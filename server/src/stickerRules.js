// 이모티콘·캐릭터 관리의 규칙(DB 없이 시험할 수 있게 stickers.js에서 뺐다).

/** 개별 삭제로 한 번에 지울 수 있는 그림 수 — 한 세트에 한 번에 올릴 수 있는 수(200장)보다 넉넉히. */
export const STICKER_DELETE_MAX = 1000;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** 개별 삭제 요청 본문 { ids: [...] } — 중복을 뺀 uuid 목록이면 { ids }, 아니면 { error }. */
export function parseStickerIds(body) {
  const ids = body?.ids;
  if (!Array.isArray(ids) || ids.length === 0) return { error: '지울 그림을 고르세요.' };
  if (ids.length > STICKER_DELETE_MAX) {
    return { error: `한 번에 ${STICKER_DELETE_MAX}개까지 지울 수 있습니다.` };
  }
  if (!ids.every((id) => typeof id === 'string' && UUID_RE.test(id))) {
    return { error: '그림 id가 올바르지 않습니다.' };
  }
  return { ids: [...new Set(ids.map((id) => id.toLowerCase()))] };
}

/** 앱에 내려줄 그림 하나의 표시 상태 — 지운 그림도 숨긴 것으로 보낸다(이 기능 전의 앱도 선택창에서는 빼고,
 * 이미 보낸 메시지에는 그대로 그린다). */
export function stickerVisibility(row) {
  return { hidden: !!row.hidden || !!row.deletedAt, deleted: !!row.deletedAt };
}
