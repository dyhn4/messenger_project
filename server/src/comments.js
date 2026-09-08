import { randomUUID } from 'node:crypto';
import { Router } from 'express';
import { findCommentById, insertComment, softDeleteComment, updateCommentText } from './db/queries/comments.js';
import { findMessageById } from './db/queries/messages.js';
import { findRoomById, isRoomMember, listRoomMemberIds } from './db/queries/rooms.js';
import { unhideDmForOtherMembers } from './rooms.js';
import { findUserById } from './db/queries/users.js';
import { notifyOfflineMembers, roomTagFor } from './push.js';
import { signFileUrl } from './upload.js';

// messages.js와 동일: 작성 후 이 시간(5분) 안에서만 본인이 수정/삭제할 수 있다.
const EDIT_WINDOW_MS = 5 * 60 * 1000;

export function toCommentDto(c) {
  const deleted = !!c.deletedAt;
  return {
    id: c.id,
    messageId: c.messageId,
    roomId: c.roomId,
    senderId: c.senderId,
    senderName: c.senderName,
    type: c.type,
    text: deleted ? null : c.text,
    fileUrl: deleted ? null : signFileUrl(c.fileUrl, c.fileName),
    fileName: deleted ? null : c.fileName,
    fileSize: deleted ? null : c.fileSize,
    mimeType: deleted ? null : c.mimeType,
    thumbnailUrl: deleted ? null : signFileUrl(c.thumbnailUrl),
    createdAt: new Date(c.createdAt).getTime(),
    editedAt: c.editedAt ? new Date(c.editedAt).getTime() : null,
    deleted,
  };
}

function withinEditWindow(comment) {
  return Date.now() - new Date(comment.createdAt).getTime() <= EDIT_WINDOW_MS;
}

export function createCommentsRouter(io) {
  const router = Router();

  router.post('/messages/:messageId/comments', async (req, res) => {
    const message = await findMessageById(req.params.messageId);
    if (!message) return res.status(404).json({ error: '메시지를 찾을 수 없습니다.' });
    if (!(await isRoomMember(message.roomId, req.user.sub))) {
      return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    }

    const type = ['image', 'file', 'sticker'].includes(req.body?.type) ? req.body.type : 'text';
    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    const fileUrl = typeof req.body?.fileUrl === 'string' ? req.body.fileUrl : null;
    if (!text && !fileUrl) return res.status(400).json({ error: '댓글 내용을 입력하세요.' });

    const sender = await findUserById(req.user.sub);
    const comment = await insertComment({
      id: randomUUID(),
      messageId: message.id,
      roomId: message.roomId,
      senderId: req.user.sub,
      senderName: sender?.name ?? sender?.username ?? '알 수 없음',
      type,
      text: text || null,
      fileUrl,
      fileName: typeof req.body?.fileName === 'string' ? req.body.fileName : null,
      fileSize: typeof req.body?.fileSize === 'number' ? req.body.fileSize : null,
      mimeType: typeof req.body?.mimeType === 'string' ? req.body.mimeType : null,
      thumbnailUrl: typeof req.body?.thumbnailUrl === 'string' ? req.body.thumbnailUrl : null,
    });

    // 평문 DM에서 상대가 이 방을 숨겨뒀으면(hidden) 자동으로 다시 보이게 한다 — socket.js의
    // message:send와 동일한 이유(rooms.js unhideDmForOtherMembers 참고).
    const room = await findRoomById(message.roomId);
    if (room) await unhideDmForOtherMembers(io, room, req.user.sub);

    const dto = toCommentDto(comment);
    io.to(message.roomId).emit('comment:new', dto);
    res.status(201).json(dto);

    // 응답 이후 백그라운드로 — socket.js의 message:send와 동일한 패턴.
    (async () => {
      if (!room) return;
      const memberIds = await listRoomMemberIds(room.id);
      await notifyOfflineMembers({
        memberIds,
        senderId: req.user.sub,
        senderName: comment.senderName,
        sender,
        room,
        entry: comment,
        roomTag: roomTagFor(room),
        kind: 'comment',
      });
    })().catch((err) => console.error('[push] 댓글 알림 실패:', err?.message ?? err));
  });

  router.patch('/comments/:id', async (req, res) => {
    const comment = await findCommentById(req.params.id);
    if (!comment || comment.deletedAt) return res.status(404).json({ error: '댓글을 찾을 수 없습니다.' });
    if (comment.senderId !== req.user.sub) return res.status(403).json({ error: '본인 댓글만 수정할 수 있습니다.' });
    if (comment.type !== 'text') return res.status(400).json({ error: '텍스트 댓글만 수정할 수 있습니다.' });
    if (!withinEditWindow(comment)) {
      return res.status(403).json({ error: '작성 후 5분이 지나 수정할 수 없습니다.' });
    }

    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    if (!text) return res.status(400).json({ error: '댓글 내용을 입력하세요.' });

    const updated = await updateCommentText(comment.id, text);
    const dto = toCommentDto(updated);
    io.to(comment.roomId).emit('comment:edited', dto);
    res.json(dto);
  });

  router.delete('/comments/:id', async (req, res) => {
    const comment = await findCommentById(req.params.id);
    if (!comment || comment.deletedAt) return res.status(404).json({ error: '댓글을 찾을 수 없습니다.' });
    if (comment.senderId !== req.user.sub) return res.status(403).json({ error: '본인 댓글만 삭제할 수 있습니다.' });
    if (!withinEditWindow(comment)) {
      return res.status(403).json({ error: '작성 후 5분이 지나 삭제할 수 없습니다.' });
    }

    await softDeleteComment(comment.id);
    io.to(comment.roomId).emit('comment:deleted', { id: comment.id, messageId: comment.messageId, roomId: comment.roomId });
    res.json({ ok: true });
  });

  return router;
}
