import { and, desc, eq, gt, isNull, lt, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { teamInviteLinks, teams } from '../schema.js';

export async function insertTeamInviteLink(fields) {
  const [row] = await db.insert(teamInviteLinks).values(fields).returning();
  return row;
}

/** 링크 자체 + 초대 대상 팀 이름을 같이 준다(랜딩 페이지/목록 화면 둘 다 팀 이름이 필요). */
export function findTeamInviteLinkByToken(token) {
  return db
    .select({ link: teamInviteLinks, teamName: teams.name })
    .from(teamInviteLinks)
    .innerJoin(teams, eq(teams.id, teamInviteLinks.teamId))
    .where(eq(teamInviteLinks.token, token))
    .then((rows) => (rows[0] ? { ...rows[0].link, teamName: rows[0].teamName } : null));
}

export function findTeamInviteLinkById(id) {
  return db
    .select({ link: teamInviteLinks, teamName: teams.name })
    .from(teamInviteLinks)
    .innerJoin(teams, eq(teams.id, teamInviteLinks.teamId))
    .where(eq(teamInviteLinks.id, id))
    .then((rows) => (rows[0] ? { ...rows[0].link, teamName: rows[0].teamName } : null));
}

/** 만든 사람 기준 목록(최신순) — "팀 초대 링크" 관리 화면이 "내가 만든 링크"만 보여줄 때 쓴다. */
export function listTeamInviteLinksByCreator(userId) {
  return db
    .select({ link: teamInviteLinks, teamName: teams.name })
    .from(teamInviteLinks)
    .innerJoin(teams, eq(teams.id, teamInviteLinks.teamId))
    .where(eq(teamInviteLinks.createdBy, userId))
    .orderBy(desc(teamInviteLinks.createdAt))
    .then((rows) => rows.map((r) => ({ ...r.link, teamName: r.teamName })));
}

export async function revokeTeamInviteLink(id) {
  const [row] = await db
    .update(teamInviteLinks)
    .set({ revokedAt: new Date() })
    .where(eq(teamInviteLinks.id, id))
    .returning();
  return row;
}

/**
 * 가입 한 건에 링크 한 자리를 쓴다 — 아직 유효하고(폐기·만료 안 됨) 자리가 남았을 때만, 확인과 차감을 한
 * 문장으로 해서 동시에 여러 명이 가입해도 정한 인원을 넘지 않는다. 썼으면 true, 못 썼으면(다 참 등) false.
 */
export async function consumeTeamInviteLink(id) {
  const rows = await db
    .update(teamInviteLinks)
    .set({ usedCount: sql`${teamInviteLinks.usedCount} + 1`, lastUsedAt: new Date() })
    .where(
      and(
        eq(teamInviteLinks.id, id),
        isNull(teamInviteLinks.revokedAt),
        gt(teamInviteLinks.expiresAt, new Date()),
        or(isNull(teamInviteLinks.maxUses), lt(teamInviteLinks.usedCount, teamInviteLinks.maxUses)),
      ),
    )
    .returning({ id: teamInviteLinks.id });
  return rows.length > 0;
}

/** 지금 유효한(만료·폐기 안 됐고 가입 인원이 남은) 링크인지. */
export function isTeamInviteLinkValid(link) {
  if (!link) return false;
  if (link.revokedAt) return false;
  if (link.maxUses != null && link.usedCount >= link.maxUses) return false;
  return new Date(link.expiresAt).getTime() > Date.now();
}
