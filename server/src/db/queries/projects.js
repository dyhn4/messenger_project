import { and, asc, desc, eq, inArray, isNull, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import {
  projectMembers,
  automationRuns,
  noteComments,
  noteVersions,
  projectAutomations,
  projectNotes,
  projects,
  taskComments,
  taskTemplates,
  taskFields,
  taskPriorities,
  taskReferences,
  tasks,
  taskStatuses,
  taskTypes,
  users,
} from '../schema.js';

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
export function listProjectsForUser(teamId, userId, { archivedOnly = false } = {}) {
  return db
    .select({ project: projects, favorite: projectMembers.favorite, myRole: projectMembers.role })
    .from(projectMembers)
    .innerJoin(projects, eq(projectMembers.projectId, projects.id))
    .where(
      and(
        eq(projectMembers.userId, userId),
        eq(projects.teamId, teamId),
        archivedOnly ? sql`${projects.archivedAt} is not null` : isNull(projects.archivedAt),
      ),
    )
    .orderBy(desc(projectMembers.favorite), asc(projects.name))
    .then((rows) => rows.map((r) => ({ ...r.project, favorite: r.favorite, myRole: r.myRole })));
}

/** 내가 아직 참여하지 않은 이 팀의 공개 프로젝트 목록(구성원 수 포함) — "공개 프로젝트 둘러보기". */
export function listBrowsablePublicProjects(teamId, userId) {
  return db
    .select({
      project: projects,
      memberCount: sql`(select count(*)::int from ${projectMembers} pm where pm.project_id = ${projects.id})`,
    })
    .from(projects)
    .where(
      and(
        eq(projects.teamId, teamId),
        eq(projects.isPublic, true),
        isNull(projects.archivedAt),
        sql`not exists (select 1 from ${projectMembers} pm where pm.project_id = ${projects.id} and pm.user_id = ${userId})`,
      ),
    )
    .orderBy(asc(projects.name))
    .then((rows) => rows.map((r) => ({ ...r.project, memberCount: r.memberCount ?? 0 })));
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

export async function setProjectMemberRole(projectId, userId, role) {
  await db
    .update(projectMembers)
    .set({ role })
    .where(and(eq(projectMembers.projectId, projectId), eq(projectMembers.userId, userId)));
}

export async function countProjectOwners(projectId) {
  const rows = await db
    .select({ userId: projectMembers.userId })
    .from(projectMembers)
    .where(and(eq(projectMembers.projectId, projectId), eq(projectMembers.role, 'owner')));
  return rows.length;
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
export function listTasksForAssignee(teamId, userId, { includeReferenced = false } = {}) {
  // 참조된 업무까지 볼 때는 "내 업무" 화면 — 홈 통계는 담당 업무만 센다.
  const mine = includeReferenced
    ? or(
        eq(tasks.assigneeId, userId),
        sql`exists (select 1 from ${taskReferences} r where r.task_id = ${tasks.id} and r.user_id = ${userId})`,
      )
    : eq(tasks.assigneeId, userId);
  return db
    .select({ task: tasks, projectName: projects.name, projectIdentifier: projects.identifier })
    .from(tasks)
    .innerJoin(projects, eq(tasks.projectId, projects.id))
    .where(and(mine, eq(projects.teamId, teamId), isNull(projects.archivedAt)))
    .orderBy(asc(tasks.dueDate), desc(tasks.createdAt))
    .then((rows) =>
      rows.map((r) => ({ ...r.task, projectName: r.projectName, projectIdentifier: r.projectIdentifier })),
    );
}

/** 내가 참여 중인 모든 프로젝트의 업무(팀 단위) — 전체 캘린더/간트차트가 쓴다. */
export function listTasksInProjects(projectIds) {
  if (projectIds.length === 0) return Promise.resolve([]);
  return db
    .select({ task: tasks, projectName: projects.name, projectIdentifier: projects.identifier })
    .from(tasks)
    .innerJoin(projects, eq(tasks.projectId, projects.id))
    .where(inArray(tasks.projectId, projectIds))
    .orderBy(asc(tasks.dueDate), desc(tasks.createdAt))
    .then((rows) =>
      rows.map((r) => ({ ...r.task, projectName: r.projectName, projectIdentifier: r.projectIdentifier })),
    );
}

// ── 업무 유형 ───────────────────────────────────────────────────────────

/** 새 프로젝트에 기본으로 넣어주는 유형 — 이후 프로젝트 담당자가 자유롭게 고치고 지운다. */
const DEFAULT_TASK_TYPES = [
  { name: 'Bug', color: '#E53935' },
  { name: 'Feature', color: '#1E88E5' },
  { name: 'Improvement', color: '#43A047' },
  { name: '기타', color: '#78909C' },
];

export async function seedDefaultTaskTypes(projectId) {
  await db
    .insert(taskTypes)
    .values(DEFAULT_TASK_TYPES.map((t, i) => ({ projectId, name: t.name, color: t.color, position: i })))
    .onConflictDoNothing();
}

export function listTaskTypes(projectId) {
  return db
    .select()
    .from(taskTypes)
    .where(eq(taskTypes.projectId, projectId))
    .orderBy(asc(taskTypes.position), asc(taskTypes.createdAt));
}

export function listTaskTypesByIds(ids) {
  if (ids.length === 0) return Promise.resolve([]);
  return db.select().from(taskTypes).where(inArray(taskTypes.id, ids));
}

export function findTaskTypeById(id) {
  return db
    .select()
    .from(taskTypes)
    .where(eq(taskTypes.id, id))
    .then((rows) => rows[0] ?? null);
}

export async function insertTaskType(fields) {
  const [{ next }] = await db
    .select({ next: sql`coalesce(max(${taskTypes.position}), -1) + 1` })
    .from(taskTypes)
    .where(eq(taskTypes.projectId, fields.projectId));
  const [row] = await db
    .insert(taskTypes)
    .values({ ...fields, position: Number(next) })
    .returning();
  return row;
}

export async function updateTaskType(id, fields) {
  const [row] = await db.update(taskTypes).set(fields).where(eq(taskTypes.id, id)).returning();
  return row ?? null;
}

export async function deleteTaskType(id) {
  await db.delete(taskTypes).where(eq(taskTypes.id, id));
}

// ── 업무 참조자 ─────────────────────────────────────────────────────────

/** 업무의 참조자를 통째로 바꾼다(빈 배열이면 전부 지운다). */
export async function setTaskReferences(taskId, userIds) {
  await db.delete(taskReferences).where(eq(taskReferences.taskId, taskId));
  if (userIds.length === 0) return;
  await db
    .insert(taskReferences)
    .values(userIds.map((userId) => ({ taskId, userId })))
    .onConflictDoNothing();
}

/** {taskId: [userId,...]} */
export async function listReferencesForTasks(taskIds) {
  if (taskIds.length === 0) return {};
  const rows = await db.select().from(taskReferences).where(inArray(taskReferences.taskId, taskIds));
  const map = {};
  for (const r of rows) (map[r.taskId] ??= []).push(r.userId);
  return map;
}

export function listUsersByIds(ids) {
  if (ids.length === 0) return Promise.resolve([]);
  return db.select().from(users).where(inArray(users.id, ids));
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

// ── 업무 상태 ───────────────────────────────────────────────────────────

const DEFAULT_TASK_STATUSES = [
  { name: '할 일', color: '#94A3B8', category: 'todo' },
  { name: '진행 중', color: '#F59E0B', category: 'doing' },
  { name: '완료', color: '#10B981', category: 'done' },
];

export async function seedDefaultTaskStatuses(projectId) {
  await db
    .insert(taskStatuses)
    .values(DEFAULT_TASK_STATUSES.map((s, i) => ({ projectId, ...s, position: i })))
    .onConflictDoNothing();
}

export function listTaskStatuses(projectId) {
  return db
    .select()
    .from(taskStatuses)
    .where(eq(taskStatuses.projectId, projectId))
    .orderBy(asc(taskStatuses.position), asc(taskStatuses.createdAt));
}

export function listTaskStatusesByIds(ids) {
  if (ids.length === 0) return Promise.resolve([]);
  return db.select().from(taskStatuses).where(inArray(taskStatuses.id, ids));
}

export function findTaskStatusById(id) {
  return db
    .select()
    .from(taskStatuses)
    .where(eq(taskStatuses.id, id))
    .then((rows) => rows[0] ?? null);
}

/** 분류(todo/doing/done)에 속한 첫 번째 상태 — 분류만 알려주는 예전 방식 요청을 상태로 바꿀 때 쓴다. */
export function findFirstStatusOfCategory(projectId, category) {
  return db
    .select()
    .from(taskStatuses)
    .where(and(eq(taskStatuses.projectId, projectId), eq(taskStatuses.category, category)))
    .orderBy(asc(taskStatuses.position), asc(taskStatuses.createdAt))
    .limit(1)
    .then((rows) => rows[0] ?? null);
}

export async function insertTaskStatus(fields) {
  const [{ next }] = await db
    .select({ next: sql`coalesce(max(${taskStatuses.position}), -1) + 1` })
    .from(taskStatuses)
    .where(eq(taskStatuses.projectId, fields.projectId));
  const [row] = await db
    .insert(taskStatuses)
    .values({ ...fields, position: Number(next) })
    .returning();
  return row;
}

export async function updateTaskStatus(id, fields) {
  const [row] = await db.update(taskStatuses).set(fields).where(eq(taskStatuses.id, id)).returning();
  return row ?? null;
}

/** 상태를 지운다 — 그 상태이던 업무는 [replacement] 상태로 옮긴다(분류가 같은 상태여야 한다). */
export async function deleteTaskStatus(id, replacementId) {
  await db.update(tasks).set({ statusId: replacementId }).where(eq(tasks.statusId, id));
  await db.delete(taskStatuses).where(eq(taskStatuses.id, id));
}

/** 열(상태)을 끌어서 순서를 바꿨을 때 — [ids] 순서대로 position을 다시 매긴다. */
export async function reorderTaskStatuses(projectId, ids) {
  for (let i = 0; i < ids.length; i += 1) {
    await db
      .update(taskStatuses)
      .set({ position: i })
      .where(and(eq(taskStatuses.projectId, projectId), eq(taskStatuses.id, ids[i])));
  }
}

// ── 사용자 정의 필드 ────────────────────────────────────────────────────

export function listTaskFields(projectId) {
  return db
    .select()
    .from(taskFields)
    .where(eq(taskFields.projectId, projectId))
    .orderBy(asc(taskFields.position), asc(taskFields.createdAt));
}

export function findTaskFieldById(id) {
  return db
    .select()
    .from(taskFields)
    .where(eq(taskFields.id, id))
    .then((rows) => rows[0] ?? null);
}

export async function insertTaskField(fields) {
  const [{ next }] = await db
    .select({ next: sql`coalesce(max(${taskFields.position}), -1) + 1` })
    .from(taskFields)
    .where(eq(taskFields.projectId, fields.projectId));
  const [row] = await db
    .insert(taskFields)
    .values({ ...fields, position: Number(next) })
    .returning();
  return row;
}

export async function updateTaskField(id, fields) {
  const [row] = await db.update(taskFields).set(fields).where(eq(taskFields.id, id)).returning();
  return row ?? null;
}

export async function deleteTaskField(id) {
  await db.delete(taskFields).where(eq(taskFields.id, id));
}

// ── 프로젝트 노트 ───────────────────────────────────────────────────────

/** 노트 목록(본문 제외) — 프로젝트 이름/색을 같이 붙여서 팀 전체 노트 목록에도 쓴다. */
export function listNotesInProjects(projectIds) {
  if (projectIds.length === 0) return Promise.resolve([]);
  return db
    .select({
      id: projectNotes.id,
      projectId: projectNotes.projectId,
      title: projectNotes.title,
      preview: sql`left(${projectNotes.body}, 140)`,
      createdBy: projectNotes.createdBy,
      updatedBy: projectNotes.updatedBy,
      createdAt: projectNotes.createdAt,
      updatedAt: projectNotes.updatedAt,
      projectName: projects.name,
      projectColor: projects.color,
    })
    .from(projectNotes)
    .innerJoin(projects, eq(projectNotes.projectId, projects.id))
    .where(inArray(projectNotes.projectId, projectIds))
    .orderBy(desc(projectNotes.updatedAt));
}

export function findNoteById(id) {
  return db
    .select()
    .from(projectNotes)
    .where(eq(projectNotes.id, id))
    .then((rows) => rows[0] ?? null);
}

export async function insertNote(fields) {
  const [row] = await db.insert(projectNotes).values(fields).returning();
  return row;
}

export async function updateNote(id, fields) {
  const [row] = await db
    .update(projectNotes)
    .set({ ...fields, updatedAt: new Date() })
    .where(eq(projectNotes.id, id))
    .returning();
  return row ?? null;
}

export async function deleteNote(id) {
  await db.delete(projectNotes).where(eq(projectNotes.id, id));
}

// ── 업무 템플릿 ─────────────────────────────────────────────────────────

export function listTaskTemplates(projectId) {
  return db.select().from(taskTemplates).where(eq(taskTemplates.projectId, projectId)).orderBy(asc(taskTemplates.createdAt));
}

export function findTaskTemplateById(id) {
  return db
    .select()
    .from(taskTemplates)
    .where(eq(taskTemplates.id, id))
    .then((rows) => rows[0] ?? null);
}

export async function insertTaskTemplate(fields) {
  const [row] = await db.insert(taskTemplates).values(fields).returning();
  return row;
}

export async function updateTaskTemplate(id, fields) {
  const [row] = await db.update(taskTemplates).set(fields).where(eq(taskTemplates.id, id)).returning();
  return row ?? null;
}

export async function deleteTaskTemplate(id) {
  await db.delete(taskTemplates).where(eq(taskTemplates.id, id));
}

// ── 자동화 규칙 ─────────────────────────────────────────────────────────

export function listAutomations(projectId, { onlyEnabled = false } = {}) {
  const where = onlyEnabled
    ? and(eq(projectAutomations.projectId, projectId), eq(projectAutomations.enabled, true))
    : eq(projectAutomations.projectId, projectId);
  return db.select().from(projectAutomations).where(where).orderBy(asc(projectAutomations.createdAt));
}

export function findAutomationById(id) {
  return db
    .select()
    .from(projectAutomations)
    .where(eq(projectAutomations.id, id))
    .then((rows) => rows[0] ?? null);
}

export async function insertAutomation(fields) {
  const [row] = await db.insert(projectAutomations).values(fields).returning();
  return row;
}

export async function updateAutomation(id, fields) {
  const [row] = await db.update(projectAutomations).set(fields).where(eq(projectAutomations.id, id)).returning();
  return row ?? null;
}

export async function deleteAutomation(id) {
  await db.delete(projectAutomations).where(eq(projectAutomations.id, id));
}

// ── 노트 댓글 / 수정 이력 ───────────────────────────────────────────────

export function listNoteComments(noteId) {
  return db.select().from(noteComments).where(eq(noteComments.noteId, noteId)).orderBy(asc(noteComments.createdAt));
}

export async function insertNoteComment(fields) {
  const [row] = await db.insert(noteComments).values(fields).returning();
  return row;
}

export function findNoteCommentById(id) {
  return db
    .select()
    .from(noteComments)
    .where(eq(noteComments.id, id))
    .then((rows) => rows[0] ?? null);
}

export async function deleteNoteComment(id) {
  await db.delete(noteComments).where(eq(noteComments.id, id));
}

const NOTE_VERSION_KEEP = 30;

/** [note]의 지금 내용을 이력에 한 줄 남기고, 오래된 것은 30개까지만 남긴다. */
export async function snapshotNoteVersion(note) {
  await db.insert(noteVersions).values({
    noteId: note.id,
    title: note.title,
    body: note.body ?? '',
    editedBy: note.updatedBy ?? note.createdBy ?? null,
    editedAt: note.updatedAt,
  });
  const old = await db
    .select({ id: noteVersions.id })
    .from(noteVersions)
    .where(eq(noteVersions.noteId, note.id))
    .orderBy(desc(noteVersions.editedAt))
    .offset(NOTE_VERSION_KEEP);
  if (old.length > 0) {
    await db.delete(noteVersions).where(inArray(noteVersions.id, old.map((r) => r.id)));
  }
}

/** 이력 목록(본문 제외) — 최근 것부터. */
export function listNoteVersions(noteId) {
  return db
    .select({ id: noteVersions.id, title: noteVersions.title, editedBy: noteVersions.editedBy, editedAt: noteVersions.editedAt })
    .from(noteVersions)
    .where(eq(noteVersions.noteId, noteId))
    .orderBy(desc(noteVersions.editedAt));
}

export function findNoteVersionById(id) {
  return db
    .select()
    .from(noteVersions)
    .where(eq(noteVersions.id, id))
    .then((rows) => rows[0] ?? null);
}

// ── 자동화 실행 기록 ────────────────────────────────────────────────────

const AUTOMATION_RUN_KEEP = 100;

export async function insertAutomationRun(fields) {
  await db.insert(automationRuns).values(fields);
  const old = await db
    .select({ id: automationRuns.id })
    .from(automationRuns)
    .where(eq(automationRuns.projectId, fields.projectId))
    .orderBy(desc(automationRuns.createdAt))
    .offset(AUTOMATION_RUN_KEEP);
  if (old.length > 0) {
    await db.delete(automationRuns).where(inArray(automationRuns.id, old.map((r) => r.id)));
  }
}

export function listAutomationRuns(projectId, limit = 100) {
  return db
    .select()
    .from(automationRuns)
    .where(eq(automationRuns.projectId, projectId))
    .orderBy(desc(automationRuns.createdAt))
    .limit(limit);
}

// ── 업무 우선순위 ───────────────────────────────────────────────────────

/** 위에서부터 높은 순위다(position 순서 = 앱에서 보여주는 순서). level(low/normal/high)은
 * 통계·정렬용 큰 묶음이라 여러 우선순위가 같은 단계를 가질 수 있다 — '긴급'과 '높음'이 둘 다
 * high, '대기'와 '없음'이 '낮음'과 같은 low인 식이다. 기존 프로젝트에도 같은 값이 들어가도록
 * drizzle/0051_task_priority_presets.sql이 한 번 채워준다. */
const DEFAULT_TASK_PRIORITIES = [
  { name: '긴급', color: '#DC2626', level: 'high' },
  { name: '높음', color: '#EF4444', level: 'high' },
  { name: '보통', color: '#5B8DEF', level: 'normal' },
  { name: '낮음', color: '#94A3B8', level: 'low' },
  { name: '대기', color: '#A78BFA', level: 'low' },
  { name: '없음', color: '#CBD5E1', level: 'low' },
];

export async function seedDefaultTaskPriorities(projectId) {
  await db
    .insert(taskPriorities)
    .values(DEFAULT_TASK_PRIORITIES.map((p, i) => ({ projectId, ...p, position: i })))
    .onConflictDoNothing();
}

export function listTaskPriorities(projectId) {
  return db
    .select()
    .from(taskPriorities)
    .where(eq(taskPriorities.projectId, projectId))
    .orderBy(asc(taskPriorities.position), asc(taskPriorities.createdAt));
}

export function listTaskPrioritiesByIds(ids) {
  if (ids.length === 0) return Promise.resolve([]);
  return db.select().from(taskPriorities).where(inArray(taskPriorities.id, ids));
}

export function findTaskPriorityById(id) {
  return db
    .select()
    .from(taskPriorities)
    .where(eq(taskPriorities.id, id))
    .then((rows) => rows[0] ?? null);
}

/** 단계(low/normal/high)에 속한 첫 우선순위 — 단계만 알려주는 예전 방식 요청을 옮길 때 쓴다. */
export function findFirstPriorityOfLevel(projectId, level) {
  return db
    .select()
    .from(taskPriorities)
    .where(and(eq(taskPriorities.projectId, projectId), eq(taskPriorities.level, level)))
    .orderBy(asc(taskPriorities.position), asc(taskPriorities.createdAt))
    .limit(1)
    .then((rows) => rows[0] ?? null);
}

export async function insertTaskPriority(fields) {
  const [{ next }] = await db
    .select({ next: sql`coalesce(max(${taskPriorities.position}), -1) + 1` })
    .from(taskPriorities)
    .where(eq(taskPriorities.projectId, fields.projectId));
  const [row] = await db
    .insert(taskPriorities)
    .values({ ...fields, position: Number(next) })
    .returning();
  return row;
}

export async function updateTaskPriority(id, fields) {
  const [row] = await db.update(taskPriorities).set(fields).where(eq(taskPriorities.id, id)).returning();
  return row ?? null;
}

/** 우선순위를 지운다 — 그 우선순위이던 업무는 [replacementId]로 옮긴다(같은 단계여야 한다). */
export async function deleteTaskPriority(id, replacementId) {
  await db.update(tasks).set({ priorityId: replacementId }).where(eq(tasks.priorityId, id));
  await db.delete(taskPriorities).where(eq(taskPriorities.id, id));
}

export async function reorderTaskPriorities(projectId, ids) {
  for (let i = 0; i < ids.length; i += 1) {
    await db
      .update(taskPriorities)
      .set({ position: i })
      .where(and(eq(taskPriorities.projectId, projectId), eq(taskPriorities.id, ids[i])));
  }
}
