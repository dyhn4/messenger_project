/**
 * 화상회의 기록 카드(messages.call_card)의 내용 규칙 — 통화 한 통마다 대화방에 카드 한 장을 두고, 시작·참여·
 * 거절·나감을 그 카드의 events에 쌓는다(대화에 시스템 메시지를 여러 줄 남기지 않는다). DB·소켓은 callCards.js가
 * 맡고, 여기는 카드 모양만 다뤄서 DB 없이 테스트할 수 있다.
 *
 * 카드: { status: 'active'|'ended', startedAt, endedAt, durationMs, answered, events: [{ at, userId, name, kind }] }
 *   kind: 'start' | 'join' | 'leave' | 'decline'
 */

/** 한 카드에 쌓는 사건 수 상한 — 연결이 계속 끊겼다 붙는 등 비정상적으로 많아져도 카드가 끝없이 커지지 않게. */
export const CALL_CARD_MAX_EVENTS = 300;

export function newCallCard({ at, userId, name }) {
  return {
    status: 'active',
    startedAt: at,
    endedAt: null,
    durationMs: null,
    answered: false,
    events: [{ at, userId, name: name || '알 수 없음', kind: 'start' }],
  };
}

/** [card]에 사건 하나를 붙인 새 카드. 끝난 카드나 상한을 넘으면 그대로 돌려준다. */
export function addCallEvent(card, { at, userId, name, kind }) {
  if (card.status !== 'active' || card.events.length >= CALL_CARD_MAX_EVENTS) return card;
  return { ...card, events: [...card.events, { at, userId, name: name || '알 수 없음', kind }] };
}

/** 통화가 끝난 카드. [answered]는 건 사람 말고 누가 한 번이라도 들어왔는지(아니면 부재중). */
export function endCallCard(card, { at, answered }) {
  return { ...card, status: 'ended', endedAt: at, durationMs: Math.max(0, at - card.startedAt), answered };
}

/** 서버가 재시작돼 통화 상태(메모리)를 잃었을 때 "진행 중"으로 남은 카드를 닫는다 — 끝난 시각은 마지막 사건 시각으로 본다. */
export function closeStaleCallCard(card) {
  if (card?.status !== 'active') return card;
  const last = card.events.at(-1)?.at ?? card.startedAt;
  const answered = card.events.some((e) => e.kind === 'join');
  return endCallCard(card, { at: last, answered });
}

/**
 * 소켓이 끊겨서(앱 종료·네트워크 끊김) 통화에서 빼기 전에 기다리는 시간. 그 사이 같은 사람이 다시
 * 붙어 통화 참여를 알리면(앱이 재연결하면 다시 알린다 — client session.dart) 그대로 이어져서,
 * 잠깐 끊긴 것만으로 카드에 "나감/참여"가 쌓이거나, 혼자 남은 사람이 끊겼다고 통화가 끝났다가 다시
 * 시작되며 모두에게 전화가 다시 울리는 일이 없다. [나가기]는 기다리지 않는다.
 */
export const CALL_DISCONNECT_GRACE_MS = 10_000;
