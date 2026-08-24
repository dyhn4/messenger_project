import 'package:flutter/material.dart';

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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(widget.session.error ?? '실패했습니다.')));
      return;
    }
    if (!_isRegister) {
      await widget.session.setRememberedUsername(_rememberUsername ? _username.text.trim() : null);
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
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 20, offset: const Offset(0, 4))],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _isRegister ? '회원가입' : '로그인',
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _username,
                    decoration: const InputDecoration(labelText: '아이디', border: OutlineInputBorder()),
                  ),
                  if (_isRegister) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _name,
                      decoration: const InputDecoration(labelText: '이름', border: OutlineInputBorder()),
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
                    decoration: const InputDecoration(labelText: '비밀번호', border: OutlineInputBorder()),
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
                              onChanged: (v) => setState(() => _rememberUsername = v),
                            ),
                            _CheckboxLabel(
                              label: '로그인 상태 유지',
                              value: _keepSignedIn,
                              onChanged: (v) => setState(() => _keepSignedIn = v),
                            ),
                          ],
                        ),
                        Wrap(
                          children: [
                            TextButton(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 6),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () => Navigator.of(context)
                                  .push(MaterialPageRoute(builder: (_) => FindIdScreen(session: widget.session))),
                              child: const Text('아이디 찾기', style: TextStyle(fontSize: 12)),
                            ),
                            TextButton(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 6),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () => Navigator.of(context)
                                  .push(MaterialPageRoute(builder: (_) => FindPasswordScreen(session: widget.session))),
                              child: const Text('비밀번호 찾기', style: TextStyle(fontSize: 12)),
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
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Text(_isRegister ? '가입하기' : '로그인'),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: TextButton(
                      onPressed: () => setState(() => _isRegister = !_isRegister),
                      child: Text(_isRegister ? '이미 계정이 있으신가요? 로그인' : '계정이 없으신가요? 회원가입'),
                    ),
                  ),
                ],
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
  const _CheckboxLabel({required this.label, required this.value, required this.onChanged});

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
