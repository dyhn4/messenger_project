import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../models/groupware_finance.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import 'approval_forms.dart' show ApprovalDateField;
import 'finance_widgets.dart';
import 'groupware_screen.dart';
import 'payroll_admin.dart';
import 'payroll_reports.dart';
import 'payslip_view.dart';
import '../../l10n/tr.dart';

/// 급여 탭 — 내 급여명세서(보낸 대장의 내 것만, 해마다 합계)와, 급여 담당자(그룹웨어 관리자 + 급여 설정의 담당자)에게는 급여 대장 관리
/// (server/src/payroll.js). 금액은 처음엔 가려 두고(옆 사람이 화면을 볼 수 있어서) 눈 단추로 보인다 — 이 앱을 켜 둔 동안만 기억한다.
class PayrollTab extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final GroupwareChanges changes;
  final Session session;
  const PayrollTab({
    super.key,
    required this.api,
    required this.ctx,
    required this.changes,
    required this.session,
  });

  @override
  State<PayrollTab> createState() => _PayrollTabState();
}

/// 금액을 보이기로 했는지(앱을 켜 둔 동안).
bool _revealAmounts = false;

class _PayrollTabState extends State<PayrollTab> {
  List<Payslip>? _mine;
  List<PayrollRun>? _runs;
  bool _canManage = false;
  bool _manage = false;

  /// 금액이 빠져 왔다(비밀번호를 다시 확인해야 함 — 급여 설정).
  bool _locked = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _canManage = widget.ctx.payrollCanManage;
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
      final mine = await widget.api.myPayslips();
      final runs = mine.canManage ? await widget.api.payrollRuns() : null;
      if (!mounted) return;
      setState(() {
        _mine = mine.items;
        _canManage = mine.canManage;
        _locked = mine.locked;
        if (mine.locked) _revealAmounts = false;
        _runs = runs;
        if (!_canManage) _manage = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _openSlip(Payslip slip) async {
    if (_locked && !await askPayrollPassword(context, api: widget.api)) return;
    if (!mounted) return;
    await openPayslipScreen(context, api: widget.api, payslipId: slip.id);
    await _load();
  }

  /// 눈 단추 — 잠겨 있으면 비밀번호를 다시 확인하고 금액을 받아 온다.
  Future<void> _toggleReveal() async {
    if (_revealAmounts) {
      setState(() => _revealAmounts = false);
      return;
    }
    if (_locked) {
      if (!await askPayrollPassword(context, api: widget.api)) return;
      await _load();
      if (_locked) return;
    }
    if (mounted) setState(() => _revealAmounts = true);
  }

  Future<void> _newRun() async {
    final run = await showDialog<PayrollRun>(
      context: context,
      builder: (_) => _NewRunDialog(
        api: widget.api,
        ctx: widget.ctx,
        runs: _runs ?? const [],
      ),
    );
    if (run == null || !mounted) return;
    widget.changes.bump();
    await openPayrollRunScreen(
      context,
      api: widget.api,
      ctx: widget.ctx,
      session: widget.session,
      runId: run.id,
    );
    await _load();
  }

  Future<void> _settings() async {
    await showPayrollSettingsDialog(context, api: widget.api);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return GroupwareEmpty(_error!);
    final mine = _mine;
    if (mine == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (_canManage)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: SegmentedButton<bool>(
                key: const ValueKey('payroll-mode'),
                segments: [
                  ButtonSegment(
                    value: false,
                    label: Text(tr('내 명세서')),
                    icon: const Icon(Icons.receipt_long_outlined),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text(tr('급여 관리')),
                    icon: const Icon(Icons.payments_outlined),
                  ),
                ],
                selected: {_manage},
                onSelectionChanged: (v) => setState(() => _manage = v.first),
              ),
            ),
          if (_manage) ..._manageView() else ..._mineView(mine),
        ],
      ),
    );
  }

  List<Widget> _mineView(List<Payslip> mine) {
    final hint = Theme.of(context).hintColor;
    // 해마다 묶는다(지급일의 해).
    final byYear = <String, List<Payslip>>{};
    for (final s in mine) {
      final year = (s.run?.payDate ?? '').length >= 4
          ? s.run!.payDate.substring(0, 4)
          : '';
      byYear.putIfAbsent(year, () => []).add(s);
    }
    return [
      GroupwareSectionHeader(
        tr('내 급여명세서'),
        trailing: IconButton(
          key: const ValueKey('payroll-reveal'),
          tooltip: _revealAmounts
              ? tr('금액 가리기')
              : _locked
              ? tr('비밀번호 확인 후 금액 보기')
              : tr('금액 보기'),
          icon: Icon(
            _revealAmounts
                ? Icons.visibility_off_outlined
                : _locked
                ? Icons.lock_outline
                : Icons.visibility_outlined,
          ),
          onPressed: _toggleReveal,
        ),
      ),
      if (mine.isEmpty)
        GroupwareEmpty(tr('받은 급여명세서가 없습니다.'))
      else
        for (final entry in byYear.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    entry.key.isEmpty
                        ? tr('지급일 없음')
                        : tr('{y}년', {'y': entry.key}),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(tr('지급 '), style: TextStyle(color: hint, fontSize: 12)),
                MaskedWon(
                  entry.value.fold(0, (s, p) => s + p.gross),
                  reveal: _revealAmounts,
                  style: TextStyle(color: hint, fontSize: 12),
                ),
                Text(
                  tr(' · 실수령 '),
                  style: TextStyle(color: hint, fontSize: 12),
                ),
                MaskedWon(
                  entry.value.fold(0, (s, p) => s + p.net),
                  reveal: _revealAmounts,
                  style: TextStyle(color: hint, fontSize: 12),
                ),
              ],
            ),
          ),
          for (final s in entry.value)
            ListTile(
              key: ValueKey('my-payslip-${s.id}'),
              leading: Badge(
                isLabelVisible: s.viewedAt == null,
                smallSize: 8,
                child: const Icon(Icons.receipt_long_outlined),
              ),
              title: Text(s.run?.title ?? tr('급여명세서')),
              subtitle: Text(
                [
                  tr('지급일 {date}', {'date': s.run?.payDate ?? ''}),
                  if (s.revision > 1) tr('정정 {n}차', {'n': s.revision - 1}),
                ].join(' · '),
              ),
              trailing: MaskedWon(
                s.net,
                reveal: _revealAmounts,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              onTap: () => _openSlip(s),
            ),
        ],
    ];
  }

  List<Widget> _manageView() {
    final runs = _runs ?? const <PayrollRun>[];
    final hint = Theme.of(context).hintColor;
    return [
      GroupwareSectionHeader(
        tr('급여 대장'),
        trailing: Wrap(
          spacing: 6,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('payroll-settings'),
              onPressed: _settings,
              icon: const Icon(Icons.tune, size: 18),
              label: Text(tr('급여 설정')),
            ),
            FilledButton.icon(
              key: const ValueKey('payroll-new-run'),
              onPressed: _newRun,
              icon: const Icon(Icons.add, size: 18),
              label: Text(tr('새 급여 대장')),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          tr(
            '달마다 대장을 만들어 금액을 넣고(직접·엑셀·근태에서 채우기) 보내면 받는 사람마다 알림이 가고 그룹웨어 → 급여에서 자기 명세서만 봅니다. 명세서 내용은 서버에 암호화해 둡니다.',
          ),
          style: TextStyle(fontSize: 12, color: hint),
        ),
      ),
      // 급여 부가 기능(payroll_reports.dart) — 연말정산 자료·퇴직금·4대보험 신고.
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('payroll-year-end'),
              onPressed: () => openYearEndScreen(
                context,
                api: widget.api,
                session: widget.session,
                ctx: widget.ctx,
              ),
              icon: const Icon(Icons.summarize_outlined, size: 18),
              label: Text(tr('연말정산 자료')),
            ),
            OutlinedButton.icon(
              key: const ValueKey('payroll-severance'),
              onPressed: () async {
                await showSeveranceDialog(
                  context,
                  api: widget.api,
                  ctx: widget.ctx,
                  session: widget.session,
                );
                await _load();
              },
              icon: const Icon(Icons.work_off_outlined, size: 18),
              label: Text(tr('퇴직금 계산')),
            ),
            OutlinedButton.icon(
              key: const ValueKey('payroll-insurance'),
              onPressed: () => openInsuranceReportsScreen(
                context,
                api: widget.api,
                session: widget.session,
              ),
              icon: const Icon(Icons.health_and_safety_outlined, size: 18),
              label: Text(tr('4대보험 신고')),
            ),
          ],
        ),
      ),
      if (runs.isEmpty)
        GroupwareEmpty(tr('급여 대장이 없습니다. "새 급여 대장"으로 시작하세요.'))
      else
        for (final r in runs)
          ListTile(
            key: ValueKey('payroll-run-${r.id}'),
            leading: Icon(
              r.published ? Icons.mark_email_read_outlined : Icons.edit_note,
              color: r.published ? Colors.green.shade700 : null,
            ),
            title: Text(r.title),
            subtitle: Text(
              [
                monthLabel(r.payMonth),
                tr('지급일 {date}', {'date': r.payDate}),
                r.published
                    ? tr('보냄 · 확인 {viewed}/{count}명', {
                        'viewed': r.viewedCount,
                        'count': r.slipCount,
                      })
                    : tr('작성 중 · {count}명', {'count': r.slipCount}),
              ].join(' · '),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await openPayrollRunScreen(
                context,
                api: widget.api,
                ctx: widget.ctx,
                session: widget.session,
                runId: r.id,
              );
              await _load();
            },
          ),
    ];
  }
}

/// 새 급여 대장 — 달·지급일·제목·안내 글, 지난 대장에서 항목·금액 이어받기(기본 — 가장 최근 대장).
class _NewRunDialog extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final List<PayrollRun> runs;
  const _NewRunDialog({
    required this.api,
    required this.ctx,
    required this.runs,
  });

  @override
  State<_NewRunDialog> createState() => _NewRunDialogState();
}

class _NewRunDialogState extends State<_NewRunDialog> {
  late String _month = widget.ctx.today.substring(0, 7);
  late String _payDate = '${widget.ctx.today.substring(0, 7)}-25';
  final _title = TextEditingController();
  final _note = TextEditingController();
  late String? _copyFrom = widget.runs.isEmpty ? null : widget.runs.first.id;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final run = await widget.api.createPayrollRun(
        payMonth: _month,
        payDate: _payDate,
        title: _title.text.trim().isEmpty ? null : _title.text.trim(),
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
        copyFromRunId: _copyFrom,
      );
      if (mounted) Navigator.pop(context, run);
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
    final months = [
      for (var i = 2; i >= -12; i--)
        shiftMonth(widget.ctx.today.substring(0, 7), i),
    ];
    return AlertDialog(
      title: Text(tr('새 급여 대장')),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: const ValueKey('new-run-month'),
                      initialValue: _month,
                      decoration: InputDecoration(
                        labelText: tr('귀속 월'),
                        border: const OutlineInputBorder(),
                      ),
                      items: [
                        for (final m in months)
                          DropdownMenuItem(
                            value: m,
                            child: Text(monthLabel(m)),
                          ),
                      ],
                      onChanged: (v) => setState(() => _month = v ?? _month),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ApprovalDateField(
                    label: tr('지급일'),
                    value: _payDate,
                    onChanged: (v) => setState(() => _payDate = v),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('new-run-title'),
                controller: _title,
                maxLength: 60,
                decoration: InputDecoration(
                  labelText: tr('제목(비우면 "{m} 급여")', {'m': monthLabel(_month)}),
                  border: const OutlineInputBorder(),
                ),
              ),
              DropdownButtonFormField<String?>(
                key: const ValueKey('new-run-copy'),
                initialValue: _copyFrom,
                decoration: InputDecoration(
                  labelText: tr('항목·금액'),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem(
                    value: null,
                    child: Text(tr('항목 틀로 새로(금액 0)')),
                  ),
                  for (final r in widget.runs.take(12))
                    DropdownMenuItem(
                      value: r.id,
                      child: Text(
                        tr('{title}에서 이어받기', {'title': r.title}),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _copyFrom = v),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _note,
                maxLength: 1000,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: tr('모두에게 보일 안내(선택)'),
                  border: const OutlineInputBorder(),
                ),
              ),
              Text(
                tr('이 범위의 정회원 이상이 모두 들어갑니다(대장에서 빼거나 더할 수 있습니다).'),
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).hintColor,
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
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
          key: const ValueKey('new-run-save'),
          onPressed: _saving ? null : _save,
          child: Text(tr('만들기')),
        ),
      ],
    );
  }
}
