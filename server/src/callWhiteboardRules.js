/**
 * 저장한 화상회의 화이트보드의 규칙(callWhiteboards.js) — 판 데이터 모양·크기, 제목. DB 없이 시험한다(test/callRecordingFollowup.test.js).
 */

export const WHITEBOARD_TITLE_MAX = 80;
export const WHITEBOARD_MAX_STROKES = 20_000;
/** 점 좌표 정수 수 상한(점 하나에 둘) — 본문 상한(512KB) 안에서 넉넉히. */
export const WHITEBOARD_MAX_NUMBERS = 400_000;
const PAGES_MAX = 20;

/** 앱이 보낸 판 데이터 → `{ data, pageCount }` 또는 `{ error }`. 모양이 틀린 칸은 받지 않는다(그대로 다시 내려주므로). */
export function parseWhiteboardData(raw) {
  const bad = { error: '화이트보드 내용이 올바르지 않습니다.' };
  if (!raw || typeof raw !== 'object' || raw.v !== 1 || !Array.isArray(raw.pages)) return bad;
  if (raw.pages.length < 1 || raw.pages.length > PAGES_MAX) return { error: `화이트보드는 ${PAGES_MAX}쪽까지 저장할 수 있습니다.` };
  let strokes = 0;
  let numbers = 0;
  const pages = [];
  for (const page of raw.pages) {
    if (!page || typeof page.id !== 'string' || page.id.length > 64 || !Array.isArray(page.strokes)) return bad;
    const out = [];
    for (const s of page.strokes) {
      if (!s || typeof s.id !== 'string' || s.id.length > 120) return bad;
      if (!Number.isInteger(s.c) || typeof s.w !== 'number' || !(s.w > 0 && s.w < 1)) return bad;
      if (!Array.isArray(s.p) || s.p.length % 2 !== 0 || !s.p.every((n) => Number.isInteger(n) && Math.abs(n) <= 10_000)) return bad;
      strokes += 1;
      numbers += s.p.length;
      out.push({ id: s.id, a: typeof s.a === 'string' ? s.a.slice(0, 64) : '', c: s.c, w: s.w, p: s.p });
    }
    pages.push({ id: page.id, strokes: out });
  }
  if (strokes > WHITEBOARD_MAX_STROKES || numbers > WHITEBOARD_MAX_NUMBERS) {
    return { error: '화이트보드에 그린 것이 너무 많아 저장할 수 없습니다. 쪽을 나눠 지운 뒤 다시 저장하세요.' };
  }
  return { data: { v: 1, pages }, pageCount: pages.length };
}

/** 제목 — 비면 "화이트보드 2026-10-22 14.30"(서버 시각). */
export function whiteboardTitle(raw, now = new Date()) {
  const t = typeof raw === 'string' ? raw.trim().slice(0, WHITEBOARD_TITLE_MAX) : '';
  if (t) return t;
  const two = (n) => String(n).padStart(2, '0');
  return `화이트보드 ${now.getFullYear()}-${two(now.getMonth() + 1)}-${two(now.getDate())} ${two(now.getHours())}.${two(now.getMinutes())}`;
}
