/**
 * 글자 서식(굵게·기울임 등) — 본문(text)은 평문 그대로 두고, 어느 구간에 어떤 서식이 걸렸는지만
 * 따로 저장한다. 그래서 알림·방 목록 미리보기·검색·답장 인용은 지금처럼 평문만 쓰면 된다.
 *
 *   [{ s, e, f, h? }]
 *   s·e — 본문의 UTF-16 위치(e는 포함 안 함). 클라이언트(Dart)·서버(JS) 모두 문자열 인덱스가 UTF-16이다.
 *   f   — 비트: 1 굵게, 2 기울임, 4 밑줄, 8 취소선, 16 코드, 32 인용(줄 단위)
 *   h   — 링크 주소(http·https·mailto만)
 *
 * 비밀 대화는 본문이 암호문이라 위치가 맞지 않고, 서식 구간만으로도 글의 모양이 드러나서 받지 않는다.
 */
export const TEXT_FORMAT_MASK = 63;

export function sanitizeTextFormat(value, text) {
  if (!Array.isArray(value) || typeof text !== 'string' || text.length === 0) return null;
  const out = [];
  for (const r of value.slice(0, 2000)) {
    if (!r || typeof r !== 'object') continue;
    const { s, e } = r;
    if (!Number.isInteger(s) || !Number.isInteger(e) || s < 0 || e <= s || e > text.length) continue;
    const f = Number.isInteger(r.f) ? r.f & TEXT_FORMAT_MASK : 0;
    const h =
      typeof r.h === 'string' && r.h.length <= 2000 && /^(https?:\/\/|mailto:)/i.test(r.h) ? r.h : null;
    if (!f && !h) continue;
    out.push(h ? { s, e, f, h } : { s, e, f });
  }
  return out.length > 0 ? out : null;
}
