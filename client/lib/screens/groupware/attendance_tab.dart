import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/groupware.dart';
import '../../services/device_location.dart';
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

/// 주 상한에서 "가까움"(주의 색)이 시작되는 폭 — 52시간이면 48시간부터(서버 workPolicy.js WARN_GAP과 같다).
const _weeklyWarnGapMinutes = 4 * 60;

/// 이번 주 상태를 이 사람의 주 상한으로 다시 가린다 — 서버의 [WeeklyHours.status]는 52시간 기준이라 탄력(60·64시간)이면 너무 일찍
/// 빨개진다. 상한이 없으면(선택근무 — 정산 기간으로 본다) 늘 'ok'.
String _weekStatus(int netMinutes, int? limitMinutes) {
  if (limitMinutes == null) return 'ok';
  if (netMinutes > limitMinutes) return 'over';
  if (netMinutes >= limitMinutes - _weeklyWarnGapMinutes) return 'warn';
  return 'ok';
}

/// 출퇴근 탭 — 오늘 출근·퇴근 단추(사내 와이파이에서 눌렀는지, 기기 위치를 보낼 수 있으면 위치도 함께 남는다 — 누를 때 한 번만 재고
/// 따라다니지 않는다), 휴게 시작·끝, 이번 주 근로시간(이 사람의 주 상한 — 탄력·선택근무면 다름)과 주 52시간 지키기 안내, 탄력·선택근무
/// 기간, 한 달 기록과 요약·가산 수당(참고용), 날마다 "수정 요청"(근태 수정 결재).
class AttendanceTab extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final GroupwareChanges changes;
  final Session session;

  /// 위치를 재는 것 — 없으면 [DeviceLocation.instance](테스트는 가짜를 넣는다).
  final DeviceLocation? location;
  const AttendanceTab({
    super.key,
    required this.api,
    required this.ctx,
    required this.changes,
    required this.session,
    this.location,
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

  /// 위치를 재는 중인지(출근·퇴근 단추 아래 작은 진행 표시).
  bool _locating = false;

  /// 출근·퇴근·휴게가 서버에서 막힌 까닭(주 52시간 지키기 409 등 — 서버 문구 그대로). 다음에 누르면 지운다.
  String? _notice;

  /// 출근 형태 — 'office' | 'field'(외근 — 장소를 적는다) | 'remote'(재택).
  String _mode = 'office';
  final _place = TextEditingController();

  DeviceLocation get _locator => widget.location ?? DeviceLocation.instance;

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

  /// 이번에 위치를 잴지 — 출근은 외근이거나 사무실 위치가 정해졌을 때(거리를 잰다), 퇴근은 사무실 위치가 있거나 외근으로 출근한
  /// 날. 그 밖(사무실·재택에 사무실 위치도 없음)은 서버가 위치를 쓰지 않으니 권한도 묻지 않는다.
  bool _wantsLocation(AttendanceToday today, bool clockIn) {
    if (today.officeLocationSet) return true;
    if (clockIn) return _mode == 'field';
    return (today.record ?? today.openRecord)?.clockInMode == 'field';
  }

  Future<void> _clock(bool clockIn) async {
    final today = _today;
    if (today == null) return;
    if (clockIn && _mode == 'field' && _place.text.trim().isEmpty) {
      showAppToast(context, tr('외근 장소(어디서 일하는지)를 적으세요.'));
      return;
    }
    final wantsLocation = _wantsLocation(today, clockIn);
    setState(() {
      _busy = true;
      _locating = wantsLocation;
      _notice = null;
    });
    try {
      // 위치는 되면 보낸다 — 못 재면(권한 거절·시간 넘김) null. 외근 위치가 필수인 범위만 막는다(서버도 400으로 막는다).
      final location = wantsLocation ? await _locator.current() : null;
      if (!mounted) return;
      if (_locating) setState(() => _locating = false);
      if (clockIn &&
          _mode == 'field' &&
          today.requireFieldLocation &&
          location == null) {
        showAppToast(context, tr('위치를 가져오지 못했습니다. 위치 권한을 켜고 다시 누르세요.'));
        return;
      }
      final record = clockIn
          ? await widget.api.clockIn(
              mode: _mode,
              note: _mode == 'field' ? _place.text.trim() : null,
              location: location,
            )
          : await widget.api.clockOut(location: location);
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
      // 서버가 막은 까닭(주 52시간 지키기 — "오늘 일하려면 연장근무 결재를 먼저 받으세요" 등)은 길어서 토스트 대신 카드 안에 남긴다.
      if (mounted) setState(() => _notice = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _locating = false;
        });
      }
    }
  }

  /// 휴게 시작([start] true)·끝 — 누른 휴게가 있는 날은 법정 휴게 대신 누른 시간을 근로에서 뺀다(서버 workRules.js).
  Future<void> _break(bool start) async {
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final record = await widget.api.attendanceBreak(start: start);
      if (!mounted) return;
      final opened = record.breaks.where((b) => b.end == null).firstOrNull;
      showAppToast(
        context,
        start
            ? tr('{p0} 휴게를 시작했습니다.', {
                'p0': clockText(opened?.start ?? DateTime.now()),
              })
            : tr('휴게를 마쳤습니다.'),
      );
      await _load();
    } catch (e) {
      if (mounted) setState(() => _notice = e.toString());
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
            locating: _locating,
            notice: _notice,
            mode: _mode,
            place: _place,
            onMode: (m) => setState(() => _mode = m),
            onClockIn: () => _clock(true),
            onClockOut: () => _clock(false),
            onBreak: _break,
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
            if (month.allowance case final allowance?)
              _AllowanceCard(allowance: allowance),
            // 이 달에 걸친 탄력·선택 기간 — 오늘 카드에 보인 지금 기간은 빼고.
            if (month.periods.any((p) => p.start != today.period?.start))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final p in month.periods)
                      if (p.start != today.period?.start)
                        _PeriodLine(
                          key: ValueKey('attendance-period-${p.start}'),
                          period: p,
                        ),
                  ],
                ),
              ),
            if (month.weeks.isNotEmpty)
              _WeeksCard(
                weeks: month.weeks,
                limitMinutes: month.weeklyLimitMinutes,
              ),
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
  final bool locating;
  final String? notice;
  final String mode;
  final TextEditingController place;
  final ValueChanged<String> onMode;
  final VoidCallback onClockIn;
  final VoidCallback onClockOut;
  final ValueChanged<bool> onBreak;
  const _TodayCard({
    required this.today,
    required this.ctx,
    required this.busy,
    required this.locating,
    required this.notice,
    required this.mode,
    required this.place,
    required this.onMode,
    required this.onClockIn,
    required this.onClockOut,
    required this.onBreak,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final record = today.record ?? today.openRecord;
    final openBreak = record?.breaks.where((b) => b.end == null).firstOrNull;
    final guardHint = _guardHint(today);
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
            if (record?.clockInLocation case final loc?)
              _LocationLine(location: loc),
            if (today.week case final week?) ...[
              const SizedBox(height: 10),
              _WeekBar(week: week, limitMinutes: today.weeklyLimitMinutes),
            ],
            if (guardHint != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  guardHint,
                  key: const ValueKey('attendance-guard-mode'),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              ),
            if (today.period case final period?)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _PeriodLine(
                  key: const ValueKey('attendance-period'),
                  period: period,
                ),
              ),
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
                      helperText: today.requireFieldLocation
                          ? tr('외근은 위치를 함께 보냅니다(위치 권한이 필요합니다).')
                          : null,
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
            if (today.canBreakStart || today.canBreakEnd) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: openBreak == null
                        ? const SizedBox.shrink()
                        : Text(
                            tr('휴게 중 — {time}부터', {
                              'time': clockText(openBreak.start),
                            }),
                            key: const ValueKey('attendance-on-break'),
                            style: TextStyle(
                              color: Colors.orange.shade800,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                  if (today.canBreakStart)
                    OutlinedButton.icon(
                      key: const ValueKey('attendance-break-start'),
                      onPressed: busy ? null : () => onBreak(true),
                      icon: const Icon(Icons.free_breakfast_outlined, size: 18),
                      label: Text(tr('휴게 시작')),
                    ),
                  if (today.canBreakEnd)
                    OutlinedButton.icon(
                      key: const ValueKey('attendance-break-end'),
                      onPressed: busy ? null : () => onBreak(false),
                      icon: const Icon(Icons.work_outline, size: 18),
                      label: Text(tr('휴게 끝')),
                    ),
                ],
              ),
            ],
            if (locating)
              Padding(
                key: const ValueKey('attendance-locating'),
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      tr('위치 확인 중…'),
                      style: TextStyle(fontSize: 12, color: hint),
                    ),
                  ],
                ),
              ),
            if (notice != null)
              Container(
                key: const ValueKey('attendance-notice'),
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.block,
                      size: 18,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        notice!,
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 주 52시간 지키기가 '알리기만'(warn)이 아닐 때의 안내 — 결재를 받게(상한 4시간 전부터 연장근무 결재가 있어야 출근), 막기(상한에
  /// 이르면 출근 막음). 주 상한이 없으면(선택근무) 안내하지 않는다.
  static String? _guardHint(AttendanceToday today) {
    final limit = today.weeklyLimitMinutes;
    if (limit == null) return null;
    return switch (today.overtimeGuard) {
      'approval' => tr(
        '주 52시간 지키기: 결재를 받게 — 이번 주 {h}시간을 넘으면 연장근무 결재가 있어야 출근합니다',
        {'h': (limit - _weeklyWarnGapMinutes) ~/ 60},
      ),
      'block' => tr('주 52시간 지키기: 막기 — 이번 주 {h}시간에 이르면 출근할 수 없습니다', {
        'h': limit ~/ 60,
      }),
      _ => null,
    };
  }
}

/// 출근 때 보낸 위치 한 줄(오늘 카드) — 사무실까지 거리(사무실 위치를 정했을 때), 반경 밖이면 "사무실 밖", 누르면 지도.
class _LocationLine extends StatelessWidget {
  final AttendanceLocation location;
  const _LocationLine({required this.location});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = location.outside ? theme.colorScheme.error : theme.hintColor;
    return InkWell(
      key: const ValueKey('attendance-today-location'),
      onTap: () => _openMap(location),
      child: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          children: [
            Icon(Icons.place_outlined, size: 14, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                [
                  tr('출근 위치'),
                  if (location.distance case final d?)
                    tr('사무실에서 {d}m', {'d': d}),
                  if (location.outside) tr('사무실 밖'),
                ].join(' · '),
                style: TextStyle(fontSize: 12, color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 위치를 지도(OpenStreetMap — 앱 밖 브라우저)로 연다.
void _openMap(AttendanceLocation location) {
  final uri = Uri.tryParse(location.mapUrl);
  if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
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

/// 가산 수당(참고용 — 서버 workPolicy.js allowanceOf) — 관리자가 통상시급을 정한 사람만. 연장·야간·휴일(8시간 넘는 부분 포함) 시간과
/// 금액, 합계. 실제 급여 계산(포괄임금·수당 규정 등)과 다를 수 있다고 함께 적는다.
class _AllowanceCard extends StatelessWidget {
  final WorkAllowance allowance;
  const _AllowanceCard({required this.allowance});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final a = allowance;
    Widget line(String label, int minutes, int pay) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(width: 56, child: Text(label)),
          Expanded(child: Text(durationText(minutes))),
          Text(wonText(pay)),
        ],
      ),
    );
    return Card(
      key: const ValueKey('attendance-allowance'),
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr('가산 수당(참고용)'),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text(
                  tr('통상시급 {p0}', {'p0': wonText(a.wage)}),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              ],
            ),
            const SizedBox(height: 6),
            line(tr('연장'), a.overtimeMinutes, a.overtimePay),
            line(tr('야간'), a.nightMinutes, a.nightPay),
            line(
              tr('휴일'),
              a.holidayMinutes + a.holidayOverMinutes,
              a.holidayPay,
            ),
            const Divider(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr('합계'),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  wonText(a.totalPay),
                  key: const ValueKey('attendance-allowance-total'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              tr('참고용 — 실제 급여와 다를 수 있습니다'),
              style: TextStyle(fontSize: 12, color: hint),
            ),
          ],
        ),
      ),
    );
  }
}

/// 탄력적 근로시간제·선택근무 정산 기간 한 줄 — 기간의 실근로 / 기준(주 40시간 × 주 수) · 연장(한도), 상태 색('warn' 주황·'over'
/// 빨강). 주 상한(탄력 60·64시간)을 넘은 주가 있으면 몇 주인지도.
class _PeriodLine extends StatelessWidget {
  final WorkPeriodSummary period;
  const _PeriodLine({super.key, required this.period});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = period;
    final color = switch (p.status) {
      'over' => theme.colorScheme.error,
      'warn' => Colors.orange.shade800,
      _ => null,
    };
    final overWeeks = p.weeks.where((w) => w.over).length;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            p.status == 'ok' ? Icons.date_range : Icons.warning_amber_rounded,
            size: 16,
            color: color ?? theme.hintColor,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              [
                tr(
                  '{label} {start}~{last}: {net} / 기준 {standard} · 연장 {over} (한도 {cap})',
                  {
                    'label': workPeriodTypeLabels[p.type] ?? p.type,
                    'start': shortDateText(p.start),
                    'last': shortDateText(p.lastDay),
                    'net': durationText(p.netMinutes),
                    'standard': durationText(p.standardMinutes),
                    'over': durationText(p.overtimeMinutes),
                    'cap': durationText(p.overtimeCapMinutes),
                  },
                ),
                if (overWeeks > 0 && p.weeklyMaxMinutes != null)
                  tr('주 {h}시간 넘은 주 {n}', {
                    'h': p.weeklyMaxMinutes! ~/ 60,
                    'n': overWeeks,
                  }),
              ].join(' · '),
              style: TextStyle(fontSize: 13, color: color),
            ),
          ),
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
    final breakdown = record?.breakdown;
    // 출근 위치(없으면 퇴근 위치) — 지도 단추. 둘 중 하나라도 사무실 반경 밖이면 "사무실 밖".
    final location = record?.clockInLocation ?? record?.clockOutLocation;
    final outside =
        (record?.clockInLocation?.outside ?? false) ||
        (record?.clockOutLocation?.outside ?? false);
    final leaveLabel = day.leaveType == null
        ? null
        : ctx.leaveType(day.leaveType)?.label ?? tr('휴가');
    final marks = [
      if (day.holiday != null) day.holiday!,
      // 시간 연차는 그 시간대까지 — "반반차 09:00~11:00".
      if (leaveLabel != null)
        day.leaveHourRange == null
            ? leaveLabel
            : '$leaveLabel ${minutesText(day.leaveHourRange!.start)}~${minutesText(day.leaveHourRange!.end)}',
      if (day.trip) tr('출장'),
      if (record != null && record.clockInMode != 'office')
        '${clockInModeLabels[record.clockInMode] ?? ''}${record.note == null ? '' : '(${record.note})'}',
      if (breakdown != null && breakdown.breakMinutes > 0)
        tr('휴게 {p0}', {'p0': durationText(breakdown.breakMinutes)}),
      if (breakdown != null && breakdown.breakShortMinutes > 0)
        tr('휴게 {m}분 모자람', {'m': breakdown.breakShortMinutes}),
      if (breakdown != null && breakdown.overtimeMinutes > 0)
        tr('연장 {p0}', {'p0': durationText(breakdown.overtimeMinutes)}),
      if (breakdown != null && breakdown.nightMinutes > 0)
        tr('야간 {p0}', {'p0': durationText(breakdown.nightMinutes)}),
      if (breakdown != null && breakdown.holidayMinutes > 0)
        tr('휴일 {p0}', {'p0': durationText(breakdown.holidayMinutes)}),
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
      if (outside) tr('사무실 밖'),
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
      trailing: location == null && onFix == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (location != null)
                  IconButton(
                    key: ValueKey('attendance-location-${day.date}'),
                    tooltip: location.distance == null
                        ? tr('위치 보기(지도)')
                        : tr('위치 보기(지도) — 사무실에서 {d}m', {
                            'd': location.distance,
                          }),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _openMap(location),
                    icon: Icon(
                      outside ? Icons.wrong_location_outlined : Icons.place,
                      size: 18,
                      color: outside ? theme.colorScheme.error : hint,
                    ),
                  ),
                if (onFix != null)
                  TextButton(onPressed: onFix, child: Text(tr('수정 요청'))),
              ],
            ),
    );
  }
}

/// 이번 주 근로시간 막대 — 이 사람의 주 상한([limitMinutes] — 보통 52시간, 탄력 60·64시간; 상한 4시간 전부터 주의 색, 넘으면 빨강).
/// 상한이 없으면(선택근무) 막대 없이 근로시간과 "정산 기간으로 봅니다".
class _WeekBar extends StatelessWidget {
  final WeeklyHours week;
  final int? limitMinutes;
  const _WeekBar({required this.week, required this.limitMinutes});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final limit = limitMinutes;
    if (limit == null) {
      return Text(
        '${tr('이번 주 {p0}', {'p0': durationText(week.netMinutes)})} · ${tr('선택근무 — 주 상한 없음(정산 기간으로 봅니다)')}',
        key: const ValueKey('attendance-week'),
        style: TextStyle(fontSize: 12, color: theme.hintColor),
      );
    }
    final status = _weekStatus(week.netMinutes, limit);
    final color = switch (status) {
      'over' => theme.colorScheme.error,
      'warn' => Colors.orange.shade700,
      _ => theme.colorScheme.primary,
    };
    final ratio = (week.netMinutes / limit).clamp(0.0, 1.0);
    final hours = limit ~/ 60;
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
                  'p1': hours,
                }),
                style: TextStyle(fontSize: 12, color: color),
              ),
            ),
            if (status != 'ok')
              Text(
                // 52시간이면 예전 문구 그대로(번역이 있다), 탄력이면 그 상한으로.
                hours == 52
                    ? (status == 'over' ? tr('주 52시간 넘음') : tr('52시간에 가까움'))
                    : (status == 'over'
                          ? tr('주 {h}시간 넘음', {'h': hours})
                          : tr('{h}시간에 가까움', {'h': hours})),
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

/// 이 달에 걸친 주마다의 근로시간 — 상태는 이 사람의 주 상한([limitMinutes])으로 다시 가린다(없으면 색 없이).
class _WeeksCard extends StatelessWidget {
  final List<WeeklyHours> weeks;
  final int? limitMinutes;
  const _WeeksCard({required this.weeks, required this.limitMinutes});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final limit = limitMinutes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            limit == null
                ? tr('주마다(주 상한 없음)')
                : (limit == 52 * 60
                      ? tr('주마다(주 52시간)')
                      : tr('주마다(주 {h}시간)', {'h': limit ~/ 60})),
            style: TextStyle(fontSize: 12, color: hint),
          ),
          for (final w in weeks)
            Builder(
              builder: (context) {
                final status = _weekStatus(w.netMinutes, limit);
                return Padding(
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
                              tr('휴일 {p0}', {
                                'p0': durationText(w.holidayMinutes),
                              }),
                          ].join(' · '),
                          style: TextStyle(
                            fontSize: 13,
                            color: status == 'over'
                                ? theme.colorScheme.error
                                : (status == 'warn'
                                      ? Colors.orange.shade800
                                      : null),
                          ),
                        ),
                      ),
                      if (status == 'over')
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 16,
                          color: theme.colorScheme.error,
                        ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
