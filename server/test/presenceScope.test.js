// 접속 상태 알림 범위(presence.js broadcastPresence) 단위 테스트 — 같은 팀 사람에게만, 팀이 없으면 아무에게도. 가짜 io·가짜
// 팀 조회로 `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { broadcastPresence, isOnline, markConnected, markDisconnected } from '../src/presence.js';

function fakeIo() {
  const sent = [];
  return {
    sent,
    to(rooms) {
      return { emit: (event, payload) => sent.push({ rooms, event, payload }) };
    },
  };
}

/** 팀 조회 가짜 — [release]를 부를 때까지 끝나지 않게 할 수 있다(조회가 끝나는 순서를 바꿔 보려고). */
function deferredLookup(ids) {
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  const fn = async () => {
    await gate;
    return ids;
  };
  return { fn, release: () => release() };
}

test('같은 팀 사람들(user:<id> 방)에게만 보낸다 — 서버 전체가 아니라', async () => {
  const io = fakeIo();
  assert.equal(markConnected('pres-a'), true);
  await broadcastPresence(io, 'pres-a', async (userId) => {
    assert.equal(userId, 'pres-a');
    return ['pres-a', 'pres-teammate-1', 'pres-teammate-2'];
  });
  assert.deepEqual(io.sent, [
    {
      rooms: ['user:pres-a', 'user:pres-teammate-1', 'user:pres-teammate-2'],
      event: 'presence:update',
      payload: { userId: 'pres-a', online: true },
    },
  ]);
  markDisconnected('pres-a');
});

test('팀이 하나도 없으면 아무에게도 안 보낸다 — io.to([])는 socket.io에서 "모두에게"라 부르지도 않는다', async () => {
  let toCalled = false;
  const io = {
    to() {
      toCalled = true;
      return { emit() {} };
    },
  };
  markConnected('pres-guest');
  await broadcastPresence(io, 'pres-guest', async () => []);
  assert.equal(toCalled, false);
  markDisconnected('pres-guest');
});

test('붙자마자 끊겨 조회 순서가 뒤바뀌어도 마지막 알림은 실제 상태(오프라인)', async () => {
  const io = fakeIo();
  const slow = deferredLookup(['pres-b', 'pres-c']);
  // 접속 → 조회가 늦게 끝난다.
  assert.equal(markConnected('pres-b'), true);
  const online = broadcastPresence(io, 'pres-b', slow.fn);
  // 그 사이 끊김 → 이쪽 조회가 먼저 끝난다.
  assert.equal(markDisconnected('pres-b'), true);
  await broadcastPresence(io, 'pres-b', async () => ['pres-b', 'pres-c']);
  slow.release();
  await online;

  assert.equal(isOnline('pres-b'), false);
  assert.deepEqual(
    io.sent.map((m) => m.payload),
    [
      { userId: 'pres-b', online: false },
      { userId: 'pres-b', online: false },
    ],
  );
});

test('여러 기기 — 첫 연결과 마지막 연결에서만 바뀐 것으로 친다(그때만 알린다)', () => {
  assert.equal(markConnected('pres-multi'), true);
  assert.equal(markConnected('pres-multi'), false);
  assert.equal(markDisconnected('pres-multi'), false);
  assert.equal(isOnline('pres-multi'), true);
  assert.equal(markDisconnected('pres-multi'), true);
  assert.equal(isOnline('pres-multi'), false);
});
