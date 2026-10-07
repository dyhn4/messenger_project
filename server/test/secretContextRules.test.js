// 비밀 대화 맥락 서명(검토 S5)의 서버 쪽 단위 테스트 — `node --test test/secretContextRules.test.js` (DB·서버 없이 돈다: db
// 메서드는 부르면 바로 실패하게 막아 두고, 저장 쿼리를 볼 때만 SQL을 받아 적는 가짜로 바꾼다. 접속 주소도 닿지 않는 값으로 정해
// 둔다 — 이 파일은 .env를 읽는 모듈을 불러오지 않는다. 라우트·소켓 처리 함수는 그런 모듈을 불러오므로 소스를 읽어 본다).
//
// 지키려는 것: 서버는 맥락 서명을 검증하지 않고(막으려는 상대가 서버라서) 모양(64바이트 base64)만 본 뒤 그대로 저장·전달한다.
// 예전 앱은 이 칸을 안 보내므로 없으면 null이고, 예전 칸과 동작은 그대로다. 모양이 틀린 서명은 null로 바꿔 받지 않고
// 거절한다(받는 새 앱이 예전 앱의 핸드셰이크로 잘못 알지 않게). 비밀 대화 이벤트·응답·방 DTO는 모두 secretContextRules.js의
// 같은 함수로 만든다 — 어느 길로 받든 같은 값이고, 새 칸이 빠지는 곳이 없게.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { mock, test } from 'node:test';
import { getTableColumns } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/node-postgres';
import {
  CONTEXT_SIGNATURE_BYTES,
  isContextSignature,
  parseContextSignature,
  parseRekeyPayload,
  parseSecretProtocol,
  SECRET_PROTOCOL_MAX,
  rekeyAckRelay,
  rekeyProposeRelay,
  secretAcceptedPayload,
  secretInvitePayload,
  secretRoomFields,
} from '../src/secretContextRules.js';

process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused';
const { db } = await import('../src/db/client.js');
for (const method of ['select', 'insert', 'update', 'delete', 'execute', 'transaction']) {
  mock.method(db, method, () => {
    throw new Error(`이 테스트는 DB를 쓰면 안 된다(db.${method})`);
  });
}
const { secretRekeys, secretSessions } = await import('../src/db/schema.js');
const { acceptSecretSession, ackSecretRekey, insertSecretSession, replaceSecretRekeyProposal } = await import(
  '../src/db/queries/secretSessions.js'
);

const ROOM = '0a0a0a0a-0000-4000-8000-000000000001';
const ALICE = '11111111-1111-4111-8111-111111111111'; // 비밀 대화를 건 사람
const BOB = '22222222-2222-4222-8222-222222222222'; // 초대받은 사람
const ALICE_DEVICE = '3f1c2b9a-7d4e-4c1a-9b2f-1e2d3c4b5a69';
const BOB_DEVICE = '9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d';
const KEY_A = Buffer.alloc(32, 7).toString('base64'); // 44자 — 앱이 보내는 X25519 임시 공개키 모양
const KEY_B = Buffer.alloc(32, 9).toString('base64');
const SIG_A = Buffer.alloc(64, 1).toString('base64'); // 예전(v1) 서명 — 키 바이트만 서명
const SIG_B = Buffer.alloc(64, 2).toString('base64');
const CTX_A = Buffer.alloc(64, 0xab).toString('base64'); // 맥락 서명(v2) — 앱의 base64Encode처럼 패딩까지 88자
const CTX_B = Buffer.alloc(64, 0xcd).toString('base64');

const pendingSession = {
  roomId: ROOM,
  initiatorUserId: ALICE,
  initiatorDeviceId: ALICE_DEVICE,
  responderUserId: BOB,
  responderDeviceId: null,
  status: 'pending',
  initiatorEphemeralPublicKey: KEY_A,
  initiatorEphemeralSignature: SIG_A,
  responderEphemeralPublicKey: null,
  responderEphemeralSignature: null,
  initiatorContextSignature: CTX_A,
  responderContextSignature: null,
  initiatorProtocol: 3, // 새 앱이 건 초대 — 새 규약(v3)을 안다
  keyEpoch: 0,
  selfDestructSeconds: null,
  createdAt: new Date('2026-10-01T00:00:00Z'),
  acceptedAt: null,
};
const activeSession = {
  ...pendingSession,
  status: 'active',
  responderDeviceId: BOB_DEVICE,
  responderEphemeralPublicKey: KEY_B,
  responderEphemeralSignature: SIG_B,
  responderContextSignature: CTX_B,
  keyEpoch: 2,
  selfDestructSeconds: 30,
  acceptedAt: new Date('2026-10-01T00:01:00Z'),
};
/** 예전 앱끼리 만든 세션 — 맥락 서명·규약 칸이 비어 있다. */
const legacySession = {
  ...activeSession,
  initiatorContextSignature: null,
  responderContextSignature: null,
  initiatorProtocol: null,
};

/** 선을 한 번 탄 모양(JSON) — undefined인 칸은 여기서 사라지므로 "null로 실려 간다"를 보려면 이걸 거친다. */
const wire = (value) => JSON.parse(JSON.stringify(value));

test('isContextSignature·parseContextSignature: 64바이트 base64는 받고, 없으면(예전 앱) null', () => {
  assert.equal(CONTEXT_SIGNATURE_BYTES, 64);
  assert.equal(CTX_A.length, 88);
  assert.ok(CTX_A.endsWith('=='));
  assert.equal(isContextSignature(CTX_A), true);
  assert.deepEqual(parseContextSignature(CTX_A, 'initiatorContextSignature'), { value: CTX_A });
  // URL 안전 글자·패딩 없는 모양도 64바이트면 받는다(받는 앱의 디코더가 읽는 글자).
  const urlSafe = Buffer.alloc(64, 0xfb).toString('base64url');
  assert.match(urlSafe, /[-_]/);
  assert.equal(urlSafe.length, 86);
  assert.equal(isContextSignature(urlSafe), true);
  assert.equal(isContextSignature(`${urlSafe}==`), true);
  // 서명이 맞는지는 보지 않는다 — 모양만 맞으면 어떤 64바이트든 받는다(검증은 받는 앱이 상대 기기 키로 한다).
  assert.equal(isContextSignature(Buffer.alloc(64).toString('base64')), true);
  // 없으면 예전 앱 — 오류가 아니라 null로 받는다.
  assert.deepEqual(parseContextSignature(undefined, 'initiatorContextSignature'), { value: null });
  assert.deepEqual(parseContextSignature(null, 'initiatorContextSignature'), { value: null });
});

test('parseContextSignature: 문자열이 아니거나, 64바이트가 아니거나, base64가 아니면 받지 않는다(null로 바꾸지 않는다)', () => {
  const bad = [
    '',
    'abc',
    KEY_A, // 32바이트 공개키
    Buffer.alloc(63, 1).toString('base64'),
    Buffer.alloc(65, 1).toString('base64'), // 88자지만 65바이트
    Buffer.alloc(128, 1).toString('base64'),
    `${CTX_A.slice(0, 86)}=`, // 패딩이 하나뿐
    `${CTX_A.slice(0, 86)}===`,
    `${CTX_A}=`,
    `${CTX_A}\n`,
    ` ${CTX_A}`,
    `${CTX_A.slice(0, 40)}!${CTX_A.slice(41)}`,
    `${CTX_A.slice(0, 40)} ${CTX_A.slice(41)}`,
    `${CTX_A.slice(0, 40)}=${CTX_A.slice(41)}`, // 패딩 글자가 가운데에
    'A'.repeat(88), // 패딩 없이 88자 = 66바이트
    'A'.repeat(1_000_000),
    '가'.repeat(86),
    64,
    0,
    true,
    false,
    [CTX_A],
    { signature: CTX_A },
  ];
  for (const raw of bad) {
    const label = JSON.stringify(raw)?.slice(0, 50) ?? String(raw);
    assert.equal(isContextSignature(raw), false, label);
    assert.deepEqual(
      parseContextSignature(raw, 'responderContextSignature'),
      { error: '맥락 서명(responderContextSignature)이 올바르지 않습니다.' },
      label,
    );
  }
});

test('parseRekeyPayload: 예전 앱의 재키잉은 그대로, 새 앱은 맥락 서명까지 — 모양이 틀리면 통째로 버린다', () => {
  const legacy = { roomId: ROOM, keyEpoch: 3, ephemeralPublicKey: KEY_A, ephemeralSignature: SIG_A };
  const parsedLegacy = { roomId: ROOM, keyEpoch: 3, ephemeralPublicKey: KEY_A, ephemeralSignature: SIG_A, contextSignature: null };
  assert.deepEqual(parseRekeyPayload(legacy), parsedLegacy);
  assert.deepEqual(parseRekeyPayload({ ...legacy, ephemeralContextSignature: null }), parsedLegacy);
  assert.deepEqual(parseRekeyPayload({ ...legacy, ephemeralContextSignature: CTX_A }), { ...parsedLegacy, contextSignature: CTX_A });
  // payload에 실린 다른 칸(보낸 사람 등)은 넘기지 않는다 — 보낸 사람은 소켓의 로그인 사용자로 정한다.
  assert.deepEqual(
    Object.keys(parseRekeyPayload({ ...legacy, proposerUserId: BOB, responderUserId: BOB, proposerContextSignature: CTX_B })).sort(),
    ['contextSignature', 'ephemeralPublicKey', 'ephemeralSignature', 'keyEpoch', 'roomId'],
  );
  const malformed = [
    null,
    undefined,
    'payload',
    42,
    [],
    {},
    { ...legacy, roomId: undefined },
    { ...legacy, roomId: 7 },
    { ...legacy, roomId: '' },
    { ...legacy, keyEpoch: '3' },
    { ...legacy, keyEpoch: 1.5 },
    { ...legacy, keyEpoch: Number.NaN },
    { ...legacy, keyEpoch: undefined },
    { ...legacy, ephemeralPublicKey: '' },
    { ...legacy, ephemeralSignature: undefined },
    // 맥락 서명이 있는데 모양이 틀리면 서명만 빼고 넘기지 않는다 — 받는 새 앱이 예전 앱의 재키잉으로 알게 된다.
    { ...legacy, ephemeralContextSignature: '' },
    { ...legacy, ephemeralContextSignature: 'abc' },
    { ...legacy, ephemeralContextSignature: KEY_A },
    { ...legacy, ephemeralContextSignature: CTX_A.slice(0, 80) },
    { ...legacy, ephemeralContextSignature: 64 },
    { ...legacy, ephemeralContextSignature: [CTX_A] },
  ];
  for (const payload of malformed) {
    assert.equal(parseRekeyPayload(payload), null, JSON.stringify(payload)?.slice(0, 80) ?? String(payload));
  }
});

test('secretInvitePayload: secret:invite와 GET invite가 같은 모양 — 예전 칸 그대로에 initiatorContextSignature·initiatorProtocol(없으면 null)', () => {
  assert.deepEqual(wire(secretInvitePayload(pendingSession)), {
    roomId: ROOM,
    initiatorUserId: ALICE,
    initiatorDeviceId: ALICE_DEVICE,
    initiatorEphemeralPublicKey: KEY_A,
    initiatorEphemeralSignature: SIG_A,
    initiatorContextSignature: CTX_A,
    initiatorProtocol: 3,
  });
  // 예전 앱이 만든 세션 — 칸이 null이든, 행에 아예 없든 null로 실려 간다(키가 빠지지 않게).
  const { initiatorContextSignature: _omitted, initiatorProtocol: _omittedProtocol, ...withoutColumn } = pendingSession;
  for (const row of [{ ...pendingSession, initiatorContextSignature: null, initiatorProtocol: null }, withoutColumn]) {
    const payload = wire(secretInvitePayload(row));
    assert.ok(Object.hasOwn(payload, 'initiatorContextSignature'));
    assert.equal(payload.initiatorContextSignature, null);
    assert.ok(Object.hasOwn(payload, 'initiatorProtocol'));
    assert.equal(payload.initiatorProtocol, null);
    assert.equal(payload.initiatorEphemeralSignature, SIG_A);
  }
});

test('parseSecretProtocol: 초대한 앱이 아는 규약 번호 — 없으면(예전 앱) null, 1~255 정수만 받는다', () => {
  assert.equal(SECRET_PROTOCOL_MAX, 255);
  assert.deepEqual(parseSecretProtocol(undefined), { value: null });
  assert.deepEqual(parseSecretProtocol(null), { value: null });
  for (const ok of [1, 3, 4, SECRET_PROTOCOL_MAX]) assert.deepEqual(parseSecretProtocol(ok), { value: ok });
  for (const bad of [0, -1, 256, 1.5, Number.NaN, Number.POSITIVE_INFINITY, '3', true, [3], { v: 3 }]) {
    assert.deepEqual(
      parseSecretProtocol(bad),
      { error: '비밀 대화 규약 번호(protocol)가 올바르지 않습니다.' },
      JSON.stringify(bad) ?? String(bad),
    );
  }
});

test('secretAcceptedPayload: 예전 칸 그대로에 responderUserId·responderContextSignature(없으면 null)', () => {
  assert.deepEqual(wire(secretAcceptedPayload(activeSession)), {
    roomId: ROOM,
    responderUserId: BOB,
    responderDeviceId: BOB_DEVICE,
    responderEphemeralPublicKey: KEY_B,
    responderEphemeralSignature: SIG_B,
    responderContextSignature: CTX_B,
  });
  const legacy = wire(secretAcceptedPayload(legacySession));
  assert.ok(Object.hasOwn(legacy, 'responderContextSignature'));
  assert.equal(legacy.responderContextSignature, null);
  assert.equal(legacy.responderEphemeralSignature, SIG_B);
  // 초대한 쪽의 키·서명은 싣지 않는다(이미 가진 값).
  assert.equal(JSON.stringify(secretAcceptedPayload(activeSession)).includes(CTX_A), false);
});

test('rekeyProposeRelay·rekeyAckRelay: 예전 칸 그대로에 맥락 서명(없으면 null) — 보낸 사람은 소켓의 사용자', () => {
  const rekey = parseRekeyPayload({ roomId: ROOM, keyEpoch: 4, ephemeralPublicKey: KEY_A, ephemeralSignature: SIG_A, ephemeralContextSignature: CTX_A });
  assert.deepEqual(wire(rekeyProposeRelay(ROOM, ALICE, rekey)), {
    roomId: ROOM,
    keyEpoch: 4,
    proposerUserId: ALICE,
    proposerEphemeralPublicKey: KEY_A,
    proposerEphemeralSignature: SIG_A,
    proposerContextSignature: CTX_A,
  });
  assert.deepEqual(wire(rekeyAckRelay(ROOM, BOB, rekey)), {
    roomId: ROOM,
    keyEpoch: 4,
    responderUserId: BOB,
    responderEphemeralPublicKey: KEY_A,
    responderEphemeralSignature: SIG_A,
    responderContextSignature: CTX_A,
  });
  const legacy = parseRekeyPayload({ roomId: ROOM, keyEpoch: 4, ephemeralPublicKey: KEY_B, ephemeralSignature: SIG_B });
  const propose = wire(rekeyProposeRelay(ROOM, ALICE, legacy));
  const ack = wire(rekeyAckRelay(ROOM, BOB, legacy));
  assert.ok(Object.hasOwn(propose, 'proposerContextSignature') && propose.proposerContextSignature === null);
  assert.ok(Object.hasOwn(ack, 'responderContextSignature') && ack.responderContextSignature === null);
  assert.equal(propose.proposerEphemeralSignature, SIG_B);
  assert.equal(ack.responderEphemeralSignature, SIG_B);
});

test('secretRoomFields: 예전 칸 그대로에 양쪽 사용자·기기 id — 모르는 값은 null, 키·서명은 싣지 않는다', () => {
  assert.deepEqual(secretRoomFields(null), {
    secretStatus: null,
    secretKeyEpoch: 0,
    secretSelfDestructSeconds: null,
    secretInitiatorUserId: null,
    secretInitiatorDeviceId: null,
    secretResponderUserId: null,
    secretResponderDeviceId: null,
  });
  // 수락 전 — 받는 쪽 기기는 아직 모른다.
  assert.deepEqual(secretRoomFields(pendingSession), {
    secretStatus: 'pending',
    secretKeyEpoch: 0,
    secretSelfDestructSeconds: null,
    secretInitiatorUserId: ALICE,
    secretInitiatorDeviceId: ALICE_DEVICE,
    secretResponderUserId: BOB,
    secretResponderDeviceId: null,
  });
  assert.deepEqual(secretRoomFields(activeSession), {
    secretStatus: 'active',
    secretKeyEpoch: 2,
    secretSelfDestructSeconds: 30,
    secretInitiatorUserId: ALICE,
    secretInitiatorDeviceId: ALICE_DEVICE,
    secretResponderUserId: BOB,
    secretResponderDeviceId: BOB_DEVICE,
  });
  // 예전 앱끼리 만든 대화도 같은 칸 — 앱이 이 값으로 상대 기기를 정한다.
  assert.deepEqual(secretRoomFields(legacySession), secretRoomFields(activeSession));
  // 방 DTO는 방 정보가 가는 곳마다 실린다 — 임시 공개키·서명·맥락 서명은 핸드셰이크 이벤트로만 오간다.
  const dto = JSON.stringify(secretRoomFields(activeSession));
  for (const material of [KEY_A, KEY_B, SIG_A, SIG_B, CTX_A, CTX_B]) assert.equal(dto.includes(material), false);
});

/**
 * 이 테스트 동안 db.[method]를 SQL을 받아 적는 가짜로 바꾼다 — 돌려주는 행은 [row]를 [table]의 칸 순서로 편 것(drizzle은
 * returning 결과를 칸 순서 배열로 받는다). drizzle은 표에 없는 칸 이름을 말없이 버리므로, 실제 SQL에 칸이 들어갔는지를 본다.
 */
function recordQueries(t, method, table, row) {
  const columns = Object.keys(getTableColumns(table));
  const queries = [];
  const fake = drizzle({
    client: {
      async query(config, values = []) {
        queries.push({ text: typeof config === 'string' ? config : config.text, values });
        return { rows: [columns.map((k) => row[k] ?? null)], rowCount: 1 };
      },
    },
  });
  t.mock.method(db, method, (...args) => fake[method](...args));
  return queries;
}

/** update SQL의 set 절에서 [column]에 넣는 값 — set에 그 칸이 없으면 undefined. */
function setValue({ text, values }, column) {
  const clause = text.slice(text.indexOf(' set '), text.search(/ where | returning /));
  const match = clause.match(new RegExp(`"${column}" = \\$(\\d+)`));
  return match ? values[Number(match[1]) - 1] : undefined;
}

/** insert SQL에서 [column]에 넣는 값 — 칸이 없거나 default(값을 안 줌)면 undefined. */
function insertedValue({ text, values }, column) {
  const match = text.match(/^insert into "[^"]+" \(([^)]*)\) values \(([^)]*)\)/);
  assert.ok(match, text);
  const columns = match[1].split(', ').map((c) => c.replaceAll('"', ''));
  const token = match[2].split(', ')[columns.indexOf(column)];
  return token?.startsWith('$') ? values[Number(token.slice(1)) - 1] : undefined;
}

test('insertSecretSession: 맥락 서명을 initiator_context_signature에 저장하고, 저장한 행이 그대로 초대 이벤트가 된다', async (t) => {
  const queries = recordQueries(t, 'insert', secretSessions, pendingSession);
  const fields = {
    roomId: ROOM,
    initiatorUserId: ALICE,
    initiatorDeviceId: ALICE_DEVICE,
    responderUserId: BOB,
    initiatorEphemeralPublicKey: KEY_A,
    initiatorEphemeralSignature: SIG_A,
  };
  const row = await insertSecretSession({ ...fields, initiatorContextSignature: CTX_A, initiatorProtocol: 3 });
  assert.match(queries[0].text, /^insert into "secret_sessions"/);
  assert.equal(insertedValue(queries[0], 'initiator_context_signature'), CTX_A);
  assert.equal(insertedValue(queries[0], 'initiator_ephemeral_signature'), SIG_A);
  assert.equal(insertedValue(queries[0], 'initiator_protocol'), 3);
  // 돌아온 행(칸 이름 → drizzle 속성)을 그대로 secret:invite로 — 속성 이름이 어긋나면 여기서 null이 된다.
  assert.equal(secretInvitePayload(row).initiatorContextSignature, CTX_A);
  assert.equal(secretInvitePayload(row).initiatorProtocol, 3);
  // 예전 앱 — null로 넣는다.
  await insertSecretSession({ ...fields, initiatorContextSignature: null, initiatorProtocol: null });
  assert.equal(insertedValue(queries[1], 'initiator_context_signature'), null);
  assert.equal(insertedValue(queries[1], 'initiator_protocol'), null);
});

test('acceptSecretSession: 맥락 서명을 responder_context_signature에 저장 — 예전 앱이면 null, 대기 중인 초대만', async (t) => {
  const queries = recordQueries(t, 'update', secretSessions, activeSession);
  const fields = {
    responderUserId: BOB,
    responderDeviceId: BOB_DEVICE,
    responderEphemeralPublicKey: KEY_B,
    responderEphemeralSignature: SIG_B,
  };
  const row = await acceptSecretSession(ROOM, { ...fields, responderContextSignature: CTX_B });
  assert.match(queries[0].text, /^update "secret_sessions" set /);
  assert.equal(setValue(queries[0], 'responder_context_signature'), CTX_B);
  assert.equal(setValue(queries[0], 'responder_ephemeral_signature'), SIG_B);
  assert.equal(setValue(queries[0], 'responder_device_id'), BOB_DEVICE);
  // 예전처럼 초대받은 사람이 대기 중인 초대를 수락할 때만 바뀐다.
  assert.match(queries[0].text, / where .*"secret_sessions"\."responder_user_id" = \$\d+.*"secret_sessions"\."status" = \$\d+/);
  assert.deepEqual(wire(secretAcceptedPayload(row)), wire(secretAcceptedPayload(activeSession)));
  // 예전 앱은 칸을 안 준다 — 그래도 null로 적는다(빠뜨리지 않는다).
  await acceptSecretSession(ROOM, fields);
  assert.equal(setValue(queries[1], 'responder_context_signature'), null);
});

test('replaceSecretRekeyProposal·ackSecretRekey: 재키잉 맥락 서명을 proposer_/responder_context_signature에 저장 — 같은 epoch의 대기 중인 제안은 바꿔 적는다', async (t) => {
  const rekeyRow = {
    id: '0b0b0b0b-0000-4000-8000-000000000001',
    roomId: ROOM,
    keyEpoch: 3,
    proposerUserId: ALICE,
    proposerEphemeralPublicKey: KEY_A,
    proposerEphemeralSignature: SIG_A,
    responderEphemeralPublicKey: KEY_B,
    responderEphemeralSignature: SIG_B,
    proposerContextSignature: CTX_A,
    responderContextSignature: CTX_B,
    status: 'acked',
    createdAt: new Date('2026-10-01T00:00:00Z'),
  };
  const proposal = {
    roomId: ROOM,
    keyEpoch: 3,
    proposerUserId: ALICE,
    proposerEphemeralPublicKey: KEY_A,
    proposerEphemeralSignature: SIG_A,
  };
  // 한 트랜잭션 안에서 — 같은 방·같은 epoch의 아직 수락되지 않은 제안을 지우고 새 제안을 적는다(예전 앱은 수락이 올 때까지
  // 메시지마다 다시 제안하는데 새 앱은 응하지 않는다 — 그대로 두면 메시지마다 행이 쌓인다).
  const tx = recordQueries(t, 'transaction', secretRekeys, rekeyRow);
  await replaceSecretRekeyProposal({ ...proposal, proposerContextSignature: CTX_A });
  const statements = tx.map((q) => q.text);
  assert.equal(statements[0], 'begin');
  assert.match(statements[1], /^delete from "secret_rekeys" where /);
  // 같은 제안자의 제안만 — 예전 앱 둘이 동시에 낸 상대의 제안은 남긴다.
  assert.match(
    statements[1],
    /"secret_rekeys"\."room_id" = \$1.*"secret_rekeys"\."key_epoch" = \$2.*"secret_rekeys"\."proposer_user_id" = \$3.*"secret_rekeys"\."status" = \$4/,
  );
  assert.deepEqual(tx[1].values, [ROOM, 3, ALICE, 'proposed']);
  assert.match(statements[2], /^insert into "secret_rekeys"/);
  assert.equal(insertedValue(tx[2], 'proposer_context_signature'), CTX_A);
  assert.equal(statements[3], 'commit');
  await replaceSecretRekeyProposal({ ...proposal, proposerContextSignature: null });
  assert.equal(insertedValue(tx[6], 'proposer_context_signature'), null);

  const updates = recordQueries(t, 'update', secretRekeys, rekeyRow);
  const ack = { responderEphemeralPublicKey: KEY_B, responderEphemeralSignature: SIG_B };
  const row = await ackSecretRekey(ROOM, 3, { ...ack, responderContextSignature: CTX_B });
  assert.match(updates[0].text, /^update "secret_rekeys" set /);
  assert.equal(setValue(updates[0], 'responder_context_signature'), CTX_B);
  assert.equal(setValue(updates[0], 'status'), 'acked');
  assert.equal(row.responderContextSignature, CTX_B);
  await ackSecretRekey(ROOM, 3, ack);
  assert.equal(setValue(updates[1], 'responder_context_signature'), null);
});

// ── 이벤트·응답을 만드는 곳(라우트·소켓 처리 함수는 .env를 읽는 모듈을 불러와서 소스를 읽어 본다) ──

const SRC_DIR = new URL('../src/', import.meta.url);
const read = (file) => fs.readFileSync(new URL(file, SRC_DIR), 'utf8');

/** [source]에서 [start]부터 그 뒤 처음 나오는 [end] 앞까지. */
function section(source, start, end) {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `${start}를 찾지 못했다`);
  const to = source.indexOf(end, from + start.length);
  assert.ok(to > from, `${end}를 찾지 못했다`);
  return source.slice(from, to);
}

/** src 아래 모든 .js — [상대 경로, 내용]. */
function allSources() {
  return fs
    .readdirSync(SRC_DIR, { recursive: true })
    .filter((file) => String(file).endsWith('.js'))
    .map((file) => [String(file), read(String(file).replaceAll('\\', '/'))]);
}

test('비밀 대화 초대·수락·재키잉 이벤트는 모두 secretContextRules.js의 같은 함수로 만든다(새 칸이 빠지는 곳이 없게)', () => {
  const builders = {
    'secret:invite': 'secretInvitePayload',
    'secret:accepted': 'secretAcceptedPayload',
    'secret:rekey-propose': 'rekeyProposeRelay',
    'secret:rekey-ack': 'rekeyAckRelay',
  };
  const count = Object.fromEntries(Object.keys(builders).map((event) => [event, 0]));
  for (const [file, source] of allSources()) {
    for (const [, event, rest] of source.matchAll(/\.emit\(\s*'(secret:(?:invite|accepted|rekey-propose|rekey-ack))'\s*,\s*([^\n]*)/g)) {
      assert.match(rest, new RegExp(`^${builders[event]}\\(`), `${file}: ${event}는 ${builders[event]}로 만든다`);
      count[event] += 1;
    }
  }
  // 소스를 읽는 방식이 망가지면 위 검사가 아무것도 안 보게 되므로 개수도 본다.
  assert.deepEqual(count, { 'secret:invite': 1, 'secret:accepted': 1, 'secret:rekey-propose': 1, 'secret:rekey-ack': 1 });
});

test('secretChats.js: 맥락 서명은 방·세션을 바꾸기 전에 모양부터 보고(틀리면 400), 그대로 저장한다', () => {
  const source = read('secretChats.js');
  const create = section(source, "router.post('/secret-chats', ", "router.get('/secret-chats/:roomId/invite'");
  const createParse = create.indexOf("parseContextSignature(initiatorContextSignature, 'initiatorContextSignature')");
  assert.ok(createParse > 0);
  for (const write of ['deleteRoom(', 'insertRoom(', 'addRoomMembers(', 'insertSecretSession(']) {
    assert.ok(create.indexOf(write) > createParse, `${write} 전에 거른다`);
  }
  assert.match(create, /if \(initiatorContext\.error\) return res\.status\(400\)\.json\(\{ error: initiatorContext\.error \}\);/);
  assert.match(create, /initiatorContextSignature: initiatorContext\.value,/);
  // 규약 번호도 같은 자리에서 — 모양이 틀리면 400, 맞으면 그대로 저장(서버는 이 값으로 아무것도 정하지 않는다).
  const protocolParse = create.indexOf('parseSecretProtocol(protocol)');
  assert.ok(protocolParse > 0);
  for (const write of ['deleteRoom(', 'insertRoom(', 'addRoomMembers(', 'insertSecretSession(']) {
    assert.ok(create.indexOf(write) > protocolParse, `${write} 전에 거른다`);
  }
  assert.match(create, /if \(initiatorProtocol\.error\) return res\.status\(400\)\.json\(\{ error: initiatorProtocol\.error \}\);/);
  assert.match(create, /initiatorProtocol: initiatorProtocol\.value,/);

  // 앱이 꺼져 있어 secret:invite를 놓쳤을 때 받는 값도 같은 함수로.
  const invite = section(source, "router.get('/secret-chats/:roomId/invite'", "router.get('/secret-chats/:roomId/accepted'");
  assert.match(invite, /res\.json\(secretInvitePayload\(session\)\);/);
  // 초대한 사람이 앱을 끈 사이 상대가 수락해 secret:accepted를 놓쳤을 때 — 수락된 대화에서, 초대한 사람만, 같은 함수로.
  const accepted = section(source, "router.get('/secret-chats/:roomId/accepted'", "router.post('/secret-chats/:roomId/accept'");
  assert.match(accepted, /if \(!session \|\| session\.status !== 'active'\) \{/);
  assert.match(
    accepted,
    /if \(session\.initiatorUserId !== req\.user\.sub \|\| !\(await isRoomMember\(room\.id, req\.user\.sub\)\)\) \{\s*return res\.status\(403\)/,
  );
  assert.match(accepted, /res\.json\(secretAcceptedPayload\(session\)\);/);

  const accept = section(source, "router.post('/secret-chats/:roomId/accept'", "router.post('/secret-chats/:roomId/reject'");
  const acceptParse = accept.indexOf("parseContextSignature(responderContextSignature, 'responderContextSignature')");
  assert.ok(acceptParse > 0 && accept.indexOf('acceptSecretSession(') > acceptParse, '수락(세션 바꾸기) 전에 거른다');
  assert.match(accept, /if \(responderContext\.error\) return res\.status\(400\)\.json\(\{ error: responderContext\.error \}\);/);
  assert.match(accept, /responderContextSignature: responderContext\.value,/);
});

test('socket.js: 재키잉 제안·수락은 parseRekeyPayload로 먼저 거르고(DB를 보기 전에) 맥락 서명을 저장한다', () => {
  const source = read('socket.js');
  const propose = section(source, "socket.on('secret:rekey-propose'", "socket.on('secret:rekey-ack'");
  const ack = section(source, "socket.on('secret:rekey-ack'", "socket.on('call:join'");
  for (const handler of [propose, ack]) {
    const parse = handler.indexOf('const rekey = parseRekeyPayload(payload);');
    assert.ok(parse > 0 && handler.indexOf('findRoomById(') > parse);
    assert.match(handler, /if \(!rekey\) return;/);
    // 예전처럼 방 멤버인 비밀 대화방에서만.
    assert.match(handler, /if \(!room \|\| !room\.isSecret \|\| !\(await isRoomMember\(room\.id, socket\.data\.userId\)\)\) return;/);
  }
  assert.match(propose, /proposerContextSignature: rekey\.contextSignature,/);
  assert.match(ack, /responderContextSignature: rekey\.contextSignature,/);
  // 제안은 같은 epoch의 대기 중인 제안을 바꿔 적는다(행이 메시지마다 쌓이지 않게).
  assert.match(propose, /await replaceSecretRekeyProposal\(\{/);
  assert.doesNotMatch(propose, /insertSecretRekey\(/);
});

test('rooms.js: 방 DTO의 비밀 대화 칸은 secretRoomFields로만 채운다', () => {
  const source = read('rooms.js');
  assert.match(source, /Object\.assign\(dto, secretRoomFields\(session\)\);/);
  // 예전처럼 칸을 하나씩 손으로 적지 않는다(새 칸이 한 곳에서만 빠지는 일이 없게).
  assert.doesNotMatch(source, /dto\.secret(Status|KeyEpoch|SelfDestructSeconds|InitiatorUserId|InitiatorDeviceId|Responder\w*) =/);
});
