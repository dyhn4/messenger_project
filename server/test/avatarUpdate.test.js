// 내 프로필(PATCH /users/me)의 이름·아바타 검사와 /files/resign의 "공개 프로필 사진" 판정(avatarRules.js) 단위 테스트 —
// `node --test test/*.test.js` (DB·서버 없이 돈다). 파일을 누가 올렸는지(uploads 표) 확인은 users.js가 upload.js
// ownedUploadClaims로 하고(그 규칙은 uploadOwner.test.js), 여기서는 그 확인이 필요한 경우를 정확히 골라내는지 본다.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { mock, test } from 'node:test';
import {
  AVATAR_COLOR_ERROR,
  AVATAR_EMOJI_ERROR,
  AVATAR_PHOTO_ERROR,
  AVATAR_TYPE_ERROR,
  USER_NAME_MAX,
  isAvatarColor,
  isAvatarEmoji,
  isPublicAvatarFile,
  parseUserName,
  planAvatarUpdate,
  safeAvatarColor,
} from '../src/avatarRules.js';
import { signFileUrl } from '../src/upload.js';

const ME = '11111111-1111-4111-8111-111111111111';
const OTHER = '22222222-2222-4222-8222-222222222222';
const MY_PHOTO = '/uploads/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.png';
const NEW_PHOTO = '/uploads/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.png';

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

// 앱(캐릭터 고르기)과 가입(auth.js)이 실제로 쓰는 이모지·배경색 — 소스에서 그대로 읽어, 둘 중 하나가 목록을 바꿔도 서버가
// 거절하지 않는지 함께 지킨다. 저장소 밖(서버 폴더만 따로 둔 곳)에서 돌리면 앱 쪽은 건너뛴다.
const authSource = fs.readFileSync(new URL('../src/auth.js', import.meta.url), 'utf8');
const clientDialogUrl = new URL('../../client/lib/screens/my_profile_dialog.dart', import.meta.url);
const clientSource = fs.existsSync(clientDialogUrl) ? fs.readFileSync(clientDialogUrl, 'utf8') : null;

function listBody(source, name) {
  const match = new RegExp(`${name}\\s*=\\s*\\[([\\s\\S]*?)\\];`).exec(source);
  assert.ok(match, `${name} 목록을 찾지 못했다`);
  return match[1];
}
const quoted = (body) => [...body.matchAll(/["']([^"'\n]+)["']/g)].map((m) => m[1]);

test('가입·앱 캐릭터 고르기가 쓰는 이모지와 배경색은 모두 받는다', () => {
  const authEmojis = quoted(listBody(authSource, 'CHARACTER_EMOJIS'));
  const authColors = quoted(listBody(authSource, 'CHARACTER_COLORS'));
  assert.equal(authEmojis.length, 12);
  assert.equal(authColors.length, 10);
  for (const e of authEmojis) assert.ok(isAvatarEmoji(e), `가입 이모지 ${e}`);
  for (const c of authColors) assert.ok(isAvatarColor(c), `가입 배경색 ${c}`);
});

test('앱 캐릭터 고르기(my_profile_dialog.dart)의 이모지·배경색 — colorToHex가 보내는 모양 그대로 받는다', { skip: !clientSource }, () => {
  const emojis = quoted(listBody(clientSource, '_characterEmojis'));
  const colors = [...listBody(clientSource, '_characterColors').matchAll(/Color\(0x([0-9A-Fa-f]{8})\)/g)].map(
    // avatar_utils.dart colorToHex: ARGB 8자리에서 알파 2자리를 떼고 대문자로 '#RRGGBB'.
    (m) => `#${m[1].slice(2).toUpperCase()}`,
  );
  assert.equal(emojis.length, 12);
  assert.equal(colors.length, 10);
  for (const e of emojis) assert.ok(isAvatarEmoji(e), `앱 이모지 ${e}`);
  for (const c of colors) assert.ok(isAvatarColor(c), `앱 배경색 ${c}`);
});

test('isAvatarEmoji: 이모지 한 덩어리(ZWJ 조합·피부색·국기 포함)만 받는다', () => {
  for (const ok of ['😀', '👍🏽', '🧑‍✈️', '👨‍👩‍👧‍👦', '🇰🇷', '❤️', '🏳️‍🌈']) assert.ok(isAvatarEmoji(ok), ok);
  for (const bad of [
    '',
    'a',
    '홍',
    '1', // 이모지 부품이기만 한 글자
    '#',
    '1️⃣',
    '\u200D', // ZWJ 혼자
    '\uFE0F',
    '😀😀', // 두 덩어리
    '😀 ',
    '😀\n',
    '😀a',
    '<b>😀</b>',
    '👍'.repeat(20),
    null,
    undefined,
    42,
    ['😀'],
    { emoji: '😀' },
  ]) {
    assert.equal(isAvatarEmoji(bad), false, JSON.stringify(bad));
  }
});

test('isAvatarColor·safeAvatarColor: 앱 parseHexColor가 읽을 수 있는 #RRGGBB만', () => {
  for (const ok of ['#9AA6B2', '#4c6ef5', '#000000', '#FFFFFF']) {
    assert.ok(isAvatarColor(ok), ok);
    assert.equal(safeAvatarColor(ok), ok);
  }
  // 이런 값 하나가 저장돼 있으면 그 사람을 그리는 다른 사람의 앱(parseHexColor → int.parse)이 예외로 깨진다.
  for (const bad of ['#FFF', '9AA6B2', '#9AA6B2FF', '#GGGGGG', ' #9AA6B2', '#9AA6B2 ', 'red', 'rgb(1,2,3)', '', null, 7]) {
    assert.equal(isAvatarColor(bad), false, JSON.stringify(bad));
    assert.equal(safeAvatarColor(bad), null, JSON.stringify(bad));
  }
});

test('parseUserName: 앞뒤 공백을 빼고, 비었거나 너무 길거나 제어·방향 문자가 있으면 거절', () => {
  assert.deepEqual(parseUserName('  홍길동  '), { value: '홍길동' });
  assert.deepEqual(parseUserName('개발자 🧑‍💻'), { value: '개발자 🧑‍💻' }); // 이모지(ZWJ 조합)는 이름에 써도 된다.
  for (const empty of ['', '   ', '\t']) assert.equal(parseUserName(empty).error, '이름을 입력하세요.');
  for (const notString of [null, undefined, 42, {}, ['홍길동']]) {
    assert.equal(parseUserName(notString).error, '이름을 입력하세요.', JSON.stringify(notString));
  }

  // 글자 수는 화면과 같은 단위(이모지 한 덩어리 = 1자)로 센다.
  assert.equal(USER_NAME_MAX, 30);
  assert.deepEqual(parseUserName('가'.repeat(USER_NAME_MAX)), { value: '가'.repeat(USER_NAME_MAX) });
  assert.deepEqual(parseUserName('🧑‍💻'.repeat(USER_NAME_MAX)).value, '🧑‍💻'.repeat(USER_NAME_MAX));
  assert.equal(parseUserName('가'.repeat(USER_NAME_MAX + 1)).error, `이름은 ${USER_NAME_MAX}자 이내로 입력하세요.`);

  for (const sneaky of ['홍\n길동', '홍\t길동', '관리자\u202E자리관', '홍\u2066길동', '홍\u0000길동']) {
    assert.equal(parseUserName(sneaky).error, '이름에 쓸 수 없는 문자가 들어 있습니다.', JSON.stringify(sneaky));
  }
});

test('planAvatarUpdate: 종류가 없거나 모르는 값이면 거절', () => {
  for (const avatarType of [undefined, null, '', 'image', 'PHOTO', 42]) {
    assert.deepEqual(planAvatarUpdate({ avatarType }), { error: AVATAR_TYPE_ERROR }, String(avatarType));
  }
  assert.deepEqual(planAvatarUpdate(undefined), { error: AVATAR_TYPE_ERROR });
});

test('planAvatarUpdate: 초기화는 이모지·배경색·사진을 모두 비운다(같이 온 값은 버린다)', () => {
  assert.deepEqual(
    planAvatarUpdate({ avatarType: 'initial', avatarEmoji: '😀', avatarColor: 'nope', avatarUrl: NEW_PHOTO }),
    { patch: { avatarType: 'initial', avatarEmoji: null, avatarColor: null, avatarUrl: null }, uploadToVerify: null },
  );
});

test('planAvatarUpdate: 캐릭터는 이모지 하나 + #RRGGBB 배경색, 사진 칸은 비운다', () => {
  assert.deepEqual(planAvatarUpdate({ avatarType: 'character', avatarEmoji: '🧔', avatarColor: '#0CA678', avatarUrl: MY_PHOTO }), {
    patch: { avatarType: 'character', avatarEmoji: '🧔', avatarColor: '#0CA678', avatarUrl: null },
    uploadToVerify: null,
  });
  assert.deepEqual(planAvatarUpdate({ avatarType: 'character', avatarEmoji: 'hello', avatarColor: '#0CA678' }), {
    error: AVATAR_EMOJI_ERROR,
  });
  assert.deepEqual(planAvatarUpdate({ avatarType: 'character', avatarColor: '#0CA678' }), { error: AVATAR_EMOJI_ERROR });
  for (const avatarColor of [undefined, null, '#FFF', 'red', '#0CA678;']) {
    assert.deepEqual(
      planAvatarUpdate({ avatarType: 'character', avatarEmoji: '🧔', avatarColor }),
      { error: AVATAR_COLOR_ERROR },
      String(avatarColor),
    );
  }
});

test('planAvatarUpdate: 새 사진은 미서명 저장 경로로 되돌려 "내가 올렸는지" 확인을 맡긴다', () => {
  const expected = {
    patch: { avatarType: 'photo', avatarEmoji: null, avatarColor: null, avatarUrl: NEW_PHOTO },
    uploadToVerify: NEW_PHOTO,
  };
  // 앱은 업로드 응답의 url(미서명 경로)을 보낸다 — 서명 링크(signedUrl)로 보내도 같은 경로로 알아본다.
  assert.deepEqual(planAvatarUpdate({ avatarType: 'photo', avatarUrl: NEW_PHOTO }, { currentAvatarUrl: MY_PHOTO }), expected);
  assert.deepEqual(planAvatarUpdate({ avatarType: 'photo', avatarUrl: signFileUrl(NEW_PHOTO) }), expected);
  // 이모지·배경색은 사진에서 안 쓰므로 비운다.
  assert.deepEqual(
    planAvatarUpdate({ avatarType: 'photo', avatarUrl: NEW_PHOTO, avatarEmoji: '😀', avatarColor: '#FFFFFF' }),
    expected,
  );
});

test('planAvatarUpdate: 저장 경로로 못 되돌리는 값·만료된 새 링크는 거절(같은 문구)', () => {
  for (const avatarUrl of [
    undefined,
    null,
    '',
    42,
    { url: NEW_PHOTO },
    'https://evil.example/x.png',
    'uploads/x.png',
    '/uploads/',
    '/uploads/..',
    '/uploads/.',
    '/uploads/sub/x.png',
    '/files/not-a-token',
    signedHoursAgo(NEW_PHOTO, 3), // 지금 사진이 아닌 파일의 만료된 링크
  ]) {
    assert.deepEqual(
      planAvatarUpdate({ avatarType: 'photo', avatarUrl }, { currentAvatarUrl: MY_PHOTO }),
      { error: AVATAR_PHOTO_ERROR },
      String(avatarUrl),
    );
  }
});

test('planAvatarUpdate: 지금 쓰는 사진을 다시 보내면(만료된 서명 링크여도) 확인 없이 그대로 둔다', () => {
  const kept = {
    patch: { avatarType: 'photo', avatarEmoji: null, avatarColor: null, avatarUrl: MY_PHOTO },
    uploadToVerify: null,
  };
  for (const avatarUrl of [MY_PHOTO, signFileUrl(MY_PHOTO), signedHoursAgo(MY_PHOTO, 5)]) {
    assert.deepEqual(planAvatarUpdate({ avatarType: 'photo', avatarUrl }, { currentAvatarUrl: MY_PHOTO }), kept);
  }
  // 지금 사진이 없으면(사진 아바타가 아니면 호출부가 null을 넘긴다) "그대로 두기"가 없다 — 새 사진과 같은 확인을 거친다.
  assert.deepEqual(planAvatarUpdate({ avatarType: 'photo', avatarUrl: MY_PHOTO }, { currentAvatarUrl: null }), {
    patch: kept.patch,
    uploadToVerify: MY_PHOTO,
  });
  assert.deepEqual(planAvatarUpdate({ avatarType: 'photo', avatarUrl: signedHoursAgo(MY_PHOTO, 5) }), {
    error: AVATAR_PHOTO_ERROR,
  });
});

test('isPublicAvatarFile: 기록이 있는 파일은 올린 사람 자신의 프로필 사진일 때만 공개', () => {
  // 지금 아무의 프로필 사진도 아니면 공개가 아니다.
  assert.equal(isPublicAvatarFile({ holderIds: [], upload: null }), false);
  assert.equal(isPublicAvatarFile({ holderIds: [], upload: { uploaderId: ME } }), false);
  // uploads 표가 생기기 전에 올린 사진·서버 캐릭터 세트 그림(기록 없음) — 예전처럼 누군가의 프로필 사진이면 된다.
  assert.equal(isPublicAvatarFile({ holderIds: [OTHER], upload: null }), true);
  // 올린 사람이 자기 프로필 사진으로 쓰는 파일.
  assert.equal(isPublicAvatarFile({ holderIds: [ME], upload: { uploaderId: ME } }), true);
  assert.equal(isPublicAvatarFile({ holderIds: [OTHER, ME], upload: { uploaderId: ME } }), true);
  // 남이 올린 파일을 프로필 사진으로 걸어 둔 경우 — 그 사진 링크를 아무에게나 새로 주지 않는다.
  assert.equal(isPublicAvatarFile({ holderIds: [OTHER], upload: { uploaderId: ME } }), false);
  // 올린 계정이 지워진 파일(uploaderId null).
  assert.equal(isPublicAvatarFile({ holderIds: [OTHER], upload: { uploaderId: null } }), false);
  assert.equal(isPublicAvatarFile({ holderIds: undefined, upload: null }), false);
});
