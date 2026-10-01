// 멘션·알림 순수 규칙 단위 테스트 — `node --test test/` (DB·서버·FCM 없이 돈다).
// 푸시 호출 대상 계산(pushTargetsFor)은 실제 FCM 전송과 분리된 함수라 여기서 그대로 검증한다.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  DEFAULT_NOTIFICATION_SETTINGS,
  MENTION_MAX,
  boardRecipientsFor,
  canMentionAll,
  diffMentions,
  mentionTargets,
  notificationPushBody,
  previewOf,
  pushTargetsFor,
  roomNameForViewer,
  sanitizeMentions,
} from '../src/notificationRules.js';

const ME = 'user-me';
const A = 'user-a';
const B = 'user-b';
const OUT = 'user-outsider';
const members = new Set([ME, A, B]);
const topic = { id: 'r1', type: 'topic', isSecret: false, isSelf: false };
const group = { id: 'r2', type: 'group', isSecret: false, isSelf: false };
const dm = { id: 'r3', type: 'dm', isSecret: false, isSelf: false };
const secret = { id: 'r4', type: 'dm', isSecret: true, isSelf: false };
const self = { id: 'r5', type: 'dm', isSecret: false, isSelf: true };

const opts = (room = topic, extra = {}) => ({ room, senderId: ME, memberIdSet: members, ...extra });

test('sanitizeMentions: 멤버 개인 멘션은 그대로, 방 멤버가 아닌 사람·본인은 버린다', () => {
  const text = '@가 @나 @외부 @나자신';
  const out = sanitizeMentions(
    [
      { type: 'user', userId: A, s: 0, e: 2 },
      { type: 'user', userId: B, s: 3, e: 5 },
      { type: 'user', userId: OUT, s: 6, e: 9 },
      { type: 'user', userId: ME, s: 10, e: 14 },
    ],
    text,
    opts(),
  );
  assert.deepEqual(out, [
    { type: 'user', userId: A, s: 0, e: 2 },
    { type: 'user', userId: B, s: 3, e: 5 },
  ]);
});

test('sanitizeMentions: 구간 오류(음수·역순·빈 구간·본문 밖·정수 아님)는 그 항목만 버린다', () => {
  const text = '@가나다';
  const out = sanitizeMentions(
    [
      { type: 'user', userId: A, s: -1, e: 2 },
      { type: 'user', userId: A, s: 2, e: 2 },
      { type: 'user', userId: A, s: 3, e: 1 },
      { type: 'user', userId: A, s: 0, e: 99 },
      { type: 'user', userId: A, s: 0.5, e: 2 },
      { type: 'user', userId: A, s: '0', e: 2 },
      { type: 'user', userId: B, s: 0, e: 4 }, // 유일하게 올바른 것(e == text.length)
    ],
    text,
    opts(),
  );
  assert.deepEqual(out, [{ type: 'user', userId: B, s: 0, e: 4 }]);
});

test('sanitizeMentions: 같은 사람은 본문에서 먼저 나온 하나만, 겹치는 구간은 앞선 것만', () => {
  const text = '@가나 @가나 @다라';
  const out = sanitizeMentions(
    [
      { type: 'user', userId: A, s: 4, e: 7 },
      { type: 'user', userId: A, s: 0, e: 3 },
      { type: 'user', userId: B, s: 2, e: 5 }, // 첫 멘션(0~3)과 겹침
    ],
    text,
    opts(),
  );
  assert.deepEqual(out, [{ type: 'user', userId: A, s: 0, e: 3 }]);
});

test('sanitizeMentions: @all은 토픽·그룹에서만, 한 글에 하나', () => {
  const raw = [
    { type: 'all', s: 0, e: 4 },
    { type: 'all', s: 5, e: 9 },
  ];
  const text = '@all @all';
  assert.deepEqual(sanitizeMentions(raw, text, opts(topic)), [{ type: 'all', s: 0, e: 4 }]);
  assert.deepEqual(sanitizeMentions(raw, text, opts(group)), [{ type: 'all', s: 0, e: 4 }]);
  assert.deepEqual(sanitizeMentions(raw, text, opts(dm)), []);
  assert.deepEqual(sanitizeMentions(raw, text, opts(self)), []);
  assert.deepEqual(sanitizeMentions(raw, text, opts(secret)), []);
  assert.equal(canMentionAll(topic), true);
  assert.equal(canMentionAll(dm), false);
});

test('sanitizeMentions: 비밀 대화는 개인 멘션도 전부 버린다', () => {
  assert.deepEqual(sanitizeMentions([{ type: 'user', userId: A, s: 0, e: 2 }], '@가', opts(secret)), []);
});

test('sanitizeMentions: 1:1·나와의 대화에서도 개인 멘션을 전부 버린다(토픽·그룹에서만 멘션)', () => {
  const raw = [{ type: 'user', userId: A, s: 0, e: 2 }];
  assert.deepEqual(sanitizeMentions(raw, '@가', opts(dm)), []);
  assert.deepEqual(sanitizeMentions(raw, '@가', opts(self)), []);
  assert.deepEqual(sanitizeMentions(raw, '@가', opts(topic)), raw);
  assert.deepEqual(sanitizeMentions(raw, '@가', opts(group)), raw);
});

test('sanitizeMentions: 최대 50개', () => {
  const many = new Set(Array.from({ length: 80 }, (_, i) => `u${i}`));
  const raw = Array.from({ length: 80 }, (_, i) => ({ type: 'user', userId: `u${i}`, s: i * 2, e: i * 2 + 1 }));
  const out = sanitizeMentions(raw, 'x'.repeat(200), { room: topic, senderId: ME, memberIdSet: many });
  assert.equal(out.length, MENTION_MAX);
  assert.equal(out[0].userId, 'u0');
});

test('sanitizeMentions: 배열이 아니거나 본문이 없으면 []', () => {
  assert.deepEqual(sanitizeMentions(null, '@가', opts()), []);
  assert.deepEqual(sanitizeMentions('x', '@가', opts()), []);
  assert.deepEqual(sanitizeMentions([{ type: 'user', userId: A, s: 0, e: 2 }], '', opts()), []);
  assert.deepEqual(sanitizeMentions([{ type: 'user', userId: A, s: 0, e: 2 }], null, opts()), []);
  assert.deepEqual(sanitizeMentions([{ type: 'dept', s: 0, e: 2 }, 7, null], '@가', opts()), []);
});

test('sanitizeMentions: shift(서버가 잘라낸 앞 공백)만큼 구간을 당긴다', () => {
  // 원문 "  @가 안녕" → 서버 저장 "@가 안녕", 클라이언트 구간은 2~4.
  const out = sanitizeMentions([{ type: 'user', userId: A, s: 2, e: 4 }], '@가 안녕', opts(topic, { shift: 2 }));
  assert.deepEqual(out, [{ type: 'user', userId: A, s: 0, e: 2 }]);
});

test('diffMentions: 새 멘션·사라진 멘션·@all 변화', () => {
  const before = [
    { type: 'user', userId: A, s: 0, e: 2 },
    { type: 'user', userId: B, s: 3, e: 5 },
  ];
  const after = [
    { type: 'user', userId: A, s: 1, e: 3 }, // 자리만 바뀜 → 그대로
    { type: 'all', s: 4, e: 8 },
  ];
  assert.deepEqual(diffMentions(before, after), {
    addedUserIds: [],
    removedUserIds: [B],
    addedAll: true,
    removedAll: false,
  });
  assert.deepEqual(diffMentions(after, before), {
    addedUserIds: [B],
    removedUserIds: [],
    addedAll: false,
    removedAll: true,
  });
  assert.deepEqual(diffMentions(null, null), { addedUserIds: [], removedUserIds: [], addedAll: false, removedAll: false });
  assert.deepEqual(mentionTargets(after), { userIds: [A], all: true });
});

test('previewOf: 공백 정리, 120자(글자 단위)로 자른다', () => {
  assert.equal(previewOf('  안녕 \n 하세요  '), '안녕 하세요');
  assert.equal(Array.from(previewOf('가'.repeat(300))).length, 120);
  assert.equal(Array.from(previewOf('😀'.repeat(200))).length, 120);
  assert.equal(previewOf(null), '');
});

test('notificationPushBody: 규약 문구', () => {
  assert.equal(notificationPushBody('mention', '홍길동', '안녕'), '홍길동님이 회원님을 멘션했습니다: 안녕');
  assert.equal(notificationPushBody('mention_all', '홍길동', '공지'), '홍길동님이 모두를 멘션했습니다: 공지');
});

// ── 푸시 호출 대상 ────────────────────────────────────────────────────────

test('pushTargetsFor: 개인 멘션은 방을 뮤트한 사람에게도 푸시한다', () => {
  const targets = pushTargetsFor({ kind: 'mention', recipientIds: [A, B], mutedIds: new Set([A]) });
  assert.deepEqual(targets, [A, B]);
});

test('pushTargetsFor: @all은 방 뮤트를 존중한다(뮤트한 사람 제외)', () => {
  const targets = pushTargetsFor({ kind: 'mention_all', recipientIds: [A, B], mutedIds: new Set([A]) });
  assert.deepEqual(targets, [B]);
});

test('pushTargetsFor: @all은 mentionAll=false인 사람에겐 푸시만 생략', () => {
  const settings = new Map([[B, { mentionAll: false }]]);
  const targets = pushTargetsFor({ kind: 'mention_all', recipientIds: [A, B], settingsOf: (id) => settings.get(id) });
  assert.deepEqual(targets, [A]);
});

test('pushTargetsFor: 소켓이 붙어 있는(온라인) 사람은 뺀다', () => {
  const targets = pushTargetsFor({ kind: 'mention', recipientIds: [A, B], isOnline: (id) => id === A });
  assert.deepEqual(targets, [B]);
});

test('pushTargetsFor: 게시글 수정은 뮤트 제외, 새 글·댓글은 일반 채팅 푸시가 이미 가므로 따로 안 보낸다', () => {
  assert.deepEqual(pushTargetsFor({ kind: 'board_edit', recipientIds: [A, B], mutedIds: new Set([B]) }), [A]);
  assert.deepEqual(pushTargetsFor({ kind: 'board_post', recipientIds: [A, B] }), []);
  assert.deepEqual(pushTargetsFor({ kind: 'board_comment', recipientIds: [A, B] }), []);
});

// ── 보드 알림 수신자 ──────────────────────────────────────────────────────

const levels = { [ME]: 'important', [A]: 'all', [B]: 'important', [OUT]: 'new' };
const levelOf = (id) => levels[id] ?? null; // 설정 없는 사람은 null → 기본값(important)
const everyone = [ME, A, B, OUT];

test('boardRecipientsFor: 새 게시글은 모든 수준의 멤버(행위자 제외)가 받는다', () => {
  assert.deepEqual(boardRecipientsFor({ event: 'post', memberIds: everyone, actorId: ME, levelOf }), [A, B, OUT]);
});

test('boardRecipientsFor: 게시글 수정은 boardLevel=all만', () => {
  assert.deepEqual(boardRecipientsFor({ event: 'edit', memberIds: everyone, actorId: ME, levelOf }), [A]);
});

test('boardRecipientsFor: 댓글은 all=전원, important=글쓴이만, new=없음', () => {
  // 글쓴이가 B(important)인 글에 ME가 댓글 → A(all)와 B(글쓴이)만
  assert.deepEqual(boardRecipientsFor({ event: 'comment', memberIds: everyone, actorId: ME, postAuthorId: B, levelOf }), [A, B]);
  // 글쓴이가 OUT(new)인 글 → all인 A만(new인 글쓴이는 안 받는다)
  assert.deepEqual(boardRecipientsFor({ event: 'comment', memberIds: everyone, actorId: ME, postAuthorId: OUT, levelOf }), [A]);
  // 글쓴이 본인이 댓글을 달면 본인은 제외
  assert.deepEqual(boardRecipientsFor({ event: 'comment', memberIds: everyone, actorId: B, postAuthorId: B, levelOf }), [A]);
});

test('boardRecipientsFor: 설정이 없는 사람은 기본값(important) — 새 글과 내 글의 댓글만, 수정은 못 받는다', () => {
  assert.equal(DEFAULT_NOTIFICATION_SETTINGS.boardLevel, 'important');
  const none = () => null;
  assert.deepEqual(boardRecipientsFor({ event: 'post', memberIds: everyone, actorId: ME, levelOf: none }), [A, B, OUT]);
  assert.deepEqual(boardRecipientsFor({ event: 'edit', memberIds: everyone, actorId: ME, levelOf: none }), []);
  // 글쓴이(B)만 댓글 알림을 받는다.
  assert.deepEqual(
    boardRecipientsFor({ event: 'comment', memberIds: everyone, actorId: ME, postAuthorId: B, levelOf: none }),
    [B],
  );
});

test('boardRecipientsFor: 같은 글로 멘션 알림을 받는 사람은 뺀다', () => {
  assert.deepEqual(
    boardRecipientsFor({ event: 'post', memberIds: everyone, actorId: ME, levelOf, excludeIds: [A] }),
    [B, OUT],
  );
});

test('roomNameForViewer: 나와의 대화·이름 있는 방·DM 상대·이름 없는 그룹', () => {
  const users = [
    { id: ME, name: '나' },
    { id: A, name: '가나' },
    { id: B, name: '다라' },
  ];
  assert.equal(roomNameForViewer({ isSelf: true }, users, ME), '나와의 대화');
  assert.equal(roomNameForViewer({ name: '영업', type: 'topic' }, users, ME), '영업');
  assert.equal(roomNameForViewer({ type: 'dm' }, [users[0], users[1]], ME), '가나');
  assert.equal(roomNameForViewer({ type: 'group' }, users, ME), '가나, 다라');
});
