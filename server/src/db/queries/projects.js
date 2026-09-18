import { and, asc, desc, eq, inArray, isNull, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { projectMembers, projects, taskComments, tasks, users } from '../schema.js';

// ── 프로젝트 ────────────────────────────────────────────────────────────

export function findProjectById(id) {
  return db
    .select()
    .from(projects)
    .where(eq(projects.id, id))
    .then((rows) => rows[0] ?? null);
}

export async function insertProject(fields) {
  const [row] = await db.insert(projects).values(fields).returning();
  return row;
}

export async function updateProject(id, fields) {
  const [row] = await db.update(projects).set(fields).where(eq(projects.id, id)).returning();
  return row ?? null;
}

export async function deleteProject(id) {
  await db.delete(projects).where(eq(projects.id, id));
}

/** 같은 팀에서 이 식별자(MKT 등)를 이미 쓰고 있는 프로젝트가 있는지 — 있으면 그 행. */
export function findProjectByIdentifier(teamId, identifier) {
  return db
    .select()
    .from(projects)
    .where(and(eq(projects.teamId, teamId), eq(projects.identifier, identifier)))
    .then((rows) => rows[0] ?? null);
}

/** 내가 참여 중인(초대된) 프로젝트 목록 — 즐겨찾기 여부와 내 역할까지 같이. */
export function listProjectsForUser(teamId, userId) {
  return db
    .select({ project: projects, favorite: projectMembers.favorite, myRole: projectMembers.role })
    .from(projectMembers)
    .innerJoin(projects, eq(projectMembers.projectId, projects.id))
    .where(and(eq(projectMembers.userId, userId), eq(projects.teamId, teamId), isNull(projects.archivedAt)))
    .orderBy(desc(projectMembers.favorite), asc(projects.name))
    .then((rows) => rows.map((r) => ({ ...r.project, favorite: r.favorite, myRole: r.myRole })));
}

/** 프로젝트별 업무 개수({projectId: {total, done}}) — 목록의 진행률 막대에 쓴다. */
export async function countTasksByProject(projectIds) {
  if (projectIds.length === 0) return {};
  const rows = await db
    .select({
      projectId: tasks.projectId,
      total: sql`count(*)::int`,
      done: sql`count(*) filter (where ${tasks.status} = 'done')::int`,
    })
    .from(tasks)
    .where(inArray(tasks.projectId, projectIds))
    .groupBy(tasks.projectId);
  const map = {};
  for (const r of rows) map[r.projectId] = { total: r.total ?? 0, done: r.done ?? 0 };
  return map;
}

// ── 구성원 ──────────────────────────────────────────────────────────────

export function isProjectMember(projectId, userId) {
  return db
    .select({ userId: projectMembers.userId })
    .from(projectMembers)
    .where(and(eq(projectMembers.projectId, projectId), eq(projectMembers.userId, userId)))
    .then((rows) => rows.length > 0);
}

export function getProjectRole(projectId, userId) {
  return db
    .select({ role: projectMembers.role })
    .from(projectMembers)
    .where(and(eq(projectMembers.projectId, projectId), eq(projectMembers.userId, userId)))
    .then((rows) => rows[0]?.role ?? null);
}

export async function addProjectMembers(projectId, userIds, role = 'member') {
  if (userIds.length === 0) return;
  await db
    .insert(projectMembers)
    .values(userIds.map((userId) => ({ projectId, userId, role })))
    .onConflictDoNothing();
}

export async function removeProjectMember(projectId, userId) {
  await db
    .delete(projectMembers)
    .where(and(eq(projectMembers.projectId, projectId), eq(projectMembers.userId, userId)));
}

export function listProjectMemberIds(projectId) {
  return db
    .select({ userId: projectMembers.userId })
    .from(projectMembers)
    .where(eq(projectMembers.projectId, projectId))
    .then((rows) => rows.map((r) => r.userId));
}

/** 구성원 목록을 실제 사용자 행 + 프로젝트 역할로. */
export function listProjectMemberUsers(projectId) {
  return db
    .select({ user: users, role: projectMembers.role })
    .from(projectMembers)
    .innerJoin(users, eq(projectMembers.userId, users.id))
    .where(eq(projectMembers.projectId, projectId))
    .then((rows) => rows.map((r) => ({ ...r.user, projectRole: r.role })));
}

export async function setProjectFavorite(projectId, userId, favorite) {
  await db
    .update(projectMembers)
    .set({ favorite })
    .where(and(eq(projectMembers.projectId, projectId), eq(projectMembers.userId, userId)));
}

// ── 업무 ────────────────────────────────────────────────────────────────

/** 업무 번호를 하나 발급받는다(projects.nextTaskSeq를 원자적으로 +1) — 삭제된 번호는 재사용 안 한다. */
export async function takeNextTaskSeq(projectId) {
  const [row] = await db
    .update(projects)
    .set({ nextTaskSeq: sql`${projects.nextTaskSeq} + 1` })
    .where(eq(projects.id, projectId))
    .returning({ seq: projects.nextTaskSeq });
  // returning은 갱신 **후** 값이라 방금 발급할 번호는 그보다 하나 작다.
  return (row?.seq ?? 1) - 1;
}

export async function insertTask(fields) {
  const [row] = await db.insert(tasks).values(fields).returning();
  return row;
}

export function findTaskById(id) {
  return db
    .select()
    .from(tasks)
    .where(eq(tasks.id, id))
    .then((rows) => rows[0] ?? null);
}

export async function updateTask(id, fields) {
  const [row] = await db
    .update(tasks)
    .set({ ...fields, updatedAt: new Date() })
    .where(eq(tasks.id, id))
    .returning();
  return row ?? null;
}

export async function deleteTask(id) {
  await db.delete(tasks).where(eq(tasks.id, id));
}

export function listTasksByProject(projectId) {
  return db
    .select()
    .from(tasks)
    .where(eq(tasks.projectId, projectId))
    .orderBy(asc(tasks.status), asc(tasks.dueDate), desc(tasks.createdAt));
}

/**
 * 내가 담당자인 업무 전부(이 팀의 프로젝트에 한정) — 대시보드의 "내가 담당한 업무"와
 * "이번 주 나의 업무"가 같은 목록을 쓰고, 주간 필터는 클라이언트가 날짜로 나눈다.
 * 프로젝트 이름/식별자를 같이 실어서 목록에 "MKT-1001 · 신제품 런칭 캠페인"을 바로 그린다.
 */
export function listTasksForAssignee(teamId, userId) {
  return db
    .select({ task: tasks, projectName: projects.name, projectIdentifier: projects.identifier })
    .from(tasks)
    .innerJoin(projects, eq(tasks.projectId, projects.id))
    .where(and(eq(tasks.assigneeId, userId), eq(projects.teamId, teamId), isNull(projects.archivedAt)))
    .orderBy(asc(tasks.dueDate), desc(tasks.createdAt))
    .then((rows) =>
      rows.map((r) => ({ ...r.task, projectName: r.projectName, projectIdentifier: r.projectIdentifier })),
    );
}

// ── 업무 댓글 ───────────────────────────────────────────────────────────

export async function insertTaskComment(fields) {
  const [row] = await db.insert(taskComments).values(fields).returning();
  return row;
}

export function listTaskComments(taskId) {
  return db.select().from(taskComments).where(eq(taskComments.taskId, taskId)).orderBy(asc(taskComments.createdAt));
}

/** 대시보드 "최근 댓글" — 내가 참여 중인 프로젝트들의 업무 댓글을 최신순으로 몇 건만. */
export function listRecentTaskComments(projectIds, limit = 10) {
  if (projectIds.length === 0) return Promise.resolve([]);
  return db
    .select({
      comment: taskComments,
      taskTitle: tasks.title,
      taskSeq: tasks.seq,
      projectName: projects.name,
      projectIdentifier: projects.identifier,
    })
    .from(taskComments)
    .innerJoin(tasks, eq(taskComments.taskId, tasks.id))
    .innerJoin(projects, eq(taskComments.projectId, projects.id))
    .where(inArray(taskComments.projectId, projectIds))
    .orderBy(desc(taskComments.createdAt))
    .limit(limit)
    .then((rows) =>
      rows.map((r) => ({
        ...r.comment,
        taskTitle: r.taskTitle,
        taskSeq: r.taskSeq,
        projectName: r.projectName,
        projectIdentifier: r.projectIdentifier,
      })),
    );
}
