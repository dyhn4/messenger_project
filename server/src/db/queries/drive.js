import { and, asc, desc, eq, ilike, inArray, isNotNull, isNull, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { driveFileVersions, driveFiles, driveFolders } from '../schema.js';
import { DRIVE_VERSIONS_MAX } from '../../driveRules.js';

/** 팀의 폴더 전부(휴지통 포함) — 경로·휴지통·옮기기 판단을 메모리에서 하려고(팀 하나의 폴더 수는 많지 않다). */
export async function loadFolderMap(teamId) {
  const rows = await db.select().from(driveFolders).where(eq(driveFolders.teamId, teamId));
  return new Map(rows.map((f) => [f.id, f]));
}

export async function findFolder(id) {
  const [row] = await db.select().from(driveFolders).where(eq(driveFolders.id, id));
  return row ?? null;
}

export async function findFile(id) {
  const [row] = await db.select().from(driveFiles).where(eq(driveFiles.id, id));
  return row ?? null;
}

/** 한 폴더(null = 맨 위)의 휴지통 아닌 파일들. */
export function listFolderFiles(teamId, folderId) {
  return db
    .select()
    .from(driveFiles)
    .where(
      and(
        eq(driveFiles.teamId, teamId),
        folderId ? eq(driveFiles.folderId, folderId) : isNull(driveFiles.folderId),
        isNull(driveFiles.deletedAt),
      ),
    )
    .orderBy(asc(driveFiles.name));
}

/** 같은 폴더의 이름들 [{ id, name }] — 휴지통 아닌 폴더·파일(이름 겹침 검사). */
export async function siblingNames(teamId, folderId, folders = null) {
  const map = folders ?? (await loadFolderMap(teamId));
  const subFolders = [...map.values()]
    .filter((f) => (f.parentId ?? null) === (folderId ?? null) && !f.deletedAt)
    .map((f) => ({ id: f.id, name: f.name }));
  const files = await db
    .select({ id: driveFiles.id, name: driveFiles.name })
    .from(driveFiles)
    .where(
      and(
        eq(driveFiles.teamId, teamId),
        folderId ? eq(driveFiles.folderId, folderId) : isNull(driveFiles.folderId),
        isNull(driveFiles.deletedAt),
      ),
    );
  return [...subFolders, ...files];
}

export async function insertFolder(values) {
  const [row] = await db.insert(driveFolders).values(values).returning();
  return row;
}

export async function updateFolder(id, fields) {
  const [row] = await db
    .update(driveFolders)
    .set({ ...fields, updatedAt: new Date() })
    .where(eq(driveFolders.id, id))
    .returning();
  return row ?? null;
}

export async function deleteFoldersPermanently(ids) {
  if (ids.length === 0) return;
  await db.delete(driveFolders).where(inArray(driveFolders.id, ids));
}

/** 새 파일과 첫 판. */
export async function insertFileWithVersion(file, version) {
  return db.transaction(async (tx) => {
    const [row] = await tx
      .insert(driveFiles)
      .values({ ...file, version: 1 })
      .returning();
    await tx.insert(driveFileVersions).values({ ...version, fileId: row.id, version: 1 });
    return row;
  });
}

/**
 * 새 판 — 파일 행의 판 번호를 하나 올리고(동시에 올려도 번호가 겹치지 않게 행을 잠근 채) 판 기록을 남긴다. 판이
 * [DRIVE_VERSIONS_MAX]개를 넘으면 가장 오래된 기록부터 지운다. 바뀐 파일 행.
 */
export async function addFileVersion(fileId, version, { updatedByName }) {
  return db.transaction(async (tx) => {
    const [row] = await tx
      .update(driveFiles)
      .set({
        version: sql`${driveFiles.version} + 1`,
        filePath: version.filePath,
        size: version.size,
        mimeType: version.mimeType,
        updatedAt: new Date(),
        updatedByName,
      })
      .where(eq(driveFiles.id, fileId))
      .returning();
    if (!row) return null;
    await tx.insert(driveFileVersions).values({ ...version, fileId, version: row.version });
    const old = await tx
      .select({ id: driveFileVersions.id })
      .from(driveFileVersions)
      .where(eq(driveFileVersions.fileId, fileId))
      .orderBy(desc(driveFileVersions.version))
      .offset(DRIVE_VERSIONS_MAX);
    if (old.length > 0) await tx.delete(driveFileVersions).where(inArray(driveFileVersions.id, old.map((o) => o.id)));
    return row;
  });
}

export async function updateFile(id, fields) {
  const [row] = await db
    .update(driveFiles)
    .set({ ...fields, updatedAt: new Date() })
    .where(eq(driveFiles.id, id))
    .returning();
  return row ?? null;
}

export async function deleteFilePermanently(id) {
  await db.delete(driveFiles).where(eq(driveFiles.id, id));
}

export function listVersions(fileId) {
  return db
    .select()
    .from(driveFileVersions)
    .where(eq(driveFileVersions.fileId, fileId))
    .orderBy(desc(driveFileVersions.version));
}

export async function findVersion(fileId, version) {
  const [row] = await db
    .select()
    .from(driveFileVersions)
    .where(and(eq(driveFileVersions.fileId, fileId), eq(driveFileVersions.version, version)));
  return row ?? null;
}

/** 휴지통 — 직접 휴지통에 넣은 파일들(폴더는 loadFolderMap에서 거른다). */
export function listTrashedFiles(teamId) {
  return db
    .select()
    .from(driveFiles)
    .where(and(eq(driveFiles.teamId, teamId), isNotNull(driveFiles.deletedAt)))
    .orderBy(desc(driveFiles.deletedAt))
    .limit(500);
}

/** 이름 찾기 — 휴지통 아닌 파일(100개까지). 폴더는 loadFolderMap에서 거른다. */
export function searchFiles(teamId, query) {
  const pattern = `%${query.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
  return db
    .select()
    .from(driveFiles)
    .where(and(eq(driveFiles.teamId, teamId), isNull(driveFiles.deletedAt), ilike(driveFiles.name, pattern)))
    .orderBy(desc(driveFiles.updatedAt), desc(driveFiles.createdAt))
    .limit(100);
}

/** 팀 드라이브가 쓰는 양(판 기록 전부의 크기 합, 바이트). */
export async function driveUsage(teamId) {
  const [row] = await db
    .select({ bytes: sql`coalesce(sum(${driveFileVersions.size}), 0)::bigint` })
    .from(driveFileVersions)
    .innerJoin(driveFiles, eq(driveFiles.id, driveFileVersions.fileId))
    .where(eq(driveFiles.teamId, teamId));
  return Number(row?.bytes ?? 0);
}

/** 폴더들 [folderIds] 안의 파일(휴지통 포함) — 폴더를 영구 삭제하기 전 세려고. */
export async function countFilesInFolders(folderIds) {
  if (folderIds.length === 0) return 0;
  const [row] = await db
    .select({ n: sql`count(*)::int` })
    .from(driveFiles)
    .where(inArray(driveFiles.folderId, folderIds));
  return row?.n ?? 0;
}
