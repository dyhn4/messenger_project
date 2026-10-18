import { and, asc, count, desc, eq, gt, inArray, isNotNull, isNull, lt, lte, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { apiTokens, integrationRooms, integrations, oauthGrants, oauthRequests, teams, webhookDeliveries } from '../schema.js';

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

/** 내 토큰 목록 — 지운 것과 OAuth 토큰(연결된 앱에서 따로 본다)은 빼고. */
export function listApiTokens(userId) {
  return db
    .select()
    .from(apiTokens)
    .where(and(eq(apiTokens.userId, userId), eq(apiTokens.kind, 'personal'), isNull(apiTokens.revokedAt)))
    .orderBy(asc(apiTokens.createdAt));
}

export async function countActiveApiTokens(userId) {
  const [row] = await db
    .select({ n: count() })
    .from(apiTokens)
    .where(
      and(
        eq(apiTokens.userId, userId),
        eq(apiTokens.kind, 'personal'),
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

/** 토큰 하나를 바로 못 쓰게(OAuth 다시 받기 — 쓴 다시 받기 토큰). 지웠으면 true. */
export async function revokeTokenById(id) {
  const rows = await db
    .update(apiTokens)
    .set({ revokedAt: new Date() })
    .where(and(eq(apiTokens.id, id), isNull(apiTokens.revokedAt)))
    .returning({ id: apiTokens.id });
  return rows.length > 0;
}

// ── 나가는 웹훅·연동 앱 ─────────────────────────────────────────────────

export function listRoomOutgoingWebhooks(roomId) {
  return db
    .select()
    .from(integrations)
    .where(and(eq(integrations.roomId, roomId), eq(integrations.kind, 'outgoing')))
    .orderBy(asc(integrations.createdAt));
}

export async function countRoomOutgoingWebhooks(roomId) {
  const [row] = await db
    .select({ n: count() })
    .from(integrations)
    .where(and(eq(integrations.roomId, roomId), eq(integrations.kind, 'outgoing')));
  return row?.n ?? 0;
}

export function listTeamApps(teamId) {
  return db
    .select()
    .from(integrations)
    .where(and(eq(integrations.teamId, teamId), eq(integrations.kind, 'app')))
    .orderBy(asc(integrations.name));
}

export async function countTeamApps(teamId) {
  const [row] = await db
    .select({ n: count() })
    .from(integrations)
    .where(and(eq(integrations.teamId, teamId), eq(integrations.kind, 'app')));
  return row?.n ?? 0;
}

/** 봇 토큰(ttb_)의 앱 — 꺼진 앱은 찾지 않는다. */
export async function findAppByBotTokenHash(tokenHash) {
  const [row] = await db
    .select()
    .from(integrations)
    .where(and(eq(integrations.tokenHash, tokenHash), eq(integrations.kind, 'app'), eq(integrations.enabled, true)))
    .limit(1);
  return row ?? null;
}

export async function findAppByClientId(clientId) {
  const [row] = await db
    .select()
    .from(integrations)
    .where(and(eq(integrations.clientId, clientId), eq(integrations.kind, 'app')))
    .limit(1);
  return row ?? null;
}

/** 이 방에 추가된 앱들(추가한 사람·시각과 함께). */
export function listRoomApps(roomId) {
  return db
    .select({ app: integrations, addedByName: integrationRooms.addedByName, addedAt: integrationRooms.createdAt })
    .from(integrationRooms)
    .innerJoin(integrations, eq(integrations.id, integrationRooms.integrationId))
    .where(eq(integrationRooms.roomId, roomId))
    .orderBy(asc(integrations.name));
}

export async function isAppInRoom(integrationId, roomId) {
  const [row] = await db
    .select({ id: integrationRooms.integrationId })
    .from(integrationRooms)
    .where(and(eq(integrationRooms.integrationId, integrationId), eq(integrationRooms.roomId, roomId)))
    .limit(1);
  return !!row;
}

/** 방에 앱 추가 — 이미 있으면 false. */
export async function addAppToRoom({ integrationId, roomId, addedBy, addedByName }) {
  const rows = await db
    .insert(integrationRooms)
    .values({ integrationId, roomId, addedBy, addedByName })
    .onConflictDoNothing()
    .returning({ id: integrationRooms.integrationId });
  return rows.length > 0;
}

export async function removeAppFromRoom(integrationId, roomId) {
  const rows = await db
    .delete(integrationRooms)
    .where(and(eq(integrationRooms.integrationId, integrationId), eq(integrationRooms.roomId, roomId)))
    .returning({ id: integrationRooms.integrationId });
  return rows.length > 0;
}

/** 앱이 추가된 방 id들 — 봇 토큰의 방 목록. */
export async function listAppRoomIds(integrationId) {
  const rows = await db
    .select({ roomId: integrationRooms.roomId })
    .from(integrationRooms)
    .where(eq(integrationRooms.integrationId, integrationId));
  return rows.map((r) => r.roomId);
}

/**
 * 이 방의 일을 받을 수 있는 연동 — 이 방의 나가는 웹훅과 이 방에 추가된 앱 중 켜져 있고 보낼 주소가 있는 것(일 종류는 부르는 쪽이
 * integrationWantsEvent로 거른다).
 */
export async function listEventTargets(roomId) {
  const appIds = db.select({ id: integrationRooms.integrationId }).from(integrationRooms).where(eq(integrationRooms.roomId, roomId));
  return db
    .select()
    .from(integrations)
    .where(
      and(
        eq(integrations.enabled, true),
        isNotNull(integrations.url),
        or(
          and(eq(integrations.kind, 'outgoing'), eq(integrations.roomId, roomId)),
          and(eq(integrations.kind, 'app'), inArray(integrations.id, appIds)),
        ),
      ),
    );
}

// ── 보내기 기록(webhook_deliveries) ──────────────────────────────────────

export async function insertDeliveries(rows) {
  if (rows.length === 0) return [];
  return db.insert(webhookDeliveries).values(rows).returning();
}

/** 보낼 때가 된 것들(오래된 것부터). */
export function listDueDeliveries(now, limit) {
  return db
    .select()
    .from(webhookDeliveries)
    .where(and(eq(webhookDeliveries.status, 'pending'), lte(webhookDeliveries.nextAttemptAt, now)))
    .orderBy(asc(webhookDeliveries.nextAttemptAt))
    .limit(limit);
}

export async function updateDelivery(id, patch) {
  const [row] = await db.update(webhookDeliveries).set(patch).where(eq(webhookDeliveries.id, id)).returning();
  return row ?? null;
}

export function listRecentDeliveries(integrationId, limit = 30) {
  return db
    .select()
    .from(webhookDeliveries)
    .where(eq(webhookDeliveries.integrationId, integrationId))
    .orderBy(desc(webhookDeliveries.createdAt))
    .limit(limit);
}

export async function deleteDeliveriesBefore(before) {
  await db.delete(webhookDeliveries).where(lt(webhookDeliveries.createdAt, before));
}

/** 꺼진 연동의 남은 보내기를 실패로 끝낸다. */
export async function failPendingDeliveries(integrationId, error) {
  await db
    .update(webhookDeliveries)
    .set({ status: 'failed', lastError: error })
    .where(and(eq(webhookDeliveries.integrationId, integrationId), eq(webhookDeliveries.status, 'pending')));
}

/** 보내기 성공 — 연달아 실패한 수를 0으로, 쓴 시각·횟수. */
export async function markDeliverySucceeded(integrationId) {
  await db
    .update(integrations)
    .set({ failureCount: 0, lastUsedAt: new Date(), useCount: sql`${integrations.useCount} + 1` })
    .where(eq(integrations.id, integrationId));
}

/** 끝내 못 보낸 일 하나 — 연달아 실패한 수를 늘리고, [disableAt]에 닿으면 끈다. 바뀐 행. */
export async function markDeliveryGaveUp(integrationId, disableAt) {
  const [row] = await db
    .update(integrations)
    .set({
      failureCount: sql`${integrations.failureCount} + 1`,
      enabled: sql`case when ${integrations.failureCount} + 1 >= ${disableAt} then false else ${integrations.enabled} end`,
    })
    .where(eq(integrations.id, integrationId))
    .returning();
  return row ?? null;
}

// ── OAuth 승인·요청 ─────────────────────────────────────────────────────

/** 승인 넣기 — 이미 있으면 권한을 이번 것으로 바꾼다. */
export async function upsertGrant({ integrationId, userId, scopes }) {
  const [row] = await db
    .insert(oauthGrants)
    .values({ integrationId, userId, scopes })
    .onConflictDoUpdate({ target: [oauthGrants.integrationId, oauthGrants.userId], set: { scopes } })
    .returning();
  return row;
}

export async function findGrantById(id) {
  const [row] = await db.select().from(oauthGrants).where(eq(oauthGrants.id, id)).limit(1);
  return row ?? null;
}

/** 내 연결된 앱(앱 이름·아이콘·설명·팀 이름과 함께). */
export function listUserGrants(userId) {
  return db
    .select({ grant: oauthGrants, app: integrations, teamName: teams.name })
    .from(oauthGrants)
    .innerJoin(integrations, eq(integrations.id, oauthGrants.integrationId))
    .leftJoin(teams, eq(teams.id, integrations.teamId))
    .where(eq(oauthGrants.userId, userId))
    .orderBy(desc(oauthGrants.createdAt));
}

export async function deleteGrant(id, userId) {
  const rows = await db
    .delete(oauthGrants)
    .where(and(eq(oauthGrants.id, id), eq(oauthGrants.userId, userId)))
    .returning({ id: oauthGrants.id });
  return rows.length > 0;
}

/** 쓴 시각 — 1분에 한 번만 적는다. */
export async function touchGrant(grant) {
  if (grant.lastUsedAt && Date.now() - new Date(grant.lastUsedAt).getTime() < 60_000) return;
  await db.update(oauthGrants).set({ lastUsedAt: new Date() }).where(eq(oauthGrants.id, grant.id));
}

export async function insertOAuthRequest(fields) {
  const [row] = await db.insert(oauthRequests).values(fields).returning();
  return row;
}

export async function findOAuthRequestById(id) {
  const [row] = await db.select().from(oauthRequests).where(eq(oauthRequests.id, id)).limit(1);
  return row ?? null;
}

export async function findOAuthRequestByUserCode(userCode) {
  const [row] = await db.select().from(oauthRequests).where(eq(oauthRequests.userCode, userCode)).limit(1);
  return row ?? null;
}

export async function findOAuthRequestByCodeHash(codeHash) {
  const [row] = await db.select().from(oauthRequests).where(eq(oauthRequests.codeHash, codeHash)).limit(1);
  return row ?? null;
}

/** 요청 상태를 [from] → patch로 바꾼다(그새 다른 쪽이 바꿨으면 null — 승인 코드를 두 번 쓰지 못하게). */
export async function transitionOAuthRequest(id, from, patch) {
  const [row] = await db
    .update(oauthRequests)
    .set(patch)
    .where(and(eq(oauthRequests.id, id), eq(oauthRequests.status, from)))
    .returning();
  return row ?? null;
}

export async function deleteOAuthRequestsBefore(before) {
  await db.delete(oauthRequests).where(lt(oauthRequests.expiresAt, before));
}
