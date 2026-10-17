import { Router } from 'express';
import { topicAccess } from './access.js';
import { splitReaders } from './boardRules.js';
import {
  listPostReads,
  listRoomMemberNames,
  listUnreadMustRead,
  markPostRead,
  setPostMustRead,
} from './db/queries/board.js';
import { findMessageById, listAttachmentsForMessages } from './db/queries/messages.js';
import { findRoomById, listRoomMemberIds } from './db/queries/rooms.js';
import { findUserById } from './db/queries/users.js';
import { toMessageDto } from './messages.js';
import { notifyBoard } from './notifications.js';

/**
 * 보드 보강 — 게시글 필독 지정, 읽음 기록·읽음 확인, 내가 안 읽은 필독. 말머리는 토픽 설정(rooms.js PATCH /rooms/:id의 boardCategories)과
 * 게시글 쓰기·고치기(sendMessage.js·messages.js의 categoryId)에서. 규칙은 boardRules.js.
 */
export function createBoardExtrasRouter(io) {
  const router = Router();

  /** 보드 게시글과 그 방·내 권한 — 아니면 응답하고 null. */
  async function loadPost(req, res) {
    const message = await findMessageById(req.params.id);
    if (!message || message.deletedAt || message.type !== 'post') {
      res.status(404).json({ error: '게시글을 찾을 수 없습니다.' });
      return null;
    }
    const room = await findRoomById(message.roomId);
    if (!room || room.type !== 'topic' || room.viewMode !== 'board') {
      res.status(404).json({ error: '게시글을 찾을 수 없습니다.' });
      return null;
    }
    const access = await topicAccess(room, req.user.sub);
    if (!access.isRoomMember) {
      res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
      return null;
    }
    return { message, room, access };
  }

  /** 필독 지정·해제 `{ mustRead }` — 토픽 관리자만. 지정하면 멤버에게 "[필독] 제목" 보드 알림. */
  router.post('/messages/:id/must-read', async (req, res) => {
    const ctx = await loadPost(req, res);
    if (!ctx) return;
    if (typeof req.body?.mustRead !== 'boolean') return res.status(400).json({ error: 'mustRead는 true/false여야 합니다.' });
    if (!ctx.access.canManage) return res.status(403).json({ error: '토픽 관리자만 필독을 정할 수 있습니다.' });
    const on = req.body.mustRead;
    const updated = on === !!ctx.message.mustReadAt ? ctx.message : await setPostMustRead(ctx.message.id, on);
    const byMessage = await listAttachmentsForMessages([updated.id]);
    const dto = toMessageDto({ ...updated, attachments: byMessage[updated.id] });
    io.to(updated.roomId).emit('message:edited', dto);
    res.json(dto);
    if (on && !ctx.message.mustReadAt) {
      const actor = await findUserById(req.user.sub);
      notifyBoard({
        io,
        event: 'mustRead',
        room: ctx.room,
        post: updated,
        actor: { id: req.user.sub, name: actor?.name ?? actor?.username, user: actor },
        memberIds: await listRoomMemberIds(ctx.room.id),
      }).catch((err) => console.error('[board] 필독 알림 실패:', err?.message ?? err));
    }
  });

  /** 게시글을 열었다 — 처음 연 시각을 남기고(쓴 사람은 남기지 않음), 새로 읽었으면 그 방에 `post:read`(읽음 수가 바뀜). */
  router.post('/messages/:id/post-read', async (req, res) => {
    const ctx = await loadPost(req, res);
    if (!ctx) return;
    if (ctx.message.senderId === req.user.sub) return res.json({ ok: true, first: false });
    const first = await markPostRead(ctx.message.id, req.user.sub);
    if (first) io.to(ctx.room.id).emit('post:read', { roomId: ctx.room.id, messageId: ctx.message.id, userId: req.user.sub });
    res.json({ ok: true, first });
  });

  /** 읽음 확인 `{ read: [{ userId, name, readAt }], unread: [{ userId, name }] }` — 방 멤버면 누구나(공지 읽음 확인과 같다). */
  router.get('/messages/:id/readers', async (req, res) => {
    const ctx = await loadPost(req, res);
    if (!ctx) return;
    const [members, reads] = await Promise.all([listRoomMemberNames(ctx.room.id), listPostReads(ctx.message.id)]);
    res.json(splitReaders({ members, reads, authorId: ctx.message.senderId, postedAt: ctx.message.createdAt }));
  });

  /** 이 보드에서 내가 아직 안 읽은 필독 `[{ id, title, createdAt, mustReadAt }]`(보드 위 "필독 안 읽음 N"). */
  router.get('/rooms/:id/must-read', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room || room.type !== 'topic' || room.viewMode !== 'board') return res.status(404).json({ error: '보드를 찾을 수 없습니다.' });
    const access = await topicAccess(room, req.user.sub);
    if (!access.isRoomMember) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    const rows = await listUnreadMustRead(room.id, req.user.sub);
    res.json(
      rows.map((r) => ({
        id: r.id,
        title: r.title ?? '',
        createdAt: new Date(r.createdAt).getTime(),
        mustReadAt: new Date(r.mustReadAt).getTime(),
      })),
    );
  });

  return router;
}
