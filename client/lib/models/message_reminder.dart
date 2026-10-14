// 메시지 리마인더("나중에 알림" — server/src/reminders.js).
//
// 정한 시각이 되면 서버가 "나와의 대화"에 탱고톡 봇 메시지로 원본 메시지 카드([ReminderCard])를 올린다. 앱은 카드의
// "메시지로 이동"으로 원본을 연다.

/// 리마인더가 울릴 때 올라오는 카드 — 원본 메시지의 스냅샷.
class ReminderCard {
  final String messageId;
  final String roomId;

  /// 이름 있는 방(토픽·이름 붙인 그룹)만 — 없으면 앱이 자기 방 목록에서 이름을 정한다.
  final String? roomName;
  final String? senderName;

  /// 한 줄 미리보기 — 비밀 대화면 null.
  final String? preview;
  final DateTime? sentAt;
  final bool secret;

  const ReminderCard({
    required this.messageId,
    required this.roomId,
    this.roomName,
    this.senderName,
    this.preview,
    this.sentAt,
    this.secret = false,
  });

  static ReminderCard? fromJson(Object? json) {
    if (json is! Map) return null;
    final messageId = json['messageId'];
    final roomId = json['roomId'];
    if (messageId is! String || roomId is! String) return null;
    final sentAt = json['sentAt'];
    return ReminderCard(
      messageId: messageId,
      roomId: roomId,
      roomName: json['roomName'] as String?,
      senderName: json['senderName'] as String?,
      preview: json['preview'] as String?,
      sentAt: sentAt is num
          ? DateTime.fromMillisecondsSinceEpoch(sentAt.toInt())
          : null,
      secret: json['secret'] == true,
    );
  }
}

/// 아직 울리지 않은 내 리마인더(GET /api/reminders) — 두 가지다.
/// - 메시지 리마인더("나중에 알림"): [messageId]·[roomId]가 있고, 원본의 [senderName]·[preview]·[sentAt]이 붙는다.
/// - 직접 만든 리마인더(메뉴의 "리마인더" — [isMemo]): 메시지 없이 [text]와 울릴 "나와의 대화"의 팀([teamId])만 있다.
class MessageReminder {
  final String id;
  final String? messageId;
  final String? roomId;
  final String? teamId;

  /// 직접 만든 리마인더의 글.
  final String? text;
  final DateTime remindAt;
  final DateTime? createdAt;
  final String? senderName;

  /// 한 줄 미리보기 — 비밀 대화면 null.
  final String? preview;
  final DateTime? sentAt;

  const MessageReminder({
    required this.id,
    this.messageId,
    this.roomId,
    this.teamId,
    this.text,
    required this.remindAt,
    this.createdAt,
    this.senderName,
    this.preview,
    this.sentAt,
  });

  /// 메시지 없이 직접 만든 리마인더인지.
  bool get isMemo => messageId == null;

  factory MessageReminder.fromJson(Map<String, dynamic> json) {
    final sentAt = json['sentAt'];
    final createdAt = json['createdAt'];
    return MessageReminder(
      id: json['id'] as String,
      messageId: json['messageId'] as String?,
      roomId: json['roomId'] as String?,
      teamId: json['teamId'] as String?,
      text: json['text'] as String?,
      createdAt: createdAt is num
          ? DateTime.fromMillisecondsSinceEpoch(createdAt.toInt())
          : null,
      remindAt: DateTime.fromMillisecondsSinceEpoch(
        (json['remindAt'] as num).toInt(),
      ),
      senderName: json['senderName'] as String?,
      preview: json['preview'] as String?,
      sentAt: sentAt is num
          ? DateTime.fromMillisecondsSinceEpoch(sentAt.toInt())
          : null,
    );
  }
}

/// "나중에 알림"의 빠른 선택지 — [now] 기준 시각. "내일 오전 9시", "다음 주 월요일 오전 9시"는 이 기기 시각 기준.
List<({String label, DateTime at})> reminderPresets(DateTime now) => [
  (label: '20분 뒤', at: now.add(const Duration(minutes: 20))),
  (label: '1시간 뒤', at: now.add(const Duration(hours: 1))),
  (label: '3시간 뒤', at: now.add(const Duration(hours: 3))),
  (label: '내일 오전 9시', at: DateTime(now.year, now.month, now.day + 1, 9)),
  (
    label: '다음 주 월요일 오전 9시',
    at: DateTime(now.year, now.month, now.day + 8 - now.weekday, 9),
  ),
];
