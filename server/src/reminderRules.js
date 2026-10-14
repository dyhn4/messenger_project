/**
 * 메시지 리마인더("나중에 알림")의 규칙 — DB를 모르게 둬서 시험하기 쉽게 했다(reminders.js가 DB·소켓·예약 작업과 잇는다).
 */

/** 가장 이르게 — 1분 뒤부터(지금 바로 울릴 리마인더는 의미가 없고, 시계가 조금 어긋나도 과거가 되지 않게). */
export const REMIND_MIN_AHEAD_MS = 60 * 1000;
/** 가장 늦게 — 1년 안. */
export const REMIND_MAX_AHEAD_MS = 365 * 24 * 60 * 60 * 1000;
/** 한 사람이 걸어 둘 수 있는 리마인더 수(아직 울리지 않은 것). */
export const REMINDER_MAX_PENDING = 100;
/** 카드 미리보기 길이(글자). */
export const REMINDER_PREVIEW_MAX = 200;
/** "나와의 대화"에 올리는 리마인더 글 — 방 목록 미리보기·푸시에도 이 글이 보인다. */
export const REMINDER_BOT_TEXT_PREFIX = '⏰ 리마인더';
/** 직접 만든 리마인더 글 길이(화면에 보이는 글자). */
export const REMINDER_TEXT_MAX = 200;

/** 울릴 시각 입력(ms) — `{ value: Date }` 또는 `{ error }`. */
export function parseRemindAt(raw, nowMs) {
  if (typeof raw !== 'number' || !Number.isFinite(raw)) return { error: '알림 시각이 올바르지 않습니다.' };
  if (raw < nowMs + REMIND_MIN_AHEAD_MS) return { error: '알림 시각은 1분 뒤부터 정할 수 있습니다.' };
  if (raw > nowMs + REMIND_MAX_AHEAD_MS) return { error: '알림 시각은 1년 안으로만 정할 수 있습니다.' };
  return { value: new Date(raw) };
}

/**
 * 직접 만든 리마인더의 글 — 앞뒤 공백을 떼고 1~[REMINDER_TEXT_MAX]자. 줄바꿈은 받되(여러 줄 메모) 그 밖의 제어 문자는 받지
 * 않는다. `{ value }` 또는 `{ error }`.
 */
export function parseReminderText(raw) {
  if (typeof raw !== 'string') return { error: '알려 드릴 내용을 입력하세요.' };
  const text = raw.replace(/\r\n?/g, '\n').trim();
  if (!text) return { error: '알려 드릴 내용을 입력하세요.' };
  if (/[\u0000-\u0009\u000b-\u001f\u007f]/.test(text)) return { error: '내용에 쓸 수 없는 문자가 있습니다.' };
  const length = [...new Intl.Segmenter('ko', { granularity: 'grapheme' }).segment(text)].length;
  if (length > REMINDER_TEXT_MAX) return { error: `내용은 ${REMINDER_TEXT_MAX}자까지 쓸 수 있습니다.` };
  return { value: text };
}

/** 직접 만든 리마인더가 울릴 때 "나와의 대화"에 올리는 글 — "⏰ 리마인더 — 15시 회의 자료 보내기". */
export function memoReminderBotText(text) {
  return `${REMINDER_BOT_TEXT_PREFIX} — ${text}`;
}

/**
 * 이 메시지에 리마인더를 걸 수 없는 이유 — 되면 null. 공감(reactionRules.js)과 같은 접근 규칙(없음·지움·DM 나가기 이전은 404,
 * 남의 방은 403)이고, 시스템 메시지만 막는다. 비밀 대화도 걸 수 있다 — 서버는 내용을 모르니 카드에 미리보기 없이 올린다.
 */
export function reminderDenial({ message, room, isMember, floor = null }) {
  const notFound = { status: 404, error: '메시지를 찾을 수 없습니다.' };
  if (!message || message.deletedAt || !room) return notFound;
  if (!isMember) return { status: 403, error: '이 방의 멤버가 아닙니다.' };
  if (floor && message.createdAt < floor) return notFound;
  if (message.type === 'system') return { status: 400, error: '이 메시지에는 리마인더를 걸 수 없습니다.' };
  return null;
}

/** 미리보기를 [REMINDER_PREVIEW_MAX]자로(화면에 보이는 글자 단위) — 넘으면 말줄임표. */
function clip(text) {
  const graphemes = [...new Intl.Segmenter('ko', { granularity: 'grapheme' }).segment(text)].map((s) => s.segment);
  return graphemes.length > REMINDER_PREVIEW_MAX ? `${graphemes.slice(0, REMINDER_PREVIEW_MAX).join('')}…` : text;
}

/**
 * 울릴 때 올리는 카드 — 원본 메시지의 스냅샷 { messageId, roomId, roomName, senderName, preview, sentAt }. [preview]는 push.js의
 * previewFor 같은 한 줄(호출부가 만든다). 비밀 대화는 서버가 내용을 모르니 미리보기를 비운다(앱이 "비밀 대화 메시지"로 그린다).
 * [roomName]은 이름 있는 방만 — 1:1처럼 이름 없는 방은 앱이 자기 방 목록에서 이름을 정한다.
 */
export function reminderCardFor({ message, room, preview }) {
  return {
    messageId: message.id,
    roomId: room.id,
    roomName: room.name ?? null,
    senderName: message.senderName ?? null,
    preview: room.isSecret ? null : clip(String(preview ?? '').trim()) || null,
    sentAt: new Date(message.createdAt).getTime(),
    secret: !!room.isSecret,
  };
}

/** "나와의 대화"에 올리는 글 — 방 목록 미리보기와 푸시 본문이 된다. 비밀 대화면 내용 없이. */
export function reminderBotText(card) {
  const who = card.senderName ? `${card.senderName}: ` : '';
  return card.preview ? `${REMINDER_BOT_TEXT_PREFIX} — ${who}${card.preview}` : `${REMINDER_BOT_TEXT_PREFIX} — ${who}메시지를 확인하세요`;
}
