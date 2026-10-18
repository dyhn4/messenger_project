/// 새 비밀번호 규칙 — 가입·비밀번호 재설정·비밀번호 변경 화면이 같이 쓴다. 서버
/// server/src/passwordPolicy.js와 숫자를 맞춘다(서버가 최종 판단하고, 여기선 보내기 전에 미리
/// 알려주는 용도). 이미 쓰고 있는 짧은 비밀번호로 로그인하는 건 그대로 된다.
library;

import '../l10n/tr.dart';

const kPasswordMinLength = 8;
const kPasswordMaxLength = 20;

/// 새 비밀번호 입력칸의 안내 문구.
final kPasswordHint =
    tr('문자, 숫자 {kPasswordMinLength}~{kPasswordMaxLength}자 (특수문자 가능)', {
      'kPasswordMinLength': kPasswordMinLength,
      'kPasswordMaxLength': kPasswordMaxLength,
    });

/// 규칙에 맞지 않으면 보여줄 문구, 맞으면 null.
String? passwordPolicyError(String password) {
  if (password.length < kPasswordMinLength) {
    return tr('비밀번호는 {kPasswordMinLength}자 이상이어야 합니다.', {
      'kPasswordMinLength': kPasswordMinLength,
    });
  }
  if (password.length > kPasswordMaxLength) {
    return tr('비밀번호는 {kPasswordMaxLength}자 이하여야 합니다.', {
      'kPasswordMaxLength': kPasswordMaxLength,
    });
  }
  return null;
}
