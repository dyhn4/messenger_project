import crypto from 'node:crypto';
import http from 'node:http';

const CODE_TTL_MS = 5 * 60 * 1000;
const MAX_ATTEMPTS = 10; // 이 횟수만큼 틀리면 코드를 무효화한다(무작위 대입 방지).

/** 지금 유효한 페어링 코드 상태. 서버 콘솔에서 "pair"를 입력할 때마다 새로 만들어진다. */
let current = null; // { code, expiresAt, attemptsLeft }

export function generatePairingCode() {
  const code = crypto.randomInt(0, 10000).toString().padStart(4, '0');
  current = { code, expiresAt: Date.now() + CODE_TTL_MS, attemptsLeft: MAX_ATTEMPTS };
  return { code, expiresInMs: CODE_TTL_MS };
}

function tryConsume(code) {
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
 */
export function startPairingServer({ port, getCertPem }) {
  const server = http.createServer((req, res) => {
    const match = req.method === 'GET' && req.url?.match(/^\/pair\/(\d{4})$/);
    if (match && tryConsume(match[1])) {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ cert: getCertPem() }));
      return;
    }
    if (req.method === 'POST' && req.url === '/admin/generate' && isLoopback(req)) {
      const { code, expiresInMs } = generatePairingCode();
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ code, expiresInMs }));
      return;
    }
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: '코드가 올바르지 않거나 만료되었습니다.' }));
  });
  server.listen(port, () => {
    console.log(`[pairing] 페어링 부트스트랩 서버 대기 중 (평문 HTTP, 포트 ${port})`);
  });
  return server;
}
