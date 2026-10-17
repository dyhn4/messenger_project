import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/login_security.dart';
import '../services/api_client.dart';
import '../services/sso_flow.dart';
import 'otp_dialogs.dart' show OtpCodeField;

/// 회사 계정(Google·Microsoft) 로그인·연결 대화상자 — 브라우저를 열어 두고 결과를 기다린다(sso_flow.dart). 같은 이메일의
/// 계정이 이미 있으면 그 이메일로 받은 확인 코드를 넣어야 연결·로그인된다(남의 계정을 가로채지 못하게).

/// 브라우저로 연다 — 웹은 새 탭.
Future<bool> openSsoUrl(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

/// 회사 계정으로 로그인 → 토큰(취소·실패면 null). [flowFactory]는 시험용.
Future<AuthResult?> showSsoLoginDialog(
  BuildContext context, {
  required ApiClient api,
  required String provider,
  SsoFlow Function()? flowFactory,
}) async {
  final result = await showDialog<Object>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SsoDialog(
      provider: provider,
      link: false,
      flow: flowFactory?.call() ?? SsoFlow(api: api, openUrl: openSsoUrl),
    ),
  );
  return result is AuthResult ? result : null;
}

/// 로그인한 내 계정에 회사 계정을 연결 → 연결했으면 true.
Future<bool> showSsoLinkDialog(
  BuildContext context, {
  required ApiClient api,
  required String provider,
  SsoFlow Function()? flowFactory,
}) async {
  final result = await showDialog<Object>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SsoDialog(
      provider: provider,
      link: true,
      flow: flowFactory?.call() ?? SsoFlow(api: api, openUrl: openSsoUrl),
    ),
  );
  return result == true;
}

class _SsoDialog extends StatefulWidget {
  final String provider;
  final bool link;
  final SsoFlow flow;
  const _SsoDialog({
    required this.provider,
    required this.link,
    required this.flow,
  });

  @override
  State<_SsoDialog> createState() => _SsoDialogState();
}

class _SsoDialogState extends State<_SsoDialog> {
  SsoPollResult? _result;
  final _code = TextEditingController();
  EmailCodeSent? _sent;
  bool _busy = false;
  String? _error;

  String get _label => ssoProviderLabel(widget.provider);

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    widget.flow.cancel();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    SsoPollResult result;
    try {
      result = await widget.flow.run(widget.provider, link: widget.link);
    } catch (e) {
      result = SsoFailed(e.toString());
    }
    if (!mounted) return;
    switch (result) {
      case SsoDone(
        :final accessToken,
        :final refreshToken,
        :final userId,
        :final username,
      ):
        Navigator.of(context).pop(
          AuthResult(
            accessToken: accessToken,
            refreshToken: refreshToken,
            userId: userId,
            username: username,
          ),
        );
      case SsoLinked():
        Navigator.of(context).pop(true);
      default:
        setState(() => _result = result);
    }
  }

  Future<void> _sendCode() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sent = await widget.flow.sendLinkCode();
      if (mounted) setState(() => _sent = sent);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    if (_code.text.trim().length != 6 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth = await widget.flow.verifyLinkCode(_code.text.trim());
      if (mounted) Navigator.of(context).pop(auth);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
        _code.clear();
      });
    }
  }

  Widget _body() {
    final hint = Theme.of(context).colorScheme.onSurfaceVariant;
    final result = _result;
    if (result == null) {
      return Column(
        key: const ValueKey('sso-waiting'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            '브라우저에서 $_label 회사 계정으로 로그인하세요. 끝나면 여기서 저절로 이어집니다.',
            textAlign: TextAlign.center,
            style: TextStyle(color: hint),
          ),
        ],
      );
    }
    if (result is SsoLinkRequired) {
      if (!result.canEmail) {
        return Text(
          '이 회사 계정의 이메일(${result.email})로 가입된 TangoTalk 계정이 있습니다. 서버의 메일 기능이 꺼져 있어 여기서 바로 연결할 수 '
          '없으니, 아이디·비밀번호로 로그인한 뒤 내 프로필의 "연결된 회사 계정"에서 연결하세요.',
          key: const ValueKey('sso-link-no-mail'),
        );
      }
      return Column(
        key: const ValueKey('sso-link-required'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '이 회사 계정의 이메일(${result.email})로 가입된 TangoTalk 계정이 있습니다. 그 이메일로 받은 확인 코드를 넣으면 연결되고, '
            '다음부터는 회사 계정으로 바로 로그인합니다.',
          ),
          const SizedBox(height: 16),
          if (_sent == null)
            FilledButton(
              key: const ValueKey('sso-link-send'),
              onPressed: _busy ? null : _sendCode,
              child: const Text('확인 코드 받기'),
            )
          else ...[
            Text(
              '${_sent!.email ?? result.email}로 보낸 6자리 코드를 넣으세요.',
              style: TextStyle(fontSize: 13, color: hint),
            ),
            const SizedBox(height: 8),
            OtpCodeField(controller: _code, onComplete: _verify),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      );
    }
    return Text(
      (result as SsoFailed).message,
      key: const ValueKey('sso-failed'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final linkStep = _result is SsoLinkRequired;
    return AlertDialog(
      title: Text(widget.link ? '$_label 계정 연결' : '$_label 계정으로 로그인'),
      content: SizedBox(width: 400, child: _body()),
      actions: [
        TextButton(
          key: const ValueKey('sso-cancel'),
          onPressed: () {
            widget.flow.cancel();
            Navigator.of(context).pop();
          },
          child: Text(_result == null || linkStep ? '취소' : '닫기'),
        ),
        if (linkStep && _sent != null)
          FilledButton(
            key: const ValueKey('sso-link-verify'),
            onPressed: _busy ? null : _verify,
            child: const Text('연결하고 로그인'),
          ),
      ],
    );
  }
}
