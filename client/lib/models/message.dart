enum MessageType { text, image, file, system }

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
  final String? text;
  final String? fileUrl; // 서버 기준 상대 경로. 표시할 땐 Session.resolveUrl로 절대 주소를 만듭니다.
  final String? fileName;
  final int? fileSize;
  final String? mimeType;
  final DateTime createdAt;

  const Message({
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
  });

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
    );
  }
}
