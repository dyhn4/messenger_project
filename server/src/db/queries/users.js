import { and, eq, inArray, isNull, lte, ne, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { users } from '../schema.js';
import { invalidateAccountState } from '../../authState.js';

export function findUserById(id) {
  return db
    .select()
    .from(users)
    .where(eq(users.id, id))
    .then((rows) => rows[0] ?? null);
}

/**
 * 아이디가 글자까지 그대로 같은 계정(대소문자도 구분한다 — 팀 설정 "아이디로 찾기"). 로그인·비밀번호 찾기는 대소문자만 다른
 * 옛 아이디도 찾아야 해서 아래 listUsersByUsernameIgnoringCase를 쓴다.
 */
export function findUserByUsername(username) {
  return db
    .select()
    .from(users)
    .where(eq(users.username, username))
    .then((rows) => rows[0] ?? null);
}

/**
 * 아이디가 대소문자만 다르거나 같은 계정 — users.username의 unique는 글자 그대로만 비교해서, 새 아이디 규칙(authGuard.js
 * parseNewUsername) 전에는 'Kim'과 'kim'이 따로 가입할 수 있었다. 아직 lower(username) 색인이 없어 계정 표 전체를 훑는다
 * (사내 메신저의 계정 표는 작다 — 겹치는 옛 아이디를 정리한 뒤 lower(username) unique 색인을 더하면 그 색인을 탄다).
 */
const usernameIgnoringCase = (username) => sql`lower(${users.username}) = lower(${username})`;

/** 아이디가 [username]과 대소문자를 무시하고 같은 계정들(탈퇴 포함) — 어느 계정인지는 authGuard.js pickUsernameMatch가 고른다. */
export function listUsersByUsernameIgnoringCase(username) {
  return db.select().from(users).where(usernameIgnoringCase(username));
}

/** 새 아이디로 쓸 수 없는지 — 대소문자만 다른 아이디도 이미 있는 것으로 본다(탈퇴한 계정의 아이디도 그대로 남아 있다). */
export function isUsernameTakenIgnoringCase(username) {
  return db
    .select({ id: users.id })
    .from(users)
    .where(usernameIgnoringCase(username))
    .limit(1)
    .then((rows) => rows.length > 0);
}

export function findUserByEmailLookup(emailLookup) {
  return db
    .select()
    .from(users)
    .where(eq(users.emailLookup, emailLookup))
    .then((rows) => rows[0] ?? null);
}

/** users.js의 프로필 이메일 변경 시 "나 말고 다른 사람이 이 이메일을 이미 쓰고 있는지" 확인용. */
export function findOtherUserByEmailLookup(emailLookup, excludeUserId) {
  return db
    .select()
    .from(users)
    .where(and(eq(users.emailLookup, emailLookup), ne(users.id, excludeUserId)))
    .then((rows) => rows[0] ?? null);
}

/**
 * 탈퇴한 사용자를 뺀 전체 가입자 목록 — 서버 전체를 보는 사람(계정 등급 관리자·서버 운영자, userDirectory.js)에게 주는 회원
 * 목록(GET /users)과 팀원 추가 후보(teams.js GET /teams/:id/member-candidates)용.
 */
export function listActiveUsers() {
  return db.select().from(users).where(isNull(users.deletedAt));
}

/**
 * [ids] 가운데 탈퇴하지 않은 계정 — 회원 목록(GET /users)과 팀원 추가 후보(teams.js GET /teams/:id/member-candidates)를 팀을
 * 같이 쓰는 사람(과 자기 자신)으로 좁혀 줄 때(users.js·teams.js, userDirectory.js). id가 없으면 DB에 묻지 않는다.
 */
export function listActiveUsersByIds(ids) {
  const unique = [...new Set(ids)];
  if (unique.length === 0) return Promise.resolve([]);
  return db
    .select()
    .from(users)
    .where(and(inArray(users.id, unique), isNull(users.deletedAt)));
}

/** 새 공개 토픽을 만들 때 "지금 가입된 회원 전원"을 멤버로 넣는 데 쓴다. 탈퇴한 사용자는
 * 멤버 목록에 남아있을 필요가 없으므로 제외한다. */
export function listAllUserIds() {
  return db
    .select({ id: users.id })
    .from(users)
    .where(isNull(users.deletedAt))
    .then((rows) => rows.map((r) => r.id));
}

/**
 * 가입한 계정을 넣는다 — 서버에 계정이 하나도 없을 때(새로 설치했거나 DB 데이터를 초기화한 서버의 첫 가입)만
 * [firstAccountFields](관리자 등급 + 서버 운영자, auth.js)를 더한다. 확인과 넣기를 가입끼리만 줄 세우는 잠금
 * (트랜잭션 advisory lock — 커밋·롤백 때 저절로 풀린다) 안에서 해서, 빈 서버에 가입이 동시에 둘 들어와도 운영자는
 * 한 명만 생긴다(빈 표에는 잠글 행이 없어 행 잠금으로는 못 막는다). { user, firstAccount }를 돌려준다.
 *
 * 같은 잠금 안에서 대소문자만 다른 같은 아이디가 이미 있는지도 다시 본다 — 가입 화면의 확인(auth.js)과 이 넣기 사이에
 * 'Kim'과 'kim'이 동시에 들어와도 하나만 들어가게(users.username의 unique는 글자 그대로만 비교한다). 있으면 넣지 않고
 * { user: null, firstAccount: false, usernameTaken: true }를 준다. 빈 서버의 첫 가입은 겹칠 계정이 없어 보지 않는다.
 */
export function insertRegisteredUser(fields, firstAccountFields) {
  return db.transaction(async (tx) => {
    await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtext('users:first-account'))`);
    const [existing] = await tx.select({ id: users.id }).from(users).limit(1);
    const firstAccount = !existing;
    if (!firstAccount) {
      const taken = await tx.execute(sql`select 1 from ${users} where ${usernameIgnoringCase(fields.username)} limit 1`);
      if (taken.rows.length > 0) return { user: null, firstAccount: false, usernameTaken: true };
    }
    const [user] = await tx
      .insert(users)
      .values(firstAccount ? { ...fields, ...firstAccountFields } : fields)
      .returning();
    return { user, firstAccount };
  });
}

/** 토큰 버전·정지·탈퇴가 바뀌면 요청 인증(authState.js)이 기억해 둔 상태를 바로 버린다. */
function forgetAccountStateIfChanged(id, patch) {
  if ('tokenVersion' in patch || 'suspendedAt' in patch || 'deletedAt' in patch) invalidateAccountState(id);
}

/** 부분 업데이트. 프로필 수정/아바타 변경/tokenVersion 증가/탈퇴 익명화/비밀번호 변경이 전부 이걸 쓴다. */
export async function updateUser(id, patch) {
  const [row] = await db.update(users).set(patch).where(eq(users.id, id)).returning();
  forgetAccountStateIfChanged(id, patch);
  return row;
}

/** 관리자 콘솔에 실제로 들어올 수 있는 서버 운영자 — 탈퇴·정지되지 않은 운영자(scripts/verify-admin.mjs와 같은 기준). */
const activeServerAdmin = () => and(eq(users.isServerAdmin, true), isNull(users.deletedAt), isNull(users.suspendedAt));

/**
 * 서버 운영자 자격을 거두는 변경(탈퇴·정지·운영자 해제)을 적용하되, 그러면 활성 운영자가 한 명도 안 남게 될 때는
 * 바꾸지 않고 null을 준다. 마지막 운영자가 빠지면 아무도 관리자 콘솔(회원 정지·등급·운영자 지정)에 못 들어가고,
 * 서버 데이터 초기화·완전 삭제의 본인 확인(verify-admin.mjs)도 통과할 사람이 없어진다. 활성 운영자 행을 잠근 채
 * (FOR UPDATE) 세고 바꿔서, 운영자 둘이 동시에 서로를 해제하거나 함께 탈퇴해도 0명이 되지 않는다(늦게 온 쪽은 앞의
 * 변경이 끝난 뒤의 행으로 다시 센다). 대상이 활성 운영자가 아니면 그냥 적용한다.
 */
export async function updateUserUnlessLastServerAdmin(id, patch) {
  const row = await db.transaction(async (tx) => {
    const admins = await tx.select({ id: users.id }).from(users).where(activeServerAdmin()).for('update');
    if (admins.length === 1 && admins[0].id === id) return null;
    const [updated] = await tx.update(users).set(patch).where(eq(users.id, id)).returning();
    return updated ?? null;
  });
  if (row) forgetAccountStateIfChanged(id, patch);
  return row;
}

/** 보존기간(1년)이 지났는데 아직 메시지를 안 지운 탈퇴 계정들 — retention.js. */
export function listUsersEligibleForMessagePurge(retentionMs) {
  const cutoff = sql`now() - (${retentionMs}::bigint * interval '1 millisecond')`;
  return db
    .select()
    .from(users)
    .where(and(sql`${users.deletedAt} IS NOT NULL`, isNull(users.messagesPurgedAt), lte(users.deletedAt, cutoff)));
}

/**
 * 관리자 콘솔의 회원 목록 — 탈퇴한 계정까지 전부 포함한다(탈퇴 이력도 운영 정보라서).
 * 가입 순서대로 준다. 팀 소속 수/마지막 접속은 라우터에서 따로 붙인다.
 */
export function listAllUsersForAdmin() {
  return db.select().from(users).orderBy(users.createdAt);
}

/** 서버에 남아있는 계정 수(탈퇴 제외) — 운영 현황 대시보드용. */
export function countActiveUsers() {
  return db
    .select({ value: sql`count(*)::int` })
    .from(users)
    .where(isNull(users.deletedAt))
    .then((rows) => rows[0]?.value ?? 0);
}
