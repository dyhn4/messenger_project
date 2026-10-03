// "메시지 더보기 > 공지 등록" — 메시지 하나를 공지로 바꿀 때의 규칙(announcements.js가 쓴다). DB·서버 없이
// 단위 테스트할 수 있게 순수 함수로 뺐다(test/announcementFromMessage.test.js).

export const ANNOUNCEMENT_TEXT_MAX = 2000;

/**
 * 공지로 올릴 수 있는 메시지인지 보고, 공지에 담을 값을 뽑는다. 잔디처럼 **일반 텍스트 메시지와 이미지 메시지만**
 * 된다 — 파일·이모티콘·시스템 메시지·보드 게시글·투표는 안 되고(댓글은 애초에 messages 행이 아니다), 지워진
 * 메시지도 안 된다. 이미지 메시지는 첫 사진 한 장을 공지 이미지로 쓰고(여러 장이어도 한 장), 설명글(캡션)이 있으면
 * 그게 공지 글이 된다(없으면 빈 글 — 사진만 있는 공지). 글 서식·멘션은 공지가 평문이라 버린다.
 *
 * 통과하면 `{ ok: true, text, image }`(image는 `{ url, thumbnailUrl, name }` 또는 null), 아니면
 * 그대로 응답할 수 있는 `{ ok: false, status, error }`.
 */
export function announcementFieldsFromMessage(message) {
  if (!message || message.deletedAt) return { ok: false, status: 404, error: '메시지를 찾을 수 없습니다.' };
  const text = typeof message.text === 'string' ? message.text.trim() : '';
  if (text.length > ANNOUNCEMENT_TEXT_MAX) {
    return { ok: false, status: 400, error: `공지는 ${ANNOUNCEMENT_TEXT_MAX}자 이내로 작성하세요.` };
  }
  if (message.type === 'text') {
    if (!text) return { ok: false, status: 400, error: '내용이 없는 메시지는 공지로 등록할 수 없습니다.' };
    return { ok: true, text, image: null };
  }
  if (message.type === 'image') {
    if (!message.fileUrl || message.fileDeletedAt) return { ok: false, status: 400, error: '사진을 찾을 수 없습니다.' };
    return {
      ok: true,
      text,
      image: {
        url: message.fileUrl,
        thumbnailUrl: message.thumbnailUrl ?? null,
        name: message.fileName ?? null,
      },
    };
  }
  return { ok: false, status: 400, error: '텍스트와 이미지 메시지만 공지로 등록할 수 있습니다.' };
}
