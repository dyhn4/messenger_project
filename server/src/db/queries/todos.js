import { and, asc, desc, eq, exists, inArray, isNull, lte, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { roomMembers, todoAssignees, todoAttachments, todoReminders, todos, users } from '../schema.js';

// 할 일(todos.js)의 쿼리 모음. 할 일·담당자·첨부·알림은 항상 같이 움직여서 쓰기는 트랜잭션 하나로 묶는다.

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

/**
 * 할 일 수정 — [fields]는 todos 행에 바로 쓸 컬럼들(updatedAt은 여기서 찍는다), [assigneeIds]·[attachments]는 주면 통째로
 * 바꾸고(undefined면 그대로), [reminderPlan]은 todoRules.planReminders의 결과다. 시각이 바뀐 알림은 보낸 기록(sentAt)을 지운다.
 */
export function updateTodo(id, { fields = {}, assigneeIds, attachments, reminderPlan }) {
  return db.transaction(async (tx) => {
    const [row] = await tx
      .update(todos)
      .set({ ...fields, updatedAt: new Date() })
      .where(eq(todos.id, id))
      .returning();
    if (!row) return null;
    if (assigneeIds !== undefined) {
      await tx.delete(todoAssignees).where(eq(todoAssignees.todoId, id));
      if (assigneeIds.length > 0) {
        await tx.insert(todoAssignees).values(assigneeIds.map((userId) => ({ todoId: id, userId })));
      }
    }
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

export async function deleteTodo(id) {
  const rows = await db.delete(todos).where(eq(todos.id, id)).returning({ id: todos.id });
  return rows.length > 0;
}

/**
 * 할 일 목록 — 내가 아직 멤버인 방의 것만(방을 나가면 목록에서 사라진다). [scope]: mine(내가 담당) /
 * assigned_by_me(내가 만듦) / team(내가 멤버인 방의 전부). 기본 정렬(due)은 미완료 먼저 → 기한 임박순(기한 없음은 뒤) →
 * 최근 생성순, created는 최근 생성순. 다음 쪽이 있는지 보려고 [limit + 1]건까지 가져온다.
 */
export function listTodos({ userId, teamId, scope, includeDone, roomId, sort, limit, offset }) {
  const conditions = [eq(todos.teamId, teamId)];
  if (roomId) conditions.push(eq(todos.roomId, roomId));
  if (!includeDone) conditions.push(sql`${todos.progress} < 100`);
  if (scope === 'mine') {
    conditions.push(
      exists(
        db
          .select({ one: sql`1` })
          .from(todoAssignees)
          .where(and(eq(todoAssignees.todoId, todos.id), eq(todoAssignees.userId, userId))),
      ),
    );
  } else if (scope === 'assigned_by_me') {
    conditions.push(eq(todos.creatorId, userId));
  }
  const order =
    sort === 'created'
      ? [desc(todos.createdAt), asc(todos.id)]
      : [sql`(${todos.progress} >= 100)`, sql`${todos.dueDate} asc nulls last`, desc(todos.createdAt), asc(todos.id)];
  return db
    .select({ todo: todos })
    .from(todos)
    .innerJoin(roomMembers, and(eq(roomMembers.roomId, todos.roomId), eq(roomMembers.userId, userId)))
    .where(and(...conditions))
    .orderBy(...order)
    .limit(limit + 1)
    .offset(offset)
    .then((rows) => rows.map((r) => r.todo));
}

/** 여러 할 일의 담당자(그 방에 아직 있는 사람만) — [{todoId, user}]. */
export function listAssigneesForTodos(todoIds) {
  if (todoIds.length === 0) return Promise.resolve([]);
  return db
    .select({ todoId: todoAssignees.todoId, user: users })
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
