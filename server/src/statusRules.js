/**
 * 상태 메시지와 방해 금지의 규칙 — DB를 모르게 둬서 시험하기 쉽게 했다(users.js가 저장·브로드캐스트, push.js가 알림을 거른다).
 * 앱(client/lib/models/user_status.dart)이 같은 계산을 한다 — 특히 [isDndActive]는 둘이 같아야 "방해 금지 중" 표시와 실제로
 * 알림이 안 가는 것이 맞는다.
 */

/** 상태 메시지에 고를 수 있는 이모지 — 앱의 고르는 줄과 같이 맞춘다. 아무 글자나 받으면 보이지 않는 글자 등을 따로 걸러야 한다. */
export const STATUS_EMOJIS = Object.freeze(['🗓️', '🚗', '🏖️', '🍽️', '🏠', '🤒', '✈️', '🎯', '☕', '📚', '👶', '💬']);
export const STATUS_TEXT_MAX = 40;
/** 상태 메시지·방해 금지를 "언제까지"로 정할 때 가장 멀리 — 휴가 한 달. */
export const UNTIL_MAX_MS = 31 * 24 * 60 * 60 * 1000;
const MINUTES_PER_DAY = 24 * 60;

// 제어 문자와 글자 방향을 바꾸는 문자 — 이름·상태 옆에 붙어 다른 사람 화면을 어지럽히지 않게.
const FORBIDDEN_CHARS = /[\u0000-\u001f\u007f-\u009f‎‏‪-‮⁦-⁩]/;

function graphemeCount(text) {
  return [...new Intl.Segmenter('ko', { granularity: 'grapheme' }).segment(text)].length;
}

function toMs(value) {
  if (value == null) return null;
  const ms = value instanceof Date ? value.getTime() : Number(value);
  return Number.isFinite(ms) ? ms : null;
}

/** "언제까지" 입력 — null(지우지 않음/끔) 또는 지금보다 뒤이고 한 달 안의 시각(ms). 틀리면 { error }. */
function parseUntil(raw, nowMs, label) {
  if (raw === null || raw === undefined) return { value: null };
  if (typeof raw !== 'number' || !Number.isFinite(raw)) return { error: `${label} 시각이 올바르지 않습니다.` };
  if (raw <= nowMs) return { error: `${label} 시각이 이미 지났습니다.` };
  if (raw - nowMs > UNTIL_MAX_MS) return { error: `${label}은(는) 한 달 안으로만 정할 수 있습니다.` };
  return { value: new Date(raw) };
}

/**
 * 상태 메시지 입력 `{ emoji, text, until }`을 저장할 칸으로 — `{ value: { statusEmoji, statusText, statusUntil } }` 또는 `{ error }`.
 * 이모지와 글이 둘 다 없으면 지우는 것(세 칸 모두 null). 글은 앞뒤 공백을 떼고, 줄바꿈·제어 문자는 받지 않는다.
 */
export function parseStatusInput(body, nowMs) {
  const emoji = body?.emoji ?? null;
  const rawText = body?.text ?? null;
  if (emoji !== null && !STATUS_EMOJIS.includes(emoji)) return { error: '상태 이모지를 목록에서 고르세요.' };
  if (rawText !== null && typeof rawText !== 'string') return { error: '상태 글은 글자로 넣어야 합니다.' };
  const text = rawText?.trim() || null;
  if (text && FORBIDDEN_CHARS.test(text)) return { error: '상태 글에 쓸 수 없는 글자가 있습니다.' };
  if (text && graphemeCount(text) > STATUS_TEXT_MAX) return { error: `상태 글은 ${STATUS_TEXT_MAX}자까지 쓸 수 있습니다.` };
  if (!emoji && !text) return { value: { statusEmoji: null, statusText: null, statusUntil: null } };
  const until = parseUntil(body?.until ?? null, nowMs, '상태를 지울');
  if (until.error) return until;
  return { value: { statusEmoji: emoji, statusText: text, statusUntil: until.value } };
}

/** 다른 사람에게 보일 상태 메시지 — `{ emoji, text, until }`(until은 ms 또는 null), 없거나 지울 시각이 지났으면 null. */
export function statusDto(user, nowMs) {
  if (!user?.statusEmoji && !user?.statusText) return null;
  const until = toMs(user.statusUntil);
  if (until !== null && until <= nowMs) return null;
  return { emoji: user.statusEmoji ?? null, text: user.statusText ?? null, until };
}

/**
 * 방해 금지 일정 입력 — `{ enabled, start, end, days, offsetMinutes }`. start/end는 하루 중 분(0~1439, 같으면 안 됨 — end가
 * start보다 작으면 밤을 넘기는 일정), days는 0(일)~6(토) 중 하나 이상, offsetMinutes는 그 사람 기기의 UTC 차이(-840~840).
 * null이면 일정을 지운다. `{ value }` 또는 `{ error }`.
 */
export function parseDndSchedule(raw) {
  if (raw === null || raw === undefined) return { value: null };
  if (typeof raw !== 'object' || Array.isArray(raw)) return { error: '방해 금지 일정 형식이 올바르지 않습니다.' };
  const { enabled, start, end, days, offsetMinutes } = raw;
  const minute = (v) => Number.isInteger(v) && v >= 0 && v < MINUTES_PER_DAY;
  if (typeof enabled !== 'boolean') return { error: '방해 금지 일정의 켜짐 여부가 올바르지 않습니다.' };
  if (!minute(start) || !minute(end)) return { error: '방해 금지 시간이 올바르지 않습니다.' };
  if (start === end) return { error: '방해 금지 시작과 끝 시간이 같습니다.' };
  if (!Array.isArray(days) || days.length === 0 || days.some((d) => !Number.isInteger(d) || d < 0 || d > 6)) {
    return { error: '방해 금지 요일을 하나 이상 고르세요.' };
  }
  if (!Number.isInteger(offsetMinutes) || offsetMinutes < -840 || offsetMinutes > 840) {
    return { error: '시간대가 올바르지 않습니다.' };
  }
  return { value: { enabled, start, end, days: [...new Set(days)].sort(), offsetMinutes } };
}

/** 방해 금지 입력 `{ until?, schedule? }` — 넘긴 것만 바꾼다. `{ value: { dndUntil?, dndSchedule? } }` 또는 `{ error }`. */
export function parseDndInput(body, nowMs) {
  const value = {};
  if (body && 'until' in body) {
    const until = parseUntil(body.until, nowMs, '방해 금지를 끝낼');
    if (until.error) return until;
    value.dndUntil = until.value;
  }
  if (body && 'schedule' in body) {
    const schedule = parseDndSchedule(body.schedule);
    if (schedule.error) return schedule;
    value.dndSchedule = schedule.value;
  }
  if (Object.keys(value).length === 0) return { error: '바꿀 내용이 없습니다.' };
  return { value };
}

/** 다른 사람에게 보일 방해 금지 — `{ until, schedule }`(지난 until은 null, 꺼진 일정은 null), 둘 다 없으면 null. */
export function dndDto(user, nowMs) {
  const until = toMs(user?.dndUntil);
  const liveUntil = until !== null && until > nowMs ? until : null;
  const schedule = user?.dndSchedule?.enabled ? user.dndSchedule : null;
  if (liveUntil === null && !schedule) return null;
  return { until: liveUntil, schedule };
}

/**
 * 지금 방해 금지 중인지 — [dnd]는 dndDto 모양(또는 행의 dndUntil/dndSchedule을 담은 같은 모양). "지금부터 n시간"이 남았거나,
 * 일정의 그 사람 시각(UTC + offsetMinutes)이 고른 요일의 start~end 안이면 true. 밤을 넘기는 일정(19:00~08:00)은 시작한 요일
 * 기준이다 — 금요일을 고르면 금요일 19:00부터 토요일 08:00까지.
 */
export function isDndActive(dnd, nowMs) {
  if (!dnd) return false;
  const until = toMs(dnd.until);
  if (until !== null && nowMs < until) return true;
  const s = dnd.schedule;
  if (!s?.enabled || !Array.isArray(s.days)) return false;
  const local = new Date(nowMs + s.offsetMinutes * 60 * 1000);
  const day = local.getUTCDay();
  const minute = local.getUTCHours() * 60 + local.getUTCMinutes();
  if (s.start < s.end) return s.days.includes(day) && minute >= s.start && minute < s.end;
  const previousDay = (day + 6) % 7;
  return (s.days.includes(day) && minute >= s.start) || (s.days.includes(previousDay) && minute < s.end);
}

/** 사용자 행으로 지금 방해 금지 중인지(push.js가 알림 받을 사람을 거를 때). */
export function isUserInDnd(user, nowMs) {
  return isDndActive({ until: user?.dndUntil ?? null, schedule: user?.dndSchedule ?? null }, nowMs);
}
