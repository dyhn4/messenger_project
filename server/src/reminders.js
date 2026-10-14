import { Router } from 'express';
import { findMessageById } from './db/queries/messages.js';
import {
  claimDueReminders,
  countPendingReminders,
  deleteFiredRemindersBefore,
  deleteReminder,
  insertReminder,
  listPendingReminders,
} from './db/queries/reminders.js';
import { findRoomById, getDmHistoryFloor, isRoomMember } from './db/queries/rooms.js';
import { isTeamMember } from './db/queries/teams.js';
import { isUuid } from './favoritesRules.js';
import { previewFor } from './push.js';
import {
  memoReminderBotText,
  parseReminderText,
  parseRemindAt,
  REMINDER_MAX_PENDING,
  reminderBotText,
  reminderCardFor,
  reminderDenial,
} from './reminderRules.js';
import { openSelfRoom, postBotMessage } from './rooms.js';
import { SELF_ROOM_BOT_NAME } from './selfRoomNotices.js';

/**
 * 리마인더 — 두 가지다(규칙은 reminderRules.js).
 * - 메시지 리마인더("나중에 알림"): 메시지에 "1시간 뒤 / 내일 오전 9시에 다시 알려 줘"를 건다. 정한 시각이 되면 그 사람의 "나와의
 *   대화"에 탱고톡 봇 메시지로 원본 메시지 카드(reminderCard)를 올리고, 앱은 카드의 "메시지로 이동"으로 원본을 연다.
 * - 직접 만든 리마인더(메뉴의 "리마인더"): 메시지 없이 글만 — 정한 시각에 그 팀의 "나와의 대화"에 "⏰ 리마인더 — 글"을 올린다.
 * 안 읽음·방 목록·푸시·방해 금지는 다른 봇 안내와 똑같이 동작한다. 나만 보는 것이라 다른 사람에게는 알리지 않는다. 리마인더
 * 목록이 바뀌면 내 기기들에 reminder:changed를 보낸다(목록 화면이 다시 받는다).
 */

/** 예약 작업 간격 — 30초마다 울릴 때가 된 것을 찾는다(늦어도 30초). */
const SWEEP_INTERVAL_MS = 30 * 1000;
/** 울린 리마인더 행은 이만큼 지나면 지운다(목록에는 안 나오고 쌓이기만 한다). */
const FIRED_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;

/** 리마인더 응답 — 직접 만든 리마인더는 messageId·roomId가 null이고 text·teamId가 있다. */
function toReminderDto(reminder, message) {
  return {
    id: reminder.id,
    messageId: reminder.messageId ?? null,
    roomId: reminder.roomId ?? null,
    teamId: reminder.teamId ?? null,
    text: reminder.text ?? null,
    remindAt: new Date(reminder.remindAt).getTime(),
    createdAt: new Date(reminder.createdAt).getTime(),
    senderName: message?.senderName ?? null,
    preview: message ? previewFor(message) || null : null,
    sentAt: message ? new Date(message.createdAt).getTime() : null,
  };
}

/** 요청한 사람이 이 메시지에 리마인더를 걸 수 있는지 — 안 되면 { status, error }, 되면 { message, room }. */
async function loadForReminder(messageId, userId) {
  const message = isUuid(messageId) ? await findMessageById(messageId) : null;
  const room = message ? await findRoomById(message.roomId) : null;
  const isMember = room ? await isRoomMember(room.id, userId) : false;
  const floor = room?.type === 'dm' && isMember ? await getDmHistoryFloor(room.id, userId) : null;
  const denial = reminderDenial({ message, room, isMember, floor });
  return denial ?? { message, room };
}

export function createRemindersRouter(io) {
  const router = Router();
  const changed = (userId) => io.to(`user:${userId}`).emit('reminder:changed', {});

  /** 리마인더 걸기 — `{ remindAt }`(ms). 같은 메시지에 여러 개를 걸 수 있다(1시간 뒤와 내일 아침). */
  router.post('/messages/:id/reminders', async (req, res) => {
    const when = parseRemindAt(req.body?.remindAt, Date.now());
    if (when.error) return res.status(400).json({ error: when.error });
    const loaded = await loadForReminder(req.params.id, req.user.sub);
    if (loaded.status) return res.status(loaded.status).json({ error: loaded.error });
    if ((await countPendingReminders(req.user.sub)) >= REMINDER_MAX_PENDING) {
      return res.status(400).json({ error: `리마인더는 ${REMINDER_MAX_PENDING}개까지 걸어 둘 수 있습니다. 지난 것을 지운 뒤 다시 거세요.` });
    }
    const reminder = await insertReminder({
      userId: req.user.sub,
      messageId: loaded.message.id,
      roomId: loaded.room.id,
      remindAt: when.value,
    });
    changed(req.user.sub);
    res.status(201).json(toReminderDto(reminder, loaded.room.isSecret ? null : loaded.message));
  });

  /**
   * 직접 만든 리마인더 걸기 — `{ text, remindAt(ms), teamId }`. 울리면 [teamId] 팀의 "나와의 대화"에 올린다(그 팀의 멤버여야
   * 한다). 메시지 리마인더와 같은 개수 한도를 함께 쓴다.
   */
  router.post('/reminders', async (req, res) => {
    const text = parseReminderText(req.body?.text);
    if (text.error) return res.status(400).json({ error: text.error });
    const when = parseRemindAt(req.body?.remindAt, Date.now());
    if (when.error) return res.status(400).json({ error: when.error });
    const teamId = req.body?.teamId;
    if (!isUuid(teamId) || !(await isTeamMember(teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
    if ((await countPendingReminders(req.user.sub)) >= REMINDER_MAX_PENDING) {
      return res.status(400).json({ error: `리마인더는 ${REMINDER_MAX_PENDING}개까지 걸어 둘 수 있습니다. 지난 것을 지운 뒤 다시 거세요.` });
    }
    const reminder = await insertReminder({ userId: req.user.sub, teamId, text: text.value, remindAt: when.value });
    changed(req.user.sub);
    res.status(201).json(toReminderDto(reminder, null));
  });

  /** 아직 울리지 않은 내 리마인더 — 울릴 시각 순. 비밀 대화 메시지는 미리보기 없이, 원본이 지워진 메시지 리마인더는 빼고. */
  router.get('/reminders', async (req, res) => {
    const rows = await listPendingReminders(req.user.sub);
    const secretRooms = new Set();
    for (const { reminder } of rows) {
      if (reminder.roomId && !secretRooms.has(reminder.roomId)) {
        const room = await findRoomById(reminder.roomId);
        if (room?.isSecret) secretRooms.add(reminder.roomId);
      }
    }
    res.json(
      rows
        .filter(({ reminder, message }) => (reminder.messageId ? message && !message.deletedAt : true))
        .map(({ reminder, message }) => toReminderDto(reminder, secretRooms.has(reminder.roomId) ? null : message)),
    );
  });

  /** 리마인더 취소. */
  router.delete('/reminders/:id', async (req, res) => {
    if (!isUuid(req.params.id) || !(await deleteReminder(req.params.id, req.user.sub))) {
      return res.status(404).json({ error: '리마인더를 찾을 수 없습니다.' });
    }
    changed(req.user.sub);
    res.json({ ok: true });
  });

  return router;
}

/**
 * 울릴 때가 된 리마인더를 울린다 — 원본이 지워졌거나 그 사람이 방(직접 만든 리마인더는 팀)에서 빠졌으면 조용히 넘어간다(울림으로는
 * 찍힌다). 서버가 꺼져 있던 동안 지난 것은 켜진 뒤 첫 차례에 울린다. 메시지 리마인더는 "나와의 대화"(원본 방이 속한 팀의 것)에
 * 카드로, 직접 만든 리마인더는 정한 팀의 "나와의 대화"에 글로 올린다.
 */
export async function fireDueReminders(io, now = new Date()) {
  const due = await claimDueReminders(now);
  for (const reminder of due) {
    try {
      if (!reminder.messageId) {
        if (!reminder.teamId || !reminder.text || !(await isTeamMember(reminder.teamId, reminder.userId))) continue;
        const selfRoom = await openSelfRoom(io, reminder.userId, reminder.teamId);
        await postBotMessage(io, selfRoom, memoReminderBotText(reminder.text), { senderName: SELF_ROOM_BOT_NAME });
        io.to(`user:${reminder.userId}`).emit('reminder:changed', {});
        continue;
      }
      const message = await findMessageById(reminder.messageId);
      const room = message ? await findRoomById(reminder.roomId) : null;
      if (!message || message.deletedAt || !room || !(await isRoomMember(room.id, reminder.userId))) continue;
      const card = reminderCardFor({ message, room, preview: previewFor(message) });
      const selfRoom = await openSelfRoom(io, reminder.userId, room.teamId);
      await postBotMessage(io, selfRoom, reminderBotText(card), { senderName: SELF_ROOM_BOT_NAME, reminderCard: card });
      io.to(`user:${reminder.userId}`).emit('reminder:changed', {});
    } catch (err) {
      console.error('[reminder] 리마인더를 울리지 못했습니다:', err?.message ?? err);
    }
  }
  return due.length;
}

/** 서버를 켤 때 한 번(꺼져 있던 동안 지난 것), 그 뒤 30초마다. 울린 지 한 달 지난 행은 하루에 한 번 지운다. */
export function startReminderJob(io) {
  let running = false;
  const sweep = async () => {
    if (running) return;
    running = true;
    try {
      await fireDueReminders(io);
    } catch (err) {
      console.error('[reminder] 리마인더 확인 실패:', err?.message ?? err);
    } finally {
      running = false;
    }
  };
  sweep();
  setInterval(sweep, SWEEP_INTERVAL_MS).unref?.();
  const cleanup = () =>
    deleteFiredRemindersBefore(new Date(Date.now() - FIRED_RETENTION_MS)).catch((err) =>
      console.error('[reminder] 지난 리마인더 정리 실패:', err?.message ?? err),
    );
  cleanup();
  setInterval(cleanup, 24 * 60 * 60 * 1000).unref?.();
}
