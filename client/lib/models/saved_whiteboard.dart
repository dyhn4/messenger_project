/// 서버에 저장한 화상회의 화이트보드(server callWhiteboards.js) — 다음 통화의 화이트보드 [불러오기]가 골라 모두의 판에 편다.
/// 목록에는 [data]가 없고, 하나를 받을 때만 있다(CallWhiteboard.loadSaved에 그대로 넘긴다).
class SavedWhiteboard {
  final String id;
  final String roomId;
  final String title;
  final int pageCount;
  final String? createdBy;
  final String createdByName;
  final String updatedByName;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Object? data;
  const SavedWhiteboard({
    required this.id,
    required this.roomId,
    required this.title,
    this.pageCount = 1,
    this.createdBy,
    this.createdByName = '',
    this.updatedByName = '',
    required this.createdAt,
    required this.updatedAt,
    this.data,
  });

  factory SavedWhiteboard.fromJson(Map<String, dynamic> json) {
    DateTime at(Object? v) => v is num
        ? DateTime.fromMillisecondsSinceEpoch(v.toInt())
        : DateTime.fromMillisecondsSinceEpoch(0);
    return SavedWhiteboard(
      id: json['id'] as String,
      roomId: json['roomId'] as String? ?? '',
      title: json['title'] as String? ?? '',
      pageCount: (json['pageCount'] as num?)?.toInt() ?? 1,
      createdBy: json['createdBy'] as String?,
      createdByName: json['createdByName'] as String? ?? '',
      updatedByName: json['updatedByName'] as String? ?? '',
      createdAt: at(json['createdAt']),
      updatedAt: at(json['updatedAt']),
      data: json['data'],
    );
  }
}
