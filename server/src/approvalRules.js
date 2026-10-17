import { addDaysKey, halfDaysText, isDateKey, leaveRequestAmount, leaveTypeOf } from './annualLeave.js';
import { parseHm } from './attendanceRules.js';

/**
 * 전자결재 규칙 — 결재선 검사, 종류별 내용 검사, 결재 진행(승인·반려·회수·취소). DB 없이 시험할 수 있게 계산만 모았다(groupware.js가
 * 쓴다). 결재는 결재선 순서대로 한 사람씩 하고(순차 결재), 누구든 반려하면 그 자리에서 끝난다.
 */

export const APPROVAL_KINDS = Object.freeze(['leave', 'expense', 'attendance']);
export const APPROVAL_KIND_LABEL = Object.freeze({ leave: '휴가', expense: '지출', attendance: '근태 수정' });
export const APPROVAL_STATUSES = Object.freeze(['pending', 'approved', 'rejected', 'withdrawn', 'canceled']);

export const APPROVERS_MAX = 5;
export const CC_MAX = 10;
export const TITLE_MAX = 100;
export const BODY_MAX = 2000;
export const COMMENT_MAX = 500;
export const LINE_NAME_MAX = 30;
export const SAVED_LINES_MAX = 20;
export const ATTACHMENTS_MAX = 5;
/** 근태 수정은 지난 이 날수 안의 날만(오래된 기록을 고쳐 임금 근거를 흔들지 못하게 — 그보다 오래된 건 관리자가 판단). */
export const ATTENDANCE_FIX_DAYS = 60;

export const EXPENSE_CATEGORIES = Object.freeze(['교통비', '식대', '비품·소모품', '출장비', '교육비', '접대비', '기타']);
export const EXPENSE_AMOUNT_MAX = 10_000_000_000;

const isIdList = (v) => Array.isArray(v) && v.every((id) => typeof id === 'string' && id.length > 0 && id.length <= 64);

/**
 * 결재선 검사 — 결재자 1~5명(순서대로), 참조자 0~10명. 같은 사람을 두 번 넣거나, 올린 사람 자신을 넣거나, 결재자를 참조자에도 넣으면
 * 거절. [isCandidate]는 이 범위에서 고를 수 있는 사람인지(groupwareScope.js canBeApprover + 같은 팀). 통과하면 `{ approverIds, ccIds }`.
 */
export function validateApprovalLine({ authorId, approverIds, ccIds = [], isCandidate }) {
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
  return { approverIds: [...approverIds], ccIds: [...ccIds] };
}

/** 휴가 신청 내용 → `{ payload }` — 양(halfDays)은 서버가 계산한다(앱이 보낸 값을 믿지 않는다). */
export function parseLeavePayload(body, holidays = new Set()) {
  const leaveType = body?.leaveType;
  const startDate = body?.startDate;
  const endDate = body?.endDate ?? startDate;
  const amount = leaveRequestAmount({ leaveType, startDate, endDate }, holidays);
  if (amount.error) return { error: amount.error };
  return { payload: { leaveType, startDate, endDate, halfDays: amount.halfDays } };
}

/** 지출 내용 → `{ payload }` — 금액(원, 정수), 분류, 쓴 날. */
export function parseExpensePayload(body) {
  const amount = Number(body?.amount);
  if (!Number.isInteger(amount) || amount <= 0) return { error: '금액을 원 단위 숫자로 넣으세요.' };
  if (amount > EXPENSE_AMOUNT_MAX) return { error: '금액이 너무 큽니다.' };
  if (!EXPENSE_CATEGORIES.includes(body?.category)) return { error: '지출 분류를 고르세요.' };
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
    const label = leaveTypeOf(payload.leaveType)?.label ?? '휴가';
    const range = payload.startDate === payload.endDate ? shortDate(payload.startDate) : `${shortDate(payload.startDate)}~${shortDate(payload.endDate)}`;
    return `${label} 신청 (${range}, ${halfDaysText(payload.halfDays)})`;
  }
  if (kind === 'expense') return `지출 결재 — ${payload.category} ${payload.amount.toLocaleString('ko-KR')}원`;
  return `근태 수정 (${shortDate(payload.workDate)})`;
}

/** 제목·내용 → `{ title, body }`. 제목이 비면 [fallback]. */
export function parseDocumentText(input, fallback) {
  const title = typeof input?.title === 'string' ? input.title.trim() : '';
  const body = typeof input?.body === 'string' ? input.body.trim() : '';
  if (title.length > TITLE_MAX) return { error: `제목은 ${TITLE_MAX}자 이내로 쓰세요.` };
  if (body.length > BODY_MAX) return { error: `내용은 ${BODY_MAX}자 이내로 쓰세요.` };
  return { title: title || fallback, body: body || null };
}

/** 이 문서를 볼 수 있는지 — 올린 사람, 결재선의 결재자, 참조자, 관리자. */
export function canViewDocument({ doc, steps, ccIds = [], userId, isManager = false }) {
  if (isManager || doc.authorId === userId) return true;
  return steps.some((s) => s.approverId === userId) || ccIds.includes(userId);
}

const sortSteps = (steps) => [...steps].sort((a, b) => a.stepOrder - b.stepOrder);

/**
 * 결재 진행 — [action]: 'approve' | 'reject' | 'withdraw'(올린 사람이 회수) | 'cancel'(승인된 문서를 관리자가 취소). 할 수 없으면
 * `{ error, status }`(HTTP 상태), 할 수 있으면 바꿀 값과 알릴 사람:
 * `{ doc: {...}, steps: [{ id, patch }], notify: { event, userIds } }`. [now]는 시험용.
 *
 * - 승인: 지금 차례(status 'pending')의 결재자만. 다음 결재자가 있으면 그 사람 차례로 넘기고(그 사람에게 알림), 마지막이면 문서가
 *   승인되고 올린 사람·참조자·앞선 결재자에게 알린다.
 * - 반려: 지금 차례의 결재자만, 사유가 있어야 한다. 문서가 반려되고 올린 사람·참조자·앞선 결재자에게 알린다.
 * - 회수: 올린 사람만, 진행 중일 때. 지금 차례였던 결재자의 차례를 거둔다.
 * - 취소: 관리자만, 승인된 문서를. 사유가 있어야 하고 올린 사람에게 알린다(휴가면 연차가 돌아가고 캘린더에서 빠진다).
 */
export function planDecision({ doc, steps, ccIds = [], actorId, action, comment = null, isManager = false, now = new Date() }) {
  const ordered = sortSteps(steps);
  const text = typeof comment === 'string' ? comment.trim() : '';
  if (text.length > COMMENT_MAX) return { error: `의견은 ${COMMENT_MAX}자 이내로 쓰세요.`, status: 400 };
  const current = ordered.find((s) => s.status === 'pending') ?? null;
  const decidedApprovers = ordered.filter((s) => s.status === 'approved').map((s) => s.approverId);
  const everyone = (extra = []) => [...new Set([doc.authorId, ...ccIds, ...decidedApprovers, ...extra].filter(Boolean))];

  if (action === 'approve' || action === 'reject') {
    if (doc.status !== 'pending' || !current) return { error: '이미 끝난 결재입니다.', status: 409 };
    if (current.approverId !== actorId) return { error: '지금 결재할 차례가 아닙니다.', status: 403 };
    if (action === 'reject') {
      if (!text) return { error: '반려 사유를 쓰세요.', status: 400 };
      return {
        doc: { status: 'rejected', currentStep: null, decidedAt: now, updatedAt: now },
        steps: [{ id: current.id, patch: { status: 'rejected', comment: text, decidedAt: now } }],
        notify: { event: 'rejected', userIds: everyone() },
      };
    }
    const next = ordered.find((s) => s.stepOrder > current.stepOrder && s.status === 'waiting') ?? null;
    const stepPatches = [{ id: current.id, patch: { status: 'approved', comment: text || null, decidedAt: now } }];
    if (next) {
      stepPatches.push({ id: next.id, patch: { status: 'pending' } });
      return {
        doc: { currentStep: next.stepOrder, updatedAt: now },
        steps: stepPatches,
        notify: { event: 'next', userIds: [next.approverId].filter(Boolean) },
      };
    }
    return {
      doc: { status: 'approved', currentStep: null, decidedAt: now, updatedAt: now },
      steps: stepPatches,
      notify: { event: 'approved', userIds: everyone([actorId]) },
    };
  }

  if (action === 'withdraw') {
    if (doc.authorId !== actorId) return { error: '올린 사람만 회수할 수 있습니다.', status: 403 };
    if (doc.status !== 'pending') return { error: '진행 중인 결재만 회수할 수 있습니다.', status: 409 };
    return {
      doc: { status: 'withdrawn', currentStep: null, decidedAt: now, updatedAt: now },
      steps: current ? [{ id: current.id, patch: { status: 'waiting' } }] : [],
      notify: { event: 'withdrawn', userIds: [current?.approverId, ...decidedApprovers].filter(Boolean) },
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
  if (managerChain.length > 0) return { approverIds: managerChain.slice(0, APPROVERS_MAX), ccIds: [], source: 'org' };
  const latest = [...savedLines].sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))[0];
  return latest ? { approverIds: latest.approverIds, ccIds: latest.ccIds, source: 'saved', lineId: latest.id } : null;
}

/** 결재 알림함(approval_notifications.kind)의 종류 — 'request'는 "내 결재 차례"(새로 올라왔거나 앞 결재자가 승인해 넘어옴). */
export const APPROVAL_NOTIFICATION_KINDS = Object.freeze(['request', 'approved', 'rejected', 'withdrawn', 'canceled']);

/**
 * 결재 진행 [event](planDecision의 notify.event 또는 새로 올림 'created')를 알림 한 건 `{ kind, title, body }`로 — 푸시와 결재 알림함이
 * 같은 글을 쓴다. 모르는 사건이면 null.
 */
export function approvalNotificationOf(event, doc) {
  const label = APPROVAL_KIND_LABEL[doc.kind] ?? '결재';
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
