import { and, asc, desc, eq, ilike, inArray, isNull, ne, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { mailAccounts, mailContacts, mailRules, teamMembers, users } from '../schema.js';

// ── 계정 ──

/** 내 메일 계정들 — 순서([position])대로(처음 것이 기본). */
export function listMailAccounts(userId) {
  return db
    .select()
    .from(mailAccounts)
    .where(eq(mailAccounts.userId, userId))
    .orderBy(asc(mailAccounts.position), asc(mailAccounts.createdAt));
}

/** 내 계정 하나 — [id]가 없으면 기본(처음) 계정. 남의 계정 id면 null. */
export async function findMailAccount(userId, id = null) {
  if (id) {
    const [row] = await db.select().from(mailAccounts).where(and(eq(mailAccounts.id, id), eq(mailAccounts.userId, userId)));
    return row ?? null;
  }
  const [row] = await listMailAccounts(userId).limit(1);
  return row ?? null;
}

/** 회사 메일함 계정(자체 메일 서버 — 사람마다 하나). */
export async function findLocalMailAccount(userId) {
  const [row] = await db.select().from(mailAccounts).where(and(eq(mailAccounts.userId, userId), eq(mailAccounts.authType, 'local')));
  return row ?? null;
}

/** 새 계정 — 맨 뒤 순서로. */
export async function insertMailAccount(userId, values) {
  const [{ next }] = await db
    .select({ next: sql`coalesce(max(${mailAccounts.position}) + 1, 0)::int` })
    .from(mailAccounts)
    .where(eq(mailAccounts.userId, userId));
  const [row] = await db
    .insert(mailAccounts)
    .values({ userId, position: next, ...values })
    .returning();
  return row;
}

/** 연결 값 바꾸기 — 새 메일 기준(UIDNEXT)과 오류를 지우고 updatedAt을 새로(열려 있던 IMAP 연결을 새로 맺게). */
export async function updateMailAccountConnection(id, values) {
  const reset = { lastUidNext: null, lastUidValidity: null, lastError: null, lastErrorAt: null, updatedAt: new Date() };
  const [row] = await db.update(mailAccounts).set({ ...values, ...reset }).where(eq(mailAccounts.id, id)).returning();
  return row ?? null;
}

export async function updateMailAccount(id, patch) {
  const [row] = await db.update(mailAccounts).set(patch).where(eq(mailAccounts.id, id)).returning();
  return row ?? null;
}

export async function deleteMailAccount(userId, id) {
  const rows = await db.delete(mailAccounts).where(and(eq(mailAccounts.id, id), eq(mailAccounts.userId, userId))).returning({ id: mailAccounts.id });
  return rows.length > 0;
}

/** 순서 바꾸기 — [ids]의 차례대로 0, 1, 2…(내 계정 전부여야 한다 — 부르는 쪽이 본다). */
export async function reorderMailAccounts(userId, ids) {
  await db.transaction(async (tx) => {
    for (const [position, id] of ids.entries()) {
      await tx.update(mailAccounts).set({ position }).where(and(eq(mailAccounts.id, id), eq(mailAccounts.userId, userId)));
    }
  });
}

/**
 * 메일 주소록 — 나와 같은 팀에 있는 사람 중 메일 계정을 연결한 사람(그 계정 주소 — 여럿이면 다). 가입 이메일(users.email)은 내보내지
 * 않는다 — 웹메일을 연결한 주소만, 같은 팀 사람에게만. `[{ userId, name, email }]`(이름순).
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
    .sort((a, b) => a.name.localeCompare(b.name, 'ko') || a.email.localeCompare(b.email));
}

/**
 * 새 메일 확인 작업 — 바깥 메일 서버 계정(회사 메일함 제외) 중 알림을 켰거나 켜진 받는 규칙이 있는 것, 탈퇴·정지하지 않은 사람의 것.
 */
export async function listCheckableMailAccounts() {
  const hasRule = sql`exists (select 1 from ${mailRules} where ${mailRules.accountId} = ${mailAccounts.id} and ${mailRules.enabled})`;
  const rows = await db
    .select({ account: mailAccounts, deletedAt: users.deletedAt, suspendedAt: users.suspendedAt })
    .from(mailAccounts)
    .innerJoin(users, eq(users.id, mailAccounts.userId))
    .where(and(ne(mailAccounts.authType, 'local'), or(eq(mailAccounts.notify, true), hasRule)));
  return rows.filter((r) => !r.deletedAt && !r.suspendedAt).map((r) => r.account);
}

// ── 주소 자동 완성 ──

/** 보낸 받는 사람을 남긴다 — 이미 있으면 횟수를 하나 올리고 이름·시각을 새로. [list] `[{ address(소문자), name }]`. */
export async function recordMailContacts(userId, list, now = new Date()) {
  if (!list.length) return;
  await db
    .insert(mailContacts)
    .values(list.map((c) => ({ userId, address: c.address, name: c.name, useCount: 1, lastUsedAt: now })))
    .onConflictDoUpdate({
      target: [mailContacts.userId, mailContacts.address],
      set: {
        useCount: sql`${mailContacts.useCount} + 1`,
        lastUsedAt: now,
        name: sql`coalesce(excluded.name, ${mailContacts.name})`,
      },
    });
}

/** 자동 완성 후보 — 주소나 이름에 [q]가 든 것, 자주·최근 쓴 것부터. */
export function listMailContacts(userId, q, limit = 20) {
  const like = `%${q.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
  return db
    .select({ address: mailContacts.address, name: mailContacts.name })
    .from(mailContacts)
    .where(and(eq(mailContacts.userId, userId), or(ilike(mailContacts.address, like), ilike(mailContacts.name, like))))
    .orderBy(desc(mailContacts.useCount), desc(mailContacts.lastUsedAt))
    .limit(limit);
}

export async function deleteMailContact(userId, address) {
  await db.delete(mailContacts).where(and(eq(mailContacts.userId, userId), eq(mailContacts.address, address)));
}

// ── 받는 규칙 ──

export function listMailRules(accountId) {
  return db.select().from(mailRules).where(eq(mailRules.accountId, accountId)).orderBy(asc(mailRules.position), asc(mailRules.createdAt));
}

export async function findMailRule(userId, id) {
  const [row] = await db.select().from(mailRules).where(and(eq(mailRules.id, id), eq(mailRules.userId, userId)));
  return row ?? null;
}

export async function insertMailRule(userId, accountId, values) {
  const [{ next, n }] = await db
    .select({ next: sql`coalesce(max(${mailRules.position}) + 1, 0)::int`, n: sql`count(*)::int` })
    .from(mailRules)
    .where(eq(mailRules.accountId, accountId));
  const [row] = await db.insert(mailRules).values({ userId, accountId, position: next, ...values }).returning();
  return { row, countBefore: n };
}

export async function countMailRules(accountId) {
  const [{ n }] = await db.select({ n: sql`count(*)::int` }).from(mailRules).where(eq(mailRules.accountId, accountId));
  return n;
}

export async function updateMailRule(userId, id, values) {
  const [row] = await db
    .update(mailRules)
    .set({ ...values, updatedAt: new Date() })
    .where(and(eq(mailRules.id, id), eq(mailRules.userId, userId)))
    .returning();
  return row ?? null;
}

export async function deleteMailRule(userId, id) {
  const rows = await db.delete(mailRules).where(and(eq(mailRules.id, id), eq(mailRules.userId, userId))).returning({ id: mailRules.id });
  return rows.length > 0;
}

export async function reorderMailRules(accountId, ids) {
  await db.transaction(async (tx) => {
    for (const [position, id] of ids.entries()) {
      await tx.update(mailRules).set({ position }).where(and(eq(mailRules.id, id), eq(mailRules.accountId, accountId)));
    }
  });
}
