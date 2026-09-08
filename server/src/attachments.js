import { Router } from 'express';
import { listAttachments } from './db/queries/messages.js';
import { toMessageDto } from './messages.js';

export const attachmentsRouter = Router();

/** files_screen.dart의 파일 형식 필터와 값이 일치해야 한다(client/lib/screens/files_screen.dart). */
const CATEGORY_MATCHERS = {
  image: (mime) => (mime ?? '').startsWith('image/'),
  pdf: (mime) => mime === 'application/pdf',
  document: (mime, name) =>
    /word|msword|text\/plain|hwp/i.test(mime ?? '') || /\.(docx?|hwpx?|txt|rtf)$/i.test(name ?? ''),
  excel: (mime, name) => /excel|spreadsheet/i.test(mime ?? '') || /\.(xlsx?|csv)$/i.test(name ?? ''),
  powerpoint: (mime, name) => /powerpoint|presentation/i.test(mime ?? '') || /\.(pptx?)$/i.test(name ?? ''),
  archive: (mime, name) => /zip|rar|7z|compressed/i.test(mime ?? '') || /\.(zip|rar|7z)$/i.test(name ?? ''),
  audio: (mime) => (mime ?? '').startsWith('audio/'),
};

/**
 * 방(들)에 첨부된 이미지/파일 목록 — search.js와 동일하게 내가 속한 방(비밀 대화 제외)으로만
 * 좁힌다. roomId를 안 주면 내가 속한 모든 방을 가로지른다. senderId/category(이미지/PDF/문서/
 * 엑셀/파워포인트/압축 파일/오디오)로 더 좁힐 수 있다(전부 선택적).
 */
attachmentsRouter.get('/attachments', async (req, res) => {
  const { roomId, senderId, category } = req.query;
  const limit = Math.min(Number(req.query.limit) || 500, 1000);

  const rows = await listAttachments({
    requesterId: req.user.sub,
    roomId: roomId || null,
    senderId: senderId || null,
    limit,
  });

  const matcher = category ? CATEGORY_MATCHERS[category] : null;
  const filtered = matcher ? rows.filter((m) => matcher(m.mimeType, m.fileName)) : rows;

  res.json(filtered.map(toMessageDto));
});
