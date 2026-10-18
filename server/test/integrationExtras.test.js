// 외부 연동 후속 — 단추 누름의 답 읽기, 나가는 일 종류·다시 보내기 간격·봉투, 사내 주소 허용, 바깥 그림 주소 모으기, 공인 주소 검사,
// 공개 API의 바깥 모양, 앱 라우터를 안에서 부르기. `node --test test/*.test.js`(DB·네트워크 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { Router } from 'express';
import {
  DELIVERY_MAX_ATTEMPTS,
  DELIVERY_RETRY_DELAYS_MS,
  eventEnvelope,
  integrationWantsEvent,
  interactionUrlOf,
  INTEGRATION_EVENTS,
  mayReachPrivate,
  nextDeliveryAttemptAt,
  PAYLOAD_IMAGES_MAX,
  parseEvents,
  parseInteractionResponse,
  webhookPayloadToMessage,
} from '../src/integrationRules.js';
import { internalCall } from '../src/internalCall.js';
import { checkPublicUrl } from '../src/linkPreview.js';
import { pickFields, publicCommentDto, publicEventDto, publicMessageDto, publicTodoDto } from '../src/publicDtos.js';

const json = (o) => ({ status: 200, contentType: 'application/json', bodyText: JSON.stringify(o) });

test('단추 누름의 답 — 지우기·바꾸기·방에 올리기·나에게만·빈 답·오류', () => {
  assert.deepEqual(parseInteractionResponse(json({ delete_original: true })), { remove: true });
  const replaced = parseInteractionResponse(json({ replace_original: true, blocks: [{ type: 'section', text: '✅ 승인됨' }] }));
  assert.deepEqual(replaced, { replace: { text: '✅ 승인됨', blocks: [{ type: 'section', text: '✅ 승인됨', fields: [], accessory: null }] } });
  assert.deepEqual(parseInteractionResponse(json({ response_type: 'in_channel', text: '배포 시작' })), {
    post: { text: '배포 시작', blocks: null },
  });
  assert.deepEqual(parseInteractionResponse(json({ text: '권한이 없습니다' })), { ephemeral: '권한이 없습니다' });
  assert.deepEqual(parseInteractionResponse({ status: 200, contentType: 'text/plain', bodyText: '확인' }), { ephemeral: '확인' });
  assert.deepEqual(parseInteractionResponse({ status: 204 }), { empty: true });
  assert.deepEqual(parseInteractionResponse(json({})), { empty: true });
  assert.ok(parseInteractionResponse({ status: 500, bodyText: '' }).error);
  assert.ok(parseInteractionResponse({ status: 200, contentType: 'application/json', bodyText: '{깨짐' }).error);
});

test('나가는 일 종류 — 하나 이상, 아는 것만, 정해진 순서로', () => {
  assert.deepEqual(parseEvents(['mention', 'message.created', 'mention']), { events: ['message.created', 'mention'] });
  assert.ok(parseEvents([]).error);
  assert.ok(parseEvents(['message.created', 'ping']).error, 'ping은 시험 전용');
  assert.ok(parseEvents('message.created').error);
  assert.equal(INTEGRATION_EVENTS.includes('todo.created'), true);
});

test('이 연동이 일을 받는지·단추 응답 주소·사내 주소 허용', () => {
  const out = { kind: 'outgoing', enabled: true, url: 'https://x.example', events: ['message.created'] };
  assert.equal(integrationWantsEvent(out, 'message.created'), true);
  assert.equal(integrationWantsEvent(out, 'mention'), false);
  assert.equal(integrationWantsEvent({ ...out, enabled: false }, 'message.created'), false, '꺼짐');
  assert.equal(integrationWantsEvent({ ...out, url: null }, 'message.created'), false, '주소 없음');
  assert.equal(integrationWantsEvent({ ...out, kind: 'webhook' }, 'message.created'), false, '들어오는 웹훅은 받지 않는다');
  assert.equal(interactionUrlOf({ kind: 'command', url: 'https://c' }), 'https://c');
  assert.equal(interactionUrlOf({ kind: 'webhook', interactionUrl: 'https://i' }), 'https://i');
  assert.equal(interactionUrlOf({ kind: 'webhook' }), null);
  assert.equal(interactionUrlOf({ kind: 'outgoing', url: 'https://o' }), null);
  assert.equal(interactionUrlOf(null), null);
  assert.equal(mayReachPrivate({ kind: 'command' }), true);
  assert.equal(mayReachPrivate({ kind: 'app' }), true);
  assert.equal(mayReachPrivate({ kind: 'outgoing', allowPrivate: false }), false);
  assert.equal(mayReachPrivate({ kind: 'webhook', allowPrivate: true }), true, '서버 운영자가 정한 주소');
});

test('다시 보내기 간격 — 10초부터 6시간까지, 그 뒤로는 끝', () => {
  assert.equal(nextDeliveryAttemptAt(1, 0), DELIVERY_RETRY_DELAYS_MS[0]);
  assert.equal(nextDeliveryAttemptAt(2, 1000), 1000 + 60_000);
  assert.equal(nextDeliveryAttemptAt(DELIVERY_MAX_ATTEMPTS - 1, 0), DELIVERY_RETRY_DELAYS_MS.at(-1));
  assert.equal(nextDeliveryAttemptAt(DELIVERY_MAX_ATTEMPTS, 0), null);
  assert.equal(nextDeliveryAttemptAt(0, 0), null);
  assert.deepEqual(eventEnvelope({ id: 'd1', type: 'mention', teamId: 't', roomId: 'r', data: { a: 1 }, now: 5 }), {
    id: 'd1',
    type: 'mention',
    createdAt: 5,
    teamId: 't',
    roomId: 'r',
    data: { a: 1 },
  });
});

test('웹훅 본문의 바깥 그림 주소 — 맨 위·Slack 첨부·Discord embed, http(s)만, 겹치지 않게, 정해진 수까지', () => {
  const r = webhookPayloadToMessage({
    text: '그래프',
    image_url: 'https://g.example/1.png',
    attachments: [{ text: 'a', image_url: 'https://g.example/1.png' }, { text: 'b', image_url: 'file:///etc/passwd' }],
    embeds: Array.from({ length: 6 }, (_, i) => ({ title: `e${i}`, image: { url: `https://d.example/${i}.png` } })),
  });
  assert.equal(r.imageUrls.length, PAYLOAD_IMAGES_MAX);
  assert.deepEqual(r.imageUrls.slice(0, 2), ['https://g.example/1.png', 'https://d.example/0.png']);
  // 그림만 있어도 받는다.
  assert.deepEqual(webhookPayloadToMessage({ image_url: 'https://g.example/x.png' }).imageUrls, ['https://g.example/x.png']);
  // 블록은 그대로 블록으로, text가 없으면 블록에서 글을 만든다.
  const b = webhookPayloadToMessage({ blocks: [{ type: 'actions', elements: [{ type: 'button', text: '승인', action_id: 'ok' }] }] });
  assert.equal(b.text, '[승인]');
  assert.equal(b.blocks[0].elements[0].actionId, 'ok');
});

test('공인 주소 검사 — 사설·루프백·80/443 밖 포트는 서버 운영자만', async () => {
  const lookup = (addrs) => async () => addrs.map((address) => ({ address }));
  assert.deepEqual(await checkPublicUrl('https://hooks.example.com/x', { lookup: lookup(['93.184.216.34']) }), { ok: true });
  assert.equal((await checkPublicUrl('https://intranet.local/x', { lookup: lookup(['192.168.0.10']) })).ok, false);
  assert.equal((await checkPublicUrl('https://mixed.example/x', { lookup: lookup(['93.184.216.34', '10.0.0.1']) })).ok, false, '하나라도 사설');
  assert.equal((await checkPublicUrl('http://127.0.0.1/x')).ok, false);
  assert.equal((await checkPublicUrl('https://hooks.example.com:8443/x', { lookup: lookup(['93.184.216.34']) })).ok, false, '포트');
  assert.equal((await checkPublicUrl('https://none.example/x', { lookup: lookup([]) })).ok, false);
  assert.equal((await checkPublicUrl('그냥 글')).ok, false);
});

test('공개 API 모양 — 메시지(봇·첨부·블록 그림·지움)·댓글·할 일·일정, 받는 칸 고르기', () => {
  const m = publicMessageDto({
    id: 'm1',
    roomId: 'r1',
    type: 'image',
    senderId: null,
    senderName: '배포봇',
    integrationId: 'i1',
    botEmoji: '🚀',
    text: '그래프',
    botBlocks: [{ type: 'image', file: '/uploads/a.webp', alt: '차트', title: null }],
    attachments: [{ kind: 'image', fileName: 'a.webp', fileSize: 10, mimeType: 'image/webp', fileUrl: '/uploads/a.webp' }],
    mentions: [{ type: 'user', userId: 'u1', s: 0, e: 3 }, { type: 'all', s: 4, e: 6 }],
    createdAt: new Date(1000),
  });
  assert.equal(m.bot, true);
  assert.equal(m.botId, 'i1');
  assert.deepEqual(m.blocks, [{ type: 'image', alt: '차트', title: null }], '그림 경로는 내보내지 않는다');
  assert.deepEqual(m.files, [{ kind: 'image', name: 'a.webp', size: 10, mimeType: 'image/webp' }]);
  assert.deepEqual(m.mentions, [{ type: 'user', userId: 'u1' }, { type: 'all' }]);
  assert.equal(m.createdAt, 1000);
  const deleted = publicMessageDto({ id: 'm2', roomId: 'r1', type: 'text', text: '비밀', deleted: true, createdAt: 1 });
  assert.equal(deleted.text, null);
  assert.deepEqual(deleted.files, []);
  assert.equal(publicCommentDto({ id: 'c1', messageId: 'm1', roomId: 'r1', type: 'text', text: 'ㅇㅋ', createdAt: 2 }).text, 'ㅇㅋ');
  const todo = publicTodoDto({ id: 't1', teamId: 'tm', roomId: 'r1', title: '보고서', creator: { id: 'u1' }, assignees: [{ id: 'u2', name: '김', progress: 50, status: 'doing', extra: 1 }] });
  assert.equal(todo.creatorId, 'u1');
  assert.deepEqual(todo.assignees, [{ id: 'u2', name: '김', progress: 50, status: 'doing' }]);
  const ev = publicEventDto({ eventId: 'e1', calendarId: 'c1', title: '회의', start: 1, end: 2, allDay: false, attendees: [{ userId: 'u1', name: '김' }], key: 'x' });
  assert.equal(ev.id, 'e1');
  assert.deepEqual(ev.attendees, [{ userId: 'u1', name: '김', response: null }]);
  assert.deepEqual(pickFields({ title: 'a', attachments: [1], dueDate: null }, ['title', 'dueDate']), { title: 'a', dueDate: null });
  assert.deepEqual(pickFields(null, ['title']), {});
});

test('앱 라우터를 안에서 부르기 — 사람으로, 경로·본문·물음표 값 그대로, 없는 경로는 404', async () => {
  const router = Router();
  router.post('/things/:id', (req, res) => res.status(201).json({ id: req.params.id, user: req.user.sub, body: req.body, q: req.query.x, ip: req.get('x-test') }));
  router.get('/boom', () => {
    throw new Error('터짐');
  });
  const from = { headers: { authorization: 'Bearer ttk_x', 'x-test': 'yes' }, socket: { remoteAddress: '10.0.0.5' } };
  const r = await internalCall(router, { from, userId: 'u1', method: 'POST', path: '/things/7', body: { a: 1 }, query: { x: '2' } });
  assert.deepEqual(r, { status: 201, body: { id: '7', user: 'u1', body: { a: 1 }, q: '2', ip: 'yes' } });
  assert.equal((await internalCall(router, { from, userId: 'u1', method: 'GET', path: '/nope' })).status, 404);
  await assert.rejects(internalCall(router, { from, userId: 'u1', method: 'GET', path: '/boom' }), /터짐/);
});
