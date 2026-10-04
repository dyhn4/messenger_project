import { Router } from 'express';
import { topicAccess } from './access.js';
import { findCommentById } from './db/queries/comments.js';
import { findMessageById, listAttachmentsForMessages } from './db/queries/messages.js';
import { findRoomById, isRoomMember, listMutedUserIdsForRoom, listRoomMemberIds } from './db/queries/rooms.js';
import { isTeamMember } from './db/queries/teams.js';
import {
  claimDueTodoReminders,
  countTodos,
  deleteTodo,
  deleteTodoComment,
  findTodoById,
  findTodoCommentById,
  insertTodo,
  insertTodoComment,
  listAssigneesForTodos,
  listAttachmentsForTodos,
  listCommentsForTodo,
  listFavoriteTodoIds,
  listRemindersForTodos,
  listTodoAssigneeIds,
  listTodoAttachmentRows,
  listTodoReminderRows,
  listTodos,
  listTodosByIds,
  listUsersByIds,
  setTodoFavorite,
  TodoProgressDeniedError,
  updateTodo,
  updateTodoCommentText,
} from './db/queries/todos.js';
import { findUserById } from './db/queries/users.js';
import { canModifyContent } from './moderation.js';
import { topicWriteDenial } from './permissions.js';
import { isOnline } from './presence.js';
import { notifyRecordPush, roomTagFor } from './push.js';
import { roomDisplayName } from './rooms.js';
import {
  isUuid,
  mergeTodoPeriod,
  myProgressOf,
  newlyAssigned,
  parseAttachments,
  parseTodoCreate,
  parseTodoListQuery,
  parseTodoPatch,
  patchDenial,
  planReminders,
  progressTarget,
  pushTargets,
  reminderTargets,
  shouldDeliverReminder,
  sourceFilePaths,
  statusOf,
  storedAttachmentPaths,
  todoPermissions,
  todoRole,
  todoRoomError,
} from './todoRules.js';
import { signFileUrl } from './upload.js';

const ms = (d) => (d ? new Date(d).getTime() : null);

function toCommentDto(row, roomId) {
  return { ...row, roomId, createdAt: ms(row.createdAt), editedAt: ms(row.editedAt) };
}

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
 * 할 일 행들을 보는 사람([viewerId]) 기준 DTO로 — 담당자·첨부·알림·즐겨찾기·만든 사람·방 이름을 한 번씩만 조회한다.
 * myRole/canEdit/canManage/myProgress/favorite는 보는 사람마다 달라서 여기서 계산한다(소켓으로 모두에게 같은 DTO를
 * 뿌리지 않는 이유). progress/status/completedAt은 전체(집계) 값이고, 담당자마다의 값은 assignees[]에 있다.
 */
export async function loadTodoDtos(rows, viewerId) {
  if (rows.length === 0) return [];
  const ids = rows.map((r) => r.id);
  const [assigneeRows, attachmentRows, reminderRows, favoriteIds] = await Promise.all([
    listAssigneesForTodos(ids),
    listAttachmentsForTodos(ids),
    listRemindersForTodos(ids),
    listFavoriteTodoIds(ids, viewerId),
  ]);
  const creatorIds = [...new Set(rows.map((r) => r.creatorId).filter(Boolean))];
  const creators = new Map((await listUsersByIds(creatorIds)).map((u) => [u.id, u]));
  const roomNames = new Map();
  for (const roomId of new Set(rows.map((r) => r.roomId))) {
    const room = await findRoomById(roomId);
    roomNames.set(roomId, room ? await roomDisplayName(room, viewerId) : null);
  }

  return rows.map((t) => {
    const assignees = assigneeRows
      .filter((a) => a.todoId === t.id)
      .map((a) => ({
        ...toTodoUser(a.user),
        progress: a.progress,
        status: statusOf(a.progress),
        completedAt: ms(a.completedAt),
      }));
    const role = todoRole({ creatorId: t.creatorId, assigneeIds: assignees.map((a) => a.id), userId: viewerId });
    const { canEdit, canManage } = todoPermissions({ role, creatorId: t.creatorId });
    const myProgress = myProgressOf({
      creatorId: t.creatorId,
      assignees: assignees.map((a) => ({ userId: a.id, progress: a.progress })),
      progress: t.progress,
      userId: viewerId,
    });
    const creator = t.creatorId ? creators.get(t.creatorId) : null;
    return {
      id: t.id,
      teamId: t.teamId,
      roomId: t.roomId,
      roomName: roomNames.get(t.roomId) ?? null,
      title: t.title,
      description: t.description ?? null,
      startDate: t.startDate ?? null,
      // 'HH:mm'(그 날짜의 벽시계 시각) — 날짜가 없으면 늘 null.
      startTime: t.startTime ?? null,
      dueDate: t.dueDate ?? null,
      dueTime: t.dueTime ?? null,
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
      // 내 진척률 — 담당자면 내 담당 행, 담당자가 없고 만든 사람이면 할 일 값, 그 밖은 null(바꿀 수 없음).
      myProgress,
      canSetProgress: myProgress !== null,
      favorite: favoriteIds.has(t.id),
      createdAt: ms(t.createdAt),
      updatedAt: ms(t.updatedAt),
    };
  });
}

/**
 * 할 일 — 만들기·목록(나의/부여한/모든 할 일, 기간)·상세·수정(담당자마다 따로인 진척률)·삭제·즐겨찾기와 알림 일정 작업
 * (startTodoReminderJob). 모든 조회·변경은 "그 대화방의 멤버"여야 하고, 할 일은 만든 뒤 다른 대화방으로 옮길 수 없다.
 * 프로젝트의 업무(tasks)와는 별개다.
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

  /** 댓글 소식(새 댓글·수정·삭제)을 그 방 멤버 전원의 개인 룸으로 — 할 일 상세를 열어 둔 사람이 바로 받는다. */
  async function emitComment(todo, event, payload) {
    for (const id of await listRoomMemberIds(todo.roomId)) io.to(`user:${id}`).emit(event, payload);
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

  /**
   * "메시지·댓글에서 할 일로 등록"의 출처 — 이 방의, 지워지지 않은 글이어야 한다(다른 방 글을 끌어다 붙이지 못하게).
   * `{ sourceMessageId, sourceCommentId, filePaths }` 또는 `{ error, filePaths: [] }`를 돌려준다. filePaths는 그 원본 글에
   * 지금 붙어 있는 파일 경로들(sourceFilePaths) — 오래전에 불러온 메시지라 첨부의 서명 링크가 만료됐어도 그 파일이면 받도록
   * 첨부 검사(parseTodoCreate)에 넘긴다. id가 uuid가 아니면 찾지 않는다(그 거절은 parseTodoCreate가 한다).
   */
  async function loadTodoSource(room, body) {
    const messageId = isUuid(body?.sourceMessageId) ? body.sourceMessageId : null;
    const commentId = isUuid(body?.sourceCommentId) ? body.sourceCommentId : null;
    if (commentId) {
      const comment = await findCommentById(commentId);
      if (!comment || comment.deletedAt || comment.roomId !== room.id) {
        return { error: '원본 댓글을 찾을 수 없습니다.', filePaths: [] };
      }
      if (messageId && messageId !== comment.messageId) {
        return { error: '원본 댓글과 메시지가 맞지 않습니다.', filePaths: [] };
      }
      return { sourceMessageId: comment.messageId, sourceCommentId: commentId, filePaths: sourceFilePaths({ comment }) };
    }
    if (messageId) {
      const message = await findMessageById(messageId);
      if (!message || message.deletedAt || message.roomId !== room.id) {
        return { error: '원본 메시지를 찾을 수 없습니다.', filePaths: [] };
      }
      const attachments = (await listAttachmentsForMessages([message.id]))[message.id] ?? [];
      return { sourceMessageId: messageId, sourceCommentId: null, filePaths: sourceFilePaths({ message, attachments }) };
    }
    return { sourceMessageId: null, sourceCommentId: null, filePaths: [] };
  }

  router.post('/rooms/:roomId/todos', async (req, res) => {
    const room = await findRoomById(req.params.roomId);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    const me = req.user.sub;
    if (!(await isRoomMember(room.id, me))) {
      return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    }
    // 서버가 내용을 볼 수 없는 비밀 대화와 보드 뷰 토픽(잔디: 챗 뷰 토픽·채팅에서만)에는 만들 수 없고, 읽기 전용·보관
    // 토픽은 글쓰기와 같게 토픽 관리자만 만든다. 이미 있는 할 일의 조회·수정은 그대로 된다.
    const roomError = todoRoomError(room);
    if (roomError) return res.status(400).json({ error: roomError });
    if (room.type === 'topic' && (room.readOnly || room.archivedAt)) {
      const denial = topicWriteDenial({ room, canManage: (await topicAccess(room, me)).canManage });
      if (denial) return res.status(403).json({ error: denial.replace('글을 쓸', '할 일을 만들') });
    }

    // 출처 글은 본문 검사보다 먼저 찾아 둔다 — 그 글에 붙어 있는 파일은 첨부 서명이 만료됐어도 알아보게(다른 파일은 그대로
    // 거절). 출처가 잘못됐다는 거절은 예전처럼 본문·담당자 검사 뒤에 한다.
    const source = await loadTodoSource(room, req.body);
    const input = parseTodoCreate(req.body, Date.now(), source.filePaths);
    if (input.error) return res.status(400).json({ error: input.error });
    const memberError = await assigneeError(room, input.assigneeIds);
    if (memberError) return res.status(400).json({ error: memberError });
    if (source.error) return res.status(400).json({ error: source.error });
    const { sourceMessageId, sourceCommentId } = source;

    const row = await insertTodo({
      todo: {
        teamId: room.teamId,
        roomId: room.id,
        creatorId: me,
        title: input.title,
        description: input.description,
        startDate: input.startDate,
        startTime: input.startTime,
        dueDate: input.dueDate,
        dueTime: input.dueTime,
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
    // total = 같은 조건(scope·방·담당자·기간·완료 제외)에 맞는 전체 개수 — offset/limit와 무관(앱의 "N개의 할 일").
    const [rows, total] = await Promise.all([listTodos({ userId: me, ...q }), countTodos({ userId: me, ...q })]);
    const hasMore = rows.length > q.limit;
    res.json({ items: await loadTodoDtos(rows.slice(0, q.limit), me), hasMore, total });
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
    // progress는 "내 진척률" — 이번 수정을 마친 뒤의 담당자 목록 기준으로, 내가 담당자면 내 담당 행, 담당자가 없고
    // 내가 만든 사람이면 할 일 값(todos.progress)에 쓴다. 그 밖은 만든 사람이라도 403. 여기서는 빨리 거절하려고 요청
    // 전에 읽은 담당자로 한 번 보고, 실제로 쓸 곳은 updateTodo가 할 일 행을 잠근 뒤 다시 정한다(그새 바뀌었으면 403).
    const target =
      fields.progress !== undefined
        ? progressTarget({ creatorId: todo.creatorId, assigneeIds: fields.assigneeIds ?? currentAssignees, userId: me })
        : null;
    // 권한은 값 검사보다 먼저 — 남이 보낸 잘못된 값의 내용까지 알려줄 필요가 없다.
    const denial = patchDenial(role, todo.creatorId, Object.keys(fields), target);
    if (denial) return res.status(denial.status).json({ error: denial.error });

    // 기간(시작일·시작 시간·종료일·종료 시간)은 일부만 보내도 저장된 나머지와 합쳐 순서를 본다 — 날짜를 지우면 그 시간도
    // 함께 지우고, 날짜 없이 시간만 남게 되면 400.
    const period = mergeTodoPeriod(todo, fields);
    if (period.error) return res.status(400).json({ error: period.error });

    let attachments;
    if (fields.attachments !== undefined) {
      // 이 할 일에 저장된 첨부의 원본·미리보기 경로 — 화면이 오래 들고 있던(서명이 만료된) 링크로 기존 첨부를 돌려보내도
      // 같은 파일로 알아본다(미리보기도 넣어야 기존 사진의 미리보기가 조용히 null로 저장되지 않는다).
      const existing = storedAttachmentPaths(await listTodoAttachmentRows(todo.id));
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

    const columns = { ...period.columns };
    for (const key of ['title', 'description']) {
      if (key in fields) columns[key] = fields[key];
    }
    // 담당자 진척률은 그 사람 행만, 담당자 없는 할 일은 예전처럼 할 일 값 — 전체 진척률은 updateTodo가 다시 맞춘다.
    const progressWrite = fields.progress !== undefined ? { userId: me, progress: fields.progress } : undefined;

    let row;
    try {
      row = await updateTodo(todo.id, {
        fields: columns,
        assigneeIds: fields.assigneeIds,
        attachments,
        reminderPlan,
        progressWrite,
      });
    } catch (e) {
      if (e instanceof TodoProgressDeniedError) return res.status(403).json({ error: e.message });
      throw e;
    }
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

  // 댓글 — 공지 댓글(announcements.js)과 같은 모양. 그 방 멤버면 누구나 읽고 쓴다(수정·삭제 없음). 새 댓글은 그 방 멤버
  // 전원의 개인 룸으로 — 할 일 상세를 열어 둔 사람이 바로 받는다.
  router.get('/todos/:id/comments', async (req, res) => {
    const ctx = await requireTodo(req, res);
    if (!ctx) return;
    const rows = await listCommentsForTodo(ctx.todo.id);
    res.json(rows.map((r) => toCommentDto(r, ctx.todo.roomId)));
  });

  router.post('/todos/:id/comments', async (req, res) => {
    const ctx = await requireTodo(req, res);
    if (!ctx) return;
    const { todo } = ctx;
    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    if (!text) return res.status(400).json({ error: '댓글 내용을 입력하세요.' });
    if (text.length > 1000) return res.status(400).json({ error: '댓글은 1000자 이내로 작성하세요.' });

    const me = await findUserById(req.user.sub);
    const row = await insertTodoComment({
      todoId: todo.id,
      authorId: req.user.sub,
      authorName: me?.name ?? me?.username ?? '알 수 없음',
      text,
    });
    const dto = toCommentDto(row, todo.roomId);
    await emitComment(todo, 'todo:comment:new', dto);
    res.status(201).json(dto);
  });

  /** 할 일 댓글 수정·삭제의 공통 — 이 할 일의 댓글인지까지 확인한다. 없으면 404를 보내고 null. */
  async function requireTodoComment(req, res) {
    const ctx = await requireTodo(req, res);
    if (!ctx) return null;
    const comment = isUuid(req.params.commentId) ? await findTodoCommentById(req.params.commentId) : null;
    if (!comment || comment.todoId !== ctx.todo.id) {
      res.status(404).json({ error: '댓글을 찾을 수 없습니다.' });
      return null;
    }
    return { ...ctx, comment };
  }

  /** 수정은 작성자만, 삭제는 작성자와 관리자(팀 관리자·토픽 관리자) — 시간 제한 없음(moderation.js isSimpleComment). */
  function canModifyComment(req, todo, comment, action) {
    return canModifyContent({
      roomId: todo.roomId,
      senderId: comment.authorId,
      createdAt: comment.createdAt,
      requesterId: req.user.sub,
      action,
      noun: '댓글',
      isSimpleComment: true,
    });
  }

  router.patch('/todos/:id/comments/:commentId', async (req, res) => {
    const ctx = await requireTodoComment(req, res);
    if (!ctx) return;
    const { todo, comment } = ctx;
    const verdict = await canModifyComment(req, todo, comment, 'edit');
    if (!verdict.ok) return res.status(verdict.status).json({ error: verdict.error });
    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    if (!text) return res.status(400).json({ error: '댓글 내용을 입력하세요.' });
    if (text.length > 1000) return res.status(400).json({ error: '댓글은 1000자 이내로 작성하세요.' });

    const updated = await updateTodoCommentText(comment.id, text);
    if (!updated) return res.status(404).json({ error: '댓글을 찾을 수 없습니다.' });
    const dto = toCommentDto(updated, todo.roomId);
    await emitComment(todo, 'todo:comment:edited', dto);
    res.json(dto);
  });

  router.delete('/todos/:id/comments/:commentId', async (req, res) => {
    const ctx = await requireTodoComment(req, res);
    if (!ctx) return;
    const { todo, comment } = ctx;
    const verdict = await canModifyComment(req, todo, comment, 'delete');
    if (!verdict.ok) return res.status(verdict.status).json({ error: verdict.error });
    await deleteTodoComment(comment.id);
    await emitComment(todo, 'todo:comment:deleted', { id: comment.id, todoId: todo.id, roomId: todo.roomId });
    res.json({ ok: true });
  });

  // 즐겨찾기(별) — 사람마다 따로. 켜기는 그 방 멤버만, 끄기는 권한을 보지 않는다(방을 나간 뒤에도 내 표시는 지울 수
  // 있게 — 행만 지우고, 없어도 200). 내 다른 기기만 알면 되므로 소켓은 내 user:<me>에만 보낸다(끄기는 실제로 지운
  // 행이 있을 때만 — 멤버가 아닌 사람에게 남의 할 일이 어느 방 것인지 알려주지 않게).
  router.put('/todos/:id/favorite', async (req, res) => {
    const favorite = req.body?.favorite;
    if (typeof favorite !== 'boolean') return res.status(400).json({ error: 'favorite는 true/false여야 합니다.' });
    const me = req.user.sub;
    let todo;
    if (favorite) {
      const ctx = await requireTodo(req, res);
      if (!ctx) return;
      todo = ctx.todo;
    } else {
      todo = isUuid(req.params.id) ? await findTodoById(req.params.id) : null;
    }
    if (todo) {
      const changed = await setTodoFavorite(todo.id, me, favorite);
      if (favorite || changed) {
        io.to(`user:${me}`).emit('todo:changed', {
          teamId: todo.teamId,
          roomId: todo.roomId,
          todoId: todo.id,
          kind: 'favorite',
          actorId: me,
          favorite,
        });
      }
    }
    res.json({ favorite });
  });

  return router;
}

// ── 알림 일정 ───────────────────────────────────────────────────────────

const REMINDER_SWEEP_INTERVAL_MS = 60 * 1000;

/**
 * 보낼 때가 된 알림을 한 번 훑는다. 알림을 먼저 찜(sentAt 기록)한 뒤에 보내므로 중복 발송이 없고, 발송 도중 실패해도
 * 다시 폭주하지 않는다. 이미 완료된(집계 100) 할 일·너무 오래 묵은 알림은 찜만 하고 보내지 않는다. 받는 사람은 아직
 * 다 하지 않은(진척률 100 미만) 담당자들(담당자가 없으면 만든 사람) — 소켓 todo:reminder는 모두에게, 푸시는 소켓이
 * 안 붙은 사람에게만.
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
    const assignees = assigneeRows
      .filter((a) => a.todoId === todo.id)
      .map((a) => ({ userId: a.user.id, progress: a.progress }));
    const targets = reminderTargets(assignees, todo.creatorId);
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
      dueTime: todo.dueTime ?? null,
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
        body: todo.dueDate
          ? `${todo.title} (기한 ${todo.dueDate.replaceAll('-', '/')}${todo.dueTime ? ` ${todo.dueTime}` : ''})`
          : todo.title,
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
