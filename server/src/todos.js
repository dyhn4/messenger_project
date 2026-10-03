import { Router } from 'express';
import { topicAccess } from './access.js';
import { findCommentById } from './db/queries/comments.js';
import { findMessageById } from './db/queries/messages.js';
import { findRoomById, isRoomMember, listMutedUserIdsForRoom, listRoomMemberIds } from './db/queries/rooms.js';
import { isTeamMember } from './db/queries/teams.js';
import {
  claimDueTodoReminders,
  deleteTodo,
  findTodoById,
  insertTodo,
  listAssigneesForTodos,
  listAttachmentsForTodos,
  listRemindersForTodos,
  listTodoAssigneeIds,
  listTodoAttachmentRows,
  listTodoReminderRows,
  listTodos,
  listTodosByIds,
  listUsersByIds,
  updateTodo,
} from './db/queries/todos.js';
import { findUserById } from './db/queries/users.js';
import { topicWriteDenial } from './permissions.js';
import { isOnline } from './presence.js';
import { notifyRecordPush, roomTagFor } from './push.js';
import { roomDisplayName } from './rooms.js';
import {
  checkDateOrder,
  isUuid,
  newlyAssigned,
  nextCompletedAt,
  parseAttachments,
  parseTodoCreate,
  parseTodoListQuery,
  parseTodoPatch,
  patchDenial,
  planReminders,
  pushTargets,
  reminderTargets,
  shouldDeliverReminder,
  statusOf,
  todoPermissions,
  todoRole,
} from './todoRules.js';
import { signFileUrl } from './upload.js';

const ms = (d) => (d ? new Date(d).getTime() : null);

/** 할 일 DTO에 싣는 사람 정보 — 이메일 복호화 같은 무거운 값 없이 아바타 그리기에 필요한 것만. */
function toTodoUser(u) {
  return {
    id: u.id,
    name: u.name ?? u.username ?? '알 수 없음',
    avatarType: u.avatarType ?? 'initial',
    avatarEmoji: u.avatarEmoji ?? null,
    avatarColor: u.avatarColor ?? null,
    avatarUrl: u.avatarUrl ? signFileUrl(u.avatarUrl) : null,
  };
}

/**
 * 할 일 행들을 보는 사람([viewerId]) 기준 DTO로 — 담당자·첨부·알림·만든 사람·방 이름을 한 번씩만 조회한다.
 * myRole/canEdit/canManage는 보는 사람마다 달라서 여기서 계산한다(소켓으로 모두에게 같은 DTO를 뿌리지 않는 이유).
 */
export async function loadTodoDtos(rows, viewerId) {
  if (rows.length === 0) return [];
  const ids = rows.map((r) => r.id);
  const [assigneeRows, attachmentRows, reminderRows] = await Promise.all([
    listAssigneesForTodos(ids),
    listAttachmentsForTodos(ids),
    listRemindersForTodos(ids),
  ]);
  const creatorIds = [...new Set(rows.map((r) => r.creatorId).filter(Boolean))];
  const creators = new Map((await listUsersByIds(creatorIds)).map((u) => [u.id, u]));
  const roomNames = new Map();
  for (const roomId of new Set(rows.map((r) => r.roomId))) {
    const room = await findRoomById(roomId);
    roomNames.set(roomId, room ? await roomDisplayName(room, viewerId) : null);
  }

  return rows.map((t) => {
    const assignees = assigneeRows.filter((a) => a.todoId === t.id).map((a) => toTodoUser(a.user));
    const role = todoRole({ creatorId: t.creatorId, assigneeIds: assignees.map((a) => a.id), userId: viewerId });
    const { canEdit, canManage } = todoPermissions({ role, creatorId: t.creatorId });
    const creator = t.creatorId ? creators.get(t.creatorId) : null;
    return {
      id: t.id,
      teamId: t.teamId,
      roomId: t.roomId,
      roomName: roomNames.get(t.roomId) ?? null,
      title: t.title,
      description: t.description ?? null,
      startDate: t.startDate ?? null,
      dueDate: t.dueDate ?? null,
      progress: t.progress,
      status: statusOf(t.progress),
      completedAt: ms(t.completedAt),
      creator: creator ? toTodoUser(creator) : null,
      assignees,
      attachments: attachmentRows
        .filter((a) => a.todoId === t.id)
        .map((a) => ({
          id: a.id,
          kind: a.kind,
          fileUrl: signFileUrl(a.fileUrl, a.fileName),
          fileName: a.fileName ?? null,
          fileSize: a.fileSize ?? null,
          mimeType: a.mimeType ?? null,
          thumbnailUrl: signFileUrl(a.thumbnailUrl),
        })),
      reminders: reminderRows
        .filter((r) => r.todoId === t.id)
        .map((r) => ({ id: r.id, remindAt: ms(r.remindAt), sent: !!r.sentAt })),
      sourceMessageId: t.sourceMessageId ?? null,
      sourceCommentId: t.sourceCommentId ?? null,
      myRole: role,
      canEdit,
      canManage,
      createdAt: ms(t.createdAt),
      updatedAt: ms(t.updatedAt),
    };
  });
}

/**
 * 할 일 — 만들기·목록(나의/부여한/팀)·상세·수정·삭제와 알림 일정 작업(startTodoReminderJob).
 * 모든 조회·변경은 "그 대화방의 멤버"여야 하고, 할 일은 만든 뒤 다른 대화방으로 옮길 수 없다. 프로젝트의 업무(tasks)와는 별개다.
 */
export function createTodosRouter(io) {
  const router = Router();

  /** 변경 소식을 그 방 멤버 전원의 개인 룸(user:<id>)으로 — 열려 있는 할 일 패널이 새로 고친다. */
  async function emitChanged(todo, kind, extra = {}) {
    const memberIds = await listRoomMemberIds(todo.roomId);
    const payload = { teamId: todo.teamId, roomId: todo.roomId, todoId: todo.id, kind, ...extra };
    for (const id of memberIds) io.to(`user:${id}`).emit('todo:changed', payload);
  }

  /** 담당자로 지정된 사람에게 푸시 — 소켓이 붙어 있는 사람은 todo:changed로 앱이 토스트를 띄우므로 뺀다. */
  async function pushAssigned({ todo, room, actor, userIds }) {
    if (userIds.length === 0) return;
    const targets = pushTargets(userIds, {
      actorId: actor.id,
      onlineIds: new Set(userIds.filter((id) => isOnline(id))),
      mutedIds: new Set(await listMutedUserIdsForRoom(room.id)),
    });
    if (targets.length === 0) return;
    await notifyRecordPush({
      targets,
      room,
      sender: actor,
      senderName: actor.name ?? actor.username ?? '알 수 없음',
      kind: 'todo',
      conversationTag: '할 일',
      body: `할 일이 지정되었습니다: ${todo.title}`,
      roomTag: roomTagFor(room),
    });
  }

  /** 할 일 행 + 방 + 내 역할까지 — 방 멤버가 아니면 403을 보내고 null. */
  async function requireTodo(req, res) {
    const todo = isUuid(req.params.id) ? await findTodoById(req.params.id) : null;
    if (!todo) {
      res.status(404).json({ error: '할 일을 찾을 수 없습니다.' });
      return null;
    }
    const room = await findRoomById(todo.roomId);
    if (!room || !(await isRoomMember(room.id, req.user.sub))) {
      res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
      return null;
    }
    const assigneeIds = await listTodoAssigneeIds(todo.id);
    const role = todoRole({ creatorId: todo.creatorId, assigneeIds, userId: req.user.sub });
    return { todo, room, assigneeIds, role };
  }

  /** [ids]가 전부 이 방의 멤버인지 — 아니면 에러 문구. */
  async function assigneeError(room, ids) {
    if (ids.length === 0) return null;
    const members = new Set(await listRoomMemberIds(room.id));
    return ids.every((id) => members.has(id)) ? null : '이 대화방의 멤버만 담당자로 지정할 수 있습니다.';
  }

  router.post('/rooms/:roomId/todos', async (req, res) => {
    const room = await findRoomById(req.params.roomId);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    const me = req.user.sub;
    if (!(await isRoomMember(room.id, me))) {
      return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    }
    // 서버가 내용을 볼 수 없는 비밀 대화에는 둘 수 없고, 읽기 전용·보관 토픽은 글쓰기와 같게 토픽 관리자만 만든다.
    if (room.isSecret) return res.status(400).json({ error: '비밀 대화에서는 할 일을 만들 수 없습니다.' });
    if (room.type === 'topic' && (room.readOnly || room.archivedAt)) {
      const denial = topicWriteDenial({ room, canManage: (await topicAccess(room, me)).canManage });
      if (denial) return res.status(403).json({ error: denial.replace('글을 쓸', '할 일을 만들') });
    }

    const input = parseTodoCreate(req.body);
    if (input.error) return res.status(400).json({ error: input.error });
    const memberError = await assigneeError(room, input.assigneeIds);
    if (memberError) return res.status(400).json({ error: memberError });

    // "메시지·댓글에서 할 일로 등록"의 출처 — 이 방의, 지워지지 않은 글이어야 한다(다른 방 글을 끌어다 붙이지 못하게).
    let sourceMessageId = input.sourceMessageId;
    let sourceCommentId = input.sourceCommentId;
    if (sourceCommentId) {
      const comment = await findCommentById(sourceCommentId);
      if (!comment || comment.deletedAt || comment.roomId !== room.id) {
        return res.status(400).json({ error: '원본 댓글을 찾을 수 없습니다.' });
      }
      if (sourceMessageId && sourceMessageId !== comment.messageId) {
        return res.status(400).json({ error: '원본 댓글과 메시지가 맞지 않습니다.' });
      }
      sourceMessageId = comment.messageId;
    } else if (sourceMessageId) {
      const message = await findMessageById(sourceMessageId);
      if (!message || message.deletedAt || message.roomId !== room.id) {
        return res.status(400).json({ error: '원본 메시지를 찾을 수 없습니다.' });
      }
    }

    const row = await insertTodo({
      todo: {
        teamId: room.teamId,
        roomId: room.id,
        creatorId: me,
        title: input.title,
        description: input.description,
        startDate: input.startDate,
        dueDate: input.dueDate,
        sourceMessageId,
        sourceCommentId,
      },
      assigneeIds: input.assigneeIds,
      attachments: input.attachments,
      reminderTimes: input.reminders,
    });

    const actor = await findUserById(me);
    const added = newlyAssigned([], input.assigneeIds, me);
    await emitChanged(row, 'created', { actorId: me, title: row.title, addedAssigneeIds: added });
    pushAssigned({ todo: row, room, actor, userIds: added }).catch((e) =>
      console.error('[todos] 담당자 푸시 실패:', e?.message ?? e),
    );
    const [dto] = await loadTodoDtos([row], me);
    res.status(201).json(dto);
  });

  router.get('/todos', async (req, res) => {
    const q = parseTodoListQuery(req.query);
    if (q.error) return res.status(400).json({ error: q.error });
    const me = req.user.sub;
    if (!(await isTeamMember(q.teamId, me))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    const rows = await listTodos({ userId: me, ...q });
    const hasMore = rows.length > q.limit;
    res.json({ items: await loadTodoDtos(rows.slice(0, q.limit), me), hasMore });
  });

  router.get('/todos/:id', async (req, res) => {
    const ctx = await requireTodo(req, res);
    if (!ctx) return;
    const [dto] = await loadTodoDtos([ctx.todo], req.user.sub);
    res.json(dto);
  });

  router.patch('/todos/:id', async (req, res) => {
    const ctx = await requireTodo(req, res);
    if (!ctx) return;
    const { todo, room, assigneeIds: currentAssignees, role } = ctx;
    const me = req.user.sub;

    const parsed = parseTodoPatch(req.body);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const { fields } = parsed;
    // 권한은 값 검사보다 먼저 — 남이 보낸 잘못된 값의 내용까지 알려줄 필요가 없다.
    const denial = patchDenial(role, todo.creatorId, Object.keys(fields));
    if (denial) return res.status(denial.status).json({ error: denial.error });

    // 시작일/종료일은 둘 중 하나만 보내도 저장된 다른 쪽과 순서를 맞춰 본다.
    const startDate = 'startDate' in fields ? fields.startDate : todo.startDate;
    const dueDate = 'dueDate' in fields ? fields.dueDate : todo.dueDate;
    const orderError = checkDateOrder(startDate, dueDate);
    if (orderError) return res.status(400).json({ error: orderError });

    let attachments;
    if (fields.attachments !== undefined) {
      const existing = (await listTodoAttachmentRows(todo.id)).map((a) => a.fileUrl);
      const r = parseAttachments(fields.attachments, existing);
      if (r.error) return res.status(400).json({ error: r.error });
      attachments = r.value;
    }

    let reminderPlan;
    if (fields.reminders !== undefined) {
      const existing = (await listTodoReminderRows(todo.id)).map((r) => ({
        id: r.id,
        remindAt: new Date(r.remindAt).getTime(),
        sent: !!r.sentAt,
      }));
      reminderPlan = planReminders(existing, fields.reminders);
      if (reminderPlan.error) return res.status(400).json({ error: reminderPlan.error });
    }

    if (fields.assigneeIds !== undefined) {
      const memberError = await assigneeError(room, fields.assigneeIds);
      if (memberError) return res.status(400).json({ error: memberError });
    }

    const columns = {};
    for (const key of ['title', 'description', 'startDate', 'dueDate']) {
      if (key in fields) columns[key] = fields[key];
    }
    if (fields.progress !== undefined) {
      columns.progress = fields.progress;
      columns.completedAt = nextCompletedAt(fields.progress, todo.completedAt);
    }

    const row = await updateTodo(todo.id, {
      fields: columns,
      assigneeIds: fields.assigneeIds,
      attachments,
      reminderPlan,
    });
    if (!row) return res.status(404).json({ error: '할 일을 찾을 수 없습니다.' });

    const added = fields.assigneeIds ? newlyAssigned(currentAssignees, fields.assigneeIds, me) : [];
    await emitChanged(row, 'updated', { actorId: me, title: row.title, addedAssigneeIds: added });
    if (added.length > 0) {
      const actor = await findUserById(me);
      pushAssigned({ todo: row, room, actor, userIds: added }).catch((e) =>
        console.error('[todos] 담당자 푸시 실패:', e?.message ?? e),
      );
    }
    const [dto] = await loadTodoDtos([row], me);
    res.json(dto);
  });

  router.delete('/todos/:id', async (req, res) => {
    const ctx = await requireTodo(req, res);
    if (!ctx) return;
    const { todo, role } = ctx;
    if (!todoPermissions({ role, creatorId: todo.creatorId }).canManage) {
      return res.status(403).json({ error: '할 일을 만든 사람만 삭제할 수 있습니다.' });
    }
    if (!(await deleteTodo(todo.id))) return res.status(404).json({ error: '할 일을 찾을 수 없습니다.' });
    await emitChanged(todo, 'deleted', { actorId: req.user.sub, title: todo.title });
    res.json({ ok: true });
  });

  return router;
}

// ── 알림 일정 ───────────────────────────────────────────────────────────

const REMINDER_SWEEP_INTERVAL_MS = 60 * 1000;

/**
 * 보낼 때가 된 알림을 한 번 훑는다. 알림을 먼저 찜(sentAt 기록)한 뒤에 보내므로 중복 발송이 없고, 발송 도중 실패해도
 * 다시 폭주하지 않는다. 이미 완료된 할 일·너무 오래 묵은 알림은 찜만 하고 보내지 않는다. 받는 사람은 담당자들(없으면
 * 만든 사람) — 소켓 todo:reminder는 모두에게, 푸시는 소켓이 안 붙은 사람에게만.
 */
export async function sweepTodoReminders(io, now = new Date()) {
  const claimed = await claimDueTodoReminders(now);
  if (claimed.length === 0) return 0;
  const todoRows = new Map((await listTodosByIds([...new Set(claimed.map((c) => c.todoId))])).map((t) => [t.id, t]));
  const assigneeRows = await listAssigneesForTodos([...todoRows.keys()]);
  let delivered = 0;
  for (const reminder of claimed) {
    const todo = todoRows.get(reminder.todoId);
    if (!todo) continue;
    const remindAt = new Date(reminder.remindAt).getTime();
    if (!shouldDeliverReminder({ progress: todo.progress, remindAt, now: now.getTime() })) continue;
    const assigneeIds = assigneeRows.filter((a) => a.todoId === todo.id).map((a) => a.user.id);
    const targets = reminderTargets(assigneeIds, todo.creatorId);
    if (targets.length === 0) continue;
    const room = await findRoomById(todo.roomId);
    if (!room) continue;
    delivered += 1;
    const payload = {
      teamId: todo.teamId,
      roomId: todo.roomId,
      todoId: todo.id,
      title: todo.title,
      dueDate: todo.dueDate ?? null,
      remindAt,
    };
    for (const id of targets) io.to(`user:${id}`).emit('todo:reminder', payload);
    const pushIds = pushTargets(targets, {
      onlineIds: new Set(targets.filter((id) => isOnline(id))),
      mutedIds: new Set(await listMutedUserIdsForRoom(room.id)),
    });
    if (pushIds.length > 0) {
      notifyRecordPush({
        targets: pushIds,
        room,
        sender: null,
        senderName: '할 일 알림',
        kind: 'todo_reminder',
        conversationTag: '할 일',
        body: todo.dueDate ? `${todo.title} (기한 ${todo.dueDate.replaceAll('-', '/')})` : todo.title,
        roomTag: roomTagFor(room),
      }).catch((e) => console.error('[todos] 알림 푸시 실패:', e?.message ?? e));
    }
  }
  return delivered;
}

/** 서버 시작 시 한 번, 이후 1분마다 보낼 때가 된 할 일 알림을 보낸다(startProjectDueReminderJob과 같은 구조). */
export function startTodoReminderJob(io) {
  const run = () => sweepTodoReminders(io).catch((e) => console.error('[todos] 알림 일정 처리 실패:', e));
  run();
  setInterval(run, REMINDER_SWEEP_INTERVAL_MS);
}
