import 'package:flutter/material.dart';

import '../services/pinned_tls.dart';
import '../services/session.dart';
import 'find_id_screen.dart';
import 'find_password_screen.dart';

const _loginGreen = Color(0xFF6FCF97);

class LoginScreen extends StatefulWidget {
  final Session session;
  const LoginScreen({super.key, required this.session});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _isRegister = false;
  bool _loading = false;
  bool _rememberUsername = false;
  bool _keepSignedIn = true;

  @override
  void initState() {
    super.initState();
    final remembered = widget.session.rememberedUsername;
    if (remembered != null) {
      _username.text = remembered;
      _rememberUsername = true;
    }
  }

  Future<void> _submit() async {
    setState(() => _loading = true);
    final ok = _isRegister
        ? await widget.session.register(
            _username.text.trim(),
            _password.text,
            _email.text.trim(),
            _name.text.trim(),
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

  @override
  void dispose() {
    _username.dispose();
    _name.dispose();
    _email.dispose();
    _password.dispose();
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
                      TextField(
                        controller: _username,
                        decoration: const InputDecoration(
                          labelText: '아이디',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      if (_isRegister) ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: _name,
                          decoration: const InputDecoration(
                            labelText: '이름',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _email,
                          decoration: const InputDecoration(
                            labelText: '이메일',
                            hintText: '아이디/비밀번호 찾기에 사용됩니다',
                            border: OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.emailAddress,
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password,
                        decoration: const InputDecoration(
                          labelText: '비밀번호',
                          border: OutlineInputBorder(),
                        ),
                        obscureText: true,
                        onSubmitted: (_) => _submit(),
                      ),
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
                        onPressed: _loading ? null : _submit,
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
