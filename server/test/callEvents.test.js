// 화상회의 기록 카드 내용 규칙(callEvents.js) 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { CALL_CARD_MAX_EVENTS, addCallEvent, closeStaleCallCard, endCallCard, newCallCard } from '../src/callEvents.js';

const T0 = 1_000_000;

test('시작하면 진행 중 카드에 시작 사건 하나', () => {
  const card = newCallCard({ at: T0, userId: 'a', name: '김철수' });
  assert.equal(card.status, 'active');
  assert.equal(card.startedAt, T0);
  assert.deepEqual(card.events, [{ at: T0, userId: 'a', name: '김철수', kind: 'start' }]);
});

test('참여·거절·나감이 시간순으로 쌓이고, 원래 카드는 그대로', () => {
  const c0 = newCallCard({ at: T0, userId: 'a', name: '김철수' });
  const c1 = addCallEvent(c0, { at: T0 + 1, userId: 'b', name: '이영희', kind: 'join' });
  const c2 = addCallEvent(c1, { at: T0 + 2, userId: 'c', name: '', kind: 'decline' });
  assert.equal(c0.events.length, 1);
  assert.deepEqual(
    c2.events.map((e) => [e.kind, e.name]),
    [['start', '김철수'], ['join', '이영희'], ['decline', '알 수 없음']],
  );
});

test('끝나면 길이·응답 여부가 정해지고, 끝난 카드에는 더 안 쌓인다', () => {
  const c = endCallCard(newCallCard({ at: T0, userId: 'a', name: '김철수' }), { at: T0 + 90_000, answered: true });
  assert.equal(c.status, 'ended');
  assert.equal(c.durationMs, 90_000);
  assert.equal(c.answered, true);
  assert.equal(addCallEvent(c, { at: T0 + 1, userId: 'b', name: 'x', kind: 'join' }), c);
});

test('사건 수 상한', () => {
  let c = newCallCard({ at: T0, userId: 'a', name: 'a' });
  for (let i = 0; i < CALL_CARD_MAX_EVENTS + 10; i++) c = addCallEvent(c, { at: T0 + i, userId: 'b', name: 'b', kind: 'join' });
  assert.equal(c.events.length, CALL_CARD_MAX_EVENTS);
});

test('서버 재시작으로 남은 진행 중 카드는 마지막 사건 시각에 끝난 것으로 닫는다', () => {
  let c = newCallCard({ at: T0, userId: 'a', name: 'a' });
  c = addCallEvent(c, { at: T0 + 5000, userId: 'b', name: 'b', kind: 'join' });
  const closed = closeStaleCallCard(c);
  assert.equal(closed.status, 'ended');
  assert.equal(closed.endedAt, T0 + 5000);
  assert.equal(closed.answered, true);
  assert.equal(closeStaleCallCard(closed), closed);
});
