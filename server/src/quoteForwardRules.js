// "메시지 공유"(인용 카드)·"메시지 전달"(전달 표시)의 출처 규칙 — DB 없이 단위 테스트한다(test/quoteForwardRules.test.js). 출처를
// 읽어 오는 쪽은 messageAttribution.js.
//
// 왜: 예전엔 인용 카드의 보낸 사람·미리보기와 전달 표시의 이름·시각을 앱이 보낸 글 그대로 저장했다. 그래서 누구나(준회원도) 들어가
// 본 적도 없는 방의 "대표이사 홍길동에서 공유된 메시지입니다" 카드에 지어낸 글을 실어 보낼 수 있었다. 이제 앱은 원본의 id만 보내고,
// 서버가 그 사람이 지금 읽을 수 있는 원본인지 확인한 뒤 이름·미리보기·시각을 DB에서 채운다(앱이 보낸 글은 쓰지 않는다).
import { ATTRIBUTION_NAME_MAX, clipGraphemes, QUOTE_PREVIEW_MAX } from './messageLimits.js';

// 공유는 인용 카드가 곧 내용이라, 출처를 확인할 수 없으면 카드를 빼고 보내지 않고 거절한다(받는 사람에게 빈 공유가 가지 않게).
export const QUOTE_UPDATE_REQUIRED = '메시지 공유는 앱을 최신 버전으로 업데이트한 뒤 다시 해 주세요.';
export const QUOTE_NOT_FOUND = '공유할 메시지를 찾을 수 없습니다.';
export const QUOTE_SECRET_SOURCE = '비밀 대화의 메시지는 공유할 수 없습니다.';
export const QUOTE_SECRET_TARGET = '비밀 대화로는 메시지를 공유할 수 없습니다.';
export const QUOTE_POLL = '투표는 공유할 수 없습니다.';
export const QUOTE_UNSUPPORTED = '이 메시지는 공유할 수 없습니다.';
export const ANNOUNCEMENT_NOT_FOUND = '공유할 공지를 찾을 수 없습니다.';

/** 출처 이름을 모를 때(탈퇴 등으로 비었을 때) 카드에 쓸 이름. */
const UNKNOWN_NAME = '알 수 없음';

// 앱이 공유·전달 메뉴를 보여 주는 메시지 종류(투표는 메뉴가 없고, 시스템 메시지·화상회의 카드는 사람이 쓴 글이 아니다).
const QUOTABLE_TYPES = ['text', 'image', 'file', 'sticker', 'post'];

export const EMPTY_ATTRIBUTION = Object.freeze({
  quotedSenderName: null,
  quotedPreview: null,
  forwardedFromSenderName: null,
  forwardedFromCreatedAt: null,
});

/**
 * message:send payload에서 출처 요청을 읽는다 — `{ quote, forward }`.
 *  - quote: { kind: 'message', id }(메시지·댓글 공유 — quotedMessageId) | { kind: 'announcement', id }(공지 공유 —
 *    quotedAnnouncementId) | { kind: 'legacy' }(id 없이 이름·미리보기 글만 — 예전 앱) | null.
 *  - forward: { id }(forwardedFromMessageId) | null. 예전 앱의 전달 표시(이름·시각 글만)는 출처를 알 수 없어 요청으로 치지 않는다 —
 *    전달한 내용 자체는 그대로 가고 "…에서 전달한 메시지입니다" 줄만 빠진다.
 * 새 앱은 옛 서버도 알아보게 이름·미리보기 글을 id와 함께 보내지만, id가 있으면 그 글은 보지 않는다.
 */
export function attributionRequest(payload) {
  const p = payload ?? {};
  const present = (v) => v !== undefined && v !== null;
  let quote = null;
  if (present(p.quotedMessageId)) quote = { kind: 'message', id: p.quotedMessageId };
  else if (present(p.quotedAnnouncementId)) quote = { kind: 'announcement', id: p.quotedAnnouncementId };
  else if (typeof p.quotedSenderName === 'string' || typeof p.quotedPreview === 'string') quote = { kind: 'legacy' };
  const forward = present(p.forwardedFromMessageId) ? { id: p.forwardedFromMessageId } : null;
  return { quote, forward };
}

/**
 * 출처 글(메시지 또는 댓글)에 지금 붙어 있는 파일 경로들 — 메시지는 지우지 않은 첨부 목록과 파일 칸(파일을 지웠으면 빼고), 댓글은
 * 자기 파일 칸. 전달한 파일이 이 안에 있어야 전달 표시를 붙인다.
 */
export function sourceFilePaths({ kind, row, attachments = [] }) {
  const out = [];
  if (kind === 'comment') {
    out.push(row?.fileUrl, row?.thumbnailUrl);
  } else {
    for (const a of attachments ?? []) if (!a.deletedAt) out.push(a.fileUrl, a.thumbnailUrl);
    if (!row?.fileDeletedAt) out.push(row?.fileUrl, row?.thumbnailUrl);
  }
  return [...new Set(out.filter((p) => typeof p === 'string' && p))];
}

/** 공유(인용)할 수 없는 출처면 거절 문구, 공유할 수 있으면 null. [source]는 messageAttribution.js loadReadableSource의 결과. */
export function quoteSourceDenial(source) {
  if (!source) return QUOTE_NOT_FOUND;
  // 비밀 대화는 서버가 암호문만 갖고 있어 미리보기를 만들 수 없고, 평문이 다른 방으로 새면 안 된다(앱도 메뉴를 감춘다).
  if (source.roomIsSecret) return QUOTE_SECRET_SOURCE;
  if (source.type === 'poll') return QUOTE_POLL;
  if (!QUOTABLE_TYPES.includes(source.type)) return QUOTE_UNSUPPORTED;
  return null;
}

/**
 * 인용 미리보기 — 앱이 보내던 글과 같다(client services/message_preview.dart formatMessagePreview, 게시글은 "게시글: 제목").
 * 이모티콘은 서버가 id만 알아서 이모지 없이 "이모티콘을 보냈습니다"다(알림 미리보기 — push.js previewFor와 같다).
 */
export function quotePreviewOf(source) {
  let preview;
  switch (source.type) {
    case 'text':
      preview = source.text ?? '';
      break;
    case 'image':
      preview = '사진을 보냈습니다';
      break;
    case 'file':
      preview = source.fileName ? `${source.fileName} 파일을 보냈습니다` : '파일을 보냈습니다';
      break;
    case 'sticker':
      preview = '이모티콘을 보냈습니다';
      break;
    case 'post':
      preview = `게시글: ${source.title ?? ''}`;
      break;
    default:
      preview = '';
  }
  return clipGraphemes(preview, QUOTE_PREVIEW_MAX);
}

function attributionName(name) {
  const trimmed = typeof name === 'string' ? name.trim() : '';
  return clipGraphemes(trimmed || UNKNOWN_NAME, ATTRIBUTION_NAME_MAX);
}

/** 공지 공유의 인용 카드 — 앱이 보내던 값(공지 작성자 이름, 글이 없고 사진만 있으면 '[사진]')과 같다. */
export function announcementQuote(announcement) {
  const text = typeof announcement?.text === 'string' ? announcement.text.trim() : '';
  const preview = text || (announcement?.imageUrl ? '[사진]' : '');
  return {
    quotedSenderName: attributionName(announcement?.authorName),
    quotedPreview: clipGraphemes(preview, QUOTE_PREVIEW_MAX),
  };
}

/**
 * 전달 화면이 처음 채워 주는 글(client message_forward_screen.dart _initialForwardText)로 볼 수 있는 값들 — 앞뒤 공백을 뗀 것.
 * 게시글은 "제목\n\n본문"(본문이 없으면 제목)이고, 파일 모아보기에서 게시글의 첨부 한 줄을 전달하면 그 줄의 글(본문)이 채워진다.
 */
export function forwardTextCandidates(source) {
  const text = typeof source.text === 'string' ? source.text.trim() : '';
  if (source.type !== 'post') return [text];
  const title = typeof source.title === 'string' ? source.title.trim() : '';
  return [...new Set([(text ? `${title}\n\n${text}` : title).trim(), text])];
}

/**
 * 전달한 내용이 출처 글 그대로인지 — 전달 화면은 글을 고칠 수 있는데, 고친 글에 "OOO에서 전달한 메시지입니다"를 붙이면 그 사람이
 * 쓰지 않은 글을 그 사람 것으로 보이게 만들 수 있다. 글이 처음 채워진 그대로이고, 실은 파일이 모두 출처에 붙어 있는 파일일 때만
 * 전달 표시를 붙인다(파일은 일부만 실어도 된다). [text]는 보낸 글, [filePaths]는 실은 파일의 저장 경로들(fileRefs.js가 푼 값).
 */
export function forwardMatchesSource({ text, filePaths = [], source }) {
  if (source.type === 'sticker') {
    // 이모티콘 메시지의 글은 이모티콘 id다 — 전달 화면은 고칠 칸 없이 그대로 싣는다.
    if ((typeof text === 'string' ? text : '') !== (source.text ?? '')) return false;
  } else {
    const sent = typeof text === 'string' ? text.trim() : '';
    if (!forwardTextCandidates(source).includes(sent)) return false;
  }
  const allowed = new Set(source.filePaths ?? []);
  return filePaths.every((p) => allowed.has(p));
}

/**
 * 출처 요청과 읽어 온 출처로 저장할 칸을 정한다 — `{ ok: true, fields }` 또는 `{ ok: false, error }`.
 *  - [targetIsSecret]: 보내는 방이 비밀 대화. 인용 카드·전달 표시는 서버가 읽을 수 있는 평문이라 비밀 대화에는 싣지 않는다(앱도
 *    공유·전달 대상에서 비밀 대화를 뺀다) — 공유는 거절, 전달 표시는 뺀다.
 *  - [quoteSource]/[announcement]: 그 사람이 지금 읽을 수 있는 인용 출처(없거나 못 읽으면 null).
 *  - [forwardSource]: 전달 출처(같은 규칙). 못 읽거나, 비밀 대화의 글이거나, 내용이 출처 그대로가 아니면 전달 표시만 뺀다(전달 자체는
 *    그 사람이 보내는 새 메시지라 막지 않는다).
 *  - [sent]: { text, filePaths } — 보낸 글과 실은 파일(forwardMatchesSource).
 */
export function decideAttribution({ request, targetIsSecret = false, quoteSource = null, announcement = null, forwardSource = null, sent = {} }) {
  const fields = { ...EMPTY_ATTRIBUTION };
  if (request?.quote) {
    if (targetIsSecret) return { ok: false, error: QUOTE_SECRET_TARGET };
    if (request.quote.kind === 'legacy') return { ok: false, error: QUOTE_UPDATE_REQUIRED };
    if (request.quote.kind === 'announcement') {
      if (!announcement) return { ok: false, error: ANNOUNCEMENT_NOT_FOUND };
      Object.assign(fields, announcementQuote(announcement));
    } else {
      const denial = quoteSourceDenial(quoteSource);
      if (denial) return { ok: false, error: denial };
      fields.quotedSenderName = attributionName(quoteSource.senderName);
      fields.quotedPreview = quotePreviewOf(quoteSource);
    }
  }
  if (
    request?.forward &&
    !targetIsSecret &&
    forwardSource &&
    !forwardSource.roomIsSecret &&
    QUOTABLE_TYPES.includes(forwardSource.type) &&
    forwardMatchesSource({ ...sent, source: forwardSource })
  ) {
    fields.forwardedFromSenderName = attributionName(forwardSource.senderName);
    fields.forwardedFromCreatedAt = new Date(forwardSource.createdAt);
  }
  return { ok: true, fields };
}
