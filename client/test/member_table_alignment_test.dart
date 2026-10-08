import 'dart:convert';

import 'package:client/models/team.dart';
import 'package:client/screens/admin_console_screen.dart';
import 'package:client/screens/team_settings_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/role_badge.dart';
import 'package:client/widgets/sort_menu_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 팀 설정 "멤버" 탭 · 관리자 콘솔 "회원" 탭 — 칼럼 제목(등급 · 직책)과 아래 목록 줄의 가로 위치가 맞는지(제목 줄 끝의
/// 정렬 단추와 목록 줄 끝의 ⋮ 단추 폭이 같아야 한다), 그리고 정렬 단추 메뉴(검색 패널 "최신 순"과 같은 드롭다운).

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

http.Response _json(Object? body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: _jsonHeaders,
);

Session _session(Object? Function(String path) route, {bool admin = false}) {
  final session = Session(
    notifications: NotificationService(),
    settings: AppSettings(),
  );
  session.serverUrl = 'https://test.local';
  session.userId = 'me';
  session.isServerAdmin = admin;
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: MockClient(
      (request) async => _json(route(request.url.path) ?? <Object>[]),
    ),
  );
  return session;
}

Future<void> _open(
  WidgetTester tester,
  void Function(BuildContext context) open,
) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => open(context),
            child: const Text('열기'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('열기'));
  await tester.pumpAndSettle();
}

/// [positions] 직책을 가진 목록 줄마다 — 첫 배지(등급)의 왼쪽 끝이 '등급' 제목과, 직책 글자의 왼쪽 끝이 '직책' 제목과 같다.
void _expectAligned(WidgetTester tester, List<String> positions) {
  double left(Finder f) => tester.getTopLeft(f).dx;
  final roleHead = left(find.text('등급'));
  final positionHead = left(find.text('직책'));
  for (final position in positions) {
    final row = find
        .ancestor(of: find.text(position), matching: find.byType(Row))
        .first;
    final badge = find
        .descendant(of: row, matching: find.byType(RoleBadge))
        .first;
    expect(left(badge), closeTo(roleHead, 0.5), reason: '$position 등급');
    expect(
      left(find.text(position)),
      closeTo(positionHead, 0.5),
      reason: position,
    );
  }
}

Map<String, dynamic> _member(String id, String name, String position) => {
  'id': id,
  'username': id,
  'name': name,
  'role': 'member',
  'position': position,
  'isOwner': id == 'me',
};

Map<String, dynamic> _adminUser(String id, String name, String position) => {
  ..._member(id, name, position),
  'createdAt': DateTime(2026).millisecondsSinceEpoch,
  'teams': <Object>[],
};

final _team = Team(
  id: 't1',
  name: '개발',
  createdAt: DateTime(2026),
  isOwner: true,
);

Future<void> _openTeamMembers(WidgetTester tester) async {
  final session = _session(
    (path) => path == '/api/teams/t1/members'
        ? [_member('me', '나', '대리'), _member('kim', '김철수', '과장')]
        : null,
  );
  await _open(
    tester,
    (context) => showTeamSettingsDialog(context, session, _team),
  );
  await tester.tap(find.text('멤버'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('팀 설정 멤버 탭: 등급·직책 제목과 목록 내용의 왼쪽 끝이 같다', (tester) async {
    await _openTeamMembers(tester);
    _expectAligned(tester, ['대리', '과장']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('관리자 콘솔 회원 탭: 등급·직책 제목과 목록 내용의 왼쪽 끝이 같다', (tester) async {
    final session = _session(
      (path) => path == '/api/admin/users'
          ? [_adminUser('me', '나', '대리'), _adminUser('kim', '김철수', '과장')]
          : null,
      admin: true,
    );
    await _open(tester, (context) => showAdminConsole(context, session));
    await tester.tap(find.text('회원').first);
    await tester.pumpAndSettle();
    _expectAligned(tester, ['대리', '과장']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '정렬 단추: "↑ 이름 순"처럼 화살표 + 기준 이름, 메뉴는 검색 패널과 같은 드롭다운 — 같은 기준을 다시 누르면 방향만 뒤집힌다',
    (tester) async {
      await _openTeamMembers(tester);
      final button = find.byKey(const ValueKey('sort-menu-button'));
      double top(String name) => tester.getTopLeft(find.text(name)).dy;
      Finder inButton(Finder f) => find.descendant(of: button, matching: f);
      final ascending = find.byKey(const ValueKey('sort-menu-ascending'));
      final descending = find.byKey(const ValueKey('sort-menu-descending'));

      // 단추 — 기준 이름(흐린 12px, "최신 순"과 같은 글자)과 그 왼쪽의 방향 화살표.
      expect(top('과장'), lessThan(top('대리'))); // 이름 오름차순(김 → 나)
      final label = inButton(find.text('이름 순'));
      expect(label, findsOneWidget);
      expect(inButton(ascending), findsOneWidget);
      expect(
        tester.getCenter(inButton(ascending)).dx,
        lessThan(tester.getTopLeft(label).dx),
      );
      final style = tester.widget<Text>(label).style;
      final theme = Theme.of(tester.element(button));
      expect(style?.fontSize, theme.textTheme.labelMedium?.fontSize);
      expect(style?.color, theme.hintColor);
      // 단추 폭은 목록 줄 끝 칸(⋮)과 같은 고정 폭.
      expect(tester.getSize(button).width, sortMenuButtonWidth);

      await tester.tap(button);
      await tester.pumpAndSettle();
      // 메뉴 — 항목마다 "○○ 순", 지금 기준에만 체크. PopupMenu가 아니라 MenuAnchor 메뉴.
      expect(find.byType(PopupMenuItem<Object>), findsNothing);
      final nameItem = find.byKey(
        const ValueKey('sort-menu-MemberSortField.name'),
      );
      final positionItem = find.byKey(
        const ValueKey('sort-menu-MemberSortField.position'),
      );
      expect(
        find.descendant(of: nameItem, matching: find.byIcon(Icons.check)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: positionItem, matching: find.text('직책 순')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: positionItem, matching: find.byIcon(Icons.check)),
        findsNothing,
      );
      // 단추 오른쪽 끝에 맞춰 뜬다.
      expect(
        tester.getTopRight(find.byType(MenuItemButton).first).dx,
        closeTo(tester.getTopRight(button).dx, 12),
      );

      // 같은 기준(이름)을 다시 누르면 방향만 뒤집힌다 — 화살표가 아래로.
      await tester.tap(nameItem);
      await tester.pumpAndSettle();
      expect(top('대리'), lessThan(top('과장')));
      expect(inButton(descending), findsOneWidget);
      expect(inButton(find.text('이름 순')), findsOneWidget);

      // 다른 기준을 고르면 그 기준의 오름차순부터 — 가장 긴 글자도 잘리지 않고 다 보인다.
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(positionItem);
      await tester.pumpAndSettle();
      final positionLabel = inButton(find.text('직책 순'));
      expect(positionLabel, findsOneWidget);
      expect(inButton(ascending), findsOneWidget);
      expect(
        tester.renderObject<RenderParagraph>(positionLabel).didExceedMaxLines,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
