import { and, count, desc, eq, gte, lte } from 'drizzle-orm';
import { db } from '../client.js';
import { auditLogs } from '../schema.js';

/** 감사 로그 한 줄 추가(추가 전용 — 수정/삭제 API는 만들지 않는다). */
export async function insertAuditLog(fields) {
  const [row] = await db.insert(auditLogs).values(fields).returning();
  return row;
}

/**
 * 감사 로그 조회(최신순). action/actorId/teamId/기간으로 좁힐 수 있고, limit+offset으로
 * 페이지를 넘긴다. 총 개수도 같이 돌려줘서 화면이 "몇 건 중 몇 건"을 보여줄 수 있게 한다.
 */
export async function listAuditLogs({ action, actorId, teamId, since, until, limit = 50, offset = 0 } = {}) {
  const conditions = [];
  if (action) conditions.push(eq(auditLogs.action, action));
  if (actorId) conditions.push(eq(auditLogs.actorId, actorId));
  if (teamId) conditions.push(eq(auditLogs.teamId, teamId));
  if (since) conditions.push(gte(auditLogs.createdAt, since));
  if (until) conditions.push(lte(auditLogs.createdAt, until));
  const where = conditions.length > 0 ? and(...conditions) : undefined;

  const rows = await db
    .select()
    .from(auditLogs)
    .where(where)
    .orderBy(desc(auditLogs.createdAt))
    .limit(limit)
    .offset(offset);
  const [total] = await db.select({ value: count() }).from(auditLogs).where(where);
  return { rows, total: total?.value ?? 0 };
}
