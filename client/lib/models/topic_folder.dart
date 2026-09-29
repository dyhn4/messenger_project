/// 토픽 폴더 이름 최대 글자 수와 한 사람이 한 팀에 만들 수 있는 폴더 수 — 서버
/// POST /rooms/folders가 같은 값으로 다시 검사한다.
const topicFolderNameMaxLength = 30;
const topicFolderMaxCount = 50;

/// 토픽 목록의 개인 폴더(서버 topic_folders) — 사람마다 팀별로 자기 목록을 따로 정리한다
/// (project.dart의 ProjectFolder와 같은 방식). 한 토픽은 내 폴더 중 한 곳에만 들어간다.
///
/// 이름·순서·접힘·안의 토픽은 Session이 화면 반응성을 위해 먼저 그 자리에서 바꾸고 서버가
/// 실패하면 되돌린다(Session.setTopicFolderCollapsed 등) — 그래서 id 말고는 전부 non-final.
class TopicFolder {
  final String id;
  String name;
  int position;
  bool collapsed;

  /// 이 폴더에 넣은 토픽 id들(순서 의미 없음 — 폴더 안 정렬은 목록 화면이 정한다).
  final List<String> roomIds;

  TopicFolder({
    required this.id,
    required this.name,
    this.position = 0,
    this.collapsed = false,
    List<String>? roomIds,
  }) : roomIds = roomIds ?? [];

  factory TopicFolder.fromJson(Map<String, dynamic> json) => TopicFolder(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    position: (json['position'] as num?)?.toInt() ?? 0,
    collapsed: json['collapsed'] as bool? ?? false,
    roomIds: (json['roomIds'] as List?)?.whereType<String>().toList(),
  );

  bool contains(String roomId) => roomIds.contains(roomId);
}
