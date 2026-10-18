import 'package:flutter/material.dart';

import '../models/user_status.dart';
import '../services/session.dart';
import 'app_toast.dart';
import 'date_time_range_field.dart' show DateTimePointPanel;
import 'muted_scrollbar.dart';
import '../l10n/tr.dart';

/// 상태 메시지와 방해 금지를 정하는 창(계정 메뉴 — account_menu_button.dart)과, 다른 사람의 상태를 보여 주는 작은 조각들.
/// 규칙은 models/user_status.dart(서버 server/src/statusRules.js와 같음).

/// "13:00까지"·"10/20 18:00까지"처럼 — 오늘이면 시각만.
String untilLabel(DateTime until, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final sameDay =
      until.year == n.year && until.month == n.month && until.day == n.day;
  final time =
      '${until.hour.toString().padLeft(2, '0')}:${until.minute.toString().padLeft(2, '0')}';
  return sameDay
      ? tr('{time}까지', {'time': time})
      : tr('{until.month}/{until.day} {time}까지', {
          'until.month': until.month,
          'until.day': until.day,
          'time': time,
        });
}

/// 방해 금지 상태를 한 줄로 — "🌙 방해 금지 중 · 13:00까지", 일정만이면 "🌙 방해 금지 중(19:00~08:00)". 꺼져 있으면 null.
String? dndLabel(DndState? dnd, {DateTime? now}) {
  final n = now ?? DateTime.now();
  if (dnd == null || !dnd.isActiveAt(n)) return null;
  final until = dnd.until;
  if (until != null && n.isBefore(until)) {
    return tr('🌙 방해 금지 중 · {p0}', {'p0': untilLabel(until, now: n)});
  }
  final s = dnd.schedule!;
  return tr('🌙 방해 금지 중({p0}~{p1})', {
    'p0': formatDayMinute(s.start),
    'p1': formatDayMinute(s.end),
  });
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
    // 글을 지우거나 쓰면 "[저장]을 누르면 상태가 지워집니다." 안내와 [상태 지우기]가 바로 바뀌게.
    _text.addListener(_onTextChanged);
    if (current != null && current.until == null) {
      _clear = StatusClearAfter.never;
    }
  }

  void _onTextChanged() => setState(() {});

  /// 이모지도 글도 없는지 — 이대로 저장하면 상태를 지운다.
  bool get _empty => _emoji == null && _text.text.trim().isEmpty;

  /// [상태 지우기] — 이모지와 글을 비우기만 한다. 실제로 지우는 건 [저장]을 눌렀을 때다(취소하면 그대로).
  void _clearFields() => setState(() {
    _emoji = null;
    _text.clear();
  });

  @override
  void dispose() {
    _text.removeListener(_onTextChanged);
    _text.dispose();
    super.dispose();
  }

  /// [저장] — 이모지·글이 다 비어 있으면 상태를 지운다(원래 없었으면 보낼 것 없이 닫는다).
  Future<void> _save() async {
    final text = _text.text.trim();
    final clear = _empty;
    // 저장해도 창은 닫지 않는다 — 알약으로만 알린다(닫기는 [취소]).
    if (clear && widget.session.myStatus == null) {
      showAppToast(context, tr('저장했습니다.'));
      return;
    }
    if (!clear && text.characters.length > statusTextMax) {
      showAppToast(
        context,
        tr('상태 글은 {statusTextMax}자까지 쓸 수 있습니다.', {
          'statusTextMax': statusTextMax,
        }),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.session.setMyStatus(
        emoji: clear ? null : _emoji,
        text: clear || text.isEmpty ? null : text,
        until: clear ? null : _clear.untilFrom(DateTime.now()),
      );
      if (mounted) showAppToast(context, tr('저장했습니다.'));
    } catch (e) {
      if (mounted) showAppToast(context, tr('상태를 저장하지 못했습니다: {e}', {'e': e}));
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
      title: Text(tr('상태 설정')),
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
                decoration: InputDecoration(
                  labelText: tr('상태 글'),
                  hintText: tr('예: 회의 중, 외근 중'),
                  border: OutlineInputBorder(),
                ),
              ),
              DropdownButtonFormField<StatusClearAfter>(
                initialValue: _clear,
                decoration: InputDecoration(
                  labelText: tr('지우는 시점'),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final c in StatusClearAfter.values)
                    DropdownMenuItem(value: c, child: Text(c.label)),
                ],
                onChanged: (v) => setState(() => _clear = v ?? _clear),
              ),
              if (hasStatus && _empty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    tr('[저장]을 누르면 상태가 지워집니다.'),
                    key: const ValueKey('status-clear-hint'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Text(
                tr('자주 쓰는 상태'),
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
        // 지우기만 해 두고 [저장]을 눌러야 적용된다 — 이미 비웠으면 누를 게 없다.
        if (hasStatus)
          TextButton(
            key: const ValueKey('status-clear'),
            onPressed: _saving || _empty ? null : _clearFields,
            child: Text(tr('상태 지우기')),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(onPressed: _saving ? null : _save, child: Text(tr('저장'))),
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

/// "지금부터 알림 멈추기"의 정해 둔 길이 — 칩 키는 'dnd-for-<이름>'.
final _pauseDurations = [
  (tr('30분'), Duration(minutes: 30)),
  (tr('1시간'), Duration(hours: 1)),
  (tr('2시간'), Duration(hours: 2)),
];

/// "지정"으로 고를 수 있는 가장 먼 시각 — 서버(statusRules.js UNTIL_MAX_MS)와 같은 31일.
const _pauseMax = Duration(days: 31);

class _DndDialogState extends State<_DndDialog> {
  late bool _scheduleOn;
  late int _start;
  late int _end;
  late Set<int> _days;
  bool _saving = false;

  /// "지금부터 알림 멈추기"에서 고른 칩의 키 — [저장]을 눌러야 적용된다. null이면 지금 상태 그대로 둔다.
  /// 'for-<이름>'([_pauseDurations]) · 'morning'(내일 오전 9시) · 'custom'([_customUntil]) · 'resume'(지금 다시 받기).
  String? _pauseKey;

  /// "지정"으로 고른 시각.
  DateTime? _customUntil;

  /// 창 내용의 스크롤 — 스크롤바([MutedScrollbar])가 같이 쓴다.
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

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

  /// 칩을 고른다 — 이미 고른 칩을 다시 누르면 고르지 않은 것으로 돌린다.
  void _choosePause(String key) =>
      setState(() => _pauseKey = _pauseKey == key ? null : key);

  /// [_pauseKey]가 뜻하는 끝 시각(저장하는 순간 [now] 기준). 'resume'이면 null(방해 금지 끄기).
  DateTime? _pauseUntil(DateTime now) {
    final key = _pauseKey;
    if (key == 'morning') return DateTime(now.year, now.month, now.day + 1, 9);
    if (key == 'custom') return _customUntil;
    for (final (label, d) in _pauseDurations) {
      if (key == 'for-$label') return now.add(d);
    }
    return null;
  }

  /// "지정" — 칩 아래에 달력과 시간 칸([DateTimePointPanel], 할 일 기간 달력과 같은 모양)을 펼친다. 처음 값은 한 시간 뒤를
  /// 15분 단위로 올린 시각이고, 한 번 고른 시각은 다시 펼쳐도 남는다. 다시 누르면 접는다(고르지 않은 것으로).
  void _toggleCustom() {
    if (_pauseKey == 'custom') {
      setState(() => _pauseKey = null);
      return;
    }
    final base = DateTime.now().add(const Duration(hours: 1));
    final slot = (base.hour * 60 + base.minute + 14) ~/ 15 * 15;
    setState(() {
      _customUntil ??= DateTime(base.year, base.month, base.day, 0, slot);
      _pauseKey = 'custom';
    });
  }

  /// "지정"으로 고른 시각이 지금 쓸 수 있는지 — 안 되면 그 까닭(지났거나 한 달 넘음), 되면 null.
  String? _customProblem(DateTime now) {
    final until = _customUntil;
    if (until == null || !until.isAfter(now)) {
      return tr('지금보다 뒤의 시각을 고르세요.');
    }
    if (until.difference(now) > _pauseMax) return tr('한 달 안으로만 정할 수 있습니다.');
    return null;
  }

  /// 매일 일정이 지금 저장된 것과 달라졌는지 — 바뀐 것만 서버에 보낸다.
  bool get _scheduleChanged {
    final s = widget.session.myDnd?.schedule;
    if (s == null) return _scheduleOn;
    return s.enabled != _scheduleOn ||
        (_scheduleOn &&
            (s.start != _start ||
                s.end != _end ||
                !(s.days.toSet().containsAll(_days) &&
                    _days.containsAll(s.days))));
  }

  /// [저장] — 고른 "지금부터 알림 멈추기"와 바뀐 매일 일정을 한 번에 적용한다. 창은 닫지 않고 "저장했습니다." 알약만
  /// 띄운다(창 위쪽 지금 상태가 새 값으로 바뀌고, 고른 칩은 풀린다). 바뀐 게 없어도 같은 알약.
  Future<void> _save() async {
    final scheduleChanged = _scheduleChanged;
    if (_pauseKey == null && !scheduleChanged) {
      showAppToast(context, tr('저장했습니다.'));
      return;
    }
    if (scheduleChanged && _scheduleOn && _days.isEmpty) {
      showAppToast(context, tr('요일을 하나 이상 고르세요.'));
      return;
    }
    if (scheduleChanged && _scheduleOn && _start == _end) {
      showAppToast(context, tr('시작과 끝 시간이 같습니다.'));
      return;
    }
    final now = DateTime.now();
    final until = _pauseKey == null ? null : _pauseUntil(now);
    if (_pauseKey == 'custom') {
      final problem = _customProblem(now);
      if (problem != null) {
        showAppToast(context, problem);
        return;
      }
    }
    setState(() => _saving = true);
    try {
      await widget.session.setMyDnd(
        setUntil: _pauseKey != null,
        until: until,
        setSchedule: scheduleChanged,
        schedule: scheduleChanged
            ? DndSchedule(
                enabled: _scheduleOn,
                start: _start,
                end: _end,
                days: _days.toList()..sort(),
                offsetMinutes: now.timeZoneOffset.inMinutes,
              )
            : null,
      );
      if (!mounted) return;
      // 적용했으니 고른 칩은 푼다 — 위쪽의 지금 상태("13:00까지 알림을 멈춥니다" 등)가 새 값을 보여 준다.
      setState(() => _pauseKey = null);
      showAppToast(context, tr('저장했습니다.'));
    } catch (e) {
      if (mounted) showAppToast(context, tr('방해 금지를 바꾸지 못했습니다: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
          title: Text(tr('방해 금지')),
          // 내용이 창보다 길면 스크롤바를 늘 보이고, 창 오른쪽 끝에 붙인다 — 그래서 내용 칸의 좌우 여백을 빼고 그 여백을
          // 스크롤 안쪽에 준다(내용 폭 400은 그대로).
          contentPadding: const EdgeInsets.only(top: 16),
          content: SizedBox(
            width: 400 + 2 * 24,
            child: MutedScrollbar(
              controller: _scroll,
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      label ?? tr('지금은 알림을 받고 있습니다.'),
                      key: const ValueKey('dnd-state'),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tr(
                        '방해 금지 중에는 메시지·멘션·업무 알림이 오지 않습니다. 메시지와 안 읽은 수는 그대로 쌓이고, 화상회의 호출은 옵니다. 같은 팀 사람들에게는 🌙로 보입니다.',
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(color: hint),
                    ),
                    const SizedBox(height: 16),
                    Text(tr('지금부터 알림 멈추기'), style: theme.textTheme.labelLarge),
                    const SizedBox(height: 6),
                    // 고르기만 하고 [저장]을 눌러야 적용된다(고른 칩은 다시 누르면 풀린다).
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final (label, _) in _pauseDurations)
                          ChoiceChip(
                            key: ValueKey('dnd-for-$label'),
                            label: Text(label),
                            selected: _pauseKey == 'for-$label',
                            onSelected: _saving
                                ? null
                                : (_) => _choosePause('for-$label'),
                          ),
                        ChoiceChip(
                          key: const ValueKey('dnd-until-morning'),
                          label: Text(tr('내일 오전 9시까지')),
                          selected: _pauseKey == 'morning',
                          onSelected: _saving
                              ? null
                              : (_) => _choosePause('morning'),
                        ),
                        // 지정 — 아래에 달력과 시간 칸이 펼쳐진다. 고르는 동안 칩에 그 시각이 보인다.
                        ChoiceChip(
                          key: const ValueKey('dnd-custom'),
                          avatar: const Icon(Icons.event_outlined, size: 18),
                          label: Text(
                            _pauseKey == 'custom' && _customUntil != null
                                ? untilLabel(_customUntil!)
                                : tr('지정'),
                          ),
                          selected: _pauseKey == 'custom',
                          onSelected: _saving ? null : (_) => _toggleCustom(),
                        ),
                        if (manualOn)
                          ChoiceChip(
                            key: const ValueKey('dnd-resume'),
                            avatar: const Icon(
                              Icons.notifications_active_outlined,
                              size: 18,
                            ),
                            label: Text(tr('지금 다시 받기')),
                            selected: _pauseKey == 'resume',
                            onSelected: _saving
                                ? null
                                : (_) => _choosePause('resume'),
                          ),
                      ],
                    ),
                    if (_pauseKey == 'custom' && _customUntil != null) ...[
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          key: const ValueKey('dnd-custom-panel'),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: DateTimePointPanel(
                            keyPrefix: 'dnd',
                            value: _customUntil!,
                            caption: tr('언제까지 알림을 멈출까요?'),
                            timeLabel: tr('종료 시간'),
                            firstDay: DateTime.now(),
                            lastDay: DateTime.now().add(_pauseMax),
                            onChanged: (v) => setState(() => _customUntil = v),
                          ),
                        ),
                      ),
                      if (_customProblem(DateTime.now()) case final problem?)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            problem,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                    if (_pauseKey != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        tr('[저장]을 누르면 적용됩니다.'),
                        style: theme.textTheme.bodySmall?.copyWith(color: hint),
                      ),
                    ],
                    const Divider(height: 32),
                    SwitchListTile(
                      key: const ValueKey('dnd-schedule-switch'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr('매일 정해진 시간에 방해 금지')),
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
                            tr('(다음 날)'),
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
          ),
          actions: [
            TextButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: Text(tr('취소')),
            ),
            FilledButton(
              key: const ValueKey('dnd-save'),
              onPressed: _saving ? null : _save,
              child: Text(tr('저장')),
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
String myStatusMenuLabel(Session session) =>
    session.myStatus?.label ?? tr('상태 설정');

/// 계정 메뉴의 방해 금지 한 줄 — "방해 금지 · 켜짐(13:00까지)" 또는 "방해 금지".
String myDndMenuLabel(Session session) {
  final dnd = session.myDnd;
  if (dnd == null || !dnd.isActiveAt(DateTime.now())) return tr('방해 금지');
  final until = dnd.until;
  return until != null && DateTime.now().isBefore(until)
      ? tr('방해 금지 · {p0}', {'p0': untilLabel(until)})
      : tr('방해 금지 · 켜짐');
}
