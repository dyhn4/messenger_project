import { Router } from 'express';
import { setPushWhileOnline, skipsPush } from './presence.js';
import {
  deleteMentionNotifications,
  deleteNotificationsForComment,
  deleteNotificationsForMessage,
  getNotificationSettingsMap,
  insertNotifications,
  listNotificationRows,
  markNotificationsRead,
  unreadCountsForUsers,
  upsertNotificationSettings,
} from './db/queries/notifications.js';
import { listMutedUserIdsForRoom, listRoomMemberUsers } from './db/queries/rooms.js';
import { findTeamById } from './db/queries/teams.js';
import {
  BOARD_LEVELS,
  DEFAULT_NOTIFICATION_SETTINGS,
  NOTIFICATION_GROUPS,
  boardRecipientsFor,
  diffMentions,
  mentionTargets,
  notificationPushBody,
  previewOf,
  pushTagSuffix,
  pushTargetsFor,
  roomNameForViewer,
  unreadCountsOf,
} from './notificationRules.js';
import { notifyRecordPush, previewFor, roomTagFor } from './push.js';

export { sanitizeMentions } from './notificationRules.js';

/**
 * 알림 기록(notifications 표) — 알림 센터의 "멘션"·"보드·공지" 탭이 읽는 받는 사람별 기록이다. 멘션(mention·mention_all)과
 * 보드 알림(board_post·board_edit·board_comment)이 같은 표·같은 생성 함수(createNotifications)를 쓴다. 프로젝트 알림은
 * 따로(projectNotify.js)이고 알림 센터의 "프로젝트" 탭이 그 API를 그대로 쓴다.
 *
 * 누구에게/무슨 종류로/푸시를 보낼지 같은 **규칙은 notificationRules.js**(순수 함수, 단위 시험 대상)에 있고, 여기는 그 결과로
 * 행을 넣고 소켓·푸시를 보내는 일을 한다.
 *
 * 소켓(user:<id>): notification:new { notification, unread:{mention,board,mentionPersonal,mentionAll} } — 새 알림 한 건과 새 안 읽음 수
 *                  (mention = 개인 멘션 + @all 합계),
 *                  notification:sync { mention, board, mentionPersonal, mentionAll } — 읽음·삭제로 안 읽음 수가 바뀌었을 때(다른 기기 동기화).
 */

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function toNotificationDto(row) {
  return {
    id: row.id,
    kind: row.kind,
    teamId: row.teamId,
    teamName: row.teamName ?? null,
    roomId: row.roomId ?? null,
    roomName: row.roomName ?? null,
    messageId: row.messageId ?? null,
    commentId: row.commentId ?? null,
    actorId: row.actorId ?? null,
    actorName: row.actorName ?? null,
    preview: row.preview ?? '',
    createdAt: new Date(row.createdAt).getTime(),
    readAt: row.readAt ? new Date(row.readAt).getTime() : null,
    roomType: row.roomType ?? null,
  };
}

/** 내 안 읽은 멘션·보드 알림 수 — 내 모든 팀 합계. {mention(=mentionPersonal+mentionAll), board, mentionPersonal, mentionAll} */
export async function unreadCounts(userId) {
  return (await unreadCountsForUsers([userId])).get(userId) ?? unreadCountsOf();
}

/** 안 읽음 수가 바뀐 사람들의 다른 기기에 새 수를 알린다(notification:sync). */
export async function syncUnread(io, userIds) {
  const ids = [...new Set(userIds)];
  if (ids.length === 0) return;
  const counts = await unreadCountsForUsers(ids);
  for (const id of ids) io.to(`user:${id}`).emit('notification:sync', counts.get(id));
}

/**
 * 알림 기록을 만드는 **유일한 지점** — 행을 한 번에 넣고(bulk insert), 받는 사람에게 소켓 notification:new를 보내고, 조건에
 * 맞는 사람에게만 푸시(push.js)를 보낸다. [recipients]에서 행위자 본인과 중복은 걷는다. 결과는 기록한 사람 수와
 * 푸시를 보낸(또는 보내기로 한) 사람 id — 같은 글의 일반 채팅 푸시에서 그 사람을 빼는 데 쓴다.
 *
 * kind: 'mention' | 'mention_all' | 'board_post' | 'board_edit' | 'board_comment'
 * actor: { id, name, user?(아바타 정보가 있는 users 행 — 푸시용) }. message: 알림이 가리키는 메시지(게시글·멘션된 메시지·
 * 댓글이 달린 원글). commentId: 댓글에 대한 알림이면 그 댓글 id. preview: 본문 앞부분(게시글이면 제목).
 */
export async function createNotifications({ io, kind, recipients, teamId, room, message, commentId = null, actor, preview }) {
  const ids = [...new Set(recipients)].filter((id) => id && id !== actor?.id);
  if (ids.length === 0) return { created: 0, pushedUserIds: [] };

  // 이름 없는 방은 보는 사람마다 이름이 달라서(DM=상대 이름, 이름 없는 그룹=나를 뺀 멤버) 멤버를 한 번만 읽어 둔다.
  const members = room.name || room.isSelf ? [] : await listRoomMemberUsers(room.id);
  const text = previewOf(preview);
  const inserted = await insertNotifications(
    ids.map((userId) => ({
      userId,
      teamId,
      kind,
      roomId: room.id,
      messageId: message?.id ?? null,
      commentId,
      actorId: actor?.id ?? null,
      actorName: actor?.name ?? null,
      preview: text,
      roomName: roomNameForViewer(room, members, userId),
    })),
  );

  const [counts, team] = await Promise.all([unreadCountsForUsers(ids), findTeamById(teamId)]);
  for (const row of inserted) {
    io.to(`user:${row.userId}`).emit('notification:new', {
      notification: toNotificationDto({ ...row, teamName: team?.name ?? null, roomType: room.type }),
      unread: counts.get(row.userId),
    });
  }

  const pushedUserIds = await pushFor({ kind, ids, room, actor, preview: text }).catch((err) => {
    console.error('[push] 알림 기록 푸시 실패:', err?.message ?? err);
    return [];
  });
  return { created: inserted.length, pushedUserIds };
}

/** 알림 기록을 남긴 사람 중 푸시 대상(뮤트·mentionAll 설정·온라인 여부 반영)에게 푸시를 보낸다 — 보낸 사람 id를 돌려준다. */
async function pushFor({ kind, ids, room, actor, preview }) {
  if (!pushTagSuffix(kind) || room.isSecret) return [];
  const mutedIds = kind === 'mention' ? new Set() : new Set(await listMutedUserIdsForRoom(room.id));
  const settings = kind === 'mention_all' ? await getNotificationSettingsMap(ids) : new Map();
  const targets = pushTargetsFor({
    kind,
    recipientIds: ids,
    mutedIds,
    settingsOf: (id) => settings.get(id),
    isOnline: skipsPush,
  });
  await notifyRecordPush({
    targets,
    room,
    sender: actor?.user ?? null,
    senderName: actor?.name ?? '알 수 없음',
    kind,
    conversationTag: pushTagSuffix(kind),
    body: notificationPushBody(kind, actor?.name, preview),
    roomTag: roomTagFor(room),
  });
  return targets;
}

/** 보드 뷰 토픽인지. */
export function isBoardRoom(room) {
  return room?.type === 'topic' && room.viewMode === 'board';
}

/** 글(메시지·게시글)·댓글을 막 만들었거나 고쳤을 때 알림에 쓰는 미리보기 — 게시글이면 제목, 아니면 본문. */
function previewSource(entry) {
  return entry.type === 'post' ? (entry.title ?? '') : entry.text || previewFor(entry);
}

/**
 * 새 글·댓글에 담긴 멘션마다 알림을 만든다 — 개인 멘션은 'mention', @all은 나머지 멤버에게 'mention_all'(개인 멘션을 받은
 * 사람은 중복해서 받지 않는다). [message]는 멘션된 메시지, 댓글이면 [comment]도 준다(알림은 원글 messageId + commentId를
 * 가리킨다). 돌려주는 것은 이 글로 알림을 받은 모든 사람([notifiedUserIds] — 보드 알림이 중복되지 않게 뺀다)과 푸시를 받을
 * 사람([pushedUserIds] — 일반 채팅 푸시에서 뺀다).
 */
export async function notifyMentions({ io, room, message, comment = null, actor, mentions, memberIds, before = null }) {
  const after = mentionTargets(mentions);
  const prev = mentionTargets(before);
  const entry = comment ?? message;
  const preview = previewSource(entry);
  const personal = after.userIds.filter((id) => id !== actor.id && !prev.userIds.includes(id));
  const allRecipients = after.all && !prev.all
    ? memberIds.filter((id) => id !== actor.id && !after.userIds.includes(id))
    : [];
  const notifiedUserIds = new Set();
  const pushedUserIds = new Set();
  for (const [kind, recipients] of [
    ['mention', personal],
    ['mention_all', allRecipients],
  ]) {
    if (recipients.length === 0) continue;
    const result = await createNotifications({
      io,
      kind,
      recipients,
      teamId: room.teamId,
      room,
      message,
      commentId: comment?.id ?? null,
      actor,
      preview,
    });
    recipients.forEach((id) => notifiedUserIds.add(id));
    result.pushedUserIds.forEach((id) => pushedUserIds.add(id));
  }
  return { notifiedUserIds: [...notifiedUserIds], pushedUserIds: [...pushedUserIds] };
}

/**
 * 글·댓글을 고쳤을 때 — 사라진 멘션의 알림 기록은 지우고(안 읽음 수가 바뀐 사람은 sync), 새로 생긴 멘션에만 알림을 보낸다.
 * 돌려주는 값은 notifyMentions와 같다.
 */
export async function updateMentions({ io, room, message, comment = null, actor, before, after, memberIds }) {
  const diff = diffMentions(before, after);
  if (diff.removedUserIds.length > 0 || diff.removedAll) {
    const affected = await deleteMentionNotifications({
      messageId: message.id,
      commentId: comment?.id ?? null,
      userIds: diff.removedUserIds,
      all: diff.removedAll,
    });
    await syncUnread(io, affected);
  }
  return notifyMentions({ io, room, message, comment, actor, mentions: after, memberIds, before });
}

// ── 보드 알림 ───────────────────────────────────────────────────────────

async function boardLevels(userIds) {
  const settings = await getNotificationSettingsMap(userIds);
  return (id) => settings.get(id)?.boardLevel ?? DEFAULT_NOTIFICATION_SETTINGS.boardLevel;
}

/**
 * 보드 뷰 토픽의 게시글 알림. event: 'post'(새 글 — 모든 수준) | 'edit'('all'만) | 'comment'(게시글의 댓글 — 'all'은 전원,
 * 'important'는 글쓴이만, 'new'는 없음). 받을 사람만 행을 만들고(한 번의 bulk insert), 같은 글로 멘션 알림을 받은 사람
 * ([excludeIds])은 뺀다. [post]는 게시글 행, 댓글이면 [comment]도 준다. 방을 뮤트한 멤버도 기록은 남는다(푸시는
 * notificationRules.js의 pushTargetsFor가 거른다).
 */
export async function notifyBoard({ io, event, room, post, comment = null, actor, memberIds, excludeIds = [] }) {
  if (!isBoardRoom(room)) return { created: 0 };
  const levelOf = await boardLevels(memberIds);
  const recipients = boardRecipientsFor({
    event,
    memberIds,
    actorId: actor.id,
    postAuthorId: post.senderId ?? null,
    levelOf,
    excludeIds,
  });
  const kind = event === 'post' ? 'board_post' : event === 'edit' ? 'board_edit' : 'board_comment';
  const entry = comment ?? post;
  const preview = event === 'comment' ? previewSource(entry) : (post.title ?? '');
  return createNotifications({
    io,
    kind,
    recipients,
    teamId: room.teamId,
    room,
    message: post,
    commentId: comment?.id ?? null,
    actor,
    preview,
  });
}

// ── 삭제 ────────────────────────────────────────────────────────────────

/** 메시지가 지워질 때(소프트·하드 모두) 그 메시지와 딸린 댓글의 알림 기록을 지우고 안 읽음 수가 바뀐 사람에게 알린다. */
export async function removeNotificationsForMessage(io, messageId) {
  await syncUnread(io, await deleteNotificationsForMessage(messageId));
}

export async function removeNotificationsForComment(io, commentId) {
  await syncUnread(io, await deleteNotificationsForComment(commentId));
}

/** 사용자가 그 방을 보고 있다(room:read) — 그 시각 이전의 멘션·보드 알림을 자동으로 읽음 처리하고 다른 기기에 알린다. */
export async function markRoomNotificationsRead(io, userId, roomId, atMs) {
  const changed = await markNotificationsRead({ userId, roomId, beforeMs: atMs });
  if (changed > 0) await syncUnread(io, [userId]);
}

export function createNotificationsRouter(io) {
  const router = Router();

  /**
   * 알림 목록 — kind=mention(개인 멘션+@all)|mention_personal|mention_all|board|all(생략=all), before(ms 커서),
   * limit(기본 30·최대 100), unreadOnly.
   */
  router.get('/notifications', async (req, res) => {
    const kind = typeof req.query.kind === 'string' && req.query.kind ? req.query.kind : 'all';
    if (kind !== 'all' && !NOTIFICATION_GROUPS.includes(kind)) {
      return res.status(400).json({ error: `kind는 ${[...NOTIFICATION_GROUPS, 'all'].join(', ')} 중 하나여야 합니다.` });
    }
    const before = req.query.before == null || req.query.before === '' ? null : Number(req.query.before);
    if (before !== null && !Number.isFinite(before)) return res.status(400).json({ error: 'before가 올바르지 않습니다.' });
    const limit = Math.min(100, Math.max(1, Math.trunc(Number(req.query.limit)) || 30));
    const rows = await listNotificationRows({
      userId: req.user.sub,
      group: kind === 'all' ? null : kind,
      before,
      limit: limit + 1,
      unreadOnly: req.query.unreadOnly === 'true',
    });
    res.json({ items: rows.slice(0, limit).map(toNotificationDto), hasMore: rows.length > limit });
  });

  router.get('/notifications/unread-counts', async (req, res) => {
    res.json(await unreadCounts(req.user.sub));
  });

  /** 읽음 처리 — { ids: [...] } 또는 { kind: 'mention'|'mention_personal'|'mention_all'|'board' } 또는 { messageId }. */
  router.post('/notifications/read', async (req, res) => {
    const body = req.body ?? {};
    const userId = req.user.sub;
    if (Array.isArray(body.ids)) {
      const ids = body.ids.filter((id) => typeof id === 'string' && UUID_RE.test(id));
      if (ids.length > 0) await markNotificationsRead({ userId, ids });
    } else if (typeof body.kind === 'string') {
      if (!NOTIFICATION_GROUPS.includes(body.kind)) {
        return res.status(400).json({ error: `kind는 ${NOTIFICATION_GROUPS.join(', ')} 중 하나여야 합니다.` });
      }
      await markNotificationsRead({ userId, group: body.kind });
    } else if (typeof body.messageId === 'string') {
      if (!UUID_RE.test(body.messageId)) return res.status(400).json({ error: 'messageId가 올바르지 않습니다.' });
      await markNotificationsRead({ userId, messageId: body.messageId });
    } else {
      return res.status(400).json({ error: 'ids, kind, messageId 중 하나를 보내세요.' });
    }
    // 바뀐 개수와 상관없이 항상 새 수를 알린다 — 다른 기기가 어긋나 있었어도 여기서 맞춰진다.
    await syncUnread(io, [userId]);
    res.json({ ok: true });
  });

  async function settingsFor(userId) {
    return { ...DEFAULT_NOTIFICATION_SETTINGS, ...(await getNotificationSettingsMap([userId])).get(userId) };
  }

  router.get('/notification-settings', async (req, res) => {
    res.json(await settingsFor(req.user.sub));
  });

  router.patch('/notification-settings', async (req, res) => {
    const body = req.body ?? {};
    const patch = {};
    if ('mentionAll' in body) {
      if (typeof body.mentionAll !== 'boolean') return res.status(400).json({ error: 'mentionAll은 true/false여야 합니다.' });
      patch.mentionAll = body.mentionAll;
    }
    if ('boardLevel' in body) {
      if (!BOARD_LEVELS.includes(body.boardLevel)) {
        return res.status(400).json({ error: `boardLevel은 ${BOARD_LEVELS.join(', ')} 중 하나여야 합니다.` });
      }
      patch.boardLevel = body.boardLevel;
    }
    if ('pushWhileOnline' in body) {
      if (typeof body.pushWhileOnline !== 'boolean') {
        return res.status(400).json({ error: 'pushWhileOnline은 true/false여야 합니다.' });
      }
      patch.pushWhileOnline = body.pushWhileOnline;
    }
    if (Object.keys(patch).length === 0) return res.json(await settingsFor(req.user.sub));
    const saved = await upsertNotificationSettings(req.user.sub, patch);
    // 접속해 있는 동안 바꿔도 다음 푸시부터 바로 따르게(presence.js는 접속할 때 이 값을 읽어 둔다).
    setPushWhileOnline(req.user.sub, saved.pushWhileOnline);
    res.json(saved);
  });

  return router;
}
