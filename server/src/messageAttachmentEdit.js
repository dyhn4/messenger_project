// 사진·파일 메시지 수정 — "설명글(캡션)을 고치고 잘못 붙인 첨부를 지운다"(잔디의 메시지 수정과 같다).
// 첨부를 **더하지는** 않는다. 지울 첨부 검사는 attachmentEditPlan.js(순수), 저장은 db/queries/messageAttachmentEdit.js,
// 이 파일은 그 둘을 엮는다. messages.js의 PATCH /messages/:id가 불러 쓴다(수정 권한·시간 제한·읽기 전용 검사는 그쪽에서 끝낸 뒤).
import { applyMediaEdit } from './db/queries/messageAttachmentEdit.js';
import { findMessageById, listAttachmentsForMessages } from './db/queries/messages.js';
import { planAttachmentEdit } from './attachmentEditPlan.js';
import { sanitizeTextFormat } from './textFormat.js';

/**
 * 사진·파일 메시지 수정 본체. [body]는 요청 본문 — `text`(설명글, 빈 문자열이면 지운다. 안 보내면 글은 그대로),
 * `textFormat`·`mentions`(text를 보낼 때만 읽는다. 멘션은 텍스트 수정처럼 **통째로 다시** 보내야 한다),
 * `removeAttachmentIds`(지울 첨부). 첨부를 다 지우면 설명글이 남는 경우에만 글 메시지로 바뀌고(type → 'text'),
 * 남는 게 없으면 거절한다(메시지를 삭제하라는 뜻). [cleanMentions]는 messages.js의 멘션 정리 함수, [trimmedLead]는
 * 본문 앞 공백 길이 계산 함수를 그대로 받는다.
 *
 * 돌려주는 값: `{ ok: true, updated, changed }`(updated는 첨부 목록이 붙은 행 — toMessageDto에 그대로 넣는다) 또는
 * `{ ok: false, status, error }`.
 */
export async function editMediaMessage({ message, room, body, userId, cleanMentions, trimmedLead }) {
  const rows = (await listAttachmentsForMessages([message.id]))[message.id] ?? [];
  const plan = planAttachmentEdit({ message, rows, removeIds: body?.removeAttachmentIds });
  if (!plan.ok) return { ok: false, status: 400, error: plan.error };

  const hasText = typeof body?.text === 'string';
  const newText = hasText ? body.text.trim() : (message.text ?? '').trim();
  if (plan.remaining.length === 0 && !newText) {
    return {
      ok: false,
      status: 400,
      error: '첨부를 모두 지우면 남는 내용이 없습니다. 메시지를 삭제하세요.',
    };
  }
  if (!hasText && plan.removed.length === 0) {
    // 고칠 게 없다 — editedAt도 건드리지 않고 지금 모습을 그대로 돌려준다.
    return { ok: true, updated: { ...message, attachments: rows.length > 0 ? rows : undefined }, changed: false };
  }

  const fields = {};
  if (hasText) {
    fields.text = newText || null;
    fields.textFormat = newText ? sanitizeTextFormat(body.textFormat, newText) : null;
    fields.mentions = newText ? await cleanMentions(body.mentions, newText, room, userId, trimmedLead(body.text)) : null;
  }
  await applyMediaEdit(message.id, { fields, plan });

  const row = await findMessageById(message.id);
  const after = (await listAttachmentsForMessages([message.id]))[message.id];
  return { ok: true, updated: { ...row, attachments: after }, changed: true };
}
