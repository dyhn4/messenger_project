import 'package:client/services/invite_share.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const lan = 'http://192.168.0.10:3001/invite/abc';
  const ext = 'http://xxx.iptime.org:3001/invite/abc';

  test('외부 주소가 없으면 예전처럼 주소 하나만', () {
    expect(inviteShareText(lan, null), lan);
  });

  test('외부 주소가 있으면 사내용·밖에서 열 주소 + 공용 와이파이 주의', () {
    expect(
      inviteShareText(lan, ext),
      '사내 와이파이에서: $lan\n사내 와이파이 밖(LTE/5G)에서: $ext\n$kPublicWifiCaution',
    );
  });

  test('링크를 외부 주소로 만들었으면(같은 주소) 주소 하나 + 주의', () {
    expect(inviteShareText(ext, ext), '$ext\n$kPublicWifiCaution');
  });
}
