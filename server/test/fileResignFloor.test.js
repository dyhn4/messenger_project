// /files/resign(fileResign.js)의 1:1 "진짜 나가기" 시작선(dm_history_floors) 단위 테스트 — `node --test test/fileResignFloor.test.js`
// (DB·서버 없이 돈다). 방 메시지 목록·메시지 한 건·댓글·앨범 목록은 시작선 이전 글을 그 사람에게 보여 주지 않는데, 새 링크 받기는
// 방 멤버인지만 봐서 예전에 받아 둔 링크로 그 글의 파일을 계속 받아 갈 수 있었다. 라우트 처리 함수를 가짜 요청으로 직접 부르고,
// drizzle의 실제 쿼리 빌더에 작은 가짜 표를 답하는 pg 클라이언트를 붙인다(test/avatarUpdateResign.test.js와 같은 방식 — 접속 주소도
// 닿지 않는 값). 가짜 표는 **쿼리에 실제로 있는 조건만** 적용한다: 시작선 조건(LEFT JOIN dm_history_floors와 hidden_before_at 비교)이
// 빠지거나, 다른 사람의 시작선을 보거나, 다른 시각 칸(댓글 자신·앨범 항목의 시각)과 비교하면 그만큼 다르게 찾아서 아래 테스트가 깨진다.
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import { drizzle } from 'drizzle-orm/node-postgres';

process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused';
const { db } = await import('../src/db/client.js');
for (const method of ['select', 'insert', 'update', 'delete', 'execute', 'transaction']) {
  mock.method(db, method, () => {
    throw new Error(`이 테스트는 DB를 쓰면 안 된다(db.${method})`);
  });
}
const { createFileResignRouter } = await import('../src/fileResign.js');
const { resolveRawUrl, signFileUrl } = await import('../src/upload.js');

const ALICE = '11111111-1111-4111-8111-111111111111'; // 1:1 대화에서 "진짜 나가기"를 했다가 다시 대화가 열린 사람
const BOB = '22222222-2222-4222-8222-222222222222'; // 상대 — 나가기를 하지 않았다
const CAROL = '33333333-3333-4333-8333-333333333333';
const DM = 'dm-alice-bob';
const DM_CAROL = 'dm-alice-carol';
const TOPIC = 'topic-1';
const FLOOR = new Date('2026-09-01T00:00:00.000Z');
const BEFORE = new Date('2026-08-01T00:00:00.000Z');
const AFTER = new Date('2026-09-02T00:00:00.000Z');
const path = (name) => `/uploads/${name}`;

const MEMBERS = [
  { roomId: DM, userId: ALICE },
  { roomId: DM, userId: BOB },
  { roomId: DM_CAROL, userId: ALICE },
  { roomId: DM_CAROL, userId: CAROL },
  { roomId: TOPIC, userId: ALICE },
];
const ALICE_FLOOR = [{ roomId: DM, userId: ALICE, at: FLOOR }];

const camel = (name) => name.replace(/_(\w)/g, (_, c) => c.toUpperCase());

/**
 * 이 테스트 동안 db.select를 가짜 표로 답하는 drizzle로 돌린다. 표: floors({ roomId, userId, at }), members({ roomId, userId }),
 * messages({ id, roomId, createdAt, fileUrl, thumbnailUrl, fileName, deletedAt, fileDeletedAt }), message_attachments({ messageId,
 * fileUrl, ... }), message_comments({ messageId, roomId, createdAt, fileUrl, ... }), albums({ id, roomId, createdAt }),
 * album_items({ albumId, createdAt, fileUrl, ... }). 파일 행 조회는 쿼리 글을 읽어 그 안에 있는 조인·조건만 적용한다. 받은 쿼리를
 * 돌려준다.
 */
function fakeTables(t, { floors = [], members = MEMBERS, ...tables }) {
  const rowsOf = (table) => tables[table] ?? [];
  const byId = (table) => new Map(rowsOf(table).map((r) => [r.id, r]));
  const queries = [];
  const fake = drizzle({
    client: {
      async query(config, values = []) {
        const text = (typeof config === 'string' ? config : config.text).trim();
        queries.push({ text, values });
        // 프로필 사진·이모티콘·uploads 기록은 없다 — 방 파일 경로만 본다.
        if (/ from "uploads" where /.test(text) || /^select "id" from "(users|stickers)" /.test(text)) return { rows: [] };
        const member = /^select "user_id" from "room_members" where \("room_members"\."room_id" = \$1 and "room_members"\."user_id" = \$2\)$/.exec(text);
        if (member) return { rows: members.some((m) => m.roomId === values[0] && m.userId === values[1]) ? [[values[1]]] : [] };
        // 조인이 없는 쿼리는 drizzle이 고른 칸에 표 이름을 붙이지 않는다(select "room_id", "file_name" from "messages").
        const shape = /^select (?:"(\w+)"\.)?"room_id", (?:"(\w+)"\.)?"file_name" from "(\w+)"/.exec(text);
        if (!shape) throw new Error(`테스트가 모르는 쿼리: ${text}`);
        const [, roomTable = shape[3], nameTable = shape[3], base] = shape;

        // 기본 표 행 + 쿼리에 있는 inner join의 부모 행(없으면 그 행은 빠진다).
        let rows = rowsOf(base).map((r) => ({ [base]: r }));
        for (const [, parent, child, fk] of text.matchAll(/inner join "(\w+)" on "\1"\."id" = "(\w+)"\."(\w+)"/g)) {
          const parents = byId(parent);
          rows = rows.filter((r) => parents.has(r[child][camel(fk)])).map((r) => ({ ...r, [parent]: parents.get(r[child][camel(fk)]) }));
        }
        // 파일 경로 — 원본이나 미리보기 칸.
        const file = /\("(\w+)"\."file_url" = \$(\d+) or "\1"\."thumbnail_url" = \$(\d+)\)/.exec(text);
        assert.ok(file, `파일 경로 조건이 없다: ${text}`);
        rows = rows.filter((r) => r[file[1]].fileUrl === values[file[2] - 1] || r[file[1]].thumbnailUrl === values[file[3] - 1]);
        // 지운 행 거르기(is null 조건) — 쿼리에 있는 것만.
        for (const [, table, column] of text.matchAll(/"(\w+)"\."(\w+)" is null/g)) {
          if (table !== 'dm_history_floors') rows = rows.filter((r) => r[table][camel(column)] == null);
        }
        // 시작선 — LEFT JOIN(그 방·그 사람의 행)과 비교 조건이 둘 다 있을 때만.
        const join = /left join "dm_history_floors" on \("dm_history_floors"\."room_id" = "(\w+)"\."room_id" and "dm_history_floors"\."user_id" = \$(\d+)\)/.exec(text);
        const after = /\("dm_history_floors"\."hidden_before_at" is null or "(\w+)"\."created_at" >= "dm_history_floors"\."hidden_before_at"\)/.exec(text);
        assert.equal(!!join, !!after, `시작선 조인과 조건이 짝이 맞지 않는다: ${text}`);
        if (join) {
          const who = values[join[2] - 1];
          rows = rows.filter((r) => {
            const floor = floors.find((f) => f.roomId === r[join[1]].roomId && f.userId === who);
            return !floor || r[after[1]].createdAt >= floor.at;
          });
        }
        return { rows: rows.map((r) => [r[roomTable].roomId, r[nameTable].fileName ?? null]) };
      },
    },
  });
  t.mock.method(db, 'select', (...args) => fake.select(...args));
  return queries;
}

/** POST /files/resign 처리 함수를 [userId]가 [url]로 부른 결과 — { status, body }. */
async function resign(userId, url) {
  const router = createFileResignRouter();
  const layer = router.stack.find((l) => l.route?.path === '/files/resign');
  const handler = layer.route.stack[0].handle;
  const out = { status: 200, body: null };
  const res = {
    status(code) {
      out.status = code;
      return res;
    },
    json(body) {
      out.body = body;
      return res;
    },
  };
  await handler({ body: { url }, user: { sub: userId } }, res);
  return out;
}

/** [userId]가 [raw]의 새 링크를 받는지 — 받으면 그 링크가 같은 파일을 가리키는지도 본다. */
async function canResign(userId, raw, url = raw) {
  const { status, body } = await resign(userId, url);
  if (status === 200) assert.equal(resolveRawUrl(body.url), raw);
  else assert.deepEqual([status, body], [404, { error: '파일을 찾을 수 없습니다.' }]);
  return status === 200;
}

test('메시지 파일: 시작선 이전 글의 파일은 나간 사람에게만 새 링크를 주지 않는다', async (t) => {
  fakeTables(t, {
    floors: ALICE_FLOOR,
    messages: [
      { id: 'm-old', roomId: DM, createdAt: BEFORE, fileUrl: path('old.pdf'), thumbnailUrl: path('old-thumb.webp'), fileName: '예전.pdf' },
      { id: 'm-new', roomId: DM, createdAt: AFTER, fileUrl: path('new.pdf'), fileName: '새.pdf' },
      // 시작선과 같은 시각의 글은 보인다(방 메시지 목록과 같다 — created_at >= 시작선).
      { id: 'm-edge', roomId: DM, createdAt: FLOOR, fileUrl: path('edge.pdf'), fileName: '경계.pdf' },
    ],
  });
  assert.equal(await canResign(ALICE, path('old.pdf')), false);
  assert.equal(await canResign(ALICE, path('old-thumb.webp')), false, '미리보기 칸도 같다');
  // 서명 링크(만료된 것도 서명만 맞으면 된다)로 와도 같다.
  assert.equal(await canResign(ALICE, path('old.pdf'), signFileUrl(path('old.pdf'))), false);
  // 상대는 나가기를 하지 않았다 — 시작선은 요청한 사람의 것만 본다.
  assert.equal(await canResign(BOB, path('old.pdf')), true);
  assert.equal(await canResign(ALICE, path('new.pdf')), true);
  assert.equal(await canResign(ALICE, path('edge.pdf')), true);
});

test('첨부 목록(message_attachments): 메시지의 시각으로 본다', async (t) => {
  fakeTables(t, {
    floors: ALICE_FLOOR,
    messages: [
      { id: 'm-old', roomId: DM, createdAt: BEFORE },
      { id: 'm-new', roomId: DM, createdAt: AFTER },
    ],
    message_attachments: [
      { messageId: 'm-old', fileUrl: path('a-old.jpg'), thumbnailUrl: path('a-old-thumb.webp'), fileName: 'a.jpg' },
      { messageId: 'm-new', fileUrl: path('a-new.jpg'), fileName: 'b.jpg' },
    ],
  });
  assert.equal(await canResign(ALICE, path('a-old.jpg')), false);
  assert.equal(await canResign(ALICE, path('a-old-thumb.webp')), false);
  assert.equal(await canResign(BOB, path('a-old.jpg')), true);
  assert.equal(await canResign(ALICE, path('a-new.jpg')), true);
});

test('댓글 첨부: 댓글 자신이 아니라 부모 메시지의 시각으로 본다(부모 글이 안 보이면 댓글도 안 보인다)', async (t) => {
  fakeTables(t, {
    floors: ALICE_FLOOR,
    messages: [
      { id: 'p-old', roomId: DM, createdAt: BEFORE },
      { id: 'p-new', roomId: DM, createdAt: AFTER },
    ],
    message_comments: [
      // 시작선 뒤에 달았지만 부모가 시작선 이전 글이다.
      { messageId: 'p-old', roomId: DM, createdAt: AFTER, fileUrl: path('c-old-parent.png'), fileName: 'c1.png' },
      { messageId: 'p-new', roomId: DM, createdAt: AFTER, fileUrl: path('c-new.png'), fileName: 'c2.png' },
    ],
  });
  assert.equal(await canResign(ALICE, path('c-old-parent.png')), false);
  assert.equal(await canResign(BOB, path('c-old-parent.png')), true);
  assert.equal(await canResign(ALICE, path('c-new.png')), true);
});

test('앨범 항목: 항목을 넣은 시각이 아니라 앨범을 만든 시각으로 본다(앨범 목록과 같다)', async (t) => {
  fakeTables(t, {
    floors: ALICE_FLOOR,
    albums: [
      { id: 'al-old', roomId: DM, createdAt: BEFORE },
      { id: 'al-new', roomId: DM, createdAt: AFTER },
    ],
    album_items: [
      // 시작선 뒤에 넣었지만 앨범은 시작선 이전에 만들었다 — 이 사람에게는 앨범째 안 보인다.
      { albumId: 'al-old', createdAt: AFTER, fileUrl: path('al-old.jpg'), thumbnailUrl: path('al-old-thumb.webp'), fileName: 'x.jpg' },
      { albumId: 'al-new', createdAt: AFTER, fileUrl: path('al-new.jpg'), fileName: 'y.jpg' },
    ],
  });
  assert.equal(await canResign(ALICE, path('al-old.jpg')), false);
  assert.equal(await canResign(ALICE, path('al-old-thumb.webp')), false);
  assert.equal(await canResign(BOB, path('al-old.jpg')), true);
  assert.equal(await canResign(ALICE, path('al-new.jpg')), true);
});

test('시작선은 그 방에만 — 같은 파일이 다른 방에 실렸거나, 다른 1:1 대화의 파일이면 그대로 받는다', async (t) => {
  fakeTables(t, {
    floors: ALICE_FLOOR,
    messages: [
      { id: 'm-dm', roomId: DM, createdAt: BEFORE, fileUrl: path('shared.pdf'), fileName: 's.pdf' },
      // 같은 파일을 토픽에도 전달해 뒀다(시작선 이전 시각이어도 그 방에는 시작선이 없다).
      { id: 'm-topic', roomId: TOPIC, createdAt: BEFORE, fileUrl: path('shared.pdf'), fileName: 's.pdf' },
      { id: 'm-carol', roomId: DM_CAROL, createdAt: BEFORE, fileUrl: path('carol.pdf'), fileName: 'c.pdf' },
    ],
  });
  assert.equal(await canResign(ALICE, path('shared.pdf')), true);
  assert.equal(await canResign(ALICE, path('carol.pdf')), true);
});

test('상대만 나가기를 했으면 상대만 못 받는다', async (t) => {
  fakeTables(t, {
    floors: [{ roomId: DM, userId: BOB, at: FLOOR }],
    messages: [{ id: 'm-old', roomId: DM, createdAt: BEFORE, fileUrl: path('old.pdf'), fileName: 'o.pdf' }],
  });
  assert.equal(await canResign(ALICE, path('old.pdf')), true);
  assert.equal(await canResign(BOB, path('old.pdf')), false);
});

test('지운 메시지·파일·첨부·댓글은 예전처럼 받을 수 없다(시작선과 함께 지운 행 조건도 그대로 남았다)', async (t) => {
  fakeTables(t, {
    messages: [
      { id: 'm-del', roomId: TOPIC, createdAt: AFTER, deletedAt: AFTER, fileUrl: path('del.pdf'), fileName: 'd.pdf' },
      { id: 'm-file-del', roomId: TOPIC, createdAt: AFTER, fileDeletedAt: AFTER, fileUrl: path('file-del.pdf'), fileName: 'f.pdf' },
      { id: 'm-live', roomId: TOPIC, createdAt: AFTER },
    ],
    message_attachments: [{ messageId: 'm-live', deletedAt: AFTER, fileUrl: path('att-del.jpg'), fileName: 'a.jpg' }],
    message_comments: [{ messageId: 'm-live', roomId: TOPIC, createdAt: AFTER, deletedAt: AFTER, fileUrl: path('cmt-del.png') }],
  });
  for (const name of ['del.pdf', 'file-del.pdf', 'att-del.jpg', 'cmt-del.png']) {
    assert.equal(await canResign(ALICE, path(name)), false, name);
  }
});

test('네 파일 쿼리 모두 요청한 사람의 시작선만 LEFT JOIN하고, 글이 보이는지를 정하는 시각과 비교한다', async (t) => {
  const queries = fakeTables(t, {});
  await resign(ALICE, path('any.pdf'));
  const fileQueries = queries.filter((q) => /\."file_name" from /.test(q.text));
  const floorOf = (q) => ({
    from: /from "(\w+)"/.exec(q.text)[1],
    room: /"dm_history_floors"\."room_id" = "(\w+)"\."room_id"/.exec(q.text)?.[1],
    who: q.values[Number(/"dm_history_floors"\."user_id" = \$(\d+)/.exec(q.text)?.[1]) - 1],
    createdAt: /or "(\w+)"\."created_at" >= "dm_history_floors"\."hidden_before_at"/.exec(q.text)?.[1],
  });
  assert.deepEqual(fileQueries.map(floorOf), [
    { from: 'messages', room: 'messages', who: ALICE, createdAt: 'messages' },
    { from: 'message_attachments', room: 'messages', who: ALICE, createdAt: 'messages' },
    { from: 'message_comments', room: 'message_comments', who: ALICE, createdAt: 'messages' },
    { from: 'album_items', room: 'albums', who: ALICE, createdAt: 'albums' },
  ]);
  assert.match(fileQueries[2].text, /inner join "messages" on "messages"\."id" = "message_comments"\."message_id"/);
  for (const q of fileQueries) assert.match(q.text, /left join "dm_history_floors" on /);
});
