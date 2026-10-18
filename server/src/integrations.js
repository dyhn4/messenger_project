import crypto from 'node:crypto';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { Router } from 'express';
import multer from 'multer';
import { topicAccess, userAccess } from './access.js';
import { AUDIT, recordAudit } from './audit.js';
import { clientIpKey, limits, retryLater, waitText } from './authGuard.js';
import { findBlockAction } from './botBlocks.js';
import { attachmentsFromUploads, discardUploads, postBotContent, removeBotMessage, updateBotMessage } from './botMessages.js';
import { decryptField, encryptField, lookupHash } from './crypto.js';
import {
  addAppToRoom,
  countActiveApiTokens,
  countRoomOutgoingWebhooks,
  countRoomWebhooks,
  countTeamApps,
  countTeamCommands,
  deleteIntegration,
  findIntegrationById,
  findTeamCommand,
  findWebhookByTokenHash,
  insertApiToken,
  insertIntegration,
  listApiTokens,
  listRecentDeliveries,
  listRoomApps,
  listRoomOutgoingWebhooks,
  listRoomWebhooks,
  listTeamApps,
  listTeamCommands,
  markIntegrationUsed,
  removeAppFromRoom,
  revokeApiToken,
  updateIntegration,
} from './db/queries/integrations.js';
import { findMessageById } from './db/queries/messages.js';
import { findRoomById, isRoomMember } from './db/queries/rooms.js';
import { findTeamById, getTeamRole } from './db/queries/teams.js';
import { findUserById } from './db/queries/users.js';
import { isUuid } from './favoritesRules.js';
import {
  API_TOKEN_PREFIX,
  API_TOKENS_PER_USER,
  APPS_PER_TEAM,
  BOT_TOKEN_PREFIX,
  canManageRoomWebhooks,
  COMMAND_DESCRIPTION_MAX,
  COMMAND_TIMEOUT_MS,
  COMMANDS_PER_TEAM,
  generateSecretToken,
  integrationKindLabel,
  interactionUrlOf,
  isSecretToken,
  mayReachPrivate,
  OUTGOING_PER_ROOM,
  parseBotEmoji,
  parseBotName,
  parseCommandName,
  parseCommandResponse,
  parseCommandUrl,
  parseEvents,
  parseExpiry,
  parseInteractionResponse,
  parseScopes,
  roomAcceptsIntegrations,
  tokenPrefixOf,
  WEBHOOK_TOKEN_PREFIX,
  webhookPayloadToMessage,
  WEBHOOKS_PER_ROOM,
} from './integrationRules.js';
import { checkPublicUrl } from './linkPreview.js';
import { clipGraphemes, MESSAGE_TEXT_MAX } from './messageLimits.js';
import { CLIENT_ID_PREFIX, CLIENT_SECRET_PREFIX, parseRedirectUris } from './oauthRules.js';
import { signedPost } from './outbound.js';
import { postSystemMessage } from './rooms.js';
import { UPLOAD_FILENAME_CHARSET, uploadsDir, uploadsDirHasRoom } from './upload.js';
import { getWebPublicUrl } from './webAddress.js';
import { sendTestDelivery } from './webhookDelivery.js';

/**
 * 외부 연동 — 들어오는 웹훅(바깥 서비스 → 대화방 봇 메시지, 그림·파일 포함), 나가는 웹훅(방의 일 → 바깥 주소, webhookDelivery.js),
 * 슬래시 명령(대화방의 `/명령` → 바깥 서버 → 봇 메시지), 연동 앱(봇 전용 계정 + OAuth 앱 — 서버 운영자가 만들고 방 관리자가 방에 추가),
 * 봇 메시지의 단추·선택지 누르기, 개인 API 토큰 관리. 규칙은 integrationRules.js·botBlocks.js·oauthRules.js, 공개 API(/api/v1)는
 * publicApi.js, OAuth 흐름은 oauth.js.
 *
 * 웹훅 주소는 비밀 토큰이 든 주소 자체가 열쇠라(/hooks/<토큰>) 만들 때 한 번만 보여 주고 열쇠 해시로만 둔다 — 새어 나가면 "주소 새로
 * 만들기"로 바꾼다. 받은 글은 사람 메시지처럼 안읽음·알림이 간다(postBotMessage — 읽기 전용 토픽에도 올릴 수 있어 알림 전용 토픽을
 * 만들기 좋다).
 *
 * 서버가 바깥 주소로 요청을 보내는 일(명령·단추 누름·나가는 웹훅)은 사내망을 찌르는 데 쓰일 수 있어서, 서버 운영자가 아닌 사람(방 관리자)이
 * 정하는 주소는 공인 주소만 받고 보낼 때도 공인 주소로만 보낸다(outbound.js — 운영자가 정한 주소만 사내 주소 가능).
 */

const NOT_FOUND = '연동을 찾을 수 없습니다.';
const ms = (v) => (v ? new Date(v).getTime() : null);
const newSigningSecret = () => crypto.randomBytes(32).toString('hex');

/**
 * 연동 한 개 → 화면 모양(비밀값 없이). [withUrl]이면 보낼 주소들(명령·나가는 웹훅의 주소, 단추 응답 주소, OAuth 앱 id·돌아갈 주소)도 —
 * 그 연동을 다룰 수 있는 사람에게만.
 */
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
    interactionUrl: withUrl ? (row.interactionUrl ?? null) : null,
    events: Array.isArray(row.events) ? row.events : [],
    enabled: row.enabled !== false,
    failureCount: row.failureCount ?? 0,
    hasSigningSecret: !!row.secretEnc,
    clientId: withUrl ? (row.clientId ?? null) : null,
    redirectUris: withUrl && Array.isArray(row.redirectUris) ? row.redirectUris : [],
    createdByName: row.createdByName ?? null,
    createdAt: ms(row.createdAt),
    lastUsedAt: ms(row.lastUsedAt),
    useCount: row.useCount ?? 0,
  };
}

/** 팀 멤버에게 보이는 앱(방에 추가할 앱 고르기·방에 있는 앱) — 이름·아이콘·설명만. */
const appPublicDto = (row) => ({ id: row.id, name: row.name, emoji: row.emoji ?? null, description: row.description ?? null });

const deliveryDto = (d) => ({
  id: d.id,
  event: d.event,
  status: d.status,
  attempts: d.attempts,
  lastStatus: d.lastStatus ?? null,
  lastError: d.lastError ?? null,
  createdAt: ms(d.createdAt),
  deliveredAt: ms(d.deliveredAt),
  nextAttemptAt: d.status === 'pending' ? ms(d.nextAttemptAt) : null,
});

/** 웹훅 주소들 — 웹 앱 주소(정식 인증서 — 바깥 서비스가 그대로 믿는다)와 지금 앱이 붙은 주소(사내 — 자체 서명 인증서). */
function webhookUrls(req, token) {
  const p = `/hooks/${token}`;
  const web = getWebPublicUrl();
  return {
    path: p,
    web: web ? `${web.replace(/\/+$/, '')}${p}` : null,
    direct: `${req.protocol}://${req.get('host')}${p}`,
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

/** 비울 수 있는 주소 칸 — null·빈 글이면 `{ url: null }`, 아니면 parseCommandUrl. */
function parseOptionalUrl(value) {
  if (value === null || value === undefined || (typeof value === 'string' && !value.trim())) return { url: null };
  return parseCommandUrl(value);
}

/**
 * 보낼 주소들의 사내 주소 허용 — 서버 운영자가 정하면 사내 주소도 되고(true), 아니면 이 연동의 주소가 모두 공인 주소여야 한다(false —
 * 아니면 `{ error }`). [urls]는 바꾼 뒤의 주소들(null은 뺀다).
 */
async function urlPolicy(urls, access) {
  if (access.isServerAdmin) return { allowPrivate: true };
  for (const u of urls.filter(Boolean)) {
    const check = await checkPublicUrl(u);
    if (!check.ok) return { error: check.error };
  }
  return { allowPrivate: false };
}

// ── 들어오는 웹훅 받기 ──────────────────────────────────────────────────

/** 웹훅으로 함께 올리는 파일 — 10개까지, 하나에 50MB(넘으면 413). 받은 파일은 업로드 폴더에 새 이름으로. */
export const WEBHOOK_FILE_MAX_BYTES = 50 * 1024 * 1024;
export const WEBHOOK_FILES_MAX = 10;
const webhookUpload = multer({
  storage: multer.diskStorage({
    destination: uploadsDir,
    filename: (req, file, cb) => cb(null, `${randomUUID()}${path.extname(file.originalname).slice(0, 16)}`),
  }),
  defParamCharset: UPLOAD_FILENAME_CHARSET,
  limits: { fileSize: WEBHOOK_FILE_MAX_BYTES, files: WEBHOOK_FILES_MAX, fields: 20, fieldSize: 100 * 1024 },
});

/**
 * 들어오는 웹훅 받기(POST /hooks/:token) — 인증 없는 공개 경로(주소의 토큰이 열쇠). 받는 모양:
 *  - JSON(일반·Slack·Discord 모양 — 블록의 단추·선택지·그림도), 그냥 글, Slack 옛 방식(form의 payload=JSON)
 *  - multipart/form-data: 파일(아무 이름의 칸, 10개까지)과 `payload`·`payload_json`(JSON 글 — Discord와 같다) 또는 `text`·`content`·
 *    `username` 칸 — 그림·로그 파일을 같이 올리기(그림만이면 그림 메시지)
 * 본문의 image_url(Slack 첨부·Discord embed의 그림 포함)과 그림 블록은 서버가 받아 그림으로 붙인다(공인 주소만 — 사내 그림은 파일로 올리세요).
 * 토큰·횟수·방은 파일을 받기 전에 본다(틀린 주소로는 파일이 쌓이지 않는다). 성공하면 `{ ok: true, messageId }`.
 * index.js가 [express.text·urlencoded, ...이것]으로 건다.
 */
export function webhookReceiveRoute(io) {
  async function check(req, res, next) {
    const ipWait = limits.webhookIp.hit(clientIpKey(req));
    if (ipWait > 0) return retryLater(res, ipWait, `요청이 너무 많습니다. ${waitText(ipWait)} 뒤에 다시 보내세요.`);
    const token = req.params.token;
    const hook = isSecretToken(token, WEBHOOK_TOKEN_PREFIX) ? await findWebhookByTokenHash(lookupHash(token)) : null;
    if (!hook) return res.status(404).json({ ok: false, error: '없는 웹훅 주소입니다(지웠거나 새로 만들었을 수 있습니다).' });
    const hookWait = limits.webhookHook.hit(hook.id);
    if (hookWait > 0) return retryLater(res, hookWait, `이 웹훅으로 너무 많이 보냈습니다. ${waitText(hookWait)} 뒤에 다시 보내세요.`);
    const room = hook.roomId ? await findRoomById(hook.roomId) : null;
    // 보관된 토픽은 읽기만 하는 곳이라 받지 않는다(다시 꺼내면 같은 주소로 다시 받는다).
    if (!room || !roomAcceptsIntegrations(room) || room.archivedAt) {
      return res.status(410).json({ ok: false, error: '이 웹훅의 대화방에 더는 올릴 수 없습니다.' });
    }
    if (req.is('multipart/form-data') && !(await uploadsDirHasRoom(Number(req.headers['content-length']) || 0))) {
      return res.status(507).json({ ok: false, error: '서버 저장 공간이 부족합니다.' });
    }
    req.webhook = { hook, room };
    next();
  }

  function files(req, res, next) {
    if (!req.is('multipart/form-data')) return next();
    webhookUpload.any()(req, res, (err) => {
      if (!err) return next();
      discardUploads(req.files).catch(() => {});
      if (err instanceof multer.MulterError) {
        return res.status(err.code === 'LIMIT_FILE_SIZE' ? 413 : 400).json({
          ok: false,
          error:
            err.code === 'LIMIT_FILE_SIZE'
              ? `파일 하나는 ${WEBHOOK_FILE_MAX_BYTES / 1024 / 1024}MB까지입니다.`
              : err.code === 'LIMIT_FILE_COUNT'
                ? `파일은 ${WEBHOOK_FILES_MAX}개까지 올릴 수 있습니다.`
                : '올린 내용의 모양이 올바르지 않습니다.',
        });
      }
      next(err);
    });
  }

  async function receive(req, res) {
    const { hook, room } = req.webhook;
    const uploaded = Array.isArray(req.files) ? req.files : [];
    const fail = async (status, error) => {
      await discardUploads(uploaded);
      return res.status(status).json({ ok: false, error });
    };
    let body = req.body;
    const embedded = body && typeof body === 'object' ? (body.payload ?? body.payload_json) : undefined;
    if (typeof embedded === 'string') {
      try {
        body = JSON.parse(embedded);
      } catch {
        return fail(400, 'payload가 올바른 JSON이 아닙니다.');
      }
    }
    const parsed = webhookPayloadToMessage(body, { allowEmpty: uploaded.length > 0 });
    if (parsed.error) return fail(400, parsed.error);
    let attachments = [];
    try {
      attachments = await attachmentsFromUploads(uploaded);
    } catch (err) {
      console.error('[webhooks] 받은 파일을 저장하지 못했습니다:', err?.message ?? err);
      return res.status(500).json({ ok: false, error: '파일을 저장하지 못했습니다. 다시 보내세요.' });
    }
    const dto = await postBotContent(
      io,
      room,
      hook,
      { text: parsed.text, blocks: parsed.blocks, imageUrls: parsed.imageUrls, files: attachments },
      { senderName: parsed.username ?? null },
    );
    await markIntegrationUsed(hook.id);
    res.json({ ok: true, messageId: dto.id });
  }

  return [check, files, (req, res, next) => receive(req, res).catch(next)];
}

export function createIntegrationsRouter(io) {
  const router = Router();

  /** 이 방의 웹훅·나가는 웹훅·앱을 다룰 수 있으면 그 방, 아니면 응답을 보내고 null. */
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

  /** 서버 운영자인지 — 아니면 403을 보내고 null. */
  async function requireServerAdmin(req, res, what = '슬래시 명령') {
    const access = await userAccess(req.user.sub);
    if (access.isServerAdmin) return access;
    res.status(403).json({ error: `${what}은(는) 서버 운영자만 만들고 바꿀 수 있습니다.` });
    return null;
  }

  function audit(req, actorName, row, action, detail) {
    recordAudit({
      actorId: req.user.sub,
      actorName,
      action,
      teamId: row.teamId,
      targetType: 'integration',
      targetId: row.id,
      targetLabel: row.kind === 'command' ? `/${row.command}` : row.name,
      detail,
    });
  }

  // ── 들어오는 웹훅 ──

  router.get('/rooms/:roomId/webhooks', async (req, res) => {
    const room = await webhookRoom(req, res, req.params.roomId);
    if (!room) return;
    res.json((await listRoomWebhooks(room.id)).map((r) => integrationDto(r, { withUrl: true })));
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
    audit(req, displayName(user), row, AUDIT.integrationCreate, `웹훅 만들기 — ${room.name ?? '대화방'}`);
    res.status(201).json({ ...integrationDto(row, { withUrl: true }), token, urls: webhookUrls(req, token) });
  });

  // ── 나가는 웹훅 ──

  router.get('/rooms/:roomId/outgoing-webhooks', async (req, res) => {
    const room = await webhookRoom(req, res, req.params.roomId);
    if (!room) return;
    res.json((await listRoomOutgoingWebhooks(room.id)).map((r) => integrationDto(r, { withUrl: true })));
  });

  /** 나가는 웹훅 만들기 `{ name, emoji?, url, events }` → 서명 비밀(이번에만). 서버 운영자가 아니면 공인 주소만. */
  router.post('/rooms/:roomId/outgoing-webhooks', async (req, res) => {
    const room = await webhookRoom(req, res, req.params.roomId);
    if (!room) return;
    const name = parseBotName(req.body?.name);
    if (name.error) return res.status(400).json({ error: name.error.replace('봇 이름', '이름') });
    const emoji = parseBotEmoji(req.body?.emoji);
    if (emoji.error) return res.status(400).json({ error: emoji.error });
    const url = parseCommandUrl(req.body?.url);
    if (url.error) return res.status(400).json({ error: url.error });
    const events = parseEvents(req.body?.events);
    if (events.error) return res.status(400).json({ error: events.error });
    if ((await countRoomOutgoingWebhooks(room.id)) >= OUTGOING_PER_ROOM) {
      return res.status(400).json({ error: `한 방에 나가는 웹훅은 ${OUTGOING_PER_ROOM}개까지입니다.` });
    }
    const access = await userAccess(req.user.sub);
    const policy = await urlPolicy([url.url], access);
    if (policy.error) return res.status(400).json({ error: policy.error });
    const secret = newSigningSecret();
    const row = await insertIntegration({
      kind: 'outgoing',
      teamId: room.teamId,
      roomId: room.id,
      name: name.name,
      emoji: emoji.emoji,
      url: url.url,
      events: events.events,
      secretEnc: encryptField(secret),
      allowPrivate: policy.allowPrivate,
      createdBy: req.user.sub,
      createdByName: displayName(access.user),
    });
    audit(req, displayName(access.user), row, AUDIT.integrationCreate, `나가는 웹훅 만들기 — ${room.name ?? '대화방'} → ${url.url}`);
    res.status(201).json({ ...integrationDto(row, { withUrl: true }), secret });
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
    const secret = newSigningSecret();
    const row = await insertIntegration({
      kind: 'command',
      teamId: team.id,
      name: name.name,
      emoji: emoji.emoji,
      command: command.command,
      description,
      url: url.url,
      secretEnc: encryptField(secret),
      allowPrivate: true,
      createdBy: req.user.sub,
      createdByName: displayName(access.user),
    });
    audit(req, displayName(access.user), row, AUDIT.integrationCreate, `슬래시 명령 만들기 — ${url.url}`);
    res.status(201).json({ ...integrationDto(row, { withUrl: true }), secret });
  });

  /**
   * 슬래시 명령 실행 `{ command, text }` — 바깥 서버로 서명한 요청을 보내고(5초까지 기다림), 답이 in_channel이면 봇 메시지로 올리고
   * `{ posted: true }`, 부른 사람에게만 보일 답이면 `{ ephemeral: 글 }`, 할 말이 없으면 `{ ok: true }`. 답에 블록(단추 등)이 있으면 그대로
   * 블록으로 올린다 — 그 단추를 누르면 같은 명령 주소로 온다(type: 'block_actions').
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
    const body = JSON.stringify({
      type: 'command',
      command: `/${hook.command}`,
      text,
      teamId: room.teamId,
      teamName: team?.name ?? null,
      roomId: room.id,
      roomName: room.name ?? null,
      userId: req.user.sub,
      username: user?.username ?? null,
      userName: displayName(user),
      timestamp: Math.floor(Date.now() / 1000),
    });
    let response;
    try {
      response = await signedPost({
        url: hook.url,
        body,
        secret: decryptField(hook.secretEnc) ?? '',
        allowPrivate: mayReachPrivate(hook),
        timeoutMs: COMMAND_TIMEOUT_MS,
        userAgent: 'TangoTalk-Command/1',
      });
    } catch (err) {
      return res.status(502).json({
        error: err.timedOut
          ? `/${hook.command} 명령을 처리하는 서버가 ${COMMAND_TIMEOUT_MS / 1000}초 안에 답하지 않았습니다.`
          : `/${hook.command} 명령을 처리하는 서버에 연결하지 못했습니다.`,
      });
    }
    await markIntegrationUsed(hook.id);
    const parsed = parseCommandResponse(response);
    if (parsed.error) return res.status(502).json({ error: parsed.error });
    if (parsed.empty) return res.json({ ok: true });
    if (!parsed.inChannel) return res.json({ ephemeral: parsed.text });
    const posted = `${displayName(user)}님이 /${hook.command}${text ? ` ${text}` : ''} 실행\n\n${parsed.text}`;
    await postBotContent(io, room, hook, { text: clipGraphemes(posted, MESSAGE_TEXT_MAX - 1), blocks: parsed.blocks });
    res.json({ posted: true });
  });

  // ── 봇 메시지의 단추·선택지 ──

  /**
   * 단추·선택지 누르기 `{ actionId, value? }`(value는 선택지에서 고른 값) — 누른 것을 그 메시지의 저장한 블록에서 찾아 맞춰 보고(앱이 보낸
   * 단추 값은 믿지 않는다), 그 메시지를 올린 연동의 응답 주소(슬래시 명령은 명령 주소)로 서명한 요청을 보낸다(5초까지):
   *   { type: 'block_actions', actionId, value, blockId, teamId, teamName, roomId, roomName, messageId, message: { text, blocks },
   *     userId, username, userName, timestamp }
   * 답에 따라 그 메시지를 바꾸거나(`{ updated: true }`)·지우거나(`{ removed: true }`)·방에 새로 올리거나(`{ posted: true }`)·누른 사람에게만
   * 보여 준다(`{ ephemeral: 글 }`). 할 말이 없으면 `{ ok: true }`(integrationRules.js parseInteractionResponse).
   */
  router.post('/messages/:id/actions', async (req, res) => {
    const message = isUuid(req.params.id) ? await findMessageById(req.params.id) : null;
    if (!message || message.deletedAt) return res.status(404).json({ error: '메시지를 찾을 수 없습니다.' });
    const room = await findRoomById(message.roomId);
    if (!room || !(await isRoomMember(room.id, req.user.sub))) return res.status(404).json({ error: '메시지를 찾을 수 없습니다.' });
    if (!roomAcceptsIntegrations(room) || room.archivedAt) {
      return res.status(400).json({ error: '이 대화방에서는 단추를 누를 수 없습니다.' });
    }
    const found = findBlockAction(message.botBlocks, req.body?.actionId, typeof req.body?.value === 'string' ? req.body.value : null);
    if (!found) return res.status(400).json({ error: '이 단추는 더 쓸 수 없습니다(메시지가 바뀌었을 수 있습니다).' });
    const hook = message.integrationId ? await findIntegrationById(message.integrationId) : null;
    const url = interactionUrlOf(hook);
    if (!url) return res.status(400).json({ error: '이 메시지의 단추를 받을 곳이 없습니다(연동에 응답 주소가 없습니다).' });
    const wait = limits.interactionUser.hit(req.user.sub);
    if (wait > 0) return retryLater(res, wait, `너무 자주 눌렀습니다. ${waitText(wait)} 뒤에 다시 하세요.`);
    const [user, team] = await Promise.all([findUserById(req.user.sub), findTeamById(room.teamId)]);
    const body = JSON.stringify({
      type: 'block_actions',
      actionId: found.element.actionId,
      value: found.value,
      ...(found.optionText ? { optionText: found.optionText } : {}),
      blockId: found.blockId,
      teamId: room.teamId,
      teamName: team?.name ?? null,
      roomId: room.id,
      roomName: room.name ?? null,
      messageId: message.id,
      message: { text: message.text ?? null, blocks: message.botBlocks ?? null },
      userId: req.user.sub,
      username: user?.username ?? null,
      userName: displayName(user),
      timestamp: Math.floor(Date.now() / 1000),
    });
    let response;
    try {
      response = await signedPost({
        url,
        body,
        secret: decryptField(hook.secretEnc) ?? '',
        allowPrivate: mayReachPrivate(hook),
        timeoutMs: COMMAND_TIMEOUT_MS,
        userAgent: 'TangoTalk-Interaction/1',
      });
    } catch (err) {
      return res.status(502).json({
        error: err.timedOut
          ? `단추를 처리하는 서버가 ${COMMAND_TIMEOUT_MS / 1000}초 안에 답하지 않았습니다.`
          : '단추를 처리하는 서버에 연결하지 못했습니다.',
      });
    }
    await markIntegrationUsed(hook.id);
    const parsed = parseInteractionResponse(response);
    if (parsed.error) return res.status(502).json({ error: parsed.error });
    if (parsed.remove) {
      await removeBotMessage(io, message, { room });
      return res.json({ removed: true });
    }
    if (parsed.replace) {
      await updateBotMessage(io, message, parsed.replace, { room });
      return res.json({ updated: true });
    }
    if (parsed.post) {
      await postBotContent(io, room, hook, parsed.post);
      return res.json({ posted: true });
    }
    if (parsed.ephemeral) return res.json({ ephemeral: parsed.ephemeral });
    res.json({ ok: true });
  });

  // ── 연동 앱(봇 전용 계정 + OAuth 앱) ──

  /** 팀의 연동 앱 — 팀 멤버는 이름·아이콘·설명(방에 추가할 앱 고르기), 서버 운영자는 주소까지(관리자 콘솔). */
  router.get('/teams/:teamId/apps', async (req, res) => {
    if (!isUuid(req.params.teamId)) return res.status(404).json({ error: '팀을 찾을 수 없습니다.' });
    const [role, access] = await Promise.all([getTeamRole(req.params.teamId, req.user.sub), userAccess(req.user.sub)]);
    if (role === null && !access.isServerAdmin) return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    const rows = await listTeamApps(req.params.teamId);
    res.json(access.isServerAdmin ? rows.map((r) => integrationDto(r, { withUrl: true })) : rows.filter((r) => r.enabled).map(appPublicDto));
  });

  /**
   * 연동 앱 만들기(서버 운영자) `{ name, emoji?, description?, url?, events?, interactionUrl?, redirectUris? }` → 봇 토큰(ttb_)·OAuth 앱 id
   * (ttc_)·앱 비밀(tts_)·서명 비밀(이번에만). [url]이 있으면 앱이 추가된 방의 [events]를 받고, [interactionUrl]로 단추 누름을 받는다.
   * [redirectUris]가 있으면 OAuth(사람이 승인해 그 사람 이름으로)를 쓸 수 있다.
   */
  router.post('/teams/:teamId/apps', async (req, res) => {
    const access = await requireServerAdmin(req, res, '연동 앱');
    if (!access) return;
    const team = isUuid(req.params.teamId) ? await findTeamById(req.params.teamId) : null;
    if (!team) return res.status(404).json({ error: '팀을 찾을 수 없습니다.' });
    const fields = parseAppFields(req.body ?? {}, { creating: true });
    if (fields.error) return res.status(400).json({ error: fields.error });
    if ((await countTeamApps(team.id)) >= APPS_PER_TEAM) {
      return res.status(400).json({ error: `한 팀에 연동 앱은 ${APPS_PER_TEAM}개까지입니다.` });
    }
    const botToken = generateSecretToken(BOT_TOKEN_PREFIX);
    const clientSecret = generateSecretToken(CLIENT_SECRET_PREFIX);
    const signingSecret = newSigningSecret();
    const row = await insertIntegration({
      kind: 'app',
      teamId: team.id,
      ...fields.patch,
      tokenHash: lookupHash(botToken),
      tokenPrefix: tokenPrefixOf(botToken),
      clientId: generateSecretToken(CLIENT_ID_PREFIX).slice(0, CLIENT_ID_PREFIX.length + 24),
      clientSecretHash: lookupHash(clientSecret),
      secretEnc: encryptField(signingSecret),
      allowPrivate: true,
      createdBy: req.user.sub,
      createdByName: displayName(access.user),
    });
    audit(req, displayName(access.user), row, AUDIT.integrationCreate, `연동 앱 만들기 — ${team.name}`);
    res.status(201).json({ ...integrationDto(row, { withUrl: true }), botToken, clientSecret, signingSecret });
  });

  /** 이 방에 추가된 앱 — 방 멤버면 누구나 본다(어떤 봇이 이 방을 읽는지 알 수 있게). */
  router.get('/rooms/:roomId/apps', async (req, res) => {
    const room = await findRoomById(req.params.roomId);
    if (!room || !(await isRoomMember(room.id, req.user.sub))) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    const rows = await listRoomApps(room.id);
    res.json(rows.map((r) => ({ ...appPublicDto(r.app), enabled: r.app.enabled, addedByName: r.addedByName ?? null, addedAt: ms(r.addedAt) })));
  });

  /** 방에 앱 추가 `{ appId }`(방 관리자) — 그 팀의 켜진 앱만. 봇이 이 방을 읽고 쓰게 되므로 방에 안내를 남긴다. */
  router.post('/rooms/:roomId/apps', async (req, res) => {
    const room = await webhookRoom(req, res, req.params.roomId);
    if (!room) return;
    const app = isUuid(req.body?.appId) ? await findIntegrationById(req.body.appId) : null;
    if (!app || app.kind !== 'app' || app.teamId !== room.teamId || !app.enabled) {
      return res.status(404).json({ error: '이 팀의 연동 앱을 찾을 수 없습니다.' });
    }
    const user = await findUserById(req.user.sub);
    const added = await addAppToRoom({ integrationId: app.id, roomId: room.id, addedBy: req.user.sub, addedByName: displayName(user) });
    if (added) {
      await postSystemMessage(io, room, `${displayName(user)}님이 앱 "${app.name}"을(를) 추가했습니다. 이 앱은 이 방의 메시지를 읽고 쓸 수 있습니다.`);
      audit(req, displayName(user), app, AUDIT.integrationCreate, `연동 앱을 방에 추가 — ${room.name ?? '대화방'}`);
    }
    res.status(added ? 201 : 200).json({ ok: true });
  });

  router.delete('/rooms/:roomId/apps/:appId', async (req, res) => {
    const room = await webhookRoom(req, res, req.params.roomId);
    if (!room) return;
    const app = isUuid(req.params.appId) ? await findIntegrationById(req.params.appId) : null;
    if (!app || !(await removeAppFromRoom(app.id, room.id))) return res.status(404).json({ error: '이 방에 없는 앱입니다.' });
    const user = await findUserById(req.user.sub);
    await postSystemMessage(io, room, `${displayName(user)}님이 앱 "${app.name}"을(를) 이 방에서 뺐습니다.`);
    audit(req, displayName(user), app, AUDIT.integrationDelete, `연동 앱을 방에서 빼기 — ${room.name ?? '대화방'}`);
    res.json({ ok: true });
  });

  // ── 공통: 바꾸기·새 비밀·보내기 기록·시험·지우기 ──

  /**
   * 이 연동을 다룰 수 있으면 `{ row, access }`, 아니면 응답을 보내고 null — 웹훅·나가는 웹훅은 그 방 관리자, 명령·앱은 서버 운영자.
   */
  async function manageable(req, res) {
    const row = isUuid(req.params.id) ? await findIntegrationById(req.params.id) : null;
    if (!row) {
      res.status(404).json({ error: NOT_FOUND });
      return null;
    }
    if (row.kind === 'command' || row.kind === 'app') {
      const access = await requireServerAdmin(req, res, integrationKindLabel(row.kind));
      return access ? { row, access } : null;
    }
    if (!(await webhookRoom(req, res, row.roomId))) return null;
    return { row, access: await userAccess(req.user.sub) };
  }

  /**
   * 바꾸기 — 모두 이름·아이콘, 명령은 설명·주소, 웹훅은 단추 응답 주소(interactionUrl — 처음 정하면 서명 비밀을 만들어 이번에만 준다),
   * 나가는 웹훅은 주소·받을 일·켜기(enabled — 켜면 연달아 실패한 수를 0으로), 앱은 설명·주소·받을 일·응답 주소·돌아갈 주소·켜기.
   */
  router.patch('/integrations/:id', async (req, res) => {
    const ctx = await manageable(req, res);
    if (!ctx) return;
    const { row, access } = ctx;
    const b = req.body ?? {};
    const patch = {};
    if ('name' in b) {
      const name = parseBotName(b.name);
      if (name.error) return res.status(400).json({ error: name.error });
      patch.name = name.name;
    }
    if ('emoji' in b) {
      const emoji = parseBotEmoji(b.emoji);
      if (emoji.error) return res.status(400).json({ error: emoji.error });
      patch.emoji = emoji.emoji;
    }
    if (row.kind === 'command') {
      if ('url' in b) {
        const url = parseCommandUrl(b.url);
        if (url.error) return res.status(400).json({ error: url.error });
        patch.url = url.url;
      }
      if ('description' in b) {
        patch.description = typeof b.description === 'string' ? b.description.trim().slice(0, COMMAND_DESCRIPTION_MAX) || null : null;
      }
    }
    if (row.kind === 'app') {
      const fields = parseAppFields(b, { creating: false });
      if (fields.error) return res.status(400).json({ error: fields.error });
      Object.assign(patch, fields.patch);
    }
    if (row.kind === 'outgoing') {
      if ('url' in b) {
        const url = parseCommandUrl(b.url);
        if (url.error) return res.status(400).json({ error: url.error });
        patch.url = url.url;
      }
      if ('events' in b) {
        const events = parseEvents(b.events);
        if (events.error) return res.status(400).json({ error: events.error });
        patch.events = events.events;
      }
    }
    let newSecret = null;
    if (row.kind === 'webhook' && 'interactionUrl' in b) {
      const url = parseOptionalUrl(b.interactionUrl);
      if (url.error) return res.status(400).json({ error: url.error });
      patch.interactionUrl = url.url;
      if (url.url && !row.secretEnc) {
        newSecret = newSigningSecret();
        patch.secretEnc = encryptField(newSecret);
      }
    }
    if ((row.kind === 'outgoing' || row.kind === 'app') && 'enabled' in b) {
      if (typeof b.enabled !== 'boolean') return res.status(400).json({ error: 'enabled는 true/false여야 합니다.' });
      patch.enabled = b.enabled;
      if (b.enabled) patch.failureCount = 0;
    }
    if (Object.keys(patch).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
    // 방 관리자가 정하는 주소(웹훅의 응답 주소·나가는 웹훅의 주소)는 사내 주소 허용을 다시 정한다 — 바꾼 뒤의 주소가 모두 공인이어야 한다.
    if ((row.kind === 'webhook' || row.kind === 'outgoing') && ('url' in patch || 'interactionUrl' in patch)) {
      const after = { ...row, ...patch };
      const policy = await urlPolicy([after.url, after.interactionUrl], access);
      if (policy.error) return res.status(400).json({ error: policy.error });
      patch.allowPrivate = policy.allowPrivate;
    }
    const updated = await updateIntegration(row.id, patch);
    res.json({ ...integrationDto(updated, { withUrl: true }), ...(newSecret ? { secret: newSecret } : {}) });
  });

  /**
   * 새 비밀 — 웹훅은 새 주소(`{ which: 'signing' }`이면 단추 응답의 새 서명 비밀), 명령·나가는 웹훅은 새 서명 비밀, 앱은 `which`로
   * 'bot'(봇 토큰)·'client'(OAuth 앱 비밀)·'signing'(서명 비밀) 중 하나. 예전 것은 바로 못 쓴다. 새 값은 이번에만 보인다.
   */
  router.post('/integrations/:id/regenerate', async (req, res) => {
    const ctx = await manageable(req, res);
    if (!ctx) return;
    const { row } = ctx;
    const which = req.body?.which;
    if (row.kind === 'webhook' && which !== 'signing') {
      const token = generateSecretToken(WEBHOOK_TOKEN_PREFIX);
      const updated = await updateIntegration(row.id, { tokenHash: lookupHash(token), tokenPrefix: tokenPrefixOf(token) });
      return res.json({ ...integrationDto(updated, { withUrl: true }), token, urls: webhookUrls(req, token) });
    }
    if (row.kind === 'app' && which === 'bot') {
      const botToken = generateSecretToken(BOT_TOKEN_PREFIX);
      const updated = await updateIntegration(row.id, { tokenHash: lookupHash(botToken), tokenPrefix: tokenPrefixOf(botToken) });
      return res.json({ ...integrationDto(updated, { withUrl: true }), botToken });
    }
    if (row.kind === 'app' && which === 'client') {
      const clientSecret = generateSecretToken(CLIENT_SECRET_PREFIX);
      const updated = await updateIntegration(row.id, { clientSecretHash: lookupHash(clientSecret) });
      return res.json({ ...integrationDto(updated, { withUrl: true }), clientSecret });
    }
    if (row.kind === 'app' && which !== 'signing') return res.status(400).json({ error: "which는 'bot'·'client'·'signing' 중 하나여야 합니다." });
    const secret = newSigningSecret();
    const updated = await updateIntegration(row.id, { secretEnc: encryptField(secret) });
    res.json({ ...integrationDto(updated, { withUrl: true }), secret, ...(row.kind === 'app' ? { signingSecret: secret } : {}) });
  });

  /** 최근 보내기 기록(나가는 웹훅·앱 — 7일, 30개까지). */
  router.get('/integrations/:id/deliveries', async (req, res) => {
    const ctx = await manageable(req, res);
    if (!ctx) return;
    res.json((await listRecentDeliveries(ctx.row.id, 30)).map(deliveryDto));
  });

  /** 보내 보기 — ping 일을 바로 한 번 보내고 그 결과(보내기 기록). */
  router.post('/integrations/:id/test', async (req, res) => {
    const ctx = await manageable(req, res);
    if (!ctx) return;
    const { row, access } = ctx;
    if ((row.kind !== 'outgoing' && row.kind !== 'app') || !row.url) {
      return res.status(400).json({ error: '보낼 주소가 있는 나가는 웹훅·앱만 시험할 수 있습니다.' });
    }
    const wait = limits.webhookTestUser.hit(req.user.sub);
    if (wait > 0) return retryLater(res, wait, `너무 자주 시험했습니다. ${waitText(wait)} 뒤에 다시 하세요.`);
    const delivery = await sendTestDelivery(row, displayName(access.user));
    res.json(delivery ? deliveryDto(delivery) : { status: 'failed', lastError: NOT_FOUND });
  });

  router.delete('/integrations/:id', async (req, res) => {
    const ctx = await manageable(req, res);
    if (!ctx) return;
    const { row, access } = ctx;
    await deleteIntegration(row.id);
    audit(req, displayName(access.user), row, AUDIT.integrationDelete, `${integrationKindLabel(row.kind)} 지우기`);
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

/**
 * 연동 앱의 칸 — 만들 때는 이름 필수. `{ patch }` | `{ error }`. 주소(url·interactionUrl)는 비울 수 있고, 받을 일은 주소가 있을 때만
 * 하나 이상(주소 없이 고르면 그대로 둔다), 돌아갈 주소는 oauthRules.js parseRedirectUris.
 */
function parseAppFields(b, { creating }) {
  const patch = {};
  if (creating || 'name' in b) {
    const name = parseBotName(b.name);
    if (name.error) return { error: name.error.replace('봇 이름', '앱 이름') };
    patch.name = name.name;
  }
  if (creating || 'emoji' in b) {
    const emoji = parseBotEmoji(b.emoji);
    if (emoji.error) return { error: emoji.error };
    patch.emoji = emoji.emoji;
  }
  if (creating || 'description' in b) {
    patch.description = typeof b.description === 'string' ? b.description.trim().slice(0, COMMAND_DESCRIPTION_MAX) || null : null;
  }
  for (const key of ['url', 'interactionUrl']) {
    if (creating || key in b) {
      const url = parseOptionalUrl(b[key]);
      if (url.error) return { error: url.error };
      patch[key] = url.url;
    }
  }
  if ((creating && b.events !== undefined) || (!creating && 'events' in b)) {
    const list = Array.isArray(b.events) ? b.events : [];
    if (list.length > 0) {
      const events = parseEvents(list);
      if (events.error) return { error: events.error };
      patch.events = events.events;
    } else {
      patch.events = [];
    }
  } else if (creating) {
    patch.events = [];
  }
  if (creating || 'redirectUris' in b) {
    const uris = parseRedirectUris(b.redirectUris ?? []);
    if (uris.error) return { error: uris.error };
    patch.redirectUris = uris.uris;
  }
  if (!creating && 'enabled' in b && typeof b.enabled === 'boolean') {
    patch.enabled = b.enabled;
    if (b.enabled) patch.failureCount = 0;
  }
  return { patch };
}
