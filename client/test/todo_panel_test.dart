import 'dart:async';
import 'dart:convert';

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/models/todo.dart';
import 'package:client/screens/image_viewer_screen.dart';
import 'package:client/screens/todo_detail_dialog.dart';
import 'package:client/screens/todo_editor_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/services/todo_controller.dart';
import 'package:client/widgets/app_toast.dart';
import 'package:client/widgets/attachment_widgets.dart'
    show ChatImageAttachments, DownloadableFile;
import 'package:client/widgets/category_tab_row.dart';
import 'package:client/widgets/compact_menu.dart';
import 'package:client/widgets/favorite_star.dart';
import 'package:client/widgets/filter_dropdown.dart';
import 'package:client/widgets/home_shell_scope.dart';
import 'package:client/widgets/panel_filters.dart' show memberChoicesFor;
import 'package:client/widgets/todo_calendar_view.dart';
import 'package:client/widgets/todo_menu.dart';
import 'package:client/widgets/todo_widgets.dart';
import 'package:client/widgets/todos_panel.dart';
import 'package:client/widgets/user_avatar.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers/fake_todo_api.dart';

/// 할 일 패널(잔디 2차 — 실제 화면에 맞추기) — 목록 화면(머리의 `할 일 일정` 칩·가로 전체 `+ 할 일 생성`·참여한 대화방 →
/// 보기 → 부여한 할 일의 담당 멤버·정렬(생성 순 / 기한 순)·`완료된 할 일 제외` 스위치·`N개의 할 일`(서버가 센 전체 개수)),
/// 카드(`진행률 : 75%` 관점 진척률과 진척률 색·생성일·즐겨찾기 표시·설명·대화방/담당자/첨부·일정과 지난 기한, 오른쪽 위
/// ⋯ — 상세 •••와 같은 항목·권한·동작, 마우스 올림 색), 화면 흐름(PC는 패널 안 Navigator에 상세·생성·일정 — ←·✕·시스템 뒤로 가기·팀 바꾸면 목록으로 / 모바일은
/// 앱 Navigator의 전체 화면), 할 일 일정 화면(42칸 범위 받기·할 일 점·고른 날의 대화방별 묶음과 접기·달/해 이동·오늘·목록
/// 필터 그대로·받는 중/실패·상세 뒤 다시 받기), 펼침 패널 위치, 어두운 테마, 폭 360·390·420. 서버는 가짜 API
/// (helpers/fake_todo_api.dart)로 대신한다.

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

Map<String, dynamic> _user(String id, String name) => {
  'id': id,
  'username': id,
  'name': name,
  'role': 'member',
};

final _members = [_user('me', '나'), _user('u2', '김철수'), _user('u3', '이영희')];

const _longRoomName = '아주 긴 대화방 이름이 들어가는 경우를 확인하는 토픽입니다 정말로';

Room _room(
  String id,
  String name, {
  String type = 'topic',
  String teamId = 't1',
  String? viewMode,
  List<Map<String, dynamic>>? members,
}) => Room.fromJson({
  'id': id,
  'teamId': teamId,
  'type': type,
  'name': name,
  'members': members ?? _members,
  'createdAt': 1000,
  'viewMode': ?viewMode,
});

/// 나와의 대화(팀마다 하나, 멤버는 나뿐).
Room _selfRoom() => Room.fromJson({
  'id': 'self',
  'teamId': 't1',
  'type': 'dm',
  'name': null,
  'members': [_user('me', '나')],
  'createdAt': 1000,
  'isSelf': true,
});

/// [withSelf]면 나와의 대화를, [extraRooms]가 있으면 그 방들을 더 넣는다.
Session _session({bool withSelf = false, List<Room> extraRooms = const []}) {
  final session = Session(
    notifications: _QuietNotifications(),
    settings: AppSettings(),
  );
  session.serverUrl = 'https://test.local';
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: MockClient(
      (request) async => http.Response.bytes(
        utf8.encode(jsonEncode({'items': <Object>[], 'hasMore': false})),
        200,
        headers: const {'content-type': 'application/json'},
      ),
    ),
  );
  session.userId = 'me';
  session.name = '나';
  session.accountRole = AccountRole.member;
  final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  session.rooms.addAll([
    _room('r1', '영업 토픽'),
    _room('r2', '개발 토픽'),
    _room('g1', '디자인 그룹', type: 'group'),
    _room('long', _longRoomName),
    if (withSelf) _selfRoom(),
    ...extraRooms,
  ]);
  return session;
}

/// 모바일 — 패널이 전체 화면(홈 셸 없음). [api]를 주면 그것을, 아니면 [todos]로 만든 가짜를 쓴다([controller]를 줄 때는
/// 같은 [api]로 만들 것). [settle]이 false면 첫 프레임만 그린다(목록 받기를 붙잡아 둔 시험 — 도는 표시 때문에
/// pumpAndSettle이 끝나지 않는다).
Future<FakeTodoApi> _pump(
  WidgetTester tester,
  List<Map<String, dynamic>> todos, {
  Size size = const Size(420, 900),
  FakeTodoApi? api,
  TodoController? controller,
  ThemeData? theme,
  Session? session,
  bool settle = true,
}) async {
  final fake = api ?? FakeTodoApi(me: 'me', todos: todos);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: TodosPanel(
          session: session ?? _session(),
          api: fake,
          controller: controller,
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return fake;
}

/// PC 하네스의 왼쪽(패널 밖) 채팅 자리를 누른 횟수 — 패널 안에 띄운 메뉴가 떠 있는 동안 채팅 쪽을 눌러도 그 누름이 채팅에
/// 가지 않는지 본다.
var _chatTaps = 0;

/// 패널 밖 채팅 자리의 한 점.
const _chatPoint = Offset(300, 450);

/// PC — 1280 폭 창의 오른쪽 420 칸에 홈 셸 아래 패널(패널 안 Navigator를 쓴다). 칸은 키 `panel-box`, 왼쪽은 누르면
/// [_chatTaps]가 느는 채팅 자리. [setPanelLeaveGuard]는 홈 화면의 "닫기 전에 물어보기" 손잡이 흉내.
Future<FakeTodoApi> _pumpShell(
  WidgetTester tester,
  List<Map<String, dynamic>> todos, {
  FakeTodoApi? api,
  TodoController? controller,
  Session? session,
  VoidCallback? onClose,
  String? currentRoomId,
  double height = 900,
  void Function(Object owner, PanelLeaveGuard? guard)? setPanelLeaveGuard,
}) async {
  final fake = api ?? FakeTodoApi(me: 'me', todos: todos);
  _chatTaps = 0;
  tester.view.physicalSize = Size(1280, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: HomeShellScope(
          openPanelKey: 'todos',
          panelRoom: null,
          panelGeneration: 0,
          currentRoomId: currentRoomId,
          togglePanel: (_) {},
          closePanel: () {},
          toggleCalendar: () {},
          openRoom: (room, {messageId}) {},
          setPanelLeaveGuard: setPanelLeaveGuard,
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  key: const ValueKey('chat-area'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _chatTaps++,
                  child: const SizedBox.expand(),
                ),
              ),
              SizedBox(
                key: const ValueKey('panel-box'),
                width: 420,
                child: TodosPanel(
                  session: session ?? _session(),
                  api: fake,
                  controller: controller,
                  onClose: onClose,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

Finder _key(String k) => find.byKey(ValueKey(k));

Rect _panelRect(WidgetTester tester) => tester.getRect(_key('panel-box'));

/// 팝업 메뉴 항목([item])이 든 메뉴 상자의 자리(항목의 가장 가까운 Material이 메뉴 상자다).
Rect _menuRect(WidgetTester tester, Finder item) => tester.getRect(
  find.ancestor(of: item, matching: find.byType(Material)).first,
);

/// 대화방 칸(RoomPickerField)의 펼친 목록.
final _roomPickerDropdown = find.byWidgetPredicate(
  (w) => w.runtimeType.toString() == '_RoomPickerDropdown',
);

/// [rect]가 PC 패널 칸 안에 있는지.
void _expectInPanel(WidgetTester tester, Rect rect, String what) {
  final panel = _panelRect(tester);
  expect(rect.left, greaterThanOrEqualTo(panel.left - 0.01), reason: what);
  expect(rect.right, lessThanOrEqualTo(panel.right + 0.01), reason: what);
  expect(rect.top, greaterThanOrEqualTo(panel.top - 0.01), reason: what);
  expect(rect.bottom, lessThanOrEqualTo(panel.bottom + 0.01), reason: what);
}

/// [open]으로 띄운 메뉴·펼침 목록([shown] — 그 안의 것)이 패널 안([rect])에 있고, 패널 밖 채팅 자리를 누르면 닫히며 그 누름은
/// 채팅에 가지 않는다(창 전체를 덮는 막이 받는다).
Future<void> _expectClosesFromChat(
  WidgetTester tester, {
  required String what,
  required Future<void> Function() open,
  required Finder shown,
  required Rect Function() rect,
}) async {
  await open();
  expect(shown, findsWidgets, reason: '$what — 떴다');
  _expectInPanel(tester, rect(), '$what — 패널 안');
  final before = _chatTaps;
  await tester.tapAt(_chatPoint);
  await tester.pumpAndSettle();
  expect(shown, findsNothing, reason: '$what — 채팅 쪽을 누르면 닫힌다');
  expect(_chatTaps, before, reason: '$what — 그 누름은 채팅에 가지 않는다');
}

Future<void> _pickScope(WidgetTester tester, TodoScope scope) async {
  await tester.tap(_key('todo-scope'));
  await tester.pumpAndSettle();
  await tester.tap(_key('todo-scope-${scope.wire}'));
  await tester.pumpAndSettle();
}

Switch _switch(WidgetTester tester) =>
    tester.widget<Switch>(_key('todo-exclude-done'));

/// 카드 첫 줄 `진행률 : N%`의 숫자 부분.
String? _percent(WidgetTester tester, String id) =>
    tester.widget<Text>(_key('todo-card-progress-$id')).data;

Color? _percentColor(WidgetTester tester, String id) =>
    tester.widget<Text>(_key('todo-card-progress-$id')).style?.color;

/// 안드로이드 뒤로 가기 — 시스템이 보내는 popRoute.
Future<void> _systemBack(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    SystemChannels.navigation.codec.encodeMethodCall(
      const MethodCall('popRoute'),
    ),
    (_) {},
  );
  await tester.pumpAndSettle();
}

// ---- 일정 ----

DateTime get _today {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

DateTime get _thisMonth => DateTime(_today.year, _today.month);

DateTime _dayOf(DateTime month, int day) =>
    DateTime(month.year, month.month, day);

String _w(DateTime d) => todoDateWire(d);

String _monthText(DateTime m) =>
    '${m.year}/${m.month.toString().padLeft(2, '0')}';

Future<void> _openCalendar(WidgetTester tester) async {
  await tester.tap(_key('todo-calendar-toggle'));
  await tester.pumpAndSettle();
}

Future<void> _tapDay(WidgetTester tester, DateTime day) async {
  final cell = _key('todo-cal-day-${_w(day)}');
  await tester.ensureVisible(cell);
  await tester.pumpAndSettle();
  await tester.tap(cell);
  await tester.pumpAndSettle();
}

/// 날짜 칸 아래에 할 일 점이 있는지.
bool _dot(DateTime day) =>
    _key('todo-cal-dot-${_w(day)}').evaluate().isNotEmpty;

/// 고른 날(채운 원이 든 칸)의 'YYYY-MM-DD'.
String? _selectedYmd(WidgetTester tester) {
  final cell = find.ancestor(
    of: _key('todo-cal-selected'),
    matching: find.byWidgetPredicate((w) {
      final key = w.key;
      return key is ValueKey<String> && key.value.startsWith('todo-cal-day-');
    }),
  );
  if (cell.evaluate().isEmpty) return null;
  final key = tester.widget(cell.first).key! as ValueKey<String>;
  return key.value.substring('todo-cal-day-'.length);
}

/// 기간(from/to)을 준 목록 조회만 실패시키는 가짜 — 일정의 실패 표시 시험.
class _RangeFailApi extends FakeTodoApi {
  _RangeFailApi({super.todos}) : super(me: 'me');

  bool failRange = true;

  @override
  Future<TodoPage> list({
    required String teamId,
    required TodoScope scope,
    bool includeDone = true,
    String? roomId,
    String? assigneeId,
    DateTime? from,
    DateTime? to,
    TodoSort sort = TodoSort.due,
    int offset = 0,
    int limit = 30,
  }) {
    if (from != null && failRange) throw const ApiException('서버 오류');
    return super.list(
      teamId: teamId,
      scope: scope,
      includeDone: includeDone,
      roomId: roomId,
      assigneeId: assigneeId,
      from: from,
      to: to,
      sort: sort,
      offset: offset,
      limit: limit,
    );
  }
}

/// 목록 받기를 실패시키는 가짜([fail]을 끄면 제대로 받는다) — 첫 받기가 실패했을 때의 표시 시험.
class _FailingListApi extends FakeTodoApi {
  _FailingListApi({super.todos}) : super(me: 'me');

  bool fail = true;

  @override
  Future<TodoPage> list({
    required String teamId,
    required TodoScope scope,
    bool includeDone = true,
    String? roomId,
    String? assigneeId,
    DateTime? from,
    DateTime? to,
    TodoSort sort = TodoSort.due,
    int offset = 0,
    int limit = 30,
  }) {
    if (fail) throw const ApiException('서버 오류');
    return super.list(
      teamId: teamId,
      scope: scope,
      includeDone: includeDone,
      roomId: roomId,
      assigneeId: assigneeId,
      from: from,
      to: to,
      sort: sort,
      offset: offset,
      limit: limit,
    );
  }
}

void main() {
  // ────────────────────────── 목록 화면 — 위쪽 ──────────────────────────
  group('목록 화면 — 위쪽', () {
    testWidgets(
      '머리(할 일 바로 옆 할 일 일정 칩, ✕) · 가로 전체 할 일 생성 · 대화방 → 보기 · 생성 순과 완료 제외 스위치 · N개의 할 일',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final api = await _pump(tester, [
          todoJson(id: 'a', title: '내 할 일', assignees: ['me']),
          todoJson(id: 'b', title: '개인 할 일', createdAt: 2),
        ]);
        // 머리 — 제목 바로 오른쪽에 작은 일정 칩, 오른쪽 끝에 ✕.
        final title = tester.getRect(find.text('할 일'));
        final chip = tester.getRect(_key('todo-calendar-toggle'));
        final close = tester.getRect(_key('todo-panel-close'));
        expect(chip.left - title.right, inInclusiveRange(4, 16));
        expect(chip.center.dy, moreOrLessEquals(title.center.dy, epsilon: 2));
        expect(chip.right, lessThan(close.left - 100));
        expect(close.right, greaterThan(400));
        expect(
          find.descendant(
            of: _key('todo-calendar-toggle'),
            matching: find.text('할 일 일정'),
          ),
          findsOneWidget,
        );
        expect(
          tester.getSemantics(_key('todo-calendar-toggle')),
          isSemantics(label: '할 일 일정', isButton: true, hasTapAction: true),
        );
        // 가로 전체 할 일 생성.
        final create = tester.getRect(_key('todo-create'));
        expect(create.width, moreOrLessEquals(420 - 32, epsilon: 0.5));
        expect(create.top, greaterThan(chip.bottom));
        expect(
          find.descendant(
            of: _key('todo-create'),
            matching: find.text('할 일 생성'),
          ),
          findsOneWidget,
        );
        // 필터 — 대화방이 먼저, 그다음 보기.
        final room = tester.getRect(find.byType(RoomFilterButton));
        final scope = tester.getRect(_key('todo-scope'));
        expect(find.text('참여한 대화방'), findsOneWidget);
        expect(
          find.descendant(
            of: _key('todo-scope'),
            matching: find.text('나의 할 일'),
          ),
          findsOneWidget,
        );
        expect(room.top, greaterThan(create.bottom));
        expect(room.right, lessThan(scope.left));
        expect(room.width, moreOrLessEquals(scope.width, epsilon: 0.5));
        expect(
          _key('todo-assignee-filter'),
          findsNothing,
          reason: '부여한 할 일에서만',
        );
        // 완료 제외 스위치(스위치 · 글자)는 왼쪽, 정렬은 오른쪽 끝(처음은 생성 순) — 한 줄.
        expect(
          find.descendant(of: _key('todo-sort'), matching: find.text('생성 순')),
          findsOneWidget,
        );
        expect(api.calls.single, contains('sort=created'));
        final sort = tester.getRect(_key('todo-sort'));
        final toggle = tester.getRect(_key('todo-exclude-done'));
        final label = tester.getRect(find.text('완료된 할 일 제외'));
        expect(toggle.top, greaterThan(room.bottom));
        expect(toggle.left, lessThan(30));
        expect(toggle.right, lessThanOrEqualTo(label.left));
        expect(label.right, lessThan(sort.left));
        expect(sort.right, greaterThan(400));
        expect(
          sort.center.dy,
          moreOrLessEquals(toggle.center.dy, epsilon: 2),
          reason: '같은 줄',
        );
        expect(_switch(tester).value, isFalse);
        // 건수 줄 — 숫자는 굵게.
        expect(find.text('2개의 할 일'), findsOneWidget);
        final count =
            tester.widget<Text>(_key('panel-loaded-count')).textSpan!
                as TextSpan;
        final number = count.children!.first as TextSpan;
        expect(number.text, '2');
        expect(number.style?.fontWeight, FontWeight.w700);
        expect(
          tester.getTopLeft(_key('panel-loaded-count')).dy,
          greaterThan(toggle.bottom),
        );
        // 예전 탭 줄·체크 상자·칩·진척률 원·고르는 칩·별 단추는 없다 — 보기는 드롭다운 안에만 있다.
        expect(find.byType(CategoryTabRow), findsNothing);
        expect(find.byType(Checkbox), findsNothing);
        expect(find.byType(FilterChip), findsNothing);
        expect(_key('todo-ring-a'), findsNothing);
        expect(find.byType(PopupMenuButton<int>), findsNothing);
        expect(find.byType(FavoriteStar), findsNothing);
        expect(find.text('부여한 할 일'), findsNothing);
        expect(find.text('모든 할 일'), findsNothing);
        semantics.dispose();
      },
    );

    testWidgets(
      '보기 드롭다운 — 모든 할 일 / 나의 할 일 / 부여한 할 일 순서(고른 것에 체크), 고르면 그 범위로 다시 받는다',
      (tester) async {
        final api = await _pump(tester, [
          todoJson(id: 'a', title: '나에게', assignees: ['me']),
          todoJson(id: 'c', title: '내가 부여', assignees: ['u2'], createdAt: 3),
          todoJson(
            id: 'd',
            title: '남의 일',
            creatorId: 'u2',
            assignees: ['u3'],
            createdAt: 4,
          ),
        ]);
        expect(api.calls.single, startsWith('list mine'));
        await tester.tap(_key('todo-scope'));
        await tester.pumpAndSettle();
        double top(String wire) =>
            tester.getTopLeft(_key('todo-scope-$wire')).dy;
        expect(top('team'), lessThan(top('mine')));
        expect(top('mine'), lessThan(top('assigned_by_me')));
        for (final (wire, label, checked) in const [
          ('team', '모든 할 일', false),
          ('mine', '나의 할 일', true),
          ('assigned_by_me', '부여한 할 일', false),
        ]) {
          final item = _key('todo-scope-$wire');
          expect(
            find.descendant(of: item, matching: find.text(label)),
            findsOneWidget,
          );
          expect(
            find.descendant(of: item, matching: find.byIcon(Icons.check)),
            checked ? findsOneWidget : findsNothing,
          );
        }
        // 지금 보기를 다시 고르면 닫히기만 하고 다시 받지 않는다.
        await tester.tap(_key('todo-scope-mine'));
        await tester.pumpAndSettle();
        expect(_key('todo-scope-team'), findsNothing);
        expect(api.callCount('list'), 1);

        await _pickScope(tester, TodoScope.assignedByMe);
        expect(api.calls.last, startsWith('list assigned_by_me'));
        expect(
          find.descendant(
            of: _key('todo-scope'),
            matching: find.text('부여한 할 일'),
          ),
          findsOneWidget,
        );
        expect(find.text('내가 부여'), findsOneWidget);
        expect(find.text('나에게'), findsNothing);
        expect(find.text('1개의 할 일'), findsOneWidget);

        await _pickScope(tester, TodoScope.team);
        expect(api.calls.last, startsWith('list team'));
        expect(
          find.descendant(
            of: _key('todo-scope'),
            matching: find.text('모든 할 일'),
          ),
          findsOneWidget,
        );
        expect(find.text('3개의 할 일'), findsOneWidget);
        expect(find.text('남의 일'), findsOneWidget);
      },
    );

    testWidgets(
      '담당 멤버 필터는 부여한 할 일에서만(보기 오른쪽) — 고른 사람을 assigneeId로 보내고 카드 진행률을 그 사람 것으로',
      (tester) async {
        final api = await _pump(tester, [
          todoJson(
            id: 'c1',
            title: '둘에게',
            assignees: ['u2', 'u3'],
            assigneeProgress: {'u2': 100, 'u3': 0},
          ),
          todoJson(
            id: 'c2',
            title: '이영희에게',
            assignees: ['u3'],
            assigneeProgress: {'u3': 50},
            createdAt: 2,
          ),
          todoJson(id: 'm', title: '나에게', assignees: ['me'], createdAt: 3),
        ]);
        expect(_key('todo-assignee-filter'), findsNothing);
        await _pickScope(tester, TodoScope.assignedByMe);
        expect(
          find.descendant(
            of: _key('todo-assignee-filter'),
            matching: find.text('모든 멤버'),
          ),
          findsOneWidget,
        );
        // 대화방 → 보기 → 멤버.
        expect(
          tester.getRect(find.byType(RoomFilterButton)).right,
          lessThan(tester.getRect(_key('todo-scope')).left),
        );
        expect(
          tester.getRect(_key('todo-scope')).right,
          lessThan(tester.getRect(_key('todo-assignee-filter')).left),
        );
        expect(_percent(tester, 'c1'), '50%', reason: '멤버를 안 고르면 집계 %');

        await tester.tap(_key('todo-assignee-filter'));
        await tester.pumpAndSettle();
        // 후보는 방 멤버(memberChoicesFor) — 나·김철수·이영희.
        expect(find.text('김철수'), findsOneWidget);
        expect(find.text('이영희'), findsOneWidget);
        await tester.tap(find.text('김철수'));
        await tester.pumpAndSettle();
        expect(api.lastList!['assigneeId'], 'u2');
        expect(api.calls.last, startsWith('list assigned_by_me'));
        expect(api.calls.last, contains('assignee=u2'));
        expect(
          find.descendant(
            of: _key('todo-assignee-filter'),
            matching: find.text('김철수'),
          ),
          findsOneWidget,
        );
        expect(find.text('둘에게'), findsOneWidget);
        expect(find.text('이영희에게'), findsNothing);
        expect(_percent(tester, 'c1'), '100%', reason: '김철수의 진척률');

        await tester.tap(_key('todo-assignee-filter'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('이영희'));
        await tester.pumpAndSettle();
        expect(api.lastList!['assigneeId'], 'u3');
        expect(_percent(tester, 'c1'), '0%');
        expect(_percent(tester, 'c2'), '50%');

        await _pickScope(tester, TodoScope.team);
        expect(_key('todo-assignee-filter'), findsNothing);
        expect(api.lastList!['assigneeId'], isNull, reason: '부여한 할 일이 아니면 비운다');
      },
    );

    testWidgets('완료된 할 일 제외 — 스위치를 눌러도, 글자를 눌러도 켜고 끈다(한 마디로 읽힌다)', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final api = await _pump(tester, [
        todoJson(id: 'a', title: '미완료', assignees: ['me']),
        todoJson(
          id: 'b',
          title: '끝난 일',
          assignees: ['me'],
          progress: 100,
          createdAt: 2,
        ),
      ]);
      expect(find.text('끝난 일'), findsOneWidget);
      expect(
        tester.getSemantics(_key('todo-exclude-done')),
        isSemantics(
          label: '완료된 할 일 제외',
          hasToggledState: true,
          isToggled: false,
          hasTapAction: true,
        ),
      );
      await tester.tap(_key('todo-exclude-done'));
      await tester.pumpAndSettle();
      expect(api.calls.last, contains('done=false'));
      expect(_switch(tester).value, isTrue);
      expect(find.text('끝난 일'), findsNothing);
      expect(find.text('1개의 할 일'), findsOneWidget);

      await tester.tap(find.text('완료된 할 일 제외'));
      await tester.pumpAndSettle();
      expect(api.calls.last, contains('done=true'));
      expect(_switch(tester).value, isFalse);
      expect(find.text('끝난 일'), findsOneWidget);
      expect(api.callCount('list'), 3);
      semantics.dispose();
    });

    testWidgets('정렬 — 생성 순(처음) / 기한 순 메뉴, 고르면 그 순서로 다시 받는다', (tester) async {
      final api = await _pump(tester, [
        for (final (i, id) in ['a', 'b', 'c'].indexed)
          todoJson(
            id: id,
            title: '할 일 $id',
            assignees: ['me'],
            dueDate: '2099-01-0${i + 1}',
            createdAt: i,
          ),
      ]);
      List<String> order() => ['a', 'b', 'c']
        ..sort(
          (x, y) => tester
              .getTopLeft(_key('todo-$x'))
              .dy
              .compareTo(tester.getTopLeft(_key('todo-$y')).dy),
        );
      expect(order(), ['c', 'b', 'a'], reason: '생성 순 — 최근에 만든 것 먼저');
      await tester.tap(_key('todo-sort'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(_key('todo-sort-created')).dy,
        lessThan(tester.getTopLeft(_key('todo-sort-due')).dy),
      );
      expect(
        find.descendant(
          of: _key('todo-sort-created'),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _key('todo-sort-due'), matching: find.text('기한 순')),
        findsOneWidget,
      );
      await tester.tap(_key('todo-sort-due'));
      await tester.pumpAndSettle();
      expect(api.calls.last, contains('sort=due'));
      expect(
        find.descendant(of: _key('todo-sort'), matching: find.text('기한 순')),
        findsOneWidget,
      );
      expect(order(), ['a', 'b', 'c'], reason: '기한 순 — 기한이 가까운 것 먼저');
    });

    testWidgets('N개의 할 일은 서버가 센 전체 개수 — 다음 쪽을 받기 전에도 다 센다', (tester) async {
      final api = await _pump(tester, [
        for (var i = 0; i < 45; i++)
          todoJson(
            id: 'x$i',
            title: '할 일 번호 $i',
            assignees: ['me'],
            createdAt: 100 - i,
          ),
      ]);
      expect(api.callCount('list'), 1);
      expect(api.calls.single, contains('limit=30'));
      expect(find.text('45개의 할 일'), findsOneWidget);
      await tester.drag(_key('todo-list'), const Offset(0, -30000));
      await tester.pumpAndSettle();
      await tester.drag(_key('todo-list'), const Offset(0, -30000));
      await tester.pumpAndSettle();
      expect(api.callCount('list'), 2);
      expect(api.calls.last, contains('offset=30'));
      expect(find.text('45개의 할 일'), findsOneWidget);
    });

    for (final width in [360.0, 390.0]) {
      testWidgets(
        '폭 ${width.toInt()} — 대화방·보기는 단추 왼쪽 끝, 멤버는 오른쪽 끝에 펼치되 늘 화면 안(가장자리 8)에',
        (tester) async {
          final api = FakeTodoApi(me: 'me');
          final controller = TodoController(
            api: api,
            teamId: 't1',
            scope: TodoScope.assignedByMe,
          );
          await _pump(
            tester,
            const [],
            api: api,
            controller: controller,
            size: Size(width, 800),
          );
          Future<Rect> open(Finder button) async {
            await tester.tap(button);
            await tester.pumpAndSettle();
            final rect = tester.getRect(find.byType(FilterPanelShell));
            // 바깥(빈 목록 자리)을 눌러 닫는다.
            await tester.tapAt(const Offset(200, 780));
            await tester.pumpAndSettle();
            return rect;
          }

          /// 단추 끝에 맞추되, 그러면 화면 밖으로 나가는 폭이면 화면 안(가장자리 8)으로 당긴 자리.
          void expectPlaced(
            Rect panel,
            Finder button, {
            required bool end,
            required String what,
          }) {
            final b = tester.getRect(button);
            final want = end ? b.right - panel.width : b.left;
            final placed = want.clamp(8.0, width - 8 - panel.width);
            expect(
              panel.left,
              moreOrLessEquals(placed, epsilon: 0.5),
              reason: what,
            );
            expect(panel.left, greaterThanOrEqualTo(8 - 0.01), reason: what);
            expect(
              panel.right,
              lessThanOrEqualTo(width - 8 + 0.01),
              reason: what,
            );
            expect(
              panel.top,
              moreOrLessEquals(b.top + 44, epsilon: 1),
              reason: '$what — 세로 자리는 단추 아래',
            );
          }

          final roomButton = find.byType(RoomFilterButton);
          final room = await open(roomButton);
          expect(room.width, RoomFilterButton.panelWidth);
          expectPlaced(room, roomButton, end: false, what: '대화방(세 칸)');
          final scope = await open(_key('todo-scope'));
          expectPlaced(scope, _key('todo-scope'), end: false, what: '보기(세 칸)');
          final member = await open(_key('todo-assignee-filter'));
          expectPlaced(
            member,
            _key('todo-assignee-filter'),
            end: true,
            what: '멤버',
          );

          // 두 칸(나의 할 일)일 때 오른쪽 끝 보기 단추 — 화면 밖으로 나가면 당긴다.
          controller.setScope(TodoScope.mine);
          await tester.pumpAndSettle();
          final right = await open(_key('todo-scope'));
          expectPlaced(right, _key('todo-scope'), end: false, what: '보기(두 칸)');
          await tester.pumpWidget(const SizedBox());
          controller.dispose();
        },
      );
    }

    testWidgets('PC — 필터 펼침 패널은 패널 안(패널 가장자리 8 안)에 뜬다', (tester) async {
      final api = FakeTodoApi(me: 'me');
      final controller = TodoController(
        api: api,
        teamId: 't1',
        scope: TodoScope.assignedByMe,
      );
      await _pumpShell(tester, const [], api: api, controller: controller);
      final panel = _panelRect(tester);
      for (final button in [
        find.byType(RoomFilterButton),
        _key('todo-scope'),
        _key('todo-assignee-filter'),
      ]) {
        await tester.tap(button);
        await tester.pumpAndSettle();
        final rect = tester.getRect(find.byType(FilterPanelShell));
        expect(rect.left, greaterThanOrEqualTo(panel.left + 8 - 0.01));
        expect(rect.right, lessThanOrEqualTo(panel.right - 8 + 0.01));
        expect(
          rect.top,
          moreOrLessEquals(tester.getRect(button).top + 44, epsilon: 1),
          reason: '단추 아래',
        );
        await tester.tapAt(Offset(panel.left + 200, 860));
        await tester.pumpAndSettle();
        expect(find.byType(FilterPanelShell), findsNothing);
      }
      // 정렬 메뉴도 패널 안 — 단추 바로 아래, 단추 오른쪽 끝(패널 오른쪽)에서 패널 쪽(왼쪽)으로.
      await tester.tap(_key('todo-sort'));
      await tester.pumpAndSettle();
      final sort = tester.getRect(_key('todo-sort'));
      final item = tester.getRect(_key('todo-sort-due'));
      expect(item.top, greaterThan(sort.bottom - 1));
      expect(item.right, moreOrLessEquals(sort.right, epsilon: 1));
      expect(item.left, greaterThanOrEqualTo(panel.left));
      await tester.tap(_key('todo-sort-due'));
      await tester.pumpAndSettle();
      expect(api.calls.last, contains('sort=due'));
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  });

  // ────────────────────────── 카드 ──────────────────────────
  group('할 일 카드', () {
    testWidgets(
      '진행률 : N%(관점·진척률 색) · 생성일 · 즐겨찾기 별 · 굵은 제목 · 설명 두 줄 · 대화방/담당자/첨부 · 구분선 아래 일정',
      (tester) async {
        await _pump(tester, [
          todoJson(
            id: 'a',
            title: '여럿에게',
            description: '첫 줄 설명\n둘째 줄\n셋째 줄',
            assignees: ['me', 'u2', 'u3'],
            assigneeProgress: {'me': 50, 'u2': 100, 'u3': 0},
            startDate: '2099-10-01',
            dueDate: '2099-10-07',
            attachmentCount: 3,
            favorite: true,
            createdAt: DateTime(2026, 10, 3, 9).millisecondsSinceEpoch,
          ),
          todoJson(
            id: 'g',
            title: '그룹 할 일',
            roomId: 'g1',
            roomName: '디자인 그룹',
            assignees: ['me'],
            assigneeProgress: {'me': 100},
            createdAt: DateTime(2026, 9, 1).millisecondsSinceEpoch,
          ),
        ]);
        final context = tester.element(_key('todo-a'));
        final theme = Theme.of(context);
        // 첫 줄 — 진행률(내 진척률, 진행은 초록)과 오른쪽 생성일.
        expect(
          find.descendant(of: _key('todo-a'), matching: find.text('진행률 : ')),
          findsOneWidget,
        );
        expect(_percent(tester, 'a'), '50%');
        expect(_percentColor(tester, 'a'), todoProgressColor(context, 50));
        expect(
          tester.widget<Text>(_key('todo-created-a')).data,
          '생성일: 2026/10/03',
        );
        expect(
          tester.getRect(_key('todo-created-a')).right,
          greaterThan(tester.getRect(_key('todo-card-progress-a')).right + 100),
        );
        // 즐겨찾기면 제목 앞에 작은 노란 별(누르는 단추가 아니다).
        final star = tester.widget<Icon>(_key('todo-fav-a'));
        expect(star.icon, Icons.star_rounded);
        expect(star.color, Colors.amber);
        expect(_key('todo-fav-g'), findsNothing);
        expect(
          tester.getCenter(_key('todo-fav-a')).dx,
          lessThan(tester.getRect(find.text('여럿에게')).left),
        );
        // 굵은 제목(두 줄까지), 설명은 회색 두 줄까지.
        final title = tester.widget<Text>(find.text('여럿에게'));
        expect(title.maxLines, 2);
        expect(title.style?.fontWeight, FontWeight.w700);
        final description = tester.widget<Text>(_key('todo-desc-a'));
        expect(description.maxLines, 2);
        expect(description.data, '첫 줄 설명\n둘째 줄\n셋째 줄');
        expect(_key('todo-desc-g'), findsNothing, reason: '설명이 없으면 줄도 없다');
        // 대화방(종류 아이콘)·담당자 수·첨부 수 한 줄.
        expect(tester.widget<Text>(_key('todo-room-a')).data, '영업 토픽');
        expect(
          find.descendant(of: _key('todo-a'), matching: find.byIcon(Icons.tag)),
          findsOneWidget,
        );
        expect(tester.widget<Text>(_key('todo-assignees-a')).data, '담당자 3명');
        expect(tester.widget<Text>(_key('todo-clips-a')).data, '3');
        expect(tester.widget<Text>(_key('todo-room-g')).data, '디자인 그룹');
        expect(
          find.descendant(
            of: _key('todo-g'),
            matching: find.byIcon(Icons.groups_outlined),
          ),
          findsOneWidget,
        );
        expect(_key('todo-clips-g'), findsNothing);
        // 구분선 아래 일정 — 날짜가 없으면 `일정: 없음`.
        final period = tester.getRect(_key('todo-period-a'));
        final divider = tester.getRect(
          find.descendant(of: _key('todo-a'), matching: find.byType(Divider)),
        );
        expect(period.top, greaterThanOrEqualTo(divider.bottom));
        expect(
          tester.widget<Text>(_key('todo-period-a')).data,
          '일정: 2099/10/01 ~ 2099/10/07',
        );
        expect(tester.widget<Text>(_key('todo-period-g')).data, '일정: 없음');
        // 완료는 회색 100%, 제목은 그대로(취소선 없음).
        expect(_percent(tester, 'g'), '100%');
        expect(_percentColor(tester, 'g'), theme.hintColor);
        expect(
          tester.widget<Text>(find.text('그룹 할 일')).style?.decoration,
          isNot(TextDecoration.lineThrough),
        );
        // 카드 — 둥근(12) 카드 바탕, 회색 바탕 위에 떠 있다.
        final card = tester.widget<Material>(
          find
              .descendant(of: _key('todo-a'), matching: find.byType(Material))
              .first,
        );
        expect(card.color, todoCardColor(context));
        expect(
          (card.shape! as RoundedRectangleBorder).borderRadius,
          BorderRadius.circular(12),
        );
        expect(todoCardColor(context), isNot(todoListBackgroundColor(context)));
        final listRect = tester.getRect(_key('todo-list'));
        final cardRect = tester.getRect(_key('todo-a'));
        expect(cardRect.left - listRect.left, moreOrLessEquals(12));
        expect(
          tester.getRect(_key('todo-g')).top - cardRect.bottom,
          moreOrLessEquals(10),
        );
        // 카드에서는 진척률을 바꾸지 않고 별은 표시만이다(즐겨찾기는 ⋯ 메뉴) — 원·고르는 칩(메뉴)·별 단추·아바타 줄(+N)이
        // 없다.
        expect(_key('todo-ring-a'), findsNothing);
        expect(find.byType(PopupMenuButton<int>), findsNothing);
        expect(find.byType(FavoriteStar), findsNothing);
        expect(_key('todo-star-a'), findsNothing);
        expect(find.byType(UserAvatar), findsNothing);
        expect(find.text('+2'), findsNothing);
      },
    );

    testWidgets('진척률 색 — 대기 주황, 진행 초록, 완료 회색', (tester) async {
      await _pump(tester, [
        for (final (i, p) in const [0, 25, 100].indexed)
          todoJson(
            id: 'p$p',
            title: '진척률 $p',
            assignees: ['me'],
            assigneeProgress: {'me': p},
            createdAt: i,
          ),
      ]);
      final context = tester.element(_key('todo-p0'));
      expect(_percent(tester, 'p0'), '0%');
      expect(_percentColor(tester, 'p0'), const Color(0xFFF08C00));
      expect(_percent(tester, 'p25'), '25%');
      expect(_percentColor(tester, 'p25'), const Color(0xFF02C472));
      expect(_percent(tester, 'p100'), '100%');
      expect(_percentColor(tester, 'p100'), Theme.of(context).hintColor);
    });

    testWidgets('관점 — 나의 할 일은 내 진척률, 모든 할 일은 집계 %(진행 1/3 대신)', (tester) async {
      await _pump(tester, [
        todoJson(
          id: 'g',
          title: '셋이 하는 일',
          assignees: ['me', 'u2', 'u3'],
          assigneeProgress: {'me': 100, 'u2': 50, 'u3': 0},
        ),
      ]);
      expect(_percent(tester, 'g'), '100%');
      await _pickScope(tester, TodoScope.team);
      expect(_percent(tester, 'g'), '50%');
      expect(find.textContaining('1/3'), findsNothing);
    });

    testWidgets('지난 기한 빨강도 관점 진척률로 — 내가 끝냈으면 나의 할 일에서는 빨갛지 않다', (tester) async {
      await _pump(tester, [
        todoJson(
          id: 'o',
          title: '지난 일',
          assignees: ['me', 'u2'],
          assigneeProgress: {'me': 100, 'u2': 0},
          dueDate: '2020-01-02',
        ),
      ]);
      Text period() => tester.widget<Text>(_key('todo-period-o'));
      final error = Theme.of(
        tester.element(_key('todo-period-o')),
      ).colorScheme.error;
      expect(period().data, '일정: ~ 2020/01/02');
      expect(period().style?.color, isNot(error), reason: '나는 끝냈다');
      await _pickScope(tester, TodoScope.team);
      expect(period().style?.color, error, reason: '전체(50)는 아직이다');
      expect(period().style?.fontWeight, FontWeight.w600);
    });

    testWidgets('시간이 있는 기간 — 목록 카드·일정 화면 카드는 시간까지, 달력의 점은 날짜로(자정에 끝나도 그날까지)', (
      tester,
    ) async {
      final tomorrow = DateTime(_today.year, _today.month, _today.day + 1);
      final api = await _pump(tester, [
        todoJson(
          id: 't',
          title: '시간 있는 일',
          assignees: ['me'],
          startDate: _w(_today),
          startTime: '17:40',
          dueDate: _w(tomorrow),
          dueTime: '00:00',
        ),
      ]);
      final text =
          '일정: ${formatTodoDate(_today)} 오후 5:40 ~ ${formatTodoDate(tomorrow)} 오전 12:00';
      expect(tester.widget<Text>(_key('todo-period-t')).data, text);
      await _openCalendar(tester);
      expect(api.lastList!['from'], isNotNull);
      expect(_dot(_today), isTrue);
      expect(_dot(tomorrow), isTrue);
      final calendarCard = find.descendant(
        of: find.byType(TodoCalendarPage),
        matching: _key('todo-period-t'),
      );
      expect(tester.widget<Text>(calendarCard).data, text);
      expect(tester.takeException(), isNull);
    });

    testWidgets('카드의 별은 표시만 — 별 자리를 눌러도 상세가 열리고, 진척률·즐겨찾기를 보내지 않는다', (
      tester,
    ) async {
      final api = await _pump(tester, [
        todoJson(
          id: 'a',
          title: '별 붙은 할 일',
          description: '자세한 설명입니다',
          assignees: ['me'],
          favorite: true,
        ),
      ]);
      await tester.tap(_key('todo-fav-a'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoDetail), findsOneWidget);
      expect(_key('todo-detail-title'), findsOneWidget);
      expect(api.callCount('setFavorite'), 0);
      expect(api.callCount('update'), 0);
    });

    testWidgets('빈 목록 — 보기마다 문구가 다르다', (tester) async {
      await _pump(tester, const []);
      expect(find.text('나에게 지정된 할 일이 없어요.'), findsOneWidget);
      expect(find.text('0개의 할 일'), findsOneWidget);
      await _pickScope(tester, TodoScope.assignedByMe);
      expect(find.text('다른 멤버에게 부여한 할 일이 없어요.'), findsOneWidget);
      await _pickScope(tester, TodoScope.team);
      expect(find.text('참여한 대화방에 등록된 할 일이 없어요.'), findsOneWidget);
    });

    testWidgets('어두운 테마 — 회색 바탕과 카드가 위쪽보다 한 단계씩 밝다', (tester) async {
      final dark = ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      );
      await _pump(tester, [
        todoJson(id: 'a', title: '할 일', assignees: ['me']),
      ], theme: dark);
      expect(tester.takeException(), isNull);
      final scheme = dark.colorScheme;
      final context = tester.element(_key('todo-a'));
      expect(todoListBackgroundColor(context), scheme.surfaceContainerLow);
      expect(todoCardColor(context), scheme.surfaceContainerHigh);
      final card = tester.widget<Material>(
        find
            .descendant(of: _key('todo-a'), matching: find.byType(Material))
            .first,
      );
      expect(card.color, scheme.surfaceContainerHigh);
      expect(
        _percentColor(tester, 'a'),
        todoProgressColor(context, 0),
        reason: '어두운 테마의 밝은 주황',
      );
    });
  });

  // ────────────────────────── 카드 ⋯ 메뉴 · 마우스 올림 ──────────────────────────
  group('카드 ⋯ 메뉴(상세 •••와 같은 항목·권한) · 마우스 올림', () {
    /// 카드 [id]의 ⋯를 눌러 메뉴를 띄운다.
    Future<void> openCardMenu(WidgetTester tester, String id) async {
      await tester.ensureVisible(_key('todo-card-menu-$id'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-card-menu-$id'));
      await tester.pumpAndSettle();
    }

    /// 떠 있는 메뉴의 항목 키 — 위에서부터.
    List<String> menuKeys(WidgetTester tester) {
      final keys = [
        for (final a in TodoMenuAction.values)
          if (_key('todo-menu-${a.name}').evaluate().isNotEmpty)
            'todo-menu-${a.name}',
      ];
      keys.sort(
        (a, b) => tester
            .getTopLeft(_key(a))
            .dy
            .compareTo(tester.getTopLeft(_key(b)).dy),
      );
      return keys;
    }

    Future<void> dismissMenu(WidgetTester tester) async {
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    }

    final roleTodos = [
      // 내가 만든 것(첨부 2개) — 전부.
      todoJson(
        id: 'mine',
        title: '내가 만든 할 일',
        assignees: ['me'],
        attachmentCount: 2,
        createdAt: 3,
      ),
      // 남이 만들고 내가 담당 — 즐겨찾기 · 수정.
      todoJson(
        id: 'assigned',
        title: '맡은 할 일',
        creatorId: 'u2',
        creatorName: '김철수',
        assignees: ['me'],
        createdAt: 2,
      ),
      // 남이 만들고 남이 담당(첨부 1개) — 즐겨찾기 · 파일 다운로드(보기만 하는 사람도).
      todoJson(
        id: 'viewer',
        title: '보기만 하는 할 일',
        creatorId: 'u2',
        creatorName: '김철수',
        assignees: ['u2'],
        attachmentCount: 1,
        createdAt: 1,
      ),
    ];

    testWidgets('카드마다 오른쪽 위 ⋯ — 항목·권한·모양이 상세 •••와 같다(만든 사람 · 담당자 · 보기만)', (
      tester,
    ) async {
      final api = FakeTodoApi(me: 'me', todos: roleTodos);
      final controller = TodoController(
        api: api,
        teamId: 't1',
        scope: TodoScope.team,
      );
      addTearDown(controller.dispose);
      await _pump(tester, const [], api: api, controller: controller);
      // ⋯는 카드 오른쪽 위 — 생성일 오른쪽, 첫 줄 높이에.
      for (final id in ['mine', 'assigned', 'viewer']) {
        final card = tester.getRect(_key('todo-$id'));
        final button = tester.getRect(_key('todo-card-menu-$id'));
        expect(card.right - button.right, moreOrLessEquals(11), reason: id);
        expect(button.top - card.top, moreOrLessEquals(12), reason: id);
        expect(
          button.left,
          greaterThan(tester.getRect(_key('todo-created-$id')).right),
          reason: '$id — 생성일과 겹치지 않는다',
        );
        expect(
          tester.getCenter(_key('todo-card-menu-$id')).dy,
          moreOrLessEquals(
            tester.getCenter(_key('todo-created-$id')).dy,
            epsilon: 3,
          ),
          reason: '$id — 첫 줄과 나란하다',
        );
        expect(
          find.descendant(
            of: _key('todo-card-menu-$id'),
            matching: find.byIcon(Icons.more_horiz),
          ),
          findsOneWidget,
        );
      }

      await openCardMenu(tester, 'mine');
      expect(menuKeys(tester), [
        'todo-menu-favorite',
        'todo-menu-edit',
        'todo-menu-download',
        'todo-menu-delete',
      ]);
      Finder inItem(String key, String text) =>
          find.descendant(of: _key(key), matching: find.text(text));
      expect(inItem('todo-menu-favorite', '즐겨찾기'), findsOneWidget);
      expect(inItem('todo-menu-edit', '할 일 수정'), findsOneWidget);
      expect(inItem('todo-menu-download', '파일 다운로드'), findsOneWidget);
      final delete = tester.widget<Text>(inItem('todo-menu-delete', '할 일 삭제'));
      final context = tester.element(_key('todo-menu-delete'));
      expect(delete.style?.color, Theme.of(context).colorScheme.error);
      // 상세 •••와 같은 간결한 메뉴 — 32 높이 항목, 창 전체(루트)의 할 일 메뉴 라우트.
      final item = tester.widget<PopupMenuItem<TodoMenuAction>>(
        _key('todo-menu-edit'),
      );
      expect(item.height, CompactMenu.itemHeight);
      expect(ModalRoute.of(context)?.settings.name, todoPopupRouteName);
      await dismissMenu(tester);

      await openCardMenu(tester, 'assigned');
      expect(menuKeys(tester), ['todo-menu-favorite', 'todo-menu-edit']);
      await dismissMenu(tester);

      await openCardMenu(tester, 'viewer');
      expect(menuKeys(tester), ['todo-menu-favorite', 'todo-menu-download']);
      await dismissMenu(tester);
      expect(find.byType(TodoDetail), findsNothing);
      expect(api.callCount('setFavorite'), 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('⋯를 눌러도 카드(상세)는 열리지 않는다 — 메뉴만 뜨고, 바깥을 눌러 닫아도 그대로', (
      tester,
    ) async {
      final api = await _pump(tester, [
        todoJson(id: 'a', title: '할 일 하나', assignees: ['me']),
      ]);
      await openCardMenu(tester, 'a');
      expect(_key('todo-menu-favorite'), findsOneWidget);
      expect(find.byType(TodoDetail), findsNothing);
      await dismissMenu(tester);
      expect(_key('todo-menu-favorite'), findsNothing);
      expect(find.byType(TodoDetail), findsNothing);
      // 카드의 다른 자리는 여전히 상세를 연다.
      await tester.tap(find.text('할 일 하나'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoDetail), findsOneWidget);
      expect(api.callCount('get'), 0);
    });

    testWidgets('즐겨찾기 / 즐겨찾기 해제 — 바로 별이 붙고 서버에 보낸 뒤 목록을 다시 받는다(즐겨찾기 먼저)', (
      tester,
    ) async {
      final api = await _pump(tester, [
        todoJson(id: 'new', title: '새 할 일', assignees: ['me'], createdAt: 2),
        todoJson(id: 'old', title: '옛 할 일', assignees: ['me'], createdAt: 1),
      ]);
      double top(String id) => tester.getTopLeft(_key('todo-$id')).dy;
      expect(top('new'), lessThan(top('old')));
      await openCardMenu(tester, 'old');
      await tester.tap(_key('todo-menu-favorite'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('setFavorite old true'));
      expect(_key('todo-fav-old'), findsOneWidget);
      expect(api.callCount('list'), 2, reason: '조용히 다시 받는다');
      expect(top('old'), lessThan(top('new')), reason: '즐겨찾기가 맨 앞');
      expect(find.byType(TodoDetail), findsNothing);

      await openCardMenu(tester, 'old');
      expect(
        find.descendant(
          of: _key('todo-menu-favorite'),
          matching: find.text('즐겨찾기 해제'),
        ),
        findsOneWidget,
      );
      await tester.tap(_key('todo-menu-favorite'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('setFavorite old false'));
      expect(_key('todo-fav-old'), findsNothing);

      // 실패하면 되돌리고 알린다.
      api.failWith = '서버 오류';
      await openCardMenu(tester, 'new');
      await tester.tap(_key('todo-menu-favorite'));
      await tester.pumpAndSettle();
      expect(_key('todo-fav-new'), findsNothing);
      expect(find.textContaining('즐겨찾기를 바꾸지 못했습니다'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('할 일 수정 — PC는 패널 안 수정 화면, 저장하면 알리고 목록을 다시 받는다', (tester) async {
      final api = await _pumpShell(tester, [
        todoJson(id: 'a', title: '고칠 할 일', assignees: ['me']),
      ]);
      await openCardMenu(tester, 'a');
      await tester.tap(_key('todo-menu-edit'));
      await tester.pumpAndSettle();
      final editor = tester.widget<TodoEditor>(find.byType(TodoEditor));
      expect(editor.mode, TodoViewMode.panel);
      expect(editor.editing?.id, 'a');
      expect(editor.onClosePanel, isNull, reason: '패널 닫기 손잡이가 없는 하네스');
      expect(tester.getRect(find.byType(TodoEditor)), _panelRect(tester));
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(TodoDetail), findsNothing, reason: '상세를 거치지 않는다');
      await tester.enterText(_key('todo-title-field'), '고친 제목');
      await tester.pump();
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(api.lastUpdate?['title'], '고친 제목');
      expect(find.byType(TodoEditor), findsNothing);
      expect(find.text('할 일을 수정했습니다.'), findsOneWidget);
      expect(find.text('고친 제목'), findsOneWidget);
      expect(api.callCount('list'), 2);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('할 일 수정 — 모바일은 전체 화면 수정 화면', (tester) async {
      await _pump(tester, [
        todoJson(id: 'a', title: '고칠 할 일', assignees: ['me']),
      ], size: const Size(390, 800));
      await openCardMenu(tester, 'a');
      await tester.tap(_key('todo-menu-edit'));
      await tester.pumpAndSettle();
      final editor = tester.widget<TodoEditor>(find.byType(TodoEditor));
      expect(editor.mode, TodoViewMode.page);
      expect(editor.editing?.id, 'a');
      expect(tester.getSize(find.byType(TodoEditor)).width, 390);
    });

    testWidgets('할 일 삭제 — 상세와 같은 확인 뒤 지우고 카드가 빠진다([취소]면 그대로)', (tester) async {
      final api = await _pump(tester, [
        todoJson(id: 'a', title: '지울 할 일', assignees: ['me']),
        todoJson(id: 'b', title: '남길 할 일', assignees: ['me']),
      ]);
      expect(find.text('2개의 할 일'), findsOneWidget);
      await openCardMenu(tester, 'a');
      await tester.tap(_key('todo-menu-delete'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('할 일 삭제'), findsOneWidget);
      expect(find.textContaining('"지울 할 일" 할 일을 삭제할까요?'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(api.callCount('delete'), 0);
      expect(_key('todo-a'), findsOneWidget);

      await openCardMenu(tester, 'a');
      await tester.tap(_key('todo-menu-delete'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-confirm-delete'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('delete a'));
      expect(_key('todo-a'), findsNothing);
      expect(_key('todo-b'), findsOneWidget);
      expect(find.text('1개의 할 일'), findsOneWidget);
      expect(find.text('할 일을 삭제했습니다.'), findsOneWidget);
      expect(find.byType(TodoDetail), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('PC — 카드 ⋯의 삭제 확인을 띄운 채 팀을 바꾸면 확인 창도 닫히고 지우지 않는다', (
      tester,
    ) async {
      final session = _session();
      final dev = Team(id: 't2', name: '개발팀', createdAt: DateTime(2026));
      session.teams.add(dev);
      final api = await _pumpShell(tester, [
        todoJson(id: 'a', title: '영업팀 할 일', assignees: ['me']),
      ], session: session);
      await openCardMenu(tester, 'a');
      await tester.tap(_key('todo-menu-delete'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      session.enterTeam(dev);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(AlertDialog), findsNothing);
      expect(api.callCount('delete'), 0);
      expect(api.lastList!['teamId'], 't2');
    });

    testWidgets('파일 다운로드 — 첨부가 있을 때만, 그 할 일의 첨부를 받고 받는 동안은 꺼진다', (
      tester,
    ) async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(
            id: 'f',
            title: '첨부 있는 할 일',
            assignees: ['me'],
            attachmentCount: 3,
            createdAt: 2,
          ),
          todoJson(
            id: 'n',
            title: '첨부 없는 할 일',
            assignees: ['me'],
            createdAt: 1,
          ),
        ],
      );
      final gate = Completer<void>();
      Todo? downloaded;
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TodosPanel(
              session: _session(),
              api: api,
              download: (context, session, todo, {onProgress}) async {
                downloaded = todo;
                onProgress?.call(0, todo.attachments.length);
                await gate.future;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openCardMenu(tester, 'n');
      expect(_key('todo-menu-download'), findsNothing);
      await dismissMenu(tester);

      await openCardMenu(tester, 'f');
      await tester.tap(_key('todo-menu-download'));
      await tester.pumpAndSettle();
      expect(downloaded?.id, 'f');
      expect(find.text('파일 3개를 다운로드하는 중입니다.'), findsOneWidget);
      expect(find.byType(TodoDetail), findsNothing);
      await openCardMenu(tester, 'f');
      PopupMenuItem<TodoMenuAction> item() => tester
          .widget<PopupMenuItem<TodoMenuAction>>(_key('todo-menu-download'));
      expect(item().enabled, isFalse, reason: '받는 동안');
      await dismissMenu(tester);
      gate.complete();
      await tester.pumpAndSettle();
      await openCardMenu(tester, 'f');
      expect(item().enabled, isTrue);
      await dismissMenu(tester);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets(
      'PC — ⋯ 메뉴는 패널 안(단추 오른쪽 끝에 맞춰)에 뜨고, 채팅 쪽을 누르면 닫히며 그 누름은 채팅에 가지 않는다',
      (tester) async {
        await _pumpShell(tester, [
          todoJson(
            id: 'a',
            title: '할 일 하나',
            assignees: ['me'],
            attachmentCount: 1,
          ),
        ]);
        await _expectClosesFromChat(
          tester,
          what: '카드 ⋯',
          open: () async {
            await openCardMenu(tester, 'a');
            expect(
              _menuRect(tester, _key('todo-menu-edit')).right,
              moreOrLessEquals(
                tester.getRect(_key('todo-card-menu-a')).right,
                epsilon: 1,
              ),
            );
          },
          shown: _key('todo-menu-edit'),
          rect: () => _menuRect(tester, _key('todo-menu-edit')),
        );
        expect(find.byType(TodoDetail), findsNothing);
        expect(find.byType(TodoEditor), findsNothing);
      },
    );

    testWidgets('할 일 일정 화면의 카드에도 ⋯ — 즐겨찾기하면 목록과 일정을 다시 받는다, 수정은 일정 위에', (
      tester,
    ) async {
      final api = await _pumpShell(tester, [
        todoJson(
          id: 'a',
          title: '오늘 할 일',
          assignees: ['me'],
          startDate: _w(_today),
          dueDate: _w(_today),
        ),
      ]);
      await _openCalendar(tester);
      final inCalendar = find.descendant(
        of: find.byType(TodoCalendarPage),
        matching: _key('todo-card-menu-a'),
      );
      expect(inCalendar, findsOneWidget);
      await tester.ensureVisible(inCalendar);
      await tester.pumpAndSettle();
      final calendarLists = api.calls
          .where((c) => c.startsWith('list') && !c.endsWith('to=null'))
          .length;
      await tester.tap(inCalendar);
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-menu-favorite'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('setFavorite a true'));
      expect(
        api.calls
            .where((c) => c.startsWith('list') && !c.endsWith('to=null'))
            .length,
        calendarLists + 1,
        reason: '일정도 다시 받는다',
      );
      expect(
        find.descendant(
          of: find.byType(TodoCalendarPage),
          matching: _key('todo-fav-a'),
        ),
        findsOneWidget,
      );
      await tester.tap(inCalendar);
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-menu-edit'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TodoEditor>(find.byType(TodoEditor)).mode,
        TodoViewMode.panel,
      );
      await tester.tap(_key('todo-page-back'));
      await tester.pumpAndSettle();
      expect(
        find.byType(TodoCalendarPage),
        findsOneWidget,
        reason: '일정으로 돌아온다',
      );
    });

    for (final brightness in Brightness.values) {
      testWidgets(
        '마우스를 올리면 카드 테두리가 주 색으로 바뀐다(${brightness.name}) — 카드 바탕은 그대로, 덧칠 없음',
        (tester) async {
          final theme = ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.indigo,
              brightness: brightness,
            ),
            useMaterial3: true,
          );
          await _pump(tester, [
            todoJson(id: 'a', title: '할 일 하나', assignees: ['me'], createdAt: 2),
            todoJson(id: 'b', title: '할 일 둘', assignees: ['me'], createdAt: 1),
          ], theme: theme);
          final context = tester.element(_key('todo-a'));
          final card = todoCardColor(context);
          final border = todoCardHoverBorder(context);
          expect(
            border.color,
            theme.colorScheme.primary.withValues(alpha: 0.55),
          );
          expect(border.width, 1.5);
          // 테두리 카드는 덧칠하지 않는다(흰 카드에 옅은 주 색을 얹으면 밝은 테마의 연보라 바탕과 같아졌다).
          final ink = tester.widget<InkWell>(
            find
                .descendant(of: _key('todo-a'), matching: find.byType(InkWell))
                .first,
          );
          expect(ink.hoverColor, Colors.transparent);
          expect(ink.highlightColor, todoCardPressColor(context));

          Material frame(String id) => tester.widget<Material>(
            find
                .descendant(
                  of: _key('todo-$id'),
                  matching: find.byType(Material),
                )
                .first,
          );
          BorderSide side(String id) =>
              (frame(id).shape! as RoundedRectangleBorder).side;
          expect(side('a'), BorderSide.none);

          final gesture = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await gesture.addPointer(location: Offset.zero);
          addTearDown(gesture.removePointer);
          await gesture.moveTo(tester.getCenter(find.text('할 일 하나')));
          await tester.pumpAndSettle();
          expect(side('a'), border);
          expect(side('b'), BorderSide.none);
          expect(frame('a').color, card, reason: '바탕은 그대로');
          // ⋯ 위로 옮겨도 카드는 올린 그대로다(⋯가 카드 안에 있다).
          await gesture.moveTo(tester.getCenter(_key('todo-card-menu-a')));
          await tester.pumpAndSettle();
          expect(side('a'), border);
          // 카드 밖으로 나가면 테두리가 사라진다.
          await gesture.moveTo(const Offset(1, 1));
          await tester.pumpAndSettle();
          expect(side('a'), BorderSide.none);
        },
      );
    }
  });

  // ────────────────────────── 화면 흐름 ──────────────────────────
  group('화면 흐름 — PC는 패널 안, 모바일은 전체 화면', () {
    testWidgets('PC — 카드를 누르면 상세가 패널 안 화면(← 할 일 … ✕)으로 — ←는 목록으로, ✕는 패널 닫기', (
      tester,
    ) async {
      var closed = 0;
      final api = await _pumpShell(tester, [
        todoJson(
          id: 'a',
          title: '상세로 열 할 일',
          description: '자세한 설명입니다',
          assignees: ['me'],
        ),
      ], onClose: () => closed++);
      final panel = _panelRect(tester);
      await tester.tap(find.text('상세로 열 할 일'));
      await tester.pumpAndSettle();
      final detail = tester.widget<TodoDetail>(find.byType(TodoDetail));
      expect(detail.mode, TodoViewMode.panel);
      expect(detail.onClosePanel, isNotNull);
      expect(
        tester.getRect(find.byType(TodoDetail)),
        panel,
        reason: '패널 칸을 채운다',
      );
      expect(_key('todo-detail-title'), findsOneWidget);
      expect(find.text('자세한 설명입니다'), findsOneWidget);
      expect(_key('todo-list'), findsNothing, reason: '목록은 상세 아래(안 보임)');
      // 상세는 패널 안 Navigator에 — 앱의 Navigator(대화상자 자리)가 아니다.
      final inner = tester.element(find.byType(TodoDetail));
      expect(
        Navigator.of(inner),
        isNot(same(Navigator.of(inner, rootNavigator: true))),
      );
      expect(find.byType(Dialog), findsNothing);

      await tester.tap(_key('todo-page-close'));
      await tester.pumpAndSettle();
      expect(closed, 1, reason: '✕는 패널 전체 닫기(TodosPanel.onClose)');

      await tester.tap(_key('todo-page-back'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoDetail), findsNothing);
      expect(_key('todo-list'), findsOneWidget);
      expect(api.callCount('list'), 1, reason: '바꾼 게 없으면 다시 받지 않는다');
    });

    testWidgets('PC — 패널 안 상세의 사진을 누르면 뷰어는 패널이 아니라 창 전체(루트 Navigator)에 뜬다', (
      tester,
    ) async {
      final json = todoJson(id: 'a', title: '사진 있는 할 일', assignees: ['me'])
        ..['attachments'] = [
          {
            'id': 'img',
            'kind': 'image',
            'fileUrl': '/files/img',
            'fileName': '사진.png',
            'fileSize': 100,
          },
        ];
      await _pumpShell(tester, [json]);
      await tester.tap(find.text('사진 있는 할 일'));
      // 사진 칸은 이미지를 기다리며 스피너를 돌려 pumpAndSettle이 끝나지 않는다 — 전환(150ms)만큼 넘긴다.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester.widget<TodoDetail>(find.byType(TodoDetail)).mode,
        TodoViewMode.panel,
      );
      final tile = find.descendant(
        of: find.byType(ChatImageAttachments),
        matching: find.byType(ClipRRect),
      );
      await tester.ensureVisible(tile.first);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(tile.first);
      // 뷰어는 이미지를 기다리며 스피너를 계속 돌리므로 pumpAndSettle은 끝나지 않는다.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final viewer = find.byType(ImageViewerScreen);
      expect(viewer, findsOneWidget);
      final context = tester.element(viewer);
      expect(
        Navigator.of(context),
        same(Navigator.of(context, rootNavigator: true)),
      );
      expect(tester.getRect(viewer).width, 1280, reason: '패널(420)이 아니라 창 전체');
      expect(find.byType(TodoDetail), findsOneWidget, reason: '닫으면 상세로 돌아온다');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('PC — 상세에서 바꾼 뒤 돌아오면 목록을 조용히 다시 받는다', (tester) async {
      final api = await _pumpShell(tester, [
        todoJson(id: 'a', title: '할 일 하나', assignees: ['me']),
      ]);
      await tester.tap(find.text('할 일 하나'));
      await tester.pumpAndSettle();
      // 상세가 "바꾼 게 있다"(true)로 닫힌 것과 같다.
      Navigator.of(tester.element(find.byType(TodoDetail))).pop(true);
      await tester.pumpAndSettle();
      expect(api.callCount('list'), 2);
      expect(_key('todo-list'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('PC — 상세의 할 일 수정도 패널 안 화면으로(상세 위에) — 닫으면 상세로 돌아온다', (
      tester,
    ) async {
      await _pumpShell(tester, [
        todoJson(id: 'a', title: '고칠 할 일', assignees: ['me']),
      ]);
      await tester.tap(find.text('고칠 할 일'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-detail-menu'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-menu-edit'));
      await tester.pumpAndSettle();
      final editor = tester.widget<TodoEditor>(find.byType(TodoEditor));
      expect(editor.mode, TodoViewMode.panel);
      expect(editor.editing?.id, 'a');
      expect(tester.getRect(find.byType(TodoEditor)), _panelRect(tester));
      expect(find.byType(Dialog), findsNothing);
      await tester.tap(_key('todo-page-back'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoEditor), findsNothing);
      expect(find.byType(TodoDetail), findsOneWidget);
    });

    testWidgets(
      'PC — 할 일 생성은 투표 만들기처럼 창 가운데 대화상자(패널 밖, 지금 연 방이 대화방 칸에) — ✕로 닫으면 목록 그대로',
      (tester) async {
        var closed = 0;
        await _pumpShell(
          tester,
          const [],
          currentRoomId: 'r2',
          onClose: () => closed++,
        );
        await tester.tap(_key('todo-create'));
        await tester.pumpAndSettle();
        final editor = tester.widget<TodoEditor>(find.byType(TodoEditor));
        expect(editor.mode, TodoViewMode.dialog);
        expect(editor.onClosePanel, isNull);
        expect(editor.room?.id, 'r2');
        expect(editor.editing, isNull);
        expect(
          find.descendant(
            of: find.byType(TodoEditor),
            matching: find.byType(Dialog),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: _key('panel-box'),
            matching: find.byType(TodoEditor),
          ),
          findsNothing,
          reason: '패널 안 Navigator가 아니라 창 전체(루트)에',
        );
        final dialog = tester.getRect(find.byType(Dialog));
        expect(dialog.center.dx, closeTo(640, 1), reason: '창 가운데');
        expect(dialog.left, lessThan(_panelRect(tester).left));
        // 패널 안 화면 머리(← 할 일 … ✕)가 아니라 대화상자 머리(`할 일 생성` + ✕).
        expect(_key('todo-page-back'), findsNothing);
        expect(
          find.descendant(
            of: find.byType(Dialog),
            matching: find.text('할 일 생성'),
          ),
          findsOneWidget,
        );
        await tester.tap(_key('todo-editor-close'));
        await tester.pumpAndSettle();
        expect(find.byType(TodoEditor), findsNothing);
        expect(_key('todo-create'), findsOneWidget);
        expect(closed, 0);
      },
    );

    testWidgets('PC — 할 일 일정은 패널 안 화면(← 할 일 … ✕) — ←로 닫으면 달력 받기를 멈춘다', (
      tester,
    ) async {
      var closed = 0;
      final api = FakeTodoApi(me: 'me');
      final controller = TodoController(api: api, teamId: 't1');
      await _pumpShell(
        tester,
        const [],
        api: api,
        controller: controller,
        onClose: () => closed++,
      );
      await _openCalendar(tester);
      final page = tester.widget<TodoCalendarPage>(
        find.byType(TodoCalendarPage),
      );
      expect(page.mode, TodoViewMode.panel);
      expect(tester.getRect(find.byType(TodoCalendarPage)), _panelRect(tester));
      expect(find.byType(TodoPageHeader), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(TodoPageHeader),
          matching: find.text('할 일'),
        ),
        findsOneWidget,
      );
      expect(_key('todo-calendar'), findsOneWidget);
      expect(controller.calendarMonth, _thisMonth);
      expect(_key('todo-list'), findsNothing);

      await tester.tap(_key('todo-page-close'));
      await tester.pumpAndSettle();
      expect(closed, 1);

      await tester.tap(_key('todo-page-back'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoCalendarPage), findsNothing);
      expect(controller.calendarMonth, isNull, reason: '닫으면 달력 받기를 멈춘다');
      expect(_key('todo-list'), findsNothing, reason: '빈 목록');
      expect(find.text('나에게 지정된 할 일이 없어요.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    testWidgets('PC — 패널을 열기만 해서는 채팅 입력칸의 포커스를 가져가지 않는다', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final input = FocusNode();
      addTearDown(input.dispose);
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(id: 'a', title: '할 일 하나', assignees: ['me']),
        ],
      );
      final session = _session();
      var open = false;
      late StateSetter setOuter;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeShellScope(
              openPanelKey: null,
              panelRoom: null,
              panelGeneration: 0,
              currentRoomId: null,
              togglePanel: (_) {},
              closePanel: () {},
              toggleCalendar: () {},
              openRoom: (room, {messageId}) {},
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuter = setState;
                  return Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('chat-input'),
                          focusNode: input,
                        ),
                      ),
                      if (open)
                        SizedBox(
                          width: 420,
                          child: TodosPanel(session: session, api: api),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(_key('chat-input'));
      await tester.pump();
      expect(input.hasFocus, isTrue);
      setOuter(() => open = true);
      await tester.pumpAndSettle();
      expect(find.text('할 일 하나'), findsOneWidget);
      expect(input.hasFocus, isTrue, reason: '쓰던 글을 이어 쓸 수 있다');
      // 패널에서 누른 화면(상세)은 포커스를 가져가고, 닫으면 목록으로 돌아온다.
      await tester.tap(find.text('할 일 하나'));
      await tester.pumpAndSettle();
      expect(input.hasFocus, isFalse);
      await tester.tap(_key('todo-page-back'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoDetail), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('PC — 시스템 뒤로 가기는 패널 안 화면부터 닫는다(안드로이드 태블릿)', (tester) async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(id: 'a', title: '할 일 하나', assignees: ['me']),
        ],
      );
      final controller = TodoController(api: api, teamId: 't1');
      await _pumpShell(tester, const [], api: api, controller: controller);
      await tester.tap(find.text('할 일 하나'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoDetail), findsOneWidget);
      await _systemBack(tester);
      expect(find.byType(TodoDetail), findsNothing);
      expect(_key('todo-list'), findsOneWidget);

      await _openCalendar(tester);
      expect(find.byType(TodoCalendarPage), findsOneWidget);
      await _systemBack(tester);
      expect(find.byType(TodoCalendarPage), findsNothing);
      expect(controller.calendarMonth, isNull);
      expect(_key('todo-list'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    testWidgets('PC — 팀을 바꾸면 패널 안 화면(상세·일정)을 닫고 새 팀의 목록으로 돌아간다', (
      tester,
    ) async {
      final session = _session();
      final sales = session.teams.single;
      final dev = Team(id: 't2', name: '개발팀', createdAt: DateTime(2026));
      session.teams.add(dev);
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(
            id: 'a',
            title: '영업팀 할 일',
            assignees: ['me'],
            dueDate: _w(_today),
          ),
          todoJson(
            id: 'z',
            teamId: 't2',
            roomId: 'x1',
            roomName: '개발팀 토픽',
            title: '개발팀 할 일',
            assignees: ['me'],
          ),
        ],
      );
      await _pumpShell(tester, const [], api: api, session: session);
      await tester.tap(find.text('영업팀 할 일'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoDetail), findsOneWidget);

      session.enterTeam(dev);
      await tester.pumpAndSettle();
      expect(find.byType(TodoDetail), findsNothing);
      expect(api.lastList!['teamId'], 't2');
      expect(find.text('개발팀 할 일'), findsOneWidget);
      expect(find.text('영업팀 할 일'), findsNothing);
      expect(tester.widget<Text>(_key('todo-room-z')).data, '개발팀 토픽');

      // 일정 화면을 띄운 채 바꿔도 닫히고, 새 팀의 컨트롤러는 달력을 받지 않는다.
      await _openCalendar(tester);
      expect(find.byType(TodoCalendarPage), findsOneWidget);
      session.enterTeam(sales);
      await tester.pumpAndSettle();
      expect(find.byType(TodoCalendarPage), findsNothing);
      expect(api.lastList!['teamId'], 't1');
      expect(api.lastList!['from'], isNull);
      expect(find.text('영업팀 할 일'), findsOneWidget);
      // 다시 열면 새 팀(지금 팀)의 일정을 받는다.
      await _openCalendar(tester);
      expect(api.lastList!['teamId'], 't1');
      expect(api.lastList!['from'], isNotNull);
      expect(find.text('영업팀 할 일'), findsOneWidget);
    });

    testWidgets('PC — 팀을 바꾸면 패널 안 화면이 창 전체(루트)에 띄운 확인 창(삭제·작성 취소)도 함께 닫힌다', (
      tester,
    ) async {
      final session = _session();
      final sales = session.teams.single;
      final dev = Team(id: 't2', name: '개발팀', createdAt: DateTime(2026));
      session.teams.add(dev);
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(id: 'a', title: '영업팀 할 일', assignees: ['me']),
          todoJson(
            id: 'z',
            teamId: 't2',
            roomId: 'x1',
            roomName: '개발팀 토픽',
            title: '개발팀 할 일',
            assignees: ['me'],
          ),
        ],
      );
      await _pumpShell(tester, const [], api: api, session: session);
      // 상세의 삭제 확인을 띄운 채 팀이 바뀐다(예: 다른 팀 방의 알림을 눌러).
      await tester.tap(find.text('영업팀 할 일'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-detail-menu'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-menu-delete'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      session.enterTeam(dev);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(TodoDetail), findsNothing);
      expect(api.callCount('delete'), 0);
      expect(api.lastList!['teamId'], 't2');

      // 패널 안 수정 화면(상세 ••• → 할 일 수정)의 "작성 취소" 확인도.
      await tester.tap(find.text('개발팀 할 일'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-detail-menu'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-menu-edit'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TodoEditor>(find.byType(TodoEditor)).mode,
        TodoViewMode.panel,
      );
      await tester.enterText(_key('todo-title-field'), '쓰던 제목');
      await tester.pump();
      await tester.tap(_key('todo-page-back'));
      await tester.pumpAndSettle();
      expect(find.text('작성 취소'), findsOneWidget);
      session.enterTeam(sales);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('작성 취소'), findsNothing);
      expect(find.byType(TodoEditor), findsNothing);
      expect(find.byType(TodoDetail), findsNothing);
      expect(api.callCount('update'), 0);
      expect(find.text('영업팀 할 일'), findsOneWidget);
    });

    testWidgets('모바일 — 상세·생성·일정은 앱 Navigator의 전체 화면이고 뒤로 가기로 닫는다', (
      tester,
    ) async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(
            id: 'a',
            title: '할 일 하나',
            assignees: ['me'],
            dueDate: _w(_today),
          ),
        ],
      );
      final controller = TodoController(api: api, teamId: 't1');
      await _pump(
        tester,
        const [],
        api: api,
        controller: controller,
        size: const Size(390, 800),
      );
      await tester.tap(find.text('할 일 하나'));
      await tester.pumpAndSettle();
      final detail = tester.widget<TodoDetail>(find.byType(TodoDetail));
      expect(detail.mode, TodoViewMode.page);
      expect(detail.onClosePanel, isNull);
      final inner = tester.element(find.byType(TodoDetail));
      expect(
        Navigator.of(inner),
        same(Navigator.of(inner, rootNavigator: true)),
      );
      await _systemBack(tester);
      expect(find.byType(TodoDetail), findsNothing);

      await tester.tap(_key('todo-create'));
      await tester.pumpAndSettle();
      final editor = tester.widget<TodoEditor>(find.byType(TodoEditor));
      expect(editor.mode, TodoViewMode.page);
      expect(editor.onClosePanel, isNull);
      // 생성은 대화상자가 아니라 앱 Navigator의 전체 화면(앱 바 ✕ · 할 일 생성 · 저장하기).
      expect(find.byType(Dialog), findsNothing);
      expect(tester.getSize(find.byType(TodoEditor)), const Size(390, 800));
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('할 일 생성')),
        findsOneWidget,
      );
      await _systemBack(tester);
      expect(find.byType(TodoEditor), findsNothing);

      await _openCalendar(tester);
      final page = tester.widget<TodoCalendarPage>(
        find.byType(TodoCalendarPage),
      );
      expect(page.mode, TodoViewMode.page);
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('할 일 일정')),
        findsOneWidget,
      );
      expect(find.byType(TodoPageHeader), findsNothing);
      expect(controller.calendarMonth, _thisMonth);
      // 일정 화면의 카드도 앱 Navigator에 전체 화면 상세로 — 닫으면 일정 화면으로.
      await tester.tap(find.text('할 일 하나'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TodoDetail>(find.byType(TodoDetail)).mode,
        TodoViewMode.page,
      );
      await _systemBack(tester);
      expect(find.byType(TodoCalendarPage), findsOneWidget);
      await _systemBack(tester);
      expect(find.byType(TodoCalendarPage), findsNothing);
      expect(controller.calendarMonth, isNull);
      expect(_key('todo-list'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  });

  // ────────────────────────── 할 일 일정 ──────────────────────────
  group('할 일 일정', () {
    testWidgets(
      '열면 오늘이 있는 달의 42칸 범위를 한 번에 받는다 — 요일 머리는 차분한 회색, 날짜는 두 자리, 처음엔 오늘',
      (tester) async {
        final api = await _pump(tester, const []);
        final before = api.callCount('list');
        await _openCalendar(tester);
        final (from, to) = todoCalendarRange(_thisMonth);
        expect(api.callCount('list'), before + 1);
        expect(api.lastList!['from'], _w(from));
        expect(api.lastList!['to'], _w(to));
        expect(api.lastList!['limit'], todoRangeMaxLimit);
        expect(api.lastList!['sort'], TodoSort.due);
        expect(api.lastList!['scope'], TodoScope.mine);
        expect(_key('todo-calendar'), findsOneWidget);
        expect(
          tester.widget<Text>(_key('todo-cal-month')).data,
          _monthText(_thisMonth),
        );
        expect(_selectedYmd(tester), _w(_today), reason: '처음엔 오늘');
        for (var i = 0; i < 42; i++) {
          final day = DateTime(from.year, from.month, from.day + i);
          expect(_key('todo-cal-day-${_w(day)}'), findsOneWidget);
        }
        for (final key in const [
          'todo-cal-prev-year',
          'todo-cal-prev',
          'todo-cal-next',
          'todo-cal-next-year',
          'todo-cal-today',
        ]) {
          expect(_key(key), findsOneWidget);
        }
        final context = tester.element(_key('todo-calendar'));
        final theme = Theme.of(context);
        Text header(String label) => tester.widget<Text>(
          find.descendant(
            of: _key('todo-calendar'),
            matching: find.text(label),
          ),
        );
        expect(header('일').style?.color, theme.hintColor);
        expect(header('토').style?.color, theme.hintColor);
        // 날짜는 두 자리, 이웃 달 날짜는 흐리게.
        final first = _dayOf(_thisMonth, 1);
        final day1 = tester.widget<Text>(
          find.descendant(
            of: _key('todo-cal-day-${_w(first)}'),
            matching: find.text('01'),
          ),
        );
        if (first != _today) {
          expect(day1.style?.color, theme.colorScheme.onSurface);
        }
        final lastCell = tester.widget<Text>(
          find.descendant(
            of: _key('todo-cal-day-${_w(to)}'),
            matching: find.byType(Text),
          ),
        );
        expect(
          lastCell.style?.color,
          theme.disabledColor,
          reason: '42칸의 끝은 늘 다음 달',
        );
        // 아직 할 일이 없다.
        expect(
          tester.widget<Text>(_key('todo-cal-day-count')).data,
          '할 일이 없습니다.',
        );
      },
    );

    testWidgets(
      '할 일이 걸친 날은 숫자 아래 작은 점(이웃 달 칸도, 날짜 없는 할 일은 빠짐) — 칸은 "N월 D일, 할 일 K개"로 읽는다',
      (tester) async {
        final m = _thisMonth;
        final (from, _) = todoCalendarRange(m);
        await _pump(tester, [
          todoJson(
            id: 'A',
            title: '사흘',
            assignees: ['me'],
            startDate: _w(_dayOf(m, 10)),
            dueDate: _w(_dayOf(m, 12)),
          ),
          todoJson(
            id: 'B',
            title: '하루',
            assignees: ['me'],
            roomId: 'r2',
            roomName: '개발 토픽',
            dueDate: _w(_dayOf(m, 11)),
            createdAt: 2,
          ),
          todoJson(
            id: 'C',
            title: '스무날',
            assignees: ['me'],
            dueDate: _w(_dayOf(m, 20)),
            createdAt: 3,
          ),
          todoJson(id: 'D', title: '날짜 없음', assignees: ['me'], createdAt: 4),
          todoJson(
            id: 'E',
            title: '첫 칸',
            assignees: ['me'],
            dueDate: _w(from),
            createdAt: 5,
          ),
        ]);
        await _openCalendar(tester);
        expect(_dot(_dayOf(m, 9)), isFalse);
        expect(_dot(_dayOf(m, 10)), isTrue);
        expect(_dot(_dayOf(m, 11)), isTrue);
        expect(_dot(_dayOf(m, 12)), isTrue);
        expect(_dot(_dayOf(m, 13)), isFalse);
        expect(_dot(_dayOf(m, 20)), isTrue);
        expect(_dot(from), isTrue, reason: '달력 첫 칸(이웃 달일 수 있다)');
        // 점은 작은 동그라미 하나(개수 숫자 대신).
        final dot = tester.getSize(_key('todo-cal-dot-${_w(_dayOf(m, 11))}'));
        expect(dot, const Size(4, 4));
        expect(
          find.descendant(
            of: _key('todo-cal-day-${_w(_dayOf(m, 11))}'),
            matching: find.text('2'),
          ),
          findsNothing,
        );
        // 칸 하나는 "N월 D일, 할 일 K개" 한 마디로 읽는다.
        final semantics = tester.ensureSemantics();
        expect(
          tester.getSemantics(_key('todo-cal-day-${_w(_dayOf(m, 11))}')),
          isSemantics(
            label: '${m.month}월 11일, 할 일 2개',
            isButton: true,
            hasTapAction: true,
          ),
        );
        semantics.dispose();
      },
    );

    testWidgets('날짜를 고르면 그날의 할 일을 대화방별 묶음 카드로 — 방 순서는 받은 목록에 처음 나온 순', (
      tester,
    ) async {
      final m = _thisMonth;
      final d11 = _dayOf(m, 11);
      await _pump(tester, size: const Size(420, 1500), [
        todoJson(
          id: 'X',
          title: '개발 하루',
          roomId: 'r2',
          roomName: '개발 토픽',
          assignees: ['me'],
          dueDate: _w(d11),
          createdAt: 1,
        ),
        todoJson(
          id: 'Y',
          title: '영업 사흘',
          assignees: ['me'],
          startDate: _w(_dayOf(m, 10)),
          dueDate: _w(_dayOf(m, 12)),
          createdAt: 2,
        ),
        todoJson(
          id: 'Z',
          title: '개발 즐겨찾기',
          roomId: 'r2',
          roomName: '개발 토픽',
          assignees: ['me'],
          assigneeProgress: {'me': 25},
          startDate: _w(d11),
          dueDate: _w(_dayOf(m, 15)),
          favorite: true,
          createdAt: 3,
        ),
        todoJson(
          id: 'O',
          title: '다른 날',
          roomId: 'g1',
          roomName: '디자인 그룹',
          assignees: ['me'],
          dueDate: _w(_dayOf(m, 20)),
          createdAt: 4,
        ),
      ]);
      await _openCalendar(tester);
      await _tapDay(tester, d11);
      expect(_selectedYmd(tester), _w(d11));
      expect(
        tester.widget<Text>(_key('todo-cal-day-count')).data,
        '3개의 할 일이 있습니다.',
      );
      // 받은 순서는 Z(즐겨찾기) → X(11일) → Y(12일) — 방은 개발 토픽, 영업 토픽 순.
      double top(Finder f) => tester.getTopLeft(f).dy;
      final r2 = top(_key('todo-cal-room-r2'));
      final r1 = top(_key('todo-cal-room-r1'));
      expect(r2, lessThan(top(_key('todo-Z'))));
      expect(top(_key('todo-Z')), lessThan(top(_key('todo-X'))));
      expect(top(_key('todo-X')), lessThan(r1));
      expect(r1, lessThan(top(_key('todo-Y'))));
      for (final (room, name, count) in const [
        ('r2', '개발 토픽', '2'),
        ('r1', '영업 토픽', '1'),
      ]) {
        final header = _key('todo-cal-room-$room');
        expect(
          find.descendant(of: header, matching: find.text(name)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: header, matching: find.text(count)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: header, matching: find.byIcon(Icons.tag)),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: header,
            matching: find.byIcon(Icons.keyboard_arrow_up),
          ),
          findsOneWidget,
          reason: '처음엔 펼쳐져 있다',
        );
      }
      expect(find.text('다른 날'), findsNothing);
      expect(_key('todo-cal-room-g1'), findsNothing);
      // 묶음 안의 카드는 목록과 같은 카드(대화방 줄은 머리에 있어 뺀다).
      expect(_key('todo-room-Z'), findsNothing);
      expect(_percent(tester, 'Z'), '25%');
      expect(_key('todo-fav-Z'), findsOneWidget);
      expect(
        tester.widget<Text>(_key('todo-period-Z')).data,
        startsWith('일정: '),
      );
      // 묶음은 카드 바탕의 둥근 카드 하나 — 안의 카드는 따로 테두리를 두지 않는다.
      final group = find.ancestor(
        of: _key('todo-cal-room-r2'),
        matching: find.byType(Material),
      );
      final context = tester.element(_key('todo-calendar'));
      expect(
        tester
            .widgetList<Material>(group)
            .any(
              (g) =>
                  g.color == todoCardColor(context) &&
                  g.borderRadius == BorderRadius.circular(12),
            ),
        isTrue,
      );
      expect(
        tester.getRect(_key('todo-Z')).width,
        moreOrLessEquals(tester.getRect(_key('todo-cal-room-r2')).width),
      );
    });

    testWidgets('묶음 머리를 누르면 접고 편다(^/v) — 개수는 그대로, 다른 날로 옮겨도 접은 채', (
      tester,
    ) async {
      final tomorrow = DateTime(_today.year, _today.month, _today.day + 1);
      await _pump(tester, size: const Size(420, 1400), [
        todoJson(
          id: 'a1',
          title: '영업 하나',
          assignees: ['me'],
          dueDate: _w(_today),
        ),
        todoJson(
          id: 'a2',
          title: '영업 둘',
          assignees: ['me'],
          startDate: _w(_today),
          dueDate: _w(tomorrow),
          createdAt: 2,
        ),
        todoJson(
          id: 'b1',
          title: '개발 하나',
          roomId: 'r2',
          roomName: '개발 토픽',
          assignees: ['me'],
          dueDate: _w(_today),
          createdAt: 3,
        ),
      ]);
      await _openCalendar(tester);
      expect(find.text('영업 하나'), findsOneWidget);
      expect(find.text('영업 둘'), findsOneWidget);
      await tester.tap(_key('todo-cal-room-r1'));
      await tester.pumpAndSettle();
      expect(find.text('영업 하나'), findsNothing);
      expect(find.text('영업 둘'), findsNothing);
      expect(find.text('개발 하나'), findsOneWidget, reason: '다른 방은 그대로');
      final header = _key('todo-cal-room-r1');
      expect(
        find.descendant(
          of: header,
          matching: find.byIcon(Icons.keyboard_arrow_down),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: header, matching: find.text('2')),
        findsOneWidget,
        reason: '접어도 개수는 보인다',
      );
      expect(
        tester.widget<Text>(_key('todo-cal-day-count')).data,
        '3개의 할 일이 있습니다.',
      );
      // 내일(그 방의 할 일이 또 있는 날)로 가도 접은 채.
      await _tapDay(tester, tomorrow);
      expect(_key('todo-cal-room-r1'), findsOneWidget);
      expect(find.text('영업 둘'), findsNothing);
      await tester.tap(_key('todo-cal-room-r1'));
      await tester.pumpAndSettle();
      expect(find.text('영업 둘'), findsOneWidget);
      expect(
        find.descendant(
          of: _key('todo-cal-room-r1'),
          matching: find.byIcon(Icons.keyboard_arrow_up),
        ),
        findsOneWidget,
      );
    });

    testWidgets('내 목록에 없는 방은 서버가 준 이름으로 묶는다', (tester) async {
      await _pump(tester, [
        todoJson(
          id: 'w',
          title: '나간 방 할 일',
          roomId: 'gone',
          roomName: '나간 토픽',
          assignees: ['me'],
          dueDate: _w(_today),
        ),
      ]);
      await _openCalendar(tester);
      final header = _key('todo-cal-room-gone');
      expect(
        find.descendant(of: header, matching: find.text('나간 토픽')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: header, matching: find.byIcon(Icons.tag)),
        findsOneWidget,
      );
    });

    testWidgets('할 일이 없는 날은 "할 일이 없습니다."', (tester) async {
      final m = _thisMonth;
      await _pump(tester, [
        todoJson(
          id: 'a',
          title: '열흘날 할 일',
          assignees: ['me'],
          dueDate: _w(_dayOf(m, 10)),
        ),
      ]);
      await _openCalendar(tester);
      await _tapDay(tester, _dayOf(m, 13));
      expect(
        tester.widget<Text>(_key('todo-cal-day-count')).data,
        '할 일이 없습니다.',
      );
      expect(find.text('열흘날 할 일'), findsNothing);
      await _tapDay(tester, _dayOf(m, 10));
      expect(
        tester.widget<Text>(_key('todo-cal-day-count')).data,
        '1개의 할 일이 있습니다.',
      );
      expect(find.text('열흘날 할 일'), findsOneWidget);
    });

    testWidgets(
      '달·해 이동 — 그 달 범위로 다시 받고, 고른 날은 그 달 안이면 그대로·아니면 1일, "오늘"은 이번 달 오늘',
      (tester) async {
        final api = await _pump(tester, const [], size: const Size(420, 1100));
        await _openCalendar(tester);
        final m = _thisMonth;
        final next = DateTime(m.year, m.month + 1);
        final prev = DateTime(m.year, m.month - 1);
        String? month() => tester.widget<Text>(_key('todo-cal-month')).data;
        void expectRange(DateTime month) {
          final (from, to) = todoCalendarRange(month);
          expect(api.lastList!['from'], _w(from));
          expect(api.lastList!['to'], _w(to));
        }

        var calls = api.callCount('list');
        await tester.tap(_key('todo-cal-next'));
        await tester.pumpAndSettle();
        expect(api.callCount('list'), calls + 1);
        expectRange(next);
        expect(month(), _monthText(next));
        expect(_selectedYmd(tester), _w(next), reason: '오늘은 다음 달에 없다 → 1일');

        await tester.tap(_key('todo-cal-prev'));
        await tester.pumpAndSettle();
        await tester.tap(_key('todo-cal-prev'));
        await tester.pumpAndSettle();
        expectRange(prev);
        expect(month(), _monthText(prev));
        expect(_selectedYmd(tester), _w(prev));

        // 이웃 달 칸(이번 달 날짜)을 고른 채 이번 달로 가면 고른 날은 그대로다.
        final (_, prevTo) = todoCalendarRange(prev);
        expect(prevTo.month, m.month, reason: '42칸의 끝은 늘 다음 달');
        await _tapDay(tester, prevTo);
        expect(_selectedYmd(tester), _w(prevTo));
        await tester.tap(_key('todo-cal-next'));
        await tester.pumpAndSettle();
        expectRange(m);
        expect(_selectedYmd(tester), _w(prevTo), reason: '그 달 안이면 그대로');

        // «·»는 한 해(12달)씩.
        final nextYear = DateTime(m.year + 1, m.month);
        await tester.tap(_key('todo-cal-next-year'));
        await tester.pumpAndSettle();
        expectRange(nextYear);
        expect(month(), _monthText(nextYear));
        expect(_selectedYmd(tester), _w(nextYear));
        await tester.tap(_key('todo-cal-prev-year'));
        await tester.pumpAndSettle();
        await tester.tap(_key('todo-cal-prev-year'));
        await tester.pumpAndSettle();
        final lastYear = DateTime(m.year - 1, m.month);
        expectRange(lastYear);
        expect(month(), _monthText(lastYear));

        // 다른 달에서 "오늘"은 이번 달로 돌아와 오늘을 고른다.
        await tester.tap(_key('todo-cal-today'));
        await tester.pumpAndSettle();
        expectRange(m);
        expect(month(), _monthText(m));
        expect(_selectedYmd(tester), _w(_today));

        // 이번 달에서 "오늘"은 다시 받지 않고 오늘만 고른다.
        await _tapDay(tester, _dayOf(m, _today.day == 1 ? 2 : 1));
        calls = api.callCount('list');
        await tester.tap(_key('todo-cal-today'));
        await tester.pumpAndSettle();
        expect(api.callCount('list'), calls);
        expect(_selectedYmd(tester), _w(_today));
      },
    );

    testWidgets('목록에서 고른 필터(보기·대화방·멤버·완료 제외)를 그대로 쓴다 — 일정 화면에는 필터가 없다', (
      tester,
    ) async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(
            id: 'mine',
            title: '내 일',
            assignees: ['me'],
            dueDate: _w(_today),
          ),
          todoJson(
            id: 'given',
            title: '맡긴 일',
            assignees: ['u2'],
            assigneeProgress: {'u2': 50},
            dueDate: _w(_today),
            createdAt: 2,
          ),
          todoJson(
            id: 'finished',
            title: '끝난 맡긴 일',
            assignees: ['u2'],
            assigneeProgress: {'u2': 100},
            dueDate: _w(_today),
            createdAt: 3,
          ),
          todoJson(
            id: 'other',
            title: '다른 방 맡긴 일',
            roomId: 'r2',
            roomName: '개발 토픽',
            assignees: ['u2'],
            dueDate: _w(_today),
            createdAt: 4,
          ),
        ],
      );
      final controller = TodoController(
        api: api,
        teamId: 't1',
        scope: TodoScope.assignedByMe,
        roomId: 'r1',
        assigneeId: 'u2',
      );
      await _pump(tester, const [], api: api, controller: controller);
      await tester.tap(_key('todo-exclude-done'));
      await tester.pumpAndSettle();
      await _openCalendar(tester);
      final list = api.lastList!;
      expect(list['from'], isNotNull);
      expect(list['scope'], TodoScope.assignedByMe);
      expect(list['roomId'], 'r1');
      expect(list['assigneeId'], 'u2');
      expect(list['includeDone'], isFalse);
      expect(find.text('맡긴 일'), findsOneWidget);
      expect(find.text('끝난 맡긴 일'), findsNothing);
      expect(find.text('다른 방 맡긴 일'), findsNothing);
      expect(find.text('내 일'), findsNothing);
      expect(_percent(tester, 'given'), '50%', reason: '고른 멤버의 진척률');
      // 일정 화면에는 필터·정렬이 없다(목록 화면은 아래에 가려져 있다).
      expect(_key('todo-scope'), findsNothing);
      expect(find.byType(RoomFilterButton), findsNothing);
      expect(_key('todo-assignee-filter'), findsNothing);
      expect(_key('todo-exclude-done'), findsNothing);
      expect(_key('todo-sort'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    testWidgets(
      'PC — 일정의 카드를 누르면 상세가 그 위에(패널 안) — 바꾼 게 있으면 목록과 일정을 조용히 다시 받는다',
      (tester) async {
        final api = await _pumpShell(tester, [
          todoJson(
            id: 'a',
            title: '오늘 할 일',
            assignees: ['me'],
            dueDate: _w(_today),
          ),
        ]);
        await _openCalendar(tester);
        await tester.tap(find.text('오늘 할 일'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TodoDetail>(find.byType(TodoDetail)).mode,
          TodoViewMode.panel,
        );
        expect(_key('todo-calendar'), findsNothing, reason: '상세 아래에 가려진다');
        final before = api.callCount('list');
        // 상세가 "바꾼 게 있다"(true)로 닫힌 것과 같다.
        Navigator.of(tester.element(find.byType(TodoDetail))).pop(true);
        await tester.pumpAndSettle();
        final fresh = api.calls
            .where((c) => c.startsWith('list'))
            .skip(before)
            .toList();
        final (from, _) = todoCalendarRange(_thisMonth);
        expect(fresh, hasLength(2));
        expect(
          fresh.where((c) => c.endsWith('from=null to=null')),
          hasLength(1),
        );
        expect(
          fresh.where((c) => c.contains('from=${_w(from)}')),
          hasLength(1),
        );
        expect(_key('todo-calendar'), findsOneWidget, reason: '일정 화면으로 돌아온다');
        expect(find.text('오늘 할 일'), findsOneWidget);
      },
    );

    testWidgets('받는 동안은 돌아가는 표시, 실패하면 문구와 다시 시도', (tester) async {
      final api = _RangeFailApi(
        todos: [
          todoJson(
            id: 'a',
            title: '오늘 할 일',
            assignees: ['me'],
            dueDate: _w(_today),
          ),
        ],
      );
      await _pump(tester, const [], api: api);
      await _openCalendar(tester);
      expect(tester.widget<Text>(_key('todo-cal-error')).data, '서버 오류');
      expect(find.text('오늘 할 일'), findsNothing);
      expect(_dot(_today), isFalse);
      expect(_key('todo-cal-day-count'), findsNothing, reason: '아직 모른다');

      api.failRange = false;
      final gate = Completer<void>();
      api.listGate = gate.future;
      await tester.tap(_key('todo-cal-retry'));
      await tester.pump();
      expect(_key('todo-cal-loading'), findsOneWidget);
      expect(_key('todo-cal-error'), findsNothing);
      gate.complete();
      await tester.pumpAndSettle();
      expect(_key('todo-cal-loading'), findsNothing);
      expect(find.text('오늘 할 일'), findsOneWidget);
      expect(_dot(_today), isTrue);
    });
  });

  // ────────────────────────── 폭 ──────────────────────────
  group('좁은 폭', () {
    for (final width in [360.0, 390.0, 420.0]) {
      testWidgets(
        '폭 $width — 부여한 할 일(멤버·긴 방 이름)과 일정 화면이 넘치지 않고, 일정은 달력과 묶음이 한 번에 스크롤된다',
        (tester) async {
          final api = FakeTodoApi(
            me: 'me',
            todos: [
              todoJson(
                id: 'a',
                title: '아주 아주 긴 제목의 할 일이라서 두 줄로 넘어가야 하는 경우도 잘 보이는지 확인합니다 계속 계속',
                description:
                    '아주 긴 설명이 들어가는 경우도 두 줄에서 잘리는지 확인하는 설명입니다. 계속 이어지는 설명',
                roomId: 'long',
                roomName: _longRoomName,
                assignees: ['u2', 'u3', 'u4', 'u5', 'u6'],
                assigneeProgress: {'u2': 75},
                startDate: '2020-01-02',
                dueDate: _w(_today),
                attachmentCount: 12,
                favorite: true,
              ),
              todoJson(
                id: 'b',
                title: '두 번째 할 일',
                roomId: 'long',
                roomName: _longRoomName,
                assignees: ['u2'],
                dueDate: _w(_today),
                createdAt: 2,
              ),
            ],
          );
          final controller = TodoController(
            api: api,
            teamId: 't1',
            scope: TodoScope.assignedByMe,
            roomId: 'long',
            assigneeId: 'u2',
          );
          await _pump(
            tester,
            const [],
            api: api,
            controller: controller,
            size: Size(width, 640),
          );
          expect(tester.takeException(), isNull);
          expect(_key('todo-assignee-filter'), findsOneWidget);
          expect(_percent(tester, 'a'), '75%');
          await _openCalendar(tester);
          expect(tester.takeException(), isNull);
          // 키가 낮아도 달력 아래 고른 날의 묶음까지 한 번에 내려간다.
          await tester.drag(_key('todo-calendar'), const Offset(0, -900));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('두 번째 할 일'), findsOneWidget);
          expect(
            tester.getBottomLeft(find.text('두 번째 할 일')).dy,
            lessThan(640),
            reason: '스크롤해서 보인다',
          );
          await tester.pumpWidget(const SizedBox());
          controller.dispose();
        },
      );
    }

    testWidgets('PC 420 — 패널 안 목록·일정 화면이 넘치지 않는다', (tester) async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(
            id: 'a',
            title: '아주 아주 긴 제목의 할 일이라서 두 줄로 넘어가야 하는 경우도 잘 보이는지 확인합니다 계속 계속',
            roomId: 'long',
            roomName: _longRoomName,
            assignees: ['u2', 'u3'],
            dueDate: _w(_today),
            attachmentCount: 3,
          ),
        ],
      );
      final controller = TodoController(
        api: api,
        teamId: 't1',
        scope: TodoScope.assignedByMe,
      );
      await _pumpShell(
        tester,
        const [],
        api: api,
        controller: controller,
        height: 600,
      );
      expect(tester.takeException(), isNull);
      await _openCalendar(tester);
      expect(tester.takeException(), isNull);
      await tester.drag(_key('todo-calendar'), const Offset(0, -900));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('아주 아주 긴 제목'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  });

  // ────────────────────────── 건수 줄 — 개수를 모를 때 ──────────────────────────
  group('건수 줄 — 개수를 모르는 동안은 0이 아니라 빈 줄', () {
    testWidgets(
      '처음 받는 동안·보기나 완료 제외를 바꿔 다시 받는 동안은 같은 높이의 빈 줄, 받으면 그 자리에 개수(조용히 다시 받을 때는 그대로)',
      (tester) async {
        final changed = StreamController<Map<String, dynamic>>.broadcast();
        addTearDown(changed.close);
        final api = FakeTodoApi(
          me: 'me',
          todos: [
            todoJson(id: 'a', title: '하나', assignees: ['me']),
            todoJson(id: 'b', title: '둘', assignees: ['me'], createdAt: 2),
          ],
        );
        final controller = TodoController(
          api: api,
          teamId: 't1',
          changed: changed.stream,
        );
        var gate = Completer<void>();
        api.listGate = gate.future;
        await _pump(
          tester,
          const [],
          api: api,
          controller: controller,
          settle: false,
        );
        expect(_key('panel-loaded-count'), findsNothing);
        expect(find.textContaining('개의 할 일'), findsNothing, reason: '0개가 아니다');
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        final pending = tester.getRect(_key('panel-count-pending'));
        gate.complete();
        await tester.pumpAndSettle();
        expect(find.text('2개의 할 일'), findsOneWidget);
        expect(_key('panel-count-pending'), findsNothing);
        final loaded = tester.getRect(_key('panel-loaded-count'));
        expect(loaded.top, pending.top);
        expect(loaded.height, pending.height, reason: '받아도 목록이 밀리지 않는다');

        // 보기를 바꿔 다시 받는 동안.
        gate = Completer<void>();
        api.listGate = gate.future;
        await tester.tap(_key('todo-scope'));
        await tester.pumpAndSettle();
        await tester.tap(_key('todo-scope-team'));
        await tester.pump();
        expect(find.textContaining('개의 할 일'), findsNothing);
        expect(_key('panel-count-pending'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        gate.complete();
        await tester.pumpAndSettle();
        expect(find.text('2개의 할 일'), findsOneWidget);

        // 완료된 할 일 제외를 켜도.
        gate = Completer<void>();
        api.listGate = gate.future;
        await tester.tap(_key('todo-exclude-done'));
        await tester.pump();
        expect(find.textContaining('개의 할 일'), findsNothing);
        gate.complete();
        await tester.pumpAndSettle();
        expect(find.text('2개의 할 일'), findsOneWidget);

        // 다른 사람이 바꿔(소켓 알림) 조용히 다시 받는 동안은 받아 둔 개수 그대로.
        gate = Completer<void>();
        api.listGate = gate.future;
        changed.add({'teamId': 't1', 'todoId': 'a', 'kind': 'updated'});
        await tester.pump();
        expect(api.calls.last, startsWith('list team'));
        expect(find.text('2개의 할 일'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        gate.complete();
        await tester.pumpAndSettle();
        expect(find.text('2개의 할 일'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );

    testWidgets('처음 받기가 실패하면 개수 줄 없이 문구와 다시 시도 — 다시 받으면 그때 개수', (tester) async {
      final api = _FailingListApi(
        todos: [
          todoJson(id: 'a', title: '하나', assignees: ['me']),
        ],
      );
      await _pump(tester, const [], api: api);
      expect(find.text('서버 오류'), findsOneWidget);
      expect(find.text('다시 시도'), findsOneWidget);
      expect(_key('panel-loaded-count'), findsNothing);
      expect(find.textContaining('개의 할 일'), findsNothing);
      expect(_key('panel-count-pending'), findsOneWidget);
      api.fail = false;
      await tester.tap(find.text('다시 시도'));
      await tester.pumpAndSettle();
      expect(find.text('1개의 할 일'), findsOneWidget);
      expect(find.text('하나'), findsOneWidget);
      expect(find.text('다시 시도'), findsNothing);
    });
  });

  // ────────────────────────── 할 일 생성 — 기본 대화방 ──────────────────────────
  group('할 일 생성 — 대화방 기본값(잔디: 나와의 대화, 담당자 나)', () {
    testWidgets(
      '모바일 — 늘 나와의 대화(담당자 나)로 채워지고, 그대로 저장하면 나와의 대화에 나를 담당자로 — 다른 방으로 바꿔도 묻지 않는다',
      (tester) async {
        // 만든 할 일이 들어갈 수 있게 늘어나는 목록으로.
        final api = await _pump(
          tester,
          <Map<String, dynamic>>[],
          session: _session(withSelf: true),
          size: const Size(390, 844),
        );
        await tester.tap(_key('todo-create'));
        await tester.pumpAndSettle();
        final editor = tester.widget<TodoEditor>(find.byType(TodoEditor));
        expect(editor.mode, TodoViewMode.page);
        expect(editor.room?.id, 'self');
        expect(editor.lockRoom, isFalse, reason: '다른 방으로 바꿀 수 있다');
        expect(
          find.descendant(
            of: _key('todo-room-field'),
            matching: find.text('나와의 대화'),
          ),
          findsOneWidget,
        );
        expect(_key('todo-assignee-chip-me'), findsOneWidget);
        expect(find.text('대화방을 먼저 선택하세요.'), findsNothing);
        expect(
          tester.widget<TextButton>(_key('todo-assignee-add')).onPressed,
          isNotNull,
          reason: '담당자 관리도 바로 된다',
        );

        // 아직 아무것도 안 넣었으면 다른 방으로 바꿔도 묻지 않는다(담당자는 새 방의 나).
        await tester.tap(_key('todo-room-field'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('토픽'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('영업 토픽').last);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          find.descendant(
            of: _key('todo-room-field'),
            matching: find.text('영업 토픽'),
          ),
          findsOneWidget,
        );
        expect(_key('todo-assignee-chip-me'), findsOneWidget);

        // 다시 나와의 대화로 — 그대로 저장한다.
        await tester.tap(_key('todo-room-field'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('채팅'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('나와의 대화').last);
        await tester.pumpAndSettle();
        await tester.enterText(_key('todo-title-field'), '내 메모');
        await tester.pump();
        await tester.tap(_key('todo-submit'));
        await tester.pumpAndSettle();
        expect(api.lastCreateRoomId, 'self');
        expect(api.lastCreate!['assigneeIds'], ['me']);
        expect(find.byType(TodoEditor), findsNothing);
        await tester.pump(const Duration(seconds: 3));
      },
    );

    testWidgets('PC — 지금 연 방이 보드 뷰 토픽이거나 연 방이 없으면 나와의 대화, 챗 뷰 토픽이면 그 방', (
      tester,
    ) async {
      final session = _session(
        withSelf: true,
        extraRooms: [_room('b1', '보드 토픽', viewMode: 'board')],
      );
      Future<String?> createRoom(String? currentRoomId) async {
        await tester.pumpWidget(const SizedBox());
        await _pumpShell(
          tester,
          const [],
          session: session,
          currentRoomId: currentRoomId,
        );
        await tester.tap(_key('todo-create'));
        await tester.pumpAndSettle();
        final editor = tester.widget<TodoEditor>(find.byType(TodoEditor));
        expect(editor.mode, TodoViewMode.dialog);
        final id = editor.room?.id;
        if (id == 'self') {
          expect(_key('todo-assignee-chip-me'), findsOneWidget);
          expect(
            find.descendant(
              of: _key('todo-room-field'),
              matching: find.text('나와의 대화'),
            ),
            findsOneWidget,
          );
        }
        await tester.tap(_key('todo-editor-close'));
        await tester.pumpAndSettle();
        return id;
      }

      expect(await createRoom('b1'), 'self', reason: '보드 뷰 토픽에는 만들 수 없다');
      expect(await createRoom(null), 'self', reason: '연 방이 없다');
      expect(await createRoom('r2'), 'r2', reason: '지금 연 챗 뷰 토픽');
    });

    testWidgets('나와의 대화를 아직 못 받았으면(목록에 없음) 예전처럼 대화방 칸이 비어 있다', (tester) async {
      await _pump(tester, const [], size: const Size(390, 844));
      await tester.tap(_key('todo-create'));
      await tester.pumpAndSettle();
      expect(tester.widget<TodoEditor>(find.byType(TodoEditor)).room, isNull);
      expect(find.text('대화방 선택'), findsOneWidget);
      expect(find.text('대화방을 먼저 선택하세요.'), findsOneWidget);
    });
  });

  // ────────────────────────── 필터 — 멤버 후보·대화방 첫 줄 ──────────────────────────
  group('필터 — 멤버 후보는 이 팀만, 대화방 목록 첫 줄은 참여한 대화방', () {
    testWidgets('부여한 할 일 – 모든 멤버의 후보에 다른 팀 방에만 있는 사람은 없다(다른 패널의 후보 계산은 그대로)', (
      tester,
    ) async {
      final session = _session(
        extraRooms: [
          _room(
            'x1',
            '다른팀 토픽',
            teamId: 't2',
            members: [_user('me', '나'), _user('u9', '다른팀사람')],
          ),
        ],
      );
      session.teams.add(Team(id: 't2', name: '개발팀', createdAt: DateTime(2026)));
      final api = FakeTodoApi(me: 'me');
      final controller = TodoController(
        api: api,
        teamId: 't1',
        scope: TodoScope.assignedByMe,
      );
      await _pump(
        tester,
        const [],
        api: api,
        controller: controller,
        session: session,
      );
      await tester.tap(_key('todo-assignee-filter'));
      await tester.pumpAndSettle();
      final shell = find.byType(FilterPanelShell);
      expect(
        find.descendant(of: shell, matching: find.text('다른팀사람')),
        findsNothing,
      );
      for (final name in ['김철수', '이영희']) {
        expect(
          find.descendant(of: shell, matching: find.text(name)),
          findsOneWidget,
          reason: name,
        );
      }
      // 팀을 주지 않는 쪽(파일·링크·즐겨찾기 …)은 예전처럼 모든 방의 멤버.
      List<String> ids(String? roomId, {String? teamId}) => [
        for (final u in memberChoicesFor(session, roomId, teamId: teamId)) u.id,
      ]..sort();
      expect(ids(null), ['me', 'u2', 'u3', 'u9']);
      expect(ids(null, teamId: 't1'), ['me', 'u2', 'u3']);
      expect(ids('x1'), ['me', 'u9']);
      expect(ids('x1', teamId: 't1'), [
        'me',
        'u2',
        'u3',
      ], reason: '다른 팀 방은 고른 셈 치지 않는다');
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    testWidgets('대화방 펼침 목록의 첫 줄도 단추와 같은 "참여한 대화방"(체크) — 방을 골랐다가 그 줄로 돌아온다', (
      tester,
    ) async {
      final api = await _pump(tester, const []);
      final shell = find.byType(FilterPanelShell);
      final all = _key('room-filter-all');
      await tester.tap(find.byType(RoomFilterButton));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: all, matching: find.text('참여한 대화방')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: all, matching: find.byIcon(Icons.check)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: shell, matching: find.text('전체')),
        findsNothing,
      );
      await tester.tap(
        find.descendant(of: shell, matching: find.text('영업 토픽')),
      );
      await tester.pumpAndSettle();
      expect(api.lastList!['roomId'], 'r1');
      expect(
        find.descendant(
          of: find.byType(RoomFilterButton),
          matching: find.text('영업 토픽'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byType(RoomFilterButton));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: all, matching: find.byIcon(Icons.check)),
        findsNothing,
      );
      await tester.tap(all);
      await tester.pumpAndSettle();
      expect(api.lastList!['roomId'], isNull);
      expect(api.calls.last, contains('room=null'));
      expect(
        find.descendant(
          of: find.byType(RoomFilterButton),
          matching: find.text('참여한 대화방'),
        ),
        findsOneWidget,
      );
    });
  });

  // ────────────────────────── PC — 패널 안 메뉴는 창 전체 위에 ──────────────────────────
  group('PC — 패널 안 화면의 메뉴·펼침 목록은 창 전체 위에(자리는 패널 안)', () {
    testWidgets(
      '열 가지(정렬·보기·대화방·멤버·상세 •••·진척률·수정 화면의 알림·기간 판·판 안의 시작/종료 시간 목록) 모두 패널 안에 뜨고, '
      '패널 밖 채팅 쪽을 누르면 닫히며 그 누름은 채팅에 가지 않는다 — 생성 대화상자의 대화방 칸·알림은 대화상자 안',
      (tester) async {
        final api = FakeTodoApi(
          me: 'me',
          todos: [
            todoJson(
              id: 'a',
              title: '같이 하는 일',
              assignees: ['me', 'u2'],
              assigneeProgress: {'me': 50, 'u2': 0},
              startDate: '2099-10-01',
              dueDate: '2099-10-07',
              dueTime: '18:00',
            ),
          ],
        );
        final controller = TodoController(
          api: api,
          teamId: 't1',
          scope: TodoScope.assignedByMe,
        );
        await _pumpShell(tester, const [], api: api, controller: controller);
        // 채팅 자리는 누르면 센다(시험 하네스가 맞는지).
        await tester.tapAt(_chatPoint);
        await tester.pump();
        expect(_chatTaps, 1);
        _chatTaps = 0;

        Future<void> tap(Finder f) async {
          await tester.ensureVisible(f);
          await tester.pumpAndSettle();
          await tester.tap(f);
          await tester.pumpAndSettle();
        }

        /// 팝업 메뉴는 루트 Navigator의 할 일 메뉴 라우트다.
        void expectRootPopup(Finder item, String what) {
          final element = tester.element(item);
          expect(
            ModalRoute.of(element)?.settings.name,
            todoPopupRouteName,
            reason: what,
          );
          expect(
            Navigator.of(element),
            same(Navigator.of(element, rootNavigator: true)),
            reason: '$what — 루트 Navigator',
          );
        }

        // 목록 화면 — 정렬(줄 오른쪽 끝의 단추 — 단추 오른쪽 끝부터 왼쪽으로). 정렬은 메시지 예약 패널과 같은
        // MenuAnchor 메뉴라 라우트가 아니라 패널 안 Navigator의 Overlay에 뜬다(바깥 누름은 TapRegion이 받는다).
        await _expectClosesFromChat(
          tester,
          what: '정렬',
          open: () async {
            await tap(_key('todo-sort'));
            expect(
              ModalRoute.of(
                tester.element(_key('todo-sort-due')),
              )?.settings.name,
              isNot(todoPopupRouteName),
              reason: '정렬 — 팝업 라우트가 아니다',
            );
            expect(
              _menuRect(tester, _key('todo-sort-due')).right,
              moreOrLessEquals(
                tester.getRect(_key('todo-sort')).right,
                epsilon: 1,
              ),
            );
          },
          shown: _key('todo-sort-due'),
          rect: () => _menuRect(tester, _key('todo-sort-due')),
        );
        // 보기·대화방·멤버 펼침 패널.
        for (final (what, button) in [
          ('보기', _key('todo-scope')),
          ('대화방', find.byType(RoomFilterButton)),
          ('멤버', _key('todo-assignee-filter')),
        ]) {
          await _expectClosesFromChat(
            tester,
            what: what,
            open: () => tap(button),
            shown: find.byType(FilterPanelShell),
            rect: () => tester.getRect(find.byType(FilterPanelShell)),
          );
        }
        expect(api.callCount('list'), 1, reason: '바깥을 눌러 닫기만 했다');
        expect(controller.sort, TodoSort.created);

        // 패널 안 상세 — ••• 와 내 진척률.
        await tap(find.text('같이 하는 일'));
        expect(find.byType(TodoDetail), findsOneWidget);
        await _expectClosesFromChat(
          tester,
          what: '상세 •••',
          open: () async {
            await tap(_key('todo-detail-menu'));
            expectRootPopup(_key('todo-menu-edit'), '상세 •••');
          },
          shown: _key('todo-menu-edit'),
          rect: () => _menuRect(tester, _key('todo-menu-edit')),
        );
        await _expectClosesFromChat(
          tester,
          what: '내 진척률',
          open: () async {
            await tap(_key('todo-detail-my-progress'));
            expectRootPopup(_key('todo-progress-option-100'), '내 진척률');
          },
          shown: _key('todo-progress-option-100'),
          rect: () => _menuRect(tester, _key('todo-progress-option-100')),
        );
        expect(api.callCount('update'), 0);
        expect(find.byType(TodoDetail), findsOneWidget, reason: '상세는 그대로');

        // 패널 안 수정 화면(상세 ••• → 할 일 수정) — 알림 메뉴와 기간 달력 아래의 시간 메뉴.
        await tap(_key('todo-detail-menu'));
        await tap(_key('todo-menu-edit'));
        expect(
          tester.widget<TodoEditor>(find.byType(TodoEditor)).mode,
          TodoViewMode.panel,
        );
        await _expectClosesFromChat(
          tester,
          what: '알림',
          open: () async {
            await tap(_key('todo-reminder-add'));
            expectRootPopup(_key('todo-reminder-option-day'), '알림');
          },
          shown: _key('todo-reminder-option-day'),
          rect: () => _menuRect(tester, _key('todo-reminder-option-day')),
        );
        // 기간 판(달력 + 시작/종료 시간)과 판 안의 시간 목록 — 루트 Overlay(자리는 패널 안).
        await _expectClosesFromChat(
          tester,
          what: '기간 판',
          open: () => tap(_key('todo-period-field')),
          shown: _key('todo-period-popup'),
          rect: () => tester.getRect(_key('todo-period-popup')),
        );
        for (final (what, box, option) in [
          ('시작 시간', 'todo-time-start', 'todo-time-option-none'),
          ('종료 시간', 'todo-time-end', 'todo-time-option-1080'),
        ]) {
          await _expectClosesFromChat(
            tester,
            what: what,
            open: () async {
              await tap(_key('todo-period-field'));
              await tap(_key(box));
              expect(_key(option), findsOneWidget, reason: what);
            },
            shown: _key('todo-time-list'),
            rect: () => tester.getRect(_key('todo-time-list')),
          );
          expect(_key('todo-period-popup'), findsNothing, reason: '판째 닫힌다');
        }
        expect(find.byType(TodoEditor), findsOneWidget, reason: '수정 화면은 그대로');
        expect(find.byType(AlertDialog), findsNothing);
        expect(api.callCount('update'), 0);
        // 바뀐 게 없으니 묻지 않고 상세로, 상세에서 목록으로.
        await tap(_key('todo-page-back'));
        expect(find.byType(TodoEditor), findsNothing);
        await tap(_key('todo-page-back'));

        // 할 일 생성은 창 가운데 대화상자 — 대화방 칸·알림 메뉴도 대화상자 안에 뜨고, 바깥(채팅 쪽)을 누르면 닫히며 그 누름은
        // 채팅에 가지 않는다(대화상자는 그대로).
        await tap(_key('todo-create'));
        expect(
          tester.widget<TodoEditor>(find.byType(TodoEditor)).mode,
          TodoViewMode.dialog,
        );
        final dialog = find.byType(Dialog);
        for (final (what, open, shown) in [
          ('대화방 칸', _key('todo-room-field'), _roomPickerDropdown),
          ('알림', _key('todo-reminder-add'), _key('todo-reminder-option-day')),
        ]) {
          await tap(open);
          expect(shown, findsWidgets, reason: '$what — 떴다');
          final rect = shown == _roomPickerDropdown
              ? tester.getRect(shown)
              : _menuRect(tester, shown);
          final box = tester.getRect(dialog);
          expect(
            rect.left,
            greaterThanOrEqualTo(box.left - 0.01),
            reason: what,
          );
          expect(rect.right, lessThanOrEqualTo(box.right + 0.01), reason: what);
          await tester.tapAt(_chatPoint);
          await tester.pumpAndSettle();
          expect(shown, findsNothing, reason: '$what — 바깥을 누르면 닫힌다');
          expect(_chatTaps, 0, reason: '$what — 그 누름은 채팅에 가지 않는다');
          expect(dialog, findsOneWidget, reason: '$what — 대화상자는 그대로');
        }
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );

    testWidgets('팀을 바꾸면 창 전체에 떠 있던 메뉴(정렬·상세 •••)도 함께 닫힌다', (tester) async {
      final session = _session();
      final dev = Team(id: 't2', name: '개발팀', createdAt: DateTime(2026));
      final sales = session.teams.single;
      session.teams.add(dev);
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(id: 'a', title: '영업팀 할 일', assignees: ['me']),
        ],
      );
      await _pumpShell(tester, const [], api: api, session: session);
      await tester.tap(_key('todo-sort'));
      await tester.pumpAndSettle();
      expect(_key('todo-sort-due'), findsOneWidget);
      session.enterTeam(dev);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_key('todo-sort-due'), findsNothing, reason: '남은 메뉴가 없다');
      expect(api.lastList!['teamId'], 't2');
      expect(api.lastList!['sort'], TodoSort.created);
      // 새 팀 목록의 정렬 단추는 그대로 쓴다.
      await tester.tap(_key('todo-sort'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-sort-due'));
      await tester.pumpAndSettle();
      expect(api.lastList!['sort'], TodoSort.due);

      // 상세의 ••• 메뉴를 띄운 채 바꿔도 메뉴와 상세가 닫힌다.
      session.enterTeam(sales);
      await tester.pumpAndSettle();
      await tester.tap(find.text('영업팀 할 일'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-detail-menu'));
      await tester.pumpAndSettle();
      expect(_key('todo-menu-edit'), findsOneWidget);
      session.enterTeam(dev);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_key('todo-menu-edit'), findsNothing);
      expect(find.byType(TodoDetail), findsNothing);
      expect(api.callCount('setFavorite'), 0);
      expect(_key('todo-create'), findsOneWidget, reason: '새 팀의 목록');
    });
  });

  // ────────────────────────── PC — 패널을 밖에서 닫기 전에 묻기 ──────────────────────────
  group('PC — 홈 화면이 패널을 닫거나 바꾸기 전에 쓰던 할 일을 묻는다', () {
    testWidgets(
      '패널은 홈 화면에 "닫기 전에 물어보기"를 맡긴다 — 패널 안에 쓰던 수정 화면이 있을 때만 물을 게 있고(생성 대화상자는 패널 밖), 묻는 것은 그 화면의 작성 취소',
      (tester) async {
        PanelLeaveGuard? guard;
        Object? owner;
        await _pumpShell(
          tester,
          [
            todoJson(id: 'a', title: '고칠 할 일', assignees: ['me']),
          ],
          setPanelLeaveGuard: (o, g) {
            if (g != null) {
              owner = o;
              guard = g;
            } else if (identical(o, owner)) {
              owner = null;
              guard = null;
            }
          },
        );
        expect(guard, isNotNull, reason: '패널이 열리면 맡긴다');
        expect(guard!.needsConfirm(), isFalse, reason: '쓰는 중인 할 일이 없다');
        expect(await guard!.confirm(), isTrue);

        // 생성은 패널 밖 대화상자(투표 만들기처럼)라 패널이 물을 게 아니다 — 써도 패널의 "쓰는 중인 할 일"이 아니다.
        await tester.tap(_key('todo-create'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);
        await tester.enterText(_key('todo-title-field'), '대화상자에 쓴 제목');
        await tester.pump();
        expect(guard!.needsConfirm(), isFalse);
        await tester.tap(_key('todo-editor-close'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, '닫기'));
        await tester.pumpAndSettle();
        expect(find.byType(TodoEditor), findsNothing);

        // 패널 안 수정 화면(상세 ••• → 할 일 수정) — 그대로면 묻지 않고, 쓰기 시작하면 묻는다.
        await tester.tap(find.text('고칠 할 일'));
        await tester.pumpAndSettle();
        await tester.tap(_key('todo-detail-menu'));
        await tester.pumpAndSettle();
        await tester.tap(_key('todo-menu-edit'));
        await tester.pumpAndSettle();
        expect(guard!.needsConfirm(), isFalse);
        await tester.enterText(_key('todo-title-field'), '고친 제목');
        await tester.pump();
        expect(guard!.needsConfirm(), isTrue);
        final keep = guard!.confirm();
        await tester.pumpAndSettle();
        expect(find.text('작성 취소'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, '계속 수정'));
        await tester.pumpAndSettle();
        expect(await keep, isFalse);
        expect(find.byType(TodoEditor), findsOneWidget);
        expect(find.text('고친 제목'), findsOneWidget);
        final leave = guard!.confirm();
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, '닫기'));
        await tester.pumpAndSettle();
        expect(await leave, isTrue, reason: '닫는 것은 홈 화면이 한다');
        expect(find.byType(TodoEditor), findsOneWidget);
        // ←로 닫으면(이 화면이 묻는다) 쓰는 중인 할 일이 없어진다(상세로 돌아간다).
        await tester.tap(_key('todo-page-back'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, '닫기'));
        await tester.pumpAndSettle();
        expect(find.byType(TodoEditor), findsNothing);
        expect(find.byType(TodoDetail), findsOneWidget);
        expect(guard!.needsConfirm(), isFalse);

        // 다시 수정 화면을 열어 쓰던 채로 — 패널이 사라지면 거둔다.
        await tester.tap(_key('todo-detail-menu'));
        await tester.pumpAndSettle();
        await tester.tap(_key('todo-menu-edit'));
        await tester.pumpAndSettle();
        await tester.enterText(_key('todo-title-field'), '또 고친 제목');
        await tester.pump();
        expect(guard!.needsConfirm(), isTrue);
        await tester.pumpWidget(const SizedBox());
        expect(guard, isNull);
      },
    );
  });

  // ────────────────────────── 알림 토스트 ──────────────────────────
  group('알림 토스트 — 패널 안 화면에서 띄워도 창 가운데 아래', () {
    testWidgets(
      '패널 안 상세의 공용 위젯(첨부 파일 줄)이 띄운 토스트도 패널이 아니라 창 맨 위 Overlay의 가운데 아래에',
      (tester) async {
        await _pumpShell(tester, [
          todoJson(
            id: 'a',
            title: '파일 있는 할 일',
            assignees: ['me'],
            attachmentCount: 1,
          ),
        ]);
        await tester.tap(find.text('파일 있는 할 일'));
        await tester.pumpAndSettle();
        final file = find.byType(DownloadableFile);
        expect(file, findsOneWidget);
        // 첨부 줄의 받기·열기 결과 알림과 같은 길 — 그 위젯의 context로 showAppToast.
        showAppToast(tester.element(file), '파일을 받지 못했습니다');
        await tester.pump();
        final toast = find.text('파일을 받지 못했습니다');
        expect(toast, findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(
          find.descendant(of: _key('panel-box'), matching: toast),
          findsNothing,
          reason: '패널의 중첩 Overlay가 아니다',
        );
        expect(tester.getCenter(toast).dx, closeTo(640, 1));
        expect(tester.getSize(toast).width, greaterThan(150));
        expect(tester.getBottomLeft(toast).dy, greaterThan(800));
        await tester.pump(const Duration(seconds: 3));
        expect(toast, findsNothing);
      },
    );
  });
}
