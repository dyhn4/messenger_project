import 'package:flutter/material.dart';

import '../models/message.dart';
import '../models/message_reaction.dart';
import '../services/session.dart';
import 'app_toast.dart';

/// 메시지 공감(이모지 반응) — 말풍선 아래의 공감 줄([MessageReactionBar])과 고르는 줄([ReactionPicker]).
/// 카카오톡 공감처럼 한 사람이 한 메시지에 하나만 고르고(같은 것을 다시 누르면 빠짐), 고를 수 있는 이모지는
/// [reactionEmojis]로 정해 둔다(server/src/reactionRules.js와 같이).

/// 이 메시지에 공감을 남길 수 있는지 — 비밀 대화(서버가 누가 무엇에 반응했는지도 모르게)·시스템 메시지·지운 메시지·
/// 댓글 항목·복호화 못 한 메시지는 안 된다(서버도 같은 규칙으로 막는다).
bool canReactToMessage(Session session, Message message) {
  if (message.deleted ||
      message.decryptFailed ||
      message.asComment != null ||
      message.type == MessageType.system) {
    return false;
  }
  for (final r in session.rooms) {
    if (r.id == message.roomId) return !r.isSecret;
  }
  return true;
}

/// 공감한 사람의 이름 — 그 방 멤버에서 찾고, 나는 내 이름, 못 찾으면(나간 사람) "알 수 없음".
String reactorName(Session session, String roomId, String userId) {
  if (userId == session.userId) return session.name ?? '나';
  for (final r in session.rooms) {
    if (r.id != roomId) continue;
    for (final m in r.members) {
      if (m.id == userId) return m.name;
    }
  }
  return '알 수 없음';
}

/// 공감을 누르거나 바꾼다 — 실패하면 알린다(화면은 Session이 원래대로 되돌린다).
Future<void> reactToMessage(
  BuildContext context,
  Session session,
  Message message,
  String emoji,
) async {
  try {
    await session.toggleMessageReaction(message, emoji);
  } catch (e) {
    if (context.mounted) showAppToast(context, '공감을 남기지 못했습니다: $e');
  }
}

/// 말풍선 아래의 공감 줄 — 이모지와 수. 내가 고른 것은 테두리로 표시하고, 누르면 그것으로 공감하거나(내 것이면) 뺀다.
/// PC는 마우스를 올리면 누가 눌렀는지, 휴대폰은 길게 누르면 목록이 뜬다. 공감이 없으면 아무것도 그리지 않는다.
class MessageReactionBar extends StatelessWidget {
  final Session session;
  final Message message;

  /// 내 말풍선이면 오른쪽 정렬 줄에 맞춘다.
  final WrapAlignment alignment;

  const MessageReactionBar({
    super.key,
    required this.session,
    required this.message,
    this.alignment = WrapAlignment.start,
  });

  @override
  Widget build(BuildContext context) {
    final reactions = message.reactions;
    if (reactions.isEmpty || message.deleted) return const SizedBox.shrink();
    final mine = myReaction(reactions, session.userId);
    final canReact = canReactToMessage(session, message);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        alignment: alignment,
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final r in reactions)
            _ReactionChip(
              key: ValueKey('reaction-${r.emoji}'),
              reaction: r,
              selected: r.emoji == mine,
              tooltip: [
                for (final id in r.userIds)
                  reactorName(session, message.roomId, id),
              ].join(', '),
              onTap: canReact
                  ? () => reactToMessage(context, session, message, r.emoji)
                  : null,
              onLongPress: () => showReactorsSheet(context, session, message),
            ),
        ],
      ),
    );
  }
}

class _ReactionChip extends StatelessWidget {
  final MessageReaction reaction;
  final bool selected;
  final String tooltip;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;

  const _ReactionChip({
    super.key,
    required this.reaction,
    required this.selected,
    required this.tooltip,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: selected
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        shape: StadiumBorder(
          side: BorderSide(
            color: selected ? scheme.primary : Colors.transparent,
            width: 1.2,
          ),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: reaction.emoji,
                    style: const TextStyle(fontSize: 14),
                  ),
                  TextSpan(
                    text: ' ${reaction.count}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: selected ? scheme.primary : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 공감을 고르는 줄 — 자주 쓰는 여섯 개([quickReactionCount])를 한 줄로 두고, 끝의 "+"를 누르면 나머지까지 격자로 펼친다. 내가 고른
/// 것은 동그라미로 표시하고, 고른 게 펼친 쪽에 있으면 처음부터 펼쳐 둔다. 휴대폰 롱프레스 시트 맨 위와 PC 말풍선 툴바의 공감 메뉴가
/// 같이 쓴다.
class ReactionPicker extends StatefulWidget {
  /// 지금 내 공감 — 없으면 null.
  final String? selected;
  final ValueChanged<String> onPicked;
  final double emojiSize;

  const ReactionPicker({
    super.key,
    required this.selected,
    required this.onPicked,
    this.emojiSize = 24,
  });

  @override
  State<ReactionPicker> createState() => _ReactionPickerState();
}

class _ReactionPickerState extends State<ReactionPicker> {
  /// 펼친 격자의 한 줄 칸 수.
  static const _columns = 8;

  late bool _expanded =
      widget.selected != null &&
      reactionEmojis.indexOf(widget.selected!) >= quickReactionCount;

  /// 이모지 한 칸의 폭 — 글자 + 동그라미 안쪽 여백(6×2) + 칸 사이(2×2).
  double get _cell => widget.emojiSize * 1.2 + 16;

  Widget _emoji(String emoji) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkResponse(
        key: ValueKey('pick-reaction-$emoji'),
        radius: widget.emojiSize,
        onTap: () => widget.onPicked(emoji),
        child: Container(
          width: _cell - 4,
          padding: const EdgeInsets.all(6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: emoji == widget.selected ? scheme.primaryContainer : null,
          ),
          child: Text(emoji, style: TextStyle(fontSize: widget.emojiSize)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final quick = reactionEmojis.take(quickReactionCount);
    final more = reactionEmojis.skip(quickReactionCount).toList();
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final emoji in quick) _emoji(emoji),
        SizedBox(
          width: _cell,
          child: IconButton(
            key: const ValueKey('pick-reaction-more'),
            tooltip: _expanded ? '접기' : '공감 더 보기',
            icon: Icon(
              _expanded ? Icons.expand_less : Icons.add,
              size: widget.emojiSize,
            ),
            onPressed: () => setState(() => _expanded = !_expanded),
          ),
        ),
      ],
    );
    if (!_expanded) return row;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row,
        const Divider(height: 8),
        SizedBox(
          key: const ValueKey('reaction-picker-grid'),
          width: _cell * _columns,
          child: Wrap(
            children: [
              for (final emoji in more)
                SizedBox(width: _cell, child: _emoji(emoji)),
            ],
          ),
        ),
      ],
    );
  }
}

/// 공감 더하기 버튼 — 누르면 고르는 줄([ReactionPicker])이 메뉴로 뜬다. 말풍선 툴바가 없는 곳(보드 게시글 상세)에서 쓴다.
/// 공감할 수 없는 메시지면 아무것도 그리지 않는다.
class ReactionAddButton extends StatelessWidget {
  final Session session;
  final Message message;

  const ReactionAddButton({
    super.key,
    required this.session,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    if (!canReactToMessage(session, message)) return const SizedBox.shrink();
    return MenuAnchor(
      menuChildren: [
        Builder(
          builder: (menuContext) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ReactionPicker(
              selected: myReaction(message.reactions, session.userId),
              emojiSize: 20,
              onPicked: (emoji) {
                MenuController.maybeOf(menuContext)?.close();
                reactToMessage(context, session, message, emoji);
              },
            ),
          ),
        ),
      ],
      builder: (context, controller, _) => IconButton(
        key: const ValueKey('add-reaction'),
        tooltip: '공감',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.add_reaction_outlined, size: 20),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// 누가 어떤 공감을 남겼는지 — 이모지별로 이름을 모아 보여 주는 하단 시트.
void showReactorsSheet(BuildContext context, Session session, Message message) {
  final reactions = message.reactions;
  if (reactions.isEmpty) return;
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Text(
            '공감 ${reactions.fold<int>(0, (n, r) => n + r.count)}',
            style: Theme.of(
              sheetContext,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          for (final r in reactions)
            for (final id in r.userIds)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Text(r.emoji, style: const TextStyle(fontSize: 20)),
                title: Text(reactorName(session, message.roomId, id)),
              ),
        ],
      ),
    ),
  );
}
