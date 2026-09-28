import 'dart:async';
import 'dart:convert';

import 'package:client/models/project.dart';
import 'package:client/models/room.dart';
import 'package:client/screens/project/automation_flow_editor.dart';
import 'package:client/screens/project/filter_controls.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _json = {'content-type': 'application/json'};

http.Response _ok(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: _json);

Map<String, dynamic> _field(
  String id,
  String name,
  String kind, [
  List<String> options = const [],
]) => {
  'id': id,
  'projectId': 'p1',
  'name': name,
  'kind': kind,
  'options': options,
};

/// 사용자 정의 필드 — 글·날짜·숫자·선택.
final _fields = [
  _field('f1', '메모', 'text'),
  _field('f2', '확인일', 'date'),
  _field('f3', '점수', 'number'),
  _field('f4', '단계', 'select', ['1차', '2차']),
];

/// 프로젝트 p1(팀 t1)의 상태·우선순위·유형과 구성원 둘(+ 사용자 정의 필드 [fields]).
/// POST로 온 규칙은 [posts]에 모은다.
MockClient _client(
  List<Map<String, dynamic>> posts, {
  List<Map<String, dynamic>> fields = const [],
}) => MockClient((request) => _handle(request, posts, fields: fields));

Future<http.Response> _handle(
  http.Request request,
  List<Map<String, dynamic>> posts, {
  List<Map<String, dynamic>> fields = const [],
}) async {
  final path = request.url.path;
  switch (path) {
    case '/api/projects/p1':
      return _ok({
        'id': 'p1',
        'teamId': 't1',
        'name': '마케팅',
        'identifier': 'MKT',
        'createdAt': 0,
        'members': [
          {'id': 'u1', 'username': 'riley', 'name': 'Riley'},
          {'id': 'u2', 'username': 'sam', 'name': 'Sam'},
        ],
      });
    case '/api/projects/p1/task-statuses':
      return _ok([
        for (final (id, name, cat) in [
          ('s1', '할 일', 'todo'),
          ('s2', '진행 중', 'doing'),
          ('s3', '완료', 'done'),
        ])
          {
            'id': id,
            'projectId': 'p1',
            'name': name,
            'color': '#94A3B8',
            'category': cat,
          },
      ]);
    case '/api/projects/p1/task-priorities':
      return _ok([
        for (final (id, name, level) in [
          ('pr1', '낮음', 'low'),
          ('pr2', '보통', 'normal'),
          ('pr3', '높음', 'high'),
        ])
          {
            'id': id,
            'projectId': 'p1',
            'name': name,
            'color': '#EF4444',
            'level': level,
          },
      ]);
    case '/api/projects/p1/task-types':
      return _ok([
        {'id': 'ty1', 'projectId': 'p1', 'name': '버그', 'color': '#607D8B'},
      ]);
    case '/api/projects/p1/task-fields':
      return _ok(fields);
    case '/api/projects/p1/automations' when request.method == 'POST':
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      posts.add(body);
      return _ok({
        'id': 'a1',
        'projectId': 'p1',
        'name': body['name'],
        'enabled': body['enabled'],
        'trigger': 'task_created',
        'actions': [],
        'graph': body['graph'],
      }, 201);
  }
  return http.Response('{}', 404);
}

Room _room(String id, String teamId, String name, {bool secret = false}) =>
    Room(
      id: id,
      teamId: teamId,
      type: RoomType.topic,
      name: name,
      members: const [],
      createdAt: DateTime(2026),
      lastRead: const {},
      isSecret: secret,
    );

Session _session(MockClient client) {
  final session = Session(
    notifications: NotificationService(),
    settings: AppSettings(),
  );
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: client,
  );
  session.userId = 'u1';
  session.rooms.addAll([
    _room('r1', 't1', '마케팅 팀'),
    _room('r2', 't2', '다른 팀 방'),
    _room('r3', 't1', '비밀 방', secret: true),
  ]);
  return session;
}

/// 편집기를 연다([rule]이 없으면 새 규칙). 닫힐 때의 결과는 [onResult]로.
Future<void> _open(
  WidgetTester tester,
  Session session,
  void Function(bool saved) onResult, {
  AutomationRule? rule,
  Size size = const Size(1400, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showAutomationFlowEditor(
              context,
              session: session,
              projectId: 'p1',
              rule: rule,
            ).then(onResult),
            child: const Text('열기'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('열기'));
  await tester.pumpAndSettle();
}

/// 데스크톱처럼 마우스로 끌어다 놓는다.
Future<void> _mouseDrag(WidgetTester tester, Offset from, Offset to) async {
  final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
  await tester.pump();
  await g.moveBy(const Offset(12, 0));
  await tester.pump();
  await g.moveTo(to);
  await tester.pump();
  await g.up();
  await g.removePointer();
  await tester.pumpAndSettle();
}

Offset _canvas(WidgetTester tester, Offset at) =>
    tester.getTopLeft(find.byKey(const ValueKey('automation-canvas'))) + at;

Future<void> _dropFromPalette(
  WidgetTester tester,
  String kind,
  String type,
  Offset at,
) => _mouseDrag(
  tester,
  tester.getCenter(find.byKey(ValueKey('palette-$kind-$type'))),
  _canvas(tester, at),
);

Offset _port(WidgetTester tester, String nodeId, String port) =>
    tester.getCenter(find.byKey(ValueKey('port-$nodeId-$port')));

/// 새 규칙은 제목 칸이 비어 있어서 저장하기 전에 제목부터 넣는다.
Future<void> _setTitle(WidgetTester tester, [String title = '테스트 자동화']) async {
  await tester.enterText(find.byKey(const ValueKey('rule-name')), title);
  await tester.pump();
}

Future<void> _pick(WidgetTester tester, String pickKey, String option) async {
  await tester.tap(find.byKey(ValueKey(pickKey)));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(
      of: find.byType(FilterPopupCard),
      matching: find.text(option),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('트리거 → IF → 액션을 놓고 이어서 설정한 뒤 저장하면 그래프가 그대로 간다', (tester) async {
    final posts = <Map<String, dynamic>>[];
    bool? saved;
    await _open(tester, _session(_client(posts)), (v) => saved = v);

    expect(find.text('왼쪽에서 트리거를 끌어다 놓아 시작하세요'), findsOneWidget);
    expect(find.text('옵션이 없습니다.'), findsOneWidget);
    expect(find.text('활성'), findsOneWidget);

    await _dropFromPalette(
      tester,
      'trigger',
      'task_created',
      const Offset(80, 120),
    );
    await _dropFromPalette(tester, 'condition', 'if', const Offset(380, 120));
    await _dropFromPalette(
      tester,
      'action',
      'set_field',
      const Offset(680, 120),
    );
    expect(find.text('왼쪽에서 트리거를 끌어다 놓아 시작하세요'), findsNothing);
    for (final id in ['n1', 'n2', 'n3']) {
      expect(find.byKey(ValueKey('node-$id')), findsOneWidget);
    }

    // 포트끼리 잇는다: 트리거 → IF, IF의 Yes → 액션.
    await _mouseDrag(
      tester,
      _port(tester, 'n1', 'out'),
      _port(tester, 'n2', 'in'),
    );
    await _mouseDrag(
      tester,
      _port(tester, 'n2', 'yes'),
      _port(tester, 'n3', 'in'),
    );
    // 같은 연결을 또 만들거나 액션에서 트리거로 되돌아가는 연결은 무시된다.
    await _mouseDrag(
      tester,
      _port(tester, 'n1', 'out'),
      _port(tester, 'n2', 'in'),
    );

    // IF: 우선순위 같음 높음.
    await tester.tap(find.byKey(const ValueKey('node-n2')));
    await tester.pumpAndSettle();
    expect(find.text('비교'), findsOneWidget);
    await _pick(tester, 'pick-field', '우선순위');
    await _pick(tester, 'pick-value', '높음');
    expect(find.text('높음'), findsNWidgets(2)); // 설정 칸 + 노드 요약

    // 액션: 담당자를 Riley로.
    await tester.tap(find.byKey(const ValueKey('node-n3')));
    await tester.pumpAndSettle();
    await _pick(tester, 'pick-field', '담당자');
    await _pick(tester, 'pick-value', 'Riley');
    expect(find.text('Riley'), findsNWidgets(2)); // 설정 칸 + 노드 요약

    await tester.enterText(
      find.byKey(const ValueKey('rule-name')),
      '높은 우선순위 담당 지정',
    );
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(posts, hasLength(1));
    final body = posts.single;
    expect(body['name'], '높은 우선순위 담당 지정');
    expect(body['enabled'], true);
    final graph = body['graph'] as Map<String, dynamic>;
    final nodes = (graph['nodes'] as List).cast<Map<String, dynamic>>();
    expect(
      [
        for (final n in nodes) [n['id'], n['kind'], n['type']],
      ],
      [
        ['n1', 'trigger', 'task_created'],
        ['n2', 'condition', 'if'],
        ['n3', 'action', 'set_field'],
      ],
    );
    expect(nodes[0]['config'], isEmpty);
    expect(nodes[1]['config'], {
      'field': 'priority',
      'op': 'eq',
      'value': 'pr3',
    });
    expect(nodes[2]['config'], {'field': 'assignee', 'value': 'u1'});
    for (final n in nodes) {
      expect(n['x'], isA<num>());
      expect(n['y'], isA<num>());
    }
    expect(graph['edges'], [
      {'from': 'n1', 'port': 'out', 'to': 'n2'},
      {'from': 'n2', 'port': 'yes', 'to': 'n3'},
    ]);
    expect(saved, isTrue);
    expect(find.text('노드 설정'), findsNothing);

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('저장 전 검사: 빈 캔버스·연결 안 된 액션·빠진 값은 서버로 보내지 않는다', (tester) async {
    final posts = <Map<String, dynamic>>[];
    await _open(tester, _session(_client(posts)), (_) {});

    Future<void> save() async {
      await tester.tap(find.widgetWithText(FilledButton, '저장'));
      await tester.pump();
    }

    // 새 규칙은 제목이 비어 있어서 제목부터 막는다.
    await save();
    expect(find.text('자동화 제목을 입력하세요.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));

    await _setTitle(tester);
    await save();
    expect(find.text('트리거를 하나 놓아 주세요.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));

    await _dropFromPalette(
      tester,
      'trigger',
      'field_changed',
      const Offset(80, 120),
    );
    await _dropFromPalette(
      tester,
      'action',
      'set_field',
      const Offset(420, 120),
    );
    await save();
    expect(find.text('트리거에 연결된 액션이 하나 이상 필요합니다.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));

    // 이었지만 필드 변경(상태)의 값을 안 골랐다 → 그 노드가 선택되고 안내가 뜬다.
    await _mouseDrag(
      tester,
      _port(tester, 'n1', 'out'),
      _port(tester, 'n2', 'in'),
    );
    await tester.tap(find.byKey(const ValueKey('node-n1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pick-value')), findsNothing);
    await save();
    expect(find.text('변경할 값을 선택하세요.'), findsOneWidget);
    expect(find.byKey(const ValueKey('pick-value')), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));

    // 제목을 공백만 남기면 노드보다 제목부터 막는다.
    await tester.enterText(find.byKey(const ValueKey('rule-name')), '  ');
    await save();
    expect(find.text('자동화 제목을 입력하세요.'), findsOneWidget);
    expect(find.text('변경할 값을 선택하세요.'), findsNothing);

    expect(posts, isEmpty);
    expect(find.text('노드 설정'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('새 규칙 제목: 빈 칸에 안내 문구만 · 누르면 커서만 · 비운 채 저장하면 막고 제목 칸으로', (
    tester,
  ) async {
    final posts = <Map<String, dynamic>>[];
    bool? saved;
    await _open(tester, _session(_client(posts)), (v) => saved = v);
    final title = find.byKey(const ValueKey('rule-name'));
    TextField field() => tester.widget<TextField>(title);
    EditableTextState editable() => tester.state<EditableTextState>(
      find.descendant(of: title, matching: find.byType(EditableText)),
    );

    // 예전의 '새 자동화 규칙' 같은 기본 글자 없이 비어 있고, 안내 문구만 보인다.
    expect(field().controller!.text, isEmpty);
    expect(find.text('새 자동화 규칙'), findsNothing);
    expect(find.text('자동화 제목을 입력하세요'), findsOneWidget);
    expect(field().focusNode!.hasFocus, isFalse);

    // 누르면 안내 문구는 사라지고 빈 칸에 커서만 깜빡인다 — 지울 글자가 없다.
    await tester.tap(title);
    await tester.pump();
    expect(field().focusNode!.hasFocus, isTrue);
    expect(field().controller!.text, isEmpty);
    expect(find.text('자동화 제목을 입력하세요'), findsNothing);
    expect(editable().cursorCurrentlyVisible, isTrue);

    // 캔버스를 누르면 포커스가 빠지고 안내 문구가 다시 보인다.
    await tester.tapAt(_canvas(tester, const Offset(500, 500)));
    await tester.pump();
    expect(field().focusNode!.hasFocus, isFalse);
    expect(find.text('자동화 제목을 입력하세요'), findsOneWidget);

    // 흐름은 다 갖췄고 제목만 없다.
    await _dropFromPalette(
      tester,
      'trigger',
      'task_created',
      const Offset(80, 120),
    );
    await _dropFromPalette(
      tester,
      'action',
      'archive_task',
      const Offset(420, 120),
    );
    await _mouseDrag(
      tester,
      _port(tester, 'n1', 'out'),
      _port(tester, 'n2', 'in'),
    );
    expect(field().focusNode!.hasFocus, isFalse);

    // 비운 채 저장 → 서버로 보내지 않고 알린 뒤 제목 칸으로 커서를 옮긴다.
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pump();
    expect(find.text('자동화 제목을 입력하세요.'), findsOneWidget);
    expect(field().focusNode!.hasFocus, isTrue);
    expect(find.text('자동화 제목을 입력하세요'), findsNothing);
    expect(posts, isEmpty);
    expect(saved, isNull);
    expect(find.byKey(const ValueKey('automation-canvas')), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));

    // 공백만 넣어도 같다.
    await tester.tapAt(_canvas(tester, const Offset(500, 500)));
    await tester.pump();
    await tester.enterText(title, '   ');
    await tester.tapAt(_canvas(tester, const Offset(500, 500)));
    await tester.pump();
    expect(field().focusNode!.hasFocus, isFalse);
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pump();
    expect(find.text('자동화 제목을 입력하세요.'), findsOneWidget);
    expect(field().focusNode!.hasFocus, isTrue);
    expect(posts, isEmpty);
    await tester.pump(const Duration(seconds: 3));

    // 제목을 넣으면 앞뒤 공백을 뺀 제목으로 저장된다.
    await tester.enterText(title, ' 새 업무 보관 ');
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(posts, hasLength(1));
    expect(posts.single['name'], '새 업무 보관');
    expect(saved, isTrue);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('트리거는 하나만 — 두 번째 트리거는 놓이지 않는다', (tester) async {
    await _open(tester, _session(_client([])), (_) {});

    await _dropFromPalette(
      tester,
      'trigger',
      'task_created',
      const Offset(80, 120),
    );
    await _dropFromPalette(
      tester,
      'trigger',
      'field_changed',
      const Offset(420, 300),
    );
    await tester.pump();
    expect(find.text('트리거는 하나만 둘 수 있습니다.'), findsOneWidget);
    expect(find.byKey(const ValueKey('node-n1')), findsOneWidget);
    expect(find.byKey(const ValueKey('node-n2')), findsNothing);

    // 조건·액션은 여러 개 둘 수 있다.
    await _dropFromPalette(tester, 'condition', 'if', const Offset(420, 300));
    expect(find.byKey(const ValueKey('node-n2')), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Delete 키 삭제(입력 중엔 무시) · 채팅방 목록 · 나가기 확인', (tester) async {
    bool? saved;
    await _open(tester, _session(_client([])), (v) => saved = v);

    await _dropFromPalette(
      tester,
      'action',
      'chat_message',
      const Offset(300, 120),
    );
    // 이 팀의 비밀이 아닌 방만 고를 수 있다.
    await tester.tap(find.byKey(const ValueKey('pick-room')));
    await tester.pumpAndSettle();
    expect(find.text('마케팅 팀'), findsOneWidget);
    expect(find.text('다른 팀 방'), findsNothing);
    expect(find.text('비밀 방'), findsNothing);
    await tester.tap(find.text('마케팅 팀'));
    await tester.pumpAndSettle();
    expect(find.text('마케팅 팀'), findsNWidgets(2)); // 설정 칸 + 노드 요약

    // 이름 칸에서 Backspace는 글자만 지운다.
    await tester.tap(find.byKey(const ValueKey('rule-name')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(find.byKey(const ValueKey('node-n1')), findsOneWidget);

    // 노드를 누른 뒤 Delete → 노드가 지워진다.
    await tester.tap(find.byKey(const ValueKey('node-n1')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(find.byKey(const ValueKey('node-n1')), findsNothing);
    expect(find.text('옵션이 없습니다.'), findsOneWidget);

    // 바뀐 게 있으면 뒤로 가기 전에 묻는다.
    await tester.tap(find.byTooltip('뒤로'));
    await tester.pumpAndSettle();
    expect(find.text('저장하지 않은 변경 사항이 있습니다. 나갈까요?'), findsOneWidget);
    await tester.tap(find.text('나가기'));
    await tester.pumpAndSettle();
    expect(find.text('노드 설정'), findsNothing);
    expect(saved, isFalse);
  });

  testWidgets('연결: 선을 눌러 고르고 삭제 · 순환 연결은 무시 · 비어 있음 비교', (tester) async {
    final posts = <Map<String, dynamic>>[];
    await _open(tester, _session(_client(posts)), (_) {});

    await _dropFromPalette(
      tester,
      'trigger',
      'task_created',
      const Offset(80, 80),
    );
    await _dropFromPalette(tester, 'condition', 'if', const Offset(380, 80));
    await _dropFromPalette(tester, 'condition', 'if', const Offset(380, 330));
    await _dropFromPalette(
      tester,
      'action',
      'archive_task',
      const Offset(680, 330),
    );

    await _mouseDrag(
      tester,
      _port(tester, 'n1', 'out'),
      _port(tester, 'n2', 'in'),
    );
    // 선 가운데(두 포트의 가운데)를 누르면 연결이 골라지고 오른쪽에서 지울 수 있다.
    final mid = (_port(tester, 'n1', 'out') + _port(tester, 'n2', 'in')) / 2;
    await tester.tapAt(mid);
    await tester.pump();
    expect(find.text('연결'), findsOneWidget);
    await tester.tap(find.text('연결 삭제'));
    await tester.pump();
    expect(find.text('연결 삭제'), findsNothing);
    expect(find.text('옵션이 없습니다.'), findsOneWidget);

    // 다시 잇고, 이번엔 골라서 Backspace로 지웠다가 또 잇는다.
    await _mouseDrag(
      tester,
      _port(tester, 'n1', 'out'),
      _port(tester, 'n2', 'in'),
    );
    await tester.tapAt(mid);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(find.text('연결 삭제'), findsNothing);
    await _mouseDrag(
      tester,
      _port(tester, 'n1', 'out'),
      _port(tester, 'n2', 'in'),
    );

    await _mouseDrag(
      tester,
      _port(tester, 'n2', 'yes'),
      _port(tester, 'n3', 'in'),
    );
    // n3 → n2는 순환이라 무시된다.
    await _mouseDrag(
      tester,
      _port(tester, 'n3', 'no'),
      _port(tester, 'n2', 'in'),
    );
    await _mouseDrag(
      tester,
      _port(tester, 'n3', 'yes'),
      _port(tester, 'n4', 'in'),
    );

    // 두 IF 모두 '비어 있음'이면 값 칸이 없다.
    for (final id in ['n2', 'n3']) {
      await tester.tap(find.byKey(ValueKey('node-$id')));
      await tester.pumpAndSettle();
      await _pick(tester, 'pick-op', '비어 있음');
      expect(find.byKey(const ValueKey('pick-value')), findsNothing);
    }

    await _setTitle(tester);
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(posts, hasLength(1));
    final graph = posts.single['graph'] as Map<String, dynamic>;
    expect(graph['edges'], [
      {'from': 'n1', 'port': 'out', 'to': 'n2'},
      {'from': 'n2', 'port': 'yes', 'to': 'n3'},
      {'from': 'n3', 'port': 'yes', 'to': 'n4'},
    ]);
    final nodes = (graph['nodes'] as List).cast<Map<String, dynamic>>();
    expect(nodes[1]['config'], {'field': 'status', 'op': 'empty'});
    expect(nodes[3]['type'], 'archive_task');
    expect(nodes[3]['config'], isEmpty);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('기존 규칙 수정(어두운 테마): 요약이 채워져 보이고 PATCH로 저장된다', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Map<String, dynamic>? patched;
    final client = MockClient((request) async {
      if (request.method == 'PATCH' &&
          request.url.path == '/api/automations/a1') {
        patched = jsonDecode(request.body) as Map<String, dynamic>;
        return _ok({
          'id': 'a1',
          'projectId': 'p1',
          'name': patched!['name'],
          'enabled': patched!['enabled'],
          'trigger': 'checklist_completed',
          'actions': [],
          'graph': patched!['graph'],
        });
      }
      return _handle(request, []);
    });
    final session = _session(client);
    final rule = AutomationRule.fromJson({
      'id': 'a1',
      'projectId': 'p1',
      'name': '다음 단계 만들기',
      'enabled': false,
      'trigger': 'checklist_completed',
      'actions': [],
      'graph': {
        'nodes': [
          {
            'id': 'n1',
            'kind': 'trigger',
            'type': 'checklist_completed',
            'config': {},
            'x': 60,
            'y': 120,
          },
          {
            'id': 'n2',
            'kind': 'action',
            'type': 'create_task',
            'config': {
              'title': '검수',
              'statusId': null,
              'assignee': 'current_assignee',
            },
            'x': 360,
            'y': 60,
          },
          {
            'id': 'n3',
            'kind': 'action',
            'type': 'chat_message',
            'config': {'roomId': 'r1', 'text': '내용 확인 부탁드리겠습니다.'},
            'x': 360,
            'y': 260,
          },
        ],
        'edges': [
          {'from': 'n1', 'port': 'out', 'to': 'n2'},
          {'from': 'n1', 'port': 'out', 'to': 'n3'},
        ],
      },
    });

    bool? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showAutomationFlowEditor(
                context,
                session: session,
                projectId: 'p1',
                rule: rule,
              ).then((v) => saved = v),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 기존 규칙은 제목 칸에 그 이름이 그대로 들어 있다.
    expect(find.text('다음 단계 만들기'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('rule-name')))
          .controller!
          .text,
      '다음 단계 만들기',
    );
    expect(find.text('비활성'), findsOneWidget);
    expect(find.text('검수'), findsOneWidget);
    expect(find.text('할 일'), findsOneWidget); // statusId null → 첫 '할 일' 상태
    expect(find.text('현재 담당자'), findsOneWidget);
    expect(find.text('마케팅 팀'), findsOneWidget);
    expect(find.text('내용 확인 부탁드리겠습니다.'), findsOneWidget);

    // 제목을 고치면 노드 요약도 바로 바뀐다.
    await tester.tap(find.byKey(const ValueKey('node-n2')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('text-title')), ' 최종 검수 ');
    await tester.pump();
    expect(find.text(' 최종 검수 '), findsOneWidget); // 입력 칸
    expect(find.text('최종 검수'), findsOneWidget); // 노드 요약

    await tester.tap(find.text('비활성'));
    await tester.pump();
    expect(find.text('활성'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(patched?['name'], '다음 단계 만들기');
    expect(patched?['enabled'], true);
    final nodes = ((patched!['graph'] as Map)['nodes'] as List)
        .cast<Map<String, dynamic>>();
    expect(nodes[1]['config'], {
      'title': '최종 검수',
      'statusId': null,
      'assignee': 'current_assignee',
    });
    expect(nodes[0]['x'], 60);
    expect(saved, isTrue);
  });

  testWidgets('캔버스: 빈 곳을 끌어 이동 · +/−와 Ctrl+휠로 확대·축소', (tester) async {
    await _open(tester, _session(_client([])), (_) {});
    await _dropFromPalette(
      tester,
      'trigger',
      'task_created',
      const Offset(80, 80),
    );
    final node = find.byKey(const ValueKey('node-n1'));
    final before = tester.getRect(node);

    // 빈 곳을 끌면 노드가 같이 움직인다.
    await _mouseDrag(
      tester,
      _canvas(tester, const Offset(500, 500)),
      _canvas(tester, const Offset(560, 540)),
    );
    final moved = tester.getRect(node);
    expect(moved.left - before.left, closeTo(60, 0.5));
    expect(moved.top - before.top, closeTo(40, 0.5));
    expect(moved.width, closeTo(before.width, 0.01));

    await tester.tap(find.byTooltip('확대'));
    await tester.pump();
    expect(tester.getRect(node).width, closeTo(before.width * 1.2, 0.01));
    await tester.tap(find.byTooltip('축소'));
    await tester.pump();
    expect(tester.getRect(node).width, closeTo(before.width, 0.01));

    // Ctrl+휠 위로 → 확대, 끝은 1.6배에서 멈춘다.
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    final at = _canvas(tester, const Offset(400, 400));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendEventToBinding(pointer.hover(at));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -100)));
    await tester.pump();
    expect(tester.getRect(node).width, closeTo(before.width * 1.1, 0.01));
    for (var i = 0; i < 10; i++) {
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -100)));
    }
    await tester.pump();
    expect(tester.getRect(node).width, closeTo(before.width * 1.6, 0.01));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    // 노드를 끌면 그 노드만 옮겨진다.
    // 확대로 위쪽이 캔버스 밖으로 나갔으므로 보이는 아래쪽을 잡는다.
    final start = tester.getRect(node);
    final grab = start.bottomCenter - const Offset(0, 20);
    await _mouseDrag(tester, grab, grab + const Offset(100, 50));
    expect(tester.getRect(node).left - start.left, closeTo(100, 0.5));
    expect(tester.getRect(node).top - start.top, closeTo(50, 0.5));
  });

  testWidgets('IF 값 칸: 비교·필드를 바꿔 값이 지워지면 입력 칸도 비워진다 · 숫자 필드는 숫자만', (
    tester,
  ) async {
    await _open(tester, _session(_client([], fields: _fields)), (_) {});
    await _dropFromPalette(tester, 'condition', 'if', const Offset(300, 120));
    await _pick(tester, 'pick-field', '메모');

    final valueBox = find.byKey(const ValueKey('text-value'));
    String boxText() => tester.widget<TextField>(valueBox).controller!.text;

    await tester.enterText(valueBox, 'abc');
    await tester.pump();
    expect(find.text('abc'), findsNWidgets(2)); // 입력 칸 + 노드 요약

    // 비어 있음이면 값이 지워진다 — 같음으로 돌아와도 옛 글자가 남아 있으면 안 된다.
    await _pick(tester, 'pick-op', '비어 있음');
    expect(valueBox, findsNothing);
    await _pick(tester, 'pick-op', '같음');
    expect(boxText(), isEmpty);
    expect(find.text('abc'), findsNothing);
    expect(find.text('값 선택'), findsOneWidget); // 노드 요약도 빈 값

    // 필드를 바꿨다 돌아와도 마찬가지.
    await tester.enterText(valueBox, 'xyz');
    await tester.pump();
    await _pick(tester, 'pick-field', '상태');
    await _pick(tester, 'pick-field', '메모');
    expect(boxText(), isEmpty);
    expect(find.text('xyz'), findsNothing);

    // 숫자 필드는 숫자·소수점·부호만 받는다.
    await _pick(tester, 'pick-field', '점수');
    await tester.enterText(valueBox, '1a2.5점');
    await tester.pump();
    expect(boxText(), '12.5');
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('날짜 필드 조건: 달력에서 고른 날이 YYYY-MM-DD로 저장되고 카드엔 요일까지 보인다', (
    tester,
  ) async {
    final posts = <Map<String, dynamic>>[];
    await _open(tester, _session(_client(posts, fields: _fields)), (_) {});
    await _dropFromPalette(
      tester,
      'trigger',
      'task_created',
      const Offset(80, 120),
    );
    await _dropFromPalette(tester, 'condition', 'if', const Offset(380, 120));
    await _dropFromPalette(
      tester,
      'action',
      'archive_task',
      const Offset(680, 120),
    );
    await _mouseDrag(
      tester,
      _port(tester, 'n1', 'out'),
      _port(tester, 'n2', 'in'),
    );
    await _mouseDrag(
      tester,
      _port(tester, 'n2', 'yes'),
      _port(tester, 'n3', 'in'),
    );
    await tester.tap(find.byKey(const ValueKey('node-n2')));
    await tester.pumpAndSettle();
    await _pick(tester, 'pick-field', '확인일');

    // 글자 칸이 아니라 날짜 칸이다.
    expect(find.byKey(const ValueKey('text-value')), findsNothing);
    expect(find.text('연도-월-일'), findsOneWidget);

    // 날을 안 고르면 저장을 막는다.
    await _setTitle(tester);
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pump();
    expect(find.text('IF 조건의 값을 선택하세요.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));

    await tester.tap(find.byKey(const ValueKey('date-value')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(FilterCalendar),
        matching: find.text('15'),
      ),
    );
    await tester.pumpAndSettle();

    final now = DateTime.now();
    final day = DateTime(now.year, now.month, 15);
    final value = '${now.year}-${now.month.toString().padLeft(2, '0')}-15';
    const weekdays = ['일', '월', '화', '수', '목', '금', '토'];
    expect(find.text(value), findsOneWidget); // 날짜 칸
    expect(
      find.text(
        '${day.year}년 ${day.month}월 15일 (${weekdays[day.weekday % 7]})',
      ),
      findsOneWidget,
    ); // 노드 카드

    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(posts, hasLength(1));
    final nodes = ((posts.single['graph'] as Map)['nodes'] as List)
        .cast<Map<String, dynamic>>();
    expect(nodes[1]['config'], {
      'field': 'field:f2',
      'op': 'eq',
      'value': value,
    });
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('지워진 상태·구성원·채팅방·유형·선택지·필드: 카드에 표시하고, 저장은 그 노드를 골라 막는다', (
    tester,
  ) async {
    Map<String, dynamic>? patched;
    final client = MockClient((request) async {
      if (request.method == 'PATCH' &&
          request.url.path == '/api/automations/a1') {
        patched = jsonDecode(request.body) as Map<String, dynamic>;
        return _ok({
          'id': 'a1',
          'projectId': 'p1',
          'name': patched!['name'],
          'enabled': patched!['enabled'],
          'trigger': 'field_changed',
          'actions': [],
          'graph': patched!['graph'],
        });
      }
      return _handle(request, [], fields: _fields);
    });
    Map<String, dynamic> node(
      String id,
      String kind,
      String type,
      Map<String, dynamic> config,
      double x,
      double y,
    ) => {
      'id': id,
      'kind': kind,
      'type': type,
      'config': config,
      'x': x,
      'y': y,
    };
    final rule = AutomationRule.fromJson({
      'id': 'a1',
      'projectId': 'p1',
      'name': '옛 규칙',
      'enabled': true,
      'trigger': 'field_changed',
      'actions': [],
      'graph': {
        'nodes': [
          node('n1', 'trigger', 'field_changed', {'field': 'field:f9'}, 60, 60),
          node(
            'n2',
            'condition',
            'if',
            {'field': 'field:f4', 'op': 'eq', 'value': '3차'},
            360,
            60,
          ),
          node(
            'n3',
            'action',
            'create_task',
            {'title': '검수', 'statusId': 's9', 'assignee': 'u9'},
            660,
            20,
          ),
          // savedBy처럼 서버가 붙이는 칸은 모르는 채로 그대로 돌려보낸다.
          node(
            'n4',
            'action',
            'chat_message',
            {'roomId': 'r9', 'text': '확인', 'savedBy': 'u1'},
            660,
            240,
          ),
          node(
            'n5',
            'action',
            'set_field',
            {'field': 'type', 'value': 'ty9'},
            660,
            420,
          ),
        ],
        'edges': [
          {'from': 'n1', 'port': 'out', 'to': 'n2'},
          {'from': 'n2', 'port': 'yes', 'to': 'n3'},
          {'from': 'n2', 'port': 'yes', 'to': 'n4'},
          {'from': 'n2', 'port': 'no', 'to': 'n5'},
        ],
      },
    });
    bool? saved;
    await _open(tester, _session(client), (v) => saved = v, rule: rule);
    expect(tester.takeException(), isNull);

    // 기본값처럼 보이지 않고 지워졌다고 보인다.
    for (final label in [
      '(삭제된 필드)',
      '(삭제된 선택지)',
      '(삭제된 상태)',
      '(삭제된 구성원)',
      '(삭제된 채팅방)',
      '(삭제된 유형)',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('할 일'), findsNothing); // 지워진 상태를 기본 상태로 덮지 않는다

    /// 저장을 누르면 [message]가 뜨고 [nodeId]가 골라진다. 그 뒤 [fix]로 고친다.
    Future<void> blocked(
      String message,
      String nodeId,
      String pickKey,
      String option,
    ) async {
      await tester.tap(find.widgetWithText(FilledButton, '저장'));
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget, reason: message);
      expect(find.byKey(ValueKey('panel-$nodeId')), findsOneWidget);
      expect(patched, isNull);
      await tester.pump(const Duration(seconds: 3));
      await _pick(tester, pickKey, option);
    }

    // 필드 변경 트리거는 체크 목록 — 지워진 필드도 체크된 채로 보여서 풀고 다른 필드를 고른다.
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(find.text('삭제된 필드입니다. 다시 선택하세요.'), findsOneWidget);
    expect(find.byKey(const ValueKey('panel-n1')), findsOneWidget);
    expect(find.text('(삭제된 필드)'), findsNWidgets(2)); // 체크 목록 + 노드 카드
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.byKey(const ValueKey('check-field-field:f9')));
    await tester.pump();
    expect(find.byKey(const ValueKey('check-field-field:f9')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('check-field-status')));
    await tester.pump();

    await blocked('삭제된 선택지입니다. 다시 선택하세요.', 'n2', 'pick-value', '1차');
    await blocked('삭제된 상태입니다. 다시 선택하세요.', 'n3', 'pick-status', '진행 중');
    await blocked('삭제된 구성원입니다. 다시 선택하세요.', 'n3', 'pick-assignee', 'Sam');
    await blocked(
      '삭제되었거나 참여 중이 아닌 채팅방입니다. 다시 선택하세요.',
      'n4',
      'pick-room',
      '마케팅 팀',
    );
    await blocked('삭제된 유형입니다. 다시 선택하세요.', 'n5', 'pick-value', '버그');

    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(saved, isTrue);
    final nodes = ((patched!['graph'] as Map)['nodes'] as List)
        .cast<Map<String, dynamic>>();
    // 예전 {field} 모양은 저장할 때 {fields}로 바뀐다.
    expect(nodes[0]['config'], {
      'fields': ['status'],
    });
    expect(nodes[1]['config'], {
      'field': 'field:f4',
      'op': 'eq',
      'value': '1차',
    });
    expect(nodes[2]['config'], {
      'title': '검수',
      'statusId': 's2',
      'assignee': 'u2',
    });
    expect(nodes[3]['config'], {'roomId': 'r1', 'text': '확인', 'savedBy': 'u1'});
    expect(nodes[4]['config'], {'field': 'type', 'value': 'ty1'});
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('좁은 창: 넘치지 않고 캔버스가 남는다 — 팔레트는 아이콘 줄, 설정 칸은 고를 때만 위에 뜬다', (
    tester,
  ) async {
    await _open(
      tester,
      _session(_client([])),
      (_) {},
      size: const Size(700, 800),
    );
    expect(tester.takeException(), isNull);
    final canvas = find.byKey(const ValueKey('automation-canvas'));
    final canvasWidth = tester.getSize(canvas).width;
    expect(canvasWidth, greaterThan(600));
    expect(find.text('왼쪽에서 트리거를 끌어다 놓아 시작하세요'), findsOneWidget);
    // 아무것도 안 골랐으면 설정 칸이 없고, 팔레트는 이름 없이 아이콘만.
    expect(find.byKey(const ValueKey('automation-panel')), findsNothing);
    expect(find.text('필드 변경'), findsNothing);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('palette-trigger-task_created')))
          .width,
      lessThan(60),
    );

    // 아이콘 줄에서도 끌어다 놓을 수 있고, 놓으면 설정 칸이 캔버스 위에 뜬다.
    await _dropFromPalette(
      tester,
      'trigger',
      'field_changed',
      const Offset(40, 120),
    );
    expect(find.byKey(const ValueKey('node-n1')), findsOneWidget);
    expect(find.byKey(const ValueKey('automation-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('check-field-any')), findsOneWidget);
    expect(tester.getSize(canvas).width, canvasWidth);
    expect(tester.takeException(), isNull);

    // 닫기 → 설정 칸이 사라진다.
    await tester.tap(find.byTooltip('닫기'));
    await tester.pump();
    expect(find.byKey(const ValueKey('automation-panel')), findsNothing);

    // 더 좁은 창이나 경계 바로 위(넓은 배치에서 캔버스가 가장 좁을 때)도 넘치지 않는다.
    for (final size in const [Size(400, 700), Size(780, 700)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$size');
      expect(tester.getSize(canvas).width, greaterThan(200), reason: '$size');
    }
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('글자 수는 서버처럼 UTF-16 길이로 센다 — 이모지 이름·업무 제목·메시지', (tester) async {
    final posts = <Map<String, dynamic>>[];
    await _open(tester, _session(_client(posts)), (_) {});
    await _dropFromPalette(
      tester,
      'trigger',
      'task_created',
      const Offset(80, 120),
    );
    await _dropFromPalette(
      tester,
      'action',
      'create_task',
      const Offset(420, 40),
    );
    await _dropFromPalette(
      tester,
      'action',
      'chat_message',
      const Offset(420, 300),
    );
    await _mouseDrag(
      tester,
      _port(tester, 'n1', 'out'),
      _port(tester, 'n2', 'in'),
    );
    await _mouseDrag(
      tester,
      _port(tester, 'n1', 'out'),
      _port(tester, 'n3', 'in'),
    );
    await tester.tap(find.byKey(const ValueKey('node-n3')));
    await tester.pumpAndSettle();
    await _pick(tester, 'pick-room', '마케팅 팀');

    // 이모지 하나 = 두 글자(UTF-16) — 입력 칸은 한 글자로 세서 받아 준다.
    String emoji(int n) => List.filled(n, '😀').join();
    await tester.enterText(find.byKey(const ValueKey('text-text')), emoji(251));
    await tester.tap(find.byKey(const ValueKey('node-n2')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('text-title')),
      emoji(101),
    );
    await tester.enterText(find.byKey(const ValueKey('rule-name')), emoji(21));
    await tester.pump();

    Future<void> saveBlocked(String message, String? nodeId) async {
      await tester.tap(find.widgetWithText(FilledButton, '저장'));
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget, reason: message);
      if (nodeId != null) {
        expect(find.byKey(ValueKey('panel-$nodeId')), findsOneWidget);
      }
      await tester.pump(const Duration(seconds: 3));
    }

    await saveBlocked('자동화 제목은 40자 이내로 입력하세요.', null);
    await tester.enterText(find.byKey(const ValueKey('rule-name')), emoji(20));
    await saveBlocked('업무 제목은 200자 이내로 입력하세요.', 'n2');
    await tester.enterText(
      find.byKey(const ValueKey('text-title')),
      emoji(100),
    );
    await saveBlocked('채팅방에 보낼 내용은 500자 이내로 입력하세요.', 'n3');
    await tester.enterText(find.byKey(const ValueKey('text-text')), emoji(250));
    expect(posts, isEmpty);

    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(posts, hasLength(1));
    expect(posts.single['name'], emoji(20));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('저장 중에는 뒤로 가기를 막고, 끝나면 저장 결과(true)로 닫힌다', (tester) async {
    final posts = <Map<String, dynamic>>[];
    final gate = Completer<void>();
    final client = MockClient((request) async {
      if (request.method == 'POST') await gate.future;
      return _handle(request, posts);
    });
    bool? saved;
    await _open(tester, _session(client), (v) => saved = v);
    await _dropFromPalette(
      tester,
      'trigger',
      'task_created',
      const Offset(80, 120),
    );
    await _dropFromPalette(
      tester,
      'action',
      'archive_task',
      const Offset(420, 120),
    );
    await _mouseDrag(
      tester,
      _port(tester, 'n1', 'out'),
      _port(tester, 'n2', 'in'),
    );

    await _setTitle(tester);
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pump();
    final back = find.widgetWithIcon(IconButton, Icons.chevron_left);
    expect(tester.widget<IconButton>(back).onPressed, isNull);

    // 시스템 뒤로 가기도 무시한다 — 나가기 확인 창도 뜨지 않는다.
    await Navigator.of(
      tester.element(find.byKey(const ValueKey('automation-canvas'))),
    ).maybePop();
    await tester.pumpAndSettle();
    expect(find.text('저장하지 않은 변경 사항이 있습니다. 나갈까요?'), findsNothing);
    expect(find.byKey(const ValueKey('automation-canvas')), findsOneWidget);
    expect(saved, isNull);

    gate.complete();
    await tester.pumpAndSettle();
    expect(posts, hasLength(1));
    expect(saved, isTrue);
    expect(find.byKey(const ValueKey('automation-canvas')), findsNothing);
  });

  testWidgets('필드 변경 트리거: 여러 필드 체크 · 모든 필드는 따로 · 하나도 없으면 저장을 막는다', (
    tester,
  ) async {
    Map<String, dynamic>? patched;
    final client = MockClient((request) async {
      if (request.method == 'PATCH' &&
          request.url.path == '/api/automations/a1') {
        patched = jsonDecode(request.body) as Map<String, dynamic>;
        return _ok({
          'id': 'a1',
          'projectId': 'p1',
          'name': patched!['name'],
          'enabled': patched!['enabled'],
          'trigger': 'field_changed',
          'actions': [],
          'graph': patched!['graph'],
        });
      }
      return _handle(request, [], fields: _fields);
    });
    // 예전 {field} 한 개짜리 모양으로 저장된 규칙.
    final rule = AutomationRule.fromJson({
      'id': 'a1',
      'projectId': 'p1',
      'name': '우선순위 바뀌면 보관',
      'enabled': true,
      'trigger': 'field_changed',
      'actions': [],
      'graph': {
        'nodes': [
          {
            'id': 'n1',
            'kind': 'trigger',
            'type': 'field_changed',
            'config': {'field': 'priority'},
            'x': 60,
            'y': 120,
          },
          {
            'id': 'n2',
            'kind': 'action',
            'type': 'archive_task',
            'config': {},
            'x': 400,
            'y': 120,
          },
        ],
        'edges': [
          {'from': 'n1', 'port': 'out', 'to': 'n2'},
        ],
      },
    });
    await _open(tester, _session(client), (_) {}, rule: rule);
    expect(tester.takeException(), isNull);
    expect(find.text('우선순위'), findsOneWidget); // 카드

    await tester.tap(find.byKey(const ValueKey('node-n1')));
    await tester.pumpAndSettle();
    expect(find.text('감지할 필드'), findsOneWidget);
    bool checked(String key) => tester
        .widget<Checkbox>(
          find.descendant(
            of: find.byKey(ValueKey('check-field-$key')),
            matching: find.byType(Checkbox),
          ),
        )
        .value!;
    Future<void> toggle(String key) async {
      await tester.tap(find.byKey(ValueKey('check-field-$key')));
      await tester.pump();
    }

    expect(checked('priority'), isTrue);
    expect(checked('any'), isFalse);

    // 여러 개를 고르면 카드엔 체크한 순서가 아니라 목록 순서대로 쉼표로 이어 보인다.
    await toggle('type');
    await toggle('status');
    expect(find.text('상태, 우선순위, 유형'), findsOneWidget);
    await toggle('field:f4'); // 사용자 정의 필드도 고를 수 있다.
    expect(find.text('상태, 우선순위, 유형, 단계'), findsOneWidget);

    // 모든 필드를 켜면 나머지가 꺼지고, 다른 필드를 켜면 모든 필드가 꺼진다.
    await toggle('any');
    expect(checked('any'), isTrue);
    expect(checked('status'), isFalse);
    expect(checked('field:f4'), isFalse);
    expect(find.text('모든 필드'), findsNWidgets(2)); // 체크 목록 + 카드
    await toggle('dueDate');
    expect(checked('any'), isFalse);
    expect(checked('dueDate'), isTrue);
    expect(find.text('마감일'), findsNWidgets(2));

    // 하나도 안 고르면 저장을 막는다.
    await toggle('dueDate');
    expect(find.text('필드 선택'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(find.text('감지할 필드를 하나 이상 선택하세요.'), findsOneWidget);
    expect(patched, isNull);
    await tester.pump(const Duration(seconds: 3));

    await toggle('type');
    await toggle('status');
    expect(find.text('상태, 유형'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final nodes = ((patched!['graph'] as Map)['nodes'] as List)
        .cast<Map<String, dynamic>>();
    // 예전 field 칸은 빠지고 fields만 간다.
    expect(nodes[0]['config'], {
      'fields': ['status', 'type'],
    });
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('변수 칩: 커서 자리에 넣고(고른 글자는 바꾼다) 카드엔 {업무 제목}처럼 · 글자 수 제한', (
    tester,
  ) async {
    final posts = <Map<String, dynamic>>[];
    await _open(tester, _session(_client(posts)), (_) {});
    await _dropFromPalette(
      tester,
      'trigger',
      'task_created',
      const Offset(80, 120),
    );
    await _dropFromPalette(
      tester,
      'action',
      'create_task',
      const Offset(420, 40),
    );
    await _dropFromPalette(
      tester,
      'action',
      'chat_message',
      const Offset(420, 300),
    );
    await _mouseDrag(
      tester,
      _port(tester, 'n1', 'out'),
      _port(tester, 'n2', 'in'),
    );
    await _mouseDrag(
      tester,
      _port(tester, 'n1', 'out'),
      _port(tester, 'n3', 'in'),
    );
    TextEditingController box(String key) =>
        tester.widget<TextField>(find.byKey(ValueKey(key))).controller!;

    // 채팅방 알림: 메시지 칸을 한 번도 안 눌렀으면 맨 뒤에 붙고, 이어 누르면 그 뒤에 붙는다.
    await tester.tap(find.byKey(const ValueKey('node-n3')));
    await tester.pumpAndSettle();
    await _pick(tester, 'pick-room', '마케팅 팀');
    expect(find.text('업무 제목'), findsOneWidget);
    expect(find.text('업무 번호'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('token-text-key')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('token-text-title')));
    await tester.pump();
    expect(box('text-text').text, '{{task.key}}{{task.title}}');
    expect(find.text('{업무 번호}{업무 제목}'), findsOneWidget); // 카드

    // 노드를 고른 채(캔버스 포커스) 칩을 누른 뒤 Backspace를 쳐도 노드가 지워지지 않고 글자가
    // 지워진다 — 칩을 누르면 포커스가 입력 칸으로 옮겨 간다.
    await tester.tap(find.byKey(const ValueKey('node-n3')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('token-text-assignee')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(find.byKey(const ValueKey('node-n3')), findsOneWidget);
    expect(box('text-text').text, '{{task.key}}{{task.title}}{{task.assignee}');

    // 업무 생성: 넣으면 제한(200자)을 넘는 자리엔 넣지 않고 알린다.
    await tester.tap(find.byKey(const ValueKey('node-n2')));
    await tester.pumpAndSettle();
    final title = find.byKey(const ValueKey('text-title'));
    await tester.enterText(title, 'a' * 190);
    await tester.tap(find.byKey(const ValueKey('token-title-title')));
    await tester.pump();
    expect(find.text('200자를 넘어서 더 넣을 수 없습니다.'), findsOneWidget);
    expect(box('text-title').text, 'a' * 190);
    await tester.pump(const Duration(seconds: 3));

    // 커서를 맨 앞에 두고 누르면 그 자리에 들어가고 커서는 변수 뒤로 간다. 마우스로 눌러도
    // 입력 칸 포커스가 풀리지 않는다(데스크톱에서 바깥을 누르면 풀리는 것과 다르게).
    await tester.enterText(title, ' - 콘텐츠 제작');
    box('text-title').selection = const TextSelection.collapsed(offset: 0);
    await tester.tap(
      find.byKey(const ValueKey('token-title-title')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(box('text-title').text, '{{task.title}} - 콘텐츠 제작');
    expect(
      box('text-title').selection,
      const TextSelection.collapsed(offset: 14),
    );
    final editable = tester.state<EditableTextState>(
      find.descendant(of: title, matching: find.byType(EditableText)),
    );
    expect(editable.widget.focusNode.hasFocus, isTrue);
    expect(find.text('{업무 제목} - 콘텐츠 제작'), findsOneWidget); // 카드

    // 글자를 골라 두면 그 글자를 변수로 바꾼다.
    box('text-title').selection = const TextSelection(
      baseOffset: 17,
      extentOffset: 20,
    );
    await tester.tap(
      find.byKey(const ValueKey('token-title-assignee')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(box('text-title').text, '{{task.title}} - {{task.assignee}} 제작');
    expect(find.text('{업무 제목} - {담당자} 제작'), findsOneWidget);

    await _setTitle(tester);
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(posts, hasLength(1));
    final nodes = ((posts.single['graph'] as Map)['nodes'] as List)
        .cast<Map<String, dynamic>>();
    expect(
      nodes[1]['config']['title'],
      '{{task.title}} - {{task.assignee}} 제작',
    );
    // 위에서 Backspace로 한 글자 지운 그대로 저장된다.
    expect(
      nodes[2]['config']['text'],
      '{{task.key}}{{task.title}}{{task.assignee}',
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('카드: 저장된 변수는 읽을 수 있는 이름으로, 모르는 {{...}}는 그대로 보인다', (tester) async {
    final rule = AutomationRule.fromJson({
      'id': 'a1',
      'projectId': 'p1',
      'name': '검수 만들기',
      'enabled': true,
      'trigger': 'task_created',
      'actions': [],
      'graph': {
        'nodes': [
          {
            'id': 'n1',
            'kind': 'trigger',
            'type': 'task_created',
            'config': {},
            'x': 60,
            'y': 120,
          },
          {
            'id': 'n2',
            'kind': 'action',
            'type': 'create_task',
            'config': {
              'title': '[{{task.key}}] {{task.title}} 검수',
              'statusId': null,
              'assignee': null,
            },
            'x': 360,
            'y': 60,
          },
          {
            'id': 'n3',
            'kind': 'action',
            'type': 'chat_message',
            'config': {
              'roomId': 'r1',
              'text': '{{task.assignee}}님 {{task.due}} 확인',
            },
            'x': 360,
            'y': 260,
          },
        ],
        'edges': [
          {'from': 'n1', 'port': 'out', 'to': 'n2'},
          {'from': 'n1', 'port': 'out', 'to': 'n3'},
        ],
      },
    });
    await _open(tester, _session(_client([])), (_) {}, rule: rule);
    expect(tester.takeException(), isNull);
    expect(find.text('[{업무 번호}] {업무 제목} 검수'), findsOneWidget);
    expect(find.text('{담당자}님 {{task.due}} 확인'), findsOneWidget);
  });
}
