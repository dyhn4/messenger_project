import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/models/text_format.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/room_chat_controller.dart';
// ScheduledMessage·ScheduledMessageEvent·room.canEditGroupInfo는 session.dart가 같이 내보낸다.
import 'package:client/services/session.dart';
import 'package:client/services/time_format.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

/// 채팅 개편(채팅 시작·그룹채팅 정보 변경·나와의 대화·메시지 예약 발송)의 클라이언트 기반 —
/// 모델 파싱, ApiClient 요청 모양, Session의 상태·조작, 소켓 이벤트, 방과 무관한 업로드.

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
    bool replyable = false,
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

Map<String, dynamic> _user(String id, String name, {String role = 'member'}) =>
    {'id': id, 'username': id, 'name': name, 'role': role};

Map<String, dynamic> _roomJson(
  String id, {
  String type = 'topic',
  String? name = '공지방',
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

Map<String, dynamic> _selfRoomJson({String teamId = 't1'}) => _roomJson(
  'self-$teamId',
  type: 'dm',
  name: null,
  teamId: teamId,
  members: [_user('me', '나')],
  extra: {'isSelf': true},
);

/// 발송 시각 기본값 — 테스트가 도는 시각과 상관없이 늘 앞으로 올 15분 단위.
final _later = defaultScheduleTime().add(const Duration(hours: 2));

Map<String, dynamic> _scheduledJson(
  String id, {
  String? roomId = 'r1',
  String? roomName = '공지방',
  String? title,
  String text = '예약한 메시지',
  DateTime? sendAt,
  String status = 'scheduled',
  String? failReason,
  String teamId = 't1',
  List<Map<String, dynamic>> attachments = const [],
}) => {
  'id': id,
  'teamId': teamId,
  'roomId': roomId,
  'roomName': roomName,
  'title': title,
  'text': text,
  'textFormat': null,
  'attachments': attachments,
  'sendAt': (sendAt ?? _later).millisecondsSinceEpoch,
  'status': status,
  'failReason': failReason,
  'createdAt': 1000,
  'updatedAt': 2000,
};

Session _buildSession(
  _FakeServer server, {
  AccountRole role = AccountRole.member,
  _FakeNotifications? notifications,
}) {
  final session = Session(
    notifications: notifications ?? _FakeNotifications(),
    settings: AppSettings(),
  );
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: server.client,
  );
  session.userId = 'me';
  session.accountRole = role;
  final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  return session;
}

Matcher _apiError(String message) =>
    throwsA(isA<ApiException>().having((e) => e.message, 'message', message));

void main() {
  // 이미지 첨부의 썸네일을 임시 파일로 쓸 때 path_provider(플랫폼 채널)를 흉내 내야 해서.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('모델', () {
    test('Room: 나와의 대화(isSelf)는 늘 "나와의 대화"로 보이고, 없으면 아니다', () {
      final self = Room.fromJson(_selfRoomJson());
      expect(self.isSelf, isTrue);
      expect(self.type, RoomType.dm);
      expect(self.displayName('me'), selfRoomName);
      expect(self.originalDisplayName('me'), '나와의 대화');
      // 별칭이 붙어 와도(서버가 막지만) 이름은 그대로다.
      self.customName = '메모장';
      expect(self.displayName('me'), '나와의 대화');

      final dm = Room.fromJson(
        _roomJson(
          'dm1',
          type: 'dm',
          name: null,
          members: [_user('me', '나'), _user('u2', '김철수')],
        ),
      );
      expect(dm.isSelf, isFalse);
      expect(dm.displayName('me'), '김철수');

      final local = Room(
        id: 'x',
        teamId: 't1',
        type: RoomType.dm,
        name: null,
        members: const [],
        createdAt: DateTime(2026),
        lastRead: const {},
      );
      expect(local.isSelf, isFalse);
    });

    test('Room: 그룹 설명·멤버 이름, 아이콘 변경은 그 자리에서 반영된다', () {
      final group = Room.fromJson(
        _roomJson(
          'g1',
          type: 'group',
          name: '점심',
          extra: {
            'description': '메뉴 정하기',
            'iconType': 'emoji',
            'iconEmoji': '🍀',
            'iconColor': '#37B24D',
          },
        ),
      );
      expect(group.description, '메뉴 정하기');
      expect(group.displayName('me'), '점심');
      expect(group.memberNames('me'), '김철수, 이영희');
      expect(groupNameMaxLength, 60);
      expect(groupDescriptionMaxLength, 300);

      group.mergeServerState(
        Room.fromJson(
          _roomJson(
            'g1',
            type: 'group',
            name: null,
            extra: {
              'description': null,
              'iconType': 'initial',
              'iconColor': '#4C6EF5',
            },
          ),
        ),
      );
      expect(group.name, isNull);
      expect(group.displayName('me'), '김철수, 이영희');
      expect(group.description, isNull);
      expect(group.iconType, 'initial');
      expect(group.iconEmoji, isNull);
      expect(group.iconColor, '#4C6EF5');
    });

    test('ScheduledMessage: DTO를 읽고, 첨부는 메시지 첨부 모양이다', () {
      final m = ScheduledMessage.fromJson({
        ..._scheduledJson(
          's1',
          title: '주간 보고',
          text: '이번 주 한 일',
          status: 'failed',
          failReason: '토픽이 보관되어 보낼 수 없습니다.',
          attachments: [
            {
              'kind': 'image',
              'fileUrl': '/files/a',
              'fileName': 'a.png',
              'fileSize': 10,
              'mimeType': 'image/png',
              'thumbnailUrl': '/files/a_t',
            },
            {
              'id': 'att-2',
              'kind': 'file',
              'fileUrl': '/files/b',
              'fileName': 'b.pdf',
              'fileSize': 20,
            },
            {'kind': 'file'}, // 파일 주소가 없는 칸은 버린다
          ],
        ),
        'textFormat': [
          {'s': 0, 'e': 2, 'f': Fmt.bold},
        ],
        'sendAt': DateTime(2026, 10, 2, 9).millisecondsSinceEpoch,
      });
      expect(m.id, 's1');
      expect(m.teamId, 't1');
      expect(m.roomId, 'r1');
      expect(m.roomName, '공지방');
      expect(m.title, '주간 보고');
      expect(m.isPost, isTrue);
      expect(m.preview, '주간 보고');
      expect(m.text, '이번 주 한 일');
      expect(m.textFormat!.single.flags, Fmt.bold);
      expect(m.sendAt, DateTime(2026, 10, 2, 9));
      expect(m.status, ScheduledMessageStatus.failed);
      expect(m.isFailed, isTrue);
      expect(m.isScheduled, isFalse);
      expect(m.failReason, '토픽이 보관되어 보낼 수 없습니다.');
      expect(m.createdAt, DateTime.fromMillisecondsSinceEpoch(1000));
      expect(m.updatedAt, DateTime.fromMillisecondsSinceEpoch(2000));
      expect(m.attachments, hasLength(2));
      expect(m.attachments.first, isA<MessageAttachment>());
      expect(m.attachments.first.isImage, isTrue);
      expect(m.attachments.first.id, 's1#0'); // id가 없던 칸은 목록 안에서만 겹치지 않게
      expect(m.attachments.last.id, 'att-2');
      // 고쳐서 다시 보낼 땐 채팅 입력칸과 같은 모양이다.
      expect(m.uploadedAttachments.map((a) => a.toPayload()), [
        {
          'kind': 'image',
          'fileUrl': '/files/a',
          'fileName': 'a.png',
          'fileSize': 10,
          'mimeType': 'image/png',
          'thumbnailUrl': '/files/a_t',
        },
        {
          'kind': 'file',
          'fileUrl': '/files/b',
          'fileName': 'b.pdf',
          'fileSize': 20,
        },
      ]);

      final retried = m.withStatus(ScheduledMessageStatus.scheduled);
      expect(retried.isScheduled, isTrue);
      expect(retried.failReason, isNull);
      expect(retried.text, m.text);
      final failed = retried.withStatus(
        ScheduledMessageStatus.failed,
        failReason: '사유',
      );
      expect(failed.failReason, '사유');
    });

    test('ScheduledMessage: 빠진 값은 기본값(예약됨·첨부 없음)으로, 방이 지워졌으면 roomId가 없다', () {
      final m = ScheduledMessage.fromJson({
        'id': 's2',
        'teamId': 't1',
        'roomId': null,
        'text': '방이 사라졌다',
        'title': '',
        'sendAt': 5000,
      });
      expect(m.roomId, isNull);
      expect(m.roomName, isNull);
      expect(m.title, isNull); // 빈 제목은 게시글이 아니다
      expect(m.isPost, isFalse);
      expect(m.preview, '방이 사라졌다');
      expect(m.status, ScheduledMessageStatus.scheduled);
      expect(m.attachments, isEmpty);
      expect(m.textFormat, isNull);
      expect(m.failReason, isNull);
      expect(m.createdAt, m.sendAt);
      expect(
        scheduledStatusFromWire('sending'),
        ScheduledMessageStatus.sending,
      );
      expect(scheduledStatusFromWire('뭔가'), ScheduledMessageStatus.scheduled);
    });

    test('ScheduledMessageEvent: 발송·실패 알림과 토스트 문구', () {
      final sent = ScheduledMessageEvent.fromSentJson({
        'id': 's1',
        'teamId': 't1',
        'roomId': 'r1',
        'roomName': '공지방',
        'messageIds': ['m1', 'm2'],
      });
      expect(sent.isSent, isTrue);
      expect(sent.messageIds, ['m1', 'm2']);
      expect(sent.toastText, '예약 메시지를 보냈습니다 · 공지방');
      final failed = ScheduledMessageEvent.fromFailedJson({
        'id': 's2',
        'teamId': 't1',
        'roomId': 'r1',
        'roomName': '공지방',
        'reason': '대화방의 멤버가 아니어서 보내지 못했습니다.',
      });
      expect(failed.isFailed, isTrue);
      expect(
        failed.toastText,
        '예약 메시지를 보내지 못했습니다 (공지방): 대화방의 멤버가 아니어서 보내지 못했습니다.',
      );
      expect(
        failed.withRoomName(null).toastText,
        startsWith('예약 메시지를 보내지 못했습니다 (대화방)'),
      );
    });

    test('발송 시각 — 15분 단위, 기본값, 서버와 같은 검사 문구', () {
      final now = DateTime(2026, 9, 30, 10, 7, 30);
      expect(isScheduleSlot(DateTime(2026, 9, 30, 10, 15)), isTrue);
      expect(isScheduleSlot(DateTime(2026, 9, 30, 10, 20)), isFalse);
      expect(isScheduleSlot(DateTime(2026, 9, 30, 10, 15, 1)), isFalse);
      expect(
        ceilToScheduleSlot(DateTime(2026, 9, 30, 10, 15)),
        DateTime(2026, 9, 30, 10, 15),
      );
      expect(
        ceilToScheduleSlot(DateTime(2026, 9, 30, 10, 15, 0, 1)),
        DateTime(2026, 9, 30, 10, 30),
      );
      // 지금+15분 이후의 가장 가까운 15분 단위.
      expect(defaultScheduleTime(now), DateTime(2026, 9, 30, 10, 30));
      expect(
        defaultScheduleTime(DateTime(2026, 9, 30, 10)),
        DateTime(2026, 9, 30, 10, 15),
      );
      expect(
        defaultScheduleTime(DateTime(2026, 9, 30, 23, 50)),
        DateTime(2026, 10, 1, 0, 15),
      );

      expect(
        validateScheduledSendAt(DateTime(2026, 9, 30, 10, 20), now: now),
        '발송 시간은 15분 단위로 선택하세요.',
      );
      expect(
        validateScheduledSendAt(DateTime(2026, 9, 30, 10), now: now),
        '발송 시간은 지금 이후로 선택하세요.',
      );
      expect(
        validateScheduledSendAt(DateTime(2026, 9, 30, 10, 15), now: now),
        isNull,
      );
      final lastSlot = ceilToScheduleSlot(latestScheduleTime(now));
      expect(
        validateScheduledSendAt(lastSlot, now: now),
        '최대 90일 뒤까지만 예약할 수 있습니다.',
      );
      expect(
        validateScheduledSendAt(
          lastSlot.subtract(const Duration(minutes: 15)),
          now: now,
        ),
        isNull,
      );

      expect(validateScheduledText('  '), '메시지를 입력하세요.');
      expect(validateScheduledText('😀' * 5000), isNull); // 이모지 한 덩어리 = 1자
      expect(validateScheduledText('가' * 5001), '메시지는 5000자 이내로 입력하세요.');
      expect(validateScheduledTitle(null, isBoard: false), isNull);
      expect(validateScheduledTitle(' ', isBoard: true), '제목을 입력하세요.');
      expect(
        validateScheduledTitle('가' * 51, isBoard: true),
        '제목은 50자 이내로 입력하세요.',
      );
      expect(validateScheduledAttachmentCount(10), isNull);
      expect(validateScheduledAttachmentCount(11), '첨부 파일은 10개까지 올릴 수 있습니다.');
    });

    test('예약 목록 순서와 발송 시각 표기', () {
      final early = ScheduledMessage.fromJson(
        _scheduledJson('a', sendAt: DateTime(2026, 10, 1, 9)),
      );
      final late = ScheduledMessage.fromJson(
        _scheduledJson('b', sendAt: DateTime(2026, 10, 3, 9)),
      );
      final failed = ScheduledMessage.fromJson(
        _scheduledJson('c', sendAt: DateTime(2026, 10, 9, 9), status: 'failed'),
      );
      expect(
        ([
          late,
          failed,
          early,
        ]..sort(compareScheduledMessages)).map((m) => m.id),
        ['c', 'a', 'b'],
      );

      final now = DateTime(2026, 9, 30);
      expect(
        formatScheduleTime(DateTime(2026, 10, 2, 9), now: now),
        '10월 2일 (금) 오전 9:00',
      );
      expect(
        formatScheduleTime(DateTime(2027, 1, 4, 12, 30), now: now),
        '2027년 1월 4일 (월) 오후 12:30',
      );
      expect(formatScheduleClock(DateTime(2026, 1, 1, 0, 15)), '오전 12:15');
      expect(formatScheduleClock(DateTime(2026, 1, 1, 13, 45)), '오후 1:45');
    });
  });

  group('Session — 그룹채팅·나와의 대화', () {
    test('새 그룹채팅: 이름·설명을 다듬어 보내고 비어 있으면 뺀다', () async {
      final server = _FakeServer();
      server.routes['POST /api/rooms'] = (r) => _json(
        _roomJson(
          'g9',
          type: 'group',
          name: _body(r)['name'] as String?,
          extra: {'description': _body(r)['description']},
        ),
        201,
      );
      final session = _buildSession(server);

      final room = await session.createGroup(
        name: ' 점심 메뉴 ',
        description: ' 오늘 뭐 먹지 ',
        memberIds: ['u2', 'u3'],
        iconType: 'members',
      );
      expect(_body(server.called('POST', '/api/rooms').single), {
        'teamId': 't1',
        'type': 'group',
        'name': '점심 메뉴',
        'description': '오늘 뭐 먹지',
        'memberIds': ['u2', 'u3'],
      });
      expect(room.description, '오늘 뭐 먹지');
      expect(session.roomById('g9'), same(room));

      await session.createGroup(memberIds: ['u2'], description: '   ');
      expect(_body(server.called('POST', '/api/rooms').last), {
        'teamId': 't1',
        'type': 'group',
        'memberIds': ['u2'],
      });
    });

    test('채팅 정보 변경: 준 값만 보내고, 결과는 화면이 들고 있던 그 방 객체에 반영된다', () async {
      final server = _FakeServer();
      server.routes['PATCH /api/rooms/g1'] = (r) => _json(
        _roomJson(
          'g1',
          type: 'group',
          name: '새 이름',
          extra: {
            'description': '새 설명',
            'iconType': 'emoji',
            'iconEmoji': '🎉',
            'iconColor': '#FAB005',
          },
        ),
      );
      final session = _buildSession(server);
      final held = Room.fromJson(_roomJson('g1', type: 'group', name: '점심'))
        ..unreadCount = 2
        ..customName = '밥 친구들';
      session.rooms.add(held);

      final updated = await session.updateGroupInfo(
        held,
        name: ' 새 이름 ',
        description: '새 설명',
        iconType: 'emoji',
        iconEmoji: '🎉',
        iconColor: '#FAB005',
      );
      expect(identical(updated, held), isTrue);
      expect(_body(server.called('PATCH', '/api/rooms/g1').single), {
        'name': '새 이름',
        'description': '새 설명',
        'iconType': 'emoji',
        'iconEmoji': '🎉',
        'iconColor': '#FAB005',
      });
      expect(held.name, '새 이름');
      expect(held.description, '새 설명');
      expect(held.iconType, 'emoji');
      expect(held.iconEmoji, '🎉');
      expect(held.unreadCount, 2); // 내 기준 값은 그대로
      expect(held.customName, '밥 친구들');
      expect(session.rooms, hasLength(1));

      // 이름·설명 지우기는 빈 문자열로, 아이콘 지우기는 'members'로 보낸다.
      await session.updateGroupInfo(held, name: '', description: '');
      expect(_body(server.called('PATCH', '/api/rooms/g1').last), {
        'name': '',
        'description': '',
      });
      await session.updateGroupInfo(held, iconType: 'members');
      expect(_body(server.called('PATCH', '/api/rooms/g1').last), {
        'iconType': 'members',
      });
    });

    test('채팅 정보 변경 권한 — 그룹 멤버인 정회원 이상만', () {
      final member = _buildSession(_FakeServer());
      final guest = _buildSession(_FakeServer(), role: AccountRole.guest);
      final group = Room.fromJson(_roomJson('g1', type: 'group'));
      final notMine = Room.fromJson(
        _roomJson('g2', type: 'group', members: [_user('u2', '김철수')]),
      );
      expect(group.canEditGroupInfo(member), isTrue);
      expect(group.canEditGroupInfo(guest), isFalse);
      expect(notMine.canEditGroupInfo(member), isFalse);
      expect(Room.fromJson(_roomJson('t1')).canEditGroupInfo(member), isFalse);
      expect(groupInfoGuestNotice, '준회원은 채팅 정보를 바꿀 수 없습니다.');
    });

    test('나와의 대화: 목록에 없으면 받아서 넣고(요청은 한 번), 있으면 바로 돌려준다', () async {
      final server = _FakeServer();
      final gate = Completer<void>();
      server.routes['POST /api/rooms/self'] = (r) async {
        await gate.future;
        return _json(_selfRoomJson(teamId: _body(r)['teamId'] as String));
      };
      final session = _buildSession(server);
      // 다른 팀의 나와의 대화는 지금 팀 것이 아니다.
      session.rooms.add(Room.fromJson(_selfRoomJson(teamId: 't2')));
      expect(session.selfRoom, isNull);

      final first = session.openSelfChat();
      final second = session.openSelfChat();
      gate.complete();
      final a = await first;
      final b = await second;
      expect(a, same(b));
      expect(server.called('POST', '/api/rooms/self'), hasLength(1));
      expect(_body(server.called('POST', '/api/rooms/self').single), {
        'teamId': 't1',
      });
      expect(a.isSelf, isTrue);
      expect(a.displayName('me'), '나와의 대화');
      expect(session.selfRoom, same(a));
      expect(session.roomById('self-t1'), same(a));

      // 이제 목록에 있으니 서버에 다시 묻지 않는다.
      expect(await session.openSelfChat(), same(a));
      expect(server.called('POST', '/api/rooms/self'), hasLength(1));

      // 팀을 바꾸면 그 팀의 나와의 대화를 본다.
      session.enterTeam(Team(id: 't2', name: '개발팀', createdAt: DateTime(2026)));
      expect(session.selfRoom?.id, 'self-t2');
    });

    test('나와의 대화에 온 봇 안내는 알림 제목에 방 이름으로 나온다', () async {
      final notifications = _FakeNotifications();
      final session = _buildSession(
        _FakeServer(),
        notifications: notifications,
      );
      final self = Room.fromJson(_selfRoomJson());
      session.rooms.add(self);

      await session.handleSocketMessage(
        Message.fromJson({
          'id': 'bot1',
          'roomId': 'self-t1',
          'senderId': null,
          'senderName': '탱고톡',
          'type': 'text',
          'text': '김철수 님이 영업팀 팀에 참여했습니다.',
          'createdAt': 9000,
        }),
      );
      expect(notifications.shown.single['title'], '탱고톡 [나와의 대화] [영업팀]');
      expect(self.unreadCount, 1);
    });
  });

  group('Session — 메시지 예약', () {
    test(
      '불러오기 — 지금 팀 것을 순서대로, 팀을 바꾸면 비우고 새 팀 것을 받는다(늦은 옛 팀 응답은 버린다)',
      () async {
        final server = _FakeServer();
        final slowTeam1 = Completer<void>();
        var holdTeam1 = false;
        server.routes['GET /api/scheduled-messages'] = (r) async {
          final teamId = r.url.queryParameters['teamId'];
          if (teamId == 't1') {
            if (holdTeam1) await slowTeam1.future;
            return _json([
              _scheduledJson('a', sendAt: _later),
              _scheduledJson(
                'f',
                sendAt: _later.add(const Duration(days: 1)),
                status: 'failed',
                failReason: '실패',
              ),
            ]);
          }
          return _json([_scheduledJson('x', teamId: 't2', roomId: 'r9')]);
        };
        final session = _buildSession(server);
        final team1 = session.currentTeam!;
        final team2 = Team(id: 't2', name: '개발팀', createdAt: DateTime(2026));
        session.teams.add(team2);
        session.currentTeam = null;
        expect(session.scheduledMessagesLoaded, isFalse);

        session.enterTeam(team1);
        await pumpEventQueue();
        expect(session.scheduledMessages.map((m) => m.id), ['f', 'a']);
        expect(session.scheduledMessagesLoaded, isTrue);

        session.enterTeam(team2);
        expect(session.scheduledMessages, isEmpty); // 바로 비운다
        expect(session.scheduledMessagesLoaded, isFalse);
        await pumpEventQueue();
        expect(session.scheduledMessages.map((m) => m.id), ['x']);

        // 옛 팀 요청이 늦게 도착해도 지금 팀 목록을 덮지 않는다.
        holdTeam1 = true;
        session.enterTeam(team1);
        await pumpEventQueue();
        session.enterTeam(team2);
        slowTeam1.complete();
        await pumpEventQueue();
        expect(session.currentTeam?.id, 't2');
        expect(session.scheduledMessages.map((m) => m.id), ['x']);
        expect(
          server
              .called('GET', '/api/scheduled-messages')
              .map((r) => r.url.queryParameters['teamId']),
          ['t1', 't2', 't1', 't2'],
        );
      },
    );

    test('불러오기 실패는 직접 부르면 알리고, 팀 목록이 없으면 비운다', () async {
      final server = _FakeServer();
      server.routes['GET /api/scheduled-messages'] = (_) =>
          _json({'error': '잠시 후 다시 시도하세요.'}, 500);
      final session = _buildSession(server);
      await expectLater(
        session.loadScheduledMessages(),
        _apiError('잠시 후 다시 시도하세요.'),
      );
      expect(session.scheduledMessagesLoaded, isFalse);
    });

    test('만들기 — 서버 모양으로 보내고 목록에 넣는다(보드가 아니면 제목은 버린다)', () async {
      final server = _FakeServer();
      server.routes['POST /api/scheduled-messages'] = (r) {
        final b = _body(r);
        return _json(
          _scheduledJson(
            's${server.called('POST', '/api/scheduled-messages').length}',
            roomId: b['roomId'] as String,
            title: b['title'] as String?,
            text: b['text'] as String,
            sendAt: DateTime.fromMillisecondsSinceEpoch(b['sendAt'] as int),
          ),
          201,
        );
      };
      final session = _buildSession(server);
      session.rooms
        ..add(Room.fromJson(_roomJson('r1')))
        ..add(
          Room.fromJson(
            _roomJson('board', name: '주간 보고', extra: {'viewMode': 'board'}),
          ),
        );
      final sendAt = _later;
      final created = await session.scheduleMessage(
        roomId: 'r1',
        title: '무시되는 제목',
        text: '  내일 회의 잊지 마세요  ',
        textFormat: const [TextFormatRun(0, 2, Fmt.bold)],
        attachments: [
          UploadedAttachment(
            isImage: false,
            url: '/uploads/memo.txt',
            fileName: 'memo.txt',
            size: 5,
            mimeType: 'text/plain',
          ),
        ],
        sendAt: sendAt,
      );
      expect(_body(server.called('POST', '/api/scheduled-messages').single), {
        'roomId': 'r1',
        'text': '내일 회의 잊지 마세요',
        // 앞뒤 공백을 떼면 서식 위치가 어긋나므로 서식은 버린다(sendPost와 같은 규칙).
        'attachments': [
          {
            'kind': 'file',
            'fileUrl': '/uploads/memo.txt',
            'fileName': 'memo.txt',
            'fileSize': 5,
            'mimeType': 'text/plain',
          },
        ],
        'sendAt': sendAt.millisecondsSinceEpoch,
      });
      expect(created.id, 's1');
      expect(session.scheduledMessages.single, same(created));
      expect(session.scheduledCountFor('r1'), 1);

      // 보드 뷰 토픽이면 제목이 게시글 제목으로 간다(서식도 그대로).
      final post = await session.scheduleMessage(
        roomId: 'board',
        title: ' 이번 주 보고 ',
        text: '본문',
        textFormat: const [TextFormatRun(0, 2, Fmt.bold)],
        sendAt: sendAt.add(const Duration(minutes: 15)),
      );
      expect(_body(server.called('POST', '/api/scheduled-messages').last), {
        'roomId': 'board',
        'title': '이번 주 보고',
        'text': '본문',
        'textFormat': textFormatToJson(const [TextFormatRun(0, 2, Fmt.bold)]),
        'sendAt': sendAt
            .add(const Duration(minutes: 15))
            .millisecondsSinceEpoch,
      });
      expect(post.isPost, isTrue);
      expect(session.scheduledMessages.map((m) => m.id), ['s1', 's2']);
    });

    test('만들기 — 서버와 같은 규칙으로 먼저 걸러서 요청 없이 알린다', () async {
      final server = _FakeServer();
      final session = _buildSession(server);
      session.rooms
        ..add(Room.fromJson(_roomJson('r1')))
        ..add(
          Room.fromJson(
            _roomJson('board', name: '주간 보고', extra: {'viewMode': 'board'}),
          ),
        )
        ..add(
          Room.fromJson(
            _roomJson(
              'secret',
              type: 'dm',
              name: null,
              extra: {'isSecret': true},
            ),
          ),
        );
      final now = DateTime.now();
      Future<ScheduledMessage> schedule({
        String roomId = 'r1',
        String? title,
        String text = '메시지',
        int attachments = 0,
        DateTime? sendAt,
      }) => session.scheduleMessage(
        roomId: roomId,
        title: title,
        text: text,
        attachments: [
          for (var i = 0; i < attachments; i++)
            UploadedAttachment(
              isImage: false,
              url: '/uploads/$i',
              fileName: '$i.txt',
              size: 1,
            ),
        ],
        sendAt: sendAt ?? _later,
      );

      await expectLater(schedule(text: '   '), _apiError('메시지를 입력하세요.'));
      await expectLater(
        schedule(roomId: 'board', title: ' '),
        _apiError('제목을 입력하세요.'),
      );
      await expectLater(
        schedule(roomId: 'secret'),
        _apiError('비밀 대화에는 예약할 수 없습니다.'),
      );
      await expectLater(
        schedule(attachments: 11),
        _apiError('첨부 파일은 10개까지 올릴 수 있습니다.'),
      );
      await expectLater(
        schedule(sendAt: _later.add(const Duration(minutes: 7))),
        _apiError('발송 시간은 15분 단위로 선택하세요.'),
      );
      await expectLater(
        schedule(
          sendAt: ceilToScheduleSlot(now).subtract(const Duration(hours: 1)),
        ),
        _apiError('발송 시간은 지금 이후로 선택하세요.'),
      );
      await expectLater(
        schedule(sendAt: ceilToScheduleSlot(now.add(const Duration(days: 91)))),
        _apiError('최대 90일 뒤까지만 예약할 수 있습니다.'),
      );
      expect(server.called('POST', '/api/scheduled-messages'), isEmpty);

      // 이미 30건이면(목록을 받아 둔 경우) 더 만들지 않는다.
      server.routes['GET /api/scheduled-messages'] = (_) => _json([
        for (var i = 0; i < 30; i++)
          _scheduledJson('s$i', sendAt: _later.add(Duration(minutes: 15 * i))),
      ]);
      await session.loadScheduledMessages();
      await expectLater(schedule(), _apiError('예약 메시지는 최대 30건까지 만들 수 있습니다.'));
      expect(server.called('POST', '/api/scheduled-messages'), isEmpty);
    });

    test('고치기 — 준 값만 보내고(글을 바꾸면 서식도 같이), 결과로 목록을 갈아 끼운다', () async {
      final server = _FakeServer();
      server.routes['GET /api/scheduled-messages'] = (_) => _json([
        _scheduledJson(
          'post',
          roomId: 'board',
          roomName: '주간 보고',
          title: '주간 보고',
          status: 'failed',
          failReason: '토픽이 보관되어 보낼 수 없습니다.',
        ),
        _scheduledJson('chat', sendAt: _later.add(const Duration(hours: 1))),
      ]);
      server.routes['PATCH /api/scheduled-messages/post'] = (r) {
        final b = _body(r);
        return _json(
          _scheduledJson(
            'post',
            roomId: b['roomId'] as String? ?? 'board',
            title: (b['title'] as String?)?.isEmpty == true ? null : '주간 보고',
            text: b['text'] as String? ?? '예약한 메시지',
            sendAt: b['sendAt'] == null
                ? _later
                : DateTime.fromMillisecondsSinceEpoch(b['sendAt'] as int),
          ),
        );
      };
      server.routes['PATCH /api/scheduled-messages/chat'] = (r) =>
          _json(_scheduledJson('chat', teamId: 't2', roomId: 'other-team'));
      final session = _buildSession(server);
      session.rooms
        ..add(Room.fromJson(_roomJson('r1')))
        ..add(
          Room.fromJson(
            _roomJson('board', name: '주간 보고', extra: {'viewMode': 'board'}),
          ),
        );
      await session.loadScheduledMessages();
      expect(session.scheduledMessageById('post')!.isFailed, isTrue);

      // 발송 시각만 바꾸면 그것만 보내고, 발송 실패가 다시 '예약됨'이 된다.
      final newTime = _later.add(const Duration(days: 1));
      final retried = await session.updateScheduledMessage(
        'post',
        sendAt: newTime,
      );
      expect(
        _body(server.called('PATCH', '/api/scheduled-messages/post').last),
        {'sendAt': newTime.millisecondsSinceEpoch},
      );
      expect(retried.isScheduled, isTrue);
      expect(retried.failReason, isNull);
      expect(session.scheduledMessageById('post'), same(retried));
      expect(session.scheduledMessages.map((m) => m.id), ['chat', 'post']);

      // 글을 바꾸면 서식·멘션도 늘 같이 간다(없으면 null·빈 목록으로 지운다).
      await session.updateScheduledMessage('post', text: ' 새 본문 ');
      expect(
        _body(server.called('PATCH', '/api/scheduled-messages/post').last),
        {'text': '새 본문', 'textFormat': null, 'mentions': <Object>[]},
      );

      // 게시글 예약을 채팅 토픽으로 옮기면 제목은 알아서 지운다.
      final moved = await session.updateScheduledMessage('post', roomId: 'r1');
      expect(
        _body(server.called('PATCH', '/api/scheduled-messages/post').last),
        {'roomId': 'r1', 'title': ''},
      );
      expect(moved.isPost, isFalse);

      // 보드 뷰 토픽으로 옮기는데 제목이 없으면 보내기 전에 막는다.
      final patches = server.called('PATCH', '/api/scheduled-messages/post');
      await expectLater(
        session.updateScheduledMessage('post', roomId: 'board'),
        _apiError('제목을 입력하세요.'),
      );
      expect(
        server.called('PATCH', '/api/scheduled-messages/post'),
        hasLength(patches.length),
      );

      // 다른 팀 대화방으로 옮겨지면 이 팀 목록에서 빠진다.
      await session.updateScheduledMessage('chat', roomId: 'other-team');
      expect(session.scheduledMessageById('chat'), isNull);
    });

    test('예약 취소 — 바로 빼고, 서버가 거절하면 되돌리고 예외를 다시 던진다', () async {
      final server = _FakeServer();
      server.routes['GET /api/scheduled-messages'] = (_) => _json([
        _scheduledJson('a'),
        _scheduledJson('b', sendAt: _later.add(const Duration(hours: 1))),
      ]);
      final gate = Completer<void>();
      server.routes['DELETE /api/scheduled-messages/a'] = (_) async {
        await gate.future;
        return _json({'ok': true});
      };
      server.routes['DELETE /api/scheduled-messages/b'] = (_) =>
          _json({'error': '이미 보내는 중이라 취소할 수 없습니다.'}, 409);
      final session = _buildSession(server);
      await session.loadScheduledMessages();

      final cancelling = session.cancelScheduledMessage('a');
      expect(session.scheduledMessageById('a'), isNull); // 응답 전부터
      // 그 사이 온 변경 알림(내 조작의 에코)은 조작이 끝난 뒤로 미룬다.
      session.handleScheduledChanged('t1');
      await pumpEventQueue();
      expect(server.called('GET', '/api/scheduled-messages'), hasLength(1));
      server.routes['GET /api/scheduled-messages'] = (_) => _json([
        _scheduledJson('b', sendAt: _later.add(const Duration(hours: 1))),
      ]);
      gate.complete();
      await cancelling;
      await pumpEventQueue();
      expect(server.called('GET', '/api/scheduled-messages'), hasLength(2));
      expect(session.scheduledMessages.map((m) => m.id), ['b']);

      await expectLater(
        session.cancelScheduledMessage('b'),
        _apiError('이미 보내는 중이라 취소할 수 없습니다.'),
      );
      expect(session.scheduledMessages.map((m) => m.id), ['b']);
      await pumpEventQueue();
      expect(server.called('GET', '/api/scheduled-messages'), hasLength(3));
    });

    test('지금 보내기 — 보내는 동안 "보내는 중", 보내지면 빼고 발송 알림을 한 번만 흘린다', () async {
      final server = _FakeServer();
      late Session session;
      server.routes['GET /api/scheduled-messages'] = (_) => _json([
        _scheduledJson('a', roomName: '옛 이름'),
        _scheduledJson('b', sendAt: _later.add(const Duration(hours: 1))),
      ]);
      server.routes['POST /api/scheduled-messages/a/send-now'] = (_) {
        expect(session.scheduledMessageById('a')!.isSending, isTrue);
        // 서버가 응답 전에 scheduled:sent도 보낸 경우 — 알림은 한 번만.
        session.handleScheduledMessageEvent(
          ScheduledMessageEvent.fromSentJson({
            'id': 'a',
            'teamId': 't1',
            'roomId': 'r1',
            'roomName': '옛 이름',
            'messageIds': ['m1'],
          }),
        );
        return _json({
          'ok': true,
          'messageIds': ['m1'],
        });
      };
      server.routes['POST /api/scheduled-messages/b/send-now'] = (_) => _json({
        'ok': true,
        'messageIds': ['m2', 'm3'],
      });
      session = _buildSession(server);
      session.rooms.add(Room.fromJson(_roomJson('r1', name: '공지방')));
      final events = <ScheduledMessageEvent>[];
      final sub = session.scheduledMessageEvents.listen(events.add);
      await session.loadScheduledMessages();

      expect(await session.sendScheduledMessageNow('a'), ['m1']);
      expect(session.scheduledMessageById('a'), isNull);
      await pumpEventQueue();
      expect(events, hasLength(1));
      expect(events.single.isSent, isTrue);
      expect(events.single.toastText, '예약 메시지를 보냈습니다 · 공지방'); // 지금 이름

      // 서버 알림이 응답 뒤에 와도 한 번만.
      expect(await session.sendScheduledMessageNow('b'), ['m2', 'm3']);
      session.handleScheduledMessageEvent(
        ScheduledMessageEvent.fromSentJson({'id': 'b', 'teamId': 't1'}),
      );
      await pumpEventQueue();
      expect(events, hasLength(2));
      expect(events.last.messageIds, ['m2', 'm3']);
      expect(session.scheduledMessages, isEmpty);
      await sub.cancel();
    });

    test('지금 보내기 실패 — 되돌리고 서버 상태(발송 실패)를 다시 받으며, 알림 대신 예외로 알린다', () async {
      final server = _FakeServer();
      late Session session;
      var failedOnServer = false;
      server.routes['GET /api/scheduled-messages'] = (_) => _json([
        _scheduledJson(
          'a',
          status: failedOnServer ? 'failed' : 'scheduled',
          failReason: failedOnServer ? '대화방의 멤버가 아니어서 보내지 못했습니다.' : null,
        ),
      ]);
      server.routes['POST /api/scheduled-messages/a/send-now'] = (_) {
        failedOnServer = true;
        return _json({'error': '대화방의 멤버가 아니어서 보내지 못했습니다.'}, 400);
      };
      session = _buildSession(server);
      session.rooms.add(Room.fromJson(_roomJson('r1')));
      final events = <ScheduledMessageEvent>[];
      final sub = session.scheduledMessageEvents.listen(events.add);
      await session.loadScheduledMessages();

      await expectLater(
        session.sendScheduledMessageNow('a'),
        _apiError('대화방의 멤버가 아니어서 보내지 못했습니다.'),
      );
      // 바로 되돌리고(보내는 중이 아님), 서버 상태를 다시 받아 '발송 실패'가 된다.
      expect(session.scheduledMessageById('a')!.isSending, isFalse);
      await pumpEventQueue();
      final failed = session.scheduledMessageById('a')!;
      expect(failed.isFailed, isTrue);
      expect(failed.failReason, '대화방의 멤버가 아니어서 보내지 못했습니다.');
      expect(server.called('GET', '/api/scheduled-messages'), hasLength(2));

      // 서버가 같은 실패를 소켓으로 또 알려도 토스트는 띄우지 않는다(부른 화면이 이미 알렸다).
      session.handleScheduledMessageEvent(
        ScheduledMessageEvent.fromFailedJson({
          'id': 'a',
          'teamId': 't1',
          'reason': '대화방의 멤버가 아니어서 보내지 못했습니다.',
        }),
      );
      await pumpEventQueue();
      expect(events, isEmpty);
      await sub.cancel();
    });

    test('소켓 이벤트 — 발송·실패가 목록을 맞추고 알림으로 흐르며, 변경 알림은 지금 팀만 다시 받는다', () async {
      final server = _FakeServer();
      server.routes['GET /api/scheduled-messages'] = (_) => _json([
        _scheduledJson('a', roomId: 'r1', roomName: '공지방'),
        _scheduledJson(
          'b',
          roomId: 'dm1',
          roomName: '김철수',
          sendAt: _later.add(const Duration(hours: 1)),
        ),
        _scheduledJson(
          'c',
          roomId: 'self-t1',
          roomName: '나와의 대화',
          sendAt: _later.add(const Duration(hours: 2)),
        ),
      ]);
      final session = _buildSession(server);
      session.rooms
        ..add(Room.fromJson(_roomJson('r1', name: '공지방')))
        ..add(
          Room.fromJson(
            _roomJson(
              'dm1',
              type: 'dm',
              name: null,
              members: [_user('me', '나'), _user('u2', '김철수')],
            ),
          )..customName = '철수 선배',
        )
        ..add(Room.fromJson(_selfRoomJson()));
      // 실제 앱처럼 소켓 스트림 → Session 처리로 잇는다(_enterApp과 같은 연결).
      final subs = [
        session.chatSocket.scheduledMessageEvents.listen(
          session.handleScheduledMessageEvent,
        ),
        session.chatSocket.scheduledChanged.listen(
          session.handleScheduledChanged,
        ),
      ];
      final events = <ScheduledMessageEvent>[];
      final sub = session.scheduledMessageEvents.listen(events.add);
      await session.loadScheduledMessages();
      expect(session.scheduledCountFor('dm1'), 1);

      session.chatSocket.debugReceiveScheduledEvent('scheduled:sent', {
        'id': 'a',
        'teamId': 't1',
        'roomId': 'r1',
        'roomName': '공지방',
        'messageIds': ['m1'],
      });
      session.chatSocket.debugReceiveScheduledEvent('scheduled:failed', {
        'id': 'b',
        'teamId': 't1',
        'roomId': 'dm1',
        'roomName': '김철수',
        'reason': '대화방의 멤버가 아니어서 보내지 못했습니다.',
      });
      await pumpEventQueue();
      expect(session.scheduledMessageById('a'), isNull);
      final failed = session.scheduledMessageById('b')!;
      expect(failed.isFailed, isTrue);
      expect(failed.failReason, '대화방의 멤버가 아니어서 보내지 못했습니다.');
      // 발송 실패가 목록 맨 위로 온다.
      expect(session.scheduledMessages.map((m) => m.id), ['b', 'c']);
      expect(session.scheduledCountFor('dm1'), 0);
      expect(session.scheduledCountFor('dm1', includeFailed: true), 1);
      expect(events.map((e) => e.toastText), [
        '예약 메시지를 보냈습니다 · 공지방',
        // 1:1은 내 목록에 보이는 이름(나에게만 바꾼 이름 포함)으로 알린다.
        '예약 메시지를 보내지 못했습니다 (철수 선배): 대화방의 멤버가 아니어서 보내지 못했습니다.',
      ]);

      // 다른 팀 예약의 발송 결과도 알림은 흐른다(그 팀 목록은 여기 없다).
      session.chatSocket.debugReceiveScheduledEvent('scheduled:sent', {
        'id': 'z',
        'teamId': 't2',
        'roomId': 'r9',
        'roomName': '개발 공지',
      });
      await pumpEventQueue();
      expect(events.last.teamId, 't2');
      expect(events.last.toastText, '예약 메시지를 보냈습니다 · 개발 공지');

      final gets = server.called('GET', '/api/scheduled-messages').length;
      session.chatSocket.debugReceiveScheduledEvent('scheduled:changed', {
        'teamId': 't2',
      });
      await pumpEventQueue();
      expect(server.called('GET', '/api/scheduled-messages'), hasLength(gets));
      session.chatSocket.debugReceiveScheduledEvent('scheduled:changed', {
        'teamId': 't1',
      });
      await pumpEventQueue();
      expect(
        server.called('GET', '/api/scheduled-messages'),
        hasLength(gets + 1),
      );
      for (final s in subs) {
        await s.cancel();
      }
      await sub.cancel();
    });

    test('방 이름·방별 목록 — 내 목록의 지금 이름, 없으면 예약할 때 이름', () async {
      final server = _FakeServer();
      server.routes['GET /api/scheduled-messages'] = (_) => _json([
        _scheduledJson('self', roomId: 'self-t1', roomName: null),
        _scheduledJson(
          'gone',
          roomId: null,
          roomName: '없어진 방',
          sendAt: _later.add(const Duration(hours: 1)),
        ),
        _scheduledJson(
          'unknown',
          roomId: 'r404',
          roomName: null,
          sendAt: _later.add(const Duration(hours: 2)),
        ),
        _scheduledJson(
          'self2',
          roomId: 'self-t1',
          roomName: '나와의 대화',
          sendAt: _later.add(const Duration(hours: 3)),
        ),
      ]);
      final session = _buildSession(server);
      session.rooms.add(Room.fromJson(_selfRoomJson()));
      await session.loadScheduledMessages();
      String nameOf(String id) =>
          session.scheduledRoomName(session.scheduledMessageById(id)!);
      expect(nameOf('self'), '나와의 대화');
      expect(nameOf('gone'), '없어진 방');
      expect(nameOf('unknown'), '대화방');
      expect(session.scheduledMessagesFor('self-t1').map((m) => m.id), [
        'self',
        'self2',
      ]);
      expect(session.scheduledCountFor('self-t1'), 2);
    });

    test('재연결하면 예약 목록도 다시 받는다', () async {
      final server = _FakeServer();
      server.routes['GET /api/teams'] = (_) => _json([
        {'id': 't1', 'name': '영업팀', 'createdAt': 0},
      ]);
      server.routes['GET /api/scheduled-messages'] = (_) =>
          _json([_scheduledJson('a')]);
      final session = _buildSession(server);
      expect(session.scheduledMessages, isEmpty);

      await session.resyncAfterReconnect();
      await pumpEventQueue();
      expect(session.scheduledMessages.map((m) => m.id), ['a']);
    });

    test('ApiClient — 방별 목록 조회는 roomId를 같이 보낸다', () async {
      final server = _FakeServer();
      server.routes['GET /api/scheduled-messages'] = (_) =>
          _json([_scheduledJson('a')]);
      final api = ApiClient(
        baseUrl: 'https://test.local',
        token: 't',
        httpClient: server.client,
      );
      final list = await api.fetchScheduledMessages('t 1', roomId: 'r1');
      expect(list.single.id, 'a');
      expect(server.requests.single.url.queryParameters, {
        'teamId': 't 1',
        'roomId': 'r1',
      });
      expect(await api.sendScheduledMessageNow('missing'), isEmpty);
    });
  });

  group('방과 무관한 업로드', () {
    late Directory temp;
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

    setUp(() {
      temp = Directory.systemTemp.createTempSync('chat_upgrade_foundation_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, (call) async => temp.path);
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null);
      temp.deleteSync(recursive: true);
    });

    test('uploadAttachments — 파일은 그대로, 사진은 썸네일까지 업로드 경로로 올린다', () async {
      final server = _FakeServer();
      final uploads = <String>[];
      server.routes['POST /api/upload'] = (r) {
        final n = uploads.length + 1;
        // multipart 본문에서 올린 파일 이름을 꺼낸다(썸네일은 임시 파일 이름). 사진 바이트가 섞여
        // 있어 UTF-8로는 못 읽으니 latin1로 읽는다.
        final name = RegExp(
          r'filename="([^"]+)"',
        ).firstMatch(latin1.decode(r.bodyBytes))![1]!;
        uploads.add(name);
        return _json({
          'url': '/uploads/$n-$name',
          'fileName': name,
          'size': 5,
          'mimeType': name.endsWith('.png') ? 'image/png' : 'text/plain',
        });
      };
      final session = _buildSession(server);
      final memo = File('${temp.path}${Platform.pathSeparator}memo.txt')
        ..writeAsStringSync('hello');
      final photo = File('${temp.path}${Platform.pathSeparator}photo.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 40, height: 30)));

      final progress = <int>{};
      final uploaded = await session.uploadAttachments([
        XFile(memo.path),
        XFile(photo.path),
      ], onProgress: (index, sent, total) => progress.add(index));
      expect(uploaded, hasLength(2));
      expect(uploaded[0].isImage, isFalse);
      expect(uploaded[0].url, '/uploads/1-memo.txt');
      expect(uploaded[0].thumbnailUrl, isNull);
      expect(uploaded[1].isImage, isTrue);
      expect(uploaded[1].url, '/uploads/3-photo.png');
      expect(uploaded[1].fileName, 'photo.png');
      // 사진은 채팅 입력칸처럼 축소 썸네일을 먼저 올린다.
      expect(uploaded[1].thumbnailUrl, '/uploads/2-upload.bin');
      expect(uploads, hasLength(3));
      expect(progress, {0, 1});
      // 평문 업로드라 비밀 대화 키는 없다.
      expect(uploaded[1].attachmentKey, isNull);
    });

    test('업로드 취소는 UploadCancelledException으로 알린다', () async {
      final server = _FakeServer();
      // 끊긴 요청은 서버가 거절한다(진짜 서버도 모자란 본문은 올리지 못한다).
      server.routes['POST /api/upload'] = (_) =>
          _json({'error': '파일이 없습니다.'}, 400);
      final api = ApiClient(
        baseUrl: 'https://test.local',
        token: 't',
        httpClient: server.client,
      );
      final file = File('${temp.path}${Platform.pathSeparator}big.txt')
        ..writeAsStringSync('x' * 1000);
      final token = UploadCancelToken()..cancel();
      await expectLater(
        api.uploadFile(XFile(file.path), cancelToken: token),
        throwsA(isA<UploadCancelledException>()),
      );
      // 취소하지 않은 실패는 그대로 알린다.
      await expectLater(
        api.uploadFile(XFile(file.path), cancelToken: UploadCancelToken()),
        _apiError('파일이 없습니다.'),
      );
    });
  });
}
