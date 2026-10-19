import { and, asc, desc, eq, inArray, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { payrollRuns, payrollSettings, payslips } from '../schema.js';

// ── 급여 설정 ──

export async function findPayrollSettings(scopeKey) {
  const [row] = await db.select().from(payrollSettings).where(eq(payrollSettings.scopeKey, scopeKey)).limit(1);
  return row ?? null;
}

export async function upsertPayrollSettings(scopeKey, patch) {
  const [row] = await db
    .insert(payrollSettings)
    .values({ scopeKey, ...patch })
    .onConflictDoUpdate({ target: payrollSettings.scopeKey, set: { ...patch, updatedAt: new Date() } })
    .returning();
  return row;
}

// ── 급여 대장 ──

/** 범위의 급여 대장 — 최근 달부터(같은 달은 최근에 만든 것부터). [status]를 주면 그것만. */
export async function listPayrollRuns(scopeKey, { status = null, limit = 60 } = {}) {
  const where = status ? and(eq(payrollRuns.scopeKey, scopeKey), eq(payrollRuns.status, status)) : eq(payrollRuns.scopeKey, scopeKey);
  return db.select().from(payrollRuns).where(where).orderBy(desc(payrollRuns.payMonth), desc(payrollRuns.createdAt)).limit(limit);
}

export async function findPayrollRun(id) {
  const [row] = await db.select().from(payrollRuns).where(eq(payrollRuns.id, id)).limit(1);
  return row ?? null;
}

/** 대장과 명세서들을 한 번에 만든다. [slips]는 `[{ userId, userName, employeeNo, department, position, data(암호화한 글) }]`. */
export async function insertPayrollRun(run, slips) {
  return db.transaction(async (tx) => {
    const [row] = await tx.insert(payrollRuns).values(run).returning();
    if (slips.length) {
      await tx.insert(payslips).values(slips.map((s) => ({ ...s, runId: row.id, scopeKey: run.scopeKey })));
    }
    return row;
  });
}

export async function updatePayrollRun(id, patch) {
  const [row] = await db
    .update(payrollRuns)
    .set({ ...patch, updatedAt: new Date() })
    .where(eq(payrollRuns.id, id))
    .returning();
  return row ?? null;
}

/**
 * 상태를 [from]에서 바꾼다(보내기·되돌리기) — 그 상태일 때만(동시에 두 사람이 눌러도 한 번만). 바뀐 행 | null.
 */
export async function transitionPayrollRun(id, from, patch) {
  const [row] = await db
    .update(payrollRuns)
    .set({ ...patch, updatedAt: new Date() })
    .where(and(eq(payrollRuns.id, id), eq(payrollRuns.status, from)))
    .returning();
  return row ?? null;
}

export async function deletePayrollRun(id) {
  await db.delete(payrollRuns).where(eq(payrollRuns.id, id));
}

// ── 명세서 ──

/** 대장의 명세서들 — 이름 순. */
export async function listPayslipsOfRun(runId) {
  return db.select().from(payslips).where(eq(payslips.runId, runId)).orderBy(asc(payslips.userName));
}

/** 대장마다의 명세서 수·확인한 수. runId → { count, viewed }. */
export async function countPayslipsByRun(runIds) {
  if (!runIds.length) return new Map();
  const rows = await db
    .select({
      runId: payslips.runId,
      count: sql`count(*)::int`,
      viewed: sql`count(${payslips.viewedAt})::int`,
    })
    .from(payslips)
    .where(inArray(payslips.runId, runIds))
    .groupBy(payslips.runId);
  return new Map(rows.map((r) => [r.runId, { count: r.count, viewed: r.viewed }]));
}

/** 내 명세서들(보낸 대장의 것만) — 지급일 최근부터. `[{ slip, run }]`. */
export async function listMyPayslips(scopeKey, userId, { limit = 120 } = {}) {
  return db
    .select({ slip: payslips, run: payrollRuns })
    .from(payslips)
    .innerJoin(payrollRuns, eq(payrollRuns.id, payslips.runId))
    .where(and(eq(payslips.scopeKey, scopeKey), eq(payslips.userId, userId), eq(payrollRuns.status, 'published')))
    .orderBy(desc(payrollRuns.payDate), desc(payrollRuns.createdAt))
    .limit(limit);
}

/** 명세서 하나와 그 대장. */
export async function findPayslip(id) {
  const [row] = await db
    .select({ slip: payslips, run: payrollRuns })
    .from(payslips)
    .innerJoin(payrollRuns, eq(payrollRuns.id, payslips.runId))
    .where(eq(payslips.id, id))
    .limit(1);
  return row ?? null;
}

/** 대장에 사람을 더한다(이미 있는 사람은 건너뜀). 넣은 행들. */
export async function insertPayslips(runId, scopeKey, slips) {
  if (!slips.length) return [];
  return db
    .insert(payslips)
    .values(slips.map((s) => ({ ...s, runId, scopeKey })))
    .onConflictDoNothing({ target: [payslips.runId, payslips.userId] })
    .returning();
}

export async function updatePayslip(id, patch) {
  const [row] = await db
    .update(payslips)
    .set({ ...patch, updatedAt: new Date() })
    .where(eq(payslips.id, id))
    .returning();
  return row ?? null;
}

/** 받는 사람이 처음 연 시각 — 이미 있으면 그대로. 처음이면 true. */
export async function markPayslipViewed(id) {
  const rows = await db
    .update(payslips)
    .set({ viewedAt: new Date() })
    .where(and(eq(payslips.id, id), sql`${payslips.viewedAt} is null`))
    .returning({ id: payslips.id });
  return rows.length > 0;
}

export async function deletePayslip(id) {
  await db.delete(payslips).where(eq(payslips.id, id));
}

/** 여러 명세서의 내용을 한 트랜잭션으로 바꾼다(엑셀 가져오기·근태 채우기·공제 계산). [updates]는 `[{ id, patch }]`. */
export async function updatePayslipsBulk(updates) {
  if (!updates.length) return;
  await db.transaction(async (tx) => {
    for (const { id, patch } of updates) {
      await tx
        .update(payslips)
        .set({ ...patch, updatedAt: new Date() })
        .where(eq(payslips.id, id));
    }
  });
}
