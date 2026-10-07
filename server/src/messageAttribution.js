// "메시지 공유"(인용 카드)·"메시지 전달"(전달 표시)의 출처를 DB에서 읽어 확인하고 저장할 칸을 채운다 — 규칙은 quoteForwardRules.js,
// 부르는 곳은 sendMessage.js. 앱이 보낸 이름·미리보기·시각 글은 쓰지 않는다.
import { findAnnouncementById } from './db/queries/announcements.js';
import { findCommentById } from './db/queries/comments.js';
import { findMessageById, listAttachmentsForMessages } from './db/queries/messages.js';
import { findRoomById, getDmHistoryFloor, isRoomMember } from './db/queries/rooms.js';
import { findUserById } from './db/queries/users.js';
import { isUuid } from './favoritesRules.js';
import { attributionRequest, decideAttribution, EMPTY_ATTRIBUTION, sourceFilePaths } from './quoteForwardRules.js';

const defaultLoaders = {
  findAnnouncementById,
  findCommentById,
  findMessageById,
  listAttachmentsForMessages,
  findRoomById,
  getDmHistoryFloor,
  isRoomMember,
  findUserById,
};

/**
 * [id](메시지 또는 댓글 — 앱은 댓글도 같은 화면으로 공유·전달하고 그 댓글 id를 보낸다)를 [userId]가 지금 읽을 수 있으면 규칙이 쓰는
 * 모양으로, 아니면 null. 읽을 수 있다는 것은 메시지 한 건 조회(GET /messages/:id·/comments/:id)와 같다: 지우지 않았고, 그 방의
 * 멤버이고, 1:1에서 "진짜 나가기" 이전 글이 아니다(댓글은 부모 메시지의 시각으로 본다). 비밀 대화의 글도 돌려준다(roomIsSecret) —
 * 거절할지는 규칙이 정한다.
 */
export async function loadReadableSource(id, userId, loaders = defaultLoaders) {
  if (!isUuid(id) || !userId) return null;
  const message = await loaders.findMessageById(id);
  const comment = message ? null : await loaders.findCommentById(id);
  const row = message ?? comment;
  if (!row || row.deletedAt) return null;
  const room = await loaders.findRoomById(row.roomId);
  if (!room || !(await loaders.isRoomMember(room.id, userId))) return null;
  if (room.type === 'dm') {
    const floor = await loaders.getDmHistoryFloor(room.id, userId);
    if (floor) {
      const anchor = message ?? (await loaders.findMessageById(comment.messageId));
      if (!anchor || new Date(anchor.createdAt) < new Date(floor)) return null;
    }
  }
  const kind = message ? 'message' : 'comment';
  const attachments = message ? ((await loaders.listAttachmentsForMessages([message.id]))[message.id] ?? []) : [];
  // 보낸 사람은 지금 이름으로(앱도 말풍선에 박제된 이름보다 지금 이름을 먼저 썼다 — message_bubble.dart displayName).
  const author = row.senderId ? await loaders.findUserById(row.senderId) : null;
  return {
    kind,
    type: row.type,
    text: row.text ?? null,
    title: message?.title ?? null,
    fileName: row.fileName ?? null,
    createdAt: row.createdAt,
    senderName: author?.name ?? author?.username ?? row.senderName ?? null,
    roomIsSecret: !!room.isSecret,
    filePaths: sourceFilePaths({ kind, row, attachments }),
  };
}

/** 공지 [id]를 [userId]가 지금 읽을 수 있으면(그 토픽의 멤버, 지우지 않은 공지) 그 행, 아니면 null. */
export async function loadReadableAnnouncement(id, userId, loaders = defaultLoaders) {
  if (!isUuid(id) || !userId) return null;
  const announcement = await loaders.findAnnouncementById(id);
  if (!announcement || announcement.deletedAt) return null;
  return (await loaders.isRoomMember(announcement.roomId, userId)) ? announcement : null;
}

/**
 * message:send의 인용·전달 칸 — `{ ok: true, fields }`(messages에 넣을 quotedSenderName·quotedPreview·forwardedFromSenderName·
 * forwardedFromCreatedAt) 또는 `{ ok: false, error }`. [room]은 보내는 방, [sent]는 { text(보낸 글), filePaths(실은 파일의 저장
 * 경로들) }. 출처 요청이 없으면 DB를 읽지 않는다.
 */
export async function resolveAttribution({ payload, senderId, room, sent }, loaders = defaultLoaders) {
  const request = attributionRequest(payload);
  if (!request.quote && !request.forward) return { ok: true, fields: { ...EMPTY_ATTRIBUTION } };
  const targetIsSecret = !!room?.isSecret;
  // 비밀 대화로 보내는 글에는 어차피 싣지 않는다 — 출처를 읽을 필요도 없다.
  if (targetIsSecret) return decideAttribution({ request, targetIsSecret, sent });

  const quote = request.quote;
  const [quoteSource, announcement] = await Promise.all([
    quote?.kind === 'message' ? loadReadableSource(quote.id, senderId, loaders) : null,
    quote?.kind === 'announcement' ? loadReadableAnnouncement(quote.id, senderId, loaders) : null,
  ]);
  const forwardSource =
    request.forward == null
      ? null
      : quote?.kind === 'message' && quote.id === request.forward.id
        ? quoteSource
        : await loadReadableSource(request.forward.id, senderId, loaders);
  return decideAttribution({ request, targetIsSecret, quoteSource, announcement, forwardSource, sent });
}
