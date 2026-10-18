import 'package:flutter/material.dart';

import '../services/session.dart';
import '../widgets/email_address_field.dart';
import 'find_password_screen.dart';
import '../l10n/tr.dart';

/// showDialog로 띄우는 플로팅 창 — 로그인 화면 전체를 덮는 새 페이지 대신 로그인 화면
/// 위에 뜬다.
class FindIdScreen extends StatefulWidget {
  final Session session;
  const FindIdScreen({super.key, required this.session});

  @override
  State<FindIdScreen> createState() => _FindIdScreenState();
}

class _FindIdScreenState extends State<FindIdScreen> {
  String _email = '';
  bool _loading = false;
  String? _error;
  String? _foundUsername;

  /// 메일로 보냈으면 일부만 보이는 받은 주소 — 이메일을 확인한 계정은 아이디를 화면에 보이지 않고 메일로 보낸다(메일이 켜진 서버).
  String? _sentTo;

  bool get _found => _foundUsername != null || _sentTo != null;

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
      _foundUsername = null;
      _sentTo = null;
    });
    try {
      final result = await widget.session.api!.findId(_email.trim());
      if (!mounted) return;
      setState(() {
        _foundUsername = result.username;
        _sentTo = result.sentByMail ? result.sentTo : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _goToFindPassword() {
    final session = widget.session;
    final username = _foundUsername;
    final email = _email;
    Navigator.of(context).pop();
    showDialog(
      context: context,
      builder: (_) => FindPasswordScreen(
        session: session,
        // 사내망 밖에서는 서버가 아이디 앞 두 글자만 알려준다(나머지는 *) — 그건 미리 채우지 않고 직접 넣게 한다. 메일로 보낸
        // 경우도 아이디를 모르니 직접 넣는다.
        initialUsername: username == null || username.contains('*')
            ? null
            : username,
        initialEmail: email,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('아이디 찾기')),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr('가입할 때 등록한 이메일을 입력하세요.')),
            const SizedBox(height: 16),
            EmailAddressField(
              onChanged: (v) {
                _email = v;
                // 아이디를 찾은 뒤 이메일을 다시 고치면 그 결과는 더 이상 유효하지 않으니
                // "비밀번호 찾기"로 바뀌었던 버튼을 원래대로("아이디 찾기") 되돌린다.
                if (_found) {
                  setState(() {
                    _foundUsername = null;
                    _sentTo = null;
                  });
                }
              },
            ),
            if (_sentTo != null) ...[
              const SizedBox(height: 16),
              Container(
                key: const ValueKey('find-id-mail-sent'),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  tr('{p0}(으)로 아이디를 보냈습니다. 메일함을 확인하세요(안 보이면 스팸함도).', {
                    'p0': _sentTo!.isEmpty ? tr('가입한 이메일') : _sentTo,
                  }),
                ),
              ),
            ],
            if (_foundUsername != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  tr('아이디: {_foundUsername}', {
                    '_foundUsername': _foundUsername,
                  }),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('닫기')),
        ),
        FilledButton(
          onPressed: _loading ? null : (_found ? _goToFindPassword : _submit),
          child: _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_found ? tr('비밀번호 찾기') : tr('아이디 찾기')),
        ),
      ],
    );
  }
}
