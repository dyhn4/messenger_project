import 'dart:convert';

import 'package:client/screens/project/project_settings_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('프로젝트 설정: 기본 정보 저장·역할 변경·삭제', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final calls = <String, dynamic>{};
    var deleted = false;
    const json = {'content-type': 'application/json'};
    final client = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'PATCH') {
        calls['${request.method} $path'] = jsonDecode(request.body);
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

    ProjectSettingsResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => result = await showProjectSettingsDialog(
                context,
                session,
                'p1',
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('구성원 2명'), findsOneWidget);

    // 이름 저장
    await tester.enterText(find.widgetWithText(TextField, '프로젝트 이름'), '새 이름');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(calls['PATCH /api/projects/p1']['name'], '새 이름');
    expect(calls['PATCH /api/projects/p1']['isPublic'], true);

    // Sam을 담당자로
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('구성원').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('담당자').last);
    await tester.pumpAndSettle();
    expect(calls['PATCH /api/projects/p1/members/u2'], {'role': 'owner'});

    // 삭제
    final del = find.widgetWithText(OutlinedButton, '프로젝트 삭제');
    await tester.ensureVisible(del);
    await tester.tap(del);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '삭제'));
    await tester.pumpAndSettle();
    expect(deleted, isTrue);
    expect(result, ProjectSettingsResult.deleted);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
