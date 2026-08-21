import { randomUUID } from 'node:crypto';
import { db } from './db.js';
import { verifySocketToken } from './auth.js';

/** 소켓 연결 시 JWT를 확인하고, 연결된 이후의 채팅 이벤트를 처리합니다. */
export function registerSocket(io) {
  io.use((socket, next) => {
    try {
      const payload = verifySocketToken(socket.handshake.auth?.token ?? '');
      socket.data.userId = payload.sub;
      socket.data.username = payload.username;
      next();
    } catch {
      next(new Error('unauthorized'));
    }
  });

  io.on('connection', (socket) => {
    socket.broadcast.emit('presence:online', { username: socket.data.username });

    // 개인용 룸(user:<id>)에 join해두면, REST로 방이 새로 생겼을 때
    // 이 소켓에 곧바로 join시켜줄 수 있습니다 (rooms.js의 notifyMembership 참고).
    socket.join(`user:${socket.data.userId}`);
    for (const room of db.data.rooms) {
      if (room.memberIds.includes(socket.data.userId)) socket.join(room.id);
    }

    // payload: { roomId, type: 'text'|'image'|'file', text?, fileUrl?, fileName?, fileSize?, mimeType? }
    socket.on('message:send', async (payload, ack) => {
      if (!payload || typeof payload !== 'object') return;

      const room = db.data.rooms.find((r) => r.id === payload.roomId);
      if (!room || !room.memberIds.includes(socket.data.userId)) {
        ack?.({ ok: false, error: '이 방의 멤버가 아닙니다.' });
        return;
      }

      const sender = db.data.users.find((u) => u.id === socket.data.userId);

      const message = {
        id: randomUUID(),
        roomId: room.id,
        senderId: socket.data.userId,
        senderName: sender?.name ?? sender?.username ?? socket.data.username,
        type: payload.type === 'image' || payload.type === 'file' ? payload.type : 'text',
        text: typeof payload.text === 'string' ? payload.text : null,
        fileUrl: typeof payload.fileUrl === 'string' ? payload.fileUrl : null,
        fileName: typeof payload.fileName === 'string' ? payload.fileName : null,
        fileSize: typeof payload.fileSize === 'number' ? payload.fileSize : null,
        mimeType: typeof payload.mimeType === 'string' ? payload.mimeType : null,
        createdAt: Date.now(),
      };

      db.data.messages.push(message);
      await db.write();

      io.to(room.id).emit('message:new', message);
      ack?.({ ok: true, message });
    });

    // payload: { roomId } — 지금 이 방을 보고 있다는 뜻. 다른 멤버들이 안읽음 카운터를 갱신할 수 있도록 브로드캐스트한다.
    socket.on('room:read', async (payload) => {
      const room = db.data.rooms.find((r) => r.id === payload?.roomId);
      if (!room || !room.memberIds.includes(socket.data.userId)) return;

      room.lastRead = room.lastRead || {};
      const lastReadAt = Date.now();
      room.lastRead[socket.data.userId] = lastReadAt;
      await db.write();

      io.to(room.id).emit('room:read', { roomId: room.id, userId: socket.data.userId, lastReadAt });
    });

    socket.on('disconnect', () => {
      socket.broadcast.emit('presence:offline', { username: socket.data.username });
    });
  });
}
