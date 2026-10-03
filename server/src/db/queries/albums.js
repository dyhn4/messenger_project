import { and, count, desc, eq, gte, inArray, isNull, lt, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { albumItems, albums, dmHistoryFloors, roomMembers, rooms, users } from '../schema.js';

// 앨범 조회·저장. 대화방 파일(message_attachments)과는 독립이라 항목은 album_items에만 있다.

export async function insertAlbum(fields) {
  const [row] = await db.insert(albums).values(fields).returning();
  return row;
}

export function findAlbumById(id) {
  return db
    .select()
    .from(albums)
    .where(eq(albums.id, id))
    .then((rows) => rows[0] ?? null);
}

export async function updateAlbum(id, fields) {
  const [row] = await db
    .update(albums)
    .set({ ...fields, updatedAt: new Date() })
    .where(eq(albums.id, id))
    .returning();
  return row ?? null;
}

/** 앨범 삭제 — 항목은 FK cascade로 같이 지워진다(업로드 파일 자체는 공유된 메시지가 참조할 수 있어 남겨 둔다). */
export async function deleteAlbum(id) {
  await db.delete(albums).where(eq(albums.id, id));
}

/**
 * 내가 멤버인 방의 앨범 목록(최신순, [before] 이전 것만 [limit]건). 비밀 대화는 뺀다. DM "진짜 나가기"를 한
 * 적이 있으면 그 시각 이전에 만든 앨범은 안 보인다(다른 조회와 같은 하한). [roomId]를 주면 그 방만.
 */
export function listAlbumsForUser({ userId, teamId, roomId, before, limit }) {
  const conditions = [eq(albums.teamId, teamId), eq(rooms.isSecret, false)];
  if (roomId) conditions.push(eq(albums.roomId, roomId));
  if (before) conditions.push(lt(albums.createdAt, before));
  conditions.push(or(isNull(dmHistoryFloors.hiddenBeforeAt), gte(albums.createdAt, dmHistoryFloors.hiddenBeforeAt)));
  return db
    .select({ album: albums, room: rooms })
    .from(albums)
    .innerJoin(rooms, eq(rooms.id, albums.roomId))
    .innerJoin(roomMembers, and(eq(roomMembers.roomId, rooms.id), eq(roomMembers.userId, userId)))
    .leftJoin(dmHistoryFloors, and(eq(dmHistoryFloors.roomId, rooms.id), eq(dmHistoryFloors.userId, userId)))
    .where(and(...conditions))
    .orderBy(desc(albums.createdAt), desc(albums.id))
    .limit(limit);
}

/** 앨범마다 항목 수 — `Map<albumId, number>`(항목이 없으면 0). */
export async function countItemsByAlbum(albumIds) {
  const result = new Map(albumIds.map((id) => [id, 0]));
  if (albumIds.length === 0) return result;
  const rows = await db
    .select({ albumId: albumItems.albumId, n: count() })
    .from(albumItems)
    .where(inArray(albumItems.albumId, albumIds))
    .groupBy(albumItems.albumId);
  for (const r of rows) result.set(r.albumId, Number(r.n));
  return result;
}

/**
 * 앨범마다 대표 항목 — 지정한 대표(coverItemId)가 아직 있으면 그것, 아니면 대표가 될 수 있는 첫 항목(가장 최근 것).
 * [canBeCover]가 이미지이거나 썸네일 있는 영상만 보는 이유는 썸네일 없는 영상을 대표로 삼으면 빈 칸이 되기 때문.
 * `Map<albumId, itemRow>`.
 */
export async function findCoverItems(albumRows) {
  const result = new Map();
  if (albumRows.length === 0) return result;
  const albumIds = albumRows.map((a) => a.id);
  const coverIds = albumRows.map((a) => a.coverItemId).filter(Boolean);
  if (coverIds.length > 0) {
    const explicit = await db
      .select()
      .from(albumItems)
      .where(and(inArray(albumItems.id, coverIds), inArray(albumItems.albumId, albumIds)));
    const byId = new Map(explicit.map((i) => [i.id, i]));
    for (const a of albumRows) {
      const item = a.coverItemId ? byId.get(a.coverItemId) : null;
      if (item && item.albumId === a.id) result.set(a.id, item);
    }
  }
  const missing = albumIds.filter((id) => !result.has(id));
  if (missing.length > 0) {
    const firsts = await db
      .selectDistinctOn([albumItems.albumId])
      .from(albumItems)
      .where(
        and(
          inArray(albumItems.albumId, missing),
          or(eq(albumItems.kind, 'image'), sql`${albumItems.thumbnailUrl} is not null`),
        ),
      )
      .orderBy(albumItems.albumId, desc(albumItems.createdAt));
    for (const item of firsts) result.set(item.albumId, item);
  }
  return result;
}

export async function countAlbumItems(albumId) {
  const [row] = await db.select({ n: count() }).from(albumItems).where(eq(albumItems.albumId, albumId));
  return Number(row?.n ?? 0);
}

/** 앨범 항목(최신순) — [before] 이전 것만 [limit]건. 올린 사람 이름을 같이 준다. */
export function listAlbumItems(albumId, { before, limit }) {
  const conditions = [eq(albumItems.albumId, albumId)];
  if (before) conditions.push(lt(albumItems.createdAt, before));
  return db
    .select({ item: albumItems, uploaderName: users.name, uploaderUsername: users.username })
    .from(albumItems)
    .leftJoin(users, eq(users.id, albumItems.uploaderId))
    .where(and(...conditions))
    .orderBy(desc(albumItems.createdAt), desc(albumItems.id))
    .limit(limit);
}

/** 이 앨범에 속한 항목들(id 목록) — 다른 앨범의 항목 id가 섞여 있으면 그만큼 빠진다. */
export function findItemsByIds(albumId, itemIds) {
  if (itemIds.length === 0) return Promise.resolve([]);
  return db
    .select()
    .from(albumItems)
    .where(and(eq(albumItems.albumId, albumId), inArray(albumItems.id, itemIds)));
}

/**
 * 항목을 한 번에 넣는다(한 트랜잭션). 보여 주는 순서가 "최신순"이라서, 한 번에 올린 묶음 안의 순서(고른 순서)가
 * 그대로 보이도록 앞 항목일수록 1ms 더 최근 시각을 준다. 앨범의 updatedAt도 함께 갱신한다.
 */
export function insertAlbumItems(albumId, uploaderId, items) {
  return db.transaction(async (tx) => {
    const base = Date.now();
    const rows = await tx
      .insert(albumItems)
      .values(items.map((item, i) => ({ ...item, albumId, uploaderId, createdAt: new Date(base + (items.length - 1 - i)) })))
      .returning();
    await tx.update(albums).set({ updatedAt: new Date() }).where(eq(albums.id, albumId));
    return rows;
  });
}

/** 항목 삭제 — 지운 행들을 돌려준다. 지운 항목이 대표였으면 coverItemId도 비운다(첫 항목으로 대신 보인다). */
export function deleteAlbumItems(albumId, itemIds) {
  return db.transaction(async (tx) => {
    const rows = await tx
      .delete(albumItems)
      .where(and(eq(albumItems.albumId, albumId), inArray(albumItems.id, itemIds)))
      .returning();
    if (rows.length > 0) {
      await tx.update(albums).set({ updatedAt: new Date() }).where(eq(albums.id, albumId));
      await tx
        .update(albums)
        .set({ coverItemId: null })
        .where(and(eq(albums.id, albumId), inArray(albums.coverItemId, itemIds)));
    }
    return rows;
  });
}
