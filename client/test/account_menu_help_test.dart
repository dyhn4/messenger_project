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

/// 삼선 메뉴의 "도움말"(초보자용, 모든 회원) 표시/동작.
void main() {
  const serverUrl = 'https://192.168.0.10:3000';
  const json = {'content-type': 'application/json'};

  late List<Uri> opened;

  setUp(() {
    opened = [];
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
    final client = MockClient(
      (request) async => http.Response('[]', 200, headers: json),
    );
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

  final cases = <String, (AccountRole, bool)>{
    '준회원': (AccountRole.guest, false),
    '정회원': (AccountRole.member, false),
    '계정 관리자': (AccountRole.admin, false),
    '서버 운영자': (AccountRole.member, true),
  };
  for (final entry in cases.entries) {
    final (role, serverAdmin) = entry.value;
    testWidgets('${entry.key}: 도움말이 오픈소스 라이선스 바로 위에 보이고, 메신저 설명서는 없다', (
      tester,
    ) async {
      await openMenu(
        tester,
        buildSession(role: role, serverAdmin: serverAdmin),
      );
      expect(find.text('도움말'), findsOneWidget);
      expect(find.text('메신저 설명서'), findsNothing);
      final help = tester.getRect(find.text('도움말'));
      final license = tester.getRect(find.text('오픈소스 라이선스'));
      expect(help.top, lessThan(license.top));
    });
  }

  testWidgets('도움말: 평문 페어링 서버가 응답하면 인증서 경고 없는 http 주소를 연다', (tester) async {
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
