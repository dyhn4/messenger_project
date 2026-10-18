import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../services/download_storage.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import 'approval_form_admin.dart' show ApprovalFormsAdminSection;
import 'approval_forms.dart' show isHmText;
import 'approval_settings.dart'
    show ApprovalSealKeySection, ApprovalStatsSection;
import 'final_rules_section.dart';
import 'groupware_work_admin.dart';
import 'line_rules_section.dart';
import 'resource_tab.dart' show ResourcesAdminSection;
import 'groupware_screen.dart';
import '../../l10n/tr.dart';

/// 관리 탭(결재·근태 관리자만) — 근무 시간(지각·조퇴 기준), 구성원 입사일·연차 현황·연차 조정, 한 달 근태 요약과 엑셀.
/// 회사 전체 범위면 서버 운영자·관리자 등급, 팀 범위면 그 팀 소유자·관리자 등급이 본다(server groupwareScope.js).
class GroupwareAdminTab extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final GroupwareChanges changes;
  final Session session;

  /// 근무 시간을 바꿨을 때 — 화면이 범위 정보(근무 시간)를 다시 받는다.
  final VoidCallback? onContextChanged;
  const GroupwareAdminTab({
    super.key,
    required this.api,
    required this.ctx,
    required this.changes,
    required this.session,
    this.onContextChanged,
  });

  @override
  State<GroupwareAdminTab> createState() => _GroupwareAdminTabState();
}

class _GroupwareAdminTabState extends State<GroupwareAdminTab> {
  late final _workStart = TextEditingController(
    text: minutesText(widget.ctx.workStart),
  );
  late final _workEnd = TextEditingController(
    text: minutesText(widget.ctx.workEnd),
  );
  List<GroupwareMember>? _members;
  List<AttendanceSummaryRow>? _summary;
  late String _monthKey = widget.ctx.today.substring(0, 7);
  bool _saving = false;
  bool _exporting = false;
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
    _workStart.dispose();
    _workEnd.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.api.members(),
        widget.api.attendanceSummary(_monthKey),
      ]);
      if (!mounted) return;
      setState(() {
        _members = results[0] as List<GroupwareMember>;
        _summary = results[1] as List<AttendanceSummaryRow>;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _saveHours() async {
    if (!isHmText(_workStart.text) || !isHmText(_workEnd.text)) {
      showAppToast(context, tr('근무 시간을 HH:MM으로 넣으세요.'));
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.api.setWorkHours(
        start: _workStart.text.trim(),
        end: _workEnd.text.trim(),
      );
      if (!mounted) return;
      showAppToast(context, tr('근무 시간을 저장했습니다.'));
      widget.onContextChanged?.call();
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editHireDate(GroupwareMember m) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: m.hireDate == null ? now : DateTime.parse(m.hireDate!),
      firstDate: DateTime(1970),
      lastDate: DateTime(now.year + 1),
      helpText: tr('{m.name}님의 입사일', {'m.name': m.name}),
    );
    if (picked == null || !mounted) return;
    try {
      await widget.api.setHireDate(m.id, dateKeyOf(picked));
      if (mounted) {
        showAppToast(
          context,
          tr('{m.name}님의 입사일을 {p0}로 정했습니다.', {
            'm.name': m.name,
            'p0': dateKeyOf(picked),
          }),
        );
      }
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    }
  }

  /// 통상시급 정하기·지우기 — 가산 수당(참고용) 계산에만 쓴다(server PUT /groupware/members/:userId/wage).
  Future<void> _editWage(GroupwareMember m) async {
    final result = await showDialog<({int? wage})>(
      context: context,
      builder: (_) => _WageDialog(name: m.name, wage: m.hourlyWage),
    );
    if (result == null || !mounted) return;
    try {
      await widget.api.setHourlyWage(m.id, result.wage);
      if (mounted) {
        showAppToast(
          context,
          result.wage == null
              ? tr('{name}님의 통상시급을 지웠습니다.', {'name': m.name})
              : tr('{name}님의 통상시급을 {wage}으로 정했습니다.', {
                  'name': m.name,
                  'wage': wonText(result.wage!),
                }),
        );
      }
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    }
  }

  Future<void> _adjust(GroupwareMember m) async {
    // 조정 내역은 창을 열 때 한 번만 받는다(창이 다시 그려져도 다시 받지 않게 — 못 받으면 내역 없이 조정만).
    final history = widget.api
        .leaveBalance(userId: m.id)
        .then((b) => b.adjustments);
    final result = await showDialog<({int halfDays, String reason})>(
      context: context,
      builder: (_) => _AdjustDialog(name: m.name, history: history),
    );
    if (result == null || !mounted) return;
    try {
      await widget.api.adjustLeave(
        m.id,
        halfDays: result.halfDays,
        reason: result.reason,
      );
      if (mounted) {
        showAppToast(context, tr('{m.name}님의 연차를 조정했습니다.', {'m.name': m.name}));
      }
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    }
  }

  /// 가산 수당 나눔 — "통상시급 10,000원 · 연장 2시간 15,000원 · 야간 1시간 5,000원 · 휴일 8시간 120,000원".
  static String _allowanceDetail(WorkAllowance a) => [
    tr('통상시급 {wage}', {'wage': wonText(a.wage)}),
    if (a.overtimeMinutes > 0)
      tr('연장 {t} {pay}', {
        't': durationText(a.overtimeMinutes),
        'pay': wonText(a.overtimePay),
      }),
    if (a.nightMinutes > 0)
      tr('야간 {t} {pay}', {
        't': durationText(a.nightMinutes),
        'pay': wonText(a.nightPay),
      }),
    if (a.holidayMinutes + a.holidayOverMinutes > 0)
      tr('휴일 {t} {pay}', {
        't': durationText(a.holidayMinutes + a.holidayOverMinutes),
        'pay': wonText(a.holidayPay),
      }),
  ].join(' · ');

  void _shiftMonth(int delta) {
    final parts = _monthKey.split('-');
    final next = DateTime(int.parse(parts[0]), int.parse(parts[1]) + delta);
    setState(() {
      _monthKey = '${next.year}-${next.month.toString().padLeft(2, '0')}';
      _summary = null;
    });
    _load();
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final name = '근태_${widget.ctx.scopeLabel}_$_monthKey.xlsx'.replaceAll(
        RegExp(r'[\\/:*?"<>|]'),
        '_',
      );
      final path = await widget.session.downloadAuthedFile(
        widget.api.attendanceExportPath(_monthKey),
        fileName: name,
      );
      await openLocalFile(path);
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    if (_error != null) return GroupwareEmpty(_error!);
    final members = _members;
    final summary = _summary;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text(
            tr(
              '범위: {p0} — 바꾸려면 관리자 콘솔 → 운영 현황의 "그룹웨어 범위". 법정 연차는 설정의 연차 기준(입사일·회계연도)으로 계산하고, 남은 연차 이월은 "연차 이월"로, 출근율 80% 미만·회사가 더 주는 휴가는 "연차 조정"으로 맞춥니다.',
              {
                'p0': widget.ctx.scope == 'server'
                    ? tr('회사 전체')
                    : tr('이 팀({p0})', {'p0': widget.ctx.teamName ?? ''}),
              },
            ),
            key: const ValueKey('gw-admin-scope-note'),
            style: TextStyle(fontSize: 12, color: hint),
          ),
        ),
        GroupwareSectionHeader(tr('근무 시간(지각·조퇴 기준)')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              SizedBox(
                width: 110,
                child: TextField(
                  key: const ValueKey('gw-work-start'),
                  controller: _workStart,
                  decoration: InputDecoration(
                    labelText: tr('시작'),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('~'),
              ),
              SizedBox(
                width: 110,
                child: TextField(
                  key: const ValueKey('gw-work-end'),
                  controller: _workEnd,
                  decoration: InputDecoration(
                    labelText: tr('끝'),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                key: const ValueKey('gw-work-save'),
                onPressed: _saving ? null : _saveHours,
                child: Text(tr('저장')),
              ),
            ],
          ),
        ),
        WorkSchedulesSection(api: widget.api, ctx: widget.ctx),
        WeeklyHoursSection(api: widget.api, ctx: widget.ctx),
        ResourcesAdminSection(api: widget.api, changes: widget.changes),
        GroupwareOptionsSection(
          api: widget.api,
          changes: widget.changes,
          onChanged: widget.onContextChanged,
        ),
        ApprovalFormsAdminSection(api: widget.api, changes: widget.changes),
        // 결재선 규칙 — 종류·금액마다 상위자를 어디까지 채울지(신청 창이 결재선을 미리 채울 때 쓴다).
        LineRulesAdminSection(
          api: widget.api,
          ctx: widget.ctx,
          changes: widget.changes,
          session: widget.session,
        ),
        // 전결 규정 — 종류·금액마다 어느 직책 이상이 전결할지(결재를 올릴 때 서버가 결재선에서 전결권자를 정한다).
        FinalRulesAdminSection(
          api: widget.api,
          ctx: widget.ctx,
          changes: widget.changes,
          session: widget.session,
        ),
        ApprovalStatsSection(
          api: widget.api,
          ctx: widget.ctx,
          session: widget.session,
        ),
        // 결재 전자서명 — 서버 서명 키의 지문과 공개 키(펼칠 때만 받는다).
        ApprovalSealKeySection(api: widget.api),
        LeavePromotionSection(
          api: widget.api,
          ctx: widget.ctx,
          changes: widget.changes,
        ),
        GroupwareSectionHeader(tr('구성원 연차')),
        if (members == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          for (final m in members)
            ListTile(
              key: ValueKey('gw-member-${m.id}'),
              dense: true,
              title: Text('${m.name}${m.suspended ? tr(' (정지)') : ''}'),
              subtitle: Text(
                m.hireDate == null
                    ? tr('입사일 미등록 — 눌러서 등록')
                    : tr('입사 {m.hireDate} · 생김 {p0} · 씀 {p1}{p2} · 남음 {p3}', {
                        'm.hireDate': m.hireDate,
                        'p0': halfDaysText(m.grantedHalfDays ?? 0),
                        'p1': halfDaysText(m.usedHalfDays),
                        'p2': m.pendingHalfDays > 0
                            ? tr(' · 결재 중 {p0}', {
                                'p0': halfDaysText(m.pendingHalfDays),
                              })
                            : '',
                        'p3': halfDaysText(m.remainingHalfDays ?? 0),
                      }),
                style: TextStyle(
                  color: m.hireDate == null ? theme.colorScheme.error : hint,
                ),
              ),
              onTap: () => _editHireDate(m),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 통상시급(가산 수당 참고용) — 정했으면 금액, 아니면 "시급".
                  TextButton(
                    key: ValueKey('gw-member-wage-${m.id}'),
                    onPressed: () => _editWage(m),
                    child: Text(
                      m.hourlyWage == null
                          ? tr('시급')
                          : tr('시급 {wage}', {'wage': wonText(m.hourlyWage!)}),
                    ),
                  ),
                  if (m.hireDate != null)
                    TextButton(
                      key: ValueKey('gw-adjust-${m.id}'),
                      onPressed: () => _adjust(m),
                      child: Text(tr('연차 조정')),
                    ),
                ],
              ),
            ),
        GroupwareSectionHeader(
          tr('월별 근태'),
          trailing: FilledButton.tonalIcon(
            key: const ValueKey('gw-export'),
            onPressed: _exporting ? null : _export,
            icon: _exporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download, size: 18),
            label: Text(tr('엑셀로 받기')),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
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
              ),
              IconButton(
                tooltip: tr('다음 달'),
                onPressed: () => _shiftMonth(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
        if (summary != null && summary.any((r) => r.allowance != null))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              tr(
                '오른쪽 금액은 총 가산 수당(참고용) — 통상시급을 정한 사람만, 승인된 연장근무와 출퇴근 기록·설정의 가산율로 셈한 것입니다. 급여 계산은 노무·급여 담당과 맞춰 보세요.',
              ),
              key: const ValueKey('gw-summary-allowance-note'),
              style: TextStyle(fontSize: 12, color: hint),
            ),
          ),
        if (summary == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          for (final row in summary)
            ListTile(
              key: ValueKey('gw-summary-${row.userId}'),
              dense: true,
              title: Text(row.name),
              // 총 가산 수당(참고용 — 통상시급을 정한 사람만). 길게 누르거나 올려 보면 연장·야간·휴일 나눔.
              trailing: row.allowance == null
                  ? null
                  : Tooltip(
                      message: _allowanceDetail(row.allowance!),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            tr('총 가산 수당'),
                            style: TextStyle(fontSize: 11, color: hint),
                          ),
                          Text(
                            wonText(row.allowance!.totalPay),
                            key: ValueKey('gw-summary-allowance-${row.userId}'),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
              subtitle: Text(
                [
                  tr('출근 {row.summary.daysWorked}일', {
                    'row.summary.daysWorked': row.summary.daysWorked,
                  }),
                  row.summary.hoursText,
                  if (row.summary.late > 0)
                    tr('지각 {row.summary.late}', {
                      'row.summary.late': row.summary.late,
                    }),
                  if (row.summary.earlyLeave > 0)
                    tr('조퇴 {row.summary.earlyLeave}', {
                      'row.summary.earlyLeave': row.summary.earlyLeave,
                    }),
                  if (row.summary.missingClockOut > 0)
                    tr('퇴근 누락 {row.summary.missingClockOut}', {
                      'row.summary.missingClockOut':
                          row.summary.missingClockOut,
                    }),
                  if (row.summary.absent > 0)
                    tr('결근 {row.summary.absent}', {
                      'row.summary.absent': row.summary.absent,
                    }),
                  if (row.summary.leaveHalfDays > 0)
                    tr('휴가 {p0}', {
                      'p0': halfDaysText(row.summary.leaveHalfDays),
                    }),
                  if (row.summary.tripDays > 0)
                    tr('출장 {row.summary.tripDays}일', {
                      'row.summary.tripDays': row.summary.tripDays,
                    }),
                  if (row.summary.overtimeMinutes > 0)
                    tr('연장 {row.summary.overtimeText}', {
                      'row.summary.overtimeText': row.summary.overtimeText,
                    }),
                ].join(' · '),
                style: TextStyle(color: hint),
              ),
            ),
      ],
    );
  }
}

/// 통상시급 — 원 단위(쉼표 넣어도 됨), 정해 둔 것이 있으면 지우기.
class _WageDialog extends StatefulWidget {
  final String name;
  final int? wage;
  const _WageDialog({required this.name, this.wage});

  @override
  State<_WageDialog> createState() => _WageDialogState();
}

class _WageDialogState extends State<_WageDialog> {
  late final _input = TextEditingController(
    text: widget.wage == null ? '' : '${widget.wage}',
  );
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _done() {
    final value = int.tryParse(_input.text.trim().replaceAll(',', ''));
    // 서버 workPolicy.js parseHourlyWage와 같은 범위(1원~100만 원).
    if (value == null || value <= 0 || value > 1000000) {
      setState(() => _error = tr('통상시급을 원 단위 숫자로 넣으세요.'));
      return;
    }
    Navigator.of(context).pop((wage: value));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('{name}님 통상시급', {'name': widget.name})),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr(
              '월별 근태의 가산 수당(참고용 — 연장·야간·휴일)을 셈하는 데만 씁니다. 급여 명세에 쓰기 전에 꼭 확인하세요.',
            ),
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('gw-wage-input'),
            controller: _input,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: tr('통상시급'),
              border: const OutlineInputBorder(),
              suffixText: tr('원'),
            ),
            onSubmitted: (_) => _done(),
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      if (widget.wage != null)
        TextButton(
          key: const ValueKey('gw-wage-clear'),
          onPressed: () => Navigator.of(context).pop((wage: null)),
          child: Text(tr('지우기')),
        ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(tr('취소')),
      ),
      FilledButton(
        key: const ValueKey('gw-wage-save'),
        onPressed: _done,
        child: Text(tr('저장')),
      ),
    ],
  );
}

/// 연차 조정 — 일수(0.5일 단위, 빼려면 −)와 사유. 위에는 이번 기간의 조정 내역([history] — 이월로 넣은 것은 "이월" 표시).
class _AdjustDialog extends StatefulWidget {
  final String name;
  final Future<List<LeaveAdjustment>>? history;
  const _AdjustDialog({required this.name, this.history});

  @override
  State<_AdjustDialog> createState() => _AdjustDialogState();
}

class _AdjustDialogState extends State<_AdjustDialog> {
  final _days = TextEditingController();
  final _reason = TextEditingController();
  bool _subtract = false;
  String? _error;

  @override
  void dispose() {
    _days.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _done() {
    final value = double.tryParse(_days.text.trim());
    if (value == null ||
        value <= 0 ||
        (value * 2) != (value * 2).roundToDouble() ||
        value > 60) {
      setState(() => _error = tr('일수를 0.5일 단위로 넣으세요(최대 60일).'));
      return;
    }
    if (_reason.text.trim().isEmpty) {
      setState(() => _error = tr('조정 사유를 쓰세요.'));
      return;
    }
    final halfDays = (value * 2).round() * (_subtract ? -1 : 1);
    Navigator.of(
      context,
    ).pop((halfDays: halfDays, reason: _reason.text.trim()));
  }

  /// 이번 기간 조정 내역 — 줄마다 "이월"(지난 기간에서 넘어온 것)·"조정"(관리자가 넣은 것), 양, 사유, 넣은 사람. 못 받으면 숨긴다.
  Widget _historyView(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<List<LeaveAdjustment>>(
      future: widget.history,
      builder: (context, snap) {
        final list = snap.data;
        if (list == null || list.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tr('이번 기간 조정 내역'),
                style: TextStyle(fontSize: 12, color: theme.hintColor),
              ),
              for (final a in list)
                Padding(
                  key: ValueKey('gw-adjustment-${a.id}'),
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: a.kind == 'carry'
                              ? theme.colorScheme.primaryContainer
                              : theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          a.kind == 'carry' ? tr('이월') : tr('조정'),
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          tr('{amount} · {reason} · {by}', {
                            'amount':
                                '${a.halfDays > 0 ? '+' : ''}${halfDaysText(a.halfDays)}',
                            'reason': a.reason,
                            'by': a.createdByName,
                          }),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('{widget.name}님 연차 조정', {'widget.name': widget.name})),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.history != null) _historyView(context),
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, label: Text(tr('더 주기'))),
              ButtonSegment(value: true, label: Text(tr('빼기'))),
            ],
            selected: {_subtract},
            onSelectionChanged: (s) => setState(() => _subtract = s.first),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('gw-adjust-days'),
            controller: _days,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: tr('일수 (예: 1, 0.5)'),
              border: OutlineInputBorder(),
              suffixText: tr('일'),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('gw-adjust-reason'),
            controller: _reason,
            maxLength: 200,
            decoration: InputDecoration(
              labelText: tr('사유 (예: 지난해 이월, 출근율 80% 미만)'),
              border: OutlineInputBorder(),
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
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(tr('취소')),
      ),
      FilledButton(
        key: const ValueKey('gw-adjust-ok'),
        onPressed: _done,
        child: Text(tr('조정')),
      ),
    ],
  );
}
