import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/login_security.dart';
import '../services/api_client.dart';
import '../services/app_platform.dart';
import '../services/session.dart';
import 'app_toast.dart';
import '../l10n/tr.dart';

/// 2단계 인증(OTP) 화면들 — 로그인 둘째 단계(코드 넣기), 켜기(QR·비밀 키 → 코드 확인 → 복구 코드), 내 프로필의 관리(복구 코드
/// 새로 받기·끄기). 서버는 server/src/loginSecurity.js.

const _dialogWidth = 400.0;

/// 6자리 코드 입력칸 — 숫자만, 다 넣으면 [onComplete].
class OtpCodeField extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback? onComplete;
  final String? errorText;
  final bool autofocus;
  const OtpCodeField({
    super.key,
    required this.controller,
    this.onComplete,
    this.errorText,
    this.autofocus = true,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const ValueKey('otp-code-field'),
      controller: controller,
      autofocus: autofocus,
      keyboardType: TextInputType.number,
      textAlign: TextAlign.center,
      maxLength: 6,
      autofillHints: const [AutofillHints.oneTimeCode],
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      style: const TextStyle(fontSize: 24, letterSpacing: 8),
      decoration: InputDecoration(
        hintText: '000000',
        counterText: '',
        errorText: errorText,
        border: const OutlineInputBorder(),
      ),
      onChanged: (v) {
        if (v.length == 6) onComplete?.call();
      },
      onSubmitted: (_) => onComplete?.call(),
    );
  }
}

/// 복구 코드 목록 — 휴대폰을 잃었을 때 한 번씩 쓴다. 지금 한 번만 보여 주니 적어 두게 한다(전부 복사 단추).
class RecoveryCodesView extends StatelessWidget {
  final List<String> codes;
  const RecoveryCodesView({super.key, required this.codes});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          tr(
            '휴대폰을 잃어버리면 아래 복구 코드로 로그인할 수 있습니다(코드마다 한 번). 지금만 보이니 안전한 곳에 적어 두세요.',
          ),
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Container(
          key: const ValueKey('otp-recovery-codes'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Wrap(
            spacing: 24,
            runSpacing: 6,
            children: [
              for (final c in codes)
                SizedBox(
                  width: 120,
                  child: SelectableText(
                    c,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 15,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: codes.join('\n')));
              if (context.mounted) showAppToast(context, tr('복구 코드를 복사했습니다.'));
            },
            icon: const Icon(Icons.copy, size: 18),
            label: Text(tr('전부 복사')),
          ),
        ),
      ],
    );
  }
}

/// 로그인 둘째 단계 — 인증 앱의 6자리 코드(또는 복구 코드)를 넣으면 토큰. 취소하면 null.
Future<AuthResult?> showOtpLoginDialog(
  BuildContext context, {
  required ApiClient api,
  required String ticket,
}) => showDialog<AuthResult>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _OtpLoginDialog(api: api, ticket: ticket),
);

class _OtpLoginDialog extends StatefulWidget {
  final ApiClient api;
  final String ticket;
  const _OtpLoginDialog({required this.api, required this.ticket});

  @override
  State<_OtpLoginDialog> createState() => _OtpLoginDialogState();
}

class _OtpLoginDialogState extends State<_OtpLoginDialog> {
  final _code = TextEditingController();
  final _recovery = TextEditingController();
  bool _useRecovery = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _recovery.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final code = _code.text.trim();
    final recovery = _recovery.text.trim();
    if (_useRecovery ? recovery.isEmpty : code.length != 6) {
      setState(
        () => _error = _useRecovery ? tr('복구 코드를 넣으세요.') : tr('6자리 코드를 넣으세요.'),
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth = await widget.api.loginWithOtp(
        widget.ticket,
        code: _useRecovery ? null : code,
        recoveryCode: _useRecovery ? recovery : null,
      );
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

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).colorScheme.onSurfaceVariant;
    return AlertDialog(
      title: Text(tr('2단계 인증')),
      content: SizedBox(
        width: _dialogWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _useRecovery
                  ? tr('적어 둔 복구 코드 하나를 넣으세요(한 번 쓰면 다시 못 씁니다).')
                  : tr('인증 앱(Google Authenticator 등)에 보이는 6자리 코드를 넣으세요.'),
              style: TextStyle(color: hint),
            ),
            const SizedBox(height: 16),
            if (_useRecovery)
              TextField(
                key: const ValueKey('otp-recovery-field'),
                controller: _recovery,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'abcde-fghjk',
                  errorText: _error,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _submit(),
              )
            else
              OtpCodeField(
                controller: _code,
                errorText: _error,
                onComplete: _submit,
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('otp-use-recovery'),
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _useRecovery = !_useRecovery;
                        _error = null;
                      }),
                child: Text(
                  _useRecovery ? tr('인증 앱 코드 넣기') : tr('휴대폰이 없나요? 복구 코드 사용'),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('otp-submit'),
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(tr('확인')),
        ),
      ],
    );
  }
}

/// 2단계 인증 켜기 — 비밀 키·QR → 코드 확인 → 복구 코드. [ticket]이 있으면 로그인 중(관리자가 꼭 쓰게 정한 사람) — 끝나면 토큰도
/// 돌려준다. 취소하면 null.
Future<({List<String> recoveryCodes, AuthResult? auth})?> showOtpSetupDialog(
  BuildContext context, {
  required ApiClient api,
  String? ticket,
}) => showDialog<({List<String> recoveryCodes, AuthResult? auth})>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _OtpSetupDialog(api: api, ticket: ticket),
);

class _OtpSetupDialog extends StatefulWidget {
  final ApiClient api;
  final String? ticket;
  const _OtpSetupDialog({required this.api, this.ticket});

  @override
  State<_OtpSetupDialog> createState() => _OtpSetupDialogState();
}

class _OtpSetupDialogState extends State<_OtpSetupDialog> {
  final _code = TextEditingController();
  OtpSetupInfo? _setup;
  ({List<String> recoveryCodes, AuthResult? auth})? _done;
  bool _busy = false;
  String? _error;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final setup = await widget.api.otpSetup(ticket: widget.ticket);
      if (mounted) setState(() => _setup = setup);
    } catch (e) {
      if (mounted) setState(() => _loadError = e.toString());
    }
  }

  Future<void> _enable() async {
    if (_busy) return;
    if (_code.text.trim().length != 6) {
      setState(() => _error = tr('6자리 코드를 넣으세요.'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final done = await widget.api.otpEnable(
        _code.text.trim(),
        ticket: widget.ticket,
      );
      if (mounted) {
        setState(() {
          _busy = false;
          _done = done;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
        _code.clear();
      });
    }
  }

  Widget _setupBody(OtpSetupInfo setup) {
    final scheme = Theme.of(context).colorScheme;
    final mobileApp = !kIsWeb && !AppPlatform.isWindows;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.ticket != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              tr('관리자가 2단계 인증을 꼭 쓰게 정했습니다. 지금 켜야 로그인됩니다.'),
              style: TextStyle(color: scheme.primary),
            ),
          ),
        Text(
          tr(
            '① 휴대폰의 인증 앱(Google Authenticator·Microsoft Authenticator 등)에서 아래 QR 코드를 찍으세요.',
          ),
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Center(
          child: Container(
            key: const ValueKey('otp-qr'),
            color: Colors.white,
            padding: const EdgeInsets.all(8),
            child: QrImageView(data: setup.uri, size: 180),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          tr('QR을 찍을 수 없으면 이 키를 직접 넣으세요:'),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                setup.secret.replaceAllMapped(
                  RegExp(r'.{4}'),
                  (m) => '${m[0]} ',
                ),
                key: const ValueKey('otp-secret'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
            IconButton(
              tooltip: tr('키 복사'),
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: setup.secret));
                if (mounted) showAppToast(context, tr('키를 복사했습니다.'));
              },
            ),
          ],
        ),
        if (mobileApp)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => launchUrl(Uri.parse(setup.uri)),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: Text(tr('이 휴대폰의 인증 앱으로 열기')),
            ),
          ),
        const SizedBox(height: 12),
        Text(
          tr('② 인증 앱에 보이는 6자리 코드를 넣으세요.'),
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        OtpCodeField(
          controller: _code,
          errorText: _error,
          onComplete: _enable,
          autofocus: false,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final setup = _setup;
    final done = _done;
    return AlertDialog(
      title: Text(done == null ? tr('2단계 인증 켜기') : tr('복구 코드')),
      content: SizedBox(
        width: _dialogWidth,
        child: SingleChildScrollView(
          child: done != null
              ? RecoveryCodesView(codes: done.recoveryCodes)
              : _loadError != null
              ? Text(_loadError!)
              : setup == null
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              : _setupBody(setup),
        ),
      ),
      actions: done != null
          ? [
              FilledButton(
                key: const ValueKey('otp-setup-finish'),
                onPressed: () => Navigator.of(context).pop(done),
                child: Text(
                  widget.ticket != null ? tr('적어 두었습니다 — 로그인') : tr('적어 두었습니다'),
                ),
              ),
            ]
          : [
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: Text(tr('취소')),
              ),
              FilledButton(
                key: const ValueKey('otp-enable'),
                onPressed: _busy || setup == null ? null : _enable,
                child: Text(tr('켜기')),
              ),
            ],
    );
  }
}

/// 내 프로필 "2단계 인증" — 상태를 보여 주고 켜기·복구 코드 새로 받기·끄기.
Future<void> showOtpManageDialog(BuildContext context, Session session) =>
    showDialog<void>(
      context: context,
      builder: (_) => _OtpManageDialog(session: session),
    );

class _OtpManageDialog extends StatefulWidget {
  final Session session;
  const _OtpManageDialog({required this.session});

  @override
  State<_OtpManageDialog> createState() => _OtpManageDialogState();
}

class _OtpManageDialogState extends State<_OtpManageDialog> {
  OtpStatus? _status;
  String? _error;

  ApiClient get _api => widget.session.api!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final status = await _api.otpStatus();
      if (!mounted) return;
      widget.session.setOtpEnabled(status.enabled);
      setState(() => _status = status);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _enable() async {
    final done = await showOtpSetupDialog(context, api: _api);
    if (done == null || !mounted) return;
    showAppToast(context, tr('2단계 인증을 켰습니다.'));
    await _load();
  }

  /// 코드(또는 복구 코드)와 필요하면 비밀번호를 묻는다 — 취소하면 null.
  Future<({String? code, String? recovery, String? password})?> _askProof({
    required String title,
    required bool withPassword,
    required String action,
  }) => showDialog(
    context: context,
    builder: (_) =>
        _ProofDialog(title: title, withPassword: withPassword, action: action),
  );

  Future<void> _regenerate() async {
    final proof = await _askProof(
      title: tr('복구 코드 새로 받기'),
      withPassword: false,
      action: tr('새로 받기'),
    );
    if (proof == null || !mounted) return;
    try {
      final codes = await _api.otpRegenerateRecoveryCodes(proof.code ?? '');
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(tr('새 복구 코드')),
          content: SizedBox(
            width: _dialogWidth,
            child: RecoveryCodesView(codes: codes),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(tr('적어 두었습니다')),
            ),
          ],
        ),
      );
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, e.toString());
    }
  }

  Future<void> _disable() async {
    final proof = await _askProof(
      title: tr('2단계 인증 끄기'),
      withPassword: widget.session.authSource == 'local',
      action: tr('끄기'),
    );
    if (proof == null || !mounted) return;
    try {
      await _api.otpDisable(
        password: proof.password,
        code: proof.code,
        recoveryCode: proof.recovery,
      );
      if (!mounted) return;
      showAppToast(context, tr('2단계 인증을 껐습니다.'));
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final hint = Theme.of(context).colorScheme.onSurfaceVariant;
    return AlertDialog(
      title: Text(tr('2단계 인증')),
      content: SizedBox(
        width: _dialogWidth,
        child: _error != null
            ? Text(_error!)
            : status == null
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        status.enabled
                            ? Icons.verified_user
                            : Icons.shield_outlined,
                        color: status.enabled ? Colors.green : hint,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        status.enabled ? tr('켜져 있습니다') : tr('꺼져 있습니다'),
                        key: const ValueKey('otp-status-text'),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    status.enabled
                        ? tr(
                            '로그인할 때 비밀번호와 함께 인증 앱의 6자리 코드를 넣습니다. 남은 복구 코드: {status.recoveryCodesLeft}개',
                            {
                              'status.recoveryCodesLeft':
                                  status.recoveryCodesLeft,
                            },
                          )
                        : tr(
                            '켜면 로그인할 때 비밀번호와 함께 휴대폰 인증 앱의 6자리 코드를 넣어, 비밀번호가 새도 다른 사람이 들어오지 못합니다.',
                          ),
                    style: TextStyle(fontSize: 13, color: hint),
                  ),
                  if (status.required)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        tr('관리자가 꼭 쓰게 정해서 끌 수 없습니다.'),
                        style: TextStyle(fontSize: 12, color: hint),
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        if (status != null && status.enabled) ...[
          TextButton(
            key: const ValueKey('otp-regenerate'),
            onPressed: _regenerate,
            child: Text(tr('복구 코드 새로 받기')),
          ),
          if (!status.required)
            TextButton(
              key: const ValueKey('otp-disable'),
              onPressed: _disable,
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: Text(tr('끄기')),
            ),
        ],
        if (status != null && !status.enabled)
          FilledButton(
            key: const ValueKey('otp-start-enable'),
            onPressed: _enable,
            child: Text(tr('켜기')),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('닫기')),
        ),
      ],
    );
  }
}

/// 끄기·복구 코드 새로 받기 전에 지금 코드(또는 복구 코드)와, 필요하면 비밀번호를 묻는다.
class _ProofDialog extends StatefulWidget {
  final String title;
  final bool withPassword;
  final String action;
  const _ProofDialog({
    required this.title,
    required this.withPassword,
    required this.action,
  });

  @override
  State<_ProofDialog> createState() => _ProofDialogState();
}

class _ProofDialogState extends State<_ProofDialog> {
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _useRecovery = false;

  @override
  void dispose() {
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _code.text.trim();
    if (code.isEmpty || (widget.withPassword && _password.text.isEmpty)) return;
    Navigator.of(context).pop((
      code: _useRecovery ? null : code,
      recovery: _useRecovery ? code : null,
      password: widget.withPassword ? _password.text : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: _dialogWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.withPassword) ...[
              TextField(
                key: const ValueKey('otp-proof-password'),
                controller: _password,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: tr('비밀번호'),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (_useRecovery)
              TextField(
                key: const ValueKey('otp-proof-recovery'),
                controller: _code,
                decoration: InputDecoration(
                  labelText: tr('복구 코드'),
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _submit(),
              )
            else
              OtpCodeField(controller: _code, autofocus: !widget.withPassword),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() {
                  _useRecovery = !_useRecovery;
                  _code.clear();
                }),
                child: Text(_useRecovery ? tr('인증 앱 코드 넣기') : tr('복구 코드 사용')),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('otp-proof-submit'),
          onPressed: _submit,
          child: Text(widget.action),
        ),
      ],
    );
  }
}
