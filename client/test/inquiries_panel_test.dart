// 문의함 패널(메뉴 "리스트"의 문의함) — 받은 문의·보낸 문의 탭, 처리 상태 칩, 카드, 상세에서 상태 바꾸기, 팀장에게 문의하기.
// 서버는 요청을 기록하는 가짜 HTTP 클라이언트로 대신한다.
import 'dart:convert';

import 'package:client/models/team.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/attachment_widgets.dart' show DownloadableFile;
import 'package:client/widgets/inquiries_panel.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

late List<http.Request> _requests;

Map<String, dynamic> _inquiry(
  String id, {
  String status = 'open',
  String title = '연차 사용 문의',
  String senderName = '이팀원',
  String recipientName = '김팀장',
  int daysAgo = 1,
}) => {
  'id': id,
  'teamId': 't1',
  'roomId': 'dm-$id',
  'senderId': 'u-$id',
  'senderName': senderName,
  'recipientId': 'boss',
  'recipientName': recipientName,
  'category': '근태/휴가',
  'title': title,
  'content': '다음 주 금요일에 연차를 써도 될까요?',
  'status': status,
  'createdAt': DateTime.now()
      .subtract(Duration(days: daysAgo))
      .millisecondsSinceEpoch,
};

Session _session({bool withLeader = true, bool withFile = false}) {
  _requests = [];
  final client = MockClient((request) async {
    _requests.add(request);
    final path = request.url.path;
    http.Response ok(Object? body) =>
        http.Response(jsonEncode(body), 200, headers: _jsonHeaders);
    switch ((request.method, path)) {
      case ('GET', '/api/inquiries/received'):
        return ok([
          {
            ..._inquiry('r1', title: '연차 사용 문의'),
            if (withFile) ...{
              'fileUrl': 'https://test.local/files/r1',
              'fileName': '근거자료.pdf',
            },
          },
          _inquiry('r2', status: 'resolved', title: '모니터 교체 요청', daysAgo: 3),
        ]);
      case ('GET', '/api/inquiries/sent'):
        return ok([_inquiry('s1', title: '출장비 정산 문의', senderName: '나')]);
      case ('GET', '/api/teams/t1/members'):
        return ok([
          {'id': 'me', 'username': 'me', 'name': '나'},
          {
            'id': 'boss',
            'username': 'boss',
            'name': '김팀장',
            'position': withLeader ? '팀장' : '대리',
          },
        ]);
      case ('PATCH', '/api/inquiries/r1'):
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return ok(_inquiry('r1', status: body['status'] as String));
      case ('POST', '/api/rooms/dm'):
        return ok({
          'id': 'dm-boss',
          'teamId': 't1',
          'type': 'dm',
          'members': [
            {'id': 'me', 'username': 'me', 'name': '나'},
            {'id': 'boss', 'username': 'boss', 'name': '김팀장', 'position': '팀장'},
          ],
          'createdAt': 0,
        });
    }
    return http.Response('{}', 404, headers: _jsonHeaders);
  });
  final session = Session(
    notifications: NotificationService(),
    settings: AppSettings(),
  );
  session.serverUrl = 'https://test.local';
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: client,
  );
  session.userId = 'me';
  final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  return session;
}

Future<void> _pump(WidgetTester tester, Session session) async {
  tester.view.physicalSize = const Size(600, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: InquiriesPanel(session: session)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('받은 문의: 대기 수가 탭에 붙고, 처리 상태 칩으로 거르며, 보낸 문의 탭에는 받는 사람이 보인다', (
    tester,
  ) async {
    await _pump(tester, _session());
    expect(find.text('문의함'), findsOneWidget);
    expect(find.text('받은 문의 1'), findsOneWidget, reason: '아직 대기 중인 수');
    expect(find.textContaining('2개의 문의', findRichText: true), findsOneWidget);
    final r1 = find.byKey(const ValueKey('inquiry-r1'));
    final r2 = find.byKey(const ValueKey('inquiry-r2'));
    expect(r1, findsOneWidget);
    expect(r2, findsOneWidget);
    expect(
      find.descendant(of: r1, matching: find.text('보낸 사람 이팀원')),
      findsOneWidget,
    );
    expect(find.descendant(of: r1, matching: find.text('대기')), findsOneWidget);
    expect(
      find.descendant(of: r1, matching: find.text('근태/휴가')),
      findsOneWidget,
    );

    // 처리 상태 칩 — 개수와 함께, 고르면 그 상태만.
    expect(find.text('전체 2'), findsOneWidget);
    expect(find.text('완료 1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('inquiry-filter-resolved')));
    await tester.pumpAndSettle();
    expect(r1, findsNothing);
    expect(r2, findsOneWidget);

    // 보낸 문의 — 필터는 풀리고 받는 사람이 보인다.
    await tester.tap(find.byKey(const ValueKey('inquiry-box-sent')));
    await tester.pumpAndSettle();
    final s1 = find.byKey(const ValueKey('inquiry-s1'));
    expect(s1, findsOneWidget);
    expect(
      find.descendant(of: s1, matching: find.text('받는 사람 김팀장')),
      findsOneWidget,
    );
    expect(find.text('전체 1'), findsOneWidget);
  });

  testWidgets('받은 문의 상세에서 처리 상태를 바꾸면 서버에 보내고 카드에도 바로 보인다', (tester) async {
    await _pump(tester, _session());
    await tester.tap(find.byKey(const ValueKey('inquiry-r1')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('다음 주 금요일에 연차를 써도 될까요?'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('inquiry-open-room')), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('inquiry-detail-status-in_progress')),
    );
    await tester.pumpAndSettle();
    final patch = _requests.lastWhere((r) => r.method == 'PATCH');
    expect(patch.url.path, '/api/inquiries/r1');
    expect(jsonDecode(patch.body), {'status': 'in_progress'});
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('inquiry-r1')),
        matching: find.text('처리중'),
      ),
      findsOneWidget,
    );
    expect(find.text('받은 문의'), findsOneWidget, reason: '대기가 없어져 숫자가 빠진다');
  });

  testWidgets('팀장이 있으면 "팀장에게 문의하기"로 그 사람과의 1:1 대화방을 열고 작성 창을 띄운다', (
    tester,
  ) async {
    await _pump(tester, _session());
    await tester.tap(find.byKey(const ValueKey('inquiry-create')));
    await tester.pumpAndSettle();
    final dm = _requests.lastWhere((r) => r.url.path == '/api/rooms/dm');
    expect(jsonDecode(dm.body), containsPair('targetUserId', 'boss'));
    expect(find.text('팀장에게 문의하기'), findsWidgets);
    expect(find.byKey(const ValueKey('inquiry-compose-title')), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(
      _requests.where((r) => r.url.path.startsWith('/api/rooms/dm-boss')),
      isEmpty,
    );
  });

  testWidgets('상세의 첨부 파일 — 마우스를 올리면 다운로드 단추가 카드와 겹치지 않고 카드 바깥 오른쪽에 붙어 뜬다', (
    tester,
  ) async {
    await _pump(tester, _session(withFile: true));
    await tester.tap(find.byKey(const ValueKey('inquiry-r1')));
    await tester.pumpAndSettle();
    final name = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('근거자료.pdf'),
    );
    expect(name, findsOneWidget);
    final file = find.ancestor(
      of: name,
      matching: find.byType(DownloadableFile),
    );
    final card = tester.getRect(
      find.descendant(of: file, matching: find.byType(Container)).first,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(name));
    await tester.pump();
    final button = find.descendant(of: file, matching: find.byTooltip('다운로드'));
    expect(button, findsOneWidget);
    final rect = tester.getRect(button);
    expect(rect.left, greaterThanOrEqualTo(card.right), reason: '카드와 겹치지 않는다');
    expect(rect.left - card.right, lessThan(10), reason: '카드 바로 오른쪽');
  });

  testWidgets('지금 팀에 팀장이 없으면 문의하기 단추가 없다', (tester) async {
    await _pump(tester, _session(withLeader: false));
    expect(find.byKey(const ValueKey('inquiry-create')), findsNothing);
  });
}
