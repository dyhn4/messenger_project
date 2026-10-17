/// 관리자 콘솔 "메일" 탭 — 서버의 메일(SMTP) 설정과 멘션 요약 메일 설정(server/src/admin.js GET /api/admin/mail). 비밀번호는
/// 서버가 다시 내려주지 않아 설정 여부([passwordConfigured])만 있다.
class MailSettings {
  /// 관리자가 켰는지 — 시험 메일이 성공한 뒤에만 켤 수 있다.
  final bool enabled;

  /// 지금 메일 기능이 실제로 동작하는지(켰고 값이 갖춰짐).
  final bool ready;
  final String host;

  /// null이면 아직 안 정함 — 서버가 보안 방식의 흔한 포트를 쓴다([defaultPorts]).
  final int? port;

  /// 'ssl' | 'starttls' | 'none'.
  final String security;
  final Map<String, int> defaultPorts;
  final String username;
  final bool passwordConfigured;
  final String fromAddress;
  final String fromName;

  /// 실제로 쓰일 보내는 주소(따로 안 정했으면 계정) — 이메일 모양이 아니면 null.
  final String? effectiveFrom;

  /// 시험 메일을 보내 볼 만큼 값이 갖춰졌는지(서버·포트·보내는 주소).
  final bool complete;

  /// 지금 값으로 시험 메일을 보내 성공한 시각 — 연결 값을 바꾸면 지워진다.
  final DateTime? testedAt;
  final MailDigestSettings digest;

  const MailSettings({
    required this.enabled,
    required this.ready,
    required this.host,
    required this.port,
    required this.security,
    required this.defaultPorts,
    required this.username,
    required this.passwordConfigured,
    required this.fromAddress,
    required this.fromName,
    required this.effectiveFrom,
    required this.complete,
    required this.testedAt,
    required this.digest,
  });

  factory MailSettings.fromJson(Map<String, dynamic> json) {
    final tested = (json['testedAt'] as num?)?.toInt();
    return MailSettings(
      enabled: json['enabled'] as bool? ?? false,
      ready: json['ready'] as bool? ?? false,
      host: json['host'] as String? ?? '',
      port: (json['port'] as num?)?.toInt(),
      security: json['security'] as String? ?? 'starttls',
      defaultPorts: {
        for (final e
            in ((json['defaultPorts'] as Map?)?.cast<String, dynamic>() ??
                    const {})
                .entries)
          e.key: (e.value as num).toInt(),
      },
      username: json['username'] as String? ?? '',
      passwordConfigured: json['passwordConfigured'] as bool? ?? false,
      fromAddress: json['fromAddress'] as String? ?? '',
      fromName: json['fromName'] as String? ?? '',
      effectiveFrom: json['effectiveFrom'] as String?,
      complete: json['complete'] as bool? ?? false,
      testedAt: tested == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(tested),
      digest: MailDigestSettings.fromJson(
        (json['digest'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
    );
  }

  /// 보안 방식의 흔한 포트(서버가 알려 준 값, 없으면 일반적인 값).
  int defaultPortFor(String security) =>
      defaultPorts[security] ??
      switch (security) {
        'ssl' => 465,
        'none' => 25,
        _ => 587,
      };
}

/// 오래 접속하지 않은 사람에게 보내는 멘션 요약 메일 설정.
class MailDigestSettings {
  final bool enabled;

  /// 이 날수 넘게 접속하지 않은 사람에게 보낸다.
  final int days;

  /// 메시지 미리보기를 메일에 넣을지 — 끄면 방 이름·보낸 사람·시각만(메시지 내용이 서버 밖으로 나가지 않게).
  final bool preview;
  final int daysMin;
  final int daysMax;

  const MailDigestSettings({
    this.enabled = true,
    this.days = 3,
    this.preview = false,
    this.daysMin = 1,
    this.daysMax = 30,
  });

  factory MailDigestSettings.fromJson(Map<String, dynamic> json) =>
      MailDigestSettings(
        enabled: json['enabled'] as bool? ?? true,
        days: (json['days'] as num?)?.toInt() ?? 3,
        preview: json['preview'] as bool? ?? false,
        daysMin: (json['daysMin'] as num?)?.toInt() ?? 1,
        daysMax: (json['daysMax'] as num?)?.toInt() ?? 30,
      );
}

/// 초대 링크를 메일로 보낸 결과 — 보낸 수와 못 보낸 주소들(server/src/inviteMail.js).
class InviteMailResult {
  final int sent;
  final List<({String email, String error})> failed;
  const InviteMailResult({required this.sent, this.failed = const []});

  factory InviteMailResult.fromJson(Map<String, dynamic> json) =>
      InviteMailResult(
        sent: (json['sent'] as num?)?.toInt() ?? 0,
        failed: [
          for (final f in (json['failed'] as List? ?? const []))
            if (f is Map)
              (
                email: f['email'] as String? ?? '',
                error: f['error'] as String? ?? '',
              ),
        ],
      );
}

/// 메일 서비스별 SMTP 값 — 관리자 콘솔에서 골라 채우기만 하면 되게. 도메인이 없을 때 흔히 쓰는 개인 메일 계정들이다.
class SmtpPreset {
  final String label;
  final String host;
  final int port;
  final String security;

  /// 그 서비스에서 SMTP를 쓰려면 해야 하는 일(앱 비밀번호 등).
  final String note;
  const SmtpPreset({
    required this.label,
    required this.host,
    required this.port,
    required this.security,
    required this.note,
  });
}

const smtpPresets = [
  SmtpPreset(
    label: '네이버',
    host: 'smtp.naver.com',
    port: 465,
    security: 'ssl',
    note:
        '네이버 메일 → 환경설정 → POP3/IMAP 설정에서 SMTP 사용을 켜고, 2단계 인증을 쓰면 네이버 보안 설정에서 만든 앱 비밀번호를 넣으세요. 계정은 전체 주소(아이디@naver.com).',
  ),
  SmtpPreset(
    label: 'Gmail',
    host: 'smtp.gmail.com',
    port: 465,
    security: 'ssl',
    note:
        'Google 계정에서 2단계 인증을 켠 뒤 "앱 비밀번호"를 만들어 넣으세요(계정 비밀번호로는 안 됩니다). 계정은 전체 주소(아이디@gmail.com).',
  ),
  SmtpPreset(
    label: '다음/카카오',
    host: 'smtp.daum.net',
    port: 465,
    security: 'ssl',
    note: '다음 메일 → 환경설정 → IMAP/SMTP에서 사용을 켜고, 2단계 인증을 쓰면 앱 비밀번호를 넣으세요.',
  ),
];
