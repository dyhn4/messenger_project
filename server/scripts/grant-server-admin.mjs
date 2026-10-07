// 서버 운영자 복구 — 활성 서버 운영자(탈퇴·정지되지 않은 is_server_admin 계정)가 한 명도 없는 서버에서, 이미 가입해
// 있는(탈퇴하지 않은) 계정 하나를 서버 운영자로 지정하고, 정지돼 있었으면 정지도 푼다.
//
// 왜 필요한가: 예전엔 "운영자가 한 명도 없으면 다음 가입자가 운영자"여서, 마지막 운영자가 탈퇴한 서버는 다음 가입자
// (밖에서 공유된 초대 링크로 온 사람 포함)가 통째로 넘겨받았다. 지금은 계정이 하나도 없는 빈 서버의 첫 가입만 운영자가
// 되고(auth.js) 마지막 운영자는 탈퇴·정지·해제할 수 없지만(db/queries/users.js updateUserUnlessLastServerAdmin), 그 전에
// 이미 운영자가 없어진 서버는 관리자 콘솔에 들어갈 사람도, 데이터 초기화·복원·완전 삭제의 본인 확인(verify-admin.mjs)을
// 통과할 사람도 없다. 그런 서버를 서버 PC에서 되살리는 길이 이 스크립트다 — .env(DB 접속 정보)를 읽을 수 있는 사람은
// 어차피 DB를 직접 고칠 수 있으므로 따로 비밀번호를 묻지 않는다.
//
// 활성 운영자가 한 명이라도 있으면 아무것도 바꾸지 않는다(exit 1) — 그때는 그 운영자가 관리자 콘솔에서 지정·정지 해제를
// 한다. 바꾸는 것은 대상 계정의 is_server_admin(true)과 suspended_at(null)뿐이고(등급·토큰·다른 계정은 그대로 — 로그인해
// 있던 기기도 끊지 않는다), 관리자 콘솔에서 지정할 때처럼 감사 로그를 한 줄 남긴다.
//
// 사용법(현재 폴더 = server 폴더):
//   개발 PC      node scripts/grant-server-admin.mjs <아이디>
//   설치된 서버  관리자 권한 PowerShell에서 cd C:\TangoTalk-Server\server 한 뒤(설치 폴더를 바꿨으면 그 폴더의 server)
//                ..\node\node.exe scripts\grant-server-admin.mjs <아이디>
//                — .env가 관리자 전용이라 관리자 권한이 필요하다. 설치 프로그램은 이 스크립트를 불러 주는
//                Grant-ServerAdmin.ps1도 설치 폴더에 넣는다(messenger-server.iss).
// 종료 코드: 0 지정함 · 1 거절(활성 운영자가 이미 있음, 그 아이디의 계정이 없음, 대소문자만 다른 아이디가 여럿, 탈퇴한
//            계정) · 2 사용법·.env·DB 오류
//
// 판단·문구·트랜잭션 흐름은 함수로 내보내 DB 없이 단위 테스트한다(test/grantServerAdmin.test.js) — 그래서 직접 실행했을
// 때만(runDirectly) .env를 읽고 DB에 붙는다.
import dotenv from 'dotenv';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

export const EXIT_OK = 0;
export const EXIT_REFUSED = 1;
export const EXIT_ERROR = 2;

const USAGE = [
  '사용법: node scripts/grant-server-admin.mjs <아이디>   (server 폴더에서)',
  '  설치된 서버는 관리자 권한 PowerShell에서: ..\\node\\node.exe scripts\\grant-server-admin.mjs <아이디>',
  '  서버 운영자가 한 명도 없을 때만, 이미 가입한 계정 하나를 서버 운영자로 지정합니다.',
].join('\n');

/**
 * 명령줄 인자 → `{ username }` | `{ error }`. 아이디는 정확히 하나(공백이 든 아이디는 따옴표로 감싼다). 앞뒤 공백은 앱의 로그인과
 * 같이 뗀다(auth.js — 앱도 입력한 아이디의 앞뒤 공백을 떼고 보낸다).
 */
export function parseArgs(args) {
  const username = typeof args[0] === 'string' ? args[0].trim() : '';
  if (args.length !== 1 || !username || ['-h', '--help', '/?'].includes(username)) return { error: USAGE };
  return { username };
}

/** 관리자 콘솔에 실제로 들어올 수 있는 서버 운영자 — 탈퇴·정지되지 않은 운영자(verify-admin.mjs, db/queries/users.js와 같은 기준). */
export function isActiveServerAdmin(account) {
  return account.isServerAdmin === true && !account.deletedAt && !account.suspendedAt;
}

/**
 * 지정할지 정한다 — DB를 안 건드리는 순수 판단. [admins]는 is_server_admin인 계정들, [candidates]는 아이디가 [username]과
 * 대소문자를 무시하고 같은 계정들(DB가 고른 그대로 — 글자까지 같은 계정도 여기 들어 있다). 계정 모양:
 * `{ id, username, name, isServerAdmin, deletedAt, suspendedAt }`.
 *
 * 아이디는 가입한 그대로 저장되고(대소문자를 바꾸지 않는다) 로그인(auth.js — authGuard.js pickUsernameMatch)과 같은 규칙으로
 * 고른다: 글자까지 같은 계정이 있으면 그것만 본다(그 계정이 탈퇴했어도 대소문자만 다른 다른 사람으로 넘어가지 않는다). 없을
 * 때만 대소문자만 다른 계정을 받아 주되, 그런 계정이 둘 이상이면(새 아이디 규칙 전에 'Kim'·'kim'이 따로 가입한 서버) 누구인지
 * 모르니 거절한다.
 *
 * 돌려주는 값: `{ ok: true, user }` | `{ ok: false, reason: 'active-admin', activeAdmins }` | `{ ok: false, reason:
 * 'not-found' }` | `{ ok: false, reason: 'ambiguous', usernames }` | `{ ok: false, reason: 'withdrawn', user }`.
 */
export function decideGrant({ username, admins, candidates }) {
  const activeAdmins = admins.filter(isActiveServerAdmin);
  if (activeAdmins.length > 0) {
    return { ok: false, reason: 'active-admin', activeAdmins: activeAdmins.map((a) => a.username).sort() };
  }
  const exact = candidates.filter((c) => c.username === username);
  const matches = exact.length > 0 ? exact : candidates;
  if (matches.length === 0) return { ok: false, reason: 'not-found' };
  if (matches.length > 1) return { ok: false, reason: 'ambiguous', usernames: matches.map((m) => m.username).sort() };
  const [user] = matches;
  if (user.deletedAt) return { ok: false, reason: 'withdrawn', user };
  return { ok: true, user };
}

/** "'kim'(김철수)" — 이름이 아이디와 같으면 아이디만. */
function accountLabel(user) {
  return user.name && user.name !== user.username ? `'${user.username}'(${user.name})` : `'${user.username}'`;
}

/** 거절했을 때 보여줄 줄들 — 무엇을 하면 되는지까지. */
export function refusalLines(decision, username) {
  switch (decision.reason) {
    case 'active-admin':
      return [
        `이미 서버 운영자가 있어 아무것도 바꾸지 않았습니다: ${decision.activeAdmins.join(', ')}`,
        '이 스크립트는 서버 운영자가 한 명도 없을 때만 씁니다 — 운영자 지정·정지 해제는 그 운영자 계정으로 관리자 콘솔에서 하세요.',
      ];
    case 'not-found':
      return [
        `아이디가 '${username}'인 계정이 없습니다. 이미 가입한 계정의 아이디를 입력하세요.`,
        '쓸 계정이 아직 없다면 사내 와이파이에서 앱으로 먼저 가입한 뒤 다시 실행하세요.',
      ];
    case 'ambiguous':
      return [
        `'${username}'와(과) 대소문자만 다른 아이디가 여럿이라 어느 계정인지 정할 수 없습니다: ${decision.usernames.join(', ')}`,
        '그중 하나를 대소문자까지 똑같이 입력해 다시 실행하세요.',
      ];
    case 'withdrawn':
      // 탈퇴하면 이름이 "탈퇴한 사용자"로 바뀌므로 아이디만 보인다.
      return [
        `'${decision.user.username}'은(는) 탈퇴한 계정이라 서버 운영자로 지정할 수 없습니다.`,
        '탈퇴하지 않은 다른 계정을 고르세요(없다면 사내 와이파이에서 앱으로 새로 가입한 뒤 다시 실행하세요).',
      ];
    default:
      return ['서버 운영자로 지정하지 않았습니다.'];
  }
}

/** 지정한 뒤 보여줄 줄들 — [user]는 바꾸기 전의 계정, [audited]는 감사 로그를 남겼는지. */
export function successLines(user, { audited }) {
  const done = user.isServerAdmin
    ? `${accountLabel(user)} 계정의 정지를 풀었습니다 — 이미 서버 운영자였으므로 이제 관리자 콘솔에 들어갈 수 있습니다.`
    : `${accountLabel(user)} 계정을 서버 운영자로 지정했습니다${user.suspendedAt ? '(정지돼 있던 것도 풀었습니다)' : ''}.`;
  const lines = [done, '그 계정으로 로그인하면 관리자 콘솔을 쓸 수 있습니다 — 이미 로그인해 있다면 앱을 다시 시작하세요.'];
  if (!audited) lines.push('(감사 로그는 남기지 못했습니다 — 지정은 그대로 적용됐습니다.)');
  return lines;
}

/** 감사 로그를 남긴 주체 — 관리자 콘솔이 아니라 서버 PC에서 한 일이라 계정 없이 이름만 남긴다. */
const AUDIT_ACTOR_NAME = '서버 PC(grant-server-admin.mjs)';

/**
 * 남길 감사 로그 — 관리자 콘솔의 운영자 지정·정지 해제와 같은 종류(audit.js의 AUDIT.userServerAdmin·userUnsuspend)라 콘솔
 * 감사 로그에서 같은 이름으로 보이고 같은 필터에 걸린다. [user]는 바꾸기 전의 계정.
 */
export function auditEntryFor(user) {
  const how = '운영자가 없는 서버 복구 — 서버 PC에서 grant-server-admin.mjs로';
  if (user.isServerAdmin) return { action: 'user.unsuspend', detail: `정지 해제(${how})` };
  return {
    action: 'user.serverAdmin',
    detail: user.suspendedAt ? `서버 운영자로 지정·정지 해제(${how})` : `서버 운영자로 지정(${how})`,
  };
}

/**
 * 감사 로그 한 줄. 기록에 실패해도 지정은 그대로 한다(audit.js recordAudit와 같은 규칙) — 같은 트랜잭션 안이라 실패한 문장
 * 하나가 트랜잭션 전체를 망치지 않게 세이브포인트로 그 한 줄만 되돌린다. 남겼으면 true.
 */
async function recordAudit(client, user) {
  const { action, detail } = auditEntryFor(user);
  await client.query('SAVEPOINT grant_audit');
  try {
    await client.query(
      `INSERT INTO audit_logs (actor_name, action, target_type, target_id, target_label, detail)
       VALUES ($1, $2, 'user', $3, $4, $5)`,
      [AUDIT_ACTOR_NAME, action, user.id, user.name ?? user.username, detail],
    );
    await client.query('RELEASE SAVEPOINT grant_audit');
    return true;
  } catch {
    await client.query('ROLLBACK TO SAVEPOINT grant_audit');
    return false;
  }
}

/** 이 스크립트가 직접 내는 오류 — 문구에 접속 정보가 없으니 그대로 보여 준다(describeDbError). */
class GrantError extends Error {}

// 확인에 읽는 계정 열 — 순수 판단(decideGrant)이 읽는 이름으로 바꿔 읽는다.
const ACCOUNT_COLUMNS =
  'id, username, name, is_server_admin AS "isServerAdmin", deleted_at AS "deletedAt", suspended_at AS "suspendedAt"';

/**
 * 한 트랜잭션에서 확인하고 바꾼다 — [client]는 연결된 pg.Client(테스트는 query만 있는 가짜). decideGrant의 결과를
 * 돌려주고, 지정했으면 거기에 감사 로그를 남겼는지(audited)를 더한다. 거절이면 아무것도 바꾸지 않고 롤백한다. DB 오류는
 * 롤백한 뒤 그대로 던진다.
 */
export async function grantServerAdmin(client, username) {
  await client.query('BEGIN');
  try {
    // 다른 작업이 계정 행을 오래 잠그고 있으면 끝없이 기다리지 않고 오류로 끝낸다(잠시 뒤 다시 실행하면 된다).
    await client.query("SET LOCAL lock_timeout = '15s'");
    // 이 스크립트를 두 창에서 동시에 돌려도 확인·지정을 하나씩 차례로 하게 한다 — 활성 운영자가 없으면 아래 FOR UPDATE가
    // 잠글 활성 운영자 행이 없어서, 행 잠금만으로는 두 실행이 서로 다른 계정을 함께 지정하는 걸 못 막는다(이 잠금은
    // 커밋·롤백 때 저절로 풀린다 — db/queries/users.js insertRegisteredUser의 첫 계정 잠금과 같은 방식).
    await client.query("SELECT pg_advisory_xact_lock(hashtext('users:grant-server-admin'))");
    // 운영자 행을 잠근 채 센다 — 탈퇴·정지·운영자 해제의 "마지막 운영자" 확인(updateUserUnlessLastServerAdmin)도 활성
    // 운영자 행을 잠그고 세므로, 이 확인과 지정 사이에 운영자 상태가 엇갈려 바뀌지 않는다.
    const admins = await client.query(`SELECT ${ACCOUNT_COLUMNS} FROM users WHERE is_server_admin = true ORDER BY id FOR UPDATE`);
    // 대상 계정도 잠가서, 확인한 뒤 바꾸기 전에 그 계정이 탈퇴하는 등으로 달라지지 않게 한다.
    const candidates = await client.query(
      `SELECT ${ACCOUNT_COLUMNS} FROM users WHERE lower(username) = lower($1::text) ORDER BY id FOR UPDATE`,
      [username],
    );
    const decision = decideGrant({ username, admins: admins.rows, candidates: candidates.rows });
    if (!decision.ok) {
      await client.query('ROLLBACK');
      return decision;
    }
    const updated = await client.query(
      'UPDATE users SET is_server_admin = true, suspended_at = NULL WHERE id = $1 AND deleted_at IS NULL',
      [decision.user.id],
    );
    // 위에서 잠근 행이라 그새 바뀔 수 없지만, 못 바꿨는데 "지정했다"고 알리는 일은 없게 한 번 더 본다.
    if (updated.rowCount !== 1) throw new GrantError('대상 계정을 바꾸지 못했습니다(다시 실행해 보세요).');
    const audited = await recordAudit(client, decision.user);
    await client.query('COMMIT');
    return { ...decision, audited };
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw err;
  }
}

/** 자주 나는 접속·DB 오류의 안내(오류 code → 할 일). */
const DB_ERROR_HINTS = {
  ECONNREFUSED: 'PostgreSQL에 연결할 수 없습니다 — PostgreSQL 서비스가 실행 중인지 확인하세요',
  ETIMEDOUT: 'PostgreSQL에 연결하다 시간이 초과됐습니다 — PostgreSQL 서비스가 실행 중인지 확인하세요',
  ENOTFOUND: 'DB 서버 주소를 찾을 수 없습니다 — .env의 DATABASE_URL을 확인하세요',
  ERR_INVALID_URL: '.env의 DATABASE_URL 형식이 올바르지 않습니다',
  '28P01': 'DB 비밀번호가 맞지 않습니다 — .env의 DATABASE_URL을 확인하세요',
  '3D000': 'DATABASE_URL의 데이터베이스가 없습니다 — .env를 확인하세요',
  '42P01': '필요한 표가 없습니다 — 서버를 한 번도 실행하지 않은(마이그레이션 전) DB이거나 다른 DB입니다',
  '55P03': '다른 작업이 계정 정보를 잠그고 있어 기다리다 멈췄습니다 — 잠시 뒤 다시 실행하세요',
  '40P01': '다른 작업과 엇갈려 멈췄습니다 — 다시 실행하세요',
};

/**
 * 오류를 한 줄로 — DATABASE_URL(비밀번호 포함)이 화면에 나오지 않게, 접속 단계의 오류(네트워크·주소 해석 등)는 문구를 쓰지
 * 않고 code만 보인다(그 문구에는 접속 주소나 .env의 값이 섞일 수 있다 — pg의 접속 설정 오류는 "Invalid <키>: <값>"처럼
 * 값을 그대로 싣는다). PostgreSQL 서버가 돌려준 오류(severity가 있다)는 접속 정보가 들어가지 않으므로 문구도 보이고, 이
 * 스크립트가 직접 낸 오류(GrantError)도 문구를 그대로 쓴다.
 */
export function describeDbError(err) {
  if (err instanceof GrantError) return err.message;
  const code = typeof err?.code === 'string' ? err.code : null;
  if (code && DB_ERROR_HINTS[code]) return `${DB_ERROR_HINTS[code]} (${code})`;
  if (err?.severity) return `DB 오류 (${code ?? '코드 없음'}): ${err.message}`;
  if (code) return `DB 오류 (${code})`;
  // pg가 연결 시간 제한(connectionTimeoutMillis)에 걸렸을 때 내는 고정 문구 — 값이 섞이지 않는다.
  if (err?.message === 'timeout expired') return 'PostgreSQL이 응답하지 않아 연결을 멈췄습니다 — PostgreSQL 서비스가 실행 중인지 확인하세요';
  return 'DB 오류';
}

/** .env에서 DATABASE_URL을 얻지 못했을 때 — 읽지 못한 까닭(dotenv가 돌려준 파일 오류)에 맞춰 안내한다. */
export function envErrorMessage(readError, envPath) {
  if (readError?.code === 'ENOENT') return `.env 파일이 없습니다(${envPath}) — 서버 설정이 끝난 server 폴더의 스크립트로 실행하세요.`;
  if (readError?.code === 'EPERM' || readError?.code === 'EACCES') {
    return '.env 파일을 읽을 권한이 없습니다 — 관리자 권한으로 실행하세요(설치된 서버의 .env는 관리자만 읽을 수 있습니다).';
  }
  if (readError) return `.env 파일을 읽지 못했습니다(${readError.code ?? '알 수 없는 오류'}).`;
  return '.env에 DATABASE_URL이 없습니다.';
}

async function main(args) {
  const parsed = parseArgs(args);
  if (parsed.error) {
    console.error(parsed.error);
    return EXIT_ERROR;
  }

  // verify-admin.mjs와 같은 방식 — 실행한 폴더와 상관없이 이 스크립트 위 server 폴더의 .env를 읽는다.
  const envPath = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '.env');
  const loaded = dotenv.config({ path: envPath, quiet: true });
  if (!process.env.DATABASE_URL) {
    console.error(envErrorMessage(loaded.error, envPath));
    return EXIT_ERROR;
  }

  let client;
  try {
    client = new pg.Client({ connectionString: process.env.DATABASE_URL, connectionTimeoutMillis: 15_000 });
    // 연결이 쉬는 사이 끊겨도 처리 안 된 'error' 이벤트로 죽지 않게 — 쿼리 중이면 그 쿼리가 오류로 끝난다.
    client.on('error', () => {});
    await client.connect();
  } catch (err) {
    console.error(`DB에 연결하지 못했습니다 — ${describeDbError(err)}`);
    await client?.end().catch(() => {});
    return EXIT_ERROR;
  }

  try {
    const result = await grantServerAdmin(client, parsed.username);
    if (!result.ok) {
      for (const line of refusalLines(result, parsed.username)) console.error(line);
      return EXIT_REFUSED;
    }
    for (const line of successLines(result.user, { audited: result.audited })) console.log(line);
    return EXIT_OK;
  } catch (err) {
    console.error(`서버 운영자로 지정하지 못했습니다 — ${describeDbError(err)}`);
    return EXIT_ERROR;
  } finally {
    await client.end().catch(() => {});
  }
}

/**
 * `node scripts/grant-server-admin.mjs ...`로 직접 실행됐는지 — 테스트가 함수만 불러갈 때는 .env를 읽거나 DB에 붙지 않게.
 * 실행 경로를 링크를 푼 실제 경로로 바꿔 이 파일과 비교한다(윈도의 path.relative는 대소문자를 가리지 않는다).
 */
function runDirectly() {
  if (!process.argv[1]) return false;
  try {
    return path.relative(fs.realpathSync(process.argv[1]), fileURLToPath(import.meta.url)) === '';
  } catch {
    return false;
  }
}

// process.exit 대신 exitCode — 출력을 다 내보낸 뒤 연결이 닫히면 저절로 끝난다.
if (runDirectly()) process.exitCode = await main(process.argv.slice(2));
