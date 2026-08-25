import { randomUUID } from 'node:crypto';
import { verifySocketToken } from './auth.js';
import { insertMessage } from './db/queries/messages.js';
import { findRoomById, isRoomMember, listRoomsForUser, setMemberLastRead } from './db/queries/rooms.js';
import { findUserById } from './db/queries/users.js';
import { markConnected, markDisconnected } from './presence.js';
import { signFileUrl } from './upload.js';

/** 소켓 연결 시 JWT를 확인하고, 연결된 이후의 채팅 이벤트를 처리합니다. */
export function registerSocket(io) {
  io.use(async (socket, next) => {
    try {
      const payload = await verifySocketToken(socket.handshake.auth?.token ?? '');
      socket.data.userId = payload.sub;
      socket.data.username = payload.username;
      next();
    } catch {
      next(new Error('unauthorized'));
    }
  });

  io.on('connection', async (socket) => {
    // 같은 사람이 여러 기기로 동시에 붙어있을 수 있어서, 이 사람의 "첫" 연결일 때만
    // 온라인으로 알린다(presence.js가 기기별 연결 수를 센다).
    if (markConnected(socket.data.userId)) {
      io.emit('presence:update', { userId: socket.data.userId, online: true });
    }

    // 개인용 룸(user:<id>)에 join해두면, REST로 방이 새로 생겼을 때
    // 이 소켓에 곧바로 join시켜줄 수 있습니다 (rooms.js의 notifyMembership 참고).
    socket.join(`user:${socket.data.userId}`);
    for (const room of await listRoomsForUser(socket.data.userId)) {
      socket.join(room.id);
    }

    // payload: { roomId, type: 'text'|'image'|'file', text?, fileUrl?, fileName?, fileSize?, mimeType? }
    socket.on('message:send', async (payload, ack) => {
      if (!payload || typeof payload !== 'object') return;

      const room = await findRoomById(payload.roomId);
      if (!room || !(await isRoomMember(room.id, socket.data.userId))) {
        ack?.({ ok: false, error: '이 방의 멤버가 아닙니다.' });
        return;
      }

      const sender = await findUserById(socket.data.userId);

      const message = await insertMessage({
        id: randomUUID(),
        roomId: room.id,
        senderId: socket.data.userId,
        senderName: sender?.name ?? sender?.username ?? socket.data.username,
        type: payload.type === 'image' || payload.type === 'file' ? payload.type : 'text',
        text: typeof payload.text === 'string' ? payload.text : null,
        fileUrl: typeof payload.fileUrl === 'string' ? payload.fileUrl : null, // 원본 상대경로 그대로 저장.
        fileName: typeof payload.fileName === 'string' ? payload.fileName : null,
        fileSize: typeof payload.fileSize === 'number' ? payload.fileSize : null,
        mimeType: typeof payload.mimeType === 'string' ? payload.mimeType : null,
      });

      // 실시간으로 내보낼 때만 서명한다 — DB에는 항상 원본을 유지해서 나중에 다시 조회될
      // 때도 그때 시점 기준으로 새로 서명할 수 있게 한다.
      const broadcastMessage = {
        ...message,
        createdAt: new Date(message.createdAt).getTime(),
        fileUrl: signFileUrl(message.fileUrl, message.fileName),
      };
      io.to(room.id).emit('message:new', broadcastMessage);
      ack?.({ ok: true, message: broadcastMessage });
    });

    // payload: { roomId } — 지금 이 방을 보고 있다는 뜻. 다른 멤버들이 안읽음 카운터를 갱신할 수 있도록 브로드캐스트한다.
    socket.on('room:read', async (payload) => {
      const room = await findRoomById(payload?.roomId);
      if (!room || !(await isRoomMember(room.id, socket.data.userId))) return;

      const lastReadAt = Date.now();
      await setMemberLastRead(room.id, socket.data.userId, lastReadAt);

      io.to(room.id).emit('room:read', { roomId: room.id, userId: socket.data.userId, lastReadAt });
    });

    socket.on('disconnect', () => {
      // 이 사람의 "마지막" 연결이 끊겼을 때만 오프라인으로 알린다.
      if (markDisconnected(socket.data.userId)) {
        io.emit('presence:update', { userId: socket.data.userId, online: false });
      }
    });
  });
}
