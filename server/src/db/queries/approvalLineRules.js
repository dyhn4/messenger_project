import { and, asc, count, eq } from 'drizzle-orm';
import { db } from '../client.js';
import { approvalLineRules, approvalTemplates } from '../schema.js';

// 결재선 규칙(groupware.js — 규칙은 approvalLineRules.js). 그룹웨어 범위([scopeKey])마다 따로.

/** 범위의 규칙 전부(양식 이름과 함께). */
export function listLineRules(scopeKey) {
  return db
    .select({ rule: approvalLineRules, templateName: approvalTemplates.name })
    .from(approvalLineRules)
    .leftJoin(approvalTemplates, eq(approvalTemplates.id, approvalLineRules.templateId))
    .where(eq(approvalLineRules.scopeKey, scopeKey))
    .orderBy(asc(approvalLineRules.kind), asc(approvalLineRules.minAmount), asc(approvalLineRules.createdAt));
}

export async function countLineRules(scopeKey) {
  const [row] = await db.select({ n: count() }).from(approvalLineRules).where(eq(approvalLineRules.scopeKey, scopeKey));
  return row?.n ?? 0;
}

export async function insertLineRule(fields) {
  const [row] = await db.insert(approvalLineRules).values(fields).returning();
  return row;
}

export async function updateLineRule(id, scopeKey, fields) {
  const [row] = await db
    .update(approvalLineRules)
    .set(fields)
    .where(and(eq(approvalLineRules.id, id), eq(approvalLineRules.scopeKey, scopeKey)))
    .returning();
  return row ?? null;
}

export async function deleteLineRule(id, scopeKey) {
  const rows = await db
    .delete(approvalLineRules)
    .where(and(eq(approvalLineRules.id, id), eq(approvalLineRules.scopeKey, scopeKey)))
    .returning({ id: approvalLineRules.id });
  return rows.length > 0;
}
