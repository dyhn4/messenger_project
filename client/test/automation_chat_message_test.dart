import 'package:client/models/app_user.dart';
import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/avatar_utils.dart';
import 'package:client/widgets/message_bubble.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 실제 OS 알림 대신, 무엇을 띄우려 했는지만 모은다.
class _FakeNotifications extends NotificationService {
  final shown = <Map<String, Object?>>[];

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
  }) async {
    shown.add({
      'title': title,
      'body': body,
      'roomId': roomId,
      'avatarType': avatarType,
      'avatarEmoji': avatarEmoji,
      'avatarColor': avatarColor,
    });
  }

  @override
  Future<void> cancelForRoom(String roomId) async {}
}

AppUser _user(String id, String name) =>
    AppUser(id: id, username: id, name: name);

Room _room() => Room(
  id: 'r1',
  teamId: 't1',
  type: RoomType.topic,
  name: '마케팅 팀',
  members: [_user('u1', 'Riley'), _user('u2', 'Sam')],
  createdAt: DateTime(2026),
  lastRead: {},
);

/// 서버(projectAutomation.js)가 보내는 모양 그대로 — 보낸 사람 없는 일반 글 메시지.
Message _botMessage({String id = 'm1', DateTime? at}) => Message.fromJson({
  'id': id,
  'roomId': 'r1',
  'senderId': null,
  'senderName': '자동화',
  'type': 'text',
  'text': '[긴급 업무 알림] MKT-1001 배너 제작\n확인 부탁드립니다.',
  'createdAt': (at ?? DateTime.now()).millisecondsSinceEpoch,
});

Message _userMessage(String senderId, String name, {String id = 'm2'}) =>
    Message(
      id: id,
      roomId: 'r1',
      senderId: senderId,
      senderName: name,
      type: MessageType.text,
      text: '안녕하세요',
      createdAt: DateTime.now(),
    );

void main() {
  test('자동화 메시지 판별 · 같은 사람 묶기는 senderId가 null이면 이름까지 본다', () {
    final bot = _botMessage();
    expect(bot.isAutomation, isTrue);
    expect(bot.senderId, isNull);

    // 예전 방식(회색 시스템 줄)과 탈퇴한 사람의 메시지는 자동화 메시지가 아니다.
    final system = Message(
      id: 's1',
      roomId: 'r1',
      senderName: '자동화',
      type: MessageType.system,
      text: '[자동화 · 규칙] 알림',
      createdAt: DateTime.now(),
    );
    final departed = Message(
      id: 'd1',
      roomId: 'r1',
      senderName: '떠난 사람',
      type: MessageType.text,
      text: '예전 글',
      createdAt: DateTime.now(),
    );
    expect(system.isAutomation, isFalse);
    expect(departed.isAutomation, isFalse);

    // 자동화 메시지끼리는 한 묶음, 탈퇴한 사람(역시 senderId null)과는 다른 사람이다.
    expect(bot.sameSenderAs(_botMessage(id: 'm9')), isTrue);
    expect(bot.sameSenderAs(departed), isFalse);
    expect(bot.sameSenderAs(_userMessage('u2', 'Sam')), isFalse);
    expect(
      _userMessage('u2', 'Sam').sameSenderAs(_userMessage('u2', 'Sam')),
      isTrue,
    );
  });

  test('소켓으로 온 자동화 메시지: 안읽음 +1 · 방 목록 미리보기 · 번개 아바타 알림', () async {
    final notifications = _FakeNotifications();
    final session = Session(
      notifications: notifications,
      settings: AppSettings(),
    );
    session.userId = 'u1';
    final room = _room();
    session.rooms.add(room);

    // 서버 시각은 밀리초 단위라 그 단위로 맞춰 둔다.
    final at = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().add(const Duration(minutes: 1)).millisecondsSinceEpoch,
    );
    await session.handleSocketMessage(_botMessage(at: at));

    expect(room.unreadCount, 1);
    expect(room.lastMessagePreview, '[긴급 업무 알림] MKT-1001 배너 제작\n확인 부탁드립니다.');
    expect(room.lastActivityAt, at);
    expect(notifications.shown, hasLength(1));
    final shown = notifications.shown.single;
    expect(shown['title'], '자동화 [마케팅 팀]');
    expect(shown['body'], '[긴급 업무 알림] MKT-1001 배너 제작\n확인 부탁드립니다.');
    expect(shown['roomId'], 'r1');
    expect(shown['avatarType'], 'character');
    expect(shown['avatarEmoji'], '⚡');
    expect(shown['avatarColor'], colorToHex(automationAvatarColor));

    // 내가 보낸 메시지는 안읽음·알림이 없고, 남이 보낸 건 평소처럼 쌓인다.
    await session.handleSocketMessage(_userMessage('u1', 'Riley', id: 'm3'));
    expect(room.unreadCount, 1);
    expect(notifications.shown, hasLength(1));
    await session.handleSocketMessage(_userMessage('u2', 'Sam', id: 'm4'));
    expect(room.unreadCount, 2);
    expect(notifications.shown.last['avatarType'], 'initial');

    // 로그인 정보가 비어 있어도(userId null) 보낸 사람 없는 메시지를 "내 것"으로 보지 않는다.
    session.userId = null;
    await session.handleSocketMessage(_botMessage(id: 'm5'));
    expect(room.unreadCount, 3);

    // 그 방을 보고 있으면 안읽음·알림 없이 넘어간다.
    session.userId = 'u1';
    session.setActiveRoom('r1');
    await session.handleSocketMessage(_botMessage(id: 'm6'));
    expect(room.unreadCount, 3);
    expect(notifications.shown, hasLength(3));
  });

  testWidgets('자동화 말풍선: 번개 아바타·이름, 내 메시지 색 아님, 수정·삭제 메뉴 없음', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final session = Session(
      notifications: _FakeNotifications(),
      settings: AppSettings(),
    );
    session.rooms.add(_room());
    final message = _botMessage();

    Future<void> pump(Message m, {required bool isMine}) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageBubble(
              key: ValueKey(m.id),
              session: session,
              message: m,
              resolveUrl: (u) => u,
              // 호출부가 senderId == userId로 비교하다 둘 다 null이면 true가 올 수 있다.
              isMine: isMine,
              onOpenThread: (_) {},
              onEdit: (_, _, {format}) async {},
              onDelete: (_) async {},
            ),
          ),
        ),
      ),
    );

    await pump(message, isMine: true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('automation-avatar')), findsOneWidget);
    expect(find.byType(AvatarView), findsNothing);
    expect(find.text('자동화'), findsOneWidget);
    expect(find.textContaining('MKT-1001 배너 제작'), findsOneWidget);

    // 남의 메시지 색(내 메시지 색이 아님).
    final bubble = tester.widget<AnimatedContainer>(
      find.ancestor(
        of: find.textContaining('MKT-1001 배너 제작'),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final context = tester.element(find.byType(MessageBubble));
    expect(
      (bubble.decoration! as BoxDecoration).color,
      Theme.of(context).colorScheme.surfaceContainerHighest,
    );

    // 이름·아바타를 눌러도 프로필 창이 뜨지 않는다.
    await tester.tap(find.byKey(const ValueKey('automation-avatar')));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    /// 말풍선([body] 글자)에 마우스를 올려 툴바의 "더보기" 메뉴를 열고 항목 이름을 모은다.
    Future<List<String>> menuLabels(String body) async {
      await mouse.moveTo(tester.getCenter(find.textContaining(body).first));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      final labels = [
        for (final t in tester.widgetList<Text>(
          find.descendant(
            of: find.byType(MenuItemButton),
            matching: find.byType(Text),
          ),
        ))
          t.data ?? '',
      ];
      await mouse.moveTo(Offset.zero);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      return labels;
    }

    // 자동화 메시지는 누구도 수정·삭제할 수 없다(관리자 삭제는 팀 관리자일 때만 따로 뜬다).
    final botMenu = await menuLabels('MKT-1001');
    expect(botMenu, contains('복사'));
    expect(botMenu, isNot(contains('수정')));
    expect(botMenu, isNot(contains('삭제')));

    // 비교: 내 일반 메시지는 수정·삭제가 뜬다.
    await pump(_userMessage('u1', 'Riley'), isMine: true);
    await tester.pumpAndSettle();
    final mineMenu = await menuLabels('안녕하세요');
    expect(mineMenu, containsAll(['수정', '삭제']));
    expect(find.byKey(const ValueKey('automation-avatar')), findsNothing);
  });
}
