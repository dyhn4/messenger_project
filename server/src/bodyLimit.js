// REST(JSON) 본문 크기 상한과 본문 읽기 오류 응답 — index.js가 쓴다. DB 없이 단위 테스트한다(test/bodyLimit.test.js).
//
// 왜: express.json()의 기본 상한(100KB)이 이 앱의 정상 요청보다 작았다 — 비밀 대화의 댓글·메시지 수정(암호문 봉투, 최대
// SECRET_TEXT_MAX ≈ 24만 자), 서식·멘션이 붙은 긴 글의 수정·예약, 긴 노트(5만 자 — 한글이면 15만 바이트)가 "request entity too
// large"로 실패했다. 그 오류는 공통 오류 처리로 가서 영어 문구의 500(서버 고장처럼)으로 보였다.
import express from 'express';
import { SOCKET_MAX_PAYLOAD_BYTES } from './messageLimits.js';

/**
 * JSON 본문 상한(바이트) — 소켓 한 번 상한(messageLimits.js SOCKET_MAX_PAYLOAD_BYTES, 512KiB)과 같은 값이다. REST로 오는 가장 큰
 * 정상 본문은 소켓 message:send에 실리는 것과 같은 글이다: 메시지·게시글 수정(PATCH /messages/:id), 댓글, 예약 메시지가 같은 글
 * 상한(messageLimits.js)에 서식·멘션·첨부를 싣는다. 소켓으로 보낼 수 있는 글이면 REST로 고치거나 예약할 수도 있어야 하므로 같은
 * 상한을 쓴다. 가장 크게 불어나는 경우 — 제어 문자로 채운 최대 길이 글에 서식 2,000구간·멘션을 붙인 수정(약 0.33MB), 최대 길이
 * 비밀 대화 봉투(약 0.25MB), 제어 문자로 채운 5만 자 노트(약 0.3MB) — 도 넉넉히 들어가고(test/bodyLimit.test.js가 직접 만들어
 * 재 본다), 몇 MB씩 받지는 않는다. 파일은 JSON이 아니라 업로드(multer — upload.js)로 따로 받는다.
 */
export const JSON_BODY_LIMIT_BYTES = SOCKET_MAX_PAYLOAD_BYTES;

/**
 * JSON 본문 파서 — 로그인한 요청([isSignedIn](req) — index.js는 auth.js hasValidAccessToken: 이 서버가 서명한, 만료 전
 * AccessToken)만 JSON_BODY_LIMIT_BYTES까지 받고, 나머지(토큰 없는 요청 — 로그인·가입·비밀번호 찾기처럼 인증 전에 열린 경로)는
 * express 기본(100KB) 그대로다. 본문은 라우트의 requireAuth보다 먼저 읽으므로, 그대로 다 올리면 인터넷의 누구든 토큰 없이 큰
 * 본문을 보내 서버가 읽고 풀게 만들 수 있는 양이 다섯 배가 된다 — 인증 전 경로에는 100KB를 넘는 정상 요청이 없다.
 * JSON이 아닌 요청(업로드의 multipart 등)은 어느 쪽 파서도 건드리지 않는다(예전 express.json()과 같다).
 */
export function createJsonBodyParser({ isSignedIn }) {
  const standard = express.json();
  const large = express.json({ limit: JSON_BODY_LIMIT_BYTES });
  return (req, res, next) => (isSignedIn(req) ? large : standard)(req, res, next);
}

export const BODY_TOO_LARGE_ERROR = '보낸 내용이 너무 큽니다. 내용을 줄이거나 나눠서 다시 보내 주세요.';
export const BODY_MALFORMED_ERROR = '요청 형식이 올바르지 않습니다.';
export const BODY_UNREADABLE_ERROR = '요청 내용을 읽지 못했습니다. 다시 시도해 주세요.';
/** requireAuth(auth.js)가 만료·위조 토큰에 쓰는 문구와 같다 — 앱은 401이면 토큰을 새로 받아 같은 요청을 다시 보낸다(api_client.dart _send). */
export const BODY_TOKEN_INVALID_ERROR = '토큰이 유효하지 않습니다.';

/** express.json(body-parser·raw-body)이 요청 쪽 잘못으로 내는 오류의 종류(err.type) — 이 밖의 오류는 여기서 다루지 않는다. */
const BODY_CLIENT_ERROR_TYPES = new Set([
  'entity.too.large',
  'entity.parse.failed',
  'entity.aborted',
  'request.aborted',
  'request.size.invalid',
  'charset.unsupported',
  'encoding.unsupported',
]);

/**
 * 본문을 읽다 난 오류(express.json)면 보낼 응답 `{ status, error }`, 아니면 null(공통 오류 처리가 예전처럼 500으로 답한다). 요청이
 * 잘못된 것이지 서버 고장이 아니라서 그 상태 코드(4xx)와 한국어 문구로 답한다 — 예전엔 영어 문구의 500이었다:
 *  - 너무 큼(entity.too.large) → 413. 단, 토큰이 붙어 있는데 만료됐거나 틀려서([isSignedIn]이 false) 기본 상한(100KB)으로 읽은
 *    요청은 401 — 앱은 401이면 토큰을 새로 받아 같은 요청을 다시 보내고, 그때는 큰 상한으로 읽힌다. 그대로 413을 주면 토큰이
 *    만료된 뒤 처음 보낸 긴 글이 다시 보내 보지도 못하고 "너무 큼"으로 실패한다(토큰이 맞았다면 받았을 크기인데도).
 *  - JSON 형식 오류(entity.parse.failed) → 400.
 *  - 그 밖의 읽기 오류(길이가 알린 것과 다름·중간에 끊김·지원하지 않는 문자셋이나 압축) → 그 상태 코드.
 * 서버 쪽 문제로 난 본문 오류(5xx)는 여기서 다루지 않는다.
 */
export function bodyErrorReply(err, req, { isSignedIn }) {
  const status = err?.status ?? err?.statusCode;
  if (!BODY_CLIENT_ERROR_TYPES.has(err?.type) || err.expose !== true || !(status >= 400 && status < 500)) return null;
  if (err.type === 'entity.too.large') {
    const header = req?.headers?.authorization;
    if (typeof header === 'string' && header.startsWith('Bearer ') && !isSignedIn(req)) {
      return { status: 401, error: BODY_TOKEN_INVALID_ERROR };
    }
    return { status: 413, error: BODY_TOO_LARGE_ERROR };
  }
  if (err.type === 'entity.parse.failed') return { status: 400, error: BODY_MALFORMED_ERROR };
  return { status, error: BODY_UNREADABLE_ERROR };
}
