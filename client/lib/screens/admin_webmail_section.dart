import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/tr.dart';
import '../models/mail_settings.dart';
import '../services/api_client.dart' show ApiException;
import '../services/session.dart';
import '../widgets/app_toast.dart';

/// 관리자 콘솔 "메일" 탭 아래의 웹메일 칸(server admin.js /admin/webmail).
///  - **자체 메일 서버** — 회사 도메인의 MX를 이 서버로 두면 그 도메인으로 오는 메일을 직접 받아 사람마다 "회사 메일함"에 넣는다
///    (주소는 `아이디@도메인`). 받는 포트(기본 25)·한 통 크기·한 사람 메일함 크기를 정하고, 도메인마다 DNS에 넣을 MX를 보여 준다.
///    바깥으로 보낼 때는 위의 메일(SMTP)로 보낸다.
///  - **OAuth 연결** — Gmail·Microsoft 365 계정을 앱 비밀번호 대신 그쪽 로그인으로 연결하게 한다(로그인 보안 탭의 클라이언트를 같이 씀).
/// 예전 서버(이 기능이 없음)면 아무것도 그리지 않는다.
class AdminWebmailSection extends StatefulWidget {
  final Session session;
  const AdminWebmailSection({super.key, required this.session});

  @override
  State<AdminWebmailSection> createState() => _AdminWebmailSectionState();
}

class _AdminWebmailSectionState extends State<AdminWebmailSection> {
  WebmailAdminSettings? _s;
  bool _loaded = false;
  bool _saving = false;
  final _domains = TextEditingController();
  final _port = TextEditingController();
  final _maxMb = TextEditingController();
  final _quotaMb = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_domains, _port, _maxMb, _quotaMb]) {
      c.dispose();
    }
    super.dispose();
  }

  void _apply(WebmailAdminSettings s) {
    _s = s;
    _domains.text = s.localDomains;
    _port.text = '${s.localPort}';
    _maxMb.text = '${s.localMaxMessageMb}';
    _quotaMb.text = '${s.localQuotaMb}';
  }

  Future<void> _load() async {
    try {
      final s = await widget.session.api!.fetchWebmailAdmin();
      if (!mounted) return;
      setState(() {
        _loaded = true;
        if (s != null) _apply(s);
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _update(
    Future<WebmailAdminSettings> Function() call, {
    String? done,
  }) async {
    setState(() => _saving = true);
    try {
      final s = await call();
      if (!mounted) return;
      setState(() => _apply(s));
      if (done != null) showAppToast(context, done);
    } catch (e) {
      if (mounted) {
        showAppToast(context, e is ApiException ? trServer(e.message) : '$e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool get _dirty {
    final s = _s;
    if (s == null) return false;
    return _domains.text.trim() != s.localDomains ||
        _port.text.trim() != '${s.localPort}' ||
        _maxMb.text.trim() != '${s.localMaxMessageMb}' ||
        _quotaMb.text.trim() != '${s.localQuotaMb}';
  }

  void _saveLocal() {
    final port = int.tryParse(_port.text.trim());
    final maxMb = int.tryParse(_maxMb.text.trim());
    final quota = int.tryParse(_quotaMb.text.trim());
    if (port == null || maxMb == null || quota == null) {
      showAppToast(context, tr('포트·크기는 숫자로 넣으세요.'));
      return;
    }
    _update(
      () => widget.session.api!.updateWebmailAdmin(
        localDomains: _domains.text.trim(),
        localPort: port,
        localMaxMessageMb: maxMb,
        localQuotaMb: quota,
      ),
      done: tr('저장했습니다.'),
    );
  }

  Widget _number(TextEditingController c, String label, String key) => SizedBox(
    width: 120,
    child: TextField(
      key: ValueKey(key),
      controller: c,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(labelText: label, isDense: true),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final s = _s;
    if (!_loaded || s == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final small = theme.textTheme.bodySmall?.copyWith(color: hint);
    final status = s.listening
        ? tr('{port}번 포트로 받는 중 · 받은 메일 {received}통, 거절 {rejected}통', {
            'port': s.listeningPort ?? s.localPort,
            'received': s.received,
            'rejected': s.rejected,
          })
        : s.listenError ?? (s.localEnabled ? tr('받는 포트를 열지 못했습니다.') : tr('꺼짐'));
    return Column(
      key: const ValueKey('admin-webmail'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 28),
        Text(tr('자체 메일 서버(회사 도메인으로 직접 받기)'), style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          tr(
            '회사 도메인의 MX 레코드를 이 서버로 두면 그 도메인으로 오는 메일을 이 서버가 직접 받아 사람마다 "회사 메일함"(아이디@도메인)에 넣습니다. 메일 화면에 회사 메일함이 저절로 생깁니다. 바깥 주소로 보낼 때는 위의 보내는 메일 계정(SMTP)으로 보내므로, 그 SMTP가 회사 주소로 보내는 것을 허락해야 합니다(회사 메일 서버·발송 서비스의 도메인 인증). 스팸 거르기는 없으니 받는 규칙으로 정리하세요.',
          ),
          style: small,
        ),
        SwitchListTile(
          key: const ValueKey('admin-webmail-local'),
          contentPadding: EdgeInsets.zero,
          title: Text(tr('자체 메일 서버 켜기')),
          subtitle: Text(
            status,
            key: const ValueKey('admin-webmail-local-status'),
            style: TextStyle(
              fontSize: 12,
              color: s.listenError != null ? theme.colorScheme.error : hint,
            ),
          ),
          value: s.localEnabled,
          onChanged: _saving || _dirty
              ? null
              : (v) => _update(
                  () => widget.session.api!.updateWebmailAdmin(localEnabled: v),
                  done: v ? tr('자체 메일 서버를 켰습니다.') : tr('자체 메일 서버를 껐습니다.'),
                ),
        ),
        TextField(
          key: const ValueKey('admin-webmail-domains'),
          controller: _domains,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: tr('받을 회사 도메인 (쉼표로 여럿 — 첫 것이 주소의 도메인)'),
            hintText: 'company.co.kr',
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            _number(_port, tr('받는 포트'), 'admin-webmail-port'),
            _number(_maxMb, tr('한 통 크기(MB)'), 'admin-webmail-max'),
            _number(_quotaMb, tr('한 사람 메일함(MB)'), 'admin-webmail-quota'),
            FilledButton(
              key: const ValueKey('admin-webmail-save'),
              onPressed: _saving || !_dirty ? null : _saveLocal,
              child: Text(tr('저장')),
            ),
          ],
        ),
        if (_dirty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(tr('바꾼 값을 먼저 저장하세요.'), style: small),
          ),
        if (!s.outboundReady && s.localEnabled)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              tr('위의 메일(SMTP) 기능이 꺼져 있어 회사 메일함에서는 회사 도메인 주소로만 보낼 수 있습니다.'),
              style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
            ),
          ),
        for (final h in s.hints)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  h.mx,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                Text(h.note, style: small),
              ],
            ),
          ),
        const Divider(height: 28),
        Text(
          tr('Google·Microsoft 로그인으로 메일 연결(OAuth)'),
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          tr(
            '켜면 사람들이 Gmail·Microsoft 365 계정을 앱 비밀번호 없이 그쪽 로그인으로 연결합니다. 로그인 보안 탭의 Google·Microsoft 클라이언트를 같이 쓰므로, 그 클라이언트에 메일 권한을 더하세요 — Google은 Gmail API 사용 설정과 범위 https://mail.google.com/, Microsoft는 API 권한(위임) Office 365 Exchange Online의 IMAP.AccessAsUser.All·SMTP.Send와 offline_access. 돌아올 주소는 회사 계정 로그인과 같습니다.',
          ),
          style: small,
        ),
        if (s.oauthRedirectUri != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: SelectableText(
              s.oauthRedirectUri!,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              tr('웹 앱 주소(WEB_DOMAIN — 정식 인증서)가 없어 OAuth를 쓸 수 없습니다.'),
              style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
            ),
          ),
        for (final (key, label, on, problem) in [
          ('google', 'Google (Gmail)', s.oauthGoogle, s.oauthGoogleProblem),
          (
            'microsoft',
            'Microsoft 365',
            s.oauthMicrosoft,
            s.oauthMicrosoftProblem,
          ),
        ])
          SwitchListTile(
            key: ValueKey('admin-webmail-oauth-$key'),
            contentPadding: EdgeInsets.zero,
            title: Text(label),
            subtitle: problem == null
                ? null
                : Text(
                    trServer(problem),
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.error,
                    ),
                  ),
            value: on,
            onChanged: _saving
                ? null
                : (v) => _update(
                    () => key == 'google'
                        ? widget.session.api!.updateWebmailAdmin(oauthGoogle: v)
                        : widget.session.api!.updateWebmailAdmin(
                            oauthMicrosoft: v,
                          ),
                  ),
          ),
      ],
    );
  }
}
