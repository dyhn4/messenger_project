/// 토픽방 공지(카카오톡 공지와 같은 개념) — server/src/announcements.js의 응답과 1:1 대응.
/// 여러 개를 쓸 수 있고(공지 목록 화면이 히스토리를 보여줌), [pinned]인 것(방마다 최대 1개)이
/// 채팅방 상단 배너에 고정된다. text/editedAt/pinned/commentCount는 non-final — 실시간
/// 소켓 이벤트(announcement:updated 등)가 도착하면 그 자리에서 값만 갱신하고
/// notifyListeners()만 부른다(Room.latestAnnouncement와 같은 패턴).
class Announcement {
  final String id;
  final String roomId;
  final String? authorId;
  final String authorName;
  final DateTime createdAt;
  String text;
  DateTime? editedAt;
  bool pinned;
  int commentCount;

  Announcement({
    required this.id,
    required this.roomId,
    this.authorId,
    required this.authorName,
    required this.text,
    required this.createdAt,
    this.editedAt,
    this.pinned = true,
    this.commentCount = 0,
  });

  factory Announcement.fromJson(Map<String, dynamic> json) => Announcement(
    id: json['id'] as String,
    roomId: json['roomId'] as String,
    authorId: json['authorId'] as String?,
    authorName: json['authorName'] as String,
    text: json['text'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    ),
    editedAt: json['editedAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((json['editedAt'] as num).toInt()),
    pinned: json['pinned'] as bool? ?? true,
    commentCount: (json['commentCount'] as num?)?.toInt() ?? 0,
  );
}

/// 공지에 달린 댓글 — server/src/announcements.js 댓글 응답과 1:1 대응.
class AnnouncementComment {
  final String id;
  final String announcementId;
  final String roomId;
  final String? authorId;
  final String authorName;
  final String text;
  final DateTime createdAt;

  const AnnouncementComment({
    required this.id,
    required this.announcementId,
    required this.roomId,
    this.authorId,
    required this.authorName,
    required this.text,
    required this.createdAt,
  });

  factory AnnouncementComment.fromJson(Map<String, dynamic> json) =>
      AnnouncementComment(
        id: json['id'] as String,
        announcementId: json['announcementId'] as String,
        roomId: json['roomId'] as String,
        authorId: json['authorId'] as String?,
        authorName: json['authorName'] as String,
        text: json['text'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (json['createdAt'] as num).toInt(),
        ),
      );
}
