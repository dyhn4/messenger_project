// 할 일(To-Do)의 순수 규칙 — 입력 검사·권한·진척률/알림 계산을 DB 없이 단위 테스트할 수 있게 todos.js에서 떼어 냈다.
import { resolveRawUrl, knownUploadPath } from './upload.js';
import { graphemeLength } from './permissions.js';

export const TODO_TITLE_MAX = 100;
export const TODO_DESCRIPTION_MAX = 2000;
export const TODO_ASSIGNEES_MAX = 30;
export const TODO_ATTACHMENTS_MAX = 30;
export const TODO_REMINDERS_MAX = 5;
export const TODO_LIST_DEFAULT_LIMIT = 30;
export const TODO_LIST_MAX_LIMIT = 100;
// 서버가 꺼져 있다가 켜졌을 때 하루도 더 지난 알림까지 한꺼번에 울리지 않도록 — 이보다 오래된 알림은 조용히 넘긴다.
export const TODO_REMINDER_STALE_MS = 24 * 60 * 60 * 1000;

export const TODO_SCOPES = ['mine', 'assigned_by_me', 'team'];
export const TODO_SORTS = ['due', 'created'];

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
const STORED_UPLOAD_RE = /^\/uploads\/[^/\\]+$/;

export function isUuid(value) {
  return typeof value === 'string' && UUID_RE.test(value);
}

/** 'YYYY-MM-DD'이고 실제로 있는 날짜(2월 30일 같은 건 거절)인지. */
export function isValidDateString(value) {
  if (typeof value !== 'string') return false;
  const m = DATE_RE.exec(value);
  if (!m) return false;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const date = new Date(Date.UTC(y, mo - 1, d));
  return date.getUTCFullYear() === y && date.getUTCMonth() === mo - 1 && date.getUTCDate() === d;
}

/** 진척률 → 상태: 0 = 대기, 1~99 = 진행, 100 = 완료. */
export function statusOf(progress) {
  if (progress >= 100) return 'done';
  if (progress > 0) return 'doing';
  return 'todo';
}

// ── 입력 검사 ───────────────────────────────────────────────────────────

function parseTitle(raw) {
  const title = typeof raw === 'string' ? raw.trim() : '';
  if (!title) return { error: '할 일 제목을 입력하세요.' };
  if (graphemeLength(title) > TODO_TITLE_MAX) return { error: `제목은 ${TODO_TITLE_MAX}자 이내로 입력하세요.` };
  return { value: title };
}

function parseDescription(raw) {
  if (raw === undefined || raw === null) return { value: null };
  if (typeof raw !== 'string') return { error: '설명이 올바르지 않습니다.' };
  const value = raw.trim() || null;
  if (value && graphemeLength(value) > TODO_DESCRIPTION_MAX) {
    return { error: `설명은 ${TODO_DESCRIPTION_MAX}자 이내로 입력하세요.` };
  }
  return { value };
}

function parseDate(raw, label) {
  if (raw === undefined || raw === null || raw === '') return { value: null };
  if (!isValidDateString(raw)) return { error: `${label}이 올바르지 않습니다. (YYYY-MM-DD)` };
  return { value: raw };
}

/** 시작일≤기한 검사 — 문자열 비교가 곧 날짜 비교다. */
export function checkDateOrder(startDate, dueDate) {
  if (startDate && dueDate && startDate > dueDate) return '시작일은 종료일보다 늦을 수 없습니다.';
  return null;
}

function parseAssigneeIds(raw) {
  if (!Array.isArray(raw)) return { error: '담당자 목록이 올바르지 않습니다.' };
  if (raw.some((id) => !isUuid(id))) return { error: '담당자 목록이 올바르지 않습니다.' };
  const ids = [...new Set(raw.map((id) => id.toLowerCase()))];
  if (ids.length > TODO_ASSIGNEES_MAX) return { error: `담당자는 ${TODO_ASSIGNEES_MAX}명까지 지정할 수 있습니다.` };
  return { value: ids };
}

/**
 * 첨부 목록 검사 — 업로드 결과 모양 [{kind, fileUrl, fileName, fileSize, mimeType, thumbnailUrl}]. 서명된
 * /files/<token>은 원본 경로(/uploads/...)로 되돌려 저장한다. [existingUrls]는 이 할 일에 이미 저장된 경로들 —
 * 화면이 오래 들고 있어 만료된 서명 링크를 그대로 돌려보내도 같은 파일이면 인정한다(수정 때만).
 * 알아볼 수 없는 링크(만료·위조·외부 주소)가 있으면 조용히 빼지 않고 거절한다.
 */
export function parseAttachments(raw, existingUrls = []) {
  if (!Array.isArray(raw)) return { error: '첨부 목록이 올바르지 않습니다.' };
  if (raw.length > TODO_ATTACHMENTS_MAX) return { error: `첨부 파일은 ${TODO_ATTACHMENTS_MAX}개까지 올릴 수 있습니다.` };
  const known = new Set(existingUrls);
  const toStored = (url, { allowKnown }) => {
    if (typeof url !== 'string' || !url) return null;
    const direct = resolveRawUrl(url);
    if (direct && STORED_UPLOAD_RE.test(direct)) return direct;
    if (allowKnown) {
      const path = knownUploadPath(url);
      if (path && known.has(path)) return path;
    }
    return null;
  };
  const items = [];
  for (const a of raw) {
    if (!a || typeof a !== 'object') return { error: '첨부 목록이 올바르지 않습니다.' };
    const fileUrl = toStored(a.fileUrl, { allowKnown: true });
    if (!fileUrl) return { error: '사용할 수 없는 첨부 링크가 있습니다. 파일을 다시 올려 주세요.' };
    items.push({
      kind: a.kind === 'file' ? 'file' : 'image',
      fileUrl,
      fileName: typeof a.fileName === 'string' ? a.fileName : null,
      fileSize: typeof a.fileSize === 'number' && Number.isFinite(a.fileSize) ? Math.trunc(a.fileSize) : null,
      mimeType: typeof a.mimeType === 'string' ? a.mimeType : null,
      thumbnailUrl: toStored(a.thumbnailUrl, { allowKnown: true }),
    });
  }
  return { value: items };
}

/** 새 알림 한 건 검사(ms 시각, 지금보다 뒤). */
function parseNewRemindAt(raw, now) {
  if (typeof raw !== 'number' || !Number.isFinite(raw)) return { error: '알림 시각이 올바르지 않습니다.' };
  if (raw <= now) return { error: '알림 시각은 지금보다 뒤여야 합니다.' };
  return { value: Math.trunc(raw) };
}

/** 만들 때의 알림 목록 — [ms, ...](지금보다 뒤, 최대 5개, 같은 시각 중복은 하나로). */
export function parseNewReminders(raw, now = Date.now()) {
  if (!Array.isArray(raw)) return { error: '알림 목록이 올바르지 않습니다.' };
  const times = [];
  for (const item of raw) {
    const r = parseNewRemindAt(typeof item === 'object' && item !== null ? item.remindAt : item, now);
    if (r.error) return r;
    times.push(r.value);
  }
  const unique = [...new Set(times)];
  if (unique.length > TODO_REMINDERS_MAX) return { error: `알림은 ${TODO_REMINDERS_MAX}개까지 추가할 수 있습니다.` };
  return { value: unique };
}

/**
 * POST /rooms/:roomId/todos 본문 검사 — 통과하면 `{ title, description, assigneeIds, startDate, dueDate,
 * attachments, reminders(ms[]), sourceMessageId, sourceCommentId }`, 아니면 `{ error }`.
 * 담당자가 그 방 멤버인지, 출처 글이 그 방의 것인지는 DB가 필요해서 todos.js가 따로 본다.
 */
export function parseTodoCreate(body, now = Date.now()) {
  const title = parseTitle(body?.title);
  if (title.error) return title;
  const description = parseDescription(body?.description);
  if (description.error) return description;
  const assignees = parseAssigneeIds(body?.assigneeIds ?? []);
  if (assignees.error) return assignees;
  const start = parseDate(body?.startDate, '시작일');
  if (start.error) return start;
  const due = parseDate(body?.dueDate, '종료일');
  if (due.error) return due;
  const orderError = checkDateOrder(start.value, due.value);
  if (orderError) return { error: orderError };
  const attachments = parseAttachments(body?.attachments ?? []);
  if (attachments.error) return attachments;
  const reminders = parseNewReminders(body?.reminders ?? [], now);
  if (reminders.error) return reminders;
  for (const key of ['sourceMessageId', 'sourceCommentId']) {
    if (body?.[key] !== undefined && body?.[key] !== null && !isUuid(body[key])) {
      return { error: '원본 메시지 정보가 올바르지 않습니다.' };
    }
  }
  return {
    title: title.value,
    description: description.value,
    assigneeIds: assignees.value,
    startDate: start.value,
    dueDate: due.value,
    attachments: attachments.value,
    reminders: reminders.value,
    sourceMessageId: body?.sourceMessageId ?? null,
    sourceCommentId: body?.sourceCommentId ?? null,
  };
}

/** PATCH에서 보낼 수 있는 필드 전부, 그리고 그중 담당자가 못 고치는 것. */
export const PATCH_FIELDS = [
  'title',
  'description',
  'assigneeIds',
  'startDate',
  'dueDate',
  'attachments',
  'reminders',
  'progress',
];
export const ASSIGNEE_FORBIDDEN_FIELDS = ['assigneeIds'];

/**
 * PATCH 본문 1차 검사 — 보낸 필드만 `fields`에 담는다(없는 필드는 안 바뀐다). 방을 옮기려는 시도(roomId·teamId)는
 * 거절한다. 통과하면 `{ fields: { title?, description?, assigneeIds?, startDate?, dueDate?, attachments?, reminders?, progress? } }`.
 * reminders는 [{id?, remindAt}] 그대로 두고(기존 것과 맞춰 보는 planReminders가 검사), attachments의 기존 링크
 * 인정과 시작일≤종료일(안 보낸 쪽은 저장된 값 기준)은 todos.js가 현재 값과 합쳐 다시 본다.
 */
export function parseTodoPatch(body) {
  if (!body || typeof body !== 'object') return { error: '수정할 내용이 없습니다.' };
  if ('roomId' in body || 'teamId' in body) return { error: '할 일은 다른 대화방으로 옮길 수 없습니다.' };
  const fields = {};
  if ('title' in body) {
    const r = parseTitle(body.title);
    if (r.error) return r;
    fields.title = r.value;
  }
  if ('description' in body) {
    const r = parseDescription(body.description);
    if (r.error) return r;
    fields.description = r.value;
  }
  if ('assigneeIds' in body) {
    const r = parseAssigneeIds(body.assigneeIds);
    if (r.error) return r;
    fields.assigneeIds = r.value;
  }
  if ('startDate' in body) {
    const r = parseDate(body.startDate, '시작일');
    if (r.error) return r;
    fields.startDate = r.value;
  }
  if ('dueDate' in body) {
    const r = parseDate(body.dueDate, '종료일');
    if (r.error) return r;
    fields.dueDate = r.value;
  }
  if ('attachments' in body) {
    if (!Array.isArray(body.attachments)) return { error: '첨부 목록이 올바르지 않습니다.' };
    if (body.attachments.length > TODO_ATTACHMENTS_MAX) {
      return { error: `첨부 파일은 ${TODO_ATTACHMENTS_MAX}개까지 올릴 수 있습니다.` };
    }
    fields.attachments = body.attachments;
  }
  if ('reminders' in body) {
    if (!Array.isArray(body.reminders)) return { error: '알림 목록이 올바르지 않습니다.' };
    fields.reminders = body.reminders;
  }
  if ('progress' in body) {
    const p = body.progress;
    if (typeof p !== 'number' || !Number.isInteger(p) || p < 0 || p > 100) {
      return { error: '진척률은 0~100 사이의 정수여야 합니다.' };
    }
    fields.progress = p;
  }
  if (Object.keys(fields).length === 0) return { error: '수정할 내용이 없습니다.' };
  return { fields };
}

// ── 권한 ────────────────────────────────────────────────────────────────

/**
 * 이 사람의 역할 — 'creator' | 'assignee' | 'viewer'. 만든 사람이면서 담당자이기도 하면 creator.
 */
export function todoRole({ creatorId, assigneeIds, userId }) {
  if (creatorId && creatorId === userId) return 'creator';
  if (assigneeIds.includes(userId)) return 'assignee';
  return 'viewer';
}

/**
 * 역할별 권한 — canEdit(제목·설명·파일·기한·알림·진척률), canManage(담당자 관리·삭제). 만든 사람 계정이 사라진
 * (탈퇴 → creator_id null) 할 일은 아무도 지울 수 없게 되므로, 그때만 담당자에게도 관리 권한을 준다.
 */
export function todoPermissions({ role, creatorId }) {
  return {
    canEdit: role === 'creator' || role === 'assignee',
    canManage: role === 'creator' || (role === 'assignee' && !creatorId),
  };
}

/** 이 역할이 PATCH 본문의 필드들을 고칠 수 있는지 — 못 고치면 `{ status: 403, error }`, 되면 null. */
export function patchDenial(role, creatorId, fieldNames) {
  const { canEdit, canManage } = todoPermissions({ role, creatorId });
  if (!canEdit) return { status: 403, error: '이 할 일을 수정할 권한이 없습니다.' };
  if (!canManage && fieldNames.some((f) => ASSIGNEE_FORBIDDEN_FIELDS.includes(f))) {
    return { status: 403, error: '담당자는 담당자 목록을 바꿀 수 없습니다.' };
  }
  return null;
}

// ── 진척률·알림 ─────────────────────────────────────────────────────────

/** 진척률이 바뀔 때의 completedAt — 100이 되면 그때(이미 완료였으면 처음 값 유지), 100 아래로 내리면 해제. */
export function nextCompletedAt(progress, prevCompletedAt, now = new Date()) {
  if (progress >= 100) return prevCompletedAt ?? now;
  return null;
}

/**
 * 알림 일정 수정 계획 — [existing]은 저장된 {id, remindAt(ms), sent}, [incoming]은 본문의 [{id?, remindAt}].
 * 기존 id에 같은 시각이면 그대로 두고(보낸 기록 유지), 시각이 바뀌면 시각만 바꿔 보낸 기록을 지우고(다시 울림),
 * id 없는 새 항목은 추가한다. 본문에 없는 기존 항목은 지운다. 새로 잡거나 바꾸는 시각은 지금보다 뒤여야 한다.
 * 통과하면 `{ deleteIds, updates:[{id, remindAt}], inserts:[ms] }`, 아니면 `{ error }`.
 */
export function planReminders(existing, incoming, now = Date.now()) {
  if (!Array.isArray(incoming)) return { error: '알림 목록이 올바르지 않습니다.' };
  if (incoming.length > TODO_REMINDERS_MAX) return { error: `알림은 ${TODO_REMINDERS_MAX}개까지 추가할 수 있습니다.` };
  const byId = new Map(existing.map((e) => [e.id, e]));
  const keptIds = new Set();
  const updates = [];
  const inserts = [];
  const seenTimes = new Set();
  for (const item of incoming) {
    const remindAt = typeof item === 'object' && item !== null ? item.remindAt : item;
    const id = typeof item === 'object' && item !== null ? item.id : null;
    if (typeof remindAt !== 'number' || !Number.isFinite(remindAt)) return { error: '알림 시각이 올바르지 않습니다.' };
    const time = Math.trunc(remindAt);
    if (seenTimes.has(time)) continue; // 같은 시각을 두 번 넣어도 하나로.
    seenTimes.add(time);
    const prev = id ? byId.get(id) : null;
    if (prev && !keptIds.has(prev.id)) {
      keptIds.add(prev.id);
      if (prev.remindAt !== time) {
        if (time <= now) return { error: '알림 시각은 지금보다 뒤여야 합니다.' };
        updates.push({ id: prev.id, remindAt: time });
      }
      continue;
    }
    if (time <= now) return { error: '알림 시각은 지금보다 뒤여야 합니다.' };
    inserts.push(time);
  }
  if (keptIds.size + inserts.length > TODO_REMINDERS_MAX) {
    return { error: `알림은 ${TODO_REMINDERS_MAX}개까지 추가할 수 있습니다.` };
  }
  return { deleteIds: existing.filter((e) => !keptIds.has(e.id)).map((e) => e.id), updates, inserts };
}

/** 담당자를 바꿨을 때 새로 담당이 된 사람 — 푸시·토스트 대상(바꾼 본인은 뺀다). */
export function newlyAssigned(beforeIds, afterIds, actorId) {
  const before = new Set(beforeIds);
  return afterIds.filter((id) => !before.has(id) && id !== actorId);
}

/**
 * 푸시를 받을 사람 — 후보 중 소켓이 안 붙어 있고([onlineIds] 아님) 그 방을 뮤트하지 않은([mutedIds] 아님) 사람.
 * 온라인인 사람은 소켓 이벤트(todo:changed / todo:reminder)로 앱이 직접 알린다(채팅 푸시와 같은 분리).
 */
export function pushTargets(candidateIds, { actorId = null, onlineIds = new Set(), mutedIds = new Set() } = {}) {
  return [...new Set(candidateIds)].filter((id) => id !== actorId && !onlineIds.has(id) && !mutedIds.has(id));
}

/** 알림이 울릴 사람 — 담당자가 있으면 담당자들, 없으면 만든 사람. */
export function reminderTargets(assigneeIds, creatorId) {
  if (assigneeIds.length > 0) return [...assigneeIds];
  return creatorId ? [creatorId] : [];
}

/** 이 알림을 지금 보내도 되는지 — 이미 완료된 할 일이나 너무 오래 묵은 알림은 보내지 않는다. */
export function shouldDeliverReminder({ progress, remindAt, now = Date.now() }) {
  if (progress >= 100) return false;
  return now - remindAt <= TODO_REMINDER_STALE_MS;
}

// ── 목록 쿼리 ───────────────────────────────────────────────────────────

/**
 * GET /todos 쿼리 검사 — 통과하면 `{ teamId, scope, includeDone, roomId, sort, limit, offset }`, 아니면 `{ error }`.
 * 정렬이 "미완료 먼저·마감 임박순·생성순"의 복합 키라 커서 대신 offset으로 이어 받는다(다른 목록의 before와 다른 점).
 */
export function parseTodoListQuery(query) {
  const teamId = typeof query?.teamId === 'string' ? query.teamId : '';
  if (!isUuid(teamId)) return { error: 'teamId가 필요합니다.' };
  const scope = typeof query?.scope === 'string' && query.scope ? query.scope : 'mine';
  if (!TODO_SCOPES.includes(scope)) return { error: `scope는 ${TODO_SCOPES.join('|')} 중 하나여야 합니다.` };
  const sort = typeof query?.sort === 'string' && query.sort ? query.sort : 'due';
  if (!TODO_SORTS.includes(sort)) return { error: `sort는 ${TODO_SORTS.join('|')} 중 하나여야 합니다.` };
  let includeDone = true;
  if (query?.includeDone !== undefined && query.includeDone !== '') {
    if (query.includeDone === 'true' || query.includeDone === true) includeDone = true;
    else if (query.includeDone === 'false' || query.includeDone === false) includeDone = false;
    else return { error: 'includeDone은 true/false여야 합니다.' };
  }
  let roomId = null;
  if (query?.roomId !== undefined && query.roomId !== '') {
    if (typeof query.roomId !== 'string') return { error: 'roomId가 올바르지 않습니다.' };
    roomId = query.roomId;
  }
  let limit = TODO_LIST_DEFAULT_LIMIT;
  if (query?.limit !== undefined && query.limit !== '') {
    const n = Math.floor(Number(query.limit));
    if (!Number.isFinite(n) || n < 1) return { error: 'limit은 1 이상의 숫자여야 합니다.' };
    limit = Math.min(n, TODO_LIST_MAX_LIMIT);
  }
  let offset = 0;
  if (query?.offset !== undefined && query.offset !== '') {
    const n = Math.floor(Number(query.offset));
    if (!Number.isFinite(n) || n < 0) return { error: 'offset은 0 이상의 숫자여야 합니다.' };
    offset = n;
  }
  return { teamId, scope, includeDone, roomId, sort, limit, offset };
}
