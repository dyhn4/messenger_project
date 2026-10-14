// 메시지 리마인더 규칙(reminderRules.js)과 연결(reminders.js·rooms.js·index.js) — `node --test test/*.test.js`. DB 없이 돈다.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import {
  parseRemindAt,
  REMIND_MAX_AHEAD_MS,
  REMIND_MIN_AHEAD_MS,
  reminderBotText,
  reminderCardFor,
  reminderDenial,
  REMINDER_PREVIEW_MAX,
} from '../src/reminderRules.js';

const NOW = Date.UTC(2026, 9, 14, 3, 0);

test('알림 시각: 1분 뒤부터 1년 안까지', () => {
  assert.deepEqual(parseRemindAt(NOW + REMIND_MIN_AHEAD_MS, NOW).value, new Date(NOW + REMIND_MIN_AHEAD_MS));
  assert.deepEqual(parseRemindAt(NOW + REMIND_MAX_AHEAD_MS, NOW).value, new Date(NOW + REMIND_MAX_AHEAD_MS));
  assert.match(parseRemindAt(NOW + 30_000, NOW).error, /1분 뒤/);
  assert.match(parseRemindAt(NOW - 1, NOW).error, /1분 뒤/);
  assert.match(parseRemindAt(NOW + REMIND_MAX_AHEAD_MS + 1, NOW).error, /1년/);
  assert.match(parseRemindAt('내일', NOW).error, /올바르지/);
  assert.match(parseRemindAt(null, NOW).error, /올바르지/);
});

test('걸 수 없는 경우: 없음·지움·남의 방(403)·DM 나가기 이전·시스템 메시지 — 비밀 대화는 된다', () => {
  const room = { id: 'r', type: 'group', isSecret: false };
  const message = { id: 'm', type: 'text', createdAt: new Date('2026-10-01'), deletedAt: null };
  assert.equal(reminderDenial({ message, room, isMember: true }), null);
  assert.equal(reminderDenial({ message, room: { ...room, isSecret: true }, isMember: true }), null);
  assert.equal(reminderDenial({ message: null, room, isMember: true }).status, 404);
  assert.equal(reminderDenial({ message: { ...message, deletedAt: new Date() }, room, isMember: true }).status, 404);
  assert.equal(reminderDenial({ message, room, isMember: false }).status, 403);
  assert.equal(reminderDenial({ message, room: { ...room, type: 'dm' }, isMember: true, floor: new Date('2026-10-02') }).status, 404);
  assert.equal(reminderDenial({ message: { ...message, type: 'system' }, room, isMember: true }).status, 400);
});

test('카드: 원본 스냅샷 — 비밀 대화는 미리보기를 비우고, 긴 미리보기는 자른다', () => {
  const message = { id: 'm1', senderName: 'Sam', createdAt: new Date(NOW) };
  const card = reminderCardFor({ message, room: { id: 'r1', name: '마케팅', isSecret: false }, preview: ' 배너 시안 확인 부탁 ' });
  assert.deepEqual(card, {
    messageId: 'm1',
    roomId: 'r1',
    roomName: '마케팅',
    senderName: 'Sam',
    preview: '배너 시안 확인 부탁',
    sentAt: NOW,
    secret: false,
  });
  assert.equal(reminderBotText(card), '⏰ 리마인더 — Sam: 배너 시안 확인 부탁');

  const secret = reminderCardFor({ message, room: { id: 'r2', name: null, isSecret: true }, preview: '암호문' });
  assert.equal(secret.preview, null);
  assert.equal(secret.roomName, null);
  assert.equal(secret.secret, true);
  assert.equal(reminderBotText(secret), '⏰ 리마인더 — Sam: 메시지를 확인하세요');

  const long = reminderCardFor({ message, room: { id: 'r1', name: 'x', isSecret: false }, preview: '가'.repeat(500) });
  assert.equal([...long.preview].length, REMINDER_PREVIEW_MAX + 1);
  assert.ok(long.preview.endsWith('…'));
  assert.equal(reminderCardFor({ message, room: { id: 'r1', isSecret: false }, preview: '' }).preview, null);
});

test('연결: 라우터·예약 작업이 붙어 있고, 울리면 나와의 대화에 카드로 올리며, DTO에 카드를 싣는다', () => {
  const index = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
  assert.match(index, /createRemindersRouter\(io\)/);
  assert.match(index, /startReminderJob\(io\);/);
  const reminders = fs.readFileSync(new URL('../src/reminders.js', import.meta.url), 'utf8');
  assert.match(reminders, /openSelfRoom\(io, reminder\.userId, room\.teamId\)/);
  assert.match(reminders, /postBotMessage\(io, selfRoom, reminderBotText\(card\), \{ senderName: SELF_ROOM_BOT_NAME, reminderCard: card \}\)/);
  assert.match(reminders, /isRoomMember\(room\.id, reminder\.userId\)/, '울릴 때 방에서 빠졌으면 올리지 않는다');
  const messages = fs.readFileSync(new URL('../src/messages.js', import.meta.url), 'utf8');
  assert.match(messages, /reminderCard: m\.deletedAt \? null : \(m\.reminderCard \?\? null\),/);
  const queries = fs.readFileSync(new URL('../src/db/queries/reminders.js', import.meta.url), 'utf8');
  assert.match(queries, /for update skip locked/, '같은 리마인더를 두 번 울리지 않는다');
});
