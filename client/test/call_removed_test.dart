import 'dart:async';
import 'dart:convert';

import 'package:client/models/app_user.dart';
import 'package:client/models/room.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/call_controller.dart';
import 'package:client/services/chat_socket.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:livekit_client/livekit_client.dart' show DisconnectReason;

/// 통화가 이 기기 밖에서 끝났을 때(서버가 내보냄·회의방이 닫힘·다른 기기에서 참여·연결이 아주 끊김)의 안내와 정리,
/// 서버가 call:join을 거절했을 때의 응답 해석, 알림을 끈(뮤트) 방은 전화가 울리지 않는 규칙.

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}

  @override
  Future<void> cancelIncomingCall(String roomId) async {}
}

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

final _me = AppUser(id: 'me', username: 'me', name: '나');

Room _room({bool muted = false}) => Room(
  id: 'r1',
  teamId: 't1',
  type: RoomType.topic,
  name: '영업방',
  members: [_me],
  createdAt: DateTime(2026),
  lastRead: {},
  muted: muted,
);

Session _session({bool muted = false, http.Client? client}) {
  final s = Session(
    notifications: _QuietNotifications(),
    settings: AppSettings(),
  );
  s.userId = 'me';
  s.serverUrl = 'https://test.local';
  s.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: client ?? MockClient((_) async => _json({'ok': true})),
  );
  s.rooms.add(_room(muted: muted));
  return s;
}

/// 소켓 없이 보낸 화상회의 신호를 "이벤트 페이로드(JSON)" 한 줄씩 모은다.
List<String> _recordCallSignals(Session s) {
  final sent = <String>[];
  s.chatSocket.debugCallSignal = (event, payload) =>
      sent.add('$event ${jsonEncode(payload)}');
  return sent;
}

CallState _call(List<String> ids, {int startedAt = 1000}) => CallState(
  roomId: 'r1',
  active: true,
  startedBy: 'a',
  startedAt: DateTime.fromMillisecondsSinceEpoch(startedAt),
  participantIds: ids,
);

void main() {
  group('callDisconnectNotice — 끊긴 이유별 안내', () {
    test('내가 나간 것은 안내하지 않는다', () {
      expect(callDisconnectNotice(DisconnectReason.clientInitiated), isNull);
    });

    test('서버가 내보냄(방에서 내보내짐·팀에서 빠짐·계정 정지 등)', () {
      expect(
        callDisconnectNotice(DisconnectReason.participantRemoved),
        '화상회의에서 내보내졌습니다',
      );
    });

    test('회의방이 닫힘(토픽 삭제)', () {
      expect(
        callDisconnectNotice(DisconnectReason.roomDeleted),
        '화상회의가 종료되었습니다',
      );
    });

    test('같은 계정으로 다른 기기에서 참여', () {
      expect(
        callDisconnectNotice(DisconnectReason.duplicateIdentity),
        contains('다른 기기에서'),
      );
    });

    test('다른 기기로 넘어간 것은 같은 계정이 다른 기기에서 참여했을 때뿐', () {
      expect(
        callDisconnectIsHandoff(DisconnectReason.duplicateIdentity),
        isTrue,
      );
      for (final reason in [
        DisconnectReason.participantRemoved,
        DisconnectReason.roomDeleted,
        DisconnectReason.disconnected,
        DisconnectReason.clientInitiated,
        null,
      ]) {
        expect(callDisconnectIsHandoff(reason), isFalse);
      }
    });

    test('그 밖에는 연결이 끊긴 것(재연결까지 실패)', () {
      for (final reason in [
        DisconnectReason.disconnected,
        DisconnectReason.signalingConnectionFailure,
        DisconnectReason.reconnectAttemptsExceeded,
        DisconnectReason.serverShutdown,
        DisconnectReason.joinFailure,
        DisconnectReason.unknown,
        null,
      ]) {
        expect(callDisconnectNotice(reason), '화상회의 연결이 끊겼습니다');
      }
    });
  });

  group('callJoinRejection — call:join 응답', () {
    test('거절이면 서버 문구', () {
      expect(
        callJoinRejection({
          'ok': false,
          'error': '읽기 전용 토픽에서는 토픽 관리자만 화상회의를 시작할 수 있습니다.',
        }),
        '읽기 전용 토픽에서는 토픽 관리자만 화상회의를 시작할 수 있습니다.',
      );
    });

    test('문구가 없으면 기본 문구', () {
      expect(callJoinRejection({'ok': false}), '화상회의에 참여하지 못했습니다.');
      expect(
        callJoinRejection({'ok': false, 'error': ''}),
        '화상회의에 참여하지 못했습니다.',
      );
    });

    test('받아들였거나 모양을 모르면(예전 서버) 거절이 아니다', () {
      expect(callJoinRejection({'ok': true}), isNull);
      expect(callJoinRejection(null), isNull);
      expect(callJoinRejection('ok'), isNull);
      expect(callJoinRejection(<String, dynamic>{}), isNull);
    });
  });

  group('통화가 밖에서 끝났을 때', () {
    test('안내를 띄우고, 서버에 나갔다고 알리고, 같은 통화가 다시 울리지 않는다', () async {
      final s = _session();
      final signals = _recordCallSignals(s);
      final toasts = <String>[];
      final sub = s.toasts.listen(toasts.add);
      // 통화 중이었다가 연결이 아주 끊겼다 — 서버는 아직 이 통화를 진행 중으로 안다.
      s.debugApplyCallState(_call(['a', 'me']));
      s.debugCallDisconnected('r1', '화상회의 연결이 끊겼습니다');
      await Future<void>.delayed(Duration.zero);
      expect(toasts, ['화상회의 연결이 끊겼습니다']);
      expect(signals, ['call:leave {"roomId":"r1"}']);

      // 남은 사람들끼리 통화가 이어져도(내가 참가자 목록에서 빠짐) 이 통화로 다시 울리지 않는다.
      s.debugApplyCallState(_call(['a']));
      expect(s.incomingCallRoomId, isNull);
      await sub.cancel();
    });

    test('다른 기기로 넘어갔으면 바로 나가지 않고 넘어갔다고 알린다(서버가 새 기기의 참여를 기다린다)', () async {
      final s = _session();
      final signals = _recordCallSignals(s);
      final toasts = <String>[];
      final sub = s.toasts.listen(toasts.add);
      s.debugApplyCallState(_call(['a', 'me']));
      s.debugCallDisconnected(
        'r1',
        callDisconnectNotice(DisconnectReason.duplicateIdentity)!,
        handoff: true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(signals, ['call:leave {"roomId":"r1","handoff":true}']);
      expect(toasts.single, contains('다른 기기에서'));
      // 다른 기기로 계속 통화 중인 그 통화로 이 기기가 울리지 않는다.
      s.debugApplyCallState(_call(['a', 'me']));
      s.debugApplyCallState(_call(['a']));
      expect(s.incomingCallRoomId, isNull);
      await sub.cancel();
    });

    test('이 기기에서 방을 나가는 중이면(서버가 그 방 통화에서도 내보낸다) 안내하지 않는다', () async {
      final response = Completer<http.Response>();
      final s = _session(client: MockClient((_) => response.future));
      final toasts = <String>[];
      final sub = s.toasts.listen(toasts.add);

      final leaving = s.leaveRoom('r1');
      s.debugCallDisconnected('r1', '화상회의에서 내보내졌습니다');
      response.complete(_json({'ok': true}));
      await leaving;
      await Future<void>.delayed(Duration.zero);

      expect(toasts, isEmpty);
      expect(s.rooms.where((r) => r.id == 'r1'), isEmpty);

      // 나가기가 끝난 뒤의 끊김은 다시 안내한다.
      s.debugCallDisconnected('r1', '화상회의에서 내보내졌습니다');
      await Future<void>.delayed(Duration.zero);
      expect(toasts, ['화상회의에서 내보내졌습니다']);
      await sub.cancel();
    });
  });

  group('알림을 끈(뮤트) 방', () {
    test('통화가 시작돼도 울리지 않는다(서버 전화 푸시와 같은 규칙)', () {
      final s = _session(muted: true);
      s.debugApplyCallState(_call(['a']));
      expect(s.incomingCallRoomId, isNull);
      // 진행 중인 통화로는 알고 있어서 통화 버튼이 "참여"로 바뀐다.
      expect(s.callStates['r1']?.active, isTrue);
    });

    test('알림을 켠 방은 그대로 울린다', () {
      final s = _session();
      s.debugApplyCallState(_call(['a']));
      expect(s.incomingCallRoomId, 'r1');
    });
  });

  group('서버가 되살린 통화(서버 재시작 뒤 등)', () {
    test('call:state의 restored를 읽는다 — 없으면(보통 통화·예전 서버) false', () {
      final base = {
        'roomId': 'r1',
        'active': true,
        'startedBy': 'a',
        'startedAt': 1000,
        'participantIds': ['a'],
      };
      expect(CallState.fromJson({...base, 'restored': true}).restored, isTrue);
      expect(CallState.fromJson(base).restored, isFalse);
    });

    test('다시 울리지 않지만, 진행 중인 통화로는 알아서 직접 들어갈 수 있다', () {
      final s = _session();
      s.debugApplyCallState(
        CallState(
          roomId: 'r1',
          active: true,
          startedBy: 'a',
          startedAt: DateTime.fromMillisecondsSinceEpoch(5000),
          participantIds: const ['a'],
          restored: true,
        ),
      );
      expect(s.incomingCallRoomId, isNull);
      expect(s.callStates['r1']?.active, isTrue);
    });
  });
}
