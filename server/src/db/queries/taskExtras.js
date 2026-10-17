import { and, asc, desc, eq, gte, inArray, isNotNull, lte, ne, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { projects, taskDependencies, taskStatuses, taskTimeEntries, taskTimers, tasks, users } from '../schema.js';

// ── 선후행 ──────────────────────────────────────────────────────────────

/** 한 프로젝트의 선후행 관계 전부 [{ taskId, dependsOnId }] — 순환 검사용(같은 프로젝트 업무끼리만 있다). */
export function listProjectDependencies(projectId) {
  return db
    .select({ taskId: taskDependencies.taskId, dependsOnId: taskDependencies.dependsOnTaskId })
    .from(taskDependencies)
    .innerJoin(tasks, eq(tasks.id, taskDependencies.taskId))
    .where(eq(tasks.projectId, projectId));
}

/** 업무 요약(선후행 목록 한 줄) — 번호·제목·상태·담당자. */
const taskSummary = {
  id: tasks.id,
  seq: tasks.seq,
  title: tasks.title,
  status: tasks.status,
  statusName: taskStatuses.name,
  statusColor: taskStatuses.color,
  assigneeId: tasks.assigneeId,
  assigneeName: users.name,
  dueDate: tasks.dueDate,
  archivedAt: tasks.archivedAt,
};

/** [taskId]의 선행 업무들. */
export function listPredecessors(taskId) {
  return db
    .select(taskSummary)
    .from(taskDependencies)
    .innerJoin(tasks, eq(tasks.id, taskDependencies.dependsOnTaskId))
    .leftJoin(taskStatuses, eq(taskStatuses.id, tasks.statusId))
    .leftJoin(users, eq(users.id, tasks.assigneeId))
    .where(eq(taskDependencies.taskId, taskId))
    .orderBy(asc(tasks.seq));
}

/** [taskId]를 선행으로 둔 후행 업무들. */
export function listSuccessors(taskId) {
  return db
    .select(taskSummary)
    .from(taskDependencies)
    .innerJoin(tasks, eq(tasks.id, taskDependencies.taskId))
    .leftJoin(taskStatuses, eq(taskStatuses.id, tasks.statusId))
    .leftJoin(users, eq(users.id, tasks.assigneeId))
    .where(eq(taskDependencies.dependsOnTaskId, taskId))
    .orderBy(asc(tasks.seq));
}

export async function countPredecessors(taskId) {
  const [row] = await db
    .select({ n: sql`count(*)::int` })
    .from(taskDependencies)
    .where(eq(taskDependencies.taskId, taskId));
  return row?.n ?? 0;
}

/** 넣었으면 true(이미 있으면 false). */
export async function insertDependency(taskId, dependsOnTaskId, createdBy) {
  const rows = await db
    .insert(taskDependencies)
    .values({ taskId, dependsOnTaskId, createdBy })
    .onConflictDoNothing()
    .returning({ taskId: taskDependencies.taskId });
  return rows.length > 0;
}

export async function deleteDependency(taskId, dependsOnTaskId) {
  const rows = await db
    .delete(taskDependencies)
    .where(and(eq(taskDependencies.taskId, taskId), eq(taskDependencies.dependsOnTaskId, dependsOnTaskId)))
    .returning({ taskId: taskDependencies.taskId });
  return rows.length > 0;
}

/** 업무를 다른 프로젝트로 옮길 때 — 그 업무가 낀 관계를 모두 지운다(다른 프로젝트 업무와 이어져 있으면 안 된다). */
export async function deleteDependenciesOf(taskId) {
  await db
    .delete(taskDependencies)
    .where(or(eq(taskDependencies.taskId, taskId), eq(taskDependencies.dependsOnTaskId, taskId)));
}

/** [taskIds] 각각의 아직 안 끝난 선행 업무 수 {taskId: n} — 목록 배지("선행 2"). 보관한 선행은 세지 않는다. */
export async function countOpenPredecessors(taskIds) {
  if (taskIds.length === 0) return {};
  const rows = await db
    .select({ taskId: taskDependencies.taskId, n: sql`count(*)::int` })
    .from(taskDependencies)
    .innerJoin(tasks, eq(tasks.id, taskDependencies.dependsOnTaskId))
    .where(
      and(inArray(taskDependencies.taskId, taskIds), ne(tasks.status, 'done'), sql`${tasks.archivedAt} is null`),
    )
    .groupBy(taskDependencies.taskId);
  return Object.fromEntries(rows.map((r) => [r.taskId, r.n ?? 0]));
}

// ── 소요 시간 ───────────────────────────────────────────────────────────

/** [taskIds] 각각의 기록된 시간 합(분) {taskId: 분}. */
export async function sumTimeForTasks(taskIds) {
  if (taskIds.length === 0) return {};
  const rows = await db
    .select({ taskId: taskTimeEntries.taskId, minutes: sql`sum(${taskTimeEntries.minutes})::int` })
    .from(taskTimeEntries)
    .where(inArray(taskTimeEntries.taskId, taskIds))
    .groupBy(taskTimeEntries.taskId);
  return Object.fromEntries(rows.map((r) => [r.taskId, r.minutes ?? 0]));
}

/** 업무의 시간 기록(최근 날짜·최근 기록순, 200개까지) — 누가 남겼는지 이름과 함께. */
export function listTimeEntries(taskId) {
  return db
    .select({
      id: taskTimeEntries.id,
      taskId: taskTimeEntries.taskId,
      userId: taskTimeEntries.userId,
      userName: users.name,
      minutes: taskTimeEntries.minutes,
      workDate: taskTimeEntries.workDate,
      note: taskTimeEntries.note,
      createdAt: taskTimeEntries.createdAt,
    })
    .from(taskTimeEntries)
    .leftJoin(users, eq(users.id, taskTimeEntries.userId))
    .where(eq(taskTimeEntries.taskId, taskId))
    .orderBy(desc(taskTimeEntries.workDate), desc(taskTimeEntries.createdAt))
    .limit(200);
}

export async function insertTimeEntry(fields) {
  const [row] = await db.insert(taskTimeEntries).values(fields).returning();
  return row;
}

export async function findTimeEntryById(id) {
  const [row] = await db.select().from(taskTimeEntries).where(eq(taskTimeEntries.id, id));
  return row ?? null;
}

export async function deleteTimeEntry(id) {
  await db.delete(taskTimeEntries).where(eq(taskTimeEntries.id, id));
}

/** 프로젝트 소요 시간 보고 — [from]~[to](포함) 기록을 사람별·업무별로 묶는다. */
export async function timeReport(projectId, from, to) {
  const where = and(eq(tasks.projectId, projectId), gte(taskTimeEntries.workDate, from), lte(taskTimeEntries.workDate, to));
  const [byMember, byTask] = await Promise.all([
    db
      .select({ userId: taskTimeEntries.userId, name: users.name, minutes: sql`sum(${taskTimeEntries.minutes})::int` })
      .from(taskTimeEntries)
      .innerJoin(tasks, eq(tasks.id, taskTimeEntries.taskId))
      .leftJoin(users, eq(users.id, taskTimeEntries.userId))
      .where(where)
      .groupBy(taskTimeEntries.userId, users.name)
      .orderBy(desc(sql`sum(${taskTimeEntries.minutes})`)),
    db
      .select({
        taskId: tasks.id,
        seq: tasks.seq,
        title: tasks.title,
        estimateMinutes: tasks.estimateMinutes,
        minutes: sql`sum(${taskTimeEntries.minutes})::int`,
      })
      .from(taskTimeEntries)
      .innerJoin(tasks, eq(tasks.id, taskTimeEntries.taskId))
      .where(where)
      .groupBy(tasks.id, tasks.seq, tasks.title, tasks.estimateMinutes)
      .orderBy(desc(sql`sum(${taskTimeEntries.minutes})`))
      .limit(200),
  ]);
  return { byMember, byTask };
}

// ── 타이머 ──────────────────────────────────────────────────────────────

/** 내 타이머와 그 업무·프로젝트(없으면 null). */
export async function findTimerOf(userId) {
  const [row] = await db
    .select({
      userId: taskTimers.userId,
      taskId: taskTimers.taskId,
      startedAt: taskTimers.startedAt,
      title: tasks.title,
      seq: tasks.seq,
      projectId: tasks.projectId,
      projectName: projects.name,
      identifier: projects.identifier,
    })
    .from(taskTimers)
    .innerJoin(tasks, eq(tasks.id, taskTimers.taskId))
    .innerJoin(projects, eq(projects.id, tasks.projectId))
    .where(eq(taskTimers.userId, userId));
  return row ?? null;
}

export async function startTimer(userId, taskId, startedAt = new Date()) {
  const [row] = await db
    .insert(taskTimers)
    .values({ userId, taskId, startedAt })
    .onConflictDoUpdate({ target: taskTimers.userId, set: { taskId, startedAt } })
    .returning();
  return row;
}

/** 내 타이머를 지우고 지운 행을 돌려준다(없었으면 null) — 두 기기에서 동시에 멈춰도 한 번만 기록되게. */
export async function takeTimer(userId) {
  const [row] = await db.delete(taskTimers).where(eq(taskTimers.userId, userId)).returning();
  return row ?? null;
}

// ── 반복 ────────────────────────────────────────────────────────────────

/** 반복 규칙을 이 업무에서 떼어 낸다 — 이 요청이 뗐으면 true(이미 다른 요청이 뗐으면 false). 다음 회차를 한 번만 만들게. */
export async function takeRecurrence(taskId) {
  const rows = await db
    .update(tasks)
    .set({ recurrence: null })
    .where(and(eq(tasks.id, taskId), isNotNull(tasks.recurrence)))
    .returning({ id: tasks.id });
  return rows.length > 0;
}
