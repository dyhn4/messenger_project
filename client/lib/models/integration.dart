/// 외부 연동(들어오는 웹훅·슬래시 명령·개인 API 토큰) 화면이 쓰는 모양 — 서버 integrations.js의 응답과 같다.
library;

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

/// 웹훅 하나 또는 슬래시 명령 하나([kind] 'webhook' | 'command'). 비밀값(토큰·서명 비밀)은 만들 때 한 번만 따로 온다.
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

  /// 슬래시 명령을 보낼 주소 — 서버 운영자에게만 온다(그 밖에는 null).
  final String? url;
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
    this.createdByName,
    this.createdAt,
    this.lastUsedAt,
    this.useCount = 0,
  });

  bool get isCommand => kind == 'command';

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
