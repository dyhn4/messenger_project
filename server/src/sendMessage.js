import { randomUUID } from 'node:crypto';
import { findInquiryById } from './db/queries/inquiries.js';
import { insertMessage, insertMessageAttachments, updateMessageLinkPreview } from './db/queries/messages.js';
import { findRoomById, isRoomMember, listRoomMemberIds } from './db/queries/rooms.js';
import { findUserById } from './db/queries/users.js';
import { extractFirstUrl, fetchLinkPreview } from './linkPreview.js';
import { topicAccess } from './access.js';
import { MESSAGE_ATTACHMENT_MAX, parsePostFields, POST_ATTACHMENT_MAX, topicWriteDenial } from './permissions.js';
import { unhideDmForOtherMembers } from './rooms.js';
import { toMessageDto } from './messages.js';
import { notifyOfflineMembers, roomTagFor } from './push.js';
import { resolveRawUrl } from './upload.js';
import { sanitizeTextFormat } from './textFormat.js';

/**
 * 사람이 보내는 메시지 한 건을 저장하고 방에 알린다 — 소켓 message:send(socket.js)와 메시지 예약 발송
 * (scheduledMessages.js)이 규칙(보드 뷰는 게시글만, 읽기 전용·보관, 첨부 개수, DM 되살리기, 브로드캐스트,
 * 푸시, 링크 미리보기)을 한 벌로 쓰도록 여기 모았다. 결과는 소켓 ack와 같은 모양이다 — 보냈으면
 * `{ ok: true, message }`(방에 뿌린 DTO), 거절이면 `{ ok: false, error }`.
 *
 * [room]을 주면(예약 발송이 방금 읽어 둔 방) 다시 찾지 않지만, 멤버인지는 항상 다시 본다.
 * [fallbackName]은 보낸 사람 이름을 못 찾았을 때 쓸 이름(소켓은 토큰의 username).
 *
 * payload: { roomId, type: 'text'|'image'|'file'|'sticker', text?, textFormat?, fileUrl?, fileName?, fileSize?,
 *   mimeType?, thumbnailUrl?, attachments?, quotedSenderName?, quotedPreview?, forwardedFromSenderName?,
 *   forwardedFromCreatedAt?, inquiryId? }
 * (quoted*는 "메시지 공유", forwardedFrom*는 "메시지 전달"에서 쓴다 — room_list_screen.dart의
 * 메시지 롱프레스 메뉴, message_share_screen.dart/message_forward_screen.dart 참고.)
 * 보드 뷰 게시글: { roomId, type: 'post', title, text, textFormat?, attachments? } — 보드 뷰 토픽은
 * 게시글만, 그 밖의 방은 게시글을 받지 않는다.
 */
export async function sendUserMessage({ io, senderId, payload, room: knownRoom = null, fallbackName = null }) {
  const room = knownRoom ?? (await findRoomById(payload.roomId));
  if (!room || !(await isRoomMember(room.id, senderId))) {
    return { ok: false, error: '이 방의 멤버가 아닙니다.' };
  }

  const isPost = payload.type === 'post';
  const isBoard = room.type === 'topic' && room.viewMode === 'board';
  if (isBoard && !isPost) {
    return { ok: false, error: '보드 뷰 토픽에는 게시글만 올릴 수 있습니다.' };
  }
  if (!isBoard && isPost) {
    return { ok: false, error: '게시글은 보드 뷰 토픽에서만 올릴 수 있습니다.' };
  }
  // 읽기 전용·보관된 토픽은 토픽을 관리할 수 있는 사람만 쓴다. 대부분의 방은 해당이 없어서
  // 그때만 권한을 조회한다(메시지마다 조회가 늘지 않게).
  if (room.type === 'topic' && (room.readOnly || room.archivedAt)) {
    const denial = topicWriteDenial({ room, canManage: (await topicAccess(room, senderId)).canManage });
    if (denial) {
      return { ok: false, error: denial };
    }
  }
  let post = null;
  if (isPost) {
    post = parsePostFields(payload.title, payload.text);
    if (post.error) {
      return { ok: false, error: post.error };
    }
  }

  const sender = await findUserById(senderId);

  // "팀장에게 문의하기"로 보낸 메시지에만 채워진다(chat_input_bar.dart) — 내가 이 방에서
  // 보낸 실제 문의가 맞는지 확인해서, 엉뚱한 문의 id를 붙여 "문의함 바로가기"를 위조하는
  // 것을 막는다.
  let inquiryId = null;
  if (typeof payload.inquiryId === 'string') {
    const inquiry = await findInquiryById(payload.inquiryId);
    if (inquiry && inquiry.roomId === room.id && inquiry.senderId === senderId) {
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
  // (파일 모아보기·검색·알림 미리보기가 아직 그 칸을 쓴다). 게시글은 30개까지 — 넘으면 조용히
  // 자르지 않고 거절한다(게시글 편집기가 이미 30개로 막으므로 넘어왔다면 파일이 빠진 채 올라가면 안 됨).
  const validAttachments = Array.isArray(payload.attachments)
    ? payload.attachments.filter((a) => a && typeof a.fileUrl === 'string')
    : [];
  if (isPost && validAttachments.length > POST_ATTACHMENT_MAX) {
    return { ok: false, error: `첨부 파일은 ${POST_ATTACHMENT_MAX}개까지 올릴 수 있습니다.` };
  }
  const attachments = validAttachments
    .slice(0, isPost ? POST_ATTACHMENT_MAX : MESSAGE_ATTACHMENT_MAX)
    .map((a) => ({
      kind: a.kind === 'file' ? 'file' : 'image',
      fileUrl: resolveRawUrl(a.fileUrl),
      fileName: typeof a.fileName === 'string' ? a.fileName : null,
      fileSize: typeof a.fileSize === 'number' ? a.fileSize : null,
      mimeType: typeof a.mimeType === 'string' ? a.mimeType : null,
      thumbnailUrl:
        typeof a.thumbnailUrl === 'string' ? resolveRawUrl(a.thumbnailUrl) : null,
    }))
    // 만료·위조된 서명 링크는 원본 경로로 못 되돌린다(null) — message_attachments.file_url은
    // 비울 수 없어서 저장 전에 뺀다(게시글은 첨부가 하나여도 그 표에 저장한다).
    .filter((a) => a.fileUrl);
  const head = attachments[0];

  // 게시글은 제목·본문(앞뒤 공백 뺀 값)과 첨부 목록만 쓴다 — 단일 파일 칸(fileUrl 등)·인용·전달
  // 값은 일반 메시지 전용이라 무시한다.
  const message = await insertMessage({
    id: randomUUID(),
    roomId: room.id,
    senderId,
    senderName: sender?.name ?? sender?.username ?? fallbackName,
    type: isPost ? 'post' : ['image', 'file', 'sticker'].includes(payload.type) ? payload.type : 'text',
    title: post?.title ?? null,
    text: post ? post.text : typeof payload.text === 'string' ? payload.text : null,
    textFormat: post
      ? sanitizeTextFormat(payload.textFormat, post.text)
      : room.isSecret || typeof payload.text !== 'string'
        ? null
        : sanitizeTextFormat(payload.textFormat, payload.text),
    fileUrl: head?.fileUrl ?? (post ? null : fileUrl),
    fileName:
      head?.fileName ?? (!post && typeof payload.fileName === 'string' ? payload.fileName : null),
    fileSize:
      head?.fileSize ?? (!post && typeof payload.fileSize === 'number' ? payload.fileSize : null),
    mimeType:
      head?.mimeType ?? (!post && typeof payload.mimeType === 'string' ? payload.mimeType : null),
    thumbnailUrl: head?.thumbnailUrl ?? (post ? null : thumbnailUrl),
    quotedSenderName: !post && typeof payload.quotedSenderName === 'string' ? payload.quotedSenderName : null,
    quotedPreview: !post && typeof payload.quotedPreview === 'string' ? payload.quotedPreview : null,
    forwardedFromSenderName:
      !post && typeof payload.forwardedFromSenderName === 'string' ? payload.forwardedFromSenderName : null,
    forwardedFromCreatedAt:
      !post && typeof payload.forwardedFromCreatedAt === 'number' ? new Date(payload.forwardedFromCreatedAt) : null,
    isInquiryNotice: inquiryId != null,
    inquiryId,
  });

  // 첨부가 둘 이상이면 목록으로도 저장한다(하나뿐이면 예전처럼 messages 칸만으로 충분). 게시글은
  // 하나여도 목록으로 저장한다 — toMessageDto의 예전 방식(파일 칸 하나 = 첨부 하나)은
  // 'image'/'file' 메시지에만 적용되기 때문이다.
  if (attachments.length > 1 || (post && attachments.length > 0)) {
    message.attachments = await insertMessageAttachments(message.id, attachments);
  }

  // 평문 DM에서 상대가 이 방을 숨겨뒀으면(hidden) 자동으로 다시 보이게 한다 —
  // "숨기기"를 멤버십 변경 없이 구현한 결과라, 메시지가 갈 때마다 직접 확인해줘야 한다
  // (rooms.js unhideDmForOtherMembers 참고).
  await unhideDmForOtherMembers(io, room, senderId);

  // 서명은 toMessageDto 안에서 실시간으로만 이뤄진다 — DB에는 항상 원본을 유지해서
  // 나중에 다시 조회될 때도 그때 시점 기준으로 새로 서명할 수 있게 한다.
  const broadcastMessage = toMessageDto(message);
  io.to(room.id).emit('message:new', broadcastMessage);

  // 응답(소켓 ack 등)을 기다리게 하지 않도록 백그라운드로 보낸다 — 실패해도(토큰 만료 등)
  // notifyOfflineMembers 내부에서 개별적으로 처리되고 메시지 전송 자체엔 영향 없다.
  listRoomMemberIds(room.id)
    .then((memberIds) =>
      notifyOfflineMembers({
        memberIds,
        senderId,
        senderName: message.senderName,
        sender,
        room,
        entry: message,
        roomTag: roomTagFor(room),
        kind: 'message',
      }),
    )
    .catch((err) => console.error('[push] message:send 알림 실패:', err?.message ?? err));

  // 링크 미리보기도 백그라운드로 — 외부 사이트를 긁어오는 거라 몇 초 걸릴 수 있는데 메시지
  // 전송 자체를 그만큼 늦출 이유가 없다. 비밀 대화는 서버가 내용을 아예 못 봐야 하므로(암호문)
  // 건너뛴다.
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

  return { ok: true, message: broadcastMessage };
}
