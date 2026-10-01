import 'dart:convert';

import 'package:client/models/app_user.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/chat_panel.dart';
import 'package:client/widgets/sticker_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 메시지가 하나도 없는 방(처음 여는 1:1 등)에서도 이모티콘 버튼을 누르면 이모티콘 목록이 떠야 한다 —
/// 예전에는 "아직 메시지가 없습니다." 화면이 이모티콘 패널을 그리는 영역(Stack) 없이 문구만 돌려줘서
/// 첫 메시지를 이모티콘으로 보낼 수가 없었다.

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

http.Response _json(Object? body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: const {'content-type': 'application/json'},
);

final _me = AppUser(id: 'me', username: 'me', name: '나');
final _kim = AppUser(id: 'u2', username: 'chulsoo', name: '김철수');

Room _dm() => Room(
  id: 'dm1',
  teamId: 't1',
  type: RoomType.dm,
  name: null,
  members: [_me, _kim],
  createdAt: DateTime(2026),
  lastRead: {},
);

Session _session(Room room) {
  final session = Session(
    notifications: _QuietNotifications(),
    settings: AppSettings(),
  );
  session.serverUrl = 'https://test.local';
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    // 메시지·기타 목록은 전부 빈 응답 — 방에 메시지가 하나도 없는 상태.
    httpClient: MockClient((request) async => _json(<Object>[])),
  );
  session.userId = 'me';
  session.name = '나';
  session.accountRole = AccountRole.member;
  final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  session.rooms.add(room);
  return session;
}

void main() {
  testWidgets('메시지가 없는 1:1 방에서도 이모티콘 버튼을 누르면 목록이 뜨고, 다시 누르면 닫힌다', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final room = _dm();
    final session = _session(room);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatPanel(key: ValueKey(room.id), session: session, room: room),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('아직 메시지가 없습니다.'), findsOneWidget);
    expect(find.byType(StickerPicker), findsNothing);

    await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(StickerPicker), findsOneWidget);

    await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(StickerPicker), findsNothing);
  });
}
