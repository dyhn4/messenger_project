import { Router } from 'express';
import { listAttachments, listAttachmentsForMessages } from './db/queries/messages.js';
import { isTeamMember } from './db/queries/teams.js';
import { toMessageDto } from './messages.js';
import { matchesFileKind, parseFileKind } from './fileKinds.js';

export const attachmentsRouter = Router();

/**
 * 방(들)에 첨부된 이미지/파일 목록 — search.js와 동일하게 내가 속한 방(비밀 대화 제외)으로만
 * 좁힌다. roomId를 안 주면 내가 속한 모든 방을 가로지른다. senderId/category(이미지/PDF/문서/
 * 엑셀/파워포인트/동영상/오디오/압축 파일/기타 — fileKinds.js)로 더 좁힐 수 있다(전부 선택적).
 * 파일 패널 상단의 검색칸·기간·정렬도 여기서 받는다: q(파일 이름 일부), since/until(밀리초),
 * order=desc|asc(기본 최신 순).
 */
attachmentsRouter.get('/attachments', async (req, res) => {
  const { roomId, senderId, category, teamId, since, until } = req.query;
  const q = String(req.query.q ?? '').trim().toLowerCase();
  const order = req.query.order === 'asc' ? 'asc' : 'desc';
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
    since: since ? Number(since) : null,
    until: until ? Number(until) : null,
    q,
    order,
  });

  // 사진·파일 여러 개를 한 말풍선으로 보낸 메시지는 첨부마다 한 줄씩 펼친다 — 안 그러면
  // 첫 번째 첨부만 목록에 나온다. 펼친 줄도 메시지 id는 그대로라 "메시지 위치로 이동"이 된다.
  // 게시글('post')과 첨부를 붙인 투표('poll')는 첨부가 하나여도 펼친다 — 목록의 각 줄은 항상 'image'/'file'이어야 한다.
  const byMessage = await listAttachmentsForMessages(rows.map((m) => m.id));
  const items = rows.flatMap((m) => {
    // 파일 삭제로 자리만 남은 첨부(deletedAt)는 목록에서 뺀다.
    const list = byMessage[m.id]?.filter((a) => !a.deletedAt);
    const isCard = m.type === 'post' || m.type === 'poll';
    if (isCard && !list) return [];
    if (!list || (list.length < 2 && !isCard)) return [m];
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

  // 한 메시지에 첨부가 여러 개면 이름이 맞는 첨부만 남긴다(메시지 단위 SQL 조건은 "하나라도 맞는" 메시지까지만 거른다).
  const kind = parseFileKind(category);
  const filtered = items.filter(
    (m) =>
      (!kind || matchesFileKind(kind, m.mimeType, m.fileName)) &&
      (!q || (m.fileName ?? '').toLowerCase().includes(q)),
  );

  res.json(filtered.map(toMessageDto));
});
