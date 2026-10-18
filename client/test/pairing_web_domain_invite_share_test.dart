import 'dart:convert';

import 'package:client/services/api_client.dart';
import 'package:client/services/invite_share.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 초대 링크 복사 글의 아이폰 안내 줄(invite_share.dart) — 서버가 GET /server-info로 웹 앱 주소(webUrl — 공인 인증서가
/// 실제로 걸려 있을 때만)를 알려 주면 맨 끝에 "아이폰은 앱 대신 웹 앱을 씁니다…"와 가입 안내를 붙인다 — 초대 코드를 넘기면
/// 웹 앱 주소에 `?invite=<코드>`를 붙여, 그 주소로 연 웹 앱이 사내 와이파이 밖에서도 가입한다(web_launch_invite.dart).
/// 예전 서버(webUrl 없음)는 지금과 똑같다.
void main() {
  const lan = 'http://192.168.0.10:3001/invite/abc';
  const ext = 'http://xxx.iptime.org:3001/invite/abc';
  const web = 'https://xxx.iptime.org';
  const iphone = '아이폰은 앱 대신 웹 앱을 씁니다: $web 을 Safari로 열어 가입하고 홈 화면에 추가하세요.';
  const token = 'a1b2c3d4e5f60718293a4b5c';
  final iphoneBlock = '$iphone\n$kIphoneSignupCaution';

  tearDown(() => rememberWebAppUrl(null));

  group('inviteShareText', () {
    test('웹 앱 주소를 모르면 지금과 똑같다', () {
      expect(knownWebAppUrl, isNull);
      expect(inviteShareText(lan, null), lan);
      expect(inviteShareText(ext, ext), '$ext\n$kPublicWifiCaution');
      expect(
        inviteShareText(lan, ext),
        '사내 와이파이에서: $lan\n사내 와이파이 밖(LTE/5G)에서: $ext\n$kPublicWifiCaution',
      );
      for (final text in [
        inviteShareText(lan, null),
        inviteShareText(lan, ext),
      ]) {
        expect(text, isNot(contains('아이폰')));
      }
    });

    test('웹 앱 주소를 넘기면 맨 끝(공용 와이파이 주의 뒤)에 아이폰 안내 줄과 가입 주의', () {
      expect(iphoneWebAppLine(web), iphone);
      expect(inviteShareText(lan, null, webUrl: web), '$lan\n$iphoneBlock');
      expect(
        inviteShareText(ext, ext, webUrl: web),
        '$ext\n$kPublicWifiCaution\n$iphoneBlock',
      );
      expect(
        inviteShareText(lan, ext, webUrl: web),
        '사내 와이파이에서: $lan\n사내 와이파이 밖(LTE/5G)에서: $ext\n$kPublicWifiCaution\n$iphoneBlock',
      );
    });

    test('초대 코드를 넘기면 웹 앱 주소에 붙인다 — 그 주소로 처음 열어야 밖(LTE/5G)에서도 가입된다', () {
      expect(
        iphoneWebAppLine(web, inviteToken: token),
        '아이폰은 앱 대신 웹 앱을 씁니다: $web/?invite=$token 을 Safari로 열어 가입하고 홈 화면에 추가하세요.',
      );
      expect(
        inviteShareText(lan, null, webUrl: web, inviteToken: token),
        '$lan\n${iphoneWebAppLine(web, inviteToken: token)}\n$kIphoneSignupCaution',
      );
      expect(webAppInviteUrl('$web/', token), '$web/?invite=$token');
      // 코드 모양이 아니면(빈 값·기호·너무 김) 붙이지 않는다.
      for (final bad in [
        '',
        'abc',
        'a b c d e f g',
        'x' * 200,
        '<script>x</script>',
      ]) {
        expect(webAppInviteUrl(web, bad), web, reason: bad);
      }
      expect(isPlausibleInviteToken(token), isTrue);
      expect(isPlausibleInviteToken('abc'), isFalse);
    });

    test('가입 안내 — 처음 가입할 때는 그 주소로, 가입한 뒤에는 홈 화면의 웹 앱으로 로그인', () {
      expect(kIphoneSignupCaution, contains('처음 가입할 때는 꼭 위 주소로 여세요'));
      expect(kIphoneSignupCaution, isNot(contains('사내 와이파이에서만')));
      // 아이폰 안내 줄 바로 다음 줄이다 — 다른 사람(PC·안드로이드)용 줄에 섞여 읽히지 않게.
      final lines = inviteShareText(lan, ext, webUrl: web).split('\n');
      expect(lines.indexOf(kIphoneSignupCaution), lines.indexOf(iphone) + 1);
      expect(lines.last, kIphoneSignupCaution);
    });

    test('주소와 "을" 사이를 띄운다 — 메신저가 주소를 링크로 바꿀 때 뒤 글자가 붙지 않게', () {
      expect(
        iphoneWebAppLine('https://a.example:8443'),
        contains('https://a.example:8443 을 Safari로'),
      );
    });

    test('넘기지 않으면 서버에서 받아 둔 주소를 쓴다(초대 링크 화면은 링크 주소만 넘긴다)', () {
      rememberWebAppUrl(web);
      expect(knownWebAppUrl, web);
      expect(inviteShareText(lan, null), '$lan\n$iphoneBlock');
      expect(
        inviteShareText(lan, null, webUrl: 'https://other.example'),
        '$lan\n${iphoneWebAppLine('https://other.example')}\n$kIphoneSignupCaution',
      );
      rememberWebAppUrl(null);
      expect(inviteShareText(lan, null), lan);
    });
  });

  group('ApiClient.fetchServerInfo — webUrl', () {
    ApiClient client(Future<http.Response> Function(http.Request) handler) =>
        ApiClient(
          baseUrl: 'https://192.168.0.10:3000',
          httpClient: MockClient(handler),
        );
    http.Response ok(Map<String, dynamic> body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

    test('webUrl을 받아 두고(끝 슬래시 정리) 반환 모양은 그대로', () async {
      final api = client(
        (_) async => ok({
          'externalUrl': 'https://xxx.iptime.org:3000',
          'internalUrls': ['https://192.168.0.10:3000'],
          'webUrl': 'https://xxx.iptime.org/',
        }),
      );
      // Session이 받아 쓰는 예전 반환 모양 그대로.
      final ({String? externalUrl, List<String> internalUrls}) info = await api
          .fetchServerInfo();
      expect(info.externalUrl, 'https://xxx.iptime.org:3000');
      expect(info.internalUrls, ['https://192.168.0.10:3000']);
      expect(knownWebAppUrl, web);
      expect(inviteShareText(lan, null), '$lan\n$iphoneBlock');

      final withWeb = await api.fetchServerInfoWithWebUrl();
      expect(withWeb.webUrl, web);
      expect(withWeb.externalUrl, 'https://xxx.iptime.org:3000');
    });

    test('예전 서버(webUrl 없음)·기능 꺼짐(null)·https가 아닌 값이면 null', () async {
      for (final body in <Map<String, dynamic>>[
        {'externalUrl': null, 'internalUrls': []},
        {'externalUrl': null, 'internalUrls': [], 'webUrl': null},
        {
          'externalUrl': null,
          'internalUrls': [],
          'webUrl': 'http://xxx.iptime.org',
        },
        {
          'externalUrl': null,
          'internalUrls': [],
          'webUrl': 'javascript:alert(1)',
        },
        {'externalUrl': null, 'internalUrls': [], 'webUrl': 'https://'},
        {'externalUrl': null, 'internalUrls': [], 'webUrl': 42},
      ]) {
        rememberWebAppUrl(web);
        final info = await client(
          (_) async => ok(body),
        ).fetchServerInfoWithWebUrl();
        expect(info.webUrl, isNull, reason: '$body');
        expect(knownWebAppUrl, isNull, reason: '$body');
      }
    });

    test('물어보지 못하면 예외는 그대로, 받아 둔 주소는 지운다(다른 서버의 주소를 안내하지 않게)', () async {
      rememberWebAppUrl(web);
      await expectLater(
        client((_) async => http.Response('nope', 502)).fetchServerInfo(),
        throwsA(isA<ApiException>()),
      );
      expect(knownWebAppUrl, isNull);

      rememberWebAppUrl(web);
      await expectLater(
        client(
          (_) async => throw http.ClientException('offline'),
        ).fetchServerInfo(),
        throwsA(isA<http.ClientException>()),
      );
      expect(knownWebAppUrl, isNull);
    });
  });
}
