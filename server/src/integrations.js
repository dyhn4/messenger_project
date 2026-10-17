import crypto from 'node:crypto';
import { Router } from 'express';
import { topicAccess, userAccess } from './access.js';
import { AUDIT, recordAudit } from './audit.js';
import { clientIpKey, limits, retryLater, waitText } from './authGuard.js';
import { decryptField, encryptField, lookupHash } from './crypto.js';
import {
  countActiveApiTokens,
  countRoomWebhooks,
  countTeamCommands,
  deleteIntegration,
  findIntegrationById,
  findTeamCommand,
  findWebhookByTokenHash,
  insertApiToken,
  insertIntegration,
  listApiTokens,
  listRoomWebhooks,
  listTeamCommands,
  markIntegrationUsed,
  revokeApiToken,
  updateIntegration,
} from './db/queries/integrations.js';
import { findRoomById, isRoomMember } from './db/queries/rooms.js';
import { findTeamById, getTeamRole } from './db/queries/teams.js';
import { findUserById } from './db/queries/users.js';
import { isUuid } from './favoritesRules.js';
import {
  API_TOKEN_PREFIX,
  API_TOKENS_PER_USER,
  canManageRoomWebhooks,
  COMMAND_DESCRIPTION_MAX,
  COMMAND_TIMEOUT_MS,
  COMMANDS_PER_TEAM,
  generateSecretToken,
  isSecretToken,
  parseBotEmoji,
  parseBotName,
  parseCommandName,
  parseCommandResponse,
  parseCommandUrl,
  parseExpiry,
  parseScopes,
  roomAcceptsIntegrations,
  signCommandRequest,
  tokenPrefixOf,
  WEBHOOK_TOKEN_PREFIX,
  webhookPayloadToMessage,
  WEBHOOKS_PER_ROOM,
} from './integrationRules.js';
import { clipGraphemes, MESSAGE_TEXT_MAX } from './messageLimits.js';
import { postBotMessage } from './rooms.js';
import { getWebPublicUrl } from './webAddress.js';

/**
 * 외부 연동 — 들어오는 웹훅(바깥 서비스 → 대화방 봇 메시지), 슬래시 명령(대화방의 `/명령` → 바깥 서버 → 봇 메시지), 개인 API 토큰
 * 관리. 규칙은 integrationRules.js, 공개 API(/api/v1)는 publicApi.js.
 *
 * 웹훅 주소는 비밀 토큰이 든 주소 자체가 열쇠라(/hooks/<토큰>) 만들 때 한 번만 보여 주고 열쇠 해시로만 둔다 — 새어 나가면 "주소 새로
 * 만들기"로 바꾼다. 받은 글은 사람 메시지처럼 안읽음·알림이 간다(postBotMessage — 읽기 전용 토픽에도 올릴 수 있어 알림 전용 토픽을
 * 만들기 좋다).
 */

const NOT_FOUND = '연동을 찾을 수 없습니다.';
const ms = (v) => (v ? new Date(v).getTime() : null);

/** 웹훅·명령 한 개 → 화면 모양(비밀값 없이). [withUrl]이면 명령의 보낼 주소도(서버 운영자에게만). */
function integrationDto(row, { withUrl = false } = {}) {
  return {
    id: row.id,
    kind: row.kind,
    teamId: row.teamId,
    roomId: row.roomId ?? null,
    name: row.name,
    emoji: row.emoji ?? null,
    tokenPrefix: row.tokenPrefix ?? null,
    command: row.command ?? null,
    description: row.description ?? null,
    url: withUrl ? (row.url ?? null) : null,
    createdByName: row.createdByName ?? null,
    createdAt: ms(row.createdAt),
    lastUsedAt: ms(row.lastUsedAt),
    useCount: row.useCount ?? 0,
  };
}

/** 웹훅 주소들 — 웹 앱 주소(정식 인증서 — 바깥 서비스가 그대로 믿는다)와 지금 앱이 붙은 주소(사내 — 자체 서명 인증서). */
function webhookUrls(req, token) {
  const path = `/hooks/${token}`;
  const web = getWebPublicUrl();
  return {
    path,
    web: web ? `${web.replace(/\/+$/, '')}${path}` : null,
    direct: `${req.protocol}://${req.get('host')}${path}`,
  };
}

function apiTokenDto(row) {
  return {
    id: row.id,
    name: row.name,
    tokenPrefix: row.tokenPrefix,
    scopes: row.scopes ?? [],
    createdAt: ms(row.createdAt),
    lastUsedAt: ms(row.lastUsedAt),
    expiresAt: ms(row.expiresAt),
  };
}

/** 이름(없으면 아이디) — 감사 로그·명령 요청에. */
const displayName = (u) => u?.name ?? u?.username ?? '알 수 없음';

/**
 * 들어오는 웹훅 받기 — 인증 없는 공개 경로(주소의 토큰이 열쇠). JSON(일반·Slack·Discord 모양), 그냥 글, Slack 옛 방식(form의
 * payload=JSON)을 받는다. 성공하면 `{ ok: true }`.
 */
export async function webhookReceiveHandler(io, req, res) {
  const ipWait = limits.webhookIp.hit(clientIpKey(req));
  if (ipWait > 0) return retryLater(res, ipWait, `요청이 너무 많습니다. ${waitText(ipWait)} 뒤에 다시 보내세요.`);
  const token = req.params.token;
  const hook = isSecretToken(token, WEBHOOK_TOKEN_PREFIX) ? await findWebhookByTokenHash(lookupHash(token)) : null;
  if (!hook) return res.status(404).json({ ok: false, error: '없는 웹훅 주소입니다(지웠거나 새로 만들었을 수 있습니다).' });
  const hookWait = limits.webhookHook.hit(hook.id);
  if (hookWait > 0) return retryLater(res, hookWait, `이 웹훅으로 너무 많이 보냈습니다. ${waitText(hookWait)} 뒤에 다시 보내세요.`);
  let body = req.body;
  if (body && typeof body === 'object' && typeof body.payload === 'string') {
    try {
      body = JSON.parse(body.payload);
    } catch {
      return res.status(400).json({ ok: false, error: 'payload가 올바른 JSON이 아닙니다.' });
    }
  }
  const parsed = webhookPayloadToMessage(body);
  if (parsed.error) return res.status(400).json({ ok: false, error: parsed.error });
  const room = hook.roomId ? await findRoomById(hook.roomId) : null;
  // 보관된 토픽은 읽기만 하는 곳이라 받지 않는다(다시 꺼내면 같은 주소로 다시 받는다).
  if (!room || !roomAcceptsIntegrations(room) || room.archivedAt) {
    return res.status(410).json({ ok: false, error: '이 웹훅의 대화방에 더는 올릴 수 없습니다.' });
  }
  await postBotMessage(io, room, parsed.text, {
    senderName: parsed.username ?? hook.name,
    integrationId: hook.id,
    botEmoji: hook.emoji,
  });
  await markIntegrationUsed(hook.id);
  res.json({ ok: true });
}

export function createIntegrationsRouter(io) {
  const router = Router();

  /** 이 방의 웹훅을 다룰 수 있으면 `{ room }`, 아니면 응답을 보내고 null. */
  async function webhookRoom(req, res, roomId) {
    const room = await findRoomById(roomId);
    if (!room || !(await isRoomMember(room.id, req.user.sub))) {
      res.status(404).json({ error: '방을 찾을 수 없습니다.' });
      return null;
    }
    if (!roomAcceptsIntegrations(room)) {
      res.status(400).json({ error: '웹훅은 토픽(보드 뷰 제외)과 그룹 대화방에만 붙일 수 있습니다.' });
      return null;
    }
    if (!canManageRoomWebhooks(room, await topicAccess(room, req.user.sub))) {
      res.status(403).json({ error: '이 방을 관리할 수 있는 사람만 웹훅을 다룰 수 있습니다.' });
      return null;
    }
    return room;
  }

  /** 서버 운영자인지 — 아니면 403을 보내고 false. */
  async function requireServerAdmin(req, res) {
    const access = await userAccess(req.user.sub);
    if (access.isServerAdmin) return access;
    res.status(403).json({ error: '슬래시 명령은 서버 운영자만 만들고 바꿀 수 있습니다.' });
    return null;
  }

  // ── 들어오는 웹훅 ──

  router.get('/rooms/:roomId/webhooks', async (req, res) => {
    const room = await webhookRoom(req, res, req.params.roomId);
    if (!room) return;
    res.json((await listRoomWebhooks(room.id)).map((r) => integrationDto(r)));
  });

  /** 웹훅 만들기 `{ name, emoji? }` → 주소(토큰은 이번에만). */
  router.post('/rooms/:roomId/webhooks', async (req, res) => {
    const room = await webhookRoom(req, res, req.params.roomId);
    if (!room) return;
    const name = parseBotName(req.body?.name);
    if (name.error) return res.status(400).json({ error: name.error });
    const emoji = parseBotEmoji(req.body?.emoji);
    if (emoji.error) return res.status(400).json({ error: emoji.error });
    if ((await countRoomWebhooks(room.id)) >= WEBHOOKS_PER_ROOM) {
      return res.status(400).json({ error: `한 방에 웹훅은 ${WEBHOOKS_PER_ROOM}개까지입니다.` });
    }
    const user = await findUserById(req.user.sub);
    const token = generateSecretToken(WEBHOOK_TOKEN_PREFIX);
    const row = await insertIntegration({
      kind: 'webhook',
      teamId: room.teamId,
      roomId: room.id,
      name: name.name,
      emoji: emoji.emoji,
      tokenHash: lookupHash(token),
      tokenPrefix: tokenPrefixOf(token),
      createdBy: req.user.sub,
      createdByName: displayName(user),
    });
    recordAudit({
      actorId: req.user.sub,
      actorName: displayName(user),
      action: AUDIT.integrationCreate,
      teamId: room.teamId,
      targetType: 'integration',
      targetId: row.id,
      targetLabel: name.name,
      detail: `웹훅 만들기 — ${room.name ?? '대화방'}`,
    });
    res.status(201).json({ ...integrationDto(row), token, urls: webhookUrls(req, token) });
  });

  // ── 슬래시 명령 ──

  /** 팀의 슬래시 명령 — 팀 멤버면 누구나(입력칸 자동 완성). 보낼 주소는 서버 운영자에게만. */
  router.get('/teams/:teamId/commands', async (req, res) => {
    if (!isUuid(req.params.teamId)) return res.status(404).json({ error: '팀을 찾을 수 없습니다.' });
    const [role, access] = await Promise.all([getTeamRole(req.params.teamId, req.user.sub), userAccess(req.user.sub)]);
    if (role === null && !access.isServerAdmin) return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    const rows = await listTeamCommands(req.params.teamId);
    res.json(rows.map((r) => integrationDto(r, { withUrl: access.isServerAdmin })));
  });

  /** 슬래시 명령 만들기(서버 운영자) `{ command, name, emoji?, description?, url }` → 서명 비밀(이번에만). */
  router.post('/teams/:teamId/commands', async (req, res) => {
    const access = await requireServerAdmin(req, res);
    if (!access) return;
    const team = isUuid(req.params.teamId) ? await findTeamById(req.params.teamId) : null;
    if (!team) return res.status(404).json({ error: '팀을 찾을 수 없습니다.' });
    const command = parseCommandName(req.body?.command);
    if (command.error) return res.status(400).json({ error: command.error });
    const name = parseBotName(req.body?.name ?? command.command);
    if (name.error) return res.status(400).json({ error: name.error });
    const emoji = parseBotEmoji(req.body?.emoji);
    if (emoji.error) return res.status(400).json({ error: emoji.error });
    const url = parseCommandUrl(req.body?.url);
    if (url.error) return res.status(400).json({ error: url.error });
    const description =
      typeof req.body?.description === 'string' ? req.body.description.trim().slice(0, COMMAND_DESCRIPTION_MAX) || null : null;
    if (await findTeamCommand(team.id, command.command)) {
      return res.status(409).json({ error: `/${command.command} 명령이 이미 있습니다.` });
    }
    if ((await countTeamCommands(team.id)) >= COMMANDS_PER_TEAM) {
      return res.status(400).json({ error: `한 팀에 슬래시 명령은 ${COMMANDS_PER_TEAM}개까지입니다.` });
    }
    const secret = crypto.randomBytes(32).toString('hex');
    const row = await insertIntegration({
      kind: 'command',
      teamId: team.id,
      name: name.name,
      emoji: emoji.emoji,
      command: command.command,
      description,
      url: url.url,
      secretEnc: encryptField(secret),
      createdBy: req.user.sub,
      createdByName: displayName(access.user),
    });
    recordAudit({
      actorId: req.user.sub,
      actorName: displayName(access.user),
      action: AUDIT.integrationCreate,
      teamId: team.id,
      targetType: 'integration',
      targetId: row.id,
      targetLabel: `/${command.command}`,
      detail: `슬래시 명령 만들기 — ${url.url}`,
    });
    res.status(201).json({ ...integrationDto(row, { withUrl: true }), secret });
  });

  /**
   * 슬래시 명령 실행 `{ command, text }` — 바깥 서버로 서명한 요청을 보내고(5초까지 기다림), 답이 in_channel이면 봇 메시지로 올리고
   * `{ posted: true }`, 부른 사람에게만 보일 답이면 `{ ephemeral: 글 }`, 할 말이 없으면 `{ ok: true }`.
   */
  router.post('/rooms/:roomId/commands/run', async (req, res) => {
    const room = await findRoomById(req.params.roomId);
    if (!room || !(await isRoomMember(room.id, req.user.sub))) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (!roomAcceptsIntegrations(room) || room.archivedAt) {
      return res.status(400).json({ error: '이 대화방에서는 슬래시 명령을 쓸 수 없습니다.' });
    }
    const command = parseCommandName(req.body?.command);
    if (command.error) return res.status(400).json({ error: command.error });
    const hook = await findTeamCommand(room.teamId, command.command);
    if (!hook) return res.status(404).json({ error: `/${command.command} 명령이 없습니다.` });
    const wait = limits.commandUser.hit(req.user.sub);
    if (wait > 0) return retryLater(res, wait, `명령을 너무 자주 실행했습니다. ${waitText(wait)} 뒤에 다시 하세요.`);
    const text = typeof req.body?.text === 'string' ? req.body.text.slice(0, 2000) : '';
    const user = await findUserById(req.user.sub);
    const team = await findTeamById(room.teamId);
    const timestamp = String(Math.floor(Date.now() / 1000));
    const body = JSON.stringify({
      command: `/${hook.command}`,
      text,
      teamId: room.teamId,
      teamName: team?.name ?? null,
      roomId: room.id,
      roomName: room.name ?? null,
      userId: req.user.sub,
      username: user?.username ?? null,
      userName: displayName(user),
      timestamp: Number(timestamp),
    });
    let response;
    try {
      response = await fetch(hook.url, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'user-agent': 'TangoTalk-Command/1',
          'x-tangotalk-timestamp': timestamp,
          'x-tangotalk-signature': signCommandRequest(decryptField(hook.secretEnc) ?? '', timestamp, body),
        },
        body,
        redirect: 'manual',
        signal: AbortSignal.timeout(COMMAND_TIMEOUT_MS),
      });
    } catch (err) {
      const timedOut = err?.name === 'TimeoutError' || err?.name === 'AbortError';
      return res.status(502).json({
        error: timedOut
          ? `/${hook.command} 명령을 처리하는 서버가 ${COMMAND_TIMEOUT_MS / 1000}초 안에 답하지 않았습니다.`
          : `/${hook.command} 명령을 처리하는 서버에 연결하지 못했습니다.`,
      });
    }
    const reader = response.body?.getReader();
    let bodyText = '';
    if (reader) {
      const decoder = new TextDecoder();
      let size = 0;
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        size += value.length;
        if (size > 64 * 1024) {
          await reader.cancel();
          break;
        }
        bodyText += decoder.decode(value, { stream: true });
      }
    }
    await markIntegrationUsed(hook.id);
    const parsed = parseCommandResponse({
      status: response.status,
      contentType: response.headers.get('content-type') ?? '',
      bodyText,
    });
    if (parsed.error) return res.status(502).json({ error: parsed.error });
    if (parsed.empty) return res.json({ ok: true });
    if (!parsed.inChannel) return res.json({ ephemeral: parsed.text });
    const posted = `${displayName(user)}님이 /${hook.command}${text ? ` ${text}` : ''} 실행\n\n${parsed.text}`;
    await postBotMessage(io, room, clipGraphemes(posted, MESSAGE_TEXT_MAX - 1), {
      senderName: hook.name,
      integrationId: hook.id,
      botEmoji: hook.emoji,
    });
    res.json({ posted: true });
  });

  // ── 공통: 바꾸기·새 비밀·지우기 ──

  /** 이 연동을 다룰 수 있으면 그 행, 아니면 응답을 보내고 null — 웹훅은 그 방 관리자, 명령은 서버 운영자. */
  async function manageable(req, res) {
    const row = isUuid(req.params.id) ? await findIntegrationById(req.params.id) : null;
    if (!row) {
      res.status(404).json({ error: NOT_FOUND });
      return null;
    }
    if (row.kind === 'command') return (await requireServerAdmin(req, res)) ? row : null;
    return (await webhookRoom(req, res, row.roomId)) ? row : null;
  }

  /** 이름·아이콘(명령은 설명·보낼 주소도) 바꾸기. */
  router.patch('/integrations/:id', async (req, res) => {
    const row = await manageable(req, res);
    if (!row) return;
    const patch = {};
    if ('name' in (req.body ?? {})) {
      const name = parseBotName(req.body.name);
      if (name.error) return res.status(400).json({ error: name.error });
      patch.name = name.name;
    }
    if ('emoji' in (req.body ?? {})) {
      const emoji = parseBotEmoji(req.body.emoji);
      if (emoji.error) return res.status(400).json({ error: emoji.error });
      patch.emoji = emoji.emoji;
    }
    if (row.kind === 'command' && 'url' in (req.body ?? {})) {
      const url = parseCommandUrl(req.body.url);
      if (url.error) return res.status(400).json({ error: url.error });
      patch.url = url.url;
    }
    if (row.kind === 'command' && 'description' in (req.body ?? {})) {
      patch.description = typeof req.body.description === 'string' ? req.body.description.trim().slice(0, COMMAND_DESCRIPTION_MAX) || null : null;
    }
    if (Object.keys(patch).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
    res.json(integrationDto(await updateIntegration(row.id, patch), { withUrl: row.kind === 'command' }));
  });

  /** 새 주소(웹훅 토큰)·새 서명 비밀(명령) — 예전 것은 바로 못 쓴다. 새 값은 이번에만 보인다. */
  router.post('/integrations/:id/regenerate', async (req, res) => {
    const row = await manageable(req, res);
    if (!row) return;
    if (row.kind === 'webhook') {
      const token = generateSecretToken(WEBHOOK_TOKEN_PREFIX);
      const updated = await updateIntegration(row.id, { tokenHash: lookupHash(token), tokenPrefix: tokenPrefixOf(token) });
      return res.json({ ...integrationDto(updated), token, urls: webhookUrls(req, token) });
    }
    const secret = crypto.randomBytes(32).toString('hex');
    const updated = await updateIntegration(row.id, { secretEnc: encryptField(secret) });
    res.json({ ...integrationDto(updated, { withUrl: true }), secret });
  });

  router.delete('/integrations/:id', async (req, res) => {
    const row = await manageable(req, res);
    if (!row) return;
    await deleteIntegration(row.id);
    const user = await findUserById(req.user.sub);
    recordAudit({
      actorId: req.user.sub,
      actorName: displayName(user),
      action: AUDIT.integrationDelete,
      teamId: row.teamId,
      targetType: 'integration',
      targetId: row.id,
      targetLabel: row.kind === 'command' ? `/${row.command}` : row.name,
      detail: row.kind === 'command' ? '슬래시 명령 지우기' : '웹훅 지우기',
    });
    res.json({ ok: true });
  });

  // ── 개인 API 토큰 ──

  router.get('/users/me/api-tokens', async (req, res) => {
    res.json((await listApiTokens(req.user.sub)).map(apiTokenDto));
  });

  /** 만들기 `{ name, scopes, expiresInDays? }` → 토큰(이번에만). 정회원 이상. */
  router.post('/users/me/api-tokens', async (req, res) => {
    const access = await userAccess(req.user.sub);
    if (access.role === 'guest') return res.status(403).json({ error: '준회원은 API 토큰을 만들 수 없습니다.' });
    const name = parseBotName(req.body?.name);
    if (name.error) return res.status(400).json({ error: name.error.replace('봇 이름', '토큰 이름') });
    const scopes = parseScopes(req.body?.scopes);
    if (scopes.error) return res.status(400).json({ error: scopes.error });
    const expiry = parseExpiry(req.body?.expiresInDays);
    if (expiry.error) return res.status(400).json({ error: expiry.error });
    if ((await countActiveApiTokens(req.user.sub)) >= API_TOKENS_PER_USER) {
      return res.status(400).json({ error: `API 토큰은 ${API_TOKENS_PER_USER}개까지 만들 수 있습니다.` });
    }
    const token = generateSecretToken(API_TOKEN_PREFIX);
    const row = await insertApiToken({
      userId: req.user.sub,
      name: name.name,
      tokenHash: lookupHash(token),
      tokenPrefix: tokenPrefixOf(token),
      scopes: scopes.scopes,
      expiresAt: expiry.expiresAt,
    });
    res.status(201).json({ ...apiTokenDto(row), token });
  });

  router.delete('/users/me/api-tokens/:id', async (req, res) => {
    if (!isUuid(req.params.id) || !(await revokeApiToken(req.params.id, req.user.sub))) {
      return res.status(404).json({ error: '토큰을 찾을 수 없습니다.' });
    }
    res.json({ ok: true });
  });

  return router;
}
