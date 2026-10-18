import { and, asc, count, eq } from 'drizzle-orm';
import { db } from '../client.js';
import { approvalFinalRules, approvalTemplates } from '../schema.js';

// 전결 규정(groupware.js — 규칙은 approvalFinalRules.js). 그룹웨어 범위([scopeKey])마다 따로.

/** 범위의 규정 전부(양식 이름과 함께). */
export function listFinalRules(scopeKey) {
  return db
    .select({ rule: approvalFinalRules, templateName: approvalTemplates.name })
    .from(approvalFinalRules)
    .leftJoin(approvalTemplates, eq(approvalTemplates.id, approvalFinalRules.templateId))
    .where(eq(approvalFinalRules.scopeKey, scopeKey))
    .orderBy(asc(approvalFinalRules.kind), asc(approvalFinalRules.minAmount), asc(approvalFinalRules.createdAt));
}

export async function countFinalRules(scopeKey) {
  const [row] = await db.select({ n: count() }).from(approvalFinalRules).where(eq(approvalFinalRules.scopeKey, scopeKey));
  return row?.n ?? 0;
}

export async function insertFinalRule(fields) {
  const [row] = await db.insert(approvalFinalRules).values(fields).returning();
  return row;
}

export async function updateFinalRule(id, scopeKey, fields) {
  const [row] = await db
    .update(approvalFinalRules)
    .set(fields)
    .where(and(eq(approvalFinalRules.id, id), eq(approvalFinalRules.scopeKey, scopeKey)))
    .returning();
  return row ?? null;
}

export async function deleteFinalRule(id, scopeKey) {
  const rows = await db
    .delete(approvalFinalRules)
    .where(and(eq(approvalFinalRules.id, id), eq(approvalFinalRules.scopeKey, scopeKey)))
    .returning({ id: approvalFinalRules.id });
  return rows.length > 0;
}
