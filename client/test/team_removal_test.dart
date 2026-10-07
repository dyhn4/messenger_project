import 'dart:convert';

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/team_settings_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/chat_socket.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 팀에서 제외될 때(서버 teams.js의 팀원 빼기)의 앱 쪽 반응 — 서버는 그 팀의 모든 방에서 그 사람을 빼고
/// team:left를 먼저 보낸 뒤 방마다 room:removed(reason 'team')를 보낸다. 방마다 안내를 띄우지 않고(team:left가
/// 팀 단위로 한 번 띄운다), 남은 쪽 1:1 대화는 빠진 사람을 "OOO (나갔음)"으로 보여 준다. 팀에서 빼는 확인 창이
/// 그 사실(모든 대화방에서 빠지고 지난 대화도 못 본다)을 알리는지도 본다(team_settings_dialog.dart).

/// 실제 OS 알림을 띄우지 않는다.
class _SilentNotifications extends NotificationService {
  @override
  Future<void> showMessage({
    required String title,
    required String body,
    required String roomId,
    String? senderName,
    String? conversationTitle,
    String avatarType = 'initial',
    String? avatarEmoji,
    String? avatarColor,
    String? avatarUrl,
    bool isSecret = false,
    bool flashTaskbarUntilRoomOpened = false,
    bool flashWindowFrame = true,
  }) async {}

  @override
  Future<void> cancelForRoom(String roomId) async {}
}

Map<String, dynamic> _user(String id, String name) => {
  'id': id,
  'username': id,
  'name': name,
};

Room _room(
  String id, {
  String type = 'topic',
  String? name = '공지방',
  List<Map<String, dynamic>>? members,
  Map<String, dynamic> extra = const {},
}) => Room.fromJson({
  'id': id,
  'teamId': 't1',
  'type': type,
  'name': name,
  'members': members ?? [_user('me', '나'), _user('u2', '김철수')],
  'createdAt': 1000,
  ...extra,
});

Session _session() {
  final session = Session(
    notifications: _SilentNotifications(),
    settings: AppSettings(),
  );
  session.userId = 'me';
  return session;
}

void main() {
  test('room:removed(팀에서 제외) — 방은 정리하고 방마다 안내 이벤트는 흘리지 않는다', () async {
    final session = _session();
    session.rooms
      ..add(_room('r1'))
      ..add(_room('r2', type: 'dm', name: null));
    session.setActiveRoom('r1');
    final events = <RoomRemovedEvent>[];
    final sub = session.roomRemovedEvents.listen(events.add);

    session.handleRoomRemoved(
      const RoomRemovedEvent(
        roomId: 'r1',
        reason: Session.kRoomRemovedReasonTeam,
        name: '공지방',
      ),
    );
    session.handleRoomRemoved(
      const RoomRemovedEvent(roomId: 'r2', reason: Session.kRoomRemovedReasonTeam),
    );
    await pumpEventQueue();

    expect(session.roomById('r1'), isNull);
    expect(session.roomById('r2'), isNull);
    expect(session.activeRoomId, isNull);
    expect(events, isEmpty);

    // 다른 이유(내보내짐)는 지금처럼 안내 이벤트를 흘린다.
    session.rooms.add(_room('r3', name: '잡담'));
    session.handleRoomRemoved(
      const RoomRemovedEvent(roomId: 'r3', reason: 'kicked'),
    );
    await pumpEventQueue();
    expect(events.single.roomId, 'r3');
    expect(events.single.toastText, "'잡담' 토픽에서 내보내졌습니다.");
    await sub.cancel();
  });

  test('팀에서 제외된 방의 안내 문구 — 토픽이 삭제됐다고 하지 않는다', () {
    final event = RoomRemovedEvent.fromJson({
      'roomId': 'r1',
      'reason': 'team',
      'name': '공지방',
    });
    expect(event.reason, Session.kRoomRemovedReasonTeam);
    expect(event.isTeamRemoval, isTrue);
    expect(event.isDeleted, isFalse);
    expect(event.isKicked, isFalse);
    expect(event.toastText, "팀에서 제외되어 '공지방' 대화방에서 나갔습니다.");
    // 1:1 대화처럼 이름이 없는 방.
    expect(
      const RoomRemovedEvent(
        roomId: 'dm1',
        reason: Session.kRoomRemovedReasonTeam,
      ).toastText,
      '팀에서 제외되어 대화방에서 나갔습니다.',
    );
  });

  test('상대가 팀에서 제외된 1:1 대화 — 남은 쪽은 "OOO (나갔음)"으로 본다', () {
    // 서버가 상대를 멤버에서 빼고 나간 사람 이름을 실어 보낸다(rooms.js toRoomDto의 secretDepartedMemberName).
    final dm = _room(
      'dm1',
      type: 'dm',
      name: null,
      members: [_user('me', '나')],
      extra: {'secretDepartedMemberName': '홍길동'},
    );
    expect(dm.isSecret, isFalse);
    expect(dm.displayName('me'), '홍길동 (나갔음)');

    // 그 사람이 다시 들어오면(다시 대화를 걸면) 서버가 표시를 지우고 멤버 이름으로 돌아간다.
    dm.mergeServerState(
      _room(
        'dm1',
        type: 'dm',
        name: null,
        members: [_user('me', '나'), _user('u9', '홍길동')],
        extra: {'secretDepartedMemberName': null},
      ),
    );
    expect(dm.displayName('me'), '홍길동');
    expect(dm.secretDepartedMemberName, isNull);
  });

  testWidgets('팀에서 빼기 확인 창 — 그 팀의 모든 대화방에서도 빠지고 지난 대화도 못 본다고 알린다', (
    tester,
  ) async {
    http.Response json(Object? body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
    final me = {..._user('me', '나'), 'role': 'member', 'isOwner': true};
    final kim = {..._user('u2', '김철수'), 'role': 'member'};
    final requests = <http.Request>[];
    final session = _session();
    session.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: MockClient((request) async {
        requests.add(request);
        return switch ('${request.method} ${request.url.path}') {
          'GET /api/teams/t1/members' => json([me, kim]),
          'DELETE /api/teams/t1/members/u2' => json([me]),
          _ => json(<Object>[]),
        };
      }),
    );
    final team = Team(
      id: 't1',
      name: '개발',
      createdAt: DateTime(2026),
      isOwner: true,
    );

    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showTeamSettingsDialog(context, session, team),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('멤버'));
    await tester.pumpAndSettle();

    // 김철수 줄의 관리 메뉴 → 팀에서 빼기.
    final kimRow = find.ancestor(
      of: find.text('김철수'),
      matching: find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_MemberRow',
      ),
    );
    await tester.tap(
      find.descendant(of: kimRow, matching: find.byTooltip('팀원 관리')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('팀에서 빼기'));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    expect(
      find.descendant(
        of: dialog,
        matching: find.text(
          '김철수 님을 개발 팀에서 뺄까요?\n'
          '이 팀의 모든 대화방(토픽·그룹채팅·1:1 대화·비밀 대화)에서도 함께 빠지고, '
          '지난 대화도 더 이상 볼 수 없습니다.',
        ),
      ),
      findsOneWidget,
    );
    expect(requests.where((r) => r.method == 'DELETE'), isEmpty);

    await tester.tap(find.descendant(of: dialog, matching: find.text('빼기')));
    await tester.pumpAndSettle();
    expect(requests.where((r) => r.method == 'DELETE').map((r) => r.url.path), [
      '/api/teams/t1/members/u2',
    ]);
    expect(find.text('김철수'), findsNothing);
  });
}
