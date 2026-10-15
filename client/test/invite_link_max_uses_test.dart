import 'dart:convert';

import 'package:client/models/invite_link.dart';
import 'package:client/screens/invite_link_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 설치 초대 링크의 "가입 인원" — 목록의 "가입 2/5명"·"인원 마감" 표시와, 만들 때 고른 인원을
/// 서버에 보내는지(server/src/invites.js의 maxUses).
void main() {
  const serverUrl = 'https://192.168.0.10:3000';
  const json = {'content-type': 'application/json'};
  final now = DateTime.now();

  Map<String, dynamic> linkJson({
    String id = 'l1',
    String? label,
    int usedCount = 0,
    int? maxUses = 1,
    bool revoked = false,
    bool valid = true,
    Duration expiresIn = const Duration(days: 7),
  }) => {
    'id': id,
    'token': 'tok-$id',
    'label': label,
    'createdByName': '김관리',
    'createdAt': now.millisecondsSinceEpoch,
    'expiresAt': now.add(expiresIn).millisecondsSinceEpoch,
    'revoked': revoked,
    'usedCount': usedCount,
    'maxUses': maxUses,
    'lastUsedAt': null,
    'valid': valid,
    // 링크 주소가 없으면 만든 뒤 클립보드 복사를 건너뛴다(이 테스트는 복사와 무관).
    'url': null,
    'externalUrl': null,
  };

  group('InviteLink 모델', () {
    test('maxUses를 읽고 "가입 n/m명"으로 보여준다', () {
      final link = InviteLink.fromJson(linkJson(usedCount: 2, maxUses: 5));
      expect(link.maxUses, 5);
      expect(link.usageLabel, '가입 2/5명');
      expect(link.statusLabel, '만료까지 6일');
    });

    test('인원이 다 차면 "인원 마감", 취소가 가장 먼저 보인다', () {
      final full = InviteLink.fromJson(
        linkJson(usedCount: 5, maxUses: 5, valid: false),
      );
      expect(full.statusLabel, '인원 마감');
      expect(full.usageLabel, '가입 5/5명');
      final revoked = InviteLink.fromJson(
        linkJson(usedCount: 5, maxUses: 5, revoked: true, valid: false),
      );
      expect(revoked.statusLabel, '취소됨');
    });

    test('인원이 다 차도 만료 전에는 열려 있고(연결·설치용), 만료되면 "만료됨"', () {
      final full = InviteLink.fromJson(
        linkJson(usedCount: 5, maxUses: 5, valid: false),
      );
      expect(full.isFull, isTrue);
      expect(full.isOpen, isTrue);
      final expiredFull = InviteLink.fromJson(
        linkJson(
          usedCount: 5,
          maxUses: 5,
          valid: false,
          expiresIn: const Duration(hours: -1),
        ),
      );
      expect(expiredFull.isOpen, isFalse);
      expect(expiredFull.statusLabel, '만료됨');
      final revoked = InviteLink.fromJson(
        linkJson(revoked: true, valid: false),
      );
      expect(revoked.isOpen, isFalse);
    });

    test('인원 칸이 생기기 전에 만든 링크(maxUses 없음)는 제한 없이 "가입 n명"', () {
      final legacy = InviteLink.fromJson(
        linkJson(usedCount: 3, maxUses: null)..remove('maxUses'),
      );
      expect(legacy.maxUses, isNull);
      expect(legacy.usageLabel, '가입 3명');
      expect(legacy.statusLabel, '만료까지 6일');
      expect(legacy.isFull, isFalse);
    });
  });

  group('초대 링크 화면', () {
    late List<http.Request> requests;
    late List<Map<String, dynamic>> listed;

    Session buildSession() {
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/api/invite-links' &&
            request.method == 'GET') {
          return http.Response(jsonEncode(listed), 200, headers: json);
        }
        if (request.url.path == '/api/invite-links' &&
            request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(
              linkJson(
                id: 'l2',
                label: body['label'] as String?,
                maxUses: body['maxUses'] as int?,
              ),
            ),
            201,
            headers: json,
          );
        }
        return http.Response('[]', 200, headers: json);
      });
      final session = Session(
        notifications: NotificationService(),
        settings: AppSettings(),
      );
      session.serverUrl = serverUrl;
      session.api = ApiClient(
        baseUrl: serverUrl,
        token: 't',
        httpClient: client,
      );
      session.userId = 'u1';
      return session;
    }

    setUp(() {
      requests = [];
      listed = [linkJson(label: '9월 신입', usedCount: 2, maxUses: 5)];
    });

    Future<void> pumpScreen(WidgetTester tester, Session session) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showInviteLinkScreen(context, session),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
    }

    testWidgets('목록에 가입 인원이 "가입 2/5명"으로 나온다', (tester) async {
      await pumpScreen(tester, buildSession());
      expect(find.text('9월 신입'), findsOneWidget);
      expect(find.textContaining('가입 2/5명'), findsOneWidget);
      expect(find.byTooltip('링크 복사'), findsOneWidget);
      expect(find.byTooltip('링크 취소'), findsOneWidget);
    });

    testWidgets('인원이 다 찬 링크는 복사는 빠지고 취소는 남는다(만료되면 둘 다 빠진다)', (tester) async {
      listed = [
        linkJson(
          id: 'full',
          label: '다 참',
          usedCount: 5,
          maxUses: 5,
          valid: false,
        ),
        linkJson(
          id: 'old',
          label: '만료',
          usedCount: 5,
          maxUses: 5,
          valid: false,
          expiresIn: const Duration(hours: -1),
        ),
      ];
      await pumpScreen(tester, buildSession());
      expect(find.textContaining('인원 마감'), findsOneWidget);
      expect(find.textContaining('만료됨'), findsOneWidget);
      expect(find.byTooltip('링크 복사'), findsNothing);
      // 만료 전인 "다 참" 링크에만 취소 버튼이 있다.
      expect(find.byTooltip('링크 취소'), findsOneWidget);
      final fullRow = find.ancestor(
        of: find.text('다 참'),
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(of: fullRow, matching: find.byTooltip('링크 취소')),
        findsOneWidget,
      );
    });

    testWidgets('만들기 창에서 고른 가입 인원을 maxUses로 보낸다(기본 1명)', (tester) async {
      await pumpScreen(tester, buildSession());
      await tester.tap(find.text('초대 링크 만들기'));
      await tester.pumpAndSettle();

      expect(find.text('가입 인원'), findsOneWidget);
      for (final n in inviteMaxUsesOptions) {
        expect(find.widgetWithText(ChoiceChip, '$n명'), findsOneWidget);
      }
      final one = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '1명'),
      );
      expect(one.selected, isTrue);

      await tester.tap(find.widgetWithText(ChoiceChip, '10명'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '10월 신입');
      await tester.tap(find.widgetWithText(FilledButton, '만들기'));
      await tester.pumpAndSettle();

      final post = requests.singleWhere((r) => r.method == 'POST');
      expect(jsonDecode(post.body), {'label': '10월 신입', 'maxUses': 10});
      // 새 링크가 목록 맨 위에 붙는다.
      expect(find.text('10월 신입'), findsOneWidget);
      expect(find.textContaining('가입 0/10명'), findsOneWidget);
      // 만들면 알약만 뜨고 클립보드에는 넣지 않는다(보낼 때는 목록 줄의 복사 단추로).
      expect(find.text('초대링크를 생성했습니다.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3)); // 알약이 사라질 때까지
    });
  });
}
