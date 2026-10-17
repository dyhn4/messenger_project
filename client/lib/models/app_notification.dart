// 알림 센터의 서버 알림(멘션·보드) — 범용 notifications 표의 한 줄. 프로젝트 알림
// (ProjectNotification)과 안 읽은 대화는 기존 모델·Room을 그대로 쓴다. 규약: CONTRACT_NOTIF.md.

/// 서버 알림 종류(kind 문자열). 문자열이라 서버가 새 종류를 더해도 깨지지 않는다 — 모르는 종류는
/// [other]로 읽고 그냥 보여 준다.
enum NotificationKind {
  mention,
  mentionAll,
  boardPost,
  boardEdit,
  boardComment,
  other,
}

NotificationKind notificationKindFromWire(String? s) => switch (s) {
  'mention' => NotificationKind.mention,
  'mention_all' => NotificationKind.mentionAll,
  'board_post' => NotificationKind.boardPost,
  'board_edit' => NotificationKind.boardEdit,
  'board_comment' => NotificationKind.boardComment,
  _ => NotificationKind.other,
};

class AppNotification {
  final String id;
  final NotificationKind kind;

  /// 서버가 준 원래 kind 문자열(모르는 종류도 그대로 남는다).
  final String kindWire;
  final String teamId;
  final String? teamName;
  final String? roomId;
  final String? roomName;
  final String? roomType;
  final String? messageId;
  final String? commentId;
  final String? actorId;
  final String? actorName;
  final String preview;
  final DateTime createdAt;

  /// 읽은 시각 — null이면 안 읽음. 읽으면 그 자리에서 바뀐다(NotificationController.markRead).
  DateTime? readAt;

  AppNotification({
    required this.id,
    required this.kind,
    String? kindWire,
    required this.teamId,
    this.teamName,
    this.roomId,
    this.roomName,
    this.roomType,
    this.messageId,
    this.commentId,
    this.actorId,
    this.actorName,
    this.preview = '',
    required this.createdAt,
    this.readAt,
  }) : kindWire = kindWire ?? _wireOf(kind);

  static String _wireOf(NotificationKind k) => switch (k) {
    NotificationKind.mention => 'mention',
    NotificationKind.mentionAll => 'mention_all',
    NotificationKind.boardPost => 'board_post',
    NotificationKind.boardEdit => 'board_edit',
    NotificationKind.boardComment => 'board_comment',
    NotificationKind.other => 'other',
  };

  factory AppNotification.fromJson(Map<String, dynamic> json) {
    final wire = json['kind'] as String?;
    return AppNotification(
      id: json['id'] as String,
      kind: notificationKindFromWire(wire),
      kindWire: wire,
      teamId: json['teamId'] as String? ?? '',
      teamName: json['teamName'] as String?,
      roomId: json['roomId'] as String?,
      roomName: json['roomName'] as String?,
      roomType: json['roomType'] as String?,
      messageId: json['messageId'] as String?,
      commentId: json['commentId'] as String?,
      actorId: json['actorId'] as String?,
      actorName: json['actorName'] as String?,
      preview: json['preview'] as String? ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num).toInt(),
      ),
      readAt: (json['readAt'] as num?) == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (json['readAt'] as num).toInt(),
            ),
    );
  }

  bool get isRead => readAt != null;

  bool get isMention =>
      kind == NotificationKind.mention || kind == NotificationKind.mentionAll;

  /// 보드 알림(새 글·수정·댓글) — 알림 센터 "보드·공지" 탭에 들어간다.
  bool get isBoard => kindWire.startsWith('board_');
}

/// 탭 배지용 안 읽음 개수 — 서버 `GET /notifications/unread-counts`, 소켓 `notification:sync`와
/// `notification:new`의 unread가 이 모양이다.
class NotificationCounts {
  /// 안 읽은 멘션 합계(개인 멘션 + `@all`).
  final int mention;
  final int board;

  /// 안 읽은 개인 멘션(`@나를 멘션`)과 `@all` 멘션 — 멘션 탭의 드롭다운 필터가 종류별 배지에 쓴다. 서버가
  /// 안 주거나 생략하면(옛 서버·옛 호출) 멘션 합계를 전부 개인 멘션으로 본다.
  final int mentionPersonal;
  final int mentionAll;

  const NotificationCounts({
    this.mention = 0,
    this.board = 0,
    int? mentionPersonal,
    int? mentionAll,
  }) : mentionPersonal = mentionPersonal ?? (mentionAll == null ? mention : 0),
       mentionAll = mentionAll ?? 0;

  /// 종류별 개수에서 합계를 맞춰 만든다.
  factory NotificationCounts.of({
    int mentionPersonal = 0,
    int mentionAll = 0,
    int board = 0,
  }) => NotificationCounts(
    mention: mentionPersonal + mentionAll,
    board: board,
    mentionPersonal: mentionPersonal,
    mentionAll: mentionAll,
  );

  factory NotificationCounts.fromJson(Object? json) {
    if (json is! Map) return const NotificationCounts();
    final personal = (json['mentionPersonal'] as num?)?.toInt();
    final all = (json['mentionAll'] as num?)?.toInt();
    return NotificationCounts(
      mention:
          (json['mention'] as num?)?.toInt() ?? (personal ?? 0) + (all ?? 0),
      board: (json['board'] as num?)?.toInt() ?? 0,
      mentionPersonal: personal,
      mentionAll: all,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NotificationCounts &&
      other.mention == mention &&
      other.board == board &&
      other.mentionPersonal == mentionPersonal &&
      other.mentionAll == mentionAll;

  @override
  int get hashCode => Object.hash(mention, board, mentionPersonal, mentionAll);
}

/// 소켓 `notification:new` — 새 알림 한 건과 그 뒤의 안 읽음 개수.
class NotificationNewEvent {
  final AppNotification notification;
  final NotificationCounts? unread;
  const NotificationNewEvent(this.notification, this.unread);

  factory NotificationNewEvent.fromJson(Map<String, dynamic> json) =>
      NotificationNewEvent(
        AppNotification.fromJson(
          Map<String, dynamic>.from(json['notification'] as Map),
        ),
        json['unread'] is Map
            ? NotificationCounts.fromJson(json['unread'])
            : null,
      );
}

/// 보드 알림 수준 — 서버 `boardLevel`. 기본은 [important](새 글 + 내가 쓴 글에 달린 댓글).
enum BoardNotifyLevel { all, important, newPosts }

BoardNotifyLevel boardLevelFromWire(String? s) => switch (s) {
  'all' => BoardNotifyLevel.all,
  'new' => BoardNotifyLevel.newPosts,
  _ => BoardNotifyLevel.important,
};

extension BoardNotifyLevelInfo on BoardNotifyLevel {
  String get wire => switch (this) {
    BoardNotifyLevel.all => 'all',
    BoardNotifyLevel.important => 'important',
    BoardNotifyLevel.newPosts => 'new',
  };

  String get label => switch (this) {
    BoardNotifyLevel.all => '전체',
    BoardNotifyLevel.important => '중요 알림',
    BoardNotifyLevel.newPosts => '새 글 알림',
  };

  String get description => switch (this) {
    BoardNotifyLevel.all => '새 글, 글 수정, 댓글 알림을 모두 받습니다.',
    BoardNotifyLevel.important => '새 글과 내가 쓴 글에 달린 댓글 알림을 받습니다.',
    BoardNotifyLevel.newPosts => '새 글 알림만 받습니다.',
  };
}

/// 내 알림 설정 — 서버 `GET/PATCH /notification-settings`.
class NotificationSettings {
  final bool mentionAll;
  final BoardNotifyLevel boardLevel;

  /// 다른 기기(PC 앱 등)로 접속해 있어도 접속해 있지 않은 기기(휴대폰)로 푸시를 받을지 — 끄면 어느 기기로든 접속해 있는
  /// 동안은 푸시가 오지 않는다(server/src/presence.js의 skipsPush). 이 값이 없는 예전 서버는 늘 "끔"처럼 동작한다.
  final bool pushWhileOnline;

  /// 오래 접속하지 않았을 때 안 읽은 멘션을 메일로 요약해 받을지(server/src/mentionDigest.js) — 서버에 메일이 켜져 있고
  /// 이메일을 확인한 사람만 실제로 받는다. 이 값이 없는 예전 서버는 켬으로 읽는다(그 서버는 요약 메일을 보내지 않는다).
  final bool emailDigest;
  const NotificationSettings({
    this.mentionAll = true,
    this.boardLevel = BoardNotifyLevel.important,
    this.pushWhileOnline = true,
    this.emailDigest = true,
  });

  factory NotificationSettings.fromJson(Map<String, dynamic> json) =>
      NotificationSettings(
        mentionAll: json['mentionAll'] as bool? ?? true,
        boardLevel: boardLevelFromWire(json['boardLevel'] as String?),
        pushWhileOnline: json['pushWhileOnline'] as bool? ?? true,
        emailDigest: json['emailDigest'] as bool? ?? true,
      );

  NotificationSettings copyWith({
    bool? mentionAll,
    BoardNotifyLevel? boardLevel,
    bool? pushWhileOnline,
    bool? emailDigest,
  }) => NotificationSettings(
    mentionAll: mentionAll ?? this.mentionAll,
    boardLevel: boardLevel ?? this.boardLevel,
    pushWhileOnline: pushWhileOnline ?? this.pushWhileOnline,
    emailDigest: emailDigest ?? this.emailDigest,
  );
}
