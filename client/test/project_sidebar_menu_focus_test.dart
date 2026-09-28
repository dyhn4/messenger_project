import 'dart:convert';

import 'package:client/models/team.dart';
import 'package:client/screens/project/project_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 사이드바 프로젝트 줄의 ⋯ 메뉴를 쓴 뒤, 마우스를 치웠는데도 그 줄이 회색(포커스 표시)으로
/// 남던 문제. 메뉴를 닫을 때 포커스가 ⋯ 버튼으로 돌아오는데, 버튼이 ListTile 안에 있으면
/// 줄 전체가 "포커스됨"으로 칠해졌다.
void main() {
  const json = {'content-type': 'application/json'};
  final now = DateTime.now().millisecondsSinceEpoch;
  final project = {
    'id': 'p1',
    'teamId': 't1',
    'name': '잔디톡',
    'identifier': 'TA',
    'color': '#5B8DEF',
    'myRole': 'owner',
    'createdAt': now,
    'members': <Map<String, dynamic>>[],
  };

  Session buildSession() {
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/projects') {
        return http.Response(
          request.url.queryParameters['archived'] == '1'
              ? '[]'
              : jsonEncode([project]),
          200,
          headers: json,
        );
      }
      if (path == '/api/projects/home') {
        return http.Response(
          jsonEncode({
            'stats': {'total': 0, 'done': 0, 'doing': 0, 'overdue': 0},
            'projects': [project],
            'myTasks': [],
            'recentComments': [],
          }),
          200,
          headers: json,
        );
      }
      if (path == '/api/project-notifications') {
        return http.Response(
          jsonEncode({'unreadCount': 0, 'items': []}),
          200,
          headers: json,
        );
      }
      if (path == '/api/projects/p1') {
        return http.Response(jsonEncode(project), 200, headers: json);
      }
      if (path == '/api/projects/p1/favorite') {
        return http.Response('{}', 200, headers: json);
      }
      return http.Response('[]', 200, headers: json);
    });
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    session.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: client,
    );
    session.currentTeam = Team(id: 't1', name: '팀', createdAt: DateTime.now());
    return session;
  }

  for (final action in ['템플릿 저장', '즐겨찾기', '프로젝트 설정']) {
    testWidgets('사이드바 ⋯ > $action 뒤 마우스를 치우면 프로젝트 줄에 회색이 남지 않는다', (
      tester,
    ) async {
      // Windows 데스크톱처럼 포커스 표시가 늘 보이는 모드.
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: ProjectDialog(session: buildSession(), embedInWindow: true),
        ),
      );
      await tester.pumpAndSettle();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      Future<void> click(Finder f) async {
        await mouse.moveTo(tester.getCenter(f));
        await tester.pumpAndSettle();
        await mouse.down(tester.getCenter(f));
        await mouse.up();
        await tester.pumpAndSettle();
      }

      final row = find.text('잔디톡').first;
      await mouse.moveTo(tester.getCenter(row));
      await tester.pumpAndSettle();
      await click(find.byTooltip('프로젝트 메뉴').first);
      await click(find.text(action));
      expect(tester.takeException(), isNull);
      if (action == '프로젝트 설정') {
        // 설정 창이 뜬다 — 닫으면 포커스가 ⋯ 버튼으로 돌아와도 줄이 회색으로 남으면 안 된다.
        final dialog = find.byType(Dialog);
        expect(dialog, findsOneWidget);
        await click(
          find.descendant(of: dialog, matching: find.byIcon(Icons.close)),
        );
        expect(dialog, findsNothing);
        expect(tester.takeException(), isNull);
      }
      // 마우스를 멀리(본문 가운데) 치운다.
      await mouse.moveTo(const Offset(900, 600));
      await tester.pumpAndSettle();

      // 프로젝트 줄이 그려지는 잉크 판에 포커스 표시 색(검정 12%)이 칠해져 있지 않아야 한다.
      final ink = find
          .ancestor(
            of: find.text('잔디톡').first,
            matching: find.byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_InkFeatures',
            ),
          )
          .first;
      String painted;
      try {
        expect(tester.renderObject(ink), paintsNothing);
        painted = '';
      } catch (e) {
        painted = e.toString();
      }
      expect(painted.contains('alpha: 0.1216'), isFalse, reason: painted);
    });
  }
}
