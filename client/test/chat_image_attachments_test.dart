import 'dart:ui' as ui;

import 'package:client/models/message.dart';
import 'package:client/screens/image_viewer_screen.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/clipboard_image.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/attachment_widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';

MessageAttachment _image(String id) => MessageAttachment(
  id: id,
  kind: 'image',
  fileUrl: '/uploads/$id.png',
  fileName: '$id.png',
  thumbnailUrl: '/uploads/${id}_thumb.jpg',
);

MessageAttachment _file(String id) => MessageAttachment(
  id: id,
  kind: 'file',
  fileUrl: '/uploads/$id.pdf',
  fileName: '$id.pdf',
);

/// [width]×[height] 픽셀짜리 PNG — 뷰어가 원본 크기를 재는지 보려고 만든다.
Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const Color(0xFF3366FF),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// 이미지 도구모음의 더보기 — 썸네일과 뷰어가 같다. 다운로드는 도구모음 버튼이라 메뉴엔 없다.
void _expectImageMenu() {
  for (final label in [
    '파일 전달',
    '인쇄',
    '즐겨찾기',
    if (canCopyImageToClipboard) '복사',
    '원본 파일 보기',
  ]) {
    expect(find.text(label), findsOneWidget, reason: label);
  }
  expect(find.text('다운로드'), findsNothing);
}

void main() {
  Session session() {
    final s = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    s.serverUrl = 'https://test.local';
    return s;
  }

  Message message() => Message(
    id: 'm1',
    roomId: 'r1',
    senderName: '송병근',
    type: MessageType.image,
    createdAt: DateTime(2026, 9, 23, 14),
    fileUrl: '/uploads/a.png',
    fileName: 'a.png',
  );

  Future<void> pump(
    WidgetTester tester,
    List<MessageAttachment> attachments, {
    double width = 900,
    bool withMessage = false,
    void Function(Message message)? onOpenThread,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: ChatImageAttachments(
              session: session(),
              attachments: attachments,
              message: withMessage ? message() : null,
              onOpenThread: onOpenThread,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('한 장이면 가로 650px로 크게 보인다', (tester) async {
    await pump(tester, [_image('a')]);
    final box = tester.getSize(find.byType(ChatImageAttachments));
    expect(box.width, closeTo(kChatImageMaxWidth, 1));
    // 세로는 원본 비율대로 잡되 1열일 때의 한도(200px)를 넘지 않는다.
    expect(box.height, lessThanOrEqualTo(chatImageMaxHeight(1) + 1));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('창이 좁아지면 미리보기도 같이 줄어든다', (tester) async {
    await pump(tester, [_image('a')], width: 420);
    final box = tester.getSize(find.byType(ChatImageAttachments));
    expect(box.width, lessThan(kChatImageMaxWidth));
    expect(box.width, closeTo(420, 1));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('여러 장이면 한 줄에 3장씩 격자로 놓인다', (tester) async {
    await pump(tester, [_image('a'), _image('b'), _image('c'), _image('d')]);
    // 4장 → 3 + 1 두 줄.
    final tiles = find.byType(ClipRRect);
    expect(tiles, findsNWidgets(4));
    final first = tester.getRect(tiles.at(0));
    final third = tester.getRect(tiles.at(2));
    final fourth = tester.getRect(tiles.at(3));
    expect(third.top, closeTo(first.top, 1)); // 같은 줄
    expect(fourth.top, greaterThan(first.bottom)); // 다음 줄
    // 3장이 한 줄에 들어가고(폭 650 안), 두 줄 전체 높이는 2줄 상한(300px) 안이다.
    expect(third.right, lessThanOrEqualTo(kChatImageMaxWidth + 1));
    expect(
      fourth.bottom - first.top,
      lessThanOrEqualTo(chatImageMaxHeight(2) + 1),
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('썸네일을 누르면 그 장부터 뷰어가 열린다', (tester) async {
    await pump(tester, [_image('a'), _image('b'), _image('c')]);

    await tester.tap(find.byType(ClipRRect).at(1));
    // 뷰어는 이미지를 기다리며 스피너를 계속 돌리므로 pumpAndSettle은 끝나지 않는다.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final viewer = tester.widget<ImageViewerScreen>(
      find.byType(ImageViewerScreen),
    );
    expect(viewer.images.length, 3);
    expect(viewer.initialIndex, 1);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('썸네일에 마우스를 올리면 댓글·다운로드·더보기 도구모음이 나온다', (tester) async {
    Message? opened;
    await pump(
      tester,
      [_image('a')],
      withMessage: true,
      onOpenThread: (m) => opened = m,
    );

    // 올리기 전에는 없다(메시지 도구모음과 같은 ⋮ 더보기 버튼).
    expect(find.byIcon(Icons.more_vert), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(ChatImageAttachments)));
    await tester.pump();
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
    expect(find.byTooltip('댓글'), findsOneWidget);
    expect(find.byTooltip('다운로드'), findsOneWidget);

    await tester.tap(find.byTooltip('댓글'));
    expect(opened?.id, 'm1');

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pump();
    _expectImageMenu();

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('뷰어: 상단 바에 보낸 사람·파일 정보와 버튼이 있고, 도구모음은 3초 뒤 사라진다', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ImageViewerScreen(
          images: const [
            ViewerImage(
              url: '/uploads/a.png',
              fileName: 'a.png',
              fileSize: 344,
            ),
            ViewerImage(url: '/uploads/b.png', fileName: 'b.png'),
          ],
          session: session(),
          message: message(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('송병근'), findsOneWidget);
    expect(find.text('2026/09/23 PM 02:00'), findsOneWidget);
    expect(find.text('a.png · 344bytes'), findsOneWidget);
    // 썸네일과 같은 도구모음 — 다운로드 · 더보기(댓글은 방을 알 때만).
    expect(find.byTooltip('다운로드'), findsOneWidget);
    expect(find.byTooltip('더보기'), findsOneWidget);
    expect(find.byTooltip('인쇄'), findsNothing);
    expect(find.byTooltip('파일 전달'), findsNothing);
    expect(find.text('1 / 2'), findsOneWidget);

    await tester.tap(find.byTooltip('더보기'));
    await tester.pump();
    _expectImageMenu();
    await tester.tapAt(const Offset(600, 400)); // 메뉴 닫기
    await tester.pump();

    // 열리자마자 도구모음이 보이고, 3초 뒤에 사라진다.
    AnimatedOpacity bar() =>
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(bar().opacity, 1);
    await tester.pump(const Duration(seconds: 4));
    expect(bar().opacity, 0);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
  testWidgets('여러 장이면 말풍선 아래 오른쪽 끝에 "전체 다운로드"가 붙고, 한 장이면 없다', (tester) async {
    await pump(tester, [_image('a')]);
    expect(find.textContaining('전체 다운로드'), findsNothing);

    await pump(tester, [_image('a'), _image('b'), _image('c')]);
    final button = find.text('전체 다운로드 (3)');
    expect(button, findsOneWidget);
    // 사진 묶음 아래에, 오른쪽 끝에 붙는다.
    final grid = tester.getRect(find.byType(Wrap));
    final bar = tester.getRect(find.byType(TextButton));
    expect(bar.top, greaterThanOrEqualTo(grid.bottom));
    expect(bar.right, closeTo(grid.right, 1));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('파일 여러 개면 목록으로 쌓이고 맨 아래 오른쪽에 "전체 다운로드"가 붙는다', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: ChatFileAttachments(
              session: session(),
              attachments: [_file('a'), _file('b')],
            ),
          ),
        ),
      ),
    );
    expect(find.text('a.pdf'), findsOneWidget);
    expect(find.text('b.pdf'), findsOneWidget);
    expect(find.text('전체 다운로드 (2)'), findsOneWidget);

    final second = tester.getRect(find.byType(DownloadableFile).at(1));
    final bar = tester.getRect(find.byType(TextButton));
    expect(bar.top, greaterThanOrEqualTo(second.bottom));
    expect(
      bar.right,
      closeTo(tester.getRect(find.byType(ChatFileAttachments)).right, 1),
    );
  });

  /// 파일 말풍선을 그리고 각 파일 줄의 카드·진행 표시 자리 위치를 돌려준다.
  Future<List<({Rect card, Rect slot})>> pumpFiles(
    WidgetTester tester,
    Widget files,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(alignment: Alignment.topLeft, child: files),
        ),
      ),
    );
    final tiles = find.byType(DownloadableFile);
    return [
      for (var i = 0; i < tiles.evaluate().length; i++)
        (
          card: tester.getRect(
            find
                .descendant(of: tiles.at(i), matching: find.byType(Container))
                .first,
          ),
          slot: tester.getRect(
            find.descendant(
              of: tiles.at(i),
              matching: find.byKey(const ValueKey('file-progress-slot')),
            ),
          ),
        ),
    ];
  }

  MessageAttachment named(String id, String name) => MessageAttachment(
    id: id,
    kind: 'file',
    fileUrl: '/uploads/$id.pdf',
    fileName: name,
  );

  testWidgets('파일 하나 — 카드 오른쪽에 진행 표시 자리를 비워 두고 그 오른쪽에 단추 자리, 합쳐서 최대 650', (
    tester,
  ) async {
    final rows = await pumpFiles(
      tester,
      DownloadableFile(
        session: session(),
        url: 'https://test.local/uploads/a.pdf',
        fileName: 'a.pdf',
        maxWidth: kChatImageMaxWidth,
        inlineActions: true,
      ),
    );
    final (:card, :slot) = rows.single;
    expect(slot.left, greaterThanOrEqualTo(card.right), reason: '카드 오른쪽');
    expect(slot.width, kFileProgressSlotWidth, reason: '받지 않을 때도 자리를 비워 둔다');
    final whole = tester.getRect(find.byType(DownloadableFile));
    expect(whole.right, greaterThan(slot.right), reason: '그 오른쪽에 단추 자리');
    expect(
      whole.width,
      lessThan(kChatImageMaxWidth),
      reason: '짧은 이름이면 650까지 늘이지 않는다',
    );

    // 아주 긴 이름이어도 합쳐서 650을 넘지 않고, 이름이 잘린다.
    final long = await pumpFiles(
      tester,
      DownloadableFile(
        session: session(),
        url: 'https://test.local/uploads/b.pdf',
        fileName: '${'아주 긴 파일 이름 ' * 20}.pdf',
        maxWidth: kChatImageMaxWidth,
        inlineActions: true,
      ),
    );
    expect(
      tester.getSize(find.byType(DownloadableFile)).width,
      kChatImageMaxWidth,
    );
    expect(long.single.slot.width, kFileProgressSlotWidth);
  });

  testWidgets('파일 여러 개 — 가장 긴 카드에 폭을 맞춰 카드·진행 표시 자리가 가지런하고, 최대 650', (
    tester,
  ) async {
    // 마우스를 올려 단추를 띄우는 PC 화면.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final rows = await pumpFiles(
      tester,
      ChatFileAttachments(
        session: session(),
        attachments: [
          named('a', 'a.pdf'),
          named('b', '분기별 영업 실적 보고서 최종본.xlsx'),
        ],
      ),
    );
    expect(rows[0].card.width, rows[1].card.width, reason: '가장 긴 카드 폭에 맞춘다');
    expect(
      rows[0].slot.left,
      rows[1].slot.left,
      reason: '진행 표시 자리가 위아래로 가지런하다',
    );
    expect(rows[0].slot.left, greaterThanOrEqualTo(rows[0].card.right));
    expect(
      tester.getSize(find.byType(ChatFileAttachments)).width,
      lessThan(kChatImageMaxWidth),
      reason: '이름이 짧으면 650까지 늘이지 않는다',
    );

    await pumpFiles(
      tester,
      ChatFileAttachments(
        session: session(),
        attachments: [
          named('a', 'a.pdf'),
          named('b', '${'아주 긴 파일 이름 ' * 20}.pdf'),
        ],
      ),
    );
    expect(
      tester.getSize(find.byType(ChatFileAttachments)).width,
      kChatImageMaxWidth,
      reason: '아주 길면 650에서 멈춘다',
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('휴대폰(길게 눌러 메뉴)에서는 진행 표시·단추 자리를 비워 두지 않는다', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: ChatFileAttachments(
              session: session(),
              attachments: [named('a', 'a.pdf'), named('b', 'b.pdf')],
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('file-progress-slot')), findsNothing);
    expect(find.text('a.pdf'), findsOneWidget);
  });

  testWidgets('"전체 다운로드" 바탕색은 마우스를 올렸을 때보다 연하다', (tester) async {
    await pump(tester, [_image('a'), _image('b')]);
    final style = tester.widget<TextButton>(find.byType(TextButton)).style!;
    final base = style.backgroundColor!.resolve({})!;
    final hover = style.overlayColor!.resolve({WidgetState.hovered})!;
    expect(base.a, greaterThan(0)); // 바탕이 깔려 있다
    expect(base.a, lessThan(hover.a)); // 호버 때 한 겹 더 진해진다

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  group('뷰어 넘기기', () {
    Message imageMessage(
      String id,
      String sender,
      int minute, {
      List<MessageAttachment> attachments = const [],
      bool deleted = false,
    }) => Message(
      id: id,
      roomId: 'r1',
      senderName: sender,
      type: MessageType.image,
      createdAt: DateTime(2026, 9, 23, 14, minute),
      fileUrl: '/uploads/$id.png',
      fileName: '$id.png',
      attachments: attachments,
      deleted: deleted,
    );

    Future<void> openViewer(WidgetTester tester, Widget viewer) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: viewer));
      await tester.pump();
    }

    Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300)); // 넘기는 애니메이션
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    }

    testWidgets('키보드 ←/→로 앞뒤 장을 넘긴다', (tester) async {
      await openViewer(
        tester,
        const ImageViewerScreen(
          images: [
            ViewerImage(url: '/uploads/a.png'),
            ViewerImage(url: '/uploads/b.png'),
            ViewerImage(url: '/uploads/c.png'),
          ],
        ),
      );
      expect(find.text('1 / 3'), findsOneWidget);

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('2 / 3'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight); // 끝에서는 더 안 간다
      expect(find.text('3 / 3'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(find.text('2 / 3'), findsOneWidget);

      await close(tester);
    });

    test('방 사진 목록: 시간 순서로, 지운 메시지는 빼고, 한 메시지의 여러 장을 이어 붙인다', () {
      final s = session();
      final older = imageMessage('m1', '김철수', 1);
      final multi = imageMessage(
        'm2',
        '송병근',
        2,
        attachments: [_image('x'), _image('y')],
      );
      final gone = imageMessage('m3', '이영희', 3, deleted: true);
      final text = Message(
        id: 't1',
        roomId: 'r1',
        senderName: '김철수',
        type: MessageType.text,
        createdAt: DateTime(2026, 9, 23, 14, 0),
        text: '안녕',
      );
      final images = roomViewerImages(s, [multi, gone, text, older]);
      expect(images.map((v) => v.id), ['m1#0', 'm2#0', 'm2#1']);
      expect(images.map((v) => v.message?.senderName), ['김철수', '송병근', '송병근']);
    });

    testWidgets('앞뒤 메시지 사진까지 넘기고, 맨 앞에 닿으면 과거 메시지를 불러와 이어 붙인다', (tester) async {
      final s = session();
      final changes = ChangeNotifier();
      addTearDown(changes.dispose);
      final messages = [
        imageMessage('m1', '김철수', 1),
        imageMessage('m2', '송병근', 2, attachments: [_image('x'), _image('y')]),
      ];
      var hasOlder = true;
      var loads = 0;
      final source = ViewerImageSource(
        changes: changes,
        images: () => roomViewerImages(s, messages),
        hasOlder: () => hasOlder,
        loadOlder: () async {
          loads++;
          messages.insert(0, imageMessage('m0', '이영희', 0));
          hasOlder = false;
          // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
          changes.notifyListeners();
        },
      );
      final images = source.images();
      await openViewer(
        tester,
        ImageViewerScreen(
          images: images,
          initialIndex: images.indexWhere((v) => v.id == 'm2#1'),
          session: s,
          message: messages[1],
          source: source,
        ),
      );
      // 누른 장(송병근의 둘째 장)에서 시작한다 — 맨 앞과 멀어서 아직 과거 메시지는 안 부른다.
      expect(find.text('3 / 3'), findsOneWidget);
      expect(find.text('송병근'), findsOneWidget);
      expect(loads, 0);

      // 같은 메시지의 첫 장 — 맨 앞에 가까워져서 과거 메시지를 불러오고, 앞에 붙은 장 때문에
      // 번호만 밀린다(보던 장은 그대로).
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(loads, 1);
      expect(find.text('3 / 4'), findsOneWidget);
      expect(find.text('송병근'), findsOneWidget);

      // 앞 메시지(김철수)의 사진 — 상단 바도 그 메시지를 따른다.
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(find.text('2 / 4'), findsOneWidget);
      expect(find.text('김철수'), findsOneWidget);

      // 불러온 과거 사진까지 넘어간다.
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(find.text('1 / 4'), findsOneWidget);
      expect(find.text('이영희'), findsOneWidget);

      // 뒤로도 이어서 — 송병근의 두 번째 장까지.
      for (var i = 0; i < 3; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(find.text('4 / 4'), findsOneWidget);
      expect(find.text('송병근'), findsOneWidget);

      await close(tester);
    });
  });

  group('뷰어 배율', () {
    Future<PhotoViewControllerBase> openViewer(
      WidgetTester tester,
      Uint8List bytes,
    ) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: ImageViewerScreen(
            images: [
              ViewerImage(
                url: '/uploads/x.png',
                bytesFuture: Future.value(bytes),
              ),
            ],
          ),
        ),
      );
      // 이미지 디코딩은 실제 비동기로 돈다.
      for (var i = 0; i < 5 && find.byType(PhotoView).evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await tester.pump();
      return tester.widget<PhotoView>(find.byType(PhotoView)).controller!;
    }

    /// 이미지가 그려지는 자리 — 상단 바를 뺀 영역.
    Size viewport(WidgetTester tester) => tester.getSize(find.byType(PageView));

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    }

    testWidgets('원본이 창보다 크면 처음부터 화면에 맞춰 연다', (tester) async {
      final bytes = (await tester.runAsync(() => _png(3000, 1000)))!;
      final photo = await openViewer(tester, bytes);
      final area = viewport(tester);
      final fit = [
        area.width / 3000,
        area.height / 1000,
      ].reduce((a, b) => a < b ? a : b);
      expect(photo.scale, closeTo(fit, 0.001));
      expect(find.text('${(fit * 100).round()}%'), findsOneWidget);
      await close(tester);
    });

    testWidgets('원본이 창보다 작으면 100%로 열고, "화면에 맞춤"을 누르면 꽉 차게 키운다', (tester) async {
      final bytes = (await tester.runAsync(() => _png(200, 100)))!;
      final photo = await openViewer(tester, bytes);
      expect(photo.scale, closeTo(1, 0.001));
      expect(find.text('100%'), findsOneWidget);

      await tester.tap(find.byTooltip('화면에 맞춤'));
      await tester.pump();
      final area = viewport(tester);
      final fit = [
        area.width / 200,
        area.height / 100,
      ].reduce((a, b) => a < b ? a : b);
      expect(photo.scale, closeTo(fit, 0.001));
      // 가로나 세로 중 한쪽이 창에 꽉 찬다.
      final drawn = Size(200 * fit, 100 * fit);
      expect(
        (drawn.width - area.width).abs() < 1 ||
            (drawn.height - area.height).abs() < 1,
        isTrue,
      );

      // 배율 숫자를 누르면 다시 100%.
      await tester.tap(find.text('${(fit * 100).round()}%'));
      await tester.pump();
      expect(photo.scale, closeTo(1, 0.001));
      await close(tester);
    });

    testWidgets('90° 돌린 뒤 "화면에 맞춤"은 가로·세로를 바꿔서 맞춘다', (tester) async {
      final bytes = (await tester.runAsync(() => _png(3000, 1000)))!;
      final photo = await openViewer(tester, bytes);
      await tester.tap(find.byTooltip('회전'));
      await tester.pump();
      await tester.tap(find.byTooltip('화면에 맞춤'));
      await tester.pump();
      final area = viewport(tester);
      final fit = [
        area.width / 1000,
        area.height / 3000,
      ].reduce((a, b) => a < b ? a : b);
      expect(photo.scale, closeTo(fit, 0.001));
      await close(tester);
    });
  });
}
