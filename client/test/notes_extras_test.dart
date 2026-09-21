import 'dart:convert';

import 'package:client/screens/project/notes_view.dart';
import 'package:client/screens/project/task_filter.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/models/project.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const json = {'content-type': 'application/json'};

  test('TaskFilter: 숫자·날짜 범위', () {
    Task task(Map<String, dynamic> custom) => Task.fromJson({
      'id': '1',
      'projectId': 'p1',
      'title': 't',
      'status': 'todo',
      'priority': 'normal',
      'createdAt': 0,
      'customValues': custom,
    });
    const fields = [
      TaskFieldDef(id: 'n', projectId: 'p1', name: '예산', kind: 'number'),
      TaskFieldDef(id: 'd', projectId: 'p1', name: '납기', kind: 'date'),
    ];
    bool m(TaskFilter f, Task t) => f.matches(t, fields: fields);
    final t = task({
      'n': 150,
      'd': DateTime(2026, 9, 10).millisecondsSinceEpoch,
    });

    expect(
      m(const TaskFilter(fieldRanges: {'n': FieldRange(min: 100)}), t),
      isTrue,
    );
    expect(
      m(const TaskFilter(fieldRanges: {'n': FieldRange(min: 200)}), t),
      isFalse,
    );
    expect(
      m(const TaskFilter(fieldRanges: {'n': FieldRange(max: 150)}), t),
      isTrue,
    );
    // 값이 없는 업무는 범위 조건에 걸리면 빠진다.
    expect(
      m(const TaskFilter(fieldRanges: {'n': FieldRange(min: 0)}), task({})),
      isFalse,
    );
    final from = DateTime(2026, 9, 1).millisecondsSinceEpoch;
    final to = DateTime(2026, 9, 10, 23, 59, 59, 999).millisecondsSinceEpoch;
    expect(
      m(
        TaskFilter(
          fieldRanges: {'d': FieldRange(min: from, max: to)},
        ),
        t,
      ),
      isTrue,
    );
    expect(
      m(
        TaskFilter(
          fieldRanges: {
            'd': FieldRange(min: DateTime(2026, 9, 11).millisecondsSinceEpoch),
          },
        ),
        t,
      ),
      isFalse,
    );
    expect(
      const TaskFilter(fieldRanges: {'n': FieldRange(min: 1)}).activeCount,
      1,
    );
  });

  testWidgets('노트 댓글 남기기·지우기와 수정 이력에서 되돌리기', (tester) async {
    tester.view.physicalSize = const Size(1300, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final calls = <String, dynamic>{};
    final t0 = DateTime(2026, 9, 1, 10).millisecondsSinceEpoch;
    var commented = false;
    Map<String, dynamic> note({bool body = false, String title = '주간 회의록'}) => {
      'id': 'n1',
      'projectId': 'p1',
      'projectName': '잔디톡',
      'projectColor': '#5B8DEF',
      'title': title,
      'preview': '# 안건',
      'body': ?(body ? '현재 내용' : null),
      'createdBy': 'u1',
      'createdByName': 'Riley',
      'updatedByName': 'Riley',
      'createdAt': t0,
      'updatedAt': t0,
    };
    final client = MockClient((request) async {
      final path = request.url.path;
      final key = '${request.method} $path';
      if (request.method == 'GET') {
        if (path == '/api/notes') {
          return http.Response(jsonEncode([note()]), 200, headers: json);
        }
        if (path == '/api/notes/n1') {
          return http.Response(
            jsonEncode(note(body: true)),
            200,
            headers: json,
          );
        }
        if (path == '/api/notes/n1/comments') {
          return http.Response(
            jsonEncode([
              {
                'id': 'c1',
                'noteId': 'n1',
                'senderId': 'u2',
                'senderName': 'Sam',
                'text': '확인했습니다',
                'createdAt': t0,
              },
              if (commented)
                {
                  'id': 'c2',
                  'noteId': 'n1',
                  'senderId': 'u1',
                  'senderName': 'Riley',
                  'text': '감사합니다',
                  'createdAt': t0,
                },
            ]),
            200,
            headers: json,
          );
        }
        if (path == '/api/notes/n1/versions') {
          return http.Response(
            jsonEncode([
              {
                'id': 'v1',
                'title': '이전 제목',
                'editedByName': 'Sam',
                'editedAt': t0,
              },
            ]),
            200,
            headers: json,
          );
        }
        if (path == '/api/note-versions/v1') {
          return http.Response(
            jsonEncode({
              'id': 'v1',
              'noteId': 'n1',
              'title': '이전 제목',
              'body': '예전 내용',
              'editedByName': 'Sam',
              'editedAt': t0,
            }),
            200,
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
                'myRole': 'owner',
                'createdAt': t0,
              },
            ]),
            200,
            headers: json,
          );
        }
        return http.Response('[]', 200, headers: json);
      }
      calls[key] = request.body.isEmpty ? null : jsonDecode(request.body);
      if (path == '/api/notes/n1/comments') {
        commented = true;
        return http.Response(
          '{"id":"c2","noteId":"n1","senderName":"Riley","text":"감사합니다","createdAt":$t0}',
          201,
          headers: json,
        );
      }
      if (path == '/api/notes/n1/restore') {
        return http.Response(
          jsonEncode(note(body: true, title: '이전 제목')),
          200,
          headers: json,
        );
      }
      return http.Response('{"ok":true}', 200, headers: json);
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
    await tester.tap(find.text('주간 회의록'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('댓글 1'), findsOneWidget);
    expect(find.text('확인했습니다'), findsOneWidget);

    // 댓글 남기기
    await tester.enterText(find.widgetWithText(TextField, '댓글 남기기'), '감사합니다');
    await tester.tap(find.widgetWithText(FilledButton, '등록'));
    await tester.pumpAndSettle();
    expect(calls['POST /api/notes/n1/comments'], {'text': '감사합니다'});
    expect(find.text('댓글 2'), findsOneWidget);

    // 내 댓글만 지울 수 있다(프로젝트 담당자라 Sam 것도 가능 — 두 개 다 삭제 버튼)
    await tester.tap(find.byTooltip('댓글 삭제').last);
    await tester.pumpAndSettle();
    expect(
      calls.keys.any((k) => k.startsWith('DELETE /api/note-comments/')),
      isTrue,
    );

    // 수정 이력 → 버전 보기 → 되돌리기
    await tester.tap(find.byTooltip('수정 이력'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Sam · 이전 제목'));
    await tester.pumpAndSettle();
    expect(find.text('예전 내용'), findsOneWidget);
    await tester.tap(find.text('이 버전으로 되돌리기'));
    await tester.pumpAndSettle();
    expect(calls['POST /api/notes/n1/restore'], {'versionId': 'v1'});

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
