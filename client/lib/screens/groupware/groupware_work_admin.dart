import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../models/groupware_work.dart';
import '../../services/groupware_api.dart';
import '../../widgets/app_toast.dart';
import 'approval_forms.dart' show isHmText;
import 'groupware_screen.dart' show GroupwareChanges, GroupwareSectionHeader;
import 'leave_tab.dart' show showLeaveDatesDialog;
import '../../l10n/tr.dart';

/// 관리 탭의 근태·휴가 관리 — 휴가 종류·지출 분류·출근 알림(범위 설정), 유연근무, 주 52시간, 연차 사용 촉진(서버 groupwareWork.js).

// ── 휴가 종류·지출 분류·출근 알림 ─────────────────────────────────────────────

class GroupwareOptionsSection extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareChanges changes;
  final VoidCallback? onChanged;
  const GroupwareOptionsSection({
    super.key,
    required this.api,
    required this.changes,
    this.onChanged,
  });

  @override
  State<GroupwareOptionsSection> createState() =>
      _GroupwareOptionsSectionState();
}

class _GroupwareOptionsSectionState extends State<GroupwareOptionsSection> {
  GroupwareOptions? _options;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final o = await widget.api.options();
      if (mounted) setState(() => _options = o);
    } catch (e) {
      if (mounted) showAppToast(context, tr('설정을 불러오지 못했습니다: {e}', {'e': e}));
    }
  }

  Future<void> _save(
    Future<GroupwareOptions> Function() action,
    String done,
  ) async {
    setState(() => _busy = true);
    try {
      final o = await action();
      if (!mounted) return;
      setState(() => _options = o);
      showAppToast(context, done);
      widget.onChanged?.call();
    } catch (e) {
      if (mounted) showAppToast(context, tr('저장하지 못했습니다: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editLeaveTypes() async {
    final result = await showDialog<List<LeaveTypeInfo>>(
      context: context,
      builder: (_) => _LeaveTypesDialog(types: _options!.leaveTypes),
    );
    if (result == null) return;
    await _save(
      () => widget.api.updateOptions(leaveTypes: result),
      tr('휴가 종류를 저장했습니다.'),
    );
  }

  Future<void> _editCategories() async {
    final result = await showDialog<List<String>>(
      context: context,
      builder: (_) =>
          _CategoriesDialog(categories: _options!.expenseCategories),
    );
    if (result == null) return;
    await _save(
      () => widget.api.updateOptions(expenseCategories: result),
      tr('지출 분류를 저장했습니다.'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final o = _options;
    final hint = Theme.of(context).hintColor;
    if (o == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupwareSectionHeader(tr('휴가 종류·지출 분류')),
        ListTile(
          key: const ValueKey('gw-leave-types'),
          dense: true,
          title: Text(tr('휴가 종류')),
          subtitle: Text(
            o.leaveTypes
                .where((t) => t.enabled)
                .map((t) => t.label)
                .join(' · '),
            style: TextStyle(color: hint),
          ),
          trailing: TextButton(
            onPressed: _busy ? null : _editLeaveTypes,
            child: Text(tr('바꾸기')),
          ),
        ),
        ListTile(
          key: const ValueKey('gw-expense-categories'),
          dense: true,
          title: Text(tr('지출 분류')),
          subtitle: Text(
            o.expenseCategories.join(' · '),
            style: TextStyle(color: hint),
          ),
          trailing: TextButton(
            onPressed: _busy ? null : _editCategories,
            child: Text(tr('바꾸기')),
          ),
        ),
        GroupwareSectionHeader(tr('출근·퇴근 알림')),
        SwitchListTile(
          key: const ValueKey('gw-clock-in-reminder'),
          dense: true,
          title: Text(tr('출근을 안 누르면 알림')),
          subtitle: Text(
            tr(
              '근무 시작 {o.reminderDelayMinutes}분 뒤 — 최근 30일 안에 출퇴근을 쓴 사람에게, 쉬는 날·휴가·출장 빼고',
              {'o.reminderDelayMinutes': o.reminderDelayMinutes},
            ),
            style: TextStyle(color: hint),
          ),
          value: o.clockInReminder,
          onChanged: _busy
              ? null
              : (v) => _save(
                  () => widget.api.updateOptions(clockInReminder: v),
                  v ? tr('출근 알림을 켰습니다.') : tr('출근 알림을 껐습니다.'),
                ),
        ),
        SwitchListTile(
          key: const ValueKey('gw-clock-out-reminder'),
          dense: true,
          title: Text(tr('퇴근을 안 누르면 알림')),
          subtitle: Text(tr('근무 끝 1시간 뒤'), style: TextStyle(color: hint)),
          value: o.clockOutReminder,
          onChanged: _busy
              ? null
              : (v) => _save(
                  () => widget.api.updateOptions(clockOutReminder: v),
                  v ? tr('퇴근 알림을 켰습니다.') : tr('퇴근 알림을 껐습니다.'),
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(tr('출근 알림 시각')),
              const SizedBox(width: 12),
              DropdownButton<int>(
                key: const ValueKey('gw-reminder-delay'),
                value:
                    const [
                      0,
                      5,
                      10,
                      15,
                      30,
                      60,
                    ].contains(o.reminderDelayMinutes)
                    ? o.reminderDelayMinutes
                    : 10,
                items: [
                  for (final m in const [0, 5, 10, 15, 30, 60])
                    DropdownMenuItem(
                      value: m,
                      child: Text(
                        m == 0 ? tr('근무 시작') : tr('근무 시작 {m}분 뒤', {'m': m}),
                      ),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (v) => _save(
                        () => widget.api.updateOptions(reminderDelayMinutes: v),
                        tr('출근 알림 시각을 바꿨습니다.'),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LeaveTypesDialog extends StatefulWidget {
  final List<LeaveTypeInfo> types;
  const _LeaveTypesDialog({required this.types});

  @override
  State<_LeaveTypesDialog> createState() => _LeaveTypesDialogState();
}

class _LeaveTypeDraft {
  final String? key;
  final bool builtin;
  final bool half;
  final TextEditingController label;
  bool enabled;
  bool deducts;
  _LeaveTypeDraft({
    required this.key,
    required this.builtin,
    required this.half,
    required String label,
    required this.enabled,
    required this.deducts,
  }) : label = TextEditingController(text: label);
}

class _LeaveTypesDialogState extends State<_LeaveTypesDialog> {
  late final _drafts = [
    for (final t in widget.types)
      _LeaveTypeDraft(
        key: t.key,
        builtin: t.builtin,
        half: t.half,
        label: t.label,
        enabled: t.enabled,
        deducts: t.deducts,
      ),
  ];
  String? _error;

  @override
  void dispose() {
    for (final d in _drafts) {
      d.label.dispose();
    }
    super.dispose();
  }

  void _save() {
    final out = <LeaveTypeInfo>[];
    for (final d in _drafts) {
      final label = d.label.text.trim();
      if (label.isEmpty) {
        setState(() => _error = tr('휴가 종류 이름을 넣으세요.'));
        return;
      }
      out.add(
        LeaveTypeInfo(
          key: d.key ?? '',
          label: label,
          deducts: d.deducts,
          half: d.half,
          enabled: d.enabled,
          builtin: d.builtin,
        ),
      );
    }
    Navigator.of(context).pop(out);
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return AlertDialog(
      title: Text(tr('휴가 종류')),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tr(
                  '끈 종류는 새로 신청할 수 없고(연차는 끌 수 없음), 이미 올린 신청은 그때 이름 그대로 남습니다. 더한 종류는 하루 단위이고 연차에서 뺄지 고릅니다.',
                ),
                style: TextStyle(fontSize: 12, color: hint),
              ),
              const SizedBox(height: 8),
              for (final (i, d) in _drafts.indexed)
                Row(
                  key: ValueKey('gw-leave-type-$i'),
                  children: [
                    Expanded(
                      child: TextField(
                        key: ValueKey('gw-leave-type-$i-label'),
                        controller: d.label,
                        maxLength: 20,
                        decoration: InputDecoration(
                          isDense: true,
                          counterText: '',
                          helperText: d.builtin ? null : tr('더한 종류'),
                        ),
                      ),
                    ),
                    if (!d.builtin)
                      Column(
                        children: [
                          Text(tr('연차 차감'), style: TextStyle(fontSize: 11)),
                          Checkbox(
                            key: ValueKey('gw-leave-type-$i-deducts'),
                            value: d.deducts,
                            onChanged: (v) =>
                                setState(() => d.deducts = v ?? false),
                          ),
                        ],
                      ),
                    Switch(
                      key: ValueKey('gw-leave-type-$i-enabled'),
                      value: d.enabled,
                      onChanged: d.key == 'annual'
                          ? null
                          : (v) => setState(() => d.enabled = v),
                    ),
                  ],
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('gw-leave-type-add'),
                  onPressed: () => setState(
                    () => _drafts.add(
                      _LeaveTypeDraft(
                        key: null,
                        builtin: false,
                        half: false,
                        label: '',
                        enabled: true,
                        deducts: false,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(tr('종류 더하기')),
                ),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('gw-leave-types-save'),
          onPressed: _save,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}

class _CategoriesDialog extends StatefulWidget {
  final List<String> categories;
  const _CategoriesDialog({required this.categories});

  @override
  State<_CategoriesDialog> createState() => _CategoriesDialogState();
}

class _CategoriesDialogState extends State<_CategoriesDialog> {
  late final _list = [...widget.categories];
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _add() {
    final v = _input.text.trim();
    if (v.isEmpty || _list.contains(v)) return;
    setState(() {
      _list.add(v);
      _input.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('지출 분류')),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final c in _list)
                  InputChip(
                    key: ValueKey('gw-category-$c'),
                    label: Text(c),
                    onDeleted: _list.length <= 1
                        ? null
                        : () => setState(() => _list.remove(c)),
                  ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('gw-category-input'),
                    controller: _input,
                    maxLength: 20,
                    decoration: InputDecoration(
                      labelText: tr('분류 더하기'),
                      counterText: '',
                    ),
                    onSubmitted: (_) => _add(),
                  ),
                ),
                IconButton(
                  key: const ValueKey('gw-category-add'),
                  tooltip: tr('더하기'),
                  icon: const Icon(Icons.add),
                  onPressed: _add,
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('gw-categories-save'),
          onPressed: () => Navigator.of(context).pop(_list),
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}

// ── 유연근무 ─────────────────────────────────────────────────────────────

class WorkSchedulesSection extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  const WorkSchedulesSection({super.key, required this.api, required this.ctx});

  @override
  State<WorkSchedulesSection> createState() => _WorkSchedulesSectionState();
}

class _WorkSchedulesSectionState extends State<WorkSchedulesSection> {
  List<MemberSchedule>? _members;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final m = await widget.api.schedules();
      if (mounted) setState(() => _members = m);
    } catch (_) {}
  }

  Future<void> _edit(MemberSchedule m) async {
    final result = await showDialog<Object>(
      context: context,
      builder: (_) => _ScheduleDialog(member: m, ctx: widget.ctx),
    );
    if (result == null || !mounted) return;
    try {
      if (result == 'default') {
        await widget.api.clearSchedule(m.userId);
      } else {
        final r =
            result
                as ({
                  String mode,
                  String? start,
                  String? end,
                  String? coreStart,
                  String? coreEnd,
                });
        await widget.api.setSchedule(
          m.userId,
          mode: r.mode,
          start: r.start,
          end: r.end,
          coreStart: r.coreStart,
          coreEnd: r.coreEnd,
        );
      }
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final members = _members;
    final hint = Theme.of(context).hintColor;
    if (members == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupwareSectionHeader(tr('유연근무')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            tr(
              '사람마다 근무 형태를 정합니다 — 시차출퇴근(자기 출근·퇴근 시각), 선택근무(핵심 시간대만 지각·조퇴), 자율 출퇴근(지각·조퇴를 세지 않음). 정하지 않으면 위 근무 시간입니다.',
            ),
            style: TextStyle(fontSize: 12, color: hint),
          ),
        ),
        for (final m in members)
          ListTile(
            key: ValueKey('gw-schedule-${m.userId}'),
            dense: true,
            title: Text(m.name),
            subtitle: Text(
              m.schedule?.description ??
                  tr('기본 {p0}~{p1}', {
                    'p0': minutesText(widget.ctx.workStart),
                    'p1': minutesText(widget.ctx.workEnd),
                  }),
              style: TextStyle(color: hint),
            ),
            trailing: const Icon(Icons.edit_outlined, size: 18),
            onTap: () => _edit(m),
          ),
      ],
    );
  }
}

class _ScheduleDialog extends StatefulWidget {
  final MemberSchedule member;
  final GroupwareContext ctx;
  const _ScheduleDialog({required this.member, required this.ctx});

  @override
  State<_ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends State<_ScheduleDialog> {
  late String _mode = widget.member.schedule?.mode ?? 'staggered';
  late final _start = TextEditingController(
    text: minutesText(widget.member.schedule?.start ?? widget.ctx.workStart),
  );
  late final _end = TextEditingController(
    text: minutesText(widget.member.schedule?.end ?? widget.ctx.workEnd),
  );
  late final _coreStart = TextEditingController(
    text: minutesText(widget.member.schedule?.coreStart ?? 10 * 60),
  );
  late final _coreEnd = TextEditingController(
    text: minutesText(widget.member.schedule?.coreEnd ?? 15 * 60),
  );
  String? _error;

  @override
  void dispose() {
    for (final c in [_start, _end, _coreStart, _coreEnd]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (_mode == 'staggered' &&
        (!isHmText(_start.text) || !isHmText(_end.text))) {
      setState(() => _error = tr('출근·퇴근 시각을 HH:MM으로 넣으세요.'));
      return;
    }
    if (_mode == 'core' &&
        (!isHmText(_coreStart.text) || !isHmText(_coreEnd.text))) {
      setState(() => _error = tr('핵심 시간대를 HH:MM으로 넣으세요.'));
      return;
    }
    Navigator.of(context).pop((
      mode: _mode,
      start: _mode == 'staggered' ? _start.text.trim() : null,
      end: _mode == 'staggered' ? _end.text.trim() : null,
      coreStart: _mode == 'core' ? _coreStart.text.trim() : null,
      coreEnd: _mode == 'core' ? _coreEnd.text.trim() : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    Widget times(
      TextEditingController a,
      TextEditingController b,
      String la,
      String lb,
      String key,
    ) => Row(
      children: [
        Expanded(
          child: TextField(
            key: ValueKey('$key-a'),
            controller: a,
            decoration: InputDecoration(labelText: la, isDense: true),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Text('~'),
        ),
        Expanded(
          child: TextField(
            key: ValueKey('$key-b'),
            controller: b,
            decoration: InputDecoration(labelText: lb, isDense: true),
          ),
        ),
      ],
    );
    return AlertDialog(
      title: Text(
        tr('{widget.member.name} 근무 형태', {
          'widget.member.name': widget.member.name,
        }),
      ),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<String>(
              key: const ValueKey('gw-schedule-mode'),
              segments: [
                ButtonSegment(value: 'staggered', label: Text(tr('시차출퇴근'))),
                ButtonSegment(value: 'core', label: Text(tr('선택근무'))),
                ButtonSegment(value: 'free', label: Text(tr('자율'))),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 12),
            if (_mode == 'staggered')
              times(
                _start,
                _end,
                tr('출근 (HH:MM)'),
                tr('퇴근 (HH:MM)'),
                'gw-schedule-hours',
              ),
            if (_mode == 'core')
              times(
                _coreStart,
                _coreEnd,
                tr('핵심 시작'),
                tr('핵심 끝'),
                'gw-schedule-core',
              ),
            if (_mode == 'free')
              Text(tr('지각·조퇴를 세지 않습니다. 근로시간(주 52시간)은 그대로 셉니다.')),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        if (widget.member.schedule != null)
          TextButton(
            key: const ValueKey('gw-schedule-default'),
            onPressed: () => Navigator.of(context).pop('default'),
            child: Text(tr('기본으로')),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('gw-schedule-save'),
          onPressed: _save,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}

// ── 주 52시간 ─────────────────────────────────────────────────────────────

class WeeklyHoursSection extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  const WeeklyHoursSection({super.key, required this.api, required this.ctx});

  @override
  State<WeeklyHoursSection> createState() => _WeeklyHoursSectionState();
}

class _WeeklyHoursSectionState extends State<WeeklyHoursSection> {
  late String _day = widget.ctx.today;
  ({String weekStart, String weekEnd, List<WeeklyMember> members})? _week;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final w = await widget.api.weekly(_day);
      if (mounted) setState(() => _week = w);
    } catch (_) {}
  }

  void _shift(int weeks) {
    final next = DateTime.parse(_day).add(Duration(days: 7 * weeks));
    final limit = DateTime.parse(widget.ctx.today).add(const Duration(days: 6));
    if (next.isAfter(limit)) return;
    _day = dateKeyOf(next);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final w = _week;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupwareSectionHeader(
          tr('주 52시간'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: tr('지난주'),
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _shift(-1),
              ),
              Text(
                w == null
                    ? ''
                    : '${shortDateText(w.weekStart)}~${shortDateText(w.weekEnd)}',
                key: const ValueKey('gw-weekly-range'),
              ),
              IconButton(
                tooltip: tr('다음 주'),
                icon: const Icon(Icons.chevron_right),
                onPressed: () => _shift(1),
              ),
            ],
          ),
        ),
        if (w != null)
          for (final m in w.members)
            ListTile(
              key: ValueKey('gw-weekly-${m.userId}'),
              dense: true,
              title: Text(m.name),
              subtitle: Text(
                [
                  tr('실근로 {p0}', {'p0': durationText(m.hours.netMinutes)}),
                  if (m.hours.overtimeMinutes > 0)
                    tr('연장 {p0}', {
                      'p0': durationText(m.hours.overtimeMinutes),
                    }),
                  if (m.hours.holidayMinutes > 0)
                    tr('휴일 {p0}', {'p0': durationText(m.hours.holidayMinutes)}),
                  if (m.hours.nightMinutes > 0)
                    tr('야간 {p0}', {'p0': durationText(m.hours.nightMinutes)}),
                ].join(' · '),
              ),
              trailing: m.hours.status == 'ok'
                  ? null
                  : Text(
                      m.hours.status == 'over' ? tr('52시간 넘음') : tr('48시간 넘음'),
                      style: TextStyle(
                        color: m.hours.status == 'over'
                            ? theme.colorScheme.error
                            : Colors.orange.shade800,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
      ],
    );
  }
}

// ── 연차 사용 촉진 ───────────────────────────────────────────────────────

class LeavePromotionSection extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final GroupwareChanges changes;
  const LeavePromotionSection({
    super.key,
    required this.api,
    required this.ctx,
    required this.changes,
  });

  @override
  State<LeavePromotionSection> createState() => _LeavePromotionSectionState();
}

class _LeavePromotionSectionState extends State<LeavePromotionSection> {
  List<PromotionMember>? _members;
  final _selected = <String>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.changes.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final m = await widget.api.promotions();
      if (mounted) {
        setState(() {
          _members = m;
          _selected.removeWhere(
            (id) => !m.any(
              (x) => x.userId == id && x.stage == PromotionStage.first,
            ),
          );
        });
      }
    } catch (_) {}
  }

  Future<void> _sendFirst() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('1차 촉진 보내기')),
        content: Text(
          tr(
            '{_selected.length}명에게 남은 연차를 알리고 10일 안에 쓸 날을 내라고 요구합니다. 보낸 기록은 지워지지 않습니다.',
            {'_selected.length': _selected.length},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('취소')),
          ),
          FilledButton(
            key: const ValueKey('gw-promotion-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('보내기')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await widget.api.sendPromotion(_selected.toList());
      if (!mounted) return;
      showAppToast(
        context,
        tr('{r.sent}명에게 보냈습니다.{p0}', {
          'r.sent': r.sent,
          'p0': r.skipped.isEmpty
              ? ''
              : tr(' ({r.skipped.length}명 건너뜀: {r.skipped.first})', {
                  'r.skipped.length': r.skipped.length,
                  'r.skipped.first': r.skipped.first,
                }),
        }),
      );
      _selected.clear();
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendSecond(PromotionMember m) async {
    final dates = await showLeaveDatesDialog(
      context,
      title: tr('{m.name} — 회사가 정할 연차 날', {'m.name': m.name}),
      from: dateKeyOf(
        DateTime.parse(widget.ctx.today).add(const Duration(days: 1)),
      ),
      to: m.expiry,
      maxDays: m.remainingHalfDays ~/ 2,
    );
    if (dates == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.sendSecondPromotion(m.userId, dates);
      if (mounted) {
        showAppToast(
          context,
          tr('{m.name}님에게 2차 촉진(사용 시기 지정)을 보냈습니다.', {'m.name': m.name}),
        );
      }
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _noticeText(PromotionMember m) {
    final first = m.notices.where((n) => n.stage == 1).firstOrNull;
    final second = m.notices.where((n) => n.stage == 2).firstOrNull;
    return [
      tr('남은 {p0} · 만료 {m.expiry}', {
        'p0': halfDaysText(m.remainingHalfDays),
        'm.expiry': m.expiry,
      }),
      if (first == null && m.stage == PromotionStage.first)
        tr('1차 {m.firstStart}~{m.firstEnd}', {
          'm.firstStart': m.firstStart,
          'm.firstEnd': m.firstEnd,
        }),
      if (first == null && m.stage == PromotionStage.upcoming)
        tr('1차 {m.firstStart}부터', {'m.firstStart': m.firstStart}),
      if (first != null)
        tr('1차 보냄{p0}{p1}', {
          'p0': first.readAt != null ? tr('·확인함') : '',
          'p1': first.planDates.isNotEmpty
              ? tr('·계획 {first.planDates.length}일', {
                  'first.planDates.length': first.planDates.length,
                })
              : '',
        }),
      if (second != null)
        tr('2차 지정 {second.designatedDates.length}일', {
          'second.designatedDates.length': second.designatedDates.length,
        }),
      if (first != null && second == null && first.planDates.isEmpty)
        tr('2차 마감 {m.secondDeadline}', {'m.secondDeadline': m.secondDeadline}),
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final members = _members;
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    if (members == null) return const SizedBox.shrink();
    Color stageColor(PromotionStage s) => switch (s) {
      PromotionStage.first || PromotionStage.second => theme.colorScheme.error,
      PromotionStage.awaiting => Colors.orange.shade800,
      PromotionStage.missed => theme.colorScheme.error.withValues(alpha: 0.6),
      _ => hint,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupwareSectionHeader(
          tr('연차 사용 촉진'),
          trailing: FilledButton(
            key: const ValueKey('gw-promotion-send'),
            onPressed: _busy || _selected.isEmpty ? null : _sendFirst,
            child: Text(
              tr('1차 보내기 ({_selected.length})', {
                '_selected.length': _selected.length,
              }),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            tr(
              '근로기준법 제61조 — 연차 기간 만료 6개월 전(입사 첫해는 3개월 전)을 기준으로 10일 안에 1차(남은 연차를 알리고 쓸 날을 내라고 요구), 받은 사람이 10일 안에 내지 않으면 만료 2개월 전(첫해는 1개월 전)까지 2차(회사가 쓸 날을 정함)를 보냅니다. 보낸·확인한·낸 시각이 남습니다. 전자 통지를 서면으로 인정하는지는 노무 담당과 확인하세요.',
            ),
            style: TextStyle(fontSize: 12, color: hint),
          ),
        ),
        if (members.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              tr('입사일이 있는 구성원이 없습니다.'),
              style: TextStyle(color: hint),
            ),
          ),
        for (final m in members)
          ListTile(
            key: ValueKey('gw-promotion-${m.userId}'),
            dense: true,
            leading: m.stage == PromotionStage.first
                ? Checkbox(
                    key: ValueKey('gw-promotion-select-${m.userId}'),
                    value: _selected.contains(m.userId),
                    onChanged: (v) => setState(
                      () => v == true
                          ? _selected.add(m.userId)
                          : _selected.remove(m.userId),
                    ),
                  )
                : const SizedBox(width: 40),
            title: Row(
              children: [
                Flexible(child: Text(m.name, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 8),
                Text(
                  m.stage.label,
                  style: TextStyle(
                    fontSize: 12,
                    color: stageColor(m.stage),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            subtitle: Text(
              _noticeText(m),
              style: TextStyle(fontSize: 12, color: hint),
            ),
            trailing: m.stage == PromotionStage.second
                ? TextButton(
                    key: ValueKey('gw-promotion-second-${m.userId}'),
                    onPressed: _busy ? null : () => _sendSecond(m),
                    child: Text(tr('2차 통보')),
                  )
                : null,
          ),
      ],
    );
  }
}
