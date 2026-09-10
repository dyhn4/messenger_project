import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import express from 'express';
import { findInviteLinkByToken, isInviteLinkValid, markInviteLinkUsed } from './db/queries/inviteLinks.js';
import {
  findTeamInviteLinkByToken,
  isTeamInviteLinkValid,
  markTeamInviteLinkUsed,
} from './db/queries/teamInviteLinks.js';
import { roleLabel } from './permissions.js';
import { releasesDir } from './version.js';

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
 * 설치 완료 후 회원가입까지 3단계 안내 — 각 단계 바로 아래에 그 단계의 화면 그림을 붙인다.
 * [subText]만 설치 초대/팀 초대 페이지가 다르게 넘긴다(팀 초대는 자동 합류 안내가 붙는다).
 *
 * "TangoTalk 열기" 버튼을 ①과 ② 사이에 둔 이유: 페이지가 다시 보일 때(visibilitychange)
 * 자동으로 딥링크를 재시도하는 스크립트가 있긴 하지만, 브라우저가 사용자의 직접적인 클릭이
 * 아닌 프로그래밍적 시도는 "안전하지 않은 다운로드 관리" 같은 자체 UI에 포커스를 준 채
 * 조용히 무시해버리는 경우가 있다(실사용자 확인됨) — 그래서 자동 재시도는 "되면 좋은" 보조
 * 수단으로 남겨두고, 확실히 동작하는 버튼(진짜 클릭 = user gesture)을 주된 경로로 둔다.
 */
function renderPostInstallSteps(subText) {
  return `
<div class="notice">
  <p class="notice-step">① 설치가 끝나면 이 페이지를 새로고침 하세요.</p>
  <button type="button" class="btn" onclick="tryDeepLink()">TangoTalk 열기</button>
  <p class="notice-step">② "TangoTalk 열기"가 나오면 "열기"를 클릭합니다.</p>
  ${BROWSER_OPEN_APP_DIAGRAM}
  <p class="notice-step">③ "서버 주소 변경" 창에서 "연결"을 클릭하고 회원가입하세요.</p>
  ${SERVER_CONNECT_DIAGRAM}
  <p class="notice-sub">${subText}</p>
</div>`;
}

/** 예전엔 접이식(<details>)으로 기본 접혀 있었는데, 안 펼쳐보고 그냥 "삭제"를 눌러버리는
 * 사람들이 있어서 페이지 오른쪽에 항상 펼쳐진 채로 보이도록 뺐다(renderInvitePage/
 * renderTeamInvitePage의 2단 레이아웃 참고) — 그래서 <details>가 아니라 그냥 <div>다. */
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
  <p class="hint"><b>"추가 정보"</b>를 누르면 <b>"실행"</b> 버튼이 나타납니다 — 눌러서 설치를 계속하세요. (안드로이드는 설치 전 "출처를 알 수 없는 앱" 허용을 한 번 물어봅니다 — "허용"을 누르면 됩니다.)</p>
</div>`;

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
  details { margin: 12px 0; color: #555; }
  summary { cursor: pointer; }
  /* 가이드를 상시 노출로 바꾸면서(아래 .page-layout 참고) 페이지 폭이 좁으면 오른쪽에
     나란히 둘 자리가 없어서, 넓은 화면에서만 2단으로 붙이고 좁은 화면에서는 본문 아래에
     세로로 이어붙인다. */
  .page-wrap { max-width: 480px; margin: 0 auto; }
  .page-wrap.with-guide { max-width: 840px; }
  .page-layout { display: flex; gap: 28px; align-items: flex-start; }
  .page-main { flex: 1 1 420px; min-width: 0; max-width: 480px; }
  .warn-guide { flex: 0 0 320px; background: #fff9db; border-radius: 10px; padding: 4px 16px 16px;
                position: sticky; top: 24px; }
  .guide-title { font-weight: bold; padding: 8px 0; margin: 0; }
  .guide-step { margin: 14px 0 6px; }
  .warn-guide svg { display: block; max-width: 100%; height: auto; margin: 4px 0; }
  @media (max-width: 760px) {
    .page-layout { flex-direction: column; }
    .page-main { max-width: 100%; }
    .warn-guide { flex: 1 1 auto; width: 100%; box-sizing: border-box; position: static; }
  }
  /* 예전엔 한 줄짜리 완료 메시지였는데, 회원가입까지 3단계(딥링크 확인창 → 서버 주소 변경
     창)를 그림과 함께 보여주도록 늘어나서 가운데 정렬 큰 글씨 대신 왼쪽 정렬 단계별 문단으로
     바꿨다(renderPostInstallSteps 참고). 배경/테두리 색은 "설치가 끝났다"는 완료 톤 그대로. */
  .notice { background: #ebfbee; border: 2px solid #2b8a3e; border-radius: 10px;
            padding: 16px 18px; margin: 16px 0; }
  .notice-step { color: #2b8a3e; font-size: 15px; font-weight: bold; margin: 14px 0 8px; }
  .notice-step:first-child { margin-top: 0; }
  .notice svg { display: block; max-width: 100%; height: auto; margin: 6px 0 4px; }
  .notice-sub { display: block; margin-top: 14px; color: #2b8a3e; font-size: 13px; font-weight: normal; }
`;

/** <h1>+body(유효성에 따라 달라짐)를 받아 최종 HTML 문서로 조립한다. 유효한 링크(=다운로드
 * 버튼이 있는 경우)일 때만 오른쪽에 다운로드 경고 가이드를 상시 노출하는 2단 레이아웃을
 * 쓰고, 무효한 링크는 다운로드 자체를 안 시키므로 가이드 없이 좁은 1단으로 그린다.
 * renderInvitePage/renderTeamInvitePage가 공유한다. */
function renderInvitePageShell({ title, body, valid, deepLink }) {
  const main = `<h1>${title}</h1>${body}`;
  const page = valid
    ? `<div class="page-wrap with-guide"><div class="page-layout"><div class="page-main">${main}</div>${DOWNLOAD_WARNING_GUIDE}</div></div>`
    : `<div class="page-wrap">${main}</div>`;
  // 페이지를 열 때 한 번 시도하고 끝나는 게 아니라, 설치 프로그램(별도 창) 때문에 이 탭이
  // 잠깐 가려졌다가 다시 보일 때마다("설치 마침"을 누르고 브라우저로 돌아왔을 때 포함) 다시
  // 시도한다 — 그래야 설치가 막 끝난 뒤 이 탭으로 돌아오기만 해도 새로고침 없이 자동으로
  // 앱이 열린다. focus가 아니라 visibilitychange를 쓰는 이유: 같은 브라우저 창 안에서 다른
  // 탭을 보고 있을 때는 이 탭이 여전히 hidden이라 재시도하지 않는 게 맞고(사용자가 안 보고
  // 있는데 "앱을 열까요?" 확인창이 뜨면 혼란스럽다), window focus만으로는 이 구분이 안 된다.
  const deepLinkScript = valid
    ? `<script>
function tryDeepLink() { try { window.location.href = ${JSON.stringify(deepLink)}; } catch (e) {} }
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

/** 초대 링크를 열었을 때 보여주는 안내 페이지 — 자체 서명 인증서 경고 없이(평문 HTTP) 누구나
 * 열어볼 수 있어야 해서 인증/세션 없이 정적으로 그린다. */
function renderInvitePage({ host, mainPort, token, link }) {
  const valid = isInviteLinkValid(link);
  const title = 'TangoTalk 초대';
  const serverAddress = `https://${host}:${mainPort}`;
  // tangotalk:// 커스텀 스킴 — 앱이 이미 설치돼 있으면 이 링크로 바로 열리면서 서버 주소/코드가
  // 자동입력된다(설치 여부를 서버가 알 방법은 없으니, 그냥 시도해보고 반응이 없으면 — 즉 이
  // 페이지가 그대로 보이고 있으면 — 아래 설치 안내를 그대로 따라가면 되는 구조).
  const deepLink = `tangotalk://pair/?address=${encodeURIComponent(serverAddress)}&code=${encodeURIComponent(token)}`;
  const body = !link
    ? `<p class="warn">유효하지 않은 초대 링크입니다.</p>`
    : !valid
      ? `<p class="warn">이 링크는 ${link.revokedAt ? '취소되었습니다' : '만료되었습니다'}. 초대한 사람에게 새 링크를 요청하세요.</p>`
      : `
        <p>${escapeHtml(link.createdByName)}님이 TangoTalk에 초대했습니다. 남은 기간: ${formatRemaining(new Date(link.expiresAt).getTime() - Date.now())}</p>
        <p class="hint">TangoTalk이 이미 설치되어 있다면 잠시 후 앱이 자동으로 열립니다. 반응이 없다면 아직 설치되지 않은 것이니, 아래에서 설치 파일을 받으세요.</p>
        <div class="downloads">
          <a class="btn" href="/invite/${token}/download/windows">Windows용 다운로드</a>
          <a class="btn" href="/invite/${token}/download/android">Android용 다운로드</a>
        </div>
        ${renderPostInstallSteps('서버 주소와 코드가 자동으로 입력됩니다.')}
        <details>
          <summary>자동으로 안 되면 직접 입력하기</summary>
          <div class="field"><span>서버 주소</span><code id="addr">${escapeHtml(serverAddress)}</code></div>
          <div class="field"><span>코드</span><code id="code">${escapeHtml(token)}</code></div>
        </details>
        <p class="hint">이미 계정이 있다면 바로 로그인하시고, 처음이라면 회원가입 후 팀 소유자·관리자에게 팀 참가를 요청하세요.</p>
      `;
  return renderInvitePageShell({ title, body, valid, deepLink });
}

/** 팀 초대 링크 안내 페이지 — renderInvitePage와 거의 같지만, 가입하면 어느 팀에 어떤
 * 등급으로 자동 합류하는지 알려준다. link에는 findTeamInviteLinkByToken이 이미 join해서
 * 넣어준 teamName이 들어있다. */
function renderTeamInvitePage({ host, mainPort, token, link }) {
  const valid = isTeamInviteLinkValid(link);
  const title = 'TangoTalk 팀 초대';
  const serverAddress = `https://${host}:${mainPort}`;
  const deepLink = `tangotalk://pair/?address=${encodeURIComponent(serverAddress)}&code=${encodeURIComponent(token)}`;
  const body = !link
    ? `<p class="warn">유효하지 않은 초대 링크입니다.</p>`
    : !valid
      ? `<p class="warn">이 링크는 ${link.revokedAt ? '취소되었습니다' : '만료되었습니다'}. 초대한 사람에게 새 링크를 요청하세요.</p>`
      : `
        <p>${escapeHtml(link.createdByName)}님이 <b>${escapeHtml(link.teamName)}</b> 팀에 초대했습니다. 이 링크로 가입하면
        자동으로 이 팀에 합류하고 <b>${roleLabel(link.assignedRole)}</b> 등급이 부여됩니다.
        남은 기간: ${formatRemaining(new Date(link.expiresAt).getTime() - Date.now())}</p>
        <p class="hint">TangoTalk이 이미 설치되어 있다면 잠시 후 앱이 자동으로 열립니다. 반응이 없다면 아직 설치되지 않은 것이니, 아래에서 설치 파일을 받으세요.</p>
        <div class="downloads">
          <a class="btn" href="/team-invite/${token}/download/windows">Windows용 다운로드</a>
          <a class="btn" href="/team-invite/${token}/download/android">Android용 다운로드</a>
        </div>
        ${renderPostInstallSteps(`서버 주소와 코드가 자동으로 입력되고, 가입하면 ${escapeHtml(link.teamName)} 팀에 자동으로 들어갑니다.`)}
        <details>
          <summary>자동으로 안 되면 직접 입력하기</summary>
          <div class="field"><span>서버 주소</span><code id="addr">${escapeHtml(serverAddress)}</code></div>
          <div class="field"><span>코드</span><code id="code">${escapeHtml(token)}</code></div>
        </details>
        <p class="hint">이미 계정이 있다면 이 링크로는 팀에 자동 합류되지 않습니다 — 팀 소유자·관리자에게 직접 참가를 요청하세요.</p>
      `;
  return renderInvitePageShell({ title, body, valid, deepLink });
}

/** 초대 설치 파일 다운로드 — 설치 초대/팀 초대 페이지가 공유한다(내려주는 파일은 똑같음). */
function downloadInstaller(req, res) {
  const files = { windows: ['client-windows-setup.exe', 'TangoTalk-Setup.exe'], android: ['client-android.apk', 'TangoTalk.apk'] };
  const entry = files[req.params.platform];
  if (!entry) return res.status(404).send('알 수 없는 플랫폼입니다.');
  const filePath = path.join(releasesDir, entry[0]);
  if (!fs.existsSync(filePath)) return res.status(404).send('아직 배포된 빌드가 없습니다.');
  res.download(filePath, entry[1]);
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

  app.get('/pair/:code', async (req, res) => {
    const { code } = req.params;
    if (/^\d{4}$/.test(code)) {
      if (!tryConsumeLegacyCode(code)) {
        return res.status(404).json({ error: '코드가 올바르지 않거나 만료되었습니다.' });
      }
      return res.json({ cert: getCertPem() });
    }

    // 4자리가 아니면 초대 링크 토큰으로 본다(설치 초대/팀 초대 둘 다 이 방식으로 인증서를
    // 받으므로 둘 다 확인한다 — 길이를 굳이 더 따지지 않는다, 어차피 둘 다 없으면 404).
    const link = await findInviteLinkByToken(code);
    if (isInviteLinkValid(link)) {
      await markInviteLinkUsed(link.id);
      return res.json({ cert: getCertPem() });
    }
    const teamLink = await findTeamInviteLinkByToken(code);
    if (isTeamInviteLinkValid(teamLink)) {
      // 팀 초대 링크는 인증서 발급 시점에는 아직 안 지운다 — 실제 팀 합류/등급 부여는
      // 회원가입(auth.js)에서 일어나고, 거기서 다시 한번 유효성을 확인하고 markTeamInviteLinkUsed를
      // 부른다. 여기서 먼저 소진해버리면 인증서만 받고 아직 가입 전인 상태에서 링크가
      // 무효화돼버릴 수 있다.
      return res.json({ cert: getCertPem() });
    }
    return res.status(404).json({ error: '코드가 올바르지 않거나 만료되었습니다.' });
  });

  app.post('/admin/generate', (req, res) => {
    if (!isLoopback(req)) return res.status(404).json({ error: '코드가 올바르지 않거나 만료되었습니다.' });
    const { code, expiresInMs } = generatePairingCode();
    res.json({ code, expiresInMs });
  });

  /** 초대 링크 안내 페이지 — 링크를 그냥 열어보는 사람용(브라우저). */
  app.get('/invite/:token', async (req, res) => {
    const link = await findInviteLinkByToken(req.params.token);
    res.type('html').send(
      renderInvitePage({ host: req.hostname, mainPort, token: req.params.token, link }),
    );
  });

  /** 설치 파일 다운로드 — 평문 HTTP라 브라우저 인증서 경고 없이 그대로 받아진다. 유효한
   * 초대 링크를 거쳐온 요청만 받는다(링크가 만료·취소됐으면 파일도 안 내려준다). */
  app.get('/invite/:token/download/:platform', async (req, res) => {
    const link = await findInviteLinkByToken(req.params.token);
    if (!isInviteLinkValid(link)) return res.status(404).send('만료되었거나 취소된 링크입니다.');
    downloadInstaller(req, res);
  });

  /** 팀 초대 링크 안내 페이지 — 링크를 그냥 열어보는 사람용(브라우저). */
  app.get('/team-invite/:token', async (req, res) => {
    const link = await findTeamInviteLinkByToken(req.params.token);
    res.type('html').send(
      renderTeamInvitePage({ host: req.hostname, mainPort, token: req.params.token, link }),
    );
  });

  /** 팀 초대 링크로 받는 설치 파일 다운로드 — 위 /invite/:token/download와 같은 파일. */
  app.get('/team-invite/:token/download/:platform', async (req, res) => {
    const link = await findTeamInviteLinkByToken(req.params.token);
    if (!isTeamInviteLinkValid(link)) return res.status(404).send('만료되었거나 취소된 링크입니다.');
    downloadInstaller(req, res);
  });

  const server = app.listen(port, () => {
    console.log(`[pairing] 페어링 부트스트랩 서버 대기 중 (평문 HTTP, 포트 ${port})`);
  });
  return server;
}
