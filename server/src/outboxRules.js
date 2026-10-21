/**
 * 보내기 대기열 규칙 — 앱이 메시지마다 붙이는 임시 id(client_id). 같은 사람이 같은 id로 다시 보내면 서버는 새로 만들지 않고 처음 것을
 * 돌려준다(sendMessage.js). DB 없이 시험한다.
 */

/** 글자·숫자·_- 8~64자. */
const CLIENT_ID_RE = /^[A-Za-z0-9_-]{8,64}$/;

/** 모양이 맞으면 그 값, 아니면 null(없는 것으로 — 그냥 새 메시지). */
export const parseClientId = (v) => (typeof v === 'string' && CLIENT_ID_RE.test(v) ? v : null);

/**
 * DB 오류가 "같은 임시 id가 이미 있음"인지 — [index]는 unique 인덱스 이름 앞부분(메시지 messages_sender_client_id_idx, 댓글
 * message_comments_sender_client_id_idx — 오프라인 중 단 댓글도 대기열이 같은 임시 id로 다시 보낸다).
 */
export const isClientIdConflict = (err, index = 'messages_sender_client_id') =>
  (err?.code ?? err?.cause?.code) === '23505' &&
  String(err?.constraint ?? err?.cause?.constraint ?? err?.constraint_name ?? err?.message ?? err?.cause?.message ?? '').includes(index);
