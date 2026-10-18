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

// ── 겸직 ─────────────────────────────────────────────────────────────────

/** 한 사람이 주 부서 말고 겸직할 수 있는 부서 수. */
export const CONCURRENT_MAX = 5;
export const CONCURRENT_POSITION_MAX = 40;

/**
 * 겸직 넣기 검사 — 부서가 이 범위에 있어야 하고, 주 부서와 같으면 안 되고, 이미 겸직 중이면 안 되고, 5개까지. [current]는 그 사람의 겸직
 * 부서 id들. `{ ok: true }` | `{ error }`.
 */
export function checkConcurrent({ departments, member, departmentId, current = [] }) {
  const map = departments instanceof Map ? departments : new Map(departments.map((d) => [d.id, d]));
  if (!map.has(departmentId)) return { error: '부서를 찾을 수 없습니다.' };
  if (member?.departmentId === departmentId) return { error: '주 부서와 같은 부서는 겸직으로 넣을 수 없습니다.' };
  if (current.includes(departmentId)) return { error: '이미 겸직 중인 부서입니다.' };
  if (current.length >= CONCURRENT_MAX) return { error: `겸직은 ${CONCURRENT_MAX}개 부서까지입니다.` };
  return { ok: true };
}

// ── 부서 경로(엑셀·사내 디렉터리) ────────────────────────────────────────

/** 부서 경로 글자 "본부 > 실 > 팀"(또는 / 로 나눈 것) → 이름 목록. 빈 칸은 뺀다. */
export function parseDepartmentPath(text) {
  return String(text ?? '')
    .split(/\s*(?:>|›|\/)\s*/)
    .map((s) => s.replace(/[\u0000-\u001f\u007f]/g, '').trim())
    .filter(Boolean);
}

export const formatDepartmentPath = (names) => names.join(' > ');

/** DN의 RDN 목록(앞에서부터) — 역슬래시 이스케이프를 지킨다. "CN=김\, 철수,OU=1팀" → [['cn','김, 철수'], ['ou','1팀']]. */
export function dnParts(dn) {
  const parts = [];
  let cur = '';
  const s = String(dn ?? '');
  for (let i = 0; i < s.length; i += 1) {
    const ch = s[i];
    if (ch === '\\' && i + 1 < s.length) {
      cur += s[i + 1];
      i += 1;
    } else if (ch === ',') {
      parts.push(cur);
      cur = '';
    } else cur += ch;
  }
  if (cur.trim()) parts.push(cur);
  return parts
    .map((p) => {
      const eq = p.indexOf('=');
      return eq > 0 ? [p.slice(0, eq).trim().toLowerCase(), p.slice(eq + 1).trim()] : null;
    })
    .filter(Boolean);
}

/**
 * 사람의 DN → 부서 경로(위에서부터 OU 이름들). [baseDn](예: OU=Users,DC=company,DC=local)이 있으면 그 아래 OU만 — DN이 그 아래가 아니면
 * null(조직도를 바꾸지 않는다). 없으면 DC를 뺀 모든 OU.
 */
export function ouPathOf(dn, baseDn = null) {
  const parts = dnParts(dn);
  if (parts.length === 0) return null;
  let tail = parts;
  if (baseDn && String(baseDn).trim()) {
    const base = dnParts(baseDn);
    const n = base.length;
    const suffix = parts.slice(-n);
    const same =
      suffix.length === n && suffix.every(([k, v], i) => k === base[i][0] && v.toLowerCase() === base[i][1].toLowerCase());
    if (!same) return null;
    tail = parts.slice(0, parts.length - n);
  }
  return tail
    .filter(([k]) => k === 'ou')
    .map(([, v]) => v)
    .reverse();
}

/** 부서 이름 경로의 부서(그 경로가 트리에 있으면), 없으면 null. */
export function departmentByPath(departments, names) {
  const list = departments instanceof Map ? [...departments.values()] : departments;
  let parentId = null;
  let found = null;
  for (const name of names) {
    found = list.find((d) => (d.parentId ?? null) === parentId && d.name === name) ?? null;
    if (!found) return null;
    parentId = found.id;
  }
  return found;
}

// ── 엑셀 가져오기·내보내기 ────────────────────────────────────────────────

/** 엑셀 시트·열 이름(내보내기와 가져오기가 같은 이름을 쓴다). */
export const ORG_SHEETS = Object.freeze({ departments: '부서', members: '구성원' });
export const DEPT_COLUMNS = Object.freeze(['부서 경로', '부서장 아이디', '순서']);
export const MEMBER_COLUMNS = Object.freeze(['아이디', '이름', '부서 경로', '직책', '상위자 아이디', '겸직 부서']);
export const IMPORT_ROWS_MAX = 5000;

/**
 * 내보낼 행 — `{ departments: [[경로, 부서장 아이디, 순서]…], members: [[아이디, 이름, 경로, 직책, 상위자 아이디, 겸직 경로들]…] }`.
 * [concurrent]는 userId → 겸직 부서 id 목록. 부서는 트리 순서(위에서부터 깊이 우선), 사람은 이름 순.
 */
export function buildOrgExport({ departments, members, concurrent = new Map() }) {
  const map = new Map(departments.map((d) => [d.id, d]));
  const usernameOf = (id) => (id ? (members.get(id)?.username ?? '') : '');
  const pathOf = (id) => (id && map.has(id) ? formatDepartmentPath(departmentPath(map, id)) : '');
  const deptRows = [];
  const walk = (parentId, depth) => {
    if (depth > DEPARTMENT_DEPTH_MAX + 1) return;
    for (const d of sortDepartments(departments.filter((x) => (x.parentId ?? null) === parentId))) {
      deptRows.push([pathOf(d.id), usernameOf(d.headId), d.sortOrder ?? 0]);
      walk(d.id, depth + 1);
    }
  };
  walk(null, 1);
  const memberRows = [...members.values()]
    .filter((m) => !m.suspendedAt)
    .sort((a, b) => a.name.localeCompare(b.name, 'ko'))
    .map((m) => [
      m.username,
      m.name,
      pathOf(m.departmentId),
      m.position ?? '',
      usernameOf(m.managerId),
      (concurrent.get(m.id) ?? []).map(pathOf).filter(Boolean).join('; '),
    ]);
  return { departments: deptRows, members: memberRows };
}

const cellText = (v) => (v == null ? '' : typeof v === 'object' && 'text' in v ? String(v.text) : String(v)).trim();

/**
 * 가져올 엑셀 내용(시트별 행 — 머리줄 뺀 칸 배열) → 할 일 `{ plan, errors }`. 아무것도 바꾸지 않고 먼저 보여 주는 데(미리 보기)와 실제로
 * 바꾸는 데(orgTree.js applyOrgImport) 같이 쓴다. 사람은 **아이디**로 찾고(없는 아이디는 오류), 부서는 **경로**로 찾는다(없는 경로는 위
 * 부서부터 만든다). 파일에 없는 부서·사람은 그대로 둔다(지우지 않는다).
 *  - 부서 시트: 경로(필수)·부서장 아이디(빈칸이면 그대로 — "-"면 부서장 없음)·순서(빈칸이면 그대로)
 *  - 구성원 시트: 아이디(필수)·이름(읽지 않음)·부서 경로(빈칸이면 그대로 — "-"면 부서 없음)·직책(빈칸이면 그대로)·상위자 아이디(빈칸이면
 *    그대로 — "-"면 부서장을 따름)·겸직 부서(빈칸이면 그대로 — "-"면 겸직 없음, 여럿이면 ; 로)
 * plan: `{ createPaths: [[이름…]…], heads: [{ path, headId }], orders: [{ path, sortOrder }], members: [{ userId, departmentPath?,
 * position?, managerId?, concurrentPaths? }] }` — 칸이 없으면(undefined) 바꾸지 않는다, null은 비우기.
 */
export function planOrgImport({ departments, members, deptRows = [], memberRows = [], positionLabels = null }) {
  if (deptRows.length + memberRows.length > IMPORT_ROWS_MAX) {
    return { plan: null, errors: [{ sheet: null, row: null, message: `한 번에 ${IMPORT_ROWS_MAX}줄까지 가져올 수 있습니다.` }] };
  }
  const errors = [];
  const byUsername = new Map([...members.values()].map((m) => [String(m.username).toLowerCase(), m]));
  const map = new Map(departments.map((d) => [d.id, d]));
  const existingPaths = new Set(departments.map((d) => formatDepartmentPath(departmentPath(map, d.id))));
  const createPaths = [];
  const wantPath = (names, where) => {
    if (names.length === 0) return false;
    for (const n of names) {
      const parsed = parseDepartmentName(n);
      if (parsed.error) {
        errors.push({ ...where, message: parsed.error });
        return false;
      }
    }
    if (names.length > DEPARTMENT_DEPTH_MAX) {
      errors.push({ ...where, message: `부서는 ${DEPARTMENT_DEPTH_MAX}단계까지입니다.` });
      return false;
    }
    for (let i = 1; i <= names.length; i += 1) {
      const key = formatDepartmentPath(names.slice(0, i));
      if (!existingPaths.has(key)) {
        existingPaths.add(key);
        createPaths.push(names.slice(0, i));
      }
    }
    return true;
  };
  // [missing]은 못 찾았을 때의 오류 문구(칸마다 문장 전체 — 앱이 통째로 번역한다).
  const userOf = (text, where, missing) => {
    const m = byUsername.get(text.toLowerCase());
    if (!m) errors.push({ ...where, message: missing(text) });
    return m ?? null;
  };

  const heads = [];
  const orders = [];
  deptRows.forEach((row, i) => {
    const where = { sheet: ORG_SHEETS.departments, row: i + 2 };
    const pathText = cellText(row[0]);
    if (!pathText) return;
    const names = parseDepartmentPath(pathText);
    if (!wantPath(names, where)) return;
    const path = formatDepartmentPath(names);
    const head = cellText(row[1]);
    if (head === '-') heads.push({ path, headId: null });
    else if (head) {
      const m = userOf(head, where, (t) => `부서장 아이디가 "${t}"인 사람이 없습니다.`);
      if (m) heads.push({ path, headId: m.id });
    }
    const order = cellText(row[2]);
    if (order) {
      const n = Number(order);
      if (!Number.isInteger(n) || n < 0 || n > 100_000) errors.push({ ...where, message: '순서는 0 이상의 정수로 넣으세요.' });
      else orders.push({ path, sortOrder: n });
    }
  });

  const memberPlans = [];
  const seen = new Set();
  memberRows.forEach((row, i) => {
    const where = { sheet: ORG_SHEETS.members, row: i + 2 };
    const username = cellText(row[0]);
    if (!username) return;
    const m = userOf(username, where, (t) => `아이디가 "${t}"인 사람이 없습니다.`);
    if (!m) return;
    if (seen.has(m.id)) {
      errors.push({ ...where, message: `"${username}"이(가) 두 번 나옵니다.` });
      return;
    }
    seen.add(m.id);
    const plan = { userId: m.id };
    const dept = cellText(row[2]);
    if (dept === '-') plan.departmentPath = null;
    else if (dept) {
      const names = parseDepartmentPath(dept);
      if (wantPath(names, where)) plan.departmentPath = formatDepartmentPath(names);
    }
    const position = cellText(row[3]);
    if (position) {
      if (positionLabels && !positionLabels.includes(position)) errors.push({ ...where, message: `직책 목록에 없는 직책입니다: ${position}` });
      else plan.position = position.slice(0, 40);
    }
    const manager = cellText(row[4]);
    if (manager === '-') plan.managerId = null;
    else if (manager) {
      const mm = userOf(manager, where, (t) => `상위자 아이디가 "${t}"인 사람이 없습니다.`);
      if (mm && mm.id === m.id) errors.push({ ...where, message: '자기 자신을 상위자로 정할 수 없습니다.' });
      else if (mm) plan.managerId = mm.id;
    }
    const concurrent = cellText(row[5]);
    if (concurrent === '-') plan.concurrentPaths = [];
    else if (concurrent) {
      const paths = [...new Set(concurrent.split(/\s*[;\n]\s*/).filter(Boolean))].map((t) => parseDepartmentPath(t));
      if (paths.length > CONCURRENT_MAX) errors.push({ ...where, message: `겸직은 ${CONCURRENT_MAX}개 부서까지입니다.` });
      else if (paths.every((p) => wantPath(p, where))) plan.concurrentPaths = paths.map(formatDepartmentPath);
    }
    memberPlans.push(plan);
  });
  return { plan: { createPaths, heads, orders, members: memberPlans }, errors };
}

/** 미리 보기 숫자 — 만들 부서·바꿀 부서장·바꿀 순서·바꿀 사람 수. */
export const importSummary = (plan) =>
  plan
    ? { createDepartments: plan.createPaths.length, headChanges: plan.heads.length, orderChanges: plan.orders.length, memberChanges: plan.members.length }
    : { createDepartments: 0, headChanges: 0, orderChanges: 0, memberChanges: 0 };

/**
 * 끌어다 놓아 옮기기 — [id] 부서를 [parentId] 아래 [index]번째(0부터)로. 같은 위 부서 안의 새 순서(부서 id 목록)를 돌려준다(옮기는 부서
 * 포함). 트리가 꼬이는지는 checkDepartmentParent로 따로 본다.
 */
export function reorderSiblings(departments, id, parentId, index) {
  const siblings = sortDepartments(departments.filter((d) => (d.parentId ?? null) === (parentId ?? null) && d.id !== id)).map((d) => d.id);
  const at = Math.max(0, Math.min(Number.isInteger(index) ? index : siblings.length, siblings.length));
  siblings.splice(at, 0, id);
  return siblings;
}

// ── 부서로 거르기(휴가 달력) ──

/**
 * [departmentId] 부서(아래 부서 모두 포함)에 속한 사람 id들(Set) — 주 부서가 그 안이거나 겸직 부서가 그 안인 사람. [departmentId]가
 * 'none'이면 부서가 없는 사람(겸직도 없는). [members]는 id → `{ departmentId }`(Map 또는 목록), [concurrent]는 `[{ userId, departmentId }]`.
 */
export function departmentMemberIds({ departmentId, departments, members, concurrent = [] }) {
  const list = members instanceof Map ? [...members.values()] : members;
  if (departmentId === 'none') {
    const withConcurrent = new Set(concurrent.map((c) => c.userId));
    return new Set(list.filter((m) => !m.departmentId && !withConcurrent.has(m.id)).map((m) => m.id));
  }
  const scope = new Set([departmentId, ...descendantsOf(departments, departmentId)]);
  const out = new Set(list.filter((m) => m.departmentId && scope.has(m.departmentId)).map((m) => m.id));
  for (const c of concurrent) if (scope.has(c.departmentId)) out.add(c.userId);
  return out;
}

/** 부서 고르기 목록 — 트리 순서(위 부서 다음에 그 아래)로 `[{ id, name, parentId, depth }]`. */
export function departmentOptions(departments) {
  const children = new Map();
  for (const d of sortDepartments([...departments])) {
    const key = d.parentId ?? null;
    if (!children.has(key)) children.set(key, []);
    children.get(key).push(d);
  }
  const out = [];
  const seen = new Set();
  const walk = (parentId, depth) => {
    for (const d of children.get(parentId) ?? []) {
      if (seen.has(d.id) || depth > DEPARTMENT_DEPTH_MAX) continue;
      seen.add(d.id);
      out.push({ id: d.id, name: d.name, parentId: d.parentId ?? null, depth });
      walk(d.id, depth + 1);
    }
  };
  walk(null, 1);
  // 위 부서가 없어진(꼬인) 부서도 빠뜨리지 않는다.
  for (const d of departments) if (!seen.has(d.id)) out.push({ id: d.id, name: d.name, parentId: d.parentId ?? null, depth: 1 });
  return out;
}
