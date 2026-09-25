import 'dart:convert';

import 'package:client/screens/project/project_menu_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const json = {'content-type': 'application/json'};

  testWidgets('프로젝트 메뉴: 메뉴 이동 · 기본 정보 저장 · 멤버 역할 · 이름 확인 후 삭제', (tester) async {
    tester.view.physicalSize = const Size(1400, 950);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final calls = <String, dynamic>{};
    var deleted = false;
    const isPublic = false;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'PATCH') {
        calls['PATCH $path'] = jsonDecode(request.body);
        return http.Response('{}', 200, headers: json);
      }
      if (request.method == 'DELETE' && path == '/api/projects/p1') {
        deleted = true;
        return http.Response('{"ok":true}', 200, headers: json);
      }
      if (path == '/api/projects/p1') {
        return http.Response(
          jsonEncode({
            'id': 'p1',
            'teamId': 't1',
            'name': '잔디톡',
            'identifier': 'TA',
            'color': '#5B8DEF',
            'isPublic': isPublic,
            'myRole': 'owner',
            'createdAt': DateTime.now().millisecondsSinceEpoch,
            'members': [
              {
                'id': 'u1',
                'username': 'riley',
                'name': 'Riley',
                'projectRole': 'owner',
              },
              {
                'id': 'u2',
                'username': 'sam',
                'name': 'Sam',
                'projectRole': 'member',
              },
            ],
          }),
          200,
          headers: json,
        );
      }
      if (path == '/api/projects/p1/notification-settings') {
        return http.Response('{"muted":false}', 200, headers: json);
      }
      if (path == '/api/projects/p1/notification-policy') {
        return http.Response(
          jsonEncode({
            'status': true,
            'priority': true,
            'assigned': true,
            'referenced': true,
            'dueDate': true,
            'taskType': true,
            'customField': true,
            'created': true,
            'deleted': true,
            'comment': true,
            'due': true,
          }),
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
    session.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: client,
    );

    ProjectMenuResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  result = await showProjectMenuDialog(context, session, 'p1'),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 왼쪽 메뉴 6개 + 기본 정보가 먼저 열린다.
    for (final label in ['기본 정보', '필드 / 상태', '멤버', '알림', '템플릿 · 자동화', '삭제']) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    expect(find.text('프로젝트 정보'), findsOneWidget);
    expect(find.text('TA'), findsOneWidget); // 프로젝트 키(수정 불가)

    // 기본 정보 저장
    await tester.enterText(find.byType(TextField).first, '새 이름');
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(calls['PATCH /api/projects/p1']['name'], '새 이름');
    expect(calls['PATCH /api/projects/p1']['isPublic'], false);

    // 멤버(비공개 프로젝트) → 두 패널(멤버 / 담당자)로 나뉘고, 체크 후 화살표로 담당자가 된다.
    await tester.tap(find.text('멤버').first);
    await tester.pumpAndSettle();
    expect(find.text('멤버 관리'), findsOneWidget);
    expect(find.text('프로젝트 멤버'), findsOneWidget);
    expect(find.text('프로젝트 담당자'), findsOneWidget);
    // 왼쪽(멤버)에 Sam, 오른쪽(담당자)에 Riley.
    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('Riley'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('담당자로'));
    await tester.pumpAndSettle();
    expect(calls['PATCH /api/projects/p1/members/u2'], {'role': 'owner'});

    // 끌어다 놓아도 같은 요청이 나간다.
    calls.remove('PATCH /api/projects/p1/members/u2');
    final from = tester.getCenter(find.text('Sam'));
    final to = tester.getCenter(find.text('프로젝트 담당자'));
    final drag = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 100));
    await drag.moveTo(from + const Offset(20, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await drag.moveTo(to + const Offset(0, 60));
    await tester.pump(const Duration(milliseconds: 100));
    await drag.up();
    await tester.pumpAndSettle();
    expect(calls['PATCH /api/projects/p1/members/u2'], {'role': 'owner'});

    // 알림 → 정책 항목이 실제로 그려진다(예전엔 스크롤이 겹쳐 제목만 보였다).
    await tester.tap(find.text('알림').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('모든 멤버에게 적용됩니다'), findsOneWidget);
    for (final label in [
      '업무 변경 알림',
      '상태 변경',
      '우선순위 변경',
      '담당자 변경',
      '마감일 변경',
      '유형 변경',
      '사용자 정의 필드 변경',
      '업무 생성',
      '업무 삭제',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // 아래쪽 항목은 스크롤해야 보인다.
    await tester.drag(find.byType(ListView).last, const Offset(0, -500));
    await tester.pumpAndSettle();
    for (final label in ['댓글 작성', '마감 임박', '이 프로젝트 알림 끄기']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }

    // 삭제 → 이름을 정확히 입력해야 영구 삭제가 열린다.
    await tester.tap(find.text('삭제').first);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '프로젝트 종료'), findsOneWidget);
    final deleteButton = find.widgetWithText(FilledButton, '프로젝트 영구 삭제');
    expect(tester.widget<FilledButton>(deleteButton).onPressed, isNull);

    await tester.enterText(find.widgetWithText(TextField, '프로젝트 이름 입력'), '잔디톡');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(deleteButton).onPressed, isNotNull);
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();
    expect(deleted, isTrue);
    expect(result, ProjectMenuResult.deleted);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('공개 프로젝트의 멤버 화면은 담당자 목록 하나만 보여준다', (tester) async {
    tester.view.physicalSize = const Size(1400, 950);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final client = MockClient((request) async {
      if (request.url.path == '/api/projects/p1') {
        return http.Response(
          jsonEncode({
            'id': 'p1',
            'teamId': 't1',
            'name': '잔디톡',
            'identifier': 'TA',
            'color': '#5B8DEF',
            'isPublic': true,
            'myRole': 'owner',
            'createdAt': DateTime.now().millisecondsSinceEpoch,
            'members': [
              {
                'id': 'u1',
                'username': 'riley',
                'name': 'Riley',
                'projectRole': 'owner',
              },
              {
                'id': 'u2',
                'username': 'sam',
                'name': 'Sam',
                'projectRole': 'member',
              },
            ],
          }),
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
    session.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: client,
    );
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
    await tester.tap(find.text('멤버').first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('멤버 관리'), findsNothing);
    expect(find.text('프로젝트 멤버'), findsNothing);
    expect(find.text('프로젝트 담당자'), findsWidgets); // 제목 + 목록 상자
    expect(find.text('담당자 추가'), findsOneWidget);
    expect(find.text('프로젝트에 담당자를 지정합니다.'), findsOneWidget);
    // 담당자(Riley)만 보이고, 일반 멤버(Sam)·체크상자는 없다.
    expect(find.text('Riley'), findsOneWidget);
    expect(find.text('Sam'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
  });
}
