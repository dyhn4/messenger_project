// "메시지 공유"(인용 카드)·"메시지 전달"(전달 표시)의 출처 규칙 단위 테스트(quoteForwardRules.js) — `node --test test/*.test.js`
// (DB·서버 없이 돈다). 이름·미리보기·시각은 서버가 원본에서 채우고, 앱이 보낸 글은 쓰지 않는다.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  ANNOUNCEMENT_NOT_FOUND,
  announcementQuote,
  attributionRequest,
  decideAttribution,
  forwardMatchesSource,
  QUOTE_NOT_FOUND,
  QUOTE_POLL,
  QUOTE_SECRET_SOURCE,
  QUOTE_SECRET_TARGET,
  QUOTE_UNSUPPORTED,
  QUOTE_UPDATE_REQUIRED,
  quotePreviewOf,
  quoteSourceDenial,
  sourceFilePaths,
} from '../src/quoteForwardRules.js';
import { QUOTE_PREVIEW_MAX } from '../src/messageLimits.js';

const ID = '33333333-3333-4333-8333-333333333333';
const CREATED = new Date('2026-09-29T09:30:00Z');

/** loadReadableSource가 돌려주는 모양의 출처. */
function source(overrides = {}) {
  return {
    kind: 'message',
    type: 'text',
    text: '회의는 3시입니다',
    title: null,
    fileName: null,
    createdAt: CREATED,
    senderName: '김철수',
    roomIsSecret: false,
    filePaths: [],
    ...overrides,
  };
}

test('attributionRequest: 새 앱은 id, 예전 앱은 글만 — 전달 글만 온 것은 요청으로 치지 않는다', () => {
  assert.deepEqual(attributionRequest({ quotedMessageId: ID, quotedSenderName: '대표이사' }), {
    quote: { kind: 'message', id: ID },
    forward: null,
  });
  assert.deepEqual(attributionRequest({ quotedAnnouncementId: ID }).quote, { kind: 'announcement', id: ID });
  assert.deepEqual(attributionRequest({ quotedSenderName: '대표이사 홍길동', quotedPreview: '지어낸 말' }).quote, {
    kind: 'legacy',
  });
  assert.deepEqual(attributionRequest({ quotedPreview: '' }).quote, { kind: 'legacy' });
  assert.deepEqual(attributionRequest({ forwardedFromMessageId: ID }).forward, { id: ID });
  assert.deepEqual(attributionRequest({ forwardedFromSenderName: '대표이사', forwardedFromCreatedAt: 1 }), {
    quote: null,
    forward: null,
  });
  assert.deepEqual(attributionRequest(null), { quote: null, forward: null });
});

test('감사의 공격: id 없이 이름·미리보기만 보낸 공유는 거절(업데이트 안내) — 지어낸 카드가 저장되지 않는다', () => {
  const request = attributionRequest({ type: 'text', quotedSenderName: '대표이사 홍길동', quotedPreview: '전 직원 상여금 취소' });
  assert.deepEqual(decideAttribution({ request }), { ok: false, error: QUOTE_UPDATE_REQUIRED });
});

test('인용 카드는 원본에서 채운다 — 앱이 함께 보낸 이름·미리보기는 쓰지 않는다', () => {
  const request = attributionRequest({ quotedMessageId: ID, quotedSenderName: '대표이사', quotedPreview: '지어낸 말' });
  const result = decideAttribution({ request, quoteSource: source() });
  assert.deepEqual(result, {
    ok: true,
    fields: {
      quotedSenderName: '김철수',
      quotedPreview: '회의는 3시입니다',
      forwardedFromSenderName: null,
      forwardedFromCreatedAt: null,
    },
  });
});

test('읽을 수 없는 원본·비밀 대화·투표·시스템 메시지는 공유할 수 없다', () => {
  const request = attributionRequest({ quotedMessageId: ID });
  assert.deepEqual(decideAttribution({ request, quoteSource: null }), { ok: false, error: QUOTE_NOT_FOUND });
  assert.equal(quoteSourceDenial(source({ roomIsSecret: true })), QUOTE_SECRET_SOURCE);
  assert.equal(quoteSourceDenial(source({ type: 'poll' })), QUOTE_POLL);
  assert.equal(quoteSourceDenial(source({ type: 'system' })), QUOTE_UNSUPPORTED);
  for (const type of ['text', 'image', 'file', 'sticker', 'post']) assert.equal(quoteSourceDenial(source({ type })), null);
});

test('비밀 대화로 보내는 글에는 인용 카드·전달 표시를 싣지 않는다(서버가 읽을 수 있는 평문이라)', () => {
  const quote = attributionRequest({ quotedMessageId: ID });
  assert.deepEqual(decideAttribution({ request: quote, targetIsSecret: true, quoteSource: source() }), {
    ok: false,
    error: QUOTE_SECRET_TARGET,
  });
  const forward = attributionRequest({ forwardedFromMessageId: ID });
  const result = decideAttribution({
    request: forward,
    targetIsSecret: true,
    forwardSource: source(),
    sent: { text: '회의는 3시입니다', filePaths: [] },
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.forwardedFromSenderName, null);
});

test('인용 미리보기 — 앱의 미리보기와 같은 글, 길면 잘라 둔다', () => {
  assert.equal(quotePreviewOf(source({ type: 'image', text: '설명글' })), '사진을 보냈습니다');
  assert.equal(quotePreviewOf(source({ type: 'file', fileName: '보고서.pdf' })), '보고서.pdf 파일을 보냈습니다');
  assert.equal(quotePreviewOf(source({ type: 'file' })), '파일을 보냈습니다');
  assert.equal(quotePreviewOf(source({ type: 'sticker', text: 'server:x' })), '이모티콘을 보냈습니다');
  assert.equal(quotePreviewOf(source({ type: 'post', title: '주간 보고', text: '긴 본문' })), '게시글: 주간 보고');
  const long = quotePreviewOf(source({ text: '가'.repeat(5000) }));
  assert.equal(long, `${'가'.repeat(QUOTE_PREVIEW_MAX)}…`);
});

test('공지 공유 — 작성자 이름과 글(사진만 있으면 [사진]), 못 읽으면 거절', () => {
  assert.deepEqual(announcementQuote({ authorName: '이영희', text: '  내일 휴무  ', imageUrl: null }), {
    quotedSenderName: '이영희',
    quotedPreview: '내일 휴무',
  });
  assert.equal(announcementQuote({ authorName: '이영희', text: '', imageUrl: '/uploads/a.png' }).quotedPreview, '[사진]');
  assert.equal(announcementQuote({ authorName: '', text: '글' }).quotedSenderName, '알 수 없음');
  const request = attributionRequest({ quotedAnnouncementId: ID });
  assert.deepEqual(decideAttribution({ request, announcement: null }), { ok: false, error: ANNOUNCEMENT_NOT_FOUND });
  assert.equal(decideAttribution({ request, announcement: { authorName: '이영희', text: '공지' } }).fields.quotedPreview, '공지');
});

test('전달 표시는 원본에서 — 이름은 지금 이름, 시각은 원본 시각', () => {
  const request = attributionRequest({ forwardedFromMessageId: ID, forwardedFromSenderName: '대표이사', forwardedFromCreatedAt: 0 });
  const result = decideAttribution({
    request,
    forwardSource: source(),
    sent: { text: '회의는 3시입니다', filePaths: [] },
  });
  assert.equal(result.fields.forwardedFromSenderName, '김철수');
  assert.equal(result.fields.forwardedFromCreatedAt.getTime(), CREATED.getTime());
});

test('전달 표시는 내용이 원본 그대로일 때만 — 고친 글·다른 파일이면 표시만 뺀다(전달은 막지 않는다)', () => {
  const request = attributionRequest({ forwardedFromMessageId: ID });
  const withFiles = source({ type: 'image', text: '사진 설명', filePaths: ['/uploads/a.png', '/uploads/a_t.jpg', '/uploads/b.png'] });
  const decide = (sent) => decideAttribution({ request, forwardSource: withFiles, sent }).fields.forwardedFromSenderName;
  assert.equal(decide({ text: '사진 설명', filePaths: ['/uploads/a.png', '/uploads/a_t.jpg'] }), '김철수');
  assert.equal(decide({ text: '  사진 설명 ', filePaths: [] }), '김철수'); // 앞뒤 공백·파일 일부만은 괜찮다
  assert.equal(decide({ text: '대표이사 지시: 사진 설명', filePaths: [] }), null); // 고친 글
  assert.equal(decide({ text: '사진 설명', filePaths: ['/uploads/other.png'] }), null); // 원본에 없는 파일
  // 읽을 수 없는 원본·비밀 대화 원본·투표면 표시 없이(거절 아님).
  for (const forwardSource of [null, source({ roomIsSecret: true }), source({ type: 'poll' })]) {
    const result = decideAttribution({ request, forwardSource, sent: { text: '회의는 3시입니다', filePaths: [] } });
    assert.equal(result.ok, true);
    assert.equal(result.fields.forwardedFromSenderName, null);
  }
});

test('forwardMatchesSource: 전달 화면이 채워 주는 글 — 게시글은 "제목\\n\\n본문" 또는 본문, 이모티콘은 id 그대로', () => {
  const post = source({ type: 'post', title: '주간 보고', text: '이번 주 일정' });
  assert.equal(forwardMatchesSource({ text: '주간 보고\n\n이번 주 일정', source: post }), true);
  assert.equal(forwardMatchesSource({ text: '이번 주 일정', source: post }), true);
  assert.equal(forwardMatchesSource({ text: '주간 보고', source: post }), false);
  assert.equal(forwardMatchesSource({ text: '주간 보고', source: source({ type: 'post', title: '주간 보고', text: '' }) }), true);
  const sticker = source({ type: 'sticker', text: 'server:abc' });
  assert.equal(forwardMatchesSource({ text: 'server:abc', source: sticker }), true);
  assert.equal(forwardMatchesSource({ text: 'server:other', source: sticker }), false);
  // 글 없는 사진을 글 없이 전달.
  assert.equal(forwardMatchesSource({ text: null, source: source({ type: 'image', text: null }) }), true);
});

test('sourceFilePaths: 메시지는 지우지 않은 첨부와 파일 칸, 댓글은 자기 파일 칸', () => {
  const row = { fileUrl: '/uploads/a.png', thumbnailUrl: '/uploads/a_t.jpg', fileDeletedAt: null };
  const attachments = [
    { fileUrl: '/uploads/a.png', thumbnailUrl: '/uploads/a_t.jpg', deletedAt: null },
    { fileUrl: '/uploads/b.pdf', thumbnailUrl: null, deletedAt: new Date() },
  ];
  assert.deepEqual(sourceFilePaths({ kind: 'message', row, attachments }), ['/uploads/a.png', '/uploads/a_t.jpg']);
  assert.deepEqual(sourceFilePaths({ kind: 'message', row: { ...row, fileDeletedAt: new Date() } }), []);
  assert.deepEqual(sourceFilePaths({ kind: 'comment', row: { fileUrl: '/uploads/c.png', thumbnailUrl: null } }), ['/uploads/c.png']);
});
