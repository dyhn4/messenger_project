import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../models/groupware_resources.dart' show LeaveMonth;
import '../../models/groupware_work.dart';
import '../../widgets/app_toast.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import 'approval_forms.dart';
import 'approval_tab.dart';
import 'groupware_screen.dart';
import 'leave_calendar.dart';
import 'leave_notice_pdf.dart';
import '../../l10n/tr.dart';

/// 휴가 탭 — 내 연차 현황(입사일 기준 법정 연차 — server annualLeave.js), 휴가 신청, 팀 휴가(달력 — leave_calendar.dart, 또는 앞으로 30일
/// 목록), 내 휴가 결재.
class LeaveTab extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final GroupwareChanges changes;
  final Session session;
  const LeaveTab({
    super.key,
    required this.api,
    required this.ctx,
    required this.changes,
    required this.session,
  });

  @override
  State<LeaveTab> createState() => _LeaveTabState();
}

class _LeaveTabState extends State<LeaveTab> {
  LeaveBalance? _balance;
  List<TeamLeave> _teamLeaves = const [];
  List<ApprovalDocument> _mine = const [];

  /// 내가 받은 연차 사용 촉진 통지(근로기준법 제61조) — 이번 연차 기간 것만 위에 보인다.
  List<LeavePromotion> _promotions = const [];
  String? _error;

  /// 팀 휴가를 달력으로 볼지(기본) 앞으로 30일 목록으로 볼지.
  bool _calendarView = true;

  /// 팀 휴가의 부서 거르기(달력·30일 목록 함께) — 부서 id · 'none'(부서 없음) · null(모든 부서). 이 기기에 기억한다(leave_calendar.dart
  /// kLeaveDepartmentPref). 부서 목록은 달력이 받은 응답에서 얻는다(비면 드롭다운을 숨긴다).
  String? _departmentId;
  List<LeaveDepartment> _departments = const [];

  @override
  void initState() {
    super.initState();
    widget.changes.addListener(_load);
    _init();
  }

  /// 기억한 부서 거르기를 먼저 읽고(못 읽으면 모든 부서) 그 부서로 처음 받는다 — 달력도 이 값으로 처음 그린다(받기 전엔 그리지 않는다).
  Future<void> _init() async {
    _departmentId = await loadLeaveDepartment();
    if (mounted) await _load();
  }

  @override
  void dispose() {
    widget.changes.removeListener(_load);
    super.dispose();
  }

  /// 앞으로 30일의 팀 휴가 — 지금 부서 거르기로.
  Future<List<TeamLeave>> _fetchTeamLeaves() {
    final today = DateTime.parse(widget.ctx.today);
    return widget.api.teamLeaves(
      from: widget.ctx.today,
      to: dateKeyOf(today.add(const Duration(days: 30))),
      departmentId: _departmentId,
    );
  }

  /// 부서 거르기만 바뀌었을 때 — 30일 목록만 다시 받는다(달력은 [LeaveMonthCalendar.departmentId]가 바뀌어 스스로 다시 받는다).
  Future<void> _reloadTeamLeaves() async {
    final department = _departmentId;
    try {
      final leaves = await _fetchTeamLeaves();
      if (mounted && department == _departmentId) {
        setState(() => _teamLeaves = leaves);
      }
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    }
  }

  /// 드롭다운에서 부서를 골랐다 — 기억하고 달력·30일 목록을 그 부서로.
  void _changeDepartment(String? departmentId) {
    if (departmentId == _departmentId) return;
    setState(() => _departmentId = departmentId);
    saveLeaveDepartment(departmentId);
    _reloadTeamLeaves();
  }

  /// 달력이 한 달을 받았다 — 부서 목록을 드롭다운에 쓰고, 기억한 부서가 없어졌으면(조직도에서 지웠거나 부서가 하나도 없다) 모든 부서로
  /// 되돌린다(기억도 지운다).
  void _onCalendarLoaded(LeaveMonth month) {
    final departments = month.departments;
    final stale = !leaveDepartmentValid(departments, _departmentId);
    if (!stale && listEquals(departments, _departments)) return;
    setState(() {
      _departments = departments;
      if (stale) _departmentId = null;
    });
    if (stale) {
      saveLeaveDepartment(null);
      _reloadTeamLeaves();
    }
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.api.leaveBalance(),
        _fetchTeamLeaves(),
        widget.api.documents(box: ApprovalBox.mine, kind: ApprovalKind.leave),
        widget.api.myPromotions().catchError((_) => <LeavePromotion>[]),
      ]);
      if (!mounted) return;
      final promotions = results[3] as List<LeavePromotion>;
      setState(() {
        _balance = results[0] as LeaveBalance;
        _teamLeaves = results[1] as List<TeamLeave>;
        _mine = results[2] as List<ApprovalDocument>;
        _promotions = promotions;
        _error = null;
      });
      // 화면에 보인 통지는 읽음(확인)으로 — 촉진을 받았다는 근거가 된다.
      for (final p in promotions.where(
        (p) => p.readAt == null && widget.ctx.today.compareTo(p.periodEnd) < 0,
      )) {
        widget.api.readPromotion(p.id).ignore();
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// 1차 촉진에 쓸 날 내기 — 남은 연차만큼까지 날짜를 고른다.
  Future<void> _submitPlan(LeavePromotion p) async {
    final dates = await showLeaveDatesDialog(
      context,
      title: tr('연차 쓸 날 내기'),
      from: widget.ctx.today,
      to: p.expiry,
      maxDays: p.remainingHalfDays ~/ 2,
    );
    if (dates == null || !mounted) return;
    try {
      await widget.api.submitPromotionPlan(p.id, dates);
      if (!mounted) return;
      showAppToast(context, tr('쓸 날을 냈습니다. 그날 휴가 신청도 잊지 마세요.'));
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    }
  }

  /// 받은 촉진 통지를 서면 통지서(PDF)로 — 근로기준법 제61조의 "서면으로 촉구·통보"를 받은 사람도 남겨 둘 수 있게(leave_notice_pdf.dart).
  /// 받는 사람 이름은 로그인한 내 이름(없으면 아이디).
  Future<void> _noticePdf(LeavePromotion p) async {
    try {
      await leaveNoticePdf(
        context,
        notice: p,
        employeeName: widget.session.name ?? widget.session.username ?? '',
        scopeLabel: widget.ctx.scopeLabel,
        ctx: widget.ctx,
      );
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    }
  }

  Future<void> _request() async {
    final doc = await showLeaveRequestDialog(
      context,
      api: widget.api,
      ctx: widget.ctx,
      balance: _balance,
    );
    if (!mounted || doc == null) return;
    toastSubmitted(context, doc);
    widget.changes.bump();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return GroupwareEmpty(_error!);
    final balance = _balance;
    if (balance == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          for (final p in _promotions.where(
            (p) => widget.ctx.today.compareTo(p.periodEnd) < 0,
          ))
            _PromotionCard(
              promotion: p,
              today: widget.ctx.today,
              onPlan: () => _submitPlan(p),
              onPdf: () => _noticePdf(p),
            ),
          _BalanceCard(balance: balance, onRequest: _request),
          GroupwareSectionHeader(
            tr('팀 휴가'),
            trailing: SegmentedButton<bool>(
              key: const ValueKey('leave-view'),
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: true, label: Text(tr('달력'))),
                ButtonSegment(value: false, label: Text(tr('앞으로 30일'))),
              ],
              selected: {_calendarView},
              onSelectionChanged: (s) =>
                  setState(() => _calendarView = s.first),
            ),
          ),
          // 부서 거르기 — 달력과 30일 목록에 함께(조직도에 부서가 없으면 숨긴다). 자리는 늘 남겨 둔다 — 목록이 나중에 생겨도 아래 달력의
          // 자리(순번)가 밀리지 않아 달력이 새로 만들어지며 다시 받지 않게.
          _departments.isEmpty
              ? const SizedBox.shrink()
              : LeaveDepartmentFilter(
                  departments: _departments,
                  value: _departmentId,
                  onChanged: _changeDepartment,
                ),
          if (_calendarView)
            LeaveMonthCalendar(
              api: widget.api,
              ctx: widget.ctx,
              changes: widget.changes,
              departmentId: _departmentId,
              onLoaded: _onCalendarLoaded,
              balance: _balance,
            )
          else if (_teamLeaves.isEmpty)
            GroupwareEmpty(tr('예정된 휴가가 없습니다.'))
          else
            for (final l in _teamLeaves)
              ListTile(
                dense: true,
                leading: const Icon(Icons.beach_access_outlined, size: 20),
                title: Text(
                  '${l.name} · ${l.leaveLabel ?? widget.ctx.leaveType(l.leaveType)?.label ?? tr('휴가')}',
                ),
                subtitle: Text(
                  l.startDate == l.endDate
                      ? shortDateText(l.startDate)
                      : '${shortDateText(l.startDate)} ~ ${shortDateText(l.endDate)}',
                ),
              ),
          GroupwareSectionHeader(tr('내 휴가 결재')),
          if (_mine.isEmpty)
            GroupwareEmpty(tr('올린 휴가 결재가 없습니다.'))
          else
            for (final d in _mine)
              ApprovalDocumentTile(
                doc: d,
                ctx: widget.ctx,
                onTap: () async {
                  final changed = await showApprovalDetail(
                    context,
                    api: widget.api,
                    ctx: widget.ctx,
                    session: widget.session,
                    documentId: d.id,
                  );
                  if (changed) widget.changes.bump();
                },
              ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  final LeaveBalance balance;
  final VoidCallback onRequest;
  const _BalanceCard({required this.balance, required this.onRequest});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    // 조정 합 = 이월 + 관리자 조정(반일 — 시간 연차·이월로 소수일 수 있다).
    final carry = balance.adjustments
        .where((a) => a.kind == 'carry')
        .fold<double>(0, (sum, a) => sum + a.halfDays);
    // 1시간(0.25 반일) 단위로 맞춰 소수 오차로 "관리자 조정 0시간"이 생기지 않게.
    final manual = ((balance.adjustmentHalfDays - carry) * 4).round() / 4;
    Widget stat(String label, String value, {Color? color}) => Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          Text(label, style: TextStyle(fontSize: 12, color: hint)),
        ],
      ),
    );
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
                  child: Text(tr('내 연차'), style: theme.textTheme.titleMedium),
                ),
                FilledButton.icon(
                  key: const ValueKey('leave-request'),
                  onPressed: onRequest,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(tr('휴가 신청')),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (!balance.known)
              Text(
                tr(
                  '입사일이 등록되지 않아 연차를 계산할 수 없습니다. 결재·근태 관리자에게 입사일 등록을 요청하세요. (휴가 신청은 할 수 있습니다)',
                ),
                style: TextStyle(color: hint),
              )
            else ...[
              Row(
                children: [
                  stat(tr('생긴 연차'), halfDaysText(balance.grantedHalfDays!)),
                  stat(tr('쓴 연차'), halfDaysText(balance.usedHalfDays)),
                  stat(tr('결재 중'), halfDaysText(balance.pendingHalfDays)),
                  stat(
                    tr('남은 연차'),
                    halfDaysText(balance.remainingHalfDays!),
                    color: theme.colorScheme.primary,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                [
                  tr('입사일 {balance.hireDate}', {
                    'balance.hireDate': balance.hireDate,
                  }),
                  if (balance.periodStart != null)
                    tr('이번 연차 기간 {balance.periodStart} ~ {balance.periodEnd}', {
                      'balance.periodStart': balance.periodStart,
                      'balance.periodEnd': balance.periodEnd,
                    }),
                  // 범위가 회계연도 기준이면(groupwareWork.js leaveBasis) 기간 옆에 밝힌다 — 입사일 기념일과 다르게 끊긴다.
                  if (balance.basis == 'fiscal') tr('회계연도 기준'),
                  balance.serviceYears == 0
                      ? tr('입사 첫해 — 한 달 채울 때마다 1일(최대 11일)')
                      : tr('근속 {balance.serviceYears}년', {
                          'balance.serviceYears': balance.serviceYears,
                        }),
                  // 조정 합에는 지난 기간에서 넘어온 이월(kind 'carry')이 함께 들어 있다 — 따로 보인다.
                  if (carry != 0)
                    tr('이월 {p0}{p1}', {
                      'p0': carry > 0 ? '+' : '−',
                      'p1': halfDaysText(carry.abs()),
                    }),
                  if (manual != 0)
                    tr('관리자 조정 {p0}{p1}', {
                      'p0': manual > 0 ? '+' : '−',
                      'p1': halfDaysText(manual.abs()),
                    }),
                ].join(' · '),
                style: TextStyle(fontSize: 12, color: hint),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 연차 사용 촉진 통지 카드 — 1차는 남은 연차와 마감(쓸 날을 내는 단추), 2차는 회사가 정한 날. 둘 다 서면 통지서(PDF) 단추.
class _PromotionCard extends StatelessWidget {
  final LeavePromotion promotion;
  final String today;
  final VoidCallback onPlan;
  final VoidCallback onPdf;
  const _PromotionCard({
    required this.promotion,
    required this.today,
    required this.onPlan,
    required this.onPdf,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = promotion;
    final days = halfDaysText(p.remainingHalfDays);
    return Card(
      key: ValueKey('leave-promotion-${p.id}'),
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              p.stage == 1 ? tr('연차 사용 촉진 안내') : tr('연차 사용 시기 지정 통보'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              p.stage == 1
                  ? tr(
                      '쓰지 않은 연차가 {days} 있습니다(연차 기간 {p.expiry}까지). {p.deadline}까지 쓸 날을 정해 내 주세요. 내지 않으면 회사가 쓸 날을 정해 알립니다.',
                      {
                        'days': days,
                        'p.expiry': p.expiry,
                        'p.deadline': p.deadline,
                      },
                    )
                  : tr('회사가 정한 연차 쓸 날: {p0}', {
                      'p0': p.designatedDates.join(', '),
                    }),
            ),
            if (p.message != null) ...[
              const SizedBox(height: 4),
              Text(
                '"${p.message}"${p.sentByName == null ? '' : ' — ${p.sentByName}'}',
                style: TextStyle(fontSize: 12, color: theme.hintColor),
              ),
            ],
            if (p.planDates.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                tr('낸 계획: {p0}', {'p0': p.planDates.join(', ')}),
                key: const ValueKey('leave-promotion-plan'),
              ),
            ],
            const SizedBox(height: 6),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                // 서면 통지서(PDF) — 받은 통지를 문서로 남겨 둔다.
                OutlinedButton.icon(
                  key: ValueKey('leave-notice-pdf-${p.id}'),
                  onPressed: onPdf,
                  icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                  label: Text(tr('통지서 PDF')),
                ),
                if (p.awaitingPlan(today))
                  FilledButton(
                    key: const ValueKey('leave-promotion-submit'),
                    onPressed: onPlan,
                    child: Text(tr('쓸 날 내기')),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 날짜 여러 개 고르기 — [from]~[to] 안에서 [maxDays]개까지(겹치지 않게). 고른 날(정렬)을 돌려준다.
Future<List<String>?> showLeaveDatesDialog(
  BuildContext context, {
  required String title,
  required String from,
  required String to,
  required int maxDays,
}) => showDialog<List<String>>(
  context: context,
  builder: (_) =>
      _LeaveDatesDialog(title: title, from: from, to: to, maxDays: maxDays),
);

class _LeaveDatesDialog extends StatefulWidget {
  final String title;
  final String from;
  final String to;
  final int maxDays;
  const _LeaveDatesDialog({
    required this.title,
    required this.from,
    required this.to,
    required this.maxDays,
  });

  @override
  State<_LeaveDatesDialog> createState() => _LeaveDatesDialogState();
}

class _LeaveDatesDialogState extends State<_LeaveDatesDialog> {
  final _dates = <String>{};

  Future<void> _add() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.parse(widget.from),
      firstDate: DateTime.parse(widget.from),
      lastDate: DateTime.parse(widget.to),
    );
    if (picked != null) setState(() => _dates.add(dateKeyOf(picked)));
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _dates.toList()..sort();
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr('{widget.to}까지, {widget.maxDays}일까지 고를 수 있습니다.', {
                'widget.to': widget.to,
                'widget.maxDays': widget.maxDays,
              }),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final d in sorted)
                  InputChip(
                    label: Text(d),
                    onDeleted: () => setState(() => _dates.remove(d)),
                  ),
                ActionChip(
                  key: const ValueKey('leave-dates-add'),
                  avatar: const Icon(Icons.add, size: 16),
                  label: Text(
                    tr('날 더하기 ({_dates.length}/{widget.maxDays})', {
                      '_dates.length': _dates.length,
                      'widget.maxDays': widget.maxDays,
                    }),
                  ),
                  onPressed: _dates.length >= widget.maxDays ? null : _add,
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
          key: const ValueKey('leave-dates-save'),
          onPressed: _dates.isEmpty
              ? null
              : () => Navigator.of(context).pop(sorted),
          child: Text(tr('내기')),
        ),
      ],
    );
  }
}
