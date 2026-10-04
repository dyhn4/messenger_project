import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/models/todo.dart';
import 'package:client/screens/todo_detail_dialog.dart';
import 'package:client/screens/todo_editor_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/services/todo_api.dart';
import 'package:client/services/todo_controller.dart';
import 'package:client/widgets/filter_dropdown.dart';
import 'package:client/widgets/side_panel_header.dart';
import 'package:client/widgets/todo_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers/fake_todo_api.dart';

/// 할 일 잔디 맞추기의 바탕 — 모델(진척률 문구·담당자별 진척률·요약 %·달력 범위), API(새 쿼리·즐겨찾기·total)와 가짜
/// API의 서버 규칙(scope 새 의미·담당자 필터·기간 겹침·즐겨찾기 먼저·기준 진척률·내 진척률 권한·집계·담당자를 모두 뺄 때의
/// S3 규칙·total), 컨트롤러(처음 정렬 생성 순·total·담당자 필터 비우기·즐겨찾기 낙관적 갱신·관점 진척률·달력 받기), 공용
/// 위젯(진척률 색·진척률 고르기 상자·패널 안 화면 머리), 대화방 필터 글자, 상세·생성의 모양(대화상자·전체 화면·패널 안
/// 화면), 보드 뷰 제외.

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

Session _session() {
  final session = Session(
    notifications: _QuietNotifications(),
    settings: AppSettings(),
  );
  session.serverUrl = 'https://test.local';
  session.userId = 'me';
  session.name = '나';
  session.accountRole = AccountRole.member;
  final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  return session;
}

Map<String, dynamic> _member(String id, String name) => {
  'id': id,
  'username': id,
  'name': name,
  'role': 'member',
};

/// [_session]에 영업 토픽(r1 — 나·김철수)을 더한 것 — 상세·생성 화면 시험용.
Session _roomSession() {
  final session = _session();
  session.rooms.add(
    Room.fromJson({
      'id': 'r1',
      'teamId': 't1',
      'type': 'topic',
      'name': '영업 토픽',
      'members': [_member('me', '나'), _member('u2', '김철수')],
      'createdAt': 1000,
    }),
  );
  return session;
}

/// PC 할 일 패널처럼 창 오른쪽 420 칸에 중첩 Navigator(키 panel-nav)를 두고, 그 첫 화면의 단추(키 panel-opener)로
/// [open]을 부른다 — 패널 안 화면(TodoViewMode.panel) 시험용.
Future<void> _pumpPanelHost(
  WidgetTester tester,
  Future<void> Function(BuildContext context) open,
) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            const Expanded(child: SizedBox()),
            SizedBox(
              key: const ValueKey('panel-host'),
              width: 420,
              child: ClipRect(
                child: Navigator(
                  key: const ValueKey('panel-nav'),
                  onGenerateRoute: (settings) => MaterialPageRoute(
                    builder: (context) => Material(
                      child: Center(
                        child: ElevatedButton(
                          key: const ValueKey('panel-opener'),
                          onPressed: () => open(context),
                          child: const Text('열기'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('panel-opener')));
  await tester.pumpAndSettle();
}

/// 버튼 하나로 [open]을 부르는 보통 화면(폭 [width]) — 모양을 안 정했을 때(넓으면 대화상자, 좁으면 전체 화면) 시험용.
Future<void> _pumpOpener(
  WidgetTester tester,
  double width,
  Future<void> Function(BuildContext context) open,
) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SizedBox());
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

Future<List<String>> _ids(Future<TodoPage> page) async => [
  for (final t in (await page).items) t.id,
];

/// 목록 조회를 한 건씩 직접 풀어 주는 가짜 — 늦게 온 응답 시험용.
class _ManualListApi extends FakeTodoApi {
  _ManualListApi({super.todos}) : super(me: 'me');

  final _gates = <Completer<void>>[];

  void release(int i) => _gates[i].complete();

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
  }) async {
    final gate = Completer<void>();
    _gates.add(gate);
    await gate.future;
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

/// 예전 서버처럼 목록 응답에 total이 없는 가짜.
class _NoTotalApi extends FakeTodoApi {
  _NoTotalApi({super.todos}) : super(me: 'me');

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
  }) async {
    final page = await super.list(
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
    return TodoPage(items: page.items, hasMore: page.hasMore);
  }
}

class _FailingListApi extends FakeTodoApi {
  _FailingListApi() : super(me: 'me');

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
  }) async => throw const ApiException('서버 오류');
}

void main() {
  // ────────────────────────── 모델 ──────────────────────────
  group('할 일 모델 — 진척률 문구·담당자별 진척률·달력 범위', () {
    test('진척률 문구 — 목록 칩, 고르는 메뉴·담당자 줄(잔디 `대기(0%)`), % 문구', () {
      expect(todoProgressSteps, [0, 25, 50, 75, 100]);
      expect(
        [for (final p in todoProgressSteps) todoProgressText(p)],
        ['대기', '진행 25%', '진행 50%', '진행 75%', '완료'],
      );
      expect(
        [for (final p in todoProgressSteps) todoProgressMenuLabel(p)],
        ['대기(0%)', '진행(25%)', '진행(50%)', '진행(75%)', '완료(100%)'],
      );
      expect(todoProgressText(33), '진행 33%', reason: '집계 값은 1~99 아무 값이나');
      expect(todoProgressMenuLabel(33), '진행(33%)', reason: '단계 밖의 값도');
      expect(
        [
          for (final p in [0, 33, 75, 100]) todoPercentText(p),
        ],
        ['0%', '33%', '75%', '100%'],
      );
    });

    test('보기·정렬 — 잔디 문구와 메뉴 순서(모든 / 나의 / 부여한, 생성 순 / 기한 순)', () {
      expect(TodoScope.team.label, '모든 할 일');
      expect(TodoScope.team.wire, 'team', reason: '와이어 값은 그대로');
      expect(TodoScope.menuOrder, [
        TodoScope.team,
        TodoScope.mine,
        TodoScope.assignedByMe,
      ]);
      expect(
        [for (final s in TodoScope.menuOrder) s.label],
        ['모든 할 일', '나의 할 일', '부여한 할 일'],
      );
      expect(TodoScope.values, TodoScope.menuOrder, reason: '선언 순서도 메뉴 순서');
      expect(
        [for (final s in TodoScope.values) s.wire],
        ['team', 'mine', 'assigned_by_me'],
      );
      expect(TodoSort.menuOrder, [TodoSort.created, TodoSort.due]);
      expect(TodoSort.values, TodoSort.menuOrder);
      expect([for (final s in TodoSort.menuOrder) s.label], ['생성 순', '기한 순']);
      expect([for (final s in TodoSort.menuOrder) s.wire], ['created', 'due']);
    });

    test('fromJson — 담당자별 진척률·내 진척률·즐겨찾기, 요약 문구', () {
      final t = Todo.fromJson(
        todoJson(
          assignees: ['me', 'u2', 'u3'],
          assigneeProgress: {'me': 100, 'u2': 50},
          favorite: true,
        ),
      );
      expect(t.assigneeProgress, {'me': 100, 'u2': 50, 'u3': 0});
      expect(t.progressOf('u2'), 50);
      expect(t.progressOf('nobody'), 0);
      expect(t.myProgress, 100);
      expect(t.canSetProgress, isTrue);
      expect(t.favorite, isTrue);
      expect(t.progress, 50, reason: '전체 = 평균 150/3');
      expect(t.doneCount, 1);
      expect(t.summaryText, '50%', reason: '사람 수(진행 1/3) 대신 집계 %');
      expect(t.statusText, '진행 50%');
    });

    test('fromJson — 예전 서버 응답(새 필드 없음)은 기본값', () {
      final t = Todo.fromJson({
        'id': 'old',
        'teamId': 't1',
        'roomId': 'r1',
        'title': '예전 할 일',
        'progress': 40,
        'assignees': [
          {'id': 'u2', 'name': '김철수'},
        ],
        'createdAt': 1000,
        'updatedAt': 1000,
      });
      expect(t.assignees.single.id, 'u2');
      expect(t.assigneeProgress, isEmpty);
      expect(t.progressOf('u2'), 0);
      expect(t.myProgress, isNull);
      expect(t.canSetProgress, isFalse);
      expect(t.favorite, isFalse);
      expect(t.statusText, '진행 40%');
    });

    test('요약 문구 — 담당자 수와 상관없이 전체(집계) 진척률 %', () {
      expect(Todo.fromJson(todoJson(progress: 25)).summaryText, '25%');
      expect(
        Todo.fromJson(todoJson(assignees: ['u2'], progress: 100)).summaryText,
        '100%',
      );
      expect(
        Todo.fromJson(
          todoJson(assignees: ['u2', 'u3'], progress: 100),
        ).summaryText,
        '100%',
      );
      expect(
        Todo.fromJson(todoJson(assignees: ['u2', 'u3'])).summaryText,
        '0%',
      );
      expect(
        Todo.fromJson(
          todoJson(
            assignees: ['u2', 'u3', 'u4'],
            assigneeProgress: {'u2': 100, 'u3': 25, 'u4': 0},
          ),
        ).summaryText,
        '42%',
        reason: '평균 125/3 반올림',
      );
    });

    test('내 진척률 — 담당자면 내 것, 담당자 없는 내 할 일이면 할 일 것, 그 밖은 없음', () {
      final personal = Todo.fromJson(todoJson(progress: 25));
      expect(personal.myProgress, 25);
      expect(personal.canSetProgress, isTrue);
      final given = Todo.fromJson(todoJson(assignees: ['u2'], progress: 50));
      expect(given.myProgress, isNull, reason: '만든 사람이라도 담당자가 아니면 못 바꾼다');
      expect(given.canSetProgress, isFalse);
      final viewer = Todo.fromJson(
        todoJson(creatorId: 'u2', assignees: ['u3']),
      );
      expect(viewer.myProgress, isNull);
      final assigned = Todo.fromJson(
        todoJson(
          creatorId: 'u2',
          assignees: ['me', 'u3'],
          assigneeProgress: {'me': 75},
        ),
      );
      expect(assigned.myProgress, 75);
      expect(assigned.canSetProgress, isTrue);
    });

    test('copyWith — 즐겨찾기·내 진척률만 바꾼 사본', () {
      final t = Todo.fromJson(
        todoJson(
          id: 'x',
          title: '제목',
          assignees: ['me'],
          dueDate: '2026-10-05',
        ),
      );
      final f = t.copyWith(favorite: true, myProgress: 50);
      expect(f.favorite, isTrue);
      expect(f.myProgress, 50);
      expect(f.id, 'x');
      expect(f.title, '제목');
      expect(f.dueDate, '2026-10-05');
      expect(f.assignees.single.id, 'me');
      expect(f.canSetProgress, isTrue);
      expect(t.favorite, isFalse, reason: '원본은 그대로');
    });

    test('지난 기한 — 다른 진척률 기준으로도 따진다(isOverdueFor)', () {
      final now = DateTime(2026, 10, 3, 12);
      final t = Todo.fromJson(
        todoJson(
          dueDate: '2026-10-02',
          assignees: ['me', 'u2'],
          assigneeProgress: {'me': 100},
        ),
      );
      expect(t.isOverdue(now), isTrue, reason: '전체는 아직 50');
      expect(
        t.isOverdueFor(t.progressOf('me'), now),
        isFalse,
        reason: '나는 끝냈다',
      );
      expect(t.isOverdueFor(t.progressOf('u2'), now), isTrue);
    });

    test('달력 범위 — 그 달 1일이 있는 주의 일요일부터 42일(끝 날 포함)', () {
      final (from, to) = todoCalendarRange(DateTime(2026, 10, 17, 9));
      expect(from, DateTime(2026, 9, 27));
      expect(to, DateTime(2026, 11, 7));
      expect(from.weekday, DateTime.sunday);
      expect(to.weekday, DateTime.saturday);
      // 1일이 일요일이면 그날부터.
      final (febFrom, febTo) = todoCalendarRange(DateTime(2026, 2));
      expect(febFrom, DateTime(2026, 2, 1));
      expect(febTo, DateTime(2026, 3, 14));
      // 해가 바뀌는 달.
      final (janFrom, janTo) = todoCalendarRange(DateTime(2027, 1, 31));
      expect(janFrom, DateTime(2026, 12, 27));
      expect(janTo, DateTime(2027, 2, 6));
    });

    test('todoCoversDate — 시작일 ?? 종료일 ~ 종료일 ?? 시작일, 날짜가 없으면 false', () {
      final both = Todo.fromJson(
        todoJson(startDate: '2026-10-01', dueDate: '2026-10-03'),
      );
      expect(todoCoversDate(both, DateTime(2026, 9, 30)), isFalse);
      expect(todoCoversDate(both, DateTime(2026, 10, 1)), isTrue);
      expect(todoCoversDate(both, DateTime(2026, 10, 3, 23, 59)), isTrue);
      expect(todoCoversDate(both, DateTime(2026, 10, 4)), isFalse);
      final dueOnly = Todo.fromJson(todoJson(dueDate: '2026-10-05'));
      expect(todoCoversDate(dueOnly, DateTime(2026, 10, 5)), isTrue);
      expect(todoCoversDate(dueOnly, DateTime(2026, 10, 4)), isFalse);
      final startOnly = Todo.fromJson(todoJson(startDate: '2026-10-07'));
      expect(todoCoversDate(startOnly, DateTime(2026, 10, 7)), isTrue);
      expect(todoCoversDate(startOnly, DateTime(2026, 10, 8)), isFalse);
      expect(
        todoCoversDate(Todo.fromJson(todoJson()), DateTime(2026, 10, 7)),
        isFalse,
      );
    });
  });

  // ────────────────────────── API ──────────────────────────
  group('RemoteTodoApi', () {
    test('목록은 assigneeId·from/to를 쿼리로, 즐겨찾기는 PUT', () async {
      final requests = <http.Request>[];
      final client = ApiClient(
        baseUrl: 'https://test.local',
        token: 't',
        httpClient: MockClient((request) async {
          requests.add(request);
          final body = request.method == 'PUT'
              ? {'favorite': true}
              : {'items': <Object>[], 'hasMore': false};
          return http.Response.bytes(
            utf8.encode(jsonEncode(body)),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      final api = RemoteTodoApi(client);
      await api.list(
        teamId: 't1',
        scope: TodoScope.assignedByMe,
        assigneeId: 'u2',
        from: DateTime(2026, 9, 27),
        to: DateTime(2026, 11, 7),
        limit: todoRangeMaxLimit,
      );
      final q = requests.single.url.queryParameters;
      expect(q['scope'], 'assigned_by_me');
      expect(q['assigneeId'], 'u2');
      expect(q['from'], '2026-09-27');
      expect(q['to'], '2026-11-07');
      expect(q['limit'], '500');
      requests.clear();
      await api.list(teamId: 't1', scope: TodoScope.mine);
      final plain = requests.single.url.queryParameters;
      expect(plain.containsKey('assigneeId'), isFalse);
      expect(plain.containsKey('from'), isFalse);
      expect(plain.containsKey('to'), isFalse);
      requests.clear();
      expect(await api.setFavorite('x1', true), isTrue);
      expect(requests.single.method, 'PUT');
      expect(requests.single.url.path, '/api/todos/x1/favorite');
      expect(jsonDecode(requests.single.body), {'favorite': true});
    });

    test('목록 응답의 total(필터에 맞는 전체 개수)을 읽고, 없으면(예전 서버) null', () async {
      Object? total;
      final client = ApiClient(
        baseUrl: 'https://test.local',
        token: 't',
        httpClient: MockClient(
          (request) async => http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'items': [todoJson(id: 'a')],
                'hasMore': true,
                'total': ?total,
              }),
            ),
            200,
            headers: const {'content-type': 'application/json'},
          ),
        ),
      );
      final api = RemoteTodoApi(client);
      total = 42;
      final page = await api.list(teamId: 't1', scope: TodoScope.mine);
      expect(page.items.single.id, 'a');
      expect(page.hasMore, isTrue);
      expect(page.total, 42);
      total = null;
      expect(
        (await api.list(teamId: 't1', scope: TodoScope.mine)).total,
        isNull,
      );
      expect(TodoPage.fromJson({'items': <Object>[], 'total': 0}).total, 0);
      expect(const TodoPage().total, isNull);
    });
  });

  // ────────────────────────── 가짜 API(서버 규칙) ──────────────────────────
  group('가짜 API — 서버와 같은 규칙', () {
    test(
      'scope — 나의(내 담당 + 내가 만든 담당자 없는 것) / 부여한(남에게 맡긴 것) / 모든, 담당자 필터',
      () async {
        final api = FakeTodoApi(
          me: 'me',
          todos: [
            todoJson(id: 'a', createdAt: 6), // 내가 만든 개인 할 일
            todoJson(id: 'b', assignees: ['me'], createdAt: 5),
            todoJson(id: 'c', assignees: ['u2'], createdAt: 4),
            todoJson(id: 'd', assignees: ['me', 'u2'], createdAt: 3),
            todoJson(id: 'e', creatorId: 'u2', assignees: ['me'], createdAt: 2),
            todoJson(id: 'f', creatorId: 'u2', createdAt: 1), // 남의 개인 할 일
          ],
        );
        Future<List<String>> ids(TodoScope scope, {String? assigneeId}) =>
            _ids(api.list(teamId: 't1', scope: scope, assigneeId: assigneeId));
        expect(await ids(TodoScope.mine), ['a', 'b', 'd', 'e']);
        expect(await ids(TodoScope.assignedByMe), ['c', 'd']);
        expect(await ids(TodoScope.team), ['a', 'b', 'c', 'd', 'e', 'f']);
        expect(await ids(TodoScope.team, assigneeId: 'u2'), ['c', 'd']);
        expect(await ids(TodoScope.mine, assigneeId: 'u2'), ['d']);
        expect(await ids(TodoScope.assignedByMe, assigneeId: 'me'), ['d']);
        expect(api.calls.last, contains('assignee=me'));
      },
    );

    test('from/to — 기간이 겹치는 것만(날짜 없는 것은 빠짐), 검사와 한도', () async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(id: 'p1', startDate: '2026-09-25', dueDate: '2026-09-28'),
          todoJson(id: 'p2', dueDate: '2026-11-07', createdAt: 2),
          todoJson(id: 'p3', startDate: '2026-09-26', createdAt: 3),
          todoJson(id: 'p4', createdAt: 4),
          todoJson(
            id: 'p5',
            startDate: '2026-09-01',
            dueDate: '2026-12-31',
            createdAt: 5,
          ),
          todoJson(
            id: 'p6',
            startDate: '2026-11-08',
            dueDate: '2026-11-09',
            createdAt: 6,
          ),
        ],
      );
      final (from, to) = todoCalendarRange(DateTime(2026, 10));
      expect(
        await _ids(
          api.list(teamId: 't1', scope: TodoScope.team, from: from, to: to),
        ),
        ['p1', 'p2', 'p5'],
      );
      expect(api.lastList!['from'], '2026-09-27');
      expect(api.lastList!['to'], '2026-11-07');
      // 둘 중 하나만, 순서가 뒤집힘, 100일 넘음은 400.
      await expectLater(
        api.list(teamId: 't1', scope: TodoScope.team, from: from),
        throwsA(isA<ApiException>()),
      );
      await expectLater(
        api.list(teamId: 't1', scope: TodoScope.team, from: to, to: from),
        throwsA(isA<ApiException>()),
      );
      await expectLater(
        api.list(
          teamId: 't1',
          scope: TodoScope.team,
          from: DateTime(2026, 1, 1),
          to: DateTime(2026, 4, 11),
        ),
        throwsA(isA<ApiException>()),
        reason: '양 끝 포함 101일',
      );
      await api.list(
        teamId: 't1',
        scope: TodoScope.team,
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 4, 10),
      );

      // 기간이 있으면 한 번에 500개까지, 없으면 100개까지.
      final many = FakeTodoApi(
        me: 'me',
        todos: [
          for (var i = 0; i < 150; i++)
            todoJson(id: 'm$i', dueDate: '2026-10-10', createdAt: i),
        ],
      );
      final plain = await many.list(
        teamId: 't1',
        scope: TodoScope.team,
        limit: todoRangeMaxLimit,
      );
      expect(plain.items, hasLength(todoListMaxLimit));
      expect(plain.hasMore, isTrue);
      final ranged = await many.list(
        teamId: 't1',
        scope: TodoScope.team,
        from: from,
        to: to,
        limit: todoRangeMaxLimit,
      );
      expect(ranged.items, hasLength(150));
      expect(ranged.hasMore, isFalse);
    });

    test('정렬 — 내가 즐겨찾기한 것이 먼저, 그다음 기존 순서', () async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(id: 'x1', dueDate: '2026-10-01', createdAt: 1),
          todoJson(
            id: 'x2',
            dueDate: '2026-10-05',
            favorite: true,
            createdAt: 2,
          ),
          todoJson(id: 'x3', progress: 100, favorite: true, createdAt: 3),
          todoJson(id: 'x4', createdAt: 4),
        ],
      );
      expect(await _ids(api.list(teamId: 't1', scope: TodoScope.team)), [
        'x2',
        'x3',
        'x1',
        'x4',
      ]);
      expect(
        await _ids(
          api.list(teamId: 't1', scope: TodoScope.team, sort: TodoSort.created),
        ),
        ['x3', 'x2', 'x4', 'x1'],
      );
    });

    test('완료 제외·정렬은 기준 진척률 — 담당자 필터 > 나의 할 일(내 것) > 전체', () async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(
            id: 'r1',
            assignees: ['me', 'u2'],
            assigneeProgress: {'me': 100, 'u2': 0},
            dueDate: '2026-10-01',
            createdAt: 1,
          ),
          todoJson(
            id: 'r2',
            assignees: ['me', 'u2'],
            assigneeProgress: {'me': 0, 'u2': 100},
            dueDate: '2026-10-02',
            createdAt: 2,
          ),
        ],
      );
      Future<List<String>> ids(
        TodoScope scope, {
        bool includeDone = true,
        String? assigneeId,
      }) => _ids(
        api.list(
          teamId: 't1',
          scope: scope,
          includeDone: includeDone,
          assigneeId: assigneeId,
        ),
      );
      expect(await ids(TodoScope.mine, includeDone: false), ['r2']);
      expect(await ids(TodoScope.team, includeDone: false), ['r1', 'r2']);
      expect(await ids(TodoScope.team, includeDone: false, assigneeId: 'u2'), [
        'r1',
      ]);
      // 기한순의 "미완료 먼저"도 같은 기준.
      expect(await ids(TodoScope.mine), ['r2', 'r1']);
      expect(await ids(TodoScope.team), ['r1', 'r2']);
      expect(await ids(TodoScope.team, assigneeId: 'u2'), ['r1', 'r2']);
      expect(await ids(TodoScope.team, assigneeId: 'me'), ['r2', 'r1']);
    });

    test('total — 같은 필터에 맞는 전체 개수(offset·limit과 상관없이)', () async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          for (var i = 0; i < 7; i++)
            todoJson(id: 'm$i', assignees: ['me'], createdAt: i),
          todoJson(id: 'done', assignees: ['me'], progress: 100, createdAt: 8),
          todoJson(id: 'other', creatorId: 'u2', assignees: ['u3']),
        ],
      );
      final first = await api.list(
        teamId: 't1',
        scope: TodoScope.mine,
        limit: 3,
      );
      expect(first.items, hasLength(3));
      expect(first.hasMore, isTrue);
      expect(first.total, 8);
      final last = await api.list(
        teamId: 't1',
        scope: TodoScope.mine,
        offset: 6,
        limit: 3,
      );
      expect(last.items, hasLength(2));
      expect(last.total, 8);
      final open = await api.list(
        teamId: 't1',
        scope: TodoScope.mine,
        includeDone: false,
        limit: 3,
      );
      expect(open.total, 7, reason: '완료 제외도 반영');
      final team = await api.list(teamId: 't1', scope: TodoScope.team);
      expect(team.total, 9);
    });

    test('즐겨찾기 — 켜고 끄기, 없는 할 일 켜기는 실패·끄기는 그냥 된다', () async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [todoJson(id: 'a')],
      );
      expect(await api.setFavorite('a', true), isTrue);
      expect((await api.get('a')).favorite, isTrue);
      expect(await api.setFavorite('a', false), isFalse);
      expect((await api.get('a')).favorite, isFalse);
      expect(await api.setFavorite('missing', false), isFalse);
      await expectLater(
        api.setFavorite('missing', true),
        throwsA(isA<ApiException>()),
      );
      api.failWith = '실패';
      await expectLater(
        api.setFavorite('a', true),
        throwsA(isA<ApiException>()),
      );
      expect(api.callCount('setFavorite'), 5);
      expect(api.calls.first, 'setFavorite a true');
    });

    test('진척률은 "내 진척률" — 담당자는 자기 것만, 바뀌면 전체를 다시 계산', () async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(id: 'g', creatorId: 'u2', assignees: ['me', 'u2', 'u3']),
        ],
      );
      var t = await api.update('g', {'progress': 100});
      expect(t.myProgress, 100);
      expect(t.progressOf('me'), 100);
      expect(t.progressOf('u2'), 0);
      expect(t.progress, 33, reason: '평균 100/3 반올림');
      expect(t.status, TodoStatus.doing);
      expect(t.completedAt, isNull);
      expect(t.summaryText, '33%');

      // 나머지 두 사람도 끝내면 전체 완료(같은 데이터를 다른 사람 기준으로).
      await FakeTodoApi(
        me: 'u2',
        todos: api.todos,
      ).update('g', {'progress': 100});
      await FakeTodoApi(
        me: 'u3',
        todos: api.todos,
      ).update('g', {'progress': 100});
      refreshTodoJson(api.todos.single, me: 'me');
      t = await api.get('g');
      expect(t.progress, 100);
      expect(t.isDone, isTrue);
      expect(t.completedAt, isNotNull);
      expect(t.summaryText, '100%');
      expect(t.myProgress, 100);

      // 한 사람이 되돌리면 전체도 진행으로(완료 시각 해제).
      t = await api.update('g', {'progress': 50});
      expect(t.progress, 83);
      expect(t.completedAt, isNull);
    });

    test('담당자 없는 내 할 일은 만든 사람이 할 일의 진척률을 바꾼다', () async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [todoJson(id: 'p')],
      );
      final t = await api.update('p', {'progress': 50});
      expect(t.progress, 50);
      expect(t.myProgress, 50);
      expect(t.canSetProgress, isTrue);
    });

    test('거절 — 담당자가 아니면 진척률 403, 값은 0·25·50·75·100만, 다른 필드는 기존 권한', () async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(id: 'given', assignees: ['u2']),
          todoJson(id: 'other', creatorId: 'u2', assignees: ['u3']),
          todoJson(id: 'mine', creatorId: 'u2', assignees: ['me']),
        ],
      );
      Future<String> result(String id, Map<String, dynamic> fields) async {
        try {
          await api.update(id, fields);
          return 'ok';
        } on ApiException catch (e) {
          return e.message;
        }
      }

      expect(
        await result('given', {'progress': 100}),
        '담당자만 진척률을 바꿀 수 있습니다.',
        reason: '만든 사람이라도 담당자가 아니면',
      );
      expect(api.todos.first['progress'], 0, reason: '거절되면 아무것도 안 바뀐다');
      expect(await result('other', {'progress': 100}), '담당자만 진척률을 바꿀 수 있습니다.');
      expect(await result('other', {'title': '남의 제목'}), '이 할 일을 수정할 권한이 없습니다.');
      expect(
        await result('mine', {
          'assigneeIds': ['me', 'u3'],
        }),
        '담당자는 담당자 목록을 바꿀 수 없습니다.',
      );
      expect(
        await result('mine', {'progress': 40}),
        '진척률은 0·25·50·75·100 중 하나여야 합니다.',
      );
      expect(
        await result('mine', {'progress': 75, 'title': '같이 보내도 된다'}),
        'ok',
      );
      final mine = await api.get('mine');
      expect(mine.title, '같이 보내도 된다');
      expect(mine.myProgress, 75);
    });

    test('담당자 목록 수정은 차이만 — 남는 사람의 진척률은 그대로, 새 사람은 0', () async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(
            id: 'h',
            assignees: ['me', 'u2'],
            assigneeProgress: {'me': 100, 'u2': 50},
          ),
        ],
      );
      final t = await api.update('h', {
        'assigneeIds': ['u2', 'u3'],
      });
      expect(t.assignees.map((a) => a.id), ['u2', 'u3']);
      expect(t.progressOf('u2'), 50);
      expect(t.progressOf('u3'), 0);
      expect(t.progress, 25);
      expect(t.myProgress, isNull, reason: '담당에서 빠진 만든 사람은 진척률을 못 바꾼다');
      expect(t.canSetProgress, isFalse);
      expect(t.myRole, 'creator');
    });

    test(
      '담당자를 모두 빼면(검토 S3) — 만든 사람이 담당자였으면 그 사람 값, 아니면 직전 집계를 가장 가까운 단계로(반은 올림)',
      () async {
        expect(
          const [
            0,
            8,
            12,
            13,
            37,
            38,
            62,
            63,
            87,
            88,
            100,
          ].map(nearestTodoProgressStep).toList(),
          [0, 0, 0, 25, 25, 50, 50, 75, 75, 100, 100],
        );
        Future<Todo> clear(
          Map<String, int> progress, {
          Map<String, dynamic> extra = const {},
        }) async {
          final api = FakeTodoApi(
            me: 'me',
            todos: [
              todoJson(
                id: 's',
                assignees: progress.keys.toList(),
                assigneeProgress: progress,
              ),
            ],
          );
          return api.update('s', {'assigneeIds': <String>[], ...extra});
        }

        // 만든 사람(나)이 담당자였다 — 집계(63)가 아니라 내 값 25.
        var t = await clear({'me': 25, 'u2': 100});
        expect(t.assignees, isEmpty);
        expect(t.progress, 25);
        expect(t.myProgress, 25, reason: '이제 만든 사람이 직접 고르는 값');
        expect(t.canSetProgress, isTrue);
        // 만든 사람이 담당자가 아니었다 — 직전 집계를 단계로.
        t = await clear({'u2': 50, 'u3': 25});
        expect(t.progress, 50, reason: '집계 38 → 50');
        t = await clear({'u2': 0, 'u3': 25});
        expect(t.progress, 25, reason: '집계 13 → 25');
        t = await clear({'u2': 0, 'u3': 0, 'u4': 25});
        expect(t.progress, 0, reason: '집계 8 → 0');
        t = await clear({'u2': 100, 'u3': 75});
        expect(t.progress, 100, reason: '집계 88 → 100');
        expect(t.isDone, isTrue);
        expect(t.completedAt, isNotNull);
        // 같이 보낸 진척률이 이긴다.
        t = await clear({'u2': 100, 'u3': 75}, extra: {'progress': 0});
        expect(t.progress, 0);
        expect(t.completedAt, isNull);
        // 담당자가 처음부터 없던 할 일은 그대로(단계 밖의 값도 맞추지 않는다).
        final api = FakeTodoApi(
          me: 'me',
          todos: [
            todoJson(id: 'p', progress: 30),
            todoJson(id: 'm', assignees: ['me', 'u2']),
          ],
        );
        t = await api.update('p', {'assigneeIds': <String>[]});
        expect(t.progress, 30);
        // 진척률 권한은 바뀐 뒤의 담당자 목록으로 — 나를 빼면서 보내면 거절(서버와 같다).
        await expectLater(
          api.update('m', {
            'assigneeIds': ['u2'],
            'progress': 50,
          }),
          throwsA(
            isA<ApiException>().having(
              (e) => e.message,
              'message',
              '담당자만 진척률을 바꿀 수 있습니다.',
            ),
          ),
        );
        expect((await api.get('m')).assignees.map((a) => a.id), ['me', 'u2']);
      },
    );

    test('집계 — 모두 100이면 100, 모두 0이면 0, 그 밖은 평균을 1~99로', () {
      expect(aggregateTodoProgress([0, 0]), 0);
      expect(aggregateTodoProgress([100, 100]), 100);
      expect(aggregateTodoProgress([100, 0]), 50);
      expect(
        aggregateTodoProgress([25, ...List.filled(50, 0)]),
        1,
        reason: '누가 시작했으면 대기로 보이지 않는다',
      );
      expect(
        aggregateTodoProgress([...List.filled(50, 100), 75]),
        99,
        reason: '한 명이라도 남았으면 완료로 보이지 않는다',
      );
    });

    test('todoJson — 담당자별 진척률 기본은 progress, 보는 사람 기준 값을 채운다', () {
      final j = todoJson(progress: 40, assignees: ['me', 'u2'], favorite: true);
      expect([for (final a in j['assignees'] as List) a['progress']], [40, 40]);
      expect(
        [for (final a in j['assignees'] as List) a['status']],
        ['doing', 'doing'],
      );
      expect(j['progress'], 40);
      expect(j['myProgress'], 40);
      expect(j['canSetProgress'], isTrue);
      expect(j['favorite'], isTrue);
      final viewer = todoJson(creatorId: 'u2', assignees: ['u3'], progress: 75);
      expect(viewer['myProgress'], isNull);
      expect(viewer['canSetProgress'], isFalse);
      expect(viewer['myRole'], 'viewer');
    });
  });

  // ────────────────────────── 컨트롤러 ──────────────────────────
  group('TodoController — 담당자 필터·즐겨찾기·관점·달력', () {
    test('담당자 필터 — 조회에 실리고, 대화방을 바꾸거나 부여한 할 일이 아닌 탭으로 가면 비운다', () async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(id: 'c', assignees: ['u2'], createdAt: 2),
          todoJson(id: 'd', assignees: ['u3'], roomId: 'r2', createdAt: 1),
        ],
      );
      final c = TodoController(
        api: api,
        teamId: 't1',
        scope: TodoScope.assignedByMe,
      );
      await c.load();
      expect(c.items.map((t) => t.id), ['c', 'd']);
      c.setAssignee('u2');
      await pumpEventQueue();
      expect(api.lastList!['assigneeId'], 'u2');
      expect(c.items.map((t) => t.id), ['c']);
      c.setSort(TodoSort.due);
      await pumpEventQueue();
      expect(api.lastList!['sort'], TodoSort.due);
      expect(c.assigneeId, 'u2', reason: '정렬은 담당자 필터를 건드리지 않는다');
      c.setExcludeDone(true);
      await pumpEventQueue();
      expect(c.assigneeId, 'u2');
      c.setRoom('r2');
      await pumpEventQueue();
      expect(c.assigneeId, isNull, reason: '대화방을 바꾸면 비운다');
      expect(api.lastList!['assigneeId'], isNull);
      expect(c.items.map((t) => t.id), ['d']);
      c.setAssignee('u3');
      await pumpEventQueue();
      expect(c.items.map((t) => t.id), ['d']);
      c.setScope(TodoScope.team);
      await pumpEventQueue();
      expect(c.assigneeId, isNull, reason: '부여한 할 일이 아닌 탭으로 가면 비운다');
      expect(api.lastList!['assigneeId'], isNull);
      c.dispose();
    });

    test('다음 쪽도 담당자 필터를 싣는다', () async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          for (var i = 0; i < 35; i++)
            todoJson(id: 'x$i', assignees: ['u2'], createdAt: i),
        ],
      );
      final c = TodoController(
        api: api,
        teamId: 't1',
        scope: TodoScope.assignedByMe,
        assigneeId: 'u2',
      );
      await c.load();
      await c.loadMore();
      expect(c.items, hasLength(35));
      expect(api.calls.last, contains('offset=30'));
      expect(api.calls.last, contains('assignee=u2'));
      c.dispose();
    });

    test('즐겨찾기 — 바로 뒤집어 보이고, 되면 조용히 다시 받아 즐겨찾기를 앞으로', () async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(id: 'a', dueDate: '2026-10-01', createdAt: 1),
          todoJson(id: 'b', dueDate: '2026-10-02', createdAt: 2),
          todoJson(id: 'c', dueDate: '2026-10-03', createdAt: 3),
        ],
      );
      final c = TodoController(api: api, teamId: 't1', scope: TodoScope.team);
      await c.load();
      // 처음 정렬은 생성 순(최근에 만든 것 먼저).
      expect(c.items.map((t) => t.id), ['c', 'b', 'a']);
      final gate = Completer<void>();
      api.favoriteGate = gate.future;
      final pending = c.toggleFavorite(c.items.last);
      await pumpEventQueue();
      expect(c.items.last.favorite, isTrue, reason: '서버 응답 전에 먼저 보인다');
      expect(api.todos.first['favorite'], isFalse, reason: '서버는 아직');
      gate.complete();
      await pending;
      await pumpEventQueue();
      expect(api.calls, contains('setFavorite a true'));
      expect(api.callCount('list'), 2, reason: '되면 조용히 한 번 다시 받는다');
      expect(c.items.map((t) => t.id), ['a', 'c', 'b']);
      expect(c.items.first.favorite, isTrue);
      expect(c.loading, isFalse);

      // 화면이 들고 있던 낡은 객체로 눌러도 지금 목록 값 기준으로 끈다.
      final stale = c.items.first.copyWith(favorite: false);
      await c.toggleFavorite(stale);
      await pumpEventQueue();
      expect(api.calls, contains('setFavorite a false'));
      expect(c.items.map((t) => t.id), ['c', 'b', 'a']);
      expect(c.items.every((t) => !t.favorite), isTrue);
      c.dispose();
    });

    test('즐겨찾기 실패 — 되돌리고 던진다(다시 받지 않는다)', () async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(id: 'a', assignees: ['me']),
        ],
      );
      final c = TodoController(api: api, teamId: 't1');
      await c.load();
      api.failWith = '권한이 없습니다.';
      final pending = c.toggleFavorite(c.items.single);
      expect(c.items.single.favorite, isTrue);
      await expectLater(pending, throwsA(isA<ApiException>()));
      expect(c.items.single.favorite, isFalse);
      expect(api.callCount('list'), 1);
      c.dispose();
    });

    test('관점 진척률·문구(%) — 담당자 필터 > 나의 할 일(내 것) > 전체', () {
      final c = TodoController(
        api: FakeTodoApi(me: 'me'),
        teamId: 't1',
      );
      final group = Todo.fromJson(
        todoJson(
          assignees: ['me', 'u2', 'u3'],
          assigneeProgress: {'me': 100, 'u2': 50, 'u3': 0},
        ),
      );
      final personal = Todo.fromJson(todoJson(progress: 25));
      final others = Todo.fromJson(
        todoJson(creatorId: 'u2', assignees: ['u3'], progress: 75),
      );
      expect(group.progress, 50);
      // 나의 할 일 — 내 진척률(없으면 전체).
      expect(c.perspectiveProgress(group), 100);
      expect(c.perspectiveText(group), '100%');
      expect(c.perspectiveText(personal), '25%');
      expect(c.perspectiveProgress(others), 75);
      // 모든 할 일 — 전체(담당자가 여럿이어도 사람 수 대신 집계 %).
      c.scope = TodoScope.team;
      expect(c.perspectiveProgress(group), 50);
      expect(c.perspectiveText(group), '50%');
      expect(c.perspectiveText(others), '75%');
      // 부여한 할 일 — 필터가 없으면 전체, 있으면 그 사람 것.
      c.scope = TodoScope.assignedByMe;
      expect(c.perspectiveText(group), '50%');
      c.assigneeId = 'u2';
      expect(c.perspectiveProgress(group), 50);
      expect(c.perspectiveText(group), '50%');
      c.assigneeId = 'u3';
      expect(c.perspectiveText(group), '0%');
      c.assigneeId = 'me';
      expect(c.perspectiveText(group), '100%');
      c.dispose();
    });

    test('처음 정렬은 생성 순 — 첫 조회부터 sort=created, 기한 순으로 바꾸면 다시 받는다', () async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(id: 'old', dueDate: '2026-10-01', createdAt: 1),
          todoJson(id: 'new', dueDate: '2026-10-09', createdAt: 2),
          todoJson(id: 'nodue', createdAt: 3),
        ],
      );
      final c = TodoController(api: api, teamId: 't1');
      expect(c.sort, TodoSort.created);
      await c.load();
      expect(api.lastList!['sort'], TodoSort.created);
      expect(api.calls.single, contains('sort=created'));
      expect(c.items.map((t) => t.id), ['nodue', 'new', 'old']);
      c.setSort(TodoSort.created);
      await pumpEventQueue();
      expect(api.callCount('list'), 1, reason: '같은 정렬이면 다시 받지 않는다');
      c.setSort(TodoSort.due);
      await pumpEventQueue();
      expect(api.calls.last, contains('sort=due'));
      expect(c.items.map((t) => t.id), ['old', 'new', 'nodue']);
      c.dispose();
    });

    test('total — 서버가 센 전체 개수(다음 쪽 전에도), 필터를 바꾸면 비우고 다시, 지우면 하나 덜', () async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          for (var i = 0; i < 35; i++)
            todoJson(id: 'x$i', assignees: ['me'], createdAt: i),
          todoJson(id: 'r2', assignees: ['me'], roomId: 'r2', createdAt: 99),
        ],
      );
      final c = TodoController(api: api, teamId: 't1');
      expect(c.total, 0);
      await c.load();
      expect(c.items, hasLength(30));
      expect(c.total, 36, reason: '아직 안 받은 쪽까지');
      await c.loadMore();
      expect(c.items, hasLength(36));
      expect(c.total, 36);
      final gate = Completer<void>();
      api.listGate = gate.future;
      c.setRoom('r2');
      expect(c.total, 0, reason: '다시 받는 동안은 비운다');
      gate.complete();
      await pumpEventQueue();
      expect(c.total, 1);
      api.listGate = null;
      await c.remove(c.items.single);
      expect(c.items, isEmpty);
      expect(c.total, 0, reason: '다시 받기 전에도 하나 덜');
      await pumpEventQueue();
      expect(c.total, 0);
      c.dispose();
    });

    test('total — 예전 서버(응답에 total 없음)면 받은 개수', () async {
      final api = _NoTotalApi(
        todos: [
          for (var i = 0; i < 35; i++)
            todoJson(id: 'x$i', assignees: ['me'], createdAt: i),
        ],
      );
      final c = TodoController(api: api, teamId: 't1');
      await c.load();
      expect(c.total, 30);
      await c.loadMore();
      expect(c.total, 35);
      await c.remove(c.items.first);
      expect(c.total, 34);
      c.dispose();
    });

    test('달력 — 그 달 칸 범위를 같은 필터로 한 번에(기한순·500개) 받고, 필터를 바꾸면 다시', () async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(
            id: 'in1',
            assignees: ['me'],
            startDate: '2026-09-25',
            dueDate: '2026-09-28',
          ),
          todoJson(
            id: 'in2',
            assignees: ['me'],
            dueDate: '2026-11-07',
            createdAt: 2,
          ),
          todoJson(
            id: 'out',
            assignees: ['me'],
            dueDate: '2026-11-08',
            createdAt: 3,
          ),
          todoJson(id: 'nodate', assignees: ['me'], createdAt: 4),
          todoJson(
            id: 'room2',
            assignees: ['me'],
            roomId: 'r2',
            dueDate: '2026-10-10',
            progress: 100,
            createdAt: 5,
          ),
        ],
      );
      final c = TodoController(api: api, teamId: 't1');
      final pending = c.loadCalendar(DateTime(2026, 10, 17, 9));
      expect(c.calendarMonth, DateTime(2026, 10));
      expect(c.calendarLoading, isTrue);
      await pending;
      expect(c.calendarLoading, isFalse);
      expect(c.calendarLoaded, isTrue);
      expect(c.calendarError, isNull);
      expect(api.lastList!['from'], '2026-09-27');
      expect(api.lastList!['to'], '2026-11-07');
      expect(api.lastList!['limit'], todoRangeMaxLimit);
      expect(api.lastList!['sort'], TodoSort.due);
      expect(api.lastList!['scope'], TodoScope.mine);
      expect(c.calendarItems.map((t) => t.id), ['in1', 'in2', 'room2']);
      expect(c.items, isEmpty, reason: '목록과 따로 받는다');

      c.setRoom('r2');
      await pumpEventQueue();
      expect(api.lastList!['roomId'], 'r2');
      expect(api.lastList!['from'], '2026-09-27');
      expect(c.calendarItems.map((t) => t.id), ['room2']);
      expect(c.items.map((t) => t.id), ['room2']);
      c.setExcludeDone(true);
      await pumpEventQueue();
      expect(api.lastList!['includeDone'], isFalse);
      expect(c.calendarItems, isEmpty);
      // 정렬은 목록 보기에만 — 달력은 다시 받지 않는다.
      final before = api.callCount('list');
      c.setSort(TodoSort.due);
      await pumpEventQueue();
      expect(api.callCount('list'), before + 1);
      expect(api.lastList!['from'], isNull);
      expect(api.lastList!['sort'], TodoSort.due);
      c.dispose();
    });

    test('달력 — todo:changed(같은 팀)·재연결이면 조용히 다시 받고, 닫으면 받지 않는다', () async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(id: 'a', assignees: ['me'], dueDate: '2026-10-05'),
        ],
      );
      final changed = StreamController<Map<String, dynamic>>.broadcast();
      final reconnected = StreamController<void>.broadcast();
      final c = TodoController(
        api: api,
        teamId: 't1',
        changed: changed.stream,
        reconnected: reconnected.stream,
      );
      await c.load();
      await c.loadCalendar(DateTime(2026, 10));
      expect(c.calendarItems.map((t) => t.id), ['a']);

      final gate = Completer<void>();
      api.listGate = gate.future;
      api.todos.add(
        todoJson(
          id: 'b',
          assignees: ['me'],
          dueDate: '2026-10-06',
          createdAt: 2,
        ),
      );
      changed.add({'teamId': 't1', 'todoId': 'b', 'kind': 'created'});
      await pumpEventQueue();
      expect(
        api.calls.where((call) => call.contains('from=2026-09-27')),
        hasLength(2),
      );
      expect(c.calendarLoading, isFalse, reason: '조용히');
      expect(c.calendarItems.map((t) => t.id), ['a'], reason: '받는 동안 그대로');
      gate.complete();
      await pumpEventQueue();
      expect(c.calendarItems.map((t) => t.id), ['a', 'b']);
      expect(c.items.map((t) => t.id), ['a', 'b']);

      final count = api.callCount('list');
      changed.add({'teamId': 'other'});
      await pumpEventQueue();
      expect(api.callCount('list'), count, reason: '다른 팀 알림은 무시');
      reconnected.add(null);
      await pumpEventQueue();
      expect(api.callCount('list'), count + 2, reason: '재연결 — 목록과 달력');

      c.closeCalendar();
      expect(c.calendarMonth, isNull);
      expect(c.calendarItems, isEmpty);
      expect(c.calendarLoaded, isFalse);
      changed.add({'teamId': 't1'});
      await pumpEventQueue();
      expect(api.callCount('list'), count + 3, reason: '닫으면 목록만');
      c.dispose();
      await changed.close();
      await reconnected.close();
    });

    test('달력 — 달을 빨리 넘기면 늦게 온 이전 달 응답은 버린다', () async {
      final api = _ManualListApi(
        todos: [
          todoJson(id: 'oct', assignees: ['me'], dueDate: '2026-10-15'),
          todoJson(
            id: 'dec',
            assignees: ['me'],
            dueDate: '2026-12-15',
            createdAt: 2,
          ),
        ],
      );
      final c = TodoController(api: api, teamId: 't1');
      final oct = c.loadCalendar(DateTime(2026, 10));
      final dec = c.loadCalendar(DateTime(2026, 12));
      expect(c.calendarMonth, DateTime(2026, 12));
      api.release(1);
      await dec;
      expect(c.calendarItems.map((t) => t.id), ['dec']);
      api.release(0);
      await oct;
      expect(c.calendarItems.map((t) => t.id), ['dec']);
      expect(c.calendarMonth, DateTime(2026, 12));
      c.dispose();
    });

    test('달력 — 처음 받기가 실패하면 calendarError', () async {
      final c = TodoController(api: _FailingListApi(), teamId: 't1');
      await c.loadCalendar(DateTime(2026, 10));
      expect(c.calendarLoaded, isFalse);
      expect(c.calendarLoading, isFalse);
      expect(c.calendarError, '서버 오류');
      c.dispose();
    });

    test('달력 항목에도 진척률·즐겨찾기·삭제가 바로 반영된다', () async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [
          todoJson(id: 'a', assignees: ['me'], dueDate: '2026-10-05'),
        ],
      );
      final c = TodoController(api: api, teamId: 't1');
      await c.loadCalendar(DateTime(2026, 10));
      await c.setProgress(c.calendarItems.single, 50);
      expect(c.calendarItems.single.myProgress, 50);
      final favorite = c.toggleFavorite(c.calendarItems.single);
      expect(c.calendarItems.single.favorite, isTrue);
      await favorite;
      await pumpEventQueue();
      expect(c.calendarItems.single.favorite, isTrue);
      await c.remove(c.calendarItems.single);
      expect(c.calendarItems, isEmpty);
      c.dispose();
    });
  });

  // ────────────────────────── 공용 위젯 ──────────────────────────
  group('공용 위젯(todo_widgets.dart)', () {
    Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: child)),
      ),
    );

    testWidgets('진척률 색(잔디) — 대기 주황 · 진행 초록 · 완료 회색, 어두운 테마는 밝은 같은 계열', (
      tester,
    ) async {
      final colors = <Brightness, List<Color>>{};
      for (final brightness in Brightness.values) {
        // 앱을 새로 띄워 테마가 바뀌는 애니메이션 중간 값을 읽지 않게.
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Builder(
              builder: (context) {
                colors[brightness] = [
                  for (final p in [0, 25, 50, 75, 99, 100])
                    todoProgressColor(context, p),
                ];
                return const SizedBox();
              },
            ),
          ),
        );
      }
      final light = ThemeData();
      final dark = ThemeData(brightness: Brightness.dark);
      expect(colors[Brightness.light], [
        const Color(0xFFF08C00),
        const Color(0xFF02C472),
        const Color(0xFF02C472),
        const Color(0xFF02C472),
        const Color(0xFF02C472),
        light.hintColor,
      ]);
      expect(colors[Brightness.dark], [
        const Color(0xFFFFA94D),
        const Color(0xFF4ADE9C),
        const Color(0xFF4ADE9C),
        const Color(0xFF4ADE9C),
        const Color(0xFF4ADE9C),
        dark.hintColor,
      ]);
      // 어두운 바탕에서도 읽히는지 — 바탕(surface)과의 명암 대비 3:1 이상(큰 글자 기준).
      double contrast(Color a, Color b) {
        final la = a.computeLuminance(), lb = b.computeLuminance();
        return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
      }

      for (final c in colors[Brightness.dark]!.take(2)) {
        expect(
          contrast(c, dark.colorScheme.surface),
          greaterThan(3),
          reason: '$c',
        );
      }
    });

    testWidgets(
      'TodoProgressSelect — 테두리 상자 `대기(0%) ▾`(진척률 색), 메뉴 5개(지금 값에 체크), 같은 값은 무시',
      (tester) async {
        final picked = <int>[];
        await pump(
          tester,
          TodoProgressSelect(progress: 0, onSelected: picked.add),
        );
        final label = tester.widget<Text>(find.text('대기(0%)'));
        expect(label.style?.color, const Color(0xFFF08C00));
        expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
        // 테두리 있는 상자 — 가장 긴 문구도 들어가는 최소 폭.
        expect(
          find.descendant(
            of: find.byType(TodoProgressSelect),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is DecoratedBox &&
                  w.decoration is BoxDecoration &&
                  (w.decoration as BoxDecoration).border != null,
            ),
          ),
          findsOneWidget,
        );
        final size = tester.getSize(find.byType(TodoProgressSelect));
        expect(size.width, greaterThanOrEqualTo(116));
        expect(size.height, greaterThanOrEqualTo(34));

        await tester.tap(find.byType(TodoProgressSelect));
        await tester.pumpAndSettle();
        const labels = {
          0: '대기(0%)',
          25: '진행(25%)',
          50: '진행(50%)',
          75: '진행(75%)',
          100: '완료(100%)',
        };
        double? lastTop;
        for (final e in labels.entries) {
          final option = find.byKey(ValueKey('todo-progress-option-${e.key}'));
          expect(option, findsOneWidget);
          expect(
            find.descendant(of: option, matching: find.text(e.value)),
            findsOneWidget,
          );
          expect(
            find.descendant(of: option, matching: find.byIcon(Icons.check)),
            e.key == 0 ? findsOneWidget : findsNothing,
          );
          final top = tester.getTopLeft(option).dy;
          if (lastTop != null) {
            expect(top, greaterThan(lastTop), reason: '위에서부터 순서대로');
          }
          lastTop = top;
        }
        // 지금 값을 다시 고르면 아무것도 하지 않는다.
        await tester.tap(find.byKey(const ValueKey('todo-progress-option-0')));
        await tester.pumpAndSettle();
        expect(picked, isEmpty);
        await tester.tap(find.byType(TodoProgressSelect));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('todo-progress-option-50')));
        await tester.pumpAndSettle();
        expect(picked, [50]);
        expect(
          find.byKey(const ValueKey('todo-progress-option-0')),
          findsNothing,
          reason: '고르면 닫힌다',
        );
      },
    );

    testWidgets(
      'TodoProgressSelect — onSelected가 없으면 색 글자만(상자·▾·메뉴 없음), 글자는 상자 안 글자와 같은 자리',
      (tester) async {
        await pump(
          tester,
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TodoProgressSelect(
                key: const ValueKey('editable'),
                progress: 75,
                onSelected: (_) {},
              ),
              const TodoProgressSelect(
                key: ValueKey('readonly'),
                progress: 100,
              ),
            ],
          ),
        );
        final readonly = find.byKey(const ValueKey('readonly'));
        expect(
          find.descendant(of: readonly, matching: find.text('완료(100%)')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: readonly,
            matching: find.byType(PopupMenuButton<int>),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: readonly,
            matching: find.byIcon(Icons.keyboard_arrow_down),
          ),
          findsNothing,
        );
        expect(
          find.descendant(of: readonly, matching: find.byType(DecoratedBox)),
          findsNothing,
        );
        final theme = Theme.of(tester.element(readonly));
        expect(
          tester.widget<Text>(find.text('완료(100%)')).style?.color,
          theme.hintColor,
        );
        expect(
          tester.widget<Text>(find.text('진행(75%)')).style?.color,
          const Color(0xFF02C472),
        );
        // 내 줄(상자)과 다른 사람 줄(글자)의 글자 왼쪽 끝이 나란하다.
        expect(
          tester.getTopLeft(find.text('완료(100%)')).dx,
          tester.getTopLeft(find.text('진행(75%)')).dx,
        );
        expect(
          tester.getSize(readonly).width,
          tester.getSize(find.byKey(const ValueKey('editable'))).width,
        );
        await tester.tap(find.text('완료(100%)'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('todo-progress-option-0')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'TodoPageHeader — `← 할 일 … actions ✕`, ←·✕ 손잡이, 높이는 패널 머리와 같다',
      (tester) async {
        var back = 0, close = 0;
        await pump(
          tester,
          SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TodoPageHeader(
                  key: const ValueKey('page-header'),
                  onBack: () => back++,
                  onClose: () => close++,
                  actions: const [Icon(Icons.star, key: ValueKey('action'))],
                ),
                const SidePanelHeader(
                  key: ValueKey('panel-header'),
                  title: '할 일',
                ),
              ],
            ),
          ),
        );
        final header = find.byKey(const ValueKey('page-header'));
        expect(
          find.descendant(of: header, matching: find.text('할 일')),
          findsOneWidget,
        );
        final backButton = find.byKey(const ValueKey('todo-page-back'));
        final closeButton = find.byKey(const ValueKey('todo-page-close'));
        expect(
          find.descendant(
            of: backButton,
            matching: find.byIcon(Icons.arrow_back),
          ),
          findsOneWidget,
        );
        // ← 제목 … actions ✕ 순서.
        final x = [
          tester.getCenter(backButton).dx,
          tester
              .getCenter(
                find.descendant(of: header, matching: find.text('할 일')),
              )
              .dx,
          tester.getCenter(find.byKey(const ValueKey('action'))).dx,
          tester.getCenter(closeButton).dx,
        ];
        expect([...x]..sort(), x);
        expect(
          tester.getSize(header).height,
          tester.getSize(find.byKey(const ValueKey('panel-header'))).height,
        );
        final titleStyle = tester
            .widget<Text>(
              find.descendant(of: header, matching: find.text('할 일')),
            )
            .style;
        expect(
          titleStyle,
          Theme.of(tester.element(header)).textTheme.titleLarge,
        );
        await tester.tap(backButton);
        await tester.pump();
        await tester.tap(closeButton);
        await tester.pump();
        expect((back, close), (1, 1));

        // 손잡이가 없으면 그 단추는 빠진다.
        await pump(tester, const TodoPageHeader(title: '할 일 일정'));
        expect(find.text('할 일 일정'), findsOneWidget);
        expect(find.byKey(const ValueKey('todo-page-back')), findsNothing);
        expect(find.byKey(const ValueKey('todo-page-close')), findsNothing);
      },
    );
  });

  // ────────────────────────── 대화방 필터 단추 ──────────────────────────
  testWidgets(
    'RoomFilterButton — 전체일 때 글자는 allLabel(기본 `참여 대화방`), 방을 고르면 방 이름',
    (tester) async {
      final session = _roomSession();
      Widget button(String? roomId, {String? allLabel}) => allLabel == null
          ? RoomFilterButton(
              session: session,
              selectedRoomId: roomId,
              onSelected: (_) {},
            )
          : RoomFilterButton(
              session: session,
              selectedRoomId: roomId,
              allLabel: allLabel,
              onSelected: (_) {},
            );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                button(null),
                button(null, allLabel: '참여한 대화방'),
                button('r1', allLabel: '참여한 대화방'),
                button('없는 방', allLabel: '참여한 대화방'),
              ],
            ),
          ),
        ),
      );
      expect(find.text('참여 대화방'), findsOneWidget, reason: '다른 패널은 그대로');
      expect(find.text('참여한 대화방'), findsNWidgets(2), reason: '없는 방도 전체로');
      expect(find.text('영업 토픽'), findsOneWidget);
      // 펼침 패널의 첫 줄은 그대로 `전체`.
      await tester.tap(find.text('참여한 대화방').first);
      await tester.pumpAndSettle();
      expect(find.text('전체'), findsOneWidget);
    },
  );

  // ────────────────────────── 패널 안 화면(TodoViewMode) ──────────────────────────
  group('상세·생성의 모양 — 패널 안 화면(panel)과 예전 모양(dialog/page)', () {
    test('mode를 안 주면 asDialog로 — true는 대화상자, false는 전체 화면, mode가 있으면 그것', () {
      final session = _roomSession();
      final todo = Todo.fromJson(todoJson());
      expect(
        TodoDetail(session: session, todo: todo).mode,
        TodoViewMode.dialog,
      );
      expect(
        TodoDetail(session: session, todo: todo, asDialog: false).mode,
        TodoViewMode.page,
      );
      final panel = TodoDetail(
        session: session,
        todo: todo,
        mode: TodoViewMode.panel,
      );
      expect(panel.mode, TodoViewMode.panel);
      expect(panel.asDialog, isFalse);
      expect(TodoEditor(session: session).mode, TodoViewMode.dialog);
      expect(TodoEditor(session: session).asDialog, isTrue);
      expect(
        TodoEditor(session: session, asDialog: false).mode,
        TodoViewMode.page,
      );
      expect(
        TodoEditor(
          session: session,
          asDialog: true,
          mode: TodoViewMode.panel,
        ).mode,
        TodoViewMode.panel,
      );
    });

    testWidgets('mode가 없으면 예전처럼 — 넓은 창은 대화상자, 좁은 창은 전체 화면(상세·생성 모두)', (
      tester,
    ) async {
      final session = _roomSession();
      final api = FakeTodoApi(
        me: 'me',
        todos: [todoJson(id: 'a')],
      );
      for (final (width, mode) in const [
        (900.0, TodoViewMode.dialog),
        (390.0, TodoViewMode.page),
      ]) {
        await _pumpOpener(
          tester,
          width,
          (context) => showTodoDetail(
            context,
            session: session,
            todo: Todo.fromJson(api.todos.single),
            api: api,
            changed: const Stream.empty(),
          ),
        );
        expect(tester.widget<TodoDetail>(find.byType(TodoDetail)).mode, mode);
        expect(
          find.byType(Dialog),
          mode == TodoViewMode.dialog ? findsOneWidget : findsNothing,
        );
        expect(find.byType(TodoPageHeader), findsNothing);

        await _pumpOpener(
          tester,
          width,
          (context) => showTodoEditor(context, session: session, api: api),
        );
        expect(tester.widget<TodoEditor>(find.byType(TodoEditor)).mode, mode);
        expect(
          find.byType(Dialog),
          mode == TodoViewMode.dialog ? findsOneWidget : findsNothing,
        );
        expect(find.byType(TodoPageHeader), findsNothing);
      }
    });

    testWidgets(
      '상세 panel — 가장 가까운(패널의) Navigator에 `← 할 일 … ✕` 화면으로, ←는 상세만 닫고 결과를, ✕는 패널 닫기',
      (tester) async {
        final session = _roomSession();
        final api = FakeTodoApi(
          me: 'me',
          todos: [todoJson(id: 'a', title: '패널 할 일')],
        );
        bool? result;
        var closed = 0;
        await _pumpPanelHost(tester, (context) async {
          result = await showTodoDetail(
            context,
            session: session,
            todo: Todo.fromJson(api.todos.single),
            api: api,
            changed: const Stream.empty(),
            mode: TodoViewMode.panel,
            onClosePanel: () => closed++,
          );
        });
        final detail = find.byType(TodoDetail);
        expect(tester.widget<TodoDetail>(detail).mode, TodoViewMode.panel);
        expect(find.byType(Dialog), findsNothing);
        expect(
          find.descendant(of: _key('panel-nav'), matching: detail),
          findsOneWidget,
        );
        expect(tester.getRect(detail), tester.getRect(_key('panel-host')));
        final header = find.descendant(
          of: detail,
          matching: find.byType(TodoPageHeader),
        );
        expect(header, findsOneWidget);
        expect(
          find.descendant(of: header, matching: find.text('할 일')),
          findsOneWidget,
        );
        expect(find.text('패널 할 일'), findsOneWidget);
        expect(_key('todo-detail-star'), findsOneWidget);
        expect(_key('todo-detail-menu'), findsOneWidget);
        expect(_key('panel-opener'), findsNothing, reason: '첫 화면을 덮는다');

        await tester.tap(_key('todo-page-close'));
        await tester.pump();
        expect(closed, 1, reason: '패널 닫기는 패널(onClose)이 한다');

        await tester.tap(_key('todo-page-back'));
        await tester.pumpAndSettle();
        expect(detail, findsNothing);
        expect(result, isFalse);
        expect(_key('panel-opener'), findsOneWidget, reason: '패널 첫 화면으로');

        // 즐겨찾기를 바꾸고 닫으면 true(목록이 다시 받는다).
        await tester.tap(_key('panel-opener'));
        await tester.pumpAndSettle();
        await tester.tap(_key('todo-detail-star'));
        await tester.pumpAndSettle();
        expect(api.calls, contains('setFavorite a true'));
        await tester.tap(_key('todo-page-back'));
        await tester.pumpAndSettle();
        expect(result, isTrue);
      },
    );

    testWidgets('상세 panel — ✕ 손잡이가 없으면 ✕가 없고, 지워졌다는 알림이 오면 위의 ⋯ 메뉴와 함께 닫힌다', (
      tester,
    ) async {
      final session = _roomSession();
      final api = FakeTodoApi(
        me: 'me',
        todos: [todoJson(id: 'a')],
      );
      final changed = StreamController<Map<String, dynamic>>.broadcast();
      addTearDown(changed.close);
      bool? result;
      await _pumpPanelHost(tester, (context) async {
        result = await showTodoDetail(
          context,
          session: session,
          todo: Todo.fromJson(api.todos.single),
          api: api,
          changed: changed.stream,
          mode: TodoViewMode.panel,
        );
      });
      expect(_key('todo-page-close'), findsNothing);
      expect(_key('todo-page-back'), findsOneWidget);
      await tester.tap(_key('todo-detail-menu'));
      await tester.pumpAndSettle();
      expect(_key('todo-menu-edit'), findsOneWidget);
      changed.add({'teamId': 't1', 'todoId': 'a', 'kind': 'deleted'});
      await tester.pumpAndSettle();
      expect(_key('todo-menu-edit'), findsNothing);
      expect(find.byType(TodoDetail), findsNothing);
      expect(result, isTrue);
      expect(_key('panel-opener'), findsOneWidget);
      // 알림 토스트가 사라질 때까지.
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('상세 panel에서 수정 — 편집기도 패널 안에(같은 ✕), 저장하면 상세로 돌아와 바뀐 제목을 그린다', (
      tester,
    ) async {
      final session = _roomSession();
      final api = FakeTodoApi(
        me: 'me',
        todos: [todoJson(id: 'a', title: '처음 제목')],
      );
      bool? result;
      var closed = 0;
      await _pumpPanelHost(tester, (context) async {
        result = await showTodoDetail(
          context,
          session: session,
          todo: Todo.fromJson(api.todos.single),
          api: api,
          changed: const Stream.empty(),
          mode: TodoViewMode.panel,
          onClosePanel: () => closed++,
        );
      });
      await tester.tap(_key('todo-detail-menu'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-menu-edit'));
      await tester.pumpAndSettle();
      final editor = find.byType(TodoEditor);
      expect(tester.widget<TodoEditor>(editor).mode, TodoViewMode.panel);
      expect(tester.widget<TodoEditor>(editor).editing?.id, 'a');
      expect(find.byType(Dialog), findsNothing);
      expect(
        find.descendant(of: _key('panel-nav'), matching: editor),
        findsOneWidget,
      );
      expect(tester.getRect(editor), tester.getRect(_key('panel-host')));
      // 편집기의 ✕도 패널 닫기(바뀐 게 없으면 묻지 않는다).
      await tester.tap(_key('todo-page-close'));
      await tester.pumpAndSettle();
      expect(closed, 1);
      expect(find.text('작성 취소'), findsNothing);

      await tester.enterText(_key('todo-title-field'), '고친 제목');
      await tester.pump();
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(api.lastUpdate, {'title': '고친 제목'});
      expect(editor, findsNothing);
      expect(find.byType(TodoDetail), findsOneWidget);
      expect(tester.widget<Text>(_key('todo-detail-title')).data, '고친 제목');
      await tester.tap(_key('todo-page-back'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets(
      '생성 panel — `← 할 일 … ✕` + 입력 칸 + [취소][저장], ←·✕는 쓰던 내용이 있으면 먼저 묻고, 저장하면 할 일을 돌려준다',
      (tester) async {
        final session = _roomSession();
        final api = FakeTodoApi(me: 'me');
        final results = <Todo?>[];
        var closed = 0;
        await _pumpPanelHost(tester, (context) async {
          results.add(
            await showTodoEditor(
              context,
              session: session,
              room: session.rooms.single,
              api: api,
              mode: TodoViewMode.panel,
              onClosePanel: () => closed++,
            ),
          );
        });
        final editor = find.byType(TodoEditor);
        expect(tester.widget<TodoEditor>(editor).mode, TodoViewMode.panel);
        expect(find.byType(Dialog), findsNothing);
        expect(
          find.descendant(of: _key('panel-nav'), matching: editor),
          findsOneWidget,
        );
        final header = find.descendant(
          of: editor,
          matching: find.byType(TodoPageHeader),
        );
        expect(
          find.descendant(of: header, matching: find.text('할 일')),
          findsOneWidget,
        );
        expect(find.widgetWithText(TextButton, '취소'), findsOneWidget);
        expect(_key('todo-submit'), findsOneWidget);
        expect(_key('todo-title-field'), findsOneWidget);

        // 바뀐 게 없으면 ←는 묻지 않고 닫는다.
        await tester.tap(_key('todo-page-back'));
        await tester.pumpAndSettle();
        expect(editor, findsNothing);
        expect(results, [null]);

        await tester.tap(_key('panel-opener'));
        await tester.pumpAndSettle();
        await tester.enterText(_key('todo-title-field'), '패널에서 만든 할 일');
        await tester.pump();
        // ✕ — 먼저 묻고, [계속 쓰기]면 그대로.
        await tester.tap(_key('todo-page-close'));
        await tester.pumpAndSettle();
        expect(find.text('작성 취소'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, '계속 쓰기'));
        await tester.pumpAndSettle();
        expect(closed, 0);
        await tester.tap(_key('todo-page-close'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, '닫기'));
        await tester.pumpAndSettle();
        expect(closed, 1);
        // ←도 먼저 묻는다.
        await tester.tap(_key('todo-page-back'));
        await tester.pumpAndSettle();
        expect(find.text('작성 취소'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, '계속 쓰기'));
        await tester.pumpAndSettle();
        expect(editor, findsOneWidget);

        await tester.tap(_key('todo-submit'));
        await tester.pumpAndSettle();
        expect(api.lastCreateRoomId, 'r1');
        expect(api.lastCreate?['title'], '패널에서 만든 할 일');
        expect(results.last?.title, '패널에서 만든 할 일');
        expect(editor, findsNothing);
        expect(_key('panel-opener'), findsOneWidget);
      },
    );
  });

  // ────────────────────────── 만들 수 있는 방 ──────────────────────────
  test('canCreateTodoIn — 보드 뷰 토픽·비밀 대화는 빠진다(챗 뷰 토픽·채팅만)', () {
    Room room(
      String id, {
      String type = 'topic',
      String? viewMode,
      bool secret = false,
    }) => Room.fromJson({
      'id': id,
      'teamId': 't1',
      'type': type,
      'name': type == 'topic' ? '토픽 $id' : null,
      'members': [_member('me', '나'), _member('u2', '김철수')],
      'createdAt': 1000,
      'viewMode': ?viewMode,
      'isSecret': secret,
    });
    final session = _session();
    expect(session.canCreateTodoIn(room('chat', viewMode: 'chat')), isTrue);
    expect(session.canCreateTodoIn(room('board', viewMode: 'board')), isFalse);
    expect(session.canCreateTodoIn(room('group', type: 'group')), isTrue);
    expect(session.canCreateTodoIn(room('dm', type: 'dm')), isTrue);
    expect(
      session.canCreateTodoIn(room('sec', type: 'dm', secret: true)),
      isFalse,
    );
  });
}
