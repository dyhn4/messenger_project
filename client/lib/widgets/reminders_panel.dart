import 'dart:async';

import 'package:flutter/material.dart';

import '../models/message_reminder.dart';
import '../models/room.dart';
import '../services/session.dart';
import 'app_toast.dart';
import 'date_time_range_field.dart' show DateTimePointPanel;
import 'filter_dropdown.dart' show iconForRoomType;
import 'home_shell_scope.dart' show openRoomFromPanel;
import 'message_reminders.dart' show reminderTimeLabel;
import 'todos_panel.dart'
    show
        todoCardColor,
        todoCardHoverBorder,
        todoCardPressColor,
        todoListBackgroundColor;
import '../l10n/tr.dart';

/// 리마인더 패널(side_panels.dart의 'reminders' — 메뉴 "생성"의 리마인더, 계정 메뉴의 리마인더) — 할 일 패널과 같은 모양이다.
/// 위에서부터 머리(`리마인더`, 오른쪽 끝 ✕), 가로 전체 `+ 리마인더 생성`(직접 만드는 창 — [showCreateReminderDialog]), 그 아래
/// 옅은 회색 바탕에 `N개의 리마인더`와 아직 울리지 않은 리마인더 카드(울릴 시각 순)다. 카드는 두 가지다.
/// - 직접 만든 리마인더: 울릴 시각과 글.
/// - 메시지 리마인더("나중에 알림"): 울릴 시각, 원본 미리보기, 대화방·보낸 사람 — 누르면 그 메시지로 간다.
/// 카드 오른쪽 위 ✕로 취소한다. 다른 기기에서 걸거나 울리면(reminder:changed) 조용히 다시 받는다.
class RemindersPanel extends StatefulWidget {
  final Session session;
  final VoidCallback? onClose;

  const RemindersPanel({super.key, required this.session, this.onClose});

  @override
  State<RemindersPanel> createState() => _RemindersPanelState();
}

class _RemindersPanelState extends State<RemindersPanel> {
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
      if (mounted) {
        setState(() => _error = tr('리마인더를 불러오지 못했습니다: {e}', {'e': e}));
      }
    }
  }

  Future<void> _create() async {
    final created = await showCreateReminderDialog(context, widget.session);
    if (created != null) await _load();
  }

  Future<void> _cancel(MessageReminder r) async {
    try {
      await widget.session.api!.deleteReminder(r.id);
      if (!mounted) return;
      setState(() => _items = _items?.where((x) => x.id != r.id).toList());
      showAppToast(context, tr('리마인더를 취소했습니다.'));
    } catch (e) {
      if (mounted) showAppToast(context, tr('취소하지 못했습니다: {e}', {'e': e}));
    }
  }

  /// 메시지 리마인더를 누르면 원본으로 — PC는 가운데 채팅이 바뀌고, 모바일은 채팅 화면이 위에 얹힌다. 그 방에 더 이상 없으면
  /// 알린다.
  void _openMessage(MessageReminder r) {
    final room = r.roomId == null ? null : widget.session.roomById(r.roomId!);
    if (room == null) {
      showAppToast(context, tr('이 대화방에 더 이상 참여하고 있지 않습니다.'));
      return;
    }
    openRoomFromPanel(context, widget.session, room, messageId: r.messageId);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context),
          const Divider(height: 1),
          _createButton(context),
          const SizedBox(height: 12),
          Expanded(
            child: ColoredBox(
              color: todoListBackgroundColor(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _countLine(context),
                  Expanded(child: _content(context)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 머리 — `리마인더`, 오른쪽 끝 ✕(패널 닫기). 높이는 할 일 패널 머리와 같다.
  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              tr('리마인더'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          IconButton(
            key: const ValueKey('reminder-panel-close'),
            icon: const Icon(Icons.close),
            tooltip: tr('닫기'),
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  /// 가로 전체 `+ 리마인더 생성` — 할 일 패널의 `+ 할 일 생성`과 같은 옅은 회색 둥근 단추.
  Widget _createButton(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: FilledButton.icon(
        key: const ValueKey('reminder-create'),
        onPressed: _create,
        style: FilledButton.styleFrom(
          backgroundColor: scheme.surfaceContainerHighest,
          foregroundColor: scheme.onSurface,
          minimumSize: const Size.fromHeight(44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: theme.textTheme.labelLarge?.copyWith(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        icon: const Icon(Icons.add, size: 20),
        label: Text(
          tr('리마인더 생성'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// `N개의 리마인더` — 받기 전에는 같은 높이의 빈 줄(목록이 밀리지 않게).
  Widget _countLine(BuildContext context) {
    final theme = Theme.of(context);
    const bold = TextStyle(fontWeight: FontWeight.w700);
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurface,
    );
    final items = _items;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Text.rich(
        key: ValueKey(
          items == null ? 'reminder-count-pending' : 'reminder-count',
        ),
        TextSpan(
          children: items == null
              ? const [TextSpan(text: ' ', style: bold)]
              : [
                  TextSpan(text: '${items.length}', style: bold),
                  TextSpan(text: tr('개의 리마인더')),
                ],
        ),
        style: style,
      ),
    );
  }

  Widget _content(BuildContext context) {
    final items = _items;
    if (items == null) {
      if (_error != null) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: _load, child: Text(tr('다시 시도'))),
            ],
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    if (items.isEmpty) return _empty(context);
    return ListView.separated(
      key: const ValueKey('reminder-list'),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      itemCount: items.length,
      separatorBuilder: (context, i) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final r = items[i];
        return _ReminderCard(
          key: ValueKey('reminder-${r.id}'),
          session: widget.session,
          reminder: r,
          onTap: r.isMemo ? null : () => _openMessage(r),
          onCancel: () => _cancel(r),
        );
      },
    );
  }

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.alarm_rounded, size: 40, color: theme.hintColor),
            const SizedBox(height: 12),
            Text(
              tr('걸어 둔 리마인더가 없어요.'),
              key: const ValueKey('reminder-empty'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 4),
            Text(
              tr('"리마인더 생성"으로 직접 만들거나, 메시지 메뉴의 "나중에 알림"으로 걸 수 있어요.'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 리마인더 카드(할 일 카드와 같은 틀 — 흰 둥근 카드, 마우스를 올리면 테두리가 주 색) — 첫 줄 ⏰ 울릴 시각(굵게)과 종류
/// (`직접 만든 리마인더`/`메시지`), 굵은 글(직접 만든 것은 그 글, 메시지는 원본 미리보기 — 두 줄까지), 메시지면 대화방·보낸
/// 사람 한 줄(작게). 오른쪽 위 ✕는 취소. [onTap]이 있으면(메시지) 눌러 원본으로 간다.
class _ReminderCard extends StatefulWidget {
  final Session session;
  final MessageReminder reminder;
  final VoidCallback? onTap;
  final VoidCallback onCancel;

  const _ReminderCard({
    super.key,
    required this.session,
    required this.reminder,
    required this.onTap,
    required this.onCancel,
  });

  @override
  State<_ReminderCard> createState() => _ReminderCardState();
}

class _ReminderCardState extends State<_ReminderCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hint = theme.hintColor;
    final r = widget.reminder;
    final title = r.isMemo ? (r.text ?? '') : (r.preview ?? tr('🔒 비밀 대화 메시지'));
    final info = _infoLine(context);
    return Material(
      color: todoCardColor(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: _hovered ? todoCardHoverBorder(context) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
        onHover: (v) {
          if (v != _hovered) setState(() => _hovered = v);
        },
        hoverColor: Colors.transparent,
        highlightColor: todoCardPressColor(context),
        splashColor: todoCardPressColor(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 6, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.alarm_rounded, size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    reminderTimeLabel(r.remindAt),
                    key: ValueKey('reminder-time-${r.id}'),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      r.isMemo ? tr('직접 만든 리마인더') : tr('메시지'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: hint),
                    ),
                  ),
                  IconButton(
                    key: ValueKey('reminder-cancel-${r.id}'),
                    tooltip: tr('리마인더 취소'),
                    icon: Icon(Icons.close, size: 18, color: hint),
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.onCancel,
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Text(
                  title,
                  key: ValueKey('reminder-title-${r.id}'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              if (info != null) ...[const SizedBox(height: 8), info],
            ],
          ),
        ),
      ),
    );
  }

  /// 작은 회색 한 줄 — 메시지면 대화방(종류 아이콘 + 이름) · 보낸 사람, 직접 만든 것이 다른 팀의 것이면 그 팀(울릴 때 그 팀의
  /// "나와의 대화"에 올라온다). 보일 게 없으면 null.
  Widget? _infoLine(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final style = TextStyle(fontSize: 12, color: hint);
    final session = widget.session;
    final r = widget.reminder;
    if (r.isMemo) {
      if (r.teamId == null || r.teamId == session.currentTeam?.id) return null;
      final team = session.teams.where((t) => t.id == r.teamId).firstOrNull;
      if (team == null) return null;
      return Text(
        tr('{team.name}의 나와의 대화로 알림', {'team.name': team.name}),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    final room = r.roomId == null ? null : session.roomById(r.roomId!);
    final roomName = room?.displayName(session.userId ?? '') ?? tr('대화방');
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Row(
        children: [
          Icon(
            iconForRoomType(room?.type ?? RoomType.topic),
            size: 13,
            color: hint,
          ),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              roomName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          if (r.senderName != null) Text(' · ${r.senderName}', style: style),
        ],
      ),
    );
  }
}

/// 직접 만든 리마인더 글의 최대 길이(서버 reminderRules.js REMINDER_TEXT_MAX와 같다).
const reminderTextMax = 200;

/// "지정"으로 고를 수 있는 가장 먼 날 — 서버 한도(1년)보다 하루 짧게.
const _customMaxAhead = Duration(days: 364);

/// 리마인더 생성 창 — 알려 줄 글, 언제(20분 뒤 · 1시간 뒤 · 3시간 뒤 · 내일 오전 9시 · 다음 주 월요일 오전 9시 · 지정 —
/// 지정을 고르면 아래에 달력·시간 칸이 펼쳐진다), 그리고 [생성]. 정한 시각에 지금 팀의 "나와의 대화"로 알려 준다. 만든
/// 리마인더를 돌려준다(취소하면 null).
Future<MessageReminder?> showCreateReminderDialog(
  BuildContext context,
  Session session,
) => showDialog<MessageReminder>(
  context: context,
  builder: (_) => _CreateReminderDialog(session: session),
);

/// 빠른 선택지 — [now] 기준 시각(메시지의 "나중에 알림"과 같다).
final List<({String label, DateTime Function(DateTime now) at})> _presets = [
  (label: tr('20분 뒤'), at: (n) => n.add(const Duration(minutes: 20))),
  (label: tr('1시간 뒤'), at: (n) => n.add(const Duration(hours: 1))),
  (label: tr('3시간 뒤'), at: (n) => n.add(const Duration(hours: 3))),
  (label: tr('내일 오전 9시'), at: (n) => DateTime(n.year, n.month, n.day + 1, 9)),
  (
    label: tr('다음 주 월요일 오전 9시'),
    at: (n) => DateTime(n.year, n.month, n.day + 8 - n.weekday, 9),
  ),
];

class _CreateReminderDialog extends StatefulWidget {
  final Session session;
  const _CreateReminderDialog({required this.session});

  @override
  State<_CreateReminderDialog> createState() => _CreateReminderDialogState();
}

class _CreateReminderDialogState extends State<_CreateReminderDialog> {
  final _text = TextEditingController();

  /// 고른 빠른 선택지(이름) — 'custom'이면 [_custom]. 처음은 1시간 뒤.
  String _choice = tr('1시간 뒤');

  /// "지정"으로 고른 시각(처음 지정을 누를 때 한 시간 뒤를 15분 단위로 올린 시각으로 채운다).
  DateTime? _custom;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _text.removeListener(_onTextChanged);
    _text.dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  void _pickCustom() {
    if (_custom == null) {
      final base = DateTime.now().add(const Duration(hours: 1));
      final slot = (base.hour * 60 + base.minute + 14) ~/ 15 * 15;
      _custom = DateTime(base.year, base.month, base.day, 0, slot);
    }
    setState(() => _choice = 'custom');
  }

  /// 지금 고른 시각 — 빠른 선택지는 [now] 기준으로 센다(창을 오래 열어 둬도 "20분 뒤"가 지금부터 20분 뒤가 되게).
  DateTime? _at(DateTime now) {
    if (_choice == 'custom') return _custom;
    for (final p in _presets) {
      if (p.label == _choice) return p.at(now);
    }
    return null;
  }

  /// 고른 시각으로 걸 수 없는 까닭(1분 뒤보다 이르거나 너무 멂), 걸 수 있으면 null.
  String? _timeProblem(DateTime now) {
    final at = _at(now);
    if (at == null || !at.isAfter(now.add(const Duration(minutes: 1)))) {
      return tr('1분 뒤 이후로 고르세요.');
    }
    if (at.isAfter(now.add(_customMaxAhead))) return tr('1년 안으로 고르세요.');
    return null;
  }

  Future<void> _save() async {
    final text = _text.text.trim();
    final teamId = widget.session.currentTeam?.id;
    final now = DateTime.now();
    final at = _at(now);
    if (text.isEmpty || at == null || _timeProblem(now) != null) return;
    if (text.characters.length > reminderTextMax) {
      showAppToast(
        context,
        tr('내용은 {reminderTextMax}자까지 쓸 수 있습니다.', {
          'reminderTextMax': reminderTextMax,
        }),
      );
      return;
    }
    if (teamId == null) {
      showAppToast(context, tr('팀을 고른 뒤 만들 수 있습니다.'));
      return;
    }
    // 창을 닫은 뒤에 알리므로 미리 잡아 둔다.
    final overlay = Overlay.of(context, rootOverlay: true);
    setState(() => _saving = true);
    try {
      final created = await widget.session.api!.createReminder(
        text: text,
        remindAt: at,
        teamId: teamId,
      );
      if (!mounted) return;
      Navigator.of(context).pop(created);
      showAppToastOnOverlay(
        overlay,
        tr('{p0}에 "나와의 대화"로 알려 드릴게요.', {'p0': reminderTimeLabel(at)}),
      );
    } catch (e) {
      if (mounted) showAppToast(context, tr('리마인더를 만들지 못했습니다: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final now = DateTime.now();
    final at = _at(now);
    final problem = _timeProblem(now);
    final canSave = !_saving && _text.text.trim().isNotEmpty && problem == null;
    return AlertDialog(
      title: Text(tr('리마인더 생성')),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('reminder-new-text'),
                controller: _text,
                autofocus: true,
                maxLength: reminderTextMax,
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: tr('무엇을 알려 드릴까요? 예: 15시 회의 자료 보내기'),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Text(tr('언제'), style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in _presets)
                    ChoiceChip(
                      key: ValueKey('reminder-new-preset-${p.label}'),
                      label: Text(p.label),
                      selected: _choice == p.label,
                      onSelected: _saving
                          ? null
                          : (_) => setState(() => _choice = p.label),
                    ),
                  ChoiceChip(
                    key: const ValueKey('reminder-new-custom'),
                    avatar: const Icon(Icons.event_outlined, size: 18),
                    label: Text(tr('지정')),
                    selected: _choice == 'custom',
                    onSelected: _saving ? null : (_) => _pickCustom(),
                  ),
                ],
              ),
              if (_choice == 'custom' && _custom != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    key: const ValueKey('reminder-new-custom-panel'),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: DateTimePointPanel(
                      keyPrefix: 'reminder-new',
                      value: _custom!,
                      caption: tr('언제 알려 드릴까요?'),
                      timeLabel: tr('알림 시간'),
                      firstDay: now,
                      lastDay: now.add(_customMaxAhead),
                      onChanged: (v) => setState(() => _custom = v),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                problem ??
                    tr('{p0}에 "나와의 대화"로 알려 드립니다.', {
                      'p0': reminderTimeLabel(at!),
                    }),
                key: const ValueKey('reminder-new-summary'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: problem != null ? theme.colorScheme.error : hint,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('reminder-new-save'),
          onPressed: canSave ? _save : null,
          child: Text(tr('생성')),
        ),
      ],
    );
  }
}
