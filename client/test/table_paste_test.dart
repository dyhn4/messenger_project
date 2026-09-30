import 'dart:convert';
import 'dart:io';


import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/clipboard_paste.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/services/table_image.dart';
import 'package:client/services/table_paste.dart';
import 'package:client/widgets/chat_input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

/// 표 이미지 붙여넣기(잔디 "표 이미지 삽입") — 표 파싱(TSV·HTML), 붙여넣기 결정, 표 이미지 그리기(순수 함수·캔버스), 입력칸의
/// Ctrl+V / Ctrl+Shift+V 분기. 클립보드는 가짜로 끼운다.

const _tsv = '이름\t수량\t단가\n사과\t3\t1,200\n배\t10\t3,400\n';

void main() {
  group('parseTsv', () {
    test('탭·줄바꿈으로 나누고 끝의 빈 줄은 버린다', () {
      expect(parseTsv(_tsv), [
        ['이름', '수량', '단가'],
        ['사과', '3', '1,200'],
        ['배', '10', '3,400'],
      ]);
      expect(parseTsv('a\tb\r\nc\td\r\n'), [
        ['a', 'b'],
        ['c', 'd'],
      ]);
    });

    test('칸 수가 다른 행은 빈 칸으로 채워 모양을 맞춘다', () {
      expect(parseTsv('a\tb\tc\nd\te'), [
        ['a', 'b', 'c'],
        ['d', 'e', ''],
      ]);
      expect(parseTsv('a\t\tc\n'), [
        ['a', '', 'c'],
      ]);
    });

    test('엑셀식 따옴표 칸 — 줄바꿈·탭·따옴표를 칸 안에 담는다', () {
      expect(parseTsv('"줄1\n줄2"\t"a\tb"\t"say ""hi"""\nx\ty\tz\n'), [
        ['줄1\n줄2', 'a\tb', 'say "hi"', ],
        ['x', 'y', 'z'],
      ]);
    });

    test('칸 가운데의 큰따옴표는 그냥 글자다', () {
      expect(parseTsv('5" 파이프\t3\n1\t2\n'), [
        ['5" 파이프', '3'],
        ['1', '2'],
      ]);
    });

    test('빈 문자열은 빈 표', () {
      expect(parseTsv(''), isEmpty);
    });
  });

  group('parseHtmlTable', () {
    test('기본 표 — td/th와 머리글 표시', () {
      final t = parseHtmlTable(
        '<table><tr><th>이름</th><th>수량</th></tr>'
        '<tr><td>사과</td><td>3</td></tr></table>',
      )!;
      expect(t.cells, [
        ['이름', '수량'],
        ['사과', '3'],
      ]);
      expect(t.hasHeader, isTrue);
    });

    test('th가 없으면 머리글 아님, 대소문자·속성 무관', () {
      final t = parseHtmlTable(
        '<TABLE border=1><TR><TD class=x1 style="a:b">A</TD><TD>B</TD></TR>'
        '<TR><TD>C</TD><TD>D</TD></TR></TABLE>',
      )!;
      expect(t.cells, [
        ['A', 'B'],
        ['C', 'D'],
      ]);
      expect(t.hasHeader, isFalse);
    });

    test('colspan은 빈 칸으로, rowspan은 아래 행의 칸을 비워 맞춘다', () {
      final t = parseHtmlTable(
        '<table><tr><td colspan="2">합계</td><td rowspan="2">R</td></tr>'
        '<tr><td>a</td><td>b</td></tr></table>',
      )!;
      expect(t.cells, [
        ['합계', '', 'R'],
        ['a', 'b', ''],
      ]);
    });

    test('엔티티·<br>·공백 정리·style/주석 무시', () {
      final t = parseHtmlTable(
        '<table><style>td{color:red}</style><!-- c -->'
        '<tr><td>A&amp;B&nbsp;&lt;1&gt;</td><td>줄1<br>줄2</td></tr>'
        '<tr><td>  여러   공백 \n 줄  </td><td>&#48148;&#x4e00;</td></tr></table>',
      )!;
      expect(t.cells, [
        ['A&B <1>', '줄1\n줄2'],
        ['여러 공백 줄', '바一'],
      ]);
    });

    test('중첩 표는 바깥 표 칸의 글자로만 본다', () {
      final t = parseHtmlTable(
        '<table><tr><td>바깥<table><tr><td>안</td></tr></table></td><td>B</td></tr>'
        '<tr><td>C</td><td>D</td></tr></table>',
      )!;
      expect(t.cells, [
        ['바깥안', 'B'],
        ['C', 'D'],
      ]);
    });

    test('CF_HTML 머리글과 조각 표시가 앞뒤에 붙어 있어도 읽는다(엑셀·브라우저)', () {
      const html =
          'Version:0.9\r\nStartHTML:0000000105\r\nEndHTML:0000000500\r\n'
          'StartFragment:0000000141\r\nEndFragment:0000000460\r\n'
          '<html><body>\r\n<!--StartFragment--><table border=0 cellpadding=0>'
          '<col width=64 span=2><tr height=20><td>월</td><td>화</td></tr>'
          '<tr height=20><td>1</td><td>2</td></tr></table><!--EndFragment-->\r\n'
          '</body></html>';
      final t = parseHtmlTable(html)!;
      expect(t.cells, [
        ['월', '화'],
        ['1', '2'],
      ]);
    });

    test('표가 없으면 null', () {
      expect(parseHtmlTable('<p>안녕</p>'), isNull);
    });
  });

  group('detectPastedTable', () {
    test('탭 텍스트 2행 2열 이상이면 표', () {
      final t = detectPastedTable(text: _tsv)!;
      expect(t.rowCount, 3);
      expect(t.columnCount, 3);
    });

    test('한 줄·한 열·탭 없는 글·들여쓴 코드는 표가 아니다', () {
      expect(detectPastedTable(text: '안녕하세요 반갑습니다'), isNull);
      expect(detectPastedTable(text: 'a\tb\tc'), isNull); // 한 행.
      expect(detectPastedTable(text: 'a\nb\nc'), isNull); // 한 열(탭 없음).
      expect(detectPastedTable(text: 'a\t\nb\t\n'), isNull); // 채워진 열이 하나.
      expect(detectPastedTable(text: '\tfoo\n\tbar\n'), isNull); // 탭 들여쓰기.
      expect(detectPastedTable(text: null, html: null), isNull);
    });

    test('탭 텍스트가 없으면 HTML 표를 쓴다(머리글 표시도 살린다)', () {
      final t = detectPastedTable(
        html:
            '<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>',
      )!;
      expect(t.cells.first, ['A', 'B']);
      expect(t.hasHeader, isTrue);
    });

    test('탭 텍스트와 HTML이 같은 모양이면 글자 칸에 HTML 머리글 표시를 합친다', () {
      final t = detectPastedTable(
        text: 'A\tB\n1\t2\n',
        html:
            '<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>',
      )!;
      expect(t.cells, [
        ['A', 'B'],
        ['1', '2'],
      ]);
      expect(t.hasHeader, isTrue);
    });

    test('100행×30열까지만 — 넘으면 null(일반 텍스트 붙여넣기)', () {
      String grid(int rows, int cols) => List.generate(
        rows,
        (r) => List.generate(cols, (c) => 'r${r}c$c').join('\t'),
      ).join('\n');
      expect(detectPastedTable(text: grid(100, 30)), isNotNull);
      expect(detectPastedTable(text: grid(101, 5)), isNull);
      expect(detectPastedTable(text: grid(5, 31)), isNull);
    });

    test('clipboardLooksTabular — 크기 제한과 무관하게 표 모양인지', () {
      expect(clipboardLooksTabular(text: _tsv), isTrue);
      expect(clipboardLooksTabular(html: '<table></table>'), isTrue);
      expect(clipboardLooksTabular(text: '그냥 글'), isFalse);
      expect(clipboardLooksTabular(text: 'a\tb'), isFalse);
      expect(clipboardLooksTabular(), isFalse);
    });
  });

  group('decidePaste', () {
    final png = Uint8List.fromList([1, 2, 3]);

    test('엑셀 — 이미지와 표 글자가 함께면 이미지만(글자는 안 붙인다)', () {
      final d = decidePaste(ClipboardSnapshot(image: png, text: _tsv));
      expect(d, isA<PasteAsImage>());
    });

    test('엑셀 HTML만 표 모양이어도 이미지를 쓴다', () {
      final d = decidePaste(
        ClipboardSnapshot(image: png, text: 'x', html: '<table><tr></tr></table>'),
      );
      expect(d, isA<PasteAsImage>());
    });

    test('표가 아닌 이미지+글자는 예전 동작(글자도 붙이고 이미지도 올린다)', () {
      expect(
        decidePaste(ClipboardSnapshot(image: png, text: '사진 설명')),
        isA<PasteAsImageAndText>(),
      );
      expect(decidePaste(ClipboardSnapshot(image: png)), isA<PasteAsImageAndText>());
    });

    test('이미지 없이 표 글자·HTML이면 표 이미지', () {
      expect(decidePaste(const ClipboardSnapshot(text: _tsv)), isA<PasteAsTable>());
      expect(
        decidePaste(
          const ClipboardSnapshot(
            html: '<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>',
          ),
        ),
        isA<PasteAsTable>(),
      );
    });

    test('그 밖에는 글자 붙여넣기', () {
      expect(decidePaste(const ClipboardSnapshot()), isA<PasteAsText>());
      expect(decidePaste(const ClipboardSnapshot(text: '안녕')), isA<PasteAsText>());
      expect(decidePaste(const ClipboardSnapshot(text: 'a\tb')), isA<PasteAsText>());
      expect(
        decidePaste(ClipboardSnapshot(image: Uint8List(0), text: '안녕')),
        isA<PasteAsText>(),
      );
    });
  });

  group('표 이미지 그리기', () {
    const table = PastedTable([
      ['이름', '수량', '단가'],
      ['사과', '3', '1,200'],
      ['배', '10', '3,400'],
    ], hasHeader: true);

    test('layoutTable — 열 너비는 글자 길이에 맞추되 최소·최대로 묶는다', () {
      final layout = layoutTable(
        const PastedTable([
          ['a', '아주아주아주아주아주아주아주아주아주아주아주아주아주아주아주아주아주아주아주아주아주아주아주아주아주아주아주아주아주아주아주아주 긴 칸입니다'],
          ['b', 'c'],
        ]),
      );
      expect(layout.columnWidths[0], 44); // 최소 너비.
      expect(layout.columnWidths[1], 360); // 최대 너비.
      expect(layout.rowHeights[0], greaterThan(layout.rowHeights[1])); // 긴 칸은 줄바꿈으로 더 높다.
      expect(layout.width, 404);
    });

    test('tableImagePixelSize — 기본 2배, 큰 표는 긴 변 8192px에 맞춰 줄인다', () {
      const style = TableImageStyle();
      final small = layoutTable(table);
      final s = tableImagePixelSize(small, style);
      expect(s.ratio, 2);
      expect(s.width, (small.width * 2).ceil());

      final wide = PastedTable([
        List.generate(30, (i) => '아주 긴 칸 내용 $i ${'가' * 40}'),
        List.generate(30, (i) => '$i'),
      ]);
      final big = layoutTable(wide);
      final b = tableImagePixelSize(big, style);
      expect(b.ratio, lessThan(2));
      expect(b.width, lessThanOrEqualTo(8192));
      expect(b.height, lessThanOrEqualTo(8192));
    });

    testWidgets('renderTablePng — 올바른 PNG가 나온다(크기 = 레이아웃 × 배율)', (tester) async {
      final layout = layoutTable(table);
      final size = tableImagePixelSize(layout, const TableImageStyle());
      final bytes = (await tester.runAsync(() => renderTablePng(table)))!;
      expect(bytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
      final decoded = (await tester.runAsync(
        () async => img.decodePng(bytes),
      ))!;
      expect(decoded.width, size.width);
      expect(decoded.height, size.height);
      // 흰 바탕에 테두리·글자가 그려졌다(전부 흰색이 아니다).
      expect(decoded.getPixel(0, 0).r, lessThan(255), reason: '모서리에 테두리 선');
    });

    testWidgets('100행×30열 표도 그려진다', (tester) async {
      final big = PastedTable([
        for (var r = 0; r < 100; r++) [for (var c = 0; c < 30; c++) '$r,$c'],
      ]);
      final bytes = (await tester.runAsync(() => renderTablePng(big)))!;
      final decoded = (await tester.runAsync(
        () async => img.decodePng(bytes),
      ))!;
      expect(decoded.width, lessThanOrEqualTo(8192));
      expect(decoded.height, lessThanOrEqualTo(8192));
    });
  });

  group('입력칸 붙여넣기', () {
    late _Env env;

    setUp(() {
      env = _Env();
    });
    tearDown(() {
      ChatInputBar.clipboardReader = readSystemClipboard;
    });

    final excelPng = Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 6)));

    Future<void> pressPaste(WidgetTester tester, {bool shift = false}) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await env.settle(tester);
    }

    testWidgets('Ctrl+V — 엑셀 표(이미지+글자)는 이미지만 업로드 미리보기로, 글자는 안 붙는다', (tester) async {
      await env.pump(
        tester,
        ClipboardSnapshot(image: excelPng, text: _tsv, html: '<table></table>'),
      );
      await pressPaste(tester);
      expect(env.reads, 1, reason: '붙여넣기가 클립보드를 읽어야 한다');
      expect(env.uploadCount, greaterThan(0));
      expect(env.uploadedPng, isTrue);
      expect(env.text(tester), isEmpty);
    });

    testWidgets('Ctrl+V — 이미지 없이 탭 표만 있으면 표를 PNG로 그려 올린다', (tester) async {
      await env.pump(tester, const ClipboardSnapshot(text: _tsv));
      await pressPaste(tester);
      expect(env.uploadedPng, isTrue);
      expect(env.uploadedNames.any((n) => n.endsWith('.png')), isTrue);
      expect(env.text(tester), isEmpty);
    });

    testWidgets('Ctrl+V — HTML 표만 있어도 이미지로 올린다', (tester) async {
      await env.pump(
        tester,
        const ClipboardSnapshot(
          html:
              '<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>',
        ),
      );
      await pressPaste(tester);
      expect(env.uploadedPng, isTrue);
      expect(env.text(tester), isEmpty);
    });

    testWidgets('Ctrl+Shift+V — 표여도 언제나 글자만 붙인다(이미지 업로드 없음)', (tester) async {
      await env.pump(tester, const ClipboardSnapshot(text: _tsv));
      await pressPaste(tester, shift: true);
      expect(env.uploadCount, 0);
      expect(env.text(tester), _tsv);
    });

    testWidgets('Ctrl+Shift+V — 엑셀(이미지+글자)도 글자만', (tester) async {
      await env.pump(tester, ClipboardSnapshot(image: excelPng, text: _tsv));
      await pressPaste(tester, shift: true);
      expect(env.uploadCount, 0);
      expect(env.text(tester), _tsv);
    });

    testWidgets('Ctrl+Shift+V — 커서 자리·선택 영역을 바꿔 붙인다', (tester) async {
      await env.pump(tester, const ClipboardSnapshot(text: 'X\tY'));
      await tester.enterText(find.byKey(const ValueKey('chat-input')), '앞뒤');
      final field = tester.widget<TextField>(find.byKey(const ValueKey('chat-input')));
      field.controller!.selection = const TextSelection.collapsed(offset: 1);
      await pressPaste(tester, shift: true);
      expect(env.text(tester), '앞X\tY뒤');
    });

    testWidgets('Ctrl+V — 탭 없는 글·한 줄 표는 기존대로 글자 붙여넣기', (tester) async {
      await env.pump(tester, const ClipboardSnapshot(text: '안녕하세요'));
      await pressPaste(tester);
      expect(env.uploadCount, 0);
      expect(env.text(tester), '안녕하세요');

      await tester.enterText(find.byKey(const ValueKey('chat-input')), '');
      ChatInputBar.clipboardReader = () async => const ClipboardSnapshot(text: 'a\tb\tc');
      env.clipboardText = 'a\tb\tc';
      await pressPaste(tester);
      expect(env.uploadCount, 0);
      expect(env.text(tester), 'a\tb\tc');
    });

    testWidgets('Ctrl+V — 표가 아닌 이미지+글자는 글자도 붙고 이미지도 올라간다(예전 동작)', (tester) async {
      await env.pump(tester, ClipboardSnapshot(image: excelPng, text: '사진 설명'));
      await pressPaste(tester);
      expect(env.uploadedPng, isTrue);
      expect(env.text(tester), '사진 설명');
    });

    testWidgets('Ctrl+V — 이미지만 있으면 이미지가 올라간다', (tester) async {
      await env.pump(tester, ClipboardSnapshot(image: excelPng));
      await pressPaste(tester);
      expect(env.uploadedPng, isTrue);
      expect(env.text(tester), isEmpty);
    });

    testWidgets('Ctrl+V — 100행을 넘는 표는 글자로 붙인다', (tester) async {
      final big = List.generate(101, (r) => 'a$r\tb$r').join('\n');
      await env.pump(tester, ClipboardSnapshot(text: big));
      await pressPaste(tester);
      expect(env.uploadCount, 0);
      expect(env.text(tester), big);
    });

    testWidgets('폭 360에서도 넘치지 않는다', (tester) async {
      await env.pump(tester, const ClipboardSnapshot(text: _tsv), width: 360);
      await pressPaste(tester);
      expect(tester.takeException(), isNull);
      expect(env.uploadedPng, isTrue);
    });
  });
}

// ── 입력칸 시험 환경 ─────────────────────────────────────────────────

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

class _Env {
  final uploadedNames = <String>[];
  bool uploadedPng = false;
  int get uploadCount => uploadedNames.length;
  String clipboardText = '';
  int reads = 0;

  String text(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const ValueKey('chat-input')))
      .controller!
      .text;

  Future<void> pump(
    WidgetTester tester,
    ClipboardSnapshot clipboard, {
    double width = 900,
  }) async {
    clipboardText = clipboard.text ?? '';
    ChatInputBar.clipboardReader = () async {
      reads++;
      return clipboard;
    };
    // 입력칸의 기본 붙여넣기(글자)가 읽는 시스템 클립보드.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') return {'text': clipboardText};
          if (call.method == 'Clipboard.hasStrings') {
            return {'value': clipboardText.isNotEmpty};
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    // 썸네일 임시 파일을 만드는 path_provider(플러그인)를 시스템 임시 폴더로 대신한다.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => Directory.systemTemp.path,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          ),
    );

    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/upload') {
        final body = latin1.decode(request.bodyBytes);
        final name = RegExp(r'filename="([^"]+)"').firstMatch(body)?[1] ?? '';
        uploadedNames.add(name);
        if (request.bodyBytes.length > 8 &&
            latin1.decode(request.bodyBytes).contains('PNG')) {
          uploadedPng = true;
        }
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'url': '/uploads/${uploadedNames.length}-$name',
              'fileName': name,
              'size': 5,
              'mimeType': 'image/png',
            }),
          ),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response('[]', 200);
    });
    final session = Session(
      notifications: _QuietNotifications(),
      settings: AppSettings(),
    );
    session.serverUrl = 'https://test.local';
    session.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: client,
    );
    session.userId = 'me';
    session.name = '나';
    session.accountRole = AccountRole.member;
    final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
    session.teams.add(team);
    session.currentTeam = team;
    final room = Room.fromJson({
      'id': 'r1',
      'teamId': 't1',
      'type': 'topic',
      'name': '공지방',
      'members': [
        {'id': 'me', 'username': 'me', 'name': '나', 'role': 'member'},
      ],
      'createdAt': 1000,
    });
    session.rooms.add(room);
    tester.view.physicalSize = Size(width, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ChatInputBar(
              controller: session.controllerFor(room),
              session: session,
              room: room,
              stickerPickerGroupId: Object(),
              onToggleStickerPicker: () {},
              onStickerConsumed: () {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('chat-input')));
    await tester.pump();
  }

  /// 붙여넣기는 클립보드 읽기·파일 쓰기·업로드가 실제 비동기라 fake async 밖에서 조금씩 기다린다.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
  }
}
