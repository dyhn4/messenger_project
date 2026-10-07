// 링크 미리보기 그림 — 서버가 받아 둔 파일(서명된 /files 상대 경로)만 우리 서버에서 받아 그리고, 바깥 사이트 주소는 그리지 않는다
// (보는 사람마다 그 사이트에 직접 접속하게 된다 — server/src/linkPreviewImage.js). 말풍선 카드와 링크 모아보기 모두 같다.
import 'dart:convert';

import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/links_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/external_image.dart';
import 'package:client/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _signed = '/files/c2lnbmVkLXRva2VuLWZvci10ZXN0';
const _fresh = '/files/ZnJlc2gtdG9rZW4tZm9yLXRlc3Q';
const _external = 'https://attacker.example/t/42.png';

String _resolve(String relative) => 'https://test.local$relative';

Future<void> _pumpCard(
  WidgetTester tester,
  LinkPreview preview, {
  Future<String?> Function()? refresh,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: LinkPreviewCard(
          preview: preview,
          resolveUrl: _resolve,
          refreshImagePath: refresh,
        ),
      ),
    ),
  );
}

/// 지금 카드가 그리는 그림 주소 — 그림 칸이 없으면 null.
String? _shownImageUrl(WidgetTester tester) {
  final found = find.byKey(const ValueKey('link-preview-image'));
  if (found.evaluate().isEmpty) return null;
  return (tester.widget<Image>(found).image as NetworkImage).url;
}

/// 그림 받기(테스트에서는 모든 HTTP 요청이 400으로 끝난다 — flutter_test)가 끝나고 카드가 다시 그려질 때까지 — 한 프레임마다
/// [onFrame]을 부른다(중간에 그린 그림 주소를 모으려고).
Future<void> _settleImage(WidgetTester tester, {void Function()? onFrame}) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
    onFrame?.call();
  }
}

void main() {
  test('serverHostedImagePath: 이 서버의 상대 경로만, 바깥 주소·프로토콜 상대 주소는 null', () {
    expect(serverHostedImagePath(_signed), _signed);
    expect(serverHostedImagePath(_external), isNull);
    expect(serverHostedImagePath('http://192.168.0.1/admin.png'), isNull);
    expect(serverHostedImagePath('//attacker.example/x.png'), isNull);
    expect(serverHostedImagePath(''), isNull);
    expect(serverHostedImagePath(null), isNull);
  });

  test('LinkPreview.fromJson: 그림은 imageFileUrl(서명 링크)에서 — 예전 앱용 imageUrl은 비어 온다', () {
    // 지금 서버: imageUrl은 늘 null(예전 앱이 빈 그림 칸을 그리지 않게), 서명 링크는 imageFileUrl로만.
    expect(
      LinkPreview.fromJson({'url': 'https://a', 'imageUrl': null, 'imageFileUrl': _signed}).serverImagePath,
      _signed,
    );
    // 업데이트 전 서버: imageUrl에 바깥 주소 — 그리지 않는다.
    expect(LinkPreview.fromJson({'url': 'https://a', 'imageUrl': _external}).serverImagePath, isNull);
    expect(LinkPreview.fromJson({'url': 'https://a', 'title': 't'}).serverImagePath, isNull);
  });

  testWidgets('말풍선 링크 카드 — 서버가 준 서명 링크는 우리 서버 주소로 그린다', (tester) async {
    await _pumpCard(
      tester,
      const LinkPreview(url: 'https://news.example/a', title: '기사 제목', imageUrl: _signed),
    );
    expect(_shownImageUrl(tester), 'https://test.local$_signed');
    expect(find.byType(ExternalImage), findsNothing);
    expect(find.text('기사 제목'), findsOneWidget);
  });

  testWidgets('말풍선 링크 카드 — 링크가 만료돼 못 받으면 새 링크를 한 번 받아 다시 그리고, 그래도 안 되면 칸을 접는다', (tester) async {
    var refreshes = 0;
    final shown = <String?>[];
    await _pumpCard(
      tester,
      const LinkPreview(url: 'https://news.example/a', title: '기사 제목', imageUrl: _signed),
      refresh: () async {
        refreshes++;
        return _fresh;
      },
    );
    shown.add(_shownImageUrl(tester));
    final imageKey = find.byKey(const ValueKey('link-preview-image'));
    final firstImageState = tester.state(imageKey);
    State? freshImageState;
    for (var i = 0; i < 4; i++) {
      await _settleImage(
        tester,
        onFrame: () {
          final url = _shownImageUrl(tester);
          shown.add(url);
          if (url == 'https://test.local$_fresh') freshImageState ??= tester.state(imageKey);
        },
      );
    }
    // 처음 링크 → (실패) 새 링크 → (또 실패) 그림 칸 없음. 새 링크는 한 번만 받는다(끝없이 다시 묻지 않게).
    expect(shown.first, 'https://test.local$_signed');
    expect(shown, contains('https://test.local$_fresh'));
    expect(shown.last, isNull);
    expect(refreshes, 1);
    // 새 링크는 새 Image로 그린다 — 같은 Image에 주소만 바꾸면 앞 링크의 실패가 남아 새 그림을 받기 전에 칸이 접힌다.
    expect(freshImageState, isNotNull);
    expect(identical(freshImageState, firstImageState), isFalse);
    expect(find.byType(AspectRatio), findsNothing);
    expect(find.text('기사 제목'), findsOneWidget);
  });

  testWidgets('말풍선 링크 카드 — 새 링크를 받을 방법이 없거나 실패하면 빈 칸을 남기지 않고 접는다', (tester) async {
    await _pumpCard(
      tester,
      const LinkPreview(url: 'https://news.example/a', title: '기사 제목', imageUrl: _signed),
    );
    for (var i = 0; i < 4; i++) {
      await _settleImage(tester);
    }
    expect(_shownImageUrl(tester), isNull);
    expect(find.byType(AspectRatio), findsNothing);

    var refreshes = 0;
    await _pumpCard(
      tester,
      const LinkPreview(url: 'https://news.example/b', title: '다른 기사', imageUrl: _fresh),
      refresh: () async {
        refreshes++;
        throw Exception('메시지를 찾을 수 없습니다.');
      },
    );
    for (var i = 0; i < 4; i++) {
      await _settleImage(tester);
    }
    expect(refreshes, 1);
    expect(find.byType(AspectRatio), findsNothing);
    expect(find.text('다른 기사'), findsOneWidget);
  });

  testWidgets('말풍선 링크 카드 — 바깥 사이트 그림 주소는 그리지 않는다(업데이트 전 서버가 줘도)', (tester) async {
    await _pumpCard(
      tester,
      const LinkPreview(url: 'https://news.example/a', title: '기사 제목', imageUrl: _external),
    );
    expect(find.byKey(const ValueKey('link-preview-image')), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(find.byType(ExternalImage), findsNothing);
    expect(find.text('기사 제목'), findsOneWidget);
  });

  testWidgets('링크 모아보기 — 서버 그림은 우리 서버에서, 바깥 그림 주소는 링크 아이콘으로', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    session.serverUrl = 'https://test.local';
    session.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/links') {
          return http.Response(
            jsonEncode([
              for (final (id, image) in [('m1', _signed), ('m2', _external)])
                {
                  'id': '$id:https://news.example/$id',
                  'messageId': id,
                  'roomId': 'r1',
                  'senderId': 'u1',
                  'senderName': '김철수',
                  'createdAt': DateTime(2026, 9, 29).millisecondsSinceEpoch,
                  'url': 'https://news.example/$id',
                  'title': '기사 $id',
                  'imageUrl': image,
                  'siteName': 'news.example',
                },
            ]),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('[]', 200, headers: const {'content-type': 'application/json'});
      }),
    );
    session.userId = 'me';
    session.currentTeam = Team(id: 't1', name: '팀', createdAt: DateTime(2026));
    session.rooms.add(
      Room(
        id: 'r1',
        teamId: 't1',
        type: RoomType.topic,
        name: '뉴스 토픽',
        members: const [],
        createdAt: DateTime(2026),
        lastRead: const {},
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LinksScreen(session: session, onOpenMessage: (_, _) {}),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('기사 m1'), findsOneWidget);
    expect(find.text('기사 m2'), findsOneWidget);
    final rowImages = tester.widgetList<Image>(find.byKey(const ValueKey('link-row-image'))).toList();
    expect(rowImages, hasLength(1));
    expect((rowImages.single.image as NetworkImage).url, 'https://test.local$_signed');
    expect(find.byType(ExternalImage), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
