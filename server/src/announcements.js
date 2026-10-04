import { randomUUID } from 'node:crypto';
import { Router } from 'express';
import { teamAccess, topicAccess } from './access.js';
import {
  countAnnouncementComments,
  deleteAnnouncementComment,
  findAnnouncementCommentById,
  findAnnouncementById,
  findLatestAnnouncementForRoom,
  findPinnedAnnouncementBySourceMessage,
  insertAnnouncement,
  insertAnnouncementComment,
  listAnnouncementsForRoom,
  listCommentsForAnnouncement,
  softDeleteAnnouncement,
  unpinAnnouncement,
  updateAnnouncementCommentText,
  updateAnnouncementText,
} from './db/queries/announcements.js';
import { announcementFieldsFromMessage } from './announcementFromMessage.js';
import { toAnnouncementDto } from './announcementDto.js';
import { parseAnnouncementText } from './announcementText.js';
import { findMessageById } from './db/queries/messages.js';
import { findRoomById, isRoomMember, listRoomMemberIds } from './db/queries/rooms.js';
import { findTeamById, isTopicCreator } from './db/queries/teams.js';
import { canModifyContent } from './moderation.js';
import { canCreateTopic, topicWriteDenial } from './permissions.js';
import { notifyOfflineMembers, roomTagFor } from './push.js';
import { signFileUrl } from './upload.js';

function toDto(row) {
  return toAnnouncementDto(row, signFileUrl);
}

/** "공지 자동 내리기" — 클라이언트는 밀리초 epoch만 보낸다(announcement_list_screen.dart의
 * 빠른 선택 버튼들이 계산). 과거 시각이나 너무 먼 미래(1년)는 실수로 보고 막는다. */
function parseAutoUnpinAt(raw) {
  if (raw === undefined || raw === null) return { ok: true, value: null };
  if (typeof raw !== 'number' || !Number.isFinite(raw)) {
    return { ok: false, error: '자동 내리기 시각이 올바르지 않습니다.' };
  }
  const now = Date.now();
  if (raw <= now) return { ok: false, error: '자동 내리기 시각은 미래여야 합니다.' };
  if (raw - now > 366 * 24 * 60 * 60 * 1000) {
    return { ok: false, error: '자동 내리기는 최대 1년 이내로 설정하세요.' };
  }
  return { ok: true, value: new Date(raw) };
}

function toCommentDto(row) {
  return {
    ...row,
    createdAt: new Date(row.createdAt).getTime(),
    editedAt: row.editedAt ? new Date(row.editedAt).getTime() : null,
  };
}

/**
 * 토픽방 공지(카카오톡 공지와 같은 개념) — 쓸 수 있는 사람은 그 팀에서 **토픽을 만들 수
 * 있는 사람과 같다**(팀 설정 topicCreationPolicy, permissions.js의 canCreateTopic). 별도
 * 권한 축을 새로 만들지 않고 이미 있는 걸 그대로 재사용한다 — "토픽방을 관리할 자격이
 * 있는 사람"이라는 의미가 이미 거기 있기 때문이다. 여기에 더해 **그 토픽을 관리할 수 있는
 * 사람**(토픽 관리자·팀 관리자, permissions.js canManageTopic)도 쓸 수 있다.
 *
 * 읽기는 그 방 멤버 전원에게 열려 있다 — 공지는 원래 다 같이 보라고 붙이는 것이므로. 수정/
 * 삭제/내리기는 **작성 본인만** 할 수 있다(요청 사양 그대로 — 메시지/댓글의 "관리자도 남의
 * 글 삭제 가능" 규칙과 달리 여기선 예외를 두지 않는다).
 */
export function createAnnouncementsRouter(io) {
  const router = Router();

  async function requireTopicMember(req, res) {
    const room = await findRoomById(req.params.id);
    if (!room) {
      res.status(404).json({ error: '방을 찾을 수 없습니다.' });
      return null;
    }
    if (room.type !== 'topic') {
      res.status(400).json({ error: '공지는 토픽방에서만 쓸 수 있습니다.' });
      return null;
    }
    if (!(await isRoomMember(room.id, req.user.sub))) {
      res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
      return null;
    }
    return room;
  }

  /** room 소속 + 삭제되지 않음 + 본인 작성 확인까지 한 번에. 통과하면 announcement 행을 준다. */
  async function requireOwnAnnouncement(req, res, room) {
    const announcement = await findAnnouncementById(req.params.announcementId);
    if (!announcement || announcement.roomId !== room.id || announcement.deletedAt) {
      res.status(404).json({ error: '공지를 찾을 수 없습니다.' });
      return null;
    }
    if (announcement.authorId !== req.user.sub) {
      res.status(403).json({ error: '본인이 작성한 공지만 할 수 있습니다.' });
      return null;
    }
    return announcement;
  }

  /** 공지 히스토리(최신순) — pinned:true인 항목이 지금 채팅방 상단에 고정된 공지다. */
  router.get('/rooms/:id/announcements', async (req, res) => {
    const room = await requireTopicMember(req, res);
    if (!room) return;
    const rows = await listAnnouncementsForRoom(room.id);
    res.json(rows.map(toDto));
  });

  router.post('/rooms/:id/announcements', async (req, res) => {
    const room = await requireTopicMember(req, res);
    if (!room) return;

    // 토픽을 만들 수 있는 사람에 더해, 그 토픽을 관리할 수 있는 사람(토픽 관리자·팀 관리자)도 쓴다.
    const access = await topicAccess(room, req.user.sub);
    const team = await findTeamById(room.teamId);
    const isDesignatedTopicCreator =
      team?.topicCreationPolicy === 'designated' ? await isTopicCreator(room.teamId, req.user.sub) : false;
    if (!access.canManage && !canCreateTopic({ ...access, isDesignatedTopicCreator, team })) {
      return res.status(403).json({ error: '공지를 작성할 권한이 없습니다.' });
    }
    // 읽기 전용·보관된 토픽은 공지도 토픽을 관리할 수 있는 사람만 — 공지로 읽기 전용을 우회하지 못하게.
    const denial = topicWriteDenial({ room, canManage: access.canManage });
    if (denial) return res.status(403).json({ error: denial });

    // 메시지 더보기의 "공지 등록" — messageId가 오면 글을 직접 받지 않고 그 메시지에서 뽑는다(텍스트 메시지의 본문,
    // 이미지 메시지의 사진 한 장 + 설명글). 그 밖의 글쓰기 경로는 예전과 같다.
    let text;
    let textFormat = null;
    let source = null;
    let image = null;
    if (req.body?.messageId !== undefined && req.body?.messageId !== null) {
      const messageId = req.body.messageId;
      const message = typeof messageId === 'string' ? await findMessageById(messageId).catch(() => null) : null;
      if (!message || message.deletedAt || message.roomId !== room.id) {
        return res.status(404).json({ error: '이 토픽에서 메시지를 찾을 수 없습니다.' });
      }
      const fields = announcementFieldsFromMessage(message);
      if (!fields.ok) return res.status(fields.status).json({ error: fields.error });
      if (await findPinnedAnnouncementBySourceMessage(room.id, message.id)) {
        return res.status(409).json({ error: '이미 공지로 등록된 메시지입니다.' });
      }
      text = fields.text;
      textFormat = fields.textFormat ?? null;
      image = fields.image;
      source = message;
    } else {
      ({ text, textFormat } = parseAnnouncementText(req.body?.text, req.body?.textFormat));
      if (!text) return res.status(400).json({ error: '내용을 입력하세요.' });
      if (text.length > 2000) return res.status(400).json({ error: '공지는 2000자 이내로 작성하세요.' });
    }

    const autoUnpin = parseAutoUnpinAt(req.body?.autoUnpinAt);
    if (!autoUnpin.ok) return res.status(400).json({ error: autoUnpin.error });

    const row = await insertAnnouncement({
      id: randomUUID(),
      roomId: room.id,
      authorId: req.user.sub,
      authorName: access.user?.name ?? access.user?.username ?? '알 수 없음',
      text,
      textFormat,
      autoUnpinAt: autoUnpin.value,
      sourceMessageId: source?.id ?? null,
      imageUrl: image?.url ?? null,
      imageThumbnailUrl: image?.thumbnailUrl ?? null,
      imageName: image?.name ?? null,
    });
    const dto = toDto({ ...row, commentCount: 0 });
    // 방 멤버 전원의 채팅방 상단 배너가 즉시 이 공지로 바뀌도록 알린다(chat_socket.dart의
    // announcement:new). 목록 화면을 열어둔 사람도 같은 이벤트로 맨 위에 새로 추가한다.
    io.to(room.id).emit('announcement:new', dto);
    res.status(201).json(dto);

    // 응답 이후 백그라운드로 — socket.js의 message:send/comments.js와 동일한 패턴. 지금 접속
    // 중인 멤버는 위 소켓 브로드캐스트로 이미 배너가 바뀌었으니, 오프라인(푸시가 필요한)
    // 멤버에게만 FCM을 보낸다. 방 멤버 전원이 대상이다(글쓰기 권한과 무관 — 공지는 누구나
    // 봐야 하므로).
    (async () => {
      const memberIds = await listRoomMemberIds(room.id);
      await notifyOfflineMembers({
        memberIds,
        senderId: req.user.sub,
        senderName: dto.authorName,
        sender: access.user,
        room,
        entry: { type: 'text', text: dto.text || '[사진]' },
        roomTag: roomTagFor(room),
        kind: 'announcement',
      });
    })().catch((err) => console.error('[push] 공지 알림 실패:', err?.message ?? err));
  });

  router.patch('/rooms/:id/announcements/:announcementId', async (req, res) => {
    const room = await requireTopicMember(req, res);
    if (!room) return;
    const announcement = await requireOwnAnnouncement(req, res, room);
    if (!announcement) return;
    // 메시지 수정과 같은 규칙 — 읽기 전용·보관된 토픽에서는 토픽을 관리할 수 있는 사람만 고친다.
    const denial = topicWriteDenial({ room, canManage: (await topicAccess(room, req.user.sub)).canManage });
    if (denial) return res.status(403).json({ error: denial });

    // 서식(textFormat)을 안 보내면 지운다 — 글이 바뀌면 예전 서식 위치가 어긋나기 때문(announcementText.js).
    const { text, textFormat } = parseAnnouncementText(req.body?.text, req.body?.textFormat);
    // 사진 공지는 글 없이 사진만 둘 수도 있다 — 글을 지워도 된다.
    if (!text && !announcement.imageUrl) return res.status(400).json({ error: '내용을 입력하세요.' });
    if (text.length > 2000) return res.status(400).json({ error: '공지는 2000자 이내로 작성하세요.' });

    const row = await updateAnnouncementText(announcement.id, text, textFormat);
    // 수정해도 댓글 수는 그대로 실어 보낸다(예전엔 0으로 나갔다 — 공지바가 댓글 수를 보여준다).
    const dto = toDto({ ...row, commentCount: await countAnnouncementComments(announcement.id) });
    io.to(room.id).emit('announcement:updated', dto);
    res.json(dto);
  });

  router.delete('/rooms/:id/announcements/:announcementId', async (req, res) => {
    const room = await requireTopicMember(req, res);
    if (!room) return;
    const announcement = await requireOwnAnnouncement(req, res, room);
    if (!announcement) return;

    await softDeleteAnnouncement(announcement.id);
    io.to(room.id).emit('announcement:deleted', { id: announcement.id, roomId: room.id });
    res.json({ ok: true });
  });

  /** "공지 내리기" — 삭제하지 않고 배너에서만 내린다(히스토리에는 그대로 남는다). */
  router.post('/rooms/:id/announcements/:announcementId/unpin', async (req, res) => {
    const room = await requireTopicMember(req, res);
    if (!room) return;
    const announcement = await requireOwnAnnouncement(req, res, room);
    if (!announcement) return;

    await unpinAnnouncement(announcement.id);
    io.to(room.id).emit('announcement:unpinned', { id: announcement.id, roomId: room.id });
    res.json({ ok: true });
  });

  router.get('/rooms/:id/announcements/:announcementId/comments', async (req, res) => {
    const room = await requireTopicMember(req, res);
    if (!room) return;
    const announcement = await findAnnouncementById(req.params.announcementId);
    if (!announcement || announcement.roomId !== room.id || announcement.deletedAt) {
      return res.status(404).json({ error: '공지를 찾을 수 없습니다.' });
    }
    const rows = await listCommentsForAnnouncement(announcement.id);
    res.json(rows.map(toCommentDto));
  });

  router.post('/rooms/:id/announcements/:announcementId/comments', async (req, res) => {
    const room = await requireTopicMember(req, res);
    if (!room) return;
    const announcement = await findAnnouncementById(req.params.announcementId);
    if (!announcement || announcement.roomId !== room.id || announcement.deletedAt) {
      return res.status(404).json({ error: '공지를 찾을 수 없습니다.' });
    }

    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    if (!text) return res.status(400).json({ error: '댓글 내용을 입력하세요.' });
    if (text.length > 1000) return res.status(400).json({ error: '댓글은 1000자 이내로 작성하세요.' });

    const access = await teamAccess(room.teamId, req.user.sub);
    const row = await insertAnnouncementComment({
      id: randomUUID(),
      announcementId: announcement.id,
      roomId: room.id,
      authorId: req.user.sub,
      authorName: access.user?.name ?? access.user?.username ?? '알 수 없음',
      text,
    });
    const dto = toCommentDto(row);
    io.to(room.id).emit('announcement:comment:new', dto);
    res.status(201).json(dto);
  });

  /** 공지 댓글 수정·삭제의 공통 — 이 방·이 공지의 댓글인지까지 확인한다. 없으면 404를 보내고 null. */
  async function requireAnnouncementComment(req, res) {
    const room = await requireTopicMember(req, res);
    if (!room) return null;
    const comment = await findAnnouncementCommentById(req.params.commentId);
    if (!comment || comment.roomId !== room.id || comment.announcementId !== req.params.announcementId) {
      res.status(404).json({ error: '댓글을 찾을 수 없습니다.' });
      return null;
    }
    return { room, comment };
  }

  /** 수정은 작성자만, 삭제는 작성자와 관리자(팀 관리자·토픽 관리자) — 시간 제한 없음(moderation.js isSimpleComment). */
  function canModifyComment(req, room, comment, action) {
    return canModifyContent({
      roomId: room.id,
      senderId: comment.authorId,
      createdAt: comment.createdAt,
      requesterId: req.user.sub,
      action,
      noun: '댓글',
      isSimpleComment: true,
    });
  }

  router.patch('/rooms/:id/announcements/:announcementId/comments/:commentId', async (req, res) => {
    const ctx = await requireAnnouncementComment(req, res);
    if (!ctx) return;
    const { room, comment } = ctx;
    const verdict = await canModifyComment(req, room, comment, 'edit');
    if (!verdict.ok) return res.status(verdict.status).json({ error: verdict.error });

    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    if (!text) return res.status(400).json({ error: '댓글 내용을 입력하세요.' });
    if (text.length > 1000) return res.status(400).json({ error: '댓글은 1000자 이내로 작성하세요.' });

    const updated = await updateAnnouncementCommentText(comment.id, text);
    if (!updated) return res.status(404).json({ error: '댓글을 찾을 수 없습니다.' });
    const dto = toCommentDto(updated);
    io.to(room.id).emit('announcement:comment:edited', dto);
    res.json(dto);
  });

  router.delete('/rooms/:id/announcements/:announcementId/comments/:commentId', async (req, res) => {
    const ctx = await requireAnnouncementComment(req, res);
    if (!ctx) return;
    const { room, comment } = ctx;
    const verdict = await canModifyComment(req, room, comment, 'delete');
    if (!verdict.ok) return res.status(verdict.status).json({ error: verdict.error });

    await deleteAnnouncementComment(comment.id);
    io.to(room.id).emit('announcement:comment:deleted', {
      id: comment.id,
      announcementId: comment.announcementId,
      roomId: room.id,
    });
    res.json({ ok: true });
  });

  return router;
}

/** 채팅방을 열 때 상단 배너에 쓸 "지금 고정된 공지" 1건 — 없으면 null. rooms.js가 방 DTO에
 * 얹어서 클라이언트가 방을 열자마자(목록 재조회 없이) 바로 배너를 그릴 수 있게 한다. */
export async function latestAnnouncementDtoFor(roomId) {
  const row = await findLatestAnnouncementForRoom(roomId);
  return row ? toDto(row) : null;
}
