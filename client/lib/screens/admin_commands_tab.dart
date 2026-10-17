import 'package:flutter/material.dart';

import '../models/admin.dart';
import '../models/integration.dart';
import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/avatar_utils.dart';
import '../widgets/integration_widgets.dart';

/// "서버 관리 > 슬래시 명령" — 팀마다 `/명령`을 등록한다(server/src/integrations.js). 대화방(토픽·그룹)에서 `/명령 내용`을 치면 서버가
/// 등록한 주소로 서명한 요청(X-TangoTalk-Signature)을 보내고, 받은 답을 봇 메시지로 올리거나(in_channel) 부른 사람에게만 보여 준다.
/// 서버가 사내 다른 주소로 요청을 보내는 일이라 서버 운영자만 만든다.
class AdminCommandsTab extends StatefulWidget {
  final Session session;
  const AdminCommandsTab({super.key, required this.session});

  @override
  State<AdminCommandsTab> createState() => _AdminCommandsTabState();
}

class _AdminCommandsTabState extends State<AdminCommandsTab> {
  List<AdminTeam>? _teams;
  String? _teamId;
  List<Integration>? _commands;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadTeams();
  }

  Future<void> _loadTeams() async {
    setState(() => _error = null);
    try {
      final teams = await widget.session.api!.fetchAdminTeams();
      if (!mounted) return;
      setState(() {
        _teams = teams;
        _teamId ??= teams.isEmpty ? null : teams.first.id;
      });
      await _loadCommands();
    } catch (e) {
      if (mounted) setState(() => _error = '팀 목록을 불러오지 못했습니다: $e');
    }
  }

  Future<void> _loadCommands() async {
    final teamId = _teamId;
    if (teamId == null) return;
    setState(() => _commands = null);
    try {
      final list = await widget.session.teamCommands(teamId, refresh: true);
      if (mounted && teamId == _teamId) setState(() => _commands = list);
    } catch (e) {
      if (mounted) setState(() => _error = '명령 목록을 불러오지 못했습니다: $e');
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

  Future<void> _revealSecret(String secret, {required bool created}) =>
      showSecretRevealDialog(
        context,
        title: created ? '슬래시 명령을 만들었습니다' : '새 서명 비밀',
        intro: '명령을 받는 서버에 이 서명 비밀을 넣으세요. 요청이 이 서버에서 온 것인지 확인하는 데 씁니다.',
        secret: secret,
        children: const [CommandSignatureHelp()],
      );

  Future<void> _create() async {
    final teamId = _teamId;
    if (teamId == null) return;
    final input = await showDialog<_CommandInput>(
      context: context,
      builder: (_) => const _CommandEditDialog(),
    );
    if (input == null || !mounted) return;
    await _run(() async {
      final (_, secret) = await widget.session.api!.createTeamCommand(
        teamId,
        command: input.command,
        name: input.name,
        url: input.url,
        emoji: input.emoji,
        description: input.description,
      );
      await _loadCommands();
      if (mounted) await _revealSecret(secret, created: true);
    }, '명령을 만들지 못했습니다');
  }

  Future<void> _edit(Integration c) async {
    final input = await showDialog<_CommandInput>(
      context: context,
      builder: (_) => _CommandEditDialog(initial: c),
    );
    if (input == null || !mounted) return;
    await _run(() async {
      await widget.session.api!.updateIntegration(c.id, {
        'name': input.name,
        'emoji': input.emoji,
        'url': input.url,
        'description': input.description,
      });
      await _loadCommands();
    }, '바꾸지 못했습니다');
  }

  Future<void> _regenerate(Integration c) async {
    final ok = await confirmIntegrationDelete(
      context,
      title: '서명 비밀 새로 만들기',
      body: '/${c.command}의 지금 서명 비밀은 바로 못 쓰게 됩니다. 명령을 받는 서버에도 새 비밀을 넣어야 합니다.',
    );
    if (!ok || !mounted) return;
    await _run(() async {
      final secret =
          await widget.session.api!.regenerateIntegration(c) as String;
      if (mounted) await _revealSecret(secret, created: false);
    }, '새 서명 비밀을 만들지 못했습니다');
  }

  Future<void> _delete(Integration c) async {
    final ok = await confirmIntegrationDelete(
      context,
      title: '슬래시 명령 지우기',
      body: '/${c.command} 명령을 지울까요? 이미 올라온 메시지는 그대로 남습니다.',
    );
    if (!ok || !mounted) return;
    await _run(() async {
      await widget.session.api!.deleteIntegration(c.id);
      await _loadCommands();
    }, '지우지 못했습니다');
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
            TextButton(onPressed: _loadTeams, child: const Text('다시 시도')),
          ],
        ),
      );
    }
    if (teams == null) return const Center(child: CircularProgressIndicator());
    if (teams.isEmpty) {
      return Center(
        child: Text('팀이 없습니다.', style: TextStyle(color: hint)),
      );
    }
    final commands = _commands;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '대화방(토픽·그룹)에서 /명령 내용을 치면 등록한 주소로 서명한 요청을 보내고, 받은 답을 봇 메시지로 올리거나 부른 사람에게만 '
          '보여 줍니다. 배포 시작, 당번 확인, 사내 시스템 조회 같은 일을 대화방에서 바로 부를 수 있습니다.',
          style: TextStyle(fontSize: 12, color: hint),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: const ValueKey('admin-commands-team'),
                initialValue: _teamId,
                decoration: const InputDecoration(
                  labelText: '팀',
                  isDense: true,
                ),
                items: [
                  for (final t in teams)
                    DropdownMenuItem(value: t.id, child: Text(t.name)),
                ],
                onChanged: (v) {
                  setState(() => _teamId = v);
                  _loadCommands();
                },
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              key: const ValueKey('admin-command-create'),
              onPressed: _busy || commands == null ? null : _create,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('명령 만들기'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (commands == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (commands.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text('이 팀에는 슬래시 명령이 없습니다.', style: TextStyle(color: hint)),
            ),
          )
        else
          for (final c in commands)
            Card(
              key: ValueKey('admin-command-${c.id}'),
              child: ListTile(
                leading: AutomationAvatar(radius: 16, emoji: c.emoji),
                title: Text(
                  '/${c.command} · ${c.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  [
                    if (c.description != null) c.description!,
                    c.url ?? '',
                    integrationUsageText(c.lastUsedAt, c.useCount),
                  ].where((s) => s.isNotEmpty).join('\n'),
                  style: const TextStyle(fontSize: 12),
                ),
                isThreeLine: true,
                trailing: PopupMenuButton<String>(
                  key: ValueKey('admin-command-menu-${c.id}'),
                  enabled: !_busy,
                  onSelected: (v) => switch (v) {
                    'edit' => _edit(c),
                    'regenerate' => _regenerate(c),
                    _ => _delete(c),
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('바꾸기')),
                    PopupMenuItem(
                      value: 'regenerate',
                      child: Text('서명 비밀 새로 만들기'),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        '지우기',
                        style: TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

/// 서명 비밀을 보여 줄 때 붙이는 안내 — 받는 쪽이 요청을 확인하는 방법과 답하는 모양.
class CommandSignatureHelp extends StatelessWidget {
  const CommandSignatureHelp({super.key});

  @override
  Widget build(BuildContext context) {
    final small = TextStyle(fontSize: 12, color: Theme.of(context).hintColor);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 14),
        const Text(
          '받는 서버에서 할 일',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          '요청은 POST JSON {command, text, teamId, roomId, roomName, userId, username, userName, timestamp}입니다.\n'
          '· 확인: X-TangoTalk-Signature가 "v1=" + HMAC-SHA256(서명 비밀, "<X-TangoTalk-Timestamp>.<본문>")의 16진수와 같은지, '
          '시각이 5분 안인지 보세요.\n'
          '· 답: 5초 안에 JSON {"text": "…"} — 기본은 부른 사람에게만 보이고, "response_type": "in_channel"이면 방에 올라갑니다. '
          '그냥 글로 답해도 되고, 할 말이 없으면 빈 답(204).',
          style: small,
        ),
      ],
    );
  }
}

typedef _CommandInput = ({
  String command,
  String name,
  String? emoji,
  String url,
  String? description,
});

/// 명령 만들기·바꾸기 — 바꿀 때는 명령 이름은 그대로(지우고 새로 만든다).
class _CommandEditDialog extends StatefulWidget {
  final Integration? initial;
  const _CommandEditDialog({this.initial});

  @override
  State<_CommandEditDialog> createState() => _CommandEditDialogState();
}

class _CommandEditDialogState extends State<_CommandEditDialog> {
  late final _command = TextEditingController(
    text: widget.initial?.command ?? '',
  );
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _emoji = TextEditingController(text: widget.initial?.emoji ?? '');
  late final _url = TextEditingController(text: widget.initial?.url ?? '');
  late final _description = TextEditingController(
    text: widget.initial?.description ?? '',
  );
  String? _error;

  @override
  void dispose() {
    for (final c in [_command, _name, _emoji, _url, _description]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final command = _command.text
        .trim()
        .replaceFirst(RegExp(r'^/'), '')
        .toLowerCase();
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{0,31}$').hasMatch(command)) {
      setState(() => _error = '명령 이름은 영문 소문자·숫자·_·-로 32자까지 넣으세요(예: deploy).');
      return;
    }
    final url = _url.text.trim();
    if (!url.startsWith('https://') && !url.startsWith('http://')) {
      setState(() => _error = '주소는 http:// 또는 https://로 시작해야 합니다.');
      return;
    }
    final name = _name.text.trim();
    final emoji = _emoji.text.trim();
    final description = _description.text.trim();
    Navigator.of(context).pop((
      command: command,
      name: name.isEmpty ? command : name,
      emoji: emoji.isEmpty ? null : emoji,
      url: url,
      description: description.isEmpty ? null : description,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.initial != null;
    return AlertDialog(
      title: Text(editing ? '/${widget.initial!.command} 바꾸기' : '슬래시 명령 만들기'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!editing)
                TextField(
                  key: const ValueKey('command-name'),
                  controller: _command,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '명령',
                    prefixText: '/',
                    hintText: 'deploy',
                  ),
                ),
              TextField(
                key: const ValueKey('command-url'),
                controller: _url,
                decoration: const InputDecoration(
                  labelText: '요청을 보낼 주소',
                  hintText: 'https://ci.company.com/hooks/chat',
                ),
              ),
              TextField(
                key: const ValueKey('command-bot-name'),
                controller: _name,
                maxLength: 40,
                decoration: const InputDecoration(labelText: '봇 이름(비우면 명령 이름)'),
              ),
              TextField(
                key: const ValueKey('command-emoji'),
                controller: _emoji,
                decoration: const InputDecoration(
                  labelText: '아이콘(이모지 하나)',
                  hintText: '비우면 🤖',
                ),
              ),
              TextField(
                key: const ValueKey('command-description'),
                controller: _description,
                maxLength: 100,
                decoration: const InputDecoration(
                  labelText: '설명(입력칸 자동 완성에 보임)',
                  hintText: '예: 서버에 배포합니다',
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
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('command-confirm'),
          onPressed: _submit,
          child: Text(editing ? '저장' : '만들기'),
        ),
      ],
    );
  }
}
