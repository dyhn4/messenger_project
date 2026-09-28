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
  findTaskCommentById,
  updateTaskCommentText,
  deleteTaskComment,
  insertTaskActivities,
  listTaskActivities,
  listTaskTypes,
  listTaskTypesByIds,
  countChecklistItems,
  countSubtasks,
  countTaskComments,
  listProjectTemplates,
  findProjectTemplateById,
  insertProjectTemplate,
  updateProjectTemplate,
  deleteProjectTemplate,
  applyProjectTemplate,
  reorderTasks,
  deleteChecklistItem,
  findChecklistItemById,
  insertChecklistItem,
  listChecklistItems,
  mutateChecklist,
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
  updateNoteCommentText,
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
  takeNextNoteSeq,
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
  ensurePublicProjectMembers,
  ensurePublicMembershipsForUser,
  joinPublicProjectAutomatically,
  isPublicProjectEligible,
  listPublicEligibleUserIds,
  removeAutoMembers,
  listProjectFolders,
  countProjectFolders,
  insertProjectFolder,
  findProjectFolderById,
  updateProjectFolder,
  deleteProjectFolder,
  listFolderProjectIds,
  setProjectFolder,
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
import {
  AUTOMATION_TRIGGERS,
  runAutomations,
  validateAutomationGraph,
  validateAutomationInput,
} from './projectAutomation.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { isTeamMember } from './db/queries/teams.js';
import { findUserById } from './db/queries/users.js';
import { teamAccess } from './access.js';
import { accountRole, canCreateProject, canManageProject } from './permissions.js';
import { publicUser } from './users.js';
import { sanitizeTextFormat } from './textFormat.js';
import { resolveRawUrl, signFileUrl } from './upload.js';

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
    // 이 프로젝트를 만든(또는 이 프로젝트로 저장한) 프로젝트 템플릿 — 지워졌으면 null.
    templateId: project.templateId ?? null,
    noteEditPermission: project.noteEditPermission ?? 'all',
    noteDeletePermission: project.noteDeletePermission ?? 'creator_admin',
  };
}

/** 프로젝트 구성원 — auto는 공개 프로젝트라서 자동으로 들어온 사람인지(초대·생성으로 들어왔으면 false). */
function toProjectMemberDto(m) {
  return { ...publicUser(m), projectRole: m.projectRole, auto: m.projectAuto === true };
}

/** 사이드바 폴더(개인 설정) — projectIds는 내가 구성원인 프로젝트만. */
function toProjectFolderDto(folder, projectIds = folder.projectIds ?? []) {
  return {
    id: folder.id,
    teamId: folder.teamId,
    name: folder.name,
    position: folder.position,
    collapsed: folder.collapsed,
    projectIds,
  };
}

const FOLDER_NAME_MAX = 30;
const FOLDER_MAX_PER_TEAM = 50;

// 앱 입력창(maxLength)은 글자 단위(이모지 한 덩어리 = 1자)로 세므로 서버도 같은 단위로 센다 —
// UTF-16 길이로 세면 앱에서 허용한 이모지 이름이 거절된다.
const graphemeSegmenter = new Intl.Segmenter('ko', { granularity: 'grapheme' });
function graphemeLength(s) {
  let n = 0;
  for (const _ of graphemeSegmenter.segment(s)) n++;
  return n;
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

/**
 * 노트 본문에 넣은 그림·파일 링크 — DB에는 만료되지 않는 원본 경로(`](/uploads/…)`)로 두고,
 * 내려줄 때만 지금 시점의 서명된 주소(`/files/<토큰>`)로 바꾼다(서명은 시간이 지나면 만료된다).
 */
function signNoteBody(body) {
  if (typeof body !== 'string') return body;
  return body.replace(/\]\((\/uploads\/[^)\s]+)\)/g, (_, url) => `](${signFileUrl(url)})`);
}

/** 저장할 때 — 클라이언트가 서명된 주소를 그대로 보내와도 원본 경로로 되돌린다. */
function rawNoteBody(body) {
  if (typeof body !== 'string') return body;
  return body.replace(/\]\((\/files\/[^)\s]+)\)/g, (m, url) => {
    const raw = resolveRawUrl(url);
    return raw ? `](${raw})` : m;
  });
}

/** 노트 수정·삭제 권한 설정 값 — 'all'(구성원 모두) | 'creator_admin'(작성자와 관리자). */
const NOTE_PERMISSIONS = ['all', 'creator_admin'];

/**
 * 내가 이 노트를 고치거나 지울 수 있는지 — [access]는 그 프로젝트의 노트 권한 설정
 * (editPermission·deletePermission)과 내가 프로젝트 관리자(canManageProject)인지(isManager).
 * 노트 댓글은 이 설정과 무관하다.
 */
function notePermissions(note, userId, access) {
  const allowed = (permission) =>
    permission === 'all' || note.createdBy === userId || access?.isManager === true;
  // 값이 없을 때의 기본은 이 기능 전 동작 — 수정은 구성원 누구나, 삭제는 작성자와 관리자만.
  return {
    canEdit: allowed(access?.editPermission ?? 'all'),
    canDelete: allowed(access?.deletePermission ?? 'creator_admin'),
  };
}

/**
 * [users]는 noteNames가 준 id → 사람(이름·사진). [perms]는 notePermissions가 준 이 노트에 대한
 * 요청한 사람의 권한 — 목록·상세 모두 사람마다 다르게 내려준다.
 */
function toNoteDto(note, users = new Map(), perms = { canEdit: true, canDelete: false }) {
  const creator = users.get(note.createdBy);
  return {
    id: note.id,
    // "MKT-N10" — 프로젝트 키 + N + 노트 번호.
    key: note.projectIdentifier && note.seq ? `${note.projectIdentifier}-N${note.seq}` : null,
    projectId: note.projectId,
    projectName: note.projectName ?? null,
    projectColor: note.projectColor ?? null,
    title: note.title,
    preview: note.preview ?? undefined,
    body: note.body == null ? undefined : signNoteBody(note.body),
    createdBy: note.createdBy ?? null,
    createdByName: creator?.name ?? null,
    createdByAvatarType: creator?.avatarType ?? 'initial',
    createdByAvatarEmoji: creator?.avatarEmoji ?? null,
    createdByAvatarColor: creator?.avatarColor ?? null,
    createdByAvatarUrl: creator?.avatarUrl ?? null,
    updatedBy: note.updatedBy ?? null,
    updatedByName: users.get(note.updatedBy)?.name ?? null,
    createdAt: new Date(note.createdAt).getTime(),
    updatedAt: new Date(note.updatedAt).getTime(),
    canEdit: perms.canEdit,
    canDelete: perms.canDelete,
  };
}

/** 노트에 나오는 사람들 — id → 이름·사진(서명된 주소). */
async function noteNames(notes) {
  const ids = [...new Set(notes.flatMap((n) => [n.createdBy, n.updatedBy]).filter(Boolean))];
  const users = await listUsersByIds(ids);
  return new Map(
    users.map((u) => [
      u.id,
      {
        name: u.name,
        avatarType: u.avatarType ?? 'initial',
        avatarEmoji: u.avatarEmoji ?? null,
        avatarColor: u.avatarColor ?? null,
        avatarUrl: signFileUrl(u.avatarUrl) ?? null,
      },
    ]),
  );
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
  const [types, statuses, priorities, refs, creators, checklist, subtasks, comments] = await Promise.all([
    listTaskTypesByIds(typeIds),
    listTaskStatusesByIds(statusIds),
    listTaskPrioritiesByIds(priorityIds),
    listReferencesForTasks(ids),
    // 만든 사람과 담당자를 한 번에 — 달력 일별 목록 등이 담당자 이름·사진을 바로 쓴다.
    listUsersByIds([...new Set(tasks.flatMap((t) => [t.createdBy, t.assigneeId]).filter(Boolean))]),
    countChecklistItems(ids),
    countSubtasks(ids),
    countTaskComments(ids),
  ]);
  const typeById = new Map(types.map((t) => [t.id, t]));
  const statusById = new Map(statuses.map((s) => [s.id, s]));
  const priorityById = new Map(priorities.map((p) => [p.id, p]));
  const creatorById = new Map(creators.map((u) => [u.id, publicUser(u)]));
  return tasks.map((t) => {
    const type = t.typeId ? typeById.get(t.typeId) : null;
    const creator = t.createdBy ? creatorById.get(t.createdBy) : null;
    const assignee = t.assigneeId ? creatorById.get(t.assigneeId) : null;
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
      assignee,
      referenceIds,
      myRole,
      checklist: checklist[t.id] ?? null,
      subtaskCount: subtasks[t.id] ?? 0,
      commentCount: comments[t.id] ?? 0,
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
    assigneeName: task.assignee?.name ?? null,
    assigneeAvatarType: task.assignee?.avatarType ?? 'initial',
    assigneeAvatarEmoji: task.assignee?.avatarEmoji ?? null,
    assigneeAvatarColor: task.assignee?.avatarColor ?? null,
    assigneeAvatarUrl: task.assignee?.avatarUrl ?? null,
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
    commentCount: task.commentCount ?? 0,
    boardPosition: task.boardPosition ?? null,
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
    textFormat: comment.textFormat ?? null,
    parentCommentId: comment.parentCommentId ?? null,
    createdAt: new Date(comment.createdAt).getTime(),
    editedAt: comment.editedAt ? new Date(comment.editedAt).getTime() : null,
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
 * 구성원(project_members)만 볼 수 있다(공개 프로젝트는 정회원 이상 팀원 모두가 자동으로
 * 구성원이 된다 — project_members.auto). 만들 수 있는 사람은 서버 설정(projectCreation)이
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

  /** 보관한 업무는 읽기만 — 고치려면 먼저 보관 해제(POST /tasks/:id/archive). 보관·복사·이동·삭제는 된다. */
  function rejectIfTaskArchived(res, task) {
    if (!task?.archivedAt) return false;
    res.status(409).json({ error: '보관된 업무입니다. 보관을 해제한 뒤 수정할 수 있습니다.' });
    return true;
  }

  // 프로젝트는 정회원 이상만 쓴다(준회원은 목록·조회·수정 모두 불가). 서버 운영자는 예외.
  router.use(['/projects', '/project-templates', '/project-folders', '/tasks', '/task-types', '/task-statuses', '/task-priorities', '/task-fields', '/notes', '/project-notifications', '/task-templates', '/automations', '/note-comments', '/note-versions', '/task-comments'], async (req, res, next) => {
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
    // isProjectMember는 유효한 행만 본다 — 팀에서 빠진 사람은 초대·자동 참여 행이 남아 있어도, 자동 참여
    // 행은 정회원 이상 자격을 잃으면 구성원이 아니다(아래 자동 참여도 팀·자격을 다시 보므로 403).
    if (!(await isProjectMember(project.id, req.user.sub))) {
      // 공개 프로젝트는 정회원 이상 팀원이면 목록을 불러오기 전에(링크·알림으로) 열어도 바로 넣어준다.
      if (!(await joinPublicProjectAutomatically(project, req.user.sub))) {
        res.status(403).json({ error: '이 프로젝트의 구성원이 아닙니다.' });
        return null;
      }
      io.to(`user:${req.user.sub}`).emit('project:changed', { teamId: project.teamId, projectId: project.id });
    }
    return project;
  }

  /** 공개 프로젝트에 새로 자동 참여한 사람들의 사이드바가 바로 갱신되도록 알린다. */
  function emitJoined(project, userIds) {
    for (const userId of userIds) {
      io.to(`user:${userId}`).emit('project:changed', { teamId: project.teamId, projectId: project.id });
    }
  }

  /** 이 사람이 프로젝트를 관리할 수 있는지(담당자 또는 팀 소유자·관리자). */
  async function isProjectManager(project, userId) {
    const [access, myRole] = await Promise.all([teamAccess(project.teamId, userId), getProjectRole(project.id, userId)]);
    return canManageProject({ ...access, isProjectOwner: myRole === 'owner' });
  }

  /** 프로젝트 설정/삭제 권한(담당자 또는 팀 소유자·관리자)까지 필요한 경우. */
  async function requireProjectManager(req, res, projectId) {
    const project = await requireProjectMember(req, res, projectId);
    if (!project) return null;
    if (!(await isProjectManager(project, req.user.sub))) {
      res.status(403).json({ error: '프로젝트를 관리할 권한이 없습니다.' });
      return null;
    }
    return project;
  }

  /** 한 프로젝트의 노트 권한 판정 재료(notePermissions의 access) — 설정 값 + 내가 관리자인지. */
  async function noteAccess(project, userId) {
    return {
      editPermission: project.noteEditPermission,
      deletePermission: project.noteDeletePermission,
      isManager: await isProjectManager(project, userId),
    };
  }

  /** 내가 참여 중인 프로젝트 목록(진행률 포함). */
  router.get('/projects', async (req, res) => {
    const teamId = req.query.teamId;
    if (typeof teamId !== 'string') return res.status(400).json({ error: 'teamId가 필요합니다.' });
    if (!(await isTeamMember(teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    // 공개 프로젝트는 참여 절차가 없다 — 예전 공개 프로젝트, 나중에 합류·승급한 경우까지 여기서 채운다.
    await ensurePublicMembershipsForUser(teamId, req.user.sub);
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
    await ensurePublicMembershipsForUser(teamId, req.user.sub);
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
    // 템플릿을 골랐으면 기본 상태·유형·우선순위 대신 그 구성으로 채운다(같은 팀 것만).
    let template = null;
    if (req.body?.templateId != null) {
      // uuid 모양이 아니면 Postgres가 500을 내므로 DB에 묻지 않고 "찾을 수 없음"으로 본다.
      template =
        typeof req.body.templateId === 'string' && UUID_RE.test(req.body.templateId)
          ? await findProjectTemplateById(req.body.templateId)
          : null;
      if (!template || template.teamId !== teamId) {
        return res.status(400).json({ error: '템플릿을 찾을 수 없습니다.' });
      }
    }
    const project = await insertProject({
      color: rawColor ? rawColor.toUpperCase() : '#5B8DEF',
      isPublic: req.body?.isPublic === true,
      id: randomUUID(),
      teamId,
      name,
      description: description || null,
      identifier: rawIdentifier,
      // 어느 템플릿으로 만들었는지 기억해 둔다(설정의 "업무 템플릿" 칸이 그 카드를 보여준다).
      templateId: template?.id ?? null,
      createdBy: req.user.sub,
    });
    if (template) {
      await applyProjectTemplate(project.id, template);
    } else {
      await seedDefaultTaskTypes(project.id);
      await seedDefaultTaskStatuses(project.id);
      await seedDefaultTaskPriorities(project.id);
    }
    await addProjectMembers(project.id, [req.user.sub], 'owner');
    await addProjectMembers(
      project.id,
      memberIds.filter((id) => id !== req.user.sub),
    );
    // 공개 프로젝트는 나머지 정회원 이상 팀원도 자동으로 넣는다(만든 사람·고른 사람은 auto가 아닌 채로 남는다).
    const autoIds = await ensurePublicProjectMembers(project);

    // 초대된 사람들의 사이드바에 바로 나타나도록 알린다(각자 user: 룸으로).
    for (const userId of new Set([req.user.sub, ...memberIds, ...autoIds])) {
      io.to(`user:${userId}`).emit('project:changed', { teamId });
    }
    res.status(201).json(toProjectDto({ ...project, favorite: false, myRole: 'owner' }));

    // 공개 프로젝트가 새로 생겼다는 것만 팀에 한 번 알린다(비공개→공개 전환 때는 보내지 않는다).
    // 이후 업무 알림은 지금처럼 그 업무에 관련된 사람만 받는다. 팀원이 많을 수 있어 응답은 기다리지 않는다.
    if (project.isPublic) {
      (async () => {
        const [creator, targetIds] = await Promise.all([findUserById(req.user.sub), listPublicEligibleUserIds(teamId)]);
        await notifier.notify({
          project,
          task: null,
          kind: 'project_created',
          actorId: req.user.sub,
          targetIds,
          title: project.name,
          body: `${creator?.name ?? '알 수 없음'}님이 공개 프로젝트를 만들었습니다: ${project.name}`,
        });
      })().catch((e) => console.error('[projects] 공개 프로젝트 생성 알림 실패:', e?.message ?? e));
    }
  });

  // ── 프로젝트 템플릿(팀 공유) ──────────────────────────────────────────
  // 팀 멤버 누구나 보고 만들 수 있다. 고치기·지우기는 만든 사람이나 팀 소유자·서버 관리자만.

  const HEX_COLOR = /^#[0-9a-fA-F]{6}$/;
  // 본문으로 받은 id를 DB에 넘기기 전에 모양만 확인한다(uuid가 아니면 Postgres가 500을 낸다).
  const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  /** 템플릿 본문(이름·설명·상태·유형·우선순위·필드)을 검사해 저장할 값으로 만든다. */
  function parseTemplateBody(body) {
    const name = typeof body?.name === 'string' ? body.name.trim() : '';
    if (!name) return { error: '템플릿 이름을 입력하세요.' };
    if (name.length > 40) return { error: '템플릿 이름은 40자 이내로 입력하세요.' };
    const description = typeof body?.description === 'string' ? body.description.trim().slice(0, 300) : '';

    /** 이름·색이 있는 항목 목록 — 이름은 비지 않고 겹치지 않아야 한다. */
    function namedList(raw, label, { max = 30, extra }) {
      if (!Array.isArray(raw)) return { error: `${label} 목록이 올바르지 않습니다.` };
      if (raw.length > max) return { error: `${label}은(는) ${max}개까지 만들 수 있습니다.` };
      const seen = new Set();
      const out = [];
      for (const item of raw) {
        const itemName = typeof item?.name === 'string' ? item.name.trim() : '';
        if (!itemName) return { error: `${label} 이름을 입력하세요.` };
        if (itemName.length > 20) return { error: `${label} 이름은 20자 이내로 입력하세요.` };
        if (seen.has(itemName)) return { error: `${label} 이름 "${itemName}"이(가) 겹칩니다.` };
        seen.add(itemName);
        const color = typeof item?.color === 'string' && HEX_COLOR.test(item.color) ? item.color.toUpperCase() : '#94A3B8';
        const more = extra ? extra(item) : {};
        if (more.error) return { error: more.error };
        out.push({ name: itemName, color, ...more });
      }
      return { list: out };
    }

    const statuses = namedList(body?.statuses, '상태', {
      extra: (s) => (['todo', 'doing', 'done'].includes(s?.category) ? { category: s.category } : { category: 'doing' }),
    });
    if (statuses.error) return statuses;
    if (!statuses.list.some((s) => s.category === 'done')) return { error: '완료 상태를 하나 이상 지정하세요.' };
    if (!statuses.list.some((s) => s.category !== 'done')) return { error: '완료가 아닌 상태가 하나 이상 있어야 합니다.' };
    const types = namedList(body?.types ?? [], '작업 유형', {});
    if (types.error) return types;
    const priorities = namedList(body?.priorities, '우선순위', {
      extra: (p) => ({ level: ['low', 'normal', 'high'].includes(p?.level) ? p.level : 'normal' }),
    });
    if (priorities.error) return priorities;
    if (priorities.list.length === 0) return { error: '우선순위를 하나 이상 만드세요.' };

    const rawFields = Array.isArray(body?.fields) ? body.fields : [];
    if (rawFields.length > 30) return { error: '필드는 30개까지 만들 수 있습니다.' };
    const fields = [];
    const fieldNames = new Set();
    for (const f of rawFields) {
      const fieldName = typeof f?.name === 'string' ? f.name.trim() : '';
      if (!fieldName) return { error: '필드 이름을 입력하세요.' };
      if (fieldName.length > 20) return { error: '필드 이름은 20자 이내로 입력하세요.' };
      if (fieldNames.has(fieldName)) return { error: `필드 이름 "${fieldName}"이(가) 겹칩니다.` };
      fieldNames.add(fieldName);
      if (!FIELD_KINDS.includes(f?.kind)) return { error: '필드 종류가 올바르지 않습니다.' };
      let options = [];
      if (OPTION_FIELD_KINDS.includes(f.kind)) {
        const raw = Array.isArray(f.options) ? f.options : [];
        options = [...new Set(raw.filter((o) => typeof o === 'string').map((o) => o.trim()).filter(Boolean))];
        if (options.length === 0) return { error: `"${fieldName}" 필드에 선택지를 하나 이상 만드세요.` };
        if (options.length > 30) return { error: '선택지는 30개까지 만들 수 있습니다.' };
        if (options.some((o) => o.length > 30)) return { error: '선택지는 30자 이내로 입력하세요.' };
      }
      fields.push({ name: fieldName, kind: f.kind, options });
    }
    return {
      values: {
        name,
        description: description || null,
        statuses: statuses.list,
        types: types.list,
        priorities: priorities.list,
        fields,
      },
    };
  }

  function toProjectTemplateDto(t, { userId, isTeamOwner, isServerAdmin, creatorName }) {
    return {
      id: t.id,
      teamId: t.teamId,
      name: t.name,
      description: t.description ?? null,
      statuses: t.statuses ?? [],
      types: t.types ?? [],
      priorities: t.priorities ?? [],
      fields: t.fields ?? [],
      createdBy: t.createdBy ?? null,
      creatorName: creatorName ?? null,
      createdAt: new Date(t.createdAt).getTime(),
      updatedAt: new Date(t.updatedAt).getTime(),
      canEdit: t.createdBy === userId || isTeamOwner || isServerAdmin,
    };
  }

  async function templateDtos(rows, teamId, userId) {
    const access = await teamAccess(teamId, userId);
    const creators = await listUsersByIds([...new Set(rows.map((r) => r.createdBy).filter(Boolean))]);
    const nameById = new Map(creators.map((u) => [u.id, u.name]));
    return rows.map((t) =>
      toProjectTemplateDto(t, {
        userId,
        isTeamOwner: access.isOwner,
        isServerAdmin: access.isServerAdmin,
        creatorName: nameById.get(t.createdBy),
      }),
    );
  }

  router.get('/projects/templates', async (req, res) => {
    const teamId = req.query.teamId;
    if (typeof teamId !== 'string') return res.status(400).json({ error: 'teamId가 필요합니다.' });
    if (!(await isTeamMember(teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    res.json(await templateDtos(await listProjectTemplates(teamId), teamId, req.user.sub));
  });

  router.post('/projects/templates', async (req, res) => {
    const teamId = req.body?.teamId;
    if (typeof teamId !== 'string') return res.status(400).json({ error: 'teamId가 필요합니다.' });
    if (!(await isTeamMember(teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    const { values, error } = parseTemplateBody(req.body);
    if (error) return res.status(400).json({ error });
    // 프로젝트를 템플릿으로 저장한 경우(프로젝트 ⋯ > "템플릿 저장", 설정 > 필드 / 상태의 "템플릿 저장")
    // 그 프로젝트를 새 템플릿에 연결해, 설정의 "업무 템플릿" 칸이 바로 이 템플릿 카드를 보여주게 한다.
    // 템플릿 저장은 구성원 누구나 할 수 있어서, 연결도 그 프로젝트를 볼 수 있는(같은 팀) 사람이면 된다.
    let source = null;
    const sourceProjectId = req.body?.sourceProjectId;
    if (sourceProjectId != null) {
      if (typeof sourceProjectId !== 'string' || !UUID_RE.test(sourceProjectId)) {
        return res.status(400).json({ error: '프로젝트를 찾을 수 없습니다.' });
      }
      source = await requireProjectMember(req, res, sourceProjectId);
      if (!source) return;
      if (source.teamId !== teamId) {
        return res.status(400).json({ error: '같은 팀의 프로젝트만 템플릿으로 저장할 수 있습니다.' });
      }
    }
    const row = await insertProjectTemplate({ ...values, teamId, createdBy: req.user.sub });
    // 종료된 프로젝트는 읽기 전용이라 템플릿만 저장하고 프로젝트 쪽 연결(template_id)은 건드리지 않는다.
    if (source && !source.archivedAt) {
      await updateProject(source.id, { templateId: row.id });
      await notifyProjectMembers(source, null);
    }
    const [dto] = await templateDtos([row], teamId, req.user.sub);
    res.status(201).json(dto);
  });

  /** 템플릿을 고치거나 지울 수 있는지 확인하고, 안 되면 응답까지 보내고 null을 준다. */
  async function requireTemplateEditor(req, res) {
    const template = await findProjectTemplateById(req.params.id);
    if (!template) {
      res.status(404).json({ error: '템플릿을 찾을 수 없습니다.' });
      return null;
    }
    const access = await teamAccess(template.teamId, req.user.sub);
    if (!access.isMember && !access.isServerAdmin) {
      res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
      return null;
    }
    if (template.createdBy !== req.user.sub && !access.isOwner && !access.isServerAdmin) {
      res.status(403).json({ error: '템플릿을 만든 사람이나 팀 소유자만 고칠 수 있습니다.' });
      return null;
    }
    return template;
  }

  router.patch('/project-templates/:id', async (req, res) => {
    const template = await requireTemplateEditor(req, res);
    if (!template) return;
    const { values, error } = parseTemplateBody(req.body);
    if (error) return res.status(400).json({ error });
    const row = await updateProjectTemplate(template.id, values);
    const [dto] = await templateDtos([row], template.teamId, req.user.sub);
    res.json(dto);
  });

  router.delete('/project-templates/:id', async (req, res) => {
    const template = await requireTemplateEditor(req, res);
    if (!template) return;
    await deleteProjectTemplate(template.id);
    res.json({ ok: true });
  });

  // ── 사이드바 프로젝트 폴더(개인 설정) ────────────────────────────────
  // 사람마다(팀마다) 따로 만드는 정리용 폴더라 다른 사람에게는 보이지 않는다. /projects/:id보다
  // 먼저 등록해야 'folders'가 프로젝트 id로 잡히지 않는다.

  /** 폴더 이름 검사 — 앞뒤 공백을 빼고 1~30자. */
  function parseFolderName(raw) {
    const name = typeof raw === 'string' ? raw.trim() : '';
    if (!name) return { error: '폴더 이름을 입력하세요.' };
    if (graphemeLength(name) > FOLDER_NAME_MAX) return { error: `폴더 이름은 ${FOLDER_NAME_MAX}자 이내로 입력하세요.` };
    return { name };
  }

  /** 내 폴더인지 확인하고, 아니면 응답까지 보내고 null — 남의 폴더는 있는지조차 알려주지 않는다. */
  async function requireMyFolder(req, res, folderId) {
    const folder = typeof folderId === 'string' ? await findProjectFolderById(folderId) : null;
    if (!folder || folder.userId !== req.user.sub) {
      res.status(404).json({ error: '폴더를 찾을 수 없습니다.' });
      return null;
    }
    return folder;
  }

  // 폴더는 즐겨찾기처럼 개인 사이드바 설정이라 project:changed를 보내지 않는다 — 보내면 접기 한 번에도
  // 열린 프로젝트 화면 전체가 다시 불러와진다. 바꾼 화면은 스스로 다시 불러온다.

  router.get('/projects/folders', async (req, res) => {
    const teamId = req.query.teamId;
    if (typeof teamId !== 'string') return res.status(400).json({ error: 'teamId가 필요합니다.' });
    if (!(await isTeamMember(teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    const folders = await listProjectFolders(teamId, req.user.sub);
    res.json(folders.map((f) => toProjectFolderDto(f)));
  });

  router.post('/projects/folders', async (req, res) => {
    const teamId = req.body?.teamId;
    if (typeof teamId !== 'string') return res.status(400).json({ error: 'teamId가 필요합니다.' });
    if (!(await isTeamMember(teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    const { name, error } = parseFolderName(req.body?.name);
    if (error) return res.status(400).json({ error });
    if ((await countProjectFolders(teamId, req.user.sub)) >= FOLDER_MAX_PER_TEAM) {
      return res.status(400).json({ error: `폴더는 ${FOLDER_MAX_PER_TEAM}개까지 만들 수 있습니다.` });
    }
    const folder = await insertProjectFolder({ teamId, userId: req.user.sub, name });
    res.status(201).json(toProjectFolderDto(folder, []));
  });

  /** 이름 바꾸기·접기/펼치기·순서 — 만든 사람만(개인 설정). */
  router.patch('/project-folders/:id', async (req, res) => {
    const folder = await requireMyFolder(req, res, req.params.id);
    if (!folder) return;
    const body = req.body ?? {};
    const fields = {};
    if ('name' in body) {
      const { name, error } = parseFolderName(body.name);
      if (error) return res.status(400).json({ error });
      fields.name = name;
    }
    if ('collapsed' in body) {
      if (typeof body.collapsed !== 'boolean') return res.status(400).json({ error: '접기 값이 올바르지 않습니다.' });
      fields.collapsed = body.collapsed;
    }
    if ('position' in body) {
      if (!Number.isInteger(body.position) || body.position < 0 || body.position > 100000) {
        return res.status(400).json({ error: '순서 값이 올바르지 않습니다.' });
      }
      fields.position = body.position;
    }
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
    const updated = await updateProjectFolder(folder.id, fields);
    res.json(toProjectFolderDto(updated, await listFolderProjectIds(folder.id, req.user.sub)));
  });

  /** 폴더만 지운다 — 안에 있던 프로젝트는 폴더 밖 목록으로 돌아간다. */
  router.delete('/project-folders/:id', async (req, res) => {
    const folder = await requireMyFolder(req, res, req.params.id);
    if (!folder) return;
    await deleteProjectFolder(folder.id);
    res.json({ ok: true });
  });

  /** 프로젝트를 내 폴더에 넣거나 옮기거나(folderId) 폴더에서 뺀다(null). */
  router.put('/projects/:id/folder', async (req, res) => {
    const folderId = req.body?.folderId;
    if (folderId !== null && typeof folderId !== 'string') {
      return res.status(400).json({ error: 'folderId가 필요합니다.' });
    }
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;
    if (folderId !== null) {
      const folder = await requireMyFolder(req, res, folderId);
      if (!folder) return;
      if (folder.teamId !== project.teamId) {
        return res.status(400).json({ error: '같은 팀의 폴더에만 넣을 수 있습니다.' });
      }
    }
    await setProjectFolder(req.user.sub, project.id, folderId);
    res.json({ ok: true, folderId });
  });

  /** 프로젝트 상세(구성원 포함). */
  router.get('/projects/:id', async (req, res) => {
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;
    // 공개 프로젝트의 구성원 목록·담당자 선택에 정회원 이상 팀원이 빠짐없이 나오도록 먼저 채운다.
    emitJoined(project, await ensurePublicProjectMembers(project));
    const [members, counts, myRole, template] = await Promise.all([
      listProjectMemberUsers(project.id),
      countTasksByProject([project.id]),
      getProjectRole(project.id, req.user.sub),
      project.templateId ? findProjectTemplateById(project.templateId) : null,
    ]);
    // 설정 > 필드 / 상태의 "업무 템플릿" 칸이 따로 요청하지 않도록 연결된 템플릿 카드 내용을 같이
    // 내려준다(템플릿은 팀 공유라 같은 팀 템플릿이면 구성원 누구나 볼 수 있다). 기준은 templateId다.
    const [templateDto] =
      template && template.teamId === project.teamId ? await templateDtos([template], project.teamId, req.user.sub) : [];
    res.json({
      ...toProjectDto({ ...project, myRole }, counts[project.id]),
      members: members.map(toProjectMemberDto),
      template: templateDto ?? null,
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
    // 노트 수정·삭제 권한(설정 > 노트) — 이 라우트 자체가 관리자 전용이라 따로 권한을 보지 않는다.
    for (const key of ['noteEditPermission', 'noteDeletePermission']) {
      if (!(key in (req.body ?? {}))) continue;
      if (!NOTE_PERMISSIONS.includes(req.body[key])) {
        return res.status(400).json({ error: '노트 권한 값이 올바르지 않습니다.' });
      }
      fields[key] = req.body[key];
    }
    if (Object.keys(fields).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });

    const updated = await updateProject(project.id, fields);
    // 공개로 바뀌면(또는 공개 프로젝트를 다시 시작하면) 정회원 이상 팀원을 자동으로 넣고,
    // 비공개로 바뀌면 자동으로 들어왔던 일반 구성원만 뺀다. 알림은 보내지 않는다(생성 때만).
    const wasOpen = project.isPublic && !project.archivedAt;
    const isOpen = updated.isPublic && !updated.archivedAt;
    if (isOpen && !wasOpen) await ensurePublicProjectMembers(updated);
    const removedIds = project.isPublic && !updated.isPublic ? await removeAutoMembers(project.id) : [];
    await notifyProjectMembers(updated, null);
    // 빠진 사람은 더 이상 구성원이 아니라 위에서 못 받으므로 따로 알려 사이드바에서 사라지게 한다.
    for (const userId of removedIds) {
      io.to(`user:${userId}`).emit('project:changed', { teamId: project.teamId });
    }
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
    res.json(members.map(toProjectMemberDto));
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
    res.json(members.map(toProjectMemberDto));
  });

  router.delete('/projects/:id/members/:userId', async (req, res) => {
    const project = await requireProjectManager(req, res, req.params.id);
    if (!project) return;
    if ((await getProjectRole(project.id, req.params.userId)) === 'owner') {
      return res.status(400).json({ error: '프로젝트 담당자는 제외할 수 없습니다.' });
    }
    // 공개 프로젝트에서 정회원 이상 팀원을 빼도 목록을 불러오는 순간 다시 자동으로 들어온다 —
    // 빼는 시늉만 되지 않도록 막는다(준회원으로 내려간 사람처럼 자격이 없는 사람은 뺄 수 있다).
    if (
      project.isPublic &&
      !project.archivedAt &&
      (await isPublicProjectEligible(project.teamId, req.params.userId))
    ) {
      return res
        .status(400)
        .json({ error: '공개 프로젝트는 정회원 이상 팀원 모두가 참여합니다. 비공개로 바꾼 뒤 멤버를 관리하세요.' });
    }
    await removeProjectMember(project.id, req.params.userId);
    io.to(`user:${req.params.userId}`).emit('project:changed', { teamId: project.teamId });
    const members = await listProjectMemberUsers(project.id);
    res.json(members.map(toProjectMemberDto));
  });

  // ── 업무 ──────────────────────────────────────────────────────────────

  router.get('/projects/:id/tasks', async (req, res) => {
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;
    // ?archived=1이면 보관한 업무만, ?archived=all이면 보관한 업무까지 전부(리스트 탭). 평소
    // 목록(칸반·간트·캘린더 등)에서는 보관한 업무를 뺀다.
    const archivedOnly = req.query.archived === '1';
    const includeArchived = req.query.archived === 'all';
    const rows = await listTasksByProject(project.id, { archivedOnly, includeArchived });
    const list = await decorateTasks(rows, req.user.sub);
    res.json(list.map((t) => toTaskDto(t, { identifier: project.identifier, projectName: project.name })));
  });

  /** 내가 담당한 업무(팀 전체) — "내 업무" 화면이 쓴다. */
  /** 칸반 한 열의 카드 순서 — 그 열의 업무 id를 위에서부터 차례로 보낸다. 다른 프로젝트 업무는 무시한다. */
  router.post('/projects/:id/tasks/order', async (req, res) => {
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;
    if (rejectIfArchived(res, project)) return;
    const ids = Array.isArray(req.body?.ids) ? req.body.ids.filter((id) => typeof id === 'string') : [];
    if (ids.length === 0 || ids.length > 1000) {
      return res.status(400).json({ error: '업무 목록이 올바르지 않습니다.' });
    }
    await reorderTasks(project.id, ids);
    await notifyProjectMembers(project, null);
    res.json({ ok: true });
  });

  router.get('/tasks/mine', async (req, res) => {
    const teamId = req.query.teamId;
    if (typeof teamId !== 'string') return res.status(400).json({ error: 'teamId가 필요합니다.' });
    if (!(await isTeamMember(teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    await ensurePublicMembershipsForUser(teamId, req.user.sub);
    // 담당자로 지정된 업무 + 참조자로 걸린 업무 — "내 업무" 화면. ?archived=all이면 보관한 업무도.
    const list = await decorateTasks(
      await listTasksForAssignee(teamId, req.user.sub, {
        includeReferenced: true,
        includeArchived: req.query.archived === 'all',
      }),
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
    await ensurePublicMembershipsForUser(teamId, req.user.sub);
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
    // 프로젝트 id → 노트 권한 판정 재료(notePermissions) — 노트마다 따로 조회하지 않도록 프로젝트별로 한 번.
    const accessByProject = new Map();
    if (typeof projectId === 'string') {
      const project = await requireProjectMember(req, res, projectId);
      if (!project) return;
      accessByProject.set(project.id, await noteAccess(project, req.user.sub));
    } else if (typeof teamId === 'string') {
      if (!(await isTeamMember(teamId, req.user.sub))) {
        return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
      }
      await ensurePublicMembershipsForUser(teamId, req.user.sub);
      // 목록 행에 내 프로젝트 역할(myRole)이 이미 있어서 팀 권한만 한 번 더 보면 된다.
      const [projectList, access] = await Promise.all([
        listProjectsForUser(teamId, req.user.sub),
        teamAccess(teamId, req.user.sub),
      ]);
      for (const p of projectList) {
        accessByProject.set(p.id, {
          editPermission: p.noteEditPermission,
          deletePermission: p.noteDeletePermission,
          isManager: canManageProject({ ...access, isProjectOwner: p.myRole === 'owner' }),
        });
      }
    } else {
      return res.status(400).json({ error: 'projectId 또는 teamId가 필요합니다.' });
    }
    const notes = await listNotesInProjects([...accessByProject.keys()]);
    const names = await noteNames(notes);
    res.json(notes.map((n) => toNoteDto(n, names, notePermissions(n, req.user.sub, accessByProject.get(n.projectId)))));
  });

  /** 노트 하나를 상세 DTO로 — 프로젝트 이름·색·키와 요청한 사람의 수정·삭제 권한을 붙인다. */
  async function noteDetailDto(note, project, userId, access) {
    const names = await noteNames([note]);
    return toNoteDto(
      { ...note, projectName: project.name, projectColor: project.color, projectIdentifier: project.identifier },
      names,
      notePermissions(note, userId, access ?? (await noteAccess(project, userId))),
    );
  }

  /**
   * 노트 수정·삭제 권한 확인 — 프로젝트의 노트 권한이 '생성자와 관리자'면 작성자 본인과 프로젝트
   * 관리자만 된다. 안 되면 403까지 보내고 null, 되면 판정 재료(access)를 돌려준다(응답 DTO에 다시 쓴다).
   */
  async function requireNotePermission(req, res, note, project, kind) {
    const access = await noteAccess(project, req.user.sub);
    const perms = notePermissions(note, req.user.sub, access);
    if (kind === 'edit' ? !perms.canEdit : !perms.canDelete) {
      res.status(403).json({
        error: kind === 'edit' ? '노트 작성자와 관리자만 수정할 수 있습니다.' : '노트 작성자와 관리자만 삭제할 수 있습니다.',
      });
      return null;
    }
    return access;
  }

  router.get('/notes/:id', async (req, res) => {
    const note = await findNoteById(req.params.id);
    if (!note) return res.status(404).json({ error: '노트를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, note.projectId);
    if (!project) return;
    res.json(await noteDetailDto(note, project, req.user.sub));
  });

  router.post('/projects/:id/notes', async (req, res) => {
    const project = await requireProjectMember(req, res, req.params.id);
    if (!project) return;
    if (rejectIfArchived(res, project)) return;
    const title = typeof req.body?.title === 'string' ? req.body.title.trim() : '';
    const body = rawNoteBody(typeof req.body?.body === 'string' ? req.body.body : '');
    if (!title) return res.status(400).json({ error: '노트 제목을 입력하세요.' });
    if (title.length > NOTE_TITLE_MAX) return res.status(400).json({ error: `제목은 ${NOTE_TITLE_MAX}자 이내로 입력하세요.` });
    if (body.length > NOTE_BODY_MAX) return res.status(400).json({ error: `내용은 ${NOTE_BODY_MAX}자 이내로 입력하세요.` });
    const note = await insertNote({
      projectId: project.id,
      seq: await takeNextNoteSeq(project.id),
      title,
      body,
      createdBy: req.user.sub,
      updatedBy: req.user.sub,
    });
    await notifyProjectMembers(project, null);
    res.status(201).json(await noteDetailDto(note, project, req.user.sub));
  });

  /**
   * 수정 — 프로젝트의 노트 수정 권한('all'이면 구성원 누구나, 'creator_admin'이면 작성자와 관리자만).
   * 두 사람이 동시에 고치다 덮어쓰지 않도록, 클라이언트가 열 때의 updatedAt을 baseUpdatedAt으로
   * 보내면 그 사이 바뀌었을 때 409를 돌려준다.
   */
  router.patch('/notes/:id', async (req, res) => {
    const note = await findNoteById(req.params.id);
    if (!note) return res.status(404).json({ error: '노트를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, note.projectId);
    if (!project) return;
    if (rejectIfArchived(res, project)) return;
    const access = await requireNotePermission(req, res, note, project, 'edit');
    if (!access) return;
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
      fields.body = rawNoteBody(req.body.body);
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
    res.json(await noteDetailDto(updated, project, req.user.sub, access));
  });

  // ── 노트 댓글 ──
  function toNoteCommentDto(c) {
    return {
      id: c.id,
      noteId: c.noteId,
      senderId: c.senderId ?? null,
      senderName: c.senderName,
      text: c.text,
      textFormat: c.textFormat ?? null,
      parentCommentId: c.parentCommentId ?? null,
      createdAt: new Date(c.createdAt).getTime(),
      editedAt: c.editedAt ? new Date(c.editedAt).getTime() : null,
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
    // 답글 — 같은 노트의 (답글이 아닌) 댓글에만 달 수 있다.
    let parentCommentId = null;
    if (typeof req.body?.parentCommentId === 'string') {
      const parent = await findNoteCommentById(req.body.parentCommentId);
      if (!parent || parent.noteId !== note.id) return res.status(400).json({ error: '답글을 달 댓글을 찾을 수 없습니다.' });
      if (parent.parentCommentId) return res.status(400).json({ error: '답글에는 다시 답글을 달 수 없습니다.' });
      parentCommentId = parent.id;
    }
    const sender = await findUserById(req.user.sub);
    const c = await insertNoteComment({
      noteId: note.id,
      senderId: req.user.sub,
      senderName: sender?.name ?? sender?.username ?? '알 수 없음',
      text,
      textFormat: sanitizeTextFormat(req.body?.textFormat, text),
      parentCommentId,
    });
    await notifyProjectMembers(project, null);
    res.status(201).json(toNoteCommentDto(c));
  });

  /** 노트 댓글 수정 — 쓴 사람만. */
  router.patch('/note-comments/:id', async (req, res) => {
    const c = await findNoteCommentById(req.params.id);
    if (!c) return res.status(404).json({ error: '댓글을 찾을 수 없습니다.' });
    const note = await findNoteById(c.noteId);
    if (!note) return res.status(404).json({ error: '노트를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, note.projectId);
    if (!project) return;
    if (rejectIfArchived(res, project)) return;
    if (c.senderId !== req.user.sub) return res.status(403).json({ error: '내가 쓴 댓글만 수정할 수 있습니다.' });
    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    if (!text) return res.status(400).json({ error: '댓글 내용을 입력하세요.' });
    if (text.length > 2000) return res.status(400).json({ error: '댓글은 2000자 이내로 작성하세요.' });
    const updated = await updateNoteCommentText(c.id, text, sanitizeTextFormat(req.body?.textFormat, text));
    await notifyProjectMembers(project, null);
    res.json(toNoteCommentDto(updated));
  });

  /** 댓글 삭제 — 쓴 사람, 프로젝트 담당자, 팀 소유자·관리자만. 답글도 같이 지워진다. */
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
        editedByName: names.get(v.editedBy)?.name ?? null,
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
      body: signNoteBody(v.body),
      editedBy: v.editedBy ?? null,
      editedByName: names.get(v.editedBy)?.name ?? null,
      editedAt: new Date(v.editedAt).getTime(),
    });
  });

  /** 이 버전으로 되돌린다(내용을 고치는 것이라 노트 수정 권한이 필요하다) — 되돌리기 직전 내용도 이력에 남는다. */
  router.post('/notes/:id/restore', async (req, res) => {
    const note = await findNoteById(req.params.id);
    if (!note) return res.status(404).json({ error: '노트를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, note.projectId);
    if (!project) return;
    if (rejectIfArchived(res, project)) return;
    const access = await requireNotePermission(req, res, note, project, 'edit');
    if (!access) return;
    const v = typeof req.body?.versionId === 'string' ? await findNoteVersionById(req.body.versionId) : null;
    if (!v || v.noteId !== note.id) return res.status(400).json({ error: '되돌릴 이력을 찾을 수 없습니다.' });
    await snapshotNoteVersion(note);
    const updated = await updateNote(note.id, { title: v.title, body: v.body, updatedBy: req.user.sub });
    await notifyProjectMembers(project, null);
    res.json(await noteDetailDto(updated, project, req.user.sub, access));
  });

  /**
   * 삭제 — 프로젝트의 노트 삭제 권한('all'이면 구성원 누구나, 'creator_admin'이면 작성자 본인과
   * 프로젝트 담당자·팀 소유자·관리자만).
   */
  router.delete('/notes/:id', async (req, res) => {
    const note = await findNoteById(req.params.id);
    if (!note) return res.status(404).json({ error: '노트를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, note.projectId);
    if (!project) return;
    if (rejectIfArchived(res, project)) return;
    if (!(await requireNotePermission(req, res, note, project, 'delete'))) return;
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
      if (rejectIfTaskArchived(res, parent)) return;
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
    const task = await runAutomations({ project, task: inserted, trigger: 'task_created', notifier, io });
    await notifyProjectMembers(project, task.id);
    await notifyTaskEvents(project, inserted, req.user.sub, {
      assigneeId: inserted.assigneeId,
      addedReferenceIds: referenceIds,
      created: true,
    });
    const [decorated] = await decorateTasks([task], req.user.sub);
    await recordTaskActivity(inserted.id, req.user.sub, [
      {
        text: '업무를 만들었습니다.',
        kind: 'created',
        detail: decorated.statusRow?.name ?? null,
        color: decorated.statusRow?.color ?? null,
      },
    ]);
    res.status(201).json(toTaskDto(decorated, { identifier: project.identifier, projectName: project.name }));
  });

  router.get('/tasks/:id', async (req, res) => {
    const task = await findTaskById(req.params.id);
    if (!task) return res.status(404).json({ error: '업무를 찾을 수 없습니다.' });
    const project = await requireProjectMember(req, res, task.projectId);
    if (!project) return;
    const [comments, checklist, subtaskRows, activities] = await Promise.all([
      listTaskComments(task.id),
      listChecklistItems(task.id),
      listSubtasks(task.id, { includeArchived: true }),
      listTaskActivities(task.id),
    ]);
    const [decorated] = await decorateTasks([task], req.user.sub);
    const subtasks = await decorateTasks(subtaskRows, req.user.sub);
    res.json({
      ...toTaskDto(decorated, { identifier: project.identifier, projectName: project.name }),
      comments: comments.map(toTaskCommentDto),
      activities: activities.map((a) => ({
        id: a.id,
        actorId: a.actorId ?? null,
        actorName: a.actorName,
        text: a.text,
        kind: a.kind ?? null,
        detail: a.detail ?? null,
        previous: a.previous ?? null,
        color: a.color ?? null,
        createdAt: new Date(a.createdAt).getTime(),
      })),
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
    if (rejectIfTaskArchived(res, found.task)) return;
    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    if (!text) return res.status(400).json({ error: '체크리스트 내용을 입력하세요.' });
    if (text.length > 200) return res.status(400).json({ error: '체크리스트는 200자 이내로 입력하세요.' });
    const items = await listChecklistItems(found.task.id);
    if (items.length >= 50) return res.status(400).json({ error: '체크리스트는 업무당 50개까지 만들 수 있습니다.' });
    const { result: item, completed } = await mutateChecklist(found.task.id, (tx) =>
      insertChecklistItem(found.task.id, text, tx),
    );
    await runChecklistAutomations(found.project, found.task.id, completed);
    await notifyProjectMembers(found.project, found.task.id);
    res.status(201).json(toChecklistItemDto(item));
  });

  /** 체크리스트가 방금 "항목 1개 이상, 전부 완료"가 됐으면([completed], mutateChecklist가 업무를
   * 잠그고 판단한다 — 동시에 체크해도 한 요청만 true) 커밋한 뒤 체크리스트 완료 자동화를 돌린다. */
  async function runChecklistAutomations(project, taskId, completed) {
    if (!completed) return;
    const task = await findTaskById(taskId);
    if (task) await runAutomations({ project, task, trigger: 'checklist_completed', notifier, io });
  }

  router.patch('/checklist-items/:id', async (req, res) => {
    const item = await findChecklistItemById(req.params.id);
    if (!item) return res.status(404).json({ error: '항목을 찾을 수 없습니다.' });
    const task = await findTaskById(item.taskId);
    const project = await requireProjectMember(req, res, task.projectId);
    if (!project) return;
    if (rejectIfArchived(res, project)) return;
    if (rejectIfTaskArchived(res, task)) return;
    const fields = {};
    if (typeof req.body?.done === 'boolean') fields.done = req.body.done;
    if (typeof req.body?.text === 'string') {
      const text = req.body.text.trim();
      if (!text) return res.status(400).json({ error: '체크리스트 내용을 입력하세요.' });
      fields.text = text.slice(0, 200);
    }
    // 완료 여부가 바뀔 때만 "전부 완료" 전환을 확인한다(글만 고치면 전환이 생기지 않는다).
    let updated;
    if ('done' in fields) {
      const { result, completed } = await mutateChecklist(task.id, (tx) => updateChecklistItem(item.id, fields, tx));
      updated = result;
      await runChecklistAutomations(project, task.id, completed);
    } else {
      updated = await updateChecklistItem(item.id, fields);
    }
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
    if (rejectIfTaskArchived(res, task)) return;
    // 남은 안 끝난 항목을 지워서 전부 완료가 될 수도 있다.
    const { completed } = await mutateChecklist(task.id, (tx) => deleteChecklistItem(item.id, tx));
    await runChecklistAutomations(project, task.id, completed);
    await notifyProjectMembers(project, task.id);
    res.json({ ok: true });
  });

  // ── 보관 · 복사 · 이동 ────────────────────────────────────────────────

  router.post('/tasks/:id/archive', async (req, res) => {
    const found = await requireTaskForChecklist(req, res);
    if (!found) return;
    const archived = req.body?.archived !== false;
    let updated = await setTaskArchived(found.task.id, archived);
    // 보관된 순간에만 — 이미 보관된 업무를 다시 보관하는 요청으로는 돌리지 않는다.
    if (archived && !found.task.archivedAt) {
      updated = await runAutomations({ project: found.project, task: updated, trigger: 'task_archived', notifier, io });
    }
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
    // 공개 프로젝트는 정회원 이상 팀원 모두가 구성원이다 — 아직 행이 채워지지 않은 사람도 아래
    // 참조자·담당자 확인에서 떨어지지 않도록 먼저 채운다(비공개면 아무것도 안 한다).
    emitJoined(target, await ensurePublicProjectMembers(target));

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
    if (rejectIfTaskArchived(res, task)) return;

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
        const mine = await listSubtasks(task.id, { includeArchived: true });
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
    // 기록·알림은 이 사람이 바꾼 결과로 만든다(자동화가 이어서 바꾼 값을 이 사람이 바꾼 것처럼 쓰지 않게).
    // 자동화보다 먼저 남겨야 기록이 "사람의 변경 → 자동화의 변경" 순서로 보인다.
    const userUpdated = updated;
    const [userDecorated] = await decorateTasks([userUpdated], req.user.sub);
    await recordTaskActivity(
      task.id,
      req.user.sub,
      await describeTaskChanges(task, fields, userDecorated, newReferenceIds, oldReferenceIds),
    );
    const statusChanged = 'statusId' in fields && fields.statusId !== task.statusId;
    // "필드 변경" 자동화 — 요청에 들어 있었어도 값이 그대로면 바뀐 것으로 치지 않는다.
    const time = (d) => (d ? new Date(d).getTime() : null);
    const changedFields = [];
    if (statusChanged) changedFields.push('status');
    if ('priorityId' in fields && fields.priorityId !== task.priorityId) changedFields.push('priority');
    if ('assigneeId' in fields && fields.assigneeId !== task.assigneeId) changedFields.push('assignee');
    if ('typeId' in fields && fields.typeId !== task.typeId) changedFields.push('type');
    if ('startDate' in fields && time(fields.startDate) !== time(task.startDate)) changedFields.push('startDate');
    if ('dueDate' in fields && time(fields.dueDate) !== time(task.dueDate)) changedFields.push('dueDate');
    if ('title' in fields && fields.title !== task.title) changedFields.push('title');
    if ('customValues' in fields) {
      const before = task.customValues ?? {};
      const after = fields.customValues ?? {};
      for (const id of new Set([...Object.keys(before), ...Object.keys(after)])) {
        if (JSON.stringify(before[id] ?? null) !== JSON.stringify(after[id] ?? null)) changedFields.push(`field:${id}`);
      }
    }
    if (changedFields.length > 0) {
      updated = await runAutomations({ project, task: updated, trigger: 'field_changed', changedFields, notifier, io });
    }
    await notifyProjectMembers(project, task.id);
    await notifyTaskEvents(project, userUpdated, req.user.sub, {
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
    // 응답은 자동화까지 끝난 최종 상태를 돌려준다.
    const [decorated] = changedFields.length > 0 ? await decorateTasks([updated], req.user.sub) : [userDecorated];
    res.json(toTaskDto(decorated, { identifier: project.identifier, projectName: project.name }));
  });

  /** 업무 기록에 한 줄씩 남긴다(행동한 사람 이름은 그때 이름으로 박아 둔다).
   * [lines]는 문장 또는 { text, kind?, detail?, previous?, color? }. */
  async function recordTaskActivity(taskId, actorId, lines) {
    if (lines.length === 0) return;
    const actor = await findUserById(actorId);
    const actorName = actor?.name ?? actor?.username ?? '알 수 없음';
    await insertTaskActivities(
      lines.map((line) => {
        const {
          text,
          kind = null,
          detail = null,
          previous = null,
          color = null,
        } = typeof line === 'string' ? { text: line } : line;
        return { taskId, actorId, actorName, text, kind, detail, previous, color };
      }),
    );
  }

  /** PATCH로 실제로 바뀐 것만 골라 기록 문장으로 만든다. */
  async function describeTaskChanges(before, fields, after, newReferenceIds, oldReferenceIds) {
    const lines = [];
    const day = (d) =>
      d ? new Date(d).toLocaleDateString('ko-KR', { timeZone: 'Asia/Seoul', month: 'numeric', day: 'numeric' }) : null;
    const dateLine = (label, from, to) => {
      const a = day(from);
      const b = day(to);
      if (a === b) return;
      lines.push(b ? `${label}을 ${b}(으)로 변경했습니다.` : `${label}을 지웠습니다.`);
    };
    if ('title' in fields && fields.title !== before.title) {
      lines.push({ text: '제목을 변경했습니다.', kind: 'title', detail: fields.title, previous: before.title });
    }
    if ('description' in fields && (fields.description ?? null) !== (before.description ?? null)) {
      lines.push(
        fields.description
          ? { text: '설명을 변경했습니다.', kind: 'description', detail: fields.description }
          : { text: '설명을 지웠습니다.', kind: 'description' },
      );
    }
    if ('assigneeId' in fields && fields.assigneeId !== before.assigneeId) {
      const user = fields.assigneeId ? await findUserById(fields.assigneeId) : null;
      lines.push(user ? `담당자를 ${user.name ?? user.username}(으)로 지정했습니다.` : '담당자를 해제했습니다.');
    }
    if ('statusId' in fields && fields.statusId !== before.statusId) {
      const name = after.statusRow?.name ?? fields.status;
      const prev = before.statusId ? await findTaskStatusById(before.statusId) : null;
      lines.push({
        text: `상태를 '${name}'(으)로 변경했습니다.`,
        kind: 'status',
        detail: name,
        previous: prev?.name ?? null,
        color: after.statusRow?.color ?? null,
      });
    }
    if ('priorityId' in fields && fields.priorityId !== before.priorityId) {
      lines.push(`우선순위를 '${after.priorityRow?.name ?? fields.priority}'(으)로 변경했습니다.`);
    }
    if ('typeId' in fields && fields.typeId !== before.typeId) {
      lines.push(after.type?.name ? `유형을 '${after.type.name}'(으)로 변경했습니다.` : '유형을 지웠습니다.');
    }
    if ('startDate' in fields) dateLine('시작일', before.startDate, fields.startDate);
    if ('dueDate' in fields) dateLine('마감일', before.dueDate, fields.dueDate);
    if ('parentTaskId' in fields && fields.parentTaskId !== before.parentTaskId) {
      lines.push(fields.parentTaskId ? '상위 업무를 지정했습니다.' : '상위 업무를 해제했습니다.');
    }
    if ('customValues' in fields && JSON.stringify(fields.customValues) !== JSON.stringify(before.customValues ?? {})) {
      lines.push('필드 값을 변경했습니다.');
    }
    if (newReferenceIds !== undefined) {
      const same =
        newReferenceIds.length === oldReferenceIds.length && newReferenceIds.every((id) => oldReferenceIds.includes(id));
      if (!same) lines.push('참조자를 변경했습니다.');
    }
    return lines;
  }

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
    // 먼저 지운 요청만 삭제 자동화·알림을 돌린다(같은 업무를 동시에 지워도 한 번만). 자동화는 위에서
    // 읽어 둔 지우기 전 스냅샷으로 돌고, 업무를 고치는 액션은 엔진이 건너뛴다.
    if (!(await deleteTask(task.id))) return res.status(404).json({ error: '업무를 찾을 수 없습니다.' });
    await runAutomations({ project, task, trigger: 'task_deleted', notifier, io });
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
    if (rejectIfTaskArchived(res, task)) return;

    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    if (!text) return res.status(400).json({ error: '댓글 내용을 입력하세요.' });
    if (text.length > 2000) return res.status(400).json({ error: '댓글은 2000자 이내로 작성하세요.' });

    // 답글 — 같은 업무의 (답글이 아닌) 댓글에만 달 수 있다.
    let parentCommentId = null;
    if (typeof req.body?.parentCommentId === 'string') {
      const parent = await findTaskCommentById(req.body.parentCommentId);
      if (!parent || parent.taskId !== task.id) return res.status(400).json({ error: '답글을 달 댓글을 찾을 수 없습니다.' });
      if (parent.parentCommentId) return res.status(400).json({ error: '답글에는 다시 답글을 달 수 없습니다.' });
      parentCommentId = parent.id;
    }

    const sender = await findUserById(req.user.sub);
    const comment = await insertTaskComment({
      id: randomUUID(),
      taskId: task.id,
      projectId: project.id,
      senderId: req.user.sub,
      senderName: sender?.name ?? sender?.username ?? '알 수 없음',
      text,
      textFormat: sanitizeTextFormat(req.body?.textFormat, text),
      parentCommentId,
    });
    // 댓글 자동화 — 결과(상태 변경 등)가 아래 화면 갱신 알림에 같이 반영되도록 먼저 돌린다.
    await runAutomations({ project, task, trigger: 'comment_added', notifier, io });
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

  /** 수정·삭제할 댓글을 찾고 권한을 확인한다. 안 되면 응답까지 보내고 null. */
  async function requireOwnTaskComment(req, res, { allowManager }) {
    const comment = await findTaskCommentById(req.params.id);
    if (!comment) {
      res.status(404).json({ error: '댓글을 찾을 수 없습니다.' });
      return null;
    }
    const project = await requireProjectMember(req, res, comment.projectId);
    if (!project) return null;
    if (rejectIfArchived(res, project)) return null;
    if (rejectIfTaskArchived(res, await findTaskById(comment.taskId))) return null;
    if (comment.senderId !== req.user.sub) {
      let ok = false;
      if (allowManager) {
        const [access, myRole] = await Promise.all([
          teamAccess(project.teamId, req.user.sub),
          getProjectRole(project.id, req.user.sub),
        ]);
        ok = canManageProject({ ...access, isProjectOwner: myRole === 'owner' });
      }
      if (!ok) {
        res.status(403).json({ error: allowManager ? '댓글을 지울 권한이 없습니다.' : '내가 쓴 댓글만 수정할 수 있습니다.' });
        return null;
      }
    }
    return { comment, project };
  }

  /** 댓글 수정 — 쓴 사람만. */
  router.patch('/task-comments/:id', async (req, res) => {
    const found = await requireOwnTaskComment(req, res, { allowManager: false });
    if (!found) return;
    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    if (!text) return res.status(400).json({ error: '댓글 내용을 입력하세요.' });
    if (text.length > 2000) return res.status(400).json({ error: '댓글은 2000자 이내로 작성하세요.' });
    const updated = await updateTaskCommentText(found.comment.id, text, sanitizeTextFormat(req.body?.textFormat, text));
    await notifyProjectMembers(found.project, found.comment.taskId);
    res.json(toTaskCommentDto(updated));
  });

  /** 댓글 삭제 — 쓴 사람, 프로젝트 담당자, 팀 소유자·관리자만. 답글도 같이 지워진다. */
  router.delete('/task-comments/:id', async (req, res) => {
    const found = await requireOwnTaskComment(req, res, { allowManager: true });
    if (!found) return;
    await deleteTaskComment(found.comment.id);
    await notifyProjectMembers(found.project, found.comment.taskId);
    res.json({ ok: true });
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
      if (!name) return { error: '양식 이름을 입력하세요.' };
      if (name.length > 30) return { error: '양식 이름은 30자 이내로 입력하세요.' };
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
    if ((await listTaskTemplates(project.id)).length >= 30) return res.status(400).json({ error: '양식은 30개까지 만들 수 있습니다.' });
    try {
      const t = await insertTaskTemplate({ projectId: project.id, createdBy: req.user.sub, ...fields });
      await notifyProjectMembers(project, null);
      res.status(201).json(toTemplateDto(t));
    } catch (e) {
      if ((e?.code ?? e?.cause?.code) === '23505') return res.status(409).json({ error: '이미 같은 이름의 양식이 있습니다.' });
      throw e;
    }
  });

  router.patch('/task-templates/:id', async (req, res) => {
    const t = await findTaskTemplateById(req.params.id);
    if (!t) return res.status(404).json({ error: '양식을 찾을 수 없습니다.' });
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
      if ((e?.code ?? e?.cause?.code) === '23505') return res.status(409).json({ error: '이미 같은 이름의 양식이 있습니다.' });
      throw e;
    }
  });

  router.delete('/task-templates/:id', async (req, res) => {
    const t = await findTaskTemplateById(req.params.id);
    if (!t) return res.status(404).json({ error: '양식을 찾을 수 없습니다.' });
    const project = await requireProjectManager(req, res, t.projectId);
    if (!project) return;
    await deleteTaskTemplate(t.id);
    await notifyProjectMembers(project, null);
    res.json({ ok: true });
  });

  // ── 자동화 규칙 ───────────────────────────────────────────────────────

  function toAutomationDto(a) {
    const graph = a.graph ?? null;
    // 그래프 규칙은 트리거 노드의 종류가 곧 실행 시점이고, 예전 칸(조건·동작)은 쓰지 않는다.
    const triggerNode = graph?.nodes?.find((n) => n.kind === 'trigger');
    return {
      id: a.id,
      projectId: a.projectId,
      name: a.name,
      enabled: a.enabled,
      trigger: graph ? (triggerNode?.type ?? a.trigger) : a.trigger,
      triggerStatusId: graph ? null : (a.triggerStatusId ?? null),
      condition: graph ? {} : (a.condition ?? {}),
      actions: graph ? [] : (a.actions ?? []),
      graph,
      createdAt: a.createdAt ? new Date(a.createdAt).getTime() : null,
    };
  }

  async function parseAutomationBody(project, body, { partial, userId }) {
    const fields = {};
    if (!partial || 'name' in (body ?? {})) {
      const name = typeof body?.name === 'string' ? body.name.trim() : '';
      if (!name) return { error: '자동화 제목을 입력하세요.' };
      if (name.length > 40) return { error: '자동화 제목은 40자 이내로 입력하세요.' };
      fields.name = name;
    }
    if (body?.graph != null) {
      // 노드 편집기 규칙 — 실행 시점은 트리거 노드가 정하고 예전 방식 칸은 비워 둔다.
      const v = await validateAutomationGraph(project, body.graph, { userId });
      if (v.error) return { error: v.error };
      fields.graph = v.graph;
      fields.trigger = v.graph.nodes.find((n) => n.kind === 'trigger').type;
      fields.triggerStatusId = null;
      fields.condition = {};
      fields.actions = [];
    } else {
      // 예전 방식 본문 — 예전 방식 규칙에만 온다(그래프 규칙을 이걸로 덮는 PATCH는 라우트에서 막는다).
      if (!partial || 'trigger' in (body ?? {})) {
        if (!AUTOMATION_TRIGGERS.includes(body?.trigger)) return { error: '실행 시점을 고르세요.' };
        fields.trigger = body.trigger;
        fields.triggerStatusId = null;
        fields.graph = null;
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
        fields.graph = null;
      }
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
    const { fields, error } = await parseAutomationBody(project, req.body, { partial: false, userId: req.user.sub });
    if (error) return res.status(400).json({ error });
    if ((await listAutomations(project.id)).length >= 20) return res.status(400).json({ error: '규칙은 20개까지 만들 수 있습니다.' });
    const a = await insertAutomation({ projectId: project.id, createdBy: req.user.sub, ...fields });
    await notifyProjectMembers(project, null);
    res.status(201).json(toAutomationDto(a));
  });

  /** 수정 — 켜기/끄기만 보낼 수도 있고, 내용을 바꿀 때는 이름·그래프(예전 방식은 이름·시점·동작)를 모두 다시 보낸다. */
  router.patch('/automations/:id', async (req, res) => {
    const a = await findAutomationById(req.params.id);
    if (!a) return res.status(404).json({ error: '규칙을 찾을 수 없습니다.' });
    const project = await requireProjectManager(req, res, a.projectId);
    if (!project) return;
    const b = req.body ?? {};
    // 노드 편집기 규칙을 예전 방식 본문(이전 빌드)으로 덮으면 그래프가 통째로 사라진다 — 막는다.
    if (a.graph && b.graph == null && ['trigger', 'actions', 'condition', 'triggerStatusId'].some((k) => k in b)) {
      return res.status(400).json({ error: '새 편집기에서 만든 규칙입니다. 앱을 업데이트한 뒤 수정해 주세요.' });
    }
    const onlyToggle = Object.keys(req.body ?? {}).every((k) => k === 'enabled');
    const { fields, error } = await parseAutomationBody(project, req.body, { partial: onlyToggle, userId: req.user.sub });
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
