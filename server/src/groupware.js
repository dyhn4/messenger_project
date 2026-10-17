import ExcelJS from 'exceljs';
import { Router } from 'express';
import { AUDIT, recordAudit } from './audit.js';
import { teamAccess, userAccess } from './access.js';
import { addDaysKey, halfDaysText, isDateKey, LEAVE_TYPES, leaveBalance, leaveShortage, leaveTypeOf } from './annualLeave.js';
import {
  APPROVAL_KINDS,
  APPROVAL_KIND_LABEL,
  APPROVAL_STATUSES,
  APPROVERS_MAX,
  approvalNotificationOf,
  ATTACHMENTS_MAX,
  BODY_MAX,
  CC_MAX,
  canViewDocument,
  defaultApprovalTitle,
  EXPENSE_CATEGORIES,
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
  recordFlags,
  summarizeMonth,
  validWorkHours,
} from './attendanceRules.js';
import { clientIp, isLanAddress, limits, retryLater, waitText } from './authGuard.js';
import {
  applyApprovalDecision,
  applyAttendanceCorrection,
  countPendingApprovals,
  countUnreadApprovalNotifications,
  deleteApprovalLine,
  findApprovalDocument,
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
import { managerChainFor } from './orgTree.js';
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
async function groupwareContext(userId, teamIdInput) {
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
  return {
    settings,
    scope,
    scopeKey: groupwareScopeKey(scope, teamId),
    teamId: scope === 'team' ? teamId : null,
    team,
    user,
    isManager,
    workStart,
    workEnd,
  };
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
const fail = (res, { error, status = 400 }) => res.status(status).json({ error });

/** 결재자·참조자로 고를 수 있는 사람들(Map id → 구성원) — 이 범위의 정회원 이상, 정지·탈퇴 제외. */
async function approverCandidates(ctx) {
  const members = await listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId });
  return new Map(members.filter(canBeApprover).map((m) => [m.id, m]));
}

function stepDto(s) {
  return {
    id: s.id,
    order: s.stepOrder,
    approverId: s.approverId,
    approverName: s.approverName,
    status: s.status,
    comment: s.comment ?? null,
    decidedAt: ms(s.decidedAt),
  };
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
function documentDto({ doc, steps }, viewerId, { isManager = false, cc = null } = {}) {
  const current = steps.find((s) => s.status === 'pending') ?? null;
  return {
    id: doc.id,
    kind: doc.kind,
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
    myTurn: doc.status === 'pending' && !!current && current.approverId === viewerId,
    canWithdraw: doc.status === 'pending' && doc.authorId === viewerId,
    canCancel: doc.status === 'approved' && isManager,
  };
}

/** 휴가 하나 → 'YYYY-MM-DD' 날짜별 { halfDays, halfType }(근태 요약·내 근무 기록에서 휴가 날을 가리는 데). */
function leaveDaysOf(leave, into = new Map()) {
  const type = leaveTypeOf(leave.payload?.leaveType);
  if (!type || !isDateKey(leave.payload?.startDate) || !isDateKey(leave.payload?.endDate)) return into;
  for (let day = leave.payload.startDate; day <= leave.payload.endDate; day = addDaysKey(day, 1)) {
    into.set(day, { halfDays: type.half ? 1 : 2, halfType: type.half ? type.key : null, type: type.key });
  }
  return into;
}

/** 한 사람의 이번 연차 현황(annualLeave.js leaveBalance + 조정 목록). */
async function balanceFor(ctx, userId) {
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

function attendanceDto(record, ctx, leave = null) {
  if (!record) return null;
  const flags = recordFlags(record, {
    workStart: ctx.workStart,
    workEnd: ctx.workEnd,
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
    ...flags,
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
  const involved = new Set([doc.authorId, ...steps.map((s) => s.approverId), ...ccIds].filter(Boolean));
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

/** 휴가가 승인·취소되면 캘린더 "팀 휴가"를 새로 고치게 한다. */
async function announceLeaveCalendar(io, doc, event) {
  if (doc.kind === 'leave' && (event === 'approved' || event === 'canceled')) {
    const teamIds = doc.teamId ? [doc.teamId] : doc.authorId ? await listTeamIdsForUser(doc.authorId) : [];
    for (const teamId of teamIds) {
      for (const id of await listTeamMemberIds(teamId)) io.to(`user:${id}`).emit('calendar:changed', { teamId, calendarId: 'leaves' });
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
      const [pendingForMe, hireDate] = await Promise.all([
        countPendingApprovals(ctx.scopeKey, ctx.user.id),
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
        leaveTypes: LEAVE_TYPES,
        expenseCategories: EXPENSE_CATEGORIES,
        limits: { approversMax: APPROVERS_MAX, ccMax: CC_MAX, attachmentsMax: ATTACHMENTS_MAX, titleMax: TITLE_MAX, bodyMax: BODY_MAX },
        inLan: isLanAddress(clientIp(req)),
      });
    }),
  );

  /** 결재자·참조자 후보(나 빼고). */
  router.get(
    '/groupware/candidates',
    withContext(async (req, res, ctx) => {
      const candidates = await approverCandidates(ctx);
      res.json(
        [...candidates.values()]
          .filter((m) => m.id !== ctx.user.id)
          .map((m) => ({ id: m.id, name: m.name, username: m.username }))
          .sort((a, b) => a.name.localeCompare(b.name, 'ko')),
      );
    }),
  );

  // ── 저장한 결재선 ──

  router.get(
    '/groupware/approval-lines',
    withContext(async (req, res, ctx) => {
      const [lines, candidates] = await Promise.all([listApprovalLines(ctx.user.id, ctx.scopeKey), approverCandidates(ctx)]);
      // 조직도의 상위자 사슬(orgTree.js) — 결재자로 고를 수 있는 사람만, 가까운 상위자부터. 조직도는 부서·직책 설정을 따르므로
      // 그룹웨어가 회사 전체여도 팀 단위 조직도면 지금 고른 팀의 조직도를 쓴다.
      const managerChain = await managerChainFor({
        settings: ctx.settings,
        teamId: ctx.teamId ?? (isUuid(req.query.teamId) ? req.query.teamId : null),
        userId: ctx.user.id,
        isEligible: (id) => candidates.has(id),
        max: APPROVERS_MAX,
      }).catch(() => []);
      res.json({
        lines: lines.map((l) => ({ id: l.id, name: l.name, approverIds: l.approverIds, ccIds: l.ccIds, createdAt: ms(l.createdAt) })),
        // 새 결재를 올릴 때 미리 채울 결재선 — 조직도 상위자 사슬, 없으면 가장 최근에 저장한 결재선(approvalRules.js suggestApprovalLine).
        suggested: suggestApprovalLine({ savedLines: lines, managerChain }),
      });
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
        isCandidate: (id) => candidates.has(id),
      });
      if (line.error) return fail(res, line);
      const row = await insertApprovalLine({ ownerId: ctx.user.id, scopeKey: ctx.scopeKey, name, ...line });
      res.status(201).json({ id: row.id, name: row.name, approverIds: row.approverIds, ccIds: row.ccIds, createdAt: ms(row.createdAt) });
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
      const box = ['inbox', 'mine', 'cc', 'done', 'all'].includes(req.query.box) ? req.query.box : 'inbox';
      if (box === 'all' && !ctx.isManager) return fail(res, { error: '관리자만 전체 문서를 볼 수 있습니다.', status: 403 });
      const kind = APPROVAL_KINDS.includes(req.query.kind) ? req.query.kind : null;
      const status = APPROVAL_STATUSES.includes(req.query.status) ? req.query.status : null;
      const before = Number(req.query.before) > 0 ? Number(req.query.before) : null;
      const rows = await listApprovalDocuments({ scopeKey: ctx.scopeKey, box, userId: ctx.user.id, kind, status, before });
      res.json(rows.map((r) => documentDto(r, ctx.user.id, { isManager: ctx.isManager })));
    }),
  );

  router.get('/groupware/documents/:id', async (req, res) => {
    if (!isUuid(req.params.id)) return fail(res, { error: '결재 문서를 찾을 수 없습니다.', status: 404 });
    const found = await findApprovalDocument(req.params.id);
    if (!found) return fail(res, { error: '결재 문서를 찾을 수 없습니다.', status: 404 });
    const isManager = await isManagerOfDocument(found.doc, req.user.sub);
    if (!canViewDocument({ ...found, userId: req.user.sub, isManager })) {
      return fail(res, { error: '결재 문서를 찾을 수 없습니다.', status: 404 });
    }
    const members = found.ccIds.length
      ? await listGroupwareMembers({ scope: found.doc.scopeKey === 'server' ? 'server' : 'team', teamId: found.doc.teamId })
      : [];
    const names = new Map(members.map((m) => [m.id, m.name]));
    const cc = found.ccIds.map((id) => ({ id, name: names.get(id) ?? '(알 수 없음)' }));
    res.json(documentDto(found, req.user.sub, { isManager, cc }));
  });

  /** 결재 올리기 — kind: leave | expense | attendance, 결재선(approverIds 순서대로)·참조자(ccIds). */
  router.post(
    '/groupware/documents',
    withContext(async (req, res, ctx) => {
      const body = req.body ?? {};
      if (!APPROVAL_KINDS.includes(body.kind)) return fail(res, { error: '결재 종류를 고르세요.' });
      const wait = limits.approvalCreateUser.hit(ctx.user.id);
      if (wait > 0) return retryLater(res, wait, `결재를 너무 많이 올렸습니다. ${waitText(wait)} 뒤에 다시 시도하세요.`);

      const today = localDateKey(new Date());
      let parsed;
      if (body.kind === 'leave') parsed = parseLeavePayload(body, HOLIDAY_DATES);
      else if (body.kind === 'expense') parsed = parseExpensePayload(body);
      else parsed = parseAttendancePayload(body, { today });
      if (parsed.error) return fail(res, parsed);
      const payload = parsed.payload;

      if (body.kind === 'leave') {
        const overlap = await findOverlappingLeave({ scopeKey: ctx.scopeKey, userId: ctx.user.id, from: payload.startDate, to: payload.endDate });
        if (overlap) return fail(res, { error: `그 기간에 이미 신청한 휴가가 있습니다: ${overlap.title}`, status: 409 });
        if (leaveTypeOf(payload.leaveType).deducts) {
          const balance = await balanceFor(ctx, ctx.user.id);
          const shortage = leaveShortage(balance, payload.halfDays);
          if (shortage) return fail(res, { error: shortage, status: 409 });
        }
      }

      const text = parseDocumentText(body, defaultApprovalTitle(body.kind, payload));
      if (text.error) return fail(res, text);
      const files = body.kind === 'expense' ? await parseAttachments(body.attachments, ctx.user.id) : { attachments: [] };
      if (files.error) return fail(res, files);

      const candidates = await approverCandidates(ctx);
      const line = validateApprovalLine({
        authorId: ctx.user.id,
        approverIds: body.approverIds,
        ccIds: body.ccIds ?? [],
        isCandidate: (id) => candidates.has(id),
      });
      if (line.error) return fail(res, line);

      const doc = await insertApprovalDocument({
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
        },
        approvers: line.approverIds.map((id) => ({ id, name: candidates.get(id).name })),
        ccIds: line.ccIds,
      });
      const found = await findApprovalDocument(doc.id);
      await announce(io, {
        ...found,
        event: 'created',
        notifyIds: [line.approverIds[0]],
        actorId: ctx.user.id,
        actorName: ctx.user.name ?? ctx.user.username,
      });
      res.status(201).json(documentDto(found, ctx.user.id, { isManager: ctx.isManager }));
    }),
  );

  /** 승인·반려·회수·취소 — 규칙은 approvalRules.js planDecision. 근태 수정이 승인되면 기록을 고치고, 취소되면 되돌린다. */
  for (const action of ['approve', 'reject', 'withdraw', 'cancel']) {
    router.post(`/groupware/documents/:id/${action}`, async (req, res) => {
      if (!isUuid(req.params.id)) return fail(res, { error: '결재 문서를 찾을 수 없습니다.', status: 404 });
      const found = await findApprovalDocument(req.params.id);
      if (!found) return fail(res, { error: '결재 문서를 찾을 수 없습니다.', status: 404 });
      const isManager = action === 'cancel' ? await isManagerOfDocument(found.doc, req.user.sub) : false;
      const actor = (await userAccess(req.user.sub)).user;
      const outcome = await applyApprovalDecision(
        req.params.id,
        async ({ doc, steps, ccIds }) => {
          if (!canViewDocument({ doc, steps, ccIds, userId: req.user.sub, isManager })) {
            return { error: '결재 문서를 찾을 수 없습니다.', status: 404 };
          }
          const plan = planDecision({ doc, steps, ccIds, actorId: req.user.sub, action, comment: req.body?.comment, isManager });
          if (plan.error || action !== 'cancel') return plan;
          return { ...plan, doc: { ...plan.doc, canceledByName: actor?.name ?? actor?.username ?? '관리자' } };
        },
        async (tx, { doc }) => {
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
          detail: `${APPROVAL_KIND_LABEL[outcome.document.kind]} 결재 취소 — ${outcome.document.cancelReason}`,
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
      res.json(documentDto(fresh, req.user.sub, { isManager: isManager || (await isManagerOfDocument(fresh.doc, req.user.sub)) }));
    });
  }

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
        workStart: ctx.workStart,
        workEnd: ctx.workEnd,
      });
    }),
  );

  router.post(
    '/groupware/attendance/clock-in',
    withContext(async (req, res, ctx) => {
      const now = new Date();
      const note = typeof req.body?.note === 'string' ? req.body.note.trim().slice(0, 200) || null : null;
      const row = await insertClockIn({
        scopeKey: ctx.scopeKey,
        teamId: ctx.teamId,
        userId: ctx.user.id,
        workDate: localDateKey(now),
        clockInAt: now,
        clockInLan: isLanAddress(clientIp(req)),
        note,
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
      const [records, leaves] = await Promise.all([
        listAttendanceInRange({ scopeKey: ctx.scopeKey, from, to, userId: target }),
        listApprovedLeaves({ scopeKey: ctx.scopeKey, from, to, userIds: [target] }),
      ]);
      const leaveByDate = new Map();
      for (const l of leaves) leaveDaysOf(l, leaveByDate);
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
            record: attendanceDto(byDate.get(day) ?? null, ctx, leave),
          };
        }),
        summary: summarizeMonth({ monthKey: month, records, leaveByDate, holidays: HOLIDAY_DATES, workStart: ctx.workStart, workEnd: ctx.workEnd, today }),
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
    const [records, leaves] = await Promise.all([
      listAttendanceInRange({ scopeKey: ctx.scopeKey, from, to }),
      listApprovedLeaves({ scopeKey: ctx.scopeKey, from, to, userIds: memberIds }),
    ]);
    const today = localDateKey(new Date());
    return members
      .map((m) => {
        const leaveByDate = new Map();
        for (const l of leaves.filter((x) => x.authorId === m.id)) leaveDaysOf(l, leaveByDate);
        const mine = records.filter((r) => r.userId === m.id);
        return {
          userId: m.id,
          name: m.name,
          username: m.username,
          records: mine,
          leaveByDate,
          summary: summarizeMonth({ monthKey: month, records: mine, leaveByDate, holidays: HOLIDAY_DATES, workStart: ctx.workStart, workEnd: ctx.workEnd, today }),
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
        ];
        for (const r of rows) {
          summary.addRow({
            name: r.name,
            username: r.username,
            ...r.summary,
            hours: Math.round((r.summary.workedMinutes / 60) * 10) / 10,
            leaveDays: r.summary.leaveHalfDays / 2,
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
        ];
        const hm = (v) => (v ? hmText(new Date(v).getHours() * 60 + new Date(v).getMinutes()) : '');
        for (const r of rows) {
          for (const record of r.records) {
            const leave = r.leaveByDate.get(record.workDate) ?? null;
            const flags = recordFlags(record, { workStart: ctx.workStart, workEnd: ctx.workEnd, halfType: leave?.halfType ?? null, fullLeave: leave?.halfDays === 2 });
            daily.addRow({
              name: r.name,
              date: record.workDate,
              in: hm(record.clockInAt),
              out: hm(record.clockOutAt),
              lan: record.clockInLan === null ? '' : record.clockInLan ? '예' : '아니오',
              late: flags.late ? '지각' : '',
              early: flags.earlyLeave ? '조퇴' : '',
              leave: leave ? (leaveTypeOf(leave.type)?.label ?? '') : '',
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
