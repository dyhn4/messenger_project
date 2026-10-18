import { Router } from 'express';
import { accountState } from './authState.js';
import { limits, retryLater, waitText } from './authGuard.js';
import { sanitizeBlocks } from './botBlocks.js';
import { postBotContent, removeBotMessage, updateBotMessage } from './botMessages.js';
import { createCalendarsRouter } from './calendars.js';
import { createCommentsRouter } from './comments.js';
import { lookupHash } from './crypto.js';
import { findCalendarById, findEventById } from './db/queries/calendars.js';
import { listCommentsForMessages } from './db/queries/comments.js';
import {
  findAppByBotTokenHash,
  findGrantById,
  findIntegrationById,
  findUsableApiToken,
  isAppInRoom,
  listAppRoomIds,
  touchApiToken,
  touchGrant,
} from './db/queries/integrations.js';
import { findMessageById, listAttachmentsForMessages, listMessagesByRoom } from './db/queries/messages.js';
import { findRoomById, getDmHistoryFloor, isRoomMember, listRoomsForUser } from './db/queries/rooms.js';
import { findTodoById } from './db/queries/todos.js';
import { findTeamById, isTeamMember, listTeamsForUser } from './db/queries/teams.js';
import { findUserById } from './db/queries/users.js';
import { isUuid } from './favoritesRules.js';
import {
  API_TOKEN_PREFIX,
  BOT_NAME_MAX,
  BOT_TOKEN_PREFIX,
  isSecretToken,
  PAYLOAD_IMAGES_MAX,
  roomAcceptsIntegrations,
  tokenHasScope,
} from './integrationRules.js';
import { internalCall } from './internalCall.js';
import { clipGraphemes, MESSAGE_TEXT_MAX } from './messageLimits.js';
import { createMessagesRouter } from './messages.js';
import { OAUTH_ACCESS_PREFIX } from './oauthRules.js';
import {
  EVENT_INPUT_FIELDS,
  pickFields,
  publicCalendarDto,
  publicCommentDto,
  publicEventDto,
  publicMessageDto,
  publicRoomDto,
  publicTodoDto,
  TODO_INPUT_FIELDS,
  TODO_PATCH_FIELDS,
} from './publicDtos.js';
import { sendUserMessage } from './sendMessage.js';
import { createTodosRouter } from './todos.js';

/**
 * 공개 API(/api/v1) — 스크립트·자동화·연동 앱이 부르는 작은 API. 앱이 쓰는 /api와 따로 두어, 앱 API가 바뀌어도 이 모양(publicDtos.js)은
 * 그대로 지킨다. 토큰은 셋 중 하나(`Authorization: Bearer …`):
 *  - 개인 API 토큰(ttk_ — 내 프로필 → API 토큰): 내 이름으로, 내가 속한 모든 팀
 *  - OAuth 토큰(tto_ — oauth.js, 사람이 연동 앱에 승인): 그 사람 이름으로, 그 앱의 팀 안에서만
 *  - 봇 토큰(ttb_ — 연동 앱): 봇 이름으로, 방 관리자가 그 앱을 추가한 방에서만(사람의 할 일·일정은 없다)
 * 권한: 'read' — GET 전부, 'write' — 메시지 보내기·고치기·지우기, 댓글, 할 일·일정 만들기·고치기·지우기(봇 토큰은 둘 다).
 *
 * 사람 토큰의 쓰기·할 일·일정은 앱 API 라우터를 그 사람으로 안에서 불러(internalCall.js) 앱과 같은 규칙(권한·상한·알림·방송)을 따른다.
 * 비밀 대화는 서버가 내용을 모르므로(종단 간 암호화) 목록에서 빼고 읽기·쓰기도 막는다. 정지·탈퇴한 계정의 토큰과 꺼진 앱의 토큰은 바로 못
 * 쓴다. 토큰마다 1분에 120번.
 *
 * 실시간으로 받기는 나가는 웹훅(방마다)이나 연동 앱의 "받을 일"(앱을 추가한 방마다)로 — webhookDelivery.js.
 */

const BOT_ONLY_PEOPLE = '봇 토큰으로는 할 수 없습니다 — 사람 토큰(개인 API 토큰·OAuth 토큰)으로 부르세요.';

/** 토큰 확인 — 맞으면 req.api = { kind: 'user' | 'bot', userId?, app?, scopes, teamId(이 팀 안에서만 — 개인 토큰은 null) }. */
async function requireApiToken(req, res, next) {
  const header = req.get('authorization') ?? '';
  const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
  const invalid = () => res.status(401).json({ error: '유효하지 않거나 만료된 API 토큰입니다.' });
  let rateKey;
  if (isSecretToken(token, BOT_TOKEN_PREFIX)) {
    const app = await findAppByBotTokenHash(lookupHash(token));
    if (!app) return invalid();
    req.api = { kind: 'bot', app, scopes: ['read', 'write'], teamId: app.teamId };
    rateKey = `bot:${app.id}`;
  } else if (isSecretToken(token, API_TOKEN_PREFIX) || isSecretToken(token, OAUTH_ACCESS_PREFIX)) {
    const row = await findUsableApiToken(lookupHash(token));
    const expectedKind = token.startsWith(API_TOKEN_PREFIX) ? 'personal' : 'oauth';
    if (!row || (row.kind ?? 'personal') !== expectedKind) return invalid();
    if ((await accountState(row.userId)).blocked) return res.status(403).json({ error: '쓸 수 없는 계정입니다.' });
    let teamId = null;
    if (expectedKind === 'oauth') {
      const grant = row.grantId ? await findGrantById(row.grantId) : null;
      const app = grant ? await findIntegrationById(grant.integrationId) : null;
      if (!grant || !app?.enabled) return invalid();
      teamId = app.teamId;
      touchGrant(grant).catch(() => {});
    }
    touchApiToken(row).catch(() => {});
    req.api = { kind: 'user', userId: row.userId, scopes: row.scopes ?? [], teamId };
    rateKey = row.id;
  } else {
    return invalid();
  }
  const wait = limits.apiToken.hit(rateKey);
  if (wait > 0) return retryLater(res, wait, `요청이 너무 많습니다. ${waitText(wait)} 뒤에 다시 하세요.`);
  next();
}

const requireScope = (scope) => (req, res, next) =>
  tokenHasScope(req.api.scopes, scope) ? next() : res.status(403).json({ error: `이 토큰에는 '${scope}' 권한이 없습니다.` });

/** 사람 토큰만 — 봇 토큰이면 403. */
const peopleOnly = (req, res, next) => (req.api.kind === 'user' ? next() : res.status(403).json({ error: BOT_ONLY_PEOPLE }));

/** 이 토큰이 [teamId]를 볼 수 있는지 — 봇·OAuth는 그 팀만, 사람은 멤버인 팀. */
async function canSeeTeam(api, teamId) {
  if (api.teamId && api.teamId !== teamId) return false;
  return api.kind === 'bot' ? true : isTeamMember(teamId, api.userId);
}

/** 이 토큰이 [room]을 볼 수 있는지 — 비밀 대화는 안 되고, 봇은 추가된 방만, 사람은 멤버인 방(OAuth는 그 팀 안에서만). */
async function canSeeRoom(api, room) {
  if (!room || room.isSecret) return false;
  if (api.teamId && api.teamId !== room.teamId) return false;
  if (api.kind === 'bot') return roomAcceptsIntegrations(room) && (await isAppInRoom(api.app.id, room.id));
  return isRoomMember(room.id, api.userId);
}

/** 볼 수 있는 방 — 아니면 404를 보내고 null. */
async function apiRoom(req, res, roomId) {
  const room = typeof roomId === 'string' ? await findRoomById(roomId) : null;
  if (!(await canSeeRoom(req.api, room))) {
    res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    return null;
  }
  return room;
}

/** 볼 수 있는 메시지와 그 방 — 아니면 404. 1:1 "기록 지우고 나가기" 전의 글은 없는 것으로. */
async function apiMessage(req, res) {
  const message = isUuid(req.params.id) ? await findMessageById(req.params.id) : null;
  const room = message ? await findRoomById(message.roomId) : null;
  const notFound = () => {
    res.status(404).json({ error: '메시지를 찾을 수 없습니다.' });
    return null;
  };
  if (!message || !(await canSeeRoom(req.api, room))) return notFound();
  if (req.api.kind === 'user' && room.type === 'dm') {
    const floor = await getDmHistoryFloor(room.id, req.api.userId);
    if (floor && message.createdAt < floor) return notFound();
  }
  return { message, room };
}

/** 앱 API 응답을 그대로 돌려줄 때 — 2xx면 [map]으로 바꿔서, 아니면 그 오류 그대로. */
function relay(res, result, map = (b) => b, okStatus = null) {
  if (result.status >= 200 && result.status < 300) return res.status(okStatus ?? result.status).json(map(result.body));
  return res.status(result.status).json(result.body && typeof result.body === 'object' ? { error: result.body.error ?? '요청을 처리하지 못했습니다.' } : { error: '요청을 처리하지 못했습니다.' });
}

/** 봇이 보낼 내용 `{ text?, blocks?, imageUrls?, username? }` → `{ content, senderName }` | `{ error }`. */
function botContentOf(body) {
  const text = typeof body?.text === 'string' ? clipGraphemes(body.text.trim(), MESSAGE_TEXT_MAX - 1) : '';
  const blocks = body?.blocks === undefined ? null : sanitizeBlocks(body.blocks);
  const imageUrls = (Array.isArray(body?.imageUrls) ? body.imageUrls : [])
    .filter((u) => typeof u === 'string' && /^https?:\/\//i.test(u) && u.length <= 2000)
    .slice(0, PAYLOAD_IMAGES_MAX);
  if (!text && !blocks && imageUrls.length === 0) return { error: 'text나 blocks에 보낼 내용을 넣으세요.' };
  const username = typeof body?.username === 'string' ? clipGraphemes(body.username.replace(/[\u0000-\u001f\u007f]/g, '').trim(), BOT_NAME_MAX) : '';
  return { content: { text, blocks, imageUrls }, senderName: username || null };
}

export function createPublicApiRouter(io) {
  const router = Router();
  // 사람 토큰의 쓰기·할 일·일정은 앱과 같은 라우터를 안에서 부른다(internalCall.js) — 한 번만 만든다.
  const internal = {
    messages: createMessagesRouter(io),
    comments: createCommentsRouter(io),
    todos: createTodosRouter(io),
    calendars: createCalendarsRouter(io),
  };
  const call = (req, routerName, method, path, { body, query } = {}) =>
    internalCall(internal[routerName], { from: req, userId: req.api.userId, method, path, body, query });

  router.use(requireApiToken);

  // ── 나·팀·방 ──

  router.get('/me', requireScope('read'), async (req, res) => {
    if (req.api.kind === 'bot') {
      const { app } = req.api;
      return res.json({ id: app.id, bot: true, name: app.name, emoji: app.emoji ?? null, teamId: app.teamId });
    }
    const user = await findUserById(req.api.userId);
    res.json({ id: user.id, bot: false, username: user.username, name: user.name ?? null, email: user.email ?? null, teamId: req.api.teamId });
  });

  router.get('/teams', requireScope('read'), async (req, res) => {
    if (req.api.kind === 'bot') {
      const team = await findTeamById(req.api.teamId);
      return res.json(team ? [{ id: team.id, name: team.name }] : []);
    }
    const rows = await listTeamsForUser(req.api.userId);
    res.json(rows.filter(({ team }) => !req.api.teamId || team.id === req.api.teamId).map(({ team }) => ({ id: team.id, name: team.name })));
  });

  /** 내(봇은 추가된) 대화방 — teamId 필수(팀마다 방이 따로다). */
  router.get('/rooms', requireScope('read'), async (req, res) => {
    const teamId = typeof req.query.teamId === 'string' ? req.query.teamId : '';
    if (!isUuid(teamId) || !(await canSeeTeam(req.api, teamId))) {
      return res.status(400).json({ error: 'teamId에 내가 속한 팀의 id를 넣으세요(GET /api/v1/teams).' });
    }
    if (req.api.kind === 'bot') {
      const rooms = (await Promise.all((await listAppRoomIds(req.api.app.id)).map((id) => findRoomById(id)))).filter(
        (r) => r && r.teamId === teamId && !r.isSecret,
      );
      return res.json(rooms.map(publicRoomDto));
    }
    const rows = await listRoomsForUser(req.api.userId, teamId);
    res.json(rows.filter((r) => !r.isSecret).map(publicRoomDto));
  });

  // ── 메시지 ──

  /** 메시지 — 최신부터 limit개(최대 100), before(epoch ms)로 더 오래된 쪽을 넘긴다. 결과는 오래된 것부터. */
  router.get('/rooms/:id/messages', requireScope('read'), async (req, res) => {
    const room = await apiRoom(req, res, req.params.id);
    if (!room) return;
    const limit = Math.min(Math.max(Number(req.query.limit) || 50, 1), 100);
    const beforeMs = Number(req.query.before);
    const before = Number.isFinite(beforeMs) && beforeMs > 0 ? new Date(beforeMs) : undefined;
    const floor = req.api.kind === 'user' && room.type === 'dm' ? await getDmHistoryFloor(room.id, req.api.userId) : null;
    const rows = await listMessagesByRoom(room.id, limit, before, floor);
    const attachments = await listAttachmentsForMessages(rows.map((r) => r.id));
    res.json(rows.map((m) => publicMessageDto({ ...m, attachments: attachments[m.id] })));
  });

  /**
   * 메시지 보내기 — 사람 토큰은 `{ text }`(내 이름으로, 사람이 보낸 것과 똑같이 — 안읽음·알림·멘션), 봇 토큰은
   * `{ text?, blocks?, imageUrls?, username? }`(봇 이름으로 — 블록의 단추·선택지를 누르면 앱의 응답 주소로 온다).
   */
  router.post('/rooms/:id/messages', requireScope('write'), async (req, res) => {
    const room = await apiRoom(req, res, req.params.id);
    if (!room) return;
    if (req.api.kind === 'bot') {
      if (room.archivedAt) return res.status(400).json({ error: '보관된 토픽에는 올릴 수 없습니다.' });
      const parsed = botContentOf(req.body);
      if (parsed.error) return res.status(400).json({ error: parsed.error });
      const dto = await postBotContent(io, room, req.api.app, parsed.content, { senderName: parsed.senderName });
      return res.status(201).json({ id: dto.id, createdAt: dto.createdAt });
    }
    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    if (!text) return res.status(400).json({ error: 'text에 보낼 글을 넣으세요.' });
    const result = await sendUserMessage({ io, senderId: req.api.userId, room, payload: { roomId: room.id, type: 'text', text } });
    if (!result.ok) return res.status(result.status ?? 400).json({ error: result.error });
    res.status(201).json({ id: result.message.id, createdAt: result.message.createdAt });
  });

  router.get('/messages/:id', requireScope('read'), async (req, res) => {
    const found = await apiMessage(req, res);
    if (!found) return;
    const attachments = await listAttachmentsForMessages([found.message.id]);
    res.json(publicMessageDto({ ...found.message, attachments: attachments[found.message.id] }));
  });

  /** 고치기 — 사람은 `{ text }`(내 메시지 — 앱과 같은 규칙), 봇은 `{ text?, blocks? }`(그 봇이 올린 메시지만, blocks: null이면 블록 빼기). */
  router.patch('/messages/:id', requireScope('write'), async (req, res) => {
    const found = await apiMessage(req, res);
    if (!found) return;
    const { message, room } = found;
    if (req.api.kind === 'bot') {
      if (message.integrationId !== req.api.app.id || message.deletedAt) {
        return res.status(403).json({ error: '이 봇이 올린 메시지만 고칠 수 있습니다.' });
      }
      const content = {};
      if (typeof req.body?.text === 'string') content.text = req.body.text.trim();
      if (req.body?.blocks !== undefined) content.blocks = req.body.blocks === null ? null : sanitizeBlocks(req.body.blocks);
      if (Object.keys(content).length === 0) return res.status(400).json({ error: 'text나 blocks를 넣으세요.' });
      const dto = await updateBotMessage(io, message, content, { room, sourceIntegrationId: req.api.app.id });
      return res.json(publicMessageDto(dto));
    }
    const result = await call(req, 'messages', 'PATCH', `/messages/${message.id}`, { body: { text: req.body?.text } });
    relay(res, result, publicMessageDto);
  });

  router.delete('/messages/:id', requireScope('write'), async (req, res) => {
    const found = await apiMessage(req, res);
    if (!found) return;
    const { message, room } = found;
    if (req.api.kind === 'bot') {
      if (message.integrationId !== req.api.app.id) return res.status(403).json({ error: '이 봇이 올린 메시지만 지울 수 있습니다.' });
      if (!message.deletedAt) await removeBotMessage(io, message, { room, sourceIntegrationId: req.api.app.id });
      return res.json({ ok: true });
    }
    relay(res, await call(req, 'messages', 'DELETE', `/messages/${message.id}`));
  });

  // ── 댓글 ──

  router.get('/messages/:id/comments', requireScope('read'), async (req, res) => {
    const found = await apiMessage(req, res);
    if (!found) return;
    const rows = await listCommentsForMessages([found.message.id]);
    res.json(rows.map(publicCommentDto));
  });

  /** 댓글 달기 `{ text }` — 사람 토큰만(내 이름으로 — 멘션 알림 등 앱과 같다). */
  router.post('/messages/:id/comments', requireScope('write'), peopleOnly, async (req, res) => {
    const found = await apiMessage(req, res);
    if (!found) return;
    const result = await call(req, 'comments', 'POST', `/messages/${found.message.id}/comments`, { body: { text: req.body?.text } });
    relay(res, result, publicCommentDto);
  });

  // ── 할 일(사람 토큰만) ──

  /** 할 일 목록 — teamId 필수, scope(mine|assigned|all…)·roomId·includeDone·from·to·limit·offset은 앱과 같다. */
  router.get('/todos', requireScope('read'), peopleOnly, async (req, res) => {
    const teamId = typeof req.query.teamId === 'string' ? req.query.teamId : '';
    if (!isUuid(teamId) || !(await canSeeTeam(req.api, teamId))) return res.status(400).json({ error: 'teamId에 내가 속한 팀의 id를 넣으세요.' });
    const query = pickFields(req.query, ['teamId', 'scope', 'roomId', 'assigneeId', 'includeDone', 'from', 'to', 'limit', 'offset', 'q', 'sort']);
    const result = await call(req, 'todos', 'GET', '/todos', { query });
    relay(res, result, (b) => ({ items: (b.items ?? []).map(publicTodoDto), hasMore: !!b.hasMore, total: b.total ?? null }));
  });

  /** 할 일 만들기 `{ title, description?, assigneeIds?, startDate?, startTime?, dueDate?, dueTime?, announce? }` — 방에 할 일 카드도 올린다. */
  router.post('/rooms/:id/todos', requireScope('write'), peopleOnly, async (req, res) => {
    const room = await apiRoom(req, res, req.params.id);
    if (!room) return;
    const body = { ...pickFields(req.body, TODO_INPUT_FIELDS), ...(req.body?.announce === false ? { announce: false } : {}) };
    relay(res, await call(req, 'todos', 'POST', `/rooms/${room.id}/todos`, { body }), publicTodoDto);
  });

  /** 볼 수 있는 할 일인지(OAuth는 그 팀만) — 아니면 404. 방 멤버 확인은 앱 라우터가 한다. */
  async function apiTodo(req, res) {
    const todo = isUuid(req.params.id) ? await findTodoById(req.params.id) : null;
    if (!todo || (req.api.teamId && req.api.teamId !== todo.teamId)) {
      res.status(404).json({ error: '할 일을 찾을 수 없습니다.' });
      return null;
    }
    return todo;
  }

  router.get('/todos/:id', requireScope('read'), peopleOnly, async (req, res) => {
    const todo = await apiTodo(req, res);
    if (!todo) return;
    relay(res, await call(req, 'todos', 'GET', `/todos/${todo.id}`), publicTodoDto);
  });

  /** 할 일 고치기 — 제목·설명·기간·담당자, progress(내 진척률 0~100 — 100이면 완료). */
  router.patch('/todos/:id', requireScope('write'), peopleOnly, async (req, res) => {
    const todo = await apiTodo(req, res);
    if (!todo) return;
    relay(res, await call(req, 'todos', 'PATCH', `/todos/${todo.id}`, { body: pickFields(req.body, TODO_PATCH_FIELDS) }), publicTodoDto);
  });

  router.delete('/todos/:id', requireScope('write'), peopleOnly, async (req, res) => {
    const todo = await apiTodo(req, res);
    if (!todo) return;
    relay(res, await call(req, 'todos', 'DELETE', `/todos/${todo.id}`));
  });

  // ── 일정(사람 토큰만) ──

  /** 내가 볼 수 있는 캘린더(기본·팀·공유·구독) — teamId 필수. */
  router.get('/calendars', requireScope('read'), peopleOnly, async (req, res) => {
    const teamId = typeof req.query.teamId === 'string' ? req.query.teamId : '';
    if (!isUuid(teamId) || !(await canSeeTeam(req.api, teamId))) return res.status(400).json({ error: 'teamId에 내가 속한 팀의 id를 넣으세요.' });
    const result = await call(req, 'calendars', 'GET', `/teams/${teamId}/calendars`);
    relay(res, result, (b) => [...(b.mine ?? []), ...(b.subscribed ?? [])].map(publicCalendarDto));
  });

  /** 일정(회차) — teamId·from·to(epoch ms, 62일까지) 필수. 반복 일정은 회차마다 한 줄. */
  router.get('/events', requireScope('read'), peopleOnly, async (req, res) => {
    const teamId = typeof req.query.teamId === 'string' ? req.query.teamId : '';
    if (!isUuid(teamId) || !(await canSeeTeam(req.api, teamId))) return res.status(400).json({ error: 'teamId에 내가 속한 팀의 id를 넣으세요.' });
    const result = await call(req, 'calendars', 'GET', `/teams/${teamId}/calendar/events`, { query: pickFields(req.query, ['from', 'to']) });
    relay(res, result, (b) => (Array.isArray(b) ? b.map(publicEventDto) : []));
  });

  /** 볼 수 있는 캘린더인지(OAuth는 그 팀만) — 권한은 앱 라우터가 본다. */
  async function apiCalendarTeamOk(req, res, calendarId) {
    const calendar = isUuid(calendarId) ? await findCalendarById(calendarId) : null;
    if (!calendar || (req.api.teamId && req.api.teamId !== calendar.teamId)) {
      res.status(404).json({ error: '캘린더를 찾을 수 없습니다.' });
      return null;
    }
    return calendar;
  }

  async function apiEvent(req, res) {
    const event = isUuid(req.params.id) ? await findEventById(req.params.id) : null;
    if (!event || !(await apiCalendarTeamOk(req, res, event.calendarId))) {
      if (!res.headersSent) res.status(404).json({ error: '일정을 찾을 수 없습니다.' });
      return null;
    }
    return event;
  }

  /** 일정 만들기 `{ title, start, end, allDay?, description?, location?, visibility?, attendeeIds? }`(start·end는 epoch ms). */
  router.post('/calendars/:id/events', requireScope('write'), peopleOnly, async (req, res) => {
    const calendar = await apiCalendarTeamOk(req, res, req.params.id);
    if (!calendar) return;
    relay(res, await call(req, 'calendars', 'POST', `/calendars/${calendar.id}/events`, { body: pickFields(req.body, EVENT_INPUT_FIELDS) }), publicEventDto);
  });

  router.get('/events/:id', requireScope('read'), peopleOnly, async (req, res) => {
    const event = await apiEvent(req, res);
    if (!event) return;
    relay(res, await call(req, 'calendars', 'GET', `/events/${event.id}`), publicEventDto);
  });

  /** 일정 고치기 — 반복 일정은 scope('this'|'following'|'all')·occurrenceStart(그 회차의 시작 ms)도. */
  router.patch('/events/:id', requireScope('write'), peopleOnly, async (req, res) => {
    const event = await apiEvent(req, res);
    if (!event) return;
    const body = { scope: 'all', ...pickFields(req.body, [...EVENT_INPUT_FIELDS, 'scope', 'occurrenceStart']) };
    relay(res, await call(req, 'calendars', 'PATCH', `/events/${event.id}`, { body }), publicEventDto);
  });

  /** 일정 지우기 — 반복 일정은 ?scope=&occurrenceStart=. */
  router.delete('/events/:id', requireScope('write'), peopleOnly, async (req, res) => {
    const event = await apiEvent(req, res);
    if (!event) return;
    relay(res, await call(req, 'calendars', 'DELETE', `/events/${event.id}`, { query: pickFields(req.query, ['scope', 'occurrenceStart']) }));
  });

  router.use((req, res) => res.status(404).json({ error: '없는 API입니다.' }));
  return router;
}

