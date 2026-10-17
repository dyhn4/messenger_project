import { Router } from 'express';
import { accountState } from './authState.js';
import { limits, retryLater, waitText } from './authGuard.js';
import { lookupHash } from './crypto.js';
import { findUsableApiToken, touchApiToken } from './db/queries/integrations.js';
import { listMessagesByRoom } from './db/queries/messages.js';
import { findRoomById, getDmHistoryFloor, isRoomMember, listRoomsForUser } from './db/queries/rooms.js';
import { isTeamMember, listTeamsForUser } from './db/queries/teams.js';
import { findUserById } from './db/queries/users.js';
import { API_TOKEN_PREFIX, isSecretToken, tokenHasScope } from './integrationRules.js';
import { sendUserMessage } from './sendMessage.js';

/**
 * 공개 API(/api/v1) — 개인 API 토큰(`Authorization: Bearer ttk_…`)으로 "내 이름으로" 스크립트·자동화가 부르는 작은 API. 앱이 쓰는
 * /api와 따로 두어, 앱 API가 바뀌어도 이 모양은 그대로 지킨다.
 *  - 'read': GET /me, /teams, /rooms?teamId=, /rooms/:id/messages
 *  - 'write': POST /rooms/:id/messages { text } — 사람이 보낸 것과 똑같은 내 메시지(안읽음·알림·멘션 그대로)
 * 비밀 대화는 서버가 내용을 모르므로(종단 간 암호화) 목록에서 빼고 읽기·쓰기도 막는다. 정지·탈퇴한 계정의 토큰은 바로 못 쓴다.
 */

const ms = (v) => (v ? new Date(v).getTime() : null);

/** 토큰 확인 — 맞으면 req.apiUser = { sub, scopes }. */
async function requireApiToken(req, res, next) {
  const header = req.get('authorization') ?? '';
  const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
  const row = isSecretToken(token, API_TOKEN_PREFIX) ? await findUsableApiToken(lookupHash(token)) : null;
  if (!row) return res.status(401).json({ error: '유효하지 않거나 만료된 API 토큰입니다.' });
  if ((await accountState(row.userId)).blocked) return res.status(403).json({ error: '쓸 수 없는 계정입니다.' });
  const wait = limits.apiToken.hit(row.id);
  if (wait > 0) return retryLater(res, wait, `요청이 너무 많습니다. ${waitText(wait)} 뒤에 다시 하세요.`);
  touchApiToken(row).catch(() => {});
  req.apiUser = { sub: row.userId, scopes: row.scopes ?? [] };
  next();
}

const requireScope = (scope) => (req, res, next) =>
  tokenHasScope(req.apiUser.scopes, scope)
    ? next()
    : res.status(403).json({ error: `이 토큰에는 '${scope}' 권한이 없습니다.` });

/** 내가 멤버이고 비밀 대화가 아닌 방 — 아니면 응답을 보내고 null. */
async function apiRoom(req, res) {
  const room = await findRoomById(req.params.id);
  if (!room || room.isSecret || !(await isRoomMember(room.id, req.apiUser.sub))) {
    res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    return null;
  }
  return room;
}

const roomDto = (r) => ({ id: r.id, teamId: r.teamId, type: r.type, name: r.name ?? null, archived: !!r.archivedAt });

const messageDto = (m) => ({
  id: m.id,
  roomId: m.roomId,
  type: m.type,
  senderId: m.senderId ?? null,
  senderName: m.senderName ?? null,
  bot: !!(m.integrationId || m.botEmoji) || (m.senderId == null && m.type === 'text'),
  title: m.deletedAt ? null : (m.title ?? null),
  text: m.deletedAt ? null : (m.text ?? null),
  fileName: m.deletedAt ? null : (m.fileName ?? null),
  createdAt: ms(m.createdAt),
  editedAt: ms(m.editedAt),
  deleted: !!m.deletedAt,
});

export function createPublicApiRouter(io) {
  const router = Router();
  router.use(requireApiToken);

  router.get('/me', requireScope('read'), async (req, res) => {
    const user = await findUserById(req.apiUser.sub);
    res.json({ id: user.id, username: user.username, name: user.name ?? null, email: user.email ?? null });
  });

  router.get('/teams', requireScope('read'), async (req, res) => {
    const rows = await listTeamsForUser(req.apiUser.sub);
    res.json(rows.map(({ team }) => ({ id: team.id, name: team.name })));
  });

  /** 내 대화방 — teamId 필수(팀마다 방이 따로다). */
  router.get('/rooms', requireScope('read'), async (req, res) => {
    const teamId = typeof req.query.teamId === 'string' ? req.query.teamId : '';
    if (!/^[0-9a-f-]{36}$/i.test(teamId) || !(await isTeamMember(teamId, req.apiUser.sub))) {
      return res.status(400).json({ error: 'teamId에 내가 속한 팀의 id를 넣으세요(GET /api/v1/teams).' });
    }
    const rows = await listRoomsForUser(req.apiUser.sub, teamId);
    res.json(rows.filter((r) => !r.isSecret).map(roomDto));
  });

  /** 메시지 — 최신부터 limit개(최대 100), before(epoch ms)로 더 오래된 쪽을 넘긴다. 결과는 오래된 것부터. */
  router.get('/rooms/:id/messages', requireScope('read'), async (req, res) => {
    const room = await apiRoom(req, res);
    if (!room) return;
    const limit = Math.min(Math.max(Number(req.query.limit) || 50, 1), 100);
    const beforeMs = Number(req.query.before);
    const before = Number.isFinite(beforeMs) && beforeMs > 0 ? new Date(beforeMs) : undefined;
    const floor = room.type === 'dm' ? await getDmHistoryFloor(room.id, req.apiUser.sub) : null;
    const rows = await listMessagesByRoom(room.id, limit, before, floor);
    res.json(rows.map(messageDto));
  });

  /** 내 이름으로 글 메시지 보내기 `{ text }`. */
  router.post('/rooms/:id/messages', requireScope('write'), async (req, res) => {
    const room = await apiRoom(req, res);
    if (!room) return;
    const text = typeof req.body?.text === 'string' ? req.body.text.trim() : '';
    if (!text) return res.status(400).json({ error: 'text에 보낼 글을 넣으세요.' });
    const result = await sendUserMessage({ io, senderId: req.apiUser.sub, room, payload: { roomId: room.id, type: 'text', text } });
    if (!result.ok) return res.status(result.status ?? 400).json({ error: result.error });
    res.status(201).json({ id: result.message.id, createdAt: result.message.createdAt });
  });

  router.use((req, res) => res.status(404).json({ error: '없는 API입니다.' }));
  return router;
}
