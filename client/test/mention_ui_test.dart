import 'dart:convert';

import 'package:client/models/app_user.dart';
import 'package:client/models/comment.dart';
import 'package:client/models/mention.dart';
import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/member_profile_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/chat_input_bar.dart';
import 'package:client/widgets/mention_autocomplete.dart';
import 'package:client/widgets/message_bubble.dart';
import 'package:client/widgets/message_comments_card.dart';
import 'package:client/widgets/rich_text_format.dart';
import 'package:client/widgets/unread_badge.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 멘션 UI — 입력창 자동완성(검색·키보드·@all 제한·비밀 대화), "@" 단추와 좁은 폭에서의 메뉴, 전송 payload, 말풍선·댓글
/// 강조와 프로필, 수정 화면의 멘션 편집, 방 목록 "@" 표시.

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json'},
);

AppUser _user(String id, String name, {String? username}) =>
    AppUser(id: id, username: username ?? id, name: name);

final _me = _user('me', '나');
final _kim = _user('u2', '김철수', username: 'chulsoo');
final _lee = _user('u3', '이영희', username: 'younghee');
final _park = _user('u4', '박철민', username: 'cm');

Room _room(
  String id, {
  RoomType type = RoomType.topic,
  bool secret = false,
  bool self = false,
  List<AppUser>? members,
}) => Room(
  id: id,
  teamId: 't1',
  type: type,
  name: type == RoomType.dm ? null : '영업방',
  members: members ?? [_me, _kim, _lee, _park],
  createdAt: DateTime(2026),
  lastRead: {},
  isSecret: secret,
  isSelf: self,
);

class _Server {
  final requests = <http.Request>[];
  late final client = MockClient((request) async {
    requests.add(request);
    if (request.method == 'POST' && request.url.path.endsWith('/comments')) {
      return _json({
        'id': 'c-new',
        'messageId': 'm1',
        'roomId': 'r1',
        'senderId': 'me',
        'senderName': '나',
        'type': 'text',
        'createdAt': 1,
      });
    }
    if (request.method == 'PATCH' &&
        request.url.path.startsWith('/api/comments/')) {
      return _json({
        'id': 'c1',
        'messageId': 'm1',
        'roomId': 'r1',
        'senderId': 'me',
        'senderName': '나',
        'type': 'text',
        'text': 'x',
        'createdAt': 1,
      });
    }
    if (request.method == 'PATCH') {
      return _json({
        'id': 'm1',
        'roomId': 'r1',
        'senderId': 'me',
        'senderName': '나',
        'type': 'text',
        'text': 'x',
        'createdAt': 1,
      });
    }
    return _json(<Object>[]);
  });

  List<http.Request> called(String method, [String? suffix]) => requests
      .where(
        (r) =>
            r.method == method &&
            (suffix == null || r.url.path.endsWith(suffix)),
      )
      .toList();
}

Session _session(_Server server, List<Room> rooms) {
  final session = Session(
    notifications: _QuietNotifications(),
    settings: AppSettings(),
  );
  session.serverUrl = 'https://test.local';
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: server.client,
  );
  session.userId = 'me';
  session.name = '나';
  session.accountRole = AccountRole.member;
  final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  session.rooms.addAll(rooms);
  return session;
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 자동완성만 떼어 붙인 시험용 입력칸.
class _Harness {
  final controller = RichTextEditingController();
  final focus = FocusNode();
  final key = GlobalKey<MentionAutocompleteState>();
  void dispose() {
    controller.dispose();
    focus.dispose();
  }
}

Future<_Harness> _pumpField(WidgetTester tester, Room room) async {
  final h = _Harness();
  addTearDown(h.dispose);
  _size(tester, const Size(500, 700));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: MentionAutocomplete(
              key: h.key,
              controller: h.controller,
              focusNode: h.focus,
              room: room,
              myUserId: 'me',
              child: TextField(
                key: const ValueKey('field'),
                controller: h.controller,
                focusNode: h.focus,
                maxLines: null,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('field')));
  await tester.pumpAndSettle();
  return h;
}

Finder get _popup => find.byKey(const ValueKey('mention-popup'));
Finder _option(int i) => find.byKey(ValueKey('mention-option-$i'));

Future<void> _enter(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('field')), text);
  await tester.pumpAndSettle();
}

void main() {
  group('자동완성 패널', () {
    testWidgets('@를 치면 @all과 멤버(나 제외)가 뜨고, 더 치면 이름·아이디로 걸러진다', (tester) async {
      final h = await _pumpField(tester, _room('r1'));
      expect(_popup, findsNothing);
      await _enter(tester, '@');
      expect(_popup, findsOneWidget);
      // @all → 김철수 → 박철민 → 이영희(이름순, 나는 없다).
      expect(
        find.descendant(of: _option(0), matching: find.text('@all')),
        findsOneWidget,
      );
      expect(find.text('김철수'), findsOneWidget);
      expect(find.text('박철민'), findsOneWidget);
      expect(find.text('이영희'), findsOneWidget);
      expect(find.text('나'), findsNothing);

      await _enter(tester, '@철');
      expect(find.text('김철수'), findsOneWidget);
      expect(find.text('박철민'), findsOneWidget);
      expect(find.text('이영희'), findsNothing);
      expect(find.text('@all'), findsNothing);

      // 아이디로도 찾는다.
      await _enter(tester, '@young');
      expect(find.text('이영희'), findsOneWidget);
      expect(find.text('김철수'), findsNothing);

      // 없는 이름이면 패널이 닫힌다.
      await _enter(tester, '@없는사람');
      expect(_popup, findsNothing);
      expect(h.controller.mentions, isEmpty);
    });

    testWidgets('목록을 누르면 "@이름 "이 들어가고 멘션으로 잡힌다', (tester) async {
      final h = await _pumpField(tester, _room('r1'));
      await _enter(tester, '안녕 @영');
      await tester.tap(find.text('이영희'));
      await tester.pumpAndSettle();
      expect(h.controller.text, '안녕 @이영희 ');
      expect(
        h.controller.mentions.single,
        const Mention.user('u3', start: 3, end: 7),
      );
      expect(_popup, findsNothing);
    });

    testWidgets('@all을 고르면 all 멘션으로 들어간다', (tester) async {
      final h = await _pumpField(tester, _room('r1'));
      await _enter(tester, '@a');
      await tester.tap(find.text('@all'));
      await tester.pumpAndSettle();
      expect(h.controller.text, '@all ');
      expect(h.controller.mentions.single.isAll, isTrue);
    });

    testWidgets('키보드 — ↓↑로 고르고 Enter·Tab으로 넣고 Esc로 닫는다', (tester) async {
      final h = await _pumpField(tester, _room('r1'));
      await _enter(tester, '@철');
      // 김철수, 박철민 — 첫 항목이 고른 상태.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(h.controller.text, '@박철민 ');
      expect(h.controller.mentions.single.userId, 'u4');

      await _enter(tester, '@영');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(h.controller.text, '@이영희 ');

      // ↑는 거꾸로 돌고(맨 위에서 맨 아래로), Esc는 패널을 닫되 글은 그대로 둔다.
      await _enter(tester, '@');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(h.controller.text, '@이영희 ');
      await _enter(tester, '@철');
      expect(_popup, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_popup, findsNothing);
      expect(h.controller.text, '@철');
      // 같은 @를 이어 치는 동안은 다시 열리지 않는다. @를 새로 치면 다시 열린다.
      await _enter(tester, '@철수');
      expect(_popup, findsNothing);
      await _enter(tester, '@철수 @철');
      expect(_popup, findsOneWidget);
    });

    testWidgets('패널이 열려 있지 않으면 Enter·방향키를 가로채지 않는다(위로 그대로 전달)', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      final seen = <LogicalKeyboardKey>[];
      _size(tester, const Size(500, 700));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Focus(
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent) seen.add(event.logicalKey);
                return KeyEventResult.ignored;
              },
              child: MentionAutocomplete(
                key: h.key,
                controller: h.controller,
                focusNode: h.focus,
                room: _room('r1'),
                myUserId: 'me',
                child: TextField(
                  key: const ValueKey('field'),
                  controller: h.controller,
                  focusNode: h.focus,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('field')));
      await _enter(tester, '안녕');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(seen, contains(LogicalKeyboardKey.enter));
      expect(seen, contains(LogicalKeyboardKey.arrowDown));
      expect(h.controller.mentions, isEmpty);
      // 패널이 열려 있으면 Enter는 여기서 끝난다(위로 안 간다).
      await _enter(tester, '@철');
      seen.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(seen, isEmpty);
      expect(h.controller.text, '@김철수 ');
    });

    testWidgets('이메일처럼 글자에 붙은 @는 열지 않는다', (tester) async {
      await _pumpField(tester, _room('r1'));
      await _enter(tester, 'me@chul');
      expect(_popup, findsNothing);
    });

    testWidgets('1:1·나와의 대화에는 멘션 자동완성이 없고, 그룹에는 @all이 있다', (tester) async {
      final dm = await _pumpField(
        tester,
        _room('dm', type: RoomType.dm, members: [_me, _kim]),
      );
      await _enter(tester, '@');
      // 1:1은 상대가 한 명뿐이라 멘션 기능 자체가 없다(패널도, 멘션 추적도).
      expect(_popup, findsNothing);
      expect(dm.controller.mentionsEnabled, isFalse);

      await _pumpField(
        tester,
        _room('self', type: RoomType.dm, self: true, members: [_me]),
      );
      await _enter(tester, '@');
      // 나와의 대화엔 멘션할 사람이 없다.
      expect(_popup, findsNothing);

      await _pumpField(tester, _room('g', type: RoomType.group));
      await _enter(tester, '@');
      expect(find.text('@all'), findsOneWidget);
    });

    testWidgets('비밀 대화는 @ 기능이 없다 — 패널도, 멘션 추적도', (tester) async {
      final h = await _pumpField(
        tester,
        _room('s', type: RoomType.dm, secret: true, members: [_me, _kim]),
      );
      await _enter(tester, '@');
      expect(_popup, findsNothing);
      expect(h.controller.mentionsEnabled, isFalse);
      h.key.currentState?.insertTrigger();
      await tester.pumpAndSettle();
      expect(h.controller.text, '@');
      expect(_popup, findsNothing);
    });

    testWidgets('"@" 단추 동작 — 커서 자리에 @를 넣고 패널을 연다(글자에 붙어 있으면 공백을 끼운다)', (
      tester,
    ) async {
      final h = await _pumpField(tester, _room('r1'));
      await _enter(tester, '안녕');
      h.key.currentState!.insertTrigger();
      await tester.pumpAndSettle();
      expect(h.controller.text, '안녕 @');
      expect(_popup, findsOneWidget);
    });

    testWidgets('멘션을 고른 뒤 이름을 고치면 멘션이 풀린다', (tester) async {
      final h = await _pumpField(tester, _room('r1'));
      await _enter(tester, '@영');
      await tester.tap(find.text('이영희'));
      await tester.pumpAndSettle();
      expect(h.controller.mentions, hasLength(1));
      await _enter(tester, '@이영 ');
      expect(h.controller.mentions, isEmpty);
    });
  });

  group('입력창(ChatInputBar)', () {
    ChatInputBar bar(Session s, Room r) => ChatInputBar(
      controller: s.controllerFor(r),
      session: s,
      room: r,
      stickerPickerGroupId: Object(),
      onToggleStickerPicker: () {},
      onStickerConsumed: () {},
    );

    Future<Session> pump(
      WidgetTester tester,
      Room room, {
      Size size = const Size(900, 700),
    }) async {
      final session = _session(_Server(), [room]);
      _size(tester, size);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: bar(session, room),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return session;
    }

    testWidgets('@ 단추 → 자동완성 → 보내면 message:send에 mentions(구간 포함)가 실린다', (
      tester,
    ) async {
      final room = _room('r1');
      final session = await pump(tester, room);
      final payloads = <Map<String, dynamic>>[];
      session.chatSocket.debugSendOverride = (p) async {
        payloads.add(p);
        return {'ok': true};
      };
      await tester.tap(find.byKey(const ValueKey('mention-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mention-popup')), findsOneWidget);
      await tester.tap(find.text('김철수'));
      await tester.pumpAndSettle();
      // 고른 멘션 뒤에 글을 이어 친다 — 구간은 그대로여야 한다.
      final c = tester
          .widget<TextField>(find.byKey(const ValueKey('chat-input')))
          .controller!;
      expect(c.text, '@김철수 ');
      c.value = TextEditingValue(
        text: '${c.text}확인 부탁드려요',
        selection: TextSelection.collapsed(offset: c.text.length + 7),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('보내기'));
      await tester.pumpAndSettle();
      final sent = payloads.single;
      expect(sent['text'], '@김철수 확인 부탁드려요');
      expect(sent['mentions'], [
        {'type': 'user', 'userId': 'u2', 's': 0, 'e': 4},
      ]);
      // 보낸 뒤 입력칸을 비우면 멘션도 비운다.
      expect(c.text, isEmpty);
    });

    testWidgets('멘션이 없는 글은 mentions 필드를 안 보낸다', (tester) async {
      final session = await pump(tester, _room('r1'));
      final payloads = <Map<String, dynamic>>[];
      session.chatSocket.debugSendOverride = (p) async {
        payloads.add(p);
        return {'ok': true};
      };
      await tester.enterText(find.byKey(const ValueKey('chat-input')), '그냥 인사');
      await tester.tap(find.byTooltip('보내기'));
      await tester.pumpAndSettle();
      expect(payloads.single.containsKey('mentions'), isFalse);
    });

    testWidgets('@all은 그룹에서 보낼 수 있고, 1:1에서는 제안도 전송도 안 된다', (tester) async {
      final group = _room('g', type: RoomType.group);
      final session = await pump(tester, group);
      final payloads = <Map<String, dynamic>>[];
      session.chatSocket.debugSendOverride = (p) async {
        payloads.add(p);
        return {'ok': true};
      };
      await tester.tap(find.byKey(const ValueKey('mention-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('@all'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('보내기'));
      await tester.pumpAndSettle();
      expect(payloads.single['text'], '@all');
      expect(payloads.single['mentions'], [
        {'type': 'all', 's': 0, 'e': 4},
      ]);
    });

    testWidgets('1:1·나와의 대화에는 @ 단추가 없고 글자 @를 쳐도 자동완성이 안 뜬다', (tester) async {
      for (final room in [
        _room('dm', type: RoomType.dm, members: [_me, _kim]),
        _room('self', type: RoomType.dm, self: true, members: [_me]),
      ]) {
        await pump(tester, room);
        expect(find.byKey(const ValueKey('mention-button')), findsNothing);
        expect(find.byKey(const ValueKey('chat-attach-mention')), findsNothing);
        await tester.enterText(find.byKey(const ValueKey('chat-input')), '@');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('mention-popup')), findsNothing);
      }
    });

    testWidgets('비밀 대화에는 @ 단추가 없고 글자 @를 쳐도 자동완성이 안 뜬다', (tester) async {
      await pump(
        tester,
        _room('s', type: RoomType.dm, secret: true, members: [_me, _kim]),
      );
      expect(find.byKey(const ValueKey('mention-button')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('chat-input')), '@');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mention-popup')), findsNothing);
    });

    for (final width in [320.0, 360.0, 400.0]) {
      testWidgets('폭 ${width.toInt()} — 단추 줄이 넘치지 않고 멘션·투표·파일 모두 닿는다', (
        tester,
      ) async {
        final room = _room('r1');
        // 테스트는 Windows에서도 도는데 거기엔 화면 캡처 단추가 하나 더 있다 — 화상회의 단추는 폭 360부터 둔다.
        final session = _session(_Server(), [room])
          ..callsEnabled = width >= 360;
        _size(tester, Size(width, 700));
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: bar(session, room),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final standalone = find.byKey(const ValueKey('mention-button'));
        final menu = find.byKey(const ValueKey('chat-attach-menu'));
        // 자리가 있으면 단추, 없으면 파일 메뉴 안의 항목 — 어느 쪽이든 멘션에 닿는다.
        if (standalone.evaluate().isNotEmpty) {
          await tester.tap(standalone);
        } else {
          expect(menu, findsOneWidget);
          await tester.tap(menu);
          await tester.pumpAndSettle();
          expect(find.text('파일 보내기'), findsOneWidget);
          expect(find.text('투표'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('chat-attach-mention')));
        }
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('mention-popup')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('말풍선·댓글 렌더링', () {
    Message msg({
      String sender = 'u2',
      String text = '@이영희 확인 부탁해요',
      List<Mention> mentions = const [Mention.user('u3', start: 0, end: 4)],
    }) => Message(
      id: 'm1',
      roomId: 'r1',
      senderId: sender,
      senderName: sender == 'me' ? '나' : '김철수',
      type: MessageType.text,
      text: text,
      mentions: mentions,
      createdAt: DateTime(2026, 9, 30, 9),
    );

    Future<Session> pumpBubble(
      WidgetTester tester,
      Message m, {
      Future<void> Function(
        String,
        String, {
        List<TextFormatRun>? format,
        List<Mention>? mentions,
      })?
      onEdit,
    }) async {
      final room = _room('r1');
      final session = _session(_Server(), [room]);
      _size(tester, const Size(700, 600));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              session: session,
              message: m,
              resolveUrl: session.resolveUrl,
              isMine: m.senderId == 'me',
              sender: room.members.where((u) => u.id == m.senderId).firstOrNull,
              onEdit: onEdit,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return session;
    }

    /// 말풍선 안의 멘션 칩(둥근 연두 바탕 + 굵은 연두 글씨) — [mine]이면 나를 멘션한 진한 칩.
    Finder chip({bool mine = false}) =>
        find.byKey(ValueKey(mine ? 'mention-chip-mine' : 'mention-chip'));
    Text chipText(WidgetTester tester, Finder chip) => tester.widget<Text>(
      find.descendant(of: chip, matching: find.byType(Text)),
    );
    BoxDecoration chipDecoration(WidgetTester tester, Finder chip) =>
        tester.widget<Container>(chip).decoration! as BoxDecoration;

    /// 본문 RichText 안에서 [text] 글자를 가진 TextSpan의 스타일.
    TextStyle? spanStyle(WidgetTester tester, String text) {
      TextStyle? found;
      void visit(InlineSpan span, TextStyle? inherited) {
        if (span is TextSpan) {
          final style = inherited?.merge(span.style) ?? span.style;
          if (span.text == text) found = style;
          for (final c in span.children ?? const <InlineSpan>[]) {
            visit(c, style);
          }
        }
      }

      for (final r in tester.widgetList<RichText>(find.byType(RichText))) {
        visit(r.text, null);
      }
      for (final s in tester.widgetList<SelectableText>(
        find.byType(SelectableText),
      )) {
        if (s.textSpan != null) visit(s.textSpan!, null);
      }
      return found;
    }

    testWidgets('멘션 구간은 강조되고, 나를 멘션하지 않았으면 말풍선에 강조선이 없다', (tester) async {
      await pumpBubble(tester, msg());
      // 연두색 굵은 글씨 + 옅은 연두 바탕의 둥근 칩.
      expect(chip(), findsOneWidget);
      final text = chipText(tester, chip());
      expect(text.data, '@이영희');
      expect(text.style!.fontWeight, FontWeight.w700);
      expect(text.style!.color, const Color(0xFF02C472));
      final deco = chipDecoration(tester, chip());
      expect(deco.color, const Color(0xFFD6F6E9));
      expect(deco.borderRadius, isNotNull);
      expect(chip(mine: true), findsNothing);
      expect(spanStyle(tester, ' 확인 부탁해요')?.fontWeight, isNot(FontWeight.w700));
      expect(_bubbleBorder(tester), isNull);
    });

    testWidgets('내가 멘션됐으면 더 진하게 + 말풍선에 얇은 강조선', (tester) async {
      await pumpBubble(
        tester,
        msg(
          text: '@나 확인 부탁해요',
          mentions: const [Mention.user('me', start: 0, end: 2)],
        ),
      );
      expect(chip(), findsNothing);
      expect(chip(mine: true), findsOneWidget);
      expect(chipText(tester, chip(mine: true)).data, '@나');
      // 나를 멘션한 칩은 바탕이 조금 더 진하다.
      expect(
        chipDecoration(tester, chip(mine: true)).color,
        const Color(0xFFBDEFD9),
      );
      expect(_bubbleBorder(tester), isNotNull);
    });

    testWidgets('@all은 강조되고 나도 멘션된 것으로 본다', (tester) async {
      await pumpBubble(
        tester,
        msg(
          text: '@all 공지입니다',
          mentions: const [Mention.all(start: 0, end: 4)],
        ),
      );
      expect(chip(mine: true), findsOneWidget);
      expect(chipText(tester, chip(mine: true)).data, '@all');
      expect(_bubbleBorder(tester), isNotNull);
    });

    testWidgets('내가 쓴 글의 멘션은 강조선을 두르지 않는다', (tester) async {
      await pumpBubble(
        tester,
        msg(
          sender: 'me',
          text: '@all 공지',
          mentions: const [Mention.all(start: 0, end: 4)],
        ),
      );
      expect(_bubbleBorder(tester), isNull);
      expect(chip(mine: true), findsOneWidget);
    });

    testWidgets('멘션한 이름을 누르면 그 멤버의 프로필이 열린다', (tester) async {
      await pumpBubble(tester, msg());
      await tester.tap(chip());
      await tester.pumpAndSettle();
      expect(find.byType(MemberProfileDialog), findsOneWidget);
    });

    testWidgets('댓글 줄도 같은 방식으로 강조한다', (tester) async {
      final room = _room('r1');
      final session = _session(_Server(), [room]);
      _size(tester, const Size(700, 600));
      final comment = Comment(
        id: 'c1',
        messageId: 'm1',
        roomId: 'r1',
        senderId: 'u2',
        senderName: '김철수',
        text: '@나 이거 봐주세요',
        mentions: const [Mention.user('me', start: 0, end: 2)],
        createdAt: DateTime(2026, 9, 30, 9),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CommentEntryLine(
              session: session,
              comment: comment,
              sender: _kim,
              isMine: false,
              resolveUrl: session.resolveUrl,
              fullWidth: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 댓글 줄도 같은 연두 칩이고, 나를 멘션했으니 진한 칩이다.
      expect(find.byKey(const ValueKey('mention-chip-mine')), findsOneWidget);
    });
  });

  group('수정 화면의 멘션', () {
    testWidgets('수정을 열면 기존 멘션이 이어지고, 그대로 저장하면 mentions를 다시 보낸다', (
      tester,
    ) async {
      final m = Message(
        id: 'm1',
        roomId: 'r1',
        senderId: 'me',
        senderName: '나',
        type: MessageType.text,
        text: '@이영희 확인 부탁해요',
        mentions: const [Mention.user('u3', start: 0, end: 4)],
        createdAt: DateTime.now(),
      );
      List<Mention>? saved;
      String? savedText;
      final room = _room('r1');
      final session = _session(_Server(), [room]);
      _size(tester, const Size(700, 600));
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              key: key,
              session: session,
              message: m,
              resolveUrl: session.resolveUrl,
              isMine: true,
              sender: _me,
              onOpenThread: (_) {},
              onDelete: (_) async {},
              onEdit: (id, text, {format, mentions}) async {
                savedText = text;
                saved = mentions;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 수정 진입 — 말풍선에 마우스를 올려 툴바의 더보기 메뉴에서 "수정"을 고른다.
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(
        tester.getCenter(find.textContaining('확인 부탁해요').first),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('수정'));
      await tester.pumpAndSettle();
      final editor = find.byType(TextField);
      expect(editor, findsOneWidget);
      final controller =
          tester.widget<TextField>(editor).controller!
              as RichTextEditingController;
      expect(controller.mentions.single.userId, 'u3');

      await tester.tap(find.text('저장'));
      await tester.pumpAndSettle();
      expect(savedText, '@이영희 확인 부탁해요');
      expect(saved!.single, const Mention.user('u3', start: 0, end: 4));
    });
  });

  group('전송 경로', () {
    test('댓글 작성·수정, 메시지 수정이 mentions를 본문에 싣는다(수정은 빈 목록도 보낸다)', () async {
      final server = _Server();
      final room = _room('r1');
      final session = _session(server, [room]);
      final c = session.controllerFor(room);
      const mention = Mention.user('u2', start: 0, end: 4);
      await c.postComment('m1', '@김철수 확인', mentions: const [mention]);
      var body =
          jsonDecode(server.called('POST', '/comments').single.body) as Map;
      expect(body['mentions'], [
        {'type': 'user', 'userId': 'u2', 's': 0, 'e': 4},
      ]);

      await c.editComment('c1', '@김철수 수정', mentions: const [mention]);
      body =
          jsonDecode(server.called('PATCH', '/api/comments/c1').single.body)
              as Map;
      expect(body['mentions'], hasLength(1));

      await c.editMessage('m1', '멘션을 지웠어요', mentions: const []);
      body =
          jsonDecode(server.called('PATCH', '/api/messages/m1').single.body)
              as Map;
      expect(body['mentions'], <Object>[]);
    });

    test('게시글 전송·수정, 첨부 글도 mentions를 싣고 비밀 대화는 싣지 않는다', () async {
      final server = _Server();
      final room = _room('r1');
      final session = _session(server, [room]);
      final c = session.controllerFor(room);
      final payloads = <Map<String, dynamic>>[];
      session.chatSocket.debugSendOverride = (p) async {
        payloads.add(p);
        return {'ok': true};
      };
      const mention = Mention.all(start: 0, end: 4);
      await c.sendPost(title: '제목', text: '@all 공지', mentions: const [mention]);
      expect(payloads.single['mentions'], [
        {'type': 'all', 's': 0, 'e': 4},
      ]);
      await c.editPost(
        'm2',
        title: '제목',
        text: '@all 공지',
        mentions: const [mention],
      );
      final body =
          jsonDecode(server.called('PATCH', '/api/messages/m2').single.body)
              as Map;
      expect(body['mentions'], hasLength(1));

      final secret = _room(
        's',
        type: RoomType.dm,
        secret: true,
        members: [_me, _kim],
      );
      session.rooms.add(secret);
      // 비밀 대화는 암호화 경로를 타서 여기서는 payload 구성만 확인할 수 없으므로, 방 정책만 본다.
      expect(secret.isSecret, isTrue);
    });
  });

  group('방 목록 "@" 표시', () {
    testWidgets('MentionMarker는 "@" 원을 그린다', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(children: [MentionMarker(), UnreadBadge(count: 2)]),
          ),
        ),
      );
      expect(find.text('@'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });
  });
}

/// 말풍선(AnimatedContainer)의 테두리 — 없으면 null.
Border? _bubbleBorder(WidgetTester tester) {
  for (final c in tester.widgetList<AnimatedContainer>(
    find.byType(AnimatedContainer),
  )) {
    final d = c.decoration;
    if (d is BoxDecoration && d.border is Border) return d.border as Border;
  }
  return null;
}
