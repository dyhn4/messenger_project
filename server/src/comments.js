import { randomUUID } from 'node:crypto';
import { Router } from 'express';
import { tooMany } from './authGuard.js';
import { findCommentById, insertComment, softDeleteComment, updateCommentText } from './db/queries/comments.js';
import { findMessageById } from './db/queries/messages.js';
import { findRoomById, getDmHistoryFloor, isRoomMember, listRoomMemberIds } from './db/queries/rooms.js';
import { isUuid } from './favoritesRules.js';
import { checkFileRefs } from './fileRefs.js';
import { commentCreateLimiter, fileFieldsDenial, messageTextDenial, sanitizeFileSize } from './messageLimits.js';
import { canModifyContent, recordModerationAudit } from './moderation.js';
import { unhideDmForOtherMembers } from './rooms.js';
import { findUserById } from './db/queries/users.js';
import { mentionsOrEmpty, mentionsToStore, sanitizeMentions } from './notificationRules.js';
import { isBoardRoom, notifyBoard, notifyMentions, removeNotificationsForComment, updateMentions } from './notifications.js';
import { notifyOfflineMembers, roomTagFor } from './push.js';
import { signFileUrl } from './upload.js';
import { sanitizeTextFormat } from './textFormat.js';

// messages.js와 동일: 수정/삭제 허용 여부와 가능 시간은 팀 설정([메시지 설정])을 따르며
// moderation.js의 canModifyContent가 판단한다.

/** 본문 앞 공백을 서버가 잘라낸 글자 수 — 멘션 구간도 그만큼 당겨 맞춘다(messages.js와 같다). */
function trimmedLead(raw) {
  return typeof raw === 'string' ? raw.length - raw.trimStart().length : 0;
}

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
    textFormat: deleted ? null : (c.textFormat ?? null),
    mentions: deleted ? [] : mentionsOrEmpty(c.mentions), // 멘션 구간(messages.mentions와 같은 모양).
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

export function createCommentsRouter(io) {
  const router = Router();

  router.post('/messages/:messageId/comments', async (req, res) => {
    // uuid 칸이라 모양이 아닌 id는 DB에 묻지 않는다(DB 오류로 500이 났다).
    const message = isUuid(req.params.messageId) ? await findMessageById(req.params.messageId) : null;
    if (!message) return res.status(404).json({ error: '메시지를 찾을 수 없습니다.' });
    if (!(await isRoomMember(message.roomId, req.user.sub))) {
      return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    }

    const type = ['image', 'file', 'sticker'].includes(req.body?.type) ? req.body.type : 'text';
    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    const rawFileUrl = typeof req.body?.fileUrl === 'string' && req.body.fileUrl ? req.body.fileUrl : null;
    const rawThumbnailUrl =
      typeof req.body?.thumbnailUrl === 'string' && req.body.thumbnailUrl ? req.body.thumbnailUrl : null;
    if (!text && !rawFileUrl) return res.status(400).json({ error: '댓글 내용을 입력하세요.' });
    const fileName = typeof req.body?.fileName === 'string' ? req.body.fileName : null;
    const mimeType = typeof req.body?.mimeType === 'string' ? req.body.mimeType : null;

    const room = await findRoomById(message.roomId);
    // 메시지와 같은 길이 상한(messageLimits.js) — 비밀 대화는 암호문 봉투 길이로, 이모티콘 댓글은 이모티콘 id 길이로 본다.
    const tooLong =
      messageTextDenial(text, { secret: !!room?.isSecret, sticker: type === 'sticker', subject: '댓글은' }) ??
      fileFieldsDenial({ fileName, mimeType });
    if (tooLong) return res.status(400).json({ error: tooLong });
    // 첨부는 메시지와 같은 규칙(fileRefs.js) — 예전엔 보낸 값을 되돌리지도 확인하지도 않고 그대로 저장해서, 어디서 알게 된 파일
    // 이름을 내 댓글에 실으면 그 파일의 새 다운로드 링크를 영영 받을 수 있었다. 비밀 대화는 직접 올린 파일만(자동 삭제가 지운다).
    const files = await checkFileRefs([rawFileUrl, rawThumbnailUrl], {
      senderId: req.user.sub,
      ownedOnly: !!room?.isSecret,
    });
    if (!files.ok) return res.status(400).json({ error: files.error });
    // 검사를 다 통과해 정말 댓글이 생기는 요청만 센다(입력 오류로 다시 보내는 것은 세지 않는다 — calendars.js 일정 추가와 같다).
    // 첨부를 단 댓글은 10초 창에서 뺀다 — 앱은 고른 첨부마다 댓글 하나씩 쉬지 않고 단다(messageLimits.js MESSAGE_SEND_BURST).
    const wait = commentCreateLimiter.hit(req.user.sub, { burst: !rawFileUrl });
    if (wait > 0) return tooMany(res, wait, '댓글 달기');

    const sender = await findUserById(req.user.sub);
    // 멘션은 이 방 멤버만 — 멘션이 없으면 멤버 조회를 건너뛴다(뒤의 푸시에서 어차피 다시 읽는다).
    let memberIds = null;
    let mentions = null;
    if (room && Array.isArray(req.body?.mentions) && req.body.mentions.length > 0) {
      memberIds = await listRoomMemberIds(room.id);
      mentions = mentionsToStore(
        sanitizeMentions(req.body.mentions, text, {
          room,
          senderId: req.user.sub,
          memberIdSet: new Set(memberIds),
          shift: trimmedLead(req.body.text),
        }),
      );
    }
    const comment = await insertComment({
      id: randomUUID(),
      messageId: message.id,
      roomId: message.roomId,
      senderId: req.user.sub,
      senderName: sender?.name ?? sender?.username ?? '알 수 없음',
      type,
      text: text || null,
      textFormat: room?.isSecret ? null : sanitizeTextFormat(req.body?.textFormat, text),
      mentions,
      fileUrl: rawFileUrl ? files.paths.get(rawFileUrl) : null,
      fileName,
      fileSize: sanitizeFileSize(req.body?.fileSize),
      mimeType,
      thumbnailUrl: rawThumbnailUrl ? files.paths.get(rawThumbnailUrl) : null,
    });

    // 평문 DM에서 상대가 이 방을 숨겨뒀으면(hidden) 자동으로 다시 보이게 한다 — socket.js의
    // message:send와 동일한 이유(rooms.js unhideDmForOtherMembers 참고).
    if (room) await unhideDmForOtherMembers(io, room, req.user.sub);

    const dto = toCommentDto(comment);
    io.to(message.roomId).emit('comment:new', dto);
    res.status(201).json(dto);

    // 응답 이후 백그라운드로 — socket.js의 message:send와 동일한 패턴.
    (async () => {
      if (!room) return;
      memberIds ??= await listRoomMemberIds(room.id);
      // 알림 기록(멘션·보드 댓글)을 먼저 — 실패해도 일반 푸시는 그대로 나간다. 멘션 푸시를 받는 사람은 일반 푸시에서 뺀다.
      let pushedUserIds = [];
      try {
        const actor = { id: req.user.sub, name: comment.senderName, user: sender };
        const mentioned = await notifyMentions({ io, room, message, comment, actor, mentions: comment.mentions, memberIds });
        pushedUserIds = mentioned.pushedUserIds;
        // 보드 뷰 게시글의 댓글이면 boardLevel에 따라 보드 알림도 남긴다(멘션 알림을 받은 사람은 뺀다).
        if (isBoardRoom(room) && message.type === 'post') {
          await notifyBoard({ io, event: 'comment', room, post: message, comment, actor, memberIds, excludeIds: mentioned.notifiedUserIds });
        }
      } catch (err) {
        console.error('[notifications] 댓글 알림 기록 실패:', err?.message ?? err);
      }
      await notifyOfflineMembers({
        memberIds,
        senderId: req.user.sub,
        senderName: comment.senderName,
        sender,
        room,
        entry: comment,
        roomTag: roomTagFor(room),
        kind: 'comment',
        excludeUserIds: pushedUserIds,
      });
    })().catch((err) => console.error('[push] 댓글 알림 실패:', err?.message ?? err));
  });

  /**
   * 댓글 한 건 — 메시지 한 건(GET /messages/:id)과 같은 용도·규칙: 그 방 멤버만(403), 지운 댓글과 비밀 대화는 404, DM
   * "진짜 나가기" 이전 글(부모 메시지)에 달린 댓글도 방 메시지 목록에서처럼 없는 것으로(404). 응답은 댓글 DTO(파일 댓글이면
   * 파일 칸 포함).
   */
  router.get('/comments/:id', async (req, res) => {
    const notFound = () => res.status(404).json({ error: '댓글을 찾을 수 없습니다.' });
    const comment = isUuid(req.params.id) ? await findCommentById(req.params.id) : null;
    if (!comment || comment.deletedAt) return notFound();
    const room = await findRoomById(comment.roomId);
    if (!room) return notFound();
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    if (room.isSecret) return notFound();
    const floor = room.type === 'dm' ? await getDmHistoryFloor(room.id, req.user.sub) : null;
    if (floor) {
      const parent = await findMessageById(comment.messageId);
      if (!parent || parent.createdAt < floor) return notFound();
    }
    res.json(toCommentDto(comment));
  });

  router.patch('/comments/:id', async (req, res) => {
    const comment = isUuid(req.params.id) ? await findCommentById(req.params.id) : null;
    if (!comment || comment.deletedAt) return res.status(404).json({ error: '댓글을 찾을 수 없습니다.' });
    if (comment.type !== 'text') return res.status(400).json({ error: '텍스트 댓글만 수정할 수 있습니다.' });
    // 메시지 수정과 완전히 같은 규칙(moderation.js).
    const verdict = await canModifyContent({
      roomId: comment.roomId,
      senderId: comment.senderId,
      createdAt: comment.createdAt,
      requesterId: req.user.sub,
      action: 'edit',
      noun: '댓글',
    });
    if (!verdict.ok) return res.status(verdict.status).json({ error: verdict.error });

    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    if (!text) return res.status(400).json({ error: '댓글 내용을 입력하세요.' });

    const room = await findRoomById(comment.roomId);
    const tooLong = messageTextDenial(text, { secret: !!room?.isSecret, subject: '댓글은' });
    if (tooLong) return res.status(400).json({ error: tooLong });
    const textFormat = room?.isSecret ? null : sanitizeTextFormat(req.body?.textFormat, text);
    // 수정은 멘션 집합을 통째로 바꾼다(안 보내면 없음) — 새로 생긴 멘션에만 알림이 간다.
    let memberIds = null;
    let mentions = null;
    if (room && Array.isArray(req.body?.mentions) && req.body.mentions.length > 0) {
      memberIds = await listRoomMemberIds(room.id);
      mentions = mentionsToStore(
        sanitizeMentions(req.body.mentions, text, {
          room,
          senderId: req.user.sub,
          memberIdSet: new Set(memberIds),
          shift: trimmedLead(req.body.text),
        }),
      );
    }
    const updated = await updateCommentText(comment.id, text, textFormat, mentions);
    const dto = toCommentDto(updated);
    io.to(comment.roomId).emit('comment:edited', dto);
    res.json(dto);

    (async () => {
      if (!room || room.isSecret) return;
      const parent = await findMessageById(comment.messageId);
      if (!parent) return;
      memberIds ??= await listRoomMemberIds(room.id);
      const actor = { id: req.user.sub, name: updated.senderName, user: await findUserById(req.user.sub) };
      await updateMentions({ io, room, message: parent, comment: updated, actor, before: comment.mentions, after: updated.mentions, memberIds });
    })().catch((err) => console.error('[notifications] 댓글 수정 알림 실패:', err?.message ?? err));
  });

  router.delete('/comments/:id', async (req, res) => {
    const comment = isUuid(req.params.id) ? await findCommentById(req.params.id) : null;
    if (!comment || comment.deletedAt) return res.status(404).json({ error: '댓글을 찾을 수 없습니다.' });
    // 메시지 삭제와 완전히 같은 규칙(moderation.js) — 팀의 수정/삭제 허용 여부와 가능 시간,
    // 콘텐츠 관리 권한을 한 곳에서 판단한다.
    const verdict = await canModifyContent({
      roomId: comment.roomId,
      senderId: comment.senderId,
      createdAt: comment.createdAt,
      requesterId: req.user.sub,
      action: 'delete',
      noun: '댓글',
    });
    if (!verdict.ok) return res.status(verdict.status).json({ error: verdict.error });

    await softDeleteComment(comment.id);
    // 이 댓글에 대한 멘션·보드 댓글 알림 기록도 지운다(소프트 삭제라 cascade가 안 탄다).
    await removeNotificationsForComment(io, comment.id);
    // 메시지와 동일: 남의 댓글을 지운 경우(관리자 콘텐츠 관리)만 감사 로그에 남긴다.
    if (comment.senderId !== req.user.sub) {
      await recordModerationAudit(req, comment, 'comment');
    }
    io.to(comment.roomId).emit('comment:deleted', { id: comment.id, messageId: comment.messageId, roomId: comment.roomId });
    res.json({ ok: true });
  });

  return router;
}
