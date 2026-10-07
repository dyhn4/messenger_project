// 프로젝트 라우터 입구(준회원 막기) 테스트 — `node --test test/projectGuardRoutes.test.js` (DB·서버 없이 돈다).
// 프로젝트는 정회원 이상만 쓴다(서버 운영자는 예외). 예전 입구 목록에는 /checklist-items가 빠져서, 준회원으로 내려간 사람이 남은 구성원
// 행으로 체크리스트를 고치고 지울 수 있었다(S26). 여기서는 projects.js에 있는 라우트를 모두 읽어 입구 목록(PROJECT_ROUTE_PREFIXES)에
// 빠진 주소가 없는지, 프로젝트를 여는 requireProjectMember도 같은 판정을 먼저 하는지, 그 판정(projectUseDenial)이 구성원 자격
// 규칙(isEligibleProjectAccount — 준회원은 서버 운영자만 예외)과 어긋나지 않는지 본다.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import {
  PROJECT_GUEST_DENIAL,
  PROJECT_ROUTE_PREFIXES,
  isEligibleProjectAccount,
  projectUseDenial,
} from '../src/projectNotifications.js';

const source = fs.readFileSync(new URL('../src/projects.js', import.meta.url), 'utf8');

/** projects.js의 라우트 [{ method, path }] — router.get('/…') 같은 선언을 모두. */
function declaredRoutes() {
  return [...source.matchAll(/router\.(get|post|put|patch|delete|all)\(\s*'([^']+)'/g)].map((m) => ({
    method: m[1],
    path: m[2],
  }));
}

/** Express의 router.use(경로) 맞추기 — 같은 경로이거나 그 아래('/'로 이어지는) 경로. */
const covered = (path) => PROJECT_ROUTE_PREFIXES.some((p) => path === p || path.startsWith(`${p}/`));

test('projects.js의 라우트는 모두 입구 목록 아래에 있다', () => {
  const routes = declaredRoutes();
  // 라우트를 읽어 오는 방식이 망가지면 아래 검사가 아무것도 안 보게 되므로 개수도 본다.
  assert.ok(routes.length >= 80, `라우트 ${routes.length}개`);
  // 따옴표가 아닌 주소(변수·템플릿 문자열)로 만든 라우트가 있으면 위 읽기가 놓친다 — 그런 라우트는 두지 않는다.
  assert.doesNotMatch(source, /router\.(get|post|put|patch|delete|all)\(\s*[^'\s]/);
  const missing = routes.filter((r) => !covered(r.path)).map((r) => `${r.method} ${r.path}`);
  assert.deepEqual(missing, [], '입구 목록(projectNotifications.js PROJECT_ROUTE_PREFIXES)에 첫 마디를 넣으세요');
  // 예전에 빠졌던 체크리스트 항목 주소.
  assert.ok(covered('/checklist-items/abc'));
  assert.ok(routes.some((r) => r.method === 'patch' && r.path === '/checklist-items/:id'));
  assert.ok(routes.some((r) => r.method === 'delete' && r.path === '/checklist-items/:id'));
});

test('입구 목록은 겹치지 않고 모두 이 라우터가 실제로 쓰는 주소다', () => {
  assert.equal(new Set(PROJECT_ROUTE_PREFIXES).size, PROJECT_ROUTE_PREFIXES.length);
  const routes = declaredRoutes();
  for (const prefix of PROJECT_ROUTE_PREFIXES) {
    assert.match(prefix, /^\/[a-z-]+$/, prefix);
    assert.ok(
      routes.some((r) => r.path === prefix || r.path.startsWith(`${prefix}/`)),
      `${prefix}로 시작하는 라우트가 없다 — 이 라우터 뒤에 붙는 다른 라우터의 같은 주소까지 막게 된다`,
    );
  }
});

test('입구는 이 목록으로 걸고, requireProjectMember는 무엇보다 먼저 같은 판정을 한다', () => {
  assert.match(source, /router\.use\(PROJECT_ROUTE_PREFIXES, async \(req, res, next\) => \{/);
  // 예전처럼 목록을 손으로 다시 적지 않는다.
  assert.doesNotMatch(source, /router\.use\(\[/);
  const start = source.indexOf('async function requireProjectMember(');
  const body = source.slice(start, source.indexOf('\n  }\n', start));
  const guest = body.indexOf('if (await rejectProjectGuest(req, res)) return null;');
  assert.ok(guest > 0, 'requireProjectMember가 준회원 막기를 한다');
  assert.ok(guest < body.indexOf('findProjectById('), '프로젝트를 찾기 전에 막는다');
  assert.ok(guest < body.indexOf('isProjectMember('), '구성원 확인 전에 막는다');
  // 계정은 한 요청에서 한 번만 읽는다(입구에서 읽었으면 다시 읽지 않는다).
  const reject = source.slice(source.indexOf('async function rejectProjectGuest('));
  assert.match(reject, /if \(req\.projectUseDenial === undefined\) \{\s*req\.projectUseDenial = projectUseDenial\(await findUserById\(req\.user\.sub\)\);/);
});

test('projectUseDenial: 준회원은 막고 서버 운영자는 등급과 무관하게 들인다', () => {
  const user = (fields = {}) => ({ id: 'u1', role: 'member', isServerAdmin: false, suspendedAt: null, deletedAt: null, ...fields });
  assert.equal(projectUseDenial(user()), null);
  assert.equal(projectUseDenial(user({ role: 'admin' })), null);
  assert.equal(projectUseDenial(user({ role: 'guest' })), PROJECT_GUEST_DENIAL);
  assert.equal(projectUseDenial(user({ role: 'guest', isServerAdmin: true })), null);
  // 모르는 등급 값은 준회원으로 본다(permissions.js accountRole).
  assert.equal(projectUseDenial(user({ role: 'owner' })), PROJECT_GUEST_DENIAL);
  assert.equal(projectUseDenial(user({ role: undefined })), PROJECT_GUEST_DENIAL);
  assert.equal(projectUseDenial(null), PROJECT_GUEST_DENIAL);
  assert.equal(PROJECT_GUEST_DENIAL, '프로젝트는 정회원 이상만 이용할 수 있습니다.');
});

test('입구를 통과하지 못하는 계정은 구성원 자격도 없다 — 입구가 구성원 규칙보다 넓게 막지 않는다', () => {
  // 입구(준회원 막기)를 통과한 정지·탈퇴 계정은 구성원 확인(isProjectMember)이 막는다. 거꾸로, 입구가 막는 계정 가운데 구성원 자격이
  // 있는 계정이 있으면 그 사람은 행이 있어도 자기 프로젝트를 못 연다 — 그런 계정이 없어야 한다.
  for (const role of ['guest', 'member', 'admin', 'owner', undefined]) {
    for (const isServerAdmin of [false, true]) {
      for (const suspendedAt of [null, new Date()]) {
        const u = { id: 'u1', role, isServerAdmin, suspendedAt, deletedAt: null };
        if (projectUseDenial(u)) assert.equal(isEligibleProjectAccount(u), false, JSON.stringify(u));
        if (isEligibleProjectAccount(u)) assert.equal(projectUseDenial(u), null, JSON.stringify(u));
      }
    }
  }
});
