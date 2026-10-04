// 공지 본문·글자 서식 규칙(announcements.js·announcementFromMessage.js가 쓴다). DB·서버 없이 단위 테스트할 수 있게
// 순수 함수로 뺐다(test/announcementText.test.js).
import { sanitizeTextFormat } from './textFormat.js';

/**
 * 앞뒤 공백을 뗀 본문에 맞춰 서식 구간을 옮긴다 — 뗀 앞 공백([lead])만큼 위치를 당기고 본문 밖으로 나간 부분은
 * 자른다(서식은 본문의 UTF-16 위치 기준 — textFormat.js). [rich]면 제목·글자색까지 받는다.
 */
export function shiftTextFormat(rawFormat, lead, text, { rich = false } = {}) {
  if (!Array.isArray(rawFormat) || !text) return null;
  const shifted = rawFormat.map((r) =>
    r && Number.isInteger(r.s) && Number.isInteger(r.e)
      ? { ...r, s: Math.max(0, r.s - lead), e: Math.min(text.length, r.e - lead) }
      : r,
  );
  return sanitizeTextFormat(shifted, text, { rich });
}

/**
 * 공지 쓰기·수정 창이 보낸 글과 서식 — 글은 앞뒤 공백을 떼고, 서식은 공지 작성 창의 도구모음(노트 편집기와 같은
 * 굵게·기울임·밑줄·취소선·링크·코드·인용·목록·제목·글자색)이 만든 구간을 그 글에 맞춰 정리한다. 서식을 안 보내면
 * (예전 클라이언트·서식 없는 글) null — 수정할 때도 마찬가지라, 글을 고치면서 서식을 안 보내면 서식이 지워진다
 * (위치가 어긋난 서식이 남지 않게). 글이 비었는지·길이 검사는 부르는 쪽(announcements.js)이 한다.
 */
export function parseAnnouncementText(rawText, rawFormat) {
  const source = typeof rawText === 'string' ? rawText : '';
  const text = source.trim();
  const lead = source.length - source.trimStart().length;
  return { text, textFormat: shiftTextFormat(rawFormat, lead, text, { rich: true }) };
}
