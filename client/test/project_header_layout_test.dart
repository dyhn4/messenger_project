import 'dart:convert';

import 'package:client/models/team.dart';
import 'package:client/screens/project/project_detail_view.dart';
import 'package:client/screens/project/project_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 프로젝트 화면 오른쪽 위 "새 업무"·"프로젝트 설정" 버튼은 위 구분선(창 상단 바 밑줄)과
/// 아래 구분선(탭 줄 윗줄) 사이 정가운데 높이에 온다 — 설명이 없을 때·두 줄로 길 때, 좁은 창,
/// 종료된 프로젝트(아래 경계는 "종료된 프로젝트입니다" 안내 띠), 데스크톱·터치 버튼 크기 모두.
void main() {
  // 버튼 크기는 플랫폼마다 다르다 — 데스크톱은 촘촘한 밀도(compact)에 누름 영역을 줄이고(shrinkWrap),
  // 터치(안드로이드)는 기본 밀도에 48px 누름 영역을 둔다. TargetPlatform.windows로 바꾸면 대시보드
  // 탭의 스크롤바가 테스트에서 따로 오류를 내서(이 기능과 무관), 테마로 데스크톱 크기를 흉내 낸다.
  final density = ValueVariant<String>({'터치', '데스크톱'});
  ThemeData themeFor(String? kind) => kind == '데스크톱'
      ? ThemeData(
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        )
      : ThemeData();

  const json = {'content-type': 'application/json'};
  final now = DateTime.now().millisecondsSinceEpoch;
  const longDescription =
      '브리프부터 광고 집행, 성과 보고까지 캠페인의 모든 단계를 한곳에서 따라갑니다. '
      '매주 월요일 회의에서 진행 상황을 확인하고, 막힌 업무는 담당자와 기한을 다시 정합니다. '
      '디자인 시안과 카피는 노트에 모아 두고, 승인된 결과물만 업무에 첨부합니다.';

  Map<String, dynamic> project(
    String id,
    String name, {
    String? description,
    bool archived = false,
  }) => {
    'id': id,
    'teamId': 't1',
    'name': name,
    'description': description,
    'identifier': id.toUpperCase(),
    'color': '#5B8DEF',
    'archived': archived,
    'myRole': 'owner',
    'createdAt': now,
    'members': <Map<String, dynamic>>[],
  };

  final active = [
    project('p1', '잔디톡', description: '브리프부터 광고 집행까지 컬럼으로 따라갑니다.'),
    project('p2', '설명 없음'),
    project('p3', '긴 설명', description: longDescription),
  ];
  final archived = [
    project('p4', '지난 캠페인', description: '작년 하반기 캠페인', archived: true),
  ];

  Session buildSession() {
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/projects') {
        return http.Response(
          jsonEncode(
            request.url.queryParameters['archived'] == '1' ? archived : active,
          ),
          200,
          headers: json,
        );
      }
      if (path == '/api/projects/home') {
        return http.Response(
          jsonEncode({
            'stats': {'total': 0, 'done': 0, 'doing': 0, 'overdue': 0},
            'projects': active,
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
      final detail = RegExp(r'^/api/projects/(\w+)$').firstMatch(path);
      if (detail != null) {
        final p = [
          ...active,
          ...archived,
        ].firstWhere((p) => p['id'] == detail.group(1));
        return http.Response(jsonEncode(p), 200, headers: json);
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

  Future<void> pumpDialog(
    WidgetTester tester, {
    double width = 1400,
    String? kind,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(kind),
        home: ProjectDialog(session: buildSession(), embedInWindow: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  /// 사이드바(좁은 창이면 » 스트립으로 펼친 겹침 메뉴)에서 프로젝트를 연다.
  Future<void> open(WidgetTester tester, String name) async {
    final sidebar = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_Sidebar',
    );
    if (sidebar.evaluate().isEmpty) {
      await tester.tap(find.byIcon(Icons.keyboard_double_arrow_right));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.descendant(of: sidebar, matching: find.text(name)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  final inDetail = find.byType(ProjectDetailView);

  /// 위 구분선 밑변과 아래 경계(탭 줄 윗줄, 종료된 프로젝트면 안내 띠) 윗변.
  ({double top, double bottom}) bounds(
    WidgetTester tester, {
    bool archived = false,
  }) {
    // 창 맨 위 줄(로고·검색·종) 바로 아래 구분선 — 창 안에서 가장 먼저 그려지는 Divider.
    final topLine = tester.getRect(
      find
          .descendant(
            of: find.byType(ProjectDialog),
            matching: find.byType(Divider),
          )
          .first,
    );
    expect(topLine.top, 56, reason: '상단 바(56) 바로 아래');
    final bottom = archived
        ? tester
              .getRect(
                find
                    .ancestor(
                      of: find.text('종료된 프로젝트입니다. 읽기만 할 수 있습니다.'),
                      matching: find.byType(Container),
                    )
                    .first,
              )
              .top
        : tester
              .getRect(
                find
                    .descendant(of: inDetail, matching: find.byType(Divider))
                    .first,
              )
              .top;
    return (top: topLine.bottom, bottom: bottom);
  }

  /// 두 버튼(종료된 프로젝트는 설정 버튼만)의 세로 가운데가 두 경계의 정가운데인지(±1px).
  ({double top, double bottom}) expectCentered(
    WidgetTester tester, {
    bool archived = false,
  }) {
    final b = bounds(tester, archived: archived);
    final mid = (b.top + b.bottom) / 2;
    final settings = tester.getRect(find.byTooltip('프로젝트 설정'));
    expect(settings.center.dy, closeTo(mid, 1), reason: '프로젝트 설정 버튼');
    // 버튼이 위아래 구분선에 닿거나 넘지 않는다.
    expect(settings.top, greaterThan(b.top));
    expect(settings.bottom, lessThan(b.bottom));
    if (!archived) {
      final newTask = tester.getRect(find.widgetWithText(FilledButton, '새 업무'));
      expect(newTask.center.dy, closeTo(mid, 1), reason: '새 업무 버튼');
      // 두 버튼은 한 줄에 나란히(새 업무 → 설정).
      expect(newTask.right, lessThanOrEqualTo(settings.left));
    } else {
      expect(find.widgetWithText(FilledButton, '새 업무'), findsNothing);
    }
    return b;
  }

  /// 프로젝트 머리(색 막대)는 예전 자리 그대로 — 위 구분선에서 14, 아래 경계까지 8 떨어져 있다.
  void expectHeaderGaps(WidgetTester tester, ({double top, double bottom}) b) {
    final bar = tester.getRect(
      find
          .descendant(
            of: inDetail,
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Container &&
                  w.constraints == const BoxConstraints.tightFor(width: 4),
            ),
          )
          .first,
    );
    expect(bar.top - b.top, closeTo(14, 0.5));
    expect(b.bottom - bar.bottom, closeTo(8, 0.5));
  }

  Finder bigTitle(String name) => find.byWidgetPredicate(
    (w) => w is Text && w.data == name && w.style?.fontSize == 22,
  );

  testWidgets('설명이 있을 때·없을 때·두 줄로 길 때 모두 버튼이 위아래 구분선의 가운데', (tester) async {
    await pumpDialog(tester, kind: density.currentValue);

    await open(tester, '잔디톡');
    expect(bigTitle('잔디톡'), findsOneWidget);
    final withDesc = expectCentered(tester);
    expectHeaderGaps(tester, withDesc);
    final oneLine = tester
        .getSize(find.text('브리프부터 광고 집행까지 컬럼으로 따라갑니다.'))
        .height;

    await open(tester, '설명 없음');
    expect(bigTitle('설명 없음'), findsOneWidget);
    final noDesc = expectCentered(tester);
    expectHeaderGaps(tester, noDesc);
    // 설명 줄이 빠진 만큼 머리 줄이 낮아져도 버튼은 여전히 가운데다.
    expect(
      noDesc.bottom - noDesc.top,
      lessThan(withDesc.bottom - withDesc.top),
    );

    await open(tester, '긴 설명');
    final desc = find.text(longDescription);
    expect(desc, findsOneWidget);
    // 설명은 두 줄까지 보인다(더 길면 말줄임).
    expect(tester.getSize(desc).height, closeTo(oneLine * 2, 1));
    final twoLines = expectCentered(tester);
    expectHeaderGaps(tester, twoLines);
    expect(
      twoLines.bottom - twoLines.top,
      greaterThan(withDesc.bottom - withDesc.top),
    );
  }, variant: density);

  testWidgets('좁은 창(왼쪽 메뉴를 접은 모양)에서도 버튼이 가운데', (tester) async {
    await pumpDialog(tester, width: 720, kind: density.currentValue);
    await open(tester, '잔디톡');
    expect(bigTitle('잔디톡'), findsOneWidget);
    expectHeaderGaps(tester, expectCentered(tester));

    await open(tester, '긴 설명');
    expectHeaderGaps(tester, expectCentered(tester));
  }, variant: density);

  testWidgets('종료된 프로젝트: 머리(별 없음) + 설정 버튼만, 위 구분선과 안내 띠 사이의 가운데', (
    tester,
  ) async {
    await pumpDialog(tester, kind: density.currentValue);
    // 사이드바 맨 아래 "종료된 프로젝트" 묶음을 펼쳐 연다.
    await tester.tap(find.text('종료된 프로젝트 1'));
    await tester.pumpAndSettle();
    await open(tester, '지난 캠페인');

    // 예전에는 작은 제목만 나왔다 — 이제 진행 중 프로젝트와 같은 머리를 쓴다.
    expect(bigTitle('지난 캠페인'), findsOneWidget);
    expect(find.text('작년 하반기 캠페인'), findsOneWidget);
    // 종료된 프로젝트는 즐겨찾기 묶음에 안 나오므로 별이 없다.
    expect(find.byIcon(Icons.star_outline_rounded), findsNothing);
    expect(find.byIcon(Icons.star_rounded), findsNothing);
    expect(find.text('종료된 프로젝트입니다. 읽기만 할 수 있습니다.'), findsOneWidget);
    final b = expectCentered(tester, archived: true);
    expectHeaderGaps(tester, b);
  }, variant: density);
}
