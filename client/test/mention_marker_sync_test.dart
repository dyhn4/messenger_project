import 'dart:convert';

import 'package:client/models/app_notification.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 다른 기기에서 어느 한 방을 읽으면 서버는 notification:sync로 "전체 안 읽은 멘션 수"만 알려 준다(방은 모른다).
/// 이 기기의 방 목록 "@" 표시는 그 수가 0일 때만 전부 지우던 탓에, 다른 방에 안 읽은 멘션이 남아 있으면 이미
/// 읽은 방의 "@"가 계속 남았다 — 표시 합이 서버 수보다 많으면 방 목록의 서버 값으로 다시 맞춘다(실서버 검증에서 발견).

class _Quiet extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

Map<String, dynamic> _roomJson(String id, String teamId, int mentions) => {
  'id': id,
  'teamId': teamId,
  'type': 'topic',
  'name': id,
  'members': <Object>[],
  'createdAt': DateTime(2026).millisecondsSinceEpoch,
  'unreadMentionCount': mentions,
};

Room _room(String id, String teamId, int mentions) => Room(
  id: id,
  teamId: teamId,
  type: RoomType.topic,
  name: id,
  members: const [],
  createdAt: DateTime(2026),
  lastRead: {},
  unreadMentionCount: mentions,
);

Session _session(Map<String, Map<String, dynamic>> serverRooms) {
  final client = MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/api/rooms') {
      final team = request.url.queryParameters['teamId']!;
      final list = [
        for (final r in serverRooms.values)
          if (r['teamId'] == team) r,
      ];
      return http.Response.bytes(
        utf8.encode(jsonEncode(list)),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
    return http.Response.bytes(utf8.encode('{}'), 200, headers: const {'content-type': 'application/json'});
  });
  final session = Session(notifications: _Quiet(), settings: AppSettings());
  session.serverUrl = 'https://test.local';
  session.api = ApiClient(baseUrl: 'https://test.local', token: 't', httpClient: client);
  session.userId = 'me';
  session.accountRole = AccountRole.member;
  session.teams.addAll([
    Team(id: 't1', name: '영업팀', createdAt: DateTime(2026)),
    Team(id: 't2', name: '개발팀', createdAt: DateTime(2026)),
  ]);
  session.currentTeam = session.teams.first;
  session.rooms.addAll([_room('r1', 't1', 3), _room('r2', 't2', 1)]);
  return session;
}

Future<void> _flush() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  test('다른 기기에서 한 방을 읽어 sync로 합계만 줄면, 읽은 방의 "@"만 서버 값으로 지운다', () async {
    final session = _session({
      'r1': _roomJson('r1', 't1', 0),
      'r2': _roomJson('r2', 't2', 1),
    });
    session.notificationCenter.handleSync(const NotificationCounts(mention: 1));
    await _flush();
    expect(session.rooms.firstWhere((r) => r.id == 'r1').unreadMentionCount, 0);
    expect(session.rooms.firstWhere((r) => r.id == 'r2').unreadMentionCount, 1);
  });

  test('표시 합이 서버 수와 같으면 방 목록을 다시 받지 않는다', () async {
    var fetched = 0;
    final session = _session({'r1': _roomJson('r1', 't1', 0)});
    final client = MockClient((request) async {
      if (request.url.path == '/api/rooms') fetched++;
      return http.Response.bytes(utf8.encode('[]'), 200, headers: const {'content-type': 'application/json'});
    });
    session.api = ApiClient(baseUrl: 'https://test.local', token: 't', httpClient: client);
    session.notificationCenter.handleSync(const NotificationCounts(mention: 4)); // 3 + 1 == 4
    await _flush();
    expect(fetched, 0);
    expect(session.rooms.map((r) => r.unreadMentionCount), [3, 1]);
  });

  test('안 읽은 멘션이 0이 되면 모든 방의 "@"를 바로 지운다(서버 호출 없이)', () async {
    var fetched = 0;
    final session = _session({});
    session.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/rooms') fetched++;
        return http.Response.bytes(utf8.encode('[]'), 200, headers: const {'content-type': 'application/json'});
      }),
    );
    session.notificationCenter.handleSync(const NotificationCounts(mention: 0));
    await _flush();
    expect(fetched, 0);
    expect(session.rooms.map((r) => r.unreadMentionCount), [0, 0]);
  });
}
