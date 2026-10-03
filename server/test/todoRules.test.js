// 할 일(To-Do) 순수 규칙 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  checkDateOrder,
  isValidDateString,
  newlyAssigned,
  nextCompletedAt,
  parseAttachments,
  parseTodoCreate,
  parseTodoListQuery,
  parseTodoPatch,
  patchDenial,
  planReminders,
  pushTargets,
  reminderTargets,
  shouldDeliverReminder,
  statusOf,
  todoPermissions,
  todoRole,
  TODO_ATTACHMENTS_MAX,
  TODO_REMINDERS_MAX,
} from '../src/todoRules.js';
import { signFileUrl } from '../src/upload.js';

const U1 = '11111111-1111-4111-8111-111111111111';
const U2 = '22222222-2222-4222-8222-222222222222';
const U3 = '33333333-3333-4333-8333-333333333333';
const NOW = 1_800_000_000_000;

test('statusOf: 0 대기 / 1~99 진행 / 100 완료', () => {
  assert.equal(statusOf(0), 'todo');
  assert.equal(statusOf(1), 'doing');
  assert.equal(statusOf(99), 'doing');
  assert.equal(statusOf(100), 'done');
});

test('isValidDateString / checkDateOrder', () => {
  assert.ok(isValidDateString('2026-02-28'));
  assert.ok(!isValidDateString('2026-02-30'));
  assert.ok(!isValidDateString('2026/02/28'));
  assert.ok(!isValidDateString(20260228));
  assert.equal(checkDateOrder('2026-01-01', '2026-01-01'), null);
  assert.ok(checkDateOrder('2026-01-02', '2026-01-01'));
  assert.equal(checkDateOrder(null, '2026-01-01'), null);
});

test('parseTodoCreate: 제목은 필수·100자, 설명 2000자, 담당자 30명, 중복 제거', () => {
  assert.ok(parseTodoCreate({ title: '   ' }, NOW).error);
  assert.ok(parseTodoCreate({ title: 'a'.repeat(101) }, NOW).error);
  assert.equal(parseTodoCreate({ title: 'a'.repeat(100) }, NOW).title.length, 100);
  assert.ok(parseTodoCreate({ title: 't', description: 'x'.repeat(2001) }, NOW).error);
  const ok = parseTodoCreate({ title: ' 제목 ', description: '  ', assigneeIds: [U1, U1.toUpperCase(), U2] }, NOW);
  assert.equal(ok.title, '제목');
  assert.equal(ok.description, null);
  assert.deepEqual(ok.assigneeIds, [U1, U2]);
  assert.ok(parseTodoCreate({ title: 't', assigneeIds: ['x'] }, NOW).error);
  const many = Array.from({ length: 31 }, (_, i) => `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`);
  assert.ok(parseTodoCreate({ title: 't', assigneeIds: many }, NOW).error);
});

test('parseTodoCreate: 날짜 형식·순서', () => {
  assert.ok(parseTodoCreate({ title: 't', startDate: '2026/10/01' }, NOW).error);
  assert.ok(parseTodoCreate({ title: 't', startDate: '2026-10-05', dueDate: '2026-10-01' }, NOW).error);
  const ok = parseTodoCreate({ title: 't', startDate: '2026-10-01', dueDate: '2026-10-05' }, NOW);
  assert.equal(ok.startDate, '2026-10-01');
  assert.equal(ok.dueDate, '2026-10-05');
  assert.equal(parseTodoCreate({ title: 't', dueDate: '2026-10-05' }, NOW).startDate, null);
});

test('parseTodoCreate: 알림은 미래 시각 최대 5개, 중복은 하나로', () => {
  assert.ok(parseTodoCreate({ title: 't', reminders: [NOW - 1] }, NOW).error);
  assert.deepEqual(parseTodoCreate({ title: 't', reminders: [NOW + 1000, { remindAt: NOW + 1000 }] }, NOW).reminders, [
    NOW + 1000,
  ]);
  const six = Array.from({ length: TODO_REMINDERS_MAX + 1 }, (_, i) => NOW + 1000 * (i + 1));
  assert.ok(parseTodoCreate({ title: 't', reminders: six }, NOW).error);
});

test('parseAttachments: 30개 제한, 서명 링크는 원본 경로로, 외부 주소는 거절', () => {
  const stored = '/uploads/abc.png';
  const ok = parseAttachments([{ kind: 'image', fileUrl: signFileUrl(stored, 'a.png'), fileName: 'a.png' }]);
  assert.equal(ok.value[0].fileUrl, stored);
  assert.ok(parseAttachments([{ fileUrl: 'https://evil.example/x.png' }]).error);
  assert.ok(parseAttachments([{ fileUrl: '/files/not-a-token' }]).error);
  const thirty = Array.from({ length: TODO_ATTACHMENTS_MAX }, () => ({ fileUrl: stored }));
  assert.equal(parseAttachments(thirty).value.length, 30);
  assert.ok(parseAttachments([...thirty, { fileUrl: stored }]).error);
  assert.ok(parseAttachments('x').error);
});

test('parseAttachments: 기존에 저장된 파일은 만료된 서명 링크로 돌려보내도 인정', () => {
  const stored = '/uploads/old.pdf';
  // 서명은 맞지만 만료된 토큰을 흉내 낼 수는 없으니, 저장된 경로를 그대로 되돌려 보내는 경우만 본다.
  assert.equal(parseAttachments([{ kind: 'file', fileUrl: stored }], [stored]).value[0].fileUrl, stored);
});

test('parseTodoPatch: 보낸 필드만, 방 옮기기·빈 본문·잘못된 진척률은 거절', () => {
  assert.ok(parseTodoPatch({}).error);
  assert.ok(parseTodoPatch(null).error);
  assert.ok(parseTodoPatch({ roomId: 'x' }).error);
  assert.ok(parseTodoPatch({ title: 't', teamId: 'x' }).error);
  assert.ok(parseTodoPatch({ progress: 101 }).error);
  assert.ok(parseTodoPatch({ progress: 50.5 }).error);
  assert.ok(parseTodoPatch({ title: '' }).error);
  assert.deepEqual(parseTodoPatch({ progress: 50, dueDate: null }).fields, { progress: 50, dueDate: null });
});

test('역할과 권한: 생성자 전부 / 담당자는 담당자 관리·삭제 불가 / 그 외 아무것도', () => {
  assert.equal(todoRole({ creatorId: U1, assigneeIds: [U1, U2], userId: U1 }), 'creator');
  assert.equal(todoRole({ creatorId: U1, assigneeIds: [U2], userId: U2 }), 'assignee');
  assert.equal(todoRole({ creatorId: U1, assigneeIds: [U2], userId: U3 }), 'viewer');
  assert.deepEqual(todoPermissions({ role: 'creator', creatorId: U1 }), { canEdit: true, canManage: true });
  assert.deepEqual(todoPermissions({ role: 'assignee', creatorId: U1 }), { canEdit: true, canManage: false });
  assert.deepEqual(todoPermissions({ role: 'viewer', creatorId: U1 }), { canEdit: false, canManage: false });
  // 만든 사람 계정이 사라진 할 일은 담당자가 관리한다.
  assert.equal(todoPermissions({ role: 'assignee', creatorId: null }).canManage, true);
});

test('patchDenial: 담당자가 assigneeIds를 보내면 403, 다른 필드는 통과, 그 외는 전부 403', () => {
  assert.equal(patchDenial('creator', U1, ['assigneeIds', 'title']), null);
  assert.equal(patchDenial('assignee', U1, ['title', 'progress', 'reminders', 'attachments']), null);
  assert.equal(patchDenial('assignee', U1, ['assigneeIds']).status, 403);
  assert.equal(patchDenial('viewer', U1, ['title']).status, 403);
});

test('nextCompletedAt: 100이면 기록(이미 있으면 유지), 아래로 내리면 해제', () => {
  const t0 = new Date(1000);
  const t1 = new Date(2000);
  assert.equal(nextCompletedAt(100, null, t1), t1);
  assert.equal(nextCompletedAt(100, t0, t1), t0);
  assert.equal(nextCompletedAt(99, t0, t1), null);
  assert.equal(nextCompletedAt(0, null, t1), null);
});

test('planReminders: 같은 시각은 유지, 바뀐 시각은 갱신(보낸 기록 초기화), 빠진 것은 삭제, 새 것은 추가', () => {
  const existing = [
    { id: 'a', remindAt: NOW - 5000, sent: true },
    { id: 'b', remindAt: NOW + 5000, sent: false },
    { id: 'c', remindAt: NOW + 9000, sent: false },
  ];
  const plan = planReminders(
    existing,
    [
      { id: 'a', remindAt: NOW - 5000 }, // 이미 지난 기존 알림도 그대로면 통과
      { id: 'b', remindAt: NOW + 7000 }, // 시각 변경
      { remindAt: NOW + 20000 }, // 새 알림
    ],
    NOW,
  );
  assert.deepEqual(plan.deleteIds, ['c']);
  assert.deepEqual(plan.updates, [{ id: 'b', remindAt: NOW + 7000 }]);
  assert.deepEqual(plan.inserts, [NOW + 20000]);
});

test('planReminders: 과거 시각으로 새로 잡거나 바꾸면 거절, 5개 초과 거절', () => {
  assert.ok(planReminders([], [{ remindAt: NOW - 1 }], NOW).error);
  assert.ok(planReminders([{ id: 'a', remindAt: NOW + 10, sent: false }], [{ id: 'a', remindAt: NOW - 10 }], NOW).error);
  const six = Array.from({ length: 6 }, (_, i) => ({ remindAt: NOW + 1000 * (i + 1) }));
  assert.ok(planReminders([], six, NOW).error);
  assert.deepEqual(planReminders([{ id: 'a', remindAt: NOW + 10, sent: false }], [], NOW).deleteIds, ['a']);
});

test('newlyAssigned / pushTargets / reminderTargets', () => {
  assert.deepEqual(newlyAssigned([U1], [U1, U2, U3], U3), [U2]);
  assert.deepEqual(newlyAssigned([], [], U1), []);
  // 푸시: 바꾼 본인·온라인·뮤트한 사람은 뺀다.
  assert.deepEqual(
    pushTargets([U1, U2, U3, U3], { actorId: U1, onlineIds: new Set([U2]), mutedIds: new Set() }),
    [U3],
  );
  assert.deepEqual(pushTargets([U1, U2], { mutedIds: new Set([U2]) }), [U1]);
  assert.deepEqual(reminderTargets([U2, U3], U1), [U2, U3]);
  assert.deepEqual(reminderTargets([], U1), [U1]);
  assert.deepEqual(reminderTargets([], null), []);
});

test('shouldDeliverReminder: 완료된 할 일·하루 넘게 묵은 알림은 보내지 않는다', () => {
  assert.ok(shouldDeliverReminder({ progress: 0, remindAt: NOW - 1000, now: NOW }));
  assert.ok(!shouldDeliverReminder({ progress: 100, remindAt: NOW - 1000, now: NOW }));
  assert.ok(!shouldDeliverReminder({ progress: 50, remindAt: NOW - 25 * 3600 * 1000, now: NOW }));
});

test('parseTodoListQuery: 기본값·scope·limit·offset 검사', () => {
  assert.ok(parseTodoListQuery({}).error);
  const d = parseTodoListQuery({ teamId: U1 });
  assert.equal(d.scope, 'mine');
  assert.equal(d.includeDone, true);
  assert.equal(d.sort, 'due');
  assert.equal(d.limit, 30);
  assert.equal(d.offset, 0);
  assert.equal(parseTodoListQuery({ teamId: U1, scope: 'team', includeDone: 'false', limit: '9999', offset: '30' }).limit, 100);
  assert.equal(parseTodoListQuery({ teamId: U1, includeDone: 'false' }).includeDone, false);
  assert.ok(parseTodoListQuery({ teamId: U1, scope: 'all' }).error);
  assert.ok(parseTodoListQuery({ teamId: U1, includeDone: 'maybe' }).error);
  assert.ok(parseTodoListQuery({ teamId: U1, limit: '0' }).error);
  assert.ok(parseTodoListQuery({ teamId: U1, offset: '-1' }).error);
});
