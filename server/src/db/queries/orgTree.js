import { and, asc, count, eq, inArray, isNotNull, isNull } from 'drizzle-orm';
import { db } from '../client.js';
import { departmentMemberships, departments, teamMembers, teams, users } from '../schema.js';

// 조직도(부서 트리) — 범위 키([scopeKey])가 'server'면 회사 하나(사람 칸은 users), 팀 id면 그 팀(사람 칸은 team_members).

/** 모든 팀 id — 팀 단위 조직도의 예전 글자 부서를 잇는 데(orgTree.js backfillOrgTrees). */
export function listAllTeamIds() {
  return db
    .select({ id: teams.id })
    .from(teams)
    .then((rows) => rows.map((r) => r.id));
}

export function listDepartments(scopeKey) {
  return db
    .select()
    .from(departments)
    .where(eq(departments.scopeKey, scopeKey))
    .orderBy(asc(departments.sortOrder), asc(departments.createdAt));
}

export async function findDepartment(id) {
  const [row] = await db.select().from(departments).where(eq(departments.id, id)).limit(1);
  return row ?? null;
}

/** 같은 범위에서 이름이 같은 부서(여럿이면 먼저 만든 것) — 예전 자유 글자 부서를 트리에 잇는 데 쓴다. */
export async function findDepartmentByName(scopeKey, name) {
  const [row] = await db
    .select()
    .from(departments)
    .where(and(eq(departments.scopeKey, scopeKey), eq(departments.name, name)))
    .orderBy(asc(departments.createdAt))
    .limit(1);
  return row ?? null;
}

export async function countDepartments(scopeKey) {
  const [row] = await db.select({ n: count() }).from(departments).where(eq(departments.scopeKey, scopeKey));
  return row?.n ?? 0;
}

export async function insertDepartment(fields) {
  const [row] = await db.insert(departments).values(fields).returning();
  return row;
}

export async function updateDepartment(id, patch) {
  const [row] = await db.update(departments).set(patch).where(eq(departments.id, id)).returning();
  return row ?? null;
}

/** 부서 지우기 — 하위 부서는 [parentId]로 올리고 지운다(한 트랜잭션). 구성원 옮기기는 호출부가 먼저 한다(moveDepartmentMembers). */
export async function deleteDepartment(id, parentId) {
  await db.transaction(async (tx) => {
    await tx.update(departments).set({ parentId }).where(eq(departments.parentId, id));
    await tx.delete(departments).where(eq(departments.id, id));
  });
}

/** 팀이 지워질 때 그 팀의 부서 트리도 지운다(팀 범위의 범위 키는 팀 id라 외래 키가 없다). */
export async function deleteDepartmentsOfScope(scopeKey) {
  await db.update(departments).set({ parentId: null }).where(eq(departments.scopeKey, scopeKey));
  await db.delete(departments).where(eq(departments.scopeKey, scopeKey));
}

const memberColumns = (row, extra) => ({
  id: row.id,
  username: row.username,
  name: row.name ?? row.username,
  role: row.role ?? 'guest',
  isServerAdmin: !!row.isServerAdmin,
  suspendedAt: row.suspendedAt ?? null,
  avatarType: row.avatarType ?? 'initial',
  avatarEmoji: row.avatarEmoji ?? null,
  avatarColor: row.avatarColor ?? null,
  avatarUrl: row.avatarUrl ?? null,
  ...extra,
});

/**
 * 조직도의 사람들 — 탈퇴하지 않은 사람. 회사 하나면 서버 전체 회원(users의 부서·직책·상위자), 팀이면 그 팀 멤버(team_members 쪽 값).
 * `[{ id, username, name, role, …아바타, department, position, departmentId, managerId, isOwner }]`.
 */
export async function listOrgMembers(scopeKey) {
  if (scopeKey === 'server') {
    const rows = await db.select().from(users).where(isNull(users.deletedAt));
    return rows.map((u) =>
      memberColumns(u, {
        department: u.department ?? null,
        position: u.position ?? null,
        departmentId: u.departmentId ?? null,
        managerId: u.managerId ?? null,
        isOwner: false,
      }),
    );
  }
  const rows = await db
    .select({ user: users, tm: teamMembers })
    .from(teamMembers)
    .innerJoin(users, eq(users.id, teamMembers.userId))
    .where(and(eq(teamMembers.teamId, scopeKey), isNull(users.deletedAt)));
  return rows.map((r) =>
    memberColumns(r.user, {
      department: r.tm.department ?? null,
      position: r.tm.position ?? null,
      departmentId: r.tm.departmentId ?? null,
      managerId: r.tm.managerId ?? null,
      isOwner: r.tm.role === 'owner',
    }),
  );
}

/** 한 사람의 조직도 칸(부서 id·부서 이름 글자·상위자)을 바꾼다. 바꿨으면 true(팀 범위인데 그 팀 멤버가 아니면 false). */
export async function setMemberOrg(scopeKey, userId, patch) {
  if (scopeKey === 'server') {
    const rows = await db.update(users).set(patch).where(eq(users.id, userId)).returning({ id: users.id });
    return rows.length > 0;
  }
  const rows = await db
    .update(teamMembers)
    .set(patch)
    .where(and(eq(teamMembers.teamId, scopeKey), eq(teamMembers.userId, userId)))
    .returning({ id: teamMembers.userId });
  return rows.length > 0;
}

/** [fromId] 부서 사람들을 [to] 부서(`{ id, name }`, null이면 부서 없음)로 — 옮긴 사람 id 목록. */
export async function moveDepartmentMembers(scopeKey, fromId, to) {
  const patch = { departmentId: to?.id ?? null, department: to?.name ?? null };
  if (scopeKey === 'server') {
    const rows = await db.update(users).set(patch).where(eq(users.departmentId, fromId)).returning({ id: users.id });
    return rows.map((r) => r.id);
  }
  const rows = await db
    .update(teamMembers)
    .set(patch)
    .where(and(eq(teamMembers.teamId, scopeKey), eq(teamMembers.departmentId, fromId)))
    .returning({ id: teamMembers.userId });
  return rows.map((r) => r.id);
}

/** 부서 이름이 바뀌면 그 부서 사람들의 부서 글자도 따라 바꾼다 — 바뀐 사람 id 목록. */
export function renameDepartmentMembers(scopeKey, deptId, name) {
  return moveDepartmentMembers(scopeKey, deptId, { id: deptId, name });
}

/** 부서 글자는 있는데 트리에 아직 안 이어진 사람들 `[{ userId, department }]` — 예전 자유 글자 부서를 잇는 데(orgTree.js). */
export async function listUnlinkedDepartmentTexts(scopeKey) {
  if (scopeKey === 'server') {
    const rows = await db
      .select({ userId: users.id, department: users.department })
      .from(users)
      .where(and(isNotNull(users.department), isNull(users.departmentId), isNull(users.deletedAt)));
    return rows.filter((r) => r.department.trim());
  }
  const rows = await db
    .select({ userId: teamMembers.userId, department: teamMembers.department })
    .from(teamMembers)
    .where(and(eq(teamMembers.teamId, scopeKey), isNotNull(teamMembers.department), isNull(teamMembers.departmentId)));
  return rows.filter((r) => r.department.trim());
}

/** 여러 사람을 한 번에 한 부서에 잇는다(예전 글자 → 트리). */
export async function linkMembersToDepartment(scopeKey, userIds, dept) {
  if (userIds.length === 0) return;
  const patch = { departmentId: dept.id, department: dept.name };
  if (scopeKey === 'server') {
    await db.update(users).set(patch).where(inArray(users.id, userIds));
    return;
  }
  await db
    .update(teamMembers)
    .set(patch)
    .where(and(eq(teamMembers.teamId, scopeKey), inArray(teamMembers.userId, userIds)));
}

/** 범위 안에서 [userId]를 상위자·부서장으로 정해 둔 칸을 비운다(그 사람이 이 범위를 떠났을 때). */
export async function clearManagerReferences(scopeKey, userId) {
  await db
    .update(departments)
    .set({ headId: null })
    .where(and(eq(departments.scopeKey, scopeKey), eq(departments.headId, userId)));
  if (scopeKey === 'server') {
    await db.update(users).set({ managerId: null }).where(eq(users.managerId, userId));
    return;
  }
  await db
    .update(teamMembers)
    .set({ managerId: null })
    .where(and(eq(teamMembers.teamId, scopeKey), eq(teamMembers.managerId, userId)));
}

// ── 겸직(department_memberships) ─────────────────────────────────────────

/** 범위의 겸직 전부 `[{ userId, departmentId, position }]`. */
export function listConcurrent(scopeKey) {
  return db
    .select({ userId: departmentMemberships.userId, departmentId: departmentMemberships.departmentId, position: departmentMemberships.position })
    .from(departmentMemberships)
    .where(eq(departmentMemberships.scopeKey, scopeKey))
    .orderBy(asc(departmentMemberships.createdAt));
}

/** 겸직 넣기 — 이미 있으면 직책만 바꾼다. */
export async function upsertConcurrent({ scopeKey, userId, departmentId, position = null }) {
  await db
    .insert(departmentMemberships)
    .values({ scopeKey, userId, departmentId, position })
    .onConflictDoUpdate({ target: [departmentMemberships.userId, departmentMemberships.departmentId], set: { position } });
}

export async function removeConcurrent(userId, departmentId) {
  const rows = await db
    .delete(departmentMemberships)
    .where(and(eq(departmentMemberships.userId, userId), eq(departmentMemberships.departmentId, departmentId)))
    .returning({ id: departmentMemberships.userId });
  return rows.length > 0;
}

/** 한 사람의 이 범위 겸직을 [departmentIds]로 바꾼다(엑셀 가져오기). */
export async function replaceConcurrent(scopeKey, userId, departmentIds) {
  await db.transaction(async (tx) => {
    await tx
      .delete(departmentMemberships)
      .where(and(eq(departmentMemberships.scopeKey, scopeKey), eq(departmentMemberships.userId, userId)));
    if (departmentIds.length) {
      await tx.insert(departmentMemberships).values(departmentIds.map((departmentId) => ({ scopeKey, userId, departmentId })));
    }
  });
}

/**
 * 부서를 지울 때 그 부서의 겸직을 [toId](위 부서)로 — 위 부서가 없거나, 이미 그 부서에 겸직이 있거나, 그 사람의 주 부서가 위 부서면 지운다.
 * [primaryOf]는 userId → 주 부서 id.
 */
export async function moveConcurrentOnDelete(scopeKey, fromId, toId, primaryOf) {
  const rows = await db.select().from(departmentMemberships).where(eq(departmentMemberships.departmentId, fromId));
  for (const r of rows) {
    await db.delete(departmentMemberships).where(and(eq(departmentMemberships.userId, r.userId), eq(departmentMemberships.departmentId, fromId)));
    if (toId && primaryOf(r.userId) !== toId) {
      await db.insert(departmentMemberships).values({ scopeKey, userId: r.userId, departmentId: toId, position: r.position }).onConflictDoNothing();
    }
  }
}

/** 주 부서를 [departmentId]로 옮긴 사람의 같은 부서 겸직은 지운다(주 부서와 겸직이 같을 수 없다). */
export async function dropConcurrentSameAsPrimary(userId, departmentId) {
  if (!departmentId) return;
  await removeConcurrent(userId, departmentId);
}

/** 팀에서 빠진 사람 — 그 팀 조직도의 겸직을 지운다. */
export async function clearConcurrentForScopeUser(scopeKey, userId) {
  await db.delete(departmentMemberships).where(and(eq(departmentMemberships.scopeKey, scopeKey), eq(departmentMemberships.userId, userId)));
}
