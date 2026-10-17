// 보내기 대기열의 임시 id(client_id)와 임시 저장 동기화 규칙 — 모양 검사, 중복 오류 알아보기, 임시 저장 입력·멘션·응답 모양.
// `node --test test/*.test.js`(DB 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { DEVICE_ID_RE, draftDto, parseDraftInput, sanitizeDraftMentions } from '../src/draftRules.js';
import { isClientIdConflict, parseClientId } from '../src/outboxRules.js';

test('임시 id — 글자·숫자·_- 8~64자만', () => {
  assert.equal(parseClientId('c-0001-abcdef'), 'c-0001-abcdef');
  assert.equal(parseClientId('8c1f0e5a-3b9d-4c7e-9a2f-0d1e2f3a4b5c'), '8c1f0e5a-3b9d-4c7e-9a2f-0d1e2f3a4b5c');
  for (const bad of ['short', 'has space id', 'x'.repeat(65), 12345678, null, undefined, "x'); drop--"]) {
    assert.equal(parseClientId(bad), null, String(bad));
  }
});

test('중복 오류 — 그 unique 인덱스의 23505만', () => {
  assert.equal(isClientIdConflict({ code: '23505', constraint: 'messages_sender_client_id_idx' }), true);
  assert.equal(isClientIdConflict({ cause: { code: '23505', constraint: 'messages_sender_client_id_idx' } }), true);
  assert.equal(isClientIdConflict({ code: '23505', message: 'duplicate key value violates unique constraint "messages_sender_client_id_idx"' }), true);
  assert.equal(isClientIdConflict({ code: '23505', constraint: 'messages_pkey' }), false);
  assert.equal(isClientIdConflict({ code: '23503', constraint: 'messages_sender_client_id_idx' }), false);
  assert.equal(isClientIdConflict(null), false);
});

test('임시 저장 입력 — 비면 지우기, 글자가 아니면 오류, 서식은 글에 맞게', () => {
  assert.deepEqual(parseDraftInput({ text: '' }), { values: null });
  assert.deepEqual(parseDraftInput({ text: '   \n' }), { values: null });
  assert.deepEqual(parseDraftInput({}), { values: null });
  assert.match(parseDraftInput({ text: 5 }).error, /글/);
  const r = parseDraftInput({ text: '안녕 @김', mentions: [{ type: 'user', userId: 'U1', s: 3, e: 5 }] });
  assert.equal(r.values.text, '안녕 @김');
  assert.deepEqual(r.values.mentions, [{ type: 'user', userId: 'U1', s: 3, e: 5 }]);
  assert.match(parseDraftInput({ text: 'x'.repeat(1_000_000) }).error, /너무 깁니다/);
});

test('멘션 — 글 범위 밖·모양이 틀린 것은 버림, 남는 게 없으면 null', () => {
  const text = '@모두 @김 회의';
  assert.deepEqual(
    sanitizeDraftMentions(
      [
        { type: 'all', s: 0, e: 3 },
        { type: 'user', userId: 'U1', s: 4, e: 6 },
        { type: 'user', userId: 'U2', s: 4, e: 99 },
        { type: 'user', s: 0, e: 1 },
        { type: 'robot', s: 0, e: 1 },
        null,
      ],
      text,
    ),
    [
      { type: 'all', s: 0, e: 3 },
      { type: 'user', userId: 'U1', s: 4, e: 6 },
    ],
  );
  assert.equal(sanitizeDraftMentions([{ type: 'user', userId: 'U1', s: 2, e: 1 }], text), null);
  assert.equal(sanitizeDraftMentions('nope', text), null);
});

test('응답 모양·기기 id', () => {
  assert.deepEqual(draftDto({ roomId: 'r1', text: 't', textFormat: null, mentions: null, updatedAt: new Date(1000) }), {
    roomId: 'r1',
    text: 't',
    format: null,
    mentions: [],
    updatedAt: 1000,
  });
  assert.equal(draftDto({ roomId: 'r1', text: '', updatedAt: new Date(5) }).text, null, '지운 것');
  assert.equal(DEVICE_ID_RE.test('3f2a-device_1'), true);
  assert.equal(DEVICE_ID_RE.test('bad id'), false);
});
