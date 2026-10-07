// 투표 소켓 알림(poll:updated)이 누가 무엇을 골랐는지 방 전체에 흘리지 않는지(S18) — `node --test test/*.test.js`
// (DB·서버 없이 돈다). socket.io의 to/except/emit을 흉내 낸 가짜 io로 "어느 소켓이 무엇을 받는지"까지 본다.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { emitPollVoteUpdate, pollRoomUpdate, toPollDto } from '../src/pollListRules.js';

const ROOM = '0a0a0a0a-0000-4000-8000-000000000001';
const OTHER_ROOM = '0a0a0a0a-0000-4000-8000-000000000002';
const VOTER = '11111111-1111-4111-8111-111111111111';
const COLLEAGUE = '22222222-2222-4222-8222-222222222222';
const GUEST = '33333333-3333-4333-8333-333333333333';
const CREATOR = '44444444-4444-4444-8444-444444444444';
const OUTSIDER = '55555555-5555-4555-8555-555555555555';
const VOTER_NAME = '김익명';
const COLLEAGUE_NAME = '박동료';

/** 소켓들 — 각자 들어가 있는 socket.io 룸. 투표한 사람은 PC·폰, 그리고 방 join이 아직 안 끝난 웹(user 룸만). */
const SOCKETS = [
  { id: 'voter-pc', rooms: [`user:${VOTER}`, ROOM] },
  { id: 'voter-phone', rooms: [`user:${VOTER}`, ROOM] },
  { id: 'voter-web-joining', rooms: [`user:${VOTER}`] },
  { id: 'colleague', rooms: [`user:${COLLEAGUE}`, ROOM] },
  { id: 'guest', rooms: [`user:${GUEST}`, ROOM] },
  { id: 'outsider', rooms: [`user:${OUTSIDER}`, OTHER_ROOM] },
];

/**
 * socket.io 브로드캐스트 흉내 — to의 룸 중 하나에 있고 except의 룸에는 하나도 없는 소켓이 받는다(socket.io 메모리 어댑터와
 * 같은 규칙). 받은 값은 JSON으로 한 번 오간 모양(실제로 선을 타는 값)으로 남긴다.
 */
function fakeIo(sockets = SOCKETS) {
  const received = new Map(sockets.map((s) => [s.id, []]));
  const operator = (to, except) => ({
    to: (room) => operator([...to, room], except),
    except: (room) => operator(to, [...except, room]),
    emit: (event, payload) => {
      for (const s of sockets) {
        if (!to.some((r) => s.rooms.includes(r))) continue;
        if (except.some((r) => s.rooms.includes(r))) continue;
        received.get(s.id).push({ event, payload: JSON.parse(JSON.stringify(payload)) });
      }
    },
  });
  return { io: { to: (room) => operator([room], []) }, received };
}

function pollRow({ anonymous }) {
  return {
    id: 'p1',
    title: '회식 장소',
    description: null,
    anonymous,
    multiple: true,
    closesAt: new Date(Date.now() + 24 * 60 * 60 * 1000),
    closedAt: null,
    creatorId: CREATOR,
  };
}

const OPTIONS = [
  { id: 'o1', pollId: 'p1', text: '한식' },
  { id: 'o2', pollId: 'p1', text: '중식' },
  { id: 'o3', pollId: 'p1', text: '일식' },
];

// 투표한 사람이 o1·o3, 동료가 o1을 골랐다(listVotesForPolls 모양 — 이름이 함께 온다).
const VOTES = [
  { pollId: 'p1', optionId: 'o1', userId: VOTER, name: VOTER_NAME, username: 'kim' },
  { pollId: 'p1', optionId: 'o3', userId: VOTER, name: VOTER_NAME, username: 'kim' },
  { pollId: 'p1', optionId: 'o1', userId: COLLEAGUE, name: COLLEAGUE_NAME, username: 'park' },
];

function vote({ anonymous, optionIds = ['o1', 'o3'], votes = VOTES } = {}) {
  const { io, received } = fakeIo();
  const neutral = toPollDto(pollRow({ anonymous }), OPTIONS, votes); // polls.js의 neutralPollDto와 같은 값(viewerId 없음)
  const sent = emitPollVoteUpdate(io, {
    roomId: ROOM,
    messageId: 'm1',
    pollId: 'p1',
    poll: neutral,
    voterId: VOTER,
    optionIds,
  });
  return { received, neutral, sent };
}

/** 소켓 하나가 받은 poll:updated들. */
function updatesFor(received, socketId) {
  return received.get(socketId).filter((e) => e.event === 'poll:updated').map((e) => e.payload);
}

test('익명 투표 — 방의 다른 사람(게스트 포함)에게는 집계만 가고 누가 무엇을 골랐는지는 어디에도 없다', () => {
  const { received } = vote({ anonymous: true });
  for (const socketId of ['colleague', 'guest']) {
    const updates = updatesFor(received, socketId);
    assert.equal(updates.length, 1, `${socketId}는 한 번만 받는다`);
    const [u] = updates;
    assert.equal(u.roomId, ROOM);
    assert.equal(u.messageId, 'm1');
    assert.equal(u.pollId, 'p1');
    assert.equal(u.actorId, null);
    assert.equal(u.actorOptionIds, null);
    // 표 수는 그대로 보인다(절대값).
    assert.equal(u.poll.voterCount, 2);
    assert.deepEqual(
      u.poll.options.map((o) => [o.id, o.voteCount]),
      [
        ['o1', 2],
        ['o2', 0],
        ['o3', 1],
      ],
    );
    assert.deepEqual(u.poll.myOptionIds, []);
    assert.equal(u.poll.favorite, false);
    // 투표한 사람·동료의 id나 이름, 사람별 목록(voters)이 실려 있지 않다.
    const wire = JSON.stringify(u);
    for (const secret of [VOTER, COLLEAGUE, VOTER_NAME, COLLEAGUE_NAME, '"voters"']) {
      assert.ok(!wire.includes(secret), `${socketId}가 받은 값에 ${secret}가 있으면 안 된다`);
    }
  }
});

test('익명 투표 — 투표한 사람의 기기(방 join 전인 기기 포함)는 본인 선택이 실린 것을 한 번만 받는다', () => {
  const { received, sent } = vote({ anonymous: true });
  for (const socketId of ['voter-pc', 'voter-phone', 'voter-web-joining']) {
    const updates = updatesFor(received, socketId);
    assert.equal(updates.length, 1, `${socketId}는 방 알림과 개인 알림을 겹쳐 받지 않는다`);
    const [u] = updates;
    assert.equal(u.actorId, VOTER);
    assert.deepEqual(u.actorOptionIds, ['o1', 'o3']);
    // 방에 간 것과 같은 집계 — 어느 쪽을 받아도 표 수가 같다(더하는 값이 아니라 그때의 절대값).
    assert.deepEqual(u.poll, sent.room.poll);
    // 본인 기기로 가는 사본에도 남(동료)의 선택은 없다.
    const wire = JSON.stringify(u);
    assert.ok(!wire.includes(COLLEAGUE) && !wire.includes(COLLEAGUE_NAME));
  }
  // 방 멤버가 아닌 사람은 아무것도 받지 않는다.
  assert.deepEqual(received.get('outsider'), []);
});

test('투표 취소 — 내 기기에는 빈 배열(선택을 지우라는 뜻), 방에는 여전히 null', () => {
  const { received } = vote({
    anonymous: true,
    optionIds: [],
    votes: VOTES.filter((v) => v.userId !== VOTER),
  });
  const [mine] = updatesFor(received, 'voter-phone');
  assert.deepEqual(mine.actorOptionIds, []);
  assert.equal(mine.actorId, VOTER);
  assert.equal(mine.poll.voterCount, 1);
  const [theirs] = updatesFor(received, 'colleague');
  assert.equal(theirs.actorId, null);
  assert.equal(theirs.actorOptionIds, null);
  assert.equal(theirs.poll.voterCount, 1);
});

test('기명 투표 — 방 알림의 actorId·actorOptionIds는 똑같이 비우고, 누가 골랐는지는 REST와 같은 voters로만 보인다', () => {
  const { received, neutral } = vote({ anonymous: false });
  const [theirs] = updatesFor(received, 'colleague');
  assert.equal(theirs.actorId, null);
  assert.equal(theirs.actorOptionIds, null);
  // 방 알림의 poll은 toPollDto(보는 사람 없음) 그대로 — 기명 투표라 voters가 있다.
  assert.deepEqual(theirs.poll, JSON.parse(JSON.stringify(neutral)));
  assert.deepEqual(
    theirs.poll.options.find((o) => o.id === 'o1').voters.map((v) => v.name),
    [VOTER_NAME, COLLEAGUE_NAME],
  );
  const [mine] = updatesFor(received, 'voter-pc');
  assert.equal(mine.actorId, VOTER);
  assert.deepEqual(mine.actorOptionIds, ['o1', 'o3']);
});

test('마감 알림(pollRoomUpdate) — 누가 마감했는지·골랐는지 없이 poll만', () => {
  const closed = toPollDto({ ...pollRow({ anonymous: true }), closedAt: new Date() }, OPTIONS, VOTES);
  const payload = pollRoomUpdate({ roomId: ROOM, messageId: 'm1', pollId: 'p1', poll: closed });
  assert.deepEqual(Object.keys(payload).sort(), ['actorId', 'actorOptionIds', 'messageId', 'poll', 'pollId', 'roomId']);
  assert.equal(payload.actorId, null);
  assert.equal(payload.actorOptionIds, null);
  assert.equal(payload.poll.closed, true);
  assert.ok(!JSON.stringify(payload).includes(VOTER));
});

test('toPollDto — 익명 투표는 보는 사람 본인의 선택만 내려 주고 voters 키가 없다(기명은 있다)', () => {
  const forVoter = toPollDto(pollRow({ anonymous: true }), OPTIONS, VOTES, { viewerId: VOTER, favorite: true });
  assert.deepEqual(forVoter.myOptionIds, ['o1', 'o3']);
  assert.equal(forVoter.favorite, true);
  assert.ok(forVoter.options.every((o) => !('voters' in o)));
  const forColleague = toPollDto(pollRow({ anonymous: true }), OPTIONS, VOTES, { viewerId: COLLEAGUE });
  assert.deepEqual(forColleague.myOptionIds, ['o1']);
  assert.ok(!JSON.stringify(forColleague).includes(VOTER));

  const named = toPollDto(pollRow({ anonymous: false }), OPTIONS, VOTES);
  assert.deepEqual(
    named.options.map((o) => o.voters.map((v) => v.userId)),
    [[VOTER, COLLEAGUE], [], [VOTER]],
  );
  // 이름이 없으면 아이디, 그것도 없으면 '알 수 없음'.
  const fallback = toPollDto(pollRow({ anonymous: false }), OPTIONS, [
    { pollId: 'p1', optionId: 'o2', userId: GUEST, name: null, username: 'guest1' },
    { pollId: 'p1', optionId: 'o2', userId: OUTSIDER, name: null, username: null },
  ]);
  assert.deepEqual(
    fallback.options[1].voters.map((v) => v.name),
    ['guest1', '알 수 없음'],
  );
});
