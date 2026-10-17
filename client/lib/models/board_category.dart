import 'dart:ui' show Color;

/// 보드 뷰 토픽의 말머리(분류) 하나 — 토픽 관리자가 정한 목록(Room.boardCategories, 서버 boardRules.js)이고,
/// 게시글은 그중 하나의 id를 Message.categoryId로 든다. 지운 말머리를 든 게시글은 말머리 없이 보인다.
class BoardCategory {
  /// 서버가 붙이는 id('k…') — 새로 더한 말머리는 아직 없어서(관리 창에서) null로 보낸다.
  final String? id;
  final String name;

  /// '#RRGGBB'(boardCategoryColors 중 하나).
  final String color;

  const BoardCategory({this.id, required this.name, required this.color});

  factory BoardCategory.fromJson(Map<String, dynamic> j) => BoardCategory(
    id: j['id'] as String?,
    name: j['name'] as String? ?? '',
    color: j['color'] as String? ?? boardCategoryColors.first,
  );

  Map<String, dynamic> toJson() => {'id': ?id, 'name': name, 'color': color};

  /// 말머리 알약의 색.
  Color get swatch => parseBoardCategoryColor(color);

  /// [json]의 말머리 목록(없거나 모양이 틀리면 빈 목록).
  static List<BoardCategory> listFromJson(Object? json) => [
    if (json is List)
      for (final e in json)
        if (e is Map && e['id'] is String && e['name'] is String)
          BoardCategory.fromJson(Map<String, dynamic>.from(e)),
  ];
}

/// 서버 boardRules.js의 BOARD_CATEGORY_COLORS와 같은 순서 — 관리 창의 색 고르기.
const boardCategoryColors = [
  '#5B8DEF',
  '#2A9D8F',
  '#F4A261',
  '#E76F51',
  '#9B5DE5',
  '#E53935',
  '#00B4D8',
  '#6C757D',
];

/// 서버 boardRules.js와 같은 제한.
const boardCategoriesMax = 20;
const boardCategoryNameMax = 20;

Color parseBoardCategoryColor(String hex) {
  final v = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
  return v == null ? const Color(0xFF5B8DEF) : Color(0xFF000000 | v);
}

/// 내가 아직 안 읽은 필독 게시글 하나(GET /rooms/:id/must-read) — 보드 위 "필독 안 읽음"에 제목만 보인다.
typedef UnreadMustRead = ({String id, String title});
