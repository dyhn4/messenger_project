import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../models/groupware_finance.dart';
import '../../models/groupware_finance_tools.dart';
import '../../services/download_storage.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import 'approval_forms.dart' show ApprovalDateField;
import 'export_templates.dart' show askRrns, pickExportTemplate;
import 'finance_widgets.dart';
import 'groupware_screen.dart';
import 'payroll_admin.dart';
import 'year_end_claim.dart';
import '../../l10n/tr.dart';

/// 급여 부가 기능(급여 담당자) — 한 해 급여 집계·연말정산 어림(사람마다 공제 자료 — year_end_claim.dart, 정산분을 작성 중인 대장에 넣기),
/// 퇴직금 계산(명세서로 만들기), 4대보험 취득·상실 신고 자료(기한·신고함·내보내기 양식으로 파일). 서버는 server/src/payrollReports.js.

Future<void> _download(
  BuildContext context,
  Session session,
  String path,
  String fileName, {
  Map<String, dynamic>? body,
}) async {
  try {
    final local = await session.downloadAuthedFile(
      path,
      fileName: fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_'),
      body: body,
    );
    await openLocalFile(local);
  } catch (e) {
    if (context.mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
  }
}

/// 추징·환급 표시 — 양수는 "추징 1,230원", 음수는 "환급 1,230원".
String settleText(int amount) => amount == 0
    ? tr('차이 없음')
    : amount > 0
    ? tr('추징 {won}', {'won': signedWonText(amount)})
    : tr('환급 {won}', {'won': signedWonText(-amount)});

// ── 한 해 집계·연말정산 ──

Future<void> openYearEndScreen(
  BuildContext context, {
  required GroupwareApi api,
  required Session session,
  required GroupwareContext ctx,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => YearEndScreen(api: api, session: session, ctx: ctx),
  ),
);

class YearEndScreen extends StatefulWidget {
  final GroupwareApi api;
  final Session session;
  final GroupwareContext ctx;
  const YearEndScreen({
    super.key,
    required this.api,
    required this.session,
    required this.ctx,
  });

  @override
  State<YearEndScreen> createState() => _YearEndScreenState();
}

class _YearEndScreenState extends State<YearEndScreen> {
  late int _year = int.parse(widget.ctx.today.substring(0, 4)) - 1;
  PayrollYearSummary? _summary;
  String? _error;
  bool _busy = false;

  /// 사람마다 넣을 정산분(소득세·지방소득세) — 처음엔 어림값, 담당자가 세무 프로그램의 값으로 고친다.
  final Map<String, (TextEditingController, TextEditingController)> _edits = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _clearEdits();
    super.dispose();
  }

  void _clearEdits() {
    for (final (a, b) in _edits.values) {
      a.dispose();
      b.dispose();
    }
    _edits.clear();
  }

  Future<void> _load() async {
    setState(() {
      _summary = null;
      _error = null;
    });
    try {
      final s = await widget.api.payrollYearSummary(_year);
      if (!mounted) return;
      _clearEdits();
      for (final p in s.people) {
        _edits[p.userId] = (
          TextEditingController(text: '${p.estimate.diffIncomeTax}'),
          TextEditingController(text: '${p.estimate.diffLocalTax}'),
        );
      }
      setState(() => _summary = s);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// 한 사람의 공제 자료 — 보고 고치고 확인한다(확인하면 그 사람은 더 못 고침).
  Future<void> _openClaim(PayrollYearPerson p) async {
    YearEndClaimDetail detail;
    try {
      detail = await widget.api.yearEndClaim(p.userId, _year);
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
      return;
    }
    if (!mounted) return;
    final year = _year;
    final saved = await openYearEndClaimForm(
      context,
      title: tr('{name} — {y}년 귀속 공제 자료', {'name': p.name, 'y': year}),
      year: year,
      claim: detail.claim,
      status: detail.status,
      onSave: (claim) => widget.api.saveYearEndClaim(
        p.userId,
        year: year,
        claim: claim,
        clear: claim == null,
      ),
      onConfirm: (confirm, claim) => widget.api.saveYearEndClaim(
        p.userId,
        year: year,
        claim: claim,
        confirmed: confirm,
      ),
    );
    if (saved == true && mounted) await _load();
  }

  Future<void> _apply(PayrollYearSummary s) async {
    if (s.draftRuns.isEmpty) {
      showAppToast(context, tr('작성 중인 급여 대장이 없습니다. 먼저 정산분을 넣을 달의 대장을 만드세요.'));
      return;
    }
    final runId = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(tr('어느 대장에 넣을까요?')),
        children: [
          for (final r in s.draftRuns)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, r.id),
              child: Text(r.title),
            ),
        ],
      ),
    );
    if (runId == null || !mounted) return;
    final rows = <({String userId, int incomeTax, int localTax})>[];
    for (final p in s.people) {
      final (a, b) = _edits[p.userId]!;
      final it = parseWonInput(a.text) ?? 0;
      final lt = parseWonInput(b.text) ?? 0;
      rows.add((userId: p.userId, incomeTax: it, localTax: lt));
    }
    setState(() => _busy = true);
    try {
      final n = await widget.api.applyYearEnd(runId, year: s.year, rows: rows);
      if (mounted) {
        showAppToast(
          context,
          tr('{n}명의 명세서에 "연말정산 소득세·지방소득세"를 넣었습니다.', {'n': n}),
        );
      }
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final s = _summary;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('연말정산 자료')),
        actions: [
          IconButton(
            tooltip: tr('엑셀로 내보내기'),
            icon: const Icon(Icons.download),
            onPressed: () => _download(
              context,
              widget.session,
              widget.api.payrollYearSummaryExportPath(_year),
              '급여집계_$_year.xlsx',
            ),
          ),
        ],
      ),
      floatingActionButton: s != null && s.people.isNotEmpty
          ? FloatingActionButton.extended(
              key: const ValueKey('year-end-apply'),
              onPressed: _busy ? null : () => _apply(s),
              icon: const Icon(Icons.playlist_add),
              label: Text(tr('대장에 정산분 넣기')),
            )
          : null,
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () {
                  setState(() => _year -= 1);
                  _load();
                },
              ),
              Text(
                tr('{y}년 귀속', {'y': _year}),
                key: const ValueKey('year-end-year'),
                style: theme.textTheme.titleMedium,
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () {
                  setState(() => _year += 1);
                  _load();
                },
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              tr(
                '그해 지급일의 보낸 명세서를 모았습니다. 결정세액은 근로소득공제·기본공제(가족 수)·국민연금·보험료·근로소득세액공제·자녀세액공제와, 사람마다의 공제 자료(신용카드·의료비·교육비·기부금·주택자금·연금계좌·월세 등 — 근로자가 내 급여에서 내거나 담당자가 넣음)로 계산한 어림입니다. 세무 프로그램에서 정산한 값이 다르면 아래 칸을 고쳐 대장에 넣으세요(+추징, −환급).',
              ),
              style: TextStyle(fontSize: 12, color: hint),
            ),
          ),
          if (_error != null)
            GroupwareEmpty(_error!)
          else if (s == null)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (s.people.isEmpty)
            GroupwareEmpty(tr('이 해에 보낸 명세서가 없습니다.'))
          else
            for (final p in s.people)
              Card(
                key: ValueKey('year-end-${p.userId}'),
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        [
                          p.name,
                          ?p.employeeNo,
                          tr('가족 {n}명', {'n': p.profile.dependents}),
                          if (p.profile.children > 0)
                            tr('8~20세 자녀 {n}명', {'n': p.profile.children}),
                        ].join(' · '),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        tr(
                          '{m}개월 · 총급여 {g} (비과세 {f} 별도) · 국민연금 {p} · 건강·요양·고용 {i}',
                          {
                            'm': p.totals.months,
                            'g': signedWonText(p.totals.taxable),
                            'f': signedWonText(p.totals.taxFree),
                            'p': signedWonText(p.totals.pension),
                            'i': signedWonText(
                              p.totals.health +
                                  p.totals.longTermCare +
                                  p.totals.employment,
                            ),
                          },
                        ),
                        style: TextStyle(fontSize: 12, color: hint),
                      ),
                      Text(
                        tr('결정세액(어림) {d} · 기납부 {w} → {settle}', {
                          'd': signedWonText(p.estimate.decidedTax),
                          'w': signedWonText(p.totals.incomeTax),
                          'settle': settleText(p.estimate.diffIncomeTax),
                        }),
                        style: TextStyle(fontSize: 12, color: hint),
                      ),
                      Row(
                        children: [
                          Icon(
                            p.claim.confirmed
                                ? Icons.verified_outlined
                                : p.claim.exists
                                ? Icons.assignment_turned_in_outlined
                                : Icons.assignment_outlined,
                            size: 16,
                            color: p.claim.confirmed
                                ? Colors.green.shade700
                                : p.claim.exists
                                ? theme.colorScheme.primary
                                : hint,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              [
                                if (p.claim.confirmed)
                                  tr('공제 자료 확인함')
                                else if (p.claim.submittedAt != null)
                                  tr('공제 자료 냄 — 확인 전')
                                else if (p.claim.exists)
                                  tr('공제 자료(담당자가 넣음)')
                                else
                                  tr('공제 자료 없음'),
                                if (p.estimate.claimDeductions['card']
                                    case final c? when c > 0)
                                  tr('카드 공제 {won}', {'won': signedWonText(c)}),
                                if (p.estimate.claimCredit > 0)
                                  tr('세액공제 {won}', {
                                    'won': signedWonText(
                                      p.estimate.claimCredit,
                                    ),
                                  }),
                              ].join(' · '),
                              style: TextStyle(fontSize: 12, color: hint),
                            ),
                          ),
                          TextButton(
                            key: ValueKey('year-end-claim-${p.userId}'),
                            onPressed: () => _openClaim(p),
                            child: Text(tr('공제 자료')),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              key: ValueKey('year-end-tax-${p.userId}'),
                              controller: _edits[p.userId]!.$1,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    signed: true,
                                  ),
                              decoration: InputDecoration(
                                isDense: true,
                                labelText: tr('정산 소득세(원)'),
                                border: const OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _edits[p.userId]!.$2,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    signed: true,
                                  ),
                              decoration: InputDecoration(
                                isDense: true,
                                labelText: tr('정산 지방소득세(원)'),
                                border: const OutlineInputBorder(),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

// ── 퇴직금 ──

Future<void> showSeveranceDialog(
  BuildContext context, {
  required GroupwareApi api,
  required GroupwareContext ctx,
  required Session session,
}) async {
  PayrollSettings settings;
  try {
    settings = await api.payrollSettings();
  } catch (e) {
    if (context.mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    return;
  }
  if (!context.mounted) return;
  final runId = await showDialog<String>(
    context: context,
    builder: (_) =>
        _SeveranceDialog(api: api, ctx: ctx, people: settings.people),
  );
  if (runId != null && context.mounted) {
    await openPayrollRunScreen(
      context,
      api: api,
      ctx: ctx,
      session: session,
      runId: runId,
    );
  }
}

class _SeveranceDialog extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final List<({String id, String name, String username})> people;
  const _SeveranceDialog({
    required this.api,
    required this.ctx,
    required this.people,
  });

  @override
  State<_SeveranceDialog> createState() => _SeveranceDialogState();
}

class _SeveranceDialogState extends State<_SeveranceDialog> {
  String? _userId;
  late String _lastDay = widget.ctx.today;
  String? _hireDate;
  final _wages = TextEditingController();
  final _bonus = TextEditingController();
  final _leavePay = TextEditingController();
  final _hourly = TextEditingController();
  SeveranceResult? _result;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_wages, _bonus, _leavePay, _hourly]) {
      c.dispose();
    }
    super.dispose();
  }

  int? _won(TextEditingController c) =>
      c.text.trim().isEmpty ? null : parseWonInput(c.text);

  Future<void> _calc() async {
    if (_userId == null) {
      setState(() => _error = tr('사람을 고르세요.'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.api.calculateSeverance(
        userId: _userId!,
        lastDay: _lastDay,
        hireDate: _hireDate,
        wages: _won(_wages),
        annualBonus: _won(_bonus),
        leavePay: _won(_leavePay),
        hourlyWage: _won(_hourly),
      );
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _makeRun() async {
    String payDate = widget.ctx.today;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(tr('퇴직금 명세서 만들기')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(
                  '그 사람 한 명의 작성 중인 급여 대장을 만듭니다(지급 퇴직금, 공제 퇴직소득세·지방소득세). 확인한 뒤 보내세요.',
                ),
              ),
              const SizedBox(height: 12),
              ApprovalDateField(
                label: tr('지급일'),
                value: payDate,
                onChanged: (v) => setLocal(() => payDate = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr('취소')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(tr('만들기')),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final runId = await widget.api.createSeveranceRun(
        userId: _userId!,
        lastDay: _lastDay,
        payDate: payDate,
        hireDate: _hireDate,
        wages: _won(_wages),
        annualBonus: _won(_bonus),
        leavePay: _won(_leavePay),
        hourlyWage: _won(_hourly),
      );
      if (mounted) Navigator.pop(context, runId);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  Widget _money(TextEditingController c, String label, Key key) => SizedBox(
    width: 200,
    child: TextField(
      key: key,
      controller: c,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final r = _result;
    String line(String label, String value) => '$label  $value';
    return AlertDialog(
      title: Text(tr('퇴직금 계산')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                key: const ValueKey('severance-person'),
                initialValue: _userId,
                decoration: InputDecoration(
                  labelText: tr('퇴직하는 사람'),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  for (final p in widget.people)
                    DropdownMenuItem(
                      value: p.id,
                      child: Text('${p.name} (${p.username})'),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _userId = v;
                  _result = null;
                }),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ApprovalDateField(
                    label: tr('마지막 근무일'),
                    value: _lastDay,
                    onChanged: (v) => setState(() => _lastDay = v),
                  ),
                  ApprovalDateField(
                    label: tr('입사일(비우면 관리 탭 값)'),
                    value: _hireDate,
                    onChanged: (v) => setState(() => _hireDate = v),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _money(
                    _wages,
                    tr('3개월 임금 총액(비우면 명세서로)'),
                    const ValueKey('severance-wages'),
                  ),
                  _money(
                    _bonus,
                    tr('연간 상여금'),
                    const ValueKey('severance-bonus'),
                  ),
                  _money(
                    _leavePay,
                    tr('연차수당(전년도 미사용분)'),
                    const ValueKey('severance-leave'),
                  ),
                  _money(
                    _hourly,
                    tr('통상시급(비우면 관리 탭 값)'),
                    const ValueKey('severance-hourly'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                tr(
                  '퇴직금 = 1일 평균임금 × 30일 × 재직일수 ÷ 365(1년 이상 일한 사람). 평균임금은 퇴직 전 3개월 임금 + 상여·연차수당의 3/12을 그 기간 날수로 나누고, 통상임금(통상시급 × 8)보다 적으면 통상임금으로 합니다. 퇴직소득세는 2023년 이후 근속연수공제·환산급여 방식입니다. 참고용 계산입니다.',
                ),
                style: TextStyle(fontSize: 12, color: hint),
              ),
              if (r != null) ...[
                const Divider(height: 24),
                Text(
                  r.eligible
                      ? tr('퇴직금 {won}', {'won': signedWonText(r.amount)})
                      : tr('계속근로기간이 1년이 되지 않아 퇴직금이 없습니다.'),
                  key: const ValueKey('severance-amount'),
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                for (final text in [
                  line(
                    tr('재직'),
                    tr('{from} ~ {to} ({d}일, 근속 {y}년)', {
                      'from': r.hireDate,
                      'to': r.lastDay,
                      'd': r.serviceDays,
                      'y': r.serviceYears,
                    }),
                  ),
                  line(
                    tr('평균임금 기간'),
                    tr('{from} ~ {to} ({d}일)', {
                      'from': r.periodFrom,
                      'to': r.periodTo,
                      'd': r.periodDays,
                    }),
                  ),
                  for (final w in r.wageBreakdown)
                    line(
                      '  ${monthLabel(w.payMonth)}',
                      tr('{gross} × {d}/{m}일 = {amount}', {
                        'gross': signedWonText(w.gross),
                        'd': w.days,
                        'm': w.monthDays,
                        'amount': signedWonText(w.amount),
                      }),
                    ),
                  line(
                    tr('3개월 임금'),
                    tr('{w} + 상여 {b} + 연차 {l}', {
                      'w': signedWonText(r.wages),
                      'b': signedWonText(r.bonusAdd),
                      'l': signedWonText(r.leaveAdd),
                    }),
                  ),
                  line(
                    tr('1일 평균임금'),
                    r.usedOrdinary
                        ? tr('{won}(통상임금 — 평균임금 {avg}보다 큼)', {
                            'won': signedWonText(r.dailyWage.floor()),
                            'avg': signedWonText(r.averageDailyWage.floor()),
                          })
                        : signedWonText(r.dailyWage.floor()),
                  ),
                  line(
                    tr('퇴직소득세'),
                    tr('{t} · 지방소득세 {l} (과세표준 {b})', {
                      't': signedWonText(r.incomeTax),
                      'l': signedWonText(r.localTax),
                      'b': signedWonText(r.taxBase),
                    }),
                  ),
                  line(tr('실지급'), signedWonText(r.net)),
                ])
                  Text(text, style: const TextStyle(fontSize: 13)),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('닫기')),
        ),
        if (r != null && r.eligible)
          OutlinedButton(
            key: const ValueKey('severance-make-run'),
            onPressed: _busy ? null : _makeRun,
            child: Text(tr('명세서로 만들기')),
          ),
        FilledButton(
          key: const ValueKey('severance-calc'),
          onPressed: _busy ? null : _calc,
          child: Text(tr('계산')),
        ),
      ],
    );
  }
}

// ── 4대보험 취득·상실 신고 ──

Future<void> openInsuranceReportsScreen(
  BuildContext context, {
  required GroupwareApi api,
  required Session session,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => InsuranceReportsScreen(api: api, session: session),
  ),
);

class InsuranceReportsScreen extends StatefulWidget {
  final GroupwareApi api;
  final Session session;
  const InsuranceReportsScreen({
    super.key,
    required this.api,
    required this.session,
  });

  @override
  State<InsuranceReportsScreen> createState() => _InsuranceReportsScreenState();
}

class _InsuranceReportsScreenState extends State<InsuranceReportsScreen> {
  InsuranceReportList? _list;
  List<({String id, String name, String username})> _people = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.api.insuranceReports(),
        if (_people.isEmpty) widget.api.payrollSettings(),
      ]);
      if (!mounted) return;
      setState(() {
        _list = results[0] as InsuranceReportList;
        if (results.length > 1) {
          _people = (results[1] as PayrollSettings).people;
        }
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _edit({
    InsuranceReport? report,
    String? kind,
    String? userId,
    String? eventDate,
  }) async {
    final list = _list;
    if (list == null) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _InsuranceReportDialog(
        api: widget.api,
        people: _people,
        lossReasons: list.lossReasons,
        today: list.today,
        report: report,
        kind: kind,
        userId: userId,
        eventDate: eventDate,
      ),
    );
    if (saved == true) await _load();
  }

  /// 신고 파일 — 아직 신고하지 않은 그 종류를, 고른 내보내기 양식으로. 양식에 주민등록번호 칸이 있으면 사람마다 받아 POST로 보낸다
  /// (서버는 파일에만 쓰고 남기지 않는다).
  Future<void> _export(String kind) async {
    final list = _list;
    if (list == null) return;
    final pending = list.items
        .where((r) => r.kind == kind && r.filedAt == null)
        .toList();
    if (pending.isEmpty) {
      showAppToast(
        context,
        kind == 'acquire'
            ? tr('아직 신고하지 않은 취득 신고가 없습니다.')
            : tr('아직 신고하지 않은 상실 신고가 없습니다.'),
      );
      return;
    }
    final template = await pickExportTemplate(
      context,
      api: widget.api,
      kind: kind,
      title: kind == 'acquire' ? tr('취득 신고 파일') : tr('상실 신고 파일'),
      intro: Text(
        tr('{n}명 — {names}', {
          'n': pending.length,
          'names': pending.map((r) => r.userName).join(', '),
        }),
        key: const ValueKey('insurance-export-intro'),
      ),
    );
    if (template == null || !mounted) return;
    var rrns = const <String, String>{};
    if (template.wantsRrn) {
      final got = await askRrns(context, [
        for (final r in pending) (id: r.id, name: r.userName),
      ]);
      if (got == null || !mounted) return;
      rrns = got;
    }
    final ext = template.fileType == 'csv' ? 'csv' : 'xlsx';
    final name = kind == 'acquire' ? '4대보험_취득.$ext' : '4대보험_상실.$ext';
    final templateId = template.builtin ? null : template.id;
    await _download(
      context,
      widget.session,
      rrns.isEmpty
          ? widget.api.insuranceReportExportPath(kind, template: templateId)
          : widget.api.insuranceReportExportPostPath,
      name,
      body: rrns.isEmpty
          ? null
          : widget.api.insuranceReportExportBody(
              kind,
              template: templateId,
              rrns: rrns,
            ),
    );
  }

  Future<void> _toggleFiled(InsuranceReport r) async {
    try {
      await widget.api.saveInsuranceReport(id: r.id, filed: r.filedAt == null);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final list = _list;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('4대보험 취득·상실 신고')),
        actions: [
          PopupMenuButton<String>(
            key: const ValueKey('insurance-export'),
            tooltip: tr('신고 파일'),
            icon: const Icon(Icons.download),
            onSelected: _export,
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'acquire',
                child: Text(tr('취득 신고 파일(아직 안 한 것)')),
              ),
              PopupMenuItem(
                value: 'lose',
                child: Text(tr('상실 신고 파일(아직 안 한 것)')),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('insurance-add'),
        onPressed: list == null ? null : () => _edit(),
        icon: const Icon(Icons.add),
        label: Text(tr('신고 더하기')),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                tr(
                  '입사하면 취득, 퇴사하면 상실 신고를 그 달의 다음 달 15일까지 4대사회보험 정보연계센터(EDI)에서 합니다. 여기서는 신고할 사람·기한을 챙기고, 내려받기(위 단추)에서 EDI 일괄 신고 양식에 맞춘 내보내기 양식을 골라 파일(보수월액·보수총액·부호)을 받습니다. 주민등록번호는 서버에 두지 않고 파일을 받을 때만 넣습니다.',
                ),
                style: TextStyle(fontSize: 12, color: hint),
              ),
            ),
            if (_error != null)
              GroupwareEmpty(_error!)
            else if (list == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              if (list.suggestions.isNotEmpty) ...[
                GroupwareSectionHeader(tr('취득 신고할 사람(입사일로 짐작)')),
                for (final s in list.suggestions)
                  ListTile(
                    key: ValueKey('insurance-suggest-${s.userId}'),
                    leading: const Icon(Icons.person_add_alt),
                    title: Text(s.name),
                    subtitle: Text(tr('입사일 {date}', {'date': s.eventDate})),
                    trailing: TextButton(
                      onPressed: () => _edit(
                        kind: 'acquire',
                        userId: s.userId,
                        eventDate: s.eventDate,
                      ),
                      child: Text(tr('신고 더하기')),
                    ),
                  ),
              ],
              GroupwareSectionHeader(tr('신고')),
              if (list.items.isEmpty)
                GroupwareEmpty(tr('신고가 없습니다.'))
              else
                for (final r in list.items)
                  ListTile(
                    key: ValueKey('insurance-${r.id}'),
                    leading: Icon(
                      r.acquire ? Icons.login : Icons.logout,
                      color: r.filedAt != null ? Colors.green.shade700 : null,
                    ),
                    title: Text(
                      '${r.userName} · ${r.acquire ? tr('취득') : tr('상실')} ${r.eventDate}',
                    ),
                    subtitle: Text(
                      [
                        if (r.filedAt != null)
                          tr('신고함 · {by}', {'by': r.filedByName ?? ''})
                        else
                          tr('기한 {date}', {'date': r.deadline}),
                        if (r.acquire && r.monthlyPay != null)
                          tr('보수월액 {won}', {
                            'won': signedWonText(r.monthlyPay!),
                          }),
                        if (!r.acquire && r.reasonCode != null)
                          list.lossReasons
                                  .where((x) => x.code == r.reasonCode)
                                  .firstOrNull
                                  ?.label ??
                              r.reasonCode!,
                        ?r.memo,
                      ].join(' · '),
                      style: TextStyle(
                        color:
                            r.filedAt == null &&
                                r.deadline.compareTo(list.today) < 0
                            ? theme.colorScheme.error
                            : null,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Tooltip(
                          message: r.filedAt == null
                              ? tr('신고했다고 표시')
                              : tr('신고 표시 지우기'),
                          child: Checkbox(
                            key: ValueKey('insurance-filed-${r.id}'),
                            value: r.filedAt != null,
                            onChanged: (_) => _toggleFiled(r),
                          ),
                        ),
                        IconButton(
                          tooltip: tr('지우기'),
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            final ok = await confirmAction(
                              context,
                              title: tr('신고 지우기'),
                              message: tr('{name}님의 신고를 지울까요?', {
                                'name': r.userName,
                              }),
                              okLabel: tr('지우기'),
                              danger: true,
                            );
                            if (!ok) return;
                            try {
                              await widget.api.deleteInsuranceReport(r.id);
                              await _load();
                            } catch (e) {
                              if (context.mounted) {
                                showAppToast(context, tr('실패: {e}', {'e': e}));
                              }
                            }
                          },
                        ),
                      ],
                    ),
                    onTap: () => _edit(report: r),
                  ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InsuranceReportDialog extends StatefulWidget {
  final GroupwareApi api;
  final List<({String id, String name, String username})> people;
  final List<({String code, String label})> lossReasons;
  final String today;
  final InsuranceReport? report;
  final String? kind;
  final String? userId;
  final String? eventDate;
  const _InsuranceReportDialog({
    required this.api,
    required this.people,
    required this.lossReasons,
    required this.today,
    this.report,
    this.kind,
    this.userId,
    this.eventDate,
  });

  @override
  State<_InsuranceReportDialog> createState() => _InsuranceReportDialogState();
}

class _InsuranceReportDialogState extends State<_InsuranceReportDialog> {
  late String _kind = widget.report?.kind ?? widget.kind ?? 'acquire';
  late String? _userId = widget.report?.userId ?? widget.userId;
  late String _date =
      widget.report?.eventDate ?? widget.eventDate ?? widget.today;
  late String? _reason = widget.report?.reasonCode;
  late final _pay = TextEditingController(
    text: widget.report?.monthlyPay?.toString(),
  );
  late final _hours = TextEditingController(
    text: widget.report?.weeklyHours?.toString(),
  );
  late final _memo = TextEditingController(text: widget.report?.memo);
  late final _jobCode = TextEditingController(text: widget.report?.jobCode);
  late final _pensionCode = TextEditingController(
    text: widget.report?.pensionCode,
  );
  late final _healthCode = TextEditingController(
    text: widget.report?.healthCode,
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _pay.dispose();
    _hours.dispose();
    _memo.dispose();
    _jobCode.dispose();
    _pensionCode.dispose();
    _healthCode.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_userId == null) {
      setState(() => _error = tr('사람을 고르세요.'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final editing = widget.report != null;
      await widget.api.saveInsuranceReport(
        id: widget.report?.id,
        kind: editing ? null : _kind,
        userId: editing ? null : _userId,
        eventDate: _date,
        reasonCode: _kind == 'lose' ? (_reason ?? '') : null,
        monthlyPay: _pay.text.trim().isEmpty ? null : parseWonInput(_pay.text),
        weeklyHours: _hours.text.trim().isEmpty
            ? null
            : num.tryParse(_hours.text.trim()),
        jobCode: _kind == 'acquire' ? _jobCode.text.trim() : null,
        pensionCode: _pensionCode.text.trim(),
        healthCode: _healthCode.text.trim(),
        memo: _memo.text.trim(),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final editing = widget.report != null;
    return AlertDialog(
      title: Text(editing ? tr('신고 고치기') : tr('신고 더하기')),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'acquire', label: Text(tr('취득(입사)'))),
                  ButtonSegment(value: 'lose', label: Text(tr('상실(퇴사)'))),
                ],
                selected: {_kind},
                onSelectionChanged: editing
                    ? null
                    : (v) => setState(() => _kind = v.first),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                key: const ValueKey('insurance-person'),
                initialValue: _userId,
                decoration: InputDecoration(
                  labelText: tr('사람'),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  for (final p in widget.people)
                    DropdownMenuItem(value: p.id, child: Text(p.name)),
                ],
                onChanged: editing ? null : (v) => setState(() => _userId = v),
              ),
              const SizedBox(height: 8),
              ApprovalDateField(
                label: _kind == 'acquire'
                    ? tr('취득일(입사일)')
                    : tr('상실일(마지막 근무일 다음 날)'),
                value: _date,
                onChanged: (v) => setState(() => _date = v),
              ),
              const SizedBox(height: 8),
              if (_kind == 'lose')
                DropdownButtonFormField<String?>(
                  initialValue: _reason,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: tr('상실 사유'),
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    for (final r in widget.lossReasons)
                      DropdownMenuItem(
                        value: r.code,
                        child: Text(
                          '${r.code} ${r.label}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => _reason = v),
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _pay,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: tr('월 보수액(비우면 최근 명세서)'),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 140,
                      child: TextField(
                        controller: _hours,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: tr('주 소정근로시간'),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (_kind == 'acquire') ...[
                    Expanded(
                      child: TextField(
                        key: const ValueKey('insurance-job-code'),
                        controller: _jobCode,
                        maxLength: 10,
                        decoration: InputDecoration(
                          labelText: tr('직종 부호'),
                          counterText: '',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: TextField(
                      key: const ValueKey('insurance-pension-code'),
                      controller: _pensionCode,
                      maxLength: 10,
                      decoration: InputDecoration(
                        labelText: _kind == 'acquire'
                            ? tr('국민연금 취득 부호')
                            : tr('국민연금 상실 부호'),
                        counterText: '',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('insurance-health-code'),
                      controller: _healthCode,
                      maxLength: 10,
                      decoration: InputDecoration(
                        labelText: _kind == 'acquire'
                            ? tr('건강보험 취득 부호')
                            : tr('건강보험 상실 부호'),
                        counterText: '',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  tr('부호는 EDI 일괄 신고 파일에 그대로 옮깁니다(신고서 뒤쪽의 부호표를 보세요). 비워도 됩니다.'),
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _memo,
                maxLength: 300,
                decoration: InputDecoration(
                  labelText: tr('메모(접수번호 등)'),
                  border: const OutlineInputBorder(),
                ),
              ),
              if (_error != null)
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('insurance-save'),
          onPressed: _saving ? null : _save,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}
