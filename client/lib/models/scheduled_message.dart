import 'mention.dart';
import 'message.dart';
import 'text_format.dart';
import 'uploaded_attachment.dart';
import '../l10n/tr.dart';

/// 메시지 예약 발송의 한도 — 서버 /scheduled-messages가 같은 값으로 다시 검사한다.
const scheduledMessageMaxCount = 30; // 한 사람이 한 팀에 둘 수 있는 예약(예약됨 + 발송 실패)
const scheduledTextMaxLength = 5000; // 메시지(보드 뷰 토픽이면 게시글 본문) 글자 수
const scheduledTitleMaxLength = 50; // 제목 — 보드 뷰 토픽에 올릴 게시글에만 쓴다
const scheduledAttachmentMaxCount = 10;
const scheduledMaxDaysAhead = 90;
const scheduledSlotMinutes = 15; // 발송 시간은 15분 단위로만 고른다

/// 서버 status 문자열. 'sending'은 발송 스케줄러가 막 집어 간 짧은 순간(또는 이 기기의 "지금 보내기"
/// 응답을 기다리는 동안)에만 보인다.
enum ScheduledMessageStatus { scheduled, sending, failed }

/// 모르는 값·예전 서버(값 없음)면 '예약됨'으로 읽는다.
ScheduledMessageStatus scheduledStatusFromWire(String? s) => switch (s) {
  'failed' => ScheduledMessageStatus.failed,
  'sending' => ScheduledMessageStatus.sending,
  _ => ScheduledMessageStatus.scheduled,
};

/// ms 숫자(서버 DTO)가 기본이지만 ISO 문자열이 와도 읽는다.
DateTime? _timeFromJson(Object? v) {
  if (v is num) return DateTime.fromMillisecondsSinceEpoch(v.toInt());
  if (v is String) return DateTime.tryParse(v)?.toLocal();
  return null;
}

/// 내가 예약한 메시지 한 건(서버 scheduled_messages) — 나만 보고 바꿀 수 있다. 보내지면 서버가 행을
/// 지우고(목록에서 사라짐), 실패하면 [failReason]과 함께 '발송 실패'로 남는다. 값이 바뀌면 Session이
/// 새 인스턴스로 갈아 끼우므로 전부 final이다([withStatus]).
class ScheduledMessage {
  final String id;
  final String teamId;

  /// 보낼 대화방. 그 방이 삭제되면 null이 된다(서버 on delete set null) — 이름은 [roomName]으로 본다.
  final String? roomId;

  /// 예약할 때의 대화방 이름(표시용 스냅샷). 지금 보이는 이름은 Session.scheduledRoomName.
  final String? roomName;

  /// 보드 뷰 토픽에 올릴 게시글 제목 — 그 밖의 대화방이면 null.
  final String? title;

  /// 메시지(게시글이면 본문).
  final String text;
  final List<TextFormatRun>? textFormat;

  /// [text] 안의 멘션 구간 — 보내지는 순간 서버가 방 멤버인지 다시 확인한다.
  final List<Mention> mentions;

  /// 같이 보낼 첨부 — 메시지 첨부처럼 서명된 링크로 온다. 고쳐서 다시 보낼 땐 [uploadedAttachments].
  final List<MessageAttachment> attachments;
  final DateTime sendAt;
  final ScheduledMessageStatus status;

  /// 발송 실패 사유(서버 문구 그대로) — 실패가 아니면 null.
  final String? failReason;
  final DateTime createdAt;
  final DateTime updatedAt;

  ScheduledMessage({
    required this.id,
    required this.teamId,
    this.roomId,
    this.roomName,
    this.title,
    required this.text,
    this.textFormat,
    this.mentions = const [],
    this.attachments = const [],
    required this.sendAt,
    this.status = ScheduledMessageStatus.scheduled,
    this.failReason,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? sendAt,
       updatedAt = updatedAt ?? createdAt ?? sendAt;

  factory ScheduledMessage.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    final sendAt = _timeFromJson(json['sendAt']) ?? DateTime.now();
    final createdAt = _timeFromJson(json['createdAt']);
    final title = json['title'] as String?;
    final attachments = <MessageAttachment>[];
    final raw = json['attachments'];
    if (raw is List) {
      for (final (i, e) in raw.indexed) {
        if (e is! Map || e['fileUrl'] is! String) continue;
        // 예약 첨부는 아직 메시지 첨부 행이 아니라 id가 없을 수 있다 — 목록 안에서만 겹치지 않으면 된다.
        final map = Map<String, dynamic>.from(e);
        if (map['id'] is! String) map['id'] = '$id#$i';
        attachments.add(MessageAttachment.fromJson(map));
      }
    }
    return ScheduledMessage(
      id: id,
      teamId: json['teamId'] as String? ?? '',
      roomId: json['roomId'] as String?,
      roomName: json['roomName'] as String?,
      title: title == null || title.isEmpty ? null : title,
      text: json['text'] as String? ?? '',
      textFormat: parseTextFormat(json['textFormat']),
      mentions: parseMentions(json['mentions']),
      attachments: attachments,
      sendAt: sendAt,
      status: scheduledStatusFromWire(json['status'] as String?),
      failReason: json['failReason'] as String?,
      createdAt: createdAt,
      updatedAt: _timeFromJson(json['updatedAt']),
    );
  }

  bool get isFailed => status == ScheduledMessageStatus.failed;
  bool get isSending => status == ScheduledMessageStatus.sending;

  /// 아직 보낼 차례를 기다리는 예약(실패도, 보내는 중도 아님).
  bool get isScheduled => status == ScheduledMessageStatus.scheduled;

  /// 보드 뷰 토픽에 올라갈 게시글 예약인지.
  bool get isPost => title != null;

  /// 목록의 두 줄 미리보기 — 게시글은 제목, 그 밖엔 메시지.
  String get preview => title ?? text;

  /// 고쳐서 다시 보낼 때(Session.updateScheduledMessage의 attachments) 쓰는 첨부 모양.
  List<UploadedAttachment> get uploadedAttachments => [
    for (final a in attachments) UploadedAttachment.fromMessageAttachment(a),
  ];

  /// 상태만 바꾼 사본 — 발송 결과(scheduled:sent/failed)나 "지금 보내기"를 그 자리에서 반영할 때.
  /// [failReason]은 실패일 때만 남긴다.
  ScheduledMessage withStatus(
    ScheduledMessageStatus status, {
    String? failReason,
  }) => ScheduledMessage(
    id: id,
    teamId: teamId,
    roomId: roomId,
    roomName: roomName,
    title: title,
    text: text,
    textFormat: textFormat,
    mentions: mentions,
    attachments: attachments,
    sendAt: sendAt,
    status: status,
    failReason: status == ScheduledMessageStatus.failed ? failReason : null,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

/// 예약 목록 순서 — 발송 실패 먼저, 그다음 발송 시각이 이른 순(서버 GET과 같다).
int compareScheduledMessages(ScheduledMessage a, ScheduledMessage b) {
  if (a.isFailed != b.isFailed) return a.isFailed ? -1 : 1;
  final bySendAt = a.sendAt.compareTo(b.sendAt);
  if (bySendAt != 0) return bySendAt;
  final byCreated = a.createdAt.compareTo(b.createdAt);
  return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
}

enum ScheduledMessageEventType { sent, failed }

/// 예약 메시지의 발송 결과(소켓 scheduled:sent / scheduled:failed, 이 기기의 "지금 보내기" 성공) —
/// Session.scheduledMessageEvents로 흘러서 루트 화면이 [toastText]로 알린다. 다른 팀 예약도 흐른다
/// ([teamId]로 구분).
class ScheduledMessageEvent {
  final ScheduledMessageEventType type;
  final String id;
  final String? teamId;
  final String? roomId;

  /// 대화방 이름 — Session이 내 목록의 지금 이름(없으면 서버가 준 스냅샷)으로 채워서 흘린다.
  final String? roomName;

  /// 실패 사유(실패일 때만).
  final String? reason;

  /// 보내진 메시지 id들(성공일 때만).
  final List<String> messageIds;

  const ScheduledMessageEvent({
    required this.type,
    required this.id,
    this.teamId,
    this.roomId,
    this.roomName,
    this.reason,
    this.messageIds = const [],
  });

  /// scheduled:sent `{id, teamId, roomId, roomName, messageIds}`.
  factory ScheduledMessageEvent.fromSentJson(Map<String, dynamic> json) =>
      ScheduledMessageEvent(
        type: ScheduledMessageEventType.sent,
        id: json['id'] as String? ?? '',
        teamId: json['teamId'] as String?,
        roomId: json['roomId'] as String?,
        roomName: json['roomName'] as String?,
        messageIds:
            (json['messageIds'] as List?)?.whereType<String>().toList() ??
            const [],
      );

  /// scheduled:failed `{id, teamId, roomId, roomName, reason}`.
  factory ScheduledMessageEvent.fromFailedJson(Map<String, dynamic> json) =>
      ScheduledMessageEvent(
        type: ScheduledMessageEventType.failed,
        id: json['id'] as String? ?? '',
        teamId: json['teamId'] as String?,
        roomId: json['roomId'] as String?,
        roomName: json['roomName'] as String?,
        reason: json['reason'] as String?,
      );

  bool get isSent => type == ScheduledMessageEventType.sent;
  bool get isFailed => type == ScheduledMessageEventType.failed;

  String get _roomLabel {
    final name = roomName?.trim();
    return name == null || name.isEmpty ? tr('대화방') : name;
  }

  /// 토스트에 그대로 쓰는 안내 문구.
  String get toastText => isSent
      ? tr('예약 메시지를 보냈습니다 · {_roomLabel}', {'_roomLabel': _roomLabel})
      : tr('예약 메시지를 보내지 못했습니다 ({_roomLabel}): {p0}', {
          '_roomLabel': _roomLabel,
          'p0': reason ?? tr('알 수 없는 오류'),
        });

  /// 같은 결과(같은 방·같은 사유)가 [count]건 한꺼번에 왔을 때의 문구 — 토픽 보관·방 삭제면 그 방
  /// 예약이 모두 한 번에 실패한다. 1건이면 [toastText].
  String toastTextFor(int count) {
    if (count <= 1) return toastText;
    return isSent
        ? tr('예약 메시지 {count}건을 보냈습니다 · {_roomLabel}', {
            'count': count,
            '_roomLabel': _roomLabel,
          })
        : tr('예약 메시지 {count}건을 보내지 못했습니다 ({_roomLabel}): {p0}', {
            'count': count,
            '_roomLabel': _roomLabel,
            'p0': reason ?? tr('알 수 없는 오류'),
          });
  }

  ScheduledMessageEvent withRoomName(String? name) => ScheduledMessageEvent(
    type: type,
    id: id,
    teamId: teamId,
    roomId: roomId,
    roomName: name,
    reason: reason,
    messageIds: messageIds,
  );
}

// ───────────────────── 발송 시각·입력 검사(서버와 같은 규칙·문구) ─────────────────────

/// 예약 발송 시각으로 쓸 수 있는 15분 단위 시각인지(초 이하는 0이어야 한다).
bool isScheduleSlot(DateTime t) =>
    t.minute % scheduledSlotMinutes == 0 &&
    t.second == 0 &&
    t.millisecond == 0 &&
    t.microsecond == 0;

/// [t] 이후(이미 15분 단위면 그대로)의 가장 가까운 15분 단위 시각(현지 시각).
DateTime ceilToScheduleSlot(DateTime t) {
  final local = t.toLocal();
  final floor = DateTime(
    local.year,
    local.month,
    local.day,
    local.hour,
    local.minute - local.minute % scheduledSlotMinutes,
  );
  return isScheduleSlot(local)
      ? floor
      : floor.add(const Duration(minutes: scheduledSlotMinutes));
}

/// 새 예약의 기본 발송 시각 — 지금부터 15분 뒤 이후의 가장 가까운 15분 단위.
DateTime defaultScheduleTime([DateTime? now]) => ceilToScheduleSlot(
  (now ?? DateTime.now()).add(const Duration(minutes: scheduledSlotMinutes)),
);

/// 예약할 수 있는 가장 늦은 시각(지금부터 90일 뒤) — 날짜 고르기의 끝.
DateTime latestScheduleTime([DateTime? now]) =>
    (now ?? DateTime.now()).add(const Duration(days: scheduledMaxDaysAhead));

/// 발송 시각 검사 — 괜찮으면 null, 아니면 서버와 같은 안내 문구.
String? validateScheduledSendAt(DateTime sendAt, {DateTime? now}) {
  final current = now ?? DateTime.now();
  if (!isScheduleSlot(sendAt)) return tr('발송 시간은 15분 단위로 선택하세요.');
  if (!sendAt.isAfter(current)) return tr('발송 시간은 지금 이후로 선택하세요.');
  if (sendAt.isAfter(latestScheduleTime(current))) {
    return tr('최대 {scheduledMaxDaysAhead}일 뒤까지만 예약할 수 있습니다.', {
      'scheduledMaxDaysAhead': scheduledMaxDaysAhead,
    });
  }
  return null;
}

/// 메시지(게시글이면 본문) 검사 — 앞뒤 공백을 뺀 값을 글자(이모지 한 덩어리 = 1자) 단위로 센다.
String? validateScheduledText(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return tr('메시지를 입력하세요.');
  if (postTextLength(trimmed) > scheduledTextMaxLength) {
    return tr('메시지는 {scheduledTextMaxLength}자 이내로 입력하세요.', {
      'scheduledTextMaxLength': scheduledTextMaxLength,
    });
  }
  return null;
}

/// 제목 검사 — 보드 뷰 토픽이면 꼭 있어야 하고(50자까지), 그 밖의 대화방은 제목을 쓰지 않는다.
String? validateScheduledTitle(String? title, {required bool isBoard}) {
  if (!isBoard) return null;
  final trimmed = title?.trim() ?? '';
  if (trimmed.isEmpty) return tr('제목을 입력하세요.');
  if (postTextLength(trimmed) > scheduledTitleMaxLength) {
    return tr('제목은 {scheduledTitleMaxLength}자 이내로 입력하세요.', {
      'scheduledTitleMaxLength': scheduledTitleMaxLength,
    });
  }
  return null;
}

/// 첨부가 10개를 넘을 때의 안내 — 서버와 같은 문구(편집기가 넘는 만큼 빼고 알릴 때도 쓴다).
final scheduledAttachmentLimitMessage = tr(
  '첨부 파일은 {scheduledAttachmentMaxCount}개까지 올릴 수 있습니다.',
  {'scheduledAttachmentMaxCount': scheduledAttachmentMaxCount},
);

/// 첨부 개수 검사.
String? validateScheduledAttachmentCount(int count) =>
    count > scheduledAttachmentMaxCount
    ? scheduledAttachmentLimitMessage
    : null;
