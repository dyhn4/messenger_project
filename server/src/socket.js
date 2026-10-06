import { verifySocketToken } from './auth.js';
import {
  activeCallStatesFor,
  callStateFor,
  callSummaryText,
  canControlMic,
  joinCall,
  leaveAllCallsForSocket,
  leaveCall,
  refreshVideoTiers,
} from './calls.js';
import { finishCallCard, recordCallEvent, startCallCard } from './callCards.js';
import { CALL_DISCONNECT_GRACE_MS } from './callEvents.js';
import { findActiveDeviceForUser, touchDeviceLastSeen } from './db/queries/devices.js';
import { markMessageRead } from './db/queries/messages.js';
import {
  findRoomById,
  isRoomMember,
  listRoomMemberIds,
  listRoomsForUser,
  setMemberLastRead,
  setMemberLastReadAnnouncementAt,
} from './db/queries/rooms.js';
import { markRoomNotificationsRead } from './notifications.js';
import { postSystemMessage } from './rooms.js';
import { findSecretSessionByRoomId, insertSecretRekey, ackSecretRekey, bumpSecretSessionEpoch } from './db/queries/secretSessions.js';
import { findUserById } from './db/queries/users.js';
import { markConnected, markDisconnected } from './presence.js';
import { notifyIncomingCall, roomTagFor } from './push.js';
import { sendUserMessage } from './sendMessage.js';

/**
 * 서버 전체 통화 참가자 수가 바뀌어 화질 단계가 달라진 **다른** 통화들에 새 상태를 다시 알린다(callQuality.js) — 참가·
 * 퇴장한 그 방은 이미 바로 위에서 알렸다.
 */
function emitVideoTierChanges(io) {
  for (const state of refreshVideoTiers()) io.to(state.roomId).emit('call:state', state);
}

/**
 * 누가 통화에서 빠진 뒤 화상회의 카드(callCards.js)를 고친다 — 그 사람이 통화에서 완전히 빠졌으면(다른 기기로
 * 아직 들어와 있지 않으면) "나감"을 붙이고, 그걸로 통화가 끝났으면 카드를 닫는다. 카드가 없는 통화(서버 재시작
 * 전에 시작된 통화)가 끝나면 예전처럼 요약 한 줄을 시스템 메시지로 남긴다.
 */
async function postCallLeft(io, state, userId, wasIn) {
  if (wasIn && !state.participantIds.includes(userId)) {
    await recordCallEvent(io, state.roomId, userId, 'leave');
  }
  if (!state.ended) return;
  if (await finishCallCard(io, state.roomId, state.ended)) return;
  const room = await findRoomById(state.roomId);
  if (!room) return;
  const users = await Promise.all(state.ended.participantIds.map(findUserById));
  const names = users.filter(Boolean).map((u) => u.name ?? u.username ?? '알 수 없음');
  await postSystemMessage(io, room, callSummaryText(state.ended, names));
}

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

    // payload 모양과 규칙(보드 뷰는 게시글만, 읽기 전용·보관, 첨부, DM 되살리기, 푸시, 링크 미리보기)은
    // sendMessage.js의 sendUserMessage — 메시지 예약 발송(scheduledMessages.js)도 같은 함수로 보낸다.
    socket.on('message:send', async (payload, ack) => {
      if (!payload || typeof payload !== 'object') return;
      const result = await sendUserMessage({
        io,
        senderId: socket.data.userId,
        fallbackName: socket.data.username,
        payload,
      });
      ack?.(result);
    });

    // payload: { roomId } — 지금 이 방을 보고 있다는 뜻. 다른 멤버들이 안읽음 카운터를 갱신할 수 있도록 브로드캐스트한다.
    socket.on('room:read', async (payload) => {
      const room = await findRoomById(payload?.roomId);
      if (!room || !(await isRoomMember(room.id, socket.data.userId))) return;

      const lastReadAt = Date.now();
      await setMemberLastRead(room.id, socket.data.userId, lastReadAt);

      io.to(room.id).emit('room:read', { roomId: room.id, userId: socket.data.userId, lastReadAt });

      // 방을 보고 있으니 이 방의 멘션·보드 알림(그 시각 이전 것)도 읽은 걸로 — 다른 기기에는 notification:sync로 알린다.
      await markRoomNotificationsRead(io, socket.data.userId, room.id, lastReadAt).catch((err) =>
        console.error('[notifications] 자동 읽음 실패:', err?.message ?? err),
      );
    });

    // payload: { roomId } — 공지 목록/상세를 실제로 열었다는 뜻(room:read와 별개 —
    // announcements.js 주석 참고). 다른 사람들에겐 의미 없는 값이라 본인의 다른 기기만
    // 동기화되도록 user: 방에만 알린다(favorite/muted 등 개인 설정과 같은 방식).
    socket.on('announcement:read', async (payload) => {
      const room = await findRoomById(payload?.roomId);
      if (!room || !(await isRoomMember(room.id, socket.data.userId))) return;

      const lastReadAt = Date.now();
      await setMemberLastReadAnnouncementAt(room.id, socket.data.userId, lastReadAt);
      io.to(`user:${socket.data.userId}`).emit('announcement:read', { roomId: room.id, lastReadAt });
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
      const updated = await markMessageRead(payload.messageId, expiresAt, {
        roomId: room.id,
        readerId: socket.data.userId,
      });
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

    // ── 화상회의 신호 ──────────────────────────────────────────────────────
    // 미디어는 클라이언트와 LiveKit이 직접 주고받는다(calls.js) — 여기서는 "누가 통화를
    // 걸었고 지금 누가 들어와 있는지"만 방 멤버 전원에게 알린다. 벨이 울릴지/통화 화면을
    // 띄울지는 클라이언트가 이 상태를 보고 판단한다(참가자 목록에 내가 없고 통화가 막
    // 시작됐으면 수신 화면).

    // payload: { roomId } — LiveKit 연결에 성공한 직후 보낸다.
    socket.on('call:join', async (payload) => {
      const room = await findRoomById(payload?.roomId);
      if (!room || !(await isRoomMember(room.id, socket.data.userId))) return;
      // 이미 통화에 들어와 있던 사람(다른 기기, 또는 연결이 잠깐 끊겼다 다시 붙어 참여를 다시 알린 것)이면
      // 화상회의 카드에 "참여"를 다시 붙이지 않는다.
      const wasIn = callStateFor(room.id).participantIds.includes(socket.data.userId);
      const state = joinCall(room.id, socket.data.userId, socket.id);
      io.to(room.id).emit('call:state', state);
      emitVideoTierChanges(io);

      // 통화를 **막 시작한 경우에만** 앱이 꺼져 있는 멤버들에게 전화를 건다(참가자가 나
      // 혼자고 시작한 사람도 나). 중간에 누가 합류할 때마다 다시 울리면, 이미 안 받기로
      // 한 사람의 폰이 계속 울리게 된다.
      const isFirstParticipant =
        state.participantIds.length === 1 && state.startedBy === socket.data.userId;
      if (!wasIn) {
        // 통화를 막 시작했으면 대화방에 화상회의 카드를 새로 올리고, 합류면 그 카드에 "참여"를 붙인다.
        if (isFirstParticipant) await startCallCard(io, room, socket.data.userId);
        else await recordCallEvent(io, room.id, socket.data.userId, 'join');
      }
      if (wasIn || !isFirstParticipant) return;

      const [caller, memberIds] = await Promise.all([
        findUserById(socket.data.userId),
        listRoomMemberIds(room.id),
      ]);
      notifyIncomingCall({
        memberIds,
        callerId: socket.data.userId,
        caller,
        room,
        roomTag: roomTagFor(room),
      }).catch((err) => console.error('[push] 통화 알림 실패:', err?.message ?? err));
    });

    // payload: { roomId } — 통화 종료 버튼을 눌렀을 때.
    socket.on('call:leave', async (payload) => {
      const roomId = payload?.roomId;
      if (typeof roomId !== 'string') return;
      const wasIn = callStateFor(roomId).participantIds.includes(socket.data.userId);
      const state = leaveCall(roomId, socket.data.userId, socket.id);
      io.to(roomId).emit('call:state', state);
      emitVideoTierChanges(io);
      await postCallLeft(io, state, socket.data.userId, wasIn);
    });

    // payload: { roomId } — 걸려온 통화의 수신 창에서 [거절]을 눌렀을 때. 통화에 지금 들어와 있는 사람들
    // (건 사람 포함)의 기기에 누가 거절했는지 알린다 — 안 그러면 건 사람은 상대가 안 받는 건지 거절한
    // 건지 모른 채 계속 기다린다. 통화가 이미 끝났거나 거절한 사람이 이미 통화에 들어와 있으면(다른
    // 기기에서 받음) 알릴 게 없다.
    socket.on('call:decline', async (payload) => {
      const roomId = payload?.roomId;
      if (typeof roomId !== 'string') return;
      const state = callStateFor(roomId);
      const userId = socket.data.userId;
      if (!state.active || state.participantIds.includes(userId)) return;
      if (!(await isRoomMember(roomId, userId))) return;
      const user = await findUserById(userId);
      const event = { roomId, userId, name: user?.name ?? user?.username ?? '상대방' };
      for (const participantId of state.participantIds) {
        io.to(`user:${participantId}`).emit('call:declined', event);
      }
      await recordCallEvent(io, roomId, userId, 'decline');
    });

    // payload: { roomId, targetId, on } — 진행자가 참가자 패널에서 다른 사람의 마이크를 끄거나(on=false), 켜 달라고
    // 요청한다(on=true — 대상 앱이 [마이크 켜기]/[그대로 두기]를 묻고 본인이 수락해야 켜진다). 진행자인지·대상이 지금
    // 통화에 있는지는 여기서 확인하고(calls.js canControlMic), 대상의 기기들(user:<id>)에 그대로 전한다 — 마이크를
    // 실제로 켜고 끄는 건 대상 앱이 한다(LiveKit 트랙은 그 사람 기기의 것이라).
    socket.on('call:mic', (payload) => {
      const roomId = payload?.roomId;
      const targetId = payload?.targetId;
      if (typeof roomId !== 'string' || typeof targetId !== 'string' || typeof payload?.on !== 'boolean') return;
      if (!canControlMic(roomId, socket.data.userId, targetId)) return;
      io.to(`user:${targetId}`).emit('call:mic', { roomId, on: payload.on, byId: socket.data.userId });
    });

    socket.on('disconnect', () => {
      // 통화 중에 앱이 꺼지거나 네트워크가 끊기면 "나가기"를 보낼 새가 없다 — 소켓이
      // 끊긴 것으로 대신 정리해준다(안 하면 유령 참가자가 남아 통화가 영영 안 끝난다).
      // 잠깐 끊긴 것일 수 있어 조금 기다렸다 뺀다(callEvents.js의 CALL_DISCONNECT_GRACE_MS) — 그 사이 다시 붙어
      // 참여를 다시 알렸으면 새 소켓으로 이미 들어와 있어서, 여기서 옛 소켓만 빠지고 통화·기록은 그대로다.
      const userId = socket.data.userId;
      setTimeout(() => {
        for (const state of leaveAllCallsForSocket(userId, socket.id)) {
          io.to(state.roomId).emit('call:state', state);
          postCallLeft(io, state, userId, true).catch((err) =>
            console.error('[call] 통화 기록 남기기 실패:', err?.message ?? err),
          );
        }
        emitVideoTierChanges(io);
      }, CALL_DISCONNECT_GRACE_MS).unref();
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
      // 이미 진행 중인 통화가 있으면 방금 붙은 이 소켓에만 현재 상태를 한 번 흘려준다
      // (call:state는 변화 시점에만 나가므로 — calls.js의 activeCallStatesFor 참고).
      for (const state of activeCallStatesFor(rooms.map((r) => r.id))) {
        socket.emit('call:state', state);
      }
    });
  });
}
