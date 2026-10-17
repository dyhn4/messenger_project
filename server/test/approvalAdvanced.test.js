// 결재 고급 규칙 — 결재선 역할(결재·합의·전결)과 단계, 합의(같은 단계가 모두 동의해야 넘어감), 전결(남은 칸 생략), 대결(부재 중 대신 결재 —
// 누가 했는지 남김, 자기 문서·이미 결재선에 있는 사람은 못 함), 서명 적어 두기, 문서 번호, 대결 설정 검사, 결재 통계.
// `node --test test/*.test.js`(DB 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  activeDelegationMap,
  approvalStats,
  canViewDocument,
  docNumberOf,
  parseDelegation,
  planDecision,
  proxyForOf,
  rolesOfLine,
  stageOf,
  suggestApprovalLine,
  validateApprovalLine,
} from '../src/approvalRules.js';

const isCandidate = (id) => id !== 'outsider';
const now = new Date('2026-10-17T01:00:00Z');
const doc = (over = {}) => ({ id: 'D', authorId: 'author', status: 'pending', ...over });
const step = (id, order, approverId, status, extra = {}) => ({ id, stepOrder: order, approverId, approverName: approverId, status, ...extra });

test('결재선 역할 — 이어진 합의는 한 단계, 전결은 한 명, 모르는 역할 거절', () => {
  const ok = validateApprovalLine({
    authorId: 'me',
    approverIds: ['lead', 'hr', 'fin', 'boss', 'ceo'],
    roles: { hr: 'agree', fin: 'agree', boss: 'final' },
    isCandidate,
  });
  assert.deepEqual(ok.line, [
    { userId: 'lead', role: 'approve', stage: 0 },
    { userId: 'hr', role: 'agree', stage: 1 },
    { userId: 'fin', role: 'agree', stage: 1 },
    { userId: 'boss', role: 'final', stage: 2 },
    { userId: 'ceo', role: 'approve', stage: 3 },
  ]);
  // 떨어진 합의는 다른 단계.
  const split = validateApprovalLine({ authorId: 'me', approverIds: ['a', 'b', 'c'], roles: { a: 'agree', c: 'agree' }, isCandidate });
  assert.deepEqual(split.line.map((l) => l.stage), [0, 1, 2]);
  assert.match(validateApprovalLine({ authorId: 'me', approverIds: ['a', 'b'], roles: { a: 'final', b: 'final' }, isCandidate }).error, /한 명만/);
  assert.match(validateApprovalLine({ authorId: 'me', approverIds: ['a'], roles: { a: 'boss' }, isCandidate }).error, /역할/);
  assert.equal(stageOf({ stepOrder: 3 }), 3, '단계가 없는 예전 칸은 순서가 곧 단계');
  assert.equal(stageOf({ stepOrder: 3, stage: 1 }), 1);
});

test('합의 — 같은 단계는 함께 차례, 모두 동의해야 다음 단계로, 하나라도 반려하면 끝', () => {
  const steps = [
    step('s1', 0, 'hr', 'pending', { stage: 0, role: 'agree' }),
    step('s2', 1, 'fin', 'pending', { stage: 0, role: 'agree' }),
    step('s3', 2, 'boss', 'waiting', { stage: 1 }),
  ];
  const first = planDecision({ doc: doc(), steps, actorId: 'hr', action: 'approve', now });
  assert.deepEqual(first.steps, [{ id: 's1', patch: { status: 'approved', comment: null, decidedAt: now } }]);
  assert.deepEqual(first.doc, { updatedAt: now }, '아직 fin을 기다린다');
  assert.equal(first.notify.event, 'agreed');
  const afterHr = [{ ...steps[0], status: 'approved' }, steps[1], steps[2]];
  const second = planDecision({ doc: doc(), steps: afterHr, actorId: 'fin', action: 'approve', now });
  assert.deepEqual(second.steps.at(-1), { id: 's3', patch: { status: 'pending' } });
  assert.deepEqual(second.doc, { currentStep: 1, updatedAt: now });
  assert.deepEqual(second.notify, { event: 'next', userIds: ['boss'] });
  // 합의 중 반려 — 같은 단계의 다른 차례는 거둔다.
  const rejected = planDecision({ doc: doc(), steps, actorId: 'fin', action: 'reject', comment: '예산 초과', now });
  assert.equal(rejected.doc.status, 'rejected');
  assert.deepEqual(rejected.steps, [
    { id: 's2', patch: { status: 'rejected', comment: '예산 초과', decidedAt: now } },
    { id: 's1', patch: { status: 'waiting' } },
  ]);
  // 첫 단계가 합의면 회수할 때 둘 다 거둔다.
  const withdrawn = planDecision({ doc: doc(), steps, actorId: 'author', action: 'withdraw', now });
  assert.deepEqual(withdrawn.steps.map((s) => s.id), ['s1', 's2']);
  assert.deepEqual(withdrawn.notify.userIds, ['hr', 'fin']);
});

test('전결 — 승인하면 남은 칸은 생략하고 결재가 끝난다', () => {
  const steps = [
    step('s1', 0, 'lead', 'approved', { stage: 0, decidedAt: now }),
    step('s2', 1, 'boss', 'pending', { stage: 1, role: 'final' }),
    step('s3', 2, 'ceo', 'waiting', { stage: 2 }),
  ];
  const plan = planDecision({ doc: doc(), steps, ccIds: ['cc'], actorId: 'boss', action: 'approve', now });
  assert.equal(plan.doc.status, 'approved');
  assert.deepEqual(plan.steps, [
    { id: 's2', patch: { status: 'approved', comment: null, decidedAt: now } },
    { id: 's3', patch: { status: 'skipped' } },
  ]);
  assert.equal(plan.notify.event, 'approved');
  assert.ok(!plan.notify.userIds.includes('ceo'), '생략된 사람에게는 알리지 않는다');
  // 전결권자가 반려하면 보통 반려.
  assert.equal(planDecision({ doc: doc(), steps, actorId: 'boss', action: 'reject', comment: 'x' }).doc.status, 'rejected');
});

test('대결 — 맡은 사람이 대신 결정하고 누가 했는지 남는다, 서명은 결정한 사람 것', () => {
  const steps = [step('s1', 0, 'lead', 'pending', { stage: 0 }), step('s2', 1, 'boss', 'waiting', { stage: 1 })];
  assert.equal(planDecision({ doc: doc(), steps, actorId: 'deputy', action: 'approve' }).status, 403, '맡지 않았으면 안 됨');
  const plan = planDecision({
    doc: doc(),
    steps,
    actorId: 'deputy',
    actorName: '부팀장',
    action: 'approve',
    proxyFor: new Set(['lead']),
    signaturePath: '/uploads/deputy-sign.png',
    now,
  });
  assert.deepEqual(plan.steps[0], {
    id: 's1',
    patch: { status: 'approved', comment: null, decidedAt: now, actedById: 'deputy', actedByName: '부팀장', signaturePath: '/uploads/deputy-sign.png' },
  });
  // 본인이 하면 대결 표시 없이 본인 서명.
  const own = planDecision({ doc: doc(), steps, actorId: 'lead', action: 'approve', signaturePath: '/uploads/lead.png', now });
  assert.deepEqual(own.steps[0].patch, { status: 'approved', comment: null, decidedAt: now, signaturePath: '/uploads/lead.png' });
  // 반려에는 서명을 적지 않는다.
  const rejected = planDecision({ doc: doc(), steps, actorId: 'deputy', action: 'reject', comment: '보류', proxyFor: new Set(['lead']), signaturePath: '/x.png' });
  assert.equal(rejected.steps[0].patch.signaturePath, undefined);
  assert.equal(rejected.steps[0].patch.actedById, 'deputy');
});

test('대결로 볼 수 있는 사람·대신할 수 있는 결재자 — 자기 문서·이미 결재선에 있는 사람은 못 함', () => {
  const steps = [step('s1', 0, 'lead', 'pending'), step('s2', 1, 'boss', 'waiting')];
  const map = new Map([['lead', 'deputy'], ['boss', 'deputy']]);
  assert.deepEqual([...proxyForOf({ actorId: 'deputy', doc: doc(), steps, delegationMap: map })].sort(), ['boss', 'lead']);
  assert.equal(proxyForOf({ actorId: 'deputy', doc: doc({ authorId: 'deputy' }), steps, delegationMap: map }).size, 0, '자기 문서');
  assert.equal(
    proxyForOf({ actorId: 'boss', doc: doc(), steps, delegationMap: new Map([['lead', 'boss']]) }).size,
    0,
    '이미 결재선에 있음 — 두 칸을 채우지 않게',
  );
  assert.equal(canViewDocument({ doc: doc(), steps, userId: 'deputy', proxyFor: new Set(['lead']) }), true);
  assert.equal(canViewDocument({ doc: doc(), steps, userId: 'deputy', proxyFor: new Set(['boss']) }), false, '아직 boss 차례가 아님');
  assert.equal(canViewDocument({ doc: doc(), steps: [step('s1', 0, 'lead', 'approved', { actedById: 'deputy' })], userId: 'deputy' }), true, '대결한 문서');
});

test('대결 설정 검사 — 자기 자신·고를 수 없는 사람·기간·겹침', () => {
  const base = { userId: 'lead', delegateId: 'deputy', startDate: '2026-10-20', endDate: '2026-10-24', today: '2026-10-17', isCandidate };
  assert.deepEqual(parseDelegation({ ...base, reason: ' 휴가 ' }).delegation, {
    startDate: '2026-10-20',
    endDate: '2026-10-24',
    delegateId: 'deputy',
    reason: '휴가',
  });
  assert.match(parseDelegation({ ...base, delegateId: 'lead' }).error, /자기 자신/);
  assert.match(parseDelegation({ ...base, delegateId: 'outsider' }).error, /대신 결재할 수 없는/);
  assert.match(parseDelegation({ ...base, endDate: '2026-10-19' }).error, /빠릅니다/);
  assert.match(parseDelegation({ ...base, startDate: '2026-10-01', endDate: '2026-10-10' }).error, /지난/);
  assert.match(parseDelegation({ ...base, endDate: '2027-03-01' }).error, /90일/);
  assert.match(parseDelegation({ ...base, existing: [{ startDate: '2026-10-23', endDate: '2026-10-30' }] }).error, /이미/);
  const map = activeDelegationMap(
    [
      { userId: 'lead', delegateId: 'deputy', startDate: '2026-10-15', endDate: '2026-10-18' },
      { userId: 'boss', delegateId: 'x', startDate: '2026-10-20', endDate: '2026-10-21' },
    ],
    '2026-10-17',
  );
  assert.deepEqual([...map], [['lead', 'deputy']], '오늘 효력 있는 것만');
});

test('문서 번호·저장한 결재선의 역할', () => {
  assert.equal(docNumberOf('leave', 2026, 12), '휴가-2026-0012');
  assert.equal(docNumberOf('form', 2026, 12345), '양식-2026-12345');
  assert.deepEqual(rolesOfLine([{ userId: 'a', role: 'approve' }, { userId: 'b', role: 'agree' }]), { b: 'agree' });
  assert.deepEqual(rolesOfLine(null), {});
  const saved = [{ id: 'L1', approverIds: ['a', 'b'], ccIds: [], line: [{ userId: 'b', role: 'final' }], createdAt: '2026-10-01' }];
  assert.deepEqual(suggestApprovalLine({ savedLines: saved }).roles, { b: 'final' });
  assert.equal(suggestApprovalLine({ savedLines: [{ ...saved[0], line: null }] }).roles, undefined);
});

test('결재 통계 — 종류별 건수·상태·평균 시간, 결재자별 결정·대결·기다림·응답 시간', () => {
  const at = (h) => new Date(Date.UTC(2026, 9, 1, h));
  const docs = [
    {
      doc: { kind: 'leave', status: 'approved', createdAt: at(0), decidedAt: at(10) },
      steps: [
        step('a', 0, 'lead', 'approved', { decidedAt: at(2) }),
        step('b', 1, 'boss', 'approved', { decidedAt: at(10), actedById: 'deputy' }),
      ],
    },
    {
      doc: { kind: 'leave', status: 'rejected', createdAt: at(0), decidedAt: at(4) },
      steps: [step('c', 0, 'lead', 'rejected', { decidedAt: at(4) })],
    },
    {
      doc: { kind: 'expense', status: 'pending', createdAt: at(1), decidedAt: null },
      steps: [step('d', 0, 'lead', 'pending')],
    },
  ];
  const s = approvalStats(docs);
  assert.deepEqual(s.totals, { total: 3, pending: 1, approved: 1, rejected: 1, withdrawn: 0, canceled: 0, avgHours: 7 });
  assert.deepEqual(s.byKind.map((k) => [k.label, k.total, k.avgHours]), [['휴가', 2, 7], ['지출', 1, null]]);
  const lead = s.byApprover.find((r) => r.userId === 'lead');
  assert.deepEqual({ ...lead }, { userId: 'lead', name: 'lead', decided: 2, approved: 1, rejected: 1, proxied: 0, waiting: 1, avgHours: 3 });
  const boss = s.byApprover.find((r) => r.userId === 'boss');
  assert.equal(boss.proxied, 1);
  assert.equal(boss.avgHours, 8, '앞 단계가 결정한 때(2시)부터 10시까지');
});
