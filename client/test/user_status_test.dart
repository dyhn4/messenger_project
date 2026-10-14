import 'dart:convert';

import 'package:client/models/app_user.dart';
import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/models/user_status.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/team_members_panel.dart';
import 'package:client/widgets/user_status_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 상태 메시지와 방해 금지 — 서버(server/src/statusRules.js)와 같은 계산, 정하는 창, 방해 금지 중 앱 알림 멈춤, 남의 상태 표시.
class _FakeNotifications extends NotificationService {
  final shown = <String>[];

  @override
  Future<void> showMessage({
    required String title,
    required String body,
    required String roomId,
    String? senderName,
    String? conversationTitle,
    String avatarType = 'initial',
    String? avatarEmoji,
    String? avatarColor,
    String? avatarUrl,
    bool isSecret = false,
    bool flashTaskbarUntilRoomOpened = false,
    bool flashWindowFrame = true,
  }) async {
    shown.add(body);
  }

  @override
  Future<void> cancelForRoom(String roomId) async {}
}

const _kst = 9 * 60;

/// KST 그 날·시각.
DateTime _kstAt(int y, int mo, int d, int h, [int mi = 0]) =>
    DateTime.utc(y, mo, d, h, mi).subtract(const Duration(minutes: _kst));

void main() {
  group('방해 금지 계산(서버 isDndActive와 같음)', () {
    test('낮 일정 — 고른 요일의 시작 포함·끝 제외', () {
      const s = DndSchedule(
        enabled: true,
        start: 12 * 60,
        end: 13 * 60,
        days: [1, 2, 3, 4, 5],
        offsetMinutes: _kst,
      );
      expect(s.coversAt(_kstAt(2026, 10, 14, 12)), isTrue); // 수
      expect(s.coversAt(_kstAt(2026, 10, 14, 12, 59)), isTrue);
      expect(s.coversAt(_kstAt(2026, 10, 14, 13)), isFalse);
      expect(s.coversAt(_kstAt(2026, 10, 17, 12, 30)), isFalse); // 토
    });

    test('밤을 넘기는 일정은 시작한 요일 기준(금 19:00 ~ 토 08:00)', () {
      const s = DndSchedule(
        enabled: true,
        start: 19 * 60,
        end: 8 * 60,
        days: [5],
        offsetMinutes: _kst,
      );
      expect(s.coversAt(_kstAt(2026, 10, 16, 18, 59)), isFalse);
      expect(s.coversAt(_kstAt(2026, 10, 16, 19)), isTrue);
      expect(s.coversAt(_kstAt(2026, 10, 17, 0)), isTrue);
      expect(s.coversAt(_kstAt(2026, 10, 17, 7, 59)), isTrue);
      expect(s.coversAt(_kstAt(2026, 10, 17, 8)), isFalse);
      expect(s.coversAt(_kstAt(2026, 10, 17, 19, 30)), isFalse);
      expect(s.coversAt(_kstAt(2026, 10, 16, 3)), isFalse);
    });

    test('시간대는 정한 기기 기준, 꺼진 일정은 아무 때도 아니다', () {
      final at = DateTime.utc(2026, 10, 14, 11); // KST 20:00, UTC+1 12:00
      const evening = (start: 19 * 60, end: 8 * 60);
      DndSchedule s(int offset, {bool enabled = true}) => DndSchedule(
        enabled: enabled,
        start: evening.start,
        end: evening.end,
        days: const [0, 1, 2, 3, 4, 5, 6],
        offsetMinutes: offset,
      );
      expect(s(_kst).coversAt(at), isTrue);
      expect(s(60).coversAt(at), isFalse);
      expect(s(_kst, enabled: false).coversAt(at), isFalse);
    });

    test('"이 시각까지"와 서버 모양 읽기', () {
      final now = DateTime(2026, 10, 14, 12);
      final dnd = DndState.fromJson({
        'until': now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
        'schedule': null,
      })!;
      expect(dnd.isActiveAt(now), isTrue);
      expect(dnd.isActiveAt(now.add(const Duration(hours: 2))), isFalse);
      expect(DndState.fromJson(null), isNull);
      expect(DndState.fromJson({'until': null, 'schedule': null}), isNull);
    });
  });

  test('상태: 서버 모양 읽기·지울 시각·지우는 시점 계산', () {
    final now = DateTime(2026, 10, 14, 10, 30); // 수요일
    final s = UserStatus.fromJson({
      'emoji': '🗓️',
      'text': '회의 중',
      'until': now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
    })!;
    expect(s.label, '🗓️ 회의 중');
    expect(s.isLiveAt(now), isTrue);
    expect(s.isLiveAt(now.add(const Duration(hours: 2))), isFalse);
    expect(UserStatus.fromJson({'emoji': null, 'text': ''}), isNull);

    expect(StatusClearAfter.never.untilFrom(now), isNull);
    expect(
      StatusClearAfter.hour1.untilFrom(now),
      DateTime(2026, 10, 14, 11, 30),
    );
    expect(StatusClearAfter.today.untilFrom(now), DateTime(2026, 10, 15));
    expect(
      StatusClearAfter.thisWeek.untilFrom(now),
      DateTime(2026, 10, 19),
      reason: '이번 주 = 다음 월요일 0시까지',
    );
    expect(
      StatusClearAfter.thisWeek.untilFrom(DateTime(2026, 10, 19, 9)),
      DateTime(2026, 10, 26),
      reason: '월요일이면 다음 주 월요일 0시',
    );
    expect(dndLabel(null), isNull);
  });

  late List<http.Request> requests;

  Map<String, dynamic> selfJson({Object? status, Object? dnd}) => {
    'id': 'u1',
    'username': 'riley',
    'name': 'Riley',
    'status': status,
    'dnd': dnd,
  };

  Session buildSession(_FakeNotifications notifications) {
    final session = Session(
      notifications: notifications,
      settings: AppSettings(),
    );
    session.serverUrl = 'https://192.168.0.10:3000';
    session.api = ApiClient(
      baseUrl: 'https://192.168.0.10:3000',
      token: 't',
      httpClient: MockClient((request) async {
        requests.add(request);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final json = request.url.path == '/api/users/me/status'
            ? selfJson(
                status: body['emoji'] == null && body['text'] == null
                    ? null
                    : body,
              )
            : selfJson(
                dnd: {'until': body['until'], 'schedule': body['schedule']},
              );
        return http.Response(
          jsonEncode(json),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    session.userId = 'u1';
    session.name = 'Riley';
    session.rooms.add(
      Room(
        id: 'r1',
        teamId: 't1',
        type: RoomType.topic,
        name: '마케팅 팀',
        members: [
          AppUser(id: 'u1', username: 'riley', name: 'Riley'),
          AppUser(id: 'u2', username: 'sam', name: 'Sam'),
        ],
        createdAt: DateTime(2026),
        lastRead: const {},
      ),
    );
    return session;
  }

  setUp(() => requests = []);

  Message incoming(String id) => Message(
    id: id,
    roomId: 'r1',
    senderId: 'u2',
    senderName: 'Sam',
    type: MessageType.text,
    text: '확인 부탁드려요 $id',
    createdAt: DateTime.now(),
  );

  test('방해 금지 중에는 앱 알림을 띄우지 않고(안 읽은 수는 쌓인다), 끄면 다시 띄운다', () async {
    final notifications = _FakeNotifications();
    final session = buildSession(notifications);
    final room = session.rooms.single;

    await session.handleSocketMessage(incoming('m1'));
    expect(notifications.shown, hasLength(1));

    await session.setMyDnd(
      setUntil: true,
      until: DateTime.now().add(const Duration(hours: 1)),
    );
    expect(jsonDecode(requests.last.body), contains('until'));
    expect(session.notificationsPaused, isTrue);
    await session.handleSocketMessage(incoming('m2'));
    expect(notifications.shown, hasLength(1), reason: '방해 금지 중 — 알림 없음');
    expect(room.unreadCount, 2, reason: '안 읽은 수는 그대로 쌓인다');

    await session.setMyDnd(setUntil: true, until: null);
    expect(session.notificationsPaused, isFalse);
    await session.handleSocketMessage(incoming('m3'));
    expect(notifications.shown, hasLength(2));
  });

  testWidgets('상태 설정 창: 자주 쓰는 상태를 고르고 저장하면 이모지·글·지울 시각을 보낸다', (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = buildSession(_FakeNotifications());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showStatusDialog(context, session),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('status-preset-회의 중')));
    await tester.pump();
    final before = DateTime.now();
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();

    final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
    expect(body['emoji'], '🗓️');
    expect(body['text'], '회의 중');
    final until = DateTime.fromMillisecondsSinceEpoch(body['until'] as int);
    expect(
      until.difference(before).inMinutes,
      inInclusiveRange(59, 60),
      reason: '회의 중은 1시간 뒤 지움',
    );
    expect(session.myStatus?.label, '🗓️ 회의 중');
    expect(find.text('상태 설정'), findsNothing, reason: '저장하면 창이 닫힌다');
  });

  testWidgets('방해 금지 창: 1시간 멈추기, 매일 일정 저장(기본 평일 19:00~08:00, 이 기기 시간대)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = buildSession(_FakeNotifications());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDndDialog(context, session),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(find.text('지금은 알림을 받고 있습니다.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('dnd-for-1시간')));
    await tester.pumpAndSettle();
    final first = jsonDecode(requests.last.body) as Map<String, dynamic>;
    expect(first.keys, ['until']);
    expect(
      find.textContaining('🌙 방해 금지 중'),
      findsOneWidget,
      reason: '창이 바로 바뀐 상태를 보인다',
    );
    expect(find.byKey(const ValueKey('dnd-resume')), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));

    await tester.tap(find.byKey(const ValueKey('dnd-schedule-switch')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dnd-save-schedule')));
    await tester.pumpAndSettle();
    final second = jsonDecode(requests.last.body) as Map<String, dynamic>;
    expect(second.keys, ['schedule']);
    expect(second['schedule'], {
      'enabled': true,
      'start': 19 * 60,
      'end': 8 * 60,
      'days': [1, 2, 3, 4, 5],
      'offsetMinutes': DateTime.now().timeZoneOffset.inMinutes,
    });
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('팀원 목록: 남의 상태 이모지·글과 방해 금지 달이 보인다', (tester) async {
    final session = buildSession(_FakeNotifications());
    // 연결할 때 회원 목록으로 채우는 것과 같은 값을 넣는다(user:status로 오는 것과 같은 모양).
    final sam = AppUser.fromJson({
      'id': 'u2',
      'username': 'sam',
      'name': 'Sam',
      'status': {'emoji': '🚗', 'text': '외근 중', 'until': null},
      'dnd': {
        'until': DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
        'schedule': null,
      },
    });
    session.debugApplyUserStatus(sam.id, sam.status, sam.dnd);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TeamMemberRow(
            session: session,
            user: sam,
            resolveUrl: (u) => u,
            online: false,
            onTap: () {},
          ),
        ),
      ),
    );
    expect(find.text('🚗 🌙'), findsOneWidget);
    expect(find.text('외근 중'), findsOneWidget);
    expect(session.isInDnd('u2'), isTrue);
    expect(session.statusOf('u2')?.label, '🚗 외근 중');
  });
}
