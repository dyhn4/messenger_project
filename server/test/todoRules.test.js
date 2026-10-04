// 할 일(To-Do) 순수 규칙 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import jwt from 'jsonwebtoken';
import {
  aggregateProgress,
  aggregateResync,
  checkDateOrder,
  checkPeriod,
  diffAssignees,
  isValidDateString,
  isValidProgress,
  isValidTimeString,
  mergeTodoPeriod,
  myProgressOf,
  nearestProgressStep,
  newlyAssigned,
  nextCompletedAt,
  orphanedProgress,
  parseAttachments,
  parseFolderPath,
  parseTodoCreate,
  parseTodoListQuery,
  parseTodoPatch,
  parseTodoRange,
  patchDenial,
  planReminders,
  progressPerspective,
  progressResync,
  progressTarget,
  pushTargets,
  reminderTargets,
  shouldDeliverReminder,
  sourceFilePaths,
  statusOf,
  storedAttachmentPaths,
  todoCardMessage,
  todoPermissions,
  todoRole,
  todoRoomError,
  toSharedTodoDto,
  TODO_ATTACHMENTS_MAX,
  TODO_PROGRESS_DENIED,
  TODO_REMINDERS_MAX,
} from '../src/todoRules.js';
import { resolveRawUrl, signFileUrl } from '../src/upload.js';

const U1 = '11111111-1111-4111-8111-111111111111';
const U2 = '22222222-2222-4222-8222-222222222222';
const U3 = '33333333-3333-4333-8333-333333333333';
const U4 = '44444444-4444-4444-8444-444444444444';
const NOW = 1_800_000_000_000;
const BAD_LINK = '사용할 수 없는 첨부 링크가 있습니다. 파일을 다시 올려 주세요.';

/** 서버가 [hours]시간 전에 내려 줬을 서명 링크 — 그때의 시계로 signFileUrl이 서명한 것(최대 2시간이라 이미 만료). */
function signedHoursAgo(path, hours, downloadName) {
  const issuedAt = Date.now() - hours * 60 * 60 * 1000;
  const clock = mock.method(Date, 'now', () => issuedAt);
  try {
    return signFileUrl(path, downloadName);
  } finally {
    clock.mock.restore();
  }
}

/** 만든 사람(U1)이 아닌 담당자들 [{ userId, progress }] — 진척률만 차례로. */
const others = (...progresses) => progresses.map((progress, i) => ({ userId: [U2, U3, U4][i], progress }));

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

test('isValidTimeString: HH:mm 24시간 00:00~23:59만', () => {
  for (const ok of ['00:00', '09:05', '12:30', '23:59']) assert.ok(isValidTimeString(ok), ok);
  for (const bad of ['24:00', '9:00', '09:60', '0900', '09:00:00', '', null, 900]) {
    assert.ok(!isValidTimeString(bad), String(bad));
  }
});

test('checkPeriod: 시간은 날짜와 함께, 시작은 종료보다 늦을 수 없음(없는 시간은 시작 00:00 / 종료 23:59)', () => {
  assert.equal(checkPeriod({}), null);
  assert.ok(checkPeriod({ startTime: '09:00' }));
  assert.ok(checkPeriod({ dueTime: '18:00', startDate: '2026-10-01' }));
  assert.equal(checkPeriod({ startDate: '2026-10-01', startTime: '09:00' }), null);
  assert.equal(checkPeriod({ dueDate: '2026-10-01', dueTime: '00:00' }), null);
  // 같은 날 — 시간으로 비교.
  const day = '2026-10-01';
  assert.equal(checkPeriod({ startDate: day, startTime: '09:00', dueDate: day, dueTime: '09:00' }), null);
  assert.equal(checkPeriod({ startDate: day, startTime: '09:00', dueDate: day, dueTime: '18:00' }), null);
  assert.ok(checkPeriod({ startDate: day, startTime: '18:00', dueDate: day, dueTime: '09:00' }));
  // 한쪽 시간이 없으면 날짜만 비교한 것과 같다.
  assert.equal(checkPeriod({ startDate: day, startTime: '23:59', dueDate: day }), null);
  assert.equal(checkPeriod({ startDate: day, dueDate: day, dueTime: '00:00' }), null);
  // 다른 날 — 날짜가 앞서면 시간은 상관없음, 날짜가 뒤면 거절.
  assert.equal(checkPeriod({ startDate: day, startTime: '23:00', dueDate: '2026-10-02', dueTime: '01:00' }), null);
  assert.equal(
    checkPeriod({ startDate: '2026-10-02', startTime: '00:00', dueDate: day, dueTime: '23:59' }),
    '시작일은 종료일보다 늦을 수 없습니다.',
  );
});

test('parseTodoCreate: 시작/종료 시간 — 형식·날짜 없는 시간·순서', () => {
  const ok = parseTodoCreate(
    { title: 't', startDate: '2026-10-01', startTime: '15:00', dueDate: '2026-10-02', dueTime: '18:00' },
    NOW,
  );
  assert.equal(ok.startTime, '15:00');
  assert.equal(ok.dueTime, '18:00');
  const none = parseTodoCreate({ title: 't', startDate: '2026-10-01', startTime: null }, NOW);
  assert.equal(none.startTime, null);
  assert.equal(none.dueTime, null);
  assert.ok(parseTodoCreate({ title: 't', startDate: '2026-10-01', startTime: '25:00' }, NOW).error);
  assert.ok(parseTodoCreate({ title: 't', startTime: '09:00' }, NOW).error);
  assert.ok(parseTodoCreate({ title: 't', startDate: '2026-10-01', dueTime: '09:00' }, NOW).error);
  const day = '2026-10-01';
  assert.ok(parseTodoCreate({ title: 't', startDate: day, startTime: '18:00', dueDate: day, dueTime: '09:00' }, NOW).error);
});

test('parseTodoPatch: startTime/dueTime은 형식만 보고 보낸 것만 담는다(null은 지우기)', () => {
  assert.deepEqual(parseTodoPatch({ startTime: '09:30' }).fields, { startTime: '09:30' });
  assert.deepEqual(parseTodoPatch({ dueTime: null }).fields, { dueTime: null });
  assert.ok(parseTodoPatch({ dueTime: '9:30' }).error);
});

test('mergeTodoPeriod: 안 보낸 쪽은 저장된 값, 날짜를 지우면 그 시간도 지움, 날짜 없는 시간·순서는 거절', () => {
  const stored = { startDate: '2026-10-01', startTime: '09:00', dueDate: '2026-10-02', dueTime: '18:00' };
  // 시간만 바꾸기.
  let r = mergeTodoPeriod(stored, { dueTime: '20:00' });
  assert.deepEqual(r.value, { ...stored, dueTime: '20:00' });
  assert.deepEqual(r.columns, { dueTime: '20:00' });
  // 날짜만 바꾸면 시간은 그대로(컬럼에도 안 들어감).
  r = mergeTodoPeriod(stored, { dueDate: '2026-10-05' });
  assert.equal(r.value.dueTime, '18:00');
  assert.deepEqual(r.columns, { dueDate: '2026-10-05' });
  // 날짜를 지우면 시간도 지운다.
  r = mergeTodoPeriod(stored, { startDate: null });
  assert.equal(r.value.startTime, null);
  assert.deepEqual(r.columns, { startDate: null, startTime: null });
  r = mergeTodoPeriod(stored, { startDate: null, dueDate: null });
  assert.deepEqual(r.columns, { startDate: null, startTime: null, dueDate: null, dueTime: null });
  // 날짜를 지우면서 시간을 주면 거절, 날짜가 없는 할 일에 시간만 주면 거절.
  assert.ok(mergeTodoPeriod(stored, { startDate: null, startTime: '09:00' }).error);
  assert.ok(mergeTodoPeriod({ startDate: null, dueDate: null }, { dueTime: '09:00' }).error);
  // 저장된 쪽과 합쳐 순서를 본다 — 같은 날로 당기면 시간으로.
  assert.ok(mergeTodoPeriod(stored, { dueDate: '2026-10-01', dueTime: '08:00' }).error);
  assert.ok(mergeTodoPeriod(stored, { dueDate: '2026-10-01' }).value);
  assert.ok(mergeTodoPeriod({ ...stored, dueDate: '2026-10-01', dueTime: null }, { startTime: '23:59' }).value);
  // 시간 칸이 없던 예전 행(undefined)도 null로.
  r = mergeTodoPeriod({ startDate: '2026-10-01', dueDate: null }, { title: 'x' });
  assert.deepEqual(r.value, { startDate: '2026-10-01', startTime: null, dueDate: null, dueTime: null });
  assert.deepEqual(r.columns, {});
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
  assert.equal(parseAttachments([{ kind: 'file', fileUrl: stored }], [stored]).value[0].fileUrl, stored);
  const expired = signedHoursAgo(stored, 3, 'old.pdf');
  assert.equal(resolveRawUrl(expired), null); // 정말 만료된 링크.
  assert.equal(parseAttachments([{ kind: 'file', fileUrl: expired }]).error, BAD_LINK);
  assert.equal(parseAttachments([{ kind: 'file', fileUrl: expired }], [stored]).value[0].fileUrl, stored);
});

test('parseAttachments: 만료 링크는 알고 있는 경로일 때만 — 다른 파일·위조 서명은 거절, 미리보기는 조용히 뺌', () => {
  const stored = '/uploads/src.png';
  const thumb = '/uploads/src_thumb.jpg';
  const expired = signedHoursAgo(stored, 5, 'src.png');
  // 다른 파일의 만료 링크는 그대로 거절.
  assert.equal(parseAttachments([{ kind: 'file', fileUrl: signedHoursAgo('/uploads/other.pdf', 5) }], [stored]).error, BAD_LINK);
  // 서명이 틀린(위조) 링크는 경로가 같아도 거절.
  const exp = Math.floor(Date.now() / 1000) + 3600;
  const forged = `/files/${jwt.sign({ file: 'src.png', type: 'file', exp }, 'not-the-server-secret', { noTimestamp: true })}`;
  assert.equal(parseAttachments([{ kind: 'image', fileUrl: forged }], [stored]).error, BAD_LINK);
  // 축소 미리보기도 같은 규칙 — 알고 있으면 원본 경로로, 모르는 만료 링크면 원본만 남기고 미리보기는 null.
  const withThumb = [{ kind: 'image', fileUrl: expired, thumbnailUrl: signedHoursAgo(thumb, 5) }];
  assert.deepEqual(
    parseAttachments(withThumb, [stored, thumb]).value.map((a) => [a.fileUrl, a.thumbnailUrl]),
    [[stored, thumb]],
  );
  assert.deepEqual(parseAttachments(withThumb, [stored]).value.map((a) => [a.fileUrl, a.thumbnailUrl]), [[stored, null]]);
});

test('parseTodoCreate: 출처 글의 파일이면 만료된 첨부 링크도 받고, 아니면 거절', () => {
  const path = '/uploads/msg-a.png';
  const body = { title: '오래된 메시지', attachments: [{ kind: 'image', fileUrl: signedHoursAgo(path, 26, 'a.png') }] };
  assert.equal(parseTodoCreate(body, NOW).error, BAD_LINK);
  assert.deepEqual(parseTodoCreate(body, NOW, [path]).attachments.map((a) => a.fileUrl), [path]);
  assert.equal(parseTodoCreate(body, NOW, ['/uploads/msg-b.png']).error, BAD_LINK);
  // 지금 막 받은(만료 전) 링크는 출처와 무관하게 예전처럼 받는다.
  const fresh = { title: 't', attachments: [{ kind: 'file', fileUrl: signFileUrl('/uploads/new.pdf', 'new.pdf') }] };
  assert.equal(parseTodoCreate(fresh, NOW).attachments[0].fileUrl, '/uploads/new.pdf');
});

test('sourceFilePaths: 출처 글에 지금 붙어 있는 파일 — 메시지 첨부 행·옛 방식 칸 / 댓글은 자기 칸만, 지운 파일 제외', () => {
  const message = { fileUrl: '/uploads/m1.png', thumbnailUrl: '/uploads/m1_t.jpg', fileDeletedAt: null };
  const attachments = [
    { fileUrl: '/uploads/m1.png', thumbnailUrl: '/uploads/m1_t.jpg', deletedAt: null },
    { fileUrl: '/uploads/m2.pdf', thumbnailUrl: null, deletedAt: null },
    { fileUrl: '/uploads/m3.pdf', thumbnailUrl: null, deletedAt: new Date(1000) },
  ];
  // 첨부 행(지운 m3 제외) + 메시지의 파일 칸(첫 첨부와 같아 중복 없이).
  assert.deepEqual(sourceFilePaths({ message, attachments }), ['/uploads/m1.png', '/uploads/m1_t.jpg', '/uploads/m2.pdf']);
  // 옛 방식(첨부 행 없음) 메시지는 파일 칸 하나, 그 파일을 지웠으면 없음.
  assert.deepEqual(sourceFilePaths({ message: { fileUrl: '/uploads/old.pdf', thumbnailUrl: null } }), ['/uploads/old.pdf']);
  assert.deepEqual(sourceFilePaths({ message: { fileUrl: '/uploads/old.pdf', fileDeletedAt: new Date(1000) } }), []);
  // 댓글이면 부모 메시지의 파일은 빼고 그 댓글의 파일 칸만.
  const comment = { fileUrl: '/uploads/c.jpg', thumbnailUrl: '/uploads/c_t.jpg' };
  assert.deepEqual(sourceFilePaths({ comment, message, attachments }), ['/uploads/c.jpg', '/uploads/c_t.jpg']);
  // 글만 있는 메시지·댓글, 저장 경로가 아닌 값은 빠진다.
  assert.deepEqual(sourceFilePaths({ message: { fileUrl: null, thumbnailUrl: null } }), []);
  assert.deepEqual(sourceFilePaths({ comment: { fileUrl: null } }), []);
  assert.deepEqual(sourceFilePaths({ message: { fileUrl: 'https://evil.example/x.png', thumbnailUrl: '/files/abc' } }), []);
  assert.deepEqual(sourceFilePaths(), []);
});

test('storedAttachmentPaths: 수정 때의 known 목록 — 저장된 첨부 행의 원본·미리보기(중복·빈 칸·저장 경로 아닌 값 없이)', () => {
  const rows = [
    { fileUrl: '/uploads/p.png', thumbnailUrl: '/uploads/p_t.jpg' },
    { fileUrl: '/uploads/doc.pdf', thumbnailUrl: null },
    { fileUrl: '/uploads/p.png', thumbnailUrl: '/uploads/p_t.jpg' }, // 같은 파일을 두 번 붙인 경우.
  ];
  assert.deepEqual(storedAttachmentPaths(rows), ['/uploads/p.png', '/uploads/p_t.jpg', '/uploads/doc.pdf']);
  assert.deepEqual(storedAttachmentPaths([{ fileUrl: 'https://evil.example/x.png', thumbnailUrl: '/files/abc' }]), []);
  assert.deepEqual(storedAttachmentPaths([]), []);
  assert.deepEqual(storedAttachmentPaths(), []);
});

test('parseAttachments (S2): 수정 때 만료된 링크로 돌려보낸 기존 사진은 미리보기까지 유지, 이 할 일의 것이 아니면 예전대로', () => {
  const stored = [{ fileUrl: '/uploads/p.png', thumbnailUrl: '/uploads/p_t.jpg' }];
  // 패널을 몇 시간 열어 둔 화면이 기존 사진(원본·미리보기 모두 만료된 링크)에 새로 올린 파일(업로드 결과 — 원본 경로)을 더해 보냄.
  const body = [
    {
      kind: 'image',
      fileUrl: signedHoursAgo('/uploads/p.png', 3, 'p.png'),
      fileName: 'p.png',
      thumbnailUrl: signedHoursAgo('/uploads/p_t.jpg', 3),
    },
    { kind: 'file', fileUrl: '/uploads/new.pdf', fileName: 'new.pdf' },
  ];
  assert.deepEqual(
    parseAttachments(body, storedAttachmentPaths(stored)).value.map((a) => [a.fileUrl, a.thumbnailUrl]),
    [
      ['/uploads/p.png', '/uploads/p_t.jpg'],
      ['/uploads/new.pdf', null],
    ],
  );
  // 예전 목록(원본만)으로는 미리보기가 오류 없이 null로 저장되던 경우.
  assert.equal(parseAttachments(body, stored.map((a) => a.fileUrl)).value[0].thumbnailUrl, null);
  // 이 할 일에 저장되지 않은 미리보기의 만료 링크는 그대로 null, 저장되지 않은 파일의 만료 링크(원본)는 그대로 거절.
  const foreignThumb = [{ kind: 'image', fileUrl: body[0].fileUrl, thumbnailUrl: signedHoursAgo('/uploads/q_t.jpg', 3) }];
  assert.deepEqual(
    parseAttachments(foreignThumb, storedAttachmentPaths(stored)).value.map((a) => [a.fileUrl, a.thumbnailUrl]),
    [['/uploads/p.png', null]],
  );
  const foreignFile = [{ kind: 'file', fileUrl: signedHoursAgo('/uploads/q.pdf', 3, 'q.pdf') }];
  assert.equal(parseAttachments(foreignFile, storedAttachmentPaths(stored)).error, BAD_LINK);
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

test('parseTodoPatch: 진척률은 0·25·50·75·100만(잔디 대기/진행 25·50·75%/완료)', () => {
  for (const p of [0, 25, 50, 75, 100]) assert.equal(parseTodoPatch({ progress: p }).fields.progress, p);
  for (const p of [30, 1, 99, -25, 125, '50', null]) {
    assert.equal(parseTodoPatch({ progress: p }).error, '진척률은 0·25·50·75·100 중 하나여야 합니다.');
  }
});

test('isValidProgress: 고를 수 있는 값만', () => {
  assert.ok(isValidProgress(0));
  assert.ok(isValidProgress(75));
  assert.ok(isValidProgress(100));
  assert.ok(!isValidProgress(30));
  assert.ok(!isValidProgress(50.0001));
  assert.ok(!isValidProgress('25'));
  assert.ok(!isValidProgress(undefined));
});

test('todoRoomError: 비밀 대화·보드 뷰 토픽은 거절, 챗 뷰 토픽·그룹·1:1·나와의 대화는 통과', () => {
  assert.equal(todoRoomError({ type: 'dm', isSecret: true }), '비밀 대화에서는 할 일을 만들 수 없습니다.');
  assert.equal(
    todoRoomError({ type: 'topic', isSecret: false, viewMode: 'board' }),
    '보드 뷰 토픽에서는 할 일을 만들 수 없습니다.',
  );
  assert.equal(todoRoomError({ type: 'topic', isSecret: false, viewMode: 'chat' }), null);
  assert.equal(todoRoomError({ type: 'group', isSecret: false, viewMode: 'chat' }), null);
  assert.equal(todoRoomError({ type: 'dm', isSecret: false, isSelf: true, viewMode: 'chat' }), null);
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
  assert.equal(patchDenial('assignee', U1, ['title', 'progress', 'reminders', 'attachments'], 'assignee'), null);
  assert.equal(patchDenial('assignee', U1, ['assigneeIds']).status, 403);
  assert.equal(patchDenial('viewer', U1, ['title']).status, 403);
});

test('patchDenial: progress는 역할이 아니라 진척률 대상(progressTarget)으로 본다', () => {
  const progressOnly = '담당자만 진척률을 바꿀 수 있습니다.';
  // 요청 앞 검사와 잠근 뒤의 다시 판단(updateTodo)이 같은 문구를 쓴다.
  assert.equal(TODO_PROGRESS_DENIED, progressOnly);
  // 담당자가 아닌 만든 사람 — 다른 필드는 되지만 진척률은 403(요청 전체 거절).
  assert.equal(patchDenial('creator', U1, ['progress'], null).error, progressOnly);
  assert.equal(patchDenial('creator', U1, ['title', 'progress'], null).error, progressOnly);
  assert.equal(patchDenial('creator', U1, ['title'], null), null);
  // 담당자 없는 할 일의 만든 사람·담당자 본인은 된다.
  assert.equal(patchDenial('creator', U1, ['progress'], 'todo'), null);
  assert.equal(patchDenial('assignee', U1, ['progress'], 'assignee'), null);
  // 보기만 하는 사람: 진척률만 보내면 진척률 문구, 다른 필드가 섞이면 수정 권한 문구.
  assert.equal(patchDenial('viewer', U1, ['progress'], null).error, progressOnly);
  assert.equal(patchDenial('viewer', U1, ['title', 'progress'], null).error, '이 할 일을 수정할 권한이 없습니다.');
  // 담당자는 진척률과 함께 보내도 담당자 목록은 못 바꾼다.
  assert.equal(
    patchDenial('assignee', U1, ['assigneeIds', 'progress'], 'assignee').error,
    '담당자는 담당자 목록을 바꿀 수 없습니다.',
  );
});

test('progressTarget / myProgressOf: 담당자는 자기 행, 담당자 없는 할 일은 만든 사람, 그 밖은 없음', () => {
  assert.equal(progressTarget({ creatorId: U1, assigneeIds: [U2, U3], userId: U2 }), 'assignee');
  // 만든 사람이 담당자이기도 하면 자기 담당 행.
  assert.equal(progressTarget({ creatorId: U1, assigneeIds: [U1, U2], userId: U1 }), 'assignee');
  // 만든 사람이라도 담당자가 아니면 못 바꾼다.
  assert.equal(progressTarget({ creatorId: U1, assigneeIds: [U2], userId: U1 }), null);
  assert.equal(progressTarget({ creatorId: U1, assigneeIds: [], userId: U1 }), 'todo');
  assert.equal(progressTarget({ creatorId: U1, assigneeIds: [], userId: U2 }), null);
  assert.equal(progressTarget({ creatorId: null, assigneeIds: [], userId: U2 }), null);
  assert.equal(progressTarget({ creatorId: U1, assigneeIds: [U2], userId: U3 }), null);

  const assignees = [
    { userId: U2, progress: 75 },
    { userId: U3, progress: 0 },
  ];
  assert.equal(myProgressOf({ creatorId: U1, assignees, progress: 38, userId: U2 }), 75);
  assert.equal(myProgressOf({ creatorId: U1, assignees, progress: 38, userId: U3 }), 0);
  assert.equal(myProgressOf({ creatorId: U1, assignees, progress: 38, userId: U1 }), null);
  assert.equal(myProgressOf({ creatorId: U1, assignees: [], progress: 50, userId: U1 }), 50);
  assert.equal(myProgressOf({ creatorId: U1, assignees: [], progress: 50, userId: U2 }), null);
});

test('nextCompletedAt: 100이면 기록(이미 있으면 유지), 아래로 내리면 해제', () => {
  const t0 = new Date(1000);
  const t1 = new Date(2000);
  assert.equal(nextCompletedAt(100, null, t1), t1);
  assert.equal(nextCompletedAt(100, t0, t1), t0);
  assert.equal(nextCompletedAt(99, t0, t1), null);
  assert.equal(nextCompletedAt(0, null, t1), null);
});

test('aggregateProgress: 모두 100 → 100, 모두 0 → 0, 그 밖은 평균 반올림을 1~99로', () => {
  assert.equal(aggregateProgress([]), null);
  assert.equal(aggregateProgress([100]), 100);
  assert.equal(aggregateProgress([100, 100, 100]), 100);
  assert.equal(aggregateProgress([0]), 0);
  assert.equal(aggregateProgress([0, 0]), 0);
  assert.equal(aggregateProgress([50]), 50);
  assert.equal(aggregateProgress([100, 0]), 50);
  assert.equal(aggregateProgress([100, 75, 100]), 92); // 91.67 → 92
  assert.equal(aggregateProgress([25, 50]), 38); // 37.5 → 38
  // 한 명이라도 시작했으면 0이 아니고(최소 1), 한 명이라도 남았으면 100이 아니다(최대 99).
  assert.equal(aggregateProgress([25, ...Array(29).fill(0)]), 1);
  assert.equal(aggregateProgress([75, ...Array(29).fill(100)]), 99);
  // 예전 데이터처럼 단계 밖 값이 섞여 평균이 0·100으로 반올림돼도 1~99로 자른다.
  assert.equal(aggregateProgress([1, 0, 0]), 1);
  assert.equal(aggregateProgress([99, 100]), 99);
});

test('aggregateResync: 방에 있는 담당자로 다시 맞출 값 — 담당자가 없거나 이미 맞으면 null', () => {
  const t0 = new Date(1000);
  const now = new Date(5000);
  // 담당자가 (방에) 하나도 없으면 만든 사람이 바꾸는 값이라 그대로.
  assert.equal(aggregateResync({ progress: 50, completedAt: null }, [], now), null);
  // 이미 맞으면 쓸 것 없음 — 완료 시각도 처음 값 그대로면 같은 것으로 본다(Date·ms 어느 쪽이든).
  assert.equal(aggregateResync({ progress: 25, completedAt: null }, [50, 0], now), null);
  assert.equal(aggregateResync({ progress: 100, completedAt: t0 }, [100, 100], now), null);
  assert.equal(aggregateResync({ progress: 100, completedAt: 1000 }, [100], now), null);
  // 덜 한 담당자가 방을 나가면: (100, 0) 집계 50 → 남은 (100)으로 완료, 완료 시각은 지금.
  assert.deepEqual(aggregateResync({ progress: 50, completedAt: null }, [100], now), { progress: 100, completedAt: now });
  // 다 한 담당자가 나가면: 남은 사람 0 → 대기(25/50/75 단계에 없는 50이 남지 않게).
  assert.deepEqual(aggregateResync({ progress: 50, completedAt: null }, [0], now), { progress: 0, completedAt: null });
  // 나간 사람이 다시 들어오면(남아 있던 0이 다시 집계에) 완료가 풀린다.
  assert.deepEqual(aggregateResync({ progress: 100, completedAt: t0 }, [100, 0], now), { progress: 50, completedAt: null });
  // 집계는 100인데 완료 시각이 비어 있던 행(예전 데이터)은 지금으로 채운다.
  assert.deepEqual(aggregateResync({ progress: 100, completedAt: null }, [100], now), { progress: 100, completedAt: now });
  // 만든 사람이 직접 써 둔 값이 남아 있어도(담당자 0) 담당자 기준으로 되돌린다.
  assert.deepEqual(aggregateResync({ progress: 100, completedAt: t0 }, [0], now), { progress: 0, completedAt: null });
});

test('nearestProgressStep: 가장 가까운 단계(0·25·50·75·100), 한가운데는 올림', () => {
  const cases = [
    [0, 0],
    [1, 0],
    [12, 0],
    [12.5, 25],
    [13, 25],
    [25, 25],
    [37, 25],
    [37.5, 50],
    [38, 50],
    [62, 50],
    [62.5, 75],
    [67, 75],
    [87, 75],
    [87.5, 100],
    [88, 100],
    [99, 100],
    [100, 100],
    [-5, 0],
    [130, 100],
  ];
  for (const [value, step] of cases) assert.equal(nearestProgressStep(value), step, `${value} → ${step}`);
});

test('orphanedProgress (S3): 만든 사람도 담당자였으면 그 사람의 진척률, 아니면 직전 집계를 가장 가까운 단계로', () => {
  // 만든 사람(U1)도 담당자였으면 집계((25, 100) → 63 → 75)가 아니라 만든 사람 자신의 값.
  assert.equal(orphanedProgress({ creatorId: U1, before: [{ userId: U1, progress: 25 }, ...others(100)] }), 25);
  assert.equal(orphanedProgress({ creatorId: U1, before: [...others(100, 100), { userId: U1, progress: 0 }] }), 0);
  assert.equal(orphanedProgress({ creatorId: U1, before: [{ userId: U1, progress: 100 }, ...others(0)] }), 100);
  // 만든 사람이 담당자가 아니었으면 직전 집계를 단계로 — (75, 0) 38 → 50, (100, 75) 88 → 100, (25, 0) 13 → 25,
  // (25, 0, 0) 8 → 0, (100, 100, 75) 92 → 100, 이미 단계인 집계는 그대로.
  assert.equal(orphanedProgress({ creatorId: U1, before: others(75, 0) }), 50);
  assert.equal(orphanedProgress({ creatorId: U1, before: others(100, 75) }), 100);
  assert.equal(orphanedProgress({ creatorId: U1, before: others(25, 0) }), 25);
  assert.equal(orphanedProgress({ creatorId: U1, before: others(25, 0, 0) }), 0);
  assert.equal(orphanedProgress({ creatorId: U1, before: others(100, 100, 75) }), 100);
  assert.equal(orphanedProgress({ creatorId: U1, before: others(50, 50) }), 50);
  // 만든 사람 계정이 없어진(탈퇴) 할 일도 직전 집계로.
  assert.equal(orphanedProgress({ creatorId: null, before: others(75, 0) }), 50);
});

test('progressResync: 담당자가 남아 있으면 집계, 마지막 담당자가 빠지면 S3 값, 원래 없었으면 그대로', () => {
  const t0 = new Date(1000);
  const now = new Date(5000);
  const todo = (progress, completedAt = null) => ({ progress, completedAt, creatorId: U1 });
  // 그 방에 남은 담당자가 있으면 aggregateResync와 같다(before는 보지 않는다).
  assert.deepEqual(progressResync(todo(38), { before: others(75, 0), after: others(100) }, now), {
    progress: 100,
    completedAt: now,
  });
  assert.equal(progressResync(todo(25), { after: others(50, 0) }, now), null);
  // 원래 담당자가 없던 할 일(before를 모르거나 빈 목록)은 만든 사람이 바꾸는 값 그대로 — 단계 밖 값이어도 손대지 않는다.
  assert.equal(progressResync(todo(38), { after: [] }, now), null);
  assert.equal(progressResync(todo(38), { before: [], after: [] }, now), null);
  // 마지막 담당자가 빠짐: 만든 사람이 아닌 담당자들만 있었으면 직전 집계를 단계로(38 → 50, 완료 아님).
  assert.deepEqual(progressResync(todo(38), { before: others(75, 0), after: [] }, now), { progress: 50, completedAt: null });
  // 88 → 100이면 완료 — 완료 시각은 지금.
  assert.deepEqual(progressResync(todo(88), { before: others(100, 75), after: [] }, now), { progress: 100, completedAt: now });
  // 이미 완료(모두 100)였으면 100 그대로·완료 시각도 처음 값 그대로라 쓸 것 없음.
  assert.equal(progressResync(todo(100, t0), { before: others(100, 100), after: [] }, now), null);
  // 만든 사람도 담당자였으면 그 사람의 진척률 — 집계 63인 할 일이 25로(75가 아니라), 100이면 완료 시각 기록.
  const creator = (progress) => ({ userId: U1, progress });
  assert.deepEqual(progressResync(todo(63), { before: [creator(25), ...others(100)], after: [] }, now), {
    progress: 25,
    completedAt: null,
  });
  assert.deepEqual(progressResync(todo(50), { before: [creator(100), ...others(0)], after: [] }, now), {
    progress: 100,
    completedAt: now,
  });
  // 저장된 값이 무엇이었든(예: 예전 서버가 써 둔 완료) 만든 사람의 진척률(0)을 이어받으면 완료가 풀린다.
  assert.deepEqual(progressResync(todo(100, t0), { before: [creator(0)], after: [] }, now), { progress: 0, completedAt: null });
  // 이어받을 값이 이미 저장된 값이면 쓸 것 없음.
  assert.equal(progressResync(todo(50), { before: others(50), after: [] }, now), null);
});

test('diffAssignees: 빠진 사람·새 사람만 골라내고 남는 사람은 그대로', () => {
  assert.deepEqual(diffAssignees([U1, U2], [U2, U3]), { removed: [U1], added: [U3], kept: [U2] });
  assert.deepEqual(diffAssignees([], [U1]), { removed: [], added: [U1], kept: [] });
  assert.deepEqual(diffAssignees([U1, U2], []), { removed: [U1, U2], added: [], kept: [] });
  assert.deepEqual(diffAssignees([U1, U2], [U2, U1]), { removed: [], added: [], kept: [U2, U1] });
  assert.deepEqual(diffAssignees([U1], [U1, U1]), { removed: [], added: [], kept: [U1] });
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
  assert.deepEqual(
    reminderTargets(
      [
        { userId: U2, progress: 0 },
        { userId: U3, progress: 50 },
      ],
      U1,
    ),
    [U2, U3],
  );
  assert.deepEqual(reminderTargets([], U1), [U1]);
  assert.deepEqual(reminderTargets([], null), []);
});

test('reminderTargets: 이미 다 한(100) 담당자는 빼고, 담당자가 있으면 만든 사람에게는 안 보낸다', () => {
  const assignees = [
    { userId: U2, progress: 100 },
    { userId: U3, progress: 75 },
  ];
  assert.deepEqual(reminderTargets(assignees, U1), [U3]);
  assert.deepEqual(reminderTargets([{ userId: U2, progress: 100 }], U1), []);
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

test('parseTodoListQuery: assigneeId는 uuid만(어떤 scope에도), 없으면 null', () => {
  const d = parseTodoListQuery({ teamId: U1 });
  assert.equal(d.assigneeId, null);
  assert.equal(d.from, null);
  assert.equal(d.to, null);
  assert.equal(parseTodoListQuery({ teamId: U1, scope: 'assigned_by_me', assigneeId: U2 }).assigneeId, U2);
  assert.equal(parseTodoListQuery({ teamId: U1, scope: 'mine', assigneeId: U2.toUpperCase() }).assigneeId, U2);
  assert.equal(parseTodoListQuery({ teamId: U1, assigneeId: '' }).assigneeId, null);
  assert.equal(parseTodoListQuery({ teamId: U1, assigneeId: 'nobody' }).error, 'assigneeId가 올바르지 않습니다.');
  assert.ok(parseTodoListQuery({ teamId: U1, assigneeId: [U2, U3] }).error);
});

test('parseTodoListQuery: from/to가 있으면 limit 최대 500, 없으면 100', () => {
  const ranged = parseTodoListQuery({ teamId: U1, from: '2026-09-27', to: '2026-11-07', limit: '9999' });
  assert.equal(ranged.from, '2026-09-27');
  assert.equal(ranged.to, '2026-11-07');
  assert.equal(ranged.limit, 500);
  assert.equal(parseTodoListQuery({ teamId: U1, from: '2026-09-27', to: '2026-11-07' }).limit, 30);
  assert.equal(parseTodoListQuery({ teamId: U1, limit: '500' }).limit, 100);
  assert.ok(parseTodoListQuery({ teamId: U1, from: '2026-09-27' }).error);
  assert.ok(parseTodoListQuery({ teamId: U1, from: '2026-01-01', to: '2026-12-31' }).error);
});

test('parseTodoRange: 둘 다 주거나 둘 다 빼기, from ≤ to, 양 끝 포함 최대 100일', () => {
  assert.deepEqual(parseTodoRange(undefined, undefined), { value: null });
  assert.deepEqual(parseTodoRange('', ''), { value: null });
  assert.equal(parseTodoRange('2026-10-01', undefined).error, 'from과 to는 함께 보내야 합니다.');
  assert.equal(parseTodoRange(undefined, '2026-10-01').error, 'from과 to는 함께 보내야 합니다.');
  assert.ok(parseTodoRange('2026/10/01', '2026-10-02').error);
  assert.ok(parseTodoRange('2026-02-30', '2026-03-02').error);
  assert.ok(parseTodoRange(['2026-10-01'], '2026-10-02').error);
  assert.equal(parseTodoRange('2026-10-02', '2026-10-01').error, '기간의 시작일은 종료일보다 늦을 수 없습니다.');
  assert.deepEqual(parseTodoRange('2026-10-01', '2026-10-01'), { value: { from: '2026-10-01', to: '2026-10-01' } });
  // 2026-01-01 ~ 2026-04-10은 양 끝 포함 100일, 하루 더 늘리면 101일.
  assert.deepEqual(parseTodoRange('2026-01-01', '2026-04-10').value, { from: '2026-01-01', to: '2026-04-10' });
  assert.equal(parseTodoRange('2026-01-01', '2026-04-11').error, '기간은 최대 100일까지 조회할 수 있습니다.');
  // 달력 6주(42일) 범위·연말을 넘는 범위.
  assert.ok(parseTodoRange('2026-09-27', '2026-11-07').value);
  assert.ok(parseTodoRange('2026-12-27', '2027-02-06').value);
});

test('progressPerspective: assigneeId → 그 사람, 나의 할 일 → 나, 그 밖 → 집계(null)', () => {
  assert.equal(progressPerspective({ scope: 'mine', assigneeId: null, userId: U1 }), U1);
  assert.equal(progressPerspective({ scope: 'assigned_by_me', assigneeId: null, userId: U1 }), null);
  assert.equal(progressPerspective({ scope: 'team', assigneeId: null, userId: U1 }), null);
  assert.equal(progressPerspective({ scope: 'assigned_by_me', assigneeId: U2, userId: U1 }), U2);
  assert.equal(progressPerspective({ scope: 'mine', assigneeId: U3, userId: U1 }), U3);
  assert.equal(progressPerspective({ scope: 'team', assigneeId: U2, userId: U1 }), U2);
});

test('폴더 경로(파일 다운로드·업로드) — 빈 값은 지정 안 함, 한 줄 글자만, 만들기·수정 모두', () => {
  assert.deepEqual(parseFolderPath(undefined, '파일 업로드'), { value: null });
  assert.deepEqual(parseFolderPath('   ', '파일 업로드'), { value: null });
  const share = String.raw`\\nas\공유\보고서`;
  assert.deepEqual(parseFolderPath(`  ${share} `, '파일 업로드'), { value: share });
  assert.ok(parseFolderPath('C:/a\nb', '파일 업로드').error);
  assert.ok(parseFolderPath(3, '파일 업로드').error);
  assert.ok(parseFolderPath('C:/' + 'a'.repeat(1001), '파일 업로드').error);

  const local = String.raw`C:\자료`;
  const created = parseTodoCreate({ title: '보고서', downloadPath: local, uploadPath: '' });
  assert.equal(created.downloadPath, local);
  assert.equal(created.uploadPath, null);
  assert.equal(parseTodoCreate({ title: '보고서' }).downloadPath, null);

  const result = String.raw`\\nas\결과`;
  assert.deepEqual(parseTodoPatch({ uploadPath: result }).fields, { uploadPath: result });
  // null로 보내면 지운다.
  assert.deepEqual(parseTodoPatch({ downloadPath: null }).fields, { downloadPath: null });
  // 담당자도 고칠 수 있다(제목·설명과 같은 편집 권한).
  assert.equal(patchDenial('assignee', 'u-creator', ['downloadPath', 'uploadPath']), null);
  assert.ok(patchDenial('viewer', 'u-creator', ['uploadPath']));
});

test('할 일 카드 메시지 — 토픽·그룹이면 만든 사람을 뺀 담당자를 멘션하고, 구간은 글자와 맞는다', () => {
  const todo = { title: '견적서 보내기', description: '거래처 A', dueDate: '2026-10-10', dueTime: '18:00' };
  const assignees = [
    { id: 'me', name: '나' },
    { id: 'u2', name: '김철수' },
    { id: 'u3', name: '이영희' },
  ];
  const { text, mentions, card } = todoCardMessage({
    todo,
    assignees,
    creatorId: 'me',
    attachments: [{ kind: 'file', fileName: '견적.xlsx', fileUrl: '/uploads/x' }],
    roomCanMention: true,
  });
  assert.equal(text, '[할 일] 견적서 보내기\n담당: @김철수 @이영희');
  assert.deepEqual(
    mentions.map((m) => [m.userId, text.slice(m.s, m.e)]),
    [
      ['u2', '@김철수'],
      ['u3', '@이영희'],
    ],
  );
  assert.equal(card.title, '견적서 보내기');
  assert.equal(card.dueTime, '18:00');
  assert.deepEqual(card.attachments, [{ kind: 'file', fileName: '견적.xlsx' }]);
  assert.equal(card.attachmentCount, 1);
  assert.deepEqual(card.assigneeNames, ['나', '김철수', '이영희']);
});

test('할 일 카드 메시지 — 1:1·나와의 대화(멘션 못 하는 방)나 담당자가 나뿐이면 멘션 없이 제목만', () => {
  const todo = { title: '보고서' };
  const dm = todoCardMessage({ todo, assignees: [{ id: 'u2', name: '김철수' }], creatorId: 'me', roomCanMention: false });
  assert.equal(dm.text, '[할 일] 보고서');
  assert.deepEqual(dm.mentions, []);
  const selfOnly = todoCardMessage({ todo, assignees: [{ id: 'me', name: '나' }], creatorId: 'me', roomCanMention: true });
  assert.equal(selfOnly.text, '[할 일] 보고서');
  assert.deepEqual(selfOnly.mentions, []);
  // 긴 설명은 앞부분만.
  const long = todoCardMessage({ todo: { title: 't', description: 'a'.repeat(400) }, roomCanMention: false });
  assert.equal(long.card.description.length, 301);
});

test('메시지 DTO의 할 일 카드 — 할 일이 지워지면 id가 null, 지운 메시지·카드 없는 메시지는 null', () => {
  const card = { title: '보고서' };
  assert.deepEqual(toSharedTodoDto({ todoId: 't1', todoCard: card }), { title: '보고서', id: 't1' });
  assert.deepEqual(toSharedTodoDto({ todoId: null, todoCard: card }), { title: '보고서', id: null });
  assert.equal(toSharedTodoDto({ todoId: 't1', todoCard: card, deletedAt: new Date() }), null);
  assert.equal(toSharedTodoDto({ text: 'hi' }), null);
});
