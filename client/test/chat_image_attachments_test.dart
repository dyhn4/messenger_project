import 'package:client/models/message.dart';
import 'package:client/screens/image_viewer_screen.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/attachment_widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

MessageAttachment _image(String id) => MessageAttachment(
  id: id,
  kind: 'image',
  fileUrl: '/uploads/$id.png',
  fileName: '$id.png',
  thumbnailUrl: '/uploads/${id}_thumb.jpg',
);

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
    // 칸은 정사각형(3열 한도 420px 안)이고 3장이 한 줄에 들어간다.
    expect(first.width, closeTo(first.height, 1));
    expect(first.height, lessThanOrEqualTo(chatImageMaxHeight(3) + 1));
    expect(third.right, lessThanOrEqualTo(kChatImageMaxWidth + 1));

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

  testWidgets('썸네일에 마우스를 올리면 더보기 메뉴가 나온다', (tester) async {
    await pump(tester, [_image('a')], withMessage: true);

    // 올리기 전에는 없다.
    expect(find.byIcon(Icons.more_horiz), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(ChatImageAttachments)));
    await tester.pump();
    expect(find.byIcon(Icons.more_horiz), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pump();
    for (final label in ['파일 전달', '다운로드', '즐겨찾기', '원본 파일 보기']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }

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
    expect(find.byTooltip('인쇄'), findsOneWidget);
    expect(find.byTooltip('다운로드'), findsOneWidget);
    expect(find.byTooltip('파일 전달'), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);

    // 열리자마자 도구모음이 보이고, 3초 뒤에 사라진다.
    AnimatedOpacity bar() =>
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(bar().opacity, 1);
    await tester.pump(const Duration(seconds: 4));
    expect(bar().opacity, 0);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
