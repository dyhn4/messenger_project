import 'dart:convert';

import 'package:client/screens/invite_link_screen.dart';
import 'package:client/screens/team_invite_link_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 초대 링크·팀 초대 링크 창 — 목록에서 링크를 누르면 목록 자리가 그 링크 내용(InviteLinkDetail)으로 바뀌고,
/// 사내·외부 주소를 따로 복사하고, "목록"으로 돌아온다.
void main() {
  const serverUrl = 'https://192.168.0.10:3000';
  const json = {'content-type': 'application/json'};
  const internal = 'http://192.168.0.10:3001/invite/tok-l1';
  const external = 'http://chat.example.org:3001/invite/tok-l1';
  final now = DateTime.now();

  Map<String, dynamic> linkJson({
    String id = 'l1',
    String? label = '9월 신입',
    bool revoked = false,
    String? url = internal,
    String? externalUrl = external,
  }) => {
    'id': id,
    'token': 'tok-$id',
    'label': label,
    'createdByName': '김관리',
    'createdAt': now.millisecondsSinceEpoch,
    'expiresAt': now.add(const Duration(days: 7)).millisecondsSinceEpoch,
    'revoked': revoked,
    'usedCount': 0,
    'maxUses': 5,
    'lastUsedAt': null,
    'valid': !revoked,
    'url': url,
    'externalUrl': externalUrl,
    // 팀 초대 링크에만 쓰는 칸 — 설치 초대 링크는 무시한다.
    'teamId': 't1',
    'teamName': '개발팀',
    'assignedRole': 'member',
    'assignedPosition': null,
  };

  late List<Map<String, dynamic>> listed;
  late List<String> clipboard;

  Session buildSession() {
    final client = MockClient((request) async {
      if (request.method == 'GET' &&
          (request.url.path == '/api/invite-links' ||
              request.url.path == '/api/team-invite-links')) {
        return http.Response(jsonEncode(listed), 200, headers: json);
      }
      return http.Response('[]', 200, headers: json);
    });
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    session.serverUrl = serverUrl;
    session.api = ApiClient(baseUrl: serverUrl, token: 't', httpClient: client);
    session.userId = 'u1';
    return session;
  }

  setUp(() {
    listed = [linkJson()];
    clipboard = [];
  });

  Future<void> pump(
    WidgetTester tester,
    Future<void> Function(BuildContext, Session) open,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final session = buildSession();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => open(context, session),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
  }

  Future<void> openRow(WidgetTester tester, String title) async {
    await tester.tap(find.widgetWithText(ListTile, title));
    await tester.pumpAndSettle();
  }

  testWidgets('링크를 누르면 내용이 보이고, 두 주소를 따로 복사하고, 목록으로 돌아온다', (tester) async {
    await pump(tester, showInviteLinkScreen);
    expect(find.byType(ListTile), findsOneWidget);

    await openRow(tester, '9월 신입');
    expect(find.byType(ListTile), findsNothing);
    expect(find.text('사내 와이파이에서'), findsOneWidget);
    expect(find.text('사내 와이파이 밖(LTE/5G)에서'), findsOneWidget);
    expect(find.text(internal), findsOneWidget);
    expect(find.text(external), findsOneWidget);
    // 위쪽 설명과 "초대 링크 만들기"는 그대로 있다 — 목록 자리만 바뀐다.
    expect(find.text('초대 링크 만들기'), findsOneWidget);

    await tester.tap(find.byTooltip('사내 와이파이 주소 복사'));
    await tester.pump();
    await tester.tap(find.byTooltip('외부 주소 복사'));
    await tester.pump();
    expect(clipboard, [internal, external]);

    await tester.tap(find.text('목록'));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsOneWidget);
    expect(find.text('사내 와이파이에서'), findsNothing);
    await tester.pump(const Duration(seconds: 3)); // 복사 알림(토스트)이 사라질 때까지.
  });

  testWidgets('외부 주소가 없으면 그 칸에 안내만 나오고 복사 버튼은 없다', (tester) async {
    listed = [linkJson(externalUrl: null)];
    await pump(tester, showInviteLinkScreen);
    await openRow(tester, '9월 신입');

    expect(find.byTooltip('사내 와이파이 주소 복사'), findsOneWidget);
    expect(find.byTooltip('외부 주소 복사'), findsNothing);
    expect(find.textContaining('외부 접속 주소가 설정되어 있지 않아'), findsOneWidget);
  });

  testWidgets('취소된 링크는 주소만 보여주고 복사 버튼은 두지 않는다', (tester) async {
    listed = [linkJson(revoked: true)];
    await pump(tester, showInviteLinkScreen);
    await openRow(tester, '9월 신입');

    expect(find.text(internal), findsOneWidget);
    expect(find.text(external), findsOneWidget);
    expect(find.byTooltip('사내 와이파이 주소 복사'), findsNothing);
    expect(find.byTooltip('외부 주소 복사'), findsNothing);
    expect(find.textContaining('더 이상 설치·연결할 수 없습니다'), findsOneWidget);
  });

  testWidgets('팀 초대 링크 창도 같은 방식으로 열고 돌아온다', (tester) async {
    listed = [linkJson(label: null)];
    await pump(
      tester,
      (context, session) => showTeamInviteLinkScreen(context, session),
    );
    // 메모가 없으면 "팀 · 등급"이 제목이다.
    await openRow(tester, '개발팀 · 정회원');

    expect(find.text(internal), findsOneWidget);
    expect(find.text(external), findsOneWidget);
    await tester.tap(find.byTooltip('외부 주소 복사'));
    await tester.pump();
    expect(clipboard, [external]);

    await tester.tap(find.text('목록'));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsOneWidget);
    await tester.pump(const Duration(seconds: 3)); // 복사 알림(토스트)이 사라질 때까지.
  });
}
