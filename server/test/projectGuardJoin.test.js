// 공개 프로젝트 "참여"(예전 앱의 POST /projects/:id/join) 테스트 — `node --test test/projectGuardJoin.test.js` (DB·서버 없이 돈다).
// 예전 참여는 초대받은 사람과 같은 행(auto = false)을 넣어서, 스스로 들어온 사람이 프로젝트가 비공개로 바뀌어도 빠지지 않았다(S27 —
// removeAutoMembers는 자동 참여 행만 뺀다). 비공개 전환과 동시에 부르면 원래 자동으로 들어와 있던 사람이 전환 도중 초대받은 행으로 다시
// 들어가기도 했다. 이제 링크로 열 때의 자동 참여(joinPublicProjectAutomatically)와 같이 넣는다 — 같은 문장 안에서 공개·종료 여부와
// 팀·자격을 다시 보고 프로젝트 행을 잠근 채(for share — 비공개 전환의 UPDATE와 서로 기다린다) auto = true로. 쿼리는 drizzle에 SQL을
// 받아 적는 가짜 pg 클라이언트로 돌린다(실제 DB에는 아무것도 묻지 않는다).
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';

process.env.DATABASE_URL ??= 'postgres://test:test@127.0.0.1:9/unused';
const { db } = await import('../src/db/client.js');
const { joinPublicProjectAutomatically, removeAutoMembers } = await import('../src/db/queries/projects.js');

const source = fs.readFileSync(new URL('../src/projects.js', import.meta.url), 'utf8');

function fakePg(respond = () => []) {
  const queries = [];
  db.$client.query = async (config, values = []) => {
    const text = typeof config === 'string' ? config : config.text;
    queries.push({ text: text.replace(/\s+/g, ' ').trim(), values });
    const rows = respond(text, values) ?? [];
    return { rows, rowCount: rows.length };
  };
  return queries;
}

/** POST /projects/:id/join 라우트의 소스. */
function joinRoute() {
  const start = source.indexOf("router.post('/projects/:id/join'");
  assert.ok(start >= 0, '참여 라우트');
  return source.slice(start, source.indexOf('\n  });\n', start));
}

test('참여 라우트는 자동 참여와 같은 함수로 넣고, 초대 행(addProjectMembers)은 넣지 않는다', () => {
  const route = joinRoute();
  assert.match(route, /await joinPublicProjectAutomatically\(project, req\.user\.sub\)/);
  assert.doesNotMatch(route, /addProjectMembers/);
  // 팀 멤버가 아니면 예전처럼 막는다(자동 참여 문장도 팀을 다시 보지만, 안내를 따로 준다).
  assert.match(route, /isTeamMember\(project\.teamId, req\.user\.sub\)/);
});

test('자동 참여 문장: 공개·종료 여부와 팀·자격을 같은 문장에서 다시 보고, 프로젝트 행을 잠근 채 auto 행으로 넣는다', async () => {
  const queries = fakePg((text) => (/^\s*insert into "project_members"/.test(text) ? [['u1']] : []));
  assert.equal(await joinPublicProjectAutomatically({ id: 'p1', isPublic: true, archivedAt: null }, 'u1'), true);
  assert.equal(queries.length, 1, '넣었으면 구성원 확인을 따로 하지 않는다');
  const [{ text, values }] = queries;
  assert.match(text, /^insert into "project_members" \(project_id, user_id, role, auto\) select p\.id, u\.id, 'member', true /);
  assert.match(text, /from "projects" p join "team_members" tm on tm\.team_id = p\.team_id and tm\.user_id = \$1 join "users" u on u\.id = tm\.user_id/);
  assert.match(text, /where p\.id = \$2 and p\.is_public and p\.archived_at is null and u\.role in \('member', 'admin'\) and u\.deleted_at is null and u\.suspended_at is null/);
  assert.match(text, /for share of p on conflict do nothing returning user_id$/);
  assert.deepEqual(values, ['u1', 'p1']);
});

test('그사이 비공개가 됐거나 자격이 없어 아무것도 안 넣었으면, 이미 구성원일 때만 true', async () => {
  // 넣은 행이 없고 구성원도 아니다 → false(라우트가 403/404로 안내한다).
  let queries = fakePg(() => []);
  assert.equal(await joinPublicProjectAutomatically({ id: 'p1', isPublic: true, archivedAt: null }, 'u1'), false);
  assert.equal(queries.length, 2);
  assert.match(queries[1].text, /^select "user_id" from "project_members" where/);
  // 넣은 행은 없지만(이미 있는 행 — on conflict) 유효한 구성원이다 → true.
  queries = fakePg((text) => (/^select "user_id" from "project_members"/.test(text) ? [['u1']] : []));
  assert.equal(await joinPublicProjectAutomatically({ id: 'p1', isPublic: true, archivedAt: null }, 'u1'), true);
  // 먼저 읽어 둔 프로젝트가 이미 비공개·종료면 DB에 묻지도 않는다.
  queries = fakePg();
  assert.equal(await joinPublicProjectAutomatically({ id: 'p1', isPublic: false, archivedAt: null }, 'u1'), false);
  assert.equal(await joinPublicProjectAutomatically({ id: 'p1', isPublic: true, archivedAt: new Date() }, 'u1'), false);
  assert.equal(queries.length, 0);
});

test('비공개로 바꾸면 자동 참여 행(= 이제 스스로 참여한 행도)이 빠진다', async () => {
  const queries = fakePg((text) => (/^delete from "project_members"/.test(text) ? [['self-joined']] : []));
  assert.deepEqual(await removeAutoMembers('p1'), ['self-joined']);
  assert.equal(
    queries[0].text,
    'delete from "project_members" where ("project_members"."project_id" = $1 and "project_members"."auto" = $2 and "project_members"."role" = $3) returning "user_id"',
  );
  assert.deepEqual(queries[0].values, ['p1', true, 'member']);
});
