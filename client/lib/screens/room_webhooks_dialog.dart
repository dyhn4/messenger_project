import 'package:flutter/material.dart';

import '../models/integration.dart';
import '../models/room.dart';
import '../models/team.dart' show AccountRole;
import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/avatar_utils.dart';
import '../widgets/integration_widgets.dart';
import '../l10n/tr.dart';

/// "웹훅" — 이 방(토픽·그룹)에 붙인 들어오는 웹훅을 만들고 지운다(server/src/integrations.js). 바깥 서비스(서버 모니터링·CI/배포·
/// 설문 등)가 웹훅 주소로 JSON을 보내면 그 이름·아이콘의 봇 메시지로 올라온다. 주소에 든 토큰이 열쇠라 만들 때 한 번만 보인다.
Future<void> showRoomWebhooksDialog(
  BuildContext context,
  Session session,
  Room room,
) => showDialog<void>(
  context: context,
  builder: (_) => RoomWebhooksDialog(session: session, room: room),
);

/// 이 방에서 웹훅을 다룰 수 있는지 — 서버 integrationRules.js canManageRoomWebhooks와 같은 규칙(메뉴를 보일지만 정한다).
bool canManageRoomWebhooks(Session session, Room room) {
  if (room.isSecret) return false;
  if (room.type == RoomType.topic) {
    return room.viewMode == TopicViewMode.chat && room.canManage(session);
  }
  if (room.type == RoomType.group) {
    return session.accountRole != AccountRole.guest;
  }
  return false;
}

class RoomWebhooksDialog extends StatefulWidget {
  final Session session;
  final Room room;
  const RoomWebhooksDialog({
    super.key,
    required this.session,
    required this.room,
  });

  @override
  State<RoomWebhooksDialog> createState() => _RoomWebhooksDialogState();
}

class _RoomWebhooksDialogState extends State<RoomWebhooksDialog> {
  List<Integration>? _hooks;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final hooks = await widget.session.api!.fetchRoomWebhooks(widget.room.id);
      if (mounted) setState(() => _hooks = hooks);
    } catch (e) {
      if (mounted) {
        setState(() => _error = tr('웹훅 목록을 불러오지 못했습니다: {e}', {'e': e}));
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
    final input = await showBotNameDialog(
      context,
      title: tr('웹훅 만들기'),
      confirmLabel: tr('만들기'),
    );
    if (input == null || !mounted) return;
    await _run(() async {
      final made = await widget.session.api!.createWebhook(
        widget.room.id,
        name: input.name,
        emoji: input.emoji,
      );
      await _load();
      if (mounted) await _reveal(made, created: true);
    }, tr('웹훅을 만들지 못했습니다'));
  }

  Future<void> _reveal(WebhookSecret s, {required bool created}) =>
      showSecretRevealDialog(
        context,
        title: created ? tr('웹훅을 만들었습니다') : tr('새 웹훅 주소'),
        intro: tr('바깥 서비스의 웹훅(Webhook URL) 칸에 이 주소를 넣으세요.'),
        secret: s.url,
        children: [WebhookUsageHelp(secret: s)],
      );

  Future<void> _rename(Integration hook) async {
    final input = await showBotNameDialog(
      context,
      title: tr('이름·아이콘 바꾸기'),
      initialName: hook.name,
      initialEmoji: hook.emoji,
    );
    if (input == null || !mounted) return;
    await _run(() async {
      await widget.session.api!.updateIntegration(hook.id, {
        'name': input.name,
        'emoji': input.emoji,
      });
      await _load();
    }, tr('바꾸지 못했습니다'));
  }

  Future<void> _regenerate(Integration hook) async {
    final ok = await confirmIntegrationDelete(
      context,
      title: tr('새 주소 만들기'),
      body: tr('"{hook.name}"의 지금 주소는 바로 못 쓰게 됩니다. 바깥 서비스에 새 주소를 다시 넣어야 합니다.', {
        'hook.name': hook.name,
      }),
    );
    if (!ok || !mounted) return;
    await _run(() async {
      final s =
          await widget.session.api!.regenerateIntegration(hook)
              as WebhookSecret;
      await _load();
      if (mounted) await _reveal(s, created: false);
    }, tr('새 주소를 만들지 못했습니다'));
  }

  Future<void> _delete(Integration hook) async {
    final ok = await confirmIntegrationDelete(
      context,
      title: tr('웹훅 지우기'),
      body: tr(
        '"{hook.name}" 웹훅을 지울까요? 이 주소로 오는 글은 더 올라오지 않습니다. 이미 올라온 메시지는 그대로 남습니다.',
        {'hook.name': hook.name},
      ),
    );
    if (!ok || !mounted) return;
    await _run(() async {
      await widget.session.api!.deleteIntegration(hook.id);
      await _load();
    }, tr('지우지 못했습니다'));
  }

  @override
  Widget build(BuildContext context) {
    final hooks = _hooks;
    final hint = Theme.of(context).hintColor;
    return AlertDialog(
      title: Text(tr('웹훅')),
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
            : hooks == null
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
                        '서버 모니터링 알림, CI/배포 결과, 설문 응답 같은 바깥 소식을 이 방에 봇 메시지로 받습니다. Slack·Discord 웹훅 형식도 그대로 받습니다.',
                      ),
                      style: TextStyle(fontSize: 12, color: hint),
                    ),
                  ),
                  if (hooks.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: Text(
                          tr('아직 웹훅이 없습니다.'),
                          style: TextStyle(color: hint),
                        ),
                      ),
                    ),
                  for (final h in hooks)
                    ListTile(
                      key: ValueKey('webhook-${h.id}'),
                      leading: AutomationAvatar(radius: 16, emoji: h.emoji),
                      title: Text(
                        h.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${h.tokenPrefix ?? ''}… · ${integrationUsageText(h.lastUsedAt, h.useCount)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: PopupMenuButton<String>(
                        key: ValueKey('webhook-menu-${h.id}'),
                        enabled: !_busy,
                        onSelected: (v) => switch (v) {
                          'rename' => _rename(h),
                          'regenerate' => _regenerate(h),
                          _ => _delete(h),
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'rename',
                            child: Text(tr('이름·아이콘 바꾸기')),
                          ),
                          PopupMenuItem(
                            value: 'regenerate',
                            child: Text(tr('새 주소 만들기')),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(
                              tr('지우기'),
                              style: TextStyle(color: Colors.redAccent),
                            ),
                          ),
                        ],
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
        FilledButton.icon(
          key: const ValueKey('webhook-create'),
          onPressed: _busy || hooks == null ? null : _create,
          icon: const Icon(Icons.add, size: 18),
          label: Text(tr('웹훅 만들기')),
        ),
      ],
    );
  }
}

/// 웹훅 주소를 보여 줄 때 붙이는 사용법 — 보내는 모양과 curl 예, 자체 서명 인증서 안내.
class WebhookUsageHelp extends StatelessWidget {
  final WebhookSecret secret;
  const WebhookUsageHelp({super.key, required this.secret});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final small = TextStyle(fontSize: 12, color: hint);
    final selfSigned = secret.webUrl == null;
    final curl = tr(
      'curl -X POST{p0} -H \'Content-Type: application/json\' -d \'{"text":"배포가 끝났습니다"}\' {secret.url}',
      {'p0': selfSigned ? ' -k' : '', 'secret.url': secret.url},
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 14),
        Text(tr('보내는 방법'), style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(
          tr(
            'POST로 JSON {"text": "보낼 글"}을 보내면 됩니다. Slack(text·attachments·blocks)·Discord(content·embeds) 형식과 그냥 글(text/plain)도 받습니다. 1분에 60건까지.',
          ),
          style: small,
        ),
        const SizedBox(height: 6),
        CopyableSecretField(value: curl, copiedText: tr('예시 명령을 복사했습니다.')),
        if (selfSigned) ...[
          const SizedBox(height: 8),
          Text(
            tr(
              '이 서버는 자체 서명 인증서를 써서 바깥 서비스가 주소를 믿지 않을 수 있습니다(인증서 확인 끄기 필요 — curl은 -k). 관리자 콘솔에서 웹 앱 주소(정식 인증서)를 설정하면 그 주소로 안내합니다.',
            ),
            style: small,
          ),
        ] else if (secret.directUrl.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(tr('사내에서 보낼 때는 이 주소도 됩니다(자체 서명 인증서):'), style: small),
          const SizedBox(height: 4),
          CopyableSecretField(value: secret.directUrl),
        ],
      ],
    );
  }
}
