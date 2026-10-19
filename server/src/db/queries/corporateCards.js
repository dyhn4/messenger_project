import { and, asc, desc, eq, gte, inArray, isNull, lte, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { approvalDocuments, cardFeedKeys, cardTransactions, corporateCards, receiptScans } from '../schema.js';

// ── 카드 ──

export async function listCards(scopeKey) {
  return db.select().from(corporateCards).where(eq(corporateCards.scopeKey, scopeKey)).orderBy(asc(corporateCards.name));
}

export async function findCard(id) {
  const [row] = await db.select().from(corporateCards).where(eq(corporateCards.id, id)).limit(1);
  return row ?? null;
}

export async function insertCard(values) {
  const [row] = await db.insert(corporateCards).values(values).returning();
  return row;
}

export async function updateCard(id, patch) {
  const [row] = await db
    .update(corporateCards)
    .set({ ...patch, updatedAt: new Date() })
    .where(eq(corporateCards.id, id))
    .returning();
  return row ?? null;
}

export async function deleteCard(id) {
  await db.delete(corporateCards).where(eq(corporateCards.id, id));
}

// ── 사용 건 ──

/** 사용 건 + 연결된 지출 결재의 상태·번호·제목(상태 계산 — cardRules.js txStatus). */
const txColumns = {
  tx: cardTransactions,
  expenseStatus: approvalDocuments.status,
  expenseDocNumber: approvalDocuments.docNumber,
  expenseTitle: approvalDocuments.title,
};
const flatten = (r) => ({
  ...r.tx,
  expenseStatus: r.expenseStatus ?? null,
  expenseDocNumber: r.expenseDocNumber ?? null,
  expenseTitle: r.expenseTitle ?? null,
});

/**
 * 범위의 사용 건 — [from]~[to](한국 날짜) 안, 최근부터. [cardIds]를 주면 그 카드들만, [userId]를 주면 그 사람 것과(사용자가 정해지지 않은 건 중)
 * [holderCardIds] 카드의 것만(일반 사용자의 "내 법인카드").
 */
export async function listTransactions({ scopeKey, from = null, to = null, cardIds = null, userId = null, holderCardIds = [], limit = 2000 }) {
  const conds = [eq(cardTransactions.scopeKey, scopeKey)];
  if (from) conds.push(gte(cardTransactions.usedOn, from));
  if (to) conds.push(lte(cardTransactions.usedOn, to));
  if (cardIds) conds.push(cardIds.length ? inArray(cardTransactions.cardId, cardIds) : sql`false`);
  if (userId) {
    conds.push(
      holderCardIds.length
        ? or(eq(cardTransactions.userId, userId), and(isNull(cardTransactions.userId), inArray(cardTransactions.cardId, holderCardIds)))
        : eq(cardTransactions.userId, userId),
    );
  }
  const rows = await db
    .select(txColumns)
    .from(cardTransactions)
    .leftJoin(approvalDocuments, eq(approvalDocuments.id, cardTransactions.expenseDocId))
    .where(and(...conds))
    .orderBy(desc(cardTransactions.usedAt))
    .limit(limit);
  return rows.map(flatten);
}

export async function findTransaction(id) {
  const [row] = await db
    .select(txColumns)
    .from(cardTransactions)
    .leftJoin(approvalDocuments, eq(approvalDocuments.id, cardTransactions.expenseDocId))
    .where(eq(cardTransactions.id, id))
    .limit(1);
  return row ? flatten(row) : null;
}

/** 지출 결재 하나에 묶인 사용 건들. */
export async function listTransactionsOfExpense(docId) {
  return db.select().from(cardTransactions).where(eq(cardTransactions.expenseDocId, docId)).orderBy(asc(cardTransactions.usedAt));
}

/** 사용 건들을 넣는다 — 같은 카드·같은 키는 건너뛴다. 넣은 행들. */
export async function insertTransactions(rows) {
  if (!rows.length) return [];
  const out = [];
  // 한 번에 너무 많은 값을 보내지 않게 나눈다.
  for (let i = 0; i < rows.length; i += 500) {
    out.push(
      ...(await db
        .insert(cardTransactions)
        .values(rows.slice(i, i + 500))
        .onConflictDoNothing({ target: [cardTransactions.cardId, cardTransactions.dedupeKey] })
        .returning()),
    );
  }
  return out;
}

export async function updateTransaction(id, patch) {
  const [row] = await db
    .update(cardTransactions)
    .set({ ...patch, updatedAt: new Date() })
    .where(eq(cardTransactions.id, id))
    .returning();
  return row ?? null;
}

/** 여러 건을 제외로(승인 취소 짝 등). */
export async function excludeTransactions(ids, { reason, byName }) {
  if (!ids.length) return;
  await db
    .update(cardTransactions)
    .set({ excludedAt: new Date(), excludedReason: reason, excludedByName: byName, updatedAt: new Date() })
    .where(and(inArray(cardTransactions.id, ids), isNull(cardTransactions.excludedAt)));
}

export async function deleteTransaction(id) {
  await db.delete(cardTransactions).where(eq(cardTransactions.id, id));
}

/**
 * 지출 결재 트랜잭션 안에서 — 청구할 사용 건들을 잠그고(FOR UPDATE — 두 결재가 같은 건을 동시에 청구하지 못하게) 연결된 결재의 상태를 붙여 읽는다.
 */
export async function lockTransactionsForClaim(tx, ids) {
  if (!ids.length) return [];
  const locked = await tx.select().from(cardTransactions).where(inArray(cardTransactions.id, ids)).for('update');
  const docIds = [...new Set(locked.map((t) => t.expenseDocId).filter(Boolean))];
  const docs = docIds.length
    ? await tx.select({ id: approvalDocuments.id, status: approvalDocuments.status }).from(approvalDocuments).where(inArray(approvalDocuments.id, docIds))
    : [];
  const statusOf = new Map(docs.map((d) => [d.id, d.status]));
  return locked.map((t) => ({ ...t, expenseStatus: t.expenseDocId ? (statusOf.get(t.expenseDocId) ?? null) : null }));
}

/** 같은 트랜잭션에서 — 사용 건들을 지출 결재에 잇고, 사용자가 비어 있던 건은 청구한 사람으로. */
export async function attachTransactionsToExpense(tx, ids, { docId, userId }) {
  if (!ids.length) return;
  await tx
    .update(cardTransactions)
    .set({ expenseDocId: docId, userId: sql`coalesce(${cardTransactions.userId}, ${userId}::uuid)`, updatedAt: new Date() })
    .where(inArray(cardTransactions.id, ids));
}

// ── 연동 키 ──

export async function findFeedKey(scopeKey) {
  const [row] = await db.select().from(cardFeedKeys).where(eq(cardFeedKeys.scopeKey, scopeKey)).limit(1);
  return row ?? null;
}

export async function findFeedKeyByHash(tokenHash) {
  const [row] = await db.select().from(cardFeedKeys).where(eq(cardFeedKeys.tokenHash, tokenHash)).limit(1);
  return row ?? null;
}

export async function upsertFeedKey(values) {
  const [row] = await db
    .insert(cardFeedKeys)
    .values(values)
    .onConflictDoUpdate({
      target: cardFeedKeys.scopeKey,
      set: { tokenHash: values.tokenHash, tokenHint: values.tokenHint, createdByName: values.createdByName, createdAt: new Date(), lastUsedAt: null },
    })
    .returning();
  return row;
}

export async function deleteFeedKey(scopeKey) {
  await db.delete(cardFeedKeys).where(eq(cardFeedKeys.scopeKey, scopeKey));
}

export async function touchFeedKey(scopeKey) {
  await db.update(cardFeedKeys).set({ lastUsedAt: new Date() }).where(eq(cardFeedKeys.scopeKey, scopeKey));
}

// ── 영수증 읽기 결과 ──

export async function findReceiptScan(fileName) {
  const [row] = await db.select().from(receiptScans).where(eq(receiptScans.fileName, fileName)).limit(1);
  return row ?? null;
}

export async function saveReceiptScan({ fileName, userId, engine, result }) {
  await db
    .insert(receiptScans)
    .values({ fileName, userId: userId ?? null, engine, result })
    .onConflictDoUpdate({ target: receiptScans.fileName, set: { engine, result, createdAt: new Date() } });
}
