// 파일 삭제(잔디의 "파일 삭제")의 순수 규칙 — DB 없이 단위 테스트한다(test/fileDelete.test.js).
// 저장은 db/queries/fileDelete.js, 요청 처리는 messageFiles.js.

import { currentAttachmentsOf, nextMessageType } from './attachmentEditPlan.js';

/** 파일을 가질 수 있는 메시지 종류 — 사진·파일 메시지와, 첨부를 붙인 게시글·투표. */
const FILE_MESSAGE_TYPES = new Set(['image', 'file', 'post', 'poll']);

/**
 * 누가 이 파일을 지울 수 있는지. 업로드한 본인(= 그 메시지를 보낸 사람) 또는 그 팀의 관리자(콘텐츠 관리 권한)다.
 * 관리자는 **그 방의 멤버**여야 하고 비밀 대화(E2EE)는 서버가 내용을 모르므로 관리 대상에서 뺀다 — 남의 메시지
 * 삭제 규칙(moderation.js canModifyContent)과 같다. [isModerator]는 canModerateContent(access) 결과.
 */
export function canDeleteFile({ senderId, requesterId, isRoomMember, isSecret, isModerator }) {
  if (!isRoomMember) return false;
  if (senderId && senderId === requesterId) return true;
  return !isSecret && !!isModerator;
}

/**
 * 지울 첨부를 고르고 지운 뒤의 모습을 계획한다. [rows]는 message_attachments 행들(지운 것 포함), [attachmentId]는
 * 지울 첨부 id — 첨부 행이 없는 옛 메시지(messages의 파일 칸 하나)는 메시지 id이거나 null/undefined(= 그 파일 하나).
 *
 * 돌려주는 값: `{ ok: true, hasRows, target, remaining, allGone, nextType }` 또는 `{ ok: false, status, error }`.
 * - [remaining]은 지운 뒤 아직 살아 있는 첨부(position 순), [allGone]이면 messages.file_deleted_at을 찍는다.
 * - [nextType]은 남은 첨부에 맞는 메시지 종류(사진+파일이 섞였다가 파일만 지웠을 때 사진 메시지로) — 사진·파일 메시지에만 쓴다.
 */
export function planFileDelete({ message, rows, attachmentId }) {
  if (!message || message.deletedAt) return { ok: false, status: 404, error: '메시지를 찾을 수 없습니다.' };
  if (!FILE_MESSAGE_TYPES.has(message.type)) {
    return { ok: false, status: 400, error: '파일이 있는 메시지가 아닙니다.' };
  }
  const hasRows = Array.isArray(rows) && rows.length > 0;
  if (hasRows) {
    if (typeof attachmentId !== 'string' || !attachmentId) {
      return { ok: false, status: 400, error: '지울 첨부를 알려 주세요.' };
    }
    const target = rows.find((a) => a.id === attachmentId);
    if (!target) return { ok: false, status: 404, error: '이 메시지에 없는 첨부입니다.' };
    if (target.deletedAt) return { ok: false, status: 404, error: '이미 삭제된 파일입니다.' };
    const remaining = rows.filter((a) => !a.deletedAt && a.id !== target.id);
    return { ok: true, hasRows, target, remaining, allGone: remaining.length === 0, nextType: nextMessageType(remaining) };
  }

  // 첨부 행이 없는 옛 방식(사진·파일 하나) — 파일 칸이 곧 첨부 하나다.
  if (message.fileDeletedAt) return { ok: false, status: 404, error: '이미 삭제된 파일입니다.' };
  const [only] = currentAttachmentsOf(message, []);
  if (!only) return { ok: false, status: 404, error: '삭제할 파일이 없습니다.' };
  if (attachmentId != null && attachmentId !== only.id) {
    return { ok: false, status: 404, error: '이 메시지에 없는 첨부입니다.' };
  }
  return { ok: true, hasRows, target: only, remaining: [], allGone: true, nextType: null };
}
