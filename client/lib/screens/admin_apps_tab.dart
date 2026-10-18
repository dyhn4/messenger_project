import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/admin.dart';
import '../models/integration.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/app_toast.dart';
import '../widgets/avatar_utils.dart';
import '../widgets/integration_widgets.dart';
import '../l10n/tr.dart';

/// "서버 관리 > 연동 앱" — 팀마다 연동 앱(봇 전용 계정 + OAuth 앱)을 만든다(server/src/integrations.js). 앱은 봇 토큰(ttb_)으로
/// /api/v1을 봇 이름으로 부르고(방 관리자가 그 방의 웹훅·앱 → 앱에서 추가한 방만 보인다), 받을 주소(url)가 있으면 그 방의 [events]를
/// 서명한 요청으로 받으며, 단추 응답 주소(interactionUrl)로 단추·선택지 누름을 받는다. 돌아갈 주소(redirectUris)가 있으면 OAuth로
/// 사람이 승인해 그 사람 이름으로도 부른다. 서버가 사내 다른 주소로 요청을 보내는 일이라 서버 운영자만 만든다.
class AdminAppsTab extends StatefulWidget {
  final Session session;
  const AdminAppsTab({super.key, required this.session});

  @override
  State<AdminAppsTab> createState() => _AdminAppsTabState();
}

class _AdminAppsTabState extends State<AdminAppsTab> {
  List<AdminTeam>? _teams;
  String? _teamId;
  List<Integration>? _apps;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadTeams();
  }

  /// 안내에 쓸 서버 주소(끝의 / 없이) — 모르면 자리표시.
  String get _base => (widget.session.serverUrl ?? tr('https://서버주소'))
      .replaceAll(RegExp(r'/+$'), '');

  Future<void> _loadTeams() async {
    setState(() => _error = null);
    try {
      final teams = await widget.session.api!.fetchAdminTeams();
      if (!mounted) return;
      setState(() {
        _teams = teams;
        _teamId ??= teams.isEmpty ? null : teams.first.id;
      });
      await _loadApps();
    } catch (e) {
      if (mounted) {
        setState(() => _error = tr('팀 목록을 불러오지 못했습니다: {e}', {'e': e}));
      }
    }
  }

  Future<void> _loadApps() async {
    final teamId = _teamId;
    if (teamId == null) return;
    setState(() => _apps = null);
    try {
      final list = await widget.session.api!.fetchTeamAppsAdmin(teamId);
      if (mounted && teamId == _teamId) setState(() => _apps = list);
    } catch (e) {
      if (mounted) {
        setState(() => _error = tr('앱 목록을 불러오지 못했습니다: {e}', {'e': e}));
      }
    }
  }

  Future<void> _run(Future<void> Function() action, String failText) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showAppToast(context, '$failText: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final teamId = _teamId;
    if (teamId == null) return;
    final input = await showDialog<_AppInput>(
      context: context,
      builder: (_) => const _AppEditDialog(),
    );
    if (input == null || !mounted) return;
    await _run(() async {
      final secrets = await widget.session.api!.createTeamApp(
        teamId,
        name: input.name,
        emoji: input.emoji,
        description: input.description,
        url: input.url,
        events: input.events,
        interactionUrl: input.interactionUrl,
        redirectUris: input.redirectUris,
      );
      await _loadApps();
      if (mounted) {
        await _showAppSecretsDialog(
          context,
          title: tr('연동 앱을 만들었습니다'),
          secrets: secrets,
          base: _base,
          created: true,
        );
      }
    }, tr('앱을 만들지 못했습니다'));
  }

  Future<void> _edit(Integration app) async {
    final input = await showDialog<_AppInput>(
      context: context,
      builder: (_) => _AppEditDialog(initial: app),
    );
    if (input == null || !mounted) return;
    await _run(() async {
      await widget.session.api!.updateIntegration(app.id, {
        'name': input.name,
        'emoji': input.emoji,
        'description': input.description,
        'url': input.url,
        'events': input.events,
        'interactionUrl': input.interactionUrl,
        'redirectUris': input.redirectUris,
      });
      await _loadApps();
    }, tr('바꾸지 못했습니다'));
  }

  /// 새 비밀([which] 'bot' | 'client' | 'signing') — 예전 것은 바로 못 쓰게 되니 확인하고, 새 값은 이번에만 보인다.
  Future<void> _regenerate(Integration app, String which) async {
    final (title, body) = switch (which) {
      'bot' => (
        tr('봇 토큰 새로 만들기'),
        tr('"{name}"의 지금 봇 토큰은 바로 못 쓰게 됩니다. 앱에도 새 토큰을 넣어야 합니다.', {
          'name': app.name,
        }),
      ),
      'client' => (
        tr('앱 비밀 새로 만들기'),
        tr(
          '"{name}"의 지금 앱 비밀(OAuth)은 바로 못 쓰게 됩니다. 승인 코드를 토큰으로 바꿀 때 새 비밀을 써야 합니다.',
          {'name': app.name},
        ),
      ),
      _ => (
        tr('서명 비밀 새로 만들기'),
        tr('"{name}"의 지금 서명 비밀은 바로 못 쓰게 됩니다. 앱에서 요청을 확인할 때 새 비밀을 써야 합니다.', {
          'name': app.name,
        }),
      ),
    };
    final ok = await confirmIntegrationDelete(
      context,
      title: title,
      body: body,
    );
    if (!ok || !mounted) return;
    await _run(() async {
      final secrets = await widget.session.api!.regenerateAppSecret(
        app.id,
        which,
      );
      await _loadApps();
      if (mounted) {
        await _showAppSecretsDialog(
          context,
          title: title,
          secrets: secrets,
          base: _base,
          created: false,
        );
      }
    }, tr('새 비밀을 만들지 못했습니다'));
  }

  /// 보내 보기 — ping을 한 번 보내고 결과를 알린다.
  Future<void> _test(Integration app) => _run(() async {
    final d = await widget.session.api!.testIntegration(app.id);
    if (!mounted) return;
    showAppToast(
      context,
      d.delivered
          ? tr('보내 보기 성공 (HTTP {status})', {'status': d.lastStatus ?? 200})
          : tr('보내 보기 실패: {error}', {
              'error': d.lastError ?? 'HTTP ${d.lastStatus ?? '-'}',
            }),
    );
    await _loadApps();
  }, tr('보내 보지 못했습니다'));

  Future<void> _deliveries(Integration app) => _run(() async {
    final list = await widget.session.api!.fetchIntegrationDeliveries(app.id);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _DeliveriesDialog(app: app, deliveries: list),
    );
  }, tr('보내기 기록을 불러오지 못했습니다'));

  /// 켜기·끄기 — 켜면 서버가 연달아 실패한 수를 0으로 되돌린다.
  Future<void> _toggle(Integration app) => _run(() async {
    await widget.session.api!.updateIntegration(app.id, {
      'enabled': !app.enabled,
    });
    await _loadApps();
  }, tr('바꾸지 못했습니다'));

  Future<void> _delete(Integration app) async {
    final ok = await confirmIntegrationDelete(
      context,
      title: tr('연동 앱 지우기'),
      body: tr(
        '"{name}" 앱을 지울까요? 봇 토큰과 OAuth 승인은 바로 못 쓰게 되고, 앱을 추가한 방에서도 빠집니다. 이미 올라온 메시지는 그대로 남습니다.',
        {'name': app.name},
      ),
    );
    if (!ok || !mounted) return;
    await _run(() async {
      await widget.session.api!.deleteIntegration(app.id);
      await _loadApps();
    }, tr('지우지 못했습니다'));
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final teams = _teams;
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            TextButton(onPressed: _loadTeams, child: Text(tr('다시 시도'))),
          ],
        ),
      );
    }
    if (teams == null) return const Center(child: CircularProgressIndicator());
    if (teams.isEmpty) {
      return Center(
        child: Text(tr('팀이 없습니다.'), style: TextStyle(color: hint)),
      );
    }
    final apps = _apps;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          tr(
            '연동 앱은 봇 토큰으로 API를 봇 이름으로 부르고(방 관리자가 방의 웹훅·앱 → 앱에서 추가한 방만 보입니다), 받을 주소를 넣으면 그 방의 일을 서명한 요청으로 받습니다. 돌아갈 주소를 넣으면 사람이 승인해 그 사람 이름으로도 부를 수 있습니다(OAuth).',
          ),
          style: TextStyle(fontSize: 12, color: hint),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: const ValueKey('admin-apps-team'),
                initialValue: _teamId,
                decoration: InputDecoration(labelText: tr('팀'), isDense: true),
                items: [
                  for (final t in teams)
                    DropdownMenuItem(value: t.id, child: Text(t.name)),
                ],
                onChanged: (v) {
                  setState(() => _teamId = v);
                  _loadApps();
                },
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              key: const ValueKey('app-create'),
              onPressed: _busy || apps == null ? null : _create,
              icon: const Icon(Icons.add, size: 18),
              label: Text(tr('앱 만들기')),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (apps == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (apps.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                tr('이 팀에는 연동 앱이 없습니다.'),
                style: TextStyle(color: hint),
              ),
            ),
          )
        else
          for (final a in apps) _appCard(a),
      ],
    );
  }

  Widget _appCard(Integration a) {
    final lines = [
      if (a.description != null) a.description!,
      if (a.tokenPrefix != null)
        tr('봇 토큰 {prefix}…', {'prefix': a.tokenPrefix}),
      if (a.url != null)
        tr('받을 일: {events} → {url}', {
          'events': a.events.isEmpty
              ? tr('없음')
              : a.events.map(integrationEventLabel).join('·'),
          'url': a.url,
        }),
      if (a.interactionUrl != null)
        tr('단추 응답: {url}', {'url': a.interactionUrl}),
      a.redirectUris.isEmpty
          ? tr('OAuth 꺼짐(돌아갈 주소 없음)')
          : tr('OAuth 켜짐 · 돌아갈 주소 {n}개', {'n': a.redirectUris.length}),
      integrationUsageText(a.lastUsedAt, a.useCount),
    ];
    return Card(
      key: ValueKey('app-${a.id}'),
      child: ListTile(
        leading: Opacity(
          opacity: a.enabled ? 1 : 0.4,
          child: AutomationAvatar(radius: 16, emoji: a.emoji),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (!a.enabled) ...[
              const SizedBox(width: 8),
              Text(
                a.failureCount > 0
                    ? tr('꺼짐 · 연달아 {n}번 실패', {'n': a.failureCount})
                    : tr('꺼짐'),
                style: const TextStyle(fontSize: 12, color: Colors.redAccent),
              ),
            ],
          ],
        ),
        subtitle: Text(lines.join('\n'), style: const TextStyle(fontSize: 12)),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          key: ValueKey('app-menu-${a.id}'),
          enabled: !_busy,
          onSelected: (v) => switch (v) {
            'edit' => _edit(a),
            'bot' || 'client' || 'signing' => _regenerate(a, v),
            'test' => _test(a),
            'deliveries' => _deliveries(a),
            'toggle' => _toggle(a),
            _ => _delete(a),
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'edit', child: Text(tr('수정'))),
            PopupMenuItem(value: 'bot', child: Text(tr('새 봇 토큰'))),
            PopupMenuItem(value: 'client', child: Text(tr('새 앱 비밀(OAuth)'))),
            PopupMenuItem(value: 'signing', child: Text(tr('새 서명 비밀'))),
            if (a.url != null) ...[
              PopupMenuItem(value: 'test', child: Text(tr('보내 보기'))),
              PopupMenuItem(value: 'deliveries', child: Text(tr('보내기 기록'))),
            ],
            PopupMenuItem(
              value: 'toggle',
              child: Text(a.enabled ? tr('끄기') : tr('켜기')),
            ),
            PopupMenuItem(
              value: 'delete',
              child: Text(
                tr('지우기'),
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 만들거나 새로 만든 비밀을 한 번만 보여 주는 창 — 받은 것([AppSecrets]에서 null이 아닌 것)만, 각자 복사 칸과 짧은 쓰는 법을 붙인다.
/// 만들 때([created])는 OAuth 앱 id(비밀 아님)도 같이 보여 준다.
Future<void> _showAppSecretsDialog(
  BuildContext context, {
  required String title,
  required AppSecrets secrets,
  required String base,
  required bool created,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      final small = TextStyle(
        fontSize: 12,
        color: Theme.of(dialogContext).hintColor,
      );
      const bold = TextStyle(fontWeight: FontWeight.w600);
      const code = TextStyle(fontFamily: 'monospace', fontSize: 11);
      final bot = secrets.botToken;
      final client = secrets.clientSecret;
      final signing = secrets.signingSecret;
      final clientId = secrets.app.clientId;
      // 단추 달린 메시지 예 — 단추 글은 화면 말이라 번역해서 넣는다.
      final buttonExample = jsonEncode({
        'text': tr('배포할까요?'),
        'blocks': [
          {
            'type': 'actions',
            'elements': [
              {
                'type': 'button',
                'text': tr('승인'),
                'action_id': 'approve',
                'value': '1',
              },
            ],
          },
        ],
      });
      Widget section(String label, String value, String key) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),
          Text(label, style: bold),
          const SizedBox(height: 4),
          CopyableSecretField(value: value, fieldKey: ValueKey(key)),
        ],
      );
      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (created)
                  Text(
                    tr(
                      '앱에 넣을 값입니다. 봇 토큰은 API를 부를 때, 앱 비밀은 OAuth 승인 코드를 토큰으로 바꿀 때, 서명 비밀은 이 서버가 보낸 요청을 확인할 때 씁니다.',
                    ),
                  ),
                if (created && clientId != null)
                  section(tr('OAuth 앱 id(비밀 아님)'), clientId, 'app-client-id'),
                if (bot != null) ...[
                  section(tr('봇 토큰'), bot, 'app-secret-bot'),
                  const SizedBox(height: 6),
                  CopyableSecretField(
                    value:
                        "curl -k -H 'Authorization: Bearer $bot' $base/api/v1/me",
                    copiedText: tr('예시 명령을 복사했습니다.'),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tr(
                      '앱을 추가한 방에 단추 달린 메시지 올리기 — POST {base}/api/v1/rooms/<방>/messages:',
                      {'base': base},
                    ),
                    style: small,
                  ),
                  SelectableText(buttonExample, style: code),
                  const SizedBox(height: 4),
                  Text(
                    tr(
                      '단추·선택지를 누르면 단추 응답 주소로 action_id·value가 갑니다. 봇이 올린 메시지는 PATCH·DELETE /api/v1/messages/<메시지>로 고치거나 지웁니다.',
                    ),
                    style: small,
                  ),
                ],
                if (client != null) ...[
                  section(tr('앱 비밀(OAuth)'), client, 'app-secret-client'),
                  const SizedBox(height: 4),
                  Text(
                    tr(
                      '돌아갈 주소를 넣었으면 {base}/oauth/authorize?response_type=code&client_id=<앱 id>&redirect_uri=…&scope=read%20write&state=…&code_challenge=…&code_challenge_method=S256 을 엽니다. 사람이 TangoTalk(내 프로필 → 연결된 앱)에서 보이는 코드를 넣어 승인하면, 받은 code를 POST {base}/oauth/token에서 이 비밀과 함께 토큰으로 바꿉니다.',
                      {'base': base},
                    ),
                    style: small,
                  ),
                ],
                if (signing != null) ...[
                  section(tr('서명 비밀'), signing, 'app-secret-signing'),
                  const SizedBox(height: 4),
                  Text(
                    tr(
                      '이 서버가 받을 주소·단추 응답 주소로 보내는 요청은 X-TangoTalk-Signature가 "v1=" + HMAC-SHA256(서명 비밀, "<X-TangoTalk-Timestamp>.<본문>")의 16진수입니다. 같은지, 시각이 5분 안인지 확인하세요.',
                    ),
                    style: small,
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: Colors.orange.shade700,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        tr(
                          '이 창을 닫으면 다시 볼 수 없습니다. 지금 복사해 두세요. 새어 나갔다면 "새로 만들기"로 바꾸세요.',
                        ),
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.orange.shade800,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            key: const ValueKey('app-secrets-done'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(tr('복사했습니다')),
          ),
        ],
      );
    },
  );
}

/// 최근 보내기 기록(7일, 30개까지) — 일 종류·결과·시도 수·마지막 응답.
class _DeliveriesDialog extends StatelessWidget {
  final Integration app;
  final List<WebhookDelivery> deliveries;
  const _DeliveriesDialog({required this.app, required this.deliveries});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return AlertDialog(
      title: Text(tr('"{name}" 보내기 기록', {'name': app.name})),
      content: SizedBox(
        width: 480,
        child: deliveries.isEmpty
            ? Text(tr('최근 보낸 것이 없습니다.'), style: TextStyle(color: hint))
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final d in deliveries)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        d.delivered
                            ? Icons.check_circle_outline
                            : d.failed
                            ? Icons.error_outline
                            : Icons.schedule,
                        size: 18,
                        color: d.delivered
                            ? Colors.green
                            : d.failed
                            ? Colors.redAccent
                            : hint,
                      ),
                      title: Text(
                        [
                          integrationEventLabel(d.event),
                          d.delivered
                              ? tr('보냄')
                              : d.failed
                              ? tr('실패')
                              : tr('다시 보낼 차례'),
                          if (d.createdAt != null)
                            formatPostDateTime(d.createdAt!),
                        ].join(' · '),
                      ),
                      subtitle: Text(
                        [
                          tr('{n}번 시도', {'n': d.attempts}),
                          if (d.lastStatus != null) 'HTTP ${d.lastStatus}',
                          if (d.lastError != null) d.lastError!,
                        ].join(' · '),
                        style: const TextStyle(fontSize: 12),
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
      ],
    );
  }
}

typedef _AppInput = ({
  String name,
  String? emoji,
  String? description,
  String? url,
  List<String> events,
  String? interactionUrl,
  List<String> redirectUris,
});

/// 앱 만들기·수정 — 이름·아이콘·설명, 받을 주소와 받을 일, 단추 응답 주소, OAuth 돌아갈 주소(한 줄에 하나).
class _AppEditDialog extends StatefulWidget {
  final Integration? initial;
  const _AppEditDialog({this.initial});

  @override
  State<_AppEditDialog> createState() => _AppEditDialogState();
}

class _AppEditDialogState extends State<_AppEditDialog> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _emoji = TextEditingController(text: widget.initial?.emoji ?? '');
  late final _description = TextEditingController(
    text: widget.initial?.description ?? '',
  );
  late final _url = TextEditingController(text: widget.initial?.url ?? '');
  late final _interactionUrl = TextEditingController(
    text: widget.initial?.interactionUrl ?? '',
  );
  late final _redirectUris = TextEditingController(
    text: (widget.initial?.redirectUris ?? const []).join('\n'),
  );
  late final Set<String> _events = {...?widget.initial?.events};
  String? _error;

  @override
  void dispose() {
    for (final c in [
      _name,
      _emoji,
      _description,
      _url,
      _interactionUrl,
      _redirectUris,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  static bool _isHttp(String url) =>
      url.startsWith('https://') || url.startsWith('http://');

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = tr('앱 이름을 넣으세요.'));
      return;
    }
    final url = _url.text.trim();
    final interactionUrl = _interactionUrl.text.trim();
    if ((url.isNotEmpty && !_isHttp(url)) ||
        (interactionUrl.isNotEmpty && !_isHttp(interactionUrl))) {
      setState(() => _error = tr('주소는 http:// 또는 https://로 시작해야 합니다.'));
      return;
    }
    if (url.isEmpty && _events.isNotEmpty) {
      setState(() => _error = tr('받을 일을 고르면 받을 주소도 넣으세요.'));
      return;
    }
    final emoji = _emoji.text.trim();
    final description = _description.text.trim();
    // 돌아갈 주소는 한 줄에 하나 — 빈 줄은 버린다(형식은 서버가 본다: https, 127.0.0.1·localhost의 http, 앱 고유 scheme).
    final redirectUris = [
      for (final line in _redirectUris.text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    Navigator.of(context).pop((
      name: name,
      emoji: emoji.isEmpty ? null : emoji,
      description: description.isEmpty ? null : description,
      url: url.isEmpty ? null : url,
      events: [
        for (final e in integrationEvents)
          if (_events.contains(e)) e,
      ],
      interactionUrl: interactionUrl.isEmpty ? null : interactionUrl,
      redirectUris: redirectUris,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.initial != null;
    final small = TextStyle(fontSize: 12, color: Theme.of(context).hintColor);
    return AlertDialog(
      title: Text(
        editing
            ? tr('"{name}" 수정', {'name': widget.initial!.name})
            : tr('연동 앱 만들기'),
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('app-name'),
                controller: _name,
                autofocus: !editing,
                maxLength: 40,
                decoration: InputDecoration(
                  labelText: tr('앱 이름(봇 이름으로 보임)'),
                  hintText: tr('예: 배포 도우미'),
                ),
              ),
              TextField(
                key: const ValueKey('app-emoji'),
                controller: _emoji,
                decoration: InputDecoration(
                  labelText: tr('아이콘(이모지 하나)'),
                  hintText: tr('비우면 🤖'),
                ),
              ),
              TextField(
                key: const ValueKey('app-description'),
                controller: _description,
                maxLength: 100,
                decoration: InputDecoration(
                  labelText: tr('설명(방에 앱을 추가할 때 보임)'),
                ),
              ),
              TextField(
                key: const ValueKey('app-url'),
                controller: _url,
                decoration: InputDecoration(
                  labelText: tr('받을 주소(선택)'),
                  hintText: 'https://bot.company.com/tangotalk/events',
                ),
              ),
              const SizedBox(height: 8),
              Text(tr('받을 일 — 앱을 추가한 방에서 생기면 받을 주소로 보냅니다.'), style: small),
              Wrap(
                children: [
                  for (final e in integrationEvents)
                    SizedBox(
                      width: 210,
                      child: CheckboxListTile(
                        key: ValueKey('app-event-$e'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(integrationEventLabel(e)),
                        value: _events.contains(e),
                        onChanged: (v) => setState(
                          () => v == true ? _events.add(e) : _events.remove(e),
                        ),
                      ),
                    ),
                ],
              ),
              TextField(
                key: const ValueKey('app-interaction-url'),
                controller: _interactionUrl,
                decoration: InputDecoration(
                  labelText: tr('단추 응답 주소(선택)'),
                  hintText: 'https://bot.company.com/tangotalk/interactions',
                  helperText: tr('앱이 올린 메시지의 단추·선택지를 누르면 여기로 보냅니다.'),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('app-redirect-uris'),
                controller: _redirectUris,
                minLines: 2,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: tr('OAuth 돌아갈 주소(한 줄에 하나, 선택)'),
                  hintText: 'https://bot.company.com/oauth/callback',
                  helperText: tr(
                    'https, 또는 http://127.0.0.1·localhost, 또는 앱 고유 scheme. 비우면 OAuth를 쓰지 않습니다.',
                  ),
                  helperMaxLines: 2,
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('app-confirm'),
          onPressed: _submit,
          child: Text(editing ? tr('저장') : tr('만들기')),
        ),
      ],
    );
  }
}
