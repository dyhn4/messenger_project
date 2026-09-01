import { Router } from 'express';
import { findMessageById, softDeleteMessage, updateMessageText } from './db/queries/messages.js';
import { signFileUrl } from './upload.js';

// 작성 후 이 시간(5분) 안에서만 본인이 수정/삭제할 수 있다.
const EDIT_WINDOW_MS = 5 * 60 * 1000;

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

function withinEditWindow(message) {
  return Date.now() - new Date(message.createdAt).getTime() <= EDIT_WINDOW_MS;
}

export function createMessagesRouter(io) {
  const router = Router();

  router.patch('/messages/:id', async (req, res) => {
    const message = await findMessageById(req.params.id);
    if (!message || message.deletedAt) return res.status(404).json({ error: '메시지를 찾을 수 없습니다.' });
    if (message.senderId !== req.user.sub) return res.status(403).json({ error: '본인 메시지만 수정할 수 있습니다.' });
    if (message.type !== 'text') return res.status(400).json({ error: '텍스트 메시지만 수정할 수 있습니다.' });
    if (!withinEditWindow(message)) {
      return res.status(403).json({ error: '작성 후 5분이 지나 수정할 수 없습니다.' });
    }

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
    if (message.senderId !== req.user.sub) return res.status(403).json({ error: '본인 메시지만 삭제할 수 있습니다.' });
    if (!withinEditWindow(message)) {
      return res.status(403).json({ error: '작성 후 5분이 지나 삭제할 수 없습니다.' });
    }

    await softDeleteMessage(message.id);
    io.to(message.roomId).emit('message:deleted', { id: message.id, roomId: message.roomId });
    res.json({ ok: true });
  });

  return router;
}
