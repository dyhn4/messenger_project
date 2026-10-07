// 웹 인증서 발급 전체 흐름 테스트 — `node --test test/*.test.js`. 진짜 acme-client(acme.js)가 127.0.0.1의 가짜 ACME 서버와
// 주고받고, 가짜 서버는 Let's Encrypt처럼 우리 포트(HTTP-01·TLS-ALPN-01)에 실제로 접속해 확인한 뒤 테스트용 CA로 인증서를 준다.
// 바깥 네트워크·DB는 쓰지 않는다.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import os from 'node:os';
import path from 'node:path';
import { after, before, test } from 'node:test';
import tls from 'node:tls';
import acme from 'acme-client';
import selfsigned from 'selfsigned';
import { Server as SocketIoServer } from 'socket.io';
import { AcmeIssueError, RATE_LIMITED, createAcmeIssuer } from '../src/acme.js';
import { getWebPublicUrl } from '../src/webAddress.js';
import { HSTS_HEADER_VALUE, getWebCertificateStatus, startWebTls } from '../src/webTls.js';

const DOMAIN = 'xxx.iptime.org';
const DAY = 24 * 60 * 60 * 1000;
const quietLog = { log() {}, warn() {}, error() {} };
const listen = (server) => new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

let ca;
let fallbackTls;
const tempDirs = [];
before(async () => {
  ca = await selfsigned.generate([{ name: 'commonName', value: 'Test ACME CA' }], {
    keyType: 'ec',
    algorithm: 'sha256',
    notAfterDate: new Date(Date.now() + 365 * DAY),
    extensions: [
      { name: 'basicConstraints', cA: true, critical: true },
      { name: 'keyUsage', keyCertSign: true, cRLSign: true, digitalSignature: true, critical: true },
    ],
  });
  const self = await selfsigned.generate([{ name: 'commonName', value: 'messenger-server' }], {
    keyType: 'ec',
    algorithm: 'sha256',
    extensions: [{ name: 'subjectAltName', altNames: [{ type: 2, value: 'localhost' }, { type: 7, ip: '127.0.0.1' }] }],
  });
  fallbackTls = { key: self.private, cert: self.cert };
});
after(() => {
  for (const dir of tempDirs) fs.rmSync(dir, { recursive: true, force: true });
});

function tempCertsDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'webtls-flow-'));
  tempDirs.push(dir);
  return path.join(dir, 'certs');
}

/**
 * Let's Encrypt 흉내 — 디렉터리·nonce·계정·주문·인증·챌린지·발급. 챌린지 완료 알림을 받으면 그 자리에서 우리 포트에 접속해 확인하고
 * 결과(valid/invalid)를 바로 정한다(테스트가 acme-client의 대기 간격을 기다리지 않게). [behavior]로 한도·실패를 흉내 낸다.
 */
async function startFakeAcme(behavior = {}) {
  const fake = { requests: [], validations: [], issued: [], contacts: [], certificateKeyPem: null, behavior };
  let resolveTargets;
  const targetsReady = new Promise((resolve) => (resolveTargets = resolve));
  fake.setTargets = (targets) => resolveTargets(targets);
  let jwk = null;
  let nonce = 0;
  let seq = 0;
  const orders = new Map();
  const chains = new Map();
  const challenges = new Map();

  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () =>
      handle(req, res, Buffer.concat(chunks).toString()).catch((err) => {
        res.writeHead(500);
        res.end(String(err?.stack ?? err));
      }),
    );
  });
  const base = `http://127.0.0.1:${await listen(server)}`;
  fake.directoryUrl = `${base}/directory`;
  fake.close = () => {
    server.closeAllConnections();
    server.close();
  };

  const reply = (res, status, body, headers = {}) => {
    const problem = body && typeof body === 'object' && String(body.type ?? '').startsWith('urn:');
    res.writeHead(status, { 'Replay-Nonce': `nonce-${++nonce}`, 'Content-Type': problem ? 'application/problem+json' : 'application/json', ...headers });
    res.end(body === undefined ? '' : JSON.stringify(body));
  };
  const publicChallenge = ({ type, url, token, status, error }) => ({ type, url, token, status, ...(error ? { error } : {}) });
  const decode = (s) => JSON.parse(Buffer.from(s, 'base64url').toString('utf8'));

  async function validate(type, keyAuthorization) {
    if (behavior.failValidation?.includes(type)) return false;
    const targets = await targetsReady;
    if (type === 'http-01') {
      const token = keyAuthorization.split('.')[0];
      const body = await new Promise((resolve) => {
        http
          .get({ host: '127.0.0.1', port: targets.http, path: `/.well-known/acme-challenge/${token}`, headers: { Host: DOMAIN } }, (res) => {
            let data = '';
            res.on('data', (c) => (data += c));
            res.on('end', () => resolve(res.statusCode === 200 ? data : null));
          })
          .on('error', () => resolve(null));
      });
      return body === keyAuthorization;
    }
    if (type === 'tls-alpn-01') {
      return new Promise((resolve) => {
        const socket = tls.connect({ host: '127.0.0.1', port: targets.tls, servername: DOMAIN, ALPNProtocols: ['acme-tls/1'], rejectUnauthorized: false }, () => {
          const cert = socket.getPeerX509Certificate();
          let ok = false;
          try {
            ok = socket.alpnProtocol === 'acme-tls/1' && acme.crypto.isAlpnCertificateAuthorizationValid(cert.toString(), keyAuthorization);
          } catch {
            ok = false;
          }
          socket.destroy();
          resolve(ok);
        });
        socket.on('error', () => resolve(false));
      });
    }
    return false;
  }

  async function issueChain() {
    const keyPem = fake.certificateKeyPem;
    const publicKey = crypto.createPublicKey(keyPem).export({ type: 'spki', format: 'pem' });
    const leaf = await selfsigned.generate([{ name: 'commonName', value: DOMAIN }], {
      keyType: 'ec',
      algorithm: 'sha256',
      keyPair: { privateKey: keyPem, publicKey },
      ca: { key: ca.private, cert: ca.cert },
      notAfterDate: new Date(Date.now() + 90 * DAY),
      extensions: [{ name: 'subjectAltName', altNames: [{ type: 2, value: DOMAIN }] }, { name: 'extKeyUsage', serverAuth: true }],
    });
    fake.issued.push(leaf.cert);
    return `${leaf.cert.trim()}\n${ca.cert.trim()}\n`;
  }

  async function handle(req, res, raw) {
    const { pathname } = new URL(req.url, base);
    fake.requests.push(`${req.method} ${pathname}`);
    if (pathname === '/directory') {
      return reply(res, 200, {
        newNonce: `${base}/new-nonce`,
        newAccount: `${base}/new-account`,
        newOrder: `${base}/new-order`,
        revokeCert: `${base}/revoke-cert`,
        keyChange: `${base}/key-change`,
        meta: { termsOfService: `${base}/terms` },
      });
    }
    if (pathname === '/new-nonce') return reply(res, 200);
    const jws = JSON.parse(raw);
    const header = decode(jws.protected);
    const payload = jws.payload ? decode(jws.payload) : null;
    let m;
    if (pathname === '/new-account') {
      fake.contacts.push(payload.contact ?? null);
      fake.termsOfServiceAgreed = payload.termsOfServiceAgreed;
      if (behavior.rejectContact && payload.contact) {
        return reply(res, 400, { type: 'urn:ietf:params:acme:error:invalidContact', detail: 'contact email has forbidden domain' });
      }
      jwk = header.jwk;
      return reply(res, 201, { status: 'valid' }, { Location: `${base}/account/1` });
    }
    if (pathname === '/new-order') {
      if (behavior.rateLimit) {
        const { status = 429, headers = {}, body } = behavior.rateLimit;
        return reply(res, status, body ?? { type: RATE_LIMITED, detail: 'too many certificates (50) already issued for "iptime.org" in the last 168h0m0s' }, headers);
      }
      const id = ++seq;
      const order = { status: 'pending', identifiers: payload.identifiers, authorizations: [`${base}/authz/${id}`], finalize: `${base}/finalize/${id}` };
      orders.set(id, order);
      for (const type of ['http-01', 'dns-01', 'tls-alpn-01']) {
        challenges.set(`${id}-${type}`, { type, url: `${base}/chall/${id}-${type}`, token: crypto.randomBytes(32).toString('base64url'), status: 'pending' });
      }
      return reply(res, 201, order, { Location: `${base}/order/${id}` });
    }
    if ((m = /^\/authz\/(\d+)$/.exec(pathname))) {
      const list = ['http-01', 'dns-01', 'tls-alpn-01'].map((type) => publicChallenge(challenges.get(`${m[1]}-${type}`)));
      return reply(res, 200, { identifier: { type: 'dns', value: DOMAIN }, status: 'pending', challenges: list });
    }
    if ((m = /^\/chall\/(.+)$/.exec(pathname))) {
      const challenge = challenges.get(m[1]);
      if (payload && challenge.status === 'pending') {
        const thumbprint = crypto.createHash('sha256').update(JSON.stringify(jwk)).digest('base64url');
        const ok = await validate(challenge.type, `${challenge.token}.${thumbprint}`);
        fake.validations.push({ type: challenge.type, ok });
        challenge.status = ok ? 'valid' : 'invalid';
        if (!ok) {
          challenge.error = { type: 'urn:ietf:params:acme:error:connection', detail: `203.0.113.5: Fetching ${challenge.type}: Timeout during connect (likely firewall problem)`, status: 400 };
        }
      }
      return reply(res, 200, publicChallenge(challenge));
    }
    if ((m = /^\/finalize\/(\d+)$/.exec(pathname))) {
      const order = orders.get(Number(m[1]));
      const csrPem = `-----BEGIN CERTIFICATE REQUEST-----\n${Buffer.from(payload.csr, 'base64url').toString('base64').match(/.{1,64}/g).join('\n')}\n-----END CERTIFICATE REQUEST-----\n`;
      fake.csrDomains = acme.crypto.readCsrDomains(csrPem);
      chains.set(Number(m[1]), await issueChain());
      Object.assign(order, { status: 'valid', certificate: `${base}/cert/${m[1]}` });
      return reply(res, 200, order);
    }
    if ((m = /^\/order\/(\d+)$/.exec(pathname))) return reply(res, 200, orders.get(Number(m[1])));
    if ((m = /^\/cert\/(\d+)$/.exec(pathname))) {
      res.writeHead(200, { 'Content-Type': 'application/pem-certificate-chain', 'Replay-Nonce': `nonce-${++nonce}` });
      return res.end(chains.get(Number(m[1])));
    }
    return reply(res, 404, { type: 'urn:ietf:params:acme:error:malformed', detail: 'not found' });
  }
  return fake;
}

/** 발급기 — 가짜 ACME 서버를 쓰고, 인증서 키를 가짜 CA가 알 수 있게 넘긴다. */
function issuerFor(fake, extra = {}) {
  return (options) =>
    createAcmeIssuer({
      ...options,
      log: quietLog,
      directoryUrl: fake.directoryUrl,
      createCertificateKey: async () => {
        const key = (await acme.crypto.createPrivateEcdsaKey()).toString();
        fake.certificateKeyPem = key;
        return key;
      },
      ...extra,
    });
}

/** 확인 요청에 답하는 창구를 메모리로 흉내 낸다(발급기 단독 테스트용). */
function memoryChallenges() {
  const added = [];
  return {
    added,
    'http-01': { add: (token, keyAuthorization) => added.push({ type: 'http-01', token, keyAuthorization }), remove() {} },
    'tls-alpn-01': { add: (token, pair) => added.push({ type: 'tls-alpn-01', token, pair }), remove() {} },
  };
}

const countOf = (fake, line) => fake.requests.filter((r) => r === line).length;

test('발급기: 한도(429 rateLimited)는 종류·Retry-After를 살려 바로 던진다 — acme-client가 그 자리에서 Retry-After만큼 잠들어 다시 보내지 않는다', async () => {
  const fake = await startFakeAcme({ rateLimit: { headers: { 'Retry-After': '7200' } } });
  try {
    const issuer = issuerFor(fake)({ domain: DOMAIN, accountKeyFile: path.join(tempCertsDir(), 'acme-account.key'), ports: { https: 443, http: 80 } });
    const started = Date.now();
    const err = await issuer.issue({ challengeTypes: ['tls-alpn-01', 'http-01'], challenges: memoryChallenges() }).catch((e) => e);
    assert.ok(err instanceof AcmeIssueError);
    assert.equal(err.kind, 'rateLimited');
    assert.equal(err.problemType, RATE_LIMITED);
    assert.equal(err.retryAfterMs, 7200 * 1000);
    assert.match(err.message, /iptime\.org/);
    assert.match(err.detail, /too many certificates/);
    assert.equal(countOf(fake, 'POST /new-order'), 1, '한 번만 묻고 그만둔다(다른 인증 방식으로 넘어가지도 않는다)');
    assert.ok(Date.now() - started < 5000);

    // Retry-After 머리글 없는 한도 응답 — 문구 속 시각을 쓴다.
    const later = new Date(Date.now() + 3 * DAY).toISOString().replace('T', ' ').replace(/\.\d+Z$/, ' UTC');
    fake.behavior.rateLimit = { body: { type: RATE_LIMITED, detail: `too many certificates, retry after ${later}: see https://letsencrypt.org/docs/rate-limits/` } };
    const err2 = await issuer.issue({ challengeTypes: ['http-01'], challenges: memoryChallenges() }).catch((e) => e);
    assert.equal(err2.kind, 'rateLimited');
    assert.ok(Math.abs(err2.retryAfterMs - 3 * DAY) < 5000);
  } finally {
    fake.close();
  }
});

/** http-01 확인에 답하는 작은 HTTP 서버 — 발급기가 memoryChallenges에 넣은 토큰으로 답한다. */
async function startHttp01Answer(challenges) {
  const server = http.createServer((req, res) => {
    const token = req.url.split('/').pop();
    const found = challenges.added.find((c) => c.type === 'http-01' && c.token === token);
    res.writeHead(found ? 200 : 404);
    res.end(found ? found.keyAuthorization : '');
  });
  return { port: await listen(server), close: () => server.close() };
}

test('발급기: 확인 접속이 실패하면 같은 시도 안에서 다른 방식으로 넘어가 받는다(CSR·약관 동의·연락처도 확인)', async () => {
  const fake = await startFakeAcme({ failValidation: ['tls-alpn-01'] });
  const challenges = memoryChallenges();
  const answer = await startHttp01Answer(challenges);
  fake.setTargets({ http: answer.port, tls: 1 });
  try {
    const issuer = issuerFor(fake)({ domain: DOMAIN, email: 'ops@example.com', accountKeyFile: path.join(tempCertsDir(), 'acme-account.key'), ports: { https: 443, http: 80 } });
    const result = await issuer.issue({ challengeTypes: ['tls-alpn-01', 'http-01'], challenges });
    assert.equal(result.challengeType, 'http-01');
    assert.deepEqual(fake.validations, [{ type: 'tls-alpn-01', ok: false }, { type: 'http-01', ok: true }]);
    assert.deepEqual(fake.csrDomains.altNames, [DOMAIN]);
    assert.equal(fake.termsOfServiceAgreed, true);
    assert.deepEqual(fake.contacts, [['mailto:ops@example.com']]);
    assert.equal(countOf(fake, 'POST /new-order'), 2);
    assert.ok(challenges.added.some((c) => c.type === 'tls-alpn-01' && /BEGIN CERTIFICATE/.test(c.pair.cert)), 'TLS-ALPN-01 확인용 인증서를 만들어 넘겼다');
    const x509 = new crypto.X509Certificate(result.certPem);
    assert.ok(x509.checkHost(DOMAIN));
    assert.ok(x509.checkPrivateKey(crypto.createPrivateKey(result.keyPem)), '인증서와 함께 돌려준 키가 짝이 맞다');
  } finally {
    fake.close();
    answer.close();
  }
});

test('발급기: 두 방식 모두 실패하면 두 이유(외부 443·80, 이 PC의 포트)를 함께 알려 준다', async () => {
  const fake = await startFakeAcme({ failValidation: ['tls-alpn-01', 'http-01'] });
  fake.setTargets({ http: 1, tls: 1 });
  try {
    const issuer = issuerFor(fake)({ domain: DOMAIN, accountKeyFile: path.join(tempCertsDir(), 'acme-account.key'), ports: { https: 443, http: 8080 } });
    const err = await issuer.issue({ challengeTypes: ['tls-alpn-01', 'http-01'], challenges: memoryChallenges() }).catch((e) => e);
    assert.ok(err instanceof AcmeIssueError);
    assert.equal(err.kind, 'challenge');
    assert.match(err.message, /\[tls-alpn-01\].*외부 443.*\/ \[http-01\].*외부 80.*TCP 8080/);
    assert.match(err.detail, /Timeout during connect/);
  } finally {
    fake.close();
  }
});

test('발급기: Let\'s Encrypt가 연락처 이메일을 받지 않으면 이메일 없이 다시 해서 받는다(선택 항목이 발급을 막지 않게)', async () => {
  const fake = await startFakeAcme({ rejectContact: true });
  const answer = http.createServer((req, res) => {
    res.writeHead(200);
    res.end(answers.get(req.url.split('/').pop()) ?? '');
  });
  const answers = new Map();
  fake.setTargets({ http: await listen(answer), tls: 1 });
  try {
    const challenges = memoryChallenges();
    challenges['http-01'].add = (token, keyAuthorization) => answers.set(token, keyAuthorization);
    const issuer = issuerFor(fake)({ domain: DOMAIN, email: 'ops@blocked.example', accountKeyFile: path.join(tempCertsDir(), 'acme-account.key') });
    const result = await issuer.issue({ challengeTypes: ['http-01'], challenges });
    assert.equal(result.challengeType, 'http-01');
    assert.deepEqual(fake.contacts, [['mailto:ops@blocked.example'], null]);
  } finally {
    fake.close();
    answer.close();
  }
});

test('발급기: ACME 서버에 아예 닿지 않으면 네트워크 문제로 알려 준다', async () => {
  const closed = http.createServer();
  const port = await listen(closed);
  closed.close();
  const issuer = createAcmeIssuer({ domain: DOMAIN, log: quietLog, accountKeyFile: path.join(tempCertsDir(), 'acme-account.key'), directoryUrl: `http://127.0.0.1:${port}/directory` });
  const err = await issuer.issue({ challengeTypes: ['http-01'], challenges: memoryChallenges() }).catch((e) => e);
  assert.equal(err.kind, 'network');
  assert.match(err.message, /연결하지 못했습니다/);
});

// ─────────────────────────────── startWebTls 전체 흐름 ───────────────────────────────

const enabledConfig = (extra = {}) => ({ domain: DOMAIN, httpsPort: 443, httpPort: 80, email: null, staging: false, error: null, ...extra });

async function waitFor(fn, { timeoutMs = 20000, what = '조건' } = {}) {
  const until = Date.now() + timeoutMs;
  for (;;) {
    const value = fn();
    if (value) return value;
    if (Date.now() > until) throw new Error(`${what}을(를) 기다리다 시간 초과`);
    await sleep(50);
  }
}

function getVia(port, { path: urlPath = '/', servername = DOMAIN } = {}) {
  return new Promise((resolve, reject) => {
    https
      .get({ host: '127.0.0.1', port, path: urlPath, servername, rejectUnauthorized: false, agent: false }, (res) => {
        let body = '';
        res.on('data', (c) => (body += c));
        res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body, cert: res.socket.getPeerX509Certificate?.() ?? null }));
      })
      .on('error', reject);
  });
}

const echoApp = (req, res) => {
  res.setHeader('Content-Type', 'text/plain');
  res.end(`app:${req.url}`);
};

test('전체 흐름: 웹 포트를 자체 서명으로 열고 → TLS-ALPN-01로 인증서를 받아 → 재시작 없이 바꿔 걸고, 공개 주소를 켠다(HSTS는 켰을 때만)', async () => {
  const fake = await startFakeAcme();
  const certsDir = tempCertsDir();
  const io = new SocketIoServer();
  let ctl;
  try {
    ctl = await startWebTls({
      app: echoApp,
      io,
      fallbackTls,
      config: enabledConfig(),
      sendHsts: true,
      certsDir,
      createIssuer: issuerFor(fake),
      bind: { host: '127.0.0.1', httpsPort: 0, httpPort: 0 },
      log: quietLog,
    });
    const ports = ctl.ports();
    fake.setTargets({ http: ports.http, tls: ports.https });

    await waitFor(() => getWebCertificateStatus().status === 'valid', { what: '인증서 발급' });
    const status = getWebCertificateStatus();
    assert.equal(status.enabled, true);
    assert.equal(status.domain, DOMAIN);
    assert.deepEqual(status.challenges, { http01: true, tlsAlpn01: true });
    assert.equal(status.lastError, null);
    assert.ok(Math.abs(status.expiresAt - (Date.now() + 90 * DAY)) < 60 * 1000);
    assert.ok(status.nextAttemptAt > Date.now() + 59 * DAY, '다음은 만료 30일 전 갱신');
    assert.deepEqual(fake.validations, [{ type: 'tls-alpn-01', ok: true }], '웹 포트가 443이면 TLS-ALPN-01부터');
    assert.equal(getWebPublicUrl(), `https://${DOMAIN}`);
    assert.equal(status.webUrl, `https://${DOMAIN}`);

    // 같은 포트에서 새 인증서가 보인다(재시작 없음) + HSTS(켰으므로)
    const res = await getVia(ports.https, { path: '/hello' });
    assert.equal(res.body, 'app:/hello');
    assert.equal(res.cert.fingerprint256, new crypto.X509Certificate(fake.issued[0]).fingerprint256);
    assert.equal(res.headers['strict-transport-security'], HSTS_HEADER_VALUE);
    assert.equal(status.hsts, true);

    // 인증서 확인용 HTTP 포트: 그 밖의 요청은 https로
    const redirect = await new Promise((resolve) => {
      http.get({ host: '127.0.0.1', port: ports.http, path: '/app?x=1', headers: { Host: 'evil.example.com' } }, (r) => {
        r.resume();
        resolve(r);
      });
    });
    assert.equal(redirect.statusCode, 302);
    assert.equal(redirect.headers.location, `https://${DOMAIN}/app?x=1`);

    for (const name of ['web.crt', 'web.key', 'acme-account.key', 'acme-state.json']) assert.ok(fs.existsSync(path.join(certsDir, name)), name);
    const state = JSON.parse(fs.readFileSync(path.join(certsDir, 'acme-state.json'), 'utf8'));
    assert.equal(state.nextAttemptAt, null);
    assert.equal(state.preferredChallenge, 'tls-alpn-01');
  } finally {
    await ctl?.close();
    io.close();
  }

  // 다시 켜면 저장된 인증서를 바로 쓰고 Let's Encrypt에는 묻지 않는다. 이번엔 sendHsts를 넘기지 않는다(index.js처럼 기본 = 끔).
  const before = fake.requests.length;
  const io2 = new SocketIoServer();
  let ctl2;
  try {
    ctl2 = await startWebTls({
      app: echoApp,
      io: io2,
      fallbackTls,
      config: enabledConfig(),
      certsDir,
      createIssuer: issuerFor(fake),
      bind: { host: '127.0.0.1', httpsPort: 0, httpPort: 0 },
      log: quietLog,
    });
    assert.equal(getWebCertificateStatus().status, 'valid');
    assert.equal(getWebPublicUrl(), `https://${DOMAIN}`);
    const res = await getVia(ctl2.ports().https);
    assert.equal(res.cert.fingerprint256, new crypto.X509Certificate(fake.issued[0]).fingerprint256);
    assert.equal(res.headers['strict-transport-security'], undefined, '기본은 HSTS를 보내지 않는다(평문 초대 링크 보호)');
    assert.equal(getWebCertificateStatus().hsts, false);
    await sleep(200);
    assert.equal(fake.requests.length, before, '재시작해도 다시 발급받지 않는다');
  } finally {
    await ctl2?.close();
    io2.close();
    fake.close();
  }
  assert.equal(getWebPublicUrl(), null);
});

test('전체 흐름: 443이 막혀(TLS-ALPN-01 실패) 있어도 같은 시도 안에서 HTTP-01로 받는다 — 다음엔 HTTP-01부터', async () => {
  const fake = await startFakeAcme({ failValidation: ['tls-alpn-01'] });
  const certsDir = tempCertsDir();
  let ctl;
  try {
    ctl = await startWebTls({
      app: echoApp,
      fallbackTls,
      config: enabledConfig(),
      certsDir,
      createIssuer: issuerFor(fake),
      bind: { host: '127.0.0.1', httpsPort: 0, httpPort: 0 },
      log: quietLog,
    });
    fake.setTargets({ http: ctl.ports().http, tls: ctl.ports().https });
    await waitFor(() => getWebCertificateStatus().status === 'valid', { what: '인증서 발급' });
    assert.deepEqual(fake.validations, [{ type: 'tls-alpn-01', ok: false }, { type: 'http-01', ok: true }]);
    const state = JSON.parse(fs.readFileSync(path.join(certsDir, 'acme-state.json'), 'utf8'));
    assert.equal(state.preferredChallenge, 'http-01');
  } finally {
    await ctl?.close();
    fake.close();
  }
});

test('전체 흐름: 한도에 걸리면 Retry-After까지 기다린다고 알리고, 재시작해도 그 전에는 묻지 않는다', async () => {
  const fake = await startFakeAcme({ rateLimit: { headers: { 'Retry-After': '7200' } } });
  const certsDir = tempCertsDir();
  let ctl;
  try {
    ctl = await startWebTls({
      app: echoApp,
      fallbackTls,
      config: enabledConfig(),
      certsDir,
      createIssuer: issuerFor(fake),
      bind: { host: '127.0.0.1', httpsPort: 0, httpPort: 0 },
      log: quietLog,
    });
    fake.setTargets({ http: ctl.ports().http, tls: ctl.ports().https });
    await waitFor(() => getWebCertificateStatus().status === 'error', { what: '한도 실패' });
    const status = getWebCertificateStatus();
    assert.match(status.lastError, /rateLimited/);
    assert.match(status.lastError, /iptime\.org/);
    assert.ok(Math.abs(status.nextAttemptAt - (Date.now() + 7200 * 1000)) < 30 * 1000, 'Retry-After(2시간)가 백오프(1시간)보다 길어 그만큼 기다린다');
    assert.ok(status.lastAttemptAt <= Date.now());
    assert.equal(getWebPublicUrl(), null, '공인 인증서가 없으면 주소를 알리지 않는다');
    // 자체 서명 인증서로라도 웹 포트는 떠 있고, HSTS는 보내지 않는다.
    const res = await getVia(ctl.ports().https);
    assert.equal(res.headers['strict-transport-security'], undefined);
    assert.equal(res.cert.fingerprint256, new crypto.X509Certificate(fallbackTls.cert).fingerprint256);
  } finally {
    await ctl?.close();
  }
  const before = fake.requests.length;
  let ctl2;
  try {
    ctl2 = await startWebTls({
      app: echoApp,
      fallbackTls,
      config: enabledConfig(),
      certsDir,
      createIssuer: issuerFor(fake),
      bind: { host: '127.0.0.1', httpsPort: 0, httpPort: 0 },
      log: quietLog,
    });
    await sleep(300);
    assert.equal(fake.requests.length, before, '재시작해도 Retry-After 전에는 묻지 않는다');
    const status = getWebCertificateStatus();
    assert.equal(status.status, 'error');
    assert.ok(status.nextAttemptAt > Date.now() + 60 * 60 * 1000);
  } finally {
    await ctl2?.close();
    fake.close();
  }
});

test('전체 흐름: HSTS를 켜도 WEB_DOMAIN이 외부 접속 주소(EXTERNAL_ADDRESS)와 같은 이름이면 보내지 않는다(평문 초대 링크 보호)', async () => {
  const fake = await startFakeAcme();
  let ctl;
  try {
    ctl = await startWebTls({
      app: echoApp,
      fallbackTls,
      config: enabledConfig(),
      sendHsts: true,
      externalHost: DOMAIN,
      certsDir: tempCertsDir(),
      createIssuer: issuerFor(fake),
      bind: { host: '127.0.0.1', httpsPort: 0, httpPort: 0 },
      log: quietLog,
    });
    fake.setTargets({ http: ctl.ports().http, tls: ctl.ports().https });
    await waitFor(() => getWebCertificateStatus().status === 'valid', { what: '인증서 발급' });
    const res = await getVia(ctl.ports().https);
    assert.equal(res.cert.fingerprint256, new crypto.X509Certificate(fake.issued[0]).fingerprint256);
    assert.equal(res.headers['strict-transport-security'], undefined);
    assert.equal(getWebCertificateStatus().hsts, false);
    assert.equal(getWebPublicUrl(), `https://${DOMAIN}`, '공개 주소는 그대로 알린다');
  } finally {
    await ctl?.close();
    fake.close();
  }
});
