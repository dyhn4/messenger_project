// 출장 캘린더(내장) — 승인된 출장 신청이 "출장" 캘린더(id 'trips', 주황)의 종일 일정으로 온다(서버 calendars.js — 팀 휴가를 보는
// 정회원 이상에게만, 장소는 출장지). 모양 읽기, 컨트롤러의 내장 캘린더 목록·숨김(로컬 저장), 상세·목록 줄의 출장 표시를 시험한다.
import 'package:client/models/calendar.dart';
import 'package:client/screens/calendar/calendar_event_widgets.dart';
import 'package:client/screens/calendar/event_detail.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/calendar_controller.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_calendar_api.dart';

CalendarController _controller(FakeCalendarApi api, {bool guest = false}) =>
    CalendarController(
      apiProvider: () => api,
      userId: () => 'me',
      isGuest: () => guest,
    );

/// 서버가 내려 주는 출장 회차(9/24~9/26 부산, 종일).
Map<String, dynamic> _tripJson() => {
  'key': 'trip:D-t:2026-09-24',
  'calendarId': 'trips',
  'source': 'trip',
  'title': '홍길동 출장 · 부산',
  'location': '부산',
  'start': allDayToMs(DateTime(2026, 9, 24)),
  'end': allDayToMs(DateTime(2026, 9, 27)),
  'allDay': true,
  'color': '#F08C00',
};

final _sep = DateTime(2026, 9, 1);
final _oct = DateTime(2026, 10, 1);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('모양 — 출장 캘린더는 내장(주황 "출장"), 회차는 source trip·종일·장소 = 출장지', () {
    final info = CalendarInfo.trips();
    expect(info.id, kTripsCalendarId);
    expect(kTripsCalendarId, 'trips');
    expect(info.name, '출장');
    expect(info.color, kTripColor);
    expect(kTripColor, '#F08C00');
    expect(info.isBuiltin, isTrue);
    expect(info.isSubscriber, isFalse, reason: '구독 취소 대상이 아니다');
    expect(CalendarInfo.trips(hidden: true).hidden, isTrue);
    expect(kBuiltinCalendarIds, contains(kTripsCalendarId));

    final trip = EventOccurrence.fromJson(_tripJson());
    expect(trip.isTrip, isTrue);
    expect(trip.isUserEvent, isFalse, reason: '고칠 수 없다');
    expect(trip.location, '부산');
    expect(trip.firstDay, DateTime(2026, 9, 24));
    expect(trip.lastDay, DateTime(2026, 9, 26));
    expect(trip.dayCount, 3);
  });

  test('정회원은 내장 캘린더에 출장이 팀 휴가 다음에 있고, 준회원은 없다', () async {
    final member = _controller(FakeCalendarApi());
    await member.setTeam('t1');
    expect(member.builtinCalendars.map((c) => c.id), [
      'holidays',
      'birthdays',
      'leaves',
      'trips',
      'bookings',
    ]);
    expect(member.calendarById('trips')?.name, '출장');

    final guest = _controller(FakeCalendarApi(), guest: true);
    await guest.setTeam('t1');
    expect(guest.builtinCalendars.map((c) => c.id), ['holidays']);
  });

  test('출장 캘린더를 숨기면 그 회차가 빠지고, 숨김은 이 기기에 저장된다', () async {
    final api = FakeCalendarApi(
      events: [EventOccurrence.fromJson(_tripJson())],
    );
    final c = _controller(api);
    await c.setTeam('t1');
    await c.watch(_sep, _oct);
    expect(c.eventsBetween(_sep, _oct).map((e) => e.title), ['홍길동 출장 · 부산']);

    await c.setHidden(CalendarInfo.trips(), true);
    expect(api.callCount('updateMySettings'), 0, reason: '내장 캘린더는 서버에 안 보낸다');
    expect(c.isHidden(kTripsCalendarId), isTrue);
    expect(c.eventsBetween(_sep, _oct), isEmpty);
    expect(c.calendarById('trips')!.hidden, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('calendar_hidden_builtin_me'), ['trips']);

    final again = _controller(api);
    await again.setTeam('t1');
    expect(again.isHidden(kTripsCalendarId), isTrue);
  });

  testWidgets('상세 — 캘린더 "출장", 출장지, 결재에서 바꾸라는 안내, 수정·삭제 없음', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    session.userId = 'me';
    final controller = _controller(FakeCalendarApi());
    await controller.setTeam('t1');
    final trip = EventOccurrence.fromJson(_tripJson());
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showEventDetail(
                context,
                session: session,
                controller: controller,
                event: trip,
              ),
              child: const Text('보기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('보기'));
    await tester.pumpAndSettle();

    expect(find.text('홍길동 출장 · 부산'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('event-detail-calendar')))
          .data,
      '출장',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('event-detail-location')))
          .data,
      '부산',
    );
    expect(find.byKey(const ValueKey('event-detail-trip')), findsOneWidget);
    expect(find.byIcon(Icons.flight_takeoff), findsOneWidget);
    expect(find.byKey(const ValueKey('event-edit')), findsNothing);
    expect(find.byKey(const ValueKey('event-delete')), findsNothing);
  });

  testWidgets('목록 줄 — 출장은 비행기 표시와 출장지', (tester) async {
    final trip = EventOccurrence.fromJson(_tripJson());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              CalendarEventTile(event: trip, onTap: () {}, calendarName: '출장'),
              CalendarEventTile(
                event: allDayEvent(
                  'e1',
                  DateTime(2026, 9, 24),
                  DateTime(2026, 9, 24),
                ),
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('event-tile-trip')), findsOneWidget);
    expect(find.text('출장 · 부산'), findsOneWidget);
  });
}
