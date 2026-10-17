import { and, desc, eq, inArray, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { surveyResponses, surveys, users, workReportComments, workReportReads, workReports } from '../schema.js';

// ── 설문 ────────────────────────────────────────────────────────────────

export async function insertSurvey(values) {
  const [row] = await db.insert(surveys).values(values).returning();
  return row;
}

export async function findSurvey(id) {
  const [row] = await db.select().from(surveys).where(eq(surveys.id, id));
  return row ?? null;
}

/** 범위의 설문(최근 것부터 200개) — 누가 볼 수 있는지는 부른 쪽이 거른다. */
export function listScopeSurveys(scopeKey) {
  return db.select().from(surveys).where(eq(surveys.scopeKey, scopeKey)).orderBy(desc(surveys.createdAt)).limit(200);
}

export async function updateSurvey(id, fields) {
  const [row] = await db.update(surveys).set(fields).where(eq(surveys.id, id)).returning();
  return row ?? null;
}

export async function deleteSurvey(id) {
  await db.delete(surveys).where(eq(surveys.id, id));
}

/** [surveyIds] 각각의 응답 수 {surveyId: n}. */
export async function countResponses(surveyIds) {
  if (surveyIds.length === 0) return {};
  const rows = await db
    .select({ surveyId: surveyResponses.surveyId, n: sql`count(*)::int` })
    .from(surveyResponses)
    .where(inArray(surveyResponses.surveyId, surveyIds))
    .groupBy(surveyResponses.surveyId);
  return Object.fromEntries(rows.map((r) => [r.surveyId, r.n ?? 0]));
}

/** [userId]가 응답한 설문 id들(그중 [surveyIds]). */
export async function respondedSurveyIds(userId, surveyIds) {
  if (surveyIds.length === 0) return new Set();
  const rows = await db
    .select({ surveyId: surveyResponses.surveyId })
    .from(surveyResponses)
    .where(and(eq(surveyResponses.userId, userId), inArray(surveyResponses.surveyId, surveyIds)));
  return new Set(rows.map((r) => r.surveyId));
}

export async function findResponse(surveyId, userId) {
  const [row] = await db
    .select()
    .from(surveyResponses)
    .where(and(eq(surveyResponses.surveyId, surveyId), eq(surveyResponses.userId, userId)));
  return row ?? null;
}

/** 응답을 넣거나 고친다 — 처음 낸 것이면 true. */
export async function upsertResponse(surveyId, userId, answers) {
  const inserted = await db
    .insert(surveyResponses)
    .values({ surveyId, userId, answers })
    .onConflictDoNothing()
    .returning({ userId: surveyResponses.userId });
  if (inserted.length > 0) return true;
  await db
    .update(surveyResponses)
    .set({ answers, updatedAt: new Date() })
    .where(and(eq(surveyResponses.surveyId, surveyId), eq(surveyResponses.userId, userId)));
  return false;
}

/** 설문의 응답 전부(응답한 사람 이름과). */
export function listResponses(surveyId) {
  return db
    .select({
      userId: surveyResponses.userId,
      name: users.name,
      username: users.username,
      answers: surveyResponses.answers,
      submittedAt: surveyResponses.submittedAt,
    })
    .from(surveyResponses)
    .leftJoin(users, eq(users.id, surveyResponses.userId))
    .where(eq(surveyResponses.surveyId, surveyId))
    .orderBy(surveyResponses.submittedAt);
}

/** 독촉 시각을 남긴다 — [before] 이전에 마지막으로 독촉했을 때만(1시간에 한 번). 남겼으면 true. */
export async function claimSurveyReminder(id, before) {
  const rows = await db
    .update(surveys)
    .set({ remindedAt: new Date() })
    .where(and(eq(surveys.id, id), sql`(${surveys.remindedAt} is null or ${surveys.remindedAt} < ${before})`))
    .returning({ id: surveys.id });
  return rows.length > 0;
}

// ── 업무일지 ────────────────────────────────────────────────────────────

export async function findReport(id) {
  const [row] = await db.select().from(workReports).where(eq(workReports.id, id));
  return row ?? null;
}

export async function findReportFor({ scopeKey, userId, kind, periodStart }) {
  const [row] = await db
    .select()
    .from(workReports)
    .where(
      and(
        eq(workReports.scopeKey, scopeKey),
        eq(workReports.userId, userId),
        eq(workReports.kind, kind),
        eq(workReports.periodStart, periodStart),
      ),
    );
  return row ?? null;
}

/** 보고를 쓰거나 고친다 — `{ row, created }`. */
export async function upsertReport(key, values) {
  const existing = await findReportFor(key);
  if (existing) {
    const [row] = await db
      .update(workReports)
      .set({ ...values, updatedAt: new Date() })
      .where(eq(workReports.id, existing.id))
      .returning();
    return { row, created: false };
  }
  const rows = await db
    .insert(workReports)
    .values({ ...key, ...values })
    .onConflictDoNothing()
    .returning();
  if (rows.length > 0) return { row: rows[0], created: true };
  // 두 기기에서 동시에 처음 낸 경우 — 먼저 들어간 행을 고친다.
  const again = await findReportFor(key);
  const [row] = await db
    .update(workReports)
    .set({ ...values, updatedAt: new Date() })
    .where(eq(workReports.id, again.id))
    .returning();
  return { row, created: false };
}

export async function deleteReport(id) {
  await db.delete(workReports).where(eq(workReports.id, id));
}

/** 내 보고 목록(최근 기간부터) — [kind]와 기간([from]~[to], 둘 다 포함)으로 거른다. */
export function listMyReports({ scopeKey, userId, kind, from = null, to = null, limit = 30 }) {
  const conds = [eq(workReports.scopeKey, scopeKey), eq(workReports.userId, userId), eq(workReports.kind, kind)];
  if (from) conds.push(sql`${workReports.periodStart} >= ${from}`);
  if (to) conds.push(sql`${workReports.periodStart} <= ${to}`);
  return db
    .select()
    .from(workReports)
    .where(and(...conds))
    .orderBy(desc(workReports.periodStart))
    .limit(limit);
}

/** 한 기간의 범위 보고들(사람들 [userIds]만). */
export function listPeriodReports({ scopeKey, kind, periodStart, userIds }) {
  if (userIds.length === 0) return Promise.resolve([]);
  return db
    .select()
    .from(workReports)
    .where(
      and(
        eq(workReports.scopeKey, scopeKey),
        eq(workReports.kind, kind),
        eq(workReports.periodStart, periodStart),
        inArray(workReports.userId, userIds),
      ),
    );
}

export function listReportComments(reportId) {
  return db
    .select()
    .from(workReportComments)
    .where(eq(workReportComments.reportId, reportId))
    .orderBy(workReportComments.createdAt);
}

export async function insertReportComment(values) {
  const [row] = await db.insert(workReportComments).values(values).returning();
  return row;
}

/** [reportIds] 각각의 댓글 수. */
export async function countReportComments(reportIds) {
  if (reportIds.length === 0) return {};
  const rows = await db
    .select({ reportId: workReportComments.reportId, n: sql`count(*)::int` })
    .from(workReportComments)
    .where(inArray(workReportComments.reportId, reportIds))
    .groupBy(workReportComments.reportId);
  return Object.fromEntries(rows.map((r) => [r.reportId, r.n ?? 0]));
}

/** 읽음 — 처음 연 시각만. 새로 읽었으면 true. */
export async function markReportRead(reportId, userId) {
  const rows = await db
    .insert(workReportReads)
    .values({ reportId, userId })
    .onConflictDoNothing()
    .returning({ userId: workReportReads.userId });
  return rows.length > 0;
}

/** [reportIds] 각각을 읽은 사람 [{ reportId, userId, name, readAt }]. */
export function listReportReads(reportIds) {
  if (reportIds.length === 0) return Promise.resolve([]);
  return db
    .select({
      reportId: workReportReads.reportId,
      userId: workReportReads.userId,
      name: users.name,
      readAt: workReportReads.readAt,
    })
    .from(workReportReads)
    .leftJoin(users, eq(users.id, workReportReads.userId))
    .where(inArray(workReportReads.reportId, reportIds))
    .orderBy(workReportReads.readAt);
}
