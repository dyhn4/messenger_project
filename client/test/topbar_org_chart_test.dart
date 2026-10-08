import 'dart:convert';

import 'package:client/models/team.dart';
import 'package:client/screens/desktop_home_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// PC 앱 팀 화면 상단 바의 "조직도" 버튼 — 알림 종 왼쪽(구분선 너머)에 있고, 조직도를 볼 수 있는 등급(계정 관리자·서버 운영자 —
/// Session.canViewOrgChart)에게만 보인다.
class _Quiet extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

const _serverUrl = 'https://192.168.0.10:3000';

Session _session({
  AccountRole role = AccountRole.member,
  bool serverAdmin = false,
}) {
  final client = MockClient(
    (request) async => http.Response.bytes(
      utf8.encode(jsonEncode(<Object>[])),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    ),
  );
  final session = Session(notifications: _Quiet(), settings: AppSettings());
  session.serverUrl = _serverUrl;
  session.api = ApiClient(baseUrl: _serverUrl, token: 't', httpClient: client);
  session.userId = 'me';
  session.name = '김하나';
  session.accountRole = role;
  session.isServerAdmin = serverAdmin;
  final team = Team(id: 't1', name: '팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  return session;
}

Future<void> _pump(WidgetTester tester, Session session) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(home: DesktopHomeScreen(session: session)),
  );
  await tester.pumpAndSettle();
}

final _orgChart = find.byKey(const ValueKey('topbar-org-chart'));

void main() {
  for (final (name, role, serverAdmin) in [
    ('계정 관리자', AccountRole.admin, false),
    ('서버 운영자', AccountRole.member, true),
  ]) {
    testWidgets('$name에게는 알림 종 왼쪽에 조직도 아이콘 버튼과 구분선이 보이고, 누르면 조직도가 열린다', (
      tester,
    ) async {
      await _pump(tester, _session(role: role, serverAdmin: serverAdmin));
      expect(_orgChart, findsOneWidget);
      // 이름은 글자로 보이지 않고 툴팁으로만 알려 준다.
      expect(find.text('조직도'), findsNothing);
      expect(find.byTooltip('조직도'), findsOneWidget);
      final bell = find.byTooltip('알림 센터');
      expect(
        tester.getCenter(_orgChart).dx,
        lessThan(tester.getCenter(bell.first).dx),
      );
      expect(find.byType(VerticalDivider), findsWidgets);
      await tester.tap(_orgChart);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final role in [AccountRole.member, AccountRole.guest]) {
    testWidgets('${role.name}에게는 "조직도" 버튼이 없다', (tester) async {
      await _pump(tester, _session(role: role));
      expect(_orgChart, findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
