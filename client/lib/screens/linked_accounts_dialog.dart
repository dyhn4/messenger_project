import 'package:flutter/material.dart';

import '../models/login_security.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/app_toast.dart';
import '../widgets/sso_dialogs.dart';

/// 내 프로필 "연결된 회사 계정" — 연결한 Google·Microsoft 회사 계정(과 회사 디렉터리)을 보여 주고, 이 서버에서 쓸 수 있는 회사
/// 계정을 연결하거나 끊는다(server/src/sso.js). 연결하면 로그인 화면의 회사 계정 단추로 들어올 수 있다.
Future<void> showLinkedAccountsDialog(BuildContext context, Session session) =>
    showDialog<void>(
      context: context,
      builder: (_) => LinkedAccountsDialog(session: session),
    );

class LinkedAccountsDialog extends StatefulWidget {
  final Session session;
  const LinkedAccountsDialog({super.key, required this.session});

  @override
  State<LinkedAccountsDialog> createState() => _LinkedAccountsDialogState();
}

class _LinkedAccountsDialogState extends State<LinkedAccountsDialog> {
  IdentitiesInfo? _info;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await widget.session.api!.fetchIdentities();
      if (mounted) setState(() => _info = info);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _link(String provider) async {
    final ok = await showSsoLinkDialog(
      context,
      api: widget.session.api!,
      provider: provider,
    );
    if (!ok || !mounted) return;
    showAppToast(context, '${ssoProviderLabel(provider)} 계정을 연결했습니다.');
    await _load();
  }

  Future<void> _unlink(String provider) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('연결 끊기'),
        content: Text(
          '${ssoProviderLabel(provider)} 계정 연결을 끊을까요? 그다음부터는 그 계정으로 로그인할 수 없습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('linked-unlink-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('끊기'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.session.api!.unlinkIdentity(provider);
      if (mounted) showAppToast(context, '연결을 끊었습니다.');
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  IconData _icon(String provider) => switch (provider) {
    'ldap' => Icons.domain,
    _ => Icons.business_center_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final hint = Theme.of(context).colorScheme.onSurfaceVariant;
    final linked = {
      for (final i in info?.identities ?? const <LinkedIdentity>[]) i.provider,
    };
    final canLink = [
      for (final p in info?.available ?? const <String>[])
        if (!linked.contains(p)) p,
    ];
    return AlertDialog(
      title: const Text('연결된 회사 계정'),
      content: SizedBox(
        width: 420,
        child: _error != null
            ? Text(_error!)
            : info == null
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  Text(
                    '회사 계정을 연결하면 로그인 화면의 회사 계정 단추로 들어올 수 있습니다(회사 계정의 2단계 인증이 그대로 적용됩니다).',
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                  const SizedBox(height: 8),
                  if (info.identities.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '연결된 회사 계정이 없습니다.',
                        style: TextStyle(color: hint),
                      ),
                    ),
                  for (final i in info.identities)
                    ListTile(
                      key: ValueKey('linked-${i.provider}'),
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(_icon(i.provider)),
                      title: Text(ssoProviderLabel(i.provider)),
                      subtitle: Text(
                        [
                          ?i.email,
                          if (i.lastLoginAt != null)
                            '마지막 로그인 ${formatPostDateTime(i.lastLoginAt!)}',
                        ].join(' · '),
                      ),
                      trailing: i.provider == 'ldap'
                          ? null
                          : TextButton(
                              key: ValueKey('linked-unlink-${i.provider}'),
                              onPressed: _busy
                                  ? null
                                  : () => _unlink(i.provider),
                              child: const Text('끊기'),
                            ),
                    ),
                  for (final p in canLink)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: OutlinedButton.icon(
                        key: ValueKey('linked-link-$p'),
                        onPressed: _busy ? null : () => _link(p),
                        icon: const Icon(Icons.link),
                        label: Text('${ssoProviderLabel(p)} 계정 연결'),
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}
