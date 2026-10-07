// TLS ClientHello 엿보기(clientHello.js) 단위 테스트 — `node --test test/*.test.js` (DB 없이, 127.0.0.1에서만 돈다).
// 진짜 ClientHello는 Node의 tls.connect가 보내는 바이트를 그대로 받아 쓰고, 이상한 입력은 직접 만든 바이트로 확인한다.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import net from 'node:net';
import { test } from 'node:test';
import tls from 'node:tls';
import { MAX_CLIENT_HELLO_BYTES, parseClientHello } from '../src/clientHello.js';

/** tls.connect가 보내는 첫 TLS 레코드(ClientHello)를 그대로 받아 온다 — 레코드 머리의 길이만 보고 자른다(파서와 무관하게). */
async function captureClientHello(options) {
  const server = net.createServer();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const captured = new Promise((resolve, reject) => {
    server.once('connection', (socket) => {
      let buf = Buffer.alloc(0);
      socket.on('error', () => {});
      socket.on('data', (chunk) => {
        buf = Buffer.concat([buf, chunk]);
        if (buf.length >= 5 && buf.length >= 5 + buf.readUInt16BE(3)) {
          socket.destroy();
          resolve(buf.subarray(0, 5 + buf.readUInt16BE(3)));
        }
      });
    });
    setTimeout(() => reject(new Error('ClientHello를 받지 못했다')), 5000).unref();
  });
  const client = tls.connect({ host: '127.0.0.1', port: server.address().port, rejectUnauthorized: false, ...options });
  client.on('error', () => {});
  try {
    return await captured;
  } finally {
    client.destroy();
    server.close();
  }
}

const u16 = (n) => {
  const b = Buffer.alloc(2);
  b.writeUInt16BE(n);
  return b;
};
const u24 = (n) => {
  const b = Buffer.alloc(3);
  b.writeUIntBE(n, 0, 3);
  return b;
};
const extension = (type, data) => Buffer.concat([u16(type), u16(data.length), data]);
const sniExtension = (name) => {
  const host = Buffer.from(name, 'latin1');
  const entry = Buffer.concat([Buffer.from([0]), u16(host.length), host]);
  return extension(0, Buffer.concat([u16(entry.length), entry]));
};
const alpnExtension = (protocols) => {
  const list = Buffer.concat(protocols.map((p) => Buffer.concat([Buffer.from([Buffer.byteLength(p)]), Buffer.from(p, 'latin1')])));
  return extension(16, Buffer.concat([u16(list.length), list]));
};
/** 직접 만드는 ClientHello 본문 — 이상한 입력을 만들 때 쓴다. */
const helloBody = (extensions) => {
  const exts = Buffer.concat(extensions);
  return Buffer.concat([Buffer.from([3, 3]), crypto.randomBytes(32), Buffer.from([0]), u16(2), Buffer.from([0x13, 0x01]), Buffer.from([1, 0]), u16(exts.length), exts]);
};
const handshake = (body, type = 1) => Buffer.concat([Buffer.from([type]), u24(body.length), body]);
/** 핸드셰이크 메시지를 TLS 레코드 여러 개로 나눈다([sizes] 순서대로, 남은 건 마지막 레코드). */
const toRecords = (message, sizes = []) => {
  const out = [];
  let offset = 0;
  for (const size of [...sizes, message.length]) {
    if (offset >= message.length) break;
    const fragment = message.subarray(offset, Math.min(offset + size, message.length));
    out.push(Buffer.concat([Buffer.from([22, 3, 1]), u16(fragment.length), fragment]));
    offset += fragment.length;
  }
  return Buffer.concat(out);
};
/** 진짜 ClientHello 레코드에서 핸드셰이크 메시지만 꺼낸다(레코드 하나라고 가정). */
const messageOf = (record) => record.subarray(5);

test('진짜 ClientHello: SNI와 ALPN acme-tls/1을 읽는다(Let\'s Encrypt TLS-ALPN-01 확인 접속 모양)', async () => {
  const bytes = await captureClientHello({ servername: 'xxx.iptime.org', ALPNProtocols: ['acme-tls/1'] });
  assert.deepEqual(parseClientHello(bytes), { status: 'complete', serverName: 'xxx.iptime.org', alpnProtocols: ['acme-tls/1'] });
});

test('진짜 ClientHello: 브라우저처럼 h2·http/1.1을 고르면 그 목록 그대로', async () => {
  const bytes = await captureClientHello({ servername: 'xxx.iptime.org', ALPNProtocols: ['h2', 'http/1.1'] });
  const hello = parseClientHello(bytes);
  assert.equal(hello.status, 'complete');
  assert.equal(hello.serverName, 'xxx.iptime.org');
  assert.deepEqual(hello.alpnProtocols, ['h2', 'http/1.1']);
});

test('진짜 ClientHello: SNI 없이(IP로 접속) · ALPN 없이도 complete — 이름은 null, 목록은 빈 배열', async () => {
  const noSni = parseClientHello(await captureClientHello({ ALPNProtocols: ['acme-tls/1'] }));
  assert.equal(noSni.status, 'complete');
  assert.equal(noSni.serverName, null);
  assert.deepEqual(noSni.alpnProtocols, ['acme-tls/1']);

  const plain = parseClientHello(await captureClientHello({ servername: 'XXX.Iptime.ORG' }));
  assert.equal(plain.status, 'complete');
  assert.equal(plain.serverName, 'xxx.iptime.org', '대소문자는 소문자로 맞춘다');
  assert.deepEqual(plain.alpnProtocols, []);
});

test('TCP로 잘려 와도(앞부분만 받은 상태) 끝까지 incomplete, 다 오면 complete — 뒤에 다른 바이트가 붙어도 된다', async () => {
  const bytes = await captureClientHello({ servername: 'xxx.iptime.org', ALPNProtocols: ['acme-tls/1'] });
  for (const cut of [0, 1, 4, 5, 6, 9, 40, Math.floor(bytes.length / 2), bytes.length - 1]) {
    assert.equal(parseClientHello(bytes.subarray(0, cut)).status, 'incomplete', `${cut}바이트`);
  }
  const withTail = Buffer.concat([bytes, Buffer.from([0x14, 0x03, 0x03, 0x00, 0x01, 0x01])]);
  assert.equal(parseClientHello(withTail).serverName, 'xxx.iptime.org');
});

test('ClientHello가 TLS 레코드 여러 개로 쪼개져 와도(레코드 조각 모음) 같은 결과 — 머리 4바이트가 갈라져도 된다', async () => {
  const bytes = await captureClientHello({ servername: 'xxx.iptime.org', ALPNProtocols: ['acme-tls/1'] });
  const message = messageOf(bytes);
  for (const sizes of [[1], [2, 2], [3, 100, 7], [700], [1, 1, 1, 1, 1, 1, 1, 1]]) {
    const fragmented = toRecords(message, sizes);
    assert.deepEqual(parseClientHello(fragmented), { status: 'complete', serverName: 'xxx.iptime.org', alpnProtocols: ['acme-tls/1'] }, `조각 ${sizes}`);
    assert.equal(parseClientHello(fragmented.subarray(0, fragmented.length - 1)).status, 'incomplete');
  }
});

test('엉뚱한 바이트는 invalid — 평문 HTTP, 무작위, SSLv2 모양, 핸드셰이크가 아닌 레코드, ClientHello가 아닌 메시지', () => {
  const cases = {
    http: Buffer.from('GET / HTTP/1.1\r\nHost: xxx.iptime.org\r\n\r\n'),
    sslv2: Buffer.from([0x80, 0x2e, 0x01, 0x03, 0x01, 0x00, 0x15]),
    appData: Buffer.from([0x17, 0x03, 0x03, 0x00, 0x05, 1, 2, 3, 4, 5]),
    badVersion: Buffer.from([0x16, 0x07, 0x01, 0x00, 0x05, 1, 2, 3, 4, 5]),
    emptyRecord: Buffer.from([0x16, 0x03, 0x01, 0x00, 0x00]),
    serverHello: toRecords(handshake(helloBody([]), 2)),
  };
  for (const [name, bytes] of Object.entries(cases)) assert.equal(parseClientHello(bytes).status, 'invalid', name);
  for (let i = 0; i < 200; i += 1) {
    const random = crypto.randomBytes(1 + (i % 64));
    const result = parseClientHello(random);
    assert.ok(['invalid', 'incomplete'].includes(result.status), '무작위 바이트로 던지지 않는다');
  }
  assert.equal(parseClientHello(null).status, 'invalid');
});

test('너무 큰 것은 다 받기 전에 invalid — 핸드셰이크 길이 상한, 레코드 길이 상한', () => {
  // 머리만 보고 거른다: 1MB짜리 ClientHello라고 주장하는 레코드.
  const huge = Buffer.concat([Buffer.from([22, 3, 1]), u16(4), Buffer.from([1]), u24(1024 * 1024)]);
  assert.deepEqual(parseClientHello(huge), { status: 'invalid', reason: 'too-large' });
  assert.equal(parseClientHello(huge.subarray(0, 9)).status, 'invalid', '레코드가 덜 와도 머리가 보이면 바로');
  const justOver = Buffer.concat([Buffer.from([22, 3, 1]), u16(4), Buffer.from([1]), u24(MAX_CLIENT_HELLO_BYTES + 1)]);
  assert.equal(parseClientHello(justOver).status, 'invalid');
  const recordTooLong = Buffer.from([22, 3, 1, 0x40, 0x01]); // 16385
  assert.deepEqual(parseClientHello(recordTooLong), { status: 'invalid', reason: 'record-length' });
});

test('길이가 어긋난 확장·중복 확장·빈 ALPN 이름·이상한 SNI는 invalid(믿을 쪽을 고르지 않고 통째로 넘긴다)', () => {
  const ok = handshake(helloBody([sniExtension('xxx.iptime.org'), alpnExtension(['acme-tls/1'])]));
  assert.equal(parseClientHello(toRecords(ok)).status, 'complete');

  const duplicate = handshake(helloBody([alpnExtension(['h2']), alpnExtension(['acme-tls/1'])]));
  assert.deepEqual(parseClientHello(toRecords(duplicate)), { status: 'invalid', reason: 'duplicate-extension' });

  const emptyName = handshake(helloBody([extension(16, Buffer.from([0, 1, 0]))]));
  assert.equal(parseClientHello(toRecords(emptyName)).status, 'invalid');

  const weirdSni = handshake(helloBody([sniExtension('xxx.iptime.org\u0000evil')]));
  assert.equal(parseClientHello(toRecords(weirdSni)).status, 'invalid');

  // 확장 전체 길이를 1 늘린다 → 본문 끝과 맞지 않는다.
  const body = helloBody([sniExtension('xxx.iptime.org')]);
  const extLengthAt = 2 + 32 + 1 + 2 + 2 + 2;
  body.writeUInt16BE(body.readUInt16BE(extLengthAt) + 1, extLengthAt);
  assert.equal(parseClientHello(toRecords(handshake(body))).status, 'invalid');

  // SNI 목록 길이가 확장 길이와 다르다.
  const sniBad = Buffer.from(sniExtension('xxx.iptime.org'));
  sniBad.writeUInt16BE(sniBad.readUInt16BE(4) - 1, 4);
  assert.equal(parseClientHello(toRecords(handshake(helloBody([sniBad])))).status, 'invalid');

  // 세션 ID 길이가 32를 넘는다.
  const longSession = helloBody([]);
  longSession[34] = 33;
  assert.equal(parseClientHello(toRecords(handshake(longSession))).status, 'invalid');
});

test('확장이 하나도 없는 옛 ClientHello도 complete(SNI·ALPN 없음)', () => {
  const body = Buffer.concat([Buffer.from([3, 1]), crypto.randomBytes(32), Buffer.from([0]), u16(2), Buffer.from([0, 0x2f]), Buffer.from([1, 0])]);
  assert.deepEqual(parseClientHello(toRecords(handshake(body))), { status: 'complete', serverName: null, alpnProtocols: [] });
});
