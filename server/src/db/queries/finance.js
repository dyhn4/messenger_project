import { and, asc, desc, eq, gte, inArray, isNotNull, lte, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { approvalDocuments, cardTransactions, financeSettings, receiptPurges, taxDocuments } from '../schema.js';

// ── 지출 관리 설정 ──

export async function findFinanceSettings(scopeKey) {
  const [row] = await db.select().from(financeSettings).where(eq(financeSettings.scopeKey, scopeKey)).limit(1);
  return row ?? null;
}

export async function upsertFinanceSettings(scopeKey, patch, teamId = null) {
  const [row] = await db
    .insert(financeSettings)
    .values({ scopeKey, teamId, ...patch })
    .onConflictDoUpdate({ target: financeSettings.scopeKey, set: { ...patch, updatedAt: new Date() } })
    .returning();
  return row;
}

/** 범위들의 설정 — [where]가 'autoSync'면 CODEF 자동 가져오기를 켠 것, 'purge'면 보관 기한이 지난 영수증을 지우는 것. */
export async function listFinanceSettings(where) {
  const cond =
    where === 'autoSync'
      ? and(eq(financeSettings.codefAutoSync, true), isNotNull(financeSettings.codefCardConnectedId))
      : and(eq(financeSettings.receiptPurge, true), sql`${financeSettings.receiptRetentionYears} > 0`);
  return db.select().from(financeSettings).where(cond);
}

// ── 지출 결재(전표·영수증 보관) ──

/** 승인된 지출 결재 — 쓴 날(payload.spentOn)이 [from]~[to] 안. 문서 번호 순. */
export async function listApprovedExpenses(scopeKey, { from, to }) {
  const spentOn = sql`(${approvalDocuments.payload}->>'spentOn')`;
  return db
    .select()
    .from(approvalDocuments)
    .where(
      and(
        eq(approvalDocuments.scopeKey, scopeKey),
        eq(approvalDocuments.kind, 'expense'),
        eq(approvalDocuments.status, 'approved'),
        sql`${spentOn} >= ${from}`,
        sql`${spentOn} <= ${to}`,
      ),
    )
    .orderBy(asc(approvalDocuments.createdAt));
}

/** 영수증이 붙은 지출 결재(첨부가 있는 것) — 쓴 날이 [to] 이전. 영수증 보관 현황·지우기. */
export async function listExpenseDocsWithReceipts(scopeKey, { to = '9999-12-31' } = {}) {
  const spentOn = sql`(${approvalDocuments.payload}->>'spentOn')`;
  return db
    .select({
      id: approvalDocuments.id,
      attachments: approvalDocuments.attachments,
      payload: approvalDocuments.payload,
      status: approvalDocuments.status,
    })
    .from(approvalDocuments)
    .where(
      and(
        eq(approvalDocuments.scopeKey, scopeKey),
        eq(approvalDocuments.kind, 'expense'),
        sql`jsonb_array_length(coalesce(${approvalDocuments.attachments}, '[]'::jsonb)) > 0`,
        sql`${spentOn} <= ${to}`,
      ),
    );
}

/** 영수증이 붙은 카드 사용 건 — 쓴 날이 [to] 이전. */
export async function listCardTxsWithReceipts(scopeKey, { to = '9999-12-31' } = {}) {
  return db
    .select({ id: cardTransactions.id, usedOn: cardTransactions.usedOn, receipts: cardTransactions.receipts })
    .from(cardTransactions)
    .where(and(eq(cardTransactions.scopeKey, scopeKey), lte(cardTransactions.usedOn, to), sql`jsonb_array_length(${cardTransactions.receipts}) > 0`));
}

export async function setCardTxReceipts(id, receipts) {
  await db.update(cardTransactions).set({ receipts, updatedAt: new Date() }).where(eq(cardTransactions.id, id));
}

// ── 지운 영수증 ──

export async function listReceiptPurges(fileNames) {
  if (!fileNames.length) return [];
  return db.select().from(receiptPurges).where(inArray(receiptPurges.fileName, fileNames));
}

export async function insertReceiptPurge(values) {
  await db.insert(receiptPurges).values(values).onConflictDoNothing({ target: receiptPurges.fileName });
}

export async function countReceiptPurges(scopeKey) {
  const [row] = await db.select({ n: sql`count(*)::int` }).from(receiptPurges).where(eq(receiptPurges.scopeKey, scopeKey));
  return row?.n ?? 0;
}

// ── 현금영수증·전자세금계산서 ──

/** 범위의 증빙 — [from]~[to] 안, [kind]·[direction]을 주면 그것만. 최근부터. */
export async function listTaxDocuments(scopeKey, { from = null, to = null, kind = null, direction = null, limit = 3000 } = {}) {
  const conds = [eq(taxDocuments.scopeKey, scopeKey)];
  if (from) conds.push(gte(taxDocuments.issuedOn, from));
  if (to) conds.push(lte(taxDocuments.issuedOn, to));
  if (kind) conds.push(eq(taxDocuments.kind, kind));
  if (direction) conds.push(eq(taxDocuments.direction, direction));
  return db
    .select()
    .from(taxDocuments)
    .where(and(...conds))
    .orderBy(desc(taxDocuments.issuedOn), desc(taxDocuments.createdAt))
    .limit(limit);
}

export async function findTaxDocument(id) {
  const [row] = await db.select().from(taxDocuments).where(eq(taxDocuments.id, id)).limit(1);
  return row ?? null;
}

/** 증빙들을 넣는다 — 같은 범위·같은 키는 건너뛴다. 넣은 행들. */
export async function insertTaxDocuments(rows) {
  const out = [];
  for (let i = 0; i < rows.length; i += 500) {
    out.push(
      ...(await db
        .insert(taxDocuments)
        .values(rows.slice(i, i + 500))
        .onConflictDoNothing({ target: [taxDocuments.scopeKey, taxDocuments.dedupeKey] })
        .returning()),
    );
  }
  return out;
}

/** 범위에 이미 있는 키들(미리 보기). */
export async function existingTaxDocKeys(scopeKey, keys) {
  if (!keys.length) return new Set();
  const rows = await db
    .select({ key: taxDocuments.dedupeKey })
    .from(taxDocuments)
    .where(and(eq(taxDocuments.scopeKey, scopeKey), inArray(taxDocuments.dedupeKey, keys)));
  return new Set(rows.map((r) => r.key));
}

export async function updateTaxDocument(id, patch) {
  const [row] = await db
    .update(taxDocuments)
    .set({ ...patch, updatedAt: new Date() })
    .where(eq(taxDocuments.id, id))
    .returning();
  return row ?? null;
}

export async function deleteTaxDocument(id) {
  await db.delete(taxDocuments).where(eq(taxDocuments.id, id));
}
