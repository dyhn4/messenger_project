import { randomUUID } from 'node:crypto';
import { Router } from 'express';
import { findActiveDeviceForUser } from './db/queries/devices.js';
import { deleteRoom, findDmRoomByKey, insertRoom } from './db/queries/rooms.js';
import {
  acceptSecretSession,
  findSecretSessionByRoomId,
  insertSecretSession,
  setSecretSessionSelfDestruct,
} from './db/queries/secretSessions.js';
import { addRoomMembers, findRoomById, isRoomMember, listRoomMemberIds } from './db/queries/rooms.js';
import { findUserById } from './db/queries/users.js';
import { notifySecretChatInvite } from './push.js';
import { dmKeyFor, notifyMembership, postSystemMessage, toRoomDto } from './rooms.js';

const MIN_SELF_DESTRUCT_SECONDS = 1;
const MAX_SELF_DESTRUCT_SECONDS = 7 * 24 * 60 * 60; // 1주.

// self_destruct_picker_dialog.dart의 프리셋과 동일한 라벨 — 시스템 메시지 문구를 그
// 다이얼로그에서 고른 표현 그대로 보여주기 위함. 프리셋에 없는 값(이론상 REST로 임의의
// 초 단위를 보낼 수 있음)은 "N초"로 대체 표기한다.
const SELF_DESTRUCT_LABELS = new Map([
  [1, '1초'],
  [5, '5초'],
  [30, '30초'],
  [60, '1분'],
  [5 * 60, '5분'],
  [60 * 60, '1시간'],
  [24 * 60 * 60, '1일'],
  [7 * 24 * 60 * 60, '1주'],
]);

function formatSelfDestructDuration(seconds) {
  return SELF_DESTRUCT_LABELS.get(seconds) ?? `${seconds}초`;
}

/** POST 본문의 deviceId가 정말 이 로그인 유저 소유이고 폐기되지 않았는지 확인한다.
 * 소켓 인증(socket.js)과 동일한 검사를 REST 쪽에서도 반복한다 — JWT는 deviceId를 모르므로. */
async function requireOwnDevice(req, res, deviceId) {
  if (!deviceId || typeof deviceId !== 'string') {
    res.status(400).json({ error: 'deviceId가 필요합니다.' });
    return null;
  }
  const device = await findActiveDeviceForUser(deviceId, req.user.sub);
  if (!device) {
    res.status(403).json({ error: '등록되지 않았거나 폐기된 기기입니다.' });
    return null;
  }
  return device;
}

export function createSecretChatsRouter(io) {
  const router = Router();

  router.post('/secret-chats', async (req, res) => {
    const { targetUserId, initiatorEphemeralPublicKey, initiatorEphemeralSignature, deviceId } = req.body ?? {};
    const device = await requireOwnDevice(req, res, deviceId);
    if (!device) return;
    if (!targetUserId || targetUserId === req.user.sub) {
      return res.status(400).json({ error: '대상 사용자가 올바르지 않습니다.' });
    }
    if (!initiatorEphemeralPublicKey || !initiatorEphemeralSignature) {
      return res.status(400).json({ error: '임시 공개키/서명이 필요합니다.' });
    }
    const target = await findUserById(targetUserId);
    if (!target) return res.status(404).json({ error: '대상 사용자를 찾을 수 없습니다.' });

    // 비밀 대화는 평문 DM과 별도의 방으로 취급한다(dmKey에 'secret:' 접두사를 붙여 평문
    // DM과 절대 같은 방으로 합쳐지지 않게 한다).
    const dmKey = `secret:${dmKeyFor(req.user.sub, targetUserId)}`;
    const existing = await findDmRoomByKey(dmKey);
    if (existing) {
      const session = await findSecretSessionByRoomId(existing.id);
      if (session && session.status !== 'rejected' && session.status !== 'terminated') {
        return res.status(200).json(await toRoomDto(existing, req.user.sub));
      }
      // 거절되었거나(reject 핸들러가 방을 지우지 못한 과거 데이터 등) 세션이 없는 낡은 방이
      // dmKey를 붙들고 있으면, 그대로 두고 새로 insert하면 dmKey unique 제약에 걸려 서버가
      // 죽는다(실제로 발생했던 장애) — 새로 시작하기 전에 낡은 방을 먼저 지운다.
      await deleteRoom(existing.id);
    }

    const room = await insertRoom({
      id: randomUUID(),
      type: 'dm',
      name: null,
      dmKey,
      createdBy: req.user.sub,
      isSecret: true,
    });
    await addRoomMembers(room.id, [req.user.sub, targetUserId]);
    await insertSecretSession({
      roomId: room.id,
      initiatorUserId: req.user.sub,
      initiatorDeviceId: device.id,
      responderUserId: targetUserId,
      initiatorEphemeralPublicKey,
      initiatorEphemeralSignature,
    });
    await notifyMembership(io, room);
    io.to(`user:${targetUserId}`).emit('secret:invite', {
      roomId: room.id,
      initiatorUserId: req.user.sub,
      initiatorDeviceId: device.id,
      initiatorEphemeralPublicKey,
      initiatorEphemeralSignature,
    });
    // system 타입은 클라이언트가 복호화를 아예 안 건드리므로(decryptInPlace 참고) 비밀
    // 대화에도 평문 시스템 메시지를 그대로 써도 된다 — 아래 세 System 메시지(요청/수락/
    // 상대만 나가기) 전부 같은 이유로 안전하다.
    await postSystemMessage(io, room, '비밀대화 요청을 보냈습니다. 상대방이 수락할 때까지 대기 중');
    const initiator = await findUserById(req.user.sub);
    notifySecretChatInvite({ targetUserId, initiator, roomId: room.id }).catch((err) =>
      console.error('[push] 비밀대화 요청 알림 실패:', err?.message ?? err),
    );
    res.status(201).json(await toRoomDto(room, req.user.sub));
  });

  /**
   * 응답자가 초대를 받았을 때 앱이 꺼져있어서(FCM만 받음) secret:invite 소켓 이벤트를
   * 놓친 경우, 수락/거절에 필요한 정보(초대자의 임시 공개키+서명)를 다시 가져온다.
   * client/lib/services/session.dart의 ensurePendingSecretInvite 참고.
   */
  router.get('/secret-chats/:roomId/invite', async (req, res) => {
    const room = await findRoomById(req.params.roomId);
    if (!room || !room.isSecret) return res.status(404).json({ error: '비밀 대화를 찾을 수 없습니다.' });
    const session = await findSecretSessionByRoomId(room.id);
    if (!session || session.status !== 'pending') {
      return res.status(404).json({ error: '대기 중인 초대가 없습니다.' });
    }
    if (session.responderUserId !== req.user.sub) {
      return res.status(403).json({ error: '이 요청을 볼 수 없습니다.' });
    }
    res.json({
      roomId: room.id,
      initiatorUserId: session.initiatorUserId,
      initiatorDeviceId: session.initiatorDeviceId,
      initiatorEphemeralPublicKey: session.initiatorEphemeralPublicKey,
      initiatorEphemeralSignature: session.initiatorEphemeralSignature,
    });
  });

  router.post('/secret-chats/:roomId/accept', async (req, res) => {
    const { responderEphemeralPublicKey, responderEphemeralSignature, deviceId } = req.body ?? {};
    const device = await requireOwnDevice(req, res, deviceId);
    if (!device) return;
    const room = await findRoomById(req.params.roomId);
    if (!room || !room.isSecret) return res.status(404).json({ error: '비밀 대화를 찾을 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    if (!responderEphemeralPublicKey || !responderEphemeralSignature) {
      return res.status(400).json({ error: '임시 공개키/서명이 필요합니다.' });
    }

    const session = await acceptSecretSession(room.id, {
      responderDeviceId: device.id,
      responderEphemeralPublicKey,
      responderEphemeralSignature,
    });
    io.to(room.id).emit('secret:accepted', {
      roomId: room.id,
      responderDeviceId: device.id,
      responderEphemeralPublicKey,
      responderEphemeralSignature,
    });
    await postSystemMessage(io, room, '비밀대화가 시작되었습니다');
    res.json({ ok: true, session: { status: session.status, keyEpoch: session.keyEpoch } });
  });

  router.post('/secret-chats/:roomId/reject', async (req, res) => {
    const room = await findRoomById(req.params.roomId);
    if (!room || !room.isSecret) return res.status(404).json({ error: '비밀 대화를 찾을 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });

    // 아직 메시지가 없는 상태(핸드셰이크 중)라 방 자체를 완전히 지운다 — dmKey를 비워둬야
    // 나중에 같은 상대에게 다시 비밀 대화를 걸 수 있다(안 지우면 unique 제약 위반으로 서버가
    // 죽는 실제 장애가 있었다).
    io.to(room.id).emit('secret:rejected', { roomId: room.id });
    const memberIds = await listRoomMemberIds(room.id);
    io.in(memberIds.map((id) => `user:${id}`)).socketsLeave(room.id);
    await deleteRoom(room.id);
    res.json({ ok: true });
  });

  router.patch('/secret-chats/:roomId/settings', async (req, res) => {
    const room = await findRoomById(req.params.roomId);
    if (!room || !room.isSecret) return res.status(404).json({ error: '비밀 대화를 찾을 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });

    const raw = req.body?.selfDestructSeconds;
    let seconds = null;
    if (raw !== null && raw !== undefined) {
      seconds = Number(raw);
      if (!Number.isInteger(seconds) || seconds < MIN_SELF_DESTRUCT_SECONDS || seconds > MAX_SELF_DESTRUCT_SECONDS) {
        return res.status(400).json({ error: '자동 삭제 시간은 1초~1주 사이여야 합니다.' });
      }
    }

    await setSecretSessionSelfDestruct(room.id, seconds);
    io.to(room.id).emit('secret:settings', { roomId: room.id, selfDestructSeconds: seconds });
    // 자동 삭제 시간 자체는 서버가 이미 평문으로 들고 있는 값(secretSessions.selfDestructSeconds,
    // 만료 스윕에 필요)이라 시스템 메시지에 그대로 적어도 E2EE를 해치지 않는다. 시스템
    // 메시지는(postSystemMessage) 애초에 암호화되지 않은 평문으로 저장/전송되는데, 클라이언트의
    // decryptInPlace가 MessageType.system은 건너뛰도록 되어 있어야 "복호화할 수 없습니다"로
    // 안 보인다.
    const text = seconds != null
      ? `메시지가 ${formatSelfDestructDuration(seconds)} 이후에 자동삭제가 되도록 설정했습니다.`
      : '자동삭제 타이머를 비활성화 했습니다.';
    await postSystemMessage(io, room, text);
    res.json({ ok: true, selfDestructSeconds: seconds });
  });

  return router;
}
