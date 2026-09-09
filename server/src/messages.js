import { Router } from 'express';
import { findMessageById, softDeleteMessage, updateMessageText } from './db/queries/messages.js';
import { canModifyContent, recordModerationAudit } from './moderation.js';
import { signFileUrl } from './upload.js';

// 수정/삭제 허용 여부와 가능 시간은 팀 설정([메시지 설정])을 따르므로 여기 상수가 아니라
// moderation.js의 canModifyContent가 판단한다.

/** 방 메시지 조회(rooms.js)와 수정/삭제 브로드캐스트(여기)가 같은 모양의 DTO를 쓰도록 공용화. */
export function toMessageDto(m) {
  return {
    id: m.id,
    roomId: m.roomId,
    senderId: m.senderId,
    senderName: m.senderName,
    type: m.type,
    text: m.text,
    fileUrl: signFileUrl(m.fileUrl, m.fileName),
    fileName: m.fileName,
    fileSize: m.fileSize,
    mimeType: m.mimeType,
    thumbnailUrl: signFileUrl(m.thumbnailUrl),
    createdAt: new Date(m.createdAt).getTime(),
    editedAt: m.editedAt ? new Date(m.editedAt).getTime() : null,
    deleted: !!m.deletedAt,
    // 비밀 대화 자동 삭제 타이머 표시용(client의 SelfDestructCountdown 참고) — 평문 방
    // 메시지는 항상 둘 다 null이다(읽음 추적 자체를 안 하므로).
    readAt: m.readAt ? new Date(m.readAt).getTime() : null,
    expiresAt: m.expiresAt ? new Date(m.expiresAt).getTime() : null,
    quotedSenderName: m.quotedSenderName ?? null,
    quotedPreview: m.quotedPreview ?? null,
    forwardedFromSenderName: m.forwardedFromSenderName ?? null,
    forwardedFromCreatedAt: m.forwardedFromCreatedAt ? new Date(m.forwardedFromCreatedAt).getTime() : null,
  };
}

export function createMessagesRouter(io) {
  const router = Router();

  router.patch('/messages/:id', async (req, res) => {
    const message = await findMessageById(req.params.id);
    if (!message || message.deletedAt) return res.status(404).json({ error: '메시지를 찾을 수 없습니다.' });
    if (message.type !== 'text') return res.status(400).json({ error: '텍스트 메시지만 수정할 수 있습니다.' });
    // 수정도 삭제와 같은 규칙(팀 [메시지 설정]의 허용 여부 + 수정/삭제 가능 시간)을 따른다.
    // 다만 남의 메시지 수정은 관리자도 할 수 없다 — moderation.js가 action으로 구분한다.
    const verdict = await canModifyContent({
      roomId: message.roomId,
      senderId: message.senderId,
      createdAt: message.createdAt,
      requesterId: req.user.sub,
      action: 'edit',
    });
    if (!verdict.ok) return res.status(verdict.status).json({ error: verdict.error });

    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    if (!text) return res.status(400).json({ error: '메시지 내용을 입력하세요.' });

    const updated = await updateMessageText(message.id, text);
    const dto = toMessageDto(updated);
    io.to(message.roomId).emit('message:edited', dto);
    res.json(dto);
  });

  router.delete('/messages/:id', async (req, res) => {
    const message = await findMessageById(req.params.id);
    if (!message || message.deletedAt) return res.status(404).json({ error: '메시지를 찾을 수 없습니다.' });
    // 수정/삭제 허용 여부, 가능 시간, 콘텐츠 관리 권한을 한 곳에서 판단한다(moderation.js
    // 참고) — 댓글(comments.js)도 완전히 같은 규칙을 쓴다.
    const verdict = await canModifyContent({
      roomId: message.roomId,
      senderId: message.senderId,
      createdAt: message.createdAt,
      requesterId: req.user.sub,
      action: 'delete',
    });
    if (!verdict.ok) return res.status(verdict.status).json({ error: verdict.error });

    await softDeleteMessage(message.id);
    // 남의 메시지를 지운 경우(= 관리자 콘텐츠 관리)만 감사 로그에 남긴다 — 본인이 자기 글을
    // 지우는 건 일상적인 동작이라 기록 대상이 아니다.
    if (message.senderId !== req.user.sub) {
      await recordModerationAudit(req, message, 'message');
    }
    io.to(message.roomId).emit('message:deleted', { id: message.id, roomId: message.roomId });
    res.json({ ok: true });
  });

  return router;
}
