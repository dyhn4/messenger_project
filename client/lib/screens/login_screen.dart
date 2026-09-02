import 'package:flutter/material.dart';

import '../services/pinned_tls.dart';
import '../services/security_questions.dart';
import '../services/session.dart';
import 'find_id_screen.dart';
import 'find_password_screen.dart';

const _loginGreen = Color(0xFF6FCF97);

// 보안 질문은 문장이 길어서(최대 28자 남짓) 기본 크기로는 드롭다운에서 잘린다 — 목록/선택
// 표시 양쪽에 같은 크기를 쓴다.
const _questionStyle = TextStyle(fontSize: 13, color: Colors.black87);

const _emailDomainCustomOption = '직접 입력';
const _emailDomainPresets = [
  'naver.com',
  'gmail.com',
  'daum.net',
  'nate.com',
  'kakao.com',
  _emailDomainCustomOption,
];

class LoginScreen extends StatefulWidget {
  final Session session;
  const LoginScreen({super.key, required this.session});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _name = TextEditingController();
  final _emailLocal = TextEditingController();
  final _emailDomainCustom = TextEditingController();
  String _emailDomainChoice = _emailDomainPresets.first;
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  final _customSecurityQuestion = TextEditingController();
  final _securityAnswer = TextEditingController();
  String? _securityQuestionChoice;
  bool _securityQuestionCustomMode = false;
  bool _isRegister = false;
  bool _loading = false;
  bool _rememberUsername = false;
  bool _keepSignedIn = true;

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
  }

  void _refresh() => setState(() {});

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
    setState(() {
      _usernameChecking = true;
      _usernameCheckMessage = null;
    });
    try {
      final reason = await widget.session.api!.checkUsernameAvailable(username);
      if (!mounted) return;
      setState(() {
        _usernameAvailable = reason == null;
        _usernameCheckMessage = reason ?? '사용 가능한 아이디입니다.';
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

  String get _resolvedEmail {
    final domain = _emailDomainChoice == _emailDomainCustomOption
        ? _emailDomainCustom.text.trim()
        : _emailDomainChoice;
    return '${_emailLocal.text.trim()}@$domain';
  }

  Future<void> _submit() async {
    if (_isRegister) {
      if (_usernameAvailable != true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('아이디 중복 확인을 해주세요.')),
        );
        return;
      }
      if (_password.text != _confirmPassword.text) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('비밀번호가 서로 다릅니다.')),
        );
        return;
      }
      final question = _resolvedSecurityQuestion();
      if (question == null || _securityAnswer.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('보안 질문과 답변을 입력하세요.')),
        );
        return;
      }
    }
    setState(() => _loading = true);
    final ok = _isRegister
        ? await widget.session.register(
            _username.text.trim(),
            _password.text,
            _resolvedEmail,
            _name.text.trim(),
            securityQuestion: _resolvedSecurityQuestion()!,
            securityAnswer: _securityAnswer.text.trim(),
            keepSignedIn: true,
          )
        : await widget.session.login(
            _username.text.trim(),
            _password.text,
            keepSignedIn: _keepSignedIn,
          );
    if (!mounted) return;
    setState(() => _loading = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.session.error ?? '실패했습니다.')),
      );
      return;
    }
    if (!_isRegister) {
      await widget.session.setRememberedUsername(
        _rememberUsername ? _username.text.trim() : null,
      );
    }
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
    _username.dispose();
    _name.dispose();
    _emailLocal.dispose();
    _emailDomainCustom.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    _customSecurityQuestion.dispose();
    _securityAnswer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F4),
      body: Center(
        child: SingleChildScrollView(
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
                        _isRegister ? '회원가입' : '로그인',
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
                            hintText: '아이디 입력 (4~20자)',
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
                                    : const Text('중복 확인'),
                              ),
                            ),
                          ),
                        ),
                      ] else ...[
                        TextField(
                          controller: _username,
                          decoration: const InputDecoration(
                            labelText: '아이디',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password,
                        maxLength: _isRegister ? 20 : null,
                        decoration: InputDecoration(
                          labelText: '비밀번호',
                          hintText: _isRegister
                              ? '문자, 숫자 4~20자 (특수문자 가능)'
                              : null,
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
                            labelText: '비밀번호 확인',
                            errorText:
                                _confirmPassword.text.isNotEmpty &&
                                    _confirmPassword.text != _password.text
                                ? '비밀번호가 일치하지 않습니다'
                                : null,
                            border: const OutlineInputBorder(),
                          ),
                          obscureText: true,
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _name,
                          decoration: const InputDecoration(
                            labelText: '이름',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '이메일 주소',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _emailLocal,
                                decoration: const InputDecoration(
                                  hintText: '이메일 주소',
                                  border: OutlineInputBorder(),
                                ),
                                keyboardType: TextInputType.emailAddress,
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.only(top: 14, left: 8, right: 8),
                              child: Text('@', style: TextStyle(fontSize: 16)),
                            ),
                            Expanded(
                              child: _emailDomainChoice ==
                                      _emailDomainCustomOption
                                  ? TextField(
                                      controller: _emailDomainCustom,
                                      decoration: const InputDecoration(
                                        hintText: '도메인 입력',
                                        border: OutlineInputBorder(),
                                      ),
                                      keyboardType:
                                          TextInputType.emailAddress,
                                    )
                                  : DropdownButtonFormField<String>(
                                      initialValue: _emailDomainChoice,
                                      isExpanded: true,
                                      decoration: const InputDecoration(
                                        border: OutlineInputBorder(),
                                      ),
                                      items: _emailDomainPresets
                                          .map(
                                            (d) => DropdownMenuItem(
                                              value: d,
                                              child: Text(
                                                d,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                              ),
                                            ),
                                          )
                                          .toList(),
                                      onChanged: (v) => setState(
                                        () => _emailDomainChoice = v!,
                                      ),
                                    ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '아이디, 비밀번호 찾기에 이용됩니다',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        const SizedBox(height: 16),
                        _SecurityQuestionSection(
                          customMode: _securityQuestionCustomMode,
                          onModeChanged: (custom) =>
                              setState(() => _securityQuestionCustomMode = custom),
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
                                  label: '아이디 기억하기',
                                  value: _rememberUsername,
                                  onChanged: (v) =>
                                      setState(() => _rememberUsername = v),
                                ),
                                _CheckboxLabel(
                                  label: '로그인 상태 유지',
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
                                  onPressed: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          FindIdScreen(session: widget.session),
                                    ),
                                  ),
                                  child: const Text(
                                    '아이디 찾기',
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
                                  onPressed: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => FindPasswordScreen(
                                        session: widget.session,
                                      ),
                                    ),
                                  ),
                                  child: const Text(
                                    '비밀번호 찾기',
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
                            : Text(_isRegister ? '가입하기' : '로그인'),
                      ),
                      const SizedBox(height: 16),
                      Center(
                        child: TextButton(
                          onPressed: () =>
                              setState(() => _isRegister = !_isRegister),
                          child: Text(
                            _isRegister
                                ? '이미 계정이 있으신가요? 로그인'
                                : '계정이 없으신가요? 회원가입',
                          ),
                        ),
                      ),
                      Center(
                        child: TextButton(
                          onPressed: () => showDialog(
                            context: context,
                            builder: (_) =>
                                _ServerAddressDialog(session: widget.session),
                          ),
                          child: Text(
                            '서버 주소 변경${widget.session.serverUrl != null ? ' (${widget.session.serverUrl})' : ''}',
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
          const Text(
            '본인 확인용 질문',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 4),
          const Text(
            '아이디, 비밀번호 찾기에 이용됩니다',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _SegmentTab(
                  label: '직접 작성',
                  selected: customMode,
                  onTap: () => onModeChanged(true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SegmentTab(
                  label: '목록에서 선택',
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
              decoration: const InputDecoration(
                hintText: '질문을 직접 입력하세요',
                border: OutlineInputBorder(),
              ),
            )
          else
            DropdownButtonFormField<String>(
              initialValue: presetChoice,
              isExpanded: true,
              hint: const Text('질문 선택', style: _questionStyle),
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
            decoration: const InputDecoration(
              labelText: '답변',
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
  const _ServerAddressDialog({required this.session});

  @override
  State<_ServerAddressDialog> createState() => _ServerAddressDialogState();
}

class _ServerAddressDialogState extends State<_ServerAddressDialog> {
  late final _controller = TextEditingController(
    text: widget.session.serverUrl ?? 'https://192.168.0.62:3000',
  );
  final _code = TextEditingController();
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
          _error = '인증서를 받지 못했습니다: $e';
        });
        return;
      }
    }
    final ok = await widget.session.setServerUrl(_controller.text);
    if (!mounted) return;
    setState(() => _submitting = false);
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() => _error = widget.session.error ?? '연결 실패');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('서버 주소 변경'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '서버 주소',
              hintText: 'https://192.168.0.62:3000',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            maxLength: 4,
            decoration: const InputDecoration(
              labelText: '페어링 코드 (새 서버일 때만)',
              hintText: '서버 콘솔에 "pair" 입력 시 나오는 4자리',
              border: OutlineInputBorder(),
              counterText: '',
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
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('연결'),
        ),
      ],
    );
  }
}
