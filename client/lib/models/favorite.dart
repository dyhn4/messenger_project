import 'app_user.dart';
import 'comment.dart';
import 'message.dart';

/// 통합 즐겨찾기의 종류(서버 `GET /api/favorites?type=`). 화면의 탭 순서이기도 하다 — 맨 앞 "전체"는 종류가 아니라
/// null로 나타낸다.
enum FavoriteKind { message, file, comment, poll, room, member }

extension FavoriteKindInfo on FavoriteKind {
  /// 서버가 쓰는 type 값.
  String get apiValue => name;

  String get label => switch (this) {
    FavoriteKind.message => '메시지',
    FavoriteKind.file => '파일',
    FavoriteKind.comment => '댓글',
    FavoriteKind.poll => '투표',
    FavoriteKind.room => '대화방',
    FavoriteKind.member => '멤버',
  };

  /// 종류마다 비었을 때 보여주는 안내 — 어디서 즐겨찾기를 켜는지 알려 준다.
  String get emptyHint => switch (this) {
    FavoriteKind.message => '즐겨찾기한 메시지가 없습니다.\n메시지의 ⋯ 메뉴에서 즐겨찾기를 켤 수 있어요.',
    FavoriteKind.file => '즐겨찾기한 파일이 없습니다.\n파일의 ⋯ 메뉴에서 즐겨찾기를 켤 수 있어요.',
    FavoriteKind.comment => '즐겨찾기한 댓글이 없습니다.\n댓글의 ⋯ 메뉴에서 즐겨찾기를 켤 수 있어요.',
    FavoriteKind.poll => '즐겨찾기한 투표가 없습니다.\n투표 카드의 ⋯ 메뉴에서 즐겨찾기를 켤 수 있어요.',
    FavoriteKind.room => '즐겨찾기한 대화방이 없습니다.\n대화방 이름 옆 별을 눌러 즐겨찾기를 켤 수 있어요.',
    FavoriteKind.member => '즐겨찾기한 멤버가 없습니다.\n멤버 프로필의 별을 눌러 즐겨찾기를 켤 수 있어요.',
  };

  static FavoriteKind? fromApi(String? value) {
    for (final k in FavoriteKind.values) {
      if (k.name == value) return k;
    }
    return null;
  }
}

/// 즐겨찾기 목록의 한 줄 — 서버 `GET /api/favorites`의 items 한 개. [kind]에 따라 쓰는 필드가 다르다
/// (message·poll·file은 [message], comment는 [comment]+[parentText], member는 [user], room은 [roomType]).
class FavoriteItem {
  final FavoriteKind kind;

  /// 즐겨찾기에 담은 시각 — 대화방은 담은 시각이 없어 null.
  final DateTime? favoritedAt;
  final String? roomId;
  final String? roomName;

  /// 메시지·투표(`poll` 포함)·파일이 딸린 메시지.
  final Message? message;
  final Comment? comment;

  /// 댓글 항목의 원문 — "홍길동: 오늘 회의…" 식 한 줄을 만드는 재료.
  final String? parentSender;
  final String? parentText;

  /// 파일 항목 — 서버가 서명해 준 주소와 이름(한 메시지에 파일이 여러 개일 수 있어 메시지와 따로 온다).
  final String? fileUrl;
  final String? fileName;

  /// 멤버 항목 — 즐겨찾기한 사람과, 어느 팀 기준인지.
  final AppUser? user;
  final String? teamId;

  /// 대화방 항목 — 'topic' | 'group' | 'dm' 와 비밀·나와의 대화 표시.
  final String? roomType;
  final bool isSecret;
  final bool isSelf;

  const FavoriteItem({
    required this.kind,
    this.favoritedAt,
    this.roomId,
    this.roomName,
    this.message,
    this.comment,
    this.parentSender,
    this.parentText,
    this.fileUrl,
    this.fileName,
    this.user,
    this.teamId,
    this.roomType,
    this.isSecret = false,
    this.isSelf = false,
  });

  /// 목록에서 같은 항목을 가리키는 키 — 지우거나 다시 받을 때 쓴다. 파일은 한 메시지의 파일마다 따로다.
  String get key => switch (kind) {
    FavoriteKind.message => 'message:${message?.id}',
    FavoriteKind.poll => 'poll:${message?.id}',
    FavoriteKind.file => 'file:${message?.id}:${fileName ?? ''}',
    FavoriteKind.comment => 'comment:${comment?.id}',
    FavoriteKind.room => 'room:$roomId',
    FavoriteKind.member => 'member:$teamId:${user?.id}',
  };

  factory FavoriteItem.fromJson(Map<String, dynamic> json) {
    final kind = FavoriteKindInfo.fromApi(json['type'] as String?);
    if (kind == null) {
      throw FormatException('알 수 없는 즐겨찾기 종류: ${json['type']}');
    }
    Map<String, dynamic>? map(String key) => json[key] is Map
        ? Map<String, dynamic>.from(json[key] as Map)
        : null;
    final parent = map('parentMessage');
    final messageJson = map('message');
    final commentJson = map('comment');
    final userJson = map('user');
    final at = (json['favoritedAt'] as num?)?.toInt();
    return FavoriteItem(
      kind: kind,
      favoritedAt: at == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(at),
      roomId: json['roomId'] as String?,
      roomName: json['roomName'] as String?,
      message: messageJson == null ? null : Message.fromJson(messageJson),
      comment: commentJson == null ? null : Comment.fromJson(commentJson),
      parentSender: parent?['senderName'] as String?,
      parentText: parent?['text'] as String?,
      fileUrl: json['fileUrl'] as String?,
      fileName: json['fileName'] as String?,
      user: userJson == null ? null : AppUser.fromJson(userJson),
      teamId: json['teamId'] as String?,
      roomType: json['roomType'] as String?,
      isSecret: json['isSecret'] as bool? ?? false,
      isSelf: json['isSelf'] as bool? ?? false,
    );
  }
}

/// `GET /api/favorites/ids` — 내가 즐겨찾기한 메시지·댓글·멤버(별 표시와 메뉴의 "즐겨찾기 / 해제"를 정하는 데 쓴다).
class FavoriteIds {
  final Set<String> messages;
  final Set<String> comments;

  /// `teamId:userId` 모양(한 사람을 팀마다 따로 담는다).
  final Set<String> members;
  const FavoriteIds({
    this.messages = const {},
    this.comments = const {},
    this.members = const {},
  });

  static String memberKey(String teamId, String userId) => '$teamId:$userId';

  factory FavoriteIds.fromJson(Map<String, dynamic> json) => FavoriteIds(
    messages: {for (final e in (json['messages'] as List? ?? const [])) '$e'},
    comments: {for (final e in (json['comments'] as List? ?? const [])) '$e'},
    members: {
      for (final e in (json['members'] as List? ?? const []))
        memberKey(
          (e as Map)['teamId'] as String,
          e['userId'] as String,
        ),
    },
  );
}
