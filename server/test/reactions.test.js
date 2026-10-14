// 메시지 공감(이모지 반응) 규칙(reactionRules.js)과 연결(reactions.js·rooms.js·messages.js) — `node --test test/*.test.js`.
// DB 없이 돈다(라우트를 import하면 DB에 붙으므로 연결은 소스 글로 확인한다 — ddns.test.js와 같은 방식).
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import { isReactionEmoji, reactionDenial, REACTION_EMOJIS, summarizeReactions } from '../src/reactionRules.js';

test('고를 수 있는 이모지는 정해 둔 6개뿐', () => {
  assert.deepEqual([...REACTION_EMOJIS], ['👍', '❤️', '😂', '😮', '😢', '✅']);
  for (const e of REACTION_EMOJIS) assert.equal(isReactionEmoji(e), true);
  assert.equal(isReactionEmoji('❤'), false, '변형 선택자(VS16) 없는 하트는 다른 글자');
  assert.equal(isReactionEmoji('👍🏽'), false);
  assert.equal(isReactionEmoji('👍 '), false);
  assert.equal(isReactionEmoji(''), false);
  assert.equal(isReactionEmoji(null), false);
  assert.equal(isReactionEmoji(['👍']), false);
});

test('요약: 메시지별로, 이모지는 정해 둔 순서·사람은 누른 순서, 모르는 이모지는 뺀다', () => {
  const summary = summarizeReactions([
    { messageId: 'm1', userId: 'a', emoji: '✅' },
    { messageId: 'm1', userId: 'b', emoji: '👍' },
    { messageId: 'm2', userId: 'a', emoji: '😂' },
    { messageId: 'm1', userId: 'c', emoji: '✅' },
    { messageId: 'm1', userId: 'd', emoji: '🔥' },
  ]);
  assert.deepEqual(summary.get('m1'), [
    { emoji: '👍', userIds: ['b'] },
    { emoji: '✅', userIds: ['a', 'c'] },
  ]);
  assert.deepEqual(summary.get('m2'), [{ emoji: '😂', userIds: ['a'] }]);
  assert.equal(summary.has('m3'), false);
  assert.equal(summarizeReactions([]).size, 0);
});

test('공감할 수 없는 경우: 없음·지움·남의 방(403)·DM 나가기 이전·비밀 대화·시스템 메시지', () => {
  const room = { id: 'r', isSecret: false, type: 'group' };
  const message = { id: 'm', type: 'text', createdAt: new Date('2026-10-01'), deletedAt: null };
  assert.equal(reactionDenial({ message, room, isMember: true }), null);
  assert.equal(reactionDenial({ message: { ...message, type: 'post' }, room, isMember: true }), null);
  assert.equal(reactionDenial({ message: { ...message, type: 'poll' }, room, isMember: true }), null);
  assert.equal(reactionDenial({ message: null, room, isMember: true }).status, 404);
  assert.equal(reactionDenial({ message: { ...message, deletedAt: new Date() }, room, isMember: true }).status, 404);
  assert.equal(reactionDenial({ message, room: null, isMember: false }).status, 404);
  assert.equal(reactionDenial({ message, room, isMember: false }).status, 403);
  assert.equal(
    reactionDenial({ message, room: { ...room, type: 'dm' }, isMember: true, floor: new Date('2026-10-02') }).status,
    404,
    'DM을 진짜 나갔다 다시 온 사람에게 그 이전 메시지는 없는 것과 같다',
  );
  assert.equal(reactionDenial({ message, room: { ...room, type: 'dm' }, isMember: true, floor: new Date('2026-09-30') }), null);
  assert.match(reactionDenial({ message, room: { ...room, isSecret: true }, isMember: true }).error, /비밀 대화/);
  assert.equal(reactionDenial({ message: { ...message, type: 'system' }, room, isMember: true }).status, 400);
});

test('연결: 방 메시지 목록·고정 게시글·메시지 한 건은 공감을 붙이고, DTO는 붙이지 않았으면 키를 싣지 않는다', () => {
  const rooms = fs.readFileSync(new URL('../src/rooms.js', import.meta.url), 'utf8');
  assert.match(rooms, /attachReactions\(await attachPolls\(\[\.\.\.extraParents, \.\.\.rows\]/);
  assert.match(rooms, /attachReactions\(await attachPolls\(await listPinnedPosts/);
  const messages = fs.readFileSync(new URL('../src/messages.js', import.meta.url), 'utf8');
  assert.match(messages, /attachReactions\(await attachPolls\(\[message\]/);
  assert.match(messages, /reactions: m\.deletedAt \? \[\] : m\.reactions,/);
  const index = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
  assert.match(index, /createReactionsRouter\(io\)/);
  const reactions = fs.readFileSync(new URL('../src/reactions.js', import.meta.url), 'utf8');
  assert.match(reactions, /io\.to\(message\.roomId\)\.emit\('message:reactions'/);
});
