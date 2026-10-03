// 캘린더 제목 검색의 순수 규칙 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  CALENDAR_SEARCH_DEFAULT_LIMIT,
  CALENDAR_SEARCH_MAX_LIMIT,
  canSearchEventTitle,
  escapeLike,
  parseCalendarSearchQuery,
  searchCursorOf,
  toSearchItem,
} from '../src/calendarSearchRules.js';
import { calendarPermissions } from '../src/permissions.js';

const EV = '22222222-2222-4222-8222-222222222222';
const ME = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const OTHER = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

test('escapeLike: \\ % _ 를 이스케이프한다', () => {
  assert.equal(escapeLike('100%_a\\b'), '100\\%\\_a\\\\b');
  assert.equal(escapeLike('주간 회의'), '주간 회의');
});

test('parseCalendarSearchQuery: q는 앞뒤 공백을 빼고 1~50자, 패턴은 %로 감싼 이스케이프 값', () => {
  const ok = parseCalendarSearchQuery({ q: '  회의_ ' });
  assert.equal(ok.q, '회의_');
  assert.equal(ok.like, '%회의\\_%');
  assert.equal(ok.limit, CALENDAR_SEARCH_DEFAULT_LIMIT);
  assert.equal(ok.before, null);
  assert.ok(parseCalendarSearchQuery({}).error);
  assert.ok(parseCalendarSearchQuery({ q: '   ' }).error);
  assert.ok(parseCalendarSearchQuery({ q: ['a'] }).error);
  assert.ok(parseCalendarSearchQuery({ q: 'a'.repeat(51) }).error);
  assert.ok(!parseCalendarSearchQuery({ q: 'a'.repeat(50) }).error);
});

test('parseCalendarSearchQuery: limit은 1..100으로 눌러 담는다', () => {
  assert.equal(parseCalendarSearchQuery({ q: 'a', limit: '5000' }).limit, CALENDAR_SEARCH_MAX_LIMIT);
  assert.equal(parseCalendarSearchQuery({ q: 'a', limit: '7' }).limit, 7);
  assert.ok(parseCalendarSearchQuery({ q: 'a', limit: '0' }).error);
  assert.ok(parseCalendarSearchQuery({ q: 'a', limit: 'x' }).error);
});

test('parseCalendarSearchQuery: before는 ms 또는 ms:eventId 커서', () => {
  assert.deepEqual(parseCalendarSearchQuery({ q: 'a', before: '1700000000000' }).before, { ms: 1700000000000, id: null });
  assert.deepEqual(parseCalendarSearchQuery({ q: 'a', before: `1700000000000:${EV.toUpperCase()}` }).before, {
    ms: 1700000000000,
    id: EV,
  });
  assert.ok(parseCalendarSearchQuery({ q: 'a', before: 'abc' }).error);
  assert.ok(parseCalendarSearchQuery({ q: 'a', before: '1700000000000:nope' }).error);
});

test('canSearchEventTitle: 공개는 누구나, 비공개는 작성자·참석자·소유자·관리자만', () => {
  const pub = { visibility: 'public', creatorId: OTHER };
  const priv = { visibility: 'private', creatorId: OTHER };
  const plain = { isOwner: false, isManager: false };
  assert.ok(canSearchEventTitle({ event: pub, viewerId: ME, isAttendee: false, access: plain }));
  assert.ok(!canSearchEventTitle({ event: priv, viewerId: ME, isAttendee: false, access: plain }));
  assert.ok(canSearchEventTitle({ event: { ...priv, creatorId: ME }, viewerId: ME, isAttendee: false, access: plain }));
  assert.ok(canSearchEventTitle({ event: priv, viewerId: ME, isAttendee: true, access: plain }));
  assert.ok(canSearchEventTitle({ event: priv, viewerId: ME, isAttendee: false, access: { isOwner: true } }));
  assert.ok(canSearchEventTitle({ event: priv, viewerId: ME, isAttendee: false, access: { isManager: true } }));
});

test('canSearchEventTitle: 실제 권한 계산과 맞물린다 — 읽기 전용 멤버는 남의 비공개 일정을 못 찾는다', () => {
  const calendar = { id: 'c', teamId: 't', kind: 'shared', ownerId: OTHER, isPublic: true };
  const reader = calendarPermissions({
    calendar,
    userId: ME,
    isTeamMember: true,
    role: 'member',
    isOwner: false,
    memberRole: 'read',
  });
  const admin = calendarPermissions({
    calendar,
    userId: ME,
    isTeamMember: true,
    role: 'member',
    isOwner: false,
    memberRole: 'admin',
  });
  const priv = { visibility: 'private', creatorId: OTHER };
  assert.ok(!canSearchEventTitle({ event: priv, viewerId: ME, isAttendee: false, access: reader }));
  assert.ok(canSearchEventTitle({ event: priv, viewerId: ME, isAttendee: false, access: admin }));
});

test('toSearchItem: 마스터 단위 DTO — 종일 일정의 시각은 그대로, 반복 요약은 recurrence 객체', () => {
  const start = Date.UTC(2026, 9, 5);
  const event = {
    id: EV,
    calendarId: 'cal',
    title: '주간 회의',
    startAt: new Date(start),
    endAt: new Date(start + 86400000),
    allDay: true,
    recurrence: { freq: 'weekly', interval: 1, byWeekday: [1] },
  };
  const item = toSearchItem({
    event,
    calendarName: '팀 캘린더',
    color: '#5B8DEF',
    attendees: [{ userId: ME, name: '나' }],
    creatorName: '홍길동',
    canEdit: true,
  });
  assert.deepEqual(item, {
    eventId: EV,
    calendarId: 'cal',
    calendarName: '팀 캘린더',
    color: '#5B8DEF',
    title: '주간 회의',
    start,
    end: start + 86400000,
    allDay: true,
    recurring: true,
    recurrence: { freq: 'weekly', interval: 1, byWeekday: [1] },
    attendees: [{ userId: ME, name: '나' }],
    creatorName: '홍길동',
    canEdit: true,
  });
  const single = toSearchItem({
    event: { ...event, recurrence: null },
    calendarName: 'x',
    color: '#000000',
    attendees: [],
    creatorName: undefined,
  });
  assert.equal(single.recurring, false);
  assert.equal(single.recurrence, null);
  assert.equal(single.creatorName, null);
  assert.equal(single.canEdit, false);
  assert.equal(searchCursorOf(item), `${start}:${EV}`);
});
