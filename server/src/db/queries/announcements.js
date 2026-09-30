import { and, desc, eq, gt, isNull, lte, ne, or, sql } from 'drizzle-orm';
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
      autoUnpinAt: announcements.autoUnpinAt,
      createdAt: announcements.createdAt,
      editedAt: announcements.editedAt,
      sourceMessageId: announcements.sourceMessageId,
      imageUrl: announcements.imageUrl,
      imageThumbnailUrl: announcements.imageThumbnailUrl,
      imageName: announcements.imageName,
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

/** 알림 센터 배지용 — [since] 이후에 올라온 안 지워진 공지 중 [userId]가 쓴 게 아닌 것의 개수.
 * 한 방에 고정 공지는 하나뿐이지만(내려간 이전 공지도 남아있다) 안 읽은 건 여러 개일 수 있다. */
export async function countUnreadAnnouncementsForUser(roomId, userId, since) {
  const [row] = await db
    .select({ n: sql`count(*)::int` })
    .from(announcements)
    .where(
      and(
        eq(announcements.roomId, roomId),
        isNull(announcements.deletedAt),
        // 탈퇴한 사람의 공지(authorId null)도 세도록 — SQL에서 NULL <> x는 참이 아니다.
        or(isNull(announcements.authorId), ne(announcements.authorId, userId)),
        gt(announcements.createdAt, since),
      ),
    );
  return row?.n ?? 0;
}

export function findAnnouncementById(id) {
  return db
    .select()
    .from(announcements)
    .where(eq(announcements.id, id))
    .then((rows) => rows[0] ?? null);
}

/** 새 공지를 쓰면 그 방의 기존 고정 공지(있다면)는 자동으로 내려가고 새 글이 고정된다 — 한
 * 방에 고정 공지는 동시에 하나뿐이라는 불변식을 트랜잭션으로 지킨다. [autoUnpinAt]은 "공지
 * 자동 내리기"를 골랐을 때만 Date, 아니면 null(기본 — 자동으로 안 내려감). */
export async function insertAnnouncement({
  id,
  roomId,
  authorId,
  authorName,
  text,
  autoUnpinAt = null,
  // "메시지를 공지로 등록"으로 만들 때만 — 출처 메시지 id와 이미지 스냅샷(announcements.js 참고).
  sourceMessageId = null,
  imageUrl = null,
  imageThumbnailUrl = null,
  imageName = null,
}) {
  return db.transaction(async (tx) => {
    await tx
      .update(announcements)
      .set({ pinned: false })
      .where(and(eq(announcements.roomId, roomId), eq(announcements.pinned, true)));
    const [row] = await tx
      .insert(announcements)
      .values({
        id,
        roomId,
        authorId,
        authorName,
        text,
        pinned: true,
        autoUnpinAt,
        sourceMessageId,
        imageUrl,
        imageThumbnailUrl,
        imageName,
      })
      .returning();
    return row;
  });
}

/** announcementAutoUnpin.js의 주기적 스윕용 — 지금 고정돼 있고(pinned) 자동 내리기 시각이
 * 지난 공지 전부. */
export function findAnnouncementsPastAutoUnpin() {
  return db
    .select({ id: announcements.id, roomId: announcements.roomId })
    .from(announcements)
    .where(
      and(
        eq(announcements.pinned, true),
        isNull(announcements.deletedAt),
        lte(announcements.autoUnpinAt, new Date()),
      ),
    );
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

/** 이 메시지를 출처로 한 "지금 고정된" 공지(없으면 null) — 같은 메시지를 공지로 두 번 올리지 않게 막는 데 쓴다. */
export async function findPinnedAnnouncementBySourceMessage(roomId, messageId) {
  const [row] = await db
    .select()
    .from(announcements)
    .where(
      and(
        eq(announcements.roomId, roomId),
        eq(announcements.sourceMessageId, messageId),
        eq(announcements.pinned, true),
        isNull(announcements.deletedAt),
      ),
    )
    .limit(1);
  return row ?? null;
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
