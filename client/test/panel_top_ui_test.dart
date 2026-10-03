import 'dart:convert';

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/files_screen.dart';
import 'package:client/screens/links_screen.dart';
import 'package:client/screens/search_screen.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/compact_menu.dart';
import 'package:client/widgets/panel_filters.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 검색·파일·링크 패널의 상단 UI — 탭/파일 형식 메뉴/정렬 드롭다운/기간(직접 설정 달력)/결과 줄.
/// 서버는 요청 주소를 기록하는 가짜 HTTP 클라이언트로 대신한다.

const _json = {'content-type': 'application/json; charset=utf-8'};

late List<Uri> _requests;

Uri _last(String path) => _requests.lastWhere((u) => u.path == path);

Session _session() {
  _requests = [];
  final client = MockClient((request) async {
    _requests.add(request.url);
    switch (request.url.path) {
      case '/api/search':
        return http.Response(
          jsonEncode({
            'items': [
              for (var i = 0; i < 3; i++)
                {
                  'id': 'm$i',
                  'roomId': 'r1',
                  'roomName': '잔디톡 팀',
                  'senderId': 'u1',
                  'senderName': '송병근',
                  'type': 'file',
                  'text': null,
                  'fileName': 'photo$i.jpg',
                  'createdAt': DateTime(
                    2026,
                    9,
                    29,
                    14,
                    i,
                  ).millisecondsSinceEpoch,
                },
            ],
            // 받아 온 것(3건)보다 전체가 더 많다 — "결과 N건"은 전체 건수.
            'total': 383,
          }),
          200,
          headers: _json,
        );
      case '/api/attachments':
        return http.Response(
          jsonEncode([
            for (var i = 0; i < 4; i++)
              {
                'id': 'f$i',
                'roomId': 'r1',
                'senderId': 'u1',
                'senderName': '송병근',
                'type': 'file',
                'fileUrl': '/uploads/f$i.pdf',
                'fileName': 'f$i.pdf',
                'createdAt': DateTime(
                  2026,
                  9,
                  23,
                  14,
                  i,
                ).millisecondsSinceEpoch,
              },
          ]),
          200,
          headers: _json,
        );
      case '/api/links':
        return http.Response(
          jsonEncode([
            {
              'id': 'm1:https://example.com/doc',
              'messageId': 'm1',
              'roomId': 'r1',
              'senderId': 'u1',
              'senderName': '송병근',
              'createdAt': DateTime(2026, 9, 29, 14).millisecondsSinceEpoch,
              'url': 'https://example.com/doc',
              'title': '예시 문서',
              'imageUrl': null,
              'siteName': 'Example',
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
  s.userId = 'me';
  s.currentTeam = Team(id: 't1', name: '팀', createdAt: DateTime(2026));
  s.rooms.add(
    Room(
      id: 'r1',
      teamId: 't1',
      type: RoomType.topic,
      name: '잔디톡 팀',
      members: const [],
      createdAt: DateTime(2026),
      lastRead: const {},
    ),
  );
  return s;
}

Future<void> _mount(WidgetTester tester, Widget body, {Size? size}) async {
  tester.view.physicalSize = size ?? const Size(900, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: body)));
  await tester.pump();
  await tester.pump();
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

/// 직접 설정 달력에서 지난달 [a]일 ~ [b]일을 고른다(지난달은 항상 오늘 이전이라 고를 수 있다).
Future<String> _pickLastMonthRange(WidgetTester tester, int a, int b) async {
  final calendar = find.byKey(const ValueKey('period-calendar'));
  await tester.tap(
    find.descendant(of: calendar, matching: find.byIcon(Icons.chevron_left)),
  );
  await tester.pump();
  await tester.tap(find.descendant(of: calendar, matching: find.text('$a')));
  await tester.pump();
  expect(find.text('종료일을 선택하세요'), findsOneWidget);
  await tester.tap(find.descendant(of: calendar, matching: find.text('$b')));
  await tester.pumpAndSettle();
  final now = DateTime.now();
  final prev = DateTime(now.year, now.month - 1, 1);
  String two(int v) => v.toString().padLeft(2, '0');
  final ym = '${prev.year}/${two(prev.month)}';
  return '$ym/${two(a)} ~ $ym/${two(b)}';
}

void main() {
  group('PanelPeriod', () {
    test('프리셋과 직접 설정의 since/until · 표시 문구', () {
      final now = DateTime(2026, 9, 30, 12);
      expect(const PanelPeriod().preset, PeriodPreset.year);
      expect(const PanelPeriod().label, '1년 (기본)');
      expect(
        const PanelPeriod().since(now),
        now.subtract(const Duration(days: 365)),
      );
      expect(const PanelPeriod().until, isNull);
      expect(const PanelPeriod().rangeText, isNull);
      expect(const PanelPeriod(PeriodPreset.all).since(now), isNull);
      // 문구는 "기간 설정 안 함"이 아니라 "설정 안 함".
      expect(const PanelPeriod(PeriodPreset.all).label, '설정 안 함');

      final custom = PanelPeriod.custom(
        DateTimeRange(start: DateTime(2025, 2, 26), end: DateTime(2026, 2, 26)),
      );
      expect(custom.label, '직접 설정');
      expect(custom.rangeText, '2025/02/26 ~ 2026/02/26');
      expect(custom.since(), DateTime(2025, 2, 26));
      // 종료일은 그날 끝까지.
      expect(custom.until, DateTime(2026, 2, 26, 23, 59, 59, 999));
    });

    test('파일 형식: 전체는 서버에 안 보내고 나머지는 서버 분류 이름 그대로', () {
      expect(FileCategory.all.apiValue, isNull);
      expect(FileCategory.image.apiValue, 'image');
      expect(FileCategory.other.apiValue, 'other');
      expect(FileCategory.all.buttonLabel, '파일');
      expect(FileCategory.video.buttonLabel, '동영상');
    });
  });

  group('검색 패널', () {
    testWidgets('필터 아래에 전체 · 메시지 · 투표 · 파일 ⌄ · 대화방 탭과 최신 순 단추가 검색 전에도 보인다', (
      tester,
    ) async {
      await _mount(tester, SearchScreen(session: _session()));
      for (final label in ['전체', '메시지', '투표', '파일', '대화방']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      // 대화방 탭은 파일 탭의 오른쪽.
      expect(
        tester.getTopLeft(find.text('대화방')).dx,
        greaterThan(tester.getTopLeft(find.text('파일')).dx),
      );
      // 가입한 팀이 하나뿐이면(이 테스트 세션) 검색 범위 단추가 없다.
      expect(find.byKey(const ValueKey('panel-scope')), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
      expect(find.text('최신 순'), findsOneWidget);
      // 필터 줄: 참여 대화방 / 모든 멤버 / 1년 (기본).
      expect(find.text('참여 대화방'), findsOneWidget);
      expect(find.text('모든 멤버'), findsOneWidget);
      expect(find.text('1년 (기본)'), findsOneWidget);
      // 검색 전에는 결과 줄이 없다.
      expect(find.byKey(const ValueKey('search-result-count')), findsNothing);
      await _close(tester);
    });

    testWidgets('검색칸이 파일 패널 "파일명 검색"칸과 같다 — 입력을 멈추면(엔터 없이) 찾고, 지우기(X)로 비운다', (
      tester,
    ) async {
      await _mount(tester, SearchScreen(session: _session()));
      final field = find.byKey(const ValueKey('search-panel-field'));
      expect(field, findsOneWidget);
      // 파일 패널 검색칸과 같은 모양 — 왼쪽 돋보기, 처음엔 지우기(X) 없음.
      expect(
        find.descendant(of: field, matching: find.byIcon(Icons.search)),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.close), findsNothing);

      // 엔터 없이 입력을 멈추기만 해도(디바운스) 찾는다 — 파일명 검색과 동일.
      await tester.enterText(field, '.jpg');
      expect(_requests.where((u) => u.path == '/api/search'), isEmpty);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(_last('/api/search').queryParameters['q'], '.jpg');

      // 글자가 있으면 지우기(X)가 뜨고, 누르면 비우면서 바로(기다리지 않고) 다시 찾는다.
      expect(find.byIcon(Icons.close), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(find.text('내가 속한 모든 방을 대상으로 검색합니다.'), findsOneWidget);
      await _close(tester);
    });

    testWidgets('검색하면 결과 N건(서버가 준 전체 건수)이 뜨고, 탭·파일 형식·정렬이 요청에 실린다', (
      tester,
    ) async {
      await _mount(tester, SearchScreen(session: _session()));
      await tester.enterText(find.byType(TextField).first, '.jpg');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump();

      var req = _last('/api/search');
      expect(req.queryParameters['q'], '.jpg');
      expect(req.queryParameters['withTotal'], '1');
      expect(req.queryParameters.containsKey('type'), isFalse);
      expect(req.queryParameters.containsKey('order'), isFalse);
      expect(req.queryParameters['since'], isNotNull); // 1년(기본)
      expect(
        find.text('결과 383건 (3건까지 표시)', findRichText: true),
        findsOneWidget,
      );
      // 직접 설정이 아니면 기간 날짜는 안 보인다.
      expect(find.byKey(const ValueKey('panel-range-text')), findsNothing);

      // 투표 탭.
      await tester.tap(find.text('투표'));
      await tester.pump();
      await tester.pump();
      req = _last('/api/search');
      expect(req.queryParameters['type'], 'poll');
      expect(req.queryParameters.containsKey('fileKind'), isFalse);

      // 파일 탭의 꺽쇠 → 파일 형식 메뉴.
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pumpAndSettle();
      for (final c in FileCategory.values) {
        expect(find.text(c.label), findsOneWidget, reason: c.label);
      }
      await tester.tap(find.text('이미지'));
      await tester.pumpAndSettle();
      req = _last('/api/search');
      expect(req.queryParameters['type'], 'file');
      expect(req.queryParameters['fileKind'], 'image');
      // 탭 글자가 고른 형식으로 바뀐다.
      expect(find.text('이미지'), findsOneWidget);
      expect(find.text('파일'), findsNothing);

      // 정렬 — 설정 메뉴와 같은 간결한 팝업으로 최신 순 / 과거 순.
      await tester.tap(find.byKey(const ValueKey('panel-sort')));
      await tester.pumpAndSettle();
      final oldest = find.widgetWithText(PopupMenuItem<bool>, '과거 순');
      expect(oldest, findsOneWidget);
      expect(
        tester.widget<PopupMenuItem<bool>>(oldest).height,
        CompactMenu.itemHeight,
      );
      await tester.tap(oldest);
      await tester.pumpAndSettle();
      req = _last('/api/search');
      expect(req.queryParameters['order'], 'asc');
      expect(req.queryParameters['type'], 'file');
      expect(find.text('과거 순'), findsOneWidget);
      await _close(tester);
    });

    testWidgets(
      '기간 필터 — "설정 안 함"으로 바뀌었고, 직접 설정은 새 업무 창의 달력이며 날짜가 결과 줄 오른쪽에 뜬다',
      (tester) async {
        await _mount(tester, SearchScreen(session: _session()));
        await tester.enterText(find.byType(TextField).first, 'a');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pump();
        await tester.pump();

        await tester.tap(find.text('1년 (기본)'));
        await tester.pumpAndSettle();
        expect(find.text('설정 안 함'), findsOneWidget);
        expect(find.text('기간 설정 안 함'), findsNothing);
        for (final label in ['1주일', '1개월', '3개월', '직접 설정']) {
          expect(find.text(label), findsOneWidget, reason: label);
        }
        await tester.tap(find.text('직접 설정'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('period-calendar')), findsOneWidget);
        expect(find.text('시작일을 선택하세요'), findsOneWidget);

        final expected = await _pickLastMonthRange(tester, 3, 12);
        // 고르면 닫히고, 그 기간으로 다시 검색하고, 결과 줄 오른쪽에 날짜가 보인다.
        expect(find.byKey(const ValueKey('period-calendar')), findsNothing);
        expect(find.text('직접 설정'), findsOneWidget); // 기간 단추의 글자
        expect(find.byKey(const ValueKey('panel-range-text')), findsOneWidget);
        expect(find.text(expected), findsOneWidget);
        final req = _last('/api/search');
        final since = DateTime.fromMillisecondsSinceEpoch(
          int.parse(req.queryParameters['since']!),
        );
        final until = DateTime.fromMillisecondsSinceEpoch(
          int.parse(req.queryParameters['until']!),
        );
        expect(since.day, 3);
        expect(until.day, 12);
        expect(until.hour, 23); // 종료일은 그날 끝까지

        // "설정 안 함"을 고르면 날짜가 사라지고 since를 안 보낸다.
        await tester.tap(find.text('직접 설정'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('설정 안 함'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('panel-range-text')), findsNothing);
        expect(
          _last('/api/search').queryParameters.containsKey('since'),
          isFalse,
        );
        await _close(tester);
      },
    );

    testWidgets('폭 360 — 탭 줄·필터 줄·결과 줄이 넘치지 않고 기간 달력이 화면 안에 뜬다', (
      tester,
    ) async {
      await _mount(
        tester,
        SearchScreen(session: _session()),
        size: const Size(360, 720),
      );
      await tester.enterText(find.byType(TextField).first, '.jpg');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump();
      expect(find.text('최신 순'), findsOneWidget);

      await tester.tap(find.text('1년 (기본)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('직접 설정'));
      await tester.pumpAndSettle();
      final calendar = tester.getRect(
        find.byKey(const ValueKey('period-calendar')),
      );
      expect(calendar.left, greaterThanOrEqualTo(0));
      expect(calendar.right, lessThanOrEqualTo(360));
      await _pickLastMonthRange(tester, 3, 12);
      expect(tester.takeException(), isNull);
      await _close(tester);
    });
  });

  group('파일 패널', () {
    testWidgets('검색칸 · 필터 줄 · 파일 ⌄ / 최신순 줄 · "N"개가 로딩되었습니다. 줄', (tester) async {
      await _mount(tester, FilesScreen(session: _session()));
      expect(find.byKey(const ValueKey('panel-search-field')), findsOneWidget);
      expect(find.text('파일명 검색'), findsOneWidget);
      expect(find.text('참여 대화방'), findsOneWidget);
      expect(find.text('모든 멤버'), findsOneWidget);
      expect(find.text('1년 (기본)'), findsOneWidget);
      expect(find.text('파일'), findsWidgets); // 제목 + "파일 ⌄"
      expect(find.text('최신순'), findsOneWidget);
      expect(find.text('"4"개가 로딩되었습니다.'), findsOneWidget);
      // 위에서부터 검색칸 → 필터 → 파일·정렬 줄 → 결과 줄.
      double top(Finder f) => tester.getTopLeft(f).dy;
      expect(
        top(find.byKey(const ValueKey('panel-search-field'))),
        lessThan(top(find.text('참여 대화방'))),
      );
      expect(top(find.text('참여 대화방')), lessThan(top(find.text('최신순'))));
      expect(top(find.text('최신순')), lessThan(top(find.text('"4"개가 로딩되었습니다.'))));

      final req = _last('/api/attachments');
      expect(req.queryParameters['since'], isNotNull);
      expect(req.queryParameters.containsKey('category'), isFalse);
      expect(req.queryParameters.containsKey('order'), isFalse);
      expect(find.byKey(const ValueKey('panel-range-text')), findsNothing);
      await _close(tester);
    });

    testWidgets('이름 검색 · 파일 형식 · 정렬 · 직접 설정 기간이 요청에 실리고 날짜가 오른쪽에 뜬다', (
      tester,
    ) async {
      await _mount(tester, FilesScreen(session: _session()));
      await tester.enterText(
        find.byKey(const ValueKey('panel-search-field')),
        'report',
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(_last('/api/attachments').queryParameters['q'], 'report');

      // 파일 ⌄ → 형식 메뉴(전체 파일 ~ 기타).
      await tester.tap(find.byKey(const ValueKey('panel-file-kind')));
      await tester.pumpAndSettle();
      for (final c in FileCategory.values) {
        expect(find.text(c.label), findsOneWidget, reason: c.label);
      }
      await tester.tap(find.text('문서'));
      await tester.pumpAndSettle();
      expect(_last('/api/attachments').queryParameters['category'], 'document');
      expect(_last('/api/attachments').queryParameters['q'], 'report');
      expect(find.text('문서'), findsOneWidget); // 단추 글자가 바뀐다

      await tester.tap(find.byKey(const ValueKey('panel-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('과거순'));
      await tester.pumpAndSettle();
      expect(_last('/api/attachments').queryParameters['order'], 'asc');

      await tester.tap(find.text('1년 (기본)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('직접 설정'));
      await tester.pumpAndSettle();
      final expected = await _pickLastMonthRange(tester, 5, 20);
      expect(find.text(expected), findsOneWidget);
      expect(_last('/api/attachments').queryParameters['until'], isNotNull);
      await _close(tester);
    });

    testWidgets('"메시지" 미리보기에 갔다 돌아와도 검색어가 칸에 남아 있다', (tester) async {
      await _mount(tester, FilesScreen(session: _session()));
      await tester.enterText(
        find.byKey(const ValueKey('panel-search-field')),
        'f',
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      await tester.tap(find.text('f0.pdf'));
      await tester.pump();
      expect(find.text('메시지'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('panel-search-field')),
      );
      expect(field.controller!.text, 'f');
      await _close(tester);
    });

    testWidgets('폭 360에서도 넘치지 않는다', (tester) async {
      await _mount(
        tester,
        FilesScreen(session: _session()),
        size: const Size(360, 720),
      );
      expect(find.text('"4"개가 로딩되었습니다.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('panel-file-kind')));
      await tester.pumpAndSettle();
      expect(find.text('압축 파일'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _close(tester);
    });
  });

  group('링크 패널', () {
    testWidgets(
      '긴 대화방 단추 대신 파일 패널과 같은 상단 — 검색칸 · 필터 줄 · 정렬 · 결과 줄(파일 단추는 없다)',
      (tester) async {
        await _mount(
          tester,
          LinksScreen(
            session: _session(),
            initialRoomId: 'r1',
            onOpenMessage: (_, _) {},
          ),
        );
        expect(
          find.byKey(const ValueKey('panel-search-field')),
          findsOneWidget,
        );
        expect(find.text('링크 검색'), findsOneWidget);
        expect(find.text('모든 멤버'), findsOneWidget);
        expect(find.text('1년 (기본)'), findsOneWidget);
        expect(find.text('최신순'), findsOneWidget);
        expect(find.byKey(const ValueKey('panel-file-kind')), findsNothing);
        expect(find.text('"1"개가 로딩되었습니다.'), findsOneWidget);
        // 방 필터는 세 칸 필터 줄 안의 한 칸이다(가로로 긴 단독 단추가 아니다).
        final room = tester.getSize(
          find.widgetWithText(OutlinedButton, '잔디톡 팀'),
        );
        expect(room.width, lessThan(400));

        var req = _last('/api/links');
        expect(req.queryParameters['roomId'], 'r1');
        expect(req.queryParameters['since'], isNotNull);

        await tester.enterText(
          find.byKey(const ValueKey('panel-search-field')),
          'youtube',
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        req = _last('/api/links');
        expect(req.queryParameters['q'], 'youtube');

        await tester.tap(find.byKey(const ValueKey('panel-sort')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('과거순'));
        await tester.pumpAndSettle();
        expect(_last('/api/links').queryParameters['order'], 'asc');

        await tester.tap(find.text('1년 (기본)'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('직접 설정'));
        await tester.pumpAndSettle();
        final expected = await _pickLastMonthRange(tester, 2, 9);
        expect(find.text(expected), findsOneWidget);
        await _close(tester);
      },
    );

    testWidgets('폭 360에서도 넘치지 않는다', (tester) async {
      await _mount(
        tester,
        LinksScreen(session: _session(), onOpenMessage: (_, _) {}),
        size: const Size(360, 720),
      );
      expect(find.text('"1"개가 로딩되었습니다.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _close(tester);
    });
  });
}
