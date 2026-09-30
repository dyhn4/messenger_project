import '../models/app_notification.dart';
import '../models/project.dart' show ProjectNotification;
import 'api_client.dart';

/// 알림 센터의 REST 호출 전부(규약 CONTRACT_NOTIF.md의 REST 3~6번 + 기존 프로젝트 알림함). 컨트롤러는 이
/// 추상 클래스만 알아서, 테스트는 가짜 구현을 끼우고 실제 앱은 [RemoteNotificationApi]가 [ApiClient]로
/// 서버를 부른다.
abstract class NotificationApi {
  /// `GET /api/notifications` — [kind]는 'mention' | 'board' | 'all'. [before]는 이 시각(ms)보다 오래된 것만
  /// (무한 스크롤 커서), 최신순이다.
  Future<({List<AppNotification> items, bool hasMore})> fetchNotifications({
    required String kind,
    int? before,
    int limit = 30,
    bool unreadOnly = false,
  });

  /// `GET /api/notifications/unread-counts` — 내 모든 팀 합계.
  Future<NotificationCounts> fetchUnreadCounts();

  /// `POST /api/notifications/read` — [ids] 또는 [kind] 또는 [messageId] 중 하나로 읽음 처리.
  Future<void> markRead({List<String>? ids, String? kind, String? messageId});

  /// `GET /api/notification-settings`.
  Future<NotificationSettings> fetchSettings();

  /// `PATCH /api/notification-settings` — 준 필드만 바꾸고 바뀐 전체를 돌려준다.
  Future<NotificationSettings> updateSettings({
    bool? mentionAll,
    BoardNotifyLevel? boardLevel,
  });

  /// 기존 프로젝트 알림함(`/api/project-notifications`) — 최근 50개와 안 읽은 개수.
  Future<({List<ProjectNotification> items, int unread})>
  fetchProjectNotifications();

  /// 프로젝트 알림 읽음 — [ids]가 없으면 전부. 남은 안 읽은 개수.
  Future<int> markProjectRead({List<String>? ids});
}

/// [ApiClient]로 서버를 부르는 실제 구현.
class RemoteNotificationApi implements NotificationApi {
  final ApiClient _api;
  RemoteNotificationApi(this._api);

  @override
  Future<({List<AppNotification> items, bool hasMore})> fetchNotifications({
    required String kind,
    int? before,
    int limit = 30,
    bool unreadOnly = false,
  }) async {
    final query = <String, String>{
      'kind': kind,
      'before': ?before?.toString(),
      'limit': '$limit',
      if (unreadOnly) 'unreadOnly': 'true',
    };
    final path = Uri(path: '/api/notifications', queryParameters: query);
    final body = Map<String, dynamic>.from(
      await _api.requestJson('GET', path.toString()) as Map,
    );
    return (
      items: [
        for (final e in (body['items'] as List? ?? const []))
          AppNotification.fromJson(Map<String, dynamic>.from(e as Map)),
      ],
      hasMore: body['hasMore'] as bool? ?? false,
    );
  }

  @override
  Future<NotificationCounts> fetchUnreadCounts() async =>
      NotificationCounts.fromJson(
        await _api.requestJson('GET', '/api/notifications/unread-counts'),
      );

  @override
  Future<void> markRead({
    List<String>? ids,
    String? kind,
    String? messageId,
  }) async {
    await _api.requestJson(
      'POST',
      '/api/notifications/read',
      body: {'ids': ?ids, 'kind': ?kind, 'messageId': ?messageId},
    );
  }

  @override
  Future<NotificationSettings> fetchSettings() async =>
      NotificationSettings.fromJson(
        Map<String, dynamic>.from(
          await _api.requestJson('GET', '/api/notification-settings') as Map,
        ),
      );

  @override
  Future<NotificationSettings> updateSettings({
    bool? mentionAll,
    BoardNotifyLevel? boardLevel,
  }) async => NotificationSettings.fromJson(
    Map<String, dynamic>.from(
      await _api.requestJson(
            'PATCH',
            '/api/notification-settings',
            body: {'mentionAll': ?mentionAll, 'boardLevel': ?boardLevel?.wire},
          )
          as Map,
    ),
  );

  @override
  Future<({List<ProjectNotification> items, int unread})>
  fetchProjectNotifications() async {
    final (items, unread) = await _api.fetchProjectNotifications();
    return (items: items, unread: unread);
  }

  @override
  Future<int> markProjectRead({List<String>? ids}) =>
      _api.markProjectNotificationsRead(ids: ids);
}
