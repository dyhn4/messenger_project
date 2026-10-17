import 'dart:async';
import 'dart:convert';

import 'package:client/screens/wiki/wiki_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/services/wiki_doc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 팀 위키 화면(wiki_screen.dart) — 나무, 페이지 열기(동시 편집 문서에 들어감), 편집하면 연산을 보내고, 다른 사람 연산이 오면 입력칸이
/// 따라 바뀐다(서버 wiki.js — 소켓은 가짜 통로).

const _json = {'content-type': 'application/json'};

class _FakeTransport implements WikiTransport {
  final requests =
      <
        ({
          String event,
          Map<String, dynamic> payload,
          void Function(Map<String, dynamic>) onAck,
        })
      >[];
  final emitted = <({String event, Map<String, dynamic> payload})>[];
  final _events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final _reconnected = StreamController<void>.broadcast(sync: true);

  @override
  void request(
    String event,
    Map<String, dynamic> payload,
    void Function(Map<String, dynamic>) onAck,
  ) => requests.add((event: event, payload: payload, onAck: onAck));

  @override
  void emit(String event, Map<String, dynamic> payload) =>
      emitted.add((event: event, payload: payload));

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Stream<void> get reconnected => _reconnected.stream;

  void send(Map<String, dynamic> event) => _events.add(event);

  /// 아직 답하지 않은 마지막 [event] 요청.
  ({
    String event,
    Map<String, dynamic> payload,
    void Function(Map<String, dynamic>) onAck,
  })
  last(String event) => requests.lastWhere((r) => r.event == event);
}

void main() {
  final now = DateTime(2026, 10, 7, 9).millisecondsSinceEpoch;
  late List<({String method, String path, Object? body})> calls;

  http.Response ok(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: _json);

  Session session() {
    calls = [];
    final s = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    s.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: MockClient((request) async {
        final body = request.body.isEmpty ? null : jsonDecode(request.body);
        if (request.method != 'GET') {
          calls.add((
            method: request.method,
            path: request.url.path,
            body: body,
          ));
        }
        switch ((request.method, request.url.path)) {
          case ('GET', '/api/wiki'):
            return ok({
              'pages': [
                {'id': 'p1', 'title': '온보딩', 'depth': 0, 'updatedAt': now},
                {
                  'id': 'p2',
                  'parentId': 'p1',
                  'title': '장비 신청',
                  'depth': 1,
                  'updatedAt': now,
                },
              ],
              'canEdit': true,
              'isManager': false,
            });
          case ('GET', '/api/wiki/p1'):
            return ok({
              'id': 'p1',
              'title': '온보딩',
              'body': '# 환영합니다',
              'revision': 0,
              'path': <Object>[],
              'canEdit': true,
              'canRemove': true,
              'updatedByName': '김가',
              'updatedAt': now,
            });
          case ('POST', '/api/wiki'):
            return ok({'id': 'p3', 'title': '새 글', 'depth': 0}, 201);
        }
        return ok(<Object>[]);
      }),
    );
    s.userId = 'me';
    return s;
  }

  Future<_FakeTransport> pump(
    WidgetTester tester, {
    Size size = const Size(1200, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final t = _FakeTransport();
    await tester.pumpWidget(
      MaterialApp(
        home: WikiScreen(
          session: session(),
          teamId: 't1',
          teamName: '영업팀',
          transport: t,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return t;
  }

  Future<void> openP1(WidgetTester tester, _FakeTransport t) async {
    await tester.tap(find.byKey(const ValueKey('wiki-row-p1')));
    await tester.pumpAndSettle();
    final join = t.last('wiki:join');
    expect(join.payload, {'pageId': 'p1'});
    join.onAck({
      'ok': true,
      'revision': 4,
      'title': '온보딩',
      'canEdit': true,
      'body': '# 환영합니다',
      'editors': [
        {'userId': 'me', 'name': '나', 'color': '#1971C2'},
        {'userId': 'u2', 'name': '이나', 'color': '#E8590C'},
      ],
    });
    await tester.pumpAndSettle();
  }

  testWidgets('나무를 보고, 페이지를 열면 동시 편집 문서에 들어가 함께 보는 사람이 보인다', (tester) async {
    final t = await pump(tester);
    expect(find.text('위키 · 영업팀'), findsOneWidget);
    expect(find.text('장비 신청'), findsOneWidget);
    await openP1(tester, t);
    expect(find.byKey(const ValueKey('wiki-title')), findsOneWidget);
    expect(find.text('환영합니다'), findsOneWidget, reason: '마크다운 제목으로 그린다');
    expect(find.byKey(const ValueKey('wiki-presence')), findsOneWidget);
    expect(find.text('이나'), findsOneWidget);
    // 다른 사람 커서가 오면 몇 번째 줄인지.
    t.send({
      'type': 'cursor',
      'pageId': 'p1',
      'userId': 'u2',
      'name': '이나',
      'color': '#E8590C',
      'revision': 4,
      'anchor': 0,
      'head': 0,
    });
    await tester.pumpAndSettle();
    expect(find.text('이나 · 1행'), findsOneWidget);
    // 보기 화면에도 다른 사람의 변경이 바로 보인다.
    t.send({
      'type': 'op',
      'pageId': 'p1',
      'revision': 5,
      'op': [7, '\n\n- 계정 만들기'],
      'userId': 'u2',
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('계정 만들기'), findsOneWidget);
  });

  testWidgets('편집 — 바꾼 만큼 연산을 보내고, 다른 사람 연산이 오면 입력칸과 커서가 따라 옮겨진다', (
    tester,
  ) async {
    final t = await pump(tester);
    await openP1(tester, t);
    await tester.tap(find.byKey(const ValueKey('wiki-edit')));
    await tester.pumpAndSettle();
    final editor = find.byKey(const ValueKey('wiki-editor'));
    expect(tester.widget<TextField>(editor).controller!.text, '# 환영합니다');
    await tester.enterText(editor, '# 환영합니다!');
    await tester.pump();
    final op = t.last('wiki:op');
    expect(op.payload['revision'], 4);
    expect(op.payload['op'], [7, '!']);
    expect(find.byKey(const ValueKey('wiki-saving')), findsOneWidget);
    op.onAck({'ok': true, 'revision': 5});
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('wiki-saving')), findsNothing);
    // 다른 사람이 맨 앞에 넣었다 — 내 커서(맨 끝)는 그만큼 뒤로.
    final controller = tester.widget<TextField>(editor).controller!;
    controller.selection = const TextSelection.collapsed(offset: 8);
    await tester.pump();
    t.send({
      'type': 'op',
      'pageId': 'p1',
      'revision': 6,
      'op': ['> ', 8],
      'userId': 'u2',
    });
    await tester.pumpAndSettle();
    expect(controller.text, '> # 환영합니다!');
    expect(controller.selection.baseOffset, 10);
    // 그 변경은 내 연산으로 다시 보내지 않는다.
    expect(t.requests.where((r) => r.event == 'wiki:op').length, 1);
  });

  testWidgets('다른 사람이 지우면 페이지가 닫히고, 새 페이지를 만든다', (tester) async {
    final t = await pump(tester);
    await openP1(tester, t);
    t.send({'type': 'removed', 'pageId': 'p1'});
    await tester.pumpAndSettle();
    expect(find.text('왼쪽에서 페이지를 고르세요.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.byKey(const ValueKey('wiki-new-page')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('wiki-text-input')),
      '새 글',
    );
    await tester.tap(find.byKey(const ValueKey('wiki-text-ok')));
    await tester.pumpAndSettle();
    expect(calls.single.body, {'teamId': 't1', 'title': '새 글'});
  });

  testWidgets('좁은 화면 — 나무에서 고르면 페이지만, ← 로 나무로', (tester) async {
    final t = await pump(tester, size: const Size(400, 800));
    await openP1(tester, t);
    expect(find.text('장비 신청'), findsNothing);
    await tester.tap(find.byTooltip('페이지 목록'));
    await tester.pumpAndSettle();
    expect(find.text('장비 신청'), findsOneWidget);
    // 페이지를 떠나면 나간다고 알린다.
    expect(t.emitted.any((e) => e.event == 'wiki:leave'), isTrue);
  });
}
