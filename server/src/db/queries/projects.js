import { and, asc, desc, eq, inArray, isNull, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import {
  projectFolderItems,
  projectFolders,
  projectMembers,
  teamMembers,
  projectTemplates,
  automationRuns,
  noteComments,
  noteVersions,
  projectAutomations,
  projectNotes,
  projects,
  taskActivities,
  taskChecklistItems,
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

/** 공개 프로젝트 자동 참여 대상 = 계정 등급 정회원 이상이고 탈퇴·정지되지 않은 사람([alias]는 users 별칭). */
function eligibleUser(alias) {
  return sql.raw(
    `${alias}.role in ('member', 'admin') and ${alias}.deleted_at is null and ${alias}.suspended_at is null`,
  );
}

/**
 * 지금도 유효한 구성원 행인지 — 그 프로젝트의 팀에 아직 있어야 하고, 자동 참여 행(auto)은 정회원
 * 이상일 때만 유효하다. 팀에서 빠졌거나 자격을 잃은 사람의 남은 행은 없는 것으로 봐서 접근·담당자
 * 선택·알림에서 모두 빠지게 한다(행 자체는 지우지 않으므로 다시 팀에 들어오면 초대받은 자리는 살아난다).
 */
function activeMembership(projectIdCol, userIdCol, autoCol) {
  return sql`exists (
    select 1 from ${projects} amp
    join ${teamMembers} amt on amt.team_id = amp.team_id and amt.user_id = ${userIdCol}
    join ${users} amu on amu.id = amt.user_id
    where amp.id = ${projectIdCol} and (not ${autoCol} or ${eligibleUser('amu')}))`;
}

const ACTIVE_PROJECT_MEMBER = activeMembership(projectMembers.projectId, projectMembers.userId, projectMembers.auto);

export function isProjectMember(projectId, userId) {
  return db
    .select({ userId: projectMembers.userId })
    .from(projectMembers)
    .where(and(eq(projectMembers.projectId, projectId), eq(projectMembers.userId, userId), ACTIVE_PROJECT_MEMBER))
    .then((rows) => rows.length > 0);
}

/**
 * [userIds] 중 지금 이 프로젝트의 (유효한) 구성원만 — 알림 대상 거르기용, 한 번의 쿼리로.
 * 비공개 전환·팀 탈퇴로 빠진 사람이 담당·참조로 남아 있어도 업무 내용이 가지 않게 한다.
 */
export async function filterActiveProjectMembers(projectId, userIds) {
  if (userIds.length === 0) return [];
  const rows = await db
    .select({ userId: projectMembers.userId })
    .from(projectMembers)
    .where(and(eq(projectMembers.projectId, projectId), inArray(projectMembers.userId, userIds), ACTIVE_PROJECT_MEMBER));
  const active = new Set(rows.map((r) => r.userId));
  return userIds.filter((id) => active.has(id));
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
    .where(and(eq(projectMembers.projectId, projectId), ACTIVE_PROJECT_MEMBER))
    .then((rows) => rows.map((r) => r.userId));
}

/**
 * 구성원 목록을 실제 사용자 행 + 프로젝트 역할(+공개 프로젝트라 자동으로 들어왔는지)로.
 * 팀에서 빠진 사람의 남은 행은 빼서 담당자·참조자 선택에 나오지 않게 한다.
 */
export function listProjectMemberUsers(projectId) {
  return db
    .select({ user: users, role: projectMembers.role, auto: projectMembers.auto })
    .from(projectMembers)
    .innerJoin(users, eq(projectMembers.userId, users.id))
    .where(and(eq(projectMembers.projectId, projectId), ACTIVE_PROJECT_MEMBER))
    .then((rows) => rows.map((r) => ({ ...r.user, projectRole: r.role, projectAuto: r.auto })));
}

// ── 공개 프로젝트 자동 참여 ─────────────────────────────────────────────
// 공개 프로젝트는 정회원 이상 팀원 모두가 참여 절차 없이 쓴다. 권한 확인·목록·알림·담당자 선택이
// 전부 project_members를 보므로, 가상으로 계산하지 않고 실제 행(auto = true)을 채워 둔다.
// 넣는 문장들은 같은 문장 안에서 projects 행의 공개·종료 여부를 다시 보고 그 행을 잠근다(for share) —
// 먼저 읽어 둔 프로젝트 객체만 믿으면 방금 비공개로 바뀐 프로젝트에 팀 전체를 다시 넣을 수 있다.

/** 자동 참여 대상 = 계정 등급 정회원 이상이고 탈퇴·정지되지 않은 사람(u는 users 별칭). */
const PUBLIC_ELIGIBLE_USER = eligibleUser('u');

/**
 * 공개(종료 안 된) 프로젝트에 아직 없는 정회원 이상 팀원을 한 번에 넣는다.
 * 새로 들어간 사람 id들을 돌려준다(사이드바 갱신 알림용).
 */
export async function ensurePublicProjectMembers(project) {
  if (!project?.isPublic || project.archivedAt) return [];
  const result = await db.execute(sql`
    insert into ${projectMembers} (project_id, user_id, role, auto)
    select p.id, u.id, 'member', true
    from ${projects} p
    join ${teamMembers} tm on tm.team_id = p.team_id
    join ${users} u on u.id = tm.user_id
    where p.id = ${project.id} and p.is_public and p.archived_at is null and ${PUBLIC_ELIGIBLE_USER}
    for share of p
    on conflict do nothing
    returning user_id`);
  return result.rows.map((r) => r.user_id);
}

/**
 * 이 사람이 아직 안 들어간 이 팀의 공개 프로젝트 전부에 넣는다 — 목록을 불러올 때마다 불러서
 * 예전에 만든 공개 프로젝트, 나중에 팀에 들어오거나 정회원으로 올라온 사람까지 채운다.
 */
export async function ensurePublicMembershipsForUser(teamId, userId) {
  const result = await db.execute(sql`
    insert into ${projectMembers} (project_id, user_id, role, auto)
    select p.id, u.id, 'member', true
    from ${projects} p
    join ${teamMembers} tm on tm.team_id = p.team_id and tm.user_id = ${userId}
    join ${users} u on u.id = tm.user_id
    where p.team_id = ${teamId} and p.is_public and p.archived_at is null and ${PUBLIC_ELIGIBLE_USER}
    for share of p
    on conflict do nothing
    returning project_id`);
  return result.rows.map((r) => r.project_id);
}

/**
 * 공개 프로젝트에 한 사람만 넣어 본다(목록보다 링크·알림으로 먼저 연 경우). 넣었거나 이미
 * 구성원이면 true, 자격이 없으면(비공개·종료·준회원·다른 팀) false.
 */
export async function joinPublicProjectAutomatically(project, userId) {
  if (!project?.isPublic || project.archivedAt) return false;
  const result = await db.execute(sql`
    insert into ${projectMembers} (project_id, user_id, role, auto)
    select p.id, u.id, 'member', true
    from ${projects} p
    join ${teamMembers} tm on tm.team_id = p.team_id and tm.user_id = ${userId}
    join ${users} u on u.id = tm.user_id
    where p.id = ${project.id} and p.is_public and p.archived_at is null and ${PUBLIC_ELIGIBLE_USER}
    for share of p
    on conflict do nothing
    returning user_id`);
  return result.rows.length > 0 || isProjectMember(project.id, userId);
}

/** 이 팀에서 공개 프로젝트에 자동으로 들어가는 사람인지(정회원 이상 팀원). */
export async function isPublicProjectEligible(teamId, userId) {
  const result = await db.execute(sql`
    select 1 from ${teamMembers} tm
    join ${users} u on u.id = tm.user_id
    where tm.team_id = ${teamId} and tm.user_id = ${userId} and ${PUBLIC_ELIGIBLE_USER}
    limit 1`);
  return result.rows.length > 0;
}

/** 공개 프로젝트에 자동으로 들어가는 팀원 id 전부 — "공개 프로젝트 생성" 알림 대상. */
export async function listPublicEligibleUserIds(teamId) {
  const result = await db.execute(sql`
    select tm.user_id from ${teamMembers} tm
    join ${users} u on u.id = tm.user_id
    where tm.team_id = ${teamId} and ${PUBLIC_ELIGIBLE_USER}`);
  return result.rows.map((r) => r.user_id);
}

/**
 * 비공개로 바뀔 때 — 자동으로 들어왔던 일반 구성원만 뺀다(초대받은 사람·담당자는 남는다).
 * 빠진 사람 id들을 돌려준다(사이드바에서 사라지도록 알리는 용도).
 */
export async function removeAutoMembers(projectId) {
  const rows = await db
    .delete(projectMembers)
    .where(and(eq(projectMembers.projectId, projectId), eq(projectMembers.auto, true), eq(projectMembers.role, 'member')))
    .returning({ userId: projectMembers.userId });
  // 담당자라서 남은 사람은 이제 비공개 프로젝트의 구성원이다 — 자동 표시를 지워서, 나중에 담당자에서
  // 내려온 뒤 다시 공개→비공개가 되어도 조용히 빠지지 않게 한다.
  await db
    .update(projectMembers)
    .set({ auto: false })
    .where(and(eq(projectMembers.projectId, projectId), eq(projectMembers.auto, true)));
  return rows.map((r) => r.userId);
}

// ── 프로젝트 폴더(개인 설정) ────────────────────────────────────────────

/**
 * 내 폴더 목록 + 폴더마다 들어 있는 프로젝트 id(position, 만든 순). 내가 더 이상 구성원이
 * 아닌 프로젝트는 빼고 돌려준다(빠졌다가 다시 들어오면 원래 폴더로 돌아온다).
 */
export async function listProjectFolders(teamId, userId) {
  const folders = await db
    .select()
    .from(projectFolders)
    .where(and(eq(projectFolders.teamId, teamId), eq(projectFolders.userId, userId)))
    .orderBy(asc(projectFolders.position), asc(projectFolders.createdAt));
  if (folders.length === 0) return [];
  const items = await db
    .select({ folderId: projectFolderItems.folderId, projectId: projectFolderItems.projectId })
    .from(projectFolderItems)
    .innerJoin(
      projectMembers,
      and(eq(projectMembers.projectId, projectFolderItems.projectId), eq(projectMembers.userId, userId)),
    )
    .innerJoin(projects, eq(projects.id, projectFolderItems.projectId))
    .where(
      and(
        eq(projectFolderItems.userId, userId),
        inArray(
          projectFolderItems.folderId,
          folders.map((f) => f.id),
        ),
      ),
    )
    .orderBy(asc(projects.name));
  const byFolder = new Map(folders.map((f) => [f.id, []]));
  for (const it of items) byFolder.get(it.folderId)?.push(it.projectId);
  return folders.map((f) => ({ ...f, projectIds: byFolder.get(f.id) ?? [] }));
}

export async function countProjectFolders(teamId, userId) {
  const [row] = await db
    .select({ n: sql`count(*)::int` })
    .from(projectFolders)
    .where(and(eq(projectFolders.teamId, teamId), eq(projectFolders.userId, userId)));
  return row?.n ?? 0;
}

/** 새 폴더는 맨 아래(가장 큰 position + 1)에 붙는다. */
export async function insertProjectFolder({ teamId, userId, name }) {
  const [{ next }] = await db
    .select({ next: sql`coalesce(max(${projectFolders.position}), -1) + 1` })
    .from(projectFolders)
    .where(and(eq(projectFolders.teamId, teamId), eq(projectFolders.userId, userId)));
  const [row] = await db
    .insert(projectFolders)
    .values({ teamId, userId, name, position: Number(next) })
    .returning();
  return row;
}

export function findProjectFolderById(id) {
  return db
    .select()
    .from(projectFolders)
    .where(eq(projectFolders.id, id))
    .then((rows) => rows[0] ?? null);
}

export async function updateProjectFolder(id, fields) {
  const [row] = await db.update(projectFolders).set(fields).where(eq(projectFolders.id, id)).returning();
  return row ?? null;
}

/** 폴더만 지운다 — 안의 프로젝트 배치(project_folder_items)는 cascade로 같이 사라져 목록으로 돌아간다. */
export async function deleteProjectFolder(id) {
  await db.delete(projectFolders).where(eq(projectFolders.id, id));
}

/** 폴더 하나에 들어 있는 (내가 구성원인) 프로젝트 id들 — 폴더 하나를 돌려줄 때 쓴다. */
export function listFolderProjectIds(folderId, userId) {
  return db
    .select({ projectId: projectFolderItems.projectId })
    .from(projectFolderItems)
    .innerJoin(
      projectMembers,
      and(eq(projectMembers.projectId, projectFolderItems.projectId), eq(projectMembers.userId, userId)),
    )
    .innerJoin(projects, eq(projects.id, projectFolderItems.projectId))
    .where(and(eq(projectFolderItems.folderId, folderId), eq(projectFolderItems.userId, userId)))
    .orderBy(asc(projects.name))
    .then((rows) => rows.map((r) => r.projectId));
}

/**
 * 내 폴더 배치를 바꾼다 — [folderId]가 null이면 어느 폴더에서든 뺀다. 한 프로젝트는 내 폴더
 * 하나에만 들어가므로(user_id, project_id 유일) 다른 폴더에 있었으면 옮겨진다.
 */
export async function setProjectFolder(userId, projectId, folderId) {
  if (folderId == null) {
    await db
      .delete(projectFolderItems)
      .where(and(eq(projectFolderItems.userId, userId), eq(projectFolderItems.projectId, projectId)));
    return;
  }
  await db
    .insert(projectFolderItems)
    .values({ userId, projectId, folderId })
    .onConflictDoUpdate({
      target: [projectFolderItems.userId, projectFolderItems.projectId],
      set: { folderId },
    });
}

export async function setProjectFavorite(projectId, userId, favorite) {
  await db
    .update(projectMembers)
    .set({ favorite })
    .where(and(eq(projectMembers.projectId, projectId), eq(projectMembers.userId, userId)));
}

// ── 업무 ────────────────────────────────────────────────────────────────

/** 노트 번호를 하나 발급받는다(projects.nextNoteSeq를 원자적으로 +1). */
export async function takeNextNoteSeq(projectId) {
  const [row] = await db
    .update(projects)
    .set({ nextNoteSeq: sql`${projects.nextNoteSeq} + 1` })
    .where(eq(projects.id, projectId))
    .returning({ seq: projects.nextNoteSeq });
  return (row?.seq ?? 1) - 1;
}

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

/** 지운 행이 있었는지 돌려준다 — 같은 업무를 동시에 지우는 요청 중 실제로 지운 쪽만 뒤처리를 한다. */
export async function deleteTask(id) {
  const rows = await db.delete(tasks).where(eq(tasks.id, id)).returning({ id: tasks.id });
  return rows.length > 0;
}

/** 보관한 업무는 기본으로 빼고 보여준다 — [archivedOnly]면 보관한 것만. */
/**
 * [archivedOnly]면 보관한 업무만, [includeArchived]면 보관한 업무까지 전부(리스트 탭이 흐리게
 * 보여준다), 둘 다 아니면 보관 안 한 업무만.
 */
export function listTasksByProject(projectId, { archivedOnly = false, includeArchived = false } = {}) {
  return db
    .select()
    .from(tasks)
    .where(
      and(
        eq(tasks.projectId, projectId),
        includeArchived
          ? undefined
          : archivedOnly
            ? sql`${tasks.archivedAt} is not null`
            : isNull(tasks.archivedAt),
      ),
    )
    .orderBy(asc(tasks.status), asc(tasks.dueDate), desc(tasks.createdAt));
}

/**
 * 내가 담당자인 업무 전부(이 팀의 프로젝트에 한정) — 대시보드의 "내가 담당한 업무"와
 * "이번 주 나의 업무"가 같은 목록을 쓰고, 주간 필터는 클라이언트가 날짜로 나눈다.
 * 프로젝트 이름/식별자를 같이 실어서 목록에 "MKT-1001 · 신제품 런칭 캠페인"을 바로 그린다.
 */
/** [includeArchived]면 보관한 업무도 넣는다("내 업무" 표가 흐리게 보여준다). 종료된 프로젝트는 늘 뺀다. */
export function listTasksForAssignee(teamId, userId, { includeReferenced = false, includeArchived = false } = {}) {
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
    .where(
      and(
        mine,
        eq(projects.teamId, teamId),
        isNull(projects.archivedAt),
        includeArchived ? undefined : isNull(tasks.archivedAt),
        // 비공개로 바뀌거나 구성원에서 빠진 프로젝트의 업무는 담당·참조로 남아 있어도 보여주지 않는다.
        sql`exists (select 1 from ${projectMembers} pm where pm.project_id = ${tasks.projectId} and pm.user_id = ${userId})`,
      ),
    )
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
    .where(and(inArray(tasks.projectId, projectIds), isNull(tasks.archivedAt)))
    .orderBy(asc(tasks.dueDate), desc(tasks.createdAt))
    .then((rows) =>
      rows.map((r) => ({ ...r.task, projectName: r.projectName, projectIdentifier: r.projectIdentifier })),
    );
}

/** 이 업무들 각각의 하위 업무 개수 {taskId: n} — 목록에서 "하위 업무 2" 같은 표시에 쓴다. */
export async function countSubtasks(taskIds) {
  if (taskIds.length === 0) return {};
  const rows = await db
    .select({ parentTaskId: tasks.parentTaskId, n: sql`count(*)::int` })
    .from(tasks)
    .where(and(inArray(tasks.parentTaskId, taskIds), isNull(tasks.archivedAt)))
    .groupBy(tasks.parentTaskId);
  const map = {};
  for (const r of rows) map[r.parentTaskId] = r.n ?? 0;
  return map;
}

/** 칸반 한 열의 카드 순서 저장 — ids 순서대로 boardPosition을 0부터 다시 매긴다. */
export async function reorderTasks(projectId, ids) {
  for (let i = 0; i < ids.length; i += 1) {
    await db
      .update(tasks)
      .set({ boardPosition: i })
      .where(and(eq(tasks.projectId, projectId), eq(tasks.id, ids[i])));
  }
}

// ── 프로젝트 템플릿 ─────────────────────────────────────────────────────

export function listProjectTemplates(teamId) {
  return db
    .select()
    .from(projectTemplates)
    .where(eq(projectTemplates.teamId, teamId))
    .orderBy(asc(projectTemplates.createdAt));
}

export async function findProjectTemplateById(id) {
  const [row] = await db.select().from(projectTemplates).where(eq(projectTemplates.id, id));
  return row ?? null;
}

export async function insertProjectTemplate(fields) {
  const [row] = await db.insert(projectTemplates).values(fields).returning();
  return row;
}

export async function updateProjectTemplate(id, fields) {
  const [row] = await db
    .update(projectTemplates)
    .set({ ...fields, updatedAt: new Date() })
    .where(eq(projectTemplates.id, id))
    .returning();
  return row ?? null;
}

export async function deleteProjectTemplate(id) {
  await db.delete(projectTemplates).where(eq(projectTemplates.id, id));
}

/** 새 프로젝트를 템플릿 구성(상태·유형·우선순위·필드)으로 채운다 — 기본값 대신 쓴다. */
export async function applyProjectTemplate(projectId, template) {
  const rows = (list, map) => list.map((item, i) => ({ projectId, ...map(item), position: i }));
  if (template.statuses.length > 0) {
    await db.insert(taskStatuses).values(
      rows(template.statuses, (s) => ({ name: s.name, color: s.color, category: s.category })),
    );
  }
  if (template.types.length > 0) {
    await db.insert(taskTypes).values(rows(template.types, (t) => ({ name: t.name, color: t.color })));
  }
  if (template.priorities.length > 0) {
    await db.insert(taskPriorities).values(
      rows(template.priorities, (p) => ({ name: p.name, color: p.color, level: p.level })),
    );
  }
  if (template.fields.length > 0) {
    await db.insert(taskFields).values(
      rows(template.fields, (f) => ({ name: f.name, kind: f.kind, options: f.options ?? [] })),
    );
  }
}

/** 업무별 댓글 수(답글 포함) — 칸반 카드의 말풍선 숫자. */
export async function countTaskComments(taskIds) {
  if (taskIds.length === 0) return {};
  const rows = await db
    .select({ taskId: taskComments.taskId, n: sql`count(*)::int` })
    .from(taskComments)
    .where(inArray(taskComments.taskId, taskIds))
    .groupBy(taskComments.taskId);
  const map = {};
  for (const r of rows) map[r.taskId] = r.n ?? 0;
  return map;
}

/** 부모의 하위 업무들 — 상세 화면에서 보여준다(보관한 것은 뺀다). */
/** [includeArchived]면 보관한 하위 업무도(업무 상세가 흐리게 보여주고, 삭제 안내 개수에도 넣는다). */
export function listSubtasks(parentTaskId, { includeArchived = false } = {}) {
  return db
    .select()
    .from(tasks)
    .where(and(eq(tasks.parentTaskId, parentTaskId), includeArchived ? undefined : isNull(tasks.archivedAt)))
    .orderBy(asc(tasks.createdAt));
}

export async function setTaskArchived(id, archived) {
  const [row] = await db
    .update(tasks)
    .set({ archivedAt: archived ? new Date() : null })
    .where(eq(tasks.id, id))
    .returning();
  return row ?? null;
}

// ── 체크리스트 ──────────────────────────────────────────────────────────

export function listChecklistItems(taskId) {
  return db
    .select()
    .from(taskChecklistItems)
    .where(eq(taskChecklistItems.taskId, taskId))
    .orderBy(asc(taskChecklistItems.position), asc(taskChecklistItems.createdAt));
}

/** 업무별 체크리스트 진행 {taskId: {done, total}} — 목록/상세의 "2/4"에 쓴다. */
export async function countChecklistItems(taskIds) {
  if (taskIds.length === 0) return {};
  const rows = await db
    .select({
      taskId: taskChecklistItems.taskId,
      total: sql`count(*)::int`,
      done: sql`count(*) filter (where ${taskChecklistItems.done})::int`,
    })
    .from(taskChecklistItems)
    .where(inArray(taskChecklistItems.taskId, taskIds))
    .groupBy(taskChecklistItems.taskId);
  const map = {};
  for (const r of rows) map[r.taskId] = { done: r.done ?? 0, total: r.total ?? 0 };
  return map;
}

/**
 * 체크리스트를 바꾸고({ result }), 이 변경으로 "항목 1개 이상, 전부 완료"가 막 됐는지
 * ({ completed }) 알려준다. 같은 업무의 동시 변경이 둘 다 전환으로 보이지 않게 업무 행을 잠근
 * 트랜잭션 안에서 전후를 본다 — [mutate]는 받은 tx로 고치고, 자동화는 커밋한 뒤 부른 쪽이 돌린다.
 */
export function mutateChecklist(taskId, mutate) {
  return db.transaction(async (tx) => {
    await tx.select({ id: tasks.id }).from(tasks).where(eq(tasks.id, taskId)).for('update');
    const allDone = async () => {
      const rows = await tx
        .select({ done: taskChecklistItems.done })
        .from(taskChecklistItems)
        .where(eq(taskChecklistItems.taskId, taskId));
      return rows.length > 0 && rows.every((r) => r.done);
    };
    const wasDone = await allDone();
    const result = await mutate(tx);
    return { result, completed: !wasDone && (await allDone()) };
  });
}

export async function insertChecklistItem(taskId, text, tx = db) {
  const [{ next }] = await tx
    .select({ next: sql`coalesce(max(${taskChecklistItems.position}), -1) + 1` })
    .from(taskChecklistItems)
    .where(eq(taskChecklistItems.taskId, taskId));
  const [row] = await tx
    .insert(taskChecklistItems)
    .values({ taskId, text, position: Number(next) })
    .returning();
  return row;
}

export function findChecklistItemById(id) {
  return db
    .select()
    .from(taskChecklistItems)
    .where(eq(taskChecklistItems.id, id))
    .then((rows) => rows[0] ?? null);
}

export async function updateChecklistItem(id, fields, tx = db) {
  const [row] = await tx
    .update(taskChecklistItems)
    .set(fields)
    .where(eq(taskChecklistItems.id, id))
    .returning();
  return row ?? null;
}

export async function deleteChecklistItem(id, tx = db) {
  await tx.delete(taskChecklistItems).where(eq(taskChecklistItems.id, id));
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

/** 유형 순서 저장 — ids 순서대로 position을 0부터 다시 매긴다(상태·우선순위와 같은 방식). */
export async function reorderTaskTypes(projectId, ids) {
  for (let i = 0; i < ids.length; i += 1) {
    await db
      .update(taskTypes)
      .set({ position: i })
      .where(and(eq(taskTypes.projectId, projectId), eq(taskTypes.id, ids[i])));
  }
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

export async function findTaskCommentById(id) {
  const [row] = await db.select().from(taskComments).where(eq(taskComments.id, id));
  return row ?? null;
}

export async function updateTaskCommentText(id, text, textFormat = null) {
  const [row] = await db
    .update(taskComments)
    .set({ text, textFormat, editedAt: new Date() })
    .where(eq(taskComments.id, id))
    .returning();
  return row ?? null;
}

/** 댓글을 지운다 — 거기 달린 답글도 FK cascade로 같이 지워진다. */
export async function deleteTaskComment(id) {
  await db.delete(taskComments).where(eq(taskComments.id, id));
}

// ── 업무 기록 ───────────────────────────────────────────────────────────

export async function insertTaskActivities(rows) {
  if (rows.length === 0) return;
  await db.insert(taskActivities).values(rows);
}

/** 기록 탭 — 최신이 위로. */
export function listTaskActivities(taskId, limit = 200) {
  return db
    .select()
    .from(taskActivities)
    .where(eq(taskActivities.taskId, taskId))
    .orderBy(desc(taskActivities.createdAt))
    .limit(limit);
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
      seq: projectNotes.seq,
      preview: sql`left(${projectNotes.body}, 140)`,
      createdBy: projectNotes.createdBy,
      updatedBy: projectNotes.updatedBy,
      createdAt: projectNotes.createdAt,
      updatedAt: projectNotes.updatedAt,
      projectName: projects.name,
      projectColor: projects.color,
      projectIdentifier: projects.identifier,
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

export async function updateNoteCommentText(id, text, textFormat = null) {
  const [row] = await db
    .update(noteComments)
    .set({ text, textFormat, editedAt: new Date() })
    .where(eq(noteComments.id, id))
    .returning();
  return row ?? null;
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
