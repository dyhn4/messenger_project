/// 관리자 콘솔 "웹 앱 주소(정식 인증서)" 카드가 보여 주는 상태 — GET /api/admin/web-certificate(서버 운영자 전용).
///
/// 아이폰에는 설치형 앱이 없어서 웹 앱을 Safari로 쓰는데, 웹 앱을 쓰고 홈 화면에 추가해 알림을 받으려면 브라우저가
/// 믿는 공인 인증서가 있어야 한다. 그래서 운영자가 도메인(예: xxx.iptime.org)을 정하면 서버가 Let's Encrypt 인증서를
/// 받아 웹 앱 전용 HTTPS 포트에 걸고 스스로 갱신한다 — PC·안드로이드 앱이 쓰는 메인 포트의 자체 서명 인증서(앱이
/// 고정해 둔 것)와는 별개다. 시각은 서버가 epoch ms(없으면 null)로 보낸다.
library;

/// 서버가 알려 주는 인증서 상태. 모르는 값(이 앱보다 새 서버)은 [unknown].
enum WebCertificateState { off, pending, valid, expiring, error, unknown }

class WebCertificateStatus {
  /// 운영자가 도메인을 정해 이 기능을 켰는지.
  final bool enabled;
  final String? domain;
  final WebCertificateState status;

  /// Let's Encrypt 시험용(staging) 서버에서 받은 인증서인지 — 발급 절차 확인용이라 브라우저가 믿지 않는다.
  final bool staging;
  final DateTime? expiresAt;
  final DateTime? lastAttemptAt;
  final String? lastError;
  final DateTime? nextAttemptAt;

  /// 도메인 확인 방식별로 서버가 받을 준비가 됐는지(그 포트를 이 PC에서 열었는지) — HTTP-01은 외부 80번 포트,
  /// TLS-ALPN-01은 외부 443번 포트로 Let's Encrypt가 확인하러 온다(통신사가 80번을 막는 경우가 있어 둘 다 둔다).
  /// 서버가 알려 주지 않으면 null.
  final bool? http01;
  final bool? tlsAlpn01;

  /// 아이폰 사용자에게 알려 줄 웹 앱 주소(https://도메인[:포트]) — 공인 인증서가 실제로 걸려 있을 때만 값이 있다.
  final String? webUrl;

  const WebCertificateStatus({
    required this.enabled,
    this.domain,
    required this.status,
    this.staging = false,
    this.expiresAt,
    this.lastAttemptAt,
    this.lastError,
    this.nextAttemptAt,
    this.http01,
    this.tlsAlpn01,
    this.webUrl,
  });

  factory WebCertificateStatus.fromJson(Map<String, dynamic> json) {
    final challenges = json['challenges'];
    return WebCertificateStatus(
      enabled: json['enabled'] as bool? ?? false,
      domain: _text(json['domain']),
      status: _state(json['status']),
      staging: json['staging'] as bool? ?? false,
      expiresAt: _time(json['expiresAt']),
      lastAttemptAt: _time(json['lastAttemptAt']),
      lastError: _text(json['lastError']),
      nextAttemptAt: _time(json['nextAttemptAt']),
      http01: challenges is Map ? _flag(challenges['http01']) : null,
      tlsAlpn01: challenges is Map ? _flag(challenges['tlsAlpn01']) : null,
      webUrl: _httpsUrl(json['webUrl']),
    );
  }

  /// 꺼져 있는지 — 도메인을 안 정했거나 서버가 'off'라고 하면.
  bool get isOff => !enabled || status == WebCertificateState.off;

  /// 발급 한도에 걸려 실패했는지. iptime.org 같은 공용 DDNS 도메인은 "도메인 하나에 7일 동안 새 인증서 50개" 한도를
  /// 그 도메인을 쓰는 모든 사람이 나눠 써서, 처음 발급이 이 이유로 막힐 수 있다(이미 받은 인증서의 갱신은 한도와
  /// 무관하다). 서버가 그대로 옮겨 주는 Let's Encrypt 오류 문구(rateLimited)로 알아본다.
  bool get rateLimited {
    final error = lastError?.toLowerCase();
    if (error == null) return false;
    return error.contains('ratelimit') ||
        error.contains('rate limit') ||
        error.contains('too many certificates') ||
        error.contains('발급 한도');
  }

  static WebCertificateState _state(Object? value) => switch (value) {
    'off' => WebCertificateState.off,
    'pending' => WebCertificateState.pending,
    'valid' => WebCertificateState.valid,
    'expiring' => WebCertificateState.expiring,
    'error' => WebCertificateState.error,
    _ => WebCertificateState.unknown,
  };

  static DateTime? _time(Object? value) =>
      value is num ? DateTime.fromMillisecondsSinceEpoch(value.toInt()) : null;

  static String? _text(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  static bool? _flag(Object? value) => value is bool ? value : null;

  /// 운영자가 아이폰 사용자에게 그대로 알려 줄 주소라 https 주소만 받는다.
  static String? _httpsUrl(Object? value) {
    final text = _text(value);
    final uri = text == null ? null : Uri.tryParse(text);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty
        ? text
        : null;
  }
}
