import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client/models/message.dart' show MessageAttachment;
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/models/todo.dart';
import 'package:client/screens/todo_detail_dialog.dart';
import 'package:client/screens/todo_editor_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/services/todo_download.dart';
import 'package:client/widgets/attachment_widgets.dart'
    show AllDownloadBar, ChatImageAttachments;
import 'package:client/widgets/todo_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers/fake_todo_api.dart';

/// 할 일 상세(잔디 상세 모양) — 만든 사람 줄(`○○ 님이 할 일을 추가했습니다.`·시각, 오른쪽 ★ · •••), ••• 메뉴(즐겨찾기 ·
/// 할 일 수정 · 파일 다운로드 · 할 일 삭제 — 역할·첨부에 따라), 제목·설명, 상자[진행률(전체 %) · 대화방 · 담당자(`총 N명`,
/// 내 줄만 진척률 고르기 상자, 다른 사람은 색 글자) · 일정(기간·알림, 없으면 `없음`)], 담당자 없는 개인 할 일은 진행률 칸의
/// 고르기 상자, 즐겨찾기·진척률의 낙관적 표시와 되돌리기, 삭제·소켓(지워지면 위에 떠 있던 ••• 메뉴·진척률 메뉴·수정 창·
/// 삭제 확인까지 닫힘 — 대화상자·전체 화면·패널 안 화면 모두, 패널에서는 삭제 확인이 루트 Navigator에 있다), 토스트는 앱
/// 맨 위 Overlay, 첨부 전부 받기(폴더에 차례로 저장·이름 겹치면 번호·실패 수). 서버는 가짜 API(helpers/fake_todo_api.dart).

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

Session _session() {
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
  // 시험 중에 탐색기 창이 뜨지 않게.
  session.settings.openFolderAfterDownload = false;
  final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  session.rooms.add(
    Room.fromJson({
      'id': 'r1',
      'teamId': 't1',
      'type': 'topic',
      'name': '영업 토픽',
      'members': [_user('me', '나'), _user('u2', '김철수'), _user('u3', '이영희')],
      'createdAt': 1000,
    }),
  );
  return session;
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Finder _key(String k) => find.byKey(ValueKey(k));

/// 상세를 연 결과 — 가짜 API, 창이 닫히며 돌려준 값(아직 열려 있으면 null), 패널 ✕(onClosePanel)를 누른 횟수.
class _Opened {
  _Opened(this.api, this.mode);
  final FakeTodoApi api;
  final TodoViewMode mode;
  bool? result;
  int panelClosed = 0;
}

/// 모드마다 기본 창 크기 — 대화상자는 넓은 창(mode를 안 줘도 대화상자), 전체 화면은 좁은 창, 패널은 1280 창 오른쪽 420 칸.
const _defaultSizes = {
  TodoViewMode.dialog: Size(900, 900),
  TodoViewMode.page: Size(390, 844),
  TodoViewMode.panel: Size(1280, 900),
};

/// 패널 모드 하네스의 왼쪽(패널 밖) 채팅 자리를 누른 횟수 — 상세가 띄운 메뉴가 떠 있는 동안 채팅 쪽을 눌러도 그 누름이
/// 채팅에 가지 않는지 본다.
var _chatTaps = 0;

/// 패널 밖 채팅 자리의 한 점.
const _chatPoint = Offset(300, 450);

/// 버튼 하나로 [json] 할 일의 상세를 연다. [mode]가 dialog·page면 예전처럼 mode 없이(창 폭으로 정해진다), panel이면 PC 할 일
/// 패널처럼 창 오른쪽 420 칸(키 panel-host)의 중첩 Navigator(키 panel-nav) 첫 화면에서 panel 모드로 연다(왼쪽은 누르면
/// [_chatTaps]가 느는 채팅 자리). [settle]이 false면 짧게만 돌린다(사진 칸은 이미지를 기다리며 계속 돌아 pumpAndSettle이
/// 끝나지 않는다).
Future<_Opened> _open(
  WidgetTester tester, {
  required Map<String, dynamic> json,
  FakeTodoApi? api,
  Session? session,
  TodoOpenRoom? onOpenRoom,
  Stream<Map<String, dynamic>>? changed,
  TodoDownloader? download,
  TodoViewMode mode = TodoViewMode.dialog,
  Size? size,
  bool settle = true,
}) async {
  final opened = _Opened(api ?? FakeTodoApi(me: 'me', todos: [json]), mode);
  final s = session ?? _session();
  final panel = mode == TodoViewMode.panel;
  _chatTaps = 0;
  _size(tester, size ?? _defaultSizes[mode]!);
  // 한 시험에서 두 번 열 때 앞의 앱(열린 창 포함)을 먼저 치운다 — 같은 MaterialApp이면 Navigator가 그대로 남는다.
  await tester.pumpWidget(const SizedBox());
  Widget opener(BuildContext context) => ElevatedButton(
    key: const ValueKey('opener'),
    onPressed: () async {
      opened.result = await showTodoDetail(
        context,
        session: s,
        todo: Todo.fromJson(json),
        api: opened.api,
        onOpenRoom: onOpenRoom,
        changed: changed ?? const Stream.empty(),
        download: download,
        mode: panel ? TodoViewMode.panel : null,
        onClosePanel: panel ? () => opened.panelClosed++ : null,
      );
    },
    child: const Text('열기'),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: panel
          ? Scaffold(
              body: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _chatTaps++,
                      child: const SizedBox.expand(),
                    ),
                  ),
                  SizedBox(
                    key: const ValueKey('panel-host'),
                    width: 420,
                    child: ClipRect(
                      child: Navigator(
                        key: const ValueKey('panel-nav'),
                        onGenerateRoute: (_) => MaterialPageRoute(
                          builder: (context) =>
                              Material(child: Center(child: opener(context))),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            )
          : Builder(
              builder: (context) =>
                  Scaffold(body: Center(child: opener(context))),
            ),
    ),
  );
  await tester.tap(_key('opener'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
  return opened;
}

/// 팝업 메뉴 항목([item])이 든 메뉴 상자의 자리(항목의 가장 가까운 Material이 메뉴 상자다).
Rect _menuRect(WidgetTester tester, Finder item) => tester.getRect(
  find.ancestor(of: item, matching: find.byType(Material)).first,
);

/// 패널 모드에서 [open]으로 띄운 메뉴([shown] — 그 안의 항목)가 창 전체(루트 Navigator)의 할 일 메뉴로 떠 있되 자리는 패널
/// 칸 안이고, 패널 밖 채팅 자리를 누르면 닫히며 그 누름은 채팅에 가지 않는다.
Future<void> _expectClosesFromChat(
  WidgetTester tester, {
  required String what,
  required Future<void> Function() open,
  required Finder shown,
}) async {
  await open();
  expect(shown, findsOneWidget, reason: '$what — 떴다');
  final element = tester.element(shown);
  expect(
    ModalRoute.of(element)?.settings.name,
    todoPopupRouteName,
    reason: '$what — 할 일 메뉴',
  );
  expect(
    Navigator.of(element),
    same(Navigator.of(element, rootNavigator: true)),
    reason: '$what — 루트 Navigator',
  );
  final panel = tester.getRect(_key('panel-host'));
  final menu = _menuRect(tester, shown);
  expect(menu.left, greaterThanOrEqualTo(panel.left - 0.01), reason: what);
  expect(menu.right, lessThanOrEqualTo(panel.right + 0.01), reason: what);
  expect(menu.bottom, lessThanOrEqualTo(panel.bottom + 0.01), reason: what);
  final before = _chatTaps;
  await tester.tapAt(_chatPoint);
  await tester.pumpAndSettle();
  expect(shown, findsNothing, reason: '$what — 채팅 쪽을 누르면 닫힌다');
  expect(_chatTaps, before, reason: '$what — 그 누름은 채팅에 가지 않는다');
}

/// 상세를 닫는다 — 대화상자 ✕·전체 화면 ←(키 todo-detail-close), 패널 안 화면은 머리의 ←(키 todo-page-back).
Future<void> _close(WidgetTester tester, _Opened opened) async {
  await tester.tap(
    _key(
      opened.mode == TodoViewMode.panel
          ? 'todo-page-back'
          : 'todo-detail-close',
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(_key('todo-detail-menu'));
  await tester.pumpAndSettle();
}

/// 열린 ••• 메뉴의 항목 키(위에서부터).
List<String> _menuKeys(WidgetTester tester) {
  final keys = [
    for (final k in [
      'todo-menu-favorite',
      'todo-menu-edit',
      'todo-menu-download',
      'todo-menu-delete',
    ])
      if (_key(k).evaluate().isNotEmpty) k,
  ];
  keys.sort(
    (a, b) =>
        tester.getTopLeft(_key(a)).dy.compareTo(tester.getTopLeft(_key(b)).dy),
  );
  return keys;
}

/// 메뉴 바깥(빈 곳)을 눌러 닫는다 — 패널 안 화면의 메뉴는 패널의 중첩 Navigator에 떠서 막이 패널만 덮으니 패널 안
/// 왼쪽 아래 구석을 누른다.
Future<void> _dismissMenu(WidgetTester tester) async {
  final host = _key('panel-host');
  await tester.tapAt(
    host.evaluate().isEmpty
        ? const Offset(5, 5)
        : tester.getRect(host).bottomLeft + const Offset(5, -5),
  );
  await tester.pumpAndSettle();
}

Finder _star(IconData icon) =>
    find.descendant(of: _key('todo-detail-star'), matching: find.byIcon(icon));

Finder _in(String key, String text) =>
    find.descendant(of: _key(key), matching: find.text(text));

/// 담당자 줄 [id]의 진척률(고르기 상자 또는 색 글자).
TodoProgressSelect _rowSelect(WidgetTester tester, String id) =>
    tester.widget<TodoProgressSelect>(
      find.descendant(
        of: _key('todo-detail-assignee-$id'),
        matching: find.byType(TodoProgressSelect),
      ),
    );

/// 내 진척률 고르기 상자(내 담당자 줄 또는 담당자 없는 할 일의 진행률 칸).
TodoProgressSelect _mySelect(WidgetTester tester) =>
    tester.widget<TodoProgressSelect>(_key('todo-detail-my-progress'));

/// 내 진척률 고르기 상자를 열고 [progress]를 고른다(응답은 기다리지 않는다).
Future<void> _pickProgress(WidgetTester tester, int progress) async {
  await tester.tap(_key('todo-detail-my-progress'));
  await tester.pumpAndSettle();
  await tester.tap(_key('todo-progress-option-$progress'));
  await tester.pump();
}

/// 즐겨찾기 요청을 붙잡아 두었다가 실패시키는 가짜 — 낙관적 표시와 되돌리기 시험용.
class _FailingFavoriteApi extends FakeTodoApi {
  _FailingFavoriteApi({super.todos}) : super(me: 'me');

  final gate = Completer<void>();

  @override
  Future<bool> setFavorite(String id, bool favorite) async {
    calls.add('setFavorite $id $favorite');
    await gate.future;
    throw const ApiException('권한이 없습니다.');
  }
}

/// 진척률 수정을 붙잡아 두는 가짜 — 응답 전 표시와 겹친 요청 시험용. [fail]이면 풀어 줄 때 실패한다(되돌리기 시험).
class _GatedUpdateApi extends FakeTodoApi {
  _GatedUpdateApi({super.todos, this.fail = false}) : super(me: 'me');

  final bool fail;
  final gate = Completer<void>();

  @override
  Future<Todo> update(String id, Map<String, dynamic> fields) async {
    await gate.future;
    if (fail) {
      calls.add('update $id ${fields.keys.join(',')}');
      throw const ApiException('서버 오류');
    }
    return super.update(id, fields);
  }
}

TodoAttachment _attachment(
  String id, {
  String? name,
  String kind = 'file',
  String? mime,
}) => TodoAttachment(
  id: id,
  kind: kind,
  fileUrl: '/files/$id',
  fileName: name,
  mimeType: mime,
);

List<String> _fileNames(Directory dir) =>
    dir.listSync().map((e) => e.path.split(RegExp(r'[\\/]')).last).toList()
      ..sort();

/// 나는 담당자 셋 중 하나(나 50 · 김철수 100 · 이영희 0 → 전체 50), 만든 사람은 김철수.
Map<String, dynamic> _threeAssignees({String id = 'a3', int me = 50}) =>
    todoJson(
      id: id,
      creatorId: 'u2',
      creatorName: '김철수',
      assignees: ['me', 'u2', 'u3'],
      assigneeProgress: {'me': me, 'u2': 100, 'u3': 0},
    );

const _modes = [TodoViewMode.dialog, TodoViewMode.page, TodoViewMode.panel];

void main() {
  // ────────────────────────── 머리·만든 사람 줄·••• 메뉴 ──────────────────────────
  group('만든 사람 줄 — ★ · ••• 메뉴', () {
    testWidgets(
      '아바타·"○○ 님이 할 일을 추가했습니다."·만든 시각, 오른쪽에 ★ 다음 •••(가로 점) — 대화상자 머리는 `할 일` + ✕만',
      (tester) async {
        final created = DateTime(2026, 10, 3, 9, 5);
        await _open(
          tester,
          json: todoJson(
            creatorId: 'u2',
            creatorName: '김철수',
            createdAt: created.millisecondsSinceEpoch,
          ),
        );
        expect(
          _in('todo-detail-created', '김철수 님이 할 일을 추가했습니다.'),
          findsOneWidget,
        );
        expect(
          _in('todo-detail-created', '2026/10/03 AM 9:05'),
          findsOneWidget,
        );
        // ★와 •••는 만든 사람 줄 오른쪽 끝에(★ 먼저).
        for (final k in ['todo-detail-star', 'todo-detail-menu']) {
          expect(
            find.descendant(of: _key('todo-detail-created'), matching: _key(k)),
            findsOneWidget,
          );
        }
        final star = tester.getRect(_key('todo-detail-star'));
        final menu = tester.getRect(_key('todo-detail-menu'));
        expect(star.right, lessThanOrEqualTo(menu.left));
        expect(menu.right, tester.getRect(_key('todo-detail-created')).right);
        expect(
          find.descendant(
            of: _key('todo-detail-menu'),
            matching: find.byIcon(Icons.more_horiz),
          ),
          findsOneWidget,
        );
        expect(find.byIcon(Icons.more_vert), findsNothing);
        // 대화상자 머리는 `할 일`과 ✕(만든 사람 줄 위).
        expect(_key('todo-detail-close'), findsOneWidget);
        expect(find.text('할 일'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('할 일')).dy,
          lessThan(tester.getTopLeft(_key('todo-detail-created')).dy),
        );
        expect(find.byType(TodoPageHeader), findsNothing);
      },
    );

    testWidgets('만든 사람 — 즐겨찾기 · 할 일 수정 · 할 일 삭제(빨강), 첨부가 없으면 파일 다운로드는 없다', (
      tester,
    ) async {
      await _open(tester, json: todoJson());
      await _openMenu(tester);
      expect(_menuKeys(tester), [
        'todo-menu-favorite',
        'todo-menu-edit',
        'todo-menu-delete',
      ]);
      expect(_in('todo-menu-favorite', '즐겨찾기'), findsOneWidget);
      expect(_in('todo-menu-edit', '할 일 수정'), findsOneWidget);
      final delete = tester.widget<Text>(_in('todo-menu-delete', '할 일 삭제'));
      expect(
        delete.style?.color,
        Theme.of(tester.element(_key('todo-menu-delete'))).colorScheme.error,
      );
    });

    testWidgets('만든 사람 + 첨부 — 즐겨찾기 · 할 일 수정 · 파일 다운로드 · 할 일 삭제 순서', (
      tester,
    ) async {
      await _open(tester, json: todoJson(attachmentCount: 2));
      await _openMenu(tester);
      expect(_menuKeys(tester), [
        'todo-menu-favorite',
        'todo-menu-edit',
        'todo-menu-download',
        'todo-menu-delete',
      ]);
      expect(_in('todo-menu-download', '파일 다운로드'), findsOneWidget);
    });

    testWidgets('담당자 — 즐겨찾기 · 할 일 수정(첨부가 있으면 파일 다운로드도), 삭제는 없다', (
      tester,
    ) async {
      await _open(
        tester,
        json: todoJson(creatorId: 'u2', assignees: ['me']),
      );
      await _openMenu(tester);
      expect(_menuKeys(tester), ['todo-menu-favorite', 'todo-menu-edit']);

      await _open(
        tester,
        json: todoJson(creatorId: 'u2', assignees: ['me'], attachmentCount: 1),
      );
      await _openMenu(tester);
      expect(_menuKeys(tester), [
        'todo-menu-favorite',
        'todo-menu-edit',
        'todo-menu-download',
      ]);
    });

    testWidgets('보는 사람 — 즐겨찾기만(첨부가 있으면 파일 다운로드도) — •••는 누구에게나 보인다', (
      tester,
    ) async {
      await _open(
        tester,
        json: todoJson(creatorId: 'u2', assignees: ['u3']),
      );
      expect(_key('todo-detail-star'), findsOneWidget);
      await _openMenu(tester);
      expect(_menuKeys(tester), ['todo-menu-favorite']);

      await _open(
        tester,
        json: todoJson(creatorId: 'u2', assignees: ['u3'], attachmentCount: 1),
      );
      await _openMenu(tester);
      expect(_menuKeys(tester), ['todo-menu-favorite', 'todo-menu-download']);
    });

    testWidgets('별 — 누르면 응답 전에 먼저 켜지고 setFavorite, 다시 누르면 끄고, 닫으면 true', (
      tester,
    ) async {
      final opened = await _open(tester, json: todoJson(id: 'f1'));
      final gate = Completer<void>();
      opened.api.favoriteGate = gate.future;
      expect(_star(Icons.star_border), findsOneWidget);
      await tester.tap(_key('todo-detail-star'));
      await tester.pump();
      expect(_star(Icons.star), findsOneWidget, reason: '서버 응답 전에 먼저');
      expect(opened.api.calls, contains('setFavorite f1 true'));
      expect(opened.api.todos.single['favorite'], isFalse, reason: '서버는 아직');
      gate.complete();
      await tester.pumpAndSettle();
      expect(_star(Icons.star), findsOneWidget);
      expect(opened.api.todos.single['favorite'], isTrue);

      await tester.tap(_key('todo-detail-star'));
      await tester.pumpAndSettle();
      expect(opened.api.calls, contains('setFavorite f1 false'));
      expect(_star(Icons.star_border), findsOneWidget);
      expect(opened.api.todos.single['favorite'], isFalse);

      await _close(tester, opened);
      expect(opened.result, isTrue, reason: '목록이 다시 받아 즐겨찾기 순서를 맞춘다');
    });

    testWidgets('••• → 즐겨찾기 / 즐겨찾기 해제 — 별과 같은 동작, 메뉴 글자도 바뀐다', (tester) async {
      final opened = await _open(tester, json: todoJson(id: 'f4'));
      await _openMenu(tester);
      expect(_in('todo-menu-favorite', '즐겨찾기'), findsOneWidget);
      await tester.tap(_key('todo-menu-favorite'));
      await tester.pumpAndSettle();
      expect(opened.api.calls, ['setFavorite f4 true']);
      expect(_star(Icons.star), findsOneWidget);

      await _openMenu(tester);
      expect(_in('todo-menu-favorite', '즐겨찾기 해제'), findsOneWidget);
      expect(
        find.descendant(
          of: _key('todo-menu-favorite'),
          matching: find.byIcon(Icons.star),
        ),
        findsOneWidget,
      );
      await tester.tap(_key('todo-menu-favorite'));
      await tester.pumpAndSettle();
      expect(opened.api.calls.last, 'setFavorite f4 false');
      expect(_star(Icons.star_border), findsOneWidget);
      await _close(tester, opened);
      expect(opened.result, isTrue);
    });

    testWidgets('별 — 실패하면 되돌리고 알린다(닫아도 바뀐 것 없음)', (tester) async {
      final json = todoJson(id: 'f2');
      final api = _FailingFavoriteApi(todos: [json]);
      final opened = await _open(tester, json: json, api: api);
      await tester.tap(_key('todo-detail-star'));
      await tester.pump();
      expect(_star(Icons.star), findsOneWidget, reason: '먼저 켜 보인다');
      api.gate.complete();
      await tester.pumpAndSettle();
      expect(_star(Icons.star_border), findsOneWidget, reason: '실패하면 되돌린다');
      expect(find.textContaining('즐겨찾기를 바꾸지 못했습니다'), findsOneWidget);
      await _close(tester, opened);
      expect(opened.result, isFalse);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('소켓 favorite(내 것) — 다시 받지 않고 별만 맞춘다', (tester) async {
      final changed = StreamController<Map<String, dynamic>>.broadcast();
      final opened = await _open(
        tester,
        json: todoJson(id: 'f3'),
        changed: changed.stream,
      );
      changed.add({'todoId': 'f3', 'kind': 'favorite', 'favorite': true});
      await tester.pumpAndSettle();
      expect(_star(Icons.star), findsOneWidget);
      expect(opened.api.callCount('get'), 0);
      // 다른 변경은 다시 받는다.
      opened.api.todos.single
        ..['favorite'] = true
        ..['title'] = '바뀐 제목';
      changed.add({'todoId': 'f3', 'kind': 'updated'});
      await tester.pumpAndSettle();
      expect(opened.api.callCount('get'), 1);
      expect(find.text('바뀐 제목'), findsOneWidget);
      expect(_star(Icons.star), findsOneWidget);
      await changed.close();
    });
  });

  // ────────────────────────── 상자 — 진행률·대화방·담당자·일정 ──────────────────────────
  group('상자 — 진행률 · 대화방 · 담당자 · 일정', () {
    testWidgets(
      '담당자 셋 중 나 — 진행률은 전체 %(굵게·진척률 색), 총 3명, 내 줄만 고르기 상자, 다른 사람은 색 글자',
      (tester) async {
        await _open(tester, json: _threeAssignees());
        final status = tester.widget<Text>(_key('todo-detail-status'));
        expect(status.data, '50%');
        expect(status.style?.fontWeight, FontWeight.w700);
        expect(
          status.style?.color,
          todoProgressColor(tester.element(_key('todo-detail-status')), 50),
        );
        expect(find.text('진행률'), findsOneWidget);
        expect(_key('todo-detail-assignee-summary'), findsOneWidget);
        expect(find.text('총 3명'), findsOneWidget);

        // 내 줄 — 고르기 상자(내 값), 이름 옆 (나).
        expect(
          find.descendant(
            of: _key('todo-detail-assignee-me'),
            matching: _key('todo-detail-my-progress'),
          ),
          findsOneWidget,
        );
        expect(_rowSelect(tester, 'me').progress, 50);
        expect(_rowSelect(tester, 'me').onSelected, isNotNull);
        expect(_in('todo-detail-assignee-me', '이름me'), findsOneWidget);
        expect(_in('todo-detail-assignee-me', '(나)'), findsOneWidget);
        expect(_in('todo-detail-assignee-me', '진행(50%)'), findsOneWidget);
        // 다른 사람 — 같은 자리에 색 글자만(고를 수 없다).
        for (final (id, progress, label) in const [
          ('u2', 100, '완료(100%)'),
          ('u3', 0, '대기(0%)'),
        ]) {
          expect(_rowSelect(tester, id).progress, progress);
          expect(_rowSelect(tester, id).onSelected, isNull);
          expect(_in('todo-detail-assignee-$id', label), findsOneWidget);
          expect(_in('todo-detail-assignee-$id', '(나)'), findsNothing);
        }
        // 서버 순서대로 한 줄에 한 명, 진척률은 줄 오른쪽 끝(줄마다 같은 자리).
        final ys = [
          for (final id in ['me', 'u2', 'u3'])
            tester.getTopLeft(_key('todo-detail-assignee-$id')).dy,
        ];
        expect(ys[0], lessThan(ys[1]));
        expect(ys[1], lessThan(ys[2]));
        for (final id in ['me', 'u2', 'u3']) {
          final select = find.descendant(
            of: _key('todo-detail-assignee-$id'),
            matching: find.byType(TodoProgressSelect),
          );
          expect(
            tester.getTopRight(select).dx,
            tester.getTopRight(_key('todo-detail-assignee-$id')).dx,
          );
        }
        // 예전 칩·안내는 없다.
        expect(find.text('내 진척률'), findsNothing);
        expect(_key('todo-progress-0'), findsNothing);
        expect(find.byType(ChoiceChip), findsNothing);
        expect(find.textContaining('담당자만'), findsNothing);
        expect(find.textContaining('수정할 수 있습니다'), findsNothing);
      },
    );

    testWidgets(
      '내 줄 고르기 — 메뉴(대기(0%)…완료(100%), 내 값 체크)에서 고르면 내 진척률만 보내고 전체 %는 서버 값으로',
      (tester) async {
        final opened = await _open(tester, json: _threeAssignees(id: 'p1'));
        await tester.tap(_key('todo-detail-my-progress'));
        await tester.pumpAndSettle();
        for (final (p, label) in const [
          (0, '대기(0%)'),
          (25, '진행(25%)'),
          (50, '진행(50%)'),
          (75, '진행(75%)'),
          (100, '완료(100%)'),
        ]) {
          expect(_in('todo-progress-option-$p', label), findsOneWidget);
          expect(
            find.descendant(
              of: _key('todo-progress-option-$p'),
              matching: find.byIcon(Icons.check),
            ),
            p == 50 ? findsOneWidget : findsNothing,
          );
        }
        await tester.tap(_key('todo-progress-option-100'));
        await tester.pumpAndSettle();
        expect(opened.api.lastUpdate, {'progress': 100});
        expect(_rowSelect(tester, 'me').progress, 100);
        // 나 100 · 김철수 100 · 이영희 0 → 서버가 다시 계산한 전체 67%.
        expect(tester.widget<Text>(_key('todo-detail-status')).data, '67%');
        await _close(tester, opened);
        expect(opened.result, isTrue);
      },
    );

    testWidgets('응답 전에 고른 값이 먼저 보이고, 그 사이 다른 값은 무시한다', (tester) async {
      final json = _threeAssignees(id: 'p3', me: 0);
      final api = _GatedUpdateApi(todos: [json]);
      await _open(tester, json: json, api: api);
      await _pickProgress(tester, 75);
      await tester.pumpAndSettle();
      expect(_mySelect(tester).progress, 75, reason: '서버 응답 전에 먼저');
      expect(
        tester.widget<Text>(_key('todo-detail-status')).data,
        '33%',
        reason: '전체는 서버 값을 기다린다',
      );
      await _pickProgress(tester, 100);
      await tester.pumpAndSettle();
      expect(_mySelect(tester).progress, 75, reason: '보내는 중에 고른 값은 무시');
      api.gate.complete();
      await tester.pumpAndSettle();
      expect(api.callCount('update'), 1);
      expect(api.lastUpdate, {'progress': 75});
      expect(_mySelect(tester).progress, 75);
      expect(tester.widget<Text>(_key('todo-detail-status')).data, '58%');
    });

    testWidgets('진척률을 바꾸지 못하면 토스트, 고르기 상자는 원래 값으로 돌아간다', (tester) async {
      final json = _threeAssignees(id: 'p4');
      final api = _GatedUpdateApi(todos: [json], fail: true);
      final opened = await _open(tester, json: json, api: api);
      await _pickProgress(tester, 75);
      await tester.pumpAndSettle();
      expect(_mySelect(tester).progress, 75, reason: '먼저 고른 값을 보인다');
      api.gate.complete();
      await tester.pumpAndSettle();
      expect(api.callCount('update'), 1);
      expect(find.textContaining('진척률을 바꾸지 못했습니다'), findsOneWidget);
      expect(_mySelect(tester).progress, 50);
      expect(tester.widget<Text>(_key('todo-detail-status')).data, '50%');
      await _close(tester, opened);
      expect(opened.result, isFalse);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets(
      '담당자 없는 내 할 일 — 진행률 칸 바로 옆에 고르기 상자, `담당자 없음`, 지금 값을 다시 고르면 보내지 않는다',
      (tester) async {
        final opened = await _open(
          tester,
          json: todoJson(id: 'p2', progress: 50),
        );
        expect(_key('todo-detail-status'), findsNothing, reason: '값 대신 상자');
        expect(_mySelect(tester).progress, 50);
        expect(_mySelect(tester).onSelected, isNotNull);
        final label = tester.getRect(find.text('진행률'));
        final select = tester.getRect(_key('todo-detail-my-progress'));
        expect(select.center.dy, closeTo(label.center.dy, 1));
        expect(select.left, greaterThan(label.right));
        expect(select.left - label.right, lessThan(20), reason: '바로 옆');
        expect(_key('todo-detail-no-assignee'), findsOneWidget);
        expect(find.text('담당자 없음'), findsOneWidget);
        expect(find.text('총 0명'), findsNothing);

        await _pickProgress(tester, 0);
        await tester.pumpAndSettle();
        expect(opened.api.lastUpdate, {'progress': 0});
        expect(_mySelect(tester).progress, 0);
        expect(_in('todo-detail-my-progress', '대기(0%)'), findsOneWidget);
        // 지금 값을 다시 고르면 보내지 않는다.
        await _pickProgress(tester, 0);
        await tester.pumpAndSettle();
        expect(opened.api.callCount('update'), 1);
      },
    );

    testWidgets('담당자가 아닌 만든 사람 — 고르기 상자 없이 색 글자만, 안내 문구 없음(수정은 된다)', (
      tester,
    ) async {
      await _open(
        tester,
        json: todoJson(assignees: ['u2', 'u3'], assigneeProgress: {'u2': 100}),
      );
      expect(_key('todo-detail-my-progress'), findsNothing);
      expect(_rowSelect(tester, 'u2').onSelected, isNull);
      expect(_rowSelect(tester, 'u3').onSelected, isNull);
      expect(tester.widget<Text>(_key('todo-detail-status')).data, '50%');
      expect(find.text('총 2명'), findsOneWidget);
      expect(find.text('담당자만 자신의 진척률을 바꿀 수 있습니다.'), findsNothing);
      expect(find.text('만든 사람과 담당자만 수정할 수 있습니다.'), findsNothing);
      await _openMenu(tester);
      expect(_key('todo-menu-edit'), findsOneWidget);
    });

    testWidgets('보는 사람 — 남의 개인 할 일은 진행률 % 글자와 `담당자 없음`만(고르기 상자·안내 없음)', (
      tester,
    ) async {
      await _open(tester, json: todoJson(creatorId: 'u2', progress: 25));
      expect(_key('todo-detail-my-progress'), findsNothing);
      expect(find.byType(TodoProgressSelect), findsNothing);
      expect(tester.widget<Text>(_key('todo-detail-status')).data, '25%');
      expect(find.text('담당자 없음'), findsOneWidget);
      expect(find.textContaining('수정할 수 있습니다'), findsNothing);
      expect(find.textContaining('담당자만'), findsNothing);
    });

    testWidgets('일정 — 🕐 기간(지난 기한·미완료는 빨강), ⏰ 알림(보낸 것은 흐리게), 없으면 둘 다 `없음`', (
      tester,
    ) async {
      await _open(
        tester,
        json: todoJson(
          startDate: '2019-12-20',
          dueDate: '2020-01-01',
          reminders: [
            {
              'id': 'r1',
              'remindAt': DateTime(2019, 12, 31, 18).millisecondsSinceEpoch,
              'sent': true,
            },
            {
              'id': 'r2',
              'remindAt': DateTime(2099, 1, 1, 17).millisecondsSinceEpoch,
              'sent': false,
            },
          ],
        ),
      );
      final theme = Theme.of(tester.element(_key('todo-detail-period')));
      final period = tester.widget<Text>(_key('todo-detail-period'));
      expect(period.data, '2019/12/20 ~ 2020/01/01');
      expect(period.style?.color, theme.colorScheme.error);
      expect(find.text('일정'), findsOneWidget);
      // 아이콘과 글자가 한 줄에.
      expect(
        tester.getCenter(find.byIcon(Icons.schedule)).dy,
        closeTo(tester.getCenter(_key('todo-detail-period')).dy, 5),
      );
      final sent = tester.widget<Text>(find.text('2019/12/31 오후 6:00 (알림 보냄)'));
      expect(sent.style?.color, theme.hintColor);
      final next = tester.widget<Text>(find.text('2099/01/01 오후 5:00'));
      expect(next.style?.color, isNot(theme.hintColor));
      expect(
        find.descendant(
          of: _key('todo-detail-reminders'),
          matching: find.byType(Text),
        ),
        findsNWidgets(2),
      );
      expect(_key('todo-detail-no-reminder'), findsNothing);

      // 날짜·알림이 없으면 둘 다 `없음`(흐리게), 다 끝난 할 일은 지난 기한이어도 빨갛지 않다.
      await _open(tester, json: todoJson());
      final none = tester.widget<Text>(_key('todo-detail-period'));
      expect(none.data, '없음');
      expect(none.style?.color, theme.hintColor);
      expect(_in('todo-detail-box', '없음'), findsNWidgets(2));
      expect(_key('todo-detail-no-reminder'), findsOneWidget);
      expect(find.byIcon(Icons.alarm), findsOneWidget);

      await _open(tester, json: todoJson(dueDate: '2020-01-01', progress: 100));
      expect(
        tester.widget<Text>(_key('todo-detail-period')).style?.color,
        isNot(theme.colorScheme.error),
      );
      // 다 끝나도 제목에 취소선은 없다(잔디).
      expect(
        tester.widget<Text>(_key('todo-detail-title')).style?.decoration,
        isNot(TextDecoration.lineThrough),
      );
    });

    testWidgets(
      '본문 순서 — 만든 사람 줄 → 제목 → 설명 → 상자[진행률 → 대화방 → 총 N명 → 담당자 → 일정 → 기간 → 알림] → 첨부 → 원본 메시지',
      (tester) async {
        await _open(
          tester,
          json: todoJson(
            title: '순서 확인',
            description: '설명 내용',
            startDate: '2026-10-01',
            dueDate: '2099-10-05',
            assignees: ['me', 'u2'],
            attachmentCount: 1,
            sourceMessageId: 'm1',
            reminders: [
              {
                'id': 'r1',
                'remindAt': DateTime(2099, 10, 4, 18).millisecondsSinceEpoch,
                'sent': false,
              },
            ],
          ),
          onOpenRoom: (room, {messageId}) {},
        );
        final order = <String, Finder>{
          '만든 사람': _key('todo-detail-created'),
          '제목': _key('todo-detail-title'),
          '설명': _key('todo-detail-description'),
          '진행률': _key('todo-detail-status'),
          '대화방': _key('todo-detail-room'),
          '총 N명': _key('todo-detail-assignee-summary'),
          '내 줄': _key('todo-detail-assignee-me'),
          '다른 담당자': _key('todo-detail-assignee-u2'),
          '일정': find.text('일정'),
          '기간': _key('todo-detail-period'),
          '알림': find.text('2099/10/04 오후 6:00'),
          '첨부': find.text('자료0.pdf'),
          '원본 메시지': _key('todo-detail-source'),
        };
        final names = order.keys.toList();
        for (var i = 1; i < names.length; i++) {
          expect(
            tester.getTopLeft(order[names[i]]!).dy,
            greaterThan(tester.getTopLeft(order[names[i - 1]]!).dy),
            reason: '${names[i - 1]} 다음에 ${names[i]}',
          );
        }
        // 진행률~알림은 테두리 상자 안, 첨부·원본 메시지는 상자 밖.
        for (final name in names.sublist(3, 11)) {
          expect(
            find.descendant(
              of: _key('todo-detail-box'),
              matching: order[name]!,
            ),
            findsOneWidget,
            reason: '$name은 상자 안',
          );
        }
        for (final name in ['제목', '설명', '첨부', '원본 메시지']) {
          expect(
            find.descendant(
              of: _key('todo-detail-box'),
              matching: order[name]!,
            ),
            findsNothing,
            reason: '$name은 상자 밖',
          );
        }
        final box = tester.widget<Container>(_key('todo-detail-box'));
        final decoration = box.decoration! as BoxDecoration;
        expect(decoration.borderRadius, BorderRadius.circular(12));
        expect(decoration.border, isNotNull);
        expect(find.text('2026/10/01 ~ 2099/10/05'), findsOneWidget);
        expect(find.text('나 님이 할 일을 추가했습니다.'), findsOneWidget);
      },
    );

    testWidgets('대화방 — 굵은 방 이름과 ›, 누르면 그 방을 열고 상세는 닫힌다(손잡이가 없으면 › 없음)', (
      tester,
    ) async {
      Room? opened;
      String? openedMessage = 'unset';
      await _open(
        tester,
        json: todoJson(),
        onOpenRoom: (room, {messageId}) {
          opened = room;
          openedMessage = messageId;
        },
      );
      expect(find.text('대화방'), findsOneWidget);
      final name = tester.widget<Text>(_in('todo-detail-room', '영업 토픽'));
      expect(name.style?.fontWeight, FontWeight.w700);
      expect(
        find.descendant(
          of: _key('todo-detail-room'),
          matching: find.byIcon(Icons.chevron_right),
        ),
        findsOneWidget,
      );
      await tester.tap(_key('todo-detail-room'));
      await tester.pumpAndSettle();
      expect(opened?.id, 'r1');
      expect(openedMessage, isNull);
      expect(find.byType(TodoDetail), findsNothing);

      await _open(tester, json: todoJson(sourceMessageId: 'm1'));
      expect(_in('todo-detail-room', '영업 토픽'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
      expect(_key('todo-detail-source'), findsNothing);
    });
  });

  // ────────────────────────── 수정·삭제·소켓 ──────────────────────────
  group('수정·삭제·소켓', () {
    testWidgets('수정 — ••• → 할 일 수정으로 편집 창이 열리고 저장하면 상세에 반영·알림', (tester) async {
      final opened = await _open(
        tester,
        json: todoJson(id: 'ed1', title: '옛 제목'),
      );
      await _openMenu(tester);
      await tester.tap(_key('todo-menu-edit'));
      await tester.pumpAndSettle();
      final editor = tester.widget<TodoEditor>(find.byType(TodoEditor));
      expect(editor.mode, TodoViewMode.dialog, reason: '상세와 같은 모양');
      expect(editor.editing?.id, 'ed1');
      await tester.enterText(_key('todo-title-field'), '새 제목');
      await tester.pump();
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(opened.api.lastUpdate, {'title': '새 제목'});
      expect(tester.widget<Text>(_key('todo-detail-title')).data, '새 제목');
      expect(find.text('할 일을 수정했습니다.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('삭제 — 확인을 거쳐 지우고 상세가 닫히며 true', (tester) async {
      final opened = await _open(tester, json: todoJson(id: 'del1'));
      await _openMenu(tester);
      await tester.tap(_key('todo-menu-delete'));
      await tester.pumpAndSettle();
      expect(find.textContaining('할 일을 삭제할까요?'), findsOneWidget);
      // 취소하면 아무 일도 없다.
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(opened.api.callCount('delete'), 0);
      expect(find.byType(TodoDetail), findsOneWidget);

      await _openMenu(tester);
      await tester.tap(_key('todo-menu-delete'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-confirm-delete'));
      await tester.pumpAndSettle();
      expect(opened.api.calls, contains('delete del1'));
      expect(find.byType(TodoDetail), findsNothing);
      expect(opened.result, isTrue);
      expect(find.text('할 일을 삭제했습니다.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('열려 있는 동안 지워지면(소켓 deleted) 알리고 닫힌다 — 다른 할 일 알림은 무시', (
      tester,
    ) async {
      final changed = StreamController<Map<String, dynamic>>.broadcast();
      final opened = await _open(
        tester,
        json: todoJson(id: 'gone'),
        changed: changed.stream,
      );
      changed.add({'todoId': 'other', 'kind': 'deleted'});
      await tester.pumpAndSettle();
      expect(find.byType(TodoDetail), findsOneWidget);
      changed.add({'todoId': 'gone', 'kind': 'deleted'});
      await tester.pumpAndSettle();
      expect(find.byType(TodoDetail), findsNothing);
      expect(find.text('이 할 일이 삭제되었습니다.'), findsOneWidget);
      expect(opened.result, isTrue);
      await tester.pump(const Duration(seconds: 3));
      await changed.close();
    });

    // 지워졌다는 알림은 상세 위에 다른 창이 떠 있을 때도 온다 — 맨 위 창이 아니라 상세를 닫아야 하고, 패널 안 화면에서는
    // 상세가 패널의 중첩 Navigator에, 삭제 확인은 루트 Navigator에 있다.
    for (final mode in _modes) {
      group('지워지면 위의 창까지 닫힌다 — ${mode.name}', () {
        testWidgets('수정 창을 띄운 채 — 묻지 않고 수정 창과 상세가 함께 닫히며 true', (tester) async {
          final changed = StreamController<Map<String, dynamic>>.broadcast();
          final opened = await _open(
            tester,
            json: todoJson(id: 'gone1', title: '지워질 할 일'),
            changed: changed.stream,
            mode: mode,
          );
          await _openMenu(tester);
          await tester.tap(_key('todo-menu-edit'));
          await tester.pumpAndSettle();
          expect(find.byType(TodoEditor), findsOneWidget);
          expect(tester.widget<TodoEditor>(find.byType(TodoEditor)).mode, mode);
          // 고치던 내용이 있어도 "버리고 닫을까요?"를 묻지 않는다 — 고칠 할 일이 없어졌다.
          await tester.enterText(_key('todo-title-field'), '고치던 제목');
          await tester.pump();

          changed.add({'todoId': 'gone1', 'kind': 'deleted'});
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byType(TodoEditor), findsNothing);
          expect(find.text('작성 취소'), findsNothing);
          expect(find.byType(TodoDetail), findsNothing);
          expect(_key('opener'), findsOneWidget);
          expect(opened.result, isTrue);
          expect(find.text('이 할 일이 삭제되었습니다.'), findsOneWidget);
          expect(opened.api.callCount('update'), 0);
          await tester.pump(const Duration(seconds: 3));
          await changed.close();
        });

        testWidgets(
          '수정 창의 "작성 취소" 확인을 띄운 채 — 확인 창도 수정 창·상세와 함께 닫힌다(패널은 확인 창이 루트에)',
          (tester) async {
            final changed = StreamController<Map<String, dynamic>>.broadcast();
            final opened = await _open(
              tester,
              json: todoJson(id: 'gone5', title: '지워질 할 일'),
              changed: changed.stream,
              mode: mode,
            );
            await _openMenu(tester);
            await tester.tap(_key('todo-menu-edit'));
            await tester.pumpAndSettle();
            await tester.enterText(_key('todo-title-field'), '고치던 제목');
            await tester.pump();
            // 닫으려다 "작성 취소" 확인이 뜬 채로 지워졌다는 알림이 온다.
            await tester.tap(
              _key(
                mode == TodoViewMode.panel
                    ? 'todo-page-back'
                    : 'todo-editor-close',
              ),
            );
            await tester.pumpAndSettle();
            expect(find.text('작성 취소'), findsOneWidget);
            if (mode == TodoViewMode.panel) {
              expect(
                find.descendant(
                  of: _key('panel-nav'),
                  matching: find.byType(AlertDialog),
                ),
                findsNothing,
                reason: '확인 창은 루트 Navigator에 뜬다',
              );
            }

            changed.add({'todoId': 'gone5', 'kind': 'deleted'});
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.text('작성 취소'), findsNothing);
            expect(find.byType(AlertDialog), findsNothing);
            expect(find.byType(TodoEditor), findsNothing);
            expect(find.byType(TodoDetail), findsNothing);
            expect(_key('opener'), findsOneWidget);
            expect(opened.result, isTrue);
            expect(opened.api.callCount('update'), 0);
            await tester.pump(const Duration(seconds: 3));
            await changed.close();
          },
        );

        testWidgets('삭제 확인을 띄운 채 — 확인 창은 [삭제] 없이 닫히고(DELETE 없음) 상세도 닫히며 true', (
          tester,
        ) async {
          final changed = StreamController<Map<String, dynamic>>.broadcast();
          final opened = await _open(
            tester,
            json: todoJson(id: 'gone2'),
            changed: changed.stream,
            mode: mode,
          );
          await _openMenu(tester);
          await tester.tap(_key('todo-menu-delete'));
          await tester.pumpAndSettle();
          expect(find.textContaining('할 일을 삭제할까요?'), findsOneWidget);

          changed.add({'todoId': 'gone2', 'kind': 'deleted'});
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.textContaining('할 일을 삭제할까요?'), findsNothing);
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.byType(TodoDetail), findsNothing);
          expect(_key('opener'), findsOneWidget);
          expect(opened.api.callCount('delete'), 0);
          expect(opened.result, isTrue);
          expect(find.text('이 할 일이 삭제되었습니다.'), findsOneWidget);
          expect(find.textContaining('삭제하지 못했습니다'), findsNothing);
          await tester.pump(const Duration(seconds: 3));
          await changed.close();
        });

        testWidgets('••• 메뉴를 펼친 채 — 메뉴와 상세가 닫힌다(같은 알림이 연달아 와도 아래 화면은 그대로)', (
          tester,
        ) async {
          final changed = StreamController<Map<String, dynamic>>.broadcast();
          final opened = await _open(
            tester,
            json: todoJson(id: 'gone3', attachmentCount: 1),
            changed: changed.stream,
            mode: mode,
          );
          await _openMenu(tester);
          expect(_key('todo-menu-edit'), findsOneWidget);

          changed
            ..add({'todoId': 'gone3', 'kind': 'deleted'})
            ..add({'todoId': 'gone3', 'kind': 'deleted'});
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(_key('todo-menu-edit'), findsNothing);
          expect(find.byType(TodoDetail), findsNothing);
          expect(opened.result, isTrue);
          expect(_key('opener'), findsOneWidget, reason: '상세 아래 화면까지 닫지 않는다');
          expect(find.text('이 할 일이 삭제되었습니다.'), findsOneWidget);
          await tester.pump(const Duration(seconds: 3));
          await changed.close();
        });

        testWidgets('진척률 메뉴를 펼친 채 — 메뉴와 상세가 닫힌다', (tester) async {
          final changed = StreamController<Map<String, dynamic>>.broadcast();
          final opened = await _open(
            tester,
            json: _threeAssignees(id: 'gone4'),
            changed: changed.stream,
            mode: mode,
          );
          await tester.tap(_key('todo-detail-my-progress'));
          await tester.pumpAndSettle();
          expect(_key('todo-progress-option-100'), findsOneWidget);

          changed.add({'todoId': 'gone4', 'kind': 'deleted'});
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(_key('todo-progress-option-100'), findsNothing);
          expect(find.byType(TodoDetail), findsNothing);
          expect(_key('opener'), findsOneWidget);
          expect(opened.result, isTrue);
          expect(opened.api.callCount('update'), 0);
          await tester.pump(const Duration(seconds: 3));
          await changed.close();
        });
      });
    }
  });

  // ────────────────────────── 패널 안 화면 ──────────────────────────
  group('패널 안 화면(PC 할 일 패널)', () {
    testWidgets('머리 `← 할 일 … ✕`(★·•••는 만든 사람 줄에), ←는 상세만 닫고 ✕는 패널 닫기', (
      tester,
    ) async {
      final opened = await _open(
        tester,
        json: _threeAssignees(id: 'pn1'),
        mode: TodoViewMode.panel,
      );
      final detail = find.byType(TodoDetail);
      expect(
        find.descendant(of: _key('panel-nav'), matching: detail),
        findsOneWidget,
      );
      expect(tester.getRect(detail), tester.getRect(_key('panel-host')));
      final header = find.byType(TodoPageHeader);
      expect(
        find.descendant(of: header, matching: find.text('할 일')),
        findsOneWidget,
      );
      for (final k in ['todo-page-back', 'todo-page-close']) {
        expect(find.descendant(of: header, matching: _key(k)), findsOneWidget);
      }
      for (final k in ['todo-detail-star', 'todo-detail-menu']) {
        expect(find.descendant(of: header, matching: _key(k)), findsNothing);
        expect(
          find.descendant(of: _key('todo-detail-created'), matching: _key(k)),
          findsOneWidget,
        );
      }
      expect(_key('todo-detail-close'), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(_key('todo-page-close'));
      await tester.pump();
      expect(opened.panelClosed, 1);

      await tester.tap(_key('todo-page-back'));
      await tester.pumpAndSettle();
      expect(detail, findsNothing);
      expect(opened.result, isFalse);
      expect(_key('opener'), findsOneWidget);
    });

    testWidgets('••• 메뉴·진척률 메뉴는 패널 안에, 내 진척률을 바꾸면 ←로 닫을 때 true', (
      tester,
    ) async {
      final opened = await _open(
        tester,
        json: _threeAssignees(id: 'pn2'),
        mode: TodoViewMode.panel,
      );
      await _openMenu(tester);
      expect(_menuKeys(tester), ['todo-menu-favorite', 'todo-menu-edit']);
      final host = tester.getRect(_key('panel-host'));
      final menuRect = tester.getRect(_key('todo-menu-edit'));
      expect(host.contains(menuRect.topLeft), isTrue);
      expect(host.contains(menuRect.bottomRight), isTrue);
      await _dismissMenu(tester);

      await _pickProgress(tester, 100);
      await tester.pumpAndSettle();
      expect(opened.api.lastUpdate, {'progress': 100});
      expect(_mySelect(tester).progress, 100);
      await _close(tester, opened);
      expect(opened.result, isTrue);
    });

    testWidgets('알림 토스트는 패널의 중첩 Overlay가 아니라 앱 맨 위 Overlay에 — 창 가운데 아래', (
      tester,
    ) async {
      final changed = StreamController<Map<String, dynamic>>.broadcast();
      final json = todoJson(id: 'pn3');
      final api = _FailingFavoriteApi(todos: [json]);
      await _open(
        tester,
        json: json,
        api: api,
        changed: changed.stream,
        mode: TodoViewMode.panel,
      );
      api.gate.complete();
      await tester.tap(_key('todo-detail-star'));
      await tester.pumpAndSettle();
      final failed = find.textContaining('즐겨찾기를 바꾸지 못했습니다');
      expect(failed, findsOneWidget);
      expect(
        find.descendant(of: _key('panel-nav'), matching: failed),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      // 창(1280) 가운데 — 패널(오른쪽 420) 안으로 밀려 있지 않다.
      expect(tester.getCenter(failed).dx, closeTo(640, 1));
      await tester.pump(const Duration(seconds: 3));

      changed.add({'todoId': 'pn3', 'kind': 'deleted'});
      await tester.pumpAndSettle();
      final gone = find.text('이 할 일이 삭제되었습니다.');
      expect(gone, findsOneWidget);
      expect(
        find.descendant(of: _key('panel-nav'), matching: gone),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
      await changed.close();
    });

    testWidgets('삭제 — 확인 창은 창 전체에(루트), 지우면 패널의 상세만 닫히고 true', (tester) async {
      final opened = await _open(
        tester,
        json: todoJson(id: 'pn4'),
        mode: TodoViewMode.panel,
      );
      await _openMenu(tester);
      await tester.tap(_key('todo-menu-delete'));
      await tester.pumpAndSettle();
      final confirm = find.byType(AlertDialog);
      expect(confirm, findsOneWidget);
      expect(
        find.descendant(of: _key('panel-nav'), matching: confirm),
        findsNothing,
      );
      await tester.tap(_key('todo-confirm-delete'));
      await tester.pumpAndSettle();
      expect(opened.api.calls, contains('delete pn4'));
      expect(find.byType(TodoDetail), findsNothing);
      expect(_key('opener'), findsOneWidget);
      expect(opened.result, isTrue);
      expect(find.text('할 일을 삭제했습니다.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('수정 — 편집 창도 패널 안에(같은 ✕), 저장하면 상세로 돌아와 반영', (tester) async {
      final opened = await _open(
        tester,
        json: todoJson(id: 'pn5', title: '처음 제목'),
        mode: TodoViewMode.panel,
      );
      await _openMenu(tester);
      await tester.tap(_key('todo-menu-edit'));
      await tester.pumpAndSettle();
      final editor = find.byType(TodoEditor);
      expect(tester.widget<TodoEditor>(editor).mode, TodoViewMode.panel);
      expect(
        find.descendant(of: _key('panel-nav'), matching: editor),
        findsOneWidget,
      );
      expect(tester.widget<TodoEditor>(editor).onClosePanel, isNotNull);
      await tester.enterText(_key('todo-title-field'), '고친 제목');
      await tester.pump();
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(editor, findsNothing);
      expect(tester.widget<Text>(_key('todo-detail-title')).data, '고친 제목');
      final toast = find.text('할 일을 수정했습니다.');
      expect(toast, findsOneWidget);
      expect(
        find.descendant(of: _key('panel-nav'), matching: toast),
        findsNothing,
      );
      await _close(tester, opened);
      expect(opened.result, isTrue);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  // ────────────────────────── 파일 다운로드 ──────────────────────────
  group('파일 다운로드', () {
    testWidgets('••• → 파일 다운로드 — 이 할 일의 첨부를 받고, 받는 동안 진행 막대(항목은 잠김)', (
      tester,
    ) async {
      final gate = Completer<void>();
      Todo? downloaded;
      await _open(
        tester,
        json: todoJson(id: 'dl1', attachmentCount: 3),
        download: (context, session, todo, {onProgress}) async {
          downloaded = todo;
          onProgress?.call(0, 3);
          await gate.future;
          onProgress?.call(3, 3);
        },
      );
      await _openMenu(tester);
      await tester.tap(_key('todo-menu-download'));
      await tester.pumpAndSettle();
      expect(downloaded?.id, 'dl1');
      expect(downloaded?.attachments, hasLength(3));
      expect(find.text('다운로드 중 0/3'), findsOneWidget);
      // 받는 동안에는 다시 고를 수 없다.
      await _openMenu(tester);
      expect(
        tester
            .widget<PopupMenuItem<String>>(_key('todo-menu-download'))
            .enabled,
        isFalse,
      );
      await _dismissMenu(tester);
      gate.complete();
      await tester.pumpAndSettle();
      expect(_key('todo-download-progress'), findsNothing);
      await _openMenu(tester);
      expect(
        tester
            .widget<PopupMenuItem<String>>(_key('todo-menu-download'))
            .enabled,
        isTrue,
      );
    });

    testWidgets('패널 안에서도 같다 — 받는 손잡이는 이 할 일과 진행 알림을 받는다', (tester) async {
      Todo? downloaded;
      final progress = <String>[];
      await _open(
        tester,
        json: todoJson(id: 'dl2', attachmentCount: 2),
        mode: TodoViewMode.panel,
        download: (context, session, todo, {onProgress}) async {
          downloaded = todo;
          for (var i = 0; i <= 2; i++) {
            onProgress?.call(i, 2);
            progress.add('$i/2');
          }
        },
      );
      await _openMenu(tester);
      await tester.tap(_key('todo-menu-download'));
      await tester.pumpAndSettle();
      expect(downloaded?.id, 'dl2');
      expect(progress, ['0/2', '1/2', '2/2']);
      expect(_key('todo-download-progress'), findsNothing, reason: '끝나면 막대도');
    });

    testWidgets('받다가 실패하면 토스트로 알린다', (tester) async {
      await _open(
        tester,
        json: todoJson(attachmentCount: 1),
        download: (context, session, todo, {onProgress}) async =>
            throw Exception('디스크 가득'),
      );
      await _openMenu(tester);
      await tester.tap(_key('todo-menu-download'));
      await tester.pumpAndSettle();
      expect(find.textContaining('다운로드하지 못했습니다'), findsOneWidget);
      expect(find.textContaining('디스크 가득'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets(
      'downloadTodoAttachments — 고른 폴더에 차례로 저장(겹치면 번호), 끝나면 실패 수까지 토스트',
      (tester) async {
        final dir = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('todo_dl_test_'),
        ))!;
        addTearDown(() => dir.deleteSync(recursive: true));
        final session = _session();
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (c) {
                context = c;
                return const Scaffold();
              },
            ),
          ),
        );
        final json = todoJson()
          ..['attachments'] = [
            {
              'id': 'a',
              'kind': 'file',
              'fileUrl': '/f/a',
              'fileName': '보고서.pdf',
            },
            {
              'id': 'b',
              'kind': 'file',
              'fileUrl': '/f/b',
              'fileName': '보고서.pdf',
            },
            {
              'id': 'c',
              'kind': 'image',
              'fileUrl': '/f/c',
              'fileName': '깨짐.png',
            },
          ];
        final progress = <String>[];
        var picked = 0;
        await tester.runAsync(
          () => downloadTodoAttachments(
            context,
            session,
            Todo.fromJson(json),
            pickFolder: () async {
              picked++;
              return dir.path;
            },
            fetch: (a) async {
              if (a.id == 'c') throw Exception('만료');
              return utf8.encode('내용 ${a.id}');
            },
            onProgress: (done, total) => progress.add('$done/$total'),
          ),
        );
        await tester.pump();
        expect(picked, 1, reason: '폴더는 한 번만 묻는다');
        expect(progress, ['0/3', '1/3', '2/3', '3/3']);
        expect(_fileNames(dir), ['보고서 (1).pdf', '보고서.pdf']);
        expect(
          File(
            '${dir.path}${Platform.pathSeparator}보고서.pdf',
          ).readAsStringSync(),
          '내용 a',
        );
        expect(
          find.text('2개를 다운로드했습니다. 1개는 실패했습니다. (${dir.path})'),
          findsOneWidget,
        );
        await tester.pump(const Duration(seconds: 5));
      },
    );

    testWidgets('downloadTodoAttachments — 폴더 고르기를 취소하면 아무것도 받지 않는다', (
      tester,
    ) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              context = c;
              return const Scaffold();
            },
          ),
        ),
      );
      var fetched = 0;
      await tester.runAsync(
        () => downloadTodoAttachments(
          context,
          _session(),
          Todo.fromJson(todoJson(attachmentCount: 2)),
          pickFolder: () async => null,
          fetch: (a) async {
            fetched++;
            return const [1];
          },
        ),
      );
      await tester.pump();
      expect(fetched, 0);
      expect(find.textContaining('다운로드'), findsNothing);
    });

    testWidgets('downloadTodoAttachments — "저장 위치 안 물어보기"면 묻지 않고 설정 폴더에', (
      tester,
    ) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('todo_dl_test_'),
      ))!;
      addTearDown(() => dir.deleteSync(recursive: true));
      final session = _session();
      session.settings
        ..downloadWithoutAsking = true
        ..downloadFolder = dir.path;
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              context = c;
              return const Scaffold();
            },
          ),
        ),
      );
      var picked = 0;
      await tester.runAsync(
        () => downloadTodoAttachments(
          context,
          session,
          Todo.fromJson(todoJson(attachmentCount: 2)),
          pickFolder: () async {
            picked++;
            return null;
          },
          fetch: (a) async => utf8.encode(a.id),
        ),
      );
      await tester.pump();
      expect(picked, 0);
      expect(_fileNames(dir), ['자료0.pdf', '자료1.pdf']);
      expect(find.text('2개를 다운로드했습니다. (${dir.path})'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets(
      'downloadTodoAttachments — 끝난 알림은 가까운(중첩) Overlay가 아니라 앱 맨 위 Overlay에',
      (tester) async {
        _size(tester, const Size(1280, 900));
        late BuildContext inner;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  const Expanded(child: SizedBox()),
                  SizedBox(
                    width: 420,
                    child: Navigator(
                      key: const ValueKey('panel-nav'),
                      onGenerateRoute: (_) => MaterialPageRoute(
                        builder: (c) {
                          inner = c;
                          return const Material();
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => downloadTodoAttachments(
            inner,
            _session(),
            Todo.fromJson(todoJson(attachmentCount: 1)),
            pickFolder: () async => Directory.systemTemp.path,
            fetch: (a) async => throw Exception('만료'),
          ),
        );
        await tester.pump();
        final toast = find.text('다운로드하지 못했습니다.');
        expect(toast, findsOneWidget);
        expect(
          find.descendant(of: _key('panel-nav'), matching: toast),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 5));
      },
    );

    test(
      'saveTodoAttachmentsToFolder — 덮어쓰지 않고 번호, 하나가 실패해도 계속, 진행 알림',
      () async {
        final dir = await Directory.systemTemp.createTemp('todo_dl_test_');
        addTearDown(() => dir.delete(recursive: true));
        // 이미 있는 같은 이름의 파일은 그대로 둔다.
        File(
          '${dir.path}${Platform.pathSeparator}견적서.pdf',
        ).writeAsStringSync('원래');
        final progress = <int>[];
        final summary = await saveTodoAttachmentsToFolder(
          attachments: [
            _attachment('a', name: '견적서.pdf'),
            _attachment('b', name: '견적서.pdf'),
            _attachment('c', name: '사진.png', kind: 'image'),
            _attachment('d', name: '메모'),
          ],
          folder: dir.path,
          fetch: (a) async {
            if (a.id == 'c') throw Exception('만료');
            return utf8.encode('내용 ${a.id}');
          },
          onProgress: (done, total) {
            expect(total, 4);
            progress.add(done);
          },
        );
        expect(summary.saved, 3);
        expect(summary.failed, 1);
        expect(summary.folder, dir.path);
        expect(progress, [0, 1, 2, 3, 4]);
        expect(_fileNames(dir), [
          '견적서 (1).pdf',
          '견적서 (2).pdf',
          '견적서.pdf',
          '메모',
        ]);
        String read(String name) => File(
          '${dir.path}${Platform.pathSeparator}$name',
        ).readAsStringSync();
        expect(read('견적서.pdf'), '원래');
        expect(read('견적서 (1).pdf'), '내용 a');
        expect(read('견적서 (2).pdf'), '내용 b');
        expect(read('메모'), '내용 d');
      },
    );

    test('todoAttachmentFileName — 못 쓰는 글자는 _로, 이름이 없으면 종류에 맞는 임시 이름', () {
      expect(
        todoAttachmentFileName(_attachment('a', name: 'a/b:c?.txt'), 0),
        'a_b_c_.txt',
      );
      expect(
        todoAttachmentFileName(_attachment('a', name: ' 회의록.docx '), 0),
        '회의록.docx',
      );
      expect(
        todoAttachmentFileName(
          _attachment('a', kind: 'image', mime: 'image/jpeg'),
          0,
        ),
        'todo_file_1.jpg',
      );
      expect(
        todoAttachmentFileName(
          _attachment('a', kind: 'image', mime: 'image/png'),
          2,
        ),
        'todo_file_3.png',
      );
      expect(
        todoAttachmentFileName(_attachment('a', name: '  ', kind: 'image'), 1),
        'todo_file_2.jpg',
      );
      expect(
        todoAttachmentFileName(_attachment('a', mime: 'application/pdf'), 0),
        'todo_file_1.pdf',
      );
      expect(todoAttachmentFileName(_attachment('a'), 4), 'todo_file_5.bin');
    });

    test('todoDownloadResultText — 받은 수, 실패 수, 폴더', () {
      const folder = r'C:\Downloads';
      expect(
        todoDownloadResultText(
          const TodoDownloadSummary(saved: 3, folder: folder),
        ),
        '3개를 다운로드했습니다. (C:\\Downloads)',
      );
      expect(
        todoDownloadResultText(
          const TodoDownloadSummary(saved: 2, failed: 1, folder: folder),
        ),
        '2개를 다운로드했습니다. 1개는 실패했습니다. (C:\\Downloads)',
      );
      expect(
        todoDownloadResultText(
          const TodoDownloadSummary(failed: 2, folder: folder),
        ),
        '다운로드하지 못했습니다.',
      );
      expect(
        todoDownloadResultText(const TodoDownloadSummary(saved: 1)),
        '1개를 다운로드했습니다.',
      );
    });
  });

  // ────────────────────────── 화면 크기 ──────────────────────────
  group('화면 크기', () {
    /// 긴 제목·설명·이름, 담당자 셋(나 포함), 첨부 셋, 지난 기한.
    Map<String, dynamic> longTodo() {
      final json = todoJson(
        id: 'long',
        title: '아주 긴 제목의 할 일 ' * 8,
        description: '설명 ' * 300,
        creatorId: 'u2',
        creatorName: '아주 긴 이름의 만든 사람 ' * 3,
        assignees: ['me', 'u2', 'u3'],
        attachmentCount: 3,
        dueDate: '2020-01-01',
        reminders: [
          {
            'id': 'r1',
            'remindAt': DateTime(2019, 12, 31, 18).millisecondsSinceEpoch,
            'sent': true,
          },
        ],
      );
      for (final a in (json['assignees'] as List).cast<Map>()) {
        a['name'] = '아주 긴 이름의 담당자 ${a['id']} ' * 4;
      }
      return json;
    }

    testWidgets('PC — 폭 560 대화상자, 짧은 할 일은 내용만큼만 높다', (tester) async {
      await _open(tester, json: todoJson(title: '짧은 할 일'));
      final card = find
          .descendant(of: find.byType(Dialog), matching: find.byType(Material))
          .first;
      expect(tester.getSize(card).width, 560);
      expect(tester.getSize(card).height, lessThan(720));
      expect(tester.takeException(), isNull);
    });

    testWidgets('PC — 긴 제목·이름·설명도 넘치지 않고, 길면 본문이 스크롤된다(지난 기한은 빨강)', (
      tester,
    ) async {
      await _open(tester, json: longTodo());
      final card = find
          .descendant(of: find.byType(Dialog), matching: find.byType(Material))
          .first;
      expect(tester.getSize(card).height, 720);
      expect(tester.takeException(), isNull);
      final period = tester.widget<Text>(_key('todo-detail-period'));
      expect(
        period.style?.color,
        Theme.of(tester.element(_key('todo-detail-period'))).colorScheme.error,
      );
      // 만든 사람 문구는 한 줄 말줄임, ★·•••는 밀려나지 않는다.
      expect(
        tester.getRect(_key('todo-detail-menu')).right,
        tester.getRect(_key('todo-detail-created')).right,
      );
    });

    testWidgets('모바일(390) — 전체 화면, 앱바는 `← 할 일`만(★·•••는 만든 사람 줄), 넘치지 않는다', (
      tester,
    ) async {
      final opened = await _open(
        tester,
        json: _threeAssignees(id: 'm1')
          ..['attachments'] = [
            for (var i = 0; i < 3; i++)
              {
                'id': 'att$i',
                'kind': 'file',
                'fileUrl': '/f/$i',
                'fileName': '자료$i.pdf',
              },
          ],
        mode: TodoViewMode.page,
      );
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
      final appBar = find.byType(AppBar);
      expect(
        find.descendant(of: appBar, matching: find.text('할 일')),
        findsOneWidget,
      );
      for (final k in ['todo-detail-star', 'todo-detail-menu']) {
        expect(find.descendant(of: appBar, matching: _key(k)), findsNothing);
        expect(
          find.descendant(of: _key('todo-detail-created'), matching: _key(k)),
          findsOneWidget,
        );
      }
      expect(_key('todo-detail-my-progress'), findsOneWidget);
      await tester.tap(_key('todo-detail-star'));
      await tester.pumpAndSettle();
      expect(opened.api.calls, contains('setFavorite m1 true'));
      await _openMenu(tester);
      expect(_menuKeys(tester), [
        'todo-menu-favorite',
        'todo-menu-edit',
        'todo-menu-download',
      ]);
      await tester.tapAt(const Offset(5, 400));
      await tester.pumpAndSettle();
      await _close(tester, opened);
      expect(opened.result, isTrue);
    });

    for (final (mode, size) in const [
      (TodoViewMode.panel, Size(1280, 900)),
      (TodoViewMode.page, Size(390, 844)),
      (TodoViewMode.page, Size(360, 780)),
    ]) {
      testWidgets(
        '긴 내용도 넘치지 않는다 — ${mode.name} ${mode == TodoViewMode.panel ? 420 : size.width.toInt()}',
        (tester) async {
          await _open(tester, json: longTodo(), mode: mode, size: size);
          expect(tester.takeException(), isNull);
          // 내 고르기 상자와 다른 사람의 색 글자는 줄 오른쪽 끝에 나란히.
          final rights = {
            for (final id in ['me', 'u2', 'u3'])
              tester
                  .getTopRight(
                    find.descendant(
                      of: _key('todo-detail-assignee-$id'),
                      matching: find.byType(TodoProgressSelect),
                    ),
                  )
                  .dx,
          };
          expect(rights, hasLength(1));
          // 맨 아래까지 내려도 넘치지 않는다.
          await tester.dragUntilVisible(
            find.text('자료2.pdf'),
            find.byType(SingleChildScrollView).last,
            const Offset(0, -300),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  });

  // ────────────────────────── 수정 — 바뀐 게 없으면 ──────────────────────────
  group('할 일 수정 — 아무것도 안 바꾸고 [저장하기]', () {
    for (final mode in _modes) {
      testWidgets('${mode.name} — 보내지 않고 수정 화면만 닫혀 상세로 돌아오며, "수정했습니다" 알림도 없다', (
        tester,
      ) async {
        final opened = await _open(
          tester,
          json: todoJson(id: 'same', title: '그대로 둘 할 일'),
          mode: mode,
        );
        await _openMenu(tester);
        await tester.tap(_key('todo-menu-edit'));
        await tester.pumpAndSettle();
        expect(find.byType(TodoEditor), findsOneWidget);
        // 잔디처럼 처음부터 누를 수 있다.
        expect(
          tester.widget<FilledButton>(_key('todo-submit')).onPressed,
          isNotNull,
        );
        await tester.tap(_key('todo-submit'));
        await tester.pumpAndSettle();
        expect(find.byType(TodoEditor), findsNothing);
        expect(find.byType(TodoDetail), findsOneWidget);
        expect(opened.api.callCount('update'), 0);
        expect(find.text('수정할 내용이 없습니다.'), findsNothing);
        expect(find.text('할 일을 수정했습니다.'), findsNothing);
        expect(
          tester.widget<Text>(_key('todo-detail-title')).data,
          '그대로 둘 할 일',
        );
        await _close(tester, opened);
        expect(opened.result, isFalse, reason: '바뀐 게 없으니 목록도 다시 받지 않는다');
      });
    }
  });

  // ────────────────────────── 첨부 — 사진 여러 장 ──────────────────────────
  group('첨부 — 사진 여러 장', () {
    testWidgets('상세의 사진 격자 아래에는 말풍선의 "전체 다운로드" 줄이 없다 — 전부 받기는 ••• → 파일 다운로드', (
      tester,
    ) async {
      final json = todoJson(id: 'img2', title: '사진 둘')
        ..['attachments'] = [
          for (final id in ['p1', 'p2'])
            {
              'id': id,
              'kind': 'image',
              'fileUrl': '/files/$id',
              'fileName': '$id.png',
              'fileSize': 100,
            },
        ];
      await _open(tester, json: json, mode: TodoViewMode.panel, settle: false);
      final grid = find.byType(ChatImageAttachments);
      expect(grid, findsOneWidget);
      expect(
        tester.widget<ChatImageAttachments>(grid).showDownloadAll,
        isFalse,
      );
      expect(find.byType(AllDownloadBar), findsNothing);
      expect(find.textContaining('전체 다운로드'), findsNothing);
      await tester.tap(_key('todo-detail-menu'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_key('todo-menu-download'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets(
      'ChatImageAttachments — 기본은 여러 장이면 "전체 다운로드", showDownloadAll: false면 없다(말풍선은 그대로)',
      (tester) async {
        final session = _session();
        const images = [
          MessageAttachment(id: 'a', kind: 'image', fileUrl: '/f/a.png'),
          MessageAttachment(id: 'b', kind: 'image', fileUrl: '/f/b.png'),
        ];
        Future<void> pump({required bool showDownloadAll}) async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: ChatImageAttachments(
                    session: session,
                    attachments: images,
                    showDownloadAll: showDownloadAll,
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
        }

        await pump(showDownloadAll: true);
        expect(find.text('전체 다운로드 (2)'), findsOneWidget);
        expect(
          ChatImageAttachments(
            session: session,
            attachments: images,
          ).showDownloadAll,
          isTrue,
          reason: '기본값',
        );
        await pump(showDownloadAll: false);
        expect(find.byType(AllDownloadBar), findsNothing);
        expect(find.textContaining('전체 다운로드'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 3));
      },
    );
  });

  // ────────────────────────── 패널 안 메뉴 — 바깥 누르기 ──────────────────────────
  group('패널 안 상세의 메뉴 — 창 전체 위에(자리는 패널 안), 채팅 쪽을 누르면 닫힘', () {
    testWidgets(
      '••• 메뉴·내 줄의 진척률 메뉴 — 패널 안에 뜨고 채팅 쪽을 누르면 닫히며 그 누름은 채팅에 가지 않는다',
      (tester) async {
        final opened = await _open(
          tester,
          json: _threeAssignees(id: 'out1'),
          mode: TodoViewMode.panel,
        );
        await _expectClosesFromChat(
          tester,
          what: '•••',
          open: () => _openMenu(tester),
          shown: _key('todo-menu-favorite'),
        );
        // ••• 메뉴는 단추 오른쪽 끝에 맞춰 왼쪽으로 편다(잔디).
        await _openMenu(tester);
        expect(
          _menuRect(tester, _key('todo-menu-favorite')).right,
          moreOrLessEquals(
            tester.getRect(_key('todo-detail-menu')).right,
            epsilon: 1,
          ),
        );
        await _dismissMenu(tester);
        await _expectClosesFromChat(
          tester,
          what: '내 진척률',
          open: () async {
            await tester.tap(_key('todo-detail-my-progress'));
            await tester.pumpAndSettle();
            // 줄 오른쪽 끝의 상자 — 상자 오른쪽 끝에 맞춰 왼쪽으로(잔디).
            expect(
              _menuRect(tester, _key('todo-progress-option-100')).right,
              moreOrLessEquals(
                tester.getRect(_key('todo-detail-my-progress')).right,
                epsilon: 1,
              ),
            );
          },
          shown: _key('todo-progress-option-100'),
        );
        expect(opened.api.callCount('update'), 0);
        expect(opened.api.callCount('setFavorite'), 0);
        expect(find.byType(TodoDetail), findsOneWidget, reason: '상세는 그대로');
        // 고르면 그대로 동작한다.
        await _pickProgress(tester, 100);
        await tester.pumpAndSettle();
        expect(opened.api.lastUpdate, {'progress': 100});
      },
    );

    testWidgets('담당자 없는 개인 할 일의 진척률 메뉴(진행률 칸)도 패널 안에 뜨고 채팅 쪽을 누르면 닫힌다', (
      tester,
    ) async {
      final opened = await _open(
        tester,
        json: todoJson(id: 'out2', title: '개인 할 일', progress: 25),
        mode: TodoViewMode.panel,
      );
      await _expectClosesFromChat(
        tester,
        what: '진행률 칸',
        open: () async {
          await tester.tap(_key('todo-detail-my-progress'));
          await tester.pumpAndSettle();
          // 상자가 패널 왼쪽에 있으니 패널 안에 띄울 때처럼 상자 왼쪽 끝에 맞춰 오른쪽으로 편다(창 기준이면 왼쪽으로 폈다).
          expect(
            _menuRect(tester, _key('todo-progress-option-50')).left,
            moreOrLessEquals(
              tester.getRect(_key('todo-detail-my-progress')).left,
              epsilon: 1,
            ),
          );
        },
        shown: _key('todo-progress-option-50'),
      );
      expect(opened.api.callCount('update'), 0);
    });

    testWidgets('지워졌다는 알림이 오면 창 전체에 떠 있던 메뉴도 닫히고 상세 아래 화면은 그대로', (
      tester,
    ) async {
      final changed = StreamController<Map<String, dynamic>>.broadcast();
      final opened = await _open(
        tester,
        json: _threeAssignees(id: 'out3'),
        changed: changed.stream,
        mode: TodoViewMode.panel,
      );
      await tester.tap(_key('todo-detail-my-progress'));
      await tester.pumpAndSettle();
      final option = _key('todo-progress-option-0');
      expect(
        Navigator.of(tester.element(option)),
        same(Navigator.of(tester.element(option), rootNavigator: true)),
      );
      changed.add({'todoId': 'out3', 'kind': 'deleted'});
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(option, findsNothing);
      expect(find.byType(TodoDetail), findsNothing);
      expect(_key('opener'), findsOneWidget);
      expect(opened.result, isTrue);
      await tester.pump(const Duration(seconds: 3));
      await changed.close();
    });
  });
}
