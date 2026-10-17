import { and, eq, inArray, isNull, ne } from 'drizzle-orm';
import { db } from '../client.js';
import { mailAccounts, teamMembers, users } from '../schema.js';

export async function findMailAccount(userId) {
  const [row] = await db.select().from(mailAccounts).where(eq(mailAccounts.userId, userId));
  return row ?? null;
}

/** 넣거나(처음) 바꾸기 — 연결 값이 바뀌면 새 메일 기준(UIDNEXT)과 오류를 지운다. */
export async function upsertMailAccount(userId, values) {
  const reset = { lastUidNext: null, lastUidValidity: null, lastError: null, lastErrorAt: null, updatedAt: new Date() };
  const [row] = await db
    .insert(mailAccounts)
    .values({ userId, ...values, ...reset })
    .onConflictDoUpdate({ target: mailAccounts.userId, set: { ...values, ...reset } })
    .returning();
  return row;
}

export async function updateMailAccount(userId, patch) {
  const [row] = await db.update(mailAccounts).set(patch).where(eq(mailAccounts.userId, userId)).returning();
  return row ?? null;
}

export async function deleteMailAccount(userId) {
  await db.delete(mailAccounts).where(eq(mailAccounts.userId, userId));
}

/**
 * 메일 주소록 — 나와 같은 팀에 있는 사람 중 메일 계정을 연결한 사람(그 계정 주소). 가입 이메일(users.email)은 내보내지 않는다 — 웹메일을 연결한
 * 주소만, 같은 팀 사람에게만. `[{ userId, name, email }]`(이름순).
 */
export async function listMailDirectory(userId) {
  const myTeams = db.select({ teamId: teamMembers.teamId }).from(teamMembers).where(eq(teamMembers.userId, userId));
  const rows = await db
    .selectDistinct({ userId: users.id, name: users.name, username: users.username, email: mailAccounts.email })
    .from(teamMembers)
    .innerJoin(users, eq(users.id, teamMembers.userId))
    .innerJoin(mailAccounts, eq(mailAccounts.userId, users.id))
    .where(and(inArray(teamMembers.teamId, myTeams), ne(users.id, userId), isNull(users.deletedAt)));
  return rows
    .map((r) => ({ userId: r.userId, name: r.name ?? r.username, email: r.email }))
    .sort((a, b) => a.name.localeCompare(b.name, 'ko'));
}

/** 새 메일 확인 작업 — 알림을 켠, 탈퇴·정지하지 않은 사람의 계정. */
export async function listNotifyMailAccounts() {
  const rows = await db
    .select({ account: mailAccounts, deletedAt: users.deletedAt, suspendedAt: users.suspendedAt })
    .from(mailAccounts)
    .innerJoin(users, eq(users.id, mailAccounts.userId))
    .where(eq(mailAccounts.notify, true));
  return rows.filter((r) => !r.deletedAt && !r.suspendedAt).map((r) => r.account);
}
