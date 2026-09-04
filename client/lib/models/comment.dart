import 'message.dart';

/// 특정 메시지에 달린 댓글(스레드 답글) 한 건.
class Comment {
  final String id;
  final String messageId;
  final String roomId;
  final String? senderId; // 탈퇴한 사용자의 댓글은 null(messages.senderId와 동일 규칙).
  final String senderName;
  final MessageType type; // text | image | file(system/comment은 안 옴).

  /// 수정하면 그 자리에서 바뀐다(RoomChatController.applyCommentEdit) — 그래서 non-final.
  String? text;
  final String? fileUrl; // 서버 기준 상대 경로. 표시할 땐 Session.resolveUrl로 절대 주소를 만듭니다.

  /// message.dart와 동일 — 비밀 대화에서는 복호화한 뒤 원본 값으로 덮어쓰므로 non-final.
  String? fileName;
  int? fileSize;
  String? mimeType;
  final DateTime createdAt;

  /// 작성 후 5분 이내 본인만 수정 가능(서버가 최종 검증). null이면 수정된 적 없음.
  DateTime? editedAt;

  /// 소프트 삭제됐으면 true — 본문 대신 "삭제된 댓글입니다"를 보여준다. 그 자리에서 바뀌므로 non-final.
  bool deleted;

  /// message.dart의 decryptFailed와 동일한 의미 — 비밀 대화 댓글을 로컬에서 복호화하지 못했을 때.
  bool decryptFailed;

  /// message.dart의 attachmentKey/attachmentNonce와 동일 — 비밀 대화 댓글의 첨부 복호화용.
  String? attachmentKey;
  String? attachmentNonce;

  /// message.dart의 thumbnailUrl/Key/Nonce와 동일한 의미.
  final String? thumbnailUrl;
  String? thumbnailKey;
  String? thumbnailNonce;

  Comment({
    required this.id,
    required this.messageId,
    required this.roomId,
    this.senderId,
    required this.senderName,
    this.type = MessageType.text,
    this.text,
    this.fileUrl,
    this.fileName,
    this.fileSize,
    this.mimeType,
    required this.createdAt,
    this.editedAt,
    this.deleted = false,
    this.decryptFailed = false,
    this.attachmentKey,
    this.attachmentNonce,
    this.thumbnailUrl,
    this.thumbnailKey,
    this.thumbnailNonce,
  });

  factory Comment.fromJson(Map<String, dynamic> json) {
    return Comment(
      id: json['id'] as String,
      messageId: json['messageId'] as String,
      roomId: json['roomId'] as String,
      senderId: json['senderId'] as String?,
      senderName: json['senderName'] as String,
      type: json['type'] == 'image'
          ? MessageType.image
          : json['type'] == 'file'
          ? MessageType.file
          : json['type'] == 'sticker'
          ? MessageType.sticker
          : MessageType.text,
      text: json['text'] as String?,
      fileUrl: json['fileUrl'] as String?,
      fileName: json['fileName'] as String?,
      fileSize: (json['fileSize'] as num?)?.toInt(),
      mimeType: json['mimeType'] as String?,
      thumbnailUrl: json['thumbnailUrl'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num).toInt(),
      ),
      editedAt: (json['editedAt'] as num?) != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (json['editedAt'] as num).toInt(),
            )
          : null,
      deleted: json['deleted'] as bool? ?? false,
    );
  }

}
