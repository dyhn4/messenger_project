import { Router } from 'express';
import { readPostIdsOf } from './db/queries/board.js';
import { listCommentsForMessages } from './db/queries/comments.js';
import { listChangedMessagesForUser, listRemovalsForUser } from './db/queries/messageChanges.js';
import { listAttachmentsForMessages } from './db/queries/messages.js';
import { toCommentDto } from './comments.js';
import {
  changesHorizon,
  changesPageSize,
  formatChangesCursor,
  mergeChangePage,
  parseChangesCursor,
} from './messageChangeRules.js';
import { toMessageDto } from './messages.js';
import { attachPolls } from './polls.js';
import { attachReactions } from './reactions.js';

/**
 * "이후 바뀐 것" — 앱이 이 기기 메시지 DB(오프라인 보기)를 서버에 맞출 때 쓴다. 끊긴 동안·앱이 꺼져 있던 동안 새로 온 메시지는
 * 빠진 구간 메우기(방 목록의 마지막 활동 이후 페이지)로 받지만, 옛 메시지에 생긴 변화(수정·삭제·공감·댓글·투표·고정 등)는 그
 * 페이지를 다시 받기 전까지 몰랐다. 메시지가 보낸 뒤 바뀌면 DB 트리거가 changed_at을, 완전히 지우면 흔적(message_removals)을
 * 남기고(마이그레이션 0141), 여기서 내가 멤버인 평문 방 전체의 것을 커서 다음부터 한 페이지씩 준다(규칙 messageChangeRules.js).
 *
 * GET /api/message-changes?since=<커서>&limit=
 * → `{ messages: [방 메시지 목록과 같은 모양(댓글 포함)], removed: [{ id, roomId }], cursor, more }`. since가 없으면 지금 자리만
 * 준다(처음 — 막 받은 저장분은 맞출 것이 없다). more면 cursor로 바로 다음 페이지를, 아니면 cursor를 적어 두었다가 다음 연결 때.
 */
export function createMessageChangesRouter() {
  const router = Router();

  router.get('/message-changes', async (req, res) => {
    const until = changesHorizon(Date.now());
    const cursor = parseChangesCursor(req.query.since);
    if (cursor?.error) return res.status(400).json({ error: cursor.error });
    if (!cursor) return res.json({ messages: [], removed: [], cursor: formatChangesCursor(until), more: false });

    const me = req.user.sub;
    const limit = changesPageSize(req.query.limit);
    const window = { since: cursor.since, afterId: cursor.afterId, until, limit: limit + 1 };
    const [changedRows, removedRows] = await Promise.all([
      listChangedMessagesForUser(me, window),
      listRemovalsForUser(me, window),
    ]);
    const page = mergeChangePage(changedRows, removedRows, limit);

    // 방 메시지 목록(rooms.js GET /rooms/:id/messages)과 같은 모양 — 앱은 저장해 둔 것을 이것으로 통째로 바꾼다.
    const all = await attachReactions(await attachPolls(page.changed, me));
    const ids = all.map((m) => m.id);
    const [attachmentsByMessageId, comments, readIds] = await Promise.all([
      listAttachmentsForMessages(ids),
      listCommentsForMessages(ids),
      readPostIdsOf(me, all.filter((m) => m.type === 'post').map((m) => m.id)),
    ]);
    const commentsByMessageId = new Map();
    for (const c of comments) {
      const list = commentsByMessageId.get(c.messageId) ?? [];
      list.push(toCommentDto(c));
      commentsByMessageId.set(c.messageId, list);
    }
    res.json({
      messages: all.map((m) => ({
        ...toMessageDto({ ...m, attachments: attachmentsByMessageId[m.id] }),
        comments: commentsByMessageId.get(m.id) ?? [],
        outOfWindow: false,
        ...(m.type === 'post' ? { readByMe: m.senderId === me || readIds.has(m.id) } : {}),
      })),
      removed: page.removed.map((r) => ({ id: r.id, roomId: r.roomId })),
      // 다 받았으면 이번에 본 끝까지 — 그 앞의 것은 모두 받았다.
      cursor: page.cursor ?? formatChangesCursor(until),
      more: page.more,
    });
  });

  return router;
}
