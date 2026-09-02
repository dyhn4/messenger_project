import 'package:flutter/material.dart';

import '../services/session.dart';

class FindPasswordScreen extends StatefulWidget {
  final Session session;
  const FindPasswordScreen({super.key, required this.session});

  @override
  State<FindPasswordScreen> createState() => _FindPasswordScreenState();
}

class _FindPasswordScreenState extends State<FindPasswordScreen> {
  final _username = TextEditingController();
  final _email = TextEditingController();
  final _securityAnswer = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirmPassword = TextEditingController();
  bool _loading = false;
  String? _error;

  // null = 아직 계정 확인 전. 확인 후에는 보안 질문 문구(없으면 '')가 들어간다.
  String? _securityQuestion;

  bool get _verified => _securityQuestion != null;

  Future<void> _verifyAccount() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final question = await widget.session.api!.fetchSecurityQuestion(
        username: _username.text.trim(),
        email: _email.text.trim(),
      );
      if (!mounted) return;
      setState(() => _securityQuestion = question ?? '');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resetPassword() async {
    if (_newPassword.text != _confirmPassword.text) {
      setState(() => _error = '새 비밀번호가 서로 다릅니다.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.session.api!.resetPassword(
        username: _username.text.trim(),
        email: _email.text.trim(),
        securityAnswer: (_securityQuestion?.isNotEmpty ?? false)
            ? _securityAnswer.text.trim()
            : null,
        newPassword: _newPassword.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('비밀번호가 재설정되었습니다. 새 비밀번호로 로그인하세요.')),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _username.dispose();
    _email.dispose();
    _securityAnswer.dispose();
    _newPassword.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('비밀번호 찾기')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _verified
                  ? (_securityQuestion!.isNotEmpty
                        ? '가입할 때 등록한 보안 질문의 답변을 입력하세요.'
                        : '새 비밀번호를 입력하세요.')
                  : '아이디와 가입할 때 등록한 이메일이 모두 일치해야 재설정할 수 있습니다.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _username,
              enabled: !_verified,
              decoration: const InputDecoration(
                labelText: '아이디',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _email,
              enabled: !_verified,
              decoration: const InputDecoration(
                labelText: '이메일',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.emailAddress,
            ),
            if (_verified && _securityQuestion!.isNotEmpty) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _securityAnswer,
                decoration: InputDecoration(
                  labelText: _securityQuestion,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
            if (_verified) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _newPassword,
                decoration: const InputDecoration(
                  labelText: '새 비밀번호',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _confirmPassword,
                decoration: const InputDecoration(
                  labelText: '새 비밀번호 확인',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
                onSubmitted: (_) => _resetPassword(),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _loading
                  ? null
                  : (_verified ? _resetPassword : _verifyAccount),
              child: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(_verified ? '비밀번호 재설정' : '다음'),
            ),
          ],
        ),
      ),
    );
  }
}
