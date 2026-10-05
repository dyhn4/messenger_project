import 'dart:async';

import 'package:client/models/bookmark.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/bookmark_editor_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/bookmark_api.dart';
import 'package:client/services/bookmark_controller.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/bookmarks_panel.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Bookmark _b(
  String id,
  String title, {
  BookmarkKind kind = BookmarkKind.team,
  bool canEdit = false,
  bool canReorder = false,
  String url = 'https://www.example.com/a/b',
  String? imageUrl,
}) => Bookmark(
  id: id,
  teamId: 't1',
  kind: kind,
  title: title,
  url: url,
  imageUrl: imageUrl,
  canEdit: canEdit,
  canReorder: canReorder,
);

/// 서버를 흉내 내는 가짜 — 부른 내용을 기록하고, 목록은 메모리에 둔다.
class FakeBookmarkApi implements BookmarkApi {
  BookmarkLists lists;
  final calls = <String>[];
  Object? createError;
  BookmarkPreview previewResult = const BookmarkPreview();
  Object? reorderError;

  FakeBookmarkApi(this.lists);

  @override
  Future<BookmarkLists> fetch(String teamId) async {
    calls.add('fetch');
    return lists;
  }

  @override
  Future<Bookmark> create({
    required String teamId,
    required BookmarkKind kind,
    required String title,
    required String url,
    String? imageUrl,
  }) async {
    calls.add('create:${kind.wire}:$title:$url:${imageUrl ?? '-'}');
    if (createError != null) throw createError!;
    final created = _b(
      'new',
      title,
      kind: kind,
      url: url,
      imageUrl: imageUrl,
      canEdit: true,
    );
    lists = kind == BookmarkKind.team
        ? BookmarkLists(
            team: [...lists.team, created],
            personal: lists.personal,
          )
        : BookmarkLists(
            team: lists.team,
            personal: [...lists.personal, created],
          );
    return created;
  }

  @override
  Future<Bookmark> update(
    String id, {
    required String title,
    required String url,
    String? imageUrl,
  }) async {
    calls.add('update:$id:$title:$url:${imageUrl ?? '-'}');
    return _b(id, title, url: url, imageUrl: imageUrl);
  }

  @override
  Future<void> delete(String id) async {
    calls.add('delete:$id');
    lists = BookmarkLists(
      team: [
        for (final b in lists.team)
          if (b.id != id) b,
      ],
      personal: [
        for (final b in lists.personal)
          if (b.id != id) b,
      ],
    );
  }

  @override
  Future<void> reorder({
    required String teamId,
    required BookmarkKind kind,
    required List<String> ids,
  }) async {
    calls.add('reorder:${kind.wire}:${ids.join(',')}');
    if (reorderError != null) throw reorderError!;
  }

  @override
  Future<BookmarkPreview> preview(String url) async {
    calls.add('preview:$url');
    return previewResult;
  }

  @override
  Future<UploadResult> uploadImage(XFile file) async {
    calls.add('upload');
    return const UploadResult(
      url: '/uploads/pic.png',
      signedUrl: '/files/signed-pic',
      fileName: 'pic.png',
      size: 3,
    );
  }
}

void main() {
  Session session({AccountRole role = AccountRole.member}) {
    final s = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    s.serverUrl = 'https://test.local';
    s.userId = 'me';
    s.accountRole = role;
    s.currentTeam = Team(id: 't1', name: '팀', createdAt: DateTime(2026));
    return s;
  }

  /// 알림(토스트) 타이머가 끝나도록 화면을 비우고 시간을 보낸다.
  Future<void> settleToasts(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }

  BookmarkController controllerFor(FakeBookmarkApi api) =>
      BookmarkController(api: api, teamId: 't1');

  Future<void> pumpPanel(
    WidgetTester tester,
    FakeBookmarkApi api, {
    Session? s,
    double width = 420,
    List<Uri>? opened,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final controller = controllerFor(api);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BookmarksPanel(
            session: s ?? session(),
            controller: controller,
            openUrl: opened == null ? null : (uri) async => opened.add(uri),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  FakeBookmarkApi sample({bool admin = false}) => FakeBookmarkApi(
    BookmarkLists(
      team: [
        _b(
          't1',
          '사내 위키',
          canEdit: admin,
          canReorder: admin,
          url: 'https://wiki.corp.com/home',
        ),
        _b('t2', '결재 시스템', canEdit: true, canReorder: admin),
        _b('t3', '식단표', canEdit: admin, canReorder: admin),
      ],
      personal: [
        _b(
          'p1',
          '내 블로그',
          kind: BookmarkKind.personal,
          canEdit: true,
          canReorder: true,
        ),
        _b(
          'p2',
          '메모장',
          kind: BookmarkKind.personal,
          canEdit: true,
          canReorder: true,
        ),
      ],
    ),
  );

  group('모델', () {
    test('Bookmark.fromJson과 도메인', () {
      final b = Bookmark.fromJson({
        'id': 'x',
        'teamId': 't',
        'kind': 'personal',
        'title': '제목',
        'url': 'https://www.naver.com/news',
        'imageUrl': null,
        'position': 2,
        'creator': {'id': 'u1', 'name': '송'},
        'canEdit': true,
        'canReorder': false,
      });
      expect(b.kind, BookmarkKind.personal);
      expect(b.host, 'naver.com');
      expect(b.creatorName, '송');
      expect(b.canEdit, isTrue);
      expect(hostOf('not a url'), 'not a url');
    });
  });

  group('컨트롤러', () {
    test('순서 변경은 바로 반영하고, 서버가 거절하면 되돌린다', () async {
      final api = sample(admin: true);
      final c = controllerFor(api);
      await c.load();
      expect(c.of(BookmarkKind.team).map((b) => b.id), ['t1', 't2', 't3']);
      await c.reorder(BookmarkKind.team, ['t3', 't1', 't2']);
      expect(c.of(BookmarkKind.team).map((b) => b.id), ['t3', 't1', 't2']);
      expect(api.calls.last, 'reorder:team:t3,t1,t2');

      api.reorderError = const ApiException('팀 북마크 순서는 관리자만 바꿀 수 있습니다.');
      await expectLater(
        c.reorder(BookmarkKind.team, ['t2', 't3', 't1']),
        throwsA(isA<ApiException>()),
      );
      await Future<void>.delayed(Duration.zero);
      // 서버 목록(원래 순서)으로 되돌아온다.
      expect(c.of(BookmarkKind.team).map((b) => b.id), ['t1', 't2', 't3']);
      c.dispose();
    });

    test('소켓 bookmark:changed가 오면 같은 팀만 다시 받는다', () async {
      final api = sample();
      final events = StreamController<Map<String, dynamic>>.broadcast();
      final c = BookmarkController(
        api: api,
        teamId: 't1',
        changed: events.stream,
      );
      await c.load();
      final before = api.calls.where((e) => e == 'fetch').length;
      events.add({'teamId': 'other', 'kind': 'team'});
      await Future<void>.delayed(Duration.zero);
      expect(api.calls.where((e) => e == 'fetch').length, before);
      api.lists = const BookmarkLists(team: []);
      events.add({'teamId': 't1', 'kind': 'team'});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(c.of(BookmarkKind.team), isEmpty);
      c.dispose();
      await events.close();
    });
  });

  group('패널', () {
    testWidgets('팀 북마크 / 개인 북마크 탭과 카드(제목·도메인)', (tester) async {
      await pumpPanel(tester, sample());
      expect(find.text('북마크'), findsOneWidget); // 머리글
      expect(find.text('북마크 추가'), findsOneWidget);
      expect(find.text('팀 북마크'), findsOneWidget);
      expect(find.text('개인 북마크'), findsOneWidget);
      expect(find.text('사내 위키'), findsOneWidget);
      expect(find.text('wiki.corp.com'), findsOneWidget);
      expect(find.text('example.com'), findsWidgets); // www. 제외
      expect(find.text('내 블로그'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('bookmark-tab-personal')));
      await tester.pump();
      expect(find.text('내 블로그'), findsOneWidget);
      expect(find.text('사내 위키'), findsNothing);
    });

    testWidgets('빈 상태 문구', (tester) async {
      await pumpPanel(tester, FakeBookmarkApi(const BookmarkLists()));
      expect(find.text('등록된 팀 북마크가 없어요.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bookmark-tab-personal')));
      await tester.pump();
      expect(find.text('등록된 개인 북마크가 없어요.'), findsOneWidget);
    });

    testWidgets('카드를 누르면 외부 브라우저로 주소를 연다', (tester) async {
      final opened = <Uri>[];
      await pumpPanel(tester, sample(), opened: opened);
      await tester.tap(find.text('사내 위키'));
      await tester.pump();
      expect(opened.single.toString(), 'https://wiki.corp.com/home');
    });

    testWidgets('⋯ 메뉴(수정·삭제)는 고칠 수 있는 카드에만', (tester) async {
      await pumpPanel(tester, sample());
      expect(find.byKey(const ValueKey('bookmark-menu-t1')), findsNothing);
      expect(find.byKey(const ValueKey('bookmark-menu-t2')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bookmark-menu-t2')));
      await tester.pumpAndSettle();
      expect(find.text('수정'), findsOneWidget);
      expect(find.text('삭제'), findsOneWidget);
    });

    testWidgets('삭제는 확인 뒤에 서버에 보내고 목록에서 사라진다', (tester) async {
      final api = sample();
      await pumpPanel(tester, api);
      await tester.tap(find.byKey(const ValueKey('bookmark-menu-t2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('삭제'));
      await tester.pumpAndSettle();
      expect(find.text('"결재 시스템" 북마크를 삭제할까요?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('confirm-delete-bookmark')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('delete:t2'));
      expect(find.text('결재 시스템'), findsNothing);
      await settleToasts(tester);
    });

    testWidgets('순서 변경 단추는 없다 — 카드를 꾹 눌러야 손잡이가 나온다', (tester) async {
      await pumpPanel(tester, sample(admin: true));
      expect(find.text('순서 변경'), findsNothing);
      expect(find.byKey(const ValueKey('bookmark-reorder-bar')), findsNothing);
      expect(find.byIcon(Icons.drag_indicator), findsNothing);
      // 그냥 누르면 여는 것뿐, 손잡이는 안 나온다.
      await tester.tap(find.text('결재 시스템'));
      await tester.pump();
      expect(find.byIcon(Icons.drag_indicator), findsNothing);
    });

    testWidgets('팀 관리자: 꾹 누르기 → 손잡이 → 드래그 → 완료에서 서버에 새 순서를 보낸다', (
      tester,
    ) async {
      final api = sample(admin: true);
      await pumpPanel(tester, api);
      await tester.longPress(find.text('사내 위키'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('bookmark-reorder-bar')),
        findsOneWidget,
      );
      expect(find.text('손잡이를 끌어서 순서를 바꾸세요'), findsOneWidget);
      expect(find.byIcon(Icons.drag_indicator), findsNWidgets(3));
      // 순서 변경 중에는 ⋯ 메뉴·북마크 추가·탭 전환이 없다.
      expect(find.byIcon(Icons.more_vert), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.descendant(
                of: find.byKey(const ValueKey('bookmark-add')),
                matching: find.byWidgetPredicate((w) => w is FilledButton),
              ),
            )
            .onPressed,
        isNull,
      );

      // 첫 카드의 손잡이를 두 칸 아래로.
      await tester.drag(
        find.byIcon(Icons.drag_indicator).first,
        const Offset(0, 140),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bookmark-reorder-done')));
      await tester.pumpAndSettle();
      expect(
        api.calls.where((c) => c.startsWith('reorder:')).single,
        'reorder:team:t2,t3,t1',
      );
      expect(find.byKey(const ValueKey('bookmark-reorder-bar')), findsNothing);
      expect(find.byIcon(Icons.drag_indicator), findsNothing);
      await settleToasts(tester);
    });

    testWidgets('순서를 안 바꾸고 완료하면 서버를 부르지 않는다', (tester) async {
      final api = sample(admin: true);
      await pumpPanel(tester, api);
      await tester.longPress(find.text('사내 위키'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('bookmark-reorder-done')));
      await tester.pump();
      expect(api.calls.where((c) => c.startsWith('reorder')), isEmpty);
      expect(find.byIcon(Icons.drag_indicator), findsNothing);
    });

    testWidgets('일반 멤버: 팀 북마크를 꾹 누르면 안내만, 개인 북마크는 손잡이가 나온다', (tester) async {
      await pumpPanel(tester, sample());
      await tester.longPress(find.text('결재 시스템'));
      await tester.pump();
      expect(find.text('팀 북마크 순서는 관리자만 바꿀 수 있어요'), findsOneWidget);
      expect(find.byIcon(Icons.drag_indicator), findsNothing);
      // 안내 토스트가 사라질 때까지(패널은 그대로).
      await tester.pump(const Duration(seconds: 3));

      await tester.tap(find.byKey(const ValueKey('bookmark-tab-personal')));
      await tester.pump();
      await tester.longPress(find.text('내 블로그'));
      await tester.pump();
      expect(find.byIcon(Icons.drag_indicator), findsNWidgets(2));
    });

    testWidgets('북마크가 하나뿐이면 꾹 눌러도 안내만', (tester) async {
      final api = FakeBookmarkApi(
        BookmarkLists(
          personal: [
            _b(
              'p1',
              '내 블로그',
              kind: BookmarkKind.personal,
              canEdit: true,
              canReorder: true,
            ),
          ],
        ),
      );
      await pumpPanel(tester, api);
      await tester.tap(find.byKey(const ValueKey('bookmark-tab-personal')));
      await tester.pump();
      await tester.longPress(find.text('내 블로그'));
      await tester.pump();
      expect(find.text('순서를 바꿀 북마크가 둘 이상 있어야 해요'), findsOneWidget);
      expect(find.byIcon(Icons.drag_indicator), findsNothing);
      await settleToasts(tester);
    });

    testWidgets('폭 360(모바일)에서도 꾹 눌러 순서를 바꾸고, 넘치지 않는다', (tester) async {
      await pumpPanel(tester, sample(admin: true), width: 360);
      expect(tester.takeException(), isNull);
      await tester.longPress(find.text('사내 위키'));
      await tester.pump();
      expect(find.byIcon(Icons.drag_indicator), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    });

    testWidgets('불러오기에 실패하면 문구와 다시 시도', (tester) async {
      final api = _FailingApi();
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final controller = BookmarkController(api: api, teamId: 't1');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BookmarksPanel(session: session(), controller: controller),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('서버에 연결할 수 없습니다.'), findsOneWidget);
      expect(find.text('다시 시도'), findsOneWidget);
    });
  });

  group('추가/수정 창', () {
    Future<void> openEditor(
      WidgetTester tester,
      FakeBookmarkApi api, {
      Bookmark? editing,
      AccountRole role = AccountRole.member,
      bool fullScreen = false,
      double width = 800,
      Future<XFile?> Function()? pickImage,
      void Function(bool saved)? onResult,
    }) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final controller = controllerFor(api);
      addTearDown(controller.dispose);
      await controller.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    final saved = await showBookmarkEditor(
                      context,
                      session: session(role: role),
                      controller: controller,
                      editing: editing,
                      fullScreen: fullScreen,
                      pickImage: pickImage,
                    );
                    onResult?.call(saved);
                  },
                  child: const Text('열기'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
    }

    testWidgets('URL을 붙여넣으면 자동으로 제목·이미지를 채우고 저장하면 만든다', (tester) async {
      final api = FakeBookmarkApi(const BookmarkLists());
      api.previewResult = const BookmarkPreview(
        title: '사내 위키 - 홈',
        imageUrl: 'https://wiki.corp.com/og.png',
        siteName: 'wiki',
      );
      bool? saved;
      await openEditor(tester, api, onResult: (s) => saved = s);
      // 저장은 제목·주소가 있어야 켜진다.
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('bookmark-save')))
            .onPressed,
        isNull,
      );

      await tester.enterText(
        find.byKey(const ValueKey('bookmark-url')),
        'https://wiki.corp.com/home',
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(api.calls, contains('preview:https://wiki.corp.com/home'));
      final title = tester.widget<TextField>(
        find.byKey(const ValueKey('bookmark-title')),
      );
      expect(title.controller!.text, '사내 위키 - 홈');

      await tester.tap(find.byKey(const ValueKey('bookmark-save')));
      await tester.pumpAndSettle();
      expect(
        api.calls,
        contains(
          'create:team:사내 위키 - 홈:https://wiki.corp.com/home:https://wiki.corp.com/og.png',
        ),
      );
      expect(saved, isTrue);
    });

    testWidgets('직접 쓴 제목은 자동으로 덮어쓰지 않는다', (tester) async {
      final api = FakeBookmarkApi(const BookmarkLists());
      api.previewResult = const BookmarkPreview(title: '가져온 제목');
      await openEditor(tester, api);
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-title')),
        '내가 정한 제목',
      );
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-url')),
        'https://a.example.com',
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      final title = tester.widget<TextField>(
        find.byKey(const ValueKey('bookmark-title')),
      );
      expect(title.controller!.text, '내가 정한 제목');

      // 단추를 직접 누르면 새 값으로 바꾼다.
      await tester.tap(find.byKey(const ValueKey('bookmark-fetch')));
      await tester.pump();
      await tester.pump();
      final after = tester.widget<TextField>(
        find.byKey(const ValueKey('bookmark-title')),
      );
      expect(after.controller!.text, '가져온 제목');
    });

    testWidgets('직접 지운 이미지는 자동으로 다시 채우지 않는다', (tester) async {
      final api = FakeBookmarkApi(const BookmarkLists());
      api.previewResult = const BookmarkPreview(
        title: '제목',
        imageUrl: 'https://a.example.com/i.png',
      );
      await openEditor(tester, api);
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-url')),
        'https://a.example.com',
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('bookmark-clear-image')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('bookmark-clear-image')));
      await tester.pump();
      expect(find.byKey(const ValueKey('bookmark-clear-image')), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('bookmark-url')),
        'https://b.example.com',
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(find.byKey(const ValueKey('bookmark-clear-image')), findsNothing);
    });

    testWidgets('이미지 선택은 올려서 저장 값에는 미서명 경로를 쓴다', (tester) async {
      final api = FakeBookmarkApi(const BookmarkLists());
      await openEditor(tester, api, pickImage: () async => XFile('x.png'));
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-title')),
        '제목',
      );
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-url')),
        'https://a.example.com',
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('bookmark-pick-image')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('upload'));
      await tester.tap(find.byKey(const ValueKey('bookmark-save')));
      await tester.pumpAndSettle();
      expect(
        api.calls,
        contains('create:team:제목:https://a.example.com:/uploads/pic.png'),
      );
    });

    testWidgets('서버 오류 문구는 창 안에 보이고 창은 열려 있다', (tester) async {
      final api = FakeBookmarkApi(const BookmarkLists());
      api.createError = const ApiException('북마크는 한 종류에 200개까지 만들 수 있습니다.');
      bool? saved;
      await openEditor(tester, api, onResult: (s) => saved = s);
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-title')),
        '제목',
      );
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-url')),
        'https://a.example.com',
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('bookmark-save')));
      await tester.pumpAndSettle();
      expect(find.text('북마크는 한 종류에 200개까지 만들 수 있습니다.'), findsOneWidget);
      expect(find.byKey(const ValueKey('bookmark-save')), findsOneWidget);
      expect(saved, isNull);
    });

    testWidgets('수정 창은 종류가 잠겨 있고 값이 채워져 있다', (tester) async {
      final api = sample();
      final editing = _b(
        't2',
        '결재 시스템',
        canEdit: true,
        url: 'https://pay.corp.com',
        imageUrl: '/files/x',
      );
      await openEditor(tester, api, editing: editing);
      expect(find.text('북마크 수정'), findsOneWidget);
      expect(find.text('북마크 종류는 만든 뒤에 바꿀 수 없어요.'), findsOneWidget);
      final kind = tester.widget<SegmentedButton<BookmarkKind>>(
        find.byKey(const ValueKey('bookmark-kind')),
      );
      expect(kind.onSelectionChanged, isNull);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('bookmark-title')))
            .controller!
            .text,
        '결재 시스템',
      );
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-title')),
        '결재',
      );
      await tester.tap(find.byKey(const ValueKey('bookmark-save')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('update:t2:결재:https://pay.corp.com:/files/x'));
    });

    testWidgets('준회원은 팀 북마크를 고를 수 없고 개인으로 시작한다', (tester) async {
      final api = FakeBookmarkApi(const BookmarkLists());
      await openEditor(tester, api, role: AccountRole.guest);
      expect(find.text('준회원은 개인 북마크만 만들 수 있어요.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-title')),
        '제목',
      );
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-url')),
        'https://a.example.com',
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('bookmark-save')));
      await tester.pumpAndSettle();
      expect(api.calls.any((c) => c.startsWith('create:personal:')), isTrue);
    });

    testWidgets('모바일 전체 화면(폭 360)에서도 쓸 수 있다', (tester) async {
      final api = FakeBookmarkApi(const BookmarkLists());
      await openEditor(tester, api, fullScreen: true, width: 360);
      expect(find.byType(AppBar), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-title')),
        '제목',
      );
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-url')),
        'https://a.example.com',
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('bookmark-save')));
      await tester.pumpAndSettle();
      expect(api.calls.any((c) => c.startsWith('create:team:제목')), isTrue);
    });

    testWidgets('잘못된 주소는 저장을 막고 안내한다', (tester) async {
      final api = FakeBookmarkApi(const BookmarkLists());
      await openEditor(tester, api);
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-title')),
        '제목',
      );
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-url')),
        'ftp://a.example.com',
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(find.text('http:// 또는 https://로 시작하는 주소를 입력하세요.'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('bookmark-save')))
            .onPressed,
        isNull,
      );
    });
  });
}

class _FailingApi extends FakeBookmarkApi {
  _FailingApi() : super(const BookmarkLists());

  @override
  Future<BookmarkLists> fetch(String teamId) async {
    throw const ApiException('서버에 연결할 수 없습니다.');
  }
}
