import { and, asc, count, desc, eq, exists, inArray, isNull, lte, ne, notExists, or, sql } from 'drizzle-orm';
import { alias } from 'drizzle-orm/pg-core';
import {
  diffAssignees,
  nextCompletedAt,
  progressPerspective,
  progressResync,
  progressTarget,
  TODO_PROGRESS_DENIED,
} from '../../todoRules.js';
import { db } from '../client.js';
import { roomMembers, todoAssignees, todoAttachments, todoFavorites, todoReminders, todos, users } from '../schema.js';

// 할 일(todos.js)의 쿼리 모음. 할 일·담당자·첨부·알림은 항상 같이 움직여서 쓰기는 트랜잭션 하나로 묶는다.

// 목록 조건의 "그 방에 아직 있는 담당자" 판단용 별칭 — 바깥 쿼리의 room_members(보는 사람의 멤버십)와 섞이지 않게.
const assigneeMember = alias(roomMembers, 'assignee_member');
// 목록의 "기준 진척률"을 읽는 담당 행(progressPerspective의 사람) 별칭.
const refAssignee = alias(todoAssignees, 'ref_assignee');

export async function findTodoById(id) {
  const [row] = await db.select().from(todos).where(eq(todos.id, id));
  return row ?? null;
}

/** 담당자 id — 그 방에 아직 있는 사람만(방을 나간 사람은 담당 행이 남아 있어도 담당자로 치지 않는다). */
export async function listTodoAssigneeIds(todoId) {
  const rows = await db
    .select({ userId: todoAssignees.userId })
    .from(todoAssignees)
    .innerJoin(todos, eq(todos.id, todoAssignees.todoId))
    .innerJoin(roomMembers, and(eq(roomMembers.roomId, todos.roomId), eq(roomMembers.userId, todoAssignees.userId)))
    .where(eq(todoAssignees.todoId, todoId));
  return rows.map((r) => r.userId);
}

export function listTodoAttachmentRows(todoId) {
  return db.select().from(todoAttachments).where(eq(todoAttachments.todoId, todoId)).orderBy(asc(todoAttachments.position));
}

export function listTodoReminderRows(todoId) {
  return db.select().from(todoReminders).where(eq(todoReminders.todoId, todoId)).orderBy(asc(todoReminders.remindAt));
}

function attachmentValues(todoId, attachments) {
  return attachments.map((a, position) => ({
    todoId,
    kind: a.kind,
    fileUrl: a.fileUrl,
    fileName: a.fileName,
    fileSize: a.fileSize,
    mimeType: a.mimeType,
    thumbnailUrl: a.thumbnailUrl,
    position,
  }));
}

/** 할 일 한 건을 담당자·첨부·알림까지 한 번에 만든다. [todo]는 todos 행에 넣을 값, [reminderTimes]는 ms 배열. */
export function insertTodo({ todo, assigneeIds, attachments, reminderTimes }) {
  return db.transaction(async (tx) => {
    const [row] = await tx.insert(todos).values(todo).returning();
    if (assigneeIds.length > 0) {
      await tx.insert(todoAssignees).values(assigneeIds.map((userId) => ({ todoId: row.id, userId })));
    }
    if (attachments.length > 0) await tx.insert(todoAttachments).values(attachmentValues(row.id, attachments));
    if (reminderTimes.length > 0) {
      await tx.insert(todoReminders).values(reminderTimes.map((ms) => ({ todoId: row.id, remindAt: new Date(ms) })));
    }
    return row;
  });
}

/** 할 일의 담당 행 중 그 방에 아직 있는 사람들의 `{ userId, progress }` — 트랜잭션([executor]) 안에서 읽는다. */
function inRoomAssigneeRows(executor, row) {
  return executor
    .select({ userId: todoAssignees.userId, progress: todoAssignees.progress })
    .from(todoAssignees)
    .innerJoin(roomMembers, and(eq(roomMembers.roomId, row.roomId), eq(roomMembers.userId, todoAssignees.userId)))
    .where(eq(todoAssignees.todoId, row.id));
}

/**
 * todos.progress·completed_at(전체 진척률)을 다시 맞춘다(todoRules.progressResync) — 그 방에 있는 담당자([after], 안 주면
 * 여기서 읽는다)가 있으면 그들의 집계, 없으면 만든 사람이 직접 바꾸는 값이라 그대로 두되, [before](이번 변경 바로 전에 그
 * 방에 있던 담당자들)가 있었으면 마지막 담당자가 빠진 것이라 S3 규칙의 값(orphanedProgress)을 이어받는다. 이미 맞으면 쓰지
 * 않는다. [row]는 이 트랜잭션에서 잠근 todos 행, 돌려주는 값은 맞춘 뒤의 행(바꿨으면 새 행, 그대로면 [row] 자신).
 */
async function syncAggregateProgress(tx, row, { before = null, after = null } = {}) {
  const next = progressResync(row, { before, after: after ?? (await inRoomAssigneeRows(tx, row)) });
  if (!next) return row;
  const [updated] = await tx.update(todos).set(next).where(eq(todos.id, row.id)).returning();
  return updated ?? row;
}

/** updateTodo가 할 일 행을 잠근 뒤 다시 봤더니 진척률을 쓸 곳이 없을 때 — 수정 전체가 되돌려지고 todos.js가 403으로 바꾼다. */
export class TodoProgressDeniedError extends Error {
  constructor() {
    super(TODO_PROGRESS_DENIED);
    this.name = 'TodoProgressDeniedError';
  }
}

/**
 * 할 일 수정 — [fields]는 todos 행에 바로 쓸 컬럼들(updatedAt은 여기서 찍는다), [attachments]는 주면 통째로 바꾸고
 * (undefined면 그대로), [reminderPlan]은 todoRules.planReminders의 결과다. 시각이 바뀐 알림은 보낸 기록(sentAt)을 지운다.
 * [assigneeIds]는 주면 차이만 반영한다(빠진 사람 행 삭제·새 사람 진척률 0으로 추가·남는 사람 행은 그대로 — 진척률 보존).
 * 그래서 (그 방에 있는) 담당자가 하나도 남지 않게 되면 할 일 값은 S3 규칙(todoRules.orphanedProgress — 바로 전까지 만든
 * 사람도 담당자였으면 그 사람의 진척률, 아니면 직전 집계를 가장 가까운 단계로)으로 이어받는다.
 * [progressWrite] `{ userId, progress }`는 그 사람의 "내 진척률" — 어디에 쓸지(progressTarget: 내 담당 행 / 담당자 없는
 * 할 일 값)는 할 일 행을 잠근 뒤, 이번 수정까지 반영한 (그 방에 있는) 담당자로 정하고, 쓸 곳이 없으면
 * TodoProgressDeniedError를 던져 수정 전체를 되돌린다. 끝에서는 늘 전체 진척률을 다시 맞춘다(담당자가 있으면 그 방에 있는
 * 담당자들로). 맨 먼저 todos 행을 고쳐 잠그고 판단은 모두 잠근 뒤의 값으로 하므로, 같은 할 일을 동시에 고치는 요청(과 방
 * 멤버가 바뀔 때의 resyncTodoProgressForMembers)은 차례로 처리되고, 요청 전에 읽은 담당자 목록이 그새 바뀌었어도 집계가
 * 어긋나지 않는다.
 */
export function updateTodo(id, { fields = {}, assigneeIds, attachments, reminderPlan, progressWrite }) {
  return db.transaction(async (tx) => {
    let [row] = await tx
      .update(todos)
      .set({ ...fields, updatedAt: new Date() })
      .where(eq(todos.id, id))
      .returning();
    if (!row) return null;
    if (assigneeIds !== undefined) {
      // 바뀌기 전에 그 방에 있던 담당자(진척률 포함) — 이번 수정으로 하나도 남지 않게 되면 S3 규칙의 기준이 된다.
      const inRoomBefore = await inRoomAssigneeRows(tx, row);
      const stored = await tx
        .select({ userId: todoAssignees.userId })
        .from(todoAssignees)
        .where(eq(todoAssignees.todoId, id));
      const { removed, added } = diffAssignees(stored.map((r) => r.userId), assigneeIds);
      if (removed.length > 0) {
        await tx.delete(todoAssignees).where(and(eq(todoAssignees.todoId, id), inArray(todoAssignees.userId, removed)));
      }
      if (added.length > 0) {
        await tx
          .insert(todoAssignees)
          .values(added.map((userId) => ({ todoId: id, userId })))
          .onConflictDoNothing();
      }
      // 마지막 담당자가 빠졌으면 여기서 S3 규칙의 값을 이어받는다 — 같은 요청에 진척률도 있으면(이제 담당자 없는 할 일이라
      // 할 일 값에 쓴다) 아래에서 그 값이 덮어쓴다.
      row = await syncAggregateProgress(tx, row, { before: inRoomBefore });
    }
    if (progressWrite) {
      const { userId, progress } = progressWrite;
      const inRoomIds = (await inRoomAssigneeRows(tx, row)).map((r) => r.userId);
      const target = progressTarget({ creatorId: row.creatorId, assigneeIds: inRoomIds, userId });
      if (!target) throw new TodoProgressDeniedError();
      if (target === 'assignee') {
        const mine = and(eq(todoAssignees.todoId, id), eq(todoAssignees.userId, userId));
        const [prev] = await tx.select({ completedAt: todoAssignees.completedAt }).from(todoAssignees).where(mine);
        await tx
          .update(todoAssignees)
          .set({ progress, completedAt: nextCompletedAt(progress, prev?.completedAt ?? null), updatedAt: new Date() })
          .where(mine);
      } else {
        // 담당자 없는 할 일 — 완료 시각은 잠근 행의 값으로 정한다(요청 전에 읽은 값은 그새 바뀌었을 수 있다).
        [row] = await tx
          .update(todos)
          .set({ progress, completedAt: nextCompletedAt(progress, row.completedAt) })
          .where(eq(todos.id, id))
          .returning();
      }
    }
    // 무엇을 고쳤든 마지막에 한 번 — 담당자가 있는데 집계가 어긋나 있으면(어떤 경로로든) 여기서 바로잡힌다.
    row = await syncAggregateProgress(tx, row);
    if (attachments !== undefined) {
      await tx.delete(todoAttachments).where(eq(todoAttachments.todoId, id));
      if (attachments.length > 0) await tx.insert(todoAttachments).values(attachmentValues(id, attachments));
    }
    if (reminderPlan) {
      if (reminderPlan.deleteIds.length > 0) {
        await tx.delete(todoReminders).where(inArray(todoReminders.id, reminderPlan.deleteIds));
      }
      for (const u of reminderPlan.updates) {
        await tx
          .update(todoReminders)
          .set({ remindAt: new Date(u.remindAt), sentAt: null })
          .where(eq(todoReminders.id, u.id));
      }
      if (reminderPlan.inserts.length > 0) {
        await tx.insert(todoReminders).values(reminderPlan.inserts.map((ms) => ({ todoId: id, remindAt: new Date(ms) })));
      }
    }
    return row;
  });
}

/**
 * 방 멤버가 바뀐 뒤(나가기·내보내기·참여·초대 — db/queries/rooms.js의 removeRoomMembers/addRoomMembers가 같은 트랜잭션
 * [tx]에서 부른다) [userIds]가 담당 행을 가진 그 방 할 일들의 전체 진척률을 다시 맞춘다 — 방을 나간 담당자는 곧바로 집계에서
 * 빠지고, 다시 들어오면 남아 있던 그 사람의 담당 행(진척률)이 다시 들어간다. [left]면 [userIds]는 방금 방에서 빠진 사람들이라,
 * 그 때문에 (그 방에 있는) 담당자가 하나도 남지 않은 할 일은 그 사람들의 담당 행(= 바로 전까지 그 방에 있던 담당자)을
 * 기준으로 S3 규칙의 값(todoRules.orphanedProgress)을 이어받는다. 할 일 행을 id 순으로 잠근 뒤 맞추므로 같은 할 일을
 * 고치는 updateTodo와 차례로 처리된다. 전체 진척률(또는 완료 시각)이 실제로 바뀐 할 일 행만 돌려준다 — 호출부가
 * todo:changed로 알린다(rooms.js notifyTodosResynced).
 */
export async function resyncTodoProgressForMembers(tx, roomId, userIds, { left = false } = {}) {
  if (userIds.length === 0) return [];
  const rows = await tx
    .select()
    .from(todos)
    .where(
      and(
        eq(todos.roomId, roomId),
        exists(
          tx
            .select({ one: sql`1` })
            .from(todoAssignees)
            .where(and(eq(todoAssignees.todoId, todos.id), inArray(todoAssignees.userId, userIds))),
        ),
      ),
    )
    .orderBy(asc(todos.id))
    .for('no key update');
  const changed = [];
  for (const row of rows) {
    const after = await inRoomAssigneeRows(tx, row);
    // 남은 담당자가 없으면 — 방금 빠진 사람들의 담당 행이 "바로 전까지 그 방에 있던 담당자"다(남은 사람이 없으니 전부).
    const before =
      left && after.length === 0
        ? await tx
            .select({ userId: todoAssignees.userId, progress: todoAssignees.progress })
            .from(todoAssignees)
            .where(and(eq(todoAssignees.todoId, row.id), inArray(todoAssignees.userId, userIds)))
        : null;
    const synced = await syncAggregateProgress(tx, row, { before, after });
    if (synced !== row) changed.push(synced);
  }
  return changed;
}

export async function deleteTodo(id) {
  const rows = await db.delete(todos).where(eq(todos.id, id)).returning({ id: todos.id });
  return rows.length > 0;
}

/**
 * 그 할 일에 (그 방에 아직 있는) 담당자가 있다는 조건(EXISTS) — [userId]를 주면 그 사람이, [exceptUserId]를 주면 그 사람
 * 말고 누군가가. 방을 나간 사람의 담당 행은 남아 있어도 담당자로 치지 않는다(listTodoAssigneeIds와 같은 기준).
 */
function roomAssigneeExists({ userId, exceptUserId } = {}) {
  const conditions = [eq(todoAssignees.todoId, todos.id)];
  if (userId) conditions.push(eq(todoAssignees.userId, userId));
  if (exceptUserId) conditions.push(ne(todoAssignees.userId, exceptUserId));
  return db
    .select({ one: sql`1` })
    .from(todoAssignees)
    .innerJoin(
      assigneeMember,
      and(eq(assigneeMember.roomId, todos.roomId), eq(assigneeMember.userId, todoAssignees.userId)),
    )
    .where(and(...conditions));
}

/**
 * 목록(listTodos)과 전체 개수(countTodos)가 함께 쓰는 조건 — 내가 아직 멤버인 방의 것만(방을 나가면 목록에서 사라진다).
 * [scope]: mine(나의 할 일 — 내가 담당이거나, 내가 만들었고 담당자가 없는 것) / assigned_by_me(부여한 할 일 — 내가 만들었고
 * 나 아닌 담당자가 있는 것) / team(모든 할 일 — 내가 멤버인 방의 전부). [assigneeId]를 주면 그 사람이 담당인 것만,
 * [from]~[to]를 주면 기간(시작일 ?? 종료일 ~ 종료일 ?? 시작일)이 겹치는 것만(날짜가 둘 다 없는 할 일은 빠진다).
 * 완료 제외는 기준 진척률(progressPerspective의 사람의 담당 행, 없으면 todos.progress)로 본다. 돌려주는 값의
 * `query(selection, join?)`은 그 select에 보는 사람의 멤버십·기준 진척률 담당 행 조인(+ [join]이 더 붙이는 것)과 조건까지
 * 붙인 쿼리, `refProgress`는 정렬에 쓰는 기준 진척률 식이다.
 */
function todoListBase({ userId, teamId, scope, includeDone, roomId, assigneeId, from, to }) {
  const conditions = [eq(todos.teamId, teamId)];
  if (roomId) conditions.push(eq(todos.roomId, roomId));
  if (scope === 'mine') {
    conditions.push(
      or(exists(roomAssigneeExists({ userId })), and(eq(todos.creatorId, userId), notExists(roomAssigneeExists()))),
    );
  } else if (scope === 'assigned_by_me') {
    conditions.push(and(eq(todos.creatorId, userId), exists(roomAssigneeExists({ exceptUserId: userId }))));
  }
  if (assigneeId) conditions.push(exists(roomAssigneeExists({ userId: assigneeId })));
  if (from && to) {
    conditions.push(
      sql`coalesce(${todos.startDate}, ${todos.dueDate}) <= ${to}::date`,
      sql`coalesce(${todos.dueDate}, ${todos.startDate}) >= ${from}::date`,
    );
  }
  const perspectiveId = progressPerspective({ scope, assigneeId, userId });
  const refProgress = perspectiveId ? sql`coalesce(${refAssignee.progress}, ${todos.progress})` : sql`${todos.progress}`;
  if (!includeDone) conditions.push(sql`${refProgress} < 100`);
  const query = (selection, join = (q) => q) => {
    // 방 멤버십·담당 행·즐겨찾기 모두 (방, 사람)/(할 일, 사람)이 기본 키라 조인해도 할 일 한 건이 한 줄이다(개수가 맞다).
    let q = db
      .select(selection)
      .from(todos)
      .innerJoin(roomMembers, and(eq(roomMembers.roomId, todos.roomId), eq(roomMembers.userId, userId)))
      .$dynamic();
    if (perspectiveId) {
      q = q.leftJoin(refAssignee, and(eq(refAssignee.todoId, todos.id), eq(refAssignee.userId, perspectiveId)));
    }
    return join(q).where(and(...conditions));
  };
  return { query, refProgress };
}

/**
 * 할 일 목록(조건은 todoListBase) — 정렬은 내가 즐겨찾기한 것 먼저, 그다음 due(기본)면 미완료 먼저(기준 진척률) → 기한
 * 임박순(기한 없음은 뒤) → 최근 생성순, created면 최근 생성순. 다음 쪽이 있는지 보려고 [limit + 1]건까지 가져온다.
 */
export function listTodos(params) {
  const { userId, sort, limit, offset } = params;
  const { query, refProgress } = todoListBase(params);
  const order = [
    sql`(${todoFavorites.userId} is null)`,
    ...(sort === 'created'
      ? [desc(todos.createdAt), asc(todos.id)]
      : [sql`(${refProgress} >= 100)`, sql`${todos.dueDate} asc nulls last`, desc(todos.createdAt), asc(todos.id)]),
  ];
  return query({ todo: todos }, (q) =>
    q.leftJoin(todoFavorites, and(eq(todoFavorites.todoId, todos.id), eq(todoFavorites.userId, userId))),
  )
    .orderBy(...order)
    .limit(limit + 1)
    .offset(offset)
    .then((rows) => rows.map((r) => r.todo));
}

/** 목록과 같은 조건(todoListBase — scope·방·담당자·기간·완료 제외)에 맞는 할 일의 전체 개수(쪽 나누기와 무관). */
export async function countTodos(params) {
  const [row] = await todoListBase(params).query({ n: count() });
  return row?.n ?? 0;
}

/** 여러 할 일의 담당자(그 방에 아직 있는 사람만)와 그 사람의 진척률 — [{todoId, progress, completedAt, user}]. */
export function listAssigneesForTodos(todoIds) {
  if (todoIds.length === 0) return Promise.resolve([]);
  return db
    .select({
      todoId: todoAssignees.todoId,
      progress: todoAssignees.progress,
      completedAt: todoAssignees.completedAt,
      user: users,
    })
    .from(todoAssignees)
    .innerJoin(todos, eq(todos.id, todoAssignees.todoId))
    .innerJoin(roomMembers, and(eq(roomMembers.roomId, todos.roomId), eq(roomMembers.userId, todoAssignees.userId)))
    .innerJoin(users, eq(users.id, todoAssignees.userId))
    .where(inArray(todoAssignees.todoId, todoIds))
    .orderBy(asc(todoAssignees.createdAt), asc(users.name));
}

export function listAttachmentsForTodos(todoIds) {
  if (todoIds.length === 0) return Promise.resolve([]);
  return db
    .select()
    .from(todoAttachments)
    .where(inArray(todoAttachments.todoId, todoIds))
    .orderBy(asc(todoAttachments.position));
}

export function listRemindersForTodos(todoIds) {
  if (todoIds.length === 0) return Promise.resolve([]);
  return db
    .select()
    .from(todoReminders)
    .where(inArray(todoReminders.todoId, todoIds))
    .orderBy(asc(todoReminders.remindAt));
}

export function listUsersByIds(ids) {
  if (ids.length === 0) return Promise.resolve([]);
  return db.select().from(users).where(inArray(users.id, ids));
}

/** 이 사람이 즐겨찾기한 할 일 id 집합(주어진 것 중에서). */
export async function listFavoriteTodoIds(todoIds, userId) {
  if (todoIds.length === 0) return new Set();
  const rows = await db
    .select({ todoId: todoFavorites.todoId })
    .from(todoFavorites)
    .where(and(eq(todoFavorites.userId, userId), inArray(todoFavorites.todoId, todoIds)));
  return new Set(rows.map((r) => r.todoId));
}

/** 즐겨찾기 켜기(이미 있으면 그대로)·끄기(없어도 그대로). 실제로 행이 생기거나 지워졌으면 true. */
export async function setTodoFavorite(todoId, userId, favorite) {
  const rows = favorite
    ? await db.insert(todoFavorites).values({ userId, todoId }).onConflictDoNothing().returning({ todoId: todoFavorites.todoId })
    : await db
        .delete(todoFavorites)
        .where(and(eq(todoFavorites.todoId, todoId), eq(todoFavorites.userId, userId)))
        .returning({ todoId: todoFavorites.todoId });
  return rows.length > 0;
}

/**
 * 보낼 때가 된 알림을 **먼저 찜한다**(sentAt을 찍으면서 돌려받는 UPDATE ... RETURNING) — 서버가 둘 떠 있거나 한 번의
 * 점검이 길어져 겹쳐도 같은 알림이 두 번 나가지 않는다. 한 번에 [limit]건까지.
 */
export async function claimDueTodoReminders(now, limit = 200) {
  const due = await db
    .select({ id: todoReminders.id })
    .from(todoReminders)
    .where(and(isNull(todoReminders.sentAt), lte(todoReminders.remindAt, now)))
    .orderBy(asc(todoReminders.remindAt))
    .limit(limit);
  if (due.length === 0) return [];
  return db
    .update(todoReminders)
    .set({ sentAt: now })
    .where(and(inArray(todoReminders.id, due.map((d) => d.id)), isNull(todoReminders.sentAt)))
    .returning();
}

/** 찜한 알림의 할 일들(한 번에). */
export function listTodosByIds(ids) {
  if (ids.length === 0) return Promise.resolve([]);
  return db.select().from(todos).where(inArray(todos.id, ids));
}
