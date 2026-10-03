import { and, asc, desc, or, sql } from 'drizzle-orm';

// 쪽 나누기 커서("<createdAt 밀리초>:<id>", pageCursor.js)의 SQL 쪽. 자바스크립트 Date는 밀리초까지만 알아서, created_at(마이크로초)을
// 그대로 비교하면 같은 밀리초 안의 글이 쪽 경계에서 빠지거나 겹친다 — 그래서 정렬·비교 모두 created_at을 밀리초로 잘라서 하고,
// 같은 밀리초 안에서는 id로 가른다.

/** created_at을 밀리초로 자른 값. */
export const msTrunc = (col) => sql`date_trunc('milliseconds', ${col})`;

/** 커서 "뒤"(desc면 더 오래된 쪽, asc면 더 새로운 쪽)만 남기는 조건. 커서가 없으면 undefined(and()가 건너뛴다). */
export function afterCursor(col, idCol, cursor, order) {
  if (!cursor) return undefined;
  const op = sql.raw(order === 'asc' ? '>' : '<');
  const ts = msTrunc(col);
  const at = sql`${new Date(cursor.ms).toISOString()}::timestamptz`;
  const beyond = sql`${ts} ${op} ${at}`;
  if (!cursor.id) return beyond;
  return or(beyond, and(sql`${ts} = ${at}`, sql`${idCol} ${op} ${cursor.id}::uuid`));
}

/** 시각(밀리초) → id 순 정렬. */
export function cursorOrder(col, idCol, order) {
  return order === 'asc' ? [asc(msTrunc(col)), asc(idCol)] : [desc(msTrunc(col)), desc(idCol)];
}

/** created_at을 밀리초 정수로(커서에 싣는 값) — 자바스크립트 Date로 거치지 않아 [msTrunc]와 정확히 같은 값이다. pg는 bigint를 문자열로 주므로 Number()로 읽는다. */
export const epochMs = (col) => sql`(extract(epoch from date_trunc('milliseconds', ${col})) * 1000)::bigint`;
