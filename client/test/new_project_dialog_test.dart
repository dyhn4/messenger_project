import 'dart:convert';

import 'package:client/screens/project/project_forms.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('프로젝트 생성: 색상·키·공개 설정이 서버로 전달된다', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Map<String, dynamic>? sent;
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path.endsWith('/projects')) {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'id': 'p1',
            'teamId': 't1',
            'name': sent!['name'],
            'identifier': sent!['identifier'],
            'color': sent!['color'],
            'isPublic': sent!['isPublic'],
            'createdAt': DateTime.now().millisecondsSinceEpoch,
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
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
              onPressed: () => showNewProjectDialog(context, session, 't1'),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(find.textContaining('프로젝트 이름', findRichText: true), findsWidgets);
    expect(find.textContaining('대표 색상', findRichText: true), findsOneWidget);
    expect(find.textContaining('프로젝트 키', findRichText: true), findsOneWidget);
    expect(find.textContaining('설명', findRichText: true), findsWidgets);
    expect(find.text('공개 설정'), findsOneWidget);
    expect(find.textContaining('별도 초대 없이'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '2분기 YM');
    // 두 번째 색(초록)을 고른다.
    final dots = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(InkWell),
    );
    // 색상 점(32x32 InkWell)만 골라 두 번째(초록)를 누른다.
    final colorDots = dots
        .evaluate()
        .where((e) => (e.renderObject as RenderBox).size == const Size(32, 32))
        .toList();
    expect(colorDots.length, 7);
    await tester.tap(find.byWidget(colorDots[1].widget));
    await tester.pump();
    // 비공개로 바꾼다(폼이 길어 스크롤해야 보인다).
    await tester.ensureVisible(find.text('공개').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('공개').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('비공개').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('초대한 구성원만'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '프로젝트 생성'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(sent, isNotNull);
    expect(sent!['name'], '2분기 YM');
    expect(sent!['color'], '#10B981');
    expect(sent!['isPublic'], false);
    expect(sent!['identifier'], 'YM');
  });
}
