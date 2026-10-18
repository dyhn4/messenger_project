import 'room.dart' show RoomType;
import '../l10n/tr.dart';

/// 초대 결과에 나오는 사람 한 명 — 초대됨/이미 참여중이면 [reason]이 없고, 초대하지 못했으면 사유가 있다.
class InvitePerson {
  final String userId;
  final String name;
  final String? reason;
  const InvitePerson({required this.userId, required this.name, this.reason});

  factory InvitePerson.fromJson(Map<String, dynamic> json) => InvitePerson(
    userId: json['userId'] as String,
    name: (json['name'] as String?) ?? tr('알 수 없음'),
    reason: json['reason'] as String?,
  );
}

/// 대화방 한 곳의 초대 결과 — 서버 POST /api/rooms/invite-bulk의 `results` 한 줄이고, 방 하나짜리 단건 초대도
/// 같은 모양으로 만들어 '초대 완료' 창([showInviteResultDialog])에 넘긴다.
class RoomInviteResult {
  final String roomId;
  final String? roomName;
  final RoomType? roomType;
  final List<InvitePerson> invited;
  final List<InvitePerson> alreadyMembers;
  final List<InvitePerson> failed;

  /// 이 방을 통째로 건너뛴 이유(서버 코드: notMember·wrongTeam·notAllowed·failed) — 없으면 정상 처리.
  final String? error;

  const RoomInviteResult({
    required this.roomId,
    this.roomName,
    this.roomType,
    this.invited = const [],
    this.alreadyMembers = const [],
    this.failed = const [],
    this.error,
  });

  factory RoomInviteResult.fromJson(Map<String, dynamic> json) {
    List<InvitePerson> people(String key) => [
      for (final p in (json[key] as List? ?? const []))
        InvitePerson.fromJson(p as Map<String, dynamic>),
    ];
    return RoomInviteResult(
      roomId: json['roomId'] as String,
      roomName: json['roomName'] as String?,
      roomType: switch (json['roomType']) {
        'topic' => RoomType.topic,
        'group' => RoomType.group,
        'dm' => RoomType.dm,
        _ => null,
      },
      invited: people('invited'),
      alreadyMembers: people('alreadyMembers'),
      failed: people('failed'),
      error: json['error'] as String?,
    );
  }

  /// 이 방에 한 명이라도 새로 초대됐는지(방 전체가 건너뛰어지지 않았고 초대된 사람이 있음).
  bool get hasInvited => error == null && invited.isNotEmpty;

  /// 이 방을 건너뛴 이유를 사람이 읽는 말로.
  String? get errorText => switch (error) {
    null => null,
    'notMember' => tr('내가 참여 중인 대화방이 아니어서 초대하지 못했습니다.'),
    'wrongTeam' => tr('다른 팀의 대화방이라 초대하지 못했습니다.'),
    'notAllowed' => tr('멤버를 초대할 수 없는 대화방입니다.'),
    _ => tr('초대하지 못했습니다. 잠시 후 다시 시도하세요.'),
  };
}
