// 그룹웨어(전자결재·연차·출퇴근) 규칙 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  addMonthsKey,
  annualLeaveDays,
  completedMonths,
  halfDaysText,
  leaveBalance,
  leavePeriod,
  leaveRequestAmount,
  leaveShortage,
  parseDateKey,
  statutoryHalfDays,
  workdaysBetween,
} from '../src/annualLeave.js';
import {
  APPROVAL_NOTIFICATION_KINDS,
  approvalNotificationOf,
  APPROVERS_MAX,
  canViewDocument,
  defaultApprovalTitle,
  parseAttendancePayload,
  parseExpensePayload,
  parseLeavePayload,
  planDecision,
  suggestApprovalLine,
  validateApprovalLine,
} from '../src/approvalRules.js';
import {
  clockOutTarget,
  dateAtMinutes,
  localDateKey,
  monthDays,
  parseHm,
  recordFlags,
  summarizeMonth,
} from '../src/attendanceRules.js';
import { canBeApprover, canManageGroupware, effectiveGroupwareScope, groupwareScopeKey } from '../src/groupwareScope.js';

// ── 범위 ───────────────────────────────────────────────────────────────

test('범위 — org는 부서·직책 설정을 따르고, team·server는 그대로', () => {
  assert.equal(effectiveGroupwareScope({ groupwareScope: 'org', orgScope: 'account' }), 'server');
  assert.equal(effectiveGroupwareScope({ groupwareScope: 'org', orgScope: 'team' }), 'team');
  assert.equal(effectiveGroupwareScope({ orgScope: 'account' }), 'server', '설정이 없으면 org');
  assert.equal(effectiveGroupwareScope({ groupwareScope: 'team', orgScope: 'account' }), 'team');
  assert.equal(effectiveGroupwareScope({ groupwareScope: 'server', orgScope: 'team' }), 'server');
  assert.equal(groupwareScopeKey('server', 'T1'), 'server');
  assert.equal(groupwareScopeKey('team', 'T1'), 'T1');
});

test('관리자 — 회사 전체는 운영자·관리자 등급, 팀 범위는 팀 소유자도', () => {
  assert.equal(canManageGroupware({ scope: 'server', role: 'member', isOwner: true }), false);
  assert.equal(canManageGroupware({ scope: 'server', role: 'admin' }), true);
  assert.equal(canManageGroupware({ scope: 'server', role: 'member', isServerAdmin: true }), true);
  assert.equal(canManageGroupware({ scope: 'team', role: 'member', isOwner: true }), true);
  assert.equal(canManageGroupware({ scope: 'team', role: 'member' }), false);
});

test('결재자는 정지·탈퇴하지 않은 정회원 이상', () => {
  assert.equal(canBeApprover({ role: 'member' }), true);
  assert.equal(canBeApprover({ role: 'guest' }), false);
  assert.equal(canBeApprover({ role: 'admin', suspendedAt: new Date() }), false);
  assert.equal(canBeApprover({ role: 'admin', deletedAt: new Date() }), false);
  assert.equal(canBeApprover(null), false);
});

// ── 날짜·근무일 ────────────────────────────────────────────────────────

test('날짜 — 없는 날은 거절, 월 더하기는 그 달 마지막 날로', () => {
  assert.deepEqual(parseDateKey('2026-02-28'), { y: 2026, m: 2, d: 28 });
  assert.equal(parseDateKey('2026-02-29'), null);
  assert.equal(parseDateKey('2026-2-1'), null);
  assert.equal(addMonthsKey('2026-01-31', 1), '2026-02-28');
  assert.equal(addMonthsKey('2028-01-31', 1), '2028-02-29');
  assert.equal(addMonthsKey('2026-11-15', 3), '2027-02-15');
  assert.equal(completedMonths('2026-01-15', '2026-02-14'), 0);
  assert.equal(completedMonths('2026-01-15', '2026-02-15'), 1);
  assert.equal(completedMonths('2026-01-31', '2026-02-28'), 1);
});

test('근무일 — 주말·공휴일 빼고', () => {
  const holidays = new Set(['2026-10-05']);
  // 2026-10-05(월)는 공휴일로 넣고, 10-03·04는 토·일.
  assert.equal(workdaysBetween('2026-10-02', '2026-10-06', holidays), 2);
  assert.equal(workdaysBetween('2026-10-03', '2026-10-04'), 0);
});

// ── 휴가 신청 ──────────────────────────────────────────────────────────

test('휴가 양 — 근무일만, 반차는 반일, 잘못된 기간은 거절', () => {
  assert.deepEqual(leaveRequestAmount({ leaveType: 'annual', startDate: '2026-10-19', endDate: '2026-10-23' }), {
    halfDays: 10,
    workdays: 5,
  });
  assert.deepEqual(leaveRequestAmount({ leaveType: 'half_am', startDate: '2026-10-19', endDate: '2026-10-19' }), {
    halfDays: 1,
    workdays: 1,
  });
  assert.match(leaveRequestAmount({ leaveType: 'half_pm', startDate: '2026-10-19', endDate: '2026-10-20' }).error, /하루만/);
  assert.match(leaveRequestAmount({ leaveType: 'half_pm', startDate: '2026-10-18', endDate: '2026-10-18' }).error, /근무일/);
  assert.match(leaveRequestAmount({ leaveType: 'annual', startDate: '2026-10-24', endDate: '2026-10-25' }).error, /근무일이 없/);
  assert.match(leaveRequestAmount({ leaveType: 'annual', startDate: '2026-10-20', endDate: '2026-10-19' }).error, /앞입니다/);
  assert.match(leaveRequestAmount({ leaveType: 'vacation', startDate: '2026-10-19', endDate: '2026-10-19' }).error, /종류/);
  assert.match(leaveRequestAmount({ leaveType: 'annual', startDate: '2026-01-01', endDate: '2026-04-01' }).error, /60일/);
});

test('휴가 내용 — 양은 서버가 계산하고 끝 날짜가 없으면 시작 날짜', () => {
  const parsed = parseLeavePayload({ leaveType: 'annual', startDate: '2026-10-19', halfDays: 999 });
  assert.deepEqual(parsed.payload, { leaveType: 'annual', startDate: '2026-10-19', endDate: '2026-10-19', halfDays: 2 });
});

// ── 법정 연차 ──────────────────────────────────────────────────────────

test('근속 연수별 연차 — 15일, 3년차부터 2년마다 1일, 최대 25일', () => {
  assert.equal(annualLeaveDays(0), 0);
  assert.equal(annualLeaveDays(1), 15);
  assert.equal(annualLeaveDays(2), 15);
  assert.equal(annualLeaveDays(3), 16);
  assert.equal(annualLeaveDays(4), 16);
  assert.equal(annualLeaveDays(5), 17);
  assert.equal(annualLeaveDays(21), 25);
  assert.equal(annualLeaveDays(30), 25);
});

test('입사 첫해 — 한 달 채울 때마다 1일, 최대 11일', () => {
  assert.equal(statutoryHalfDays('2026-03-02', '2026-03-31'), 0);
  assert.equal(statutoryHalfDays('2026-03-02', '2026-04-02'), 2);
  assert.equal(statutoryHalfDays('2026-03-02', '2026-09-01'), 10, '5개월');
  assert.equal(statutoryHalfDays('2026-03-02', '2027-03-01'), 22, '11개월 = 11일이 최대');
  assert.equal(statutoryHalfDays('2026-03-02', '2027-03-02'), 30, '1년이 되면 15일');
  assert.equal(statutoryHalfDays(null, '2026-10-17'), null);
  assert.equal(statutoryHalfDays('2027-01-01', '2026-10-17'), null, '입사 전');
});

test('연차 기간은 입사 기념일마다', () => {
  assert.deepEqual(leavePeriod('2020-05-10', '2026-10-17'), { year: 6, start: '2026-05-10', end: '2027-05-10' });
  assert.deepEqual(leavePeriod('2026-05-10', '2026-10-17'), { year: 0, start: '2026-05-10', end: '2027-05-10' });
  assert.equal(statutoryHalfDays('2020-05-10', '2026-10-17'), annualLeaveDays(6) * 2);
});

test('연차 현황과 부족 — 결재 중인 것까지 빼고 본다, 입사일이 없으면 막지 않는다', () => {
  const balance = leaveBalance({ hireDate: '2020-05-10', today: '2026-10-17', usedHalfDays: 10, pendingHalfDays: 4, adjustmentHalfDays: 2 });
  assert.equal(balance.grantedHalfDays, 36); // 17일 + 조정 1일
  assert.equal(balance.remainingHalfDays, 26);
  assert.equal(leaveShortage(balance, 22), null);
  assert.match(leaveShortage(balance, 23), /남은 연차\(11일\)/);
  const unknown = leaveBalance({ hireDate: null, today: '2026-10-17' });
  assert.equal(unknown.remainingHalfDays, null);
  assert.equal(leaveShortage(unknown, 100), null);
  assert.equal(halfDaysText(5), '2.5일');
  assert.equal(halfDaysText(4), '2일');
});

// ── 결재선·내용 ────────────────────────────────────────────────────────

test('결재선 — 1~10명, 중복·자기 자신·결재자 겸 참조자·범위 밖은 거절', () => {
  const isCandidate = (id) => id !== 'outsider';
  const ok = validateApprovalLine({ authorId: 'me', approverIds: ['a', 'b'], ccIds: ['c'], isCandidate });
  assert.deepEqual(ok, {
    approverIds: ['a', 'b'],
    ccIds: ['c'],
    line: [
      { userId: 'a', role: 'approve', stage: 0 },
      { userId: 'b', role: 'approve', stage: 1 },
    ],
  });
  assert.match(validateApprovalLine({ authorId: 'me', approverIds: [], isCandidate }).error, /한 명 이상/);
  assert.match(
    validateApprovalLine({ authorId: 'me', approverIds: Array.from({ length: APPROVERS_MAX + 1 }, (_, i) => `u${i}`), isCandidate }).error,
    /까지/,
  );
  assert.match(validateApprovalLine({ authorId: 'me', approverIds: ['a', 'a'], isCandidate }).error, /두 번/);
  assert.match(validateApprovalLine({ authorId: 'me', approverIds: ['me'], isCandidate }).error, /자기 자신/);
  assert.match(validateApprovalLine({ authorId: 'me', approverIds: ['a'], ccIds: ['a'], isCandidate }).error, /참조자로/);
  assert.match(validateApprovalLine({ authorId: 'me', approverIds: ['outsider'], isCandidate }).error, /고를 수 없는/);
  assert.match(validateApprovalLine({ authorId: 'me', approverIds: 'a', isCandidate }).error, /한 명 이상/);
});

test('지출·근태 수정 내용 검사', () => {
  assert.deepEqual(parseExpensePayload({ amount: '12000', category: '교통비', spentOn: '2026-10-16' }).payload, {
    amount: 12000,
    category: '교통비',
    spentOn: '2026-10-16',
  });
  assert.match(parseExpensePayload({ amount: 12.5, category: '교통비', spentOn: '2026-10-16' }).error, /원 단위/);
  assert.match(parseExpensePayload({ amount: 1, category: '술값', spentOn: '2026-10-16' }).error, /분류/);
  const today = '2026-10-17';
  assert.deepEqual(parseAttendancePayload({ workDate: '2026-10-16', clockIn: '09:05', clockOut: '18:10' }, { today }).payload, {
    workDate: '2026-10-16',
    clockIn: '09:05',
    clockOut: '18:10',
  });
  assert.equal(parseAttendancePayload({ workDate: '2026-10-16', clockIn: '09:05' }, { today }).payload.clockOut, null);
  assert.match(parseAttendancePayload({ workDate: '2026-10-18', clockIn: '09:00' }, { today }).error, /앞으로/);
  assert.match(parseAttendancePayload({ workDate: '2026-07-01', clockIn: '09:00' }, { today }).error, /60일/);
  assert.match(parseAttendancePayload({ workDate: '2026-10-16', clockIn: '18:00', clockOut: '09:00' }, { today }).error, /늦어야/);
  assert.match(parseAttendancePayload({ workDate: '2026-10-16', clockIn: '25:00' }, { today }).error, /출근 시각/);
});

test('제목을 비우면 종류에 맞는 이름', () => {
  assert.equal(
    defaultApprovalTitle('leave', { leaveType: 'annual', startDate: '2026-10-19', endDate: '2026-10-21', halfDays: 6 }),
    '연차 신청 (10/19~10/21, 3일)',
  );
  assert.equal(defaultApprovalTitle('expense', { category: '식대', amount: 12000 }), '지출 결재 — 식대 12,000원');
  assert.equal(defaultApprovalTitle('attendance', { workDate: '2026-10-16' }), '근태 수정 (10/16)');
});

// ── 결재 진행 ──────────────────────────────────────────────────────────

const doc = (over = {}) => ({ id: 'D', authorId: 'author', status: 'pending', ...over });
const steps = () => [
  { id: 's1', stepOrder: 0, approverId: 'a1', status: 'pending' },
  { id: 's2', stepOrder: 1, approverId: 'a2', status: 'waiting' },
];

test('승인 — 차례인 사람만, 다음 결재자에게 넘기고 마지막이면 문서 승인', () => {
  const now = new Date('2026-10-17T01:00:00Z');
  assert.equal(planDecision({ doc: doc(), steps: steps(), actorId: 'a2', action: 'approve' }).status, 403);
  const first = planDecision({ doc: doc(), steps: steps(), ccIds: ['cc'], actorId: 'a1', action: 'approve', now });
  assert.deepEqual(first.doc, { currentStep: 1, updatedAt: now });
  assert.deepEqual(first.steps, [
    { id: 's1', patch: { status: 'approved', comment: null, decidedAt: now } },
    { id: 's2', patch: { status: 'pending' } },
  ]);
  assert.deepEqual(first.notify, { event: 'next', userIds: ['a2'] });

  const second = planDecision({
    doc: doc(),
    steps: [
      { id: 's1', stepOrder: 0, approverId: 'a1', status: 'approved' },
      { id: 's2', stepOrder: 1, approverId: 'a2', status: 'pending' },
    ],
    ccIds: ['cc'],
    actorId: 'a2',
    action: 'approve',
    comment: ' 좋습니다 ',
    now,
  });
  assert.equal(second.doc.status, 'approved');
  assert.equal(second.steps[0].patch.comment, '좋습니다');
  assert.deepEqual(second.notify.event, 'approved');
  assert.deepEqual(new Set(second.notify.userIds), new Set(['author', 'cc', 'a1', 'a2']));
});

test('반려는 사유가 있어야 하고 문서가 끝난다', () => {
  assert.equal(planDecision({ doc: doc(), steps: steps(), actorId: 'a1', action: 'reject' }).status, 400);
  const rejected = planDecision({ doc: doc(), steps: steps(), actorId: 'a1', action: 'reject', comment: '날짜 조정 바람' });
  assert.equal(rejected.doc.status, 'rejected');
  assert.equal(rejected.steps[0].patch.status, 'rejected');
  assert.deepEqual(rejected.notify.userIds, ['author']);
  assert.equal(planDecision({ doc: doc({ status: 'rejected' }), steps: steps(), actorId: 'a1', action: 'approve' }).status, 409);
});

test('회수는 올린 사람이 진행 중일 때만, 취소는 관리자가 승인된 것만(사유 필수)', () => {
  assert.equal(planDecision({ doc: doc(), steps: steps(), actorId: 'a1', action: 'withdraw' }).status, 403);
  const withdrawn = planDecision({ doc: doc(), steps: steps(), actorId: 'author', action: 'withdraw' });
  assert.equal(withdrawn.doc.status, 'withdrawn');
  assert.deepEqual(withdrawn.steps, [{ id: 's1', patch: { status: 'waiting' } }]);
  assert.deepEqual(withdrawn.notify.userIds, ['a1']);

  const approved = doc({ status: 'approved' });
  assert.equal(planDecision({ doc: approved, steps: [], actorId: 'boss', action: 'cancel', comment: 'x' }).status, 403);
  assert.equal(planDecision({ doc: approved, steps: [], actorId: 'boss', action: 'cancel', isManager: true }).status, 400);
  const canceled = planDecision({ doc: approved, steps: [], actorId: 'boss', action: 'cancel', comment: '중복 신청', isManager: true });
  assert.equal(canceled.doc.status, 'canceled');
  assert.equal(canceled.doc.cancelReason, '중복 신청');
  assert.equal(planDecision({ doc: doc(), steps: [], actorId: 'boss', action: 'cancel', comment: 'x', isManager: true }).status, 409);
});

test('볼 수 있는 사람 — 올린 사람·결재자·참조자·관리자', () => {
  const s = steps();
  assert.equal(canViewDocument({ doc: doc(), steps: s, userId: 'author' }), true);
  assert.equal(canViewDocument({ doc: doc(), steps: s, userId: 'a2' }), true);
  assert.equal(canViewDocument({ doc: doc(), steps: s, ccIds: ['cc'], userId: 'cc' }), true);
  assert.equal(canViewDocument({ doc: doc(), steps: s, userId: 'boss', isManager: true }), true);
  assert.equal(canViewDocument({ doc: doc(), steps: s, userId: 'stranger' }), false);
});

test('미리 채울 결재선 — 조직도 상위자, 없으면 최근 저장한 결재선', () => {
  assert.equal(suggestApprovalLine({}), null);
  const saved = [
    { id: 'L1', approverIds: ['a'], ccIds: [], createdAt: '2026-10-01' },
    { id: 'L2', approverIds: ['b'], ccIds: ['c'], createdAt: '2026-10-10' },
  ];
  assert.deepEqual(suggestApprovalLine({ savedLines: saved }), { approverIds: ['b'], ccIds: ['c'], source: 'saved', lineId: 'L2' });
  assert.equal(suggestApprovalLine({ savedLines: saved, managerChain: ['m1', 'm2'] }).source, 'org');
});

// ── 출퇴근 ─────────────────────────────────────────────────────────────

test('시각 글자와 날짜', () => {
  assert.equal(parseHm('09:30'), 570);
  assert.equal(parseHm('24:00'), null);
  assert.equal(parseHm('9:30'), null);
  const at = dateAtMinutes('2026-10-16', 9 * 60 + 5);
  assert.equal(localDateKey(at), '2026-10-16');
  assert.equal(at.getHours(), 9);
  assert.equal(monthDays('2026-02').length, 28);
  assert.equal(monthDays('2026-13'), null);
});

test('지각·조퇴·일한 시간 — 반차·휴가는 그만큼 따지지 않는다', () => {
  const record = { workDate: '2026-10-16', clockInAt: dateAtMinutes('2026-10-16', 9 * 60 + 10), clockOutAt: dateAtMinutes('2026-10-16', 17 * 60) };
  assert.deepEqual(recordFlags(record), { late: true, earlyLeave: true, workedMinutes: 470, missingClockOut: false });
  assert.equal(recordFlags(record, { halfType: 'half_am' }).late, false);
  assert.equal(recordFlags(record, { halfType: 'half_pm' }).earlyLeave, false);
  assert.equal(recordFlags(record, { fullLeave: true }).late, false);
  const overnight = { workDate: '2026-10-16', clockInAt: dateAtMinutes('2026-10-16', 22 * 60), clockOutAt: dateAtMinutes('2026-10-17', 6 * 60) };
  assert.equal(recordFlags(overnight).earlyLeave, false, '다음 날 새벽 퇴근은 조퇴가 아니다');
  assert.equal(recordFlags(overnight).workedMinutes, 480);
  assert.equal(recordFlags({ workDate: '2026-10-16', clockInAt: record.clockInAt }).missingClockOut, true);
});

test('퇴근 대상 — 오늘 기록, 없으면 20시간 안에 출근한 어제의 열린 기록', () => {
  const now = dateAtMinutes('2026-10-17', 6 * 60);
  const yesterdayOpen = { workDate: '2026-10-16', clockInAt: dateAtMinutes('2026-10-16', 22 * 60), clockOutAt: null };
  assert.equal(clockOutTarget([yesterdayOpen], now), yesterdayOpen);
  const stale = { workDate: '2026-10-16', clockInAt: dateAtMinutes('2026-10-16', 8 * 60), clockOutAt: null };
  assert.equal(clockOutTarget([stale], dateAtMinutes('2026-10-17', 9 * 60)), null);
  const today = { workDate: '2026-10-17', clockInAt: now };
  assert.equal(clockOutTarget([yesterdayOpen, today], now), today);
});

test('한 달 요약 — 결근은 지난 근무일 중 기록·휴가가 없는 날만', () => {
  const at = (day, minutes) => dateAtMinutes(day, minutes);
  const records = [
    { workDate: '2026-10-01', clockInAt: at('2026-10-01', 8 * 60 + 50), clockOutAt: at('2026-10-01', 18 * 60) },
    { workDate: '2026-10-02', clockInAt: at('2026-10-02', 9 * 60 + 20), clockOutAt: null },
  ];
  const summary = summarizeMonth({
    monthKey: '2026-10',
    records,
    leaveByDate: new Map([['2026-10-06', { halfDays: 2, halfType: null }]]),
    holidays: new Set(['2026-10-05', '2026-10-09']),
    workStart: 540,
    workEnd: 1080,
    today: '2026-10-08',
  });
  // 10/1(목) 출근, 10/2(금) 지각+퇴근 없음, 10/5(월) 공휴일, 10/6(화) 휴가, 10/7(수) 결근, 10/8(오늘)은 아직 안 셈.
  assert.equal(summary.daysWorked, 2);
  assert.equal(summary.late, 1);
  assert.equal(summary.missingClockOut, 1);
  assert.equal(summary.absent, 1);
  assert.equal(summary.leaveHalfDays, 2);
  assert.equal(summary.workedMinutes, 550);
});

test('결재 알림 — 사건마다 종류·제목·본문, 모르는 사건은 null', () => {
  const doc = { kind: 'leave', title: '연차 신청', authorName: '김철수' };
  assert.deepEqual(approvalNotificationOf('created', doc), { kind: 'request', title: '결재 요청', body: '김철수 — 연차 신청' });
  assert.equal(approvalNotificationOf('next', doc).kind, 'request');
  assert.deepEqual(approvalNotificationOf('approved', doc), { kind: 'approved', title: '휴가 결재 승인', body: '승인되었습니다: 연차 신청' });
  assert.equal(approvalNotificationOf('rejected', { ...doc, kind: 'expense' }).title, '지출 결재 반려');
  assert.equal(approvalNotificationOf('withdrawn', doc).body, '김철수님이 회수했습니다: 연차 신청');
  assert.equal(approvalNotificationOf('canceled', { ...doc, kind: 'attendance' }).title, '근태 수정 결재 취소');
  assert.equal(approvalNotificationOf('unknown', doc), null);
  for (const e of ['created', 'approved', 'rejected', 'withdrawn', 'canceled']) {
    assert.ok(APPROVAL_NOTIFICATION_KINDS.includes(approvalNotificationOf(e, doc).kind));
  }
});
