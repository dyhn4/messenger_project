import 'dart:convert';

import 'package:client/screens/project/notes_view.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _json = {'content-type': 'application/json'};

void main() {
  late Map<String, dynamic> posted;
  var created = false;

  Session session() {
    posted = {};
    created = false;
    int at(int d) => DateTime(2026, 8, d, 10).millisecondsSinceEpoch;
    Map<String, dynamic> note(
      String id,
      String project,
      String title,
      int created,
      int updated,
    ) => {
      'id': id,
      'projectId': project,
      'projectName': project == 'p1' ? '신제품 런칭 캠페인' : '겨울 신메뉴 출시',
      'projectColor': project == 'p1' ? '#EC4899' : '#F97316',
      'title': title,
      'preview': '- [ ] 과장 표현 **없음**',
      'createdBy': 'u1',
      'createdAt': at(created),
      'updatedAt': at(updated),
    };
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
              note('n1', 'p1', '소재 검수 체크리스트', 23, 23),
              note('n2', 'p1', '채널별 집행 계획', 22, 25),
              note('n3', 'p2', '메뉴 시식 후기', 10, 10),
              if (created) note('n9', 'p1', posted['title'] as String, 26, 26),
            ]),
            200,
            headers: _json,
          );
        }
        if (request.method == 'GET' && path == '/api/projects') {
          return http.Response(
            jsonEncode([
              for (final (id, name, color) in [
                ('p1', '신제품 런칭 캠페인', '#EC4899'),
                ('p2', '겨울 신메뉴 출시', '#F97316'),
              ])
                {
                  'id': id,
                  'teamId': 't1',
                  'name': name,
                  'identifier': id.toUpperCase(),
                  'color': color,
                  'myRole': 'owner',
                  'createdAt': at(1),
                },
            ]),
            200,
            headers: _json,
          );
        }
        if (request.method == 'POST') {
          posted = jsonDecode(request.body) as Map<String, dynamic>;
          final first = !created;
          created = true;
          return http.Response(
            jsonEncode({
              ...note(
                first ? 'n9' : 'n10',
                'p1',
                posted['title'] as String,
                26,
                26,
              ),
              'key': first ? 'P1-N9' : 'P1-N10',
              'createdByName': '송병근',
              'body': posted['body'],
            }),
            201,
            headers: _json,
          );
        }
        return http.Response('[]', 200, headers: _json);
      }),
    );
    return s;
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotesView(session: session(), teamId: 't1', reloadTick: 0),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  double y(WidgetTester tester, String text) =>
      tester.getTopLeft(find.text(text).first).dy;

  testWidgets('목록 화면: 검색·전체 프로젝트·생성순, 미리보기는 기호 없이, 마우스를 올리면 ✕', (tester) async {
    await pump(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('노트'), findsOneWidget);
    expect(find.text('+ 새 노트'), findsOneWidget);
    expect(find.text('전체 프로젝트'), findsOneWidget);
    expect(find.text('생성순'), findsOneWidget);
    expect(find.text('☐ 과장 표현 없음'), findsNWidgets(3));
    expect(find.text('2026년 8월 23일'), findsOneWidget);
    // 생성순: 23일 → 22일 → 10일.
    expect(y(tester, '소재 검수 체크리스트'), lessThan(y(tester, '채널별 집행 계획')));
    expect(y(tester, '채널별 집행 계획'), lessThan(y(tester, '메뉴 시식 후기')));

    // 수정순으로 바꾸면 25일에 고친 노트가 맨 위.
    await tester.tap(find.text('생성순'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '수정순'));
    await tester.pumpAndSettle();
    expect(y(tester, '채널별 집행 계획'), lessThan(y(tester, '소재 검수 체크리스트')));

    // 프로젝트로 거르기.
    await tester.tap(find.text('전체 프로젝트'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '겨울 신메뉴 출시'));
    await tester.pumpAndSettle();
    expect(find.text('소재 검수 체크리스트'), findsNothing);
    expect(find.text('메뉴 시식 후기'), findsOneWidget);

    // 마우스를 올리면 ✕가 보인다.
    final close = find.byTooltip('삭제');
    expect(
      tester
          .widget<Visibility>(
            find.ancestor(of: close, matching: find.byType(Visibility)).first,
          )
          .visible,
      isFalse,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('메뉴 시식 후기')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Visibility>(
            find.ancestor(of: close, matching: find.byType(Visibility)).first,
          )
          .visible,
      isTrue,
    );
  });

  testWidgets('새 노트: 왼쪽 목록(계층형·접기) + 편집기(도구모음·표) · 저장하면 마크다운', (tester) async {
    await pump(tester);
    await tester.tap(find.text('+ 새 노트'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 왼쪽 목록 — 계층형이라 프로젝트별로 묶인다.
    expect(find.text('계층형'), findsOneWidget);
    expect(find.text('신제품 런칭 캠페인'), findsWidgets);
    expect(find.text('겨울 신메뉴 출시'), findsWidgets);
    // 편집기.
    expect(find.text('제목을 입력하세요'), findsOneWidget);
    expect(find.text('내용을 입력하세요'), findsOneWidget);
    for (final tip in [
      '글자색',
      '제목 1',
      '제목 2',
      '제목 3',
      '표',
      '그림',
      '굵게 (Ctrl+B)',
    ]) {
      expect(find.byTooltip(tip), findsOneWidget, reason: tip);
    }
    // 제목이 비어 있으면 저장할 수 없다.
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '저장'))
          .onPressed,
      isNull,
    );

    Finder field(String hint) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == hint,
    );
    await tester.enterText(field('제목을 입력하세요'), '회의록');
    await tester.enterText(field('내용을 입력하세요'), '안건');
    await tester.pump();
    // 첫 줄을 큰 제목으로 + 표 넣기.
    final body = tester.widget<TextField>(field('내용을 입력하세요'));
    body.controller!.selection = const TextSelection.collapsed(offset: 1);
    await tester.tap(find.byTooltip('제목 1'));
    await tester.pump();
    body.controller!.selection = TextSelection.collapsed(
      offset: body.controller!.text.length,
    );
    await tester.tap(find.byTooltip('표'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(posted['title'], '회의록');
    expect(posted['body'], '# 안건\n| 항목 | 내용 |\n| --- | --- |\n|  |  |');

    // 목록 접기 · 펼치기.
    await tester.tap(find.byTooltip('목록 접기'));
    await tester.pumpAndSettle();
    expect(find.text('계층형'), findsNothing);
    await tester.tap(find.byTooltip('목록 펼치기'));
    await tester.pumpAndSettle();
    expect(find.text('계층형'), findsOneWidget);

    // 왼쪽 위 "노트"를 누르면 다시 목록 화면.
    await tester.tap(find.byTooltip('노트 목록'));
    await tester.pumpAndSettle();
    expect(find.text('전체 프로젝트'), findsOneWidget);
    expect(find.text('계층형'), findsNothing);
  });

  testWidgets('저장한 노트: 번호 칩 · 최종 수정 · 작성자 · 댓글, ⋯에서 수정·노트 복제·삭제', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('+ 새 노트'));
    await tester.pumpAndSettle();
    Finder field(String hint) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == hint,
    );
    await tester.enterText(field('제목을 입력하세요'), '제목이다');
    await tester.enterText(field('내용을 입력하세요'), 'ㅁㄴㅇㄹ');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(find.text('P1-N9'), findsOneWidget);
    // 번호 칩을 누르면 노트 링크가 복사된다.
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    await tester.tap(find.text('P1-N9'));
    await tester.pump();
    expect(find.text('링크를 복사했습니다.'), findsOneWidget);
    expect(copied, startsWith('tangotalk://note/n9'));
    expect(copied, contains('key=P1-N9'));
    expect(find.text('제목이다'), findsWidgets);
    expect(find.textContaining('최종 수정 2026.08.26'), findsOneWidget);
    expect(find.text('송병근'), findsOneWidget);
    expect(find.text('댓글 (0)'), findsOneWidget);
    expect(find.text('댓글을 입력하세요...'), findsOneWidget);
    expect(find.byTooltip('수정 이력'), findsOneWidget);

    await tester.tap(find.byTooltip('더보기'));
    await tester.pumpAndSettle();
    expect(find.text('수정'), findsOneWidget);
    expect(find.text('노트 복제'), findsOneWidget);
    expect(find.text('삭제'), findsOneWidget);

    // 노트 복제 — 같은 프로젝트에 "(복사본)"으로 만든다.
    await tester.tap(find.text('노트 복제'));
    await tester.pumpAndSettle();
    expect(posted['title'], '제목이다 (복사본)');
    expect(posted['body'], 'ㅁㄴㅇㄹ');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
