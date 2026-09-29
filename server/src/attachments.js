import { Router } from 'express';
import { listAttachments, listAttachmentsForMessages } from './db/queries/messages.js';
import { isTeamMember } from './db/queries/teams.js';
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
  const { roomId, senderId, category, teamId } = req.query;
  const limit = Math.min(Number(req.query.limit) || 500, 1000);
  // 파일 목록도 검색과 마찬가지로 지금 보고 있는 팀 안에서만.
  if (!teamId) return res.status(400).json({ error: 'teamId가 필요합니다.' });
  if (!(await isTeamMember(teamId, req.user.sub))) {
    return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
  }

  const rows = await listAttachments({
    requesterId: req.user.sub,
    teamId,
    roomId: roomId || null,
    senderId: senderId || null,
    limit,
  });

  // 사진·파일 여러 개를 한 말풍선으로 보낸 메시지는 첨부마다 한 줄씩 펼친다 — 안 그러면
  // 첫 번째 첨부만 목록에 나온다. 펼친 줄도 메시지 id는 그대로라 "메시지 위치로 이동"이 된다.
  const byMessage = await listAttachmentsForMessages(rows.map((m) => m.id));
  const items = rows.flatMap((m) => {
    const list = byMessage[m.id];
    if (!list || list.length < 2) return [m];
    return list.map((a) => ({
      ...m,
      type: a.kind === 'image' ? 'image' : 'file',
      fileUrl: a.fileUrl,
      fileName: a.fileName,
      fileSize: a.fileSize,
      mimeType: a.mimeType,
      thumbnailUrl: a.thumbnailUrl,
      attachments: undefined,
    }));
  });

  const matcher = category ? CATEGORY_MATCHERS[category] : null;
  const filtered = matcher ? items.filter((m) => matcher(m.mimeType, m.fileName)) : items;

  res.json(filtered.map(toMessageDto));
});
