import 'dart:convert';

import 'package:client/models/announcement.dart';
import 'package:client/models/app_user.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/announcement_editor_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/rich_text_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 공지 쓰기 창의 서식 도구모음(프로젝트 "새 노트"와 같은 도구)과 서식 저장, "공지 자동 내리기 > 지정"의
/// 날짜+시각 한 칸(투표 마감 시각과 같은 ScheduleDateTimeField — 1년까지).

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

final _me = AppUser(id: 'me', username: 'me', name: '나');

Room _room() => Room(
  id: 'r1',
  teamId: 't1',
  type: RoomType.topic,
  name: '영업방',
  members: [_me],
  createdAt: DateTime(2026),
  lastRead: {},
);

Map<String, dynamic> _announcementJson({
  String text = '원래 글',
  Object? textFormat,
}) => {
  'id': 'a1',
  'roomId': 'r1',
  'authorId': 'me',
  'authorName': '나',
  'text': text,
  'textFormat': textFormat,
  'createdAt': DateTime(2026, 9, 30).millisecondsSinceEpoch,
  'pinned': true,
};

Session _session({http.Client? client}) {
  final session = Session(
    notifications: _QuietNotifications(),
    settings: AppSettings(),
  );
  session.serverUrl = 'https://test.local';
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: client ?? MockClient((_) async => _json(<Object>[])),
  );
  session.userId = 'me';
  session.name = '나';
  final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  session.rooms.add(_room());
  return session;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

Finder _key(String key) => find.byKey(ValueKey(key));

RichTextEditingController _bodyController(WidgetTester tester) =>
    tester.widget<TextField>(_key('announcement-body')).controller!
        as RichTextEditingController;

Future<void> _openEditor(
  WidgetTester tester, {
  Size size = const Size(1000, 800),
  Announcement? announcement,
  List<AnnouncementDraft>? sink,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final session = _session();
  final room = session.rooms.first;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showAnnouncementEditor(
                context,
                session: session,
                room: room,
                announcement: announcement,
                onSubmit: (draft) async => sink?.add(draft),
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('열기'));
  await _settle(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('서식 도구모음', () {
    for (final (label, size) in [
      ('PC 대화상자', const Size(1000, 800)),
      ('모바일 전체 화면', const Size(360, 780)),
    ]) {
      testWidgets('$label: 본문 칸 위에 노트 편집기와 같은 도구모음이 늘 있다', (tester) async {
        await _openEditor(tester, size: size);
        final toolbar = _key('announcement-format-toolbar');
        expect(toolbar, findsOneWidget);
        expect(
          find.descendant(
            of: toolbar,
            matching: find.byType(RichFormatToolbar),
          ),
          findsOneWidget,
        );
        for (final tip in [
          '글자색',
          '제목 1',
          '제목 2',
          '제목 3',
          '굵게 (Ctrl+B)',
          '기울임 (Ctrl+I)',
          '밑줄 (Ctrl+U)',
          '취소선',
          '링크',
          '코드',
          '인용',
          '번호 목록',
          '글머리 목록',
          '구분선',
        ]) {
          expect(
            find.descendant(of: toolbar, matching: find.byTooltip(tip)),
            findsOneWidget,
            reason: tip,
          );
        }
        // 도구모음이 본문 칸보다 위에 있다.
        expect(
          tester.getTopLeft(toolbar).dy,
          lessThan(tester.getTopLeft(_key('announcement-body')).dy),
        );
        expect(tester.takeException(), isNull);
        await _finish(tester);
      });
    }

    testWidgets('고른 글자에 굵게·제목을 걸면 등록할 때 그 서식이 글(앞뒤 공백 뗌)에 맞춰 넘어간다', (
      tester,
    ) async {
      final sink = <AnnouncementDraft>[];
      await _openEditor(tester, sink: sink);
      await tester.enterText(_key('announcement-body'), '  회의 안내\n본문  ');
      await tester.pump();
      final c = _bodyController(tester);
      // "회의"(2..4)를 골라 굵게.
      c.selection = const TextSelection(baseOffset: 2, extentOffset: 4);
      await tester.pump();
      await tester.tap(find.byTooltip('굵게 (Ctrl+B)'));
      await tester.pump();
      expect(c.isActive(Fmt.bold), isTrue);
      // 첫 줄 전체를 제목 1로.
      c.selection = const TextSelection.collapsed(offset: 4);
      await tester.tap(find.byTooltip('제목 1'));
      await tester.pump();

      await tester.tap(_key('announcement-submit'));
      await _settle(tester);
      final draft = sink.single;
      expect(draft.text, '회의 안내\n본문');
      final runs = draft.format!;
      int flagsAt(int i) => runs
          .where((r) => r.start <= i && i < r.end)
          .fold(0, (f, r) => f | r.flags);
      // 앞 공백 두 칸을 뗀 위치 — "회의"는 0..2, 첫 줄(0..5)은 제목 1, 둘째 줄은 서식 없음.
      expect(flagsAt(0) & Fmt.bold, Fmt.bold);
      expect(flagsAt(1) & Fmt.bold, Fmt.bold);
      expect(flagsAt(3) & Fmt.bold, 0);
      expect(flagsAt(0) & Fmt.h1, Fmt.h1);
      expect(flagsAt(4) & Fmt.h1, Fmt.h1);
      expect(flagsAt(draft.text.length - 1), 0);
      await _finish(tester);
    });

    testWidgets('Ctrl+B 단축키로도 굵게가 걸린다', (tester) async {
      final sink = <AnnouncementDraft>[];
      await _openEditor(tester, sink: sink);
      await tester.enterText(_key('announcement-body'), '중요');
      final c = _bodyController(tester);
      c.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.tap(_key('announcement-submit'));
      await _settle(tester);
      expect(sink.single.format!.single.flags & Fmt.bold, Fmt.bold);
      await _finish(tester);
    });

    testWidgets('서식 없이 쓰면 format은 null(평문 공지)', (tester) async {
      final sink = <AnnouncementDraft>[];
      await _openEditor(tester, sink: sink);
      await tester.enterText(_key('announcement-body'), '평범한 공지');
      await tester.tap(_key('announcement-submit'));
      await _settle(tester);
      expect(sink.single.text, '평범한 공지');
      expect(sink.single.format, isNull);
      await _finish(tester);
    });

    testWidgets('수정: 저장된 서식이 칸에 그대로 살아 있고, 서식만 바꿔도 "고친 것"으로 본다', (
      tester,
    ) async {
      final sink = <AnnouncementDraft>[];
      final red = Fmt.withColor(0, 0xE53935);
      final a = Announcement.fromJson(
        _announcementJson(
          text: '굵게 빨강',
          textFormat: [
            {'s': 0, 'e': 2, 'f': Fmt.bold},
            {'s': 3, 'e': 5, 'f': red},
          ],
        ),
      );
      expect(a.textFormat, hasLength(2));
      await _openEditor(tester, announcement: a, sink: sink);
      final c = _bodyController(tester);
      expect(c.text, '굵게 빨강');
      c.selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();
      expect(c.isActive(Fmt.bold), isTrue);
      c.selection = const TextSelection.collapsed(offset: 4);
      await tester.pump();
      expect(c.currentColor, 0xE53935);

      // 아무것도 안 바꾸고 닫으면 묻지 않는다.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.text('공지 수정'), findsNothing);
      expect(find.text('수정 취소'), findsNothing);

      // 다시 열어 굵게만 풀면 닫기 전에 묻고, 저장하면 바뀐 서식이 넘어간다.
      await tester.tap(find.text('열기'));
      await _settle(tester);
      final c2 = _bodyController(tester);
      c2.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
      await tester.pump();
      await tester.tap(find.byTooltip('굵게 (Ctrl+B)'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.text('수정 취소'), findsOneWidget);
      await tester.tap(find.text('계속 쓰기'));
      await _settle(tester);
      await tester.tap(_key('announcement-submit'));
      await _settle(tester);
      final draft = sink.single;
      expect(draft.text, '굵게 빨강');
      expect(draft.format!.single.start, 3);
      expect(Fmt.colorOf(draft.format!.single.flags), 0xE53935);
      // 수정에는 자동 내리기가 없다.
      expect(draft.autoUnpinAfter, isNull);
      await _finish(tester);
    });
  });

  group('공지 서식 저장·표시', () {
    test('Announcement.fromJson이 textFormat을 읽는다(없으면 null)', () {
      final a = Announcement.fromJson(
        _announcementJson(
          text: '제목',
          textFormat: [
            {'s': 0, 'e': 2, 'f': Fmt.h1 | Fmt.bold},
          ],
        ),
      );
      expect(a.textFormat!.single.flags, Fmt.h1 | Fmt.bold);
      expect(Announcement.fromJson(_announcementJson()).textFormat, isNull);
    });

    test(
      'createAnnouncement·updateAnnouncement는 서식이 있을 때만 textFormat을 보낸다',
      () async {
        final bodies = <Map<String, dynamic>>[];
        final client = MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          bodies.add(body);
          return _json(
            _announcementJson(
              text: body['text'] as String,
              textFormat: body['textFormat'],
            ),
          );
        });
        final api = ApiClient(
          baseUrl: 'https://test.local',
          token: 't',
          httpClient: client,
        );
        const runs = [TextFormatRun(0, 2, Fmt.bold)];
        final created = await api.createAnnouncement(
          'r1',
          '공지',
          textFormat: runs,
        );
        expect(bodies.last['textFormat'], [
          {'s': 0, 'e': 2, 'f': Fmt.bold},
        ]);
        expect(created.textFormat!.single.flags, Fmt.bold);

        await api.createAnnouncement('r1', '평문');
        expect(bodies.last.containsKey('textFormat'), isFalse);

        await api.updateAnnouncement('r1', 'a1', '고침', textFormat: runs);
        expect(bodies.last['textFormat'], isNotNull);
        // 서식을 안 주면 보내지 않는다 — 서버가 서식을 지운다.
        await api.updateAnnouncement('r1', 'a1', '고침');
        expect(bodies.last, {'text': '고침'});
      },
    );

    testWidgets('FormattedText maxLines — 미리보기처럼 줄 수를 넘으면 말줄임(인용 줄도 한 덩어리)', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: FormattedText(
              '첫 줄\n둘째 줄\n셋째 줄',
              format: [TextFormatRun(0, 3, Fmt.bold), TextFormatRun(4, 8, 32)],
              maxLines: 2,
            ),
          ),
        ),
      );
      final text = tester.widget<RichText>(find.byType(RichText).first);
      expect(text.maxLines, 2);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(find.byType(Column), findsNothing);
    });
  });

  group('자동 내리기 지정', () {
    Future<void> openCustom(
      WidgetTester tester, {
      Size size = const Size(1000, 800),
      List<AnnouncementDraft>? sink,
    }) async {
      await _openEditor(tester, size: size, sink: sink);
      await tester.enterText(_key('announcement-body'), '자동 내리기 공지');
      await tester.ensureVisible(_key('announcement-auto-unpin-custom'));
      await tester.tap(_key('announcement-auto-unpin-custom'));
      await _settle(tester);
    }

    testWidgets('"지정"을 고르면 대화상자 대신 칩 아래에 날짜+시각 한 칸이 펼쳐진다(기본: 내일 이맘때)', (
      tester,
    ) async {
      await openCustom(tester);
      // 예전의 일/시간 입력 대화상자는 없다.
      expect(find.text('공지 자동 내리기 — 직접 지정'), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(_key('schedule-datetime'), findsOneWidget);
      final now = DateTime.now();
      final tomorrow = DateTime(now.year, now.month, now.day + 1);
      expect(
        find.descendant(
          of: _key('schedule-datetime'),
          matching: find.textContaining('${tomorrow.month}월 ${tomorrow.day}일'),
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(_key('announcement-auto-unpin-hint')).data,
        anyOf(contains('1일 뒤에'), contains('23시간')),
      );
      // 빠른 선택으로 돌아가면 칸이 사라진다.
      await tester.tap(find.text('없음'));
      await tester.pump();
      expect(_key('schedule-datetime'), findsNothing);
      await _finish(tester);
    });

    testWidgets('칸을 누르면 달력 + 그 밑 시간 드롭다운(목록은 위로 펼쳐짐) — 고른 시각까지의 기간이 넘어간다', (
      tester,
    ) async {
      final sink = <AnnouncementDraft>[];
      await openCustom(tester, sink: sink);
      await tester.tap(_key('schedule-datetime'));
      await _settle(tester);
      expect(_key('schedule-datetime-popup'), findsOneWidget);

      // 모레를 고른다(그달이 아니면 다음 달로).
      final now = DateTime.now();
      final day = DateTime(now.year, now.month, now.day + 2);
      if (day.month != now.month) {
        await tester.tap(find.byTooltip('다음 달'));
        await _settle(tester);
      }
      await tester.tap(
        _key('schedule-day-${day.year}-${day.month}-${day.day}'),
      );
      await _settle(tester);
      expect(_key('schedule-datetime-popup'), findsOneWidget);

      await tester.tap(_key('schedule-time-box'));
      await _settle(tester);
      final list = _key('schedule-time-list');
      expect(list, findsOneWidget);
      // 목록은 시간 칸 위로(달력을 덮으며) 펼쳐진다.
      expect(
        tester.getBottomLeft(list).dy,
        lessThanOrEqualTo(tester.getTopLeft(_key('schedule-time-box')).dy),
      );
      final slot = _key('schedule-slot-${15 * 60 + 30}');
      // 목록은 지금 값 자리로 스크롤해 열린다 — 오후에 돌리면 3:30이 그보다 위라 먼저 맨 위로 올린다.
      await tester.drag(list, const Offset(0, 10000));
      await _settle(tester);
      await tester.scrollUntilVisible(
        slot,
        150,
        scrollable: find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        ),
      );
      await tester.ensureVisible(slot);
      await _settle(tester);
      await tester.tap(slot);
      await _settle(tester);
      expect(_key('schedule-datetime-popup'), findsNothing);
      expect(
        find.descendant(
          of: _key('schedule-datetime'),
          matching: find.textContaining('오후 3:30'),
        ),
        findsOneWidget,
      );

      await tester.tap(_key('announcement-submit'));
      await _settle(tester);
      final target = DateTime(day.year, day.month, day.day, 15, 30);
      final after = sink.single.autoUnpinAfter!;
      final landed = DateTime.now().add(after);
      expect(landed.difference(target).inMinutes.abs(), lessThan(2));
      await _finish(tester);
    });

    testWidgets('투표·예약(90일)보다 길게 — 1년(365일) 안까지 고를 수 있다', (tester) async {
      await openCustom(tester);
      await tester.tap(_key('schedule-datetime'));
      await _settle(tester);
      final now = DateTime.now();
      // 200일 뒤 — 예약 메시지 한도(90일)를 넘지만 공지 자동 내리기는 된다.
      final far = DateTime(now.year, now.month, now.day + 200);
      final months = (far.year - now.year) * 12 + far.month - now.month;
      for (var i = 0; i < months; i++) {
        await tester.tap(find.byTooltip('다음 달'));
        await tester.pump();
      }
      final cell = tester.widget<InkWell>(
        _key('schedule-day-${far.year}-${far.month}-${far.day}'),
      );
      expect(cell.onTap, isNotNull);
      // 1년 넘는 달까지는 넘어가지 않는다.
      for (var i = 0; i < 12; i++) {
        final next = find.byTooltip('다음 달');
        final button = tester.widget<IconButton>(
          find.ancestor(of: next, matching: find.byType(IconButton)).first,
        );
        if (button.onPressed == null) break;
        await tester.tap(next);
        await tester.pump();
      }
      final limit = DateTime(now.year, now.month, now.day + 366);
      final beyond = _key(
        'schedule-day-${limit.year}-${limit.month}-${limit.day}',
      );
      if (beyond.evaluate().isNotEmpty) {
        expect(tester.widget<InkWell>(beyond).onTap, isNull);
      }
      await _finish(tester);
    });

    testWidgets('Esc는 펼친 달력 판만 먼저 닫는다', (tester) async {
      await openCustom(tester);
      await tester.tap(_key('schedule-datetime'));
      await _settle(tester);
      expect(_key('schedule-datetime-popup'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(_key('schedule-datetime-popup'), findsNothing);
      expect(find.text('공지 쓰기'), findsOneWidget);
      expect(find.text('작성 취소'), findsNothing);
      await _finish(tester);
    });

    testWidgets('모바일(폭 360): 칸이 폭을 꽉 채우고 넘치지 않는다', (tester) async {
      await openCustom(tester, size: const Size(360, 780));
      expect(_key('schedule-datetime'), findsOneWidget);
      await tester.ensureVisible(_key('schedule-datetime'));
      await _settle(tester);
      await tester.tap(_key('schedule-datetime'));
      await _settle(tester);
      expect(_key('schedule-datetime-popup'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });
  });
}
