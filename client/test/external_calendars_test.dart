import 'dart:convert';

import 'package:client/models/calendar.dart';
import 'package:client/screens/calendar/calendar_common.dart';
import 'package:client/screens/calendar/calendar_list_panel.dart';
import 'package:client/screens/calendar/external_calendar_dialogs.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/calendar_api.dart';
import 'package:client/services/calendar_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_calendar_api.dart';

/// 외부 캘린더 연동 — ICS 주소 구독(가져오기, 나에게만·읽기 전용)과 내 일정 ICS 구독 주소(내보내기).
/// 서버는 server/src/externalCalendars.js·calendarFeeds.js.

CalendarInfo _external({String? lastError}) => CalendarInfo(
  id: 'ext:c1',
  teamId: 't1',
  kind: 'external',
  name: '회사 Google',
  color: '#039BE5',
  role: 'subscriber',
  canDelete: true,
  host: 'calendar.google.com',
  lastSuccessAt: DateTime(2026, 10, 14, 9),
  lastError: lastError,
);

CalendarController _controller(FakeCalendarApi api) => CalendarController(
  apiProvider: () => api,
  userId: () => 'me',
  isGuest: () => false,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('모양 읽기: 외부 캘린더(ext: id)·외부 일정(읽기 전용)·내보내기 주소', () {
    final c = CalendarInfo.fromJson({
      'id': 'ext:c1',
      'teamId': 't1',
      'kind': 'external',
      'name': '회사 Google',
      'color': '#039BE5',
      'role': 'subscriber',
      'hidden': false,
      'canDelete': true,
      'host': 'calendar.google.com',
      'lastSuccessAt': DateTime(2026, 10, 14, 9).millisecondsSinceEpoch,
      'lastError': null,
    });
    expect(c.isExternal, isTrue);
    expect(c.isSubscriber, isFalse, reason: '구독 취소(leave)가 아니라 구독 해지로 끊는다');
    expect(c.isBuiltin, isFalse);
    expect(c.host, 'calendar.google.com');
    expect(c.lastSuccessAt, DateTime(2026, 10, 14, 9));
    expect(c.copyWith(hidden: true).host, 'calendar.google.com');
    expect(externalCalendarKey('ext:c1'), 'c1');
    expect(isExternalCalendarId('cal-me'), isFalse);

    final e = EventOccurrence.fromJson({
      'key': 'ext:c1:uid:1',
      'calendarId': 'ext:c1',
      'source': 'external',
      'title': '분기 회의',
      'start': 0,
      'end': 3600000,
    });
    expect(e.isExternal, isTrue);
    expect(e.isUserEvent, isFalse);

    final feed = CalendarFeed.fromJson({
      'url': 'https://chat.example.com/calendar-feed/abc.ics',
      'publicAddress': true,
      'createdAt': 0,
      'lastAccessAt': null,
    });
    expect(feed.url, endsWith('.ics'));
    expect(feed.lastAccessAt, isNull);
  });

  test('상태 문구: 호스트·마지막 업데이트, 실패하면 그 이유', () {
    final now = DateTime(2026, 10, 14, 9, 12);
    expect(
      externalStatusLabel(_external(), now: now),
      'calendar.google.com · 12분 전 업데이트',
    );
    expect(
      externalStatusLabel(_external(lastError: '캘린더를 받지 못했습니다.'), now: now),
      '캘린더를 받지 못했습니다.',
    );
    expect(externalUpdatedLabel(DateTime(2026, 10, 12), now: now), '10/12');
  });

  test('실제 API: 목록의 external, 외부 캘린더의 색·숨김·새로고침·해지·추가와 내보내기 주소의 경로', () async {
    final requests = <http.Request>[];
    final api = RemoteCalendarApi(
      ApiClient(
        baseUrl: 'https://192.168.0.10:3000',
        token: 't',
        httpClient: MockClient((request) async {
          requests.add(request);
          final path = request.url.path;
          final ext = {
            'id': 'ext:c1',
            'kind': 'external',
            'name': '회사',
            'color': '#039BE5',
            'role': 'subscriber',
          };
          Object body = ext;
          if (path == '/api/teams/t1/calendars') {
            body = {
              'mine': [],
              'subscribed': [],
              'external': [ext],
            };
          } else if (path.endsWith('/calendar-feed')) {
            body = {'url': null, 'publicAddress': false};
          } else if (request.method == 'DELETE') {
            body = {'ok': true};
          }
          return http.Response(
            jsonEncode(body),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      ),
    );
    final lists = await api.fetchCalendars('t1');
    expect(lists.external.single.isExternal, isTrue);
    await api.updateMySettings('ext:c1', hidden: true);
    await api.updateMySettings('cal-me', color: '#000000');
    await api.refreshExternalCalendar('ext:c1');
    await api.deleteExternalCalendar('ext:c1');
    await api.addExternalCalendar('t1', url: 'webcal://example.com/a.ics');
    await api.createCalendarFeed('t1');
    await api.deleteCalendarFeed('t1');
    expect(requests.map((r) => '${r.method} ${r.url.path}').toList(), [
      'GET /api/teams/t1/calendars',
      'PATCH /api/external-calendars/c1',
      'PATCH /api/calendars/cal-me/me',
      'POST /api/external-calendars/c1/refresh',
      'DELETE /api/external-calendars/c1',
      'POST /api/teams/t1/external-calendars',
      'POST /api/teams/t1/calendar-feed',
      'DELETE /api/teams/t1/calendar-feed',
    ]);
    expect(jsonDecode(requests[5].body), {'url': 'webcal://example.com/a.ics'});
  });

  test('컨트롤러: 외부 캘린더도 목록·숨김·id 찾기에 들어가고, 추가·해지하면 목록을 다시 받는다', () async {
    final api = FakeCalendarApi()..external = [_external()];
    final c = _controller(api);
    await c.setTeam('t1');
    expect(c.external.map((e) => e.id), ['ext:c1']);
    expect(c.calendarById('ext:c1')?.name, '회사 Google');
    expect(c.subscribedGroup.any((e) => e.isExternal), isFalse);
    expect(c.writableCalendars.any((e) => e.isExternal), isFalse);

    await c.setHidden(c.external.single, true);
    expect(
      api.calls,
      contains('updateMySettings ext:c1 color=null hidden=true'),
    );
    expect(c.isHidden('ext:c1'), isTrue);

    await c.addExternalCalendar('https://outlook.office365.com/a.ics');
    expect(c.external, hasLength(2));
    await c.removeExternalCalendar(c.external.first);
    expect(c.external.map((e) => e.id), ['ext:x2']);
  });

  testWidgets('목록: "외부 캘린더" 묶음에 상태가 보이고, ⋯ 메뉴로 새로고침·구독 해지', (tester) async {
    final api = FakeCalendarApi()
      ..external = [_external(lastError: '주소에 접근할 권한이 없습니다.')];
    final controller = _controller(api);
    await controller.setTeam('t1');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: CalendarListPanel(
              controller: controller,
              hooks: const CalendarManagementHooks(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('외부 캘린더'), findsOneWidget);
    expect(find.text('회사 Google'), findsOneWidget);
    expect(find.text('주소에 접근할 권한이 없습니다.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('cal-menu-ext:c1')));
    await tester.pumpAndSettle();
    expect(find.text('캘린더 설정'), findsNothing);
    await tester.tap(find.text('지금 새로고침'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('refreshExternalCalendar ext:c1'));
    await tester.pump(const Duration(seconds: 3));

    await tester.tap(find.byKey(const ValueKey('cal-menu-ext:c1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('구독 해지'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ext-remove-confirm')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('deleteExternalCalendar ext:c1'));
    expect(find.text('회사 Google'), findsNothing);
  });

  testWidgets('외부 캘린더 추가: 주소를 넣으면 구독하고, 서버가 거절하면 그 이유를 보여 준다', (tester) async {
    final api = FakeCalendarApi();
    final controller = _controller(api);
    await controller.setTeam('t1');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: CalendarListPanel(
              controller: controller,
              hooks: const CalendarManagementHooks(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('cal-add-external')));
    await tester.pumpAndSettle();

    api.failWith = 'ICS 캘린더가 아닙니다.';
    await tester.enterText(
      find.byKey(const ValueKey('ext-url')),
      'https://example.com/',
    );
    await tester.tap(find.byKey(const ValueKey('ext-submit')));
    await tester.pumpAndSettle();
    expect(find.text('ICS 캘린더가 아닙니다.'), findsOneWidget);

    api.failWith = null;
    await tester.enterText(
      find.byKey(const ValueKey('ext-url')),
      'webcal://calendar.google.com/x/basic.ics',
    );
    await tester.enterText(find.byKey(const ValueKey('ext-name')), '회사 일정');
    await tester.tap(find.byKey(const ValueKey('ext-submit')));
    await tester.pumpAndSettle();
    expect(
      api.calls,
      contains(
        'addExternalCalendar webcal://calendar.google.com/x/basic.ics name=회사 일정',
      ),
    );
    expect(find.byKey(const ValueKey('ext-url')), findsNothing);
    expect(find.text('회사 일정'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('내 일정 내보내기: 주소를 만들고, 바꾸면 새 주소, 끄면 없어진다', (tester) async {
    final api = FakeCalendarApi();
    final controller = _controller(api);
    await controller.setTeam('t1');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCalendarFeedDialog(context, controller),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('feed-create')));
    await tester.pumpAndSettle();
    expect(
      find.text('https://chat.example.com/calendar-feed/token1.ics'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('feed-no-public')), findsNothing);
    await tester.pump(const Duration(seconds: 3));

    await tester.tap(find.byKey(const ValueKey('feed-reset')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('feed-reset-confirm')));
    await tester.pumpAndSettle();
    expect(
      find.text('https://chat.example.com/calendar-feed/token2.ics'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 3));

    await tester.tap(find.byKey(const ValueKey('feed-delete')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('feed-create')), findsOneWidget);
    expect(api.feedUrl, isNull);
    await tester.pump(const Duration(seconds: 3));
  });
}
