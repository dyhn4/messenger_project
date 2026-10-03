import '../models/message.dart';
import '../models/poll.dart';
import '../models/room.dart';
import '../models/uploaded_attachment.dart';
import 'api_client.dart';
import 'session.dart';

/// 투표 만들기·투표·마감·즐겨찾기와 소켓 이벤트 반영. Session 본체가 이미 커서 새 코드는 확장으로
/// 따로 두고(session.dart가 같이 내보낸다), 목록 갱신은 방 컨트롤러(applyPoll*)에 맡긴다.
extension SessionPolls on Session {
  ApiClient get _pollApi {
    final client = api;
    if (client == null) throw const ApiException('연결되어 있지 않습니다.');
    return client;
  }

  /// 투표를 만든다 — 목록 반영은 서버가 방에 뿌리는 message:new로 이뤄진다(다른 메시지 전송과
  /// 같다). 규칙에 어긋나면(비밀 대화·읽기 전용 토픽 등) 서버 문구 그대로 [ApiException]이 난다.
  Future<Message> createPoll(
    Room room, {
    required String title,
    String? description,
    required List<String> options,
    bool anonymous = false,
    bool multiple = false,
    required DateTime closesAt,
    List<UploadedAttachment> attachments = const [],
  }) {
    final trimmedDescription = description?.trim();
    return _pollApi.createPoll(
      room.id,
      title: title.trim(),
      description: trimmedDescription == null || trimmedDescription.isEmpty
          ? null
          : trimmedDescription,
      options: [
        for (final o in options)
          if (o.trim().isNotEmpty) o.trim(),
      ],
      anonymous: anonymous,
      multiple: multiple,
      closesAt: closesAt,
      attachments: attachments,
    );
  }

  /// 투표하기·다시 투표하기(빈 목록이면 내 표 취소). 응답으로 받은 내 기준 값을 곧바로 목록에 반영한다.
  Future<Poll> votePoll(Poll poll, List<String> optionIds) async {
    final updated = await _pollApi.votePoll(poll.id, optionIds);
    _applyPollResult(updated);
    return updated;
  }

  /// 투표를 일찍 마감한다(만든 사람·관리자).
  Future<Poll> closePoll(Poll poll) async {
    final updated = await _pollApi.closePoll(poll.id);
    _applyPollResult(updated);
    return updated;
  }

  /// 즐겨찾기 켜기/끄기 — 서버가 확정한 값을 목록에 반영하고 돌려준다.
  Future<bool> setPollFavorite(Message message, bool favorite) async {
    final poll = message.poll;
    if (poll == null) return favorite;
    final result = await _pollApi.setPollFavorite(poll.id, favorite);
    for (final room in rooms) {
      existingControllerFor(
        room.id,
      )?.applyPollFavorite(message.id, poll.id, result);
    }
    return result;
  }

  void _applyPollResult(Poll poll) {
    for (final room in rooms) {
      if (existingControllerFor(room.id)?.applyPollResult(poll) ?? false) {
        return;
      }
    }
  }

  /// 소켓 poll:updated — 그 방 컨트롤러가 규약의 받는 쪽 규칙대로 갱신한다. 테스트가 소켓 없이
  /// 같은 경로를 태울 수 있게 밖으로 열어 둔다.
  void handlePollUpdated(PollUpdatedEvent event) {
    existingControllerFor(
      event.roomId,
    )?.applyPollUpdate(event, myUserId: userId);
    pollEvents.emitUpdated(event); // 투표 목록 패널에 있는 사본도 고치게.
  }

  /// 소켓 poll:favorite — 방을 모르는 이벤트라 열려 있는 방 컨트롤러를 모두 훑는다.
  void handlePollFavorite(PollFavoriteEvent event) {
    for (final room in rooms) {
      existingControllerFor(
        room.id,
      )?.applyPollFavorite(event.messageId, event.pollId, event.favorite);
    }
  }
}
