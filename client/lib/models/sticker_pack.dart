/// 서버에 올린 그림 이모티콘 한 장(server/src/stickers.js). [url]은 짧게 만료되는 서명 링크라
/// 화면에서는 [id]로 캐시해서 쓴다(sticker_view.dart).
class ServerSticker {
  final String id;
  final String packId;
  final String url;
  final String? fileName;
  final String? mimeType;

  /// 이모티콘 선택창에서만 빠진다 — 예전 메시지는 계속 그림이 보여야 해서 목록에는 온다.
  final bool hidden;

  const ServerSticker({
    required this.id,
    required this.packId,
    required this.url,
    this.fileName,
    this.mimeType,
    this.hidden = false,
  });

  factory ServerSticker.fromJson(Map<String, dynamic> json) => ServerSticker(
    id: json['id'] as String,
    packId: json['packId'] as String,
    url: json['url'] as String,
    fileName: json['fileName'] as String?,
    mimeType: json['mimeType'] as String?,
    hidden: json['hidden'] as bool? ?? false,
  );
}

/// 이모티콘 세트(예: "리마인").
class ServerStickerPack {
  final String id;
  final String name;
  final bool hidden;

  /// "세트 삭제"한 세트 — 관리 화면·선택창에는 안 나오고, 예전 메시지를 그릴 때만 쓴다.
  final bool deleted;
  final List<ServerSticker> stickers;

  const ServerStickerPack({
    required this.id,
    required this.name,
    this.hidden = false,
    this.deleted = false,
    this.stickers = const [],
  });

  factory ServerStickerPack.fromJson(Map<String, dynamic> json) =>
      ServerStickerPack(
        id: json['id'] as String,
        name: json['name'] as String,
        hidden: json['hidden'] as bool? ?? false,
        deleted: json['deleted'] as bool? ?? false,
        stickers: [
          for (final s in (json['stickers'] as List? ?? const []))
            ServerSticker.fromJson(s as Map<String, dynamic>),
        ],
      );
}
