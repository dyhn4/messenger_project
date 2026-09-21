import { randomUUID } from 'node:crypto';
import {
  filterUsersWantingKind,
  findTasksDueSoon,
  insertProjectNotification,
  countUnreadProjectNotifications,
  markTaskDueReminded,
} from './db/queries/projectNotifications.js';
import { findProjectById } from './db/queries/projects.js';
import { notifyProjectPush } from './push.js';

/**
 * 프로젝트 알림 — 알림함(project_notifications)에 한 줄 남기고, 접속 중이면 소켓
 * (project:notification)으로 바로 알리고, 앱이 꺼져 있으면 FCM 푸시를 보낸다.
 * 받는 사람의 알림 설정(프로젝트별 끄기/종류별 끄기)을 존중하고, 행동한 본인에게는 안 보낸다.
 */
export function createProjectNotifier(io) {
  async function notify({ project, task, kind, actorId = null, targetIds, title, body }) {
    const ids = [...new Set(targetIds.filter((id) => id && id !== actorId))];
    const wanted = await filterUsersWantingKind(project.id, ids, kind);
    for (const userId of wanted) {
      const row = await insertProjectNotification({
        id: randomUUID(),
        userId,
        projectId: project.id,
        taskId: task?.id ?? null,
        kind,
        title,
        body,
        actorId,
      });
      const unreadCount = await countUnreadProjectNotifications(userId);
      io.to(`user:${userId}`).emit('project:notification', {
        id: row.id,
        projectId: project.id,
        projectName: project.name,
        taskId: task?.id ?? null,
        kind,
        title,
        body,
        createdAt: new Date(row.createdAt).getTime(),
        unreadCount,
      });
      notifyProjectPush({ userId, title, body, projectId: project.id, taskId: task?.id ?? null }).catch((e) =>
        console.error('[projectNotify] 푸시 실패:', e?.message ?? e),
      );
    }
  }
  return { notify };
}

const SWEEP_INTERVAL_MS = 10 * 60 * 1000;

async function sweepDueSoon(io) {
  const notifier = createProjectNotifier(io);
  const due = await findTasksDueSoon();
  for (const t of due) {
    // 먼저 표시해서(같은 업무를 중복 발송하지 않도록) 발송 도중 실패해도 다시 폭주하지 않게 한다.
    await markTaskDueReminded(t.id, t.dueDate);
    const project = await findProjectById(t.projectId);
    if (!project) continue;
    const key = `${t.projectIdentifier}-${t.seq}`;
    await notifier.notify({
      project,
      task: t,
      kind: 'due',
      targetIds: [t.assigneeId],
      title: `${project.name} · ${key}`,
      body: `마감이 임박했습니다: ${t.title}`,
    });
  }
}

/** 서버 시작 시 한 번, 이후 10분마다 "마감 임박" 알림을 보낸다. */
export function startProjectDueReminderJob(io) {
  const run = () => sweepDueSoon(io).catch((e) => console.error('[projectNotify] 마감 알림 실패:', e));
  run();
  setInterval(run, SWEEP_INTERVAL_MS);
}
