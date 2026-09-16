import { and, desc, eq, isNull, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { announcementComments, announcements } from '../schema.js';

/** 최신순, 삭제되지 않은 것만 — 댓글 개수(commentCount)를 함께 집계해서 목록 화면이 바로 쓸 수
 * 있게 한다. pinned가 true인 항목(최대 1개)이 지금 채팅방 상단에 고정된 공지다. */
export function listAnnouncementsForRoom(roomId) {
  return db
    .select({
      id: announcements.id,
      roomId: announcements.roomId,
      authorId: announcements.authorId,
      authorName: announcements.authorName,
      text: announcements.text,
      pinned: announcements.pinned,
      createdAt: announcements.createdAt,
      editedAt: announcements.editedAt,
      commentCount: sql`count(${announcementComments.id})`.mapWith(Number),
    })
    .from(announcements)
    .leftJoin(announcementComments, eq(announcementComments.announcementId, announcements.id))
    .where(and(eq(announcements.roomId, roomId), isNull(announcements.deletedAt)))
    .groupBy(announcements.id)
    .orderBy(desc(announcements.createdAt));
}

/** 채팅방 상단 배너용 — 지금 고정된(pinned=true) 공지 1건(없으면 null). */
export async function findLatestAnnouncementForRoom(roomId) {
  const [row] = await db
    .select()
    .from(announcements)
    .where(and(eq(announcements.roomId, roomId), eq(announcements.pinned, true), isNull(announcements.deletedAt)))
    .limit(1);
  return row ?? null;
}

export function findAnnouncementById(id) {
  return db
    .select()
    .from(announcements)
    .where(eq(announcements.id, id))
    .then((rows) => rows[0] ?? null);
}

/** 새 공지를 쓰면 그 방의 기존 고정 공지(있다면)는 자동으로 내려가고 새 글이 고정된다 — 한
 * 방에 고정 공지는 동시에 하나뿐이라는 불변식을 트랜잭션으로 지킨다. */
export async function insertAnnouncement({ id, roomId, authorId, authorName, text }) {
  return db.transaction(async (tx) => {
    await tx
      .update(announcements)
      .set({ pinned: false })
      .where(and(eq(announcements.roomId, roomId), eq(announcements.pinned, true)));
    const [row] = await tx
      .insert(announcements)
      .values({ id, roomId, authorId, authorName, text, pinned: true })
      .returning();
    return row;
  });
}

export async function updateAnnouncementText(id, text) {
  const [row] = await db
    .update(announcements)
    .set({ text, editedAt: new Date() })
    .where(eq(announcements.id, id))
    .returning();
  return row;
}

export async function unpinAnnouncement(id) {
  const [row] = await db.update(announcements).set({ pinned: false }).where(eq(announcements.id, id)).returning();
  return row;
}

export async function softDeleteAnnouncement(id) {
  const [row] = await db
    .update(announcements)
    .set({ deletedAt: new Date(), pinned: false })
    .where(eq(announcements.id, id))
    .returning();
  return row;
}

export function listCommentsForAnnouncement(announcementId) {
  return db
    .select()
    .from(announcementComments)
    .where(eq(announcementComments.announcementId, announcementId))
    .orderBy(announcementComments.createdAt);
}

export async function insertAnnouncementComment({ id, announcementId, roomId, authorId, authorName, text }) {
  const [row] = await db
    .insert(announcementComments)
    .values({ id, announcementId, roomId, authorId, authorName, text })
    .returning();
  return row;
}
