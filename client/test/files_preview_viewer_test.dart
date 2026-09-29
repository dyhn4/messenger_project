import 'dart:convert';

import 'package:client/models/team.dart';
import 'package:client/screens/files_screen.dart';
import 'package:client/screens/image_viewer_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/attachment_widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _json = {'content-type': 'application/json; charset=utf-8'};

Map<String, dynamic> _row(
  String id,
  String sender,
  int minute, {
  String type = 'image',
  String? ext,
}) => {
  'id': id,
  'roomId': 'r1',
  'senderId': 'u-$id',
  'senderName': sender,
  'type': type,
  'fileUrl': '/uploads/$id.${ext ?? 'png'}',
  'fileName': '$id.${ext ?? 'png'}',
  'createdAt': DateTime(2026, 9, 23, 14, minute).millisecondsSinceEpoch,
};

void main() {
  late List<String> favoritePosts;

  Session session() {
    favoritePosts = [];
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/attachments') {
        // 서버는 최신순으로 준다.
        return http.Response(
          jsonEncode([
            _row('m3', '이영희', 3),
            _row('doc', '김철수', 2, type: 'file', ext: 'pdf'),
            _row('m2', '송병근', 2),
            _row('m1', '김철수', 1),
          ]),
          200,
          headers: _json,
        );
      }
      if (request.method == 'POST' && path.endsWith('/favorite-file')) {
        favoritePosts.add(path);
        return http.Response(
          jsonEncode({'favorited': true}),
          200,
          headers: _json,
        );
      }
      return http.Response('[]', 200, headers: _json);
    });
    final s = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    s.serverUrl = 'https://test.local';
    s.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: client,
    );
    s.userId = 'me';
    s.currentTeam = Team(id: 't1', name: '팀', createdAt: DateTime(2026));
    return s;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('파일 패널 "메시지" 화면: 사진에 마우스를 올리면 즐겨찾기 · 더보기, 누르면 앞뒤 사진까지 넘기는 뷰어', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FilesScreen(session: session())),
      ),
    );
    await tester.pump();
    await tester.pump();

    // 송병근의 사진 줄을 눌러 "메시지" 화면으로.
    await tester.tap(find.text('m2.png'));
    await tester.pump();
    expect(find.text('메시지'), findsOneWidget);
    final image = find.byType(DownloadableImage);
    expect(image, findsOneWidget);

    // 올리기 전에는 툴바가 없다(즐겨찾기 안 한 사진).
    expect(find.byIcon(Icons.star_border), findsNothing);
    expect(find.byIcon(Icons.more_vert), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(image));
    await tester.pump();
    expect(find.byIcon(Icons.star_border), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
    // 다운로드 버튼 대신 목록 줄과 같은 도구들이다.
    expect(find.byIcon(Icons.download_outlined), findsNothing);

    // 더보기 메뉴 — 파일 전달 · 다운로드 · 즐겨찾기 · 원본 파일 보기.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pump();
    for (final label in ['파일 전달', '다운로드', '즐겨찾기', '원본 파일 보기']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.byIcon(Icons.more_vert)); // 다시 눌러 닫는다
    await tester.pump();
    expect(find.text('원본 파일 보기'), findsNothing);

    // 별을 누르면 즐겨찾기에 담기고, 마우스를 치워도 노란 별은 남는다.
    await tester.tap(find.byIcon(Icons.star_border));
    await tester.pump();
    await tester.pump();
    expect(favoritePosts, ['/api/messages/m2/favorite-file']);
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(find.byIcon(Icons.star), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsNothing);

    // 사진을 누르면 뷰어 — 목록의 사진들(파일은 빼고)을 시간 순서로, 누른 사진부터.
    await tester.tap(image);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final viewer = tester.widget<ImageViewerScreen>(
      find.byType(ImageViewerScreen),
    );
    expect(viewer.images.map((v) => v.message?.id), ['m1', 'm2', 'm3']);
    expect(viewer.initialIndex, 1);
    expect(find.text('2 / 3'), findsOneWidget);
    expect(find.text('송병근'), findsWidgets);

    // 키보드 →로 다음(더 최근) 메시지의 사진 — 상단 바도 그 메시지를 따른다.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('3 / 3'), findsOneWidget);
    expect(find.text('이영희'), findsWidgets);

    await close(tester);
  });
}
