import 'package:flutter/material.dart';

import '../services/pinned_tls.dart';
import '../services/session.dart';

class ServerSetupScreen extends StatefulWidget {
  final Session session;
  const ServerSetupScreen({super.key, required this.session});

  @override
  State<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends State<ServerSetupScreen> {
  final _controller = TextEditingController(text: 'https://192.168.0.62:3000');
  final _code = TextEditingController();
  bool _loading = false;

  Future<void> _submit() async {
    setState(() => _loading = true);
    final code = _code.text.trim();
    if (code.isNotEmpty) {
      try {
        await PinnedTls.pairAndSaveCert(_controller.text, code);
      } catch (e) {
        if (!mounted) return;
        setState(() => _loading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('인증서를 받지 못했습니다: $e')));
        return;
      }
    }
    final ok = await widget.session.setServerUrl(_controller.text);
    if (!mounted) return;
    setState(() => _loading = false);
    if (!ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(widget.session.error ?? '연결 실패')));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('서버 연결')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('PC에서 서버(npm start)를 먼저 실행한 뒤, 콘솔에 출력된 주소를 그대로 입력하세요.'),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
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
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _loading ? null : _submit,
              child: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('연결'),
            ),
          ],
        ),
      ),
    );
  }
}
