import { randomUUID } from 'node:crypto';
import { Router } from 'express';
import {
  addProjectMembers,
  countTasksByProject,
  deleteProject,
  deleteTask,
  deleteTaskType,
  findProjectById,
  findProjectByIdentifier,
  findTaskById,
  findTaskTypeById,
  getProjectRole,
  insertProject,
  insertTask,
  insertTaskComment,
  insertTaskType,
  isProjectMember,
  listBrowsablePublicProjects,
  listProjectMemberUsers,
  listProjectsForUser,
  listRecentTaskComments,
  listReferencesForTasks,
  listTaskComments,
  listTaskTypes,
  listTaskTypesByIds,
  countChecklistItems,
  countSubtasks,
  deleteChecklistItem,
  findChecklistItemById,
  insertChecklistItem,
  listChecklistItems,
  listSubtasks,
  setTaskArchived,
  updateChecklistItem,
  listTasksByProject,
  listTasksInProjects,
  listTasksForAssignee,
  listUsersByIds,
  removeProjectMember,
  setProjectMemberRole,
  countProjectOwners,
  deleteNoteComment,
  findNoteCommentById,
  findNoteVersionById,
  insertNoteComment,
  listAutomationRuns,
  listNoteComments,
  listNoteVersions,
  snapshotNoteVersion,
  deleteAutomation,
  deleteTaskTemplate,
  findAutomationById,
  findTaskTemplateById,
  insertAutomation,
  insertTaskTemplate,
  listAutomations,
  listTaskTemplates,
  updateAutomation,
  updateTaskTemplate,
  deleteNote,
  findNoteById,
  insertNote,
  listNotesInProjects,
  updateNote,
  deleteTaskField,
  deleteTaskStatus,
  deleteTaskPriority,
  findFirstPriorityOfLevel,
  findFirstStatusOfCategory,
  findTaskPriorityById,
  insertTaskPriority,
  listTaskPriorities,
  listTaskPrioritiesByIds,
  reorderTaskPriorities,
  seedDefaultTaskPriorities,
  updateTaskPriority,
  findTaskFieldById,
  findTaskStatusById,
  insertTaskField,
  insertTaskStatus,
  listTaskFields,
  listTaskStatuses,
  listTaskStatusesByIds,
  reorderTaskStatuses,
  reorderTaskTypes,
  seedDefaultTaskStatuses,
  updateTaskField,
  updateTaskStatus,
  seedDefaultTaskTypes,
  setProjectFavorite,
  setTaskReferences,
  takeNextTaskSeq,
  updateProject,
  updateTask,
  updateTaskType,
} from './db/queries/projects.js';
import {
  countUnreadProjectNotifications,
  getNotificationPolicy,
  getNotificationSettings,
  listProjectNotifications,
  markProjectNotificationsRead,
  upsertNotificationPolicy,
  upsertNotificationSettings,
} from './db/queries/projectNotifications.js';
import { createProjectNotifier } from './projectNotify.js';
import { AUTOMATION_TRIGGERS, runAutomations, validateAutomationInput } from './projectAutomation.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { isTeamMember } from './db/queries/teams.js';
import { findUserById } from './db/queries/users.js';
import { teamAccess } from './access.js';
import { accountRole, canCreateProject, canManageProject } from './permissions.js';
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
    color: project.color ?? '#5B8DEF',
    isPublic: project.isPublic ?? false,
    archived: !!project.archivedAt,
    memberCount: project.memberCount ?? undefined,
    favorite: project.favorite ?? false,
    myRole: project.myRole ?? 'member',
    taskTotal: total,
    taskDone: done,
    createdAt: new Date(project.createdAt).getTime(),
  };
}

function toTaskPriorityDto(p) {
  return { id: p.id, projectId: p.projectId, name: p.name, color: p.color, level: p.level, position: p.position };
}

function toTaskStatusDto(s) {
  return { id: s.id, projectId: s.projectId, name: s.name, color: s.color, category: s.category, position: s.position };
}

function toTaskFieldDto(f) {
  return {
    id: f.id,
    projectId: f.projectId,
    name: f.name,
    kind: f.kind,
    options: Array.isArray(f.options) ? f.options : [],
    position: f.position,
  };
}

const FIELD_KINDS = ['text', 'number', 'date', 'select', 'multiSelect', 'progress'];
/** 선택지(options)가 필요한 필드 종류. */
const OPTION_FIELD_KINDS = ['select', 'multiSelect'];

const NOTE_TITLE_MAX = 100;
const NOTE_BODY_MAX = 50000;

function toNoteDto(note, names = new Map()) {
  return {
    id: note.id,
    projectId: note.projectId,
    projectName: note.projectName ?? null,
    projectColor: note.projectColor ?? null,
    title: note.title,
    preview: note.preview ?? undefined,
    body: note.body ?? undefined,
    createdBy: note.createdBy ?? null,
    createdByName: names.get(note.createdBy) ?? null,
    updatedBy: note.updatedBy ?? null,
    updatedByName: names.get(note.updatedBy) ?? null,
    createdAt: new Date(note.createdAt).getTime(),
    updatedAt: new Date(note.updatedAt).getTime(),
  };
}

async function noteNames(notes) {
  const ids = [...new Set(notes.flatMap((n) => [n.createdBy, n.updatedBy]).filter(Boolean))];
  const users = await listUsersByIds(ids);
  return new Map(users.map((u) => [u.id, u.name]));
}

function toTaskTypeDto(type) {
  return { id: type.id, projectId: type.projectId, name: type.name, color: type.color, position: type.position };
}

/**
 * 업무 목록에 유형/참조자/생성자를 한 번에 붙인다 — 화면마다 업무 몇 백 개를 그릴 수 있어서
 * 업무별로 따로 조회하지 않고 세 번의 조회(유형·참조자·사용자)로 묶는다.
 * [myUserId]를 주면 각 업무에 "내가 담당인지/참조인지"(myRole)도 붙는다.
 */
async function decorateTasks(tasks, myUserId = null) {
  const typeIds = [...new Set(tasks.map((t) => t.typeId).filter(Boolean))];
  const statusIds = [...new Set(tasks.map((t) => t.statusId).filter(Boolean))];
  const priorityIds = [...new Set(tasks.map((t) => t.priorityId).filter(Boolean))];
  const ids = tasks.map((t) => t.id);
  const [types, statuses, priorities, refs, creators, checklist, subtasks] = await Promise.all([
    listTaskTypesByIds(typeIds),
    listTaskStatusesByIds(statusIds),
    listTaskPrioritiesByIds(priorityIds),
    listReferencesForTasks(ids),
    listUsersByIds([...new Set(tasks.map((t) => t.createdBy).filter(Boolean))]),
    countChecklistItems(ids),
    countSubtasks(ids),
  ]);
  const typeById = new Map(types.map((t) => [t.id, t]));
  const statusById = new Map(statuses.map((s) => [s.id, s]));
  const priorityById = new Map(priorities.map((p) => [p.id, p]));
  const creatorById = new Map(creators.map((u) => [u.id, publicUser(u)]));
  return tasks.map((t) => {
    const type = t.typeId ? typeById.get(t.typeId) : null;
    const creator = t.createdBy ? creatorById.get(t.createdBy) : null;
    const referenceIds = refs[t.id] ?? [];
    let myRole = null;
    if (myUserId) {
      if (t.assigneeId === myUserId) myRole = 'assignee';
      else if (referenceIds.includes(myUserId)) myRole = 'reference';
    }
    const statusRow = t.statusId ? statusById.get(t.statusId) : null;
    const priorityRow = t.priorityId ? priorityById.get(t.priorityId) : null;
    return {
      ...t,
      type,
      statusRow,
      priorityRow,
      creator,
      referenceIds,
      myRole,
      checklist: checklist[t.id] ?? null,
      subtaskCount: subtasks[t.id] ?? 0,
    };
  });
}

function toTaskDto(task, { identifier, projectName } = {}) {
  const key = identifier ? taskKey(identifier, task.seq) : null;
  return {
    statusId: task.statusId ?? null,
    statusName: task.statusRow?.name ?? null,
    statusColor: task.statusRow?.color ?? null,
    priorityId: task.priorityId ?? null,
    priorityName: task.priorityRow?.name ?? null,
    priorityColor: task.priorityRow?.color ?? null,
    customValues: task.customValues ?? {},
    typeId: task.typeId ?? null,
    typeName: task.type?.name ?? null,
    typeColor: task.type?.color ?? null,
    referenceIds: task.referenceIds ?? [],
    myRole: task.myRole ?? null,
    creatorId: task.createdBy ?? null,
    creatorName: task.creator?.name ?? null,
    creatorAvatarType: task.creator?.avatarType ?? 'initial',
    creatorAvatarEmoji: task.creator?.avatarEmoji ?? null,
    creatorAvatarColor: task.creator?.avatarColor ?? null,
    creatorAvatarUrl: task.creator?.avatarUrl ?? null,
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
    parentTaskId: task.parentTaskId ?? null,
    archived: !!task.archivedAt,
    checklistDone: task.checklist?.done ?? 0,
    checklistTotal: task.checklist?.total ?? 0,
    subtaskCount: task.subtaskCount ?? 0,
  };
}

function toChecklistItemDto(item) {
  return {
    id: item.id,
    taskId: item.taskId,
    text: item.text,
    done: item.done,
    position: item.position,
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
  const notifier = createProjectNotifier(io);

  /** 종료된(보관된) 프로젝트는 읽기만 된다 — 쓰기 요청이면 409로 막고 true를 돌려준다. */
  function rejectIfArchived(res, project) {
    if (!project.archivedAt) return false;
    res.status(409).json({ error: '종료된 프로젝트입니다. 다시 시작한 뒤 수정할 수 있습니다.' });
    return true;
  }

  // 프로젝트는 정회원 이상만 쓴다(준회원은 목록·조회·수정 모두 불가). 서버 운영자는 예외.
  router.use(['/projects', '/tasks', '/task-types', '/task-statuses', '/task-priorities', '/task-fields', '/notes', '/project-notifications', '/task-templates', '/automations', '/note-comments', '/note-versions'], async (req, res, next) => {
    try {
      const user = await findUserById(req.user.sub);
      if (accountRole(user) === 'guest' && !user?.isServerAdmin) {
        return res.status(403).json({ error: '프로젝트는 정회원 이상만 이용할 수 있습니다.' });
      }
      next();
    } catch (e) {
      next(e);
    }
  });

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
    // ?archived=1이면 종료(보관)된 프로젝트만.
    const list = await listProjectsForUser(teamId, req.user.sub, { archivedOnly: req.query.archived === '1' });
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
    const [counts, myTasksRaw, comments] = await Promise.all([
      countTasksByProject(projectIds),
      listTasksForAssignee(teamId, req.user.sub),
      listRecentTaskComments(projectIds),
    ]);
    const myTasks = await decorateTasks(myTasksRaw, req.user.sub);

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

  /** 공개 프로젝트 둘러보기 — 내가 아직 안 들어간 공개 프로젝트(정회원 이상만 볼 수 있다). */
  router.get('/projects/browse', async (req, res) => {
    const teamId = req.query.teamId;
    if (typeof teamId !== 'string') return res.status(400).json({ error: 'teamId가 필요합니다.' });
    if (!(await isTeamMember(teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    const access = await teamAccess(teamId, req.user.sub);
    if (access.role === 'guest' && !access.isServerAdmin) return res.json([]);
    const list = await listBrowsablePublicProjects(teamId, req.user.sub);
    res.json(list.map((p) => toProjectDto(p)));
  });

  /** 공개 프로젝트에 초대 없이 참여한다 — 팀 멤버이면서 정회원 이상만. */
  router.post('/projects/:id/join', async (req, res) => {
    const project = await findProjectById(req.params.id);
    if (!project || !project.isPublic) return res.status(404).json({ error: '참여할 수 있는 공개 프로젝트가 아닙니다.' });
    if (!(await isTeamMember(project.teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    const access = await teamAccess(project.teamId, req.user.sub);
    if (access.role === 'guest' && !access.isServerAdmin) {
      return res.status(403).json({ error: '정회원 이상만 공개 프로젝트에 참여할 수 있습니다.' });
    }
    await addProjectMembers(project.id, [req.user.sub]);
    await notifyProjectMembers(project, null);
    io.to(`user:${req.user.sub}`).emit('project:changed', { teamId: project.teamId, projectId: project.id });
    res.json(toProjectDto({ ...project, favorite: false, myRole: 'member' }));
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

    const rawColor = req.body?.color;
    if (rawColor != null && (typeof rawColor !== 'string' || !/^#[0-9a-fA-F]{6}$/.test(rawColor))) {
      return res.status(400).json({ error: '색은 #RRGGBB 형식이어야 합니다.' });
    }
    const memberIds = Array.isArray(req.body?.memberIds) ? req.body.memberIds.filter((id) => typeof id === 'string') : [];
    const project = await insertProject({
      color: rawColor ? rawColor.toUpperCase() : '#5B8DEF',
      isPublic: req.body?.isPublic === true,
      id: randomUUID(),
      teamId,
      name,
      description: description || null,
      identifier: rawIdentifier,
      createdBy: req.user.sub,
    });
    await seedDefaultTaskTypes(project.id);
    await seedDefaultTaskStatuses(project.id);
    await seedDefaultTaskPriorities(project.id);
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
    if ('color' in (req.body ?? {})) {
      if (typeof req.body.color !== 'string' || !/^#[0-9A-Fa-f]{6}$/.test(req.body.color)) {
        return res.status(400).json({ error: '색상 형식이 올바르지 않습니다.' });
      }
      fields.color = req.body.color.toUpperCase();
    }
    if ('isPublic' in (req.body ?? {})) {
      if (typeof req.body.isPublic !== 'boolean') return res.status(400).json({ error: '공개 설정 값이 올바르지 않습니다.' });
      fields.isPublic = req.body.isPublic;
    }
    if ('archived' in (req.body ?? {})) {
      if (typeof req.body.archived !== 'boolean') return res.status(400).json({ error: '종료 여부 값이 올바르지 않습니다.' });
      fields.archivedAt = req.body.archived ? new Date() : null;
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
      const target = await findUserById(userId);
      if (accountRole(target) === 'guest') {
        return res.status(400).json({ error: '프로젝트는 정회원 이상만 참여할 수 있습니다.' });
      }
    }
    await addProjectMembers(project.id, userIds);
    for (const userId of userIds) {
      io.to(`user:${userId}`).emit('project:changed', { teamId: project.teamId, projectId: project.id });
    }
    const members = await listProjectMemberUsers(project.id);
    res.json(members.map((m) => ({ ...publicUser(m), projectRole: m.projectRole })));
  });

  /** 구성원 역할 변경 — 담당자(owner) 지정/해제. 담당자가 한 명도 없어지면 안 된다. */
  router.patch('/projects/:id/members/:userId', async (req, res) => {
    const project = await requireProjectManager(req, res, req.params.id);
    if (!project) return;
    const role = req.body?.role;
    if (role !== 'owner' && role !== 'member') return res.status(400).json({ error: '역할 값이 올바르지 않습니다.' });
    const current = await getProjectRole(project.id, req.params.userId);
    if (!current) return res.status(404).json({ error: '이 프로젝트의 구성원이 아닙니다.' });
    if (current === 'owner' && role === 'member' && (await countProjectOwners(project.id)) <= 1) {
      return res.status(400).json({ error: '담당자가 한 명은 있어야 합니다.' });
    }
    await setProjectMemberRole(project.id, req.params.userId, role);
    await notifyProjectMembers(project, null);
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
    // ?archived=1이면 보관함 — 평소 목록에서는 보관한 업무를 뺀다.
    const archivedOnly = req.query.archived === '1';
    const rows = await listTasksByProject(project.id, { archivedOnly });
    const list = await decorateTasks(rows, req.user.sub);
    res.json(list.map((t) => toTaskDto(t, { identifier: project.identifier, projectName: project.name })));
  });

  /** 내가 담당한 업무(팀 전체) — "내 업무" 화면이 쓴다. */
  router.get('/tasks/mine', async (req, res) => {
    const teamId = req.query.teamId;
    if (typeof teamId !== 'string') return res.status(400).json({ error: 'teamId가 필요합니다.' });
    if (!(await isTeamMember(teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    // 담당자로 지정된 업무 + 참조자로 걸린 업무 — "내 업무" 화면.
    const list = await decorateTasks(
      await listTasksForAssignee(teamId, req.user.sub, { includeReferenced: true }),
      req.user.sub,
    );
    res.json(list.map((t) => toTaskDto(t, { identifier: t.projectIdentifier, projectName: t.projectName })));
  });

  /** 내가 참여 중인 모든 프로젝트의 업무(팀 단위) — 사이드바 "캘린더"/"간트차트"가 쓴다. */
  router.get('/tasks/team', async (req, res) => {
    const teamId = req.query.teamId;
    if (typeof teamId !== 'string') return res.status(400).json({ error: 'teamId가 필요합니다.' });
    if (!(await isTeamMember(teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    const projects = await listProjectsForUser(teamId, req.user.sub);
    const list = await decorateTasks(await listTasksInProjects(projects.map((p) => p.id)), req.user.sub);
    res.json(list.map((t) => toTaskDto(t, { identifier: t.projectIdentifier, projectName: t.projectName })));
  });

  /**
   * 요청 본문의 상태를 (분류, 상태 id)로 푼다. statusId가 오면 그 상태(이 프로젝트 것이어야 함),
   * 예전 방식의 status(분류)만 오면 분류로만 돌려준다(상태 id는 호출한 쪽이 첫 상태로 채운다).
   */
  async function resolveStatus(project, body) {
    if (typeof body?.statusId === 'string') {
      const st = await findTaskStatusById(body.statusId);
      if (!st || st.projectId !== project.id) return { error: '이 프로젝트의 상태가 아닙니다.' };
      return { status: st.category, statusId: st.id };
    }
    if (body?.status !== undefined) {
      if (!TASK_STATUSES.includes(body.status)) return { error: '상태 값이 올바르지 않습니다.' };
      return { status: body.status };
    }
    return {};
  }

  /**
   * 요청 본문의 우선순위를 (단계, 우선순위 id)로 푼다 — resolveStatus와 같은 방식.
   * priorityId가 오면 그 우선순위(이 프로젝트 것이어야 함), 예전 방식의 priority(단계)만 오면 단계만.
   */
  async function resolvePriority(project, body) {
    if (typeof body?.priorityId === 'string') {
      const p = await findTaskPriorityById(body.priorityId);
      if (!p || p.projectId !== project.id) return { error: '이 프로젝트의 우선순위가 아닙니다.' };
      return { priority: p.level, priorityId: p.id };
    }
    if (body?.priority !== undefined) {
      if (!TASK_PRIORITIES.includes(body.priority)) return { error: '우선순위 값이 올바르지 않습니다.' };
      return { priority: body.priority };
    }
    return {};
  }

  /** 사용자 정의 필드 값 검증 + 기존 값과 합치기(null이면 그 값을 지운다). */
  async function validCustomValues(project, input, existing) {
    if (input === undefined || input === null) return { values: existing };
    if (typeof input !== 'object' || Array.isArray(input)) return { error: '사용자 정의 필드 값 형식이 올바르지 않습니다.' };
    const defs = new Map((await listTaskFields(project.id)).map((f) => [f.id, f]));
    const values = { ...existing };
    for (const [fieldId, value] of Object.entries(input)) {
      const def = defs.get(fieldId);
      if (!def) return { error: '이 프로젝트의 필드가 아닙니다.' };
      // 다중 선택은 빈 배열도 "값 없음"으로 본다.
      if (value === null || value === '' || (Array.isArray(value) && value.length === 0)) {
        delete values[fieldId];
        continue;
      }
      if (def.kind === 'text') {
        if (typeof value !== 'string' || value.length > 500) return { error: `"${def.name}"은(는) 500자 이내의 글자여야 합니다.` };
      } else if (def.kind === 'number') {
        if (typeof value !== 'number' || !Number.isFinite(value)) return { error: `"${def.name}"은(는) 숫자여야 합니다.` };
      } else if (def.kind === 'date') {
        if (typeof value !== 'number' || !Number.isFinite(value)) return { error: `"${def.name}"은(는) 날짜여야 합니다.` };
      } else if (def.kind === 'select') {
        if (typeof value !== 'string' || !(def.options ?? []).includes(value)) return { error: `"${def.name}"의 선택지에 없는 값입니다.` };
      } else if (def.kind === 'multiSelect') {
        if (!Array.isArray(value) || value.some((v) => typeof v !== 'string')) {
          return { error: `"${def.name}"은(는) 선택지 목록이어야 합니다.` };
        }
        const picked = [...new Set(value)];
        if (picked.some((v) => !(def.options ?? []).includes(v))) return { error: `"${def.name}"의 선택지에 없는 값입니다.` };
        values[fieldId] = picked;
        continue;
      } else if (def.kind === 'progress') {
        if (typeof value !== 'number' || !Number.isFinite(value) || value < 0 || value > 100) {
          return { error: `"${def.name}"은(는) 0~100 사이의 숫자여야 합니다.` };
        }
      }
      values[fieldId] = value;
    }
    return { values };
  }

  // ── 프로젝트 노트 ─────────────────────────────────────────────────────

  /**
   * 노트 목록(본문 제외). projectId를 주면 그 프로젝트, teamId를 주면 내가 참여 중인 이 팀의
   * 모든 프로젝트의 노트를 최근 수정 순으로 돌려준다.
   */
  router.get('/notes', async (req, res) => {
    const { projectId, teamId } = req.query;
    let projectIds;
    if (typeof projectId === 'string') {
      const project = await requireProjectMember(req, res, projectId);
      if (!project) return;
      projectIds = [project.id];
    } else if (typeof teamId === 'string') {
      if (!(await isTeamMember(teamId, req.user.sub))) {
        return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
      }
      projectIds = (await listProjectsForUser(teamId, req.user.sub)).map((p) => p.id);
    } else {
      return res.status(400).json({ error: 'projectId 또는 teamId가 필요합니다.' });
    }
    const notes = await listNotesInProjects(projectIds);
    const names = await noteNames(notes);
    res.json(notes.map((n) => toNoteDto(n, names)));
  });

  router.get('/notes/:id', async (req, res) => {
    const note = await findNoteById(req.params.id);
    if (!note) return res.status(404).json({ error: '노트를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, note.projectId);
    if (!project) return;
    const names = await noteNames([note]);
    res.json(toNoteDto({ ...note, projectName: project.name, projectColor: project.color }, names));
  });

  router.post('/projects/:id/notes', async (req, res) => {
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;
    if (rejectIfArchived(res, project)) return;
    const title = typeof req.body?.title === 'string' ? req.body.title.trim() : '';
    const body = typeof req.body?.body === 'string' ? req.body.body : '';
    if (!title) return res.status(400).json({ error: '노트 제목을 입력하세요.' });
    if (title.length > NOTE_TITLE_MAX) return res.status(400).json({ error: `제목은 ${NOTE_TITLE_MAX}자 이내로 입력하세요.` });
    if (body.length > NOTE_BODY_MAX) return res.status(400).json({ error: `내용은 ${NOTE_BODY_MAX}자 이내로 입력하세요.` });
    const note = await insertNote({
      projectId: project.id,
      title,
      body,
      createdBy: req.user.sub,
      updatedBy: req.user.sub,
    });
    await notifyProjectMembers(project, null);
    const names = await noteNames([note]);
    res.status(201).json(toNoteDto({ ...note, projectName: project.name, projectColor: project.color }, names));
  });

  /**
   * 수정 — 구성원이면 누구나. 두 사람이 동시에 고치다 덮어쓰지 않도록, 클라이언트가 열 때의
   * updatedAt을 baseUpdatedAt으로 보내면 그 사이 바뀌었을 때 409를 돌려준다.
   */
  router.patch('/notes/:id', async (req, res) => {
    const note = await findNoteById(req.params.id);
    if (!note) return res.status(404).json({ error: '노트를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, note.projectId);
    if (!project) return;
    if (rejectIfArchived(res, project)) return;
    const fields = {};
    if ('title' in (req.body ?? {})) {
      const title = typeof req.body.title === 'string' ? req.body.title.trim() : '';
      if (!title) return res.status(400).json({ error: '노트 제목을 입력하세요.' });
      if (title.length > NOTE_TITLE_MAX) return res.status(400).json({ error: `제목은 ${NOTE_TITLE_MAX}자 이내로 입력하세요.` });
      fields.title = title;
    }
    if ('body' in (req.body ?? {})) {
      if (typeof req.body.body !== 'string') return res.status(400).json({ error: '내용 형식이 올바르지 않습니다.' });
      if (req.body.body.length > NOTE_BODY_MAX) return res.status(400).json({ error: `내용은 ${NOTE_BODY_MAX}자 이내로 입력하세요.` });
      fields.body = req.body.body;
    }
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
    const base = req.body?.baseUpdatedAt;
    if (typeof base === 'number' && Math.abs(new Date(note.updatedAt).getTime() - base) > 1) {
      return res.status(409).json({ error: '다른 사람이 먼저 이 노트를 수정했습니다. 다시 불러온 뒤 고쳐주세요.' });
    }
    // 내용이 실제로 바뀌면 고치기 직전 버전을 이력에 남긴다.
    if ((fields.title ?? note.title) !== note.title || (fields.body ?? note.body) !== note.body) {
      await snapshotNoteVersion(note);
    }
    const updated = await updateNote(note.id, { ...fields, updatedBy: req.user.sub });
    await notifyProjectMembers(project, null);
    const names = await noteNames([updated]);
    res.json(toNoteDto({ ...updated, projectName: project.name, projectColor: project.color }, names));
  });

  // ── 노트 댓글 ──
  function toNoteCommentDto(c) {
    return {
      id: c.id,
      noteId: c.noteId,
      senderId: c.senderId ?? null,
      senderName: c.senderName,
      text: c.text,
      createdAt: new Date(c.createdAt).getTime(),
    };
  }

  router.get('/notes/:id/comments', async (req, res) => {
    const note = await findNoteById(req.params.id);
    if (!note) return res.status(404).json({ error: '노트를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, note.projectId);
    if (!project) return;
    res.json((await listNoteComments(note.id)).map(toNoteCommentDto));
  });

  router.post('/notes/:id/comments', async (req, res) => {
    const note = await findNoteById(req.params.id);
    if (!note) return res.status(404).json({ error: '노트를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, note.projectId);
    if (!project) return;
    if (rejectIfArchived(res, project)) return;
    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    if (!text) return res.status(400).json({ error: '댓글 내용을 입력하세요.' });
    if (text.length > 2000) return res.status(400).json({ error: '댓글은 2000자 이내로 작성하세요.' });
    const sender = await findUserById(req.user.sub);
    const c = await insertNoteComment({
      noteId: note.id,
      senderId: req.user.sub,
      senderName: sender?.name ?? sender?.username ?? '알 수 없음',
      text,
    });
    await notifyProjectMembers(project, null);
    res.status(201).json(toNoteCommentDto(c));
  });

  /** 댓글 삭제 — 쓴 사람, 프로젝트 담당자, 팀 소유자·관리자만. */
  router.delete('/note-comments/:id', async (req, res) => {
    const c = await findNoteCommentById(req.params.id);
    if (!c) return res.status(404).json({ error: '댓글을 찾을 수 없습니다.' });
    const note = await findNoteById(c.noteId);
    if (!note) return res.status(404).json({ error: '노트를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, note.projectId);
    if (!project) return;
    if (rejectIfArchived(res, project)) return;
    if (c.senderId !== req.user.sub) {
      const [access, myRole] = await Promise.all([
        teamAccess(project.teamId, req.user.sub),
        getProjectRole(project.id, req.user.sub),
      ]);
      if (!canManageProject({ ...access, isProjectOwner: myRole === 'owner' })) {
        return res.status(403).json({ error: '댓글을 지울 권한이 없습니다.' });
      }
    }
    await deleteNoteComment(c.id);
    await notifyProjectMembers(project, null);
    res.json({ ok: true });
  });

  // ── 노트 수정 이력 ──
  router.get('/notes/:id/versions', async (req, res) => {
    const note = await findNoteById(req.params.id);
    if (!note) return res.status(404).json({ error: '노트를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, note.projectId);
    if (!project) return;
    const versions = await listNoteVersions(note.id);
    const names = await noteNames(versions.map((v) => ({ createdBy: v.editedBy, updatedBy: null })));
    res.json(
      versions.map((v) => ({
        id: v.id,
        title: v.title,
        editedBy: v.editedBy ?? null,
        editedByName: names.get(v.editedBy) ?? null,
        editedAt: new Date(v.editedAt).getTime(),
      })),
    );
  });

  router.get('/note-versions/:id', async (req, res) => {
    const v = await findNoteVersionById(req.params.id);
    if (!v) return res.status(404).json({ error: '이력을 찾을 수 없습니다.' });
    const note = await findNoteById(v.noteId);
    if (!note) return res.status(404).json({ error: '노트를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, note.projectId);
    if (!project) return;
    const names = await noteNames([{ createdBy: v.editedBy, updatedBy: null }]);
    res.json({
      id: v.id,
      noteId: v.noteId,
      title: v.title,
      body: v.body,
      editedBy: v.editedBy ?? null,
      editedByName: names.get(v.editedBy) ?? null,
      editedAt: new Date(v.editedAt).getTime(),
    });
  });

  /** 이 버전으로 되돌린다 — 되돌리기 직전 내용도 이력에 남는다. */
  router.post('/notes/:id/restore', async (req, res) => {
    const note = await findNoteById(req.params.id);
    if (!note) return res.status(404).json({ error: '노트를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, note.projectId);
    if (!project) return;
    if (rejectIfArchived(res, project)) return;
    const v = typeof req.body?.versionId === 'string' ? await findNoteVersionById(req.body.versionId) : null;
    if (!v || v.noteId !== note.id) return res.status(400).json({ error: '되돌릴 이력을 찾을 수 없습니다.' });
    await snapshotNoteVersion(note);
    const updated = await updateNote(note.id, { title: v.title, body: v.body, updatedBy: req.user.sub });
    await notifyProjectMembers(project, null);
    const names = await noteNames([updated]);
    res.json(toNoteDto({ ...updated, projectName: project.name, projectColor: project.color }, names));
  });

  /** 삭제 — 쓴 사람, 프로젝트 담당자, 팀 소유자·관리자만. */
  router.delete('/notes/:id', async (req, res) => {
    const note = await findNoteById(req.params.id);
    if (!note) return res.status(404).json({ error: '노트를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, note.projectId);
    if (!project) return;
    if (rejectIfArchived(res, project)) return;
    if (note.createdBy !== req.user.sub) {
      const [access, myRole] = await Promise.all([
        teamAccess(project.teamId, req.user.sub),
        getProjectRole(project.id, req.user.sub),
      ]);
      if (!canManageProject({ ...access, isProjectOwner: myRole === 'owner' })) {
        return res.status(403).json({ error: '노트를 지울 권한이 없습니다.' });
      }
    }
    await deleteNote(note.id);
    await notifyProjectMembers(project, null);
    res.json({ ok: true });
  });

  // ── 업무 상태(프로젝트별) ─────────────────────────────────────────────

  router.get('/projects/:id/task-statuses', async (req, res) => {
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;
    res.json((await listTaskStatuses(project.id)).map(toTaskStatusDto));
  });

  function parseStatusFields(body, { partial }) {
    const fields = {};
    if (!partial || 'name' in (body ?? {})) {
      const name = typeof body?.name === 'string' ? body.name.trim() : '';
      if (!name) return { error: '상태 이름을 입력하세요.' };
      if (name.length > 20) return { error: '상태 이름은 20자 이내로 입력하세요.' };
      fields.name = name;
    }
    if ('color' in (body ?? {})) {
      if (typeof body.color !== 'string' || !/^#[0-9a-fA-F]{6}$/.test(body.color)) {
        return { error: '색은 #RRGGBB 형식이어야 합니다.' };
      }
      fields.color = body.color.toUpperCase();
    }
    if (!partial) {
      if (!TASK_STATUSES.includes(body?.category)) return { error: '분류(할 일/진행 중/완료)를 고르세요.' };
      fields.category = body.category;
    }
    return { fields };
  }

  router.post('/projects/:id/task-statuses', async (req, res) => {
    const project = await requireProjectManager(req, res, req.params.id);
    if (!project) return;
    const { fields, error } = parseStatusFields(req.body, { partial: false });
    if (error) return res.status(400).json({ error });
    try {
      const st = await insertTaskStatus({ projectId: project.id, ...fields });
      await notifyProjectMembers(project, null);
      res.status(201).json(toTaskStatusDto(st));
    } catch (e) {
      if ((e?.code ?? e?.cause?.code) === '23505') return res.status(409).json({ error: '이미 같은 이름의 상태가 있습니다.' });
      throw e;
    }
  });

  /** 열 순서 바꾸기 — 프로젝트의 상태 id를 원하는 순서로 전부 보낸다. */
  router.post('/projects/:id/task-statuses/order', async (req, res) => {
    const project = await requireProjectManager(req, res, req.params.id);
    if (!project) return;
    const ids = Array.isArray(req.body?.ids) ? req.body.ids : [];
    const current = (await listTaskStatuses(project.id)).map((s) => s.id);
    if (ids.length !== current.length || !current.every((id) => ids.includes(id))) {
      return res.status(400).json({ error: '상태 목록이 올바르지 않습니다.' });
    }
    await reorderTaskStatuses(project.id, ids);
    await notifyProjectMembers(project, null);
    res.json((await listTaskStatuses(project.id)).map(toTaskStatusDto));
  });

  router.patch('/task-statuses/:id', async (req, res) => {
    const st = await findTaskStatusById(req.params.id);
    if (!st) return res.status(404).json({ error: '상태를 찾을 수 없습니다.' });
    const project = await requireProjectManager(req, res, st.projectId);
    if (!project) return;
    const { fields, error } = parseStatusFields(req.body, { partial: true });
    if (error) return res.status(400).json({ error });
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
    try {
      const updated = await updateTaskStatus(st.id, fields);
      await notifyProjectMembers(project, null);
      res.json(toTaskStatusDto(updated));
    } catch (e) {
      if ((e?.code ?? e?.cause?.code) === '23505') return res.status(409).json({ error: '이미 같은 이름의 상태가 있습니다.' });
      throw e;
    }
  });

  /** 상태 삭제 — 같은 분류의 다른 상태가 있어야 하고, 이 상태이던 업무는 그쪽(첫 번째)으로 옮긴다. */
  router.delete('/task-statuses/:id', async (req, res) => {
    const st = await findTaskStatusById(req.params.id);
    if (!st) return res.status(404).json({ error: '상태를 찾을 수 없습니다.' });
    const project = await requireProjectManager(req, res, st.projectId);
    if (!project) return;
    const others = (await listTaskStatuses(project.id)).filter((s) => s.id !== st.id && s.category === st.category);
    if (others.length === 0) {
      return res.status(400).json({ error: '분류(할 일/진행 중/완료)마다 상태가 하나는 있어야 합니다.' });
    }
    await deleteTaskStatus(st.id, others[0].id);
    await notifyProjectMembers(project, null);
    res.json({ ok: true });
  });

  // ── 업무 우선순위(프로젝트별) ─────────────────────────────────────────

  router.get('/projects/:id/task-priorities', async (req, res) => {
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;
    res.json((await listTaskPriorities(project.id)).map(toTaskPriorityDto));
  });

  function parsePriorityFields(body, { partial }) {
    const fields = {};
    if (!partial || 'name' in (body ?? {})) {
      const name = typeof body?.name === 'string' ? body.name.trim() : '';
      if (!name) return { error: '우선순위 이름을 입력하세요.' };
      if (name.length > 20) return { error: '우선순위 이름은 20자 이내로 입력하세요.' };
      fields.name = name;
    }
    if ('color' in (body ?? {})) {
      if (typeof body.color !== 'string' || !/^#[0-9a-fA-F]{6}$/.test(body.color)) {
        return { error: '색은 #RRGGBB 형식이어야 합니다.' };
      }
      fields.color = body.color.toUpperCase();
    }
    if (!partial) {
      if (!TASK_PRIORITIES.includes(body?.level)) return { error: '단계(낮음/보통/높음)를 고르세요.' };
      fields.level = body.level;
    }
    return { fields };
  }

  router.post('/projects/:id/task-priorities', async (req, res) => {
    const project = await requireProjectManager(req, res, req.params.id);
    if (!project) return;
    const { fields, error } = parsePriorityFields(req.body, { partial: false });
    if (error) return res.status(400).json({ error });
    try {
      const row = await insertTaskPriority({ projectId: project.id, ...fields });
      await notifyProjectMembers(project, null);
      res.status(201).json(toTaskPriorityDto(row));
    } catch (e) {
      if ((e?.code ?? e?.cause?.code) === '23505') return res.status(409).json({ error: '이미 같은 이름의 우선순위가 있습니다.' });
      throw e;
    }
  });

  /** 순서 바꾸기 — 프로젝트의 우선순위 id를 원하는 순서로 전부 보낸다. */
  router.post('/projects/:id/task-priorities/order', async (req, res) => {
    const project = await requireProjectManager(req, res, req.params.id);
    if (!project) return;
    const ids = Array.isArray(req.body?.ids) ? req.body.ids : [];
    const current = (await listTaskPriorities(project.id)).map((p) => p.id);
    if (ids.length !== current.length || !current.every((id) => ids.includes(id))) {
      return res.status(400).json({ error: '우선순위 목록이 올바르지 않습니다.' });
    }
    await reorderTaskPriorities(project.id, ids);
    await notifyProjectMembers(project, null);
    res.json((await listTaskPriorities(project.id)).map(toTaskPriorityDto));
  });

  router.patch('/task-priorities/:id', async (req, res) => {
    const row = await findTaskPriorityById(req.params.id);
    if (!row) return res.status(404).json({ error: '우선순위를 찾을 수 없습니다.' });
    const project = await requireProjectManager(req, res, row.projectId);
    if (!project) return;
    const { fields, error } = parsePriorityFields(req.body, { partial: true });
    if (error) return res.status(400).json({ error });
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
    try {
      const updated = await updateTaskPriority(row.id, fields);
      await notifyProjectMembers(project, null);
      res.json(toTaskPriorityDto(updated));
    } catch (e) {
      if ((e?.code ?? e?.cause?.code) === '23505') return res.status(409).json({ error: '이미 같은 이름의 우선순위가 있습니다.' });
      throw e;
    }
  });

  /** 삭제 — 같은 단계의 다른 우선순위가 있어야 하고, 그 업무는 그쪽(첫 번째)으로 옮긴다. */
  router.delete('/task-priorities/:id', async (req, res) => {
    const row = await findTaskPriorityById(req.params.id);
    if (!row) return res.status(404).json({ error: '우선순위를 찾을 수 없습니다.' });
    const project = await requireProjectManager(req, res, row.projectId);
    if (!project) return;
    const others = (await listTaskPriorities(project.id)).filter((p) => p.id !== row.id && p.level === row.level);
    if (others.length === 0) {
      return res.status(400).json({ error: '단계(낮음/보통/높음)마다 우선순위가 하나는 있어야 합니다.' });
    }
    await deleteTaskPriority(row.id, others[0].id);
    await notifyProjectMembers(project, null);
    res.json({ ok: true });
  });

  // ── 사용자 정의 필드(프로젝트별) ──────────────────────────────────────

  router.get('/projects/:id/task-fields', async (req, res) => {
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;
    res.json((await listTaskFields(project.id)).map(toTaskFieldDto));
  });

  function parseFieldFields(body, { partial }) {
    const fields = {};
    if (!partial || 'name' in (body ?? {})) {
      const name = typeof body?.name === 'string' ? body.name.trim() : '';
      if (!name) return { error: '필드 이름을 입력하세요.' };
      if (name.length > 20) return { error: '필드 이름은 20자 이내로 입력하세요.' };
      fields.name = name;
    }
    if (!partial) {
      if (!FIELD_KINDS.includes(body?.kind)) return { error: '필드 종류가 올바르지 않습니다.' };
      fields.kind = body.kind;
    }
    if ('options' in (body ?? {}) || (!partial && OPTION_FIELD_KINDS.includes(body?.kind))) {
      const raw = Array.isArray(body?.options) ? body.options : [];
      const options = [...new Set(raw.filter((o) => typeof o === 'string').map((o) => o.trim()).filter(Boolean))];
      if (options.some((o) => o.length > 30)) return { error: '선택지는 30자 이내로 입력하세요.' };
      if (options.length > 30) return { error: '선택지는 30개까지 만들 수 있습니다.' };
      fields.options = options;
    }
    return { fields };
  }

  router.post('/projects/:id/task-fields', async (req, res) => {
    const project = await requireProjectManager(req, res, req.params.id);
    if (!project) return;
    const { fields, error } = parseFieldFields(req.body, { partial: false });
    if (error) return res.status(400).json({ error });
    if (OPTION_FIELD_KINDS.includes(fields.kind) && (fields.options ?? []).length === 0) {
      return res.status(400).json({ error: '선택 필드는 선택지가 하나 이상 필요합니다.' });
    }
    if ((await listTaskFields(project.id)).length >= 20) {
      return res.status(400).json({ error: '필드는 프로젝트마다 20개까지 만들 수 있습니다.' });
    }
    try {
      const f = await insertTaskField({ projectId: project.id, ...fields });
      await notifyProjectMembers(project, null);
      res.status(201).json(toTaskFieldDto(f));
    } catch (e) {
      if ((e?.code ?? e?.cause?.code) === '23505') return res.status(409).json({ error: '이미 같은 이름의 필드가 있습니다.' });
      throw e;
    }
  });

  router.patch('/task-fields/:id', async (req, res) => {
    const f = await findTaskFieldById(req.params.id);
    if (!f) return res.status(404).json({ error: '필드를 찾을 수 없습니다.' });
    const project = await requireProjectManager(req, res, f.projectId);
    if (!project) return;
    const { fields, error } = parseFieldFields(req.body, { partial: true });
    if (error) return res.status(400).json({ error });
    if ('options' in fields && !OPTION_FIELD_KINDS.includes(f.kind)) delete fields.options;
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
    if (fields.options && fields.options.length === 0) return res.status(400).json({ error: '선택지가 하나 이상 필요합니다.' });
    try {
      const updated = await updateTaskField(f.id, fields);
      await notifyProjectMembers(project, null);
      res.json(toTaskFieldDto(updated));
    } catch (e) {
      if ((e?.code ?? e?.cause?.code) === '23505') return res.status(409).json({ error: '이미 같은 이름의 필드가 있습니다.' });
      throw e;
    }
  });

  router.delete('/task-fields/:id', async (req, res) => {
    const f = await findTaskFieldById(req.params.id);
    if (!f) return res.status(404).json({ error: '필드를 찾을 수 없습니다.' });
    const project = await requireProjectManager(req, res, f.projectId);
    if (!project) return;
    await deleteTaskField(f.id);
    await notifyProjectMembers(project, null);
    res.json({ ok: true });
  });

  // ── 업무 유형(프로젝트별) ─────────────────────────────────────────────

  router.get('/projects/:id/task-types', async (req, res) => {
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;
    res.json((await listTaskTypes(project.id)).map(toTaskTypeDto));
  });

  function parseTypeFields(body, { partial }) {
    const fields = {};
    if (!partial || 'name' in (body ?? {})) {
      const name = typeof body?.name === 'string' ? body.name.trim() : '';
      if (!name) return { error: '유형 이름을 입력하세요.' };
      if (name.length > 20) return { error: '유형 이름은 20자 이내로 입력하세요.' };
      fields.name = name;
    }
    if ('color' in (body ?? {})) {
      if (typeof body.color !== 'string' || !/^#[0-9a-fA-F]{6}$/.test(body.color)) {
        return { error: '색은 #RRGGBB 형식이어야 합니다.' };
      }
      fields.color = body.color.toUpperCase();
    }
    return { fields };
  }

  /** 유형 순서 저장 — 말풍선을 끌어다 놓으면 전체 id를 원하는 순서로 보낸다. */
  router.post('/projects/:id/task-types/order', async (req, res) => {
    const project = await requireProjectManager(req, res, req.params.id);
    if (!project) return;
    const ids = Array.isArray(req.body?.ids) ? req.body.ids : [];
    const current = (await listTaskTypes(project.id)).map((t) => t.id);
    if (ids.length !== current.length || !current.every((id) => ids.includes(id))) {
      return res.status(400).json({ error: '유형 목록이 올바르지 않습니다.' });
    }
    await reorderTaskTypes(project.id, ids);
    await notifyProjectMembers(project, null);
    res.json((await listTaskTypes(project.id)).map(toTaskTypeDto));
  });

  router.post('/projects/:id/task-types', async (req, res) => {
    const project = await requireProjectManager(req, res, req.params.id);
    if (!project) return;
    const { fields, error } = parseTypeFields(req.body, { partial: false });
    if (error) return res.status(400).json({ error });
    try {
      const type = await insertTaskType({ projectId: project.id, ...fields });
      await notifyProjectMembers(project, null);
      res.status(201).json(toTaskTypeDto(type));
    } catch (e) {
      if ((e?.code ?? e?.cause?.code) === '23505') return res.status(409).json({ error: '이미 같은 이름의 유형이 있습니다.' });
      throw e;
    }
  });

  router.patch('/task-types/:id', async (req, res) => {
    const type = await findTaskTypeById(req.params.id);
    if (!type) return res.status(404).json({ error: '유형을 찾을 수 없습니다.' });
    const project = await requireProjectManager(req, res, type.projectId);
    if (!project) return;
    const { fields, error } = parseTypeFields(req.body, { partial: true });
    if (error) return res.status(400).json({ error });
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
    try {
      const updated = await updateTaskType(type.id, fields);
      await notifyProjectMembers(project, null);
      res.json(toTaskTypeDto(updated));
    } catch (e) {
      if ((e?.code ?? e?.cause?.code) === '23505') return res.status(409).json({ error: '이미 같은 이름의 유형이 있습니다.' });
      throw e;
    }
  });

  router.delete('/task-types/:id', async (req, res) => {
    const type = await findTaskTypeById(req.params.id);
    if (!type) return res.status(404).json({ error: '유형을 찾을 수 없습니다.' });
    const project = await requireProjectManager(req, res, type.projectId);
    if (!project) return;
    await deleteTaskType(type.id);
    await notifyProjectMembers(project, null);
    res.json({ ok: true });
  });

  router.post('/projects/:id/tasks', async (req, res) => {
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;
    if (rejectIfArchived(res, project)) return;

    const title = typeof req.body?.title === 'string' ? req.body.title.trim() : '';
    if (!title) return res.status(400).json({ error: '업무 제목을 입력하세요.' });
    if (title.length > 200) return res.status(400).json({ error: '업무 제목은 200자 이내로 입력하세요.' });

    const resolved = await resolveStatus(project, req.body);
    if (resolved.error) return res.status(400).json({ error: resolved.error });
    const status = resolved.status ?? 'todo';
    const statusId = resolved.statusId ?? (await findFirstStatusOfCategory(project.id, status))?.id ?? null;
    const custom = await validCustomValues(project, req.body?.customValues, {});
    if (custom.error) return res.status(400).json({ error: custom.error });
    const resolvedPriority = await resolvePriority(project, req.body);
    if (resolvedPriority.error) return res.status(400).json({ error: resolvedPriority.error });
    const priority = resolvedPriority.priority ?? 'normal';
    // 우선순위를 아예 안 보낸 업무(예: 상세 패널의 "+ 새 하위 업무")는 비워 둔다 — 화면에
    // "—"로 나오고 나중에 배지를 눌러 정하면 된다. 단계만 보냈으면(템플릿 등) 그 단계의 첫
    // 우선순위로 맞춘다. priority(단계)는 정렬·통계용이라 항상 값이 있어야 해서 기본값을 쓴다.
    const priorityGiven =
      req.body?.priorityId !== undefined || req.body?.priority !== undefined;
    const priorityId = priorityGiven
      ? (resolvedPriority.priorityId ?? (await findFirstPriorityOfLevel(project.id, priority))?.id ?? null)
      : null;
    const assigneeId = typeof req.body?.assigneeId === 'string' ? req.body.assigneeId : null;
    if (assigneeId && !(await isProjectMember(project.id, assigneeId))) {
      return res.status(400).json({ error: '담당자는 프로젝트 구성원 중에서 고를 수 있습니다.' });
    }

    const typeId = typeof req.body?.typeId === 'string' ? req.body.typeId : null;
    if (typeId) {
      const type = await findTaskTypeById(typeId);
      if (!type || type.projectId !== project.id) return res.status(400).json({ error: '이 프로젝트의 유형이 아닙니다.' });
    }
    const referenceIds = await validReferenceIds(project, req.body?.referenceIds);
    if (referenceIds === null) return res.status(400).json({ error: '참조자는 프로젝트 구성원 중에서 고를 수 있습니다.' });

    // 하위 업무로 만들 때 — 부모는 같은 프로젝트의 업무여야 하고, 두 단계까지만 허용한다
    // (하위 업무의 하위 업무는 만들지 않는다 — 목록 들여쓰기가 끝없이 깊어진다).
    const parentTaskId = typeof req.body?.parentTaskId === 'string' ? req.body.parentTaskId : null;
    if (parentTaskId) {
      const parent = await findTaskById(parentTaskId);
      if (!parent || parent.projectId !== project.id) {
        return res.status(400).json({ error: '이 프로젝트의 업무가 아닙니다.' });
      }
      if (parent.parentTaskId) {
        return res.status(400).json({ error: '하위 업무에는 또 하위 업무를 둘 수 없습니다.' });
      }
    }

    const seq = await takeNextTaskSeq(project.id);
    const inserted = await insertTask({
      id: randomUUID(),
      projectId: project.id,
      seq,
      parentTaskId,
      title,
      description: typeof req.body?.description === 'string' ? req.body.description.trim() || null : null,
      assigneeId,
      status,
      statusId,
      customValues: custom.values,
      priority,
      priorityId,
      typeId,
      startDate: parseDate(req.body?.startDate) ?? null,
      dueDate: parseDate(req.body?.dueDate) ?? null,
      createdBy: req.user.sub,
      completedAt: status === 'done' ? new Date() : null,
    });
    if (referenceIds.length > 0) await setTaskReferences(inserted.id, referenceIds);
    // 자동화 규칙 실행 — 결과(자동 배정 등)가 응답과 다른 사람들의 화면 갱신에 이미 반영되도록 먼저 돌린다.
    const task = await runAutomations({ project, task: inserted, trigger: 'task_created', notifier });
    await notifyProjectMembers(project, task.id);
    await notifyTaskEvents(project, inserted, req.user.sub, {
      assigneeId: inserted.assigneeId,
      addedReferenceIds: referenceIds,
      created: true,
    });
    const [decorated] = await decorateTasks([task], req.user.sub);
    res.status(201).json(toTaskDto(decorated, { identifier: project.identifier, projectName: project.name }));
  });

  router.get('/tasks/:id', async (req, res) => {
    const task = await findTaskById(req.params.id);
    if (!task) return res.status(404).json({ error: '업무를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, task.projectId);
    if (!project) return;
    const [comments, checklist, subtaskRows] = await Promise.all([
      listTaskComments(task.id),
      listChecklistItems(task.id),
      listSubtasks(task.id),
    ]);
    const [decorated] = await decorateTasks([task], req.user.sub);
    const subtasks = await decorateTasks(subtaskRows, req.user.sub);
    res.json({
      ...toTaskDto(decorated, { identifier: project.identifier, projectName: project.name }),
      comments: comments.map(toTaskCommentDto),
      checklist: checklist.map(toChecklistItemDto),
      subtasks: subtasks.map((t) =>
        toTaskDto(t, { identifier: project.identifier, projectName: project.name }),
      ),
    });
  });

  // ── 체크리스트 ────────────────────────────────────────────────────────
  //
  // 업무를 볼 수 있으면(=프로젝트 구성원) 체크리스트도 고칠 수 있다 — 그 업무를 같이 하는
  // 사람들이 진행을 표시하는 용도라 따로 권한을 더 두지 않는다.

  async function requireTaskForChecklist(req, res) {
    const task = await findTaskById(req.params.id ?? req.params.taskId);
    if (!task) {
      res.status(404).json({ error: '업무를 찾을 수 없습니다.' });
      return null;
    }
    const project = await requireProjectMember(req, res, task.projectId);
    if (!project) return null;
    if (rejectIfArchived(res, project)) return null;
    return { task, project };
  }

  router.post('/tasks/:id/checklist', async (req, res) => {
    const found = await requireTaskForChecklist(req, res);
    if (!found) return;
    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    if (!text) return res.status(400).json({ error: '체크리스트 내용을 입력하세요.' });
    if (text.length > 200) return res.status(400).json({ error: '체크리스트는 200자 이내로 입력하세요.' });
    const items = await listChecklistItems(found.task.id);
    if (items.length >= 50) return res.status(400).json({ error: '체크리스트는 업무당 50개까지 만들 수 있습니다.' });
    const item = await insertChecklistItem(found.task.id, text);
    await notifyProjectMembers(found.project, found.task.id);
    res.status(201).json(toChecklistItemDto(item));
  });

  router.patch('/checklist-items/:id', async (req, res) => {
    const item = await findChecklistItemById(req.params.id);
    if (!item) return res.status(404).json({ error: '항목을 찾을 수 없습니다.' });
    const task = await findTaskById(item.taskId);
    const project = await requireProjectMember(req, res, task.projectId);
    if (!project) return;
    if (rejectIfArchived(res, project)) return;
    const fields = {};
    if (typeof req.body?.done === 'boolean') fields.done = req.body.done;
    if (typeof req.body?.text === 'string') {
      const text = req.body.text.trim();
      if (!text) return res.status(400).json({ error: '체크리스트 내용을 입력하세요.' });
      fields.text = text.slice(0, 200);
    }
    const updated = await updateChecklistItem(item.id, fields);
    await notifyProjectMembers(project, task.id);
    res.json(toChecklistItemDto(updated));
  });

  router.delete('/checklist-items/:id', async (req, res) => {
    const item = await findChecklistItemById(req.params.id);
    if (!item) return res.status(404).json({ error: '항목을 찾을 수 없습니다.' });
    const task = await findTaskById(item.taskId);
    const project = await requireProjectMember(req, res, task.projectId);
    if (!project) return;
    if (rejectIfArchived(res, project)) return;
    await deleteChecklistItem(item.id);
    await notifyProjectMembers(project, task.id);
    res.json({ ok: true });
  });

  // ── 보관 · 복사 · 이동 ────────────────────────────────────────────────

  router.post('/tasks/:id/archive', async (req, res) => {
    const found = await requireTaskForChecklist(req, res);
    if (!found) return;
    const archived = req.body?.archived !== false;
    const updated = await setTaskArchived(found.task.id, archived);
    await notifyProjectMembers(found.project, found.task.id);
    const [decorated] = await decorateTasks([updated], req.user.sub);
    res.json(
      toTaskDto(decorated, {
        identifier: found.project.identifier,
        projectName: found.project.name,
      }),
    );
  });

  /** 같은 프로젝트에 사본을 만든다 — 참조자와 체크리스트까지 같이 복사하고, 댓글·하위 업무는
   * 원본에 딸린 기록이라 복사하지 않는다. 제목 뒤에 "(사본)"을 붙인다. */
  router.post('/tasks/:id/copy', async (req, res) => {
    const found = await requireTaskForChecklist(req, res);
    if (!found) return;
    const { task, project } = found;
    const seq = await takeNextTaskSeq(project.id);
    const copy = await insertTask({
      id: randomUUID(),
      projectId: task.projectId,
      seq,
      parentTaskId: task.parentTaskId,
      title: `${task.title} (사본)`.slice(0, 200),
      description: task.description,
      assigneeId: task.assigneeId,
      status: task.status,
      statusId: task.statusId,
      customValues: task.customValues,
      priority: task.priority,
      priorityId: task.priorityId,
      typeId: task.typeId,
      startDate: task.startDate,
      dueDate: task.dueDate,
      createdBy: req.user.sub,
      completedAt: task.status === 'done' ? new Date() : null,
    });
    const refs = (await listReferencesForTasks([task.id]))[task.id] ?? [];
    if (refs.length > 0) await setTaskReferences(copy.id, refs);
    for (const item of await listChecklistItems(task.id)) {
      const made = await insertChecklistItem(copy.id, item.text);
      if (item.done) await updateChecklistItem(made.id, { done: true });
    }
    await notifyProjectMembers(project, copy.id);
    const [decorated] = await decorateTasks([copy], req.user.sub);
    res.status(201).json(
      toTaskDto(decorated, { identifier: project.identifier, projectName: project.name }),
    );
  });

  /** 다른 프로젝트로 옮긴다. 업무 번호는 새 프로젝트에서 다시 받고, 그 프로젝트에만 있는
   * 값(상태·유형·우선순위·사용자 정의 필드·참조자·하위 업무 관계)은 비우거나 기본값으로
   * 맞춘다 — 옮긴 뒤에도 남아 있으면 다른 프로젝트의 항목을 가리키게 된다. */
  router.post('/tasks/:id/move', async (req, res) => {
    const found = await requireTaskForChecklist(req, res);
    if (!found) return;
    const { task } = found;
    const targetId = typeof req.body?.projectId === 'string' ? req.body.projectId : null;
    if (!targetId) return res.status(400).json({ error: '옮길 프로젝트를 고르세요.' });
    if (targetId === task.projectId) return res.status(400).json({ error: '이미 그 프로젝트에 있습니다.' });
    const target = await requireProjectMember(req, res, targetId);
    if (!target) return;
    if (rejectIfArchived(res, target)) return;

    const seq = await takeNextTaskSeq(target.id);
    const status = await findFirstStatusOfCategory(target.id, task.status);
    const priority = await findFirstPriorityOfLevel(target.id, task.priority);
    const moved = await updateTask(task.id, {
      projectId: target.id,
      seq,
      statusId: status?.id ?? null,
      priorityId: priority?.id ?? null,
      typeId: null,
      customValues: {},
      parentTaskId: null,
    });
    // 참조자·담당자는 새 프로젝트 구성원이 아닐 수 있다 — 구성원이 아닌 사람은 뗀다.
    const refs = (await listReferencesForTasks([task.id]))[task.id] ?? [];
    const keep = [];
    for (const userId of refs) {
      if (await isProjectMember(target.id, userId)) keep.push(userId);
    }
    await setTaskReferences(task.id, keep);
    if (moved.assigneeId && !(await isProjectMember(target.id, moved.assigneeId))) {
      await updateTask(task.id, { assigneeId: null });
    }
    // 하위 업무는 부모를 따라오지 않는다 — 부모만 옮기고 하위는 원래 프로젝트에 남긴다.
    await notifyProjectMembers(found.project, null);
    await notifyProjectMembers(target, task.id);
    const fresh = await findTaskById(task.id);
    const [decorated] = await decorateTasks([fresh], req.user.sub);
    res.json(toTaskDto(decorated, { identifier: target.identifier, projectName: target.name }));
  });

  router.patch('/tasks/:id', async (req, res) => {
    const task = await findTaskById(req.params.id);
    if (!task) return res.status(404).json({ error: '업무를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, task.projectId);
    if (!project) return;
    if (rejectIfArchived(res, project)) return;

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
    if ('status' in (req.body ?? {}) || 'statusId' in (req.body ?? {})) {
      const resolved = await resolveStatus(project, req.body);
      if (resolved.error) return res.status(400).json({ error: resolved.error });
      fields.status = resolved.status;
      fields.statusId = resolved.statusId ?? (await findFirstStatusOfCategory(project.id, resolved.status))?.id ?? null;
      // 완료로 바뀐 순간만 기록하고, 다시 진행 중으로 되돌리면 지운다(완료율 계산에 쓴다).
      if (resolved.status !== task.status) fields.completedAt = resolved.status === 'done' ? new Date() : null;
    }
    if ('parentTaskId' in (req.body ?? {})) {
      const parentTaskId = typeof req.body.parentTaskId === 'string' ? req.body.parentTaskId : null;
      if (parentTaskId) {
        if (parentTaskId === task.id) {
          return res.status(400).json({ error: '자기 자신을 상위 업무로 둘 수 없습니다.' });
        }
        const parent = await findTaskById(parentTaskId);
        if (!parent || parent.projectId !== project.id) {
          return res.status(400).json({ error: '이 프로젝트의 업무가 아닙니다.' });
        }
        // 두 단계까지만 — 하위 업무를 상위로 삼거나, 이미 하위를 거느린 업무를 하위로 내릴 수 없다.
        if (parent.parentTaskId) {
          return res.status(400).json({ error: '하위 업무를 상위 업무로 둘 수 없습니다.' });
        }
        const mine = await listSubtasks(task.id);
        if (mine.length > 0) {
          return res.status(400).json({ error: '하위 업무가 있는 업무는 다른 업무의 하위로 둘 수 없습니다.' });
        }
      }
      fields.parentTaskId = parentTaskId;
    }
    if ('customValues' in (req.body ?? {})) {
      const custom = await validCustomValues(project, req.body.customValues, task.customValues ?? {});
      if (custom.error) return res.status(400).json({ error: custom.error });
      fields.customValues = custom.values;
    }
    if ('priority' in (req.body ?? {}) || 'priorityId' in (req.body ?? {})) {
      const resolved = await resolvePriority(project, req.body);
      if (resolved.error) return res.status(400).json({ error: resolved.error });
      fields.priority = resolved.priority;
      fields.priorityId =
        resolved.priorityId ?? (await findFirstPriorityOfLevel(project.id, resolved.priority))?.id ?? null;
    }
    if ('typeId' in (req.body ?? {})) {
      const typeId = typeof req.body.typeId === 'string' ? req.body.typeId : null;
      if (typeId) {
        const type = await findTaskTypeById(typeId);
        if (!type || type.projectId !== project.id) return res.status(400).json({ error: '이 프로젝트의 유형이 아닙니다.' });
      }
      fields.typeId = typeId;
    }
    let newReferenceIds;
    if ('referenceIds' in (req.body ?? {})) {
      newReferenceIds = await validReferenceIds(project, req.body.referenceIds);
      if (newReferenceIds === null) return res.status(400).json({ error: '참조자는 프로젝트 구성원 중에서 고를 수 있습니다.' });
    }
    const startDate = parseDate(req.body?.startDate);
    if (startDate !== undefined) fields.startDate = startDate;
    const dueDate = parseDate(req.body?.dueDate);
    if (dueDate !== undefined) fields.dueDate = dueDate;

    if (Object.keys(fields).length === 0 && newReferenceIds === undefined) {
      return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
    }
    const oldReferenceIds = newReferenceIds !== undefined ? ((await listReferencesForTasks([task.id]))[task.id] ?? []) : [];
    if ('assigneeId' in fields && fields.assigneeId !== task.assigneeId) fields.dueRemindedFor = null;
    let updated = Object.keys(fields).length > 0 ? await updateTask(task.id, fields) : task;
    if (newReferenceIds !== undefined) await setTaskReferences(task.id, newReferenceIds);
    const statusChanged = 'statusId' in fields && fields.statusId !== task.statusId;
    if (statusChanged) updated = await runAutomations({ project, task: updated, trigger: 'status_changed', notifier });
    await notifyProjectMembers(project, task.id);
    await notifyTaskEvents(project, updated, req.user.sub, {
      assigneeId: 'assigneeId' in fields && fields.assigneeId !== task.assigneeId ? fields.assigneeId : null,
      addedReferenceIds: (newReferenceIds ?? []).filter((id) => !oldReferenceIds.includes(id)),
      statusChanged,
      priorityChanged: 'priorityId' in fields && fields.priorityId !== task.priorityId,
      dueChanged:
        'dueDate' in fields &&
        (fields.dueDate?.getTime() ?? null) !== (task.dueDate ? new Date(task.dueDate).getTime() : null),
      typeChanged: 'typeId' in fields && fields.typeId !== task.typeId,
      customFieldChanged:
        'customValues' in fields &&
        JSON.stringify(fields.customValues) !== JSON.stringify(task.customValues ?? {}),
    });
    const [decorated] = await decorateTasks([updated], req.user.sub);
    res.json(toTaskDto(decorated, { identifier: project.identifier, projectName: project.name }));
  });

  router.delete('/tasks/:id', async (req, res) => {
    const task = await findTaskById(req.params.id);
    if (!task) return res.status(404).json({ error: '업무를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, task.projectId);
    if (!project) return;
    if (rejectIfArchived(res, project)) return;
    // 알림 대상은 지우기 전에 모아둔다(지운 뒤엔 참조자 목록도 같이 사라진다).
    const refs = (await listReferencesForTasks([task.id]))[task.id] ?? [];
    const owners = (await listProjectMemberUsers(project.id))
      .filter((m) => m.projectRole === 'owner')
      .map((m) => m.id);
    const actor = await findUserById(req.user.sub);
    const label = taskKey(project.identifier, task.seq);
    await deleteTask(task.id);
    await notifyProjectMembers(project, null);
    // project_notifications.task_id는 업무가 지워지면 같이 사라지므로(cascade) 안 붙인다.
    await notifier.notify({
      project,
      task: null,
      kind: 'deleted',
      actorId: req.user.sub,
      targetIds: [...owners, task.assigneeId, task.createdBy, ...refs],
      title: `${project.name} · ${label}`,
      body: `${actor?.name ?? actor?.username ?? '누군가'}님이 업무를 삭제했습니다: ${task.title}`,
    });
    res.json({ ok: true });
  });

  // ── 업무 댓글 ─────────────────────────────────────────────────────────

  router.post('/tasks/:id/comments', async (req, res) => {
    const task = await findTaskById(req.params.id);
    if (!task) return res.status(404).json({ error: '업무를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, task.projectId);
    if (!project) return;
    if (rejectIfArchived(res, project)) return;

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
    const refs = (await listReferencesForTasks([task.id]))[task.id] ?? [];
    await notifier.notify({
      project,
      task,
      kind: 'comment',
      actorId: req.user.sub,
      targetIds: [task.assigneeId, task.createdBy, ...refs],
      title: `${project.name} · ${taskKey(project.identifier, task.seq)}`,
      body: `${comment.senderName}: ${text.length > 80 ? `${text.slice(0, 80)}…` : text}`,
    });
    res.status(201).json(toTaskCommentDto(comment));
  });

  /** 업무가 만들어지거나 바뀔 때 배정/참조/상태 변경 알림을 보낸다(행동한 본인은 제외). */
  async function notifyTaskEvents(
    project,
    task,
    actorId,
    { assigneeId, addedReferenceIds, statusChanged, priorityChanged, dueChanged, typeChanged, customFieldChanged, created } = {},
  ) {
    const actor = await findUserById(actorId);
    const actorName = actor?.name ?? actor?.username ?? '누군가';
    const title = `${project.name} · ${taskKey(project.identifier, task.seq)}`;
    // 업무 변경 알림은 담당자와 참조자에게 간다(정책의 "업무 변경 알림" 항목들).
    const watchers = async () => [task.assigneeId, task.createdBy, ...((await listReferencesForTasks([task.id]))[task.id] ?? [])];
    const change = async (kind, body) =>
      notifier.notify({ project, task, kind, actorId, targetIds: await watchers(), title, body });
    if (assigneeId) {
      await notifier.notify({
        project,
        task,
        kind: 'assigned',
        actorId,
        targetIds: [assigneeId],
        title,
        body: `${actorName}님이 업무를 배정했습니다: ${task.title}`,
      });
    }
    if (addedReferenceIds?.length > 0) {
      await notifier.notify({
        project,
        task,
        kind: 'referenced',
        actorId,
        targetIds: addedReferenceIds,
        title,
        body: `${actorName}님이 참조자로 지정했습니다: ${task.title}`,
      });
    }
    if (statusChanged) {
      const st = task.statusId ? await findTaskStatusById(task.statusId) : null;
      await change('status', `${actorName}님이 상태를 '${st?.name ?? task.status}'(으)로 바꿨습니다: ${task.title}`);
    }
    if (priorityChanged) {
      const pr = task.priorityId ? await findTaskPriorityById(task.priorityId) : null;
      await change('priority', `${actorName}님이 우선순위를 '${pr?.name ?? task.priority}'(으)로 바꿨습니다: ${task.title}`);
    }
    if (dueChanged) {
      const when = task.dueDate ? new Date(task.dueDate).toISOString().slice(0, 10) : '없음';
      await change('due_date', `${actorName}님이 마감일을 ${when}(으)로 바꿨습니다: ${task.title}`);
    }
    if (typeChanged) {
      const type = task.typeId ? await findTaskTypeById(task.typeId) : null;
      await change('task_type', `${actorName}님이 유형을 '${type?.name ?? '없음'}'(으)로 바꿨습니다: ${task.title}`);
    }
    if (customFieldChanged) {
      await change('custom_field', `${actorName}님이 추가 정보를 바꿨습니다: ${task.title}`);
    }
    if (created) {
      // 업무가 새로 만들어지면 프로젝트 담당자(owner)에게 알린다.
      const owners = (await listProjectMemberUsers(project.id))
        .filter((m) => m.projectRole === 'owner')
        .map((m) => m.id);
      await notifier.notify({
        project,
        task,
        kind: 'created',
        actorId,
        targetIds: owners,
        title,
        body: `${actorName}님이 업무를 만들었습니다: ${task.title}`,
      });
    }
  }

  // ── 업무 템플릿 ───────────────────────────────────────────────────────

  function toTemplateDto(t) {
    return {
      id: t.id,
      projectId: t.projectId,
      name: t.name,
      title: t.title,
      description: t.description ?? null,
      priority: t.priority,
      typeId: t.typeId ?? null,
      assigneeId: t.assigneeId ?? null,
      dueOffsetDays: t.dueOffsetDays ?? null,
    };
  }

  /** 본문을 검증해 템플릿 필드로. partial이면 온 것만. */
  async function parseTemplateFields(project, body, { partial }) {
    const fields = {};
    if (!partial || 'name' in (body ?? {})) {
      const name = typeof body?.name === 'string' ? body.name.trim() : '';
      if (!name) return { error: '템플릿 이름을 입력하세요.' };
      if (name.length > 30) return { error: '템플릿 이름은 30자 이내로 입력하세요.' };
      fields.name = name;
    }
    if ('title' in (body ?? {})) {
      const title = typeof body.title === 'string' ? body.title.trim() : '';
      if (title.length > 200) return { error: '업무 제목은 200자 이내로 입력하세요.' };
      fields.title = title;
    }
    if ('description' in (body ?? {})) {
      const d = typeof body.description === 'string' ? body.description.trim() : '';
      fields.description = d || null;
    }
    if ('priority' in (body ?? {})) {
      if (!TASK_PRIORITIES.includes(body.priority)) return { error: '우선순위 값이 올바르지 않습니다.' };
      fields.priority = body.priority;
    }
    if ('typeId' in (body ?? {})) {
      if (body.typeId) {
        const type = await findTaskTypeById(body.typeId);
        if (!type || type.projectId !== project.id) return { error: '이 프로젝트의 유형이 아닙니다.' };
      }
      fields.typeId = body.typeId || null;
    }
    if ('assigneeId' in (body ?? {})) {
      if (body.assigneeId && !(await isProjectMember(project.id, body.assigneeId))) {
        return { error: '담당자는 프로젝트 구성원 중에서 고를 수 있습니다.' };
      }
      fields.assigneeId = body.assigneeId || null;
    }
    if ('dueOffsetDays' in (body ?? {})) {
      const v = body.dueOffsetDays;
      if (v !== null && (!Number.isInteger(v) || v < 0 || v > 3650)) return { error: '마감일은 0~3650일 사이로 입력하세요.' };
      fields.dueOffsetDays = v;
    }
    return { fields };
  }

  router.get('/projects/:id/task-templates', async (req, res) => {
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;
    res.json((await listTaskTemplates(project.id)).map(toTemplateDto));
  });

  router.post('/projects/:id/task-templates', async (req, res) => {
    const project = await requireProjectManager(req, res, req.params.id);
    if (!project) return;
    const { fields, error } = await parseTemplateFields(project, req.body, { partial: false });
    if (error) return res.status(400).json({ error });
    if ((await listTaskTemplates(project.id)).length >= 30) return res.status(400).json({ error: '템플릿은 30개까지 만들 수 있습니다.' });
    try {
      const t = await insertTaskTemplate({ projectId: project.id, createdBy: req.user.sub, ...fields });
      await notifyProjectMembers(project, null);
      res.status(201).json(toTemplateDto(t));
    } catch (e) {
      if ((e?.code ?? e?.cause?.code) === '23505') return res.status(409).json({ error: '이미 같은 이름의 템플릿이 있습니다.' });
      throw e;
    }
  });

  router.patch('/task-templates/:id', async (req, res) => {
    const t = await findTaskTemplateById(req.params.id);
    if (!t) return res.status(404).json({ error: '템플릿을 찾을 수 없습니다.' });
    const project = await requireProjectManager(req, res, t.projectId);
    if (!project) return;
    const { fields, error } = await parseTemplateFields(project, req.body, { partial: true });
    if (error) return res.status(400).json({ error });
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
    try {
      const updated = await updateTaskTemplate(t.id, fields);
      await notifyProjectMembers(project, null);
      res.json(toTemplateDto(updated));
    } catch (e) {
      if ((e?.code ?? e?.cause?.code) === '23505') return res.status(409).json({ error: '이미 같은 이름의 템플릿이 있습니다.' });
      throw e;
    }
  });

  router.delete('/task-templates/:id', async (req, res) => {
    const t = await findTaskTemplateById(req.params.id);
    if (!t) return res.status(404).json({ error: '템플릿을 찾을 수 없습니다.' });
    const project = await requireProjectManager(req, res, t.projectId);
    if (!project) return;
    await deleteTaskTemplate(t.id);
    await notifyProjectMembers(project, null);
    res.json({ ok: true });
  });

  // ── 자동화 규칙 ───────────────────────────────────────────────────────

  function toAutomationDto(a) {
    return {
      id: a.id,
      projectId: a.projectId,
      name: a.name,
      enabled: a.enabled,
      trigger: a.trigger,
      triggerStatusId: a.triggerStatusId ?? null,
      condition: a.condition ?? {},
      actions: a.actions ?? [],
    };
  }

  async function parseAutomationBody(project, body, { partial }) {
    const fields = {};
    if (!partial || 'name' in (body ?? {})) {
      const name = typeof body?.name === 'string' ? body.name.trim() : '';
      if (!name) return { error: '규칙 이름을 입력하세요.' };
      if (name.length > 40) return { error: '규칙 이름은 40자 이내로 입력하세요.' };
      fields.name = name;
    }
    if (!partial || 'trigger' in (body ?? {})) {
      if (!AUTOMATION_TRIGGERS.includes(body?.trigger)) return { error: '실행 시점을 고르세요.' };
      fields.trigger = body.trigger;
      fields.triggerStatusId = null;
      if (body.trigger === 'status_changed' && body.triggerStatusId) {
        const st = await findTaskStatusById(body.triggerStatusId);
        if (!st || st.projectId !== project.id) return { error: '이 프로젝트의 상태가 아닙니다.' };
        fields.triggerStatusId = st.id;
      }
    }
    if (!partial || 'actions' in (body ?? {}) || 'condition' in (body ?? {})) {
      const v = await validateAutomationInput(project, body ?? {}, { loadTypes: listTaskTypes });
      if (v.error) return { error: v.error };
      fields.condition = v.condition;
      fields.actions = v.actions;
    }
    if ('enabled' in (body ?? {})) {
      if (typeof body.enabled !== 'boolean') return { error: '사용 여부 값이 올바르지 않습니다.' };
      fields.enabled = body.enabled;
    }
    return { fields };
  }

  router.get('/projects/:id/automations', async (req, res) => {
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;
    res.json((await listAutomations(project.id)).map(toAutomationDto));
  });

  router.post('/projects/:id/automations', async (req, res) => {
    const project = await requireProjectManager(req, res, req.params.id);
    if (!project) return;
    const { fields, error } = await parseAutomationBody(project, req.body, { partial: false });
    if (error) return res.status(400).json({ error });
    if ((await listAutomations(project.id)).length >= 20) return res.status(400).json({ error: '규칙은 20개까지 만들 수 있습니다.' });
    const a = await insertAutomation({ projectId: project.id, createdBy: req.user.sub, ...fields });
    await notifyProjectMembers(project, null);
    res.status(201).json(toAutomationDto(a));
  });

  /** 수정 — 켜기/끄기만 보낼 수도 있고, 내용을 바꿀 때는 이름·시점·동작을 모두 다시 보낸다. */
  router.patch('/automations/:id', async (req, res) => {
    const a = await findAutomationById(req.params.id);
    if (!a) return res.status(404).json({ error: '규칙을 찾을 수 없습니다.' });
    const project = await requireProjectManager(req, res, a.projectId);
    if (!project) return;
    const onlyToggle = Object.keys(req.body ?? {}).every((k) => k === 'enabled');
    const { fields, error } = await parseAutomationBody(project, req.body, { partial: onlyToggle });
    if (error) return res.status(400).json({ error });
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
    const updated = await updateAutomation(a.id, fields);
    await notifyProjectMembers(project, null);
    res.json(toAutomationDto(updated));
  });

  router.delete('/automations/:id', async (req, res) => {
    const a = await findAutomationById(req.params.id);
    if (!a) return res.status(404).json({ error: '규칙을 찾을 수 없습니다.' });
    const project = await requireProjectManager(req, res, a.projectId);
    if (!project) return;
    await deleteAutomation(a.id);
    await notifyProjectMembers(project, null);
    res.json({ ok: true });
  });

  /** 자동화 실행 기록(최근 100개) — 프로젝트 구성원이면 볼 수 있다. */
  router.get('/projects/:id/automation-runs', async (req, res) => {
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;
    const runs = await listAutomationRuns(project.id);
    res.json(
      runs.map((r) => ({
        id: r.id,
        automationName: r.automationName,
        taskId: r.taskId ?? null,
        taskKey: r.taskKey ?? null,
        trigger: r.trigger,
        summary: r.summary,
        ok: r.ok,
        createdAt: new Date(r.createdAt).getTime(),
      })),
    );
  });

  // ── 프로젝트 알림 ─────────────────────────────────────────────────────

  /** 개인 설정 — 지금은 "이 프로젝트 알림 끄기" 하나. */
  function toSettingsDto(s) {
    return { muted: s.muted };
  }

  const POLICY_FIELDS = {
    status: 'onStatus',
    priority: 'onPriority',
    assigned: 'onAssigned',
    referenced: 'onReferenced',
    dueDate: 'onDueDate',
    taskType: 'onTaskType',
    customField: 'onCustomField',
    created: 'onCreated',
    deleted: 'onDeleted',
    comment: 'onComment',
    due: 'onDue',
  };

  function toPolicyDto(p) {
    return Object.fromEntries(Object.entries(POLICY_FIELDS).map(([key, col]) => [key, p[col] !== false]));
  }

  /** 프로젝트 알림 정책 — 구성원이면 볼 수 있고, 바꾸는 건 담당자·팀 소유자/관리자만. */
  router.get('/projects/:id/notification-policy', async (req, res) => {
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;
    res.json(toPolicyDto(await getNotificationPolicy(project.id)));
  });

  router.patch('/projects/:id/notification-policy', async (req, res) => {
    const project = await requireProjectManager(req, res, req.params.id);
    if (!project) return;
    const fields = {};
    for (const [key, col] of Object.entries(POLICY_FIELDS)) {
      if (key in (req.body ?? {})) {
        if (typeof req.body[key] !== 'boolean') return res.status(400).json({ error: '설정 값이 올바르지 않습니다.' });
        fields[col] = req.body[key];
      }
    }
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
    await notifyProjectMembers(project, null);
    res.json(toPolicyDto(await upsertNotificationPolicy(project.id, fields)));
  });

  /** 내 알림함(최근 50개) + 안 읽은 개수. */
  router.get('/project-notifications', async (req, res) => {
    const [rows, unreadCount] = await Promise.all([
      listProjectNotifications(req.user.sub, 50),
      countUnreadProjectNotifications(req.user.sub),
    ]);
    res.json({
      unreadCount,
      items: rows.map((n) => ({
        id: n.id,
        projectId: n.projectId,
        projectName: n.projectName,
        projectColor: n.projectColor,
        taskId: n.taskId ?? null,
        kind: n.kind,
        title: n.title,
        body: n.body,
        createdAt: new Date(n.createdAt).getTime(),
        read: !!n.readAt,
      })),
    });
  });

  /** 읽음 처리 — ids를 주면 그 알림만, 안 주면 전부. 내 다른 기기/창에도 새 개수를 알린다. */
  router.post('/project-notifications/read', async (req, res) => {
    const ids = Array.isArray(req.body?.ids) ? req.body.ids.filter((id) => typeof id === 'string') : null;
    await markProjectNotificationsRead(req.user.sub, ids);
    const unreadCount = await countUnreadProjectNotifications(req.user.sub);
    io.to(`user:${req.user.sub}`).emit('project:notification-sync', { unreadCount });
    res.json({ unreadCount });
  });

  router.get('/projects/:id/notification-settings', async (req, res) => {
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;
    res.json(toSettingsDto(await getNotificationSettings(req.user.sub, project.id)));
  });

  router.patch('/projects/:id/notification-settings', async (req, res) => {
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;
    if (typeof req.body?.muted !== 'boolean') return res.status(400).json({ error: '설정 값이 올바르지 않습니다.' });
    const fields = { muted: req.body.muted };
    res.json(toSettingsDto(await upsertNotificationSettings(req.user.sub, project.id, fields)));
  });

  /** 참조자 id 목록을 검증한다 — 프로젝트 구성원이 아닌 사람이 섞여 있으면 null. */
  async function validReferenceIds(project, raw) {
    const ids = Array.isArray(raw) ? [...new Set(raw.filter((id) => typeof id === 'string'))] : [];
    for (const id of ids) {
      if (!(await isProjectMember(project.id, id))) return null;
    }
    return ids;
  }

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
