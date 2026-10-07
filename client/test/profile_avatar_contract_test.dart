import 'dart:convert';

import 'package:client/screens/my_profile_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 내 프로필(PATCH /api/users/me)이 보내는 값이 서버 검사(server/src/avatarRules.js)를 그대로 통과하는 모양인지 —
/// 서버는 이제 캐릭터 배경색을 '#RRGGBB'로만, 이모지를 한 덩어리로만, 이름을 30자까지만 받고, 사진이 아닌 아바타는
/// 사진 칸을 비운다. 그 모양을 벗어나면 저장이 400으로 실패하므로 앱 쪽 모양을 여기서 지킨다.

final _hexColor = RegExp(r'^#[0-9A-F]{6}$');

http.Response _json(Object? body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

/// PATCH /api/users/me 본문을 [patches]에 모으고, 받은 값을 그대로 돌려주는 가짜 서버를 붙인 세션.
Session _session(List<Map<String, dynamic>> patches) {
  final session = Session(
    notifications: NotificationService(),
    settings: AppSettings(),
  );
  session.serverUrl = 'https://test.local';
  session.userId = 'me';
  session.username = 'me';
  session.name = '나대리';
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: MockClient((request) async {
      if (request.method == 'PATCH' && request.url.path == '/api/users/me') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        patches.add(body);
        return _json({
          'username': 'me',
          'name': body['name'] ?? '나대리',
          'avatarType': body['avatarType'] ?? 'initial',
          'avatarEmoji': body['avatarEmoji'],
          'avatarColor': body['avatarColor'],
          'avatarUrl': body['avatarUrl'],
        });
      }
      return _json(<Object>[]);
    }),
  );
  return session;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(800, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: child)),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('캐릭터 고르기 — 이모지 한 덩어리와 대문자 #RRGGBB 배경색을 보내고 사진 칸은 비운다', (
    tester,
  ) async {
    final patches = <Map<String, dynamic>>[];
    final session = _session(patches);
    await _pump(tester, CharacterPickerDialog(session: session));

    await tester.tap(find.text('🧔'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '확인'));
    await tester.pumpAndSettle();

    final body = patches.single;
    expect(body['avatarType'], 'character');
    expect(body['avatarEmoji'], '🧔');
    expect((body['avatarEmoji'] as String).characters.length, 1);
    expect(body['avatarColor'], matches(_hexColor));
    expect(body['avatarUrl'], isNull);
    session.dispose();
  });

  testWidgets('캐릭터 고르기 — 예전에 저장된 소문자 배경색도 서버가 받는 모양으로 다시 보낸다', (tester) async {
    final patches = <Map<String, dynamic>>[];
    final session = _session(patches)
      ..avatarType = 'character'
      ..avatarEmoji = '👮'
      ..avatarColor = '#4c6ef5';
    await _pump(tester, CharacterPickerDialog(session: session));

    await tester.tap(find.widgetWithText(FilledButton, '확인'));
    await tester.pumpAndSettle();

    expect(patches.single, {
      'avatarType': 'character',
      'avatarEmoji': '👮',
      'avatarColor': '#4C6EF5',
      'avatarUrl': null,
    });
    session.dispose();
  });

  testWidgets('프로필 사진 초기화 — 이모지·배경색·사진을 모두 비워 보낸다', (tester) async {
    final patches = <Map<String, dynamic>>[];
    final session = _session(patches)
      ..avatarType = 'character'
      ..avatarEmoji = '👮'
      ..avatarColor = '#4C6EF5';
    await _pump(tester, AvatarEditDialog(session: session));

    await tester.tap(find.widgetWithText(TextButton, '초기화'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();

    expect(patches.single, {
      'avatarType': 'initial',
      'avatarEmoji': null,
      'avatarColor': null,
      'avatarUrl': null,
    });
    expect(session.avatarType, 'initial');
    session.dispose();
  });

  testWidgets('이름 변경 — 입력칸이 서버 상한(30자)에서 멈추고 앞뒤 공백을 빼서 보낸다', (tester) async {
    final patches = <Map<String, dynamic>>[];
    final session = _session(patches);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MyProfileDialog(session: session)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    final dialog = find.widgetWithText(AlertDialog, '이름 변경');
    final field = find.descendant(of: dialog, matching: find.byType(TextField));
    expect(tester.widget<TextField>(field).maxLength, kProfileNameMaxLength);
    expect(kProfileNameMaxLength, 30);

    await tester.enterText(field, ' ${'가' * 35}');
    await tester.pump();
    await tester.tap(find.descendant(of: dialog, matching: find.text('확인')));
    await tester.pumpAndSettle();

    // 앞 공백까지 30자에서 멈추고(입력칸), 공백을 뺀 29자가 간다.
    expect(patches.single, {'name': '가' * 29});
    expect(session.name, '가' * 29);
    session.dispose();
  });
}
