import 'package:flutter/material.dart';

import '../services/api_client.dart' show ApiException, EmailCodeSent;
import '../services/password_policy.dart';
import '../services/session.dart';
import '../widgets/email_address_field.dart';
import '../widgets/email_code_input.dart';
import '../l10n/tr.dart';

enum _Step { credentials, question, emailCode, newPassword }

/// showDialog로 띄우는 플로팅 창 — 로그인 화면 전체를 덮는 새 페이지 대신 로그인 화면
/// 위에 뜬다. 아이디/이메일 확인 → 본인 확인 → 새 비밀번호 입력, 이렇게 단계별로 한 화면에
/// 필요한 입력칸만 보여준다.
///
/// 본인 확인은 계정마다 다르다(server auth.js /password-reset/start): 메일이 켜진 서버에서 이메일을 확인한 계정은 그 이메일로
/// 받은 코드, 그 밖에는 보안 질문 답(질문이 없는 옛 계정은 사내 와이파이에서 답 없이).
class FindPasswordScreen extends StatefulWidget {
  final Session session;

  /// 아이디 찾기에서 바로 넘어온 경우: 아이디/이메일을 이미 알고 있으니 그 입력 단계를
  /// 건너뛰고 곧장 본인 확인(또는 질문이 없는 계정이면 새 비밀번호) 단계로 이어간다.
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
  final _emailCode = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirmPassword = TextEditingController();
  bool _loading = false;
  String? _error;

  _Step _step = _Step.credentials;
  String? _securityQuestion;

  /// 서버가 재설정 코드를 메일로 보냈을 때 그 결과(받은 주소 일부·다시 보내기 대기 시간).
  EmailCodeSent? _codeSent;

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
      final start = await widget.session.api!.startPasswordReset(
        username: _username.text.trim(),
        email: _email.trim(),
      );
      if (!mounted) return;
      setState(() {
        if (start.byEmail) {
          _codeSent = start.emailCode;
          _step = _Step.emailCode;
        } else {
          _securityQuestion = start.question;
          _step = (start.question?.isNotEmpty ?? false)
              ? _Step.question
              : _Step.newPassword;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _autoVerifying = false;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 코드 다시 받기 — 첫 단계를 다시 부르면 서버가 새 코드를 보낸다(1분 간격).
  Future<EmailCodeSent> _resendCode() async {
    final start = await widget.session.api!.startPasswordReset(
      username: _username.text.trim(),
      email: _email.trim(),
    );
    final sent = start.emailCode;
    if (sent == null) {
      throw ApiException(tr('이 계정은 이메일 코드로 재설정하지 않습니다. 처음부터 다시 하세요.'));
    }
    _emailCode.clear();
    return sent;
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

  Future<void> _verifyCode() async {
    if (!isEmailCodeShape(_emailCode.text)) {
      setState(() => _error = tr('메일로 받은 6자리 인증 코드를 넣으세요.'));
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.session.api!.verifyPasswordResetCode(
        username: _username.text.trim(),
        email: _email.trim(),
        code: _emailCode.text.trim(),
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
      setState(() => _error = tr('새 비밀번호가 서로 다릅니다.'));
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
        emailCode: _codeSent != null ? _emailCode.text.trim() : null,
        newPassword: _newPassword.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('비밀번호가 재설정되었습니다. 새 비밀번호로 로그인하세요.'))),
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
    _emailCode.dispose();
    _newPassword.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('비밀번호 찾기')),
      content: SizedBox(width: 360, child: _buildStep()),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('닫기')),
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
    _Step.emailCode => _verifyCode,
    _Step.newPassword => _resetPassword,
  };

  String get _primaryLabel => switch (_step) {
    _Step.credentials => tr('다음'),
    _Step.question || _Step.emailCode => tr('확인'),
    _Step.newPassword => tr('비밀번호 재설정'),
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
          Text(tr('아이디와 가입할 때 등록한 이메일이 모두 일치해야 재설정할 수 있습니다.')),
          const SizedBox(height: 16),
          TextField(
            controller: _username,
            decoration: InputDecoration(
              labelText: tr('아이디'),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          EmailAddressField(onChanged: (v) => _email = v),
        ];
      case _Step.question:
        return [
          Text(tr('회원정보에 등록한 질문과 답변을 입력해 주세요.')),
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
      case _Step.emailCode:
        return [
          Text(tr('가입한 이메일로 비밀번호 재설정 코드를 보냈습니다. 받은 코드를 넣어 주세요.')),
          const SizedBox(height: 16),
          EmailCodeInput(
            key: const ValueKey('find-password-email-code'),
            controller: _emailCode,
            sent: _codeSent,
            onSend: _resendCode,
            onSent: (sent) => _codeSent = sent,
            onSubmitted: _verifyCode,
          ),
        ];
      case _Step.newPassword:
        return [
          Text(tr('새 비밀번호를 입력하세요.')),
          const SizedBox(height: 16),
          TextField(
            controller: _newPassword,
            decoration: InputDecoration(
              labelText: tr('새 비밀번호'),
              hintText: kPasswordHint,
              border: OutlineInputBorder(),
            ),
            obscureText: true,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirmPassword,
            decoration: InputDecoration(
              labelText: tr('새 비밀번호 확인'),
              border: OutlineInputBorder(),
            ),
            obscureText: true,
            onSubmitted: (_) => _resetPassword(),
          ),
        ];
    }
  }
}
