import { and, desc, eq, ilike, isNull, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { wikiPageVersions, wikiPages } from '../schema.js';

/** 팀의 페이지 전부(휴지통 포함, 본문 빼고) — 나무·휴지통·옮기기를 메모리에서 판단하려고. */
export async function loadPageMap(teamId) {
  const rows = await db
    .select({
      id: wikiPages.id,
      teamId: wikiPages.teamId,
      parentId: wikiPages.parentId,
      title: wikiPages.title,
      position: wikiPages.position,
      createdBy: wikiPages.createdBy,
      createdAt: wikiPages.createdAt,
      updatedAt: wikiPages.updatedAt,
      updatedByName: wikiPages.updatedByName,
      deletedAt: wikiPages.deletedAt,
    })
    .from(wikiPages)
    .where(eq(wikiPages.teamId, teamId));
  return new Map(rows.map((p) => [p.id, p]));
}

export async function findPage(id) {
  const [row] = await db.select().from(wikiPages).where(eq(wikiPages.id, id));
  return row ?? null;
}

export async function insertPage(values) {
  const [row] = await db.insert(wikiPages).values(values).returning();
  return row;
}

export async function updatePage(id, fields) {
  const [row] = await db.update(wikiPages).set(fields).where(eq(wikiPages.id, id)).returning();
  return row ?? null;
}

/** 같은 위 페이지 아래 맨 뒤 순서. */
export async function nextPosition(teamId, parentId) {
  const [row] = await db
    .select({ n: sql`coalesce(max(${wikiPages.position}), -1) + 1` })
    .from(wikiPages)
    .where(and(eq(wikiPages.teamId, teamId), parentId ? eq(wikiPages.parentId, parentId) : isNull(wikiPages.parentId)));
  return Number(row?.n ?? 0);
}

/** 본문 저장(동시 편집 문서 — wikiDocs.js). [revision]이 지금 것보다 클 때만(늦게 끝난 저장이 새 값을 덮지 않게). */
export async function savePageBody(id, { body, revision, updatedByName }) {
  await db
    .update(wikiPages)
    .set({ body, revision, updatedAt: new Date(), ...(updatedByName ? { updatedByName } : {}) })
    .where(and(eq(wikiPages.id, id), sql`${wikiPages.revision} < ${revision}`));
}

export async function insertVersion(values) {
  const [row] = await db.insert(wikiPageVersions).values(values).returning();
  return row;
}

export async function latestVersion(pageId) {
  const [row] = await db
    .select()
    .from(wikiPageVersions)
    .where(eq(wikiPageVersions.pageId, pageId))
    .orderBy(desc(wikiPageVersions.createdAt))
    .limit(1);
  return row ?? null;
}

/** 판 목록(최근 것부터 100개, 본문 빼고). */
export function listVersions(pageId) {
  return db
    .select({
      id: wikiPageVersions.id,
      revision: wikiPageVersions.revision,
      title: wikiPageVersions.title,
      editorNames: wikiPageVersions.editorNames,
      createdAt: wikiPageVersions.createdAt,
      size: sql`length(${wikiPageVersions.body})::int`,
    })
    .from(wikiPageVersions)
    .where(eq(wikiPageVersions.pageId, pageId))
    .orderBy(desc(wikiPageVersions.createdAt))
    .limit(100);
}

export async function findVersion(id) {
  const [row] = await db.select().from(wikiPageVersions).where(eq(wikiPageVersions.id, id));
  return row ?? null;
}

/** 제목·본문으로 찾기(휴지통 아닌 것, 50개) — 휴지통 아래 페이지는 부른 쪽이 거른다. */
export function searchPages(teamId, query) {
  const pattern = `%${query.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
  return db
    .select({
      id: wikiPages.id,
      parentId: wikiPages.parentId,
      title: wikiPages.title,
      body: wikiPages.body,
      updatedAt: wikiPages.updatedAt,
    })
    .from(wikiPages)
    .where(
      and(
        eq(wikiPages.teamId, teamId),
        isNull(wikiPages.deletedAt),
        or(ilike(wikiPages.title, pattern), ilike(wikiPages.body, pattern)),
      ),
    )
    .orderBy(desc(wikiPages.updatedAt))
    .limit(50);
}
