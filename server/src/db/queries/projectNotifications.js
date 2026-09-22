import { and, desc, eq, inArray, isNull, lte, gt, ne, sql } from 'drizzle-orm';
import { db } from '../client.js';
import {
  projectNotificationPolicies,
  projectNotificationSettings,
  projectNotifications,
  projects,
  tasks,
} from '../schema.js';

/** 알림 종류 → 정책 칸. 여기 없는 종류(자동화 등)는 정책으로 끄지 않는다. */
const POLICY_COLUMN = {
  status: 'onStatus',
  priority: 'onPriority',
  assigned: 'onAssigned',
  referenced: 'onReferenced',
  due_date: 'onDueDate',
  task_type: 'onTaskType',
  custom_field: 'onCustomField',
  created: 'onCreated',
  deleted: 'onDeleted',
  comment: 'onComment',
  due: 'onDue',
};

export const DEFAULT_POLICY = Object.fromEntries(
  Object.values(POLICY_COLUMN).map((col) => [col, true]),
);

export async function getNotificationPolicy(projectId) {
  const [row] = await db
    .select()
    .from(projectNotificationPolicies)
    .where(eq(projectNotificationPolicies.projectId, projectId));
  return row ?? { projectId, ...DEFAULT_POLICY };
}

export async function upsertNotificationPolicy(projectId, fields) {
  const [row] = await db
    .insert(projectNotificationPolicies)
    .values({ projectId, ...fields })
    .onConflictDoUpdate({ target: projectNotificationPolicies.projectId, set: fields })
    .returning();
  return row;
}

/** 프로젝트 정책이 이 종류의 알림을 허용하는지. */
export async function policyAllows(projectId, kind) {
  const col = POLICY_COLUMN[kind];
  if (!col) return true;
  const policy = await getNotificationPolicy(projectId);
  return policy[col] !== false;
}

export async function getNotificationSettings(userId, projectId) {
  const [row] = await db
    .select()
    .from(projectNotificationSettings)
    .where(and(eq(projectNotificationSettings.userId, userId), eq(projectNotificationSettings.projectId, projectId)));
  return row ?? { userId, projectId, muted: false };
}

export async function upsertNotificationSettings(userId, projectId, fields) {
  const [row] = await db
    .insert(projectNotificationSettings)
    .values({ userId, projectId, ...fields })
    .onConflictDoUpdate({
      target: [projectNotificationSettings.userId, projectNotificationSettings.projectId],
      set: fields,
    })
    .returning();
  return row;
}

/** 이 프로젝트 알림을 개인적으로 끄지 않은 사람만 추린다. */
export async function filterUnmutedUsers(projectId, userIds) {
  if (userIds.length === 0) return [];
  const rows = await db
    .select()
    .from(projectNotificationSettings)
    .where(and(eq(projectNotificationSettings.projectId, projectId), inArray(projectNotificationSettings.userId, userIds)));
  const muted = new Set(rows.filter((r) => r.muted).map((r) => r.userId));
  return userIds.filter((id) => !muted.has(id));
}

export async function insertProjectNotification(fields) {
  const [row] = await db.insert(projectNotifications).values(fields).returning();
  return row;
}

export function listProjectNotifications(userId, limit = 50) {
  return db
    .select({ n: projectNotifications, projectName: projects.name, projectColor: projects.color })
    .from(projectNotifications)
    .innerJoin(projects, eq(projectNotifications.projectId, projects.id))
    .where(eq(projectNotifications.userId, userId))
    .orderBy(desc(projectNotifications.createdAt))
    .limit(limit)
    .then((rows) => rows.map((r) => ({ ...r.n, projectName: r.projectName, projectColor: r.projectColor })));
}

export async function countUnreadProjectNotifications(userId) {
  const [row] = await db
    .select({ n: sql`count(*)::int` })
    .from(projectNotifications)
    .where(and(eq(projectNotifications.userId, userId), isNull(projectNotifications.readAt)));
  return row?.n ?? 0;
}

/** [ids]가 없으면 내 알림 전부를 읽음 처리한다. */
export async function markProjectNotificationsRead(userId, ids) {
  const conds = [eq(projectNotifications.userId, userId), isNull(projectNotifications.readAt)];
  if (ids && ids.length > 0) conds.push(inArray(projectNotifications.id, ids));
  await db
    .update(projectNotifications)
    .set({ readAt: new Date() })
    .where(and(...conds));
}

/**
 * "마감 임박" 후보 — 담당자가 있고 완료 전이며, 마감이 앞으로 24시간 안(또는 오늘 마감으로 이미
 * 시작된 지 24시간 안)이고, 그 마감일로는 아직 알린 적이 없는 업무.
 */
export function findTasksDueSoon(now = new Date()) {
  const soon = new Date(now.getTime() + 24 * 3600 * 1000);
  const past = new Date(now.getTime() - 24 * 3600 * 1000);
  return db
    .select({ task: tasks, projectName: projects.name, projectIdentifier: projects.identifier })
    .from(tasks)
    .innerJoin(projects, eq(tasks.projectId, projects.id))
    .where(
      and(
        ne(tasks.status, 'done'),
        sql`${tasks.assigneeId} is not null`,
        sql`${tasks.dueDate} is not null`,
        lte(tasks.dueDate, soon),
        gt(tasks.dueDate, past),
        sql`${tasks.dueRemindedFor} is distinct from ${tasks.dueDate}`,
        sql`${projects.archivedAt} is null`,
      ),
    )
    .then((rows) => rows.map((r) => ({ ...r.task, projectName: r.projectName, projectIdentifier: r.projectIdentifier })));
}

export async function markTaskDueReminded(taskId, dueDate) {
  await db.update(tasks).set({ dueRemindedFor: dueDate }).where(eq(tasks.id, taskId));
}
