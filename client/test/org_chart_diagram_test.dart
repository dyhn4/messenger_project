import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:client/models/org_tree.dart';
import 'package:client/widgets/org_chart_diagram.dart';

/// 조직도 그림(가로 트리) — 자리 셈, 누르기, 끌어서 옮기기, 확대·축소, 빈 조직도.
///
/// 대표실(d1, 부서장 김대표)
///   ├ 영업본부(d2, 부서장 이본부)
///   │   └ 영업1팀(d4, 부서장 없음)
///   └ 개발본부(d3, 부서장 박본부)
/// 총무팀(d5, 맨 위)
/// + 부서 없는 사람 한 명(u6)
OrgTree _tree({bool withUnassigned = true}) => OrgTree.fromJson({
  'scope': 'server',
  'scopeKey': 'server',
  'canEdit': true,
  'departments': [
    {'id': 'd1', 'name': '대표실', 'headId': 'u1'},
    {'id': 'd2', 'parentId': 'd1', 'name': '영업본부', 'headId': 'u2'},
    {'id': 'd3', 'parentId': 'd1', 'name': '개발본부', 'headId': 'u3'},
    {'id': 'd4', 'parentId': 'd2', 'name': '영업1팀'},
    {'id': 'd5', 'name': '총무팀'},
  ],
  'members': [
    {'id': 'u1', 'name': '김대표', 'position': '대표이사', 'departmentId': 'd1'},
    {'id': 'u2', 'name': '이본부', 'position': '본부장', 'departmentId': 'd2'},
    {'id': 'u3', 'name': '박본부', 'departmentId': 'd3'},
    {'id': 'u4', 'name': '최사원', 'departmentId': 'd4'},
    {'id': 'u5', 'name': '정사원', 'departmentId': 'd4'},
    if (withUnassigned) {'id': 'u6', 'name': '한신입'},
  ],
});

Finder _dept(String id) => find.byKey(ValueKey('org-chart-dept-$id'));

Future<void> _pump(
  WidgetTester tester,
  OrgTree tree, {
  void Function(OrgDepartment)? onTapDepartment,
  void Function(OrgMember)? onTapMember,
  Future<void> Function(OrgDepartment, String?)? onMoveDepartment,
  Size size = const Size(1600, 1200),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: OrgChartDiagram(
          tree: tree,
          onTapDepartment: onTapDepartment,
          onTapMember: onTapMember,
          onMoveDepartment: onMoveDepartment,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// [from]을 길게 눌러 [to] 위치로 끌어 놓는다.
Future<void> _longPressDrag(
  WidgetTester tester,
  Finder from,
  Offset Function() to,
) async {
  final gesture = await tester.startGesture(tester.getCenter(from));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
  // 끌기가 시작되면 "맨 위로" 띠 등이 그려지므로 한 번 다시 그린 뒤 목적지를 잰다.
  await gesture.moveBy(const Offset(10, 10));
  await tester.pump();
  final target = to();
  await gesture.moveTo(target - const Offset(4, 4));
  await tester.pump();
  await gesture.moveTo(target);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

double _scale(WidgetTester tester) => tester
    .widget<InteractiveViewer>(find.byType(InteractiveViewer))
    .transformationController!
    .value
    .getMaxScaleOnAxis();

void main() {
  testWidgets('부서마다 상자 — 이름·부서장·사람 수(하위 부서 포함)', (tester) async {
    await _pump(tester, _tree());
    for (final id in ['d1', 'd2', 'd3', 'd4', 'd5']) {
      expect(_dept(id), findsOneWidget);
    }
    Finder inCard(String id, String text) =>
        find.descendant(of: _dept(id), matching: find.text(text));
    expect(inCard('d1', '대표실'), findsOneWidget);
    expect(inCard('d1', '김대표'), findsOneWidget);
    expect(inCard('d1', '대표이사'), findsOneWidget);
    expect(inCard('d1', '5명'), findsOneWidget);
    expect(inCard('d2', '이본부'), findsOneWidget);
    expect(inCard('d2', '3명'), findsOneWidget);
    expect(inCard('d4', '부서장 없음'), findsOneWidget);
    expect(inCard('d4', '2명'), findsOneWidget);
    expect(inCard('d5', '0명'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('하위 부서는 오른쪽에, 위 부서는 하위 부서들 가운데 높이에', (tester) async {
    await _pump(tester, _tree());
    final d1 = tester.getRect(_dept('d1'));
    final d2 = tester.getRect(_dept('d2'));
    final d3 = tester.getRect(_dept('d3'));
    final d4 = tester.getRect(_dept('d4'));
    final d5 = tester.getRect(_dept('d5'));
    // 오른쪽으로 한 칸씩.
    expect(d2.left, greaterThan(d1.right));
    expect(d3.left, greaterThan(d1.right));
    expect(d4.left, greaterThan(d2.right));
    expect(d2.left, moreOrLessEquals(d3.left));
    // 형제는 위에서 아래로(서버 순서).
    expect(d3.top, greaterThan(d2.bottom));
    // 위 부서는 하위 부서 범위 안(첫째~막내 가운데).
    expect(d1.center.dy, greaterThanOrEqualTo(d2.center.dy));
    expect(d1.center.dy, lessThanOrEqualTo(d3.center.dy));
    expect(
      d1.center.dy,
      moreOrLessEquals((d2.center.dy + d3.center.dy) / 2, epsilon: 0.5),
    );
    // 하위 부서가 하나면 같은 높이.
    expect(d2.center.dy, moreOrLessEquals(d4.center.dy, epsilon: 0.5));
    // 다음 맨 위 부서는 앞 묶음 아래, 같은 왼쪽 줄.
    expect(d5.top, greaterThan(d3.bottom));
    expect(d5.left, moreOrLessEquals(d1.left));
  });

  testWidgets('상자를 누르면 onTapDepartment, 부서장을 누르면 onTapMember', (tester) async {
    OrgDepartment? tapped;
    OrgMember? person;
    await _pump(
      tester,
      _tree(),
      onTapDepartment: (d) => tapped = d,
      onTapMember: (m) => person = m,
    );
    await tester.tap(
      find.descendant(of: _dept('d3'), matching: find.text('개발본부')),
    );
    await tester.pumpAndSettle();
    expect(tapped?.id, 'd3');
    expect(person, isNull);

    await tester.tap(find.byKey(const ValueKey('org-chart-head-u2')));
    await tester.pumpAndSettle();
    expect(person?.id, 'u2');
    expect(tapped?.id, 'd3');
  });

  testWidgets('길게 눌러 다른 부서에 놓으면 그 아래로 옮긴다', (tester) async {
    final calls = <(String, String?)>[];
    await _pump(
      tester,
      _tree(),
      onMoveDepartment: (d, parentId) async => calls.add((d.id, parentId)),
    );
    await _longPressDrag(
      tester,
      _dept('d5'),
      () => tester.getCenter(_dept('d2')),
    );
    expect(calls, [('d5', 'd2')]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('자기 하위 부서·이미 위 부서인 곳에는 놓을 수 없다', (tester) async {
    final calls = <(String, String?)>[];
    await _pump(
      tester,
      _tree(),
      onMoveDepartment: (d, parentId) async => calls.add((d.id, parentId)),
    );
    // 대표실 → 손자 부서(영업1팀): 고리가 되므로 안 된다.
    await _longPressDrag(
      tester,
      _dept('d1'),
      () => tester.getCenter(_dept('d4')),
    );
    // 영업1팀 → 이미 위 부서인 영업본부: 바뀌는 게 없다.
    await _longPressDrag(
      tester,
      _dept('d4'),
      () => tester.getCenter(_dept('d2')),
    );
    expect(calls, isEmpty);
  });

  testWidgets('끄는 동안 "맨 위로" 띠 — 놓으면 위 부서 없이(null)', (tester) async {
    final calls = <(String, String?)>[];
    await _pump(
      tester,
      _tree(),
      onMoveDepartment: (d, parentId) async => calls.add((d.id, parentId)),
    );
    final strip = find.byKey(const ValueKey('org-chart-drop-root'));
    expect(strip, findsNothing);
    await _longPressDrag(tester, _dept('d2'), () => tester.getCenter(strip));
    expect(calls, [('d2', null)]);
    expect(strip, findsNothing);
  });

  testWidgets('맨 위 부서를 끌 때는 "맨 위로" 띠가 없다', (tester) async {
    await _pump(tester, _tree(), onMoveDepartment: (d, parentId) async {});
    final gesture = await tester.startGesture(tester.getCenter(_dept('d5')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(20, 20));
    await tester.pump();
    expect(find.byKey(const ValueKey('org-chart-drop-root')), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('옮기는 동안 돌림표, 실패해도 깨지지 않는다', (tester) async {
    final done = Completer<void>();
    var fail = false;
    await _pump(
      tester,
      _tree(),
      onMoveDepartment: (d, parentId) {
        if (fail) return Future.error(Exception('boom'));
        return done.future;
      },
    );
    await _longPressDragNoSettle(tester, _dept('d5'), _dept('d3'));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    done.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);

    fail = true;
    await _longPressDrag(
      tester,
      _dept('d5'),
      () => tester.getCenter(_dept('d3')),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('onMoveDepartment가 없으면 끌 수 없다', (tester) async {
    OrgDepartment? tapped;
    await _pump(tester, _tree(), onTapDepartment: (d) => tapped = d);
    expect(find.byType(LongPressDraggable<OrgDepartment>), findsNothing);
    expect(find.byType(DragTarget<OrgDepartment>), findsNothing);
    final gesture = await tester.startGesture(tester.getCenter(_dept('d5')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveTo(tester.getCenter(_dept('d2')));
    await tester.pump();
    expect(find.byKey(const ValueKey('org-chart-drop-root')), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    // 길게 누르고 끈 것은 누르기가 아니다.
    expect(tapped, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('확대·축소 단추가 배율을 바꾸고 맞춤은 문제없다', (tester) async {
    await _pump(tester, _tree());
    expect(_scale(tester), moreOrLessEquals(1));
    await tester.tap(find.byKey(const ValueKey('org-chart-zoom-in')));
    await tester.pump();
    expect(_scale(tester), greaterThan(1));
    await tester.tap(find.byKey(const ValueKey('org-chart-zoom-out')));
    await tester.tap(find.byKey(const ValueKey('org-chart-zoom-out')));
    await tester.pump();
    expect(_scale(tester), lessThan(1));
    // 아주 많이 줄여도 최소 배율에서 멈춘다.
    for (var i = 0; i < 20; i++) {
      await tester.tap(find.byKey(const ValueKey('org-chart-zoom-out')));
    }
    await tester.pump();
    expect(_scale(tester), moreOrLessEquals(0.3, epsilon: 1e-6));
    await tester.tap(find.byKey(const ValueKey('org-chart-fit')));
    await tester.pump();
    // 넓은 화면에서는 키우지 않고 1배로 가운데.
    expect(_scale(tester), moreOrLessEquals(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('좁은 휴대폰(360x640)에서도 넘치지 않고 맞춤이 줄인다', (tester) async {
    await _pump(tester, _tree(), size: const Size(360, 640));
    expect(_dept('d1'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('org-chart-fit')));
    await tester.pump();
    expect(_scale(tester), lessThan(1));
    expect(_scale(tester), greaterThanOrEqualTo(0.3));
    // 맞춘 뒤에는 그림이 보이는 칸 안에 들어온다.
    final d4 = tester.getRect(_dept('d4'));
    expect(d4.right, lessThanOrEqualTo(360));
    expect(tester.takeException(), isNull);
  });

  testWidgets('어두운 테마에서도 그린다', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(body: OrgChartDiagram(tree: _tree())),
      ),
    );
    await tester.pumpAndSettle();
    expect(_dept('d1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('부서가 없으면 안내 글', (tester) async {
    await _pump(
      tester,
      OrgTree.fromJson({
        'scope': 'server',
        'scopeKey': 'server',
        'departments': [],
        'members': [
          {'id': 'u1', 'name': '김대표'},
        ],
      }),
    );
    expect(find.text('아직 부서가 없습니다.'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('부서 없는 사람이 있으면 맨 아래 "부서 없음" 상자', (tester) async {
    OrgMember? person;
    await _pump(tester, _tree(), onTapMember: (m) => person = m);
    final card = find.byKey(const ValueKey('org-chart-unassigned'));
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.text('부서 없음')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('1명')),
      findsOneWidget,
    );
    // 맨 위 부서들 아래.
    expect(
      tester.getRect(card).top,
      greaterThan(tester.getRect(_dept('d5')).bottom),
    );
    await tester.tap(find.byKey(const ValueKey('org-chart-unassigned-u6')));
    await tester.pumpAndSettle();
    expect(person?.id, 'u6');
  });

  testWidgets('모두 부서가 있으면 "부서 없음" 상자가 없다', (tester) async {
    await _pump(tester, _tree(withUnassigned: false));
    expect(find.byKey(const ValueKey('org-chart-unassigned')), findsNothing);
  });
}

/// 놓기까지만 하고 기다리지 않는다(옮기는 중 돌림표를 보려고).
Future<void> _longPressDragNoSettle(
  WidgetTester tester,
  Finder from,
  Finder to,
) async {
  final gesture = await tester.startGesture(tester.getCenter(from));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
  await gesture.moveBy(const Offset(10, 10));
  await tester.pump();
  final target = tester.getCenter(to);
  await gesture.moveTo(target - const Offset(4, 4));
  await tester.pump();
  await gesture.moveTo(target);
  await tester.pump();
  await gesture.up();
  await tester.pump();
}
