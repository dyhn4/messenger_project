import assert from 'node:assert/strict';
import test from 'node:test';
import {
  REPLY_TICKET_TTL_MS,
  replyAllowed,
  signReplyTicket,
  unreadDeltaOf,
  verifyReplyTicket,
  widgetNameOf,
} from '../src/pushReplyRules.js';

const SECRET = 'test-secret';
const who = { userId: 'U1', roomId: 'R1', deviceId: 'D1', tokenVersion: 2 };

test('답장 표 — 만든 값 그대로 읽히고, 기한·서명·모양이 틀리면 null', () => {
  const now = 1_700_000_000_000;
  const t = signReplyTicket(SECRET, who, now);
  assert.match(t, /^v1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
  assert.deepEqual(verifyReplyTicket(SECRET, t, now + 1000), who);
  // 기한(3일)이 지나면.
  assert.equal(verifyReplyTicket(SECRET, t, now + REPLY_TICKET_TTL_MS), null);
  // 다른 비밀값·본문을 바꾼 표·모양이 다른 글.
  assert.equal(verifyReplyTicket('other', t, now), null);
  const [p, body, mac] = t.split('.');
  const forged = Buffer.from(JSON.stringify({ u: 'U2', r: 'R1', d: 'D1', v: 2, e: now + 10_000 })).toString('base64url');
  assert.equal(verifyReplyTicket(SECRET, `${p}.${forged}.${mac}`, now), null);
  assert.equal(verifyReplyTicket(SECRET, `v2.${body}.${mac}`, now), null);
  assert.equal(verifyReplyTicket(SECRET, 'eyJhbGciOiJIUzI1NiJ9.e30.x', now), null);
  assert.equal(verifyReplyTicket(SECRET, null, now), null);
  assert.equal(verifyReplyTicket(SECRET, 'x'.repeat(2000), now), null);
});

test('답장 칸은 새 메시지만(비밀 대화·댓글·멘션은 없음), 안 읽은 수는 메시지·댓글·멘션만 올린다', () => {
  assert.equal(replyAllowed('message', { isSecret: false }), true);
  assert.equal(replyAllowed('message', { isSecret: true }), false);
  assert.equal(replyAllowed('comment', {}), false);
  assert.equal(replyAllowed('mention', {}), false);
  assert.deepEqual(['message', 'comment', 'mention', 'mention_all', 'announcement', 'board_edit'].map(unreadDeltaOf), [1, 1, 1, 1, 0, 0]);
});

test('위젯 이름 — 1:1은 보낸 사람, 그 밖에는 방 이름표', () => {
  assert.equal(widgetNameOf({ type: 'dm' }, '1:1', '홍길동'), '홍길동');
  assert.equal(widgetNameOf({ type: 'dm', isSelf: true }, '나와의 대화', '탱고톡'), '나와의 대화');
  assert.equal(widgetNameOf({ type: 'topic' }, '영업', '홍길동'), '영업');
  assert.equal(widgetNameOf({ type: 'topic' }, null, '홍길동'), '홍길동');
});
