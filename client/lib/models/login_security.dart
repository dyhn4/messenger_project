// 로그인 보안 — 2단계 인증(OTP), 보안 키·패스키(WebAuthn), 회사 계정 로그인(SSO — Google·Microsoft·SAML), 사내 디렉터리(LDAP),
// 디렉터리 그룹 규칙, 로그아웃 연동. 서버는 server/src/loginSecurity.js·webauthn.js·sso.js·saml.js·admin.js(/admin/login-security).

import '../l10n/tr.dart';

/// 회사 계정 이름(화면 글자). SAML은 관리자가 정한 IdP 이름([samlLabel] — 예: "Okta")이 있으면 그것.
String ssoProviderLabel(String provider, {String? samlLabel}) =>
    switch (provider) {
      'google' => 'Google',
      'microsoft' => 'Microsoft',
      'saml' =>
        (samlLabel != null && samlLabel.isNotEmpty)
            ? samlLabel
            : tr('회사 계정(SAML)'),
      'ldap' => tr('회사 디렉터리(Windows)'),
      _ => provider,
    };

/// 로그인 화면에 보일 로그인 방법(GET /server-info의 loginMethods) — 켜져 있고 쓸 수 있는 것만.
class LoginMethods {
  /// 회사 계정 로그인 단추('google' | 'microsoft' | 'saml').
  final List<String> sso;

  /// SAML 단추 글(관리자가 정한 IdP 이름).
  final String? samlLabel;

  /// 보안 키·패스키로 바로(비밀번호 없이) 로그인할 수 있는지 — 웹 앱 주소가 있고 관리자가 막지 않았을 때.
  final bool passkey;

  /// 회사(Windows 도메인) 계정으로도 로그인할 수 있는지 — 아이디 칸 아래 안내만(같은 칸으로 들어온다).
  final bool ldap;

  /// 2단계 인증 정책 — 'optional' | 'admins' | 'all'.
  final String otpPolicy;

  const LoginMethods({
    this.sso = const [],
    this.samlLabel,
    this.passkey = false,
    this.ldap = false,
    this.otpPolicy = 'optional',
  });

  static const none = LoginMethods();

  factory LoginMethods.fromJson(Object? json) {
    if (json is! Map) return none;
    return LoginMethods(
      sso: [
        for (final p in (json['sso'] as List? ?? const []))
          if (p == 'google' || p == 'microsoft' || p == 'saml') p as String,
      ],
      samlLabel: json['samlLabel'] as String?,
      passkey: json['passkey'] == true,
      ldap: json['ldap'] == true,
      otpPolicy: json['otpPolicy'] as String? ?? 'optional',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LoginMethods &&
      other.ldap == ldap &&
      other.otpPolicy == otpPolicy &&
      other.passkey == passkey &&
      other.samlLabel == samlLabel &&
      other.sso.join(',') == sso.join(',');

  @override
  int get hashCode =>
      Object.hash(sso.join(','), ldap, otpPolicy, passkey, samlLabel);
}

/// 비밀번호(또는 디렉터리)는 맞았고 2단계 인증이 남았다 — 로그인 화면이 받아서 코드를 묻는다. [setupRequired]면 관리자가 꼭
/// 쓰게 정했는데 아직 안 켠 사람이라 그 자리에서 켠다. [ticket]은 10분 동안만 쓸 수 있는 확인 표.
class OtpChallenge implements Exception {
  final String ticket;
  final bool setupRequired;
  final String username;

  /// 둘째 단계로 쓸 수 있는 방법 — 'totp'(인증 앱 코드)·'webauthn'(보안 키·패스키). 예전 서버는 보내지 않아 ['totp'].
  final List<String> methods;
  const OtpChallenge({
    required this.ticket,
    required this.setupRequired,
    required this.username,
    this.methods = const ['totp'],
  });

  bool get canUseTotp => methods.contains('totp');
  bool get canUsePasskey => methods.contains('webauthn');

  @override
  String toString() => tr('2단계 인증이 필요합니다.');
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

  /// 등록한 보안 키·패스키 수 — 있으면 꼭 써야 해도 인증 앱을 끌 수 있다.
  final int passkeyCount;
  const OtpStatus({
    required this.enabled,
    required this.required,
    required this.policy,
    required this.recoveryCodesLeft,
    this.passkeyCount = 0,
  });

  factory OtpStatus.fromJson(Map<String, dynamic> j) => OtpStatus(
    enabled: j['enabled'] == true,
    required: j['required'] == true,
    policy: j['policy'] as String? ?? 'optional',
    recoveryCodesLeft: (j['recoveryCodesLeft'] as num?)?.toInt() ?? 0,
    passkeyCount: (j['passkeyCount'] as num?)?.toInt() ?? 0,
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

  /// SAML 단추 글(관리자가 정한 IdP 이름) — [ssoProviderLabel]에 넘긴다.
  final String? samlLabel;
  const IdentitiesInfo({
    required this.identities,
    required this.available,
    this.samlLabel,
  });

  factory IdentitiesInfo.fromJson(Map<String, dynamic> j) => IdentitiesInfo(
    identities: [
      for (final e in (j['identities'] as List? ?? const []))
        LinkedIdentity.fromJson((e as Map).cast<String, dynamic>()),
    ],
    available: [
      for (final p in (j['available'] as List? ?? const [])) p as String,
    ],
    samlLabel: ((j['labels'] as Map?) ?? const {})['saml'] as String?,
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
      _ => SsoFailed(j['error'] as String? ?? tr('회사 계정 로그인에 실패했습니다.')),
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
  final SamlSettings saml;

  /// 보안 키·패스키로 바로 로그인하게 할지, 그럴 수 있는 서버인지(웹 앱 주소가 있어야 한다).
  final bool passkeyLoginEnabled;
  final bool passkeysAvailable;

  /// 디렉터리 그룹 규칙 켜기·그룹에서 빠지면 빼기.
  final bool groupSyncEnabled;
  final bool groupSyncRemove;

  /// 이 앱에서 로그아웃할 때 회사 계정에서도 로그아웃할지와 Microsoft "프런트 채널 로그아웃 URL"에 넣을 주소.
  final bool idpLogout;
  final String? frontChannelLogoutUrl;

  const LoginSecuritySettings({
    required this.otpPolicy,
    required this.redirectUri,
    required this.ssoAutoCreate,
    required this.ssoDefaultRole,
    required this.ssoSessionDays,
    required this.google,
    required this.microsoft,
    required this.ldap,
    this.saml = const SamlSettings(),
    this.passkeyLoginEnabled = true,
    this.passkeysAvailable = false,
    this.groupSyncEnabled = false,
    this.groupSyncRemove = false,
    this.idpLogout = false,
    this.frontChannelLogoutUrl,
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
      saml: SamlSettings.fromJson(
        (j['saml'] as Map? ?? const {}).cast<String, dynamic>(),
      ),
      passkeyLoginEnabled: j['passkeyLoginEnabled'] != false,
      passkeysAvailable: j['passkeysAvailable'] == true,
      groupSyncEnabled: (j['groupSync'] as Map?)?['enabled'] == true,
      groupSyncRemove: (j['groupSync'] as Map?)?['removeUnmatched'] == true,
      idpLogout: (j['logout'] as Map?)?['idpLogout'] == true,
      frontChannelLogoutUrl:
          (j['logout'] as Map?)?['frontChannelUrl'] as String?,
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

  /// 조직도 맞추기 — 부서 방식('attribute' 부서 속성 글자 | 'ou' OU 경로를 트리로 | 'off'), 부서 트리의 시작 OU, 상위자(manager)
  /// 맞추기와 그 속성. [orgSyncAvailable]은 계정 단위 조직도인지(팀 단위면 쓸 수 없다).
  final String orgSource;
  final String orgBaseDn;
  final bool managerSync;
  final String managerAttr;
  final bool orgSyncAvailable;

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
    this.orgSource = 'attribute',
    this.orgBaseDn = '',
    this.managerSync = false,
    this.managerAttr = 'manager',
    this.orgSyncAvailable = false,
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
    orgSource: j['orgSource'] as String? ?? 'attribute',
    orgBaseDn: j['orgBaseDn'] as String? ?? '',
    managerSync: j['managerSync'] == true,
    managerAttr: j['managerAttr'] as String? ?? 'manager',
    orgSyncAvailable: j['orgSyncAvailable'] == true,
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

/// 관리자 콘솔 — SAML 2.0 IdP 설정과 IdP에 넣을 이 서버(SP)의 값.
class SamlSettings {
  final bool enabled;

  /// 로그인 단추 글(비우면 기본 "회사 계정(SAML)") — [buttonLabel]은 실제로 보일 글.
  final String label;
  final String buttonLabel;
  final String entryPoint;
  final String idpIssuer;
  final String idpCert;
  final String logoutUrl;
  final String emailAttr;
  final String nameAttr;
  final String groupsAttr;

  /// IdP에 넣을 값 — entityID·ACS·SLO·메타데이터 주소(웹 앱 주소가 없으면 null).
  final SamlSpInfo? sp;
  final String? problem;

  const SamlSettings({
    this.enabled = false,
    this.label = '',
    this.buttonLabel = '',
    this.entryPoint = '',
    this.idpIssuer = '',
    this.idpCert = '',
    this.logoutUrl = '',
    this.emailAttr = 'email',
    this.nameAttr = 'displayName',
    this.groupsAttr = 'groups',
    this.sp,
    this.problem,
  });

  factory SamlSettings.fromJson(Map<String, dynamic> j) => SamlSettings(
    enabled: j['enabled'] == true,
    label: j['label'] as String? ?? '',
    buttonLabel: j['buttonLabel'] as String? ?? '',
    entryPoint: j['entryPoint'] as String? ?? '',
    idpIssuer: j['idpIssuer'] as String? ?? '',
    idpCert: j['idpCert'] as String? ?? '',
    logoutUrl: j['logoutUrl'] as String? ?? '',
    emailAttr: j['emailAttr'] as String? ?? 'email',
    nameAttr: j['nameAttr'] as String? ?? 'displayName',
    groupsAttr: j['groupsAttr'] as String? ?? 'groups',
    sp: j['sp'] is Map
        ? SamlSpInfo.fromJson((j['sp'] as Map).cast<String, dynamic>())
        : null,
    problem: j['problem'] as String?,
  );
}

class SamlSpInfo {
  final String entityId;
  final String metadataUrl;
  final String acsUrl;
  final String sloUrl;
  const SamlSpInfo({
    required this.entityId,
    required this.metadataUrl,
    required this.acsUrl,
    required this.sloUrl,
  });

  factory SamlSpInfo.fromJson(Map<String, dynamic> j) => SamlSpInfo(
    entityId: j['entityId'] as String? ?? '',
    metadataUrl: j['metadataUrl'] as String? ?? '',
    acsUrl: j['acsUrl'] as String? ?? '',
    sloUrl: j['sloUrl'] as String? ?? '',
  );
}

/// IdP 메타데이터를 읽어 채울 값(POST /admin/login-security/saml-metadata — 저장은 따로).
class SamlMetadataFill {
  final String? idpIssuer;
  final String entryPoint;
  final String? logoutUrl;
  final String idpCert;
  const SamlMetadataFill({
    this.idpIssuer,
    required this.entryPoint,
    this.logoutUrl,
    required this.idpCert,
  });

  factory SamlMetadataFill.fromJson(Map<String, dynamic> j) => SamlMetadataFill(
    idpIssuer: j['idpIssuer'] as String?,
    entryPoint: j['entryPoint'] as String? ?? '',
    logoutUrl: j['logoutUrl'] as String?,
    idpCert: j['idpCert'] as String? ?? '',
  );
}

/// 그룹의 출처 — 서버 groupSyncRules.js GROUP_SOURCES.
const groupSources = ['any', 'ldap', 'saml', 'microsoft'];

String groupSourceLabel(String source) => switch (source) {
  'any' => tr('어디서든'),
  'ldap' => tr('사내 디렉터리(LDAP)'),
  'saml' => 'SAML',
  'microsoft' => 'Microsoft',
  _ => source,
};

/// 디렉터리 그룹 규칙 하나 — [group]이 맞으면 [teamId] 팀에 넣고 [accountRole] 등급으로.
class GroupMapping {
  final String id;
  final String source;
  final String group;
  final String? teamId;
  final String? teamName;

  /// 'guest' | 'member' | 'admin' | null(등급은 그대로).
  final String? accountRole;
  final DateTime? createdAt;
  const GroupMapping({
    required this.id,
    required this.source,
    required this.group,
    this.teamId,
    this.teamName,
    this.accountRole,
    this.createdAt,
  });

  factory GroupMapping.fromJson(Map<String, dynamic> j) => GroupMapping(
    id: j['id'] as String,
    source: j['source'] as String? ?? 'any',
    group: j['group'] as String? ?? '',
    teamId: j['teamId'] as String?,
    teamName: j['teamName'] as String?,
    accountRole: j['accountRole'] as String?,
    createdAt: j['createdAt'] is num
        ? DateTime.fromMillisecondsSinceEpoch((j['createdAt'] as num).toInt())
        : null,
  );
}

/// 등록한 보안 키·패스키 하나(내 프로필).
class Passkey {
  final String id;
  final String name;

  /// 여러 기기에 동기화되는 패스키(iCloud·Google 비밀번호 관리자 등)인지 — 아니면 그 키·기기에만 있다.
  final bool backedUp;

  /// 키가 알려 준 연결 방법('usb' | 'nfc' | 'ble' | 'internal' | 'hybrid').
  final List<String> transports;
  final DateTime? createdAt;
  final DateTime? lastUsedAt;
  const Passkey({
    required this.id,
    required this.name,
    this.backedUp = false,
    this.transports = const [],
    this.createdAt,
    this.lastUsedAt,
  });

  factory Passkey.fromJson(Map<String, dynamic> j) {
    DateTime? at(Object? v) =>
        v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
    return Passkey(
      id: j['id'] as String,
      name: j['name'] as String? ?? '',
      backedUp: j['backedUp'] == true,
      transports: (j['transports'] as List? ?? const [])
          .whereType<String>()
          .toList(),
      createdAt: at(j['createdAt']),
      lastUsedAt: at(j['lastUsedAt']),
    );
  }
}

/// 내 보안 키 목록과 이 서버에서 쓸 수 있는지(웹 앱 주소가 있어야 한다).
class PasskeysInfo {
  final List<Passkey> passkeys;
  final bool available;
  const PasskeysInfo({required this.passkeys, required this.available});

  factory PasskeysInfo.fromJson(Map<String, dynamic> j) => PasskeysInfo(
    passkeys: [
      for (final e in (j['passkeys'] as List? ?? const []))
        Passkey.fromJson((e as Map).cast<String, dynamic>()),
    ],
    available: j['available'] == true,
  );
}

/// 보안 키 확인 결과 묻기(POST /auth/passkeys/poll)의 답.
sealed class PasskeyPollResult {
  const PasskeyPollResult();
}

final class PasskeyPending extends PasskeyPollResult {
  const PasskeyPending();
}

/// 로그인됐다(비밀번호 없이 로그인·둘째 단계·로그인 중 등록) — 토큰. 등록이었으면 [passkey]도.
final class PasskeyDone extends PasskeyPollResult {
  final String accessToken;
  final String refreshToken;
  final String userId;
  final String username;
  final Passkey? passkey;
  const PasskeyDone({
    required this.accessToken,
    required this.refreshToken,
    required this.userId,
    required this.username,
    this.passkey,
  });
}

/// 내 프로필에서 등록했다.
final class PasskeyRegistered extends PasskeyPollResult {
  final Passkey passkey;
  const PasskeyRegistered(this.passkey);
}

final class PasskeyFailed extends PasskeyPollResult {
  final String message;
  const PasskeyFailed(this.message);
}

PasskeyPollResult passkeyPollResultFromJson(Map<String, dynamic> j) {
  Passkey? key() => j['passkey'] is Map
      ? Passkey.fromJson((j['passkey'] as Map).cast<String, dynamic>())
      : null;
  return switch (j['status']) {
    'pending' => const PasskeyPending(),
    'done' => PasskeyDone(
      accessToken: j['accessToken'] as String,
      refreshToken: j['refreshToken'] as String,
      userId: j['userId'] as String,
      username: j['username'] as String,
      passkey: key(),
    ),
    'registered' when key() != null => PasskeyRegistered(key()!),
    _ => PasskeyFailed(j['error'] as String? ?? tr('보안 키를 확인하지 못했습니다.')),
  };
}
