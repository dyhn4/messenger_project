import { randomUUID } from 'node:crypto';
import { verifySocketToken } from './auth.js';
import { insertMessage } from './db/queries/messages.js';
import { findRoomById, isRoomMember, listRoomsForUser, setMemberLastRead } from './db/queries/rooms.js';
import { findUserById } from './db/queries/users.js';
import { toMessageDto } from './messages.js';
import { markConnected, markDisconnected } from './presence.js';

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

  io.on('connection', (socket) => {
    // 같은 사람이 여러 기기로 동시에 붙어있을 수 있어서, 이 사람의 "첫" 연결일 때만
    // 온라인으로 알린다(presence.js가 기기별 연결 수를 센다).
    if (markConnected(socket.data.userId)) {
      io.emit('presence:update', { userId: socket.data.userId, online: true });
    }

    // 개인용 룸(user:<id>)에 join해두면, REST로 방이 새로 생겼을 때
    // 이 소켓에 곧바로 join시켜줄 수 있습니다 (rooms.js의 notifyMembership 참고).
    socket.join(`user:${socket.data.userId}`);

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

      // 서명은 toMessageDto 안에서 실시간으로만 이뤄진다 — DB에는 항상 원본을 유지해서
      // 나중에 다시 조회될 때도 그때 시점 기준으로 새로 서명할 수 있게 한다.
      const broadcastMessage = toMessageDto(message);
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

    // 방에 join하는 건 DB 조회가 필요해 비동기다 — 리스너 등록(위)보다 뒤에 둬서, 이
    // 조회가 끝나기 전에 도착한 이벤트(message:send 등)를 리스너 없음으로 놓치는 일이
    // 없게 한다. join이 끝나기 전에 이 소켓이 먼저 message:send를 보내는 극히 드문
    // 경우엔 다른 멤버들에게는 정상 전달되고, 보낸 사람 자신의 실시간 echo만 살짝
    // 늦게(방금 보낸 메시지가 REST 재조회 때는 정상적으로 보임) 받을 수 있다.
    listRoomsForUser(socket.data.userId).then((rooms) => {
      for (const room of rooms) socket.join(room.id);
    });
  });
}
