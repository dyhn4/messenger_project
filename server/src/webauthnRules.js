/**
 * 하드웨어 보안 키·패스키(WebAuthn)의 **순수 규칙** — 신뢰 당사자(RP — 웹 앱 주소의 도메인)와 출처, 키 이름 검사, 로그인 둘째 단계로
 * 쓸 수 있는 방법들. 등록·확인 계산은 webauthn.js가 @simplewebauthn/server로 한다. DB 없이 시험한다(test/webauthnRules.test.js).
 *
 * 왜 브라우저에서 하나: Windows·안드로이드·아이폰·웹 앱 모두에서 같은 방식으로 보안 키(USB·NFC)·패스키(Windows Hello·휴대폰)를 쓰려고
 * 앱이 웹 앱 주소(WEB_DOMAIN — 정식 인증서)의 작은 페이지를 브라우저로 연다(회사 계정 로그인과 같은 길). WebAuthn은 도메인 이름에
 * 묶여서, 키는 그 도메인으로만 서명한다 — 가짜 사이트에서는 쓸 수 없다(피싱에 강한 2단계 인증).
 */

export const PASSKEYS_PER_USER = 10;
export const PASSKEY_NAME_MAX = 40;
export const WEBAUTHN_TTL_MS = 5 * 60 * 1000;

/** 웹 앱 주소 → `{ rpID, origin }`(RP ID는 도메인, 출처는 https://도메인[:포트]) | null(웹 앱 주소 없음·https 아님). */
export function webauthnRp(webBase) {
  try {
    const u = new URL(String(webBase ?? ''));
    if (u.protocol !== 'https:' || !u.hostname || /^\d+\.\d+\.\d+\.\d+$/.test(u.hostname)) return null;
    return { rpID: u.hostname, origin: u.origin };
  } catch {
    return null;
  }
}

/** 키 이름 — 1~40자, 제어 문자 없이. 비우면 [fallback]. `{ name }` | `{ error }`. */
export function parsePasskeyName(value, fallback = '보안 키') {
  if (value === undefined || value === null || value === '') return { name: fallback };
  if (typeof value !== 'string') return { error: '키 이름이 올바르지 않습니다.' };
  const name = value.replace(/[\u0000-\u001f\u007f]/g, '').trim();
  if (!name) return { name: fallback };
  if ([...name].length > PASSKEY_NAME_MAX) return { error: `키 이름은 ${PASSKEY_NAME_MAX}자까지입니다.` };
  return { name };
}

/**
 * 등록할 때 키 이름을 정하지 않았으면 붙일 이름 — 동기화되는 패스키(여러 기기)면 "패스키", 아니면 연결 방법으로(USB·NFC 보안 키,
 * 이 기기 — Windows Hello·지문 등).
 */
export function defaultPasskeyName({ backedUp = false, transports = [] } = {}) {
  if (backedUp) return '패스키';
  const t = Array.isArray(transports) ? transports : [];
  if (t.includes('usb') || t.includes('nfc') || t.includes('ble')) return '보안 키';
  if (t.includes('internal')) return '이 기기(생체 인증)';
  if (t.includes('hybrid')) return '휴대폰 패스키';
  return '보안 키';
}

/** 로그인 둘째 단계로 쓸 수 있는 방법들 — 인증 앱(TOTP)과 보안 키·패스키. */
export function secondFactorMethods(user, passkeyCount) {
  const out = [];
  if (user?.totpEnabledAt && user?.totpSecretEnc) out.push('totp');
  if (passkeyCount > 0) out.push('webauthn');
  return out;
}

/** base64url ↔ 바이트 — 키 id·공개 키를 글로 저장한다. */
export const toB64url = (bytes) => Buffer.from(bytes).toString('base64url');
export const fromB64url = (text) => new Uint8Array(Buffer.from(String(text ?? ''), 'base64url'));
