import 'package:flutter/material.dart';

import '../models/user_status.dart';
import '../services/session.dart';
import 'app_toast.dart';

/// 상태 메시지와 방해 금지를 정하는 창(계정 메뉴 — account_menu_button.dart)과, 다른 사람의 상태를 보여 주는 작은 조각들.
/// 규칙은 models/user_status.dart(서버 server/src/statusRules.js와 같음).

/// "13:00까지"·"10/20 18:00까지"처럼 — 오늘이면 시각만.
String untilLabel(DateTime until, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final sameDay =
      until.year == n.year && until.month == n.month && until.day == n.day;
  final time =
      '${until.hour.toString().padLeft(2, '0')}:${until.minute.toString().padLeft(2, '0')}';
  return sameDay ? '$time까지' : '${until.month}/${until.day} $time까지';
}

/// 방해 금지 상태를 한 줄로 — "🌙 방해 금지 중 · 13:00까지", 일정만이면 "🌙 방해 금지 중(19:00~08:00)". 꺼져 있으면 null.
String? dndLabel(DndState? dnd, {DateTime? now}) {
  final n = now ?? DateTime.now();
  if (dnd == null || !dnd.isActiveAt(n)) return null;
  final until = dnd.until;
  if (until != null && n.isBefore(until)) {
    return '🌙 방해 금지 중 · ${untilLabel(until, now: n)}';
  }
  final s = dnd.schedule!;
  return '🌙 방해 금지 중(${formatDayMinute(s.start)}~${formatDayMinute(s.end)})';
}

/// 이름 옆에 붙이는 작은 표시 — 상태 이모지와(있으면) 방해 금지 달. 둘 다 없으면 아무것도 그리지 않는다. 마우스를 올리면
/// 상태 글이 보인다.
class UserStatusBadge extends StatelessWidget {
  final Session session;
  final String userId;
  final double size;

  const UserStatusBadge({
    super.key,
    required this.session,
    required this.userId,
    this.size = 13,
  });

  @override
  Widget build(BuildContext context) {
    final status = session.statusOf(userId);
    final inDnd = session.isInDnd(userId);
    if (status == null && !inDnd) return const SizedBox.shrink();
    final parts = [if (status?.emoji != null) status!.emoji!, if (inDnd) '🌙'];
    if (parts.isEmpty) return const SizedBox.shrink();
    final tooltip = [
      if (status != null) status.label,
      ?dndLabel(session.dndOf(userId)),
    ].join('\n');
    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Text(parts.join(' '), style: TextStyle(fontSize: size)),
      ),
    );
  }
}

/// 상태 메시지 정하기 — 자주 쓰는 상태, 이모지·글, 언제 지울지.
Future<void> showStatusDialog(BuildContext context, Session session) =>
    showDialog<void>(
      context: context,
      builder: (_) => _StatusDialog(session: session),
    );

class _StatusDialog extends StatefulWidget {
  final Session session;
  const _StatusDialog({required this.session});

  @override
  State<_StatusDialog> createState() => _StatusDialogState();
}

class _StatusDialogState extends State<_StatusDialog> {
  late final TextEditingController _text;
  String? _emoji;
  StatusClearAfter _clear = StatusClearAfter.today;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final current = widget.session.myStatus;
    _emoji = current?.emoji;
    _text = TextEditingController(text: current?.text ?? '');
    if (current != null && current.until == null) {
      _clear = StatusClearAfter.never;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save({bool clear = false}) async {
    final text = _text.text.trim();
    if (!clear && text.characters.length > statusTextMax) {
      showAppToast(context, '상태 글은 $statusTextMax자까지 쓸 수 있습니다.');
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.session.setMyStatus(
        emoji: clear ? null : _emoji,
        text: clear || text.isEmpty ? null : text,
        until: clear ? null : _clear.untilFrom(DateTime.now()),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showAppToast(context, '상태를 저장하지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasStatus = widget.session.myStatus != null;
    return AlertDialog(
      title: const Text('상태 설정'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 2,
                runSpacing: 2,
                children: [
                  for (final e in statusEmojis)
                    InkResponse(
                      key: ValueKey('status-emoji-$e'),
                      radius: 20,
                      onTap: () =>
                          setState(() => _emoji = _emoji == e ? null : e),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _emoji == e ? scheme.primaryContainer : null,
                        ),
                        child: Text(e, style: const TextStyle(fontSize: 20)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _text,
                maxLength: statusTextMax,
                decoration: const InputDecoration(
                  labelText: '상태 글',
                  hintText: '예: 회의 중, 외근 중',
                  border: OutlineInputBorder(),
                ),
              ),
              DropdownButtonFormField<StatusClearAfter>(
                initialValue: _clear,
                decoration: const InputDecoration(
                  labelText: '지우는 시점',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final c in StatusClearAfter.values)
                    DropdownMenuItem(value: c, child: Text(c.label)),
                ],
                onChanged: (v) => setState(() => _clear = v ?? _clear),
              ),
              const SizedBox(height: 16),
              Text(
                '자주 쓰는 상태',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.hintColor,
                ),
              ),
              for (final p in statusPresets)
                ListTile(
                  key: ValueKey('status-preset-${p.text}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Text(p.emoji, style: const TextStyle(fontSize: 20)),
                  title: Text(p.text),
                  trailing: Text(
                    p.clear.label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                  onTap: () => setState(() {
                    _emoji = p.emoji;
                    _text.text = p.text;
                    _clear = p.clear;
                  }),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (hasStatus)
          TextButton(
            onPressed: _saving ? null : () => _save(clear: true),
            child: const Text('상태 지우기'),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('저장'),
        ),
      ],
    );
  }
}

/// 방해 금지 — 지금부터 잠시, 또는 매일 정한 시간. 켜져 있는 동안 메시지·멘션·업무 알림이 오지 않는다(화상회의 호출은 온다).
Future<void> showDndDialog(BuildContext context, Session session) =>
    showDialog<void>(
      context: context,
      builder: (_) => _DndDialog(session: session),
    );

class _DndDialog extends StatefulWidget {
  final Session session;
  const _DndDialog({required this.session});

  @override
  State<_DndDialog> createState() => _DndDialogState();
}

class _DndDialogState extends State<_DndDialog> {
  late bool _scheduleOn;
  late int _start;
  late int _end;
  late Set<int> _days;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final s = widget.session.myDnd?.schedule;
    _scheduleOn = s?.enabled ?? false;
    _start = s?.start ?? 19 * 60;
    _end = s?.end ?? 8 * 60;
    _days = {...?s?.days};
    if (_days.isEmpty) _days = {1, 2, 3, 4, 5};
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() => _saving = true);
    try {
      await action();
      if (mounted) showAppToast(context, done);
    } catch (e) {
      if (mounted) showAppToast(context, '방해 금지를 바꾸지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _pauseFor(Duration d) {
    final until = DateTime.now().add(d);
    _run(
      () => widget.session.setMyDnd(setUntil: true, until: until),
      '${untilLabel(until)} 알림을 멈춥니다.',
    );
  }

  void _pauseUntilTomorrowMorning() {
    final now = DateTime.now();
    final until = DateTime(now.year, now.month, now.day + 1, 9);
    _run(
      () => widget.session.setMyDnd(setUntil: true, until: until),
      '${untilLabel(until)} 알림을 멈춥니다.',
    );
  }

  void _resume() => _run(
    () => widget.session.setMyDnd(setUntil: true, until: null),
    '방해 금지를 껐습니다.',
  );

  void _saveSchedule() {
    if (_scheduleOn && _days.isEmpty) {
      showAppToast(context, '요일을 하나 이상 고르세요.');
      return;
    }
    if (_scheduleOn && _start == _end) {
      showAppToast(context, '시작과 끝 시간이 같습니다.');
      return;
    }
    _run(
      () => widget.session.setMyDnd(
        setSchedule: true,
        schedule: DndSchedule(
          enabled: _scheduleOn,
          start: _start,
          end: _end,
          days: _days.toList()..sort(),
          offsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
        ),
      ),
      _scheduleOn ? '방해 금지 일정을 저장했습니다.' : '방해 금지 일정을 껐습니다.',
    );
  }

  Future<void> _pickTime(bool start) async {
    final current = start ? _start : _end;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
    );
    if (picked == null || !mounted) return;
    setState(() {
      final minute = picked.hour * 60 + picked.minute;
      if (start) {
        _start = minute;
      } else {
        _end = minute;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final dnd = widget.session.myDnd;
        final label = dndLabel(dnd);
        final manualOn = dnd?.until != null;
        return AlertDialog(
          title: const Text('방해 금지'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    label ?? '지금은 알림을 받고 있습니다.',
                    key: const ValueKey('dnd-state'),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '방해 금지 중에는 메시지·멘션·업무 알림이 오지 않습니다. 메시지와 안 읽은 수는 그대로 쌓이고, '
                    '화상회의 호출은 옵니다. 같은 팀 사람들에게는 🌙로 보입니다.',
                    style: theme.textTheme.bodySmall?.copyWith(color: hint),
                  ),
                  const SizedBox(height: 16),
                  Text('지금부터 알림 멈추기', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (label, d) in [
                        ('30분', const Duration(minutes: 30)),
                        ('1시간', const Duration(hours: 1)),
                        ('2시간', const Duration(hours: 2)),
                      ])
                        ActionChip(
                          key: ValueKey('dnd-for-$label'),
                          label: Text(label),
                          onPressed: _saving ? null : () => _pauseFor(d),
                        ),
                      ActionChip(
                        key: const ValueKey('dnd-until-morning'),
                        label: const Text('내일 오전 9시까지'),
                        onPressed: _saving ? null : _pauseUntilTomorrowMorning,
                      ),
                      if (manualOn)
                        ActionChip(
                          key: const ValueKey('dnd-resume'),
                          avatar: const Icon(
                            Icons.notifications_active_outlined,
                            size: 18,
                          ),
                          label: const Text('지금 다시 받기'),
                          onPressed: _saving ? null : _resume,
                        ),
                    ],
                  ),
                  const Divider(height: 32),
                  SwitchListTile(
                    key: const ValueKey('dnd-schedule-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('매일 정해진 시간에 방해 금지'),
                    value: _scheduleOn,
                    onChanged: _saving
                        ? null
                        : (v) => setState(() => _scheduleOn = v),
                  ),
                  Row(
                    children: [
                      OutlinedButton(
                        key: const ValueKey('dnd-start'),
                        onPressed: _scheduleOn && !_saving
                            ? () => _pickTime(true)
                            : null,
                        child: Text(formatDayMinute(_start)),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Text('~'),
                      ),
                      OutlinedButton(
                        key: const ValueKey('dnd-end'),
                        onPressed: _scheduleOn && !_saving
                            ? () => _pickTime(false)
                            : null,
                        child: Text(formatDayMinute(_end)),
                      ),
                      if (_end < _start) ...[
                        const SizedBox(width: 8),
                        Text(
                          '(다음 날)',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: hint,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 4,
                    children: [
                      // 월요일부터 — 0(일)은 끝에.
                      for (final d in [1, 2, 3, 4, 5, 6, 0])
                        FilterChip(
                          key: ValueKey('dnd-day-$d'),
                          label: Text(weekdayNames[d]),
                          selected: _days.contains(d),
                          onSelected: _scheduleOn && !_saving
                              ? (on) => setState(
                                  () => on ? _days.add(d) : _days.remove(d),
                                )
                              : null,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('닫기'),
            ),
            FilledButton(
              key: const ValueKey('dnd-save-schedule'),
              onPressed: _saving ? null : _saveSchedule,
              child: const Text('일정 저장'),
            ),
          ],
        );
      },
    );
  }
}

/// 다른 사람의 상태를 프로필 창 등에 두 줄까지 — 상태 메시지(지울 시각 포함)와 방해 금지. 둘 다 없으면 아무것도 그리지 않는다.
class UserStatusLines extends StatelessWidget {
  final Session session;
  final String userId;

  const UserStatusLines({
    super.key,
    required this.session,
    required this.userId,
  });

  @override
  Widget build(BuildContext context) {
    final status = session.statusOf(userId);
    final dnd = dndLabel(session.dndOf(userId));
    if (status == null && dnd == null) return const SizedBox.shrink();
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (status != null)
          Text(
            status.until == null
                ? status.label
                : '${status.label} · ${untilLabel(status.until!)}',
            style: const TextStyle(fontSize: 13),
          ),
        if (dnd != null) Text(dnd, style: TextStyle(fontSize: 12, color: hint)),
      ],
    );
  }
}

/// 계정 메뉴의 한 줄 요약 — "🗓️ 회의 중" 또는 "상태 설정".
String myStatusMenuLabel(Session session) => session.myStatus?.label ?? '상태 설정';

/// 계정 메뉴의 방해 금지 한 줄 — "방해 금지 · 켜짐(13:00까지)" 또는 "방해 금지".
String myDndMenuLabel(Session session) {
  final dnd = session.myDnd;
  if (dnd == null || !dnd.isActiveAt(DateTime.now())) return '방해 금지';
  final until = dnd.until;
  return until != null && DateTime.now().isBefore(until)
      ? '방해 금지 · ${untilLabel(until)}'
      : '방해 금지 · 켜짐';
}
