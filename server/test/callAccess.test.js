// 통화 자격을 잃은 사람 내보내기(callAccess.js removeFromCallsWith·endRoomCallWith, callState.js removeUserFromCalls)와 내보낸
// 뒤 남은 토큰으로 다시 붙는 연결 막기(createCallRevocations) 단위 테스트 — 가짜 LiveKit 클라이언트·가짜 io로
// `node --test test/*.test.js` (DB·LiveKit·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  CALL_REVOKE_WINDOW_MS,
  consumeCallToken,
  createCallRevocations,
  endRoomCallWith,
  hasCallToken,
  isLivekitNotFound,
  recordCallToken,
  removeFromCallsWith,
} from '../src/callAccess.js';
import { callStateFor, canControlMic, joinCall, leaveCall, removeUserFromCalls } from '../src/callState.js';

function fakeIo() {
  const sent = [];
  return {
    sent,
    to(room) {
      return { emit: (event, payload) => sent.push({ room, event, payload }) };
    },
  };
}

function notFound() {
  return Object.assign(new Error('participant not found'), { status: 404, code: 'not_found' });
}

/**
 * RoomServiceClient와 같은 모양의 가짜 — 부른 내용을 남긴다. [rooms]는 지금 열린 LiveKit 방, [participants]는 방 이름 →
 * 붙어 있는 identity 목록.
 */
function fakeLivekit({
  rooms = [],
  participants = {},
  failList = false,
  failParticipants = [],
  failRemove = [],
  missing = [],
} = {}) {
  const calls = { listRooms: [], listParticipants: [], removeParticipant: [], deleteRoom: [] };
  return {
    calls,
    async listRooms(names) {
      calls.listRooms.push(names);
      if (failList) throw new Error('connect ECONNREFUSED 127.0.0.1:7880');
      return rooms.filter((r) => !names || names.includes(r.name));
    },
    async listParticipants(room) {
      calls.listParticipants.push(room);
      if (failParticipants.includes(room)) throw new Error('connect ECONNREFUSED 127.0.0.1:7880');
      return (participants[room] ?? []).map((identity) => ({ identity }));
    },
    async removeParticipant(room, identity, opts) {
      calls.removeParticipant.push({ room, identity, opts });
      if (missing.includes(room)) throw notFound();
      if (failRemove.includes(room)) throw new Error('connect ECONNREFUSED 127.0.0.1:7880');
    },
    async deleteRoom(room) {
      calls.deleteRoom.push(room);
    },
  };
}

function recorder() {
  const calls = [];
  const fn = async (io, state, userId, wasIn) => {
    calls.push({ state, userId, wasIn });
  };
  fn.calls = calls;
  return fn;
}

/** console.error를 잠깐 가로채 무엇이 찍혔는지 본다(실패를 남기고 계속하는지). */
async function captureErrors(run) {
  const original = console.error;
  const logged = [];
  console.error = (...args) => logged.push(args.join(' '));
  try {
    await run();
  } finally {
    console.error = original;
  }
  return logged;
}

/** console.error·console.warn을 잠깐 가로챈다 — 다시 붙은 사람을 내보낸 기록(warn)과 실패(error)를 따로 본다. */
async function captureLogs(run) {
  const original = { error: console.error, warn: console.warn };
  const logs = { errors: [], warnings: [] };
  console.error = (...args) => logs.errors.push(args.join(' '));
  console.warn = (...args) => logs.warnings.push(args.join(' '));
  try {
    await run();
  } finally {
    Object.assign(console, original);
  }
  return logs;
}

test('진행자를 내보내면 통화에서 빠지고, 진행자가 넘어가고, LiveKit에서도 내보낸다', async () => {
  const r = 'acc-host';
  // PC로 들어왔다가 폰으로 옮겨 참여했다 — 폰 소켓이 PC 소켓 자리를 대신한다(callState.js joinCall).
  joinCall(r, 'host', 's-host-pc');
  joinCall(r, 'host', 's-host-phone');
  joinCall(r, 'b', 's-b');
  joinCall(r, 'c', 's-c');
  assert.equal(canControlMic(r, 'host', 'b'), true);

  const io = fakeIo();
  const livekit = fakeLivekit({ rooms: [{ name: r, numParticipants: 3 }] });
  const afterLeave = recorder();
  const states = await removeFromCallsWith({ livekit, afterLeave, now: () => 1_700_000_000_500 }, io, 'host', { roomIds: [r] });

  assert.equal(states.length, 1);
  const state = callStateFor(r);
  assert.deepEqual(state.participantIds, ['b', 'c']);
  assert.equal(state.hostId, 'b'); // 남은 사람 중 먼저 들어온 사람.
  assert.equal(canControlMic(r, 'host', 'b'), false); // 더는 남의 마이크를 못 끈다.
  assert.equal(canControlMic(r, 'b', 'c'), true);

  // 방 사람들에게 바뀐 상태를 알렸다.
  const notices = io.sent.filter((m) => m.room === r && m.event === 'call:state');
  assert.equal(notices.length, 1);
  assert.deepEqual(notices[0].payload.participantIds, ['b', 'c']);

  // LiveKit — 그 방에서만, 이 서버 시계로 1초 뒤까지 받은 토큰을 무효로.
  assert.deepEqual(livekit.calls.listRooms, [[r]]);
  assert.deepEqual(livekit.calls.removeParticipant, [{ room: r, identity: 'host', opts: { revokeTokenTs: 1_700_000_001n } }]);

  // 카드는 보통 나가기처럼("나감").
  assert.equal(afterLeave.calls.length, 1);
  assert.equal(afterLeave.calls[0].userId, 'host');
  assert.equal(afterLeave.calls[0].wasIn, true);
  assert.equal(afterLeave.calls[0].state.ended, undefined);

  // 그 사람의 기기 소켓들이 나중에 끊겨도(끊김 유예 뒤 정리) 아무 일도 없다.
  assert.equal(leaveCall(r, 'host', 's-host-phone').participantIds.length, 2);
  assert.equal(leaveCall(r, 'host', 's-host-pc').participantIds.length, 2);
  leaveCall(r, 'b', 's-b');
  leaveCall(r, 'c', 's-c');
});

test('방 범위를 주면 그 방 통화에서만 — 다른 방 통화와 그 방의 LiveKit은 건드리지 않는다', async () => {
  joinCall('acc-scope-a', 'u', 's-u');
  joinCall('acc-scope-a', 'x', 's-x');
  joinCall('acc-scope-b', 'u', 's-u');
  joinCall('acc-scope-b', 'y', 's-y');

  const livekit = fakeLivekit({
    rooms: [
      { name: 'acc-scope-a', numParticipants: 2 },
      { name: 'acc-scope-b', numParticipants: 2 },
    ],
  });
  await removeFromCallsWith({ livekit, afterLeave: recorder() }, fakeIo(), 'u', { roomIds: ['acc-scope-a'] });

  assert.deepEqual(callStateFor('acc-scope-a').participantIds, ['x']);
  assert.deepEqual(callStateFor('acc-scope-b').participantIds, ['u', 'y']);
  assert.deepEqual(
    livekit.calls.removeParticipant.map((c) => c.room),
    ['acc-scope-a'],
  );

  for (const [room, user] of [
    ['acc-scope-a', 'x'],
    ['acc-scope-b', 'u'],
    ['acc-scope-b', 'y'],
  ]) {
    leaveCall(room, user, `s-${user}`);
  }
});

test('범위를 안 주면(정지·탈퇴) 모든 통화에서, 우리 통화 상태에 없는 LiveKit 연결까지 끊는다', async () => {
  joinCall('acc-all-a', 'v', 's-v');
  joinCall('acc-all-a', 'w', 's-w');
  const livekit = fakeLivekit({
    rooms: [
      { name: 'acc-all-a', numParticipants: 2 },
      // call:join 없이 미디어만 붙었거나, 끊김 유예 뒤 통화 상태에서 빠진 채 남은 연결.
      { name: 'acc-all-media-only', numParticipants: 2 },
      // 빈 방(아무도 없음)에는 묻지 않는다.
      { name: 'acc-all-empty', numParticipants: 0 },
    ],
    missing: ['acc-all-media-only'],
  });
  const io = fakeIo();
  const afterLeave = recorder();
  const logged = await captureErrors(() => removeFromCallsWith({ livekit, afterLeave }, io, 'v'));

  assert.deepEqual(livekit.calls.listRooms, [undefined]); // 열린 방 전부.
  assert.deepEqual(livekit.calls.removeParticipant.map((c) => c.room).sort(), ['acc-all-a', 'acc-all-media-only']);
  // "그런 참가자 없음"은 실패가 아니라 이미 없는 것 — 로그를 남기지 않는다.
  assert.deepEqual(logged, []);
  // 통화 상태에 있던 방만 알리고 카드에 남긴다.
  assert.deepEqual(
    io.sent.filter((m) => m.event === 'call:state' && m.payload.roomId !== 'acc-all-a'),
    [],
  );
  assert.deepEqual(afterLeave.calls.map((c) => c.state.roomId), ['acc-all-a']);
  leaveCall('acc-all-a', 'w', 's-w');
});

test('마지막 참가자를 내보내면 통화가 끝나고 요약이 붙는다', async () => {
  const r = 'acc-last';
  joinCall(r, 'solo', 's-solo');
  const afterLeave = recorder();
  const [state] = await removeFromCallsWith({ livekit: null, afterLeave }, fakeIo(), 'solo', { roomIds: [r] });
  assert.equal(state.active, false);
  assert.equal(state.ended.answered, false);
  assert.deepEqual(state.ended.participantIds, ['solo']);
  assert.equal(callStateFor(r).active, false);
  assert.equal(afterLeave.calls[0].state.ended.startedBy, 'solo');
});

test('LiveKit이 꺼져 있어도 통화 상태·카드는 맞추고, 실패는 남기고 계속한다(던지지 않는다)', async () => {
  const r = 'acc-down';
  joinCall(r, 'p', 's-p');
  joinCall(r, 'q', 's-q');
  const livekit = fakeLivekit({ failList: true, failRemove: [r] });
  const io = fakeIo();
  const afterLeave = recorder();
  const logged = await captureErrors(() => removeFromCallsWith({ livekit, afterLeave }, io, 'p', { roomIds: [r] }));

  assert.deepEqual(callStateFor(r).participantIds, ['q']);
  assert.equal(io.sent.filter((m) => m.event === 'call:state').length, 1);
  // 목록을 못 받아도 우리 통화 상태에 있던 방에서는 내보내기를 시도한다.
  assert.deepEqual(livekit.calls.removeParticipant.map((c) => c.room), [r]);
  assert.equal(afterLeave.calls.length, 1);
  assert.equal(logged.length, 2); // 목록 실패 한 번, 내보내기 실패 한 번.
  leaveCall(r, 'q', 's-q');
});

test('화상회의가 설정 안 된 서버(LiveKit 없음)도 통화 상태는 맞춘다', async () => {
  const r = 'acc-no-livekit';
  joinCall(r, 'm', 's-m');
  joinCall(r, 'n', 's-n');
  await removeFromCallsWith({ livekit: null, afterLeave: recorder() }, fakeIo(), 'n');
  assert.deepEqual(callStateFor(r).participantIds, ['m']);
  leaveCall(r, 'm', 's-m');
});

test('빈 방 범위면 아무것도 안 한다 — LiveKit에 "열린 방 전부"를 묻지 않는다', async () => {
  joinCall('acc-empty-scope', 'e', 's-e');
  const livekit = fakeLivekit({ rooms: [{ name: 'acc-empty-scope', numParticipants: 1 }] });
  const states = await removeFromCallsWith({ livekit, afterLeave: recorder() }, fakeIo(), 'e', { roomIds: [] });
  assert.deepEqual(states, []);
  assert.deepEqual(livekit.calls.listRooms, []);
  assert.deepEqual(callStateFor('acc-empty-scope').participantIds, ['e']);
  leaveCall('acc-empty-scope', 'e', 's-e');
});

test('통화에 없던 사람이면 통화 상태는 그대로', () => {
  joinCall('acc-not-in', 'k', 's-k');
  assert.deepEqual(removeUserFromCalls('stranger'), []);
  assert.deepEqual(callStateFor('acc-not-in').participantIds, ['k']);
  leaveCall('acc-not-in', 'k', 's-k');
});

test('카드 정리가 실패해도 나머지 방은 계속한다', async () => {
  joinCall('acc-card-a', 'z', 's-z');
  joinCall('acc-card-b', 'z', 's-z');
  const seen = [];
  const afterLeave = async (io, state) => {
    seen.push(state.roomId);
    if (state.roomId === 'acc-card-a') throw new Error('db down');
  };
  const logged = await captureErrors(() => removeFromCallsWith({ livekit: null, afterLeave }, fakeIo(), 'z'));
  assert.deepEqual(seen.sort(), ['acc-card-a', 'acc-card-b']);
  assert.equal(logged.length, 1);
  assert.equal(callStateFor('acc-card-a').active, false);
  assert.equal(callStateFor('acc-card-b').active, false);
});

test('토픽 삭제 — 모두 빼고 마지막 상태만 알리고, LiveKit 방째 닫고, 카드를 닫는다', async () => {
  const r = 'acc-delete';
  joinCall(r, 'a', 's-a');
  joinCall(r, 'b', 's-b');
  joinCall(r, 'c', 's-c');
  const io = fakeIo();
  const livekit = fakeLivekit();
  const afterLeave = recorder();
  await endRoomCallWith({ livekit, afterLeave }, io, r);

  assert.equal(callStateFor(r).active, false);
  const notices = io.sent.filter((m) => m.event === 'call:state' && m.room === r);
  assert.equal(notices.length, 1);
  assert.equal(notices[0].payload.active, false);
  assert.deepEqual(livekit.calls.deleteRoom, [r]);
  assert.equal(afterLeave.calls.length, 1);
  assert.ok(afterLeave.calls[0].state.ended);

  // 통화가 없던 방이어도 LiveKit 방은 닫아 본다(call:join 없이 붙은 연결) — 카드는 없다.
  const quiet = recorder();
  const lk2 = fakeLivekit();
  await endRoomCallWith({ livekit: lk2, afterLeave: quiet }, fakeIo(), 'acc-delete-idle');
  assert.deepEqual(lk2.calls.deleteRoom, ['acc-delete-idle']);
  assert.equal(quiet.calls.length, 0);
});

test('LiveKit "없음" 응답 판별', () => {
  assert.equal(isLivekitNotFound(notFound()), true);
  assert.equal(isLivekitNotFound(Object.assign(new Error('x'), { status: 404 })), true);
  assert.equal(isLivekitNotFound(new Error('connect ECONNREFUSED')), false);
  assert.equal(isLivekitNotFound(undefined), false);
});

// ── 내보낸 뒤 남은 토큰으로 다시 붙는 연결 막기 ─────────────────────────

/** LiveKit 토큰 무효화 기준(초) — callAccess.js와 같은 계산(그 시각 + 1초). */
const revokeTs = (ms) => BigInt(Math.floor(ms / 1000) + 1);

test('내보내면 아직 안 쓴 토큰 기록을 지우고(범위 안만), 남은 토큰이 만료될 때까지 지켜본다', async () => {
  recordCallToken('rv-u', 'rv-room');
  recordCallToken('rv-u', 'rv-other');
  const revocations = createCallRevocations();
  await removeFromCallsWith({ livekit: fakeLivekit(), afterLeave: recorder(), revocations }, fakeIo(), 'rv-u', { roomIds: ['rv-room'] });
  assert.equal(hasCallToken('rv-u', 'rv-room'), false);
  assert.equal(hasCallToken('rv-u', 'rv-other'), true);
  assert.equal(revocations.size, 1);
  consumeCallToken('rv-u', 'rv-other');
});

test('토큰만 받아 두었다가 내보내진 뒤 LiveKit에 바로 붙으면 다음 차례에 또 내보낸다 — 그 시각까지의 토큰도 무효로', async () => {
  const t0 = 1_700_000_000_000;
  const revocations = createCallRevocations();
  // 내보낼 때는 아직 붙어 있지 않았다(LiveKit이 "없음"이라 무효가 남지 않는다).
  const atRemoval = fakeLivekit({ missing: ['sw-room'] });
  await removeFromCallsWith({ livekit: atRemoval, afterLeave: recorder(), revocations, now: () => t0 }, fakeIo(), 'sw-u', { roomIds: ['sw-room'] });
  assert.deepEqual(atRemoval.calls.removeParticipant, []); // 통화 상태에도 LiveKit 방 목록에도 없었다.

  // 30초 뒤 남은 토큰으로 붙었다.
  const lk = fakeLivekit({
    rooms: [
      { name: 'sw-room', numParticipants: 2 },
      { name: 'sw-elsewhere', numParticipants: 1 },
    ],
    participants: { 'sw-room': ['sw-u', 'sw-x'], 'sw-elsewhere': ['sw-u'] },
  });
  const logs = await captureLogs(() => revocations.sweep(lk, t0 + 30_000));
  assert.deepEqual(lk.calls.removeParticipant, [{ room: 'sw-room', identity: 'sw-u', opts: { revokeTokenTs: revokeTs(t0 + 30_000) } }]);
  // 범위 밖 방(sw-elsewhere — 여전히 멤버인 방)은 참가자 목록도 보지 않는다.
  assert.deepEqual(lk.calls.listParticipants, ['sw-room']);
  assert.equal(logs.warnings.length, 1); // 운영자가 알 수 있게 남긴다.
  assert.deepEqual(logs.errors, []);

  // 토큰이 모두 만료될 때가 지나면 더 보지 않는다(LiveKit에 묻지도 않는다).
  const later = fakeLivekit({ rooms: [{ name: 'sw-room', numParticipants: 1 }], participants: { 'sw-room': ['sw-u'] } });
  await revocations.sweep(later, t0 + CALL_REVOKE_WINDOW_MS + 1);
  assert.equal(revocations.size, 0);
  assert.deepEqual(later.calls.listRooms, []);
  assert.deepEqual(later.calls.removeParticipant, []);
});

test('내보낼 때 LiveKit이 잠깐 응답하지 않아 못 끊었어도 다음 차례에 끊는다', async () => {
  const r = 'retry-room';
  joinCall(r, 'retry-u', 's-retry-u');
  joinCall(r, 'retry-v', 's-retry-v');
  const revocations = createCallRevocations();
  const down = fakeLivekit({ failList: true, failRemove: [r] });
  await captureErrors(() => removeFromCallsWith({ livekit: down, afterLeave: recorder(), revocations, now: () => 1_000 }, fakeIo(), 'retry-u', { roomIds: [r] }));
  assert.deepEqual(callStateFor(r).participantIds, ['retry-v']); // 통화 상태는 바로 맞았다.

  const back = fakeLivekit({ rooms: [{ name: r, numParticipants: 2 }], participants: { [r]: ['retry-u', 'retry-v'] } });
  await captureLogs(() => revocations.sweep(back, 6_000));
  assert.deepEqual(back.calls.removeParticipant.map((c) => c.identity), ['retry-u']);
  leaveCall(r, 'retry-v', 's-retry-v');
});

test('그 뒤 자격을 다시 얻어 새 토큰을 받은 사람은 건드리지 않고, 다시 잃으면 다시 내보낸다', async () => {
  const t0 = Date.now();
  const revocations = createCallRevocations();
  const deps = { livekit: fakeLivekit(), afterLeave: recorder(), revocations };
  await removeFromCallsWith({ ...deps, now: () => t0 - 10_000 }, fakeIo(), 'ex-u', { roomIds: ['ex-room'] });
  recordCallToken('ex-u', 'ex-room', t0); // 다시 초대돼 토큰을 받았다(토큰 발급이 멤버임을 확인했다).
  const lk = () => fakeLivekit({ rooms: [{ name: 'ex-room', numParticipants: 1 }], participants: { 'ex-room': ['ex-u'] } });

  const first = lk();
  await revocations.sweep(first, t0 + 5_000);
  assert.deepEqual(first.calls.removeParticipant, []);

  // 또 내보내졌다 — 새 항목은 그 뒤에 받은 토큰이 없으니 내보낸다(먼저 항목의 "다시 얻음"은 이 항목에 안 번진다).
  await removeFromCallsWith({ ...deps, now: () => t0 + 10_000 }, fakeIo(), 'ex-u', { roomIds: ['ex-room'] });
  const second = lk();
  await captureLogs(() => revocations.sweep(second, t0 + 15_000));
  assert.deepEqual(second.calls.removeParticipant.map((c) => [c.room, c.identity]), [['ex-room', 'ex-u']]);
});

test('범위 없이(정지·탈퇴) 지켜보면 어느 방에 다시 붙어도 내보낸다 — 여러 항목이 같은 사람을 봐도 한 번만, 빈 방은 안 본다', async () => {
  const t0 = 1_700_000_100_000;
  const revocations = createCallRevocations();
  revocations.watchUser('all-u', null, t0);
  revocations.watchUser('all-u', ['all-a'], t0); // 방에서 내보낸 뒤 계정도 정지했다.
  const lk = fakeLivekit({
    rooms: [
      { name: 'all-a', numParticipants: 1 },
      { name: 'all-b', numParticipants: 2 },
      { name: 'all-empty', numParticipants: 0 },
    ],
    participants: { 'all-a': ['all-u'], 'all-b': ['someone', 'all-u'] },
  });
  await captureLogs(() => revocations.sweep(lk, t0 + 1_000));
  assert.deepEqual(lk.calls.removeParticipant.map((c) => c.room).sort(), ['all-a', 'all-b']);
  assert.deepEqual(lk.calls.listParticipants.sort(), ['all-a', 'all-b']);
});

test('지워진 토픽의 회의방이 남은 토큰으로 다시 열리면 방째 닫는다 — 그 방 토큰 기록도 지운다', async () => {
  recordCallToken('del-x', 'del-room');
  const revocations = createCallRevocations();
  await endRoomCallWith({ livekit: fakeLivekit(), afterLeave: recorder(), revocations, now: () => 5_000 }, fakeIo(), 'del-room');
  assert.equal(hasCallToken('del-x', 'del-room'), false);
  assert.equal(revocations.size, 1);

  const reopened = fakeLivekit({
    rooms: [
      { name: 'del-room', numParticipants: 1 },
      { name: 'del-live', numParticipants: 3 },
    ],
    participants: { 'del-room': ['del-x'], 'del-live': ['p', 'q', 'r'] },
  });
  await captureLogs(() => revocations.sweep(reopened, 10_000));
  assert.deepEqual(reopened.calls.deleteRoom, ['del-room']);
  // 지켜보는 사람이 없는 방은 참가자 목록도 보지 않는다.
  assert.deepEqual(reopened.calls.listParticipants, []);
});

test('훑다가 LiveKit이 실패하면 그 방만 남기고 계속한다 — 방 목록부터 못 받으면 던진다(다음 차례에 다시 본다)', async () => {
  const revocations = createCallRevocations();
  revocations.watchUser('err-u', null, 0);
  await assert.rejects(revocations.sweep(fakeLivekit({ failList: true }), 1_000));
  assert.equal(revocations.size, 1);

  const lk = fakeLivekit({
    rooms: [
      { name: 'err-a', numParticipants: 1 },
      { name: 'err-b', numParticipants: 1 },
      { name: 'err-c', numParticipants: 1 },
    ],
    participants: { 'err-b': ['err-u'], 'err-c': ['err-u'] },
    failParticipants: ['err-a'],
    failRemove: ['err-b'],
    missing: ['err-c'],
  });
  const logs = await captureLogs(() => revocations.sweep(lk, 2_000));
  assert.deepEqual(lk.calls.removeParticipant.map((c) => c.room).sort(), ['err-b', 'err-c']);
  // err-a 참가자 목록 실패, err-b 내보내기 실패 — err-c는 그새 나간 것("없음")이라 실패가 아니다.
  assert.equal(logs.errors.length, 2);
  assert.deepEqual(logs.warnings, []);
});

test('화상회의가 설정 안 된 서버(LiveKit 없음)면 지켜볼 것도 없다', async () => {
  const revocations = createCallRevocations();
  await removeFromCallsWith({ livekit: null, afterLeave: recorder(), revocations }, fakeIo(), 'nolk-u');
  await endRoomCallWith({ livekit: null, afterLeave: recorder(), revocations }, fakeIo(), 'nolk-room');
  assert.equal(revocations.size, 0);
  revocations.watchUser('nolk-u', null, 0);
  await revocations.sweep(null, 1);
  assert.equal(revocations.size, 0);
});
