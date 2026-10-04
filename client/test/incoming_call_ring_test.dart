import 'package:client/services/app_settings.dart';
import 'package:client/services/chat_socket.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter_test/flutter_test.dart';

/// 걸려온 화상회의의 수신 창(Session.incomingCallRoomId) — 이미 응답한(참여했거나 거절한) 통화는 그 통화 중에
/// 누가 들어오고 나가도 다시 울리지 않고, 끝난 뒤 같은 방에서 새로 건 통화는 다시 울린다.

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}

  @override
  Future<void> cancelIncomingCall(String roomId) async {}
}

Session _session() {
  final s = Session(notifications: _QuietNotifications(), settings: AppSettings());
  s.userId = 'me';
  return s;
}

CallState _call(List<String> ids, {int startedAt = 1000, bool active = true}) =>
    CallState(
      roomId: 'r1',
      active: active,
      startedBy: active ? 'a' : null,
      startedAt: active ? DateTime.fromMillisecondsSinceEpoch(startedAt) : null,
      participantIds: ids,
    );

void main() {
  test('누가 걸면 울린다', () {
    final s = _session();
    s.debugApplyCallState(_call(['a']));
    expect(s.incomingCallRoomId, 'r1');
  });

  test('거절한 통화는 그 통화에 누가 들어오고 나가도 다시 울리지 않는다', () {
    final s = _session();
    s.debugApplyCallState(_call(['a']));
    s.declineIncomingCall();
    expect(s.incomingCallRoomId, isNull);
    s.debugApplyCallState(_call(['a', 'b']));
    s.debugApplyCallState(_call(['a']));
    expect(s.incomingCallRoomId, isNull);
  });

  test('참여했다가 나간 통화는 남은 사람이 있어도 다시 울리지 않는다', () {
    final s = _session();
    s.debugApplyCallState(_call(['a']));
    // 참여(다른 기기에서 받은 것도 같다) — 참가자 목록에 내가 들어온다.
    s.debugApplyCallState(_call(['a', 'me']));
    expect(s.incomingCallRoomId, isNull);
    // 나가기 — 통화는 a가 남아 계속된다.
    s.debugApplyCallState(_call(['a']));
    expect(s.incomingCallRoomId, isNull);
  });

  test('통화가 끝난 뒤 같은 방에서 새로 건 통화는 다시 울린다', () {
    final s = _session();
    s.debugApplyCallState(_call(['a']));
    s.declineIncomingCall();
    s.debugApplyCallState(_call([], active: false));
    s.debugApplyCallState(_call(['a'], startedAt: 5000));
    expect(s.incomingCallRoomId, 'r1');
  });
}
