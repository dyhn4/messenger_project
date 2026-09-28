import 'dart:async';
import 'dart:convert';

import 'package:client/models/project.dart';
import 'package:client/screens/project/note_markdown.dart';
import 'package:client/screens/project/note_task_links.dart';
import 'package:client/screens/project/notes_view.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_links.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/rich_text_format.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _json = {'content-type': 'application/json'};

Map<String, dynamic> _task(
  String id,
  String key,
  String title,
  int day, {
  bool archived = false,
}) => {
  'id': id,
  'projectId': 'p1',
  'key': key,
  'title': title,
  'status': 'todo',
  'priority': 'normal',
  'assigneeName': '김민수',
  'archived': archived,
  'createdAt': DateTime(2026, 9, day).millisecondsSinceEpoch,
};

/// "/" 목록이 붙은 노트 편집기를 띄울 준비 — 새 노트를 쓰면 POST 본문을 [posted]에 담는다.
class _Harness {
  Map<String, dynamic>? posted;
  int taskFetches = 0;

  /// 업무 목록 응답을 붙잡아 둘 수 있게(불러오는 중 표시 확인용).
  Completer<void>? gate;

  /// 앞으로 몇 번 업무 목록을 실패로 돌려줄지.
  int failTasks = 0;

  late final Session session = () {
    final t0 = DateTime(2026, 9, 1, 10).millisecondsSinceEpoch;
    final s = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    s.userId = 'u1';
    s.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' && path == '/api/notes') {
          return http.Response(
            jsonEncode([
              if (posted != null)
                {
                  'id': 'n9',
                  'projectId': 'p1',
                  'title': posted!['title'],
                  'createdAt': t0,
                  'updatedAt': t0,
                },
            ]),
            200,
            headers: _json,
          );
        }
        if (request.method == 'GET' && path == '/api/projects') {
          return http.Response(
            jsonEncode([
              {
                'id': 'p1',
                'teamId': 't1',
                'name': '잔디톡',
                'identifier': 'TA',
                'color': '#5B8DEF',
                'myRole': 'owner',
                'createdAt': t0,
              },
            ]),
            200,
            headers: _json,
          );
        }
        if (request.method == 'GET' && path == '/api/projects/p1/tasks') {
          taskFetches++;
          await gate?.future;
          if (failTasks > 0) {
            failTasks--;
            return http.Response('{"error":"오류"}', 500, headers: _json);
          }
          return http.Response(
            jsonEncode([
              _task('t1', 'TA-1', '로그인 오류 수정', 1),
              _task('t2', 'TA-2', '배포 일정 정리', 2),
              _task('t3', 'TA-3', '[긴급] 서버 점검', 3),
              _task('t4', 'TA-4', '보관된 업무', 4, archived: true),
            ]),
            200,
            headers: _json,
          );
        }
        if (request.method == 'POST' && path == '/api/projects/p1/notes') {
          posted = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'id': 'n9',
              'key': 'TA-N9',
              'projectId': 'p1',
              'projectName': '잔디톡',
              'projectColor': '#5B8DEF',
              'title': posted!['title'],
              'body': posted!['body'],
              'createdBy': 'u1',
              'createdByName': 'Riley',
              'createdAt': t0,
              'updatedAt': t0,
              'canEdit': true,
              'canDelete': true,
            }),
            201,
            headers: _json,
          );
        }
        if (request.method == 'GET' && path == '/api/notes/n9') {
          return http.Response(
            jsonEncode({
              'id': 'n9',
              'key': 'TA-N9',
              'projectId': 'p1',
              'title': posted?['title'] ?? '',
              'body': posted?['body'] ?? '',
              'createdBy': 'u1',
              'createdAt': t0,
              'updatedAt': t0,
              'canEdit': true,
              'canDelete': true,
            }),
            200,
            headers: _json,
          );
        }
        return http.Response('[]', 200, headers: _json);
      }),
    );
    return s;
  }();

  Finder field(String hint) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.hintText == hint,
  );

  Finder get body => field('내용을 입력하세요');

  TextEditingController controller(WidgetTester tester) =>
      tester.widget<TextField>(body).controller!;

  /// 새 노트 편집기를 열고 제목을 넣은 뒤 본문 칸에 포커스를 준다.
  Future<void> openEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1300, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotesView(
            session: session,
            teamId: 't1',
            projectId: 'p1',
            reloadTick: 0,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ 새 노트').first);
    await tester.pumpAndSettle();
    await tester.enterText(field('제목을 입력하세요'), '회의록');
    await tester.showKeyboard(body);
    await tester.pump();
  }

  /// 본문을 [text]로(커서는 끝) — 입력기가 보내는 값처럼. [composing]이면 조합 중인 구간.
  Future<void> type(
    WidgetTester tester,
    String text, {
    TextRange composing = TextRange.empty,
    bool settle = true,
  }) async {
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
        composing: composing,
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump();
    }
  }

  /// 지금 본문 끝에 [chars]를 한 글자씩 친다(글자마다 입력기가 값을 보내는 것처럼).
  Future<void> keys(
    WidgetTester tester,
    String chars, {
    bool settle = true,
  }) async {
    for (final ch in chars.split('')) {
      final text = controller(tester).text + ch;
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ),
      );
      await tester.pump();
    }
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }
}

String _href(String id, String key, String title) => AppLinks.task(
  id: id,
  key: key,
  title: title,
  project: '잔디톡',
  color: '#5B8DEF',
  person: '김민수',
);

void main() {
  group('"/" 찾기', () {
    TextEditingValue v(String text, [int? caret]) => TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret ?? text.length),
    );

    test('줄 맨 앞·공백 뒤에서 친 "/"만 연다', () {
      expect(noteSlashTriggerAt(v(''), v('/')), 0);
      expect(noteSlashTriggerAt(v('안건 '), v('안건 /')), 3);
      expect(noteSlashTriggerAt(v('첫 줄\n'), v('첫 줄\n/')), 4);
      // 가운데에 끼워 친 것도(커서 바로 앞이 "/").
      expect(noteSlashTriggerAt(v('a  b', 2), v('a / b', 3)), 2);
      // 낱말 안의 "/"는 무시("a/b", "1/2").
      expect(noteSlashTriggerAt(v('a'), v('a/')), isNull);
      expect(noteSlashTriggerAt(v('1'), v('1/')), isNull);
      // 붙여넣기(여러 글자)·"/" 아닌 글자·지우기는 무시.
      expect(noteSlashTriggerAt(v(''), v('/ab')), isNull);
      expect(noteSlashTriggerAt(v(' '), v(' a')), isNull);
      expect(noteSlashTriggerAt(v(' /'), v(' ')), isNull);
    });
  });

  test('검색: 보관 제외는 부르는 쪽 몫, 번호·제목 순위 + 최근 것 먼저', () {
    final tasks = [
      Task.fromJson(_task('t1', 'TA-1', '로그인 오류 수정', 1)),
      Task.fromJson(_task('t2', 'TA-2', '배포 일정 정리', 2)),
      Task.fromJson(_task('t3', 'TA-3', '[긴급] 서버 점검', 3)),
      Task.fromJson(_task('t12', 'TA-12', '로그 정리', 4)),
    ];
    List<String?> keys(String q) => [
      for (final t in noteTaskLinkMatches(tasks, q)) t.key,
    ];
    expect(keys(''), ['TA-12', 'TA-3', 'TA-2', 'TA-1']);
    expect(keys('ta-1'), ['TA-1', 'TA-12']); // 딱 맞는 번호가 먼저
    expect(keys('1'), ['TA-12', 'TA-1']); // 번호 숫자로 시작
    expect(keys('로그'), ['TA-12', 'TA-1']);
    expect(keys('서버 점검'), ['TA-3']);
    expect(keys('점검 긴급'), ['TA-3']); // 낱말 순서 무관
    expect(keys('없는 업무'), isEmpty);
  });

  test('링크 글의 대괄호: 짝이 맞으면 그대로, 아니면 전각으로 — 저장했다 다시 읽어도 링크', () {
    expect(noteSafeLinkText('TA-3 [긴급] 서버 점검'), 'TA-3 [긴급] 서버 점검');
    expect(noteSafeLinkText('TA-5 a]b'), 'TA-5 a］b');
    expect(noteSafeLinkText('TA-6 [[x]]'), 'TA-6 ［［x］］');
    for (final label in ['TA-3 [긴급] 서버 점검', '[TA-1] 붙여넣은 링크']) {
      final href = _href('t3', 'TA-3', '[긴급] 서버 점검');
      final md = '앞 [$label]($href) 뒤';
      final r = noteMarkdownToRich(md);
      expect(r.text, '앞 $label 뒤');
      expect(r.runs.single.href, href);
      expect(noteRichToMarkdown(r.text, r.runs), md);
    }
    // 짝이 안 맞는 링크 글도 저장하면 링크로 남는다.
    final md = noteRichToMarkdown('a]b', [
      const TextFormatRun(0, 3, 0, 'https://a.com'),
    ]);
    expect(md, '[a］b](https://a.com)');
    expect(noteMarkdownToRich(md).runs.single.href, 'https://a.com');
  });

  test('업무 제목의 서식 기호("*"·"`"·"~~"·"<b>"·"[글](주소)")는 저장했다 다시 읽어도 글자 그대로', () {
    Task task(String title) => Task.fromJson(_task('t1', 'TA-1', title, 1));
    final href = _href('t1', 'TA-1', '제목');
    const expected = {
      '*중요* 배포': 'TA-1 ＊중요＊ 배포',
      '`config` 수정': 'TA-1 ｀config｀ 수정',
      '~~취소~~ 항목': 'TA-1 ～～취소～～ 항목',
      '**굵게** 표시': 'TA-1 ＊＊굵게＊＊ 표시',
      '<b>태그</b> 제목': 'TA-1 ＜b>태그＜/b> 제목',
      '[긴급](점검) 서버': 'TA-1 ［긴급］(점검) 서버',
      // 서식으로 읽히지 않는 기호는 그대로 둔다.
      '5*3 계산 · a ~ b · A < B': 'TA-1 5*3 계산 · a ~ b · A < B',
      '[긴급] 서버 점검': 'TA-1 [긴급] 서버 점검',
    };
    for (final MapEntry(key: title, value: label) in expected.entries) {
      expect(noteTaskLinkLabel(task(title)), label, reason: title);
      final md = noteRichToMarkdown(label, [
        TextFormatRun(0, label.length, 0, href),
      ]);
      final back = noteMarkdownToRich(md);
      expect(back.text, label, reason: md);
      expect(back.runs, hasLength(1), reason: md);
      expect(
        (back.runs.single.start, back.runs.single.end, back.runs.single.flags),
        (0, label.length, 0),
        reason: md,
      );
      expect(back.runs.single.href, href, reason: md);
    }
  });

  testWidgets('"/" 목록: 불러오는 중 → 최근 순 목록(보관 제외) → 거르기 → ↓·Enter로 링크 넣기 → 저장', (
    tester,
  ) async {
    final h = _Harness()..gate = Completer<void>();
    await h.openEditor(tester);

    // 공백 뒤 "/" → 글자 아래에 "업무 링크" 목록, 먼저 불러오는 중.
    await h.keys(tester, '참고 /', settle: false);
    expect(find.text('업무 링크'), findsOneWidget);
    expect(find.text('업무를 불러오는 중...'), findsOneWidget);
    h.gate!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('업무를 불러오는 중...'), findsNothing);
    expect(find.text('보관된 업무'), findsNothing);
    final order = [
      for (final k in ['TA-3', 'TA-2', 'TA-1'])
        tester.getTopLeft(find.text(k)).dy,
    ];
    expect(order, orderedEquals([...order]..sort()));
    // 목록은 "/" 글자 바로 아래, 그 글자 가까이에서 시작한다.
    final menu = tester.getRect(
      find
          .ancestor(of: find.text('업무 링크'), matching: find.byType(Material))
          .first,
    );
    final editor = tester.getRect(h.body);
    expect(menu.top, greaterThan(editor.top));
    expect(menu.top, lessThan(editor.top + 60));
    expect(menu.left, lessThan(editor.left + 80));

    // 거르기 — 번호·제목.
    await h.type(tester, '참고 /로그');
    expect(find.text('TA-1'), findsOneWidget);
    expect(find.text('TA-2'), findsNothing);
    await h.type(tester, '참고 /없는업무');
    expect(find.text('일치하는 업무가 없습니다.'), findsOneWidget);
    await h.type(tester, '참고 /');
    expect(find.text('TA-2'), findsOneWidget);

    // ↓ 한 번 → 두 번째(TA-2), Enter → "/"가 "TA-2 배포 일정 정리" 링크로 바뀌고 한 칸 띈다.
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown), isTrue);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('업무 링크'), findsNothing);
    expect(h.controller(tester).text, '참고 TA-2 배포 일정 정리 ');
    expect(
      h.controller(tester).selection.baseOffset,
      '참고 TA-2 배포 일정 정리 '.length,
    );

    // 목록은 편집기를 연 동안 한 번만 불러온다.
    await h.keys(tester, '/');
    expect(h.controller(tester).text, '참고 TA-2 배포 일정 정리 /');
    expect(find.text('TA-3'), findsOneWidget);
    expect(h.taskFetches, 1);
    // Tab으로도 고른다(맨 위 = 가장 최근 업무).
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.tab), isTrue);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(
      h.posted!['body'],
      '참고 [TA-2 배포 일정 정리](${_href('t2', 'TA-2', '배포 일정 정리')}) '
      '[TA-3 [긴급] 서버 점검](${_href('t3', 'TA-3', '[긴급] 서버 점검')})',
    );

    // 읽기 화면에서 링크를 누르면 그 업무가 열린다(앱 링크 처리).
    String? opened;
    final saved = AppLinks.handler;
    AppLinks.handler = (href) => opened = href;
    addTearDown(() => AppLinks.handler = saved);
    await tester.tapOnText(find.textRange.ofSubstring('TA-2 배포 일정 정리'));
    expect(opened, _href('t2', 'TA-2', '배포 일정 정리'));

    await h.dispose(tester);
  });

  testWidgets(
    'Esc는 "/검색어"를 글로 남기고 닫는다 · 낱말 안 "/"는 안 열림 · "/"를 지우면 닫힘 · 마우스로 고르기',
    (tester) async {
      final h = _Harness();
      await h.openEditor(tester);

      // 목록이 닫혀 있을 때 Enter는 그대로 입력칸 몫(줄바꿈·목록 잇기).
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isFalse);

      await h.keys(tester, 'a /로그');
      expect(find.text('업무 링크'), findsOneWidget);
      expect(find.text('TA-1'), findsOneWidget);
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.escape), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('업무 링크'), findsNothing);
      expect(h.controller(tester).text, 'a /로그');
      // 이어서 쳐도 다시 열리지 않는다.
      await h.type(tester, 'a /로그인');
      expect(find.text('업무 링크'), findsNothing);

      // "a/b" — 낱말 안의 "/".
      await h.type(tester, '');
      await h.keys(tester, 'a/b');
      expect(find.text('업무 링크'), findsNothing);

      // Backspace로 "/"까지 지우면 닫힌다.
      await h.type(tester, '');
      await h.keys(tester, 'x /');
      expect(find.text('업무 링크'), findsOneWidget);
      await h.type(tester, 'x ');
      expect(find.text('업무 링크'), findsNothing);

      // 줄 맨 앞 "/" + 마우스로 누르기.
      await h.type(tester, '');
      await h.keys(tester, '첫 줄\n/');
      expect(find.text('업무 링크'), findsOneWidget);
      await tester.tap(find.text('로그인 오류 수정'));
      await tester.pumpAndSettle();
      expect(h.controller(tester).text, '첫 줄\nTA-1 로그인 오류 수정 ');
      expect(find.text('업무 링크'), findsNothing);

      await h.dispose(tester);
    },
  );

  testWidgets('한글 조합 중: 조합 글자로 거르되 글은 건드리지 않고, 조합 중 Enter는 조합이 끝난 뒤에 고른다', (
    tester,
  ) async {
    final h = _Harness();
    await h.openEditor(tester);
    await h.keys(tester, 'x /');
    // "로"를 조합하는 중.
    await h.type(tester, 'x /로', composing: const TextRange(start: 3, end: 4));
    expect(find.text('업무 링크'), findsOneWidget);
    expect(find.text('TA-1'), findsOneWidget);
    expect(find.text('TA-2'), findsNothing);
    expect(h.controller(tester).text, 'x /로');
    expect(
      h.controller(tester).value.composing,
      const TextRange(start: 3, end: 4),
    );

    // 조합 중 Esc는 입력기 몫이라 닫지 않는다.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('업무 링크'), findsOneWidget);

    // 조합 중 Enter — 키는 막되(줄바꿈 안 됨) 글은 아직 그대로.
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isTrue);
    await tester.pump();
    expect(h.controller(tester).text, 'x /로');

    // 입력기가 조합을 끝내면(확정·조합 끝 값이 연달아 온다) 그게 다 들어온 뒤에 고른다.
    const done = TextEditingValue(
      text: 'x /로',
      selection: TextSelection.collapsed(offset: 4),
    );
    tester.testTextInput.updateEditingValue(done);
    expect(h.controller(tester).text, 'x /로');
    tester.testTextInput.updateEditingValue(done);
    await tester.pumpAndSettle();
    expect(h.controller(tester).text, 'x TA-1 로그인 오류 수정 ');
    expect(find.text('업무 링크'), findsNothing);

    await h.dispose(tester);
  });

  testWidgets('"/" 뒤로 커서만 옮기면(→·←·클릭) 닫는다 — 뒤에 있던 글을 검색어로 삼아 지우지 않는다', (
    tester,
  ) async {
    final h = _Harness();
    await h.openEditor(tester);
    await h.type(tester, '회의 일정 정리');
    // 공백 뒤(가운데)에 "/"를 친다 — 커서 뒤에 "일정 정리"가 이미 있다.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '회의 /일정 정리',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('업무 링크'), findsOneWidget);

    // → 두 번: 커서가 이미 있던 글 안으로 — 목록이 닫히고 Enter는 입력칸 몫.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('업무 링크'), findsNothing);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isFalse);
    await tester.pumpAndSettle();
    expect(h.controller(tester).text, '회의 /일정 정리');

    // 검색어를 친 뒤 ←로 되돌아가도 닫힌다.
    await h.type(tester, '');
    await h.keys(tester, 'x /로그');
    expect(find.text('TA-1'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('업무 링크'), findsNothing);
    expect(h.controller(tester).text, 'x /로그');

    // 클릭·터치로 커서만 옮겨도(글은 그대로) 닫힌다.
    await h.type(tester, '');
    await h.keys(tester, '/로그');
    expect(find.text('업무 링크'), findsOneWidget);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '/로그',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('업무 링크'), findsNothing);

    await h.dispose(tester);
  });

  testWidgets('제목·인용 줄 맨 앞에서 골라도 그 줄 서식이 링크 글에 남는다', (tester) async {
    final h = _Harness();
    await h.openEditor(tester);
    final c = h.controller(tester) as RichTextEditingController;
    String markdown() {
      final f = c.formatted();
      return noteRichToMarkdown(f.text, f.format);
    }

    final href = _href('t3', 'TA-3', '[긴급] 서버 점검');

    // 빈 줄에서 H1을 누르고 "/" → Enter.
    c.toggleHeading(1);
    await h.keys(tester, '/');
    expect(markdown(), '# /');
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isTrue);
    await tester.pumpAndSettle();
    expect(markdown(), '# [TA-3 [긴급] 서버 점검]($href)');

    // 인용 줄.
    await h.type(tester, '');
    await h.keys(tester, '본문\n');
    c.toggleQuote();
    await h.keys(tester, '/');
    expect(markdown(), '본문\n> /');
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isTrue);
    await tester.pumpAndSettle();
    expect(markdown(), '본문\n> [TA-3 [긴급] 서버 점검]($href)');

    await h.dispose(tester);
  });

  testWidgets('가만히 있는 마우스 아래에 목록이 떠도 키보드로 고른 줄은 그대로, 마우스를 움직이면 그 줄', (
    tester,
  ) async {
    final h = _Harness();
    await h.openEditor(tester);
    await h.keys(tester, '/');
    // 두 번째 줄(TA-2) 자리를 재 두고 닫는다.
    final row2 = tester.getCenter(find.text('배포 일정 정리'));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: row2);
    addTearDown(mouse.removePointer);
    await tester.pump();

    // 그 자리 아래에 목록이 다시 뜬다 — Enter는 맨 위(TA-3).
    await h.type(tester, '');
    await h.keys(tester, '/');
    expect(tester.getCenter(find.text('배포 일정 정리')), row2);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isTrue);
    await tester.pumpAndSettle();
    expect(h.controller(tester).text, 'TA-3 [긴급] 서버 점검 ');

    // 마우스를 실제로 움직이면 그 아래 줄을 고른다.
    await h.type(tester, '');
    await h.keys(tester, '/');
    await mouse.moveTo(row2 + const Offset(3, 0));
    await tester.pump();
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isTrue);
    await tester.pumpAndSettle();
    expect(h.controller(tester).text, 'TA-2 배포 일정 정리 ');

    await h.dispose(tester);
  });

  testWidgets('업무 목록을 못 불러오면 안내하고, 다음 "/"에서 다시 불러온다 · Enter는 줄바꿈으로 넘긴다', (
    tester,
  ) async {
    final h = _Harness()..failTasks = 1;
    await h.openEditor(tester);
    await h.keys(tester, '/');
    expect(find.text('업무를 불러오지 못했습니다.'), findsOneWidget);
    // 고를 게 없으면 Enter는 목록만 닫고 입력칸으로 넘긴다.
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isFalse);
    await tester.pumpAndSettle();
    expect(find.text('업무 링크'), findsNothing);
    await h.keys(tester, ' /');
    expect(find.text('TA-1'), findsOneWidget);
    expect(h.taskFetches, 2);
    await h.dispose(tester);
  });
}
