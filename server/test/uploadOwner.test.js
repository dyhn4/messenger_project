// 업로드 파일의 "올린 사람" 규칙 단위 테스트 — 비밀 대화가 받는 첨부(sendMessage.js)와 자동 삭제가 지우는 파일(secretExpiry.js)이
// 같은 기준(upload.js ownedUploadClaims)을 쓴다. `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import { ownedUploadClaims, resolveRawUrl, signFileUrl, uploadFileNameOf } from '../src/upload.js';

const ALICE = '11111111-1111-4111-8111-111111111111';
const BOB = '22222222-2222-4222-8222-222222222222';
const A_FILE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.bin';
const A_THUMB = 'abababab-abab-4bab-8bab-abababababab.bin';
const B_FILE = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.png';
const B_COMMENT_FILE = 'bdbdbdbd-bdbd-4dbd-8dbd-bdbdbdbdbdbd.bin';
const OLD_FILE = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg'; // uploads 표가 생기기 전에 올린 파일 — 기록이 없다.

// uploads 표: 저장 이름 → 올린 사람.
const uploaders = new Map([
  [A_FILE, ALICE],
  [A_THUMB, ALICE],
  [B_FILE, BOB],
  [B_COMMENT_FILE, BOB],
]);

const stored = (name) => `/uploads/${name}`;

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

test('uploadFileNameOf: 미서명 저장 경로(/uploads/<이름>)일 때만 이름을 돌려준다', () => {
  assert.equal(uploadFileNameOf(stored(A_FILE)), A_FILE);
  // 서명 링크·외부 주소·하위 경로·접두어 없는 이름·빈 이름은 저장 경로가 아니다.
  assert.equal(uploadFileNameOf(signFileUrl(stored(A_FILE))), null);
  assert.equal(uploadFileNameOf(`https://example.com/uploads/${A_FILE}`), null);
  assert.equal(uploadFileNameOf(`/uploads/sub/${A_FILE}`), null);
  assert.equal(uploadFileNameOf(`/uploads/sub\\${A_FILE}`), null);
  assert.equal(uploadFileNameOf(`uploads/${A_FILE}`), null);
  assert.equal(uploadFileNameOf(A_FILE), null);
  assert.equal(uploadFileNameOf('/uploads/'), null);
  // 업로드 폴더 자신이나 그 위를 가리키는 이름은 절대 파일 이름으로 보지 않는다(지우는 쪽에서 path.join에 쓰인다).
  assert.equal(uploadFileNameOf('/uploads/.'), null);
  assert.equal(uploadFileNameOf('/uploads/..'), null);
  for (const notString of [null, undefined, 42, {}, [stored(A_FILE)]]) {
    assert.equal(uploadFileNameOf(notString), null);
  }
});

test('ownedUploadClaims: uploads 표가 실은 사람이 직접 올렸다고 말하는 파일만 남긴다', () => {
  const claims = [
    { path: stored(A_FILE), ownerId: ALICE, tag: 'own' },
    { path: stored(B_FILE), ownerId: ALICE, tag: 'someone else uploaded it' },
    { path: stored(OLD_FILE), ownerId: ALICE, tag: 'no record' },
    { path: stored(A_THUMB), ownerId: null, tag: 'unknown sender' },
    { path: `/uploads/sub/${A_FILE}`, ownerId: ALICE, tag: 'not a stored path' },
    { path: null, ownerId: ALICE, tag: 'empty' },
  ];
  const owned = ownedUploadClaims(claims, uploaders);
  // 다른 필드(메시지 id 등)는 그대로 둔 채 걸러낸다.
  assert.deepEqual(owned, [{ path: stored(A_FILE), ownerId: ALICE, tag: 'own' }]);
  assert.deepEqual(ownedUploadClaims([], uploaders), []);
});

test('ownedUploadClaims: 올린 사람 계정이 지워져 기록이 null이어도, 실은 사람을 모르는 경우와 짝지어 통과하지 않는다', () => {
  const orphan = new Map([[A_FILE, null]]);
  assert.deepEqual(ownedUploadClaims([{ path: stored(A_FILE), ownerId: null }], orphan), []);
  assert.deepEqual(ownedUploadClaims([{ path: stored(A_FILE), ownerId: ALICE }], orphan), []);
});

test('비밀 대화 첨부 — 남의 파일 서명 링크를 실으면 거절되고, 내가 올린 파일은 서명 링크로 와도 받는다', () => {
  // sendMessage.js secretAttachmentDenial과 같은 순서: 서명 링크를 원본 경로로 되돌린 뒤 올린 사람을 본다.
  const claimOf = (url, ownerId) => ({ path: resolveRawUrl(url), ownerId });

  // 감사에서 찾은 공격: Bob의 파일 링크(볼 수 있는 방에서 받은 것)를 Alice가 자동 삭제를 켠 비밀 대화로 보낸다.
  const attack = [claimOf(signFileUrl(stored(B_FILE)), ALICE)];
  assert.equal(attack[0].path, stored(B_FILE));
  assert.equal(ownedUploadClaims(attack, uploaders).length, 0);
  // 저장 경로를 그대로 실어도 마찬가지.
  assert.equal(ownedUploadClaims([claimOf(stored(B_FILE), ALICE)], uploaders).length, 0);

  // 정상: 비밀 대화 앱은 방금 올린 암호화 파일의 저장 경로(원본·미리보기)를 싣는다.
  const legit = [claimOf(stored(A_FILE), ALICE), claimOf(stored(A_THUMB), ALICE)];
  assert.equal(ownedUploadClaims(legit, uploaders).length, legit.length);
  assert.equal(ownedUploadClaims([claimOf(signFileUrl(stored(A_FILE)), ALICE)], uploaders).length, 1);

  // 만료된 서명 링크는 원본으로 되돌릴 수 없다(null) — 실은 파일로 인정하지 않는다.
  const expired = claimOf(signedHoursAgo(stored(A_FILE), 3), ALICE);
  assert.equal(expired.path, null);
  assert.equal(ownedUploadClaims([expired], uploaders).length, 0);
});

test('자동 삭제 후보 — 메시지·첨부는 보낸 사람, 댓글은 단 사람 기준으로 본다', () => {
  // secretExpiry.js filesToRemove가 만드는 모양: 한 메시지(Alice가 보냄)의 파일·미리보기·첨부, 그 메시지에 Bob이 단 댓글의 파일.
  const claims = [
    { messageId: 'm1', ownerId: ALICE, path: stored(A_FILE) },
    { messageId: 'm1', ownerId: ALICE, path: stored(A_THUMB) },
    { messageId: 'm1', ownerId: ALICE, path: stored(B_FILE) }, // Alice 메시지에 실린 Bob의 파일 — 후보가 아니다.
    { messageId: 'm1', ownerId: ALICE, path: stored(OLD_FILE) }, // 기록 없는 옛 파일 — 후보가 아니다.
    { messageId: 'm1', ownerId: BOB, path: stored(B_COMMENT_FILE) }, // Bob이 단 댓글의 Bob 파일 — 후보.
  ];
  assert.deepEqual(
    ownedUploadClaims(claims, uploaders).map((c) => [c.ownerId, c.path]),
    [
      [ALICE, stored(A_FILE)],
      [ALICE, stored(A_THUMB)],
      [BOB, stored(B_COMMENT_FILE)],
    ],
  );
});
