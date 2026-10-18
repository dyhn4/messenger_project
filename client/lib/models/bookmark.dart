import '../l10n/tr.dart';

/// 북마크 종류 — 팀 북마크는 팀 모두에게, 개인 북마크는 나에게만 보인다. 한 번 만들면 바꿀 수 없다.
enum BookmarkKind {
  team('team', '팀 북마크'),
  personal('personal', '개인 북마크');

  final String wire;
  final String _labelKo;

  /// 화면에 보일 이름(지금 언어 — l10n/tr.dart).
  String get label => tr(_labelKo);
  const BookmarkKind(this.wire, this._labelKo);

  static BookmarkKind fromWire(String? s) =>
      s == 'personal' ? BookmarkKind.personal : BookmarkKind.team;
}

/// 북마크 하나 — 이미지·제목·링크(server/src/bookmarks.js). [canEdit]/[canReorder]는 서버가 이 사람 기준으로 계산해 준다.
class Bookmark {
  final String id;
  final String teamId;
  final BookmarkKind kind;
  final String title;
  final String url;

  /// 서명된 /files/… 링크(직접 올린 사진) 또는 외부 http(s) 주소. 없으면 null.
  final String? imageUrl;
  final int position;
  final String? creatorId;
  final String? creatorName;

  /// 만든 사람 또는 팀 관리자(개인 북마크는 본인) — 수정·삭제할 수 있다.
  final bool canEdit;

  /// 이 종류의 순서를 바꿀 수 있다 — 팀 북마크는 팀 관리자만, 개인 북마크는 본인.
  final bool canReorder;

  const Bookmark({
    required this.id,
    required this.teamId,
    required this.kind,
    required this.title,
    required this.url,
    this.imageUrl,
    this.position = 0,
    this.creatorId,
    this.creatorName,
    this.canEdit = false,
    this.canReorder = false,
  });

  factory Bookmark.fromJson(Map<String, dynamic> json) {
    final creator = json['creator'];
    return Bookmark(
      id: json['id'] as String,
      teamId: json['teamId'] as String? ?? '',
      kind: BookmarkKind.fromWire(json['kind'] as String?),
      title: json['title'] as String? ?? '',
      url: json['url'] as String? ?? '',
      imageUrl: json['imageUrl'] as String?,
      position: (json['position'] as num?)?.toInt() ?? 0,
      creatorId: creator is Map ? creator['id'] as String? : null,
      creatorName: creator is Map ? creator['name'] as String? : null,
      canEdit: json['canEdit'] as bool? ?? false,
      canReorder: json['canReorder'] as bool? ?? false,
    );
  }

  /// 카드에 작게 보이는 도메인 — 주소의 호스트("www." 제외). 파싱이 안 되면 주소 그대로.
  String get host => hostOf(url);

  Bookmark copyWith({
    String? title,
    String? url,
    String? imageUrl,
    bool clearImage = false,
  }) => Bookmark(
    id: id,
    teamId: teamId,
    kind: kind,
    title: title ?? this.title,
    url: url ?? this.url,
    imageUrl: clearImage ? null : (imageUrl ?? this.imageUrl),
    position: position,
    creatorId: creatorId,
    creatorName: creatorName,
    canEdit: canEdit,
    canReorder: canReorder,
  );
}

/// 주소의 도메인("www." 제외). 파싱이 안 되면 받은 값 그대로.
String hostOf(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  if (host.isEmpty) return url;
  return host.startsWith('www.') ? host.substring(4) : host;
}

/// 한 팀의 북마크 두 목록(각각 position 순).
class BookmarkLists {
  final List<Bookmark> team;
  final List<Bookmark> personal;
  const BookmarkLists({this.team = const [], this.personal = const []});

  List<Bookmark> of(BookmarkKind kind) =>
      kind == BookmarkKind.team ? team : personal;

  factory BookmarkLists.fromJson(Map<String, dynamic> json) {
    List<Bookmark> parse(Object? raw) => [
      for (final e in (raw as List? ?? const []))
        Bookmark.fromJson(Map<String, dynamic>.from(e as Map)),
    ];
    return BookmarkLists(
      team: parse(json['team']),
      personal: parse(json['personal']),
    );
  }
}

/// "링크 정보 가져오기" 결과 — 주소의 제목·대표 이미지·사이트 이름. 못 가져오면 전부 null.
class BookmarkPreview {
  final String? title;
  final String? imageUrl;
  final String? siteName;
  const BookmarkPreview({this.title, this.imageUrl, this.siteName});

  bool get isEmpty => (title ?? '').isEmpty && (imageUrl ?? '').isEmpty;

  factory BookmarkPreview.fromJson(Map<String, dynamic> json) =>
      BookmarkPreview(
        title: json['title'] as String?,
        imageUrl: json['imageUrl'] as String?,
        siteName: json['siteName'] as String?,
      );
}
