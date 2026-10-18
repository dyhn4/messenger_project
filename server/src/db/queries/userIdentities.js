import { and, asc, eq } from 'drizzle-orm';
import { db } from '../client.js';
import { userIdentities } from '../schema.js';

/** 연결된 외부 로그인(회사 계정·디렉터리) 하나 — 없으면 null. */
export async function findIdentity(provider, subject) {
  const [row] = await db
    .select()
    .from(userIdentities)
    .where(and(eq(userIdentities.provider, provider), eq(userIdentities.subject, subject)))
    .limit(1);
  return row ?? null;
}

/** 이 사람이 [provider]에 연결해 둔 것 — 없으면 null. */
export async function findIdentityForUser(userId, provider) {
  const [row] = await db
    .select()
    .from(userIdentities)
    .where(and(eq(userIdentities.userId, userId), eq(userIdentities.provider, provider)))
    .limit(1);
  return row ?? null;
}

/** [provider]에 연결된 것 전부 `[{ userId, subject }]` — 디렉터리로 조직도를 한꺼번에 맞출 때(orgDirectorySync.js). */
export function listIdentitiesByProvider(provider) {
  return db
    .select({ userId: userIdentities.userId, subject: userIdentities.subject })
    .from(userIdentities)
    .where(eq(userIdentities.provider, provider));
}

export function listIdentitiesForUser(userId) {
  return db.select().from(userIdentities).where(eq(userIdentities.userId, userId)).orderBy(asc(userIdentities.createdAt));
}

/**
 * 연결한다 — 같은 외부 계정이 이미 다른 사람에게 이어져 있으면 넣지 않고 null(unique). 같은 사람이 같은 제공자에 다른 계정을
 * 잇고 있었으면 바꾼다(한 사람 한 제공자 하나).
 */
export async function linkIdentity({ userId, provider, subject, emailEnc = null }) {
  return db.transaction(async (tx) => {
    const [taken] = await tx
      .select()
      .from(userIdentities)
      .where(and(eq(userIdentities.provider, provider), eq(userIdentities.subject, subject)))
      .limit(1);
    if (taken && taken.userId !== userId) return null;
    if (taken) return taken;
    await tx.delete(userIdentities).where(and(eq(userIdentities.userId, userId), eq(userIdentities.provider, provider)));
    const [row] = await tx
      .insert(userIdentities)
      .values({ userId, provider, subject, emailEnc, lastLoginAt: new Date() })
      .onConflictDoNothing()
      .returning();
    return row ?? null;
  });
}

export async function touchIdentity(id) {
  await db.update(userIdentities).set({ lastLoginAt: new Date() }).where(eq(userIdentities.id, id));
}

/** 연결을 끊는다. 끊었으면 true. */
export async function unlinkIdentity(userId, provider) {
  const rows = await db
    .delete(userIdentities)
    .where(and(eq(userIdentities.userId, userId), eq(userIdentities.provider, provider)))
    .returning({ id: userIdentities.id });
  return rows.length > 0;
}
