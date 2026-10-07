// 화상회의 참가 규칙(callAccess.js — 방 종류·읽기 전용 토픽·토큰 발급 기록·시작 횟수 제한·call:join 받아들이기·LiveKit 확인
// 횟수 제한), 거절 한 번만(callState.js markCallDeclined), 다른 기기로 옮김(callState.js joinCall), 카드 사건의 한 사람 몫
// 상한(callEvents.js addUserCallEvent) 단위 테스트 — `node --test test/*.test.js` (DB·LiveKit·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { RateLimiter } from '../src/authGuard.js';
import {
  CALL_JOIN_PROOF_MAX_PER_MIN,
  CALL_JOIN_UNVERIFIED,
  CALL_START_MAX_PER_ROOM,
  CALL_START_MAX_PER_USER,
  CALL_TOKEN_TTL_MS,
  SECRET_ROOM_CALL_DENIAL,
  admitCallJoin,
  callJoinProofLimitText,
  callJoinProofWait,
  callRoomDenial,
  callStartDenial,
  callStartLimitText,
  consumeCallToken,
  createCallStartLimiter,
  hasCallToken,
  isRestrictedTopic,
  recordCallToken,
  tokenIssuedAfter,
} from '../src/callAccess.js';
import { CALL_CARD_MAX_EVENTS_PER_USER, addUserCallEvent, newCallCard } from '../src/callEvents.js';
import {
  callStateFor,
  isSocketInCall,
  joinCall,
  leaveAllCallsForSocket,
  leaveCall,
  markCallDeclined,
} from '../src/callState.js';
import { SELF_ROOM_DENIAL } from '../src/permissions.js';

const MIN = 60 * 1000;

function room(id, over = {}) {
  return { id, type: 'group', isSecret: false, isSelf: false, readOnly: false, archivedAt: null, ...over };
}

/** call:join의 LiveKit 확인 자리에 넣는 가짜 — 물어본 횟수를 센다. */
function livekitSays(answer) {
  const fn = async (roomId, userId) => {
    fn.asked.push([roomId, userId]);
    return answer;
  };
  fn.asked = [];
  return fn;
}

/** 넉넉한 제한(테스트 사이에 기본 제한을 건드리지 않게 따로 만든다). */
const roomyLimiter = () => createCallStartLimiter({ maxPerRoom: 100, maxPerUser: 100 });

/** 시작으로 세면 테스트가 실패하는 제한 — 되살리기·합류가 시작 횟수를 건드리지 않는지 본다. */
const mustNotCount = {
  waitFor: () => 0,
  hit() {
    throw new Error('통화 시작으로 세면 안 된다');
  },
};

function endCall(roomId) {
  for (const id of callStateFor(roomId).participantIds) {
    // 테스트가 쓴 소켓 id 규칙(`s-<user>`·`s-<user>-2`)으로 모두 뺀다.
    leaveCall(roomId, id, `s-${id}`);
    leaveCall(roomId, id, `s-${id}-2`);
  }
  assert.equal(callStateFor(roomId).active, false);
}

test('비밀 대화·나와의 대화는 화상회의를 아예 못 쓴다', () => {
  assert.equal(callRoomDenial(room('a', { isSecret: true, type: 'dm' })), SECRET_ROOM_CALL_DENIAL);
  assert.equal(callRoomDenial(room('a', { isSelf: true, type: 'dm' })), SELF_ROOM_DENIAL);
  assert.equal(callRoomDenial(room('a', { type: 'dm' })), null);
  assert.equal(callRoomDenial(room('a', { type: 'topic' })), null);
  assert.equal(callRoomDenial(room('a')), null);
});

test('읽기 전용·보관된 토픽은 토픽 관리자만 통화를 시작한다', () => {
  const readOnly = room('a', { type: 'topic', readOnly: true });
  const archived = room('a', { type: 'topic', archivedAt: new Date() });
  assert.equal(isRestrictedTopic(readOnly), true);
  assert.equal(isRestrictedTopic(archived), true);
  assert.equal(isRestrictedTopic(room('a', { type: 'topic' })), false);
  // 토픽이 아니면 readOnly 칸이 있어도 해당 없다(글쓰기 규칙과 같다).
  assert.equal(isRestrictedTopic(room('a', { readOnly: true })), false);

  assert.match(callStartDenial({ room: readOnly, canManage: false }), /읽기 전용 토픽에서는 토픽 관리자만 화상회의를 시작/);
  assert.match(callStartDenial({ room: archived, canManage: false }), /보관된 토픽에서는 토픽 관리자만 화상회의를 시작/);
  assert.equal(callStartDenial({ room: readOnly, canManage: true }), null);
  assert.equal(callStartDenial({ room: room('a', { type: 'topic' }), canManage: false }), null);
  assert.equal(callStartDenial({ room: room('a'), canManage: false }), null);
});

test('토큰 발급 기록 — 유효 시간 안에서만, 쓰고 나면 지워진다, 사람·방마다 따로', () => {
  const t0 = 1_000_000;
  recordCallToken('tok-u', 'tok-r', t0);
  assert.equal(hasCallToken('tok-u', 'tok-r', t0 + CALL_TOKEN_TTL_MS), true);
  assert.equal(hasCallToken('tok-u', 'tok-r', t0 + CALL_TOKEN_TTL_MS + 1), false);
  assert.equal(hasCallToken('tok-u', 'other-room', t0), false);
  assert.equal(hasCallToken('other-user', 'tok-r', t0), false);
  consumeCallToken('tok-u', 'tok-r');
  assert.equal(hasCallToken('tok-u', 'tok-r', t0), false);
  // 쓴 뒤에도 발급 시각은 남는다 — 자격을 잃은 뒤 다시 얻었는지 볼 때 쓴다.
  assert.equal(tokenIssuedAfter('tok-u', 'tok-r', t0 - 1), true);
  assert.equal(tokenIssuedAfter('tok-u', 'tok-r', t0), false);
  assert.equal(tokenIssuedAfter('tok-u', 'other-room', 0), false);
});

test('통화 시작 제한 — 같은 방 5번, 미리 보기는 세지 않고, 창이 지나면 풀린다', () => {
  let now = 0;
  const limiter = createCallStartLimiter({ now: () => now });
  for (let i = 0; i < CALL_START_MAX_PER_ROOM; i++) {
    assert.equal(limiter.waitFor('lim-u', 'lim-r'), 0);
    assert.equal(limiter.hit('lim-u', 'lim-r'), 0);
  }
  // 미리 보기(토큰 발급)는 막힐지만 알려 주고 세지 않는다.
  assert.ok(limiter.waitFor('lim-u', 'lim-r') > 0);
  assert.ok(limiter.waitFor('lim-u', 'lim-r') > 0);
  const wait = limiter.hit('lim-u', 'lim-r');
  assert.ok(wait > 0 && wait <= 10 * MIN);
  // 다른 사람·다른 방은 그대로.
  assert.equal(limiter.hit('lim-other', 'lim-r'), 0);
  assert.equal(limiter.hit('lim-u', 'lim-r2'), 0);
  // 창(10분)이 지나면 다시 걸 수 있다 — 막혔던 시도는 세지 않아 창이 늘어나지 않는다.
  now += 10 * MIN;
  assert.equal(limiter.waitFor('lim-u', 'lim-r'), 0);
  assert.equal(limiter.hit('lim-u', 'lim-r'), 0);
});

test('통화 시작 제한 — 여러 방을 돌아가며 걸어도 사람마다 20번까지', () => {
  const limiter = createCallStartLimiter({ now: () => 0 });
  for (let i = 0; i < CALL_START_MAX_PER_USER; i++) assert.equal(limiter.hit('spread-u', `spread-r${i}`), 0);
  assert.ok(limiter.hit('spread-u', 'spread-new-room') > 0);
  assert.equal(limiter.hit('spread-other', 'spread-new-room'), 0);
});

test('막혔을 때 문구는 남은 시간을 분 단위로', () => {
  assert.equal(callStartLimitText(90_000), '화상회의 시도가 너무 많습니다. 2분 후 다시 시도하세요.');
});

test('call:join — 토큰도 통화 상태도 LiveKit 연결도 없으면 거절', async () => {
  const lk = livekitSays(false);
  const result = await admitCallJoin({ room: room('j-none'), userId: 'a', socketId: 's-a', canManage: true, livekitHas: lk, limiter: roomyLimiter() });
  assert.deepEqual(result, { ok: false, error: CALL_JOIN_UNVERIFIED });
  assert.deepEqual(lk.asked, [['j-none', 'a']]);
  assert.equal(callStateFor('j-none').active, false);
});

test('call:join — 방금 받은 토큰으로 통화를 시작하고, 그 토큰은 한 번만 쓴다', async () => {
  const r = room('j-token');
  const lk = livekitSays(false);
  recordCallToken('a', r.id);
  const first = await admitCallJoin({ room: r, userId: 'a', socketId: 's-a', canManage: true, livekitHas: lk, limiter: roomyLimiter() });
  assert.equal(first.ok, true);
  assert.equal(first.wasIn, false);
  assert.equal(first.state.active, true);
  assert.equal(first.state.startedBy, 'a');
  assert.deepEqual(first.state.participantIds, ['a']);
  assert.deepEqual(lk.asked, []); // 토큰이 있으면 LiveKit에 묻지 않는다.
  assert.equal(hasCallToken('a', r.id), false);

  // 나갔다가 같은 토큰으로(새로 받지 않고) 다시 call:join만 보내면 — LiveKit에도 없으니 거절.
  leaveCall(r.id, 'a', 's-a');
  const again = await admitCallJoin({ room: r, userId: 'a', socketId: 's-a', canManage: true, livekitHas: lk, limiter: roomyLimiter() });
  assert.equal(again.ok, false);
  assert.equal(callStateFor(r.id).active, false);
});

test('call:join — 이미 들어와 있으면(다른 기기·다시 알림) 토큰 없이도 받고, LiveKit에 묻지 않는다', async () => {
  const r = room('j-rejoin');
  recordCallToken('a', r.id);
  await admitCallJoin({ room: r, userId: 'a', socketId: 's-a', canManage: true, livekitHas: livekitSays(false), limiter: roomyLimiter() });
  const lk = livekitSays(false);
  const again = await admitCallJoin({ room: r, userId: 'a', socketId: 's-a-2', canManage: true, livekitHas: lk, limiter: roomyLimiter() });
  assert.equal(again.ok, true);
  assert.equal(again.wasIn, true);
  assert.deepEqual(again.state.participantIds, ['a']);
  assert.deepEqual(lk.asked, []);
  endCall(r.id);
});

test('call:join — 끊김 유예보다 오래 끊겼다 다시 알려도(토큰은 오래됨) LiveKit에 연결돼 있으면 받는다', async () => {
  const r = room('j-livekit');
  recordCallToken('a', r.id);
  recordCallToken('b', r.id);
  await admitCallJoin({ room: r, userId: 'a', socketId: 's-a', canManage: true, livekitHas: livekitSays(false), limiter: roomyLimiter() });
  await admitCallJoin({ room: r, userId: 'b', socketId: 's-b', canManage: true, livekitHas: livekitSays(false), limiter: roomyLimiter() });
  // b의 소켓이 끊겨 유예 뒤에 통화 상태에서 빠졌다(socket.js disconnect). 영상은 그대로 이어지는 중.
  leaveCall(r.id, 'b', 's-b');
  const lk = livekitSays(true);
  const back = await admitCallJoin({ room: r, userId: 'b', socketId: 's-b-2', canManage: true, livekitHas: lk, limiter: roomyLimiter() });
  assert.equal(back.ok, true);
  assert.equal(back.wasIn, false);
  assert.equal(back.restored, false); // 통화는 a로 이어지고 있었다 — 합류다.
  assert.deepEqual(back.state.participantIds, ['a', 'b']);
  assert.deepEqual(lk.asked, [[r.id, 'b']]);
  endCall(r.id);
});

test('call:join — 비밀 대화·나와의 대화는 토큰이 있어도 거절', async () => {
  for (const r of [room('j-secret', { type: 'dm', isSecret: true }), room('j-self', { type: 'dm', isSelf: true })]) {
    recordCallToken('a', r.id);
    const result = await admitCallJoin({ room: r, userId: 'a', socketId: 's-a', canManage: true, livekitHas: livekitSays(true), limiter: roomyLimiter() });
    assert.equal(result.ok, false);
    assert.equal(callStateFor(r.id).active, false);
  }
});

test('call:join — 읽기 전용 토픽: 멤버는 시작 못 하지만, 관리자가 연 회의에는 합류한다', async () => {
  const r = room('j-readonly', { type: 'topic', readOnly: true });
  const limiter = roomyLimiter();
  recordCallToken('member', r.id);
  const start = await admitCallJoin({ room: r, userId: 'member', socketId: 's-member', canManage: false, livekitHas: livekitSays(false), limiter });
  assert.equal(start.ok, false);
  assert.match(start.error, /읽기 전용 토픽/);
  assert.equal(callStateFor(r.id).active, false);
  // 거절됐으니 토큰은 남아 있다 — 관리자가 회의를 연 뒤 같은 토큰으로 합류할 수 있다.
  assert.equal(hasCallToken('member', r.id), true);

  recordCallToken('manager', r.id);
  const opened = await admitCallJoin({ room: r, userId: 'manager', socketId: 's-manager', canManage: true, livekitHas: livekitSays(false), limiter });
  assert.equal(opened.ok, true);
  const joined = await admitCallJoin({ room: r, userId: 'member', socketId: 's-member', canManage: false, livekitHas: livekitSays(false), limiter });
  assert.equal(joined.ok, true);
  assert.deepEqual(joined.state.participantIds, ['manager', 'member']);
  endCall(r.id);
});

test('call:join — 시작만 세고(합류는 안 셈), 너무 자주 시작하면 거절', async () => {
  const limiter = createCallStartLimiter({ maxPerRoom: 2, maxPerUser: 100 });
  const r = room('j-limit');
  const start = (userId) => {
    recordCallToken(userId, r.id);
    return admitCallJoin({ room: r, userId, socketId: `s-${userId}`, canManage: true, livekitHas: livekitSays(false), limiter });
  };
  for (let i = 0; i < 2; i++) {
    assert.equal((await start('caller')).ok, true);
    // 상대가 합류해도 caller의 횟수는 그대로, 상대(b)는 시작이 아니라 세지 않는다.
    assert.equal((await start('b')).ok, true);
    endCall(r.id);
  }
  const third = await start('caller');
  assert.equal(third.ok, false);
  assert.match(third.error, /화상회의 시도가 너무 많습니다/);
  assert.equal(callStateFor(r.id).active, false);
  // b는 한 번도 시작하지 않았으니 시작할 수 있다.
  assert.equal((await start('b')).ok, true);
  endCall(r.id);
});

test('call:join — 서버 재시작 뒤 읽기 전용 토픽 멤버가 먼저 다시 알려도 통화를 되살린다(시작 규칙·횟수는 안 봄, 울리지 않음)', async () => {
  // 관리자가 연 공지 토픽 회의 중에 Node 서버만 재시작돼 통화 상태(메모리)가 비었다 — LiveKit 회의는 그대로다.
  const r = room('j-restart', { type: 'topic', readOnly: true });
  const lk = livekitSays(true);
  const member = await admitCallJoin({ room: r, userId: 'member', socketId: 's-member', canManage: false, livekitHas: lk, limiter: mustNotCount });
  assert.equal(member.ok, true);
  assert.equal(member.restored, true);
  assert.equal(member.wasIn, false);
  assert.equal(member.state.restored, true); // 앱이 이 통화로 다시 울리지 않게.
  assert.deepEqual(member.state.participantIds, ['member']);
  assert.deepEqual(lk.asked, [[r.id, 'member']]);

  // 나중에 다시 알린 관리자는 되살린 그 통화에 합류한다.
  const manager = await admitCallJoin({ room: r, userId: 'manager', socketId: 's-manager', canManage: true, livekitHas: livekitSays(true), limiter: mustNotCount });
  assert.equal(manager.ok, true);
  assert.equal(manager.restored, false);
  assert.equal(manager.state.restored, true);
  assert.deepEqual(manager.state.participantIds, ['member', 'manager']);
  endCall(r.id);
});

test('call:join — 관리자가 나가고 혼자 남은 멤버가 끊김 유예보다 오래 끊겼다 다시 알려도 이어 간다', async () => {
  const r = room('j-alone', { type: 'topic', readOnly: true });
  recordCallToken('manager', r.id);
  recordCallToken('member', r.id);
  const limiter = roomyLimiter();
  assert.equal((await admitCallJoin({ room: r, userId: 'manager', socketId: 's-manager', canManage: true, livekitHas: livekitSays(false), limiter })).ok, true);
  assert.equal((await admitCallJoin({ room: r, userId: 'member', socketId: 's-member', canManage: false, livekitHas: livekitSays(false), limiter })).ok, true);
  leaveCall(r.id, 'manager', 's-manager');
  // 멤버 소켓이 오래 끊겨 통화 상태에서 빠졌다(socket.js disconnect) — 혼자였으니 통화가 끝난 것으로 정리됐다.
  leaveCall(r.id, 'member', 's-member');
  assert.equal(callStateFor(r.id).active, false);

  const back = await admitCallJoin({ room: r, userId: 'member', socketId: 's-member-2', canManage: false, livekitHas: livekitSays(true), limiter: mustNotCount });
  assert.equal(back.ok, true);
  assert.equal(back.restored, true);
  assert.deepEqual(back.state.participantIds, ['member']);
  endCall(r.id);
});

test('call:join — 혼자 있다가 오래 끊기기를 되풀이해도(되살리기) 시작 횟수에 안 걸리고, 진짜 시작은 그대로 센다', async () => {
  const limiter = createCallStartLimiter({ maxPerRoom: 1, maxPerUser: 100 });
  const r = room('j-flaky');
  recordCallToken('a', r.id);
  assert.equal((await admitCallJoin({ room: r, userId: 'a', socketId: 's-a', canManage: true, livekitHas: livekitSays(false), limiter })).ok, true);
  for (let i = 0; i < 5; i++) {
    leaveCall(r.id, 'a', 's-a'); // 끊김 유예 뒤 정리 — 통화가 끝났다.
    const back = await admitCallJoin({ room: r, userId: 'a', socketId: 's-a', canManage: true, livekitHas: livekitSays(true), limiter });
    assert.equal(back.ok, true);
    assert.equal(back.restored, true);
  }
  endCall(r.id);
  // 새 토큰으로 다시 거는 건 진짜 시작이라 센다(이 방 1번 — 이미 찼다).
  recordCallToken('a', r.id);
  const again = await admitCallJoin({ room: r, userId: 'a', socketId: 's-a', canManage: true, livekitHas: livekitSays(true), limiter });
  assert.equal(again.ok, false);
  assert.match(again.error, /화상회의 시도가 너무 많습니다/);
});

test('call:join — 방금 받은 토큰으로 왔으면 LiveKit에 붙어 있어도 통화 시작이다(읽기 전용 토픽 멤버는 거절)', async () => {
  // 관리자가 연 회의 중에 토큰을 받아 LiveKit에 붙었는데, call:join이 닿기 전에 회의가 끝났다 — 이건 새로 거는 것이다.
  const r = room('j-token-first', { type: 'topic', readOnly: true });
  recordCallToken('member', r.id);
  const lk = livekitSays(true);
  const result = await admitCallJoin({ room: r, userId: 'member', socketId: 's-member', canManage: false, livekitHas: lk, limiter: roomyLimiter() });
  assert.equal(result.ok, false);
  assert.match(result.error, /읽기 전용 토픽/);
  assert.deepEqual(lk.asked, []);
  assert.equal(callStateFor(r.id).active, false);
  consumeCallToken('member', r.id);
});

test('LiveKit 확인까지 가는 call:join은 사람마다 1분에 10번까지 — 통화 중 다시 알림·방금 받은 토큰은 세지 않는다', () => {
  let t = 0;
  const limiter = new RateLimiter({ max: CALL_JOIN_PROOF_MAX_PER_MIN, windowMs: 60_000, now: () => t });
  joinCall('proof-r', 'in', 's-in');
  recordCallToken('fresh', 'proof-r');
  for (let i = 0; i < 30; i++) {
    assert.equal(callJoinProofWait('in', 'proof-r', { limiter }), 0);
    assert.equal(callJoinProofWait('fresh', 'proof-r', { limiter }), 0);
  }
  // 그 밖(LiveKit에 물어봐야 하는 시도)은 방을 바꿔 가며 보내도 사람마다 센다.
  for (let i = 0; i < CALL_JOIN_PROOF_MAX_PER_MIN; i++) {
    assert.equal(callJoinProofWait('flood', `proof-r${i}`, { limiter }), 0);
  }
  const wait = callJoinProofWait('flood', 'proof-x', { limiter });
  assert.ok(wait > 0 && wait <= 60_000);
  assert.equal(callJoinProofWait('other', 'proof-x', { limiter }), 0);
  t += 60_000;
  assert.equal(callJoinProofWait('flood', 'proof-x', { limiter }), 0);
  assert.equal(callJoinProofLimitText(30_000), '화상회의 참여 시도가 너무 많습니다. 1분 후 다시 시도하세요.');
  leaveCall('proof-r', 'in', 's-in');
  consumeCallToken('fresh', 'proof-r');
});

test('같은 사람이 다른 소켓으로 참여를 알리면 그 소켓이 예전 소켓을 대신한다(다른 기기로 옮김) — 진행자·참가 순서 그대로', () => {
  const r = 'move-room';
  joinCall(r, 'a', 's-a-pc');
  joinCall(r, 'b', 's-b');
  const moved = joinCall(r, 'a', 's-a-phone');
  assert.deepEqual(moved.participantIds, ['a', 'b']);
  assert.equal(moved.hostId, 'a');
  assert.equal(isSocketInCall(r, 'a', 's-a-pc'), false);
  assert.equal(isSocketInCall(r, 'a', 's-a-phone'), true);
  // 예전 기기의 나가기나 그 소켓의 끊김 정리는 아무것도 바꾸지 않는다.
  assert.deepEqual(leaveCall(r, 'a', 's-a-pc').participantIds, ['a', 'b']);
  assert.deepEqual(leaveAllCallsForSocket('a', 's-a-pc'), []);
  // 옮겨 간 기기에서 나가면 그 사람이 빠지고 진행자가 넘어간다(예전엔 예전 소켓이 남아 계속 "통화 중"이었다).
  const left = leaveCall(r, 'a', 's-a-phone');
  assert.deepEqual(left.participantIds, ['b']);
  assert.equal(left.hostId, 'b');
  leaveCall(r, 'b', 's-b');
  assert.equal(callStateFor(r).active, false);
});

test('되살린 통화는 상태와 끝난 요약에 restored가 붙고, 보통 통화는 그 칸이 없다', () => {
  const restored = joinCall('flag-restored', 'a', 's-a', { restored: true });
  assert.equal(restored.restored, true);
  // 이미 있는 통화에 합류할 때 넘긴 값은 무시한다(통화를 새로 만들 때만).
  assert.equal(joinCall('flag-restored', 'b', 's-b').restored, true);
  leaveCall('flag-restored', 'b', 's-b');
  assert.equal(leaveCall('flag-restored', 'a', 's-a').ended.restored, true);

  const plain = joinCall('flag-plain', 'a', 's-a');
  assert.equal('restored' in plain, false);
  assert.equal('restored' in joinCall('flag-plain', 'b', 's-b', { restored: true }), false);
  leaveCall('flag-plain', 'b', 's-b');
  assert.equal('restored' in leaveCall('flag-plain', 'a', 's-a').ended, false);
});

test('카드 사건은 한 사람마다 상한까지 — 나가기·참여를 되풀이해도 다른 사람 몫이 남는다', () => {
  let card = newCallCard({ at: 0, userId: 'a', name: 'a' });
  for (let i = 0; i < 200; i++) {
    card = addUserCallEvent(card, { at: i, userId: 'loop', name: 'x', kind: i % 2 ? 'join' : 'leave' });
  }
  assert.equal(card.events.filter((e) => e.userId === 'loop').length, CALL_CARD_MAX_EVENTS_PER_USER);
  // 상한이면 같은 카드를 그대로 돌려준다(callCards.js가 DB를 고치지도, 알리지도 않는다).
  assert.equal(addUserCallEvent(card, { at: 999, userId: 'loop', name: 'x', kind: 'join' }), card);
  card = addUserCallEvent(card, { at: 1000, userId: 'b', name: 'b', kind: 'join' });
  assert.equal(card.events.at(-1).userId, 'b');
  // 시작한 사람은 시작 사건까지 같은 상한에 든다.
  let started = newCallCard({ at: 0, userId: 's', name: 's' });
  for (let i = 0; i < 50; i++) started = addUserCallEvent(started, { at: i, userId: 's', name: 's', kind: 'join' });
  assert.equal(started.events.length, CALL_CARD_MAX_EVENTS_PER_USER);
});

test('거절은 한 통화에 한 번만 — 다시 보내도, 다른 기기에서 또 눌러도 한 번', () => {
  const r = 'decline-room';
  assert.equal(markCallDeclined(r, 'b'), false); // 통화가 없으면 알릴 게 없다.
  joinCall(r, 'a', 's-a');
  assert.equal(markCallDeclined(r, 'a'), false); // 이미 통화에 들어와 있는 사람(건 사람)은 거절이 아니다.
  assert.equal(markCallDeclined(r, 'b'), true);
  assert.equal(markCallDeclined(r, 'b'), false);
  assert.equal(markCallDeclined(r, 'c'), true);
  leaveCall(r, 'a', 's-a');
  // 같은 방에서 새로 건 통화는 다시 거절할 수 있다.
  joinCall(r, 'a', 's-a');
  assert.equal(markCallDeclined(r, 'b'), true);
  leaveCall(r, 'a', 's-a');
});
