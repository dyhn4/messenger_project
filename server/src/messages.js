import { Router } from 'express';
import {
  findMessageById,
  hardDeleteMessage,
  listAttachmentsForMessages,
  listFavoriteFiles,
  setMessagePinned,
  softDeleteMessage,
  toggleFavoriteFile,
  updateMessageText,
  updatePost,
} from './db/queries/messages.js';
import { isRoomMember, listRoomMemberIds } from './db/queries/rooms.js';
import { findRoomById, getRoomLastReadMap } from './db/queries/rooms.js';
import { findUserById } from './db/queries/users.js';
import { topicAccess } from './access.js';
import { canModifyContent, recordModerationAudit } from './moderation.js';
import { mentionsOrEmpty, mentionsToStore, sanitizeMentions } from './notificationRules.js';
import { notifyBoard, removeNotificationsForMessage, updateMentions } from './notifications.js';
import { parsePostFields, topicWriteDenial } from './permissions.js';
import { resolveRawUrl, signFileUrl } from './upload.js';
import { sanitizeTextFormat } from './textFormat.js';
import { editMediaMessage } from './messageAttachmentEdit.js';
import { isFileDeleted } from './db/queries/fileDelete.js';

// 수정/삭제 허용 여부와 가능 시간은 팀 설정([메시지 설정])을 따르므로 여기 상수가 아니라
// moderation.js의 canModifyContent가 판단한다.

/** [m.attachments]가 붙어 있으면 그걸, 없으면 예전 방식(messages의 파일 칸 하나)을 목록으로. */
function toAttachmentDtos(m) {
  const rows = m.attachments;
  if (Array.isArray(rows) && rows.length > 0) {
    return rows.map((a) =>
      // 지운 첨부(소프트 삭제)는 파일 경로를 내려주지 않고 자리만 — 클라이언트가 "삭제된 파일입니다" 카드를 그린다.
      a.deletedAt
        ? { id: a.id, kind: a.kind, fileUrl: null, fileName: a.fileName ?? null, fileSize: null, mimeType: a.mimeType ?? null, thumbnailUrl: null, deleted: true }
        : {
            id: a.id,
            kind: a.kind,
            fileUrl: signFileUrl(a.fileUrl, a.fileName),
            fileName: a.fileName ?? null,
            fileSize: a.fileSize ?? null,
            mimeType: a.mimeType ?? null,
            thumbnailUrl: signFileUrl(a.thumbnailUrl),
            deleted: false,
          },
    );
  }
  if (!m.fileUrl || (m.type !== 'image' && m.type !== 'file')) return [];
  if (m.fileDeletedAt) {
    // 첨부 하나짜리(messages의 파일 칸만 쓰는) 메시지의 파일을 지운 경우.
    return [{ id: m.id, kind: m.type, fileUrl: null, fileName: m.fileName ?? null, fileSize: null, mimeType: m.mimeType ?? null, thumbnailUrl: null, deleted: true }];
  }
  return [
    {
      id: m.id,
      kind: m.type,
      deleted: false,
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
    // 보드 뷰 게시글('post')의 제목과 고정 시각 — 다른 메시지는 둘 다 null.
    title: m.deletedAt ? null : (m.title ?? null),
    pinnedAt: m.pinnedAt && !m.deletedAt ? new Date(m.pinnedAt).getTime() : null,
    text: m.text,
    textFormat: m.deletedAt ? null : (m.textFormat ?? null),
    // 멘션 구간([{type:'user',userId,s,e} | {type:'all',s,e}]) — 없으면 [].
    mentions: m.deletedAt ? [] : mentionsOrEmpty(m.mentions),
    // 파일을 지운 메시지(file_deleted_at)는 파일 칸 경로를 내려주지 않는다(이름은 자리 표시용으로 남긴다).
    fileUrl: m.fileDeletedAt ? null : signFileUrl(m.fileUrl, m.fileName),
    fileName: m.fileName,
    fileSize: m.fileSize,
    mimeType: m.mimeType,
    thumbnailUrl: m.fileDeletedAt ? null : signFileUrl(m.thumbnailUrl),
    // 사진 여러 장을 한 말풍선에 보여주려고 첨부를 목록으로 내려준다. message_attachments
    // 행이 있으면 그걸 쓰고, 없으면(예전 메시지) messages의 파일 칸을 첨부 하나로 본다.
    // 지워진 메시지는 첨부 행이 남아 있어도 내려주지 않는다(내용을 비운 소프트 삭제와 같은 뜻).
    attachments: m.deletedAt ? [] : toAttachmentDtos(m),
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
    // 투표(type='poll')의 제목·보기·집계 — 동기 함수라 여기서 조회하지 않고, 목록을 내려주는 쪽이 미리
    // 행에 붙여 둔 m.poll(polls.js의 attachPolls / 새 투표는 sendMessage.js)을 그대로 옮긴다. 지워진
    // 메시지나 투표가 아닌 메시지는 항상 null.
    poll: m.type === 'poll' && !m.deletedAt ? (m.poll ?? null) : null,
  };
}

/** 본문 앞 공백을 서버가 잘라낸 글자 수 — 멘션 구간도 서식 구간처럼 그만큼 당겨 맞춘다. */
function trimmedLead(raw) {
  return typeof raw === 'string' ? raw.length - raw.trimStart().length : 0;
}

export function createMessagesRouter(io) {
  const router = Router();

  /**
   * 글을 고친 뒤의 알림 — 새로 생긴 멘션에만 알리고 사라진 멘션의 알림 기록은 지운다(notifications.js updateMentions).
   * 보드 게시글이면 boardLevel이 'all'인 멤버에게 '게시글 수정' 알림도 기록한다(멘션 알림을 받은 사람은 뺀다).
   * 응답을 기다리게 하지 않도록 백그라운드로 돌리고, 실패해도 수정 자체엔 영향 없다.
   */
  function notifyAfterEdit({ room, before, updated, actorId }) {
    (async () => {
      if (!room || room.isSecret) return;
      const [actorUser, memberIds] = await Promise.all([findUserById(actorId), listRoomMemberIds(room.id)]);
      const actor = { id: actorId, name: updated.senderName, user: actorUser };
      const mentioned = await updateMentions({
        io,
        room,
        message: updated,
        actor,
        before: before.mentions,
        after: updated.mentions,
        memberIds,
      });
      if (updated.type === 'post') {
        await notifyBoard({ io, event: 'edit', room, post: updated, actor, memberIds, excludeIds: mentioned.notifiedUserIds });
      }
    })().catch((err) => console.error('[notifications] 수정 알림 실패:', err?.message ?? err));
  }

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
    if (await isFileDeleted(message, resolveRawUrl(fileUrl))) {
      return res.status(410).json({ error: '삭제된 파일입니다.' });
    }
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

  /** 요청의 mentions를 이 방 기준으로 정리해 저장할 값으로(없으면 null). 수정은 멘션 집합을 통째로 바꾼다 — 안 보내면 없음. */
  async function cleanMentions(raw, text, room, senderId, shift) {
    if (!Array.isArray(raw) || raw.length === 0 || !room) return null;
    const memberIdSet = new Set(await listRoomMemberIds(room.id));
    return mentionsToStore(sanitizeMentions(raw, text, { room, senderId, memberIdSet, shift }));
  }

  /** 게시글 응답·브로드캐스트용 DTO — 방금 고친 행에는 첨부 목록이 안 붙어 있어서 다시 붙인다
   * (안 붙이면 toMessageDto가 게시글 첨부를 빈 목록으로 내려 화면에서 첨부가 사라진다). */
  async function postDto(row) {
    const byMessage = await listAttachmentsForMessages([row.id]);
    return toMessageDto({ ...row, attachments: byMessage[row.id] });
  }

  router.patch('/messages/:id', async (req, res) => {
    const message = await findMessageById(req.params.id);
    if (!message || message.deletedAt) return res.status(404).json({ error: '메시지를 찾을 수 없습니다.' });
    const isPost = message.type === 'post';
    if (message.type === 'poll') {
      return res.status(400).json({ error: '투표는 수정할 수 없습니다.' });
    }
    // 사진·파일 메시지는 설명글 수정과 첨부 삭제만 된다(messageAttachmentEdit.js). 이모티콘·시스템 메시지는 불가.
    const isMedia = message.type === 'image' || message.type === 'file';
    if (message.type !== 'text' && !isPost && !isMedia) {
      return res.status(400).json({ error: '텍스트·사진·파일 메시지만 수정할 수 있습니다.' });
    }
    // 수정도 삭제와 같은 규칙(팀 [메시지 설정]의 허용 여부 + 수정/삭제 가능 시간)을 따른다.
    // 다만 남의 메시지 수정은 관리자도 할 수 없다 — moderation.js가 action으로 구분한다.
    // 게시글은 본인만 고칠 수 있고 수정/삭제 가능 시간 제한이 없다(isPost).
    const verdict = await canModifyContent({
      roomId: message.roomId,
      senderId: message.senderId,
      createdAt: message.createdAt,
      requesterId: req.user.sub,
      action: 'edit',
      isPost,
    });
    if (!verdict.ok) return res.status(verdict.status).json({ error: verdict.error });

    const room = await findRoomById(message.roomId);
    // 읽기 전용·보관된 토픽에서는 고치는 것도 "글쓰기"다 — 토픽을 관리할 수 있는 사람만(socket.js의
    // message:send와 같은 규칙). 삭제는 막지 않는다.
    if (room?.type === 'topic' && (room.readOnly || room.archivedAt)) {
      const denial = topicWriteDenial({ room, canManage: (await topicAccess(room, req.user.sub)).canManage });
      if (denial) return res.status(403).json({ error: denial });
    }

    if (isMedia) {
      // 비밀 대화는 설명글이 첨부 키 봉투와 한 덩어리 암호문이고 서버가 안을 못 봐서 고치거나 첨부를 덜어낼 수 없다.
      if (room?.isSecret) {
        return res.status(400).json({ error: '비밀 대화의 사진·파일 메시지는 수정할 수 없습니다.' });
      }
      const result = await editMediaMessage({
        message,
        room,
        body: req.body,
        userId: req.user.sub,
        cleanMentions,
        trimmedLead,
      });
      if (!result.ok) return res.status(result.status).json({ error: result.error });
      const dto = toMessageDto(result.updated);
      if (result.changed) {
        io.to(message.roomId).emit('message:edited', dto);
        notifyAfterEdit({ room, before: message, updated: result.updated, actorId: req.user.sub });
      }
      return res.json(dto);
    }

    if (isPost) {
      const fields = parsePostFields(req.body?.title, req.body?.text);
      if (fields.error) return res.status(400).json({ error: fields.error });
      const mentions = await cleanMentions(req.body?.mentions, fields.text, room, req.user.sub, trimmedLead(req.body?.text));
      const updated = await updatePost(message.id, {
        title: fields.title,
        text: fields.text,
        textFormat: sanitizeTextFormat(req.body?.textFormat, fields.text),
        mentions,
      });
      const dto = await postDto(updated);
      io.to(message.roomId).emit('message:edited', dto);
      res.json(dto);
      notifyAfterEdit({ room, before: message, updated, actorId: req.user.sub });
      return;
    }

    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    if (!text) return res.status(400).json({ error: '메시지 내용을 입력하세요.' });

    const textFormat = room?.isSecret ? null : sanitizeTextFormat(req.body?.textFormat, text);
    const mentions = await cleanMentions(req.body?.mentions, text, room, req.user.sub, trimmedLead(req.body?.text));
    const updated = await updateMessageText(message.id, text, textFormat, mentions);
    const dto = toMessageDto(updated);
    io.to(message.roomId).emit('message:edited', dto);
    res.json(dto);
    notifyAfterEdit({ room, before: message, updated, actorId: req.user.sub });
  });

  /**
   * 보드 뷰 게시글 고정/해제 — 보드 뷰 토픽의 게시글만, 토픽을 관리할 수 있는 사람만. 고정 목록
   * (GET /rooms/:id/pinned-posts)과 카드의 📌 표시가 바뀌도록 message:edited로 알린다.
   */
  router.post('/messages/:id/pin', async (req, res) => {
    const message = await findMessageById(req.params.id);
    if (!message || message.deletedAt) return res.status(404).json({ error: '메시지를 찾을 수 없습니다.' });
    const room = await findRoomById(message.roomId);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (message.type !== 'post' || room.type !== 'topic' || room.viewMode !== 'board') {
      return res.status(400).json({ error: '보드 뷰 토픽의 게시글만 고정할 수 있습니다.' });
    }
    if (typeof req.body?.pinned !== 'boolean') return res.status(400).json({ error: 'pinned는 true/false여야 합니다.' });
    const access = await topicAccess(room, req.user.sub);
    if (!access.isRoomMember) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    if (!access.canManage) return res.status(403).json({ error: '토픽 관리자만 게시글을 고정할 수 있습니다.' });

    // 이미 같은 상태면 고정 시각을 새로 찍지 않고 그대로 돌려준다(두 기기에서 동시에 눌러도 무해).
    const updated = req.body.pinned === !!message.pinnedAt ? message : await setMessagePinned(message.id, req.body.pinned);
    const dto = await postDto(updated);
    io.to(message.roomId).emit('message:edited', dto);
    res.json(dto);
  });

  router.delete('/messages/:id', async (req, res) => {
    const message = await findMessageById(req.params.id);
    if (!message || message.deletedAt) return res.status(404).json({ error: '메시지를 찾을 수 없습니다.' });
    // 수정/삭제 허용 여부, 가능 시간, 콘텐츠 관리 권한을 한 곳에서 판단한다(moderation.js
    // 참고) — 댓글(comments.js)도 완전히 같은 규칙을 쓴다. 게시글은 그 토픽의 토픽 관리자도 지울 수
    // 있고 가능 시간 제한이 없다(isPost). 투표도 게시글처럼 오래 두고 쓰는 글이라 시간 제한이 없고
    // 관리자가 지울 수 있다(isPoll).
    const isPost = message.type === 'post';
    const isPoll = message.type === 'poll';
    const verdict = await canModifyContent({
      roomId: message.roomId,
      senderId: message.senderId,
      createdAt: message.createdAt,
      requesterId: req.user.sub,
      action: 'delete',
      isPost,
      isPoll,
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
      await recordModerationAudit(req, message, isPost ? 'post' : isPoll ? 'poll' : 'message');
    }

    // 이 글의 멘션·보드 알림 기록도 같이 지운다(소프트 삭제는 cascade가 안 타므로 명시적으로).
    await removeNotificationsForMessage(io, message.id);

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
