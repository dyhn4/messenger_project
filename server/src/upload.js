import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Router } from 'express';
import multer from 'multer';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const uploadsDir = path.join(__dirname, '..', 'uploads');

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

  res.status(201).json({
    url: `/uploads/${req.file.filename}`,
    fileName: req.file.originalname,
    size: req.file.size,
    mimeType: req.file.mimetype,
  });
});
