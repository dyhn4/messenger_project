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

export async function acceptSecretSession(roomId, { responderDeviceId, responderEphemeralPublicKey, responderEphemeralSignature }) {
  const [row] = await db
    .update(secretSessions)
    .set({
      responderDeviceId,
      responderEphemeralPublicKey,
      responderEphemeralSignature,
      status: 'active',
      acceptedAt: new Date(),
    })
    .where(eq(secretSessions.roomId, roomId))
    .returning();
  return row;
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

export async function insertSecretRekey(fields) {
  const [row] = await db.insert(secretRekeys).values(fields).returning();
  return row;
}

export function findSecretRekey(roomId, keyEpoch) {
  return db
    .select()
    .from(secretRekeys)
    .where(and(eq(secretRekeys.roomId, roomId), eq(secretRekeys.keyEpoch, keyEpoch)))
    .then((rows) => rows[0] ?? null);
}

export async function ackSecretRekey(roomId, keyEpoch, { responderEphemeralPublicKey, responderEphemeralSignature }) {
  const [row] = await db
    .update(secretRekeys)
    .set({ responderEphemeralPublicKey, responderEphemeralSignature, status: 'acked' })
    .where(and(eq(secretRekeys.roomId, roomId), eq(secretRekeys.keyEpoch, keyEpoch)))
    .returning();
  return row;
}
