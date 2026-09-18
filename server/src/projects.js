import { randomUUID } from 'node:crypto';
import { Router } from 'express';
import {
  addProjectMembers,
  countTasksByProject,
  deleteProject,
  deleteTask,
  findProjectById,
  findProjectByIdentifier,
  findTaskById,
  getProjectRole,
  insertProject,
  insertTask,
  insertTaskComment,
  isProjectMember,
  listProjectMemberUsers,
  listProjectsForUser,
  listRecentTaskComments,
  listTaskComments,
  listTasksByProject,
  listTasksForAssignee,
  removeProjectMember,
  setProjectFavorite,
  takeNextTaskSeq,
  updateProject,
  updateTask,
} from './db/queries/projects.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { isTeamMember } from './db/queries/teams.js';
import { findUserById } from './db/queries/users.js';
import { teamAccess } from './access.js';
import { canCreateProject, canManageProject } from './permissions.js';
import { publicUser } from './users.js';

const TASK_STATUSES = ['todo', 'doing', 'done'];
const TASK_PRIORITIES = ['low', 'normal', 'high'];

/** 업무 번호 표기(MKT-1001) — 화면에 보이는 값은 항상 서버가 만들어서 내려준다. */
function taskKey(identifier, seq) {
  return `${identifier}-${seq}`;
}

function toProjectDto(project, { total = 0, done = 0 } = {}) {
  return {
    id: project.id,
    teamId: project.teamId,
    name: project.name,
    description: project.description ?? null,
    identifier: project.identifier,
    favorite: project.favorite ?? false,
    myRole: project.myRole ?? 'member',
    taskTotal: total,
    taskDone: done,
    createdAt: new Date(project.createdAt).getTime(),
  };
}

function toTaskDto(task, { identifier, projectName } = {}) {
  const key = identifier ? taskKey(identifier, task.seq) : null;
  return {
    id: task.id,
    projectId: task.projectId,
    seq: task.seq,
    key,
    projectName: projectName ?? task.projectName ?? null,
    title: task.title,
    description: task.description ?? null,
    assigneeId: task.assigneeId ?? null,
    status: task.status,
    priority: task.priority,
    startDate: task.startDate ? new Date(task.startDate).getTime() : null,
    dueDate: task.dueDate ? new Date(task.dueDate).getTime() : null,
    createdAt: new Date(task.createdAt).getTime(),
    completedAt: task.completedAt ? new Date(task.completedAt).getTime() : null,
  };
}

function toTaskCommentDto(comment) {
  return {
    id: comment.id,
    taskId: comment.taskId,
    projectId: comment.projectId,
    senderId: comment.senderId ?? null,
    senderName: comment.senderName,
    text: comment.text,
    createdAt: new Date(comment.createdAt).getTime(),
    // "최근 댓글" 목록에서만 채워진다(어느 업무의 댓글인지 한 줄로 보여주려고).
    taskTitle: comment.taskTitle ?? null,
    taskKey:
      comment.projectIdentifier != null && comment.taskSeq != null
        ? taskKey(comment.projectIdentifier, comment.taskSeq)
        : null,
    projectName: comment.projectName ?? null,
  };
}

/** 날짜 입력(epoch millis 또는 null)을 Date로. 값이 안 왔으면 undefined(=안 건드림). */
function parseDate(value) {
  if (value === undefined) return undefined;
  if (value === null) return null;
  return typeof value === 'number' ? new Date(value) : undefined;
}

/**
 * 프로젝트 — 토픽(대화)과 별개로 "업무를 계획·추적하는 공간"이다. 팀에 속하고, 초대된
 * 구성원(project_members)만 볼 수 있다. 만들 수 있는 사람은 서버 설정(projectCreation)이
 * 정하고(관리자 콘솔 "프로젝트 생성 권한"), 이미 만들어진 프로젝트에 초대받아 참여하는 건
 * 등급과 무관하다(준회원도 초대받으면 볼 수 있다).
 */
export function createProjectsRouter(io) {
  const router = Router();

  /** 이 사람이 그 프로젝트를 볼 수 있는지 확인하고, 못 보면 응답까지 보내고 null을 준다. */
  async function requireProjectMember(req, res, projectId) {
    const project = await findProjectById(projectId);
    if (!project) {
      res.status(404).json({ error: '프로젝트를 찾을 수 없습니다.' });
      return null;
    }
    if (!(await isProjectMember(project.id, req.user.sub))) {
      res.status(403).json({ error: '이 프로젝트의 구성원이 아닙니다.' });
      return null;
    }
    return project;
  }

  /** 프로젝트 설정/삭제 권한(담당자 또는 팀 소유자·관리자)까지 필요한 경우. */
  async function requireProjectManager(req, res, projectId) {
    const project = await requireProjectMember(req, res, projectId);
    if (!project) return null;
    const [access, myRole] = await Promise.all([
      teamAccess(project.teamId, req.user.sub),
      getProjectRole(project.id, req.user.sub),
    ]);
    if (!canManageProject({ ...access, isProjectOwner: myRole === 'owner' })) {
      res.status(403).json({ error: '프로젝트를 관리할 권한이 없습니다.' });
      return null;
    }
    return project;
  }

  /** 내가 참여 중인 프로젝트 목록(진행률 포함). */
  router.get('/projects', async (req, res) => {
    const teamId = req.query.teamId;
    if (typeof teamId !== 'string') return res.status(400).json({ error: 'teamId가 필요합니다.' });
    if (!(await isTeamMember(teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    const list = await listProjectsForUser(teamId, req.user.sub);
    const counts = await countTasksByProject(list.map((p) => p.id));
    res.json(list.map((p) => toProjectDto(p, counts[p.id])));
  });

  /**
   * 프로젝트 홈(대시보드) 한 번에 — 통계/내 업무/최근 댓글을 화면 하나가 다 쓰는 값이라
   * 왕복을 줄이려고 묶어서 내려준다.
   */
  router.get('/projects/home', async (req, res) => {
    const teamId = req.query.teamId;
    if (typeof teamId !== 'string') return res.status(400).json({ error: 'teamId가 필요합니다.' });
    if (!(await isTeamMember(teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    const list = await listProjectsForUser(teamId, req.user.sub);
    const projectIds = list.map((p) => p.id);
    const [counts, myTasks, comments] = await Promise.all([
      countTasksByProject(projectIds),
      listTasksForAssignee(teamId, req.user.sub),
      listRecentTaskComments(projectIds),
    ]);

    const now = Date.now();
    const stats = {
      total: myTasks.length,
      done: myTasks.filter((t) => t.status === 'done').length,
      doing: myTasks.filter((t) => t.status !== 'done').length,
      // 마감일이 지났는데 아직 완료가 아닌 것.
      overdue: myTasks.filter((t) => t.status !== 'done' && t.dueDate && new Date(t.dueDate).getTime() < now).length,
    };

    res.json({
      stats,
      projects: list.map((p) => toProjectDto(p, counts[p.id])),
      myTasks: myTasks.map((t) => toTaskDto(t, { identifier: t.projectIdentifier, projectName: t.projectName })),
      recentComments: comments.map(toTaskCommentDto),
    });
  });

  /** 새 프로젝트. 만든 사람이 담당자(owner)가 되고, 고른 구성원이 함께 들어간다. */
  router.post('/projects', async (req, res) => {
    const teamId = req.body?.teamId;
    if (typeof teamId !== 'string') return res.status(400).json({ error: 'teamId가 필요합니다.' });
    if (!(await isTeamMember(teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    const [access, settings] = await Promise.all([teamAccess(teamId, req.user.sub), getServerSettings()]);
    if (!canCreateProject({ ...access, projectCreation: settings.projectCreation })) {
      return res.status(403).json({ error: '프로젝트를 만들 권한이 없습니다.' });
    }

    const name = typeof req.body?.name === 'string' ? req.body.name.trim() : '';
    if (!name) return res.status(400).json({ error: '프로젝트 이름을 입력하세요.' });
    if (name.length > 60) return res.status(400).json({ error: '프로젝트 이름은 60자 이내로 입력하세요.' });
    const description = typeof req.body?.description === 'string' ? req.body.description.trim() : null;

    // 식별자는 업무 번호(MKT-1001)에 쓰이므로 영문/숫자 대문자로만 받는다.
    const rawIdentifier = typeof req.body?.identifier === 'string' ? req.body.identifier.trim().toUpperCase() : '';
    if (!/^[A-Z][A-Z0-9]{1,9}$/.test(rawIdentifier)) {
      return res.status(400).json({ error: '식별자는 영문으로 시작하는 2~10자의 영문/숫자입니다(예: MKT).' });
    }
    if (await findProjectByIdentifier(teamId, rawIdentifier)) {
      return res.status(409).json({ error: '이미 같은 식별자를 쓰는 프로젝트가 있습니다.' });
    }

    const memberIds = Array.isArray(req.body?.memberIds) ? req.body.memberIds.filter((id) => typeof id === 'string') : [];
    const project = await insertProject({
      id: randomUUID(),
      teamId,
      name,
      description: description || null,
      identifier: rawIdentifier,
      createdBy: req.user.sub,
    });
    await addProjectMembers(project.id, [req.user.sub], 'owner');
    await addProjectMembers(
      project.id,
      memberIds.filter((id) => id !== req.user.sub),
    );

    // 초대된 사람들의 사이드바에 바로 나타나도록 알린다(각자 user: 룸으로).
    for (const userId of new Set([req.user.sub, ...memberIds])) {
      io.to(`user:${userId}`).emit('project:changed', { teamId });
    }
    res.status(201).json(toProjectDto({ ...project, favorite: false, myRole: 'owner' }));
  });

  /** 프로젝트 상세(구성원 포함). */
  router.get('/projects/:id', async (req, res) => {
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;
    const [members, counts, myRole] = await Promise.all([
      listProjectMemberUsers(project.id),
      countTasksByProject([project.id]),
      getProjectRole(project.id, req.user.sub),
    ]);
    res.json({
      ...toProjectDto({ ...project, myRole }, counts[project.id]),
      members: members.map((m) => ({ ...publicUser(m), projectRole: m.projectRole })),
    });
  });

  /** 이름/설명 수정 — 담당자와 팀 소유자·관리자만. */
  router.patch('/projects/:id', async (req, res) => {
    const project = await requireProjectManager(req, res, req.params.id);
    if (!project) return;
    const fields = {};
    if ('name' in (req.body ?? {})) {
      const name = typeof req.body.name === 'string' ? req.body.name.trim() : '';
      if (!name) return res.status(400).json({ error: '프로젝트 이름을 입력하세요.' });
      if (name.length > 60) return res.status(400).json({ error: '프로젝트 이름은 60자 이내로 입력하세요.' });
      fields.name = name;
    }
    if ('description' in (req.body ?? {})) {
      const description = typeof req.body.description === 'string' ? req.body.description.trim() : '';
      fields.description = description || null;
    }
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });

    const updated = await updateProject(project.id, fields);
    await notifyProjectMembers(project, null);
    res.json(toProjectDto(updated));
  });

  router.delete('/projects/:id', async (req, res) => {
    const project = await requireProjectManager(req, res, req.params.id);
    if (!project) return;
    const members = await listProjectMemberUsers(project.id);
    await deleteProject(project.id);
    for (const member of members) {
      io.to(`user:${member.id}`).emit('project:changed', { teamId: project.teamId });
    }
    res.json({ ok: true });
  });

  /** 사이드바 즐겨찾기(개인 설정) — 방 즐겨찾기와 같은 성격이라 구성원이면 누구나. */
  router.patch('/projects/:id/favorite', async (req, res) => {
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;
    const favorite = req.body?.favorite !== false;
    await setProjectFavorite(project.id, req.user.sub, favorite);
    res.json({ ok: true, favorite });
  });

  /** 구성원 초대 — 같은 팀 멤버만 넣을 수 있다. */
  router.post('/projects/:id/members', async (req, res) => {
    const project = await requireProjectManager(req, res, req.params.id);
    if (!project) return;
    const userIds = Array.isArray(req.body?.userIds) ? req.body.userIds.filter((id) => typeof id === 'string') : [];
    if (userIds.length === 0) return res.status(400).json({ error: '추가할 구성원을 고르세요.' });
    for (const userId of userIds) {
      if (!(await isTeamMember(project.teamId, userId))) {
        return res.status(400).json({ error: '같은 팀 멤버만 프로젝트에 추가할 수 있습니다.' });
      }
    }
    await addProjectMembers(project.id, userIds);
    for (const userId of userIds) {
      io.to(`user:${userId}`).emit('project:changed', { teamId: project.teamId, projectId: project.id });
    }
    const members = await listProjectMemberUsers(project.id);
    res.json(members.map((m) => ({ ...publicUser(m), projectRole: m.projectRole })));
  });

  router.delete('/projects/:id/members/:userId', async (req, res) => {
    const project = await requireProjectManager(req, res, req.params.id);
    if (!project) return;
    if ((await getProjectRole(project.id, req.params.userId)) === 'owner') {
      return res.status(400).json({ error: '프로젝트 담당자는 제외할 수 없습니다.' });
    }
    await removeProjectMember(project.id, req.params.userId);
    io.to(`user:${req.params.userId}`).emit('project:changed', { teamId: project.teamId });
    const members = await listProjectMemberUsers(project.id);
    res.json(members.map((m) => ({ ...publicUser(m), projectRole: m.projectRole })));
  });

  // ── 업무 ──────────────────────────────────────────────────────────────

  router.get('/projects/:id/tasks', async (req, res) => {
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;
    const list = await listTasksByProject(project.id);
    res.json(list.map((t) => toTaskDto(t, { identifier: project.identifier, projectName: project.name })));
  });

  /** 내가 담당한 업무(팀 전체) — "내 업무" 화면이 쓴다. */
  router.get('/tasks/mine', async (req, res) => {
    const teamId = req.query.teamId;
    if (typeof teamId !== 'string') return res.status(400).json({ error: 'teamId가 필요합니다.' });
    if (!(await isTeamMember(teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    const list = await listTasksForAssignee(teamId, req.user.sub);
    res.json(list.map((t) => toTaskDto(t, { identifier: t.projectIdentifier, projectName: t.projectName })));
  });

  router.post('/projects/:id/tasks', async (req, res) => {
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;

    const title = typeof req.body?.title === 'string' ? req.body.title.trim() : '';
    if (!title) return res.status(400).json({ error: '업무 제목을 입력하세요.' });
    if (title.length > 200) return res.status(400).json({ error: '업무 제목은 200자 이내로 입력하세요.' });

    const status = TASK_STATUSES.includes(req.body?.status) ? req.body.status : 'todo';
    const priority = TASK_PRIORITIES.includes(req.body?.priority) ? req.body.priority : 'normal';
    const assigneeId = typeof req.body?.assigneeId === 'string' ? req.body.assigneeId : null;
    if (assigneeId && !(await isProjectMember(project.id, assigneeId))) {
      return res.status(400).json({ error: '담당자는 프로젝트 구성원 중에서 고를 수 있습니다.' });
    }

    const seq = await takeNextTaskSeq(project.id);
    const task = await insertTask({
      id: randomUUID(),
      projectId: project.id,
      seq,
      title,
      description: typeof req.body?.description === 'string' ? req.body.description.trim() || null : null,
      assigneeId,
      status,
      priority,
      startDate: parseDate(req.body?.startDate) ?? null,
      dueDate: parseDate(req.body?.dueDate) ?? null,
      createdBy: req.user.sub,
      completedAt: status === 'done' ? new Date() : null,
    });
    await notifyProjectMembers(project, task.id);
    res.status(201).json(toTaskDto(task, { identifier: project.identifier, projectName: project.name }));
  });

  router.get('/tasks/:id', async (req, res) => {
    const task = await findTaskById(req.params.id);
    if (!task) return res.status(404).json({ error: '업무를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, task.projectId);
    if (!project) return;
    const comments = await listTaskComments(task.id);
    res.json({
      ...toTaskDto(task, { identifier: project.identifier, projectName: project.name }),
      comments: comments.map(toTaskCommentDto),
    });
  });

  router.patch('/tasks/:id', async (req, res) => {
    const task = await findTaskById(req.params.id);
    if (!task) return res.status(404).json({ error: '업무를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, task.projectId);
    if (!project) return;

    const fields = {};
    if ('title' in (req.body ?? {})) {
      const title = typeof req.body.title === 'string' ? req.body.title.trim() : '';
      if (!title) return res.status(400).json({ error: '업무 제목을 입력하세요.' });
      fields.title = title;
    }
    if ('description' in (req.body ?? {})) {
      const description = typeof req.body.description === 'string' ? req.body.description.trim() : '';
      fields.description = description || null;
    }
    if ('assigneeId' in (req.body ?? {})) {
      const assigneeId = typeof req.body.assigneeId === 'string' ? req.body.assigneeId : null;
      if (assigneeId && !(await isProjectMember(project.id, assigneeId))) {
        return res.status(400).json({ error: '담당자는 프로젝트 구성원 중에서 고를 수 있습니다.' });
      }
      fields.assigneeId = assigneeId;
    }
    if ('status' in (req.body ?? {})) {
      if (!TASK_STATUSES.includes(req.body.status)) {
        return res.status(400).json({ error: '상태는 할 일/진행 중/완료 중에서 고를 수 있습니다.' });
      }
      fields.status = req.body.status;
      // 완료로 바뀐 순간만 기록하고, 다시 진행 중으로 되돌리면 지운다(완료율 계산에 쓴다).
      fields.completedAt = req.body.status === 'done' ? new Date() : null;
    }
    if ('priority' in (req.body ?? {})) {
      if (!TASK_PRIORITIES.includes(req.body.priority)) {
        return res.status(400).json({ error: '우선순위 값이 올바르지 않습니다.' });
      }
      fields.priority = req.body.priority;
    }
    const startDate = parseDate(req.body?.startDate);
    if (startDate !== undefined) fields.startDate = startDate;
    const dueDate = parseDate(req.body?.dueDate);
    if (dueDate !== undefined) fields.dueDate = dueDate;

    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
    const updated = await updateTask(task.id, fields);
    await notifyProjectMembers(project, task.id);
    res.json(toTaskDto(updated, { identifier: project.identifier, projectName: project.name }));
  });

  router.delete('/tasks/:id', async (req, res) => {
    const task = await findTaskById(req.params.id);
    if (!task) return res.status(404).json({ error: '업무를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, task.projectId);
    if (!project) return;
    await deleteTask(task.id);
    await notifyProjectMembers(project, null);
    res.json({ ok: true });
  });

  // ── 업무 댓글 ─────────────────────────────────────────────────────────

  router.post('/tasks/:id/comments', async (req, res) => {
    const task = await findTaskById(req.params.id);
    if (!task) return res.status(404).json({ error: '업무를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, task.projectId);
    if (!project) return;

    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    if (!text) return res.status(400).json({ error: '댓글 내용을 입력하세요.' });
    if (text.length > 2000) return res.status(400).json({ error: '댓글은 2000자 이내로 작성하세요.' });

    const sender = await findUserById(req.user.sub);
    const comment = await insertTaskComment({
      id: randomUUID(),
      taskId: task.id,
      projectId: project.id,
      senderId: req.user.sub,
      senderName: sender?.name ?? sender?.username ?? '알 수 없음',
      text,
    });
    await notifyProjectMembers(project, task.id);
    res.status(201).json(toTaskCommentDto(comment));
  });

  /** 업무/댓글이 바뀌면 그 프로젝트 구성원들이 열어둔 화면이 스스로 갱신하도록 알린다. */
  async function notifyProjectMembers(project, taskId) {
    const members = await listProjectMemberUsers(project.id);
    for (const member of members) {
      io.to(`user:${member.id}`).emit('project:changed', {
        teamId: project.teamId,
        projectId: project.id,
        taskId: taskId ?? undefined,
      });
    }
  }

  return router;
}
