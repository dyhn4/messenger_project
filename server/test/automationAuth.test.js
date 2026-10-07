// 프로젝트 자동화 "채팅방 알림"의 권한·횟수 규칙과 업무 제목·설명 길이 테스트 — `node --test test/automationAuth.test.js`
// (DB·서버 없이 돈다). 채팅방 알림은 규칙을 저장한 사람(savedBy)의 권한으로 올라가므로, 실행할 때마다 그 사람이 아직 살아 있는
// 정회원 이상이고, 프로젝트 구성원이며, 규칙을 저장할 수 있는(프로젝트를 관리할 수 있는) 사람이고, 채팅방 멤버인지 본다(S16).
// 사실을 DB에서 모으고 규칙을 끄는 부분(projectAutomation.js chatSaverDenial·runGraphRule)은 DB가 있어야 해서 여기서는 그
// 판단(automationSaverDenial)과 횟수 상한(AutomationChatThrottle), 올라가는 글의 모양(automationChatText), 그리고 만들기·
// 고치기가 같이 쓰는 업무 제목·설명 길이(parseTaskTitle·parseTaskDescription)를 본다.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  AUTOMATION_CHAT_PER_ROOM,
  AUTOMATION_CHAT_PER_RULE,
  AUTOMATION_CHAT_THROTTLED,
  AUTOMATION_CHAT_WINDOW_MS,
  AutomationChatThrottle,
  TASK_DESCRIPTION_MAX,
  TASK_TITLE_MAX,
  automationChatText,
  automationSaverDenial,
  parseTaskDescription,
  parseTaskTitle,
} from '../src/projectNotifications.js';

const NOW = new Date('2026-10-07T00:00:00Z');

/** 저장한 사람이 모든 조건을 갖춘 경우 — 각 테스트가 하나씩 뺀다. */
function facts(overrides = {}) {
  return {
    savedBy: 'u1',
    saver: { id: 'u1', role: 'member', isServerAdmin: false, suspendedAt: null, deletedAt: null },
    isProjectMember: true,
    canManageProject: true,
    isRoomMember: true,
    ...overrides,
  };
}
const saver = (fields) => ({ ...facts().saver, ...fields });

test('automationSaverDenial: 모든 조건을 갖추면 올린다', () => {
  assert.equal(automationSaverDenial(facts()), null);
  assert.equal(automationSaverDenial(facts({ saver: saver({ role: 'admin' }) })), null);
  // 서버 운영자는 준회원이어도 프로젝트를 쓸 수 있다(프로젝트 라우터 입구 규칙과 같다).
  assert.equal(automationSaverDenial(facts({ saver: saver({ role: 'guest', isServerAdmin: true }) })), null);
});

test('automationSaverDenial: 저장한 사람이 없으면(예전 규칙) 올리지 않는다', () => {
  assert.equal(automationSaverDenial({ savedBy: null }), '규칙을 저장한 사람을 알 수 없습니다.');
  assert.equal(automationSaverDenial({ savedBy: undefined }), '규칙을 저장한 사람을 알 수 없습니다.');
  assert.equal(automationSaverDenial(facts({ savedBy: '' })), '규칙을 저장한 사람을 알 수 없습니다.');
});

test('automationSaverDenial: 정지·탈퇴·준회원 강등된 저장자는 권한을 잃는다', () => {
  const reason = '규칙을 저장한 사람이 탈퇴·정지됐거나 준회원이 되었습니다.';
  assert.equal(automationSaverDenial(facts({ saver: null })), reason);
  assert.equal(automationSaverDenial(facts({ saver: saver({ suspendedAt: NOW }) })), reason);
  assert.equal(automationSaverDenial(facts({ saver: saver({ deletedAt: NOW }) })), reason);
  assert.equal(automationSaverDenial(facts({ saver: saver({ role: 'guest' }) })), reason);
  // 서버 운영자여도 정지되면 안 된다.
  assert.equal(automationSaverDenial(facts({ saver: saver({ role: 'admin', isServerAdmin: true, suspendedAt: NOW }) })), reason);
});

test('automationSaverDenial: 프로젝트에서 빠졌거나 관리 권한을 잃었거나 방을 나간 저장자', () => {
  assert.equal(
    automationSaverDenial(facts({ isProjectMember: false })),
    '규칙을 저장한 사람이 더 이상 이 프로젝트의 구성원이 아닙니다.',
  );
  assert.equal(
    automationSaverDenial(facts({ canManageProject: false })),
    '규칙을 저장한 사람이 더 이상 이 프로젝트를 관리할 수 없습니다.',
  );
  assert.equal(
    automationSaverDenial(facts({ isRoomMember: false })),
    '규칙을 저장한 사람이 더 이상 채팅방 멤버가 아닙니다.',
  );
});

test('automationSaverDenial: 여러 조건을 잃었으면 계정 → 구성원 → 관리 권한 → 방 순서로 첫 이유를 준다', () => {
  assert.match(
    automationSaverDenial({ savedBy: 'u1', saver: saver({ suspendedAt: NOW }), isProjectMember: false, canManageProject: false, isRoomMember: false }),
    /탈퇴·정지/,
  );
  assert.match(automationSaverDenial(facts({ isProjectMember: false, canManageProject: false, isRoomMember: false })), /구성원이 아닙니다/);
  assert.match(automationSaverDenial(facts({ canManageProject: false, isRoomMember: false })), /관리할 수 없습니다/);
});

test('AutomationChatThrottle: 규칙마다 10분에 20번, 채팅방마다 10분에 30번', () => {
  assert.equal(AUTOMATION_CHAT_PER_RULE, 20);
  assert.equal(AUTOMATION_CHAT_PER_ROOM, 30);
  assert.equal(AUTOMATION_CHAT_WINDOW_MS, 10 * 60 * 1000);
  let t = 0;
  const throttle = new AutomationChatThrottle({ now: () => t });
  for (let i = 0; i < AUTOMATION_CHAT_PER_RULE; i += 1) assert.equal(throttle.take('rule-a', 'room-1'), 0, `${i + 1}번째`);
  assert.ok(throttle.take('rule-a', 'room-1') > 0, '규칙 상한을 넘으면 막힌다');
  // 같은 방이라도 다른 규칙은 방 몫(30)이 남은 만큼 올린다 — 상한을 넘긴 규칙의 시도는 방 몫을 쓰지 않았다.
  for (let i = 0; i < AUTOMATION_CHAT_PER_ROOM - AUTOMATION_CHAT_PER_RULE; i += 1) {
    assert.equal(throttle.take('rule-b', 'room-1'), 0);
  }
  assert.ok(throttle.take('rule-b', 'room-1') > 0, '방 상한을 넘으면 다른 규칙도 막힌다');
  assert.equal(throttle.take('rule-c', 'room-2'), 0, '다른 방은 따로 센다');
  t += AUTOMATION_CHAT_WINDOW_MS;
  assert.equal(throttle.take('rule-a', 'room-1'), 0, '창이 지나면 다시 올린다');
  assert.match(AUTOMATION_CHAT_THROTTLED, /너무 많아/);
});

test('automationChatText: 머리말·내용 뒤에 실행한 사람을 적는다(모르면 알 수 없음)', () => {
  const base = { ruleName: '완료 알림', taskKey: 'MKT-1001', taskTitle: '배너 교체', body: '완료되었습니다.' };
  assert.equal(
    automationChatText({ ...base, actorName: '홍길동' }),
    '[완료 알림] MKT-1001 배너 교체\n완료되었습니다.\n(실행한 사람: 홍길동)',
  );
  assert.equal(
    automationChatText({ ...base, actorName: null }),
    '[완료 알림] MKT-1001 배너 교체\n완료되었습니다.\n(실행한 사람: 알 수 없음)',
  );
  assert.match(automationChatText({ ...base, actorName: '' }), /\(실행한 사람: 알 수 없음\)$/);
});

test('parseTaskTitle: 앞뒤 공백을 빼고 1~200자', () => {
  assert.equal(TASK_TITLE_MAX, 200);
  assert.deepEqual(parseTaskTitle('  배너 교체  '), { value: '배너 교체' });
  assert.deepEqual(parseTaskTitle('가'.repeat(200)), { value: '가'.repeat(200) });
  assert.deepEqual(parseTaskTitle('가'.repeat(201)), { error: '업무 제목은 200자 이내로 입력하세요.' });
  // 공백을 뺀 길이로 센다.
  assert.deepEqual(parseTaskTitle(` ${'a'.repeat(200)} `), { value: 'a'.repeat(200) });
  for (const empty of ['', '   ', null, undefined, 42, {}]) {
    assert.deepEqual(parseTaskTitle(empty), { error: '업무 제목을 입력하세요.' }, String(empty));
  }
});

test('parseTaskDescription: 비면 null, 10,000자까지', () => {
  assert.equal(TASK_DESCRIPTION_MAX, 10000);
  assert.deepEqual(parseTaskDescription('  설명  '), { value: '설명' });
  assert.deepEqual(parseTaskDescription('   '), { value: null });
  assert.deepEqual(parseTaskDescription(''), { value: null });
  // 글자가 아닌 값은 예전처럼 설명을 비운다.
  assert.deepEqual(parseTaskDescription(null), { value: null });
  assert.deepEqual(parseTaskDescription(undefined), { value: null });
  assert.deepEqual(parseTaskDescription(7), { value: null });
  assert.deepEqual(parseTaskDescription('x'.repeat(TASK_DESCRIPTION_MAX)), { value: 'x'.repeat(TASK_DESCRIPTION_MAX) });
  assert.deepEqual(parseTaskDescription('x'.repeat(TASK_DESCRIPTION_MAX + 1)), {
    error: '업무 설명은 10,000자 이내로 입력하세요.',
  });
});
