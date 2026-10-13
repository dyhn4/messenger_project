/// 관리자 콘솔 "DDNS" 탭 — 서버가 주기적으로 DuckDNS에 공인 IP를 알리는 설정과 그 상태(server/src/admin.js
/// GET /api/admin/ddns, 갱신은 server/src/ddns.js). 토큰은 서버가 다시 내려주지 않아 설정 여부([tokenConfigured])만 있다.
class DdnsSettings {
  final bool enabled;

  /// ".duckdns.org"를 뗀 이름들(예: tangotalk).
  final List<String> domains;
  final bool tokenConfigured;
  final DdnsStatus status;

  const DdnsSettings({
    required this.enabled,
    required this.domains,
    required this.tokenConfigured,
    required this.status,
  });

  factory DdnsSettings.fromJson(Map<String, dynamic> json) => DdnsSettings(
    enabled: json['enabled'] as bool? ?? false,
    domains: (json['domains'] as List?)?.cast<String>() ?? const [],
    tokenConfigured: json['tokenConfigured'] as bool? ?? false,
    status: DdnsStatus.fromJson(
      (json['status'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
  );

  /// 화면에 보일 전체 주소들(tangotalk.duckdns.org).
  List<String> get fullDomains => [for (final d in domains) '$d.duckdns.org'];
}

/// 서버의 갱신기 상태 — 서버를 다시 켜면 비워진다(메모리에만 있다).
class DdnsStatus {
  final DateTime? lastAttemptAt;
  final DateTime? lastSuccessAt;

  /// 마지막 시도가 성공했는지 — 아직 시도 전이면 null.
  final bool? ok;

  /// DuckDNS가 알려 준, 지금 도메인이 가리키는 공인 IP.
  final String? ip;
  final String? error;
  final DateTime? nextAttemptAt;
  final int intervalMinutes;

  const DdnsStatus({
    this.lastAttemptAt,
    this.lastSuccessAt,
    this.ok,
    this.ip,
    this.error,
    this.nextAttemptAt,
    this.intervalMinutes = 5,
  });

  factory DdnsStatus.fromJson(Map<String, dynamic> json) => DdnsStatus(
    lastAttemptAt: _time(json['lastAttemptAt']),
    lastSuccessAt: _time(json['lastSuccessAt']),
    ok: json['ok'] as bool?,
    ip: json['ip'] as String?,
    error: json['error'] as String?,
    nextAttemptAt: _time(json['nextAttemptAt']),
    intervalMinutes: (json['intervalMinutes'] as num?)?.toInt() ?? 5,
  );

  static DateTime? _time(Object? ms) =>
      ms is num ? DateTime.fromMillisecondsSinceEpoch(ms.toInt()) : null;
}
