import { and, asc, count, desc, eq, exists, inArray, isNull, ne, notExists, or, sql } from 'drizzle-orm';
import { alias } from 'drizzle-orm/pg-core';
import {
  diffAssignees,
  nextCompletedAt,
  progressPerspective,
  progressResync,
  progressTarget,
  schedulesReminders,
  TODO_PENDING_REMINDERS_ERROR,
  TODO_PROGRESS_DENIED,
} from '../../todoRules.js';
import { db } from '../client.js';
import {
  roomMembers,
  todoAssignees,
  todoAttachments,
  todoComments,
  todoFavorites,
  todoReminders,
  todos,
  users,
} from '../schema.js';

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

// ── 아직 보내지 않은 알림의 한 사람 몫 상한(todoRules.TODO_PENDING_REMINDERS_MAX) ──────────────────────

/** 알림을 새로 잡으면 그 사람 몫의 아직 보내지 않은 알림이 상한을 넘을 때 — 할 일 만들기·수정 전체가 되돌려지고 todos.js가 400으로 바꾼다. */
export class TodoReminderLimitError extends Error {
  constructor() {
    super(TODO_PENDING_REMINDERS_ERROR);
    this.name = 'TodoReminderLimitError';
  }
}

/**
 * [ownerId] 몫으로 세는 할 일 — 그 사람이 만든 할 일, 그리고 만든 사람 계정이 사라진(creator_id null) 할 일 중 그 사람이
 * 담당자인 것(todoPermissions의 관리 권한과 같은 기준 — 그런 할 일은 담당자가 관리한다). 방을 나간 담당자의 행도 넉넉하게
 * 같이 센다.
 */
function ownedByCondition(executor, ownerId) {
  return or(
    eq(todos.creatorId, ownerId),
    and(
      isNull(todos.creatorId),
      exists(
        executor
          .select({ one: sql`1` })
          .from(todoAssignees)
          .where(and(eq(todoAssignees.todoId, todos.id), eq(todoAssignees.userId, ownerId))),
      ),
    ),
  );
}

/** [ownerId] 몫(ownedByCondition)의 아직 보내지 않은(sent_at null — 앞으로 울릴 것과 때가 됐는데 아직 못 보낸 것) 알림 개수. */
async function countPendingReminders(executor, ownerId) {
  const [row] = await executor
    .select({ n: sql`count(*)::int` })
    .from(todoReminders)
    .innerJoin(todos, eq(todos.id, todoReminders.todoId))
    .where(and(isNull(todoReminders.sentAt), ownedByCondition(executor, ownerId)));
  return Number(row?.n ?? 0);
}

/** 할 일 한 건의 아직 보내지 않은 알림 개수 — updateTodo가 이번 수정으로 늘었는지 보려고 앞뒤로 센다. */
async function countTodoPendingReminders(executor, todoId) {
  const [row] = await executor
    .select({ n: sql`count(*)::int` })
    .from(todoReminders)
    .where(and(eq(todoReminders.todoId, todoId), isNull(todoReminders.sentAt)));
  return Number(row?.n ?? 0);
}

/**
 * 알림을 다 써 넣은 뒤(트랜잭션 [tx] 안) [ownerId] 몫이 [max]를 넘으면 TodoReminderLimitError를 던져 전체를 되돌린다. 같은
 * 사람 몫의 검사를 advisory 잠금으로 줄 세우므로(커밋·롤백 때 저절로 풀린다) 동시에 여러 요청이 와도 상한을 넘지 않는다 —
 * 뒤에 잠근 쪽의 개수 쿼리는 앞선 쪽이 커밋한 알림까지 본다. 잠금은 트랜잭션의 맨 마지막에 잡고 그 뒤로는 개수만 세므로,
 * 이 잠금을 쥔 쪽이 다른 행 잠금을 기다리는 일이 없다(교착 없음).
 */
async function assertPendingRemindersWithin(tx, ownerId, max) {
  await tx.execute(sql`select pg_advisory_xact_lock(hashtext(${`todo-reminders:${ownerId}`}))`);
  if ((await countPendingReminders(tx, ownerId)) > max) throw new TodoReminderLimitError();
}

/**
 * 할 일 한 건을 담당자·첨부·알림까지 한 번에 만든다. [todo]는 todos 행에 넣을 값, [reminderTimes]는 ms 배열.
 * [pendingReminderMax]를 주면 알림을 넣은 뒤 만든 사람 몫의 아직 보내지 않은 알림이 그 수를 넘는지 보고, 넘으면
 * TodoReminderLimitError(아무것도 만들지 않는다).
 */
export function insertTodo({ todo, assigneeIds, attachments, reminderTimes, pendingReminderMax = null }) {
  return db.transaction(async (tx) => {
    const [row] = await tx.insert(todos).values(todo).returning();
    if (assigneeIds.length > 0) {
      await tx.insert(todoAssignees).values(assigneeIds.map((userId) => ({ todoId: row.id, userId })));
    }
    if (attachments.length > 0) await tx.insert(todoAttachments).values(attachmentValues(row.id, attachments));
    if (reminderTimes.length > 0) {
      await tx.insert(todoReminders).values(reminderTimes.map((ms) => ({ todoId: row.id, remindAt: new Date(ms) })));
      if (pendingReminderMax !== null && row.creatorId) {
        await assertPendingRemindersWithin(tx, row.creatorId, pendingReminderMax);
      }
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
 * [pendingReminderLimit] `{ actorId, max }`를 주면, 이번 알림 수정으로 이 할 일의 아직 보내지 않은 알림이 늘었을 때만 그
 * 할 일 주인 몫(만든 사람, 그 계정이 사라졌으면 고치는 사람 — ownedByCondition)이 [max]를 넘는지 보고 넘으면
 * TodoReminderLimitError를 던져 수정 전체를 되돌린다 — 줄이거나 시각만 옮기는 수정은 상한을 넘은 사람도 할 수 있다.
 */
export function updateTodo(id, { fields = {}, assigneeIds, attachments, reminderPlan, progressWrite, pendingReminderLimit = null }) {
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
      // 새로 잡는 알림이 있을 때만 앞뒤 개수를 센다 — 지우기만 하는 수정은 상한과 상관없다.
      const watch = !!pendingReminderLimit && schedulesReminders(reminderPlan);
      const pendingBefore = watch ? await countTodoPendingReminders(tx, id) : 0;
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
      // 맨 마지막 — 이 할 일의 아직 보내지 않은 알림이 늘었으면 주인 몫 전체를 본다(잠금도 여기서 잡는다).
      if (watch && (await countTodoPendingReminders(tx, id)) > pendingBefore) {
        const ownerId = row.creatorId ?? pendingReminderLimit.actorId;
        if (ownerId) await assertPendingRemindersWithin(tx, ownerId, pendingReminderLimit.max);
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
function todoListBase({ userId, teamId, scope, includeDone, roomId, assigneeId, from, to, q = null }) {
  const conditions = [eq(todos.teamId, teamId)];
  if (roomId) conditions.push(eq(todos.roomId, roomId));
  if (q) {
    // 검색 패널의 "할 일" 탭 — 제목·설명에 든 글(q는 이미 소문자). %·_·\는 와일드카드가 아니라 글자 그대로(메시지 검색과 같다).
    const pattern = `%${q.replace(/[\\%_]/g, '\\$&')}%`;
    conditions.push(
      or(sql`lower(${todos.title}) like ${pattern}`, sql`lower(coalesce(${todos.description}, '')) like ${pattern}`),
    );
  }
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
      : [
          sql`(${refProgress} >= 100)`,
          sql`${todos.dueDate} asc nulls last`,
          // 같은 기한일이면 종료 시간 순(시간이 없으면 그날 끝 — 23:59 뒤).
          sql`${todos.dueTime} asc nulls last`,
          desc(todos.createdAt),
          asc(todos.id),
        ]),
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
 * 점검이 길어져 겹쳐도 같은 알림이 두 번 나가지 않는다. 한 번에 [limit]건까지, 할 일을 만든 사람마다 돌아가며 고른다 —
 * 사람마다 가장 이른 알림 하나씩, 그다음 둘째 것 하나씩… (같은 차례 안에서는 이른 순, 만든 사람 계정이 사라진 할 일은 한
 * 사람으로 친다). 예전처럼 서버 전체에서 가장 이른 것부터 고르면, 누군가 알림을 한꺼번에 몰아 둘 때 다른 사람의 알림이 그
 * 뒤로 밀렸다 — 이제는 남의 알림이 첫 묶음에 들어간다(검토 S19). 돌려주는 값은 `{ reminders(그 차례대로), more(같은 조건에
 * 더 남았을 수 있음 — 고른 것이 [limit]만큼 찼다) }`. 이미 보낸 알림(sent_at)은 사람마다 차례를 세기 전에 빠진다.
 */
// [limit]의 기본값은 지우지 않는다 — 빠뜨리면 `limit null`(무제한)로 나가 쌓인 알림을 한 번에 다 찜하게 된다(막으려던 폭주).
export async function claimDueTodoReminders(now, limit = 200) {
  const due = await db.execute(sql`
    select id from (
      select r.id, r.remind_at,
             row_number() over (partition by t.creator_id order by r.remind_at, r.id) as turn
      from ${todoReminders} r
      join ${todos} t on t.id = r.todo_id
      where r.sent_at is null and r.remind_at <= ${now.toISOString()}
    ) due
    order by turn, remind_at, id
    limit ${limit}`);
  const ids = due.rows.map((r) => r.id);
  if (ids.length === 0) return { reminders: [], more: false };
  const claimed = await db
    .update(todoReminders)
    .set({ sentAt: now })
    .where(and(inArray(todoReminders.id, ids), isNull(todoReminders.sentAt)))
    .returning();
  // UPDATE ... RETURNING은 순서를 지키지 않으므로 고른 차례대로 다시 늘어놓는다(앞의 것부터 보낸다).
  const order = new Map(ids.map((id, i) => [id, i]));
  claimed.sort((a, b) => order.get(a.id) - order.get(b.id));
  return { reminders: claimed, more: ids.length >= limit };
}

/** 찜한 알림의 할 일들(한 번에). */
export function listTodosByIds(ids) {
  if (ids.length === 0) return Promise.resolve([]);
  return db.select().from(todos).where(inArray(todos.id, ids));
}

// ── 댓글 ────────────────────────────────────────────────────────────────

export function listCommentsForTodo(todoId) {
  return db.select().from(todoComments).where(eq(todoComments.todoId, todoId)).orderBy(asc(todoComments.createdAt));
}

export async function insertTodoComment({ todoId, authorId, authorName, text }) {
  const [row] = await db.insert(todoComments).values({ todoId, authorId, authorName, text }).returning();
  return row;
}

export async function findTodoCommentById(id) {
  const [row] = await db.select().from(todoComments).where(eq(todoComments.id, id));
  return row ?? null;
}

export async function updateTodoCommentText(id, text) {
  const [row] = await db.update(todoComments).set({ text, editedAt: new Date() }).where(eq(todoComments.id, id)).returning();
  return row ?? null;
}

export async function deleteTodoComment(id) {
  await db.delete(todoComments).where(eq(todoComments.id, id));
}
