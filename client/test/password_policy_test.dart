import 'package:client/services/password_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('8자 미만은 거부 — 서버 passwordPolicy.js와 같은 기준', () {
    expect(passwordPolicyError('abc1234'), '비밀번호는 8자 이상이어야 합니다.');
    expect(passwordPolicyError(''), '비밀번호는 8자 이상이어야 합니다.');
  });

  test('8~20자는 통과, 20자 초과는 거부', () {
    expect(passwordPolicyError('abcd1234'), isNull);
    expect(passwordPolicyError('a' * 20), isNull);
    expect(passwordPolicyError('a' * 21), '비밀번호는 20자 이하여야 합니다.');
  });

  test('입력칸 안내 문구에 길이가 들어 있다', () {
    expect(kPasswordHint, contains('8~20자'));
  });
}
