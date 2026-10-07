// 팀에서 제외될 때 그 팀의 모든 방에서 빼는 쿼리(db/queries/rooms.js removeMemberFromTeamRooms·removeMemberFromRoom)와
// 서버를 켤 때 팀 밖에 남은 멤버십을 찾아 빼는 쿼리(listLeftoverTeamRoomMembers, leftoverOnly) 단위 테스트 —
// `node --test test/teamRemoval.test.js` (DB·서버 없이 돈다). drizzle의 실제 쿼리 빌더에 SQL을 받아 적는 가짜 pg 클라이언트를
// 붙여, 어떤 방을 어떻게 잠그고 방 종류마다 무엇을 바꾸는지 본다. 소켓 알림·안내 문구(rooms.js notifyRemovedFromTeamRooms)와
// 서버 시작 때의 정리 순서(teams.js sweepLeftoverTeamRoomMembers)는 DB와 소켓 서버가 있어야 해서 여기서 다루지 않는다.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { getTableColumns } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/node-postgres';

// db/client.js는 접속 주소가 없으면 프로세스를 끝낸다 — 모듈을 불러오기만 하고 그 연결로는 아무것도 묻지 않는다
// (모든 쿼리는 아래 가짜 클라이언트로 간다).
process.env.DATABASE_URL ??= 'postgres://test:test@127.0.0.1:9/unused';
const { listLeftoverTeamRoomMembers, removeMemberFromRoom, removeMemberFromTeamRooms } = await import(
  '../src/db/queries/rooms.js'
);
const { rooms } = await import('../src/db/schema.js');

const ROOM_COLUMNS = Object.keys(getTableColumns(rooms));

/**
 * "방이 걸린 팀의 멤버가 아닌 멤버십" 조건(isLeftoverTeamRoomMembership)이 SQL로 나오는 모양 — 팀 멤버십이 없고, 비밀
 * 대화라면 그 사람이 만든 방이어야 한다(받은 쪽은 다른 팀 사람일 수 있다). [n]은 is_secret에 묶이는 자리 번호.
 */
function leftoverCondition(n) {
  return (
    '(not exists (select 1 from "team_members" where "team_members"."team_id" = "rooms"."team_id" and ' +
    '"team_members"."user_id" = "room_members"."user_id") and ' +
    `("rooms"."is_secret" = $${n} or "rooms"."created_by" = "room_members"."user_id"::text))`
  );
}

/** rooms 행 하나를 pg가 rowMode 'array'로 돌려주는 모양(스키마 열 순서)으로. */
function roomRow(room) {
  return ROOM_COLUMNS.map((key) => room[key] ?? null);
}

function room(id, fields = {}) {
  return {
    id,
    teamId: 'team-1',
    type: 'topic',
    name: null,
    isSecret: false,
    isSelf: false,
    quietLeave: false,
    createdAt: '2026-10-01T00:00:00.000Z',
    ...fields,
  };
}

/**
 * 방·멤버를 기억하는 아주 작은 가짜 DB — removeMemberFromTeamRooms가 내는 쿼리 모양만 알아듣는다. [locked]는 잠금
 * 조회가 돌려줄 방(이미 id 순서), [members]는 방 id → 멤버 id 목록.
 */
function fakeDb({ locked = [], members = {}, folderItems = {} }) {
  const state = {
    rooms: new Map(locked.map((r) => [r.id, { ...r }])),
    members: new Map(Object.entries(members).map(([id, ids]) => [id, new Set(ids)])),
    deletedRooms: [],
    departed: [],
    queries: [],
  };
  const client = {
    async query(config, values = []) {
      const text = typeof config === 'string' ? config : config.text;
      state.queries.push({ text, values });
      if (/^select .* from "rooms" inner join "room_members"/.test(text)) {
        return { rows: [...state.rooms.values()].map(roomRow) };
      }
      if (/^delete from "room_members"/.test(text)) {
        const [roomId, ...userIds] = values;
        const set = state.members.get(roomId) ?? new Set();
        const removed = userIds.filter((id) => set.delete(id));
        return { rows: removed.map((id) => [id]), rowCount: removed.length };
      }
      if (/^delete from "topic_folder_items"/.test(text)) {
        const [roomId, ...userIds] = values;
        const removed = (folderItems[roomId] ?? []).filter((id) => userIds.includes(id));
        return { rows: removed.map((id) => [id]), rowCount: removed.length };
      }
      // 할 일 진척률 다시 맞추기(resyncTodoProgressForMembers) — 이 테스트의 방에는 할 일이 없다.
      if (/ from "todos" /.test(text)) return { rows: [] };
      if (/^select "user_id" from "room_members" where "room_members"\."room_id" = \$1$/.test(text)) {
        return { rows: [...(state.members.get(values[0]) ?? [])].map((id) => [id]) };
      }
      if (/^update "rooms" set "secret_departed_member_id" = \$1, "secret_departed_member_name" = \$2 where "rooms"\."id" = \$3 returning/.test(text)) {
        const [userId, name, roomId] = values;
        state.departed.push({ roomId, userId, name });
        const current = state.rooms.get(roomId);
        if (!current) return { rows: [] };
        Object.assign(current, { secretDepartedMemberId: userId, secretDepartedMemberName: name });
        return { rows: [roomRow(current)] };
      }
      if (/^delete from "rooms" where "rooms"\."id" = \$1$/.test(text)) {
        state.deletedRooms.push(values[0]);
        state.rooms.delete(values[0]);
        return { rows: [], rowCount: 1 };
      }
      throw new Error(`테스트가 모르는 쿼리: ${text}`);
    },
  };
  return { db: drizzle({ client }), state };
}

test('removeMemberFromTeamRooms: 그 사람이 멤버인 그 팀 방을 id 순서로 한 번에 잠근다', async () => {
  const { db, state } = fakeDb({});
  assert.deepEqual(await removeMemberFromTeamRooms(db, 'team-1', 'u1', { departedName: '홍길동' }), []);
  // 방이 없으면 잠금 조회 하나로 끝난다.
  assert.equal(state.queries.length, 1);
  const [lock] = state.queries;
  assert.match(lock.text, /from "rooms" inner join "room_members" on \("room_members"\."room_id" = "rooms"\."id" and "room_members"\."user_id" = \$1\)/);
  assert.match(lock.text, /where "rooms"\."team_id" = \$2 order by "rooms"\."id" asc for no key update of "rooms"$/);
  assert.deepEqual(lock.values, ['u1', 'team-1']);
});

test('removeMemberFromTeamRooms: 토픽·그룹·1:1·나와의 대화·비밀 대화를 종류별로 정리한다', async () => {
  const locked = [
    room('a-topic', { type: 'topic', name: '공지' }),
    room('b-group', { type: 'group' }),
    room('c-dm', { type: 'dm' }),
    room('d-self', { type: 'dm', isSelf: true }),
    room('e-secret', { type: 'dm', isSecret: true }),
    room('f-secret-alone', { type: 'dm', isSecret: true }),
  ];
  const { db, state } = fakeDb({
    locked,
    members: {
      'a-topic': ['u1', 'u2', 'u3'],
      'b-group': ['u1', 'u2'],
      'c-dm': ['u1', 'u2'],
      'd-self': ['u1'],
      // 비밀 대화 상대는 이 팀 멤버가 아닐 수도 있다(다른 팀에서 함께 있는 사람).
      'e-secret': ['u1', 'outsider'],
      // 상대가 이미 먼저 혼자 나간 비밀 대화.
      'f-secret-alone': ['u1'],
    },
    folderItems: { 'a-topic': ['u1'] },
  });

  const removals = await removeMemberFromTeamRooms(db, 'team-1', 'u1', { departedName: '홍길동' });
  const byId = Object.fromEntries(removals.map((r) => [r.room.id, r]));
  assert.deepEqual(
    removals.map((r) => r.room.id),
    locked.map((r) => r.id),
    '잠근 순서대로 모든 방에서 빠진다',
  );
  for (const r of removals) {
    assert.equal(r.removed, true);
    assert.deepEqual(r.changedTodos, []);
    assert.equal(state.members.get(r.room.id)?.has('u1') ?? false, false, `${r.room.id}에 멤버로 남지 않는다`);
  }

  // 토픽·그룹 — 멤버에서만 빠진다(방 행은 그대로, 토픽 폴더 배치는 같이 지워짐).
  assert.deepEqual(byId['a-topic'].remainingMemberIds, ['u2', 'u3']);
  assert.equal(byId['a-topic'].folderItemRemoved, true);
  assert.equal(byId['a-topic'].deleted, false);
  assert.equal(byId['b-group'].folderItemRemoved, false);
  assert.deepEqual(byId['b-group'].remainingMemberIds, ['u2']);

  // 평문 1:1 대화 — 기록은 남기고 남은 쪽이 "홍길동 (나갔음)"으로 보게 이름을 남긴다.
  assert.equal(byId['c-dm'].deleted, false);
  assert.deepEqual(byId['c-dm'].remainingMemberIds, ['u2']);
  assert.equal(byId['c-dm'].room.secretDepartedMemberId, 'u1');
  assert.equal(byId['c-dm'].room.secretDepartedMemberName, '홍길동');

  // 나와의 대화 — 남는 사람이 없지만 지우지 않는다(다시 팀에 들어오면 예전 메모와 함께 돌아온다).
  assert.equal(byId['d-self'].deleted, false);
  assert.deepEqual(byId['d-self'].remainingMemberIds, []);
  assert.equal(byId['d-self'].room.secretDepartedMemberName ?? null, null);

  // 비밀 대화 — 상대가 남으면 혼자 나가기처럼 이름을 남기고, 아무도 안 남으면 방째 지운다.
  assert.equal(byId['e-secret'].deleted, false);
  assert.deepEqual(byId['e-secret'].remainingMemberIds, ['outsider']);
  assert.equal(byId['e-secret'].room.secretDepartedMemberName, '홍길동');
  assert.equal(byId['f-secret-alone'].deleted, true);
  assert.deepEqual(byId['f-secret-alone'].remainingMemberIds, []);

  assert.deepEqual(state.deletedRooms, ['f-secret-alone']);
  assert.deepEqual(
    state.departed.map((d) => d.roomId),
    ['c-dm', 'e-secret'],
    '1:1 대화에만 나간 사람 이름을 남긴다(토픽·그룹·나와의 대화는 방 행을 건드리지 않는다)',
  );
  assert.ok(state.departed.every((d) => d.userId === 'u1' && d.name === '홍길동'));
  // 방을 바꾸기 전에 먼저 잠근다 — 잠금 조회가 맨 처음이고, 그 뒤로는 잠근 방만 건드린다.
  assert.match(state.queries[0].text, /for no key update of "rooms"$/);
  const touched = new Set(state.queries.slice(1).map((q) => q.values[q.text.startsWith('update') ? 2 : 0]));
  assert.deepEqual([...touched].sort(), locked.map((r) => r.id).sort());
});

test('removeMemberFromTeamRooms: 그새 스스로 나간 방은 건너뛰고 그 방은 바꾸지 않는다', async () => {
  // 잠금 조회 뒤에 이미 빠져 있던 경우(잠그지 않는 그룹 나가기와 엇갈림) — 안내가 두 번 남지 않게 결과에서 뺀다.
  const { db, state } = fakeDb({
    locked: [room('a-dm', { type: 'dm' }), room('b-group', { type: 'group' })],
    members: { 'a-dm': ['u2'], 'b-group': ['u1', 'u2'] },
  });
  const removals = await removeMemberFromTeamRooms(db, 'team-1', 'u1', { departedName: '홍길동' });
  assert.deepEqual(
    removals.map((r) => r.room.id),
    ['b-group'],
  );
  assert.deepEqual(state.departed, [], '이미 빠져 있던 1:1 대화에는 이름을 다시 남기지 않는다');
  assert.deepEqual(state.deletedRooms, []);
});

test('listLeftoverTeamRoomMembers: 팀 멤버가 아닌데 그 팀 방에 남은 (팀, 사람) 쌍을 한 번에 고른다', async () => {
  const queries = [];
  const db = drizzle({
    client: {
      async query(config, values = []) {
        queries.push({ text: typeof config === 'string' ? config : config.text, values });
        return { rows: [['team-1', 'u1'], ['team-2', 'u3']] };
      },
    },
  });
  assert.deepEqual(await listLeftoverTeamRoomMembers(db), [
    { teamId: 'team-1', userId: 'u1' },
    { teamId: 'team-2', userId: 'u3' },
  ]);
  assert.equal(queries.length, 1);
  const [{ text, values }] = queries;
  assert.equal(
    text,
    'select distinct "rooms"."team_id", "room_members"."user_id" from "room_members" ' +
      'inner join "rooms" on "rooms"."id" = "room_members"."room_id" ' +
      `where ${leftoverCondition(1)} ` +
      'order by "rooms"."team_id" asc, "room_members"."user_id" asc',
  );
  // 비밀 대화가 아닌 방(is_secret = false)은 누구든, 비밀 대화는 만든 사람만.
  assert.deepEqual(values, [false]);
});

test('removeMemberFromTeamRooms(leftoverOnly): 팀 밖에 남은 방만 같은 잠금·같은 정리로 뺀다', async () => {
  const locked = [
    room('a-topic', { type: 'topic' }),
    room('b-dm', { type: 'dm' }),
    room('c-self', { type: 'dm', isSelf: true }),
    room('d-secret-mine', { type: 'dm', isSecret: true, createdBy: 'u1' }),
  ];
  const { db, state } = fakeDb({
    locked,
    members: { 'a-topic': ['u1', 'u2'], 'b-dm': ['u1', 'u2'], 'c-self': ['u1'], 'd-secret-mine': ['u1', 'u2'] },
  });
  const removals = await removeMemberFromTeamRooms(db, 'team-1', 'u1', { departedName: '홍길동', leftoverOnly: true });

  // 잠그면서 다시 고른다 — 고른 뒤 그새 팀에 다시 들어왔거나, 남이 만든 비밀 대화(받은 쪽은 다른 팀 사람일 수 있다)는
  // 여기서 빠진다. 잠금은 팀에서 뺄 때와 똑같이 id 순서의 FOR NO KEY UPDATE.
  const [lock] = state.queries;
  assert.match(lock.text, /from "rooms" inner join "room_members" on \("room_members"\."room_id" = "rooms"\."id" and "room_members"\."user_id" = \$1\)/);
  assert.ok(
    lock.text.endsWith(
      `where ("rooms"."team_id" = $2 and ${leftoverCondition(3)}) order by "rooms"."id" asc for no key update of "rooms"`,
    ),
    lock.text,
  );
  assert.deepEqual(lock.values, ['u1', 'team-1', false]);

  // 고른 방은 팀에서 뺄 때와 같은 방 종류별 정리를 받는다.
  const byId = Object.fromEntries(removals.map((r) => [r.room.id, r]));
  assert.deepEqual(
    removals.map((r) => r.room.id),
    locked.map((r) => r.id),
  );
  assert.deepEqual(byId['a-topic'].remainingMemberIds, ['u2']);
  assert.equal(byId['b-dm'].room.secretDepartedMemberName, '홍길동');
  assert.equal(byId['c-self'].deleted, false);
  assert.equal(byId['d-secret-mine'].room.secretDepartedMemberName, '홍길동');
  assert.deepEqual(
    state.departed.map((d) => d.roomId),
    ['b-dm', 'd-secret-mine'],
  );
});

test('removeMemberFromRoom: 비밀 대화 혼자 나가기와 같은 규칙 — 상대가 남으면 이름, 아무도 없으면 방째 삭제', async () => {
  const secret = room('s1', { type: 'dm', isSecret: true });

  const withPartner = fakeDb({ locked: [secret], members: { s1: ['u1', 'u2'] } });
  const kept = await removeMemberFromRoom(withPartner.db, secret, 'u1', { departedName: '김철수' });
  assert.equal(kept.removed, true);
  assert.equal(kept.deleted, false);
  assert.equal(kept.room.secretDepartedMemberName, '김철수');
  assert.deepEqual(kept.remainingMemberIds, ['u2']);

  const alone = fakeDb({ locked: [secret], members: { s1: ['u1'] } });
  const gone = await removeMemberFromRoom(alone.db, secret, 'u1', { departedName: '김철수' });
  assert.equal(gone.removed, true);
  assert.equal(gone.deleted, true);
  assert.deepEqual(alone.state.deletedRooms, ['s1']);
  assert.deepEqual(alone.state.departed, []);

  // 이미 나가 있었으면(같은 요청이 두 번 옴) 아무것도 바꾸지 않는다.
  const again = fakeDb({ locked: [secret], members: { s1: ['u2'] } });
  const noop = await removeMemberFromRoom(again.db, secret, 'u1', { departedName: '김철수' });
  assert.equal(noop.removed, false);
  assert.equal(noop.deleted, false);
  assert.deepEqual(again.state.departed, []);
  assert.deepEqual(again.state.deletedRooms, []);
});
