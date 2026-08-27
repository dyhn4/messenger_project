import { randomUUID } from 'node:crypto';
import { Router } from 'express';
import {
  addRoomMembers,
  findDmRoomByKey,
  findRoomById,
  getMemberFavorite,
  getRoomLastReadMap,
  insertRoom,
  isRoomMember,
  listBrowsableTopics,
  listRoomMemberIds,
  listRoomMemberUsers,
  listRoomsForUser,
  removeRoomMember,
  setMemberFavorite,
} from './db/queries/rooms.js';
import { countUnreadForUser, getLastMessageAt, insertMessage, listMessagesByRoom } from './db/queries/messages.js';
import { countUnreadCommentsForUser, getLastCommentAt, listCommentsForMessages } from './db/queries/comments.js';
import { findUserById, listAllUserIds } from './db/queries/users.js';
import { publicUser } from './users.js';
import { toCommentDto } from './comments.js';
import { toMessageDto } from './messages.js';

async function resolveMembers(roomId) {
  return (await listRoomMemberUsers(roomId)).map(publicUser);
}

/** 시스템 메시지 문구("OOO 님이 참여했습니다" 등)에 쓸 표시 이름. 이름이 없으면 아이디로 대체. */
export async function nameOf(id) {
  const u = await findUserById(id);
  return u?.name ?? u?.username ?? '알 수 없음';
}

/**
 * requesterId를 넘기면 그 사람 기준 안읽음 개수(unreadCount)를 계산해 넣는다. 안읽음은
 * 보는 사람마다 값이 다르므로, 여러 멤버에게 동시에 뿌리는 브로드캐스트에는 절대 넣으면 안 되고
 * (requesterId 생략) 요청자 한 명에게만 가는 REST 응답에서만 넣는다(requesterId 전달).
 */
export async function toRoomDto(room, requesterId) {
  const [members, lastRead, lastMessageAt, lastCommentAt] = await Promise.all([
    resolveMembers(room.id),
    getRoomLastReadMap(room.id),
    getLastMessageAt(room.id),
    getLastCommentAt(room.id),
  ]);
  // 방 목록에서 카테고리 안 정렬 기준(누구에게나 동일한, 사용자 무관 값) — 로그인 직후에도
  // 오프라인 동안 쌓인 활동이 반영되도록, 실시간 소켓 없이도 방 목록 응답 자체에 이 시각을
  // 담아 보낸다(클라이언트 Room.lastActivityAt, desktop_home_screen.dart/room_list_screen.dart
  // 의 _favoriteFirst 정렬 참고).
  const lastActivityAt = Math.max(
    new Date(room.createdAt).getTime(),
    lastMessageAt ? new Date(lastMessageAt).getTime() : 0,
    lastCommentAt ? new Date(lastCommentAt).getTime() : 0,
  );
  const dto = {
    id: room.id,
    type: room.type,
    name: room.name,
    description: room.description ?? null,
    isPublic: room.type === 'topic' ? room.isPublic !== false : undefined,
    members,
    createdAt: new Date(room.createdAt).getTime(),
    lastRead,
    lastActivityAt,
  };
  if (requesterId) {
    const myLastRead = lastRead[requesterId] ?? 0;
    // 로그아웃해 있는 동안 달린 댓글은 comment:new 소켓을 못 받아서 클라이언트가 실시간으로
    // unreadCount를 못 올리므로, 다시 로그인해서 방 목록을 받아올 때 이 REST 응답에서
    // 메시지·댓글 안읽음 수를 합쳐서 내려줘야 뱃지가 정확하다.
    const [unreadMessages, unreadComments] = await Promise.all([
      countUnreadForUser(room.id, requesterId, myLastRead),
      countUnreadCommentsForUser(room.id, requesterId, myLastRead),
    ]);
    dto.unreadCount = unreadMessages + unreadComments;
    dto.favorite = await getMemberFavorite(room.id, requesterId);
  }
  return dto;
}

function dmKeyFor(userIdA, userIdB) {
  return [userIdA, userIdB].sort().join(':');
}

/** 방 멤버십이 바뀔 때 해당 유저들의 소켓을 즉시 방에 join시키고 알린다. */
export async function notifyMembership(io, room) {
  const memberIds = await listRoomMemberIds(room.id);
  const userRooms = memberIds.map((id) => `user:${id}`);
  if (userRooms.length > 0) io.in(userRooms).socketsJoin(room.id);
  io.to(room.id).emit('room:created', await toRoomDto(room));
}

/** 이 사람이 속한 모든 방(다른 기기 포함)에 갱신된 멤버 정보를 알린다 — 프로필/탈퇴 변경 후. */
export async function broadcastMemberUpdate(io, userId) {
  for (const room of await listRoomsForUser(userId)) {
    io.to(room.id).emit('room:created', await toRoomDto(room));
  }
}

/** 참여/초대/퇴장 안내 문구를 일반 메시지처럼 저장하고 방에 브로드캐스트한다. */
export async function postSystemMessage(io, room, text) {
  const message = await insertMessage({
    id: randomUUID(),
    roomId: room.id,
    senderId: null, // 시스템 메시지는 작성자가 없다 — type='system'이 판별 기준.
    senderName: '시스템',
    type: 'system',
    text,
  });
  const dto = { ...message, createdAt: new Date(message.createdAt).getTime() };
  io.to(room.id).emit('message:new', dto);
  return dto;
}

export function createRoomsRouter(io) {
  const router = Router();

  router.get('/rooms', async (req, res) => {
    const myRooms = await listRoomsForUser(req.user.sub);
    res.json(await Promise.all(myRooms.map((r) => toRoomDto(r, req.user.sub))));
  });

  // /rooms/:id 보다 먼저 등록해야 'browse'가 :id로 매칭되지 않습니다.
  // 공개 토픽은 누구에게나(나중에 가입한 회원 포함) 보이고, 비공개 토픽은 이미 멤버인
  // 사람에게만 보인다(초대로만 들어올 수 있음 — 자유 참여 불가는 /join에서 막는다).
  router.get('/rooms/browse', async (req, res) => {
    const rows = await listBrowsableTopics(req.user.sub);
    const withCounts = await Promise.all(
      rows.map(async ({ room, joined }) => ({
        id: room.id,
        name: room.name,
        description: room.description ?? null,
        isPublic: room.isPublic !== false,
        memberCount: (await listRoomMemberIds(room.id)).length,
        joined: !!joined,
      })),
    );
    res.json(withCounts);
  });

  router.post('/rooms/dm', async (req, res) => {
    const { targetUserId } = req.body ?? {};
    if (!targetUserId || typeof targetUserId !== 'string') {
      return res.status(400).json({ error: 'targetUserId가 필요합니다.' });
    }
    if (targetUserId === req.user.sub) {
      return res.status(400).json({ error: '자기 자신과는 DM을 시작할 수 없습니다.' });
    }
    const target = await findUserById(targetUserId);
    if (!target) return res.status(404).json({ error: '대상 사용자를 찾을 수 없습니다.' });

    const dmKey = dmKeyFor(req.user.sub, targetUserId);
    const existing = await findDmRoomByKey(dmKey);
    if (existing) {
      // 둘 중 한쪽이 예전에 "채팅방 나가기"를 했을 수 있으니, 다시 대화를 걸면 그 사람을 되살린다.
      const memberIds = await listRoomMemberIds(existing.id);
      const missing = [req.user.sub, targetUserId].filter((id) => !memberIds.includes(id));
      if (missing.length > 0) {
        await addRoomMembers(existing.id, missing);
        await notifyMembership(io, existing);
      }
      return res.status(200).json(await toRoomDto(existing, req.user.sub));
    }

    const room = await insertRoom({
      id: randomUUID(),
      type: 'dm',
      name: null,
      dmKey,
      createdBy: req.user.sub,
    });
    await addRoomMembers(room.id, [req.user.sub, targetUserId]);
    await notifyMembership(io, room);
    res.status(201).json(await toRoomDto(room, req.user.sub));
  });

  router.post('/rooms', async (req, res) => {
    const { type, name, description, memberIds, isPublic } = req.body ?? {};
    if (type !== 'topic' && type !== 'group') {
      return res.status(400).json({ error: "type은 'topic' 또는 'group'이어야 합니다 (DM은 /rooms/dm 사용)." });
    }
    const trimmedName = typeof name === 'string' ? name.trim() : '';
    if (type === 'topic' && !trimmedName) {
      return res.status(400).json({ error: '토픽 이름을 입력하세요.' });
    }

    const isPublicTopic = type === 'topic' && isPublic !== false;

    let roomMemberIds;
    if (isPublicTopic) {
      // 공개 토픽은 만드는 순간 가입된 회원 전원이 멤버로 들어간다(나중에 가입하는
      // 회원은 /auth/register에서 기존 공개 토픽 전체에 자동으로 추가된다).
      roomMemberIds = await listAllUserIds();
      if (!roomMemberIds.includes(req.user.sub)) roomMemberIds.push(req.user.sub);
    } else {
      const memberIdSet = new Set([req.user.sub, ...(Array.isArray(memberIds) ? memberIds : [])]);
      if (type === 'group' && memberIdSet.size < 2) {
        return res.status(400).json({ error: '그룹에는 나 이외의 멤버가 최소 1명 필요합니다.' });
      }
      roomMemberIds = [...memberIdSet];
    }

    const room = await insertRoom({
      id: randomUUID(),
      type,
      name: trimmedName || null,
      description: type === 'topic' && description ? String(description).trim() : null,
      // 공개 토픽은 지금 회원뿐 아니라 나중에 가입하는 회원에게도 계속 보인다(/rooms/browse).
      isPublic: type === 'topic' ? isPublic !== false : null,
      createdBy: req.user.sub,
    });
    await addRoomMembers(room.id, roomMemberIds);
    await notifyMembership(io, room);

    if (type === 'group') {
      const invitedIds = roomMemberIds.filter((id) => id !== req.user.sub);
      const invitedNames = await Promise.all(invitedIds.map(nameOf));
      if (invitedNames.length > 0) {
        await postSystemMessage(io, room, `${await nameOf(req.user.sub)} 님이 ${invitedNames.join(', ')} 님을 초대했습니다.`);
      }
    }

    res.status(201).json(await toRoomDto(room, req.user.sub));
  });

  router.post('/rooms/:id/join', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (room.type !== 'topic') return res.status(403).json({ error: '토픽방만 자유롭게 참여할 수 있습니다.' });
    if (room.isPublic === false) {
      return res.status(403).json({ error: '비공개 토픽은 초대를 통해서만 참여할 수 있습니다.' });
    }

    if (!(await isRoomMember(room.id, req.user.sub))) {
      await addRoomMembers(room.id, [req.user.sub]);
      await notifyMembership(io, room);
      await postSystemMessage(io, room, `${await nameOf(req.user.sub)} 님이 참여했습니다.`);
    }
    res.json(await toRoomDto(room, req.user.sub));
  });

  router.post('/rooms/:id/invite', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (room.type === 'dm') return res.status(403).json({ error: 'DM에는 멤버를 초대할 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });

    const { userIds } = req.body ?? {};
    const currentMemberIds = await listRoomMemberIds(room.id);
    const candidateIds = (Array.isArray(userIds) ? userIds : []).filter(
      (id) => typeof id === 'string' && !currentMemberIds.includes(id),
    );
    const toInvite = [];
    for (const id of candidateIds) {
      if (await findUserById(id)) toInvite.push(id);
    }
    if (toInvite.length === 0) {
      return res.status(400).json({ error: '초대할 멤버를 선택하세요.' });
    }

    await addRoomMembers(room.id, toInvite);
    await notifyMembership(io, room);

    const invitedNames = await Promise.all(toInvite.map(nameOf));
    await postSystemMessage(io, room, `${await nameOf(req.user.sub)} 님이 ${invitedNames.join(', ')} 님을 초대했습니다.`);

    res.json(await toRoomDto(room, req.user.sub));
  });

  router.post('/rooms/:id/leave', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });

    await removeRoomMember(room.id, req.user.sub);

    io.in(`user:${req.user.sub}`).socketsLeave(room.id); // 나간 사람은 이후 이 방 메시지를 더 이상 받지 않게.
    await postSystemMessage(io, room, `${await nameOf(req.user.sub)} 님이 나갔습니다.`); // socketsLeave 이후라 본인은 자기 퇴장 메시지를 안 받음.
    io.to(room.id).emit('room:created', await toRoomDto(room)); // 남은 멤버들의 목록을 갱신시킨다.

    res.json({ ok: true });
  });

  // 즐겨찾기는 나 혼자만의 표시 설정이라 방 멤버 전체가 아니라 내 다른 기기(user:<id> 룸)에만 알린다.
  router.post('/rooms/:id/favorite', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });

    const favorite = req.body?.favorite === true;
    await setMemberFavorite(room.id, req.user.sub, favorite);
    io.to(`user:${req.user.sub}`).emit('room:favorite', { roomId: room.id, favorite });
    res.json(await toRoomDto(room, req.user.sub));
  });

  router.get('/rooms/:id', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    res.json(await toRoomDto(room, req.user.sub));
  });

  router.get('/rooms/:id/messages', async (req, res) => {
    const room = await findRoomById(req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });

    const limit = Math.min(Number(req.query.limit) || 50, 200);
    const rows = await listMessagesByRoom(room.id, limit);

    const comments = await listCommentsForMessages(rows.map((m) => m.id));
    const commentsByMessageId = new Map();
    for (const c of comments) {
      const list = commentsByMessageId.get(c.messageId) ?? [];
      list.push(toCommentDto(c));
      commentsByMessageId.set(c.messageId, list);
    }

    // 저장은 항상 원본 상대경로(/uploads/xxx)로 해두고, 응답에 낼 때만 매번 새로 서명한다
    // (DB에 서명된 URL을 그대로 저장하면 나중에 다시 조회할 때 이미 만료돼있게 된다).
    res.json(
      rows.map((m) => ({
        ...toMessageDto(m),
        comments: commentsByMessageId.get(m.id) ?? [],
      })),
    );
  });

  return router;
}
