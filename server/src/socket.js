import { topicAccess } from './access.js';
import { verifySocketToken } from './auth.js';
import { accountState } from './authState.js';
import {
  admitCallJoin,
  callJoinProofLimitText,
  callJoinProofWait,
  emitVideoTierChanges,
  isRestrictedTopic,
} from './callAccess.js';
import {
  activeCallStatesFor,
  callStateFor,
  canControlMic,
  leaveAllCallsForSocket,
  leaveCall,
  livekitHasParticipant,
} from './calls.js';
import { postCallLeft, recordCallEvent, startCallCard } from './callCards.js';
import { CALL_DISCONNECT_GRACE_MS, CALL_HANDOFF_GRACE_MS } from './callEvents.js';
import { isSocketInCall, markCallDeclined } from './callState.js';
import { findActiveDeviceForUser, touchDeviceLastSeen } from './db/queries/devices.js';
import { touchUserLastSeen } from './db/queries/mentionDigest.js';
import { getNotificationSettingsMap } from './db/queries/notifications.js';
import { DEFAULT_NOTIFICATION_SETTINGS } from './notificationRules.js';
import { markMessageRead } from './db/queries/messages.js';
import {
  findRoomById,
  isRoomMember,
  listRoomMemberIds,
  listRoomsForUser,
  setMemberLastReadAnnouncementAt,
} from './db/queries/rooms.js';
import { markRoomRead } from './roomRead.js';
import { listCoTeamMemberIds } from './db/queries/teams.js';
import {
  findSecretSessionByRoomId,
  replaceSecretRekeyProposal,
  ackSecretRekey,
  bumpSecretSessionEpoch,
} from './db/queries/secretSessions.js';
import { findUserById } from './db/queries/users.js';
import { parseRekeyPayload, rekeyAckRelay, rekeyProposeRelay } from './secretContextRules.js';
import { messageRateLimitText, messageSendLimiter, sendCarriesFiles } from './messageLimits.js';
import { broadcastPresence, markConnected, markDisconnected, setDeviceBackground } from './presence.js';
import { notifyIncomingCall, roomTagFor } from './push.js';
import { sendUserMessage } from './sendMessage.js';
import { registerWikiSocket } from './wiki.js';

/**
 * 이 소켓의 계정을 아직 쓸 수 있는지 — 정지·탈퇴했거나, 전체 로그아웃·비밀번호 변경으로 토큰 버전이 올랐으면 false. 그런
 * 계정의 소켓은 보통 곧바로 끊기지만, 끊기기 전에 온 통화 신호(참가·거절·마이크 제어)도 받지 않는다. REST의 requireAuth와
 * 같은 상태를 본다(authState.js — 30초 캐시, 계정 상태가 바뀌면 바로 지워진다).
 */
async function socketAccountActive(socket) {
  const state = await accountState(socket.data.userId);
  return !state.blocked && state.tokenVersion === socket.data.tokenVersion;
}

const INACTIVE_ACCOUNT_ERROR = '계정을 확인할 수 없습니다. 다시 로그인해 주세요.';

/** 접속 상태가 바뀐 사람을 같은 팀 사람들에게만 알린다(presence.js broadcastPresence). 실패해도 연결 처리는 그대로. */
function announcePresence(io, userId) {
  broadcastPresence(io, userId, listCoTeamMemberIds).catch((err) =>
    console.error('[presence] 접속 상태 알림 실패:', err?.message ?? err),
  );
}

/** 소켓 연결 시 JWT를 확인하고, 연결된 이후의 채팅 이벤트를 처리합니다. */
export function registerSocket(io) {
  io.use(async (socket, next) => {
    try {
      const payload = await verifySocketToken(socket.handshake.auth?.token ?? '');
      socket.data.userId = payload.sub;
      socket.data.username = payload.username;
      // 연결 뒤에 토큰 버전이 오르면(전체 로그아웃·비밀번호 변경) 이 소켓의 통화 신호를 받지 않는다(socketAccountActive).
      socket.data.tokenVersion = payload.tokenVersion ?? 0;
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
      // "다른 기기 접속 중에도 푸시" 설정 — 접속해 있는 동안 푸시 대상을 고를 때 쓴다(presence.js skipsPush). 못 읽으면
      // 기본값(켬)으로 둔다 — 연결 자체를 막을 일은 아니다.
      socket.data.pushWhileOnline = await getNotificationSettingsMap([payload.sub])
        .then((m) => m.get(payload.sub)?.pushWhileOnline ?? DEFAULT_NOTIFICATION_SETTINGS.pushWhileOnline)
        .catch(() => DEFAULT_NOTIFICATION_SETTINGS.pushWhileOnline);
      next();
    } catch {
      next(new Error('unauthorized'));
    }
  });

  io.on('connection', (socket) => {
    // 같은 사람이 여러 기기로 동시에 붙어있을 수 있어서, 이 사람의 "첫" 연결일 때만
    // 온라인으로 알린다(presence.js가 기기별 연결 수를 센다). 받는 사람은 같은 팀 사람들뿐이다.
    const connected = markConnected(socket.data.userId, {
      deviceId: socket.data.deviceId ?? null,
      pushWhileOnline: socket.data.pushWhileOnline,
    });
    if (connected) announcePresence(io, socket.data.userId);
    // 마지막으로 앱이 붙어 있던 시각 — 오래 접속하지 않은 사람에게 멘션 요약 메일을 보내는 데 쓴다(mentionDigest.js).
    touchUserLastSeen(socket.data.userId).catch(() => {});

    // 개인용 룸(user:<id>)에 join해두면, REST로 방이 새로 생겼을 때
    // 이 소켓에 곧바로 join시켜줄 수 있습니다 (rooms.js의 notifyMembership 참고).
    socket.join(`user:${socket.data.userId}`);

    // 위키 동시 편집(wiki:join·wiki:op·wiki:cursor·wiki:leave — wiki.js).
    registerWikiSocket(io, socket);

    // payload 모양과 규칙(보드 뷰는 게시글만, 읽기 전용·보관, 첨부, 길이, 인용·전달 출처, DM 되살리기, 푸시, 링크 미리보기)은
    // sendMessage.js의 sendUserMessage — 메시지 예약 발송(scheduledMessages.js)도 같은 함수로 보낸다.
    socket.on('message:send', async (payload, ack) => {
      const reply = typeof ack === 'function' ? ack : () => {};
      if (!payload || typeof payload !== 'object') return reply({ ok: false, error: '메시지를 보내지 못했습니다.' });
      // 사람마다 보내기 횟수를 DB를 보기 전에 센다(messageLimits.js) — 예전엔 제한 없이 큰 메시지를 계속 보내 큰 토픽의 모든
      // 멤버에게 뿌릴 수 있었다. 정상 사용으로는 닿지 않는 넉넉한 값이다. 파일을 싣는 메시지는 10초 창에서 뺀다(비밀 대화는 고른
      // 파일마다 한 통씩 쉬지 않고 보낸다 — messageLimits.js MESSAGE_SEND_BURST).
      const wait = messageSendLimiter.hit(socket.data.userId, { burst: !sendCarriesFiles(payload) });
      if (wait > 0) return reply({ ok: false, error: messageRateLimitText(wait) });
      try {
        reply(
          await sendUserMessage({
            io,
            senderId: socket.data.userId,
            fallbackName: socket.data.username,
            payload,
          }),
        );
      } catch (err) {
        // DB 오류 등 — 응답을 안 보내면 앱은 15초를 기다린 뒤에야 "서버 응답이 없습니다"를 보여 준다.
        console.error('[socket] message:send 처리 실패:', err?.message ?? err);
        reply({ ok: false, error: '메시지를 보내지 못했습니다. 잠시 후 다시 시도하세요.' });
      }
    });

    // payload: { background } — 아이폰 앱이 뒤로 갔다/돌아왔다. 뒤에 있는 동안은 소켓이 붙어 있어도 이 기기로 푸시(APNs)를
    // 보낸다(presence.js pushesToDevice — iOS가 곧 앱을 멈춰 소켓 알림을 못 그린다). 인증된 기기의 소켓만 받는다.
    socket.on('app:background', (payload) => {
      if (!socket.data.deviceId || typeof payload?.background !== 'boolean') return;
      setDeviceBackground(socket.data.deviceId, payload.background);
    });

    // payload: { roomId } — 지금 이 방을 보고 있다는 뜻. 다른 멤버들이 안읽음 카운터를 갱신할 수 있도록 브로드캐스트한다.
    socket.on('room:read', async (payload) => {
      const room = await findRoomById(payload?.roomId);
      if (!room || !(await isRoomMember(room.id, socket.data.userId))) return;
      // 마지막 읽은 시각 + room:read 알림 + 이 방의 멘션·보드 알림 읽음(roomRead.js — 알림에서 바로 답장도 같은 함수).
      await markRoomRead(io, room.id, socket.data.userId);
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

    // 재키잉 제안/수락 중계(예전 규약 v1을 쓰는 예전 앱만 보낸다 — 새 앱은 재키잉을 하지 않고 응하지도 않는다) — 서버는
    // 공개키/서명만 보고 그대로 상대에게 전달할 뿐, 공유비밀 계산은 양쪽 클라이언트가 각자 로컬에서 한다. 맥락
    // 서명(ephemeralContextSignature)도 검증하지 않고 모양만 본 뒤 저장·전달한다 — 받는 앱이 상대 기기 키로 검증한다
    // (secretContextRules.js). 예전 앱은 안 보내서 null로 넘어간다.
    // payload: { roomId, keyEpoch, ephemeralPublicKey, ephemeralSignature, ephemeralContextSignature? }
    socket.on('secret:rekey-propose', async (payload) => {
      // 모양이 틀린 payload(맥락 서명 모양이 틀린 것 포함)는 DB를 보기 전에 버린다.
      const rekey = parseRekeyPayload(payload);
      if (!rekey) return;
      const room = await findRoomById(rekey.roomId);
      if (!room || !room.isSecret || !(await isRoomMember(room.id, socket.data.userId))) return;

      // 수락을 못 받은 예전 앱은 메시지마다 다시 제안한다 — 같은 epoch의 대기 중인 제안은 바꿔 적는다(행이 쌓이지 않게).
      await replaceSecretRekeyProposal({
        roomId: room.id,
        keyEpoch: rekey.keyEpoch,
        proposerUserId: socket.data.userId,
        proposerEphemeralPublicKey: rekey.ephemeralPublicKey,
        proposerEphemeralSignature: rekey.ephemeralSignature,
        proposerContextSignature: rekey.contextSignature,
      });
      socket.to(room.id).emit('secret:rekey-propose', rekeyProposeRelay(room.id, socket.data.userId, rekey));
    });

    // payload: { roomId, keyEpoch, ephemeralPublicKey, ephemeralSignature, ephemeralContextSignature? }
    socket.on('secret:rekey-ack', async (payload) => {
      const rekey = parseRekeyPayload(payload);
      if (!rekey) return;
      const room = await findRoomById(rekey.roomId);
      if (!room || !room.isSecret || !(await isRoomMember(room.id, socket.data.userId))) return;

      await ackSecretRekey(room.id, rekey.keyEpoch, {
        responderEphemeralPublicKey: rekey.ephemeralPublicKey,
        responderEphemeralSignature: rekey.ephemeralSignature,
        responderContextSignature: rekey.contextSignature,
      });
      await bumpSecretSessionEpoch(room.id, rekey.keyEpoch);
      io.to(room.id).emit('secret:rekey-ack', rekeyAckRelay(room.id, socket.data.userId, rekey));
    });

    // ── 화상회의 신호 ──────────────────────────────────────────────────────
    // 미디어는 클라이언트와 LiveKit이 직접 주고받는다(calls.js) — 여기서는 "누가 통화를
    // 걸었고 지금 누가 들어와 있는지"만 방 멤버 전원에게 알린다. 벨이 울릴지/통화 화면을
    // 띄울지는 클라이언트가 이 상태를 보고 판단한다(참가자 목록에 내가 없고 통화가 막
    // 시작됐으면 수신 화면).

    // 이 소켓이 "다른 기기로 넘어감"으로 나간 통화들 — roomId → 잠시 뒤 이 소켓을 그 통화에서 빼는 타이머(call:leave handoff).
    const handoffTimers = new Map();
    const cancelHandoff = (roomId) => {
      clearTimeout(handoffTimers.get(roomId));
      handoffTimers.delete(roomId);
    };

    /**
     * 이 소켓을 [roomId] 통화에서 뺀다(나가기 버튼·연결이 아주 끊김·다른 기기로 넘어간 뒤 그 기기가 안 옴). 이 소켓이 그 통화에
     * 없으면(이미 빠졌거나 다른 기기의 참여가 이 자리를 대신했으면) 아무것도 안 한다 — 바뀐 게 없는데 방 전체에 상태를 다시
     * 보내지 않게.
     */
    async function leaveCallFromSocket(roomId) {
      const userId = socket.data.userId;
      if (!isSocketInCall(roomId, userId, socket.id)) return;
      const state = leaveCall(roomId, userId, socket.id);
      io.to(roomId).emit('call:state', state);
      emitVideoTierChanges(io);
      await postCallLeft(io, state, userId, true);
    }

    // payload: { roomId } — LiveKit 연결에 성공한 직후, 그리고 통화 중에 소켓이 다시 붙을 때마다(client session.dart
    // _reannounceCall) 보낸다. call:join은 토큰 없이도 보낼 수 있어서 토큰 발급(calls.js)과 같은 규칙을 여기서 다시 건다 —
    // 예전엔 방 멤버이기만 하면 비밀 대화·읽기 전용 토픽에서도, 미디어 연결 없이도 call:join/call:leave를 되풀이해 대화에
    // 카드를 쌓고 방 전원에게 전화를 계속 울릴 수 있었다. 규칙은 callAccess.js.
    // ack(앱이 원하면): { ok: true } 또는 { ok: false, error } — 거절되면 앱이 LiveKit 연결을 끊고 안내한다.
    socket.on('call:join', async (payload, ack) => {
      const reply = typeof ack === 'function' ? ack : () => {};
      const userId = socket.data.userId;
      const roomId = payload?.roomId;
      if (typeof roomId !== 'string') return reply({ ok: false, error: '방을 찾을 수 없습니다.' });
      // LiveKit 연결로 확인해야 하는 시도(통화에 없고 쓸 수 있는 토큰도 없음)는 DB를 보기 전에 센다 — 되풀이해 보내 DB 조회와
      // LiveKit 요청을 계속 일으키거나, 미디어는 붙여 둔 채 나가기·참여를 되풀이해 카드와 방 전체 알림을 쌓지 못하게.
      const proofWait = callJoinProofWait(userId, roomId);
      if (proofWait > 0) return reply({ ok: false, error: callJoinProofLimitText(proofWait) });
      const room = await findRoomById(roomId);
      if (!room || !(await isRoomMember(room.id, userId))) {
        return reply({ ok: false, error: '이 방의 멤버가 아닙니다.' });
      }
      if (!(await socketAccountActive(socket))) return reply({ ok: false, error: INACTIVE_ACCOUNT_ERROR });
      // 읽기 전용·보관된 토픽은 토픽 관리자만 통화를 시작할 수 있다 — "시작"인지는 참가 직전에 보지만(admitCallJoin) 권한
      // 조회는 DB가 필요해서, 그런 토픽일 때만 미리 해 둔다.
      const canManage = isRestrictedTopic(room) ? (await topicAccess(room, userId)).canManage : true;
      // 방 종류·참가 자격(토큰·통화 상태·LiveKit 연결)·시작 규칙(읽기 전용·횟수)을 보고, 받아들이면 통화 상태에 넣는다.
      const admitted = await admitCallJoin({
        room,
        userId,
        socketId: socket.id,
        canManage,
        livekitHas: livekitHasParticipant,
      });
      if (!admitted.ok) return reply({ ok: false, error: admitted.error });
      // 이 기기가 "다른 기기로 넘어감"으로 나갔다가 다시 들어왔으면 잠시 뒤 빼기로 한 것을 거둔다.
      cancelHandoff(room.id);
      // 이미 통화에 들어와 있던 사람(다른 기기, 또는 연결이 잠깐 끊겼다 다시 붙어 참여를 다시 알린 것)이면
      // 화상회의 카드에 "참여"를 다시 붙이지 않는다.
      const { state, wasIn, restored } = admitted;
      reply({ ok: true });
      io.to(room.id).emit('call:state', state);
      emitVideoTierChanges(io);
      // 서버가 잃었던 통화를 LiveKit 연결로 되살린 것이면(서버 재시작 뒤, 혼자 남아 있다가 오래 끊긴 뒤) 새 카드도 전화도
      // 없다 — 그 회의는 처음 시작할 때 이미 카드가 올라가고 전화가 울렸다(callAccess.js admitCallJoin). 되살린 통화에는
      // 카드가 없어 합류도 카드에 남지 않는다.
      if (wasIn || restored) return;

      // 통화를 **막 시작한 경우에만** 앱이 꺼져 있는 멤버들에게 전화를 건다(참가자가 나
      // 혼자고 시작한 사람도 나). 중간에 누가 합류할 때마다 다시 울리면, 이미 안 받기로
      // 한 사람의 폰이 계속 울리게 된다.
      const isFirstParticipant = state.participantIds.length === 1 && state.startedBy === userId;
      // 통화를 막 시작했으면 대화방에 화상회의 카드를 새로 올리고, 합류면 그 카드에 "참여"를 붙인다.
      if (!isFirstParticipant) {
        await recordCallEvent(io, room.id, userId, 'join');
        return;
      }
      await startCallCard(io, room, userId);

      const [caller, memberIds] = await Promise.all([findUserById(userId), listRoomMemberIds(room.id)]);
      notifyIncomingCall({
        memberIds,
        callerId: userId,
        caller,
        room,
        roomTag: roomTagFor(room),
      }).catch((err) => console.error('[push] 통화 알림 실패:', err?.message ?? err));
    });

    // payload: { roomId, handoff? } — 통화 종료 버튼을 눌렀을 때, 그리고 LiveKit 연결이 이 기기 밖의 이유로 끝났을 때(client
    // session.dart). handoff: true는 같은 계정이 다른 기기에서 이 통화에 들어가 LiveKit이 이 기기를 끊은 것(duplicateIdentity)
    // — 그 기기의 call:join이 곧 와서 이 소켓 자리를 대신하므로(callState.js joinCall) 바로 빼지 않고 잠시 기다린다. 바로
    // 빼면 그 사이 그 사람이 통화에서 빠진 것으로 정리돼 진행자가 넘어가고, 카드에 나감·참여가 남고, 혼자였으면 통화가
    // 끝났다가 다시 시작되며 모두에게 전화가 다시 울린다(callEvents.js CALL_HANDOFF_GRACE_MS).
    socket.on('call:leave', async (payload) => {
      const roomId = payload?.roomId;
      if (typeof roomId !== 'string') return;
      cancelHandoff(roomId);
      if (payload?.handoff === true) {
        // 이 소켓이 들어가 있는 통화에만 타이머를 건다(아무 방 id나 보내 타이머를 쌓지 못하게).
        if (!isSocketInCall(roomId, socket.data.userId, socket.id)) return;
        const timer = setTimeout(() => {
          handoffTimers.delete(roomId);
          leaveCallFromSocket(roomId).catch((err) => console.error('[call] 통화 기록 남기기 실패:', err?.message ?? err));
        }, CALL_HANDOFF_GRACE_MS);
        handoffTimers.set(roomId, timer.unref());
        return;
      }
      await leaveCallFromSocket(roomId);
    });

    // payload: { roomId } — 걸려온 통화의 수신 창에서 [거절]을 눌렀을 때. 통화에 지금 들어와 있는 사람들
    // (건 사람 포함)의 기기에 누가 거절했는지 알린다 — 안 그러면 건 사람은 상대가 안 받는 건지 거절한
    // 건지 모른 채 계속 기다린다. 통화가 이미 끝났거나 거절한 사람이 이미 통화에 들어와 있으면(다른
    // 기기에서 받음) 알릴 게 없다.
    socket.on('call:decline', async (payload) => {
      const roomId = payload?.roomId;
      if (typeof roomId !== 'string') return;
      const userId = socket.data.userId;
      // 거절은 한 통화에 한 번만 알린다 — 같은 계정의 다른 기기에서 또 거절했거나 되풀이해 보내도 건 사람에게 다시 알리지도,
      // 카드에 다시 쌓지도 않는다(예전엔 되풀이해 보내 카드에 사건을 상한까지 채울 수 있었다). DB를 보기 전에 메모리에서 거른다.
      const { startedAt } = callStateFor(roomId);
      if (!markCallDeclined(roomId, userId)) return;
      if (!(await isRoomMember(roomId, userId)) || !(await socketAccountActive(socket))) return;
      // 그사이 통화가 끝났거나(다른 통화로 바뀜) 거절한 사람이 다른 기기에서 받았으면 알릴 게 없다.
      const state = callStateFor(roomId);
      if (!state.active || state.startedAt !== startedAt || state.participantIds.includes(userId)) return;
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
    socket.on('call:mic', async (payload) => {
      const roomId = payload?.roomId;
      const targetId = payload?.targetId;
      const userId = socket.data.userId;
      if (typeof roomId !== 'string' || typeof targetId !== 'string' || typeof payload?.on !== 'boolean') return;
      if (!canControlMic(roomId, userId, targetId)) return;
      // 진행자 표시는 메모리 상태라, 방에서 내보내졌거나 계정이 정지된 진행자가 끊기기 전 소켓으로 남의 마이크를 계속 끄지
      // 못하게 멤버십·계정을 다시 본다(보통은 내보낼 때 통화 상태에서도 빠져 진행자가 넘어간다 — callAccess.js).
      if (!(await isRoomMember(roomId, userId)) || !(await socketAccountActive(socket))) return;
      if (!canControlMic(roomId, userId, targetId)) return; // 그사이 진행자가 바뀌었을 수 있다.
      io.to(`user:${targetId}`).emit('call:mic', { roomId, on: payload.on, byId: userId });
    });

    socket.on('disconnect', () => {
      // 통화 중에 앱이 꺼지거나 네트워크가 끊기면 "나가기"를 보낼 새가 없다 — 소켓이
      // 끊긴 것으로 대신 정리해준다(안 하면 유령 참가자가 남아 통화가 영영 안 끝난다).
      // 잠깐 끊긴 것일 수 있어 조금 기다렸다 뺀다(callEvents.js의 CALL_DISCONNECT_GRACE_MS) — 그 사이 다시 붙어
      // 참여를 다시 알렸으면 새 소켓으로 이미 들어와 있어서, 여기서 옛 소켓만 빠지고 통화·기록은 그대로다.
      const userId = socket.data.userId;
      // 다른 기기로 넘어가며 잠시 뒤 빼기로 한 통화도 아래 끊김 정리가 같이 뺀다.
      for (const timer of handoffTimers.values()) clearTimeout(timer);
      handoffTimers.clear();
      setTimeout(() => {
        for (const state of leaveAllCallsForSocket(userId, socket.id)) {
          io.to(state.roomId).emit('call:state', state);
          postCallLeft(io, state, userId, true).catch((err) =>
            console.error('[call] 통화 기록 남기기 실패:', err?.message ?? err),
          );
        }
        emitVideoTierChanges(io);
      }, CALL_DISCONNECT_GRACE_MS).unref();
      // 이 사람의 "마지막" 연결이 끊겼을 때만 오프라인으로 알린다(같은 팀 사람들에게만). 그때 마지막 접속 시각도 적는다 —
      // 며칠씩 붙어 있다 끊긴 경우에도 끊긴 때부터 센다.
      if (markDisconnected(socket.data.userId, socket.data.deviceId ?? null)) {
        announcePresence(io, socket.data.userId);
        touchUserLastSeen(socket.data.userId).catch(() => {});
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
