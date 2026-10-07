import 'dart:convert';
import 'dart:io';

import 'package:client/services/pinned_tls.dart';
import 'package:flutter_test/flutter_test.dart';

/// 처음 페어링할 때 인증서를 어디서 받나(pinned_tls.dart) — 서버 주소가 도메인 이름이면 그 이름의 443 포트(서버의
/// 웹 앱 전용 HTTPS 포트, 공인 인증서)에서 **보통의 인증서 검증**으로 먼저 받는다. 연결·TLS 문제로 못 받으면 지금까지의
/// 경로(메인 포트 → 평문 페어링 포트)로 넘어가고, 서버가 코드를 거절하면 그 문구를 그대로 보여 준다. IP 주소는 지금까지와
/// 똑같다.
void main() {
  group('publicTlsPairingUri — 도메인 이름일 때만 443 포트로 물어본다', () {
    test('도메인 이름이면 그 이름의 443 포트, 같은 /pair/<코드>', () {
      final uri = PinnedTls.publicTlsPairingUri(
        Uri.parse('https://xxx.iptime.org:3000'),
        '1234',
      );
      expect(uri.toString(), 'https://xxx.iptime.org/pair/1234');
      expect(uri!.port, 443);
      // 초대 링크 토큰도 같은 경로로 묻는다(서버 createPairHandler가 둘 다 받는다).
      expect(
        PinnedTls.publicTlsPairingUri(
          Uri.parse('https://chat.example.co.kr'),
          'eb29ac8867e36f94b62d18d7',
        ).toString(),
        'https://chat.example.co.kr/pair/eb29ac8867e36f94b62d18d7',
      );
    });

    test('IP 주소·점 없는 이름에는 공인 인증서가 없으니 묻지 않는다', () {
      for (final address in [
        'https://192.168.0.62:3000',
        'https://203.0.113.7:3000',
        'https://[::1]:3000',
        'https://[fe80::1]:3000',
        'https://localhost:3000',
        'https://server-pc:3000',
      ]) {
        expect(
          PinnedTls.publicTlsPairingUri(Uri.parse(address), '1234'),
          isNull,
          reason: address,
        );
      }
    });

    test('코드에 경로 문자가 섞여도 /pair 아래 한 칸으로만 들어간다', () {
      final uri = PinnedTls.publicTlsPairingUri(
        Uri.parse('https://xxx.iptime.org:3000'),
        '../admin',
      );
      expect(uri!.pathSegments, ['pair', '../admin']);
      expect(uri.path, '/pair/..%2Fadmin');
    });
  });

  group('pairingCertificate — 어느 경로로 받나', () {
    const publicPem = 'PUBLIC-TLS-PEM';
    const mainPem = 'MAIN-PORT-PEM';
    late List<String> calls;

    Future<String> mainPort(Uri address, String code) async {
      calls.add('main $address $code');
      return mainPem;
    }

    setUp(() => calls = []);

    test('도메인 이름이고 443에서 받으면 그 인증서를 쓰고, 기존 경로는 거치지 않는다', () async {
      final pem = await PinnedTls.pairingCertificate(
        Uri.parse('https://xxx.iptime.org:3000'),
        '1234',
        overPublicTls: (uri) async {
          calls.add('public $uri');
          return publicPem;
        },
        overMainPort: mainPort,
      );
      expect(pem, publicPem);
      expect(calls, ['public https://xxx.iptime.org/pair/1234']);
    });

    test('443에서 못 받으면(포트 닫힘·예전 서버·공인 인증서 아님) 기존 경로 그대로', () async {
      final pem = await PinnedTls.pairingCertificate(
        Uri.parse('https://xxx.iptime.org:3000'),
        '1234',
        overPublicTls: (uri) async {
          calls.add('public $uri');
          return null;
        },
        overMainPort: mainPort,
      );
      expect(pem, mainPem);
      expect(calls, [
        'public https://xxx.iptime.org/pair/1234',
        'main https://xxx.iptime.org:3000 1234',
      ]);
    });

    test('서버가 코드를 거절하면 그 문구를 그대로 올리고, 기존 경로로 다시 묻지 않는다', () async {
      await expectLater(
        PinnedTls.pairingCertificate(
          Uri.parse('https://xxx.iptime.org:3000'),
          '9999',
          overPublicTls: (uri) async {
            calls.add('public $uri');
            throw '코드가 올바르지 않거나 만료되었습니다.';
          },
          overMainPort: mainPort,
        ),
        throwsA('코드가 올바르지 않거나 만료되었습니다.'),
      );
      // 다시 물어도 같은 답이고, 4자리 코드는 틀린 횟수만 늘어난다.
      expect(calls, ['public https://xxx.iptime.org/pair/9999']);
    });

    test('IP 주소면 443은 묻지 않고 기존 경로 그대로', () async {
      final pem = await PinnedTls.pairingCertificate(
        Uri.parse('https://192.168.0.62:3000'),
        '1234',
        overPublicTls: (uri) async {
          calls.add('public $uri');
          return publicPem;
        },
        overMainPort: mainPort,
      );
      expect(pem, mainPem);
      expect(calls, ['main https://192.168.0.62:3000 1234']);
    });

    test('기존 경로의 오류(틀린 코드 등)는 지금처럼 그대로 올라온다', () async {
      await expectLater(
        PinnedTls.pairingCertificate(
          Uri.parse('https://192.168.0.62:3000'),
          '0000',
          overPublicTls: (_) async => publicPem,
          overMainPort: (_, _) async => throw '코드가 올바르지 않거나 만료되었습니다.',
        ),
        throwsA('코드가 올바르지 않거나 만료되었습니다.'),
      );
    });
  });

  group('publicPairingResult — 443에서 받은 응답 읽기', () {
    const pem =
        '-----BEGIN CERTIFICATE-----\nTUFJTg==\n-----END CERTIFICATE-----\n';

    test('200 + 인증서면 그 PEM', () {
      expect(
        PinnedTls.publicPairingResult(200, jsonEncode({'cert': pem})),
        pem,
      );
    });

    test('서버 /pair가 코드를 거절하면(404 틀림·만료, 429 시도 과다 + error) 그 문구로 예외', () {
      expect(
        () => PinnedTls.publicPairingResult(
          404,
          jsonEncode({'error': '코드가 올바르지 않거나 만료되었습니다.'}),
        ),
        throwsA('코드가 올바르지 않거나 만료되었습니다.'),
      );
      expect(
        () => PinnedTls.publicPairingResult(
          429,
          jsonEncode({'error': '페어링 시도가 너무 많습니다. 15분 후 다시 시도하세요.'}),
        ),
        throwsA('페어링 시도가 너무 많습니다. 15분 후 다시 시도하세요.'),
      );
    });

    test('/pair가 쓰지 않는 다른 4xx는 "거절"로 읽지 않고 기존 경로로(null)', () {
      for (final status in [400, 401, 403, 405]) {
        expect(
          PinnedTls.publicPairingResult(
            status,
            jsonEncode({'error': '사내망 밖에서는 이 주소로 연결할 수 없습니다.'}),
          ),
          isNull,
          reason: '$status',
        );
      }
    });

    test('이 서버의 /pair가 아닌 답은 null(기존 경로로)', () {
      final cases = <(int, String)>[
        (
          404,
          '<!DOCTYPE html><pre>Cannot GET /pair/1234</pre>',
        ), // 예전 서버·다른 웹 서버
        (200, '<html>공유기 관리 페이지</html>'),
        (302, ''), // 리다이렉트는 따라가지 않는다
        (500, jsonEncode({'error': '서버 오류가 발생했습니다.'})), // 서버 오류는 기존 경로가 다시 판단
        (200, jsonEncode({'ok': true})), // 인증서가 없다
        (200, jsonEncode({'cert': 'not a pem'})),
        (200, jsonEncode(['cert'])),
        (404, jsonEncode({'message': 'Not Found'})),
        (404, jsonEncode({'error': ''})),
      ];
      for (final (status, body) in cases) {
        expect(
          PinnedTls.publicPairingResult(status, body),
          isNull,
          reason: '$status $body',
        );
      }
    });
  });

  group('pairOverPublicTls — 루프백 HTTPS 서버(자체 서명 인증서)', () {
    // 메인 포트의 자체 서명 인증서라 치고 본문에 실어 보내는 PEM — TLS 연결 자체의 인증서와는 다르다.
    const mainPortPem =
        '-----BEGIN CERTIFICATE-----\nTUFJTi1QT1JU\n-----END CERTIFICATE-----\n';
    late HttpServer server;
    late HttpOverrides? previousGlobal;

    Uri at(String path) => Uri.parse('https://localhost:${server.port}$path');

    /// 시험용 HTTPS 서버의 인증서만 믿는 목록 — 실제로는 운영체제의 공인 인증 기관 목록이 그 자리에 들어간다.
    SecurityContext trustFixture() =>
        SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificatesBytes(utf8.encode(_fixtureCert));

    setUp(() async {
      previousGlobal = HttpOverrides.current;
      final context = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(_fixtureCert))
        ..usePrivateKeyBytes(utf8.encode(_fixtureKey));
      server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      server.listen((request) async {
        final response = request.response
          ..headers.contentType = ContentType.json;
        switch (request.uri.path) {
          case '/pair/1234':
            response.write(jsonEncode({'cert': mainPortPem}));
          case '/moved':
            response
              ..statusCode = HttpStatus.found
              ..headers.set('location', '/pair/1234');
          default:
            response
              ..statusCode = HttpStatus.notFound
              ..write(jsonEncode({'error': '코드가 올바르지 않거나 만료되었습니다.'}));
        }
        await response.close();
      });
    });

    tearDown(() async {
      HttpOverrides.global = previousGlobal;
      await server.close(force: true);
    });

    test('앱 전체에 걸린 HttpOverrides(핀닝)를 비켜 가서, 공인 인증서가 아니면 받지 않는다', () async {
      // 앱 전체 설정이 이 자체 서명 인증서를 믿는 상태 — 그대로 만든 HttpClient로는 받아진다(전제 확인).
      HttpOverrides.global = _TrustEverything();
      final plain = HttpClient();
      try {
        final response = await (await plain.getUrl(at('/pair/1234'))).close();
        await response.drain<void>();
        expect(response.statusCode, 200);
      } finally {
        plain.close(force: true);
      }
      // 공인 인증서 검증으로 붙는 이 경로는 그 설정을 거치지 않으므로 TLS에서 걸러지고 null(기존 경로로).
      expect(await PinnedTls.pairOverPublicTls(at('/pair/1234')), isNull);
    });

    test('믿을 수 있는 연결이면 본문에 실린 (메인 포트의) 인증서를 돌려준다', () async {
      expect(
        await PinnedTls.pairOverPublicTls(
          at('/pair/1234'),
          trustedRoots: trustFixture(),
        ),
        mainPortPem,
      );
    });

    test('코드를 거절하면 서버 문구로 예외', () async {
      await expectLater(
        PinnedTls.pairOverPublicTls(
          at('/pair/0000'),
          trustedRoots: trustFixture(),
        ),
        throwsA('코드가 올바르지 않거나 만료되었습니다.'),
      );
    });

    test('리다이렉트는 따라가지 않는다 — null', () async {
      expect(
        await PinnedTls.pairOverPublicTls(
          at('/moved'),
          trustedRoots: trustFixture(),
        ),
        isNull,
      );
    });

    test('포트가 닫혀 있으면 null', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final closedPort = probe.port;
      await probe.close();
      expect(
        await PinnedTls.pairOverPublicTls(
          Uri.parse('https://localhost:$closedPort/pair/1234'),
          trustedRoots: trustFixture(),
        ),
        isNull,
      );
    });
  });
}

/// 앱의 핀닝 설정을 흉내 낸 것 — 이 설정 아래에서 만든 HttpClient는 시험용 자체 서명 인증서도 받아들인다.
class _TrustEverything extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..badCertificateCallback = (_, _, _) => true;
}

/// 시험용 자체 서명 인증서(localhost·127.0.0.1, 2126년까지) — 이 테스트의 루프백 HTTPS 서버에만 쓴다.
const _fixtureCert = '''-----BEGIN CERTIFICATE-----
MIIBvzCCAWWgAwIBAgIUczfZA0INgG697drELQ3oo/dWPX0wCgYIKoZIzj0EAwIw
FDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MTAwNzExMzA1OFoYDzIxMjYwOTEz
MTEzMDU4WjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjO
PQMBBwNCAARqNNsLMVy7bTBSPrtcM6SqH2JDwhw30ogM2nhX2h9rKcRT5ws1spmm
WywZThXAcdOOebH+dQaWrXE9DeH8ZLURo4GSMIGPMB0GA1UdDgQWBBTARp+lFoh2
fpq9WTd7yxC7DwRiKDAfBgNVHSMEGDAWgBTARp+lFoh2fpq9WTd7yxC7DwRiKDAa
BgNVHREEEzARgglsb2NhbGhvc3SHBH8AAAEwDAYDVR0TAQH/BAIwADAOBgNVHQ8B
Af8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwCgYIKoZIzj0EAwIDSAAwRQIh
APPXeEhuv6DZYwiq2FkHwKiSiydeB491ACqGG81UOmaVAiAOMHsKHtwFa1nJqhkK
gW5tYDnsUdbFjJtHKRTEGqtE/Q==
-----END CERTIFICATE-----
''';

const _fixtureKey = '''-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg5qgcL/h8ag9PCa0y
zpatmihOGCHlCg06pfQeYqJjzDChRANCAARqNNsLMVy7bTBSPrtcM6SqH2JDwhw3
0ogM2nhX2h9rKcRT5ws1spmmWywZThXAcdOOebH+dQaWrXE9DeH8ZLUR
-----END PRIVATE KEY-----
''';
