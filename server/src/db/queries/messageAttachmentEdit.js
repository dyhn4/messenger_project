import { and, eq, inArray } from 'drizzle-orm';
import { db } from '../client.js';
import { favoriteFiles, messageAttachments, messages } from '../schema.js';

/**
 * 사진·파일 메시지 수정의 저장(messageAttachmentEdit.js) — 한 트랜잭션으로 글, 첨부 행, messages의 파일 칸을 함께
 * 맞춘다. [fields]는 바꿀 글 값(`{ text, textFormat, mentions }`, 글을 안 고치면 빈 객체), [plan]은 planAttachmentEdit의
 * 결과다.
 *
 * - 지울 첨부가 있으면 message_attachments의 그 행을 지운다(행이 없는 예전 메시지는 파일 칸만 비운다). 파일 자체는
 *   디스크에서 지우지 않는다 — 전달된 메시지·공지·즐겨찾기가 같은 파일을 가리킬 수 있어서다.
 * - 남은 첨부가 있으면 순서(position)를 다시 매기고 messages의 파일 칸을 **남은 첫 번째**로 맞춘다(파일 모아보기·
 *   검색·알림 미리보기가 그 칸을 쓴다).
 * - 남은 첨부가 없으면(설명글이 있을 때만 여기까지 온다) 메시지는 글 메시지(type 'text')가 되고 파일 칸이 비워진다.
 * - 지운 파일을 즐겨찾기해 둔 사람의 즐겨찾기 항목도 같이 지운다(지운 첨부가 즐겨찾기에 남으면 열리지 않는다).
 * 첨부나 글이 바뀌었으니 editedAt을 찍는다.
 */
export async function applyMediaEdit(messageId, { fields, plan }) {
  await db.transaction(async (tx) => {
    const set = { ...fields, editedAt: new Date() };

    if (plan.removed.length > 0) {
      if (plan.hasRows) {
        await tx
          .delete(messageAttachments)
          .where(
            and(
              eq(messageAttachments.messageId, messageId),
              inArray(
                messageAttachments.id,
                plan.removed.map((a) => a.id),
              ),
            ),
          );
      }
      await tx.delete(favoriteFiles).where(
        and(
          eq(favoriteFiles.messageId, messageId),
          inArray(
            favoriteFiles.fileUrl,
            plan.removed.map((a) => a.fileUrl),
          ),
        ),
      );

      const head = plan.remaining[0];
      if (!head) {
        set.type = 'text';
        set.fileUrl = null;
        set.fileName = null;
        set.fileSize = null;
        set.mimeType = null;
        set.thumbnailUrl = null;
        // 파일 삭제로 자리만 남은(소프트 삭제) 첨부 행도 정리한다 — 글 메시지가 됐으니 "삭제된 파일" 카드는 더 필요 없다.
        if (plan.hasRows) await tx.delete(messageAttachments).where(eq(messageAttachments.messageId, messageId));
        set.fileDeletedAt = null;
      } else {
        // 사진+파일이 섞인 메시지에서 파일을 다 지웠으면 사진 메시지로(보낼 때와 같은 규칙 — attachmentEditPlan.js).
        if (plan.nextType) set.type = plan.nextType;
        set.fileUrl = head.fileUrl;
        set.fileName = head.fileName ?? null;
        set.fileSize = head.fileSize ?? null;
        set.mimeType = head.mimeType ?? null;
        set.thumbnailUrl = head.thumbnailUrl ?? null;
        if (plan.hasRows) {
          for (let i = 0; i < plan.remaining.length; i++) {
            await tx
              .update(messageAttachments)
              .set({ position: i })
              .where(eq(messageAttachments.id, plan.remaining[i].id));
          }
        }
      }
    }

    await tx.update(messages).set(set).where(eq(messages.id, messageId));
  });
}
