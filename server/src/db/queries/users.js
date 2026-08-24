import { and, eq, isNull, lte, ne, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { users } from '../schema.js';

export function findUserById(id) {
  return db
    .select()
    .from(users)
    .where(eq(users.id, id))
    .then((rows) => rows[0] ?? null);
}

export function findUserByUsername(username) {
  return db
    .select()
    .from(users)
    .where(eq(users.username, username))
    .then((rows) => rows[0] ?? null);
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

export function findUserByUsernameAndEmailLookup(username, emailLookup) {
  return db
    .select()
    .from(users)
    .where(and(eq(users.username, username), eq(users.emailLookup, emailLookup)))
    .then((rows) => rows[0] ?? null);
}

/** 탈퇴한 사용자를 뺀 전체 가입자 목록 — 멤버 선택/멤버 패널용. */
export function listActiveUsers() {
  return db.select().from(users).where(isNull(users.deletedAt));
}

/** 새 공개 토픽을 만들 때 "지금 가입된 회원 전원"을 멤버로 넣는 데 쓴다. lowdb 시절 코드도
 * 탈퇴 여부를 따로 거르지 않았던 걸 그대로 유지한다(탈퇴자는 어차피 로그인이 막혀있어 실질적
 * 영향이 없음 — 마이그레이션 원칙상 동작을 바꾸지 않는다). */
export function listAllUserIds() {
  return db
    .select({ id: users.id })
    .from(users)
    .then((rows) => rows.map((r) => r.id));
}

export async function insertUser(fields) {
  const [row] = await db.insert(users).values(fields).returning();
  return row;
}

/** 부분 업데이트. 프로필 수정/아바타 변경/tokenVersion 증가/탈퇴 익명화/비밀번호 변경이 전부 이걸 쓴다. */
export async function updateUser(id, patch) {
  const [row] = await db.update(users).set(patch).where(eq(users.id, id)).returning();
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
