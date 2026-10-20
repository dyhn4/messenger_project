// 다른 앱에서 공유하기와 홈 화면 위젯(앱 쪽) — 공유받은 것 읽기(제목+글·파일), 안드로이드 채널(앱이 켜지기 전·켜진 뒤), 공유 화면에서
// 방을 골라 보내기(대기열로), 위젯 내용(알림 끈 방·비밀 대화·앱 잠금·로그아웃)과 바뀔 때만 넘기기.
import 'dart:convert';

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/share_target_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/home_widget_bridge.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/services/share_intake.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

Room _room(
  String id, {
  String? name,
  int unread = 0,
  bool muted = false,
  bool secret = false,
  int hour = 10,
  String type = 'group',
}) => Room.fromJson({
  'id': id,
  'teamId': 't1',
  'type': type,
  'name': name,
  'members': [
    {'id': 'me', 'username': 'me', 'name': '나'},
    {'id': 'u2', 'username': 'kim', 'name': '김철수'},
  ],
  'createdAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
  'lastActivityAt': DateTime(2026, 10, 18, hour).millisecondsSinceEpoch,
  'unreadCount': unread,
  'muted': muted,
  'isSecret': secret,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('공유받은 것', () {
    test('제목은 글 앞에(글에 이미 있으면 빼고), 파일은 경로·이름·형식, 아무것도 없으면 null', () {
      final p = SharedPayload.fromChannel({
        'text': 'https://news.example/a',
        'subject': '오늘의 기사',
        'files': [
          {
            'path': '/c/shared/1_a.jpg',
            'name': 'a.jpg',
            'mimeType': 'image/jpeg',
            'size': 2048,
          },
          {
            'path': '/c/shared/2_b.pdf',
            'name': 'b.pdf',
            'mimeType': 'application/pdf',
          },
          {'name': '경로 없음'},
        ],
      })!;
      expect(p.text, '오늘의 기사\nhttps://news.example/a');
      expect(p.files.map((f) => f.name), ['a.jpg', 'b.pdf']);
      expect(p.files.first.isImage, isTrue);
      expect(p.files.last.isImage, isFalse);
      expect(
        SharedPayload.fromChannel({'text': '제목 포함 본문', 'subject': '제목'})!.text,
        '제목 포함 본문',
      );
      expect(SharedPayload.fromChannel({'text': '  ', 'files': []}), isNull);
      expect(SharedPayload.fromChannel('nope'), isNull);
    });

    test('채널 — 앱이 켜지기 전에 온 것은 takeInitial로, 켜진 뒤 온 것은 바로', () async {
      const channel = MethodChannel('test/share');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'takeInitial');
        return {
          'share': {'text': '켜기 전에 공유'},
          'openRoomId': 'R-widget',
        };
      });
      final shares = <SharedPayload>[];
      final rooms = <String>[];
      await ShareIntake(
        channel: channel,
        enabled: true,
      ).start(onShare: shares.add, onOpenRoom: rooms.add);
      expect(shares.single.text, '켜기 전에 공유');
      expect(rooms, ['R-widget']);
      // 켜져 있을 때 안드로이드가 보낸 것.
      const codec = StandardMethodCodec();
      await messenger.handlePlatformMessage(
        'test/share',
        codec.encodeMethodCall(
          const MethodCall('shareReceived', {
            'text': null,
            'files': [
              {'path': '/c/x.png', 'name': 'x.png', 'mimeType': 'image/png'},
            ],
          }),
        ),
        (_) {},
      );
      await messenger.handlePlatformMessage(
        'test/share',
        codec.encodeMethodCall(const MethodCall('openRoom', 'R2')),
        (_) {},
      );
      expect(shares.last.files.single.name, 'x.png');
      expect(rooms.last, 'R2');
      messenger.setMockMethodCallHandler(channel, null);
    });

    test('안드로이드가 아니면 아무것도 하지 않음', () async {
      var called = false;
      const channel = MethodChannel('test/share-off');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            called = true;
            return null;
          });
      await ShareIntake(
        channel: channel,
        enabled: false,
        windows: false,
      ).start(onShare: (_) {}, onOpenRoom: (_) {});
      expect(called, isFalse);
    });
  });

  testWidgets('공유 화면 — 방을 고르기 전엔 못 보내고, 고치면 고친 글이 대기열로', (tester) async {
    final session = Session(
      notifications: _QuietNotifications(),
      settings: AppSettings(),
    );
    session.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: MockClient(
        (_) async => http.Response.bytes(
          utf8.encode('[]'),
          200,
          headers: const {'content-type': 'application/json'},
        ),
      ),
    );
    session.userId = 'me';
    session.accountRole = AccountRole.member;
    final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
    session.teams.add(team);
    session.currentTeam = team;
    session.rooms.addAll([
      _room('g1', name: '영업 1팀'),
      _room('s1', name: '비밀', secret: true, type: 'dm'),
    ]);
    List<Room>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showShareTargetScreen(
              context,
              session: session,
              payload: const SharedPayload(text: 'https://news.example/a'),
            ),
            child: const Text('열기'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('share-send')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('대화방 선택'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('그룹채팅'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('영업 1팀').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('share-room-g1')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('share-text')),
      '이 기사 보세요 https://news.example/a',
    );
    await tester.tap(find.byKey(const ValueKey('share-send')));
    await tester.pumpAndSettle();
    expect(result?.map((r) => r.id), ['g1']);
    final queued = session.outbox.forRoom('g1').single;
    expect(queued.payload['type'], 'text');
    expect(queued.payload['text'], '이 기사 보세요 https://news.example/a');
  });

  group('홈 화면 위젯', () {
    test('안 읽은 방 — 알림 끈 방은 빼고 최근 활동순 세 개, 비밀 대화는 이름을 숨김', () {
      final state = homeWidgetState(
        signedIn: true,
        locked: false,
        myUserId: 'me',
        rooms: [
          _room('a', name: '영업', unread: 2, hour: 9),
          _room('b', name: '조용한 방', unread: 50, muted: true, hour: 12),
          _room('c', name: '개발', unread: 1, hour: 11),
          _room(
            'd',
            name: '비밀방',
            unread: 3,
            secret: true,
            hour: 10,
            type: 'dm',
          ),
          _room('e', name: '인사', unread: 4, hour: 8),
          _room('f', name: '다 읽음', hour: 13),
        ],
      );
      expect(state['total'], 10);
      expect((state['rooms'] as List).map((r) => (r as Map)['id']), [
        'c',
        'd',
        'a',
      ]);
      expect(((state['rooms'] as List)[1] as Map)['name'], '비밀 대화');
    });

    test('앱 잠금이면 합계만, 로그아웃이면 안내만', () {
      final locked = homeWidgetState(
        signedIn: true,
        locked: true,
        myUserId: 'me',
        rooms: [_room('a', name: '영업', unread: 2)],
      );
      expect(locked['total'], 2);
      expect(locked['rooms'], isEmpty);
      expect(locked['locked'], isTrue);
      expect(
        homeWidgetState(
          signedIn: false,
          locked: false,
          myUserId: '',
          rooms: [_room('a', unread: 2)],
        )['loggedOut'],
        isTrue,
      );
    });

    test('바뀔 때만 안드로이드로 넘긴다', () async {
      const channel = MethodChannel('test/widget');
      final pushed = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            pushed.add((call.arguments as Map)['json'] as String);
            return null;
          });
      final session = Session(
        notifications: _QuietNotifications(),
        settings: AppSettings(),
      );
      final bridge = HomeWidgetBridge(session, channel: channel, enabled: true);
      await bridge.push();
      await bridge.push();
      expect(pushed.length, 1);
      expect(jsonDecode(pushed.single)['loggedOut'], isTrue);
    });
  });
}
