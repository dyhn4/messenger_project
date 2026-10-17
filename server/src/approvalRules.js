import { addDaysKey, halfDaysText, isDateKey, leaveRequestAmount, leaveTypeOf } from './annualLeave.js';
import { defaultFormTitle, FORM_KINDS, MONEY_MAX } from './approvalForms.js';
import { DEFAULT_EXPENSE_CATEGORIES } from './groupwareOptions.js';
import { parseHm } from './attendanceRules.js';

/**
 * 전자결재 규칙 — 결재선 검사, 종류별 내용 검사, 결재 진행(승인·반려·회수·취소). DB 없이 시험할 수 있게 계산만 모았다(groupware.js가
 * 쓴다). 결재는 결재선 순서대로 한 사람씩 하고(순차 결재), 누구든 반려하면 그 자리에서 끝난다.
 */

// 휴가·지출·근태 수정은 전용 화면이 있는 종류, 그 밖은 양식으로 올리는 종류(approvalForms.js — 기본 양식 + 관리자가 만든 'form').
export const APPROVAL_KINDS = Object.freeze(['leave', 'expense', 'attendance', ...FORM_KINDS]);
export const APPROVAL_KIND_LABEL = Object.freeze({
  leave: '휴가',
  expense: '지출',
  attendance: '근태 수정',
  draft: '기안',
  trip: '출장',
  purchase: '구매',
  overtime: '연장근무',
  form: '양식',
});

/** 문서의 종류 이름 — 관리자가 만든 양식이면 그 양식 이름(알림·감사 로그). */
export const approvalLabelOf = (doc) =>
  doc.kind === 'form' ? (doc.payload?.templateName ?? '결재') : (APPROVAL_KIND_LABEL[doc.kind] ?? '결재');
export const APPROVAL_STATUSES = Object.freeze(['pending', 'approved', 'rejected', 'withdrawn', 'canceled']);

// 결재선 사람 수(합의 칸 포함).
export const APPROVERS_MAX = 10;
export const CC_MAX = 10;
/** 조직도 상위자 사슬로 미리 채우는 결재자 수. */
export const ORG_CHAIN_MAX = 5;
export const TITLE_MAX = 100;
export const BODY_MAX = 2000;
export const COMMENT_MAX = 500;
export const LINE_NAME_MAX = 30;
export const SAVED_LINES_MAX = 20;
export const ATTACHMENTS_MAX = 5;
/** 근태 수정은 지난 이 날수 안의 날만(오래된 기록을 고쳐 임금 근거를 흔들지 못하게 — 그보다 오래된 건 관리자가 판단). */
export const ATTENDANCE_FIX_DAYS = 60;

export const EXPENSE_CATEGORIES = DEFAULT_EXPENSE_CATEGORIES;
export const EXPENSE_AMOUNT_MAX = MONEY_MAX;

const isIdList = (v) => Array.isArray(v) && v.every((id) => typeof id === 'string' && id.length > 0 && id.length <= 64);

/** 결재선 칸의 역할 — 결재(차례대로), 합의(이어진 합의 칸은 한 단계 — 동시에 차례, 모두 동의해야 넘어감), 전결(승인하면 남은 칸은 생략). */
export const LINE_ROLES = Object.freeze(['approve', 'agree', 'final']);
export const LINE_ROLE_LABEL = Object.freeze({ approve: '결재', agree: '합의', final: '전결' });

/**
 * 결재선 검사 — 결재자 1~[APPROVERS_MAX]명(순서대로), 참조자 0~10명. 같은 사람을 두 번 넣거나, 올린 사람 자신을 넣거나, 결재자를 참조자에도
 * 넣으면 거절. [isCandidate]는 이 범위에서 고를 수 있는 사람인지(groupwareScope.js canBeApprover + 같은 팀). [roles]는 결재자 id → 역할
 * ('approve' 기본 | 'agree' | 'final' — 전결은 한 명까지, 합의 칸은 전결이 될 수 없다). 통과하면 `{ approverIds, ccIds, line }` —
 * [line]은 `[{ userId, role, stage }]`(이어진 합의 칸은 같은 단계).
 */
export function validateApprovalLine({ authorId, approverIds, ccIds = [], roles = {}, isCandidate }) {
  if (!isIdList(approverIds) || approverIds.length === 0) return { error: '결재자를 한 명 이상 고르세요.' };
  if (approverIds.length > APPROVERS_MAX) return { error: `결재자는 ${APPROVERS_MAX}명까지 고를 수 있습니다.` };
  if (!isIdList(ccIds)) return { error: '참조자가 올바르지 않습니다.' };
  if (ccIds.length > CC_MAX) return { error: `참조자는 ${CC_MAX}명까지 고를 수 있습니다.` };
  if (new Set(approverIds).size !== approverIds.length) return { error: '같은 결재자를 두 번 넣었습니다.' };
  if (new Set(ccIds).size !== ccIds.length) return { error: '같은 참조자를 두 번 넣었습니다.' };
  if (approverIds.includes(authorId) || ccIds.includes(authorId)) return { error: '자기 자신은 결재선에 넣을 수 없습니다.' };
  if (ccIds.some((id) => approverIds.includes(id))) return { error: '결재자를 참조자로 또 넣을 수는 없습니다.' };
  if (![...approverIds, ...ccIds].every((id) => isCandidate(id))) {
    return { error: '결재선에 고를 수 없는 사람이 있습니다(정회원 이상, 같은 범위의 사람만).' };
  }
  const roleMap = roles && typeof roles === 'object' && !Array.isArray(roles) ? roles : {};
  const roleOf = (id) => roleMap[id] ?? 'approve';
  if (approverIds.some((id) => !LINE_ROLES.includes(roleOf(id)))) return { error: '결재선 역할은 결재·합의·전결 중에서 고르세요.' };
  if (approverIds.filter((id) => roleOf(id) === 'final').length > 1) return { error: '전결은 한 명만 정할 수 있습니다.' };
  const line = [];
  let stage = -1;
  for (const [i, id] of approverIds.entries()) {
    const role = roleOf(id);
    // 바로 앞 칸도 합의면 같은 단계(동시 결재) — 그 밖에는 새 단계.
    if (!(role === 'agree' && i > 0 && roleOf(approverIds[i - 1]) === 'agree')) stage += 1;
    line.push({ userId: id, role, stage });
  }
  return { approverIds: [...approverIds], ccIds: [...ccIds], line };
}

/**
 * 휴가 신청 내용 → `{ payload }` — 양(halfDays)은 서버가 계산한다(앱이 보낸 값을 믿지 않는다). [types]는 이 범위의 휴가 종류
 * (groupwareOptions.js mergeLeaveTypes — 켜진 것만 신청할 수 있다). 그 종류의 이름(leaveLabel)·연차 차감 여부(deducts)를 같이 적어
 * 두어, 나중에 종류 이름을 바꾸거나 꺼도 이 신청은 그대로다.
 */
export function parseLeavePayload(body, holidays = new Set(), types = null) {
  const leaveType = body?.leaveType;
  const startDate = body?.startDate;
  const endDate = body?.endDate ?? startDate;
  const typeOf = types ? (key) => types.find((t) => t.key === key && t.enabled) ?? null : leaveTypeOf;
  const amount = leaveRequestAmount({ leaveType, startDate, endDate }, holidays, typeOf);
  if (amount.error) return { error: amount.error };
  const type = typeOf(leaveType);
  return { payload: { leaveType, leaveLabel: type.label, deducts: type.deducts, startDate, endDate, halfDays: amount.halfDays } };
}

/** 지출 내용 → `{ payload }` — 금액(원, 정수), 분류, 쓴 날. */
export function parseExpensePayload(body, categories = EXPENSE_CATEGORIES) {
  const amount = Number(body?.amount);
  if (!Number.isInteger(amount) || amount <= 0) return { error: '금액을 원 단위 숫자로 넣으세요.' };
  if (amount > EXPENSE_AMOUNT_MAX) return { error: '금액이 너무 큽니다.' };
  if (!categories.includes(body?.category)) return { error: '지출 분류를 고르세요.' };
  if (!isDateKey(body?.spentOn)) return { error: '쓴 날짜를 확인하세요.' };
  return { payload: { amount, category: body.category, spentOn: body.spentOn } };
}

/**
 * 근태 수정 내용 → `{ payload }` — 고칠 날(오늘 포함 지난 [ATTENDANCE_FIX_DAYS]일 안), 출근 'HH:MM', 퇴근 'HH:MM'(비우면 출근만 고침).
 * 퇴근은 출근보다 늦어야 한다(밤을 넘긴 근무는 기록을 그대로 두고 관리자가 판단).
 */
export function parseAttendancePayload(body, { today }) {
  const workDate = body?.workDate;
  if (!isDateKey(workDate)) return { error: '고칠 날짜를 확인하세요.' };
  if (workDate > today) return { error: '앞으로의 날은 고칠 수 없습니다.' };
  if (workDate < addDaysKey(today, -(ATTENDANCE_FIX_DAYS - 1))) {
    return { error: `지난 ${ATTENDANCE_FIX_DAYS}일 안의 기록만 고칠 수 있습니다.` };
  }
  const clockIn = parseHm(body?.clockIn);
  if (clockIn === null) return { error: '출근 시각을 확인하세요.' };
  const hasOut = body?.clockOut !== undefined && body?.clockOut !== null && body?.clockOut !== '';
  const clockOut = hasOut ? parseHm(body.clockOut) : null;
  if (hasOut && clockOut === null) return { error: '퇴근 시각을 확인하세요.' };
  if (clockOut !== null && clockOut <= clockIn) return { error: '퇴근 시각이 출근 시각보다 늦어야 합니다.' };
  return { payload: { workDate, clockIn: body.clockIn, clockOut: hasOut ? body.clockOut : null } };
}

const shortDate = (key) => `${Number(key.slice(5, 7))}/${Number(key.slice(8, 10))}`;

/** 제목을 비워 두면 쓸 이름. */
export function defaultApprovalTitle(kind, payload) {
  if (kind === 'leave') {
    const label = payload.leaveLabel ?? leaveTypeOf(payload.leaveType)?.label ?? '휴가';
    const range = payload.startDate === payload.endDate ? shortDate(payload.startDate) : `${shortDate(payload.startDate)}~${shortDate(payload.endDate)}`;
    return `${label} 신청 (${range}, ${halfDaysText(payload.halfDays)})`;
  }
  if (kind === 'expense') return `지출 결재 — ${payload.category} ${payload.amount.toLocaleString('ko-KR')}원`;
  if (kind === 'attendance') return `근태 수정 (${shortDate(payload.workDate)})`;
  return defaultFormTitle(kind, payload);
}

/** 제목·내용 → `{ title, body }`. 제목이 비면 [fallback]. */
export function parseDocumentText(input, fallback) {
  const title = typeof input?.title === 'string' ? input.title.trim() : '';
  const body = typeof input?.body === 'string' ? input.body.trim() : '';
  if (title.length > TITLE_MAX) return { error: `제목은 ${TITLE_MAX}자 이내로 쓰세요.` };
  if (body.length > BODY_MAX) return { error: `내용은 ${BODY_MAX}자 이내로 쓰세요.` };
  return { title: title || fallback, body: body || null };
}

/**
 * 이 문서를 볼 수 있는지 — 올린 사람, 결재선의 결재자, 참조자, 관리자, 대결한 사람, 그리고 지금 차례인 결재자의 대결을 맡은 사람
 * ([proxyFor]에 그 결재자 id).
 */
export function canViewDocument({ doc, steps, ccIds = [], userId, isManager = false, proxyFor = new Set() }) {
  if (isManager || doc.authorId === userId) return true;
  if (steps.some((s) => s.approverId === userId || s.actedById === userId) || ccIds.includes(userId)) return true;
  return steps.some((s) => s.status === 'pending' && s.approverId && proxyFor.has(s.approverId));
}

const sortSteps = (steps) => [...steps].sort((a, b) => a.stepOrder - b.stepOrder);

/** 칸의 단계 — 이 기능 전 문서는 단계가 없어 step_order가 곧 단계. */
export const stageOf = (step) => step.stage ?? step.stepOrder;

/**
 * 결재 진행 — [action]: 'approve' | 'reject' | 'withdraw'(올린 사람이 회수) | 'cancel'(승인된 문서를 관리자가 취소). 할 수 없으면
 * `{ error, status }`(HTTP 상태), 할 수 있으면 바꿀 값과 알릴 사람:
 * `{ doc: {...}, steps: [{ id, patch }], notify: { event, userIds } }`. [now]는 시험용.
 *
 * - 결재는 단계(stage)마다 — 같은 단계의 칸(합의)은 함께 차례(status 'pending')가 되고, 그 단계 사람이 모두 승인해야 다음 단계로 넘어간다.
 * - 승인: 지금 차례인 칸의 결재자만 — 또는 그 결재자가 자리를 비워 대결을 맡긴 사람([proxyFor]에 그 결재자 id — 이때 칸에 acted_by가 남는다).
 *   단계가 끝나면 다음 단계 사람들 차례로 넘기고(그 사람들에게 알림), 마지막 단계면 문서가 승인되고 올린 사람·참조자·앞선 결재자에게 알린다.
 *   전결 칸(role 'final')이 승인하면 남은 칸은 모두 생략(status 'skipped')되고 문서가 바로 승인된다. [signaturePath]가 있으면 그 칸에 적는다.
 * - 반려: 같은 사람만, 사유가 있어야 한다. 문서가 반려되고(같은 단계의 다른 차례 칸은 거둔다) 올린 사람·참조자·앞선 결재자에게 알린다.
 * - 회수: 올린 사람만, 진행 중일 때. 지금 차례였던 칸들의 차례를 거둔다.
 * - 취소: 관리자만, 승인된 문서를. 사유가 있어야 하고 올린 사람에게 알린다(휴가면 연차가 돌아가고 캘린더에서 빠진다).
 */
export function planDecision({
  doc,
  steps,
  ccIds = [],
  actorId,
  actorName = null,
  action,
  comment = null,
  isManager = false,
  proxyFor = new Set(),
  signaturePath = null,
  now = new Date(),
}) {
  const ordered = sortSteps(steps);
  const text = typeof comment === 'string' ? comment.trim() : '';
  if (text.length > COMMENT_MAX) return { error: `의견은 ${COMMENT_MAX}자 이내로 쓰세요.`, status: 400 };
  const pending = ordered.filter((s) => s.status === 'pending');
  const decidedApprovers = ordered.filter((s) => s.status === 'approved').map((s) => s.approverId);
  const everyone = (extra = []) => [...new Set([doc.authorId, ...ccIds, ...decidedApprovers, ...extra].filter(Boolean))];

  if (action === 'approve' || action === 'reject') {
    if (doc.status !== 'pending' || pending.length === 0) return { error: '이미 끝난 결재입니다.', status: 409 };
    // 내 칸이 먼저, 없으면 대결을 맡은 사람의 칸.
    const own = pending.find((s) => s.approverId === actorId) ?? null;
    const target = own ?? pending.find((s) => s.approverId && proxyFor.has(s.approverId)) ?? null;
    if (!target) return { error: '지금 결재할 차례가 아닙니다.', status: 403 };
    const proxy = own ? {} : { actedById: actorId, actedByName: actorName };
    const stage = stageOf(target);
    const othersInStage = pending.filter((s) => s.id !== target.id && stageOf(s) === stage);
    if (action === 'reject') {
      if (!text) return { error: '반려 사유를 쓰세요.', status: 400 };
      return {
        doc: { status: 'rejected', currentStep: null, decidedAt: now, updatedAt: now },
        steps: [
          { id: target.id, patch: { status: 'rejected', comment: text, decidedAt: now, ...proxy } },
          ...othersInStage.map((s) => ({ id: s.id, patch: { status: 'waiting' } })),
        ],
        notify: { event: 'rejected', userIds: everyone() },
      };
    }
    const approvedPatch = {
      status: 'approved',
      comment: text || null,
      decidedAt: now,
      ...proxy,
      ...(signaturePath ? { signaturePath } : {}),
    };
    const stepPatches = [{ id: target.id, patch: approvedPatch }];
    // 전결 — 남은 칸(같은 단계의 다른 차례 칸 포함)은 생략하고 문서를 끝낸다.
    if (target.role === 'final') {
      for (const s of ordered) {
        if (s.id !== target.id && (s.status === 'waiting' || s.status === 'pending')) {
          stepPatches.push({ id: s.id, patch: { status: 'skipped' } });
        }
      }
      return {
        doc: { status: 'approved', currentStep: null, decidedAt: now, updatedAt: now },
        steps: stepPatches,
        notify: { event: 'approved', userIds: everyone([target.approverId, actorId]) },
      };
    }
    // 같은 단계(합의)에 아직 차례인 사람이 있으면 기다린다.
    if (othersInStage.length > 0) {
      return { doc: { updatedAt: now }, steps: stepPatches, notify: { event: 'agreed', userIds: [] } };
    }
    const nextStage = ordered
      .filter((s) => s.status === 'waiting' && stageOf(s) > stage)
      .reduce((min, s) => (min === null || stageOf(s) < min ? stageOf(s) : min), null);
    if (nextStage !== null) {
      const next = ordered.filter((s) => s.status === 'waiting' && stageOf(s) === nextStage);
      for (const s of next) stepPatches.push({ id: s.id, patch: { status: 'pending' } });
      return {
        doc: { currentStep: nextStage, updatedAt: now },
        steps: stepPatches,
        notify: { event: 'next', userIds: next.map((s) => s.approverId).filter(Boolean) },
      };
    }
    return {
      doc: { status: 'approved', currentStep: null, decidedAt: now, updatedAt: now },
      steps: stepPatches,
      notify: { event: 'approved', userIds: everyone([target.approverId, actorId]) },
    };
  }

  if (action === 'withdraw') {
    if (doc.authorId !== actorId) return { error: '올린 사람만 회수할 수 있습니다.', status: 403 };
    if (doc.status !== 'pending') return { error: '진행 중인 결재만 회수할 수 있습니다.', status: 409 };
    return {
      doc: { status: 'withdrawn', currentStep: null, decidedAt: now, updatedAt: now },
      steps: pending.map((s) => ({ id: s.id, patch: { status: 'waiting' } })),
      notify: { event: 'withdrawn', userIds: [...new Set([...pending.map((s) => s.approverId), ...decidedApprovers])].filter(Boolean) },
    };
  }

  if (action === 'cancel') {
    if (!isManager) return { error: '관리자만 승인된 결재를 취소할 수 있습니다.', status: 403 };
    if (doc.status !== 'approved') return { error: '승인된 결재만 취소할 수 있습니다.', status: 409 };
    if (!text) return { error: '취소 사유를 쓰세요.', status: 400 };
    return {
      doc: { status: 'canceled', cancelReason: text, updatedAt: now },
      steps: [],
      notify: { event: 'canceled', userIds: everyone() },
    };
  }
  return { error: '알 수 없는 동작입니다.', status: 400 };
}

/**
 * 새 결재를 올릴 때 미리 채울 결재선 — 조직도의 상위자 사슬([managerChain] — 아직 없다, 나중에 조직도에 상위자를 정하면 넘긴다)이
 * 있으면 그것, 없으면 가장 최근에 저장한 결재선, 그것도 없으면 null(직접 고른다).
 */
export function suggestApprovalLine({ savedLines = [], managerChain = [] }) {
  if (managerChain.length > 0) return { approverIds: managerChain.slice(0, ORG_CHAIN_MAX), ccIds: [], source: 'org' };
  const latest = [...savedLines].sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))[0];
  if (!latest) return null;
  const roles = rolesOfLine(latest.line);
  return {
    approverIds: latest.approverIds,
    ccIds: latest.ccIds,
    source: 'saved',
    lineId: latest.id,
    ...(Object.keys(roles).length ? { roles } : {}),
  };
}

/** 저장해 둔 결재선의 역할 `[{ userId, role }]` → { userId: role }(결재가 아닌 것만). */
export function rolesOfLine(line) {
  const roles = {};
  for (const entry of Array.isArray(line) ? line : []) {
    if (entry?.userId && entry.role && entry.role !== 'approve') roles[entry.userId] = entry.role;
  }
  return roles;
}

// ── 문서 번호 ──

/** 문서 번호 앞머리(종류별) — "휴가-2026-0012". 관리자가 만든 양식은 '양식'. */
export const DOC_NUMBER_PREFIX = Object.freeze({
  leave: '휴가',
  expense: '지출',
  attendance: '근태',
  draft: '기안',
  trip: '출장',
  purchase: '구매',
  overtime: '연장',
  form: '양식',
});

/** [kind] 문서의 [year]년 [seq]번째 번호. */
export const docNumberOf = (kind, year, seq) => `${DOC_NUMBER_PREFIX[kind] ?? '결재'}-${year}-${String(seq).padStart(4, '0')}`;

// ── 대결(부재 중 대신 결재) ──

/** 대결을 맡길 수 있는 기간(일). */
export const DELEGATION_MAX_DAYS = 90;
export const DELEGATION_REASON_MAX = 100;

/**
 * 대결 설정 검사 — [userId]가 자리를 비우는 [startDate]~[endDate](오늘 이후로 끝나야, 90일까지)에 [delegateId]가 대신 결재한다. 자기 자신에게는
 * 못 맡기고, 맡을 사람은 이 범위에서 결재자로 고를 수 있는 사람([isCandidate])이어야 한다. [existing]은 그 사람의 다른 대결 설정 — 기간이
 * 겹치면 거절. `{ delegation: { startDate, endDate, delegateId, reason } }` | `{ error }`.
 */
export function parseDelegation({ userId, delegateId, startDate, endDate, reason, today, isCandidate, existing = [] }) {
  if (typeof delegateId !== 'string' || !delegateId) return { error: '대신 결재할 사람을 고르세요.' };
  if (delegateId === userId) return { error: '자기 자신에게는 맡길 수 없습니다.' };
  if (!isCandidate(delegateId)) return { error: '대신 결재할 수 없는 사람입니다(정회원 이상, 같은 범위의 사람만).' };
  const end = endDate ?? startDate;
  if (!isDateKey(startDate) || !isDateKey(end)) return { error: '기간을 확인하세요.' };
  if (end < startDate) return { error: '끝 날짜가 시작보다 빠릅니다.' };
  if (end < today) return { error: '이미 지난 기간입니다.' };
  if (addDaysKey(startDate, DELEGATION_MAX_DAYS - 1) < end) return { error: `대결은 ${DELEGATION_MAX_DAYS}일까지 맡길 수 있습니다.` };
  if (existing.some((d) => d.startDate <= end && startDate <= d.endDate)) return { error: '그 기간에 이미 맡겨 둔 대결이 있습니다.' };
  const text = typeof reason === 'string' ? reason.trim().slice(0, DELEGATION_REASON_MAX) || null : null;
  return { delegation: { startDate, endDate: end, delegateId, reason: text } };
}

/** [today]에 효력이 있는 대결들 → 맡긴 사람 id → 맡은 사람 id. */
export function activeDelegationMap(delegations, today) {
  const map = new Map();
  for (const d of delegations) if (d.startDate <= today && today <= d.endDate) map.set(d.userId, d.delegateId);
  return map;
}

/**
 * [actorId]가 지금 대신 결재할 수 있는 결재자들(Set) — 오늘 그 사람에게 대결을 맡긴 사람들. 단, 이 문서를 올린 사람이거나 이미 결재선에 있는
 * 사람은 대결로 한 자리를 더 차지할 수 없다(한 사람이 두 칸을 채우지 않게).
 */
export function proxyForOf({ actorId, doc, steps, delegationMap }) {
  const out = new Set();
  if (!doc || doc.authorId === actorId || steps.some((s) => s.approverId === actorId)) return out;
  for (const [absent, delegate] of delegationMap) if (delegate === actorId) out.add(absent);
  return out;
}

// ── 결재 통계 ──

const hoursBetween = (a, b) => (new Date(b) - new Date(a)) / 3_600_000;
const avg = (list) => (list.length ? Math.round((list.reduce((s, v) => s + v, 0) / list.length) * 10) / 10 : null);

/**
 * 결재 통계 — [docs]는 `{ doc, steps }` 목록(기간 안에 올린 문서). 종류별(건수·상태별·끝날 때까지 걸린 평균 시간)과 결재자별(결정 건수·승인·반려·
 * 대결로 처리된 건·지금 기다리는 건·차례가 된 뒤 결정까지 평균 시간), 그리고 전체 합계. [labelOf]는 종류 이름.
 */
export function approvalStats(docs, { labelOf = (doc) => APPROVAL_KIND_LABEL[doc.kind] ?? doc.kind } = {}) {
  const blank = () => ({ total: 0, pending: 0, approved: 0, rejected: 0, withdrawn: 0, canceled: 0, hours: [] });
  const totals = blank();
  const byKind = new Map();
  const byApprover = new Map();
  for (const { doc, steps } of docs) {
    const label = labelOf(doc);
    if (!byKind.has(label)) byKind.set(label, { ...blank(), label });
    for (const bucket of [totals, byKind.get(label)]) {
      bucket.total += 1;
      if (bucket[doc.status] !== undefined) bucket[doc.status] += 1;
      if (doc.decidedAt && (doc.status === 'approved' || doc.status === 'rejected')) bucket.hours.push(hoursBetween(doc.createdAt, doc.decidedAt));
    }
    // 결재자별 — 차례가 된 때는 앞 단계의 마지막 결정 시각(첫 단계면 올린 시각).
    const ordered = sortSteps(steps);
    for (const s of ordered) {
      if (!s.approverId) continue;
      if (!byApprover.has(s.approverId)) {
        byApprover.set(s.approverId, { userId: s.approverId, name: s.approverName, decided: 0, approved: 0, rejected: 0, proxied: 0, waiting: 0, hours: [] });
      }
      const row = byApprover.get(s.approverId);
      if (s.status === 'pending' && doc.status === 'pending') row.waiting += 1;
      if (s.status !== 'approved' && s.status !== 'rejected') continue;
      row.decided += 1;
      row[s.status] += 1;
      if (s.actedById) row.proxied += 1;
      const before = ordered.filter((o) => stageOf(o) < stageOf(s) && o.decidedAt).map((o) => new Date(o.decidedAt).getTime());
      const turnAt = before.length ? new Date(Math.max(...before)) : doc.createdAt;
      if (s.decidedAt) row.hours.push(hoursBetween(turnAt, s.decidedAt));
    }
  }
  const finish = ({ hours, ...rest }) => ({ ...rest, avgHours: avg(hours) });
  return {
    totals: finish(totals),
    byKind: [...byKind.values()].map(finish).sort((a, b) => b.total - a.total),
    byApprover: [...byApprover.values()].map(finish).sort((a, b) => b.decided + b.waiting - (a.decided + a.waiting)),
  };
}

/** 결재 알림함(approval_notifications.kind)의 종류 — 'request'는 "내 결재 차례"(새로 올라왔거나 앞 결재자가 승인해 넘어옴). */
export const APPROVAL_NOTIFICATION_KINDS = Object.freeze(['request', 'approved', 'rejected', 'withdrawn', 'canceled']);

/**
 * 결재 진행 [event](planDecision의 notify.event 또는 새로 올림 'created')를 알림 한 건 `{ kind, title, body }`로 — 푸시와 결재 알림함이
 * 같은 글을 쓴다. 모르는 사건이면 null.
 */
export function approvalNotificationOf(event, doc) {
  const label = approvalLabelOf(doc);
  switch (event) {
    case 'created':
    case 'next':
      return { kind: 'request', title: '결재 요청', body: `${doc.authorName} — ${doc.title}` };
    case 'approved':
      return { kind: 'approved', title: `${label} 결재 승인`, body: `승인되었습니다: ${doc.title}` };
    case 'rejected':
      return { kind: 'rejected', title: `${label} 결재 반려`, body: `반려되었습니다: ${doc.title}` };
    case 'withdrawn':
      return { kind: 'withdrawn', title: '결재 회수', body: `${doc.authorName}님이 회수했습니다: ${doc.title}` };
    case 'canceled':
      return { kind: 'canceled', title: `${label} 결재 취소`, body: `승인된 결재가 취소되었습니다: ${doc.title}` };
    default:
      return null;
  }
}
