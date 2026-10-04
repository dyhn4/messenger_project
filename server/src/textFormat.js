/**
 * 글자 서식(굵게·기울임 등) — 본문(text)은 평문 그대로 두고, 어느 구간에 어떤 서식이 걸렸는지만
 * 따로 저장한다. 그래서 알림·방 목록 미리보기·검색·답장 인용은 지금처럼 평문만 쓰면 된다.
 *
 *   [{ s, e, f, h? }]
 *   s·e — 본문의 UTF-16 위치(e는 포함 안 함). 클라이언트(Dart)·서버(JS) 모두 문자열 인덱스가 UTF-16이다.
 *   f   — 비트: 1 굵게, 2 기울임, 4 밑줄, 8 취소선, 16 코드, 32 인용(줄 단위)
 *   h   — 링크 주소(http·https·mailto, 앱 안 링크 tangotalk://)
 *
 * 비밀 대화는 본문이 암호문이라 위치가 맞지 않고, 서식 구간만으로도 글의 모양이 드러나서 받지 않는다.
 */
export const TEXT_FORMAT_MASK = 63;

/** 공지처럼 노트 편집기와 같은 도구모음을 쓰는 곳 — 위 서식에 더해 제목(64 H1·128 H2·256 H3, 줄 단위)과
 * 글자색(512 "색 있음" 비트 + 1024배 자리부터 RGB 24비트 — 클라이언트 models/text_format.dart Fmt.withColor). */
export const RICH_TEXT_FORMAT_MASK = 511;
const COLOR_BIT = 512;
const COLOR_UNIT = 1024;

/** 서식 비트 정리 — 글자색 자리는 32비트를 넘어서(최대 2^34) 비트 연산(&) 대신 나눗셈으로 자른다. */
function sanitizeFlags(raw, rich) {
  if (!rich) return raw & TEXT_FORMAT_MASK;
  if (!Number.isSafeInteger(raw) || raw < 0) return 0;
  const low = (raw % COLOR_BIT) & RICH_TEXT_FORMAT_MASK;
  if (Math.floor(raw / COLOR_BIT) % 2 === 0) return low;
  const rgb = Math.floor(raw / COLOR_UNIT) % 0x1000000;
  return low + COLOR_BIT + rgb * COLOR_UNIT;
}

/** [rich]가 true면 제목·글자색까지 받는다(공지). 채팅·댓글·게시글은 기본(false) 그대로다. */
export function sanitizeTextFormat(value, text, { rich = false } = {}) {
  if (!Array.isArray(value) || typeof text !== 'string' || text.length === 0) return null;
  const out = [];
  for (const r of value.slice(0, 2000)) {
    if (!r || typeof r !== 'object') continue;
    const { s, e } = r;
    if (!Number.isInteger(s) || !Number.isInteger(e) || s < 0 || e <= s || e > text.length) continue;
    const f = Number.isInteger(r.f) ? sanitizeFlags(r.f, rich) : 0;
    const h =
      typeof r.h === 'string' && r.h.length <= 2000 && /^(https?:\/\/|mailto:|tangotalk:\/\/)/i.test(r.h) ? r.h : null;
    if (!f && !h) continue;
    out.push(h ? { s, e, f, h } : { s, e, f });
  }
  return out.length > 0 ? out : null;
}
