import 'dart:async';

import '../models/message.dart';
import '../models/poll.dart';

/// 투표 소켓 이벤트를 화면(투표 목록 패널)에 나눠 주는 통로. 방 컨트롤러가 가진 투표는 Session이 컨트롤러를 통해 갱신하지만
/// 컨트롤러에 없는 사본(패널이 서버에서 받아 둔 목록)은 이 스트림을 듣고 스스로 고친다. Session이 하나만 갖고 있고
/// (`session.pollEvents`), 소켓 이벤트를 처리하는 곳(poll_actions.dart의 handlePollUpdated, session.dart의
/// handleSocketMessage)이 여기에 흘려 보낸다 — 그래서 소켓 없는 테스트도 같은 경로를 탈 수 있다.
class PollEvents {
  final _updated = StreamController<PollUpdatedEvent>.broadcast();
  final _created = StreamController<Message>.broadcast();

  /// 누가 투표했거나 투표가 마감됐다(poll:updated).
  Stream<PollUpdatedEvent> get updated => _updated.stream;

  /// 방에 새 투표가 올라왔다(message:new, type poll) — 내가 만든 것도 포함한다.
  Stream<Message> get created => _created.stream;

  void emitUpdated(PollUpdatedEvent event) {
    if (!_updated.isClosed) _updated.add(event);
  }

  void emitCreated(Message message) {
    if (!_created.isClosed) _created.add(message);
  }

  void dispose() {
    _updated.close();
    _created.close();
  }
}
