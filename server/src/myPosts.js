// 내가 쓴 글 모아보기 — 내가 직접 보낸 메시지(본문이나 제목이 있는 것)와 댓글을 키워드 없이 시간순으로 모아 준다.
// 내가 아직 멤버인 방의 글만이라 방을 나가면 그 방 글은 안 보이고, 비밀 대화(서버가 내용을 모른다)와 파일·이미지만 보낸 메시지는
// 빠진다. 순수 규칙은 myPostsRules.js, 조회는 db/queries/myPosts.js.
import { Router } from 'express';
import { listMyPostComments, listMyPostMessages } from './db/queries/myPosts.js';
import { isTeamMember } from './db/queries/teams.js';
import { mergeMyPosts, MY_POST_TEXT_PREVIEW, parentPreview, parseMyPostsQuery, previewText } from './myPostsRules.js';
import { roomDisplayName } from './rooms.js';

export function createMyPostsRouter() {
  const router = Router();

  router.get('/my-posts', async (req, res) => {
    const q = parseMyPostsQuery(req.query);
    if (q.error) return res.status(400).json({ error: q.error });
    if (!(await isTeamMember(q.teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    const me = req.user.sub;
    const [messageRows, commentRows] = await Promise.all([
      q.kind === 'comment' ? [] : listMyPostMessages(me, q),
      q.kind === 'message' ? [] : listMyPostComments(me, q),
    ]);

    const roomNames = new Map();
    async function roomFields(room) {
      if (!roomNames.has(room.id)) roomNames.set(room.id, await roomDisplayName(room, me));
      return { roomId: room.id, roomName: roomNames.get(room.id) ?? null, roomType: room.type, teamId: room.teamId };
    }
    const time = (d) => (d ? new Date(d).getTime() : null);

    // 합친 뒤 앞쪽 limit개만 남기므로, 각각 limit개까지만 DTO로 만든다(하나 더 받아 온 것은 hasMore 계산용).
    const messageItems = [];
    for (const r of messageRows.slice(0, q.limit)) {
      messageItems.push({
        kind: 'message',
        id: r.message.id,
        messageId: r.message.id,
        ...(await roomFields(r.room)),
        text: previewText(r.message.text, MY_POST_TEXT_PREVIEW),
        title: r.message.type === 'post' ? (r.message.title ?? null) : null,
        createdAt: Number(r.ms),
        editedAt: time(r.message.editedAt),
        parent: null,
      });
    }
    const commentItems = [];
    for (const r of commentRows.slice(0, q.limit)) {
      commentItems.push({
        kind: 'comment',
        id: r.comment.id,
        messageId: r.parent.id,
        ...(await roomFields(r.room)),
        text: previewText(r.comment.text, MY_POST_TEXT_PREVIEW),
        title: null,
        createdAt: Number(r.ms),
        editedAt: time(r.comment.editedAt),
        parent: parentPreview(r.parent),
      });
    }

    // 받아 온 개수가 limit 초과인 쪽이 있으면(잘라낸 게 있으면) 섞은 뒤에도 남는 게 있을 수 있으니 hasMore에 반영한다.
    const merged = mergeMyPosts([messageItems, commentItems], { limit: q.limit, order: q.order });
    const trimmed = messageRows.length > q.limit || commentRows.length > q.limit;
    const hasMore = merged.hasMore || trimmed;
    const last = merged.items[merged.items.length - 1];
    res.json({
      items: merged.items,
      hasMore,
      nextBefore: hasMore && last ? `${last.createdAt}:${last.id}` : null,
    });
  });

  return router;
}
