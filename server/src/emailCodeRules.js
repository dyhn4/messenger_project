import crypto from 'node:crypto';

/**
 * 메일로 보내는 확인 코드(6자리)의 규칙 — DB·메일 없이 시험할 수 있게 계산만 모았다. 실제로 보내고 확인하는 쪽은
 * emailCodes.js, 저장은 db/queries/emailCodes.js.
 *
 * 링크 대신 코드를 쓰는 이유: 메일을 연 기기가 서버 주소에 닿아야 링크가 열리는데, 공인 주소가 없는 사내 서버에서는 그게
 * 보장되지 않는다. 코드는 앱 화면에 넣으니 그런 제약이 없다.
 */

/** 'signup'(가입 전 이메일 확인) | 'verify'(로그인한 사람의 이메일 확인) | 'change'(새 이메일 확인) | 'reset'(비밀번호 재설정). */
export const EMAIL_CODE_PURPOSES = Object.freeze(['signup', 'verify', 'change', 'reset']);

export const CODE_LENGTH = 6;
/** 코드가 살아 있는 시간. 메일이 늦게 오는 경우를 생각해 10분. */
export const CODE_TTL_MS = 10 * 60 * 1000;
/** 코드 하나로 맞혀 볼 수 있는 횟수 — 넘으면 그 코드는 못 쓰고 새로 받아야 한다(새로 받는 것도 횟수가 막혀 있다). */
export const CODE_MAX_ATTEMPTS = 5;
/** 같은 목적·같은 주소로 다시 보내려면 기다려야 하는 시간 — 버튼을 여러 번 눌러 메일함이 넘치지 않게. */
export const CODE_RESEND_MS = 60 * 1000;

/** 000000~999999 중 하나(앞자리 0도 그대로 둔다). [randomInt]는 시험용. */
export function generateEmailCode(randomInt = crypto.randomInt) {
  return String(randomInt(0, 10 ** CODE_LENGTH)).padStart(CODE_LENGTH, '0');
}

/**
 * 사람이 넣은 코드를 6자리 숫자로 — 메일에서 복사하며 섞인 공백·하이픈은 떼고, 전각 숫자(１２３)도 받는다. 모양이 아니면 null
 * (그런 값으로는 시도 횟수를 쓰지 않는다).
 */
export function normalizeEmailCode(input) {
  if (typeof input !== 'string' || input.length > 40) return null;
  const digits = input
    .normalize('NFKC')
    .replace(/[\s-]/g, '');
  return /^\d{6}$/.test(digits) ? digits : null;
}

/**
 * 저장할 코드 해시 — 목적·주소를 함께 넣어서, 다른 목적이나 다른 주소로 받은 코드와 같은 값이 나오지 않게 한다. [keyedHash]는
 * 서버 비밀값으로 만드는 해시(crypto.js lookupHash)를 받는다 — DB만 새어서는 코드를 거꾸로 알아낼 수 없게.
 */
export function emailCodeHash(keyedHash, { purpose, emailLookup, code }) {
  return keyedHash(`email-code|${purpose}|${emailLookup}|${code}`);
}

/** 두 해시가 같은지 — 글자 수가 다르면 바로 거짓, 같으면 걸리는 시간이 값과 무관하게. */
export function sameCodeHash(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  return crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b));
}

/** 마지막으로 보낸 지 [CODE_RESEND_MS]가 안 지났으면 남은 시간(ms), 아니면 0. */
export function resendWaitMs(lastSentAt, now = Date.now()) {
  if (!lastSentAt) return 0;
  const elapsed = now - new Date(lastSentAt).getTime();
  return elapsed >= CODE_RESEND_MS || elapsed < 0 ? 0 : CODE_RESEND_MS - elapsed;
}

/**
 * 저장된 코드 행으로 지금 이 코드를 받을 수 있는지 — 'ok' | 'missing'(받은 코드가 없음) | 'expired' | 'exhausted'(시도를 다 씀).
 * 맞는지(해시 비교)는 시도를 한 칸 쓴 뒤에 따로 본다(emailCodes.js).
 */
export function emailCodeState(row, now = Date.now()) {
  if (!row) return 'missing';
  if (new Date(row.expiresAt).getTime() <= now) return 'expired';
  if ((row.attempts ?? 0) >= CODE_MAX_ATTEMPTS) return 'exhausted';
  return 'ok';
}

/** 화면에 보일 문구 — 코드가 틀렸거나 못 쓰게 됐을 때. 남은 횟수는 틀렸을 때만 알려 준다. */
export function emailCodeError(state, { attemptsLeft } = {}) {
  switch (state) {
    case 'missing':
    case 'expired':
      return '확인 코드가 없거나 만료되었습니다. 코드를 다시 받으세요.';
    case 'exhausted':
      return '확인 코드를 너무 많이 틀렸습니다. 코드를 다시 받으세요.';
    case 'invalid':
      return '확인 코드 모양이 아닙니다. 메일로 받은 6자리 숫자를 넣으세요.';
    default:
      return attemptsLeft > 0
        ? `확인 코드가 맞지 않습니다. (${attemptsLeft}번 더 시도할 수 있습니다)`
        : '확인 코드를 너무 많이 틀렸습니다. 코드를 다시 받으세요.';
  }
}
