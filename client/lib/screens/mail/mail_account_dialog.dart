import 'package:flutter/material.dart';

import '../../models/mail.dart';
import '../../services/api_client.dart' show ApiException;
import '../../services/mail_api.dart';

/// 메일 계정 연결 창 — 서비스(네이버·Gmail·다음·네이버웍스·Outlook 또는 직접 입력)를 고르고 주소·비밀번호(앱 비밀번호)를 넣으면 서버가
/// IMAP·SMTP 로그인을 해 보고 저장한다(server webmail.js). [current]가 있으면 바꾸기(비밀번호를 비우면 지금 것). 연결한 계정, 그만두면 null.
Future<MailAccount?> showMailAccountDialog(
  BuildContext context, {
  required MailApi api,
  MailAccount? current,
}) => showDialog<MailAccount>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _MailAccountDialog(api: api, current: current),
);

class _MailAccountDialog extends StatefulWidget {
  final MailApi api;
  final MailAccount? current;
  const _MailAccountDialog({required this.api, this.current});

  @override
  State<_MailAccountDialog> createState() => _MailAccountDialogState();
}

class _MailAccountDialogState extends State<_MailAccountDialog> {
  List<MailPreset> _presets = const [];
  late String _provider = widget.current?.provider ?? 'naver';
  late final _email = TextEditingController(text: widget.current?.email ?? '');
  late final _name = TextEditingController(
    text: widget.current?.displayName ?? '',
  );
  late final _username = TextEditingController(
    text: widget.current?.username == widget.current?.email
        ? ''
        : widget.current?.username ?? '',
  );
  final _password = TextEditingController();
  late final _imapHost = TextEditingController(
    text: widget.current?.imap.host ?? '',
  );
  late final _imapPort = TextEditingController(
    text: '${widget.current?.imap.port ?? 993}',
  );
  late String _imapSecurity = widget.current?.imap.security ?? 'ssl';
  late final _smtpHost = TextEditingController(
    text: widget.current?.smtp.host ?? '',
  );
  late final _smtpPort = TextEditingController(
    text: '${widget.current?.smtp.port ?? 465}',
  );
  late String _smtpSecurity = widget.current?.smtp.security ?? 'ssl';
  bool _saving = false;
  bool _showPassword = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.api
        .presets()
        .then((p) {
          if (mounted) setState(() => _presets = p);
        })
        .catchError((_) {});
  }

  @override
  void dispose() {
    for (final c in [
      _email,
      _name,
      _username,
      _password,
      _imapHost,
      _imapPort,
      _smtpHost,
      _smtpPort,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  MailPreset? get _preset {
    for (final p in _presets) {
      if (p.key == _provider) return p;
    }
    return null;
  }

  Future<void> _save() async {
    final email = _email.text.trim();
    if (!email.contains('@')) {
      setState(() => _error = '이메일 주소를 넣으세요.');
      return;
    }
    if (widget.current == null && _password.text.isEmpty) {
      setState(() => _error = '비밀번호(앱 비밀번호)를 넣으세요.');
      return;
    }
    final custom = _provider == 'custom';
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final account = await widget.api.connect(
        email: email,
        displayName: _name.text.trim(),
        provider: _provider,
        imap: custom
            ? MailEndpoint(
                host: _imapHost.text.trim(),
                port: int.tryParse(_imapPort.text.trim()) ?? 0,
                security: _imapSecurity,
              )
            : null,
        smtp: custom
            ? MailEndpoint(
                host: _smtpHost.text.trim(),
                port: int.tryParse(_smtpPort.text.trim()) ?? 0,
                security: _smtpSecurity,
              )
            : null,
        username: _username.text.trim().isEmpty ? null : _username.text.trim(),
        password: _password.text.isEmpty ? null : _password.text,
      );
      if (mounted) Navigator.of(context).pop(account);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e is ApiException ? e.message : '연결하지 못했습니다.';
        });
      }
    }
  }

  Widget _endpoint(
    String label,
    TextEditingController host,
    TextEditingController port,
    String security,
    ValueChanged<String> onSecurity,
    String key,
  ) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      children: [
        Expanded(
          flex: 3,
          child: TextField(
            key: ValueKey('$key-host'),
            controller: host,
            decoration: InputDecoration(labelText: '$label 서버', isDense: true),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 64,
          child: TextField(
            key: ValueKey('$key-port'),
            controller: port,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '포트', isDense: true),
          ),
        ),
        const SizedBox(width: 8),
        DropdownButton<String>(
          key: ValueKey('$key-security'),
          value: security,
          items: const [
            DropdownMenuItem(value: 'ssl', child: Text('SSL')),
            DropdownMenuItem(value: 'starttls', child: Text('STARTTLS')),
          ],
          onChanged: (v) => setState(() => onSecurity(v ?? security)),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preset = _preset;
    return AlertDialog(
      title: Text(widget.current == null ? '메일 계정 연결' : '메일 계정 바꾸기'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '쓰고 있는 메일 계정(회사 메일·네이버·Gmail 등)을 연결하면 여기서 받고 보냅니다. 메일은 원래 메일 서버에 그대로 있고, '
                '비밀번호는 서버에 암호화해 둡니다.',
                style: TextStyle(fontSize: 12, color: theme.hintColor),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                key: const ValueKey('mail-provider'),
                initialValue: _provider,
                decoration: const InputDecoration(labelText: '메일 서비스'),
                items: [
                  for (final p in _presets)
                    DropdownMenuItem(value: p.key, child: Text(p.label)),
                  if (!_presets.any((p) => p.key == _provider) &&
                      _provider != 'custom')
                    DropdownMenuItem(value: _provider, child: Text(_provider)),
                  const DropdownMenuItem(
                    value: 'custom',
                    child: Text('직접 입력(회사 메일 서버)'),
                  ),
                ],
                onChanged: (v) => setState(() => _provider = v ?? _provider),
              ),
              if (preset != null && preset.hint.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    preset.hint,
                    key: const ValueKey('mail-provider-hint'),
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              TextField(
                key: const ValueKey('mail-email'),
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: '이메일 주소'),
              ),
              TextField(
                key: const ValueKey('mail-password'),
                controller: _password,
                obscureText: !_showPassword,
                decoration: InputDecoration(
                  labelText: widget.current == null
                      ? '비밀번호(앱 비밀번호)'
                      : '비밀번호 (비우면 지금 것)',
                  suffixIcon: IconButton(
                    tooltip: _showPassword ? '숨기기' : '보기',
                    icon: Icon(
                      _showPassword ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () =>
                        setState(() => _showPassword = !_showPassword),
                  ),
                ),
              ),
              TextField(
                key: const ValueKey('mail-name'),
                controller: _name,
                maxLength: 50,
                decoration: const InputDecoration(
                  labelText: '보내는 이름 (받는 사람에게 보임)',
                  counterText: '',
                ),
              ),
              TextField(
                key: const ValueKey('mail-username'),
                controller: _username,
                decoration: const InputDecoration(
                  labelText: '로그인 아이디 (비우면 이메일 주소)',
                ),
              ),
              if (_provider == 'custom') ...[
                _endpoint(
                  '받는 메일(IMAP)',
                  _imapHost,
                  _imapPort,
                  _imapSecurity,
                  (v) => _imapSecurity = v,
                  'mail-imap',
                ),
                _endpoint(
                  '보내는 메일(SMTP)',
                  _smtpHost,
                  _smtpPort,
                  _smtpSecurity,
                  (v) => _smtpSecurity = v,
                  'mail-smtp',
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'IMAP은 993(SSL)·143(STARTTLS), SMTP는 465(SSL)·587(STARTTLS)이 흔합니다. 암호화 없는 연결은 쓸 수 없습니다.',
                    style: TextStyle(fontSize: 12, color: theme.hintColor),
                  ),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _error!,
                    key: const ValueKey('mail-account-error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('mail-account-save'),
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('연결'),
        ),
      ],
    );
  }
}
