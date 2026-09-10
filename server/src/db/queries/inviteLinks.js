import { desc, eq, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { inviteLinks } from '../schema.js';

export async function insertInviteLink(fields) {
  const [row] = await db.insert(inviteLinks).values(fields).returning();
  return row;
}

export function findInviteLinkByToken(token) {
  return db
    .select()
    .from(inviteLinks)
    .where(eq(inviteLinks.token, token))
    .then((rows) => rows[0] ?? null);
}

export function findInviteLinkById(id) {
  return db
    .select()
    .from(inviteLinks)
    .where(eq(inviteLinks.id, id))
    .then((rows) => rows[0] ?? null);
}

/** 만든 사람 기준 목록(최신순) — 초대 링크 관리 화면이 "내가 만든 링크"만 보여줄 때 쓴다. */
export function listInviteLinksByCreator(userId) {
  return db.select().from(inviteLinks).where(eq(inviteLinks.createdBy, userId)).orderBy(desc(inviteLinks.createdAt));
}

export async function revokeInviteLink(id) {
  const [row] = await db.update(inviteLinks).set({ revokedAt: new Date() }).where(eq(inviteLinks.id, id)).returning();
  return row;
}

/** 초대 페이지/페어링에서 쓸 때마다 사용 횟수와 마지막 사용 시각을 갱신한다(1회용이 아니다). */
export async function markInviteLinkUsed(id) {
  await db
    .update(inviteLinks)
    .set({ usedCount: sql`${inviteLinks.usedCount} + 1`, lastUsedAt: new Date() })
    .where(eq(inviteLinks.id, id));
}

/** 지금 유효한(만료·폐기 안 된) 링크인지. */
export function isInviteLinkValid(link) {
  if (!link) return false;
  if (link.revokedAt) return false;
  return new Date(link.expiresAt).getTime() > Date.now();
}
