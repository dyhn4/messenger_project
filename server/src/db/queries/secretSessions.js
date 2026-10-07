import { and, eq } from 'drizzle-orm';
import { db } from '../client.js';
import { secretRekeys, secretSessions } from '../schema.js';

export async function insertSecretSession(fields) {
  const [row] = await db.insert(secretSessions).values(fields).returning();
  return row;
}

export function findSecretSessionByRoomId(roomId) {
  return db
    .select()
    .from(secretSessions)
    .where(eq(secretSessions.roomId, roomId))
    .then((rows) => rows[0] ?? null);
}

/**
 * 초대받은 사람([responderUserId])이 아직 대기 중인 초대를 수락할 때만 바뀐다(아니면 null). 예전엔 방 멤버면 누구나,
 * 이미 시작된 대화에도 응답자 키를 덮어써서 상대의 비밀 대화를 깨거나 키를 바꿔치기할 수 있었다.
 * [responderContextSignature]는 맥락 서명(secretContextRules.js) — 예전 앱이 수락하면 없어서 null로 둔다.
 */
export async function acceptSecretSession(
  roomId,
  { responderUserId, responderDeviceId, responderEphemeralPublicKey, responderEphemeralSignature, responderContextSignature },
) {
  const [row] = await db
    .update(secretSessions)
    .set({
      responderDeviceId,
      responderEphemeralPublicKey,
      responderEphemeralSignature,
      responderContextSignature: responderContextSignature ?? null,
      status: 'active',
      acceptedAt: new Date(),
    })
    .where(
      and(
        eq(secretSessions.roomId, roomId),
        eq(secretSessions.responderUserId, responderUserId),
        eq(secretSessions.status, 'pending'),
      ),
    )
    .returning();
  return row ?? null;
}

export async function rejectSecretSession(roomId) {
  await db.update(secretSessions).set({ status: 'rejected' }).where(eq(secretSessions.roomId, roomId));
}

export async function setSecretSessionSelfDestruct(roomId, seconds) {
  const [row] = await db
    .update(secretSessions)
    .set({ selfDestructSeconds: seconds })
    .where(eq(secretSessions.roomId, roomId))
    .returning();
  return row;
}

export async function bumpSecretSessionEpoch(roomId, newEpoch) {
  await db.update(secretSessions).set({ keyEpoch: newEpoch }).where(eq(secretSessions.roomId, roomId));
}

/**
 * 재키잉 제안 하나를 적는다 — 같은 방·같은 epoch에 같은 제안자가 낸, 아직 수락되지 않은 예전 제안이 있으면 지우고
 * 적는다(예전 앱 둘이 동시에 낸 서로의 제안은 건드리지 않는다). 예전 앱은 수락이 올 때까지 메시지마다 새 임시키로 다시
 * 제안하는데, 새 앱은 재키잉에 응하지 않아(client secret_session_manager.dart) 그대로 두면 그런 방에서는 메시지마다 행이
 * 하나씩 쌓인다.
 */
export async function replaceSecretRekeyProposal(fields) {
  return db.transaction(async (tx) => {
    await tx
      .delete(secretRekeys)
      .where(
        and(
          eq(secretRekeys.roomId, fields.roomId),
          eq(secretRekeys.keyEpoch, fields.keyEpoch),
          eq(secretRekeys.proposerUserId, fields.proposerUserId),
          eq(secretRekeys.status, 'proposed'),
        ),
      );
    const [row] = await tx.insert(secretRekeys).values(fields).returning();
    return row;
  });
}

export function findSecretRekey(roomId, keyEpoch) {
  return db
    .select()
    .from(secretRekeys)
    .where(and(eq(secretRekeys.roomId, roomId), eq(secretRekeys.keyEpoch, keyEpoch)))
    .then((rows) => rows[0] ?? null);
}

/** 재키잉 수락을 그 제안 행에 적는다. [responderContextSignature]는 맥락 서명 — 예전 앱의 수락이면 null. */
export async function ackSecretRekey(
  roomId,
  keyEpoch,
  { responderEphemeralPublicKey, responderEphemeralSignature, responderContextSignature },
) {
  const [row] = await db
    .update(secretRekeys)
    .set({
      responderEphemeralPublicKey,
      responderEphemeralSignature,
      responderContextSignature: responderContextSignature ?? null,
      status: 'acked',
    })
    .where(and(eq(secretRekeys.roomId, roomId), eq(secretRekeys.keyEpoch, keyEpoch)))
    .returning();
  return row;
}
