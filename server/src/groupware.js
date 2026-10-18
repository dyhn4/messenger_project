import ExcelJS from 'exceljs';
import { Router } from 'express';
import { AUDIT, recordAudit } from './audit.js';
import { teamAccess, userAccess } from './access.js';
import { addDaysKey, halfDaysText, isDateKey, leaveBalance, leaveShortage, leaveTypeOf } from './annualLeave.js';
import {
  activeDelegationMap,
  APPROVAL_KINDS,
  approvalStats,
  docNumberOf,
  ORG_CHAIN_MAX,
  parseDelegation,
  proxyForOf,
  rolesOfLine,
  stageOf,
  approvalLabelOf,
  APPROVAL_STATUSES,
  APPROVERS_MAX,
  approvalNotificationOf,
  ATTACHMENTS_MAX,
  BODY_MAX,
  CC_MAX,
  canViewDocument,
  defaultApprovalTitle,
  LINE_NAME_MAX,
  parseAttendancePayload,
  parseDocumentText,
  parseExpensePayload,
  parseLeavePayload,
  planDecision,
  SAVED_LINES_MAX,
  suggestApprovalLine,
  TITLE_MAX,
  validateApprovalLine,
} from './approvalRules.js';
import {
  clockOutTarget,
  dateAtMinutes,
  hmText,
  localDateKey,
  monthDays,
  parseHm,
  summarizeMonth,
  validWorkHours,
} from './attendanceRules.js';
import {
  buildFormPayload,
  builtinKindOfId,
  BUILTIN_FORMS,
  CUSTOM_FORMS_MAX,
  FORM_KINDS,
  mergeForms,
  parseFormDefinition,
} from './approvalForms.js';
import { applyFormDefaults, parseFormDefaults } from './approvalFormDefaults.js';
import { applyFinalRule, FINAL_RULES_MAX, finalRuleDto, parseFinalRule, pickFinalRule } from './approvalFinalRules.js';
import { countFinalRules, deleteFinalRule, insertFinalRule, listFinalRules, updateFinalRule } from './db/queries/approvalFinalRules.js';
import { isDecidedStep, sealsFor, verifyDocument } from './approvalSeal.js';
import { sealKeys, signWith, uploadSha256, verifyWith } from './approvalSealKeys.js';
import { canSettle, checkSettlement, SETTLE_KINDS, settlementOf } from './settlementRules.js';
import { clientIp, isLanAddress, limits, retryLater, waitText } from './authGuard.js';
import {
  applyApprovalDecision,
  applyAttendanceCorrection,
  countPendingApprovals,
  countUnreadApprovalNotifications,
  deleteApprovalLine,
  findApprovalDocument,
  findApprovalDocumentRow,
  writeStepSeals,
  listSettlementsOf,
  findHireDate,
  findOverlappingLeave,
  insertApprovalDocument,
  insertApprovalLine,
  insertClockIn,
  insertApprovalNotifications,
  insertLeaveAdjustment,
  listApprovalDocuments,
  listApprovalLines,
  listApprovedLeaves,
  listCurrentDelegations,
  findGroupwareOptions,
  findWorkSchedule,
  listWorkSchedules,
  insertDelegation,
  findDelegation,
  deleteDelegation,
  listDocumentsCreatedBetween,
  listApprovedOvertime,
  listApprovedTrips,
  listApprovalTemplates,
  findApprovalTemplate,
  insertApprovalTemplate,
  updateApprovalTemplate,
  deleteApprovalTemplate,
  upsertBuiltinTemplate,
  listAttendanceInRange,
  listGroupwareMembers,
  listApprovalNotifications,
  listLeaveAdjustments,
  listRecentAttendance,
  markApprovalNotificationsRead,
  revertAttendanceCorrection,
  setHireDate,
  sumDeductedLeave,
  updateClockOut,
} from './db/queries/groupware.js';
import { getServerSettings, updateServerSettings } from './db/queries/serverSettings.js';
import { findTeamById, listTeamIdsForUser, listTeamMemberIds, updateTeam } from './db/queries/teams.js';
import { isUuid } from './favoritesRules.js';
import { checkFileRefs } from './fileRefs.js';
import {
  canBeApprover,
  canManageGroupware,
  effectiveGroupwareScope,
  groupwareScopeKey,
} from './groupwareScope.js';
import { HOLIDAYS } from './holidays.js';
import { fileFieldsDenial, sanitizeFileSize } from './messageLimits.js';
import { updateUser } from './db/queries/users.js';
import { optionsView } from './groupwareOptions.js';
import { managerChainWithPositions } from './orgTree.js';
import { applyLineRule, documentAmountOf, LINE_RULES_MAX, lineRuleDto, parseLineRule, pickLineRule, RULE_CHAIN_MAX } from './approvalLineRules.js';
import { countLineRules, deleteLineRule, insertLineRule, listLineRules, updateLineRule } from './db/queries/approvalLineRules.js';
import { listPositionOptions } from './db/queries/positionOptions.js';
import {
  CLOCK_IN_MODES,
  effectiveHours,
  monthBreakdown,
  parseClockIn,
  scheduledFlags,
  WEEKLY_LIMIT_MINUTES,
  WEEKLY_WARN_MINUTES,
  weekStartOf,
  weeklySummary,
  weeksOfMonth,
  workBreakdown,
  WORK_MODE_LABEL,
} from './workRules.js';
import { notifyGroupwarePush } from './push.js';
import { signFileUrl } from './upload.js';

/**
 * 그룹웨어 — 전자결재(휴가·지출·근태 수정), 법정 연차, 출퇴근 기록. 규칙은 approvalRules.js·annualLeave.js·attendanceRules.js,
 * 범위(팀마다 / 회사 전체)는 groupwareScope.js.
 *
 * 앱은 늘 지금 보고 있는 팀(teamId)을 보낸다 — 팀 범위면 그 팀 안에서, 회사 전체 범위면 팀과 상관없이 하나로 다룬다. 결재·근태
 * 관리자는 범위에 따라 다르다(canManageGroupware). 결재 알림은 푸시(접속해 있지 않은 기기)와 소켓 'groupware:changed'(목록·뱃지
 * 새로 고침)로 간다.
 */

/** 공휴일 날짜 모음(holidays.js — 2025~2027). 그 밖의 해는 주말만 쉬는 날로 센다. */
const HOLIDAY_DATES = new Set(HOLIDAYS.map((h) => h.date));
const DAY_MS = 24 * 60 * 60 * 1000;
const ms = (v) => (v ? new Date(v).getTime() : null);

/**
 * 이 요청의 그룹웨어 범위 — `{ scope, scopeKey, teamId, team, user, isManager, workStart, workEnd, settings }`, 쓸 수 없으면
 * `{ error, status }`. 팀 범위는 그 팀 멤버(또는 서버 운영자)여야 한다.
 */
export async function groupwareContext(userId, teamIdInput) {
  const settings = await getServerSettings();
  const scope = effectiveGroupwareScope(settings);
  const teamId = isUuid(teamIdInput) ? teamIdInput : null;
  let access;
  let team = null;
  if (scope === 'team') {
    if (!teamId) return { error: '팀을 먼저 고르세요.', status: 400 };
    [access, team] = await Promise.all([teamAccess(teamId, userId), findTeamById(teamId)]);
    if (!team) return { error: '팀을 찾을 수 없습니다.', status: 404 };
    if (!access.isMember && !access.isServerAdmin) return { error: '이 팀의 멤버가 아닙니다.', status: 403 };
  } else {
    access = await userAccess(userId);
  }
  const user = access.user;
  if (!user || user.deletedAt || user.suspendedAt) return { error: '사용할 수 없는 계정입니다.', status: 403 };
  const isManager = canManageGroupware({ scope, role: access.role, isOwner: access.isOwner, isServerAdmin: access.isServerAdmin });
  const workStart = scope === 'team' ? (team.workStartMinutes ?? settings.workStartMinutes) : settings.workStartMinutes;
  const workEnd = scope === 'team' ? (team.workEndMinutes ?? settings.workEndMinutes) : settings.workEndMinutes;
  const scopeKey = groupwareScopeKey(scope, teamId);
  // 범위 설정(휴가 종류·지출 분류·알림 — groupwareWork.js)과 내 근무 형태(유연근무).
  const [optionsRow, schedule] = await Promise.all([findGroupwareOptions(scopeKey), findWorkSchedule(scopeKey, user.id)]);
  return {
    settings,
    scope,
    scopeKey,
    teamId: scope === 'team' ? teamId : null,
    team,
    user,
    isManager,
    workStart,
    workEnd,
    options: optionsView(optionsRow),
    schedule,
    hours: effectiveHours(schedule, { workStart, workEnd }),
  };
}

/** 근무 형태 → 앱 모양(없으면 null — 범위의 근무 시간). */
export function scheduleDto(s) {
  if (!s) return null;
  return {
    mode: s.mode,
    label: WORK_MODE_LABEL[s.mode] ?? s.mode,
    start: s.startMinutes ?? null,
    end: s.endMinutes ?? null,
    coreStart: s.coreStartMinutes ?? null,
    coreEnd: s.coreEndMinutes ?? null,
  };
}

/** 범위 사람들의 근무 형태 → userId → 지각·조퇴 기준. */
async function hoursByUser(ctx) {
  const map = new Map();
  for (const s of await listWorkSchedules(ctx.scopeKey)) {
    map.set(s.userId, effectiveHours(s, { workStart: ctx.workStart, workEnd: ctx.workEnd }));
  }
  return (userId) => map.get(userId) ?? effectiveHours(null, { workStart: ctx.workStart, workEnd: ctx.workEnd });
}

/** 문서가 속한 범위에서 [userId]가 관리자인지 — 지금 고른 팀과 다른 범위의 문서를 열 때도 맞게. */
async function isManagerOfDocument(doc, userId) {
  if (doc.scopeKey === 'server') {
    const access = await userAccess(userId);
    return canManageGroupware({ scope: 'server', role: access.role, isServerAdmin: access.isServerAdmin });
  }
  if (!doc.teamId) return false;
  const access = await teamAccess(doc.teamId, userId);
  return canManageGroupware({ scope: 'team', role: access.role, isOwner: access.isOwner, isServerAdmin: access.isServerAdmin });
}

/** 응답을 끝내는 오류 도우미. */
export const fail = (res, { error, status = 400 }) => res.status(status).json({ error });

/** 결재자·참조자로 고를 수 있는 사람들(Map id → 구성원) — 이 범위의 정회원 이상, 정지·탈퇴 제외. */
export async function approverCandidates(ctx) {
  const members = await listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId });
  return new Map(members.filter(canBeApprover).map((m) => [m.id, m]));
}

function stepDto(s) {
  return {
    id: s.id,
    order: s.stepOrder,
    // 단계(같은 단계 = 합의로 동시에 차례)와 역할('approve' 결재 | 'agree' 합의 | 'final' 전결).
    stage: stageOf(s),
    role: s.role ?? 'approve',
    approverId: s.approverId,
    approverName: s.approverName,
    status: s.status,
    comment: s.comment ?? null,
    decidedAt: ms(s.decidedAt),
    // 대결 — 자리를 비운 결재자 대신 결정한 사람.
    actedByName: s.actedByName ?? null,
    // 승인할 때의 서명·도장(서명 링크).
    signatureUrl: s.signaturePath ? (signFileUrl(s.signaturePath) ?? null) : null,
    // 전자서명이 있는지(approvalSeal.js — 맞는지는 GET /groupware/documents/:id/verify).
    sealed: !!s.seal,
  };
}

/** 오늘 이 범위에서 효력이 있는 대결 — 맡긴 사람 id → 맡은 사람 id. */
async function delegationMapOf(scopeKey) {
  const today = localDateKey(new Date());
  return activeDelegationMap(await listCurrentDelegations(scopeKey, today), today);
}

/** 오늘 [userId]에게 대결을 맡긴 사람들(이 범위). */
async function proxySourcesOf(scopeKey, userId) {
  const map = await delegationMapOf(scopeKey);
  return [...map].filter(([, delegate]) => delegate === userId).map(([absent]) => absent);
}

function attachmentDtos(list) {
  if (!Array.isArray(list)) return [];
  return list.map((a) => ({
    fileUrl: signFileUrl(a.fileUrl, a.fileName ?? undefined) ?? null,
    fileName: a.fileName ?? null,
    fileSize: a.fileSize ?? null,
    mimeType: a.mimeType ?? null,
  }));
}

/** 앱에 내려줄 문서 모양 — [viewerId] 기준으로 지금 내 차례인지·회수·취소할 수 있는지를 함께. */
function documentDto({ doc, steps }, viewerId, { isManager = false, cc = null, proxySources = [], settlements = null } = {}) {
  // 차례인 칸 — 진행 중이면 그 단계, 승인됐으면 아직 확인하지 않은 후결 칸.
  const pending =
    doc.status === 'pending'
      ? steps.filter((s) => s.status === 'pending')
      : doc.status === 'approved'
        ? steps.filter((s) => s.status === 'pending' && s.role === 'post')
        : [];
  const own = pending.find((s) => s.approverId === viewerId) ?? null;
  // 대결 — 내가 올렸거나 이미 결재선에 있으면 대신 결재하지 않는다(approvalRules.js proxyForOf).
  const proxyFor = proxyForOf({ actorId: viewerId, doc, steps, delegationMap: new Map(proxySources.map((id) => [id, viewerId])) });
  const proxied = own ? null : (pending.find((s) => s.approverId && proxyFor.has(s.approverId)) ?? null);
  return {
    id: doc.id,
    kind: doc.kind,
    docNumber: doc.docNumber ?? null,
    title: doc.title,
    body: doc.body ?? null,
    payload: doc.payload,
    attachments: attachmentDtos(doc.attachments),
    status: doc.status,
    authorId: doc.authorId,
    authorName: doc.authorName,
    createdAt: ms(doc.createdAt),
    updatedAt: ms(doc.updatedAt),
    decidedAt: ms(doc.decidedAt),
    cancelReason: doc.cancelReason ?? null,
    canceledByName: doc.canceledByName ?? null,
    steps: steps.map(stepDto),
    ...(cc ? { cc } : {}),
    myTurn: !!(own || proxied),
    // 대결로 내 차례면 누구 대신인지.
    actingFor: proxied ? proxied.approverName : null,
    // 내 칸이 전결이면 승인하는 순간 결재가 끝난다(남은 칸은 생략).
    finalForMe: (own ?? proxied)?.role === 'final',
    // 내 칸이 합의면 "반대 의견으로 진행"을 할 수 있고, 후결이면 확인만 한다.
    canDisagree: (own ?? proxied)?.role === 'agree',
    postForMe: (own ?? proxied)?.role === 'post',
    canWithdraw: doc.status === 'pending' && doc.authorId === viewerId,
    canCancel: doc.status === 'approved' && isManager,
    // 정산(구매·출장 — settlementRules.js) — 이 결재를 정산하는 지출 결재(승인 → 결재 중 → 최근 순)와 "정산하기"를 누를 수 있는지.
    ...(SETTLE_KINDS.includes(doc.kind) && settlements
      ? { settlement: settlementOf(settlements), canSettle: canSettle(doc, viewerId, settlements) }
      : {}),
  };
}

/** 문서들([rows] `[{ doc }]`) 중 구매·출장을 정산하는 지출 결재들 — 문서 id → 목록. */
async function settlementsByDoc(rows) {
  const ids = rows.filter((r) => SETTLE_KINDS.includes(r.doc.kind)).map((r) => r.doc.id);
  const map = new Map(ids.map((id) => [id, []]));
  for (const s of await listSettlementsOf(ids)) map.get(s.settlesId)?.push(s);
  return map;
}

/** 휴가 하나 → 'YYYY-MM-DD' 날짜별 { halfDays, halfType }(근태 요약·내 근무 기록에서 휴가 날을 가리는 데). */
function leaveDaysOf(leave, into = new Map()) {
  const key = leave.payload?.leaveType;
  if (!key || !isDateKey(leave.payload?.startDate) || !isDateKey(leave.payload?.endDate)) return into;
  // 반차는 기본 종류(오전·오후 반차)뿐 — 관리자가 더한 종류는 하루 단위.
  const half = leaveTypeOf(key)?.half === true;
  const label = leave.payload?.leaveLabel ?? leaveTypeOf(key)?.label ?? '휴가';
  for (let day = leave.payload.startDate; day <= leave.payload.endDate; day = addDaysKey(day, 1)) {
    into.set(day, { halfDays: half ? 1 : 2, halfType: half ? key : null, type: key, label });
  }
  return into;
}

/** 승인된 출장 하나 → 그 기간의 날짜들을 [into]에(근태에서 결근으로 세지 않는다). */
function tripDaysOf(trip, into = new Set()) {
  const { startDate, endDate } = trip.payload ?? {};
  if (!isDateKey(startDate) || !isDateKey(endDate) || endDate < startDate) return into;
  for (let day = startDate; day <= endDate; day = addDaysKey(day, 1)) into.add(day);
  return into;
}

/** 승인된 연장근무들 → 날짜 → 분. */
function overtimeByDateOf(list, into = new Map()) {
  for (const o of list) {
    const day = o.payload?.workDate;
    const minutes = Number(o.payload?.minutes) || 0;
    if (isDateKey(day) && minutes > 0) into.set(day, (into.get(day) ?? 0) + minutes);
  }
  return into;
}

/** 이 범위에서 올릴 양식 — 기본 양식이면 켜져 있어야, 관리자가 만든 양식이면 이 범위의 켜진 양식이어야. */
async function formForSubmission(ctx, kind, formId) {
  const forms = mergeForms(await listApprovalTemplates(ctx.scopeKey));
  const form = kind === 'form' ? forms.find((f) => !f.builtin && f.id === formId) : forms.find((f) => f.id === `builtin:${kind}`);
  if (!form) return { error: '결재 양식을 찾을 수 없습니다.', status: 404 };
  if (!form.enabled) return { error: '지금은 쓰지 않는 양식입니다. 관리자에게 문의하세요.', status: 409 };
  return { id: form.builtin ? null : form.id, name: form.name, fields: form.fields, allowAttachments: form.allowAttachments };
}

/** 기본 결재선·참조자를 볼 양식 — 기본 양식은 종류로, 관리자가 만든 양식은 [templateId]로. 없으면 null. */
function formForLine(forms, kind, templateId) {
  if (kind === 'form') return forms.find((f) => !f.builtin && f.id === templateId) ?? null;
  return forms.find((f) => f.id === `builtin:${kind}`) ?? null;
}

const formDto = (f) => ({
  id: f.id,
  kind: f.kind,
  builtin: f.builtin,
  name: f.name,
  description: f.description ?? null,
  fields: f.fields,
  allowAttachments: f.allowAttachments,
  enabled: f.enabled,
  // 기본 결재선 `[{ userId, role }]`(null이면 정하지 않음)·기본 참조자(approvalFormDefaults.js).
  defaultLine: f.defaultLine ?? null,
  defaultCcIds: f.defaultCcIds ?? [],
});

/** 한 사람의 이번 연차 현황(annualLeave.js leaveBalance + 조정 목록). */
export async function balanceFor(ctx, userId) {
  const today = localDateKey(new Date());
  const hireDate = await findHireDate({ scope: ctx.scope, teamId: ctx.teamId, userId });
  const base = leaveBalance({ hireDate, today });
  if (!base.period) return { ...base, hireDate, adjustments: [] };
  const [used, adjustments] = await Promise.all([
    sumDeductedLeave({ scopeKey: ctx.scopeKey, userId, from: base.period.start, to: base.period.end }),
    listLeaveAdjustments({ scopeKey: ctx.scopeKey, userId, periodStart: base.period.start }),
  ]);
  const adjustmentHalfDays = adjustments.reduce((sum, a) => sum + a.halfDays, 0);
  return {
    ...leaveBalance({ hireDate, today, usedHalfDays: used.approved, pendingHalfDays: used.pending, adjustmentHalfDays }),
    hireDate,
    adjustments: adjustments.map((a) => ({
      id: a.id,
      halfDays: a.halfDays,
      reason: a.reason,
      createdByName: a.createdByName,
      createdAt: ms(a.createdAt),
    })),
  };
}

function attendanceDto(record, ctx, leave = null, hours = ctx.hours) {
  if (!record) return null;
  // 지각·조퇴는 그 사람의 근무 형태(유연근무 — workRules.js effectiveHours) 기준.
  const flags = scheduledFlags(record, hours ?? effectiveHours(null, { workStart: ctx.workStart, workEnd: ctx.workEnd }), {
    halfType: leave?.halfType ?? null,
    fullLeave: leave?.halfDays === 2,
  });
  return {
    id: record.id,
    workDate: record.workDate,
    clockInAt: ms(record.clockInAt),
    clockOutAt: ms(record.clockOutAt),
    clockInLan: record.clockInLan,
    clockOutLan: record.clockOutLan,
    note: record.note ?? null,
    corrected: !!record.corrected,
    originalClockInAt: ms(record.originalClockInAt),
    originalClockOutAt: ms(record.originalClockOutAt),
    // 출근 형태 — 'office' | 'field'(외근 — note에 장소) | 'remote'(재택).
    clockInMode: record.clockInMode ?? 'office',
    ...flags,
    // 휴게·연장·야간·휴일 근무(workRules.js workBreakdown — 퇴근을 눌러야 계산).
    breakdown: workBreakdown(record, { holidays: HOLIDAY_DATES }),
  };
}

/** 결재 알림 한 줄 → 클라이언트 모양(알림 센터 "결재" 탭). */
function approvalNotificationDto(n) {
  return {
    id: n.id,
    documentId: n.documentId,
    teamId: n.teamId ?? null,
    teamName: n.teamName ?? null,
    kind: n.kind,
    title: n.title,
    body: n.body,
    actorId: n.actorId ?? null,
    actorName: n.actorName ?? null,
    docKind: n.docKind ?? null,
    docStatus: n.docStatus ?? null,
    actionable: !!n.actionable,
    createdAt: ms(n.createdAt),
    readAt: ms(n.readAt),
  };
}

/**
 * 결재가 바뀌었음을 알린다 — 관련된 모두(올린 사람·결재자·참조자)에게 소켓으로 목록·뱃지를 새로 고치게 하고, [notifyIds](행동한 사람
 * 제외)에게는 결재 알림함에 한 줄 넣어 소켓 `approval:notification`(알림 센터 "결재" 탭)과 푸시로 알린다. 행동한 사람에게 와 있던 이
 * 문서의 알림(결재 요청 등)은 처리했으니 읽은 것으로 바꾼다. 휴가가 승인·취소되면 캘린더 "팀 휴가"도 새로 고치게 한다.
 */
async function announce(io, { doc, steps, ccIds, event, notifyIds, actorId, actorName }) {
  // 결재 차례가 된 사람이 대결을 맡겨 두었으면 맡은 사람에게도 알린다.
  const delegationMap = await delegationMapOf(doc.scopeKey).catch(() => new Map());
  const delegates = (event === 'created' || event === 'next' || event === 'post' ? notifyIds : [])
    .map((id) => delegationMap.get(id))
    .filter(Boolean);
  notifyIds = [...notifyIds, ...delegates];
  const involved = new Set([doc.authorId, ...steps.map((s) => s.approverId), ...ccIds, ...delegates].filter(Boolean));
  for (const id of involved) io.to(`user:${id}`).emit('groupware:changed', { documentId: doc.id, scopeKey: doc.scopeKey });
  // 결재는 이미 저장됐다 — 알림함·푸시가 실패해도(예: 마이그레이션 전) 응답은 성공으로 두고 기록만 남긴다.
  await announceNotifications(io, { doc, event, notifyIds, actorId, actorName }).catch((err) =>
    console.error('[groupware] 결재 알림함 기록 실패:', err?.message ?? err),
  );
  await announceLeaveCalendar(io, doc, event);
}

/** 결재 알림함에 줄을 넣고 소켓·푸시로 알린다. 행동한 사람에게 와 있던 이 문서의 알림은 읽음으로. */
async function announceNotifications(io, { doc, event, notifyIds, actorId, actorName }) {
  if (actorId && (await markApprovalNotificationsRead(actorId, { documentId: doc.id })) > 0) {
    io.to(`user:${actorId}`).emit('approval:notification-sync', { unreadCount: await countUnreadApprovalNotifications(actorId) });
  }
  const text = approvalNotificationOf(event, doc);
  const recipients = [...new Set(notifyIds)].filter((id) => id && id !== actorId);
  if (!text || recipients.length === 0) return;
  const rows = await insertApprovalNotifications(
    recipients.map((userId) => ({
      userId,
      documentId: doc.id,
      teamId: doc.teamId ?? null,
      kind: text.kind,
      title: text.title,
      body: text.body,
      actorId: actorId ?? null,
      actorName: actorName ?? null,
    })),
  );
  const teamName = doc.teamId ? ((await findTeamById(doc.teamId))?.name ?? null) : null;
  for (const row of rows) {
    const notification = approvalNotificationDto({
      ...row,
      teamName,
      docKind: doc.kind,
      docStatus: doc.status,
      actionable: text.kind === 'request',
    });
    const unreadCount = await countUnreadApprovalNotifications(row.userId);
    io.to(`user:${row.userId}`).emit('approval:notification', { notification, unreadCount });
    notifyGroupwarePush({
      userId: row.userId,
      title: text.title,
      body: text.body,
      documentId: doc.id,
      teamId: doc.teamId,
    }).catch((err) => console.error('[groupware] 알림 실패:', err?.message ?? err));
  }
}

/** 휴가·출장이 승인·취소되면 캘린더 "팀 휴가"·"출장"을 새로 고치게 한다. */
async function announceLeaveCalendar(io, doc, event) {
  if ((doc.kind === 'leave' || doc.kind === 'trip') && (event === 'approved' || event === 'canceled')) {
    const calendarId = doc.kind === 'trip' ? 'trips' : 'leaves';
    const teamIds = doc.teamId ? [doc.teamId] : doc.authorId ? await listTeamIdsForUser(doc.authorId) : [];
    for (const teamId of teamIds) {
      for (const id of await listTeamMemberIds(teamId)) io.to(`user:${id}`).emit('calendar:changed', { teamId, calendarId });
    }
  }
}

/** 지출 영수증 등 첨부 → 저장할 값 `{ attachments }` 또는 `{ error }`. 직접 올린 파일만(fileRefs.js). */
async function parseAttachments(input, senderId) {
  if (input === undefined || input === null) return { attachments: [] };
  if (!Array.isArray(input) || input.length > ATTACHMENTS_MAX) return { error: `첨부는 ${ATTACHMENTS_MAX}개까지입니다.` };
  const rows = [];
  for (const item of input) {
    if (typeof item?.fileUrl !== 'string' || !item.fileUrl) return { error: '첨부 파일을 확인할 수 없습니다.' };
    const fileName = typeof item.fileName === 'string' ? item.fileName : null;
    const mimeType = typeof item.mimeType === 'string' ? item.mimeType : null;
    const denial = fileFieldsDenial({ fileName, mimeType });
    if (denial) return { error: denial };
    rows.push({ raw: item.fileUrl, fileName, mimeType, fileSize: sanitizeFileSize(item.fileSize) });
  }
  const checked = await checkFileRefs(rows.map((r) => r.raw), { senderId });
  if (!checked.ok) return { error: checked.error };
  return {
    attachments: rows.map((r) => ({ fileUrl: checked.paths.get(r.raw), fileName: r.fileName, fileSize: r.fileSize, mimeType: r.mimeType })),
  };
}

export function createGroupwareRouter(io) {
  const router = Router();

  /** 결재 양식을 바꾼 기록(감사 로그). */
  function auditForm(ctx, detail) {
    recordAudit({
      actorId: ctx.user.id,
      actorName: ctx.user.name ?? ctx.user.username,
      action: AUDIT.groupwareForm,
      teamId: ctx.teamId,
      teamName: ctx.team?.name ?? null,
      targetType: 'approvalForm',
      detail,
    });
  }

  /** 양식이 바뀌면 그 범위 사람들의 그룹웨어 화면이 양식 목록을 다시 받게(groupware:changed — forms). */
  async function broadcastFormsChanged(ctx) {
    const payload = { forms: true, scopeKey: ctx.scopeKey };
    if (ctx.scope === 'team') {
      for (const id of await listTeamMemberIds(ctx.teamId)) io.to(`user:${id}`).emit('groupware:changed', payload);
    } else {
      io.emit('groupware:changed', payload);
    }
  }

  /** 범위를 정해 [handler](req, res, ctx)를 부른다 — 팀은 쿼리나 본문의 teamId. [managerOnly]면 관리자만. */
  const withContext =
    (handler, { managerOnly = false } = {}) =>
    async (req, res) => {
      const ctx = await groupwareContext(req.user.sub, req.query.teamId ?? req.body?.teamId);
      if (ctx.error) return fail(res, ctx);
      if (managerOnly && !ctx.isManager) return fail(res, { error: '결재·근태 관리자만 할 수 있습니다.', status: 403 });
      return handler(req, res, ctx);
    };

  /** 그룹웨어 화면을 열 때 — 범위, 관리자인지, 근무 시간, 휴가 종류·지출 분류, 내가 결재할 문서 수, 내 입사일. */
  router.get(
    '/groupware/context',
    withContext(async (req, res, ctx) => {
      const proxySources = await proxySourcesOf(ctx.scopeKey, ctx.user.id);
      const [pendingForMe, hireDate] = await Promise.all([
        countPendingApprovals(ctx.scopeKey, ctx.user.id, proxySources),
        findHireDate({ scope: ctx.scope, teamId: ctx.teamId, userId: ctx.user.id }),
      ]);
      res.json({
        scope: ctx.scope,
        scopeSetting: ctx.settings.groupwareScope ?? 'org',
        teamId: ctx.teamId,
        teamName: ctx.team?.name ?? null,
        isManager: ctx.isManager,
        workStart: ctx.workStart,
        workEnd: ctx.workEnd,
        today: localDateKey(new Date()),
        hireDate,
        pendingForMe,
        // 이 범위의 휴가 종류(꺼진 것도 — 예전 신청의 이름을 보이려고, 앱은 enabled만 고르게 한다)·지출 분류(관리자가 바꾼다).
        leaveTypes: ctx.options.leaveTypes,
        expenseCategories: ctx.options.expenseCategories,
        // 내 근무 형태(유연근무 — 없으면 null)와 지각·조퇴 기준, 주 52시간.
        schedule: scheduleDto(ctx.schedule),
        myWorkStart: ctx.hours.workStart,
        myWorkEnd: ctx.hours.workEnd,
        weeklyLimitMinutes: WEEKLY_LIMIT_MINUTES,
        weeklyWarnMinutes: WEEKLY_WARN_MINUTES,
        clockInModes: CLOCK_IN_MODES,
        limits: { approversMax: APPROVERS_MAX, ccMax: CC_MAX, attachmentsMax: ATTACHMENTS_MAX, titleMax: TITLE_MAX, bodyMax: BODY_MAX },
        inLan: isLanAddress(clientIp(req)),
        // 내 서명·도장(서명 링크) — 결재할 때 결재 칸에 들어간다.
        signatureUrl: ctx.user.signaturePath ? (signFileUrl(ctx.user.signaturePath) ?? null) : null,
      });
    }),
  );

  /** 결재자·참조자 후보(나 빼고 — ?includeSelf=1이면 나도: 양식의 사람 칸·관리자가 정하는 양식 기본 결재선). */
  router.get(
    '/groupware/candidates',
    withContext(async (req, res, ctx) => {
      const candidates = await approverCandidates(ctx);
      const includeSelf = req.query.includeSelf === '1';
      res.json(
        [...candidates.values()]
          .filter((m) => includeSelf || m.id !== ctx.user.id)
          .map((m) => ({ id: m.id, name: m.name, username: m.username }))
          .sort((a, b) => a.name.localeCompare(b.name, 'ko')),
      );
    }),
  );

  // ── 저장한 결재선 ──

  /**
   * 저장한 결재선과 새 결재에 미리 채울 결재선 `?kind=&templateId=&amount=` — [kind]·[amount](원)를 주면 그 문서에 맞는 결재선 규칙
   * (approvalLineRules.js)대로 상위자 사슬을 자르고(직책 기준이면 그 직책 이상까지) 늘 붙일 결재자·참조자를 더한다(`source: 'rule'`, `rule`).
   * 규칙이 없거나 종류를 안 주면 예전처럼 사슬 5명, 사슬도 없으면 가장 최근에 저장한 결재선. 양식(기본 양식은 종류, 관리자가 만든
   * 양식은 templateId)에 기본 결재선이 있으면 그것이 먼저고(`source: 'form'`), 기본 참조자는 참조자에 더한다(approvalFormDefaults.js).
   */
  router.get(
    '/groupware/approval-lines',
    withContext(async (req, res, ctx) => {
      const [lines, candidates, rules, templates, finalRules] = await Promise.all([
        listApprovalLines(ctx.user.id, ctx.scopeKey),
        approverCandidates(ctx),
        listLineRules(ctx.scopeKey),
        listApprovalTemplates(ctx.scopeKey),
        listFinalRules(ctx.scopeKey),
      ]);
      const kind = typeof req.query.kind === 'string' ? req.query.kind : null;
      const amount = Number.isFinite(Number(req.query.amount)) && req.query.amount !== '' ? Number(req.query.amount) : null;
      const rule = kind
        ? pickLineRule(
            rules.map((r) => r.rule),
            { kind, templateId: isUuid(req.query.templateId) ? req.query.templateId : null, amount },
          )
        : null;
      // 조직도의 상위자 사슬(orgTree.js) — 결재자로 고를 수 있는 사람만, 가까운 상위자부터. 조직도는 부서·직책 설정을 따르므로
      // 그룹웨어가 회사 전체여도 팀 단위 조직도면 지금 고른 팀의 조직도를 쓴다. 규칙이 있으면 더 길게 읽어 규칙이 자른다.
      const { chain: managerChain, positionOf } = await managerChainWithPositions({
        settings: ctx.settings,
        teamId: ctx.teamId ?? (isUuid(req.query.teamId) ? req.query.teamId : null),
        userId: ctx.user.id,
        isEligible: (id) => candidates.has(id),
        max: rule ? RULE_CHAIN_MAX : ORG_CHAIN_MAX,
      }).catch(() => ({ chain: [], positionOf: () => null }));
      let suggested = suggestApprovalLine({ savedLines: lines, managerChain });
      if (rule) {
        const ranks = new Map((await listPositionOptions()).map((o) => [o.label, o.sortOrder ?? 0]));
        const applied = applyLineRule(rule, {
          chain: managerChain,
          authorId: ctx.user.id,
          rankOf: (id) => ranks.get(positionOf(id)) ?? null,
          rankOfLabel: (label) => ranks.get(label) ?? null,
        });
        const keep = (id) => candidates.has(id);
        suggested = {
          approverIds: applied.approverIds.filter(keep),
          ccIds: applied.ccIds.filter(keep),
          source: 'rule',
          rule: lineRuleDto(rule, { templateName: rules.find((r) => r.rule.id === rule.id)?.templateName ?? null }),
        };
      }
      if (kind && FORM_KINDS.includes(kind)) {
        const form = formForLine(mergeForms(templates), kind, isUuid(req.query.templateId) ? req.query.templateId : null);
        suggested = applyFormDefaults({ form, authorId: ctx.user.id, suggested, isCandidate: (id) => candidates.has(id) });
      }
      // 전결 규정 — 맞는 규정이 있으면 미리 채운 결재선에도 입혀 보이고(올릴 때 서버가 다시 정한다), 어떤 규정인지 알려 준다.
      const finalRule = kind
        ? pickFinalRule(
            finalRules.map((r) => r.rule),
            { kind, templateId: isUuid(req.query.templateId) ? req.query.templateId : null, amount },
          )
        : null;
      if (finalRule && suggested?.approverIds?.length) {
        const ranks = new Map((await listPositionOptions()).map((o) => [o.label, o.sortOrder ?? 0]));
        const applied = applyFinalRule(finalRule, {
          approverIds: suggested.approverIds,
          roles: suggested.roles ?? {},
          rankOf: (id) => ranks.get(positionOf(id)) ?? null,
          rankOfLabel: (label) => ranks.get(label) ?? null,
        });
        suggested = { ...suggested, roles: applied.roles, finalUserId: applied.finalUserId };
      }
      res.json({
        lines: lines.map((l) => ({
          id: l.id,
          name: l.name,
          approverIds: l.approverIds,
          ccIds: l.ccIds,
          roles: rolesOfLine(l.line),
          createdAt: ms(l.createdAt),
        })),
        // 새 결재를 올릴 때 미리 채울 결재선 — 결재선 규칙, 조직도 상위자 사슬, 가장 최근에 저장한 결재선 순서(approvalRules.js suggestApprovalLine).
        suggested,
        // 이 문서에 맞는 전결 규정(없으면 null — approvalFinalRules.js).
        finalRule: finalRule
          ? finalRuleDto(finalRule, { templateName: finalRules.find((r) => r.rule.id === finalRule.id)?.templateName ?? null })
          : null,
      });
    }),
  );

  // ── 결재선 규칙(approvalLineRules.js) ──

  /** 이 범위의 결재선 규칙 — 누구나 본다(결재를 올릴 때 "규칙: 휴가 — 상위자 1명까지"로 보인다). */
  router.get(
    '/groupware/line-rules',
    withContext(async (req, res, ctx) => {
      res.json((await listLineRules(ctx.scopeKey)).map((r) => lineRuleDto(r.rule, { templateName: r.templateName ?? null })));
    }),
  );

  /** 규칙 입력 검사 — 직책 목록과 결재자 후보로. */
  async function parsedRule(ctx, body) {
    const [positions, candidates] = await Promise.all([listPositionOptions(), approverCandidates(ctx)]);
    return parseLineRule(body, { positionLabels: positions.map((o) => o.label), isCandidate: (id) => candidates.has(id) });
  }

  /** 규칙 만들기(그룹웨어 관리자) `{ kind, templateId?, minAmount?, mode, levels?, positionLabel?, extraApproverIds?, ccIds? }`. */
  router.post(
    '/groupware/line-rules',
    withContext(async (req, res, ctx) => {
      if (!ctx.isManager) return fail(res, { error: '결재선 규칙은 그룹웨어 관리자만 정할 수 있습니다.', status: 403 });
      const parsed = await parsedRule(ctx, req.body);
      if (parsed.error) return fail(res, parsed);
      if ((await countLineRules(ctx.scopeKey)) >= LINE_RULES_MAX) {
        return fail(res, { error: `결재선 규칙은 ${LINE_RULES_MAX}개까지입니다.` });
      }
      const row = await insertLineRule({ scopeKey: ctx.scopeKey, ...parsed.fields });
      res.status(201).json(lineRuleDto(row));
    }),
  );

  router.put(
    '/groupware/line-rules/:id',
    withContext(async (req, res, ctx) => {
      if (!ctx.isManager) return fail(res, { error: '결재선 규칙은 그룹웨어 관리자만 정할 수 있습니다.', status: 403 });
      if (!isUuid(req.params.id)) return fail(res, { error: '규칙을 찾을 수 없습니다.', status: 404 });
      const parsed = await parsedRule(ctx, req.body);
      if (parsed.error) return fail(res, parsed);
      const row = await updateLineRule(req.params.id, ctx.scopeKey, parsed.fields);
      if (!row) return fail(res, { error: '규칙을 찾을 수 없습니다.', status: 404 });
      res.json(lineRuleDto(row));
    }),
  );

  router.delete(
    '/groupware/line-rules/:id',
    withContext(async (req, res, ctx) => {
      if (!ctx.isManager) return fail(res, { error: '결재선 규칙은 그룹웨어 관리자만 정할 수 있습니다.', status: 403 });
      if (!isUuid(req.params.id) || !(await deleteLineRule(req.params.id, ctx.scopeKey))) {
        return fail(res, { error: '규칙을 찾을 수 없습니다.', status: 404 });
      }
      res.json({ ok: true });
    }),
  );


  // ── 전결 규정(approvalFinalRules.js) ──

  /** 이 범위의 전결 규정 — 누구나 본다(결재를 쓸 때 "전결 규정: 본부장 이상 전결"로 보인다). */
  router.get(
    '/groupware/final-rules',
    withContext(async (req, res, ctx) => {
      res.json((await listFinalRules(ctx.scopeKey)).map((r) => finalRuleDto(r.rule, { templateName: r.templateName ?? null })));
    }),
  );

  const parsedFinalRule = async (body) => parseFinalRule(body, { positionLabels: (await listPositionOptions()).map((o) => o.label) });

  /** 규정 만들기(그룹웨어 관리자) `{ kind, templateId?, minAmount?, positionLabel }`. */
  router.post(
    '/groupware/final-rules',
    withContext(async (req, res, ctx) => {
      if (!ctx.isManager) return fail(res, { error: '전결 규정은 그룹웨어 관리자만 정할 수 있습니다.', status: 403 });
      const parsed = await parsedFinalRule(req.body);
      if (parsed.error) return fail(res, parsed);
      if ((await countFinalRules(ctx.scopeKey)) >= FINAL_RULES_MAX) return fail(res, { error: `전결 규정은 ${FINAL_RULES_MAX}개까지입니다.` });
      const row = await insertFinalRule({ scopeKey: ctx.scopeKey, ...parsed.fields });
      res.status(201).json(finalRuleDto(row));
    }),
  );

  router.put(
    '/groupware/final-rules/:id',
    withContext(async (req, res, ctx) => {
      if (!ctx.isManager) return fail(res, { error: '전결 규정은 그룹웨어 관리자만 정할 수 있습니다.', status: 403 });
      if (!isUuid(req.params.id)) return fail(res, { error: '전결 규정을 찾을 수 없습니다.', status: 404 });
      const parsed = await parsedFinalRule(req.body);
      if (parsed.error) return fail(res, parsed);
      const row = await updateFinalRule(req.params.id, ctx.scopeKey, parsed.fields);
      if (!row) return fail(res, { error: '전결 규정을 찾을 수 없습니다.', status: 404 });
      res.json(finalRuleDto(row));
    }),
  );

  router.delete(
    '/groupware/final-rules/:id',
    withContext(async (req, res, ctx) => {
      if (!ctx.isManager) return fail(res, { error: '전결 규정은 그룹웨어 관리자만 정할 수 있습니다.', status: 403 });
      if (!isUuid(req.params.id) || !(await deleteFinalRule(req.params.id, ctx.scopeKey))) {
        return fail(res, { error: '전결 규정을 찾을 수 없습니다.', status: 404 });
      }
      res.json({ ok: true });
    }),
  );

  router.post(
    '/groupware/approval-lines',
    withContext(async (req, res, ctx) => {
      const name = typeof req.body?.name === 'string' ? req.body.name.trim() : '';
      if (!name || name.length > LINE_NAME_MAX) return fail(res, { error: `결재선 이름을 ${LINE_NAME_MAX}자 이내로 쓰세요.` });
      const existing = await listApprovalLines(ctx.user.id, ctx.scopeKey);
      if (existing.length >= SAVED_LINES_MAX) return fail(res, { error: `결재선은 ${SAVED_LINES_MAX}개까지 저장할 수 있습니다.` });
      const candidates = await approverCandidates(ctx);
      const line = validateApprovalLine({
        authorId: ctx.user.id,
        approverIds: req.body?.approverIds,
        ccIds: req.body?.ccIds ?? [],
        roles: req.body?.roles,
        isCandidate: (id) => candidates.has(id),
      });
      if (line.error) return fail(res, line);
      const row = await insertApprovalLine({
        ownerId: ctx.user.id,
        scopeKey: ctx.scopeKey,
        name,
        approverIds: line.approverIds,
        ccIds: line.ccIds,
        line: line.line.map(({ userId, role }) => ({ userId, role })),
      });
      res.status(201).json({
        id: row.id,
        name: row.name,
        approverIds: row.approverIds,
        ccIds: row.ccIds,
        roles: rolesOfLine(row.line),
        createdAt: ms(row.createdAt),
      });
    }),
  );

  /**
   * 결재 알림함(알림 센터 "결재" 탭) — 범위와 상관없이 내 것 전부(여러 팀에 걸쳐) 최근 50개와 안 읽은 수. 팀 범위를 따지지 않으니
   * withContext를 거치지 않는다.
   */
  router.get('/groupware/notifications', async (req, res) => {
    const [items, unreadCount] = await Promise.all([
      listApprovalNotifications(req.user.sub, 50),
      countUnreadApprovalNotifications(req.user.sub),
    ]);
    res.json({ items: items.map(approvalNotificationDto), unreadCount });
  });

  /**
   * 결재 알림 읽음 — 본문 `{ ids }` 또는 `{ documentId }`(그 문서의 내 알림 전부 — 푸시 알림을 눌러 문서를 열었을 때), 둘 다 없으면
   * 전부. 남은 안 읽은 수를 돌려주고 내 다른 기기에도 알린다.
   */
  router.post('/groupware/notifications/read', async (req, res) => {
    const raw = req.body?.ids;
    const documentId = req.body?.documentId ?? null;
    if (raw !== undefined && raw !== null && (!Array.isArray(raw) || raw.length > 200 || !raw.every(isUuid))) {
      return fail(res, { error: '알림 id를 확인하세요.', status: 400 });
    }
    if (documentId !== null && !isUuid(documentId)) return fail(res, { error: '결재 문서를 확인하세요.', status: 400 });
    if (!Array.isArray(raw) || raw.length > 0) await markApprovalNotificationsRead(req.user.sub, { ids: raw ?? null, documentId });
    const unreadCount = await countUnreadApprovalNotifications(req.user.sub);
    io.to(`user:${req.user.sub}`).emit('approval:notification-sync', { unreadCount });
    res.json({ unreadCount });
  });

  router.delete('/groupware/approval-lines/:id', async (req, res) => {
    if (!isUuid(req.params.id) || !(await deleteApprovalLine(req.params.id, req.user.sub))) {
      return fail(res, { error: '결재선을 찾을 수 없습니다.', status: 404 });
    }
    res.json({ ok: true });
  });

  // ── 결재 문서 ──

  /** 목록 — box: inbox(결재할 것) | mine(올린 것) | cc(참조) | done(결재한 것) | all(관리자). */
  router.get(
    '/groupware/documents',
    withContext(async (req, res, ctx) => {
      // archive — 보관함(끝난 문서 중 내가 볼 수 있는 것, 관리자는 범위 전부).
      const box = ['inbox', 'mine', 'cc', 'done', 'all', 'archive'].includes(req.query.box) ? req.query.box : 'inbox';
      if (box === 'all' && !ctx.isManager) return fail(res, { error: '관리자만 전체 문서를 볼 수 있습니다.', status: 403 });
      const kind = APPROVAL_KINDS.includes(req.query.kind) ? req.query.kind : null;
      const status = APPROVAL_STATUSES.includes(req.query.status) ? req.query.status : null;
      const before = Number(req.query.before) > 0 ? Number(req.query.before) : null;
      const proxySources = await proxySourcesOf(ctx.scopeKey, ctx.user.id);
      // 정산 안 된 승인 구매·출장만(?unsettled=1) — 관리자는 전체에서, 아니면 내가 올린 것에서.
      const unsettled = req.query.unsettled === '1' || req.query.unsettled === 'true';
      // 검색 — ?q=(제목·문서 번호·올린 사람, 100자까지) &from=&to=(올린 날 'YYYY-MM-DD').
      const q = typeof req.query.q === 'string' && req.query.q.trim() ? req.query.q.trim().slice(0, 100) : null;
      const from = isDateKey(req.query.from) ? req.query.from : null;
      const to = isDateKey(req.query.to) ? req.query.to : null;
      if (from && to && to < from) return fail(res, { error: '끝 날짜가 시작보다 빠릅니다.' });
      const rows = await listApprovalDocuments({
        scopeKey: ctx.scopeKey,
        box,
        userId: ctx.user.id,
        kind,
        status,
        before,
        proxyFor: proxySources,
        unsettled,
        q,
        from,
        to,
        isManager: ctx.isManager,
      });
      const settlements = await settlementsByDoc(rows);
      res.json(
        rows.map((r) =>
          documentDto(r, ctx.user.id, { isManager: ctx.isManager, proxySources, settlements: settlements.get(r.doc.id) ?? null }),
        ),
      );
    }),
  );

  router.get('/groupware/documents/:id', async (req, res) => {
    if (!isUuid(req.params.id)) return fail(res, { error: '결재 문서를 찾을 수 없습니다.', status: 404 });
    const found = await findApprovalDocument(req.params.id);
    if (!found) return fail(res, { error: '결재 문서를 찾을 수 없습니다.', status: 404 });
    const isManager = await isManagerOfDocument(found.doc, req.user.sub);
    const proxySources = await proxySourcesOf(found.doc.scopeKey, req.user.sub);
    const proxyFor = proxyForOf({ actorId: req.user.sub, ...found, delegationMap: new Map(proxySources.map((id) => [id, req.user.sub])) });
    if (!canViewDocument({ ...found, userId: req.user.sub, isManager, proxyFor })) {
      return fail(res, { error: '결재 문서를 찾을 수 없습니다.', status: 404 });
    }
    const members = found.ccIds.length
      ? await listGroupwareMembers({ scope: found.doc.scopeKey === 'server' ? 'server' : 'team', teamId: found.doc.teamId })
      : [];
    const names = new Map(members.map((m) => [m.id, m.name]));
    const cc = found.ccIds.map((id) => ({ id, name: names.get(id) ?? '(알 수 없음)' }));
    const settlements = (await settlementsByDoc([found])).get(found.doc.id) ?? null;
    res.json(documentDto(found, req.user.sub, { isManager, cc, proxySources, settlements }));
  });

  /**
   * 전자서명 검증(approvalSeal.js) — 문서를 볼 수 있는 사람. 결정한 칸마다 서버 키로 한 서명이 지금 DB의 내용·결정 기록·서명 그림 파일과
   * 맞는지 → `{ digest(문서 지문), fingerprint(서버 키 지문), ok, steps: [{ id, order, approverName, status, result }] }`.
   */
  router.get('/groupware/documents/:id/verify', async (req, res) => {
    if (!isUuid(req.params.id)) return fail(res, { error: '결재 문서를 찾을 수 없습니다.', status: 404 });
    const found = await findApprovalDocument(req.params.id);
    if (!found) return fail(res, { error: '결재 문서를 찾을 수 없습니다.', status: 404 });
    const isManager = await isManagerOfDocument(found.doc, req.user.sub);
    const proxySources = await proxySourcesOf(found.doc.scopeKey, req.user.sub);
    const proxyFor = proxyForOf({ actorId: req.user.sub, ...found, delegationMap: new Map(proxySources.map((id) => [id, req.user.sub])) });
    if (!canViewDocument({ ...found, userId: req.user.sub, isManager, proxyFor })) {
      return fail(res, { error: '결재 문서를 찾을 수 없습니다.', status: 404 });
    }
    const keys = await sealKeys();
    const hashes = new Map();
    for (const s of found.steps) {
      if (isDecidedStep(s) && s.signatureHash && s.signaturePath) hashes.set(s.id, await uploadSha256(s.signaturePath));
    }
    const result = verifyDocument({
      doc: found.doc,
      steps: found.steps,
      verify: verifyWith(keys),
      fileHashOf: (s) => (hashes.has(s.id) ? hashes.get(s.id) : undefined),
    });
    res.json({ ...result, fingerprint: keys.fingerprint });
  });

  /** 결재 전자서명의 서버 공개 키와 지문 — 인쇄한 문서를 바깥에서 맞춰 볼 때. */
  router.get('/groupware/seal-key', async (req, res) => {
    const keys = await sealKeys();
    res.json({ fingerprint: keys.fingerprint, publicKey: keys.publicKeyPem, algorithm: 'Ed25519' });
  });

  // ── 결재 양식 ──

  /**
   * 이 범위의 결재 양식 — 기본 양식(일반 기안서·출장 신청·구매 요청·연장근무 신청)과 관리자가 만든 양식. 관리자가 아니면 켜진 것만,
   * 관리자는 꺼진 것까지(관리 탭). 휴가·지출·근태 수정은 전용 화면이 있어 여기 없다.
   */
  router.get(
    '/groupware/forms',
    withContext(async (req, res, ctx) => {
      const forms = mergeForms(await listApprovalTemplates(ctx.scopeKey));
      res.json(forms.filter((f) => f.enabled || ctx.isManager).map(formDto));
    }),
  );

  /** 양식 만들기(관리자) `{ name, description?, fields: [{ label, type, required?, options? }], allowAttachments? }`. */
  router.post(
    '/groupware/forms',
    withContext(
      async (req, res, ctx) => {
        const parsed = parseFormDefinition(req.body);
        if (parsed.error) return fail(res, parsed);
        const rows = await listApprovalTemplates(ctx.scopeKey);
        const custom = rows.filter((r) => !r.builtinKey);
        if (custom.length >= CUSTOM_FORMS_MAX) return fail(res, { error: `양식은 ${CUSTOM_FORMS_MAX}개까지 만들 수 있습니다.` });
        if (mergeForms(rows).some((f) => f.name === parsed.form.name)) return fail(res, { error: '같은 이름의 양식이 있습니다.', status: 409 });
        const defaults = await parsedFormDefaults(ctx, req.body);
        if (defaults.error) return fail(res, defaults);
        const row = await insertApprovalTemplate({
          scopeKey: ctx.scopeKey,
          ...parsed.form,
          ...defaults.defaults,
          sortOrder: 100 + custom.reduce((max, r) => Math.max(max, (r.sortOrder ?? 100) - 100), -1) + 1,
          createdBy: ctx.user.id,
          createdByName: ctx.user.name ?? ctx.user.username,
        });
        auditForm(ctx, `양식 만들기 — ${row.name}`);
        broadcastFormsChanged(ctx);
        res.status(201).json(formDto(mergeForms([row]).find((f) => f.id === row.id)));
      },
      { managerOnly: true },
    ),
  );

  /** 기본 결재선·참조자 입력 검사(결재자 후보로) — 본문에 둘 다 없으면 `{ defaults: {} }`(그대로). */
  async function parsedFormDefaults(ctx, body) {
    if (!body || (!('defaultLine' in body) && !('defaultCcIds' in body))) return { defaults: {} };
    const candidates = await approverCandidates(ctx);
    return parseFormDefaults(body, { isCandidate: (id) => candidates.has(id) });
  }

  /**
   * 양식 바꾸기(관리자) — 기본 양식은 `{ enabled?, defaultLine?, defaultCcIds? }`, 관리자가 만든 양식은 `{ name?, description?, fields?,
   * allowAttachments?, enabled?, defaultLine?, defaultCcIds? }`. 기본 결재선·참조자는 둘 중 하나만 보내면 다른 하나는 그대로.
   */
  router.patch(
    '/groupware/forms/:id',
    withContext(
      async (req, res, ctx) => {
        const body = req.body ?? {};
        const builtin = builtinKindOfId(req.params.id);
        const current = builtin ? mergeForms(await listApprovalTemplates(ctx.scopeKey)).find((f) => f.id === req.params.id) : null;
        const defaults = await parsedFormDefaults(ctx, {
          ...('defaultLine' in body || 'defaultCcIds' in body
            ? { defaultLine: current?.defaultLine ?? null, defaultCcIds: current?.defaultCcIds ?? [] }
            : {}),
          ...body,
        });
        if (defaults.error) return fail(res, defaults);
        const hasDefaults = Object.keys(defaults.defaults).length > 0;
        if (builtin) {
          if (typeof body.enabled !== 'boolean' && !hasDefaults) {
            return fail(res, { error: '기본 양식은 켜고 끄기와 기본 결재선만 바꿀 수 있습니다.' });
          }
          const enabled = typeof body.enabled === 'boolean' ? body.enabled : current.enabled;
          await upsertBuiltinTemplate(ctx.scopeKey, builtin, {
            name: BUILTIN_FORMS[builtin].name,
            enabled,
            sortOrder: current.sortOrder,
            defaults: hasDefaults ? defaults.defaults : null,
          });
          if (typeof body.enabled === 'boolean') {
            auditForm(ctx, `기본 양식 ${body.enabled ? '켜기' : '끄기'} — ${BUILTIN_FORMS[builtin].name}`);
          }
          if (hasDefaults) auditForm(ctx, `기본 결재선 바꾸기 — ${BUILTIN_FORMS[builtin].name}`);
          broadcastFormsChanged(ctx);
          return res.json(formDto({ ...current, enabled, ...defaults.defaults }));
        }
        const row = isUuid(req.params.id) ? await findApprovalTemplate(req.params.id) : null;
        if (!row || row.builtinKey || row.scopeKey !== ctx.scopeKey) return fail(res, { error: '결재 양식을 찾을 수 없습니다.', status: 404 });
        const patch = {};
        if (['name', 'description', 'fields', 'allowAttachments'].some((k) => k in body)) {
          const parsed = parseFormDefinition({
            name: body.name ?? row.name,
            description: 'description' in body ? body.description : row.description,
            fields: body.fields ?? row.fields,
            allowAttachments: 'allowAttachments' in body ? body.allowAttachments : row.allowAttachments,
          });
          if (parsed.error) return fail(res, parsed);
          const others = mergeForms(await listApprovalTemplates(ctx.scopeKey)).filter((f) => f.id !== row.id);
          if (others.some((f) => f.name === parsed.form.name)) return fail(res, { error: '같은 이름의 양식이 있습니다.', status: 409 });
          Object.assign(patch, parsed.form);
        }
        if (typeof body.enabled === 'boolean') patch.enabled = body.enabled;
        if (hasDefaults) {
          // 한쪽만 보냈으면 다른 쪽은 지금 값(관리자가 만든 양식 줄).
          const next = await parsedFormDefaults(ctx, {
            defaultLine: 'defaultLine' in body ? body.defaultLine : row.defaultLine,
            defaultCcIds: 'defaultCcIds' in body ? body.defaultCcIds : row.defaultCcIds,
          });
          if (next.error) return fail(res, next);
          Object.assign(patch, next.defaults);
        }
        if (Object.keys(patch).length === 0) return fail(res, { error: '바꿀 내용이 없습니다.' });
        const updated = await updateApprovalTemplate(row.id, patch);
        auditForm(ctx, `양식 바꾸기 — ${updated.name}`);
        broadcastFormsChanged(ctx);
        res.json(formDto(mergeForms([updated]).find((f) => f.id === updated.id)));
      },
      { managerOnly: true },
    ),
  );

  /** 양식 지우기(관리자, 관리자가 만든 양식만) — 이미 올린 문서는 칸 정의를 적어 두어 그대로 보인다. */
  router.delete(
    '/groupware/forms/:id',
    withContext(
      async (req, res, ctx) => {
        if (builtinKindOfId(req.params.id)) return fail(res, { error: '기본 양식은 지울 수 없습니다(끌 수는 있습니다).' });
        const row = isUuid(req.params.id) ? await findApprovalTemplate(req.params.id) : null;
        if (!row || row.builtinKey || row.scopeKey !== ctx.scopeKey) return fail(res, { error: '결재 양식을 찾을 수 없습니다.', status: 404 });
        await deleteApprovalTemplate(row.id);
        auditForm(ctx, `양식 지우기 — ${row.name}`);
        broadcastFormsChanged(ctx);
        res.json({ ok: true });
      },
      { managerOnly: true },
    ),
  );

  /** 결재 올리기 — kind: leave | expense | attendance, 또는 양식(draft | trip | purchase | overtime | form — values, form은 formId), 결재선(approverIds 순서대로)·참조자(ccIds). */
  router.post(
    '/groupware/documents',
    withContext(async (req, res, ctx) => {
      const body = req.body ?? {};
      if (!APPROVAL_KINDS.includes(body.kind)) return fail(res, { error: '결재 종류를 고르세요.' });
      const wait = limits.approvalCreateUser.hit(ctx.user.id);
      if (wait > 0) return retryLater(res, wait, `결재를 너무 많이 올렸습니다. ${waitText(wait)} 뒤에 다시 시도하세요.`);

      const today = localDateKey(new Date());
      let parsed;
      // 양식으로 올리는 종류(일반 기안서·출장·구매·연장근무·관리자가 만든 양식) — 칸 정의대로 검사하고 칸 정의를 문서에 같이 적는다.
      let form = null;
      const candidates = await approverCandidates(ctx);
      if (FORM_KINDS.includes(body.kind)) {
        form = await formForSubmission(ctx, body.kind, body.formId);
        if (form.error) return fail(res, form);
        // 사람 칸 — 이 범위에서 결재자로 고를 수 있는 사람과 올리는 사람 자신(그때의 이름으로 적는다).
        const personOf = (id) =>
          candidates.get(id) ?? (id === ctx.user.id ? { id: ctx.user.id, name: ctx.user.name ?? ctx.user.username } : null);
        parsed = buildFormPayload({ kind: body.kind, template: form, values: body.values, today, personOf });
      } else if (body.kind === 'leave') parsed = parseLeavePayload(body, HOLIDAY_DATES, ctx.options.leaveTypes);
      else if (body.kind === 'expense') parsed = parseExpensePayload(body, ctx.options.expenseCategories);
      else parsed = parseAttendancePayload(body, { today });
      if (parsed.error) return fail(res, parsed);
      const payload = parsed.payload;

      // 정산 — 지출 결재가 승인된 구매 요청·출장 신청을 가리키면(settlesId) 그 결재를 확인하고 그때의 제목·번호·예산을 적는다.
      let settlesId = null;
      if (body.kind === 'expense' && body.settlesId !== undefined && body.settlesId !== null) {
        const source = isUuid(body.settlesId) ? await findApprovalDocumentRow(body.settlesId) : null;
        const checked = checkSettlement({
          source,
          userId: ctx.user.id,
          scopeKey: ctx.scopeKey,
          settlements: source ? await listSettlementsOf([source.id]) : [],
        });
        if (checked.error) return fail(res, checked);
        payload.settles = checked.settles;
        settlesId = source.id;
      }

      if (body.kind === 'leave') {
        const overlap = await findOverlappingLeave({ scopeKey: ctx.scopeKey, userId: ctx.user.id, from: payload.startDate, to: payload.endDate });
        if (overlap) return fail(res, { error: `그 기간에 이미 신청한 휴가가 있습니다: ${overlap.title}`, status: 409 });
        if (payload.deducts) {
          const balance = await balanceFor(ctx, ctx.user.id);
          const shortage = leaveShortage(balance, payload.halfDays);
          if (shortage) return fail(res, { error: shortage, status: 409 });
        }
      }

      const text = parseDocumentText(body, defaultApprovalTitle(body.kind, payload));
      if (text.error) return fail(res, text);
      const files =
        body.kind === 'expense' || form?.allowAttachments ? await parseAttachments(body.attachments, ctx.user.id) : { attachments: [] };
      if (files.error) return fail(res, files);

      // 전결 규정 — 종류·양식·문서 금액에 맞는 규정이 있으면 결재선에서 그 직책 이상인 첫 결재자를 전결로(올리는 사람이 고른 전결은 지움).
      let roles = body.roles;
      const finalRule = pickFinalRule(
        (await listFinalRules(ctx.scopeKey)).map((r) => r.rule),
        { kind: body.kind, templateId: form?.id ?? null, amount: documentAmountOf(body.kind, payload) },
      );
      if (finalRule && Array.isArray(body.approverIds)) {
        const [{ positionOf }, positions] = await Promise.all([
          managerChainWithPositions({ settings: ctx.settings, teamId: ctx.teamId, userId: ctx.user.id, isEligible: () => false, max: 0 }).catch(
            () => ({ positionOf: () => null }),
          ),
          listPositionOptions(),
        ]);
        const ranks = new Map(positions.map((o) => [o.label, o.sortOrder ?? 0]));
        const applied = applyFinalRule(finalRule, {
          approverIds: body.approverIds,
          roles: body.roles && typeof body.roles === 'object' && !Array.isArray(body.roles) ? body.roles : {},
          rankOf: (id) => ranks.get(positionOf(id)) ?? null,
          rankOfLabel: (label) => ranks.get(label) ?? null,
        });
        roles = applied.roles;
        // 문서에 그때의 규정을 적어 둔다(상세에 "전결 규정: 본부장 이상").
        payload.finalRule = { positionLabel: finalRule.positionLabel, minAmount: finalRule.minAmount ?? null, applied: !!applied.finalUserId };
      }
      const line = validateApprovalLine({
        authorId: ctx.user.id,
        approverIds: body.approverIds,
        ccIds: body.ccIds ?? [],
        roles,
        isCandidate: (id) => candidates.has(id),
      });
      if (line.error) return fail(res, line);

      const doc = await insertApprovalDocument({
        numberOf: (year, seq) => docNumberOf(body.kind, year, seq),
        doc: {
          scopeKey: ctx.scopeKey,
          teamId: ctx.teamId,
          kind: body.kind,
          authorId: ctx.user.id,
          authorName: ctx.user.name ?? ctx.user.username,
          title: text.title,
          body: text.body,
          payload,
          attachments: files.attachments.length ? files.attachments : null,
          settlesId,
        },
        approvers: line.line.map(({ userId, role, stage }) => ({ id: userId, name: candidates.get(userId).name, role, stage })),
        ccIds: line.ccIds,
      });
      const found = await findApprovalDocument(doc.id);
      await announce(io, {
        ...found,
        event: 'created',
        notifyIds: found.steps.filter((s) => s.status === 'pending').map((s) => s.approverId),
        actorId: ctx.user.id,
        actorName: ctx.user.name ?? ctx.user.username,
      });
      res.status(201).json(documentDto(found, ctx.user.id, { isManager: ctx.isManager }));
    }),
  );

  /** 승인·반려·회수·취소 — 규칙은 approvalRules.js planDecision. 근태 수정이 승인되면 기록을 고치고, 취소되면 되돌린다. */
  for (const action of ['approve', 'reject', 'withdraw', 'cancel', 'disagree']) {
    router.post(`/groupware/documents/:id/${action}`, async (req, res) => {
      if (!isUuid(req.params.id)) return fail(res, { error: '결재 문서를 찾을 수 없습니다.', status: 404 });
      const found = await findApprovalDocument(req.params.id);
      if (!found) return fail(res, { error: '결재 문서를 찾을 수 없습니다.', status: 404 });
      const isManager = action === 'cancel' ? await isManagerOfDocument(found.doc, req.user.sub) : false;
      const actor = (await userAccess(req.user.sub)).user;
      const delegationMap = await delegationMapOf(found.doc.scopeKey);
      // 전자서명 — 서버 키와 지금 서명 그림의 SHA-256(키를 못 읽으면 — 예: 마이그레이션 전 — 서명 없이 결정만 한다).
      const keys = action === 'withdraw' || action === 'cancel' ? null : await sealKeys().catch((err) => (console.error('[groupware] 전자서명 키:', err?.message ?? err), null));
      const signatureHash = keys && actor?.signaturePath ? await uploadSha256(actor.signaturePath) : null;
      const outcome = await applyApprovalDecision(
        req.params.id,
        async ({ doc, steps, ccIds }) => {
          // 대결 — 오늘 나에게 맡긴 결재자의 차례면 대신 결정한다(내가 올렸거나 이미 결재선에 있으면 안 됨).
          const proxyFor = proxyForOf({ actorId: req.user.sub, doc, steps, delegationMap });
          if (!canViewDocument({ doc, steps, ccIds, userId: req.user.sub, isManager, proxyFor })) {
            return { error: '결재 문서를 찾을 수 없습니다.', status: 404 };
          }
          const plan = planDecision({
            doc,
            steps,
            ccIds,
            actorId: req.user.sub,
            actorName: actor?.name ?? actor?.username ?? null,
            action,
            comment: req.body?.comment,
            isManager,
            proxyFor,
            signaturePath: actor?.signaturePath ?? null,
          });
          if (plan.error) return plan;
          if (action === 'cancel') return { ...plan, doc: { ...plan.doc, canceledByName: actor?.name ?? actor?.username ?? '관리자' } };
          // 서명 그림을 넣은 칸에는 그 파일의 SHA-256도 적는다(전자서명이 파일까지 덮게).
          return {
            ...plan,
            steps: plan.steps.map((s) => (s.patch.signaturePath && signatureHash ? { ...s, patch: { ...s.patch, signatureHash } } : s)),
          };
        },
        async (tx, { doc, freshSteps, result }) => {
          // 이번에 결정된 칸들을 서명한다(같은 트랜잭션 — 결정과 서명이 따로 남지 않게).
          if (keys) {
            const decided = result.steps.filter((s) => ['approved', 'rejected', 'disagreed'].includes(s.patch.status)).map((s) => s.id);
            if (decided.length) await writeStepSeals(tx, sealsFor({ doc, steps: freshSteps, stepIds: decided, sign: signWith(keys) }));
          }
          if (doc.kind !== 'attendance') return;
          if (doc.status === 'approved') {
            const minutesIn = parseHm(doc.payload.clockIn);
            const minutesOut = doc.payload.clockOut ? parseHm(doc.payload.clockOut) : null;
            await applyAttendanceCorrection(tx, {
              scopeKey: doc.scopeKey,
              teamId: doc.teamId,
              userId: doc.authorId,
              workDate: doc.payload.workDate,
              clockInAt: dateAtMinutes(doc.payload.workDate, minutesIn),
              clockOutAt: minutesOut === null ? null : dateAtMinutes(doc.payload.workDate, minutesOut),
              docId: doc.id,
            });
          } else if (doc.status === 'canceled') {
            await revertAttendanceCorrection(tx, doc.id);
          }
        },
      );
      if (outcome.error) return fail(res, outcome);
      if (action === 'cancel') {
        recordAudit({
          actorId: req.user.sub,
          actorName: actor?.name ?? actor?.username,
          action: AUDIT.groupwareCancel,
          teamId: outcome.document.teamId,
          targetType: 'approval',
          targetId: outcome.document.id,
          targetLabel: outcome.document.title,
          detail: `${approvalLabelOf(outcome.document)} 결재 취소 — ${outcome.document.cancelReason}`,
        });
      }
      const fresh = await findApprovalDocument(req.params.id);
      await announce(io, {
        ...fresh,
        event: outcome.notify.event,
        notifyIds: outcome.notify.userIds,
        actorId: req.user.sub,
        actorName: actor?.name ?? actor?.username ?? null,
      });
      // 덧붙인 알림 — 후결 요청, 합의 반대 의견(approvalRules.js planDecision의 alsoNotify).
      for (const extra of outcome.alsoNotify ?? []) {
        await announce(io, {
          ...fresh,
          event: extra.event,
          notifyIds: extra.userIds,
          actorId: req.user.sub,
          actorName: actor?.name ?? actor?.username ?? null,
        });
      }
      res.json(
        documentDto(fresh, req.user.sub, {
          isManager: isManager || (await isManagerOfDocument(fresh.doc, req.user.sub)),
          proxySources: [...delegationMap].filter(([, d]) => d === req.user.sub).map(([absent]) => absent),
          settlements: (await settlementsByDoc([fresh])).get(fresh.doc.id) ?? null,
        }),
      );
    });
  }

  // ── 대결(부재 중 대신 결재) ──

  const delegationDto = (d, names) => ({
    id: d.id,
    userId: d.userId,
    userName: names.get(d.userId) ?? '(알 수 없음)',
    delegateId: d.delegateId,
    delegateName: names.get(d.delegateId) ?? '(알 수 없음)',
    startDate: d.startDate,
    endDate: d.endDate,
    reason: d.reason ?? null,
  });

  /** 대결 설정 — 내가 맡긴 것과 내가 맡은 것(관리자는 ?all=1로 이 범위 전부). 지난 것은 뺀다. */
  router.get(
    '/groupware/delegations',
    withContext(async (req, res, ctx) => {
      const today = localDateKey(new Date());
      const all = await listCurrentDelegations(ctx.scopeKey, today);
      const shown = req.query.all === '1' && ctx.isManager ? all : all.filter((d) => d.userId === ctx.user.id || d.delegateId === ctx.user.id);
      const names = new Map((await listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId })).map((m) => [m.id, m.name]));
      res.json(shown.map((d) => delegationDto(d, names)));
    }),
  );

  /** 대결 맡기기 `{ delegateId, startDate, endDate, reason?, userId? }` — userId(남의 것)는 관리자만. */
  router.post(
    '/groupware/delegations',
    withContext(async (req, res, ctx) => {
      const body = req.body ?? {};
      const userId = isUuid(body.userId) ? body.userId : ctx.user.id;
      if (userId !== ctx.user.id && !ctx.isManager) return fail(res, { error: '관리자만 남의 대결을 정할 수 있습니다.', status: 403 });
      const candidates = await approverCandidates(ctx);
      if (!candidates.has(userId)) return fail(res, { error: '결재자가 아닌 사람입니다.' });
      const today = localDateKey(new Date());
      const parsed = parseDelegation({
        userId,
        delegateId: body.delegateId,
        startDate: body.startDate,
        endDate: body.endDate,
        reason: body.reason,
        today,
        isCandidate: (id) => candidates.has(id),
        existing: await listCurrentDelegations(ctx.scopeKey, today, { userId }),
      });
      if (parsed.error) return fail(res, parsed);
      const row = await insertDelegation({ scopeKey: ctx.scopeKey, userId, ...parsed.delegation, createdById: ctx.user.id });
      const names = new Map([...candidates.values()].map((m) => [m.id, m.name]));
      // 맡은 사람의 결재함·뱃지가 바로 바뀌게.
      for (const id of [userId, row.delegateId]) io.to(`user:${id}`).emit('groupware:changed', { delegation: true, scopeKey: ctx.scopeKey });
      res.status(201).json(delegationDto(row, names));
    }),
  );

  /** 대결 거두기 — 맡긴 사람·관리자. */
  router.delete('/groupware/delegations/:id', async (req, res) => {
    const row = isUuid(req.params.id) ? await findDelegation(req.params.id) : null;
    if (!row) return fail(res, { error: '대결 설정을 찾을 수 없습니다.', status: 404 });
    if (row.userId !== req.user.sub) {
      const isManager = await isManagerOfDocument({ scopeKey: row.scopeKey, teamId: row.scopeKey === 'server' ? null : row.scopeKey }, req.user.sub);
      if (!isManager) return fail(res, { error: '맡긴 사람이나 관리자만 거둘 수 있습니다.', status: 403 });
    }
    await deleteDelegation(row.id);
    for (const id of [row.userId, row.delegateId]) io.to(`user:${id}`).emit('groupware:changed', { delegation: true, scopeKey: row.scopeKey });
    res.json({ ok: true });
  });

  // ── 서명·도장 ──

  /** 내 서명·도장 그림 정하기 `{ fileUrl }` — 직접 올린 그림(png·jpg·webp)만. 이미 한 결재의 서명은 그대로다. */
  router.put('/groupware/signature', async (req, res) => {
    const raw = req.body?.fileUrl;
    if (typeof raw !== 'string' || !raw) return fail(res, { error: '서명 그림을 올리세요.' });
    const checked = await checkFileRefs([raw], { senderId: req.user.sub });
    if (!checked.ok) return fail(res, { error: checked.error });
    const path = checked.paths.get(raw);
    if (!/\.(png|jpe?g|webp)$/i.test(path ?? '')) return fail(res, { error: '서명은 그림 파일(png·jpg·webp)로 올리세요.' });
    await updateUser(req.user.sub, { signaturePath: path });
    res.json({ signatureUrl: signFileUrl(path) ?? null });
  });

  router.delete('/groupware/signature', async (req, res) => {
    await updateUser(req.user.sub, { signaturePath: null });
    res.json({ ok: true });
  });

  // ── 결재 통계 ──

  /** 결재 통계(관리자) `?from=&to=`('YYYY-MM-DD', 기본 이번 달, 366일까지) — 그 사이에 올린 문서의 종류별·결재자별 건수와 평균 처리 시간. */
  router.get(
    '/groupware/stats',
    withContext(
      async (req, res, ctx) => {
        const today = localDateKey(new Date());
        const from = isDateKey(req.query.from) ? req.query.from : `${today.slice(0, 7)}-01`;
        const to = isDateKey(req.query.to) ? req.query.to : today;
        if (to < from || addDaysKey(from, 365) < to) return fail(res, { error: '기간은 366일 안으로 고르세요.' });
        const docs = await listDocumentsCreatedBetween({ scopeKey: ctx.scopeKey, from, to });
        res.json({ from, to, truncated: docs.length >= 5000, ...approvalStats(docs, { labelOf: approvalLabelOf }) });
      },
      { managerOnly: true },
    ),
  );

  /**
   * 결재 통계 엑셀(관리자) `?from=&to=` — "요약"(전체·종류별), "결재자별", "문서"(번호·종류·제목·올린 사람·상태·올린 시각·끝난 시각·걸린 시간)
   * 세 시트.
   */
  router.get(
    '/groupware/stats/export',
    withContext(
      async (req, res, ctx) => {
        const today = localDateKey(new Date());
        const from = isDateKey(req.query.from) ? req.query.from : `${today.slice(0, 7)}-01`;
        const to = isDateKey(req.query.to) ? req.query.to : today;
        if (to < from || addDaysKey(from, 365) < to) return fail(res, { error: '기간은 366일 안으로 고르세요.' });
        const docs = await listDocumentsCreatedBetween({ scopeKey: ctx.scopeKey, from, to });
        const stats = approvalStats(docs, { labelOf: approvalLabelOf });
        const workbook = new ExcelJS.Workbook();
        const hoursText = (h) => (h === null || h === undefined ? '' : h);
        const summary = workbook.addWorksheet('요약');
        summary.columns = [
          { header: '종류', key: 'label', width: 16 },
          { header: '건수', key: 'total', width: 8 },
          { header: '진행 중', key: 'pending', width: 8 },
          { header: '승인', key: 'approved', width: 8 },
          { header: '반려', key: 'rejected', width: 8 },
          { header: '회수', key: 'withdrawn', width: 8 },
          { header: '취소', key: 'canceled', width: 8 },
          { header: '평균 처리 시간(시간)', key: 'avgHours', width: 18 },
        ];
        summary.addRow({ ...stats.totals, label: '전체', avgHours: hoursText(stats.totals.avgHours) });
        for (const k of stats.byKind) summary.addRow({ ...k, avgHours: hoursText(k.avgHours) });
        const approvers = workbook.addWorksheet('결재자별');
        approvers.columns = [
          { header: '결재자', key: 'name', width: 16 },
          { header: '결정', key: 'decided', width: 8 },
          { header: '승인', key: 'approved', width: 8 },
          { header: '반려', key: 'rejected', width: 8 },
          { header: '반대 의견', key: 'disagreed', width: 10 },
          { header: '대결로 처리', key: 'proxied', width: 12 },
          { header: '기다리는 중', key: 'waiting', width: 12 },
          { header: '평균 응답 시간(시간)', key: 'avgHours', width: 18 },
        ];
        for (const a of stats.byApprover) approvers.addRow({ ...a, avgHours: hoursText(a.avgHours) });
        const list = workbook.addWorksheet('문서');
        list.columns = [
          { header: '문서 번호', key: 'docNumber', width: 16 },
          { header: '종류', key: 'kind', width: 12 },
          { header: '제목', key: 'title', width: 40 },
          { header: '올린 사람', key: 'author', width: 12 },
          { header: '상태', key: 'status', width: 8 },
          { header: '올린 시각', key: 'createdAt', width: 18 },
          { header: '끝난 시각', key: 'decidedAt', width: 18 },
          { header: '걸린 시간(시간)', key: 'hours', width: 14 },
        ];
        const STATUS_LABEL = { pending: '진행 중', approved: '승인', rejected: '반려', withdrawn: '회수', canceled: '취소' };
        const at = (d) => (d ? `${localDateKey(new Date(d))} ${hmText(Math.round((new Date(d).getHours() * 60 + new Date(d).getMinutes())))}` : '');
        for (const { doc } of docs) {
          list.addRow({
            docNumber: doc.docNumber ?? '',
            kind: approvalLabelOf(doc),
            title: doc.title,
            author: doc.authorName,
            status: STATUS_LABEL[doc.status] ?? doc.status,
            createdAt: at(doc.createdAt),
            decidedAt: at(doc.decidedAt),
            hours: doc.decidedAt ? Math.round(((new Date(doc.decidedAt) - new Date(doc.createdAt)) / 3_600_000) * 10) / 10 : '',
          });
        }
        for (const sheet of [summary, approvers, list]) sheet.getRow(1).font = { bold: true };
        const fileName = `결재통계_${ctx.team?.name ?? '회사'}_${from}_${to}.xlsx`;
        res.setHeader('Content-Type', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
        res.setHeader('Content-Disposition', `attachment; filename*=UTF-8''${encodeURIComponent(fileName)}`);
        await workbook.xlsx.write(res);
        res.end();
      },
      { managerOnly: true },
    ),
  );

  // ── 연차 ──

  /** 연차 현황 — 내 것, 관리자는 ?userId=로 남의 것도. */
  router.get(
    '/groupware/leave/balance',
    withContext(async (req, res, ctx) => {
      const target = isUuid(req.query.userId) ? req.query.userId : ctx.user.id;
      if (target !== ctx.user.id && !ctx.isManager) return fail(res, { error: '관리자만 남의 연차를 볼 수 있습니다.', status: 403 });
      res.json(await balanceFor(ctx, target));
    }),
  );

  /** 이 범위에서 [from]~[to] 사이 승인된 휴가(그룹웨어 화면의 "팀 휴가" 목록) — 구성원이면 누구나. */
  router.get(
    '/groupware/leave/calendar',
    withContext(async (req, res, ctx) => {
      const from = isDateKey(req.query.from) ? req.query.from : localDateKey(new Date());
      const to = isDateKey(req.query.to) ? req.query.to : addDaysKey(from, 30);
      if (to < from || addDaysKey(from, 92) < to) return fail(res, { error: '기간은 92일 안으로 고르세요.' });
      const userIds = ctx.scope === 'server' && ctx.teamId ? await listTeamMemberIds(ctx.teamId) : null;
      const leaves = await listApprovedLeaves({ scopeKey: ctx.scopeKey, from, to, userIds });
      res.json(
        leaves
          .map((l) => ({ documentId: l.id, userId: l.authorId, name: l.authorName, ...l.payload }))
          .sort((a, b) => a.startDate.localeCompare(b.startDate)),
      );
    }),
  );

  // ── 관리(결재·근태 관리자) ──

  /** 구성원과 입사일·연차 현황. */
  router.get(
    '/groupware/members',
    withContext(
      async (req, res, ctx) => {
        const members = await listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId });
        const rows = [];
        for (const m of members) {
          const balance = await balanceFor(ctx, m.id);
          rows.push({
            id: m.id,
            name: m.name,
            username: m.username,
            role: m.role,
            suspended: !!m.suspendedAt,
            hireDate: m.hireDate,
            period: balance.period,
            grantedHalfDays: balance.grantedHalfDays,
            usedHalfDays: balance.usedHalfDays,
            pendingHalfDays: balance.pendingHalfDays,
            remainingHalfDays: balance.remainingHalfDays,
          });
        }
        res.json(rows.sort((a, b) => a.name.localeCompare(b.name, 'ko')));
      },
      { managerOnly: true },
    ),
  );

  /** 입사일 정하기(null이면 지움). */
  router.patch(
    '/groupware/members/:userId',
    withContext(
      async (req, res, ctx) => {
        if (!isUuid(req.params.userId)) return fail(res, { error: '구성원을 찾을 수 없습니다.', status: 404 });
        const hireDate = req.body?.hireDate ?? null;
        if (hireDate !== null && (!isDateKey(hireDate) || hireDate > localDateKey(new Date(Date.now() + 366 * DAY_MS)))) {
          return fail(res, { error: '입사일을 확인하세요.' });
        }
        if (!(await setHireDate({ scope: ctx.scope, teamId: ctx.teamId, userId: req.params.userId, hireDate }))) {
          return fail(res, { error: '구성원을 찾을 수 없습니다.', status: 404 });
        }
        recordAudit({
          actorId: ctx.user.id,
          actorName: ctx.user.name ?? ctx.user.username,
          action: AUDIT.groupwareHireDate,
          teamId: ctx.teamId,
          teamName: ctx.team?.name ?? null,
          targetType: 'user',
          targetId: req.params.userId,
          detail: `입사일 ${hireDate ?? '지움'}`,
        });
        res.json(await balanceFor(ctx, req.params.userId));
      },
      { managerOnly: true },
    ),
  );

  /** 연차 조정(반일 단위, +는 더 줌 −는 뺌) — 이번 연차 기간에. 입사일이 있어야 한다. */
  router.post(
    '/groupware/members/:userId/leave-adjustments',
    withContext(
      async (req, res, ctx) => {
        if (!isUuid(req.params.userId)) return fail(res, { error: '구성원을 찾을 수 없습니다.', status: 404 });
        const halfDays = Number(req.body?.halfDays);
        if (!Number.isInteger(halfDays) || halfDays === 0 || Math.abs(halfDays) > 120) {
          return fail(res, { error: '조정할 일수를 반일 단위로 넣으세요(최대 60일).' });
        }
        const reason = typeof req.body?.reason === 'string' ? req.body.reason.trim() : '';
        if (!reason || reason.length > 200) return fail(res, { error: '조정 사유를 200자 이내로 쓰세요.' });
        const balance = await balanceFor(ctx, req.params.userId);
        if (!balance.period) return fail(res, { error: '입사일을 먼저 정하세요.' });
        await insertLeaveAdjustment({
          scopeKey: ctx.scopeKey,
          userId: req.params.userId,
          periodStart: balance.period.start,
          halfDays,
          reason,
          createdByName: ctx.user.name ?? ctx.user.username,
        });
        recordAudit({
          actorId: ctx.user.id,
          actorName: ctx.user.name ?? ctx.user.username,
          action: AUDIT.groupwareLeaveAdjust,
          teamId: ctx.teamId,
          teamName: ctx.team?.name ?? null,
          targetType: 'user',
          targetId: req.params.userId,
          detail: `연차 ${halfDays > 0 ? '+' : '−'}${halfDaysText(Math.abs(halfDays))} — ${reason}`,
        });
        res.status(201).json(await balanceFor(ctx, req.params.userId));
      },
      { managerOnly: true },
    ),
  );

  /** 근무 시간(지각·조퇴 기준) — 팀 범위는 그 팀, 회사 전체는 서버 설정. 'HH:MM'. */
  router.patch(
    '/groupware/settings',
    withContext(
      async (req, res, ctx) => {
        const start = parseHm(req.body?.workStart);
        const end = parseHm(req.body?.workEnd);
        if (!validWorkHours(start, end)) return fail(res, { error: '근무 시작이 끝보다 앞이어야 합니다(HH:MM).' });
        if (ctx.scope === 'team') {
          await updateTeam(ctx.teamId, { workStartMinutes: start, workEndMinutes: end });
        } else {
          await updateServerSettings({ workStartMinutes: start, workEndMinutes: end });
        }
        recordAudit({
          actorId: ctx.user.id,
          actorName: ctx.user.name ?? ctx.user.username,
          action: AUDIT.groupwareSettings,
          teamId: ctx.teamId,
          teamName: ctx.team?.name ?? null,
          detail: `근무 시간 ${hmText(start)}~${hmText(end)}`,
        });
        res.json({ workStart: start, workEnd: end });
      },
      { managerOnly: true },
    ),
  );

  // ── 출퇴근 ──

  /** 오늘 — 내 기록과 출근·퇴근을 누를 수 있는지, 지금 사내 와이파이인지. */
  router.get(
    '/groupware/attendance/today',
    withContext(async (req, res, ctx) => {
      const now = new Date();
      const today = localDateKey(now);
      const recent = await listRecentAttendance({ scopeKey: ctx.scopeKey, userId: ctx.user.id, fromDate: addDaysKey(today, -1) });
      const todayRecord = recent.find((r) => r.workDate === today) ?? null;
      const target = clockOutTarget(recent, now);
      res.json({
        today,
        record: attendanceDto(todayRecord, ctx),
        openRecord: target && target !== todayRecord ? attendanceDto(target, ctx) : null,
        canClockIn: !todayRecord,
        canClockOut: !!target?.clockInAt && !target.clockOutAt,
        inLan: isLanAddress(clientIp(req)),
        workStart: ctx.hours.workStart,
        workEnd: ctx.hours.workEnd,
        schedule: scheduleDto(ctx.schedule),
        // 이번 주(월~일) 근로시간 — 주 52시간.
        week: weeklySummary(
          await listAttendanceInRange({ scopeKey: ctx.scopeKey, from: weekStartOf(today), to: addDaysKey(weekStartOf(today), 6), userId: ctx.user.id }),
          weekStartOf(today),
          { holidays: HOLIDAY_DATES },
        ),
      });
    }),
  );

  router.post(
    '/groupware/attendance/clock-in',
    withContext(async (req, res, ctx) => {
      const now = new Date();
      // 출근 형태 — 사무실·외근(장소 필수)·재택(workRules.js parseClockIn).
      const input = parseClockIn(req.body);
      if (input.error) return fail(res, input);
      const row = await insertClockIn({
        scopeKey: ctx.scopeKey,
        teamId: ctx.teamId,
        userId: ctx.user.id,
        workDate: localDateKey(now),
        clockInAt: now,
        clockInLan: isLanAddress(clientIp(req)),
        clockInMode: input.mode,
        note: input.note,
      });
      if (!row) return fail(res, { error: '오늘은 이미 출근을 눌렀습니다.', status: 409 });
      res.status(201).json(attendanceDto(row, ctx));
    }),
  );

  router.post(
    '/groupware/attendance/clock-out',
    withContext(async (req, res, ctx) => {
      const now = new Date();
      const recent = await listRecentAttendance({ scopeKey: ctx.scopeKey, userId: ctx.user.id, fromDate: addDaysKey(localDateKey(now), -1) });
      const target = clockOutTarget(recent, now);
      if (!target?.clockInAt) {
        return fail(res, { error: '출근 기록이 없습니다. 출근을 빠뜨렸으면 근태 수정을 올리세요.', status: 409 });
      }
      if (target.clockOutAt) return fail(res, { error: '이미 퇴근을 눌렀습니다.', status: 409 });
      const row = await updateClockOut(target.id, { clockOutAt: now, clockOutLan: isLanAddress(clientIp(req)) });
      if (!row) return fail(res, { error: '이미 퇴근을 눌렀습니다.', status: 409 });
      res.json(attendanceDto(row, ctx));
    }),
  );

  /** 한 달 근태 — 내 것, 관리자는 ?userId=로 남의 것도. 날마다 기록·휴가와 요약. */
  router.get(
    '/groupware/attendance/month',
    withContext(async (req, res, ctx) => {
      const month = typeof req.query.month === 'string' ? req.query.month : localDateKey(new Date()).slice(0, 7);
      const days = monthDays(month);
      if (!days) return fail(res, { error: '달을 확인하세요(YYYY-MM).' });
      const target = isUuid(req.query.userId) ? req.query.userId : ctx.user.id;
      if (target !== ctx.user.id && !ctx.isManager) return fail(res, { error: '관리자만 남의 근태를 볼 수 있습니다.', status: 403 });
      const from = days[0];
      const to = days[days.length - 1];
      // 주 52시간 — 달에 걸친 주 전체(앞뒤 달의 날 포함)를 본다.
      const weeks = weeksOfMonth(days);
      const [records, leaves, trips, overtime, weekRecords, hoursOf] = await Promise.all([
        listAttendanceInRange({ scopeKey: ctx.scopeKey, from, to, userId: target }),
        listApprovedLeaves({ scopeKey: ctx.scopeKey, from, to, userIds: [target] }),
        listApprovedTrips({ scopeKey: ctx.scopeKey, from, to, userIds: [target] }),
        listApprovedOvertime({ scopeKey: ctx.scopeKey, from, to, userIds: [target] }),
        listAttendanceInRange({ scopeKey: ctx.scopeKey, from: weeks[0], to: addDaysKey(weeks[weeks.length - 1], 6), userId: target }),
        hoursByUser(ctx),
      ]);
      const targetHours = hoursOf(target);
      const leaveByDate = new Map();
      for (const l of leaves) leaveDaysOf(l, leaveByDate);
      const tripDates = new Set();
      for (const t of trips) tripDaysOf(t, tripDates);
      const overtimeByDate = overtimeByDateOf(overtime);
      const byDate = new Map(records.map((r) => [r.workDate, r]));
      const today = localDateKey(new Date());
      res.json({
        month,
        days: days.map((day) => {
          const leave = leaveByDate.get(day) ?? null;
          return {
            date: day,
            holiday: HOLIDAYS.find((h) => h.date === day)?.name ?? null,
            leave: leave ? { type: leave.type, halfDays: leave.halfDays } : null,
            trip: tripDates.has(day),
            overtimeMinutes: overtimeByDate.get(day) ?? 0,
            record: attendanceDto(byDate.get(day) ?? null, ctx, leave, targetHours),
          };
        }),
        summary: {
          ...summarizeMonth({
            monthKey: month,
            records,
            leaveByDate,
            tripDates,
            overtimeByDate,
            holidays: HOLIDAY_DATES,
            workStart: targetHours.workStart,
            workEnd: targetHours.workEnd,
            checkLate: targetHours.checkLate,
            checkEarly: targetHours.checkEarly,
            today,
          }),
          ...monthBreakdown(records, { holidays: HOLIDAY_DATES }),
        },
        weeks: weeks.map((w) => weeklySummary(weekRecords, w, { holidays: HOLIDAY_DATES })),
      });
    }),
  );

  /** 구성원별 한 달 근태 요약(관리자). */
  async function monthSummaries(ctx, month) {
    const days = monthDays(month);
    const from = days[0];
    const to = days[days.length - 1];
    const members = (await listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId })).filter((m) => !m.suspendedAt);
    const memberIds = members.map((m) => m.id);
    const [records, leaves, trips, overtime] = await Promise.all([
      listAttendanceInRange({ scopeKey: ctx.scopeKey, from, to }),
      listApprovedLeaves({ scopeKey: ctx.scopeKey, from, to, userIds: memberIds }),
      listApprovedTrips({ scopeKey: ctx.scopeKey, from, to, userIds: memberIds }),
      listApprovedOvertime({ scopeKey: ctx.scopeKey, from, to, userIds: memberIds }),
    ]);
    const hoursOf = await hoursByUser(ctx);
    const today = localDateKey(new Date());
    return members
      .map((m) => {
        const leaveByDate = new Map();
        for (const l of leaves.filter((x) => x.authorId === m.id)) leaveDaysOf(l, leaveByDate);
        const mine = records.filter((r) => r.userId === m.id);
        const tripDates = new Set();
        for (const t of trips.filter((x) => x.authorId === m.id)) tripDaysOf(t, tripDates);
        const overtimeByDate = overtimeByDateOf(overtime.filter((x) => x.authorId === m.id));
        return {
          userId: m.id,
          name: m.name,
          username: m.username,
          records: mine,
          leaveByDate,
          hours: hoursOf(m.id),
          summary: {
            ...summarizeMonth({
              monthKey: month,
              records: mine,
              leaveByDate,
              tripDates,
              overtimeByDate,
              holidays: HOLIDAY_DATES,
              workStart: hoursOf(m.id).workStart,
              workEnd: hoursOf(m.id).workEnd,
              checkLate: hoursOf(m.id).checkLate,
              checkEarly: hoursOf(m.id).checkEarly,
              today,
            }),
            ...monthBreakdown(mine, { holidays: HOLIDAY_DATES }),
          },
        };
      })
      .sort((a, b) => a.name.localeCompare(b.name, 'ko'));
  }

  router.get(
    '/groupware/attendance/summary',
    withContext(
      async (req, res, ctx) => {
        const month = typeof req.query.month === 'string' ? req.query.month : localDateKey(new Date()).slice(0, 7);
        if (!monthDays(month)) return fail(res, { error: '달을 확인하세요(YYYY-MM).' });
        const rows = await monthSummaries(ctx, month);
        res.json({ month, members: rows.map((r) => ({ userId: r.userId, name: r.name, username: r.username, ...r.summary })) });
      },
      { managerOnly: true },
    ),
  );

  /** 한 달 근태를 엑셀로(관리자) — "요약"(사람별)과 "일별 기록"(사람·날짜별) 두 시트. */
  router.get(
    '/groupware/attendance/export',
    withContext(
      async (req, res, ctx) => {
        const month = typeof req.query.month === 'string' ? req.query.month : localDateKey(new Date()).slice(0, 7);
        if (!monthDays(month)) return fail(res, { error: '달을 확인하세요(YYYY-MM).' });
        const rows = await monthSummaries(ctx, month);
        const workbook = new ExcelJS.Workbook();
        const summary = workbook.addWorksheet('요약');
        summary.columns = [
          { header: '이름', key: 'name', width: 14 },
          { header: '아이디', key: 'username', width: 14 },
          { header: '출근일', key: 'daysWorked', width: 8 },
          { header: '근무 시간', key: 'hours', width: 10 },
          { header: '지각', key: 'late', width: 6 },
          { header: '조퇴', key: 'earlyLeave', width: 6 },
          { header: '퇴근 누락', key: 'missingClockOut', width: 9 },
          { header: '결근', key: 'absent', width: 6 },
          { header: '휴가(일)', key: 'leaveDays', width: 9 },
          { header: '출장(일)', key: 'tripDays', width: 9 },
          { header: '연장근무 신청(시간)', key: 'overtimeHours', width: 16 },
          { header: '실근로(시간)', key: 'netHours', width: 11 },
          { header: '연장(시간)', key: 'actualOvertimeHours', width: 10 },
          { header: '야간(시간)', key: 'nightHours', width: 10 },
          { header: '휴일(시간)', key: 'holidayHours', width: 10 },
        ];
        for (const r of rows) {
          summary.addRow({
            name: r.name,
            username: r.username,
            ...r.summary,
            hours: Math.round((r.summary.workedMinutes / 60) * 10) / 10,
            leaveDays: r.summary.leaveHalfDays / 2,
            overtimeHours: Math.round((r.summary.overtimeMinutes / 60) * 10) / 10,
            netHours: Math.round((r.summary.netMinutes / 60) * 10) / 10,
            actualOvertimeHours: Math.round((r.summary.actualOvertimeMinutes / 60) * 10) / 10,
            nightHours: Math.round((r.summary.nightMinutes / 60) * 10) / 10,
            holidayHours: Math.round((r.summary.holidayWorkMinutes / 60) * 10) / 10,
          });
        }
        const daily = workbook.addWorksheet('일별 기록');
        daily.columns = [
          { header: '이름', key: 'name', width: 14 },
          { header: '날짜', key: 'date', width: 12 },
          { header: '출근', key: 'in', width: 8 },
          { header: '퇴근', key: 'out', width: 8 },
          { header: '사내 와이파이', key: 'lan', width: 12 },
          { header: '지각', key: 'late', width: 6 },
          { header: '조퇴', key: 'early', width: 6 },
          { header: '휴가', key: 'leave', width: 10 },
          { header: '결재로 고침', key: 'corrected', width: 11 },
          { header: '처음 출근', key: 'origIn', width: 10 },
          { header: '처음 퇴근', key: 'origOut', width: 10 },
          { header: '출근 형태', key: 'mode', width: 9 },
          { header: '실근로', key: 'net', width: 8 },
          { header: '연장', key: 'overtime', width: 8 },
          { header: '야간', key: 'night', width: 8 },
          { header: '휴일', key: 'holiday', width: 8 },
        ];
        const hm = (v) => (v ? hmText(new Date(v).getHours() * 60 + new Date(v).getMinutes()) : '');
        for (const r of rows) {
          for (const record of r.records) {
            const leave = r.leaveByDate.get(record.workDate) ?? null;
            const flags = scheduledFlags(record, r.hours, { halfType: leave?.halfType ?? null, fullLeave: leave?.halfDays === 2 });
            const b = workBreakdown(record, { holidays: HOLIDAY_DATES });
            daily.addRow({
              name: r.name,
              date: record.workDate,
              in: hm(record.clockInAt),
              out: hm(record.clockOutAt),
              lan: record.clockInLan === null ? '' : record.clockInLan ? '예' : '아니오',
              late: flags.late ? '지각' : '',
              early: flags.earlyLeave ? '조퇴' : '',
              leave: leave ? (leave.label ?? leaveTypeOf(leave.type)?.label ?? '') : '',
              mode: { office: '사무실', field: '외근', remote: '재택' }[record.clockInMode ?? 'office'] ?? '',
              net: b.netMinutes ? hmText(b.netMinutes) : '',
              overtime: b.overtimeMinutes ? hmText(b.overtimeMinutes) : '',
              night: b.nightMinutes ? hmText(b.nightMinutes) : '',
              holiday: b.holidayMinutes ? hmText(b.holidayMinutes) : '',
              corrected: record.corrected ? '예' : '',
              origIn: hm(record.originalClockInAt),
              origOut: hm(record.originalClockOutAt),
            });
          }
        }
        for (const sheet of [summary, daily]) sheet.getRow(1).font = { bold: true };
        const fileName = `근태_${ctx.team?.name ?? '회사'}_${month}.xlsx`;
        res.setHeader('Content-Type', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
        res.setHeader('Content-Disposition', `attachment; filename*=UTF-8''${encodeURIComponent(fileName)}`);
        await workbook.xlsx.write(res);
        res.end();
      },
      { managerOnly: true },
    ),
  );

  return router;
}
