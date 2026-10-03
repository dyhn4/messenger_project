import 'dart:convert';

import 'package:client/models/room.dart';
import 'package:client/models/shared_link.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/links_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/app_menu_button.dart';
import 'package:client/widgets/filter_dropdown.dart';
import 'package:client/widgets/room_options_menu.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _json = {'content-type': 'application/json; charset=utf-8'};

void main() {
  late List<Uri> requests;

  Session session() {
    requests = [];
    final client = MockClient((request) async {
      requests.add(request.url);
      if (request.url.path == '/api/links') {
        return http.Response(
          jsonEncode([
            {
              'id': 'm1:https://example.com/doc',
              'messageId': 'm1',
              'roomId': 'r1',
              'senderId': 'u1',
              'senderName': '송병근',
              'createdAt': DateTime(2026, 9, 29, 14).millisecondsSinceEpoch,
              'url': 'https://example.com/doc',
              'title': '예시 문서',
              'imageUrl': null,
              'siteName': 'Example',
            },
            {
              'id': 'm2:https://www.youtube.com/watch?v=1',
              'messageId': 'm2',
              'roomId': 'r1',
              'senderId': 'u2',
              'senderName': '김철수',
              'createdAt': DateTime(2026, 9, 29, 13).millisecondsSinceEpoch,
              'url': 'https://www.youtube.com/watch?v=1',
              'title': null,
              'imageUrl': null,
              'siteName': null,
            },
          ]),
          200,
          headers: _json,
        );
      }
      return http.Response('[]', 200, headers: _json);
    });
    final s = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    s.serverUrl = 'https://test.local';
    s.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: client,
    );
    s.userId = 'me';
    s.currentTeam = Team(id: 't1', name: '팀', createdAt: DateTime(2026));
    s.rooms.add(
      Room(
        id: 'r1',
        teamId: 't1',
        type: RoomType.topic,
        name: '잔디톡 팀',
        members: const [],
        createdAt: DateTime(2026),
        lastRead: const {},
      ),
    );
    return s;
  }

  test('제목이 없으면 도메인(www. 뗀 것)을 보여준다', () {
    final link = SharedLink(
      id: 'x',
      messageId: 'm',
      roomId: 'r',
      senderName: 'a',
      createdAt: DateTime(2026),
      url: 'https://www.youtube.com/watch?v=1',
    );
    expect(link.displayTitle, 'youtube.com');
  });

  testWidgets('링크 패널: 보고 있던 방으로 걸러 불러오고, 대화방에서 보기·링크 복사가 된다', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
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

    (Room, String)? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LinksScreen(
            session: session(),
            initialRoomId: 'r1',
            onOpenMessage: (room, messageId) => opened = (room, messageId),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // 보고 있던 방으로 걸러서 부른다.
    final linksCall = requests.firstWhere((u) => u.path == '/api/links');
    expect(linksCall.queryParameters['roomId'], 'r1');
    expect(linksCall.queryParameters['teamId'], 't1');

    // 대화방 이름 · 제목(없으면 도메인) · 주소 — 보낸 사람과 시각은 안 보인다.
    expect(find.text('예시 문서'), findsOneWidget);
    expect(find.text('youtube.com'), findsOneWidget);
    expect(find.text('https://example.com/doc'), findsOneWidget);
    expect(find.text('잔디톡 팀'), findsNWidgets(3)); // 필터 버튼 + 두 줄
    expect(find.textContaining('송병근'), findsNothing);

    // 제목을 누르면 링크를 여는 게 아니라 "대화방에서 보기".
    await tester.tap(find.text('예시 문서'));
    await tester.pump();
    expect(opened?.$2, 'm1');
    opened = null;

    // 마우스를 올리면 대화방에서 보기 · 링크 복사.
    expect(find.byTooltip('대화방에서 보기'), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('예시 문서')));
    await tester.pump();
    expect(find.byTooltip('대화방에서 보기'), findsOneWidget);
    expect(find.byTooltip('링크 복사'), findsOneWidget);

    await tester.tap(find.byTooltip('링크 복사'));
    await tester.pump();
    expect(copied, 'https://example.com/doc');
    expect(find.text('링크를 복사했습니다.'), findsOneWidget);

    await tester.tap(find.byTooltip('대화방에서 보기'));
    await tester.pump();
    expect(opened?.$1.id, 'r1');
    expect(opened?.$2, 'm1');

    // 모바일처럼 길게 누르면 같은 두 가지가 아래에서 올라온다.
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    await tester.longPress(find.text('youtube.com'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '대화방에서 보기'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, '대화방에서 보기'));
    await tester.pumpAndSettle();
    expect(opened?.$2, 'm2');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('"메뉴"에 링크 항목이 있고, 홈 화면 밖(모바일)에서는 전체 화면으로 열린다', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: [AppMenuButton(session: session())]),
        ),
      ),
    );
    await tester.tap(find.byTooltip('메뉴'));
    await tester.pumpAndSettle();
    expect(find.text('파일'), findsOneWidget);
    expect(find.text('링크'), findsOneWidget);
    expect(find.text('문의함'), findsOneWidget);
    await tester.tap(find.text('링크'));
    await tester.pumpAndSettle();
    expect(find.byType(LinksScreen), findsOneWidget);
    // 패널이 자기 머리글(제목 + 닫기)을 그린다 — 닫으면 메뉴가 있던 화면으로 돌아온다.
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();
    expect(find.byType(LinksScreen), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('참여 대화방 필터: 토픽 · 그룹채팅 · 채팅 탭, 골라 둔 방의 탭부터 보인다', (tester) async {
    final s = session();
    s.rooms.addAll([
      Room(
        id: 'g1',
        teamId: 't1',
        type: RoomType.group,
        name: '디자인 그룹',
        members: const [],
        createdAt: DateTime(2026),
        lastRead: const {},
      ),
      Room(
        id: 'd1',
        teamId: 't1',
        type: RoomType.dm,
        name: '김철수',
        members: const [],
        createdAt: DateTime(2026),
        lastRead: const {},
      ),
    ]);
    String? picked = 'g1';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => RoomFilterButton(
              session: s,
              selectedRoomId: picked,
              onSelected: (id) => setState(() => picked = id),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('디자인 그룹'));
    await tester.pumpAndSettle();
    for (final tab in ['토픽', '그룹채팅', '채팅']) {
      expect(find.text(tab), findsOneWidget, reason: tab);
    }
    // 골라 둔 방이 그룹채팅이라 그 탭부터 — 그룹채팅방만 보인다.
    expect(find.text('디자인 그룹'), findsNWidgets(2)); // 버튼 + 목록
    expect(find.text('잔디톡 팀'), findsNothing);
    expect(find.text('김철수'), findsNothing);

    await tester.tap(find.text('채팅'));
    await tester.pumpAndSettle();
    expect(find.text('김철수'), findsOneWidget);
    expect(find.text('잔디톡 팀'), findsNothing);

    await tester.tap(find.text('토픽'));
    await tester.pumpAndSettle();
    expect(find.text('잔디톡 팀'), findsOneWidget);
    await tester.tap(find.text('잔디톡 팀'));
    await tester.pumpAndSettle();
    expect(picked, 'r1');
  });

  testWidgets('채팅방 헤더: 멤버 · 알림 · 멤버 초대는 더보기 왼쪽에, 더보기에는 파일 보기 · 링크 보기', (
    tester,
  ) async {
    final s = session();
    final room = s.rooms.first;
    Room? filesFor, linksFor;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [
              RoomOptionsMenu(
                session: s,
                room: room,
                onOpenFiles: (r) => filesFor = r,
                onOpenLinks: (r) => linksFor = r,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byTooltip('멤버'), findsOneWidget);
    expect(find.byTooltip('알림 끄기'), findsOneWidget);

    await tester.tap(find.byTooltip('더보기'));
    await tester.pumpAndSettle();
    expect(find.text('파일 보기'), findsOneWidget);
    expect(find.text('링크 보기'), findsOneWidget);
    // 꺼낸 것들은 메뉴에 다시 나오지 않는다.
    expect(find.textContaining('멤버 ('), findsNothing);
    expect(find.text('알림 끄기'), findsNothing);

    await tester.tap(find.text('링크 보기'));
    await tester.pumpAndSettle();
    expect(linksFor?.id, 'r1');

    await tester.tap(find.byTooltip('더보기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('파일 보기'));
    await tester.pumpAndSettle();
    expect(filesFor?.id, 'r1');
  });
}
