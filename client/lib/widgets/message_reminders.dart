import 'dart:async';

import 'package:flutter/material.dart';

import '../models/message.dart';
import '../models/message_reminder.dart';
import '../models/room.dart';
import '../screens/chat_screen.dart';
import '../screens/home_screen.dart' show wideBreakpoint;
import '../services/session.dart';
import 'app_toast.dart';

/// 메시지 리마인더("나중에 알림") — 메시지 메뉴의 고르는 창([showReminderPicker]), 울렸을 때 "나와의 대화"에 올라오는 카드
/// ([ReminderCardView]), 걸어 둔 리마인더 목록([showRemindersDialog]). 서버는 server/src/reminders.js.

/// 이 메시지에 리마인더를 걸 수 있는지 — 지운 메시지·시스템 메시지·댓글 항목은 안 된다(서버도 같은 규칙).
bool canRemindMessage(Message message) =>
    !message.deleted &&
    message.asComment == null &&
    message.type != MessageType.system;

/// "10/15(수) 09:00" — 리마인더 시각 표기.
String reminderTimeLabel(DateTime at) {
  const days = ['월', '화', '수', '목', '금', '토', '일'];
  final hh = at.hour.toString().padLeft(2, '0');
  final mm = at.minute.toString().padLeft(2, '0');
  return '${at.month}/${at.day}(${days[at.weekday - 1]}) $hh:$mm';
}

/// "나중에 알림" — 빠른 선택지나 직접 고른 시각에 리마인더를 건다.
Future<void> showReminderPicker(
  BuildContext context,
  Session session,
  Message message,
) async {
  final now = DateTime.now();
  final picked = await showDialog<DateTime>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('나중에 알림'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(
            '정한 시각에 "나와의 대화"로 이 메시지를 다시 알려 드립니다.',
            style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
              color: Theme.of(dialogContext).hintColor,
            ),
          ),
        ),
        for (final p in reminderPresets(now))
          SimpleDialogOption(
            key: ValueKey('reminder-preset-${p.label}'),
            onPressed: () => Navigator.of(dialogContext).pop(p.at),
            child: Row(
              children: [
                Expanded(child: Text(p.label)),
                Text(
                  reminderTimeLabel(p.at),
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(dialogContext).hintColor,
                  ),
                ),
              ],
            ),
          ),
        SimpleDialogOption(
          key: const ValueKey('reminder-custom'),
          onPressed: () async {
            final at = await _pickDateTime(dialogContext, now);
            if (at != null && dialogContext.mounted) {
              Navigator.of(dialogContext).pop(at);
            }
          },
          child: const Text('날짜·시간 직접 고르기…'),
        ),
      ],
    ),
  );
  if (picked == null || !context.mounted) return;
  try {
    await session.api!.createMessageReminder(message.id, picked);
    if (context.mounted) {
      showAppToast(context, '${reminderTimeLabel(picked)}에 알려 드릴게요.');
    }
  } catch (e) {
    if (context.mounted) showAppToast(context, '리마인더를 걸지 못했습니다: $e');
  }
}

Future<DateTime?> _pickDateTime(BuildContext context, DateTime now) async {
  final date = await showDatePicker(
    context: context,
    initialDate: now,
    firstDate: DateTime(now.year, now.month, now.day),
    lastDate: now.add(const Duration(days: 364)),
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: const TimeOfDay(hour: 9, minute: 0),
  );
  if (time == null) return null;
  final at = DateTime(date.year, date.month, date.day, time.hour, time.minute);
  if (!at.isAfter(now.add(const Duration(minutes: 1)))) {
    if (context.mounted) showAppToast(context, '1분 뒤 이후로 고르세요.');
    return null;
  }
  return at;
}

/// 원본 메시지가 있는 방을 연다 — 넓은 화면은 홈 화면이 펼치고(requestOpenRoom), 좁은 화면은 채팅 화면을 직접 띄운다
/// (알림 센터와 같은 방식 — notifications_panel.dart). 그 방에 더 이상 없으면 알린다.
void openReminderTarget(
  BuildContext context,
  Session session, {
  required String roomId,
  required String messageId,
}) {
  Room? room;
  for (final r in session.rooms) {
    if (r.id == roomId) room = r;
  }
  if (room == null) {
    showAppToast(context, '이 대화방에 더 이상 참여하고 있지 않습니다.');
    return;
  }
  if (MediaQuery.sizeOf(context).width >= wideBreakpoint) {
    session.requestOpenRoom(room, messageId: messageId);
  } else {
    session.requestOpenRoom(room);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          session: session,
          room: room!,
          highlightMessageId: messageId,
        ),
      ),
    );
  }
}

/// 리마인더가 울릴 때 "나와의 대화"에 올라오는 카드 — 원본의 보낸 사람·방·미리보기와 "메시지로 이동".
class ReminderCardView extends StatelessWidget {
  final Session session;
  final ReminderCard card;

  const ReminderCardView({
    super.key,
    required this.session,
    required this.card,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    Room? room;
    for (final r in session.rooms) {
      if (r.id == card.roomId) room = r;
    }
    final roomName =
        room?.displayName(session.userId ?? '') ?? card.roomName ?? '대화방';
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text('⏰', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 6),
              Text(
                '리마인더',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '$roomName · ${card.senderName ?? '알 수 없음'}'
            '${card.sentAt != null ? ' · ${reminderTimeLabel(card.sentAt!)}' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: hint),
          ),
          const SizedBox(height: 4),
          Text(
            card.secret ? '🔒 비밀 대화 메시지' : (card.preview ?? '메시지를 확인하세요'),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('reminder-open'),
            onPressed: () => openReminderTarget(
              context,
              session,
              roomId: card.roomId,
              messageId: card.messageId,
            ),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('메시지로 이동'),
          ),
        ],
      ),
    );
  }
}

/// 걸어 둔 리마인더 목록 — 울릴 시각 순, 각 줄에서 원본으로 이동하거나 취소한다. 다른 기기에서 걸거나 울리면 다시 받는다.
Future<void> showRemindersDialog(BuildContext context, Session session) =>
    showDialog<void>(
      context: context,
      builder: (_) => _RemindersDialog(session: session, hostContext: context),
    );

class _RemindersDialog extends StatefulWidget {
  final Session session;

  /// 대화상자를 띄운 화면 — 줄을 눌러 대화상자를 닫은 뒤 원본 방을 여는 데 쓴다(대화상자 자신의 context는 닫히면 못 쓴다).
  final BuildContext hostContext;
  const _RemindersDialog({required this.session, required this.hostContext});

  @override
  State<_RemindersDialog> createState() => _RemindersDialogState();
}

class _RemindersDialogState extends State<_RemindersDialog> {
  List<MessageReminder>? _items;
  String? _error;
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _load();
    _changes = widget.session.chatSocket.reminderChanges.listen((_) => _load());
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final items = await widget.session.api!.fetchReminders();
      if (mounted) {
        setState(() {
          _items = items;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _cancel(MessageReminder r) async {
    try {
      await widget.session.api!.deleteReminder(r.id);
      if (!mounted) return;
      setState(() => _items = _items?.where((x) => x.id != r.id).toList());
      showAppToast(context, '리마인더를 취소했습니다.');
    } catch (e) {
      if (mounted) showAppToast(context, '취소하지 못했습니다: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final items = _items;
    Widget body;
    if (_error != null) {
      body = Text(_error!);
    } else if (items == null) {
      body = const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else if (items.isEmpty) {
      body = Text(
        '걸어 둔 리마인더가 없습니다. 메시지 메뉴의 "나중에 알림"으로 걸 수 있습니다.',
        style: TextStyle(color: hint),
      );
    } else {
      body = ListView.separated(
        shrinkWrap: true,
        itemCount: items.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final r = items[i];
          Room? room;
          for (final x in widget.session.rooms) {
            if (x.id == r.roomId) room = x;
          }
          return ListTile(
            key: ValueKey('reminder-${r.id}'),
            contentPadding: EdgeInsets.zero,
            leading: const Text('⏰', style: TextStyle(fontSize: 20)),
            title: Text(
              r.preview ?? '🔒 비밀 대화 메시지',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${reminderTimeLabel(r.remindAt)} · '
              '${room?.displayName(widget.session.userId ?? '') ?? '대화방'}'
              '${r.senderName != null ? ' · ${r.senderName}' : ''}',
              style: theme.textTheme.bodySmall?.copyWith(color: hint),
            ),
            trailing: IconButton(
              tooltip: '취소',
              icon: const Icon(Icons.close),
              onPressed: () => _cancel(r),
            ),
            onTap: () {
              Navigator.of(context).pop();
              final host = widget.hostContext;
              if (!host.mounted) return;
              openReminderTarget(
                host,
                widget.session,
                roomId: r.roomId,
                messageId: r.messageId,
              );
            },
          );
        },
      );
    }
    return AlertDialog(
      title: const Text('리마인더'),
      content: SizedBox(width: 420, child: body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}
