/// 대화에서 주고받은 링크 하나("링크" 모아보기 — server/src/links.js). 메시지 하나에 링크가
/// 여러 개면 링크마다 하나씩 온다.
class SharedLink {
  final String id;
  final String messageId;
  final String roomId;
  final String? senderId;
  final String senderName;
  final DateTime createdAt;
  final String url;

  /// 서버가 받아 둔 링크 미리보기(메시지의 첫 번째 주소에만 있다) — 없으면 null.
  final String? title;
  final String? imageUrl;
  final String? siteName;

  const SharedLink({
    required this.id,
    required this.messageId,
    required this.roomId,
    this.senderId,
    required this.senderName,
    required this.createdAt,
    required this.url,
    this.title,
    this.imageUrl,
    this.siteName,
  });

  factory SharedLink.fromJson(Map<String, dynamic> json) => SharedLink(
    id: json['id'] as String,
    messageId: json['messageId'] as String,
    roomId: json['roomId'] as String,
    senderId: json['senderId'] as String?,
    senderName: json['senderName'] as String? ?? '',
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    ),
    url: json['url'] as String,
    title: json['title'] as String?,
    imageUrl: json['imageUrl'] as String?,
    siteName: json['siteName'] as String?,
  );

  /// 주소의 도메인(www. 뗀 것) — 제목이 없을 때 대신 보여준다.
  String get domain {
    final host = Uri.tryParse(url)?.host ?? '';
    final bare = host.startsWith('www.') ? host.substring(4) : host;
    return bare.isEmpty ? url : bare;
  }

  /// 목록에 크게 보일 이름 — 미리보기 제목, 없으면 도메인.
  String get displayTitle {
    final t = title?.trim();
    return t == null || t.isEmpty ? domain : t;
  }
}
