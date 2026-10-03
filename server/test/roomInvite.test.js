// 그룹→토픽 전환·여러 방 일괄 초대의 순수 규칙 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
// 권한·트랜잭션·소켓은 임시 서버로 실제 HTTP/소켓 검증한다.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  bulkInviteRoomError,
  convertDenial,
  convertNotice,
  INVITE_BULK_MAX_ROOMS,
  INVITE_BULK_MAX_USERS,
  parseConvertBody,
  parseInviteBulkBody,
  planInvite,
} from '../src/roomInviteRules.js';

test('parseConvertBody: 이름 필수·60자, 설명 선택·300자, 앞뒤 공백 제거', () => {
  assert.deepEqual(parseConvertBody({ name: '  기획  ', description: '  설명 ' }), { name: '기획', description: '설명' });
  assert.deepEqual(parseConvertBody({ name: '기획' }), { name: '기획', description: null });
  assert.deepEqual(parseConvertBody({ name: '기획', description: '   ' }), { name: '기획', description: null });
  assert.ok(parseConvertBody({ name: '   ' }).error);
  assert.ok(parseConvertBody({}).error);
  assert.ok(parseConvertBody({ name: 5 }).error);
  assert.equal(parseConvertBody({ name: 'a'.repeat(60) }).error, undefined);
  assert.ok(parseConvertBody({ name: 'a'.repeat(61) }).error);
  assert.equal(parseConvertBody({ name: 'x', description: 'd'.repeat(300) }).error, undefined);
  assert.ok(parseConvertBody({ name: 'x', description: 'd'.repeat(301) }).error);
  assert.ok(parseConvertBody({ name: 'x', description: 7 }).error);
  // 글자(이모지 한 덩어리 = 1자) 단위로 센다.
  assert.equal(parseConvertBody({ name: '😀'.repeat(60) }).error, undefined);
});

test('convertDenial: 그룹채팅만 전환할 수 있다', () => {
  assert.equal(convertDenial({ type: 'group' }), null);
  assert.ok(convertDenial(null));
  assert.match(convertDenial({ type: 'topic' }), /이미 토픽/);
  assert.match(convertDenial({ type: 'dm' }), /1:1/);
  assert.match(convertDenial({ type: 'dm', isSecret: true }), /1:1/);
  assert.match(convertDenial({ type: 'dm', isSelf: true }), /나와의 대화/);
});

test('convertNotice: 시스템 메시지 문구', () => {
  assert.equal(convertNotice('홍길동', '기획'), "홍길동 님이 그룹채팅을 '기획' 토픽으로 전환했습니다.");
});

test('parseInviteBulkBody: teamId·멤버 1~200·방 1~100, 중복 제거', () => {
  const ok = parseInviteBulkBody({ teamId: 't', userIds: ['a', 'a', 'b', 3], roomIds: ['r1', 'r1'] });
  assert.deepEqual(ok, { teamId: 't', userIds: ['a', 'b'], roomIds: ['r1'] });
  assert.ok(parseInviteBulkBody({ userIds: ['a'], roomIds: ['r'] }).error);
  assert.ok(parseInviteBulkBody({ teamId: 't', userIds: [], roomIds: ['r'] }).error);
  assert.ok(parseInviteBulkBody({ teamId: 't', userIds: ['a'], roomIds: [] }).error);
  assert.ok(parseInviteBulkBody({ teamId: 't', userIds: 'a', roomIds: ['r'] }).error);
  const many = (n) => Array.from({ length: n }, (_, i) => `id${i}`);
  assert.equal(parseInviteBulkBody({ teamId: 't', userIds: many(INVITE_BULK_MAX_USERS), roomIds: ['r'] }).error, undefined);
  assert.ok(parseInviteBulkBody({ teamId: 't', userIds: many(INVITE_BULK_MAX_USERS + 1), roomIds: ['r'] }).error);
  assert.equal(parseInviteBulkBody({ teamId: 't', userIds: ['a'], roomIds: many(INVITE_BULK_MAX_ROOMS) }).error, undefined);
  assert.ok(parseInviteBulkBody({ teamId: 't', userIds: ['a'], roomIds: many(INVITE_BULK_MAX_ROOMS + 1) }).error);
});

test('bulkInviteRoomError: 내가 멤버인 같은 팀의 토픽·그룹채팅만', () => {
  const ctx = { teamId: 't', isMember: true };
  assert.equal(bulkInviteRoomError({ teamId: 't', type: 'topic' }, ctx), null);
  assert.equal(bulkInviteRoomError({ teamId: 't', type: 'topic', archivedAt: new Date() }, ctx), null); // 보관된 토픽도 된다.
  assert.equal(bulkInviteRoomError({ teamId: 't', type: 'group' }, ctx), null);
  assert.equal(bulkInviteRoomError(null, ctx), 'notMember');
  assert.equal(bulkInviteRoomError({ teamId: 't', type: 'topic' }, { ...ctx, isMember: false }), 'notMember');
  assert.equal(bulkInviteRoomError({ teamId: 'other', type: 'topic' }, ctx), 'wrongTeam');
  assert.equal(bulkInviteRoomError({ teamId: 't', type: 'dm' }, ctx), 'notAllowed');
  assert.equal(bulkInviteRoomError({ teamId: 't', type: 'dm', isSelf: true }, ctx), 'notAllowed');
  assert.equal(bulkInviteRoomError({ teamId: 't', type: 'dm', isSecret: true }, ctx), 'notAllowed');
});

test('planInvite: 이미 멤버 / 팀 멤버 아님 / 초대 대상으로 가른다', () => {
  const plan = planInvite(['a', 'b', 'c', 'd'], new Set(['a']), new Set(['a', 'b', 'c']));
  assert.deepEqual(plan, { toInvite: ['b', 'c'], alreadyMembers: ['a'], failed: ['d'] });
  assert.deepEqual(planInvite([], new Set(), new Set()), { toInvite: [], alreadyMembers: [], failed: [] });
});
