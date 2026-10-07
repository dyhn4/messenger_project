// 웹 앱 전용 포트의 앞단(ClientHello를 엿봐 TLS-ALPN-01 확인 접속만 따로 보내기)·확인용 TLS 서버·HTTP-01 응답(webTls.js) 테스트
// — `node --test test/*.test.js`. DB 없이 127.0.0.1에서만 돈다. 실제 socket.io를 붙여 WebSocket 업그레이드까지 앞단을 거쳐 확인한다.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import { after, before, test } from 'node:test';
import tls from 'node:tls';
import acme from 'acme-client';
import selfsigned from 'selfsigned';
import { Server as SocketIoServer } from 'socket.io';
import { createAcmeHttpHandler, createAcmeTlsServer, createTlsFrontRouter } from '../src/webTls.js';

const DOMAIN = 'xxx.iptime.org';
const KEY_AUTHORIZATION = 'tok_EN-123.thumbprint_456';

const listen = (server, port = 0) => new Promise((resolve) => server.listen(port, '127.0.0.1', () => resolve(server.address().port)));
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

let fx; // 공용 준비물

before(async () => {
  const web = await selfsigned.generate([{ name: 'commonName', value: DOMAIN }], {
    keyType: 'ec',
    algorithm: 'sha256',
    extensions: [{ name: 'subjectAltName', altNames: [{ type: 2, value: DOMAIN }, { type: 7, ip: '127.0.0.1' }] }],
  });
  const [alpnKey, alpnCert] = await acme.crypto.createAlpnCertificate({ identifier: { type: 'dns', value: DOMAIN } }, KEY_AUTHORIZATION, await acme.crypto.createPrivateEcdsaKey());
  const challengeContext = tls.createSecureContext({ key: alpnKey, cert: alpnCert });

  const counts = { web: 0, acme: 0 };
  const webServer = https.createServer({ key: web.private, cert: web.cert }, (req, res) => {
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ path: req.url, remote: req.socket.remoteAddress }));
  });
  webServer.on('connection', () => (counts.web += 1));
  const io = new SocketIoServer();
  io.attach(webServer); // index.js·webTls.js와 같은 방식으로 웹 서버에 붙인다.
  await listen(webServer); // 운영과 같이 루프백에서도 듣게 한다(느린 요청 감시).

  const acmeServer = createAcmeTlsServer((servername) => (servername === DOMAIN ? challengeContext : null));
  acmeServer.on('connection', () => (counts.acme += 1));

  const state = { peek: false };
  const router = createTlsFrontRouter({
    httpsServer: webServer,
    acmeServer,
    shouldPeek: () => state.peek,
    isAcmeHello: (hello) => hello.serverName === DOMAIN && hello.alpnProtocols.includes('acme-tls/1'),
    peekTimeoutMs: 300,
    maxConcurrentPeeks: 4,
  });
  const port = await listen(router);
  fx = { web, webServer, io, acmeServer, router, port, counts, state };
});

after(async () => {
  fx.router.close();
  fx.io.close(); // 엔진과 webServer까지 닫는다.
  fx.webServer.closeAllConnections();
  fx.acmeServer.close();
});

function httpsGet(port, { servername = DOMAIN, path = '/', ALPNProtocols } = {}) {
  return new Promise((resolve, reject) => {
    const req = https.get(
      { host: '127.0.0.1', port, path, servername, rejectUnauthorized: false, agent: false, ALPNProtocols },
      (res) => {
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (c) => (body += c));
        res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, json: JSON.parse(body), fingerprint: res.socket.getPeerX509Certificate?.()?.fingerprint256 }));
      },
    );
    req.on('error', reject);
  });
}

/** TLS 핸드셰이크만 하고 협상된 ALPN과 받은 인증서를 돌려준다. 실패하면 { error }. */
function handshake(port, { servername, ALPNProtocols }) {
  return new Promise((resolve) => {
    const socket = tls.connect({ host: '127.0.0.1', port, servername, ALPNProtocols, rejectUnauthorized: false }, () => {
      const cert = socket.getPeerX509Certificate();
      resolve({ alpnProtocol: socket.alpnProtocol, certPem: cert?.toString() ?? null, fingerprint: cert?.fingerprint256 ?? null });
      socket.destroy();
    });
    socket.on('error', (error) => resolve({ error }));
  });
}

/** socket.io의 WebSocket 업그레이드를 직접 해 보고 첫 프레임(engine.io open 패킷)을 읽는다. */
function socketIoOpen(port) {
  return new Promise((resolve, reject) => {
    const socket = tls.connect({ host: '127.0.0.1', port, servername: DOMAIN, rejectUnauthorized: false }, () => {
      socket.write(
        `GET /socket.io/?EIO=4&transport=websocket HTTP/1.1\r\nHost: ${DOMAIN}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n` +
          `Sec-WebSocket-Key: ${crypto.randomBytes(16).toString('base64')}\r\nSec-WebSocket-Version: 13\r\n\r\n`,
      );
    });
    let buf = Buffer.alloc(0);
    socket.on('data', (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      const end = buf.indexOf('\r\n\r\n');
      if (end < 0) return;
      const rest = buf.subarray(end + 4);
      if (rest.length < 2) return;
      let length = rest[1] & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (rest.length < 4) return;
        length = rest.readUInt16BE(2);
        offset = 4;
      }
      if (rest.length < offset + length) return;
      socket.destroy();
      resolve({ statusLine: buf.subarray(0, end).toString().split('\r\n')[0], frame: rest.subarray(offset, offset + length).toString() });
    });
    socket.on('error', reject);
  });
}

/** 클라이언트가 보내는 바이트를 [chunkSize]씩 잘라 조금씩 늦게 넘기는 TCP 중계 — TCP로 잘게 쪼개져 오는 ClientHello 흉내. */
async function startChunkingProxy(targetPort, { chunkSize, delayMs = 3 }) {
  const server = net.createServer((client) => {
    const upstream = net.connect(targetPort, '127.0.0.1');
    upstream.setNoDelay(true); // 잘라 쓴 조각이 커널에서 다시 뭉치지 않게.
    let queue = Promise.resolve();
    client.on('data', (data) => {
      client.pause();
      queue = queue
        .then(async () => {
          for (let i = 0; i < data.length; i += chunkSize) {
            if (upstream.destroyed) return;
            upstream.write(data.subarray(i, i + chunkSize));
            await sleep(delayMs);
          }
        })
        .then(() => client.resume());
    });
    upstream.on('data', (data) => client.write(data));
    const destroy = () => {
      client.destroy();
      upstream.destroy();
    };
    for (const s of [client, upstream]) {
      s.on('error', destroy);
      s.on('close', destroy);
    }
  });
  const port = await listen(server);
  return { port, close: () => server.close() };
}

test('평소(확인 대기 없음)에는 엿보지 않고 바로 HTTPS 서버로 — 실제 접속 IP가 그대로 보인다', async () => {
  fx.state.peek = false;
  const res = await httpsGet(fx.port, { path: '/hello?x=1' });
  assert.equal(res.status, 200);
  assert.deepEqual(res.json, { path: '/hello?x=1', remote: '127.0.0.1' });
  // acme-tls/1을 달고 와도 엿보지 않으니 확인용 서버로 가지 않는다.
  const before = fx.counts.acme;
  const shake = await handshake(fx.port, { servername: DOMAIN, ALPNProtocols: ['acme-tls/1'] });
  assert.notEqual(shake.alpnProtocol, 'acme-tls/1');
  assert.equal(fx.counts.acme, before);
});

test('확인 대기 중: acme-tls/1 + 우리 도메인만 확인용 인증서(acmeIdentifier)를 받고, 일반 HTTPS는 그대로 된다', async () => {
  fx.state.peek = true;
  try {
    const acmeBefore = fx.counts.acme;
    const shake = await handshake(fx.port, { servername: DOMAIN, ALPNProtocols: ['acme-tls/1'] });
    assert.equal(shake.error, undefined);
    assert.equal(shake.alpnProtocol, 'acme-tls/1');
    assert.equal(acme.crypto.isAlpnCertificateAuthorizationValid(shake.certPem, KEY_AUTHORIZATION), true);
    assert.equal(fx.counts.acme, acmeBefore + 1);

    const res = await httpsGet(fx.port, { path: '/during-challenge' });
    assert.equal(res.status, 200);
    assert.equal(res.json.path, '/during-challenge');
    assert.equal(res.json.remote, '127.0.0.1');

    // 다른 도메인이거나 SNI가 없으면 acme-tls/1이어도 확인용 서버로 보내지 않는다.
    const webBefore = fx.counts.web;
    for (const servername of ['other.example.com', undefined]) {
      const other = await handshake(fx.port, { servername, ALPNProtocols: ['acme-tls/1'] });
      assert.notEqual(other.alpnProtocol, 'acme-tls/1');
    }
    assert.equal(fx.counts.acme, acmeBefore + 1);
    assert.equal(fx.counts.web, webBefore + 2);
  } finally {
    fx.state.peek = false;
  }
});

test('WebSocket 업그레이드(socket.io)도 앞단을 거쳐 그대로 된다 — 엿볼 때와 안 엿볼 때 모두', async () => {
  for (const peek of [false, true]) {
    fx.state.peek = peek;
    const opened = await socketIoOpen(fx.port);
    assert.equal(opened.statusLine, 'HTTP/1.1 101 Switching Protocols', `peek=${peek}`);
    assert.match(opened.frame, /^0\{"sid":"/, 'engine.io open 패킷');
  }
  fx.state.peek = false;
});

test('TCP로 잘게 쪼개져 와도(100바이트씩) ClientHello를 모아 제대로 보낸다', async () => {
  fx.state.peek = true;
  const proxy = await startChunkingProxy(fx.port, { chunkSize: 100 });
  try {
    const shake = await handshake(proxy.port, { servername: DOMAIN, ALPNProtocols: ['acme-tls/1'] });
    assert.equal(shake.alpnProtocol, 'acme-tls/1');
    assert.equal(acme.crypto.isAlpnCertificateAuthorizationValid(shake.certPem, KEY_AUTHORIZATION), true);
    const res = await httpsGet(proxy.port, { path: '/chunked' });
    assert.equal(res.json.path, '/chunked');
  } finally {
    proxy.close();
    fx.state.peek = false;
  }
});

test('조각이 상한보다 많으면 엿보기를 그만두고 HTTPS 서버로 넘긴다(일반 HTTPS는 그래도 된다)', async () => {
  // 같은 서버들 앞에 조각 상한만 작게(3개) 둔 앞단 — 100바이트씩 5ms 간격이면 조각이 3개보다 훨씬 많다.
  const strict = createTlsFrontRouter({
    httpsServer: fx.webServer,
    acmeServer: fx.acmeServer,
    shouldPeek: () => true,
    isAcmeHello: (hello) => hello.serverName === DOMAIN && hello.alpnProtocols.includes('acme-tls/1'),
    maxPeekChunks: 3,
  });
  const strictPort = await listen(strict);
  const proxy = await startChunkingProxy(strictPort, { chunkSize: 100, delayMs: 5 });
  try {
    const before = fx.counts.acme;
    const shake = await handshake(proxy.port, { servername: DOMAIN, ALPNProtocols: ['acme-tls/1'] });
    assert.notEqual(shake.alpnProtocol, 'acme-tls/1');
    assert.equal(fx.counts.acme, before);
    const res = await httpsGet(proxy.port, { path: '/many-chunks' });
    assert.equal(res.json.path, '/many-chunks');
  } finally {
    proxy.close();
    strict.close();
  }
});

/** 날 TCP로 [bytes]를 보내고 서버가 연결을 닫을 때까지 기다린다. */
function rawExchange(port, bytes, { waitMs = 3000 } = {}) {
  return new Promise((resolve) => {
    const socket = net.connect(port, '127.0.0.1', () => socket.write(bytes));
    let received = Buffer.alloc(0);
    socket.on('data', (c) => (received = Buffer.concat([received, c])));
    const timer = setTimeout(() => {
      socket.destroy();
      resolve({ closed: false, received });
    }, waitMs);
    socket.on('close', () => {
      clearTimeout(timer);
      resolve({ closed: true, received });
    });
    socket.on('error', () => {});
  });
}

test('엉뚱한 바이트·평문 HTTP는 HTTPS 서버로 넘어가 원래대로 거절되고, 앞단은 계속 멀쩡하다', async () => {
  fx.state.peek = true;
  try {
    const webBefore = fx.counts.web;
    const garbage = await rawExchange(fx.port, crypto.randomBytes(64));
    assert.equal(garbage.closed, true);
    const plainHttp = await rawExchange(fx.port, Buffer.from(`GET / HTTP/1.1\r\nHost: ${DOMAIN}\r\n\r\n`));
    assert.equal(plainHttp.closed, true);
    assert.equal(fx.counts.web, webBefore + 2);
    const res = await httpsGet(fx.port, { path: '/still-alive' });
    assert.equal(res.json.path, '/still-alive');
  } finally {
    fx.state.peek = false;
  }
});

test('너무 큰 ClientHello라고 우기면 다 기다리지 않고(엿보기 제한 시간 전에) HTTPS 서버로 넘긴다', async () => {
  fx.state.peek = true;
  const socket = net.connect(fx.port, '127.0.0.1');
  socket.on('error', () => {});
  try {
    await new Promise((resolve) => socket.once('connect', resolve));
    const webBefore = fx.counts.web;
    // 1MB짜리 ClientHello라는 머리 + 조금. 그 뒤로는 HTTPS 서버(OpenSSL)가 원래대로 레코드를 마저 기다리다 제한 시간에 끊는다.
    socket.write(Buffer.concat([Buffer.from([22, 3, 1, 0x40, 0x00, 1, 0x10, 0x00, 0x00]), crypto.randomBytes(100)]));
    await sleep(100);
    assert.equal(fx.counts.web, webBefore + 1, '엿보기 제한 시간(300ms)보다 먼저 넘겼다');
  } finally {
    socket.destroy();
    fx.state.peek = false;
  }
});

test('ClientHello를 다 안 보내고 버티면 엿보기 제한 시간 뒤 HTTPS 서버로 넘긴다(그 서버의 원래 제한을 따른다)', async () => {
  fx.state.peek = true;
  const socket = net.connect(fx.port, '127.0.0.1');
  try {
    await new Promise((resolve) => socket.once('connect', resolve));
    const webBefore = fx.counts.web;
    socket.write(Buffer.from([22, 3, 1]));
    await sleep(100);
    assert.equal(fx.counts.web, webBefore, '아직 엿보는 중');
    await sleep(400);
    assert.equal(fx.counts.web, webBefore + 1, '시간이 지나 넘겼다');
  } finally {
    socket.destroy();
    fx.state.peek = false;
  }
});

test('엿보는 중에 끊긴 접속은 정리되고, 동시에 엿보는 수에는 상한이 있다(넘치면 엿보지 않고 바로 넘김)', async () => {
  // 같은 서버들 앞에 동시 엿보기 상한 2개·제한 시간 넉넉한(30초) 앞단 — 붙잡아 둔 접속이 테스트 도중에 시간으로 풀리지 않게.
  const capped = createTlsFrontRouter({
    httpsServer: fx.webServer,
    acmeServer: fx.acmeServer,
    shouldPeek: () => true,
    isAcmeHello: (hello) => hello.serverName === DOMAIN && hello.alpnProtocols.includes('acme-tls/1'),
    peekTimeoutMs: 30 * 1000,
    maxConcurrentPeeks: 2,
  });
  const port = await listen(capped);
  const idle = [];
  const openIdle = async () => {
    const s = net.connect(port, '127.0.0.1');
    s.on('error', () => {});
    await new Promise((resolve) => s.once('connect', resolve));
    s.write(Buffer.from([22, 3, 1]));
    idle.push(s);
    return s;
  };
  try {
    // 엿보다가 끊긴 접속 — 어느 서버에도 넘기지 않고, 상한 자리도 돌려준다.
    const webBefore = fx.counts.web;
    const dropped = await openIdle();
    await sleep(50);
    dropped.destroy();
    await sleep(50);
    assert.equal(fx.counts.web, webBefore, '끊긴 접속은 넘기지 않는다');
    const reused = await handshake(port, { servername: DOMAIN, ALPNProtocols: ['acme-tls/1'] });
    assert.equal(reused.alpnProtocol, 'acme-tls/1', '끊긴 접속의 자리는 돌려받았다');

    // 상한(2개)만큼 붙잡아 두면 다음 접속은 엿보지 않는다 → acme-tls/1이어도 HTTPS 서버로.
    await openIdle();
    await openIdle();
    await sleep(50);
    const acmeBefore = fx.counts.acme;
    const shake = await handshake(port, { servername: DOMAIN, ALPNProtocols: ['acme-tls/1'] });
    assert.notEqual(shake.alpnProtocol, 'acme-tls/1');
    assert.equal(fx.counts.acme, acmeBefore);

    // 붙잡던 접속이 끊기면 상한이 풀려 다시 엿본다.
    for (const s of idle) s.destroy();
    await sleep(100);
    const again = await handshake(port, { servername: DOMAIN, ALPNProtocols: ['acme-tls/1'] });
    assert.equal(again.alpnProtocol, 'acme-tls/1', '상한이 풀리면 다시 엿본다');
  } finally {
    for (const s of idle) s.destroy();
    capped.close();
  }
});

test('확인용 TLS 서버: 기다리는 확인이 없는 이름이면 핸드셰이크 자체가 실패한다', async () => {
  const lonely = createAcmeTlsServer(() => null);
  const port = await listen(lonely);
  try {
    const shake = await handshake(port, { servername: DOMAIN, ALPNProtocols: ['acme-tls/1'] });
    assert.ok(shake.error, '인증서를 내주지 않는다');
  } finally {
    lonely.close();
  }
});

// ─────────────────────────────── HTTP-01 · http→https ───────────────────────────────

function rawHttp(port, requestText) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, '127.0.0.1', () => socket.write(requestText));
    let data = '';
    socket.setEncoding('latin1');
    socket.on('data', (c) => (data += c));
    socket.on('end', () => resolve(data));
    socket.on('error', reject);
  });
}

function parseRawResponse(text) {
  const [head, ...rest] = text.split('\r\n\r\n');
  const [statusLine, ...lines] = head.split('\r\n');
  const headers = Object.fromEntries(lines.map((l) => [l.slice(0, l.indexOf(':')).toLowerCase(), l.slice(l.indexOf(':') + 1).trim()]));
  return { status: Number(statusLine.split(' ')[1]), headers, body: rest.join('\r\n\r\n') };
}

async function withHttp01(options, fn) {
  const tokens = new Map([['tok_EN-123', KEY_AUTHORIZATION]]);
  const server = http.createServer(createAcmeHttpHandler({ getKeyAuthorization: (t) => tokens.get(t) ?? null, ...options }));
  const port = await listen(server);
  try {
    await fn(port, tokens);
  } finally {
    server.close();
  }
}

const request = (path, { method = 'GET', host = DOMAIN } = {}) => `${method} ${path} HTTP/1.1\r\nHost: ${host}\r\nConnection: close\r\n\r\n`;

test('HTTP-01: 기다리는 토큰과 정확히 같을 때만 key authorization을 text/plain으로 답한다', async () => {
  await withHttp01({ domain: DOMAIN, httpsPort: 443 }, async (port, tokens) => {
    const ok = parseRawResponse(await rawHttp(port, request('/.well-known/acme-challenge/tok_EN-123')));
    assert.equal(ok.status, 200);
    assert.equal(ok.body, KEY_AUTHORIZATION);
    assert.match(ok.headers['content-type'], /^text\/plain/);
    assert.equal(ok.headers['cache-control'], 'no-store');

    const head = parseRawResponse(await rawHttp(port, request('/.well-known/acme-challenge/tok_EN-123', { method: 'HEAD' })));
    assert.equal(head.status, 200);
    assert.equal(head.body, '');

    for (const path of [
      '/.well-known/acme-challenge/tok_EN-12', // 앞부분만
      '/.well-known/acme-challenge/tok_EN-1234', // 더 긴 것
      '/.well-known/acme-challenge/TOK_EN-123', // 대소문자
      '/.well-known/acme-challenge/tok_EN-123/', // 뒤 슬래시
      '/.well-known/acme-challenge/tok_EN-123?x=1', // 쿼리
      '/.well-known/acme-challenge/tok_EN-123%00', // 이상한 글자
      '/.well-known/acme-challenge/../acme-challenge/tok_EN-123',
      '/.well-known/acme-challenge/',
      '/.well-known/acme-challenge/constructor', // 객체 기본 속성 이름
      `/.well-known/acme-challenge/${'a'.repeat(300)}`,
    ]) {
      const res = parseRawResponse(await rawHttp(port, request(path)));
      assert.equal(res.status, 404, path);
      assert.notEqual(res.body, KEY_AUTHORIZATION, path);
    }
    const post = parseRawResponse(await rawHttp(port, request('/.well-known/acme-challenge/tok_EN-123', { method: 'POST' })));
    assert.equal(post.status, 404, 'GET·HEAD만');

    tokens.delete('tok_EN-123');
    const gone = parseRawResponse(await rawHttp(port, request('/.well-known/acme-challenge/tok_EN-123')));
    assert.equal(gone.status, 404, '확인이 끝나 지운 토큰은 더 답하지 않는다');
  });
});

test('그 밖의 요청은 설정한 도메인의 https로 보낸다 — Host 머리글은 무시(열린 리디렉션 없음), 443이 아니면 포트를 붙인다', async () => {
  await withHttp01({ domain: DOMAIN, httpsPort: 443 }, async (port) => {
    const res = parseRawResponse(await rawHttp(port, request('/app/index.html?room=1', { host: 'evil.example.com' })));
    assert.equal(res.status, 302);
    assert.equal(res.headers.location, `https://${DOMAIN}/app/index.html?room=1`);

    const absolute = parseRawResponse(await rawHttp(port, request('http://evil.example.com/steal', { host: 'evil.example.com' })));
    assert.equal(absolute.headers.location, `https://${DOMAIN}/`, '프록시 형식 요청은 첫 화면으로');

    const doubleSlash = parseRawResponse(await rawHttp(port, request('//evil.example.com/x')));
    assert.equal(new URL(doubleSlash.headers.location).host, DOMAIN, '//로 시작해도 호스트는 그대로');

    const backslash = parseRawResponse(await rawHttp(port, request('/\\evil.example.com/x')));
    assert.equal(new URL(backslash.headers.location).host, DOMAIN);
  });
  await withHttp01({ domain: DOMAIN, httpsPort: 8443 }, async (port) => {
    const res = parseRawResponse(await rawHttp(port, request('/')));
    assert.equal(res.headers.location, `https://${DOMAIN}:8443/`);
  });
});
