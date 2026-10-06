/**
 * 새 비밀번호 규칙 — 가입·비밀번호 재설정·비밀번호 변경이 같은 기준을 쓴다. 사내망 밖에서도
 * 로그인할 수 있게 되면서 최소 길이를 4자에서 8자로 올렸다(무차별 대입 방어는 authGuard.js).
 * 이미 쓰고 있는 짧은 비밀번호로도 로그인은 그대로 되고, 새로 정할 때만 이 규칙을 적용한다.
 * 클라이언트 password_policy.dart와 숫자를 같이 맞춘다.
 */
export const PASSWORD_MIN_LENGTH = 8;
// 가입 화면 입력칸 길이(20자)와 맞춘다. bcrypt는 72바이트까지만 보므로 그보다 짧게 둔다.
export const PASSWORD_MAX_LENGTH = 20;

/**
 * 길이만 맞으면 통과하던 흔한 비밀번호 — 여러 IP에서 아이디마다 몇 개씩 넣어보는 공격(비밀번호 스프레이)이 제일
 * 먼저 시도하는 것들이라 새로 정할 때 막는다(소문자로 비교). 키보드 배열·숫자 나열·자주 쓰는 단어 위주.
 */
const COMMON_PASSWORDS = new Set([
  'password', 'password1', 'password12', 'password123', 'password!', 'passw0rd', 'p@ssw0rd', 'p@ssword',
  'qwerty12', 'qwerty123', 'qwertyui', 'qwer1234', 'qwer1234!', 'asdf1234', 'asdfasdf', 'asdfghjk',
  'zxcvbnm1', '1q2w3e4r', '1q2w3e4r!', '1q2w3e4r5t', 'q1w2e3r4', 'a1s2d3f4', '1qaz2wsx', 'qazwsxed',
  'abcd1234', 'abcd1234!', 'abc12345', 'abcdefgh', 'aa123456', 'a1234567', 'a12345678', 'admin123',
  'admin1234', 'administrator', 'welcome1', 'welcome123', 'iloveyou', 'iloveyou1', 'sunshine', 'princess',
  'football', 'baseball', 'dragon12', 'monkey12', 'letmein1', 'trustno1', 'master12', 'superman',
  'samsung1', 'samsung123', 'korea123', 'seoul123', 'love1234', 'test1234', 'test1234!', 'temp1234',
  'guest123', 'user1234', 'tangotalk', 'tangotalk1', 'messenger', 'company1', 'changeme',
]);

/**
 * 규칙에 맞지 않으면 사용자에게 보여줄 문구, 맞으면 null. [username]을 주면 아이디가 그대로 들어간 비밀번호도
 * 막는다(아이디는 남에게 보이는 값이라 맞히기 쉽다).
 */
export function passwordPolicyError(password, { username } = {}) {
  if (typeof password !== 'string' || password.length < PASSWORD_MIN_LENGTH) {
    return `비밀번호는 ${PASSWORD_MIN_LENGTH}자 이상이어야 합니다.`;
  }
  if (password.length > PASSWORD_MAX_LENGTH) {
    return `비밀번호는 ${PASSWORD_MAX_LENGTH}자 이하여야 합니다.`;
  }
  const lower = password.toLowerCase();
  if (COMMON_PASSWORDS.has(lower) || isTrivialPattern(lower)) {
    return '너무 흔하거나 단순한 비밀번호입니다. 다른 비밀번호를 쓰세요.';
  }
  const name = typeof username === 'string' ? username.trim().toLowerCase() : '';
  if (name.length >= 4 && lower.includes(name)) {
    return '아이디가 들어간 비밀번호는 쓸 수 없습니다.';
  }
  return null;
}

/** 한 글자 반복(aaaaaaaa), 연속 숫자·글자(12345678, 87654321, abcdefgh) 같은 나열. */
function isTrivialPattern(s) {
  if (new Set(s).size <= 2) return true;
  let up = true;
  let down = true;
  for (let i = 1; i < s.length; i++) {
    const d = s.charCodeAt(i) - s.charCodeAt(i - 1);
    if (d !== 1) up = false;
    if (d !== -1) down = false;
  }
  return up || down;
}
