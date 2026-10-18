import 'text_format.dart';
import '../l10n/tr.dart';

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

  /// [text]에 걸린 글자 서식 구간(공지 쓰기 창의 서식 도구모음 — 굵게·제목·글자색 등, 서버 textFormat.js).
  /// 없으면 null(평문). 수정하면 [text]와 함께 바뀐다 — 화면은 FormattedText(text, format: textFormat)로 그린다.
  List<TextFormatRun>? textFormat;
  DateTime? editedAt;
  bool pinned;
  int commentCount;

  /// "공지 자동 내리기"로 고른 시각(없으면 null — 기본값, 자동으로 안 내려감). 작성 시점에만
  /// 정해지고 이후 바뀌지 않는다(edit은 text만 바꿀 수 있음) — 실제로 내려가면(서버의 주기적
  /// 스윕) pinned가 false로 바뀌는 것으로 반영된다(이 값 자체는 기록으로 남아 그대로 있음).
  final DateTime? autoUnpinAt;

  /// "메시지 더보기 > 공지 등록"으로 만든 공지의 원본 메시지 id(원본이 지워졌거나 직접 쓴 공지면 null) —
  /// 말풍선에 작은 "공지" 표시를 붙이는 데 쓴다.
  final String? messageId;

  /// 이미지 메시지를 공지로 등록했을 때의 사진 한 장(서명된 /files 경로 — Session.resolveUrl로 절대 주소)과
  /// 그 축소본·파일 이름. 글만 있는 공지는 모두 null. 사진만 있는 공지는 [text]가 빈 문자열이다.
  final String? imageUrl;
  final String? imageThumbnailUrl;
  final String? imageName;

  bool get hasImage => imageUrl != null;

  /// 배너·알림처럼 한 줄로 보여줄 글 — 사진만 있는 공지는 "[사진]".
  String get previewText => text.trim().isEmpty && hasImage ? tr('[사진]') : text;

  /// 이 인스턴스를 만들 때(서버 응답) 받은 댓글 수 — [liveCommentCount]의 기준점.
  final int _baseCommentCount;

  /// 만든 뒤 실시간(announcement:comment:new)으로 들어온 댓글 id들 — Session이 방 상단 공지(Room.latestAnnouncement)에
  /// 대해 [noteLiveComment]로 모은다. 같은 id는 한 번만 센다.
  final Set<String> _liveCommentIds = {};

  /// 공지바(announcement_banner.dart)에 보여줄 댓글 수 — 서버가 준 수 + 실시간으로 들어온 새 댓글 수.
  /// 상세보기가 같은 인스턴스의 [commentCount]를 직접 올리기도 해서(열어 둔 동안 들어온 댓글) 둘 중 큰 값을 쓴다
  /// — 같은 댓글이 양쪽에서 두 번 세지지 않는다.
  int get liveCommentCount {
    final live =
        _baseCommentCount + _liveCommentIds.length - _deletedCommentIds.length;
    final count = live > commentCount ? live : commentCount;
    return count < 0 ? 0 : count;
  }

  /// 실시간으로 들어온 댓글 하나를 센다 — 처음 보는 id면 true(다시 그려야 함).
  bool noteLiveComment(String commentId) => _liveCommentIds.add(commentId);

  /// 만든 뒤 지워진(announcement:comment:deleted) 댓글 id들 — [liveCommentCount]에서 뺀다.
  final Set<String> _deletedCommentIds = {};

  /// 지워진 댓글 하나를 센다 — 처음 보는 id면 true(다시 그려야 함). 상세보기는 같은 인스턴스의 [commentCount]도 하나
  /// 내리므로(그 댓글을 목록에 들고 있었을 때) 둘이 어긋나지 않는다.
  bool noteDeletedComment(String commentId) =>
      _deletedCommentIds.add(commentId);

  Announcement({
    required this.id,
    required this.roomId,
    this.authorId,
    required this.authorName,
    required this.text,
    this.textFormat,
    required this.createdAt,
    this.editedAt,
    this.pinned = true,
    this.commentCount = 0,
    this.autoUnpinAt,
    this.messageId,
    this.imageUrl,
    this.imageThumbnailUrl,
    this.imageName,
  }) : _baseCommentCount = commentCount;

  factory Announcement.fromJson(Map<String, dynamic> json) => Announcement(
    id: json['id'] as String,
    roomId: json['roomId'] as String,
    authorId: json['authorId'] as String?,
    authorName: json['authorName'] as String,
    text: json['text'] as String,
    textFormat: parseTextFormat(json['textFormat']),
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    ),
    editedAt: json['editedAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            (json['editedAt'] as num).toInt(),
          ),
    pinned: json['pinned'] as bool? ?? true,
    commentCount: (json['commentCount'] as num?)?.toInt() ?? 0,
    autoUnpinAt: json['autoUnpinAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            (json['autoUnpinAt'] as num).toInt(),
          ),
    messageId: json['messageId'] as String?,
    imageUrl: json['imageUrl'] as String?,
    imageThumbnailUrl: json['imageThumbnailUrl'] as String?,
    imageName: json['imageName'] as String?,
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

  /// 고친 시각 — 안 고쳤으면 null(`(수정됨)` 표시).
  final DateTime? editedAt;

  const AnnouncementComment({
    required this.id,
    required this.announcementId,
    required this.roomId,
    this.authorId,
    required this.authorName,
    required this.text,
    required this.createdAt,
    this.editedAt,
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
        editedAt: json['editedAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (json['editedAt'] as num).toInt(),
              ),
      );
}

/// 공지 읽음 확인 — 이 방 멤버 중 읽은 사람(먼저 읽은 순)과 아직 안 읽은 사람(이름순). 서버 GET
/// /rooms/:id/announcements/:announcementId/readers(server/src/announcementReadRules.js — 공지가 올라온 뒤 공지 목록·상세를 연 사람이
/// 읽은 쪽, 쓴 사람은 늘 읽은 쪽).
class AnnouncementReaders {
  final List<({String userId, String name, DateTime readAt})> read;
  final List<({String userId, String name})> unread;

  const AnnouncementReaders({required this.read, required this.unread});

  /// [userId]를 읽은 쪽으로 옮긴 것 — 지금 이 공지를 열어 보고 있는 나(서버에 읽음이 닿기 전에 받은 목록이어도).
  AnnouncementReaders markRead(String? userId, DateTime at) {
    final me = unread.where((r) => r.userId == userId).firstOrNull;
    if (me == null) return this;
    return AnnouncementReaders(
      read: [...read, (userId: me.userId, name: me.name, readAt: at)],
      unread: [
        for (final r in unread)
          if (r.userId != userId) r,
      ],
    );
  }

  factory AnnouncementReaders.fromJson(Map<String, dynamic> j) =>
      AnnouncementReaders(
        read: [
          for (final r in (j['read'] as List? ?? const []))
            if (r is Map && r['userId'] is String)
              (
                userId: r['userId'] as String,
                name: r['name'] as String? ?? '',
                readAt: DateTime.fromMillisecondsSinceEpoch(
                  (r['readAt'] as num?)?.toInt() ?? 0,
                ),
              ),
        ],
        unread: [
          for (final r in (j['unread'] as List? ?? const []))
            if (r is Map && r['userId'] is String)
              (userId: r['userId'] as String, name: r['name'] as String? ?? ''),
        ],
      );
}
