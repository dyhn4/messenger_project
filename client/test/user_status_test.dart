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
import 'package:client/screens/my_profile_dialog.dart';
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

  /// 방해 금지 창을 여는 버튼 화면.
  Future<void> pumpDndOpener(WidgetTester tester, Session session) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
  }

  Future<void> openDnd(WidgetTester tester) async {
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
  }

  Future<void> saveDnd(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('dnd-save')));
    await tester.pumpAndSettle();
    expect(find.text('방해 금지'), findsNothing, reason: '저장하면 창이 닫힌다');
    await tester.pump(const Duration(seconds: 3)); // 알림 토스트가 사라질 때까지
  }

  testWidgets(
    '방해 금지 창: 고르기만 해서는 바뀌지 않고 [저장]을 눌러야 적용된다 — 1시간 멈추기, 매일 일정(기본 평일 19:00~08:00, 이 기기 시간대)',
    (tester) async {
      final session = buildSession(_FakeNotifications());
      await pumpDndOpener(tester, session);
      await openDnd(tester);
      expect(find.text('지금은 알림을 받고 있습니다.'), findsOneWidget);

      // 고르기만 하면 아무것도 보내지 않고, 취소하면 그대로다.
      await tester.tap(find.byKey(const ValueKey('dnd-for-1시간')));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      expect(find.text('[저장]을 누르면 적용됩니다.'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      expect(session.myDnd?.until, isNull);

      await openDnd(tester);
      await tester.tap(find.byKey(const ValueKey('dnd-for-1시간')));
      await tester.pump();
      final before = DateTime.now();
      await saveDnd(tester);
      final first = jsonDecode(requests.last.body) as Map<String, dynamic>;
      expect(first.keys, ['until'], reason: '일정은 안 바꿨으니 보내지 않는다');
      final until = DateTime.fromMillisecondsSinceEpoch(first['until'] as int);
      expect(until.difference(before).inMinutes, inInclusiveRange(59, 60));

      await openDnd(tester);
      expect(find.textContaining('🌙 방해 금지 중'), findsOneWidget);
      expect(find.byKey(const ValueKey('dnd-resume')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('dnd-schedule-switch')));
      await tester.pump();
      await saveDnd(tester);
      final second = jsonDecode(requests.last.body) as Map<String, dynamic>;
      expect(second.keys, ['schedule']);
      expect(second['schedule'], {
        'enabled': true,
        'start': 19 * 60,
        'end': 8 * 60,
        'days': [1, 2, 3, 4, 5],
        'offsetMinutes': DateTime.now().timeZoneOffset.inMinutes,
      });
    },
  );

  testWidgets('방해 금지 창: "지정"을 누르면 할 일 기간과 같은 달력·시간 칸이 펼쳐지고, 고른 날짜·시각까지 멈춘다', (
    tester,
  ) async {
    final session = buildSession(_FakeNotifications());
    await pumpDndOpener(tester, session);
    await openDnd(tester);
    expect(find.text('지정'), findsOneWidget);
    expect(find.byKey(const ValueKey('dnd-custom-panel')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('dnd-custom')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dnd-custom-panel')), findsOneWidget);
    expect(find.text('언제까지 알림을 멈출까요?'), findsOneWidget);
    expect(find.text('종료 시간'), findsOneWidget);

    // 어제는 고를 수 없다(지난 날은 흐리고 눌리지 않는다).
    final now = DateTime.now();
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    if (yesterday.month == now.month) {
      final cell = tester.widget<InkWell>(
        find.byKey(
          ValueKey(
            'dnd-period-day-${yesterday.year}-${yesterday.month}-${yesterday.day}',
          ),
        ),
      );
      expect(cell.onTap, isNull);
    }

    // 내일(다음 달이면 › 로 넘겨서) → 시간 칸에서 오후 6:00.
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    if (tomorrow.month != now.month) {
      await tester.tap(find.byKey(const ValueKey('dnd-period-next')));
      await tester.pumpAndSettle();
    }
    await tester.tap(
      find.byKey(
        ValueKey(
          'dnd-period-day-${tomorrow.year}-${tomorrow.month}-${tomorrow.day}',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dnd-time-end')));
    await tester.pumpAndSettle();
    expect(find.text('시간 없음'), findsNothing, reason: '시각은 꼭 있어야 한다');
    final option = find.byKey(const ValueKey('dnd-time-option-1080'));
    final timeList = find.descendant(
      of: find.byKey(const ValueKey('dnd-time-list')),
      matching: find.byType(Scrollable),
    );
    // 목록은 지금 값 자리로 스크롤해 열린다 — 오후에 돌리면 6:00이 그보다 위일 수 있어 먼저 맨 위로 올린다.
    await tester.drag(timeList, const Offset(0, 10000));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(option, 72, scrollable: timeList);
    // 목록 안에 만들어졌어도 보이는 칸 밖일 수 있어 화면에 보이게 맞춘다.
    await tester.ensureVisible(option);
    await tester.pumpAndSettle();
    await tester.tap(option);
    await tester.pumpAndSettle();
    expect(requests, isEmpty, reason: '고르기만 해서는 보내지 않는다');

    final expected = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 18);
    expect(find.text(untilLabel(expected)), findsOneWidget, reason: '칩에 고른 시각');
    await saveDnd(tester);
    final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
    expect(body.keys, ['until']);
    expect(DateTime.fromMillisecondsSinceEpoch(body['until'] as int), expected);
  });

  testWidgets('방해 금지 창: 내용이 창보다 길면 스크롤바가 늘 보이고 창 오른쪽 끝에 붙는다', (tester) async {
    final session = buildSession(_FakeNotifications());
    await pumpDndOpener(tester, session);
    tester.view.physicalSize = const Size(900, 500); // 내용이 다 안 들어가는 낮은 창
    await tester.pump();
    await openDnd(tester);

    // 보이는 창(Dialog 안의 Material) — Dialog 위젯 자체는 화면 전체를 차지한다.
    final dialog = tester.getRect(
      find
          .descendant(of: find.byType(Dialog), matching: find.byType(Material))
          .first,
    );
    final bar = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(Scrollbar),
    );
    expect(bar, findsOneWidget);
    final scrollbar = tester.widget<Scrollbar>(bar);
    expect(scrollbar.thumbVisibility, isTrue);
    expect(tester.getRect(bar).right, dialog.right, reason: '창 오른쪽 끝에 붙는다');
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: bar, matching: find.byType(Scrollable)),
        )
        .position;
    expect(position.maxScrollExtent, greaterThan(0), reason: '스크롤할 내용이 있다');
    // 맨 아래(매일 일정 요일)까지 스크롤해서 볼 수 있다.
    await tester.drag(find.text('지금부터 알림 멈추기'), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(position.pixels, position.maxScrollExtent);
    expect(tester.takeException(), isNull);
  });

  testWidgets('상태 설정 창: [상태 지우기]는 비우기만 하고 [저장]을 눌러야 지워진다(취소하면 그대로)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = buildSession(_FakeNotifications());
    await session.setMyStatus(emoji: '🗓️', text: '회의 중', until: null);
    requests.clear();
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
    Future<void> open() async {
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
    }

    TextField field() => tester.widget<TextField>(find.byType(TextField));

    await open();
    expect(field().controller!.text, '회의 중');
    expect(find.byKey(const ValueKey('status-clear-hint')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('status-clear')));
    await tester.pump();
    expect(requests, isEmpty, reason: '누르기만 해서는 지우지 않는다');
    expect(field().controller!.text, isEmpty);
    expect(find.byKey(const ValueKey('status-clear-hint')), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('status-clear')))
          .onPressed,
      isNull,
      reason: '이미 비웠다',
    );
    expect(find.text('상태 설정'), findsOneWidget, reason: '창은 열린 채');

    // 취소하면 상태는 그대로다.
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(session.myStatus?.label, '🗓️ 회의 중');

    // 다시 열어 지우고 저장하면 지운다.
    await open();
    await tester.tap(find.byKey(const ValueKey('status-clear')));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
    expect(body['emoji'], isNull);
    expect(body['text'], isNull);
    expect(body['until'], isNull);
    expect(session.myStatus, isNull);
    expect(find.text('상태 설정'), findsNothing, reason: '저장하면 창이 닫힌다');
  });

  testWidgets('내 프로필 카드: 상태와 방해 금지 줄이 보이고, 누르면 그 창이 떠서 바꾸면 카드에 바로 보인다', (
    tester,
  ) async {
    final session = buildSession(_FakeNotifications());
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => MyProfileDialog(session: session),
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    final statusRow = find.byKey(const ValueKey('my-profile-status'));
    final dndRow = find.byKey(const ValueKey('my-profile-dnd'));
    expect(
      find.descendant(of: statusRow, matching: find.text('상태 설정')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dndRow, matching: find.text('방해 금지')),
      findsOneWidget,
    );

    // 상태 — 자주 쓰는 "회의 중"을 고르고 저장하면 카드에 이모지·글·지울 시각이 보인다.
    await tester.tap(statusRow);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('status-preset-회의 중')));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(find.text('상태 설정'), findsNothing, reason: '상태 창은 닫히고');
    expect(find.byType(MyProfileDialog), findsOneWidget, reason: '카드는 열린 채');
    expect(
      find.descendant(of: statusRow, matching: find.text('회의 중')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: statusRow, matching: find.text('🗓️')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: statusRow,
        matching: find.text(untilLabel(session.myStatus!.until!)),
      ),
      findsOneWidget,
    );

    // 방해 금지 — 1시간 멈추기를 저장하면 카드 줄이 "방해 금지 · …까지"로 바뀐다.
    await tester.tap(dndRow);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dnd-for-1시간')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dnd-save')));
    await tester.pumpAndSettle();
    expect(find.byType(MyProfileDialog), findsOneWidget);
    expect(
      find.descendant(
        of: dndRow,
        matching: find.text('방해 금지 · ${untilLabel(session.myDnd!.until!)}'),
      ),
      findsOneWidget,
    );
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
