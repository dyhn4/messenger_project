/**
 * 조직도(부서 트리와 상위자)의 **순수 규칙** — 부서 이름, 트리가 꼬이지 않는지(자기 아래로 옮기기·깊이), 한 사람의 상위자와 상위자
 * 사슬(결재선 추천 — approvalRules.js suggestApprovalLine의 managerChain), 누가 보고 고치는지. DB는 orgTree.js가 한다.
 * `node --test`로 시험한다(test/orgTree.test.js).
 *
 * 범위는 부서·직책 설정(server_settings.org_scope)을 따른다 — 계정 단위면 회사 하나('server'), 팀 단위면 팀마다(팀 id).
 * 한 사람의 부서·상위자도 같은 범위의 칸(users 또는 team_members)에 둔다.
 */

export const DEPARTMENT_NAME_MAX = 30;
/** 한 범위의 부서 수와 트리 깊이(맨 위 부서가 1). */
export const DEPARTMENTS_MAX = 500;
export const DEPARTMENT_DEPTH_MAX = 10;

/** 조직도 범위 키 — 계정 단위면 'server', 팀 단위면 그 팀 id(없으면 null — 팀을 골라야 한다). */
export function orgScopeKey(settings, teamId) {
  if (settings?.orgScope === 'account') return 'server';
  return typeof teamId === 'string' && teamId ? teamId : null;
}

/** 부서 이름 — 앞뒤 공백·제어 문자를 떼고 1~30자. `{ name }` | `{ error }`. */
export function parseDepartmentName(value) {
  const name = typeof value === 'string' ? value.replace(/[\u0000-\u001f\u007f]/g, '').trim() : '';
  if (!name) return { error: '부서 이름을 넣으세요.' };
  if ([...name].length > DEPARTMENT_NAME_MAX) return { error: `부서 이름은 ${DEPARTMENT_NAME_MAX}자 이내로 넣으세요.` };
  return { name };
}

/** id → 부서 Map. */
const byId = (departments) => (departments instanceof Map ? departments : new Map(departments.map((d) => [d.id, d])));

/** [id] 부서의 위 부서들(가까운 것부터, 자기는 빼고). 꼬인 트리여도 멈춘다. */
export function ancestorsOf(departments, id) {
  const map = byId(departments);
  const out = [];
  const seen = new Set([id]);
  let cur = map.get(id)?.parentId ?? null;
  while (cur && !seen.has(cur) && map.has(cur)) {
    out.push(cur);
    seen.add(cur);
    cur = map.get(cur).parentId ?? null;
  }
  return out;
}

/** [id] 부서의 깊이(맨 위가 1). */
export const depthOf = (departments, id) => ancestorsOf(departments, id).length + 1;

/** [id] 아래의 모든 부서 id(자기 빼고). */
export function descendantsOf(departments, id) {
  const list = departments instanceof Map ? [...departments.values()] : departments;
  const children = new Map();
  for (const d of list) {
    if (!d.parentId) continue;
    if (!children.has(d.parentId)) children.set(d.parentId, []);
    children.get(d.parentId).push(d.id);
  }
  const out = [];
  const stack = [...(children.get(id) ?? [])];
  const seen = new Set([id]);
  while (stack.length) {
    const next = stack.pop();
    if (seen.has(next)) continue;
    seen.add(next);
    out.push(next);
    stack.push(...(children.get(next) ?? []));
  }
  return out;
}

/** "본부 › 실 › 팀" 이름 경로(위에서부터). */
export function departmentPath(departments, id) {
  const map = byId(departments);
  if (!map.has(id)) return [];
  return [...ancestorsOf(map, id)].reverse().map((a) => map.get(a).name).concat(map.get(id).name);
}

/**
 * [id] 부서를 [parentId] 아래로 옮길 수 있는지(null이면 맨 위로) — 자기 자신이나 자기 아래로는 못 옮기고, 옮긴 뒤 가장 깊은 하위
 * 부서까지 깊이 상한 안이어야 한다. `{ ok: true }` | `{ error }`. 새 부서는 [id]를 null로.
 */
export function checkDepartmentParent(departments, id, parentId) {
  const map = byId(departments);
  if (parentId == null) {
    if (id == null) return { ok: true };
  } else {
    if (!map.has(parentId)) return { error: '위 부서를 찾을 수 없습니다.' };
    if (id != null && (parentId === id || descendantsOf(map, id).includes(parentId))) {
      return { error: '부서를 자기 자신이나 그 아래 부서 밑으로 옮길 수 없습니다.' };
    }
  }
  const parentDepth = parentId == null ? 0 : depthOf(map, parentId);
  // 옮기는 부서 아래로 가장 깊이 내려간 칸 수(자기 포함 1).
  let subtree = 1;
  if (id != null) {
    for (const d of descendantsOf(map, id)) {
      subtree = Math.max(subtree, depthOf(map, d) - depthOf(map, id) + 1);
    }
  }
  if (parentDepth + subtree > DEPARTMENT_DEPTH_MAX) return { error: `부서는 ${DEPARTMENT_DEPTH_MAX}단계까지 만들 수 있습니다.` };
  return { ok: true };
}

/**
 * 한 사람의 바로 위 상위자 id(없으면 null) — 따로 정한 상위자([member.managerId])가 있으면 그 사람, 없으면 속한 부서의 부서장(본인이
 * 부서장이거나 부서장이 비었으면 위 부서로 올라가며 첫 부서장). [members]는 id → `{ departmentId, managerId }`.
 */
export function directManagerOf(userId, { members, departments }) {
  const member = members.get(userId);
  if (!member) return null;
  if (member.managerId && member.managerId !== userId) return member.managerId;
  const map = byId(departments);
  let deptId = member.departmentId && map.has(member.departmentId) ? member.departmentId : null;
  const seen = new Set();
  while (deptId && !seen.has(deptId)) {
    seen.add(deptId);
    const dept = map.get(deptId);
    if (!dept) break;
    if (dept.headId && dept.headId !== userId) return dept.headId;
    deptId = dept.parentId ?? null;
  }
  return null;
}

/**
 * 상위자 사슬 — [userId]의 상위자, 그 상위자의 상위자 … (가까운 사람부터, 최대 [max]명). [isEligible]이 거짓인 사람(결재자로 고를 수
 * 없는 사람 — 준회원·정지·이 범위 밖)은 건너뛰고 그 위로 계속 오른다. 돌고 도는 사슬이면 멈춘다. 결재선 추천에 쓴다.
 */
export function managerChain(userId, { members, departments, isEligible = () => true, max = 5 }) {
  const chain = [];
  const seen = new Set([userId]);
  let cur = userId;
  for (let hops = 0; hops < 50 && chain.length < max; hops += 1) {
    const next = directManagerOf(cur, { members, departments });
    if (!next || seen.has(next)) break;
    seen.add(next);
    if (isEligible(next)) chain.push(next);
    cur = next;
  }
  return chain;
}

/**
 * [userId]의 상위자를 [managerId]로 정해도 되는지 — 자기 자신은 안 되고, [managerId]의 상위자 사슬에 [userId]가 있으면(서로가 서로의
 * 상위자가 됨) 안 된다. `{ ok: true }` | `{ error }`.
 */
export function checkManager(userId, managerId, { members, departments }) {
  if (managerId == null) return { ok: true };
  if (managerId === userId) return { error: '자기 자신을 상위자로 정할 수 없습니다.' };
  if (!members.has(managerId)) return { error: '이 조직도에 없는 사람입니다.' };
  const after = new Map(members);
  after.set(userId, { ...(members.get(userId) ?? {}), managerId });
  const chainOfManager = managerChain(managerId, { members: after, departments, max: 50 });
  if (chainOfManager.includes(userId)) return { error: '서로가 서로의 상위자가 되게 할 수 없습니다.' };
  return { ok: true };
}

/**
 * 조직도를 볼 수 있는지 — 회사 하나(계정 단위)면 정회원 이상(준회원은 서버 전체 명단을 보지 않는다 — userDirectory.js와 같은 뜻),
 * 팀마다면 그 팀 멤버. 서버 운영자·계정 등급 관리자는 언제나.
 */
export function canViewOrgTree({ scope, role, isServerAdmin = false, isTeamMember = false }) {
  if (isServerAdmin || role === 'admin') return true;
  if (scope === 'server') return role === 'member';
  return isTeamMember;
}

/** 조직도를 고칠 수 있는지 — 회사 하나면 서버 운영자·계정 등급 관리자, 팀마다면 그 팀을 관리하는 사람(소유자)도. */
export function canEditOrgTree({ scope, role, isServerAdmin = false, isOwner = false }) {
  if (isServerAdmin || role === 'admin') return true;
  return scope === 'team' && isOwner === true;
}

/**
 * 부서를 지울 때 — 하위 부서와 구성원은 지운 부서의 위 부서로 올라간다(맨 위 부서면 하위 부서는 맨 위로, 구성원은 부서 없음).
 * `{ parentId }` 하나로 충분하지만 호출부가 같은 뜻을 쓰게 여기 둔다.
 */
export const departmentDeletionTarget = (dept) => ({ parentId: dept.parentId ?? null });

/** 같은 위 부서 아래에서 보일 순서 — sortOrder, 그다음 이름. */
export function sortDepartments(list) {
  return [...list].sort((a, b) => (a.sortOrder ?? 0) - (b.sortOrder ?? 0) || a.name.localeCompare(b.name, 'ko'));
}
