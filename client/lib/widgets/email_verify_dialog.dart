import 'package:flutter/material.dart';

import '../services/session.dart';
import 'app_toast.dart';
import 'email_code_input.dart';
import '../l10n/tr.dart';

/// "이메일 확인" — 메일이 켜진 서버에서 지금 이메일로 받은 코드를 넣어 본인 이메일인지 확인한다. 확인된 이메일이 있어야 비밀번호·
/// 아이디를 메일로 찾는다(그 전에는 보안 질문으로 찾는다). 로그인한 뒤 확인하지 않았으면 한 번 띄우고(home_screen.dart),
/// 개인정보 설정의 "이메일 관리"에서도 연다. 확인했으면 true.
Future<bool> showEmailVerifyDialog(
  BuildContext context,
  Session session, {
  bool prompted = false,
}) async {
  final verified = await showDialog<bool>(
    context: context,
    builder: (_) => EmailVerifyDialog(session: session, prompted: prompted),
  );
  return verified ?? false;
}

class EmailVerifyDialog extends StatefulWidget {
  final Session session;

  /// 로그인한 뒤 앱이 먼저 띄운 것인지 — 그러면 "나중에" 단추와 왜 확인해야 하는지를 보인다.
  final bool prompted;
  const EmailVerifyDialog({
    super.key,
    required this.session,
    this.prompted = false,
  });

  @override
  State<EmailVerifyDialog> createState() => _EmailVerifyDialogState();
}

class _EmailVerifyDialogState extends State<EmailVerifyDialog> {
  final _code = TextEditingController();
  bool _verifying = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (!isEmailCodeShape(_code.text)) {
      setState(() => _error = tr('메일로 받은 6자리 인증 코드를 넣으세요.'));
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      await widget.session.verifyEmail(_code.text.trim());
      if (!mounted) return;
      showAppToast(context, tr('이메일을 확인했습니다.'));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final email = widget.session.email ?? '';
    return AlertDialog(
      title: Text(tr('이메일 확인')),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.prompted
                  ? tr(
                      '이 서버는 이제 비밀번호·아이디를 이메일로 찾습니다. 등록한 이메일이 본인 것인지 확인해 주세요 — 확인하지 않으면 지금처럼 보안 질문으로 찾습니다.',
                    )
                  : tr(
                      '등록한 이메일로 인증 코드를 보내 본인 것인지 확인합니다. 확인하면 비밀번호·아이디를 이메일로 찾을 수 있습니다.',
                    ),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                email,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 12),
            EmailCodeInput(
              controller: _code,
              onSend: widget.session.sendEmailVerificationCode,
              onSubmitted: _verify,
            ),
            const SizedBox(height: 8),
            Text(
              tr('주소가 틀렸다면 내 프로필 → 개인정보 설정 → 이메일 관리에서 바꾸세요.'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(widget.prompted ? tr('나중에') : tr('닫기')),
        ),
        FilledButton(
          onPressed: _verifying ? null : _verify,
          child: _verifying
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(tr('확인')),
        ),
      ],
    );
  }
}
