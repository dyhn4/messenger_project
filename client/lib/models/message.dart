import 'comment.dart';

/// [comment]는 서버가 보내는 실제 메시지 타입이 아니라, 댓글 하나를 채팅 타임라인 안에 그 댓글이
/// 달린 시각 위치에 끼워 넣기 위한 클라이언트 전용 합성(synthetic) 항목이다 — Message.commentEntry로만
/// 만들어지고, 서버 JSON의 type 문자열로는 절대 나오지 않는다(_typeFromString은 이 값을 모른다).
enum MessageType { text, image, file, system, comment }

MessageType _typeFromString(String? s) => switch (s) {
  'image' => MessageType.image,
  'file' => MessageType.file,
  'system' => MessageType.system,
  _ => MessageType.text,
};

class Message {
  final String id;
  final String roomId;
  final String?
  senderId; // 시스템 메시지는 작성자가 없어서 null(서버 rooms.js의 postSystemMessage 참고).
  final String senderName;
  final MessageType type;

  /// 수정하면 그 자리에서 바뀐다(RoomChatController.applyEdit) — 그래서 non-final.
  String? text;
  final String? fileUrl; // 서버 기준 상대 경로. 표시할 땐 Session.resolveUrl로 절대 주소를 만듭니다.

  /// 비밀 대화에서는 서버가 실제 파일명/종류를 못 보게 더미 값("encrypted" 등)만 받고,
  /// 복호화한 뒤 원본 값으로 그 자리에서 덮어쓴다(Session.decryptInPlace 참고) — 그래서 non-final.
  String? fileName;
  int? fileSize;
  String? mimeType;
  final DateTime createdAt;

  /// 작성 후 5분 이내 본인만 수정 가능(서버가 최종 검증). null이면 수정된 적 없음.
  DateTime? editedAt;

  /// 소프트 삭제됐으면 true — 본문 대신 "삭제된 메시지입니다"를 보여준다. 그 자리에서 바뀌므로 non-final.
  bool deleted;

  /// 비밀 대화 메시지인데 로컬에 이 epoch/n을 복호화할 체인키가 없어서(재키잉을 2번 이상
  /// 놓쳤거나 다른 기기에서 온 세션 등) 복호화에 실패했으면 true. text는 이때 null이고
  /// UI는 "🔒 이 메시지는 복호화할 수 없습니다" 플레이스홀더를 보여준다(secret_chat_crypto.dart 참고).
  bool decryptFailed;

  /// 비밀 대화의 이미지/파일 첨부 복호화 키/nonce(base64) — 서버가 갖고 있는 fileUrl은 암호화된
  /// 바이트라, 실제로 보여주려면 다운로드 후 이 키로 한 번 더 복호화해야 한다(secret_chat_crypto.dart
  /// decryptAttachment 참고). 비밀 대화가 아니면 항상 null.
  String? attachmentKey;
  String? attachmentNonce;

  /// 비밀 대화 자동 삭제 타이머용 — 상대가 이 메시지를 읽은 시각(null이면 아직 안 읽음)과,
  /// 그때부터 방의 타이머(초)만큼 지나 삭제될 시각. secret:message-read 브로드캐스트로 그 자리에서
  /// 채워지므로(RoomChatController.applyMessageRead) non-final. 평문 방 메시지는 항상 둘 다 null.
  DateTime? readAt;
  DateTime? expiresAt;

  /// 이 항목이 실제 메시지가 아니라 댓글 타임라인 합성 항목(type == MessageType.comment)일 때만
  /// 채워진다. 그 댓글의 원본 정보는 그대로 여기 있고, "어느 메시지에 달린 댓글인지"는
  /// asComment.messageId로 알 수 있다.
  final Comment? asComment;

  /// 이 메시지에 달린 댓글들(원본 메시지 쪽에만 채워짐). 서버 응답에는 있을 수도 없을 수도
  /// 있지만(방 메시지 목록 조회에는 포함, 실시간 message:new에는 안 옴 — 새 메시지는 어차피
  /// 댓글이 없으므로), 리스트 자체는 항상 이 메시지 전용으로 새로 만들어서 실시간 댓글이 도착할
  /// 때 그 자리에서 추가한다(RoomChatController.addComment 참고) — 그래서 인스턴스마다 독립된
  /// growable list여야 한다.
  final List<Comment> comments;

  Message({
    required this.id,
    required this.roomId,
    this.senderId,
    required this.senderName,
    required this.type,
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
    this.readAt,
    this.expiresAt,
    this.asComment,
    List<Comment>? comments,
  }) : comments = comments ?? [];

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id: json['id'] as String,
      roomId: json['roomId'] as String,
      senderId: json['senderId'] as String?,
      senderName: json['senderName'] as String,
      type: _typeFromString(json['type'] as String?),
      text: json['text'] as String?,
      fileUrl: json['fileUrl'] as String?,
      fileName: json['fileName'] as String?,
      fileSize: (json['fileSize'] as num?)?.toInt(),
      mimeType: json['mimeType'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num).toInt(),
      ),
      editedAt: (json['editedAt'] as num?) != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (json['editedAt'] as num).toInt(),
            )
          : null,
      deleted: json['deleted'] as bool? ?? false,
      readAt: (json['readAt'] as num?) != null
          ? DateTime.fromMillisecondsSinceEpoch((json['readAt'] as num).toInt())
          : null,
      expiresAt: (json['expiresAt'] as num?) != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (json['expiresAt'] as num).toInt(),
            )
          : null,
      comments: (json['comments'] as List?)
          ?.map((e) => Comment.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// 댓글 하나를 채팅 타임라인에 그 댓글이 달린 시각 위치에 끼워 넣기 위한 합성 항목.
  factory Message.commentEntry(Comment c) {
    return Message(
      id: 'comment:${c.id}',
      roomId: c.roomId,
      senderId: c.senderId,
      senderName: c.senderName,
      type: MessageType.comment,
      createdAt: c.createdAt,
      asComment: c,
    );
  }
}
