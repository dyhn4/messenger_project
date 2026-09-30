import { randomUUID } from 'node:crypto';
import { Router } from 'express';
import { topicAccess } from './access.js';
import {
  claimDueScheduledMessages,
  claimScheduledMessage,
  deleteScheduledMessage,
  deleteScheduledMessageIfIdle,
  failInterruptedScheduledMessages,
  failScheduledMessages,
  findScheduledMessageById,
  insertScheduledMessageWithinLimit,
  listScheduledForRoom,
  listScheduledMessages,
  markScheduledMessageFailed,
  updateScheduledMessageIfIdle,
} from './db/queries/scheduledMessages.js';
import { findRoomById, isRoomMember } from './db/queries/rooms.js';
import { isTeamMember } from './db/queries/teams.js';
import { findUserById } from './db/queries/users.js';
import {
  graphemeLength,
  SCHEDULED_ATTACHMENT_MAX,
  SCHEDULED_MAX_AHEAD_MS,
  SCHEDULED_MAX_PER_TEAM,
  SCHEDULED_STEP_MS,
  SCHEDULED_TEXT_MAX,
  SCHEDULED_TITLE_MAX,
  topicWriteDenial,
} from './permissions.js';
import { roomDisplayName } from './rooms.js';
import { sendUserMessage } from './sendMessage.js';
import { sanitizeTextFormat } from './textFormat.js';
import { knownUploadPath, signFileUrl, toStoredUploadUrl } from './upload.js';

/**
 * 메시지 예약 발송 — 대화방·(보드 뷰면 제목)·메시지·첨부·발송 시각을 저장해 두면 그 시각에 서버가 내 이름으로
 * 대신 보낸다. 만든 사람만 보고 고친다. 보내는 길은 소켓 message:send와 같은 sendUserMessage(sendMessage.js)라
 * 규칙(보드 뷰 게시글, 읽기 전용·보관, 첨부, DM 되살리기, 푸시, 링크 미리보기)이 똑같다. 보냈으면 행을 지우고,
 * 못 보냈으면 'failed' + 이유로 남겨 목록의 '발송 실패'에 보여준다.
 *
 * 이벤트(전부 user:<만든 사람>에게만): scheduled:changed {teamId} — 만들기·고치기·취소·지금 보내기·발송 결과 뒤
 * (다른 기기가 목록을 다시 받는다), scheduled:sent {id, teamId, roomId, roomName, messageIds} / scheduled:failed
 * {id, teamId, roomId, roomName, reason} — 시각이 되어 서버가 보냈을 때와 보관·삭제로 미리 실패시켰을 때(알림용).
 * "지금 보내기"는 누른 화면이 응답으로 결과를 알기 때문에 sent/failed 없이 changed만 보낸다.
 */

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SWEEP_INTERVAL_MS = 20_000;
const SWEEP_BATCH = 50;

const LIMIT_ERROR = `예약 메시지는 최대 ${SCHEDULED_MAX_PER_TEAM}건까지 만들 수 있습니다.`;
const SECRET_ERROR = '비밀 대화에는 예약할 수 없습니다.';
const INVALID_ATTACHMENT_ERROR = '첨부 파일 정보가 올바르지 않습니다. 다시 올려주세요.';
const SENDING_ERROR = '지금 보내는 중인 예약 메시지는 바꿀 수 없습니다.';

// 발송 실패 이유 — 목록의 '발송 실패'와 scheduled:failed에 그대로 보인다.
const REASON_ROOM_DELETED = '대화방이 삭제되어 보내지 못했습니다.';
const REASON_NOT_MEMBER = '대화방의 멤버가 아니어서 보내지 못했습니다.';
const REASON_NOT_TEAM_MEMBER = '팀에서 제외되어 보내지 못했습니다.';
const REASON_ACCOUNT = '탈퇴했거나 정지된 계정이라 보내지 못했습니다.';
const REASON_ARCHIVED = '토픽이 보관되어 보낼 수 없습니다.';
const REASON_RESTARTED = '서버가 다시 시작되어 보냈는지 확인하지 못했습니다. 대화방을 확인한 뒤 다시 예약하세요.';
const REASON_ERROR = '보내는 중 오류가 발생했습니다. 다시 예약하세요.';

/** 응답 DTO — 첨부는 채팅 첨부처럼 응답할 때만 서명한다. 'sending'(막 보내는 중)은 화면에선 아직 예약됨이다. */
export function toScheduledDto(row) {
  const failed = row.status === 'failed';
  return {
    id: row.id,
    teamId: row.teamId,
    roomId: row.roomId ?? null,
    roomName: row.roomName ?? null,
    title: row.title ?? null,
    text: row.text,
    textFormat: row.textFormat ?? null,
    attachments: (Array.isArray(row.attachments) ? row.attachments : []).map((a) => ({
      id: a.id,
      kind: a.kind,
      fileUrl: signFileUrl(a.fileUrl, a.fileName),
      fileName: a.fileName ?? null,
      fileSize: a.fileSize ?? null,
      mimeType: a.mimeType ?? null,
      thumbnailUrl: signFileUrl(a.thumbnailUrl) ?? null,
    })),
    sendAt: new Date(row.sendAt).getTime(),
    status: failed ? 'failed' : 'scheduled',
    failReason: failed ? (row.failReason ?? null) : null,
    createdAt: new Date(row.createdAt).getTime(),
    updatedAt: new Date(row.updatedAt).getTime(),
  };
}

// ── 검사 ────────────────────────────────────────────────────────────────

/** 읽기 전용·보관된 토픽이면 토픽 관리자만 쓴다(message:send와 같은 문구). 쓸 수 있으면 null. */
async function writeDenial(room, userId) {
  if (room.type !== 'topic' || (!room.readOnly && !room.archivedAt)) return null;
  return topicWriteDenial({ room, canManage: (await topicAccess(room, userId)).canManage });
}

/** 보드 뷰 토픽은 게시글이라 제목이 필요하고(50자까지), 그 밖의 방은 제목을 쓰지 않는다. */
function parseTitle(raw, isBoard) {
  if (isBoard) {
    const title = typeof raw === 'string' ? raw.trim() : '';
    if (!title) return { error: '제목을 입력하세요.' };
    if (graphemeLength(title) > SCHEDULED_TITLE_MAX) {
      return { error: `제목은 ${SCHEDULED_TITLE_MAX}자 이내로 입력하세요.` };
    }
    return { value: title };
  }
  if (raw != null && (typeof raw !== 'string' || raw.trim())) {
    return { error: '제목은 보드 뷰 토픽에 올리는 게시글에만 쓸 수 있습니다.' };
  }
  return { value: null };
}

/** 메시지(게시글이면 본문) — 필수, 앞뒤 공백을 빼고 5000자까지. 뗀 앞 공백만큼 서식 구간 위치도 당긴다
 * (서식은 본문의 UTF-16 위치 기준 — textFormat.js). */
function parseMessageText(raw, rawFormat) {
  if (typeof raw !== 'string' || !raw.trim()) return { error: '메시지를 입력하세요.' };
  const lead = raw.length - raw.trimStart().length;
  const text = raw.trim();
  if (graphemeLength(text) > SCHEDULED_TEXT_MAX) {
    return { error: `메시지는 ${SCHEDULED_TEXT_MAX}자 이내로 입력하세요.` };
  }
  const shifted = Array.isArray(rawFormat)
    ? rawFormat.map((r) =>
        r && Number.isInteger(r.s) && Number.isInteger(r.e)
          ? { ...r, s: Math.max(0, r.s - lead), e: Math.min(text.length, r.e - lead) }
          : r,
      )
    : null;
  return { text, textFormat: sanitizeTextFormat(shifted, text) };
}

/**
 * 첨부 — 채팅 입력칸이 보내는 것과 같은 모양({kind, fileUrl, fileName, fileSize, mimeType, thumbnailUrl}), 10개까지.
 * 경로는 미서명 /uploads/ 로 저장한다. 수정 화면은 받아 둔 첨부(서명 링크)를 그대로 돌려보내므로, 이미 저장된
 * 첨부는 id로, id가 없으면(클라이언트 UploadedAttachment는 id를 안 싣는다) 링크가 가리키는 파일로 찾아 원래
 * 경로를 그대로 쓴다 — 그사이 서명이 만료됐어도 첨부가 빠지지 않는다(이 예약에 원래 있던 파일만 그렇게 받는다).
 */
function parseAttachments(raw, existing = []) {
  if (raw == null) return { value: [] };
  if (!Array.isArray(raw)) return { error: INVALID_ATTACHMENT_ERROR };
  if (raw.length > SCHEDULED_ATTACHMENT_MAX) {
    return { error: `첨부 파일은 ${SCHEDULED_ATTACHMENT_MAX}개까지 올릴 수 있습니다.` };
  }
  const existingList = Array.isArray(existing) ? existing : [];
  const saved = new Map(existingList.map((a) => [a.id, a]));
  const savedByPath = new Map(existingList.map((a) => [a.fileUrl, a]));
  const value = [];
  for (const a of raw) {
    if (!a || typeof a !== 'object') return { error: INVALID_ATTACHMENT_ERROR };
    const kept = (typeof a.id === 'string' ? saved.get(a.id) : null) ?? savedByPath.get(knownUploadPath(a.fileUrl));
    if (kept) {
      value.push(kept);
      continue;
    }
    const fileUrl = toStoredUploadUrl(typeof a.fileUrl === 'string' ? a.fileUrl : null);
    if (!fileUrl) return { error: INVALID_ATTACHMENT_ERROR };
    const mimeType = typeof a.mimeType === 'string' ? a.mimeType : null;
    value.push({
      id: randomUUID(),
      // kind를 안 보냈으면 형식으로 가른다(사진은 한 말풍선 격자, 나머지는 파일로 보낸다).
      kind: a.kind === 'image' || a.kind === 'file' ? a.kind : mimeType?.startsWith('image/') ? 'image' : 'file',
      fileUrl,
      fileName: typeof a.fileName === 'string' ? a.fileName : null,
      fileSize: typeof a.fileSize === 'number' && Number.isFinite(a.fileSize) ? a.fileSize : null,
      mimeType,
      thumbnailUrl: typeof a.thumbnailUrl === 'string' ? toStoredUploadUrl(a.thumbnailUrl) : null,
    });
  }
  return { value };
}

/** 발송 시각(epoch ms) — 15분 단위, 지금 이후, 90일 뒤까지. */
function parseSendAt(raw) {
  let ms = NaN;
  if (typeof raw === 'number') ms = raw;
  else if (typeof raw === 'string' && raw.trim()) ms = /^\d+$/.test(raw.trim()) ? Number(raw) : Date.parse(raw);
  if (!Number.isFinite(ms)) return { error: '발송 시간을 선택하세요.' };
  if (ms % SCHEDULED_STEP_MS !== 0) return { error: '발송 시간은 15분 단위로 선택하세요.' };
  const now = Date.now();
  if (ms <= now) return { error: '발송 시간은 지금 이후로 선택하세요.' };
  if (ms > now + SCHEDULED_MAX_AHEAD_MS) return { error: '최대 90일 뒤까지만 예약할 수 있습니다.' };
  return { value: new Date(ms) };
}

/**
 * 예약 내용 검사(만들기·고치기 공용) — 통과하면 저장할 칸들 `{ fields }`, 아니면 `{ error }`. 팀은 방이 속한 팀이다.
 * 보낼 때(deliver)도 방·멤버·쓰기 권한은 다시 본다(그사이 나가거나 읽기 전용이 됐을 수 있다).
 */
async function validateScheduled(userId, input, existing = null) {
  const room = typeof input.roomId === 'string' && input.roomId ? await findRoomById(input.roomId) : null;
  if (!room) return { error: '대화방을 찾을 수 없습니다.' };
  if (!(await isRoomMember(room.id, userId))) return { error: '이 방의 멤버가 아닙니다.' };
  if (!(await isTeamMember(room.teamId, userId))) return { error: '이 팀의 멤버가 아닙니다.' };
  if (room.isSecret) return { error: SECRET_ERROR };
  const denial = await writeDenial(room, userId);
  if (denial) return { error: denial };

  // 고치면서 제목을 안 보냈으면(undefined) 지금 제목을 그대로 쓰되, 보드 뷰가 아닌 방으로 옮기면 쓸 곳이 없어 버린다.
  const isBoard = room.type === 'topic' && room.viewMode === 'board';
  const rawTitle = input.title !== undefined ? input.title : isBoard ? (existing?.title ?? null) : null;
  const title = parseTitle(rawTitle, isBoard);
  if (title.error) return title;
  const text = parseMessageText(input.text, input.textFormat);
  if (text.error) return text;
  const attachments = parseAttachments(input.attachments, existing?.attachments);
  if (attachments.error) return attachments;
  const sendAt = parseSendAt(input.sendAt);
  if (sendAt.error) return sendAt;

  return {
    fields: {
      teamId: room.teamId,
      roomId: room.id,
      roomName: await roomDisplayName(room, userId),
      title: title.value,
      text: text.text,
      textFormat: text.textFormat,
      attachments: attachments.value,
      sendAt: sendAt.value,
    },
  };
}

// ── 보내기 ──────────────────────────────────────────────────────────────

/** 지금 보낼 수 없는 이유 — 보낼 수 있으면 null. 만들 때 통과했어도 그사이 바뀌었을 수 있어 보낼 때마다 다시 본다. */
async function sendBlockReason(row, room) {
  if (!room) return REASON_ROOM_DELETED;
  const owner = await findUserById(row.userId);
  if (!owner || owner.deletedAt || owner.suspendedAt) return REASON_ACCOUNT;
  if (!(await isTeamMember(room.teamId, row.userId))) return REASON_NOT_TEAM_MEMBER;
  if (!(await isRoomMember(room.id, row.userId))) return REASON_NOT_MEMBER;
  if (room.isSecret) return SECRET_ERROR;
  return writeDenial(room, row.userId);
}

/**
 * 예약 한 건을 채팅 입력칸과 같은 모양의 message:send 묶음으로 바꾼다 — 보드 뷰 토픽은 게시글 하나(제목·본문·첨부),
 * 그 밖의 방은 첨부를 먼저(입력칸처럼 사진은 한 말풍선 — 여러 장이면 격자, 나머지 파일도 한 말풍선 — 여러 개면
 * 목록) 보내고 메시지는 마지막에 따로 한 통.
 */
function payloadsFor(row, room) {
  const attachments = Array.isArray(row.attachments) ? row.attachments : [];
  const toPayload = (a) => ({
    kind: a.kind,
    fileUrl: a.fileUrl,
    fileName: a.fileName,
    fileSize: a.fileSize,
    mimeType: a.mimeType,
    thumbnailUrl: a.thumbnailUrl,
  });
  if (room.type === 'topic' && room.viewMode === 'board') {
    return [
      {
        roomId: room.id,
        type: 'post',
        title: row.title,
        text: row.text,
        textFormat: row.textFormat,
        attachments: attachments.map(toPayload),
      },
    ];
  }
  const payloads = [];
  // 한 개면 입력칸의 sendUploadedAttachment처럼 파일 칸에, 여러 개면 sendUploadedAttachments처럼 목록으로.
  const bubble = (items, type) => {
    if (items.length === 1) {
      const { fileUrl, fileName, fileSize, mimeType, thumbnailUrl } = items[0];
      payloads.push({ roomId: room.id, type, fileUrl, fileName, fileSize, mimeType, thumbnailUrl });
    } else if (items.length > 1) {
      payloads.push({ roomId: room.id, type, attachments: items.map(toPayload) });
    }
  };
  bubble(attachments.filter((a) => a.kind === 'image'), 'image');
  bubble(attachments.filter((a) => a.kind !== 'image'), 'file');
  payloads.push({ roomId: room.id, type: 'text', text: row.text, textFormat: row.textFormat });
  return payloads;
}

/**
 * 'sending'으로 찜한 예약 한 건을 보낸다. 보냈으면 행을 지우고, 못 보냈으면 발송 실패 + 이유로 남긴다.
 * [announce]면(시각이 되어 서버가 보낸 경우) scheduled:sent/failed로 알리고, 어느 쪽이든 scheduled:changed를 보낸다.
 * 결과: `{ ok: true, messageIds }` 또는 `{ ok: false, reason, messageIds }`.
 */
async function deliver(io, row, { announce }) {
  let room = null;
  let reason = null;
  const messageIds = [];
  try {
    room = row.roomId ? await findRoomById(row.roomId) : null;
    reason = await sendBlockReason(row, room);
    if (!reason) {
      for (const payload of payloadsFor(row, room)) {
        const result = await sendUserMessage({ io, senderId: row.userId, payload, room, fallbackName: '알 수 없음' });
        if (!result.ok) {
          reason = result.error;
          break;
        }
        messageIds.push(result.message.id);
      }
    }
  } catch (err) {
    console.error('[scheduled] 예약 메시지 발송 오류:', err?.message ?? err);
    reason = REASON_ERROR;
  }
  // 첨부 말풍선은 나갔는데 뒤의 메시지가 막힌 드문 경우 — 다시 보내면 겹치니 이미 보낸 게 있다고 알려준다.
  if (reason && messageIds.length > 0) reason = `${reason} (일부는 이미 보냈습니다.)`;

  const roomName = room ? await roomDisplayName(room, row.userId).catch(() => row.roomName) : row.roomName;
  const base = { id: row.id, teamId: row.teamId, roomId: room?.id ?? row.roomId ?? null, roomName: roomName ?? null };
  const toOwner = io.to(`user:${row.userId}`);
  if (reason) {
    await markScheduledMessageFailed(row.id, reason, room ? roomName : undefined);
    if (announce) toOwner.emit('scheduled:failed', { ...base, reason });
  } else {
    await deleteScheduledMessage(row.id);
    if (announce) toOwner.emit('scheduled:sent', { ...base, messageIds });
  }
  toOwner.emit('scheduled:changed', { teamId: row.teamId });
  return reason ? { ok: false, reason, messageIds } : { ok: true, messageIds };
}

/** 미리 실패로 돌린 예약들을(보관·삭제·재시작) 주인에게 알린다 — 한 건마다 failed, 사람마다 changed 한 번. */
function announceFailed(io, rows, { roomId, roomName } = {}) {
  const changed = new Map();
  for (const row of rows) {
    io.to(`user:${row.userId}`).emit('scheduled:failed', {
      id: row.id,
      teamId: row.teamId,
      roomId: roomId ?? row.roomId ?? null,
      roomName: roomName ?? row.roomName ?? null,
      reason: row.failReason,
    });
    changed.set(`${row.userId}:${row.teamId}`, row);
  }
  for (const row of changed.values()) io.to(`user:${row.userId}`).emit('scheduled:changed', { teamId: row.teamId });
}

// 한 번에 한 바퀴만 — 이전 바퀴가 길어져도 겹쳐 돌지 않게.
let sweeping = false;

/** 보낼 시각이 된 예약을 찜해서(여러 번에 걸쳐 SWEEP_BATCH건씩) 보낸다. 보낸(시도한) 건수를 돌려준다. */
export async function runScheduledMessageSweep(io) {
  if (sweeping) return 0;
  sweeping = true;
  try {
    let total = 0;
    for (;;) {
      const rows = await claimDueScheduledMessages(SWEEP_BATCH);
      for (const row of rows) {
        // 한 건이 DB 오류 등으로 터져도 같이 찜한 나머지는 계속 보낸다 — 그 건은 실패로라도 남겨 둔다
        // (그마저 안 되면 'sending'으로 남았다가 다음 재시작 때 실패로 정리된다).
        await deliver(io, row, { announce: true }).catch(async (err) => {
          console.error('[scheduled] 예약 메시지 처리 실패:', err?.message ?? err);
          await markScheduledMessageFailed(row.id, REASON_ERROR).catch(() => {});
        });
      }
      total += rows.length;
      if (rows.length < SWEEP_BATCH) return total;
    }
  } finally {
    sweeping = false;
  }
}

/** 서버가 보내던 도중 꺼졌던 예약('sending'으로 남은 행) — 실제로 나갔는지 알 수 없으니 두 번 보내지 않도록
 * 다시 보내지 않고 실패로 돌려 확인하게 한다. */
export async function recoverInterruptedScheduledMessages(io) {
  const rows = await failInterruptedScheduledMessages(REASON_RESTARTED);
  announceFailed(io, rows);
  return rows.length;
}

/** 서버 시작 시 — 먼저 끊겼던 발송을 정리하고, 그 뒤로 SWEEP_INTERVAL_MS마다 보낼 시각이 된 예약을 보낸다. */
export function startScheduledMessageJob(io) {
  const sweep = () =>
    runScheduledMessageSweep(io).catch((e) => console.error('[scheduled] 예약 메시지 발송 실패:', e));
  recoverInterruptedScheduledMessages(io)
    .catch((e) => console.error('[scheduled] 끊긴 발송 정리 실패:', e))
    .finally(() => {
      sweep();
      setInterval(sweep, SWEEP_INTERVAL_MS);
    });
}

/**
 * 토픽을 보관하면 토픽 관리자가 아닌 사람들의 예약은 더 이상 보낼 수 없다 — 보낼 시각을 기다리지 않고 지금 실패로
 * 돌려 알린다(토픽 관리자 본인들의 예약은 그대로 나간다). 실패해도 보관 자체는 막지 않는다.
 */
export async function failScheduledForArchivedTopic(io, room) {
  try {
    const byUser = new Map();
    for (const row of await listScheduledForRoom(room.id)) {
      byUser.set(row.userId, [...(byUser.get(row.userId) ?? []), row.id]);
    }
    for (const [userId, ids] of byUser) {
      if ((await topicAccess(room, userId)).canManage) continue;
      const failed = await failScheduledMessages(ids, REASON_ARCHIVED);
      announceFailed(io, failed, { roomId: room.id, roomName: room.name ?? undefined });
    }
  } catch (err) {
    console.error('[scheduled] 보관된 토픽의 예약 정리 실패:', err?.message ?? err);
  }
}

/** 방을 지웠을 때 — 지우기 전에 골라 둔 그 방의 예약([rows])을 실패로 돌려 알린다(방 id는 이미 비워졌다). */
export async function failScheduledForDeletedRoom(io, room, rows) {
  try {
    const failed = await failScheduledMessages(rows.map((r) => r.id), REASON_ROOM_DELETED);
    announceFailed(io, failed, { roomId: room.id });
  } catch (err) {
    console.error('[scheduled] 삭제된 방의 예약 정리 실패:', err?.message ?? err);
  }
}

// ── 라우터 ──────────────────────────────────────────────────────────────

export function createScheduledMessagesRouter(io) {
  const router = Router();

  const notifyChanged = (userId, teamId) => io.to(`user:${userId}`).emit('scheduled:changed', { teamId });

  /** 내 예약만 — 남의 예약은 있는지조차 알려주지 않는다(404). uuid 모양이 아니면 DB 형식 오류 대신 같은 404. */
  async function requireMine(req, res) {
    const id = req.params.id;
    const row = UUID_RE.test(id) ? await findScheduledMessageById(id) : null;
    if (!row || row.userId !== req.user.sub) {
      res.status(404).json({ error: '예약 메시지를 찾을 수 없습니다.' });
      return null;
    }
    return row;
  }

  /** 그 팀의 내 예약 — 발송 실패 먼저, 그다음 보낼 시각 순. roomId를 주면 그 방 것만. */
  router.get('/scheduled-messages', async (req, res) => {
    const teamId = typeof req.query.teamId === 'string' ? req.query.teamId : null;
    if (!teamId) return res.status(400).json({ error: 'teamId가 필요합니다.' });
    if (!UUID_RE.test(teamId) || !(await isTeamMember(teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    const roomId = typeof req.query.roomId === 'string' && req.query.roomId ? req.query.roomId : null;
    const rows = await listScheduledMessages({ userId: req.user.sub, teamId, roomId });
    res.json(rows.map(toScheduledDto));
  });

  /** 예약 만들기 — { roomId, title?, text, textFormat?, attachments?, sendAt(ms) }. */
  router.post('/scheduled-messages', async (req, res) => {
    const checked = await validateScheduled(req.user.sub, req.body ?? {});
    if (checked.error) return res.status(400).json({ error: checked.error });
    const row = await insertScheduledMessageWithinLimit(
      { ...checked.fields, userId: req.user.sub, status: 'scheduled' },
      SCHEDULED_MAX_PER_TEAM,
    );
    if (!row) return res.status(400).json({ error: LIMIT_ERROR });
    notifyChanged(req.user.sub, row.teamId);
    res.status(201).json(toScheduledDto(row));
  });

  /**
   * 예약 고치기(보낸 칸만 — 대화방·발송 시각 포함) — 예약됨/발송 실패일 때만. 전부 다시 검사하고 예약됨으로 되돌린다
   * (발송 실패를 고쳐 다시 예약하는 길). 본문을 바꾸면서 서식을 안 보냈으면 옛 서식은 위치가 안 맞아 버린다.
   */
  router.patch('/scheduled-messages/:id', async (req, res) => {
    const row = await requireMine(req, res);
    if (!row) return;
    if (row.status === 'sending') return res.status(409).json({ error: SENDING_ERROR });
    const body = req.body ?? {};
    const input = {
      roomId: 'roomId' in body ? body.roomId : row.roomId,
      title: 'title' in body ? body.title : undefined, // 안 보냈으면 validateScheduled가 지금 제목을 쓴다
      text: 'text' in body ? body.text : row.text,
      textFormat: 'textFormat' in body ? body.textFormat : 'text' in body ? null : row.textFormat,
      attachments: 'attachments' in body ? body.attachments : row.attachments,
      sendAt: 'sendAt' in body ? body.sendAt : new Date(row.sendAt).getTime(),
    };
    const checked = await validateScheduled(req.user.sub, input, row);
    if (checked.error) return res.status(400).json({ error: checked.error });
    const movedTeam = checked.fields.teamId !== row.teamId;
    const updated = await updateScheduledMessageIfIdle(
      row.id,
      { ...checked.fields, status: 'scheduled', failReason: null },
      { limit: movedTeam ? { userId: req.user.sub, teamId: checked.fields.teamId, max: SCHEDULED_MAX_PER_TEAM } : null },
    );
    if (updated === 'limit') return res.status(400).json({ error: LIMIT_ERROR });
    if (!updated) return res.status(409).json({ error: SENDING_ERROR });
    notifyChanged(req.user.sub, updated.teamId);
    if (movedTeam) notifyChanged(req.user.sub, row.teamId);
    res.json(toScheduledDto(updated));
  });

  /** 예약 취소. */
  router.delete('/scheduled-messages/:id', async (req, res) => {
    const row = await requireMine(req, res);
    if (!row) return;
    if (!(await deleteScheduledMessageIfIdle(row.id))) return res.status(409).json({ error: SENDING_ERROR });
    notifyChanged(req.user.sub, row.teamId);
    res.json({ ok: true });
  });

  /** 지금 보내기 — 시각을 기다리지 않고 같은 규칙으로 바로 보낸다. 보냈으면 행이 지워지고, 못 보냈으면 발송 실패 +
   * 그 이유로 남기고 400 { error: 이유 }. */
  router.post('/scheduled-messages/:id/send-now', async (req, res) => {
    const row = await requireMine(req, res);
    if (!row) return;
    const claimed = await claimScheduledMessage(row.id, req.user.sub);
    if (!claimed) return res.status(409).json({ error: SENDING_ERROR });
    const outcome = await deliver(io, claimed, { announce: false });
    if (!outcome.ok) return res.status(400).json({ error: outcome.reason });
    res.json({ ok: true, messageIds: outcome.messageIds });
  });

  return router;
}
