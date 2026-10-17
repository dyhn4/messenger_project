import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/project.dart';
import '../../models/task_extras.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/date_drop_calendar.dart';
import 'task_views.dart' show formatYmd;

/// 업무 상세 패널(task_detail_panel.dart)에 붙는 업무 기능 보강 — 반복 규칙·예상 시간 고르기 창, 선후행 업무 칸, 소요 시간 칸,
/// 프로젝트 소요 시간 보고 창. 서버는 taskExtras.js.

String _ymdKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime _parseYmd(String key) {
  final p = key.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

// ── 반복 규칙 ───────────────────────────────────────────────────────────

/// 반복 고르기 창 — 취소하면 null, "반복 안 함"이면 rule이 null인 결과.
Future<({TaskRecurrence? rule})?> showTaskRecurrenceDialog(
  BuildContext context, {
  TaskRecurrence? initial,
}) => showDialog<({TaskRecurrence? rule})>(
  context: context,
  builder: (_) => _RecurrenceDialog(initial: initial),
);

class _RecurrenceDialog extends StatefulWidget {
  final TaskRecurrence? initial;
  const _RecurrenceDialog({this.initial});

  @override
  State<_RecurrenceDialog> createState() => _RecurrenceDialogState();
}

class _RecurrenceDialogState extends State<_RecurrenceDialog> {
  late String _freq = widget.initial?.freq ?? 'weekly';
  late int _interval = widget.initial?.interval ?? 1;
  late final Set<int> _days = {...?widget.initial?.byWeekday};
  late DateTime? _until = widget.initial?.until == null
      ? null
      : _parseYmd(widget.initial!.until!);

  static const _freqs = [
    ('daily', '매일', '일'),
    ('weekly', '매주', '주'),
    ('monthly', '매월', '개월'),
    ('yearly', '매년', '년'),
  ];

  TaskRecurrence get _rule => TaskRecurrence(
    freq: _freq,
    interval: _interval,
    byWeekday: _freq == 'weekly' ? (_days.toList()..sort()) : const [],
    until: _until == null ? null : _ymdKey(_until!),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unit = _freqs.firstWhere((f) => f.$1 == _freq).$3;
    return AlertDialog(
      title: const Text('반복'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<String>(
              key: const ValueKey('recurrence-freq'),
              showSelectedIcon: false,
              segments: [
                for (final f in _freqs)
                  ButtonSegment(value: f.$1, label: Text(f.$2)),
              ],
              selected: {_freq},
              onSelectionChanged: (s) => setState(() => _freq = s.first),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const Text('간격'),
                const SizedBox(width: 12),
                DropdownButton<int>(
                  key: const ValueKey('recurrence-interval'),
                  value: _interval,
                  items: [
                    for (var i = 1; i <= 30; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(i == 1 ? '1$unit마다' : '$i$unit마다'),
                      ),
                  ],
                  onChanged: (v) => setState(() => _interval = v ?? 1),
                ),
              ],
            ),
            if (_freq == 'weekly') ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 4,
                children: [
                  for (var d = 0; d < 7; d++)
                    FilterChip(
                      key: ValueKey('recurrence-day-$d'),
                      label: Text(TaskRecurrence.weekdayNames[d]),
                      selected: _days.contains(d),
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      onSelected: (on) =>
                          setState(() => on ? _days.add(d) : _days.remove(d)),
                    ),
                ],
              ),
              Text(
                '요일을 고르지 않으면 마감일의 요일에 반복합니다.',
                style: TextStyle(fontSize: 12, color: theme.hintColor),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('종료일'),
                const SizedBox(width: 12),
                DateDropButton(
                  value: _until,
                  onPicked: (d) => setState(() => _until = d),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Text(
                      _until == null ? '없음(계속 반복)' : formatYmd(_until!),
                      style: TextStyle(
                        color: _until == null ? theme.hintColor : null,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '완료하면 다음 회차 업무가 만들어집니다 — 날짜는 마감일 기준으로 옮기고, 담당자·참조자·체크리스트(새로)를 그대로 가져갑니다.',
              style: TextStyle(fontSize: 12, color: theme.hintColor),
            ),
            const SizedBox(height: 6),
            Text(
              _rule.label,
              key: const ValueKey('recurrence-preview'),
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.initial != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop((rule: null)),
            child: const Text('반복 안 함'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('recurrence-save'),
          onPressed: () => Navigator.of(context).pop((rule: _rule)),
          child: const Text('저장'),
        ),
      ],
    );
  }
}

// ── 시간 입력 ───────────────────────────────────────────────────────────

/// "시간·분" 두 칸 — 합한 분을 [onChanged]로.
class _HoursMinutesField extends StatefulWidget {
  final int? initial;
  final ValueChanged<int> onChanged;
  final String keyPrefix;
  const _HoursMinutesField({
    this.initial,
    required this.onChanged,
    required this.keyPrefix,
  });

  @override
  State<_HoursMinutesField> createState() => _HoursMinutesFieldState();
}

class _HoursMinutesFieldState extends State<_HoursMinutesField> {
  late final _h = TextEditingController(
    text: widget.initial == null ? '' : '${widget.initial! ~/ 60}',
  );
  late final _m = TextEditingController(
    text: widget.initial == null ? '' : '${widget.initial! % 60}',
  );

  @override
  void dispose() {
    _h.dispose();
    _m.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged(
    (int.tryParse(_h.text) ?? 0) * 60 + (int.tryParse(_m.text) ?? 0),
  );

  Widget _box(TextEditingController c, String suffix, String key) => SizedBox(
    width: 90,
    child: TextField(
      key: ValueKey(key),
      controller: c,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        isDense: true,
        suffixText: suffix,
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) => _emit(),
    ),
  );

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _box(_h, '시간', '${widget.keyPrefix}-hours'),
      const SizedBox(width: 8),
      _box(_m, '분', '${widget.keyPrefix}-minutes'),
    ],
  );
}

/// 예상 소요 시간 창 — 취소하면 null, "지우기"면 minutes가 null인 결과.
Future<({int? minutes})?> showEstimateDialog(
  BuildContext context, {
  int? initial,
}) {
  var minutes = initial ?? 0;
  return showDialog<({int? minutes})>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        title: const Text('예상 시간'),
        content: _HoursMinutesField(
          initial: initial,
          keyPrefix: 'estimate',
          onChanged: (v) => setState(() => minutes = v),
        ),
        actions: [
          if (initial != null)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop((minutes: null)),
              child: const Text('지우기'),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('estimate-save'),
            onPressed: minutes < 1
                ? null
                : () => Navigator.of(dialogContext).pop((minutes: minutes)),
            child: const Text('저장'),
          ),
        ],
      ),
    ),
  );
}

/// 시간 기록 창 — 시간·분, 일한 날(오늘까지), 메모.
Future<({int minutes, DateTime date, String note})?> _showTimeEntryDialog(
  BuildContext context,
) => showDialog<({int minutes, DateTime date, String note})>(
  context: context,
  builder: (_) => const _TimeEntryDialog(),
);

/// 메모 입력칸은 창이 닫히는 애니메이션이 끝난 뒤에 정리되게 창이 들고 있는다.
class _TimeEntryDialog extends StatefulWidget {
  const _TimeEntryDialog();

  @override
  State<_TimeEntryDialog> createState() => _TimeEntryDialogState();
}

class _TimeEntryDialogState extends State<_TimeEntryDialog> {
  var _minutes = 0;
  var _date = DateTime.now();
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    return AlertDialog(
      title: const Text('소요 시간 기록'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _HoursMinutesField(
              keyPrefix: 'time-entry',
              onChanged: (v) => setState(() => _minutes = v),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('날짜'),
                const SizedBox(width: 12),
                DateDropButton(
                  value: _date,
                  allowClear: false,
                  onPicked: (d) {
                    if (d == null) return;
                    // 앞으로의 날짜에는 남길 수 없다(서버도 막는다).
                    if (d.isAfter(today)) {
                      showAppToast(context, '오늘까지의 날짜만 고를 수 있습니다.');
                      return;
                    }
                    setState(() => _date = d);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Text(formatYmd(_date)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('time-entry-note'),
              controller: _note,
              maxLength: 200,
              decoration: const InputDecoration(
                hintText: '메모(선택)',
                isDense: true,
                border: OutlineInputBorder(),
              ),
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
          key: const ValueKey('time-entry-save'),
          onPressed: _minutes < 1 || _minutes > 24 * 60
              ? null
              : () => Navigator.of(
                  context,
                ).pop((minutes: _minutes, date: _date, note: _note.text)),
          child: const Text('기록'),
        ),
      ],
    );
  }
}

// ── 선후행 업무 ─────────────────────────────────────────────────────────

/// 선후행 업무 칸 — 선행(이 업무 전에 끝나야 하는 것)을 더하고 빼고, 후행(이 업무를 기다리는 것)을 본다. 선행이 안 끝났으면
/// 위에 안내가 붙는다(막지는 않는다). 누르면 그 업무로 간다.
class TaskDependenciesSection extends StatelessWidget {
  final Session session;
  final Task task;
  final bool readOnly;

  /// 서버에 반영한 뒤 — 패널을 다시 읽는다.
  final Future<void> Function(Future<void> Function() save) apply;
  final ValueChanged<String> onOpenTask;

  const TaskDependenciesSection({
    super.key,
    required this.session,
    required this.task,
    required this.readOnly,
    required this.apply,
    required this.onOpenTask,
  });

  Future<void> _add(BuildContext context) async {
    final picked = await showDialog<Task>(
      context: context,
      builder: (_) => _TaskPickerDialog(
        session: session,
        projectId: task.projectId,
        exclude: {task.id, for (final p in task.predecessors) p.id},
      ),
    );
    if (picked == null) return;
    await apply(() async {
      await session.api!.addTaskDependency(task.id, picked.id);
    });
  }

  Widget _row(BuildContext context, TaskLink link, {VoidCallback? onRemove}) {
    final theme = Theme.of(context);
    final color = parseTypeColor(link.statusColor);
    return InkWell(
      key: ValueKey('task-link-${link.id}'),
      onTap: () => onOpenTask(link.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(
              link.isDone ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 16,
              color: link.isDone ? Colors.green : theme.hintColor,
            ),
            const SizedBox(width: 8),
            Text(
              link.key,
              style: TextStyle(fontSize: 12, color: theme.hintColor),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                link.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  decoration: link.isDone ? TextDecoration.lineThrough : null,
                  color: link.isDone ? theme.hintColor : null,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                link.statusName ?? '',
                style: TextStyle(fontSize: 11, color: color),
              ),
            ),
            if (onRemove != null)
              IconButton(
                tooltip: '선행 업무 해제',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                onPressed: onRemove,
                icon: const Icon(Icons.close),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final open = task.predecessors
        .where((p) => !p.isDone && !p.archived)
        .length;
    Widget sub(String text) => Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Text(text, style: TextStyle(fontSize: 12, color: hint)),
    );
    return Column(
      key: const ValueKey('task-dependencies'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.account_tree_outlined, size: 16, color: hint),
            const SizedBox(width: 6),
            const Text('선후행 업무', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        if (open > 0 && task.status != TaskStatus.done)
          Container(
            key: const ValueKey('task-blocked-note'),
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                const Icon(Icons.hourglass_top, size: 14, color: Colors.orange),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '선행 업무 $open개가 아직 끝나지 않았습니다.',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
        sub('선행 업무 — 이 업무 전에 끝나야 합니다'),
        for (final p in task.predecessors)
          _row(
            context,
            p,
            onRemove: readOnly
                ? null
                : () => apply(
                    () => session.api!.removeTaskDependency(task.id, p.id),
                  ),
          ),
        if (!readOnly)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('task-add-predecessor'),
              onPressed: () => _add(context),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('선행 업무 추가'),
            ),
          )
        else if (task.predecessors.isEmpty)
          Text('없음', style: TextStyle(fontSize: 13, color: hint)),
        if (task.successors.isNotEmpty) ...[
          sub('후행 업무 — 이 업무가 끝나기를 기다립니다'),
          for (final s in task.successors) _row(context, s),
        ],
      ],
    );
  }
}

/// 같은 프로젝트의 업무 고르기 — 번호·제목으로 찾는다(보관한 업무·[exclude]는 뺀다).
class _TaskPickerDialog extends StatefulWidget {
  final Session session;
  final String projectId;
  final Set<String> exclude;
  const _TaskPickerDialog({
    required this.session,
    required this.projectId,
    required this.exclude,
  });

  @override
  State<_TaskPickerDialog> createState() => _TaskPickerDialogState();
}

class _TaskPickerDialogState extends State<_TaskPickerDialog> {
  List<Task>? _tasks;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    widget.session.api!
        .fetchProjectTasks(widget.projectId)
        .then((list) {
          if (mounted) setState(() => _tasks = list);
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = '$e');
        });
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final shown = [
      for (final t in _tasks ?? const <Task>[])
        if (!widget.exclude.contains(t.id) &&
            !t.archived &&
            (q.isEmpty ||
                t.title.toLowerCase().contains(q) ||
                (t.key ?? '').toLowerCase().contains(q)))
          t,
    ];
    return AlertDialog(
      title: const Text('선행 업무 고르기'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('task-picker-search'),
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '번호나 제목으로 찾기',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _error != null
                  ? Center(child: Text(_error!))
                  : _tasks == null
                  ? const Center(child: CircularProgressIndicator())
                  : shown.isEmpty
                  ? const Center(child: Text('고를 수 있는 업무가 없습니다.'))
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, i) {
                        final t = shown[i];
                        return ListTile(
                          key: ValueKey('task-pick-${t.id}'),
                          dense: true,
                          leading: Text(t.key ?? ''),
                          title: Text(
                            t.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Text(
                            t.statusLabel,
                            style: const TextStyle(fontSize: 12),
                          ),
                          onTap: () => Navigator.of(context).pop(t),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
      ],
    );
  }
}

// ── 소요 시간 ───────────────────────────────────────────────────────────

/// 소요 시간 칸 — 기록 합·예상 대비 막대, 타이머(사람마다 하나, 기기 사이에 같이 보인다), "+ 시간 기록", 기록 목록.
/// 남이 남긴 기록은 프로젝트 담당자만 지울 수 있다([canManage]).
class TaskTimeSection extends StatefulWidget {
  final Session session;
  final Task task;
  final bool readOnly;
  final bool canManage;
  final Future<void> Function(Future<void> Function() save) apply;
  final VoidCallback onEditEstimate;

  const TaskTimeSection({
    super.key,
    required this.session,
    required this.task,
    required this.readOnly,
    required this.canManage,
    required this.apply,
    required this.onEditEstimate,
  });

  @override
  State<TaskTimeSection> createState() => _TaskTimeSectionState();
}

class _TaskTimeSectionState extends State<TaskTimeSection> {
  TaskTimer? _timer;
  StreamSubscription<TaskTimer?>? _sub;
  Timer? _tick;
  bool _busy = false;
  bool _showAll = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.session.chatSocket.taskTimerChanged.listen(_setTimer);
    widget.session.api!
        .fetchTaskTimer()
        .then(_setTimer)
        .catchError((Object _) {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  bool get _runningHere => _timer?.taskId == widget.task.id;

  void _setTimer(TaskTimer? t) {
    if (!mounted) return;
    final wasHere = _runningHere;
    setState(() => _timer = t);
    _tick?.cancel();
    if (_runningHere) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
    // 다른 기기에서 멈춰 기록이 생겼을 수 있다 — 칸의 합·목록을 다시 읽는다.
    if (wasHere && !_runningHere) unawaited(widget.apply(() async {}));
  }

  Future<void> _toggleTimer() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final api = widget.session.api!;
      if (_runningHere) {
        final entry = await api.stopTaskTimer();
        _setTimer(null);
        if (mounted) {
          showAppToast(
            context,
            entry == null
                ? '1분이 안 되어 기록하지 않았습니다.'
                : '${formatMinutes(entry.minutes)}을 기록했습니다.',
          );
        }
        // 칸의 합·목록은 위 _setTimer(null)이 다시 읽는다.
      } else {
        final elsewhere = _timer;
        final started = await api.startTaskTimer(widget.task.id);
        _setTimer(started);
        if (elsewhere != null && mounted) {
          showAppToast(context, '${elsewhere.key} 타이머를 멈춰 기록하고 이 업무에서 시작했습니다.');
        }
      }
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addEntry() async {
    final picked = await _showTimeEntryDialog(context);
    if (picked == null) return;
    await widget.apply(() async {
      await widget.session.api!.addTimeEntry(
        widget.task.id,
        minutes: picked.minutes,
        workDate: _ymdKey(picked.date),
        note: picked.note,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final task = widget.task;
    final spent = task.spentMinutes;
    final estimate = task.estimateMinutes;
    final over = estimate != null && spent > estimate;
    final entries = _showAll
        ? task.timeEntries
        : task.timeEntries.take(5).toList();
    final me = widget.session.userId;
    final running = _timer;
    return Column(
      key: const ValueKey('task-time'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.timer_outlined, size: 16, color: hint),
            const SizedBox(width: 6),
            const Text('소요 시간', style: TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            if (!widget.readOnly)
              _runningHere
                  ? FilledButton.tonalIcon(
                      key: const ValueKey('task-timer-stop'),
                      onPressed: _busy ? null : _toggleTimer,
                      icon: const Icon(Icons.stop, size: 16),
                      label: Text(
                        formatElapsed(
                          DateTime.now().difference(running!.startedAt),
                        ),
                      ),
                    )
                  : OutlinedButton.icon(
                      key: const ValueKey('task-timer-start'),
                      onPressed: _busy ? null : _toggleTimer,
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: const Text('타이머'),
                    ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              '기록 ${formatMinutes(spent)}',
              key: const ValueKey('task-time-spent'),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: over ? theme.colorScheme.error : null,
              ),
            ),
            Text(' · ', style: TextStyle(color: hint)),
            InkWell(
              onTap: widget.readOnly ? null : widget.onEditEstimate,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                child: Text(
                  estimate == null
                      ? '예상 시간 정하기'
                      : '예상 ${formatMinutes(estimate)}',
                  key: const ValueKey('task-time-estimate'),
                  style: TextStyle(
                    fontSize: 13,
                    color: estimate == null ? hint : null,
                    decoration: widget.readOnly
                        ? null
                        : TextDecoration.underline,
                    decorationColor: hint,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (estimate != null) ...[
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: (spent / estimate).clamp(0, 1).toDouble(),
              minHeight: 5,
              color: over ? theme.colorScheme.error : null,
            ),
          ),
        ],
        if (running != null && !_runningHere && !widget.readOnly)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '${running.key}에서 타이머가 돌고 있습니다 — 여기서 켜면 그 업무에 기록하고 넘어옵니다.',
              style: TextStyle(fontSize: 12, color: hint),
            ),
          ),
        const SizedBox(height: 4),
        for (final e in entries)
          Padding(
            key: ValueKey('time-entry-${e.id}'),
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                SizedBox(
                  width: 44,
                  child: Text(
                    e.workDate.length == 10
                        ? e.workDate.substring(5).replaceAll('-', '/')
                        : e.workDate,
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                ),
                Text(e.userName ?? '', style: const TextStyle(fontSize: 12.5)),
                const SizedBox(width: 8),
                Text(
                  formatMinutes(e.minutes),
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    e.note ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                ),
                if (!widget.readOnly && (e.userId == me || widget.canManage))
                  IconButton(
                    tooltip: '기록 지우기',
                    visualDensity: VisualDensity.compact,
                    iconSize: 15,
                    onPressed: () => widget.apply(
                      () => widget.session.api!.deleteTimeEntry(task.id, e.id),
                    ),
                    icon: const Icon(Icons.delete_outline),
                  ),
              ],
            ),
          ),
        if (task.timeEntries.length > 5 && !_showAll)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _showAll = true),
              child: Text('기록 모두 보기 (${task.timeEntries.length})'),
            ),
          ),
        if (!widget.readOnly)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('task-add-time'),
              onPressed: _addEntry,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('시간 기록'),
            ),
          ),
      ],
    );
  }
}

// ── 프로젝트 소요 시간 보고 ─────────────────────────────────────────────

/// 프로젝트 소요 시간 보고 창 — 이번 주·이번 달·지난달·올해, 사람별·업무별 합(업무는 예상 대비).
Future<void> showProjectTimeReportDialog(
  BuildContext context,
  Session session,
  Project project,
) => showDialog<void>(
  context: context,
  builder: (_) => _TimeReportDialog(session: session, project: project),
);

class _TimeReportDialog extends StatefulWidget {
  final Session session;
  final Project project;
  const _TimeReportDialog({required this.session, required this.project});

  @override
  State<_TimeReportDialog> createState() => _TimeReportDialogState();
}

class _TimeReportDialogState extends State<_TimeReportDialog> {
  String _range = 'month';
  ProjectTimeReport? _report;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  (DateTime, DateTime) _bounds() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return switch (_range) {
      'week' => (today.subtract(Duration(days: today.weekday - 1)), today),
      'lastMonth' => (
        DateTime(now.year, now.month - 1, 1),
        DateTime(now.year, now.month, 0),
      ),
      'year' => (DateTime(now.year, 1, 1), today),
      _ => (DateTime(now.year, now.month, 1), today),
    };
  }

  Future<void> _load() async {
    final (from, to) = _bounds();
    setState(() {
      _report = null;
      _error = null;
    });
    try {
      final r = await widget.session.api!.fetchTimeReport(
        widget.project.id,
        from: _ymdKey(from),
        to: _ymdKey(to),
      );
      if (mounted) setState(() => _report = r);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final r = _report;
    Widget bar(int minutes, int max) => ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: LinearProgressIndicator(
        value: max == 0 ? 0 : minutes / max,
        minHeight: 6,
      ),
    );
    return AlertDialog(
      title: Text('소요 시간 — ${widget.project.name}'),
      content: SizedBox(
        width: 520,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<String>(
              key: const ValueKey('time-report-range'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'week', label: Text('이번 주')),
                ButtonSegment(value: 'month', label: Text('이번 달')),
                ButtonSegment(value: 'lastMonth', label: Text('지난달')),
                ButtonSegment(value: 'year', label: Text('올해')),
              ],
              selected: {_range},
              onSelectionChanged: (s) {
                setState(() => _range = s.first);
                _load();
              },
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _error != null
                  ? Center(child: Text(_error!))
                  : r == null
                  ? const Center(child: CircularProgressIndicator())
                  : r.totalMinutes == 0
                  ? Center(
                      child: Text(
                        '${r.from} ~ ${r.to}에 기록한 시간이 없습니다.',
                        style: TextStyle(color: hint),
                      ),
                    )
                  : ListView(
                      children: [
                        Text(
                          '${r.from} ~ ${r.to} · 합계 ${formatMinutes(r.totalMinutes)}',
                          key: const ValueKey('time-report-total'),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '사람별',
                          style: TextStyle(color: hint, fontSize: 12),
                        ),
                        for (final m in r.byMember)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 110,
                                  child: Text(
                                    m.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Expanded(
                                  child: bar(
                                    m.minutes,
                                    r.byMember.first.minutes,
                                  ),
                                ),
                                SizedBox(
                                  width: 90,
                                  child: Text(
                                    formatMinutes(m.minutes),
                                    textAlign: TextAlign.right,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 12),
                        Text(
                          '업무별',
                          style: TextStyle(color: hint, fontSize: 12),
                        ),
                        for (final t in r.byTask)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 70,
                                  child: Text(
                                    t.key,
                                    style: TextStyle(fontSize: 12, color: hint),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    t.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  t.estimate == null
                                      ? formatMinutes(t.minutes)
                                      : '${formatMinutes(t.minutes)} / ${formatMinutes(t.estimate!)}',
                                  style: TextStyle(
                                    color:
                                        t.estimate != null &&
                                            t.minutes > t.estimate!
                                        ? theme.colorScheme.error
                                        : null,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}
