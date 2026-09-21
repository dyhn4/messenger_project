import 'dart:convert';

import 'package:client/screens/project/notes_view.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('프로젝트 노트: 목록·읽기·새 노트·편집(충돌 방지 기준 시각)·삭제', (tester) async {
    tester.view.physicalSize = const Size(1300, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final calls = <String, dynamic>{};
    const json = {'content-type': 'application/json'};
    final t0 = DateTime(2026, 9, 1, 10).millisecondsSinceEpoch;
    Map<String, dynamic> note({bool body = false}) => {
      'id': 'n1',
      'projectId': 'p1',
      'projectName': '잔디톡',
      'projectColor': '#5B8DEF',
      'title': '주간 회의록',
      'preview': '# 안건',
      'body': ?(body ? '# 안건\n- 배포 일정\n- [x] 리뷰 완료\n> 참고' : null),
      'createdBy': 'u1',
      'createdByName': 'Riley',
      'updatedByName': 'Riley',
      'createdAt': t0,
      'updatedAt': t0,
    };
    var created = false;
    final client = MockClient((request) async {
      final path = request.url.path;
      final key = '${request.method} $path';
      if (request.method == 'GET' && path == '/api/notes') {
        return http.Response(
          jsonEncode([
            note(),
            if (created) {...note(), 'id': 'n2', 'title': '새 노트'},
          ]),
          200,
          headers: json,
        );
      }
      if (request.method == 'GET' && path.endsWith('/comments')) {
        return http.Response('[]', 200, headers: json);
      }
      if (request.method == 'GET' && path.startsWith('/api/notes/')) {
        return http.Response(jsonEncode(note(body: true)), 200, headers: json);
      }
      if (request.method == 'GET' && path == '/api/projects') {
        return http.Response(
          jsonEncode([
            {
              'id': 'p1',
              'teamId': 't1',
              'name': '잔디톡',
              'identifier': 'TA',
              'myRole': 'owner',
              'createdAt': t0,
            },
          ]),
          200,
          headers: json,
        );
      }
      if (request.method == 'POST' && path == '/api/projects/p1/notes') {
        calls[key] = jsonDecode(request.body);
        created = true;
        return http.Response(
          jsonEncode({...note(body: true), 'id': 'n2', 'title': '새 노트'}),
          201,
          headers: json,
        );
      }
      if (request.method == 'PATCH' && path == '/api/notes/n1') {
        calls[key] = jsonDecode(request.body);
        return http.Response(jsonEncode(note(body: true)), 200, headers: json);
      }
      if (request.method == 'DELETE') {
        calls[key] = true;
        return http.Response('{"ok":true}', 200, headers: json);
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
    session.userId = 'u1';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotesView(
            session: session,
            teamId: 't1',
            projectId: 'p1',
            reloadTick: 0,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('주간 회의록'), findsOneWidget);

    // 읽기: 마크다운 줄 렌더링
    await tester.tap(find.text('주간 회의록'));
    await tester.pumpAndSettle();
    expect(find.text('안건'), findsOneWidget); // '# ' 제거
    expect(find.text('배포 일정'), findsOneWidget);
    expect(find.byIcon(Icons.check_box), findsOneWidget);
    expect(find.text('참고'), findsOneWidget);

    // 편집 → 저장: 열 때의 수정 시각을 함께 보낸다
    await tester.tap(find.text('편집'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '제목'), '주간 회의록 v2');
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    final patch = calls['PATCH /api/notes/n1'] as Map;
    expect(patch['title'], '주간 회의록 v2');
    expect(patch['baseUpdatedAt'], t0);

    // 새 노트
    await tester.tap(find.text('새 노트'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '제목'), '새 노트');
    await tester.enterText(find.widgetWithText(TextField, '내용'), '본문');
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(calls['POST /api/projects/p1/notes'], {
      'title': '새 노트',
      'body': '본문',
    });

    // 삭제(작성자=나)
    await tester.tap(find.byTooltip('삭제'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '삭제'));
    await tester.pumpAndSettle();
    expect(calls.keys.any((k) => k.startsWith('DELETE /api/notes/')), isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
