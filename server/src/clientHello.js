/**
 * TLS ClientHello(접속하자마자 클라이언트가 보내는 첫 메시지)에서 SNI(접속하려는 도메인)와 ALPN(쓰려는 프로토콜 목록)만 읽는다.
 *
 * 웹 앱 전용 HTTPS 포트의 앞단(webTls.js)이 Let's Encrypt의 TLS-ALPN-01 확인 접속(ALPN "acme-tls/1")을 골라내는 데 쓴다 — Node의
 * TLS 서버는 ALPN을 보고 인증서를 고를 수 없어서(SNICallback에는 도메인만 온다), 첫 바이트들을 소비하지 않고 엿본 뒤 알맞은 서버에
 * 넘겨야 하기 때문이다.
 *
 * 인터넷의 아무나 보내는 바이트를 그대로 받으므로 모든 길이를 경계 안에서만 읽고, 조금이라도 규격과 다르면 'invalid'를 돌려준다
 * — 그러면 앞단은 엿보기를 그만두고 평소 HTTPS 서버에 그대로 넘긴다(그 서버가 원래 하던 대로 거절한다). 아직 덜 왔으면 'incomplete'.
 * 핸드셰이크 메시지가 TLS 레코드 여러 개로 쪼개져 와도(RFC 8446 5.1) 이어 붙여 읽는다.
 */

/** ClientHello 본문의 상한 — 양자 내성 키 교환(X25519MLKEM768)을 넣은 요즘 브라우저도 2KB 안팎이라 넉넉하다. 넘으면 'invalid'. */
export const MAX_CLIENT_HELLO_BYTES = 16 * 1024;

const RECORD_HEADER_BYTES = 5;
const HANDSHAKE_HEADER_BYTES = 4;
const CONTENT_TYPE_HANDSHAKE = 22;
const HANDSHAKE_CLIENT_HELLO = 1;
// 평문 TLS 레코드 하나의 최대 길이(2^14, RFC 8446 5.1).
const MAX_RECORD_FRAGMENT_BYTES = 16 * 1024;
const EXTENSION_SERVER_NAME = 0;
const EXTENSION_ALPN = 16;

const INCOMPLETE = Object.freeze({ status: 'incomplete' });

function invalid(reason) {
  return { status: 'invalid', reason };
}

/**
 * [buf]의 맨 앞(소켓에서 지금까지 받은 바이트 전부)을 ClientHello로 읽는다.
 * @returns {{status: 'complete', serverName: string|null, alpnProtocols: string[]}
 *   | {status: 'incomplete'} | {status: 'invalid', reason: string}}
 */
export function parseClientHello(buf, { maxHandshakeBytes = MAX_CLIENT_HELLO_BYTES } = {}) {
  if (!Buffer.isBuffer(buf)) return invalid('not-a-buffer');
  const fragments = [];
  let collected = 0;
  let expected = -1; // 핸드셰이크 메시지 전체 길이(머리 4바이트 포함) — 머리를 읽기 전에는 -1
  let offset = 0;

  while (expected < 0 || collected < expected) {
    if (buf.length - offset < RECORD_HEADER_BYTES) return INCOMPLETE;
    const contentType = buf[offset];
    const majorVersion = buf[offset + 1];
    const length = buf.readUInt16BE(offset + 3);
    // 빈 핸드셰이크 레코드는 규격상 보내면 안 된다(RFC 8446 5.1). SSLv2 형식(첫 바이트 0x80…)이나 평문 HTTP도 여기서 걸러진다.
    if (contentType !== CONTENT_TYPE_HANDSHAKE) return invalid('not-handshake');
    if (majorVersion !== 3) return invalid('record-version');
    if (length === 0 || length > MAX_RECORD_FRAGMENT_BYTES) return invalid('record-length');

    const available = Math.min(length, buf.length - offset - RECORD_HEADER_BYTES);
    const fragment = buf.subarray(offset + RECORD_HEADER_BYTES, offset + RECORD_HEADER_BYTES + available);

    // 레코드가 다 오기 전이라도 핸드셰이크 머리(종류·길이)가 보이면 먼저 확인한다 — 잘못된 접속을 끝까지 기다리지 않으려고.
    if (expected < 0 && collected + fragment.length >= HANDSHAKE_HEADER_BYTES) {
      const head = Buffer.concat([...fragments, fragment]).subarray(0, HANDSHAKE_HEADER_BYTES);
      if (head[0] !== HANDSHAKE_CLIENT_HELLO) return invalid('not-client-hello');
      const bodyLength = head.readUIntBE(1, 3);
      if (bodyLength > maxHandshakeBytes) return invalid('too-large');
      expected = HANDSHAKE_HEADER_BYTES + bodyLength;
    }
    if (available < length) return INCOMPLETE;

    fragments.push(fragment);
    collected += length;
    offset += RECORD_HEADER_BYTES + length;
  }

  // 마지막 레코드에 다음 핸드셰이크 메시지가 붙어 있을 수 있다(TLS 1.2 이하) — ClientHello 몫만 자른다.
  const message = Buffer.concat(fragments, collected).subarray(HANDSHAKE_HEADER_BYTES, expected);
  return parseClientHelloBody(message);
}

/** 핸드셰이크 머리 4바이트를 뺀 ClientHello 본문(RFC 8446 4.1.2 — TLS 1.2의 모양도 같다). */
function parseClientHelloBody(body) {
  let p = 0;
  const has = (n) => p + n <= body.length;

  // legacy_version(2) + random(32)
  if (!has(34)) return invalid('truncated');
  p += 34;

  if (!has(1)) return invalid('truncated');
  const sessionIdLength = body[p];
  p += 1;
  if (sessionIdLength > 32 || !has(sessionIdLength)) return invalid('session-id');
  p += sessionIdLength;

  if (!has(2)) return invalid('truncated');
  const cipherSuitesLength = body.readUInt16BE(p);
  p += 2;
  if (cipherSuitesLength < 2 || cipherSuitesLength % 2 !== 0 || !has(cipherSuitesLength)) return invalid('cipher-suites');
  p += cipherSuitesLength;

  if (!has(1)) return invalid('truncated');
  const compressionLength = body[p];
  p += 1;
  if (compressionLength < 1 || !has(compressionLength)) return invalid('compression');
  p += compressionLength;

  let serverName = null;
  let alpnProtocols = [];
  // 확장이 하나도 없는 ClientHello(옛 TLS)도 규격에 맞다 — SNI·ALPN이 없는 것으로 본다.
  if (p === body.length) return { status: 'complete', serverName, alpnProtocols };

  if (!has(2)) return invalid('truncated');
  const extensionsLength = body.readUInt16BE(p);
  p += 2;
  if (p + extensionsLength !== body.length) return invalid('extensions-length');

  const seen = new Set();
  while (p < body.length) {
    if (!has(4)) return invalid('extension-header');
    const type = body.readUInt16BE(p);
    const length = body.readUInt16BE(p + 2);
    p += 4;
    if (!has(length)) return invalid('extension-length');
    // 같은 확장을 두 번 보내면 규격 위반이다(RFC 8446 4.2) — 어느 쪽을 믿을지 고르지 않고 통째로 넘긴다.
    if (seen.has(type)) return invalid('duplicate-extension');
    seen.add(type);
    const data = body.subarray(p, p + length);
    p += length;

    if (type === EXTENSION_SERVER_NAME) {
      serverName = parseServerName(data);
      if (serverName === undefined) return invalid('server-name');
    } else if (type === EXTENSION_ALPN) {
      alpnProtocols = parseAlpn(data);
      if (!alpnProtocols) return invalid('alpn');
    }
  }
  return { status: 'complete', serverName, alpnProtocols };
}

/** server_name 확장(RFC 6066 3) — host_name 항목의 이름(소문자). 형식이 틀리면 undefined. */
function parseServerName(data) {
  if (data.length < 2) return undefined;
  const listLength = data.readUInt16BE(0);
  if (listLength + 2 !== data.length || listLength === 0) return undefined;
  let p = 2;
  let hostName = null;
  while (p < data.length) {
    if (p + 3 > data.length) return undefined;
    const nameType = data[p];
    const length = data.readUInt16BE(p + 1);
    p += 3;
    if (length === 0 || p + length > data.length) return undefined;
    if (nameType === 0) {
      if (hostName !== null) return undefined; // host_name은 하나만 올 수 있다.
      const raw = data.subarray(p, p + length);
      // 도메인에 쓰는 글자(영문·숫자·점·하이픈·밑줄)만 — 그 밖의 바이트가 섞인 이름은 우리 도메인일 수 없다.
      if (length > 255 || !/^[A-Za-z0-9._-]+$/.test(raw.toString('latin1'))) return undefined;
      hostName = raw.toString('latin1').toLowerCase();
    }
    p += length;
  }
  return hostName;
}

/** ALPN 확장(RFC 7301 3.1) — 클라이언트가 고른 프로토콜 이름들. 형식이 틀리면 null. */
function parseAlpn(data) {
  if (data.length < 2) return null;
  const listLength = data.readUInt16BE(0);
  if (listLength + 2 !== data.length || listLength < 2) return null;
  const names = [];
  let p = 2;
  while (p < data.length) {
    const length = data[p];
    p += 1;
    if (length === 0 || p + length > data.length) return null;
    names.push(data.subarray(p, p + length).toString('latin1'));
    p += length;
  }
  return names;
}
