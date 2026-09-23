import { randomUUID } from 'node:crypto';
import { verifySocketToken } from './auth.js';
import { activeCallStatesFor, callSummaryText, joinCall, leaveAllCallsForSocket, leaveCall } from './calls.js';
import { findActiveDeviceForUser, touchDeviceLastSeen } from './db/queries/devices.js';
import { findInquiryById } from './db/queries/inquiries.js';
import {
  insertMessage,
  insertMessageAttachments,
  markMessageRead,
  updateMessageLinkPreview,
} from './db/queries/messages.js';
import {
  findRoomById,
  isRoomMember,
  listRoomMemberIds,
  listRoomsForUser,
  setMemberLastRead,
  setMemberLastReadAnnouncementAt,
} from './db/queries/rooms.js';
import { extractFirstUrl, fetchLinkPreview } from './linkPreview.js';
import { postSystemMessage, unhideDmForOtherMembers } from './rooms.js';
import { findSecretSessionByRoomId, insertSecretRekey, ackSecretRekey, bumpSecretSessionEpoch } from './db/queries/secretSessions.js';
import { findUserById } from './db/queries/users.js';
import { toMessageDto } from './messages.js';
import { markConnected, markDisconnected } from './presence.js';
import { notifyIncomingCall, notifyOfflineMembers, roomTagFor } from './push.js';
import { resolveRawUrl } from './upload.js';

/**
 * 통화가 끝났으면(마지막 참가자가 나갔으면) 그 대화에 요약 한 줄을 시스템 메시지로 남긴다.
 * 녹화 대신 "언제 누가 얼마나 회의했는지"는 남기자는 결정(calls.js의 callSummaryText).
 */
async function postCallSummary(io, state) {
  if (!state.ended) return;
  const room = await findRoomById(state.roomId);
  if (!room) return;
  // 참여자 id만 들고 있으므로 여기서 이름으로 바꿔준다 — 통화가 끝나는 순간에만 도는
  // 경로라 인원수만큼 조회해도 부담이 없다.
  const users = await Promise.all(state.ended.participantIds.map(findUserById));
  const names = users
    .filter(Boolean)
    .map((u) => u.name ?? u.username ?? '알 수 없음');
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

      // "팀장에게 문의하기"로 보낸 메시지에만 채워진다(chat_input_bar.dart) — 내가 이 방에서
      // 보낸 실제 문의가 맞는지 확인해서, 엉뚱한 문의 id를 붙여 "문의함 바로가기"를 위조하는
      // 것을 막는다.
      let inquiryId = null;
      if (typeof payload.inquiryId === 'string') {
        const inquiry = await findInquiryById(payload.inquiryId);
        if (inquiry && inquiry.roomId === room.id && inquiry.senderId === socket.data.userId) {
          inquiryId = inquiry.id;
        }
      }

      // fileUrl/thumbnailUrl이 서명된 /files/<token> 형태로 오면(메시지 전달 — 클라이언트는
      // 원본이 아니라 서명된 다운로드 URL만 갖고 있다) 원본 상대경로로 되돌린다. 일반적인
      // 새 업로드는 이미 원본 경로라 그대로 통과한다(resolveRawUrl 참고).
      const fileUrl =
        typeof payload.fileUrl === 'string' ? resolveRawUrl(payload.fileUrl) : null;
      const thumbnailUrl =
        typeof payload.thumbnailUrl === 'string' ? resolveRawUrl(payload.thumbnailUrl) : null;

      // 사진 여러 장을 한 말풍선으로 보낼 때 — 첫 장은 messages의 파일 칸에도 그대로 넣는다
      // (파일 모아보기·검색·알림 미리보기가 아직 그 칸을 쓴다).
      const attachments = Array.isArray(payload.attachments)
        ? payload.attachments
            .filter((a) => a && typeof a.fileUrl === 'string')
            .slice(0, 20)
            .map((a) => ({
              kind: a.kind === 'file' ? 'file' : 'image',
              fileUrl: resolveRawUrl(a.fileUrl),
              fileName: typeof a.fileName === 'string' ? a.fileName : null,
              fileSize: typeof a.fileSize === 'number' ? a.fileSize : null,
              mimeType: typeof a.mimeType === 'string' ? a.mimeType : null,
              thumbnailUrl:
                typeof a.thumbnailUrl === 'string' ? resolveRawUrl(a.thumbnailUrl) : null,
            }))
        : [];
      const head = attachments[0];

      const message = await insertMessage({
        id: randomUUID(),
        roomId: room.id,
        senderId: socket.data.userId,
        senderName: sender?.name ?? sender?.username ?? socket.data.username,
        type: ['image', 'file', 'sticker'].includes(payload.type) ? payload.type : 'text',
        text: typeof payload.text === 'string' ? payload.text : null,
        fileUrl: head?.fileUrl ?? fileUrl,
        fileName:
          head?.fileName ?? (typeof payload.fileName === 'string' ? payload.fileName : null),
        fileSize:
          head?.fileSize ?? (typeof payload.fileSize === 'number' ? payload.fileSize : null),
        mimeType:
          head?.mimeType ?? (typeof payload.mimeType === 'string' ? payload.mimeType : null),
        thumbnailUrl: head?.thumbnailUrl ?? thumbnailUrl,
        quotedSenderName: typeof payload.quotedSenderName === 'string' ? payload.quotedSenderName : null,
        quotedPreview: typeof payload.quotedPreview === 'string' ? payload.quotedPreview : null,
        forwardedFromSenderName:
          typeof payload.forwardedFromSenderName === 'string' ? payload.forwardedFromSenderName : null,
        forwardedFromCreatedAt:
          typeof payload.forwardedFromCreatedAt === 'number' ? new Date(payload.forwardedFromCreatedAt) : null,
        isInquiryNotice: inquiryId != null,
        inquiryId,
      });

      // 첨부가 둘 이상이면 목록으로도 저장한다(하나뿐이면 예전처럼 messages 칸만으로 충분).
      if (attachments.length > 1) {
        message.attachments = await insertMessageAttachments(message.id, attachments);
      }

      // 평문 DM에서 상대가 이 방을 숨겨뒀으면(hidden) 자동으로 다시 보이게 한다 —
      // "숨기기"를 멤버십 변경 없이 구현한 결과라, 메시지가 갈 때마다 직접 확인해줘야 한다
      // (rooms.js unhideDmForOtherMembers 참고).
      await unhideDmForOtherMembers(io, room, socket.data.userId);

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
            sender,
            room,
            entry: message,
            roomTag: roomTagFor(room),
            kind: 'message',
          }),
        )
        .catch((err) => console.error('[push] message:send 알림 실패:', err?.message ?? err));

      // 링크 미리보기도 ack 이후 백그라운드로 — 외부 사이트를 긁어오는 거라 몇 초 걸릴 수
      // 있는데 메시지 전송 자체를 그만큼 늦출 이유가 없다. 비밀 대화는 서버가 내용을 아예
      // 못 봐야 하므로(암호문) 건너뛴다.
      if (!room.isSecret && message.type === 'text') {
        const url = extractFirstUrl(message.text);
        if (url) {
          fetchLinkPreview(url)
            .then(async (preview) => {
              if (!preview) return;
              const updated = await updateMessageLinkPreview(message.id, preview);
              io.to(room.id).emit('message:linkPreview', toMessageDto(updated));
            })
            .catch((err) => console.error('[linkPreview] 처리 실패:', err?.message ?? err));
        }
      }
    });

    // payload: { roomId } — 지금 이 방을 보고 있다는 뜻. 다른 멤버들이 안읽음 카운터를 갱신할 수 있도록 브로드캐스트한다.
    socket.on('room:read', async (payload) => {
      const room = await findRoomById(payload?.roomId);
      if (!room || !(await isRoomMember(room.id, socket.data.userId))) return;

      const lastReadAt = Date.now();
      await setMemberLastRead(room.id, socket.data.userId, lastReadAt);

      io.to(room.id).emit('room:read', { roomId: room.id, userId: socket.data.userId, lastReadAt });
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

    // ── 화상회의 신호 ──────────────────────────────────────────────────────
    // 미디어는 클라이언트와 LiveKit이 직접 주고받는다(calls.js) — 여기서는 "누가 통화를
    // 걸었고 지금 누가 들어와 있는지"만 방 멤버 전원에게 알린다. 벨이 울릴지/통화 화면을
    // 띄울지는 클라이언트가 이 상태를 보고 판단한다(참가자 목록에 내가 없고 통화가 막
    // 시작됐으면 수신 화면).

    // payload: { roomId } — LiveKit 연결에 성공한 직후 보낸다.
    socket.on('call:join', async (payload) => {
      const room = await findRoomById(payload?.roomId);
      if (!room || !(await isRoomMember(room.id, socket.data.userId))) return;
      const state = joinCall(room.id, socket.data.userId, socket.id);
      io.to(room.id).emit('call:state', state);

      // 통화를 **막 시작한 경우에만** 앱이 꺼져 있는 멤버들에게 전화를 건다(참가자가 나
      // 혼자고 시작한 사람도 나). 중간에 누가 합류할 때마다 다시 울리면, 이미 안 받기로
      // 한 사람의 폰이 계속 울리게 된다.
      const isFirstParticipant =
        state.participantIds.length === 1 && state.startedBy === socket.data.userId;
      if (!isFirstParticipant) return;

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
      const state = leaveCall(roomId, socket.data.userId, socket.id);
      io.to(roomId).emit('call:state', state);
      await postCallSummary(io, state);
    });

    socket.on('disconnect', () => {
      // 통화 중에 앱이 꺼지거나 네트워크가 끊기면 "나가기"를 보낼 새가 없다 — 소켓이
      // 끊긴 것으로 대신 정리해준다(안 하면 유령 참가자가 남아 통화가 영영 안 끝난다).
      for (const state of leaveAllCallsForSocket(socket.data.userId, socket.id)) {
        io.to(state.roomId).emit('call:state', state);
        postCallSummary(io, state).catch((err) =>
          console.error('[call] 통화 기록 남기기 실패:', err?.message ?? err),
        );
      }
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
