import { Router } from 'express';
import { teamAccess, userAccess } from './access.js';
import { AUDIT, recordAudit } from './audit.js';
import { safeAvatarColor } from './avatarRules.js';
import {
  clearManagerReferences,
  countDepartments,
  deleteDepartment,
  findDepartment,
  findDepartmentByName,
  insertDepartment,
  linkMembersToDepartment,
  listAllTeamIds,
  listDepartments,
  listOrgMembers,
  listUnlinkedDepartmentTexts,
  moveDepartmentMembers,
  renameDepartmentMembers,
  setMemberOrg,
  updateDepartment,
} from './db/queries/orgTree.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { findTeamById, listCoTeamMemberIds, listTeamMemberIds } from './db/queries/teams.js';
import { isUuid } from './favoritesRules.js';
import {
  canEditOrgTree,
  canViewOrgTree,
  checkDepartmentParent,
  checkManager,
  DEPARTMENTS_MAX,
  directManagerOf,
  managerChain,
  orgScopeKey,
  parseDepartmentName,
  sortDepartments,
} from './orgTreeRules.js';
import { signFileUrl } from './upload.js';
import { seesWholeDirectory } from './userDirectory.js';

/**
 * 조직도 — 부서 트리(상위 부서·부서장·순서)와 사람마다의 부서·상위자. 규칙은 orgTreeRules.js, DB는 db/queries/orgTree.js.
 *
 * 범위는 부서·직책 설정(orgScope)을 따른다 — 계정 단위면 회사 하나('server' — 사람 칸은 users), 팀 단위면 팀마다(팀 id — 사람 칸은
 * team_members). 사람의 부서 글자(department)는 고른 부서 이름을 그대로 따라 적어 두어, 부서를 보여 주던 화면(멤버 목록·프로필
 * 카드·예전 앱)은 그대로 돈다. 예전에 글자로만 적어 둔 부서는 서버를 켤 때 같은 이름의 맨 위 부서로 이어 둔다([backfillOrgTrees]).
 *
 * 상위자 사슬은 결재선 추천에 쓴다(groupware.js → approvalRules.js suggestApprovalLine의 managerChain — [managerChainFor]).
 */

const ms = (v) => (v ? new Date(v).getTime() : null);

/** 범위 하나의 트리와 사람들 — `{ departments, members(Map id → 사람) }`. */
export async function loadOrgTree(scopeKey) {
  const [departments, members] = await Promise.all([listDepartments(scopeKey), listOrgMembers(scopeKey)]);
  return { departments, members: new Map(members.map((m) => [m.id, m])) };
}

/**
 * 부서 글자를 트리의 부서로 — 같은 이름 부서가 있으면 그것, 없으면 맨 위에 새로 만든다(부서 수 상한이면 null — 글자만 남는다).
 * 예전 화면(팀 설정·관리자 콘솔의 부서 칸, 사내 디렉터리의 부서 속성)이 글자로 보내도 트리에 이어지게.
 */
export async function departmentForText(scopeKey, text) {
  const name = typeof text === 'string' ? text.trim() : '';
  if (!scopeKey || !name) return null;
  const found = await findDepartmentByName(scopeKey, name);
  if (found) return found;
  if ((await countDepartments(scopeKey)) >= DEPARTMENTS_MAX) return null;
  const parsed = parseDepartmentName(name);
  if (parsed.error) return null;
  return insertDepartment({ scopeKey, name: parsed.name, sortOrder: 1000 });
}

/** 범위 하나의 "글자만 있는 부서"를 트리에 잇는다 — 이은 사람 수. */
export async function linkUnlinkedDepartments(scopeKey) {
  const rows = await listUnlinkedDepartmentTexts(scopeKey);
  const byName = new Map();
  for (const r of rows) {
    const name = r.department.trim();
    if (!byName.has(name)) byName.set(name, []);
    byName.get(name).push(r.userId);
  }
  let linked = 0;
  for (const [name, userIds] of byName) {
    const dept = await departmentForText(scopeKey, name);
    if (!dept) continue;
    await linkMembersToDepartment(scopeKey, userIds, dept);
    linked += userIds.length;
  }
  return linked;
}

/** 서버를 켤 때 — 지금 쓰는 범위(회사 하나 또는 팀마다)의 예전 글자 부서를 트리에 잇는다. 여러 번 돌아도 같다. */
export async function backfillOrgTrees() {
  const settings = await getServerSettings();
  const keys = settings.orgScope === 'account' ? ['server'] : await listAllTeamIds();
  let linked = 0;
  for (const key of keys) linked += await linkUnlinkedDepartments(key);
  return linked;
}

/**
 * 결재선 추천의 상위자 사슬 — 지금 설정의 조직도에서 [userId]의 상위자부터 위로(결재자로 고를 수 없는 사람은 건너뜀). 조직도 범위를
 * 정할 수 없으면(팀 단위인데 팀이 없음) 빈 목록.
 */
export async function managerChainFor({ settings, teamId, userId, isEligible, max }) {
  const scopeKey = orgScopeKey(settings, teamId);
  if (!scopeKey) return [];
  const { departments, members } = await loadOrgTree(scopeKey);
  return managerChain(userId, { members, departments, isEligible, max });
}

/** 이 요청의 조직도 범위와 권한 — `{ scopeKey, scope, teamId, team, canView, canEdit, viewer }` | `{ error, status }`. */
async function orgContext(userId, { scopeKey: givenKey = null, teamId: teamIdInput = null } = {}) {
  const settings = await getServerSettings();
  const activeKey = orgScopeKey(settings, isUuid(teamIdInput) ? teamIdInput : null);
  const scopeKey = givenKey ?? activeKey;
  if (!scopeKey) return { error: '팀을 먼저 고르세요.', status: 400 };
  // 부서·직책 설정을 바꾸면 예전 범위의 트리는 쓰지 않는다(지우지는 않음 — 되돌리면 그대로).
  if (givenKey && (settings.orgScope === 'account') !== (givenKey === 'server')) {
    return { error: '부서·직책 관리 범위가 바뀌어 지금은 쓰지 않는 조직도입니다.', status: 409 };
  }
  if (scopeKey === 'server') {
    const access = await userAccess(userId);
    if (!access.user || access.user.deletedAt) return { error: '사용자를 찾을 수 없습니다.', status: 404 };
    return {
      scopeKey,
      scope: 'server',
      teamId: null,
      team: null,
      viewer: access.user,
      canView: canViewOrgTree({ scope: 'server', role: access.role, isServerAdmin: access.isServerAdmin }),
      canEdit: canEditOrgTree({ scope: 'server', role: access.role, isServerAdmin: access.isServerAdmin }),
    };
  }
  const [access, team] = await Promise.all([teamAccess(scopeKey, userId), findTeamById(scopeKey)]);
  if (!team) return { error: '팀을 찾을 수 없습니다.', status: 404 };
  return {
    scopeKey,
    scope: 'team',
    teamId: team.id,
    team,
    viewer: access.user,
    canView: canViewOrgTree({ scope: 'team', role: access.role, isServerAdmin: access.isServerAdmin, isTeamMember: access.isMember }),
    canEdit: canEditOrgTree({ scope: 'team', role: access.role, isServerAdmin: access.isServerAdmin, isOwner: access.isOwner }),
  };
}

const departmentDto = (d) => ({
  id: d.id,
  parentId: d.parentId ?? null,
  name: d.name,
  headId: d.headId ?? null,
  sortOrder: d.sortOrder ?? 0,
  createdAt: ms(d.createdAt),
});

export function createOrgTreeRouter(io) {
  const router = Router();

  /** 응답을 보내고 null, 또는 권한까지 맞는 맥락. */
  async function context(req, res, { edit = false, scopeKey = null, teamId = null } = {}) {
    const ctx = await orgContext(req.user.sub, { scopeKey, teamId });
    if (ctx.error) {
      res.status(ctx.status).json({ error: ctx.error });
      return null;
    }
    if (!ctx.canView) {
      res.status(403).json({ error: ctx.scope === 'server' ? '준회원은 조직도를 볼 수 없습니다.' : '이 팀의 멤버가 아닙니다.' });
      return null;
    }
    if (edit && !ctx.canEdit) {
      res.status(403).json({ error: '조직도를 고칠 권한이 없습니다.' });
      return null;
    }
    return ctx;
  }

  /** 부서를 바꾼 뒤 — 범위 사람들에게 트리가 바뀌었다고, 부서 글자가 바뀐 사람은 그 사람을 아는 사람들에게 org:updated로. */
  async function notifyChanged(ctx, changedUserIds = []) {
    const audience =
      ctx.scope === 'team' ? await listTeamMemberIds(ctx.teamId) : null; // 회사 하나면 모두에게(범위 키만 보낸다)
    if (audience) for (const id of audience) io.to(`user:${id}`).emit('org:tree-changed', { scopeKey: ctx.scopeKey });
    else io.emit('org:tree-changed', { scopeKey: ctx.scopeKey });
    if (changedUserIds.length === 0) return;
    const members = await listOrgMembers(ctx.scopeKey);
    const byId = new Map(members.map((m) => [m.id, m]));
    for (const userId of changedUserIds) {
      const m = byId.get(userId);
      if (!m) continue;
      const payload = { userId, department: m.department ?? null, position: m.position ?? null };
      const recipients = audience ?? [userId, ...(await listCoTeamMemberIds(userId))];
      for (const id of new Set(recipients)) io.to(`user:${id}`).emit('org:updated', payload);
    }
  }

  function audit(req, ctx, detail, targetLabel) {
    recordAudit({
      actorId: req.user.sub,
      actorName: ctx.viewer?.name ?? ctx.viewer?.username ?? '알 수 없음',
      action: AUDIT.orgTree,
      teamId: ctx.teamId,
      teamName: ctx.team?.name ?? null,
      targetType: 'department',
      targetLabel,
      detail,
    });
  }

  /**
   * 조직도 `?teamId=` — 부서 트리와 사람들(정지된 계정은 뺌). 아이디는 서버 전체를 보는 사람·팀을 같이 쓰는 사람에게만 싣는다(회사
   * 하나인 조직도는 정회원 모두가 보므로 — userDirectory.js와 같은 뜻). effectiveManagerId는 상위자를 따로 안 정했을 때 부서장으로 정해지는
   * 실제 상위자.
   */
  router.get('/org-tree', async (req, res) => {
    const ctx = await context(req, res, { teamId: req.query.teamId });
    if (!ctx) return;
    const { departments, members } = await loadOrgTree(ctx.scopeKey);
    const visibleIds = seesWholeDirectory(ctx.viewer)
      ? null
      : new Set([req.user.sub, ...(await listCoTeamMemberIds(req.user.sub))]);
    const active = [...members.values()].filter((m) => !m.suspendedAt);
    res.json({
      scope: ctx.scope,
      scopeKey: ctx.scopeKey,
      teamId: ctx.teamId,
      teamName: ctx.team?.name ?? null,
      canEdit: ctx.canEdit,
      departments: sortDepartments(departments).map(departmentDto),
      members: active
        .map((m) => ({
          id: m.id,
          name: m.name,
          username: visibleIds === null || visibleIds.has(m.id) ? m.username : null,
          role: m.role,
          avatarType: m.avatarType,
          avatarEmoji: m.avatarEmoji,
          avatarColor: safeAvatarColor(m.avatarColor),
          avatarUrl: m.avatarType === 'photo' ? (signFileUrl(m.avatarUrl) ?? null) : null,
          position: m.position ?? null,
          departmentId: m.departmentId ?? null,
          managerId: m.managerId ?? null,
          effectiveManagerId: directManagerOf(m.id, { members, departments }),
        }))
        .sort((a, b) => a.name.localeCompare(b.name, 'ko')),
    });
  });

  /** 부서 만들기 `{ teamId?, name, parentId? }`. */
  router.post('/org-tree/departments', async (req, res) => {
    const ctx = await context(req, res, { edit: true, teamId: req.body?.teamId });
    if (!ctx) return;
    const name = parseDepartmentName(req.body?.name);
    if (name.error) return res.status(400).json({ error: name.error });
    const parentId = req.body?.parentId ?? null;
    if (parentId !== null && !isUuid(parentId)) return res.status(400).json({ error: '위 부서를 찾을 수 없습니다.' });
    const departments = await listDepartments(ctx.scopeKey);
    if (departments.length >= DEPARTMENTS_MAX) return res.status(400).json({ error: `부서는 ${DEPARTMENTS_MAX}개까지 만들 수 있습니다.` });
    const check = checkDepartmentParent(departments, null, parentId);
    if (check.error) return res.status(400).json({ error: check.error });
    if (departments.some((d) => (d.parentId ?? null) === parentId && d.name === name.name)) {
      return res.status(409).json({ error: '같은 위치에 같은 이름의 부서가 있습니다.' });
    }
    const siblings = departments.filter((d) => (d.parentId ?? null) === parentId);
    const row = await insertDepartment({
      scopeKey: ctx.scopeKey,
      parentId,
      name: name.name,
      sortOrder: siblings.reduce((max, d) => Math.max(max, d.sortOrder ?? 0), -1) + 1,
    });
    audit(req, ctx, '부서 만들기', name.name);
    await notifyChanged(ctx);
    res.status(201).json(departmentDto(row));
  });

  /** 부서 바꾸기 `{ name?, parentId?, headId? }` — 이름을 바꾸면 그 부서 사람들의 부서 글자도 따라 바뀐다. */
  router.patch('/org-tree/departments/:id', async (req, res) => {
    const dept = isUuid(req.params.id) ? await findDepartment(req.params.id) : null;
    if (!dept) return res.status(404).json({ error: '부서를 찾을 수 없습니다.' });
    const ctx = await context(req, res, { edit: true, scopeKey: dept.scopeKey });
    if (!ctx) return;
    const body = req.body ?? {};
    const patch = {};
    const details = [];
    if ('name' in body) {
      const name = parseDepartmentName(body.name);
      if (name.error) return res.status(400).json({ error: name.error });
      if (name.name !== dept.name) {
        patch.name = name.name;
        details.push(`이름 ${dept.name} → ${name.name}`);
      }
    }
    if ('parentId' in body) {
      const parentId = body.parentId ?? null;
      if (parentId !== null && !isUuid(parentId)) return res.status(400).json({ error: '위 부서를 찾을 수 없습니다.' });
      const departments = await listDepartments(ctx.scopeKey);
      const check = checkDepartmentParent(departments, dept.id, parentId);
      if (check.error) return res.status(400).json({ error: check.error });
      if ((dept.parentId ?? null) !== parentId) {
        patch.parentId = parentId;
        patch.sortOrder =
          departments.filter((d) => (d.parentId ?? null) === parentId).reduce((max, d) => Math.max(max, d.sortOrder ?? 0), -1) + 1;
        details.push('위치 옮김');
      }
    }
    let headJoined = null;
    if ('headId' in body) {
      const headId = body.headId ?? null;
      const members = await listOrgMembers(ctx.scopeKey);
      const head = headId === null ? null : members.find((m) => m.id === headId && !m.suspendedAt);
      if (headId !== null && !head) return res.status(400).json({ error: '이 조직도에 없는 사람입니다.' });
      patch.headId = headId;
      details.push(head ? `부서장 ${head.name}` : '부서장 없음');
      // 부서가 없는 사람을 부서장으로 정하면 그 부서 사람으로도 넣는다.
      if (head && !head.departmentId) headJoined = head.id;
    }
    if (Object.keys(patch).length === 0) return res.json(departmentDto(dept));
    const updated = await updateDepartment(dept.id, patch);
    const changed = patch.name ? await renameDepartmentMembers(ctx.scopeKey, dept.id, patch.name) : [];
    if (headJoined) {
      await setMemberOrg(ctx.scopeKey, headJoined, { departmentId: dept.id, department: updated.name });
      changed.push(headJoined);
    }
    audit(req, ctx, `부서 바꾸기 — ${details.join(', ')}`, updated.name);
    await notifyChanged(ctx, changed);
    res.json(departmentDto(updated));
  });

  /** 같은 위 부서 안에서 순서 옮기기 `{ direction: 'up' | 'down' }`. */
  router.post('/org-tree/departments/:id/move', async (req, res) => {
    const dept = isUuid(req.params.id) ? await findDepartment(req.params.id) : null;
    if (!dept) return res.status(404).json({ error: '부서를 찾을 수 없습니다.' });
    const ctx = await context(req, res, { edit: true, scopeKey: dept.scopeKey });
    if (!ctx) return;
    const direction = req.body?.direction;
    if (direction !== 'up' && direction !== 'down') return res.status(400).json({ error: "direction은 'up' 또는 'down'입니다." });
    const siblings = sortDepartments((await listDepartments(ctx.scopeKey)).filter((d) => (d.parentId ?? null) === (dept.parentId ?? null)));
    const index = siblings.findIndex((d) => d.id === dept.id);
    const swapWith = direction === 'up' ? index - 1 : index + 1;
    if (swapWith < 0 || swapWith >= siblings.length) return res.json({ ok: true });
    [siblings[index], siblings[swapWith]] = [siblings[swapWith], siblings[index]];
    // 순서를 0부터 다시 매긴다(예전 부서는 모두 같은 값일 수 있다).
    for (let i = 0; i < siblings.length; i += 1) {
      if ((siblings[i].sortOrder ?? 0) !== i) await updateDepartment(siblings[i].id, { sortOrder: i });
    }
    await notifyChanged(ctx);
    res.json({ ok: true });
  });

  /** 부서 지우기 — 하위 부서와 구성원은 위 부서로 올라간다(맨 위 부서면 구성원은 부서 없음). */
  router.delete('/org-tree/departments/:id', async (req, res) => {
    const dept = isUuid(req.params.id) ? await findDepartment(req.params.id) : null;
    if (!dept) return res.status(404).json({ error: '부서를 찾을 수 없습니다.' });
    const ctx = await context(req, res, { edit: true, scopeKey: dept.scopeKey });
    if (!ctx) return;
    const parent = dept.parentId ? await findDepartment(dept.parentId) : null;
    const moved = await moveDepartmentMembers(ctx.scopeKey, dept.id, parent ? { id: parent.id, name: parent.name } : null);
    await deleteDepartment(dept.id, parent?.id ?? null);
    audit(req, ctx, `부서 지우기${parent ? ` — 구성원·하위 부서는 ${parent.name}(으)로` : ''}`, dept.name);
    await notifyChanged(ctx, moved);
    res.json({ ok: true, movedTo: parent?.id ?? null });
  });

  /** 사람의 부서·상위자 `{ teamId?, departmentId?, managerId? }`(null이면 비움). */
  router.put('/org-tree/members/:userId', async (req, res) => {
    const ctx = await context(req, res, { edit: true, teamId: req.body?.teamId });
    if (!ctx) return;
    const { departments, members } = await loadOrgTree(ctx.scopeKey);
    const target = members.get(req.params.userId);
    if (!target) return res.status(404).json({ error: '이 조직도에 없는 사람입니다.' });
    const body = req.body ?? {};
    const patch = {};
    const details = [];
    if ('departmentId' in body) {
      const deptId = body.departmentId ?? null;
      const dept = deptId === null ? null : departments.find((d) => d.id === deptId);
      if (deptId !== null && !dept) return res.status(400).json({ error: '부서를 찾을 수 없습니다.' });
      patch.departmentId = dept?.id ?? null;
      patch.department = dept?.name ?? null;
      details.push(dept ? `부서 ${dept.name}` : '부서 없음');
    }
    if ('managerId' in body) {
      const managerId = body.managerId ?? null;
      if (managerId !== null && !members.get(managerId)) return res.status(400).json({ error: '이 조직도에 없는 사람입니다.' });
      const after = new Map(members);
      if ('departmentId' in patch) after.set(target.id, { ...target, departmentId: patch.departmentId });
      const check = checkManager(target.id, managerId, { members: after, departments });
      if (check.error) return res.status(400).json({ error: check.error });
      patch.managerId = managerId;
      details.push(managerId ? `상위자 ${members.get(managerId).name}` : '상위자 부서장으로');
    }
    if (Object.keys(patch).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
    await setMemberOrg(ctx.scopeKey, target.id, patch);
    recordAudit({
      actorId: req.user.sub,
      actorName: ctx.viewer?.name ?? ctx.viewer?.username ?? '알 수 없음',
      action: AUDIT.orgTree,
      teamId: ctx.teamId,
      teamName: ctx.team?.name ?? null,
      targetType: 'user',
      targetId: target.id,
      targetLabel: target.name,
      detail: details.join(', '),
    });
    await notifyChanged(ctx, 'departmentId' in patch ? [target.id] : []);
    res.json({ ok: true });
  });

  return router;
}

/** 팀에서 빠진 사람 — 그 팀 조직도에서 그 사람을 상위자로 정해 둔 칸을 비운다(teams.js가 부른다). */
export const forgetTeamManager = (teamId, userId) => clearManagerReferences(teamId, userId);
