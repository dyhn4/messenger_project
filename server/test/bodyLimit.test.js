// REST(JSON) 본문 상한과 본문 읽기 오류 응답(bodyLimit.js) 단위 테스트 — `node --test test/bodyLimit.test.js` (DB·서버 없이 돈다).
// 예전엔 express.json() 기본 상한(100KB)이 정상 앱이 보내는 글(비밀 대화 댓글·수정의 암호문 봉투, 서식이 붙은 긴 글 수정, 긴 노트)보다
// 작아서 "request entity too large"가 영어 문구의 500으로 났다. 상한 안에 가장 큰 정상 본문이 들어가는지는 messageLimits.js의 상한으로
// 직접 만들어 재 보고, 실제 express.json 파서는 가짜 요청 스트림으로 돌린다(포트를 열지 않는다). index.js는 import하면 서버가 뜨므로
// 연결(파서·오류 처리·CSP)은 소스 글로 본다.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import { Readable } from 'node:stream';
import { test } from 'node:test';
import {
  BODY_MALFORMED_ERROR,
  BODY_TOKEN_INVALID_ERROR,
  BODY_TOO_LARGE_ERROR,
  BODY_UNREADABLE_ERROR,
  bodyErrorReply,
  createJsonBodyParser,
  JSON_BODY_LIMIT_BYTES,
} from '../src/bodyLimit.js';
import {
  FILE_NAME_MAX,
  MESSAGE_TEXT_MAX,
  MESSAGE_TEXT_MAX_BYTES,
  messageTextDenial,
  postBytesDenial,
  SECRET_TEXT_MAX,
  SOCKET_MAX_PAYLOAD_BYTES,
} from '../src/messageLimits.js';
import { graphemeLength, POST_TITLE_MAX } from '../src/permissions.js';

const EXPRESS_DEFAULT_LIMIT = 100 * 1024; // express.json()의 기본값('100kb')
const projectsSource = fs.readFileSync(new URL('../src/projects.js', import.meta.url), 'utf8');
const indexSource = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
const NOTE_BODY_MAX = Number(/const NOTE_BODY_MAX = (\d+);/.exec(projectsSource)?.[1]);

/** 앱(Dart jsonEncode)이 보내는 본문의 바이트 수 — 한글·이모지는 그대로(UTF-8), 제어 문자는 \u00XX로 JSON.stringify와 같다. */
const bytesOf = (body) => Buffer.byteLength(JSON.stringify(body));

/** 글자 수·바이트 상한 안에서 JSON으로 가장 크게 불어나는 글 — 제어 문자(1바이트 → \u00XX 6바이트)로 글자 수를 거의 다 쓰고, 남은
 * 바이트를 결합 문자 덩어리 한 글자에 몰아 둔다(test/messageLimits.test.js와 같은 셈). */
function worstText(maxGraphemes = MESSAGE_TEXT_MAX, maxBytes = MESSAGE_TEXT_MAX_BYTES) {
  const controls = '\u0001'.repeat(maxGraphemes - 1);
  return `${controls}a${'́'.repeat(Math.floor((maxBytes - controls.length - 1) / 2))}`;
}

/** 서식 2,000구간(5개에 하나는 긴 링크) — 서버가 받는 구간 수 상한(textFormat.js). */
const worstFormat = () =>
  Array.from({ length: 2000 }, (_, i) =>
    i % 5 === 0 ? { s: i, e: i + 1, f: 1, h: `https://example.com/${'p'.repeat(150)}` } : { s: i, e: i + 1, f: 63 },
  );
const manyMentions = () => Array.from({ length: 200 }, (_, i) => ({ type: 'user', userId: crypto.randomUUID(), s: i, e: i + 1 }));

/** 길이가 꼭 [length]자인 비밀 대화 봉투 모양(client secret_chat_crypto.dart encryptEnvelope — 안의 따옴표는 바깥 JSON에서 \"로 늘어난다). */
function envelopeOfLength(length) {
  const head = JSON.stringify({ v: 1, epoch: Number.MAX_SAFE_INTEGER, n: Number.MAX_SAFE_INTEGER, nonce: 'A'.repeat(16), ciphertext: '' });
  return `${head.slice(0, -2)}${'A'.repeat(length - head.length)}"}`;
}

/** REST로 오는 가장 큰 정상 본문들 — 라우트마다 서버가 받는 상한을 꽉 채운 값. */
function largestRestBodies() {
  const text = worstText();
  const title = worstText(POST_TITLE_MAX, 16 * POST_TITLE_MAX);
  const attachment = {
    kind: 'image',
    fileUrl: `/files/${'A'.repeat(140)}`,
    fileName: '가'.repeat(FILE_NAME_MAX),
    fileSize: 2147483647,
    mimeType: 'image/jpeg',
    thumbnailUrl: `/files/${'A'.repeat(140)}`,
  };
  return {
    // POST /messages/:id/comments — 비밀 대화의 사진·파일 댓글(봉투 + 파일 칸).
    secretComment: {
      type: 'file',
      text: envelopeOfLength(SECRET_TEXT_MAX),
      fileUrl: `/uploads/${crypto.randomUUID()}.bin`,
      thumbnailUrl: `/uploads/${crypto.randomUUID()}.bin`,
      fileName: 'encrypted',
      fileSize: 2147483647,
      mimeType: 'application/octet-stream',
    },
    // PATCH /messages/:id — 비밀 대화 글 수정.
    secretEdit: { text: envelopeOfLength(SECRET_TEXT_MAX) },
    // PATCH /messages/:id — 일반 글 수정(서식·멘션 포함).
    plainEdit: { text, textFormat: worstFormat(), mentions: manyMentions() },
    // PATCH /messages/:id — 보드 뷰 게시글 수정(제목 + 본문).
    postEdit: { title, text, textFormat: worstFormat(), mentions: manyMentions() },
    // POST /messages/:id/comments — 일반 댓글(서식은 없고 멘션은 있다).
    plainComment: { type: 'image', text, mentions: manyMentions(), ...attachment },
    // 예약 메시지 — 글(5,000자) + 첨부 10개(scheduledMessages.js).
    scheduled: { text: worstText(5000), textFormat: worstFormat(), mentions: manyMentions(), attachments: Array(10).fill(attachment) },
    // 프로젝트 노트 저장 — 본문 NOTE_BODY_MAX자(projects.js — 자 수는 UTF-16 길이로 센다).
    note: { title: '가'.repeat(100), body: '\u0001'.repeat(NOTE_BODY_MAX) },
  };
}

/** 가짜 요청(본문 스트림) — express.json이 보는 헤더만 둔다. [headers]로 덮어쓰거나 지운다(undefined). */
function fakeRequest(body, headers = {}) {
  const buffer = Buffer.from(typeof body === 'string' ? body : JSON.stringify(body));
  const req = Readable.from([buffer], { objectMode: false });
  req.method = 'POST';
  req.url = '/api/test';
  req.headers = { 'content-type': 'application/json', 'content-length': String(buffer.length), ...headers };
  for (const [k, v] of Object.entries(req.headers)) if (v === undefined) delete req.headers[k];
  return req;
}

/** 파서를 돌린 결과 — { err, body, req }. */
function parse(parser, req) {
  return new Promise((resolve) => parser(req, {}, (err) => resolve({ err, body: req.body, req })));
}

const signedIn = () => true;
const signedOut = () => false;

test('상한: 기본 100KB보다 크고 몇 MB씩은 아니며, 소켓 한 번 상한과 같다', () => {
  assert.equal(JSON_BODY_LIMIT_BYTES, SOCKET_MAX_PAYLOAD_BYTES);
  assert.ok(JSON_BODY_LIMIT_BYTES > EXPRESS_DEFAULT_LIMIT);
  assert.ok(JSON_BODY_LIMIT_BYTES <= 1024 * 1024);
});

test('상한: 라우트마다 서버가 받는 가장 큰 정상 본문이 들어간다(기본 100KB에는 안 들어간다)', () => {
  assert.ok(Number.isInteger(NOTE_BODY_MAX) && NOTE_BODY_MAX > 0, 'projects.js의 NOTE_BODY_MAX를 읽지 못했다');
  const bodies = largestRestBodies();
  // 만든 값이 정말 서버가 받는 값인지 — 상한을 넘었으면 이 셈은 의미가 없다.
  assert.equal(bodies.secretEdit.text.length, SECRET_TEXT_MAX);
  assert.equal(messageTextDenial(bodies.secretEdit.text, { secret: true }), null);
  assert.equal(messageTextDenial(bodies.plainEdit.text), null);
  assert.equal(graphemeLength(bodies.plainEdit.text), MESSAGE_TEXT_MAX);
  assert.equal(postBytesDenial(bodies.postEdit.title, bodies.postEdit.text), null);
  assert.equal(graphemeLength(bodies.postEdit.title), POST_TITLE_MAX);
  assert.equal(bodies.note.body.length, NOTE_BODY_MAX);
  for (const [name, body] of Object.entries(bodies)) {
    const size = bytesOf(body);
    assert.ok(size <= JSON_BODY_LIMIT_BYTES, `${name}: ${size} > ${JSON_BODY_LIMIT_BYTES}`);
  }
  // 고치기 전에 실패하던 것들 — 셈이 맞는지 확인하는 겸.
  for (const name of ['secretComment', 'secretEdit', 'plainEdit', 'postEdit', 'note']) {
    assert.ok(bytesOf(bodies[name]) > EXPRESS_DEFAULT_LIMIT, `${name}은(는) 기본 상한으로도 들어간다`);
  }
  // 한글로 채운 5만 자 노트도 예전엔 실패했다(15만 바이트).
  assert.ok(bytesOf({ title: '노트', body: '가'.repeat(NOTE_BODY_MAX) }) > EXPRESS_DEFAULT_LIMIT);
});

test('파서: 로그인한 요청은 가장 큰 정상 본문까지 그대로 읽는다', async () => {
  const parser = createJsonBodyParser({ isSignedIn: signedIn });
  const bodies = largestRestBodies();
  for (const name of ['secretComment', 'postEdit', 'note']) {
    const { err, body } = await parse(parser, fakeRequest(bodies[name]));
    assert.equal(err, undefined, `${name}: ${err?.message}`);
    assert.deepEqual(body, bodies[name], name);
  }
  // 상한을 넘으면 413으로 답할 오류.
  const tooBig = await parse(parser, fakeRequest({ text: 'A'.repeat(JSON_BODY_LIMIT_BYTES) }));
  assert.equal(tooBig.err?.type, 'entity.too.large');
  assert.deepEqual(bodyErrorReply(tooBig.err, tooBig.req, { isSignedIn: signedIn }), { status: 413, error: BODY_TOO_LARGE_ERROR });
});

test('파서: 토큰 없는 요청(로그인·가입 등 인증 전 경로)은 예전 상한(100KB) 그대로 — 큰 본문은 413', async () => {
  const parser = createJsonBodyParser({ isSignedIn: signedOut });
  const fits = { username: 'kim', password: 'x'.repeat(1000) };
  assert.deepEqual((await parse(parser, fakeRequest(fits))).body, fits);
  const { err, req } = await parse(parser, fakeRequest({ text: 'A'.repeat(EXPRESS_DEFAULT_LIMIT) }));
  assert.equal(err?.type, 'entity.too.large');
  assert.equal(err.limit, EXPRESS_DEFAULT_LIMIT);
  assert.deepEqual(bodyErrorReply(err, req, { isSignedIn: signedOut }), { status: 413, error: BODY_TOO_LARGE_ERROR });
  // 길이를 미리 알리지 않고(chunked) 보내도 읽다가 멈춘다.
  const chunked = await parse(
    parser,
    fakeRequest({ text: 'A'.repeat(EXPRESS_DEFAULT_LIMIT) }, { 'content-length': undefined, 'transfer-encoding': 'chunked' }),
  );
  assert.equal(chunked.err?.type, 'entity.too.large');
});

test('토큰이 붙었는데 만료·위조라 기본 상한으로 읽다 넘친 요청은 401 — 앱이 토큰을 새로 받아 다시 보내게', async () => {
  const seen = [];
  const isSignedIn = (req) => {
    seen.push(req.headers.authorization);
    return false;
  };
  const parser = createJsonBodyParser({ isSignedIn });
  const big = { text: envelopeOfLength(SECRET_TEXT_MAX) };
  const { err, req } = await parse(parser, fakeRequest(big, { authorization: 'Bearer expired.token.value' }));
  assert.equal(err?.type, 'entity.too.large');
  assert.deepEqual(seen, ['Bearer expired.token.value'], '파서는 요청마다 한 번 토큰을 본다');
  assert.deepEqual(bodyErrorReply(err, req, { isSignedIn }), { status: 401, error: BODY_TOKEN_INVALID_ERROR });
  // 새 토큰으로 다시 보내면 큰 상한으로 읽힌다.
  const retried = await parse(createJsonBodyParser({ isSignedIn: signedIn }), fakeRequest(big, { authorization: 'Bearer fresh' }));
  assert.equal(retried.err, undefined);
  assert.equal(retried.body.text.length, SECRET_TEXT_MAX);
  // 토큰이 맞는데도 넘쳤으면(정말 너무 큼) 그대로 413, Bearer가 아닌 Authorization도 413.
  assert.equal(bodyErrorReply(err, { headers: { authorization: 'Bearer ok' } }, { isSignedIn: signedIn }).status, 413);
  assert.equal(bodyErrorReply(err, { headers: { authorization: 'Basic abc' } }, { isSignedIn: signedOut }).status, 413);
});

test('본문 오류 응답: JSON 형식 오류는 400, 그 밖의 읽기 오류는 그 상태 코드 — 문구는 한국어', async () => {
  const parser = createJsonBodyParser({ isSignedIn: signedIn });
  const malformed = await parse(parser, fakeRequest('{"text": "닫지 않은 글'));
  assert.equal(malformed.err?.type, 'entity.parse.failed');
  assert.deepEqual(bodyErrorReply(malformed.err, malformed.req, { isSignedIn: signedIn }), { status: 400, error: BODY_MALFORMED_ERROR });
  // 알린 길이보다 적게 오고 끝남.
  const short = await parse(parser, fakeRequest('{"a":1}', { 'content-length': '100' }));
  assert.equal(short.err?.type, 'request.size.invalid');
  assert.deepEqual(bodyErrorReply(short.err, short.req, { isSignedIn: signedIn }), { status: 400, error: BODY_UNREADABLE_ERROR });
  // JSON이 받지 않는 문자셋.
  const charset = await parse(parser, fakeRequest('{"a":1}', { 'content-type': 'application/json; charset=latin1' }));
  assert.equal(charset.err?.type, 'charset.unsupported');
  assert.deepEqual(bodyErrorReply(charset.err, charset.req, { isSignedIn: signedIn }), { status: 415, error: BODY_UNREADABLE_ERROR });
});

test('본문 오류가 아닌 오류는 건드리지 않는다(공통 오류 처리가 예전처럼 500으로)', () => {
  const opts = { isSignedIn: signedIn };
  const req = { headers: {} };
  const dbError = Object.assign(new Error('Failed query: select 1'), { name: 'DrizzleQueryError', cause: { code: '42P01' } });
  const notFound = Object.assign(new Error('Not Found'), { status: 404, statusCode: 404, expose: true });
  const streamBug = Object.assign(new Error('stream is not readable'), { type: 'stream.not.readable', status: 500, expose: false });
  const fakeType = Object.assign(new Error('x'), { type: 'entity.too.large', status: 413 }); // expose가 없다 — http-errors가 만든 것이 아니다
  for (const err of [new Error('boom'), dbError, notFound, streamBug, fakeType, null, undefined, 'string error']) {
    assert.equal(bodyErrorReply(err, req, opts), null, String(err?.message ?? err));
  }
});

test('JSON이 아닌 요청(업로드의 multipart 등)은 어느 파서도 건드리지 않는다 — 본문 스트림이 그대로 남는다', async () => {
  for (const isSignedIn of [signedIn, signedOut]) {
    const parser = createJsonBodyParser({ isSignedIn });
    const upload = fakeRequest('--x\r\nContent-Disposition: form-data; name="file"\r\n\r\nhi\r\n--x--\r\n', {
      'content-type': 'multipart/form-data; boundary=x',
    });
    const { err, body, req } = await parse(parser, upload);
    assert.equal(err, undefined);
    assert.deepEqual(body, {});
    assert.equal(req.readableFlowing, null, 'multer가 읽을 스트림을 건드리지 않았다');
    assert.equal(req.readableEnded, false);
  }
});

test('index.js 연결: LiveKit 중계 다음에 이 파서를 쓰고, 마지막 오류 처리가 500보다 먼저 본문 오류를 답한다', () => {
  // 주석을 뺀 코드만 본다.
  const code = indexSource.replace(/^\s*\/\/.*$/gm, '');
  assert.doesNotMatch(code, /express\.json\(/, '기본 상한 파서를 따로 쓰지 않는다');
  const proxyAt = code.indexOf('app.use(LIVEKIT_PROXY_PREFIX, livekitHttpProxy(LIVEKIT_PORT));');
  const parserAt = code.indexOf('app.use(createJsonBodyParser({ isSignedIn: hasValidAccessToken }));');
  const firstRouteAt = code.indexOf("app.use('/auth', createAuthRouter(io));");
  assert.ok(proxyAt >= 0 && parserAt > proxyAt, 'LiveKit 중계는 본문을 그대로 흘려야 해서 파서보다 먼저다');
  assert.ok(firstRouteAt > parserAt, '라우트보다 먼저 본문을 읽는다');
  const handlerAt = code.lastIndexOf('app.use((err, req, res, next) => {');
  const replyAt = code.indexOf('bodyErrorReply(err, req, { isSignedIn: hasValidAccessToken })', handlerAt);
  const serverErrorAt = code.indexOf('res.status(500)', handlerAt);
  assert.ok(handlerAt >= 0 && replyAt > handlerAt && serverErrorAt > replyAt, '본문 오류를 500 처리보다 먼저 본다');
});

test('index.js CSP: 웹 앱의 그림·연결은 이 서버(와 data:·blob:·글꼴·화상회의 wss:)만 — 바깥 http(s) 그림을 받지 않는다', () => {
  const csp = /const WEB_APP_CSP = \[([\s\S]*?)\]\.join/.exec(indexSource)?.[1];
  assert.ok(csp, 'WEB_APP_CSP를 찾지 못했다');
  const directive = (name) => new RegExp(`"${name} ([^"]*)"`).exec(csp)?.[1].split(' ');
  assert.deepEqual(directive('img-src'), ["'self'", 'data:', 'blob:']);
  const connect = directive('connect-src');
  for (const scheme of ['https:', 'http:', '*']) assert.ok(!connect.includes(scheme), `connect-src에 ${scheme}`);
  // 웹 앱이 쓰는 것은 그대로다.
  assert.deepEqual(directive('script-src'), ["'self'", "'wasm-unsafe-eval'", 'blob:']);
  assert.ok(connect.includes('wss:') && connect.includes('https://fonts.gstatic.com'));
});
