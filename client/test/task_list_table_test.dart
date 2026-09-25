import 'dart:convert';

import 'package:client/models/project.dart';
import 'package:client/models/app_user.dart';
import 'package:client/screens/project/task_detail_panel.dart';
import 'package:client/screens/project/task_views.dart';
import 'package:client/widgets/date_drop_calendar.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _json = {'content-type': 'application/json'};

void main() {
  setUp(TaskListTable.resetRememberedWidths);
  final now = DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> task(String id, String title) => {
    'id': id,
    'projectId': 'p1',
    'key': 'MKT-100$id',
    'title': title,
    'status': 'doing',
    'statusId': 's2',
    'priority': 'high',
    'priorityId': 'pr-high',
    'typeId': 't1',
    'typeName': '콘텐츠',
    'typeColor': '#5B8DEF',
    'statusName': '제작 중',
    'priorityName': '높음',
    'startDate': DateTime(2026, 9, 20).millisecondsSinceEpoch,
    'dueDate': DateTime(2026, 9, 25).millisecondsSinceEpoch,
    'createdAt': now,
  };

  late Map<String, dynamic> patched;

  Session session() {
    patched = {};
    final s = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    s.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'PATCH') {
          patched = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(task('1', '랜딩페이지')),
            200,
            headers: _json,
          );
        }
        if (path == '/api/projects/p1/task-types') {
          return http.Response(
            jsonEncode([
              {
                'id': 't1',
                'projectId': 'p1',
                'name': '콘텐츠',
                'color': '#5B8DEF',
              },
              {
                'id': 't2',
                'projectId': 'p1',
                'name': '디자인',
                'color': '#E53935',
              },
            ]),
            200,
            headers: _json,
          );
        }
        if (path == '/api/projects/p1/task-statuses') {
          return http.Response(
            jsonEncode([
              {
                'id': 's1',
                'projectId': 'p1',
                'name': '브리프',
                'color': '#94A3B8',
                'category': 'todo',
                'position': 0,
              },
              {
                'id': 's2',
                'projectId': 'p1',
                'name': '제작 중',
                'color': '#5B8DEF',
                'category': 'doing',
                'position': 1,
              },
              {
                'id': 's3',
                'projectId': 'p1',
                'name': '집행',
                'color': '#2E9E6B',
                'category': 'done',
                'position': 2,
              },
            ]),
            200,
            headers: _json,
          );
        }
        if (path == '/api/projects/p1/task-priorities') {
          return http.Response(
            jsonEncode([
              {
                'id': 'pr-urgent',
                'projectId': 'p1',
                'name': '긴급',
                'color': '#DC2626',
                'level': 'high',
                'position': 0,
              },
              {
                'id': 'pr-high',
                'projectId': 'p1',
                'name': '높음',
                'color': '#EF4444',
                'level': 'high',
                'position': 1,
              },
            ]),
            200,
            headers: _json,
          );
        }
        return http.Response('[]', 200, headers: _json);
      }),
    );
    return s;
  }

  Future<void> pump(WidgetTester tester, {VoidCallback? onChanged}) async {
    tester.view.physicalSize = const Size(1400, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskListTable(
            tasks: [Task.fromJson(task('1', '랜딩페이지 히어로 카피'))],
            session: session(),
            onOpen: (_) {},
            onChanged: onChanged,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('유형 배지를 누르면 그 프로젝트의 유형이 뜨고 고르면 저장된다', (tester) async {
    var reloads = 0;
    await pump(tester, onChanged: () => reloads++);

    await tester.tap(find.text('콘텐츠'));
    await tester.pumpAndSettle();
    // 메뉴가 열리면 '없음'과 다른 유형이 보인다.
    expect(find.text('없음'), findsOneWidget);
    expect(find.text('디자인'), findsOneWidget);

    await tester.tap(find.text('디자인'));
    await tester.pumpAndSettle();
    expect(patched['typeId'], 't2');
    expect(reloads, 1);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('상태 배지로 상태를 바꾼다', (tester) async {
    await pump(tester);
    await tester.tap(find.text('제작 중'));
    await tester.pumpAndSettle();
    expect(find.text('브리프'), findsOneWidget);

    await tester.tap(find.text('집행'));
    await tester.pumpAndSettle();
    expect(patched['statusId'], 's3');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('우선순위 배지로 우선순위를 바꾼다', (tester) async {
    await pump(tester);
    await tester.tap(find.text('높음'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('긴급'));
    await tester.pumpAndSettle();
    expect(patched['priorityId'], 'pr-urgent');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('업무/유형 사이 구분선을 끌면 첫 열 폭이 바뀐다', (tester) async {
    await pump(tester);

    // "업무" 머리글 칸 자체의 폭을 잰다(Expanded 안의 Padding이 그 칸이다).
    final titleCell = find
        .ancestor(of: find.text('업무'), matching: find.byType(Padding))
        .first;
    final handle = find.byWidgetPredicate(
      (w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeColumn,
    );
    expect(handle, findsOneWidget);

    final table = find
        .descendant(
          of: find.byType(TaskListTable),
          matching: find.byType(Scrollbar),
        )
        .first;
    final widthBefore = tester.getSize(titleCell).width;
    final handleXBefore = tester.getTopLeft(handle).dx;
    final tableWidthBefore = tester.getSize(table).width;
    final tableRightBefore = tester.getTopRight(table).dx;

    // 마우스를 여러 번 나눠 움직여도 민 만큼만 정확히 따라와야 한다 — 프레임마다 다시
    // 그려진 폭을 또 더하면 몇 배로 달아나고, 이동량만 더하면 놓친 이동만큼 뒤처진다.
    final gesture = await tester.startGesture(tester.getCenter(handle));
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    // tester.drag는 끌기 판정에 쓰이는 여유분(touch slop)을 먼저 먹으므로 정확히 120px은
    // 아니다 — 줄어들었다는 것과, 구분선이 칸과 똑같이 따라왔다는 것을 본다.
    final widthAfter = tester.getSize(titleCell).width;
    final handleXAfter = tester.getTopLeft(handle).dx;
    // 민 만큼(120px) 그대로 줄어든다 — 델타를 놓치면 이보다 훨씬 덜 줄어든다.
    expect(widthAfter, closeTo(widthBefore - 120, 2));
    expect(handleXBefore - handleXAfter, closeTo(widthBefore - widthAfter, 1));
    // 표 자체의 폭(오른쪽 끝)은 그대로다 — 구분선은 표 안에서만 움직인다.
    expect(tester.getSize(table).width, tableWidthBefore);
    expect(tester.getTopRight(table).dx, tableRightBefore);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('마감일을 누르면 달력이 떠서 날짜를 바꾼다', (tester) async {
    await pump(tester);

    // 칸의 왼쪽 가장자리 근처를 눌러, 달력이 그 x에서 떨어지는지 본다.
    final cell = tester.getRect(find.text('2026.09.25'));
    final tapAt = Offset(cell.left + 4, cell.center.dy);
    await tester.tapAt(tapAt);
    await tester.pumpAndSettle();
    // 칸 바로 아래에 달력이 펼쳐진다(모달이 아니라서 뒤가 어두워지지 않는다).
    expect(find.text('2026년 9월'), findsOneWidget);
    expect(find.text('오늘'), findsOneWidget);
    // 뒤를 어둡게 덮는 막(모달 대화상자의 barrier)이 없다.
    expect(
      tester
          .widgetList<ModalBarrier>(find.byType(ModalBarrier))
          .where((b) => b.color != null),
      isEmpty,
    );
    // 달력은 누른 칸 아래로, 그리고 누른 지점에서 오른쪽으로 펼쳐진다.
    final cellBottom = tester.getBottomLeft(find.text('2026.09.25')).dy;
    final calendar = find.byType(DateDropCalendar);
    expect(tester.getTopLeft(calendar).dy, greaterThan(cellBottom));
    expect(tester.getTopLeft(calendar).dx, closeTo(tapAt.dx, 1));

    await tester.tap(find.text('28').first);
    await tester.pumpAndSettle();

    final due = DateTime.fromMillisecondsSinceEpoch(patched['dueDate'] as int);
    expect(due.day, 28);
    expect(due.month, 9);
    expect(patched['startDate'], isNull); // 마감일만 건드린다

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('업무에 마우스를 올리면 연필이 나오고, 제목을 고쳐 저장한다', (tester) async {
    await pump(tester);

    // 마우스를 올리기 전에는 연필이 없다.
    expect(find.byTooltip('제목 수정'), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('랜딩페이지 히어로 카피')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('제목 수정'), findsOneWidget);

    await tester.tap(find.byTooltip('제목 수정'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '랜딩페이지 히어로 카피'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '카피 최종안');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(patched['title'], '카피 최종안');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('날짜를 눌러 연 달력은 손을 떼도 그대로 떠 있다', (tester) async {
    await pump(tester);

    // 실제 앱에서는 누르고 떼는 사이에 프레임이 그려진다 — 예전에는 그 사이 다시 그려진
    // onTap이 "닫기"로 바뀌어 방금 연 달력이 손을 떼는 순간 도로 닫혔다.
    final cell = tester.getRect(find.text('2026.09.25'));
    final gesture = await tester.startGesture(cell.center);
    await tester.pumpAndSettle(); // 누른 채로 화면이 다시 그려진다
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      find.byType(DateDropCalendar),
      findsOneWidget,
      reason: '손을 떼면 열리고 그대로 떠 있어야 한다',
    );

    // 같은 칸을 다시 누르면 닫힌다.
    await tester.tapAt(cell.center);
    await tester.pumpAndSettle();
    expect(find.byType(DateDropCalendar), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('유형·우선순위를 아직 안 고른 업무는 "—"로 보이고 눌러서 고를 수 있다', (tester) async {
    tester.view.physicalSize = const Size(1400, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final bare = task('2', '새로 만든 하위 업무')
      ..remove('typeName')
      ..remove('typeColor')
      ..remove('priorityName');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskListTable(
            tasks: [Task.fromJson(bare)],
            session: session(),
            onOpen: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 상태는 배지로 남고, 유형·우선순위 자리는 "—"가 된다("보통" 같은 기본값이 아니다).
    expect(find.text('제작 중'), findsOneWidget);
    expect(find.text('보통'), findsNothing);
    // 유형·우선순위, 그리고 이 예시엔 생성자도 비어 있어 셋이다.
    expect(find.text('—'), findsNWidgets(3));

    // 그래도 눌러서 고를 수 있다.
    await tester.tap(find.text('—').first);
    await tester.pumpAndSettle();
    expect(find.text('디자인'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  /// 창 폭·프로젝트 리스트 여부·옆 업무 패널 여부를 바꿔 가며 표를 띄운다.
  Future<void> pumpSized(
    WidgetTester tester, {
    required double width,
    bool projectList = false,
    double panelInset = 0,
  }) async {
    tester.view.physicalSize = Size(width, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    Widget table = TaskListTable(
      tasks: [
        Task.fromJson({
          ...task('1', '랜딩페이지 히어로 카피'),
          'creatorId': 'u1',
          'creatorName': '송병근',
          'assigneeId': 'u1',
        }),
      ],
      session: session(),
      onOpen: (_) {},
      members: projectList
          ? [AppUser(id: 'u1', username: 'song', name: '송병근')]
          : null,
    );
    if (panelInset > 0) {
      table = TaskPanelInset(width: panelInset, child: table);
    }
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: table)));
    await tester.pumpAndSettle();
  }

  final hScrollView = find.byWidgetPredicate(
    (w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
  );

  testWidgets('좁은 창: 가로 스크롤바를 끌면 업무 열은 그대로, 나머지 칸만 움직인다', (tester) async {
    await pumpSized(tester, width: 820);
    final view = tester.widget<SingleChildScrollView>(hScrollView);
    expect(view.controller, isNotNull);
    expect(view.controller!.position.maxScrollExtent, greaterThan(0));
    final titleX = tester.getTopLeft(find.text('업무')).dx;
    final typeX = tester.getTopLeft(find.text('유형')).dx;
    final rowTitleX = tester.getTopLeft(find.text('랜딩페이지 히어로 카피')).dx;
    // 스크롤 줄은 "업무" 열 오른쪽 구간 아래에만 있다.
    final rect = tester.getRect(hScrollView);
    expect(rect.left, greaterThan(titleX + 150));

    final mouse = await tester.startGesture(
      Offset(rect.left + 30, rect.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    for (var i = 0; i < 5; i++) {
      await mouse.moveBy(const Offset(30, 0));
      await tester.pump();
    }
    await mouse.up();
    await tester.pumpAndSettle();
    expect(view.controller!.offset, greaterThan(0));
    // 업무 열(머리글·제목)은 제자리, 유형 머리글은 왼쪽으로 밀렸다.
    expect(tester.getTopLeft(find.text('업무')).dx, titleX);
    expect(tester.getTopLeft(find.text('랜딩페이지 히어로 카피')).dx, rowTitleX);
    expect(
      tester.getTopLeft(find.text('유형')).dx,
      closeTo(typeX - view.controller!.offset, 1),
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('좁은 창에서도 업무/유형 구분선을 끌어 넓힐 수 있다', (tester) async {
    await pumpSized(tester, width: 820);
    final titleCell = find
        .ancestor(of: find.text('업무'), matching: find.byType(Padding))
        .first;
    final handle = find.byWidgetPredicate(
      (w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeColumn,
    );
    final before = tester.getSize(titleCell).width;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getSize(titleCell).width, closeTo(before + 100, 2));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('리스트: 담당자 뒤에 생성자·생성일 열이 있고 모두 보인다', (tester) async {
    await pumpSized(tester, width: 1400, projectList: true);
    final viewRight = tester.getRect(find.byType(TaskListTable)).right - 25;
    for (final label in ['담당자', '생성자', '생성일']) {
      expect(find.text(label), findsOneWidget, reason: label);
      expect(
        tester.getRect(find.text(label)).right,
        lessThanOrEqualTo(viewRight + 0.5),
      );
    }
    expect(
      tester.getCenter(find.text('담당자')).dx,
      lessThan(tester.getCenter(find.text('생성자')).dx),
    );
    expect(
      tester.getCenter(find.text('생성자')).dx,
      lessThan(tester.getCenter(find.text('생성일')).dx),
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('리스트: 업무 패널이 옆에 열리면 담당자까지만 보이고 생성자·생성일은 패널 뒤로', (tester) async {
    await pumpSized(
      tester,
      width: 1700 - 421,
      projectList: true,
      panelInset: 421,
    );
    final viewRight = tester.getRect(find.byType(TaskListTable)).right - 25;
    expect(tester.getRect(find.text('담당자')).right, closeTo(viewRight, 1.5));
    expect(tester.getCenter(find.text('생성자')).dx, greaterThan(viewRight));
    expect(tester.getCenter(find.text('생성일')).dx, greaterThan(viewRight));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('내 업무: 업무 패널이 열려도 생성자 열까지 다 보인다', (tester) async {
    await pumpSized(tester, width: 1700 - 421, panelInset: 421);
    final viewRight = tester.getRect(find.byType(TaskListTable)).right - 25;
    expect(find.text('담당자'), findsNothing);
    expect(
      tester.getRect(find.text('생성자')).right,
      lessThanOrEqualTo(viewRight + 0.5),
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('업무 패널이 열리거나 창이 줄어도 업무/유형 구분선은 제자리에 있다', (tester) async {
    double divider() => tester.getTopLeft(find.text('유형')).dx;

    await pumpSized(tester, width: 1600, projectList: true);
    final x = divider();
    // 패널이 옆에 열림(표가 새로 만들어진다).
    await pumpSized(
      tester,
      width: 1600 - 421,
      projectList: true,
      panelInset: 421,
    );
    // "유형" 머리글은 가운데 정렬이라, 칸 폭이 바뀌면 글자 위치도 조금 바뀐다 — 칸 왼쪽 끝을 본다.
    double cellLeft() => tester
        .getTopLeft(
          find
              .ancestor(of: find.text('유형'), matching: find.byType(SizedBox))
              .first,
        )
        .dx;
    final left = cellLeft();
    await pumpSized(tester, width: 1100, projectList: true);
    expect(cellLeft(), left);
    await pumpSized(tester, width: 1600, projectList: true);
    expect(cellLeft(), left);
    expect(divider(), x);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
