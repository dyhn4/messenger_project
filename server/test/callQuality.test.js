// 화상회의 화질 단계(callQuality.js)와 진행자 규칙(calls.js) 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { videoTierFor } from '../src/callQuality.js';
import { callStateFor, canControlMic, joinCall, leaveCall, refreshVideoTiers } from '../src/callState.js';

test('참가자 수가 늘면 화질 단계가 내려간다 — 방 기준', () => {
  assert.equal(videoTierFor(1, 1), 'fhd');
  assert.equal(videoTierFor(4, 4), 'fhd');
  assert.equal(videoTierFor(5, 5), 'hd');
  assert.equal(videoTierFor(8, 8), 'hd');
  assert.equal(videoTierFor(9, 9), 'sd');
  assert.equal(videoTierFor(16, 16), 'sd');
  assert.equal(videoTierFor(17, 17), 'ld');
});

test('방은 작아도 서버 전체 참가자가 많으면 낮은 쪽을 쓴다', () => {
  assert.equal(videoTierFor(2, 16), 'fhd');
  assert.equal(videoTierFor(2, 17), 'hd');
  assert.equal(videoTierFor(2, 40), 'sd');
  assert.equal(videoTierFor(2, 65), 'ld');
  // 방 기준이 더 낮으면 그쪽.
  assert.equal(videoTierFor(10, 20), 'sd');
});

test('진행자 — 건 사람, 나가면 남은 사람 중 먼저 들어온 사람', () => {
  const room = 'room-host';
  joinCall(room, 'a', 's-a');
  joinCall(room, 'b', 's-b');
  joinCall(room, 'c', 's-c');
  assert.equal(callStateFor(room).hostId, 'a');
  assert.equal(canControlMic(room, 'a', 'b'), true);
  assert.equal(canControlMic(room, 'b', 'c'), false); // 진행자가 아니다.
  assert.equal(canControlMic(room, 'a', 'z'), false); // 통화에 없는 사람.

  leaveCall(room, 'a', 's-a');
  assert.equal(callStateFor(room).hostId, 'b');
  assert.equal(canControlMic(room, 'b', 'c'), true);

  // 건 사람이 다시 들어와도 지금 진행자가 그대로다(진행자가 왔다 갔다 하지 않게).
  joinCall(room, 'a', 's-a2');
  assert.equal(callStateFor(room).hostId, 'b');
  for (const [id, socket] of [
    ['a', 's-a2'],
    ['b', 's-b'],
    ['c', 's-c'],
  ]) {
    leaveCall(room, id, socket);
  }
  assert.equal(callStateFor(room).active, false);
});

test('다른 방에 사람이 늘어 서버 전체 단계가 바뀌면 진행 중인 다른 통화도 다시 알린다', () => {
  joinCall('small', 'x', 's-x');
  joinCall('small', 'y', 's-y');
  assert.equal(callStateFor('small').videoTier, 'fhd');
  refreshVideoTiers(); // 지금 값을 기준으로 맞춰 둔다.

  const big = 'big';
  for (let i = 0; i < 17; i++) joinCall(big, `u${i}`, `s${i}`);
  // 2 + 17 = 19명 → 서버 기준 hd. big(17명)은 방 기준 ld인데, big의 새 상태는 참가할 때마다 이미 나간다(joinCall의 반환값)
  // — 다시 알릴 것은 small뿐이다.
  assert.equal(callStateFor(big).videoTier, 'ld');
  const changed = refreshVideoTiers();
  assert.deepEqual(
    changed.map((s) => [s.roomId, s.videoTier]),
    [['small', 'hd']],
  );
  // 바뀐 게 없으면 다시 알리지 않는다.
  assert.deepEqual(refreshVideoTiers(), []);

  for (let i = 0; i < 17; i++) leaveCall(big, `u${i}`, `s${i}`);
  assert.deepEqual(
    refreshVideoTiers().map((s) => [s.roomId, s.videoTier]),
    [['small', 'fhd']],
  );
  leaveCall('small', 'x', 's-x');
  leaveCall('small', 'y', 's-y');
});
