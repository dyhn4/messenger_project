import 'dart:convert';

import 'package:client/models/project.dart';
import 'package:client/models/task_extras.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/project/task_detail_panel.dart';
import 'package:client/screens/project/task_extras_sections.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 업무 기능 보강 — 반복 업무·선후행·소요 시간(task_extras_sections.dart, 서버 taskExtras.js).

const _json = {'content-type': 'application/json'};

void main() {
  final now = DateTime.now().millisecondsSinceEpoch;
  late List<({String method, String path, Map<String, dynamic>? body})> calls;
  Map<String, dynamic>? timer;
  var predecessors = <Map<String, dynamic>>[];

  Map<String, dynamic> link(
    String id,
    String title, {
    String status = 'doing',
  }) => {
    'id': id,
    'key': 'MKT-$id',
    'title': title,
    'status': status,
    'statusName': status == 'done' ? '완료' : '진행',
    'statusColor': '#F59E0B',
  };

  Map<String, dynamic> task(String id, String title) => {
    'id': id,
    'projectId': 'p1',
    'key': 'MKT-$id',
    'title': title,
    'status': 'doing',
    'statusId': 's2',
    'statusName': '진행',
    'priority': 'normal',
    'createdAt': now,
    'recurring': true,
    'recurrence': {'freq': 'monthly', 'interval': 1},
    'estimateMinutes': 120,
    'spentMinutes': 90,
    'openPredecessorCount': predecessors
        .where((p) => p['status'] != 'done')
        .length,
    'predecessors': predecessors,
    'successors': [link('1009', '배포')],
    'timeEntries': [
      {
        'id': 'e1',
        'taskId': id,
        'userId': 'u1',
        'userName': 'Riley',
        'minutes': 60,
        'workDate': '2026-10-05',
        'note': '시안',
      },
      {
        'id': 'e2',
        'taskId': id,
        'userId': 'u2',
        'userName': 'Mina',
        'minutes': 30,
        'workDate': '2026-10-04',
      },
    ],
    'comments': <Object>[],
    'checklist': <Object>[],
    'subtasks': <Object>[],
  };

  Session buildSession({String myRole = 'member'}) {
    calls = [];
    timer = null;
    predecessors = [link('1002', '설계')];
    final s = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    http.Response ok(Object body, [int status = 200]) =>
        http.Response(jsonEncode(body), status, headers: _json);
    s.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: MockClient((request) async {
        final path = request.url.path;
        final body = request.body.isEmpty
            ? null
            : jsonDecode(request.body) as Map<String, dynamic>;
        if (request.method != 'GET') {
          calls.add((method: request.method, path: path, body: body));
        }
        switch ((request.method, path)) {
          case ('GET', '/api/tasks/timer'):
            return ok({'timer': timer});
          case ('POST', '/api/tasks/1001/timer/start'):
            timer = {
              'taskId': '1001',
              'key': 'MKT-1001',
              'title': '배너',
              'projectId': 'p1',
              'startedAt': now - 65000,
            };
            return ok({'timer': timer, 'stopped': null});
          case ('POST', '/api/tasks/timer/stop'):
            timer = null;
            return ok({
              'entry': {
                'id': 'e9',
                'taskId': '1001',
                'userId': 'u1',
                'minutes': 25,
                'workDate': '2026-10-05',
              },
            });
          case ('POST', '/api/tasks/1001/dependencies'):
            predecessors = [...predecessors, link('1004', '문구 검수')];
            return ok({'predecessors': predecessors, 'successors': <Object>[]});
          case ('DELETE', '/api/tasks/1001/dependencies/1002'):
            predecessors = [];
            return ok({'predecessors': <Object>[], 'successors': <Object>[]});
          case ('POST', '/api/tasks/1001/time-entries'):
            return ok({
              'id': 'e3',
              'taskId': '1001',
              'userId': 'u1',
              'minutes': body?['minutes'],
              'workDate': body?['workDate'],
            }, 201);
          case ('PATCH', '/api/tasks/1001'):
            return ok(task('1001', '배너'));
          case ('GET', '/api/tasks/1001'):
            return ok(task('1001', '배너'));
          case ('GET', '/api/projects/p1'):
            return ok({
              'id': 'p1',
              'teamId': 't1',
              'name': '런칭',
              'identifier': 'MKT',
              'color': '#5B8DEF',
              'myRole': myRole,
              'createdAt': now,
              'members': [
                {'id': 'u1', 'username': 'riley', 'name': 'Riley'},
                {'id': 'u2', 'username': 'mina', 'name': 'Mina'},
              ],
            });
          case ('GET', '/api/projects/p1/tasks'):
            return ok([
              task('1001', '배너'),
              {...task('1002', '설계'), 'recurring': false},
              {...task('1004', '문구 검수'), 'recurring': false},
            ]);
          case ('GET', '/api/projects/p1/time-report'):
            return ok({
              'from': '2026-10-01',
              'to': '2026-10-18',
              'totalMinutes': 150,
              'byMember': [
                {'userId': 'u1', 'name': 'Riley', 'minutes': 120},
                {'userId': 'u2', 'name': 'Mina', 'minutes': 30},
              ],
              'byTask': [
                {
                  'taskId': '1001',
                  'key': 'MKT-1001',
                  'title': '배너',
                  'minutes': 150,
                  'estimateMinutes': 120,
                },
              ],
            });
        }
        return ok(<Object>[]);
      }),
    );
    s.userId = 'u1';
    s.currentTeam = Team(id: 't1', name: '팀', createdAt: DateTime.now());
    return s;
  }

  Future<Session> pumpPanel(
    WidgetTester tester, {
    String myRole = 'member',
  }) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final session = buildSession(myRole: myRole);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskDetailPanel(
            session: session,
            taskId: '1001',
            expanded: false,
            onToggleExpand: () {},
            onClose: () {},
            onOpenTask: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return session;
  }

  Future<void> tapVisible(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }

  test('모델 — 반복 규칙 문구·전송 모양, 업무의 보강 값, 시간 문구', () {
    const weekly = TaskRecurrence(freq: 'weekly', byWeekday: [1, 3]);
    expect(weekly.label, '매주 월·수');
    expect(weekly.toJson(), {
      'freq': 'weekly',
      'interval': 1,
      'byWeekday': [1, 3],
    });
    expect(
      const TaskRecurrence(
        freq: 'monthly',
        interval: 2,
        until: '2026-12-31',
      ).label,
      '2개월마다 (~2026-12-31)',
    );
    // 매주가 아니면 요일은 보내지 않는다.
    expect(
      const TaskRecurrence(
        freq: 'daily',
        byWeekday: [1],
      ).toJson().containsKey('byWeekday'),
      isFalse,
    );
    expect(TaskRecurrence.fromJson(null), isNull);
    predecessors = [link('1002', '설계')];
    final t = Task.fromJson({
      ...task('1001', '배너'),
      'nextRecurrence': {'id': 'x', 'key': 'MKT-1010'},
    });
    expect(t.recurrence?.label, '매월');
    expect(t.spentMinutes, 90);
    expect(t.openPredecessorCount, 1);
    expect(t.predecessors.single.key, 'MKT-1002');
    expect(t.timeEntries.length, 2);
    expect(t.nextRecurrenceKey, 'MKT-1010');
    // 예전 서버(칸 없음).
    final old = Task.fromJson({
      'id': 'a',
      'projectId': 'p',
      'title': 't',
      'status': 'todo',
      'priority': 'normal',
      'createdAt': now,
    });
    expect(old.recurring, isFalse);
    expect(old.predecessors, isEmpty);
    expect(formatMinutes(150), '2시간 30분');
    expect(formatMinutes(45), '45분');
    expect(formatElapsed(const Duration(minutes: 1, seconds: 5)), '01:05');
    expect(
      formatElapsed(const Duration(hours: 1, minutes: 2, seconds: 3)),
      '1:02:03',
    );
  });

  testWidgets('반복 — 지금 규칙을 보이고, 매주 월·수로 바꿔 저장한다', (tester) async {
    await pumpPanel(tester);
    expect(find.byKey(const ValueKey('task-recurrence-label')), findsOneWidget);
    expect(find.text('매월'), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('task-recurrence')));
    await tester.tap(find.text('매주'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recurrence-day-1')));
    await tester.tap(find.byKey(const ValueKey('recurrence-day-3')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recurrence-preview')), findsOneWidget);
    expect(find.text('매주 월·수'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recurrence-save')));
    await tester.pumpAndSettle();
    final patch = calls.lastWhere((c) => c.method == 'PATCH');
    expect(patch.body, {
      'recurrence': {
        'freq': 'weekly',
        'interval': 1,
        'byWeekday': [1, 3],
      },
    });

    // "반복 안 함"은 null로 끈다.
    await tapVisible(tester, find.byKey(const ValueKey('task-recurrence')));
    await tester.tap(find.text('반복 안 함').last);
    await tester.pumpAndSettle();
    expect(calls.lastWhere((c) => c.method == 'PATCH').body, {
      'recurrence': null,
    });
    await finish(tester);
  });

  testWidgets('선후행 — 안 끝난 선행 안내, 고르기 창으로 더하고 ×로 뺀다, 후행도 보인다', (tester) async {
    await pumpPanel(tester);
    expect(find.byKey(const ValueKey('task-blocked-note')), findsOneWidget);
    expect(find.text('선행 업무 1개가 아직 끝나지 않았습니다.'), findsOneWidget);
    expect(find.byKey(const ValueKey('task-link-1002')), findsOneWidget);
    expect(find.byKey(const ValueKey('task-link-1009')), findsOneWidget);

    await tapVisible(
      tester,
      find.byKey(const ValueKey('task-add-predecessor')),
    );
    // 자기 자신과 이미 선행인 업무는 고를 수 없다.
    expect(find.byKey(const ValueKey('task-pick-1001')), findsNothing);
    expect(find.byKey(const ValueKey('task-pick-1002')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('task-picker-search')),
      '문구',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-pick-1004')));
    await tester.pumpAndSettle();
    expect(
      calls.singleWhere((c) => c.path == '/api/tasks/1001/dependencies').body,
      {'taskId': '1004'},
    );
    expect(find.byKey(const ValueKey('task-link-1004')), findsOneWidget);

    await tapVisible(
      tester,
      find.descendant(
        of: find.byKey(const ValueKey('task-link-1002')),
        matching: find.byTooltip('선행 업무 해제'),
      ),
    );
    expect(
      calls.any(
        (c) =>
            c.method == 'DELETE' &&
            c.path == '/api/tasks/1001/dependencies/1002',
      ),
      isTrue,
    );
    await finish(tester);
  });

  testWidgets('소요 시간 — 합·예상, 타이머 켜고 끄기, 시간 기록, 내 기록만 지우기', (tester) async {
    await pumpPanel(tester);
    expect(find.text('기록 1시간 30분'), findsOneWidget);
    expect(find.text('예상 2시간'), findsOneWidget);
    // 담당자가 아니면 남의 기록(e2)은 지울 수 없다.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('time-entry-e1')),
        matching: find.byTooltip('기록 지우기'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('time-entry-e2')),
        matching: find.byTooltip('기록 지우기'),
      ),
      findsNothing,
    );

    await tapVisible(tester, find.byKey(const ValueKey('task-timer-start')));
    expect(calls.any((c) => c.path == '/api/tasks/1001/timer/start'), isTrue);
    expect(find.byKey(const ValueKey('task-timer-stop')), findsOneWidget);
    // 경과는 실제 시계로 센다(켠 지 1분 남짓 — 테스트의 가짜 시간과 무관하다).
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('task-timer-stop')),
        matching: find.textContaining(RegExp(r'^01:\d\d$')),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('task-timer-stop')));
    await tester.pumpAndSettle();
    expect(calls.any((c) => c.path == '/api/tasks/timer/stop'), isTrue);
    expect(find.text('25분을 기록했습니다.'), findsOneWidget);
    expect(find.byKey(const ValueKey('task-timer-start')), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    await tapVisible(tester, find.byKey(const ValueKey('task-add-time')));
    await tester.enterText(find.byKey(const ValueKey('time-entry-hours')), '1');
    await tester.enterText(
      find.byKey(const ValueKey('time-entry-minutes')),
      '30',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('time-entry-save')));
    await tester.pumpAndSettle();
    final added = calls.singleWhere(
      (c) => c.path == '/api/tasks/1001/time-entries',
    );
    expect(added.body?['minutes'], 90);
    expect(added.body?['workDate'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    await finish(tester);
  });

  testWidgets('예상 시간 — 눌러서 고치고 지운다', (tester) async {
    await pumpPanel(tester);
    await tapVisible(tester, find.byKey(const ValueKey('task-time-estimate')));
    await tester.enterText(find.byKey(const ValueKey('estimate-hours')), '3');
    await tester.enterText(find.byKey(const ValueKey('estimate-minutes')), '0');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('estimate-save')));
    await tester.pumpAndSettle();
    expect(calls.lastWhere((c) => c.method == 'PATCH').body, {
      'estimateMinutes': 180,
    });
    await tapVisible(tester, find.byKey(const ValueKey('task-time-estimate')));
    await tester.tap(find.text('지우기'));
    await tester.pumpAndSettle();
    expect(calls.lastWhere((c) => c.method == 'PATCH').body, {
      'estimateMinutes': null,
    });
    await finish(tester);
  });

  testWidgets('프로젝트 담당자는 남의 시간 기록도 지울 수 있다', (tester) async {
    await pumpPanel(tester, myRole: 'owner');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('time-entry-e2')),
        matching: find.byTooltip('기록 지우기'),
      ),
      findsOneWidget,
    );
    await finish(tester);
  });

  testWidgets('소요 시간 보고 — 합계·사람별·업무별(예상 넘으면 표시)', (tester) async {
    final session = buildSession();
    final project = Project.fromJson({
      'id': 'p1',
      'teamId': 't1',
      'name': '런칭',
      'identifier': 'MKT',
      'color': '#5B8DEF',
      'myRole': 'member',
      'createdAt': now,
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showProjectTimeReportDialog(context, session, project),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(find.textContaining('합계 2시간 30분'), findsOneWidget);
    expect(find.text('Riley'), findsOneWidget);
    expect(find.text('2시간 30분 / 2시간'), findsOneWidget);
  });
}
