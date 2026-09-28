import 'dart:convert';

import 'package:client/models/app_user.dart';
import 'package:client/models/project.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/desktop_home_screen.dart';
import 'package:client/screens/project/project_menu_dialog.dart';
import 'package:client/screens/project/project_views.dart';
import 'package:client/screens/project/task_views.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// 윈도우(데스크톱)에서는 스크롤 뷰가 PrimaryScrollController에 붙지 않는다 — 컨트롤러 없이 늘 보이는
// 스크롤바를 달면 디버그 모드에서 "The Scrollbar's ScrollController has no ScrollPosition attached"
// 오류가 난다. 기본 테스트 플랫폼(안드로이드)에서는 안 보이는 문제라 플랫폼을 윈도우로 바꿔 확인한다.

const _json = {'content-type': 'application/json'};
final _now = DateTime.now();

Map<String, dynamic> _task(
  String id,
  String title, {
  String status = 'todo',
  String? assignee,
}) => {
  'id': id,
  'projectId': 'p1',
  'key': 'TA-$id',
  'title': title,
  'status': status,
  'priority': 'normal',
  'assigneeId': assignee,
  'startDate': _now.millisecondsSinceEpoch,
  'dueDate': _now.millisecondsSinceEpoch,
  'createdAt': _now.millisecondsSinceEpoch,
};

Map<String, dynamic> _project() => {
  'id': 'p1',
  'teamId': 't1',
  'name': '잔디톡',
  'description': '메신저 앱',
  'identifier': 'TA',
  'color': '#5B8DEF',
  'myRole': 'owner',
  'createdAt': 0,
  'noteEditPermission': 'all',
  'noteDeletePermission': 'creator_admin',
  'members': [
    {'id': 'u1', 'username': 'riley', 'name': 'Riley', 'projectRole': 'owner'},
    {'id': 'u2', 'username': 'sam', 'name': 'Sam', 'projectRole': 'member'},
  ],
};

Session _session() {
  final session = Session(
    notifications: NotificationService(),
    settings: AppSettings(),
  );
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: MockClient((request) async {
      if (request.url.path == '/api/projects/p1') {
        return http.Response(jsonEncode(_project()), 200, headers: _json);
      }
      return http.Response('[]', 200, headers: _json);
    }),
  );
  return session;
}

/// [body]를 윈도우 플랫폼으로 돌리고, 끝나면(실패해도) 원래대로 되돌린다.
Future<void> _onWindows(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  testWidgets('윈도우: 프로젝트 대시보드 스크롤바가 오류 없이 붙는다', (tester) async {
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _onWindows(() async {
      final tasks = [
        for (var i = 0; i < 12; i++)
          Task.fromJson(
            _task('$i', '업무 $i', status: i.isEven ? 'done' : 'todo'),
          ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskDashboardView(
              tasks: tasks,
              members: [
                AppUser.fromJson({
                  'id': 'u1',
                  'username': 'riley',
                  'name': 'Riley',
                }),
              ],
              session: _session(),
              onOpen: (_) {},
              onStatTap: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('전체 업무'), findsOneWidget);

      // 스크롤바가 실제 대시보드 내용에 붙어 있다 — 끌면 내용이 움직인다.
      final scrollView = find.byType(SingleChildScrollView).first;
      final controller = tester
          .widget<SingleChildScrollView>(scrollView)
          .controller;
      expect(controller, isNotNull);
      expect(controller!.hasClients, isTrue);
      expect(
        tester.widget<Scrollbar>(find.byType(Scrollbar).first).controller,
        same(controller),
      );

      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('윈도우: 프로젝트 설정의 모든 칸(기본 정보·노트·삭제 등)이 오류 없이 열린다', (tester) async {
    tester.view.physicalSize = const Size(1400, 950);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _onWindows(() async {
      final session = _session();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showProjectMenuDialog(context, session, 'p1'),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      // 처음 열리는 칸은 기본 정보.
      expect(tester.takeException(), isNull);
      expect(find.text('프로젝트 이름'), findsWidgets);

      for (final section in [
        '필드 / 상태',
        '멤버',
        '알림',
        '자동화',
        '노트',
        '삭제',
        '기본 정보',
      ]) {
        await tester.tap(find.text(section).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: section);
      }

      // 노트 칸: 스크롤바와 스크롤 뷰가 같은 컨트롤러를 쓴다.
      await tester.tap(find.text('노트').first);
      await tester.pumpAndSettle();
      final scrollView = find
          .ancestor(
            of: find.text('노트 수정 권한'),
            matching: find.byType(SingleChildScrollView),
          )
          .first;
      final controller = tester
          .widget<SingleChildScrollView>(scrollView)
          .controller;
      expect(controller?.hasClients, isTrue);
      expect(
        tester
            .widget<Scrollbar>(
              find
                  .ancestor(of: scrollView, matching: find.byType(Scrollbar))
                  .first,
            )
            .controller,
        same(controller),
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    });
  });

  testWidgets('윈도우: 메신저 왼쪽 대화방 세 구역(토픽·그룹·1:1) 스크롤바가 오류 없이 붙는다', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _onWindows(() async {
      final session = _session()
        ..currentTeam = Team(id: 't1', name: '팀', createdAt: DateTime(2026));
      await tester.pumpWidget(
        MaterialApp(home: DesktopHomeScreen(session: session)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // 구역마다 스크롤바와 목록이 자기 컨트롤러를 같이 쓴다.
      final sections = find.byWidgetPredicate(
        (w) => w is Scrollbar && w.child is ListView,
      );
      expect(sections, findsNWidgets(3));
      for (final bar in tester.widgetList<Scrollbar>(sections)) {
        final list = bar.child as ListView;
        expect(bar.controller, isNotNull);
        expect(list.controller, same(bar.controller));
        expect(bar.controller!.hasClients, isTrue);
      }

      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('윈도우: 캘린더 일별 업무 목록 스크롤바가 오류 없이 붙는다', (tester) async {
    tester.view.physicalSize = const Size(1300, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _onWindows(() async {
      final tasks = [
        for (var i = 0; i < 15; i++) Task.fromJson(_task('$i', '오늘 업무 $i')),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskCalendarView(tasks: tasks, onOpen: (_) {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('해당 일의 업무 15건'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });
  });
}
