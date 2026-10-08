import { and, eq, gte, inArray, isNull, lte, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { dmHistoryFloors, messageComments, messages, roomMembers, rooms, teamMembers, teams } from '../schema.js';
import { afterCursor, cursorOrder, epochMs } from './cursorSql.js';

// "내가 쓴 글"(myPosts.js) — 내가 보낸 메시지와 댓글을 각각 [limit + 1]개(다음 쪽이 있는지 보려고 하나 더)까지. 둘 다 "이 팀에서
// 내가 아직 멤버인 방(비밀 대화 제외)의, 지워지지 않은 것"만이고, DM "진짜 나가기" 이후에는 그 이전 글이 내게 안 보여야 해서
// 다른 조회와 같은 하한(dm_history_floors)을 적용한다. 기간·커서·정렬은 모두 글을 쓴 시각 기준이다. [q]는 myPostsRules.js의
// parseMyPostsQuery 결과 — "모든 팀"(allTeams)이면 내가 아직 속한 팀들의 방, 아니면 teamId 한 팀의 방만이고, 검색어(text)가
// 있으면 본문(게시글은 제목도)에 그 글자가 들어 있는 것만(통합 검색 searchMessages와 같은 부분 일치).

const nonBlank = (col) => sql`btrim(coalesce(${col}, '')) <> ''`;

/** 검색어를 LIKE 패턴으로 — %·_·\는 와일드카드가 아니라 글자 그대로 찾는다(searchMessages와 같은 이스케이프). */
const likePattern = (text) => `%${text.replace(/[\\%_]/g, '\\$&')}%`;
const contains = (col, pattern) => sql`lower(${col}) like ${pattern}`;

/** 팀 범위 — 모든 팀이면 내가 아직 속한 팀(방 멤버여도 이미 나간 팀의 방은 빠진다), 아니면 그 팀 하나. */
function teamScope(q, userId) {
  return q.allTeams
    ? sql`${rooms.teamId} in (select ${teamMembers.teamId} from ${teamMembers} where ${teamMembers.userId} = ${userId})`
    : eq(rooms.teamId, q.teamId);
}

function joinRoom(query, roomIdColumn, userId) {
  return query
    .innerJoin(rooms, eq(rooms.id, roomIdColumn))
    .innerJoin(teams, eq(teams.id, rooms.teamId))
    .innerJoin(roomMembers, and(eq(roomMembers.roomId, rooms.id), eq(roomMembers.userId, userId)))
    .leftJoin(dmHistoryFloors, and(eq(dmHistoryFloors.roomId, rooms.id), eq(dmHistoryFloors.userId, userId)));
}

/** 본문이나 제목이 있는 일반 메시지(text)·게시글(post). 파일·이미지·이모티콘만인 것, 시스템·투표는 빠진다. */
export function listMyPostMessages(userId, q) {
  const createdAt = messages.createdAt;
  const conditions = [
    eq(messages.senderId, userId),
    inArray(messages.type, ['text', 'post']),
    isNull(messages.deletedAt),
    or(nonBlank(messages.text), nonBlank(messages.title)),
    teamScope(q, userId),
    eq(rooms.isSecret, false),
    or(isNull(dmHistoryFloors.hiddenBeforeAt), gte(createdAt, dmHistoryFloors.hiddenBeforeAt)),
    afterCursor(createdAt, messages.id, q.cursor, q.order),
  ];
  if (q.roomId) conditions.push(eq(messages.roomId, q.roomId));
  if (q.text) {
    const pattern = likePattern(q.text);
    conditions.push(or(contains(messages.text, pattern), contains(messages.title, pattern)));
  }
  if (q.since) conditions.push(gte(createdAt, q.since));
  if (q.until) conditions.push(lte(createdAt, q.until));
  return joinRoom(
    db.select({ message: messages, room: rooms, teamName: teams.name, ms: epochMs(createdAt) }).from(messages),
    messages.roomId,
    userId,
  )
    .where(and(...conditions))
    .orderBy(...cursorOrder(createdAt, messages.id, q.order))
    .limit(q.limit + 1);
}

/** 본문이 있는 댓글. 원본 메시지가 지워졌으면 갈 곳이 없으니 같이 뺀다. */
export function listMyPostComments(userId, q) {
  const createdAt = messageComments.createdAt;
  const conditions = [
    eq(messageComments.senderId, userId),
    isNull(messageComments.deletedAt),
    nonBlank(messageComments.text),
    isNull(messages.deletedAt),
    teamScope(q, userId),
    eq(rooms.isSecret, false),
    or(isNull(dmHistoryFloors.hiddenBeforeAt), gte(createdAt, dmHistoryFloors.hiddenBeforeAt)),
    afterCursor(createdAt, messageComments.id, q.cursor, q.order),
  ];
  if (q.roomId) conditions.push(eq(messageComments.roomId, q.roomId));
  if (q.text) conditions.push(contains(messageComments.text, likePattern(q.text)));
  if (q.since) conditions.push(gte(createdAt, q.since));
  if (q.until) conditions.push(lte(createdAt, q.until));
  return joinRoom(
    db
      .select({
        comment: messageComments,
        parent: { id: messages.id, type: messages.type, text: messages.text, title: messages.title },
        room: rooms,
        teamName: teams.name,
        ms: epochMs(createdAt),
      })
      .from(messageComments)
      .innerJoin(messages, eq(messages.id, messageComments.messageId)),
    messageComments.roomId,
    userId,
  )
    .where(and(...conditions))
    .orderBy(...cursorOrder(createdAt, messageComments.id, q.order))
    .limit(q.limit + 1);
}
