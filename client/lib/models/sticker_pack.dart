/// 서버에 올린 그림 이모티콘 한 장(server/src/stickers.js). [url]은 짧게 만료되는 서명 링크라
/// 화면에서는 [id]로 캐시해서 쓴다(sticker_view.dart).
class ServerSticker {
  final String id;
  final String packId;
  final String url;

  /// 화면에 그릴 작은 그림(서버가 올릴 때 만든다) — 움직이는 그림이거나 예전에 올린 것이면 null.
  final String? thumbnailUrl;
  final String? fileName;
  final String? mimeType;

  /// 화면(선택창·말풍선·프로필 미리보기)에 그릴 주소 — 썸네일이 있으면 그것, 없으면 원본.
  String get displayUrl => thumbnailUrl ?? url;

  /// 이모티콘 선택창에서만 빠진다 — 예전 메시지는 계속 그림이 보여야 해서 목록에는 온다.
  final bool hidden;

  /// 관리 화면에서 "개별 삭제"한 그림 — 관리 화면에서도 빠진다. 예전 메시지에 그리려고 목록에는 계속 오고,
  /// 서버가 [hidden]도 같이 켜서 보내서 선택창에서는 빠진다.
  final bool deleted;

  const ServerSticker({
    required this.id,
    required this.packId,
    required this.url,
    this.thumbnailUrl,
    this.fileName,
    this.mimeType,
    this.hidden = false,
    this.deleted = false,
  });

  factory ServerSticker.fromJson(Map<String, dynamic> json) => ServerSticker(
    id: json['id'] as String,
    packId: json['packId'] as String,
    url: json['url'] as String,
    thumbnailUrl: json['thumbnailUrl'] as String?,
    fileName: json['fileName'] as String?,
    mimeType: json['mimeType'] as String?,
    hidden: json['hidden'] as bool? ?? false,
    deleted: json['deleted'] as bool? ?? false,
  );
}

/// 이모티콘 세트(예: "리마인"). [kind]로 채팅에 보내는 "sticker"와 프로필 사진으로 고르는
/// "character"를 구분한다(server/src/db/schema.js) — 테이블·업로드·관리 화면은 같이 쓰고,
/// 목록을 받을 때(api_client.dart의 kind 인자)로만 서로 안 섞이게 가른다.
class ServerStickerPack {
  final String id;
  final String name;
  final String kind; // 'sticker' | 'character'
  final bool hidden;

  /// "세트 삭제"한 세트 — 관리 화면·선택창에는 안 나오고, 예전 메시지를 그릴 때만 쓴다.
  final bool deleted;
  final List<ServerSticker> stickers;

  const ServerStickerPack({
    required this.id,
    required this.name,
    this.kind = 'sticker',
    this.hidden = false,
    this.deleted = false,
    this.stickers = const [],
  });

  factory ServerStickerPack.fromJson(Map<String, dynamic> json) =>
      ServerStickerPack(
        id: json['id'] as String,
        name: json['name'] as String,
        kind: json['kind'] as String? ?? 'sticker',
        hidden: json['hidden'] as bool? ?? false,
        deleted: json['deleted'] as bool? ?? false,
        stickers: [
          for (final s in (json['stickers'] as List? ?? const []))
            ServerSticker.fromJson(s as Map<String, dynamic>),
        ],
      );
}
