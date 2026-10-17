import { and, desc, eq, gt, isNull, lt, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { emailCodes } from '../schema.js';

/** 같은 목적·주소(·계정)의 코드를 가리키는 조건 — 가입 전 코드(userId 없음)와 로그인한 사람의 코드를 섞지 않는다. */
const sameSlot = ({ purpose, emailLookup, userId = null }) =>
  and(
    eq(emailCodes.purpose, purpose),
    eq(emailCodes.emailLookup, emailLookup),
    userId ? eq(emailCodes.userId, userId) : isNull(emailCodes.userId),
  );

/** 그 자리의 가장 최근 코드(없으면 null) — 다시 보내기 대기 시간과 확인에 쓴다. */
export async function findLatestEmailCode(slot) {
  const [row] = await db.select().from(emailCodes).where(sameSlot(slot)).orderBy(desc(emailCodes.createdAt)).limit(1);
  return row ?? null;
}

/** 새 코드를 넣는다 — 같은 자리의 예전 코드는 지운다(늘 마지막 하나만 쓸 수 있다). */
export async function replaceEmailCode({ purpose, emailLookup, userId = null, emailEnc = null, codeHash, expiresAt }) {
  return db.transaction(async (tx) => {
    await tx.delete(emailCodes).where(sameSlot({ purpose, emailLookup, userId }));
    const [row] = await tx
      .insert(emailCodes)
      .values({ purpose, emailLookup, userId, emailEnc, codeHash, expiresAt })
      .returning();
    return row;
  });
}

/**
 * 맞혀 볼 시도 한 칸을 먼저 쓴다 — 아직 살아 있고 시도가 [maxAttempts]보다 적을 때만. 쓴 뒤의 행(못 쓰면 null). 확인하기 전에
 * 한 문장으로 세서, 한꺼번에 여러 요청을 보내도 정한 수보다 많이 맞혀 보지 못한다.
 */
export async function takeEmailCodeAttempt(id, maxAttempts) {
  const [row] = await db
    .update(emailCodes)
    .set({ attempts: sql`${emailCodes.attempts} + 1` })
    .where(and(eq(emailCodes.id, id), lt(emailCodes.attempts, maxAttempts), gt(emailCodes.expiresAt, new Date())))
    .returning();
  return row ?? null;
}

/** 다 쓴 코드를 지운다 — 한 번 쓴 코드로 다시 할 수 없게. 지웠으면 true(이미 누가 썼으면 false). */
export async function deleteEmailCode(id) {
  const rows = await db.delete(emailCodes).where(eq(emailCodes.id, id)).returning({ id: emailCodes.id });
  return rows.length > 0;
}

/** 만료된 코드 정리(retention.js) — 지운 개수. */
export async function deleteExpiredEmailCodes(now = new Date()) {
  const rows = await db.delete(emailCodes).where(lt(emailCodes.expiresAt, now)).returning({ id: emailCodes.id });
  return rows.length;
}
