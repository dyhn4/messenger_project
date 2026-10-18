/// 외부 연동(들어오는·나가는 웹훅, 슬래시 명령, 연동 앱, 개인 API 토큰, 연결된 앱) 화면이 쓰는 모양 — 서버 integrations.js·oauth.js의
/// 응답과 같다.
library;

import '../l10n/tr.dart';
import 'room.dart';

/// 연동(웹훅·슬래시 명령)을 쓸 수 있는 방인지 — 서버 integrationRules.js roomAcceptsIntegrations와 같은 규칙(토픽 챗 뷰·그룹,
/// 비밀 대화 아님). 보관된 토픽은 명령을 받지 않는다.
bool roomAcceptsIntegrations(Room room) {
  if (room.isSecret) return false;
  if (room.type == RoomType.topic) {
    return room.viewMode == TopicViewMode.chat && !room.isArchived;
  }
  return room.type == RoomType.group;
}

DateTime? _time(Object? v) => (v as num?) == null
    ? null
    : DateTime.fromMillisecondsSinceEpoch((v as num).toInt());

/// 외부 연동(웹훅·슬래시 명령)이 올린 봇 메시지의 표시 — 봇 아이콘(이모지)과 어느 연동인지(연동을 지웠으면 null).
/// 봇 이름은 메시지의 senderName에 있다.
class MessageBot {
  final String? integrationId;
  final String? emoji;
  const MessageBot({this.integrationId, this.emoji});

  static MessageBot? fromJson(Object? json) {
    if (json is! Map) return null;
    return MessageBot(
      integrationId: json['integrationId'] as String?,
      emoji: json['emoji'] as String?,
    );
  }
}

/// 연동 하나([kind] 'webhook'(들어오는 웹훅) | 'command'(슬래시 명령) | 'outgoing'(나가는 웹훅) | 'app'(연동 앱)). 비밀값(토큰·서명
/// 비밀)은 만들 때 한 번만 따로 온다.
class Integration {
  final String id;
  final String kind;
  final String teamId;
  final String? roomId;
  final String name;
  final String? emoji;
  final String? tokenPrefix;
  final String? command;
  final String? description;

  /// 보낼 주소(슬래시 명령·나가는 웹훅·앱의 받을 일) — 그 연동을 다룰 수 있는 사람에게만 온다(그 밖에는 null).
  final String? url;

  /// 단추·선택지 누름을 받을 주소(들어오는 웹훅·앱) — 없으면 그 연동이 올린 메시지의 단추는 눌러도 갈 곳이 없다.
  final String? interactionUrl;

  /// 받을 일(나가는 웹훅·앱 — [integrationEvents] 중에서).
  final List<String> events;

  /// 켜져 있는지(나가는 웹훅·앱 — 보내기가 연달아 실패하면 서버가 끈다)와 연달아 실패한 수.
  final bool enabled;
  final int failureCount;

  /// 서명 비밀이 있는지(들어오는 웹훅은 응답 주소를 정할 때 처음 생긴다).
  final bool hasSigningSecret;

  /// OAuth 앱 id와 돌아갈 주소(앱 — 서버 운영자에게만).
  final String? clientId;
  final List<String> redirectUris;
  final String? createdByName;
  final DateTime? createdAt;
  final DateTime? lastUsedAt;
  final int useCount;

  const Integration({
    required this.id,
    required this.kind,
    required this.teamId,
    required this.name,
    this.roomId,
    this.emoji,
    this.tokenPrefix,
    this.command,
    this.description,
    this.url,
    this.interactionUrl,
    this.events = const [],
    this.enabled = true,
    this.failureCount = 0,
    this.hasSigningSecret = false,
    this.clientId,
    this.redirectUris = const [],
    this.createdByName,
    this.createdAt,
    this.lastUsedAt,
    this.useCount = 0,
  });

  bool get isCommand => kind == 'command';
  bool get isOutgoing => kind == 'outgoing';
  bool get isApp => kind == 'app';

  factory Integration.fromJson(Map<String, dynamic> json) => Integration(
    id: json['id'] as String,
    kind: json['kind'] as String? ?? 'webhook',
    teamId: json['teamId'] as String? ?? '',
    roomId: json['roomId'] as String?,
    name: json['name'] as String? ?? '',
    emoji: json['emoji'] as String?,
    tokenPrefix: json['tokenPrefix'] as String?,
    command: json['command'] as String?,
    description: json['description'] as String?,
    url: json['url'] as String?,
    interactionUrl: json['interactionUrl'] as String?,
    events: (json['events'] as List? ?? const []).whereType<String>().toList(),
    enabled: json['enabled'] as bool? ?? true,
    failureCount: (json['failureCount'] as num?)?.toInt() ?? 0,
    hasSigningSecret: json['hasSigningSecret'] == true,
    clientId: json['clientId'] as String?,
    redirectUris: (json['redirectUris'] as List? ?? const [])
        .whereType<String>()
        .toList(),
    createdByName: json['createdByName'] as String?,
    createdAt: _time(json['createdAt']),
    lastUsedAt: _time(json['lastUsedAt']),
    useCount: (json['useCount'] as num?)?.toInt() ?? 0,
  );
}

/// 웹훅을 만들거나 주소를 새로 만든 결과 — 토큰이 든 주소는 이번에만 보인다.
class WebhookSecret {
  final Integration webhook;
  final String token;

  /// 웹 앱 주소(정식 인증서 — 바깥 서비스가 그대로 믿는다). 웹 앱 주소를 설정하지 않은 서버면 null.
  final String? webUrl;

  /// 지금 앱이 붙은 서버 주소(사내 — 자체 서명 인증서일 수 있다).
  final String directUrl;

  const WebhookSecret({
    required this.webhook,
    required this.token,
    required this.webUrl,
    required this.directUrl,
  });

  /// 안내에 쓸 주소 — 웹 앱 주소가 있으면 그쪽.
  String get url => webUrl ?? directUrl;

  factory WebhookSecret.fromJson(Map<String, dynamic> json) {
    final urls = Map<String, dynamic>.from(json['urls'] as Map? ?? const {});
    return WebhookSecret(
      webhook: Integration.fromJson(json),
      token: json['token'] as String,
      webUrl: urls['web'] as String?,
      directUrl: urls['direct'] as String? ?? '',
    );
  }
}

/// 슬래시 명령 실행 결과 — 방에 올렸거나([posted]), 나에게만 보일 답([ephemeral]), 둘 다 아니면 할 말 없음.
class CommandRunResult {
  final bool posted;
  final String? ephemeral;
  const CommandRunResult({this.posted = false, this.ephemeral});

  factory CommandRunResult.fromJson(Map<String, dynamic> json) =>
      CommandRunResult(
        posted: json['posted'] == true,
        ephemeral: json['ephemeral'] as String?,
      );
}

/// 개인 API 토큰([scopes] — 'read' | 'write').
class ApiToken {
  final String id;
  final String name;
  final String tokenPrefix;
  final List<String> scopes;
  final DateTime? createdAt;
  final DateTime? lastUsedAt;
  final DateTime? expiresAt;

  const ApiToken({
    required this.id,
    required this.name,
    required this.tokenPrefix,
    required this.scopes,
    this.createdAt,
    this.lastUsedAt,
    this.expiresAt,
  });

  bool get canWrite => scopes.contains('write');
  bool expiredAt(DateTime now) => expiresAt != null && !expiresAt!.isAfter(now);

  factory ApiToken.fromJson(Map<String, dynamic> json) => ApiToken(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    tokenPrefix: json['tokenPrefix'] as String? ?? '',
    scopes: (json['scopes'] as List? ?? const []).whereType<String>().toList(),
    createdAt: _time(json['createdAt']),
    lastUsedAt: _time(json['lastUsedAt']),
    expiresAt: _time(json['expiresAt']),
  );
}

/// 입력한 글이 슬래시 명령이면 (명령 소문자, 나머지 글) — 서버 integrationRules.js parseSlashInvocation과 같은 규칙.
({String command, String text})? parseSlashInvocation(String input) {
  final m = RegExp(
    r'^/([a-zA-Z0-9][a-zA-Z0-9_-]{0,31})(?:\s+([\s\S]*))?$',
  ).firstMatch(input.trim());
  if (m == null) return null;
  return (command: m.group(1)!.toLowerCase(), text: (m.group(2) ?? '').trim());
}

/// 입력칸 자동 완성 — 지금 친 글이 `/`로 시작하고 아직 띄어쓰기 전이면 그 앞부분(소문자), 아니면 null.
String? slashCommandQuery(String input) {
  final m = RegExp(r'^/([a-zA-Z0-9_-]{0,32})$').firstMatch(input);
  return m?.group(1)?.toLowerCase();
}

/// 나가는 웹훅·앱이 받을 수 있는 일 — 서버 integrationRules.js INTEGRATION_EVENTS와 같은 순서.
const integrationEvents = [
  'message.created',
  'message.updated',
  'message.deleted',
  'mention',
  'comment.created',
  'todo.created',
  'todo.updated',
  'todo.deleted',
];

/// 일 종류의 화면 이름('ping'은 시험 보내기).
String integrationEventLabel(String event) => switch (event) {
  'message.created' => tr('새 메시지'),
  'message.updated' => tr('메시지 수정'),
  'message.deleted' => tr('메시지 삭제'),
  'mention' => tr('멘션'),
  'comment.created' => tr('새 댓글'),
  'todo.created' => tr('할 일 생성'),
  'todo.updated' => tr('할 일 수정'),
  'todo.deleted' => tr('할 일 삭제'),
  'ping' => tr('시험 보내기'),
  _ => event,
};

/// 나가는 웹훅·앱의 보내기 기록 한 건([status] 'pending'(다시 보낼 차례를 기다림) | 'delivered' | 'failed').
class WebhookDelivery {
  final String id;
  final String event;
  final String status;
  final int attempts;
  final int? lastStatus;
  final String? lastError;
  final DateTime? createdAt;
  final DateTime? deliveredAt;
  final DateTime? nextAttemptAt;

  const WebhookDelivery({
    required this.id,
    required this.event,
    required this.status,
    this.attempts = 0,
    this.lastStatus,
    this.lastError,
    this.createdAt,
    this.deliveredAt,
    this.nextAttemptAt,
  });

  bool get delivered => status == 'delivered';
  bool get failed => status == 'failed';

  factory WebhookDelivery.fromJson(Map<String, dynamic> json) =>
      WebhookDelivery(
        id: json['id'] as String? ?? '',
        event: json['event'] as String? ?? '',
        status: json['status'] as String? ?? 'failed',
        attempts: (json['attempts'] as num?)?.toInt() ?? 0,
        lastStatus: (json['lastStatus'] as num?)?.toInt(),
        lastError: json['lastError'] as String?,
        createdAt: _time(json['createdAt']),
        deliveredAt: _time(json['deliveredAt']),
        nextAttemptAt: _time(json['nextAttemptAt']),
      );
}

/// 연동 앱을 만들거나 비밀을 새로 만든 결과 — 비밀값은 이번에만 보인다(바꾸지 않은 것은 null).
class AppSecrets {
  final Integration app;
  final String? botToken;
  final String? clientSecret;
  final String? signingSecret;
  const AppSecrets({
    required this.app,
    this.botToken,
    this.clientSecret,
    this.signingSecret,
  });

  factory AppSecrets.fromJson(Map<String, dynamic> json) => AppSecrets(
    app: Integration.fromJson(json),
    botToken: json['botToken'] as String?,
    clientSecret: json['clientSecret'] as String?,
    signingSecret: (json['signingSecret'] ?? json['secret']) as String?,
  );
}

/// 팀 멤버에게 보이는 연동 앱(이름·아이콘·설명) — 방에 추가된 앱이면 추가한 사람·시각도.
class TeamApp {
  final String id;
  final String name;
  final String? emoji;
  final String? description;
  final bool enabled;
  final String? addedByName;
  final DateTime? addedAt;

  const TeamApp({
    required this.id,
    required this.name,
    this.emoji,
    this.description,
    this.enabled = true,
    this.addedByName,
    this.addedAt,
  });

  factory TeamApp.fromJson(Map<String, dynamic> json) => TeamApp(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    emoji: json['emoji'] as String?,
    description: json['description'] as String?,
    enabled: json['enabled'] as bool? ?? true,
    addedByName: json['addedByName'] as String?,
    addedAt: _time(json['addedAt']),
  );
}

/// 내 프로필 → 연결된 앱 한 줄 — 내가 승인한 OAuth 앱과 권한.
class ConnectedApp {
  final String id;
  final TeamApp app;
  final String? teamName;
  final List<String> scopes;
  final DateTime? createdAt;
  final DateTime? lastUsedAt;

  const ConnectedApp({
    required this.id,
    required this.app,
    this.teamName,
    this.scopes = const [],
    this.createdAt,
    this.lastUsedAt,
  });

  bool get canWrite => scopes.contains('write');

  factory ConnectedApp.fromJson(Map<String, dynamic> json) => ConnectedApp(
    id: json['id'] as String,
    app: TeamApp.fromJson(
      (json['app'] as Map? ?? const {}).cast<String, dynamic>(),
    ),
    teamName: json['teamName'] as String?,
    scopes: (json['scopes'] as List? ?? const []).whereType<String>().toList(),
    createdAt: _time(json['createdAt']),
    lastUsedAt: _time(json['lastUsedAt']),
  );
}

/// 승인 코드를 넣어 찾은 OAuth 승인 요청 — 승인 창에 앱 이름·팀·권한·돌아갈 곳을 보여 준다.
class OAuthRequestInfo {
  final String id;
  final TeamApp app;
  final String? teamName;
  final List<String> scopes;
  final String redirectHost;
  final DateTime? expiresAt;

  const OAuthRequestInfo({
    required this.id,
    required this.app,
    this.teamName,
    this.scopes = const [],
    required this.redirectHost,
    this.expiresAt,
  });

  bool get canWrite => scopes.contains('write');

  factory OAuthRequestInfo.fromJson(Map<String, dynamic> json) =>
      OAuthRequestInfo(
        id: json['id'] as String,
        app: TeamApp.fromJson(
          (json['app'] as Map? ?? const {}).cast<String, dynamic>(),
        ),
        teamName: json['teamName'] as String?,
        scopes: (json['scopes'] as List? ?? const [])
            .whereType<String>()
            .toList(),
        redirectHost: json['redirectHost'] as String? ?? '',
        expiresAt: _time(json['expiresAt']),
      );
}
