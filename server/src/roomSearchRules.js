// 검색 패널 "대화방" 탭의 순수 규칙 — 요청 해석, 표시 이름 규칙, 이름 매칭, 정렬. DB는 안 건드리고
// (db/queries/roomSearch.js가 읽어 온 행을 받아) 단위 테스트(test/roomSearch.test.js)로 그대로 검증한다.
import { roomNameForViewer } from './notificationRules.js';

export const ROOM_SEARCH_DEFAULT_LIMIT = 200;
export const ROOM_SEARCH_MAX_LIMIT = 500;

/**
 * GET /api/search/rooms 쿼리 해석. scope=all이면 teamId 없이 내가 속한 모든 팀, 아니면(기본 team) teamId가 필요하다.
 * 검색어는 앞뒤 공백을 떼고 소문자로 — 빈 검색어는 q가 ''이라 호출부가 빈 결과를 돌려준다.
 */
export function parseRoomSearchQuery(query) {
  const q = String(query.q ?? '').trim().toLowerCase();
  const scope = query.scope === 'all' ? 'all' : 'team';
  const teamId = query.teamId ? String(query.teamId) : null;
  const order = query.order === 'asc' ? 'asc' : 'desc';
  const limit = Math.min(Math.max(Number(query.limit) || ROOM_SEARCH_DEFAULT_LIMIT, 1), ROOM_SEARCH_MAX_LIMIT);
  if (q && scope === 'team' && !teamId) return { error: 'teamId가 필요합니다.' };
  return { q, scope, teamId, order, limit };
}

/**
 * 화면에 보이는 방 이름 — 클라이언트 Room.displayName()과 같은 규칙: 나와의 대화는 '나와의 대화', 나에게만 바꾼 이름
 * (room_members.custom_name)이 있으면 그것, 아니면 원래 이름(1:1은 상대 이름, 이름 없는 그룹은 나를 뺀 멤버 이름들).
 */
export function roomSearchDisplayName(room, customName, members, viewerId) {
  if (room.isSelf) return '나와의 대화';
  if (customName) return customName;
  return roomNameForViewer(room, members, viewerId);
}

/**
 * [rows]({ room, customName, ... })에서 이름에 [q](소문자)가 들어 있는 방만 남기고 표시 이름을 붙인다.
 * 글자 그대로 찾는다 — SQL LIKE가 아니라 includes라 %·_가 와일드카드로 읽히지 않는다.
 * 나만의 별칭을 붙인 방은 원래 이름으로도 찾힌다. 이름 없는 그룹은 표시 이름이 멤버 이름들이라 멤버 이름으로 찾힌다.
 * [membersByRoom]: roomId → [{ id, name }] (이름 없는 방만 필요).
 */
export function matchRoomsByName(rows, membersByRoom, q, viewerId) {
  const out = [];
  for (const row of rows) {
    const members = membersByRoom.get(row.room.id) ?? [];
    const name = roomSearchDisplayName(row.room, row.customName, members, viewerId);
    const candidates = [name];
    if (row.customName && !row.room.isSelf) candidates.push(roomNameForViewer(row.room, members, viewerId));
    if (candidates.some((c) => c.toLowerCase().includes(q))) out.push({ ...row, name });
  }
  return out;
}

/** 마지막 활동순(order: 'desc' 최신 먼저 / 'asc' 오래된 먼저), 같으면 이름순. [row.lastActivityAt]은 ms. */
export function sortRoomsByActivity(rows, order) {
  const sign = order === 'asc' ? 1 : -1;
  return [...rows].sort(
    (a, b) => sign * (a.lastActivityAt - b.lastActivityAt) || a.name.localeCompare(b.name, 'ko'),
  );
}
