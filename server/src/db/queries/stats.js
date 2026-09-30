import { eq, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { messageComments, messages, rooms, teams } from '../schema.js';

/**
 * 관리자 콘솔 대시보드용 집계. 큰 테이블(messages)은 count(*)가 느려질 수 있어서 한 번에
 * 모아 한 쿼리로 처리하고, 화면에서도 자주 새로고침하지 않는다.
 */
export async function countRooms() {
  // 나와의 대화는 팀원마다 저절로 하나씩 생기는 개인 메모 공간이라 '대화방' 수에서 뺀다.
  const [row] = await db.select({ value: sql`count(*)::int` }).from(rooms).where(eq(rooms.isSelf, false));
  return row?.value ?? 0;
}

export async function countTeams() {
  const [row] = await db.select({ value: sql`count(*)::int` }).from(teams);
  return row?.value ?? 0;
}

export async function countMessages() {
  const [row] = await db.select({ value: sql`count(*)::int` }).from(messages);
  return row?.value ?? 0;
}

/** 오늘(서버 시간 기준 자정 이후) 올라온 메시지+댓글 수. */
export async function countMessagesToday() {
  const [m] = await db
    .select({ value: sql`count(*)::int` })
    .from(messages)
    .where(sql`${messages.createdAt} >= date_trunc('day', now())`);
  const [c] = await db
    .select({ value: sql`count(*)::int` })
    .from(messageComments)
    .where(sql`${messageComments.createdAt} >= date_trunc('day', now())`);
  return (m?.value ?? 0) + (c?.value ?? 0);
}
