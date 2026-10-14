import { Router } from 'express';
import { findMessageById } from './db/queries/messages.js';
import { listReactionsForMessages, removeReaction, setReaction } from './db/queries/reactions.js';
import { findRoomById, getDmHistoryFloor, isRoomMember } from './db/queries/rooms.js';
import { isUuid } from './favoritesRules.js';
import { isReactionEmoji, reactionDenial, REACTION_EMOJIS, summarizeReactions } from './reactionRules.js';

/**
 * 메시지 공감(이모지 반응) — 규칙은 reactionRules.js. 공감 목록은 사람마다 다르지 않은 값([{ emoji, userIds }])이라 메시지
 * DTO에 그대로 싣고(toMessageDto의 reactions — 목록을 내려주는 곳이 [attachReactions]로 미리 붙인다), 바뀌면 방 전체에
 * message:reactions로 알린다. "내가 눌렀는지"는 앱이 userIds에 내 id가 있는지로 본다. 공감은 알림을 보내지 않는다.
 */

/**
 * 메시지 행들에 `reactions`(요약 — 없으면 빈 목록)를 붙여 돌려준다. 지워진 메시지는 조회하지 않는다(toMessageDto가 빈 목록으로
 * 내린다). toMessageDto가 동기 함수라 목록을 내려주는 곳이 DTO로 바꾸기 전에 한 번 부른다(attachPolls와 같은 방식). 이걸 거치지
 * 않은 DTO(수정·링크 미리보기 브로드캐스트 등)에는 reactions 키가 없다 — 앱은 그때 가진 공감을 그대로 둔다.
 */
export async function attachReactions(messageRows) {
  const ids = messageRows.filter((m) => !m.deletedAt).map((m) => m.id);
  const summary = summarizeReactions(await listReactionsForMessages(ids));
  return messageRows.map((m) => ({ ...m, reactions: summary.get(m.id) ?? [] }));
}

/** 메시지 한 건의 공감 요약. */
async function reactionsOf(messageId) {
  return summarizeReactions(await listReactionsForMessages([messageId])).get(messageId) ?? [];
}

export function createReactionsRouter(io) {
  const router = Router();

  /**
   * 내 공감을 정한다 — { emoji: '👍' }이면 그것으로(이미 다른 것이면 바꾼다), { emoji: null }이면 뺀다. 같은 값을 다시 보내도
   * 결과는 같다(앱이 "같은 것을 다시 누르면 빼기"를 판단해 null을 보낸다 — 연달아 눌러 요청이 겹쳐도 엇갈리지 않게). 바뀐 공감
   * 목록을 돌려주고 방 전체에 message:reactions로 알린다.
   */
  router.put('/messages/:id/reaction', async (req, res) => {
    const emoji = req.body?.emoji ?? null;
    if (emoji !== null && !isReactionEmoji(emoji)) {
      return res.status(400).json({ error: `공감은 ${REACTION_EMOJIS.join(' ')} 중에서 고르세요.` });
    }
    const message = isUuid(req.params.id) ? await findMessageById(req.params.id) : null;
    const room = message ? await findRoomById(message.roomId) : null;
    const isMember = room ? await isRoomMember(room.id, req.user.sub) : false;
    const floor = room?.type === 'dm' && isMember ? await getDmHistoryFloor(room.id, req.user.sub) : null;
    const denial = reactionDenial({ message, room, isMember, floor });
    if (denial) return res.status(denial.status).json({ error: denial.error });

    if (emoji) await setReaction(message.id, req.user.sub, emoji);
    else await removeReaction(message.id, req.user.sub);

    const reactions = await reactionsOf(message.id);
    io.to(message.roomId).emit('message:reactions', { roomId: message.roomId, messageId: message.id, reactions });
    res.json({ messageId: message.id, reactions });
  });

  return router;
}
