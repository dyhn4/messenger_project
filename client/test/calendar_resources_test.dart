// 캘린더 일정의 회의실·자원 여러 개(회의실 + 장비, 5개까지) — 모양 읽기(resources·예전 resource 하나), 편집 창의 여러 개 고르기
// (resourceIds 전체를 보냄 — 모두 빼면 빈 목록), 못 잡는 자원 막기·승인 안내, "회의실 추천"(참석자 수·바꾸기), 개수 한도 안내,
// 상세의 자원 칩·"승인 대기" 꼬리표, 좁은 창(360px)에서 넘치지 않음. 서버는 가짜 HTTP(그룹웨어)와 가짜 캘린더 API.
import 'dart:convert';

import 'package:client/models/calendar.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/calendar/event_detail.dart';
import 'package:client/screens/calendar/event_editor.dart';
import 'package:client/screens/calendar/event_resource_picker.dart'
    show eventResourcesOf;
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/calendar_controller.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_calendar_api.dart';

http.Response _json(Object? body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

/// 세션(일반 멤버) + 그룹웨어 가짜 HTTP — [routes]는 'GET /api/...' 꼴, 없는 길은 404.
class _Harness {
  final requests = <http.Request>[];
  final routes = <String, http.Response Function(http.Request)>{};
  late final Session session;
  _Harness() {
    session = Session(
      notifications: _QuietNotifications(),
      settings: AppSettings(),
    );
    session.serverUrl = 'https://test.local';
    session.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: MockClient((request) async {
        requests.add(request);
        final route = routes['${request.method} ${request.url.path}'];
        return route != null
            ? route(request)
            : _json({'error': 'no route'}, status: 404);
      }),
    );
    session.userId = 'U-me';
    session.name = '나';
    session.accountRole = AccountRole.member;
    final team = Team(id: 'T1', name: '본사', createdAt: DateTime(2026));
    session.teams.add(team);
    session.currentTeam = team;
  }

  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
}

final _day = DateTime.now();
int _at(int h, [int m = 0]) =>
    DateTime(_day.year, _day.month, _day.day, h, m).millisecondsSinceEpoch;

/// 자원 목록(GET /groupware/resources) 한 줄.
Map<String, dynamic> _res(
  String id,
  String name, {
  String kind = 'room',
  bool canBook = true,
  bool needsApproval = false,
  int? capacity = 12,
  int? spare,
}) => {
  'id': id,
  'kind': kind,
  'name': name,
  'location': '3층',
  'capacity': capacity,
  'enabled': true,
  'canBook': canBook,
  'needsApproval': needsApproval,
  'spare': ?spare,
};

EventResource _er(
  String id,
  String name, {
  String kind = 'room',
  String status = 'confirmed',
}) => EventResource(
  bookingId: 'B-$id',
  resourceId: id,
  name: name,
  kind: kind,
  status: status,
);

EventOccurrence _editing({
  List<EventResource> resources = const [],
  List<Attendee> attendees = const [],
  String location = '대회의실',
}) => EventOccurrence(
  key: 'E1:${_at(10)}',
  eventId: 'E1',
  calendarId: 'cal-me',
  title: '고객 미팅',
  location: location,
  start: _at(10),
  end: _at(11),
  canEdit: true,
  canDelete: true,
  attendees: attendees,
  resource: resources.isEmpty ? null : resources.first,
  resources: resources,
);

/// 편집 창을 연다(넓은 창이면 대화상자, [size]가 좁으면 전체 화면).
Future<FakeCalendarApi> _openEditor(
  WidgetTester tester,
  _Harness h, {
  EventOccurrence? editing,
  Size size = const Size(1400, 1600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = FakeCalendarApi(events: [?editing]);
  final controller = CalendarController(
    apiProvider: () => fake,
    userId: () => 'U-me',
  );
  await controller.setTeam('t1');
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showEventEditor(
              context,
              h.session,
              controller,
              editing: editing,
              initialStart: DateTime(_day.year, _day.month, _day.day, 10),
            ),
            child: const Text('열기'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('열기'));
  await tester.pumpAndSettle();
  return fake;
}

/// 단추를 직접 누른다 — 편집 창 아래 저장 줄에 가릴 수 있어서.
Future<void> _press(WidgetTester tester, String key) async {
  tester.widget<ButtonStyleButton>(find.byKey(ValueKey(key))).onPressed!();
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('event-save')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('모양 읽기', () {
    test('resources 여러 개(승인 대기 포함), 예전 resource 하나만 와도 목록으로', () {
      final e = EventOccurrence.fromJson({
        'key': 'E1:1',
        'eventId': 'E1',
        'calendarId': 'C1',
        'title': '회의',
        'start': 1,
        'end': 2,
        'resource': {
          'bookingId': 'B1',
          'resourceId': 'R1',
          'name': '대회의실',
          'kind': 'room',
          'status': 'confirmed',
        },
        'resources': [
          {
            'bookingId': 'B1',
            'resourceId': 'R1',
            'name': '대회의실',
            'kind': 'room',
            'status': 'confirmed',
          },
          {
            'bookingId': 'B2',
            'resourceId': 'Q1',
            'name': '빔프로젝터',
            'kind': 'equipment',
            'status': 'pending',
          },
        ],
      });
      expect(e.resources.map((r) => r.resourceId), ['R1', 'Q1']);
      expect(e.resources[1].kind, 'equipment');
      expect(e.resources[1].pending, isTrue);
      expect(e.resources[0].pending, isFalse);
      expect(e.resource!.resourceId, 'R1');
      expect(eventResourcesOf(e), hasLength(2));

      // 예전 서버 — resource 하나만.
      final legacy = EventOccurrence.fromJson({
        'key': 'E2:1',
        'eventId': 'E2',
        'calendarId': 'C1',
        'title': '회의',
        'start': 1,
        'end': 2,
        'resource': {'bookingId': 'B9', 'resourceId': 'R9', 'name': '소회의실'},
      });
      expect(eventResourcesOf(legacy).single.resourceId, 'R9');
      // resources 칸 없이 만든 일정(앱 안 복사본 등)도 resource로 채운다.
      expect(
        eventResourcesOf(
          EventOccurrence(
            key: 'k',
            calendarId: 'c',
            title: 't',
            start: 1,
            end: 2,
            resource: _er('R1', '대회의실'),
          ),
        ).single.name,
        '대회의실',
      );
    });

    test('EventInput — resourceIds가 있으면 그것만(빈 목록도 보냄)', () {
      final json = const EventInput(
        title: 't',
        start: 1,
        end: 2,
        resourceId: 'R1',
        resourceIds: ['R1', 'Q1'],
      ).toJson();
      expect(json['resourceIds'], ['R1', 'Q1']);
      expect(json, isNot(contains('resourceId')));
      expect(
        const EventInput(
          title: 't',
          start: 1,
          end: 2,
          resourceIds: [],
        ).toJson()['resourceIds'],
        isEmpty,
      );
    });
  });

  group('편집 창', () {
    testWidgets('둘을 골라 만들면 resourceIds 두 개 — 못 잡는 자원은 막힘, 승인 필요 안내', (
      tester,
    ) async {
      final h = _Harness();
      h.routes['GET /api/groupware/resources'] = (_) => _json([
        _res('R1', '대회의실'),
        _res('Q1', '빔프로젝터', kind: 'equipment', needsApproval: true),
        _res('X1', '임원 회의실', canBook: false),
      ]);
      final fake = await _openEditor(tester, h);
      await tester.enterText(
        find.byKey(const ValueKey('event-title')),
        '주간 회의',
      );

      await _press(tester, 'event-resource-add');
      // 내가 못 잡는 자원은 눌러도 창이 안 닫힌다.
      expect(find.textContaining('예약할 수 있는 사람이 정해진 자원입니다.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('event-resource-X1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('event-resource-X1')), findsOneWidget);
      expect(find.textContaining('승인 필요'), findsOneWidget, reason: '빔프로젝터 줄');
      await tester.tap(find.byKey(const ValueKey('event-resource-R1')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('event-resource-chip-R1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('event-resource-approval-hint')),
        findsNothing,
      );

      // 두 번째 — 이미 붙인 R1은 체크 표시와 함께 막혀 있다.
      await _press(tester, 'event-resource-add');
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('event-resource-R1')))
            .enabled,
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('event-resource-Q1')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('event-resource-chip-Q1')),
        findsOneWidget,
      );
      expect(find.text('빔프로젝터 · 승인 필요'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('event-resource-approval-hint')),
        findsOneWidget,
      );
      // 장소는 회의실 이름으로만 채운다(장비는 장소가 아님).
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('event-location')))
            .controller!
            .text,
        '대회의실',
      );

      await _save(tester);
      expect(fake.lastCreateInput!.resourceIds, ['R1', 'Q1']);
      expect(fake.lastCreateInput!.toJson()['resourceIds'], ['R1', 'Q1']);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('붙인 것을 모두 빼고 저장하면 resourceIds 빈 목록', (tester) async {
      final h = _Harness();
      h.routes['GET /api/groupware/resources'] = (_) =>
          _json([_res('R1', '대회의실')]);
      final fake = await _openEditor(
        tester,
        h,
        editing: _editing(
          resources: [
            _er('R1', '대회의실'),
            _er('Q1', '빔프로젝터', kind: 'equipment', status: 'pending'),
          ],
        ),
      );
      expect(
        find.byKey(const ValueKey('event-resource-chip-R1')),
        findsOneWidget,
      );
      expect(find.text('빔프로젝터 · 승인 대기'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('event-resource-approval-hint')),
        findsOneWidget,
      );
      for (final id in ['R1', 'Q1']) {
        final chip = find.byKey(ValueKey('event-resource-chip-$id'));
        await _reveal(tester, chip);
        await tester.tap(
          find.descendant(of: chip, matching: find.byIcon(Icons.clear)),
        );
        await tester.pumpAndSettle();
      }
      expect(
        find.byKey(const ValueKey('event-resource-chip-R1')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('event-resource-chip-Q1')),
        findsNothing,
      );
      await _save(tester);
      expect(fake.lastEventFields!['resourceIds'], isEmpty);
      expect(fake.lastEventFields!.containsKey('resourceIds'), isTrue);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('회의실 추천 — 참석자 수(나 포함)로 묻고, 고르면 붙어 있던 회의실을 바꿈(장비는 그대로)', (
      tester,
    ) async {
      final h = _Harness();
      h.routes['GET /api/groupware/resources'] = (_) =>
          _json([_res('R1', '대회의실')]);
      h.routes['GET /api/groupware/resources/suggest'] = (_) => _json([
        _res('R3', '중회의실', capacity: 6, spare: 3, needsApproval: true),
        _res('R4', '라운지', capacity: 10, spare: 7),
      ]);
      final fake = await _openEditor(
        tester,
        h,
        editing: _editing(
          attendees: const [
            Attendee(userId: 'U-a', name: '김가'),
            Attendee(userId: 'U-b', name: '이나'),
          ],
          resources: [
            _er('R1', '대회의실'),
            _er('Q1', '빔프로젝터', kind: 'equipment'),
          ],
        ),
      );
      await _press(tester, 'event-resource-suggest');
      final q = h
          .called('GET', '/api/groupware/resources/suggest')
          .single
          .url
          .queryParameters;
      expect(q['attendees'], '3');
      expect(q['kind'], 'room');
      expect(q['eventId'], 'E1');
      expect(int.parse(q['start']!), _at(10));
      expect(int.parse(q['end']!), _at(11));
      expect(find.text('회의실 추천'), findsWidgets);
      expect(find.text('3층 · 6명 · 3자리 남음 · 승인 필요'), findsOneWidget);
      expect(find.text('3층 · 10명 · 7자리 남음'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('event-resource-suggest-R3')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('event-resource-chip-R1')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('event-resource-chip-R3')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('event-resource-chip-Q1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('event-resource-approval-hint')),
        findsOneWidget,
      );
      // 장소가 바꾼 회의실 이름 그대로였으니 따라 바뀐다.
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('event-location')))
            .controller!
            .text,
        '중회의실',
      );
      await _save(tester);
      expect(fake.lastEventFields!['resourceIds'], ['Q1', 'R3']);
      expect(fake.lastEventFields!['location'], '중회의실');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('새 일정의 추천은 나 혼자 — attendees=1, 빈 결과 안내', (tester) async {
      final h = _Harness();
      h.routes['GET /api/groupware/resources'] = (_) =>
          _json([_res('R1', '대회의실')]);
      h.routes['GET /api/groupware/resources/suggest'] = (_) => _json([]);
      await _openEditor(tester, h);
      await _press(tester, 'event-resource-suggest');
      expect(
        h
            .called('GET', '/api/groupware/resources/suggest')
            .single
            .url
            .queryParameters['attendees'],
        '1',
      );
      expect(
        find.byKey(const ValueKey('event-resource-suggest-empty')),
        findsOneWidget,
      );
    });

    testWidgets('5개가 붙어 있으면 더 붙이지 못한다는 안내(고르기 창은 안 열림)', (tester) async {
      final h = _Harness();
      h.routes['GET /api/groupware/resources'] = (_) =>
          _json([_res('R1', '대회의실')]);
      h.routes['GET /api/groupware/resources/suggest'] = (_) => _json([]);
      await _openEditor(
        tester,
        h,
        editing: _editing(
          resources: [
            for (var i = 1; i <= 5; i++) _er('Q$i', '장비 $i', kind: 'equipment'),
          ],
        ),
      );
      final before = h.called('GET', '/api/groupware/resources').length;
      await _press(tester, 'event-resource-add');
      expect(find.text('회의실·자원은 5개까지 붙일 수 있습니다.'), findsOneWidget);
      expect(
        h.called('GET', '/api/groupware/resources').length,
        before,
        reason: '고르기 창을 열지 않음',
      );
      await tester.pump(const Duration(seconds: 3));
      // 회의실이 없는데 다 찼으면 추천도 막는다.
      await _press(tester, 'event-resource-suggest');
      expect(find.text('회의실·자원은 5개까지 붙일 수 있습니다.'), findsOneWidget);
      expect(h.called('GET', '/api/groupware/resources/suggest'), isEmpty);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('반복을 켜면 추가·추천 단추가 숨고, 붙인 채 저장하면 막힘', (tester) async {
      final h = _Harness();
      h.routes['GET /api/groupware/resources'] = (_) =>
          _json([_res('R1', '대회의실')]);
      final fake = await _openEditor(
        tester,
        h,
        editing: _editing(resources: [_er('R1', '대회의실')]),
      );
      expect(find.byKey(const ValueKey('event-resource-add')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('event-resource-suggest')),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('event-repeat')));
      await tester.tap(find.byKey(const ValueKey('event-repeat')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('매일').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('event-resource-add')), findsNothing);
      expect(
        find.byKey(const ValueKey('event-resource-suggest')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('event-resource-chip-R1')),
        findsOneWidget,
        reason: '붙인 것은 뺄 수 있게 남김',
      );
      await _save(tester);
      expect(fake.lastEventFields, isNull, reason: '저장이 막힘');
      expect(
        find.text('회의실·자원을 잡은 일정은 반복할 수 없습니다. 회의실·자원을 빼거나 반복을 끄세요.'),
        findsOneWidget,
      );
    });

    testWidgets('좁은 창(360px)에서 긴 이름 자원 칩·단추가 넘치지 않음', (tester) async {
      final h = _Harness();
      h.routes['GET /api/groupware/resources'] = (_) =>
          _json([_res('R1', '대회의실')]);
      await _openEditor(
        tester,
        h,
        size: const Size(360, 780),
        editing: _editing(
          resources: [
            _er('R1', '본관 12층 대형 회의실 (화상회의 장비 완비, 최대 40명)'),
            _er(
              'Q1',
              '이동식 빔프로젝터와 스크린 세트 2호기',
              kind: 'equipment',
              status: 'pending',
            ),
          ],
        ),
      );
      await _reveal(tester, find.byKey(const ValueKey('event-resource-add')));
      expect(
        find.byKey(const ValueKey('event-resource-chip-Q1')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('상세', () {
    Future<void> showDetail(
      WidgetTester tester,
      EventOccurrence e, {
      Size size = const Size(1400, 1600),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = _Harness();
      final fake = FakeCalendarApi();
      final controller = CalendarController(
        apiProvider: () => fake,
        userId: () => 'U-me',
      );
      await controller.setTeam('t1');
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showEventDetail(
                  context,
                  session: h.session,
                  controller: controller,
                  event: e,
                ),
                child: const Text('보기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('보기'));
      await tester.pumpAndSettle();
    }

    testWidgets('자원 둘 — 칩마다 이름, 승인 대기 꼬리표, 장소가 자원 이름이면 한 번만', (tester) async {
      await showDetail(
        tester,
        _editing(
          location: '빔프로젝터',
          resources: [
            _er('R1', '대회의실'),
            _er('Q1', '빔프로젝터', kind: 'equipment', status: 'pending'),
          ],
        ),
      );
      final r1 = find.byKey(const ValueKey('event-detail-resource-R1'));
      final q1 = find.byKey(const ValueKey('event-detail-resource-Q1'));
      expect(r1, findsOneWidget);
      expect(q1, findsOneWidget);
      expect(
        find.descendant(of: r1, matching: find.text('대회의실')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: q1, matching: find.text('승인 대기')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: r1, matching: find.text('승인 대기')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: q1,
          matching: find.byIcon(Icons.devices_other_outlined),
        ),
        findsOneWidget,
      );
      expect(find.text('빔프로젝터'), findsOneWidget, reason: '장소 줄은 숨김');
      expect(find.byKey(const ValueKey('event-detail-location')), findsNothing);
    });

    testWidgets('장소가 자원 이름과 다르면 장소 줄도, 좁은 창에서 넘치지 않음', (tester) async {
      await showDetail(
        tester,
        size: const Size(360, 780),
        _editing(
          location: '본사 3층',
          resources: [
            _er('R1', '본관 12층 대형 회의실 (화상회의 장비 완비, 최대 40명)'),
            _er('Q1', '이동식 빔프로젝터와 스크린 세트 2호기', status: 'pending'),
          ],
        ),
      );
      expect(
        find.byKey(const ValueKey('event-detail-location')),
        findsOneWidget,
      );
      expect(find.text('승인 대기'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
