// 프로젝트 구성원 자격 테스트 — `node --test test/projectMembership.test.js` (DB·서버 없이 돈다).
// 정지·탈퇴·준회원 강등된 계정은 project_members 행이 남아 있어도 구성원이 아니다(S7). 같은 규칙이 두 곳에 있다:
// JS 쪽(projectNotifications.js isEligibleProjectAccount — 자동화 저장자 확인 등)과 SQL 쪽(db/queries/projects.js
// projectAccountEligibleSql — 구성원 확인·목록·알림 대상 거르기). 여기서는 두 규칙이 같은 결론을 내는지, SQL 조건이 자동 참여
// 행뿐 아니라 모든 구성원 행에 걸리는지, 그리고 구성원으로 넣을 때(초대·프로젝트 만들기)의 규칙을 본다.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { PgDialect } from 'drizzle-orm/pg-core';
import { isEligibleProjectAccount, projectInviteDenial } from '../src/projectNotifications.js';

// db/queries/projects.js는 db/client.js를 불러 접속 주소가 없으면 프로세스를 끝낸다 — 모듈만 불러오고 이 연결로는 아무것도
// 묻지 않는다(쿼리 조건을 SQL 글자로 바꿔 보기만 한다). test/teamRemoval.test.js와 같은 방식.
process.env.DATABASE_URL ??= 'postgres://test:test@127.0.0.1:9/unused';
const { ACTIVE_PROJECT_MEMBER, projectAccountEligibleSql } = await import('../src/db/queries/projects.js');

const NOW = new Date('2026-10-07T00:00:00Z');

/** 사용자 행 하나 — 기본은 정지·탈퇴 안 한 정회원. */
function user(fields = {}) {
  return { id: 'u1', role: 'member', isServerAdmin: false, suspendedAt: null, deletedAt: null, ...fields };
}

/** 자격이 갈리는 경우들 — 계정 등급 × 서버 운영자 × 정지 × 탈퇴, 그리고 모르는 등급 값. */
const MATRIX = [];
for (const role of ['guest', 'member', 'admin', 'owner', undefined]) {
  for (const isServerAdmin of [false, true]) {
    for (const suspendedAt of [null, NOW]) {
      for (const deletedAt of [null, NOW]) {
        MATRIX.push(user({ role, isServerAdmin, suspendedAt, deletedAt }));
      }
    }
  }
}

/**
 * projectAccountEligibleSql이 만드는 조건 글자를 JS 함수로 옮긴다 — 이 조건에 나오는 모양(`x.col is null`, `x.role in (…)`,
 * `x.is_server_admin`, and/or, 괄호)만 알아듣는다. 모르는 모양이 남으면 함수 만들기가 실패해 테스트가 깨진다.
 */
function sqlConditionToJs(condition) {
  const js = condition
    .replace(/\b\w+\.(\w+) is null\b/g, '(row.$1 == null)')
    .replace(/\b\w+\.role in \(([^)]*)\)/g, '[$1].includes(row.role)')
    .replace(/\b\w+\.is_server_admin\b/g, '(row.is_server_admin === true)')
    .replace(/\band\b/g, '&&')
    .replace(/\bor\b/g, '||');
  return new Function('row', `return ${js};`);
}

const toRow = (u) => ({
  role: u.role,
  is_server_admin: u.isServerAdmin,
  suspended_at: u.suspendedAt,
  deleted_at: u.deletedAt,
});

test('isEligibleProjectAccount: 정회원 이상 또는 서버 운영자이면서 정지·탈퇴하지 않은 계정만', () => {
  assert.equal(isEligibleProjectAccount(user()), true);
  assert.equal(isEligibleProjectAccount(user({ role: 'admin' })), true);
  // 준회원은 구성원이 아니다 — 서버 운영자는 예외(projects.js 라우터 입구 규칙과 같다).
  assert.equal(isEligibleProjectAccount(user({ role: 'guest' })), false);
  assert.equal(isEligibleProjectAccount(user({ role: 'guest', isServerAdmin: true })), true);
  // 모르는 등급 값은 가장 약한 등급(준회원)으로 본다(permissions.js accountRole).
  assert.equal(isEligibleProjectAccount(user({ role: 'owner' })), false);
  assert.equal(isEligibleProjectAccount(user({ role: undefined })), false);
  // 정지·탈퇴는 등급·운영자 여부와 무관하게 자격을 잃는다.
  assert.equal(isEligibleProjectAccount(user({ suspendedAt: NOW })), false);
  assert.equal(isEligibleProjectAccount(user({ role: 'admin', deletedAt: NOW })), false);
  assert.equal(isEligibleProjectAccount(user({ role: 'admin', isServerAdmin: true, suspendedAt: NOW })), false);
  assert.equal(isEligibleProjectAccount(null), false);
  assert.equal(isEligibleProjectAccount(undefined), false);
});

test('projectAccountEligibleSql: SQL 조건이 JS 규칙(isEligibleProjectAccount)과 모든 경우에 같은 결론을 낸다', () => {
  const condition = projectAccountEligibleSql('amu');
  assert.equal(
    condition,
    "amu.deleted_at is null and amu.suspended_at is null and (amu.role in ('member', 'admin') or amu.is_server_admin)",
  );
  const eligible = sqlConditionToJs(condition);
  assert.equal(MATRIX.length, 40);
  for (const u of MATRIX) {
    assert.equal(eligible(toRow(u)), isEligibleProjectAccount(u), `role=${u.role} admin=${u.isServerAdmin} suspended=${!!u.suspendedAt} deleted=${!!u.deletedAt}`);
  }
});

test('ACTIVE_PROJECT_MEMBER: 자격 조건이 자동 참여 행만이 아니라 모든 구성원 행에 걸린다', () => {
  const { sql, params } = new PgDialect().sqlToQuery(ACTIVE_PROJECT_MEMBER);
  assert.deepEqual(params, []);
  // 그 프로젝트의 팀에 아직 있어야 하고(팀 멤버십 join), 계정이 자격을 지녀야 한다.
  assert.match(sql, /join "team_members" amt on amt\.team_id = amp\.team_id and amt\.user_id = "project_members"\."user_id"/);
  assert.match(sql, /join "users" amu on amu\.id = amt\.user_id/);
  assert.match(sql, /where amp\.id = "project_members"\."project_id" and /);
  assert.ok(sql.includes(projectAccountEligibleSql('amu')), sql);
  // 예전 조건은 "(not auto or 자격)"이라 초대받은 행(auto = false)에는 자격을 보지 않았다 — 이제 auto와 무관하다.
  assert.doesNotMatch(sql, /auto/);
});

test('projectInviteDenial: 남이 넣을 수 있는 사람은 정지·탈퇴하지 않은 정회원 이상', () => {
  assert.equal(projectInviteDenial(user()), null);
  assert.equal(projectInviteDenial(user({ role: 'admin' })), null);
  assert.equal(projectInviteDenial(user({ role: 'admin', isServerAdmin: true })), null);
  const guestError = '프로젝트는 정회원 이상만 참여할 수 있습니다.';
  assert.equal(projectInviteDenial(user({ role: 'guest' })), guestError);
  // 초대는 예전처럼 준회원이면 서버 운영자여도 막는다(운영자는 스스로 참여하거나 직접 만든다).
  assert.equal(projectInviteDenial(user({ role: 'guest', isServerAdmin: true })), guestError);
  assert.equal(projectInviteDenial(user({ role: 'owner' })), guestError);
  const goneError = '탈퇴했거나 정지된 사용자는 프로젝트에 추가할 수 없습니다.';
  assert.equal(projectInviteDenial(user({ suspendedAt: NOW })), goneError);
  assert.equal(projectInviteDenial(user({ deletedAt: NOW })), goneError);
  assert.equal(projectInviteDenial(user({ role: 'guest', deletedAt: NOW })), goneError);
  assert.equal(projectInviteDenial(null), goneError);
});

test('projectInviteDenial로 넣을 수 있는 사람은 넣은 뒤에도 구성원 자격이 있다', () => {
  // 넣기는 했는데 구성원으로 치지 않는 행(조용히 무시되는 초대)이 생기지 않는지 — 초대 규칙이 자격 규칙보다 넓으면 안 된다.
  for (const u of MATRIX) {
    if (projectInviteDenial(u) === null) assert.equal(isEligibleProjectAccount(u), true, JSON.stringify(u));
  }
});
