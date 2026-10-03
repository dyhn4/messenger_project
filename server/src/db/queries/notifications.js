import { and, desc, eq, inArray, isNull, lt, lte, or, isNotNull, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { notificationSettings, notifications, roomMembers, rooms, teams } from '../schema.js';
import { unreadCountsOf } from '../../notificationRules.js';

// 'mention'·'mention_all'은 멘션, 'board_'로 시작하는 것은 보드 알림 — 알림 센터 탭과 배지가 이 두 묶음으로 센다.
const isMentionKind = inArray(notifications.kind, ['mention', 'mention_all']);
const isBoardKind = sql`left(${notifications.kind}, 6) = 'board_'`;
// mention_personal(개인 멘션만)·mention_all(@all만)은 알림 센터 멘션 탭의 드롭다운 필터용 — notificationRules.js NOTIFICATION_GROUPS.
const GROUPS = {
  mention: isMentionKind,
  mention_personal: eq(notifications.kind, 'mention'),
  mention_all: eq(notifications.kind, 'mention_all'),
  board: isBoardKind,
};

// 받는 사람이 지금도 그 방의 멤버인 알림만 본다(나간 방의 알림이 배지에 남지 않게). 방이 없는 알림(앞으로의 종류)은 통과.
const stillMember = or(isNull(notifications.roomId), isNotNull(roomMembers.userId));

/** 알림 행을 한 번에 넣는다 — 큰 토픽의 @all·새 게시글도 한 번에(파라미터 한도를 넘지 않게 500행씩 끊는다). */
export async function insertNotifications(rows) {
  const inserted = [];
  for (let i = 0; i < rows.length; i += 500) {
    inserted.push(...(await db.insert(notifications).values(rows.slice(i, i + 500)).returning()));
  }
  return inserted;
}

/**
 * 사람마다 안 읽은 멘션·보드 알림 수 {userId: {mention, board, mentionPersonal, mentionAll}} — 요청한 모든 사람이
 * (0이라도) 들어 있다. `mention`은 개인 멘션 + @all 합계다.
 */
export async function unreadCountsForUsers(userIds) {
  const map = new Map(userIds.map((id) => [id, unreadCountsOf()]));
  for (let i = 0; i < userIds.length; i += 1000) {
    const chunk = userIds.slice(i, i + 1000);
    const rows = await db
      .select({
        userId: notifications.userId,
        mentionPersonal: sql`count(*) filter (where ${GROUPS.mention_personal})`.mapWith(Number),
        mentionAll: sql`count(*) filter (where ${GROUPS.mention_all})`.mapWith(Number),
        board: sql`count(*) filter (where ${isBoardKind})`.mapWith(Number),
      })
      .from(notifications)
      .leftJoin(roomMembers, and(eq(roomMembers.roomId, notifications.roomId), eq(roomMembers.userId, notifications.userId)))
      .where(and(inArray(notifications.userId, chunk), isNull(notifications.readAt), stillMember))
      .groupBy(notifications.userId);
    for (const r of rows) map.set(r.userId, unreadCountsOf(r));
  }
  return map;
}

/** 이 방에서 내가 읽지 않은 멘션 알림 수 — 방 목록의 "@" 표시(rooms.js toRoomDto). */
export async function countUnreadMentionsInRoom(userId, roomId) {
  const [row] = await db
    .select({ count: sql`count(*)`.mapWith(Number) })
    .from(notifications)
    .where(and(eq(notifications.userId, userId), eq(notifications.roomId, roomId), isNull(notifications.readAt), isMentionKind));
  return row?.count ?? 0;
}

/**
 * 알림 목록(최신순). [group]은 'mention' | 'mention_personal' | 'mention_all' | 'board' | null(전부). 더 없는지 알려면 limit+1개를 읽어 오는 쪽(호출부)이
 * 자른다. 방이 없어졌거나 내가 더는 멤버가 아닌 항목은 뺀다.
 */
export async function listNotificationRows({ userId, group, before, limit, unreadOnly }) {
  const conditions = [eq(notifications.userId, userId), stillMember];
  if (group && GROUPS[group]) conditions.push(GROUPS[group]);
  if (before) conditions.push(lt(notifications.createdAt, new Date(before)));
  if (unreadOnly) conditions.push(isNull(notifications.readAt));
  const rows = await db
    .select({ n: notifications, teamName: teams.name, roomType: rooms.type })
    .from(notifications)
    .leftJoin(roomMembers, and(eq(roomMembers.roomId, notifications.roomId), eq(roomMembers.userId, notifications.userId)))
    .leftJoin(rooms, eq(rooms.id, notifications.roomId))
    .leftJoin(teams, eq(teams.id, notifications.teamId))
    .where(and(...conditions))
    .orderBy(desc(notifications.createdAt), desc(notifications.id))
    .limit(limit);
  return rows.map((r) => ({ ...r.n, teamName: r.teamName ?? null, roomType: r.roomType ?? null }));
}

/**
 * 읽음 처리 — 안 읽은 것만 바꾸고 바뀐 개수를 돌려준다. 조건은 하나씩: ids / group(그 묶음 전부) / messageId(그 메시지의
 * 알림 전부) / roomId(+ beforeMs: 그 시각 이전 것만 — room:read 자동 읽음).
 */
export async function markNotificationsRead({ userId, ids, group, messageId, roomId, beforeMs }) {
  const conditions = [eq(notifications.userId, userId), isNull(notifications.readAt)];
  if (ids) conditions.push(inArray(notifications.id, ids));
  if (group && GROUPS[group]) conditions.push(GROUPS[group]);
  if (messageId) conditions.push(eq(notifications.messageId, messageId));
  if (roomId) {
    conditions.push(eq(notifications.roomId, roomId));
    if (beforeMs) conditions.push(lte(notifications.createdAt, new Date(beforeMs)));
  }
  const changed = await db
    .update(notifications)
    .set({ readAt: new Date() })
    .where(and(...conditions))
    .returning({ id: notifications.id });
  return changed.length;
}

/** 메시지가 지워질 때 — 그 메시지(와 딸린 댓글)의 알림을 지우고, 안 읽음 수가 바뀐 사람의 id를 돌려준다. */
export async function deleteNotificationsForMessage(messageId) {
  const rows = await db
    .delete(notifications)
    .where(eq(notifications.messageId, messageId))
    .returning({ userId: notifications.userId, readAt: notifications.readAt });
  return [...new Set(rows.filter((r) => !r.readAt).map((r) => r.userId))];
}

/** 댓글이 지워질 때. */
export async function deleteNotificationsForComment(commentId) {
  const rows = await db
    .delete(notifications)
    .where(eq(notifications.commentId, commentId))
    .returning({ userId: notifications.userId, readAt: notifications.readAt });
  return [...new Set(rows.filter((r) => !r.readAt).map((r) => r.userId))];
}

/**
 * 수정으로 사라진 멘션의 알림을 지운다 — 메시지([commentId] 없음)는 그 메시지 본문에 대한 것만, 댓글은 그 댓글에 대한
 * 것만. [userIds]를 주면 그 사람들의 개인 멘션, [all]이면 @all 알림.
 */
export async function deleteMentionNotifications({ messageId, commentId = null, userIds = [], all = false }) {
  const who = [];
  if (userIds.length > 0) who.push(and(eq(notifications.kind, 'mention'), inArray(notifications.userId, userIds)));
  if (all) who.push(eq(notifications.kind, 'mention_all'));
  if (who.length === 0) return [];
  const scope = commentId ? eq(notifications.commentId, commentId) : and(eq(notifications.messageId, messageId), isNull(notifications.commentId));
  const rows = await db
    .delete(notifications)
    .where(and(scope, or(...who)))
    .returning({ userId: notifications.userId, readAt: notifications.readAt });
  return [...new Set(rows.filter((r) => !r.readAt).map((r) => r.userId))];
}

/** 보존 기간이 지난 알림 정리(retention.js) — 지운 개수. */
export async function deleteNotificationsOlderThan(cutoff) {
  const rows = await db.delete(notifications).where(lt(notifications.createdAt, cutoff)).returning({ id: notifications.id });
  return rows.length;
}

// ── 설정 ────────────────────────────────────────────────────────────────

/** 여러 사람의 알림 설정을 한 번에 {userId: {mentionAll, boardLevel}} — 행이 없는 사람은 들어 있지 않다(기본값은 호출부). */
export async function getNotificationSettingsMap(userIds) {
  const map = new Map();
  if (userIds.length === 0) return map;
  for (let i = 0; i < userIds.length; i += 1000) {
    const rows = await db
      .select()
      .from(notificationSettings)
      .where(inArray(notificationSettings.userId, userIds.slice(i, i + 1000)));
    for (const r of rows) map.set(r.userId, { mentionAll: r.mentionAll, boardLevel: r.boardLevel });
  }
  return map;
}

export async function upsertNotificationSettings(userId, patch) {
  const [row] = await db
    .insert(notificationSettings)
    .values({ userId, ...patch })
    .onConflictDoUpdate({ target: notificationSettings.userId, set: { ...patch, updatedAt: new Date() } })
    .returning();
  return { mentionAll: row.mentionAll, boardLevel: row.boardLevel };
}
