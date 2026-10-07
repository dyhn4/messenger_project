// 웹 앱 전용 포트 켜기·끄기·설정·포트 문제(webTls.js, webTlsConfig.js)와 index.js·admin.js 연결 테스트 — `node --test test/*.test.js`.
// DB 없이 127.0.0.1에서만 돈다. index.js는 import하면 서버가 뜨므로 소스 글만 확인한다(bodyLimit.test.js와 같은 방식).
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { after, before, test } from 'node:test';
import tls from 'node:tls';
import express from 'express';
import selfsigned from 'selfsigned';
import { Server as SocketIoServer } from 'socket.io';
import { attachLivekitUpgradeProxy } from '../src/livekitProxy.js';
import { getWebPublicUrl } from '../src/webAddress.js';
import { getWebCertificateStatus, startWebTls } from '../src/webTls.js';
import { parseWebDomain, readWebTlsConfig, webOrigin } from '../src/webTlsConfig.js';

const DOMAIN = 'xxx.iptime.org';
const DAY = 24 * 60 * 60 * 1000;
const quietLog = { log() {}, warn() {}, error() {} };
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const listen = (server, port = 0) => new Promise((resolve, reject) => {
  server.once('error', reject);
  server.listen(port, '127.0.0.1', () => resolve(server.address().port));
});

let fallbackTls;
let issued;
const tempDirs = [];
before(async () => {
  const self = await selfsigned.generate([{ name: 'commonName', value: 'messenger-server' }], { keyType: 'ec', algorithm: 'sha256' });
  fallbackTls = { key: self.private, cert: self.cert };
  const leaf = await selfsigned.generate([{ name: 'commonName', value: DOMAIN }], {
    keyType: 'ec',
    algorithm: 'sha256',
    notAfterDate: new Date(Date.now() + 90 * DAY),
    extensions: [{ name: 'subjectAltName', altNames: [{ type: 2, value: DOMAIN }] }],
  });
  issued = { certPem: leaf.cert, keyPem: leaf.private };
});
after(() => {
  for (const dir of tempDirs) fs.rmSync(dir, { recursive: true, force: true });
});

function tempCertsDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'webtls-start-'));
  tempDirs.push(dir);
  return path.join(dir, 'certs');
}

/** 발급기 흉내 — 받은 인증 방식을 남기고 바로 인증서를 준다. */
function fakeIssuerFactory() {
  const calls = [];
  const factory = () => ({
    issue: async ({ challengeTypes }) => {
      calls.push(challengeTypes);
      return { ...issued, challengeType: challengeTypes[0] };
    },
  });
  return { factory, calls };
}

const enabledConfig = (extra = {}) => ({ domain: DOMAIN, httpsPort: 443, httpPort: 80, email: null, staging: false, error: null, ...extra });
const echoApp = (req, res) => res.end(`app:${req.url}`);

async function waitFor(fn, { timeoutMs = 10000, what = '조건' } = {}) {
  const until = Date.now() + timeoutMs;
  for (;;) {
    if (fn()) return;
    if (Date.now() > until) throw new Error(`${what}을(를) 기다리다 시간 초과`);
    await sleep(25);
  }
}

// ─────────────────────────────── 꺼져 있을 때 ───────────────────────────────

test('WEB_DOMAIN이 없으면 아무것도 하지 않는다 — 포트·파일·타이머·io 연결 없음, 상태는 off', async () => {
  const certsDir = tempCertsDir();
  const resourcesBefore = process.getActiveResourcesInfo().length;
  const io = {
    attach() {
      throw new Error('꺼져 있는데 socket.io를 붙였다');
    },
  };
  const ctl = await startWebTls({
    app: echoApp,
    io,
    fallbackTls,
    attachUpgrade: () => {
      throw new Error('꺼져 있는데 upgrade 처리기를 붙였다');
    },
    config: { domain: null, httpsPort: 443, httpPort: 80, email: null, staging: false, error: null },
    certsDir,
    createIssuer: () => {
      throw new Error('꺼져 있는데 발급기를 만들었다');
    },
    log: { log: () => assert.fail('로그를 남겼다'), warn: () => assert.fail('경고를 남겼다'), error: () => assert.fail('오류를 남겼다') },
  });
  assert.equal(process.getActiveResourcesInfo().length, resourcesBefore, '열린 포트·타이머가 늘지 않았다');
  assert.equal(fs.existsSync(certsDir), false, 'certs 폴더도 건드리지 않았다');
  assert.equal(getWebPublicUrl(), null);
  assert.deepEqual(getWebCertificateStatus(), {
    enabled: false,
    domain: null,
    status: 'off',
    staging: false,
    expiresAt: null,
    lastAttemptAt: null,
    lastError: null,
    nextAttemptAt: null,
    challenges: { http01: false, tlsAlpn01: false },
    webUrl: null,
  });
  assert.deepEqual(ctl.ports(), { https: null, http: null });
});

test('WEB_DOMAIN 형식이 잘못돼 꺼졌으면 상태에 그 이유를 보여 준다', async () => {
  const config = readWebTlsConfig({ WEB_DOMAIN: 'https://xxx.iptime.org:443/' }, { port: 3000, pairingPort: 3001 });
  assert.equal(config.domain, null);
  await startWebTls({ app: echoApp, fallbackTls, config, certsDir: tempCertsDir(), log: quietLog });
  const status = getWebCertificateStatus();
  assert.equal(status.status, 'off');
  assert.equal(status.enabled, false);
  assert.match(status.lastError, /WEB_DOMAIN 형식이 올바르지 않습니다/);
});

// ─────────────────────────────── 설정 읽기 ───────────────────────────────

test('설정: 비어 있으면 기능 off(경고 없음), 기본 포트 443·80, staging 아님', () => {
  assert.deepEqual(readWebTlsConfig({}, { port: 3000, pairingPort: 3001 }), {
    domain: null,
    httpsPort: 443,
    httpPort: 80,
    email: null,
    staging: false,
    error: null,
    warnings: [],
  });
  // 도메인이 없으면 나머지 값이 이상해도 아무 말 없이 off.
  const off = readWebTlsConfig({ WEB_HTTPS_PORT: 'abc', ACME_STAGING: 'maybe' }, { port: 3000, pairingPort: 3001 });
  assert.equal(off.domain, null);
  assert.equal(off.error, null);
  assert.deepEqual(off.warnings, []);
});

test('설정: 도메인 이름 정리(대소문자·끝 점·한글 도메인)와 거절(https://·포트·IP·와일드카드·점 없는 이름·밑줄)', () => {
  assert.equal(parseWebDomain('  XXX.iptime.ORG. '), DOMAIN);
  const korean = parseWebDomain('메신저.회사.kr');
  assert.match(korean, /^xn--[a-z0-9-]+\.xn--[a-z0-9-]+\.kr$/);
  assert.equal(korean, new URL('https://메신저.회사.kr/').hostname, '브라우저가 쓰는 퓨니코드와 같다');
  for (const bad of ['https://xxx.iptime.org', 'xxx.iptime.org:443', 'xxx.iptime.org/app', '203.0.113.5', '2001:db8::1', '*.iptime.org', 'localhost', 'my_server.iptime.org', '-x.iptime.org', '1.2.3.4.5', 'a b.com']) {
    assert.throws(() => parseWebDomain(bad), /WEB_DOMAIN/, bad);
  }
});

test('설정: 포트·이메일·staging — 웹 포트가 메인/페어링 포트와 겹치면 기능 off, 확인용 HTTP 포트 문제는 그 포트만 끈다', () => {
  const base = { WEB_DOMAIN: DOMAIN };
  const ports = { port: 3000, pairingPort: 3001 };
  const custom = readWebTlsConfig({ ...base, WEB_HTTPS_PORT: '8443', ACME_HTTP_PORT: '8080', ACME_EMAIL: 'ops@example.com', ACME_STAGING: '1' }, ports);
  assert.deepEqual(
    { domain: custom.domain, httpsPort: custom.httpsPort, httpPort: custom.httpPort, email: custom.email, staging: custom.staging, error: custom.error, warnings: custom.warnings },
    { domain: DOMAIN, httpsPort: 8443, httpPort: 8080, email: 'ops@example.com', staging: true, error: null, warnings: [] },
  );
  assert.equal(readWebTlsConfig({ ...base, ACME_HTTP_PORT: '0' }, ports).httpPort, 0, '0이면 HTTP-01 끔');

  for (const clash of ['3000', '3001']) {
    const conflicted = readWebTlsConfig({ ...base, WEB_HTTPS_PORT: clash }, ports);
    assert.equal(conflicted.domain, null, `웹 포트 ${clash}`);
    assert.match(conflicted.error, /겹칩니다/);
  }
  assert.match(readWebTlsConfig({ ...base, WEB_HTTPS_PORT: '70000' }, ports).error, /WEB_HTTPS_PORT/);
  assert.match(readWebTlsConfig({ ...base, WEB_HTTPS_PORT: '0' }, ports).error, /WEB_HTTPS_PORT/);

  for (const [value, pattern] of [['3000', /겹칩니다/], ['443', /겹칩니다/], ['eighty', /ACME_HTTP_PORT/]]) {
    const degraded = readWebTlsConfig({ ...base, ACME_HTTP_PORT: value }, ports);
    assert.equal(degraded.domain, DOMAIN, '기능은 켜 둔다');
    assert.equal(degraded.httpPort, 0);
    assert.match(degraded.warnings.join(' '), pattern);
  }
  const badEmail = readWebTlsConfig({ ...base, ACME_EMAIL: 'not-an-email' }, ports);
  assert.equal(badEmail.email, null);
  assert.match(badEmail.warnings[0], /ACME_EMAIL/);
  const badStaging = readWebTlsConfig({ ...base, ACME_STAGING: 'maybe' }, ports);
  assert.equal(badStaging.staging, false);
  assert.match(badStaging.warnings[0], /ACME_STAGING/);
  assert.equal(readWebTlsConfig({ ...base, ACME_STAGING: 'true' }, ports).staging, true);
  assert.equal(readWebTlsConfig({ ...base, ACME_STAGING: '0' }, ports).staging, false);
});

test('웹 앱 주소: 443이면 포트를 적지 않는다', () => {
  assert.equal(webOrigin(DOMAIN, 443), `https://${DOMAIN}`);
  assert.equal(webOrigin(DOMAIN, 8443), `https://${DOMAIN}:8443`);
});

// ─────────────────────────────── 포트 문제 ───────────────────────────────

test('웹 포트를 다른 프로그램이 쓰고 있으면: 던지지 않고 상태 error + 한국어 이유, 발급하지 않음 → 포트가 풀리면 재시작 없이 붙어 발급', async () => {
  const blocker = net.createServer();
  const blockedPort = await listen(blocker);
  const { factory, calls } = fakeIssuerFactory();
  const errors = [];
  let ctl;
  try {
    ctl = await startWebTls({
      app: echoApp,
      fallbackTls,
      config: enabledConfig(),
      certsDir: tempCertsDir(),
      createIssuer: factory,
      bind: { host: '127.0.0.1', httpsPort: blockedPort, httpPort: 0 },
      listenRetryMs: 200,
      log: { log() {}, warn() {}, error: (...args) => errors.push(args.join(' ')) },
    });
    let status = getWebCertificateStatus();
    assert.equal(status.status, 'error');
    assert.equal(status.challenges.tlsAlpn01, false);
    assert.equal(status.challenges.http01, true);
    assert.match(status.lastError, new RegExp(`포트 ${blockedPort}.*이미 다른 프로그램`));
    assert.match(status.lastError, /메인 서버는 정상/);
    assert.ok(errors.some((line) => /IIS/.test(line) && /netstat/.test(line)), '콘솔에 확인 방법을 남겼다');
    await sleep(500);
    assert.equal(calls.length, 0, '쓸 데 없는 인증서는 받지 않는다(한도 보호)');
    assert.equal(errors.filter((line) => line.includes('이미 다른 프로그램')).length, 1, '같은 이유는 한 번만 크게 남긴다');
    assert.equal(getWebPublicUrl(), null);

    await new Promise((resolve) => blocker.close(resolve));
    await waitFor(() => getWebCertificateStatus().status === 'valid', { what: '포트가 풀린 뒤 발급' });
    status = getWebCertificateStatus();
    assert.equal(status.challenges.tlsAlpn01, true);
    assert.deepEqual(calls[0], ['tls-alpn-01', 'http-01']);
    assert.equal(getWebPublicUrl(), `https://${DOMAIN}`);
  } finally {
    await ctl?.close();
    if (blocker.listening) blocker.close();
  }
});

test('확인용 HTTP 포트(80)만 막혀 있으면 TLS-ALPN-01만으로 진행한다', async () => {
  const blocker = net.createServer();
  const blockedPort = await listen(blocker);
  const { factory, calls } = fakeIssuerFactory();
  let ctl;
  try {
    ctl = await startWebTls({
      app: echoApp,
      fallbackTls,
      config: enabledConfig({ httpsPort: 8443 }),
      certsDir: tempCertsDir(),
      createIssuer: factory,
      bind: { host: '127.0.0.1', httpsPort: 0, httpPort: blockedPort },
      listenRetryMs: 60 * 1000,
      log: quietLog,
    });
    await waitFor(() => getWebCertificateStatus().status === 'valid', { what: '발급' });
    const status = getWebCertificateStatus();
    assert.deepEqual(status.challenges, { http01: false, tlsAlpn01: true });
    assert.match(status.httpPortError, new RegExp(`포트 ${blockedPort}`));
    assert.deepEqual(calls[0], ['tls-alpn-01']);
    assert.equal(getWebPublicUrl(), `https://${DOMAIN}:8443`, '443이 아니면 주소에 포트를 붙인다');
  } finally {
    await ctl?.close();
    blocker.close();
  }
});

test('ACME_HTTP_PORT=0이면 HTTP 포트를 열지 않는다', async () => {
  const { factory, calls } = fakeIssuerFactory();
  let ctl;
  try {
    ctl = await startWebTls({
      app: echoApp,
      fallbackTls,
      config: enabledConfig({ httpPort: 0 }),
      certsDir: tempCertsDir(),
      createIssuer: factory,
      bind: { host: '127.0.0.1', httpsPort: 0 },
      log: quietLog,
    });
    await waitFor(() => getWebCertificateStatus().status === 'valid', { what: '발급' });
    assert.equal(ctl.ports().http, null);
    assert.deepEqual(getWebCertificateStatus().challenges, { http01: false, tlsAlpn01: true });
    assert.deepEqual(calls[0], ['tls-alpn-01']);
  } finally {
    await ctl?.close();
  }
});

test('준비 중 예외가 나도 던지지 않고 상태 error로 남는다(메인 서버 시작을 막지 않는다)', async () => {
  const ctl = await startWebTls({
    app: echoApp,
    fallbackTls: { key: 'broken', cert: 'broken' },
    config: enabledConfig(),
    certsDir: tempCertsDir(),
    bind: { host: '127.0.0.1', httpsPort: 0, httpPort: 0 },
    log: quietLog,
  });
  const status = getWebCertificateStatus();
  assert.equal(status.enabled, true);
  assert.equal(status.status, 'error');
  assert.match(status.lastError, /준비하지 못했습니다/);
  assert.equal(getWebPublicUrl(), null);
  await ctl.close();
});

test('웹 포트도 메인 포트처럼 느린 요청(slowloris)을 끊는다 — 앞단이 넘긴 접속에도 HTTPS 서버의 headersTimeout이 걸린다', async () => {
  const { factory } = fakeIssuerFactory();
  let ctl;
  try {
    ctl = await startWebTls({
      app: echoApp,
      fallbackTls,
      config: enabledConfig({ httpPort: 0 }),
      certsDir: tempCertsDir(),
      createIssuer: factory,
      bind: { host: '127.0.0.1', httpsPort: 0 },
      serverOptions: { connectionsCheckingInterval: 100, headersTimeout: 500, requestTimeout: 800 },
      log: quietLog,
    });
    const started = Date.now();
    const closedAfter = await new Promise((resolve) => {
      const socket = tls.connect({ host: '127.0.0.1', port: ctl.ports().https, servername: DOMAIN, rejectUnauthorized: false }, () => {
        socket.write(`GET / HTTP/1.1\r\nHost: ${DOMAIN}\r\n`);
        const drip = setInterval(() => socket.writable && socket.write('X-Slow: 1\r\n'), 150);
        socket.on('close', () => {
          clearInterval(drip);
          resolve(Date.now() - started);
        });
      });
      socket.on('error', () => {});
      setTimeout(() => {
        socket.destroy();
        resolve(Infinity);
      }, 5000).unref();
    });
    assert.ok(closedAfter < 3000, `머리글을 끝내지 않는 접속을 끊었다(${closedAfter}ms)`);
  } finally {
    await ctl?.close();
  }
});

test('index.js와 같은 구성: 웹 포트로 Express 앱·socket.io·/livekit 화상회의 신호 중계가 모두 된다(HSTS는 index.js처럼 끔)', async () => {
  // 가짜 LiveKit(평문) — /rtc WebSocket 업그레이드에 101로 답한다.
  const livekit = http.createServer((req, res) => res.end('livekit'));
  livekit.on('upgrade', (req, socket) => {
    socket.end(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nX-Upstream-Path: ${req.url}\r\n\r\n`);
  });
  const livekitPort = await listen(livekit);
  const app = express();
  app.get('/hello', (req, res) => res.json({ ok: true, secure: req.secure }));
  const io = new SocketIoServer();
  const { factory } = fakeIssuerFactory();
  let ctl;
  try {
    ctl = await startWebTls({
      app,
      io,
      fallbackTls,
      attachUpgrade: (server) => attachLivekitUpgradeProxy(server, livekitPort),
      config: enabledConfig({ httpPort: 0 }),
      sendHsts: false,
      certsDir: tempCertsDir(),
      createIssuer: factory,
      bind: { host: '127.0.0.1', httpsPort: 0 },
      log: quietLog,
    });
    await waitFor(() => getWebCertificateStatus().status === 'valid', { what: '발급' });
    const port = ctl.ports().https;

    const res = await new Promise((resolve, reject) => {
      https
        .get({ host: '127.0.0.1', port, path: '/hello', servername: DOMAIN, rejectUnauthorized: false, agent: false }, (r) => {
          let body = '';
          r.on('data', (c) => (body += c));
          r.on('end', () => resolve({ headers: r.headers, body: JSON.parse(body) }));
        })
        .on('error', reject);
    });
    assert.deepEqual(res.body, { ok: true, secure: true });
    assert.equal(res.headers['strict-transport-security'], undefined, '공인 인증서가 걸려도 HSTS는 보내지 않는다(평문 초대 링크 보호)');

    const upgrade = (path) =>
      new Promise((resolve, reject) => {
        const socket = tls.connect({ host: '127.0.0.1', port, servername: DOMAIN, rejectUnauthorized: false }, () => {
          socket.write(
            `GET ${path} HTTP/1.1\r\nHost: ${DOMAIN}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n` +
              `Sec-WebSocket-Key: ${crypto.randomBytes(16).toString('base64')}\r\nSec-WebSocket-Version: 13\r\n\r\n`,
          );
        });
        let head = '';
        socket.setEncoding('latin1');
        socket.on('data', (c) => {
          head += c;
          if (head.includes('\r\n\r\n')) {
            socket.destroy();
            resolve(head);
          }
        });
        socket.on('error', reject);
      });
    const livekitHead = await upgrade('/livekit/rtc?access_token=abc');
    assert.match(livekitHead, /^HTTP\/1\.1 101/);
    assert.match(livekitHead, /X-Upstream-Path: \/rtc\?access_token=abc/i, '/livekit을 떼고 LiveKit에 넘겼다');
    const socketIoHead = await upgrade('/socket.io/?EIO=4&transport=websocket');
    assert.match(socketIoHead, /^HTTP\/1\.1 101/);
  } finally {
    await ctl?.close();
    io.close();
    livekit.close();
  }
});

// ─────────────────────────────── index.js · admin.js 연결 ───────────────────────────────

const indexSource = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
const adminSource = fs.readFileSync(new URL('../src/admin.js', import.meta.url), 'utf8');
const codeOnly = (source) => source.replace(/^\s*\/\/.*$/gm, '');

test('index.js: /server-info가 webUrl(공인 인증서가 걸린 웹 앱 주소)을 알려 준다', () => {
  const route = /app\.get\('\/server-info'[\s\S]*?\n\);/.exec(codeOnly(indexSource))?.[0];
  assert.ok(route, '/server-info 라우트를 찾지 못했다');
  assert.match(route, /webUrl: getWebPublicUrl\(\)/);
  assert.match(route, /externalUrl: EXTERNAL_ADDRESS\?\.url \?\? null/);
});

test('index.js: 메인 서버를 띄운 뒤 웹 포트를 켜고, 같은 app·io·화상회의 중계·설정을 넘기며, 실패해도 서버를 멈추지 않는다', () => {
  const code = codeOnly(indexSource);
  const listenAt = code.indexOf('httpServer.listen(PORT');
  const startAt = code.indexOf('startWebTls({');
  assert.ok(listenAt >= 0 && startAt > listenAt, '메인 포트를 먼저 연다');
  const call = code.slice(startAt, code.indexOf('});', startAt) + 3);
  for (const part of [
    'app,',
    'io,',
    'fallbackTls: tls,',
    'attachUpgrade: (server) => attachLivekitUpgradeProxy(server, LIVEKIT_PORT)',
    'domain: WEB_DOMAIN',
    'httpsPort: WEB_HTTPS_PORT',
    'httpPort: ACME_HTTP_PORT',
    'email: ACME_EMAIL',
    'staging: ACME_STAGING',
    'error: WEB_TLS_CONFIG_ERROR',
    // HSTS는 끈다 — 초대 링크가 http://WEB_DOMAIN:PAIRING_PORT/…일 수 있어서(webTls.js). 켜기로 했다면 이 줄도 함께 바꾼다.
    'sendHsts: false,',
    'externalHost: EXTERNAL_ADDRESS?.host ?? null',
    'certsDir,',
  ]) {
    assert.ok(call.includes(part), `startWebTls에 ${part}`);
  }
  assert.match(code.slice(startAt), /^startWebTls\(\{[\s\S]*?\}\)\.catch\(/, '혹시 던져도 잡는다');
  assert.doesNotMatch(code, /await startWebTls/, '메인 서버 시작을 기다리게 하지 않는다');
});

test('admin.js: 웹 인증서 상태 라우트는 서버 운영자 확인(/admin 미들웨어) 뒤에 있고 상태만 돌려준다', () => {
  const code = codeOnly(adminSource);
  const guardAt = code.indexOf("router.use('/admin', async (req, res, next) => {");
  const routeAt = code.indexOf("router.get('/admin/web-certificate'");
  assert.ok(guardAt >= 0 && routeAt > guardAt, '운영자 확인 뒤에 둔다');
  assert.ok(routeAt < code.indexOf('return router;'), 'createAdminRouter 안에 있다');
  assert.match(code.slice(routeAt, routeAt + 200), /res\.json\(getWebCertificateStatus\(\)\)/);
});
