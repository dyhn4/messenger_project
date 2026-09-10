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

  @override
  void initState() {
    super.initState();
    _consumePendingPairRequest();
  }

  @override
  void didUpdateWidget(covariant ServerSetupScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 이 화면이 이미 떠 있는 동안 초대 링크가 도착한 경우(예: 서버 미설정 상태로 앱을
    // 열어둔 채 다른 기기의 딥링크... 는 아니고, 같은 기기에서 링크를 다시 눌러 이 창이
    // 포그라운드로 올라온 경우) — MyApp이 session이 바뀔 때마다 이 위젯을 새로 만들어
    // 넘겨주므로 didUpdateWidget이 매번 불린다.
    _consumePendingPairRequest();
  }

  void _consumePendingPairRequest() {
    final req = widget.session.consumePendingPairRequest();
    if (req == null) return;
    setState(() {
      _controller.text = req.address;
      _code.text = req.code;
    });
  }

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
              // 4자리 페어링 코드뿐 아니라 초대 링크의 긴 코드도 그대로 붙여넣을 수 있어야
              // 해서 숫자 키패드/길이 제한을 두지 않는다(서버가 길이로 둘을 구분해서 처리).
              decoration: const InputDecoration(
                labelText: '페어링 코드 또는 초대 링크의 코드 (새 서버일 때만)',
                hintText: '서버 콘솔의 4자리 코드, 또는 초대 페이지에 적힌 코드',
                border: OutlineInputBorder(),
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
