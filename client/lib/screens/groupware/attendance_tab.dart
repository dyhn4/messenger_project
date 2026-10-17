import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import 'approval_forms.dart';
import 'groupware_screen.dart';

const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

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
    setState(() => _busy = true);
    try {
      final record = clockIn
          ? await widget.api.clockIn()
          : await widget.api.clockOut();
      if (!mounted) return;
      showAppToast(
        context,
        clockIn
            ? '${clockText(record.clockInAt)} 출근했습니다.${record.late ? ' (지각)' : ''}'
            : '${clockText(record.clockOutAt)} 퇴근했습니다.${record.workedMinutes != null ? ' 오늘 ${(record.workedMinutes! / 60).toStringAsFixed(1)}시간' : ''}',
      );
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '실패: $e');
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
            busy: _busy,
            onClockIn: () => _clock(true),
            onClockOut: () => _clock(false),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
            child: Row(
              children: [
                IconButton(
                  tooltip: '이전 달',
                  onPressed: () => _shiftMonth(-1),
                  icon: const Icon(Icons.chevron_left),
                ),
                Text(
                  '${_monthKey.substring(0, 4)}년 ${int.parse(_monthKey.substring(5))}월',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                IconButton(
                  tooltip: '다음 달',
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
  final bool busy;
  final VoidCallback onClockIn;
  final VoidCallback onClockOut;
  const _TodayCard({
    required this.today,
    required this.busy,
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
                    '오늘 ${shortDateText(today.today)}',
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
                  today.inLan ? '사내 와이파이' : '사내 와이파이 아님',
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '근무 시간 ${minutesText(today.workStart)} ~ ${minutesText(today.workEnd)}'
              '${record == null ? '' : ' · 출근 ${clockText(record.clockInAt)} · 퇴근 ${clockText(record.clockOutAt)}'}'
              '${today.openRecord != null ? ' (어제 출근)' : ''}',
              style: TextStyle(color: hint),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('attendance-clock-in'),
                    onPressed: busy || !today.canClockIn ? null : onClockIn,
                    icon: const Icon(Icons.login),
                    label: const Text('출근'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('attendance-clock-out'),
                    onPressed: busy || !today.canClockOut ? null : onClockOut,
                    icon: const Icon(Icons.logout),
                    label: const Text('퇴근'),
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
      '출근 ${summary.daysWorked}일',
      '근무 ${summary.hoursText}',
      if (summary.late > 0) '지각 ${summary.late}',
      if (summary.earlyLeave > 0) '조퇴 ${summary.earlyLeave}',
      if (summary.missingClockOut > 0) '퇴근 누락 ${summary.missingClockOut}',
      if (summary.absent > 0) '결근 ${summary.absent}',
      if (summary.leaveHalfDays > 0)
        '휴가 ${halfDaysText(summary.leaveHalfDays)}',
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
      if (day.leaveType != null) ctx.leaveType(day.leaveType)?.label ?? '휴가',
      if (record?.late ?? false) '지각',
      if (record?.earlyLeave ?? false) '조퇴',
      if (record?.missingClockOut ?? false) '퇴근 누락',
      if (record?.corrected ?? false) '결재로 고침',
      if (record?.clockInLan == false) '밖에서 출근',
    ];
    return ListTile(
      key: ValueKey('attendance-day-${day.date}'),
      dense: true,
      leading: SizedBox(
        width: 44,
        child: Text(
          '${date.day}일 ${_weekdays[date.weekday - 1]}',
          style: TextStyle(
            color: off ? theme.colorScheme.error : null,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      title: Text(
        record == null
            ? (off || day.leaveType != null ? '' : '기록 없음')
            : '${clockText(record.clockInAt)} ~ ${clockText(record.clockOutAt)}',
      ),
      subtitle: marks.isEmpty
          ? null
          : Text(marks.join(' · '), style: TextStyle(color: hint)),
      trailing: onFix == null
          ? null
          : TextButton(onPressed: onFix, child: const Text('수정 요청')),
    );
  }
}
