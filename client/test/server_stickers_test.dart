import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:client/data/stickers.dart';
import 'package:client/models/sticker_pack.dart';
import 'package:client/screens/admin_stickers_tab.dart';
import 'package:client/screens/my_profile_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/sticker_picker.dart';
import 'package:client/widgets/sticker_view.dart';
import 'package:client/widgets/pagination.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _json = {'content-type': 'application/json; charset=utf-8'};

Map<String, dynamic> _packJson({
  bool hideSecond = false,
  bool hidePack = false,
}) => {
  'id': 'p1',
  'name': '리마인',
  'hidden': hidePack,
  'stickers': [
    for (var i = 1; i <= 3; i++)
      {
        'id': 's$i',
        'packId': 'p1',
        'url': '/files/token$i',
        'fileName': '$i.jpg',
        'mimeType': 'image/jpeg',
        'hidden': hideSecond && i == 2,
      },
  ],
};

void main() {
  tearDown(serverStickers.clear);

  test('목록: 숨긴 이모티콘은 선택창에서 빠지지만 예전 메시지용으로 id로는 찾힌다', () {
    serverStickers.replace([
      ServerStickerPack.fromJson(_packJson(hideSecond: true)),
    ], (u) => 'https://srv$u');
    final visible = serverStickers.visibleCategories;
    expect(visible.single.name, '리마인');
    expect(visible.single.stickers.map((s) => s.id), ['srv:s1', 'srv:s3']);
    final hidden = findStickerById('srv:s2');
    expect(hidden?.imageUrl, 'https://srv/files/token2');
    expect(hidden?.isImage, isTrue);
    expect(stickerPreviewText('srv:s1'), '이모티콘을 보냈습니다');
    expect(stickerPreviewText('grin'), '😄 이모티콘을 보냈습니다');
  });

  test('숨긴 세트는 선택창에 안 나오고, 모르는 id를 만나면 목록을 다시 받게 알린다', () {
    serverStickers.replace([
      ServerStickerPack.fromJson(_packJson(hidePack: true)),
    ], (u) => u);
    expect(serverStickers.visibleCategories, isEmpty);
    var missing = 0;
    serverStickers.onMissing = () => missing++;
    addTearDown(() => serverStickers.onMissing = null);
    expect(findStickerById('srv:new'), isNull);
    expect(missing, 1);
    expect(findStickerById('grin')?.emoji, '😄'); // 기본 이모티콘은 그대로
  });

  testWidgets('선택창: 그림 세트가 맨 앞 탭이고, 고르면 srv: id가 넘어온다', (tester) async {
    serverStickers.replace([
      ServerStickerPack.fromJson(_packJson()),
    ], (u) => 'https://srv$u');
    Sticker? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StickerPicker(
              onSelected: (s) => picked = s,
              settings: AppSettings(),
            ),
          ),
        ),
      ),
    );
    expect(find.widgetWithText(ChoiceChip, '리마인'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '표정'), findsOneWidget);
    // 첫 탭(리마인)이 열려 있고 그림으로 그린다.
    expect(find.byType(CachedNetworkImage), findsNWidgets(3));
    await tester.tap(find.byType(StickerView).first);
    expect(picked?.id, 'srv:s1');

    // 기본 탭으로 가면 이모지.
    await tester.tap(find.widgetWithText(ChoiceChip, '표정'));
    await tester.pump();
    expect(find.text('😄'), findsOneWidget);
  });

  testWidgets('말풍선: 그림 이모티콘은 그림, 목록에 없으면 자리만', (tester) async {
    serverStickers.replace([
      ServerStickerPack.fromJson(_packJson()),
    ], (u) => 'https://srv$u');
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              StickerView(stickerId: 'srv:s1', emojiSize: 72, imageSize: 140),
              StickerView(
                stickerId: 'srv:unknown',
                emojiSize: 72,
                imageSize: 140,
              ),
              StickerView(stickerId: 'grin', emojiSize: 72, imageSize: 140),
            ],
          ),
        ),
      ),
    );
    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.cacheKey, 'sticker-srv:s1'); // 서명 링크가 바뀌어도 같은 캐시
    expect(image.width, 140);
    // 모르는 id는 자리만(그림을 받는 중인 칸도 같은 자리 표시를 쓴다).
    expect(find.byIcon(Icons.emoji_emotions_outlined), findsWidgets);
    expect(find.text('😄'), findsOneWidget);
  });

  group('서버 관리 > 이모티콘', () {
    late Map<String, dynamic> patches;
    late List<String> deletes;
    late bool hiddenSecond;

    Session session({int packCount = 1}) {
      patches = {};
      deletes = [];
      hiddenSecond = false;
      final client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'PATCH') {
          patches[path] = jsonDecode(request.body);
          hiddenSecond = true;
          return http.Response('{}', 200, headers: _json);
        }
        if (request.method == 'DELETE') {
          deletes.add(path);
          return http.Response('{"ok":true}', 200, headers: _json);
        }
        if (path == '/api/stickers') {
          return http.Response(
            jsonEncode([
              for (var n = 0; n < packCount; n++)
                {
                  ..._packJson(hideSecond: hiddenSecond),
                  'id': n == 0 ? 'p1' : 'p${n + 1}',
                  'name': n == 0 ? '리마인' : '세트 ${n + 1}',
                  'deleted': deletes.contains(
                    '/api/stickers/packs/${n == 0 ? 'p1' : 'p${n + 1}'}',
                  ),
                },
            ]),
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
      return s;
    }

    Future<void> pumpTab(WidgetTester tester, Session s) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AdminStickersTab(session: s)),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('세트는 대표 이미지 + 이름 카드, 누르면 이모티콘 모음, 그림을 누르면 숨긴다', (tester) async {
      final s = session();
      await pumpTab(tester, s);
      expect(find.text('리마인'), findsOneWidget);
      expect(find.text('3개'), findsOneWidget);
      expect(find.byType(StickerView), findsOneWidget); // 대표 이미지 하나

      await tester.tap(find.byType(StickerView));
      await tester.pump();
      expect(find.byTooltip('세트 목록'), findsOneWidget);
      expect(find.byType(StickerView), findsNWidgets(3));
      // 더보기(⋮)는 줄 오른쪽 끝에 붙는다(탭 폭 1000).
      expect(
        tester.getRect(find.byIcon(Icons.more_vert)).right,
        greaterThan(990),
      );

      await tester.tap(find.byType(StickerView).at(1));
      await tester.pump();
      await tester.pump();
      expect(patches['/api/stickers/packs/p1/stickers/s2'], {'hidden': true});
      expect(find.text('3개 · 숨김 1'), findsOneWidget);

      await tester.tap(find.byTooltip('세트 목록'));
      await tester.pump();
      expect(find.byTooltip('세트 목록'), findsNothing);
      s.dispose();
    });

    testWidgets('대표 이미지에 마우스를 올리면 더보기 — 세트 삭제', (tester) async {
      final s = session();
      await pumpTab(tester, s);
      expect(find.byIcon(Icons.more_vert), findsNothing);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byType(StickerView)));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pump();
      for (final label in ['그림 올리기', '이름 바꾸기', '세트 숨기기', '세트 삭제']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await tester.tap(find.text('세트 삭제'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '삭제'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(deletes, ['/api/stickers/packs/p1']);
      expect(find.text('리마인'), findsNothing); // 삭제한 세트는 목록에서 빠진다
      s.dispose();
      await tester.pump(const Duration(seconds: 3)); // 알약 알림 정리
    });

    testWidgets('세트가 많으면 아래에 페이지 넘김', (tester) async {
      final s = session(packCount: 12);
      await pumpTab(tester, s);
      expect(find.byType(Pagination), findsOneWidget);
      expect(find.text('리마인'), findsOneWidget);
      expect(find.text('세트 12'), findsNothing); // 둘째 쪽
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pump();
      expect(find.text('세트 12'), findsOneWidget);
      expect(find.text('리마인'), findsNothing);
      s.dispose();
    });

    testWidgets('이모티콘/캐릭터 세그먼트를 바꾸면 그 kind만 다시 받는다', (tester) async {
      final requestedKinds = <String>[];
      Map<String, dynamic> packJson(String kind) => {
        ..._packJson(),
        'id': 'p-$kind',
        'name': kind == 'character' ? '캐릭터세트' : '리마인',
        'kind': kind,
      };
      final client = MockClient((request) async {
        if (request.url.path == '/api/stickers') {
          final kind = request.url.queryParameters['kind'] ?? 'sticker';
          requestedKinds.add(kind);
          return http.Response(
            jsonEncode([packJson(kind)]),
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
      await pumpTab(tester, s);
      expect(find.text('리마인'), findsOneWidget);
      expect(requestedKinds, ['sticker']);

      await tester.tap(find.text('캐릭터'));
      await tester.pump();
      await tester.pump();
      expect(find.text('캐릭터세트'), findsOneWidget);
      expect(find.text('리마인'), findsNothing);
      expect(requestedKinds, ['sticker', 'character']);

      // "새 세트" 창 제목도 지금 고른 kind를 따라간다.
      await tester.tap(find.widgetWithText(FilledButton, '새 세트'));
      await tester.pumpAndSettle();
      expect(find.text('새 캐릭터 세트'), findsOneWidget);
      s.dispose();
    });
  });

  group('프로필 카드 > 캐릭터 선택하기: 세트에서 고르기', () {
    testWidgets('세트 탭에서 캐릭터 그림을 고르고 확인을 누르면 저장되고 창이 닫힌다', (tester) async {
      String? postedPath;
      final client = MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/api/stickers') {
          expect(request.url.queryParameters['kind'], 'character');
          return http.Response(
            jsonEncode([
              {
                'id': 'cp1',
                'name': '리마인 캐릭터',
                'kind': 'character',
                'hidden': false,
                'stickers': [
                  {
                    'id': 'c1',
                    'packId': 'cp1',
                    'url': '/files/char1',
                    'fileName': '1.png',
                    'mimeType': 'image/png',
                    'hidden': false,
                  },
                ],
              },
            ]),
            200,
            headers: _json,
          );
        }
        if (request.method == 'POST' &&
            request.url.path == '/api/users/me/avatar/character/c1') {
          postedPath = request.url.path;
          return http.Response(
            jsonEncode({
              'username': 'me',
              'name': '나',
              'avatarType': 'photo',
              'avatarUrl': '/files/signed-char1',
            }),
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
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: CharacterPickerDialog(session: s)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // 처음엔 "기본 캐릭터" 탭(이모지)이 열려 있고, 세트 탭 줄에 서버 세트 이름이 보인다.
      expect(find.widgetWithText(ChoiceChip, '리마인 캐릭터'), findsOneWidget);
      expect(find.byType(StickerView), findsNothing);

      await tester.tap(find.widgetWithText(ChoiceChip, '리마인 캐릭터'));
      await tester.pump();
      expect(find.byType(StickerView), findsOneWidget); // 이 세트의 그림 하나

      await tester.tap(find.byType(StickerView));
      await tester.pump();
      expect(postedPath, isNull); // "확인"을 눌러야 저장된다 — 그림만 골랐을 땐 아직 안 보낸다.

      await tester.tap(find.widgetWithText(FilledButton, '확인'));
      await tester.pump();
      await tester.pump();
      expect(postedPath, '/api/users/me/avatar/character/c1');
      expect(s.avatarType, 'photo');
      expect(s.avatarUrl, '/files/signed-char1');
      s.dispose();
    });

    testWidgets('캐릭터 세트가 없으면 "기본 캐릭터" 탭만 있고 이모지 고르기만 보인다', (tester) async {
      final client = MockClient(
        (request) async => http.Response('[]', 200, headers: _json),
      );
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
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: CharacterPickerDialog(session: s)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.widgetWithText(ChoiceChip, '기본 캐릭터'), findsOneWidget);
      expect(find.text('캐릭터'), findsOneWidget); // 이모지 고르기 쪽 라벨
      expect(find.byType(StickerView), findsNothing);
      s.dispose();
    });

    testWidgets('이 앱의 최소 창 크기(350×600)에서도 레이아웃이 넘치지 않는다', (tester) async {
      final client = MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/api/stickers') {
          return http.Response(
            jsonEncode([_packJson(hideSecond: false)]),
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
      tester.view.physicalSize = const Size(350, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: CharacterPickerDialog(session: s)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull); // RenderFlex overflow 등 렌더 오류 없음.
      s.dispose();
    });

    testWidgets('세트마다 그림 개수가 달라도 창 크기가 그대로고, 닫기/확인은 늘 보인다', (tester) async {
      Map<String, dynamic> packJson(String name, int stickerCount) => {
        'id': name,
        'name': name,
        'kind': 'character',
        'hidden': false,
        'stickers': [
          for (var i = 1; i <= stickerCount; i++)
            {
              'id': '$name-$i',
              'packId': name,
              'url': '/files/$name-$i',
              'fileName': '$i.jpg',
              'mimeType': 'image/jpeg',
              'hidden': false,
            },
        ],
      };
      final client = MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/api/stickers') {
          return http.Response(
            jsonEncode([packJson('한장', 1), packJson('스무장', 20)]),
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
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: CharacterPickerDialog(session: s)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      Size dialogSize() => tester.getSize(find.byType(Dialog));
      bool buttonsVisible() =>
          tester.getRect(find.widgetWithText(FilledButton, '확인')).bottom <=
          tester.getRect(find.byType(Dialog)).bottom;

      final builtinSize = dialogSize();
      expect(buttonsVisible(), isTrue);

      await tester.tap(find.widgetWithText(ChoiceChip, '한장'));
      await tester.pump();
      expect(dialogSize(), builtinSize); // 그림 1장짜리 세트로 바꿔도 창 크기 그대로.
      expect(buttonsVisible(), isTrue);

      await tester.tap(find.widgetWithText(ChoiceChip, '스무장'));
      await tester.pump();
      expect(dialogSize(), builtinSize); // 그림 20장짜리 세트로 바꿔도 창 크기 그대로.
      expect(buttonsVisible(), isTrue);
      s.dispose();
    });
  });
}
