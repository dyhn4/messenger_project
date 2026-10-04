import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:socket_io_client/socket_io_client.dart' as socket_io;

import '../models/album.dart';
import '../models/announcement.dart';
import '../models/app_notification.dart';
import '../models/inquiry.dart';
import '../models/comment.dart';
import '../models/mention.dart';
import '../models/message.dart';
import '../models/poll.dart';
import '../models/room.dart';
import '../models/scheduled_message.dart';
import '../models/team.dart';
import '../models/text_format.dart';
import '../models/todo.dart' show TodoComment;
import 'pinned_tls.dart';

/// room:read 브로드캐스트 한 건. 누가(userId) 언제(lastReadAt) 어느 방(roomId)을 읽었는지.
class RoomReadEvent {
  final String roomId;
  final String userId;
  final int lastReadAt;
  const RoomReadEvent({
    required this.roomId,
    required this.userId,
    required this.lastReadAt,
  });

  factory RoomReadEvent.fromJson(Map<String, dynamic> json) => RoomReadEvent(
    roomId: json['roomId'] as String,
    userId: json['userId'] as String,
    lastReadAt: (json['lastReadAt'] as num).toInt(),
  );
}

/// 내(다른 기기 포함)가 방의 즐겨찾기를 바꿨다는 브로드캐스트(room:favorite).
class RoomFavoriteUpdate {
  final String roomId;
  final bool favorite;
  const RoomFavoriteUpdate({required this.roomId, required this.favorite});

  factory RoomFavoriteUpdate.fromJson(Map<String, dynamic> json) =>
      RoomFavoriteUpdate(
        roomId: json['roomId'] as String,
        favorite: json['favorite'] as bool,
      );
}

/// 내(다른 기기 포함)가 방의 알림 끄기를 바꿨다는 브로드캐스트(room:muted).
class RoomMutedUpdate {
  final String roomId;
  final bool muted;
  const RoomMutedUpdate({required this.roomId, required this.muted});

  factory RoomMutedUpdate.fromJson(Map<String, dynamic> json) =>
      RoomMutedUpdate(
        roomId: json['roomId'] as String,
        muted: json['muted'] as bool,
      );
}

/// 내(다른 기기 포함)가 그룹채팅방 이름을 나에게만 바꿨다는 브로드캐스트(room:renamed).
class RoomRenamedUpdate {
  final String roomId;
  final String? customName;
  const RoomRenamedUpdate({required this.roomId, required this.customName});

  factory RoomRenamedUpdate.fromJson(Map<String, dynamic> json) =>
      RoomRenamedUpdate(
        roomId: json['roomId'] as String,
        customName: json['customName'] as String?,
      );
}

/// 누군가의 부서/직책이 바뀌었다는 알림(org:updated) — 관리자 콘솔("회원" 탭) 또는 팀 설정
/// ("멤버" 탭)에서 바뀌면 온다. 로그아웃 없이 room.members에 캐싱된 값을 바로 덮어쓰는 데 쓴다.
class OrgUpdate {
  final String userId;
  final String? department;
  final String? position;
  const OrgUpdate({required this.userId, this.department, this.position});

  factory OrgUpdate.fromJson(Map<String, dynamic> json) => OrgUpdate(
    userId: json['userId'] as String,
    department: json['department'] as String?,
    position: json['position'] as String?,
  );
}

/// 팀에서 빠졌다는 알림(team:left) — 소유자/관리자가 나를 팀에서 뺐거나, 소유자가 팀 자체를
/// 삭제했을 때([deleted]가 true). 어느 쪽이든 클라이언트가 하는 일은 같지만(팀+방 정리),
/// 사용자에게 보여주는 안내 문구가 다르다.
class TeamLeftEvent {
  final String teamId;
  final String? teamName;
  final bool deleted;
  const TeamLeftEvent({
    required this.teamId,
    this.teamName,
    this.deleted = false,
  });

  factory TeamLeftEvent.fromJson(Map<String, dynamic> json) => TeamLeftEvent(
    teamId: json['teamId'] as String,
    teamName: json['teamName'] as String?,
    deleted: json['deleted'] as bool? ?? false,
  );
}

/// 평문 DM의 숨기기 상태가 바뀌었다는 브로드캐스트(room:hidden) — 내가(다른 기기 포함)
/// 직접 숨기기/나가기를 했을 때뿐 아니라, 상대가 새 메시지를 보내 서버가 자동으로 다시
/// 보이게(hidden: false) 되돌렸을 때도 온다(room_options_menu.dart 참고).
class RoomHiddenUpdate {
  final String roomId;
  final bool hidden;
  const RoomHiddenUpdate({required this.roomId, required this.hidden});

  factory RoomHiddenUpdate.fromJson(Map<String, dynamic> json) =>
      RoomHiddenUpdate(
        roomId: json['roomId'] as String,
        hidden: json['hidden'] as bool,
      );
}

/// 누군가 메시지를 삭제했다는 브로드캐스트(message:deleted). 내용은 이미 클라이언트에서
/// 가려질 거라 최소 정보만 온다.
class MessageDeletedEvent {
  final String id;
  final String roomId;
  const MessageDeletedEvent({required this.id, required this.roomId});

  factory MessageDeletedEvent.fromJson(Map<String, dynamic> json) =>
      MessageDeletedEvent(
        id: json['id'] as String,
        roomId: json['roomId'] as String,
      );
}

/// 누군가 댓글을 삭제했다는 브로드캐스트(comment:deleted). 내용은 이미 클라이언트에서
/// 가려질 거라 최소 정보만 온다.
class CommentDeletedEvent {
  final String id;
  final String messageId;
  final String roomId;
  const CommentDeletedEvent({
    required this.id,
    required this.messageId,
    required this.roomId,
  });

  factory CommentDeletedEvent.fromJson(Map<String, dynamic> json) =>
      CommentDeletedEvent(
        id: json['id'] as String,
        messageId: json['messageId'] as String,
        roomId: json['roomId'] as String,
      );
}

/// 내(다른 기기 포함)가 공지 목록/상세를 열어서 읽음 처리됐다는 브로드캐스트(announcement:read)
/// — user: 방에만 오므로 항상 "나"에 대한 것이다(room:read와 달리 userId가 없다).
class AnnouncementReadEvent {
  final String roomId;
  final int lastReadAt;
  const AnnouncementReadEvent({required this.roomId, required this.lastReadAt});

  factory AnnouncementReadEvent.fromJson(Map<String, dynamic> json) =>
      AnnouncementReadEvent(
        roomId: json['roomId'] as String,
        lastReadAt: (json['lastReadAt'] as num).toInt(),
      );
}

/// 공지가 삭제되거나(announcement:deleted) 내려갔을 때(announcement:unpinned) 오는 최소 정보.
/// 공지·할 일 댓글이 지워졌다는 소식 — [parentId]는 그 공지(또는 할 일)의 id.
typedef SimpleCommentDeleted = ({String id, String parentId, String roomId});

class AnnouncementRemovedEvent {
  final String id;
  final String roomId;
  const AnnouncementRemovedEvent({required this.id, required this.roomId});

  factory AnnouncementRemovedEvent.fromJson(Map<String, dynamic> json) =>
      AnnouncementRemovedEvent(
        id: json['id'] as String,
        roomId: json['roomId'] as String,
      );
}

/// 비밀 대화 초대(secret:invite) — 상대가 나에게 비밀 대화를 걸었다는 신호.
class SecretInviteEvent {
  final String roomId;
  final String initiatorUserId;
  final String initiatorDeviceId;
  final String initiatorEphemeralPublicKey;
  final String initiatorEphemeralSignature;
  const SecretInviteEvent({
    required this.roomId,
    required this.initiatorUserId,
    required this.initiatorDeviceId,
    required this.initiatorEphemeralPublicKey,
    required this.initiatorEphemeralSignature,
  });

  factory SecretInviteEvent.fromJson(
    Map<String, dynamic> json,
  ) => SecretInviteEvent(
    roomId: json['roomId'] as String,
    initiatorUserId: json['initiatorUserId'] as String,
    initiatorDeviceId: json['initiatorDeviceId'] as String,
    initiatorEphemeralPublicKey: json['initiatorEphemeralPublicKey'] as String,
    initiatorEphemeralSignature: json['initiatorEphemeralSignature'] as String,
  );
}

/// 상대가 내 비밀 대화 초대를 수락했다는 브로드캐스트(secret:accepted).
class SecretAcceptedEvent {
  final String roomId;
  final String responderDeviceId;
  final String responderEphemeralPublicKey;
  final String responderEphemeralSignature;
  const SecretAcceptedEvent({
    required this.roomId,
    required this.responderDeviceId,
    required this.responderEphemeralPublicKey,
    required this.responderEphemeralSignature,
  });

  factory SecretAcceptedEvent.fromJson(
    Map<String, dynamic> json,
  ) => SecretAcceptedEvent(
    roomId: json['roomId'] as String,
    responderDeviceId: json['responderDeviceId'] as String,
    responderEphemeralPublicKey: json['responderEphemeralPublicKey'] as String,
    responderEphemeralSignature: json['responderEphemeralSignature'] as String,
  );
}

class SecretRejectedEvent {
  final String roomId;
  const SecretRejectedEvent(this.roomId);
  factory SecretRejectedEvent.fromJson(Map<String, dynamic> json) =>
      SecretRejectedEvent(json['roomId'] as String);
}

/// 나 또는 상대방이 비밀 대화를 나갔다는 브로드캐스트(secret:left) — 서버가 방을 완전히
/// 지웠다는 뜻이라, 둘 중 누가 나갔든 양쪽 다 방을 목록에서 지우고 로컬 키도 잊어야 한다.
class SecretLeftEvent {
  final String roomId;
  const SecretLeftEvent(this.roomId);
  factory SecretLeftEvent.fromJson(Map<String, dynamic> json) =>
      SecretLeftEvent(json['roomId'] as String);
}

/// 자동 삭제 타이머 설정이 바뀌었다는 브로드캐스트(secret:settings).
class SecretSettingsEvent {
  final String roomId;
  final int? selfDestructSeconds;
  const SecretSettingsEvent({required this.roomId, this.selfDestructSeconds});
  factory SecretSettingsEvent.fromJson(Map<String, dynamic> json) =>
      SecretSettingsEvent(
        roomId: json['roomId'] as String,
        selfDestructSeconds: (json['selfDestructSeconds'] as num?)?.toInt(),
      );
}

/// 비밀 대화 메시지를 상대가 읽었다는 브로드캐스트(secret:message-read) — 자동 삭제 카운트다운 시작 신호.
class SecretMessageReadEvent {
  final String roomId;
  final String messageId;
  final int readAt;
  final int? expiresAt;
  const SecretMessageReadEvent({
    required this.roomId,
    required this.messageId,
    required this.readAt,
    this.expiresAt,
  });
  factory SecretMessageReadEvent.fromJson(Map<String, dynamic> json) =>
      SecretMessageReadEvent(
        roomId: json['roomId'] as String,
        messageId: json['messageId'] as String,
        readAt: (json['readAt'] as num).toInt(),
        expiresAt: (json['expiresAt'] as num?)?.toInt(),
      );
}

/// 자동 삭제 타이머가 만료돼 서버가 메시지를 완전히 지웠다는 브로드캐스트(message:expired).
class MessageExpiredEvent {
  final String roomId;
  final String messageId;
  const MessageExpiredEvent({required this.roomId, required this.messageId});
  factory MessageExpiredEvent.fromJson(Map<String, dynamic> json) =>
      MessageExpiredEvent(
        roomId: json['roomId'] as String,
        messageId: json['messageId'] as String,
      );
}

/// 재키잉 제안/수락 중계(secret:rekey-propose / secret:rekey-ack) — 서버는 그대로 전달만 한다.
class SecretRekeyEvent {
  final String roomId;
  final int keyEpoch;
  final String userId; // propose면 proposerUserId, ack면 responderUserId.
  final String ephemeralPublicKey;
  final String ephemeralSignature;
  const SecretRekeyEvent({
    required this.roomId,
    required this.keyEpoch,
    required this.userId,
    required this.ephemeralPublicKey,
    required this.ephemeralSignature,
  });

  factory SecretRekeyEvent.fromProposeJson(Map<String, dynamic> json) =>
      SecretRekeyEvent(
        roomId: json['roomId'] as String,
        keyEpoch: (json['keyEpoch'] as num).toInt(),
        userId: json['proposerUserId'] as String,
        ephemeralPublicKey: json['proposerEphemeralPublicKey'] as String,
        ephemeralSignature: json['proposerEphemeralSignature'] as String,
      );

  factory SecretRekeyEvent.fromAckJson(Map<String, dynamic> json) =>
      SecretRekeyEvent(
        roomId: json['roomId'] as String,
        keyEpoch: (json['keyEpoch'] as num).toInt(),
        userId: json['responderUserId'] as String,
        ephemeralPublicKey: json['responderEphemeralPublicKey'] as String,
        ephemeralSignature: json['responderEphemeralSignature'] as String,
      );
}

/// 한 방의 화상회의 상태 브로드캐스트(call:state) — 서버 calls.js가 통화 참가/퇴장마다
/// 그 방 멤버 전원에게 보낸다. 벨을 울릴지, 통화 화면을 띄울지, "통화 중" 표시를 할지는
/// 클라이언트가 이 상태를 보고 판단한다(참가자 목록에 내가 없으면 아직 안 받은 통화).
class CallState {
  final String roomId;
  final bool active;
  final String? startedBy;
  final DateTime? startedAt;
  final List<String> participantIds;

  /// 진행자 — 참가자 패널에서 다른 사람의 마이크를 켜고 끌 수 있다(예전 서버면 null).
  final String? hostId;

  /// 서버가 정한 영상 화질 단계('fhd'|'hd'|'sd'|'ld' — call_quality.dart, 예전 서버면 null).
  final String? videoTier;

  const CallState({
    required this.roomId,
    required this.active,
    this.startedBy,
    this.startedAt,
    this.participantIds = const [],
    this.hostId,
    this.videoTier,
  });

  factory CallState.fromJson(Map<String, dynamic> json) => CallState(
    roomId: json['roomId'] as String,
    active: json['active'] as bool? ?? false,
    startedBy: json['startedBy'] as String?,
    startedAt: json['startedAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            (json['startedAt'] as num).toInt(),
          ),
    participantIds:
        (json['participantIds'] as List?)?.cast<String>() ?? const [],
    hostId: json['hostId'] as String?,
    videoTier: json['videoTier'] as String?,
  );
}

/// 진행자가 내 마이크를 켜거나 끄라고 했다(call:mic — 서버가 진행자인지 확인한 뒤 내 기기들에만 보낸다).
typedef CallMicRequest = ({String roomId, bool on});

/// 토픽에서 내보내졌거나 토픽이 삭제돼서 이 방이 내 목록에서 사라졌다는 알림(room:removed) —
/// user: 방으로만 온다. Session이 방을 정리한 뒤 같은 모양으로 roomRemovedEvents에 흘려서
/// 화면이 안내 토스트([toastText])를 띄우고 열려 있던 그 방을 닫게 한다.
class RoomRemovedEvent {
  final String roomId;

  /// 'deleted'(토픽 삭제) | 'kicked'(내보내짐). 모르는 값이 와도 방 정리는 똑같이 한다.
  final String reason;

  /// 토픽 이름(안내 문구용). 서버가 안 보냈으면 Session이 로컬에 있던 이름으로 채운다.
  final String? name;

  const RoomRemovedEvent({
    required this.roomId,
    required this.reason,
    this.name,
  });

  factory RoomRemovedEvent.fromJson(Map<String, dynamic> json) =>
      RoomRemovedEvent(
        roomId: json['roomId'] as String,
        reason: json['reason'] as String? ?? 'deleted',
        name: json['name'] as String?,
      );

  bool get isDeleted => reason == 'deleted';
  bool get isKicked => reason == 'kicked';

  /// 토스트에 그대로 쓰는 안내 문구.
  String get toastText {
    final topic = name == null || name!.isEmpty ? '토픽' : "'$name' 토픽";
    return isKicked ? '$topic에서 내보내졌습니다.' : '$topic이 삭제되었습니다.';
  }
}

/// message:send가 실패했을 때(서버 거절·연결 없음·응답 없음) — 서버 문구를 그대로 보여줄 수
/// 있게 toString이 "Exception: " 없이 문구만 돌려준다(읽기 전용 토픽 안내 등).
class MessageSendException implements Exception {
  final String message;
  const MessageSendException(this.message);
  @override
  String toString() => message;
}

/// 누군가 온라인/오프라인으로 바뀌었다는 브로드캐스트(presence:update).
class PresenceUpdate {
  final String userId;
  final bool online;
  const PresenceUpdate({required this.userId, required this.online});

  factory PresenceUpdate.fromJson(Map<String, dynamic> json) => PresenceUpdate(
    userId: json['userId'] as String,
    online: json['online'] as bool,
  );
}

/// Socket.io 연결을 감싸서 Message/Room/읽음 이벤트 스트림으로 노출합니다.
class ChatSocket {
  socket_io.Socket? _socket;
  final _messageController = StreamController<Message>.broadcast();
  final _roomController = StreamController<Room>.broadcast();
  final _readController = StreamController<RoomReadEvent>.broadcast();
  final _favoriteController = StreamController<RoomFavoriteUpdate>.broadcast();
  final _mutedController = StreamController<RoomMutedUpdate>.broadcast();
  final _renamedController = StreamController<RoomRenamedUpdate>.broadcast();
  final _hiddenController = StreamController<RoomHiddenUpdate>.broadcast();
  // 팀 갱신(이름/아이콘 변경, 팀에 새로 들어감)과 팀에서 빠짐.
  final _teamController = StreamController<Team>.broadcast();
  final _teamLeftController = StreamController<TeamLeftEvent>.broadcast();
  final _commentController = StreamController<Comment>.broadcast();
  final _messageEditedController = StreamController<Message>.broadcast();
  final _messageLinkPreviewController = StreamController<Message>.broadcast();
  final _pollUpdatedController = StreamController<PollUpdatedEvent>.broadcast();
  final _pollFavoriteController =
      StreamController<PollFavoriteEvent>.broadcast();
  final _favoriteChangedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _bookmarkChangedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _todoChangedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _todoReminderController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _todoCommentController = StreamController<TodoComment>.broadcast();
  final _todoCommentEditedController =
      StreamController<TodoComment>.broadcast();
  final _todoCommentDeletedController =
      StreamController<SimpleCommentDeleted>.broadcast();
  final _albumChangedController =
      StreamController<AlbumChangedEvent>.broadcast();
  final _messageDeletedController =
      StreamController<MessageDeletedEvent>.broadcast();
  final _commentEditedController = StreamController<Comment>.broadcast();
  final _commentDeletedController =
      StreamController<CommentDeletedEvent>.broadcast();
  final _presenceController = StreamController<PresenceUpdate>.broadcast();
  final _callStateController = StreamController<CallState>.broadcast();
  final _callMicController = StreamController<CallMicRequest>.broadcast();
  final _announcementController = StreamController<Announcement>.broadcast();
  final _announcementUpdatedController =
      StreamController<Announcement>.broadcast();
  final _announcementDeletedController =
      StreamController<AnnouncementRemovedEvent>.broadcast();
  final _announcementUnpinnedController =
      StreamController<AnnouncementRemovedEvent>.broadcast();
  final _announcementCommentController =
      StreamController<AnnouncementComment>.broadcast();
  final _announcementCommentEditedController =
      StreamController<AnnouncementComment>.broadcast();
  final _announcementCommentDeletedController =
      StreamController<SimpleCommentDeleted>.broadcast();
  final _announcementReadController =
      StreamController<AnnouncementReadEvent>.broadcast();
  final _inquiryNewController = StreamController<Inquiry>.broadcast();
  final _inquiryStatusChangedController = StreamController<Inquiry>.broadcast();
  final _reconnectController = StreamController<void>.broadcast();
  final _authErrorController = StreamController<void>.broadcast();
  final _connectFailedController = StreamController<void>.broadcast();
  final _roleUpdatedController = StreamController<void>.broadcast();
  final _orgUpdatedController = StreamController<OrgUpdate>.broadcast();
  final _projectChangedController = StreamController<void>.broadcast();
  final _projectNotificationController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _projectNotificationSyncController = StreamController<int>.broadcast();
  final _notificationNewController =
      StreamController<NotificationNewEvent>.broadcast();
  final _notificationSyncController =
      StreamController<NotificationCounts>.broadcast();
  final _secretInviteController =
      StreamController<SecretInviteEvent>.broadcast();
  final _secretAcceptedController =
      StreamController<SecretAcceptedEvent>.broadcast();
  final _secretRejectedController =
      StreamController<SecretRejectedEvent>.broadcast();
  final _secretLeftController = StreamController<SecretLeftEvent>.broadcast();
  final _secretSettingsController =
      StreamController<SecretSettingsEvent>.broadcast();
  final _secretMessageReadController =
      StreamController<SecretMessageReadEvent>.broadcast();
  final _messageExpiredController =
      StreamController<MessageExpiredEvent>.broadcast();
  final _secretRekeyProposeController =
      StreamController<SecretRekeyEvent>.broadcast();
  final _secretRekeyAckController =
      StreamController<SecretRekeyEvent>.broadcast();
  final _roomRemovedController = StreamController<RoomRemovedEvent>.broadcast();
  final _topicFoldersChangedController = StreamController<String>.broadcast();
  final _calendarChangedController = StreamController<String>.broadcast();
  final _scheduledMessageEventController =
      StreamController<ScheduledMessageEvent>.broadcast();
  final _scheduledChangedController = StreamController<String>.broadcast();

  Stream<Message> get messages => _messageController.stream;

  /// 내 예약 메시지가 보내졌거나(scheduled:sent) 보내지 못했을 때(scheduled:failed) — user: 방으로만 온다.
  Stream<ScheduledMessageEvent> get scheduledMessageEvents =>
      _scheduledMessageEventController.stream;

  /// 내(다른 기기 포함) 예약 메시지 목록이 바뀌었을 때(scheduled:changed) — 그 팀 id가 흐른다.
  Stream<String> get scheduledChanged => _scheduledChangedController.stream;

  /// 예약 메시지 이벤트를 스트림으로 옮기는 처리 — connect()가 소켓에 걸고, 테스트는
  /// [debugReceiveScheduledEvent]로 같은 처리를 소켓 없이 태운다.
  late final Map<String, void Function(dynamic data)> _scheduledHandlers = {
    'scheduled:sent': (data) => _scheduledMessageEventController.add(
      ScheduledMessageEvent.fromSentJson(
        Map<String, dynamic>.from(data as Map),
      ),
    ),
    'scheduled:failed': (data) => _scheduledMessageEventController.add(
      ScheduledMessageEvent.fromFailedJson(
        Map<String, dynamic>.from(data as Map),
      ),
    ),
    'scheduled:changed': (data) => _scheduledChangedController.add(
      data is Map ? (data['teamId'] as String? ?? '') : '',
    ),
  };

  /// 소켓 없이 'scheduled:sent' / 'scheduled:failed' / 'scheduled:changed'를 받은 것처럼 처리한다.
  @visibleForTesting
  void debugReceiveScheduledEvent(String event, Object? data) =>
      _scheduledHandlers[event]?.call(data);

  /// 토픽에서 내보내졌거나 토픽이 삭제됐을 때(room:removed).
  Stream<RoomRemovedEvent> get roomRemoved => _roomRemovedController.stream;

  /// 캘린더·일정이 바뀌었을 때(calendar:changed) — 그 팀 id가 흐른다. 열려 있는 캘린더 화면이 다시 받는다.
  Stream<String> get calendarChanged => _calendarChangedController.stream;

  /// 내(다른 기기 포함) 토픽 폴더가 바뀌었을 때(topic-folders:changed) — 그 팀 id가 흐른다.
  Stream<String> get topicFoldersChanged =>
      _topicFoldersChangedController.stream;

  /// 서버가 방 생성/합류를 알려줄 때(room:created) 흘러나온다. Session이 방 목록을 upsert하는 데 쓴다.
  Stream<Room> get roomEvents => _roomController.stream;

  /// 누군가 방을 읽었다는 브로드캐스트. 안읽음 카운터 갱신에 쓴다.
  Stream<RoomReadEvent> get readEvents => _readController.stream;

  /// 내가(다른 기기 포함) 방의 즐겨찾기를 바꿨다는 브로드캐스트.
  Stream<RoomFavoriteUpdate> get favoriteEvents => _favoriteController.stream;

  /// 내가(다른 기기 포함) 방의 알림 끄기를 바꿨다는 브로드캐스트.
  Stream<RoomMutedUpdate> get mutedEvents => _mutedController.stream;
  Stream<RoomRenamedUpdate> get renamedEvents => _renamedController.stream;

  /// 평문 DM의 숨기기 상태 변화(내가 숨기기/나가기를 했거나, 상대의 새 메시지로 서버가
  /// 자동으로 다시 보이게 되돌렸을 때).
  Stream<RoomHiddenUpdate> get hiddenEvents => _hiddenController.stream;

  /// 팀이 갱신됐거나(team:updated — 이름/아이콘 변경) 내가 팀에 새로 들어갔을 때(team:joined).
  Stream<Team> get teamEvents => _teamController.stream;

  /// 소유자/관리자가 나를 팀에서 뺐을 때(team:left).
  Stream<TeamLeftEvent> get teamLeftEvents => _teamLeftController.stream;

  /// 누군가 메시지에 댓글을 달았다는 브로드캐스트(comment:new).
  Stream<Comment> get commentEvents => _commentController.stream;

  /// 누군가 메시지를 수정했다는 브로드캐스트(message:edited) — 수정된 메시지 전체가 온다.
  Stream<Message> get messageEdited => _messageEditedController.stream;

  /// 메시지에 담긴 링크의 오픈그래프 미리보기가 (서버가 백그라운드로 가져와서) 채워졌을 때
  /// (message:linkPreview) — 사용자가 고친 게 아니므로 messageEdited와는 별도 이벤트다.
  Stream<Message> get messageLinkPreview =>
      _messageLinkPreviewController.stream;

  /// 누가 투표했거나 투표가 마감됐다(poll:updated) — 방 전체에 온다.
  Stream<PollUpdatedEvent> get pollUpdated => _pollUpdatedController.stream;

  /// 내 다른 기기에서 투표 즐겨찾기를 바꿨다(poll:favorite) — 내 user 룸으로만 온다.
  Stream<PollFavoriteEvent> get pollFavorite => _pollFavoriteController.stream;

  /// 내 다른 기기에서 메시지·댓글·멤버 즐겨찾기를 바꿨다(favorite:changed — `{kind, id, favorite, teamId?}`).
  /// 내 user 룸으로만 온다. 받는 쪽은 services/favorites_controller.dart.
  Stream<Map<String, dynamic>> get favoriteChanged =>
      _favoriteChangedController.stream;

  /// 북마크가 만들어지거나 바뀌거나 지워지거나 순서가 바뀌었다(bookmark:changed — `{teamId, kind}`). 팀 북마크는 그 팀
  /// 멤버 모두에게, 개인 북마크는 본인에게만 온다. 받는 쪽은 services/bookmark_controller.dart.
  Stream<Map<String, dynamic>> get bookmarkChanged =>
      _bookmarkChangedController.stream;

  /// 할 일이 만들어지거나 바뀌거나 지워졌다(todo:changed — `{teamId, roomId, todoId, kind, actorId?, title?,
  /// addedAssigneeIds?}`) — 그 방 멤버에게 온다. 받는 쪽은 services/todo_controller.dart.
  Stream<Map<String, dynamic>> get todoChanged => _todoChangedController.stream;

  /// 할 일에 새 댓글이 달렸다(todo:comment:new) — 그 방 멤버에게 온다. 받는 쪽은 할 일 상세(todo_detail_dialog.dart).
  Stream<TodoComment> get todoComments => _todoCommentController.stream;

  /// 할 일 댓글이 고쳐졌다(todo:comment:edited).
  Stream<TodoComment> get todoCommentEdited =>
      _todoCommentEditedController.stream;

  /// 할 일 댓글이 지워졌다(todo:comment:deleted — parentId는 할 일 id).
  Stream<SimpleCommentDeleted> get todoCommentDeleted =>
      _todoCommentDeletedController.stream;

  /// 할 일 알림 시각이 됐다(todo:reminder — `{teamId, roomId, todoId, title, dueDate?, dueTime?, remindAt}`) — 담당자(없으면 만든
  /// 사람)에게만 온다. 앱이 켜져 있으면 토스트로 보여 준다(session.dart).
  Stream<Map<String, dynamic>> get todoReminder =>
      _todoReminderController.stream;

  /// 앨범이 만들어지거나 바뀌거나 지워졌거나 항목이 늘고 줄었다(album:changed) — 그 방 멤버에게 온다.
  /// 받는 쪽은 services/album_controller.dart.
  Stream<AlbumChangedEvent> get albumChanged => _albumChangedController.stream;

  /// 누군가 메시지를 삭제했다는 브로드캐스트(message:deleted).
  Stream<MessageDeletedEvent> get messageDeleted =>
      _messageDeletedController.stream;

  /// 누군가 댓글을 수정했다는 브로드캐스트(comment:edited) — 수정된 댓글 전체가 온다.
  Stream<Comment> get commentEdited => _commentEditedController.stream;

  /// 누군가 댓글을 삭제했다는 브로드캐스트(comment:deleted).
  Stream<CommentDeletedEvent> get commentDeleted =>
      _commentDeletedController.stream;

  /// 누군가 온라인/오프라인으로 바뀌었다는 브로드캐스트. 멤버 목록의 초록 점 갱신에 쓴다.
  Stream<PresenceUpdate> get presenceEvents => _presenceController.stream;

  /// 화상회의 상태가 바뀔 때마다(누가 들어오고 나갈 때) 그 방의 멤버 전원에게 온다.
  Stream<CallState> get callStates => _callStateController.stream;

  /// 진행자의 마이크 켜기/끄기 요청(call:mic).
  Stream<CallMicRequest> get callMicRequests => _callMicController.stream;

  /// 토픽방 공지가 새로 올라올 때마다(announcement:new) — 방 상단 배너와 공지 목록 화면이
  /// 이걸로 즉시 갱신된다.
  Stream<Announcement> get announcements => _announcementController.stream;

  /// 공지가 수정됐을 때(announcement:updated) — 수정된 공지 전체가 온다(예전 서버는 댓글 개수를 0으로
  /// 보냈으므로 호출부에서 기존 값을 덮어쓰지 않고 text/editedAt만 반영한다).
  Stream<Announcement> get announcementUpdated =>
      _announcementUpdatedController.stream;

  /// 공지가 삭제됐을 때(announcement:deleted) — 목록에서도 완전히 사라져야 한다.
  Stream<AnnouncementRemovedEvent> get announcementDeleted =>
      _announcementDeletedController.stream;

  /// "공지 내리기"로 배너에서 내려갔을 때(announcement:unpinned) — 목록(히스토리)엔 남고
  /// "고정됨" 표시만 사라진다.
  Stream<AnnouncementRemovedEvent> get announcementUnpinned =>
      _announcementUnpinnedController.stream;

  /// 공지에 새 댓글이 달렸을 때(announcement:comment:new).
  Stream<AnnouncementComment> get announcementComments =>
      _announcementCommentController.stream;

  /// 공지 댓글이 고쳐졌을 때(announcement:comment:edited).
  Stream<AnnouncementComment> get announcementCommentEdited =>
      _announcementCommentEditedController.stream;

  /// 공지 댓글이 지워졌을 때(announcement:comment:deleted — parentId는 공지 id).
  Stream<SimpleCommentDeleted> get announcementCommentDeleted =>
      _announcementCommentDeletedController.stream;

  /// 내가(다른 기기 포함) 공지 목록/상세를 열어서 읽음 처리됐을 때(announcement:read) — 알림
  /// 센터의 "안 읽은 공지" 표시를 다른 기기와 동기화하는 데 쓴다.
  Stream<AnnouncementReadEvent> get announcementRead =>
      _announcementReadController.stream;

  /// 새 문의가 왔을 때(inquiry:new) — 팀장이 "받은 문의" 목록을 열어뒀으면 실시간으로 반영.
  Stream<Inquiry> get inquiryNew => _inquiryNewController.stream;

  /// 문의 처리 상태가 바뀌었을 때(inquiry:statusChanged) — 보낸 사람의 "보낸 문의" 목록이나
  /// 다른 기기의 "받은 문의" 목록에 실시간으로 반영.
  Stream<Inquiry> get inquiryStatusChanged =>
      _inquiryStatusChangedController.stream;

  /// 연결이 끊겼다가 다시 붙었을 때(최초 연결 제외) 흘러나온다.
  /// 끊긴 동안 놓친 메시지/방 상태를 다시 받아오는 용도.
  Stream<void> get reconnected => _reconnectController.stream;

  /// 서버 운영자가 관리자 콘솔에서 내 계정 등급/서버 운영자 여부를 바꿨을 때 — 로그아웃
  /// 없이 바로 반영하려고, 이 이벤트를 받으면 Session이 /users/me를 다시 불러온다.
  Stream<void> get roleUpdated => _roleUpdatedController.stream;

  /// 누군가의 부서/직책이 바뀌었을 때(관리자 콘솔 "회원" 탭 또는 팀 설정 "멤버" 탭) — 로그아웃
  /// 없이 바로 반영하려고, Session이 이 이벤트로 room.members에 캐싱된 값을 직접 덮어쓴다.
  Stream<OrgUpdate> get orgUpdated => _orgUpdatedController.stream;

  /// 내가 참여 중인 프로젝트에서 뭔가 바뀌었을 때(프로젝트/업무/댓글 생성·수정·삭제) —
  /// 열려 있는 "프로젝트" 창이 지금 보고 있는 화면을 다시 불러오는 신호로만 쓴다(무엇이
  /// 바뀌었는지는 굳이 구분하지 않는다 — 화면 하나가 통째로 새로고침되는 편이 단순하다).
  Stream<void> get projectChanged => _projectChangedController.stream;

  /// 프로젝트 알림(업무 배정/댓글/마감 임박 등) 한 건 — 서버 project:notification.
  Stream<Map<String, dynamic>> get projectNotifications =>
      _projectNotificationController.stream;

  /// 프로젝트 알림의 안 읽은 개수가 바뀜(다른 창/기기에서 읽음 처리) — 새 개수.
  Stream<int> get projectNotificationSync =>
      _projectNotificationSyncController.stream;

  /// 알림 센터의 멘션·보드 알림 한 건(서버 notification:new) — 새 알림과 그 뒤의 안 읽음 개수.
  Stream<NotificationNewEvent> get notificationNew =>
      _notificationNewController.stream;

  /// 멘션·보드 안 읽음 개수가 바뀜(다른 기기에서 읽음, 방을 읽음 — 서버 notification:sync).
  Stream<NotificationCounts> get notificationSync =>
      _notificationSyncController.stream;

  /// 서버가 handshake에서 인증을 거부했을 때(만료됐거나 비밀번호 변경 등으로 폐기된
  /// accessToken으로 연결을 시도한 경우) 흘러나온다. Session이 새 accessToken을 받아
  /// 다시 연결을 시도하는 데 쓴다.
  Stream<void> get authErrors => _authErrorController.stream;

  /// 인증 문제가 아닌 이유로 연결(재연결 시도 포함)이 실패할 때마다 흘러나온다 — 서버에 아예
  /// 닿지 않는 경우(사내 와이파이를 벗어남 등). Session이 사내/외부 주소 중 되는 쪽을 다시
  /// 찾는 데 쓴다(server_endpoints.dart). 재연결 시도마다 오므로 받는 쪽에서 간격을 둔다.
  Stream<void> get connectFailures => _connectFailedController.stream;

  Stream<SecretInviteEvent> get secretInvites => _secretInviteController.stream;
  Stream<SecretAcceptedEvent> get secretAccepted =>
      _secretAcceptedController.stream;
  Stream<SecretRejectedEvent> get secretRejected =>
      _secretRejectedController.stream;
  Stream<SecretLeftEvent> get secretLeft => _secretLeftController.stream;
  Stream<SecretSettingsEvent> get secretSettings =>
      _secretSettingsController.stream;
  Stream<SecretMessageReadEvent> get secretMessageRead =>
      _secretMessageReadController.stream;
  Stream<MessageExpiredEvent> get messageExpired =>
      _messageExpiredController.stream;
  Stream<SecretRekeyEvent> get secretRekeyPropose =>
      _secretRekeyProposeController.stream;
  Stream<SecretRekeyEvent> get secretRekeyAck =>
      _secretRekeyAckController.stream;

  bool get isConnected => _socket?.connected ?? false;

  /// connect()로 소켓을 만든 뒤 아직 dispose()하지 않은 상태(연결 중·재연결 대기 포함).
  bool get isStarted => _socket != null;

  /// 소켓이 아직 **만들어지기도 전에** 들어온 읽음 처리 요청들. 알림을 눌러 앱이 켜지는
  /// 경로에서는 방 목록을 받자마자 채팅방이 열리는데(main.dart의 _openRoomFromNotification),
  /// 그 시점엔 Session._enterApp이 아직 fetchMe/기기 등록을 기다리는 중이라 connect()가
  /// 불리기 전이다. 그러면 markRead의 emit이 그냥 사라져서 서버는 내가 읽은 걸 영영 모르고,
  /// 양쪽 앱의 "안 읽음 1" 표시가 계속 남는다(다음 메시지가 올 때 markRead가 다시 불려야
  /// 겨우 풀렸다). 소켓이 만들어진 뒤라면 연결 전이어도 socket.io가 알아서 버퍼링해주므로
  /// (sendBuffer) 이 큐는 "_socket == null"인 구간만 메운다.
  final _pendingReadRoomIds = <String>{};
  final _pendingAnnouncementReadRoomIds = <String>{};

  bool _looksLikeAuthError(dynamic err) {
    final message = err is Map ? err['message']?.toString() : err?.toString();
    return message?.toLowerCase().contains('unauthorized') ?? false;
  }

  Future<void> connect({
    required String baseUrl,
    required String token,
    String? deviceId,
  }) async {
    _socket?.dispose();

    // 서버가 자체 서명 인증서를 쓰므로, 앱에 내장해둔 그 인증서만 신뢰하는 커넥터로
    // WebSocket을 연결한다(REST 쪽 PinnedTls.httpClient()와 같은 목적).
    final connector = await PinnedTls.webSocketConnector();

    final socket = socket_io.io(
      baseUrl,
      socket_io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': token, 'deviceId': ?deviceId})
          .setWebSocketConnector(connector)
          .disableAutoConnect()
          // socket_io_client가 같은 baseUrl에 대해 내부적으로 Manager를 전역 캐싱하는데,
          // 재로그인처럼 같은 앱 프로세스 안에서 connect()를 다시 호출하는 경우 이 캐시가
          // 이전 계정(토큰)으로 인증된 연결을 재사용해버릴 수 있다 — 그러면 겉보기엔 새
          // 토큰으로 연결한 것 같아도 서버는 예전 사용자로 인식한다. forceNew로 매번
          // 완전히 새 연결을 강제해서 이 문제를 원천 차단한다.
          .enableForceNew()
          .build(),
    );

    socket.on('message:new', (data) {
      _messageController.add(
        Message.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('room:created', (data) {
      _roomController.add(
        Room.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('room:read', (data) {
      _readController.add(
        RoomReadEvent.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('room:favorite', (data) {
      _favoriteController.add(
        RoomFavoriteUpdate.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('room:muted', (data) {
      _mutedController.add(
        RoomMutedUpdate.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('room:renamed', (data) {
      _renamedController.add(
        RoomRenamedUpdate.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('room:hidden', (data) {
      _hiddenController.add(
        RoomHiddenUpdate.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('room:removed', (data) {
      _roomRemovedController.add(
        RoomRemovedEvent.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('calendar:changed', (data) {
      _calendarChangedController.add(
        data is Map ? (data['teamId'] as String? ?? '') : '',
      );
    });
    socket.on('topic-folders:changed', (data) {
      _topicFoldersChangedController.add(
        data is Map ? (data['teamId'] as String? ?? '') : '',
      );
    });
    _scheduledHandlers.forEach(socket.on);
    // 팀 갱신과 팀 합류는 클라이언트에서 하는 일이 같다(팀 목록에 upsert) — 같은 스트림으로 묶는다.
    for (final event in ['team:updated', 'team:joined']) {
      socket.on(event, (data) {
        _teamController.add(
          Team.fromJson(Map<String, dynamic>.from(data as Map)),
        );
      });
    }
    socket.on('team:left', (data) {
      _teamLeftController.add(
        TeamLeftEvent.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('user:role-updated', (_) => _roleUpdatedController.add(null));
    socket.on('project:changed', (_) => _projectChangedController.add(null));
    socket.on(
      'project:notification',
      (data) => _projectNotificationController.add(
        Map<String, dynamic>.from(data as Map),
      ),
    );
    socket.on(
      'project:notification-sync',
      (data) => _projectNotificationSyncController.add(
        ((data as Map)['unreadCount'] as num?)?.toInt() ?? 0,
      ),
    );
    socket.on('notification:new', (data) {
      _notificationNewController.add(
        NotificationNewEvent.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on(
      'notification:sync',
      (data) =>
          _notificationSyncController.add(NotificationCounts.fromJson(data)),
    );
    socket.on('org:updated', (data) {
      _orgUpdatedController.add(
        OrgUpdate.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('comment:new', (data) {
      _commentController.add(
        Comment.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('message:edited', (data) {
      _messageEditedController.add(
        Message.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('message:linkPreview', (data) {
      _messageLinkPreviewController.add(
        Message.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('poll:updated', (data) {
      _pollUpdatedController.add(
        PollUpdatedEvent.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('poll:favorite', (data) {
      _pollFavoriteController.add(
        PollFavoriteEvent.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('favorite:changed', (data) {
      _favoriteChangedController.add(Map<String, dynamic>.from(data as Map));
    });
    socket.on('bookmark:changed', (data) {
      _bookmarkChangedController.add(Map<String, dynamic>.from(data as Map));
    });
    socket.on('todo:changed', (data) {
      _todoChangedController.add(Map<String, dynamic>.from(data as Map));
    });
    socket.on('todo:reminder', (data) {
      _todoReminderController.add(Map<String, dynamic>.from(data as Map));
    });
    socket.on('todo:comment:new', (data) {
      _todoCommentController.add(
        TodoComment.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('todo:comment:edited', (data) {
      _todoCommentEditedController.add(
        TodoComment.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('todo:comment:deleted', (data) {
      final m = Map<String, dynamic>.from(data as Map);
      _todoCommentDeletedController.add((
        id: m['id'] as String,
        parentId: m['todoId'] as String,
        roomId: m['roomId'] as String,
      ));
    });
    socket.on('album:changed', (data) {
      _albumChangedController.add(
        AlbumChangedEvent.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('message:deleted', (data) {
      _messageDeletedController.add(
        MessageDeletedEvent.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('comment:edited', (data) {
      _commentEditedController.add(
        Comment.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('comment:deleted', (data) {
      _commentDeletedController.add(
        CommentDeletedEvent.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('announcement:new', (data) {
      _announcementController.add(
        Announcement.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('announcement:updated', (data) {
      _announcementUpdatedController.add(
        Announcement.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('announcement:deleted', (data) {
      _announcementDeletedController.add(
        AnnouncementRemovedEvent.fromJson(
          Map<String, dynamic>.from(data as Map),
        ),
      );
    });
    socket.on('announcement:unpinned', (data) {
      _announcementUnpinnedController.add(
        AnnouncementRemovedEvent.fromJson(
          Map<String, dynamic>.from(data as Map),
        ),
      );
    });
    socket.on('announcement:comment:new', (data) {
      _announcementCommentController.add(
        AnnouncementComment.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('announcement:comment:edited', (data) {
      _announcementCommentEditedController.add(
        AnnouncementComment.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('announcement:comment:deleted', (data) {
      final m = Map<String, dynamic>.from(data as Map);
      _announcementCommentDeletedController.add((
        id: m['id'] as String,
        parentId: m['announcementId'] as String,
        roomId: m['roomId'] as String,
      ));
    });
    socket.on('announcement:read', (data) {
      _announcementReadController.add(
        AnnouncementReadEvent.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('inquiry:new', (data) {
      _inquiryNewController.add(
        Inquiry.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('inquiry:statusChanged', (data) {
      _inquiryStatusChangedController.add(
        Inquiry.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('call:state', (data) {
      _callStateController.add(
        CallState.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('call:mic', (data) {
      final m = Map<String, dynamic>.from(data as Map);
      final roomId = m['roomId'];
      final on = m['on'];
      if (roomId is String && on is bool) {
        _callMicController.add((roomId: roomId, on: on));
      }
    });
    socket.on('presence:update', (data) {
      _presenceController.add(
        PresenceUpdate.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('secret:invite', (data) {
      _secretInviteController.add(
        SecretInviteEvent.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('secret:accepted', (data) {
      _secretAcceptedController.add(
        SecretAcceptedEvent.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('secret:rejected', (data) {
      _secretRejectedController.add(
        SecretRejectedEvent.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('secret:left', (data) {
      _secretLeftController.add(
        SecretLeftEvent.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('secret:settings', (data) {
      _secretSettingsController.add(
        SecretSettingsEvent.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('secret:message-read', (data) {
      _secretMessageReadController.add(
        SecretMessageReadEvent.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('message:expired', (data) {
      _messageExpiredController.add(
        MessageExpiredEvent.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('secret:rekey-propose', (data) {
      _secretRekeyProposeController.add(
        SecretRekeyEvent.fromProposeJson(
          Map<String, dynamic>.from(data as Map),
        ),
      );
    });
    socket.on('secret:rekey-ack', (data) {
      _secretRekeyAckController.add(
        SecretRekeyEvent.fromAckJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.onReconnect((_) => _reconnectController.add(null));
    void onFailure(dynamic err) => _looksLikeAuthError(err)
        ? _authErrorController.add(null)
        : _connectFailedController.add(null);
    socket.onConnectError(onFailure);
    socket.onReconnectError(onFailure);

    socket.connect();
    _socket = socket;
    // connect()가 끝나기 전에 emit해도 socket.io가 sendBuffer에 담아뒀다가 연결되면 보낸다 —
    // 소켓이 없던 동안 밀린 읽음 처리를 여기서 한 번에 흘려보낸다(_pendingReadRoomIds 참고).
    for (final roomId in _pendingReadRoomIds) {
      socket.emit('room:read', {'roomId': roomId});
    }
    _pendingReadRoomIds.clear();
    for (final roomId in _pendingAnnouncementReadRoomIds) {
      socket.emit('announcement:read', {'roomId': roomId});
    }
    _pendingAnnouncementReadRoomIds.clear();
  }

  /// 테스트가 실제 소켓 없이 message:send 페이로드를 확인할 수 있게 하는 대체 전송 함수 —
  /// 설정돼 있으면 소켓 대신 이 함수가 페이로드를 받고, 그 반환값을 서버 ack로 쓴다.
  @visibleForTesting
  Future<Map<String, dynamic>> Function(Map<String, dynamic> payload)?
  debugSendOverride;

  /// 메시지를 보내고 서버의 ack(message:send 응답)를 기다린다. 서버가 ack에 실어준 저장된
  /// 메시지를 돌려준다(없거나 못 읽으면 null — 목록 반영은 어차피 message:new로 된다).
  /// 서버가 실패를 응답하거나 일정 시간 내 응답이 없으면 [MessageSendException]을 던진다.
  /// (연결이 끊긴 상태라면 socket.io가 알아서 큐에 담아뒀다가 재연결 시 보내므로,
  /// 짧은 연결 끊김 정도는 타임아웃 전에 ack가 도착해 정상 처리된다.)
  Future<Message?> send({
    required String roomId,
    required String type,
    String? text,

    /// 보드 게시글(type 'post')의 제목 — 다른 타입은 안 보낸다.
    String? title,

    /// [text]의 글자 서식(rich_text_format.dart) — 비밀 대화는 서버가 받지 않는다.
    List<TextFormatRun>? textFormat,

    /// [text] 안의 멘션 구간 — 비밀 대화는 보내지 않는다(서버가 본문을 모른다).
    List<Mention>? mentions,
    String? fileUrl,
    String? fileName,
    int? fileSize,
    String? mimeType,
    String? thumbnailUrl,

    /// 사진 여러 장을 한 말풍선으로 보낼 때 — [{kind, fileUrl, fileName, fileSize,
    /// mimeType, thumbnailUrl}, ...]. 한 장뿐이면 안 보내고 위의 fileUrl만 쓴다.
    List<Map<String, dynamic>>? attachments,
    // "메시지 공유"(message_share_screen.dart) — 다른 방으로 원본을 인용해서 보낼 때만 채운다.
    String? quotedSenderName,
    String? quotedPreview,
    // "메시지 전달"(message_forward_screen.dart)에서 "포함" 토글을 켰을 때만 채운다.
    String? forwardedFromSenderName,
    int? forwardedFromCreatedAt,
    // "팀장에게 문의하기"로 보낸 메시지에만 채운다(chat_input_bar.dart의 _showInquiryDialog) —
    // message_bubble.dart가 이 값이 있으면 "문의함 바로가기" 링크를 붙여서 보여준다.
    String? inquiryId,
  }) {
    final payload = <String, dynamic>{
      'roomId': roomId,
      'type': type,
      'title': ?title,
      'text': ?text,
      'textFormat': ?textFormatToJson(textFormat),
      'mentions': ?mentionsToJson(mentions),
      'fileUrl': ?fileUrl,
      'fileName': ?fileName,
      'fileSize': ?fileSize,
      'mimeType': ?mimeType,
      'thumbnailUrl': ?thumbnailUrl,
      'attachments': ?attachments,
      'quotedSenderName': ?quotedSenderName,
      'quotedPreview': ?quotedPreview,
      'forwardedFromSenderName': ?forwardedFromSenderName,
      'forwardedFromCreatedAt': ?forwardedFromCreatedAt,
      'inquiryId': ?inquiryId,
    };
    final override = debugSendOverride;
    if (override != null) return override(payload).then(_messageFromAck);

    final socket = _socket;
    if (socket == null) {
      return Future.error(const MessageSendException('서버와 연결되어 있지 않습니다.'));
    }

    final completer = Completer<Message?>();
    socket.emitWithAck(
      'message:send',
      payload,
      ack: (dynamic response) {
        if (completer.isCompleted) return;
        final map = response is Map
            ? Map<String, dynamic>.from(response)
            : const <String, dynamic>{};
        try {
          completer.complete(_messageFromAck(map));
        } catch (e) {
          completer.completeError(e);
        }
      },
    );
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () =>
          throw const MessageSendException('서버 응답이 없습니다. 연결 상태를 확인해주세요.'),
    );
  }

  /// message:send ack 해석 — 실패면 서버 문구로 예외를 던지고, 성공이면 같이 온 메시지를 읽는다.
  static Message? _messageFromAck(Map<String, dynamic> ack) {
    if (ack['ok'] != true) {
      throw MessageSendException(ack['error']?.toString() ?? '메시지 전송에 실패했습니다.');
    }
    final message = ack['message'];
    if (message is! Map) return null;
    try {
      return Message.fromJson(Map<String, dynamic>.from(message));
    } catch (_) {
      return null; // 전송 자체는 성공했으니 모양이 낯설어도 실패로 만들지 않는다.
    }
  }

  void markRead(String roomId) {
    final socket = _socket;
    if (socket == null) {
      _pendingReadRoomIds.add(roomId);
      return;
    }
    socket.emit('room:read', {'roomId': roomId});
  }

  /// 공지 목록/상세를 열었다는 뜻(markRead와 별개 — announcements.js 주석 참고).
  void markAnnouncementRead(String roomId) {
    final socket = _socket;
    if (socket == null) {
      _pendingAnnouncementReadRoomIds.add(roomId);
      return;
    }
    socket.emit('announcement:read', {'roomId': roomId});
  }

  /// LiveKit 연결에 성공한 직후 "나 통화에 들어왔다"고 알린다 — 서버가 방 멤버 전원에게
  /// call:state를 브로드캐스트해서 다른 사람 화면에 수신/참가자 표시가 뜨게 한다.
  void joinCall(String roomId) =>
      _socket?.emit('call:join', {'roomId': roomId});

  /// 통화 종료. 소켓이 그냥 끊겨도 서버가 알아서 정리하지만(socket.js의 disconnect),
  /// 정상 종료는 명시적으로 알려야 남은 사람들 화면이 즉시 갱신된다.
  void leaveCall(String roomId) =>
      _socket?.emit('call:leave', {'roomId': roomId});

  /// 진행자가 [targetId]의 마이크를 켜거나 끈다 — 서버가 진행자인지 확인하고 그 사람 기기에 전한다.
  void controlCallMic(String roomId, String targetId, bool on) => _socket?.emit(
    'call:mic',
    {'roomId': roomId, 'targetId': targetId, 'on': on},
  );

  /// 비밀 대화 메시지가 실제로 화면에 노출됐다는 신호 — 자동 삭제 타이머가 이 시점부터 시작된다.
  void markSecretMessageRead(String roomId, String messageId) {
    _socket?.emit('secret:message-read', {
      'roomId': roomId,
      'messageId': messageId,
    });
  }

  void proposeSecretRekey({
    required String roomId,
    required int keyEpoch,
    required String ephemeralPublicKey,
    required String ephemeralSignature,
  }) {
    _socket?.emit('secret:rekey-propose', {
      'roomId': roomId,
      'keyEpoch': keyEpoch,
      'ephemeralPublicKey': ephemeralPublicKey,
      'ephemeralSignature': ephemeralSignature,
    });
  }

  void ackSecretRekey({
    required String roomId,
    required int keyEpoch,
    required String ephemeralPublicKey,
    required String ephemeralSignature,
  }) {
    _socket?.emit('secret:rekey-ack', {
      'roomId': roomId,
      'keyEpoch': keyEpoch,
      'ephemeralPublicKey': ephemeralPublicKey,
      'ephemeralSignature': ephemeralSignature,
    });
  }

  void dispose() {
    // 스트림 컨트롤러는 Session이 재로그인 시 같은 ChatSocket 인스턴스로 connect()를
    // 다시 호출할 수 있어 여기서 닫지 않는다(소켓 자체만 정리).
    _socket?.dispose();
    _socket = null;
  }
}
