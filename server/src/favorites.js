import { Router } from 'express';
import { findCommentById } from './db/queries/comments.js';
import {
  listFavoriteComments,
  listFavoriteFileRows,
  listFavoriteIds,
  listFavoriteMemberRows,
  listFavoriteMessages,
  listFavoritePollRows,
  listFavoriteRoomRows,
  setCommentFavorite,
  setMemberFavorite,
  setMessageFavorite,
} from './db/queries/favorites.js';
import { findMessageById, listAttachmentsForMessages } from './db/queries/messages.js';
import { findRoomById, isRoomMember } from './db/queries/rooms.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { isTeamMember } from './db/queries/teams.js';
import { toCommentDto } from './comments.js';
import { toMessageDto } from './messages.js';
import { isUuid, mergeFavoriteLists, parseFavoritesQuery } from './favoritesRules.js';
import { accountRole } from './permissions.js';
import { attachPolls } from './polls.js';
import { roomDisplayName } from './rooms.js';
import { signFileUrl } from './upload.js';
import { publicUser } from './users.js';

export function createFavoritesRouter(io) {
  const router = Router();

  /** 즐겨찾기는 사람마다 따로라서 내 다른 기기(user:<id> 룸)에만 알린다(poll:favorite·room:favorite과 같은 방식). */
  function notifyChanged(userId, payload) {
    io.to(`user:${userId}`).emit('favorite:changed', payload);
  }

  /** 풀기(favorite=false)는 권한을 안 본다 — 방을 나갔거나 글이 지워져도 내 목록에서 뺄 수 있어야 한다. */
  function readFavoriteFlag(req, res) {
    if (typeof req.body?.favorite !== 'boolean') {
      res.status(400).json({ error: 'favorite는 true/false여야 합니다.' });
      return null;
    }
    return req.body.favorite;
  }

  router.put('/messages/:id/favorite', async (req, res) => {
    const favorite = readFavoriteFlag(req, res);
    if (favorite === null) return;
    if (!isUuid(req.params.id)) return res.status(404).json({ error: '메시지를 찾을 수 없습니다.' });
    if (favorite) {
      const message = await findMessageById(req.params.id);
      if (!message || message.deletedAt) return res.status(404).json({ error: '메시지를 찾을 수 없습니다.' });
      if (!(await isRoomMember(message.roomId, req.user.sub))) {
        return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
      }
      if (message.type === 'system') return res.status(400).json({ error: '시스템 메시지는 즐겨찾기할 수 없습니다.' });
      if (message.type === 'poll') {
        return res.status(400).json({ error: '투표는 /polls/:pollId/favorite로 즐겨찾기합니다.' });
      }
      const room = await findRoomById(message.roomId);
      if (room?.isSecret) return res.status(400).json({ error: '비밀 대화는 즐겨찾기할 수 없습니다.' });
    }
    await setMessageFavorite(req.user.sub, req.params.id, favorite);
    notifyChanged(req.user.sub, { kind: 'message', id: req.params.id, favorite });
    res.json({ favorite });
  });

  router.put('/comments/:id/favorite', async (req, res) => {
    const favorite = readFavoriteFlag(req, res);
    if (favorite === null) return;
    if (!isUuid(req.params.id)) return res.status(404).json({ error: '댓글을 찾을 수 없습니다.' });
    if (favorite) {
      const comment = await findCommentById(req.params.id);
      if (!comment || comment.deletedAt) return res.status(404).json({ error: '댓글을 찾을 수 없습니다.' });
      if (!(await isRoomMember(comment.roomId, req.user.sub))) {
        return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
      }
      const room = await findRoomById(comment.roomId);
      if (room?.isSecret) return res.status(400).json({ error: '비밀 대화는 즐겨찾기할 수 없습니다.' });
    }
    await setCommentFavorite(req.user.sub, req.params.id, favorite);
    notifyChanged(req.user.sub, { kind: 'comment', id: req.params.id, favorite });
    res.json({ favorite });
  });

  router.put('/teams/:teamId/members/:userId/favorite', async (req, res) => {
    const favorite = readFavoriteFlag(req, res);
    if (favorite === null) return;
    const { teamId, userId } = req.params;
    if (!isUuid(teamId) || !isUuid(userId)) {
      return res.status(404).json({ error: '멤버를 찾을 수 없습니다.' });
    }
    if (favorite) {
      if (userId === req.user.sub) return res.status(400).json({ error: '나 자신은 즐겨찾기할 수 없습니다.' });
      if (!(await isTeamMember(teamId, req.user.sub))) {
        return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
      }
      if (!(await isTeamMember(teamId, userId))) {
        return res.status(404).json({ error: '이 팀의 멤버가 아닙니다.' });
      }
    }
    await setMemberFavorite(req.user.sub, teamId, userId, favorite);
    notifyChanged(req.user.sub, { kind: 'member', id: userId, teamId, favorite });
    res.json({ favorite });
  });

  /** 내가 즐겨찾기한 메시지·댓글·멤버 id 전부 — 앱이 메뉴의 "즐겨찾기 / 즐겨찾기 해제"를 정하는 데 쓴다. */
  router.get('/favorites/ids', async (req, res) => {
    res.json(await listFavoriteIds(req.user.sub));
  });

  router.get('/favorites', async (req, res) => {
    const q = parseFavoritesQuery(req.query);
    if (q.error) return res.status(400).json({ error: q.error });
    if (!(await isTeamMember(q.teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    const me = req.user.sub;
    const page = { before: q.before, limit: q.limit };
    const want = (type) => q.type === 'all' || q.type === type;

    // 방 이름은 여러 항목이 같은 방을 가리키므로 한 번씩만 계산한다.
    const roomNames = new Map();
    async function roomNameOf(room) {
      if (!roomNames.has(room.id)) roomNames.set(room.id, await roomDisplayName(room, me));
      return roomNames.get(room.id) ?? null;
    }
    const base = async (room, favoritedAt) => ({
      favoritedAt: favoritedAt ? new Date(favoritedAt).getTime() : null,
      roomId: room.id,
      roomName: await roomNameOf(room),
    });

    const [messageRows, commentRows, fileRows, pollRows, memberRows, roomRows, settings] = await Promise.all([
      want('message') ? listFavoriteMessages(me, q.teamId, page) : [],
      want('comment') ? listFavoriteComments(me, q.teamId, page) : [],
      want('file') ? listFavoriteFileRows(me, q.teamId, page) : [],
      want('poll') ? listFavoritePollRows(me, q.teamId, page) : [],
      want('member') ? listFavoriteMemberRows(me, q.teamId, page) : [],
      // 대화방은 담은 시각이 없어 쪽 나누지 않는다 — '전체'에서는 첫 쪽(before 없음) 맨 앞에만 싣는다.
      want('room') && (q.type === 'room' || !q.before) ? listFavoriteRoomRows(me, q.teamId) : [],
      want('member') ? getServerSettings() : null,
    ]);

    const cut = (rows) => rows.slice(0, q.limit); // 하나 더 받아 온 것은 hasMore 계산에만 쓴다.

    // 메시지(일반·게시글) — 첨부를 붙여 DTO로.
    const messageItems = [];
    {
      const kept = cut(messageRows);
      const attachments = await listAttachmentsForMessages(kept.map((r) => r.message.id));
      for (const r of kept) {
        messageItems.push({
          type: 'message',
          ...(await base(r.room, r.favoritedAt)),
          message: toMessageDto({ ...r.message, attachments: attachments[r.message.id] }),
        });
      }
    }

    const commentItems = [];
    for (const r of cut(commentRows)) {
      commentItems.push({
        type: 'comment',
        ...(await base(r.room, r.favoritedAt)),
        comment: toCommentDto(r.comment),
        parentMessage: {
          id: r.parent.id,
          senderName: r.parent.senderName,
          type: r.parent.type,
          text: r.parent.title ?? r.parent.text ?? null,
        },
      });
    }

    const fileItems = [];
    {
      const kept = cut(fileRows);
      const attachments = await listAttachmentsForMessages(kept.map((r) => r.message.id));
      for (const r of kept) {
        fileItems.push({
          type: 'file',
          ...(await base(r.room, r.file.createdAt)),
          messageId: r.message.id,
          fileUrl: signFileUrl(r.file.fileUrl, r.file.fileName),
          fileName: r.file.fileName ?? null,
          message: toMessageDto({ ...r.message, attachments: attachments[r.message.id] }),
        });
      }
    }

    const pollItems = [];
    {
      const kept = cut(pollRows);
      const withPolls = await attachPolls(
        kept.map((r) => r.message),
        me,
      );
      const attachments = await listAttachmentsForMessages(kept.map((r) => r.message.id));
      for (const [i, r] of kept.entries()) {
        pollItems.push({
          type: 'poll',
          ...(await base(r.room, r.favoritedAt)),
          message: toMessageDto({ ...withPolls[i], attachments: attachments[r.message.id] }),
        });
      }
    }

    const byTeam = settings ? settings.orgScope !== 'account' : true;
    const memberItems = cut(memberRows).map((r) => ({
      type: 'member',
      favoritedAt: new Date(r.favoritedAt).getTime(),
      teamId: q.teamId,
      user: {
        ...publicUser(r.user),
        role: accountRole(r.user),
        isOwner: r.isOwner === 'owner',
        department: (byTeam ? r.department : r.user.department) ?? null,
        position: (byTeam ? r.position : r.user.position) ?? null,
      },
    }));

    const roomItems = [];
    for (const room of roomRows) {
      roomItems.push({
        type: 'room',
        favoritedAt: null,
        roomId: room.id,
        roomName: await roomNameOf(room),
        roomType: room.type,
        isSecret: !!room.isSecret,
        isSelf: !!room.isSelf,
      });
    }
    roomItems.sort((a, b) => (a.roomName ?? '').localeCompare(b.roomName ?? '', 'ko'));

    const dated = [messageRows, commentRows, fileRows, pollRows, memberRows].some((rows) => rows.length > q.limit);
    const merged = mergeFavoriteLists([messageItems, commentItems, fileItems, pollItems, memberItems], q.limit);
    // 종류별로 이미 limit으로 잘라 섞었으므로 더 있는지는 잘라내기 전 원본 기준으로 본다.
    res.json({ items: [...roomItems, ...merged.items], hasMore: merged.hasMore || dated });
  });

  return router;
}
