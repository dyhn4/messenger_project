// 로그인 보안 — 2단계 인증(OTP), 회사 계정 로그인(SSO — Google·Microsoft), 사내 디렉터리(LDAP). 서버는
// server/src/loginSecurity.js·sso.js·admin.js(/admin/login-security).

/// 회사 계정 이름(화면 글자).
String ssoProviderLabel(String provider) => switch (provider) {
  'google' => 'Google',
  'microsoft' => 'Microsoft',
  'ldap' => '회사 디렉터리(Windows)',
  _ => provider,
};

/// 로그인 화면에 보일 로그인 방법(GET /server-info의 loginMethods) — 켜져 있고 쓸 수 있는 것만.
class LoginMethods {
  /// 회사 계정 로그인 단추('google' | 'microsoft').
  final List<String> sso;

  /// 회사(Windows 도메인) 계정으로도 로그인할 수 있는지 — 아이디 칸 아래 안내만(같은 칸으로 들어온다).
  final bool ldap;

  /// 2단계 인증 정책 — 'optional' | 'admins' | 'all'.
  final String otpPolicy;

  const LoginMethods({
    this.sso = const [],
    this.ldap = false,
    this.otpPolicy = 'optional',
  });

  static const none = LoginMethods();

  factory LoginMethods.fromJson(Object? json) {
    if (json is! Map) return none;
    return LoginMethods(
      sso: [
        for (final p in (json['sso'] as List? ?? const []))
          if (p == 'google' || p == 'microsoft') p as String,
      ],
      ldap: json['ldap'] == true,
      otpPolicy: json['otpPolicy'] as String? ?? 'optional',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LoginMethods &&
      other.ldap == ldap &&
      other.otpPolicy == otpPolicy &&
      other.sso.join(',') == sso.join(',');

  @override
  int get hashCode => Object.hash(sso.join(','), ldap, otpPolicy);
}

/// 비밀번호(또는 디렉터리)는 맞았고 2단계 인증이 남았다 — 로그인 화면이 받아서 코드를 묻는다. [setupRequired]면 관리자가 꼭
/// 쓰게 정했는데 아직 안 켠 사람이라 그 자리에서 켠다. [ticket]은 10분 동안만 쓸 수 있는 확인 표.
class OtpChallenge implements Exception {
  final String ticket;
  final bool setupRequired;
  final String username;
  const OtpChallenge({
    required this.ticket,
    required this.setupRequired,
    required this.username,
  });

  @override
  String toString() => '2단계 인증이 필요합니다.';
}

/// 2단계 인증 켜기 1단계 — 인증 앱에 넣을 비밀 키와 QR 주소(otpauth://).
class OtpSetupInfo {
  final String secret;
  final String uri;
  const OtpSetupInfo({required this.secret, required this.uri});
}

/// 내 2단계 인증 상태.
class OtpStatus {
  final bool enabled;

  /// 관리자가 꼭 쓰게 정했는지(그러면 끌 수 없다).
  final bool required;
  final String policy;
  final int recoveryCodesLeft;
  const OtpStatus({
    required this.enabled,
    required this.required,
    required this.policy,
    required this.recoveryCodesLeft,
  });

  factory OtpStatus.fromJson(Map<String, dynamic> j) => OtpStatus(
    enabled: j['enabled'] == true,
    required: j['required'] == true,
    policy: j['policy'] as String? ?? 'optional',
    recoveryCodesLeft: (j['recoveryCodesLeft'] as num?)?.toInt() ?? 0,
  );
}

/// 연결된 외부 로그인 한 개(회사 계정·디렉터리).
class LinkedIdentity {
  final String provider;
  final String? email;
  final DateTime createdAt;
  final DateTime? lastLoginAt;
  const LinkedIdentity({
    required this.provider,
    this.email,
    required this.createdAt,
    this.lastLoginAt,
  });

  factory LinkedIdentity.fromJson(Map<String, dynamic> j) {
    DateTime? at(Object? v) =>
        v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
    return LinkedIdentity(
      provider: j['provider'] as String,
      email: j['email'] as String?,
      createdAt: at(j['createdAt']) ?? DateTime.now(),
      lastLoginAt: at(j['lastLoginAt']),
    );
  }
}

/// 내 연결 목록과 이 서버에서 연결할 수 있는 회사 계정.
class IdentitiesInfo {
  final List<LinkedIdentity> identities;
  final List<String> available;
  const IdentitiesInfo({required this.identities, required this.available});

  factory IdentitiesInfo.fromJson(Map<String, dynamic> j) => IdentitiesInfo(
    identities: [
      for (final e in (j['identities'] as List? ?? const []))
        LinkedIdentity.fromJson((e as Map).cast<String, dynamic>()),
    ],
    available: [
      for (final p in (j['available'] as List? ?? const [])) p as String,
    ],
  );
}

/// 회사 계정 로그인 결과 묻기(POST /auth/sso/poll)의 답.
sealed class SsoPollResult {
  const SsoPollResult();
}

/// 아직 브라우저에서 로그인 중.
final class SsoPending extends SsoPollResult {
  const SsoPending();
}

/// 로그인됐다 — 토큰.
final class SsoDone extends SsoPollResult {
  final String accessToken;
  final String refreshToken;
  final String userId;
  final String username;
  const SsoDone({
    required this.accessToken,
    required this.refreshToken,
    required this.userId,
    required this.username,
  });
}

/// 내 프로필에서 연결하기가 끝났다.
final class SsoLinked extends SsoPollResult {
  final String provider;
  const SsoLinked(this.provider);
}

/// 같은 이메일의 계정이 있어 이메일 확인 코드로 연결해야 한다 — [email]은 일부만 보이는 주소, [canEmail]이 false면 서버 메일이
/// 꺼져 있어 아이디로 로그인한 뒤 내 프로필에서 연결해야 한다.
final class SsoLinkRequired extends SsoPollResult {
  final String email;
  final bool canEmail;
  const SsoLinkRequired({required this.email, required this.canEmail});
}

final class SsoFailed extends SsoPollResult {
  final String message;
  const SsoFailed(this.message);
}

SsoPollResult ssoPollResultFromJson(Map<String, dynamic> j) =>
    switch (j['status']) {
      'pending' => const SsoPending(),
      'done' => SsoDone(
        accessToken: j['accessToken'] as String,
        refreshToken: j['refreshToken'] as String,
        userId: j['userId'] as String,
        username: j['username'] as String,
      ),
      'linked' => SsoLinked(j['provider'] as String? ?? ''),
      'link_required' => SsoLinkRequired(
        email: j['email'] as String? ?? '',
        canEmail: j['canEmail'] == true,
      ),
      _ => SsoFailed(j['error'] as String? ?? '회사 계정 로그인에 실패했습니다.'),
    };

/// 관리자 콘솔 "로그인 보안"이 받는 모양(GET /admin/login-security) — 비밀값은 정했는지([hasClientSecret] 등)만.
class LoginSecuritySettings {
  final String otpPolicy;
  final String? redirectUri;
  final bool ssoAutoCreate;
  final String ssoDefaultRole;
  final int ssoSessionDays;
  final SsoProviderSettings google;
  final SsoProviderSettings microsoft;
  final LdapSettings ldap;

  const LoginSecuritySettings({
    required this.otpPolicy,
    required this.redirectUri,
    required this.ssoAutoCreate,
    required this.ssoDefaultRole,
    required this.ssoSessionDays,
    required this.google,
    required this.microsoft,
    required this.ldap,
  });

  factory LoginSecuritySettings.fromJson(Map<String, dynamic> j) {
    final sso = (j['sso'] as Map? ?? const {}).cast<String, dynamic>();
    return LoginSecuritySettings(
      otpPolicy: j['otpPolicy'] as String? ?? 'optional',
      redirectUri: sso['redirectUri'] as String?,
      ssoAutoCreate: sso['autoCreate'] == true,
      ssoDefaultRole: sso['defaultRole'] as String? ?? 'member',
      ssoSessionDays: (sso['sessionDays'] as num?)?.toInt() ?? 7,
      google: SsoProviderSettings.fromJson(
        (sso['google'] as Map? ?? const {}).cast<String, dynamic>(),
      ),
      microsoft: SsoProviderSettings.fromJson(
        (sso['microsoft'] as Map? ?? const {}).cast<String, dynamic>(),
      ),
      ldap: LdapSettings.fromJson(
        (j['ldap'] as Map? ?? const {}).cast<String, dynamic>(),
      ),
    );
  }
}

class SsoProviderSettings {
  final bool enabled;
  final String clientId;
  final bool hasClientSecret;

  /// Google — 받아들일 회사 도메인(쉼표로 여럿).
  final String domains;

  /// Microsoft — 디렉터리(테넌트) ID.
  final String tenantId;

  /// 켤 수 없는 이유(값이 빠짐) — 없으면 null.
  final String? problem;

  const SsoProviderSettings({
    required this.enabled,
    required this.clientId,
    required this.hasClientSecret,
    this.domains = '',
    this.tenantId = '',
    this.problem,
  });

  factory SsoProviderSettings.fromJson(Map<String, dynamic> j) =>
      SsoProviderSettings(
        enabled: j['enabled'] == true,
        clientId: j['clientId'] as String? ?? '',
        hasClientSecret: j['hasClientSecret'] == true,
        domains: j['domains'] as String? ?? '',
        tenantId: j['tenantId'] as String? ?? '',
        problem: j['problem'] as String?,
      );
}

class LdapSettings {
  final bool enabled;
  final String url;
  final String bindDn;
  final bool hasBindPassword;
  final String baseDn;
  final String userFilter;
  final String nameAttr;
  final String emailAttr;
  final String departmentAttr;
  final String titleAttr;
  final bool tlsVerify;
  final bool autoCreate;
  final String defaultRole;
  final DateTime? testedAt;
  final String? problem;

  const LdapSettings({
    required this.enabled,
    required this.url,
    required this.bindDn,
    required this.hasBindPassword,
    required this.baseDn,
    required this.userFilter,
    required this.nameAttr,
    required this.emailAttr,
    required this.departmentAttr,
    required this.titleAttr,
    required this.tlsVerify,
    required this.autoCreate,
    required this.defaultRole,
    this.testedAt,
    this.problem,
  });

  factory LdapSettings.fromJson(Map<String, dynamic> j) => LdapSettings(
    enabled: j['enabled'] == true,
    url: j['url'] as String? ?? '',
    bindDn: j['bindDn'] as String? ?? '',
    hasBindPassword: j['hasBindPassword'] == true,
    baseDn: j['baseDn'] as String? ?? '',
    userFilter: j['userFilter'] as String? ?? '',
    nameAttr: j['nameAttr'] as String? ?? 'displayName',
    emailAttr: j['emailAttr'] as String? ?? 'mail',
    departmentAttr: j['departmentAttr'] as String? ?? 'department',
    titleAttr: j['titleAttr'] as String? ?? 'title',
    tlsVerify: j['tlsVerify'] != false,
    autoCreate: j['autoCreate'] != false,
    defaultRole: j['defaultRole'] as String? ?? 'member',
    testedAt: j['testedAt'] is num
        ? DateTime.fromMillisecondsSinceEpoch((j['testedAt'] as num).toInt())
        : null,
    problem: j['problem'] as String?,
  );
}

/// 디렉터리 연결 시험 결과.
class LdapTestResult {
  final bool ok;
  final String message;

  /// 찾은 사람(이름·이메일·부서·직책) — 사람을 찾아봤을 때만.
  final Map<String, String?>? profile;
  final LoginSecuritySettings view;
  const LdapTestResult({
    required this.ok,
    required this.message,
    this.profile,
    required this.view,
  });
}
