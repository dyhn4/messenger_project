import 'package:client/models/calendar.dart';
import 'package:client/screens/calendar/calendar_drag.dart';
import 'package:client/screens/calendar/calendar_month_view.dart';
import 'package:client/screens/calendar/calendar_screen.dart';
import 'package:client/screens/calendar/calendar_time_grid.dart';
import 'package:client/models/team.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/calendar_controller.dart';
import 'package:client/services/calendar_layout.dart';
import 'package:client/services/calendar_move.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_calendar_api.dart';

/// 일정 드래그 이동 위젯 시험 — 월간(날짜 칸), 주간·일간 시간표(날짜+10분 스냅, 종일 칸), 반복·권한 없는 일정은
/// 안 끌림, 모바일(터치) 길게 눌러 끌기, 화면 전체(낙관적 갱신·실패 되돌리기).

typedef _Moves = List<(EventOccurrence, EventMove)>;

ThemeData get _desktopTheme => ThemeData(platform: TargetPlatform.windows);

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

int _ms(int y, int m, int d, [int h = 0, int min = 0]) =>
    DateTime(y, m, d, h, min).millisecondsSinceEpoch;

/// 마우스로 [from]에서 [to]까지 끌고, [release]면 놓는다. 놓지 않으면 제스처를 돌려준다(끄는 중 상태 확인용).
Future<TestGesture> _mouseDrag(
  WidgetTester tester,
  Offset from,
  Offset to, {
  bool release = true,
}) async {
  final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
  await g.moveBy(const Offset(4, 4));
  await tester.pump();
  await g.moveTo(to);
  await tester.pump();
  if (release) {
    await g.up();
    await g.removePointer();
    await tester.pump();
  }
  return g;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('월간 보기', () {
    final timed = timedEvent(
      't',
      DateTime(2026, 9, 10, 9, 30),
      DateTime(2026, 9, 10, 11),
      title: '디자인 리뷰',
    );
    // 9/29(화) ~ 10/1(목) 3일 — 같은 주 열 2..4.
    final trip = allDayEvent(
      'trip',
      DateTime(2026, 9, 29),
      DateTime(2026, 10, 1),
      title: '출장',
    );
    final recurring = timedEvent(
      'r',
      DateTime(2026, 9, 21, 10),
      DateTime(2026, 9, 21, 11),
      title: '주간 회의',
      recurring: true,
      recurrence: const Recurrence(freq: 'weekly', byWeekday: [1]),
    );
    final readOnly = timedEvent(
      'ro',
      DateTime(2026, 9, 22, 10),
      DateTime(2026, 9, 22, 11),
      title: '읽기 전용',
      canEdit: false,
    );
    final restricted = timedEvent(
      'rs',
      DateTime(2026, 9, 23, 10),
      DateTime(2026, 9, 23, 11),
      title: '비공개 일정',
      restricted: true,
      canEdit: false,
    );
    final holiday = holidayEvent(DateTime(2026, 9, 25), '추석연휴');

    Future<_Moves> pump(
      WidgetTester tester, {
      bool compact = false,
      Size size = const Size(1000, 700),
    }) async {
      _size(tester, size);
      final moves = <(EventOccurrence, EventMove)>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: _desktopTheme,
          home: Scaffold(
            body: SizedBox(
              width: size.width,
              height: size.height - 100,
              child: CalendarMonthView(
                month: DateTime(2026, 9, 1),
                today: DateTime(2026, 9, 30),
                events: [timed, trip, recurring, readOnly, restricted, holiday],
                compact: compact,
                onDayTap: (_) {},
                onEventTap: (_) {},
                onMoreTap: (_) {},
                onEventMove: (e, m) => moves.add((e, m)),
              ),
            ),
          ),
        ),
      );
      return moves;
    }

    Offset cell(WidgetTester t, String ymd) =>
        t.getCenter(find.byKey(ValueKey('cal-day-$ymd')));

    Finder bar(EventOccurrence e, int col) =>
        find.byKey(ValueKey('cal-bar-${e.key}-$col'));

    testWidgets('시간 일정을 다른 날짜 칸에 놓으면 날짜만 옮기고 시각은 유지', (tester) async {
      final moves = await pump(tester);
      await _mouseDrag(
        tester,
        tester.getCenter(bar(timed, 4)),
        cell(tester, '2026-09-17'),
      );
      expect(moves, hasLength(1));
      final (e, m) = moves.single;
      expect(e.eventId, 't');
      expect(m.allDay, isFalse);
      expect(m.start, _ms(2026, 9, 17, 9, 30));
      expect(m.end, _ms(2026, 9, 17, 11));
    });

    testWidgets('같은 주 줄 안에서도 끌린다(끄는 중에 막대가 다시 만들어지지 않는다)', (tester) async {
      final moves = await pump(tester);
      await _mouseDrag(
        tester,
        tester.getCenter(bar(timed, 4)),
        cell(tester, '2026-09-08'),
      );
      expect(moves, hasLength(1));
      expect(moves.single.$2.start, _ms(2026, 9, 8, 9, 30));
    });

    testWidgets('끄는 동안 목적지 칸 하이라이트와 반투명 고스트가 보이고, 놓으면 사라진다', (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('cal-drop-2026-09-17')), findsNothing);
      final g = await _mouseDrag(
        tester,
        tester.getCenter(bar(timed, 4)),
        cell(tester, '2026-09-17'),
        release: false,
      );
      expect(find.byKey(const ValueKey('cal-drop-2026-09-17')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('cal-ghost-2026-09-17')),
        findsOneWidget,
      );
      // 포인터 옆에도 제목 칩이 따라다닌다(원래 자리 + 칩).
      expect(find.text('디자인 리뷰'), findsWidgets);
      await g.up();
      await g.removePointer();
      await tester.pump();
      expect(find.byKey(const ValueKey('cal-drop-2026-09-17')), findsNothing);
      expect(find.byKey(const ValueKey('cal-ghost-2026-09-17')), findsNothing);
    });

    testWidgets('여러 날 종일 막대: 잡은 날이 놓인 칸에 오도록 전체가 같이 이동', (tester) async {
      final moves = await pump(tester);
      // 막대는 열 2..4(9/29~10/1) — 가운데(9/30 부분)를 잡는다.
      final b = tester.getRect(bar(trip, 2));
      final grab = Offset(b.left + b.width / 2, b.center.dy);
      await _mouseDrag(tester, grab, cell(tester, '2026-09-16'));
      expect(moves, hasLength(1));
      final m = moves.single.$2;
      expect(m.allDay, isTrue);
      // 잡은 날(둘째 날)이 9/16 → 첫날은 9/15, 3일 → 9/15~9/17(끝은 9/18 배타).
      expect(m.start, allDayToMs(DateTime(2026, 9, 15)));
      expect(m.end, allDayToMs(DateTime(2026, 9, 18)));
    });

    testWidgets('같은 칸에 놓거나 격자 밖에 놓으면 아무 일도 없다', (tester) async {
      final moves = await pump(tester);
      await _mouseDrag(
        tester,
        tester.getCenter(bar(timed, 4)),
        cell(tester, '2026-09-10') + const Offset(8, 20),
      );
      expect(moves, isEmpty);
      await _mouseDrag(
        tester,
        tester.getCenter(bar(timed, 4)),
        const Offset(500, 680),
      );
      expect(moves, isEmpty);
    });

    testWidgets('반복 일정은 끌리지 않고, 일반 커서와 안내 툴팁이 나온다', (tester) async {
      final moves = await pump(tester);
      final target = bar(recurring, 1);
      expect(target, findsOneWidget);
      await _mouseDrag(
        tester,
        tester.getCenter(target),
        cell(tester, '2026-09-17'),
      );
      expect(moves, isEmpty);
      expect(find.byKey(const ValueKey('cal-drop-2026-09-17')), findsNothing);
      final ink = tester.widget<InkWell>(
        find.descendant(of: target, matching: find.byType(InkWell)),
      );
      expect(ink.mouseCursor, SystemMouseCursors.basic);
      // 마우스를 올리면 툴팁.
      final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await hover.addPointer(location: Offset.zero);
      addTearDown(hover.removePointer);
      await hover.moveTo(tester.getCenter(target));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text(kRecurringDragHint), findsOneWidget);
    });

    testWidgets('끌 수 있는 일정의 커서는 잡는 손 모양', (tester) async {
      await pump(tester);
      final ink = tester.widget<InkWell>(
        find.descendant(of: bar(timed, 4), matching: find.byType(InkWell)),
      );
      expect(ink.mouseCursor, SystemMouseCursors.grab);
    });

    testWidgets('수정 권한 없는 일정·제한된 일정·공휴일은 끌리지 않는다', (tester) async {
      final moves = await pump(tester);
      await _mouseDrag(
        tester,
        tester.getCenter(bar(readOnly, 2)),
        cell(tester, '2026-09-17'),
      );
      await _mouseDrag(
        tester,
        tester.getCenter(bar(restricted, 3)),
        cell(tester, '2026-09-17'),
      );
      expect(moves, isEmpty);
      expect(find.byKey(const ValueKey('cal-drop-2026-09-17')), findsNothing);
      // 읽기 전용은 툴팁도 없다(반복 일정 안내는 수정 권한이 있을 때만).
      final ink = tester.widget<InkWell>(
        find.descendant(of: bar(readOnly, 2), matching: find.byType(InkWell)),
      );
      expect(ink.mouseCursor, isNull);
    });

    testWidgets('작은 격자(compact, 모바일)에서는 끌 수 없다', (tester) async {
      final moves = await pump(
        tester,
        compact: true,
        size: const Size(360, 640),
      );
      await _mouseDrag(
        tester,
        tester.getCenter(find.byKey(const ValueKey('cal-day-2026-09-10'))),
        tester.getCenter(find.byKey(const ValueKey('cal-day-2026-09-17'))),
      );
      expect(moves, isEmpty);
    });

    testWidgets('onEventMove가 없으면 끌리지 않는다', (tester) async {
      _size(tester, const Size(1000, 700));
      await tester.pumpWidget(
        MaterialApp(
          theme: _desktopTheme,
          home: Scaffold(
            body: CalendarMonthView(
              month: DateTime(2026, 9, 1),
              today: DateTime(2026, 9, 30),
              events: [timed],
              onDayTap: (_) {},
              onEventTap: (_) {},
              onMoreTap: (_) {},
            ),
          ),
        ),
      );
      final g = await _mouseDrag(
        tester,
        tester.getCenter(bar(timed, 4)),
        tester.getCenter(find.byKey(const ValueKey('cal-day-2026-09-17'))),
        release: false,
      );
      expect(find.byKey(const ValueKey('cal-drop-2026-09-17')), findsNothing);
      await g.up();
      await g.removePointer();
    });
  });

  group('주간·일간 시간표', () {
    // 오늘이 들어 있지 않은 주로 — 처음 스크롤 위치가 오전 8시로 정해진다.
    final week = weekDays(DateTime(2020, 9, 16)); // 9/13(일) ~ 9/19(토)
    final meeting = timedEvent(
      'm',
      DateTime(2020, 9, 16, 10),
      DateTime(2020, 9, 16, 11),
      title: '팀 회의',
    );
    final trip = allDayEvent(
      'trip',
      DateTime(2020, 9, 15),
      DateTime(2020, 9, 16),
      title: '출장',
    );
    final repeating = timedEvent(
      'r',
      DateTime(2020, 9, 17, 15),
      DateTime(2020, 9, 17, 16),
      title: '반복 회의',
      recurring: true,
      recurrence: const Recurrence(freq: 'daily'),
    );

    Future<_Moves> pump(
      WidgetTester tester, {
      List<DateTime>? days,
      Size size = const Size(1200, 800),
      ThemeData? theme,
    }) async {
      _size(tester, size);
      final moves = <(EventOccurrence, EventMove)>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: theme ?? _desktopTheme,
          home: Scaffold(
            body: CalendarTimeGrid(
              days: days ?? week,
              events: [meeting, trip, repeating],
              today: DateTime(2020, 9, 16),
              onEventTap: (_) {},
              onSlotTap: (_) {},
              onMoreTap: (_) {},
              onEventMove: (e, m) => moves.add((e, m)),
            ),
          ),
        ),
      );
      await tester.pump();
      return moves;
    }

    /// 열 [md]('9-18' 같은 키)에서 [h]시 [min]분 위치(전역 좌표).
    Offset at(WidgetTester t, String md, int h, int min) {
      final slot = t.getRect(find.byKey(ValueKey('cal-slot-$md')));
      return Offset(slot.center.dx, slot.top + (h * 60 + min) / 60 * 52);
    }

    testWidgets('블록을 다른 날·다른 시각으로 끌면 10분 단위로 맞추고 길이를 유지', (tester) async {
      final moves = await pump(tester);
      final block = find.byKey(ValueKey('cal-block-${meeting.key}'));
      expect(block, findsOneWidget);
      // 블록 한가운데(10:30)를 잡고 9/18 14:37 자리에 놓는다 → 잡은 곳 기준으로 시작은 14:07 → 14:10.
      await _mouseDrag(
        tester,
        tester.getCenter(block),
        at(tester, '9-18', 14, 37),
      );
      expect(moves, hasLength(1));
      final m = moves.single.$2;
      expect(m.allDay, isFalse);
      expect(m.start, _ms(2020, 9, 18, 14, 10));
      expect(m.end - m.start, 3600000);
    });

    testWidgets('끄는 동안 도착 열 하이라이트와 시간 범위가 적힌 고스트가 보인다', (tester) async {
      await pump(tester);
      final block = find.byKey(ValueKey('cal-block-${meeting.key}'));
      final g = await _mouseDrag(
        tester,
        tester.getCenter(block),
        at(tester, '9-18', 14, 30),
        release: false,
      );
      expect(find.byKey(const ValueKey('cal-drop-9-18')), findsOneWidget);
      final ghost = find.byKey(ValueKey('cal-ghost-${meeting.key}'));
      expect(ghost, findsOneWidget);
      // 14:00 ~ 15:00 (잡은 곳이 블록 한가운데라 30분 위로 시작).
      expect(
        find.descendant(of: ghost, matching: find.textContaining('2:00')),
        findsWidgets,
      );
      await g.up();
      await g.removePointer();
      await tester.pump();
      expect(find.byKey(ValueKey('cal-ghost-${meeting.key}')), findsNothing);
    });

    testWidgets('같은 자리에 놓으면 아무 일도 없다', (tester) async {
      final moves = await pump(tester);
      final block = find.byKey(ValueKey('cal-block-${meeting.key}'));
      await _mouseDrag(
        tester,
        tester.getCenter(block),
        tester.getCenter(block) + const Offset(0, 2),
      );
      expect(moves, isEmpty);
    });

    testWidgets('종일 막대는 날짜만: 종일 칸의 막대를 다른 날 열로 끈다', (tester) async {
      final moves = await pump(tester);
      final strip = find.byKey(ValueKey('cal-strip-${trip.key}-2'));
      expect(strip, findsOneWidget);
      final r = tester.getRect(strip);
      // 막대는 9/15~9/16(열 2·3) — 첫날 쪽을 잡고 9/18 열로.
      final grab = Offset(r.left + r.width / 4, r.center.dy);
      final target = Offset(
        tester.getCenter(find.byKey(const ValueKey('cal-slot-9-18'))).dx,
        r.center.dy,
      );
      await _mouseDrag(tester, grab, target);
      expect(moves, hasLength(1));
      final m = moves.single.$2;
      expect(m.allDay, isTrue);
      expect(m.start, allDayToMs(DateTime(2020, 9, 18)));
      expect(m.end, allDayToMs(DateTime(2020, 9, 20)));
    });

    testWidgets('종일 막대를 시간표 영역에 놓아도 날짜만 옮긴다(시각 없음)', (tester) async {
      final moves = await pump(tester);
      final strip = find.byKey(ValueKey('cal-strip-${trip.key}-2'));
      final r = tester.getRect(strip);
      final grab = Offset(r.left + r.width / 4, r.center.dy);
      await _mouseDrag(tester, grab, at(tester, '9-17', 13, 0));
      expect(moves, hasLength(1));
      expect(moves.single.$2.allDay, isTrue);
      expect(moves.single.$2.start, allDayToMs(DateTime(2020, 9, 17)));
    });

    testWidgets('반복 일정 블록은 끌리지 않는다', (tester) async {
      final moves = await pump(tester);
      final block = find.byKey(ValueKey('cal-block-${repeating.key}'));
      expect(block, findsOneWidget);
      await _mouseDrag(
        tester,
        tester.getCenter(block),
        at(tester, '9-18', 9, 0),
      );
      expect(moves, isEmpty);
      final ink = tester.widget<InkWell>(
        find.descendant(of: block, matching: find.byType(InkWell)),
      );
      expect(ink.mouseCursor, SystemMouseCursors.basic);
    });

    testWidgets('일간 보기(열 1개)에서도 시각이 옮겨진다', (tester) async {
      final moves = await pump(tester, days: [DateTime(2020, 9, 16)]);
      final block = find.byKey(ValueKey('cal-block-${meeting.key}'));
      await _mouseDrag(
        tester,
        tester.getCenter(block),
        at(tester, '9-16', 16, 30),
      );
      expect(moves.single.$2.start, _ms(2020, 9, 16, 16));
    });

    testWidgets('모바일(터치): 길게 눌러야 끌리고, 그냥 끌면 스크롤이다', (tester) async {
      final moves = await pump(
        tester,
        days: [DateTime(2020, 9, 16)],
        size: const Size(360, 780),
        theme: ThemeData(platform: TargetPlatform.android),
      );
      final block = find.byKey(ValueKey('cal-block-${meeting.key}'));
      // 길게 누르지 않고 끌면 스크롤만 된다.
      final from = tester.getCenter(block);
      await tester.dragFrom(from, const Offset(0, -60));
      await tester.pump();
      expect(moves, isEmpty);

      final start = tester.getCenter(block);
      final g = await tester.startGesture(start);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await g.moveBy(const Offset(0, 20));
      await tester.pump();
      await g.moveTo(at(tester, '9-16', 15, 30));
      await tester.pump();
      expect(find.byKey(ValueKey('cal-ghost-${meeting.key}')), findsOneWidget);
      await g.up();
      await g.removePointer();
      await tester.pump();
      expect(moves, hasLength(1));
      expect(moves.single.$2.start, _ms(2020, 9, 16, 15));
    });
  });

  group('화면 전체', () {
    final now = DateTime(2026, 9, 30, 10, 15);

    Session session() {
      final s = Session(notifications: _Quiet(), settings: AppSettings());
      s.serverUrl = 'https://test.local';
      s.api = ApiClient(baseUrl: 'https://test.local', token: 't');
      s.userId = 'me';
      s.name = '나';
      final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
      s.teams.add(team);
      s.currentTeam = team;
      return s;
    }

    FakeCalendarApi api() => FakeCalendarApi(
      events: [
        timedEvent(
          'm',
          DateTime(2026, 9, 30, 10),
          DateTime(2026, 9, 30, 11),
          title: '오늘 회의',
        ),
      ],
    );

    Future<CalendarController> pumpScreen(
      WidgetTester tester,
      FakeCalendarApi api,
    ) async {
      _size(tester, const Size(1280, 900));
      final controller = CalendarController(
        apiProvider: () => api,
        userId: () => 'me',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: _desktopTheme,
          home: CalendarScreen(
            session: session(),
            controller: controller,
            now: now,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return controller;
    }

    testWidgets('놓으면 곧바로 새 칸에 보이고 PATCH(start/end/allDay, scope 없음)를 보낸다', (
      tester,
    ) async {
      final fake = api();
      await pumpScreen(tester, fake);
      final src = fake.events.single;
      final bar = find.byKey(ValueKey('cal-bar-${src.key}-3'));
      await _mouseDrag(
        tester,
        tester.getCenter(bar),
        tester.getCenter(find.byKey(const ValueKey('cal-day-2026-09-16'))),
      );
      await tester.pumpAndSettle();
      expect(fake.calls, contains('updateEvent m null'));
      expect(fake.lastScope, isNull);
      expect(fake.lastEventFields, {
        'start': _ms(2026, 9, 16, 10),
        'end': _ms(2026, 9, 16, 11),
        'allDay': false,
      });
      // 9/16에 보이고 9/30에는 없다.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('cal-day-2026-09-16')),
          matching: find.text('오늘 회의'),
        ),
        findsNothing,
      );
      expect(find.textContaining('오늘 회의'), findsOneWidget);
      final moved = fake.events.single;
      expect(
        find.byKey(ValueKey('cal-bar-${moved.key}-3')),
        findsOneWidget,
        reason: '9/16은 수요일(열 3)',
      );
      expect(moved.start, _ms(2026, 9, 16, 10));
    });

    testWidgets('서버가 거절하면 원위치로 돌아가고 서버 오류 문구가 토스트로 나온다', (tester) async {
      final fake = api()..failWith = '이 일정을 수정할 권한이 없습니다.';
      final controller = await pumpScreen(tester, fake);
      final src = fake.events.single;
      final before = controller.eventsBetween(
        DateTime(2026, 9, 1),
        DateTime(2026, 10, 1),
      );
      expect(before.single.start, src.start);
      await _mouseDrag(
        tester,
        tester.getCenter(find.byKey(ValueKey('cal-bar-${src.key}-3'))),
        tester.getCenter(find.byKey(const ValueKey('cal-day-2026-09-16'))),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('이 일정을 수정할 권한이 없습니다.'), findsOneWidget);
      // 원래 자리(9/30)로 되돌아왔다.
      final after = controller.eventsBetween(
        DateTime(2026, 9, 1),
        DateTime(2026, 10, 1),
      );
      expect(after.single.start, src.start);
      expect(find.byKey(ValueKey('cal-bar-${src.key}-3')), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}

class _Quiet extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}
