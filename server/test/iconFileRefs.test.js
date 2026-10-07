// 팀·그룹 아이콘 사진의 파일 확인 단위 테스트(S22) — `node --test test/iconFileRefs.test.js` (DB·서버 없이 돈다).
// 아이콘 사진은 그 팀·그룹을 보는 사람 모두에게 서명 링크로 나간다. 그래서 저장하기 전에 fileRefs.js checkIconRef(= checkFileRefs, 원래
// 있던 파일은 지금 아이콘)를 거친다: 이 사람이 올린 사진, 지금 아이콘(설정 창이 들고 있던 링크가 만료돼 돌아와도), 서명 링크로 온 지금
// 볼 수 있는 방의 사진만. 조회는 가짜를 넣고, 라우트 연결은 소스에서 본다(projectGuardJoin.test.js와 같은 방식).
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { mock, test } from 'node:test';
import jwt from 'jsonwebtoken';
import { signFileUrl } from '../src/upload.js';

process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused';
const { db } = await import('../src/db/client.js');
for (const method of ['select', 'insert', 'update', 'delete', 'execute', 'transaction']) {
  mock.method(db, method, () => {
    throw new Error(`이 테스트는 DB를 쓰면 안 된다(db.${method})`);
  });
}
const { checkIconRef } = await import('../src/fileRefs.js');

const ADMIN = '11111111-1111-4111-8111-111111111111';
const OTHER = '22222222-2222-4222-8222-222222222222';
const MY_PHOTO = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.png';
const CURRENT = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc.png'; // 지금 아이콘 — 다른 관리자가 올렸다.
const THEIRS = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.png';
const stored = (name) => `/uploads/${name}`;
const ERROR = '팀 아이콘 사진이 올바르지 않습니다. 다시 올려주세요.';

function signedHoursAgo(p, hours) {
  const issuedAt = Date.now() - hours * 60 * 60 * 1000;
  const clock = mock.method(Date, 'now', () => issuedAt);
  try {
    return signFileUrl(p);
  } finally {
    clock.mock.restore();
  }
}

/** 가짜 조회 — 부른 기록을 남긴다. */
function fakeLookups({ reachable = [] } = {}) {
  const owners = new Map([
    [MY_PHOTO, ADMIN],
    [CURRENT, OTHER],
    [THEIRS, OTHER],
  ]);
  const calls = { uploaders: [], reachable: [] };
  return {
    calls,
    async findUploaders(names) {
      calls.uploaders.push(names);
      return new Map(names.filter((n) => owners.has(n)).map((n) => [n, owners.get(n)]));
    },
    async findReachableUploadPaths(userId, paths) {
      calls.reachable.push({ userId, paths });
      return new Set(paths.filter((p) => reachable.includes(p)));
    },
  };
}

test('checkIconRef: 방금 올린 사진 — 업로드 응답의 서명 링크(signedUrl)든 저장 경로(url)든 저장 경로로', async () => {
  for (const sent of [signFileUrl(stored(MY_PHOTO)), stored(MY_PHOTO)]) {
    const lookups = fakeLookups();
    assert.deepEqual(await checkIconRef(sent, { senderId: ADMIN, error: ERROR }, lookups), { ok: true, path: stored(MY_PHOTO) });
    assert.deepEqual(lookups.calls.reachable, []);
  }
});

test('checkIconRef: 지금 아이콘을 그대로 다시 보내면(다른 사람이 올렸어도, 창을 오래 열어 둬 만료된 링크여도) 조회 없이 받는다', async () => {
  for (const sent of [signedHoursAgo(stored(CURRENT), 6), signFileUrl(stored(CURRENT)), stored(CURRENT)]) {
    const lookups = fakeLookups();
    assert.deepEqual(
      await checkIconRef(sent, { senderId: ADMIN, currentIconUrl: stored(CURRENT), error: ERROR }, lookups),
      { ok: true, path: stored(CURRENT) },
    );
    assert.deepEqual(lookups.calls, { uploaders: [], reachable: [] });
  }
});

test('감사의 공격: 알게 된 남의 파일 이름을 아이콘으로 — 거절(방을 찾아보지도 않는다), 지금 아이콘이 아니면 만료 링크도 거절', async () => {
  const lookups = fakeLookups({ reachable: [stored(THEIRS)] });
  assert.deepEqual(await checkIconRef(stored(THEIRS), { senderId: ADMIN, currentIconUrl: stored(CURRENT), error: ERROR }, lookups), {
    ok: false,
    error: ERROR,
  });
  assert.deepEqual(lookups.calls.reachable, []);
  // 바뀌기 전 아이콘(지금 아이콘이 아닌, 남이 올린 사진)의 링크는 볼 수 있는 방에 없으면 거절.
  assert.deepEqual(
    await checkIconRef(signedHoursAgo(stored(THEIRS), 3), { senderId: ADMIN, currentIconUrl: stored(CURRENT), error: ERROR }, fakeLookups()),
    { ok: false, error: ERROR },
  );
});

test('checkIconRef: 서명 링크로 온, 지금 들어가 있는 방에서 볼 수 있는 남의 사진은 받는다(메시지 전달과 같다)', async () => {
  const lookups = fakeLookups({ reachable: [stored(THEIRS)] });
  assert.deepEqual(await checkIconRef(signFileUrl(stored(THEIRS)), { senderId: ADMIN, error: ERROR }, lookups), {
    ok: true,
    path: stored(THEIRS),
  });
  assert.deepEqual(lookups.calls.reachable, [{ userId: ADMIN, paths: [stored(THEIRS)] }]);
});

test('checkIconRef: 빈 값·문자열 아님·바깥 주소·예전 JWT 링크·하위 경로는 DB를 보지 않고 거절', async () => {
  const lookups = fakeLookups();
  const legacy = `/files/${jwt.sign({ file: MY_PHOTO, type: 'file' }, 'any-secret')}`;
  for (const bad of [undefined, null, '', 42, { url: stored(MY_PHOTO) }, 'https://evil.example/a.png', legacy, `/uploads/x/${MY_PHOTO}`, '/uploads/..']) {
    assert.deepEqual(await checkIconRef(bad, { senderId: ADMIN, error: ERROR }, lookups), { ok: false, error: ERROR }, String(bad));
  }
  assert.deepEqual(lookups.calls, { uploaders: [], reachable: [] });
});

test('teams.js 연결: 팀 만들기·설정 변경 모두 아이콘 사진을 checkIconRef로 보고, 설정 변경은 지금 아이콘을 넘긴다', () => {
  const source = fs.readFileSync(new URL('../src/teams.js', import.meta.url), 'utf8');
  assert.match(source, /async function parseTeamOptionFields\(body, \{ userId, currentIconUrl = null \}\)/);
  assert.match(
    source,
    /const icon = await checkIconRef\(body\.iconUrl, \{ senderId: userId, currentIconUrl, error: TEAM_ICON_ERROR \}\);\s*if \(!icon\.ok\) return \{ error: icon\.error \};\s*fields\.iconUrl = icon\.path;/,
  );
  assert.match(source, /await parseTeamOptionFields\(req\.body \?\? \{\}, \{ userId: req\.user\.sub \}\)/);
  assert.match(source, /await parseTeamOptionFields\(req\.body \?\? \{\}, \{ userId: req\.user\.sub, currentIconUrl: team\.iconUrl \}\)/);
  // 확인 없이 저장 경로로 되돌리기만 하던 길이 남아 있지 않다.
  assert.doesNotMatch(source, /toStoredUploadUrl/);
});

test('rooms.js 연결: 그룹 만들기·채팅 정보 변경 모두 아이콘 사진을 checkIconRef로 보고, 정보 변경은 지금 아이콘을 넘긴다', () => {
  const source = fs.readFileSync(new URL('../src/rooms.js', import.meta.url), 'utf8');
  assert.match(source, /async function parseGroupIcon\(\{ iconType, iconEmoji, iconColor, iconUrl \}, \{ userId, currentIconUrl = null \}\)/);
  assert.match(source, /await checkIconRef\(iconUrl, \{ senderId: userId, currentIconUrl, error: GROUP_ICON_ERROR \}\)/);
  assert.match(source, /await parseGroupIcon\(\{ iconType, iconEmoji, iconColor, iconUrl \}, \{ userId: req\.user\.sub \}\)/);
  assert.match(source, /\{ userId: req\.user\.sub, currentIconUrl: room\.iconUrl \},\s*\);/);
  // parseGroupIcon을 부르는 곳은 모두 기다린다(두 곳).
  assert.equal([...source.matchAll(/(?<!function )parseGroupIcon\(/g)].length, 2);
  assert.equal([...source.matchAll(/await parseGroupIcon\(/g)].length, 2);
  assert.doesNotMatch(source, /toStoredUploadUrl/);
});
