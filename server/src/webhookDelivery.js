import { randomUUID } from 'node:crypto';
import { decryptField } from './crypto.js';
import {
  deleteDeliveriesBefore,
  failPendingDeliveries,
  findIntegrationById,
  insertDeliveries,
  listDueDeliveries,
  listEventTargets,
  markDeliveryGaveUp,
  markDeliverySucceeded,
  updateDelivery,
} from './db/queries/integrations.js';
import { findRoomById } from './db/queries/rooms.js';
import {
  DELIVERY_AUTO_DISABLE,
  DELIVERY_TIMEOUT_MS,
  deliveryErrorText,
  eventEnvelope,
  integrationWantsEvent,
  nextDeliveryAttemptAt,
  PING_EVENT,
  roomAcceptsIntegrations,
} from './integrationRules.js';
import { signedPost } from './outbound.js';
import { publicCommentDto, publicMessageDto, publicRoomDto, publicTodoDto } from './publicDtos.js';

/**
 * 나가는 웹훅·연동 앱으로 **방의 일을 바깥에 알리기** — 새 메시지·고침·지움, 멘션, 댓글, 할 일. 일이 생긴 곳(sendMessage.js·rooms.js
 * postBotMessage·messages.js·comments.js·todos.js)이 아래 notify*를 부르면, 그 방의 나가는 웹훅과 그 방에 추가된 앱 중 그 일을 고른 것마다
 * 보내기 기록(webhook_deliveries)을 남기고 바로 보낸다. 실패하면(2xx가 아님·연결 실패·시간 초과) 10초·1분·5분·30분·2시간·6시간 뒤
 * 다시 보내고, 그래도 안 되면 실패로 끝낸다 — 그렇게 끝난 일이 연달아 10개면 그 연동을 끈다(화면에서 다시 켠다).
 *
 * 보내는 모양: POST JSON `{ id, type, createdAt, teamId, roomId, data }`(integrationRules.js eventEnvelope — data는 publicDtos.js의 공개
 * API 모양), 헤더 X-TangoTalk-Event·X-TangoTalk-Delivery(같은 일을 다시 보내도 같은 값)·X-TangoTalk-Timestamp·X-TangoTalk-Signature
 * (outbound.js). 비밀 대화·1:1·나와의 대화에는 연동이 붙지 않으므로 그 방의 일은 보내지 않는다.
 *
 * 일을 알리는 쪽을 기다리게 하지 않는다 — 모든 notify*는 실패해도 throw하지 않고 기록만 남긴다. 서버 한 개(pm2 한 프로세스)에서 도는
 * 것을 전제로 한다(보내는 중인 것을 메모리로 거른다).
 */

const TICK_MS = 5000;
const BATCH = 20;
const PARALLEL = 5;
const KEEP_MS = 7 * 24 * 60 * 60 * 1000;
const inFlight = new Set();
let ticking = false;
let kickTimer = null;

/** 이 방의 [type] 일을 받을 연동마다 보내기를 남기고 곧 보낸다. [sourceIntegrationId](그 일을 만든 봇)에게는 다시 보내지 않는다. */
async function enqueue(room, type, data, { sourceIntegrationId = null } = {}) {
  if (!room || !roomAcceptsIntegrations(room)) return;
  const targets = (await listEventTargets(room.id)).filter((t) => t.id !== sourceIntegrationId && integrationWantsEvent(t, type));
  if (targets.length === 0) return;
  const now = Date.now();
  await insertDeliveries(
    targets.map((t) => {
      const id = randomUUID();
      return { id, integrationId: t.id, event: type, payload: eventEnvelope({ id, type, teamId: room.teamId, roomId: room.id, data, now }) };
    }),
  );
  kick();
}

/** 실패해도 일을 알린 쪽은 모르게 — 기록만. */
function fireAndForget(promise, what) {
  promise.catch((err) => console.error(`[webhooks] ${what} 알림을 남기지 못했습니다:`, err?.message ?? err));
}

const roomData = (room) => publicRoomDto(room);

/** 멘션이 있으면 'mention'도 — 누구를 멘션했는지는 data.mentions. */
function enqueueMention(room, dataKey, dto, opts) {
  if (!dto.mentions?.length) return Promise.resolve();
  return enqueue(room, 'mention', { room: roomData(room), [dataKey]: dto, mentions: dto.mentions }, opts);
}

/** 새 메시지(사람·봇) — [message]는 DB 행이나 메시지 DTO. 봇이 올린 것이면 [sourceIntegrationId]에 그 연동. */
export function notifyMessageCreated(room, message, { sourceIntegrationId = null } = {}) {
  if (!room || room.isSecret || message.type === 'system') return;
  const dto = publicMessageDto(message);
  const opts = { sourceIntegrationId };
  fireAndForget(
    enqueue(room, 'message.created', { room: roomData(room), message: dto }, opts).then(() => enqueueMention(room, 'message', dto, opts)),
    '새 메시지',
  );
}

export function notifyMessageUpdated(room, message, { sourceIntegrationId = null } = {}) {
  if (!room || room.isSecret) return;
  fireAndForget(enqueue(room, 'message.updated', { room: roomData(room), message: publicMessageDto(message) }, { sourceIntegrationId }), '메시지 고침');
}

export function notifyMessageDeleted(room, messageId, { sourceIntegrationId = null } = {}) {
  if (!room || room.isSecret) return;
  fireAndForget(enqueue(room, 'message.deleted', { room: roomData(room), messageId }, { sourceIntegrationId }), '메시지 지움');
}

export function notifyCommentCreated(room, comment) {
  if (!room || room.isSecret) return;
  const dto = publicCommentDto(comment);
  fireAndForget(
    enqueue(room, 'comment.created', { room: roomData(room), comment: dto }).then(() => enqueueMention(room, 'comment', dto)),
    '새 댓글',
  );
}

/** 할 일 만들기·고치기·지우기([kind] 'created' | 'updated' | 'deleted' — todos.js emitChanged의 종류). 그 밖의 종류는 보내지 않는다. */
export function notifyTodoChanged(todo, kind, { room = null } = {}) {
  if (!['created', 'updated', 'deleted'].includes(kind)) return;
  fireAndForget(
    (async () => {
      const r = room ?? (await findRoomById(todo.roomId));
      await enqueue(r, `todo.${kind}`, { room: r ? roomData(r) : null, todo: publicTodoDto(todo) });
    })(),
    '할 일',
  );
}

// ── 보내기 ──────────────────────────────────────────────────────────────

/** 곧(같은 차례에 쌓인 것을 모아) 보내기를 돌린다. */
function kick() {
  if (kickTimer) return;
  kickTimer = setTimeout(() => {
    kickTimer = null;
    tick().catch((err) => console.error('[webhooks] 보내기 실패:', err?.message ?? err));
  }, 50);
}

/**
 * 보내기 기록 한 건을 한 번 보낸다 — 성공하면 delivered, 실패하면 다음 시도를 잡거나(retry) 실패로 끝낸다. 바뀐 기록을 돌려준다.
 * [retry]가 false면(시험 보내기) 한 번으로 끝낸다.
 */
async function attempt(delivery, { retry = true } = {}) {
  const row = await findIntegrationById(delivery.integrationId);
  if (!row) return null; // 연동을 지웠다 — 기록도 같이 지워졌다.
  const attempts = delivery.attempts + 1;
  if ((!row.enabled && delivery.event !== PING_EVENT) || !row.url) {
    return updateDelivery(delivery.id, { status: 'failed', attempts, lastError: '연동이 꺼져 있거나 보낼 주소가 없습니다.' });
  }
  let status = null;
  let error = null;
  try {
    const res = await signedPost({
      url: row.url,
      body: JSON.stringify(delivery.payload),
      secret: decryptField(row.secretEnc) ?? '',
      allowPrivate: row.allowPrivate,
      headers: { 'x-tangotalk-event': delivery.event, 'x-tangotalk-delivery': delivery.id },
      timeoutMs: DELIVERY_TIMEOUT_MS,
      maxBytes: 4096,
    });
    status = res.status;
    if (status < 200 || status >= 300) error = `HTTP ${status}`;
  } catch (err) {
    error = deliveryErrorText(err);
  }
  if (!error) {
    await markDeliverySucceeded(row.id);
    return updateDelivery(delivery.id, { status: 'delivered', attempts, lastStatus: status, lastError: null, deliveredAt: new Date() });
  }
  const next = retry ? nextDeliveryAttemptAt(attempts) : null;
  if (next) {
    return updateDelivery(delivery.id, { attempts, lastStatus: status, lastError: error, nextAttemptAt: new Date(next) });
  }
  const updated = await updateDelivery(delivery.id, { status: 'failed', attempts, lastStatus: status, lastError: error });
  if (retry) {
    const after = await markDeliveryGaveUp(row.id, DELIVERY_AUTO_DISABLE);
    if (after && row.enabled && !after.enabled) {
      console.warn(`[webhooks] "${row.name}" 보내기가 연달아 ${DELIVERY_AUTO_DISABLE}번 실패해서 껐습니다.`);
      await failPendingDeliveries(row.id, '보내기가 계속 실패해서 연동을 껐습니다.');
    }
  }
  return updated;
}

/** 보낼 때가 된 것을 [BATCH]개씩, 한 번에 [PARALLEL]개까지 보낸다. 이미 돌고 있으면 건너뛴다. */
async function tick() {
  if (ticking) return;
  ticking = true;
  try {
    for (let round = 0; round < 10; round += 1) {
      const due = (await listDueDeliveries(new Date(), BATCH)).filter((d) => !inFlight.has(d.id));
      if (due.length === 0) break;
      for (let i = 0; i < due.length; i += PARALLEL) {
        await Promise.all(
          due.slice(i, i + PARALLEL).map(async (d) => {
            inFlight.add(d.id);
            try {
              await attempt(d);
            } catch (err) {
              console.error('[webhooks] 보내기 기록을 고치지 못했습니다:', err?.message ?? err);
            } finally {
              inFlight.delete(d.id);
            }
          }),
        );
      }
      if (due.length < BATCH) break;
    }
  } finally {
    ticking = false;
  }
}

/**
 * "보내 보기" — ping 일을 바로 한 번 보내고 그 기록을 돌려준다(다시 보내지 않는다, 꺼진 연동도 시험은 된다).
 * [row]는 나가는 웹훅이나 앱(보낼 주소가 있어야 한다).
 */
export async function sendTestDelivery(row, actorName) {
  const id = randomUUID();
  const [delivery] = await insertDeliveries([
    {
      id,
      integrationId: row.id,
      event: PING_EVENT,
      payload: eventEnvelope({
        id,
        type: PING_EVENT,
        teamId: row.teamId,
        roomId: row.roomId ?? null,
        data: { message: '시험 보내기입니다(TangoTalk).', integrationId: row.id, name: row.name, by: actorName },
      }),
    },
  ]);
  inFlight.add(id);
  try {
    return await attempt(delivery, { retry: false });
  } finally {
    inFlight.delete(id);
  }
}

/** 서버를 켤 때 한 번 — 5초마다 보낼 것을 보고, 한 시간마다 7일 지난 기록을 지운다. 서버가 꺼져 있던 동안 쌓인 것도 이어서 보낸다. */
export function startWebhookDeliveryJob() {
  setInterval(() => tick().catch((err) => console.error('[webhooks] 보내기 실패:', err?.message ?? err)), TICK_MS).unref();
  setInterval(
    () => deleteDeliveriesBefore(new Date(Date.now() - KEEP_MS)).catch((err) => console.error('[webhooks] 기록 정리 실패:', err?.message ?? err)),
    60 * 60 * 1000,
  ).unref();
  kick();
}
