// 사진·파일 메시지 수정의 순수 계산(DB 없이 단위 테스트한다 — test/attachmentEditPlan.test.js). 저장은 messageAttachmentEdit.js.

/** 한 번에 지울 수 있는 첨부 수 상한 — 게시글 첨부 상한(30)보다 넉넉히. 터무니없는 배열을 일찍 거른다. */
const REMOVE_IDS_MAX = 100;

/**
 * 지금 이 메시지에 붙어 있는 첨부 목록(미서명 원본 경로). message_attachments 행이 있으면 그걸, 없으면
 * (예전 메시지·첨부 하나짜리) messages의 파일 칸 하나를 첨부 하나로 본다 — 이때 id는 메시지 id다
 * (messages.js의 toAttachmentDtos가 내려주는 id와 같아야 클라이언트가 고른 id를 알아본다).
 */
export function currentAttachmentsOf(message, rows) {
  if (Array.isArray(rows) && rows.length > 0) return rows;
  if (!message.fileUrl || (message.type !== 'image' && message.type !== 'file')) return [];
  return [
    {
      id: message.id,
      kind: message.type,
      fileUrl: message.fileUrl,
      fileName: message.fileName ?? null,
      fileSize: message.fileSize ?? null,
      mimeType: message.mimeType ?? null,
      thumbnailUrl: message.thumbnailUrl ?? null,
    },
  ];
}

/**
 * 지울 첨부 id 목록([removeIds])을 검사하고 결과를 계획으로 돌려준다 — `{ ok: true, current, removed, remaining,
 * hasRows }` 또는 `{ ok: false, error }`. id는 이 메시지의 지금 첨부 id여야 한다(남의 메시지·이미 지운 첨부 거절).
 * [hasRows]는 message_attachments 행이 있는 메시지인지(없으면 messages 파일 칸 하나뿐인 예전 방식).
 */
export function planAttachmentEdit({ message, rows, removeIds }) {
  if (removeIds !== undefined && removeIds !== null) {
    if (!Array.isArray(removeIds) || removeIds.length > REMOVE_IDS_MAX || removeIds.some((id) => typeof id !== 'string')) {
      return { ok: false, error: '지울 첨부 목록이 올바르지 않습니다.' };
    }
  }
  const current = currentAttachmentsOf(message, rows);
  const known = new Set(current.map((a) => a.id));
  const removeSet = new Set(removeIds ?? []);
  for (const id of removeSet) {
    if (!known.has(id)) return { ok: false, error: '이 메시지에 없는 첨부입니다.' };
  }
  const remaining = current.filter((a) => !removeSet.has(a.id));
  return {
    ok: true,
    current,
    removed: current.filter((a) => removeSet.has(a.id)),
    remaining,
    hasRows: Array.isArray(rows) && rows.length > 0,
    nextType: nextMessageType(remaining),
  };
}

/**
 * 첨부를 지운 뒤 남은 첨부([remaining])에 맞는 메시지 종류 — 보낼 때와 같은 규칙이다(sendMessage.js: 전부 사진이면
 * 'image', 하나라도 파일이면 'file'). 사진+파일이 섞인 'file' 메시지에서 파일을 다 지우면 사진만 남는데, 종류가
 * 'file'인 채면 화면이 사진을 사진 격자가 아니라 내려받기 카드로 그린다. 남은 게 없으면 null(글 메시지로 바뀌는 건 호출부 몫).
 */
export function nextMessageType(remaining) {
  if (!Array.isArray(remaining) || remaining.length === 0) return null;
  return remaining.every((a) => a.kind === 'image') ? 'image' : 'file';
}
