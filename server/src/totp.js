import crypto from 'node:crypto';

/**
 * 2단계 인증(OTP)의 **순수 규칙** — Google Authenticator·Microsoft Authenticator 같은 앱이 30초마다 바꾸는 6자리 코드(TOTP —
 * RFC 6238, HMAC-SHA1). 외부 라이브러리 없이 node:crypto로만 만든다. DB를 만지지 않아 `node --test`로 시험한다
 * (test/loginSecurity.test.js — RFC 6238 부록의 시험 값을 그대로 맞춘다).
 */

export const TOTP_DIGITS = 6;
export const TOTP_PERIOD_SECONDS = 30;
/** 앞뒤로 몇 칸(30초)까지 받을지 — 휴대폰 시계가 조금 어긋나도 되게. */
export const TOTP_WINDOW = 1;
export const RECOVERY_CODE_COUNT = 10;
export const TOTP_ISSUER = 'TangoTalk';

const BASE32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/** 바이트 → base32(RFC 4648, 패딩 없음) — 인증 앱에 손으로 넣는 비밀 키 글자. */
export function base32Encode(bytes) {
  let bits = 0;
  let value = 0;
  let out = '';
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += BASE32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += BASE32[(value << (5 - bits)) & 31];
  return out;
}

/** base32 → 바이트. 공백·하이픈·소문자·패딩은 봐준다. 틀린 글자가 있으면 null. */
export function base32Decode(text) {
  const clean = String(text ?? '')
    .toUpperCase()
    .replace(/[\s-]/g, '')
    .replace(/=+$/, '');
  let bits = 0;
  let value = 0;
  const out = [];
  for (const ch of clean) {
    const idx = BASE32.indexOf(ch);
    if (idx < 0) return null;
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 255);
      bits -= 8;
    }
  }
  return Buffer.from(out);
}

/** 새 비밀 키(20바이트 = 160비트, RFC 4226 권장) — base32 글자로. */
export function generateTotpSecret(randomBytes = crypto.randomBytes) {
  return base32Encode(randomBytes(20));
}

/** HOTP(RFC 4226) — [key] 바이트와 [counter]로 [digits]자리 숫자 글자. */
export function hotp(key, counter, digits = TOTP_DIGITS) {
  const buf = Buffer.alloc(8);
  buf.writeBigUInt64BE(BigInt(counter));
  const mac = crypto.createHmac('sha1', key).update(buf).digest();
  const offset = mac[mac.length - 1] & 0x0f;
  const bin = ((mac[offset] & 0x7f) << 24) | (mac[offset + 1] << 16) | (mac[offset + 2] << 8) | mac[offset + 3];
  return String(bin % 10 ** digits).padStart(digits, '0');
}

/** [nowMs] 시각의 30초 칸 번호. */
export function totpStep(nowMs = Date.now()) {
  return Math.floor(nowMs / 1000 / TOTP_PERIOD_SECONDS);
}

/** 그 시각의 코드(시험·화면 확인용). */
export function totpAt(secretB32, nowMs = Date.now()) {
  return hotp(base32Decode(secretB32), totpStep(nowMs));
}

/** 사람이 넣은 코드 — 숫자만 남겨 6자리면 그 글자, 아니면 null(공백·하이픈은 봐준다). */
export function normalizeTotpCode(input) {
  const digits = String(input ?? '').replace(/[\s-]/g, '');
  return /^\d{6}$/.test(digits) ? digits : null;
}

/**
 * 코드 확인 — 지금 칸과 앞뒤 [TOTP_WINDOW]칸까지 맞춰 본다. [lastStep]보다 앞이거나 같은 칸의 코드는 이미 쓴 것이라 받지 않는다
 * (같은 코드를 엿보고 다시 쓰는 것 막기). `{ ok: true, step }`(다음에 lastStep으로 적을 칸) | `{ ok: false }`.
 */
export function verifyTotp(secretB32, input, { nowMs = Date.now(), lastStep = null } = {}) {
  const code = normalizeTotpCode(input);
  const key = base32Decode(secretB32);
  if (!code || !key || key.length === 0) return { ok: false };
  const now = totpStep(nowMs);
  for (let delta = -TOTP_WINDOW; delta <= TOTP_WINDOW; delta += 1) {
    const step = now + delta;
    if (lastStep !== null && step <= lastStep) continue;
    const expected = hotp(key, step);
    if (crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(code))) return { ok: true, step };
  }
  return { ok: false };
}

/** 인증 앱이 QR로 읽는 주소(otpauth://totp/…) — [account]는 앱에 보일 계정 이름(아이디). */
export function otpauthUri({ secret, account, issuer = TOTP_ISSUER }) {
  const label = encodeURIComponent(`${issuer}:${account}`);
  const params = new URLSearchParams({
    secret,
    issuer,
    algorithm: 'SHA1',
    digits: String(TOTP_DIGITS),
    period: String(TOTP_PERIOD_SECONDS),
  });
  return `otpauth://totp/${label}?${params.toString()}`;
}

/** 복구 코드 [count]개 — 'abcde-fghjk'(헷갈리는 글자 뺀 소문자·숫자 10자). 휴대폰을 잃었을 때 한 번씩 쓴다. */
export function generateRecoveryCodes(count = RECOVERY_CODE_COUNT, randomInt = crypto.randomInt) {
  const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
  const codes = [];
  for (let i = 0; i < count; i += 1) {
    let s = '';
    for (let j = 0; j < 10; j += 1) s += alphabet[randomInt(alphabet.length)];
    codes.push(`${s.slice(0, 5)}-${s.slice(5)}`);
  }
  return codes;
}

/** 복구 코드 비교용 글자 — 소문자로, 영문·숫자만. 10자가 아니면 null. */
export function normalizeRecoveryCode(input) {
  const s = String(input ?? '')
    .toLowerCase()
    .replace(/[^a-z0-9]/g, '');
  return s.length === 10 ? s : null;
}

/**
 * 복구 코드 쓰기 — [hashes](저장된 열쇠 해시들)에 [input]의 해시가 있으면 그것을 뺀 나머지를 돌려준다(한 번 쓰면 끝).
 * [hashOf]는 열쇠 해시 함수(crypto.js lookupHash — 서버 비밀 없이는 맞춰 볼 수 없다). `{ ok, remaining }`.
 */
export function useRecoveryCode(hashes, input, hashOf) {
  const code = normalizeRecoveryCode(input);
  const list = Array.isArray(hashes) ? hashes : [];
  if (!code) return { ok: false, remaining: list };
  const target = hashOf(`otp-recovery:${code}`);
  const idx = list.indexOf(target);
  if (idx < 0) return { ok: false, remaining: list };
  return { ok: true, remaining: [...list.slice(0, idx), ...list.slice(idx + 1)] };
}

/** 복구 코드들의 저장 값(열쇠 해시). */
export function hashRecoveryCodes(codes, hashOf) {
  return codes.map((c) => hashOf(`otp-recovery:${normalizeRecoveryCode(c)}`));
}
