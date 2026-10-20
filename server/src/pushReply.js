import { Router } from 'express';
import { accessPayload } from './auth.js';
import { accountState, deviceActive } from './authState.js';
import { JWT_SECRET } from './config.js';
import { findRoomById } from './db/queries/rooms.js';
import { messageRateLimitText, messageSendLimiter } from './messageLimits.js';
import { verifyReplyTicket } from './pushReplyRules.js';
import { markRoomRead } from './roomRead.js';
import { sendUserMessage } from './sendMessage.js';

/**
 * 알림에서 바로 답장 `POST /api/push-reply { text, ticket? | roomId?, clientId? }` — 안드로이드 알림의 "답장" 칸에 쓴 글을 그 방에 보낸다
 * (client main.dart의 알림 답장 핸들러). 로그인 토큰 없이 부를 수 있게 앱 토큰 묶음(/api — requireAuth)보다 먼저 건다:
 *  - **ticket**: 채팅 푸시에 실려 온 답장 표(pushReplyRules.js) — 그 사람·방·기기에 묶여 있다. 서명·기한과 함께 그 사람이 지금도 로그인할 수
 *    있는지(정지·탈퇴·비밀번호 변경 — 토큰 버전)와 그 기기가 아직 로그인돼 있는지 본다.
 *  - **roomId + Authorization**: 앱이 켜져 있는 동안 소켓으로 받아 앱이 그린 알림(표가 없다) — 평소 AccessToken으로.
 * 보내기는 소켓의 `message:send`와 같은 함수·같은 횟수 제한(sendMessage.js sendUserMessage — 멤버·읽기 전용·보관·길이)이고, 비밀 대화는
 * 400(암호화할 수 없다). 보냈으면 그 방을 읽은 것으로 한다(roomRead.js). 응답 201 `{ id }`.
 */
export function createPushReplyRouter(io) {
  const router = Router();
  router.post('/api/push-reply', async (req, res) => {
    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    if (!text) return res.status(400).json({ error: '보낼 글을 넣으세요.' });
    let userId;
    let roomId;
    if (typeof req.body?.ticket === 'string') {
      const ticket = verifyReplyTicket(JWT_SECRET, req.body.ticket);
      if (!ticket) return res.status(401).json({ error: '답장할 수 있는 시간이 지났습니다. 앱을 열어 보내세요.' });
      const state = await accountState(ticket.userId);
      if (state.blocked || state.tokenVersion !== ticket.tokenVersion || !(await deviceActive(ticket.deviceId, ticket.userId))) {
        return res.status(401).json({ error: '다시 로그인한 뒤 앱에서 보내세요.' });
      }
      userId = ticket.userId;
      roomId = ticket.roomId;
    } else {
      const payload = await accessPayload(req);
      if (!payload) return res.status(401).json({ error: '토큰이 유효하지 않습니다.' });
      userId = payload.sub;
      roomId = typeof req.body?.roomId === 'string' ? req.body.roomId : null;
    }
    const wait = messageSendLimiter.hit(userId, { burst: true });
    if (wait > 0) return res.status(429).json({ error: messageRateLimitText(wait) });
    const room = roomId ? await findRoomById(roomId) : null;
    if (!room) return res.status(404).json({ error: '대화방을 찾을 수 없습니다.' });
    if (room.isSecret) return res.status(400).json({ error: '비밀 대화는 알림에서 답장할 수 없습니다. 앱을 열어 보내세요.' });
    try {
      const result = await sendUserMessage({
        io,
        senderId: userId,
        room,
        payload: { roomId: room.id, type: 'text', text, clientId: req.body?.clientId },
      });
      if (!result.ok) return res.status(result.status ?? 400).json({ error: result.error });
      await markRoomRead(io, room.id, userId);
      res.status(201).json({ id: result.message.id });
    } catch (err) {
      console.error('[push-reply] 답장 보내기 실패:', err?.message ?? err);
      res.status(500).json({ error: '메시지를 보내지 못했습니다. 잠시 후 다시 시도하세요.' });
    }
  });
  return router;
}
