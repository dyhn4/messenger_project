// 클라이언트가 보낸 파일 참조를 받을지 정하는 규칙 단위 테스트(fileRefRules.js) — 메시지·댓글·문의·예약 메시지·앨범·북마크가
// 같은 규칙을 쓴다. `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import jwt from 'jsonwebtoken';
import {
  decideFileRefs,
  fileRefPath,
  lookupPathsOf,
  presentRefs,
  storedPathsAllowed,
} from '../src/fileRefRules.js';
import { knownUploadPath, resolveRawUrl, signFileUrl } from '../src/upload.js';

const ALICE = '11111111-1111-4111-8111-111111111111';
const BOB = '22222222-2222-4222-8222-222222222222';
const A_FILE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.png';
const A_THUMB = 'abababab-abab-4bab-8bab-abababababab.jpg';
const B_FILE = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.pdf';
const OLD_FILE = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg'; // uploads 표가 생기기 전에 올린 파일 — 기록이 없다.
const stored = (name) => `/uploads/${name}`;

const uploaders = new Map([
  [A_FILE, ALICE],
  [A_THUMB, ALICE],
  [B_FILE, BOB],
]);

/** [hours]시간 전에 서명된 링크 — 최대 2시간이라 이미 만료된 것. */
function signedHoursAgo(path, hours) {
  const issuedAt = Date.now() - hours * 60 * 60 * 1000;
  const clock = mock.method(Date, 'now', () => issuedAt);
  try {
    return signFileUrl(path);
  } finally {
    clock.mock.restore();
  }
}

/**
 * 이 서버가 예전(AES 토큰 전)에 발급하던 모양의 JWT 링크(아직 만료 전). 서버는 이제 서명을 확인하기도 전에 모양(점이 든 토큰)만
 * 보고 거절하므로, 테스트는 서버 비밀값 대신 아무 값으로 서명해도 같은 것을 확인한다.
 */
function legacyJwtLink(name) {
  const exp = Math.floor(Date.now() / 1000) + 3600;
  return `/files/${jwt.sign({ file: name, type: 'file', exp }, 'any-secret', { noTimestamp: true })}`;
}

test('fileRefPath: 서명 링크(만료돼도 서명만 맞으면)와 미서명 저장 경로만 저장 경로로 푼다', () => {
  assert.equal(fileRefPath(stored(A_FILE)), stored(A_FILE));
  assert.equal(fileRefPath(signFileUrl(stored(A_FILE), 'a.png')), stored(A_FILE));
  assert.equal(fileRefPath(signedHoursAgo(stored(A_FILE), 5)), stored(A_FILE));
  for (const bad of [
    `https://evil.example/uploads/${A_FILE}`,
    `/uploads/sub/${A_FILE}`,
    '/uploads/..',
    '/files/not-a-token',
    `/files/${'A'.repeat(60)}`,
    `/files/${jwt.sign({ file: A_FILE, type: 'file' }, 'not-the-server-secret')}`,
    '',
    null,
    undefined,
    42,
    { url: stored(A_FILE) },
  ]) {
    assert.equal(fileRefPath(bad), null, String(bad));
  }
});

test('예전 JWT 다운로드 링크는 더 받지 않는다 — 만료 전이어도(모양만 보고 거절한다)', () => {
  // JWT는 base64만 풀면 파일 이름이 보이고, 만료를 보지 않는 경로(knownUploadPath)에서는 서명만 맞으면 영영 통했다.
  const link = legacyJwtLink(B_FILE);
  assert.equal(resolveRawUrl(link), null);
  assert.equal(knownUploadPath(link), null);
  assert.equal(fileRefPath(link), null);
  assert.equal(decideFileRefs([link], { senderId: BOB, uploaders }).ok, false);
});

test('직접 올린 파일 — 저장 경로로 오든 서명 링크(만료돼도)로 오든 받는다', () => {
  const refs = [stored(A_FILE), signedHoursAgo(stored(A_THUMB), 3)];
  const decision = decideFileRefs(refs, { senderId: ALICE, uploaders });
  assert.equal(decision.ok, true);
  assert.deepEqual([...decision.paths.values()], [stored(A_FILE), stored(A_THUMB)]);
  assert.equal(decision.paths.get(refs[1]), stored(A_THUMB));
});

test('감사의 공격: 알게 된 남의 파일 이름을 실으면 거절 — 지금 볼 수 있는 방에 그 파일이 없으면', () => {
  // 방에서 내보내진 뒤 예전 링크에서 읽은 이름(/uploads/<uuid>)을 내 메시지·댓글에 싣는 경우.
  assert.equal(decideFileRefs([stored(B_FILE)], { senderId: ALICE, uploaders }).ok, false);
  // 기록이 없는 옛 파일도 올린 사람으로 인정할 수 없다.
  assert.equal(decideFileRefs([stored(OLD_FILE)], { senderId: ALICE, uploaders }).ok, false);
  // 살아 있는(만료 전) 서명 링크라는 것만으로도 받지 않는다 — 남에게 받은 링크라도 열리는 동안은 열리므로.
  assert.equal(decideFileRefs([signFileUrl(stored(B_FILE))], { senderId: ALICE, uploaders }).ok, false);
});

test('메시지 전달 — 지금 들어가 있는 방에서 볼 수 있는 파일이면 남의 파일도, 몇 시간 지난 링크도 받는다', () => {
  const reachable = new Set([stored(B_FILE), stored(OLD_FILE)]);
  const refs = [signedHoursAgo(stored(B_FILE), 4), signFileUrl(stored(OLD_FILE))];
  const decision = decideFileRefs(refs, { senderId: ALICE, uploaders, reachable });
  assert.equal(decision.ok, true);
  assert.deepEqual([...decision.paths.values()], [stored(B_FILE), stored(OLD_FILE)]);
});

test('미서명 저장 경로로 온 남의 파일은 볼 수 있는 방에 있어도 받지 않는다 — 앱은 자기 파일에만 그 모양을 쓴다', () => {
  const reachable = new Set([stored(B_FILE)]);
  assert.equal(decideFileRefs([stored(B_FILE)], { senderId: ALICE, uploaders, reachable }).ok, false);
  assert.equal(decideFileRefs([signFileUrl(stored(B_FILE))], { senderId: ALICE, uploaders, reachable }).ok, true);
});

test('고치기 — 그 기록에 원래 있던 파일이면 남의 파일이어도 그대로 다시 받는다', () => {
  const existing = [stored(B_FILE)];
  const expired = signedHoursAgo(stored(B_FILE), 6);
  assert.equal(decideFileRefs([expired], { senderId: ALICE, uploaders, existing }).ok, true);
  // 다른 파일은 여전히 거절.
  assert.equal(decideFileRefs([stored(OLD_FILE)], { senderId: ALICE, uploaders, existing }).ok, false);
});

test('비밀 대화(ownedOnly) — 직접 올린 파일만, 볼 수 있는 방의 파일·원래 있던 파일도 안 된다', () => {
  const reachable = new Set([stored(B_FILE)]);
  const existing = [stored(B_FILE)];
  assert.equal(decideFileRefs([stored(A_FILE)], { senderId: ALICE, uploaders, ownedOnly: true }).ok, true);
  assert.equal(
    decideFileRefs([signFileUrl(stored(B_FILE))], { senderId: ALICE, uploaders, reachable, existing, ownedOnly: true }).ok,
    false,
  );
});

test('하나라도 안 되면 전체 거절 — 일부만 빼고 보내지 않는다', () => {
  const decision = decideFileRefs([stored(A_FILE), stored(B_FILE), '/files/garbage'], { senderId: ALICE, uploaders });
  assert.equal(decision.ok, false);
  assert.deepEqual(decision.rejected, [stored(B_FILE), '/files/garbage']);
});

test('빈 값·문자열 아님은 "첨부 없음" — 검사 대상이 아니다', () => {
  assert.deepEqual(presentRefs([null, undefined, '', 0, stored(A_FILE)]), [stored(A_FILE)]);
  const decision = decideFileRefs([null, '', undefined], { senderId: ALICE, uploaders });
  assert.equal(decision.ok, true);
  assert.equal(decision.paths.size, 0);
  // 보내는 사람을 모르면(null) 올린 사람 기록과 맞춰 보지 않는다.
  assert.equal(decideFileRefs([stored(A_FILE)], { senderId: null, uploaders: new Map([[A_FILE, null]]) }).ok, false);
});

test('lookupPathsOf: 알아볼 수 없는 참조가 있으면 조회하지 않고(null), 원래 있던 경로는 빼고, 방 확인 후보는 서명 링크만', () => {
  assert.equal(lookupPathsOf([stored(A_FILE), 'https://x.example/a.png']), null);
  assert.deepEqual(lookupPathsOf([stored(A_FILE), signFileUrl(stored(A_FILE)), stored(B_FILE)], [stored(B_FILE)]), {
    paths: [stored(A_FILE)],
    signedPaths: [stored(A_FILE)],
  });
  assert.deepEqual(lookupPathsOf([stored(OLD_FILE), signFileUrl(stored(B_FILE))]), {
    paths: [stored(OLD_FILE), stored(B_FILE)],
    signedPaths: [stored(B_FILE)],
  });
});

test('예약 메시지 발송(storedPathsAllowed) — 기록 있는 파일은 보내는 사람 것만, 기록 없는 옛 파일은 예전처럼', () => {
  assert.equal(storedPathsAllowed([stored(A_FILE), stored(OLD_FILE)], { senderId: ALICE, uploaders }), true);
  assert.equal(storedPathsAllowed([stored(B_FILE)], { senderId: ALICE, uploaders }), false);
  // 저장 경로 모양이 아니면(서명 링크·바깥 주소가 섞여 저장됐다면) 보내지 않는다.
  assert.equal(storedPathsAllowed([signFileUrl(stored(A_FILE))], { senderId: ALICE, uploaders }), false);
  assert.equal(storedPathsAllowed(['https://x.example/a.png'], { senderId: ALICE, uploaders }), false);
});
