import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/tr.dart';
import '../models/bot_blocks.dart';
import '../models/message.dart';
import '../services/app_links.dart';
import '../services/session.dart';
import 'app_toast.dart';
import 'avatar_utils.dart';
import 'rich_text_format.dart';

/// 대화형 봇 메시지 — 봇 메시지의 블록(models/bot_blocks.dart)을 말풍선 안에 그린다: 머리글, 글(+ 오른쪽 단추·선택지), 두 줄 칸,
/// 문맥(작은 회색 글), 구분선, 그림, 단추·선택지 줄. 웹훅·슬래시 명령·연동 앱이 Slack Block Kit 모양으로 보낸 것을 서버가 걸러 둔 것이다.
///
/// 단추·선택지를 누르면 서버(POST /api/messages/:id/actions)가 그 연동의 응답 주소로 알리고, 답에 따라 메시지가 바뀌거나(소켓
/// message:edited — 이 위젯이 새 블록으로 다시 그려진다)·새 메시지가 오거나·나에게만 보일 답이 온다(창으로 보여 준다). 링크 단추는 서버에
/// 알리지 않고 그 주소를 연다. 누른 단추는 답이 올 때까지 돌아가는 표시로 바뀌고, 그동안 다른 단추도 누를 수 없다(두 번 누르기 막기).
class BotBlocksView extends StatefulWidget {
  final Session session;
  final Message message;
  final List<BotBlock> blocks;

  /// 그림 블록의 서명 링크(상대 경로)를 받을 주소로 — 말풍선과 같은 것(session.resolveUrl).
  final String Function(String relative) resolveUrl;

  /// 링크 단추 열기 — 테스트가 바꾼다.
  @visibleForTesting
  static Future<void> Function(String url) openLink = _openLink;

  const BotBlocksView({
    super.key,
    required this.session,
    required this.message,
    required this.blocks,
    required this.resolveUrl,
  });

  @override
  State<BotBlocksView> createState() => _BotBlocksViewState();
}

Future<void> _openLink(String url) async {
  if (AppLinks.open(url)) return;
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    // 브라우저를 못 열어도 조용히 — 링크 미리보기 카드와 같다.
  }
}

class _BotBlocksViewState extends State<BotBlocksView> {
  /// 답을 기다리는 단추·선택지(actionId) — 그동안 모든 단추를 막는다.
  String? _pending;

  /// 선택지에서 고른 값(actionId → value) — 서버가 메시지를 바꾸기 전까지 고른 것을 보여 준다.
  final Map<String, String> _selected = {};

  @override
  void didUpdateWidget(covariant BotBlocksView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 메시지가 바뀌면(단추를 누른 뒤 "승인됨"으로 등) 고른 값은 새 블록의 처음 값을 따른다.
    if (!identical(oldWidget.blocks, widget.blocks)) _selected.clear();
  }

  Future<void> _run(BotElement element, {String? value}) async {
    if (_pending != null) return;
    final api = widget.session.api;
    if (api == null) return;
    setState(() => _pending = element.actionId);
    String? reply;
    try {
      final result = await api.runMessageAction(
        widget.message.id,
        actionId: element.actionId,
        value: value,
      );
      reply = result.ephemeral;
    } catch (e) {
      if (mounted) {
        showAppToast(context, tr('단추를 처리하지 못했습니다: {e}', {'e': e}));
      }
    } finally {
      if (mounted) setState(() => _pending = null);
    }
    // 답 창은 기다림 표시를 푼 뒤에(창이 떠 있는 동안 단추가 계속 돌아가지 않게 — 슬래시 명령의 답 창과 같다).
    if (reply != null && reply.isNotEmpty && mounted) {
      await showBotReplyDialog(
        context,
        botName: widget.message.senderName,
        emoji: widget.message.bot?.emoji,
        text: reply,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (final b in widget.blocks) {
      if (children.isNotEmpty) children.add(const SizedBox(height: 6));
      children.add(_block(context, b));
    }
    return Column(
      key: const ValueKey('bot-blocks'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _text(BuildContext context, String text, {TextStyle? style}) =>
      FormattedText(
        text,
        style: style ?? Theme.of(context).textTheme.bodyMedium,
        linkColor: Colors.blue,
        selectable: false,
      );

  Widget _block(BuildContext context, BotBlock block) {
    final theme = Theme.of(context);
    switch (block) {
      case BotHeaderBlock(:final text):
        return Text(
          text,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        );
      case BotSectionBlock(:final text, :final fields, :final accessory):
        final body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (text != null && text.isNotEmpty) _text(context, text),
            if (fields.isNotEmpty) ...[
              if (text != null && text.isNotEmpty) const SizedBox(height: 6),
              _fields(context, fields),
            ],
          ],
        );
        if (accessory == null) return body;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(child: body),
            const SizedBox(width: 8),
            _element(context, accessory),
          ],
        );
      case BotContextBlock(:final text):
        return _text(
          context,
          text,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        );
      case BotDividerBlock():
        return const Divider(height: 8);
      case BotImageBlock(:final url, :final alt, :final title):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title != null) ...[
              Text(title, style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360, maxHeight: 320),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  widget.resolveUrl(url),
                  fit: BoxFit.contain,
                  semanticLabel: alt,
                  errorBuilder: (_, _, _) => Text(
                    alt ?? tr('그림을 불러오지 못했습니다.'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      case BotActionsBlock(:final elements):
        return Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [for (final e in elements) _element(context, e)],
        );
    }
  }

  /// 두 줄 칸 — 넓으면 두 칸씩, 좁으면 한 칸씩.
  Widget _fields(BuildContext context, List<String> fields) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumns =
            constraints.maxWidth.isFinite && constraints.maxWidth >= 280;
        final width = twoColumns
            ? (constraints.maxWidth - 12) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: 12,
          runSpacing: 6,
          children: [
            for (final f in fields)
              SizedBox(
                width: width.isFinite ? width : null,
                child: _text(context, f),
              ),
          ],
        );
      },
    );
  }

  Widget _element(BuildContext context, BotElement element) {
    final busy = _pending != null;
    final mine = _pending == element.actionId;
    switch (element) {
      case BotButton():
        return _button(context, element, busy: busy, spinning: mine);
      case BotSelect():
        return _select(context, element, busy: busy, spinning: mine);
    }
  }

  Widget _button(
    BuildContext context,
    BotButton b, {
    required bool busy,
    required bool spinning,
  }) {
    final theme = Theme.of(context);
    final key = ValueKey('bot-action-${b.actionId}');
    final onPressed = b.isLink
        ? () => BotBlocksView.openLink(b.url!)
        : busy
        ? null
        : () => _run(b);
    final label = spinning
        ? const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(b.text, overflow: TextOverflow.ellipsis)),
              if (b.isLink) ...[
                const SizedBox(width: 4),
                const Icon(Icons.open_in_new, size: 14),
              ],
            ],
          );
    const padding = EdgeInsets.symmetric(horizontal: 12, vertical: 6);
    return switch (b.style) {
      BotButtonStyle.primary => FilledButton(
        key: key,
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          padding: padding,
          visualDensity: VisualDensity.compact,
        ),
        child: label,
      ),
      BotButtonStyle.danger => OutlinedButton(
        key: key,
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: theme.colorScheme.error,
          side: BorderSide(color: theme.colorScheme.error),
          padding: padding,
          visualDensity: VisualDensity.compact,
        ),
        child: label,
      ),
      BotButtonStyle.normal => OutlinedButton(
        key: key,
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: padding,
          visualDensity: VisualDensity.compact,
        ),
        child: label,
      ),
    };
  }

  Widget _select(
    BuildContext context,
    BotSelect s, {
    required bool busy,
    required bool spinning,
  }) {
    final chosen = _selected[s.actionId] ?? s.initial;
    String? chosenText;
    for (final o in s.options) {
      if (o.value == chosen) chosenText = o.text;
    }
    return PopupMenuButton<String>(
      key: ValueKey('bot-action-${s.actionId}'),
      enabled: !busy,
      tooltip: s.placeholder ?? tr('고르기'),
      onSelected: (value) {
        setState(() => _selected[s.actionId] = value);
        _run(s, value: value);
      },
      itemBuilder: (_) => [
        for (final o in s.options)
          CheckedPopupMenuItem(
            key: ValueKey('bot-option-${s.actionId}-${o.value}'),
            value: o.value,
            checked: o.value == chosen,
            child: Text(o.text),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                chosenText ?? s.placeholder ?? tr('고르기'),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            spinning
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }
}

/// 봇이 나에게만 보인 답(단추를 누른 뒤 등) — 봇 아이콘·이름과 글. 다른 사람에게는 보이지 않는다는 안내를 붙인다.
Future<void> showBotReplyDialog(
  BuildContext context, {
  required String botName,
  String? emoji,
  required String text,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('bot-reply-dialog'),
      title: Row(
        children: [
          AutomationAvatar(radius: 14, emoji: emoji),
          const SizedBox(width: 8),
          Expanded(child: Text(botName, overflow: TextOverflow.ellipsis)),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(text),
              const SizedBox(height: 10),
              Text(
                tr('나에게만 보이는 답입니다.'),
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(dialogContext).hintColor,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(tr('닫기')),
        ),
      ],
    ),
  );
}
