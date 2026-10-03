import { and, asc, desc, eq, gte, inArray, isNull, lte, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { afterCursor, cursorOrder, epochMs } from './cursorSql.js';
import {
  dmHistoryFloors,
  messageAttachments,
  messages,
  pollFavorites,
  pollOptions,
  polls,
  pollVotes,
  roomMembers,
  rooms,
  users,
} from '../schema.js';

/**
 * 투표 메시지 한 건을 통째로 만든다 — 메시지(type='poll') + 첨부 + polls + 보기들을 한 트랜잭션에
 * 넣어서, 중간에 실패해도 "보기 없는 투표"나 "투표 없는 투표 메시지"가 남지 않게 한다.
 * [message]는 messages 행에 넣을 값, [attachments]는 message_attachments에 넣을 값(없으면 빈 배열).
 */
export function insertPollMessage({ message, attachments, poll, optionTexts }) {
  return db.transaction(async (tx) => {
    const [messageRow] = await tx.insert(messages).values(message).returning();
    let attachmentRows = [];
    if (attachments.length > 0) {
      attachmentRows = await tx
        .insert(messageAttachments)
        .values(attachments.map((a, i) => ({ ...a, messageId: messageRow.id, position: i })))
        .returning();
    }
    const [pollRow] = await tx
      .insert(polls)
      .values({ ...poll, messageId: messageRow.id, roomId: messageRow.roomId })
      .returning();
    const optionRows = await tx
      .insert(pollOptions)
      .values(optionTexts.map((text, position) => ({ pollId: pollRow.id, position, text })))
      .returning();
    optionRows.sort((a, b) => a.position - b.position);
    return { message: messageRow, attachments: attachmentRows, poll: pollRow, options: optionRows };
  });
}

export function findPollById(id) {
  return db
    .select()
    .from(polls)
    .where(eq(polls.id, id))
    .then((rows) => rows[0] ?? null);
}

/** 메시지 id들에 딸린 투표 행들(투표가 아닌 메시지는 그냥 빠진다). */
export function listPollsByMessageIds(messageIds) {
  if (messageIds.length === 0) return Promise.resolve([]);
  return db.select().from(polls).where(inArray(polls.messageId, messageIds));
}

export function listPollsByIds(pollIds) {
  if (pollIds.length === 0) return Promise.resolve([]);
  return db.select().from(polls).where(inArray(polls.id, pollIds));
}

export function listOptionsForPolls(pollIds) {
  if (pollIds.length === 0) return Promise.resolve([]);
  return db
    .select()
    .from(pollOptions)
    .where(inArray(pollOptions.pollId, pollIds))
    .orderBy(asc(pollOptions.position));
}

/** 투표들의 표 전부(누가 어느 보기를) — 이름은 공개 투표의 "투표한 사람" 목록에 쓴다. */
export function listVotesForPolls(pollIds) {
  if (pollIds.length === 0) return Promise.resolve([]);
  return db
    .select({
      pollId: pollVotes.pollId,
      optionId: pollVotes.optionId,
      userId: pollVotes.userId,
      name: users.name,
      username: users.username,
    })
    .from(pollVotes)
    .innerJoin(users, eq(users.id, pollVotes.userId))
    .where(inArray(pollVotes.pollId, pollIds))
    .orderBy(asc(pollVotes.createdAt));
}

/** 이 사람이 즐겨찾기한 투표 id 집합. */
export async function listFavoritePollIds(pollIds, userId) {
  if (pollIds.length === 0) return new Set();
  const rows = await db
    .select({ pollId: pollFavorites.pollId })
    .from(pollFavorites)
    .where(and(eq(pollFavorites.userId, userId), inArray(pollFavorites.pollId, pollIds)));
  return new Set(rows.map((r) => r.pollId));
}

/**
 * 내 표를 통째로 [optionIds]로 바꾼다(재투표·취소 포함 — 빈 배열이면 표만 지운다). 투표 행을 잠근 채
 * 마감 여부를 다시 보고 지운 뒤 넣는다 — 마감(close)과 동시에 들어온 표가 마감 뒤에 저장되거나,
 * 두 기기에서 동시에 바꿔 표가 섞이는 것을 막는다. 마감됐으면 `{ closed: true }`.
 */
export function replaceMyVotes(pollId, userId, optionIds) {
  return db.transaction(async (tx) => {
    const [poll] = await tx.select().from(polls).where(eq(polls.id, pollId)).for('update');
    if (!poll) return { missing: true };
    if (poll.closedAt || new Date(poll.closesAt).getTime() <= Date.now()) return { closed: true };
    await tx.delete(pollVotes).where(and(eq(pollVotes.pollId, pollId), eq(pollVotes.userId, userId)));
    if (optionIds.length > 0) {
      await tx.insert(pollVotes).values(optionIds.map((optionId) => ({ pollId, optionId, userId })));
    }
    return { ok: true };
  });
}

/** 일찍 마감 — 아직 열려 있을 때만 찍는다(동시에 두 번 눌러도 한 번만). 이미 닫혀 있으면 null. */
export async function closePollEarly(pollId, closedBy) {
  const [row] = await db
    .update(polls)
    .set({ closedAt: new Date(), closedBy })
    .where(and(eq(polls.id, pollId), isNull(polls.closedAt)))
    .returning();
  return row ?? null;
}

export async function setPollFavorite(pollId, userId, favorite) {
  if (favorite) {
    await db.insert(pollFavorites).values({ pollId, userId }).onConflictDoNothing();
  } else {
    await db.delete(pollFavorites).where(and(eq(pollFavorites.pollId, pollId), eq(pollFavorites.userId, userId)));
  }
}

/**
 * 내가 즐겨찾기한 투표 — 이 팀에서 내가 아직 멤버인 방의, 지워지지 않은 것만 최근 즐겨찾기순으로.
 * DM "진짜 나가기" 이후에는 그 이전 메시지가 내게 안 보여야 해서 다른 조회와 같은 하한을 적용한다.
 */
export async function listFavoritePolls(userId, teamId) {
  return db
    .select({ message: messages, room: rooms, favoritedAt: pollFavorites.createdAt })
    .from(pollFavorites)
    .innerJoin(polls, eq(polls.id, pollFavorites.pollId))
    .innerJoin(messages, eq(messages.id, polls.messageId))
    .innerJoin(rooms, eq(rooms.id, messages.roomId))
    .innerJoin(roomMembers, and(eq(roomMembers.roomId, rooms.id), eq(roomMembers.userId, userId)))
    .leftJoin(dmHistoryFloors, and(eq(dmHistoryFloors.roomId, rooms.id), eq(dmHistoryFloors.userId, userId)))
    .where(
      and(
        eq(pollFavorites.userId, userId),
        eq(rooms.teamId, teamId),
        isNull(messages.deletedAt),
        or(isNull(dmHistoryFloors.hiddenBeforeAt), gte(messages.createdAt, dmHistoryFloors.hiddenBeforeAt)),
      ),
    )
    .orderBy(desc(pollFavorites.createdAt));
}

/**
 * 투표 목록 패널(`GET /api/polls`) — 이 팀에서 내가 아직 멤버인 방(비밀 대화 제외)의, 지워지지 않은 투표를 만든 시각순으로.
 * [q]는 pollListRules.js의 parsePollListQuery 결과(status·participated·creatorId·roomId·since/until·order·cursor).
 * 기간·커서·정렬은 모두 투표를 만든 시각(polls.created_at) 기준이다. DM "진짜 나가기" 이전 투표는 다른 조회와 같은 하한으로 뺀다.
 * 돌려주는 값: `{ rows: [{ message, room, pollId, pollMs }](limit + 1개까지), total }` — total은 커서와 상관없이 조건에 맞는 전체 개수.
 */
export async function listPollPanelRows(userId, q) {
  const now = new Date();
  const base = [
    eq(rooms.teamId, q.teamId),
    eq(rooms.isSecret, false),
    isNull(messages.deletedAt),
    or(isNull(dmHistoryFloors.hiddenBeforeAt), gte(messages.createdAt, dmHistoryFloors.hiddenBeforeAt)),
  ];
  if (q.roomId) base.push(eq(polls.roomId, q.roomId));
  if (q.creatorId) base.push(eq(polls.creatorId, q.creatorId));
  if (q.since) base.push(gte(polls.createdAt, q.since));
  if (q.until) base.push(lte(polls.createdAt, q.until));
  // 마감 = 일찍 마감했거나 마감 시각이 지났다(polls.js의 isPollClosed와 같은 기준).
  const closed = or(sql`${polls.closedAt} is not null`, lte(polls.closesAt, now));
  if (q.status === 'closed') base.push(closed);
  if (q.status === 'open') base.push(and(isNull(polls.closedAt), sql`${polls.closesAt} > ${now.toISOString()}::timestamptz`));
  if (q.participated !== 'all') {
    const voted = sql`exists (select 1 from ${pollVotes} where ${pollVotes.pollId} = ${polls.id} and ${pollVotes.userId} = ${userId})`;
    base.push(q.participated === 'yes' ? voted : sql`not ${voted}`);
  }

  const joined = (fields) =>
    db
      .select(fields)
      .from(polls)
      .innerJoin(messages, eq(messages.id, polls.messageId))
      .innerJoin(rooms, eq(rooms.id, polls.roomId))
      .innerJoin(roomMembers, and(eq(roomMembers.roomId, rooms.id), eq(roomMembers.userId, userId)))
      .leftJoin(dmHistoryFloors, and(eq(dmHistoryFloors.roomId, rooms.id), eq(dmHistoryFloors.userId, userId)));

  const [rows, [{ total }]] = await Promise.all([
    joined({ message: messages, room: rooms, pollId: polls.id, pollMs: epochMs(polls.createdAt) })
      .where(and(...base, afterCursor(polls.createdAt, polls.id, q.cursor, q.order)))
      .orderBy(...cursorOrder(polls.createdAt, polls.id, q.order))
      .limit(q.limit + 1),
    joined({ total: sql`count(*)::int` }).where(and(...base)),
  ]);
  return { rows, total };
}
