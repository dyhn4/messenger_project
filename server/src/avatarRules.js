import { graphemeLength } from './permissions.js';
import { knownUploadPath, toStoredUploadUrl, uploadFileNameOf } from './upload.js';

/**
 * 내 프로필(PATCH /users/me)의 이름·아바타 값 검사와, 프로필 사진 파일을 누구에게나 보여도 되는지의 판정 — DB를 읽지 않는
 * 순수 규칙이라 단위 테스트가 그대로 돌린다(test/avatarUpdate.test.js). 파일을 누가 올렸는지처럼 DB가 필요한 확인은 값만
 * 돌려주고 호출부(users.js·fileResign.js)가 한다.
 *
 * 예전엔 아바타 칸을 보낸 그대로 저장해서, 남이 올린 파일 경로(/uploads/<이름>)를 프로필 사진으로 걸어 두면 내 프로필 DTO가
 * 그 파일의 새 다운로드 링크를 매번 실어 주고 /files/resign도 누구에게나 새 링크를 줬다(방에서 나간 뒤에도, 지운 파일이어도).
 * 배경색도 아무 문자열이나 받아서, 모양이 다른 값 하나로 그 사람을 그리는 다른 사람의 앱 화면(아바타)이 깨질 수 있었다.
 */

/** 아바타 종류 — 앱 프로필 사진 편집(my_profile_dialog.dart: 초기화·캐릭터·사진)과 가입(auth.js의 'character')이 쓰는 값. */
export const AVATAR_TYPES = ['initial', 'character', 'photo'];

/**
 * 이름 길이 상한(글자 단위 — 이모지 한 덩어리 = 1자, permissions.js graphemeLength). 이름은 방 목록·알림 제목·시스템
 * 메시지("OOO 님이 참여했습니다")에 그대로 실리므로, 끝없이 긴 이름으로 다른 사람 화면·알림을 덮지 못하게 한다.
 */
export const USER_NAME_MAX = 30;

export const AVATAR_TYPE_ERROR = '프로필 사진 종류가 올바르지 않습니다.';
export const AVATAR_EMOJI_ERROR = '캐릭터 이모지가 올바르지 않습니다.';
export const AVATAR_COLOR_ERROR = '캐릭터 배경색이 올바르지 않습니다.';
// 남의 파일이든, 없는 파일이든, 만료된 링크든 같은 문구로 답한다(어떤 파일이 있는지 알려주지 않게).
export const AVATAR_PHOTO_ERROR = '프로필 사진을 확인할 수 없습니다. 사진을 다시 올려 주세요.';

// 이모지 하나 — 글자 단위로 한 덩어리이고, 이모지를 이루는 문자(그림 문자·피부색·ZWJ·변형 선택자 등)로만 되어 있으며,
// 그림 문자나 국기 문자가 적어도 하나 있어야 한다(숫자·'#'처럼 이모지 부품이기만 한 글자는 안 된다). 앱의 기본 캐릭터
// 12개(ZWJ 조합 포함)와 가입 때 고르는 이모지가 모두 여기에 든다. 길이 상한은 가장 긴 조합(가족 이모지 등)도 넉넉히 들어갈 만큼.
const AVATAR_EMOJI_MAX_CODE_UNITS = 32;
const EMOJI_PARTS_ONLY = /^[\p{Extended_Pictographic}\p{Emoji_Component}]+$/u;
const EMOJI_ANCHOR = /[\p{Extended_Pictographic}\p{Regional_Indicator}]/u;

// 앱이 보내는 배경색 모양(avatar_utils.dart colorToHex → '#RRGGBB'). 앱의 parseHexColor는 이 모양이 아니면 예외를 던져
// 그 아바타를 그리는 화면을 깨뜨리므로 정확히 이 모양만 받는다.
const AVATAR_COLOR = /^#[0-9A-Fa-f]{6}$/;

// 이름에 넣으면 화면·알림을 어지럽히는 글자 — 제어 문자(줄바꿈·탭 등), 글자 방향을 뒤집는 문자(다른 이름처럼 보이게 꾸밀 수
// 있다), 폭이 없는 보이지 않는 글자(ZWSP·LRM/RLM·단어 결합자·BOM 등 — trim()이 못 지워서 빈 이름이나 똑같아 보이는 다른
// 이름을 만들 수 있다). ZWJ/ZWNJ(U+200C·U+200D)는 이모지 조합(👨‍💻 등)에 쓰여서 허용하고, 대신 보이는 글자가 하나도 없는
// 이름은 parseUserName이 따로 막는다(NAME_INVISIBLE을 다 지우면 빈 문자열).
const NAME_FORBIDDEN = /[\p{Cc}\u061C\u180E\u200B\u200E\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069\uFEFF]/u;
const NAME_INVISIBLE = /[\p{Cf}\p{Z}\s]/gu;

const graphemes = new Intl.Segmenter('ko', { granularity: 'grapheme' });

/** 캐릭터 아바타의 이모지로 쓸 수 있는 값인지(이모지 하나). */
export function isAvatarEmoji(value) {
  if (typeof value !== 'string' || !value || value.length > AVATAR_EMOJI_MAX_CODE_UNITS) return false;
  if (!EMOJI_PARTS_ONLY.test(value) || !EMOJI_ANCHOR.test(value)) return false;
  let count = 0;
  for (const _ of graphemes.segment(value)) {
    if (++count > 1) return false;
  }
  return count === 1;
}

/** 캐릭터 아바타의 배경색으로 쓸 수 있는 값인지('#RRGGBB'). */
export function isAvatarColor(value) {
  return typeof value === 'string' && AVATAR_COLOR.test(value);
}

/**
 * DTO에 실을 배경색 — 모양이 맞지 않는 값은 null(앱은 기본색으로 그린다). 검사가 생기기 전에 저장된 값이 남아 있어도
 * 그 사람을 그리는 다른 사람의 앱이 깨지지 않게 내보낼 때 한 번 더 거른다(users.js publicUser, admin.js 회원 목록).
 */
export function safeAvatarColor(value) {
  return isAvatarColor(value) ? value : null;
}

/** 프로필 이름 검사 — 앞뒤 공백을 뺀 값을 돌려준다. 통과하면 `{ value }`, 아니면 `{ error }`. */
export function parseUserName(raw) {
  if (typeof raw !== 'string') return { error: '이름을 입력하세요.' };
  const value = raw.trim();
  if (!value) return { error: '이름을 입력하세요.' };
  if (NAME_FORBIDDEN.test(value)) return { error: '이름에 쓸 수 없는 문자가 들어 있습니다.' };
  if (!value.replace(NAME_INVISIBLE, '')) return { error: '이름을 입력하세요.' };
  if (graphemeLength(value) > USER_NAME_MAX) return { error: `이름은 ${USER_NAME_MAX}자 이내로 입력하세요.` };
  return { value };
}

/**
 * PATCH /users/me에 avatarType이 왔을 때 바꿀 아바타 칸들 — 초기화·캐릭터·사진이 서로 다른 칸 조합을 쓰므로 아바타 상태를 통째로
 * 바꾼다(그 종류에서 안 쓰는 칸은 비운다). [currentAvatarUrl]은 지금 프로필 사진의 저장 경로 — 지금 아바타가 사진(avatarType
 * 'photo')이 아니면 null로 넘긴다(사진이 아닌 아바타에 남아 있던 경로를 "그대로 두기"로 다시 살리지 않게).
 * 통과하면 `{ patch, uploadToVerify }`, 아니면 `{ error }`.
 *  - initial: 이모지·배경색·사진을 모두 비운다(앱의 "초기화"가 보내는 그대로).
 *  - character: 이모지 하나 + '#RRGGBB' 배경색.
 *  - photo: ① 지금 내 프로필 사진과 같은 파일이면 그대로 둔다 — 앱이 들고 있던 서명 링크를 다시 보내도(만료됐어도) 알아본다
 *             (knownUploadPath는 서명만 맞으면 만료를 안 보므로 "원래 저장돼 있던 값"과 비교할 때만 쓴다).
 *           ② 아니면 새로 올린 사진이어야 한다 — 미서명 /uploads/<이름>으로 되돌릴 수 있어야 하고(만료·위조 링크는 안 됨), 그 파일을
 *             이 사람이 올렸는지는 uploadToVerify(저장 경로)로 돌려줘서 호출부가 uploads 표로 확인한다. 기록이 없는 파일(이 표가
 *             생기기 전에 올린 파일·이모티콘 그림)도 새 프로필 사진으로는 받지 않는다 — 서버 캐릭터 세트 그림은 따로 있는
 *             POST /users/me/avatar/character/:stickerId로 고른다.
 */
export function planAvatarUpdate(body, { currentAvatarUrl = null } = {}) {
  const { avatarType, avatarEmoji, avatarColor, avatarUrl } = body ?? {};
  if (!AVATAR_TYPES.includes(avatarType)) return { error: AVATAR_TYPE_ERROR };
  const cleared = { avatarType, avatarEmoji: null, avatarColor: null, avatarUrl: null };

  if (avatarType === 'initial') return { patch: cleared, uploadToVerify: null };

  if (avatarType === 'character') {
    if (!isAvatarEmoji(avatarEmoji)) return { error: AVATAR_EMOJI_ERROR };
    if (!isAvatarColor(avatarColor)) return { error: AVATAR_COLOR_ERROR };
    return { patch: { ...cleared, avatarEmoji, avatarColor }, uploadToVerify: null };
  }

  if (typeof avatarUrl !== 'string' || !avatarUrl) return { error: AVATAR_PHOTO_ERROR };
  if (currentAvatarUrl && (avatarUrl === currentAvatarUrl || knownUploadPath(avatarUrl) === currentAvatarUrl)) {
    return { patch: { ...cleared, avatarUrl: currentAvatarUrl }, uploadToVerify: null };
  }
  const stored = toStoredUploadUrl(avatarUrl);
  if (!uploadFileNameOf(stored)) return { error: AVATAR_PHOTO_ERROR };
  return { patch: { ...cleared, avatarUrl: stored }, uploadToVerify: stored };
}

/**
 * /files/resign: 프로필 사진이라서 방 확인 없이 새 다운로드 링크를 줘도 되는 파일인지. [holderIds]는 그 경로를 지금 프로필 사진으로
 * 쓰는 계정들(호출부가 찾은 것 — 기록이 있는 파일이면 올린 사람만 찾아봐도 된다), [upload]는 uploads 표의 그 파일 행(없으면 null).
 * 기록이 없는 파일(이 표가 생기기 전에 올린 사진·서버 캐릭터 세트 그림)은 예전처럼 누군가의 프로필 사진이기만 하면 되고, 기록이
 * 있으면 그 파일을 올린 사람 자신의 프로필 사진이어야 한다 — 남이 올린 파일을 프로필 사진으로 걸어 두고 새 링크를 받아 가지 못하게.
 */
export function isPublicAvatarFile({ holderIds, upload }) {
  if (!Array.isArray(holderIds) || holderIds.length === 0) return false;
  if (!upload) return true;
  return upload.uploaderId != null && holderIds.includes(upload.uploaderId);
}
