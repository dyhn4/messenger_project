import 'package:flutter/material.dart';

import '../models/ddns_settings.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/app_toast.dart';
import '../widgets/web_certificate_status_card.dart';
import '../l10n/tr.dart';

/// 관리자 콘솔 "DDNS" 탭 — 외부 접속 주소(DuckDNS)를 서버가 스스로 갱신하는 설정, 그리고 같은 도메인을 쓰는 아이폰용
/// 웹 앱 주소(정식 인증서) 상태. 둘 다 "밖에서 이 서버에 닿는 주소"라 한 탭에 모았다.
///
/// 갱신은 서버가 켜져 있는 동안 5분마다 한다(server/src/ddns.js). 토큰은 서버가 다시 내려주지 않아 "설정됨"으로만
/// 보이고, 바꿀 때만 새로 넣는다 — 빈 칸으로 저장해도 이미 저장된 토큰은 그대로다.
class AdminDdnsTab extends StatefulWidget {
  final Session session;
  const AdminDdnsTab({super.key, required this.session});

  @override
  State<AdminDdnsTab> createState() => _AdminDdnsTabState();
}

class _AdminDdnsTabState extends State<AdminDdnsTab> {
  DdnsSettings? _settings;
  bool _loaded = false;
  String? _error;
  bool _enabled = false;
  bool _saving = false;
  bool _updating = false;
  final _domains = TextEditingController();
  final _token = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _domains.dispose();
    _token.dispose();
    super.dispose();
  }

  void _apply(DdnsSettings settings) {
    _settings = settings;
    _enabled = settings.enabled;
    _domains.text = settings.fullDomains.join(', ');
  }

  Future<void> _load() async {
    try {
      final settings = await widget.session.api!.fetchDdnsSettings();
      if (!mounted) return;
      setState(() {
        _loaded = true;
        if (settings != null) _apply(settings);
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loaded = true;
          _error = e.toString();
        });
      }
    }
  }

  void _toastResult(DdnsSettings settings, String saved) {
    final status = settings.status;
    final message = !settings.enabled
        ? saved
        : status.ok == true
        ? tr('{saved} DuckDNS 갱신에 성공했습니다.', {'saved': saved})
        : tr('{saved} 갱신에 실패했습니다: {p0}', {
            'saved': saved,
            'p0': status.error ?? tr('알 수 없는 이유'),
          });
    showAppToast(context, message.trim());
  }

  Future<void> _save() async {
    final token = _token.text.trim();
    final hasToken = token.isNotEmpty || (_settings?.tokenConfigured ?? false);
    if (_enabled && (_domains.text.trim().isEmpty || !hasToken)) {
      showAppToast(context, tr('켜려면 도메인과 토큰을 넣으세요.'));
      return;
    }
    setState(() => _saving = true);
    try {
      final settings = await widget.session.api!.updateDdnsSettings(
        enabled: _enabled,
        domains: _domains.text,
        token: token.isEmpty ? null : token,
      );
      if (!mounted) return;
      _token.clear();
      setState(() => _apply(settings));
      _toastResult(settings, tr('저장했습니다.'));
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clearToken() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('토큰 지우기')),
        content: SizedBox(
          width: 320,
          child: Text(tr('저장된 DuckDNS 토큰을 지울까요? 자동 갱신도 꺼집니다.')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('취소')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('지우기')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _saving = true);
    try {
      final settings = await widget.session.api!.updateDdnsSettings(token: '');
      if (!mounted) return;
      setState(() => _apply(settings));
      showAppToast(context, tr('토큰을 지웠습니다. 자동 갱신이 꺼졌습니다.'));
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _runNow() async {
    setState(() => _updating = true);
    try {
      final settings = await widget.session.api!.runDdnsUpdate();
      if (!mounted) return;
      setState(() => _settings = settings);
      _toastResult(settings, '');
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr(
              '공유기의 공인 IP가 바뀌어도 외부 접속 주소(xxx.duckdns.org)가 이 서버를 가리키도록, 서버가 켜져 있는 동안 5분마다 DuckDNS에 알립니다. duckdns.org에 로그인하면 보이는 도메인 이름과 token을 넣으세요. 이 PC의 작업 스케줄러(PowerShell)로 갱신하고 있었다면, 여기서 갱신이 잘 되는 걸 확인한 뒤 그 작업은 꺼도 됩니다.',
            ),
            style: theme.textTheme.bodySmall?.copyWith(color: hint),
          ),
          const SizedBox(height: 12),
          ..._buildEditor(context),
          const SizedBox(height: 8),
          const Divider(height: 32),
          // 아이폰용 웹 앱의 정식 인증서(Let's Encrypt) — 같은 DuckDNS 도메인을 쓰는 일이 많아 이 탭에 둔다. 이 기능이
          // 없는 예전 서버면 카드가 스스로 숨는다(fetchWebCertificateStatus가 404를 null로 준다).
          WebCertificateStatusCard(
            load: () => widget.session.api!.fetchWebCertificateStatus(),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildEditor(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    if (!_loaded) {
      return const [
        Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ];
    }
    if (_error != null) return [Text(_error!)];
    final settings = _settings;
    if (settings == null) {
      return [
        Text(
          tr('이 서버 버전은 DDNS 자동 갱신을 지원하지 않습니다. 서버를 업데이트하세요.'),
          style: TextStyle(color: theme.colorScheme.error),
        ),
      ];
    }
    return [
      _DdnsStatusCard(
        settings: settings,
        updating: _updating,
        onRunNow: settings.enabled && !_updating ? _runNow : null,
      ),
      const SizedBox(height: 12),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(tr('자동 갱신 사용')),
        value: _enabled,
        onChanged: _saving ? null : (v) => setState(() => _enabled = v),
      ),
      const SizedBox(height: 4),
      TextField(
        controller: _domains,
        decoration: InputDecoration(
          labelText: tr('DuckDNS 도메인'),
          hintText: tr('예: tangotalk.duckdns.org — 여러 개는 쉼표로'),
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _token,
        obscureText: true,
        decoration: InputDecoration(
          labelText: settings.tokenConfigured ? tr('새 토큰 (바꿀 때만)') : tr('토큰'),
          hintText: tr('duckdns.org 첫 화면의 token'),
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 4),
      Row(
        children: [
          Expanded(
            child: Text(
              settings.tokenConfigured ? tr('토큰: 설정됨') : tr('토큰: 설정 안 됨'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: settings.tokenConfigured
                    ? hint
                    : theme.colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (settings.tokenConfigured)
            TextButton(
              onPressed: _saving ? null : _clearToken,
              child: Text(tr('토큰 지우기')),
            ),
        ],
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(tr('저장')),
        ),
      ),
    ];
  }
}

/// 갱신 상태 카드 — 웹 앱 주소(정식 인증서) 카드(WebCertificateStatusCard)와 같은 모양.
class _DdnsStatusCard extends StatelessWidget {
  final DdnsSettings settings;
  final bool updating;
  final VoidCallback? onRunNow;
  const _DdnsStatusCard({
    required this.settings,
    required this.updating,
    required this.onRunNow,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final (icon, color, label) = ddnsStatusLook(settings, theme);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    text: tr('DuckDNS 자동 갱신'),
                    children: [
                      TextSpan(
                        text: '  ·  $label',
                        style: TextStyle(color: color),
                      ),
                    ],
                  ),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                tooltip: tr('지금 갱신'),
                onPressed: onRunNow,
                icon: updating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
          for (final line in ddnsStatusLines(settings))
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 10),
              child: Text(
                line,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: line.startsWith('※') ? hint : null,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 상태 카드 제목 옆의 아이콘·색·글.
(IconData, Color, String) ddnsStatusLook(DdnsSettings s, ThemeData theme) {
  if (!s.enabled) return (Icons.cloud_off_outlined, theme.hintColor, tr('꺼짐'));
  return switch (s.status.ok) {
    true => (Icons.cloud_done_outlined, Colors.green.shade700, tr('정상')),
    false => (Icons.error_outline, theme.colorScheme.error, tr('실패')),
    null => (Icons.cloud_sync_outlined, theme.hintColor, tr('확인 중')),
  };
}

/// 상태 카드 본문 줄들.
List<String> ddnsStatusLines(DdnsSettings s) {
  if (!s.enabled) {
    return [tr('꺼져 있습니다. 아래에 도메인과 토큰을 넣고 "자동 갱신 사용"을 켠 뒤 저장하세요.')];
  }
  final status = s.status;
  final domains = s.fullDomains.join(', ');
  return [
    status.ip != null ? '$domains → ${status.ip}' : domains,
    if (status.ok == false)
      tr('실패 이유: {p0}', {'p0': status.error ?? tr('알 수 없음')}),
    if (status.lastSuccessAt != null)
      tr('마지막 성공: {p0}', {'p0': formatDateTime(status.lastSuccessAt!)}),
    if (status.nextAttemptAt != null)
      tr('다음 갱신: {p0} ({status.intervalMinutes}분마다)', {
        'p0': formatDateTime(status.nextAttemptAt!),
        'status.intervalMinutes': status.intervalMinutes,
      }),
    tr('※ 서버가 켜져 있는 동안만 갱신합니다. 갱신 기록은 서버를 다시 켜면 비워집니다.'),
  ];
}
