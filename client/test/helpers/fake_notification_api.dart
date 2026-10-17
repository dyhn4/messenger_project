import 'package:client/models/app_notification.dart';
import 'package:client/models/project.dart' show ProjectNotification;
import 'package:client/services/api_client.dart' show ApiException;
import 'package:client/services/notification_api.dart';

/// 서버 없이 알림 센터 컨트롤러·화면을 시험하는 가짜 API. 호출을 [calls]에 기록하고, 알림은 메모리에 들고
/// 있으며, 목록 조회는 진짜 서버처럼 kind·before·limit·unreadOnly를 지켜 최신순으로 돌려준다.
class FakeNotificationApi implements NotificationApi {
  /// 서버에 있는 알림 전부(순서 상관 없음 — 조회할 때 최신순으로 정렬한다).
  List<AppNotification> items;
  NotificationSettings settings;
  List<ProjectNotification> project;

  /// 호출 기록 — "메서드명 인자…" 문자열.
  final calls = <String>[];

  /// 마지막 markRead 요청의 세부.
  List<String>? lastReadIds;
  String? lastReadKind;

  /// null이 아니면 호출이 이 사유로 실패(서버 4xx 흉내).
  String? failWith;

  /// 목록 조회를 붙잡아 둘 때(늦은 응답 시험) 쓰는 대기.
  Future<void>? fetchGate;

  FakeNotificationApi({
    List<AppNotification>? items,
    NotificationSettings? settings,
    List<ProjectNotification>? project,
  }) : items = items ?? [],
       settings = settings ?? const NotificationSettings(),
       project = project ?? [];

  int callCount(String prefix) =>
      calls.where((c) => c.startsWith(prefix)).length;

  void _maybeFail() {
    if (failWith != null) throw ApiException(failWith!);
  }

  NotificationCounts get counts => NotificationCounts.of(
    mentionPersonal: items
        .where((n) => n.kind == NotificationKind.mention && !n.isRead)
        .length,
    mentionAll: items
        .where((n) => n.kind == NotificationKind.mentionAll && !n.isRead)
        .length,
    board: items.where((n) => n.isBoard && !n.isRead).length,
  );

  /// 서버의 kind 묶음(mention·mention_personal·mention_all·board)에 [n]이 드는지.
  static bool inKind(String kind, AppNotification n) => switch (kind) {
    'all' => true,
    'mention' => n.isMention,
    'mention_personal' => n.kind == NotificationKind.mention,
    'mention_all' => n.kind == NotificationKind.mentionAll,
    'board' => n.isBoard,
    _ => false,
  };

  @override
  Future<({List<AppNotification> items, bool hasMore})> fetchNotifications({
    required String kind,
    int? before,
    int limit = 30,
    bool unreadOnly = false,
  }) async {
    calls.add(
      'fetch kind=$kind before=$before limit=$limit unreadOnly=$unreadOnly',
    );
    final gate = fetchGate;
    if (gate != null) await gate;
    _maybeFail();
    final matching = [
      for (final n in items)
        if (inKind(kind, n) &&
            (before == null || n.createdAt.millisecondsSinceEpoch < before) &&
            (!unreadOnly || !n.isRead))
          n,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return (
      items: matching.take(limit).toList(),
      hasMore: matching.length > limit,
    );
  }

  @override
  Future<NotificationCounts> fetchUnreadCounts() async {
    calls.add('counts');
    _maybeFail();
    return counts;
  }

  @override
  Future<void> markRead({
    List<String>? ids,
    String? kind,
    String? messageId,
  }) async {
    calls.add('read ids=$ids kind=$kind messageId=$messageId');
    lastReadIds = ids;
    lastReadKind = kind;
    _maybeFail();
    final now = DateTime.now();
    for (final n in items) {
      final hit =
          (ids != null && ids.contains(n.id)) ||
          (kind != null && kind != 'all' && inKind(kind, n)) ||
          (messageId != null && n.messageId == messageId);
      if (hit) n.readAt ??= now;
    }
  }

  @override
  Future<NotificationSettings> fetchSettings() async {
    calls.add('settings');
    _maybeFail();
    return settings;
  }

  @override
  Future<NotificationSettings> updateSettings({
    bool? mentionAll,
    BoardNotifyLevel? boardLevel,
    bool? pushWhileOnline,
    bool? emailDigest,
  }) async {
    calls.add(
      'update mentionAll=$mentionAll boardLevel=${boardLevel?.wire}'
      '${pushWhileOnline == null ? '' : ' pushWhileOnline=$pushWhileOnline'}'
      '${emailDigest == null ? '' : ' emailDigest=$emailDigest'}',
    );
    _maybeFail();
    settings = settings.copyWith(
      mentionAll: mentionAll,
      boardLevel: boardLevel,
      pushWhileOnline: pushWhileOnline,
      emailDigest: emailDigest,
    );
    return settings;
  }

  @override
  Future<({List<ProjectNotification> items, int unread})>
  fetchProjectNotifications() async {
    calls.add('project');
    _maybeFail();
    return (
      items: List.of(project),
      unread: project.where((n) => !n.read).length,
    );
  }

  @override
  Future<int> markProjectRead({List<String>? ids}) async {
    calls.add('project-read ids=$ids');
    _maybeFail();
    project = [
      for (final n in project)
        if (ids == null || ids.contains(n.id))
          ProjectNotification(
            id: n.id,
            projectId: n.projectId,
            projectName: n.projectName,
            projectColor: n.projectColor,
            taskId: n.taskId,
            kind: n.kind,
            title: n.title,
            body: n.body,
            createdAt: n.createdAt,
            read: true,
          )
        else
          n,
    ];
    return project.where((n) => !n.read).length;
  }
}

/// 테스트용 알림 한 건 — [minutesAgo]분 전에 만들어진 것.
AppNotification notif(
  String id, {
  NotificationKind kind = NotificationKind.mention,
  int minutesAgo = 0,
  bool read = false,
  String roomId = 'r1',
  String roomName = '공지방',
  String? messageId,
  String teamId = 't1',
  String actor = '김철수',
  String preview = '확인 부탁드려요',
  DateTime? now,
}) {
  final base = now ?? DateTime(2026, 9, 30, 12);
  final t = base.subtract(Duration(minutes: minutesAgo));
  return AppNotification(
    id: id,
    kind: kind,
    teamId: teamId,
    teamName: '영업팀',
    roomId: roomId,
    roomName: roomName,
    messageId: messageId ?? 'm-$id',
    actorId: 'u2',
    actorName: actor,
    preview: preview,
    createdAt: t,
    readAt: read ? t : null,
  );
}

ProjectNotification projectNotif(
  String id, {
  int minutesAgo = 0,
  bool read = false,
  String? taskId = 'task1',
  String title = '잔디톡 · TA-1',
  String body = '업무를 배정했습니다',
  DateTime? now,
}) => ProjectNotification(
  id: id,
  projectId: 'p1',
  projectName: '잔디톡',
  projectColor: '#5B8DEF',
  taskId: taskId,
  kind: 'assigned',
  title: title,
  body: body,
  createdAt: (now ?? DateTime(2026, 9, 30, 12)).subtract(
    Duration(minutes: minutesAgo),
  ),
  read: read,
);
