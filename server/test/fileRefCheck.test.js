// fileRefs.js checkFileRefs(조회를 엮는 쪽)와 db/queries/uploads.js findReachableUploadPaths("지금 볼 수 있는 방의 파일") 단위 테스트 —
// `node --test test/*.test.js` (DB·서버 없이 돈다). 조회 함수는 가짜를 넣고, 쿼리는 drizzle의 실제 쿼리 빌더에 작은 가짜 표를 답하는
// pg 클라이언트를 붙여 본다(접속 주소도 닿지 않는 값으로 정해 둔다 — avatarUpdateResign.test.js와 같은 방식).
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import { drizzle } from 'drizzle-orm/node-postgres';
import { signFileUrl } from '../src/upload.js';

process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused';
const { db } = await import('../src/db/client.js');
for (const method of ['select', 'insert', 'update', 'delete', 'execute', 'transaction']) {
  mock.method(db, method, () => {
    throw new Error(`이 테스트는 DB를 쓰면 안 된다(db.${method})`);
  });
}
const { checkFileRefs, storedFilesAllowed } = await import('../src/fileRefs.js');
const { findReachableUploadPaths } = await import('../src/db/queries/uploads.js');
const { FILE_REF_ERROR, SECRET_FILE_REF_ERROR } = await import('../src/fileRefRules.js');

const ALICE = '11111111-1111-4111-8111-111111111111';
const BOB = '22222222-2222-4222-8222-222222222222';
const A_FILE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.png';
const B_FILE = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.pdf';
const B_THUMB = 'bdbdbdbd-bdbd-4dbd-8dbd-bdbdbdbdbdbd.jpg';
const C_FILE = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg';
const stored = (name) => `/uploads/${name}`;

/** 가짜 조회 — 부른 기록을 남긴다. */
function fakeLookups({ uploaders = {}, reachable = [] } = {}) {
  const calls = { uploaders: [], reachable: [] };
  return {
    calls,
    async findUploaders(names) {
      calls.uploaders.push(names);
      return new Map(names.filter((n) => n in uploaders).map((n) => [n, uploaders[n]]));
    },
    async findReachableUploadPaths(userId, paths) {
      calls.reachable.push({ userId, paths });
      return new Set(paths.filter((p) => reachable.includes(p)));
    },
  };
}

test('checkFileRefs: 방금 올린 파일만 실은 보통 메시지는 올린 사람만 보고 방은 조회하지 않는다', async () => {
  const lookups = fakeLookups({ uploaders: { [A_FILE]: ALICE } });
  const result = await checkFileRefs([stored(A_FILE), null, ''], { senderId: ALICE }, lookups);
  assert.equal(result.ok, true);
  assert.equal(result.paths.get(stored(A_FILE)), stored(A_FILE));
  assert.deepEqual(lookups.calls.uploaders, [[A_FILE]]);
  assert.deepEqual(lookups.calls.reachable, []);
});

test('checkFileRefs: 전달 — 남의 파일만 방까지 확인하고, 볼 수 있으면 원본 경로로 저장한다', async () => {
  const lookups = fakeLookups({ uploaders: { [A_FILE]: ALICE, [B_FILE]: BOB }, reachable: [stored(B_FILE)] });
  const link = signFileUrl(stored(B_FILE), 'b.pdf');
  const result = await checkFileRefs([stored(A_FILE), link], { senderId: ALICE }, lookups);
  assert.equal(result.ok, true);
  assert.equal(result.paths.get(link), stored(B_FILE));
  assert.deepEqual(lookups.calls.reachable, [{ userId: ALICE, paths: [stored(B_FILE)] }]);
});

test('checkFileRefs: 볼 수 없는 남의 파일·알아볼 수 없는 참조는 문구와 함께 거절', async () => {
  const lookups = fakeLookups({ uploaders: { [B_FILE]: BOB } });
  assert.deepEqual(await checkFileRefs([signFileUrl(stored(B_FILE))], { senderId: ALICE }, lookups), {
    ok: false,
    error: FILE_REF_ERROR,
  });
  // 미서명 저장 경로로 온 남의 파일(알아낸 이름)은 방을 찾아보지도 않고 거절한다 — 지어낸 이름으로 표를 훑게 만들지 못하게.
  const reachableToo = fakeLookups({ uploaders: { [B_FILE]: BOB }, reachable: [stored(B_FILE)] });
  assert.deepEqual(await checkFileRefs([stored(B_FILE)], { senderId: ALICE }, reachableToo), {
    ok: false,
    error: FILE_REF_ERROR,
  });
  assert.deepEqual(reachableToo.calls.reachable, []);
  // 알아볼 수 없는 참조가 있으면 DB도 보지 않는다.
  const quiet = fakeLookups();
  const bad = await checkFileRefs(['https://evil.example/x.png'], { senderId: ALICE, error: '맞춤 문구' }, quiet);
  assert.deepEqual(bad, { ok: false, error: '맞춤 문구' });
  assert.deepEqual(quiet.calls, { uploaders: [], reachable: [] });
});

test('checkFileRefs: 비밀 대화는 직접 올린 파일만 — 방 조회 없이, 비밀 대화 문구로 거절', async () => {
  const lookups = fakeLookups({ uploaders: { [B_FILE]: BOB }, reachable: [stored(B_FILE)] });
  const result = await checkFileRefs([signFileUrl(stored(B_FILE))], { senderId: ALICE, ownedOnly: true }, lookups);
  assert.deepEqual(result, { ok: false, error: SECRET_FILE_REF_ERROR });
  assert.deepEqual(lookups.calls.reachable, []);
});

test('checkFileRefs: 고치기 — 원래 있던 경로는 조회하지 않고 받는다', async () => {
  const lookups = fakeLookups();
  const result = await checkFileRefs([stored(B_FILE)], { senderId: ALICE, existing: [stored(B_FILE)] }, lookups);
  assert.equal(result.ok, true);
  assert.deepEqual(lookups.calls, { uploaders: [], reachable: [] });
});

test('storedFilesAllowed: 예약 메시지 — 기록 없는 옛 파일은 보내고, 남이 올린 파일은 안 보낸다', async () => {
  const lookups = fakeLookups({ uploaders: { [A_FILE]: ALICE, [B_FILE]: BOB } });
  assert.equal(await storedFilesAllowed([stored(A_FILE), stored(C_FILE)], { senderId: ALICE }, lookups), true);
  assert.equal(await storedFilesAllowed([stored(B_FILE)], { senderId: ALICE }, lookups), false);
  assert.equal(await storedFilesAllowed([], { senderId: ALICE }, lookups), true);
});

// ── findReachableUploadPaths — 실제 쿼리 빌더 + 가짜 표 ──────────────────

/**
 * 이 테스트 동안 db.select를 가짜 표로 답하는 drizzle로 돌린다. [tables]는 표 이름 → { roomId, fileUrl, thumbnailUrl, deleted?,
 * shownAt? } 목록(쿼리가 지운 행을 거르는지는 SQL 글에서 본다 — shownAt은 1:1 "진짜 나가기" 하한과 견주는 시각: 메시지·첨부는 메시지,
 * 댓글은 부모 메시지, 앨범 항목은 앨범의 시각), [members]는 { userId, roomId }, [secretRooms]는 비밀 대화방 id들(쿼리에 "비밀 대화
 * 아님" 조건이 있을 때만 거른다), [floors]는 { userId, roomId, hiddenBeforeAt }(쿼리가 그 사람의 하한을 LEFT JOIN할 때만 거른다).
 * 받은 SQL은 [seen]에 남긴다.
 */
function fakeTables(t, { tables = {}, members = [], secretRooms = [], floors = [] }) {
  const seen = [];
  const fake = drizzle({
    client: {
      async query(config, values = []) {
        const text = typeof config === 'string' ? config : config.text;
        seen.push(text);
        const from = /^select .* from "(\w+)"/.exec(text)?.[1];
        if (from === 'room_members') {
          const [userId, ...rest] = values;
          const roomIds = rest.filter((v) => typeof v === 'string');
          const notSecret = /"rooms"\."is_secret" = \$\d+/.test(text) && rest.includes(false);
          return {
            rows: members
              .filter((m) => m.userId === userId && roomIds.includes(m.roomId))
              .filter((m) => !notSecret || !secretRooms.includes(m.roomId))
              .map((m) => [m.roomId]),
          };
        }
        if (from in tables) {
          const wanted = new Set(values.filter((v) => typeof v === 'string' && v.startsWith('/uploads/')));
          // 하한은 쿼리가 그 사람(user_id 자리의 값)의 dm_history_floors를 붙이고 "하한 이후" 조건을 걸었을 때만 적용한다.
          const floorUserParam = /left join "dm_history_floors" on \(.*"dm_history_floors"\."user_id" = \$(\d+)\)/.exec(text)?.[1];
          const floorUser = floorUserParam && /"hidden_before_at" is null or .* >= "dm_history_floors"\."hidden_before_at"/.test(text)
            ? values[Number(floorUserParam) - 1]
            : null;
          const hiddenBefore = (roomId) => floors.find((f) => f.userId === floorUser && f.roomId === roomId)?.hiddenBeforeAt;
          const rows = tables[from]
            .filter((r) => !r.deleted && (wanted.has(r.fileUrl) || wanted.has(r.thumbnailUrl)))
            .filter((r) => !hiddenBefore(r.roomId) || (r.shownAt && r.shownAt >= hiddenBefore(r.roomId)))
            .map((r) => [r.roomId, r.fileUrl, r.thumbnailUrl ?? null]);
          return { rows };
        }
        throw new Error(`테스트가 모르는 쿼리: ${text}`);
      },
    },
  });
  t.mock.method(db, 'select', (...args) => fake.select(...args));
  return seen;
}

test('findReachableUploadPaths: 내가 멤버인 방의 메시지·첨부·댓글·앨범 파일만 — 나간 방·다른 방은 빠진다', async (t) => {
  const seen = fakeTables(t, {
    tables: {
      messages: [{ roomId: 'r-in', fileUrl: stored(A_FILE), thumbnailUrl: null }],
      message_attachments: [{ roomId: 'r-out', fileUrl: stored(B_FILE), thumbnailUrl: stored(B_THUMB) }],
      message_comments: [{ roomId: 'r-in', fileUrl: stored(C_FILE), thumbnailUrl: null, deleted: true }],
      album_items: [{ roomId: 'r-album', fileUrl: stored(B_THUMB), thumbnailUrl: null }],
    },
    members: [
      { userId: ALICE, roomId: 'r-in' },
      { userId: ALICE, roomId: 'r-album' },
      { userId: BOB, roomId: 'r-out' },
    ],
  });
  const reachable = await findReachableUploadPaths(ALICE, [stored(A_FILE), stored(B_FILE), stored(B_THUMB), stored(C_FILE)]);
  // A: 내 방의 메시지. B_THUMB: 다른 방의 첨부 미리보기이기도 하지만 내 방의 앨범 항목이다. B: 나만 없는 방. C: 지운 댓글.
  assert.deepEqual([...reachable].sort(), [stored(A_FILE), stored(B_THUMB)].sort());

  // 지운 메시지·파일·첨부·댓글은 쿼리 단계에서 거른다(지운 뒤에도 예전 링크로 다시 실을 수 있던 문제를 막는다).
  const sql = seen.join('\n');
  assert.match(sql, /from "messages" left join .* where .*"messages"\."deleted_at" is null.*"messages"\."file_deleted_at" is null/);
  assert.match(sql, /from "message_attachments" inner join "messages".*"message_attachments"\."deleted_at" is null/);
  assert.match(sql, /from "message_comments" inner join "messages" .* where .*"message_comments"\."deleted_at" is null/);
  assert.match(sql, /from "album_items" inner join "albums"/);
  assert.match(sql, /from "room_members" inner join "rooms" .* where \("room_members"\."user_id" = \$1 and "room_members"\."room_id" in/);
});

test('findReachableUploadPaths: 1:1 "진짜 나가기" 이전 글의 파일은 빠진다 — 댓글은 부모 메시지, 앨범은 앨범 시각으로 본다', async (t) => {
  const floor = new Date('2026-09-01T00:00:00Z');
  const before = new Date('2026-08-01T00:00:00Z');
  const after = new Date('2026-09-15T00:00:00Z');
  const D_FILE = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd.png';
  const E_FILE = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee.png';
  const F_FILE = 'ffffffff-ffff-4fff-8fff-ffffffffffff.png';
  const seen = fakeTables(t, {
    tables: {
      // 하한 전 메시지의 파일(빠진다)과 하한 뒤 메시지의 파일(남는다).
      messages: [
        { roomId: 'dm', fileUrl: stored(A_FILE), thumbnailUrl: null, shownAt: before },
        { roomId: 'dm', fileUrl: stored(B_FILE), thumbnailUrl: null, shownAt: after },
      ],
      message_attachments: [{ roomId: 'dm', fileUrl: stored(C_FILE), thumbnailUrl: null, shownAt: before }],
      // 하한 뒤에 달았어도 부모 메시지가 하한 전이면 화면에 안 보이는 댓글이다(빠진다).
      message_comments: [{ roomId: 'dm', fileUrl: stored(D_FILE), thumbnailUrl: null, shownAt: before }],
      album_items: [
        { roomId: 'dm', fileUrl: stored(E_FILE), thumbnailUrl: null, shownAt: before },
        { roomId: 'dm', fileUrl: stored(F_FILE), thumbnailUrl: null, shownAt: after },
      ],
    },
    members: [{ userId: ALICE, roomId: 'dm' }],
    // 하한은 사람마다 따로다 — 같은 방의 상대(BOB)에게는 하한이 없다.
    floors: [{ userId: ALICE, roomId: 'dm', hiddenBeforeAt: floor }],
  });
  const all = [A_FILE, B_FILE, C_FILE, D_FILE, E_FILE, F_FILE].map(stored);
  assert.deepEqual([...(await findReachableUploadPaths(ALICE, all))].sort(), [stored(B_FILE), stored(F_FILE)].sort());

  // 표마다 화면에 보이는지를 정하는 시각과 견준다.
  const sql = seen.join('\n');
  const atLeastFloor = (column) => `${column} >= "dm_history_floors"\\."hidden_before_at"`;
  assert.match(
    sql,
    new RegExp(`from "messages" left join "dm_history_floors" on .* where .*${atLeastFloor('"messages"\\."created_at"')}`),
  );
  assert.match(
    sql,
    new RegExp(`from "message_attachments" inner join "messages" .* left join "dm_history_floors" .* where .*${atLeastFloor('"messages"\\."created_at"')}`),
  );
  assert.match(
    sql,
    new RegExp(
      `from "message_comments" inner join "messages" on .* left join "dm_history_floors" on \\("dm_history_floors"\\."room_id" = "message_comments"\\."room_id" .* where .*${atLeastFloor('"messages"\\."created_at"')}`,
    ),
  );
  assert.match(
    sql,
    new RegExp(`from "album_items" inner join "albums" .* left join "dm_history_floors" .* where .*${atLeastFloor('"albums"\\."created_at"')}`),
  );

  // 상대(BOB)에게는 같은 파일들이 그대로 보인다.
  fakeTables(t, {
    tables: {
      messages: [{ roomId: 'dm', fileUrl: stored(A_FILE), thumbnailUrl: null, shownAt: before }],
      message_attachments: [],
      message_comments: [],
      album_items: [],
    },
    members: [{ userId: BOB, roomId: 'dm' }],
    floors: [{ userId: ALICE, roomId: 'dm', hiddenBeforeAt: floor }],
  });
  assert.deepEqual([...(await findReachableUploadPaths(BOB, [stored(A_FILE)]))], [stored(A_FILE)]);
});

test('findReachableUploadPaths: 비밀 대화의 파일(그 방 키로만 풀리는 암호문)은 다른 방으로 실을 수 있는 파일로 치지 않는다', async (t) => {
  fakeTables(t, {
    tables: {
      messages: [
        { roomId: 'secret', fileUrl: stored(A_FILE), thumbnailUrl: stored(B_THUMB) },
        { roomId: 'r-in', fileUrl: stored(C_FILE), thumbnailUrl: null },
      ],
      message_attachments: [],
      message_comments: [],
      album_items: [],
    },
    members: [
      { userId: ALICE, roomId: 'secret' },
      { userId: ALICE, roomId: 'r-in' },
    ],
    secretRooms: ['secret'],
  });
  const reachable = await findReachableUploadPaths(ALICE, [stored(A_FILE), stored(B_THUMB), stored(C_FILE)]);
  assert.deepEqual([...reachable], [stored(C_FILE)]);
});

test('findReachableUploadPaths: 후보가 없거나 실린 방이 없으면 방 멤버 조회도 하지 않는다', async (t) => {
  const seen = fakeTables(t, { tables: { messages: [], message_attachments: [], message_comments: [], album_items: [] } });
  assert.deepEqual([...(await findReachableUploadPaths(ALICE, []))], []);
  assert.equal(seen.length, 0);
  assert.deepEqual([...(await findReachableUploadPaths(ALICE, [stored(A_FILE)]))], []);
  assert.equal(seen.some((s) => s.includes('"room_members"')), false);
});
