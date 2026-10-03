// 검색 패널 "대화방" 탭 순수 규칙 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
// 권한(내가 멤버인 방만·비밀 대화 제외·팀 멤버십)은 listMemberRoomsForSearch의 SQL이 맡고, 임시 서버로 실제 HTTP 검증한다.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  ROOM_SEARCH_DEFAULT_LIMIT,
  ROOM_SEARCH_MAX_LIMIT,
  matchRoomsByName,
  parseRoomSearchQuery,
  roomSearchDisplayName,
  sortRoomsByActivity,
} from '../src/roomSearchRules.js';

const ME = 'me';
const topic = { id: 't1', type: 'topic', name: '마케팅 전략', isSelf: false };
const unnamedGroup = { id: 'g1', type: 'group', name: null, isSelf: false };
const namedGroup = { id: 'g2', type: 'group', name: '점심 모임', isSelf: false };
const dm = { id: 'd1', type: 'dm', name: null, isSelf: false };
const self = { id: 's1', type: 'dm', name: null, isSelf: true };
const members = new Map([
  ['g1', [{ id: ME, name: '나' }, { id: 'u2', name: '철수' }, { id: 'u3', name: '영희' }]],
  ['d1', [{ id: ME, name: '나' }, { id: 'u2', name: '김철수' }]],
]);
const row = (room, extra = {}) => ({ room, customName: null, teamName: '팀A', ...extra });

test('parseRoomSearchQuery: 검색어는 소문자·trim, scope 기본 team은 teamId 필수, all은 teamId 없이 가능', () => {
  assert.equal(parseRoomSearchQuery({ q: '  ABC ', teamId: 't' }).q, 'abc');
  assert.equal(parseRoomSearchQuery({ q: 'a', teamId: 't' }).scope, 'team');
  assert.ok(parseRoomSearchQuery({ q: 'a' }).error);
  const all = parseRoomSearchQuery({ q: 'a', scope: 'all' });
  assert.equal(all.scope, 'all');
  assert.equal(all.error, undefined);
  // 빈 검색어는 teamId 없이도 에러가 아니다(호출부가 빈 결과).
  assert.equal(parseRoomSearchQuery({ q: ' ' }).error, undefined);
  assert.equal(parseRoomSearchQuery({ q: 'a', scope: 'weird', teamId: 't' }).scope, 'team');
});

test('parseRoomSearchQuery: order·limit 기본값과 상한', () => {
  const d = parseRoomSearchQuery({ q: 'a', scope: 'all' });
  assert.equal(d.order, 'desc');
  assert.equal(d.limit, ROOM_SEARCH_DEFAULT_LIMIT);
  assert.equal(parseRoomSearchQuery({ q: 'a', scope: 'all', order: 'asc' }).order, 'asc');
  assert.equal(parseRoomSearchQuery({ q: 'a', scope: 'all', limit: '9999' }).limit, ROOM_SEARCH_MAX_LIMIT);
  assert.equal(parseRoomSearchQuery({ q: 'a', scope: 'all', limit: '7' }).limit, 7);
});

test('roomSearchDisplayName: 나와의 대화·별칭·토픽/그룹 이름·1:1 상대 이름·이름 없는 그룹 멤버 이름', () => {
  assert.equal(roomSearchDisplayName(self, '별칭', [], ME), '나와의 대화');
  assert.equal(roomSearchDisplayName(topic, null, [], ME), '마케팅 전략');
  assert.equal(roomSearchDisplayName(topic, '내 별칭', [], ME), '내 별칭');
  assert.equal(roomSearchDisplayName(dm, null, members.get('d1'), ME), '김철수');
  assert.equal(roomSearchDisplayName(unnamedGroup, null, members.get('g1'), ME), '영희, 철수');
});

test('matchRoomsByName: 표시 이름 부분 일치(대소문자 무시), 이름 없는 그룹은 멤버 이름으로도 찾힌다', () => {
  const rows = [row(topic), row(unnamedGroup), row(namedGroup), row(dm), row(self)];
  const names = (q) => matchRoomsByName(rows, members, q, ME).map((r) => r.name);
  assert.deepEqual(names('전략'), ['마케팅 전략']);
  assert.deepEqual(names('철수'), ['영희, 철수', '김철수']); // 이름 없는 그룹 + 1:1 상대
  assert.deepEqual(names('영희'), ['영희, 철수']);
  assert.deepEqual(names('나와의'), ['나와의 대화']);
  assert.deepEqual(names('점심'), ['점심 모임']);
  assert.deepEqual(names('없는이름'), []);
  const eng = [row({ ...topic, id: 't9', name: 'Project X' })];
  assert.equal(matchRoomsByName(eng, members, 'project', ME).length, 1);
});

test('matchRoomsByName: %·_ 는 와일드카드가 아니라 글자 그대로', () => {
  const rows = [row(topic), row({ ...topic, id: 't2', name: '100% 달성' }), row({ ...topic, id: 't3', name: 'a_b' })];
  assert.deepEqual(matchRoomsByName(rows, members, '%', ME).map((r) => r.name), ['100% 달성']);
  assert.deepEqual(matchRoomsByName(rows, members, '_', ME).map((r) => r.name), ['a_b']);
  assert.deepEqual(matchRoomsByName(rows, members, String.fromCharCode(92), ME), []);
});

test('matchRoomsByName: 나에게만 바꾼 이름이 있으면 그 이름과 원래 이름 둘 다로 찾힌다', () => {
  const rows = [row(topic, { customName: '내 마케팅' })];
  assert.equal(matchRoomsByName(rows, members, '내 마케', ME)[0].name, '내 마케팅');
  assert.equal(matchRoomsByName(rows, members, '전략', ME)[0].name, '내 마케팅');
});

test('sortRoomsByActivity: 최신 순/과거 순은 마지막 활동 시각, 같으면 이름순', () => {
  const rows = [
    { name: '나', lastActivityAt: 100 },
    { name: '다', lastActivityAt: 300 },
    { name: '가', lastActivityAt: 300 },
  ];
  assert.deepEqual(sortRoomsByActivity(rows, 'desc').map((r) => r.name), ['가', '다', '나']);
  assert.deepEqual(sortRoomsByActivity(rows, 'asc').map((r) => r.name), ['나', '가', '다']);
});
