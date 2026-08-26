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
  final String? senderId; // 시스템 메시지는 작성자가 없어서 null(서버 rooms.js의 postSystemMessage 참고).
  final String senderName;
  final MessageType type;

  /// 수정하면 그 자리에서 바뀐다(RoomChatController.applyEdit) — 그래서 non-final.
  String? text;
  final String? fileUrl; // 서버 기준 상대 경로. 표시할 땐 Session.resolveUrl로 절대 주소를 만듭니다.
  final String? fileName;
  final int? fileSize;
  final String? mimeType;
  final DateTime createdAt;

  /// 작성 후 5분 이내 본인만 수정 가능(서버가 최종 검증). null이면 수정된 적 없음.
  DateTime? editedAt;

  /// 소프트 삭제됐으면 true — 본문 대신 "삭제된 메시지입니다"를 보여준다. 그 자리에서 바뀌므로 non-final.
  bool deleted;

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
      createdAt: DateTime.fromMillisecondsSinceEpoch((json['createdAt'] as num).toInt()),
      editedAt: (json['editedAt'] as num?) != null
          ? DateTime.fromMillisecondsSinceEpoch((json['editedAt'] as num).toInt())
          : null,
      deleted: json['deleted'] as bool? ?? false,
      comments: (json['comments'] as List?)?.map((e) => Comment.fromJson(e as Map<String, dynamic>)).toList(),
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
