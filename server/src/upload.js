import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Router } from 'express';
import jwt from 'jsonwebtoken';
import multer from 'multer';
import { JWT_SECRET } from './config.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const uploadsDir = path.join(__dirname, '..', 'uploads');

// 업로드된 파일은 더 이상 고정된 공개 경로(/uploads/xxx)로 직접 서빙하지 않는다. 대신 매번
// 짧게 만료되는 서명 URL(/files/<token>)을 만들어서 응답에 넣는다 — 그 URL을 아는 사람만,
// 그것도 발급된 지 얼마 안 됐을 때만 파일을 받을 수 있다.
//
// 만료를 "지금부터 N분"이 아니라 1시간 단위 버킷으로 묶는 이유: 같은 파일(예: 프로필
// 사진)에 대해 같은 시간대 안에서는 항상 같은 토큰이 나오게 해서, Flutter의 이미지 캐시가
// URL이 바뀔 때마다(=매번 새로 서명될 때마다) 매번 다시 내려받는 걸 막기 위함이다.
const BUCKET_MS = 60 * 60 * 1000;
const VALID_BUCKETS = 2; // 현재 버킷 + 다음 버킷까지, 즉 최대 2시간 후 만료.

/** 저장된 상대경로(/uploads/xxx)를 짧게 만료되는 서명 다운로드 경로(/files/<token>)로 바꾼다. */
export function signFileUrl(relativeUrl) {
  if (!relativeUrl) return relativeUrl;
  const filename = path.basename(relativeUrl); // 경로 조작 방지
  const bucketStart = Math.floor(Date.now() / BUCKET_MS) * BUCKET_MS;
  const exp = Math.floor((bucketStart + VALID_BUCKETS * BUCKET_MS) / 1000);
  const token = jwt.sign({ file: filename, type: 'file', exp }, JWT_SECRET, { noTimestamp: true });
  return `/files/${token}`;
}

/** /files/:token 라우트에서 쓴다. 서명이 유효하고 만료 전이면 실제 파일 경로를 돌려준다. */
export function resolveSignedFile(token) {
  const payload = jwt.verify(token, JWT_SECRET); // 서명/만료 실패 시 throw
  if (payload.type !== 'file' || typeof payload.file !== 'string') {
    throw new Error('invalid file token');
  }
  return path.join(uploadsDir, path.basename(payload.file));
}

const storage = multer.diskStorage({
  destination: uploadsDir,
  filename: (req, file, cb) => {
    // 멀티파트 스펙에 파일명 인코딩이 정해져 있지 않아서, busboy가 헤더를 기본값인 latin1로
    // 디코딩한다. 클라이언트(Dart http 패키지)는 파일명을 UTF-8 바이트 그대로 보내므로
    // 한글 등 비ASCII 파일명이 깨져 들어온다 — latin1로 다시 인코딩해서 원래 UTF-8 바이트로
    // 되돌린다(흔히 알려진 멀티파트 업로드 한글 깨짐 문제의 표준적인 해결법).
    file.originalname = Buffer.from(file.originalname, 'latin1').toString('utf8');
    const ext = path.extname(file.originalname);
    cb(null, `${randomUUID()}${ext}`);
  },
});

const upload = multer({
  storage,
  limits: { fileSize: 200 * 1024 * 1024 }, // 200MB. 필요에 맞게 조절하세요.
});

export const uploadRouter = Router();

uploadRouter.post('/upload', upload.single('file'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: '파일이 없습니다.' });

  // 응답의 url은 저장된 상대경로일 뿐, 그 자체로는 서빙되지 않는다(직접 공개 URL 금지).
  // 실제로 내려받을 땐 이 메시지/프로필이 요청될 때마다 signFileUrl로 새로 서명된
  // /files/<token> 경로가 쓰인다 — socket.js의 message:send, rooms.js의 메시지 조회,
  // users.js의 publicUser()를 보면 된다.
  res.status(201).json({
    url: `/uploads/${req.file.filename}`,
    fileName: req.file.originalname,
    size: req.file.size,
    mimeType: req.file.mimetype,
  });
});

/**
 * 서명된 다운로드 링크로만 파일을 내려받는다. 별도의 Authorization 헤더가 필요 없다 —
 * 토큰 자체가 "누가, 언제까지" 받을 수 있는지를 담고 있는 자격증명이다(presigned URL 방식).
 * requireAuth를 걸지 않는 이유도 이것 — 토큰 자체가 이미 인증/인가를 대신한다.
 */
export const filesRouter = Router();

filesRouter.get('/files/:token', (req, res) => {
  let filePath;
  try {
    filePath = resolveSignedFile(req.params.token);
  } catch {
    return res.status(401).json({ error: '다운로드 링크가 만료되었거나 유효하지 않습니다.' });
  }
  res.sendFile(filePath, (err) => {
    if (err && !res.headersSent) res.status(404).json({ error: '파일을 찾을 수 없습니다.' });
  });
});
