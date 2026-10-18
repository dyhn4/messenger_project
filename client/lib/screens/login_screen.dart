import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../models/login_security.dart';
import '../services/api_client.dart' show AuthResult;
import '../services/password_policy.dart';
import '../services/pinned_tls.dart';
import '../services/security_questions.dart';
import '../services/session.dart';
import '../widgets/email_address_field.dart';
import '../widgets/email_code_input.dart';
import '../widgets/otp_dialogs.dart';
import '../widgets/passkey_dialogs.dart';
import '../widgets/sso_dialogs.dart';
import '../widgets/update_dialog.dart';
import 'find_id_screen.dart';
import 'find_password_screen.dart';
import 'my_profile_dialog.dart' show kProfileNameMaxLength;
import '../l10n/tr.dart';
import '../widgets/language_picker.dart';

const _loginGreen = Color(0xFF6FCF97);

/// 새로 정하는 아이디의 규칙 — 영문·숫자와 . _ - 만, 4~20자. 서버(server/src/authGuard.js의 USERNAME_PATTERN)와 같은
/// 규칙이라, 보내기 전에 여기서 먼저 알려 준다(최종 판단은 서버가 한다). 아이디는 다른 사람이 "이 사람이 맞는지"
/// 확인하는 값이라 띄어쓰기·한글·비슷하게 생긴 다른 글자로 기존 아이디를 흉내 내지 못하게 한다. 대소문자만 다른
/// 아이디도 서버가 같은 아이디로 보고 "이미 사용 중"이라고 답한다.
final kSignupUsernamePattern = RegExp(r'^[A-Za-z0-9._-]{4,20}$');

/// 아이디 규칙을 어겼을 때의 안내 — 서버 USERNAME_RULE_ERROR와 같은 문구.
final kSignupUsernameRule = tr(
  '아이디는 영문·숫자와 . _ - 만 써서 4~20자로 정하세요(한글·띄어쓰기·그 밖의 기호는 쓸 수 없습니다).',
);

/// 회원가입 아이디 칸 아래에 늘 보이는 안내.
final kSignupUsernameHelper = tr('영문, 숫자와 . _ - 만 쓸 수 있습니다 (4~20자)');

/// 회원가입에 쓸 아이디가 규칙에 맞는지 — 맞으면 null, 아니면 [kSignupUsernameRule]. 앞뒤 공백은 보낼 때처럼 떼고 본다.
String? signupUsernameError(String raw) =>
    kSignupUsernamePattern.hasMatch(raw.trim()) ? null : kSignupUsernameRule;

// 보안 질문은 문장이 길어서(최대 28자 남짓) 기본 크기로는 드롭다운에서 잘린다 — 목록/선택
// 표시 양쪽에 같은 크기를 쓴다.
const _questionStyle = TextStyle(fontSize: 13, color: Colors.black87);

class LoginScreen extends StatefulWidget {
  final Session session;
  const LoginScreen({super.key, required this.session});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _scrollController = ScrollController();
  final _username = TextEditingController();
  final _name = TextEditingController();
  String _email = '';
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  final _customSecurityQuestion = TextEditingController();
  final _securityAnswer = TextEditingController();

  /// 메일이 켜진 서버의 가입 — 이메일로 받은 인증 코드. [_codeSentFor]는 코드를 보낸 주소(그 뒤 이메일을 바꿨으면 다시 받게).
  final _emailCode = TextEditingController();
  String? _codeSentFor;
  String? _securityQuestionChoice;
  bool _securityQuestionCustomMode = false;
  bool _isRegister = false;
  bool _loading = false;
  bool _rememberUsername = false;
  late bool _keepSignedIn = widget.session.keepSignedInPref;

  // null = 아직 중복 확인을 안 했거나(또는 확인 후 아이디를 다시 고쳐서 무효화된) 상태.
  bool? _usernameAvailable;
  bool _usernameChecking = false;
  String? _usernameCheckMessage;

  @override
  void initState() {
    super.initState();
    final remembered = widget.session.rememberedUsername;
    if (remembered != null) {
      _username.text = remembered;
      _rememberUsername = true;
    }
    _password.addListener(_refresh);
    _confirmPassword.addListener(_refresh);
    _maybeShowPairDialog();
    _maybeShowUpdateBanner();
    // 관리자가 그사이 메일 기능을 켜거나 껐을 수 있다 — 가입 폼(인증 코드/보안 질문)을 그에 맞춘다(바뀌면 세션이 알려 다시 그린다).
    widget.session.refreshMailEnabled();
    // 회사 계정(SSO) 단추·회사 디렉터리 안내도 관리자가 그사이 켜거나 껐을 수 있다.
    widget.session.refreshLoginMethods();
  }

  @override
  void didUpdateWidget(covariant LoginScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // MyApp이 session이 바뀔 때마다 이 화면을 새로 만들어 넘겨주므로, 로그인 화면을
    // 보고 있는 동안 초대 링크가 도착해도(또는 다시 눌러 이 창이 앞으로 온 경우도)
    // didUpdateWidget으로 매번 잡아낼 수 있다.
    _maybeShowPairDialog();
    // session.init()이 서버 주소를 알자마자(로그인 전에도) 업데이트 확인을 비동기로 시작해서
    // (_checkForUpdate), 로그인 화면을 보고 있는 동안 응답이 도착하는 경우가 흔하다 —
    // HomeScreen과 같은 방식으로, 로그인하지 않고도 바로 업데이트 안내가 뜨게 한다.
    _maybeShowUpdateBanner();
  }

  /// session.dart의 _checkForUpdate()가 새 버전을 찾으면 한 번만 대화상자를 띄운다
  /// (home_screen.dart의 같은 이름 메서드와 동일한 목적 — 로그인 전 화면에도 필요하다).
  /// "이미 띄웠는지"는 session에 두고 HomeScreen과 공유한다 — 로그인 전에 이미 봤으면
  /// 로그인 직후 또 뜨지 않게.
  void _maybeShowUpdateBanner() {
    final version = widget.session.updateAvailableVersion;
    if (version == null || widget.session.updateBannerShown) return;
    widget.session.updateBannerShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (_) => UpdateDialog(session: widget.session, version: version),
      );
    });
  }

  /// 초대 링크로 받은 서버 주소/코드가 있으면 "서버 주소 변경" 다이얼로그를 그 값으로
  /// 미리 채워 자동으로 띄운다 — 연결 자체는 사용자가 다이얼로그에서 직접 눌러야 한다.
  void _maybeShowPairDialog() {
    final req = widget.session.consumePendingPairRequest();
    if (req == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => _ServerAddressDialog(
          session: widget.session,
          initialAddress: req.address,
          initialCode: req.code,
        ),
      );
    });
  }

  void _refresh() => setState(() {});

  /// 로그인/회원가입 폼 전환. "아이디 기억하기"로 로그인 칸에 남아있던 아이디가 회원가입
  /// 칸에도 그대로 보이는 게 아니라, 회원가입으로 넘어가면 새로 가입할 아이디를 적을 수
  /// 있도록 비워준다. 다시 로그인으로 돌아오면 원래 기억해둔 아이디를 그대로 복원한다.
  void _toggleMode() {
    setState(() {
      _isRegister = !_isRegister;
      if (_isRegister) {
        _username.clear();
        _usernameAvailable = null;
        _usernameCheckMessage = null;
      } else {
        _username.text = widget.session.rememberedUsername ?? '';
      }
    });
  }

  void _onUsernameChanged(String _) {
    if (_usernameAvailable != null || _usernameCheckMessage != null) {
      setState(() {
        _usernameAvailable = null;
        _usernameCheckMessage = null;
      });
    }
  }

  Future<void> _checkUsername() async {
    final username = _username.text.trim();
    if (username.isEmpty) return;
    // 규칙(영문·숫자·. _ -, 4~20자)에 안 맞으면 서버에 묻지 않고 바로 알려 준다.
    final ruleError = signupUsernameError(username);
    if (ruleError != null) {
      setState(() {
        _usernameAvailable = false;
        _usernameCheckMessage = ruleError;
      });
      return;
    }
    setState(() {
      _usernameChecking = true;
      _usernameCheckMessage = null;
    });
    try {
      final reason = await widget.session.api!.checkUsernameAvailable(
        username,
        inviteToken: widget.session.pendingTeamInviteToken,
      );
      if (!mounted) return;
      setState(() {
        _usernameAvailable = reason == null;
        _usernameCheckMessage = reason ?? tr('사용 가능한 아이디입니다.');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _usernameAvailable = false;
        _usernameCheckMessage = e.toString();
      });
    } finally {
      if (mounted) setState(() => _usernameChecking = false);
    }
  }

  bool get _canSubmitRegister => _usernameAvailable == true;

  Future<void> _submit() async {
    if (_isRegister) {
      final usernameError = signupUsernameError(_username.text);
      if (usernameError != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(usernameError)));
        return;
      }
      if (_usernameAvailable != true) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('아이디 중복 확인을 해주세요.'))));
        return;
      }
      final passwordError = passwordPolicyError(_password.text);
      if (passwordError != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(passwordError)));
        return;
      }
      if (_password.text != _confirmPassword.text) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('비밀번호가 서로 다릅니다.'))));
        return;
      }
      if (widget.session.mailEnabled) {
        // 메일이 켜진 서버는 보안 질문 대신 이메일로 받은 코드로 본인을 확인한다.
        final codeError = _codeSentFor == null
            ? tr('이메일 인증 코드를 받아 넣어 주세요.')
            : _codeSentFor != _email
            ? tr('이메일을 바꿨다면 인증 코드를 다시 받으세요.')
            : !isEmailCodeShape(_emailCode.text)
            ? tr('메일로 받은 6자리 인증 코드를 넣어 주세요.')
            : null;
        if (codeError != null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(codeError)));
          return;
        }
      } else {
        final question = _resolvedSecurityQuestion();
        if (question == null || _securityAnswer.text.trim().isEmpty) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(tr('보안 질문과 답변을 입력하세요.'))));
          return;
        }
      }
    }
    final byMail = widget.session.mailEnabled;
    // login()이 성공하면 그 안에서 stage=ready로 바뀌며 곧장 HomeScreen으로 전환되어
    // 이 화면(LoginScreen)이 언마운트된다 — 그 뒤에 컨트롤러를 읽으면(이미 dispose된 뒤라)
    // 죽은 컨트롤러 접근 크래시가 나고, mounted 체크로 건너뛰면 "아이디 기억하기"가 아예
    // 저장되지 않는다. 그래서 필요한 값은 await 전에 미리 지역 변수로 뽑아둔다.
    final rememberUsername = _rememberUsername;
    final keepSignedIn = _keepSignedIn;
    final usernameText = _username.text.trim();
    setState(() => _loading = true);
    bool ok;
    try {
      ok = _isRegister
          ? await widget.session.register(
              usernameText,
              _password.text,
              _email,
              _name.text.trim(),
              securityQuestion: byMail ? null : _resolvedSecurityQuestion()!,
              securityAnswer: byMail ? null : _securityAnswer.text.trim(),
              emailCode: byMail ? _emailCode.text.trim() : null,
              keepSignedIn: true,
            )
          : await widget.session.login(
              usernameText,
              _password.text,
              keepSignedIn: keepSignedIn,
            );
    } on OtpChallenge catch (challenge) {
      // 비밀번호는 맞았고 2단계 인증이 남았다 — 코드를 묻거나(켠 사람) 그 자리에서 켜게 한다(관리자가 꼭 쓰게 정한 사람).
      if (!mounted) return;
      setState(() => _loading = false);
      final auth = await _secondFactor(challenge);
      if (auth == null || !mounted) return;
      setState(() => _loading = true);
      ok = await widget.session.signInWith(auth, keepSignedIn: keepSignedIn);
    }
    if (ok && !_isRegister) {
      await widget.session.setRememberedUsername(
        rememberUsername ? usernameText : null,
      );
      // "로그인 상태 유지" 체크박스 자체의 표시값도 "아이디 기억하기"처럼 다음에 로그인
      // 화면을 열 때 그대로 보이도록 저장해둔다(로그아웃해도 이 값은 안 지워진다).
      await widget.session.setKeepSignedInPref(keepSignedIn);
    }
    if (!mounted) return;
    setState(() => _loading = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.session.error ?? tr('실패했습니다.'))),
      );
      return;
    }
  }

  /// 2단계 인증 — 확인 표로 코드를 넣거나(켠 사람) 켜기(정책상 꼭 써야 하는데 아직 안 켠 사람)를 마쳐 토큰을 받는다. 취소하면 null.
  /// 서버가 준 방법([OtpChallenge.methods])에 보안 키('webauthn')가 있으면 코드 창에 "보안 키로 확인"도 보이고, 보안 키만 있는
  /// 사람(인증 앱은 안 켬)은 코드 창 없이 바로 보안 키 확인으로 간다. 꼭 써야 하는데 아무것도 없는 사람은 인증 앱 켜기와 보안 키
  /// 등록 중에서 고른다. 어느 길이든 끝에 받은 토큰은 똑같이 [Session.signInWith]로 넘긴다.
  Future<AuthResult?> _secondFactor(OtpChallenge challenge) async {
    final api = widget.session.api!;
    if (!challenge.setupRequired) {
      if (!challenge.canUseTotp && challenge.canUsePasskey) {
        return showPasskeySecondFactorDialog(
          context,
          api: api,
          ticket: challenge.ticket,
        );
      }
      return showOtpLoginDialog(
        context,
        api: api,
        ticket: challenge.ticket,
        canUsePasskey: challenge.canUsePasskey,
      );
    }
    final choice = await showOtpSetupChoiceDialog(context);
    if (choice == null || !mounted) return null;
    if (choice == OtpSetupChoice.passkey) {
      return showPasskeySetupDialog(
        context,
        api: api,
        ticket: challenge.ticket,
      );
    }
    final done = await showOtpSetupDialog(
      context,
      api: api,
      ticket: challenge.ticket,
    );
    return done?.auth;
  }

  /// 회사 계정(Google·Microsoft·SAML)으로 로그인 — 브라우저에서 로그인하고 돌아오면 이어서 들어간다(sso_dialogs.dart).
  Future<void> _loginWithSso(String provider) async {
    final auth = await showSsoLoginDialog(
      context,
      api: widget.session.api!,
      provider: provider,
      samlLabel: widget.session.loginMethods.samlLabel,
    );
    await _finishExternalLogin(auth);
  }

  /// 보안 키·패스키로 바로(비밀번호 없이) 로그인 — 브라우저에서 키를 쓰고 돌아오면 이어서 들어간다(passkey_dialogs.dart). 키가
  /// 사람을 확인하므로 2단계 인증을 따로 묻지 않는다(서버 webauthn.js).
  Future<void> _loginWithPasskey() async {
    final auth = await showPasskeyLoginDialog(
      context,
      api: widget.session.api!,
    );
    await _finishExternalLogin(auth);
  }

  /// 회사 계정·보안 키로 받은 토큰으로 들어간다 — 취소했으면([auth]가 null) 아무것도 하지 않는다. "로그인 상태 유지"는 지금
  /// 체크박스 값(창이 떠 있는 동안에는 바꿀 수 없다)을 들어가기 전에 뽑아 둔다 — 들어가면 이 화면이 사라진다([_submit]과 같은 까닭).
  Future<void> _finishExternalLogin(AuthResult? auth) async {
    if (auth == null || !mounted) return;
    final keepSignedIn = _keepSignedIn;
    setState(() => _loading = true);
    final ok = await widget.session.signInWith(
      auth,
      keepSignedIn: keepSignedIn,
    );
    if (ok) await widget.session.setKeepSignedInPref(keepSignedIn);
    if (!mounted) return;
    setState(() => _loading = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.session.error ?? tr('실패했습니다.'))),
      );
    }
  }

  /// 회사 계정 단추 글 — SAML은 관리자가 정한 IdP 이름으로("Okta 로그인" — 안 정했으면 "회사 계정(SAML) 로그인". 이름이 받침으로
  /// 끝나도 어색하지 않게 조사를 붙이지 않는다),
  /// Google·Microsoft는 "… 회사 계정으로 로그인".
  String _ssoButtonLabel(String provider) => provider == 'saml'
      ? tr('{label} 로그인', {
          'label': ssoProviderLabel(
            'saml',
            samlLabel: widget.session.loginMethods.samlLabel,
          ),
        })
      : tr('{p0} 회사 계정으로 로그인', {'p0': ssoProviderLabel(provider)});

  /// 로그인 단추 아래 — 회사 계정 로그인 단추들과 보안 키·패스키 로그인 단추(서버가 켠 것만).
  List<Widget> _ssoButtons() {
    final methods = widget.session.loginMethods;
    final providers = methods.sso;
    if (_isRegister || (providers.isEmpty && !methods.passkey)) {
      return const [];
    }
    return [
      const SizedBox(height: 12),
      Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              tr('또는'),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).hintColor,
              ),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
      const SizedBox(height: 12),
      for (final p in providers)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: OutlinedButton.icon(
            key: ValueKey('login-sso-$p'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _loading ? null : () => _loginWithSso(p),
            icon: const Icon(Icons.business_center_outlined),
            label: Text(_ssoButtonLabel(p)),
          ),
        ),
      if (methods.passkey)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: OutlinedButton.icon(
            key: const ValueKey('login-passkey'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _loading ? null : _loginWithPasskey,
            icon: const Icon(Icons.key),
            label: Text(tr('보안 키·패스키로 로그인')),
          ),
        ),
    ];
  }

  /// "직접 작성"/"목록에서 선택" 토글 결과를 실제로 서버에 보낼 질문 문자열로 바꾼다.
  /// 직접 작성인데 아직 질문을 안 적었거나, 목록에서 아직 아무것도 안 골랐으면 null.
  String? _resolvedSecurityQuestion() {
    if (_securityQuestionCustomMode) {
      final custom = _customSecurityQuestion.text.trim();
      return custom.isEmpty ? null : custom;
    }
    return _securityQuestionChoice;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _username.dispose();
    _name.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    _customSecurityQuestion.dispose();
    _securityAnswer.dispose();
    _emailCode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F4),
      // 화면 언어 — 로그인하기 전에도 고를 수 있게 오른쪽 위에(language_picker.dart).
      floatingActionButtonLocation: FloatingActionButtonLocation.endTop,
      floatingActionButton: const LanguagePicker(compact: true),
      body: Center(
        child: Scrollbar(
          controller: _scrollController,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Container(
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 20,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                // 카드 배경이 항상 흰색으로 고정돼 있는데(위 decoration), 시스템이 다크 모드면
                // 글자/테두리 색은 여전히 다크 테마(밝은 색)를 그대로 물려받아서 흰 배경 위에
                // 흐릿하게(뿌옇게) 보이는 문제가 있었다 — 로그인 카드 안쪽만 항상 라이트 테마로
                // 고정해서, 시스템 다크 모드와 무관하게 대비가 항상 확보되게 한다.
                child: Theme(
                  data: ThemeData(
                    colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
                    useMaterial3: true,
                  ),
                  // Theme만으로는 TextButton/TextField처럼 스스로 Theme.of(context)를 읽는
                  // 위젯들만 바뀐다 — 색을 안 정해준 평범한 Text("로그인" 제목)는 이 Theme
                  // 바깥(Scaffold)에서 이미 정해진 DefaultTextStyle을 그대로 물려받아서 여전히
                  // 흐릿하게 남아있었다. Material을 한 겹 더 두면 그 DefaultTextStyle을 지금
                  // Theme 기준으로 다시 잡아줘서 제목까지 포함해 전부 대비가 확보된다.
                  child: Material(
                    type: MaterialType.transparency,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _isRegister ? tr('회원가입') : tr('로그인'),
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 24),
                        if (_isRegister) ...[
                          if (_usernameCheckMessage != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text(
                                _usernameCheckMessage!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _usernameAvailable == true
                                      ? const Color(0xFF2FA36B)
                                      : Colors.redAccent,
                                ),
                              ),
                            ),
                          TextField(
                            controller: _username,
                            maxLength: 20,
                            onChanged: _onUsernameChanged,
                            decoration: InputDecoration(
                              hintText: tr('아이디 입력 (영문·숫자 4~20자)'),
                              // 쓸 수 있는 글자를 미리 보여 준다(서버 규칙과 같다 — kSignupUsernamePattern).
                              helperText: kSignupUsernameHelper,
                              counterText: '',
                              border: const OutlineInputBorder(),
                              // 버튼을 입력칸 안쪽 오른쪽 끝에 넣는다. 기본 suffixIcon 제약은
                              // 정사각형 아이콘 기준이라 버튼이 잘리므로 제약을 풀어준다.
                              suffixIconConstraints: const BoxConstraints(
                                minWidth: 0,
                                minHeight: 0,
                              ),
                              suffixIcon: Padding(
                                padding: const EdgeInsets.all(6),
                                child: FilledButton(
                                  onPressed: _usernameChecking
                                      ? null
                                      : _checkUsername,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: _loginGreen,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                    ),
                                    minimumSize: const Size(0, 36),
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    textStyle: const TextStyle(fontSize: 13),
                                  ),
                                  child: _usernameChecking
                                      ? const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : Text(tr('중복 확인')),
                                ),
                              ),
                            ),
                          ),
                        ] else ...[
                          TextField(
                            controller: _username,
                            decoration: InputDecoration(
                              labelText: tr('아이디'),
                              // 회사 디렉터리(LDAP)가 켜진 서버 — 같은 칸에 회사(Windows) 계정을 넣어도 된다.
                              helperText: widget.session.loginMethods.ldap
                                  ? tr('회사(Windows) 계정 아이디·비밀번호로도 로그인할 수 있습니다.')
                                  : null,
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        TextField(
                          controller: _password,
                          maxLength: _isRegister ? kPasswordMaxLength : null,
                          decoration: InputDecoration(
                            labelText: tr('비밀번호'),
                            hintText: _isRegister ? kPasswordHint : null,
                            counterText: _isRegister ? '' : null,
                            border: const OutlineInputBorder(),
                          ),
                          obscureText: true,
                          onSubmitted: _isRegister ? null : (_) => _submit(),
                        ),
                        if (_isRegister) ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: _confirmPassword,
                            decoration: InputDecoration(
                              labelText: tr('비밀번호 확인'),
                              errorText:
                                  _confirmPassword.text.isNotEmpty &&
                                      _confirmPassword.text != _password.text
                                  ? tr('비밀번호가 일치하지 않습니다')
                                  : null,
                              border: const OutlineInputBorder(),
                            ),
                            obscureText: true,
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _name,
                            // 서버 가입 규칙(이름 30자 이내 — 프로필 이름 변경과 같다)에 맞춰 입력 단계에서 자른다.
                            maxLength: kProfileNameMaxLength,
                            decoration: InputDecoration(
                              labelText: tr('이름'),
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            tr('이메일 주소'),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          EmailAddressField(onChanged: (v) => _email = v),
                          const SizedBox(height: 4),
                          Text(
                            tr('아이디, 비밀번호 찾기에 이용됩니다'),
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                          const SizedBox(height: 16),
                          // 메일이 켜진 서버는 이메일 인증 코드가 보안 질문을 대신한다(server auth.js /register).
                          if (widget.session.mailEnabled)
                            EmailCodeInput(
                              key: const ValueKey('signup-email-code'),
                              controller: _emailCode,
                              onSend: () {
                                final email = _email.trim();
                                return widget.session.sendSignupEmailCode(
                                  email,
                                );
                              },
                              onSent: (_) => _codeSentFor = _email,
                            )
                          else
                            _SecurityQuestionSection(
                              customMode: _securityQuestionCustomMode,
                              onModeChanged: (custom) => setState(
                                () => _securityQuestionCustomMode = custom,
                              ),
                              presetChoice: _securityQuestionChoice,
                              onPresetChanged: (v) =>
                                  setState(() => _securityQuestionChoice = v),
                              customQuestionController: _customSecurityQuestion,
                              answerController: _securityAnswer,
                            ),
                        ],
                        if (!_isRegister) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            runSpacing: 4,
                            children: [
                              Wrap(
                                spacing: 4,
                                children: [
                                  _CheckboxLabel(
                                    label: tr('아이디 기억하기'),
                                    value: _rememberUsername,
                                    onChanged: (v) =>
                                        setState(() => _rememberUsername = v),
                                  ),
                                  _CheckboxLabel(
                                    label: tr('로그인 상태 유지'),
                                    value: _keepSignedIn,
                                    onChanged: (v) =>
                                        setState(() => _keepSignedIn = v),
                                  ),
                                ],
                              ),
                              Wrap(
                                children: [
                                  TextButton(
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                      ),
                                      minimumSize: Size.zero,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    onPressed: () => showDialog(
                                      context: context,
                                      builder: (_) =>
                                          FindIdScreen(session: widget.session),
                                    ),
                                    child: Text(
                                      tr('아이디 찾기'),
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ),
                                  TextButton(
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                      ),
                                      minimumSize: Size.zero,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    onPressed: () => showDialog(
                                      context: context,
                                      builder: (_) => FindPasswordScreen(
                                        session: widget.session,
                                      ),
                                    ),
                                    child: Text(
                                      tr('비밀번호 찾기'),
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 20),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: _loginGreen,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          onPressed:
                              _loading || (_isRegister && !_canSubmitRegister)
                              ? null
                              : _submit,
                          child: _loading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Text(_isRegister ? tr('가입하기') : tr('로그인')),
                        ),
                        ..._ssoButtons(),
                        const SizedBox(height: 16),
                        // 웹 앱을 초대 링크의 웹 주소로 열었으면(아이폰 — main.dart의 takeLaunchInviteToken) 처음 온 사람이 가입으로
                        // 가면 된다는 걸 알린다 — 그 초대 코드로 가입해야 사내 와이파이 밖에서도 가입되고, 팀 초대면 팀에도 들어간다.
                        if (kIsWeb &&
                            !_isRegister &&
                            widget.session.pendingTeamInviteToken != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              tr('초대 링크로 들어왔습니다. 처음이라면 아래 회원가입으로 가입하세요.'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                        Center(
                          child: TextButton(
                            onPressed: _toggleMode,
                            child: Text(
                              _isRegister
                                  ? tr('이미 계정이 있으신가요? 로그인')
                                  : tr('계정이 없으신가요? 회원가입'),
                            ),
                          ),
                        ),
                        // 웹 앱은 페이지를 내려준 서버에만 붙는다(session.dart의 webServerUrl) — 바꿀 주소가 없다.
                        if (!kIsWeb)
                          Center(
                            child: TextButton(
                              onPressed: () => showDialog(
                                context: context,
                                builder: (_) => _ServerAddressDialog(
                                  session: widget.session,
                                ),
                              ),
                              child: Text(
                                tr('서버 주소 변경{p0}', {
                                  'p0': widget.session.serverUrl != null
                                      ? ' (${widget.session.serverUrl})'
                                      : '',
                                }),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 회원가입 폼의 "본인 확인용 질문" 블록. "직접 작성"/"목록에서 선택" 탭으로 질문을
/// 고르는 방식을 나누고(선택된 쪽이 초록색으로 강조), 그 아래 실제 질문 입력(텍스트
/// 필드 또는 드롭다운)과 답변 입력란을 보여준다.
class _SecurityQuestionSection extends StatelessWidget {
  final bool customMode;
  final ValueChanged<bool> onModeChanged;
  final String? presetChoice;
  final ValueChanged<String?> onPresetChanged;
  final TextEditingController customQuestionController;
  final TextEditingController answerController;

  const _SecurityQuestionSection({
    required this.customMode,
    required this.onModeChanged,
    required this.presetChoice,
    required this.onPresetChanged,
    required this.customQuestionController,
    required this.answerController,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('본인 확인용 질문'),
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 4),
          Text(
            tr('아이디, 비밀번호 찾기에 이용됩니다'),
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _SegmentTab(
                  label: tr('직접 작성'),
                  selected: customMode,
                  onTap: () => onModeChanged(true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SegmentTab(
                  label: tr('목록에서 선택'),
                  selected: !customMode,
                  onTap: () => onModeChanged(false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (customMode)
            TextField(
              controller: customQuestionController,
              decoration: InputDecoration(
                hintText: tr('질문을 직접 입력하세요'),
                border: OutlineInputBorder(),
              ),
            )
          else
            DropdownButtonFormField<String>(
              initialValue: presetChoice,
              isExpanded: true,
              hint: Text(tr('질문 선택'), style: _questionStyle),
              decoration: const InputDecoration(border: OutlineInputBorder()),
              style: _questionStyle,
              // itemHeight를 비워야 항목 높이가 내용에 맞게 늘어난다 — 질문이 길면 팝업에서
              // 두 줄로 접혀서 끝까지 다 보이게 하기 위함.
              itemHeight: null,
              items: kSecurityQuestionPresets
                  .map(
                    (q) => DropdownMenuItem(
                      value: q,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(q, style: _questionStyle),
                      ),
                    ),
                  )
                  .toList(),
              // 닫혀있는 상태(입력칸 자리)에서는 한 줄로만 보이게 줄임표 처리한다 —
              // 위 items는 팝업에서 두 줄로 펼쳐지는 쪽이라 서로 다른 표현이 필요하다.
              selectedItemBuilder: (context) => kSecurityQuestionPresets
                  .map(
                    (q) => Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        q,
                        style: _questionStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: onPresetChanged,
            ),
          const SizedBox(height: 12),
          TextField(
            controller: answerController,
            decoration: InputDecoration(
              labelText: tr('답변'),
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }
}

class _SegmentTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _SegmentTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? const Color(0xFF2FA36B) : Colors.grey.shade600;
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: selected ? color : Colors.grey.shade300),
        backgroundColor: selected
            ? const Color(0xFF2FA36B).withValues(alpha: 0.08)
            : null,
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
      child: Text(label, overflow: TextOverflow.ellipsis),
    );
  }
}

class _CheckboxLabel extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _CheckboxLabel({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: Checkbox(
                value: value,
                onChanged: (v) => onChanged(v ?? false),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// 로그인 화면에서 서버를 재설치 없이 바로 바꿀 수 있게 하는 다이얼로그.
/// 최초 설정용 ServerSetupScreen과 달리, 이미 로그인 화면까지 온 뒤에도 다시 열 수 있다.
class _ServerAddressDialog extends StatefulWidget {
  final Session session;
  // 초대 링크로 받은 값이 있으면 미리 채워둔다(둘 다 null이면 지금까지처럼 빈 채로 시작).
  final String? initialAddress;
  final String? initialCode;
  const _ServerAddressDialog({
    required this.session,
    this.initialAddress,
    this.initialCode,
  });

  @override
  State<_ServerAddressDialog> createState() => _ServerAddressDialogState();
}

class _ServerAddressDialogState extends State<_ServerAddressDialog> {
  late final _controller = TextEditingController(
    text:
        widget.initialAddress ??
        widget.session.primaryServerUrl ??
        widget.session.serverUrl ??
        'https://192.168.0.62:3000',
  );
  late final _code = TextEditingController(text: widget.initialCode ?? '');
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    final code = _code.text.trim();
    if (code.isNotEmpty) {
      try {
        await PinnedTls.pairAndSaveCert(_controller.text, code);
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _submitting = false;
          _error = tr('인증서를 받지 못했습니다: {e}', {'e': e});
        });
        return;
      }
      widget.session.rememberInviteCode(code);
    }
    final ok = await widget.session.setServerUrl(_controller.text);
    if (!mounted) return;
    setState(() => _submitting = false);
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() => _error = widget.session.error ?? tr('연결 실패'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('서버 주소 변경')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: tr('서버 주소'),
              hintText: 'https://192.168.0.62:3000',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            // 4자리 페어링 코드뿐 아니라 초대 링크의 긴 코드도 그대로 붙여넣을 수 있어야
            // 해서 숫자 키패드/길이 제한을 두지 않는다(서버가 길이로 둘을 구분해서 처리).
            decoration: InputDecoration(
              labelText: tr('페어링 코드 또는 초대 링크의 코드 (새 서버일 때만)'),
              hintText: tr('서버 콘솔의 4자리 코드, 또는 초대 페이지에 적힌 코드'),
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(tr('연결')),
        ),
      ],
    );
  }
}
