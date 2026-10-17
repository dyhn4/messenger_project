import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_client.dart' show EmailCodeSent;

/// 메일로 받은 6자리 확인 코드 입력 — "코드 보내기" 단추와 코드 칸, 보낸 주소·다시 보내기까지 남은 시간 안내를 한 덩어리로.
/// 가입·비밀번호 찾기·이메일 확인·이메일 변경이 같이 쓴다(서버 규칙: server/src/emailCodeRules.js — 10분 동안 쓸 수 있고 1분
/// 뒤에 다시 받을 수 있다).
///
/// [onSend]가 코드를 보내고(실패하면 던진다 — 그 문구를 칸 아래에 보인다) [controller]에 사람이 넣은 코드가 쌓인다. [sent]를
/// 주면 이미 한 번 보낸 상태로 시작한다(비밀번호 찾기처럼 앞 단계에서 서버가 보낸 경우).
class EmailCodeInput extends StatefulWidget {
  final Future<EmailCodeSent> Function() onSend;
  final TextEditingController controller;
  final EmailCodeSent? sent;

  /// 코드 칸에서 Enter를 눌렀을 때(다음 단계로).
  final VoidCallback? onSubmitted;

  /// 코드를 처음 보냈을 때 — 부르는 쪽이 "이 주소로 보냈다"를 기억하게(가입 화면이 이메일을 바꿨는지 보는 데).
  final ValueChanged<EmailCodeSent>? onSent;
  final bool enabled;
  final String sendLabel;

  const EmailCodeInput({
    super.key,
    required this.onSend,
    required this.controller,
    this.sent,
    this.onSubmitted,
    this.onSent,
    this.enabled = true,
    this.sendLabel = '인증 코드 보내기',
  });

  @override
  State<EmailCodeInput> createState() => _EmailCodeInputState();
}

class _EmailCodeInputState extends State<EmailCodeInput> {
  EmailCodeSent? _sent;
  DateTime? _resendAt;
  bool _sending = false;
  String? _error;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    final sent = widget.sent;
    if (sent != null) _markSent(sent);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _markSent(EmailCodeSent sent) {
    _sent = sent;
    _resendAt = DateTime.now().add(sent.resendIn);
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      if (_waitSeconds <= 0) timer.cancel();
      setState(() {});
    });
  }

  int get _waitSeconds {
    final at = _resendAt;
    if (at == null) return 0;
    return (at.difference(DateTime.now()).inMilliseconds / 1000).ceil().clamp(
      0,
      600,
    );
  }

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final sent = await widget.onSend();
      if (!mounted) return;
      setState(() => _markSent(sent));
      widget.onSent?.call(sent);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sent = _sent;
    final wait = _waitSeconds;
    final canSend = widget.enabled && !_sending && wait == 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('email-code-field'),
                controller: widget.controller,
                enabled: widget.enabled && sent != null,
                keyboardType: TextInputType.number,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                autofillHints: const [AutofillHints.oneTimeCode],
                decoration: const InputDecoration(
                  labelText: '인증 코드 6자리',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
                onSubmitted: (_) => widget.onSubmitted?.call(),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 56,
              child: OutlinedButton(
                key: const ValueKey('email-code-send'),
                onPressed: canSend ? _send : null,
                child: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        sent == null
                            ? widget.sendLabel
                            : wait > 0
                            ? '다시 보내기 ($wait초)'
                            : '다시 보내기',
                      ),
              ),
            ),
          ],
        ),
        if (sent != null) ...[
          const SizedBox(height: 4),
          Text(
            '${sent.email?.isNotEmpty == true ? '${sent.email}(으)로' : '메일로'} 인증 코드를 보냈습니다. '
            '${sent.expiresIn.inMinutes}분 안에 넣으세요. 메일이 안 보이면 스팸함도 확인하세요.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 4),
          Text(
            _error!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

/// 6자리 숫자인지 — 단계를 넘어가기 전에 서버에 묻지 않고 거른다(서버도 같은 규칙으로 본다).
bool isEmailCodeShape(String value) =>
    RegExp(r'^\d{6}$').hasMatch(value.trim());
