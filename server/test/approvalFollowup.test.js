// 결재 기능 후속 — 전결 규정, 합의의 "반대 의견으로 진행", 후결(사후 결재), 통계·알림의 새 상태, 전자서명(위변조 방지).
// `node --test test/*.test.js`(DB 없이 돈다).
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { test } from 'node:test';
import { applyFinalRule, parseFinalRule, pickFinalRule } from '../src/approvalFinalRules.js';
import { approvalNotificationOf, approvalStats, planDecision, validateApprovalLine } from '../src/approvalRules.js';
import { canonicalJson, documentDigest, keyFingerprint, sealsFor, verifyDocument } from '../src/approvalSeal.js';

const now = new Date('2026-10-18T10:00:00Z');
const step = (id, stepOrder, extra = {}) => ({
  id,
  stepOrder,
  stage: stepOrder,
  approverId: id,
  approverName: id,
  role: 'approve',
  status: 'waiting',
  ...extra,
});
const doc = (extra = {}) => ({ id: 'd1', authorId: 'author', authorName: '작성자', status: 'pending', title: '문서', ...extra });

test('결재선 — 후결은 맨 뒤에만, 앞에 결재할 사람이 있어야 하고 후결 칸은 한 단계', () => {
  const isCandidate = () => true;
  const ok = validateApprovalLine({
    authorId: 'me',
    approverIds: ['a', 'b', 'c', 'd'],
    roles: { b: 'agree', c: 'post', d: 'post' },
    isCandidate,
  });
  assert.deepEqual(
    ok.line.map((l) => [l.userId, l.role, l.stage]),
    [
      ['a', 'approve', 0],
      ['b', 'agree', 1],
      ['c', 'post', 2],
      ['d', 'post', 2],
    ],
  );
  assert.match(validateApprovalLine({ authorId: 'me', approverIds: ['a', 'b'], roles: { a: 'post' }, isCandidate }).error, /후결 앞에/);
  assert.match(validateApprovalLine({ authorId: 'me', approverIds: ['a', 'b', 'c'], roles: { b: 'post' }, isCandidate }).error, /맨 뒤/);
  assert.match(validateApprovalLine({ authorId: 'me', approverIds: ['a'], roles: { a: 'boss' }, isCandidate }).error, /역할/);
});

test('후결 — 앞의 결재가 끝나면 문서가 승인되고 후결 칸이 차례(후결 요청 알림), 후결은 확인만', () => {
  const steps = [step('a', 0, { status: 'pending' }), step('p1', 1, { role: 'post' }), step('p2', 2, { role: 'post', stage: 1 })];
  const plan = planDecision({ doc: doc(), steps, actorId: 'a', action: 'approve', now });
  assert.equal(plan.doc.status, 'approved');
  assert.deepEqual(
    plan.steps.map((s) => [s.id, s.patch.status]),
    [
      ['a', 'approved'],
      ['p1', 'pending'],
      ['p2', 'pending'],
    ],
  );
  assert.equal(plan.notify.event, 'approved');
  assert.deepEqual(plan.alsoNotify, [{ event: 'post', userIds: ['p1', 'p2'] }]);

  // 승인된 문서에서 후결 확인 — 문서 상태는 그대로, 알림 없음.
  const after = [step('a', 0, { status: 'approved' }), step('p1', 1, { role: 'post', status: 'pending' })];
  const confirm = planDecision({ doc: doc({ status: 'approved' }), steps: after, actorId: 'p1', action: 'approve', comment: '확인', now });
  assert.equal(confirm.doc.status, undefined);
  assert.deepEqual(confirm.steps, [{ id: 'p1', patch: { status: 'approved', comment: '확인', decidedAt: now } }]);
  assert.match(
    planDecision({ doc: doc({ status: 'approved' }), steps: after, actorId: 'p1', action: 'reject', comment: 'x', now }).error,
    /확인만/,
  );
  // 후결 칸이 아니면 승인된 문서에서 차례가 없다.
  assert.equal(planDecision({ doc: doc({ status: 'approved' }), steps: after, actorId: 'a', action: 'approve', now }).status, 403);
  assert.equal(planDecision({ doc: doc({ status: 'rejected' }), steps: after, actorId: 'p1', action: 'approve', now }).status, 409);
  // 관리자가 취소하면 확인하지 않은 후결은 생략.
  const cancel = planDecision({ doc: doc({ status: 'approved' }), steps: after, actorId: 'mgr', action: 'cancel', comment: '중복', isManager: true, now });
  assert.deepEqual(cancel.steps, [{ id: 'p1', patch: { status: 'skipped' } }]);
});

test('전결이 승인하면 남은 결재 칸은 생략하지만 후결 칸은 차례가 된다', () => {
  const steps = [
    step('a', 0, { status: 'pending', role: 'final' }),
    step('b', 1),
    step('p', 2, { role: 'post' }),
  ];
  const plan = planDecision({ doc: doc(), steps, actorId: 'a', action: 'approve', now });
  assert.equal(plan.doc.status, 'approved');
  assert.deepEqual(
    plan.steps.map((s) => [s.id, s.patch.status]),
    [
      ['a', 'approved'],
      ['b', 'skipped'],
      ['p', 'pending'],
    ],
  );
});

test('합의의 반대 의견 — 합의 칸만·의견 필수, 결재는 이어지고 올린 사람에게 따로 알린다', () => {
  const steps = [
    step('g1', 0, { role: 'agree', status: 'pending', stage: 0 }),
    step('g2', 1, { role: 'agree', status: 'pending', stage: 0 }),
    step('b', 2, { stage: 1 }),
  ];
  // 같은 단계의 다른 합의자가 남아 있으면 기다림.
  const first = planDecision({ doc: doc(), steps, actorId: 'g1', action: 'disagree', comment: '예산 과다', now });
  assert.deepEqual(first.steps, [{ id: 'g1', patch: { status: 'disagreed', comment: '예산 과다', decidedAt: now } }]);
  assert.deepEqual(first.alsoNotify, [{ event: 'disagreed', userIds: ['author'] }]);
  // 마지막 합의자가 반대해도 다음 단계로 넘어간다.
  const second = planDecision({
    doc: doc(),
    steps: [{ ...steps[0], status: 'disagreed' }, steps[1], steps[2]],
    actorId: 'g2',
    action: 'disagree',
    comment: '반대',
    now,
  });
  assert.equal(second.notify.event, 'next');
  assert.deepEqual(second.notify.userIds, ['b']);
  assert.deepEqual(
    second.steps.map((s) => [s.id, s.patch.status]),
    [
      ['g2', 'disagreed'],
      ['b', 'pending'],
    ],
  );
  assert.match(planDecision({ doc: doc(), steps, actorId: 'g1', action: 'disagree', now }).error, /반대 의견을 쓰세요/);
  const approveStep = [step('a', 0, { status: 'pending' })];
  assert.match(planDecision({ doc: doc(), steps: approveStep, actorId: 'a', action: 'disagree', comment: 'x', now }).error, /합의 칸에서만/);
  // 반대한 사람도 승인 알림을 받는다(결정한 사람).
  const last = planDecision({
    doc: doc(),
    steps: [step('g', 0, { role: 'agree', status: 'disagreed' }), step('b', 1, { status: 'pending' })],
    actorId: 'b',
    action: 'approve',
    now,
  });
  assert.ok(last.notify.userIds.includes('g'));
});

test('통계·알림 — 반대 의견 수, 승인된 문서의 후결도 기다리는 칸, 후결 요청·반대 의견 알림 글', () => {
  const created = new Date('2026-10-01T00:00:00Z');
  const docs = [
    {
      doc: { kind: 'draft', status: 'approved', createdAt: created, decidedAt: new Date('2026-10-01T02:00:00Z') },
      steps: [
        step('g', 0, { role: 'agree', status: 'disagreed', decidedAt: new Date('2026-10-01T01:00:00Z') }),
        step('b', 1, { status: 'approved', decidedAt: new Date('2026-10-01T02:00:00Z') }),
        step('p', 2, { role: 'post', status: 'pending' }),
      ],
    },
  ];
  const stats = approvalStats(docs);
  const g = stats.byApprover.find((a) => a.userId === 'g');
  assert.equal(g.disagreed, 1);
  assert.equal(g.decided, 1);
  assert.equal(stats.byApprover.find((a) => a.userId === 'p').waiting, 1);
  assert.equal(approvalNotificationOf('post', { kind: 'draft', authorName: '김', title: 't' }).kind, 'request');
  assert.equal(approvalNotificationOf('post', { kind: 'draft', authorName: '김', title: 't' }).title, '후결 요청');
  assert.equal(approvalNotificationOf('disagreed', { kind: 'draft', authorName: '김', title: 't' }).kind, 'disagreed');
  assert.equal(approvalNotificationOf('postConfirmed', { kind: 'draft', title: 't' }), null);
});

test('전결 규정 — 입력 검사, 고르는 순서(양식 > 종류 > 모든 종류, 금액), 직책 이상인 첫 결재자를 전결로', () => {
  const positionLabels = ['사원', '팀장', '본부장', '대표'];
  assert.deepEqual(parseFinalRule({ kind: 'expense', minAmount: '1000000', positionLabel: '본부장' }, { positionLabels }).fields, {
    kind: 'expense',
    templateId: null,
    minAmount: 1000000,
    positionLabel: '본부장',
  });
  assert.match(parseFinalRule({ kind: 'expense', positionLabel: '회장' }, { positionLabels }).error, /직책 목록/);
  assert.match(parseFinalRule({ kind: 'nope', positionLabel: '팀장' }, { positionLabels }).error, /종류/);
  assert.match(parseFinalRule({ kind: 'leave', templateId: crypto.randomUUID(), positionLabel: '팀장' }, { positionLabels }).error, /양식/);

  const rules = [
    { id: 'r1', kind: 'expense', minAmount: null, positionLabel: '팀장' },
    { id: 'r2', kind: 'expense', minAmount: 1_000_000, positionLabel: '본부장' },
    { id: 'r3', kind: 'any', minAmount: null, positionLabel: '대표' },
  ];
  assert.equal(pickFinalRule(rules, { kind: 'expense', amount: 50_000 }).id, 'r1');
  assert.equal(pickFinalRule(rules, { kind: 'expense', amount: 2_000_000 }).id, 'r2');
  assert.equal(pickFinalRule(rules, { kind: 'leave' }).id, 'r3');

  const rank = { a: 1, b: 2, c: 3 };
  const ranks = { 팀장: 1, 본부장: 2, 대표: 3 };
  const opts = { rankOf: (id) => rank[id] ?? null, rankOfLabel: (l) => ranks[l] ?? null };
  // 올리는 사람이 고른 전결(c)은 지우고 본부장(b)을 전결로, 합의는 그대로.
  assert.deepEqual(applyFinalRule(rules[1], { approverIds: ['a', 'b', 'c'], roles: { c: 'final', a: 'agree' }, ...opts }), {
    roles: { a: 'agree', b: 'final' },
    finalUserId: 'b',
  });
  // 합의 칸은 전결이 될 수 없다 — 다음 결재자.
  assert.equal(applyFinalRule(rules[1], { approverIds: ['b', 'c'], roles: { b: 'agree' }, ...opts }).finalUserId, 'c');
  // 그 직책 이상이 없으면 전결 없이 끝까지.
  assert.deepEqual(applyFinalRule(rules[2], { approverIds: ['a', 'b'], roles: { a: 'final' }, ...opts }), { roles: {}, finalUserId: null });
});

test('전자서명 — 서명한 그대로면 맞고, 내용·결정 기록·서명 그림을 바꾸면 드러난다', () => {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const sign = (text) => crypto.sign(null, Buffer.from(text), privateKey).toString('base64');
  const verify = (text, seal) => crypto.verify(null, Buffer.from(text), publicKey, Buffer.from(seal, 'base64'));
  const d = {
    id: 'd1',
    scopeKey: 'server',
    kind: 'expense',
    docNumber: '지출-2026-0001',
    authorId: 'u0',
    authorName: '작성자',
    title: '지출 결재 — 비품 50,000원',
    body: '프린터 토너',
    payload: { amount: 50000, category: '비품', spentOn: '2026-10-17' },
    attachments: [{ fileUrl: '/uploads/r.png', fileName: 'r.png', fileSize: 10 }],
    createdAt: new Date('2026-10-17T00:00:00Z'),
  };
  const s1 = step('a', 0, { status: 'approved', decidedAt: new Date('2026-10-17T01:00:00Z'), signatureHash: 'h1', signaturePath: '/uploads/s.png' });
  const s2 = step('b', 1, { status: 'approved', decidedAt: new Date('2026-10-17T02:00:00Z'), comment: '좋습니다' });
  // 첫 칸 서명 → 둘째 칸 서명(사슬).
  const [seal1] = sealsFor({ doc: d, steps: [s1, step('b', 1)], stepIds: ['a'], sign });
  const signed1 = { ...s1, seal: seal1.seal };
  const [seal2] = sealsFor({ doc: d, steps: [signed1, s2], stepIds: ['b'], sign });
  const steps = [signed1, { ...s2, seal: seal2.seal }];
  const fileHashOf = () => 'h1';
  const ok = verifyDocument({ doc: d, steps, verify, fileHashOf });
  assert.equal(ok.ok, true);
  assert.deepEqual(
    ok.steps.map((s) => s.result),
    ['valid', 'valid'],
  );
  assert.equal(ok.digest, documentDigest(d));

  // 금액을 고치면 두 칸 모두 깨진다(문서 지문).
  const tampered = verifyDocument({ doc: { ...d, payload: { ...d.payload, amount: 500000 } }, steps, verify, fileHashOf });
  assert.equal(tampered.ok, false);
  assert.deepEqual(
    tampered.steps.map((s) => s.result),
    ['invalid', 'invalid'],
  );
  // 첫 칸의 결정 시각을 고치면 그 칸만 깨진다(둘째 칸은 앞 칸의 서명 값을 이어 받으므로 그대로 맞음).
  const moved = verifyDocument({
    doc: d,
    steps: [{ ...steps[0], comment: '고침' }, steps[1]],
    verify,
    fileHashOf,
  });
  assert.deepEqual(
    moved.steps.map((s) => s.result),
    ['invalid', 'valid'],
  );
  // 서명 그림 파일이 바뀌거나 없어짐.
  assert.equal(verifyDocument({ doc: d, steps, verify, fileHashOf: () => 'other' }).steps[0].result, 'signatureChanged');
  assert.equal(verifyDocument({ doc: d, steps, verify, fileHashOf: () => null }).steps[0].result, 'signatureMissing');
  // 계정이 지워져 id가 비어도 서명은 맞다(이름으로 서명).
  assert.equal(
    verifyDocument({ doc: { ...d, authorId: null }, steps: steps.map((s) => ({ ...s, approverId: null })), verify, fileHashOf }).ok,
    true,
  );
  // 이 기능 전 칸 — 서명 없음(맞는 칸이 없으면 ok가 아님).
  const old = verifyDocument({ doc: d, steps: [s2], verify, fileHashOf });
  assert.deepEqual(
    old.steps.map((s) => s.result),
    ['unsealed'],
  );
  assert.equal(old.ok, false);
});

test('전자서명 도우미 — 키 순서와 상관없는 JSON, 키 지문 모양', () => {
  assert.equal(canonicalJson({ b: 1, a: [{ d: 2, c: null }] }), canonicalJson({ a: [{ c: null, d: 2 }], b: 1 }));
  assert.equal(canonicalJson({ a: undefined, b: new Date('2026-01-01T00:00:00Z') }), '{"b":"2026-01-01T00:00:00.000Z"}');
  const { publicKey } = crypto.generateKeyPairSync('ed25519');
  assert.match(keyFingerprint(publicKey.export({ type: 'spki', format: 'der' })), /^([0-9A-F]{4}-){7}[0-9A-F]{4}$/);
});
