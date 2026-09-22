import { asc, eq, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { positionOptions } from '../schema.js';

/** 서열(sortOrder) 순서로 — 관리자 콘솔의 "직책 목록"과 회원 직책 선택 라디오 버튼이 이
 * 순서로 뜬다. 같은 sortOrder는 없어야 정상이지만, 혹시 몰라 createdAt을 2차 기준으로 둔다. */
export function listPositionOptions() {
  return db
    .select()
    .from(positionOptions)
    .orderBy(asc(positionOptions.sortOrder), asc(positionOptions.createdAt));
}

export function findPositionOptionByLabel(label) {
  return db
    .select()
    .from(positionOptions)
    .where(eq(positionOptions.label, label))
    .then((rows) => rows[0] ?? null);
}

/** 회원가입 시 자동으로 부여할 직책(없으면 null) — auth.js가 새 계정을 만들 때 쓴다. */
export function findDefaultPositionOption() {
  return db
    .select()
    .from(positionOptions)
    .where(eq(positionOptions.isDefault, true))
    .then((rows) => rows[0] ?? null);
}

/** 새 직책은 항상 목록 맨 끝에 추가된다. */
export async function insertPositionOption(label) {
  const [{ max }] = await db
    .select({ max: sql`max(${positionOptions.sortOrder})` })
    .from(positionOptions);
  const [row] = await db
    .insert(positionOptions)
    .values({ label, sortOrder: (max ?? -1) + 1 })
    .returning();
  return row;
}

export async function deletePositionOption(id) {
  await db.delete(positionOptions).where(eq(positionOptions.id, id));
}

/**
 * 관리자 콘솔에서 직책을 끌어다 놓아 서열을 바꿀 때 — [ids](전체 직책 id, 원하는 순서)의
 * 순서대로 sortOrder를 0부터 다시 매긴다. 항상 최신 전체 목록을 돌려준다(클라이언트가 그대로
 * 다시 그리면 되도록).
 */
export async function reorderPositionOptions(ids) {
  await db.transaction(async (tx) => {
    for (const [i, id] of ids.entries()) {
      await tx.update(positionOptions).set({ sortOrder: i }).where(eq(positionOptions.id, id));
    }
  });
  return listPositionOptions();
}

/**
 * 직책 목록의 "기본값" 별표를 누를 때 — 이미 기본값이면 해제만(기본값 없음), 아니면 기존
 * 기본값을 내리고 이 항목을 새 기본값으로 올린다(항상 최대 1개만 기본값). 회원가입 시
 * auth.js가 이 값을 읽어 새 계정에 자동으로 부여한다. 항상 최신 전체 목록을 돌려준다.
 */
export async function toggleDefaultPositionOption(id) {
  const [target] = await db.select().from(positionOptions).where(eq(positionOptions.id, id));
  if (!target) return listPositionOptions();
  await db.transaction(async (tx) => {
    await tx.update(positionOptions).set({ isDefault: false }).where(eq(positionOptions.isDefault, true));
    if (!target.isDefault) {
      await tx.update(positionOptions).set({ isDefault: true }).where(eq(positionOptions.id, id));
    }
  });
  return listPositionOptions();
}
