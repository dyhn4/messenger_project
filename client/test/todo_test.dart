import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client/models/app_user.dart';
import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/models/todo.dart';
import 'package:client/models/uploaded_attachment.dart';
import 'package:client/screens/todo_detail_dialog.dart';
import 'package:client/screens/todo_editor_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/services/todo_controller.dart';
import 'package:client/widgets/date_range_calendar_panel.dart';
import 'package:client/widgets/menu_entries.dart';
import 'package:client/widgets/message_actions.dart';
import 'package:client/widgets/side_panels.dart';
import 'package:client/widgets/todo_from_message.dart';
import 'package:client/widgets/todos_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers/fake_todo_api.dart';

/// 할 일(To-Do) — 모델·입력 검사, 컨트롤러(탭·필터·무한 스크롤·소켓 갱신), 패널(카드·완료 체크·상세), 생성/수정 창(제목
/// 필수·담당자는 방 멤버만·첨부 30개·알림), 상세(권한별 ⋯·진척률·삭제), 메시지·댓글에서 만들기(미리 채움), 메뉴·패널 등록.
/// 서버는 가짜 API(helpers/fake_todo_api.dart)로 대신한다.

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

Room _topic(
  String id, {
  String name = '영업 토픽',
  bool readOnly = false,
  bool secret = false,
}) => Room.fromJson({
  'id': id,
  'teamId': 't1',
  'type': secret ? 'dm' : 'topic',
  'name': secret ? null : name,
  'members': _members,
  'createdAt': 1000,
  'readOnly': readOnly,
  'isSecret': secret,
});

Session _session({List<Room>? rooms, http.Client? client}) {
  final session = Session(
    notifications: _QuietNotifications(),
    settings: AppSettings(),
  );
  session.serverUrl = 'https://test.local';
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient:
        client ??
        MockClient((request) async {
          return http.Response.bytes(
            utf8.encode(jsonEncode({'items': <Object>[], 'hasMore': false})),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
  );
  session.userId = 'me';
  session.name = '나';
  session.accountRole = AccountRole.member;
  final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  session.rooms.addAll(rooms ?? [_topic('r1'), _topic('r2', name: '개발 토픽')]);
  return session;
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pumpPanel(
  WidgetTester tester,
  Session session,
  FakeTodoApi api, {
  Size size = const Size(420, 900),
  TodoController? controller,
}) async {
  _size(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TodosPanel(session: session, api: api, controller: controller),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 버튼 하나로 [open]을 여는 화면 — 대화상자/전체 화면 창을 시험할 때.
Future<void> _pumpOpener(
  WidgetTester tester,
  Future<void> Function(BuildContext context) open, {
  Size size = const Size(900, 900),
}) async {
  _size(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const ValueKey('opener'),
              onPressed: () => open(context),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('opener')));
  await tester.pumpAndSettle();
}

Finder _key(String k) => find.byKey(ValueKey(k));

String _ymd(DateTime d) => todoDateWire(d);

/// 기한 달력(폼 안에 펼쳐진 것)의 [day]일을 누른다 — 화면 밖이면 스크롤해서.
Future<void> _tapDay(WidgetTester tester, String day) async {
  final finder = find.descendant(
    of: find.byType(DateRangeCalendarPanel),
    matching: find.text(day),
  );
  await tester.ensureVisible(finder.last);
  await tester.pumpAndSettle();
  await tester.tap(finder.last);
  await tester.pumpAndSettle();
}

void main() {
  // ────────────────────────── 모델 ──────────────────────────
  group('Todo 모델', () {
    test('fromJson — 상태·기한·담당자·권한', () {
      final t = Todo.fromJson(
        todoJson(
          progress: 40,
          startDate: '2026-10-01',
          dueDate: '2026-10-05',
          assignees: ['u2', 'u3'],
          attachmentCount: 2,
          creatorId: 'u2',
          creatorName: '김철수',
          reminders: [
            {'id': 'r1', 'remindAt': 123456, 'sent': true},
          ],
        ),
      );
      expect(t.status, TodoStatus.doing);
      expect(t.statusText, '진행 40%');
      expect(t.periodText, '2026/10/01 ~ 2026/10/05');
      expect(t.assignees.map((a) => a.id), ['u2', 'u3']);
      expect(t.attachments, hasLength(2));
      expect(t.reminders.single.sent, isTrue);
      expect(t.creator?.name, '김철수');
      // 내가 만들지도 담당하지도 않은 할 일 — 읽기 전용.
      expect(t.myRole, 'viewer');
      expect(t.canEdit, isFalse);
      expect(t.canManage, isFalse);
    });

    test('상태는 진척률로 가른다(0 대기, 1~99 진행, 100 완료)', () {
      expect(TodoStatus.of(0), TodoStatus.todo);
      expect(TodoStatus.of(1), TodoStatus.doing);
      expect(TodoStatus.of(99), TodoStatus.doing);
      expect(TodoStatus.of(100), TodoStatus.done);
      expect(Todo.fromJson(todoJson(progress: 0)).statusText, '대기');
      expect(Todo.fromJson(todoJson(progress: 100)).statusText, '완료');
    });

    test('기한 문구는 종료일만이면 "~ yyyy/MM/dd", 기한이 없으면 null', () {
      expect(
        Todo.fromJson(todoJson(dueDate: '2026-10-05')).periodText,
        '~ 2026/10/05',
      );
      expect(Todo.fromJson(todoJson()).periodText, isNull);
    });

    test('지난 기한은 완료되지 않았을 때만 지연', () {
      final now = DateTime(2026, 10, 3, 12);
      expect(
        Todo.fromJson(todoJson(dueDate: '2026-10-02')).isOverdue(now),
        isTrue,
      );
      expect(
        Todo.fromJson(todoJson(dueDate: '2026-10-03')).isOverdue(now),
        isFalse,
        reason: '기한 당일은 아직 지연이 아니다',
      );
      expect(
        Todo.fromJson(
          todoJson(dueDate: '2026-10-02', progress: 100),
        ).isOverdue(now),
        isFalse,
      );
      expect(Todo.fromJson(todoJson()).isOverdue(now), isFalse);
    });

    test('날짜 표기·변환', () {
      expect(formatTodoDate(DateTime(2026, 3, 7)), '2026/03/07');
      expect(todoDateWire(DateTime(2026, 3, 7)), '2026-03-07');
      expect(parseTodoDate('2026-03-07'), DateTime(2026, 3, 7));
      expect(parseTodoDate('2026/03/07'), isNull);
      expect(parseTodoDate(null), isNull);
      expect(
        formatTodoDateTime(DateTime(2026, 3, 7, 13, 5)),
        '2026/03/07 오후 1:05',
      );
      expect(
        formatTodoDateTime(DateTime(2026, 3, 7, 0, 0)),
        '2026/03/07 오전 12:00',
      );
    });

    test('입력 검사 — 제목 필수·길이, 기한 순서, 개수 한도', () {
      expect(checkTodoDraft(title: '  ').titleError, isNotNull);
      expect(checkTodoDraft(title: '할 일').ok, isTrue);
      expect(
        checkTodoDraft(title: 'a' * (todoTitleMaxLength + 1)).titleError,
        isNotNull,
      );
      expect(
        checkTodoDraft(title: 'a' * todoTitleMaxLength).titleError,
        isNull,
      );
      expect(
        checkTodoDraft(
          title: 't',
          description: 'x' * (todoDescriptionMaxLength + 1),
        ).descriptionError,
        isNotNull,
      );
      expect(
        checkTodoDraft(
          title: 't',
          start: DateTime(2026, 10, 5),
          due: DateTime(2026, 10, 1),
        ).periodError,
        isNotNull,
      );
      expect(
        checkTodoDraft(
          title: 't',
          start: DateTime(2026, 10, 1),
          due: DateTime(2026, 10, 1),
        ).periodError,
        isNull,
        reason: '같은 날은 허용',
      );
      expect(
        checkTodoDraft(title: 't', attachmentCount: 31).attachmentsError,
        isNotNull,
      );
      expect(
        checkTodoDraft(title: 't', attachmentCount: 30).attachmentsError,
        isNull,
      );
      expect(
        checkTodoDraft(title: 't', assigneeCount: 31).assigneesError,
        isNotNull,
      );
      expect(
        checkTodoDraft(title: 't', reminderCount: 6).remindersError,
        isNotNull,
      );
    });

    test('메시지 본문 → 제목은 첫 줄 최대 100자', () {
      expect(todoTitleFromText('첫 줄\n둘째 줄'), '첫 줄');
      expect(todoTitleFromText('\n\n  공백 뒤  \n다음'), '공백 뒤');
      expect(todoTitleFromText(null), '');
      expect(todoTitleFromText('가' * 150), '가' * 100);
    });

    test('기한 기준 알림 — 기한일 오후 6시 기준', () {
      final due = DateTime(2026, 10, 5);
      expect(
        todoReminderBeforeDue(due, const Duration(days: 1)),
        DateTime(2026, 10, 4, 18),
      );
      expect(
        todoReminderBeforeDue(due, const Duration(hours: 1)),
        DateTime(2026, 10, 5, 17),
      );
    });

    test('소켓 토스트 문구 — 담당 지정은 내가 대상일 때만, 알림은 제목 포함', () {
      expect(
        todoAssignedToast({
          'addedAssigneeIds': ['me'],
          'actorId': 'u2',
          'title': '견적서',
        }, myUserId: 'me'),
        '할 일이 지정되었습니다: 견적서',
      );
      expect(
        todoAssignedToast({
          'addedAssigneeIds': ['me'],
          'actorId': 'me',
        }, myUserId: 'me'),
        isNull,
        reason: '내가 한 일은 알리지 않는다',
      );
      expect(
        todoAssignedToast({
          'addedAssigneeIds': ['u3'],
          'actorId': 'u2',
        }, myUserId: 'me'),
        isNull,
      );
      expect(todoReminderToast({'title': '견적서'}), '할 일 알림: 견적서');
      expect(todoReminderToast({}), '할 일 알림');
    });
  });

  // ────────────────────────── 컨트롤러 ──────────────────────────
  group('TodoController', () {
    FakeTodoApi seeded() => FakeTodoApi(
      me: 'me',
      todos: [
        todoJson(
          id: 'a',
          title: '내 할 일 A',
          assignees: ['me'],
          dueDate: '2026-10-09',
          createdAt: 1,
        ),
        todoJson(
          id: 'b',
          title: '내 할 일 B 완료',
          assignees: ['me'],
          progress: 100,
          dueDate: '2026-10-01',
          createdAt: 2,
        ),
        todoJson(
          id: 'c',
          title: '내가 만든 C',
          assignees: ['u2'],
          roomId: 'r2',
          roomName: '개발 토픽',
          createdAt: 3,
        ),
        todoJson(
          id: 'd',
          title: '남이 만든 D',
          creatorId: 'u2',
          assignees: ['u3'],
          createdAt: 4,
        ),
      ],
    );

    test('탭마다 scope가 다르다 — 나의 / 부여한 / 팀', () async {
      final api = seeded();
      final c = TodoController(api: api, teamId: 't1');
      await c.load();
      expect(c.items.map((t) => t.id), ['a', 'b']);
      c.setScope(TodoScope.assignedByMe);
      await pumpEventQueue();
      expect(c.items.map((t) => t.id), unorderedEquals(['a', 'b', 'c']));
      c.setScope(TodoScope.team);
      await pumpEventQueue();
      expect(c.items.length, 4);
      c.dispose();
    });

    test('정렬 — 미완료 먼저, 기한 임박순(기한 없음은 뒤)', () async {
      final api = seeded();
      final c = TodoController(api: api, teamId: 't1', scope: TodoScope.team);
      await c.load();
      // 미완료: a(10/09), c(없음, 최신), d(없음) → a, d(4), c(3) 순, 완료 b는 맨 끝.
      expect(c.items.map((t) => t.id), ['a', 'd', 'c', 'b']);
      c.setSort(TodoSort.created);
      await pumpEventQueue();
      expect(c.items.map((t) => t.id), ['d', 'c', 'b', 'a']);
      c.dispose();
    });

    test('완료 제외·대화방 필터', () async {
      final api = seeded();
      final c = TodoController(api: api, teamId: 't1', scope: TodoScope.team);
      await c.load();
      c.setExcludeDone(true);
      await pumpEventQueue();
      expect(c.items.map((t) => t.id), isNot(contains('b')));
      c.setRoom('r2');
      await pumpEventQueue();
      expect(c.items.map((t) => t.id), ['c']);
      expect(api.calls.last, contains('room=r2'));
      expect(api.calls.last, contains('done=false'));
      c.dispose();
    });

    test('무한 스크롤 — 다음 쪽은 지금까지 받은 개수를 offset으로', () async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          for (var i = 0; i < 35; i++)
            todoJson(
              id: 'x$i',
              title: '할 일 $i',
              assignees: ['me'],
              createdAt: i,
            ),
        ],
      );
      final c = TodoController(api: api, teamId: 't1', pageSize: 30);
      await c.load();
      expect(c.items, hasLength(30));
      expect(c.hasMore, isTrue);
      await c.loadMore();
      expect(c.items, hasLength(35));
      expect(c.hasMore, isFalse);
      expect(api.calls.last, contains('offset=30'));
      await c.loadMore(); // 끝 — 더 부르지 않는다
      expect(api.callCount('list'), 2);
      expect({for (final t in c.items) t.id}, hasLength(35));
      c.dispose();
    });

    test('소켓 todo:changed — 그 팀 것만 조용히 다시 받는다', () async {
      final api = seeded();
      final changed = StreamController<Map<String, dynamic>>.broadcast();
      final c = TodoController(api: api, teamId: 't1', changed: changed.stream);
      await c.load();
      expect(api.callCount('list'), 1);
      changed.add({'teamId': 'other'});
      await pumpEventQueue();
      expect(api.callCount('list'), 1, reason: '다른 팀 알림은 무시');
      api.todos.add(
        todoJson(id: 'e', title: '새 할 일', assignees: ['me'], createdAt: 9),
      );
      changed.add({'teamId': 't1', 'todoId': 'e', 'kind': 'created'});
      await pumpEventQueue();
      expect(api.callCount('list'), 2);
      expect(c.items.map((t) => t.id), contains('e'));
      expect(c.loading, isFalse, reason: '조용한 갱신은 로딩 표시를 켜지 않는다');
      c.dispose();
      await changed.close();
    });

    test('첫 불러오기 실패는 error로, 이미 목록이 있으면 조용히 넘어간다', () async {
      final api = seeded();
      final c = TodoController(api: api, teamId: 't1');
      api.failWith = null;
      final failing = _FailingListApi();
      final c2 = TodoController(api: failing, teamId: 't1');
      await c2.load();
      expect(c2.loaded, isFalse);
      expect(c2.error, '서버 오류');
      await c.load();
      expect(c.error, isNull);
      c.dispose();
      c2.dispose();
    });

    test('setProgress — 서버 결과로 목록을 바꾼다, remove는 목록에서 뺀다', () async {
      final api = seeded();
      final c = TodoController(api: api, teamId: 't1');
      await c.load();
      final a = c.items.firstWhere((t) => t.id == 'a');
      final updated = await c.setProgress(a, 100);
      expect(updated.isDone, isTrue);
      expect(c.items.firstWhere((t) => t.id == 'a').isDone, isTrue);
      expect(api.lastUpdate, {'progress': 100});
      await c.remove(a);
      expect(c.items.any((t) => t.id == 'a'), isFalse);
      expect(api.callCount('delete'), 1);
      c.dispose();
    });
  });

  // ────────────────────────── 패널 ──────────────────────────
  group('할 일 패널', () {
    testWidgets('탭·필터·건수 줄·카드(상태 칩·기한·담당자 +N·대화방·첨부)', (tester) async {
      final session = _session();
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(
            id: 'a',
            title: '지난 기한 할 일',
            assignees: ['me', 'u2', 'u3', 'u4', 'u5'],
            dueDate: '2020-01-02',
            progress: 40,
            attachmentCount: 3,
          ),
          todoJson(
            id: 'b',
            title: '여유 있는 할 일',
            assignees: ['me'],
            dueDate: '2099-12-31',
            createdAt: 5,
          ),
        ],
      );
      await _pumpPanel(tester, session, api);
      expect(find.text('나의 할 일'), findsOneWidget);
      expect(find.text('부여한 할 일'), findsOneWidget);
      expect(find.text('팀 할 일'), findsOneWidget);
      expect(find.text('참여 대화방'), findsOneWidget);
      expect(_key('todo-exclude-done'), findsOneWidget);
      expect(find.text('"2"개가 로딩되었습니다.'), findsOneWidget);
      expect(find.text('지난 기한 할 일'), findsOneWidget);
      expect(find.text('진행 40%'), findsOneWidget);
      expect(find.text('대기'), findsOneWidget);
      // 지난 기한은 빨강, 아닌 것은 흐린 색.
      final overdue = tester.widget<Text>(_key('todo-period-a'));
      expect(overdue.data, '~ 2020/01/02');
      expect(overdue.style?.color, ThemeData().colorScheme.error);
      final fine = tester.widget<Text>(_key('todo-period-b'));
      expect(fine.data, '~ 2099/12/31');
      expect(fine.style?.color, isNot(ThemeData().colorScheme.error));
      expect(find.text('+2'), findsOneWidget); // 담당자 5명 중 3명만 그리고 +2
      expect(find.text('3'), findsOneWidget); // 첨부 클립 수
      expect(find.text('영업 토픽'), findsWidgets);
    });

    testWidgets('탭을 누르면 그 scope로 다시 받고, 건수 줄이 바뀐다', (tester) async {
      final session = _session();
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(id: 'a', title: '나에게', assignees: ['me']),
          todoJson(id: 'c', title: '내가 부여', assignees: ['u2'], createdAt: 3),
          todoJson(
            id: 'd',
            title: '남의 일',
            creatorId: 'u2',
            assignees: ['u3'],
            createdAt: 4,
          ),
        ],
      );
      await _pumpPanel(tester, session, api);
      expect(find.text('나에게'), findsOneWidget);
      expect(find.text('내가 부여'), findsNothing);
      await tester.tap(find.text('부여한 할 일'));
      await tester.pumpAndSettle();
      expect(api.calls.last, startsWith('list assigned_by_me'));
      expect(find.text('내가 부여'), findsOneWidget);
      await tester.tap(find.text('팀 할 일'));
      await tester.pumpAndSettle();
      expect(find.text('"3"개가 로딩되었습니다.'), findsOneWidget);
      expect(find.text('남의 일'), findsOneWidget);
    });

    testWidgets('완료 제외 토글과 정렬 메뉴가 서버 조회를 바꾼다', (tester) async {
      final session = _session();
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(id: 'a', title: '미완료', assignees: ['me']),
          todoJson(id: 'b', title: '끝난 일', assignees: ['me'], progress: 100),
        ],
      );
      await _pumpPanel(tester, session, api);
      expect(find.text('끝난 일'), findsOneWidget);
      await tester.tap(_key('todo-exclude-done'));
      await tester.pumpAndSettle();
      expect(api.calls.last, contains('done=false'));
      expect(find.text('끝난 일'), findsNothing);
      await tester.tap(_key('todo-sort'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-sort-created'));
      await tester.pumpAndSettle();
      expect(api.calls.last, contains('sort=created'));
    });

    testWidgets('완료 체크로 빠르게 완료/해제, 권한 없는 카드는 체크가 꺼져 있다', (tester) async {
      final session = _session();
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(id: 'a', title: '내 할 일', assignees: ['me']),
        ],
      );
      await _pumpPanel(tester, session, api);
      await tester.tap(_key('todo-check-a'));
      await tester.pumpAndSettle();
      expect(api.lastUpdate, {'progress': 100});
      expect(find.text('완료'), findsOneWidget);
      await tester.tap(_key('todo-check-a'));
      await tester.pumpAndSettle();
      expect(api.lastUpdate, {'progress': 0});

      // 팀 탭에서 남의 할 일은 체크할 수 없다.
      api.todos.add(
        todoJson(
          id: 'v',
          title: '남의 일',
          creatorId: 'u2',
          assignees: ['u3'],
          createdAt: 9,
        ),
      );
      await tester.tap(find.text('팀 할 일'));
      await tester.pumpAndSettle();
      final box = tester.widget<Checkbox>(_key('todo-check-v'));
      expect(box.onChanged, isNull);
    });

    testWidgets('목록 끝으로 스크롤하면 다음 쪽을 받는다', (tester) async {
      final session = _session();
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          for (var i = 0; i < 45; i++)
            todoJson(
              id: 'x$i',
              title: '할 일 번호 $i',
              assignees: ['me'],
              createdAt: 100 - i,
              dueDate: '2099-01-${(i % 28 + 1).toString().padLeft(2, '0')}',
            ),
        ],
      );
      await _pumpPanel(tester, session, api);
      expect(api.callCount('list'), 1);
      await tester.drag(_key('todo-list'), const Offset(0, -20000));
      await tester.pumpAndSettle();
      await tester.drag(_key('todo-list'), const Offset(0, -20000));
      await tester.pumpAndSettle();
      expect(api.callCount('list'), 2);
      expect(api.calls.last, contains('offset=30'));
      expect(find.text('"45"개가 로딩되었습니다.'), findsOneWidget);
    });

    testWidgets('비어 있으면 탭에 맞는 안내', (tester) async {
      final session = _session();
      await _pumpPanel(tester, session, FakeTodoApi(me: 'me'));
      expect(find.text('나에게 지정된 할 일이 없어요.'), findsOneWidget);
      expect(find.text('"0"개가 로딩되었습니다.'), findsOneWidget);
      await tester.tap(find.text('팀 할 일'));
      await tester.pumpAndSettle();
      expect(find.text('이 팀에 등록된 할 일이 없어요.'), findsOneWidget);
    });

    testWidgets('카드를 누르면 상세가 열린다', (tester) async {
      final session = _session();
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(
            id: 'a',
            title: '상세로 열 할 일',
            description: '자세한 설명입니다',
            assignees: ['me'],
          ),
        ],
      );
      await _pumpPanel(tester, session, api);
      await tester.tap(find.text('상세로 열 할 일'));
      await tester.pumpAndSettle();
      expect(_key('todo-detail-title'), findsOneWidget);
      expect(find.text('자세한 설명입니다'), findsOneWidget);
    });

    testWidgets('폭 360에서도 넘치지 않는다', (tester) async {
      final session = _session();
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(
            id: 'a',
            title: '아주 아주 긴 제목의 할 일이라서 두 줄로 넘어가야 하는 경우도 잘 보이는지 확인합니다 계속 계속',
            assignees: ['me', 'u2', 'u3', 'u4', 'u5'],
            dueDate: '2020-01-02',
            progress: 75,
            attachmentCount: 12,
            roomName: '아주 긴 대화방 이름이 들어가는 경우를 확인하는 토픽입니다 정말로',
          ),
        ],
      );
      await _pumpPanel(tester, session, api, size: const Size(360, 780));
      expect(tester.takeException(), isNull);
      expect(find.text('진행 75%'), findsOneWidget);
    });
  });

  // ────────────────────────── 생성/수정 창 ──────────────────────────
  group('할 일 생성 창', () {
    testWidgets('제목이 없으면 만들 수 없고, 대화방도 골라야 한다', (tester) async {
      final session = _session();
      final api = FakeTodoApi(me: 'me');
      await _pumpOpener(
        tester,
        (c) => showTodoEditor(c, session: session, api: api),
      );
      expect(find.text('할 일 생성'), findsOneWidget);
      FilledButton submit() => tester.widget<FilledButton>(_key('todo-submit'));
      expect(submit().onPressed, isNull, reason: '대화방·제목 둘 다 없다');
      await tester.enterText(_key('todo-title-field'), '제목만 있음');
      await tester.pump();
      expect(submit().onPressed, isNull, reason: '대화방이 없다');
    });

    testWidgets('방이 정해지고 제목이 있으면 만들어지고, 본문은 정리된다', (tester) async {
      final session = _session();
      final api = FakeTodoApi(me: 'me');
      Todo? saved;
      await _pumpOpener(tester, (c) async {
        saved = await showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          api: api,
        );
      });
      FilledButton submit() => tester.widget<FilledButton>(_key('todo-submit'));
      expect(submit().onPressed, isNull);
      await tester.enterText(_key('todo-title-field'), '  견적서 보내기  ');
      await tester.enterText(_key('todo-description-field'), '  내용  ');
      await tester.pump();
      expect(submit().onPressed, isNotNull);
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(api.lastCreateRoomId, 'r1');
      expect(api.lastCreate!['title'], '견적서 보내기');
      expect(api.lastCreate!['description'], '내용');
      expect(api.lastCreate!['assigneeIds'], isEmpty, reason: '담당자 기본은 없음');
      expect(saved?.title, '견적서 보내기');
      expect(_key('todo-submit'), findsNothing, reason: '저장되면 창이 닫힌다');
    });

    testWidgets('서버가 거절하면 창 안에 문구를 보이고 입력은 그대로', (tester) async {
      final session = _session();
      final api = FakeTodoApi(me: 'me')..failWith = '보관된 토픽에서는 할 일을 만들 수 없습니다.';
      await _pumpOpener(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          api: api,
        ),
      );
      await tester.enterText(_key('todo-title-field'), '거절될 할 일');
      await tester.pump();
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(find.text('보관된 토픽에서는 할 일을 만들 수 없습니다.'), findsOneWidget);
      expect(find.text('거절될 할 일'), findsOneWidget);
      expect(_key('todo-submit'), findsOneWidget);
    });

    testWidgets('담당자는 이 대화방 멤버 중에서만 고른다', (tester) async {
      final session = _session();
      final api = FakeTodoApi(me: 'me');
      await _pumpOpener(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          api: api,
        ),
      );
      await tester.tap(_key('todo-assignee-add'));
      await tester.pumpAndSettle();
      // 멤버 셋(나·김철수·이영희)만 보인다.
      expect(_key('todo-assignee-option-me'), findsOneWidget);
      expect(_key('todo-assignee-option-u2'), findsOneWidget);
      expect(_key('todo-assignee-option-u3'), findsOneWidget);
      expect(_key('todo-assignee-option-u9'), findsNothing);
      await tester.tap(_key('todo-assignee-option-u2'));
      await tester.tap(_key('todo-assignee-option-u3'));
      await tester.pump();
      await tester.tap(_key('todo-assignee-ok'));
      await tester.pumpAndSettle();
      expect(_key('todo-assignee-chip-u2'), findsOneWidget);
      expect(_key('todo-assignee-chip-u3'), findsOneWidget);
      // 칩의 x로 뺀다.
      tester.widget<InputChip>(_key('todo-assignee-chip-u3')).onDeleted!();
      await tester.pump();
      expect(_key('todo-assignee-chip-u3'), findsNothing);
      await tester.enterText(_key('todo-title-field'), '담당 있음');
      await tester.pump();
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(api.lastCreate!['assigneeIds'], ['u2']);
    });

    testWidgets('setAssignees는 방 멤버가 아닌 사람을 버린다', (tester) async {
      final session = _session();
      await _pumpOpener(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          api: FakeTodoApi(me: 'me'),
        ),
      );
      final state = tester.state<TodoEditorState>(find.byType(TodoEditor));
      state.setAssignees([
        AppUser(id: 'u2', username: 'u2', name: '김철수'),
        AppUser(id: 'outsider', username: 'o', name: '외부인'),
      ]);
      await tester.pump();
      expect(_key('todo-assignee-chip-u2'), findsOneWidget);
      expect(_key('todo-assignee-chip-outsider'), findsNothing);
    });

    testWidgets('대화방을 바꾸면 그 방에 없는 담당자는 빠진다', (tester) async {
      final other = Room.fromJson({
        'id': 'r3',
        'teamId': 't1',
        'type': 'topic',
        'name': '작은 토픽',
        'members': [_user('me', '나'), _user('u3', '이영희')],
        'createdAt': 1000,
      });
      final session = _session(rooms: [_topic('r1'), other]);
      await _pumpOpener(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          api: FakeTodoApi(me: 'me'),
        ),
      );
      final state = tester.state<TodoEditorState>(find.byType(TodoEditor));
      state.setAssignees([
        AppUser(id: 'u2', username: 'u2', name: '김철수'),
        AppUser(id: 'u3', username: 'u3', name: '이영희'),
      ]);
      await tester.pump();
      await tester.tap(find.text('영업 토픽'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('작은 토픽').last);
      await tester.pumpAndSettle();
      expect(_key('todo-assignee-chip-u3'), findsOneWidget);
      expect(_key('todo-assignee-chip-u2'), findsNothing);
      expect(find.text('이 대화방에 없는 담당자 1명을 뺐습니다.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('읽기 전용 토픽·비밀 대화는 대화방 목록에서 빠진다', (tester) async {
      final session = _session(
        rooms: [
          _topic('r1'),
          _topic('ro', name: '읽기 전용 토픽', readOnly: true),
          _topic('sec', secret: true),
        ],
      );
      expect(session.canCreateTodoIn(session.rooms[0]), isTrue);
      expect(session.canCreateTodoIn(session.rooms[1]), isFalse);
      expect(session.canCreateTodoIn(session.rooms[2]), isFalse);
    });

    testWidgets('기한은 달력에서 시작일 → 종료일 차례로 고르고 지울 수 있다', (tester) async {
      final session = _session();
      final api = FakeTodoApi(me: 'me');
      await _pumpOpener(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          api: api,
        ),
      );
      await tester.enterText(_key('todo-title-field'), '기한 있는 일');
      await tester.tap(_key('todo-period-field'));
      await tester.pumpAndSettle();
      expect(find.text('시작일을 선택하세요'), findsOneWidget);
      await _tapDay(tester, '10');
      expect(find.text('종료일을 선택하세요'), findsOneWidget);
      await _tapDay(tester, '20');
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, 10);
      final due = DateTime(now.year, now.month, 20);
      expect(find.text(formatTodoDate(start)), findsOneWidget);
      expect(find.text(formatTodoDate(due)), findsOneWidget);
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(api.lastCreate!['startDate'], _ymd(start));
      expect(api.lastCreate!['dueDate'], _ymd(due));
    });

    testWidgets('종료일을 시작일보다 앞서 누르면 그 날이 새 시작일이 된다(순서가 뒤집히지 않는다)', (
      tester,
    ) async {
      final session = _session();
      final api = FakeTodoApi(me: 'me');
      await _pumpOpener(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          api: api,
        ),
      );
      await tester.enterText(_key('todo-title-field'), '순서');
      await tester.tap(_key('todo-period-field'));
      await tester.pumpAndSettle();
      await _tapDay(tester, '20');
      await _tapDay(tester, '10');
      // 아직 종료일을 못 골랐다 — 10일이 시작일로 바뀌었다.
      expect(find.text('종료일을 선택하세요'), findsOneWidget);
      final now = DateTime.now();
      expect(
        find.text(formatTodoDate(DateTime(now.year, now.month, 10))),
        findsOneWidget,
      );
      await tester.ensureVisible(_key('todo-period-clear'));
      await tester.tap(_key('todo-period-clear'));
      await tester.pump();
      expect(find.text('시작일'), findsOneWidget);
    });

    testWidgets('첨부는 30개까지 — 넘치면 막고 알린다', (tester) async {
      final session = _session();
      final many = [
        for (var i = 0; i < 31; i++)
          UploadedAttachment(
            isImage: false,
            url: '/uploads/f$i',
            fileName: '파일$i.txt',
            size: 10,
          ),
      ];
      await _pumpOpener(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          lockRoom: true,
          initialAttachments: many,
          api: FakeTodoApi(me: 'me'),
        ),
      );
      final state = tester.state<TodoEditorState>(find.byType(TodoEditor));
      expect(state.attachmentCount, 30, reason: '31개를 줘도 30개만');
      expect(find.text('30/30'), findsOneWidget);
      state.addFiles([File('nope.txt')]);
      await tester.pump();
      expect(state.attachmentCount, 30);
      expect(find.text('첨부 파일은 30개까지 올릴 수 있습니다.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      final attach = tester.widget<OutlinedButton>(_key('todo-attach'));
      expect(attach.onPressed, isNull, reason: '가득 차면 단추가 꺼진다');
    });

    testWidgets('알림 — 기한이 없으면 안내, 기한이 있으면 하루 전·1시간 전이 추가되고 5개까지', (
      tester,
    ) async {
      final session = _session();
      final api = FakeTodoApi(me: 'me');
      await _pumpOpener(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          api: api,
        ),
      );
      await tester.ensureVisible(_key('todo-reminder-add'));
      await tester.tap(_key('todo-reminder-add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('기한 하루 전 (전날 오후 6시)'));
      await tester.pumpAndSettle();
      expect(find.text('기한을 먼저 정하세요.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(_key('todo-reminder-0'), findsNothing);

      // 기한을 멀리(다음 달 25일) 잡고 추가.
      await tester.tap(_key('todo-period-field'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(DateRangeCalendarPanel),
          matching: find.byIcon(Icons.chevron_right),
        ),
      );
      await tester.pumpAndSettle();
      await _tapDay(tester, '25');
      await _tapDay(tester, '25');
      await tester.ensureVisible(_key('todo-reminder-add'));
      await tester.tap(_key('todo-reminder-add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('기한 하루 전 (전날 오후 6시)'));
      await tester.pumpAndSettle();
      expect(_key('todo-reminder-0'), findsOneWidget);
      expect(find.textContaining('오후 6:00'), findsOneWidget);
      await tester.ensureVisible(_key('todo-reminder-add'));
      await tester.tap(_key('todo-reminder-add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('기한 1시간 전 (기한일 오후 5시)'));
      await tester.pumpAndSettle();
      expect(_key('todo-reminder-1'), findsOneWidget);
      expect(find.textContaining('오후 5:00'), findsOneWidget);
      // 삭제.
      await tester.tap(_key('todo-reminder-remove-0'));
      await tester.pump();
      expect(_key('todo-reminder-1'), findsNothing);
      expect(_key('todo-reminder-0'), findsOneWidget);
    });

    testWidgets('작성 중에 닫으면 확인을 묻는다', (tester) async {
      final session = _session();
      await _pumpOpener(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          api: FakeTodoApi(me: 'me'),
        ),
      );
      // 바뀐 게 없으면 바로 닫힌다.
      await tester.tap(_key('todo-editor-close'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoEditor), findsNothing);
    });

    testWidgets('쓰던 내용이 있으면 닫기 전에 확인한다', (tester) async {
      final session = _session();
      await _pumpOpener(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          api: FakeTodoApi(me: 'me'),
        ),
      );
      await tester.enterText(_key('todo-title-field'), '쓰던 제목');
      await tester.pump();
      await tester.tap(_key('todo-editor-close'));
      await tester.pumpAndSettle();
      expect(find.text('작성 중인 할 일을 버리고 닫을까요?'), findsOneWidget);
      await tester.tap(find.text('계속 쓰기'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoEditor), findsOneWidget);
      await tester.tap(_key('todo-editor-close'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoEditor), findsNothing);
    });

    testWidgets('모바일 폭(360)에서는 전체 화면으로 열리고 넘치지 않는다', (tester) async {
      final session = _session();
      await _pumpOpener(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          api: FakeTodoApi(me: 'me'),
        ),
        size: const Size(360, 780),
      );
      expect(find.byType(Scaffold), findsWidgets);
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
      expect(_key('todo-submit'), findsOneWidget);
    });
  });

  group('할 일 수정 창', () {
    Todo todo({String creator = 'me', List<String> assignees = const ['u2']}) =>
        Todo.fromJson(
          todoJson(
            id: 'e1',
            title: '고칠 할 일',
            description: '원래 설명',
            creatorId: creator,
            assignees: assignees,
            dueDate: '2099-12-31',
            attachmentCount: 1,
          ),
        );

    testWidgets('대화방은 잠기고, 바뀐 칸만 보낸다', (tester) async {
      final session = _session();
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(id: 'e1', assignees: ['u2']),
        ],
      );
      Todo? saved;
      await _pumpOpener(tester, (c) async {
        saved = await showTodoEditor(
          c,
          session: session,
          editing: todo(),
          api: api,
        );
      });
      expect(find.text('할 일 수정'), findsOneWidget);
      expect(_key('todo-room-locked'), findsOneWidget);
      expect(_key('todo-room-field'), findsNothing);
      expect(find.text('한 번 만든 할 일은 다른 대화방으로 옮길 수 없습니다.'), findsOneWidget);
      expect(find.text('고칠 할 일'), findsOneWidget);
      // 바꾼 게 없으면 저장도 빈 변경 — 제목만 바꿔 본다.
      await tester.enterText(_key('todo-title-field'), '새 제목');
      await tester.pump();
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(api.lastUpdate, {'title': '새 제목'});
      expect(saved?.title, '새 제목');
    });

    testWidgets('담당자(만든 사람이 아님)는 담당자 칸이 읽기 전용이고 assigneeIds를 보내지 않는다', (
      tester,
    ) async {
      final session = _session();
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(
            id: 'e1',
            title: '고칠 할 일',
            creatorId: 'u2',
            assignees: ['me'],
          ),
        ],
      );
      await _pumpOpener(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          editing: Todo.fromJson(
            todoJson(
              id: 'e1',
              title: '고칠 할 일',
              creatorId: 'u2',
              assignees: ['me'],
            ),
          ),
          api: api,
        ),
      );
      expect(_key('todo-assignee-add'), findsNothing);
      expect(find.text('담당자는 만든 사람만 바꿀 수 있습니다.'), findsOneWidget);
      await tester.enterText(_key('todo-description-field'), '담당자가 쓴 설명');
      await tester.pump();
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(api.lastUpdate, {'description': '담당자가 쓴 설명'});
      expect(api.lastUpdate!.containsKey('assigneeIds'), isFalse);
    });

    testWidgets('만든 사람은 담당자를 바꾸면 assigneeIds를 보낸다', (tester) async {
      final session = _session();
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(id: 'e1', title: '고칠 할 일', assignees: ['u2']),
        ],
      );
      await _pumpOpener(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          editing: Todo.fromJson(
            todoJson(id: 'e1', title: '고칠 할 일', assignees: ['u2']),
          ),
          api: api,
        ),
      );
      await tester.tap(_key('todo-assignee-add'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-assignee-option-u3'));
      await tester.pump();
      await tester.tap(_key('todo-assignee-ok'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(api.lastUpdate!['assigneeIds'], unorderedEquals(['u2', 'u3']));
    });
  });

  // ────────────────────────── 상세 ──────────────────────────
  group('할 일 상세', () {
    Future<FakeTodoApi> open(
      WidgetTester tester, {
      required Map<String, dynamic> json,
      TodoOpenRoom? onOpenRoom,
      Stream<Map<String, dynamic>>? changed,
      Size size = const Size(900, 900),
      Session? session,
    }) async {
      final api = FakeTodoApi(me: 'me', todos: [json]);
      final s = session ?? _session();
      await _pumpOpener(
        tester,
        (c) => showTodoDetail(
          c,
          session: s,
          todo: Todo.fromJson(json),
          api: api,
          onOpenRoom: onOpenRoom,
          changed: changed ?? const Stream.empty(),
        ),
        size: size,
      );
      return api;
    }

    testWidgets('내용 — 제목·상태·설명·기간·담당자·대화방·알림·만든 사람', (tester) async {
      await open(
        tester,
        json: todoJson(
          title: '상세 확인',
          description: '설명 내용',
          startDate: '2026-10-01',
          dueDate: '2099-10-05',
          progress: 25,
          assignees: ['u2', 'u3'],
          attachmentCount: 2,
          creatorName: '나',
          reminders: [
            {
              'id': 'r1',
              'remindAt': DateTime(2099, 10, 4, 18).millisecondsSinceEpoch,
              'sent': false,
            },
          ],
        ),
      );
      expect(find.text('상세 확인'), findsOneWidget);
      expect(find.text('진행 25%'), findsOneWidget);
      expect(find.text('25%'), findsWidgets);
      expect(find.text('설명 내용'), findsOneWidget);
      expect(find.text('2026/10/01 ~ 2099/10/05'), findsOneWidget);
      expect(_key('todo-detail-assignee-u2'), findsOneWidget);
      expect(_key('todo-detail-assignee-u3'), findsOneWidget);
      expect(find.text('영업 토픽'), findsOneWidget);
      expect(find.text('2099/10/04 오후 6:00'), findsOneWidget);
      expect(find.textContaining('나 · '), findsOneWidget);
      expect(find.text('자료0.pdf'), findsOneWidget);
    });

    testWidgets('⋯ 메뉴 — 만든 사람은 수정·삭제, 담당자는 수정만, 그 외는 메뉴가 없다', (tester) async {
      await open(tester, json: todoJson());
      await tester.tap(_key('todo-detail-menu'));
      await tester.pumpAndSettle();
      expect(_key('todo-menu-edit'), findsOneWidget);
      expect(_key('todo-menu-delete'), findsOneWidget);
    });

    testWidgets('담당자의 ⋯ 메뉴는 수정만', (tester) async {
      await open(
        tester,
        json: todoJson(creatorId: 'u2', assignees: ['me']),
      );
      await tester.tap(_key('todo-detail-menu'));
      await tester.pumpAndSettle();
      expect(_key('todo-menu-edit'), findsOneWidget);
      expect(_key('todo-menu-delete'), findsNothing);
    });

    testWidgets('권한 없는 사람은 ⋯ 메뉴도 진척률 조절도 없다(읽기 전용)', (tester) async {
      await open(
        tester,
        json: todoJson(creatorId: 'u2', assignees: ['u3']),
      );
      expect(_key('todo-detail-menu'), findsNothing);
      final chip = tester.widget<ChoiceChip>(_key('todo-progress-50'));
      expect(chip.onSelected, isNull);
      expect(find.text('만든 사람과 담당자만 수정할 수 있습니다.'), findsOneWidget);
      final complete = tester.widget<FilledButton>(
        _key('todo-complete-button'),
      );
      expect(complete.onPressed, isNull);
    });

    testWidgets('진척률 단추와 완료 단추 — 서버로 보내고 상태 칩이 바뀐다', (tester) async {
      final api = await open(tester, json: todoJson());
      expect(find.text('대기'), findsOneWidget);
      await tester.tap(_key('todo-progress-50'));
      await tester.pumpAndSettle();
      expect(api.lastUpdate, {'progress': 50});
      expect(find.text('진행 50%'), findsOneWidget);
      await tester.tap(_key('todo-complete-button'));
      await tester.pumpAndSettle();
      expect(api.lastUpdate, {'progress': 100});
      expect(find.text('완료'), findsWidgets);
      // 완료되면 "완료 취소"로 바뀐다.
      expect(find.text('완료 취소'), findsOneWidget);
      await tester.tap(_key('todo-complete-button'));
      await tester.pumpAndSettle();
      expect(api.lastUpdate, {'progress': 0});
      expect(find.text('대기'), findsOneWidget);
    });

    testWidgets('진척률을 바꾸지 못하면 토스트로 알린다', (tester) async {
      final api = await open(tester, json: todoJson());
      api.failWith = '권한이 없습니다.';
      await tester.tap(_key('todo-progress-75'));
      await tester.pumpAndSettle();
      expect(find.textContaining('진척률을 바꾸지 못했습니다'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('삭제 — 확인 대화상자를 거쳐 지우고 상세가 닫힌다', (tester) async {
      final api = await open(tester, json: todoJson(id: 'del1'));
      await tester.tap(_key('todo-detail-menu'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-menu-delete'));
      await tester.pumpAndSettle();
      expect(find.textContaining('할 일을 삭제할까요?'), findsOneWidget);
      // 취소하면 아무 일도 없다.
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(api.callCount('delete'), 0);
      await tester.tap(_key('todo-detail-menu'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-menu-delete'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-confirm-delete'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('delete del1'));
      expect(find.byType(TodoDetail), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('수정 — 편집 창이 열리고 저장한 값이 상세에 반영된다', (tester) async {
      final api = await open(
        tester,
        json: todoJson(id: 'ed1', title: '옛 제목'),
      );
      await tester.tap(_key('todo-detail-menu'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-menu-edit'));
      await tester.pumpAndSettle();
      expect(find.text('할 일 수정'), findsOneWidget);
      await tester.enterText(_key('todo-title-field'), '새 제목');
      await tester.pump();
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(api.lastUpdate, {'title': '새 제목'});
      expect(find.text('새 제목'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('대화방·원본 메시지 보기를 누르면 방을 연다', (tester) async {
      final session = _session();
      Room? opened;
      String? openedMessage;
      await open(
        tester,
        session: session,
        json: todoJson(sourceMessageId: 'm9'),
        onOpenRoom: (room, {messageId}) {
          opened = room;
          openedMessage = messageId;
        },
      );
      await tester.tap(_key('todo-detail-source'));
      await tester.pumpAndSettle();
      expect(opened?.id, 'r1');
      expect(openedMessage, 'm9');
      expect(find.byType(TodoDetail), findsNothing);
    });

    testWidgets('onOpenRoom이 없으면 대화방 이동 단추가 없다', (tester) async {
      await open(tester, json: todoJson(sourceMessageId: 'm9'));
      expect(_key('todo-detail-source'), findsNothing);
    });

    testWidgets('열려 있는 동안 지워지면(소켓 deleted) 닫힌다', (tester) async {
      final changed = StreamController<Map<String, dynamic>>.broadcast();
      await open(
        tester,
        json: todoJson(id: 'gone'),
        changed: changed.stream,
      );
      changed.add({'todoId': 'gone', 'kind': 'deleted'});
      await tester.pumpAndSettle();
      expect(find.byType(TodoDetail), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      await changed.close();
    });

    testWidgets('다른 사람이 고치면(소켓 updated) 다시 받아 그린다', (tester) async {
      final changed = StreamController<Map<String, dynamic>>.broadcast();
      final api = await open(
        tester,
        json: todoJson(id: 'live', title: '처음 제목'),
        changed: changed.stream,
      );
      api.todos.first['title'] = '바뀐 제목';
      changed.add({'todoId': 'live', 'kind': 'updated'});
      await tester.pumpAndSettle();
      expect(find.text('바뀐 제목'), findsOneWidget);
      await changed.close();
    });

    testWidgets('모바일 폭(360)에서는 전체 화면이고 넘치지 않는다', (tester) async {
      await open(
        tester,
        json: todoJson(
          title: '아주 긴 제목의 할 일 아주 긴 제목의 할 일 아주 긴 제목의 할 일',
          description: '설명 ' * 50,
          assignees: ['u2', 'u3', 'u4'],
          attachmentCount: 3,
          dueDate: '2020-01-01',
        ),
        size: const Size(360, 780),
      );
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
      expect(_key('todo-detail-title'), findsOneWidget);
    });
  });

  // ────────────────────────── 메시지·댓글에서 만들기 ──────────────────────────
  group('메시지·댓글에서 할 일로 등록', () {
    Message msg({
      String id = 'm1',
      String roomId = 'r1',
      MessageType type = MessageType.text,
      String? text = '내일까지 견적서 보내기\n둘째 줄 내용',
      List<MessageAttachment> attachments = const [],
      bool poll = false,
      bool deleted = false,
    }) => Message(
      id: id,
      roomId: roomId,
      senderId: 'u2',
      senderName: '김철수',
      type: type,
      text: text,
      createdAt: DateTime(2026, 10, 3),
      attachments: attachments,
      isPoll: poll,
      deleted: deleted,
    );

    test('노출 조건 — 텍스트·사진·파일만, 시스템·투표·삭제·비밀 대화·읽기 전용 제외', () {
      final session = _session(
        rooms: [
          _topic('r1'),
          _topic('ro', readOnly: true),
          _topic('sec', secret: true),
        ],
      );
      expect(canRegisterAsTodo(session, msg()), isTrue);
      expect(
        canRegisterAsTodo(session, msg(type: MessageType.image, text: null)),
        isTrue,
      );
      expect(
        canRegisterAsTodo(session, msg(type: MessageType.file, text: null)),
        isTrue,
      );
      expect(
        canRegisterAsTodo(session, msg(type: MessageType.system)),
        isFalse,
      );
      expect(
        canRegisterAsTodo(session, msg(type: MessageType.sticker)),
        isFalse,
      );
      expect(canRegisterAsTodo(session, msg(poll: true)), isFalse);
      expect(canRegisterAsTodo(session, msg(deleted: true)), isFalse);
      expect(canRegisterAsTodo(session, msg(roomId: 'sec')), isFalse);
      expect(canRegisterAsTodo(session, msg(roomId: 'ro')), isFalse);
      expect(canRegisterAsTodo(session, msg(roomId: 'unknown')), isFalse);
    });

    test('첨부 — 목록이 있으면 그것, 없으면 파일 칸 하나, 최대 30개', () {
      final withList = msg(
        type: MessageType.image,
        attachments: [
          for (var i = 0; i < 35; i++)
            MessageAttachment(
              id: 'a$i',
              kind: 'image',
              fileUrl: '/files/t$i',
              fileName: '$i.png',
            ),
        ],
      );
      expect(todoAttachmentsOf(withList), hasLength(30));
      final single = Message(
        id: 'c1',
        roomId: 'r1',
        senderName: '김철수',
        type: MessageType.file,
        fileUrl: '/files/x',
        fileName: '계약서.pdf',
        fileSize: 10,
        createdAt: DateTime(2026),
      );
      final list = todoAttachmentsOf(single);
      expect(list.single.fileName, '계약서.pdf');
      expect(list.single.isImage, isFalse);
      expect(
        todoAttachmentsOf(
          msg(
            type: MessageType.image,
            attachments: const [
              MessageAttachment(
                id: 'd',
                kind: 'image',
                fileUrl: '',
                fileName: '지움.png',
                deleted: true,
              ),
            ],
          ),
        ),
        isEmpty,
      );
    });

    testWidgets('등록하면 방이 고정되고 제목(첫 줄)·설명(본문)·첨부가 미리 채워진다', (tester) async {
      final session = _session();
      final api = FakeTodoApi(me: 'me');
      await _pumpOpener(
        tester,
        (c) => registerMessageAsTodo(
          c,
          session: session,
          message: msg(
            type: MessageType.image,
            attachments: const [
              MessageAttachment(
                id: 'a0',
                kind: 'image',
                fileUrl: '/files/t0',
                fileName: '사진.png',
                fileSize: 10,
              ),
              MessageAttachment(
                id: 'a1',
                kind: 'image',
                fileUrl: '/files/t1',
                fileName: '사진2.png',
                fileSize: 10,
              ),
            ],
          ),
          api: api,
        ),
      );
      expect(_key('todo-room-locked'), findsOneWidget, reason: '방이 고정된다');
      expect(find.text('영업 토픽'), findsOneWidget);
      expect(
        tester.widget<TextField>(_key('todo-title-field')).controller!.text,
        '내일까지 견적서 보내기',
      );
      expect(
        tester
            .widget<TextField>(_key('todo-description-field'))
            .controller!
            .text,
        '내일까지 견적서 보내기\n둘째 줄 내용',
      );
      expect(
        tester.state<TodoEditorState>(find.byType(TodoEditor)).attachmentCount,
        2,
      );
      // 제목은 고칠 수 있다.
      await tester.enterText(_key('todo-title-field'), '고친 제목');
      await tester.pump();
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(api.lastCreateRoomId, 'r1');
      expect(api.lastCreate!['title'], '고친 제목');
      expect(api.lastCreate!['sourceMessageId'], 'm1');
      expect(api.lastCreate!['sourceCommentId'], isNull);
      expect(api.lastCreateAttachments, hasLength(2));
      expect(api.lastCreateAttachments.first.url, '/files/t0');
      expect(find.text('할 일로 등록했습니다.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('댓글에서 등록하면 sourceCommentId로 보낸다', (tester) async {
      final session = _session();
      final api = FakeTodoApi(me: 'me');
      await _pumpOpener(
        tester,
        (c) => registerMessageAsTodo(
          c,
          session: session,
          message: msg(id: 'c1', text: '댓글 내용'),
          isComment: true,
          api: api,
        ),
      );
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(api.lastCreate!['sourceCommentId'], 'c1');
      expect(api.lastCreate!['sourceMessageId'], isNull);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('글 없는 사진 메시지는 첫 파일 이름이 제목 후보', (tester) async {
      final session = _session();
      await _pumpOpener(
        tester,
        (c) => registerMessageAsTodo(
          c,
          session: session,
          message: msg(
            type: MessageType.file,
            text: null,
            attachments: const [
              MessageAttachment(
                id: 'a0',
                kind: 'file',
                fileUrl: '/files/t0',
                fileName: '계약서.pdf',
              ),
            ],
          ),
          api: FakeTodoApi(me: 'me'),
        ),
      );
      expect(
        tester.widget<TextField>(_key('todo-title-field')).controller!.text,
        '계약서.pdf',
      );
    });

    testWidgets('메시지 길게 누르기 시트에 "할 일로 등록"이 있고, 투표·비밀 대화에는 없다', (tester) async {
      final session = _session(
        rooms: [_topic('r1'), _topic('sec', secret: true)],
      );
      Future<void> openSheet(Message m, {bool comment = false}) async {
        await _pumpOpener(
          tester,
          (c) async => showMessageActionSheet(
            c,
            session: session,
            message: m,
            senderDisplayName: '김철수',
            isComment: comment,
          ),
        );
      }

      await openSheet(msg());
      expect(_key('action-todo'), findsOneWidget);
      expect(find.text('할 일로 등록'), findsOneWidget);
    });

    testWidgets('시트 — 투표 메시지에는 항목이 없다', (tester) async {
      final session = _session();
      await _pumpOpener(
        tester,
        (c) async => showMessageActionSheet(
          c,
          session: session,
          message: msg(poll: true),
          senderDisplayName: '김철수',
        ),
      );
      expect(_key('action-todo'), findsNothing);
    });

    testWidgets('시트 — 비밀 대화에는 항목이 없다', (tester) async {
      final session = _session(rooms: [_topic('sec', secret: true)]);
      await _pumpOpener(
        tester,
        (c) async => showMessageActionSheet(
          c,
          session: session,
          message: msg(roomId: 'sec'),
          senderDisplayName: '김철수',
        ),
      );
      expect(_key('action-todo'), findsNothing);
    });

    testWidgets('시트의 항목을 누르면 생성 창이 열린다', (tester) async {
      final session = _session();
      await _pumpOpener(
        tester,
        (c) async => showMessageActionSheet(
          c,
          session: session,
          message: msg(),
          senderDisplayName: '김철수',
        ),
      );
      await tester.tap(_key('action-todo'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoEditor), findsOneWidget);
      expect(_key('todo-room-locked'), findsOneWidget);
    });
  });

  // ────────────────────────── 메뉴·패널 등록 ──────────────────────────
  group('메뉴·패널 등록', () {
    test('"할 일"은 생성 묶음 order 20(메시지 예약 10, 투표 30 사이)에 있다', () {
      final session = _session();
      final entries = menuEntriesFor(MenuSection.create, session);
      final keys = entries.map((e) => e.key).toList();
      expect(keys, containsAllInOrder(['schedule', 'todos', 'poll']));
      final todos = entries.firstWhere((e) => e.key == 'todos');
      expect(todos.label, '할 일');
      expect(todos.order, 20);
      expect(sidePanelSpecFor('todos'), isNotNull);
      expect(sidePanelSpecFor('todos')!.title, '할 일');
    });

    testWidgets('모바일(홈 셸 없음)에서 메뉴를 누르면 전체 화면 패널이 열린다', (tester) async {
      final session = _session();
      await _pumpOpener(tester, (c) async {
        openSidePanel(c, session, 'todos');
      }, size: const Size(400, 800));
      expect(find.byType(TodosPanel), findsOneWidget);
      expect(find.text('할 일'), findsWidgets);
      expect(_key('todo-create'), findsOneWidget);
    });
  });
}

class _FailingListApi extends FakeTodoApi {
  _FailingListApi() : super(me: 'me');

  @override
  Future<TodoPage> list({
    required String teamId,
    required TodoScope scope,
    bool includeDone = true,
    String? roomId,
    TodoSort sort = TodoSort.due,
    int offset = 0,
    int limit = 30,
  }) async => throw const ApiException('서버 오류');
}
