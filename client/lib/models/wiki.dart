// 팀 위키 모델(서버 wiki.js·wikiRules.js) — 페이지 나무 한 줄, 페이지, 판, 찾기 결과.

DateTime? _time(Object? v) =>
    v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;

/// 나무 목록 한 줄 — 위에서 아래로 펼친 차례, [depth]만큼 들여 쓴다.
class WikiPageRow {
  final String id;
  final String? parentId;
  final String title;
  final int depth;
  final String? createdBy;
  final DateTime? updatedAt;
  final String? updatedByName;

  /// 휴지통에서만.
  final DateTime? deletedAt;
  final bool canRemove;

  const WikiPageRow({
    required this.id,
    this.parentId,
    required this.title,
    this.depth = 0,
    this.createdBy,
    this.updatedAt,
    this.updatedByName,
    this.deletedAt,
    this.canRemove = false,
  });

  factory WikiPageRow.fromJson(Map<String, dynamic> j) => WikiPageRow(
    id: j['id'] as String,
    parentId: j['parentId'] as String?,
    title: j['title'] as String? ?? '',
    depth: (j['depth'] as num?)?.toInt() ?? 0,
    createdBy: j['createdBy'] as String?,
    updatedAt: _time(j['updatedAt']),
    updatedByName: j['updatedByName'] as String?,
    deletedAt: _time(j['deletedAt']),
    canRemove: j['canRemove'] as bool? ?? false,
  );
}

class WikiTree {
  final List<WikiPageRow> pages;
  final bool canEdit;
  final bool isManager;
  const WikiTree({
    this.pages = const [],
    this.canEdit = false,
    this.isManager = false,
  });

  factory WikiTree.fromJson(Map<String, dynamic> j) => WikiTree(
    pages: [
      for (final p in (j['pages'] as List? ?? const []))
        WikiPageRow.fromJson((p as Map).cast<String, dynamic>()),
    ],
    canEdit: j['canEdit'] as bool? ?? false,
    isManager: j['isManager'] as bool? ?? false,
  );
}

/// 페이지 하나(REST) — 동시 편집은 WikiDocSession(services/wiki_doc.dart)이 이어받는다.
class WikiPage {
  final WikiPageRow row;
  final String body;
  final int revision;
  final List<({String id, String title})> path;
  final bool canEdit;
  final bool canRemove;

  const WikiPage({
    required this.row,
    required this.body,
    this.revision = 0,
    this.path = const [],
    this.canEdit = false,
    this.canRemove = false,
  });

  factory WikiPage.fromJson(Map<String, dynamic> j) => WikiPage(
    row: WikiPageRow.fromJson(j),
    body: j['body'] as String? ?? '',
    revision: (j['revision'] as num?)?.toInt() ?? 0,
    path: [
      for (final p in (j['path'] as List? ?? const []))
        if (p is Map)
          (id: p['id'] as String, title: p['title'] as String? ?? ''),
    ],
    canEdit: j['canEdit'] as bool? ?? false,
    canRemove: j['canRemove'] as bool? ?? false,
  );
}

class WikiVersion {
  final String id;
  final int revision;
  final String title;
  final String? editorNames;
  final int size;
  final DateTime? createdAt;

  /// 판 하나를 열었을 때만.
  final String? body;

  const WikiVersion({
    required this.id,
    required this.revision,
    required this.title,
    this.editorNames,
    this.size = 0,
    this.createdAt,
    this.body,
  });

  factory WikiVersion.fromJson(Map<String, dynamic> j) => WikiVersion(
    id: j['id'] as String,
    revision: (j['revision'] as num?)?.toInt() ?? 0,
    title: j['title'] as String? ?? '',
    editorNames: j['editorNames'] as String?,
    size: (j['size'] as num?)?.toInt() ?? 0,
    createdAt: _time(j['createdAt']),
    body: j['body'] as String?,
  );
}

class WikiSearchHit {
  final String id;
  final String title;
  final String path;
  final String excerpt;
  const WikiSearchHit({
    required this.id,
    required this.title,
    this.path = '',
    this.excerpt = '',
  });

  factory WikiSearchHit.fromJson(Map<String, dynamic> j) => WikiSearchHit(
    id: j['id'] as String,
    title: j['title'] as String? ?? '',
    path: j['path'] as String? ?? '',
    excerpt: j['excerpt'] as String? ?? '',
  );
}
