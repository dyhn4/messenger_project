import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import 'approval_forms.dart';
import 'groupware_screen.dart';
import '../../l10n/tr.dart';

final _weekdays = [
  tr('월'),
  tr('화'),
  tr('수'),
  tr('목'),
  tr('금'),
  tr('토'),
  tr('일'),
];

/// 출퇴근 탭 — 오늘 출근·퇴근 단추(사내 와이파이에서 눌렀는지 함께 남는다 — 위치 정보는 받지 않는다), 한 달 기록과 요약,
/// 날마다 "수정 요청"(근태 수정 결재).
class AttendanceTab extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final GroupwareChanges changes;
  final Session session;
  const AttendanceTab({
    super.key,
    required this.api,
    required this.ctx,
    required this.changes,
    required this.session,
  });

  @override
  State<AttendanceTab> createState() => _AttendanceTabState();
}

class _AttendanceTabState extends State<AttendanceTab> {
  AttendanceToday? _today;
  AttendanceMonth? _month;
  late String _monthKey = widget.ctx.today.substring(0, 7);
  bool _busy = false;
  String? _error;

  /// 출근 형태 — 'office' | 'field'(외근 — 장소를 적는다) | 'remote'(재택).
  String _mode = 'office';
  final _place = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.changes.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.changes.removeListener(_load);
    _place.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.api.attendanceToday(),
        widget.api.attendanceMonth(_monthKey),
      ]);
      if (!mounted) return;
      setState(() {
        _today = results[0] as AttendanceToday;
        _month = results[1] as AttendanceMonth;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _clock(bool clockIn) async {
    if (clockIn && _mode == 'field' && _place.text.trim().isEmpty) {
      showAppToast(context, tr('외근 장소(어디서 일하는지)를 적으세요.'));
      return;
    }
    setState(() => _busy = true);
    try {
      final record = clockIn
          ? await widget.api.clockIn(
              mode: _mode,
              note: _mode == 'field' ? _place.text.trim() : null,
            )
          : await widget.api.clockOut();
      if (!mounted) return;
      showAppToast(
        context,
        clockIn
            ? tr('{p0} 출근했습니다.{p1}', {
                'p0': clockText(record.clockInAt),
                'p1': record.late ? tr(' (지각)') : '',
              })
            : tr('{p0} 퇴근했습니다.{p1}', {
                'p0': clockText(record.clockOutAt),
                'p1': record.workedMinutes != null
                    ? tr(' 오늘 {p0}시간', {
                        'p0': (record.workedMinutes! / 60).toStringAsFixed(1),
                      })
                    : '',
              }),
      );
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _shiftMonth(int delta) {
    final parts = _monthKey.split('-');
    final next = DateTime(int.parse(parts[0]), int.parse(parts[1]) + delta);
    setState(() {
      _monthKey = '${next.year}-${next.month.toString().padLeft(2, '0')}';
      _month = null;
    });
    _load();
  }

  Future<void> _requestFix(AttendanceDay day) async {
    final doc = await showAttendanceCorrectionDialog(
      context,
      api: widget.api,
      ctx: widget.ctx,
      workDate: day.date,
      record: day.record,
    );
    if (!mounted || doc == null) return;
    toastSubmitted(context, doc);
    widget.changes.bump();
  }

  /// 수정 요청을 올릴 수 있는 날 — 오늘 포함 지난 60일(서버 approvalRules.js ATTENDANCE_FIX_DAYS).
  bool _fixable(String date) {
    final today = DateTime.parse(widget.ctx.today);
    final day = DateTime.parse(date);
    return !day.isAfter(today) && today.difference(day).inDays < 60;
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return GroupwareEmpty(_error!);
    final today = _today;
    if (today == null) return const Center(child: CircularProgressIndicator());
    final month = _month;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          _TodayCard(
            today: today,
            ctx: widget.ctx,
            busy: _busy,
            mode: _mode,
            place: _place,
            onMode: (m) => setState(() => _mode = m),
            onClockIn: () => _clock(true),
            onClockOut: () => _clock(false),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
            child: Row(
              children: [
                IconButton(
                  tooltip: tr('이전 달'),
                  onPressed: () => _shiftMonth(-1),
                  icon: const Icon(Icons.chevron_left),
                ),
                Text(
                  tr('{p0}년 {p1}월', {
                    'p0': _monthKey.substring(0, 4),
                    'p1': int.parse(_monthKey.substring(5)),
                  }),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                IconButton(
                  tooltip: tr('다음 달'),
                  onPressed: () => _shiftMonth(1),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
          if (month == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            _SummaryRow(summary: month.summary),
            if (month.weeks.isNotEmpty)
              _WeeksCard(weeks: month.weeks, ctx: widget.ctx),
            for (final day in month.days.reversed)
              if (!day.date.startsWith(today.today.substring(0, 7)) ||
                  day.date.compareTo(today.today) <= 0)
                _DayTile(
                  day: day,
                  ctx: widget.ctx,
                  onFix: _fixable(day.date) ? () => _requestFix(day) : null,
                ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _TodayCard extends StatelessWidget {
  final AttendanceToday today;
  final GroupwareContext ctx;
  final bool busy;
  final String mode;
  final TextEditingController place;
  final ValueChanged<String> onMode;
  final VoidCallback onClockIn;
  final VoidCallback onClockOut;
  const _TodayCard({
    required this.today,
    required this.ctx,
    required this.busy,
    required this.mode,
    required this.place,
    required this.onMode,
    required this.onClockIn,
    required this.onClockOut,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final record = today.record ?? today.openRecord;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr('오늘 {p0}', {'p0': shortDateText(today.today)}),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Icon(
                  today.inLan ? Icons.wifi : Icons.wifi_off,
                  size: 16,
                  color: today.inLan ? Colors.green.shade700 : hint,
                ),
                const SizedBox(width: 4),
                Text(
                  today.inLan ? tr('사내 와이파이') : tr('사내 와이파이 아님'),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              tr('근무 시간 {p0} ~ {p1}{p2}{p3}', {
                'p0': minutesText(today.workStart),
                'p1': minutesText(today.workEnd),
                'p2': record == null
                    ? ''
                    : tr(' · 출근 {p0} · 퇴근 {p1}', {
                        'p0': clockText(record.clockInAt),
                        'p1': clockText(record.clockOutAt),
                      }),
                'p3': today.openRecord != null ? tr(' (어제 출근)') : '',
              }),
              style: TextStyle(color: hint),
            ),
            if (ctx.schedule != null)
              Text(
                tr('근무 형태: {p0}', {'p0': ctx.schedule!.description}),
                key: const ValueKey('attendance-schedule'),
                style: TextStyle(fontSize: 12, color: hint),
              ),
            if (record != null && record.clockInMode != 'office')
              Text(
                '${clockInModeLabels[record.clockInMode] ?? ''}${record.note == null ? '' : ': ${record.note}'}',
                style: TextStyle(fontSize: 12, color: hint),
              ),
            if (today.week case final week?) ...[
              const SizedBox(height: 10),
              _WeekBar(week: week, ctx: ctx),
            ],
            if (today.canClockIn) ...[
              const SizedBox(height: 12),
              SegmentedButton<String>(
                key: const ValueKey('attendance-mode'),
                segments: [
                  for (final e in clockInModeLabels.entries)
                    ButtonSegment(value: e.key, label: Text(e.value)),
                ],
                selected: {mode},
                onSelectionChanged: (s) => onMode(s.first),
              ),
              if (mode == 'field')
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextField(
                    key: const ValueKey('attendance-place'),
                    controller: place,
                    maxLength: 200,
                    decoration: InputDecoration(
                      labelText: tr('외근 장소'),
                      hintText: tr('예: 고객사(판교)'),
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('attendance-clock-in'),
                    onPressed: busy || !today.canClockIn ? null : onClockIn,
                    icon: const Icon(Icons.login),
                    label: Text(tr('출근')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('attendance-clock-out'),
                    onPressed: busy || !today.canClockOut ? null : onClockOut,
                    icon: const Icon(Icons.logout),
                    label: Text(tr('퇴근')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final AttendanceSummary summary;
  const _SummaryRow({required this.summary});

  @override
  Widget build(BuildContext context) {
    final items = [
      tr('출근 {summary.daysWorked}일', {
        'summary.daysWorked': summary.daysWorked,
      }),
      tr('근무 {summary.hoursText}', {'summary.hoursText': summary.hoursText}),
      if (summary.late > 0)
        tr('지각 {summary.late}', {'summary.late': summary.late}),
      if (summary.earlyLeave > 0)
        tr('조퇴 {summary.earlyLeave}', {
          'summary.earlyLeave': summary.earlyLeave,
        }),
      if (summary.missingClockOut > 0)
        tr('퇴근 누락 {summary.missingClockOut}', {
          'summary.missingClockOut': summary.missingClockOut,
        }),
      if (summary.absent > 0)
        tr('결근 {summary.absent}', {'summary.absent': summary.absent}),
      if (summary.leaveHalfDays > 0)
        tr('휴가 {p0}', {'p0': halfDaysText(summary.leaveHalfDays)}),
      if (summary.tripDays > 0)
        tr('출장 {summary.tripDays}일', {'summary.tripDays': summary.tripDays}),
      if (summary.overtimeMinutes > 0)
        tr('연장근무 신청 {summary.overtimeText}', {
          'summary.overtimeText': summary.overtimeText,
        }),
      if (summary.netMinutes > 0)
        tr('실근로 {p0}', {'p0': durationText(summary.netMinutes)}),
      if (summary.actualOvertimeMinutes > 0)
        tr('연장 {p0}', {'p0': durationText(summary.actualOvertimeMinutes)}),
      if (summary.nightMinutes > 0)
        tr('야간 {p0}', {'p0': durationText(summary.nightMinutes)}),
      if (summary.holidayWorkMinutes > 0)
        tr('휴일 {p0}', {'p0': durationText(summary.holidayWorkMinutes)}),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final i in items)
            Chip(label: Text(i), visualDensity: VisualDensity.compact),
        ],
      ),
    );
  }
}

class _DayTile extends StatelessWidget {
  final AttendanceDay day;
  final GroupwareContext ctx;
  final VoidCallback? onFix;
  const _DayTile({required this.day, required this.ctx, required this.onFix});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final date = DateTime.parse(day.date);
    final record = day.record;
    final off = day.weekend || day.holiday != null;
    final marks = [
      if (day.holiday != null) day.holiday!,
      if (day.leaveType != null)
        ctx.leaveType(day.leaveType)?.label ?? tr('휴가'),
      if (day.trip) tr('출장'),
      if (record != null && record.clockInMode != 'office')
        '${clockInModeLabels[record.clockInMode] ?? ''}${record.note == null ? '' : '(${record.note})'}',
      if (record != null && record.breakdown.overtimeMinutes > 0)
        tr('연장 {p0}', {'p0': durationText(record.breakdown.overtimeMinutes)}),
      if (record != null && record.breakdown.nightMinutes > 0)
        tr('야간 {p0}', {'p0': durationText(record.breakdown.nightMinutes)}),
      if (record != null && record.breakdown.holidayMinutes > 0)
        tr('휴일 {p0}', {'p0': durationText(record.breakdown.holidayMinutes)}),
      if (day.overtimeMinutes > 0)
        tr('연장근무 {p0}', {
          'p0': AttendanceSummary(
            overtimeMinutes: day.overtimeMinutes,
          ).overtimeText,
        }),
      if (record?.late ?? false) tr('지각'),
      if (record?.earlyLeave ?? false) tr('조퇴'),
      if (record?.missingClockOut ?? false) tr('퇴근 누락'),
      if (record?.corrected ?? false) tr('결재로 고침'),
      if (record?.clockInLan == false) tr('밖에서 출근'),
    ];
    return ListTile(
      key: ValueKey('attendance-day-${day.date}'),
      dense: true,
      leading: SizedBox(
        width: 44,
        child: Text(
          tr('{date.day}일 {p0}', {
            'date.day': date.day,
            'p0': _weekdays[date.weekday - 1],
          }),
          style: TextStyle(
            color: off ? theme.colorScheme.error : null,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      title: Text(
        record == null
            ? (off || day.leaveType != null || day.trip ? '' : tr('기록 없음'))
            : '${clockText(record.clockInAt)} ~ ${clockText(record.clockOutAt)}',
      ),
      subtitle: marks.isEmpty
          ? null
          : Text(marks.join(' · '), style: TextStyle(color: hint)),
      trailing: onFix == null
          ? null
          : TextButton(onPressed: onFix, child: Text(tr('수정 요청'))),
    );
  }
}

/// 이번 주 근로시간 막대 — 주 52시간(48시간부터 주의 색, 넘으면 빨강).
class _WeekBar extends StatelessWidget {
  final WeeklyHours week;
  final GroupwareContext ctx;
  const _WeekBar({required this.week, required this.ctx});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (week.status) {
      'over' => theme.colorScheme.error,
      'warn' => Colors.orange.shade700,
      _ => theme.colorScheme.primary,
    };
    final ratio = (week.netMinutes / ctx.weeklyLimitMinutes).clamp(0.0, 1.0);
    return Column(
      key: const ValueKey('attendance-week'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                tr('이번 주 {p0} / {p1}시간', {
                  'p0': durationText(week.netMinutes),
                  'p1': ctx.weeklyLimitMinutes ~/ 60,
                }),
                style: TextStyle(fontSize: 12, color: color),
              ),
            ),
            if (week.status != 'ok')
              Text(
                week.status == 'over' ? tr('주 52시간 넘음') : tr('52시간에 가까움'),
                style: TextStyle(
                  fontSize: 12,
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: ratio,
          color: color,
          backgroundColor: color.withValues(alpha: 0.15),
        ),
      ],
    );
  }
}

/// 이 달에 걸친 주마다의 근로시간.
class _WeeksCard extends StatelessWidget {
  final List<WeeklyHours> weeks;
  final GroupwareContext ctx;
  const _WeeksCard({required this.weeks, required this.ctx});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr('주마다(주 52시간)'), style: TextStyle(fontSize: 12, color: hint)),
          for (final w in weeks)
            Padding(
              key: ValueKey('attendance-week-${w.weekStart}'),
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(
                    width: 96,
                    child: Text(
                      '${shortDateText(w.weekStart)}~${shortDateText(w.weekEnd)}',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      [
                        durationText(w.netMinutes),
                        if (w.overtimeMinutes > 0)
                          tr('연장 {p0}', {
                            'p0': durationText(w.overtimeMinutes),
                          }),
                        if (w.holidayMinutes > 0)
                          tr('휴일 {p0}', {'p0': durationText(w.holidayMinutes)}),
                      ].join(' · '),
                      style: TextStyle(
                        fontSize: 13,
                        color: w.status == 'over'
                            ? theme.colorScheme.error
                            : (w.status == 'warn'
                                  ? Colors.orange.shade800
                                  : null),
                      ),
                    ),
                  ),
                  if (w.status == 'over')
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: theme.colorScheme.error,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
