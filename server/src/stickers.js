import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { Router } from 'express';
import multer from 'multer';
import { findUserById } from './db/queries/users.js';
import {
  addStickers,
  createStickerPack,
  findSticker,
  findStickerPack,
  listStickerPacks,
  updateSticker,
  updateStickerPack,
} from './db/queries/stickers.js';
import { signFileUrl, uploadsDir } from './upload.js';

/** 이모티콘으로 올릴 수 있는 그림 형식(움직이는 GIF 포함) — 확장자로 본다(앱의 업로드는 형식을
 * application/octet-stream으로 보내서, 보내온 형식 값은 믿을 수 없다). */
export const STICKER_MIME = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
};
const extOf = (name) => path.extname(name).toLowerCase();
const MAX_FILE_BYTES = 5 * 1024 * 1024;

const upload = multer({
  storage: multer.diskStorage({
    destination: uploadsDir,
    // 한글 파일명은 fileFilter(먼저 불린다)에서 이미 되돌려 놓았다.
    filename: (req, file, cb) => cb(null, `${randomUUID()}${extOf(file.originalname)}`),
  }),
  limits: { fileSize: MAX_FILE_BYTES, files: 200 },
  fileFilter: (req, file, cb) => {
    // upload.js와 같은 이유로 한글 파일명을 되돌린다(멀티파트 파일명은 latin1로 디코딩된다).
    file.originalname = Buffer.from(file.originalname, 'latin1').toString('utf8');
    cb(null, extOf(file.originalname) in STICKER_MIME);
  },
});

/** "1.jpg, 2.jpg, … 10.jpg"가 사람이 보는 순서대로 가게 숫자를 숫자로 비교한다. */
export const naturalCompare = (a, b) =>
  a.localeCompare(b, 'ko', { numeric: true, sensitivity: 'base' });

function stickerDto(s) {
  return {
    id: s.id,
    packId: s.packId,
    url: signFileUrl(s.fileUrl),
    fileName: s.fileName ?? null,
    mimeType: s.mimeType ?? null,
    hidden: s.hidden,
  };
}

function packDto(p) {
  return {
    id: p.id,
    name: p.name,
    hidden: p.hidden,
    deleted: !!p.deletedAt,
    stickers: (p.stickers ?? []).map(stickerDto),
  };
}

/**
 * 이모티콘(그림 스티커) API. 목록은 로그인한 누구나 받고(숨긴 것도 — 예전 메시지를 그리려고),
 * 세트 만들기·그림 올리기·숨기기는 서버 운영자만 한다(admin.js와 같은 isServerAdmin 기준).
 */
export function createStickersRouter() {
  const router = Router();

  const requireServerAdmin = async (req, res, next) => {
    const me = await findUserById(req.user.sub);
    if (!me || me.deletedAt || !me.isServerAdmin) {
      return res.status(403).json({ error: '서버 운영자만 이모티콘을 관리할 수 있습니다.' });
    }
    next();
  };

  router.get('/stickers', async (req, res) => {
    res.json((await listStickerPacks()).map(packDto));
  });

  router.post('/stickers/packs', requireServerAdmin, async (req, res) => {
    const name = typeof req.body?.name === 'string' ? req.body.name.trim() : '';
    if (!name) return res.status(400).json({ error: '세트 이름을 입력하세요.' });
    res.status(201).json(packDto(await createStickerPack(name)));
  });

  /** 세트 이름 바꾸기·숨기기(숨기면 선택창에서만 빠지고 예전 메시지는 그대로 보인다). */
  router.patch('/stickers/packs/:id', requireServerAdmin, async (req, res) => {
    const fields = {};
    if (typeof req.body?.name === 'string' && req.body.name.trim()) fields.name = req.body.name.trim();
    if (typeof req.body?.hidden === 'boolean') fields.hidden = req.body.hidden;
    const row = await updateStickerPack(req.params.id, fields);
    if (!row) return res.status(404).json({ error: '세트를 찾을 수 없습니다.' });
    res.json(packDto(row));
  });

  /** 세트 삭제 — 관리 화면과 선택창에서 없어진다. 이미 보낸 메시지가 그 그림을 가리키고 있어서
   * 행과 그림 파일은 남기고 표시만 한다(목록에는 deleted로 계속 내려가서 예전 메시지는 보인다). */
  router.delete('/stickers/packs/:id', requireServerAdmin, async (req, res) => {
    const row = await updateStickerPack(req.params.id, { deletedAt: new Date() });
    if (!row) return res.status(404).json({ error: '세트를 찾을 수 없습니다.' });
    res.json({ ok: true });
  });

  /** 그림 여러 장을 한 번에 세트 맨 뒤로 — 파일 이름 순서(1, 2, … 10)대로 붙인다. */
  router.post('/stickers/packs/:id/stickers', requireServerAdmin, upload.array('files'), async (req, res) => {
    const files = (req.files ?? []).slice().sort((a, b) => naturalCompare(a.originalname, b.originalname));
    const pack = await findStickerPack(req.params.id);
    if (!pack || pack.deletedAt) {
      for (const f of files) fs.rmSync(f.path, { force: true });
      return res.status(404).json({ error: '세트를 찾을 수 없습니다.' });
    }
    if (files.length === 0) {
      return res.status(400).json({ error: '올릴 그림이 없습니다(PNG·JPG·GIF·WEBP, 한 장 5MB 이하).' });
    }
    const rows = await addStickers(
      pack.id,
      files.map((f) => ({
        fileUrl: `/uploads/${f.filename}`,
        fileName: f.originalname,
        mimeType: STICKER_MIME[extOf(f.originalname)],
      })),
    );
    res.status(201).json(rows.map(stickerDto));
  });

  /** 한 장 숨기기/다시 보이기. */
  router.patch('/stickers/packs/:packId/stickers/:id', requireServerAdmin, async (req, res) => {
    const existing = await findSticker(req.params.packId, req.params.id);
    if (!existing) return res.status(404).json({ error: '이모티콘을 찾을 수 없습니다.' });
    if (typeof req.body?.hidden !== 'boolean') return res.status(400).json({ error: 'hidden 값이 필요합니다.' });
    res.json(stickerDto(await updateSticker(existing.id, { hidden: req.body.hidden })));
  });

  // multer가 던진 용량 초과 등을 JSON 오류로.
  router.use('/stickers', (err, req, res, next) => {
    if (err instanceof multer.MulterError) {
      const msg = err.code === 'LIMIT_FILE_SIZE' ? '그림 한 장은 5MB 이하여야 합니다.' : err.message;
      return res.status(400).json({ error: msg });
    }
    next(err);
  });

  return router;
}
