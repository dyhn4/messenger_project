import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client/models/app_user.dart';
import 'package:client/models/comment.dart';
import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/models/text_format.dart';
import 'package:client/models/topic_folder.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/chat_socket.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/room_chat_controller.dart';
// room.canManage/canWrite/canKick은 session.dart가 같이 내보낸다(room_permissions.dart).
import 'package:client/services/session.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 토픽 개편(보기 방식·읽기 전용·보관·토픽 관리자·토픽 폴더·보드 게시글)의 클라이언트 기반 —
/// 모델 파싱, 권한 판정, Session의 폴더/토픽 관리, room:removed 처리, 게시글 전송.

/// 실제 OS 알림 대신 무엇을 띄우려 했는지만 모은다.
class _FakeNotifications extends NotificationService {
  final shown = <Map<String, Object?>>[];

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
  }) async {
    shown.add({'title': title, 'body': body, 'roomId': roomId});
  }

  @override
  Future<void> cancelForRoom(String roomId) async {}
}

typedef _Handler = FutureOr<http.Response> Function(http.Request request);

/// 경로별 응답을 정해두고, 들어온 요청을 전부 기록하는 가짜 서버.
class _FakeServer {
  final requests = <http.Request>[];
  final routes = <String, _Handler>{};

  late final client = MockClient((request) async {
    requests.add(request);
    final handler = routes['${request.method} ${request.url.path}'];
    if (handler != null) return handler(request);
    return _json(<Object>[]);
  });

  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
}

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json'},
);

Map<String, dynamic> _body(http.Request r) =>
    jsonDecode(r.body) as Map<String, dynamic>;

Map<String, dynamic> _user(
  String id,
  String name, {
  String role = 'member',
  bool isOwner = false,
}) => {
  'id': id,
  'username': id,
  'name': name,
  'role': role,
  'isOwner': isOwner,
};

Map<String, dynamic> _roomJson(
  String id, {
  String type = 'topic',
  String name = '공지방',
  String teamId = 't1',
  List<Map<String, dynamic>>? members,
  Map<String, dynamic> extra = const {},
}) => {
  'id': id,
  'teamId': teamId,
  'type': type,
  'name': name,
  'members':
      members ??
      [_user('me', '나'), _user('u2', '김철수'), _user('u3', '이영희', role: 'guest')],
  'createdAt': 1000,
  ...extra,
};

Map<String, dynamic> _folderJson(
  String id,
  String name,
  int position, {
  bool collapsed = false,
  List<String> roomIds = const [],
}) => {
  'id': id,
  'name': name,
  'position': position,
  'collapsed': collapsed,
  'roomIds': roomIds,
};

Map<String, dynamic> _postJson(
  String id, {
  String title = '제목',
  String text = '본문',
  int createdAt = 2000,
  int? pinnedAt,
  int? editedAt,
  String senderId = 'u2',
}) => {
  'id': id,
  'roomId': 'r1',
  'senderId': senderId,
  'senderName': '김철수',
  'type': 'post',
  'title': title,
  'text': text,
  'createdAt': createdAt,
  'pinnedAt': pinnedAt,
  'editedAt': editedAt,
  'attachments': <Object>[],
  'comments': <Object>[],
};

Session _buildSession(
  _FakeServer server, {
  AccountRole role = AccountRole.member,
  bool teamOwner = false,
}) {
  final session = Session(
    notifications: _FakeNotifications(),
    settings: AppSettings(),
  );
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: server.client,
  );
  session.userId = 'me';
  session.accountRole = role;
  final team = Team(
    id: 't1',
    name: '영업팀',
    createdAt: DateTime(2026),
    isOwner: teamOwner,
  );
  session.teams.add(team);
  session.currentTeam = team;
  return session;
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: '기다리던 상태가 되지 않았습니다');
}

void main() {
  group('모델 파싱', () {
    test('Room: 새 토픽 필드를 읽고, 토픽 멤버의 소유자 표시도 읽는다', () {
      final room = Room.fromJson(
        _roomJson(
          'r1',
          members: [_user('me', '나', isOwner: true), _user('u2', '김철수')],
          extra: {
            'viewMode': 'board',
            'readOnly': true,
            'autoInvite': true,
            'quietLeave': true,
            'archived': true,
            'archivedAt': 5000,
            'adminIds': ['u2'],
            'createdBy': 'u2',
          },
        ),
      );
      expect(room.viewMode, TopicViewMode.board);
      expect(room.isBoard, isTrue);
      expect(room.readOnly, isTrue);
      expect(room.autoInvite, isTrue);
      expect(room.quietLeave, isTrue);
      expect(room.archivedAt, DateTime.fromMillisecondsSinceEpoch(5000));
      expect(room.isArchived, isTrue);
      expect(room.adminIds, ['u2']);
      expect(room.isTopicAdmin('u2'), isTrue);
      expect(room.isTopicAdmin('me'), isFalse);
      expect(room.isTopicAdmin(null), isFalse);
      expect(room.createdBy, 'u2');
      expect(room.members.first.isOwner, isTrue);
      expect(room.members.last.isOwner, isFalse);
    });

    test('Room: 예전 서버 응답(새 필드 없음)은 기본값으로 읽는다', () {
      final room = Room.fromJson(_roomJson('r1'));
      expect(room.viewMode, TopicViewMode.chat);
      expect(room.isBoard, isFalse);
      expect(room.readOnly, isFalse);
      expect(room.autoInvite, isFalse);
      expect(room.quietLeave, isFalse);
      expect(room.archivedAt, isNull);
      expect(room.isArchived, isFalse);
      expect(room.adminIds, isEmpty);
      expect(room.createdBy, isNull);
      // 목록은 이후 그 자리에서 바꿀 수 있어야 한다(const 목록이면 안 된다).
      room.adminIds.add('me');
      expect(room.isTopicAdmin('me'), isTrue);

      // 코드에서 직접 만드는 방(테스트·로컬)도 새 인자 없이 그대로 만들어진다.
      final local = Room(
        id: 'x',
        teamId: 't1',
        type: RoomType.topic,
        name: '로컬',
        members: const [],
        createdAt: DateTime(2026),
        lastRead: const {},
      );
      expect(local.viewMode, TopicViewMode.chat);
      expect(local.adminIds, isEmpty);
      expect(local.isArchived, isFalse);
    });

    test('Room: 보관 시각 없이 archived만 와도 보관으로 보고, 보드는 토픽에서만 의미가 있다', () {
      expect(
        Room.fromJson(_roomJson('r1', extra: {'archived': true})).isArchived,
        isTrue,
      );
      final group = Room.fromJson(
        _roomJson('g1', type: 'group', extra: {'viewMode': 'board'}),
      );
      expect(group.isBoard, isFalse);
      expect(topicViewModeFromWire('grid'), TopicViewMode.chat);
      expect(topicViewModeFromWire(null), TopicViewMode.chat);
      expect(TopicViewMode.board.wire, 'board');
      expect(TopicViewMode.chat.label, '챗 뷰');
      expect(TopicViewMode.board.label, '보드 뷰');
      expect(TopicViewMode.board.description, '제목이 있는 게시글을 올리는 게시판');
    });

    test('Message: 게시글(post)은 text 타입 + isPost로 읽고, 모르는 타입도 안전하다', () {
      final post = Message.fromJson(_postJson('p1', pinnedAt: 3000));
      expect(post.isPost, isTrue);
      expect(post.type, MessageType.text);
      expect(post.title, '제목');
      expect(post.text, '본문');
      expect(post.pinnedAt, DateTime.fromMillisecondsSinceEpoch(3000));
      expect(post.isPinned, isTrue);

      final plain = Message.fromJson({
        'id': 'm1',
        'roomId': 'r1',
        'senderName': '김철수',
        'type': 'text',
        'text': '안녕',
        'createdAt': 1,
      });
      expect(plain.isPost, isFalse);
      expect(plain.title, isNull);
      expect(plain.pinnedAt, isNull);
      expect(plain.isPinned, isFalse);

      final unknown = Message.fromJson({
        'id': 'm2',
        'roomId': 'r1',
        'senderName': '김철수',
        'type': 'poll',
        'createdAt': 1,
      });
      expect(unknown.type, MessageType.text);
      expect(unknown.isPost, isFalse);
    });

    test('TopicFolder / TopicBrowseEntry / SearchResult: 새 필드와 빠진 필드', () {
      final folder = TopicFolder.fromJson(
        _folderJson('f1', '영업', 2, collapsed: true, roomIds: ['r1']),
      );
      expect(folder.name, '영업');
      expect(folder.position, 2);
      expect(folder.collapsed, isTrue);
      expect(folder.contains('r1'), isTrue);
      final bare = TopicFolder.fromJson({'id': 'f2'});
      expect(bare.name, '');
      expect(bare.position, 0);
      expect(bare.collapsed, isFalse);
      bare.roomIds.add('r2'); // 그 자리에서 바꿀 수 있어야 한다.
      expect(bare.contains('r2'), isTrue);

      final entry = TopicBrowseEntry.fromJson({
        'id': 'r1',
        'name': '공지',
        'memberCount': 3,
        'joined': false,
        'viewMode': 'board',
        'readOnly': true,
        'archived': true,
        'createdAt': 7000,
        'adminNames': ['김철수', '이영희'],
      });
      expect(entry.viewMode, TopicViewMode.board);
      expect(entry.isBoard, isTrue);
      expect(entry.readOnly, isTrue);
      expect(entry.archived, isTrue);
      expect(entry.createdAt, DateTime.fromMillisecondsSinceEpoch(7000));
      expect(entry.adminNames, ['김철수', '이영희']);
      final old = TopicBrowseEntry.fromJson({
        'id': 'r2',
        'name': '예전',
        'memberCount': 1,
        'joined': true,
      });
      expect(old.viewMode, TopicViewMode.chat);
      expect(old.readOnly, isFalse);
      expect(old.archived, isFalse);
      expect(old.createdAt, isNull);
      expect(old.adminNames, isEmpty);

      final hit = SearchResult.fromJson({
        'id': 'p1',
        'roomId': 'r1',
        'senderName': '김철수',
        'type': 'post',
        'title': '주간 보고',
        'createdAt': 1,
      });
      expect(hit.isPost, isTrue);
      expect(hit.title, '주간 보고');
    });

    test('RoomRemovedEvent: 안내 문구', () {
      const kicked = RoomRemovedEvent(
        roomId: 'r1',
        reason: 'kicked',
        name: '공지방',
      );
      expect(kicked.isKicked, isTrue);
      expect(kicked.toastText, "'공지방' 토픽에서 내보내졌습니다.");
      const deleted = RoomRemovedEvent(
        roomId: 'r1',
        reason: 'deleted',
        name: '공지방',
      );
      expect(deleted.isDeleted, isTrue);
      expect(deleted.toastText, "'공지방' 토픽이 삭제되었습니다.");
      expect(
        const RoomRemovedEvent(roomId: 'r1', reason: 'deleted').toastText,
        '토픽이 삭제되었습니다.',
      );
      expect(
        RoomRemovedEvent.fromJson({'roomId': 'r1', 'name': '잡담'}).isDeleted,
        isTrue,
      );
    });
  });

  group('토픽 권한', () {
    Room topic({
      bool readOnly = false,
      bool archived = false,
      List<String> admins = const [],
      String teamId = 't1',
    }) => Room.fromJson(
      _roomJson(
        'r1',
        teamId: teamId,
        extra: {
          'readOnly': readOnly,
          'archivedAt': archived ? 5000 : null,
          'adminIds': admins,
        },
      ),
    );

    test('canWrite/canManage — 평범한 멤버·준회원·토픽 관리자·팀 관리자', () {
      final server = _FakeServer();
      final member = _buildSession(server);
      final guest = _buildSession(server, role: AccountRole.guest);
      final owner = _buildSession(server, teamOwner: true);
      final accountAdmin = _buildSession(server, role: AccountRole.admin);

      // (세션, 방) → (canManage, canWrite)
      final cases = <String, (Session, Room, bool, bool)>{
        '멤버·보통 토픽': (member, topic(), false, true),
        '멤버·읽기 전용': (member, topic(readOnly: true), false, false),
        '멤버·보관됨': (member, topic(archived: true), false, false),
        '준회원·보통 토픽': (guest, topic(), false, true),
        '준회원·읽기 전용': (guest, topic(readOnly: true), false, false),
        '토픽 관리자·읽기 전용+보관': (
          member,
          topic(readOnly: true, archived: true, admins: ['me']),
          true,
          true,
        ),
        '다른 사람만 토픽 관리자': (
          member,
          topic(readOnly: true, admins: ['u2']),
          false,
          false,
        ),
        '팀 소유자·읽기 전용': (owner, topic(readOnly: true), true, true),
        '계정 관리자·보관됨': (accountAdmin, topic(archived: true), true, true),
      };
      cases.forEach((label, c) {
        final (session, room, manage, write) = c;
        expect(room.canManage(session), manage, reason: '$label canManage');
        expect(room.canWrite(session), write, reason: '$label canWrite');
      });
    });

    test('그룹/DM은 관리 대상이 아니고 늘 쓸 수 있다', () {
      final owner = _buildSession(_FakeServer(), teamOwner: true);
      for (final type in ['group', 'dm']) {
        final room = Room.fromJson(
          _roomJson(
            'x',
            type: type,
            extra: {
              'readOnly': true,
              'archivedAt': 1,
              'adminIds': ['me'],
            },
          ),
        );
        expect(room.canManage(owner), isFalse, reason: type);
        expect(room.canWrite(owner), isTrue, reason: type);
      }
    });

    test('팀 관리자 판단은 지금 팀이 아니라 그 방이 속한 팀 기준이다', () {
      final session = _buildSession(_FakeServer());
      session.teams.add(
        Team(id: 't2', name: '개발팀', createdAt: DateTime(2026), isOwner: true),
      );
      expect(topic(teamId: 't2').canManage(session), isTrue);
      expect(topic(teamId: 't1').canManage(session), isFalse);
    });

    test('canKick — 자기 자신은 안 되고, 팀 관리자가 아닌 토픽 관리자는 다른 토픽 관리자를 못 내보낸다', () {
      final server = _FakeServer();
      final member = _buildSession(server);
      final owner = _buildSession(server, teamOwner: true);
      final room = topic(admins: ['me', 'u2']);
      expect(room.canKick(member, 'u3'), isTrue);
      expect(room.canKick(member, 'u2'), isFalse);
      expect(room.canKick(member, 'me'), isFalse);
      expect(room.canKick(member, 'nobody'), isFalse);
      expect(room.canKick(owner, 'u2'), isTrue);
      expect(topic().canKick(member, 'u3'), isFalse); // 관리 권한 없음

      expect(
        canBeTopicAdmin(
          AppUser(id: 'a', username: 'a', name: 'a', role: 'member'),
        ),
        isTrue,
      );
      expect(
        canBeTopicAdmin(
          AppUser(id: 'b', username: 'b', name: 'b', role: 'admin'),
        ),
        isTrue,
      );
      expect(
        canBeTopicAdmin(
          AppUser(id: 'c', username: 'c', name: 'c', role: 'guest'),
        ),
        isFalse,
      );
    });

    test('공지는 팀 토픽 생성 권한이 없어도 토픽을 관리할 수 있으면 쓸 수 있다', () {
      final session = _buildSession(_FakeServer());
      session.teams.first.topicCreationPolicy = TopicCreationPolicy.owner;
      expect(session.canCreateAnnouncementIn(topic()), isFalse);
      expect(session.canCreateAnnouncementIn(topic(admins: ['me'])), isTrue);
    });

    test('읽기 전용·보관된 토픽의 공지는 토픽을 관리할 수 있는 사람만 쓴다', () {
      final session = _buildSession(_FakeServer());
      // 기본 정책(정회원 이상)이라 평소에는 쓸 수 있다.
      expect(session.canCreateAnnouncementIn(topic()), isTrue);
      expect(session.canCreateAnnouncementIn(topic(readOnly: true)), isFalse);
      expect(session.canCreateAnnouncementIn(topic(archived: true)), isFalse);
      expect(
        session.canCreateAnnouncementIn(topic(readOnly: true, admins: ['me'])),
        isTrue,
      );
    });
  });

  group('Session — 토픽 폴더', () {
    test('팀을 고르면 그 팀 폴더를 불러오고, 팀을 바꾸면 옛 팀 폴더는 바로 비운다', () async {
      final server = _FakeServer();
      server.routes['GET /api/rooms/folders'] = (r) => _json(
        r.url.queryParameters['teamId'] == 't1'
            ? [_folderJson('f2', '개발', 1), _folderJson('f1', '영업', 0)]
            : <Object>[],
      );
      final session = _buildSession(server);
      final team1 = session.teams.first;
      final team2 = Team(id: 't2', name: '개발팀', createdAt: DateTime(2026));
      session.teams.add(team2);
      session.currentTeam = null;

      session.enterTeam(team1);
      await pumpEventQueue();
      expect(session.topicFolders.map((f) => f.id), ['f1', 'f2']);

      session.enterTeam(team2);
      expect(session.topicFolders, isEmpty);
      await pumpEventQueue();
      expect(session.topicFolders, isEmpty);
      expect(
        server
            .called('GET', '/api/rooms/folders')
            .map((r) => r.url.queryParameters['teamId']),
        ['t1', 't2'],
      );
    });

    test('만들기·이름 바꾸기·접기·순서·이동·삭제는 바로 반영되고 서버엔 한 번씩만 보낸다', () async {
      final server = _FakeServer();
      server.routes['GET /api/rooms/folders'] = (_) => _json([
        _folderJson('f1', '영업', 0, roomIds: ['r1']),
        _folderJson('f2', '개발', 1),
      ]);
      server.routes['POST /api/rooms/folders'] = (r) =>
          _json(_folderJson('f3', _body(r)['name'] as String, 2), 201);
      server.routes['PATCH /api/topic-folders/f1'] = (r) => _json(
        _folderJson(
          'f1',
          _body(r)['name'] as String? ?? '영업1팀',
          0,
          collapsed: _body(r)['collapsed'] as bool? ?? false,
        ),
      );
      server.routes['PUT /api/topic-folders/order'] = (_) =>
          _json({'ok': true});
      server.routes['PUT /api/rooms/r1/folder'] = (_) => _json({'ok': true});
      server.routes['DELETE /api/topic-folders/f2'] = (_) =>
          _json({'ok': true});
      final session = _buildSession(server);
      final room = Room.fromJson(_roomJson('r1'));
      session.rooms.add(room);
      await session.loadTopicFolders();
      expect(session.topicFolderOf('r1')?.id, 'f1');

      final created = await session.createTopicFolder('  기획  ');
      expect(created.id, 'f3');
      expect(_body(server.called('POST', '/api/rooms/folders').single), {
        'teamId': 't1',
        'name': '기획',
      });
      expect(session.topicFolders.map((f) => f.id), ['f1', 'f2', 'f3']);

      final renaming = session.renameTopicFolder('f1', ' 영업1팀 ');
      expect(session.topicFolders.first.name, '영업1팀');
      await renaming;
      expect(_body(server.called('PATCH', '/api/topic-folders/f1').single), {
        'name': '영업1팀',
      });

      final getsBefore = server.called('GET', '/api/rooms/folders').length;
      final collapsing = session.setTopicFolderCollapsed('f1', true);
      expect(session.topicFolderOf('r1')!.collapsed, isTrue); // 응답 전부터
      await collapsing;
      await pumpEventQueue();
      expect(_body(server.called('PATCH', '/api/topic-folders/f1').last), {
        'collapsed': true,
      });
      expect(server.called('GET', '/api/rooms/folders'), hasLength(getsBefore));

      final reordering = session.reorderTopicFolders(['f3', 'f1']);
      expect(session.topicFolders.map((f) => f.id), ['f3', 'f1', 'f2']);
      expect(session.topicFolders.map((f) => f.position), [0, 1, 2]);
      await reordering;
      expect(_body(server.called('PUT', '/api/topic-folders/order').single), {
        'teamId': 't1',
        'folderIds': ['f3', 'f1', 'f2'],
      });

      final moving = session.moveTopicToFolder(room, 'f2');
      expect(session.topicFolderOf('r1')?.id, 'f2');
      expect(session.topicFolders[1].roomIds, isEmpty); // f1에서는 빠졌다
      await moving;
      expect(_body(server.called('PUT', '/api/rooms/r1/folder').single), {
        'folderId': 'f2',
      });

      final deleting = session.deleteTopicFolder('f2');
      expect(session.topicFolders.map((f) => f.id), ['f3', 'f1']);
      expect(session.topicFolderOf('r1'), isNull); // 폴더 밖 목록으로 돌아간다
      await deleting;
      expect(server.called('DELETE', '/api/topic-folders/f2'), hasLength(1));
    });

    test('서버가 거절하면 낙관적으로 바꾼 것을 되돌리고 예외를 다시 던진다', () async {
      final server = _FakeServer();
      server.routes['GET /api/rooms/folders'] = (_) => _json([
        _folderJson('f1', '영업', 0, roomIds: ['r1']),
        _folderJson('f2', '개발', 1),
      ]);
      http.Response fail(http.Request _) =>
          _json({'error': '폴더를 바꿀 수 없습니다.'}, 500);
      server.routes['PATCH /api/topic-folders/f1'] = fail;
      server.routes['PUT /api/topic-folders/order'] = fail;
      server.routes['PUT /api/rooms/r1/folder'] = fail;
      server.routes['DELETE /api/topic-folders/f2'] = fail;
      final session = _buildSession(server);
      final room = Room.fromJson(_roomJson('r1'));
      session.rooms.add(room);
      await session.loadTopicFolders();

      TopicFolder f(String id) =>
          session.topicFolders.firstWhere((x) => x.id == id);
      final failed = throwsA(
        isA<ApiException>().having(
          (e) => e.message,
          'message',
          '폴더를 바꿀 수 없습니다.',
        ),
      );

      final collapsing = session.setTopicFolderCollapsed('f1', true);
      expect(f('f1').collapsed, isTrue);
      await expectLater(collapsing, failed);
      expect(f('f1').collapsed, isFalse);

      await expectLater(session.renameTopicFolder('f1', '새 이름'), failed);
      expect(f('f1').name, '영업');

      await expectLater(session.reorderTopicFolders(['f2', 'f1']), failed);
      expect(session.topicFolders.map((x) => x.id), ['f1', 'f2']);
      expect(session.topicFolders.map((x) => x.position), [0, 1]);

      await expectLater(session.moveTopicToFolder(room, 'f2'), failed);
      expect(session.topicFolderOf('r1')?.id, 'f1');
      await expectLater(session.moveTopicToFolder(room, null), failed);
      expect(session.topicFolderOf('r1')?.id, 'f1');

      await expectLater(session.deleteTopicFolder('f2'), failed);
      expect(session.topicFolders.map((x) => x.id), ['f1', 'f2']);

      // 실패 뒤엔 서버 상태를 한 번 더 받아와도 되돌린 모습 그대로다.
      await pumpEventQueue();
      expect(session.topicFolders.map((x) => x.id), ['f1', 'f2']);
      expect(session.topicFolderOf('r1')?.id, 'f1');
    });

    test('폴더 변경 알림 — 지금 팀이면 다시 받고, 내 조작이 가는 중이면 끝난 뒤로 미룬다', () async {
      final server = _FakeServer();
      var serverCollapsed = false;
      server.routes['GET /api/rooms/folders'] = (_) =>
          _json([_folderJson('f1', '영업', 0, collapsed: serverCollapsed)]);
      final gate = Completer<void>();
      server.routes['PATCH /api/topic-folders/f1'] = (r) async {
        await gate.future;
        serverCollapsed = true;
        return _json(_folderJson('f1', '영업', 0, collapsed: true));
      };
      final session = _buildSession(server);
      await session.loadTopicFolders();
      int gets() => server.called('GET', '/api/rooms/folders').length;
      expect(gets(), 1);

      final collapsing = session.setTopicFolderCollapsed('f1', true);
      session.handleTopicFoldersChanged('t1'); // 내 조작의 에코가 먼저 온 셈
      await pumpEventQueue();
      expect(gets(), 1);
      expect(session.topicFolders.single.collapsed, isTrue);

      gate.complete();
      await collapsing;
      await pumpEventQueue();
      expect(gets(), 2);
      expect(session.topicFolders.single.collapsed, isTrue);

      session.handleTopicFoldersChanged('t9'); // 다른 팀 폴더 변경은 무시
      await pumpEventQueue();
      expect(gets(), 2);
      session.handleTopicFoldersChanged('t1');
      await pumpEventQueue();
      expect(gets(), 3);
    });

    test('토픽을 나가면 폴더에서도 빠진다', () async {
      final server = _FakeServer();
      server.routes['GET /api/rooms/folders'] = (_) => _json([
        _folderJson('f1', '영업', 0, roomIds: ['r1', 'r2']),
      ]);
      server.routes['POST /api/rooms/r1/leave'] = (_) => _json({'ok': true});
      final session = _buildSession(server);
      session.rooms
        ..add(Room.fromJson(_roomJson('r1')))
        ..add(Room.fromJson(_roomJson('r2')));
      await session.loadTopicFolders();

      await session.leaveRoom('r1');
      expect(session.roomById('r1'), isNull);
      expect(session.topicFolderOf('r1'), isNull);
      expect(session.topicFolderOf('r2')?.id, 'f1');
    });
  });

  group('Session — 토픽 관리', () {
    test('새 토픽: 새 설정을 보내고, 폴더를 고르면 그 폴더에 바로 보인다', () async {
      final server = _FakeServer();
      server.routes['GET /api/rooms/folders'] = (_) =>
          _json([_folderJson('f1', '영업', 0)]);
      server.routes['POST /api/rooms'] = (r) => _json(
        _roomJson(
          'r9',
          name: _body(r)['name'] as String,
          members: [_user('me', '나')],
          extra: {
            'viewMode': _body(r)['viewMode'],
            'isPublic': _body(r)['isPublic'],
            'readOnly': _body(r)['readOnly'],
            'adminIds': ['me'],
            'createdBy': 'me',
          },
        ),
      );
      final session = _buildSession(server);
      await session.loadTopicFolders();

      final room = await session.createTopic(
        name: ' 주간 보고 ',
        description: '매주 올립니다',
        isPublic: false,
        viewMode: TopicViewMode.board,
        readOnly: true,
        autoInvite: true, // 비공개라 꺼서 보낸다
        folderId: 'f1',
      );
      expect(_body(server.called('POST', '/api/rooms').single), {
        'teamId': 't1',
        'type': 'topic',
        'name': '주간 보고',
        'description': '매주 올립니다',
        'isPublic': false,
        'viewMode': 'board',
        'readOnly': true,
        'autoInvite': false,
        'folderId': 'f1',
      });
      expect(room.isBoard, isTrue);
      expect(room.isTopicAdmin('me'), isTrue);
      expect(identical(session.roomById('r9'), room), isTrue);
      expect(session.topicFolderOf('r9')?.id, 'f1');

      // 예전 호출(이름·설명·공개 여부만)도 그대로 된다.
      await session.createTopic(name: '잡담');
      expect(_body(server.called('POST', '/api/rooms').last), {
        'teamId': 't1',
        'type': 'topic',
        'name': '잡담',
        'isPublic': true,
        'viewMode': 'chat',
        'readOnly': false,
      });
    });

    test('토픽 정보 변경·보관·내보내기·관리자 지정 결과는 화면이 들고 있던 그 방 객체에 반영된다', () async {
      final server = _FakeServer();
      server.routes['PATCH /api/rooms/r1'] = (_) => _json(
        _roomJson(
          'r1',
          name: '새 이름',
          extra: {
            'readOnly': true,
            'adminIds': ['u2'],
          },
        ),
      );
      server.routes['POST /api/rooms/r1/archive'] = (r) => _json(
        _roomJson(
          'r1',
          name: '새 이름',
          extra: {
            'readOnly': true,
            'archivedAt': _body(r)['archived'] == true ? 9000 : null,
            'adminIds': ['u2'],
          },
        ),
      );
      server.routes['POST /api/rooms/r1/kick'] = (_) => _json(
        _roomJson(
          'r1',
          name: '새 이름',
          members: [_user('me', '나'), _user('u2', '김철수')],
          extra: {
            'archivedAt': 9000,
            'adminIds': ['u2'],
          },
        ),
      );
      server.routes['PUT /api/rooms/r1/admins'] = (r) => _json(
        _roomJson(
          'r1',
          name: '새 이름',
          members: [_user('me', '나'), _user('u2', '김철수')],
          extra: {'adminIds': _body(r)['userIds']},
        ),
      );
      final session = _buildSession(server);
      final held = Room.fromJson(_roomJson('r1'))
        ..unreadCount = 3
        ..favorite = true;
      session.rooms.add(held);
      expect(held.canWrite(session), isTrue);

      final updated = await session.updateTopic('r1', readOnly: true);
      expect(identical(updated, held), isTrue);
      expect(held.name, '새 이름');
      expect(held.readOnly, isTrue);
      expect(held.adminIds, ['u2']);
      expect(held.canWrite(session), isFalse);
      expect(held.unreadCount, 3); // 내 기준 값은 그대로
      expect(held.favorite, isTrue);
      expect(_body(server.called('PATCH', '/api/rooms/r1').single), {
        'readOnly': true,
      });

      await session.setTopicArchived('r1', true);
      expect(held.isArchived, isTrue);
      expect(_body(server.called('POST', '/api/rooms/r1/archive').single), {
        'archived': true,
      });

      await session.kickTopicMembers('r1', ['u3']);
      expect(held.members.map((m) => m.id), ['me', 'u2']);
      expect(_body(server.called('POST', '/api/rooms/r1/kick').single), {
        'userIds': ['u3'],
      });

      await session.setTopicAdmins('r1', ['me', 'u2']);
      expect(held.adminIds, ['me', 'u2']);
      expect(held.canManage(session), isTrue);
      expect(_body(server.called('PUT', '/api/rooms/r1/admins').single), {
        'userIds': ['me', 'u2'],
      });
      expect(session.rooms, hasLength(1));
    });

    test('room:removed(내보내짐) — 방·컨트롤러·활성 방·폴더를 정리하고 안내 이벤트를 흘린다', () async {
      final server = _FakeServer();
      server.routes['GET /api/rooms/folders'] = (_) => _json([
        _folderJson('f1', '영업', 0, roomIds: ['r1', 'r2']),
      ]);
      final session = _buildSession(server);
      final room = Room.fromJson(_roomJson('r1', name: '공지방'));
      session.rooms
        ..add(room)
        ..add(Room.fromJson(_roomJson('r2', name: '잡담')));
      await session.loadTopicFolders();
      final controller = session.controllerFor(room);
      session.setActiveRoom('r1');
      final events = <RoomRemovedEvent>[];
      final sub = session.roomRemovedEvents.listen(events.add);

      session.handleRoomRemoved(
        const RoomRemovedEvent(roomId: 'r1', reason: 'kicked'),
      );
      await pumpEventQueue();
      expect(session.roomById('r1'), isNull);
      expect(session.activeRoomId, isNull);
      expect(session.topicFolderOf('r1'), isNull);
      expect(session.topicFolderOf('r2')?.id, 'f1');
      expect(
        () => ChangeNotifier.debugAssertNotDisposed(controller),
        throwsFlutterError,
      );
      expect(events, hasLength(1));
      expect(events.single.roomId, 'r1');
      expect(events.single.isKicked, isTrue);
      expect(events.single.name, '공지방'); // 서버가 이름을 안 줘도 로컬 이름으로
      expect(events.single.toastText, "'공지방' 토픽에서 내보내졌습니다.");

      // 이미 정리된 방이면 조용히 넘어간다.
      session.handleRoomRemoved(
        const RoomRemovedEvent(roomId: 'r1', reason: 'deleted', name: '공지방'),
      );
      await pumpEventQueue();
      expect(events, hasLength(1));
      await sub.cancel();
    });

    test('내가 이 기기에서 삭제한 토픽은 room:removed가 먼저 와도 안내 없이 정리만 한다', () async {
      final server = _FakeServer();
      late Session session;
      server.routes['DELETE /api/rooms/r1'] = (_) {
        // 서버는 HTTP 응답보다 room:removed를 먼저 보낼 수 있다.
        session.handleRoomRemoved(
          const RoomRemovedEvent(roomId: 'r1', reason: 'deleted', name: '공지방'),
        );
        return _json({'ok': true});
      };
      session = _buildSession(server);
      session.rooms.add(Room.fromJson(_roomJson('r1')));
      final events = <RoomRemovedEvent>[];
      final sub = session.roomRemovedEvents.listen(events.add);

      await session.deleteTopic('r1');
      await pumpEventQueue();
      expect(session.roomById('r1'), isNull);
      expect(events, isEmpty);
      await sub.cancel();
    });
  });

  group('보드 게시글', () {
    Session boardSession(_FakeServer server, {List<Object>? history}) {
      server.routes['GET /api/rooms/r1/messages'] = (_) =>
          _json(history ?? <Object>[]);
      final session = _buildSession(server);
      session.rooms.add(
        Room.fromJson(_roomJson('r1', extra: {'viewMode': 'board'})),
      );
      return session;
    }

    test('sendPost — message:send로 type post·제목·본문·첨부 목록을 보낸다', () async {
      final server = _FakeServer();
      final session = boardSession(server);
      final sent = <Map<String, dynamic>>[];
      session.chatSocket.debugSendOverride = (payload) async {
        sent.add(payload);
        return {'ok': true, 'message': _postJson('p9', title: '주간 보고')};
      };
      final controller = session.controllerFor(session.rooms.single);
      await _waitFor(() => !controller.loading);

      final result = await controller.sendPost(
        title: '  주간 보고 ',
        text: '이번 주 한 일',
        textFormat: const [TextFormatRun(0, 2, Fmt.bold)],
        attachments: [
          UploadedAttachment(
            isImage: true,
            url: '/uploads/a.png',
            fileName: 'a.png',
            size: 10,
            mimeType: 'image/png',
            thumbnailUrl: '/uploads/a_t.jpg',
          ),
          UploadedAttachment(
            isImage: false,
            url: '/uploads/b.pdf',
            fileName: 'b.pdf',
            size: 20,
          ),
        ],
      );
      expect(sent.single, {
        'roomId': 'r1',
        'type': 'post',
        'title': '주간 보고',
        'text': '이번 주 한 일',
        'textFormat': textFormatToJson(const [TextFormatRun(0, 2, Fmt.bold)]),
        'attachments': [
          {
            'kind': 'image',
            'fileUrl': '/uploads/a.png',
            'fileName': 'a.png',
            'fileSize': 10,
            'mimeType': 'image/png',
            'thumbnailUrl': '/uploads/a_t.jpg',
          },
          {
            'kind': 'file',
            'fileUrl': '/uploads/b.pdf',
            'fileName': 'b.pdf',
            'fileSize': 20,
          },
        ],
      });
      expect(result?.isPost, isTrue);
      expect(result?.title, '주간 보고');

      // Session에서도 방만 주면 같은 경로로 보낸다(첨부가 없으면 목록을 안 보낸다).
      await session.sendPost(session.rooms.single, title: '두 번째', text: '본문');
      expect(sent.last, {
        'roomId': 'r1',
        'type': 'post',
        'title': '두 번째',
        'text': '본문',
      });
    });

    test('sendPost — 빈 제목은 보내기 전에 막고, 서버 거절은 그 문구 그대로 알린다', () async {
      final server = _FakeServer();
      final session = boardSession(server);
      var calls = 0;
      session.chatSocket.debugSendOverride = (payload) async {
        calls++;
        return {'ok': false, 'error': '읽기 전용 토픽에서는 토픽 관리자만 글을 쓸 수 있습니다.'};
      };
      final controller = session.controllerFor(session.rooms.single);

      await expectLater(
        controller.sendPost(title: '   ', text: '본문'),
        throwsA(
          isA<ApiException>().having((e) => e.message, 'message', '제목을 입력하세요.'),
        ),
      );
      await expectLater(
        controller.sendPost(title: '제목', text: ' '),
        throwsA(isA<ApiException>()),
      );
      expect(calls, 0);

      Object? error;
      try {
        await controller.sendPost(title: '제목', text: '본문');
      } catch (e) {
        error = e;
      }
      expect(error, isA<MessageSendException>());
      expect('$error', '읽기 전용 토픽에서는 토픽 관리자만 글을 쓸 수 있습니다.');
    });

    test('게시글 수정·고정 — 응답을 바로 반영하고 고정 목록을 맞춘다', () async {
      final server = _FakeServer();
      final session = boardSession(
        server,
        history: [
          _postJson('p1', title: '첫 글', createdAt: 2000),
          _postJson('p2', title: '둘째 글', createdAt: 3000),
        ],
      );
      server.routes['GET /api/rooms/r1/pinned-posts'] = (_) => _json([
        _postJson('p0', title: '옛 공지', createdAt: 500, pinnedAt: 600),
      ]);
      server.routes['PATCH /api/messages/p1'] = (r) => _json(
        _postJson(
          'p1',
          title: _body(r)['title'] as String,
          text: _body(r)['text'] as String,
          createdAt: 2000,
          editedAt: 4000,
        ),
      );
      server.routes['POST /api/messages/p2/pin'] = (r) => _json(
        _postJson(
          'p2',
          title: '둘째 글',
          createdAt: 3000,
          pinnedAt: _body(r)['pinned'] == true ? 5000 : null,
        ),
      );
      final controller = session.controllerFor(session.rooms.single);
      await _waitFor(() => !controller.loading);
      final p1 = controller.messages.firstWhere((m) => m.id == 'p1');
      final p2 = controller.messages.firstWhere((m) => m.id == 'p2');

      await controller.editPost('p1', title: ' 첫 글(수정) ', text: '새 본문');
      expect(_body(server.called('PATCH', '/api/messages/p1').single), {
        'title': '첫 글(수정)',
        'text': '새 본문',
      });
      expect(p1.title, '첫 글(수정)');
      expect(p1.text, '새 본문');
      expect(p1.editedAt, DateTime.fromMillisecondsSinceEpoch(4000));

      await controller.loadPinnedPosts();
      expect(controller.pinnedPostsLoaded, isTrue);
      expect(controller.pinnedPosts.map((m) => m.id), ['p0']);

      await controller.setPostPinned('p2', true);
      expect(_body(server.called('POST', '/api/messages/p2/pin').single), {
        'pinned': true,
      });
      expect(p2.isPinned, isTrue);
      // 타임라인의 그 인스턴스가 들어가고, 게시글 작성 시각 최신순이다.
      expect(controller.pinnedPosts.map((m) => m.id), ['p2', 'p0']);
      expect(identical(controller.pinnedPosts.first, p2), isTrue);

      // 다른 멤버의 고정 해제(message:edited)·삭제(message:deleted)도 그 자리에서 맞춘다.
      controller.applyEdit(
        Message.fromJson(_postJson('p0', title: '옛 공지', createdAt: 500)),
      );
      expect(controller.pinnedPosts.map((m) => m.id), ['p2']);
      controller.applyDelete('p2');
      expect(controller.pinnedPosts, isEmpty);
      expect(p2.deleted, isTrue);
    });

    test('타임라인에 없는 옛 고정 게시글에도 댓글·수정이 반영된다', () async {
      final server = _FakeServer();
      final session = boardSession(server);
      server.routes['GET /api/rooms/r1/pinned-posts'] = (_) => _json([
        _postJson('p0', title: '옛 공지', createdAt: 500, pinnedAt: 600),
      ]);
      final controller = session.controllerFor(session.rooms.single);
      await _waitFor(() => !controller.loading);
      await controller.loadPinnedPosts();
      final p0 = controller.pinnedPosts.single;

      controller.applyEdit(
        Message.fromJson(
          _postJson('p0', title: '옛 공지(수정)', createdAt: 500, pinnedAt: 600),
        ),
      );
      expect(p0.title, '옛 공지(수정)');
      expect(controller.pinnedPosts.single, same(p0));

      final comment = Comment.fromJson({
        'id': 'c1',
        'messageId': 'p0',
        'roomId': 'r1',
        'senderId': 'u2',
        'senderName': '김철수',
        'type': 'text',
        'text': '확인했습니다',
        'createdAt': 700,
      });
      controller.addComment(comment);
      expect(p0.comments.single.text, '확인했습니다');
      controller.applyCommentDelete('c1');
      expect(p0.comments.single.deleted, isTrue);
    });

    test('게시글 알림·방 목록 미리보기는 "게시글: 제목"이다', () async {
      final server = _FakeServer();
      final notifications = _FakeNotifications();
      final session = Session(
        notifications: notifications,
        settings: AppSettings(),
      );
      session.api = ApiClient(
        baseUrl: 'https://test.local',
        token: 't',
        httpClient: server.client,
      );
      session.userId = 'me';
      final room = Room.fromJson(_roomJson('r1', extra: {'viewMode': 'board'}));
      session.rooms.add(room);

      await session.handleSocketMessage(
        Message.fromJson(_postJson('p1', title: '주간 보고', createdAt: 9000)),
      );
      expect(room.lastMessagePreview, '게시글: 주간 보고');
      expect(notifications.shown.single['body'], '게시글: 주간 보고');
      expect(room.unreadCount, 1);
    });

    test('uploadLocalFiles — 로컬 파일을 올려 게시글 첨부로 쓸 모양을 만든다', () async {
      final server = _FakeServer();
      server.routes['POST /api/upload'] = (_) => _json({
        'url': '/uploads/memo.txt',
        'fileName': 'memo.txt',
        'size': 5,
        'mimeType': 'text/plain',
      });
      final session = boardSession(server);
      final controller = session.controllerFor(session.rooms.single);
      final dir = Directory.systemTemp.createTempSync('topic_foundation_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}memo.txt')
        ..writeAsStringSync('hello');

      final progress = <int>[];
      final uploaded = await controller.uploadLocalFiles([
        XFile(file.path),
      ], onProgress: (index, sent, total) => progress.add(index));
      expect(uploaded.single.isImage, isFalse);
      expect(uploaded.single.toPayload(), {
        'kind': 'file',
        'fileUrl': '/uploads/memo.txt',
        'fileName': 'memo.txt',
        'fileSize': 5,
        'mimeType': 'text/plain',
      });
      expect(progress, everyElement(0));
      expect(server.called('POST', '/api/upload'), hasLength(1));
    });
  });

  group('게시글 동기화·방 정리 보강', () {
    Session boardSession(
      _FakeServer server, {
      List<Object> history = const [],
      List<Object> pinned = const [],
    }) {
      server.routes['GET /api/rooms/r1/messages'] = (_) => _json(history);
      server.routes['GET /api/rooms/r1/pinned-posts'] = (_) => _json(pinned);
      final session = _buildSession(server);
      session.rooms.add(
        Room.fromJson(_roomJson('r1', extra: {'viewMode': 'board'})),
      );
      return session;
    }

    Comment comment(String id, String messageId, int createdAt) =>
        Comment.fromJson({
          'id': id,
          'messageId': messageId,
          'roomId': 'r1',
          'senderId': 'u2',
          'senderName': '김철수',
          'type': 'text',
          'text': '댓글 $id',
          'createdAt': createdAt,
        });

    test('완전히 지워진(message:expired) 고정 게시글은 고정 목록에서도 빠지고 삭제로 표시된다', () async {
      final server = _FakeServer();
      final session = boardSession(
        server,
        history: [_postJson('p1', createdAt: 2000, pinnedAt: 2500)],
        pinned: [
          _postJson('p1', createdAt: 2000, pinnedAt: 2500),
          _postJson('p0', createdAt: 500, pinnedAt: 600),
        ],
      );
      final controller = session.controllerFor(session.rooms.single);
      await _waitFor(() => !controller.loading);
      await controller.loadPinnedPosts();
      final p1 = controller.messages.firstWhere((m) => m.id == 'p1');
      final p0 = controller.pinnedPosts.firstWhere((m) => m.id == 'p0');
      var notified = 0;
      controller.addListener(() => notified++);

      controller.applyExpire('p1');
      expect(controller.messages.where((m) => m.id == 'p1'), isEmpty);
      expect(controller.pinnedPosts.map((m) => m.id), ['p0']);
      // 상세 화면이 들고 있던 인스턴스도 "삭제된 게시글"로 바뀐다.
      expect(p1.deleted, isTrue);
      expect(notified, 1);

      // 타임라인엔 없고 고정 목록에만 있던 옛 게시글도 같다.
      controller.applyExpire('p0');
      expect(controller.pinnedPosts, isEmpty);
      expect(p0.deleted, isTrue);
      expect(notified, 2);
    });

    test('고정 목록을 다시 받아도 상세가 들고 있는 옛 게시글 인스턴스는 그대로 이어진다', () async {
      final server = _FakeServer();
      final session = boardSession(
        server,
        pinned: [_postJson('p0', title: '옛 공지', createdAt: 500, pinnedAt: 600)],
      );
      final controller = session.controllerFor(session.rooms.single);
      await _waitFor(() => !controller.loading);
      await controller.loadPinnedPosts();
      final held = controller.pinnedPosts.single;

      // 재연결 뒤 다시 받기 — 그 사이 제목이 바뀌었다.
      server.routes['GET /api/rooms/r1/pinned-posts'] = (_) => _json([
        _postJson('p0', title: '옛 공지(수정)', createdAt: 500, pinnedAt: 600),
      ]);
      await controller.loadPinnedPosts();
      expect(controller.pinnedPosts.single, same(held));
      expect(held.title, '옛 공지(수정)');

      controller.addComment(comment('c1', 'p0', 700));
      expect(held.comments.map((c) => c.id), ['c1']);
    });

    test('고정 목록에만 있던 옛 게시글이 과거 페이지로 타임라인에 들어와도 같은 인스턴스를 쓴다', () async {
      final server = _FakeServer();
      server.routes['GET /api/rooms/r1/messages'] = (r) => _json(
        r.url.queryParameters['before'] == null
            ? [
                for (var i = 0; i < 50; i++)
                  _postJson('n$i', createdAt: 10000 + i),
              ]
            : [
                {
                  ..._postJson('p0', createdAt: 500, pinnedAt: 600),
                  'comments': [
                    {
                      'id': 'c1',
                      'messageId': 'p0',
                      'roomId': 'r1',
                      'senderId': 'u2',
                      'senderName': '김철수',
                      'type': 'text',
                      'text': '먼저 단 댓글',
                      'createdAt': 550,
                    },
                  ],
                },
              ],
      );
      server.routes['GET /api/rooms/r1/pinned-posts'] = (_) =>
          _json([_postJson('p0', createdAt: 500, pinnedAt: 600)]);
      final session = _buildSession(server);
      session.rooms.add(
        Room.fromJson(_roomJson('r1', extra: {'viewMode': 'board'})),
      );
      final controller = session.controllerFor(session.rooms.single);
      await _waitFor(() => !controller.loading);
      await controller.loadPinnedPosts();
      final held = controller.pinnedPosts.single;

      await controller.loadOlderMessages();
      final inTimeline = controller.messages.firstWhere((m) => m.id == 'p0');
      expect(inTimeline, same(held));
      expect(controller.pinnedPosts.single, same(held));
      expect(held.comments.map((c) => c.id), ['c1']);
      // 타임라인에도 댓글 항목이 한 번만 생긴다.
      expect(
        controller.messages.where(
          (m) => m.type == MessageType.comment && m.asComment!.id == 'c1',
        ),
        hasLength(1),
      );

      controller.addComment(comment('c2', 'p0', 800));
      expect(held.comments.map((c) => c.id), ['c1', 'c2']);
    });

    test('불러오지 않은 옛 게시글을 다른 사람이 고정하면 고정 목록을 댓글까지 다시 받는다', () async {
      final server = _FakeServer();
      final session = boardSession(server);
      final controller = session.controllerFor(session.rooms.single);
      await _waitFor(() => !controller.loading);
      await controller.loadPinnedPosts();
      expect(controller.pinnedPosts, isEmpty);

      server.routes['GET /api/rooms/r1/pinned-posts'] = (_) => _json([
        {
          ..._postJson('old', createdAt: 100, pinnedAt: 900),
          'comments': [
            {
              'id': 'c1',
              'messageId': 'old',
              'roomId': 'r1',
              'senderId': 'u2',
              'senderName': '김철수',
              'type': 'text',
              'text': '댓글',
              'createdAt': 150,
            },
          ],
        },
      ]);
      // message:edited 브로드캐스트에는 댓글이 없다(서버 postDto).
      controller.applyEdit(
        Message.fromJson(_postJson('old', createdAt: 100, pinnedAt: 900)),
      );
      await _waitFor(() => controller.pinnedPosts.isNotEmpty);
      expect(controller.pinnedPosts.single.comments.map((c) => c.id), ['c1']);
    });

    test('처음 불러오기가 실패해도 재연결 새로고침이 되면 오류를 거두고 과거 페이지를 이어 받는다', () async {
      final server = _FakeServer();
      var fail = true;
      server.routes['GET /api/rooms/r1/messages'] = (r) {
        if (fail) return _json({'error': '잠시 후 다시 시도하세요.'}, 500);
        return _json(
          r.url.queryParameters['before'] == null
              ? [
                  for (var i = 0; i < 50; i++)
                    _postJson('n$i', createdAt: 10000 + i),
                ]
              : [_postJson('old', createdAt: 100)],
        );
      };
      final session = _buildSession(server);
      session.rooms.add(
        Room.fromJson(_roomJson('r1', extra: {'viewMode': 'board'})),
      );
      final controller = session.controllerFor(session.rooms.single);
      await _waitFor(() => !controller.loading);
      expect(controller.error, isNotNull);

      fail = false;
      await controller.refresh();
      expect(controller.error, isNull);
      expect(controller.messages, hasLength(50));
      await controller.loadOlderMessages();
      expect(controller.messages.map((m) => m.id), contains('old'));
      expect(
        server
            .called('GET', '/api/rooms/r1/messages')
            .last
            .url
            .queryParameters['before'],
        '10000',
      );
    });

    test('게시글 제목·본문 길이는 서버처럼 글자(이모지 한 덩어리 = 1자) 단위로 센다', () async {
      final server = _FakeServer();
      final session = boardSession(server);
      final sent = <Map<String, dynamic>>[];
      session.chatSocket.debugSendOverride = (payload) async {
        sent.add(payload);
        return {'ok': true};
      };
      final controller = session.controllerFor(session.rooms.single);

      // 이모지 100개 — UTF-16으로는 200이지만 서버는 100자로 센다.
      await controller.sendPost(title: '😀' * 100, text: '👍' * 20000);
      expect(sent, hasLength(1));
      await expectLater(
        controller.sendPost(title: '😀' * 101, text: '본문'),
        throwsA(isA<ApiException>()),
      );
      await expectLater(
        controller.sendPost(title: '제목', text: '👍' * 20001),
        throwsA(isA<ApiException>()),
      );
      expect(sent, hasLength(1));
    });

    test('정리 경로는 컨트롤러를 새로 만들지 않는다(existingControllerFor)', () async {
      final server = _FakeServer();
      final session = boardSession(server);
      final room = session.rooms.single;
      expect(session.existingControllerFor('r1'), isNull);
      final controller = session.controllerFor(room);
      expect(session.existingControllerFor('r1'), same(controller));
      session.handleRoomRemoved(
        const RoomRemovedEvent(roomId: 'r1', reason: 'deleted'),
      );
      expect(session.existingControllerFor('r1'), isNull);
      // 사라진 방의 게시글 조작은 새 컨트롤러(=옛 방 기록 다시 받기)를 만들지 않는다.
      await expectLater(
        session.setPostPinned(room, 'p1', true),
        throwsA(isA<ApiException>()),
      );
      expect(session.existingControllerFor('r1'), isNull);
    });

    test('새 팀에 들어갈 때 먼저 온 자동 초대 토픽은 팀 방 목록을 받아도 한 번만 있다', () async {
      final server = _FakeServer();
      server.routes['POST /api/rooms/auto/join'] = (_) =>
          _json(_roomJson('auto', teamId: 't2', name: '전체 공지'));
      server.routes['GET /api/rooms'] = (_) => _json([
        _roomJson(
          'auto',
          teamId: 't2',
          name: '전체 공지',
          extra: {'unreadCount': 3},
        ),
        _roomJson('other', teamId: 't2', name: '잡담'),
      ]);
      final session = _buildSession(server);
      // 서버는 자동 초대 토픽의 room:created를 team:joined보다 먼저 보낸다 — 이미 목록에 있다.
      final auto = await session.joinRoom('auto');

      await session.handleTeamEvent(
        Team(id: 't2', name: '디자인팀', createdAt: DateTime(2026)),
      );
      expect(session.rooms.where((r) => r.id == 'auto'), hasLength(1));
      expect(session.roomById('auto'), same(auto));
      expect(auto.unreadCount, 3); // 내 기준으로 받은 목록이라 안읽음도 맞춘다
      expect(session.roomById('other'), isNotNull);
      expect(session.teams.map((t) => t.id), contains('t2'));
    });

    test('재연결 동기화 — 그 사이 생긴 방은 지우지 않고, 그 사이 사라진 방은 되살리지 않는다', () async {
      final server = _FakeServer();
      late Session session;
      server.routes['GET /api/teams'] = (_) => _json([
        {'id': 't1', 'name': '영업팀', 'createdAt': 0},
      ]);
      server.routes['POST /api/rooms/new/join'] = (_) =>
          _json(_roomJson('new', name: '새 토픽'));
      server.routes['GET /api/rooms'] = (_) async {
        // 목록을 만든 뒤(=응답이 오기 전)에 새 토픽에 들어가고, 옛 토픽에서는 내보내졌다.
        await session.joinRoom('new');
        session.handleRoomRemoved(
          const RoomRemovedEvent(roomId: 'gone', reason: 'kicked'),
        );
        return _json([_roomJson('r1'), _roomJson('gone', name: '내보내진 토픽')]);
      };
      session = _buildSession(server);
      session.rooms
        ..add(Room.fromJson(_roomJson('r1')))
        ..add(Room.fromJson(_roomJson('gone', name: '내보내진 토픽')));
      // 이미 열어 둔 방들 — 동기화가 하나씩 다시 받는 동안 다른 방이 열려도 멈추지 않는다.
      session.controllerFor(session.roomById('r1')!);
      var refreshes = 0;
      server.routes['GET /api/rooms/r1/messages'] = (_) {
        refreshes++;
        if (refreshes == 2) {
          session.controllerFor(Room.fromJson(_roomJson('other')));
        }
        return _json(<Object>[]);
      };

      await session.resyncAfterReconnect();
      expect(session.roomById('new'), isNotNull);
      expect(session.roomById('gone'), isNull);
      expect(session.roomById('r1'), isNotNull);
      expect(refreshes, 2); // 처음 열 때 한 번 + 동기화 한 번
    });
  });
}
