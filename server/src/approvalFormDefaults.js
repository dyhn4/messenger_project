import { APPROVERS_MAX, CC_MAX, LINE_ROLES } from './approvalRules.js';

/**
 * 양식마다의 **기본 결재선·참조자**(순수 규칙) — 관리자가 양식(기본 양식도)에 "이 양식은 늘 이 사람들이 결재"를 정해 두면, 그 양식으로 새
 * 결재를 쓸 때 결재선을 그 사람들로 미리 채운다(결재선 규칙·조직도 상위자보다 먼저). 기본 참조자만 정하면 결재자는 예전처럼 규칙·
 * 상위자로 채우고 참조자에 더한다. 미리 채울 때만 쓰고, 올리는 사람이 고칠 수 있다. DB는 approval_templates의 default_line·
 * default_cc_ids(groupware.js). `node --test`로 시험한다(test/approvalFormFollowup.test.js).
 */

/**
 * 기본 결재선·참조자 입력 `{ defaultLine?: [{ userId, role? }] | null, defaultCcIds?: [] }` 검사 → `{ defaults: { defaultLine, defaultCcIds } }`
 * (빈 결재선은 null — 정하지 않음) | `{ error }`. [isCandidate]는 이 범위에서 결재자로 고를 수 있는 사람인지. 결재선 검사
 * (approvalRules.js validateApprovalLine)와 같은 규칙 — 같은 사람 두 번, 결재자를 참조자로도, 전결 둘 이상은 안 된다.
 */
export function parseFormDefaults(body, { isCandidate }) {
  const lineIn = body?.defaultLine;
  const ccIn = body?.defaultCcIds;
  if (lineIn !== undefined && lineIn !== null && !Array.isArray(lineIn)) return { error: '기본 결재선이 올바르지 않습니다.' };
  if (ccIn !== undefined && ccIn !== null && !Array.isArray(ccIn)) return { error: '기본 참조자가 올바르지 않습니다.' };
  const line = [];
  for (const entry of lineIn ?? []) {
    const userId = typeof entry === 'string' ? entry : entry?.userId;
    const role = (typeof entry === 'object' && entry?.role) || 'approve';
    if (typeof userId !== 'string' || !isCandidate(userId)) return { error: '기본 결재선에 결재자로 고를 수 없는 사람이 있습니다.' };
    if (!LINE_ROLES.includes(role)) return { error: '결재선 역할은 결재·합의·전결 중에서 고르세요.' };
    if (line.some((e) => e.userId === userId)) return { error: '기본 결재선에 같은 사람이 두 번 있습니다.' };
    line.push({ userId, role });
  }
  if (line.length > APPROVERS_MAX) return { error: `기본 결재선은 ${APPROVERS_MAX}명까지입니다.` };
  if (line.filter((e) => e.role === 'final').length > 1) return { error: '전결은 한 명만 정할 수 있습니다.' };
  // 후결은 맨 뒤에만, 앞에 결재할 사람이 있어야(approvalRules.js validateApprovalLine과 같은 규칙).
  const firstPost = line.findIndex((e) => e.role === 'post');
  if (firstPost === 0) return { error: '후결 앞에 결재할 사람이 한 명 이상 있어야 합니다.' };
  if (firstPost > 0 && line.slice(firstPost).some((e) => e.role !== 'post')) return { error: '후결은 결재선 맨 뒤에만 둘 수 있습니다.' };
  const cc = [...new Set(ccIn ?? [])];
  if (cc.length > CC_MAX) return { error: `기본 참조자는 ${CC_MAX}명까지입니다.` };
  if (cc.some((id) => typeof id !== 'string' || !isCandidate(id))) return { error: '기본 참조자에 고를 수 없는 사람이 있습니다.' };
  if (cc.some((id) => line.some((e) => e.userId === id))) return { error: '같은 사람을 기본 결재자와 기본 참조자로 함께 넣을 수 없습니다.' };
  return { defaults: { defaultLine: line.length ? line : null, defaultCcIds: cc } };
}

/** 이 양식에 기본 결재선이나 기본 참조자가 있는지. */
export const hasFormDefaults = (form) =>
  (Array.isArray(form?.defaultLine) && form.defaultLine.length > 0) || (Array.isArray(form?.defaultCcIds) && form.defaultCcIds.length > 0);

/**
 * 미리 채울 결재선([suggested] — 규칙·상위자·저장한 결재선으로 고른 것, null일 수 있음)에 양식의 기본값을 입힌다. 올리는 사람 자신과 지금
 * 고를 수 없는 사람([isCandidate])은 뺀다.
 *  - 기본 결재선이 남으면 결재자·역할은 그것으로(`source: 'form'`), 참조자는 기본 참조자.
 *  - 기본 참조자만 있으면 결재자는 그대로, 참조자에 더한다(결재자와 겹치면 빼고 [CC_MAX]명까지).
 * 기본값을 하나라도 썼으면 `form: { id, name }`을 붙인다("양식 기본 결재선" 안내).
 */
export function applyFormDefaults({ form, authorId, suggested, isCandidate }) {
  if (!form || !hasFormDefaults(form)) return suggested;
  const keep = (id) => typeof id === 'string' && id !== authorId && isCandidate(id);
  const line = (form.defaultLine ?? []).filter((e) => keep(e.userId));
  const formCc = (form.defaultCcIds ?? []).filter(keep);
  const tag = { id: form.id, name: form.name };
  if (line.length > 0) {
    const approverIds = line.map((e) => e.userId);
    const roles = Object.fromEntries(line.filter((e) => e.role !== 'approve').map((e) => [e.userId, e.role]));
    return {
      approverIds,
      ccIds: formCc.filter((id) => !approverIds.includes(id)),
      source: 'form',
      ...(Object.keys(roles).length ? { roles } : {}),
      form: tag,
    };
  }
  if (formCc.length === 0) return suggested;
  const approverIds = suggested?.approverIds ?? [];
  const ccIds = [...new Set([...(suggested?.ccIds ?? []), ...formCc])].filter((id) => !approverIds.includes(id)).slice(0, CC_MAX);
  return { ...(suggested ?? { approverIds: [], source: 'form' }), approverIds, ccIds, form: tag };
}
