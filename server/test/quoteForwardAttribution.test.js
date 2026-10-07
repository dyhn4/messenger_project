// messageAttribution.js(인용·전달 출처를 DB에서 읽어 확인하는 쪽) 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
// 조회 함수는 가짜 표를 답하는 함수를 넣고, DB 모듈은 불러오기만 하고 쓰지 않는다(접속 주소도 닿지 않는 값으로 정해 둔다).
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';

process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused';
const { db } = await import('../src/db/client.js');
for (const method of ['select', 'insert', 'update', 'delete', 'execute', 'transaction']) {
  mock.method(db, method, () => {
    throw new Error(`이 테스트는 DB를 쓰면 안 된다(db.${method})`);
  });
}
const { loadReadableSource, resolveAttribution } = await import('../src/messageAttribution.js');
const { toMessageDto } = await import('../src/messages.js');
const { ATTRIBUTION_NAME_MAX, QUOTE_PREVIEW_MAX } = await import('../src/messageLimits.js');
const { QUOTE_NOT_FOUND, QUOTE_SECRET_SOURCE, QUOTE_SECRET_TARGET, QUOTE_UPDATE_REQUIRED } = await import(
  '../src/quoteForwardRules.js'
);

const ME = '11111111-1111-4111-8111-111111111111';
const CEO = '22222222-2222-4222-8222-222222222222';
const MSG = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const MSG_SECRET = 'abababab-abab-4bab-8bab-abababababab';
const MSG_OLD_DM = 'acacacac-acac-4cac-8cac-acacacacacac';
const MSG_OTHER_ROOM = 'adadadad-adad-4dad-8dad-adadadadadad';
const COMMENT = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const NOTICE = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

/** 가짜 표 — 부른 조회를 [calls]에 남긴다. */
function fakeDb() {
  const calls = [];
  const rooms = {
    topic: { id: 'topic', type: 'topic', isSecret: false },
    secret: { id: 'secret', type: 'dm', isSecret: true },
    dm: { id: 'dm', type: 'dm', isSecret: false },
    other: { id: 'other', type: 'topic', isSecret: false },
  };
  const members = new Set(['topic', 'secret', 'dm'].map((r) => `${r}:${ME}`));
  const messages = {
    [MSG]: {
      id: MSG,
      roomId: 'topic',
      senderId: CEO,
      senderName: '예전 이름',
      type: 'image',
      text: '현장 사진',
      fileUrl: '/uploads/site.png',
      thumbnailUrl: '/uploads/site_t.jpg',
      fileName: 'site.png',
      createdAt: new Date('2026-09-01T00:00:00Z'),
    },
    [MSG_SECRET]: { id: MSG_SECRET, roomId: 'secret', senderId: CEO, senderName: '대표', type: 'text', text: '{"v":1}', createdAt: new Date() },
    [MSG_OLD_DM]: { id: MSG_OLD_DM, roomId: 'dm', senderId: CEO, senderName: '대표', type: 'text', text: '옛 글', createdAt: new Date('2026-01-01') },
    [MSG_OTHER_ROOM]: { id: MSG_OTHER_ROOM, roomId: 'other', senderId: CEO, senderName: '대표', type: 'text', text: '남의 방', createdAt: new Date() },
  };
  const comments = {
    [COMMENT]: { id: COMMENT, messageId: MSG, roomId: 'topic', senderId: CEO, senderName: '대표', type: 'text', text: '댓글 글', createdAt: new Date('2026-09-02') },
  };
  const loaders = {
    async findMessageById(id) {
      calls.push(['message', id]);
      return messages[id] ?? null;
    },
    async findCommentById(id) {
      calls.push(['comment', id]);
      return comments[id] ?? null;
    },
    async findAnnouncementById(id) {
      calls.push(['announcement', id]);
      return id === NOTICE ? { id, roomId: 'topic', authorName: '이영희', text: '내일 휴무', deletedAt: null } : null;
    },
    async listAttachmentsForMessages(ids) {
      calls.push(['attachments', ids]);
      return {};
    },
    async findRoomById(id) {
      calls.push(['room', id]);
      return rooms[id] ?? null;
    },
    async getDmHistoryFloor(roomId) {
      calls.push(['floor', roomId]);
      return roomId === 'dm' ? new Date('2026-06-01') : null;
    },
    async isRoomMember(roomId, userId) {
      calls.push(['member', roomId]);
      return members.has(`${roomId}:${userId}`);
    },
    async findUserById(id) {
      calls.push(['user', id]);
      return id === CEO ? { id, name: '홍길동', username: 'hong' } : null;
    },
  };
  return { loaders, calls };
}

const topic = { id: 'topic', type: 'topic', isSecret: false };

test('공유: 앱이 보낸 이름·미리보기 대신 원본(지금 이름·사진 미리보기)에서 채운다', async () => {
  const { loaders } = fakeDb();
  const result = await resolveAttribution(
    {
      payload: { quotedMessageId: MSG, quotedSenderName: '대표이사', quotedPreview: '지어낸 말' },
      senderId: ME,
      room: topic,
      sent: { text: '보세요', filePaths: [] },
    },
    loaders,
  );
  assert.deepEqual(result.fields, {
    quotedSenderName: '홍길동',
    quotedPreview: '사진을 보냈습니다',
    forwardedFromSenderName: null,
    forwardedFromCreatedAt: null,
  });
});

test('공유: 내가 멤버가 아닌 방의 글·1:1 "진짜 나가기" 이전 글·모양이 아닌 id는 찾을 수 없다', async () => {
  const { loaders, calls } = fakeDb();
  const quote = (id) =>
    resolveAttribution({ payload: { quotedMessageId: id }, senderId: ME, room: topic, sent: {} }, loaders);
  assert.deepEqual(await quote(MSG_OTHER_ROOM), { ok: false, error: QUOTE_NOT_FOUND });
  assert.deepEqual(await quote(MSG_OLD_DM), { ok: false, error: QUOTE_NOT_FOUND });
  calls.length = 0;
  assert.deepEqual(await quote("x' or 1=1 --"), { ok: false, error: QUOTE_NOT_FOUND });
  assert.deepEqual(calls, []); // DB에 묻지도 않는다(uuid 칸이라 DB 오류가 났다).
  assert.deepEqual(await quote(MSG_SECRET), { ok: false, error: QUOTE_SECRET_SOURCE });
});

test('공유: 댓글도 같은 화면으로 공유한다 — 메시지에 없으면 댓글에서 찾는다', async () => {
  const { loaders } = fakeDb();
  const result = await resolveAttribution(
    { payload: { quotedMessageId: COMMENT }, senderId: ME, room: topic, sent: {} },
    loaders,
  );
  assert.equal(result.fields.quotedPreview, '댓글 글');
  assert.equal(result.fields.quotedSenderName, '홍길동');
});

test('공지 공유: 그 토픽의 멤버만, 카드는 공지에서', async () => {
  const { loaders } = fakeDb();
  const result = await resolveAttribution(
    { payload: { quotedAnnouncementId: NOTICE, quotedPreview: '지어낸 공지' }, senderId: ME, room: topic, sent: {} },
    loaders,
  );
  assert.equal(result.fields.quotedSenderName, '이영희');
  assert.equal(result.fields.quotedPreview, '내일 휴무');
  const outsider = await resolveAttribution(
    { payload: { quotedAnnouncementId: NOTICE }, senderId: CEO, room: topic, sent: {} },
    loaders,
  );
  assert.equal(outsider.ok, false);
});

test('예전 앱의 공유(이름·미리보기 글만)는 거절, 예전 앱의 전달(이름·시각 글만)은 표시만 빼고 보낸다', async () => {
  const { loaders, calls } = fakeDb();
  assert.deepEqual(
    await resolveAttribution(
      { payload: { quotedSenderName: '대표이사', quotedPreview: '지어낸 말' }, senderId: ME, room: topic, sent: {} },
      loaders,
    ),
    { ok: false, error: QUOTE_UPDATE_REQUIRED },
  );
  const forward = await resolveAttribution(
    { payload: { forwardedFromSenderName: '대표이사', forwardedFromCreatedAt: 1 }, senderId: ME, room: topic, sent: { text: '글' } },
    loaders,
  );
  assert.equal(forward.ok, true);
  assert.equal(forward.fields.forwardedFromSenderName, null);
  assert.deepEqual(calls, []);
});

test('전달: 원본 그대로면 원본의 이름·시각, 고친 글이면 표시 없이', async () => {
  const { loaders } = fakeDb();
  const forward = (text, filePaths) =>
    resolveAttribution({ payload: { forwardedFromMessageId: MSG }, senderId: ME, room: topic, sent: { text, filePaths } }, loaders);
  const same = await forward('현장 사진', ['/uploads/site.png', '/uploads/site_t.jpg']);
  assert.equal(same.fields.forwardedFromSenderName, '홍길동');
  assert.equal(same.fields.forwardedFromCreatedAt.toISOString(), '2026-09-01T00:00:00.000Z');
  const edited = await forward('대표 지시: 현장 사진', ['/uploads/site.png']);
  assert.equal(edited.ok, true);
  assert.equal(edited.fields.forwardedFromSenderName, null);
});

test('비밀 대화로 보내면 출처를 읽지도 않는다 — 공유는 거절, 전달 표시는 뺀다', async () => {
  const { loaders, calls } = fakeDb();
  const secretRoom = { id: 'secret', type: 'dm', isSecret: true };
  assert.deepEqual(
    await resolveAttribution({ payload: { quotedMessageId: MSG }, senderId: ME, room: secretRoom, sent: {} }, loaders),
    { ok: false, error: QUOTE_SECRET_TARGET },
  );
  const forward = await resolveAttribution(
    { payload: { forwardedFromMessageId: MSG }, senderId: ME, room: secretRoom, sent: { text: '현장 사진' } },
    loaders,
  );
  assert.equal(forward.fields.forwardedFromSenderName, null);
  assert.deepEqual(calls, []);
});

test('예전에 저장된 끝없이 긴 인용·전달 글도 내려줄 때는 상한으로 자른다', () => {
  const dto = toMessageDto({
    id: MSG,
    roomId: 'topic',
    senderId: ME,
    senderName: '나',
    type: 'text',
    text: '공유합니다',
    createdAt: new Date(),
    quotedSenderName: '가'.repeat(5000),
    quotedPreview: '나'.repeat(500000),
    forwardedFromSenderName: '다'.repeat(5000),
    forwardedFromCreatedAt: new Date('2026-09-01'),
  });
  assert.equal(dto.quotedSenderName, `${'가'.repeat(ATTRIBUTION_NAME_MAX)}…`);
  assert.equal(dto.quotedPreview, `${'나'.repeat(QUOTE_PREVIEW_MAX)}…`);
  assert.equal(dto.forwardedFromSenderName, `${'다'.repeat(ATTRIBUTION_NAME_MAX)}…`);
  assert.equal(toMessageDto({ id: MSG, roomId: 'topic', createdAt: new Date() }).quotedPreview, null);
});

test('출처 요청이 없으면 DB를 읽지 않는다', async () => {
  const { loaders, calls } = fakeDb();
  const result = await resolveAttribution({ payload: { type: 'text', text: '안녕' }, senderId: ME, room: topic, sent: {} }, loaders);
  assert.equal(result.ok, true);
  assert.deepEqual(calls, []);
  assert.equal(await loadReadableSource(MSG, null, loaders), null);
});
