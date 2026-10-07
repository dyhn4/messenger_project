import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import path from 'node:path';
import tls from 'node:tls';
import { createCertificateRenewer, createCertificateStore } from './acmeRenewal.js';
import { MAX_CLIENT_HELLO_BYTES, parseClientHello } from './clientHello.js';
import { getWebPublicUrl, setWebPublicUrl } from './webAddress.js';
import { webOrigin } from './webTlsConfig.js';

/**
 * 아이폰 등 앱이 없는 기기용 웹 앱 전용 HTTPS 포트(A안) — .env의 WEB_DOMAIN이 있을 때만 켜진다.
 *
 * iOS Safari는 공인 인증서가 아니면 웹 앱(홈 화면 추가·웹 푸시 포함)을 제대로 쓸 수 없다. 그런데 메인 포트(PORT)는 PC·안드로이드
 * 앱이 핀닝한 자체 서명 인증서(certs.js, pinned_tls.dart)라 바꿀 수 없다. 그래서 **같은 Express 앱**(웹 앱·API·socket.io·화상회의
 * 신호 /livekit·/pair)을 WEB_HTTPS_PORT(기본 443)에서 한 번 더 열고, 그 포트에만 Let's Encrypt 인증서를 받아 건다.
 *  - 인증서가 오기 전에는 자체 서명 인증서로 포트를 열어 둔다(TLS-ALPN-01 확인에 포트가 떠 있어야 한다).
 *  - 받거나 갱신하면 server.setSecureContext로 바로 바꾼다 — 재시작 없음.
 *  - Let's Encrypt 확인 방식 두 가지를 다 받는다: HTTP-01(ACME_HTTP_PORT, 기본 80 — 통신사가 80을 막기도 한다)과 TLS-ALPN-01(웹 포트).
 *  - 포트 충돌(IIS 등)·발급 실패는 로그와 관리자 콘솔 상태(GET /api/admin/web-certificate)로만 알리고, 메인 서버는 그대로 돈다.
 *  - HSTS(Strict-Transport-Security)는 기본으로 보내지 않는다(sendHsts — 이유는 startEnabled의 hsts 설명).
 *
 * 구조: 웹 포트에는 날 TCP 서버(앞단)가 듣고, 접속마다 첫 TLS 메시지(ClientHello)를 소비하지 않고 엿봐서 TLS-ALPN-01 확인
 * 접속("acme-tls/1" + 우리 도메인)만 확인용 TLS 서버로, 나머지는 전부 웹 HTTPS 서버로 넘긴다(emit('connection') — 소켓 자체를
 * 넘기므로 req.socket.remoteAddress가 실제 접속 IP 그대로다. 사내망 판단(authGuard.js isLanAddress)이 이 값에 기대므로 중요하다).
 * Node의 TLS 서버는 ALPN을 보고 인증서를 고를 수 없어서 이렇게 나눈다. 확인을 기다리는 동안이 아니면 엿보지도 않고 바로 넘긴다.
 */

export const HSTS_HEADER_VALUE = 'max-age=15552000';
export const ACME_TLS_ALPN_PROTOCOL = 'acme-tls/1';
const ACME_CHALLENGE_PREFIX = '/.well-known/acme-challenge/';
// 챌린지 토큰 모양(base64url) — acme.js의 ACME_TOKEN_PATTERN과 같은 규칙(이 모듈은 acme-client를 읽지 않으려고 따로 둔다).
const ACME_TOKEN_PATTERN = /^[A-Za-z0-9_-]{1,256}$/;
const TAG = '[web-tls]';

// ─────────────────────────────── HTTP-01 · http→https ───────────────────────────────

/** 리디렉션에 붙일 경로 — 요청 줄의 경로만 쓴다. 프록시 형식(GET http://…)·이상한 글자·지나치게 긴 경로는 첫 화면(/)으로. */
function redirectPath(url) {
  if (typeof url !== 'string' || !url.startsWith('/') || url.length > 2048 || /[^\x21-\x7e]/.test(url)) return '/';
  return url;
}

/**
 * ACME_HTTP_PORT(평문 HTTP)의 요청 처리. GET(·HEAD) /.well-known/acme-challenge/<토큰>은 지금 기다리는 토큰과 정확히 같을 때만
 * key authorization을 text/plain으로 답하고(아니면 404), 그 밖의 요청은 전부 https://WEB_DOMAIN[:포트]<같은 경로>로 보낸다.
 * 보낼 주소는 **설정한 도메인**으로만 만든다 — 요청의 Host 머리글을 쓰면 남의 사이트로 보내는 열린 리디렉션이 된다.
 * 302(임시)로 보낸다 — 301은 브라우저가 오래 기억해서, 나중에 WEB_HTTPS_PORT를 바꾸면 예전 포트로 계속 간다.
 */
export function createAcmeHttpHandler({ domain, httpsPort, getKeyAuthorization }) {
  const origin = webOrigin(domain, httpsPort);
  const plain = { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  return (req, res) => {
    const url = typeof req.url === 'string' ? req.url : '';
    if (url.startsWith(ACME_CHALLENGE_PREFIX)) {
      const token = url.slice(ACME_CHALLENGE_PREFIX.length);
      const readable = req.method === 'GET' || req.method === 'HEAD';
      const keyAuthorization = readable && ACME_TOKEN_PATTERN.test(token) ? getKeyAuthorization(token) : null;
      if (typeof keyAuthorization !== 'string') {
        res.writeHead(404, plain);
        res.end('Not Found');
        return;
      }
      res.writeHead(200, { ...plain, 'Content-Length': Buffer.byteLength(keyAuthorization) });
      res.end(req.method === 'HEAD' ? undefined : keyAuthorization);
      return;
    }
    res.writeHead(302, { ...plain, Location: `${origin}${redirectPath(url)}`, 'Content-Length': 0 });
    res.end();
  };
}

// ─────────────────────────────── 웹 포트 앞단(ClientHello 엿보기) ───────────────────────────────

/**
 * 웹 포트의 앞단 TCP 서버. [shouldPeek]()가 false면(평소) 접속을 받자마자 그대로 [httpsServer]에 넘긴다. true면(TLS-ALPN-01 확인을
 * 기다리는 동안) ClientHello를 다 받을 때까지 엿보고, [isAcmeHello](hello)가 참이면 [acmeServer]로, 아니면 [httpsServer]로 넘긴다.
 * 엿본 바이트는 소비하지 않고 소켓에 되돌려 넣어(unshift) 받는 서버가 처음부터 읽게 한다.
 *
 * 엿보기는 HTTPS 서버가 원래 감당하던 것보다 자원을 더 쓰지 않게 묶어 둔다: 접속당 [maxPeekBytes]·[maxPeekChunks] 조각·
 * [peekTimeoutMs](HTTPS 서버의 TLS 핸드셰이크 제한 120초보다 훨씬 짧다), 동시에 [maxConcurrentPeeks]개까지(넘으면 엿보지 않고
 * 바로 넘긴다). 형식이 이상하거나 덜 왔거나 너무 크면 모두 HTTPS 서버로 넘긴다 — 그 서버가 원래 하던 대로 처리한다.
 */
export function createTlsFrontRouter({
  httpsServer,
  acmeServer,
  shouldPeek,
  isAcmeHello,
  peekTimeoutMs = 5000,
  maxPeekBytes = MAX_CLIENT_HELLO_BYTES + 2048,
  maxPeekChunks = 64,
  maxConcurrentPeeks = 256,
}) {
  let peeking = 0;
  // https.createServer와 같은 기본값(Nagle 끔) — 넘겨받은 소켓은 이 서버의 옵션으로 만들어진다.
  const server = net.createServer({ noDelay: true }, (socket) => {
    if (!shouldPeek() || peeking >= maxConcurrentPeeks) {
      httpsServer.emit('connection', socket);
      return;
    }
    peeking += 1;
    const chunks = [];
    let total = 0;
    let settled = false;

    const settle = (target) => {
      if (settled) return;
      settled = true;
      peeking -= 1;
      clearTimeout(timer);
      socket.removeListener('data', onData);
      socket.removeListener('error', onAbort);
      socket.removeListener('end', onAbort);
      socket.removeListener('close', onClose);
      if (!target) return;
      // 'data'로 읽던 걸 멈추고 읽은 바이트를 되돌려 놓는다 — TLS 서버가 소켓을 감쌀 때 남은 바이트부터 읽는다.
      socket.pause();
      if (total) socket.unshift(chunks.length === 1 ? chunks[0] : Buffer.concat(chunks, total));
      target.emit('connection', socket);
    };
    const onData = (chunk) => {
      chunks.push(chunk);
      total += chunk.length;
      if (total > maxPeekBytes || chunks.length > maxPeekChunks) {
        settle(httpsServer);
        return;
      }
      const hello = parseClientHello(chunks.length === 1 ? chunk : Buffer.concat(chunks, total));
      if (hello.status === 'incomplete') return;
      settle(hello.status === 'complete' && isAcmeHello(hello) ? acmeServer : httpsServer);
    };
    // 엿보는 중에 끊거나 반만 닫은 접속은 어느 서버에도 넘기지 않고 정리한다.
    const onAbort = () => {
      settle(null);
      socket.destroy();
    };
    const onClose = () => settle(null);
    const timer = setTimeout(() => settle(httpsServer), peekTimeoutMs);

    socket.on('data', onData);
    socket.on('error', onAbort);
    socket.on('end', onAbort);
    socket.on('close', onClose);
  });
  return server;
}

/**
 * TLS-ALPN-01(RFC 8737) 확인 접속만 받는 TLS 서버 — "acme-tls/1"만 협상하고, 지금 기다리는 확인용 인증서(acmeIdentifier 확장)를
 * 보여 준 뒤 바로 닫는다(규격상 확인하는 쪽도 데이터를 보내지 않는다). 기다리는 확인이 없으면 핸드셰이크가 실패한다.
 */
export function createAcmeTlsServer(getContext) {
  const server = tls.createServer({
    ALPNProtocols: [ACME_TLS_ALPN_PROTOCOL],
    SNICallback: (servername, callback) => {
      const context = getContext(String(servername ?? '').toLowerCase());
      if (context) callback(null, context);
      else callback(new Error('기다리는 TLS-ALPN-01 확인이 없습니다.'));
    },
    handshakeTimeout: 10 * 1000,
  });
  server.on('secureConnection', (socket) => {
    socket.on('error', () => {});
    socket.setTimeout(5000, () => socket.destroy());
    socket.end();
  });
  server.on('tlsClientError', (_err, socket) => socket.destroy());
  return server;
}

/** 지금 기다리는 확인 응답들 — acme.js가 넣고 뺀다(토큰별). */
function createChallengeRegistry(domain) {
  const http01 = new Map(); // token → keyAuthorization
  const tlsAlpn01 = new Map(); // token → SecureContext
  return {
    'http-01': {
      add: (token, keyAuthorization) => http01.set(token, keyAuthorization),
      remove: (token) => http01.delete(token),
    },
    'tls-alpn-01': {
      add: (token, { key, cert }) => tlsAlpn01.set(token, tls.createSecureContext({ key, cert })),
      remove: (token) => tlsAlpn01.delete(token),
    },
    keyAuthorizationFor: (token) => http01.get(token) ?? null,
    alpnPending: () => tlsAlpn01.size > 0,
    alpnContextFor: (servername) => (servername === domain && tlsAlpn01.size ? [...tlsAlpn01.values()].pop() : null),
  };
}

// ─────────────────────────────── 포트 열기 ───────────────────────────────

function portErrorMessage(err, { port, label, envName, retryMs }) {
  const every = retryMs >= 60000 ? `${Math.round(retryMs / 60000)}분` : `${Math.max(1, Math.round(retryMs / 1000))}초`;
  const retry = `${every}마다 다시 열어 봅니다.`;
  if (err?.code === 'EADDRINUSE') {
    return (
      `포트 ${port}(${label})를 이미 다른 프로그램이 쓰고 있어 열지 못했습니다 — IIS("World Wide Web Publishing Service")·다른 웹 서버·` +
      `HTTP.sys 예약 등을 확인하세요(관리자 명령 프롬프트: netstat -ano | findstr :${port}). 그 프로그램을 끄거나 .env의 ${envName}를 ` +
      `다른 번호로 바꾸세요(공유기 포트포워딩도 함께). ${retry}`
    );
  }
  if (err?.code === 'EACCES') {
    return (
      `포트 ${port}(${label})를 열 권한이 없습니다 — Windows가 예약해 둔 포트 범위일 수 있습니다(netsh interface ipv4 show ` +
      `excludedportrange protocol=tcp). .env의 ${envName}를 다른 번호로 바꾸세요. ${retry}`
    );
  }
  return `포트 ${port}(${label})를 열지 못했습니다(${err?.code ?? err?.message ?? err}). ${retry}`;
}

/**
 * [server]를 연다. 실패하면(IIS가 80/443을 쥐고 있는 등) 이유를 한 번만 크게 남기고 [retryMs]마다 다시 시도한다 — 운영자가 그
 * 프로그램을 끄면 재시작 없이 붙는다. 첫 시도의 성공 여부로 resolve한다. 열리면 onUp, 실패할 때마다 onDown(이유).
 */
function listenWithRetry(server, { port, host, label, envName, retryMs, onUp, onDown, setTimer, log, timers }) {
  let reported = null;
  let first = true;
  return new Promise((resolveFirst) => {
    const done = (ok) => {
      if (!first) return;
      first = false;
      resolveFirst(ok);
    };
    const tryListen = () => {
      const onListening = () => {
        server.removeListener('error', onError);
        // 연 뒤에 나는 오류(드묾)로 프로세스가 죽지 않게 — 로그만.
        server.on('error', (err) => log.error(`${TAG} ${label} 포트 오류:`, err?.message ?? err));
        if (reported) log.log(`${TAG} ✔ 이제 포트 ${port}(${label})를 열었습니다.`);
        onUp();
        done(true);
      };
      const onError = (err) => {
        server.removeListener('listening', onListening);
        const message = portErrorMessage(err, { port, label, envName, retryMs });
        if (reported !== message) log.error(`${TAG} ⚠ ${message}`);
        reported = message;
        onDown(message);
        const retry = setTimer(tryListen, retryMs);
        retry?.unref?.();
        timers.add(retry);
        done(false);
      };
      server.once('listening', onListening);
      server.once('error', onError);
      try {
        server.listen(port, host);
      } catch (err) {
        server.removeListener('listening', onListening);
        server.removeListener('error', onError);
        onError(err);
      }
    };
    tryListen();
  });
}

function listenOnce(server, port, host) {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => {
      server.removeListener('error', reject);
      resolve();
    });
  });
}

// ─────────────────────────────── 시작 · 상태 ───────────────────────────────

let activeController = null;

function offStatus(lastError = null) {
  return {
    enabled: false,
    domain: null,
    status: 'off',
    staging: false,
    expiresAt: null,
    lastAttemptAt: null,
    lastError,
    nextAttemptAt: null,
    challenges: { http01: false, tlsAlpn01: false },
    webUrl: null,
  };
}

/**
 * 관리자 콘솔용 웹 인증서 상태(admin.js GET /api/admin/web-certificate).
 * { enabled, domain, status: 'off'|'pending'|'valid'|'expiring'|'error', staging, expiresAt, lastAttemptAt, lastError, nextAttemptAt,
 *   challenges: { http01, tlsAlpn01 }, webUrl, … } — 시각은 모두 ms(epoch), lastError는 한국어(비밀값 없음).
 */
export function getWebCertificateStatus() {
  return activeController ? activeController.status() : offStatus();
}

async function defaultCreateIssuer(options) {
  const { createAcmeIssuer } = await import('./acme.js');
  return createAcmeIssuer(options);
}

function logStartup(log, { origin, httpsPort, httpPort, staging, hstsBlockedByExternal, mainPort }) {
  const apps = mainPort ? `(PC·안드로이드 앱은 지금처럼 포트 ${mainPort})` : '';
  log.log(`${TAG} 웹 앱 전용 주소: ${origin} — 아이폰 등 앱이 없는 기기는 브라우저(Safari)로 이 주소를 엽니다${apps}.`);
  log.log(`${TAG}   공유기 포트포워딩(TCP):`);
  if (httpsPort === 443) {
    log.log(`${TAG}     외부 443 → 이 PC의 443 — 웹 앱 접속 + 인증서 확인(TLS-ALPN-01)`);
  } else {
    log.log(`${TAG}     외부 ${httpsPort} → 이 PC의 ${httpsPort} — 웹 앱 접속`);
    log.log(`${TAG}     외부 443 → 이 PC의 ${httpsPort} — 인증서 확인(TLS-ALPN-01 — Let's Encrypt는 443으로만 확인합니다. HTTP-01이 되면 없어도 됩니다)`);
  }
  if (httpPort) log.log(`${TAG}     외부 80 → 이 PC의 ${httpPort} — 인증서 확인(HTTP-01) + http:// 주소를 https로 이동`);
  else log.log(`${TAG}     (ACME_HTTP_PORT=0 — 80 포트는 쓰지 않고 TLS-ALPN-01(외부 443)로만 인증서를 확인합니다)`);
  log.log(`${TAG}   Windows 방화벽에서도 위 포트의 인바운드 TCP를 허용해야 합니다. 인증서는 Let's Encrypt에서 자동으로 받고, 만료 30일 전부터 자동으로 갱신합니다.`);
  if (staging) {
    log.log(`${TAG}   ACME_STAGING=1 — 시험용 인증서(브라우저가 신뢰하지 않음)로 포트포워딩만 확인하는 중입니다. 확인되면 .env에서 지우고 서버를 다시 시작하세요.`);
  }
  // HSTS를 켜 두었는데(sendHsts) 외부 접속 주소 때문에 막은 경우만 알린다 — 기본(끔)은 운영자가 할 일이 없으니 조용히.
  if (hstsBlockedByExternal) {
    log.log(
      `${TAG}   HSTS 머리글은 보내지 않습니다 — WEB_DOMAIN이 외부 접속 주소(EXTERNAL_ADDRESS)와 같은 이름이라, 보내면 브라우저가 이 ` +
        '이름의 평문 페어링 포트(초대 링크·도움말 http://…)까지 https로 바꿔 열어 버려 그 페이지가 열리지 않게 됩니다.',
    );
  }
}

/**
 * 웹 앱 전용 HTTPS 포트를 연다(index.js가 메인 서버를 띄운 뒤 부른다). WEB_DOMAIN(config.domain)이 없으면 **아무것도 하지 않는다**
 * — 포트·파일·타이머·acme-client 어느 것도 건드리지 않는다. 절대 던지지 않는다(실패는 로그와 상태로).
 *
 * @param {object} o
 * @param {Function} o.app Express 앱(메인 포트와 같은 것)
 * @param {import('socket.io').Server} [o.io] 같은 socket.io 서버 — 웹 포트에도 붙인다(io.attach).
 * @param {{key: string, cert: string}} o.fallbackTls 공인 인증서가 오기 전까지 쓸 자체 서명 인증서(certs.js)
 * @param {(server) => void} [o.attachUpgrade] 화상회의 신호 중계 등 'upgrade' 처리기를 붙인다(livekitProxy.js).
 * @param {object} o.config { domain, httpsPort, httpPort, email, staging, error } — config.js의 WEB_DOMAIN·WEB_HTTPS_PORT·
 *   ACME_HTTP_PORT(0이면 끔)·ACME_EMAIL·ACME_STAGING·WEB_TLS_CONFIG_ERROR
 * @param {boolean} [o.sendHsts] 공인 인증서가 걸린 동안 웹 포트 응답에 HSTS를 붙일지 — 기본 false(이유는 startEnabled의 hsts 설명).
 * @param {string|null} [o.externalHost] EXTERNAL_ADDRESS의 호스트 — WEB_DOMAIN과 같으면 sendHsts여도 HSTS를 보내지 않는다.
 * @param {string} o.certsDir 인증서·계정 키·시도 기록을 둘 폴더(certs/)
 * @param {object} [o.bind] 테스트용 — 실제로 열 주소·포트({ host, httpsPort, httpPort }, 0이면 아무 빈 포트).
 */
export async function startWebTls({
  app,
  io = null,
  fallbackTls,
  attachUpgrade = () => {},
  config,
  sendHsts = false,
  externalHost = null,
  mainPort = null,
  certsDir,
  createIssuer = defaultCreateIssuer,
  bind = {},
  serverOptions = {},
  now = () => Date.now(),
  setTimer = setTimeout,
  clearTimer = clearTimeout,
  log = console,
  listenRetryMs = 10 * 60 * 1000,
}) {
  if (!config?.domain) {
    const configError = config?.error ?? null;
    activeController = { status: () => offStatus(configError), ports: () => ({ https: null, http: null }), close: async () => {} };
    setWebPublicUrl(null);
    return activeController;
  }

  const cleanups = [];
  try {
    activeController = await startEnabled({
      app, io, fallbackTls, attachUpgrade, config, sendHsts, externalHost, mainPort, certsDir, createIssuer, bind, serverOptions,
      now, setTimer, clearTimer, log, listenRetryMs, cleanups,
    });
  } catch (err) {
    log.error(`${TAG} ⚠ 웹 앱 전용 포트를 준비하지 못했습니다 — 메인 서버(앱 접속)는 그대로 돕니다:`, err);
    for (const cleanup of cleanups.splice(0).reverse()) {
      try {
        cleanup();
      } catch {
        /* 정리 실패는 무시 */
      }
    }
    setWebPublicUrl(null);
    const lastError = `웹 앱 전용 포트를 준비하지 못했습니다: ${err?.message ?? err}`;
    activeController = {
      status: () => ({ ...offStatus(lastError), enabled: true, domain: config.domain, status: 'error', staging: !!config.staging }),
      ports: () => ({ https: null, http: null }),
      close: async () => {},
    };
  }
  return activeController;
}

async function startEnabled({
  app, io, fallbackTls, attachUpgrade, config, sendHsts, externalHost, mainPort, certsDir, createIssuer, bind, serverOptions,
  now, setTimer, clearTimer, log, listenRetryMs, cleanups,
}) {
  const { domain, httpsPort, httpPort, email, staging } = config;
  const origin = webOrigin(domain, httpsPort);
  // HSTS는 기본으로 끈다(sendHsts=false — index.js). HSTS는 포트를 가리지 않고 **이름** 전체에 걸리는데, 초대·팀 초대 링크는 요청받은
  // 호스트로 만든 평문 주소다(http://<요청 호스트>:PAIRING_PORT/invite/… — invites.js·teamInvites.js, 페어링 포트는 끌 수도 없다).
  // 그래서 웹 앱(이 포트, 호스트 = WEB_DOMAIN)에서 만들거나 본 링크는 http://WEB_DOMAIN:PAIRING_PORT/…가 되고, 웹 앱을 한 번 연
  // 브라우저(HSTS를 기억)는 그 링크를 https로 바꿔 평문 포트에 붙으므로 안내 페이지가 열리지 않는다. 초대·도움말 링크가 이 이름의 평문
  // 주소를 더는 쓰지 않게 바뀐 뒤에만 켠다. 켜더라도 WEB_DOMAIN이 외부 접속 주소(EXTERNAL_ADDRESS — 밖에서 열 초대 링크
  // http://외부주소:PAIRING_PORT/…, 앱의 도움말 링크)와 같은 이름이면 같은 이유로 보내지 않는다.
  const hstsBlockedByExternal = !!sendHsts && !!externalHost && String(externalHost).toLowerCase() === domain;
  const hsts = !!sendHsts && !hstsBlockedByExternal;
  const listening = { https: false, http: false };
  const portErrors = { https: null, http: null };
  const retryTimers = new Set();
  cleanups.push(() => retryTimers.forEach((t) => clearTimer(t)));

  logStartup(log, { origin, httpsPort, httpPort, staging, hstsBlockedByExternal, mainPort });

  const challenges = createChallengeRegistry(domain);
  const store = createCertificateStore({ certsDir });
  let issuerPromise = null;
  const issuerOptions = {
    domain,
    email,
    staging,
    accountKeyFile: path.join(certsDir, 'acme-account.key'),
    ports: { https: httpsPort, http: httpPort },
    log,
  };
  const getIssuer = () => {
    issuerPromise ??= Promise.resolve(createIssuer(issuerOptions)).catch((err) => {
      issuerPromise = null; // 다음 시도 때 다시 만든다.
      throw err;
    });
    return issuerPromise;
  };

  let webServer = null;
  // 공인 인증서가 지금 걸려 있고 웹 포트가 열려 있는지 — 공개 주소(webAddress.js)와 HSTS가 이것만 본다.
  const publicActive = () => listening.https && renewer.hasPublicCertificate();
  const refreshPublicUrl = () => setWebPublicUrl(publicActive() ? origin : null);

  const renewer = createCertificateRenewer({
    domain,
    staging,
    store,
    now,
    setTimer,
    clearTimer,
    log,
    issue: async ({ challengeTypes }) => (await getIssuer()).issue({ challengeTypes, challenges }),
    // 웹 포트가 없으면 인증서를 받아 봐야 쓸 데가 없다(한도만 쓴다). 웹 포트가 443이면 그 포트로 바로 확인되는 TLS-ALPN-01을 먼저.
    getChallengeTypes: () => {
      if (!listening.https) return [];
      const types = httpsPort === 443 ? ['tls-alpn-01', 'http-01'] : ['http-01', 'tls-alpn-01'];
      return types.filter((type) => (type === 'http-01' ? listening.http : true));
    },
    getWaitingReason: () => portErrors.https ?? '웹 앱 HTTPS 포트가 아직 열리지 않았습니다.',
    onCertificate: (cert) => {
      webServer?.setSecureContext({ key: cert.keyPem, cert: cert.certPem });
    },
    onChange: refreshPublicUrl,
  });
  cleanups.push(() => renewer.stop());

  const initial = renewer.current ? { key: renewer.current.keyPem, cert: renewer.current.certPem } : fallbackTls;
  webServer = https.createServer({ key: initial.key, cert: initial.cert, ...serverOptions }, (req, res) => {
    // HSTS를 켰다면(sendHsts — 기본은 끔, 위 hsts 설명) 브라우저가 이 이름을 앞으로 https로만 열게 한다 — 공인 인증서가 걸린 동안에만
    // (자체 서명일 때 보내면 의미가 없다). 하위 도메인(includeSubDomains)·preload는 넣지 않는다: WEB_DOMAIN이 iptime.org 같은 남의
    // 도메인 아래 이름일 수 있다.
    if (hsts && publicActive()) res.setHeader('Strict-Transport-Security', HSTS_HEADER_VALUE);
    app(req, res);
  });
  // 메인 포트와 같은 socket.io(실시간 채팅)와 화상회의 신호 중계를 이 포트에도 붙인다.
  io?.attach(webServer);
  attachUpgrade(webServer);
  // 웹 HTTPS 서버는 앞단이 넘겨주는 접속만 받지만, 127.0.0.1의 아무 빈 포트에서도 듣게 한다 — Node의 HTTP 서버는 listen해야
  // ('listening') 느린 요청 감시(headersTimeout·requestTimeout)를 켜기 때문이다. 이게 없으면 머리글을 아주 천천히 보내는 접속
  // (slowloris)이 끝없이 붙어 있을 수 있다.
  await listenOnce(webServer, 0, '127.0.0.1');
  cleanups.push(() => {
    webServer.closeAllConnections?.();
    webServer.close();
  });

  const acmeServer = createAcmeTlsServer((servername) => challenges.alpnContextFor(servername));
  cleanups.push(() => acmeServer.close());
  const front = createTlsFrontRouter({
    httpsServer: webServer,
    acmeServer,
    shouldPeek: () => challenges.alpnPending(),
    isAcmeHello: (hello) => hello.serverName === domain && hello.alpnProtocols.includes(ACME_TLS_ALPN_PROTOCOL),
  });
  cleanups.push(() => front.close());

  let acmeHttpServer = null;
  if (httpPort) {
    const getKeyAuthorization = (token) => challenges.keyAuthorizationFor(token);
    acmeHttpServer = http.createServer(createAcmeHttpHandler({ domain, httpsPort, getKeyAuthorization }));
    // 인터넷에 그대로 열리는 평문 포트라 느린 요청을 짧게 끊는다(확인 요청·리디렉션은 순식간에 끝난다).
    acmeHttpServer.headersTimeout = 10 * 1000;
    acmeHttpServer.requestTimeout = 15 * 1000;
    acmeHttpServer.keepAliveTimeout = 5 * 1000;
    cleanups.push(() => {
      acmeHttpServer.closeAllConnections?.();
      acmeHttpServer.close();
    });
  }

  const host = bind.host;
  const [httpsUp] = await Promise.all([
    listenWithRetry(front, {
      port: bind.httpsPort ?? httpsPort,
      host,
      label: '웹 앱 HTTPS',
      envName: 'WEB_HTTPS_PORT',
      retryMs: listenRetryMs,
      setTimer,
      log,
      timers: retryTimers,
      onUp: () => {
        listening.https = true;
        portErrors.https = null;
        refreshPublicUrl();
        renewer.poke();
      },
      onDown: (message) => {
        portErrors.https = `${message} 웹 앱 전용 주소와 인증서 발급은 꺼져 있습니다(메인 서버는 정상).`;
      },
    }),
    acmeHttpServer
      ? listenWithRetry(acmeHttpServer, {
          port: bind.httpPort ?? httpPort,
          host,
          label: '인증서 확인용 HTTP',
          envName: 'ACME_HTTP_PORT',
          retryMs: listenRetryMs,
          setTimer,
          log,
          timers: retryTimers,
          onUp: () => {
            listening.http = true;
            portErrors.http = null;
            renewer.poke();
          },
          onDown: (message) => {
            portErrors.http = message;
          },
        })
      : Promise.resolve(false),
  ]);
  if (!httpsUp) log.error(`${TAG} ⚠ 웹 앱 전용 포트가 열릴 때까지 웹 앱 주소와 인증서 발급은 꺼져 있습니다(메인 서버는 정상).`);
  refreshPublicUrl();
  renewer.start();

  return {
    status() {
      const r = renewer.status();
      const webPortDown = !listening.https;
      return {
        enabled: true,
        domain,
        status: webPortDown ? 'error' : r.status,
        staging: !!staging,
        expiresAt: r.expiresAt,
        lastAttemptAt: r.lastAttemptAt,
        lastError: webPortDown ? portErrors.https ?? r.lastError : r.lastError,
        nextAttemptAt: webPortDown ? null : r.nextAttemptAt,
        challenges: { http01: listening.http, tlsAlpn01: listening.https },
        webUrl: getWebPublicUrl(),
        ports: { https: httpsPort, http: httpPort },
        hsts: hsts && publicActive(),
        attempting: r.attempting,
        certificateStaging: r.certificateStaging,
        httpPortError: portErrors.http,
      };
    },
    /** 테스트용 — 실제로 열린 포트. */
    ports() {
      return {
        https: front.address()?.port ?? null,
        http: acmeHttpServer?.address()?.port ?? null,
        inner: webServer.address()?.port ?? null,
      };
    },
    /** 테스트용 — 연 것을 모두 닫는다(운영 중에는 부르지 않는다: 웹 서버를 닫으면 그 서버에 붙인 socket.io 엔진도 닫힌다). */
    async close() {
      for (const cleanup of cleanups.splice(0).reverse()) {
        try {
          cleanup();
        } catch {
          /* 닫는 중 오류는 무시 */
        }
      }
      setWebPublicUrl(null);
    },
  };
}
