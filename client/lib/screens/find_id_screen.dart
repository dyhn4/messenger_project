import 'package:flutter/material.dart';

import '../services/session.dart';
import '../widgets/email_address_field.dart';
import 'find_password_screen.dart';

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

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
      _foundUsername = null;
    });
    try {
      final username = await widget.session.api!.findId(_email.trim());
      if (!mounted) return;
      setState(() => _foundUsername = username);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _goToFindPassword() {
    final session = widget.session;
    final username = _foundUsername!;
    final email = _email;
    Navigator.of(context).pop();
    showDialog(
      context: context,
      builder: (_) => FindPasswordScreen(
        session: session,
        initialUsername: username,
        initialEmail: email,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('아이디 찾기'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('가입할 때 등록한 이메일을 입력하세요.'),
            const SizedBox(height: 16),
            EmailAddressField(
              onChanged: (v) {
                _email = v;
                // 아이디를 찾은 뒤 이메일을 다시 고치면 그 결과는 더 이상 유효하지 않으니
                // "비밀번호 찾기"로 바뀌었던 버튼을 원래대로("아이디 찾기") 되돌린다.
                if (_foundUsername != null)
                  setState(() => _foundUsername = null);
              },
            ),
            if (_foundUsername != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '아이디: $_foundUsername',
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
          child: const Text('닫기'),
        ),
        FilledButton(
          onPressed: _loading
              ? null
              : (_foundUsername != null ? _goToFindPassword : _submit),
          child: _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_foundUsername != null ? '비밀번호 찾기' : '아이디 찾기'),
        ),
      ],
    );
  }
}
