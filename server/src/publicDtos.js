/**
 * 공개 API(/api/v1 — publicApi.js)와 나가는 웹훅·연동 앱의 일(webhookDelivery.js)이 함께 쓰는 **바깥에 보이는 모양**. 앱 API(/api)의
 * DTO는 화면에 맞춰 자주 바뀌므로 바깥에는 이 모양만 주고, 칸을 더할 수는 있어도 있던 칸의 뜻은 바꾸지 않는다. 그림·파일은 내려주지
 * 않는다(서명 링크는 짧게 만료되고 앱 화면 전용이다 — 이름·종류만). DB 없이 시험한다(test/publicDtos.test.js).
 */

const ms = (v) => (v == null ? null : typeof v === 'number' ? v : new Date(v).getTime());

export const publicRoomDto = (r) => ({
  id: r.id,
  teamId: r.teamId,
  type: r.type,
  name: r.name ?? null,
  archived: !!r.archivedAt,
});

/** 메시지 — DB 행이든 앱 DTO든(bot·attachments 칸이 다를 뿐) 같은 모양으로. 지운 메시지는 내용 없이 deleted. */
export function publicMessageDto(m) {
  const deleted = !!(m.deletedAt || m.deleted);
  const botEmoji = m.botEmoji ?? m.bot?.emoji ?? null;
  const integrationId = m.integrationId ?? m.bot?.integrationId ?? null;
  const attachments = Array.isArray(m.attachments) ? m.attachments : [];
  return {
    id: m.id,
    roomId: m.roomId,
    type: m.type,
    senderId: m.senderId ?? null,
    senderName: m.senderName ?? null,
    bot: !!(integrationId || botEmoji) || (m.senderId == null && m.type === 'text'),
    botId: integrationId,
    title: deleted ? null : (m.title ?? null),
    text: deleted ? null : (m.text ?? null),
    // 봇 메시지의 블록(botBlocks.js 저장 모양 — 그림 블록은 내용 대신 alt·title만).
    blocks: deleted ? null : publicBlocks(m.botBlocks ?? m.blocks ?? null),
    fileName: deleted ? null : (m.fileName ?? null),
    files: deleted
      ? []
      : (attachments.length ? attachments : m.fileName ? [m] : []).map((a) => ({
          kind: a.kind ?? (m.type === 'image' ? 'image' : 'file'),
          name: a.fileName ?? null,
          size: a.fileSize ?? null,
          mimeType: a.mimeType ?? null,
        })),
    mentions: deleted ? [] : mentionsOf(m.mentions),
    createdAt: ms(m.createdAt),
    editedAt: ms(m.editedAt),
    deleted,
  };
}

/** 멘션 구간 → 바깥 모양 [{ type: 'user', userId } | { type: 'all' }](글자 자리는 뺀다). */
function mentionsOf(list) {
  if (!Array.isArray(list)) return [];
  return list
    .map((x) => (x?.type === 'all' ? { type: 'all' } : x?.type === 'user' && x.userId ? { type: 'user', userId: x.userId } : null))
    .filter(Boolean);
}

function publicBlocks(blocks) {
  if (!Array.isArray(blocks)) return null;
  return blocks.map((b) => (b.type === 'image' ? { type: 'image', alt: b.alt ?? null, title: b.title ?? null } : b));
}

export function publicCommentDto(c) {
  const deleted = !!(c.deletedAt || c.deleted);
  return {
    id: c.id,
    messageId: c.messageId,
    roomId: c.roomId,
    senderId: c.senderId ?? null,
    senderName: c.senderName ?? null,
    type: c.type,
    text: deleted ? null : (c.text ?? null),
    fileName: deleted ? null : (c.fileName ?? null),
    mentions: deleted ? [] : mentionsOf(c.mentions),
    createdAt: ms(c.createdAt),
    editedAt: ms(c.editedAt),
    deleted,
  };
}

/** 할 일 — 앱 API의 할 일 DTO(todos.js loadTodoDtos)나 DB 행에서. */
export function publicTodoDto(t) {
  return {
    id: t.id,
    teamId: t.teamId,
    roomId: t.roomId,
    title: t.title,
    description: t.description ?? null,
    startDate: t.startDate ?? null,
    startTime: t.startTime ?? null,
    dueDate: t.dueDate ?? null,
    dueTime: t.dueTime ?? null,
    progress: t.progress ?? 0,
    status: t.status ?? null,
    completedAt: ms(t.completedAt),
    creatorId: t.creator?.id ?? t.creatorId ?? null,
    assignees: Array.isArray(t.assignees)
      ? t.assignees.map((a) => ({ id: a.id, name: a.name ?? null, progress: a.progress ?? 0, status: a.status ?? null }))
      : [],
    createdAt: ms(t.createdAt),
    updatedAt: ms(t.updatedAt),
  };
}

export const publicCalendarDto = (c) => ({
  id: c.id,
  teamId: c.teamId,
  kind: c.kind,
  name: c.name,
  color: c.color ?? null,
  role: c.role ?? null,
  canCreateEvents: !!c.canCreateEvents,
});

/** 일정(한 회차) — 앱 API의 회차 DTO(calendars.js toOccurrenceDto)에서. 비공개라 못 보는 일정은 restricted·제목 '비공개 일정'. */
export function publicEventDto(e) {
  return {
    id: e.eventId ?? e.id,
    calendarId: e.calendarId ?? null,
    source: e.source ?? 'event',
    title: e.title,
    description: e.description ?? null,
    location: e.location ?? null,
    start: e.start,
    end: e.end,
    allDay: !!e.allDay,
    visibility: e.visibility ?? null,
    restricted: !!e.restricted,
    recurring: !!e.recurring,
    creatorId: e.creatorId ?? null,
    attendees: Array.isArray(e.attendees)
      ? e.attendees.map((a) => ({ userId: a.userId, name: a.name ?? null, response: a.response ?? null }))
      : [],
    canEdit: !!e.canEdit,
  };
}

/** 할 일·일정 입력 중 공개 API가 받는 칸만(나머지 — 첨부·폴더 경로·알림 등 — 은 앱 화면 전용). */
export const TODO_INPUT_FIELDS = Object.freeze(['title', 'description', 'assigneeIds', 'startDate', 'startTime', 'dueDate', 'dueTime']);
export const TODO_PATCH_FIELDS = Object.freeze([...TODO_INPUT_FIELDS, 'progress']);
export const EVENT_INPUT_FIELDS = Object.freeze(['title', 'description', 'location', 'start', 'end', 'allDay', 'visibility', 'attendeeIds']);

/** [body]에서 [fields]의 칸만 꺼낸다(보내지 않은 칸은 빼서 "그대로 둠"으로). */
export function pickFields(body, fields) {
  const out = {};
  if (!body || typeof body !== 'object') return out;
  for (const f of fields) if (f in body) out[f] = body[f];
  return out;
}
