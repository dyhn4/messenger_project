import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/login_security.dart';
import '../services/api_client.dart';
import '../services/passkey_flow.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/app_toast.dart';
import '../widgets/integration_widgets.dart' show confirmIntegrationDelete;
import '../l10n/tr.dart';

/// 한 사람이 등록할 수 있는 보안 키·패스키 수(server/src/webauthnRules.js PASSKEYS_PER_USER와 같게).
const kPasskeysPerUser = 10;

/// 키 이름 최대 길이(server/src/webauthnRules.js PASSKEY_NAME_MAX와 같게).
const kPasskeyNameMax = 40;

/// "보안 키·패스키" — 내 계정에 등록한 보안 키(USB·NFC — YubiKey 등)·Windows Hello·휴대폰/iCloud/Google 패스키를 보고, 이름을
/// 바꾸고, 지우고, 새로 등록한다(server/src/webauthn.js). 등록한 키는 비밀번호 없이 로그인(관리자가 허용했을 때)과 인증 앱 코드 대신
/// 2단계 인증에 쓴다. 등록은 브라우저로 서버 웹 주소의 작은 페이지를 열어 거기서 키를 쓰고, 여기서는 결과를 기다린다(passkey_flow.dart).
/// 서버에 인증서가 있는 웹 주소가 없으면(available false) 쓸 수 없다는 설명만 보인다. 게스트도 쓴다 — 내 로그인 보안이라서.
Future<void> showPasskeysDialog(BuildContext context, Session session) =>
    showDialog<void>(
      context: context,
      builder: (_) => PasskeysDialog(session: session),
    );

/// 브라우저로 연다 — 웹은 새 탭.
Future<bool> _openPasskeyUrl(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

class PasskeysDialog extends StatefulWidget {
  final Session session;
  const PasskeysDialog({super.key, required this.session});

  /// 시험용 — 등록 흐름을 바꿔 끼운다(브라우저 열기·결과 묻는 간격). null이면 실제 브라우저로 연다.
  @visibleForTesting
  static PasskeyFlow Function(ApiClient api)? flowFactory;

  @override
  State<PasskeysDialog> createState() => _PasskeysDialogState();
}

class _PasskeysDialogState extends State<PasskeysDialog> {
  PasskeysInfo? _info;
  String? _error;
  bool _busy = false;

  ApiClient get _api => widget.session.api!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final info = await _api.fetchPasskeys();
      if (mounted) setState(() => _info = info);
    } catch (e) {
      if (mounted) {
        setState(() => _error = tr('보안 키 목록을 불러오지 못했습니다: {e}', {'e': e}));
      }
    }
  }

  /// 추가 — 이름(비워도 됨)을 묻고, 브라우저에서 키를 등록하는 동안 기다리는 창을 띄운다. 등록되면 알리고 목록을 다시 받는다.
  Future<void> _add() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _PasskeyNameDialog(
        title: tr('보안 키 추가'),
        confirmLabel: tr('다음'),
        fieldKey: const ValueKey('passkey-new-name'),
        showIntro: true,
      ),
    );
    if (name == null || !mounted) return;
    final flow =
        PasskeysDialog.flowFactory?.call(_api) ??
        PasskeyFlow(api: _api, openUrl: _openPasskeyUrl);
    final result = await showDialog<PasskeyPollResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _PasskeyRegisterDialog(flow: flow, name: name.isEmpty ? null : name),
    );
    if (!mounted) return;
    // 취소(null)·실패는 기다리는 창 안에서 끝났다 — 등록됐을 때만 알린다.
    if (result is PasskeyRegistered || result is PasskeyDone) {
      showAppToast(context, tr('보안 키를 등록했습니다'));
      await _load();
    }
  }

  Future<void> _rename(Passkey p) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _PasskeyNameDialog(
        title: tr('이름 바꾸기'),
        confirmLabel: tr('저장'),
        fieldKey: const ValueKey('passkey-name-field'),
        initialName: p.name,
      ),
    );
    if (name == null || name.isEmpty || name == p.name || !mounted) return;
    setState(() => _busy = true);
    try {
      await _api.renamePasskey(p.id, name);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('이름을 바꾸지 못했습니다: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 지우기 — 관리자가 2단계 인증을 꼭 쓰게 했는데 이게 마지막 수단이면 서버가 403과 까닭을 돌려준다(그대로 알린다).
  Future<void> _delete(Passkey p) async {
    final ok = await confirmIntegrationDelete(
      context,
      title: tr('보안 키 지우기'),
      body: tr('"{name}" 키를 지울까요? 이 키로는 더 이상 로그인할 수 없습니다.', {'name': p.name}),
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await _api.deletePasskey(p.id);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('지우지 못했습니다: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 동기화되는 패스키(iCloud·Google 등) → 구름, 이 기기에 든 것(Windows Hello·휴대폰 지문 등) → 지문, 나머지(USB·NFC 키) → 열쇠.
  IconData _iconOf(Passkey p) {
    if (p.backedUp) return Icons.cloud_sync;
    if (p.transports.contains('internal')) return Icons.fingerprint;
    return Icons.key;
  }

  String _subtitle(Passkey p) => [
    if (p.createdAt != null)
      tr('등록 {p0}', {'p0': formatPostDateTime(p.createdAt!)}),
    p.lastUsedAt == null
        ? tr('아직 쓰지 않음')
        : tr('마지막 사용 {p0}', {'p0': formatPostDateTime(p.lastUsedAt!)}),
  ].join(' · ');

  Widget _row(Passkey p) => ListTile(
    key: ValueKey('passkey-${p.id}'),
    leading: Icon(_iconOf(p)),
    title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(_subtitle(p), style: const TextStyle(fontSize: 12)),
    trailing: PopupMenuButton<String>(
      key: ValueKey('passkey-menu-${p.id}'),
      enabled: !_busy,
      tooltip: tr('더 보기'),
      onSelected: (v) => v == 'rename' ? _rename(p) : _delete(p),
      itemBuilder: (_) => [
        PopupMenuItem(
          key: const ValueKey('passkey-rename'),
          value: 'rename',
          child: Text(tr('이름 바꾸기')),
        ),
        PopupMenuItem(
          key: const ValueKey('passkey-delete'),
          value: 'delete',
          child: Text(
            tr('지우기'),
            style: const TextStyle(color: Colors.redAccent),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final hint = Theme.of(context).hintColor;
    final full = info != null && info.passkeys.length >= kPasskeysPerUser;
    return AlertDialog(
      title: Text(tr('보안 키·패스키')),
      contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      content: SizedBox(
        width: 460,
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    TextButton(onPressed: _load, child: Text(tr('다시 시도'))),
                  ],
                ),
              )
            : info == null
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      tr(
                        'USB·NFC 보안 키(YubiKey 등), Windows Hello, 휴대폰·iCloud·Google 패스키를 등록하면 비밀번호 없이 로그인하거나(관리자가 허용한 경우) 인증 앱 코드 대신 2단계 인증으로 쓸 수 있습니다. 키는 이 서버 주소에서만 동작해 가짜 사이트에서는 쓸 수 없습니다.',
                      ),
                      style: TextStyle(fontSize: 12, color: hint),
                    ),
                  ),
                  // 서버에 인증서가 있는 웹 주소가 없으면 키를 묶을 도메인이 없다 — 이미 등록한 키도 쓸 수 없으니 설명만.
                  if (!info.available)
                    Padding(
                      key: const ValueKey('passkey-unavailable'),
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline, size: 18, color: hint),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              tr(
                                '이 서버에는 인증서가 있는 웹 앱 주소가 설정되어 있지 않아 보안 키·패스키를 쓸 수 없습니다. 관리자에게 문의하세요.',
                              ),
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (info.available && info.passkeys.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: Text(
                          tr('아직 등록한 보안 키가 없습니다.'),
                          style: TextStyle(color: hint),
                        ),
                      ),
                    ),
                  for (final p in info.passkeys) _row(p),
                  if (full)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Text(
                        tr('보안 키·패스키는 {n}개까지 등록할 수 있습니다.', {
                          'n': kPasskeysPerUser,
                        }),
                        style: TextStyle(fontSize: 12, color: hint),
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('닫기')),
        ),
        if (info != null && info.available)
          FilledButton.icon(
            key: const ValueKey('passkey-add'),
            onPressed: _busy || full ? null : _add,
            icon: const Icon(Icons.add, size: 18),
            label: Text(tr('보안 키 추가')),
          ),
      ],
    );
  }
}

/// 키 이름 묻기 — 추가(비워도 됨, 브라우저가 열린다는 안내)와 이름 바꾸기에 같이 쓴다. 확인하면 다듬은 이름(빈 문자열 가능), 취소면 null.
class _PasskeyNameDialog extends StatefulWidget {
  final String title;
  final String confirmLabel;
  final Key fieldKey;
  final String initialName;
  final bool showIntro;
  const _PasskeyNameDialog({
    required this.title,
    required this.confirmLabel,
    required this.fieldKey,
    this.initialName = '',
    this.showIntro = false,
  });

  @override
  State<_PasskeyNameDialog> createState() => _PasskeyNameDialogState();
}

class _PasskeyNameDialogState extends State<_PasskeyNameDialog> {
  late final _name = TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    // 이름 바꾸기는 비울 수 없다(추가는 비우면 서버가 기본 이름을 붙인다).
    if (!widget.showIntro && name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.showIntro) ...[
              Text(
                tr(
                  '알아보기 쉬운 이름을 붙이세요(비워도 됩니다). 다음을 누르면 브라우저가 열리고, 거기서 보안 키를 대거나 Windows Hello·휴대폰으로 확인합니다.',
                ),
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).hintColor,
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              key: widget.fieldKey,
              controller: _name,
              autofocus: true,
              maxLength: kPasskeyNameMax,
              decoration: InputDecoration(
                labelText: tr('이름'),
                hintText: tr('예: YubiKey 5'),
              ),
              onSubmitted: (_) => _submit(),
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
          key: const ValueKey('passkey-name-confirm'),
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// 브라우저에서 키를 등록하는 동안 기다리는 창(sso_dialogs.dart의 회사 계정 창과 같은 모양) — 등록되면 결과를 돌려주며 닫히고,
/// 실패하면 까닭을 보여 준다. 취소하거나 창이 닫히면 기다리기를 멈춘다.
class _PasskeyRegisterDialog extends StatefulWidget {
  final PasskeyFlow flow;
  final String? name;
  const _PasskeyRegisterDialog({required this.flow, this.name});

  @override
  State<_PasskeyRegisterDialog> createState() => _PasskeyRegisterDialogState();
}

class _PasskeyRegisterDialogState extends State<_PasskeyRegisterDialog> {
  String? _failed;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    widget.flow.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    PasskeyPollResult result;
    try {
      result = await widget.flow.register(name: widget.name);
    } catch (e) {
      // 시작부터 거절(10개를 넘음 등)되면 서버 문구를 그대로.
      result = PasskeyFailed(e.toString());
    }
    if (!mounted || widget.flow.cancelled) return;
    switch (result) {
      case PasskeyRegistered() || PasskeyDone():
        Navigator.of(context).pop(result);
      case PasskeyFailed(:final message):
        setState(() => _failed = message);
      case PasskeyPending():
        setState(() => _failed = tr('보안 키를 확인하지 못했습니다.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).colorScheme.onSurfaceVariant;
    return AlertDialog(
      title: Text(tr('보안 키 추가')),
      content: SizedBox(
        width: 400,
        child: _failed != null
            ? Text(_failed!, key: const ValueKey('passkey-failed'))
            : Column(
                key: const ValueKey('passkey-waiting'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    tr('브라우저에서 보안 키를 등록하세요. 끝나면 여기서 저절로 이어집니다.'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: hint),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('passkey-cancel'),
          onPressed: () {
            widget.flow.cancel();
            Navigator.of(context).pop();
          },
          child: Text(_failed == null ? tr('취소') : tr('닫기')),
        ),
      ],
    );
  }
}
