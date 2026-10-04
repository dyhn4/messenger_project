/**
 * 새 비밀번호 규칙 — 가입·비밀번호 재설정·비밀번호 변경이 같은 기준을 쓴다. 사내망 밖에서도
 * 로그인할 수 있게 되면서 최소 길이를 4자에서 8자로 올렸다(무차별 대입 방어는 authGuard.js).
 * 이미 쓰고 있는 짧은 비밀번호로도 로그인은 그대로 되고, 새로 정할 때만 이 규칙을 적용한다.
 * 클라이언트 password_policy.dart와 숫자를 같이 맞춘다.
 */
export const PASSWORD_MIN_LENGTH = 8;
// 가입 화면 입력칸 길이(20자)와 맞춘다. bcrypt는 72바이트까지만 보므로 그보다 짧게 둔다.
export const PASSWORD_MAX_LENGTH = 20;

/** 규칙에 맞지 않으면 사용자에게 보여줄 문구, 맞으면 null. */
export function passwordPolicyError(password) {
  if (typeof password !== 'string' || password.length < PASSWORD_MIN_LENGTH) {
    return `비밀번호는 ${PASSWORD_MIN_LENGTH}자 이상이어야 합니다.`;
  }
  if (password.length > PASSWORD_MAX_LENGTH) {
    return `비밀번호는 ${PASSWORD_MAX_LENGTH}자 이하여야 합니다.`;
  }
  return null;
}
