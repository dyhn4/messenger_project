import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import express from 'express';
import { findInviteLinkByToken, inviteLinkHasSeat } from './db/queries/inviteLinks.js';
import { findTeamInviteLinkByToken } from './db/queries/teamInviteLinks.js';
import { clientIp, clientIpKey, isLanAddress, limits, minutesText } from './authGuard.js';
import { allowedFromOutside, installerFor, pairingErrorHandler } from './pairingPaths.js';
import { EXTERNAL_ADDRESS } from './config.js';
import { inviteLinkConnectable } from './invites.js';
import { roleLabel } from './permissions.js';
import { teamInviteLinkConnectable } from './teamInvites.js';
import { guideStatic, releasesDir } from './version.js';
import { getWebPublicUrl } from './webAddress.js';

const CODE_TTL_MS = 5 * 60 * 1000;
const MAX_ATTEMPTS = 10; // 이 횟수만큼 틀리면 코드를 무효화한다(무작위 대입 방지).

/** 지금 유효한 페어링 코드 상태. 서버 콘솔에서 "pair"를 입력할 때마다 새로 만들어진다. */
let current = null; // { code, expiresAt, attemptsLeft }

export function generatePairingCode() {
  const code = crypto.randomInt(0, 10000).toString().padStart(4, '0');
  current = { code, expiresAt: Date.now() + CODE_TTL_MS, attemptsLeft: MAX_ATTEMPTS };
  return { code, expiresInMs: CODE_TTL_MS };
}

function tryConsumeLegacyCode(code) {
  if (!current) return false;
  if (Date.now() >= current.expiresAt) {
    current = null;
    return false;
  }
  if (current.code !== code) {
    current.attemptsLeft -= 1;
    if (current.attemptsLeft <= 0) current = null;
    return false;
  }
  current = null; // 1회용
  return true;
}

/** 이 서버가 도는 PC 안에서 온 요청인지(127.0.0.1/::1) — /admin/generate는 이거로만 제한한다. */
function isLoopback(req) {
  const ip = req.socket.remoteAddress;
  return ip === '127.0.0.1' || ip === '::1' || ip === '::ffff:127.0.0.1';
}

/** "1일" / "7일"처럼 사람이 읽는 남은 기간 표기(초대 랜딩 페이지용). */
function formatRemaining(ms) {
  const days = Math.ceil(ms / (24 * 60 * 60 * 1000));
  return days <= 1 ? '하루' : `${days}일`;
}

/**
 * 아직 열려 있는 초대 링크(설치 초대·팀 초대 공용)의 남은 기간·가입 인원 — "남은 기간: 7일 · 남은 가입 인원: 3명".
 * 인원 제한이 없는(그 칸이 생기기 전에 만든) 링크는 기간만 적는다.
 */
export function inviteRemainingText(link) {
  const period = `남은 기간: ${formatRemaining(new Date(link.expiresAt).getTime() - Date.now())}`;
  if (link.maxUses == null) return period;
  return `${period} · 남은 가입 인원: ${Math.max(0, link.maxUses - link.usedCount)}명`;
}

/**
 * 연결할 수 없는 초대 링크의 이유 — "이 링크는 ___. 초대한 사람에게 새 링크를 요청하세요."의 빈칸. 인원 마감은 여기 오지
 * 않는다(다 찬 링크도 연결·설치는 된다 — 아래 seatFullNotice). 취소·만료가 아닌데도 못 쓰면 만든 사람이 더는 그 링크를
 * 줄 수 없게 된 것이다(등급 변경·팀 제외·정지·탈퇴 등 — invites.js의 inviteLinkConnectable, teamInvites.js의
 * teamInviteLinkConnectable).
 */
export function inviteUnusableReason(link) {
  if (link.revokedAt) return '취소되었습니다';
  if (new Date(link.expiresAt).getTime() <= Date.now()) return '만료되었습니다';
  return '더 이상 쓸 수 없습니다';
}

/**
 * 가입 인원이 다 찼지만 아직 열려 있는 링크의 안내 페이지에 붙이는 문단 — 이 링크로 더 가입할 수는 없어도, 이미 가입한
 * 사람이 집 PC 등 다른 기기에 설치·연결하는 데는 남은 기간 동안 계속 쓸 수 있다는 걸 알린다. 사내 와이파이에서는 링크 없이도
 * 가입되므로(auth.js) 그 경우까지 틀리지 않게 [what](무엇이 막혔는지)과 [next](새로 가입할 사람이 할 일)를 페이지마다 받는다.
 */
function seatFullNotice({ what, next }) {
  return `<p class="seat-full"><b>가입 인원 마감</b> — 정해진 인원이 모두 가입했습니다. ${what}
  이미 가입한 분은 이 링크로 다른 기기에 설치하고 로그인할 수 있습니다. ${next}</p>`;
}

function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
}

/** Edge "안전하지 않은 다운로드가 차단됨" 대응 안내에 쓰는 도식(실제 Edge 화면을 그대로
 * 베낀 스크린샷이 아니라, 어디를 눌러야 하는지만 보여주는 단순화된 그림). 정식 코드 서명
 * 인증서 없이 배포하는 실행파일이라 Edge/Windows 양쪽 모두 자체적으로 못 없애는 경고다. */
const EDGE_BLOCK_DIAGRAM = `
<svg width="320" height="120" viewBox="0 0 320 120" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="삭제 버튼 옆 화살표를 눌러 그래도 계속을 선택하는 그림">
  <rect x="1" y="1" width="318" height="44" rx="8" fill="#f1f3f5" stroke="#ced4da"/>
  <circle cx="22" cy="23" r="10" fill="#e03131"/>
  <text x="22" y="27" font-size="12" fill="#fff" font-weight="bold" text-anchor="middle">!</text>
  <text x="42" y="19" font-size="11" fill="#495057">차단됨</text>
  <text x="42" y="33" font-size="10" fill="#868e96">TangoTalk-Setup.exe</text>
  <rect x="180" y="10" width="52" height="24" rx="5" fill="#fff" stroke="#ced4da"/>
  <text x="206" y="26" font-size="10" fill="#495057" text-anchor="middle">취소</text>
  <rect x="238" y="10" width="72" height="24" rx="5" fill="#fff" stroke="#4c6ef5" stroke-width="1.5"/>
  <text x="266" y="26" font-size="10" fill="#1a1a1a" text-anchor="middle">삭제</text>
  <text x="296" y="26" font-size="9" fill="#4c6ef5" text-anchor="middle">▾</text>
  <rect x="176" y="52" width="134" height="34" rx="6" fill="#212529"/>
  <text x="188" y="73" font-size="11" fill="#fff">그래도 계속</text>
  <line x1="296" y1="38" x2="260" y2="52" stroke="#4c6ef5" stroke-width="2" marker-end="url(#arrow1)"/>
  <defs><marker id="arrow1" markerWidth="8" markerHeight="8" refX="4" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8 Z" fill="#4c6ef5"/></marker></defs>
</svg>`;

/** Edge 버전/설정에 따라 ①번 대신(또는 먼저) 뜰 수 있는 또 다른 차단 화면 — 다운로드
 * 목록에 "일반적으로 다운로드되지 않는 파일"이라는 경고와 점 세 개(⋯) 메뉴가 뜨는 형태.
 * 이 경우엔 "그래도 계속"이 아니라 그 메뉴의 "유지"를 눌러야 한다. */
const EDGE_BLOCK_DIAGRAM_ALT = `
<svg width="320" height="168" viewBox="0 0 320 168" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="다운로드 알림의 점 세 개 메뉴를 눌러 유지를 선택하는 그림">
  <rect x="1" y="1" width="318" height="26" rx="6" fill="#f8f9fa" stroke="#ced4da"/>
  <text x="12" y="18" font-size="11" fill="#495057" font-weight="bold">다운로드</text>
  <text x="296" y="19" font-size="13" fill="#868e96">⋯</text>
  <rect x="1" y="33" width="318" height="64" rx="8" fill="#fff" stroke="#ced4da"/>
  <circle cx="21" cy="55" r="9" fill="#f08c00"/>
  <text x="21" y="59" font-size="12" fill="#fff" font-weight="bold" text-anchor="middle">!</text>
  <text x="38" y="51" font-size="10" fill="#495057">TangoTalk-Setup.exe은(는) 일반적으로</text>
  <text x="38" y="64" font-size="10" fill="#495057">다운로드되지 않습니다.</text>
  <text x="38" y="82" font-size="10" fill="#4c6ef5">자세히 보기</text>
  <rect x="284" y="40" width="20" height="20" rx="4" fill="#e9ecef"/>
  <text x="294" y="54" font-size="12" fill="#495057" text-anchor="middle">⋯</text>
  <rect x="216" y="104" width="96" height="58" rx="8" fill="#fff" stroke="#ced4da"/>
  <text x="230" y="126" font-size="10" fill="#495057">삭제</text>
  <rect x="222" y="132" width="82" height="22" rx="4" fill="#e7f5ff"/>
  <text x="232" y="147" font-size="10" fill="#1864ab" font-weight="bold">유지</text>
  <line x1="294" y1="60" x2="270" y2="104" stroke="#4c6ef5" stroke-width="2" marker-end="url(#arrow4)"/>
  <defs><marker id="arrow4" markerWidth="8" markerHeight="8" refX="4" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8 Z" fill="#4c6ef5"/></marker></defs>
</svg>`;

const SMARTSCREEN_DIAGRAM = `
<svg width="280" height="140" viewBox="0 0 280 140" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="추가 정보를 누른 뒤 실행 버튼을 누르는 그림">
  <rect x="1" y="1" width="278" height="138" rx="10" fill="#fff" stroke="#ced4da"/>
  <rect x="1" y="1" width="278" height="34" rx="10" fill="#1864ab"/>
  <text x="14" y="22" font-size="12" fill="#fff" font-weight="bold">Windows에서 PC를 보호했습니다</text>
  <text x="14" y="58" font-size="10" fill="#495057">인식할 수 없는 앱을 시작했습니다.</text>
  <text x="14" y="75" font-size="11" fill="#4c6ef5" text-decoration="underline">추가 정보</text>
  <rect x="14" y="104" width="60" height="26" rx="4" fill="#1864ab"/>
  <text x="28" y="121" font-size="10" fill="#fff" font-weight="bold">실행</text>
  <rect x="150" y="104" width="70" height="26" rx="4" fill="#f1f3f5" stroke="#ced4da"/>
  <text x="160" y="121" font-size="10" fill="#495057">실행 안 함</text>
  <line x1="45" y1="78" x2="45" y2="100" stroke="#e03131" stroke-width="2" marker-end="url(#arrow2)"/>
  <defs><marker id="arrow2" markerWidth="8" markerHeight="8" refX="4" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8 Z" fill="#e03131"/></marker></defs>
</svg>`;

/** 설치 후 회원가입까지 남은 절차(딥링크 확인창 → 서버 주소 변경 창)를 단계별로 보여주는
 * 안내에 쓰는 도식 — 위 EDGE_BLOCK_DIAGRAM류와 마찬가지로 실제 화면을 그대로 베낀 스크린샷이
 * 아니라 어디를 눌러야 하는지만 보여주는 단순화된 그림이다. */
const BROWSER_OPEN_APP_DIAGRAM = `
<svg width="320" height="116" viewBox="0 0 320 116" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="이 사이트에서 TangoTalk을 열려고 합니다 알림에서 열기 버튼을 누르는 그림">
  <rect x="1" y="1" width="318" height="98" rx="12" fill="#fff" stroke="#ced4da"/>
  <text x="16" y="27" font-size="12" fill="#1a1a1a" font-weight="bold">이 사이트에서 TangoTalk을 열려고 합니다.</text>
  <text x="16" y="49" font-size="10" fill="#868e96">http://192.168.0.62:3011에서 이 응용 프로그램을</text>
  <text x="16" y="62" font-size="10" fill="#868e96">열려고 합니다.</text>
  <rect x="148" y="74" width="64" height="24" rx="5" fill="#fff" stroke="#ced4da" stroke-width="1.5"/>
  <text x="180" y="90" font-size="10" fill="#495057" text-anchor="middle">열기</text>
  <rect x="222" y="74" width="80" height="24" rx="5" fill="#4c6ef5"/>
  <text x="262" y="90" font-size="10" fill="#fff" font-weight="bold" text-anchor="middle">취소</text>
  <line x1="180" y1="114" x2="180" y2="100" stroke="#e03131" stroke-width="2" marker-end="url(#arrowOpen)"/>
  <defs><marker id="arrowOpen" markerWidth="8" markerHeight="8" refX="4" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8 Z" fill="#e03131"/></marker></defs>
</svg>`;

const SERVER_CONNECT_DIAGRAM = `
<svg width="320" height="196" viewBox="0 0 320 196" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="서버 주소 변경 창에서 연결 버튼을 누르는 그림">
  <rect x="1" y="1" width="318" height="172" rx="14" fill="#f3f1f7" stroke="#ced4da"/>
  <text x="18" y="26" font-size="13" fill="#1a1a1a" font-weight="bold">서버 주소 변경</text>
  <text x="18" y="48" font-size="9" fill="#868e96">서버 주소</text>
  <rect x="18" y="54" width="282" height="26" rx="6" fill="#fff" stroke="#ced4da"/>
  <text x="28" y="71" font-size="10" fill="#495057">https://192.168.0.62:3010</text>
  <text x="18" y="96" font-size="9" fill="#868e96">페어링 코드 또는 초대 링크의 코드</text>
  <rect x="18" y="102" width="282" height="26" rx="6" fill="#fff" stroke="#ced4da"/>
  <text x="28" y="119" font-size="10" fill="#495057">eb29ac8867e36f94b62d18d7</text>
  <text x="200" y="153" font-size="10" fill="#495057">취소</text>
  <rect x="222" y="138" width="78" height="26" rx="6" fill="#4c6ef5"/>
  <text x="261" y="155" font-size="10" fill="#fff" font-weight="bold" text-anchor="middle">연결</text>
  <line x1="261" y1="192" x2="261" y2="166" stroke="#e03131" stroke-width="2" marker-end="url(#arrowConnect)"/>
  <defs><marker id="arrowConnect" markerWidth="8" markerHeight="8" refX="4" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8 Z" fill="#e03131"/></marker></defs>
</svg>`;

/**
 * 설치 완료 후 회원가입까지 3단계 안내(Windows 칸 — 그림이 PC 브라우저 화면이다. Android 칸은 androidSection) — 각 단계
 * 바로 아래에 그 단계의 화면 그림을 붙인다.
 * [subText]만 설치 초대/팀 초대 페이지가 다르게 넘긴다(팀 초대는 자동 합류 안내가 붙는다). 가입 인원이 다 찬
 * 링크([join] false — 이미 가입한 사람이 다른 기기를 연결할 때)는 마지막 단계가 회원가입 대신 로그인이다.
 *
 * "TangoTalk 열기" 버튼을 ①과 ② 사이에 둔 이유: 페이지가 다시 보일 때(visibilitychange)
 * 자동으로 딥링크를 재시도하는 스크립트가 있긴 하지만, 브라우저가 사용자의 직접적인 클릭이
 * 아닌 프로그래밍적 시도는 "안전하지 않은 다운로드 관리" 같은 자체 UI에 포커스를 준 채
 * 조용히 무시해버리는 경우가 있다(실사용자 확인됨) — 그래서 자동 재시도는 "되면 좋은" 보조
 * 수단으로 남겨두고, 확실히 동작하는 버튼(진짜 클릭 = user gesture)을 주된 경로로 둔다.
 */
function renderPostInstallSteps(subText, { join = true } = {}) {
  return `
<div class="notice">
  <p class="notice-step">① 설치가 끝나면 이 페이지를 새로고침 하세요.</p>
  <button type="button" class="btn" onclick="tryDeepLink()">TangoTalk 열기</button>
  <p class="notice-step">② "TangoTalk 열기"가 나오면 "열기"를 클릭합니다.</p>
  ${BROWSER_OPEN_APP_DIAGRAM}
  <p class="notice-step">③ "서버 주소 변경" 창에서 "연결"을 클릭하고 ${join ? '회원가입' : '로그인'}하세요.</p>
  ${SERVER_CONNECT_DIAGRAM}
  <p class="notice-sub">${subText}</p>
</div>`;
}

/** 예전엔 접이식(<details>)으로 기본 접혀 있었는데, 안 펼쳐보고 그냥 "삭제"를 눌러버리는
 * 사람들이 있어서 항상 펼쳐진 채로 Windows 칸(platformColumns) 다운로드 버튼 바로 아래에 둔다 —
 * 그래서 <details>가 아니라 그냥 <div>다. */
const DOWNLOAD_WARNING_GUIDE = `
<div class="warn-guide">
  <p class="guide-title">다운로드·설치 중 경고 화면이 뜬다면?</p>
  <p class="hint">정식 코드 서명 인증서 없이 배포하는 실행 파일이라 아래 화면들이 뜰 수 있습니다.
  악성코드 검사와는 무관하게 항상 나오는 절차이니, 그대로 진행해도 안전합니다.</p>
  <p class="guide-step"><b>① Edge가 "안전하지 않은 다운로드가 차단됨"이라고 뜨면</b></p>
  ${EDGE_BLOCK_DIAGRAM_ALT}
  <p class="hint">다운로드 알림에 <b>"일반적으로 다운로드되지 않습니다"</b>라는 경고와 함께
  점 세 개(<b>⋯</b>) 메뉴가 보이면, 그 메뉴를 눌러 <b>"유지"</b>를 선택하세요. (Edge
  버전에 따라 아래 화면 대신 이 화면이 뜰 수 있습니다.)</p>
  ${EDGE_BLOCK_DIAGRAM}
  <p class="hint">화면 아래 다운로드 알림에서 <b>"삭제" 버튼 옆 화살표(▾)</b>를 누르고 <b>"그래도 계속"</b>을 선택하세요.</p>
  <p class="guide-step"><b>② 설치 파일 실행 시 "Windows에서 PC를 보호했습니다"가 뜨면</b></p>
  ${SMARTSCREEN_DIAGRAM}
  <p class="hint"><b>"추가 정보"</b>를 누르면 <b>"실행"</b> 버튼이 나타납니다 — 눌러서 설치를 계속하세요.</p>
</div>`;

/**
 * Android 칸 — 설치 순서(Chrome 다운로드 경고 → 출처를 알 수 없는 앱 허용 → Play 프로텍트)와 설치 뒤 앱 열기, 그리고
 * 앱이 쓰는 권한(AndroidManifest.xml — 알림·카메라/마이크·전체 화면 알림·업데이트 설치)을 어디서 허용하는지 안내한다.
 * Windows 칸의 그림 안내(renderPostInstallSteps)는 PC 브라우저 화면이라 여기서는 글로만 적는다.
 */
function androidSection(downloadHref, subText, { join = true } = {}) {
  return `
            <a class="btn" href="${downloadHref}">Android용 다운로드</a>
            <div class="warn-guide">
              <p class="guide-title">설치 순서</p>
              <ol class="guide-list">
                <li>Chrome이 <b>"이 유형의 파일은 기기에 손상을 줄 수 있습니다"</b>라고 물으면 <b>"다운로드"</b>(또는 "무시하고 다운로드")를 누릅니다.</li>
                <li>다운로드가 끝나면 알림이나 Chrome의 다운로드 목록에서 <b>설치 파일(.apk)</b>을 눌러 엽니다.</li>
                <li><b>"출처를 알 수 없는 앱"</b>을 설치할 수 없다고 나오면 <b>"설정"</b>을 눌러 <b>"이 출처 허용"</b>을 켜고, 뒤로 돌아와 <b>"설치"</b>를 누릅니다.</li>
                <li><b>Play 프로텍트</b> 경고("안전하지 않은 앱 차단됨" 등)가 뜨면 <b>"세부정보 더보기"</b> → <b>"무시하고 설치"</b>를 누릅니다.</li>
              </ol>
              <p class="hint">스토어를 거치지 않고 배포하는 앱이라 나오는 확인 절차입니다. 그대로 진행해도 안전합니다.</p>
            </div>
            <div class="notice">
              <p class="notice-step">설치가 끝나면 이 페이지로 돌아와 아래 버튼을 누르세요.</p>
              <button type="button" class="btn" onclick="tryDeepLink()">TangoTalk 열기</button>
              <p class="notice-sub">"서버 주소 변경" 창이 뜨면 "연결"을 누르고 ${join ? '회원가입' : '로그인'}하세요. ${subText}</p>
            </div>
            <div class="perm-guide">
              <p class="guide-title">권한 설정</p>
              <ul class="guide-list">
                <li><b>알림</b> — 처음 실행할 때 알림 허용을 물으면 <b>"허용"</b>을 누릅니다. 놓쳤다면 휴대폰 <b>설정 → 애플리케이션 → TangoTalk → 알림</b>에서 켭니다.</li>
                <li><b>카메라·마이크</b> — 화상회의에 처음 들어갈 때 묻습니다. <b>"앱 사용 중에만 허용"</b>을 고르세요.</li>
                <li><b>배터리</b> — 앱을 닫았을 때 알림이 늦거나 안 오면 <b>설정 → 애플리케이션 → TangoTalk → 배터리</b>를 <b>"제한 없음"</b>으로 바꿉니다(삼성은 설정 → 배터리 → 백그라운드 사용 한도의 "절전 예외 앱"에도 추가).</li>
                <li><b>전체 화면 알림</b> — 잠금 화면에서 걸려 온 화상회의를 전체 화면으로 받으려면(Android 14 이상) 앱 정보에서 TangoTalk의 <b>"전체 화면 알림"</b>을 허용합니다.</li>
                <li><b>앱 업데이트</b> — 앱 안에서 새 버전을 설치할 때 TangoTalk에도 "출처를 알 수 없는 앱" 허용을 한 번 묻습니다. <b>"이 출처 허용"</b>을 켜세요.</li>
              </ul>
            </div>`;
}

/**
 * 아이폰 칸 아래의 "앱을 닫아도 알림 받기" 조건 — 웹 푸시(webPush.js → client/web/sw.js)는 iOS 16.4 이상에서 홈 화면에
 * 추가한 웹 앱이 알림을 허용해 구독했을 때만 온다(web_push_prompt.dart의 환경설정 > 알림 상태 문구와 맞춘다).
 * 마지막 줄: 서버는 소켓이 붙어 있는 기기로는 푸시를 보내지 않는데(push.js), 홈으로만 나간 직후에는 끊긴 걸 알기까지 시간이 걸린다.
 */
const IOS_PUSH_GUIDE = `
            <div class="perm-guide">
              <p class="guide-title">앱을 닫아도 알림을 받으려면</p>
              <ul class="guide-list">
                <li><b>iOS 16.4 이상</b>이어야 합니다.</li>
                <li>Safari 탭이 아니라 <b>홈 화면의 TangoTalk 아이콘</b>으로 열어 로그인한 뒤 <b>"알림 켜기"</b> → <b>"허용"</b>을 누릅니다. 홈 화면에 추가만 해서는 알림이 오지 않습니다.</li>
                <li>앱의 <b>환경설정 → 알림</b>이 "앱을 닫아도 새 메시지 알림이 옵니다"인지 확인합니다. 아니면 <b>"앱을 닫아도 알림 받기(푸시)"</b>를 켭니다.</li>
                <li>아이폰 <b>설정 → 알림 → TangoTalk</b>이 허용되어 있고, 집중 모드에서 막혀 있지 않아야 합니다.</li>
                <li>TangoTalk의 <b>방해 금지</b>가 켜져 있는 동안에는 알림이 오지 않습니다.</li>
                <li>홈 화면 아이콘을 지웠다가 다시 추가했다면 <b>"알림 켜기"</b>를 다시 해야 합니다.</li>
              </ul>
              <p class="hint">앱을 완전히 닫지 않고 홈으로만 나간 직후 잠깐(수십 초) 동안 온 메시지는 알림이 오지 않을 수 있습니다.</p>
            </div>`;

/** 아이폰 칸 — 웹 앱 주소가 있으면(iphoneWebSection) 주소와 알림 조건을, 없으면 쓸 수 없다는 안내만. */
function iosSection(webUrl, opts) {
  const web = iphoneWebSection(webUrl, opts);
  if (!web) {
    return `
            <p class="hint">이 서버에는 아직 웹 앱 주소(공인 인증서)가 설정되어 있지 않아 아이폰·아이패드에서는 쓸 수 없습니다. 서버 관리자에게 문의하세요.</p>`;
  }
  return `${web}${IOS_PUSH_GUIDE}`;
}

/**
 * 연결할 수 있는 초대 페이지의 기기별 안내 — 왼쪽부터 Windows·Android·iPhone 세 칸에 각자의 다운로드(웹 앱) 버튼과 설명을
 * 나눠 담는다. 좁은 화면에서는 세로로 쌓이고, 페이지 스크립트(renderInvitePageShell)가 지금 기기의 칸을 표시해 맨 위로 올린다.
 * [basePath]는 다운로드 주소의 앞부분('/invite' 또는 '/team-invite'), [subText]는 설치 뒤 안내의 마지막 줄이다.
 */
function platformColumns({ basePath, token, webUrl, join, subText }) {
  return `
        <div class="platforms">
          <section class="platform" id="pf-windows">
            <h2>Windows <span class="mine-badge">지금 기기</span></h2>
            <p class="platform-sub">PC용 설치 프로그램</p>
            <a class="btn" href="${basePath}/${token}/download/windows">Windows용 다운로드</a>
            ${DOWNLOAD_WARNING_GUIDE}
            ${renderPostInstallSteps(subText, { join })}
          </section>
          <section class="platform" id="pf-android">
            <h2>Android <span class="mine-badge">지금 기기</span></h2>
            <p class="platform-sub">휴대폰·태블릿 앱(APK)</p>
            ${androidSection(`${basePath}/${token}/download/android`, subText, { join })}
          </section>
          <section class="platform" id="pf-ios">
            <h2>iPhone · iPad <span class="mine-badge">지금 기기</span></h2>
            <p class="platform-sub">설치 없이 웹 앱으로 사용</p>
            ${iosSection(webUrl, { join, token })}
          </section>
        </div>`;
}

/** 초대 페이지(설치 초대 / 팀 초대 공용) 스타일 — 두 페이지가 완전히 같은 톤을 쓰도록 뺐다. */
const INVITE_PAGE_STYLE = `
  body { font-family: -apple-system, 'Segoe UI', sans-serif; margin: 0; padding: 40px 20px; color: #1a1a1a; }
  h1 { font-size: 22px; margin-top: 0; }
  /* <a>(다운로드 링크)와 <button>("TangoTalk 열기") 둘 다 쓴다 — button 기본 테두리/배경/
     폰트를 지우고 a 태그와 똑같이 보이게 리셋한다. */
  .btn { display: block; width: 100%; box-sizing: border-box; text-align: center; padding: 14px;
         margin: 10px 0; background: #4c6ef5; color: #fff; text-decoration: none; border: none;
         border-radius: 10px; font: inherit; font-weight: bold; cursor: pointer; }
  .field { display: flex; justify-content: space-between; align-items: center; background: #f1f3f5; padding: 10px 14px;
            border-radius: 8px; margin: 8px 0; }
  .field code { font-size: 14px; word-break: break-all; }
  .hint { color: #888; font-size: 13px; }
  .warn { color: #e03131; font-weight: bold; }
  .net-caution { background: #fff4e6; border: 1px solid #f08c00; border-radius: 10px; padding: 10px 14px;
                 color: #7c4a03; font-size: 14px; margin: 12px 0; }
  /* 인원이 다 찬 링크(seatFullNotice) — 설치 버튼은 그대로 두되, 새로 가입하러 온 사람이 놓치지 않게 눈에 띄게. */
  .seat-full { background: #fff5f5; border: 1px solid #ffa8a8; border-radius: 10px; padding: 10px 14px;
               color: #c92a2a; font-size: 14px; margin: 12px 0; }
  details { margin: 12px 0; color: #555; }
  summary { cursor: pointer; }
  /* 연결할 수 있는 링크는 기기별 세 칸(platformColumns)을 나란히 놓으려고 넓게 쓴다. 칸 하나가 그림(320px)이 들어갈
     만큼은 돼야 해서, 그보다 좁아지는 화면에서는 세로로 쌓고 지금 기기의 칸(.mine — 페이지 스크립트가 붙인다)을 맨 위로 올린다. */
  .page-wrap { max-width: 480px; margin: 0 auto; }
  .page-wrap.wide { max-width: 1140px; }
  .platforms { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 20px; align-items: start; margin: 18px 0; }
  .platform { border: 1px solid #dee2e6; border-radius: 12px; padding: 16px; min-width: 0; }
  .platform.mine { border: 2px solid #4c6ef5; padding: 15px; }
  .platform h2 { font-size: 19px; margin: 0; }
  .platform-sub { color: #888; font-size: 13px; margin: 2px 0 6px; }
  .mine-badge { display: none; font-size: 12px; font-weight: bold; color: #fff; background: #4c6ef5;
                border-radius: 999px; padding: 2px 8px; vertical-align: middle; }
  .platform.mine .mine-badge { display: inline-block; }
  @media (max-width: 960px) {
    .platforms { grid-template-columns: 1fr; }
    .platform.mine { order: -1; }
  }
  /* 칸 안의 안내 상자 — 노랑(warn-guide)은 설치 중 경고 화면, 파랑(perm-guide)은 권한·알림 설정. */
  .warn-guide { background: #fff9db; border-radius: 10px; padding: 4px 14px 14px; margin: 12px 0; }
  .perm-guide { background: #e7f5ff; border-radius: 10px; padding: 4px 14px 14px; margin: 12px 0; }
  .guide-title { font-weight: bold; padding: 8px 0; margin: 0; }
  .guide-step { margin: 14px 0 6px; }
  .guide-list { margin: 0; padding-left: 20px; font-size: 14px; line-height: 1.5; }
  .guide-list li { margin: 6px 0; }
  .warn-guide svg { display: block; max-width: 100%; height: auto; margin: 4px 0; }
  /* 예전엔 한 줄짜리 완료 메시지였는데, 회원가입까지 3단계(딥링크 확인창 → 서버 주소 변경
     창)를 그림과 함께 보여주도록 늘어나서 가운데 정렬 큰 글씨 대신 왼쪽 정렬 단계별 문단으로
     바꿨다(renderPostInstallSteps 참고). 배경/테두리 색은 "설치가 끝났다"는 완료 톤 그대로. */
  .notice { background: #ebfbee; border: 2px solid #2b8a3e; border-radius: 10px;
            padding: 16px 18px; margin: 16px 0; }
  .notice-step { color: #2b8a3e; font-size: 15px; font-weight: bold; margin: 14px 0 8px; }
  .notice-step:first-child { margin-top: 0; }
  .notice svg { display: block; max-width: 100%; height: auto; margin: 6px 0 4px; }
  .notice-sub { display: block; margin-top: 14px; color: #2b8a3e; font-size: 13px; font-weight: normal; }
  /* 아이폰 안내(iphoneWebSection) — 아이폰 칸 맨 위에 옅은 상자로. 주소가 길어도 좁은 화면(아이폰)에서 가로로 넘치지
     않게 아무 데서나 줄을 바꾼다. */
  .ios-web { background: #f1f3f5; border-radius: 10px; padding: 10px 14px; margin: 10px 0; font-size: 14px; }
  .ios-web p { margin: 4px 0; }
  .ios-web a { word-break: break-all; }
  /* 웹 앱 버튼(iphoneWebSection) — 위의 설치 버튼(파란 바탕)과 구별되게 테두리 버튼으로. */
  .ios-web .btn-web { margin: 4px 0 6px; background: #fff; color: #4c6ef5; border: 2px solid #4c6ef5; }
`;

/**
 * 아이폰 사용자용 안내 — 아이폰에는 설치형 앱이 없어서 웹 앱(server/web)을 Safari로 쓴다. Safari에서 웹 앱을 쓰고 홈 화면에
 * 추가해 알림까지 받으려면 브라우저가 믿는 공인 인증서가 있어야 해서, 그 인증서가 실제로 걸려 있을 때(webAddress.js의
 * getWebPublicUrl — 없으면 null)만 주소를 알려 준다. 없을 때 알려 주면 "안전하지 않음" 경고가 뜨는 주소를 안내하게 된다.
 * 서버가 정하는 값이지만 https 주소가 아니면(설정 실수) 안내하지 않고, 페이지에 넣을 때도 이스케이프한다.
 *
 * 자리가 남은 링크([join])면 웹 앱 주소에 이 초대 코드를 붙여(`?invite=<코드>`) 알려 준다 — 사내 와이파이 밖에서는 초대 코드를
 * 함께 보내야 가입되는데(auth.js /register), 웹 앱은 그 코드를 주소에서 꺼내 가입할 때 보낸다(client web_launch_invite.dart).
 * 초대받은 아이폰 사용자는 대개 밖에서 이 페이지를 열기 때문이다. 팀 초대면 그 코드로 팀 자동 합류·등급도 앱과 똑같이 받는다.
 * 인원이 다 찬 링크는 가입에 못 쓰니 코드 없이 로그인 주소로만 알려 준다.
 */
function iphoneWebSection(webUrl, { join = true, token = null } = {}) {
  if (typeof webUrl !== 'string' || !/^https:\/\/[^\s/]+/.test(webUrl)) return '';
  const withInvite =
    join && typeof token === 'string' && /^[A-Za-z0-9_-]{8,128}$/.test(token)
      ? `${webUrl.endsWith('/') ? webUrl : `${webUrl}/`}?invite=${encodeURIComponent(token)}`
      : webUrl;
  const url = escapeHtml(withInvite);
  const how = withInvite !== webUrl
    ? '을 Safari로 열어 가입하고 홈 화면에 추가하세요.'
    : '을 Safari로 열어 로그인하고 홈 화면에 추가하세요.';
  const signupNote = withInvite !== webUrl
    ? `
          <p class="hint">처음 가입할 때는 꼭 이 주소로 여세요 — 초대 코드가 들어 있어 사내 와이파이 밖에서도 가입됩니다. 가입한 뒤에는 홈 화면의 웹 앱으로 로그인합니다.</p>`
    : '';
  // 버튼은 아이폰만이 아니라 설치 없이 브라우저로 쓰려는 사람(PC·안드로이드)도 누를 수 있다 — 같은 주소다.
  return `
        <div class="ios-web">
          <a class="btn btn-web" href="${url}">웹 앱 열기</a>
          <p class="hint">설치하지 않고 이 브라우저에서 바로 쓸 수도 있습니다(PC·안드로이드도 됩니다).</p>
          <p><b>아이폰은 앱 대신 웹 앱을 씁니다:</b> <a href="${url}">${url}</a> ${how}</p>
          <p class="hint">Safari의 공유 버튼 → "홈 화면에 추가". 홈 화면에서 열어야 새 메시지 알림도 받을 수 있습니다.</p>${signupNote}
        </div>`;
}

/** <h1>+body(유효성에 따라 달라짐)를 받아 최종 HTML 문서로 조립한다. 연결할 수 있는 링크(=다운로드
 * 버튼이 있는 경우 — 가입 인원이 다 찬 링크 포함)일 때만 기기별 세 칸(platformColumns)이 들어갈 넓은 폭을 쓰고,
 * 그렇지 않은 링크는 다운로드 자체를 안 시키므로 좁은 1단으로 그린다.
 * renderInvitePage/renderTeamInvitePage가 공유한다. */
function renderInvitePageShell({ title, body, connectable, deepLink }) {
  const main = `<h1>${title}</h1>${body}`;
  const page = `<div class="page-wrap${connectable ? ' wide' : ''}">${main}</div>`;
  // 페이지를 열 때 한 번 시도하고 끝나는 게 아니라, 설치 프로그램(별도 창) 때문에 이 탭이
  // 잠깐 가려졌다가 다시 보일 때마다("설치 마침"을 누르고 브라우저로 돌아왔을 때 포함) 다시
  // 시도한다 — 그래야 설치가 막 끝난 뒤 이 탭으로 돌아오기만 해도 새로고침 없이 자동으로
  // 앱이 열린다. focus가 아니라 visibilitychange를 쓰는 이유: 같은 브라우저 창 안에서 다른
  // 탭을 보고 있을 때는 이 탭이 여전히 hidden이라 재시도하지 않는 게 맞고(사용자가 안 보고
  // 있는데 "앱을 열까요?" 확인창이 뜨면 혼란스럽다), window focus만으로는 이 구분이 안 된다.
  //
  // 아이폰·아이패드에서는 시도하지 않는다 — 설치형 앱이 없어서(웹 앱을 쓴다 — iphoneWebSection) tangotalk:// 주소를 열려고 하면
  // Safari가 "주소가 유효하지 않음" 경고창을 띄우고, 이 탭이 다시 보일 때마다 또 띄운다. 아이패드는 Safari가 Mac이라고
  // 알려 오는 경우가 있어 터치 지점 수로 가린다(Mac은 0).
  //
  // 지금 기기의 칸(platformColumns)에 .mine을 붙여 "지금 기기"로 표시한다 — 좁은 화면에서는 그 칸이 맨 위로 온다(CSS).
  const deepLinkScript = connectable
    ? `<script>
var noInstalledApp = /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
var myPlatform = noInstalledApp ? 'ios' : /Android/i.test(navigator.userAgent) ? 'android' : /Windows/i.test(navigator.userAgent) ? 'windows' : '';
var myColumn = myPlatform && document.getElementById('pf-' + myPlatform);
if (myColumn) myColumn.className += ' mine';
function tryDeepLink() { if (noInstalledApp) return; try { window.location.href = ${JSON.stringify(deepLink)}; } catch (e) {} }
tryDeepLink();
document.addEventListener('visibilitychange', function () {
  if (document.visibilityState === 'visible') tryDeepLink();
});
</script>`
    : '';
  return `<!doctype html>
<html lang="ko"><head><meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${title}</title>
<style>${INVITE_PAGE_STYLE}</style></head>
<body>${page}
${deepLinkScript}
</body></html>`;
}

/**
 * 사내망 밖에서 이 페이지를 열었을 때 맨 위에 띄우는 주의 — 이 페이지와 설치 파일은 평문 HTTP라
 * 공용 와이파이처럼 믿을 수 없는 네트워크에서는 중간에서 바꿔치기될 수 있다(공인 인증서 없이는
 * 기술적으로 막을 방법이 없어서 안내로 대신한다 — README "외부(LTE/5G)에서 접속하기").
 */
const PUBLIC_WIFI_CAUTION = `<p class="net-caution"><b>⚠ 공용 와이파이(카페·공항·호텔 등)에서는 열지 마세요.</b><br />
  이 페이지와 설치 파일은 암호화되지 않은 연결로 받습니다. LTE/5G나 집 와이파이로 바꾼 뒤 다시 여세요.</p>`;

/** 초대 링크를 열었을 때 보여주는 안내 페이지 — 자체 서명 인증서 경고 없이(평문 HTTP) 누구나
 * 열어볼 수 있어야 해서 인증/세션 없이 정적으로 그린다. [connectable]은 이 링크로 지금 연결·설치할 수
 * 있는지(invites.js의 inviteLinkConnectable — 만든 사람의 권한까지 DB로 봐야 해서 라우트가 미리 구해 넘긴다).
 * 가입 인원이 다 찬 링크도 연결·설치는 되므로 설치 안내는 그대로 두고, 가입만 마감됐다고 알린다. [webUrl]은 아이폰
 * 사용자에게 알려 줄 웹 앱 주소(iphoneWebSection) — 안 넘기면 지금 걸려 있는 공인 인증서 기준의 주소(없으면 null). */
export function renderInvitePage({ serverAddress, token, link, connectable, outside, webUrl = getWebPublicUrl() }) {
  const title = 'TangoTalk 초대';
  // tangotalk:// 커스텀 스킴 — 앱이 이미 설치돼 있으면 이 링크로 바로 열리면서 서버 주소/코드가
  // 자동입력된다(설치 여부를 서버가 알 방법은 없으니, 그냥 시도해보고 반응이 없으면 — 즉 이
  // 페이지가 그대로 보이고 있으면 — 아래 설치 안내를 그대로 따라가면 되는 구조).
  const deepLink = `tangotalk://pair/?address=${encodeURIComponent(serverAddress)}&code=${encodeURIComponent(token)}`;
  const join = !!link && inviteLinkHasSeat(link);
  const body = !link
    ? `<p class="warn">유효하지 않은 초대 링크입니다.</p>`
    : !connectable
      ? `<p class="warn">이 링크는 ${inviteUnusableReason(link)}. 초대한 사람에게 새 링크를 요청하세요.</p>`
      : `
        <p>${escapeHtml(link.createdByName)}님이 TangoTalk에 초대했습니다. ${inviteRemainingText(link)}</p>
        ${join ? '' : seatFullNotice({
          what: '사내 와이파이 밖에서는 이 링크로 더 가입할 수 없습니다.',
          next: '새로 가입하실 분은 초대한 사람에게 새 링크를 요청하거나 사내 와이파이에서 가입하세요.',
        })}
        ${outside ? PUBLIC_WIFI_CAUTION : ''}
        <p class="hint">TangoTalk이 이미 설치되어 있다면 잠시 후 앱이 자동으로 열립니다. 반응이 없다면 아직 설치되지 않은 것이니, 아래에서 설치 파일을 받으세요.</p>
        ${platformColumns({ basePath: '/invite', token, webUrl, join, subText: '서버 주소와 코드가 자동으로 입력됩니다.' })}
        <details>
          <summary>자동으로 안 되면 직접 입력하기</summary>
          <div class="field"><span>서버 주소</span><code id="addr">${escapeHtml(serverAddress)}</code></div>
          <div class="field"><span>코드</span><code id="code">${escapeHtml(token)}</code></div>
        </details>
        ${join ? '<p class="hint">이미 계정이 있다면 바로 로그인하시고, 처음이라면 회원가입 후 팀 소유자·관리자에게 팀 참가를 요청하세요.</p>' : ''}
      `;
  return renderInvitePageShell({ title, body, connectable, deepLink });
}

/** 팀 초대 링크 안내 페이지 — renderInvitePage와 거의 같지만, 가입하면 어느 팀에 어떤
 * 등급으로 자동 합류하는지 알려준다. link에는 findTeamInviteLinkByToken이 이미 join해서
 * 넣어준 teamName이 들어있다. [connectable]은 teamInvites.js의 teamInviteLinkConnectable 결과 —
 * 가입 인원이 다 찬 링크는 연결·설치 안내만 두고 자동 합류 약속은 빼고 마감됐다고 알린다. 그런 링크로 오는 사람은
 * 대개 이미 이 링크로 가입해 다른 기기를 연결하는 사람이라, "이미 계정이 있다면 팀에 자동 합류되지 않는다"는 안내도
 * 자리가 남은 링크에만 붙인다(설치 초대 페이지의 계정 안내와 같다). 아이폰 안내([webUrl])도 설치 초대 페이지와 같고, 웹 앱으로
 * 가입하면 팀에 자동으로 들어가지 않는다는 줄만 더한다(iphoneWebSection). */
export function renderTeamInvitePage({ serverAddress, token, link, connectable, outside, webUrl = getWebPublicUrl() }) {
  const title = 'TangoTalk 팀 초대';
  const deepLink = `tangotalk://pair/?address=${encodeURIComponent(serverAddress)}&code=${encodeURIComponent(token)}`;
  const join = !!link && inviteLinkHasSeat(link);
  const body = !link
    ? `<p class="warn">유효하지 않은 초대 링크입니다.</p>`
    : !connectable
      ? `<p class="warn">이 링크는 ${inviteUnusableReason(link)}. 초대한 사람에게 새 링크를 요청하세요.</p>`
      : `
        <p>${escapeHtml(link.createdByName)}님이 <b>${escapeHtml(link.teamName)}</b> 팀에 초대했습니다.${join ? ` 이 링크로 가입하면
        자동으로 이 팀에 합류하고 <b>${roleLabel(link.assignedRole)}</b> 등급이 부여됩니다.` : ''}
        ${inviteRemainingText(link)}</p>
        ${join ? '' : seatFullNotice({
          what: '이 링크로 가입해도 팀에 자동으로 들어가지 않고, 사내 와이파이 밖에서는 가입도 할 수 없습니다.',
          next: '새로 가입하실 분은 초대한 사람에게 새 링크를 요청하세요.',
        })}
        ${outside ? PUBLIC_WIFI_CAUTION : ''}
        <p class="hint">TangoTalk이 이미 설치되어 있다면 잠시 후 앱이 자동으로 열립니다. 반응이 없다면 아직 설치되지 않은 것이니, 아래에서 설치 파일을 받으세요.</p>
        ${platformColumns({
          basePath: '/team-invite',
          token,
          webUrl,
          join,
          subText: join
            ? `서버 주소와 코드가 자동으로 입력되고, 가입하면 ${escapeHtml(link.teamName)} 팀에 자동으로 들어갑니다.`
            : '서버 주소와 코드가 자동으로 입력됩니다.',
        })}
        <details>
          <summary>자동으로 안 되면 직접 입력하기</summary>
          <div class="field"><span>서버 주소</span><code id="addr">${escapeHtml(serverAddress)}</code></div>
          <div class="field"><span>코드</span><code id="code">${escapeHtml(token)}</code></div>
        </details>
        ${join ? '<p class="hint">이미 계정이 있다면 이 링크로는 팀에 자동 합류되지 않습니다 — 팀 소유자·관리자에게 직접 참가를 요청하세요.</p>' : ''}
      `;
  return renderInvitePageShell({ title, body, connectable, deepLink });
}

/** 초대 설치 파일 다운로드 — 설치 초대/팀 초대 페이지가 공유한다(내려주는 파일은 똑같음). 플랫폼은 정해 둔 것만
 * (pairingPaths.js installerFor — 'constructor' 같은 이름이 객체의 기본 속성으로 잡히지 않게). */
export function downloadInstaller(req, res) {
  const installer = installerFor(req.params.platform);
  if (!installer) return res.status(404).send('알 수 없는 플랫폼입니다.');
  const filePath = path.join(releasesDir, installer.file);
  if (!fs.existsSync(filePath)) return res.status(404).send('아직 배포된 빌드가 없습니다.');
  res.download(filePath, installer.downloadName);
}

/**
 * GET /pair/:code — 페어링 코드(또는 초대 토큰)를 확인하고 이 서버의 TLS 인증서(공개 부분)를
 * 돌려준다. 사내망의 평문 페어링 서버(아래 startPairingServer)와, 사내망 밖(LTE/5G)에서도
 * 재페어링할 수 있게 메인 HTTPS 서버(index.js — 공유기에는 이 포트만 열려 있다) 양쪽에 붙인다.
 * HTTPS 쪽은 앱이 아직 이 인증서를 모르는 상태라 인증서 확인 없이 붙되, 응답에 실린 인증서가
 * 실제 TLS 연결의 인증서와 같은지 대조한다(client pinned_tls.dart). 다만 중간에서 TLS를 대신 맺은 쪽이 자기 인증서를
 * 본문에도 실어 보내면 이 대조로는 못 막는다 — 그래서 도메인(웹 앱 주소)을 설정한 서버는 같은 Express 앱을 공인
 * 인증서(Let's Encrypt)로 웹 전용 HTTPS 포트에도 여는데, 서버 주소가 도메인 이름이면 앱이 그 이름의 443 포트에서 이
 * 경로를 **보통의 인증서 검증**으로 먼저 물어본다. 거기서 받은 인증서는 공인 인증 기관이 확인한 연결로 온 것이라
 * 바꿔치기될 수 없다. 코드 상태(5분·1회용·10번 틀리면 무효)는 모든 경로가 함께 쓴다.
 */
export function createPairHandler(getCertPem) {
  return async (req, res) => {
    const { code } = req.params;
    if (/^\d{4}$/.test(code)) {
      if (!tryConsumeLegacyCode(code)) {
        return res.status(404).json({ error: '코드가 올바르지 않거나 만료되었습니다.' });
      }
      return res.json({ cert: getCertPem() });
    }

    // 4자리가 아니면 초대 링크 토큰으로 본다(설치 초대/팀 초대 둘 다 이 방식으로 인증서를
    // 받으므로 둘 다 확인한다 — 길이를 굳이 더 따지지 않는다, 어차피 둘 다 없으면 404).
    //
    // 초대 링크는(설치 초대·팀 초대 모두) 인증서를 받을 때는 자리를 쓰지 않고 사용 횟수도 안 센다 —
    // 가입 인원은 실제 가입(auth.js의 claimInviteSeat)에서만 한 자리씩 쓴다. 여기서 먼저 쓰면 인증서만
    // 받고 아직 가입 전인 사람이 자리를 차지하거나, 같은 사람이 다시 연결할 때마다 인원이 줄어든다.
    // 같은 이유로 인원이 다 찬 링크로도 인증서는 받는다(…Connectable) — 이 링크로 가입한 사람이 집 PC 등
    // 다른 기기를 연결하거나 앱을 다시 설치할 때 같은 링크를 쓰고, 인증서는 원래 공개 정보다. 가입은
    // auth.js가 인원까지 보고 막는다.
    const link = await findInviteLinkByToken(code);
    if (await inviteLinkConnectable(link)) return res.json({ cert: getCertPem() });
    const teamLink = await findTeamInviteLinkByToken(code);
    if (await teamInviteLinkConnectable(teamLink)) return res.json({ cert: getCertPem() });
    return res.status(404).json({ error: '코드가 올바르지 않거나 만료되었습니다.' });
  };
}

/**
 * 인증서를 앱에 미리 내장하지 않고, 새 기기를 페어링 코드로 연결할 수 있게 해주는
 * 평문 HTTP 부트스트랩 서버. 여기서 내려주는 건 TLS 인증서의 공개 부분뿐이라(비밀키 아님)
 * 정보 자체가 새어나가도 큰 문제는 아니지만, 엉뚱한 서버가 아니라 지금 이 서버가 맞다는 걸
 * 관리자가 직접 불러준 코드로 확인시켜주는 게 목적이다 — 그래서 코드는 5분짜리 1회용으로 짧게 둔다.
 *
 * 코드 생성은 두 가지 경로로 할 수 있다: ①서버를 일반 터미널(`npm start`)로 띄웠다면 그
 * 콘솔에 "pair"를 입력(index.js의 readline) ②pm2처럼 콘솔 입력을 받을 수 없는 방식으로
 * 띄웠다면 같은 PC에서 `npm run pair`(scripts/pair.mjs가 아래 /admin/generate를 호출) —
 * 이 라우트는 같은 PC(loopback)에서만 호출 가능해서 외부에 노출되지 않는다.
 *
 * 같은 서버에 **초대 링크**(invites.js에서 발급, `/invite/<토큰>`) 랜딩 페이지와 설치 파일
 * 다운로드도 얹는다 — 자체 서명 인증서 경고 없이 누구나 브라우저로 바로 열어볼 수 있어야
 * 하므로, 회원가입 절차 없이 여는 메인 HTTPS 서버(index.js)가 아니라 일부러 이 평문 서버에
 * 둔다. 인증서를 실제로 받는 부분(/pair/:code)은 4자리 코드든 초대 토큰이든 같은 방식으로
 * 처리해서, 클라이언트(server_setup_screen.dart 등)는 코드 입력칸 하나만 있으면 된다.
 */
export function startPairingServer({ port, mainPort, getCertPem }) {
  const app = express();

  // 사내망 밖(LTE/5G)에서 이 평문 포트에 닿는 건 초대 링크 안내 페이지·설치 파일·도움말을 열 때뿐이어야
  // 한다 — 공유기에서 이 포트를 열어 초대받은 사람이 밖에서도 안내 페이지를 볼 수 있게 하되, 인증서를
  // 평문으로 내려주는 /pair는 막는다(밖에서는 앱이 메인 HTTPS 포트로 페어링한다 — pinned_tls.dart).
  // 초대 토큰을 맞혀보는 걸 늦추려고 밖에서 온 요청은 IP마다(IPv6는 /64마다 — authGuard.js ipKey) 요청 수도 제한한다.
  app.use((req, res, next) => {
    if (isLanAddress(clientIp(req))) return next();
    if (!allowedFromOutside(req.path)) {
      return res.status(403).json({ error: '사내망 밖에서는 이 주소로 연결할 수 없습니다. 앱에 외부 주소(https://)를 넣어 연결하세요.' });
    }
    if (req.path.startsWith('/guide')) return next();
    const wait = limits.invitePageIp.hit(clientIpKey(req));
    if (wait > 0) {
      // 브라우저로 여는 페이지라 JSON(tooMany) 대신 글로 답하되, 언제 다시 되는지는 같은 머리글로 알린다.
      res.set('Retry-After', String(Math.ceil(wait / 1000)));
      return res.status(429).send(`요청이 너무 많습니다. ${minutesText(wait)} 후 다시 시도하세요.`);
    }
    next();
  });

  /** 안내 페이지에 적을 메인 HTTPS 주소 — 지금 이 페이지를 연 주소의 호스트에 메인 포트. 외부 주소
   * (EXTERNAL_ADDRESS)로 열었으면 그 주소 그대로(공유기에서 메인 포트를 다른 번호로 열었을 수 있다). */
  const mainAddressFor = (req) =>
    EXTERNAL_ADDRESS && req.hostname === EXTERNAL_ADDRESS.host ? EXTERNAL_ADDRESS.url : `https://${req.hostname}:${mainPort}`;

  app.get('/pair/:code', createPairHandler(getCertPem));

  app.post('/admin/generate', (req, res) => {
    if (!isLoopback(req)) return res.status(404).json({ error: '코드가 올바르지 않거나 만료되었습니다.' });
    const { code, expiresInMs } = generatePairingCode();
    res.json({ code, expiresInMs });
  });

  /** 초대 링크 안내 페이지 — 링크를 그냥 열어보는 사람용(브라우저). */
  app.get('/invite/:token', async (req, res) => {
    const link = await findInviteLinkByToken(req.params.token);
    res.type('html').send(
      renderInvitePage({
        serverAddress: mainAddressFor(req),
        token: req.params.token,
        link,
        connectable: await inviteLinkConnectable(link),
        outside: !isLanAddress(clientIp(req)),
      }),
    );
  });

  /** 설치 파일 다운로드 — 평문 HTTP라 브라우저 인증서 경고 없이 그대로 받아진다. 지금 연결할 수 있는
   * 초대 링크를 거쳐온 요청만 받는다(링크가 만료·취소됐거나 만든 사람이 권한을 잃었으면 파일도 안 내려준다 —
   * 인원이 다 찬 링크는 이미 가입한 사람이 다른 기기에 설치할 때 쓰므로 내려준다). */
  app.get('/invite/:token/download/:platform', async (req, res) => {
    const link = await findInviteLinkByToken(req.params.token);
    if (!(await inviteLinkConnectable(link))) return res.status(404).send('만료되었거나 더 쓸 수 없는 링크입니다.');
    downloadInstaller(req, res);
  });

  /** 팀 초대 링크 안내 페이지 — 링크를 그냥 열어보는 사람용(브라우저). */
  app.get('/team-invite/:token', async (req, res) => {
    const link = await findTeamInviteLinkByToken(req.params.token);
    res.type('html').send(
      renderTeamInvitePage({
        serverAddress: mainAddressFor(req),
        token: req.params.token,
        link,
        connectable: await teamInviteLinkConnectable(link),
        outside: !isLanAddress(clientIp(req)),
      }),
    );
  });

  /** 팀 초대 링크로 받는 설치 파일 다운로드 — 위 /invite/:token/download와 같은 파일, 같은 기준. */
  app.get('/team-invite/:token/download/:platform', async (req, res) => {
    const link = await findTeamInviteLinkByToken(req.params.token);
    if (!(await teamInviteLinkConnectable(link))) return res.status(404).send('만료되었거나 더 쓸 수 없는 링크입니다.');
    downloadInstaller(req, res);
  });

  /** 초보자용 도움말(server/guide/ 정적 페이지) — 메인 HTTPS 서버의 /guide와 같은 파일. 앱이
   * 자체 서명 인증서 경고 없이 열리도록 이 평문 포트의 /guide/를 먼저 시도한다. 여기에는 이
   * 공개 정적 폴더만 얹고 다른 메인 서버 경로는 노출하지 않는다. */
  app.use('/guide', guideStatic);

  // 맨 마지막 — 위 경로에서 난 예외는 NODE_ENV와 상관없이 스택 추적 없는 짧은 JSON으로만 답한다(pairingPaths.js).
  app.use(pairingErrorHandler);

  const server = app.listen(port, () => {
    console.log(`[pairing] 페어링 부트스트랩 서버 대기 중 (평문 HTTP, 포트 ${port})`);
  });
  return server;
}
