import { randomUUID } from 'node:crypto';
import { verifySocketToken } from './auth.js';
import { findActiveDeviceForUser, touchDeviceLastSeen } from './db/queries/devices.js';
import { insertMessage, markMessageRead } from './db/queries/messages.js';
import { findRoomById, isRoomMember, listRoomMemberIds, listRoomsForUser, setMemberLastRead } from './db/queries/rooms.js';
import { findSecretSessionByRoomId, insertSecretRekey, ackSecretRekey, bumpSecretSessionEpoch } from './db/queries/secretSessions.js';
import { findUserById } from './db/queries/users.js';
import { toMessageDto } from './messages.js';
import { markConnected, markDisconnected } from './presence.js';
import { notifyOfflineMembers, roomTagFor } from './push.js';
import { resolveRawUrl } from './upload.js';

/** 소켓 연결 시 JWT를 확인하고, 연결된 이후의 채팅 이벤트를 처리합니다. */
export function registerSocket(io) {
  io.use(async (socket, next) => {
    try {
      const payload = await verifySocketToken(socket.handshake.auth?.token ?? '');
      socket.data.userId = payload.sub;
      socket.data.username = payload.username;
      // deviceId는 비밀 대화(E2EE) 기능에서만 쓰인다 — 없거나 무효해도 일반 소켓 연결(평문
      // 채팅/알림 등)은 그대로 허용하고, secret:* 이벤트만 이후 개별적으로 막는다.
      const deviceId = socket.handshake.auth?.deviceId;
      if (typeof deviceId === 'string' && deviceId) {
        const device = await findActiveDeviceForUser(deviceId, payload.sub);
        if (device) {
          socket.data.deviceId = device.id;
          touchDeviceLastSeen(device.id).catch(() => {});
        }
      }
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

    // payload: { roomId, type: 'text'|'image'|'file', text?, fileUrl?, fileName?, fileSize?, mimeType?, thumbnailUrl?,
    //   quotedSenderName?, quotedPreview?, forwardedFromSenderName?, forwardedFromCreatedAt? }
    // (quoted*는 "메시지 공유", forwardedFrom*는 "메시지 전달"에서 쓴다 — room_list_screen.dart의
    // 메시지 롱프레스 메뉴, message_share_screen.dart/message_forward_screen.dart 참고.)
    socket.on('message:send', async (payload, ack) => {
      if (!payload || typeof payload !== 'object') return;

      const room = await findRoomById(payload.roomId);
      if (!room || !(await isRoomMember(room.id, socket.data.userId))) {
        ack?.({ ok: false, error: '이 방의 멤버가 아닙니다.' });
        return;
      }

      const sender = await findUserById(socket.data.userId);

      // fileUrl/thumbnailUrl이 서명된 /files/<token> 형태로 오면(메시지 전달 — 클라이언트는
      // 원본이 아니라 서명된 다운로드 URL만 갖고 있다) 원본 상대경로로 되돌린다. 일반적인
      // 새 업로드는 이미 원본 경로라 그대로 통과한다(resolveRawUrl 참고).
      const fileUrl =
        typeof payload.fileUrl === 'string' ? resolveRawUrl(payload.fileUrl) : null;
      const thumbnailUrl =
        typeof payload.thumbnailUrl === 'string' ? resolveRawUrl(payload.thumbnailUrl) : null;

      const message = await insertMessage({
        id: randomUUID(),
        roomId: room.id,
        senderId: socket.data.userId,
        senderName: sender?.name ?? sender?.username ?? socket.data.username,
        type: ['image', 'file', 'sticker'].includes(payload.type) ? payload.type : 'text',
        text: typeof payload.text === 'string' ? payload.text : null,
        fileUrl,
        fileName: typeof payload.fileName === 'string' ? payload.fileName : null,
        fileSize: typeof payload.fileSize === 'number' ? payload.fileSize : null,
        mimeType: typeof payload.mimeType === 'string' ? payload.mimeType : null,
        thumbnailUrl,
        quotedSenderName: typeof payload.quotedSenderName === 'string' ? payload.quotedSenderName : null,
        quotedPreview: typeof payload.quotedPreview === 'string' ? payload.quotedPreview : null,
        forwardedFromSenderName:
          typeof payload.forwardedFromSenderName === 'string' ? payload.forwardedFromSenderName : null,
        forwardedFromCreatedAt:
          typeof payload.forwardedFromCreatedAt === 'number' ? new Date(payload.forwardedFromCreatedAt) : null,
      });

      // 서명은 toMessageDto 안에서 실시간으로만 이뤄진다 — DB에는 항상 원본을 유지해서
      // 나중에 다시 조회될 때도 그때 시점 기준으로 새로 서명할 수 있게 한다.
      const broadcastMessage = toMessageDto(message);
      io.to(room.id).emit('message:new', broadcastMessage);
      ack?.({ ok: true, message: broadcastMessage });

      // 응답을 기다리게 하지 않도록 ack 이후 백그라운드로 보낸다 — 실패해도(토큰 만료 등)
      // notifyOfflineMembers 내부에서 개별적으로 처리되고 메시지 전송 자체엔 영향 없다.
      listRoomMemberIds(room.id)
        .then((memberIds) =>
          notifyOfflineMembers({
            memberIds,
            senderId: socket.data.userId,
            senderName: message.senderName,
            room,
            entry: message,
            roomTag: roomTagFor(room),
            kind: 'message',
          }),
        )
        .catch((err) => console.error('[push] message:send 알림 실패:', err?.message ?? err));
    });

    // payload: { roomId } — 지금 이 방을 보고 있다는 뜻. 다른 멤버들이 안읽음 카운터를 갱신할 수 있도록 브로드캐스트한다.
    socket.on('room:read', async (payload) => {
      const room = await findRoomById(payload?.roomId);
      if (!room || !(await isRoomMember(room.id, socket.data.userId))) return;

      const lastReadAt = Date.now();
      await setMemberLastRead(room.id, socket.data.userId, lastReadAt);

      io.to(room.id).emit('room:read', { roomId: room.id, userId: socket.data.userId, lastReadAt });
    });

    // payload: { roomId, messageId } — 비밀 대화 메시지가 실제로 화면에 노출됐다는 신호.
    // 최초 1회만 readAt이 찍히고(markMessageRead), 자동 삭제 타이머가 설정돼 있으면
    // 그때부터 카운트가 시작된다(텔레그램 비밀 대화와 동일 — 보낸 시점이 아니라 읽은 시점부터).
    socket.on('secret:message-read', async (payload) => {
      const room = await findRoomById(payload?.roomId);
      if (!room || !room.isSecret || !(await isRoomMember(room.id, socket.data.userId))) return;
      if (typeof payload?.messageId !== 'string') return;

      const session = await findSecretSessionByRoomId(room.id);
      const expiresAt = session?.selfDestructSeconds
        ? Date.now() + session.selfDestructSeconds * 1000
        : null;
      const updated = await markMessageRead(payload.messageId, expiresAt);
      if (!updated) return; // 이미 읽음 처리된 메시지(멱등) — 중복 브로드캐스트 안 함.

      io.to(room.id).emit('secret:message-read', {
        roomId: room.id,
        messageId: updated.id,
        readAt: new Date(updated.readAt).getTime(),
        expiresAt: updated.expiresAt ? new Date(updated.expiresAt).getTime() : null,
      });
    });

    // 재키잉 제안/수락 중계 — 서버는 공개키/서명만 보고 그대로 상대에게 전달할 뿐, 공유비밀
    // 계산은 양쪽 클라이언트가 각자 로컬에서 한다.
    // payload: { roomId, keyEpoch, ephemeralPublicKey, ephemeralSignature }
    socket.on('secret:rekey-propose', async (payload) => {
      const room = await findRoomById(payload?.roomId);
      if (!room || !room.isSecret || !(await isRoomMember(room.id, socket.data.userId))) return;
      const { keyEpoch, ephemeralPublicKey, ephemeralSignature } = payload ?? {};
      if (!Number.isInteger(keyEpoch) || !ephemeralPublicKey || !ephemeralSignature) return;

      await insertSecretRekey({
        roomId: room.id,
        keyEpoch,
        proposerUserId: socket.data.userId,
        proposerEphemeralPublicKey: ephemeralPublicKey,
        proposerEphemeralSignature: ephemeralSignature,
      });
      socket.to(room.id).emit('secret:rekey-propose', {
        roomId: room.id,
        keyEpoch,
        proposerUserId: socket.data.userId,
        proposerEphemeralPublicKey: ephemeralPublicKey,
        proposerEphemeralSignature: ephemeralSignature,
      });
    });

    // payload: { roomId, keyEpoch, ephemeralPublicKey, ephemeralSignature }
    socket.on('secret:rekey-ack', async (payload) => {
      const room = await findRoomById(payload?.roomId);
      if (!room || !room.isSecret || !(await isRoomMember(room.id, socket.data.userId))) return;
      const { keyEpoch, ephemeralPublicKey, ephemeralSignature } = payload ?? {};
      if (!Number.isInteger(keyEpoch) || !ephemeralPublicKey || !ephemeralSignature) return;

      await ackSecretRekey(room.id, keyEpoch, {
        responderEphemeralPublicKey: ephemeralPublicKey,
        responderEphemeralSignature: ephemeralSignature,
      });
      await bumpSecretSessionEpoch(room.id, keyEpoch);
      io.to(room.id).emit('secret:rekey-ack', {
        roomId: room.id,
        keyEpoch,
        responderUserId: socket.data.userId,
        responderEphemeralPublicKey: ephemeralPublicKey,
        responderEphemeralSignature: ephemeralSignature,
      });
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
