import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/login_security.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/app_toast.dart';
import '../widgets/integration_widgets.dart';
import '../l10n/tr.dart';
import 'admin_group_mappings.dart';
import 'admin_login_security_saml.dart';

/// 관리자 콘솔 "로그인 보안" 탭 — 2단계 인증 정책, 회사 계정 로그인(Google·Microsoft — OIDC, 그리고 SAML 2.0), 사내 디렉터리
/// (LDAP/Active Directory), 디렉터리 그룹 규칙(그룹 → 팀·등급), 보안 키·패스키 로그인, 로그아웃 연동
/// (server/src/admin.js /admin/login-security·/admin/group-mappings). 기존 아이디·비밀번호 로그인은 그대로 두고 그 위에 더한다.
///
/// 비밀값(클라이언트 보안 비밀·서비스 계정 비밀번호)은 서버가 다시 내려주지 않아 "설정됨"으로만 보이고 바꿀 때만 넣는다. 디렉터리는
/// 값을 저장 → "연결 시험" 통과 → 켜기 순서다(연결 값을 바꾸면 서버가 다시 끈다 — 메일 설정과 같다). SAML 칸은
/// [AdminSamlSection], 그룹 규칙 목록은 [AdminGroupMappingsSection](따로 파일) — 켜기·끄기 스위치는 모두 바로 저장한다.
class AdminLoginSecurityTab extends StatefulWidget {
  final Session session;
  const AdminLoginSecurityTab({super.key, required this.session});

  @override
  State<AdminLoginSecurityTab> createState() => _AdminLoginSecurityTabState();
}

class _AdminLoginSecurityTabState extends State<AdminLoginSecurityTab> {
  LoginSecuritySettings? _s;
  String? _error;
  bool _busy = false;

  // 회사 계정
  final _gClientId = TextEditingController();
  final _gSecret = TextEditingController();
  final _gDomains = TextEditingController();
  final _mTenant = TextEditingController();
  final _mClientId = TextEditingController();
  final _mSecret = TextEditingController();
  final _sessionDays = TextEditingController();
  // 디렉터리
  final _ldapUrl = TextEditingController();
  final _bindDn = TextEditingController();
  final _bindPassword = TextEditingController();
  final _baseDn = TextEditingController();
  final _filter = TextEditingController();
  final _nameAttr = TextEditingController();
  final _emailAttr = TextEditingController();
  final _deptAttr = TextEditingController();
  final _titleAttr = TextEditingController();
  final _testUser = TextEditingController();
  final _testPassword = TextEditingController();
  bool _tlsVerify = true;
  String? _testMessage;
  bool? _testOk;

  List<TextEditingController> get _all => [
    _gClientId,
    _gSecret,
    _gDomains,
    _mTenant,
    _mClientId,
    _mSecret,
    _sessionDays,
    _ldapUrl,
    _bindDn,
    _bindPassword,
    _baseDn,
    _filter,
    _nameAttr,
    _emailAttr,
    _deptAttr,
    _titleAttr,
    _testUser,
    _testPassword,
  ];

  @override
  void initState() {
    super.initState();
    for (final c in _all) {
      c.addListener(_refresh);
    }
    _load();
  }

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  void _refresh() => setState(() {});

  void _apply(LoginSecuritySettings s) {
    _s = s;
    _gClientId.text = s.google.clientId;
    _gSecret.clear();
    _gDomains.text = s.google.domains;
    _mTenant.text = s.microsoft.tenantId;
    _mClientId.text = s.microsoft.clientId;
    _mSecret.clear();
    _sessionDays.text = '${s.ssoSessionDays}';
    _ldapUrl.text = s.ldap.url;
    _bindDn.text = s.ldap.bindDn;
    _bindPassword.clear();
    _baseDn.text = s.ldap.baseDn;
    _filter.text = s.ldap.userFilter;
    _nameAttr.text = s.ldap.nameAttr;
    _emailAttr.text = s.ldap.emailAttr;
    _deptAttr.text = s.ldap.departmentAttr;
    _titleAttr.text = s.ldap.titleAttr;
    _tlsVerify = s.ldap.tlsVerify;
  }

  Future<void> _load() async {
    try {
      final s = await widget.session.api!.fetchLoginSecurity();
      if (mounted) setState(() => _apply(s));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// 바꾼다 — 성공하면 서버가 준 값으로 다시 채운다(저장 안 한 다른 칸도 서버 값으로 돌아간다).
  Future<void> _patch(Map<String, dynamic> patch, String done) async {
    setState(() => _busy = true);
    try {
      final s = await widget.session.api!.updateLoginSecurity(patch);
      if (!mounted) return;
      setState(() => _apply(s));
      showAppToast(context, done);
      // 로그인 화면의 단추·안내도 맞춘다.
      await widget.session.refreshLoginMethods();
    } catch (e) {
      if (mounted) showAppToast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _ssoDirty {
    final s = _s!;
    return _gClientId.text.trim() != s.google.clientId ||
        _gSecret.text.isNotEmpty ||
        _gDomains.text.trim() != s.google.domains ||
        _mTenant.text.trim() != s.microsoft.tenantId ||
        _mClientId.text.trim() != s.microsoft.clientId ||
        _mSecret.text.isNotEmpty ||
        _sessionDays.text.trim() != '${s.ssoSessionDays}';
  }

  bool get _ldapDirty {
    final l = _s!.ldap;
    return _ldapUrl.text.trim() != l.url ||
        _bindDn.text.trim() != l.bindDn ||
        _bindPassword.text.isNotEmpty ||
        _baseDn.text.trim() != l.baseDn ||
        _filter.text.trim() != l.userFilter ||
        _nameAttr.text.trim() != l.nameAttr ||
        _emailAttr.text.trim() != l.emailAttr ||
        _deptAttr.text.trim() != l.departmentAttr ||
        _titleAttr.text.trim() != l.titleAttr ||
        _tlsVerify != l.tlsVerify;
  }

  Future<void> _saveSso() => _patch({
    'ssoGoogleClientId': _gClientId.text.trim(),
    if (_gSecret.text.isNotEmpty) 'ssoGoogleClientSecret': _gSecret.text,
    'ssoGoogleDomains': _gDomains.text.trim(),
    'ssoMicrosoftTenantId': _mTenant.text.trim(),
    'ssoMicrosoftClientId': _mClientId.text.trim(),
    if (_mSecret.text.isNotEmpty) 'ssoMicrosoftClientSecret': _mSecret.text,
    'ssoSessionDays': int.tryParse(_sessionDays.text.trim()) ?? 0,
  }, tr('회사 계정 설정을 저장했습니다.'));

  Future<void> _saveLdap() => _patch({
    'ldapUrl': _ldapUrl.text.trim(),
    'ldapBindDn': _bindDn.text.trim(),
    if (_bindPassword.text.isNotEmpty) 'ldapBindPassword': _bindPassword.text,
    'ldapBaseDn': _baseDn.text.trim(),
    'ldapUserFilter': _filter.text.trim(),
    'ldapNameAttr': _nameAttr.text.trim(),
    'ldapEmailAttr': _emailAttr.text.trim(),
    'ldapDepartmentAttr': _deptAttr.text.trim(),
    'ldapTitleAttr': _titleAttr.text.trim(),
    'ldapTlsVerify': _tlsVerify,
  }, tr('디렉터리 설정을 저장했습니다. "연결 시험"을 해 보세요.'));

  Future<void> _testLdap() async {
    setState(() {
      _busy = true;
      _testMessage = null;
    });
    try {
      final r = await widget.session.api!.testLdap(
        username: _testUser.text.trim().isEmpty ? null : _testUser.text.trim(),
        password: _testPassword.text.isEmpty ? null : _testPassword.text,
      );
      if (!mounted) return;
      final p = r.profile;
      setState(() {
        _apply(r.view);
        _testOk = r.ok;
        _testMessage = [
          r.message,
          if (p != null)
            [
              p['email'],
              p['department'],
              p['title'],
            ].whereType<String>().join(' · '),
        ].where((s) => s.isNotEmpty).join('\n');
        _testPassword.clear();
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _testOk = false;
          _testMessage = e.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? hint,
    String? helper,
    bool obscure = false,
    Key? key,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      key: key,
      controller: c,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperMaxLines: 3,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    ),
  );

  Widget _section(String title, String description) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            description,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );
  }

  Widget _problem(String? problem) => problem == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            problem,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        );

  Widget _roleDropdown(String value, ValueChanged<String> onChanged, Key key) =>
      DropdownButton<String>(
        key: key,
        value: value,
        items: [
          DropdownMenuItem(value: 'member', child: Text(tr('정회원'))),
          DropdownMenuItem(value: 'guest', child: Text(tr('준회원'))),
        ],
        onChanged: _busy ? null : (v) => onChanged(v ?? value),
      );

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Text(_error!);
    final s = _s;
    if (s == null) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final redirect = s.redirectUri;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 2단계 인증 ──
          _section(
            tr('2단계 인증(OTP)'),
            tr(
              '로그인할 때 비밀번호와 함께 휴대폰 인증 앱(Google Authenticator 등)의 6자리 코드를 받습니다. 꼭 써야 하는 사람이 아직 켜지 않았으면 다음 로그인 때 그 자리에서 켜게 됩니다. 회사 계정(SSO)으로 들어오면 그쪽 2단계 인증을 쓰므로 묻지 않습니다. 휴대폰을 잃어버린 회원은 "회원" 탭의 메뉴에서 해제할 수 있습니다.',
            ),
          ),
          SegmentedButton<String>(
            key: const ValueKey('admin-otp-policy'),
            segments: [
              ButtonSegment(value: 'optional', label: Text(tr('각자 선택'))),
              ButtonSegment(value: 'admins', label: Text(tr('관리자는 필수'))),
              ButtonSegment(value: 'all', label: Text(tr('모두 필수'))),
            ],
            selected: {s.otpPolicy},
            onSelectionChanged: _busy
                ? null
                : (v) =>
                      _patch({'otpPolicy': v.first}, tr('2단계 인증 정책을 바꿨습니다.')),
          ),
          const SizedBox(height: 6),
          // 보안 키·패스키도 둘째 단계라 등록해 두면 "필수"를 채운다(인증 앱을 안 켜도 된다 — server/src/webauthn.js).
          Text(
            tr('보안 키·패스키를 등록한 회원은 인증 앱 없이도 "필수" 정책을 채웁니다.'),
            style: TextStyle(fontSize: 12, color: hint),
          ),
          const Divider(height: 32),

          // ── 회사 계정(SSO) ──
          _section(
            tr('회사 계정 로그인(Google·Microsoft)'),
            tr(
              '회사의 Google Workspace·Microsoft 365 계정으로 로그인합니다. 퇴사자는 회사 계정만 막으면 되고, 회사 계정의 2단계 인증이 그대로 적용됩니다. Google Cloud 콘솔(OAuth 클라이언트 — 웹 애플리케이션) 또는 Microsoft Entra 관리 센터(앱 등록)에서 앱을 만들고, 아래 "돌아올 주소"를 그쪽의 승인된 리디렉션 URI로 등록한 뒤 받은 값을 넣으세요.',
            ),
          ),
          if (redirect == null)
            Text(
              tr(
                '서버의 웹 앱 주소(정식 인증서 — WEB_DOMAIN)가 없어 회사 계정 로그인을 켤 수 없습니다. "DDNS" 탭의 웹 앱 주소를 먼저 설정하세요.',
              ),
              style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
            )
          else
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    tr('돌아올 주소: {redirect}', {'redirect': redirect}),
                    key: const ValueKey('admin-sso-redirect'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                IconButton(
                  tooltip: tr('복사'),
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: redirect));
                    if (context.mounted) showAppToast(context, tr('복사했습니다.'));
                  },
                ),
              ],
            ),
          const SizedBox(height: 8),
          SwitchListTile(
            key: const ValueKey('admin-sso-google-enabled'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Google 회사 계정 로그인')),
            value: s.google.enabled,
            onChanged: _busy || _ssoDirty || redirect == null
                ? null
                : (v) => _patch({
                    'ssoGoogleEnabled': v,
                  }, v ? tr('Google 로그인을 켰습니다.') : tr('Google 로그인을 껐습니다.')),
          ),
          _problem(s.google.enabled ? null : s.google.problem),
          _field(
            _gClientId,
            tr('클라이언트 ID'),
            hint: '…apps.googleusercontent.com',
          ),
          _field(
            _gSecret,
            s.google.hasClientSecret
                ? tr('새 클라이언트 보안 비밀 (바꿀 때만)')
                : tr('클라이언트 보안 비밀'),
            helper: s.google.hasClientSecret ? tr('보안 비밀: 설정됨') : null,
            obscure: true,
          ),
          _field(
            _gDomains,
            tr('받아들일 회사 도메인'),
            hint: tr('company.com (여럿이면 쉼표로)'),
            helper: tr('이 도메인의 Google Workspace 계정만 들어옵니다(개인 Gmail은 안 됨).'),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            key: const ValueKey('admin-sso-microsoft-enabled'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Microsoft 회사 계정 로그인')),
            value: s.microsoft.enabled,
            onChanged: _busy || _ssoDirty || redirect == null
                ? null
                : (v) => _patch(
                    {'ssoMicrosoftEnabled': v},
                    v ? tr('Microsoft 로그인을 켰습니다.') : tr('Microsoft 로그인을 껐습니다.'),
                  ),
          ),
          _problem(s.microsoft.enabled ? null : s.microsoft.problem),
          _field(
            _mTenant,
            tr('디렉터리(테넌트) ID'),
            hint: '1234abcd-…',
            helper: tr('Entra 관리 센터 "개요"의 테넌트 ID — 이 회사 사람만 들어옵니다.'),
          ),
          _field(_mClientId, tr('애플리케이션(클라이언트) ID')),
          _field(
            _mSecret,
            s.microsoft.hasClientSecret
                ? tr('새 클라이언트 암호 (바꿀 때만)')
                : tr('클라이언트 암호'),
            helper: s.microsoft.hasClientSecret ? tr('클라이언트 암호: 설정됨') : null,
            obscure: true,
          ),
          _field(
            _sessionDays,
            tr('회사 계정 다시 확인 주기(일)'),
            helper: tr('회사 계정으로만 들어오는 계정은 이 날수가 지나면 다시 회사 계정으로 로그인합니다(1~90).'),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const ValueKey('admin-sso-save'),
              onPressed: _busy || !_ssoDirty ? null : _saveSso,
              child: Text(tr('회사 계정 설정 저장')),
            ),
          ),
          SwitchListTile(
            key: const ValueKey('admin-sso-auto-create'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr('처음 들어온 회사 계정의 계정을 저절로 만들기')),
            subtitle: Text(
              tr(
                '끄면 이미 있는 계정에 연결한 사람만 들어옵니다. 같은 이메일의 계정이 있으면 그 이메일로 받은 코드를 넣어야 연결됩니다.',
              ),
              style: TextStyle(fontSize: 12, color: hint),
            ),
            value: s.ssoAutoCreate,
            onChanged: _busy
                ? null
                : (v) => _patch({'ssoAutoCreate': v}, tr('저장했습니다.')),
          ),
          Row(
            children: [
              Text(tr('새 계정 등급: ')),
              _roleDropdown(
                s.ssoDefaultRole,
                (v) => _patch({'ssoDefaultRole': v}, tr('저장했습니다.')),
                const ValueKey('admin-sso-role'),
              ),
            ],
          ),
          const Divider(height: 32),

          // ── SAML 2.0(admin_login_security_saml.dart) ──
          AdminSamlSection(
            session: widget.session,
            saml: s.saml,
            busy: _busy,
            onPatch: _patch,
          ),
          const Divider(height: 32),

          // ── 사내 디렉터리(LDAP) ──
          _section(
            tr('사내 디렉터리(LDAP/Active Directory)'),
            tr(
              '사내 Windows 도메인 계정 그대로 로그인합니다(로그인 화면의 같은 아이디·비밀번호 칸). 인터넷 없이 사내망에서 동작합니다. 같은 아이디의 기존 계정은 이메일이 디렉터리와 같을 때 연결되고, 연결된 계정은 디렉터리 비밀번호로만 들어옵니다. 디렉터리에서 계정을 막으면 늦어도 10분 안에 앱에서도 끊깁니다.',
            ),
          ),
          SwitchListTile(
            key: const ValueKey('admin-ldap-enabled'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr('디렉터리 로그인 사용')),
            subtitle: Text(
              s.ldap.testedAt == null
                  ? tr('값을 저장하고 "연결 시험"을 통과해야 켤 수 있습니다.')
                  : tr('시험 통과: {p0}', {'p0': formatDateTime(s.ldap.testedAt!)}),
              style: TextStyle(fontSize: 12, color: hint),
            ),
            value: s.ldap.enabled,
            onChanged:
                _busy ||
                    (!s.ldap.enabled && (s.ldap.testedAt == null || _ldapDirty))
                ? null
                : (v) => _patch({
                    'ldapEnabled': v,
                  }, v ? tr('디렉터리 로그인을 켰습니다.') : tr('디렉터리 로그인을 껐습니다.')),
          ),
          _field(
            _ldapUrl,
            tr('LDAP 서버 주소'),
            hint: 'ldaps://dc01.company.local:636',
            helper: _ldapUrl.text.trim().startsWith('ldap://')
                ? tr('ldap://는 비밀번호가 암호화되지 않고 사내망을 지나갑니다 — 되도록 ldaps://를 쓰세요.')
                : null,
            key: const ValueKey('admin-ldap-url'),
          ),
          _field(
            _bindDn,
            tr('서비스 계정 DN'),
            hint: 'CN=tangotalk,OU=Service,DC=company,DC=local',
            helper: tr('사람을 찾을 때 쓰는 읽기 전용 계정(비우면 익명 검색).'),
          ),
          _field(
            _bindPassword,
            s.ldap.hasBindPassword
                ? tr('새 서비스 계정 비밀번호 (바꿀 때만)')
                : tr('서비스 계정 비밀번호'),
            helper: s.ldap.hasBindPassword ? tr('비밀번호: 설정됨') : null,
            obscure: true,
          ),
          _field(_baseDn, tr('검색 위치(Base DN)'), hint: 'DC=company,DC=local'),
          _field(
            _filter,
            tr('사용자 검색 조건'),
            helper: tr('{username} 자리에 로그인 화면에 넣은 아이디가 들어갑니다.'),
          ),
          Row(
            children: [
              Expanded(child: _field(_nameAttr, tr('이름 속성'))),
              const SizedBox(width: 8),
              Expanded(child: _field(_emailAttr, tr('이메일 속성'))),
            ],
          ),
          Row(
            children: [
              Expanded(child: _field(_deptAttr, tr('부서 속성'))),
              const SizedBox(width: 8),
              Expanded(child: _field(_titleAttr, tr('직책 속성'))),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('ldaps:// 인증서 확인')),
            subtitle: Text(
              tr('사내 인증 기관 인증서라 확인이 안 되면 끄세요(사내망 안에서만).'),
              style: TextStyle(fontSize: 12, color: hint),
            ),
            value: _tlsVerify,
            onChanged: _busy ? null : (v) => setState(() => _tlsVerify = v),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const ValueKey('admin-ldap-save'),
              onPressed: _busy || !_ldapDirty ? null : _saveLdap,
              child: Text(tr('디렉터리 설정 저장')),
            ),
          ),
          const SizedBox(height: 8),
          Text(tr('연결 시험'), style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: _field(_testUser, tr('찾아볼 아이디(선택)'))),
              const SizedBox(width: 8),
              Expanded(
                child: _field(_testPassword, tr('그 비밀번호(선택)'), obscure: true),
              ),
            ],
          ),
          Row(
            children: [
              OutlinedButton(
                key: const ValueKey('admin-ldap-test'),
                onPressed: _busy || _ldapDirty || s.ldap.problem != null
                    ? null
                    : _testLdap,
                child: Text(tr('연결 시험')),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _ldapDirty
                      ? tr('바꾼 값을 먼저 저장하세요.')
                      : s.ldap.problem ??
                            tr(
                              '아이디를 넣으면 그 사람을 찾아 보고, 비밀번호까지 넣으면 로그인도 해 봅니다(남기지 않음).',
                            ),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              ),
            ],
          ),
          if (_testMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _testMessage!,
                key: const ValueKey('admin-ldap-test-result'),
                style: TextStyle(
                  color: _testOk == true
                      ? Colors.green
                      : theme.colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: 8),
          SwitchListTile(
            key: const ValueKey('admin-ldap-auto-create'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr('처음 들어온 디렉터리 계정의 계정을 저절로 만들기')),
            value: s.ldap.autoCreate,
            onChanged: _busy
                ? null
                : (v) => _patch({'ldapAutoCreate': v}, tr('저장했습니다.')),
          ),
          Row(
            children: [
              Text(tr('새 계정 등급: ')),
              _roleDropdown(
                s.ldap.defaultRole,
                (v) => _patch({'ldapDefaultRole': v}, tr('저장했습니다.')),
                const ValueKey('admin-ldap-role'),
              ),
            ],
          ),
          const Divider(height: 32),

          // ── 디렉터리 그룹 규칙(server/src/groupSync.js) — 켜기·빼기는 서버 설정, 규칙 목록은 admin_group_mappings.dart ──
          _section(
            tr('디렉터리 그룹 규칙'),
            tr(
              '사내 디렉터리·SAML·Microsoft가 알려 준 그룹에 따라 팀에 넣고 계정 등급을 정합니다. 로그인할 때마다 맞추고, 디렉터리(LDAP) 계정은 10분마다도 맞춥니다.',
            ),
          ),
          SwitchListTile(
            key: const ValueKey('group-sync-enabled'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr('그룹 규칙 켜기')),
            value: s.groupSyncEnabled,
            onChanged: _busy
                ? null
                : (v) => _patch({
                    'groupSyncEnabled': v,
                  }, v ? tr('그룹 규칙을 켰습니다.') : tr('그룹 규칙을 껐습니다.')),
          ),
          SwitchListTile(
            key: const ValueKey('group-sync-remove'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr('그룹에서 빠지면 팀에서 빼고 등급 되돌리기')),
            subtitle: Text(
              tr(
                '규칙으로 넣은 팀·등급만 되돌립니다. 팀 소유자와 직접 넣은 팀 멤버는 그대로 두고, 관리자가 손으로 바꾼 등급도 되돌리지 않습니다. 서버 관리자 권한은 건드리지 않습니다.',
              ),
              style: TextStyle(fontSize: 12, color: hint),
            ),
            value: s.groupSyncRemove,
            onChanged: _busy || !s.groupSyncEnabled
                ? null
                : (v) => _patch({'groupSyncRemove': v}, tr('저장했습니다.')),
          ),
          const SizedBox(height: 4),
          AdminGroupMappingsSection(session: widget.session),
          const Divider(height: 32),

          // ── 보안 키·패스키(server/src/webauthn.js) ──
          _section(
            tr('보안 키·패스키'),
            tr(
              '회원이 내 프로필에서 등록한 보안 키(YubiKey 등)·패스키는 늘 2단계 인증으로 쓸 수 있습니다. 여기서는 비밀번호 없이 그것만으로 로그인하게 할지 정합니다.',
            ),
          ),
          if (!s.passkeysAvailable)
            Text(
              tr(
                '서버의 웹 앱 주소(정식 인증서 — WEB_DOMAIN)가 없어 보안 키·패스키를 쓸 수 없습니다. "DDNS" 탭의 웹 앱 주소를 먼저 설정하세요.',
              ),
              key: const ValueKey('passkey-unavailable'),
              style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
            ),
          SwitchListTile(
            key: const ValueKey('passkey-login-enabled'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr('보안 키·패스키로 비밀번호 없이 로그인 허용')),
            value: s.passkeyLoginEnabled,
            onChanged: _busy
                ? null
                : (v) => _patch(
                    {'passkeyLoginEnabled': v},
                    v
                        ? tr('보안 키·패스키 로그인을 허용했습니다.')
                        : tr('보안 키·패스키 로그인을 막았습니다.'),
                  ),
          ),
          const Divider(height: 32),

          // ── 로그아웃 연동(server/src/ssoSessions.js) ──
          _section(
            tr('로그아웃 연동'),
            tr(
              'Microsoft: 앱 등록의 "프런트 채널 로그아웃 URL"에 아래 주소를 넣고, 토큰 구성에서 ID 토큰에 선택적 클레임 sid를 더하면 회사 계정에서 로그아웃할 때 TangoTalk 로그인도 끝납니다. SAML: IdP의 Single Logout이 위 SLO URL로 보냅니다. Google은 로그아웃 연동이 없습니다.',
            ),
          ),
          SwitchListTile(
            key: const ValueKey('sso-idp-logout'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr('이 앱에서 로그아웃하면 회사 계정(Microsoft·SAML)에서도 로그아웃')),
            value: s.idpLogout,
            onChanged: _busy
                ? null
                : (v) => _patch({'ssoIdpLogout': v}, tr('저장했습니다.')),
          ),
          if (s.frontChannelLogoutUrl != null) ...[
            Text(tr('프런트 채널 로그아웃 URL'), style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 2),
            CopyableSecretField(
              value: s.frontChannelLogoutUrl!,
              fieldKey: const ValueKey('sso-front-channel-url'),
            ),
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
