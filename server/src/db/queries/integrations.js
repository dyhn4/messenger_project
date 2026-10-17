import { and, asc, count, eq, gt, isNull, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { apiTokens, integrations } from '../schema.js';

// ── 외부 연동(웹훅·슬래시 명령) ─────────────────────────────────────────────

export async function insertIntegration(fields) {
  const [row] = await db.insert(integrations).values(fields).returning();
  return row;
}

export async function findIntegrationById(id) {
  const [row] = await db.select().from(integrations).where(eq(integrations.id, id)).limit(1);
  return row ?? null;
}

export async function findWebhookByTokenHash(tokenHash) {
  const [row] = await db
    .select()
    .from(integrations)
    .where(and(eq(integrations.tokenHash, tokenHash), eq(integrations.kind, 'webhook')))
    .limit(1);
  return row ?? null;
}

export function listRoomWebhooks(roomId) {
  return db
    .select()
    .from(integrations)
    .where(and(eq(integrations.roomId, roomId), eq(integrations.kind, 'webhook')))
    .orderBy(asc(integrations.createdAt));
}

export function listTeamCommands(teamId) {
  return db
    .select()
    .from(integrations)
    .where(and(eq(integrations.teamId, teamId), eq(integrations.kind, 'command')))
    .orderBy(asc(integrations.command));
}

export async function findTeamCommand(teamId, command) {
  const [row] = await db
    .select()
    .from(integrations)
    .where(and(eq(integrations.teamId, teamId), eq(integrations.kind, 'command'), eq(integrations.command, command)))
    .limit(1);
  return row ?? null;
}

export async function countRoomWebhooks(roomId) {
  const [row] = await db
    .select({ n: count() })
    .from(integrations)
    .where(and(eq(integrations.roomId, roomId), eq(integrations.kind, 'webhook')));
  return row?.n ?? 0;
}

export async function countTeamCommands(teamId) {
  const [row] = await db
    .select({ n: count() })
    .from(integrations)
    .where(and(eq(integrations.teamId, teamId), eq(integrations.kind, 'command')));
  return row?.n ?? 0;
}

export async function updateIntegration(id, patch) {
  const [row] = await db.update(integrations).set(patch).where(eq(integrations.id, id)).returning();
  return row ?? null;
}

export async function deleteIntegration(id) {
  const rows = await db.delete(integrations).where(eq(integrations.id, id)).returning({ id: integrations.id });
  return rows.length > 0;
}

/** 쓴 시각·횟수를 적는다(목록에 "마지막 사용"으로 보인다). */
export async function markIntegrationUsed(id) {
  await db
    .update(integrations)
    .set({ lastUsedAt: new Date(), useCount: sql`${integrations.useCount} + 1` })
    .where(eq(integrations.id, id));
}

// ── 개인 API 토큰 ──────────────────────────────────────────────────────

export async function insertApiToken(fields) {
  const [row] = await db.insert(apiTokens).values(fields).returning();
  return row;
}

/** 내 토큰 목록 — 지운 것은 빼고. */
export function listApiTokens(userId) {
  return db
    .select()
    .from(apiTokens)
    .where(and(eq(apiTokens.userId, userId), isNull(apiTokens.revokedAt)))
    .orderBy(asc(apiTokens.createdAt));
}

export async function countActiveApiTokens(userId) {
  const [row] = await db
    .select({ n: count() })
    .from(apiTokens)
    .where(
      and(
        eq(apiTokens.userId, userId),
        isNull(apiTokens.revokedAt),
        or(isNull(apiTokens.expiresAt), gt(apiTokens.expiresAt, new Date())),
      ),
    );
  return row?.n ?? 0;
}

/** 아직 쓸 수 있는(지우지 않았고 만료 전) 토큰 — 없으면 null. */
export async function findUsableApiToken(tokenHash) {
  const [row] = await db
    .select()
    .from(apiTokens)
    .where(
      and(
        eq(apiTokens.tokenHash, tokenHash),
        isNull(apiTokens.revokedAt),
        or(isNull(apiTokens.expiresAt), gt(apiTokens.expiresAt, new Date())),
      ),
    )
    .limit(1);
  return row ?? null;
}

export async function revokeApiToken(id, userId) {
  const rows = await db
    .update(apiTokens)
    .set({ revokedAt: new Date() })
    .where(and(eq(apiTokens.id, id), eq(apiTokens.userId, userId), isNull(apiTokens.revokedAt)))
    .returning({ id: apiTokens.id });
  return rows.length > 0;
}

/** 쓴 시각 — 1분에 한 번만 적는다(요청마다 쓰지 않게). */
export async function touchApiToken(row) {
  if (row.lastUsedAt && Date.now() - new Date(row.lastUsedAt).getTime() < 60_000) return;
  await db.update(apiTokens).set({ lastUsedAt: new Date() }).where(eq(apiTokens.id, row.id));
}
