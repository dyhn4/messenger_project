import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/room.dart';
import '../services/api_client.dart' show ApiException;
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/app_toast.dart';
import '../widgets/hover_toolbar.dart'
    show hoverMenuDivider, hoverMenuItem, hoverMenuStyle;
import '../widgets/muted_scrollbar.dart';
import '../widgets/room_avatar.dart';
import 'home_screen.dart' show wideBreakpoint;
import 'schedule_message_dialog.dart';

/// "메시지 예약" 목록을 연다 — 입력칸·보드 위의 "예약된 메시지 N개 · 보기"에서([room]을 주면 '이 대화방만'이
/// 켜진 채로). 넓은 창(PC)은 대화상자, 좁은 창(모바일)은 전체 화면. [메뉴]의 "메시지 예약"은 오른쪽 패널
/// (widgets/scheduled_panel.dart — side_panels.dart의 'scheduled')로 연다.
Future<void> showScheduledMessages(
  BuildContext context,
  Session session, {
  Room? room,
}) {
  final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  if (wide) {
    final height = MediaQuery.sizeOf(context).height;
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 580,
          height: math.min(720, height - 48),
          child: ScheduledMessagesScreen(
            session: session,
            room: room,
            asDialog: true,
          ),
        ),
      ),
    );
  }
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => ScheduledMessagesScreen(session: session, room: room),
    ),
  );
}

/// 내가 예약한 메시지 목록(지금 팀) — 맨 위에 "예약 N/30"과 "메시지 예약 생성", 그 아래 '발송 실패'(사유와
/// 함께, 수정해서 다시 예약하거나 삭제)와 '예약됨'(보낼 시각 순, ⋯로 수정·지금 보내기·예약 취소). 보내진
/// 예약은 목록에서 사라진다(알림은 루트 화면의 토스트가 한다).
class ScheduledMessagesScreen extends StatefulWidget {
  final Session session;

  /// 이 대화방에서 열었으면 그 방 — '이 대화방만' 칩이 켜진 채로 시작한다.
  final Room? room;
  final bool asDialog;

  const ScheduledMessagesScreen({
    super.key,
    required this.session,
    this.room,
    this.asDialog = false,
  });

  @override
  State<ScheduledMessagesScreen> createState() =>
      _ScheduledMessagesScreenState();
}

class _ScheduledMessagesScreenState extends State<ScheduledMessagesScreen> {
  late bool _onlyRoom = widget.room != null;
  final _scroll = ScrollController();
  bool _loading = true;
  Object? _loadError;

  Session get _session => widget.session;

  @override
  void initState() {
    super.initState();
    // 열 때마다 서버에서 새로 받는다(다른 기기에서 바꿨거나 알림을 놓쳤을 수 있다).
    unawaited(_fetch());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _retry() {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    unawaited(_fetch());
  }

  Future<void> _fetch() async {
    try {
      await _session.loadScheduledMessages();
    } catch (e) {
      if (!mounted) return;
      // 이미 받아 둔 목록이 있으면 그대로 보여주고 알리기만 한다.
      if (_session.scheduledMessagesLoaded) {
        showAppToast(context, '예약 목록을 새로 받지 못했습니다: $e');
      } else {
        setState(() => _loadError = e);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _atLimit =>
      _session.scheduledMessages.length >= scheduledMessageMaxCount;

  Future<void> _create() async {
    final room = widget.room;
    await showScheduleMessageEditor(
      context,
      _session,
      // '이 대화방만'을 보고 있으면 그 방으로 미리 골라 둔다.
      room: _onlyRoom && room != null && canScheduleIn(_session, room)
          ? room
          : null,
    );
  }

  Future<void> _edit(ScheduledMessage m) async {
    await showScheduleMessageEditor(context, _session, editing: m);
  }

  Future<bool> _confirm({
    required String title,
    required String content,
    required String action,
    bool destructive = false,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('닫기'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              action,
              style: destructive
                  ? const TextStyle(color: Colors.redAccent)
                  : null,
            ),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// 묻는 사이 목록에서 사라졌는지 — 예약 시각이 되어 보내졌거나(발송 알림은 루트 토스트가 띄운다)
  /// 다른 기기에서 취소했으면 더 할 일이 없다("찾을 수 없습니다" 오류를 띄우지 않게).
  bool _gone(ScheduledMessage m) =>
      _session.scheduledMessagesLoaded &&
      _session.scheduledMessageById(m.id) == null;

  Future<void> _sendNow(ScheduledMessage m) async {
    final room = _session.scheduledRoomName(m);
    final ok = await _confirm(
      title: '지금 보내기',
      content: "예약 시간을 기다리지 않고 '$room'에 지금 바로 보낼까요?",
      action: '보내기',
    );
    if (!ok || !mounted || _gone(m)) return;
    try {
      // 보내지면 루트 화면이 "예약 메시지를 보냈습니다" 토스트를 띄운다(여기서는 따로 알리지 않는다).
      await _session.sendScheduledMessageNow(m.id);
    } catch (e) {
      if (mounted) {
        showAppToast(
          context,
          e is ApiException ? e.message : '보내지 못했습니다: $e',
          duration: const Duration(seconds: 3),
        );
      }
    }
  }

  Future<void> _cancel(ScheduledMessage m, {required bool failed}) async {
    final ok = await _confirm(
      title: failed ? '예약 메시지 삭제' : '예약 취소',
      content: failed
          ? '보내지 못한 예약 메시지를 삭제할까요?'
          : '${formatScheduleTime(m.sendAt)}에 보낼 예약을 취소할까요? 취소한 예약은 되돌릴 수 없습니다.',
      action: failed ? '삭제' : '예약 취소',
      destructive: true,
    );
    if (!ok || !mounted || _gone(m)) return;
    try {
      await _session.cancelScheduledMessage(m.id);
      if (mounted) {
        showAppToast(context, failed ? '예약 메시지를 삭제했습니다.' : '예약을 취소했습니다.');
      }
    } catch (e) {
      if (mounted) {
        showAppToast(context, e is ApiException ? e.message : '취소하지 못했습니다: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = ListenableBuilder(
      listenable: _session,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildToolbar(context),
          const Divider(height: 1),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
    if (!widget.asDialog) {
      return Scaffold(
        appBar: AppBar(title: const Text('메시지 예약')),
        body: SafeArea(child: body),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '메시지 예약',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: '닫기',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Expanded(child: body),
      ],
    );
  }

  /// "예약 N/30" + "메시지 예약 생성", 방에서 열었으면 '이 대화방만' 칩.
  Widget _buildToolbar(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final count = _session.scheduledMessages.length;
    final room = widget.room;
    final createButton = FilledButton.icon(
      key: const ValueKey('scheduled-create'),
      onPressed: _atLimit ? null : _create,
      icon: const Icon(Icons.add, size: 18),
      label: const Text('메시지 예약 생성'),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(widget.asDialog ? 20 : 16, 8, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: '예약 '),
                    TextSpan(
                      text: '$count',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: _atLimit
                            ? theme.colorScheme.error
                            : theme.colorScheme.primary,
                      ),
                    ),
                    TextSpan(
                      text: '/$scheduledMessageMaxCount',
                      style: TextStyle(color: hint),
                    ),
                  ],
                ),
                key: const ValueKey('scheduled-count'),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (_atLimit)
                Tooltip(
                  message: '예약 메시지는 최대 $scheduledMessageMaxCount건까지 만들 수 있습니다.',
                  child: createButton,
                )
              else
                createButton,
            ],
          ),
          if (room != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                FilterChip(
                  key: const ValueKey('scheduled-only-room'),
                  label: const Text('이 대화방만'),
                  selected: _onlyRoom,
                  visualDensity: VisualDensity.compact,
                  onSelected: (v) => setState(() => _onlyRoom = v),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    room.displayName(_session.userId ?? ''),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: hint),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (!_session.scheduledMessagesLoaded) {
      if (_loadError != null && !_loading) {
        return _ErrorState(message: '예약 목록을 불러오지 못했습니다.', onRetry: _retry);
      }
      return const Center(child: CircularProgressIndicator());
    }
    final room = widget.room;
    final all = _onlyRoom && room != null
        ? _session.scheduledMessagesFor(room.id)
        : _session.scheduledMessages;
    final failed = [
      for (final m in all)
        if (m.isFailed) m,
    ];
    final scheduled = [
      for (final m in all)
        if (!m.isFailed) m,
    ];
    if (all.isEmpty) {
      return _EmptyState(
        filtered: _onlyRoom && room != null,
        canCreate: !_atLimit,
        onCreate: _create,
      );
    }
    final pad = widget.asDialog ? 20.0 : 16.0;
    final list = ListView(
      controller: _scroll,
      padding: EdgeInsets.fromLTRB(pad, 12, pad, 20),
      children: [
        if (failed.isNotEmpty) ...[
          _SectionHeader(
            key: const ValueKey('scheduled-failed-header'),
            icon: Icons.error_outline,
            label: '발송 실패',
            count: failed.length,
            danger: true,
          ),
          for (final m in failed)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ScheduledCard(
                key: ValueKey('scheduled-${m.id}'),
                session: _session,
                message: m,
                onEdit: () => _edit(m),
                onSendNow: () => _sendNow(m),
                onCancel: () => _cancel(m, failed: true),
              ),
            ),
          const SizedBox(height: 10),
        ],
        _SectionHeader(
          key: const ValueKey('scheduled-header'),
          icon: Icons.schedule_send_outlined,
          label: '예약됨',
          count: scheduled.length,
        ),
        if (scheduled.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '보낼 차례를 기다리는 예약이 없습니다.',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).hintColor,
              ),
            ),
          ),
        for (final m in scheduled)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _ScheduledCard(
              key: ValueKey('scheduled-${m.id}'),
              session: _session,
              message: m,
              onEdit: () => _edit(m),
              onSendNow: () => _sendNow(m),
              onCancel: () => _cancel(m, failed: false),
            ),
          ),
      ],
    );
    return widget.asDialog
        ? MutedScrollbar(controller: _scroll, child: list)
        : list;
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;
  final bool danger;
  const _SectionHeader({
    super.key,
    required this.icon,
    required this.label,
    required this.count,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = danger ? theme.colorScheme.error : theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 0, 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: danger ? color : null,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// 예약 한 건 — 대화방(아이콘·이름), 보낼 시각, 두 줄 미리보기(게시글이면 제목), 첨부 수. 발송 실패면
/// 빨간 테두리와 사유, 수정·삭제 단추를 붙인다. 예약됨은 ⋯로 수정·지금 보내기·예약 취소.
class _ScheduledCard extends StatelessWidget {
  final Session session;
  final ScheduledMessage message;
  final VoidCallback onEdit;
  final VoidCallback onSendNow;
  final VoidCallback onCancel;
  const _ScheduledCard({
    super.key,
    required this.session,
    required this.message,
    required this.onEdit,
    required this.onSendNow,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hint = theme.hintColor;
    final m = message;
    final failed = m.isFailed;
    final sending = m.isSending;
    final dark = theme.brightness == Brightness.dark;
    final cardColor = failed
        ? Color.alphaBlend(
            scheme.error.withValues(alpha: dark ? 0.10 : 0.05),
            scheme.surface,
          )
        : dark
        ? scheme.surfaceContainer
        : scheme.surfaceContainerLowest;
    final border = failed
        ? scheme.error.withValues(alpha: 0.55)
        : dark
        ? theme.dividerColor
        : const Color(0xFFE6E8EC);
    final attachments = m.attachments.length;
    return Material(
      color: cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: sending ? null : onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _RoomIcon(session: session, message: m),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.scheduledRoomName(m),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 10,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _Meta(
                          icon: Icons.schedule,
                          text: formatScheduleTime(m.sendAt),
                          color: failed ? hint : scheme.primary,
                          strong: !failed,
                        ),
                        if (attachments > 0)
                          _Meta(
                            icon: Icons.attach_file,
                            text: '파일 $attachments개',
                            color: hint,
                          ),
                      ],
                    ),
                    if (failed) ...[
                      const SizedBox(height: 6),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Icon(
                              Icons.error_outline,
                              size: 15,
                              color: scheme.error,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              m.failReason ?? '보내지 못했습니다.',
                              key: ValueKey('scheduled-reason-${m.id}'),
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: scheme.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 6),
                    _Preview(message: m),
                    if (failed) ...[
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            key: ValueKey('scheduled-delete-${m.id}'),
                            onPressed: onCancel,
                            style: TextButton.styleFrom(
                              foregroundColor: hint,
                              visualDensity: VisualDensity.compact,
                            ),
                            child: const Text('삭제'),
                          ),
                          const SizedBox(width: 4),
                          FilledButton.tonalIcon(
                            key: ValueKey('scheduled-edit-${m.id}'),
                            onPressed: onEdit,
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            icon: const Icon(Icons.edit_calendar, size: 16),
                            label: const Text('수정'),
                          ),
                          const SizedBox(width: 8),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (!failed)
                sending
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(8, 10, 10, 0),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '보내는 중',
                              style: TextStyle(fontSize: 12, color: hint),
                            ),
                          ],
                        ),
                      )
                    : _MoreButton(
                        messageId: m.id,
                        onEdit: onEdit,
                        onSendNow: onSendNow,
                        onCancel: onCancel,
                      ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  final bool strong;
  const _Meta({
    required this.icon,
    required this.text,
    required this.color,
    this.strong = false,
  });

  @override
  Widget build(BuildContext context) {
    // 좁은 화면에서 해를 넘긴 긴 날짜("2027년 1월 4일 (월) 오전 9:00")도 카드 밖으로 넘치지 않게.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: strong ? FontWeight.w600 : FontWeight.normal,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}

/// 두 줄 미리보기 — 게시글 예약은 "게시글" 표시 + 제목, 그 밖엔 메시지.
class _Preview extends StatelessWidget {
  final ScheduledMessage message;
  const _Preview({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurface.withValues(alpha: 0.8);
    final text = message.preview.trim().replaceAll(RegExp(r'\s*\n\s*'), ' ');
    return Text.rich(
      TextSpan(
        children: [
          if (message.isPost)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Container(
                margin: const EdgeInsets.only(right: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '게시글',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
          TextSpan(
            text: text,
            style: message.isPost
                ? const TextStyle(fontWeight: FontWeight.w600)
                : null,
          ),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 13.5, height: 1.45, color: color),
    );
  }
}

/// 예약됨 카드의 ⋯ — 수정 / 지금 보내기 / 예약 취소.
class _MoreButton extends StatelessWidget {
  final String messageId;
  final VoidCallback onEdit;
  final VoidCallback onSendNow;
  final VoidCallback onCancel;
  const _MoreButton({
    required this.messageId,
    required this.onEdit,
    required this.onSendNow,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      style: hoverMenuStyle(context),
      menuChildren: [
        hoverMenuItem(
          icon: Icons.edit_outlined,
          label: '수정',
          onPressed: onEdit,
        ),
        hoverMenuItem(
          icon: Icons.send_outlined,
          label: '지금 보내기',
          onPressed: onSendNow,
        ),
        hoverMenuDivider(),
        hoverMenuItem(
          icon: Icons.event_busy_outlined,
          label: '예약 취소',
          color: Colors.redAccent,
          onPressed: onCancel,
        ),
      ],
      builder: (context, controller, _) => IconButton(
        key: ValueKey('scheduled-more-$messageId'),
        icon: const Icon(Icons.more_horiz),
        tooltip: '더보기',
        visualDensity: VisualDensity.compact,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// 예약이 갈 대화방의 아이콘 — 토픽은 # (보드는 보드 모양) 네모, 채팅·그룹은 방 아바타(나와의 대화는 내
/// 아바타), 내 목록에 없는 방(나갔거나 삭제됨)은 회색 말풍선.
class _RoomIcon extends StatelessWidget {
  final Session session;
  final ScheduledMessage message;
  const _RoomIcon({required this.session, required this.message});

  static const _size = 36.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final roomId = message.roomId;
    final room = roomId == null ? null : session.roomById(roomId);
    if (room == null) {
      return Container(
        width: _size,
        height: _size,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.speaker_notes_off_outlined,
          size: 18,
          color: scheme.onSurfaceVariant,
        ),
      );
    }
    if (room.type == RoomType.topic) {
      return Container(
        width: _size,
        height: _size,
        decoration: BoxDecoration(
          color: scheme.primaryContainer.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          room.isBoard ? Icons.dashboard_outlined : Icons.tag,
          size: 19,
          color: scheme.onPrimaryContainer,
        ),
      );
    }
    return SizedBox(
      width: _size,
      height: _size,
      child: Center(
        child: RoomAvatar(
          room: room,
          myUserId: session.userId ?? '',
          resolveUrl: session.resolveUrl,
          onlineUserIds: const <String>{},
          size: _size,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool filtered;
  final bool canCreate;
  final VoidCallback onCreate;
  const _EmptyState({
    required this.filtered,
    required this.canCreate,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: primary.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.schedule_send_outlined,
                size: 38,
                color: primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              filtered ? '이 대화방에 예약된 메시지가 없습니다.' : '예약된 메시지가 없습니다.',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '원하는 시간에 보낼 메시지를 미리 써 두세요.\n15분 단위로 최대 $scheduledMaxDaysAhead일 뒤까지 예약할 수 있어요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.hintColor, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 40, color: theme.hintColor),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '연결 상태를 확인한 뒤 다시 시도해 주세요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.hintColor),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('다시 시도'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 입력칸 위·보드 아래의 얇은 줄 "예약된 메시지 N개 · 보기"(보드면 "예약된 게시글") — 이 방에 내 예약이
/// 있을 때만 보이고(발송 실패도 따로 센다), 누르면 이 대화방만 걸러 둔 예약 목록을 연다. 세션 알림마다
/// 전체를 다시 그리지 않도록 개수가 바뀔 때만 다시 그린다(입력 중 불필요한 다시 그리기를 줄이려고).
class ScheduledRoomBar extends StatefulWidget {
  final Session session;
  final Room room;
  final EdgeInsetsGeometry padding;
  const ScheduledRoomBar({
    super.key,
    required this.session,
    required this.room,
    this.padding = EdgeInsets.zero,
  });

  @override
  State<ScheduledRoomBar> createState() => _ScheduledRoomBarState();
}

class _ScheduledRoomBarState extends State<ScheduledRoomBar> {
  late (int, int) _counts = _read();

  (int, int) _read() {
    final s = widget.session;
    final scheduled = s.scheduledCountFor(widget.room.id);
    final all = s.scheduledCountFor(widget.room.id, includeFailed: true);
    return (scheduled, all - scheduled);
  }

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSessionChanged);
  }

  @override
  void didUpdateWidget(covariant ScheduledRoomBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      oldWidget.session.removeListener(_onSessionChanged);
      widget.session.addListener(_onSessionChanged);
    }
    _counts = _read();
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    if (!mounted) return;
    final next = _read();
    if (next != _counts) setState(() => _counts = next);
  }

  @override
  Widget build(BuildContext context) {
    final (scheduled, failed) = _counts;
    if (scheduled == 0 && failed == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final noun = widget.room.isBoard ? '게시글' : '메시지';
    return Padding(
      padding: widget.padding,
      child: Material(
        color: scheme.primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          key: const ValueKey('scheduled-room-bar'),
          borderRadius: BorderRadius.circular(8),
          onTap: () =>
              showScheduledMessages(context, widget.session, room: widget.room),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
            child: Row(
              children: [
                Icon(
                  Icons.schedule_send_outlined,
                  size: 16,
                  color: scheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        if (scheduled > 0)
                          TextSpan(text: '예약된 $noun $scheduled개'),
                        if (scheduled > 0 && failed > 0)
                          const TextSpan(text: ' · '),
                        if (failed > 0)
                          TextSpan(
                            text: '발송 실패 $failed개',
                            style: TextStyle(
                              color: scheme.error,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        const TextSpan(text: ' · '),
                        TextSpan(
                          text: '보기',
                          style: TextStyle(
                            color: scheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: scheme.onSurface.withValues(alpha: 0.85),
                    ),
                  ),
                ),
                Icon(Icons.chevron_right, size: 18, color: scheme.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 앱 전체에 한 번 붙이는(main.dart) 예약 메시지 발송 결과 알림 — 예약 시각에 보내졌거나 못 보냈을 때
/// (그리고 "지금 보내기" 성공) 어느 화면에 있든 토스트로 알린다. 여러 건이 한꺼번에 오면 겹치지 않게
/// 차례로 띄우고, 같은 결과(같은 방·같은 사유)는 한 번에 묶는다. [child]는 Navigator 안(첫 화면)에
/// 있어야 토스트가 다른 화면·대화상자 위에 뜬다.
class ScheduledMessageToasts extends StatefulWidget {
  final Session session;
  final Widget child;
  const ScheduledMessageToasts({
    super.key,
    required this.session,
    required this.child,
  });

  @override
  State<ScheduledMessageToasts> createState() => _ScheduledMessageToastsState();
}

class _ScheduledMessageToastsState extends State<ScheduledMessageToasts> {
  StreamSubscription<ScheduledMessageEvent>? _sub;
  final _queue = Queue<ScheduledMessageEvent>();
  Timer? _next;

  @override
  void initState() {
    super.initState();
    _sub = widget.session.scheduledMessageEvents.listen(_onEvent);
  }

  @override
  void didUpdateWidget(covariant ScheduledMessageToasts oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      _sub?.cancel();
      _sub = widget.session.scheduledMessageEvents.listen(_onEvent);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _next?.cancel();
    super.dispose();
  }

  /// 첫 알림을 띄우기 전에 잠깐 모은다 — 토픽 보관·방 삭제면 서버가 그 방 예약마다 실패를 잇달아
  /// 보내는데, 하나씩 띄우면 같은 알림이 몇 분씩 이어진다.
  static const _gather = Duration(milliseconds: 250);

  void _onEvent(ScheduledMessageEvent event) {
    _queue.add(event);
    _next ??= Timer(_gather, _showNext);
  }

  /// 한 알림으로 묶어도 되는지 — 같은 팀·같은 방의 같은 결과(같은 사유)일 때만.
  static bool _sameResult(ScheduledMessageEvent a, ScheduledMessageEvent b) =>
      a.type == b.type &&
      a.teamId == b.teamId &&
      a.roomId == b.roomId &&
      a.toastText == b.toastText;

  void _showNext() {
    _next = null;
    if (!mounted || _queue.isEmpty) return;
    final event = _queue.removeFirst();
    // 바로 뒤에 같은 결과(같은 방·같은 사유)가 이어져 있으면 몇 건이든 알림 하나로 묶는다.
    var count = 1;
    while (_queue.isNotEmpty && _sameResult(_queue.first, event)) {
      _queue.removeFirst();
      count++;
    }
    // 실패는 사유까지 읽을 수 있게 조금 더 오래 둔다.
    final duration = event.isFailed
        ? const Duration(milliseconds: 4500)
        : const Duration(milliseconds: 2500);
    showAppToast(context, event.toastTextFor(count), duration: duration);
    _next = Timer(duration + const Duration(milliseconds: 150), _showNext);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
