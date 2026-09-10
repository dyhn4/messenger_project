import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import express from 'express';
import { findInviteLinkByToken, isInviteLinkValid, markInviteLinkUsed } from './db/queries/inviteLinks.js';
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

/** Chrome "안전하지 않은 다운로드가 차단됨" 대응 안내에 쓰는 도식(실제 Chrome 화면을 그대로
 * 베낀 스크린샷이 아니라, 어디를 눌러야 하는지만 보여주는 단순화된 그림). 정식 코드 서명
 * 인증서 없이 배포하는 실행파일이라 Chrome/Windows 양쪽 모두 자체적으로 못 없애는 경고다. */
const CHROME_BLOCK_DIAGRAM = `
<svg width="320" height="90" viewBox="0 0 320 90" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="다운로드 알림에서 점 세 개 메뉴를 눌러 유지를 선택하는 그림">
  <rect x="1" y="1" width="318" height="44" rx="8" fill="#f1f3f5" stroke="#ced4da"/>
  <circle cx="22" cy="23" r="10" fill="#e03131"/>
  <text x="22" y="27" font-size="12" fill="#fff" font-weight="bold" text-anchor="middle">!</text>
  <text x="42" y="19" font-size="11" fill="#495057">차단됨</text>
  <text x="42" y="33" font-size="10" fill="#868e96">messenger-setup.exe</text>
  <circle cx="296" cy="23" r="15" fill="#fff" stroke="#4c6ef5" stroke-width="2"/>
  <text x="296" y="28" font-size="16" fill="#4c6ef5" text-anchor="middle">⋮</text>
  <rect x="176" y="52" width="126" height="34" rx="6" fill="#fff" stroke="#ced4da"/>
  <text x="188" y="73" font-size="11" fill="#1a1a1a">유지(다운로드 유지)</text>
  <line x1="288" y1="40" x2="245" y2="52" stroke="#4c6ef5" stroke-width="2" marker-end="url(#arrow1)"/>
  <defs><marker id="arrow1" markerWidth="8" markerHeight="8" refX="4" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8 Z" fill="#4c6ef5"/></marker></defs>
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

const DOWNLOAD_WARNING_GUIDE = `
<details class="warn-guide">
  <summary>다운로드·설치 중 경고 화면이 뜬다면?</summary>
  <p class="hint">정식 코드 서명 인증서 없이 배포하는 실행 파일이라 아래 두 화면이 뜰 수 있습니다.
  악성코드 검사와는 무관하게 항상 나오는 절차이니, 그대로 진행해도 안전합니다.</p>
  <p class="guide-step"><b>① Chrome이 "안전하지 않은 다운로드가 차단됨"이라고 뜨면</b></p>
  ${CHROME_BLOCK_DIAGRAM}
  <p class="hint">화면 아래 다운로드 알림에서 <b>점 세 개(⋮)</b>를 누르고 <b>"유지"</b>(또는 "다운로드 유지")를 선택하세요.</p>
  <p class="guide-step"><b>② 설치 파일 실행 시 "Windows에서 PC를 보호했습니다"가 뜨면</b></p>
  ${SMARTSCREEN_DIAGRAM}
  <p class="hint"><b>"추가 정보"</b>를 누르면 <b>"실행"</b> 버튼이 나타납니다 — 눌러서 설치를 계속하세요. (안드로이드는 설치 전 "출처를 알 수 없는 앱" 허용을 한 번 물어봅니다 — "허용"을 누르면 됩니다.)</p>
</details>`;

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
        ${DOWNLOAD_WARNING_GUIDE}
        <p class="notice">설치가 끝나면 이 페이지를 새로고침해서 회원가입 하세요.<br><span class="notice-sub">서버 주소와 코드가 자동으로 입력됩니다.</span></p>
        <details>
          <summary>자동으로 안 되면 직접 입력하기</summary>
          <div class="field"><span>서버 주소</span><code id="addr">${escapeHtml(serverAddress)}</code></div>
          <div class="field"><span>코드</span><code id="code">${escapeHtml(token)}</code></div>
        </details>
        <p class="hint">이미 계정이 있다면 바로 로그인하시고, 처음이라면 회원가입 후 팀 소유자·관리자에게 팀 참가를 요청하세요.</p>
      `;
  return `<!doctype html>
<html lang="ko"><head><meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${title}</title>
<style>
  body { font-family: -apple-system, 'Segoe UI', sans-serif; max-width: 480px; margin: 40px auto; padding: 0 20px; color: #1a1a1a; }
  h1 { font-size: 22px; }
  .btn { display: block; text-align: center; padding: 14px; margin: 10px 0; background: #4c6ef5; color: #fff;
         text-decoration: none; border-radius: 10px; font-weight: bold; }
  .field { display: flex; justify-content: space-between; align-items: center; background: #f1f3f5; padding: 10px 14px;
            border-radius: 8px; margin: 8px 0; }
  .field code { font-size: 14px; word-break: break-all; }
  .hint { color: #888; font-size: 13px; }
  .warn { color: #e03131; font-weight: bold; }
  details { margin: 12px 0; color: #555; }
  summary { cursor: pointer; }
  .warn-guide { background: #fff9db; border-radius: 10px; padding: 4px 16px 12px; }
  .warn-guide summary { font-weight: bold; padding: 8px 0; }
  .guide-step { margin: 14px 0 6px; }
  .warn-guide svg { display: block; max-width: 100%; height: auto; margin: 4px 0; }
  .notice { background: #ebfbee; color: #2b8a3e; border: 2px solid #2b8a3e; border-radius: 10px;
            padding: 14px 16px; margin: 16px 0; font-size: 18px; font-weight: bold; text-align: center; }
  .notice-sub { display: inline-block; margin-top: 6px; color: #2b8a3e; font-size: 13px; font-weight: normal; }
</style></head>
<body><h1>${title}</h1>${body}
${valid ? `<script>try { window.location.href = ${JSON.stringify(deepLink)}; } catch (e) {}</script>` : ''}
</body></html>`;
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

    // 4자리가 아니면 초대 링크 토큰으로 본다(길이를 굳이 더 따지지 않는다 — 어차피 DB에
    // 없으면 아래에서 404가 난다).
    const link = await findInviteLinkByToken(code);
    if (!isInviteLinkValid(link)) {
      return res.status(404).json({ error: '코드가 올바르지 않거나 만료되었습니다.' });
    }
    await markInviteLinkUsed(link.id);
    res.json({ cert: getCertPem() });
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

    const files = { windows: ['client-windows-setup.exe', 'TangoTalk-Setup.exe'], android: ['client-android.apk', 'TangoTalk.apk'] };
    const entry = files[req.params.platform];
    if (!entry) return res.status(404).send('알 수 없는 플랫폼입니다.');
    const filePath = path.join(releasesDir, entry[0]);
    if (!fs.existsSync(filePath)) return res.status(404).send('아직 배포된 빌드가 없습니다.');
    res.download(filePath, entry[1]);
  });

  const server = app.listen(port, () => {
    console.log(`[pairing] 페어링 부트스트랩 서버 대기 중 (평문 HTTP, 포트 ${port})`);
  });
  return server;
}
