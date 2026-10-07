// 준회원으로 내려간 사람의 공유 캘린더 권한 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
// 공유 캘린더 행(calendar_members.role)은 계정 등급이 바뀌어도 그대로 남으므로, 권한 계산이 계정 등급을 함께 봐서
// 준회원을 읽기 멤버로 낮추는지(소유자여도 마찬가지), 정회원 이상은 예전 그대로인지 확인한다.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { canSearchEventTitle } from '../src/calendarSearchRules.js';
import { calendarPermissions, canModifyCalendarEvent, effectiveCalendarMemberRole } from '../src/permissions.js';

const ME = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const OTHER = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

const shared = (ownerId = OTHER, isPublic = false) => ({ id: 'c', teamId: 't', kind: 'shared', ownerId, isPublic });
const perm = (calendar, { role, memberRole = null, isOwner = false, isTeamMember = true }) =>
  calendarPermissions({ calendar, userId: ME, isTeamMember, role, isOwner, memberRole });
const pick = (p) => ({
  canView: p.canView,
  canCreateEvents: p.canCreateEvents,
  canEditSettings: p.canEditSettings,
  canDelete: p.canDelete,
  role: p.role,
  isOwner: p.isOwner,
  isManager: p.isManager,
  limitedAsGuest: p.limitedAsGuest,
});

// 읽기 멤버가 갖는 것 — 보기만 하고, 소유자·관리자 자격은 없다.
const READ_ONLY = {
  canView: true,
  canCreateEvents: false,
  canEditSettings: false,
  canDelete: false,
  role: 'read',
  isOwner: false,
  isManager: false,
};

test('effectiveCalendarMemberRole: 준회원은 관리자·쓰기 행이 있어도 읽기, 나머지는 행 그대로', () => {
  const of = (memberRole, role) => effectiveCalendarMemberRole({ memberRole, role });
  assert.equal(of('admin', 'guest'), 'read');
  assert.equal(of('write', 'guest'), 'read');
  assert.equal(of('read', 'guest'), 'read');
  assert.equal(of('subscriber', 'guest'), 'subscriber'); // 구독 여부는 calendarPermissions가 따로 막는다
  assert.equal(of(null, 'guest'), null);
  assert.equal(of(undefined, 'guest'), null);
  for (const role of ['member', 'admin']) {
    for (const memberRole of ['admin', 'write', 'read', 'subscriber']) assert.equal(of(memberRole, role), memberRole);
  }
  // 계정 등급을 모르면(undefined) 낮추지 않는다 — 준회원이라고 알 때만 읽기로 계산한다.
  assert.equal(of('admin', undefined), 'admin');
});

test('calendarPermissions: 준회원으로 내려간 관리자·쓰기 멤버는 읽기 멤버와 똑같다', () => {
  for (const memberRole of ['admin', 'write']) {
    for (const isPublic of [false, true]) {
      assert.deepEqual(pick(perm(shared(OTHER, isPublic), { role: 'guest', memberRole })), { ...READ_ONLY, limitedAsGuest: true }, memberRole);
    }
  }
  // 처음부터 읽기였던 준회원은 낮춰진 게 아니다(거절 문구도 일반 문구).
  assert.deepEqual(pick(perm(shared(), { role: 'guest', memberRole: 'read' })), { ...READ_ONLY, limitedAsGuest: false });
});

test('calendarPermissions: 준회원이 된 소유자는 캘린더 삭제·소유자 자격도 잃는다', () => {
  const mine = shared(ME);
  assert.deepEqual(pick(perm(mine, { role: 'guest', memberRole: 'admin' })), { ...READ_ONLY, limitedAsGuest: true });
  // 행이 이상하게 read여도(소유자 권한은 API로 못 바꾼다) 소유자 자격을 거둔 것이므로 limitedAsGuest.
  assert.deepEqual(pick(perm(mine, { role: 'guest', memberRole: 'read' })), { ...READ_ONLY, limitedAsGuest: true });
  // 그 팀의 소유자여도 공유 캘린더에서는 아무 힘이 없다 — 준회원이면 읽기.
  assert.deepEqual(pick(perm(mine, { role: 'guest', memberRole: 'admin', isOwner: true })), { ...READ_ONLY, limitedAsGuest: true });
});

test('calendarPermissions: 정회원 이상은 행의 권한 그대로 — 계정 등급 관리자도 행보다 올라가지 않는다', () => {
  assert.deepEqual(pick(perm(shared(), { role: 'member', memberRole: 'admin' })), {
    canView: true,
    canCreateEvents: true,
    canEditSettings: true,
    canDelete: false,
    role: 'admin',
    isOwner: false,
    isManager: true,
    limitedAsGuest: false,
  });
  assert.deepEqual(pick(perm(shared(ME), { role: 'member', memberRole: 'admin' })), {
    canView: true,
    canCreateEvents: true,
    canEditSettings: true,
    canDelete: true,
    role: 'admin',
    isOwner: true,
    isManager: true,
    limitedAsGuest: false,
  });
  const adminWriter = pick(perm(shared(), { role: 'admin', memberRole: 'write' }));
  assert.deepEqual(
    [adminWriter.role, adminWriter.canCreateEvents, adminWriter.canEditSettings, adminWriter.isManager, adminWriter.limitedAsGuest],
    ['write', true, false, false, false],
  );
  // 행은 고치지 않으므로 정회원으로 다시 올라가면 행에 남은 권한이 돌아온다.
  const restored = pick(perm(shared(ME), { role: 'member', memberRole: 'admin' }));
  assert.deepEqual([restored.canEditSettings, restored.canDelete, restored.isOwner], [true, true, true]);
  // 행이 없는 계정 등급 관리자는 공유 캘린더를 못 본다(멤버로 초대받은 사람만 — 예전과 같다).
  assert.equal(perm(shared(), { role: 'admin', memberRole: null }).canView, false);
});

test('canModifyCalendarEvent: 준회원은 공유 캘린더의 남의 일정도, 자기가 만들었던 일정도 못 고친다', () => {
  const others = { creatorId: OTHER };
  const own = { creatorId: ME };
  const can = (calendar, ctx, event) => canModifyCalendarEvent({ access: perm(calendar, ctx), event, userId: ME });
  for (const memberRole of ['admin', 'write']) {
    assert.equal(can(shared(), { role: 'guest', memberRole }, others), false, memberRole);
    assert.equal(can(shared(), { role: 'guest', memberRole }, own), false, memberRole); // 쓰기였을 때 만든 일정
  }
  assert.equal(can(shared(ME), { role: 'guest', memberRole: 'admin' }, others), false); // 준회원이 된 소유자
  // 정회원 관리자는 그대로 남의 일정을 고친다.
  assert.equal(can(shared(), { role: 'member', memberRole: 'admin' }, others), true);
  // 준회원도 자기 기본 캘린더의 일정은 고친다(기본 캘린더 규칙은 그대로).
  assert.equal(can({ kind: 'personal', ownerId: ME, isPublic: true }, { role: 'guest' }, own), true);
});

test('비공개 일정: 준회원은 공유 캘린더의 남의 비공개 일정 상세·제목을 못 본다(만든 사람·참석자면 본다)', () => {
  // canSearchEventTitle은 일정 조회·상세(calendars.js toOccurrenceDto)의 "상세가 보이는지"와 같은 조건이다 —
  // 둘 다 access.isOwner·isManager를 보므로 그 값이 준회원에게 false인지 함께 확인한다.
  const priv = { visibility: 'private', creatorId: OTHER };
  const sees = (access, event = priv, isAttendee = false) => canSearchEventTitle({ event, viewerId: ME, isAttendee, access });
  const guestAdmin = perm(shared(), { role: 'guest', memberRole: 'admin' });
  const guestOwner = perm(shared(ME), { role: 'guest', memberRole: 'admin' });
  for (const access of [guestAdmin, guestOwner]) {
    assert.deepEqual([access.isOwner, access.isManager], [false, false]);
    assert.equal(sees(access), false);
    assert.equal(sees(access, { ...priv, creatorId: ME }), true); // 내가 만든 비공개 일정
    assert.equal(sees(access, priv, true), true); // 참석자로 초대받은 비공개 일정
    assert.equal(sees(access, { visibility: 'public', creatorId: OTHER }), true);
  }
  assert.equal(sees(perm(shared(), { role: 'member', memberRole: 'admin' })), true);
  assert.equal(sees(perm(shared(ME), { role: 'member', memberRole: 'admin' })), true);
});

test('calendarPermissions: 준회원의 다른 캘린더 규칙과 limitedAsGuest 기본값은 그대로', () => {
  // 자기 기본 캘린더는 전부 할 수 있다.
  const personal = pick(perm({ kind: 'personal', ownerId: ME, isPublic: true }, { role: 'guest' }));
  assert.deepEqual(
    [personal.canView, personal.canCreateEvents, personal.canEditSettings, personal.isOwner, personal.isManager, personal.limitedAsGuest],
    [true, true, true, true, true, false],
  );
  // 팀 캘린더·구독은 준회원에게 보이지 않는다(그 팀의 소유자여도).
  assert.equal(perm({ kind: 'team', ownerId: null, isPublic: true }, { role: 'guest', isOwner: true }).canView, false);
  assert.equal(perm(shared(OTHER, true), { role: 'guest', memberRole: 'subscriber' }).canView, false);
  assert.equal(perm({ kind: 'personal', ownerId: OTHER, isPublic: true }, { role: 'guest', memberRole: 'subscriber' }).canView, false);
  // 팀에서 나갔으면 행이 무엇이든 아무것도 못 한다.
  const left = perm(shared(), { role: 'guest', memberRole: 'admin', isTeamMember: false });
  assert.deepEqual(pick(left), {
    canView: false,
    canCreateEvents: false,
    canEditSettings: false,
    canDelete: false,
    role: null,
    isOwner: false,
    isManager: false,
    limitedAsGuest: false,
  });
});
