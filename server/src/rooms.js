import { randomUUID } from 'node:crypto';
import { Router } from 'express';
import { db } from './db.js';
import { publicUser } from './users.js';

function resolveMembers(memberIds) {
  return memberIds
    .map((id) => db.data.users.find((u) => u.id === id))
    .filter(Boolean)
    .map(publicUser);
}

/**
 * requesterId를 넘기면 그 사람 기준 안읽음 개수(unreadCount)를 계산해 넣는다. 안읽음은
 * 보는 사람마다 값이 다르므로, 여러 멤버에게 동시에 뿌리는 브로드캐스트에는 절대 넣으면 안 되고
 * (requesterId 생략) 요청자 한 명에게만 가는 REST 응답에서만 넣는다(requesterId 전달).
 */
function toRoomDto(room, requesterId) {
  const dto = {
    id: room.id,
    type: room.type,
    name: room.name,
    description: room.description ?? null,
    members: resolveMembers(room.memberIds),
    createdAt: room.createdAt,
    lastRead: room.lastRead ?? {},
  };
  if (requesterId) {
    const myLastRead = (room.lastRead ?? {})[requesterId] ?? 0;
    dto.unreadCount = db.data.messages.filter(
      (m) => m.roomId === room.id && m.senderId !== requesterId && m.type !== 'system' && m.createdAt > myLastRead,
    ).length;
  }
  return dto;
}

function dmKeyFor(userIdA, userIdB) {
  return [userIdA, userIdB].sort().join(':');
}

/** io를 캡처해 방 멤버십이 바뀔 때 해당 유저들의 소켓을 즉시 방에 join시키고 알립니다. */
export function createRoomsRouter(io) {
  const router = Router();

  function notifyMembership(room) {
    const userRooms = room.memberIds.map((id) => `user:${id}`);
    if (userRooms.length > 0) io.in(userRooms).socketsJoin(room.id);
    io.to(room.id).emit('room:created', toRoomDto(room));
  }

  /** 참여/초대/퇴장 안내 문구를 일반 메시지처럼 저장하고 방에 브로드캐스트한다. */
  async function postSystemMessage(room, text) {
    const message = {
      id: randomUUID(),
      roomId: room.id,
      senderId: 'system',
      senderName: '시스템',
      type: 'system',
      text,
      fileUrl: null,
      fileName: null,
      fileSize: null,
      mimeType: null,
      createdAt: Date.now(),
    };
    db.data.messages.push(message);
    await db.write();
    io.to(room.id).emit('message:new', message);
    return message;
  }

  router.get('/rooms', (req, res) => {
    const myRooms = db.data.rooms.filter((r) => r.memberIds.includes(req.user.sub));
    res.json(myRooms.map((r) => toRoomDto(r, req.user.sub)));
  });

  // /rooms/:id 보다 먼저 등록해야 'browse'가 :id로 매칭되지 않습니다.
  router.get('/rooms/browse', (req, res) => {
    const topics = db.data.rooms.filter((r) => r.type === 'topic');
    res.json(
      topics.map((r) => ({
        id: r.id,
        name: r.name,
        description: r.description ?? null,
        memberCount: r.memberIds.length,
        joined: r.memberIds.includes(req.user.sub),
      })),
    );
  });

  router.post('/rooms/dm', async (req, res) => {
    const { targetUserId } = req.body ?? {};
    if (!targetUserId || typeof targetUserId !== 'string') {
      return res.status(400).json({ error: 'targetUserId가 필요합니다.' });
    }
    if (targetUserId === req.user.sub) {
      return res.status(400).json({ error: '자기 자신과는 DM을 시작할 수 없습니다.' });
    }
    const target = db.data.users.find((u) => u.id === targetUserId);
    if (!target) return res.status(404).json({ error: '대상 사용자를 찾을 수 없습니다.' });

    const dmKey = dmKeyFor(req.user.sub, targetUserId);
    const existing = db.data.rooms.find((r) => r.type === 'dm' && r.dmKey === dmKey);
    if (existing) {
      // 둘 중 한쪽이 예전에 "채팅방 나가기"를 했을 수 있으니, 다시 대화를 걸면 그 사람을 되살린다.
      let revived = false;
      for (const id of [req.user.sub, targetUserId]) {
        if (!existing.memberIds.includes(id)) {
          existing.memberIds.push(id);
          revived = true;
        }
      }
      if (revived) {
        await db.write();
        notifyMembership(existing);
      }
      return res.status(200).json(toRoomDto(existing, req.user.sub));
    }

    const room = {
      id: randomUUID(),
      type: 'dm',
      name: null,
      memberIds: [req.user.sub, targetUserId],
      dmKey,
      createdBy: req.user.sub,
      createdAt: Date.now(),
      lastRead: {},
    };
    db.data.rooms.push(room);
    db.write().then(() => notifyMembership(room));
    res.status(201).json(toRoomDto(room, req.user.sub));
  });

  router.post('/rooms', async (req, res) => {
    const { type, name, description, memberIds } = req.body ?? {};
    if (type !== 'topic' && type !== 'group') {
      return res.status(400).json({ error: "type은 'topic' 또는 'group'이어야 합니다 (DM은 /rooms/dm 사용)." });
    }
    const trimmedName = typeof name === 'string' ? name.trim() : '';
    if (type === 'topic' && !trimmedName) {
      return res.status(400).json({ error: '토픽 이름을 입력하세요.' });
    }

    const memberIdSet = new Set([req.user.sub, ...(Array.isArray(memberIds) ? memberIds : [])]);
    if (type === 'group' && memberIdSet.size < 2) {
      return res.status(400).json({ error: '그룹에는 나 이외의 멤버가 최소 1명 필요합니다.' });
    }

    const room = {
      id: randomUUID(),
      type,
      name: trimmedName || null,
      description: type === 'topic' && description ? String(description).trim() : undefined,
      memberIds: [...memberIdSet],
      createdBy: req.user.sub,
      createdAt: Date.now(),
      lastRead: {},
    };
    db.data.rooms.push(room);
    await db.write();
    notifyMembership(room);

    if (type === 'group') {
      const invitedIds = [...memberIdSet].filter((id) => id !== req.user.sub);
      const invitedNames = invitedIds
        .map((id) => db.data.users.find((u) => u.id === id)?.username)
        .filter(Boolean);
      if (invitedNames.length > 0) {
        await postSystemMessage(room, `${req.user.username} 님이 ${invitedNames.join(', ')} 님을 초대했습니다.`);
      }
    }

    res.status(201).json(toRoomDto(room, req.user.sub));
  });

  router.post('/rooms/:id/join', async (req, res) => {
    const room = db.data.rooms.find((r) => r.id === req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (room.type !== 'topic') return res.status(403).json({ error: '토픽방만 자유롭게 참여할 수 있습니다.' });

    if (!room.memberIds.includes(req.user.sub)) {
      room.memberIds.push(req.user.sub);
      await db.write();
      notifyMembership(room);
      await postSystemMessage(room, `${req.user.username} 님이 참여했습니다.`);
    }
    res.json(toRoomDto(room, req.user.sub));
  });

  router.post('/rooms/:id/invite', async (req, res) => {
    const room = db.data.rooms.find((r) => r.id === req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (room.type === 'dm') return res.status(403).json({ error: 'DM에는 멤버를 초대할 수 없습니다.' });
    if (!room.memberIds.includes(req.user.sub)) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });

    const { userIds } = req.body ?? {};
    const toInvite = (Array.isArray(userIds) ? userIds : []).filter(
      (id) => typeof id === 'string' && !room.memberIds.includes(id) && db.data.users.some((u) => u.id === id),
    );
    if (toInvite.length === 0) {
      return res.status(400).json({ error: '초대할 멤버를 선택하세요.' });
    }

    room.memberIds.push(...toInvite);
    await db.write();
    notifyMembership(room);

    const invitedNames = toInvite.map((id) => db.data.users.find((u) => u.id === id)?.username).filter(Boolean);
    await postSystemMessage(room, `${req.user.username} 님이 ${invitedNames.join(', ')} 님을 초대했습니다.`);

    res.json(toRoomDto(room, req.user.sub));
  });

  router.post('/rooms/:id/leave', async (req, res) => {
    const room = db.data.rooms.find((r) => r.id === req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (!room.memberIds.includes(req.user.sub)) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });

    room.memberIds = room.memberIds.filter((id) => id !== req.user.sub);
    await db.write();

    io.in(`user:${req.user.sub}`).socketsLeave(room.id); // 나간 사람은 이후 이 방 메시지를 더 이상 받지 않게.
    await postSystemMessage(room, `${req.user.username} 님이 나갔습니다.`); // socketsLeave 이후라 본인은 자기 퇴장 메시지를 안 받음.
    io.to(room.id).emit('room:created', toRoomDto(room)); // 남은 멤버들의 목록을 갱신시킨다.

    res.json({ ok: true });
  });

  router.get('/rooms/:id', (req, res) => {
    const room = db.data.rooms.find((r) => r.id === req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (!room.memberIds.includes(req.user.sub)) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    res.json(toRoomDto(room, req.user.sub));
  });

  router.get('/rooms/:id/messages', (req, res) => {
    const room = db.data.rooms.find((r) => r.id === req.params.id);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (!room.memberIds.includes(req.user.sub)) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });

    const limit = Math.min(Number(req.query.limit) || 50, 200);
    const all = db.data.messages.filter((m) => m.roomId === room.id);
    res.json(all.slice(Math.max(0, all.length - limit)));
  });

  return router;
}
