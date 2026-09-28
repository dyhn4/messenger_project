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

// 프로젝트 설정 > 노트의 수정·삭제 권한 — 서버가 노트마다 canEdit·canDelete를 사람마다 계산해
// 주면, 노트 화면은 그에 맞춰 수정·삭제·되돌리기를 감추고, 그래도 막히면 서버 안내를 보여준다.

const _json = {'content-type': 'application/json'};

class _Server {
  bool canEdit;
  bool canDelete;

  /// 저장·삭제를 서버가 403으로 막을지(그 사이 권한이 바뀐 경우).
  bool rejectEdit = false;
  bool rejectDelete = false;
  final calls = <String>[];

  _Server({this.canEdit = true, this.canDelete = true});

  final t0 = DateTime(2026, 9, 1, 10).millisecondsSinceEpoch;

  Map<String, dynamic> note({bool body = false}) => {
    'id': 'n1',
    'key': 'TA-N1',
    'projectId': 'p1',
    'projectName': '잔디톡',
    'projectColor': '#5B8DEF',
    'title': '주간 회의록',
    'preview': '안건',
    'body': ?(body ? '안건' : null),
    'createdBy': 'u2',
    'createdByName': 'Sam',
    'updatedByName': 'Sam',
    'createdAt': t0,
    'updatedAt': t0,
    'canEdit': canEdit,
    'canDelete': canDelete,
  };

  late final Session session = () {
    final s = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    s.userId = 'u1';
    s.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: MockClient((request) async {
        final path = request.url.path;
        calls.add('${request.method} $path');
        if (request.method == 'GET') {
          if (path == '/api/notes') {
            return http.Response(jsonEncode([note()]), 200, headers: _json);
          }
          if (path == '/api/notes/n1') {
            return http.Response(
              jsonEncode(note(body: true)),
              200,
              headers: _json,
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
              headers: _json,
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
              headers: _json,
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
                  'myRole': 'member',
                  'createdAt': t0,
                },
              ]),
              200,
              headers: _json,
            );
          }
          return http.Response('[]', 200, headers: _json);
        }
        if (request.method == 'PATCH' && path == '/api/notes/n1') {
          if (rejectEdit) {
            return http.Response(
              jsonEncode({'error': '노트 작성자와 관리자만 수정할 수 있습니다.'}),
              403,
              headers: _json,
            );
          }
          return http.Response(
            jsonEncode(note(body: true)),
            200,
            headers: _json,
          );
        }
        if (request.method == 'DELETE' && path == '/api/notes/n1') {
          if (rejectDelete) {
            return http.Response(
              jsonEncode({'error': '노트 작성자와 관리자만 삭제할 수 있습니다.'}),
              403,
              headers: _json,
            );
          }
          return http.Response('{"ok":true}', 200, headers: _json);
        }
        return http.Response('{"ok":true}', 200, headers: _json);
      }),
    );
    return s;
  }();

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1300, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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
  }
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

void main() {
  testWidgets('수정·삭제 권한이 없으면: 목록 ✕ 없음, ⋯에는 노트 복제만, 이력은 보기만', (tester) async {
    final server = _Server(canEdit: false, canDelete: false);
    await server.pump(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('주간 회의록'), findsOneWidget);
    expect(find.byTooltip('삭제'), findsNothing);

    await tester.tap(find.text('주간 회의록'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('더보기'));
    await tester.pumpAndSettle();
    expect(find.text('노트 복제'), findsOneWidget);
    expect(find.text('수정'), findsNothing);
    expect(find.text('삭제'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('수정 이력'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Sam · 이전 제목'));
    await tester.pumpAndSettle();
    expect(find.text('예전 내용'), findsOneWidget);
    expect(find.text('이 버전으로 되돌리기'), findsNothing);

    await _finish(tester);
  });

  testWidgets('편집 중에 권한이 바뀌어 저장이 막히면: 서버 안내 + 편집기는 읽기 전용(쓰던 글은 남김)', (
    tester,
  ) async {
    final server = _Server();
    await server.pump(tester);
    await tester.tap(find.text('주간 회의록'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('더보기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('수정'));
    await tester.pumpAndSettle();

    Finder field(String hint) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == hint,
    );
    await tester.enterText(field('내용을 입력하세요'), '안건\n고친 내용');
    await tester.pump();

    // 그 사이 관리자가 '생성자와 관리자'로 바꿨다.
    server
      ..rejectEdit = true
      ..canEdit = false;
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pump();
    await tester.pump();
    expect(find.text('저장하지 못했습니다: 노트 작성자와 관리자만 수정할 수 있습니다.'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.textContaining('이 노트를 수정할 권한이 없습니다'), findsOneWidget);
    final body = tester.widget<TextField>(field('내용을 입력하세요'));
    expect(body.readOnly, isTrue);
    expect(body.controller!.text, '안건\n고친 내용');
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '저장'))
          .onPressed,
      isNull,
    );
    // 서식 도구모음 대신 안내가 보인다.
    expect(find.byTooltip('굵게 (Ctrl+B)'), findsNothing);

    // 편집을 그만두면 보기 화면도 새 권한대로 — '수정'·되돌리기가 다시 나오지 않는다.
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '버리기'));
    await tester.pumpAndSettle();
    expect(field('내용을 입력하세요'), findsNothing);
    await tester.tap(find.byTooltip('더보기'));
    await tester.pumpAndSettle();
    expect(find.text('노트 복제'), findsOneWidget);
    expect(find.text('수정'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('수정 이력'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Sam · 이전 제목'));
    await tester.pumpAndSettle();
    expect(find.text('이 버전으로 되돌리기'), findsNothing);

    await _finish(tester);
  });

  testWidgets('삭제가 막히면 서버 안내를 보여주고, 다시 읽은 권한대로 ✕·삭제 메뉴를 감춘다', (tester) async {
    final server = _Server();
    await server.pump(tester);
    await tester.tap(find.text('주간 회의록'));
    await tester.pumpAndSettle();

    server
      ..rejectDelete = true
      ..canDelete = false;
    await tester.tap(find.byTooltip('더보기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('삭제'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '삭제'));
    await tester.pump();
    await tester.pump();
    expect(find.text('삭제하지 못했습니다: 노트 작성자와 관리자만 삭제할 수 있습니다.'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(server.calls, contains('DELETE /api/notes/n1'));
    // 노트는 그대로 열려 있고, 이제 ⋯에 삭제가 없다.
    await tester.tap(find.byTooltip('더보기'));
    await tester.pumpAndSettle();
    expect(find.text('노트 복제'), findsOneWidget);
    expect(find.text('삭제'), findsNothing);

    await _finish(tester);
  });
}
