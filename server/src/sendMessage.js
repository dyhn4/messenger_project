import { randomUUID } from 'node:crypto';
import { findInquiryById } from './db/queries/inquiries.js';
import {
  findMessageByClientId,
  insertMessage,
  insertMessageWithAttachments,
  listAttachmentsForMessages,
  updateMessageLinkPreview,
} from './db/queries/messages.js';
import { insertPollMessage } from './db/queries/polls.js';
import { findRoomById, isRoomMember, listRoomMemberIds } from './db/queries/rooms.js';
import { findUserById } from './db/queries/users.js';
import { extractFirstUrl, fetchLinkPreview } from './linkPreview.js';
import { storePreviewImage } from './linkPreviewImage.js';
import { topicAccess } from './access.js';
import { isUuid } from './favoritesRules.js';
import { checkFileRefs, storedFilesAllowed } from './fileRefs.js';
import { resolveAttribution } from './messageAttribution.js';
import {
  fileFieldsDenial,
  messageTextDenial,
  postBytesDenial,
  sanitizeFileSize,
  SECRET_TEXT_MAX,
  TEXT_TOO_LONG_ERROR,
} from './messageLimits.js';
import { MESSAGE_ATTACHMENT_MAX, parsePostFields, POST_ATTACHMENT_MAX, topicWriteDenial } from './permissions.js';
import { isClientIdConflict, parseClientId } from './outboxRules.js';
import { EMPTY_ATTRIBUTION } from './quoteForwardRules.js';
import { unhideDmForOtherMembers } from './rooms.js';
import { toMessageDto } from './messages.js';
import { mentionsToStore, sanitizeMentions } from './notificationRules.js';
import { notifyBoard, notifyMentions } from './notifications.js';
import { toPollDto } from './polls.js';
import { notifyOfflineMembers, roomTagFor } from './push.js';
import { sanitizeTextFormat } from './textFormat.js';

/** 같은 임시 id로 이미 만든 메시지가 있으면 그 응답(다시 방송하지 않는다 — 처음 보낼 때 이미 갔다). 없으면 null. */
async function duplicateReply(senderId, clientId, roomId) {
  const existing = await findMessageByClientId(senderId, clientId);
  if (!existing) return null;
  if (existing.roomId !== roomId) return { ok: false, error: '메시지를 보내지 못했습니다. 다시 시도하세요.' };
  const byMessage = await listAttachmentsForMessages([existing.id]);
  return { ok: true, duplicate: true, message: toMessageDto({ ...existing, attachments: byMessage[existing.id] }) };
}

/** 예약 메시지에 저장해 둔 첨부를 보낼 수 없을 때(발송 실패 이유로 목록에 보인다). */
const STORED_ATTACHMENT_ERROR = '첨부 파일을 확인할 수 없어 보내지 못했습니다. 파일을 다시 올려 예약하세요.';

/**
 * 저장할 첨부인지 — 파일 경로(빈 값이 아닌 문자열)가 있는 항목만. 빈 문자열은 "첨부 없음"이라 예전처럼 뺀다: 남겨 두면 저장할
 * 경로가 없어 message_attachments.file_url(비울 수 없다)에서 DB 오류가 났다.
 */
export function isSentAttachment(a) {
  return a != null && typeof a === 'object' && typeof a.fileUrl === 'string' && a.fileUrl !== '';
}

/**
 * 이 메시지가 실제로 저장할 파일 참조들(문자열) — 카드형(게시글·투표)은 첨부 목록만, 그 밖은 파일 칸·미리보기 칸과 첨부 목록.
 * [attachments]는 isSentAttachment로 거른 목록이다.
 */
function sentFileRefs(payload, attachments, isRich) {
  const refs = isRich ? [] : [payload.fileUrl, payload.thumbnailUrl];
  for (const a of attachments) refs.push(a.fileUrl, a.thumbnailUrl);
  return refs.filter((r) => typeof r === 'string' && r !== '');
}

/**
 * [refs]를 저장할 경로로 바꾼다 — [fileSource]에 따라 확인 방법이 다르다:
 *  - 'client'(기본 — 소켓 message:send·투표 만들기): 앱이 보낸 값. 직접 올린 파일·지금 볼 수 있는 방의 파일만(fileRefs.js). 비밀
 *    대화는 직접 올린 파일만 — 자동 삭제(secretExpiry.js)가 첨부 파일을 실제로 지우기 때문이다(예전엔 남의 파일 링크를 실어 보내
 *    그 파일을 지우게 할 수 있었다). 비밀 대화 앱은 보낼 때마다 암호화한 파일을 방금 새로 올려 그 경로를 싣고, 전달·공유로는 비밀
 *    대화에 보낼 수 없어서(방 고르기에서 빠진다) 정상 사용에는 걸리지 않는다.
 *  - 'server': 서버가 DB에서 읽어 이미 권한을 확인한 경로(앨범 항목 공유 — albums.js) — 그대로.
 *  - 'stored': 서버가 저장해 둔 예약 메시지의 경로 — 올린 사람 기록이 있으면 보내는 사람의 파일이어야 한다(fileRefs.js storedFilesAllowed
 *    — 기록이 없는 옛 파일은 예약할 때 확인할 길이 없었으므로 예전처럼 보낸다).
 * 결과: `{ ok: true, pathOf(ref) }` 또는 `{ ok: false, error }`.
 */
async function resolveSentFiles(refs, { fileSource, senderId, secret }) {
  if (fileSource === 'server') return { ok: true, pathOf: (ref) => ref };
  if (fileSource === 'stored') {
    return (await storedFilesAllowed(refs, { senderId }))
      ? { ok: true, pathOf: (ref) => ref }
      : { ok: false, error: STORED_ATTACHMENT_ERROR };
  }
  const checked = await checkFileRefs(refs, { senderId, ownedOnly: secret });
  return checked.ok ? { ok: true, pathOf: (ref) => checked.paths.get(ref) ?? null } : checked;
}

/** 보낼 수 있는 길이인지 — 글(종류마다 다르다)·게시글 제목·파일 이름·형식. 받을 수 있으면 null, 아니면 거절 문구. */
function sizeDenial(payload, { room, isPost, isPoll, attachments }) {
  if (!isPoll) {
    const textDenial = isPost
      ? postBytesDenial(payload.title, payload.text)
      : messageTextDenial(payload.text, {
          secret: !!room.isSecret,
          sticker: payload.type === 'sticker',
        });
    if (textDenial) return textDenial;
  }
  for (const fields of isPost || isPoll ? attachments : [payload, ...attachments]) {
    const denial = fileFieldsDenial(fields);
    if (denial) return denial;
  }
  return null;
}

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
 *   mimeType?, thumbnailUrl?, attachments?, quotedMessageId?, quotedAnnouncementId?, forwardedFromMessageId?, inquiryId? }
 * (quoted*는 "메시지 공유"(메시지·댓글 또는 공지 인용), forwardedFromMessageId는 "메시지 전달"에서 쓴다 — message_share_screen.dart·
 * message_forward_screen.dart·announcement_detail_screen.dart 참고. 인용 카드의 이름·미리보기와 전달 표시의 이름·시각은 서버가 그
 * 원본에서 채운다(messageAttribution.js) — 예전 앱이 보내는 quotedSenderName·quotedPreview·forwardedFromSenderName·
 * forwardedFromCreatedAt 글은 쓰지 않는다: id 없는 공유는 업데이트 안내로 거절하고, id 없는 전달은 전달 표시만 뺀다.)
 * 파일 칸(fileUrl·thumbnailUrl·attachments)은 직접 올린 파일이나 지금 볼 수 있는 방의 파일만 받는다(fileRefs.js — [fileSource] 참고).
 * 글·이름·형식의 길이 상한은 messageLimits.js.
 * 보드 뷰 게시글: { roomId, type: 'post', title, text, textFormat?, attachments? } — 보드 뷰 토픽은
 * 게시글만(투표 제외), 그 밖의 방은 게시글을 받지 않는다.
 * 멘션: text/post에 mentions?: [{type:'user',userId,s,e} | {type:'all',s,e}] — 방 멤버만·구간 검사 등은
 * notificationRules.js의 sanitizeMentions가 걸러 저장하고, 저장 뒤 notifications.js가 알림 기록·푸시를 만든다.
 * 투표: { roomId, type: 'poll', attachments? } + [poll]({ title, description, optionTexts, anonymous, multiple,
 * closesAt } — polls.js의 parsePollFields가 검사한 값). 투표는 REST(POST /rooms/:roomId/polls)로만 만든다 —
 * 소켓 message:send는 [poll]을 넘길 수 없어서 type:'poll'을 거절한다. 첨부는 보드 뷰 토픽의 투표만 30개까지.
 * 거절 결과에는 REST 응답용 [status]가 붙을 수 있다(소켓 ack에서는 무시된다).
 * 앨범 공유: [albumShare]({ albumId, title, teamName } — albums.js POST /albums/:id/messages가 검사한 값)를 주면
 * 글 메시지에 앨범 카드(messages.album_id·album_share)를 붙인다. 소켓 payload로는 넘길 수 없다.
 * 할 일 카드: [todoShare]({ todoId, card } — todos.js가 할 일을 만들 때 todoRules.js todoCardMessage로 만든 값)를 주면
 * 글 메시지에 할 일 카드(messages.todo_id·todo_card)를 붙인다. 소켓 payload로는 넘길 수 없다.
 * [notifyOnly](userId 배열)를 주면 일반 메시지 알림(푸시)을 그 사람들에게만 보내고, 방송하는 메시지에도 실어 앱이 다른
 * 사람에게는 알림을 띄우지 않게 한다(메시지는 모두에게 보이고 안읽음도 는다 — 할 일 생성 창 "대화방에 알리기"를 끈 카드).
 * 멘션 알림은 그대로 간다.
 * [fileSource]는 파일 칸 값이 어디서 왔는지 — 'client'(앱이 보낸 값, 기본), 'server'(서버가 권한을 확인하고 DB에서 읽은 경로 —
 * 앨범 항목 공유), 'stored'(예약 메시지에 저장해 둔 경로). resolveSentFiles 참고.
 */
export async function sendUserMessage({
  io,
  senderId,
  payload,
  room: knownRoom = null,
  fallbackName = null,
  poll = null,
  albumShare = null,
  todoShare = null,
  notifyOnly = null,
  fileSource = 'client',
}) {
  // 어느 방이든 받을 수 없는 길이(비밀 대화의 암호문 상한보다 긴 글)는 DB를 보기 전에 거른다. 방에 맞는 상한은 아래 sizeDenial.
  if (typeof payload.text === 'string' && payload.text.length > SECRET_TEXT_MAX) {
    return { ok: false, error: TEXT_TOO_LONG_ERROR };
  }
  const room = knownRoom ?? (typeof payload.roomId === 'string' ? await findRoomById(payload.roomId) : null);
  if (!room || !(await isRoomMember(room.id, senderId))) {
    return { ok: false, error: '이 방의 멤버가 아닙니다.', status: 403 };
  }
  // 보내기 대기열이 다시 보낸 메시지(응답을 못 받았을 뿐 처음 것이 이미 들어갔을 수 있다) — 앱이 보낸 것만 본다.
  const clientId = fileSource === 'client' ? parseClientId(payload.clientId) : null;
  if (clientId) {
    const duplicate = await duplicateReply(senderId, clientId, room.id);
    if (duplicate) return duplicate;
  }

  const isPost = payload.type === 'post';
  const isPoll = poll != null;
  if (payload.type === 'poll' && !isPoll) {
    return { ok: false, error: '투표는 투표 만들기로만 올릴 수 있습니다.' };
  }
  if (isPoll && room.isSecret) {
    return { ok: false, error: '비밀 대화에서는 투표를 만들 수 없습니다.' };
  }
  // 게시글과 투표는 본문 대신 제목·첨부 목록을 쓰는 "카드형" 메시지다(단일 파일 칸·인용·전달 값은 무시).
  const isRich = isPost || isPoll;
  const isBoard = room.type === 'topic' && room.viewMode === 'board';
  if (isBoard && !isPost && !isPoll) {
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
      return { ok: false, error: denial, status: 403 };
    }
  }
  let post = null;
  if (isPost) {
    post = parsePostFields(payload.title, payload.text);
    if (post.error) {
      return { ok: false, error: post.error };
    }
  }

  // 사진 여러 장을 한 말풍선으로 보낼 때 — 첫 장은 messages의 파일 칸에도 그대로 넣는다
  // (파일 모아보기·검색·알림 미리보기가 아직 그 칸을 쓴다). 게시글은 30개까지 — 넘으면 조용히
  // 자르지 않고 거절한다(게시글 편집기가 이미 30개로 막으므로 넘어왔다면 파일이 빠진 채 올라가면 안 됨).
  const validAttachments = Array.isArray(payload.attachments) ? payload.attachments.filter(isSentAttachment) : [];
  if (isPoll && !isBoard && validAttachments.length > 0) {
    return { ok: false, error: '첨부 파일은 보드 뷰 토픽의 투표에서만 올릴 수 있습니다.' };
  }
  if (isRich && validAttachments.length > POST_ATTACHMENT_MAX) {
    return { ok: false, error: `첨부 파일은 ${POST_ATTACHMENT_MAX}개까지 올릴 수 있습니다.` };
  }
  const sentAttachments = validAttachments.slice(0, isRich ? POST_ATTACHMENT_MAX : MESSAGE_ATTACHMENT_MAX);

  // 글·제목·파일 이름·형식의 길이(messageLimits.js) — 예전엔 게시글 말고는 소켓 한 번에 실리는 만큼(1MB) 그대로 저장됐다.
  const tooLong = sizeDenial(payload, { room, isPost, isPoll, attachments: sentAttachments });
  if (tooLong) return { ok: false, error: tooLong };

  // 파일 칸 — 서명 링크(메시지 전달 — 앱은 원본이 아니라 서명된 다운로드 링크만 갖고 있다)든 원본 경로(방금 올린 파일)든 저장할
  // 원본 경로로 바꾸되, 이 사람이 써도 되는 파일인지 먼저 본다(resolveSentFiles). 하나라도 안 되면 일부만 빼고 보내지 않고
  // 거절한다 — 예전엔 만료·위조 링크의 첨부를 조용히 빼고 보냈다.
  const files = await resolveSentFiles(sentFileRefs(payload, sentAttachments, isRich), {
    fileSource,
    senderId,
    secret: !!room.isSecret,
  });
  if (!files.ok) return { ok: false, error: files.error };
  const pathOf = (ref) => (typeof ref === 'string' && ref !== '' ? files.pathOf(ref) : null);
  const fileUrl = isRich ? null : pathOf(payload.fileUrl);
  const thumbnailUrl = isRich ? null : pathOf(payload.thumbnailUrl);
  const attachments = sentAttachments.map((a) => ({
    kind: a.kind === 'file' ? 'file' : 'image',
    fileUrl: pathOf(a.fileUrl),
    fileName: typeof a.fileName === 'string' ? a.fileName : null,
    fileSize: sanitizeFileSize(a.fileSize),
    mimeType: typeof a.mimeType === 'string' ? a.mimeType : null,
    thumbnailUrl: pathOf(a.thumbnailUrl),
  }));
  const head = attachments[0];

  // 인용 카드·전달 표시 — 앱이 보낸 이름·미리보기 글이 아니라 원본에서 채운다(messageAttribution.js). 카드형(게시글·투표)은 쓰지
  // 않는다. 전달 표시는 보낸 글·파일이 원본 그대로일 때만 붙는다.
  let attribution = EMPTY_ATTRIBUTION;
  if (!isRich) {
    const resolved = await resolveAttribution({
      payload,
      senderId,
      room,
      sent: {
        text: payload.text,
        filePaths: [fileUrl, thumbnailUrl, ...attachments.flatMap((a) => [a.fileUrl, a.thumbnailUrl])].filter(Boolean),
      },
    });
    if (!resolved.ok) return { ok: false, error: resolved.error };
    attribution = resolved.fields;
  }

  const sender = await findUserById(senderId);

  // "팀장에게 문의하기"로 보낸 메시지에만 채워진다(chat_input_bar.dart) — 내가 이 방에서
  // 보낸 실제 문의가 맞는지 확인해서, 엉뚱한 문의 id를 붙여 "문의함 바로가기"를 위조하는
  // 것을 막는다. id 모양이 아니면 DB에 묻지 않는다(uuid 칸이라 DB 오류가 나 응답이 끊겼다).
  let inquiryId = null;
  if (isUuid(payload.inquiryId)) {
    const inquiry = await findInquiryById(payload.inquiryId);
    if (inquiry && inquiry.roomId === room.id && inquiry.senderId === senderId) {
      inquiryId = inquiry.id;
    }
  }

  // 멘션 — 본문이 있는 텍스트·게시글과 사진/파일에 붙인 설명글(캡션)에, 그 방의 멤버만(클라이언트 입력칸은 첨부 설명글에서도
  // @ 멘션을 고를 수 있다). 스티커·투표는 본문이 아니라 제외. 멘션이 없으면 멤버 조회를 건너뛴다(푸시 때 어차피 읽는다).
  let memberIds = null;
  let mentions = null;
  const mentionable = !isPoll && payload.type !== 'sticker';
  if (mentionable && !room.isSecret && Array.isArray(payload.mentions) && payload.mentions.length > 0) {
    memberIds = await listRoomMemberIds(room.id);
    const rawText = payload.text;
    mentions = mentionsToStore(
      sanitizeMentions(payload.mentions, isPost ? post.text : payload.text, {
        room,
        senderId,
        memberIdSet: new Set(memberIds),
        // 게시글 본문은 앞뒤 공백을 잘라 저장하므로 잘린 만큼 구간을 당긴다(서식과 같은 이유).
        shift: isPost && typeof rawText === 'string' ? rawText.length - rawText.trimStart().length : 0,
      }),
    );
  }

  // 게시글은 제목·본문(앞뒤 공백 뺀 값)과 첨부 목록만 쓴다 — 단일 파일 칸(fileUrl 등)·인용·전달
  // 값은 일반 메시지 전용이라 무시한다. 투표는 messages.text에 제목을 그대로 넣는다(검색·알림·미리보기가
  // text를 쓰므로) — 보기·마감 같은 나머지는 polls 표에 있다.
  const messageFields = {
    id: randomUUID(),
    roomId: room.id,
    senderId,
    senderName: sender?.name ?? sender?.username ?? fallbackName,
    type: isPoll ? 'poll' : isPost ? 'post' : ['image', 'file', 'sticker'].includes(payload.type) ? payload.type : 'text',
    title: post?.title ?? null,
    text: isPoll ? poll.title : post ? post.text : typeof payload.text === 'string' ? payload.text : null,
    textFormat: isPoll
      ? null
      : post
        ? sanitizeTextFormat(payload.textFormat, post.text)
        : room.isSecret || typeof payload.text !== 'string'
          ? null
          : sanitizeTextFormat(payload.textFormat, payload.text),
    mentions,
    fileUrl: head?.fileUrl ?? fileUrl,
    fileName:
      head?.fileName ?? (!isRich && typeof payload.fileName === 'string' ? payload.fileName : null),
    fileSize: head?.fileSize ?? (!isRich ? sanitizeFileSize(payload.fileSize) : null),
    mimeType:
      head?.mimeType ?? (!isRich && typeof payload.mimeType === 'string' ? payload.mimeType : null),
    thumbnailUrl: head?.thumbnailUrl ?? thumbnailUrl,
    ...attribution,
    isInquiryNotice: inquiryId != null,
    inquiryId,
    ...(albumShare && !isRich
      ? { albumId: albumShare.albumId, albumShare: { title: albumShare.title, teamName: albumShare.teamName ?? null } }
      : {}),
    ...(todoShare && !isRich ? { todoId: todoShare.todoId, todoCard: todoShare.card } : {}),
    clientId,
  };

  let message;
  let pollDto = null;
  try {
    if (isPoll) {
      // 메시지·첨부·투표·보기를 한 트랜잭션으로 — 중간에 실패해도 반쪽짜리 투표가 남지 않는다.
      const created = await insertPollMessage({
        message: messageFields,
        attachments,
        poll: {
          creatorId: senderId,
          title: poll.title,
          description: poll.description,
          anonymous: poll.anonymous,
          multiple: poll.multiple,
          closesAt: poll.closesAt,
        },
        optionTexts: poll.optionTexts,
      });
      message = created.message;
      if (created.attachments.length > 0) message.attachments = created.attachments;
      // 막 만든 투표라 표가 없다 — 모두에게 같은 DTO라 myOptionIds/favorite은 중립값이다.
      pollDto = toPollDto(created.poll, created.options, []);
    } else if (attachments.length > 1 || (post && attachments.length > 0)) {
      // 첨부가 둘 이상이면 목록으로도 저장한다(하나뿐이면 예전처럼 messages 칸만으로 충분). 게시글은
      // 하나여도 목록으로 저장한다 — toMessageDto의 예전 방식(파일 칸 하나 = 첨부 하나)은
      // 'image'/'file' 메시지에만 적용되기 때문이다. 메시지와 첨부는 한 트랜잭션으로 — 첨부에서 실패해도
      // 반쪽짜리 메시지가 남지 않는다(투표와 같다).
      const created = await insertMessageWithAttachments(messageFields, attachments);
      message = created.message;
      message.attachments = created.attachments;
    } else {
      message = await insertMessage(messageFields);
    }
  } catch (err) {
    // 같은 임시 id가 거의 동시에 두 번 왔다(재연결 직후 소켓이 쌓아 둔 것과 대기열이 다시 보낸 것) — 먼저 들어간 것을 돌려준다.
    if (clientId && isClientIdConflict(err)) {
      const duplicate = await duplicateReply(senderId, clientId, room.id);
      if (duplicate) return duplicate;
    }
    throw err;
  }

  // 평문 DM에서 상대가 이 방을 숨겨뒀으면(hidden) 자동으로 다시 보이게 한다 —
  // "숨기기"를 멤버십 변경 없이 구현한 결과라, 메시지가 갈 때마다 직접 확인해줘야 한다
  // (rooms.js unhideDmForOtherMembers 참고).
  await unhideDmForOtherMembers(io, room, senderId);

  // 서명은 toMessageDto 안에서 실시간으로만 이뤄진다 — DB에는 항상 원본을 유지해서
  // 나중에 다시 조회될 때도 그때 시점 기준으로 새로 서명할 수 있게 한다.
  const broadcastMessage = toMessageDto(pollDto ? { ...message, poll: pollDto } : message);
  if (Array.isArray(notifyOnly)) broadcastMessage.notifyOnly = notifyOnly;
  io.to(room.id).emit('message:new', broadcastMessage);

  // 응답(소켓 ack 등)을 기다리게 하지 않도록 백그라운드로 보낸다 — 실패해도(토큰 만료 등)
  // notifyOfflineMembers 내부에서 개별적으로 처리되고 메시지 전송 자체엔 영향 없다.
  (async () => {
    const ids = memberIds ?? (await listRoomMemberIds(room.id));
    // 알림 기록(멘션, 보드 새 게시글)을 먼저 — 실패해도 일반 푸시는 그대로 나간다. 멘션 푸시를 받는 사람은 일반 푸시에서 뺀다.
    let pushedUserIds = [];
    try {
      const actor = { id: senderId, name: message.senderName, user: sender };
      const mentioned = await notifyMentions({ io, room, message, actor, mentions: message.mentions, memberIds: ids });
      pushedUserIds = mentioned.pushedUserIds;
      if (isPost) {
        await notifyBoard({ io, event: 'post', room, post: message, actor, memberIds: ids, excludeIds: mentioned.notifiedUserIds });
      }
    } catch (err) {
      console.error('[notifications] 알림 기록 실패:', err?.message ?? err);
    }
    await notifyOfflineMembers({
      memberIds: Array.isArray(notifyOnly) ? ids.filter((id) => notifyOnly.includes(id)) : ids,
      senderId,
      senderName: message.senderName,
      sender,
      room,
      entry: message,
      roomTag: roomTagFor(room),
      kind: 'message',
      excludeUserIds: pushedUserIds,
    });
  })().catch((err) => console.error('[push] message:send 알림 실패:', err?.message ?? err));

  // 링크 미리보기도 백그라운드로 — 외부 사이트를 긁어오는 거라 몇 초 걸릴 수 있는데 메시지
  // 전송 자체를 그만큼 늦출 이유가 없다. 비밀 대화는 서버가 내용을 아예 못 봐야 하므로(암호문)
  // 건너뛴다. 미리보기 그림은 외부 주소를 저장하지 않고 서버가 한 번 받아 업로드 파일로 둔다
  // (linkPreviewImage.js) — 외부 주소를 넘기면 보는 사람마다 앱이 그 사이트에 직접 접속한다.
  if (!room.isSecret && message.type === 'text') {
    const url = extractFirstUrl(message.text);
    if (url) {
      fetchLinkPreview(url)
        .then(async (preview) => {
          if (!preview) return;
          const imageUrl = preview.imageUrl ? await storePreviewImage(preview.imageUrl, { requesterId: senderId }) : null;
          if (!preview.title && !preview.description && !imageUrl) return;
          const updated = await updateMessageLinkPreview(message.id, { ...preview, imageUrl });
          io.to(room.id).emit('message:linkPreview', toMessageDto(updated));
        })
        .catch((err) => console.error('[linkPreview] 처리 실패:', err?.message ?? err));
    }
  }

  return { ok: true, message: broadcastMessage };
}
