import 'dart:convert';

import 'package:client/models/web_certificate_status.dart';
import 'package:client/services/api_client.dart';
import 'package:client/widgets/web_certificate_status_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 관리자 콘솔 "웹 앱 주소(정식 인증서)" 카드 — GET /api/admin/web-certificate 응답을 운영자가 읽을 쉬운 말로
/// 바꾸고(꺼짐이면 켜는 방법, 정상이면 도메인·만료일·자동 갱신, 실패면 오류와 다음 시도), 이 기능이 없는 예전
/// 서버(404)면 카드를 숨긴다.
void main() {
  final expires = DateTime(2026, 12, 30, 14, 5);
  final lastAttempt = DateTime(2026, 10, 7, 9, 0);
  final nextAttempt = DateTime(2026, 10, 7, 21, 30);

  Map<String, dynamic> json({
    bool enabled = true,
    String? domain = 'xxx.iptime.org',
    String status = 'valid',
    bool staging = false,
    DateTime? expiresAt,
    DateTime? lastAttemptAt,
    String? lastError,
    DateTime? nextAttemptAt,
    Object? challenges = const {'http01': true, 'tlsAlpn01': false},
    String? webUrl,
  }) => {
    'enabled': enabled,
    'domain': domain,
    'status': status,
    'staging': staging,
    'expiresAt': expiresAt?.millisecondsSinceEpoch,
    'lastAttemptAt': lastAttemptAt?.millisecondsSinceEpoch,
    'lastError': lastError,
    'nextAttemptAt': nextAttemptAt?.millisecondsSinceEpoch,
    'challenges': challenges,
    'webUrl': webUrl,
  };
  WebCertificateStatus parse(Map<String, dynamic> j) =>
      WebCertificateStatus.fromJson(j);

  group('WebCertificateStatus.fromJson', () {
    test('모든 칸을 읽는다(시각은 epoch ms)', () {
      final s = parse(
        json(
          status: 'error',
          staging: true,
          expiresAt: expires,
          lastAttemptAt: lastAttempt,
          lastError: '연결 시간 초과',
          nextAttemptAt: nextAttempt,
          webUrl: 'https://xxx.iptime.org',
        ),
      );
      expect(s.enabled, isTrue);
      expect(s.domain, 'xxx.iptime.org');
      expect(s.status, WebCertificateState.error);
      expect(s.staging, isTrue);
      expect(s.expiresAt, expires);
      expect(s.lastAttemptAt, lastAttempt);
      expect(s.lastError, '연결 시간 초과');
      expect(s.nextAttemptAt, nextAttempt);
      expect(s.http01, isTrue);
      expect(s.tlsAlpn01, isFalse);
      expect(s.webUrl, 'https://xxx.iptime.org');
      expect(s.isOff, isFalse);
    });

    test('webUrl은 https 주소만 받는다', () {
      expect(
        parse(json(webUrl: 'https://xxx.iptime.org:8443')).webUrl,
        'https://xxx.iptime.org:8443',
      );
      for (final bad in [
        'http://xxx.iptime.org',
        'javascript:alert(1)',
        'https://',
        '  ',
      ]) {
        expect(parse(json(webUrl: bad)).webUrl, isNull, reason: bad);
      }
      expect(parse(json()).webUrl, isNull);
    });

    test('모르는 상태·빠진 칸은 안전한 기본값', () {
      final s = parse({'enabled': true, 'status': 'renewing'});
      expect(s.status, WebCertificateState.unknown);
      expect(s.domain, isNull);
      expect(s.staging, isFalse);
      expect(s.expiresAt, isNull);
      expect(s.http01, isNull);
      expect(s.tlsAlpn01, isNull);
      final odd = parse(json(challenges: {'http01': 'yes'}, domain: '  '));
      expect(odd.http01, isNull);
      expect(odd.domain, isNull);
      expect(parse(json(challenges: null)).tlsAlpn01, isNull);
    });

    test('도메인을 안 정했거나 서버가 off라고 하면 꺼짐', () {
      expect(parse(json(enabled: false, status: 'valid')).isOff, isTrue);
      expect(parse(json(status: 'off')).isOff, isTrue);
      expect(parse({}).isOff, isTrue);
    });

    test('발급 한도(rateLimited) 오류를 알아본다', () {
      for (final error in [
        'urn:ietf:params:acme:error:rateLimited: too many certificates (50) already issued for "iptime.org"',
        'Rate limit exceeded',
        'Let\'s Encrypt 발급 한도에 걸렸습니다',
      ]) {
        expect(
          parse(json(status: 'error', lastError: error)).rateLimited,
          isTrue,
          reason: error,
        );
      }
      expect(
        parse(
          json(status: 'error', lastError: 'Connection refused'),
        ).rateLimited,
        isFalse,
      );
      expect(parse(json(status: 'error')).rateLimited, isFalse);
    });
  });

  group('카드 문구', () {
    test('꺼짐 — 켜는 방법(시작 메뉴 "웹 앱 주소(정식 인증서)")', () {
      final s = parse(json(enabled: false, status: 'off', domain: null));
      expect(webCertificateLabel(s), '꺼짐');
      final text = webCertificateLines(s).join('\n');
      expect(text, contains('아이폰은 앱 대신 웹 앱(Safari)을 씁니다'));
      expect(text, contains('"웹 앱 주소(정식 인증서)"'));
      expect(text, contains('xxx.iptime.org'));
      expect(text, contains('자동으로 갱신'));
      expect(text, contains('80번이나 443번 포트를 이 서버 PC로 넘겨야 합니다'));
      expect(text, contains('PC·안드로이드 앱의 연결 방식은 바뀌지 않습니다'));
    });

    test('정상 — 도메인·만료일·자동 갱신, 아이폰에 알려 줄 주소, 초대 링크에 안내가 붙는다는 것', () {
      final s = parse(
        json(expiresAt: expires, webUrl: 'https://xxx.iptime.org'),
      );
      expect(webCertificateLabel(s), '사용 중');
      final lines = webCertificateLines(s);
      expect(
        lines.first,
        'xxx.iptime.org · 2026/12/30 14:05까지 유효 · 만료 전에 자동 갱신합니다.',
      );
      expect(lines, contains('아이폰 사용자에게 알려 줄 주소: https://xxx.iptime.org'));
      // 주소 바로 다음 줄 — 웹 앱은 초대 코드를 못 보내서 밖에서는 가입이 안 된다는 것(밖에서 가입된다고 안내하지 않게).
      expect(
        lines[lines.indexOf('아이폰 사용자에게 알려 줄 주소: https://xxx.iptime.org') + 1],
        '※ 웹 앱은 초대 코드를 쓸 수 없어서 아이폰 사용자의 첫 가입은 사내 와이파이에서 해야 합니다(가입한 뒤의 로그인은 어디서든 됩니다).',
      );
      expect(lines.join('\n'), contains('초대 링크를 복사하면 아이폰용 웹 앱 주소 안내가 함께 붙습니다'));
      expect(
        lines.last,
        '※ 인증서 확인 방식: HTTP-01(외부 80번 포트) 준비됨 · TLS-ALPN-01(외부 443번 포트) 준비 안 됨',
      );
      // 서버가 주소를 안 주면(예전 서버) 주소 줄과 그 가입 주의만 빠진다.
      final noUrl = webCertificateLines(
        parse(json(expiresAt: expires)),
      ).join('\n');
      expect(noUrl, isNot(contains('아이폰 사용자에게 알려 줄 주소')));
      expect(noUrl, isNot(contains('첫 가입은 사내 와이파이에서')));
      // 정상일 때는 시도 시각을 늘어놓지 않는다.
      final withTimes = webCertificateLines(
        parse(
          json(
            expiresAt: expires,
            lastAttemptAt: lastAttempt,
            nextAttemptAt: nextAttempt,
          ),
        ),
      ).join('\n');
      expect(withTimes, isNot(contains('다음 시도')));
    });

    test('발급 실패 — 오류 문구와 다음 시도 시각, 포트 확인 안내', () {
      final s = parse(
        json(
          status: 'error',
          lastError: '80·443 포트로 확인 요청이 들어오지 않았습니다.',
          lastAttemptAt: lastAttempt,
          nextAttemptAt: nextAttempt,
        ),
      );
      expect(webCertificateLabel(s), '발급 실패');
      final text = webCertificateLines(s).join('\n');
      expect(
        text,
        contains('xxx.iptime.org 인증서를 받지 못했습니다: 80·443 포트로 확인 요청이 들어오지 않았습니다.'),
      );
      expect(text, contains('마지막 시도: 2026/10/07 09:00'));
      expect(text, contains('다음 시도: 2026/10/07 21:30 (자동)'));
      expect(text, contains('포트포워딩에서 80번·443번 포트를 이 서버 PC로 넘겼는지'));
      expect(text, isNot(contains('발급 한도')));
    });

    test('발급 실패(한도) — iptime.org 공용 한도 설명, 지금 인증서가 아직 유효하면 그것도', () {
      final s = parse(
        json(
          status: 'error',
          lastError:
              'urn:ietf:params:acme:error:rateLimited: too many certificates already issued',
          expiresAt: expires,
          nextAttemptAt: nextAttempt,
        ),
      );
      final text = webCertificateLines(
        s,
        now: DateTime(2026, 10, 7),
      ).join('\n');
      expect(text, contains('발급 한도(7일에 새 인증서 50개)'));
      expect(text, contains('지금 걸려 있는 인증서는 2026/12/30 14:05까지 쓸 수 있습니다.'));
      expect(text, isNot(contains('포트포워딩')));
      // 이미 지난 인증서는 "쓸 수 있다"고 하지 않는다.
      final expired = webCertificateLines(
        s,
        now: DateTime(2027, 1, 1),
      ).join('\n');
      expect(expired, isNot(contains('쓸 수 있습니다')));
    });

    test('곧 만료 — 만료일과 자동 갱신 중, 갱신이 실패했으면 그 오류', () {
      final s = parse(
        json(
          status: 'expiring',
          expiresAt: expires,
          lastError: 'Timeout during connect',
          nextAttemptAt: nextAttempt,
        ),
      );
      expect(webCertificateLabel(s), '곧 만료');
      final text = webCertificateLines(s).join('\n');
      expect(
        text,
        contains(
          'xxx.iptime.org · 2026/12/30 14:05에 만료됩니다. 서버가 자동 갱신을 시도하고 있습니다.',
        ),
      );
      expect(text, contains('마지막 갱신 실패: Timeout during connect'));
      expect(text, contains('다음 시도: 2026/10/07 21:30 (자동)'));
    });

    test('발급 중 — 받는 중, 지난 시도의 오류가 있으면 함께', () {
      final s = parse(json(status: 'pending', lastError: 'Connection refused'));
      expect(webCertificateLabel(s), '발급 중');
      final text = webCertificateLines(s).join('\n');
      expect(text, contains('xxx.iptime.org 인증서를 받는 중입니다.'));
      expect(text, contains('마지막 오류: Connection refused'));
    });

    test('시험용 인증서 — 브라우저가 믿지 않는다는 안내, "사용 중"이라고만 하지 않고 주소도 안내하지 않는다', () {
      final s = parse(
        json(
          staging: true,
          expiresAt: expires,
          webUrl: 'https://xxx.iptime.org',
        ),
      );
      expect(webCertificateLabel(s), '시험용 인증서 사용 중');
      final text = webCertificateLines(s).join('\n');
      expect(text, contains('시험용 인증서(Let\'s Encrypt 스테이징)'));
      expect(text, contains('브라우저가 믿지 않습니다'));
      expect(text, contains('시험용 설정(ACME_STAGING)을 끄고 서버를 다시 시작한 뒤'));
      expect(text, isNot(contains('초대 링크를 복사하면')));
      expect(text, isNot(contains('아이폰 사용자에게 알려 줄 주소')));
      expect(text, isNot(contains('첫 가입은 사내 와이파이에서')));
    });

    test('웹 포트가 안 열려(다른 프로그램이 443을 씀) 실패 — 서버 문구와 포트 확인 안내', () {
      final s = parse(
        json(
          status: 'error',
          lastError: '웹 앱 전용 포트 443을 열 수 없습니다 — 다른 프로그램(IIS 등)이 쓰고 있습니다.',
          challenges: {'http01': true, 'tlsAlpn01': false},
        ),
      );
      final lines = webCertificateLines(s);
      expect(
        lines.first,
        'xxx.iptime.org 인증서를 받지 못했습니다: 웹 앱 전용 포트 443을 열 수 없습니다 — 다른 프로그램(IIS 등)이 쓰고 있습니다.',
      );
      expect(
        lines.join('\n'),
        contains('다른 프로그램(IIS 등)이 그 포트를 쓰고 있지 않은지 확인하세요'),
      );
      expect(lines.last, contains('TLS-ALPN-01(외부 443번 포트) 준비 안 됨'));
    });
  });

  group('WebCertificateStatusCard', () {
    Future<void> pump(
      WidgetTester tester,
      Future<WebCertificateStatus?> Function() load,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('위'),
                  WebCertificateStatusCard(load: load),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('정상 상태를 제목·상태·본문으로 보여 준다', (tester) async {
      await pump(tester, () async => parse(json(expiresAt: expires)));
      expect(find.textContaining('웹 앱 주소(정식 인증서)'), findsOneWidget);
      expect(find.textContaining('사용 중'), findsOneWidget);
      expect(
        find.text('xxx.iptime.org · 2026/12/30 14:05까지 유효 · 만료 전에 자동 갱신합니다.'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.verified_user), findsOneWidget);
    });

    testWidgets('예전 서버(404 → null)면 카드를 그리지 않는다', (tester) async {
      await pump(tester, () async => null);
      expect(find.text('위'), findsOneWidget);
      expect(find.textContaining('웹 앱 주소(정식 인증서)'), findsNothing);
      expect(find.byTooltip('다시 확인'), findsNothing);
    });

    testWidgets('불러오지 못하면 그 이유를 보이고, "다시 확인"으로 다시 불러온다', (tester) async {
      var calls = 0;
      await pump(tester, () async {
        calls++;
        if (calls == 1) throw const ApiException('서버 운영자만 볼 수 있습니다.');
        return parse(json(enabled: false, status: 'off', domain: null));
      });
      expect(
        find.textContaining('상태를 불러오지 못했습니다: 서버 운영자만 볼 수 있습니다.'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('다시 확인'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.textContaining('꺼짐'), findsOneWidget);
      expect(find.textContaining('"웹 앱 주소(정식 인증서)"'), findsOneWidget);
    });
  });

  group('ApiClient.fetchWebCertificateStatus', () {
    ApiClient client(http.Response response) => ApiClient(
      baseUrl: 'https://192.168.0.10:3000',
      token: 't',
      httpClient: MockClient((request) async {
        expect(request.url.path, '/api/admin/web-certificate');
        expect(request.headers['Authorization'], 'Bearer t');
        return response;
      }),
    );

    test('응답을 읽는다', () async {
      final s = await client(
        http.Response(
          jsonEncode(json(expiresAt: expires)),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ).fetchWebCertificateStatus();
      expect(s!.status, WebCertificateState.valid);
      expect(s.expiresAt, expires);
    });

    test('이 기능이 없는 예전 서버(Express 기본 404 HTML)면 null', () async {
      expect(
        await client(
          http.Response(
            '<!DOCTYPE html><pre>Cannot GET /api/admin/web-certificate</pre>',
            404,
            headers: {'content-type': 'text/html'},
          ),
        ).fetchWebCertificateStatus(),
        isNull,
      );
    });

    test('그 밖의 실패는 서버 문구(없으면 기본 문구)로 ApiException', () async {
      await expectLater(
        client(
          http.Response(
            jsonEncode({'error': '서버 운영자만 쓸 수 있습니다.'}),
            403,
            headers: {'content-type': 'application/json'},
          ),
        ).fetchWebCertificateStatus(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            '서버 운영자만 쓸 수 있습니다.',
          ),
        ),
      );
      await expectLater(
        client(
          http.Response('<html>Bad Gateway</html>', 502),
        ).fetchWebCertificateStatus(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            '웹 인증서 상태를 가져오지 못했습니다(502).',
          ),
        ),
      );
    });
  });
}
