// 회의실·자원 예약 규칙 — 자원 입력 검사, 예약 시간·제목 검사, 겹침, 종일 일정의 예약 구간, 겹침 안내 글, 예약 줄 모양(비공개 일정 가리기).
// `node --test test/*.test.js`(DB 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  BOOKING_AHEAD_MS,
  BOOKING_MAX_MS,
  bookingDto,
  conflictText,
  eventBookingRange,
  eventResourceDto,
  kstText,
  overlaps,
  parseBookingTimes,
  parseBookingTitle,
  parseResourceInput,
} from '../src/resourceRules.js';

const HOUR = 3600 * 1000;
const NOW = Date.UTC(2026, 9, 17, 1); // 2026-10-17 10:00 KST

test('자원 입력 — 종류·이름·수용 인원, 고치기는 보낸 칸만', () => {
  assert.deepEqual(parseResourceInput({ name: ' 대회의실 ', capacity: 12, location: '3층' }).values, {
    kind: 'room',
    name: '대회의실',
    location: '3층',
    description: null,
    capacity: 12,
  });
  assert.match(parseResourceInput({ name: '' }).error, /이름/);
  assert.match(parseResourceInput({ name: 'a'.repeat(31) }).error, /30자/);
  assert.match(parseResourceInput({ name: '배', kind: 'boat' }).error, /종류/);
  assert.match(parseResourceInput({ name: '방', capacity: 0 }).error, /수용 인원/);
  assert.match(parseResourceInput({ name: '방', capacity: 2.5 }).error, /수용 인원/);
  assert.equal(parseResourceInput({ name: '방', capacity: '' }).values.capacity, null);
  assert.deepEqual(parseResourceInput({ enabled: false }, { partial: true }).values, { enabled: false });
  assert.deepEqual(parseResourceInput({ location: '' }, { partial: true }).values, { location: null });
  assert.match(parseResourceInput({}, { partial: true }).error, /바꿀 내용/);
  assert.match(parseResourceInput({ enabled: 'yes' }, { partial: true }).error, /켜고 끄기/);
});

test('예약 시간 — 순서, 7일 이하, 지난 시간 안 됨(진행 중은 됨), 180일 안', () => {
  assert.deepEqual(parseBookingTimes(NOW + HOUR, NOW + 2 * HOUR, NOW), { startMs: NOW + HOUR, endMs: NOW + 2 * HOUR });
  assert.match(parseBookingTimes(NOW + 2 * HOUR, NOW + HOUR, NOW).error, /끝 시각/);
  assert.match(parseBookingTimes(NOW, NOW, NOW).error, /끝 시각/);
  assert.match(parseBookingTimes(NOW, NOW + BOOKING_MAX_MS + 1, NOW).error, /7일/);
  assert.ok(parseBookingTimes(NOW, NOW + BOOKING_MAX_MS, NOW).startMs);
  assert.match(parseBookingTimes(NOW - 2 * HOUR, NOW - HOUR, NOW).error, /지난 시간/);
  assert.ok(parseBookingTimes(NOW - HOUR, NOW + HOUR, NOW).startMs, '진행 중인 시간은 됨');
  assert.match(parseBookingTimes(NOW + BOOKING_AHEAD_MS + 1, NOW + BOOKING_AHEAD_MS + HOUR, NOW).error, /180일/);
  assert.match(parseBookingTimes('1', NOW, NOW).error, /예약 시간/);
});

test('예약 제목 — 비우면 "<자원> 예약", 50자', () => {
  assert.equal(parseBookingTitle('', '대회의실').title, '대회의실 예약');
  assert.equal(parseBookingTitle(undefined, '빔프로젝터').title, '빔프로젝터 예약');
  assert.equal(parseBookingTitle(' 주간 회의 ', '대회의실').title, '주간 회의');
  assert.match(parseBookingTitle('가'.repeat(51), '방').error, /50자/);
  assert.match(parseBookingTitle(3, '방').error, /제목/);
});

test('겹침 — 끝과 시작이 맞닿으면 겹치지 않음', () => {
  const a = { startMs: 10, endMs: 20 };
  assert.equal(overlaps(a, { startMs: 15, endMs: 25 }), true);
  assert.equal(overlaps(a, { startMs: 0, endMs: 30 }), true);
  assert.equal(overlaps(a, { startMs: 20, endMs: 30 }), false);
  assert.equal(overlaps(a, { startMs: 0, endMs: 10 }), false);
});

test('일정의 예약 구간 — 종일 일정은 한국 날짜 자정부터', () => {
  const day = Date.UTC(2026, 9, 20);
  assert.deepEqual(eventBookingRange({ startMs: day, endMs: day + 2 * 24 * HOUR, allDay: true }), {
    startMs: day - 9 * HOUR,
    endMs: day + 39 * HOUR,
  });
  assert.equal(kstText(day - 9 * HOUR), '10/20 00:00');
  assert.deepEqual(eventBookingRange({ startMs: NOW, endMs: NOW + HOUR, allDay: false }), { startMs: NOW, endMs: NOW + HOUR });
});

test('겹침 안내 — 같은 날이면 끝은 시각만', () => {
  const b = (s, e) => ({ startAt: new Date(s), endAt: new Date(e), userName: '홍길동' });
  assert.equal(conflictText(b(NOW, NOW + HOUR)), '이미 예약된 시간입니다 (10/17 10:00~11:00 홍길동)');
  assert.equal(conflictText(b(NOW, NOW + 24 * HOUR)), '이미 예약된 시간입니다 (10/17 10:00~10/18 10:00 홍길동)');
});

test('예약 줄 — 일정 예약은 일정 제목, 비공개 일정은 잡은 사람·만든 사람 말고는 가림, 취소는 본인·관리자', () => {
  const row = {
    id: 'B1',
    resourceId: 'R1',
    resourceName: '대회의실',
    resourceKind: 'room',
    userId: 'U1',
    userName: '홍길동',
    teamId: 'T1',
    title: '대회의실 예약',
    startAt: new Date(NOW),
    endAt: new Date(NOW + HOUR),
    eventId: 'E1',
    eventTitle: '고객 미팅',
    eventVisibility: 'private',
    eventCreatorId: 'U2',
  };
  assert.equal(bookingDto(row, { viewerId: 'U1' }).title, '고객 미팅');
  assert.equal(bookingDto(row, { viewerId: 'U2' }).title, '고객 미팅');
  const other = bookingDto(row, { viewerId: 'U3' });
  assert.equal(other.title, '비공개 일정');
  assert.equal(other.canCancel, false);
  assert.equal(bookingDto(row, { viewerId: 'U3', isManager: true }).canCancel, true);
  assert.equal(bookingDto({ ...row, eventVisibility: 'public' }, { viewerId: 'U3' }).title, '고객 미팅');
  const standalone = bookingDto({ ...row, eventId: null, eventTitle: null, eventVisibility: null, title: '주간 회의' }, { viewerId: 'U3' });
  assert.equal(standalone.title, '주간 회의');
  assert.equal(standalone.start, NOW);
  assert.deepEqual(eventResourceDto(row), { bookingId: 'B1', resourceId: 'R1', name: '대회의실', kind: 'room', status: 'confirmed' });
  assert.equal(eventResourceDto(null), null);
});
