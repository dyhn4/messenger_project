import 'dart:async';

import 'package:flutter/material.dart';

import '../models/message.dart';
import '../models/message_reminder.dart';
import '../models/room.dart';
import '../screens/chat_screen.dart';
import '../screens/home_screen.dart' show wideBreakpoint;
import '../services/session.dart';
import 'app_toast.dart';
import 'date_time_range_field.dart' show DateTimePointPanel;
import '../l10n/tr.dart';

/// 메시지 리마인더("나중에 알림") — 메시지 메뉴의 고르는 창([showReminderPicker]), 울렸을 때 "나와의 대화"에 올라오는 카드
/// ([ReminderCardView]). 걸어 둔 리마인더 목록과 직접 만드는 리마인더는 리마인더 패널(reminders_panel.dart). 서버는
/// server/src/reminders.js.

/// 이 메시지에 리마인더를 걸 수 있는지 — 지운 메시지·시스템 메시지·댓글 항목은 안 된다(서버도 같은 규칙).
bool canRemindMessage(Message message) =>
    !message.deleted &&
    message.asComment == null &&
    message.type != MessageType.system;

/// "10/15(수) 09:00" — 리마인더 시각 표기.
String reminderTimeLabel(DateTime at) {
  final days = [tr('월'), tr('화'), tr('수'), tr('목'), tr('금'), tr('토'), tr('일')];
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
  final picked = await showDialog<DateTime>(
    context: context,
    builder: (_) => const _ReminderPickerDialog(),
  );
  if (picked == null || !context.mounted) return;
  try {
    await session.api!.createMessageReminder(message.id, picked);
    if (context.mounted) {
      showAppToast(
        context,
        tr('{p0}에 알려 드릴게요.', {'p0': reminderTimeLabel(picked)}),
      );
    }
  } catch (e) {
    if (context.mounted) {
      showAppToast(context, tr('리마인더를 걸지 못했습니다: {e}', {'e': e}));
    }
  }
}

/// 직접 고를 수 있는 가장 먼 날 — 지금부터 364일 뒤까지.
const _reminderMaxAhead = Duration(days: 364);

/// "나중에 알림" 창 — 빠른 선택지는 누르면 바로 그 시각으로 닫히고, "날짜·시간 직접 고르기"는 아래에 달력과 시간 칸
/// ([DateTimePointPanel] — 방해 금지 "지정"·할 일 기간과 같은 모양)을 펼쳐 고른 뒤 [이 시각에 알림]으로 닫는다.
/// 고른 시각을 돌려준다(닫으면 null).
class _ReminderPickerDialog extends StatefulWidget {
  const _ReminderPickerDialog();

  @override
  State<_ReminderPickerDialog> createState() => _ReminderPickerDialogState();
}

class _ReminderPickerDialogState extends State<_ReminderPickerDialog> {
  /// 창을 연 시각 — 빠른 선택지는 이 기준이다.
  final _now = DateTime.now();

  /// 직접 고르는 판을 펼쳤으면 그 시각(처음은 한 시간 뒤를 15분 단위로 올린 시각), 접었으면 null.
  DateTime? _custom;

  void _toggleCustom() {
    if (_custom != null) {
      setState(() => _custom = null);
      return;
    }
    final base = DateTime.now().add(const Duration(hours: 1));
    final slot = (base.hour * 60 + base.minute + 14) ~/ 15 * 15;
    setState(
      () => _custom = DateTime(base.year, base.month, base.day, 0, slot),
    );
  }

  /// 고른 시각으로 걸 수 없는 까닭(1분 뒤보다 이르거나 너무 멂), 걸 수 있으면 null.
  String? _customProblem(DateTime now) {
    final at = _custom;
    if (at == null || !at.isAfter(now.add(const Duration(minutes: 1)))) {
      return tr('1분 뒤 이후로 고르세요.');
    }
    if (at.isAfter(now.add(_reminderMaxAhead))) return tr('1년 안으로 고르세요.');
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final custom = _custom;
    final problem = custom == null ? null : _customProblem(DateTime.now());
    return SimpleDialog(
      title: Text(tr('나중에 알림')),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(
            tr('정한 시각에 "나와의 대화"로 이 메시지를 다시 알려 드립니다.'),
            style: theme.textTheme.bodySmall?.copyWith(color: hint),
          ),
        ),
        for (final p in reminderPresets(_now))
          SimpleDialogOption(
            key: ValueKey('reminder-preset-${p.label}'),
            onPressed: () => Navigator.of(context).pop(p.at),
            child: Row(
              children: [
                Expanded(child: Text(p.label)),
                Text(
                  reminderTimeLabel(p.at),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              ],
            ),
          ),
        SimpleDialogOption(
          key: const ValueKey('reminder-custom'),
          onPressed: _toggleCustom,
          child: Row(
            children: [
              Expanded(child: Text(tr('날짜·시간 직접 고르기'))),
              if (custom != null)
                Text(
                  reminderTimeLabel(custom),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              Icon(
                custom == null ? Icons.expand_more : Icons.expand_less,
                size: 20,
                color: hint,
              ),
            ],
          ),
        ),
        if (custom != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    key: const ValueKey('reminder-custom-panel'),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: DateTimePointPanel(
                      keyPrefix: 'reminder',
                      value: custom,
                      caption: tr('언제 다시 알려 드릴까요?'),
                      timeLabel: tr('알림 시간'),
                      firstDay: DateTime.now(),
                      lastDay: DateTime.now().add(_reminderMaxAhead),
                      onChanged: (v) => setState(() => _custom = v),
                    ),
                  ),
                ),
                if (problem != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      problem,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 10),
                FilledButton(
                  key: const ValueKey('reminder-custom-confirm'),
                  onPressed: problem != null
                      ? null
                      : () => Navigator.of(context).pop(custom),
                  child: Text(tr('이 시각에 알림')),
                ),
              ],
            ),
          ),
      ],
    );
  }
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
    showAppToast(context, tr('이 대화방에 더 이상 참여하고 있지 않습니다.'));
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
        room?.displayName(session.userId ?? '') ?? card.roomName ?? tr('대화방');
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
                tr('리마인더'),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '$roomName · ${card.senderName ?? tr('알 수 없음')}'
            '${card.sentAt != null ? ' · ${reminderTimeLabel(card.sentAt!)}' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: hint),
          ),
          const SizedBox(height: 4),
          Text(
            card.secret
                ? tr('🔒 비밀 대화 메시지')
                : (card.preview ?? tr('메시지를 확인하세요')),
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
            label: Text(tr('메시지로 이동')),
          ),
        ],
      ),
    );
  }
}
