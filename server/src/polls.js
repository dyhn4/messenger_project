import { Router } from 'express';
import { topicAccess } from './access.js';
import {
  closePollEarly,
  findPollById,
  listFavoritePollIds,
  listFavoritePolls,
  listPollPanelRows,
  listOptionsForPolls,
  listPollsByMessageIds,
  listVotesForPolls,
  replaceMyVotes,
  setPollFavorite,
} from './db/queries/polls.js';
import { findMessageById, listAttachmentsForMessages } from './db/queries/messages.js';
import { findRoomById, getDmHistoryFloor, isRoomMember } from './db/queries/rooms.js';
import { isTeamMember } from './db/queries/teams.js';
import { findUserById } from './db/queries/users.js';
import { toMessageDto } from './messages.js';
import { canManageTeam, graphemeLength } from './permissions.js';
import { formatCursor } from './pageCursor.js';
import { emitPollVoteUpdate, parsePollListQuery, pollIsClosedAt, pollRoomUpdate, toPollDto } from './pollListRules.js';
import { postSystemMessage, roomDisplayName } from './rooms.js';
import { sendUserMessage } from './sendMessage.js';

// 투표 DTO 조립은 DB 없이 테스트하려고 pollListRules.js로 옮겼다 — 새 투표 메시지를 만드는 sendMessage.js 등은
// 지금처럼 여기서 가져다 쓴다.
export { toPollDto };

// 투표 입력 제한 — 클라이언트 입력창(maxLength)과 같은 단위(글자 = 이모지 한 덩어리 1자)로 센다.
export const POLL_TITLE_MAX = 100;
export const POLL_DESCRIPTION_MAX = 1000;
export const POLL_OPTION_MAX = 100;
export const POLL_OPTIONS_MIN = 2;
export const POLL_OPTIONS_MAX_COUNT = 20;
export const POLL_MAX_AHEAD_MS = 90 * 24 * 60 * 60 * 1000; // 마감은 지금부터 최대 90일 뒤까지

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * 투표 만들기 본문 검사(POST /rooms/:roomId/polls) — 통과하면 sendUserMessage에 그대로 넘길 수 있는
 * `{ title, description, optionTexts, anonymous, multiple, closesAt(Date) }`, 아니면 `{ error }`.
 * 제목·설명·보기는 앞뒤 공백을 뺀 값을 쓰고, 보기 중복도 공백을 뺀 값으로 비교한다.
 */
export function parsePollFields(body) {
  const title = typeof body?.title === 'string' ? body.title.trim() : '';
  if (!title) return { error: '투표 제목을 입력하세요.' };
  if (graphemeLength(title) > POLL_TITLE_MAX) return { error: `투표 제목은 ${POLL_TITLE_MAX}자 이내로 입력하세요.` };

  let description = null;
  if (body?.description !== undefined && body?.description !== null) {
    if (typeof body.description !== 'string') return { error: '투표 설명이 올바르지 않습니다.' };
    description = body.description.trim() || null;
    if (description && graphemeLength(description) > POLL_DESCRIPTION_MAX) {
      return { error: `투표 설명은 ${POLL_DESCRIPTION_MAX}자 이내로 입력하세요.` };
    }
  }

  if (!Array.isArray(body?.options)) return { error: '투표 보기를 입력하세요.' };
  const optionTexts = [];
  for (const raw of body.options) {
    const text = typeof raw === 'string' ? raw.trim() : '';
    if (!text) return { error: '비어 있는 보기가 있습니다.' };
    if (graphemeLength(text) > POLL_OPTION_MAX) return { error: `보기는 ${POLL_OPTION_MAX}자 이내로 입력하세요.` };
    optionTexts.push(text);
  }
  if (optionTexts.length < POLL_OPTIONS_MIN) return { error: `보기는 ${POLL_OPTIONS_MIN}개 이상 입력하세요.` };
  if (optionTexts.length > POLL_OPTIONS_MAX_COUNT) return { error: `보기는 ${POLL_OPTIONS_MAX_COUNT}개까지 만들 수 있습니다.` };
  if (new Set(optionTexts).size !== optionTexts.length) return { error: '같은 보기가 여러 번 있습니다.' };

  for (const key of ['anonymous', 'multiple']) {
    if (body?.[key] !== undefined && typeof body[key] !== 'boolean') {
      return { error: '익명·복수 선택 설정이 올바르지 않습니다.' };
    }
  }

  const closesAtMs = body?.closesAt;
  if (typeof closesAtMs !== 'number' || !Number.isFinite(closesAtMs)) return { error: '마감 시각을 지정하세요.' };
  const now = Date.now();
  if (closesAtMs <= now) return { error: '마감 시각은 지금보다 뒤여야 합니다.' };
  if (closesAtMs - now > POLL_MAX_AHEAD_MS) return { error: '마감은 지금부터 최대 90일 이내로 정하세요.' };

  return {
    title,
    description,
    optionTexts,
    anonymous: body?.anonymous === true,
    multiple: body?.multiple === true,
    closesAt: new Date(closesAtMs),
  };
}

/** 마감 여부 — 일찍 마감했거나 마감 시각이 지났으면 닫힌 것(서버가 계산해서 내려준다). */
export function isPollClosed(poll) {
  return pollIsClosedAt(poll);
}

/** 투표 행들을 보는 사람 기준 DTO로 — `Map<pollId, dto>`. 보기·표·즐겨찾기를 한 번씩만 조회한다. */
export async function loadPollDtos(pollRows, viewerId = null) {
  const result = new Map();
  if (pollRows.length === 0) return result;
  const ids = pollRows.map((p) => p.id);
  const [options, votes, favorites] = await Promise.all([
    listOptionsForPolls(ids),
    listVotesForPolls(ids),
    viewerId ? listFavoritePollIds(ids, viewerId) : Promise.resolve(new Set()),
  ]);
  for (const poll of pollRows) {
    result.set(
      poll.id,
      toPollDto(
        poll,
        options.filter((o) => o.pollId === poll.id),
        votes.filter((v) => v.pollId === poll.id),
        { viewerId, favorite: favorites.has(poll.id) },
      ),
    );
  }
  return result;
}

/**
 * 메시지 행들 중 투표(type='poll', 지워지지 않은 것)에 `poll`(보는 사람 기준)을 붙여 돌려준다 — toMessageDto가
 * 동기 함수라서 목록을 내려주는 곳(방 메시지, 고정 게시글, 즐겨찾기 투표)이 DTO로 바꾸기 전에 한 번 부른다.
 * 투표가 없는 목록이면 조회 없이 그대로 돌려준다.
 */
export async function attachPolls(messageRows, viewerId = null) {
  const pollMessages = messageRows.filter((m) => m.type === 'poll' && !m.deletedAt);
  if (pollMessages.length === 0) return messageRows;
  const pollRows = await listPollsByMessageIds(pollMessages.map((m) => m.id));
  const dtos = await loadPollDtos(pollRows, viewerId);
  const pollIdByMessage = new Map(pollRows.map((p) => [p.messageId, p.id]));
  return messageRows.map((m) => {
    const pollId = pollIdByMessage.get(m.id);
    return pollId ? { ...m, poll: dtos.get(pollId) } : m;
  });
}

/**
 * poll:updated에 싣는 poll — 방 전체와 투표한 사람의 기기에 같은 값이 간다. 받는 사람마다 다른 값(myOptionIds/favorite)은
 * 중립값(빈 배열·false)으로 채우고, 익명이면 voters 키도 없다(toPollDto).
 */
async function neutralPollDto(pollRow) {
  return (await loadPollDtos([pollRow], null)).get(pollRow.id);
}

/**
 * 투표 — 만들기(방 메시지 한 건)는 sendUserMessage 규칙을 그대로 쓰고, 투표하기·일찍 마감·즐겨찾기를 맡는다.
 * 소켓 message:send로는 투표를 만들 수 없다(REST 전용 — 입력 검사가 여기 있어서).
 */
export function createPollsRouter(io) {
  const router = Router();

  router.post('/rooms/:roomId/polls', async (req, res) => {
    const room = await findRoomById(req.params.roomId);
    if (!room) return res.status(404).json({ error: '방을 찾을 수 없습니다.' });
    if (!(await isRoomMember(room.id, req.user.sub))) {
      return res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
    }
    if (room.isSecret) {
      return res.status(400).json({ error: '비밀 대화에서는 투표를 만들 수 없습니다.' });
    }
    const poll = parsePollFields(req.body);
    if (poll.error) return res.status(400).json({ error: poll.error });

    const result = await sendUserMessage({
      io,
      senderId: req.user.sub,
      room,
      poll,
      payload: { roomId: room.id, type: 'poll', attachments: req.body?.attachments },
    });
    if (!result.ok) return res.status(result.status ?? 400).json({ error: result.error });
    res.status(201).json(result.message);
  });

  /** 투표 행 + 그 메시지(지워지지 않음) + 방 + 내가 그 방 멤버인지까지 한 번에. 통과하면 { poll, message, room }. */
  async function requirePollMember(req, res) {
    const poll = UUID_RE.test(req.params.pollId) ? await findPollById(req.params.pollId) : null;
    const message = poll ? await findMessageById(poll.messageId) : null;
    if (!poll || !message || message.deletedAt) {
      res.status(404).json({ error: '투표를 찾을 수 없습니다.' });
      return null;
    }
    const room = await findRoomById(poll.roomId);
    if (!room || !(await isRoomMember(room.id, req.user.sub))) {
      res.status(403).json({ error: '이 방의 멤버가 아닙니다.' });
      return null;
    }
    // 1:1 대화에서 "기록 지우고 나가기" 전의 투표는 다시 들어와도 안 보인다(메시지 조회와 같은 규칙).
    const floor = room.type === 'dm' ? await getDmHistoryFloor(room.id, req.user.sub) : null;
    if (floor && message.createdAt < floor) {
      res.status(404).json({ error: '투표를 찾을 수 없습니다.' });
      return null;
    }
    return { poll, message, room };
  }

  // 정적 경로라 '/polls/:pollId/...'와 겹치지 않지만, 읽기 쉽도록 앞에 둔다.
  router.get('/polls/favorites', async (req, res) => {
    const teamId = typeof req.query.teamId === 'string' ? req.query.teamId : '';
    if (!UUID_RE.test(teamId)) return res.status(400).json({ error: 'teamId가 필요합니다.' });
    if (!(await isTeamMember(teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    const rows = await listFavoritePolls(req.user.sub, teamId);
    const messageRows = rows.map((r) => r.message);
    const [attachmentsByMessage, withPolls] = await Promise.all([
      listAttachmentsForMessages(messageRows.map((m) => m.id)),
      attachPolls(messageRows, req.user.sub),
    ]);
    const roomNames = new Map();
    for (const r of rows) {
      if (!roomNames.has(r.room.id)) roomNames.set(r.room.id, await roomDisplayName(r.room, req.user.sub));
    }
    res.json(
      rows.map((r, i) => ({
        message: toMessageDto({ ...withPolls[i], attachments: attachmentsByMessage[r.message.id] }),
        roomName: roomNames.get(r.room.id) ?? null,
        favoritedAt: new Date(r.favoritedAt).getTime(),
      })),
    );
  });

  // 투표 목록 패널 — 이 팀에서 내가 멤버인 방(비밀 대화 제외)의 투표를 만든 시각순(기본) 또는 기한 순(sort=deadline)으로,
  // 필터·무한 스크롤(nextBefore 커서는 두 정렬 모두 "<정렬 키>:<pollId>" — pollListRules.js).
  // 각 항목은 방 메시지 DTO(poll은 보는 사람 기준 myOptionIds/favorite 포함)에 roomName(받는 사람 기준 표시 이름)을 더한 것.
  router.get('/polls', async (req, res) => {
    const q = parsePollListQuery(req.query);
    if (q.error) return res.status(400).json({ error: q.error });
    if (!(await isTeamMember(q.teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    const { rows, total } = await listPollPanelRows(req.user.sub, q);
    const kept = rows.slice(0, q.limit); // 하나 더 받아 온 것은 hasMore 계산에만 쓴다.
    const messageRows = kept.map((r) => r.message);
    const [attachmentsByMessage, withPolls] = await Promise.all([
      listAttachmentsForMessages(messageRows.map((m) => m.id)),
      attachPolls(messageRows, req.user.sub),
    ]);
    const roomNames = new Map();
    for (const r of kept) {
      if (!roomNames.has(r.room.id)) roomNames.set(r.room.id, await roomDisplayName(r.room, req.user.sub));
    }
    const hasMore = rows.length > q.limit;
    const last = kept[kept.length - 1];
    res.json({
      items: kept.map((r, i) => ({
        ...toMessageDto({ ...withPolls[i], attachments: attachmentsByMessage[r.message.id] }),
        roomName: roomNames.get(r.room.id) ?? null,
      })),
      hasMore,
      total,
      nextBefore: hasMore && last ? formatCursor(Number(last.cursorKey), last.pollId) : null,
    });
  });

  router.put('/polls/:pollId/vote', async (req, res) => {
    const ctx = await requirePollMember(req, res);
    if (!ctx) return;
    const { poll, message } = ctx;

    const optionIds = req.body?.optionIds;
    if (!Array.isArray(optionIds) || optionIds.some((id) => typeof id !== 'string')) {
      return res.status(400).json({ error: 'optionIds는 보기 id 배열이어야 합니다.' });
    }
    const chosen = [...new Set(optionIds)];
    if (!poll.multiple && chosen.length > 1) {
      return res.status(400).json({ error: '이 투표는 하나만 고를 수 있습니다.' });
    }
    const options = await listOptionsForPolls([poll.id]);
    const validIds = new Set(options.map((o) => o.id));
    if (chosen.some((id) => !validIds.has(id))) {
      return res.status(400).json({ error: '이 투표의 보기가 아닙니다.' });
    }
    if (isPollClosed(poll)) return res.status(400).json({ error: '마감된 투표입니다.' });

    const outcome = await replaceMyVotes(poll.id, req.user.sub, chosen);
    if (outcome.missing) return res.status(404).json({ error: '투표를 찾을 수 없습니다.' });
    if (outcome.closed) return res.status(400).json({ error: '마감된 투표입니다.' });

    // 방에는 집계만, "내가 고른 보기"는 내 기기들(user 룸)에만 — 익명 투표에서 누가 무엇을 골랐는지가
    // 소켓으로 방 전체에 새지 않게(pollListRules.js의 emitPollVoteUpdate).
    emitPollVoteUpdate(io, {
      roomId: poll.roomId,
      messageId: message.id,
      pollId: poll.id,
      poll: await neutralPollDto(poll),
      voterId: req.user.sub,
      optionIds: chosen,
    });
    res.json((await loadPollDtos([poll], req.user.sub)).get(poll.id));
  });

  router.post('/polls/:pollId/close', async (req, res) => {
    const ctx = await requirePollMember(req, res);
    if (!ctx) return;
    const { poll, message, room } = ctx;

    // 만든 사람, 또는 그 방을 관리할 수 있는 사람(팀 소유자/계정 등급 관리자, 토픽이면 토픽 관리자).
    if (poll.creatorId !== req.user.sub) {
      const access = await topicAccess(room, req.user.sub);
      if (!access.canManage && !(access.isMember && canManageTeam(access))) {
        return res.status(403).json({ error: '투표를 만든 사람이나 관리자만 마감할 수 있습니다.' });
      }
    }
    if (isPollClosed(poll)) return res.status(400).json({ error: '이미 마감된 투표입니다.' });

    const closed = await closePollEarly(poll.id, req.user.sub);
    if (!closed) return res.status(400).json({ error: '이미 마감된 투표입니다.' });

    io.to(poll.roomId).emit(
      'poll:updated',
      pollRoomUpdate({ roomId: poll.roomId, messageId: message.id, pollId: poll.id, poll: await neutralPollDto(closed) }),
    );
    const closer = await findUserById(req.user.sub);
    await postSystemMessage(
      io,
      room,
      `${closer?.name ?? closer?.username ?? '알 수 없음'} 님이 투표 '${poll.title}'을(를) 마감했습니다.`,
    );
    res.json((await loadPollDtos([closed], req.user.sub)).get(closed.id));
  });

  router.put('/polls/:pollId/favorite', async (req, res) => {
    const ctx = await requirePollMember(req, res);
    if (!ctx) return;
    const { poll, message } = ctx;
    if (typeof req.body?.favorite !== 'boolean') {
      return res.status(400).json({ error: 'favorite는 true/false여야 합니다.' });
    }
    await setPollFavorite(poll.id, req.user.sub, req.body.favorite);
    // 즐겨찾기는 사람마다 따로라서 방 전체가 아니라 내 다른 기기에만 알린다(다른 개인 설정과 같은 방식).
    io.to(`user:${req.user.sub}`).emit('poll:favorite', {
      messageId: message.id,
      pollId: poll.id,
      favorite: req.body.favorite,
    });
    res.json({ favorite: req.body.favorite });
  });

  return router;
}
