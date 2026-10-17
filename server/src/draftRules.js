import { MESSAGE_TEXT_MAX } from './messageLimits.js';
import { sanitizeTextFormat } from './textFormat.js';

/**
 * 임시 저장 동기화 규칙 — 입력 검사·멘션 모양·응답 모양(drafts.js가 쓴다 — DB 없이 시험한다).
 */

export const DRAFT_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000;
const MENTIONS_MAX = 200;
export const DEVICE_ID_RE = /^[A-Za-z0-9_-]{1,100}$/;

/** 멘션 구간 — 모양만 본다(`{ type: 'user'|'all', userId?, s, e }`, 글 안의 위치). 보낼 때 서버가 다시 검사한다(sendMessage.js). */
export function sanitizeDraftMentions(value, text) {
  if (!Array.isArray(value)) return null;
  const out = [];
  for (const m of value.slice(0, MENTIONS_MAX)) {
    if (!m || typeof m !== 'object') continue;
    const s = Number(m.s);
    const e = Number(m.e);
    if (!Number.isInteger(s) || !Number.isInteger(e) || s < 0 || e <= s || e > text.length) continue;
    if (m.type === 'all') out.push({ type: 'all', s, e });
    else if (m.type === 'user' && typeof m.userId === 'string' && m.userId.length <= 64) out.push({ type: 'user', userId: m.userId, s, e });
  }
  return out.length ? out : null;
}

/** 임시 저장 입력 `{ text, format?, mentions? }` → `{ values }`(text가 비면 지우기 — values null) | `{ error }`. */
export function parseDraftInput(body) {
  const text = body?.text;
  if (text !== undefined && text !== null && typeof text !== 'string') return { error: '글을 확인하세요.' };
  if (!text || !text.trim()) return { values: null };
  if (text.length > MESSAGE_TEXT_MAX) return { error: '임시 저장 글이 너무 깁니다.' };
  return {
    values: {
      text,
      textFormat: sanitizeTextFormat(body.format, text),
      mentions: sanitizeDraftMentions(body.mentions, text),
    },
  };
}

/** 응답 모양 — 지운 것(빈 글로 남긴 것)은 text가 null(앱은 그 시각보다 오래된 이 기기의 글을 지운다). */
export const draftDto = (d) => ({
  roomId: d.roomId,
  text: d.text || null,
  format: d.textFormat ?? null,
  mentions: d.mentions ?? [],
  updatedAt: new Date(d.updatedAt).getTime(),
});
