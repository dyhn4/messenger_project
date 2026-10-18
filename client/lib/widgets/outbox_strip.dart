import 'package:flutter/material.dart';

import '../services/message_outbox.dart';
import '../services/session.dart';
import '../l10n/tr.dart';

/// 대화방 아래(입력칸 바로 위)의 보내기 대기열 — 아직 서버에 닿지 않은 내 메시지를 오른쪽 말풍선으로 보여 준다. 보내는 중·연결을
/// 기다림(붙으면 보냄)·실패(서버가 거절 — 이유와 다시 보내기·지우기). 서버에 닿으면 대화 목록에 진짜 메시지로 나타나고 여기서 사라진다.
class OutboxStrip extends StatelessWidget {
  final Session session;
  final String roomId;
  const OutboxStrip({super.key, required this.session, required this.roomId});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session.outbox,
      builder: (context, _) {
        final items = session.outbox.forRoom(roomId);
        if (items.isEmpty) return const SizedBox.shrink();
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: SingleChildScrollView(
            key: const ValueKey('outbox-strip'),
            reverse: true,
            padding: const EdgeInsets.fromLTRB(48, 4, 12, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final item in items)
                  _OutboxBubble(
                    item: item,
                    onRetry: () => session.outbox.retry(item.clientId),
                    onDiscard: () => session.outbox.discard(item.clientId),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _OutboxBubble extends StatelessWidget {
  final OutboxItem item;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;
  const _OutboxBubble({
    required this.item,
    required this.onRetry,
    required this.onDiscard,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = item.state == OutboxState.failed;
    final status = switch (item.state) {
      OutboxState.sending => tr('보내는 중…'),
      OutboxState.waiting => tr('연결되면 보냅니다'),
      OutboxState.failed => item.error ?? tr('보내지 못했습니다'),
    };
    return Padding(
      key: ValueKey('outbox-${item.clientId}'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(
                alpha: failed ? 0.35 : 0.6,
              ),
              borderRadius: BorderRadius.circular(14),
              border: failed
                  ? Border.all(color: theme.colorScheme.error)
                  : null,
            ),
            child: Text(
              item.preview,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: theme.hintColor.withValues(alpha: 0.9)),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (item.state == OutboxState.sending)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                )
              else
                Icon(
                  failed ? Icons.error_outline : Icons.schedule,
                  size: 13,
                  color: failed ? theme.colorScheme.error : theme.hintColor,
                ),
              const SizedBox(width: 3),
              Flexible(
                child: Text(
                  status,
                  key: ValueKey('outbox-status-${item.clientId}'),
                  style: TextStyle(
                    fontSize: 11,
                    color: failed ? theme.colorScheme.error : theme.hintColor,
                  ),
                ),
              ),
              if (failed) ...[
                TextButton(
                  key: ValueKey('outbox-retry-${item.clientId}'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: onRetry,
                  child: Text(tr('다시 보내기')),
                ),
                TextButton(
                  key: ValueKey('outbox-discard-${item.clientId}'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: onDiscard,
                  child: Text(tr('지우기')),
                ),
              ] else if (item.state == OutboxState.waiting)
                TextButton(
                  key: ValueKey('outbox-discard-${item.clientId}'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: onDiscard,
                  child: Text(tr('취소')),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 서버와의 실시간 연결이 끊겼을 때(3초 넘게) 화면 위 띠 — 저장해 둔 목록을 보여 주는 중이고 보내는 메시지는 연결되면 보낸다고 알린다.
class ConnectionLostBanner extends StatelessWidget {
  final Session session;
  const ConnectionLostBanner({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        if (!session.connectionLost) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Material(
          key: const ValueKey('connection-lost-banner'),
          color: theme.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Icon(
                  Icons.cloud_off,
                  size: 16,
                  color: theme.colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tr(
                      '서버와 연결이 끊겼습니다 — 다시 연결하는 중입니다. 이 기기에 저장해 둔 대화를 보여 주고, 보내는 메시지는 연결되면 보냅니다.',
                    ),
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
