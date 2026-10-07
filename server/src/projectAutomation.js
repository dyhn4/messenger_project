import { randomUUID } from 'node:crypto';
import {
  findFirstStatusOfCategory,
  findTaskById,
  findTaskPriorityById,
  findTaskStatusById,
  findTaskTypeById,
  getProjectRole,
  insertAutomationRun,
  insertTask,
  insertTaskActivities,
  insertTaskComment,
  isProjectMember,
  listAutomations,
  listProjectMemberUsers,
  listReferencesForTasks,
  listTaskFields,
  listTaskPriorities,
  listTaskStatuses,
  listTaskTypes,
  setTaskArchived,
  setTaskReferences,
  takeNextTaskSeq,
  updateAutomation,
  updateTask,
} from './db/queries/projects.js';
import { findRoomById, isRoomMember } from './db/queries/rooms.js';
import { findUserById } from './db/queries/users.js';
import { teamAccess, topicAccess } from './access.js';
import { canManageProject, topicWriteDenial } from './permissions.js';
import {
  AUTOMATION_CHAT_THROTTLED,
  AUTOMATION_CHAT_WINDOW_MS,
  AutomationChatThrottle,
  automationChatText,
  automationSaverDenial,
} from './projectNotifications.js';
import { postBotMessage } from './rooms.js';

/** 예상한 이유로 액션을 못 한 경우 — 실행 기록에 그 이유(한국어)를 그대로 남긴다. */
class AutomationActionError extends Error {}

/** 규칙을 저장한 사람이 권한을 잃어 이 규칙을 더 돌리면 안 되는 경우 — 실행 기록에 남기고 규칙을 끈다(runGraphRule). */
class AutomationAccessLostError extends AutomationActionError {}

// 채팅방 알림 횟수 상한(규칙마다·채팅방마다 10분) — 메모리에만 둔다(서버를 다시 켜면 처음부터 센다).
const chatThrottle = new AutomationChatThrottle();
setInterval(() => chatThrottle.prune(), AUTOMATION_CHAT_WINDOW_MS).unref();

/**
 * 채팅방 알림을 규칙을 저장한 사람([savedBy])의 권한으로 올려도 되는지 — 안 되면 이유(projectNotifications.js
 * automationSaverDenial), 되면 null. 계정 상태·프로젝트 구성원·자동화 저장 권한·채팅방 멤버를 지금 시점으로 다시 읽는다.
 */
async function chatSaverDenial(project, room, savedBy) {
  if (!savedBy) return automationSaverDenial({ savedBy });
  const [access, projectRole, projectMember, roomMember] = await Promise.all([
    teamAccess(project.teamId, savedBy),
    getProjectRole(project.id, savedBy),
    isProjectMember(project.id, savedBy),
    isRoomMember(room.id, savedBy),
  ]);
  return automationSaverDenial({
    savedBy,
    saver: access.user,
    isProjectMember: projectMember,
    // 자동화 규칙 저장(POST·PATCH /automations)과 같은 권한 — 프로젝트 담당자 또는 팀 소유자·관리자.
    canManageProject: canManageProject({ ...access, isProjectOwner: projectRole === 'owner' }),
    isRoomMember: roomMember,
  });
}

/** 실행 기록에 남길 실패 표시 — 예상한 이유면 그 이유까지(DB 오류 같은 내부 메시지는 남기지 않는다). */
function failedLabel(label, error) {
  return error instanceof AutomationActionError ? `${label}(실패: ${error.message})` : `${label}(실패)`;
}

/**
 * "채팅방 알림"을 이 방에 올릴 수 없는 이유 — 올릴 수 있으면 null. 사람이 보내는 메시지와 같은
 * 규칙(socket.js의 message:send)이다: 보드 뷰 토픽은 게시글만 받고(일반 글은 게시판에 안 보인다),
 * 읽기 전용·보관된 토픽은 규칙을 저장한 사람이 그 토픽을 관리할 수 있을 때만 올린다.
 */
async function chatMessageDenial(room, userId) {
  if (room.type !== 'topic') return null;
  if (room.viewMode === 'board') return '보드 뷰 토픽에는 채팅방 알림을 보낼 수 없습니다.';
  if (!room.readOnly && !room.archivedAt) return null;
  return topicWriteDenial({ room, canManage: (await topicAccess(room, userId)).canManage });
}

export const AUTOMATION_TRIGGERS = ['task_created', 'status_changed'];
export const ACTION_KINDS = ['set_assignee', 'set_status', 'set_priority', 'add_reference', 'add_comment', 'notify'];
const PRIORITIES = ['low', 'normal', 'high'];
const ACTION_LABELS = {
  set_assignee: '담당자 지정',
  set_status: '상태 변경',
  set_priority: '우선순위 변경',
  add_reference: '참조자 추가',
  add_comment: '댓글 남기기',
  notify: '알림 보내기',
};

/** 규칙의 조건(우선순위/유형)이 이 업무와 맞는지. 비어 있으면 항상 맞다. */
function matchesCondition(condition, task) {
  if (condition?.priority && condition.priority !== task.priority) return false;
  if (condition?.typeId && condition.typeId !== task.typeId) return false;
  return true;
}

/**
 * 규칙 입력(actions/condition)을 검증해서 저장 가능한 모양으로 돌려준다. 잘못됐으면 { error }.
 * 사용자/상태/유형은 이 프로젝트의 것이어야 한다.
 */
export async function validateAutomationInput(project, body, { loadTypes }) {
  const condition = {};
  if (body.condition?.priority) {
    if (!PRIORITIES.includes(body.condition.priority)) return { error: '조건의 우선순위가 올바르지 않습니다.' };
    condition.priority = body.condition.priority;
  }
  if (body.condition?.typeId) {
    const types = await loadTypes(project.id);
    if (!types.some((t) => t.id === body.condition.typeId)) return { error: '조건의 유형이 이 프로젝트의 것이 아닙니다.' };
    condition.typeId = body.condition.typeId;
  }
  const raw = Array.isArray(body.actions) ? body.actions : [];
  if (raw.length === 0) return { error: '동작을 하나 이상 추가하세요.' };
  if (raw.length > 5) return { error: '동작은 5개까지 넣을 수 있습니다.' };
  const actions = [];
  for (const a of raw) {
    if (!ACTION_KINDS.includes(a?.kind)) return { error: '동작 종류가 올바르지 않습니다.' };
    if (a.kind === 'set_assignee' || a.kind === 'add_reference' || a.kind === 'notify') {
      if (typeof a.userId !== 'string' || !(await isProjectMember(project.id, a.userId))) {
        return { error: '사용자는 프로젝트 구성원 중에서 고를 수 있습니다.' };
      }
      actions.push({ kind: a.kind, userId: a.userId });
    } else if (a.kind === 'set_status') {
      const st = typeof a.statusId === 'string' ? await findTaskStatusById(a.statusId) : null;
      if (!st || st.projectId !== project.id) return { error: '이 프로젝트의 상태가 아닙니다.' };
      actions.push({ kind: a.kind, statusId: st.id });
    } else if (a.kind === 'set_priority') {
      if (!PRIORITIES.includes(a.priority)) return { error: '우선순위 값이 올바르지 않습니다.' };
      actions.push({ kind: a.kind, priority: a.priority });
    } else if (a.kind === 'add_comment') {
      const text = typeof a.text === 'string' ? a.text.trim() : '';
      if (!text || text.length > 500) return { error: '댓글은 1~500자로 입력하세요.' };
      actions.push({ kind: a.kind, text });
    }
  }
  return { condition, actions };
}

// ── 자동화 v2: 노드 그래프 ─────────────────────────────────────────────
//
// 규칙 = 트리거 노드 하나 → IF 조건 노드(예/아니오 갈래) → 액션 노드. 저장 형식은
// project_automations.graph = {nodes: [{id, kind, type, config, x, y}], edges: [{from, port, to}]}.

export const GRAPH_TRIGGER_TYPES = [
  'field_changed',
  'task_created',
  'task_deleted',
  'task_archived',
  'comment_added',
  'checklist_completed',
];
export const GRAPH_ACTION_TYPES = ['set_field', 'create_task', 'archive_task', 'chat_message'];
const GRAPH_ACTION_LABELS = {
  set_field: '필드 변경',
  create_task: '업무 생성',
  archive_task: '업무 보관',
  chat_message: '채팅방 알림',
};
/** 트리거 "필드 변경"이 볼 수 있는 필드(+ 'field:<사용자 정의 필드 id>'). 'any'는 따로 다룬다. */
const TRIGGER_FIELDS = ['status', 'priority', 'assignee', 'type', 'startDate', 'dueDate', 'title'];
const CONDITION_FIELDS = ['status', 'priority', 'assignee', 'type'];
const CONDITION_OPS = ['eq', 'neq', 'empty', 'not_empty'];
const SET_FIELDS = ['status', 'priority', 'assignee', 'type'];
/** 노드 종류별 나가는 포트 — 액션은 실행하고 끝나므로 포트가 없다. */
const NODE_PORTS = { trigger: ['out'], condition: ['yes', 'no'], action: [] };
const GRAPH_MAX_NODES = 30;
const GRAPH_MAX_EDGES = 60;
const NODE_ID_MAX = 40;

function nodeTypesOf(kind) {
  if (kind === 'trigger') return GRAPH_TRIGGER_TYPES;
  if (kind === 'condition') return ['if'];
  if (kind === 'action') return GRAPH_ACTION_TYPES;
  return null;
}

function trimmed(value) {
  return typeof value === 'string' ? value.trim() : '';
}

/** 캔버스 좌표 — 숫자가 아니면 0(편집기 표시용일 뿐이라 실행에는 영향이 없다). */
function coord(value) {
  const n = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(n) ? Math.round(n * 10) / 10 : 0;
}

/**
 * 노드 편집기에서 보낸 그래프를 검증해서 저장할 모양으로 돌려준다(알려진 키만, 문자열은 trim,
 * 좌표는 숫자). 잘못됐으면 { error }(한국어). 설정이 가리키는 상태·우선순위·유형·필드·사람은
 * 이 프로젝트의 것이어야 하고, 채팅방은 같은 팀의 (비밀 대화가 아닌) 방이면서 저장하는 사람이
 * 참여 중인 방이어야 한다 — 남의 방에 자동 메시지를 심지 못하게.
 */
export async function validateAutomationGraph(project, graph, { userId } = {}) {
  if (!graph || typeof graph !== 'object' || Array.isArray(graph)) return { error: '규칙 흐름 형식이 올바르지 않습니다.' };
  if (!Array.isArray(graph.nodes)) return { error: '규칙 흐름 형식이 올바르지 않습니다.' };
  if (graph.edges != null && !Array.isArray(graph.edges)) return { error: '규칙 흐름 형식이 올바르지 않습니다.' };
  const rawNodes = graph.nodes;
  const rawEdges = graph.edges ?? [];
  if (rawNodes.length > GRAPH_MAX_NODES) return { error: `노드는 ${GRAPH_MAX_NODES}개까지 넣을 수 있습니다.` };
  if (rawEdges.length > GRAPH_MAX_EDGES) return { error: `연결은 ${GRAPH_MAX_EDGES}개까지 만들 수 있습니다.` };

  // 노드마다 조회하지 않도록 이 프로젝트의 정의를 한 번에 불러 둔다.
  const [statuses, priorities, types, fields] = await Promise.all([
    listTaskStatuses(project.id),
    listTaskPriorities(project.id),
    listTaskTypes(project.id),
    listTaskFields(project.id),
  ]);
  const defs = {
    statusIds: new Set(statuses.map((s) => s.id)),
    priorityIds: new Set(priorities.map((p) => p.id)),
    typeIds: new Set(types.map((t) => t.id)),
    fieldById: new Map(fields.map((f) => [f.id, f])),
  };
  const memberCache = new Map();
  const isMember = async (id) => {
    if (typeof id !== 'string' || !id) return false;
    if (!memberCache.has(id)) memberCache.set(id, await isProjectMember(project.id, id));
    return memberCache.get(id);
  };
  const ctx = { project, userId, defs, isMember };

  const nodes = [];
  const byId = new Map();
  for (const raw of rawNodes) {
    const id = trimmed(raw?.id);
    if (!id || id.length > NODE_ID_MAX) return { error: '노드 id가 올바르지 않습니다.' };
    if (byId.has(id)) return { error: '노드 id가 겹칩니다.' };
    const kind = raw.kind;
    const allowedTypes = nodeTypesOf(kind);
    if (!allowedTypes) return { error: '노드 종류가 올바르지 않습니다.' };
    if (!allowedTypes.includes(raw.type)) {
      return { error: kind === 'trigger' ? '트리거 종류가 올바르지 않습니다.' : kind === 'action' ? '액션 종류가 올바르지 않습니다.' : '조건 종류가 올바르지 않습니다.' };
    }
    const rawConfig = raw.config && typeof raw.config === 'object' && !Array.isArray(raw.config) ? raw.config : {};
    const checked = await normalizeNodeConfig(kind, raw.type, rawConfig, ctx);
    if (checked.error) return { error: checked.error };
    const node = { id, kind, type: raw.type, config: checked.config, x: coord(raw.x), y: coord(raw.y) };
    nodes.push(node);
    byId.set(id, node);
  }
  const triggers = nodes.filter((n) => n.kind === 'trigger');
  if (triggers.length === 0) return { error: '트리거를 하나 추가하세요.' };
  if (triggers.length > 1) return { error: '트리거는 하나만 둘 수 있습니다.' };

  const edges = [];
  const seen = new Set();
  for (const raw of rawEdges) {
    const from = trimmed(raw?.from);
    const to = trimmed(raw?.to);
    const port = trimmed(raw?.port);
    const fromNode = byId.get(from);
    const toNode = byId.get(to);
    if (!fromNode || !toNode) return { error: '연결된 노드를 찾을 수 없습니다.' };
    if (from === to) return { error: '노드를 자기 자신에 연결할 수 없습니다.' };
    if (!NODE_PORTS[fromNode.kind].includes(port)) {
      return { error: fromNode.kind === 'action' ? '액션 뒤에는 다른 노드를 이을 수 없습니다.' : '연결 위치가 올바르지 않습니다.' };
    }
    if (toNode.kind === 'trigger') return { error: '트리거로 들어가는 연결은 만들 수 없습니다.' };
    const key = `${from}\u0000${port}\u0000${to}`;
    if (seen.has(key)) continue; // 같은 연결이 두 번 오면 하나로 합친다.
    seen.add(key);
    edges.push({ from, port, to });
  }

  // 순환 검사(DFS 색칠) — 순환이 있으면 실행이 끝나지 않거나 결과가 순서에 따라 달라진다.
  const next = new Map(nodes.map((n) => [n.id, []]));
  for (const e of edges) next.get(e.from).push(e.to);
  const state = new Map(); // 1 = 방문 중, 2 = 끝남
  const hasCycle = (id) => {
    state.set(id, 1);
    for (const to of next.get(id)) {
      const s = state.get(to);
      if (s === 1) return true;
      if (s !== 2 && hasCycle(to)) return true;
    }
    state.set(id, 2);
    return false;
  };
  for (const n of nodes) {
    if (!state.has(n.id) && hasCycle(n.id)) return { error: '연결이 순환하지 않도록 이어 주세요.' };
  }

  // 트리거에서 이어지는 액션이 없으면 아무 일도 안 하는 규칙이다.
  const reached = new Set([triggers[0].id]);
  const queue = [triggers[0].id];
  while (queue.length > 0) {
    for (const to of next.get(queue.shift())) {
      if (reached.has(to)) continue;
      reached.add(to);
      queue.push(to);
    }
  }
  if (!nodes.some((n) => n.kind === 'action' && reached.has(n.id))) {
    return { error: '트리거에서 이어지는 액션을 하나 이상 연결하세요.' };
  }
  return { graph: { nodes, edges } };
}

/** 'YYYY-MM-DD'이면서 실제로 있는 날짜인지(2026-02-30 같은 값은 거른다). */
function isDayString(text) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text);
  if (!m) return false;
  const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
  return d.getUTCFullYear() === Number(m[1]) && d.getUTCMonth() === Number(m[2]) - 1 && d.getUTCDate() === Number(m[3]);
}

/** 날짜 필드 값(epoch ms)을 한국 시간 기준 'YYYY-MM-DD'로 — 클라이언트가 그 날 0시(현지)로 저장한다. */
function seoulDay(millis) {
  return new Date(millis).toLocaleDateString('sv-SE', { timeZone: 'Asia/Seoul' });
}

/** 'field:<id>'면 그 사용자 정의 필드(이 프로젝트 것), 아니면 null. */
function customFieldOf(field, defs) {
  if (typeof field !== 'string' || !field.startsWith('field:')) return null;
  return defs.fieldById.get(field.slice('field:'.length)) ?? null;
}

async function normalizeNodeConfig(kind, type, config, { project, userId, defs, isMember }) {
  if (kind === 'trigger') {
    if (type !== 'field_changed') return { config: {} };
    // 예전 모양 {field: X}(이전 빌드·저장된 규칙)도 받아서 {fields: [X]}로 바꿔 저장한다.
    let list;
    if (config.fields != null) {
      if (!Array.isArray(config.fields)) return { error: '트리거의 필드가 올바르지 않습니다.' };
      list = config.fields;
    } else {
      list = config.field == null || config.field === '' ? ['any'] : [config.field];
    }
    if (list.length === 0) return { error: '감지할 필드를 하나 이상 고르세요.' };
    // '모든 필드'는 나머지를 다 포함하므로 함께 오면 그것만 남긴다.
    if (list.includes('any')) return { config: { fields: ['any'] } };
    const fields = [];
    for (const f of list) {
      if (!TRIGGER_FIELDS.includes(f) && !customFieldOf(f, defs)) return { error: '트리거의 필드가 올바르지 않습니다.' };
      if (!fields.includes(f)) fields.push(f);
    }
    return { config: { fields } };
  }

  if (kind === 'condition') {
    const field = config.field;
    const custom = customFieldOf(field, defs);
    if (!CONDITION_FIELDS.includes(field) && !custom) return { error: '조건의 필드를 고르세요.' };
    if (!CONDITION_OPS.includes(config.op)) return { error: '조건의 비교 방법을 고르세요.' };
    if (config.op === 'empty' || config.op === 'not_empty') return { config: { field, op: config.op, value: null } };
    const value = config.value;
    if (field === 'status') {
      if (!defs.statusIds.has(value)) return { error: '조건의 상태가 이 프로젝트의 것이 아닙니다.' };
    } else if (field === 'priority') {
      if (!defs.priorityIds.has(value)) return { error: '조건의 우선순위가 이 프로젝트의 것이 아닙니다.' };
    } else if (field === 'type') {
      if (!defs.typeIds.has(value)) return { error: '조건의 유형이 이 프로젝트의 것이 아닙니다.' };
    } else if (field === 'assignee') {
      if (!(await isMember(value))) return { error: '조건의 담당자는 프로젝트 구성원 중에서 고를 수 있습니다.' };
    } else {
      // 사용자 정의 필드 — 값은 글자로 비교한다(선택형은 선택지 글자).
      const text = typeof value === 'number' && Number.isFinite(value) ? String(value) : trimmed(value);
      if (!text) return { error: `조건의 "${custom.name}" 값을 입력하세요.` };
      if (text.length > 500) return { error: '조건 값은 500자 이내로 입력하세요.' };
      if ((custom.kind === 'select' || custom.kind === 'multiSelect') && !(custom.options ?? []).includes(text)) {
        return { error: `"${custom.name}"의 선택지에 없는 값입니다.` };
      }
      // 날짜는 'YYYY-MM-DD'(한국 시간 날짜)로 비교하므로, 형식이 틀리면 영영 안 맞는 조건이 된다.
      if (custom.kind === 'date' && !isDayString(text)) {
        return { error: `"${custom.name}" 값은 2026-10-01 형식의 날짜로 입력하세요.` };
      }
      if ((custom.kind === 'number' || custom.kind === 'progress') && !Number.isFinite(Number(text))) {
        return { error: `"${custom.name}" 값은 숫자로 입력하세요.` };
      }
      return { config: { field, op: config.op, value: text } };
    }
    return { config: { field, op: config.op, value } };
  }

  switch (type) {
    case 'set_field': {
      const field = config.field;
      if (!SET_FIELDS.includes(field)) return { error: '변경할 필드를 고르세요.' };
      const value = config.value ?? null;
      if (field === 'status' && !defs.statusIds.has(value)) return { error: '변경할 상태를 이 프로젝트의 상태 중에서 고르세요.' };
      if (field === 'priority' && !defs.priorityIds.has(value)) {
        return { error: '변경할 우선순위를 이 프로젝트의 우선순위 중에서 고르세요.' };
      }
      if (field === 'type' && value !== null && !defs.typeIds.has(value)) return { error: '이 프로젝트의 유형이 아닙니다.' };
      if (field === 'assignee' && value !== null && !(await isMember(value))) {
        return { error: '담당자는 프로젝트 구성원 중에서 고를 수 있습니다.' };
      }
      return { config: { field, value } };
    }
    case 'create_task': {
      const title = trimmed(config.title);
      if (!title) return { error: '만들 업무의 제목을 입력하세요.' };
      if (title.length > 200) return { error: '업무 제목은 200자 이내로 입력하세요.' };
      const statusId = config.statusId ?? null;
      if (statusId !== null && !defs.statusIds.has(statusId)) return { error: '이 프로젝트의 상태가 아닙니다.' };
      const assignee = config.assignee ?? null;
      if (assignee !== null && assignee !== 'current_assignee' && !(await isMember(assignee))) {
        return { error: '담당자는 프로젝트 구성원 중에서 고를 수 있습니다.' };
      }
      return { config: { title, statusId, assignee } };
    }
    case 'archive_task':
      return { config: {} };
    case 'chat_message': {
      const roomId = trimmed(config.roomId);
      const room = roomId ? await findRoomById(roomId) : null;
      if (!room || room.teamId !== project.teamId || room.isSecret) return { error: '알림을 보낼 채팅방을 찾을 수 없습니다.' };
      if (!userId || !(await isRoomMember(room.id, userId))) return { error: '내가 참여 중인 채팅방만 고를 수 있습니다.' };
      const denial = await chatMessageDenial(room, userId);
      if (denial) return { error: denial };
      const text = trimmed(config.text);
      if (!text) return { error: '채팅방에 보낼 내용을 입력하세요.' };
      if (text.length > 500) return { error: '채팅방에 보낼 내용은 500자 이내로 입력하세요.' };
      // 방 참여를 확인한 사람(마지막으로 저장한 사람)을 서버가 적어 둔다 — 실행할 때 그 사람이
      // 아직 방 멤버인지 다시 본다. 클라이언트가 보낸 값은 쓰지 않는다.
      return { config: { roomId: room.id, text, savedBy: userId } };
    }
    default:
      return { error: '액션 종류가 올바르지 않습니다.' };
  }
}

/**
 * 꺼진 규칙을 켜기만 할 때(PATCH /automations/:id {enabled: true}) — 그래프를 다시 검사하지 않으므로, 채팅방 알림을 저장한
 * 사람이 그새 권한을 잃었으면 켜자마자 다시 꺼진다. 그런 규칙은 켜지 못하게 이유를 돌려준다(되면 null). 규칙을 열어 다시
 * 저장하면 저장하는 관리자가 새 savedBy가 되어 다시 켤 수 있다.
 */
export async function automationEnableDenial(project, rule) {
  for (const node of rule?.graph?.nodes ?? []) {
    if (node?.kind !== 'action' || node.type !== 'chat_message') continue;
    const config = node.config ?? {};
    const room = config.roomId ? await findRoomById(config.roomId) : null;
    // 채팅방이 없어진 노드는 예전처럼 실행할 때 그 액션만 실패로 남는다(저장한 사람의 권한 문제가 아니라 규칙을 끄지 않는다).
    if (!room || room.teamId !== project.teamId || room.isSecret) continue;
    const lost = await chatSaverDenial(project, room, config.savedBy);
    if (lost) return `${lost} 규칙을 열어 다시 저장한 뒤 켜세요.`;
  }
  return null;
}

// ── 실행 ────────────────────────────────────────────────────────────────

/**
 * 트리거가 일어났을 때 이 프로젝트의 켜진 규칙을 만든 순서대로 실행한다. 실행 후의 최신 업무를
 * 돌려준다. 호출한 쪽(라우터)의 응답을 망치지 않도록 절대 throw하지 않는다.
 *
 * - trigger: 'task_created' | 'field_changed' | 'task_deleted' | 'task_archived' | 'comment_added'
 *   | 'checklist_completed'
 * - changedFields: field_changed일 때 실제로 바뀐 필드들('status', …, 'field:<id>')
 * - actorId: 이 트리거를 일으킨 사람(요청한 사람) — 채팅방 알림에 "실행한 사람"으로 적는다. 없으면 '알 수 없음'.
 *
 * 예전 방식 규칙(graph가 없는 것)은 업무 생성, 그리고 상태가 바뀐 필드 변경에서만 돈다.
 * 규칙의 동작은 DB를 직접 고치므로(라우터를 다시 타지 않으므로) 자동화가 또 다른 자동화를
 * 부르지 않는다.
 */
export async function runAutomations({
  project,
  task,
  trigger,
  changedFields = [],
  notifier = null,
  io = null,
  actorId = null,
}) {
  let current = task;
  try {
    const changed = new Set(changedFields);
    const legacyTrigger =
      trigger === 'task_created'
        ? 'task_created'
        : trigger === 'status_changed' || (trigger === 'field_changed' && changed.has('status'))
          ? 'status_changed'
          : null;
    // 실행한 사람 이름은 채팅방 알림을 실제로 올릴 때만 한 번 읽는다(대부분의 규칙은 쓰지 않는다).
    let actorName;
    const loadActorName = async () => {
      if (actorName === undefined) {
        const actor = actorId ? await findUserById(actorId).catch(() => null) : null;
        actorName = actor?.name ?? actor?.username ?? null;
      }
      return actorName;
    };
    const rules = await listAutomations(project.id, { onlyEnabled: true });
    for (const rule of rules) {
      try {
        if (rule.graph) {
          const start = matchingTriggerNode(rule.graph, trigger, changed);
          if (!start) continue;
          current = await runGraphRule({ project, rule, task: current, start, notifier, io, loadActorName });
        } else {
          if (!legacyTrigger || rule.trigger !== legacyTrigger) continue;
          if (legacyTrigger === 'status_changed' && rule.triggerStatusId && rule.triggerStatusId !== task.statusId) continue;
          current = await runLegacyRule({ project, rule, task: current, trigger: legacyTrigger, notifier });
        }
      } catch (e) {
        console.error(`[automation] "${rule.name}" 실행 실패:`, e?.message ?? e);
      }
    }
  } catch (e) {
    console.error('[automation] 규칙 실행 실패:', e?.message ?? e);
  }
  return current;
}

async function runLegacyRule({ project, rule, task, trigger, notifier }) {
  let current = task;
  if (!matchesCondition(rule.condition, current)) return current;
  const done = [];
  let failed = 0;
  for (const action of rule.actions ?? []) {
    const label = ACTION_LABELS[action.kind] ?? action.kind;
    try {
      current = await applyAction({ project, task: current, rule, action, notifier });
      done.push(label);
    } catch (e) {
      failed += 1;
      if (!(e instanceof AutomationActionError)) console.error(`[automation] "${rule.name}" 동작 실패:`, e?.message ?? e);
      done.push(failedLabel(label, e));
    }
  }
  await insertAutomationRun({
    projectId: project.id,
    automationName: rule.name,
    taskId: current.id,
    taskKey: `${project.identifier}-${current.seq}`,
    trigger,
    summary: done.join(' → '),
    ok: failed === 0,
  }).catch((e) => console.error('[automation] 실행 기록 실패:', e?.message ?? e));
  return current;
}

/** 이 규칙의 트리거 노드가 지금 일어난 일과 맞으면 그 노드, 아니면 null. */
function matchingTriggerNode(graph, trigger, changed) {
  const node = (graph?.nodes ?? []).find((n) => n?.kind === 'trigger');
  if (!node || node.type !== trigger) return null;
  if (trigger === 'field_changed') {
    const fields = triggerFieldsOf(node.config);
    if (fields.includes('any')) return changed.size > 0 ? node : null;
    // 고른 필드 중 하나라도 바뀌었으면 실행한다.
    return fields.some((f) => changed.has(f)) ? node : null;
  }
  return node;
}

/** 필드 변경 트리거가 볼 필드 목록 — 다시 저장하기 전의 예전 규칙은 {field: X} 모양이라 둘 다 읽는다. */
function triggerFieldsOf(config) {
  if (Array.isArray(config?.fields) && config.fields.length > 0) return config.fields;
  if (typeof config?.field === 'string' && config.field) return [config.field];
  return ['any'];
}

// ── 제목/내용 변수 ──────────────────────────────────────────────────────
// 잔디의 {{task.title}}처럼, 업무 생성 제목·채팅방 알림 내용에 적은 변수를 규칙을 부른 업무의
// 값으로 바꾼다. 모르는 {{...}}는 오타일 수 있어 그대로 둔다(지우면 무엇이 틀렸는지 안 보인다).
const TASK_TOKEN = /\{\{task\.(title|key|assignee)\}\}/g;

async function fillTaskTokens(template, project, task) {
  if (typeof template !== 'string' || !template.includes('{{')) return template ?? '';
  let assignee = '미배정';
  if (template.includes('{{task.assignee}}') && task.assigneeId) {
    const user = await findUserById(task.assigneeId);
    assignee = user?.name ?? user?.username ?? '미배정';
  }
  const values = { title: task.title ?? '', key: `${project.identifier}-${task.seq}`, assignee };
  // 한 번만 훑으므로 업무 제목 안에 {{...}}가 있어도 다시 바뀌지 않는다.
  return template.replace(TASK_TOKEN, (_, name) => values[name]);
}

/** JS 글자 수로 자르되, 이모지 같은 서로게이트 쌍이 반쪽만 남지 않게 한다. */
function clip(text, max) {
  if (text.length <= max) return text;
  let cut = text.slice(0, max);
  const last = cut.charCodeAt(cut.length - 1);
  if (last >= 0xd800 && last <= 0xdbff) cut = cut.slice(0, -1);
  return cut;
}

/**
 * 그래프 규칙 하나를 트리거 노드부터 따라가며 실행한다. 조건은 예/아니오 중 맞는 갈래로만
 * 가고, 여러 갈래로 이어진 노드는 연결 순서대로 모두 실행한다. 같은 노드에 두 번 도착해도
 * 한 번만 실행한다. 액션 뒤에는 업무를 다시 읽어서 다음 조건이 바뀐 값을 보게 한다.
 */
async function runGraphRule({ project, rule, task, start, notifier, io, loadActorName }) {
  const graph = rule.graph;
  const byId = new Map((graph.nodes ?? []).map((n) => [n.id, n]));
  const edges = graph.edges ?? [];
  const nextOf = (id, port) =>
    edges.filter((e) => e.from === id && e.port === port).map((e) => byId.get(e.to)).filter(Boolean);
  // 삭제 트리거는 지우기 직전 스냅샷으로 돈다(업무 행은 이미 없다) — 업무를 고치는 액션은 건너뛴다.
  const deleted = start.type === 'task_deleted';
  const visited = new Set();
  const done = [];
  let failed = 0;
  // 채팅방 알림을 저장한 사람이 권한을 잃었으면 이번 실행이 끝난 뒤 규칙을 끈다.
  let accessLost = false;
  let current = task;
  let defs = null;
  const loadDefs = async () => {
    defs ??= await Promise.all([
      listTaskStatuses(project.id),
      listTaskPriorities(project.id),
      listTaskFields(project.id),
    ]).then(([statuses, priorities, fields]) => ({ statuses, priorities, fields }));
    return defs;
  };

  const visit = async (node) => {
    if (visited.has(node.id)) return;
    visited.add(node.id);
    if (node.kind === 'trigger') {
      for (const n of nextOf(node.id, 'out')) await visit(n);
      return;
    }
    if (node.kind === 'condition') {
      const ok = await evaluateCondition(node.config ?? {}, current, loadDefs);
      for (const n of nextOf(node.id, ok ? 'yes' : 'no')) await visit(n);
      return;
    }
    if (node.kind !== 'action') return;
    if (deleted && (node.type === 'set_field' || node.type === 'archive_task')) return;
    const label = GRAPH_ACTION_LABELS[node.type] ?? node.type;
    try {
      await applyGraphAction({ project, rule, task: current, node, notifier, io, loadActorName });
      done.push(label);
    } catch (e) {
      failed += 1;
      if (e instanceof AutomationAccessLostError) accessLost = true;
      if (!(e instanceof AutomationActionError)) console.error(`[automation] "${rule.name}" 액션 실패:`, e?.message ?? e);
      done.push(failedLabel(label, e));
    }
    if (!deleted) {
      try {
        current = (await findTaskById(current.id)) ?? current;
      } catch (e) {
        console.error('[automation] 업무 다시 읽기 실패:', e?.message ?? e);
      }
    }
  };
  await visit(start);

  // 저장한 사람이 권한을 잃은 규칙은 끈다 — 켜 둔 채로는 그 사람의 권한으로 업무 번호·제목·담당자가 계속 채팅방으로
  // 나간다. 실행 기록에 이유가 남고, 관리자가 규칙을 열어 다시 저장하면 그 관리자의 권한으로 다시 켤 수 있다.
  if (accessLost) {
    try {
      await updateAutomation(rule.id, { enabled: false });
      done.push('규칙 꺼짐(다시 저장하면 켤 수 있습니다)');
    } catch (e) {
      console.error(`[automation] "${rule.name}" 규칙 끄기 실패:`, e?.message ?? e);
    }
  }

  // 조건에 막혀 아무 액션도 안 했으면 기록을 남기지 않는다(트리거마다 빈 기록이 쌓이지 않도록).
  if (done.length > 0) {
    await insertAutomationRun({
      projectId: project.id,
      automationName: rule.name,
      // 삭제 트리거는 업무 행이 이미 지워진 뒤라(FK) 번호(taskKey)로만 남긴다.
      taskId: deleted ? null : current.id,
      taskKey: `${project.identifier}-${current.seq}`,
      trigger: start.type,
      summary: done.join(' → '),
      ok: failed === 0,
    }).catch((e) => console.error('[automation] 실행 기록 실패:', e?.message ?? e));
  }
  return current;
}

function isEmptyValue(v) {
  return v === null || v === undefined || v === '' || (Array.isArray(v) && v.length === 0);
}

/** 상태/우선순위 id — 업무에 id가 없거나(예전 업무) 지워진 id면 같은 분류/단계의 첫 정의로 본다
 * (클라이언트 필터와 같은 규칙). */
function effectiveDefId(id, list, sameGroup) {
  if (id && list.some((d) => d.id === id)) return id;
  return list.find(sameGroup)?.id ?? null;
}

async function evaluateCondition(config, task, loadDefs) {
  const { field, op, value } = config;
  let actual;
  if (field === 'status') {
    const { statuses } = await loadDefs();
    actual = effectiveDefId(task.statusId, statuses, (s) => s.category === task.status);
  } else if (field === 'priority') {
    const { priorities } = await loadDefs();
    actual = effectiveDefId(task.priorityId, priorities, (p) => p.level === task.priority);
  } else if (field === 'assignee') {
    actual = task.assigneeId ?? null;
  } else if (field === 'type') {
    actual = task.typeId ?? null;
  } else if (typeof field === 'string' && field.startsWith('field:')) {
    const fieldId = field.slice('field:'.length);
    actual = (task.customValues ?? {})[fieldId];
    // 날짜 필드는 epoch ms로 저장되고 조건 값은 'YYYY-MM-DD'라 한국 시간 날짜로 맞춰 비교한다.
    const { fields } = await loadDefs();
    if (fields.find((f) => f.id === fieldId)?.kind === 'date' && typeof actual === 'number' && Number.isFinite(actual)) {
      actual = seoulDay(actual);
    }
  } else {
    return false;
  }
  if (op === 'empty') return isEmptyValue(actual);
  if (op === 'not_empty') return !isEmptyValue(actual);
  const same = valueMatches(actual, value);
  if (op === 'eq') return same;
  if (op === 'neq') return !same;
  return false;
}

/** 조건 값과 같은지 — 다중 선택은 그 선택지를 포함하면, 숫자는 숫자로 비교한다. */
function valueMatches(actual, expected) {
  if (isEmptyValue(actual) || expected === null || expected === undefined) return false;
  if (Array.isArray(actual)) return actual.some((v) => String(v) === String(expected));
  if (typeof actual === 'number' && expected !== '' && Number.isFinite(Number(expected))) {
    return actual === Number(expected);
  }
  return String(actual) === String(expected);
}

/** 알림 제목(프로젝트 · 업무 번호). */
function notifyTitle(project, task) {
  return `${project.name} · ${project.identifier}-${task.seq}`;
}

async function applyGraphAction({ project, rule, task, node, notifier, io, loadActorName = async () => null }) {
  const config = node.config ?? {};
  switch (node.type) {
    case 'set_field': {
      const { field, value } = config;
      // 자동화가 바꾼 값은 자동화 이름으로 업무 기록에 남긴다(요청한 사람이 바꾼 것처럼 보이지 않게).
      const record = (line) =>
        insertTaskActivities([
          {
            taskId: task.id,
            actorId: null,
            actorName: `자동화 · ${rule.name}`,
            kind: null,
            detail: null,
            previous: null,
            color: null,
            ...line,
          },
        ]);
      if (field === 'status') {
        const st = value ? await findTaskStatusById(value) : null;
        if (!st || st.projectId !== project.id) throw new AutomationActionError('상태를 찾을 수 없습니다.');
        // status(분류)와 완료 시각은 항상 상태와 맞춘다(예전 set_status와 같은 방식).
        await updateTask(task.id, {
          statusId: st.id,
          status: st.category,
          completedAt: st.category === 'done' ? (task.completedAt ?? new Date()) : null,
        });
        if (st.id !== task.statusId) {
          const prev = task.statusId ? await findTaskStatusById(task.statusId) : null;
          await record({
            text: `상태를 '${st.name}'(으)로 변경했습니다.`,
            kind: 'status',
            detail: st.name,
            previous: prev?.name ?? null,
            color: st.color ?? null,
          });
        }
      } else if (field === 'priority') {
        const p = value ? await findTaskPriorityById(value) : null;
        if (!p || p.projectId !== project.id) throw new AutomationActionError('우선순위를 찾을 수 없습니다.');
        await updateTask(task.id, { priorityId: p.id, priority: p.level });
        if (p.id !== task.priorityId) await record({ text: `우선순위를 '${p.name}'(으)로 변경했습니다.` });
      } else if (field === 'assignee') {
        const assigneeId = value ?? null;
        // 이미 그 담당자면 그대로 둔다(마감 임박 알림 기록을 괜히 지우지 않도록).
        if (assigneeId === (task.assigneeId ?? null)) return;
        // 저장한 뒤 프로젝트에서 나간 사람일 수 있다.
        if (assigneeId && !(await isProjectMember(project.id, assigneeId))) {
          throw new AutomationActionError('담당자가 프로젝트 구성원이 아닙니다.');
        }
        await updateTask(task.id, { assigneeId, dueRemindedFor: null });
        const user = assigneeId ? await findUserById(assigneeId) : null;
        await record({
          text: assigneeId ? `담당자를 ${user?.name ?? user?.username ?? '알 수 없음'}(으)로 지정했습니다.` : '담당자를 해제했습니다.',
        });
        if (assigneeId) {
          await notifier?.notify({
            project,
            task,
            kind: 'assigned',
            targetIds: [assigneeId],
            title: notifyTitle(project, task),
            body: `자동화 '${rule.name}'이(가) 업무를 배정했습니다: ${task.title}`,
          });
        }
      } else if (field === 'type') {
        const typeId = value ?? null;
        const type = typeId ? await findTaskTypeById(typeId) : null;
        if (typeId && (!type || type.projectId !== project.id)) throw new AutomationActionError('유형을 찾을 수 없습니다.');
        await updateTask(task.id, { typeId });
        if (typeId !== (task.typeId ?? null)) {
          await record({ text: type ? `유형을 '${type.name}'(으)로 변경했습니다.` : '유형을 지웠습니다.' });
        }
      } else {
        throw new Error(`알 수 없는 필드: ${field}`);
      }
      return;
    }
    case 'create_task':
      await createTaskFromAutomation({ project, rule, task, config, notifier });
      return;
    case 'archive_task':
      if (!task.archivedAt) await setTaskArchived(task.id, true);
      return;
    case 'chat_message': {
      const room = config.roomId ? await findRoomById(config.roomId) : null;
      if (!room || room.teamId !== project.teamId || room.isSecret) throw new AutomationActionError('채팅방을 찾을 수 없습니다.');
      // 이 메시지는 규칙을 저장한 사람의 권한으로 올라간다 — 저장한 뒤 방에서 나갔거나, 프로젝트에서 빠졌거나, 관리 권한을
      // 잃었거나, 정지·탈퇴·준회원 강등됐으면 더는 올리지 않고 규칙을 끈다(저장한 사람이 없는 예전 규칙도 같다). 안 그러면
      // 권한을 잃은 사람이 자기 방(나와의 대화 등)을 고른 규칙으로 이 프로젝트의 업무 내용을 계속 받아 볼 수 있었다.
      const lost = await chatSaverDenial(project, room, config.savedBy);
      if (lost) throw new AutomationAccessLostError(lost);
      // 저장한 뒤 토픽이 읽기 전용·보관으로 바뀌었을 수 있어 실행할 때 다시 본다(다시 풀릴 수 있으니 규칙은 끄지 않는다).
      const denial = await chatMessageDenial(room, config.savedBy);
      if (denial) throw new AutomationActionError(denial);
      // 규칙마다·채팅방마다 10분 상한 — 넘치면 이번 알림만 건너뛴다(projectNotifications.js AutomationChatThrottle).
      if (chatThrottle.take(rule.id, room.id) > 0) throw new AutomationActionError(AUTOMATION_CHAT_THROTTLED);
      // 보낸 사람 이름이 이미 '자동화'라 머리말에는 규칙 이름만 두고, 누구의 변경으로 올라온 글인지 끝에 적는다. 사람
      // 메시지처럼 안읽음·푸시가 가게 일반 텍스트로 올린다(시스템 메시지는 알림이 안 울린다).
      const body = clip(await fillTaskTokens(config.text, project, task), 1000);
      const text = automationChatText({
        ruleName: rule.name,
        taskKey: `${project.identifier}-${task.seq}`,
        taskTitle: task.title,
        body,
        actorName: await loadActorName(),
      });
      await postBotMessage(io ?? { to: () => ({ emit() {} }) }, room, text, { senderName: '자동화' });
      return;
    }
    default:
      throw new Error(`알 수 없는 액션: ${node.type}`);
  }
}

/**
 * "업무 생성" 액션 — POST /projects/:id/tasks와 같은 번호 발급·상태/우선순위 기본값으로 같은
 * 프로젝트에 새 업무(하위 업무 아님)를 만든다. 만든 사람은 규칙을 만든 사람으로 남긴다.
 * 자동화로 만든 업무는 다시 "업무 생성" 자동화를 부르지 않는다(무한 반복 방지).
 */
async function createTaskFromAutomation({ project, rule, task, config, notifier }) {
  let st = config.statusId ? await findTaskStatusById(config.statusId) : null;
  // 저장 뒤에 지워진 상태면 요청에 상태가 없을 때처럼 첫 '할 일' 상태로 만든다.
  if (!st || st.projectId !== project.id) st = await findFirstStatusOfCategory(project.id, 'todo');
  const status = st?.category ?? 'todo';
  let assigneeId = config.assignee === 'current_assignee' ? (task.assigneeId ?? null) : (config.assignee ?? null);
  // 그 사이 프로젝트에서 나간 사람이면 담당자 없이 만든다(업무 자체는 만들어야 하므로).
  if (assigneeId && !(await isProjectMember(project.id, assigneeId))) assigneeId = null;
  // {{task.title}} 등을 채운 뒤 길이를 다시 맞춘다(저장 때는 변수를 적힌 그대로 셌다).
  const taskTitle = clip((await fillTaskTokens(config.title, project, task)).trim(), 200).trim() || config.title;
  const seq = await takeNextTaskSeq(project.id);
  const created = await insertTask({
    id: randomUUID(),
    projectId: project.id,
    seq,
    parentTaskId: null,
    title: taskTitle,
    description: null,
    assigneeId,
    status,
    statusId: st?.id ?? null,
    customValues: {},
    // 우선순위를 안 보낸 POST와 같다 — 단계는 기본값, 우선순위는 비워 둔다("—").
    priority: 'normal',
    priorityId: null,
    typeId: null,
    startDate: null,
    dueDate: null,
    createdBy: rule.createdBy ?? null,
    completedAt: status === 'done' ? new Date() : null,
  });
  await insertTaskActivities([
    {
      taskId: created.id,
      actorId: null,
      actorName: `자동화 · ${rule.name}`,
      text: '업무를 만들었습니다.',
      kind: 'created',
      detail: st?.name ?? null,
      previous: null,
      color: st?.color ?? null,
    },
  ]);
  if (!notifier) return created;
  const title = notifyTitle(project, created);
  if (assigneeId) {
    await notifier.notify({
      project,
      task: created,
      kind: 'assigned',
      targetIds: [assigneeId],
      title,
      body: `자동화 '${rule.name}'이(가) 업무를 배정했습니다: ${created.title}`,
    });
  }
  const owners = (await listProjectMemberUsers(project.id)).filter((m) => m.projectRole === 'owner').map((m) => m.id);
  await notifier.notify({
    project,
    task: created,
    kind: 'created',
    targetIds: owners,
    title,
    body: `자동화 '${rule.name}'이(가) 업무를 만들었습니다: ${created.title}`,
  });
  return created;
}

async function applyAction({ project, task, rule, action, notifier }) {
  const title = `${project.name} · ${project.identifier}-${task.seq}`;
  switch (action.kind) {
    case 'set_assignee': {
      // 저장한 뒤 프로젝트에서 빠졌거나 정지·탈퇴·준회원 강등된 사람일 수 있다 — 구성원이 아닌 사람에게 업무를 넘기지
      // 않는다(넘기면 그 사람이 담당자로 남아 화면에 보이고, 다시 구성원이 되는 순간 알림 없이 담당이 된다).
      if (!(await isProjectMember(project.id, action.userId))) {
        throw new AutomationActionError('담당자가 프로젝트 구성원이 아닙니다.');
      }
      const updated = await updateTask(task.id, { assigneeId: action.userId, dueRemindedFor: null });
      await notifier.notify({
        project,
        task: updated,
        kind: 'assigned',
        targetIds: [action.userId],
        title,
        body: `자동화 '${rule.name}'이(가) 업무를 배정했습니다: ${task.title}`,
      });
      return updated;
    }
    case 'set_status': {
      const st = await findTaskStatusById(action.statusId);
      if (!st) return task;
      return (
        (await updateTask(task.id, {
          statusId: st.id,
          status: st.category,
          completedAt: st.category === 'done' ? (task.completedAt ?? new Date()) : null,
        })) ?? task
      );
    }
    case 'set_priority':
      return (await updateTask(task.id, { priority: action.priority })) ?? task;
    case 'add_reference': {
      // 담당자 지정과 같은 이유로 지금도 구성원인지 다시 본다.
      if (!(await isProjectMember(project.id, action.userId))) {
        throw new AutomationActionError('참조자가 프로젝트 구성원이 아닙니다.');
      }
      const refs = (await listReferencesForTasks([task.id]))[task.id] ?? [];
      if (!refs.includes(action.userId)) {
        await setTaskReferences(task.id, [...refs, action.userId]);
        await notifier.notify({
          project,
          task,
          kind: 'referenced',
          targetIds: [action.userId],
          title,
          body: `자동화 '${rule.name}'이(가) 참조자로 지정했습니다: ${task.title}`,
        });
      }
      return task;
    }
    case 'add_comment':
      await insertTaskComment({
        id: randomUUID(),
        taskId: task.id,
        projectId: project.id,
        senderId: null,
        senderName: `자동화 · ${rule.name}`,
        text: action.text,
      });
      return task;
    case 'notify':
      await notifier.notify({
        project,
        task,
        kind: 'automation',
        targetIds: [action.userId],
        title,
        body: `자동화 '${rule.name}': ${task.title}`,
      });
      return task;
    default:
      return task;
  }
}
