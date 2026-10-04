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
// 기간(from~to)으로 받을 때(달력 보기) — 한 번에 최대 100일(양 끝 포함), 그 대신 limit을 500까지 올려 한 번에 받는다.
export const TODO_RANGE_MAX_DAYS = 100;
export const TODO_RANGE_MAX_LIMIT = 500;
// 서버가 꺼져 있다가 켜졌을 때 하루도 더 지난 알림까지 한꺼번에 울리지 않도록 — 이보다 오래된 알림은 조용히 넘긴다.
export const TODO_REMINDER_STALE_MS = 24 * 60 * 60 * 1000;
// 고를 수 있는 진척률(잔디: 대기 / 진행 25·50·75% / 완료 100%).
export const TODO_PROGRESS_STEPS = [0, 25, 50, 75, 100];
// 진척률을 쓸 곳이 없는 사람(담당자가 있는 할 일의 담당자 아닌 사람)의 403 문구 — 요청 앞의 검사(patchDenial)와
// 할 일 행을 잠근 뒤의 다시 판단(db/queries/todos.js updateTodo)이 같은 문구를 쓴다.
export const TODO_PROGRESS_DENIED = '담당자만 진척률을 바꿀 수 있습니다.';

// mine = 나의 할 일, assigned_by_me = 부여한 할 일, team = 모든 할 일(앱의 라벨) — 와이어 값은 예전 그대로다.
export const TODO_SCOPES = ['mine', 'assigned_by_me', 'team'];
export const TODO_SORTS = ['due', 'created'];

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
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

/** 사람이 고를 수 있는 진척률인지 — 0·25·50·75·100만(집계 값은 1~99 아무 값이나 될 수 있지만 직접 고르지는 못한다). */
export function isValidProgress(value) {
  return TODO_PROGRESS_STEPS.includes(value);
}

/** 이 대화방에 할 일을 만들 수 없는 이유 — 비밀 대화(서버가 내용을 볼 수 없음)·보드 뷰 토픽(잔디: 챗 뷰 토픽·채팅에서만). 되면 null. */
export function todoRoomError(room) {
  if (room.isSecret) return '비밀 대화에서는 할 일을 만들 수 없습니다.';
  if (room.type === 'topic' && room.viewMode === 'board') return '보드 뷰 토픽에서는 할 일을 만들 수 없습니다.';
  return null;
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

/** 'HH:mm'(24시간, 00:00~23:59)인지 — 날짜 칸과 같은 "그 지역의 벽시계" 시각이다. */
export function isValidTimeString(value) {
  return typeof value === 'string' && TIME_RE.test(value);
}

function parseTime(raw, label) {
  if (raw === undefined || raw === null || raw === '') return { value: null };
  if (!isValidTimeString(raw)) return { error: `${label}이 올바르지 않습니다. (HH:mm)` };
  return { value: raw };
}

/**
 * 기간(시작일·시작 시간 ~ 종료일·종료 시간) 검사 — 시간은 그 날짜가 있어야 하고, 두 날짜가 다 있으면 (날짜, 시간) 순으로
 * 시작이 종료보다 늦으면 안 된다. 시간이 없는 쪽은 날짜만 비교하도록 시작은 00:00, 종료는 23:59로 본다(같은 날 시작
 * 15:00 ~ 종료 시간 없음은 통과). 'YYYY-MM-DDTHH:mm' 문자열 비교가 곧 시각 비교다. 문제가 없으면 null.
 */
export function checkPeriod({ startDate = null, startTime = null, dueDate = null, dueTime = null }) {
  if (startTime && !startDate) return '시작 시간은 시작일과 함께 정해야 합니다.';
  if (dueTime && !dueDate) return '종료 시간은 종료일과 함께 정해야 합니다.';
  if (startDate && dueDate && `${startDate}T${startTime ?? '00:00'}` > `${dueDate}T${dueTime ?? '23:59'}`) {
    return startDate > dueDate ? '시작일은 종료일보다 늦을 수 없습니다.' : '시작 시간은 종료 시간보다 늦을 수 없습니다.';
  }
  return null;
}

/**
 * PATCH의 기간 필드(startDate·startTime·dueDate·dueTime 중 보낸 것)를 저장된 값([stored])과 합친 결과 — 안 보낸 쪽은
 * 저장된 값 그대로지만, 날짜를 지우면(null) 그 시간도 함께 지운다. 통과하면 `{ value: 합친 기간, columns: 쓸 컬럼 }`
 * (columns는 보낸 필드 + 날짜를 지워 함께 지우는 시간), 아니면 `{ error }`(checkPeriod — 시간만 있고 날짜가 없음·순서).
 */
export function mergeTodoPeriod(stored, fields) {
  const value = {};
  const columns = {};
  for (const [dateKey, timeKey] of [
    ['startDate', 'startTime'],
    ['dueDate', 'dueTime'],
  ]) {
    value[dateKey] = dateKey in fields ? fields[dateKey] : (stored?.[dateKey] ?? null);
    if (dateKey in fields) columns[dateKey] = fields[dateKey];
    if (timeKey in fields) {
      value[timeKey] = fields[timeKey];
      columns[timeKey] = fields[timeKey];
    } else if (dateKey in fields && fields[dateKey] === null) {
      value[timeKey] = null;
      columns[timeKey] = null;
    } else {
      value[timeKey] = stored?.[timeKey] ?? null;
    }
  }
  const error = checkPeriod(value);
  if (error) return { error };
  return { value, columns };
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
 * /files/<token>은 원본 경로(/uploads/...)로 되돌려 저장한다. [existingUrls]는 이미 알고 있는 저장 경로들 — 수정 때는
 * 이 할 일에 저장된 첨부의 원본·축소 미리보기(storedAttachmentPaths), 만들 때는 출처 글(메시지·댓글)에 붙어 있는
 * 파일(sourceFilePaths). 화면이 오래 들고 있어 서명이 만료된 링크를 그대로 보내도 이 경로들의 파일이면 인정한다(서명은
 * 맞아야 한다 — knownUploadPath). 원본(fileUrl)이 그 밖의 알아볼 수 없는 링크(만료·위조·외부 주소)면 조용히 빼지 않고
 * 거절하고, 미리보기(thumbnailUrl)만 알아볼 수 없으면 미리보기 없이(null) 받는다.
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

/**
 * "메시지·댓글에서 할 일로 등록"의 출처 글에 지금 실제로 붙어 있는 파일 경로들(/uploads/...) — 만들기 요청의 첨부를
 * 알아보는 known 목록(parseAttachments). 댓글([comment])이면 그 댓글의 파일 칸만(앱은 댓글 자신의 파일만 싣는다),
 * 메시지([message])면 첨부 행들([attachments] — message_attachments)과 옛 방식의 파일 칸. 지운 파일(첨부 행의 deletedAt,
 * 메시지의 fileDeletedAt)은 빼고, 원본·축소 미리보기 경로를 함께 담는다(중복 없이).
 */
export function sourceFilePaths({ comment = null, message = null, attachments = [] } = {}) {
  const urls = [];
  if (comment) {
    urls.push(comment.fileUrl, comment.thumbnailUrl);
  } else if (message) {
    for (const a of attachments) {
      if (!a.deletedAt) urls.push(a.fileUrl, a.thumbnailUrl);
    }
    if (!message.fileDeletedAt) urls.push(message.fileUrl, message.thumbnailUrl);
  }
  return uniqueStoredPaths(urls);
}

/**
 * 할 일을 고칠 때 첨부를 알아보는 known 목록(parseAttachments) — 이 할 일에 지금 저장된 첨부 행들([rows] —
 * todo_attachments)의 원본과 축소 미리보기 경로. 앱은 첨부 목록이 바뀔 때마다 기존 첨부를 상세에서 받은 서명 링크
 * 그대로(원본·미리보기 모두) 다시 보내므로, 패널을 오래 열어 둬 둘 다 만료됐어도 미리보기까지 알아봐야 기존 사진의
 * 미리보기가 조용히 빠지지 않는다(검토 S2 — 만들 때의 sourceFilePaths가 미리보기를 함께 담는 것과 같은 이유).
 */
export function storedAttachmentPaths(rows = []) {
  return uniqueStoredPaths(rows.flatMap((a) => [a.fileUrl, a.thumbnailUrl]));
}

/** 저장 경로(/uploads/<이름>)인 값만 중복 없이 — 빈 칸(null)·외부 주소·서명 링크는 뺀다. */
function uniqueStoredPaths(urls) {
  return [...new Set(urls.filter((u) => typeof u === 'string' && STORED_UPLOAD_RE.test(u)))];
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
 * POST /rooms/:roomId/todos 본문 검사 — 통과하면 `{ title, description, assigneeIds, startDate, startTime, dueDate,
 * dueTime, attachments, reminders(ms[]), sourceMessageId, sourceCommentId }`, 아니면 `{ error }`. 시간('HH:mm')은
 * 그 날짜가 있어야 하고, 시작은 종료보다 늦을 수 없다(checkPeriod).
 * 담당자가 그 방 멤버인지, 출처 글이 그 방의 것인지는 DB가 필요해서 todos.js가 따로 본다. [sourceFileUrls]는 출처 글에
 * 지금 붙어 있는 파일 경로들(sourceFilePaths) — 오래전에 불러온 메시지를 등록해 첨부 서명이 만료됐어도 그 파일이면 받는다.
 */
export function parseTodoCreate(body, now = Date.now(), sourceFileUrls = []) {
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
  const startTime = parseTime(body?.startTime, '시작 시간');
  if (startTime.error) return startTime;
  const dueTime = parseTime(body?.dueTime, '종료 시간');
  if (dueTime.error) return dueTime;
  const periodError = checkPeriod({
    startDate: start.value,
    startTime: startTime.value,
    dueDate: due.value,
    dueTime: dueTime.value,
  });
  if (periodError) return { error: periodError };
  const attachments = parseAttachments(body?.attachments ?? [], sourceFileUrls);
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
    startTime: startTime.value,
    dueDate: due.value,
    dueTime: dueTime.value,
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
  'startTime',
  'dueDate',
  'dueTime',
  'attachments',
  'reminders',
  'progress',
];
export const ASSIGNEE_FORBIDDEN_FIELDS = ['assigneeIds'];

/**
 * PATCH 본문 1차 검사 — 보낸 필드만 `fields`에 담는다(없는 필드는 안 바뀐다). 방을 옮기려는 시도(roomId·teamId)는
 * 거절한다. 통과하면 `{ fields: { title?, description?, assigneeIds?, startDate?, startTime?, dueDate?, dueTime?,
 * attachments?, reminders?, progress? } }`. progress는 보내는 사람의 "내 진척률"(0·25·50·75·100 — 어디에 쓰는지는
 * progressTarget). reminders는 [{id?, remindAt}] 그대로 두고(기존 것과 맞춰 보는 planReminders가 검사), attachments의
 * 기존 링크 인정과 기간(시간만 있고 날짜 없음·시작≤종료 — 안 보낸 쪽은 저장된 값 기준, mergeTodoPeriod)은 todos.js가
 * 현재 값과 합쳐 다시 본다.
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
  if ('startTime' in body) {
    const r = parseTime(body.startTime, '시작 시간');
    if (r.error) return r;
    fields.startTime = r.value;
  }
  if ('dueTime' in body) {
    const r = parseTime(body.dueTime, '종료 시간');
    if (r.error) return r;
    fields.dueTime = r.value;
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
    if (!isValidProgress(body.progress)) return { error: '진척률은 0·25·50·75·100 중 하나여야 합니다.' };
    fields.progress = body.progress;
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
 * 역할별 권한 — canEdit(제목·설명·파일·기한·알림), canManage(담당자 관리·삭제). 진척률은 역할이 아니라 담당 여부로
 * 따로 본다(progressTarget). 만든 사람 계정이 사라진(탈퇴 → creator_id null) 할 일은 아무도 지울 수 없게 되므로,
 * 그때만 담당자에게도 관리 권한을 준다.
 */
export function todoPermissions({ role, creatorId }) {
  return {
    canEdit: role === 'creator' || role === 'assignee',
    canManage: role === 'creator' || (role === 'assignee' && !creatorId),
  };
}

/**
 * "내 진척률"을 어디에 쓸지 — 내가 (그 방에 있는) 담당자면 'assignee'(내 담당 행), 담당자가 없고 내가 만든 사람이면
 * 'todo'(todos.progress — 개인 할 일, 예전 방식), 그 밖은 null(만든 사람이라도 담당자가 아니면 못 바꾼다 — 잔디 "개별 진행").
 */
export function progressTarget({ creatorId, assigneeIds, userId }) {
  if (assigneeIds.includes(userId)) return 'assignee';
  if (assigneeIds.length === 0 && creatorId && creatorId === userId) return 'todo';
  return null;
}

/** DTO의 myProgress — [assignees]는 그 방에 있는 담당자 [{ userId, progress }]. 바꿀 수 없는 사람이면 null. */
export function myProgressOf({ creatorId, assignees, progress, userId }) {
  const target = progressTarget({ creatorId, assigneeIds: assignees.map((a) => a.userId), userId });
  if (target === 'assignee') return assignees.find((a) => a.userId === userId).progress;
  if (target === 'todo') return progress;
  return null;
}

/**
 * 이 사람이 PATCH 본문의 필드들을 고칠 수 있는지 — 못 고치면 `{ status: 403, error }`, 되면 null. progress만은
 * 역할 대신 [target](progressTarget의 결과)으로 본다 — null이면 만든 사람이라도 403.
 */
export function patchDenial(role, creatorId, fieldNames, target = null) {
  const others = fieldNames.filter((f) => f !== 'progress');
  if (others.length > 0) {
    const { canEdit, canManage } = todoPermissions({ role, creatorId });
    if (!canEdit) return { status: 403, error: '이 할 일을 수정할 권한이 없습니다.' };
    if (!canManage && others.some((f) => ASSIGNEE_FORBIDDEN_FIELDS.includes(f))) {
      return { status: 403, error: '담당자는 담당자 목록을 바꿀 수 없습니다.' };
    }
  }
  if (fieldNames.includes('progress') && !target) {
    return { status: 403, error: TODO_PROGRESS_DENIED };
  }
  return null;
}

// ── 진척률·알림 ─────────────────────────────────────────────────────────

/**
 * 진척률이 바뀔 때의 completedAt — 100이 되면 그때(이미 완료였으면 처음 값 유지), 100 아래로 내리면 해제.
 * 할 일(집계)과 담당자 한 사람의 행에 똑같이 쓴다.
 */
export function nextCompletedAt(progress, prevCompletedAt, now = new Date()) {
  if (progress >= 100) return prevCompletedAt ?? now;
  return null;
}

/**
 * 담당자들의 진척률로 전체(집계) 진척률 — 모두 100이면 100, 모두 0이면 0, 그 밖은 평균을 반올림해 1~99로 자른다
 * (한 명이라도 덜 했으면 완료로, 한 명이라도 시작했으면 대기로 보이지 않게). 담당자가 없으면 null — 그때는 만든
 * 사람이 직접 바꾸는 todos.progress를 그대로 둔다.
 */
export function aggregateProgress(progresses) {
  if (progresses.length === 0) return null;
  if (progresses.every((p) => p >= 100)) return 100;
  if (progresses.every((p) => p <= 0)) return 0;
  const average = Math.round(progresses.reduce((sum, p) => sum + p, 0) / progresses.length);
  return Math.min(99, Math.max(1, average));
}

/** 저장된 [todo]의 progress·completedAt을 [progress]로 맞춘 값 — 완료 시각은 nextCompletedAt 규칙, 이미 맞으면 null. */
function resyncTo(todo, progress, now) {
  const completedAt = nextCompletedAt(progress, todo.completedAt ?? null, now);
  const time = (d) => (d ? new Date(d).getTime() : null);
  if (progress === todo.progress && time(completedAt) === time(todo.completedAt)) return null;
  return { progress, completedAt };
}

/**
 * 저장된 전체 진척률([todo]의 progress·completedAt)을 그 방에 아직 있는 담당자들의 진척률([progresses])로 다시 맞춘 값 —
 * 바꿀 것이 있으면 `{ progress, completedAt }`, 담당자가 없거나(만든 사람이 직접 바꾸는 값이라 그대로 둔다) 이미 맞으면 null.
 * 할 일을 고칠 때마다, 그리고 담당자가 방을 나가거나 다시 들어올 때 쓴다(progressResync) — 그래서 방을 나간 담당자는
 * 곧바로 집계에서 빠지고, 다시 들어오면 남아 있던 그 사람의 진척률이 다시 들어간다.
 */
export function aggregateResync(todo, progresses, now = new Date()) {
  const progress = aggregateProgress(progresses);
  if (progress === null) return null;
  return resyncTo(todo, progress, now);
}

/** 진척률을 가장 가까운 단계(0·25·50·75·100)로 — 두 단계의 한가운데(12.5·37.5·62.5·87.5)는 큰 쪽으로(반은 올림). */
export function nearestProgressStep(value) {
  let nearest = TODO_PROGRESS_STEPS[0];
  for (const step of TODO_PROGRESS_STEPS) {
    // 단계가 오름차순이라 거리가 같으면 뒤의 큰 단계가 남는다.
    if (Math.abs(value - step) <= Math.abs(value - nearest)) nearest = step;
  }
  return nearest;
}

/**
 * (그 방에 있는) 담당자가 하나도 남지 않게 된 할 일이 이어받을 진척률(검토 S3) — 이제부터는 담당자 없는 할 일이라 만든
 * 사람이 직접 고르는 값이 되므로, 바로 전까지 만든 사람도 담당자였으면 만든 사람 자신의 진척률, 아니면 직전 집계를 가장
 * 가까운 단계로 맞춘 값(집계 38%처럼 고를 수 없는 값이 남지 않게). [before]는 바로 전에 그 방에 있던 담당자들
 * [{ userId, progress }](한 명 이상).
 */
export function orphanedProgress({ creatorId, before }) {
  const creator = creatorId ? before.find((a) => a.userId === creatorId) : null;
  if (creator) return creator.progress;
  return nearestProgressStep(aggregateProgress(before.map((a) => a.progress)));
}

/**
 * 할 일을 고치거나 방 멤버가 바뀐 뒤, 저장된 전체 진척률([todo]의 progress·completedAt·creatorId)을 다시 맞춘 값 — 바꿀
 * 것이 있으면 `{ progress, completedAt }`, 이미 맞거나 손댈 것이 없으면 null. [after]는 지금 그 방에 있는 담당자들
 * [{ userId, progress }] — 있으면 그들의 집계(aggregateResync). 없으면 만든 사람이 직접 바꾸는 값이라 그대로 두지만, 이번
 * 변경 바로 전([before] — 그때 그 방에 있던 담당자들, 모르면 null)에는 담당자가 있었다면(마지막 담당자가 빠짐)
 * orphanedProgress의 값을 이어받는다. 완료 시각은 어느 쪽이든 nextCompletedAt 규칙.
 */
export function progressResync(todo, { before = null, after }, now = new Date()) {
  if (after.length > 0) return aggregateResync(todo, after.map((a) => a.progress), now);
  if (!before || before.length === 0) return null;
  return resyncTo(todo, orphanedProgress({ creatorId: todo.creatorId, before }), now);
}

/**
 * 담당자 목록 수정의 차이 — removed(빠진 사람: 행 삭제), added(새 사람: 진척률 0으로 추가), kept(남는 사람: 행을
 * 그대로 둬서 진척률 보존). [beforeIds]는 저장된 담당 행 전부(방을 나간 사람 포함), [afterIds]는 새 목록.
 */
export function diffAssignees(beforeIds, afterIds) {
  const before = new Set(beforeIds);
  const after = new Set(afterIds);
  return {
    removed: [...before].filter((id) => !after.has(id)),
    added: [...after].filter((id) => !before.has(id)),
    kept: [...after].filter((id) => before.has(id)),
  };
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

/**
 * 알림이 울릴 사람 — 담당자가 있으면 아직 다 하지 않은(진척률 100 미만) 담당자들, 없으면 만든 사람.
 * [assignees]는 그 방에 아직 있는 담당자 [{ userId, progress }]. 할 일 전체가 완료면 shouldDeliverReminder가 먼저 거른다.
 */
export function reminderTargets(assignees, creatorId) {
  if (assignees.length > 0) return assignees.filter((a) => a.progress < 100).map((a) => a.userId);
  return creatorId ? [creatorId] : [];
}

/** 이 알림을 지금 보내도 되는지 — 이미 완료된 할 일이나 너무 오래 묵은 알림은 보내지 않는다. */
export function shouldDeliverReminder({ progress, remindAt, now = Date.now() }) {
  if (progress >= 100) return false;
  return now - remindAt <= TODO_REMINDER_STALE_MS;
}

// ── 목록 쿼리 ───────────────────────────────────────────────────────────

/** 두 날짜('YYYY-MM-DD') 사이의 날 수(to − from). */
function daysBetween(from, to) {
  const utc = (s) => Date.UTC(Number(s.slice(0, 4)), Number(s.slice(5, 7)) - 1, Number(s.slice(8, 10)));
  return Math.round((utc(to) - utc(from)) / (24 * 60 * 60 * 1000));
}

/**
 * 목록의 기간 조건 검사(달력 보기) — from/to('YYYY-MM-DD')는 둘 다 주거나 둘 다 빼야 하고, from ≤ to, 양 끝을 포함해
 * 최대 100일. 둘 다 없으면 `{ value: null }`, 통과하면 `{ value: { from, to } }`, 아니면 `{ error }`.
 */
export function parseTodoRange(from, to) {
  const given = (v) => v !== undefined && v !== null && v !== '';
  if (!given(from) && !given(to)) return { value: null };
  if (!given(from) || !given(to)) return { error: 'from과 to는 함께 보내야 합니다.' };
  if (!isValidDateString(from) || !isValidDateString(to)) return { error: '기간이 올바르지 않습니다. (YYYY-MM-DD)' };
  if (from > to) return { error: '기간의 시작일은 종료일보다 늦을 수 없습니다.' };
  if (daysBetween(from, to) + 1 > TODO_RANGE_MAX_DAYS) {
    return { error: `기간은 최대 ${TODO_RANGE_MAX_DAYS}일까지 조회할 수 있습니다.` };
  }
  return { value: { from, to } };
}

/**
 * 목록의 "기준 진척률"을 누구 것으로 볼지 — assigneeId가 있으면 그 사람, 없고 나의 할 일(mine)이면 나(담당자가
 * 아닌 할 일은 todos.progress로 대신), 그 밖은 null(집계 todos.progress). 완료 제외와 "완료 여부" 정렬이 이 값을 본다.
 */
export function progressPerspective({ scope, assigneeId, userId }) {
  if (assigneeId) return assigneeId;
  if (scope === 'mine') return userId;
  return null;
}

/**
 * GET /todos 쿼리 검사 — 통과하면 `{ teamId, scope, includeDone, roomId, assigneeId, from, to, sort, limit, offset }`,
 * 아니면 `{ error }`. assigneeId(선택)는 그 사람이 담당자인 것만 — 어떤 scope에도 걸 수 있다. from/to(선택)는 기간이
 * 겹치는 것만(parseTodoRange) — 이때는 limit을 500까지 받는다(없으면 100까지). 정렬이 "즐겨찾기 먼저·미완료 먼저·
 * 마감 임박순·생성순"의 복합 키라 커서 대신 offset으로 이어 받는다(다른 목록의 before와 다른 점).
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
  let assigneeId = null;
  if (query?.assigneeId !== undefined && query.assigneeId !== '') {
    if (!isUuid(query.assigneeId)) return { error: 'assigneeId가 올바르지 않습니다.' };
    assigneeId = query.assigneeId.toLowerCase();
  }
  const range = parseTodoRange(query?.from, query?.to);
  if (range.error) return range;
  let limit = TODO_LIST_DEFAULT_LIMIT;
  if (query?.limit !== undefined && query.limit !== '') {
    const n = Math.floor(Number(query.limit));
    if (!Number.isFinite(n) || n < 1) return { error: 'limit은 1 이상의 숫자여야 합니다.' };
    limit = Math.min(n, range.value ? TODO_RANGE_MAX_LIMIT : TODO_LIST_MAX_LIMIT);
  }
  let offset = 0;
  if (query?.offset !== undefined && query.offset !== '') {
    const n = Math.floor(Number(query.offset));
    if (!Number.isFinite(n) || n < 0) return { error: 'offset은 0 이상의 숫자여야 합니다.' };
    offset = n;
  }
  return {
    teamId,
    scope,
    includeDone,
    roomId,
    assigneeId,
    from: range.value?.from ?? null,
    to: range.value?.to ?? null,
    sort,
    limit,
    offset,
  };
}
