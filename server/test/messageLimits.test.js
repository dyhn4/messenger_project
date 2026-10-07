// 메시지·댓글 길이 상한과 보내기 횟수 제한 단위 테스트(messageLimits.js) — `node --test test/*.test.js` (DB·서버 없이 돈다).
// 비밀 대화의 상한은 "평문 상한 안의 가장 긴 글을 앱과 같은 방식으로 암호화한 봉투"가 들어가는지로 확인한다.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { test } from 'node:test';
import {
  clipGraphemes,
  COMMENT_CREATE_SUSTAINED,
  createPairLimiter,
  FILE_NAME_ERROR,
  FILE_NAME_MAX,
  fileFieldsDenial,
  MESSAGE_SEND_BURST,
  MESSAGE_SEND_SUSTAINED,
  MESSAGE_TEXT_MAX,
  MESSAGE_TEXT_MAX_BYTES,
  messageRateLimitText,
  messageTextDenial,
  MIME_TYPE_ERROR,
  postBytesDenial,
  sanitizeFileSize,
  SECRET_TEXT_MAX,
  sendCarriesFiles,
  SOCKET_MAX_PAYLOAD_BYTES,
  TEXT_TOO_LONG_ERROR,
} from '../src/messageLimits.js';
import { graphemeLength, POST_TEXT_MAX } from '../src/permissions.js';

/**
 * 앱(client secret_chat_crypto.dart encryptEnvelope)과 같은 모양의 봉투 — AES-GCM 암호문(평문 + 16바이트 태그)을 base64로 담은 JSON.
 * epoch·n은 가장 긴 숫자로 둔다.
 */
function envelopeOf(plaintext) {
  const key = crypto.randomBytes(32);
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, nonce);
  const ct = Buffer.concat([cipher.update(Buffer.from(plaintext, 'utf8')), cipher.final(), cipher.getAuthTag()]);
  return JSON.stringify({
    v: 1,
    epoch: Number.MAX_SAFE_INTEGER,
    n: Number.MAX_SAFE_INTEGER,
    nonce: nonce.toString('base64'),
    ciphertext: ct.toString('base64'),
  });
}

/** 사진·파일 메시지의 평문(client session.dart encryptAttachmentPayload) — 설명글을 파일 정보·키와 함께 JSON으로. */
function attachmentPlaintext(caption, fileName = '가'.repeat(FILE_NAME_MAX)) {
  const key = crypto.randomBytes(32).toString('base64');
  const nonce = crypto.randomBytes(12).toString('base64');
  return JSON.stringify({
    caption,
    fileName,
    fileSize: 2147483647,
    mimeType: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    attachmentKey: key,
    attachmentNonce: nonce,
    thumbnailKey: key,
    thumbnailNonce: nonce,
  });
}

test('글 상한: 게시글 본문과 같은 글자 수(이모지 한 덩어리 = 1자)까지', () => {
  assert.equal(MESSAGE_TEXT_MAX, POST_TEXT_MAX);
  assert.equal(messageTextDenial('가'.repeat(MESSAGE_TEXT_MAX)), null);
  assert.match(messageTextDenial('가'.repeat(MESSAGE_TEXT_MAX + 1)), /20,000자 이내/);
  assert.match(messageTextDenial('가'.repeat(MESSAGE_TEXT_MAX + 1), { subject: '댓글은' }), /^댓글은 /);
  // 이모지는 UTF-16으로 두 칸이지만 한 글자다 — 상한까지 받는다.
  const emoji = '😀'.repeat(MESSAGE_TEXT_MAX);
  assert.equal(emoji.length, 2 * MESSAGE_TEXT_MAX);
  assert.equal(messageTextDenial(emoji), null);
  assert.equal(messageTextDenial(''), null);
  assert.equal(messageTextDenial(null), null);
});

test('글 상한: 결합 문자로 한 글자를 끝없이 키운 글은 바이트 상한에 걸린다', () => {
  const zalgo = `a${'́'.repeat(MESSAGE_TEXT_MAX_BYTES)}`;
  assert.equal(graphemeLength(zalgo), 1);
  assert.equal(messageTextDenial(zalgo), TEXT_TOO_LONG_ERROR);
  // 한글 상한 길이(3바이트 × 2만)는 바이트 상한 안이다.
  assert.ok(Buffer.byteLength('가'.repeat(MESSAGE_TEXT_MAX)) <= MESSAGE_TEXT_MAX_BYTES);
});

test('이모티콘 메시지의 글(이모티콘 id)은 짧은 id만', () => {
  assert.equal(messageTextDenial('server:3f1c2d4e-0000-4000-8000-000000000000', { sticker: true }), null);
  assert.ok(messageTextDenial('x'.repeat(201), { sticker: true }));
});

test('비밀 대화 상한: 평문 상한 안의 가장 긴 글을 암호화한 봉투가 들어간다', () => {
  // 글 메시지 — 한글·이모지로 글자 수 상한을 채운 글, 바이트 상한을 채운 글.
  const hangul = MESSAGE_TEXT_MAX - 1;
  for (const plain of [
    '가'.repeat(MESSAGE_TEXT_MAX),
    '😀'.repeat(MESSAGE_TEXT_MAX),
    // 글자 수를 거의 다 쓰고, 남은 바이트를 마지막 글자에 붙인 결합 문자(2바이트씩)로 채운 글.
    `${'가'.repeat(hangul)}${'́'.repeat(Math.floor((MESSAGE_TEXT_MAX_BYTES - 3 * hangul) / 2))}`,
  ]) {
    assert.equal(messageTextDenial(plain), null);
    const envelope = envelopeOf(plain);
    assert.ok(envelope.length <= SECRET_TEXT_MAX, `${envelope.length} > ${SECRET_TEXT_MAX}`);
    assert.equal(messageTextDenial(envelope, { secret: true }), null);
  }
  // 사진·파일 메시지 — 설명글이 JSON에서 가장 크게 불어나는 경우: 제어 문자(1바이트·1글자 → \u00XX 6바이트)로 글자 수를 다 쓰고
  // 남은 바이트를 결합 문자 덩어리 한 글자에 몰아 둔다. 파일 이름도 가장 길게.
  const controls = '\u0001'.repeat(MESSAGE_TEXT_MAX - 1);
  const worstCaption = `${controls}a${'́'.repeat((MESSAGE_TEXT_MAX_BYTES - controls.length - 1) / 2)}`;
  assert.equal(graphemeLength(worstCaption), MESSAGE_TEXT_MAX);
  assert.ok(Buffer.byteLength(worstCaption) <= MESSAGE_TEXT_MAX_BYTES);
  const worstFileName = `${'\u0002'.repeat(FILE_NAME_MAX - 1)}"`;
  const envelope = envelopeOf(attachmentPlaintext(worstCaption, worstFileName));
  assert.ok(envelope.length <= SECRET_TEXT_MAX, `${envelope.length} > ${SECRET_TEXT_MAX}`);
  // 그보다 훨씬 긴 봉투는 거절한다.
  assert.equal(messageTextDenial('A'.repeat(SECRET_TEXT_MAX + 1), { secret: true }), TEXT_TOO_LONG_ERROR);
});

test('소켓 한 번 상한: 정상 앱이 보내는 가장 큰 message:send 패킷보다 크고, 기본 1MB보다 작다', () => {
  const packet = (payload) => Buffer.byteLength(`42999${JSON.stringify(['message:send', payload])}`);
  const token = `/files/${'A'.repeat(140)}`;
  // 비밀 대화: 상한 길이의 봉투 + 파일 칸.
  const secret = packet({
    roomId: crypto.randomUUID(),
    type: 'file',
    text: 'A'.repeat(SECRET_TEXT_MAX),
    fileUrl: `/uploads/${crypto.randomUUID()}.bin`,
    fileName: 'encrypted',
    fileSize: 2147483647,
    mimeType: 'application/octet-stream',
    thumbnailUrl: `/uploads/${crypto.randomUUID()}.bin`,
  });
  // 일반 방: 글자·바이트 상한 안에서 JSON으로 가장 크게 불어나는 글 + 서식 2,000구간(링크 몇백 개) + 멘션 200개 + 첨부 30개.
  const controls = '\u0001'.repeat(MESSAGE_TEXT_MAX - 1);
  const text = `${controls}a${'́'.repeat((MESSAGE_TEXT_MAX_BYTES - controls.length - 1) / 2)}`;
  const plain = packet({
    roomId: crypto.randomUUID(),
    type: 'image',
    text,
    textFormat: Array.from({ length: 2000 }, (_, i) =>
      i % 5 === 0 ? { s: i, e: i + 1, f: 1, h: `https://example.com/${'p'.repeat(150)}` } : { s: i, e: i + 1, f: 63 },
    ),
    mentions: Array.from({ length: 200 }, (_, i) => ({ type: 'user', userId: crypto.randomUUID(), s: i, e: i + 1 })),
    attachments: Array.from({ length: 30 }, () => ({
      kind: 'image',
      fileUrl: token,
      fileName: '가'.repeat(FILE_NAME_MAX),
      fileSize: 2147483647,
      mimeType: 'image/jpeg',
      thumbnailUrl: token,
    })),
  });
  for (const size of [secret, plain]) {
    assert.ok(size < SOCKET_MAX_PAYLOAD_BYTES, `${size} >= ${SOCKET_MAX_PAYLOAD_BYTES}`);
  }
  assert.ok(SOCKET_MAX_PAYLOAD_BYTES < 1e6);
});

test('게시글 제목·본문의 바이트 상한', () => {
  assert.equal(postBytesDenial('제목', '본문'), null);
  assert.equal(postBytesDenial(`a${'́'.repeat(2000)}`, '본문'), TEXT_TOO_LONG_ERROR);
  assert.equal(postBytesDenial('제목', `a${'́'.repeat(MESSAGE_TEXT_MAX_BYTES)}`), TEXT_TOO_LONG_ERROR);
  assert.equal(postBytesDenial(null, null), null);
});

test('파일 이름·형식 상한', () => {
  assert.equal(fileFieldsDenial({ fileName: '가'.repeat(FILE_NAME_MAX), mimeType: 'image/png' }), null);
  assert.equal(fileFieldsDenial({ fileName: '가'.repeat(FILE_NAME_MAX + 1) }), FILE_NAME_ERROR);
  assert.equal(fileFieldsDenial({ fileName: `a${'́'.repeat(2000)}` }), FILE_NAME_ERROR);
  assert.equal(fileFieldsDenial({ mimeType: 'x'.repeat(256) }), MIME_TYPE_ERROR);
  assert.equal(fileFieldsDenial({ fileName: 42, mimeType: null }), null);
  assert.equal(fileFieldsDenial(), null);
});

test('파일 크기는 정수 칸에 들어가는 값만(아니면 null)', () => {
  assert.equal(sanitizeFileSize(0), 0);
  assert.equal(sanitizeFileSize(1073741824), 1073741824);
  for (const bad of [-1, 1.5, 2147483648, Number.NaN, Infinity, '10', null, undefined]) {
    assert.equal(sanitizeFileSize(bad), null, String(bad));
  }
});

test('clipGraphemes: 글자 단위로 자르고 잘렸으면 …', () => {
  assert.equal(clipGraphemes('가나다', 3), '가나다');
  assert.equal(clipGraphemes('가나다라', 3), '가나다…');
  // 이모지 조합(가족 이모지)을 반으로 자르지 않는다.
  const family = '👨‍👩‍👧';
  assert.equal(clipGraphemes(`${family}${family}`, 1), `${family}…`);
  assert.equal(clipGraphemes(null, 3), null);
});

test('보내기 횟수: 짧게 몰아 보내기와 길게 이어 보내기를 따로 센다', () => {
  let now = 0;
  const limiter = createPairLimiter({ max: 3, windowMs: 10_000 }, { max: 5, windowMs: 600_000 }, { now: () => now });
  for (let i = 0; i < 3; i++) assert.equal(limiter.hit('u'), 0);
  assert.ok(limiter.hit('u') > 0); // 10초에 3번을 넘었다.
  assert.equal(limiter.hit('other'), 0); // 사람마다 따로.
  now = 11_000;
  assert.equal(limiter.hit('u'), 0); // 짧은 창이 지나면 다시 — 하지만 긴 창에는 이미 5번째다(막힌 시도도 센다).
  now = 22_000;
  assert.ok(limiter.hit('u') > 60_000); // 10분에 5번을 넘었다 — 긴 창이 끝날 때까지.
  // 실제 값은 사람이 손으로 보내는 속도보다 훨씬 넉넉하다(초당 4통·10분에 600통).
  assert.ok(MESSAGE_SEND_BURST.max / (MESSAGE_SEND_BURST.windowMs / 1000) >= 4);
  assert.ok(MESSAGE_SEND_SUSTAINED.max >= 600);
});

test('보내기 횟수: 파일을 싣는 보내기는 10초 창에서 빠지고 10분 창에만 센다(고른 파일마다 한 통씩 몰아 보내는 앱)', () => {
  let now = 0;
  const limiter = createPairLimiter(MESSAGE_SEND_BURST, MESSAGE_SEND_SUSTAINED, { now: () => now });
  // 비밀 대화에서 사진 300장을 한 번에 골라 보내도(1초 안에) 끝까지 간다 — 예전엔 41번째부터 실패하고 남은 사진이 사라졌다.
  for (let i = 0; i < 300; i++) assert.equal(limiter.hit('u', { burst: false }), 0, `${i + 1}번째 사진`);
  // 그 사이 글은 여전히 10초 창으로 본다.
  for (let i = 0; i < MESSAGE_SEND_BURST.max; i++) assert.equal(limiter.hit('u'), 0);
  assert.ok(limiter.hit('u') > 0);
  // 파일을 붙여 10초 창을 피해도 10분 창(총량)은 못 넘는다 — 지금까지 300 + 41번을 셌다.
  now = 11_000;
  for (let i = 0; i < MESSAGE_SEND_SUSTAINED.max - 341; i++) assert.equal(limiter.hit('u', { burst: false }), 0);
  assert.ok(limiter.hit('u', { burst: false }) > 60_000);
  assert.ok(COMMENT_CREATE_SUSTAINED.max >= 300);
});

test('sendCarriesFiles: 파일 칸이나 첨부 목록에 경로 문자열이 있을 때만', () => {
  assert.equal(sendCarriesFiles({ type: 'image', fileUrl: '/uploads/a.png' }), true);
  assert.equal(sendCarriesFiles({ type: 'image', attachments: [{ fileUrl: '' }, { fileUrl: '/files/x' }] }), true);
  for (const payload of [
    { type: 'text', text: '안녕' },
    { type: 'image', fileUrl: '' },
    { type: 'image', attachments: [{ fileUrl: '' }, null, { fileUrl: 3 }] },
    { type: 'image', attachments: 'x' },
    null,
    'x',
  ]) {
    assert.equal(sendCarriesFiles(payload), false, JSON.stringify(payload));
  }
});

test('보내기 횟수 문구: 1분이 안 남았으면 초로', () => {
  assert.equal(messageRateLimitText(4200), '메시지를 너무 빠르게 보내고 있습니다. 5초 후 다시 시도하세요.');
  assert.equal(messageRateLimitText(5 * 60 * 1000), '메시지를 너무 빠르게 보내고 있습니다. 5분 후 다시 시도하세요.');
});
