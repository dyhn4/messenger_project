import 'dart:convert';

import 'package:client/models/message.dart';
import 'package:client/models/team.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/message_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('메시지를 업무로 등록: 제목·설명 미리 채워서 새 업무 창을 열고 등록', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Map<String, dynamic>? created;
    const json = {'content-type': 'application/json'};
    final client = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'POST' && path == '/api/projects/p1/tasks') {
        created = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'id': 't1',
            'projectId': 'p1',
            'key': 'TA-7',
            'title': created!['title'],
            'status': 'todo',
            'priority': 'normal',
            'createdAt': DateTime.now().millisecondsSinceEpoch,
          }),
          201,
          headers: json,
        );
      }
      if (path == '/api/projects') {
        return http.Response(
          jsonEncode([
            {
              'id': 'p1',
              'teamId': 't1',
              'name': '잔디톡',
              'identifier': 'TA',
              'createdAt': DateTime.now().millisecondsSinceEpoch,
            },
          ]),
          200,
          headers: json,
        );
      }
      if (path == '/api/projects/p1') {
        return http.Response(
          jsonEncode({
            'id': 'p1',
            'teamId': 't1',
            'name': '잔디톡',
            'identifier': 'TA',
            'createdAt': DateTime.now().millisecondsSinceEpoch,
            'members': [],
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
    session.currentTeam = Team(id: 't1', name: '팀', createdAt: DateTime.now());

    final message = Message(
      id: 'm1',
      roomId: 'r1',
      senderId: 'u2',
      senderName: 'Sam',
      type: MessageType.text,
      text: '배포 전에 로그인 오류 확인 부탁해요\n재현 방법은 아래와 같아요',
      createdAt: DateTime(2026, 9, 21, 14, 5),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => registerMessageAsTask(
                context,
                session: session,
                message: message,
                senderDisplayName: 'Sam',
              ),
              child: const Text('등록'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('등록'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 메시지 내용(+ 출처)은 설명에, 업무(제목)는 비워 두어 '업무 입력' 안내가 보인다.
    // 프로젝트도 고르기 전이라 '프로젝트 선택'.
    expect(find.text('업무 입력'), findsOneWidget);
    expect(find.text('프로젝트 선택'), findsOneWidget);
    expect(find.textContaining('재현 방법은 아래와 같아요'), findsOneWidget);
    expect(find.textContaining('Sam'), findsWidgets);

    // 프로젝트를 고르지 않으면 만들 수 없다.
    await tester.tap(find.widgetWithText(FilledButton, '생성'));
    await tester.pumpAndSettle();
    expect(created, isNull);

    await tester.tap(find.text('프로젝트 선택'), warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('잔디톡').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '업무 입력'),
      '로그인 오류 확인',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '생성'));
    await tester.pumpAndSettle();
    expect(created?['title'], '로그인 오류 확인');
    expect(created?['description'], contains('재현 방법은 아래와 같아요'));
    expect(created?['description'], contains('Sam'));
    expect(find.text('TA-7로 등록했습니다.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
