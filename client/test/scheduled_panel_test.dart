import 'dart:convert';

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/desktop_home_screen.dart';
import 'package:client/screens/schedule_message_dialog.dart';
import 'package:client/screens/scheduled_messages_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/services/time_format.dart';
import 'package:client/services/typing_gate.dart';
import 'package:client/widgets/app_menu_button.dart';
import 'package:client/widgets/scheduled_panel.dart';
import 'package:client/widgets/side_panels.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 메시지 예약 패널(widgets/scheduled_panel.dart — [메뉴] > 생성 > 메시지 예약) — PC 오른쪽 패널·모바일 전체 화면으로
/// 열리기, 머리·만들기·필터·정렬·개수 줄, 카드 모양, ⋯ 동작(수정·지금 보내기·예약 취소·삭제), 실시간 반영, 불러오기 실패.

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

/// 서버의 예약 목록 흉내 — 취소·지금 보내기가 실제로 목록을 바꿔서 다시 받아도 맞는 목록이 온다.
class _Server {
  final requests = <http.Request>[];
  final rows = <Map<String, dynamic>>[];

  /// true면 GET 목록이 500으로 실패한다.
  bool failList = false;

  late final client = MockClient((r) async {
    requests.add(r);
    final path = r.url.path;
    if (path == '/api/scheduled-messages' && r.method == 'GET') {
      if (failList) return _json({'error': '잠시 후 다시 시도하세요.'}, 500);
      return _json(rows);
    }
    final segs = r.url.pathSegments;
    if (path.startsWith('/api/scheduled-messages/')) {
      if (r.method == 'DELETE') {
        rows.removeWhere((x) => x['id'] == segs.last);
        return _json({'ok': true});
      }
      if (r.method == 'POST' && segs.last == 'send-now') {
        final id = segs[segs.length - 2];
        rows.removeWhere((x) => x['id'] == id);
        return _json({
          'ok': true,
          'messageIds': ['m-$id'],
        });
      }
    }
    if (path == '/api/favorites' || path == '/api/my-posts') {
      return _json({'items': <Object>[], 'hasMore': false});
    }
    return _json(<Object>[]);
  });

  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
}

final _later = defaultScheduleTime().add(const Duration(hours: 2));

Map<String, dynamic> _row(
  String id, {
  String? roomId = 'r1',
  String? roomName = '공지방',
  String? title,
  String text = '예약한 메시지',
  DateTime? sendAt,
  int createdAt = 1000,
  String status = 'scheduled',
  String? failReason,
  int files = 0,
}) => {
  'id': id,
  'teamId': 't1',
  'roomId': roomId,
  'roomName': roomName,
  'title': title,
  'text': text,
  'textFormat': null,
  'attachments': [
    for (var i = 0; i < files; i++)
      {
        'id': 'a-$id-$i',
        'kind': 'file',
        'fileUrl': '/files/f$i.pdf?sig=x',
        'fileName': 'f$i.pdf',
        'fileSize': 2048,
        'mimeType': 'application/pdf',
      },
  ],
  'sendAt': (sendAt ?? _later).millisecondsSinceEpoch,
  'status': status,
  'failReason': failReason,
  'createdAt': createdAt,
  'updatedAt': createdAt,
};

Map<String, dynamic> _user(String id, String name) => {
  'id': id,
  'username': id,
  'name': name,
  'role': 'member',
};

final _members = [_user('me', '나'), _user('u2', '김철수')];

Room _topic(
  String id,
  String name, {
  bool board = false,
  bool readOnly = false,
}) => Room.fromJson({
  'id': id,
  'teamId': 't1',
  'type': 'topic',
  'name': name,
  'members': _members,
  'createdAt': 1000,
  'viewMode': board ? 'board' : 'chat',
  'readOnly': readOnly,
});

List<Room> _rooms() => [
  _topic('r1', '공지방'),
  _topic('r-board', '주간 보고', board: true),
  _topic('r-ro', '읽기전용방', readOnly: true),
  Room.fromJson({
    'id': 'r-dm',
    'teamId': 't1',
    'type': 'dm',
    'name': null,
    'members': [_user('me', '나'), _user('u2', '김철수')],
    'createdAt': 1000,
  }),
];

({_Server server, Session session}) _setup([
  List<Map<String, dynamic>> rows = const [],
]) {
  final server = _Server()..rows.addAll(rows);
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
  session.rooms.addAll(_rooms());
  return (server: server, session: session);
}

/// 네 건 — 발송 실패 하나(삭제된 방), 공지방(첨부 2), 주간 보고(게시글), 김철수(1:1). 생성 순서는 s3 → s1 → s2 → f1.
List<Map<String, dynamic>> _fourRows() => [
  _row('s1', text: '회의 자료 공유드립니다', sendAt: _later, createdAt: 2000, files: 2),
  _row(
    's2',
    roomId: 'r-board',
    roomName: '주간 보고',
    title: '주간 보고서',
    text: '본문',
    sendAt: _later.add(const Duration(days: 1)),
    createdAt: 3000,
  ),
  _row(
    's3',
    roomId: 'r-dm',
    roomName: null,
    text: '생일 축하해요',
    sendAt: _later.add(const Duration(days: 2)),
    createdAt: 1000,
  ),
  _row(
    'f1',
    roomId: null,
    roomName: '지난 행사',
    text: '행사 안내',
    sendAt: DateTime.now().subtract(const Duration(hours: 1)),
    createdAt: 4000,
    status: 'failed',
    failReason: '대화방이 삭제되어 보낼 수 없습니다.',
  ),
];

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 패널만 띄운다(폭 420, 창 1280 — 편집기는 대화상자로 열린다). [currentRoomId]를 주면 홈 화면 손잡이를 흉내 낸다.
Future<void> _pumpPanel(
  WidgetTester tester,
  Session session, {
  String? currentRoomId,
  VoidCallback? onClose,
}) async {
  _size(tester, const Size(1280, 900));
  Widget panel = ScheduledPanel(session: session, onClose: onClose);
  if (currentRoomId != null) {
    panel = HomeShellScope(
      openPanelKey: 'scheduled',
      panelRoom: null,
      panelGeneration: 0,
      currentRoomId: currentRoomId,
      togglePanel: (_) {},
      closePanel: () {},
      toggleCalendar: () {},
      openRoom: (_, {messageId}) {},
      child: panel,
    );
  }
  await tester.pumpWidget(
    MaterialApp(
      // 한 테스트에서 다시 올리면 새 패널로 시작한다.
      key: UniqueKey(),
      home: ScheduledMessageToasts(
        session: session,
        child: Scaffold(
          body: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(width: 420, child: panel),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 떠 있는 알림(토스트)의 타이머가 테스트 끝까지 남지 않게 흘려보낸다.
Future<void> _flushToasts(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(seconds: 5));
  }
  await tester.pumpAndSettle();
}

Finder _card(String id) => find.byKey(ValueKey('scheduled-panel-card-$id'));

/// 보이는 카드 id들(위에서 아래 순서).
List<String> _cardOrder(WidgetTester tester) {
  final cards = find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('scheduled-panel-card-'),
  );
  final entries = [
    for (final e in cards.evaluate())
      (
        ((e.widget.key! as ValueKey<String>).value).substring(
          'scheduled-panel-card-'.length,
        ),
        tester.getTopLeft(find.byWidget(e.widget)).dy,
      ),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  return [for (final (id, _) in entries) id];
}

Future<void> _cardMenu(WidgetTester tester, String id, String label) async {
  await tester.tap(find.byKey(ValueKey('scheduled-panel-more-$id')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

String _countText(WidgetTester tester) {
  final text = tester.widget<Text>(
    find.byKey(const ValueKey('scheduled-panel-count')),
  );
  return text.textSpan!.toPlainText();
}

void main() {
  group('filterScheduledMessages', () {
    final all = [for (final r in _fourRows()) ScheduledMessage.fromJson(r)];

    test('발송 시간 순은 발송 실패 먼저, 그다음 보낼 시각 순', () {
      expect(filterScheduledMessages(all).map((m) => m.id), [
        'f1',
        's1',
        's2',
        's3',
      ]);
    });

    test('생성 순은 발송 실패 먼저, 그다음 최근에 만든 순', () {
      expect(
        filterScheduledMessages(
          all,
          sort: ScheduledSort.created,
        ).map((m) => m.id),
        ['f1', 's2', 's1', 's3'],
      );
    });

    test('대화방·상태로 거른다(보내는 중은 예약됨에 든다)', () {
      expect(filterScheduledMessages(all, roomId: 'r-board').map((m) => m.id), [
        's2',
      ]);
      expect(
        filterScheduledMessages(
          all,
          status: ScheduledStatusFilter.failed,
        ).map((m) => m.id),
        ['f1'],
      );
      final sending = all[0].withStatus(ScheduledMessageStatus.sending);
      expect(
        filterScheduledMessages([
          sending,
          all[3],
        ], status: ScheduledStatusFilter.scheduled).map((m) => m.id),
        ['s1'],
      );
    });
  });

  group('열기', () {
    testWidgets('메뉴 > 메시지 예약은 메시지 예약 패널로 등록돼 있다', (tester) async {
      final spec = sidePanelSpecFor('scheduled');
      expect(spec, isNotNull);
      expect(spec!.title, '메시지 예약');
      expect(spec.ownHeader, isTrue);
    });

    testWidgets('PC: 메뉴 타일을 누르면 오른쪽 패널로 열리고, 다시 누르면 닫힌다', (tester) async {
      final t = _setup([_row('s1', text: '회의 자료 공유드립니다')]);
      _size(tester, const Size(1400, 1000));
      await tester.pumpWidget(
        MaterialApp(home: DesktopHomeScreen(session: t.session)),
      );
      await tester.pumpAndSettle();

      Future<void> tapTile() async {
        await tester.tap(find.byTooltip('메뉴'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('menu-schedule')));
        await tester.pumpAndSettle();
      }

      await tapTile();
      expect(find.byType(ScheduledPanel), findsOneWidget);
      expect(find.byType(ScheduledMessagesScreen), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      // 오른쪽에 붙는다.
      expect(
        tester.getTopLeft(find.byType(ScheduledPanel)).dx,
        greaterThan(900),
      );
      expect(find.text('회의 자료 공유드립니다', findRichText: true), findsOneWidget);

      await tapTile();
      expect(find.byType(ScheduledPanel), findsNothing);

      TypingGate.instance.reset();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('모바일(360): 메뉴 타일을 누르면 전체 화면으로 열리고 ✕로 닫힌다', (tester) async {
      final t = _setup([_row('s1')]);
      _size(tester, const Size(360, 740));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(actions: [AppMenuButton(session: t.session)]),
          ),
        ),
      );
      await tester.tap(find.byTooltip('메뉴'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-schedule')));
      await tester.pumpAndSettle();

      expect(find.byType(ScheduledPanel), findsOneWidget);
      expect(tester.getSize(find.byType(ScheduledPanel)).width, 360);
      expect(find.byType(AppBar), findsNothing); // 패널이 자기 머리를 그린다
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('scheduled-panel-close')));
      await tester.pumpAndSettle();
      expect(find.byType(ScheduledPanel), findsNothing);
    });
  });

  group('목록', () {
    testWidgets('머리·만들기·필터·정렬·한도, 개수 줄과 카드(발송 예정·대화방·첨부·게시글·발송 실패)', (
      tester,
    ) async {
      final t = _setup(_fourRows());
      await _pumpPanel(tester, t.session);

      expect(t.server.called('GET', '/api/scheduled-messages'), hasLength(1));
      expect(find.text('메시지 예약'), findsNWidgets(2)); // 머리 + 만들기 단추
      expect(
        find.byKey(const ValueKey('scheduled-panel-create')),
        findsOneWidget,
      );
      expect(find.text('참여한 대화방'), findsOneWidget);
      expect(find.text('모든 예약'), findsOneWidget);
      expect(find.text('발송 시간 순'), findsOneWidget);
      expect(find.text('예약 4/30', findRichText: true), findsOneWidget);
      expect(_countText(tester), '4개의 예약 메시지');
      expect(_cardOrder(tester), ['f1', 's1', 's2', 's3']);

      // 예약됨 카드 — `발송 예정 : 시각`, 대화방 이름, 첨부 수, 미리보기.
      expect(
        find.descendant(of: _card('s1'), matching: find.text('발송 예정 : ')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('scheduled-panel-time-s1')))
            .data,
        formatScheduleTime(_later),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('scheduled-panel-room-s1')))
            .data,
        '공지방',
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('scheduled-panel-clips-s1')),
            )
            .data,
        '2',
      );
      // 게시글 예약은 `게시글` 표 + 제목, 1:1은 상대 이름.
      expect(
        find.descendant(of: _card('s2'), matching: find.text('게시글')),
        findsOneWidget,
      );
      expect(find.textContaining('주간 보고서', findRichText: true), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('scheduled-panel-room-s3')))
            .data,
        '김철수',
      );
      // 발송 실패 — `발송 예정 :` 대신 빨간 표, 사라진 방은 예약 때 이름, 사유.
      expect(
        find.byKey(const ValueKey('scheduled-panel-failed-f1')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _card('f1'), matching: find.text('발송 예정 : ')),
        findsNothing,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('scheduled-panel-room-f1')))
            .data,
        '지난 행사',
      );
      expect(
        find.byKey(const ValueKey('scheduled-panel-reason-f1')),
        findsOneWidget,
      );
      expect(find.text('대화방이 삭제되어 보낼 수 없습니다.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('대화방·상태 필터와 정렬, 걸러서 없으면 안내', (tester) async {
      final t = _setup(_fourRows());
      await _pumpPanel(tester, t.session);

      // 상태 — 발송 실패만.
      await tester.tap(find.byKey(const ValueKey('scheduled-panel-status')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('scheduled-status-failed')));
      await tester.pumpAndSettle();
      expect(find.text('발송 실패'), findsWidgets);
      expect(_cardOrder(tester), ['f1']);
      expect(_countText(tester), '1개의 예약 메시지');

      // 예약됨.
      await tester.tap(find.byKey(const ValueKey('scheduled-panel-status')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('scheduled-status-scheduled')),
      );
      await tester.pumpAndSettle();
      expect(_cardOrder(tester), ['s1', 's2', 's3']);

      // 생성 순(최근에 만든 순).
      await tester.tap(find.byKey(const ValueKey('scheduled-panel-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('scheduled-sort-created')));
      await tester.pumpAndSettle();
      expect(find.text('생성 순'), findsOneWidget);
      expect(_cardOrder(tester), ['s2', 's1', 's3']);

      // 대화방 — 주간 보고만.
      await tester.tap(find.byKey(const ValueKey('scheduled-panel-room')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('주간 보고').last);
      await tester.pumpAndSettle();
      expect(_cardOrder(tester), ['s2']);
      expect(_countText(tester), '1개의 예약 메시지');

      // 그 방에 발송 실패는 없다.
      await tester.tap(find.byKey(const ValueKey('scheduled-panel-status')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('scheduled-status-failed')));
      await tester.pumpAndSettle();
      expect(_cardOrder(tester), isEmpty);
      expect(_countText(tester), '0개의 예약 메시지');
      expect(find.text('발송에 실패한 예약 메시지가 없어요.'), findsOneWidget);
    });

    testWidgets('예약이 하나도 없으면 안내, 30건이면 만들기가 막힌다', (tester) async {
      final empty = _setup();
      await _pumpPanel(tester, empty.session);
      expect(find.text('예약된 메시지가 없어요.'), findsOneWidget);
      expect(_countText(tester), '0개의 예약 메시지');

      final full = _setup([for (var i = 0; i < 30; i++) _row('s$i')]);
      await _pumpPanel(tester, full.session);
      expect(find.text('예약 30/30', findRichText: true), findsOneWidget);
      final create = tester.widget<ButtonStyleButton>(
        find.byKey(const ValueKey('scheduled-panel-create')),
      );
      expect(create.onPressed, isNull);
    });

    testWidgets('처음 불러오기가 실패하면 다시 시도할 수 있다', (tester) async {
      final t = _setup([_row('s1', text: '첫 예약')]);
      t.server.failList = true;
      await _pumpPanel(tester, t.session);
      expect(find.text('예약 목록을 불러오지 못했습니다.'), findsOneWidget);
      expect(find.byKey(const ValueKey('scheduled-panel-count')), findsNothing);

      t.server.failList = false;
      await tester.tap(find.byKey(const ValueKey('scheduled-panel-retry')));
      await tester.pumpAndSettle();
      expect(find.text('첫 예약', findRichText: true), findsOneWidget);
      expect(_countText(tester), '1개의 예약 메시지');
    });
  });

  group('만들기·⋯ 동작', () {
    testWidgets('+ 메시지 예약 — 지금 연 방(예약할 수 있을 때), 대화방 필터를 골랐으면 그 방을 미리 고른다', (
      tester,
    ) async {
      final t = _setup();
      await _pumpPanel(tester, t.session, currentRoomId: 'r1');
      await tester.tap(find.byKey(const ValueKey('scheduled-panel-create')));
      await tester.pumpAndSettle();
      var editor = tester.widget<ScheduleMessageEditor>(
        find.byType(ScheduleMessageEditor),
      );
      expect(editor.room?.id, 'r1');
      expect(editor.editing, isNull);
      expect(find.byType(Dialog), findsOneWidget); // PC는 대화상자
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleMessageEditor), findsNothing);

      // 대화방 필터가 먼저다.
      await tester.tap(find.byKey(const ValueKey('scheduled-panel-room')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('주간 보고').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('scheduled-panel-create')));
      await tester.pumpAndSettle();
      editor = tester.widget<ScheduleMessageEditor>(
        find.byType(ScheduleMessageEditor),
      );
      expect(editor.room?.id, 'r-board');
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();

      // 지금 연 방에 쓸 수 없으면(읽기 전용) 비워 둔다.
      await _pumpPanel(tester, t.session, currentRoomId: 'r-ro');
      await tester.tap(find.byKey(const ValueKey('scheduled-panel-create')));
      await tester.pumpAndSettle();
      editor = tester.widget<ScheduleMessageEditor>(
        find.byType(ScheduleMessageEditor),
      );
      expect(editor.room, isNull);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
    });

    testWidgets('카드를 누르거나 ⋯ > 수정이면 그 예약의 수정 창', (tester) async {
      final t = _setup(_fourRows());
      await _pumpPanel(tester, t.session);
      await tester.tap(find.text('회의 자료 공유드립니다', findRichText: true));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ScheduleMessageEditor>(find.byType(ScheduleMessageEditor))
            .editing
            ?.id,
        's1',
      );
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();

      await _cardMenu(tester, 's3', '수정');
      expect(
        tester
            .widget<ScheduleMessageEditor>(find.byType(ScheduleMessageEditor))
            .editing
            ?.id,
        's3',
      );
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
    });

    testWidgets('⋯ > 지금 보내기 · 예약 취소 — 묻고 나서 서버에 보내고 카드가 사라진다', (tester) async {
      final t = _setup(_fourRows());
      await _pumpPanel(tester, t.session);

      await _cardMenu(tester, 's1', '지금 보내기');
      expect(find.text("예약 시간을 기다리지 않고 '공지방'에 지금 바로 보낼까요?"), findsOneWidget);
      await tester.tap(find.text('보내기'));
      await tester.pumpAndSettle();
      expect(
        t.server.called('POST', '/api/scheduled-messages/s1/send-now'),
        hasLength(1),
      );
      expect(_card('s1'), findsNothing);
      expect(find.text('예약 메시지를 보냈습니다 · 공지방'), findsOneWidget); // 루트 토스트
      expect(_countText(tester), '3개의 예약 메시지');

      await _cardMenu(tester, 's2', '예약 취소');
      expect(find.textContaining('예약을 취소할까요?'), findsOneWidget);
      await tester.tap(find.text('예약 취소').last);
      await tester.pumpAndSettle();
      expect(
        t.server.called('DELETE', '/api/scheduled-messages/s2'),
        hasLength(1),
      );
      expect(_card('s2'), findsNothing);
      expect(_countText(tester), '2개의 예약 메시지');
      await _flushToasts(tester);
    });

    testWidgets('발송 실패 카드의 ⋯는 수정해서 다시 예약·삭제(지금 보내기는 없다)', (tester) async {
      final t = _setup(_fourRows());
      await _pumpPanel(tester, t.session);
      await tester.tap(find.byKey(const ValueKey('scheduled-panel-more-f1')));
      await tester.pumpAndSettle();
      expect(find.text('수정해서 다시 예약'), findsOneWidget);
      expect(find.text('지금 보내기'), findsNothing);
      await tester.tap(find.text('삭제'));
      await tester.pumpAndSettle();
      expect(find.text('보내지 못한 예약 메시지를 삭제할까요?'), findsOneWidget);
      await tester.tap(find.text('삭제').last);
      await tester.pumpAndSettle();
      expect(
        t.server.called('DELETE', '/api/scheduled-messages/f1'),
        hasLength(1),
      );
      expect(_card('f1'), findsNothing);
      expect(find.text('예약 메시지를 삭제했습니다.'), findsOneWidget);
      await _flushToasts(tester);
    });
  });

  group('실시간 반영', () {
    testWidgets('발송 결과·변경 알림이 오면 목록이 그 자리에서 바뀐다', (tester) async {
      final t = _setup(_fourRows());
      await _pumpPanel(tester, t.session);
      expect(_cardOrder(tester), ['f1', 's1', 's2', 's3']);

      // 예약 시각이 되어 보내졌다 — 카드가 사라진다.
      t.server.rows.removeWhere((r) => r['id'] == 's1');
      t.session.handleScheduledMessageEvent(
        const ScheduledMessageEvent(
          type: ScheduledMessageEventType.sent,
          id: 's1',
          teamId: 't1',
          roomId: 'r1',
          roomName: '공지방',
        ),
      );
      await tester.pumpAndSettle();
      expect(_card('s1'), findsNothing);
      expect(_countText(tester), '3개의 예약 메시지');

      // 보내지 못했다 — 발송 실패로 위에 올라오고 사유가 붙는다.
      t.session.handleScheduledMessageEvent(
        const ScheduledMessageEvent(
          type: ScheduledMessageEventType.failed,
          id: 's3',
          teamId: 't1',
          roomId: 'r-dm',
          reason: '받는 사람이 팀을 나갔습니다.',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('scheduled-panel-failed-s3')),
        findsOneWidget,
      );
      expect(find.text('받는 사람이 팀을 나갔습니다.'), findsOneWidget);
      expect(_cardOrder(tester).take(2).toSet(), {'f1', 's3'});

      // 다른 기기에서 만들었다(scheduled:changed) — 다시 받아 새 카드가 보인다.
      t.server.rows.add(_row('n1', text: '다른 기기에서 만든 예약'));
      t.session.handleScheduledChanged('t1');
      await tester.pumpAndSettle();
      expect(_card('n1'), findsOneWidget);
      expect(find.text('다른 기기에서 만든 예약', findRichText: true), findsOneWidget);
      await _flushToasts(tester);
    });
  });
}
