// 메시지·댓글·문의의 길이 상한과 보내기 횟수 제한 — DB 없이 단위 테스트한다(test/messageLimits.test.js).
//
// 왜: 게시글 말고는 서버가 길이를 보지 않아서, 소켓 한 번(기본 1MB)에 실리는 만큼의 글·인용·파일 이름이 그대로 저장되고 방의 모든
// 멤버에게 뿌려졌다 — DB가 불어나고, 받는 앱은 방 목록 미리보기·대화 화면에서 그 글을 그리다 멈춘다. 메시지 보내기와 댓글 달기에는
// 횟수 제한도 없었다.
import { RateLimiter, minutesText } from './authGuard.js';
import { graphemeLength, POST_TEXT_MAX, POST_TITLE_MAX } from './permissions.js';

// ── 글 길이 ────────────────────────────────────────────────────────────

/**
 * 메시지(사진·파일의 설명글 포함)·댓글 본문 상한(글자 단위 — 이모지 한 덩어리 = 1자). 게시글 본문(parsePostFields)과 같은 값이다 —
 * 게시글을 "메시지 전달"하면 제목과 본문이 한 메시지 글로 들어가므로, 이보다 작으면 긴 게시글을 대화방으로 전달할 수 없다.
 */
export const MESSAGE_TEXT_MAX = POST_TEXT_MAX;

/**
 * 같은 글의 바이트(UTF-8) 상한 — 글자 수만 세면 글자 하나에 결합 문자를 수천 개 붙인 글("자고 글자")이 한 글자로 세어져 끝없이
 * 커질 수 있다. 글자당 평균 4바이트(한글 3바이트·이모지 대부분 4바이트)까지 — 보통 글은 글자 수 상한에 먼저 닿는다.
 */
export const MESSAGE_TEXT_MAX_BYTES = 4 * MESSAGE_TEXT_MAX;

/**
 * 비밀 대화의 글(text)은 서버가 못 읽는 암호문 봉투(JSON — client secret_chat_crypto.dart encryptEnvelope)라 글자 수로 셀 수 없다.
 * 대신 "평문 상한 안의 가장 긴 글을 암호화한 봉투"가 들어가는 길이를 상한으로 둔다:
 *   - 평문: 사진·파일 메시지는 설명글을 파일 이름·복호화 키와 함께 JSON으로 감싸 암호화한다(session.dart encryptAttachmentPayload).
 *     JSON은 제어 문자 하나(1바이트·1글자)를 \u00XX(6바이트)로 늘리므로, 글자 수(MESSAGE_TEXT_MAX)·바이트(MESSAGE_TEXT_MAX_BYTES)
 *     상한 안의 설명글이 가장 크게 불어나면 MESSAGE_TEXT_MAX_BYTES + 5 × MESSAGE_TEXT_MAX바이트다. 여기에 파일 이름(최대 255자,
 *     역시 이스케이프로 불어날 수 있다)·키·숫자 칸 몫으로 4KB를 더 둔다.
 *   - 봉투: AES-GCM 암호문 = 평문 + 16바이트(인증 태그), base64로 4/3배 → {"v":1,"epoch":…,"n":…,"nonce":"…","ciphertext":"…"}의
 *     나머지 칸 몫 256자.
 */
export const SECRET_PLAINTEXT_MAX_BYTES = MESSAGE_TEXT_MAX_BYTES + 5 * MESSAGE_TEXT_MAX + 4096;
export const SECRET_TEXT_MAX = 4 * Math.ceil((SECRET_PLAINTEXT_MAX_BYTES + 16) / 3) + 256;

/** 이모티콘 메시지·댓글의 글은 이모티콘 id다(서버 이모티콘 'server:<uuid>' 등) — 그보다 길 일이 없다. */
export const STICKER_TEXT_MAX = 200;

/** 파일 이름 — 운영체제가 받는 이름(한 칸 255자)까지. 결합 문자 폭탄을 막는 UTF-16 길이 상한도 함께 둔다. */
export const FILE_NAME_MAX = 255;
const FILE_NAME_MAX_UNITS = 1024;
/** MIME 형식('type/subtype' — RFC 6838은 양쪽 127자씩까지). */
export const MIME_TYPE_MAX = 255;
/** messages·댓글·문의의 file_size 칸(integer)에 들어가는 값 — 넘으면 DB가 오류를 낸다. */
const FILE_SIZE_MAX = 2147483647;

/** 서버가 채우는 인용 미리보기·출처 이름의 상한(quoteForwardRules.js) — 말풍선은 두 줄만 보여 준다. */
export const QUOTE_PREVIEW_MAX = 300;
export const ATTRIBUTION_NAME_MAX = 100;

/** 문의 분류 — 앱은 정해 둔 몇 개(client models/inquiry.dart inquiryCategories) 중에서 고른다. */
export const INQUIRY_CATEGORY_MAX = 20;

export const TEXT_TOO_LONG_ERROR = '메시지가 너무 깁니다. 나눠서 보내 주세요.';
export const FILE_NAME_ERROR = '파일 이름이 너무 깁니다. 이름을 줄여 다시 올려 주세요.';
export const MIME_TYPE_ERROR = '파일 형식 정보가 올바르지 않습니다.';

/** [text]가 바이트 상한 안인지 — 바이트를 먼저 보는 이유: 큰 글을 글자 단위로 쪼개(느리다) 보기 전에 싸게 거른다. */
function withinBytes(text, maxBytes) {
  // UTF-16 한 칸은 UTF-8로 3바이트를 넘지 않으므로 이만큼 짧으면 셀 필요도 없다.
  return text.length * 3 <= maxBytes || Buffer.byteLength(text, 'utf8') <= maxBytes;
}

/**
 * 메시지·댓글 글 검사 — 받을 수 있으면 null, 아니면 거절 문구. [secret]이면 암호문 봉투 길이만, [sticker]면 id 길이만 본다.
 * [subject]는 글자 수 문구의 주어('메시지는'·'댓글은').
 */
export function messageTextDenial(text, { secret = false, sticker = false, subject = '메시지는' } = {}) {
  if (typeof text !== 'string' || text === '') return null;
  if (secret) return text.length > SECRET_TEXT_MAX ? TEXT_TOO_LONG_ERROR : null;
  if (sticker) return text.length > STICKER_TEXT_MAX ? '이모티콘 정보가 올바르지 않습니다.' : null;
  if (!withinBytes(text, MESSAGE_TEXT_MAX_BYTES)) return TEXT_TOO_LONG_ERROR;
  if (graphemeLength(text) > MESSAGE_TEXT_MAX) {
    return `${subject} ${MESSAGE_TEXT_MAX.toLocaleString('en-US')}자 이내로 입력하세요.`;
  }
  return null;
}

/** 게시글 제목의 바이트 상한 — 글자당 16바이트(가장 긴 이모지 조합도 대개 그 안이다). 글자 수는 parsePostFields가 본다. */
const POST_TITLE_MAX_BYTES = 16 * POST_TITLE_MAX;

/** 게시글 제목·본문의 바이트 상한(글자 수는 parsePostFields가 본다) — 받을 수 있으면 null. */
export function postBytesDenial(title, text) {
  if (typeof title === 'string' && !withinBytes(title, POST_TITLE_MAX_BYTES)) return TEXT_TOO_LONG_ERROR;
  if (typeof text === 'string' && !withinBytes(text, MESSAGE_TEXT_MAX_BYTES)) return TEXT_TOO_LONG_ERROR;
  return null;
}

/** 파일 칸들(이름·형식) 검사 — 받을 수 있으면 null. 문자열이 아닌 값은 호출부가 null로 저장하므로 여기선 넘긴다. */
export function fileFieldsDenial({ fileName, mimeType } = {}) {
  if (typeof fileName === 'string' && (fileName.length > FILE_NAME_MAX_UNITS || graphemeLength(fileName) > FILE_NAME_MAX)) {
    return FILE_NAME_ERROR;
  }
  if (typeof mimeType === 'string' && mimeType.length > MIME_TYPE_MAX) return MIME_TYPE_ERROR;
  return null;
}

/** 파일 크기 — 0 이상 정수이고 칸에 들어가는 값만, 아니면 null(크기는 표시용이라 버려도 된다 — 예전엔 소수·큰 수가 DB 오류를 냈다). */
export function sanitizeFileSize(value) {
  return Number.isSafeInteger(value) && value >= 0 && value <= FILE_SIZE_MAX ? value : null;
}

/** 서버가 만드는 짧은 글(인용 미리보기·이름)을 [max]글자로 자른다 — 잘렸으면 끝에 '…'. */
export function clipGraphemes(text, max) {
  if (typeof text !== 'string') return text;
  if (text.length <= max) return text;
  let count = 0;
  let end = 0;
  for (const { segment, index } of new Intl.Segmenter('ko', { granularity: 'grapheme' }).segment(text)) {
    if (count === max) return `${text.slice(0, end)}…`;
    count += 1;
    end = index + segment.length;
  }
  return text;
}

// ── 소켓 한 번에 받는 크기 ─────────────────────────────────────────────

/**
 * socket.io가 한 번에 받는 메시지 크기 상한(index.js maxHttpBufferSize — 기본 1MB). 앱이 소켓으로 보내는 것 가운데 가장 큰 것은
 * message:send다(나머지 — 읽음·통화·재키잉 신호 — 는 수백 바이트; 투표는 REST, 화이트보드는 LiveKit 데이터 채널로 간다):
 *   - 비밀 대화: 글이 봉투 상한 SECRET_TEXT_MAX(약 24만 자 — ASCII라 바이트도 같다) + 파일 칸 몇백 바이트.
 *   - 일반 방: 글 MESSAGE_TEXT_MAX_BYTES(8만) — JSON에 실리며 제어 문자가 늘어나도 위와 같은 셈으로 약 18만 바이트 — 에 서식
 *     (textFormat 최대 2,000구간)·멘션(최대 200개 후보)·첨부(최대 30개) 몫 수십 KB.
 * 둘 다 0.3MB를 넘지 않아 512KiB면 넉넉하다. 이보다 큰 것은 정상 앱이 만들 수 없는 크기라 서버가 받지 않고 연결을 끊는다 — 앱은
 * 보내기 전에 같은 상한으로 먼저 거른다(client chat_socket.dart).
 */
export const SOCKET_MAX_PAYLOAD_BYTES = 512 * 1024;

// ── 보내기 횟수 ────────────────────────────────────────────────────────

const SEC = 1000;
const MIN = 60 * SEC;

/**
 * 사람마다 메시지 보내기 횟수 — 짧게 몰아 보내기(10초)와 길게 이어 보내기(10분)를 따로 센다. 사람이 손으로 보내는 속도로는 닿지
 * 않을 만큼 넉넉하다.
 *
 * 파일을 싣는 보내기(sendCarriesFiles)는 10초 창에서 뺀다(10분 창에는 센다): 앱은 파일 하나마다 한 통씩 쉬지 않고 이어 보낸다 —
 * 비밀 대화는 사진·파일을 한 장씩 따로 보내고(room_chat_controller.dart sendUploadedAttachments), 댓글은 첨부마다 댓글 하나다
 * (comment_input_bar.dart). 파일 고르기에 개수 제한이 없어서 한 번에 고른 수십·수백 개가 10초 안에 몰리는데, 10초 창에 걸리면 중간부터
 * 실패하고 남은 파일은 사라진다(예전 앱도 같은 반복이라 앱만 고쳐서는 안 된다). 그래서 이런 몰림은 10분 창(메시지 600통·댓글
 * 300개)으로만 막는다 — 10분 창이 보내기 총량의 상한이라 파일을 붙여 10초 창을 피해도 그 이상은 보낼 수 없다.
 */
export const MESSAGE_SEND_BURST = { max: 40, windowMs: 10 * SEC };
export const MESSAGE_SEND_SUSTAINED = { max: 600, windowMs: 10 * MIN };
/** 사람마다 댓글 달기 횟수 — 같은 방식(첨부를 단 댓글은 10초 창에서 뺀다). */
export const COMMENT_CREATE_BURST = { max: 20, windowMs: 10 * SEC };
export const COMMENT_CREATE_SUSTAINED = { max: 300, windowMs: 10 * MIN };

/** 파일을 싣는 메시지인지(파일 칸이나 첨부 목록에 경로 문자열이 있다) — 짧은 창에서 뺄지 정한다(위 MESSAGE_SEND_BURST). */
export function sendCarriesFiles(payload) {
  const hasPath = (value) => typeof value === 'string' && value !== '';
  if (!payload || typeof payload !== 'object') return false;
  return hasPath(payload.fileUrl) || (Array.isArray(payload.attachments) && payload.attachments.some((a) => hasPath(a?.fileUrl)));
}

/**
 * 짧은·긴 창 두 개를 함께 세는 제한기 — hit(key)는 막아야 하면 남은 ms(아니면 0). 둘 다 센다(한쪽만 세면 다른 쪽을 우회한다).
 * hit(key, { burst: false })는 긴 창에만 센다 — 파일을 싣는 보내기(위 설명).
 */
export function createPairLimiter(burst, sustained, { now = () => Date.now() } = {}) {
  const short = new RateLimiter({ ...burst, now });
  const long = new RateLimiter({ ...sustained, now });
  return {
    hit(key, { burst: countBurst = true } = {}) {
      const longWait = long.hit(key);
      return countBurst ? Math.max(short.hit(key), longWait) : longWait;
    },
    prune() {
      short.prune();
      long.prune();
    },
  };
}

export const messageSendLimiter = createPairLimiter(MESSAGE_SEND_BURST, MESSAGE_SEND_SUSTAINED);
export const commentCreateLimiter = createPairLimiter(COMMENT_CREATE_BURST, COMMENT_CREATE_SUSTAINED);
setInterval(() => {
  messageSendLimiter.prune();
  commentCreateLimiter.prune();
}, MIN).unref();

/** 메시지 보내기를 막았을 때 소켓 응답(ack)으로 보여 줄 문구 — 1분이 안 남았으면 초로. */
export function messageRateLimitText(ms) {
  const wait = ms < MIN ? `${Math.max(1, Math.ceil(ms / SEC))}초` : minutesText(ms);
  return `메시지를 너무 빠르게 보내고 있습니다. ${wait} 후 다시 시도하세요.`;
}
