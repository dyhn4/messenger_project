// 앨범 — 대화방 안에서 이미지·GIF·영상을 주제별로 모으는 공간(서버 server/src/albums.js).
// 대화방 파일과 자동 연동이 없는 독립 저장소이고, 그 방의 멤버가 함께 본다.

/// 한 번에 올릴 수 있는 최대 개수 — 서버(ALBUM_ITEMS_PER_REQUEST_MAX)와 같다. 앨범의 총 개수는 제한이 없다.
const albumUploadMaxCount = 100;

/// 한 번에 대화방에 공유할 수 있는 최대 개수(서버 ALBUM_SHARE_MAX).
const albumShareMaxCount = 10;

const albumTitleMaxLength = 50;
const albumDescriptionMaxLength = 300;

enum AlbumItemKind { image, video }

class Album {
  final String id;
  final String teamId;
  final String roomId;

  /// 받는 사람 기준 방 이름(1:1이면 상대 이름 등) — 서버가 계산해 준다.
  final String? roomName;
  final String? creatorId;
  final String? creatorName;
  final String title;
  final String? description;
  final String? coverItemId;

  /// 대표 이미지(서명된 썸네일 링크, 상대 경로) — 항목이 없거나 썸네일 없는 영상뿐이면 null.
  final String? coverUrl;
  final int itemCount;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 상세에서만 채워진다(목록은 false) — 제목·설명·대표 이미지를 고칠 수 있는지 / 앨범을 지울 수 있는지 /
  /// 남이 올린 항목까지 지울 수 있는지(앨범 만든 사람·팀 관리자).
  final bool canEdit;
  final bool canDelete;
  final bool canDeleteAnyItem;

  const Album({
    required this.id,
    required this.teamId,
    required this.roomId,
    this.roomName,
    this.creatorId,
    this.creatorName,
    required this.title,
    this.description,
    this.coverItemId,
    this.coverUrl,
    this.itemCount = 0,
    required this.createdAt,
    required this.updatedAt,
    this.canEdit = false,
    this.canDelete = false,
    this.canDeleteAnyItem = false,
  });

  factory Album.fromJson(Map<String, dynamic> json) => Album(
    id: json['id'] as String,
    teamId: json['teamId'] as String? ?? '',
    roomId: json['roomId'] as String,
    roomName: json['roomName'] as String?,
    creatorId: json['creatorId'] as String?,
    creatorName: json['creatorName'] as String?,
    title: json['title'] as String? ?? '',
    description: json['description'] as String?,
    coverItemId: json['coverItemId'] as String?,
    coverUrl: json['coverUrl'] as String?,
    itemCount: (json['itemCount'] as num?)?.toInt() ?? 0,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num?)?.toInt() ?? 0,
    ),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      (json['updatedAt'] as num?)?.toInt() ?? 0,
    ),
    canEdit: json['canEdit'] as bool? ?? false,
    canDelete: json['canDelete'] as bool? ?? false,
    canDeleteAnyItem: json['canDeleteAnyItem'] as bool? ?? false,
  );

  Album copyWith({
    String? title,
    String? description,
    int? itemCount,
    String? coverUrl,
    bool clearCover = false,
  }) => Album(
    id: id,
    teamId: teamId,
    roomId: roomId,
    roomName: roomName,
    creatorId: creatorId,
    creatorName: creatorName,
    title: title ?? this.title,
    description: description ?? this.description,
    coverItemId: clearCover ? null : coverItemId,
    coverUrl: clearCover ? null : (coverUrl ?? this.coverUrl),
    itemCount: itemCount ?? this.itemCount,
    createdAt: createdAt,
    updatedAt: updatedAt,
    canEdit: canEdit,
    canDelete: canDelete,
    canDeleteAnyItem: canDeleteAnyItem,
  );
}

class AlbumItem {
  final String id;
  final String albumId;
  final String? uploaderId;
  final String? uploaderName;
  final AlbumItemKind kind;

  /// 서명된 파일 링크(/files/…, 약 2시간 뒤 만료) — 만료되면 목록을 다시 받아 새 링크를 쓴다.
  final String fileUrl;
  final String? fileName;
  final int? fileSize;
  final String? mimeType;
  final String? thumbnailUrl;
  final int? width;
  final int? height;
  final int? durationMs;
  final DateTime createdAt;

  /// 내가 이 항목을 지울 수 있는지(올린 사람·앨범 만든 사람·팀 관리자) — 서버가 계산한다.
  final bool canDelete;

  const AlbumItem({
    required this.id,
    required this.albumId,
    this.uploaderId,
    this.uploaderName,
    required this.kind,
    required this.fileUrl,
    this.fileName,
    this.fileSize,
    this.mimeType,
    this.thumbnailUrl,
    this.width,
    this.height,
    this.durationMs,
    required this.createdAt,
    this.canDelete = false,
  });

  bool get isImage => kind == AlbumItemKind.image;
  bool get isVideo => kind == AlbumItemKind.video;

  /// GIF 이미지인지 — 격자에서 "GIF" 표시를 붙인다.
  bool get isGif =>
      (mimeType ?? '').toLowerCase() == 'image/gif' ||
      (fileName ?? '').toLowerCase().endsWith('.gif');

  factory AlbumItem.fromJson(Map<String, dynamic> json) => AlbumItem(
    id: json['id'] as String,
    albumId: json['albumId'] as String? ?? '',
    uploaderId: json['uploaderId'] as String?,
    uploaderName: json['uploaderName'] as String?,
    kind: json['kind'] == 'video' ? AlbumItemKind.video : AlbumItemKind.image,
    fileUrl: json['fileUrl'] as String? ?? '',
    fileName: json['fileName'] as String?,
    fileSize: (json['fileSize'] as num?)?.toInt(),
    mimeType: json['mimeType'] as String?,
    thumbnailUrl: json['thumbnailUrl'] as String?,
    width: (json['width'] as num?)?.toInt(),
    height: (json['height'] as num?)?.toInt(),
    durationMs: (json['durationMs'] as num?)?.toInt(),
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num?)?.toInt() ?? 0,
    ),
    canDelete: json['canDelete'] as bool? ?? false,
  );
}

/// 앨범에 올릴 파일 한 개의 서버 요청 모양 — 이미 `/api/upload`로 올라간 파일을 가리킨다.
class AlbumItemDraft {
  final AlbumItemKind kind;
  final String fileUrl;
  final String fileName;
  final int fileSize;
  final String mimeType;
  final String? thumbnailUrl;
  final int? width;
  final int? height;
  final int? durationMs;

  const AlbumItemDraft({
    required this.kind,
    required this.fileUrl,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    this.thumbnailUrl,
    this.width,
    this.height,
    this.durationMs,
  });

  Map<String, dynamic> toJson() => {
    'kind': kind == AlbumItemKind.video ? 'video' : 'image',
    'fileUrl': fileUrl,
    'fileName': fileName,
    'fileSize': fileSize,
    'mimeType': mimeType,
    'thumbnailUrl': ?thumbnailUrl,
    'width': ?width,
    'height': ?height,
    'durationMs': ?durationMs,
  };
}

enum AlbumChangeKind { created, updated, deleted, items }

/// 소켓 `album:changed` — 앨범이 만들어지거나 바뀌거나 지워졌거나 항목이 늘고 줄었다.
class AlbumChangedEvent {
  final String teamId;
  final String roomId;
  final String albumId;
  final AlbumChangeKind kind;

  const AlbumChangedEvent({
    required this.teamId,
    required this.roomId,
    required this.albumId,
    required this.kind,
  });

  factory AlbumChangedEvent.fromJson(Map<String, dynamic> json) =>
      AlbumChangedEvent(
        teamId: json['teamId'] as String? ?? '',
        roomId: json['roomId'] as String? ?? '',
        albumId: json['albumId'] as String? ?? '',
        kind: switch (json['kind']) {
          'created' => AlbumChangeKind.created,
          'deleted' => AlbumChangeKind.deleted,
          'items' => AlbumChangeKind.items,
          _ => AlbumChangeKind.updated,
        },
      );
}

/// 영상 길이를 `m:ss`(1시간 넘으면 `h:mm:ss`)로.
String formatAlbumDuration(int? durationMs) {
  if (durationMs == null || durationMs < 0) return '';
  final total = (durationMs / 1000).round();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}
