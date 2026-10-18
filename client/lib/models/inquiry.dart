import '../l10n/tr.dart';

/// 문의 작성 폼(chat_input_bar.dart)의 분류 선택지 — 관리자가 설정하는 값이 아니라 고정
/// 목록이다(직책 목록처럼 팀마다 다를 이유가 없는 값이라 굳이 DB 테이블로 안 뺐다).
final inquiryCategories = [tr('업무'), tr('근태/휴가'), tr('불편사항'), tr('기타')];

/// "팀장에게 문의하기"의 처리 상태 — server/src/inquiries.js와 1:1 대응.
enum InquiryStatus { open, inProgress, resolved }

InquiryStatus _statusFromWire(String s) => switch (s) {
  'in_progress' => InquiryStatus.inProgress,
  'resolved' => InquiryStatus.resolved,
  _ => InquiryStatus.open,
};

String inquiryStatusToWire(InquiryStatus s) => switch (s) {
  InquiryStatus.open => 'open',
  InquiryStatus.inProgress => 'in_progress',
  InquiryStatus.resolved => 'resolved',
};

String inquiryStatusLabel(InquiryStatus s) => switch (s) {
  InquiryStatus.open => tr('대기'),
  InquiryStatus.inProgress => tr('처리중'),
  InquiryStatus.resolved => tr('완료'),
};

/// 팀원이 자기 팀의 "팀장"에게 보낸 문의(미니 티켓) — server/src/inquiries.js 응답과 1:1
/// 대응. 실제 대화 내용은 [roomId] 방에 일반 메시지로도 남아있다(chat_input_bar.dart가 이
/// 문의 생성과 별개로 메시지도 보낸다) — 이 객체는 처리 현황 추적용.
class Inquiry {
  final String id;
  final String teamId;
  final String roomId;
  final String? senderId;
  final String senderName;
  final String? recipientId;
  final String recipientName;
  final String category;
  final String title;
  final String content;
  InquiryStatus status;
  final DateTime createdAt;
  DateTime? statusUpdatedAt;

  /// 첨부(선택) — 없으면 전부 null.
  final String? fileUrl;
  final String? fileName;
  final int? fileSize;
  final String? mimeType;
  final String? thumbnailUrl;

  Inquiry({
    required this.id,
    required this.teamId,
    required this.roomId,
    this.senderId,
    required this.senderName,
    this.recipientId,
    required this.recipientName,
    required this.category,
    required this.title,
    required this.content,
    required this.status,
    required this.createdAt,
    this.statusUpdatedAt,
    this.fileUrl,
    this.fileName,
    this.fileSize,
    this.mimeType,
    this.thumbnailUrl,
  });

  bool get hasAttachment => fileUrl != null;
  bool get attachmentIsImage => mimeType?.startsWith('image/') ?? false;

  factory Inquiry.fromJson(Map<String, dynamic> json) => Inquiry(
    id: json['id'] as String,
    teamId: json['teamId'] as String,
    roomId: json['roomId'] as String,
    senderId: json['senderId'] as String?,
    senderName: json['senderName'] as String,
    recipientId: json['recipientId'] as String?,
    recipientName: json['recipientName'] as String,
    category: json['category'] as String,
    title: json['title'] as String,
    content: json['content'] as String,
    status: _statusFromWire(json['status'] as String),
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    ),
    statusUpdatedAt: json['statusUpdatedAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            (json['statusUpdatedAt'] as num).toInt(),
          ),
    fileUrl: json['fileUrl'] as String?,
    fileName: json['fileName'] as String?,
    fileSize: (json['fileSize'] as num?)?.toInt(),
    mimeType: json['mimeType'] as String?,
    thumbnailUrl: json['thumbnailUrl'] as String?,
  );
}
