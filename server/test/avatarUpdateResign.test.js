// /files/resign(fileResign.js)의 프로필 사진 경로 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다). 라우트 처리 함수를
// 가짜 요청으로 직접 부르고, drizzle의 실제 쿼리 빌더에 아주 작은 가짜 표(계정·uploads)를 답하는 pg 클라이언트를 붙인다(접속 주소도
// 닿지 않는 값으로 정해 둔다). 남이 올린 파일을 프로필 사진으로 걸어 둬도 그 파일의 새 다운로드 링크를 아무에게나 주지 않는지 본다.
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import { drizzle } from 'drizzle-orm/node-postgres';
import { resolveRawUrl, signFileUrl } from '../src/upload.js';

process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused';
const { db } = await import('../src/db/client.js');
for (const method of ['select', 'insert', 'update', 'delete', 'execute', 'transaction']) {
  mock.method(db, method, () => {
    throw new Error(`이 테스트는 DB를 쓰면 안 된다(db.${method})`);
  });
}
const { createFileResignRouter } = await import('../src/fileResign.js');

const ALICE = '11111111-1111-4111-8111-111111111111';
const MALLORY = '22222222-2222-4222-8222-222222222222';
const READER = '33333333-3333-4333-8333-333333333333';
const ALICE_FILE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.png';
const OLD_FILE = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg'; // uploads 표가 생기기 전에 올린 사진 — 기록이 없다.
const stored = (name) => `/uploads/${name}`;

/**
 * 이 테스트 동안 db.select를 가짜 표로 답하는 drizzle로 돌린다 — [accounts]는 { id, avatarType, avatarUrl }, [uploads]는 저장 이름 →
 * 올린 사람. 메시지·댓글·앨범·이모티콘·방 멤버 조회는 빈 결과(그 파일이 실린 방이 없다)로 답한다.
 */
function fakeTables(t, { accounts = [], uploads = {} }) {
  const fake = drizzle({
    client: {
      async query(config, values = []) {
        const text = typeof config === 'string' ? config : config.text;
        if (/ from "uploads" where "uploads"\."file_name" = \$1$/.test(text)) {
          const name = values[0];
          return { rows: name in uploads ? [[name, uploads[name], '2026-10-01T00:00:00.000Z']] : [] };
        }
        if (/^select "id" from "users" where /.test(text)) {
          // 쿼리에 실제로 있는 조건만 적용한다(조건이 빠지면 그만큼 넓게 찾는다 — 예전 쿼리로 돌아가면 아래 테스트가 깨진다).
          const param = (column) => {
            const m = new RegExp(`"users"\\."${column}" = \\$(\\d+)`).exec(text);
            return m ? values[Number(m[1]) - 1] : undefined;
          };
          const [url, type, id] = [param('avatar_url'), param('avatar_type'), param('id')];
          const hits = accounts.filter(
            (a) => a.avatarUrl === url && (type === undefined || a.avatarType === type) && (id === undefined || a.id === id),
          );
          return { rows: hits.slice(0, 1).map((a) => [a.id]) };
        }
        if (/ from "(messages|message_attachments|message_comments|album_items|stickers)" /.test(text)) return { rows: [] };
        throw new Error(`테스트가 모르는 쿼리: ${text}`);
      },
    },
  });
  t.mock.method(db, 'select', (...args) => fake.select(...args));
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

test('올린 사람 자신의 사진 아바타면 누구에게나 새 링크를 준다(알림 아이콘)', async (t) => {
  fakeTables(t, {
    accounts: [{ id: ALICE, avatarType: 'photo', avatarUrl: stored(ALICE_FILE) }],
    uploads: { [ALICE_FILE]: ALICE },
  });
  const { status, body } = await resign(READER, signFileUrl(stored(ALICE_FILE)));
  assert.equal(status, 200);
  assert.equal(resolveRawUrl(body.url), stored(ALICE_FILE));
});

test('남이 올린 파일을 프로필 사진으로 걸어 둔 경우 — 그 파일 링크를 새로 주지 않는다', async (t) => {
  // 예전 PATCH /users/me로 Mallory가 Alice의 파일 경로를 자기 프로필 사진에 넣어 둔 상태(Alice는 다른 아바타).
  fakeTables(t, {
    accounts: [
      { id: ALICE, avatarType: 'character', avatarUrl: null },
      { id: MALLORY, avatarType: 'photo', avatarUrl: stored(ALICE_FILE) },
    ],
    uploads: { [ALICE_FILE]: ALICE },
  });
  for (const who of [READER, MALLORY]) {
    const { status, body } = await resign(who, signFileUrl(stored(ALICE_FILE)));
    assert.equal(status, 404, who);
    assert.deepEqual(body, { error: '파일을 찾을 수 없습니다.' });
  }
});

test('올린 계정이 지워진 파일은 누구의 프로필 사진이어도 공개로 보지 않는다', async (t) => {
  fakeTables(t, {
    accounts: [{ id: MALLORY, avatarType: 'photo', avatarUrl: stored(ALICE_FILE) }],
    uploads: { [ALICE_FILE]: null },
  });
  assert.equal((await resign(READER, stored(ALICE_FILE))).status, 404);
});

test('사진이 아닌 아바타에 남아 있는 경로는 프로필 사진으로 치지 않는다', async (t) => {
  // 예전 PATCH /users/me는 캐릭터 아바타에도 보낸 경로를 그대로 저장했다(기록 없는 예전 파일이어도 마찬가지).
  fakeTables(t, {
    accounts: [{ id: MALLORY, avatarType: 'character', avatarUrl: stored(OLD_FILE) }],
  });
  assert.equal((await resign(READER, stored(OLD_FILE))).status, 404);
});

test('uploads 기록이 없는 예전 사진은 예전처럼 누군가의 사진 아바타면 된다', async (t) => {
  fakeTables(t, {
    accounts: [{ id: ALICE, avatarType: 'photo', avatarUrl: stored(OLD_FILE) }],
  });
  const { status, body } = await resign(READER, stored(OLD_FILE));
  assert.equal(status, 200);
  assert.equal(resolveRawUrl(body.url), stored(OLD_FILE));
});

test('알 수 없는 링크는 400', async () => {
  for (const url of [undefined, 'https://evil.example/x.png', '/files/forged', '/uploads/sub/x.png']) {
    assert.equal((await resign(READER, url)).status, 400, String(url));
  }
});
