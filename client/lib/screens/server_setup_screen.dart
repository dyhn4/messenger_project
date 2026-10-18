import 'dart:io';

import 'package:flutter/material.dart';

import '../services/pinned_tls.dart';
import '../services/session.dart';
import '../l10n/tr.dart';
import '../widgets/language_picker.dart';

class ServerSetupScreen extends StatefulWidget {
  final Session session;
  const ServerSetupScreen({super.key, required this.session});

  @override
  State<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends State<ServerSetupScreen> {
  final _controller = TextEditingController();
  final _code = TextEditingController();
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _prefillLocalServerAddress();
    _consumePendingPairRequest();
  }

  // 서버(index.js)가 콘솔에 찍는 "같은 와이파이의 다른 기기에서 접속할 주소"와 같은 방식으로
  // 이 PC의 LAN IPv4를 찾는다 — 보통 서버도 같은 개발 PC에서 띄우므로, 기본값을 미리 채워두면
  // 매번 서버 콘솔을 보고 옮겨 적을 필요가 없다. 못 찾으면 빈 값(hintText의 예시만 보임)으로 둔다.
  Future<void> _prefillLocalServerAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final addresses = interfaces
          .expand((i) => i.addresses)
          .map((a) => a.address)
          .where((a) => a.isNotEmpty)
          .toList();
      if (addresses.isEmpty || !mounted || _controller.text.isNotEmpty) return;
      setState(() => _controller.text = 'https://${addresses.first}:3000');
    } catch (_) {
      // 네트워크 인터페이스 조회 실패 — 사용자가 직접 입력하도록 둔다.
    }
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('인증서를 받지 못했습니다: {e}', {'e': e}))),
        );
        return;
      }
      widget.session.rememberInviteCode(code);
    }
    final ok = await widget.session.setServerUrl(_controller.text);
    if (!mounted) return;
    setState(() => _loading = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.session.error ?? tr('연결 실패'))),
      );
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
      // 화면 언어 — 서버에 연결하기 전에도 고를 수 있게(language_picker.dart).
      appBar: AppBar(
        title: Text(tr('서버 연결')),
        actions: const [LanguagePicker(compact: true)],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(tr('PC에서 서버(npm start)를 먼저 실행한 뒤, 콘솔에 출력된 주소를 그대로 입력하세요.')),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              decoration: InputDecoration(
                labelText: tr('서버 주소'),
                hintText: 'https://192.168.0.62:3000',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              // 4자리 페어링 코드뿐 아니라 초대 링크의 긴 코드도 그대로 붙여넣을 수 있어야
              // 해서 숫자 키패드/길이 제한을 두지 않는다(서버가 길이로 둘을 구분해서 처리).
              decoration: InputDecoration(
                labelText: tr('페어링 코드 또는 초대 링크의 코드 (새 서버일 때만)'),
                hintText: tr('서버 콘솔의 4자리 코드, 또는 초대 페이지에 적힌 코드'),
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
                  : Text(tr('연결')),
            ),
          ],
        ),
      ),
    );
  }
}
