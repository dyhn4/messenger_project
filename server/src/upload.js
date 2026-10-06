import fs from 'node:fs';
import path from 'node:path';
import crypto, { randomUUID } from 'node:crypto';
import { Router } from 'express';
import jwt from 'jsonwebtoken';
import multer from 'multer';
import { JWT_SECRET, UPLOADS_DIR } from './config.js';

export const uploadsDir = UPLOADS_DIR;
// 네트워크 경로(UNC/매핑 드라이브)로 지정된 경우 아직 폴더가 없을 수 있어 미리 만들어둔다.
// multer의 diskStorage는 destination 폴더가 이미 있어야 하고 스스로 만들어주지 않는다.
fs.mkdirSync(uploadsDir, { recursive: true });

// 업로드된 파일은 더 이상 고정된 공개 경로(/uploads/xxx)로 직접 서빙하지 않는다. 대신 매번
// 짧게 만료되는 서명 URL(/files/<token>)을 만들어서 응답에 넣는다 — 그 URL을 아는 사람만,
// 그것도 발급된 지 얼마 안 됐을 때만 파일을 받을 수 있다.
//
// 만료를 "지금부터 N분"이 아니라 1시간 단위 버킷으로 묶는 이유: 같은 파일(예: 프로필
// 사진)에 대해 같은 시간대 안에서는 항상 같은 토큰이 나오게 해서, Flutter의 이미지 캐시가
// URL이 바뀔 때마다(=매번 새로 서명될 때마다) 매번 다시 내려받는 걸 막기 위함이다.
const BUCKET_MS = 60 * 60 * 1000;
const VALID_BUCKETS = 2; // 현재 버킷 + 다음 버킷까지, 즉 최대 2시간 후 만료.

// 다운로드 링크 토큰은 내용을 암호화해서(AES-256-GCM) 링크만 봐서는 어떤 파일인지 알 수 없게 한다. 예전엔 JWT라
// 누구나 base64를 풀어 실제 파일 이름(/uploads/<uuid>.확장자)을 읽을 수 있었고, 그 이름을 자기 메시지에 넣어 다시
// 서명받는 식으로 방에서 나간 뒤에도 그 파일을 계속 받을 수 있었다. 같은 파일·같은 시간대면 늘 같은 토큰이 나오도록
// IV를 내용에서 만든다(HMAC) — 이미지 캐시가 위 버킷 설계대로 계속 맞게.
const FILE_TOKEN_KEY = crypto.createHash('sha256').update(`${JWT_SECRET}:file-token:enc`).digest();
const FILE_TOKEN_IV_KEY = crypto.createHash('sha256').update(`${JWT_SECRET}:file-token:iv`).digest();

function sealFileToken(payload) {
  const plain = Buffer.from(JSON.stringify(payload), 'utf8');
  const iv = crypto.createHmac('sha256', FILE_TOKEN_IV_KEY).update(plain).digest().subarray(0, 12);
  const cipher = crypto.createCipheriv('aes-256-gcm', FILE_TOKEN_KEY, iv);
  const ct = Buffer.concat([cipher.update(plain), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), ct]).toString('base64url');
}

/**
 * 토큰을 풀어 { file, type, exp, downloadName? }을 돌려준다(위조·형식 오류·만료면 throw). 점(.)이 있으면 이 방식 전에
 * 발급된 JWT 토큰 — 최대 2시간이면 다 만료되지만, 앱이 들고 있던 옛 링크를 새로 받는 경로(knownUploadPath)를 위해
 * 계속 알아본다.
 */
function openFileToken(token, { ignoreExpiration = false } = {}) {
  if (typeof token !== 'string') throw new Error('invalid file token');
  let payload;
  if (token.includes('.')) {
    payload = jwt.verify(token, JWT_SECRET, { ignoreExpiration });
  } else {
    const buf = Buffer.from(token, 'base64url');
    if (buf.length < 29) throw new Error('invalid file token');
    const decipher = crypto.createDecipheriv('aes-256-gcm', FILE_TOKEN_KEY, buf.subarray(0, 12));
    decipher.setAuthTag(buf.subarray(12, 28));
    payload = JSON.parse(Buffer.concat([decipher.update(buf.subarray(28)), decipher.final()]).toString('utf8'));
    if (!ignoreExpiration && !(payload.exp * 1000 > Date.now())) throw new Error('file token expired');
  }
  if (payload?.type !== 'file' || typeof payload.file !== 'string') throw new Error('invalid file token');
  return payload;
}

/**
 * 저장된 상대경로(/uploads/xxx)를 짧게 만료되는 서명 다운로드 경로(/files/<token>)로 바꾼다.
 * downloadName을 같이 주면(메시지 첨부처럼 원본 파일명이 있는 경우) 토큰에 실어서, 실제
 * 다운로드 응답에 Content-Disposition으로 원본 파일명을 돌려줄 수 있게 한다 — 안 그러면
 * (예: 파일을 눌러서 브라우저/외부 앱으로 바로 열 때) URL의 토큰 문자열이 파일명으로
 * 쓰여버린다.
 */
export function signFileUrl(relativeUrl, downloadName) {
  if (!relativeUrl) return relativeUrl;
  const filename = path.basename(relativeUrl); // 경로 조작 방지
  const bucketStart = Math.floor(Date.now() / BUCKET_MS) * BUCKET_MS;
  const exp = Math.floor((bucketStart + VALID_BUCKETS * BUCKET_MS) / 1000);
  const payload = { file: filename, type: 'file', exp };
  if (downloadName) payload.downloadName = downloadName;
  return `/files/${sealFileToken(payload)}`;
}

/**
 * 메시지 전달(forward)용 — 클라이언트는 첨부의 서명된 다운로드 URL(/files/<token>)만 들고
 * 있으므로, 그걸 그대로 새 메시지의 fileUrl로 저장하면 안 된다(토큰이 곧 만료되고, 애초에
 * DB엔 항상 미서명 원본 경로만 남아야 한다 — signFileUrl 주석 참고). 서명된 형태로 오면
 * 검증해서 원본 상대경로(/uploads/xxx)로 되돌리고, 이미 원본 경로면 그대로 돌려준다.
 * 토큰이 무효/만료면 null(호출부가 첨부 없이 진행하거나 실패 처리).
 */
export function resolveRawUrl(url) {
  if (!url) return null;
  const match = /^\/files\/(.+)$/.exec(url);
  if (!match) return url;
  try {
    return `/uploads/${path.basename(openFileToken(match[1]).file)}`;
  } catch {
    return null;
  }
}

/**
 * 팀·그룹 아이콘 사진처럼 클라이언트가 업로드 응답의 URL(서명된 /files/ 링크든 미서명
 * /uploads/ 경로든)을 다시 보내올 때 — DB에 넣을 미서명 /uploads/<파일명> 경로로 바꾼다.
 * 알아볼 수 없는 값(만료/위조 토큰, 다른 경로)이면 null.
 */
export function toStoredUploadUrl(url) {
  const raw = resolveRawUrl(url);
  return raw && /^\/uploads\/[^/\\]+$/.test(raw) ? raw : null;
}

/**
 * 이미 저장해 둔 파일을 다시 알아볼 때만 쓴다(예약 메시지 수정의 기존 첨부, 그룹 아이콘 그대로 저장) — 서명만
 * 맞으면 만료됐어도 원본 경로를 돌려준다. 화면이 몇 시간 들고 있던 DTO의 링크를 그대로 돌려보내도 같은 파일로
 * 알아보려는 것이라, 호출부는 결과를 반드시 "원래 저장돼 있던 경로"와 비교해서만 쓴다(새 파일은 toStoredUploadUrl).
 */
export function knownUploadPath(url) {
  if (typeof url !== 'string') return null;
  const match = /^\/files\/(.+)$/.exec(url);
  let raw = url;
  if (match) {
    try {
      raw = `/uploads/${path.basename(openFileToken(match[1], { ignoreExpiration: true }).file)}`;
    } catch {
      return null;
    }
  }
  return /^\/uploads\/[^/\\]+$/.test(raw) ? raw : null;
}

/** /files/:token 라우트에서 쓴다. 서명이 유효하고 만료 전이면 실제 파일 경로(+원본 파일명)를 돌려준다. */
export function resolveSignedFile(token) {
  const payload = openFileToken(token); // 위조·만료면 throw
  return {
    filePath: path.join(uploadsDir, path.basename(payload.file)),
    downloadName: typeof payload.downloadName === 'string' ? payload.downloadName : null,
  };
}

/** 업로드 파일명 문자셋 — stickers.js도 같은 값을 쓴다(위 upload 설정의 주석 참고). */
export const UPLOAD_FILENAME_CHARSET = 'utf8';

const storage = multer.diskStorage({
  destination: uploadsDir,
  filename: (req, file, cb) => {
    const ext = path.extname(file.originalname);
    cb(null, `${randomUUID()}${ext}`);
  },
});

const upload = multer({
  storage,
  // 멀티파트 스펙에 파일명 인코딩이 정해져 있지 않아서 busboy는 기본값 latin1로 읽는데,
  // 클라이언트(Dart http 패키지)는 파일명을 UTF-8 바이트 그대로 보낸다 — 그대로 두면 한글
  // 파일명이 깨진다. multer 2부터는 이 기본 문자셋을 직접 정할 수 있어서 UTF-8로 읽게 한다
  // (예전에는 latin1로 읽힌 이름을 다시 UTF-8로 되돌리는 우회 코드를 썼다).
  defParamCharset: UPLOAD_FILENAME_CHARSET,
  limits: { fileSize: 1024 * 1024 * 1024 }, // 1GB. 필요에 맞게 조절하세요.
});

export const uploadRouter = Router();

/**
 * 업로드 남용 막기 — 계정 하나가 파일을 계속 올려 디스크(또는 공유 폴더)를 가득 채우면 모두의 업로드와 DB까지
 * 멈춘다. 사람마다 하루 올릴 수 있는 양과 한 시간에 올릴 수 있는 개수를 두고, 디스크 여유가 바닥나면 받지 않는다.
 * 기록은 메모리에만 둔다(서버를 다시 켜면 처음부터) — 사고를 늦추는 게 목적이라 그걸로 충분하다.
 * 하루 한도는 .env의 UPLOAD_DAILY_LIMIT_GB로 바꿀 수 있다(기본 10GB).
 */
const UPLOAD_DAILY_LIMIT_BYTES = (Number(process.env.UPLOAD_DAILY_LIMIT_GB) || 10) * 1024 ** 3;
const UPLOAD_HOURLY_MAX_COUNT = 500;
const UPLOAD_MIN_FREE_BYTES = 2 * 1024 ** 3;
const uploadUsage = new Map(); // userId → { day, bytes, hourStart, count }

function usageFor(userId) {
  const now = Date.now();
  const day = new Date(now).toDateString();
  let u = uploadUsage.get(userId);
  if (!u || u.day !== day) {
    u = { day, bytes: 0, hourStart: now, count: 0 };
    uploadUsage.set(userId, u);
  }
  if (now - u.hourStart > 60 * 60 * 1000) {
    u.hourStart = now;
    u.count = 0;
  }
  return u;
}

async function uploadQuotaGuard(req, res, next) {
  const u = usageFor(req.user.sub);
  const incoming = Number(req.headers['content-length']) || 0;
  if (u.count >= UPLOAD_HOURLY_MAX_COUNT) {
    return res.status(429).json({ error: '파일을 너무 많이 올렸습니다. 잠시 뒤에 다시 시도하세요.' });
  }
  if (u.bytes + incoming > UPLOAD_DAILY_LIMIT_BYTES) {
    return res.status(429).json({ error: '오늘 올릴 수 있는 용량을 다 썼습니다. 내일 다시 시도하세요.' });
  }
  try {
    const stat = await fs.promises.statfs(uploadsDir);
    if (stat.bavail * stat.bsize - incoming < UPLOAD_MIN_FREE_BYTES) {
      return res.status(507).json({ error: '서버 저장 공간이 부족합니다. 관리자에게 알려 주세요.' });
    }
  } catch {
    // 여유 공간을 못 재는 저장소(일부 네트워크 드라이브)면 그냥 받는다.
  }
  u.count += 1;
  next();
}

/** 올리기가 끝난 뒤 실제 크기를 그 사람의 하루 사용량에 더한다. */
export function recordUploadedBytes(userId, bytes) {
  usageFor(userId).bytes += bytes;
}

uploadRouter.post('/upload', uploadQuotaGuard, upload.single('file'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: '파일이 없습니다.' });
  recordUploadedBytes(req.user.sub, req.file.size);

  // 응답의 url은 저장된 상대경로일 뿐, 그 자체로는 서빙되지 않는다(직접 공개 URL 금지).
  // 실제로 내려받을 땐 이 메시지/프로필이 요청될 때마다 signFileUrl로 새로 서명된
  // /files/<token> 경로가 쓰인다 — socket.js의 message:send, rooms.js의 메시지 조회,
  // users.js의 publicUser()를 보면 된다. signedUrl은 올린 사람이 저장 전에 바로 미리보기를
  // 그릴 수 있게 함께 주는 서명된 링크다(팀·그룹 아이콘 사진 — 저장할 땐 이걸 그대로
  // 보내도 서버가 toStoredUploadUrl로 미서명 경로로 되돌린다).
  const url = `/uploads/${req.file.filename}`;
  res.status(201).json({
    url,
    signedUrl: signFileUrl(url),
    fileName: req.file.originalname,
    size: req.file.size,
    mimeType: req.file.mimetype,
  });
});

/**
 * upload.single('file')이 용량 초과(LIMIT_FILE_SIZE) 등으로 던진 MulterError를 다른 API처럼
 * 깔끔한 JSON 에러로 바꿔준다 — 안 붙이면 Express 기본 에러 핸들러가 날것의 500/HTML을 보낸다.
 * server/src/index.js에서 uploadRouter 마운트 바로 뒤에 연결한다(라우터보다 뒤에 와야
 * Express가 이 4개 인자짜리 미들웨어를 에러 핸들러로 인식한다).
 */
export function uploadErrorHandler(err, req, res, next) {
  if (err instanceof multer.MulterError && err.code === 'LIMIT_FILE_SIZE') {
    return res.status(413).json({ error: '파일 크기가 너무 큽니다 (최대 1GB).' });
  }
  next(err);
}

/**
 * 서명된 다운로드 링크로만 파일을 내려받는다. 별도의 Authorization 헤더가 필요 없다 —
 * 토큰 자체가 "누가, 언제까지" 받을 수 있는지를 담고 있는 자격증명이다(presigned URL 방식).
 * requireAuth를 걸지 않는 이유도 이것 — 토큰 자체가 이미 인증/인가를 대신한다.
 */
export const filesRouter = Router();

/**
 * 브라우저가 화면에 바로 열어도 되는 형식(확장자 → Content-Type). 여기 없는 것(HTML·SVG·XML·JS 등)은 내용이
 * 무엇이든 application/octet-stream + attachment로만 내려준다 — 같은 주소에서 웹 앱이 돌고 있어서, 올린
 * HTML/SVG가 그 주소의 페이지로 열리면 안에 든 스크립트가 웹 앱의 로그인 토큰을 읽을 수 있다.
 */
const INLINE_TYPES = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.bmp': 'image/bmp',
  '.mp4': 'video/mp4',
  '.webm': 'video/webm',
  '.mov': 'video/quicktime',
  '.m4v': 'video/mp4',
  '.mp3': 'audio/mpeg',
  '.m4a': 'audio/mp4',
  '.wav': 'audio/wav',
  '.ogg': 'audio/ogg',
  '.pdf': 'application/pdf',
  '.txt': 'text/plain; charset=utf-8',
};

filesRouter.get('/files/:token', (req, res) => {
  let filePath, downloadName;
  try {
    ({ filePath, downloadName } = resolveSignedFile(req.params.token));
  } catch {
    return res.status(401).json({ error: '다운로드 링크가 만료되었거나 유효하지 않습니다.' });
  }
  const inlineType = INLINE_TYPES[path.extname(filePath).toLowerCase()];
  // 브라우저가 내용을 보고 형식을 추측하지 못하게 — 위 목록의 형식만 그 형식으로 열린다.
  res.setHeader('X-Content-Type-Options', 'nosniff');
  // sendFile은 Content-Type이 이미 있으면 확장자로 다시 정하지 않는다.
  res.setHeader('Content-Type', inlineType ?? 'application/octet-stream');
  const disposition = inlineType ? 'inline' : 'attachment';
  if (downloadName) {
    // 한글 등 비ASCII 파일명도 안전하게: ASCII 폴백 + RFC 5987 UTF-8 인코딩을 같이 준다.
    const asciiFallback = downloadName.replace(/[^\x20-\x7E]/g, '_').replace(/"/g, '');
    res.setHeader(
      'Content-Disposition',
      `${disposition}; filename="${asciiFallback}"; filename*=UTF-8''${encodeURIComponent(downloadName)}`,
    );
  } else {
    res.setHeader('Content-Disposition', disposition);
  }
  res.sendFile(filePath, (err) => {
    if (err && !res.headersSent) {
      // 위에서 파일용으로 붙인 형식·다운로드 헤더를 떼야 오류가 JSON으로 읽힌다.
      res.removeHeader('Content-Type');
      res.removeHeader('Content-Disposition');
      res.status(404).json({ error: '파일을 찾을 수 없습니다.' });
    }
  });
});
