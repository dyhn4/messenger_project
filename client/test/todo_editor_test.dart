import 'dart:convert';
import 'dart:io';

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/models/todo.dart';
import 'package:client/models/uploaded_attachment.dart';
import 'package:client/screens/todo_editor_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/todo_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers/fake_todo_api.dart';

/// 할 일 생성·수정 창(잔디 생성 화면 모양) — 칸마다 이름표 대신 왼쪽 회색 아이콘(줄 순서: 대화방 → 제목 → 설명 → 파일
/// 업로드 → 담당자 → 기간 → 알림), 글자 수 카운터 없음, 대화방 칸 아래 안내(만들 때·고칠 때 문구), 가로 전체 `+ 파일 업로드
/// (선택)` + `N / 30`, 담당자 회색 상자 + `✏ 담당자 관리`, 기간 한 칸(누르면 칸을 덮지 않는 판 —
/// 기간 달력 + 시작 시간 · 그 밑 종료 시간, 판 안에서 펼치는 시간 목록), 알림 선택 상자(메뉴 세 가지), 저장
/// 단추 `저장하기`(대화상자·패널·모바일 앱 바), 새로 만들 때 담당자 기본값 나, 대화방을 바꾸면 첨부·담당자 초기화(지울 게
/// 있으면 확인 → 변경/취소), 보드 뷰 토픽 제외, 담당자로 고칠 때 담당자 칸 읽기 전용, 패널 안 화면(`← 할 일 … ✕`)과 그
/// 화면의 토스트. 서버는 가짜 API(helpers/fake_todo_api.dart)로 대신한다.

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

final _members = [_user('me', '송민수'), _user('u2', '김철수'), _user('u3', '이영희')];

Room _topic(String id, {String name = '영업 토픽', bool board = false}) =>
    Room.fromJson({
      'id': id,
      'teamId': 't1',
      'type': 'topic',
      'name': name,
      'members': _members,
      'createdAt': 1000,
      if (board) 'viewMode': 'board',
    });

/// 나와의 대화 — 멤버는 나 하나(개인 비공개 할 일).
Room _selfRoom() => Room.fromJson({
  'id': 'self',
  'teamId': 't1',
  'type': 'dm',
  'name': null,
  'members': [_user('me', '송민수')],
  'createdAt': 1000,
  'isSelf': true,
});

Session _session({List<Room>? rooms}) {
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
  session.name = '송민수';
  session.accountRole = AccountRole.member;
  final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  session.rooms.addAll(rooms ?? [_topic('r1'), _topic('r2', name: '개발 토픽')]);
  return session;
}

/// 버튼 하나로 생성·수정 창을 여는 화면 — 넓으면(PC) 대화상자, 좁으면(모바일) 전체 화면.
Future<void> _open(
  WidgetTester tester,
  Future<void> Function(BuildContext context) open, {
  Size size = const Size(900, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
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

/// 패널 하네스의 왼쪽(패널 밖) 채팅 자리를 누른 횟수 — 생성 화면이 띄운 목록·메뉴가 떠 있는 동안 채팅 쪽을 눌러도 그 누름이
/// 채팅에 가지 않는지 본다.
var _chatTaps = 0;

/// 패널 밖 채팅 자리의 한 점.
const _chatPoint = Offset(300, 450);

/// PC 할 일 패널 흉내 — 넓은 창 오른쪽 420 칸 안의 중첩 Navigator(키 panel-nav) 첫 화면 단추로 [open]을 부른다. 왼쪽은
/// 누르면 [_chatTaps]가 느는 채팅 자리.
Future<void> _openPanel(
  WidgetTester tester,
  Future<void> Function(BuildContext context) open,
) async {
  _chatTaps = 0;
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
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

Finder _key(String k) => find.byKey(ValueKey(k));

/// 대화방 칸에 보이는 방 이름.
Finder _roomFieldText(String name) =>
    find.descendant(of: _key('todo-room-field'), matching: find.text(name));

/// 저장 단추의 글자.
Finder _submitText(String text) =>
    find.descendant(of: _key('todo-submit'), matching: find.text(text));

TodoEditorState _state(WidgetTester tester) =>
    tester.state<TodoEditorState>(find.byType(TodoEditor));

/// 파일 업로드 단추 아래 `N / 30`의 글자.
String _fileCount(WidgetTester tester) => tester
    .widget<RichText>(
      find.descendant(
        of: _key('todo-file-count'),
        matching: find.byType(RichText),
      ),
    )
    .text
    .toPlainText();

UploadedAttachment _attachment(String name) => UploadedAttachment(
  isImage: false,
  url: '/files/$name',
  fileName: name,
  size: 2048,
);

/// 화면을 멈출 때까지 돌린다 — [settle]이 false면 짧게만(올리는 중인 첨부의 진행 막대는 끝없이 돌아서 pumpAndSettle을
/// 못 쓴다).
Future<void> _settle(WidgetTester tester, {bool settle = true}) async {
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
}

/// 대화방 칸을 눌러 목록에서 [name] 방을 고른다.
Future<void> _pickRoom(
  WidgetTester tester,
  String name, {
  bool settle = true,
}) async {
  await tester.tap(_key('todo-room-field'));
  await _settle(tester, settle: settle);
  // 칸에도 지금 방 이름이 보이므로 목록(맨 위에 뜬 것) 쪽을 누른다.
  await tester.tap(find.text(name).last);
  await _settle(tester, settle: settle);
}

Future<void> _submitWithTitle(WidgetTester tester, String title) async {
  await tester.enterText(_key('todo-title-field'), title);
  await tester.pump();
  await tester.tap(_key('todo-submit'));
  await tester.pumpAndSettle();
}

/// 펼친 기간 판(달력 + 시작/종료 시간).
final _popup = _key('todo-period-popup');

/// 기간 칸을 눌러 판을 연다 — 칸이 창 아래쪽이면 보이게 민 뒤.
Future<void> _openPeriod(WidgetTester tester) async {
  await tester.ensureVisible(_key('todo-period-field'));
  await tester.pumpAndSettle();
  await tester.tap(_key('todo-period-field'));
  await tester.pumpAndSettle();
}

/// 판 달력의 [day] 칸.
Finder _dayKey(DateTime day) =>
    _key('todo-period-day-${day.year}-${day.month}-${day.day}');

/// 펼친 기간 판의 달력에서 [day]를 누른다.
Future<void> _tapDay(WidgetTester tester, DateTime day) async {
  await tester.tap(_dayKey(day));
  await tester.pumpAndSettle();
}

/// 기간 칸에 보이는 글자(두 줄이면 한 줄로 이어서).
String _periodText(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(
        of: _key('todo-period-field'),
        matching: find.byType(Text),
      ),
    )
    .map((t) => t.data)
    .join(' ');

/// 달력 [day] 칸의 원을 채운 색(시작일·종료일) — 없으면 null.
Color? _dayFill(WidgetTester tester, DateTime day) {
  final circle = tester.widget<Container>(
    find.descendant(of: _dayKey(day), matching: find.byType(Container)).first,
  );
  return (circle.decoration as BoxDecoration?)?.color;
}

/// 달력 [day] 칸에 기간 띠가 깔렸는지.
bool _hasBand(WidgetTester tester, DateTime day) => tester
    .widgetList<ColoredBox>(
      find.descendant(of: _dayKey(day), matching: find.byType(ColoredBox)),
    )
    .any((b) => b.color.a > 0);

/// 판이 화면([screen]) 안에 있고 기간 칸을 덮지 않는다(칸 바로 아래나 위).
void _expectPopupBeside(WidgetTester tester, Size screen) {
  final popup = tester.getRect(_popup);
  final field = tester.getRect(_key('todo-period-field'));
  expect(popup.overlaps(field), isFalse, reason: '칸을 덮지 않는다');
  expect(
    popup.top >= field.bottom || popup.bottom <= field.top,
    isTrue,
    reason: '칸 바로 아래나 위',
  );
  expect(popup.left, moreOrLessEquals(field.left, epsilon: 0.5));
  expect(popup.left, greaterThanOrEqualTo(0));
  expect(popup.right, lessThanOrEqualTo(screen.width));
  expect(popup.top, greaterThanOrEqualTo(0));
  expect(popup.bottom, lessThanOrEqualTo(screen.height));
}

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

/// 상자(InkWell 등) 안 첫 Container의 테두리 색.
Color _borderOf(WidgetTester tester, Finder box) {
  final container = tester.widget<Container>(
    find.descendant(of: box, matching: find.byType(Container)).first,
  );
  final border = (container.decoration! as BoxDecoration).border! as Border;
  return border.top.color;
}

const _resetMessage = '대화방을 변경하면\n첨부한 파일과 담당자 정보가 초기화됩니다.';

/// 대화방 칸 아래 안내(잔디 생성 화면과 같은 자리) — 만들 때 / 고칠 때.
const _createRoomHint = '할 일 생성 후에는 대화방 변경이 불가능합니다.';
const _editRoomHint = '한 번 만든 할 일은 다른 대화방으로 옮길 수 없습니다.';

/// 날짜를 새로 고를 때 채우는 시간이 지금에 따라 달라 — 시험은 시계를 2026/10/04 오전 10:07로 고정한다(채우는 값은
/// 그다음 15분 단위 오전 10:15).
final _fixedNow = DateTime(2026, 10, 4, 10, 7);

void main() {
  setUp(() => todoClock = () => _fixedNow);
  tearDown(() => todoClock = DateTime.now);
  // ────────────────────────── 모양·순서·문구 ──────────────────────────
  group('모양·순서·문구', () {
    testWidgets(
      '줄 순서는 대화방 → 제목 → 설명 → 파일 업로드 → 담당자 → 기간 → 알림 — 이름표 대신 왼쪽 회색 아이콘(20, 한 세로줄), '
      '입력은 제 아이콘 오른쪽, 한 줄짜리 칸은 모두 높이 50',
      (tester) async {
        final session = _session();
        await _open(
          tester,
          (c) => showTodoEditor(
            c,
            session: session,
            room: session.rooms.first,
            api: FakeTodoApi(me: 'me'),
          ),
        );
        const rows = [
          ('room', Icons.chat_bubble_outline, '대화방', 'todo-room-field'),
          ('title', Icons.title, '제목', 'todo-title-field'),
          ('description', Icons.format_quote, '설명', 'todo-description-field'),
          ('files', Icons.insert_drive_file_outlined, '파일', 'todo-attach'),
          ('assignees', Icons.people_outline, '담당자', 'todo-assignee-box'),
          ('period', Icons.schedule, '기간', 'todo-period-field'),
          ('reminders', Icons.alarm, '알림', 'todo-reminder-add'),
        ];
        final scheme = Theme.of(
          tester.element(find.byType(TodoEditor)),
        ).colorScheme;
        double? iconLeft;
        double? fieldLeft;
        Rect? above;
        for (final (id, icon, label, field) in rows) {
          final iconFinder = _key('todo-label-$id');
          final widget = tester.widget<Icon>(iconFinder);
          expect(widget.icon, icon, reason: id);
          expect(widget.size, 20, reason: id);
          expect(widget.color, scheme.outline, reason: '$id — 회색');
          expect(widget.semanticLabel, label, reason: '화면 읽기용 이름표');
          final iconRect = tester.getRect(iconFinder);
          final fieldRect = tester.getRect(_key(field));
          // 아이콘은 그 줄 입력 칸의 첫 줄(높이 50) 가운데, 입력은 아이콘 오른쪽에서 시작한다.
          expect(
            iconRect.center.dy,
            moreOrLessEquals(fieldRect.top + 25, epsilon: 0.5),
            reason: id,
          );
          expect(fieldRect.left, greaterThan(iconRect.right), reason: id);
          iconLeft ??= iconRect.left;
          fieldLeft ??= fieldRect.left;
          expect(iconRect.left, iconLeft, reason: '아이콘은 한 세로줄');
          expect(fieldRect.left, fieldLeft, reason: '입력 칸 왼쪽 끝이 나란하다');
          if (above != null) {
            expect(fieldRect.top, greaterThan(above.bottom), reason: id);
          }
          above = fieldRect;
        }
        for (final k in [
          'todo-room-field',
          'todo-title-field',
          'todo-attach',
          'todo-period-field',
          'todo-reminder-add',
        ]) {
          expect(tester.getSize(_key(k)).height, 50, reason: k);
        }
        // 이름표 글자·글자 수 카운터는 없다(글자 수 한도는 그대로).
        for (final text in ['대화방', '제목', '설명', '파일 첨부', '담당자', '기한', '알림 일정']) {
          expect(find.text(text), findsNothing, reason: '이름표 "$text"');
        }
        expect(find.text('0/$todoTitleMaxLength'), findsNothing);
        expect(find.text('0/$todoDescriptionMaxLength'), findsNothing);
        expect(find.text('1/$todoAssigneesMaxCount'), findsNothing);
        expect(find.text('0/$todoRemindersMaxCount'), findsNothing);
        expect(
          tester.widget<TextField>(_key('todo-title-field')).maxLength,
          todoTitleMaxLength,
        );
        expect(
          tester.widget<TextField>(_key('todo-description-field')).maxLength,
          todoDescriptionMaxLength,
        );
        expect(find.text('제목을 입력하세요'), findsOneWidget);
        expect(find.text('설명을 입력하세요 (선택)'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '대화방 칸 바로 아래 안내 — 만들 때는 "할 일 생성 후에는 대화방 변경이 불가능합니다."(직접 고를 때·메시지에서 열어 잠겼을 때 '
      '모두), 고칠 때는 옮길 수 없다는 안내',
      (tester) async {
        final session = _session();
        final json = todoJson(id: 'e1', title: '고칠 할 일');
        final api = FakeTodoApi(me: 'me', todos: [json]);

        /// 안내가 [field](대화방 칸) 바로 아래·제목 칸 위에 작은 흐린 글씨로 [text]인지.
        void expectHint(String text, String field) {
          final hint = _key('todo-room-hint');
          expect(
            find.descendant(of: hint, matching: find.text(text)),
            findsOneWidget,
          );
          final top = tester.getTopLeft(hint).dy;
          expect(
            top,
            greaterThanOrEqualTo(tester.getBottomLeft(_key(field)).dy),
          );
          expect(top, lessThan(tester.getTopLeft(_key('todo-title-field')).dy));
          expect(
            tester.getTopLeft(hint).dx,
            tester.getTopLeft(_key(field)).dx,
            reason: '칸과 왼쪽 끝이 같다',
          );
          final style = tester.widget<Text>(find.text(text)).style;
          expect(style?.fontSize, 12);
          expect(
            style?.color,
            Theme.of(tester.element(find.text(text))).hintColor,
          );
        }

        // 대화방 없이 연 창 — 고르기 전에 미리 알린다.
        await _open(
          tester,
          (c) => showTodoEditor(c, session: session, api: api),
        );
        expectHint(_createRoomHint, 'todo-room-field');
        expect(find.text(_editRoomHint), findsNothing);
        await _pickRoom(tester, '영업 토픽');
        expectHint(_createRoomHint, 'todo-room-field');
        // 방을 골라 "쓰던 내용"이 생겼으니 닫을 때 한 번 묻는다.
        await tester.tap(_key('todo-editor-close'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, '닫기'));
        await tester.pumpAndSettle();
        expect(find.byType(TodoEditor), findsNothing);

        // 메시지·알림에서 열어 대화방이 잠긴 창.
        await _open(
          tester,
          (c) => showTodoEditor(
            c,
            session: session,
            room: session.rooms.first,
            lockRoom: true,
            initialTitle: '메시지 본문',
            sourceMessageId: 'm1',
            api: api,
          ),
        );
        expectHint(_createRoomHint, 'todo-room-locked');
        expect(
          find.descendant(
            of: _key('todo-room-locked'),
            matching: find.byIcon(Icons.lock_outline),
          ),
          findsOneWidget,
        );
        expect(tester.getSize(_key('todo-room-locked')).height, 50);
        await tester.tap(_key('todo-editor-close'));
        await tester.pumpAndSettle();
        expect(find.byType(TodoEditor), findsNothing);

        // 고치기 — 칸이 잠긴 까닭.
        await _open(
          tester,
          (c) => showTodoEditor(
            c,
            session: session,
            editing: Todo.fromJson(json),
            api: api,
          ),
        );
        expectHint(_editRoomHint, 'todo-room-locked');
        expect(find.text(_createRoomHint), findsNothing);
      },
    );

    testWidgets(
      '저장 단추는 만들 때도 고칠 때도 "저장하기" — 대화상자 머리는 할 일 생성 / 할 일 수정 + ✕(아이콘 없음)',
      (tester) async {
        final session = _session();
        final json = todoJson(id: 'e1', title: '고칠 할 일');
        final api = FakeTodoApi(me: 'me', todos: [json]);
        await _open(
          tester,
          (c) => showTodoEditor(
            c,
            session: session,
            room: session.rooms.first,
            api: api,
          ),
        );
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.text('할 일 생성'), findsOneWidget);
        expect(find.byIcon(Icons.checklist_rounded), findsNothing);
        expect(_submitText('저장하기'), findsOneWidget);
        expect(find.text('저장'), findsNothing);
        expect(find.text('만들기'), findsNothing);
        // [취소][저장하기]는 오른쪽 끝에 이 차례로.
        final cancel = find.widgetWithText(TextButton, '취소');
        expect(
          tester.getTopRight(cancel).dx,
          lessThan(tester.getTopLeft(_key('todo-submit')).dx),
        );
        await tester.tap(_key('todo-editor-close'));
        await tester.pumpAndSettle();

        await _open(
          tester,
          (c) => showTodoEditor(
            c,
            session: session,
            editing: Todo.fromJson(json),
            api: api,
          ),
        );
        expect(find.text('할 일 수정'), findsOneWidget);
        expect(_submitText('저장하기'), findsOneWidget);
      },
    );

    testWidgets('모바일(390)은 전체 화면 — 앱 바의 단추도 "저장하기"이고 넘치지 않는다', (tester) async {
      final session = _session();
      await _open(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          initialAttachments: [_attachment('아주_긴_이름의_견적서_최종_수정본_v3.pdf')],
          api: FakeTodoApi(me: 'me'),
        ),
        size: const Size(390, 844),
      );
      expect(find.byType(Dialog), findsNothing);
      final bar = find.byType(AppBar);
      expect(
        find.descendant(of: bar, matching: find.text('할 일 생성')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: bar, matching: _key('todo-submit')),
        findsOneWidget,
      );
      expect(_submitText('저장하기'), findsOneWidget);
      expect(_key('todo-assignee-chip-me'), findsOneWidget);
      expect(
        find.descendant(
          of: _key('todo-room-hint'),
          matching: find.text(_createRoomHint),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('모바일(360) 수정 — 담당자 셋·기간·알림이 모두 있어도 넘치지 않는다', (tester) async {
      final session = _session();
      final json = todoJson(
        id: 'e1',
        title: '견적서 보내기',
        startDate: '2099-12-28',
        dueDate: '2100-01-10',
        assignees: ['me', 'u2', 'u3'],
        attachmentCount: 2,
        reminders: [
          {
            'id': 'rm1',
            'remindAt': DateTime(2100, 1, 9, 18).millisecondsSinceEpoch,
          },
        ],
      );
      await _open(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          editing: Todo.fromJson(json),
          api: FakeTodoApi(me: 'me', todos: [json]),
        ),
        size: const Size(360, 780),
      );
      await tester.ensureVisible(_key('todo-reminder-0'));
      await tester.pumpAndSettle();
      expect(_key('todo-period-clear'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // ────────────────────────── 파일 업로드 ──────────────────────────
  group('파일 업로드', () {
    testWidgets(
      '가로 전체 옅은 단추 "+ 파일 업로드 (선택)", 그 오른쪽 아래 "N / 30"(N 굵게), 붙인 파일은 그 아래 한 줄씩 — x로 빼면 수가 준다',
      (tester) async {
        final session = _session();
        final api = FakeTodoApi(me: 'me');
        await _open(
          tester,
          (c) => showTodoEditor(
            c,
            session: session,
            room: session.rooms.first,
            initialAttachments: [
              _attachment('견적서.pdf'),
              _attachment('제안서.pptx'),
            ],
            api: api,
          ),
        );
        final attach = _key('todo-attach');
        expect(
          find.descendant(of: attach, matching: find.text('파일 업로드 (선택)')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: attach, matching: find.byIcon(Icons.add)),
          findsOneWidget,
        );
        final theme = Theme.of(tester.element(attach));
        final button = tester.widget<ButtonStyleButton>(attach);
        expect(button.onPressed, isNotNull);
        expect(
          button.style?.backgroundColor?.resolve({}),
          theme.colorScheme.surfaceContainerHighest,
          reason: '옅은 회색 바탕',
        );
        // 가로 전체 — 제목 칸과 같은 폭·왼쪽 끝.
        final attachRect = tester.getRect(attach);
        final titleRect = tester.getRect(_key('todo-title-field'));
        expect(attachRect.width, titleRect.width);
        expect(attachRect.left, titleRect.left);

        // N / 30 — 단추 바로 아래 오른쪽 끝, N은 굵게.
        expect(_fileCount(tester), '2 / $todoAttachmentsMaxCount');
        final countRect = tester.getRect(_key('todo-file-count'));
        expect(countRect.top, greaterThanOrEqualTo(attachRect.bottom));
        final count = tester.widget<RichText>(
          find.descendant(
            of: _key('todo-file-count'),
            matching: find.byType(RichText),
          ),
        );
        expect(count.textAlign, TextAlign.right);
        expect(countRect.right, attachRect.right);
        TextStyle? styleOf(String part) {
          TextStyle? found;
          count.text.visitChildren((span) {
            if (span is TextSpan && span.text == part) {
              found = span.style;
              return false;
            }
            return true;
          });
          return found;
        }

        expect(styleOf('2')?.fontWeight, FontWeight.w700);
        expect(styleOf(' / $todoAttachmentsMaxCount')?.fontWeight, isNull);

        // 붙인 파일은 수 아래에 한 줄에 하나(가로 전체).
        final quote = find.text('견적서.pdf');
        final deck = find.text('제안서.pptx');
        expect(tester.getTopLeft(quote).dy, greaterThan(countRect.bottom));
        expect(
          tester.getTopLeft(deck).dy,
          greaterThan(tester.getBottomLeft(quote).dy),
        );
        await tester.ensureVisible(deck);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('첨부 빼기').last);
        await tester.pumpAndSettle();
        expect(deck, findsNothing);
        expect(_fileCount(tester), '1 / $todoAttachmentsMaxCount');
        await _submitWithTitle(tester, '첨부 하나');
        expect(api.lastCreateAttachments.single.fileName, '견적서.pdf');
      },
    );

    testWidgets('30개를 채우면 단추가 꺼지고, 더 붙이면 알린다', (tester) async {
      final session = _session();
      await _open(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          lockRoom: true,
          initialAttachments: [
            for (var i = 0; i < 31; i++) _attachment('파일$i.txt'),
          ],
          api: FakeTodoApi(me: 'me'),
        ),
      );
      final state = _state(tester);
      expect(state.attachmentCount, 30, reason: '31개를 줘도 30개만');
      expect(_fileCount(tester), '30 / 30');
      expect(
        tester.widget<ButtonStyleButton>(_key('todo-attach')).onPressed,
        isNull,
      );
      state.addFiles([File('nope.txt')]);
      await tester.pump();
      expect(state.attachmentCount, 30);
      expect(find.text('첨부 파일은 30개까지 올릴 수 있습니다.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  // ────────────────────────── 담당자 ──────────────────────────
  group('담당자 — 회색 상자 + ✏ 담당자 관리, 기본값 나', () {
    testWidgets(
      '담당자 칩은 옅은 회색 상자 안, 상자 오른쪽 아래 글자 단추 "✏ 담당자 관리" — 고르는 창 제목도 "담당자 관리"(나는 체크된 채로)',
      (tester) async {
        final session = _session();
        final api = FakeTodoApi(me: 'me');
        await _open(
          tester,
          (c) => showTodoEditor(
            c,
            session: session,
            room: session.rooms.first,
            api: api,
          ),
        );
        final box = _key('todo-assignee-box');
        final theme = Theme.of(tester.element(box));
        final decoration =
            tester.widget<Container>(box).decoration! as BoxDecoration;
        expect(decoration.color, theme.colorScheme.surfaceContainerHighest);
        expect(
          find.descendant(of: box, matching: _key('todo-assignee-chip-me')),
          findsOneWidget,
        );
        final add = _key('todo-assignee-add');
        expect(tester.widget(add), isA<TextButton>());
        expect(
          find.descendant(of: add, matching: find.text('담당자 관리')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: add, matching: find.byIcon(Icons.edit)),
          findsOneWidget,
        );
        // 상자 바로 아래, 오른쪽 끝에 붙는다.
        final boxRect = tester.getRect(box);
        final addRect = tester.getRect(add);
        expect(addRect.top, greaterThanOrEqualTo(boxRect.bottom));
        expect(addRect.right, boxRect.right);
        expect(addRect.left, greaterThan(boxRect.center.dx));
        expect(find.text('담당자 선택'), findsNothing);

        await tester.ensureVisible(add);
        await tester.pumpAndSettle();
        await tester.tap(add);
        await tester.pumpAndSettle();
        final picker = find.byType(AlertDialog);
        expect(
          find.descendant(of: picker, matching: find.text('담당자 관리')),
          findsOneWidget,
        );
        bool checked(String id) => tester
            .widget<CheckboxListTile>(_key('todo-assignee-option-$id'))
            .value!;
        expect(checked('me'), isTrue, reason: '기본 담당자(나)');
        expect(checked('u2'), isFalse);
        expect(
          find.descendant(of: picker, matching: find.text('송민수 (나)')),
          findsOneWidget,
        );
        await tester.tap(_key('todo-assignee-option-u2'));
        await tester.pump();
        await tester.tap(_key('todo-assignee-ok'));
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: box, matching: _key('todo-assignee-chip-me')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: box, matching: _key('todo-assignee-chip-u2')),
          findsOneWidget,
        );
        await _submitWithTitle(tester, '둘이 하는 일');
        expect(api.lastCreate!['assigneeIds'], ['me', 'u2']);
      },
    );

    testWidgets('대화방을 주고 열면 처음부터 내가 담당자 — 그대로 저장하면 assigneeIds에 내가 들어간다', (
      tester,
    ) async {
      final session = _session();
      final api = FakeTodoApi(me: 'me');
      await _open(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          api: api,
        ),
      );
      expect(
        find.descendant(
          of: _key('todo-assignee-chip-me'),
          matching: find.text('송민수 (나)'),
        ),
        findsOneWidget,
      );
      await _submitWithTitle(tester, '견적서 보내기');
      expect(api.lastCreateRoomId, 'r1');
      expect(api.lastCreate!['assigneeIds'], ['me']);
      // 만들어진 할 일은 나에게 지정된 할 일이다(나의 할 일·내 진척률).
      final created = Todo.fromJson(api.todos.single);
      expect(created.isAssignee('me'), isTrue);
      expect(created.canSetProgress, isTrue);
    });

    testWidgets(
      '기본 담당자는 지울 수 있다 — 빼면 상자에 "담당자를 지정하지 않았습니다.", 저장하면 담당자 없이 만들어진다',
      (tester) async {
        final session = _session();
        final api = FakeTodoApi(me: 'me');
        await _open(
          tester,
          (c) => showTodoEditor(
            c,
            session: session,
            room: session.rooms.first,
            api: api,
          ),
        );
        final chip = tester.widget<InputChip>(_key('todo-assignee-chip-me'));
        expect(chip.onDeleted, isNotNull);
        chip.onDeleted!();
        await tester.pump();
        expect(_key('todo-assignee-chip-me'), findsNothing);
        expect(
          find.descendant(
            of: _key('todo-assignee-box'),
            matching: find.text('담당자를 지정하지 않았습니다.'),
          ),
          findsOneWidget,
        );
        expect(tester.getSize(_key('todo-assignee-box')).height, 50);
        await _submitWithTitle(tester, '담당자 없음');
        expect(api.lastCreate!['assigneeIds'], isEmpty);
      },
    );

    testWidgets('기본 담당자만 있으면 "쓰던 내용"이 아니다 — 그대로 닫으면 묻지 않고 닫힌다', (tester) async {
      final session = _session();
      await _open(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          api: FakeTodoApi(me: 'me'),
        ),
      );
      expect(_key('todo-assignee-chip-me'), findsOneWidget);
      await tester.tap(_key('todo-editor-close'));
      await tester.pumpAndSettle();
      expect(find.text('작성 중인 할 일을 버리고 닫을까요?'), findsNothing);
      expect(find.byType(TodoEditor), findsNothing);
    });

    testWidgets('쓰던 내용이 있으면 닫기 전에 묻는다 — [계속 쓰기]면 그대로, [닫기]면 닫힌다(아래 [취소]도 같다)', (
      tester,
    ) async {
      final session = _session();
      await _open(
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
      await tester.tap(find.widgetWithText(TextButton, '취소'));
      await tester.pumpAndSettle();
      expect(find.text('작성 중인 할 일을 버리고 닫을까요?'), findsOneWidget);
      await tester.tap(find.text('계속 쓰기'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoEditor), findsOneWidget);
      await tester.tap(_key('todo-editor-close'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '닫기'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoEditor), findsNothing);
    });

    testWidgets(
      '대화방 없이 열면 상자에 "대화방을 먼저 선택하세요."·담당자 관리 꺼짐 — 대화방을 처음 고르면 묻지 않고 내가 담당자(첨부는 그대로)',
      (tester) async {
        final session = _session();
        final api = FakeTodoApi(me: 'me');
        await _open(
          tester,
          (c) => showTodoEditor(
            c,
            session: session,
            initialAttachments: [_attachment('기획서.pdf')],
            api: api,
          ),
        );
        expect(_roomFieldText('대화방 선택'), findsOneWidget);
        expect(_key('todo-assignee-chip-me'), findsNothing);
        expect(
          find.descendant(
            of: _key('todo-assignee-box'),
            matching: find.text('대화방을 먼저 선택하세요.'),
          ),
          findsOneWidget,
        );
        expect(
          tester.widget<ButtonStyleButton>(_key('todo-assignee-add')).onPressed,
          isNull,
          reason: '대화방을 고르기 전에는 담당자를 고를 수 없다',
        );
        expect(
          tester.widget<ButtonStyleButton>(_key('todo-submit')).onPressed,
          isNull,
          reason: '대화방이 없으면 저장할 수 없다',
        );

        await _pickRoom(tester, '개발 토픽');
        expect(
          find.text(_resetMessage),
          findsNothing,
          reason: '처음 고를 때는 묻지 않는다',
        );
        expect(_roomFieldText('개발 토픽'), findsOneWidget);
        expect(_key('todo-assignee-chip-me'), findsOneWidget);
        expect(find.text('대화방을 먼저 선택하세요.'), findsNothing);
        expect(
          tester.widget<ButtonStyleButton>(_key('todo-assignee-add')).onPressed,
          isNotNull,
        );
        expect(
          _state(tester).attachmentCount,
          1,
          reason: '처음 고를 때는 첨부를 지우지 않는다',
        );

        await _submitWithTitle(tester, '방 고른 뒤');
        expect(api.lastCreateRoomId, 'r2');
        expect(api.lastCreate!['assigneeIds'], ['me']);
        expect(api.lastCreateAttachments.single.fileName, '기획서.pdf');
      },
    );

    testWidgets('메시지에서 등록(대화방 고정)·나와의 대화에서도 기본은 나', (tester) async {
      final self = _selfRoom();
      final session = _session(rooms: [_topic('r1'), self]);
      final api = FakeTodoApi(me: 'me');
      await _open(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          lockRoom: true,
          initialTitle: '메시지 본문',
          sourceMessageId: 'm1',
          api: api,
        ),
      );
      expect(_key('todo-room-locked'), findsOneWidget);
      expect(_key('todo-room-field'), findsNothing);
      expect(_key('todo-assignee-chip-me'), findsOneWidget);
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(api.lastCreate!['assigneeIds'], ['me']);
      expect(api.lastCreate!['sourceMessageId'], 'm1');

      await _open(
        tester,
        (c) => showTodoEditor(c, session: session, room: self, api: api),
      );
      expect(_roomFieldText(selfRoomName), findsOneWidget);
      expect(_key('todo-assignee-chip-me'), findsOneWidget);
      await _submitWithTitle(tester, '개인 할 일');
      expect(api.lastCreateRoomId, 'self');
      expect(api.lastCreate!['assigneeIds'], ['me']);
    });

    testWidgets('고치기에서는 기본값을 넣지 않는다 — 원래 담당자 그대로, 안 바꿨으면 assigneeIds도 안 보낸다', (
      tester,
    ) async {
      final session = _session();
      final alone = todoJson(id: 'e1', title: '혼자 하는 일');
      final handedOver = todoJson(id: 'e2', title: '맡긴 일', assignees: ['u2']);
      final api = FakeTodoApi(me: 'me', todos: [alone, handedOver]);
      await _open(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          editing: Todo.fromJson(alone),
          api: api,
        ),
      );
      expect(_key('todo-assignee-chip-me'), findsNothing);
      expect(find.text('담당자를 지정하지 않았습니다.'), findsOneWidget);
      await _submitWithTitle(tester, '새 제목');
      expect(api.lastUpdate, {'title': '새 제목'});

      await _open(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          editing: Todo.fromJson(handedOver),
          api: api,
        ),
      );
      expect(_key('todo-assignee-chip-u2'), findsOneWidget);
      expect(_key('todo-assignee-chip-me'), findsNothing);
      // 그대로 닫으면 묻지 않는다(바뀐 게 없다).
      await tester.tap(_key('todo-editor-close'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoEditor), findsNothing);
    });
  });

  // ────────────────────────── 기간 ──────────────────────────
  group('기간', () {
    testWidgets(
      '한 칸(높이 50, 비어 있으면 "기간을 선택하세요 (선택)") — 누르면 칸을 덮지 않는 판(달력 위, 그 아래 시작 시간 · 바로 밑 종료 시간), '
      '첫 누름 시작일 · 둘째 누름 종료일(사이는 띠), 새로 고른 날짜의 빈 시간은 지금 다음의 15분 단위, 골라도 판은 열린 채 — 바깥 · 칸 · Esc로 닫는다',
      (tester) async {
        final session = _session();
        final api = FakeTodoApi(me: 'me');
        await _open(
          tester,
          (c) => showTodoEditor(
            c,
            session: session,
            room: session.rooms.first,
            api: api,
          ),
          size: const Size(1280, 900),
        );
        final field = _key('todo-period-field');
        expect(
          find.descendant(of: field, matching: find.text('기간을 선택하세요 (선택)')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: field,
            matching: find.byIcon(Icons.arrow_drop_down),
          ),
          findsOneWidget,
        );
        expect(tester.getSize(field).height, 50);
        expect(
          tester.getSize(field).width,
          tester.getSize(_key('todo-title-field')).width,
          reason: '가로 전체 한 칸',
        );
        expect(_key('todo-period-clear'), findsNothing);
        expect(_popup, findsNothing);
        final scheme = Theme.of(tester.element(field)).colorScheme;

        await _openPeriod(tester);
        expect(_popup, findsOneWidget);
        _expectPopupBeside(tester, const Size(1280, 900));
        expect(_borderOf(tester, field), scheme.primary, reason: '펼친 동안 강조');
        expect(find.text('시작일을 선택하세요'), findsOneWidget);
        final now = DateTime.now();
        final s = DateTime(now.year, now.month, 10);
        final m = DateTime(now.year, now.month, 15);
        final d = DateTime(now.year, now.month, 20);
        // 달력 아래 `시작 시간`, 그 바로 밑 `종료 시간`(같은 폭으로 위아래).
        final startBox = tester.getRect(_key('todo-time-start'));
        final endBox = tester.getRect(_key('todo-time-end'));
        expect(startBox.top, greaterThan(tester.getRect(_dayKey(d)).bottom));
        expect(endBox.left, startBox.left);
        expect(endBox.width, startBox.width);
        expect(endBox.top, greaterThan(startBox.bottom));
        expect(
          tester.getTopLeft(find.text('종료 시간')).dy,
          inExclusiveRange(startBox.bottom, endBox.top),
        );

        await _tapDay(tester, s);
        expect(find.text('종료일을 선택하세요'), findsOneWidget);
        expect(_periodText(tester), '${formatTodoDate(s)} 오전 10:15 ~');
        await _tapDay(tester, d);
        expect(_popup, findsOneWidget, reason: '골라도 판은 열린 채');
        expect(
          _periodText(tester),
          '${formatTodoDate(s)} 오전 10:15 ~ ${formatTodoDate(d)} 오전 10:15',
        );
        expect(find.text('시작일을 선택하세요'), findsOneWidget, reason: '다시 누르면 새 기간');
        // 시작일 · 종료일은 채운 원, 사이는 옅은 띠(기간 밖은 없음).
        expect(_dayFill(tester, s), scheme.primary);
        expect(_dayFill(tester, d), scheme.primary);
        expect(_dayFill(tester, m), isNull);
        expect(_hasBand(tester, m), isTrue);
        expect(_hasBand(tester, DateTime(now.year, now.month, 25)), isFalse);

        // 바깥을 누르면 닫힌다(값은 그대로).
        await tester.tapAt(const Offset(4, 4));
        await tester.pumpAndSettle();
        expect(_popup, findsNothing);
        expect(find.byType(TodoEditor), findsOneWidget);
        expect(_key('todo-period-clear'), findsOneWidget);
        // 칸을 다시 눌러도 닫힌다.
        await _openPeriod(tester);
        expect(_popup, findsOneWidget);
        await tester.tap(field, warnIfMissed: false); // 막이 받는다
        await tester.pumpAndSettle();
        expect(_popup, findsNothing);
        // Esc는 판만 닫는다(편집기는 그대로 — 작성 취소도 묻지 않는다).
        await _openPeriod(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(_popup, findsNothing);
        expect(find.byType(TodoEditor), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);

        await tester.enterText(_key('todo-title-field'), '기간 있는 일');
        await tester.pump();
        await tester.tap(_key('todo-submit'));
        await tester.pumpAndSettle();
        expect(api.lastCreate!['startDate'], todoDateWire(s));
        expect(api.lastCreate!['dueDate'], todoDateWire(d));
        expect(api.lastCreate!['startTime'], '10:15');
        expect(api.lastCreate!['dueTime'], '10:15');
      },
    );

    testWidgets('칸 안의 ✕(기간 지우기)로 날짜와 시간을 모두 비운다', (tester) async {
      final session = _session();
      final json = todoJson(
        id: 'e1',
        title: '기간 있는 일',
        startDate: '2099-10-01',
        dueDate: '2099-10-07',
      );
      final api = FakeTodoApi(me: 'me', todos: [json]);
      await _open(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          editing: Todo.fromJson(json),
          api: api,
        ),
      );
      expect(_periodText(tester), '2099/10/01 ~ 2099/10/07');
      final clear = _key('todo-period-clear');
      expect(
        find.descendant(of: _key('todo-period-field'), matching: clear),
        findsOneWidget,
        reason: '칸 안 오른쪽',
      );
      await tester.ensureVisible(clear);
      await tester.pumpAndSettle();
      await tester.tap(clear);
      await tester.pump();
      expect(find.text('기간을 선택하세요 (선택)'), findsOneWidget);
      expect(clear, findsNothing);
      expect(_popup, findsNothing, reason: '지우기는 판을 열지 않는다');
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(api.lastUpdate, {'startDate': null, 'dueDate': null});
    });

    testWidgets(
      '좁으면(390) 칸 안 기간은 ~ 뒤에서 두 줄, 판은 화면 안에서 칸을 덮지 않고, 뒤로 가기는 판부터 닫는다',
      (tester) async {
        final session = _session();
        final json = todoJson(
          id: 'e1',
          title: '모바일',
          startDate: '2099-10-01',
          startTime: '09:00',
          dueDate: '2099-10-02',
          dueTime: '18:00',
        );
        final api = FakeTodoApi(me: 'me', todos: [json]);
        await _open(
          tester,
          (c) => showTodoEditor(
            c,
            session: session,
            editing: Todo.fromJson(json),
            api: api,
          ),
          size: const Size(390, 844),
        );
        expect(
          tester.widget<TodoEditor>(find.byType(TodoEditor)).mode,
          TodoViewMode.page,
        );
        final field = _key('todo-period-field');
        final first = find.descendant(
          of: field,
          matching: find.text('2099/10/01 오전 9:00 ~'),
        );
        final second = find.descendant(
          of: field,
          matching: find.text('2099/10/02 오후 6:00'),
        );
        expect(first, findsOneWidget);
        expect(second, findsOneWidget);
        expect(
          tester.getTopLeft(second).dy,
          greaterThan(tester.getTopLeft(first).dy),
        );
        await _openPeriod(tester);
        _expectPopupBeside(tester, const Size(390, 844));
        // 판이 처음 보여 주는 달은 시작일의 달.
        expect(_dayKey(DateTime(2099, 10, 1)), findsOneWidget);
        // 시간 목록도 화면 안.
        await tester.tap(_key('todo-time-end'));
        await tester.pumpAndSettle();
        final list = tester.getRect(_key('todo-time-list'));
        expect(list.left, greaterThanOrEqualTo(0));
        expect(list.right, lessThanOrEqualTo(390));
        expect(list.top, greaterThanOrEqualTo(0));
        // 안드로이드 뒤로 가기 — 판(과 목록)만 닫고 편집기는 그대로.
        await _systemBack(tester);
        expect(_popup, findsNothing);
        expect(find.byType(TodoEditor), findsOneWidget);
        // 판이 없으면 편집기를 닫는다(바뀐 게 없으니 묻지 않는다).
        await _systemBack(tester);
        expect(find.byType(TodoEditor), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });

  // ────────────────────────── 기간 — 시작/종료 시간 ──────────────────────────
  group('기간 — 시작/종료 시간', () {
    /// 판 안의 시간 칸 [id]('start'|'end')를 눌러 목록을 연다.
    Future<void> openTime(WidgetTester tester, String id) async {
      await tester.tap(_key('todo-time-$id'));
      await tester.pumpAndSettle();
    }

    /// 열린 시간 목록에서 [option](`none` 또는 분)을 고른다 — 목록 맨 위로 옮긴 뒤 보일 때까지 내린다.
    Future<void> pickTime(WidgetTester tester, Object option) async {
      final item = _key('todo-time-option-$option');
      final list = find.descendant(
        of: _key('todo-time-list'),
        matching: find.byType(Scrollable),
      );
      if (item.evaluate().isEmpty) {
        tester.state<ScrollableState>(list).position.jumpTo(0);
        await tester.pumpAndSettle();
      }
      if (item.evaluate().isEmpty) {
        await tester.scrollUntilVisible(item, 150, scrollable: list);
      }
      await tester.ensureVisible(item);
      await tester.pumpAndSettle();
      await tester.tap(item);
      await tester.pumpAndSettle();
    }

    String boxText(WidgetTester tester, String id) => tester
        .widgetList<Text>(
          find.descendant(
            of: _key('todo-time-$id'),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data)
        .join();

    testWidgets(
      '판의 시작 시간 · 종료 시간 칸(높이 36, 글자 14, 시계 아이콘 · ▾) — 날짜가 없으면 꺼짐, 날짜를 고르면 지금 다음의 15분 단위, '
      '목록은 그 칸 바로 위로 판 안에서 달력을 덮고(시간 없음 + 15분 단위 97줄, 지금 값 체크, 보이게 스크롤), 고르면 목록만 닫힌다',
      (tester) async {
        final session = _session();
        final api = FakeTodoApi(me: 'me');
        await _open(
          tester,
          (c) => showTodoEditor(
            c,
            session: session,
            room: session.rooms.first,
            api: api,
          ),
        );
        await _openPeriod(tester);
        for (final (id, label) in const [
          ('start', '시작 시간'),
          ('end', '종료 시간'),
        ]) {
          final box = _key('todo-time-$id');
          expect(box, findsOneWidget);
          expect(tester.getSize(box).height, 36);
          expect(find.text(label), findsOneWidget);
          expect(boxText(tester, id), '시간 없음');
          expect(
            tester.widget<InkWell>(box).onTap,
            isNull,
            reason: '날짜가 없으면 꺼짐',
          );
          expect(
            find.descendant(of: box, matching: find.byIcon(Icons.schedule)),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: box,
              matching: find.byIcon(Icons.arrow_drop_down),
            ),
            findsOneWidget,
          );
          final text = tester.widget<Text>(
            find.descendant(of: box, matching: find.text('시간 없음')),
          );
          expect(text.style?.fontSize, 14);
        }

        final now = DateTime.now();
        final s = DateTime(now.year, now.month, 10);
        await _tapDay(tester, s);
        expect(boxText(tester, 'start'), '오전 10:15');
        expect(
          tester.widget<InkWell>(_key('todo-time-start')).onTap,
          isNotNull,
        );
        expect(boxText(tester, 'end'), '시간 없음');
        await _tapDay(tester, DateTime(now.year, now.month, 20));
        expect(boxText(tester, 'end'), '오전 10:15');

        // 종료 시간 목록 — 그 칸 바로 위, 판 안(달력을 덮는다).
        await openTime(tester, 'end');
        final listFinder = _key('todo-time-list');
        final list = tester.getRect(listFinder);
        final popup = tester.getRect(_popup);
        final endBox = tester.getRect(_key('todo-time-end'));
        expect(list.bottom, lessThanOrEqualTo(endBox.top));
        expect(endBox.top - list.bottom, lessThan(8));
        expect(list.top, greaterThanOrEqualTo(popup.top));
        expect(list.left, greaterThanOrEqualTo(popup.left));
        expect(list.right, lessThanOrEqualTo(popup.right));
        expect(
          list.top,
          lessThan(tester.getRect(_key('todo-time-start')).top),
          reason: '시작 시간 칸과 달력 쪽을 덮는다',
        );
        expect(_popup, findsOneWidget);
        // 첫 줄 시간 없음, 그다음 오전 12:00 … 오후 11:45(15분 단위 96줄).
        final view = tester.widget<ListView>(
          find.descendant(of: listFinder, matching: find.byType(ListView)),
        );
        expect(
          (view.childrenDelegate as SliverChildBuilderDelegate).childCount,
          97,
        );
        // 지금 값(오전 10:15)에 체크 — 목록 안에 보이게 열린다.
        final current = _key('todo-time-option-615');
        expect(
          find.descendant(of: current, matching: find.byIcon(Icons.check)),
          findsOneWidget,
        );
        final row = tester.getRect(current);
        expect(row.top, greaterThanOrEqualTo(list.top - 0.5));
        expect(row.bottom, lessThanOrEqualTo(list.bottom + 0.5));
        expect(list.height, lessThan(300), reason: '한 번에 여섯 줄쯤');
        expect(
          tester
              .widget<Text>(
                find.descendant(of: current, matching: find.text('오전 10:15')),
              )
              .style
              ?.fontSize,
          14,
        );
        expect(_key('todo-time-option-620'), findsNothing, reason: '15분 단위');
        // 맨 위는 시간 없음(체크 없음), 맨 아래는 오후 11:45.
        final scrollable = find.descendant(
          of: listFinder,
          matching: find.byType(Scrollable),
        );
        tester.state<ScrollableState>(scrollable).position.jumpTo(0);
        await tester.pumpAndSettle();
        final none = _key('todo-time-option-none');
        expect(
          find.descendant(of: none, matching: find.text('시간 없음')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: none, matching: find.byIcon(Icons.check)),
          findsNothing,
        );
        expect(tester.getTopLeft(none).dy, lessThan(list.top + 8));
        expect(
          find.descendant(
            of: _key('todo-time-option-0'),
            matching: find.text('오전 12:00'),
          ),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(
          _key('todo-time-option-1425'),
          150,
          scrollable: scrollable,
        );
        expect(
          find.descendant(
            of: _key('todo-time-option-1425'),
            matching: find.text('오후 11:45'),
          ),
          findsOneWidget,
        );
        // 판 안의 다른 곳(달력 머리)을 누르면 목록만 닫힌다.
        await tester.tapAt(tester.getCenter(find.text('시작일을 선택하세요')));
        await tester.pumpAndSettle();
        expect(listFinder, findsNothing);
        expect(_popup, findsOneWidget);
        // Esc도 목록부터.
        await openTime(tester, 'end');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(listFinder, findsNothing);
        expect(_popup, findsOneWidget);

        await openTime(tester, 'end');
        await pickTime(tester, 21 * 60 + 30);
        expect(listFinder, findsNothing, reason: '고르면 목록은 닫히고');
        expect(_popup, findsOneWidget, reason: '판은 열린 채');
        expect(boxText(tester, 'end'), '오후 9:30');
        expect(_periodText(tester), endsWith('오후 9:30'));

        // 시작 시간을 `시간 없음`으로 — 칸에는 날짜만.
        await openTime(tester, 'start');
        await pickTime(tester, 'none');
        expect(boxText(tester, 'start'), '시간 없음');
        expect(_periodText(tester), startsWith('${formatTodoDate(s)} ~ '));

        await tester.tapAt(const Offset(4, 4));
        await tester.pumpAndSettle();
        await _submitWithTitle(tester, '시간 있는 일');
        expect(api.lastCreate!['startDate'], todoDateWire(s));
        expect(api.lastCreate!['startTime'], isNull);
        expect(api.lastCreate!['dueTime'], '21:30');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('같은 날 시작 시간이 종료 시간보다 늦으면 안내하고 저장할 수 없다 — ✕는 날짜와 시간을 모두 지운다', (
      tester,
    ) async {
      final session = _session();
      final api = FakeTodoApi(me: 'me');
      await _open(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          api: api,
        ),
      );
      await tester.enterText(_key('todo-title-field'), '같은 날');
      await _openPeriod(tester);
      final now = DateTime.now();
      final day = DateTime(now.year, now.month, 10);
      await _tapDay(tester, day);
      await _tapDay(tester, day);
      const error = '시작 시간은 종료 시간보다 늦을 수 없습니다.';
      expect(find.text(error), findsNothing, reason: '둘 다 오전 10:15');
      await openTime(tester, 'start');
      await pickTime(tester, 19 * 60);
      expect(find.text(error), findsOneWidget);
      expect(
        tester.widget<FilledButton>(_key('todo-submit')).onPressed,
        isNull,
      );
      await openTime(tester, 'end');
      await pickTime(tester, 19 * 60);
      expect(find.text(error), findsNothing, reason: '같은 시각은 된다');
      expect(
        tester.widget<FilledButton>(_key('todo-submit')).onPressed,
        isNotNull,
      );

      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      await tester.ensureVisible(_key('todo-period-clear'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-period-clear'));
      await tester.pumpAndSettle();
      await _openPeriod(tester);
      expect(boxText(tester, 'start'), '시간 없음');
      expect(boxText(tester, 'end'), '시간 없음');
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(api.lastCreate!['startDate'], isNull);
      expect(api.lastCreate!['startTime'], isNull);
      expect(api.lastCreate!['dueTime'], isNull);
    });

    testWidgets(
      '고치기 — 바뀐 시간만 보낸다, 단위 밖 시각(17:40)도 목록에 체크되어 보인다, 이미 시간이 있는 날짜를 옮기면 시간은 그대로',
      (tester) async {
        final session = _session();
        final json = todoJson(
          id: 'e1',
          title: '시간 있는 일',
          startDate: '2099-10-01',
          startTime: '17:40',
          dueDate: '2099-10-02',
          dueTime: '00:00',
        );
        final api = FakeTodoApi(me: 'me', todos: [json]);
        await _open(
          tester,
          (c) => showTodoEditor(
            c,
            session: session,
            editing: Todo.fromJson(json),
            api: api,
          ),
        );
        expect(_periodText(tester), '2099/10/01 오후 5:40 ~ 2099/10/02 오전 12:00');
        await _openPeriod(tester);
        expect(boxText(tester, 'start'), '오후 5:40');
        await openTime(tester, 'start');
        final odd = _key('todo-time-option-1060');
        expect(
          find.descendant(of: odd, matching: find.text('오후 5:40')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: odd, matching: find.byIcon(Icons.check)),
          findsOneWidget,
        );
        expect(
          tester.getTopLeft(odd).dy,
          inExclusiveRange(
            tester.getTopLeft(_key('todo-time-option-1050')).dy,
            tester.getTopLeft(_key('todo-time-option-1065')).dy,
          ),
          reason: '제자리(오후 5:30과 5:45 사이)',
        );
        await pickTime(tester, 18 * 60);
        await tester.tapAt(const Offset(4, 4));
        await tester.pumpAndSettle();
        await tester.tap(_key('todo-submit'));
        await tester.pumpAndSettle();
        expect(api.lastUpdate, {'startTime': '18:00'});
        expect(api.todos.single['startTime'], '18:00');
        expect(api.todos.single['dueTime'], '00:00');
      },
    );

    testWidgets('종료 시간이 있으면 "기한 하루 전 / 1시간 전"은 그 시각 기준 — 메뉴 문구에 울릴 시각', (
      tester,
    ) async {
      final session = _session();
      final json = todoJson(
        id: 'e1',
        title: '오후 3시 마감',
        dueDate: '2099-12-25',
        dueTime: '15:00',
      );
      final api = FakeTodoApi(me: 'me', todos: [json]);
      await _open(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          editing: Todo.fromJson(json),
          api: api,
        ),
      );
      await tester.ensureVisible(_key('todo-reminder-add'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-reminder-add'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: _key('todo-reminder-option-day'),
          matching: find.text('기한 하루 전 (2099/12/24 오후 3:00)'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _key('todo-reminder-option-hour'),
          matching: find.text('기한 1시간 전 (2099/12/25 오후 2:00)'),
        ),
        findsOneWidget,
      );
      await tester.tap(_key('todo-reminder-option-hour'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: _key('todo-reminder-0'),
          matching: find.text('2099/12/25 오후 2:00'),
        ),
        findsOneWidget,
      );
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(api.lastUpdate!['reminders'], [
        {'remindAt': DateTime(2099, 12, 25, 14).millisecondsSinceEpoch},
      ]);
    });
  });

  // ────────────────────────── 알림 ──────────────────────────
  group('알림', () {
    testWidgets(
      '테두리 선택 상자 "알림을 받아보세요 (선택) ▾"(가로 전체) — 메뉴는 상자 폭 그대로 세 가지, 기한이 없으면 안내만, 추가한 알림은 상자 아래 한 줄씩(x로 지우기)',
      (tester) async {
        final session = _session();
        final api = FakeTodoApi(me: 'me');
        await _open(
          tester,
          (c) => showTodoEditor(
            c,
            session: session,
            room: session.rooms.first,
            api: api,
          ),
        );
        final select = _key('todo-reminder-add');
        expect(
          find.descendant(of: select, matching: find.text('알림을 받아보세요 (선택)')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: select,
            matching: find.byIcon(Icons.arrow_drop_down),
          ),
          findsOneWidget,
        );
        expect(
          tester.getSize(select).width,
          tester.getSize(_key('todo-title-field')).width,
        );

        Future<void> pick(String option) async {
          await tester.ensureVisible(select);
          await tester.pumpAndSettle();
          await tester.tap(select);
          await tester.pumpAndSettle();
          await tester.tap(_key('todo-reminder-option-$option'));
          await tester.pumpAndSettle();
        }

        await tester.ensureVisible(select);
        await tester.pumpAndSettle();
        await tester.tap(select);
        await tester.pumpAndSettle();
        for (final (option, text) in const [
          ('day', '기한 하루 전 (전날 오후 6시)'),
          ('hour', '기한 1시간 전 (기한일 오후 5시)'),
          ('custom', '직접 지정'),
        ]) {
          final item = _key('todo-reminder-option-$option');
          expect(
            find.descendant(of: item, matching: find.text(text)),
            findsOneWidget,
          );
          expect(tester.getSize(item).width, tester.getSize(select).width);
          expect(tester.getTopLeft(item).dx, tester.getTopLeft(select).dx);
        }
        await tester.tap(_key('todo-reminder-option-day'));
        await tester.pumpAndSettle();
        expect(find.text('기한을 먼저 정하세요.'), findsOneWidget);
        expect(_key('todo-reminder-0'), findsNothing);
        await tester.pump(const Duration(seconds: 3));

        // 기한을 멀리(다음 달 25일) 잡고 하루 전·1시간 전을 더한다 — 종료 시간은 새로 고른 날짜라 지금 다음의 15분
        // 단위(시계 고정 — 오전 10:15)가 채워진다.
        final now = DateTime.now();
        final due = DateTime(now.year, now.month + 1, 25);
        await _openPeriod(tester);
        await tester.tap(_key('todo-period-next'));
        await tester.pumpAndSettle();
        await _tapDay(tester, due);
        await _tapDay(tester, due);
        await tester.tapAt(const Offset(4, 4));
        await tester.pumpAndSettle();
        await pick('day');
        await pick('hour');
        final first = _key('todo-reminder-0');
        final second = _key('todo-reminder-1');
        expect(
          find.descendant(of: first, matching: find.textContaining('오전 10:15')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: second, matching: find.textContaining('오전 9:15')),
          findsOneWidget,
        );
        expect(
          tester.getTopLeft(first).dy,
          greaterThan(tester.getBottomLeft(select).dy),
          reason: '추가한 알림은 선택 상자 아래',
        );
        expect(tester.getSize(first).width, tester.getSize(select).width);
        // 지우기.
        await tester.ensureVisible(_key('todo-reminder-remove-0'));
        await tester.pumpAndSettle();
        await tester.tap(_key('todo-reminder-remove-0'));
        await tester.pump();
        expect(second, findsNothing);
        expect(
          find.descendant(of: first, matching: find.textContaining('오전 9:15')),
          findsOneWidget,
        );
        await _submitWithTitle(tester, '알림 있는 일');
        expect(api.lastCreate!['reminders'], [
          todoReminderBeforeDue(
            due,
            const Duration(hours: 1),
            dueMinutes: 10 * 60 + 15,
          ).millisecondsSinceEpoch,
        ]);
      },
    );

    testWidgets('5개를 채우면 선택 상자가 꺼지고 문구가 바뀐다 — 하나 지우면 다시 켜진다', (tester) async {
      final session = _session();
      final json = todoJson(
        id: 'e1',
        title: '알림 많은 일',
        dueDate: '2099-12-31',
        reminders: [
          for (var i = 0; i < todoRemindersMaxCount; i++)
            {
              'id': 'rm$i',
              'remindAt': DateTime(2099, 12, 20 + i, 9).millisecondsSinceEpoch,
            },
        ],
      );
      await _open(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          editing: Todo.fromJson(json),
          api: FakeTodoApi(me: 'me', todos: [json]),
        ),
      );
      final select = _key('todo-reminder-add');
      expect(tester.widget<PopupMenuButton<String>>(select).enabled, isFalse);
      expect(
        find.descendant(
          of: select,
          matching: find.text('알림은 $todoRemindersMaxCount개까지 추가할 수 있습니다.'),
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(_key('todo-reminder-remove-4'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-reminder-remove-4'));
      await tester.pump();
      expect(tester.widget<PopupMenuButton<String>>(select).enabled, isTrue);
      expect(
        find.descendant(of: select, matching: find.text('알림을 받아보세요 (선택)')),
        findsOneWidget,
      );
    });
  });

  // ────────────────────────── 대화방 바꾸기 ──────────────────────────
  group('대화방을 바꾸면 첨부·담당자 초기화', () {
    /// 영업 토픽에서 첨부 하나·담당자 나와 김철수로 연 창.
    Future<FakeTodoApi> openWithInput(WidgetTester tester) async {
      final session = _session();
      final api = FakeTodoApi(me: 'me');
      await _open(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          initialAttachments: [_attachment('견적서.pdf')],
          api: api,
        ),
      );
      _state(tester).setAssignees(session.rooms.first.members.take(2).toList());
      await tester.pump();
      expect(_key('todo-assignee-chip-me'), findsOneWidget);
      expect(_key('todo-assignee-chip-u2'), findsOneWidget);
      expect(find.text('견적서.pdf'), findsOneWidget);
      return api;
    }

    testWidgets('지울 게 있으면 먼저 묻고(두 줄 문구) — [변경]이면 첨부를 모두 빼고 담당자는 새 방의 [나]', (
      tester,
    ) async {
      final api = await openWithInput(tester);
      await _pickRoom(tester, '개발 토픽');
      expect(find.text(_resetMessage), findsOneWidget);
      expect(
        find.descendant(
          of: _key('todo-room-change-cancel'),
          matching: find.text('취소'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _key('todo-room-change-confirm'),
          matching: find.text('변경'),
        ),
        findsOneWidget,
      );
      // 묻는 동안 대화방 칸은 아직 원래 방이다.
      expect(_roomFieldText('영업 토픽'), findsOneWidget);
      expect(_roomFieldText('개발 토픽'), findsNothing);

      await tester.tap(_key('todo-room-change-confirm'));
      await tester.pumpAndSettle();
      expect(find.text(_resetMessage), findsNothing);
      expect(_roomFieldText('개발 토픽'), findsOneWidget);
      expect(_state(tester).attachmentCount, 0);
      expect(find.text('견적서.pdf'), findsNothing);
      expect(_fileCount(tester), '0 / $todoAttachmentsMaxCount');
      expect(_key('todo-assignee-chip-me'), findsOneWidget);
      expect(_key('todo-assignee-chip-u2'), findsNothing);

      await _submitWithTitle(tester, '옮겨서 만들기');
      expect(api.lastCreateRoomId, 'r2');
      expect(api.lastCreate!['assigneeIds'], ['me']);
      expect(api.lastCreateAttachments, isEmpty);
    });

    testWidgets('[취소]면 원래 대화방·첨부·담당자 그대로', (tester) async {
      final api = await openWithInput(tester);
      await _pickRoom(tester, '개발 토픽');
      expect(find.text(_resetMessage), findsOneWidget);
      await tester.tap(_key('todo-room-change-cancel'));
      await tester.pumpAndSettle();
      expect(find.text(_resetMessage), findsNothing);
      expect(_roomFieldText('영업 토픽'), findsOneWidget);
      expect(_roomFieldText('개발 토픽'), findsNothing);
      expect(_state(tester).attachmentCount, 1);
      expect(find.text('견적서.pdf'), findsOneWidget);
      expect(_fileCount(tester), '1 / $todoAttachmentsMaxCount');
      expect(_key('todo-assignee-chip-me'), findsOneWidget);
      expect(_key('todo-assignee-chip-u2'), findsOneWidget);

      await _submitWithTitle(tester, '그대로 만들기');
      expect(api.lastCreateRoomId, 'r1');
      expect(api.lastCreate!['assigneeIds'], ['me', 'u2']);
      expect(api.lastCreateAttachments.single.url, '/files/견적서.pdf');
    });

    testWidgets('첨부가 없어도 담당자가 [나]가 아니면(나를 뺐어도) 묻는다', (tester) async {
      final session = _session();
      await _open(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          api: FakeTodoApi(me: 'me'),
        ),
      );
      tester.widget<InputChip>(_key('todo-assignee-chip-me')).onDeleted!();
      await tester.pump();
      expect(_key('todo-assignee-chip-me'), findsNothing);
      await _pickRoom(tester, '개발 토픽');
      expect(find.text(_resetMessage), findsOneWidget);
      await tester.tap(_key('todo-room-change-confirm'));
      await tester.pumpAndSettle();
      expect(_roomFieldText('개발 토픽'), findsOneWidget);
      expect(
        _key('todo-assignee-chip-me'),
        findsOneWidget,
        reason: '담당자는 다시 [나]',
      );
    });

    testWidgets('지울 게 없으면(첨부 없음·담당자 [나]) 묻지 않고 바로 바꾼다', (tester) async {
      final session = _session();
      final api = FakeTodoApi(me: 'me');
      await _open(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          api: api,
        ),
      );
      await _pickRoom(tester, '개발 토픽');
      expect(find.text(_resetMessage), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(_roomFieldText('개발 토픽'), findsOneWidget);
      expect(_key('todo-assignee-chip-me'), findsOneWidget);
      await _submitWithTitle(tester, '바로 옮김');
      expect(api.lastCreateRoomId, 'r2');
      expect(api.lastCreate!['assigneeIds'], ['me']);
    });

    testWidgets('같은 대화방을 다시 고르면 묻지도 지우지도 않는다', (tester) async {
      await openWithInput(tester);
      await _pickRoom(tester, '영업 토픽');
      expect(find.text(_resetMessage), findsNothing);
      expect(_roomFieldText('영업 토픽'), findsOneWidget);
      expect(_state(tester).attachmentCount, 1);
      expect(_key('todo-assignee-chip-u2'), findsOneWidget);
    });

    testWidgets('올리는 중인 첨부(진행 막대·"업로드 중")도 [변경]이면 올리기를 멈추고 뺀다', (tester) async {
      final session = _session();
      await _open(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          room: session.rooms.first,
          api: FakeTodoApi(me: 'me'),
        ),
      );
      final state = _state(tester);
      // 없는 파일 — 테스트 안에서는 올리기가 끝나지 않아 "올리는 중"으로 남는다.
      state.addFiles([File('올리는_중.txt')]);
      await tester.pump();
      expect(state.attachmentCount, 1);
      expect(state.debugUploading, isTrue);
      expect(find.text('올리는_중.txt'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(_fileCount(tester), '1 / $todoAttachmentsMaxCount');
      expect(_submitText('업로드 중'), findsOneWidget);
      expect(
        tester.widget<ButtonStyleButton>(_key('todo-submit')).onPressed,
        isNull,
      );

      await _pickRoom(tester, '개발 토픽', settle: false);
      expect(find.text(_resetMessage), findsOneWidget);
      await tester.tap(_key('todo-room-change-confirm'));
      await tester.pumpAndSettle();
      expect(state.attachmentCount, 0);
      expect(_submitText('저장하기'), findsOneWidget);
      expect(_roomFieldText('개발 토픽'), findsOneWidget);

      // 멈춘 요청이 나중에 끝나도(여기서는 요청 시간 초과 20초) 다시 붙거나 실패 알림이 뜨지 않는다.
      await tester.pump(const Duration(seconds: 21));
      await tester.pumpAndSettle();
      expect(state.attachmentCount, 0);
      expect(state.debugUploading, isFalse);
      expect(find.textContaining('올리지 못했습니다'), findsNothing);
    });

    testWidgets('보드 뷰 토픽은 대화방 목록에 없다(챗 뷰 토픽·채팅에서만 만든다)', (tester) async {
      final session = _session(
        rooms: [
          _topic('r1'),
          _topic('b1', name: '보드 토픽', board: true),
        ],
      );
      await _open(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          api: FakeTodoApi(me: 'me'),
        ),
      );
      await tester.tap(_key('todo-room-field'));
      await tester.pumpAndSettle();
      expect(find.text('영업 토픽'), findsOneWidget);
      expect(find.text('보드 토픽'), findsNothing);
      expect(session.canCreateTodoIn(session.rooms[0]), isTrue);
      expect(session.canCreateTodoIn(session.rooms[1]), isFalse);
    });
  });

  // ────────────────────────── 고치기 ──────────────────────────
  group('고치기', () {
    testWidgets(
      '담당자로 고치면 담당자 칩은 읽기 전용(빼기·담당자 관리 없음, 상자 아래 까닭)이고 assigneeIds를 보내지 않는다',
      (tester) async {
        final session = _session();
        final json = todoJson(
          id: 'e1',
          title: '같이 하는 일',
          creatorId: 'u2',
          creatorName: '김철수',
          assignees: ['me', 'u3'],
        );
        final api = FakeTodoApi(me: 'me', todos: [json]);
        await _open(
          tester,
          (c) => showTodoEditor(
            c,
            session: session,
            editing: Todo.fromJson(json),
            api: api,
          ),
        );
        expect(find.text('할 일 수정'), findsOneWidget);
        expect(_key('todo-room-locked'), findsOneWidget);
        final box = _key('todo-assignee-box');
        for (final id in ['me', 'u3']) {
          // 빼기(x) 없는 보통 칩 — 흐린 "꺼짐" 색이 아니라 이름이 그대로 읽힌다.
          final chip = _key('todo-assignee-chip-$id');
          expect(find.descendant(of: box, matching: chip), findsOneWidget);
          expect(
            tester.widget<Chip>(chip).onDeleted,
            isNull,
            reason: '담당자는 담당자 목록을 바꿀 수 없다',
          );
        }
        expect(find.byType(InputChip), findsNothing);
        expect(
          find.descendant(
            of: _key('todo-assignee-chip-me'),
            matching: find.text('이름me (나)'),
          ),
          findsOneWidget,
        );
        expect(_key('todo-assignee-add'), findsNothing);
        expect(find.text('담당자 관리'), findsNothing);
        final why = find.text('담당자는 만든 사람만 바꿀 수 있습니다.');
        expect(why, findsOneWidget);
        expect(
          tester.getTopLeft(why).dy,
          greaterThanOrEqualTo(tester.getBottomLeft(box).dy),
        );
        // 제목·설명·파일·기간·알림은 담당자도 고칠 수 있다.
        expect(
          tester.widget<ButtonStyleButton>(_key('todo-attach')).onPressed,
          isNotNull,
        );
        expect(
          tester
              .widget<PopupMenuButton<String>>(_key('todo-reminder-add'))
              .enabled,
          isTrue,
        );
        expect(_submitText('저장하기'), findsOneWidget);
        await tester.enterText(_key('todo-description-field'), '담당자가 쓴 설명');
        await tester.pump();
        await tester.tap(_key('todo-submit'));
        await tester.pumpAndSettle();
        expect(api.lastUpdate, {'description': '담당자가 쓴 설명'});
      },
    );

    testWidgets('서버가 거절하면 창 아래에 문구가 남고 입력은 그대로', (tester) async {
      final session = _session();
      final json = todoJson(id: 'e1', title: '고칠 할 일', assignees: ['u2']);
      final api = FakeTodoApi(me: 'me', todos: [json])
        ..failWith = '이 할 일을 수정할 권한이 없습니다.';
      await _open(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          editing: Todo.fromJson(json),
          api: api,
        ),
      );
      await _submitWithTitle(tester, '거절될 제목');
      final error = _key('todo-editor-error');
      expect(tester.widget<Text>(error).data, '이 할 일을 수정할 권한이 없습니다.');
      expect(
        tester.getTopLeft(error).dy,
        lessThan(tester.getTopLeft(_key('todo-submit')).dy),
        reason: '[저장하기] 줄 바로 위',
      );
      expect(find.text('거절될 제목'), findsOneWidget);
      expect(_submitText('저장하기'), findsOneWidget);
    });
  });

  // ────────────────────────── 패널 안 화면 ──────────────────────────
  group('패널 안 화면(PC 할 일 패널)', () {
    testWidgets(
      '머리는 만들 때도 고칠 때도 `← 할 일 … ✕`, 아래 [취소][저장하기] — [취소]는 ←처럼 이 화면만 닫고(바뀐 게 있으면 묻는다) ✕는 패널을 닫는다',
      (tester) async {
        final session = _session();
        final json = todoJson(id: 'e1', title: '고칠 할 일');
        final api = FakeTodoApi(me: 'me', todos: [json]);
        final results = <Todo?>[];
        var closed = 0;
        var editing = false;
        await _openPanel(tester, (context) async {
          results.add(
            await showTodoEditor(
              context,
              session: session,
              room: session.rooms.first,
              editing: editing ? Todo.fromJson(json) : null,
              api: api,
              mode: TodoViewMode.panel,
              onClosePanel: () => closed++,
            ),
          );
        });
        final editor = find.byType(TodoEditor);
        expect(
          find.descendant(of: _key('panel-nav'), matching: editor),
          findsOneWidget,
        );
        expect(find.byType(Dialog), findsNothing);
        final header = find.descendant(
          of: editor,
          matching: find.byType(TodoPageHeader),
        );
        expect(
          find.descendant(of: header, matching: find.text('할 일')),
          findsOneWidget,
        );
        expect(find.text('할 일 생성'), findsNothing);
        expect(_key('todo-editor-close'), findsNothing);
        expect(_submitText('저장하기'), findsOneWidget);
        // [취소]·[저장하기]는 패널 아래 오른쪽 끝.
        final cancel = find.widgetWithText(TextButton, '취소');
        expect(
          tester.getBottomRight(_key('todo-submit')).dx,
          moreOrLessEquals(tester.getRect(_key('panel-host')).right - 16),
        );
        expect(
          tester.getTopRight(cancel).dx,
          lessThan(tester.getTopLeft(_key('todo-submit')).dx),
        );
        // 바뀐 게 없으면 [취소]는 묻지 않고 이 화면만 닫는다.
        await tester.tap(cancel);
        await tester.pumpAndSettle();
        expect(editor, findsNothing);
        expect(results, [null]);
        expect(closed, 0);

        // 고치기도 같은 머리.
        editing = true;
        await tester.tap(_key('panel-opener'));
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: header, matching: find.text('할 일')),
          findsOneWidget,
        );
        expect(find.text('할 일 수정'), findsNothing);
        expect(
          find.descendant(
            of: _key('todo-room-hint'),
            matching: find.text(_editRoomHint),
          ),
          findsOneWidget,
        );
        await tester.enterText(_key('todo-title-field'), '고친 제목');
        await tester.pump();
        await tester.tap(cancel);
        await tester.pumpAndSettle();
        expect(find.text('수정한 내용을 버리고 닫을까요?'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, '계속 수정'));
        await tester.pumpAndSettle();
        expect(editor, findsOneWidget);
        await tester.tap(_key('todo-page-close'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, '닫기'));
        await tester.pumpAndSettle();
        expect(closed, 1, reason: '✕는 패널 닫기(onClosePanel)');

        await tester.tap(_key('todo-submit'));
        await tester.pumpAndSettle();
        expect(api.lastUpdate, {'title': '고친 제목'});
        expect(results.last?.title, '고친 제목');
        expect(editor, findsNothing);
      },
    );

    testWidgets(
      '패널 안 화면의 알림(토스트)은 창 전체(루트) 위에 뜬다 — 패널 폭의 중첩 Navigator 안에서 찌그러지지 않는다',
      (tester) async {
        final session = _session();
        await _openPanel(
          tester,
          (context) => showTodoEditor(
            context,
            session: session,
            room: session.rooms.first,
            lockRoom: true,
            initialAttachments: [
              for (var i = 0; i < todoAttachmentsMaxCount; i++)
                _attachment('파일$i.txt'),
            ],
            api: FakeTodoApi(me: 'me'),
            mode: TodoViewMode.panel,
            onClosePanel: () {},
          ),
        );
        final state = _state(tester);
        expect(state.attachmentCount, todoAttachmentsMaxCount);
        state.addFiles([File('하나_더.txt')]);
        await tester.pump();
        const message = '첨부 파일은 30개까지 올릴 수 있습니다.';
        expect(find.text(message), findsOneWidget);
        expect(
          find.descendant(of: _key('panel-nav'), matching: find.text(message)),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.text(message)).width, greaterThan(300));
        await tester.pump(const Duration(seconds: 3));
        expect(find.text(message), findsNothing);
      },
    );
  });

  // ────────────────────────── 고치기 — 바꾼 게 없으면 ──────────────────────────
  group('고치기 — 바꾼 게 없이 [저장하기]', () {
    test('가짜 API도 서버처럼 바꿀 칸이 없는 수정은 "수정할 내용이 없습니다."로 거절한다', () async {
      final api = FakeTodoApi(
        me: 'me',
        todos: [todoJson(id: 'e1')],
      );
      await expectLater(
        api.update('e1', {}),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            '수정할 내용이 없습니다.',
          ),
        ),
      );
    });

    // 대화상자(PC 넓은 창)·전체 화면(모바일)·패널 안 화면 — 서버에 보내지 않고 닫히며 결과는 null(상세는 "수정했습니다"를
    // 띄우지 않는다).
    for (final mode in TodoViewMode.values) {
      testWidgets('${mode.name} — [저장하기]는 처음부터 눌리고, 눌러도 보내지 않고 닫힌다(결과 null)', (
        tester,
      ) async {
        final session = _session();
        final json = todoJson(
          id: 'e1',
          title: '그대로 둘 할 일',
          description: '설명',
          assignees: ['me', 'u2'],
          startDate: '2099-10-01',
          dueDate: '2099-10-05',
          attachmentCount: 1,
          reminders: [
            {
              'id': 'rm1',
              'remindAt': DateTime(2099, 10, 4, 18).millisecondsSinceEpoch,
              'sent': false,
            },
          ],
        );
        final api = FakeTodoApi(me: 'me', todos: [json]);
        final results = <Todo?>[];
        var finished = 0;
        Future<void> open(BuildContext context) async {
          results.add(
            await showTodoEditor(
              context,
              session: session,
              editing: Todo.fromJson(json),
              api: api,
              mode: mode == TodoViewMode.panel ? TodoViewMode.panel : null,
              onClosePanel: mode == TodoViewMode.panel ? () {} : null,
            ),
          );
          finished++;
        }

        if (mode == TodoViewMode.panel) {
          await _openPanel(tester, open);
        } else {
          await _open(
            tester,
            open,
            size: mode == TodoViewMode.dialog
                ? const Size(900, 900)
                : const Size(390, 844),
          );
        }
        expect(tester.widget<TodoEditor>(find.byType(TodoEditor)).mode, mode);
        expect(_state(tester).isDirty, isFalse);
        expect(
          tester.widget<FilledButton>(_key('todo-submit')).onPressed,
          isNotNull,
          reason: '잔디처럼 바꾸기 전에도 누를 수 있다',
        );
        await tester.tap(_key('todo-submit'));
        await tester.pumpAndSettle();
        expect(find.byType(TodoEditor), findsNothing);
        expect(api.callCount('update'), 0);
        expect(finished, 1);
        expect(results, [null]);
        expect(find.text('수정할 내용이 없습니다.'), findsNothing);
      });
    }

    testWidgets('담당자를 뺐다가 같은 사람을 다시 넣거나 순서만 바꾸면 바뀐 게 없다 — 보내지 않고 닫힌다', (
      tester,
    ) async {
      final session = _session();
      final json = todoJson(id: 'e2', title: '맡긴 일', assignees: ['u2', 'u3']);
      final api = FakeTodoApi(me: 'me', todos: [json]);
      Future<void> open() => _open(
        tester,
        (c) => showTodoEditor(
          c,
          session: session,
          editing: Todo.fromJson(json),
          api: api,
        ),
      );

      // 칩의 x로 빼고 담당자 관리에서 다시 넣는다.
      await open();
      await tester.tap(
        find.descendant(
          of: _key('todo-assignee-chip-u2'),
          matching: find.byIcon(Icons.close),
        ),
      );
      await tester.pumpAndSettle();
      expect(_key('todo-assignee-chip-u2'), findsNothing);
      await tester.tap(_key('todo-assignee-add'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-assignee-option-u2'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-assignee-ok'));
      await tester.pumpAndSettle();
      expect(_key('todo-assignee-chip-u2'), findsOneWidget);
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoEditor), findsNothing);
      expect(api.callCount('update'), 0);

      // 순서만 바뀐 담당자 — 닫을 때는 "바뀐 게 있다"로 보지만(묻는다) 보낼 칸은 없다.
      await open();
      final members = session.rooms.first.members;
      _state(tester).setAssignees([
        members.firstWhere((m) => m.id == 'u3'),
        members.firstWhere((m) => m.id == 'u2'),
      ]);
      await tester.pump();
      expect(_state(tester).isDirty, isTrue);
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoEditor), findsNothing);
      expect(api.callCount('update'), 0);
      expect(find.byKey(const ValueKey('todo-editor-error')), findsNothing);

      // 한 칸이라도 바꾸면 그 칸만 보낸다.
      await open();
      await tester.enterText(_key('todo-title-field'), '고친 제목');
      await tester.pump();
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(api.lastUpdate, {'title': '고친 제목'});
      expect(find.byType(TodoEditor), findsNothing);
    });
  });

  // ────────────────────────── 패널 안 목록·메뉴 — 바깥 누르기 ──────────────────────────
  group('패널 안 생성 화면의 대화방 목록·알림 메뉴 — 창 전체 위에(자리는 패널 안)', () {
    testWidgets('대화방 칸의 목록과 알림 메뉴는 패널 안에 뜨고, 채팅 쪽을 누르면 닫히며 그 누름은 채팅에 가지 않는다', (
      tester,
    ) async {
      final session = _session();
      final api = FakeTodoApi(me: 'me');
      await _openPanel(
        tester,
        (context) => showTodoEditor(
          context,
          session: session,
          api: api,
          mode: TodoViewMode.panel,
          onClosePanel: () {},
        ),
      );
      final panel = tester.getRect(_key('panel-host'));
      void expectInPanel(Rect rect, String what) {
        expect(
          rect.left,
          greaterThanOrEqualTo(panel.left - 0.01),
          reason: what,
        );
        expect(rect.right, lessThanOrEqualTo(panel.right + 0.01), reason: what);
        expect(
          rect.bottom,
          lessThanOrEqualTo(panel.bottom + 0.01),
          reason: what,
        );
      }

      Future<void> closeFromChat(Finder shown, String what) async {
        final before = _chatTaps;
        await tester.tapAt(_chatPoint);
        await tester.pumpAndSettle();
        expect(shown, findsNothing, reason: '$what — 채팅 쪽을 누르면 닫힌다');
        expect(_chatTaps, before, reason: '$what — 그 누름은 채팅에 가지 않는다');
      }

      // 대화방 칸 — 칸 바로 아래·칸 폭의 목록(루트 Overlay).
      await tester.tap(_key('todo-room-field'));
      await tester.pumpAndSettle();
      final dropdown = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_RoomPickerDropdown',
      );
      expect(dropdown, findsOneWidget);
      final field = tester.getRect(_key('todo-room-field'));
      final list = tester.getRect(dropdown);
      expectInPanel(list, '대화방 목록');
      expect(list.left, moreOrLessEquals(field.left, epsilon: 0.5));
      expect(list.width, moreOrLessEquals(field.width, epsilon: 0.5));
      expect(list.top, greaterThan(field.bottom));
      expect(
        find.descendant(of: _key('panel-nav'), matching: dropdown),
        findsNothing,
        reason: '패널의 중첩 Overlay가 아니라 루트 Overlay',
      );
      await closeFromChat(dropdown, '대화방 목록');
      expect(find.text('대화방 선택'), findsOneWidget, reason: '고르지 않았다');

      // 알림 메뉴 — 상자 폭 그대로, 상자 바로 아래.
      await tester.ensureVisible(_key('todo-reminder-add'));
      await tester.pumpAndSettle();
      await tester.tap(_key('todo-reminder-add'));
      await tester.pumpAndSettle();
      final option = _key('todo-reminder-option-day');
      expect(option, findsOneWidget);
      expect(
        ModalRoute.of(tester.element(option))?.settings.name,
        todoPopupRouteName,
      );
      final box = tester.getRect(_key('todo-reminder-add'));
      final menu = tester.getRect(
        find.ancestor(of: option, matching: find.byType(Material)).first,
      );
      expectInPanel(menu, '알림 메뉴');
      expect(menu.width, moreOrLessEquals(box.width, epsilon: 0.5));
      expect(menu.left, moreOrLessEquals(box.left, epsilon: 0.5));
      expect(menu.top, greaterThan(box.bottom));
      await closeFromChat(option, '알림 메뉴');
      expect(_key('todo-reminder-0'), findsNothing, reason: '고르지 않았다');

      // 기간 판 — 칸을 덮지 않고 패널 안(루트 Overlay), 채팅 쪽을 누르면 닫히고 그 누름은 채팅에 가지 않는다.
      await _openPeriod(tester);
      final popup = tester.getRect(_popup);
      expectInPanel(popup, '기간 판');
      expect(popup.top, greaterThanOrEqualTo(panel.top));
      expect(
        popup.overlaps(tester.getRect(_key('todo-period-field'))),
        isFalse,
      );
      expect(
        popup.left,
        moreOrLessEquals(
          tester.getRect(_key('todo-period-field')).left,
          epsilon: 0.5,
        ),
      );
      await closeFromChat(_popup, '기간 판');
      // 시간 목록이 열려 있어도 채팅 쪽을 누르면 판째 닫힌다.
      await _openPeriod(tester);
      final now = DateTime.now();
      await _tapDay(tester, DateTime(now.year, now.month, 10));
      await tester.tap(_key('todo-time-start'));
      await tester.pumpAndSettle();
      expectInPanel(tester.getRect(_key('todo-time-list')), '시간 목록');
      await closeFromChat(_key('todo-time-list'), '시간 목록');
      expect(_popup, findsNothing);
      expect(find.byType(TodoEditor), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
