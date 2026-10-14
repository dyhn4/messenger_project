// 상태 메시지·방해 금지 규칙(statusRules.js)과 연결(users.js·push.js) — `node --test test/*.test.js`. DB 없이 돈다.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import {
  dndDto,
  isDndActive,
  isUserInDnd,
  parseDndInput,
  parseDndSchedule,
  parseStatusInput,
  STATUS_EMOJIS,
  STATUS_TEXT_MAX,
  statusDto,
} from '../src/statusRules.js';

const NOW = Date.UTC(2026, 9, 14, 3, 0); // 2026-10-14(수) 12:00 KST
const HOUR = 60 * 60 * 1000;
const KST = 9 * 60;
/** KST 기준 그 날·시각의 ms. */
const kst = (y, mo, d, h, mi = 0) => Date.UTC(y, mo - 1, d, h, mi) - KST * 60 * 1000;

test('상태 입력: 목록의 이모지·40자 글·한 달 안의 지울 시각, 둘 다 비면 지우기', () => {
  assert.deepEqual(parseStatusInput({ emoji: '🗓️', text: ' 회의 중 ', until: NOW + HOUR }, NOW).value, {
    statusEmoji: '🗓️',
    statusText: '회의 중',
    statusUntil: new Date(NOW + HOUR),
  });
  assert.deepEqual(parseStatusInput({ emoji: null, text: '외근', until: null }, NOW).value.statusUntil, null);
  assert.deepEqual(parseStatusInput({}, NOW).value, { statusEmoji: null, statusText: null, statusUntil: null });
  assert.deepEqual(parseStatusInput({ text: '   ', until: NOW + HOUR }, NOW).value.statusText, null, '공백뿐이면 지우기');
  assert.match(parseStatusInput({ emoji: '🔥' }, NOW).error, /목록/);
  assert.match(parseStatusInput({ text: '가'.repeat(STATUS_TEXT_MAX + 1) }, NOW).error, /40자/);
  assert.equal(parseStatusInput({ text: '👨‍👩‍👧'.repeat(STATUS_TEXT_MAX) }, NOW).error, undefined, '글자는 화면에 보이는 단위로 센다');
  assert.match(parseStatusInput({ text: '회의\n중' }, NOW).error, /쓸 수 없는 글자/);
  assert.match(parseStatusInput({ text: 'a‮b' }, NOW).error, /쓸 수 없는 글자/);
  assert.match(parseStatusInput({ text: 3 }, NOW).error, /글자/);
  assert.match(parseStatusInput({ text: '회의', until: NOW - 1 }, NOW).error, /지났습니다/);
  assert.match(parseStatusInput({ text: '휴가', until: NOW + 40 * 24 * HOUR }, NOW).error, /한 달/);
  assert.match(parseStatusInput({ text: '회의', until: '내일' }, NOW).error, /올바르지/);
  assert.equal(STATUS_EMOJIS.length, 12);
});

test('상태 내려주기: 지울 시각이 지났거나 비었으면 null', () => {
  assert.deepEqual(statusDto({ statusEmoji: '🚗', statusText: '외근', statusUntil: new Date(NOW + HOUR) }, NOW), {
    emoji: '🚗',
    text: '외근',
    until: NOW + HOUR,
  });
  assert.equal(statusDto({ statusEmoji: '🚗', statusText: '외근', statusUntil: new Date(NOW - 1) }, NOW), null);
  assert.deepEqual(statusDto({ statusText: '재택', statusUntil: null }, NOW), { emoji: null, text: '재택', until: null });
  assert.equal(statusDto({}, NOW), null);
});

test('방해 금지 일정 입력 검사', () => {
  const ok = { enabled: true, start: 19 * 60, end: 8 * 60, days: [5, 1, 1, 2], offsetMinutes: KST };
  assert.deepEqual(parseDndSchedule(ok).value.days, [1, 2, 5]);
  assert.equal(parseDndSchedule(null).value, null);
  assert.match(parseDndSchedule({ ...ok, start: 480, end: 480 }).error, /같습니다/);
  assert.match(parseDndSchedule({ ...ok, start: 1440 }).error, /시간/);
  assert.match(parseDndSchedule({ ...ok, days: [] }).error, /요일/);
  assert.match(parseDndSchedule({ ...ok, days: [7] }).error, /요일/);
  assert.match(parseDndSchedule({ ...ok, offsetMinutes: 900 }).error, /시간대/);
  assert.match(parseDndSchedule({ ...ok, enabled: 'yes' }).error, /켜짐/);
  assert.match(parseDndSchedule([1]).error, /형식/);
  assert.deepEqual(parseDndInput({ until: NOW + HOUR }, NOW).value, { dndUntil: new Date(NOW + HOUR) });
  assert.deepEqual(parseDndInput({ until: null }, NOW).value, { dndUntil: null });
  assert.match(parseDndInput({}, NOW).error, /바꿀 내용/);
  assert.match(parseDndInput({ until: NOW - 1 }, NOW).error, /지났습니다/);
});

test('방해 금지 중인지: "지금부터 n시간"', () => {
  assert.equal(isDndActive({ until: NOW + 1, schedule: null }, NOW), true);
  assert.equal(isDndActive({ until: NOW, schedule: null }, NOW), false);
  assert.equal(isDndActive(null, NOW), false);
  assert.equal(isUserInDnd({ dndUntil: new Date(NOW + HOUR), dndSchedule: null }, NOW), true);
  assert.equal(isUserInDnd({ dndUntil: null, dndSchedule: null }, NOW), false);
});

test('방해 금지 중인지: 낮 일정(평일 12:00~13:00 KST)', () => {
  const dnd = { until: null, schedule: { enabled: true, start: 12 * 60, end: 13 * 60, days: [1, 2, 3, 4, 5], offsetMinutes: KST } };
  assert.equal(isDndActive(dnd, kst(2026, 10, 14, 12, 0)), true, '수요일 12:00 — 시작 포함');
  assert.equal(isDndActive(dnd, kst(2026, 10, 14, 12, 59)), true);
  assert.equal(isDndActive(dnd, kst(2026, 10, 14, 13, 0)), false, '끝은 포함하지 않는다');
  assert.equal(isDndActive(dnd, kst(2026, 10, 14, 11, 59)), false);
  assert.equal(isDndActive(dnd, kst(2026, 10, 17, 12, 30)), false, '토요일은 고르지 않았다');
  assert.equal(isDndActive({ ...dnd, schedule: { ...dnd.schedule, enabled: false } }, kst(2026, 10, 14, 12, 30)), false);
});

test('방해 금지 중인지: 밤을 넘기는 일정은 시작한 요일 기준(금 19:00 ~ 토 08:00)', () => {
  const dnd = { until: null, schedule: { enabled: true, start: 19 * 60, end: 8 * 60, days: [5], offsetMinutes: KST } };
  assert.equal(isDndActive(dnd, kst(2026, 10, 16, 18, 59)), false, '금 18:59');
  assert.equal(isDndActive(dnd, kst(2026, 10, 16, 19, 0)), true, '금 19:00');
  assert.equal(isDndActive(dnd, kst(2026, 10, 16, 23, 59)), true);
  assert.equal(isDndActive(dnd, kst(2026, 10, 17, 0, 0)), true, '토 00:00 — 금요일 일정이 이어짐');
  assert.equal(isDndActive(dnd, kst(2026, 10, 17, 7, 59)), true);
  assert.equal(isDndActive(dnd, kst(2026, 10, 17, 8, 0)), false, '토 08:00 끝');
  assert.equal(isDndActive(dnd, kst(2026, 10, 17, 19, 30)), false, '토요일 밤은 고르지 않았다');
  assert.equal(isDndActive(dnd, kst(2026, 10, 16, 3, 0)), false, '금 새벽은 목요일 일정의 끝자락 — 목요일은 안 골랐다');
});

test('방해 금지 중인지: 시간대는 그 사람 기기 기준(같은 순간이라도 시간대가 다르면 다르다)', () => {
  const at = Date.UTC(2026, 9, 14, 11, 0); // UTC 11:00 = KST 20:00 = 런던(BST, +60) 12:00
  const evening = { enabled: true, start: 19 * 60, end: 8 * 60, days: [0, 1, 2, 3, 4, 5, 6] };
  assert.equal(isDndActive({ schedule: { ...evening, offsetMinutes: KST } }, at), true);
  assert.equal(isDndActive({ schedule: { ...evening, offsetMinutes: 60 } }, at), false);
});

test('방해 금지 내려주기: 지난 until·꺼진 일정은 빼고, 둘 다 없으면 null', () => {
  const schedule = { enabled: true, start: 0, end: 60, days: [1], offsetMinutes: 0 };
  assert.deepEqual(dndDto({ dndUntil: new Date(NOW + HOUR), dndSchedule: null }, NOW), { until: NOW + HOUR, schedule: null });
  assert.deepEqual(dndDto({ dndUntil: new Date(NOW - 1), dndSchedule: schedule }, NOW), { until: null, schedule });
  assert.equal(dndDto({ dndUntil: new Date(NOW - 1), dndSchedule: { ...schedule, enabled: false } }, NOW), null);
  assert.equal(dndDto({}, NOW), null);
});

test('연결: 프로필에 상태·방해 금지를 싣고, 바꾸면 user:status로 알리고, 채팅·업무 푸시는 방해 금지인 사람을 뺀다', () => {
  const users = fs.readFileSync(new URL('../src/users.js', import.meta.url), 'utf8');
  assert.match(users, /status: statusDto\(u, Date\.now\(\)\)/);
  assert.match(users, /dnd: dndDto\(u, Date\.now\(\)\)/);
  assert.match(users, /router\.put\('\/users\/me\/status'/);
  assert.match(users, /router\.put\('\/users\/me\/dnd'/);
  assert.match(users, /emit\('user:status'/);
  const push = fs.readFileSync(new URL('../src/push.js', import.meta.url), 'utf8');
  assert.match(push, /const targets = await withoutDndUsers\(requested\);/);
  assert.match(push, /if \(\(await withoutDndUsers\(\[userId\]\)\)\.length === 0\) return;/);
  const callPush = push.slice(push.indexOf('export async function notifyIncomingCall'));
  assert.doesNotMatch(callPush.slice(0, callPush.indexOf('\n}\n')), /withoutDndUsers/, '화상회의 호출은 방해 금지여도 울린다');
});
