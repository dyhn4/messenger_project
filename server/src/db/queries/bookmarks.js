import { and, asc, eq, isNull, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { bookmarks, users } from '../schema.js';

const withCreator = () =>
  db
    .select({ bookmark: bookmarks, creatorName: users.name })
    .from(bookmarks)
    .leftJoin(users, eq(users.id, bookmarks.creatorId));

const flat = (rows) => rows.map((r) => ({ ...r.bookmark, creatorName: r.creatorName ?? null }));

/** 팀 북마크 — position 순(같으면 만든 순). */
export async function listTeamBookmarks(teamId) {
  return flat(
    await withCreator()
      .where(and(eq(bookmarks.teamId, teamId), eq(bookmarks.kind, 'team')))
      .orderBy(asc(bookmarks.position), asc(bookmarks.createdAt)),
  );
}

/** 내 개인 북마크(그 팀 안에서). */
export async function listPersonalBookmarks(teamId, ownerId) {
  return flat(
    await withCreator()
      .where(and(eq(bookmarks.teamId, teamId), eq(bookmarks.kind, 'personal'), eq(bookmarks.ownerId, ownerId)))
      .orderBy(asc(bookmarks.position), asc(bookmarks.createdAt)),
  );
}

export async function findBookmarkById(id) {
  const [row] = await withCreator().where(eq(bookmarks.id, id));
  return row ? { ...row.bookmark, creatorName: row.creatorName ?? null } : null;
}

function scopeOf(teamId, kind, ownerId) {
  return and(
    eq(bookmarks.teamId, teamId),
    eq(bookmarks.kind, kind),
    kind === 'personal' ? eq(bookmarks.ownerId, ownerId) : isNull(bookmarks.ownerId),
  );
}

export async function countBookmarks(teamId, kind, ownerId) {
  const [row] = await db
    .select({ count: sql`count(*)`.mapWith(Number) })
    .from(bookmarks)
    .where(scopeOf(teamId, kind, ownerId));
  return row?.count ?? 0;
}

/** 맨 끝 position으로 넣는다(같은 종류 안의 가장 큰 값 + 1). */
export async function insertBookmark({ teamId, kind, ownerId, creatorId, title, url, imageUrl }) {
  const [last] = await db
    .select({ max: sql`max(${bookmarks.position})`.mapWith(Number) })
    .from(bookmarks)
    .where(scopeOf(teamId, kind, ownerId));
  const [row] = await db
    .insert(bookmarks)
    .values({
      teamId,
      kind,
      ownerId: kind === 'personal' ? ownerId : null,
      creatorId,
      title,
      url,
      imageUrl: imageUrl ?? null,
      position: (last?.max ?? -1) + 1,
    })
    .returning();
  return row;
}

export async function updateBookmark(id, fields) {
  const [row] = await db
    .update(bookmarks)
    .set({ ...fields, updatedAt: new Date() })
    .where(eq(bookmarks.id, id))
    .returning();
  return row ?? null;
}

export async function deleteBookmark(id) {
  const [row] = await db.delete(bookmarks).where(eq(bookmarks.id, id)).returning();
  return row ?? null;
}

/** [ids] 순서대로 position을 0부터 다시 매긴다(한 트랜잭션). */
export async function reorderBookmarks(ids) {
  await db.transaction(async (tx) => {
    for (const [i, id] of ids.entries()) {
      await tx.update(bookmarks).set({ position: i, updatedAt: new Date() }).where(eq(bookmarks.id, id));
    }
  });
}
