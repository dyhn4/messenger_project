/**
 * 메시지 공감(이모지 반응)의 규칙 — DB를 모르게 둬서 시험하기 쉽게 했다(reactions.js가 DB·소켓과 잇는다).
 *
 * 카카오톡 공감처럼 고를 수 있는 이모지를 몇 개로 정해 두고, 한 사람이 한 메시지에 하나만 고른다. 아무 이모지나 받으면
 * 글자 수·보이지 않는 글자·조합 이모지를 따로 걸러야 하고, 화면도 반응 줄이 끝없이 길어진다. 이 목록의 순서가 화면에 보이는
 * 순서다 — 고르는 줄과 말풍선 아래 줄이 늘 같은 자리에 같은 이모지를 둔다(클라이언트 message_reactions.dart의 목록과 같이 맞춘다).
 */
export const REACTION_EMOJIS = Object.freeze(['👍', '❤️', '😂', '😮', '😢', '✅']);

export function isReactionEmoji(value) {
  return typeof value === 'string' && REACTION_EMOJIS.includes(value);
}

/**
 * 공감 행들([{ messageId, userId, emoji }] — 누른 순서)을 메시지별 요약으로 — `Map<messageId, [{ emoji, userIds }]>`.
 * 이모지는 REACTION_EMOJIS 순서, 사람은 누른 순서. 목록에 없는 이모지(예전에 받던 것 등)는 뺀다. 아무도 안 누른 메시지는
 * 맵에 없다(받는 쪽이 빈 목록으로 본다).
 */
export function summarizeReactions(rows) {
  const byMessage = new Map();
  for (const row of rows) {
    if (!isReactionEmoji(row.emoji)) continue;
    let byEmoji = byMessage.get(row.messageId);
    if (!byEmoji) {
      byEmoji = new Map();
      byMessage.set(row.messageId, byEmoji);
    }
    const users = byEmoji.get(row.emoji) ?? [];
    users.push(row.userId);
    byEmoji.set(row.emoji, users);
  }
  const result = new Map();
  for (const [messageId, byEmoji] of byMessage) {
    result.set(
      messageId,
      REACTION_EMOJIS.filter((e) => byEmoji.has(e)).map((emoji) => ({ emoji, userIds: byEmoji.get(emoji) })),
    );
  }
  return result;
}

/**
 * 이 메시지에 공감할 수 없는 이유 — 되면 null. [message]는 메시지 행, [room]은 그 방, [isMember]는 요청한 사람이 그 방 멤버인지,
 * [floor]는 DM "진짜 나가기" 이력(그 이전 메시지는 그 사람에게 없는 것과 같다). 응답 코드와 문구를 { status, error }로 준다 —
 * 메시지 한 건 조회(messages.js GET /messages/:id)와 같은 규칙으로 없는 것처럼 보일 것은 404.
 */
export function reactionDenial({ message, room, isMember, floor = null }) {
  const notFound = { status: 404, error: '메시지를 찾을 수 없습니다.' };
  if (!message || message.deletedAt || !room) return notFound;
  if (!isMember) return { status: 403, error: '이 방의 멤버가 아닙니다.' };
  if (floor && message.createdAt < floor) return notFound;
  if (room.isSecret) return { status: 400, error: '비밀 대화에서는 공감을 남길 수 없습니다.' };
  if (message.type === 'system') return { status: 400, error: '이 메시지에는 공감을 남길 수 없습니다.' };
  return null;
}
