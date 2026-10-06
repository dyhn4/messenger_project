import { and, eq, isNotNull } from 'drizzle-orm';
import { db } from '../client.js';
import { favoriteFiles, messageAttachments, messages } from '../schema.js';

/**
 * 파일 삭제의 저장(messageFiles.js) — 소프트 삭제다. 디스크 파일은 지우지 않는다(전달된 메시지·공지·즐겨찾기가 같은
 * 경로를 가리킬 수 있다). [plan]은 planFileDelete의 결과, [userId]는 지운 사람.
 *
 * - 첨부 행이 있으면 그 행에 deleted_at/deleted_by를 찍는다. 남은 첨부가 있으면 messages의 파일 칸을 **남은 첫 번째**로
 *   다시 맞춘다(파일 모아보기·검색·알림 미리보기가 그 칸을 쓴다). 남은 게 없으면 messages.file_deleted_at을 찍는다.
 * - 첨부 행이 없는 옛 메시지는 messages.file_deleted_at만 찍는다.
 * - 지운 파일을 즐겨찾기한 사람들의 favorite_files 행을 지운다.
 * 메시지와 그 댓글은 그대로 남는다. editedAt은 건드리지 않는다("(수정됨)"이 붙을 일이 아니다).
 */
export async function applyFileDelete(messageId, { plan, message, userId }) {
  await db.transaction(async (tx) => {
    const now = new Date();
    const set = {};
    if (plan.hasRows) {
      await tx
        .update(messageAttachments)
        .set({ deletedAt: now, deletedBy: userId })
        .where(and(eq(messageAttachments.id, plan.target.id), eq(messageAttachments.messageId, messageId)));
    }
    if (plan.allGone) {
      set.fileDeletedAt = now;
    } else {
      const head = plan.remaining[0];
      set.fileUrl = head.fileUrl;
      set.fileName = head.fileName ?? null;
      set.fileSize = head.fileSize ?? null;
      set.mimeType = head.mimeType ?? null;
      set.thumbnailUrl = head.thumbnailUrl ?? null;
      // 사진+파일이 섞인 메시지에서 파일을 다 지웠으면 사진 메시지로(보낼 때와 같은 규칙) — 게시글·투표는 종류를 안 바꾼다.
      if (plan.nextType && (message.type === 'image' || message.type === 'file')) set.type = plan.nextType;
    }
    await tx
      .delete(favoriteFiles)
      .where(and(eq(favoriteFiles.messageId, messageId), eq(favoriteFiles.fileUrl, plan.target.fileUrl)));
    if (Object.keys(set).length > 0) await tx.update(messages).set(set).where(eq(messages.id, messageId));
  });
}

/** 이 메시지의 [fileUrl](미서명 원본 경로) 파일이 이미 지워졌는지 — 지운 파일은 즐겨찾기에 담을 수 없다. */
/** [fileUrl](원본 경로)이 정말 이 메시지에 붙은 파일인지 — 즐겨찾기가 남의 방 파일 경로를 내 메시지에 걸어 두고
 * 새 다운로드 링크를 계속 받아 가는 데 쓰이지 않게 한다. */
export async function isFileOfMessage(message, fileUrl) {
  if (!fileUrl) return false;
  if (message.fileUrl === fileUrl) return true;
  const rows = await db
    .select({ id: messageAttachments.id })
    .from(messageAttachments)
    .where(and(eq(messageAttachments.messageId, message.id), eq(messageAttachments.fileUrl, fileUrl)))
    .limit(1);
  return rows.length > 0;
}

export async function isFileDeleted(message, fileUrl) {
  if (message.fileDeletedAt && message.fileUrl === fileUrl) return true;
  const rows = await db
    .select({ id: messageAttachments.id })
    .from(messageAttachments)
    .where(
      and(
        eq(messageAttachments.messageId, message.id),
        eq(messageAttachments.fileUrl, fileUrl),
        isNotNull(messageAttachments.deletedAt),
      ),
    )
    .limit(1);
  return rows.length > 0;
}
