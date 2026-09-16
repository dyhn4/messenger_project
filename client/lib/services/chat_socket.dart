import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as socket_io;

import '../models/announcement.dart';
import '../models/comment.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../models/team.dart';
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

  const CallState({
    required this.roomId,
    required this.active,
    this.startedBy,
    this.startedAt,
    this.participantIds = const [],
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
  );
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
  final _hiddenController = StreamController<RoomHiddenUpdate>.broadcast();
  // 팀 갱신(이름/아이콘 변경, 팀에 새로 들어감)과 팀에서 빠짐.
  final _teamController = StreamController<Team>.broadcast();
  final _teamLeftController = StreamController<TeamLeftEvent>.broadcast();
  final _commentController = StreamController<Comment>.broadcast();
  final _messageEditedController = StreamController<Message>.broadcast();
  final _messageDeletedController =
      StreamController<MessageDeletedEvent>.broadcast();
  final _commentEditedController = StreamController<Comment>.broadcast();
  final _commentDeletedController =
      StreamController<CommentDeletedEvent>.broadcast();
  final _presenceController = StreamController<PresenceUpdate>.broadcast();
  final _callStateController = StreamController<CallState>.broadcast();
  final _announcementController = StreamController<Announcement>.broadcast();
  final _announcementUpdatedController =
      StreamController<Announcement>.broadcast();
  final _announcementDeletedController =
      StreamController<AnnouncementRemovedEvent>.broadcast();
  final _announcementUnpinnedController =
      StreamController<AnnouncementRemovedEvent>.broadcast();
  final _announcementCommentController =
      StreamController<AnnouncementComment>.broadcast();
  final _announcementReadController =
      StreamController<AnnouncementReadEvent>.broadcast();
  final _reconnectController = StreamController<void>.broadcast();
  final _authErrorController = StreamController<void>.broadcast();
  final _roleUpdatedController = StreamController<void>.broadcast();
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

  Stream<Message> get messages => _messageController.stream;

  /// 서버가 방 생성/합류를 알려줄 때(room:created) 흘러나온다. Session이 방 목록을 upsert하는 데 쓴다.
  Stream<Room> get roomEvents => _roomController.stream;

  /// 누군가 방을 읽었다는 브로드캐스트. 안읽음 카운터 갱신에 쓴다.
  Stream<RoomReadEvent> get readEvents => _readController.stream;

  /// 내가(다른 기기 포함) 방의 즐겨찾기를 바꿨다는 브로드캐스트.
  Stream<RoomFavoriteUpdate> get favoriteEvents => _favoriteController.stream;

  /// 내가(다른 기기 포함) 방의 알림 끄기를 바꿨다는 브로드캐스트.
  Stream<RoomMutedUpdate> get mutedEvents => _mutedController.stream;

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

  /// 토픽방 공지가 새로 올라올 때마다(announcement:new) — 방 상단 배너와 공지 목록 화면이
  /// 이걸로 즉시 갱신된다.
  Stream<Announcement> get announcements => _announcementController.stream;

  /// 공지가 수정됐을 때(announcement:updated) — 수정된 공지 전체가 온다(댓글 개수는 항상 0으로
  /// 오므로 호출부에서 기존 값을 덮어쓰지 않고 text/editedAt만 반영해야 한다).
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

  /// 내가(다른 기기 포함) 공지 목록/상세를 열어서 읽음 처리됐을 때(announcement:read) — 알림
  /// 센터의 "안 읽은 공지" 표시를 다른 기기와 동기화하는 데 쓴다.
  Stream<AnnouncementReadEvent> get announcementRead =>
      _announcementReadController.stream;

  /// 연결이 끊겼다가 다시 붙었을 때(최초 연결 제외) 흘러나온다.
  /// 끊긴 동안 놓친 메시지/방 상태를 다시 받아오는 용도.
  Stream<void> get reconnected => _reconnectController.stream;

  /// 서버 운영자가 관리자 콘솔에서 내 계정 등급/서버 운영자 여부를 바꿨을 때 — 로그아웃
  /// 없이 바로 반영하려고, 이 이벤트를 받으면 Session이 /users/me를 다시 불러온다.
  Stream<void> get roleUpdated => _roleUpdatedController.stream;

  /// 서버가 handshake에서 인증을 거부했을 때(만료됐거나 비밀번호 변경 등으로 폐기된
  /// accessToken으로 연결을 시도한 경우) 흘러나온다. Session이 새 accessToken을 받아
  /// 다시 연결을 시도하는 데 쓴다.
  Stream<void> get authErrors => _authErrorController.stream;

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
    socket.on('room:hidden', (data) {
      _hiddenController.add(
        RoomHiddenUpdate.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
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
        AnnouncementRemovedEvent.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('announcement:unpinned', (data) {
      _announcementUnpinnedController.add(
        AnnouncementRemovedEvent.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('announcement:comment:new', (data) {
      _announcementCommentController.add(
        AnnouncementComment.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('announcement:read', (data) {
      _announcementReadController.add(
        AnnouncementReadEvent.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    });
    socket.on('call:state', (data) {
      _callStateController.add(
        CallState.fromJson(Map<String, dynamic>.from(data as Map)),
      );
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
    socket.onConnectError((err) {
      if (_looksLikeAuthError(err)) _authErrorController.add(null);
    });
    socket.onReconnectError((err) {
      if (_looksLikeAuthError(err)) _authErrorController.add(null);
    });

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

  /// 메시지를 보내고 서버의 ack(message:send 응답)를 기다린다.
  /// 서버가 실패를 응답하거나 일정 시간 내 응답이 없으면 예외를 던진다.
  /// (연결이 끊긴 상태라면 socket.io가 알아서 큐에 담아뒀다가 재연결 시 보내므로,
  /// 짧은 연결 끊김 정도는 타임아웃 전에 ack가 도착해 정상 처리된다.)
  Future<void> send({
    required String roomId,
    required String type,
    String? text,
    String? fileUrl,
    String? fileName,
    int? fileSize,
    String? mimeType,
    String? thumbnailUrl,
    // "메시지 공유"(message_share_screen.dart) — 다른 방으로 원본을 인용해서 보낼 때만 채운다.
    String? quotedSenderName,
    String? quotedPreview,
    // "메시지 전달"(message_forward_screen.dart)에서 "포함" 토글을 켰을 때만 채운다.
    String? forwardedFromSenderName,
    int? forwardedFromCreatedAt,
  }) {
    final socket = _socket;
    if (socket == null) {
      return Future.error(Exception('서버와 연결되어 있지 않습니다.'));
    }

    final completer = Completer<void>();
    socket.emitWithAck(
      'message:send',
      {
        'roomId': roomId,
        'type': type,
        'text': ?text,
        'fileUrl': ?fileUrl,
        'fileName': ?fileName,
        'fileSize': ?fileSize,
        'mimeType': ?mimeType,
        'thumbnailUrl': ?thumbnailUrl,
        'quotedSenderName': ?quotedSenderName,
        'quotedPreview': ?quotedPreview,
        'forwardedFromSenderName': ?forwardedFromSenderName,
        'forwardedFromCreatedAt': ?forwardedFromCreatedAt,
      },
      ack: (dynamic response) {
        if (completer.isCompleted) return;
        final map = response is Map
            ? Map<String, dynamic>.from(response)
            : const <String, dynamic>{};
        if (map['ok'] == true) {
          completer.complete();
        } else {
          completer.completeError(
            Exception(map['error']?.toString() ?? '메시지 전송에 실패했습니다.'),
          );
        }
      },
    );
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw Exception('서버 응답이 없습니다. 연결 상태를 확인해주세요.'),
    );
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
