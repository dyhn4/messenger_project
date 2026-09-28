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

    // 왼쪽 메뉴 7개(이 순서로 위에서 아래로) + 기본 정보가 먼저 열린다. 업무 템플릿은 메뉴에서
    // 빠지고 필드 / 상태 화면의 칸으로 옮겨 갔고, 노트가 자동화와 삭제 사이에 들어왔다.
    const menu = ['기본 정보', '필드 / 상태', '멤버', '알림', '자동화', '노트', '삭제'];
    for (final label in menu) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    for (var i = 1; i < menu.length; i++) {
      final above = tester.getCenter(find.text(menu[i - 1]));
      final below = tester.getCenter(find.text(menu[i]));
      expect(below.dy, greaterThan(above.dy), reason: menu[i]);
      expect(below.dx, closeTo(above.dx, 40), reason: menu[i]);
    }
    expect(find.text('업무 템플릿'), findsNothing);
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

    // 자동화 → "자동화 규칙 / 실행 기록" 탭과 새 자동화 버튼만 있고, 템플릿은 따로 있다.
    await tester.tap(find.text('자동화').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('자동화 규칙'), findsOneWidget);
    expect(find.text('실행 기록'), findsOneWidget);
    expect(find.text('새 자동화'), findsOneWidget);
    expect(find.text('양식 추가'), findsNothing);

    // 필드 / 상태 → 사용자 정의 필드 아래 "업무 템플릿" 칸 — 템플릿을 안 썼으니 "템플릿 저장",
    // 그 아래 새 업무 양식 목록(예전 업무 템플릿 메뉴).
    await tester.tap(find.text('필드 / 상태').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('업무 템플릿'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('업무 템플릿')).dy,
      greaterThan(tester.getTopLeft(find.text('사용자 정의 필드')).dy),
    );
    expect(find.widgetWithText(FilledButton, '템플릿 저장'), findsOneWidget);
    expect(find.text('새 업무 양식'), findsOneWidget);
    expect(find.text('양식 추가'), findsOneWidget);
    expect(find.text('자동화 규칙'), findsNothing);

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

  /// 공개 프로젝트의 설정 > 멤버 화면을 [myRole]로 연다. 나간 PATCH 요청을 모아 돌려준다.
  Future<Map<String, dynamic>> openPublicMembers(
    WidgetTester tester, {
    required String myRole,
  }) async {
    tester.view.physicalSize = const Size(1400, 950);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final calls = <String, dynamic>{};
    final client = MockClient((request) async {
      if (request.method == 'PATCH') {
        calls['PATCH ${request.url.path}'] = jsonDecode(request.body);
        return http.Response('{}', 200, headers: json);
      }
      if (request.url.path == '/api/projects/p1') {
        return http.Response(
          jsonEncode({
            'id': 'p1',
            'teamId': 't1',
            'name': '잔디톡',
            'identifier': 'TA',
            'color': '#5B8DEF',
            'isPublic': true,
            'myRole': myRole,
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
              {
                'id': 'u3',
                'username': 'jo',
                'name': 'Jo',
                'projectRole': 'owner',
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
    return calls;
  }

  testWidgets('공개 프로젝트의 멤버 화면은 담당자 목록 하나만 보여준다', (tester) async {
    final calls = await openPublicMembers(tester, myRole: 'owner');

    expect(find.text('멤버 관리'), findsNothing);
    expect(find.text('프로젝트 멤버'), findsNothing);
    expect(find.text('프로젝트 담당자'), findsWidgets); // 제목 + 목록 상자
    expect(find.text('담당자 추가'), findsOneWidget);
    expect(find.text('프로젝트에 담당자를 지정합니다.'), findsOneWidget);
    // 정회원 이상 팀원 모두가 자동으로 멤버라는 안내 — 초대·제외는 없다.
    expect(find.text('공개 프로젝트는 정회원 이상 팀원 모두가 멤버입니다.'), findsOneWidget);
    expect(find.text('멤버 초대하기'), findsNothing);
    expect(find.byTooltip('프로젝트에서 제외'), findsNothing);
    // 담당자(Riley·Jo)만 보이고, 일반 멤버(Sam)·체크상자는 없다.
    expect(find.text('Riley'), findsOneWidget);
    expect(find.text('Jo'), findsOneWidget);
    expect(find.text('Sam'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);

    // 담당자의 X는 프로젝트에서 빼지 않고 일반 멤버로 내린다.
    expect(find.byTooltip('담당자 해제'), findsNWidgets(2));
    await tester.tap(find.byTooltip('담당자 해제').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(calls['PATCH /api/projects/p1/members/u1'], {'role': 'member'});

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('공개 프로젝트: 담당자가 아니면 담당자 추가·해제가 보이지 않는다', (tester) async {
    await openPublicMembers(tester, myRole: 'member');

    expect(find.text('공개 프로젝트는 정회원 이상 팀원 모두가 멤버입니다.'), findsOneWidget);
    expect(find.text('Riley'), findsOneWidget);
    expect(find.text('담당자 추가'), findsNothing);
    expect(find.text('멤버 초대하기'), findsNothing);
    expect(find.byTooltip('담당자 해제'), findsNothing);
    expect(find.byTooltip('프로젝트에서 제외'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
