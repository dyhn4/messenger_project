import { Router } from 'express';
import {
  findMessageById,
  hardDeleteMessage,
  listFavoriteFiles,
  softDeleteMessage,
  toggleFavoriteFile,
  updateMessageText,
} from './db/queries/messages.js';
import { isRoomMember } from './db/queries/rooms.js';
import { findRoomById, getRoomLastReadMap } from './db/queries/rooms.js';
import { canModifyContent, recordModerationAudit } from './moderation.js';
import { resolveRawUrl, signFileUrl } from './upload.js';

// 수정/삭제 허용 여부와 가능 시간은 팀 설정([메시지 설정])을 따르므로 여기 상수가 아니라
// moderation.js의 canModifyContent가 판단한다.

/** [m.attachments]가 붙어 있으면 그걸, 없으면 예전 방식(messages의 파일 칸 하나)을 목록으로. */
function toAttachmentDtos(m) {
  const rows = m.attachments;
  if (Array.isArray(rows) && rows.length > 0) {
    return rows.map((a) => ({
      id: a.id,
      kind: a.kind,
      fileUrl: signFileUrl(a.fileUrl, a.fileName),
      fileName: a.fileName ?? null,
      fileSize: a.fileSize ?? null,
      mimeType: a.mimeType ?? null,
      thumbnailUrl: signFileUrl(a.thumbnailUrl),
    }));
  }
  if (!m.fileUrl || (m.type !== 'image' && m.type !== 'file')) return [];
  return [
    {
      id: m.id,
      kind: m.type,
      fileUrl: signFileUrl(m.fileUrl, m.fileName),
      fileName: m.fileName ?? null,
      fileSize: m.fileSize ?? null,
      mimeType: m.mimeType ?? null,
      thumbnailUrl: signFileUrl(m.thumbnailUrl),
    },
  ];
}

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
    // 사진 여러 장을 한 말풍선에 보여주려고 첨부를 목록으로 내려준다. message_attachments
    // 행이 있으면 그걸 쓰고, 없으면(예전 메시지) messages의 파일 칸을 첨부 하나로 본다.
    attachments: toAttachmentDtos(m),
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
    linkPreview: m.linkPreviewTitle || m.linkPreviewDescription || m.linkPreviewImageUrl
      ? {
          url: m.linkPreviewUrl,
          title: m.linkPreviewTitle ?? null,
          description: m.linkPreviewDescription ?? null,
          imageUrl: m.linkPreviewImageUrl ?? null,
          siteName: m.linkPreviewSiteName ?? null,
        }
      : null,
    isInquiryNotice: !!m.isInquiryNotice,
    inquiryId: m.inquiryId ?? null,
  };
}

export function createMessagesRouter(io) {
  const router = Router();

  // ── 즐겨찾기한 파일 ───────────────────────────────────────────────────
  //
  // 사람마다 따로 담는 목록이라 방 권한만 확인하고 그 사람 것에만 쓴다.

  router.post('/messages/:id/favorite-file', async (req, res) => {
    const message = await findMessageById(req.params.id);
    if (!message) return res.status(404).json({ error: '메시지를 찾을 수 없습니다.' });
    if (!(await isRoomMember(message.roomId, req.user.sub))) {
      return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    }
    const fileUrl = typeof req.body?.fileUrl === 'string' ? req.body.fileUrl : null;
    if (!fileUrl) return res.status(400).json({ error: '파일을 알 수 없습니다.' });
    const favorited = await toggleFavoriteFile({
      userId: req.user.sub,
      messageId: message.id,
      // 서명된 /files/<token> 형태로 와도 원본 경로로 되돌려 저장한다(서명은 매번 바뀐다).
      fileUrl: resolveRawUrl(fileUrl),
      fileName: typeof req.body?.fileName === 'string' ? req.body.fileName : null,
    });
    res.json({ favorited });
  });

  router.get('/favorite-files', async (req, res) => {
    const rows = await listFavoriteFiles(req.user.sub);
    res.json(
      rows.map((r) => ({
        id: r.id,
        messageId: r.messageId,
        fileUrl: signFileUrl(r.fileUrl, r.fileName),
        fileName: r.fileName ?? null,
        createdAt: new Date(r.createdAt).getTime(),
      })),
    );
  });

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

    // 삭제 가능 시간 안에 발신자 본인 외에 아직 아무도 이 메시지를 안 읽었으면, "삭제된
    // 메시지입니다" 흔적도 없이 안 보낸 것처럼 완전히 지운다. 한 명이라도 읽었으면 기존처럼
    // 자리만 남기고 내용만 비우는 소프트 삭제로 처리한다.
    const room = await findRoomById(message.roomId);
    let seenByOther;
    if (room?.isSecret) {
      // 비밀 대화는 메시지마다 정확한 읽음 시각(readAt)을 이미 추적한다(자동 삭제 타이머용,
      // 항상 2명뿐이라 이 값이 곧 "상대가 읽었는지"다).
      seenByOther = !!message.readAt;
    } else {
      // 평문 방은 메시지 단위 읽음 기록이 없어서, 방의 "마지막으로 읽은 시각"이 이 메시지의
      // 작성 시각 이후인 멤버가(나 제외) 한 명이라도 있는지로 판단한다.
      const lastReadMap = await getRoomLastReadMap(message.roomId);
      const createdAtMs = new Date(message.createdAt).getTime();
      seenByOther = Object.entries(lastReadMap).some(
        ([userId, whenMs]) => userId !== message.senderId && whenMs >= createdAtMs,
      );
    }

    // 남의 메시지를 지운 경우(= 관리자 콘텐츠 관리)만 감사 로그에 남긴다 — 본인이 자기 글을
    // 지우는 건 일상적인 동작이라 기록 대상이 아니다.
    if (message.senderId !== req.user.sub) {
      await recordModerationAudit(req, message, 'message');
    }

    if (seenByOther) {
      await softDeleteMessage(message.id);
      io.to(message.roomId).emit('message:deleted', { id: message.id, roomId: message.roomId });
    } else {
      await hardDeleteMessage(message.id);
      // "완전히 없앤다"는 클라이언트 동작 자체가 이미 secretExpiry.js의 자동 삭제 타이머
      // 만료와 똑같다(applyExpire — 리스트에서 통째로 빼고 딸린 댓글 타임라인 항목도 같이
      // 제거) — 새 이벤트를 만들지 않고 그 경로를 그대로 재사용한다.
      io.to(message.roomId).emit('message:expired', { roomId: message.roomId, messageId: message.id });
    }
    res.json({ ok: true });
  });

  return router;
}
