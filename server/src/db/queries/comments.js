import { and, asc, desc, eq, gt, gte, inArray, isNull, lt, ne, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { messageComments } from '../schema.js';

export async function insertComment(fields) {
  const [row] = await db.insert(messageComments).values(fields).returning();
  return row;
}

/** 여러 메시지의 댓글을 한 번에(생성 순) 가져온다 — 호출부에서 messageId별로 묶는다. */
export function listCommentsForMessages(messageIds) {
  if (messageIds.length === 0) return Promise.resolve([]);
  return db
    .select()
    .from(messageComments)
    .where(inArray(messageComments.messageId, messageIds))
    .orderBy(asc(messageComments.createdAt));
}

/** 방의 [since, before) 시간대에 달린 댓글 전부(부모가 뭐든 상관없이).
 *
 * 댓글은 자기가 달린 시각 위치에 타임라인으로 끼워 넣어 보여주는데(클라이언트의 합성 항목),
 * 옛날 메시지에 오늘 댓글을 달면 "부모 메시지는 창 밖(오래됨) + 댓글은 창 안(최근)"이 된다.
 * 그럼 클라이언트가 부모를 못 찾아 댓글 카드를 통째로 안 그린다 — 그런 부모를 추가로
 * 끌어오기 위해 쓴다(rooms.js의 /rooms/:id/messages 참고). */
export function listCommentsInRoomBetween(roomId, since, before) {
  const conditions = [eq(messageComments.roomId, roomId), gte(messageComments.createdAt, since)];
  if (before) conditions.push(lt(messageComments.createdAt, before));
  return db
    .select()
    .from(messageComments)
    .where(and(...conditions))
    .orderBy(asc(messageComments.createdAt));
}

export function findCommentById(id) {
  return db
    .select()
    .from(messageComments)
    .where(eq(messageComments.id, id))
    .then((rows) => rows[0] ?? null);
}

export async function updateCommentText(id, text, textFormat = null, mentions = null) {
  const [row] = await db
    .update(messageComments)
    .set({ text, textFormat, mentions, editedAt: new Date() })
    .where(eq(messageComments.id, id))
    .returning();
  return row;
}

/** 소프트 삭제 — 행은 남기고(원본 메시지처럼 참조가 필요하진 않지만 동일 패턴 유지) deletedAt만
 * 찍는다. text는 지우지 않고 남겨두되, toCommentDto가 deletedAt이 찍힌 건 null로 가린다. */
export async function softDeleteComment(id) {
  const [row] = await db
    .update(messageComments)
    .set({ deletedAt: new Date() })
    .where(eq(messageComments.id, id))
    .returning();
  return row;
}

/** 방 목록 정렬용 "최근 활동" 계산에 쓴다(rooms.js의 toRoomDto, getLastMessageAt과 짝) — 이
 * 방의 가장 최근 댓글 시각. 댓글이 하나도 없으면 null. */
export async function getLastCommentAt(roomId) {
  const [row] = await db
    .select({ createdAt: messageComments.createdAt })
    .from(messageComments)
    .where(eq(messageComments.roomId, roomId))
    .orderBy(desc(messageComments.createdAt))
    .limit(1);
  return row?.createdAt ?? null;
}

/** 방 목록 미리보기용 — 가장 최근의 지워지지 않은 댓글 한 건(messages.js의
 * getLastMessageForPreview와 짝 — rooms.js의 toRoomDto가 둘 중 더 최근 걸 고른다). */
export async function getLastCommentForPreview(roomId) {
  const [row] = await db
    .select({ type: messageComments.type, text: messageComments.text, fileName: messageComments.fileName, senderName: messageComments.senderName, createdAt: messageComments.createdAt })
    .from(messageComments)
    .where(and(eq(messageComments.roomId, roomId), isNull(messageComments.deletedAt)))
    .orderBy(desc(messageComments.createdAt))
    .limit(1);
  return row ?? null;
}

/** rooms.js의 countUnreadForUser(messages 기준)와 동일한 규칙을 message_comments에 적용한다 —
 * 로그아웃해 있는 동안(소켓으로 comment:new를 못 받은 채) 달린 댓글도, 다시 로그인해서 방
 * 목록을 새로 받아올 때 이 값이 unreadCount에 합산되어 안읽음 뱃지에 반영되게 한다. */
export async function countUnreadCommentsForUser(roomId, requesterId, sinceMs) {
  const [row] = await db
    .select({ count: sql`count(*)`.mapWith(Number) })
    .from(messageComments)
    .where(
      and(
        eq(messageComments.roomId, roomId),
        // 탈퇴한 사람의 댓글(senderId null)도 세도록 — messages 쪽 countUnreadForUser와 같은 이유.
        or(isNull(messageComments.senderId), ne(messageComments.senderId, requesterId)),
        gt(messageComments.createdAt, new Date(sinceMs)),
      ),
    );
  return row?.count ?? 0;
}
