import { and, desc, eq, gt, isNull, lt, or, sql } from 'drizzle-orm';
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

/**
 * 가입 한 건에 링크 한 자리를 쓴다 — 아직 유효하고(폐기·만료 안 됨) 자리가 남았을 때만, 확인과 차감을 한
 * 문장으로 해서 동시에 여러 명이 가입해도 정한 인원을 넘지 않는다. 썼으면 true, 못 썼으면(다 참 등) false.
 * 사용 횟수(used_count)는 이렇게 가입한 사람만 센다 — 예전엔 페어링(인증서 받기)할 때마다 올라서, 같은 사람이
 * 다시 연결해도 늘고 가입 인원으로는 쓸 수 없었다(pairing.js는 이제 링크를 건드리지 않는다).
 */
export async function consumeInviteLink(id) {
  const rows = await db
    .update(inviteLinks)
    .set({ usedCount: sql`${inviteLinks.usedCount} + 1`, lastUsedAt: new Date() })
    .where(
      and(
        eq(inviteLinks.id, id),
        isNull(inviteLinks.revokedAt),
        gt(inviteLinks.expiresAt, new Date()),
        or(isNull(inviteLinks.maxUses), lt(inviteLinks.usedCount, inviteLinks.maxUses)),
      ),
    )
    .returning({ id: inviteLinks.id });
  return rows.length > 0;
}

/**
 * 아직 열려 있는(취소·만료되지 않은) 링크인지 — 가입 인원은 보지 않는다. 인원이 다 찬 링크도 이미 가입한 사람이 다른 기기를
 * 연결하거나 앱을 다시 설치할 때는 계속 쓰이기 때문이다(invites.js의 inviteLinkConnectable). 팀 초대 링크도 같은 칸
 * (revokedAt·expiresAt)이라 같이 쓴다(teamInvites.js).
 */
export function isInviteLinkOpen(link) {
  if (!link || link.revokedAt) return false;
  return new Date(link.expiresAt).getTime() > Date.now();
}

/**
 * 가입할 자리가 남았는지. 인원 제한이 없는(maxUses null) 건 그 칸이 생기기 전에 만든 링크뿐이다. 팀 초대 링크도 같은 칸
 * (maxUses·usedCount)이라 같이 쓴다(pairing.js의 안내 페이지).
 */
export function inviteLinkHasSeat(link) {
  return link.maxUses == null || link.usedCount < link.maxUses;
}

/** 지금 이 링크로 가입할 수 있는지 — 열려 있고(isInviteLinkOpen) 가입 인원이 남았을 때. */
export function isInviteLinkValid(link) {
  return isInviteLinkOpen(link) && inviteLinkHasSeat(link);
}
