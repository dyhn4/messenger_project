import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/mail.dart';
import '../../services/api_client.dart' show ApiException;
import '../../services/mail_api.dart';
import '../../l10n/tr.dart';

/// 메일 계정 연결 창 — 서비스(네이버·Gmail·다음·네이버웍스·Outlook 또는 직접 입력)를 고르고 주소·비밀번호(앱 비밀번호)를 넣으면 서버가
/// IMAP·SMTP 로그인을 해 보고 저장한다(server webmail.js). Gmail·Outlook은 관리자가 켰으면 **Google·Microsoft 로그인(OAuth)**으로도
/// 연결한다 — 브라우저에서 로그인하고 메일 권한을 허락하면 앱 비밀번호가 필요 없다(서버 webmailOAuth.js — 앱은 2초마다 결과를 묻는다).
/// [current]가 있으면 그 계정 바꾸기(비밀번호를 비우면 지금 것, OAuth 계정은 "다시 로그인"). 연결한 계정, 그만두면 null.
/// [legacy]는 계정이 하나뿐인 예전 서버(/mail/account).
Future<MailAccount?> showMailAccountDialog(
  BuildContext context, {
  required MailApi api,
  MailAccount? current,
  bool legacy = false,
}) => showDialog<MailAccount>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      _MailAccountDialog(api: api, current: current, legacy: legacy),
);

/// OAuth 로그인 주소를 여는 곳 — 시험에서 바꿔 끼운다.
Future<bool> Function(Uri uri) mailOAuthOpenUrl = (uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// OAuth 결과를 묻는 간격 — 시험에서 줄인다.
Duration mailOAuthPollInterval = const Duration(seconds: 2);

class _MailAccountDialog extends StatefulWidget {
  final MailApi api;
  final MailAccount? current;
  final bool legacy;
  const _MailAccountDialog({
    required this.api,
    this.current,
    this.legacy = false,
  });

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
    text: widget.current?.imap?.host ?? '',
  );
  late final _imapPort = TextEditingController(
    text: '${widget.current?.imap?.port ?? 993}',
  );
  late String _imapSecurity = widget.current?.imap?.security ?? 'ssl';
  late final _smtpHost = TextEditingController(
    text: widget.current?.smtp?.host ?? '',
  );
  late final _smtpPort = TextEditingController(
    text: '${widget.current?.smtp?.port ?? 465}',
  );
  late String _smtpSecurity = widget.current?.smtp?.security ?? 'ssl';
  bool _saving = false;
  bool _showPassword = false;
  String? _error;

  /// OAuth 로그인을 기다리는 중이면 그 제공자.
  String? _oauthWaiting;
  bool _oauthCancelled = false;

  /// 비밀번호로 바꾸는 중(OAuth 계정을 앱 비밀번호 연결로).
  bool get _passwordForCurrent =>
      widget.current != null && widget.current!.authType == 'password';

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
    _oauthCancelled = true;
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
      setState(() => _error = tr('이메일 주소를 넣으세요.'));
      return;
    }
    if (!_passwordForCurrent && _password.text.isEmpty) {
      setState(() => _error = tr('비밀번호(앱 비밀번호)를 넣으세요.'));
      return;
    }
    final custom = _provider == 'custom';
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final account = await widget.api.connect(
        accountId: widget.current?.id,
        legacy: widget.legacy,
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
          _error = e is ApiException ? trServer(e.message) : tr('연결하지 못했습니다.');
        });
      }
    }
  }

  /// Google·Microsoft 로그인으로 연결 — 브라우저를 열고 끝날 때까지 결과를 묻는다(10분).
  Future<void> _oauth(String provider) async {
    setState(() {
      _oauthWaiting = provider;
      _oauthCancelled = false;
      _error = null;
    });
    String? error;
    try {
      final started = await widget.api.oauthStart(
        provider,
        accountId: widget.current?.isOAuth == true ? widget.current!.id : null,
      );
      if (!await mailOAuthOpenUrl(Uri.parse(started.authUrl))) {
        error = tr('브라우저를 열지 못했습니다.');
      } else {
        final deadline = DateTime.now().add(const Duration(minutes: 10));
        while (!_oauthCancelled) {
          if (DateTime.now().isAfter(deadline)) {
            error = tr('로그인 시간이 지났습니다. 다시 해 보세요.');
            break;
          }
          await Future<void>.delayed(mailOAuthPollInterval);
          if (_oauthCancelled || !mounted) return;
          final ({String status, MailAccount? account, String? error}) r;
          try {
            r = await widget.api.oauthPoll(started.state);
          } catch (_) {
            continue; // 잠깐 끊겼으면 다음 차례에.
          }
          if (r.status == 'pending') continue;
          if (r.status == 'done' && r.account != null) {
            if (mounted) Navigator.of(context).pop(r.account);
            return;
          }
          error = trServer(r.error ?? tr('연결하지 못했습니다.'));
          break;
        }
      }
    } catch (e) {
      error = e is ApiException ? trServer(e.message) : tr('연결하지 못했습니다.');
    }
    if (mounted) {
      setState(() {
        _oauthWaiting = null;
        if (!_oauthCancelled) _error = error;
      });
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
            decoration: InputDecoration(
              labelText: tr('{label} 서버', {'label': label}),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 64,
          child: TextField(
            key: ValueKey('$key-port'),
            controller: port,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: tr('포트'), isDense: true),
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

  String _oauthLabel(String provider) =>
      provider == 'google' ? tr('Google 계정으로 로그인') : tr('Microsoft 계정으로 로그인');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preset = _preset;
    final oauth = preset?.oauth;
    final busy = _saving || _oauthWaiting != null;
    return AlertDialog(
      title: Text(widget.current == null ? tr('메일 계정 연결') : tr('메일 계정 바꾸기')),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tr(
                  '쓰고 있는 메일 계정(회사 메일·네이버·Gmail 등)을 연결하면 여기서 받고 보냅니다. 메일은 원래 메일 서버에 그대로 있고, 비밀번호는 서버에 암호화해 둡니다.',
                ),
                style: TextStyle(fontSize: 12, color: theme.hintColor),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                key: const ValueKey('mail-provider'),
                initialValue: _provider,
                decoration: InputDecoration(labelText: tr('메일 서비스')),
                items: [
                  for (final p in _presets)
                    DropdownMenuItem(value: p.key, child: Text(p.label)),
                  if (!_presets.any((p) => p.key == _provider) &&
                      _provider != 'custom')
                    DropdownMenuItem(value: _provider, child: Text(_provider)),
                  DropdownMenuItem(
                    value: 'custom',
                    child: Text(tr('직접 입력(회사 메일 서버)')),
                  ),
                ],
                onChanged: busy
                    ? null
                    : (v) => setState(() => _provider = v ?? _provider),
              ),
              if (oauth != null) ...[
                const SizedBox(height: 10),
                FilledButton.icon(
                  key: ValueKey('mail-oauth-$oauth'),
                  onPressed: busy ? null : () => _oauth(oauth),
                  icon: const Icon(Icons.login),
                  label: Text(_oauthLabel(oauth)),
                ),
                if (_oauthWaiting != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            tr('브라우저에서 로그인하고 메일 권한을 허락하세요. 끝나면 저절로 연결됩니다.'),
                            key: const ValueKey('mail-oauth-waiting'),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        TextButton(
                          key: const ValueKey('mail-oauth-cancel'),
                          onPressed: () =>
                              setState(() => _oauthCancelled = true),
                          child: Text(tr('취소')),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    widget.current?.isOAuth == true
                        ? tr(
                            '로그인이 끝났거나 권한을 취소했으면 다시 로그인하세요. 아래에 앱 비밀번호를 넣어 비밀번호 연결로 바꿀 수도 있습니다.',
                          )
                        : tr('로그인하면 앱 비밀번호가 필요 없습니다. 앱 비밀번호로 연결하려면 아래에 넣으세요.'),
                    style: TextStyle(fontSize: 12, color: theme.hintColor),
                  ),
                ),
              ],
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
                decoration: InputDecoration(labelText: tr('이메일 주소')),
              ),
              TextField(
                key: const ValueKey('mail-password'),
                controller: _password,
                obscureText: !_showPassword,
                decoration: InputDecoration(
                  labelText: _passwordForCurrent
                      ? tr('비밀번호 (비우면 지금 것)')
                      : tr('비밀번호(앱 비밀번호)'),
                  suffixIcon: IconButton(
                    tooltip: _showPassword ? tr('숨기기') : tr('보기'),
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
                decoration: InputDecoration(
                  labelText: tr('보내는 이름 (받는 사람에게 보임)'),
                  counterText: '',
                ),
              ),
              TextField(
                key: const ValueKey('mail-username'),
                controller: _username,
                decoration: InputDecoration(
                  labelText: tr('로그인 아이디 (비우면 이메일 주소)'),
                ),
              ),
              if (_provider == 'custom') ...[
                _endpoint(
                  tr('받는 메일(IMAP)'),
                  _imapHost,
                  _imapPort,
                  _imapSecurity,
                  (v) => _imapSecurity = v,
                  'mail-imap',
                ),
                _endpoint(
                  tr('보내는 메일(SMTP)'),
                  _smtpHost,
                  _smtpPort,
                  _smtpSecurity,
                  (v) => _smtpSecurity = v,
                  'mail-smtp',
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    tr(
                      'IMAP은 993(SSL)·143(STARTTLS), SMTP는 465(SSL)·587(STARTTLS)이 흔합니다. 암호화 없는 연결은 쓸 수 없습니다.',
                    ),
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
          onPressed: _saving
              ? null
              : () {
                  _oauthCancelled = true;
                  Navigator.of(context).pop();
                },
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('mail-account-save'),
          onPressed: busy ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(tr('연결')),
        ),
      ],
    );
  }
}
