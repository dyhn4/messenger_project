import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/integration.dart';
import '../services/time_format.dart';
import 'app_toast.dart';
import 'avatar_utils.dart';

/// 외부 연동 화면(웹훅·슬래시 명령·개인 API 토큰)이 함께 쓰는 조각 — 한 번만 보이는 비밀값 창, 복사 칸, 이름·아이콘 입력.

/// 비밀값(웹훅 주소·API 토큰·서명 비밀)을 한 줄로 보여 주고 복사 단추를 붙인 칸.
class CopyableSecretField extends StatelessWidget {
  final String value;
  final String copiedText;
  final Key? fieldKey;
  const CopyableSecretField({
    super.key,
    required this.value,
    this.copiedText = '복사했습니다.',
    this.fieldKey,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              value,
              key: fieldKey,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          IconButton(
            tooltip: '복사',
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (context.mounted) showAppToast(context, copiedText);
            },
          ),
        ],
      ),
    );
  }
}

/// 만든 직후 한 번만 보여 주는 비밀값 창 — 닫으면 다시 볼 수 없다는 안내를 붙인다. [children]은 비밀값 아래에 붙는 안내(사용 예 등).
Future<void> showSecretRevealDialog(
  BuildContext context, {
  required String title,
  required String intro,
  required String secret,
  List<Widget> children = const [],
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(intro),
              const SizedBox(height: 10),
              CopyableSecretField(
                value: secret,
                fieldKey: const ValueKey('integration-secret'),
              ),
              const SizedBox(height: 8),
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
                      '이 창을 닫으면 다시 볼 수 없습니다. 지금 복사해 두세요. 새어 나갔다면 "새로 만들기"로 바꾸세요.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.orange.shade800,
                      ),
                    ),
                  ),
                ],
              ),
              ...children,
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('integration-secret-done'),
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('복사했습니다'),
        ),
      ],
    ),
  );
}

/// 이름·아이콘(이모지) 입력 창 — 웹훅 만들기·이름 바꾸기. 확인하면 (이름, 이모지 — 비우면 null).
Future<({String name, String? emoji})?> showBotNameDialog(
  BuildContext context, {
  required String title,
  String initialName = '',
  String? initialEmoji,
  String nameHint = '예: 서버 모니터링',
  String confirmLabel = '저장',
}) {
  return showDialog<({String name, String? emoji})>(
    context: context,
    builder: (_) => _BotNameDialog(
      title: title,
      initialName: initialName,
      initialEmoji: initialEmoji,
      nameHint: nameHint,
      confirmLabel: confirmLabel,
    ),
  );
}

class _BotNameDialog extends StatefulWidget {
  final String title;
  final String initialName;
  final String? initialEmoji;
  final String nameHint;
  final String confirmLabel;
  const _BotNameDialog({
    required this.title,
    required this.initialName,
    required this.initialEmoji,
    required this.nameHint,
    required this.confirmLabel,
  });

  @override
  State<_BotNameDialog> createState() => _BotNameDialogState();
}

class _BotNameDialogState extends State<_BotNameDialog> {
  late final _name = TextEditingController(text: widget.initialName);
  late final _emoji = TextEditingController(text: widget.initialEmoji ?? '');

  @override
  void dispose() {
    _name.dispose();
    _emoji.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final emoji = _emoji.text.trim();
    Navigator.of(
      context,
    ).pop((name: name, emoji: emoji.isEmpty ? null : emoji));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('bot-name-field'),
              controller: _name,
              autofocus: true,
              maxLength: 40,
              decoration: InputDecoration(
                labelText: '봇 이름',
                hintText: widget.nameHint,
              ),
              onSubmitted: (_) => _submit(),
            ),
            TextField(
              key: const ValueKey('bot-emoji-field'),
              controller: _emoji,
              decoration: const InputDecoration(
                labelText: '아이콘(이모지 하나)',
                hintText: '비우면 🤖',
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('bot-name-confirm'),
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// 슬래시 명령의 "나에게만 보이는 답" — 방에는 올라가지 않는다(Slack의 ephemeral과 같다).
Future<void> showSlashReplyDialog(
  BuildContext context, {
  required String command,
  required String botName,
  String? emoji,
  required String text,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('slash-reply-dialog'),
      title: Row(
        children: [
          AutomationAvatar(radius: 14, emoji: emoji),
          const SizedBox(width: 8),
          Flexible(child: Text(botName, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 6),
          const BotBadge(),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '/$command · 나에게만 보이는 답',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(dialogContext).hintColor,
                ),
              ),
              const SizedBox(height: 8),
              SelectableText(text),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('닫기'),
        ),
      ],
    ),
  );
}

/// 입력칸 위에 뜨는 슬래시 명령 고르기 — 누르면 `/명령 `을 입력칸에 채운다.
class SlashCommandSuggestions extends StatelessWidget {
  final List<Integration> commands;
  final ValueChanged<Integration> onPick;
  const SlashCommandSuggestions({
    super.key,
    required this.commands,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Container(
      key: const ValueKey('slash-suggestions'),
      margin: const EdgeInsets.only(bottom: 6),
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          for (final c in commands)
            InkWell(
              key: ValueKey('slash-suggestion-${c.command}'),
              onTap: () => onPick(c),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    AutomationAvatar(radius: 11, emoji: c.emoji),
                    const SizedBox(width: 8),
                    Text(
                      '/${c.command}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        c.description ?? c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: hint),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// "마지막 사용 …" / "아직 안 씀" 한 줄.
String integrationUsageText(DateTime? lastUsedAt, int useCount) =>
    lastUsedAt == null
    ? '아직 쓰지 않음'
    : '마지막 사용 ${formatPostDateTime(lastUsedAt)} · $useCount번';

/// 지우기 확인 창 — 확인하면 true.
Future<bool> confirmIntegrationDelete(
  BuildContext context, {
  required String title,
  required String body,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('integration-delete-confirm'),
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('지우기'),
        ),
      ],
    ),
  );
  return ok == true;
}
