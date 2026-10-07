// 회원 명단을 누구에게 얼마나 보여 줄지(userDirectory.js — GET /users·GET /users/:id/teams·팀원 추가 후보) 단위 테스트 —
// `node --test test/*.test.js` (DB·서버 없이 돈다). 범위를 좁혀 읽는 쿼리(db/queries/users.js listActiveUsersByIds)는 drizzle의
// 실제 쿼리 빌더에 SQL을 받아 적는 가짜 pg 클라이언트를 붙여 모양만 본다(접속 주소도 닿지 않는 값으로 정해 둔다).
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import { drizzle } from 'drizzle-orm/node-postgres';
import { canSeeUser, directoryUserIds, seesWholeDirectory, teamMemberCandidates } from '../src/userDirectory.js';
import { resolveRawUrl } from '../src/upload.js';

process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused';
const { db } = await import('../src/db/client.js');
for (const method of ['select', 'insert', 'update', 'delete', 'execute', 'transaction']) {
  mock.method(db, method, () => {
    throw new Error(`이 테스트는 DB를 쓰면 안 된다(db.${method})`);
  });
}
const { listActiveUsersByIds } = await import('../src/db/queries/users.js');

const user = (id, fields = {}) => ({
  id,
  username: `${id}-login`,
  name: id,
  role: 'member',
  isServerAdmin: false,
  avatarType: 'initial',
  avatarEmoji: null,
  avatarColor: null,
  avatarUrl: null,
  suspendedAt: null,
  deletedAt: null,
  ...fields,
});

test('seesWholeDirectory: 계정 등급 관리자와 서버 운영자만 서버 전체 회원을 본다', () => {
  assert.equal(seesWholeDirectory(user('a', { role: 'admin' })), true);
  // 서버 운영자는 계정 등급과 별개 축이다 — 등급이 낮아도 관리자 콘솔·조직도를 쓰므로 전체를 본다.
  assert.equal(seesWholeDirectory(user('s', { role: 'guest', isServerAdmin: true })), true);
  assert.equal(seesWholeDirectory(user('m', { role: 'member' })), false);
  assert.equal(seesWholeDirectory(user('g', { role: 'guest' })), false);
  // 모르는 등급은 가장 약한 등급으로 본다(permissions.js accountRole).
  assert.equal(seesWholeDirectory(user('x', { role: 'superuser' })), false);
  assert.equal(seesWholeDirectory(user('y', { isServerAdmin: 'true' })), false);
  assert.equal(seesWholeDirectory(null), false);
  assert.equal(seesWholeDirectory(undefined), false);
});

test('directoryUserIds·canSeeUser: 팀을 같이 쓰는 사람과 자기 자신만, 서버 전체(null)면 누구든', () => {
  // listCoTeamMemberIds는 자기 자신도 돌려줄 수 있다(팀이 있으면) — 겹쳐도 한 번만.
  const visible = directoryUserIds('me', ['me', 'kim', 'lee', 'kim']);
  assert.deepEqual([...visible].sort(), ['kim', 'lee', 'me']);
  assert.equal(canSeeUser(visible, 'kim'), true);
  assert.equal(canSeeUser(visible, 'me'), true);
  assert.equal(canSeeUser(visible, 'stranger'), false);

  // 팀이 하나도 없는 준회원 — 자기 자신만 보인다(예전엔 서버 전체 회원 명단이 갔다).
  const loner = directoryUserIds('newbie', []);
  assert.deepEqual([...loner], ['newbie']);
  assert.equal(canSeeUser(loner, 'kim'), false);
  assert.deepEqual([...directoryUserIds('newbie')], ['newbie']);

  assert.equal(canSeeUser(null, 'anyone'), true);
});

test('teamMemberCandidates: 아직 이 팀에 없고 정지·탈퇴하지 않은 계정만, 이름순으로', () => {
  const users = [
    user('u-park', { name: '박민수' }),
    user('u-kim', { name: '김철수' }), // 이미 팀원
    user('u-choi', { name: '최지우', role: 'guest' }),
    user('u-lee', { name: '이영희', suspendedAt: new Date() }),
    user('u-gone', { name: '탈퇴한 사용자', deletedAt: new Date() }),
    user('u-han', { name: '한소희', role: 'admin' }),
    user('u-ahn', { name: '안정환', role: 'weird' }),
  ];
  const candidates = teamMemberCandidates(users, ['u-kim', 'u-owner']);
  assert.deepEqual(
    candidates.map((c) => c.name),
    ['박민수', '안정환', '최지우', '한소희'],
  );
  // 화면(팀 설정 "팀원 추가")이 쓰는 칸만 — 이메일·생일·접속 상태·직책·비밀번호 해시 같은 건 싣지 않는다.
  for (const c of candidates) {
    assert.deepEqual(Object.keys(c).sort(), ['avatarColor', 'avatarEmoji', 'avatarType', 'avatarUrl', 'id', 'name', 'role', 'username']);
  }
  const byId = Object.fromEntries(candidates.map((c) => [c.id, c]));
  // 같은 이름을 가리려고 아이디는 싣는다.
  assert.equal(byId['u-park'].username, 'u-park-login');
  assert.equal(byId['u-choi'].role, 'guest');
  assert.equal(byId['u-han'].role, 'admin');
  assert.equal(byId['u-ahn'].role, 'guest'); // 모르는 등급은 준회원으로.
  assert.deepEqual(teamMemberCandidates([], ['u-kim']), []);
});

test('teamMemberCandidates: 아바타 칸은 앱이 그릴 수 있게 거른다', () => {
  const photo = '/uploads/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.png';
  const [withPhoto, character, junk] = teamMemberCandidates(
    [
      user('p', { name: '가', avatarType: 'photo', avatarUrl: photo }),
      user('c', { name: '나', avatarType: 'character', avatarEmoji: '🧔', avatarColor: '#0CA678' }),
      // 검사가 생기기 전에 저장된 이상한 값 — 배경색은 버리고, 사진이 아닌 아바타의 경로는 서명해 주지 않는다.
      user('j', { name: '다', avatarType: 'character', avatarEmoji: '🧔', avatarColor: 'not-a-color', avatarUrl: photo }),
    ],
    [],
  );
  assert.equal(withPhoto.avatarType, 'photo');
  assert.match(withPhoto.avatarUrl, /^\/files\//);
  assert.equal(resolveRawUrl(withPhoto.avatarUrl), photo);
  assert.equal(character.avatarColor, '#0CA678');
  assert.equal(character.avatarUrl, null);
  assert.equal(junk.avatarColor, null);
  assert.equal(junk.avatarUrl, null);
});

/** 이 테스트 동안 db.select를 SQL만 받아 적는 drizzle로 돌린다 — 결과는 [rows](pg rowMode 'array' 모양). */
function recordSelects(t, rows = []) {
  const queries = [];
  const fake = drizzle({
    client: {
      async query(config, values = []) {
        queries.push({ text: typeof config === 'string' ? config : config.text, values });
        return { rows };
      },
    },
  });
  t.mock.method(db, 'select', (...args) => fake.select(...args));
  return queries;
}

test('listActiveUsersByIds: 그 id들 가운데 탈퇴하지 않은 계정만 한 번에 묻는다', async (t) => {
  const queries = recordSelects(t);
  assert.deepEqual(await listActiveUsersByIds(['me', 'kim', 'me']), []);
  assert.equal(queries.length, 1);
  assert.match(queries[0].text, /from "users" where \("users"\."id" in \(\$1, \$2\) and "users"\."deleted_at" is null\)$/);
  assert.deepEqual(queries[0].values, ['me', 'kim']); // 겹친 id는 한 번만.
});

test('listActiveUsersByIds: id가 없으면 DB에 묻지 않는다', async (t) => {
  const queries = recordSelects(t);
  assert.deepEqual(await listActiveUsersByIds([]), []);
  assert.equal(queries.length, 0);
});
