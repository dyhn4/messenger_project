import 'package:flutter/material.dart';

import '../models/mail_settings.dart';
import 'app_toast.dart';
import '../l10n/tr.dart';

/// 한 번에 보낼 수 있는 주소 수 — 서버와 같다(server/src/mailRules.js INVITE_MAIL_MAX_RECIPIENTS).
const kInviteMailMaxRecipients = 20;

final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

/// 초대 메일 받는 주소들 — 쉼표·세미콜론·줄바꿈으로 나누고, 대소문자만 다른 같은 주소는 하나로. 틀린 주소가 있으면
/// `(emails: [], error: …)`. 서버도 같은 규칙으로 다시 본다.
({List<String> emails, String? error}) parseInviteRecipients(String input) {
  final seen = <String>{};
  final emails = <String>[];
  for (final part in input.split(RegExp(r'[,;\n]'))) {
    final email = part.trim();
    if (email.isEmpty) continue;
    if (!_emailPattern.hasMatch(email)) {
      return (
        emails: const [],
        error: tr('이메일 형식이 아닙니다: {email}', {'email': email}),
      );
    }
    if (seen.add(email.toLowerCase())) emails.add(email);
  }
  if (emails.isEmpty) return (emails: const [], error: tr('받는 사람 이메일을 넣으세요.'));
  if (emails.length > kInviteMailMaxRecipients) {
    return (
      emails: const [],
      error: tr('한 번에 {kInviteMailMaxRecipients}명까지 보낼 수 있습니다.', {
        'kInviteMailMaxRecipients': kInviteMailMaxRecipients,
      }),
    );
  }
  return (emails: emails, error: null);
}

/// 초대 링크를 메일로 보내는 창 — 설치 초대(invite_link_screen.dart)와 팀 초대(team_invite_link_screen.dart)가 같이 쓴다.
/// 본문은 서버가 링크 값으로 만든다(server/src/inviteMail.js). [send]가 서버에 보내고 결과를 돌려준다.
Future<void> showInviteMailDialog(
  BuildContext context, {
  required String linkTitle,
  required Future<InviteMailResult> Function(List<String> emails) send,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _InviteMailDialog(linkTitle: linkTitle, send: send),
  );
}

class _InviteMailDialog extends StatefulWidget {
  final String linkTitle;
  final Future<InviteMailResult> Function(List<String> emails) send;
  const _InviteMailDialog({required this.linkTitle, required this.send});

  @override
  State<_InviteMailDialog> createState() => _InviteMailDialogState();
}

class _InviteMailDialogState extends State<_InviteMailDialog> {
  final _input = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final parsed = parseInviteRecipients(_input.text);
    if (parsed.error != null) {
      setState(() => _error = parsed.error);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final result = await widget.send(parsed.emails);
      if (!mounted) return;
      if (result.failed.isEmpty) {
        showAppToast(
          context,
          tr('초대 메일 {result.sent}통을 보냈습니다.', {'result.sent': result.sent}),
        );
        Navigator.of(context).pop();
        return;
      }
      // 일부만 실패했으면 못 보낸 주소만 남겨 다시 보낼 수 있게 한다.
      setState(() {
        _input.text = result.failed.map((f) => f.email).join('\n');
        _error = tr(
          '{p0}{result.failed.length}통을 보내지 못했습니다: {result.failed.first.error}',
          {
            'p0': result.sent > 0
                ? tr('{result.sent}통은 보냈지만 ', {'result.sent': result.sent})
                : '',
            'result.failed.length': result.failed.length,
            'result.failed.first.error': result.failed.first.error,
          },
        );
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(tr('초대 메일 보내기')),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr(
                '"{widget.linkTitle}"을(를) 메일로 보냅니다. 받는 사람은 메일의 링크로 앱을 설치하고 가입할 수 있습니다.',
                {'widget.linkTitle': widget.linkTitle},
              ),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('invite-mail-recipients'),
              controller: _input,
              minLines: 3,
              maxLines: 6,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: tr('받는 사람 이메일'),
                hintText: tr('여러 명은 쉼표나 줄바꿈으로 — 한 번에 20명까지'),
                border: OutlineInputBorder(),
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
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          onPressed: _sending ? null : _send,
          child: _sending
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(tr('보내기')),
        ),
      ],
    );
  }
}
