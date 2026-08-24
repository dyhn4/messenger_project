import { GENERAL_ROOM_ID } from './client.js';
import { findRoomById, insertRoom } from './queries/rooms.js';

/** 서버 시작 시 한 번 확인해서, 없으면 기본 "일반" 토픽방을 만든다. 멱있으니 매번 불러도 안전하다. */
export async function ensureSeedData() {
  const existing = await findRoomById(GENERAL_ROOM_ID);
  if (existing) return;

  await insertRoom({
    id: GENERAL_ROOM_ID,
    type: 'topic',
    name: '일반',
    description: '전체 공지 및 자유 대화',
    isPublic: true,
    createdBy: 'system',
  });
  console.log('[db] 기본 "일반" 토픽방을 생성했습니다.');
}
