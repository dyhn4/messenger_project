import { findIdentity, listIdentitiesByProvider } from './db/queries/userIdentities.js';
import { insertDepartment, listDepartments, dropConcurrentSameAsPrimary, setMemberOrg } from './db/queries/orgTree.js';
import { ldapListProfiles, ldapProfileByDn } from './ldapAuth.js';
import { loadOrgTree } from './orgTree.js';
import { checkManager, departmentByPath, DEPARTMENTS_MAX, ouPathOf, parseDepartmentName } from './orgTreeRules.js';

/**
 * 사내 디렉터리(LDAP/AD)로 조직도 맞추기 — 계정 단위 조직도(회사 하나 — 범위 'server')에서만.
 *  - 부서: [ldapOrgSource] 'ou'면 그 사람 DN의 OU 경로(예: OU=1팀,OU=영업본부,OU=Users,… → 영업본부 > 1팀, [ldapOrgBaseDn] 아래부터)를 부서
 *    트리로 — 없는 부서는 위에서부터 만든다. 'attribute'(예전 방식 — 부서 속성 글자를 맨 위 부서로)는 loginSecurity.js가 하고, 'off'면 안 맞춘다.
 *  - 상위자: [ldapManagerSync]면 manager 속성(상위자의 DN)의 사람을 이 앱 계정으로 찾아(그 사람이 디렉터리로 한 번이라도 들어와 계정이 있어야
 *    한다) 상위자로 정한다. 서로가 서로의 상위자가 되면 정하지 않는다. 디렉터리에 상위자가 없으면 그대로 둔다.
 * 언제: 디렉터리 로그인 때·10분마다 다시 볼 때(한 사람), 관리자 콘솔 "지금 디렉터리와 맞추기"(모두 — 계정이 있는 사람만).
 * 실패해도 로그인은 막지 않는다.
 */

const SCOPE = 'server';

/** 경로의 부서(없으면 위에서부터 만든다 — 부서 수 상한이면 null). [departments]는 이번에 읽은 목록(만든 것을 더해 둔다). */
async function ensurePath(departments, names) {
  let parentId = null;
  let dept = null;
  for (let i = 0; i < names.length; i += 1) {
    const parsed = parseDepartmentName(names[i]);
    if (parsed.error) return null;
    dept = departmentByPath(departments, names.slice(0, i + 1));
    if (!dept) {
      if (departments.length >= DEPARTMENTS_MAX) return null;
      const siblings = departments.filter((d) => (d.parentId ?? null) === parentId);
      dept = await insertDepartment({
        scopeKey: SCOPE,
        parentId,
        name: parsed.name,
        sortOrder: siblings.reduce((max, d) => Math.max(max, d.sortOrder ?? 0), -1) + 1,
      });
      departments.push(dept);
    }
    parentId = dept.id;
  }
  return dept;
}

/** 이 설정으로 조직도를 맞추는지. */
export const directoryOrgSyncOn = (settings) =>
  settings.orgScope === 'account' && (settings.ldapOrgSource === 'ou' || !!settings.ldapManagerSync);

/** 상위자 DN → 이 앱 계정 id(10분 기억). */
const managerCache = new Map(); // dn(소문자) → { at, userId }
async function userIdForDn(settings, dn) {
  const key = String(dn).toLowerCase();
  const hit = managerCache.get(key);
  if (hit && Date.now() - hit.at < 10 * 60 * 1000) return hit.userId;
  const profile = await ldapProfileByDn({ settings, dn }).catch(() => null);
  const identity = profile ? await findIdentity('ldap', profile.subject) : null;
  const userId = identity?.userId ?? null;
  managerCache.set(key, { at: Date.now(), userId });
  if (managerCache.size > 5000) managerCache.delete(managerCache.keys().next().value);
  return userId;
}

/**
 * 한 사람 — 디렉터리 [profile](dn·managerDn)로 부서·상위자를 맞춘다. 바뀌었으면 `{ changed: true }`(부른 쪽이 조직도가 바뀌었다고 알린다).
 * [resolveManager]는 상위자 DN → 계정 id(한꺼번에 맞출 때는 미리 만든 표를 쓴다).
 */
export async function syncDirectoryOrgForUser(io, userId, profile, settings, { tree = null, resolveManager = null } = {}) {
  try {
    if (!directoryOrgSyncOn(settings) || !profile) return { changed: false };
    const { departments, members } = tree ?? (await loadOrgTree(SCOPE));
    const member = members.get(userId);
    if (!member) return { changed: false };
    const patch = {};
    if (settings.ldapOrgSource === 'ou') {
      const path = ouPathOf(profile.dn, settings.ldapOrgBaseDn);
      if (path && path.length > 0) {
        const dept = await ensurePath(departments, path);
        if (dept && dept.id !== member.departmentId) Object.assign(patch, { departmentId: dept.id, department: dept.name });
      }
    }
    if (settings.ldapManagerSync && profile.managerDn) {
      const managerId = resolveManager ? resolveManager(profile.managerDn) : await userIdForDn(settings, profile.managerDn);
      if (managerId && managerId !== member.managerId && managerId !== userId) {
        const after = new Map(members);
        if (patch.departmentId) after.set(userId, { ...member, departmentId: patch.departmentId });
        if (checkManager(userId, managerId, { members: after, departments }).ok) patch.managerId = managerId;
      }
    }
    if (Object.keys(patch).length === 0) return { changed: false };
    await setMemberOrg(SCOPE, userId, patch);
    members.set(userId, { ...member, ...patch });
    if (patch.departmentId) await dropConcurrentSameAsPrimary(userId, patch.departmentId);
    if (!tree) io?.emit('org:tree-changed', { scopeKey: SCOPE });
    return { changed: true, moved: !!patch.departmentId, managerSet: !!patch.managerId };
  } catch (err) {
    console.error('[orgDirectorySync] 조직도를 맞추지 못했습니다:', userId, err?.message ?? err);
    return { changed: false };
  }
}

/**
 * 모두 — 디렉터리의 사람을 읽어(계정이 있는 사람만 — 디렉터리 연결로 찾는다) 부서·상위자를 맞춘다. `{ scanned, linked, moved, managersSet,
 * departmentsCreated }` | `{ error }`. 부서를 먼저 다 맞춘 뒤 상위자를 맞춘다(상위자 사슬 검사가 새 부서를 보게).
 */
export async function syncDirectoryOrgAll(io, settings) {
  if (settings.orgScope !== 'account') return { error: '사내 디렉터리로 조직도를 맞추는 것은 계정 단위 조직도에서만 됩니다.' };
  if (!directoryOrgSyncOn(settings)) return { error: '부서(OU)나 상위자 맞추기를 먼저 켜세요.' };
  const profiles = await ldapListProfiles({ settings });
  if (profiles.error) return { error: `디렉터리를 읽지 못했습니다: ${profiles.error}` };
  const identities = await listIdentitiesByProvider('ldap');
  const userBySubject = new Map(identities.map((i) => [i.subject, i.userId]));
  const userByDn = new Map();
  for (const p of profiles) {
    const userId = userBySubject.get(p.subject);
    if (userId && p.dn) userByDn.set(String(p.dn).toLowerCase(), userId);
  }
  const tree = await loadOrgTree(SCOPE);
  const before = tree.departments.length;
  const linkedProfiles = profiles.filter((p) => userBySubject.has(p.subject));
  let moved = 0;
  let managersSet = 0;
  const resolveManager = (dn) => userByDn.get(String(dn).toLowerCase()) ?? null;
  // 두 번 — 처음엔 부서만(상위자 끔), 다음엔 상위자만.
  for (const passSettings of [
    { ...settings, ldapManagerSync: false },
    { ...settings, ldapOrgSource: 'off' },
  ]) {
    if (!directoryOrgSyncOn(passSettings)) continue;
    for (const p of linkedProfiles) {
      const r = await syncDirectoryOrgForUser(io, userBySubject.get(p.subject), p, passSettings, { tree, resolveManager });
      if (r.moved) moved += 1;
      if (r.managerSet) managersSet += 1;
    }
  }
  io?.emit('org:tree-changed', { scopeKey: SCOPE });
  return {
    scanned: profiles.length,
    linked: linkedProfiles.length,
    moved,
    managersSet,
    departmentsCreated: (await listDepartments(SCOPE)).length - before,
  };
}
