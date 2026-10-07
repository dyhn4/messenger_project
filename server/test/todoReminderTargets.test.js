// 할 일 알림 대상(검토 S33) — `node --test test/todoReminderTargets.test.js` (DB·서버 없이 돈다). 담당자가 없어 만든
// 사람에게 넘어가는 알림은, 그 사람이 아직 그 할 일의 방·팀 멤버일 때만 보내야 한다 — 방에서 내보내지거나 팀에서 빠진 만든
// 사람에게 제목·기한이 담긴 알림이 가지 않게. reminderTargets의 순수 규칙과, 점검(sweepTodoReminders)이 그 규칙에 멤버십을
// 어떻게 넘기는지(담당자가 없을 때만 확인)를 작은 가짜로 본다.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { reminderTargets } from '../src/todoRules.js';

const U1 = '11111111-1111-4111-8111-111111111111'; // 만든 사람
const U2 = '22222222-2222-4222-8222-222222222222';
const U3 = '33333333-3333-4333-8333-333333333333';

test('담당자가 있으면 아직 안 끝낸 담당자들 — 만든 사람 멤버십은 보지 않는다', () => {
  const assignees = [
    { userId: U2, progress: 0 },
    { userId: U3, progress: 50 },
  ];
  assert.deepEqual(reminderTargets(assignees, U1, { creatorIsMember: false }), [U2, U3]);
  assert.deepEqual(reminderTargets(assignees, U1, { creatorIsMember: true }), [U2, U3]);
  // 다 끝낸(100) 담당자는 빠진다.
  assert.deepEqual(reminderTargets([{ userId: U2, progress: 100 }, { userId: U3, progress: 75 }], U1), [U3]);
  // 담당자가 다 끝냈으면 비어 있다(만든 사람에게 넘어가지 않는다 — 담당자가 "있는" 할 일이라).
  assert.deepEqual(reminderTargets([{ userId: U2, progress: 100 }], U1, { creatorIsMember: true }), []);
});

test('담당자가 없으면 만든 사람 — 멤버일 때만(S33)', () => {
  assert.deepEqual(reminderTargets([], U1, { creatorIsMember: true }), [U1]);
  assert.deepEqual(reminderTargets([], U1, { creatorIsMember: false }), []);
  assert.deepEqual(reminderTargets([], U1), []); // 기본값은 "확인 안 됨" — 안 보낸다(fail-closed).
  assert.deepEqual(reminderTargets([], null, { creatorIsMember: true }), []); // 만든 사람 계정이 사라졌으면 대상 없음.
});

// ── 점검의 멤버십 확인을 흉내 낸다(todos.js deliverTodoReminders와 같은 판단) ──────────────────────────
// 담당자가 없을 때만 방·팀 멤버십을 확인해 reminderTargets에 넘긴다. 이미 찜(sentAt)된 알림이라, 멤버가 아니라 건너뛰어도
// 다시 울리지 않는다(여기서는 "보냈는가"만 본다).
function decideTargets(todo, { assignees, isRoomMember, isTeamMember }) {
  let creatorIsMember = false;
  let membershipChecks = 0;
  if (assignees.length === 0 && todo.creatorId) {
    membershipChecks += 1;
    creatorIsMember = isRoomMember(todo.roomId, todo.creatorId) && isTeamMember(todo.teamId, todo.creatorId);
  }
  return { targets: reminderTargets(assignees, todo.creatorId, { creatorIsMember }), membershipChecks };
}

test('점검 — 내보내진 만든 사람에게는 안 보내고, 담당자가 있으면 멤버십을 묻지 않는다', () => {
  const todo = { creatorId: U1, roomId: 'room-1', teamId: 'team-1' };
  const member = { isRoomMember: () => true, isTeamMember: () => true };
  const notInRoom = { isRoomMember: () => false, isTeamMember: () => true };
  const notInTeam = { isRoomMember: () => true, isTeamMember: () => false };

  // 담당자 없음 + 만든 사람이 방·팀 멤버 → 보낸다(멤버십 1회 확인).
  let r = decideTargets(todo, { assignees: [], ...member });
  assert.deepEqual(r.targets, [U1]);
  assert.equal(r.membershipChecks, 1);

  // 방에서 내보내졌으면 안 보낸다.
  assert.deepEqual(decideTargets(todo, { assignees: [], ...notInRoom }).targets, []);
  // 팀에서 빠졌으면 안 보낸다.
  assert.deepEqual(decideTargets(todo, { assignees: [], ...notInTeam }).targets, []);

  // 담당자가 있으면 멤버십을 아예 묻지 않는다(묻는 함수가 던져도 괜찮게).
  const boom = { isRoomMember: () => { throw new Error('묻지 말 것'); }, isTeamMember: () => { throw new Error('묻지 말 것'); } };
  r = decideTargets(todo, { assignees: [{ userId: U2, progress: 0 }], ...boom });
  assert.deepEqual(r.targets, [U2]);
  assert.equal(r.membershipChecks, 0);
});
