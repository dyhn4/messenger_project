import 'package:flutter/material.dart';

import '../services/password_policy.dart';
import '../services/session.dart';
import '../widgets/email_address_field.dart';

enum _Step { credentials, question, newPassword }

/// showDialog로 띄우는 플로팅 창 — 로그인 화면 전체를 덮는 새 페이지 대신 로그인 화면
/// 위에 뜬다. 아이디/이메일 확인 → (보안 질문이 있으면) 질문 답변 확인 → 새 비밀번호
/// 입력, 이렇게 단계별로 한 화면에 필요한 입력칸만 보여준다.
class FindPasswordScreen extends StatefulWidget {
  final Session session;

  /// 아이디 찾기에서 바로 넘어온 경우: 아이디/이메일을 이미 알고 있으니 그 입력 단계를
  /// 건너뛰고 곧장 보안 질문(또는 질문이 없는 계정이면 새 비밀번호) 단계로 이어간다.
  final String? initialUsername;
  final String? initialEmail;

  const FindPasswordScreen({
    super.key,
    required this.session,
    this.initialUsername,
    this.initialEmail,
  });

  @override
  State<FindPasswordScreen> createState() => _FindPasswordScreenState();
}

class _FindPasswordScreenState extends State<FindPasswordScreen> {
  final _username = TextEditingController();
  String _email = '';
  final _securityAnswer = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirmPassword = TextEditingController();
  bool _loading = false;
  String? _error;

  _Step _step = _Step.credentials;
  String? _securityQuestion;

  // 아이디 찾기에서 넘어와 아이디/이메일 입력 단계를 건너뛰고 자동으로 다음 단계를 조회하는
  // 중인지 — 이 동안은 credentials 단계의 입력칸 대신 로딩 표시만 보여준다.
  bool _autoVerifying = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialUsername != null && widget.initialEmail != null) {
      _username.text = widget.initialUsername!;
      _email = widget.initialEmail!;
      _autoVerifying = true;
      _loading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _verifyAccount());
    }
  }

  Future<void> _verifyAccount() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final question = await widget.session.api!.fetchSecurityQuestion(
        username: _username.text.trim(),
        email: _email.trim(),
      );
      if (!mounted) return;
      setState(() {
        _securityQuestion = question;
        _step = (question?.isNotEmpty ?? false)
            ? _Step.question
            : _Step.newPassword;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verifyAnswer() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.session.api!.verifySecurityAnswer(
        username: _username.text.trim(),
        email: _email.trim(),
        securityAnswer: _securityAnswer.text.trim(),
      );
      if (!mounted) return;
      setState(() => _step = _Step.newPassword);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resetPassword() async {
    final passwordError = passwordPolicyError(_newPassword.text);
    if (passwordError != null) {
      setState(() => _error = passwordError);
      return;
    }
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
        email: _email.trim(),
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
    _securityAnswer.dispose();
    _newPassword.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('비밀번호 찾기'),
      content: SizedBox(width: 360, child: _buildStep()),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
        FilledButton(
          onPressed: _loading ? null : _primaryAction,
          child: _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_primaryLabel),
        ),
      ],
    );
  }

  VoidCallback get _primaryAction => switch (_step) {
    _Step.credentials => _verifyAccount,
    _Step.question => _verifyAnswer,
    _Step.newPassword => _resetPassword,
  };

  String get _primaryLabel => switch (_step) {
    _Step.credentials => '다음',
    _Step.question => '확인',
    _Step.newPassword => '비밀번호 재설정',
  };

  Widget _buildStep() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ..._stepFields(),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }

  List<Widget> _stepFields() {
    switch (_step) {
      case _Step.credentials:
        if (_autoVerifying && _loading) {
          return const [
            Center(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: CircularProgressIndicator(),
              ),
            ),
          ];
        }
        return [
          const Text('아이디와 가입할 때 등록한 이메일이 모두 일치해야 재설정할 수 있습니다.'),
          const SizedBox(height: 16),
          TextField(
            controller: _username,
            decoration: const InputDecoration(
              labelText: '아이디',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          EmailAddressField(onChanged: (v) => _email = v),
        ];
      case _Step.question:
        return [
          const Text('회원정보에 등록한 질문과 답변을 입력해 주세요.'),
          const SizedBox(height: 16),
          TextField(
            controller: _securityAnswer,
            decoration: InputDecoration(
              labelText: _securityQuestion,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _verifyAnswer(),
          ),
        ];
      case _Step.newPassword:
        return [
          const Text('새 비밀번호를 입력하세요.'),
          const SizedBox(height: 16),
          TextField(
            controller: _newPassword,
            decoration: const InputDecoration(
              labelText: '새 비밀번호',
              hintText: kPasswordHint,
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
        ];
    }
  }
}
