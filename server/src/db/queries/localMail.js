import { and, asc, desc, eq, ilike, inArray, isNotNull, lt, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { localMailFolders, localMailMessages } from '../schema.js';

/** 회사 메일함(자체 메일 서버)의 메일 표 — 원문 파일은 localMailStore.js가 다룬다. */

export async function insertLocalMessage(values) {
  const [row] = await db.insert(localMailMessages).values(values).returning();
  return row;
}

/** 폴더마다 메일 수·안 읽은 수 `{ 폴더: { total, unseen } }`. */
export async function localFolderCounts(accountId) {
  const rows = await db
    .select({
      folder: localMailMessages.folder,
      total: sql`count(*)::int`,
      unseen: sql`count(*) filter (where not ${localMailMessages.seen})::int`,
    })
    .from(localMailMessages)
    .where(eq(localMailMessages.accountId, accountId))
    .groupBy(localMailMessages.folder);
  return Object.fromEntries(rows.map((r) => [r.folder, { total: r.total, unseen: r.unseen }]));
}

/** 목록 — 새것부터 [limit]+1통([before] uid보다 앞의 것). [q]는 찾기용 글(searchText)에 든 것. */
export function listLocalMessages(accountId, folder, { before = null, limit = 30, q = null }) {
  const where = [eq(localMailMessages.accountId, accountId), eq(localMailMessages.folder, folder)];
  if (before) where.push(lt(localMailMessages.uid, before));
  if (q) where.push(ilike(localMailMessages.searchText, `%${q.replace(/[\\%_]/g, (c) => `\\${c}`)}%`));
  return db
    .select()
    .from(localMailMessages)
    .where(and(...where))
    .orderBy(desc(localMailMessages.uid))
    .limit(limit + 1);
}

export async function findLocalMessage(accountId, folder, uid) {
  const [row] = await db
    .select()
    .from(localMailMessages)
    .where(and(eq(localMailMessages.accountId, accountId), eq(localMailMessages.folder, folder), eq(localMailMessages.uid, uid)));
  return row ?? null;
}

export function listLocalMessagesByUid(accountId, folder, uids) {
  return db
    .select()
    .from(localMailMessages)
    .where(and(eq(localMailMessages.accountId, accountId), eq(localMailMessages.folder, folder), inArray(localMailMessages.uid, uids)));
}

export function updateLocalMessages(accountId, folder, uids, patch) {
  return db
    .update(localMailMessages)
    .set(patch)
    .where(and(eq(localMailMessages.accountId, accountId), eq(localMailMessages.folder, folder), inArray(localMailMessages.uid, uids)))
    .returning({ uid: localMailMessages.uid });
}

/** 지운 줄들(파일 이름 — 부르는 쪽이 파일을 지운다). */
export function deleteLocalMessages(accountId, folder, uids) {
  return db
    .delete(localMailMessages)
    .where(and(eq(localMailMessages.accountId, accountId), eq(localMailMessages.folder, folder), inArray(localMailMessages.uid, uids)))
    .returning({ uid: localMailMessages.uid, fileName: localMailMessages.fileName });
}

/** 이 계정 메일함이 쓰는 크기(바이트). */
export async function localQuotaUsed(accountId) {
  const [row] = await db
    .select({ used: sql`coalesce(sum(${localMailMessages.size}), 0)::bigint` })
    .from(localMailMessages)
    .where(eq(localMailMessages.accountId, accountId));
  return Number(row?.used ?? 0);
}

/** 최근 [limit]통(받는 규칙을 지금 걸기). */
export function recentLocalMessages(accountId, folder, limit) {
  return db
    .select()
    .from(localMailMessages)
    .where(and(eq(localMailMessages.accountId, accountId), eq(localMailMessages.folder, folder)))
    .orderBy(desc(localMailMessages.uid))
    .limit(limit);
}

/** 받은편지함 안 읽은 수. */
export async function localInboxUnseen(accountId) {
  const [row] = await db
    .select({ n: sql`count(*)::int` })
    .from(localMailMessages)
    .where(and(eq(localMailMessages.accountId, accountId), eq(localMailMessages.folder, 'INBOX'), eq(localMailMessages.seen, false)));
  return row?.n ?? 0;
}

/** 휴지통에 [before]보다 먼저 들어간 메일(아주 지울 것) — 계정·uid·파일 이름. */
export function listExpiredTrash(before, limit = 500) {
  return db
    .select({ accountId: localMailMessages.accountId, uid: localMailMessages.uid, fileName: localMailMessages.fileName })
    .from(localMailMessages)
    .where(and(eq(localMailMessages.folder, 'Trash'), isNotNull(localMailMessages.trashedAt), lt(localMailMessages.trashedAt, before)))
    .limit(limit);
}

// ── 사람이 만든 폴더 ──

/** 이 계정에 사람이 만든 폴더 이름들(만든 차례). */
export async function listLocalFolders(accountId) {
  const rows = await db
    .select({ name: localMailFolders.name })
    .from(localMailFolders)
    .where(eq(localMailFolders.accountId, accountId))
    .orderBy(asc(localMailFolders.createdAt));
  return rows.map((r) => r.name);
}

/** 폴더 만들기 — 대소문자만 다른 이름이 이미 있으면 false(고유 색인). */
export async function insertLocalFolder(accountId, name) {
  const rows = await db.insert(localMailFolders).values({ accountId, name }).onConflictDoNothing().returning({ id: localMailFolders.id });
  return rows.length > 0;
}

/** 폴더 이름 바꾸기 — 폴더 행과 그 폴더의 메일을 한 번에. 그 폴더가 없으면 false. */
export async function renameLocalFolder(accountId, from, to) {
  return db.transaction(async (tx) => {
    const rows = await tx
      .update(localMailFolders)
      .set({ name: to })
      .where(and(eq(localMailFolders.accountId, accountId), eq(localMailFolders.name, from)))
      .returning({ id: localMailFolders.id });
    if (rows.length === 0) return false;
    await tx
      .update(localMailMessages)
      .set({ folder: to })
      .where(and(eq(localMailMessages.accountId, accountId), eq(localMailMessages.folder, from)));
    return true;
  });
}

/** 폴더 지우기(비어 있는지는 부르는 쪽이 본다). 지웠으면 true. */
export async function deleteLocalFolder(accountId, name) {
  const rows = await db
    .delete(localMailFolders)
    .where(and(eq(localMailFolders.accountId, accountId), eq(localMailFolders.name, name)))
    .returning({ id: localMailFolders.id });
  return rows.length > 0;
}

/** [folder]의 메일 수. */
export async function localFolderMessageCount(accountId, folder) {
  const [row] = await db
    .select({ n: sql`count(*)::int` })
    .from(localMailMessages)
    .where(and(eq(localMailMessages.accountId, accountId), eq(localMailMessages.folder, folder)));
  return row?.n ?? 0;
}
