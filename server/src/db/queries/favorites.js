import { and, desc, eq, gte, isNull, lt, ne, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import {
  commentFavorites,
  dmHistoryFloors,
  favoriteFiles,
  memberFavorites,
  messageAttachments,
  messageComments,
  messageFavorites,
  messages,
  pollFavorites,
  polls,
  roomMembers,
  rooms,
  teamMembers,
  users,
} from '../schema.js';

// 통합 즐겨찾기 조회(favorites.js) — 종류마다 "이 팀에서 내가 아직 멤버인 방의, 지워지지 않은 것"만
// 최근 즐겨찾기순으로 [limit + 1]건(다음 쪽이 있는지 보려고 하나 더) 돌려준다. [before]는 이 시각(Date)보다
// 먼저 담은 것만(무한 스크롤 커서). DM "진짜 나가기" 이후에는 그 이전 글이 내게 안 보여야 해서(dm_history_floors)
// 다른 조회와 같은 하한을 적용하고, 비밀 대화는 서버가 내용을 모르므로 아예 뺀다.

/** 방 조인 공통 — 내가 그 방 멤버여야 하고(roomMembers), DM 하한(floor)보다 전의 글은 안 보인다. */
function visibleIn(createdAtColumn, teamId) {
  return and(
    eq(rooms.teamId, teamId),
    eq(rooms.isSecret, false),
    or(isNull(dmHistoryFloors.hiddenBeforeAt), gte(createdAtColumn, dmHistoryFloors.hiddenBeforeAt)),
  );
}

function withMembership(query, userId) {
  return query
    .innerJoin(roomMembers, and(eq(roomMembers.roomId, rooms.id), eq(roomMembers.userId, userId)))
    .leftJoin(dmHistoryFloors, and(eq(dmHistoryFloors.roomId, rooms.id), eq(dmHistoryFloors.userId, userId)));
}

// ── 토글 ────────────────────────────────────────────────────────────────

export async function setMessageFavorite(userId, messageId, favorite) {
  if (favorite) {
    await db.insert(messageFavorites).values({ userId, messageId }).onConflictDoNothing();
  } else {
    await db
      .delete(messageFavorites)
      .where(and(eq(messageFavorites.userId, userId), eq(messageFavorites.messageId, messageId)));
  }
}

export async function setCommentFavorite(userId, commentId, favorite) {
  if (favorite) {
    await db.insert(commentFavorites).values({ userId, commentId }).onConflictDoNothing();
  } else {
    await db
      .delete(commentFavorites)
      .where(and(eq(commentFavorites.userId, userId), eq(commentFavorites.commentId, commentId)));
  }
}

export async function setMemberFavorite(userId, teamId, favoriteUserId, favorite) {
  if (favorite) {
    await db.insert(memberFavorites).values({ userId, teamId, favoriteUserId }).onConflictDoNothing();
  } else {
    await db
      .delete(memberFavorites)
      .where(
        and(
          eq(memberFavorites.userId, userId),
          eq(memberFavorites.teamId, teamId),
          eq(memberFavorites.favoriteUserId, favoriteUserId),
        ),
      );
  }
}

// ── 내가 담은 id 모음(별 표시용) ─────────────────────────────────────────

const IDS_CAP = 5000;

/** 내가 즐겨찾기한 메시지·댓글·멤버 id 전부(팀 무관) — 화면이 메뉴의 "즐겨찾기 / 해제"를 정하는 데 쓴다. */
export async function listFavoriteIds(userId) {
  const [messageRows, commentRows, memberRows] = await Promise.all([
    db
      .select({ id: messageFavorites.messageId })
      .from(messageFavorites)
      .where(eq(messageFavorites.userId, userId))
      .orderBy(desc(messageFavorites.createdAt))
      .limit(IDS_CAP),
    db
      .select({ id: commentFavorites.commentId })
      .from(commentFavorites)
      .where(eq(commentFavorites.userId, userId))
      .orderBy(desc(commentFavorites.createdAt))
      .limit(IDS_CAP),
    db
      .select({ teamId: memberFavorites.teamId, userId: memberFavorites.favoriteUserId })
      .from(memberFavorites)
      .where(eq(memberFavorites.userId, userId))
      .orderBy(desc(memberFavorites.createdAt))
      .limit(IDS_CAP),
  ]);
  return {
    messages: messageRows.map((r) => r.id),
    comments: commentRows.map((r) => r.id),
    members: memberRows,
  };
}

// ── 종류별 목록 ─────────────────────────────────────────────────────────

export function listFavoriteMessages(userId, teamId, { before, limit }) {
  const conditions = [
    eq(messageFavorites.userId, userId),
    isNull(messages.deletedAt),
    ne(messages.type, 'system'),
    ne(messages.type, 'poll'),
    visibleIn(messages.createdAt, teamId),
  ];
  if (before) conditions.push(lt(messageFavorites.createdAt, before));
  return withMembership(
    db
      .select({ message: messages, room: rooms, favoritedAt: messageFavorites.createdAt })
      .from(messageFavorites)
      .innerJoin(messages, eq(messages.id, messageFavorites.messageId))
      .innerJoin(rooms, eq(rooms.id, messages.roomId)),
    userId,
  )
    .where(and(...conditions))
    .orderBy(desc(messageFavorites.createdAt))
    .limit(limit + 1);
}

/** 댓글 — 원 메시지가 지워졌으면 댓글도 같이 뺀다(눌러도 갈 곳이 없다). */
export function listFavoriteComments(userId, teamId, { before, limit }) {
  const conditions = [
    eq(commentFavorites.userId, userId),
    isNull(messageComments.deletedAt),
    isNull(messages.deletedAt),
    visibleIn(messageComments.createdAt, teamId),
  ];
  if (before) conditions.push(lt(commentFavorites.createdAt, before));
  return withMembership(
    db
      .select({
        comment: messageComments,
        parent: {
          id: messages.id,
          senderName: messages.senderName,
          type: messages.type,
          text: messages.text,
          title: messages.title,
        },
        room: rooms,
        favoritedAt: commentFavorites.createdAt,
      })
      .from(commentFavorites)
      .innerJoin(messageComments, eq(messageComments.id, commentFavorites.commentId))
      .innerJoin(messages, eq(messages.id, messageComments.messageId))
      .innerJoin(rooms, eq(rooms.id, messageComments.roomId)),
    userId,
  )
    .where(and(...conditions))
    .orderBy(desc(commentFavorites.createdAt))
    .limit(limit + 1);
}

export function listFavoriteFileRows(userId, teamId, { before, limit }) {
  const conditions = [
    eq(favoriteFiles.userId, userId),
    isNull(messages.deletedAt),
    // 파일을 지운 항목은 지울 때 즐겨찾기 행도 함께 지우지만, 혹시 남아 있어도 목록에는 내지 않는다.
    isNull(messages.fileDeletedAt),
    sql`not exists (select 1 from ${messageAttachments} where ${messageAttachments.messageId} = ${favoriteFiles.messageId} and ${messageAttachments.fileUrl} = ${favoriteFiles.fileUrl} and ${messageAttachments.deletedAt} is not null)`,
    visibleIn(messages.createdAt, teamId),
  ];
  if (before) conditions.push(lt(favoriteFiles.createdAt, before));
  return withMembership(
    db
      .select({ file: favoriteFiles, message: messages, room: rooms })
      .from(favoriteFiles)
      .innerJoin(messages, eq(messages.id, favoriteFiles.messageId))
      .innerJoin(rooms, eq(rooms.id, messages.roomId)),
    userId,
  )
    .where(and(...conditions))
    .orderBy(desc(favoriteFiles.createdAt))
    .limit(limit + 1);
}

export function listFavoritePollRows(userId, teamId, { before, limit }) {
  const conditions = [
    eq(pollFavorites.userId, userId),
    isNull(messages.deletedAt),
    visibleIn(messages.createdAt, teamId),
  ];
  if (before) conditions.push(lt(pollFavorites.createdAt, before));
  return withMembership(
    db
      .select({ message: messages, room: rooms, favoritedAt: pollFavorites.createdAt })
      .from(pollFavorites)
      .innerJoin(polls, eq(polls.id, pollFavorites.pollId))
      .innerJoin(messages, eq(messages.id, polls.messageId))
      .innerJoin(rooms, eq(rooms.id, messages.roomId)),
    userId,
  )
    .where(and(...conditions))
    .orderBy(desc(pollFavorites.createdAt))
    .limit(limit + 1);
}

/** 즐겨찾기한 대화방 — room_members.favorite(담은 시각은 따로 없다). 내가 숨긴 DM은 목록에서도 뺀다. */
export function listFavoriteRoomRows(userId, teamId) {
  return db
    .select({ room: rooms })
    .from(roomMembers)
    .innerJoin(rooms, eq(rooms.id, roomMembers.roomId))
    .where(
      and(
        eq(roomMembers.userId, userId),
        eq(roomMembers.favorite, true),
        eq(roomMembers.hidden, false),
        eq(rooms.teamId, teamId),
      ),
    )
    .then((rows) => rows.map((r) => r.room));
}

/** 즐겨찾기한 멤버 — 그 사람이 아직 이 팀 멤버일 때만. */
export function listFavoriteMemberRows(userId, teamId, { before, limit }) {
  const conditions = [eq(memberFavorites.userId, userId), eq(memberFavorites.teamId, teamId)];
  if (before) conditions.push(lt(memberFavorites.createdAt, before));
  return db
    .select({
      user: users,
      department: teamMembers.department,
      position: teamMembers.position,
      isOwner: teamMembers.role,
      favoritedAt: memberFavorites.createdAt,
    })
    .from(memberFavorites)
    .innerJoin(
      teamMembers,
      and(eq(teamMembers.teamId, memberFavorites.teamId), eq(teamMembers.userId, memberFavorites.favoriteUserId)),
    )
    .innerJoin(users, eq(users.id, memberFavorites.favoriteUserId))
    .where(and(...conditions))
    .orderBy(desc(memberFavorites.createdAt))
    .limit(limit + 1);
}
