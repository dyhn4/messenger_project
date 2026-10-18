import { and, asc, count, desc, eq, isNull } from 'drizzle-orm';
import { db } from '../client.js';
import { directoryGroupMappings, groupSyncGrants, ssoSessions, teams, webauthnCredentials } from '../schema.js';

// ── 보안 키·패스키(WebAuthn — webauthn.js) ─────────────────────────────────

export function listPasskeys(userId) {
  return db.select().from(webauthnCredentials).where(eq(webauthnCredentials.userId, userId)).orderBy(asc(webauthnCredentials.createdAt));
}

export async function countPasskeys(userId) {
  const [row] = await db.select({ n: count() }).from(webauthnCredentials).where(eq(webauthnCredentials.userId, userId));
  return row?.n ?? 0;
}

export async function findPasskeyByCredentialId(credentialId) {
  const [row] = await db.select().from(webauthnCredentials).where(eq(webauthnCredentials.credentialId, credentialId)).limit(1);
  return row ?? null;
}

/** 넣기 — 같은 키 id가 이미 있으면(다른 계정이든 같은 계정이든) null. */
export async function insertPasskey(fields) {
  const rows = await db.insert(webauthnCredentials).values(fields).onConflictDoNothing().returning();
  return rows[0] ?? null;
}

/** 쓴 기록 — 키가 센 서명 횟수와 시각. */
export async function touchPasskey(id, counter) {
  await db.update(webauthnCredentials).set({ counter, lastUsedAt: new Date() }).where(eq(webauthnCredentials.id, id));
}

export async function renamePasskey(id, userId, name) {
  const [row] = await db
    .update(webauthnCredentials)
    .set({ name })
    .where(and(eq(webauthnCredentials.id, id), eq(webauthnCredentials.userId, userId)))
    .returning();
  return row ?? null;
}

export async function deletePasskey(id, userId) {
  const rows = await db
    .delete(webauthnCredentials)
    .where(and(eq(webauthnCredentials.id, id), eq(webauthnCredentials.userId, userId)))
    .returning({ id: webauthnCredentials.id });
  return rows.length > 0;
}

// ── 디렉터리 그룹 규칙(groupSync.js) ─────────────────────────────────────

/** 규칙 전부(팀 이름과 함께 — 지운 팀의 규칙은 같이 지워진다). */
export function listGroupMappings() {
  return db
    .select({ mapping: directoryGroupMappings, teamName: teams.name })
    .from(directoryGroupMappings)
    .leftJoin(teams, eq(teams.id, directoryGroupMappings.teamId))
    .orderBy(asc(directoryGroupMappings.createdAt));
}

export async function countGroupMappings() {
  const [row] = await db.select({ n: count() }).from(directoryGroupMappings);
  return row?.n ?? 0;
}

export async function insertGroupMapping(fields) {
  const [row] = await db.insert(directoryGroupMappings).values(fields).returning();
  return row;
}

export async function deleteGroupMapping(id) {
  const rows = await db.delete(directoryGroupMappings).where(eq(directoryGroupMappings.id, id)).returning({ id: directoryGroupMappings.id });
  return rows.length > 0;
}

/** 이 사람이 규칙으로 들어간 팀들. */
export async function listGrantedTeamIds(userId) {
  const rows = await db.select({ teamId: groupSyncGrants.teamId }).from(groupSyncGrants).where(eq(groupSyncGrants.userId, userId));
  return rows.map((r) => r.teamId);
}

export async function addGroupSyncGrant(userId, teamId) {
  await db.insert(groupSyncGrants).values({ userId, teamId }).onConflictDoNothing();
}

/** 팀에서 빠지면(누가 빼든) — 다음에 사람이 직접 다시 넣은 멤버십을 규칙이 빼지 않게. */
export async function removeGroupSyncGrant(userId, teamId) {
  await db.delete(groupSyncGrants).where(and(eq(groupSyncGrants.userId, userId), eq(groupSyncGrants.teamId, teamId)));
}

// ── 회사 계정 로그인 세션(로그아웃 연동) ───────────────────────────────────

export async function insertSsoSession(fields) {
  const [row] = await db.insert(ssoSessions).values(fields).returning();
  return row;
}

export async function findSsoSessionById(id) {
  const [row] = await db.select().from(ssoSessions).where(eq(ssoSessions.id, id)).limit(1);
  return row ?? null;
}

/** 끝낸다 — 이미 끝났으면 null. */
export async function endSsoSession(id, reason) {
  const [row] = await db
    .update(ssoSessions)
    .set({ endedAt: new Date(), endReason: reason })
    .where(and(eq(ssoSessions.id, id), isNull(ssoSessions.endedAt)))
    .returning();
  return row ?? null;
}

/**
 * 회사 계정 쪽 로그아웃 — [provider]의 세션 중 그쪽 세션 값([idpSessionId])이나 NameID([nameId] — SessionIndex 없이 온 SAML 로그아웃)가
 * 같은, 아직 안 끝난 것을 모두 끝낸다. 끝낸 행들.
 */
export async function endSsoSessionsBy({ provider, idpSessionId = null, nameId = null }, reason) {
  const match = idpSessionId ? eq(ssoSessions.idpSessionId, idpSessionId) : eq(ssoSessions.nameId, nameId);
  return db
    .update(ssoSessions)
    .set({ endedAt: new Date(), endReason: reason })
    .where(and(eq(ssoSessions.provider, provider), match, isNull(ssoSessions.endedAt)))
    .returning();
}

/** 최근 세션들(관리자·시험용). */
export function listSsoSessionsForUser(userId, limit = 20) {
  return db.select().from(ssoSessions).where(eq(ssoSessions.userId, userId)).orderBy(desc(ssoSessions.createdAt)).limit(limit);
}
