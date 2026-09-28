import 'dart:convert';

import 'package:client/models/team.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/account_menu_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 삼선 메뉴의 "도움말"(초보자용, 모든 회원)과 "메신저 설명서"(관리자 이상) 표시/동작.
void main() {
  const serverUrl = 'https://192.168.0.10:3000';
  const json = {'content-type': 'application/json'};

  late List<Uri> opened;
  late List<http.Request> requests;
  var manualStatus = 200;

  setUp(() {
    opened = [];
    requests = [];
    manualStatus = 200;
    AccountMenuButton.openExternal = (uri) async {
      opened.add(uri);
      return true;
    };
    AccountMenuButton.probePlainGuide = (_) async => false;
  });

  Session buildSession({
    AccountRole role = AccountRole.member,
    bool serverAdmin = false,
  }) {
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'POST' &&
          request.url.path == '/api/help/manual-link') {
        if (manualStatus != 200) {
          return http.Response(
            jsonEncode({'error': '메신저 설명서는 관리자만 볼 수 있습니다.'}),
            manualStatus,
            headers: json,
          );
        }
        return http.Response(
          jsonEncode({'url': '/help?t=signed-token', 'expiresInSeconds': 300}),
          200,
          headers: json,
        );
      }
      return http.Response('[]', 200, headers: json);
    });
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    session.serverUrl = serverUrl;
    session.api = ApiClient(baseUrl: serverUrl, token: 't', httpClient: client);
    session.userId = 'u1';
    session.name = '김하나';
    session.accountRole = role;
    session.isServerAdmin = serverAdmin;
    session.currentTeam = Team(id: 't1', name: '팀', createdAt: DateTime.now());
    return session;
  }

  Future<void> openMenu(WidgetTester tester, Session session) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: [AccountMenuButton(session: session)]),
        ),
      ),
    );
    await tester.tap(find.byTooltip('설정'));
    await tester.pumpAndSettle();
  }

  final cases = <String, (AccountRole, bool, bool)>{
    '준회원': (AccountRole.guest, false, false),
    '정회원': (AccountRole.member, false, false),
    '계정 관리자': (AccountRole.admin, false, true),
    '서버 운영자': (AccountRole.member, true, true),
  };
  for (final entry in cases.entries) {
    final (role, serverAdmin, seesManual) = entry.value;
    testWidgets('${entry.key}: 도움말은 보이고 메신저 설명서는 '
        '${seesManual ? '보인다' : '안 보인다'}', (tester) async {
      await openMenu(
        tester,
        buildSession(role: role, serverAdmin: serverAdmin),
      );
      expect(find.text('도움말'), findsOneWidget);
      expect(find.text('메신저 설명서'), seesManual ? findsOneWidget : findsNothing);
      // 도움말은 예전 자리(오픈소스 라이선스 바로 위), 메신저 설명서는 그 바로 아래.
      final help = tester.getRect(find.text('도움말'));
      final license = tester.getRect(find.text('오픈소스 라이선스'));
      expect(help.top, lessThan(license.top));
      if (seesManual) {
        final manual = tester.getRect(find.text('메신저 설명서'));
        expect(manual.top, greaterThan(help.top));
        expect(manual.top, lessThan(license.top));
      }
    });
  }

  testWidgets('도움말: 평문 페어링 서버가 응답하면 인증서 경고 없는 http 주소를 연다', (
    tester,
  ) async {
    final probed = <Uri>[];
    AccountMenuButton.probePlainGuide = (uri) async {
      probed.add(uri);
      return true;
    };
    await openMenu(tester, buildSession(role: AccountRole.guest));
    await tester.tap(find.text('도움말'));
    await tester.pumpAndSettle();
    expect(probed.single.toString(), 'http://192.168.0.10:3001/guide/');
    expect(opened.single.toString(), 'http://192.168.0.10:3001/guide/');
  });

  testWidgets('도움말: 페어링 서버에 없으면 메인 서버의 /guide/를 연다', (tester) async {
    await openMenu(tester, buildSession());
    await tester.tap(find.text('도움말'));
    await tester.pumpAndSettle();
    expect(opened.single.toString(), '$serverUrl/guide/');
  });

  testWidgets('메신저 설명서: 서버가 준 서명 링크를 절대 주소로 연다', (tester) async {
    await openMenu(tester, buildSession(role: AccountRole.admin));
    await tester.tap(find.text('메신저 설명서'));
    await tester.pumpAndSettle();
    final post = requests.singleWhere(
      (r) => r.url.path == '/api/help/manual-link',
    );
    expect(post.method, 'POST');
    expect(post.headers['Authorization'], 'Bearer t');
    expect(opened.single.toString(), '$serverUrl/help?t=signed-token');
  });

  testWidgets('메신저 설명서: 서버가 거절하면 그 메시지를 토스트로 보여준다', (tester) async {
    manualStatus = 403;
    await openMenu(tester, buildSession(serverAdmin: true));
    await tester.tap(find.text('메신저 설명서'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('메신저 설명서는 관리자만 볼 수 있습니다.'), findsOneWidget);
    expect(opened, isEmpty);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  test('plainGuideUri: 메인 포트+1의 http 주소(포트 없으면 443+1)', () {
    expect(
      plainGuideUri('https://10.0.0.5:3000').toString(),
      'http://10.0.0.5:3001/guide/',
    );
    expect(
      plainGuideUri('https://chat.example.com').toString(),
      'http://chat.example.com:444/guide/',
    );
  });
}
