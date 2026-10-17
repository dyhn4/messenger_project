import 'dart:convert';

import 'package:client/models/team.dart';
import 'package:client/screens/org_chart_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/role_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 조직도 "멤버" 탭 — 칼럼 제목(이름 · 등급 · 직책)과 아래 목록 줄의 가로 위치가 맞는지. 제목 줄 맨 오른쪽에만 정렬
/// 단추가 있어서, 목록 줄이 그 자리를 비워 두지 않으면 오른쪽 칼럼일수록 제목이 왼쪽으로 밀려 보였다.

const _json = {'content-type': 'application/json; charset=utf-8'};

Map<String, dynamic> _user(String id, String name, {String? position}) => {
  'id': id,
  'username': id,
  'name': name,
  'role': 'member',
  'position': position,
};

Session _session() {
  final client = MockClient((request) async {
    final Object body = switch (request.url.path) {
      '/api/org-tree' => {
        'scope': 'team',
        'scopeKey': 't1',
        'teamId': 't1',
        'departments': <Object>[],
        'members': <Object>[],
      },
      '/api/org-chart/teams' => [
        {
          'id': 't1',
          'name': '영업팀',
          'memberIds': ['me', 'kim'],
          'ownerId': 'me',
        },
      ],
      '/api/users' => [
        _user('me', '나', position: '대리'),
        _user('kim', '김철수', position: '과장'),
      ],
      _ => <Object>[],
    };
    return http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: _json,
    );
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
  // 서버 전체 팀/회원 탭("팀"·"멤버")은 계정 등급 관리자 이상에게만 붙는다.
  s.accountRole = AccountRole.admin;
  s.currentTeam = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  return s;
}

void main() {
  for (final width in [1280.0, 900.0]) {
    // PC와 휴대폰 둘 다 — 스크롤바가 목록과 같은 컨트롤러를 써서 어느 쪽에서도 스크롤바 오류가 없어야 한다.
    testWidgets(
      '멤버 탭 폭 $width: 등급·직책 칼럼 제목과 목록 내용의 왼쪽 끝이 같다',
      variant: TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.android,
      }),
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final session = _session();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showOrgChartScreen(context, session),
                  child: const Text('열기'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('열기'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(Tab, '멤버'));
        await tester.pumpAndSettle();

        double left(Finder f) => tester.getTopLeft(f).dx;
        final roleHead = find.text('등급');
        final positionHead = find.text('직책');
        expect(roleHead, findsOneWidget);
        expect(positionHead, findsOneWidget);
        // 목록 줄마다 첫 배지(등급)와 직책 글자.
        for (final position in ['대리', '과장']) {
          final row = find.ancestor(
            of: find.text(position),
            matching: find.byType(InkWell),
          );
          final badge = find
              .descendant(of: row, matching: find.byType(RoleBadge))
              .first;
          expect(left(badge), closeTo(left(roleHead), 0.5), reason: position);
          expect(
            left(find.text(position)),
            closeTo(left(positionHead), 0.5),
            reason: position,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
