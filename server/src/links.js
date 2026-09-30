import { Router } from 'express';
import { listLinkMessages } from './db/queries/messages.js';
import { isTeamMember } from './db/queries/teams.js';
import { extractFirstUrl, extractUrls, linkRowMatchesQuery } from './linkPreview.js';

export const linksRouter = Router();

/** 글자 서식 구간([{s, e, f, h?}] — textFormat.js)에 걸린 http(s) 링크 주소들. */
function formatHrefs(textFormat) {
  if (!Array.isArray(textFormat)) return [];
  return textFormat
    .map((run) => run?.h)
    .filter((h) => typeof h === 'string' && /^https?:\/\//i.test(h));
}

/**
 * "링크" 모아보기 — 대화에서 주고받은 http(s) 링크를 최신순으로(잔디의 "링크" 메뉴와 같은 기능).
 * 메시지 하나에 링크가 여러 개면 링크마다 한 줄씩 펼친다. 본문에 그대로 쓴 주소와, 글자에 링크를
 * 건 주소(글자 서식)를 모두 모은다. 제목·이미지는 서버가 이미 받아 둔 링크 미리보기(메시지의
 * 첫 번째 주소에만 있다)를 쓰고, 없으면 클라이언트가 도메인으로 대신 보여준다. 파일 모아보기와
 * 같은 범위 — 지금 팀의 내가 속한 방(비밀 대화 제외), roomId/senderId로 더 좁힐 수 있다.
 * 링크 패널 상단의 검색칸·기간·정렬도 받는다: q(본문·주소·미리보기 제목 일부), since/until(밀리초),
 * order=desc|asc(기본 최신 순).
 */
linksRouter.get('/links', async (req, res) => {
  const { roomId, senderId, teamId, since, until } = req.query;
  const q = String(req.query.q ?? '').trim().toLowerCase();
  const order = req.query.order === 'asc' ? 'asc' : 'desc';
  const limit = Math.min(Number(req.query.limit) || 500, 1000);
  if (!teamId) return res.status(400).json({ error: 'teamId가 필요합니다.' });
  if (!(await isTeamMember(teamId, req.user.sub))) {
    return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
  }

  const rows = await listLinkMessages({
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

  const items = [];
  for (const m of rows) {
    const urls = [...new Set([...extractUrls(m.text), ...formatHrefs(m.textFormat)])];
    const previewUrl = extractFirstUrl(m.text);
    for (const url of urls) {
      const preview = url === previewUrl && m.linkPreviewUrl ? m : null;
      if (!linkRowMatchesQuery(q, { url, text: m.text, urls, title: preview?.linkPreviewTitle, siteName: preview?.linkPreviewSiteName })) {
        continue;
      }
      items.push({
        id: `${m.id}:${url}`,
        messageId: m.id,
        roomId: m.roomId,
        senderId: m.senderId,
        senderName: m.senderName,
        createdAt: new Date(m.createdAt).getTime(),
        url,
        title: preview?.linkPreviewTitle ?? null,
        imageUrl: preview?.linkPreviewImageUrl ?? null,
        siteName: preview?.linkPreviewSiteName ?? null,
      });
    }
  }
  res.json(items);
});
