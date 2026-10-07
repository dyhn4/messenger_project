import { randomUUID } from 'node:crypto';
import { callSummaryText } from './calls.js';
import { addUserCallEvent, closeStaleCallCard, endCallCard, newCallCard } from './callEvents.js';
import {
  insertMessage,
  listActiveCallCardMessages,
  updateMessageCallCard,
} from './db/queries/messages.js';
import { findRoomById } from './db/queries/rooms.js';
import { findUserById } from './db/queries/users.js';
import { postSystemMessage } from './rooms.js';

/**
 * 화상회의 기록 카드 — 통화 한 통마다 대화방에 시스템 메시지 한 장(messages.call_card)을 두고, 시작·참여·거절·나감을
 * 그 카드에 쌓는다. 바뀔 때마다 DB를 고치고 방 멤버들에게 call:card로 알려서 대화방의 카드가 그 자리에서 바뀐다.
 * 통화가 끝나면 카드를 "종료/부재중"으로 닫고 메시지 글(검색·내보내기용)을 요약 문구로 바꾼다.
 *
 * 시스템 메시지라서 안읽음·푸시·방 목록 미리보기에 끼지 않는다(통화 시작 알림은 따로 전화처럼 울린다 — push.js).
 * 내용 규칙은 callEvents.js.
 *
 * 한 방의 카드 작업은 순서대로 처리한다 — 카드를 만드는 DB 쓰기가 끝나기 전에 누가 바로 들어와도 그 참여가
 * 빠지지 않게(방마다 작업 줄을 둔다).
 */

/** roomId → { messageId, card } — 지금 진행 중인 통화의 카드. 통화 상태(callState.js)처럼 메모리에만 둔다. */
const liveCards = new Map();
/** roomId → 그 방의 마지막 카드 작업(Promise) — 다음 작업을 이 뒤에 잇는다. */
const queues = new Map();

function enqueue(roomId, task) {
  const prev = queues.get(roomId) ?? Promise.resolve();
  const next = prev
    .then(task)
    .catch((err) => console.error('[call] 화상회의 카드 갱신 실패:', err?.message ?? err));
  queues.set(roomId, next);
  next.finally(() => {
    if (queues.get(roomId) === next) queues.delete(roomId);
  });
  return next;
}

async function nameOf(userId) {
  const user = await findUserById(userId);
  return user?.name ?? user?.username ?? '알 수 없음';
}

function emitCard(io, roomId, messageId, card, text) {
  io.to(roomId).emit('call:card', { roomId, messageId, card, ...(text !== undefined && { text }) });
}

/** 통화가 막 시작됐을 때 — 카드를 새로 만들어 대화방에 올린다. */
export function startCallCard(io, room, userId) {
  return enqueue(room.id, async () => {
    const card = newCallCard({ at: Date.now(), userId, name: await nameOf(userId) });
    const message = await insertMessage({
      id: randomUUID(),
      roomId: room.id,
      senderId: null,
      senderName: '시스템',
      type: 'system',
      text: '화상회의',
      callCard: card,
    });
    liveCards.set(room.id, { messageId: message.id, card });
    io.to(room.id).emit('message:new', { ...message, createdAt: new Date(message.createdAt).getTime() });
  });
}

/**
 * 진행 중인 통화에 사건(참여·나감·거절)을 붙인다. 카드가 없으면(서버 재시작 뒤 되살린 통화 등) 아무것도 안 한다. 상한에
 * 걸려 카드가 그대로면(callEvents.js addUserCallEvent — 한 사람이 나가기·참여를 되풀이) DB도 고치지 않고 알리지도 않는다.
 */
export function recordCallEvent(io, roomId, userId, kind) {
  return enqueue(roomId, async () => {
    const live = liveCards.get(roomId);
    if (!live) return;
    const next = addUserCallEvent(live.card, { at: Date.now(), userId, name: await nameOf(userId), kind });
    if (next === live.card) return;
    live.card = next;
    await updateMessageCallCard(live.messageId, live.card);
    emitCard(io, roomId, live.messageId, live.card);
  });
}

/** 통화가 끝났을 때 — 카드를 닫고 메시지 글을 요약("화상회의 · 3분 · …" / "부재중 화상회의")으로 바꾼다.
 * 카드가 있어 닫았으면 true(없으면 호출부가 예전처럼 요약 한 줄을 남긴다). */
export function finishCallCard(io, roomId, ended) {
  return enqueue(roomId, async () => {
    const live = liveCards.get(roomId);
    if (!live) return false;
    liveCards.delete(roomId);
    const users = await Promise.all(ended.participantIds.map(findUserById));
    const names = users.filter(Boolean).map((u) => u.name ?? u.username ?? '알 수 없음');
    const text = callSummaryText(ended, names);
    live.card = endCallCard(live.card, { at: Date.now(), answered: ended.answered });
    await updateMessageCallCard(live.messageId, live.card, text);
    emitCard(io, roomId, live.messageId, live.card, text);
    return true;
  });
}

/**
 * 누가 통화에서 빠진 뒤 카드를 고친다 — 그 사람이 통화에서 완전히 빠졌으면(다른 기기로 아직 들어와 있지 않으면) "나감"을
 * 붙이고, 그걸로 통화가 끝났으면 카드를 닫는다. 카드가 없는 통화(서버 재시작 뒤 되살린 통화)가 끝나면 예전처럼 요약 한
 * 줄을 시스템 메시지로 남긴다 — 단 되살린 통화에 아무도 함께하지 않았으면 남기지 않는다(혼자 남았다가 끊겼다 다시 붙기를
 * 되풀이하면 대화에 "부재중" 줄만 쌓인다 — 처음 통화의 카드가 이미 그 통화를 기록했다).
 * [state]는 callState.js leaveCall/removeUserFromCalls가 돌려준 상태, [wasIn]은 빠지기 전에 통화에 들어와 있었는지.
 * 나가기·소켓 끊김(socket.js)과 자격을 잃어 내보내기(callAccess.js)가 같이 쓴다.
 */
export async function postCallLeft(io, state, userId, wasIn) {
  if (wasIn && !state.participantIds.includes(userId)) {
    await recordCallEvent(io, state.roomId, userId, 'leave');
  }
  if (!state.ended) return;
  if (await finishCallCard(io, state.roomId, state.ended)) return;
  if (state.ended.restored && !state.ended.answered) return;
  const room = await findRoomById(state.roomId);
  if (!room) return;
  const users = await Promise.all(state.ended.participantIds.map(findUserById));
  const names = users.filter(Boolean).map((u) => u.name ?? u.username ?? '알 수 없음');
  await postSystemMessage(io, room, callSummaryText(state.ended, names));
}

/** 서버가 뜰 때 — 지난번 실행 중에 "진행 중"으로 남은 카드를 닫는다(통화 상태는 메모리에만 있어서 재시작하면 사라진다). */
export async function closeStaleCallCards() {
  const rows = await listActiveCallCardMessages();
  for (const row of rows) {
    const card = closeStaleCallCard(row.callCard);
    await updateMessageCallCard(row.id, card, card.answered ? '화상회의' : '부재중 화상회의');
  }
  if (rows.length > 0) console.log(`[call] 진행 중으로 남아 있던 화상회의 카드 ${rows.length}장을 종료로 정리했습니다.`);
}
