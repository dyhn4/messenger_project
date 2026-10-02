import 'package:client/models/app_user.dart';
import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/chat_font_scope.dart';
import 'package:client/widgets/message_bubble.dart';
import 'package:client/widgets/rich_text_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 환경설정 > 화면 설정 > 글꼴은 허용 목록(방 이름, 메시지 본문, 댓글 본문)에만 입힌다 —
/// chat_font_scope.dart의 도우미와, 실제 말풍선에서 본문만 바뀌고 이름·시간은 그대로인지.
void main() {
  group('도우미', () {
    test('시스템 기본(빈 문자열)이면 글꼴 스타일이 없고, 원래 style을 그대로 돌려준다', () {
      final settings = AppSettings();
      expect(chatFontStyle(settings), isNull);
      const base = TextStyle(fontSize: 13, color: Colors.red);
      expect(applyChatFont(base, chatFontStyle(settings)), same(base));
      expect(applyChatFont(null, null), isNull);
    });

    test('글꼴을 고르면 글꼴만 바뀌고 색·크기·굵기는 그대로', () {
      final settings = AppSettings()..fontFamily = '맑은 고딕';
      const base = TextStyle(
        fontSize: 13,
        color: Colors.red,
        fontWeight: FontWeight.bold,
        fontFamily: 'Roboto', // Theme.textTheme 스타일엔 이게 이미 박혀 있다
      );
      final out = applyChatFont(base, chatFontStyle(settings))!;
      expect(out.fontFamily, '맑은 고딕');
      expect(out.fontFamilyFallback, contains(oldHangulFontFamily));
      expect(out.fontSize, 13);
      expect(out.color, Colors.red);
      expect(out.fontWeight, FontWeight.bold);
    });

    testWidgets('ChatFont는 저장하면(설정이 바뀌면) 바로 다시 그린다', (tester) async {
      final settings = AppSettings();
      await tester.pumpWidget(
        MaterialApp(
          home: ChatFont(
            settings: settings,
            builder: (context, font) =>
                Text('방 이름', style: applyChatFont(null, font)),
          ),
        ),
      );
      expect(tester.widget<Text>(find.text('방 이름')).style, isNull);
      settings.fontFamily = '맑은 고딕';
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      settings.notifyListeners();
      await tester.pump();
      expect(tester.widget<Text>(find.text('방 이름')).style?.fontFamily, '맑은 고딕');
    });
  });

  testWidgets('말풍선: 메시지 본문만 고른 글꼴, 보낸 사람 이름은 기본 글꼴 그대로', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings()..fontFamily = '맑은 고딕',
    );
    session.userId = 'u1';
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
        lastRead: {},
      ),
    );
    final message = Message(
      id: 'm1',
      roomId: 'r1',
      senderId: 'u2',
      senderName: 'Sam',
      type: MessageType.text,
      text: '안녕하세요 반갑습니다',
      createdAt: DateTime.now(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageBubble(
              session: session,
              message: message,
              resolveUrl: (u) => u,
              isMine: false,
              onOpenThread: (_) {},
              onEdit: (_, _, {format, mentions}) async {},
              onDelete: (_) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 본문은 고른 글꼴.
    expect(
      tester
          .widget<FormattedText>(find.byType(FormattedText))
          .style
          ?.fontFamily,
      '맑은 고딕',
    );
    // 보낸 사람 이름은 기본 그대로(이 글자의 style에도, 둘러싼 기본 글자 스타일에도 고른
    // 글꼴이 없다).
    final name = find.text('Sam');
    expect(name, findsOneWidget);
    expect(tester.widget<Text>(name).style?.fontFamily, isNot('맑은 고딕'));
    expect(
      DefaultTextStyle.of(tester.element(name)).style.fontFamily,
      isNot('맑은 고딕'),
    );
  });
}
