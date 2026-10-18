import '../l10n/tr.dart';

/// 내가 쓴 글 패널의 탭 — 서버 `GET /api/my-posts`의 `kind` 값과 같은 이름이다.
enum MyPostKind { all, message, comment }

extension MyPostKindLabel on MyPostKind {
  String get label => switch (this) {
    MyPostKind.all => tr('전체'),
    MyPostKind.message => tr('메시지'),
    MyPostKind.comment => tr('댓글'),
  };
}

/// 내가 쓴 글 한 줄 — 내가 보낸 메시지(`message`) 또는 내가 단 댓글(`comment`). 댓글이어도 [messageId]는 원본 메시지의 id라
/// 눌러서 그 방의 원본 메시지로 이동할 때 그대로 쓴다.
class MyPost {
  final bool isComment;
  final String id;
  final String messageId;
  final String roomId;
  final String? roomName;
  final String? roomType;
  final String? teamId;

  /// 그 글이 있는 팀의 이름 — "모든 팀"으로 받았을 때 줄마다 팀 칩으로 보인다.
  final String? teamName;

  /// 미리보기용 앞 200자. 게시글은 본문 없이 제목만 있을 수 있어 null일 수 있다.
  final String? text;

  /// 게시글의 제목(그 밖에는 null).
  final String? title;
  final DateTime createdAt;
  final DateTime? editedAt;

  /// 댓글이면 원본 메시지 앞부분(80자).
  final String? parent;

  const MyPost({
    required this.isComment,
    required this.id,
    required this.messageId,
    required this.roomId,
    this.roomName,
    this.roomType,
    this.teamId,
    this.teamName,
    this.text,
    this.title,
    required this.createdAt,
    this.editedAt,
    this.parent,
  });

  /// 목록에서 줄을 구분하는 키 — 메시지와 댓글의 id는 서로 겹치지 않지만 종류까지 붙여 안전하게.
  String get key => '${isComment ? 'c' : 'm'}:$id';

  bool get isPost => !isComment && (title ?? '').isNotEmpty;

  factory MyPost.fromJson(Map<String, dynamic> json) => MyPost(
    isComment: json['kind'] == 'comment',
    id: json['id'] as String,
    messageId: json['messageId'] as String,
    roomId: json['roomId'] as String,
    roomName: json['roomName'] as String?,
    roomType: json['roomType'] as String?,
    teamId: json['teamId'] as String?,
    teamName: json['teamName'] as String?,
    text: json['text'] as String?,
    title: json['title'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    ),
    editedAt: (json['editedAt'] as num?) != null
        ? DateTime.fromMillisecondsSinceEpoch((json['editedAt'] as num).toInt())
        : null,
    parent: json['parent'] as String?,
  );
}

/// `GET /api/my-posts` 한 쪽. [nextBefore]는 다음 쪽을 받을 때 `before`로 넘기는 커서.
class MyPostsPage {
  final List<MyPost> items;
  final bool hasMore;
  final String? nextBefore;
  const MyPostsPage({
    required this.items,
    required this.hasMore,
    this.nextBefore,
  });

  factory MyPostsPage.fromJson(Map<String, dynamic> json) => MyPostsPage(
    items: [
      for (final e in (json['items'] as List? ?? const []))
        MyPost.fromJson(Map<String, dynamic>.from(e as Map)),
    ],
    hasMore: json['hasMore'] as bool? ?? false,
    nextBefore: json['nextBefore'] as String?,
  );
}
