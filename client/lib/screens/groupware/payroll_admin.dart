import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../models/groupware_finance.dart';
import '../../services/download_storage.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../services/time_format.dart';
import '../../widgets/app_toast.dart';
import 'approval_forms.dart' show ApprovalDateField;
import 'finance_widgets.dart';
import 'groupware_screen.dart';
import 'payslip_view.dart';
import '../../l10n/tr.dart';

/// 급여 담당자 화면 — 급여 대장 하나(명세서들·근태에서 채우기·4대보험 공제 어림·엑셀 내보내기/가져오기·보내기/보내기 취소), 명세서 고치기
/// (보낸 뒤에는 정정 사유가 꼭), 급여 설정(담당자·회사 이름·항목 틀·4대보험 요율·사번). 서버는 server/src/payroll.js.
Future<void> openPayrollRunScreen(
  BuildContext context, {
  required GroupwareApi api,
  required GroupwareContext ctx,
  required Session session,
  required String runId,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) =>
        PayrollRunScreen(api: api, ctx: ctx, session: session, runId: runId),
  ),
);

class PayrollRunScreen extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final Session session;
  final String runId;
  const PayrollRunScreen({
    super.key,
    required this.api,
    required this.ctx,
    required this.session,
    required this.runId,
  });

  @override
  State<PayrollRunScreen> createState() => _PayrollRunScreenState();
}

class _PayrollRunScreenState extends State<PayrollRunScreen> {
  PayrollRunDetail? _detail;
  String? _error;
  bool _busy = false;
  final _filter = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.payrollRun(widget.runId);
      if (mounted) {
        setState(() {
          _detail = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// [action]을 돌리고 다시 받는다 — 실패는 알림으로.
  Future<void> _run(Future<String?> Function() action) async {
    setState(() => _busy = true);
    try {
      final message = await action();
      if (mounted && message != null) showAppToast(context, message);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _publish(PayrollRunDetail d) async {
    final negative = d.payslips.where((s) => s.net < 0).length;
    final ok = await confirmAction(
      context,
      title: tr('급여명세서 보내기'),
      message: [
        tr(
          '{count}명에게 "{title}" 명세서를 보냅니다. 받는 사람마다 알림이 가고(금액은 알림에 넣지 않음) 그룹웨어 → 급여에서 봅니다.',
          {'count': d.payslips.length, 'title': d.run.title},
        ),
        if (negative > 0) tr('실수령액이 0원보다 적은 사람이 {n}명 있습니다.', {'n': negative}),
        tr('보낸 뒤에 고치면 정정 사유와 함께 받는 사람에게 다시 알립니다.'),
      ].join('\n\n'),
      okLabel: tr('보내기'),
    );
    if (!ok) return;
    await _run(() async {
      await widget.api.publishPayrollRun(d.run.id);
      return tr('명세서를 보냈습니다.');
    });
  }

  Future<void> _unpublish(PayrollRunDetail d) async {
    final reason = await askText(
      context,
      title: tr('보내기 취소'),
      message: tr('받는 사람 화면에서 이 대장의 명세서가 사라지고 다시 작성 중이 됩니다(감사 로그에 남음).'),
      label: tr('사유'),
      okLabel: tr('보내기 취소'),
    );
    if (reason == null) return;
    await _run(() async {
      await widget.api.unpublishPayrollRun(d.run.id, reason);
      return tr('보내기를 취소했습니다.');
    });
  }

  Future<void> _delete(PayrollRunDetail d) async {
    final ok = await confirmAction(
      context,
      title: tr('급여 대장 지우기'),
      message: tr('"{title}"과 명세서 {n}장을 지울까요?', {
        'title': d.run.title,
        'n': d.payslips.length,
      }),
      okLabel: tr('지우기'),
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.deletePayrollRun(d.run.id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showAppToast(context, tr('실패: {e}', {'e': e}));
      }
    }
  }

  Future<void> _editHeader(PayrollRunDetail d) async {
    final result =
        await showDialog<({String title, String payDate, String note})>(
          context: context,
          builder: (_) => _RunHeaderDialog(run: d.run),
        );
    if (result == null) return;
    await _run(() async {
      await widget.api.updatePayrollRun(
        d.run.id,
        title: result.title,
        payDate: result.payDate,
        note: result.note,
      );
      return null;
    });
  }

  Future<void> _fillAttendance(PayrollRunDetail d) async {
    final ok = await confirmAction(
      context,
      title: tr('근태에서 채우기'),
      message: tr(
        '{month}의 출퇴근 기록으로 명세서마다 근무 내역(출근일·근로·연장·야간·휴일 시간)을 넣고, 통상시급을 정한 사람은 연장·야간·휴일근로수당 금액과 계산 방법을 바꿉니다. 다른 항목은 그대로 둡니다.',
        {'month': monthLabel(d.run.payMonth)},
      ),
      okLabel: tr('채우기'),
    );
    if (!ok) return;
    await _run(() async {
      final r = await widget.api.fillPayrollAttendance(d.run.id);
      return tr('{n}명의 근무 내역을 채웠습니다(수당까지 {m}명).', {
        'n': r.updated,
        'm': r.withAllowance,
      });
    });
  }

  Future<void> _calcDeductions(PayrollRunDetail d) async {
    final ok = await confirmAction(
      context,
      title: tr('4대보험 공제 계산'),
      message: tr(
        '과세 대상 급여(비과세 항목 뺀 지급 총액)로 국민연금·건강보험·장기요양보험·고용보험을 급여 설정의 요율대로 어림해 넣고, 소득세가 있으면 지방소득세를 넣습니다. 소득세(간이세액표)는 계산하지 않습니다. 실제 고지액·나이·감면에 따라 다를 수 있으니 확인하세요.',
      ),
      okLabel: tr('계산'),
    );
    if (!ok) return;
    await _run(() async {
      final n = await widget.api.calcPayrollDeductions(d.run.id);
      return tr('{n}명의 공제를 계산했습니다.', {'n': n});
    });
  }

  Future<void> _export(PayrollRunDetail d) async {
    await _run(() async {
      final name = '급여대장_${d.run.payMonth}_${d.run.title}.xlsx'.replaceAll(
        RegExp(r'[\\/:*?"<>|]'),
        '_',
      );
      final path = await widget.session.downloadAuthedFile(
        widget.api.payrollExportPath(d.run.id),
        fileName: name,
      );
      await openLocalFile(path);
      return null;
    });
  }

  Future<void> _import(PayrollRunDetail d) async {
    final file = await pickSheetFile(title: tr('급여대장 가져오기'));
    if (file == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final preview = await widget.api.importPayroll(
        d.run.id,
        file.bytes,
        dryRun: true,
        contentType: file.contentType,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      final apply = await showDialog<bool>(
        context: context,
        builder: (_) =>
            _PayrollImportPreview(result: preview, fileName: file.name),
      );
      if (apply != true) return;
      await _run(() async {
        final r = await widget.api.importPayroll(
          d.run.id,
          file.bytes,
          dryRun: false,
          contentType: file.contentType,
        );
        return tr('가져왔습니다 — 고침 {u}명, 더함 {a}명', {'u': r.updated, 'a': r.added});
      });
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showAppToast(context, tr('실패: {e}', {'e': e}));
      }
    }
  }

  Future<void> _addPeople(PayrollRunDetail d) async {
    if (d.addable.isEmpty) {
      showAppToast(context, tr('더할 구성원이 없습니다.'));
      return;
    }
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (_) => _PickPeopleDialog(people: d.addable),
    );
    if (picked == null || picked.isEmpty) return;
    await _run(() async {
      await widget.api.addPayslips(d.run.id, picked);
      return tr('{n}명을 더했습니다.', {'n': picked.length});
    });
  }

  Future<void> _editSlip(PayrollRunDetail d, Payslip slip) async {
    final saved = await showDialog<Payslip>(
      context: context,
      builder: (_) => PayslipEditorDialog(
        api: widget.api,
        slip: slip,
        published: d.run.published,
      ),
    );
    if (saved != null) await _load();
  }

  Future<void> _removeSlip(PayrollRunDetail d, Payslip slip) async {
    final ok = await confirmAction(
      context,
      title: tr('명세서 빼기'),
      message: tr('{name}님을 이 대장에서 뺄까요?', {'name': slip.userName}),
      okLabel: tr('빼기'),
      danger: true,
    );
    if (!ok) return;
    await _run(() async {
      await widget.api.deletePayslip(slip.id);
      return null;
    });
  }

  void _preview(PayrollRunDetail d, Payslip slip) {
    final full = Payslip(
      id: slip.id,
      runId: slip.runId,
      userId: slip.userId,
      userName: slip.userName,
      employeeNo: slip.employeeNo,
      department: slip.department,
      position: slip.position,
      revision: slip.revision,
      correctedAt: slip.correctedAt,
      viewedAt: slip.viewedAt,
      gross: slip.gross,
      taxable: slip.taxable,
      taxFree: slip.taxFree,
      deductionTotal: slip.deductionTotal,
      net: slip.net,
      earnings: slip.earnings,
      deductions: slip.deductions,
      work: slip.work,
      memo: slip.memo,
      corrections: slip.corrections,
      run: d.run,
      companyName: d.companyName,
    );
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        contentPadding: const EdgeInsets.all(8),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(child: PayslipView(slip: full)),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => payslipPdf(dialogContext, slip: full, print: true),
            icon: const Icon(Icons.print_outlined, size: 18),
            label: Text(tr('인쇄')),
          ),
          TextButton.icon(
            onPressed: () => payslipPdf(dialogContext, slip: full),
            icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
            label: Text(tr('PDF로 저장')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(tr('닫기')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    if (d == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr('급여 대장'))),
        body: Center(
          child: _error != null
              ? GroupwareEmpty(_error!)
              : const CircularProgressIndicator(),
        ),
      );
    }
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final draft = !d.run.published;
    final q = _filter.text.trim().toLowerCase();
    final slips = q.isEmpty
        ? d.payslips
        : d.payslips
              .where(
                (s) =>
                    s.userName.toLowerCase().contains(q) ||
                    (s.employeeNo ?? '').toLowerCase().contains(q) ||
                    (s.department ?? '').toLowerCase().contains(q),
              )
              .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(d.run.title),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          PopupMenuButton<String>(
            key: const ValueKey('payroll-run-menu'),
            enabled: !_busy,
            onSelected: (v) => switch (v) {
              'header' => _editHeader(d),
              'attendance' => _fillAttendance(d),
              'deductions' => _calcDeductions(d),
              'export' => _export(d),
              'import' => _import(d),
              'add' => _addPeople(d),
              'unpublish' => _unpublish(d),
              'delete' => _delete(d),
              _ => null,
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'header', child: Text(tr('제목·지급일·안내 고치기'))),
              if (draft) ...[
                PopupMenuItem(value: 'attendance', child: Text(tr('근태에서 채우기'))),
                PopupMenuItem(
                  value: 'deductions',
                  child: Text(tr('4대보험 공제 계산')),
                ),
                PopupMenuItem(value: 'import', child: Text(tr('엑셀 가져오기'))),
                PopupMenuItem(value: 'add', child: Text(tr('사람 더하기'))),
              ],
              PopupMenuItem(value: 'export', child: Text(tr('엑셀로 내보내기'))),
              if (!draft)
                PopupMenuItem(value: 'unpublish', child: Text(tr('보내기 취소'))),
              if (draft)
                PopupMenuItem(value: 'delete', child: Text(tr('대장 지우기'))),
            ],
          ),
        ],
      ),
      floatingActionButton: draft
          ? FloatingActionButton.extended(
              key: const ValueKey('payroll-publish'),
              onPressed: _busy || d.payslips.isEmpty ? null : () => _publish(d),
              icon: const Icon(Icons.send),
              label: Text(tr('보내기')),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            Card(
              margin: const EdgeInsets.all(16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      [
                        monthLabel(d.run.payMonth),
                        tr('지급일 {date}', {'date': d.run.payDate}),
                        draft
                            ? tr('작성 중')
                            : tr('보냄 {at} · {by}', {
                                'at': d.run.publishedAt == null
                                    ? ''
                                    : formatDateTime(d.run.publishedAt!),
                                'by': d.run.publishedByName ?? '',
                              }),
                      ].join(' · '),
                      key: const ValueKey('payroll-run-status'),
                      style: TextStyle(color: hint),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 24,
                      runSpacing: 8,
                      children: [
                        _Figure(
                          label: tr('인원'),
                          value: tr('{n}명', {'n': d.payslips.length}),
                        ),
                        _Figure(
                          label: tr('지급 총액'),
                          value: signedWonText(d.gross),
                        ),
                        _Figure(
                          label: tr('공제 총액'),
                          value: signedWonText(d.deductionTotal),
                        ),
                        _Figure(
                          label: tr('실수령 합계'),
                          value: signedWonText(d.net),
                        ),
                        if (!draft)
                          _Figure(
                            label: tr('확인'),
                            value: tr('{v}/{n}명', {
                              'v': d.payslips
                                  .where((s) => s.viewedAt != null)
                                  .length,
                              'n': d.payslips.length,
                            }),
                          ),
                      ],
                    ),
                    if (d.run.note != null) ...[
                      const SizedBox(height: 8),
                      Text(d.run.note!, style: const TextStyle(fontSize: 13)),
                    ],
                    if (draft) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          OutlinedButton.icon(
                            key: const ValueKey('payroll-fill-attendance'),
                            onPressed: _busy ? null : () => _fillAttendance(d),
                            icon: const Icon(Icons.schedule, size: 18),
                            label: Text(tr('근태에서 채우기')),
                          ),
                          OutlinedButton.icon(
                            key: const ValueKey('payroll-calc-deductions'),
                            onPressed: _busy ? null : () => _calcDeductions(d),
                            icon: const Icon(
                              Icons.calculate_outlined,
                              size: 18,
                            ),
                            label: Text(tr('4대보험 공제 계산')),
                          ),
                          OutlinedButton.icon(
                            key: const ValueKey('payroll-import'),
                            onPressed: _busy ? null : () => _import(d),
                            icon: const Icon(Icons.upload_file, size: 18),
                            label: Text(tr('엑셀 가져오기')),
                          ),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : () => _export(d),
                            icon: const Icon(Icons.download, size: 18),
                            label: Text(tr('엑셀로 내보내기')),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (d.payslips.length > 8)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _filter,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: tr('이름·사번·부서로 찾기'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            if (d.payslips.isEmpty)
              GroupwareEmpty(tr('명세서가 없습니다. 메뉴의 "사람 더하기"로 넣으세요.')),
            for (final s in slips)
              ListTile(
                key: ValueKey('payroll-slip-${s.userId}'),
                leading: CircleAvatar(
                  radius: 16,
                  child: Text(
                    s.userName.isEmpty ? '?' : s.userName.characters.first,
                  ),
                ),
                title: Text(
                  [s.userName, ?s.employeeNo, ?s.department].join(' · '),
                ),
                subtitle: Text(
                  [
                    tr('지급 {won}', {'won': signedWonText(s.gross)}),
                    tr('공제 {won}', {'won': signedWonText(s.deductionTotal)}),
                    if (s.revision > 1) tr('정정 {n}차', {'n': s.revision - 1}),
                    if (s.unreadable) tr('내용을 읽지 못함'),
                  ].join(' · '),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      signedWonText(s.net),
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: s.net < 0 ? theme.colorScheme.error : null,
                      ),
                    ),
                    if (!draft)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Tooltip(
                          message: s.viewedAt == null
                              ? tr('아직 안 봄')
                              : tr('확인 {at}', {
                                  'at': formatDateTime(s.viewedAt!),
                                }),
                          child: Icon(
                            s.viewedAt == null
                                ? Icons.mark_email_unread_outlined
                                : Icons.done_all,
                            size: 18,
                            color: s.viewedAt == null
                                ? hint
                                : Colors.green.shade700,
                          ),
                        ),
                      ),
                    PopupMenuButton<String>(
                      onSelected: (v) => switch (v) {
                        'edit' => _editSlip(d, s),
                        'preview' => _preview(d, s),
                        'remove' => _removeSlip(d, s),
                        _ => null,
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'edit',
                          child: Text(draft ? tr('고치기') : tr('정정하기')),
                        ),
                        PopupMenuItem(
                          value: 'preview',
                          child: Text(tr('미리 보기')),
                        ),
                        if (draft)
                          PopupMenuItem(
                            value: 'remove',
                            child: Text(tr('대장에서 빼기')),
                          ),
                      ],
                    ),
                  ],
                ),
                onTap: () => _editSlip(d, s),
              ),
          ],
        ),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  final String label;
  final String value;
  const _Figure({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
      ),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
    ],
  );
}

/// 대장 머리 고치기 — 제목·지급일·안내.
class _RunHeaderDialog extends StatefulWidget {
  final PayrollRun run;
  const _RunHeaderDialog({required this.run});

  @override
  State<_RunHeaderDialog> createState() => _RunHeaderDialogState();
}

class _RunHeaderDialogState extends State<_RunHeaderDialog> {
  late final _title = TextEditingController(text: widget.run.title);
  late final _note = TextEditingController(text: widget.run.note);
  late String _payDate = widget.run.payDate;

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('대장 고치기')),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _title,
            maxLength: 60,
            decoration: InputDecoration(
              labelText: tr('제목'),
              border: const OutlineInputBorder(),
            ),
          ),
          ApprovalDateField(
            label: tr('지급일'),
            value: _payDate,
            onChanged: (v) => setState(() => _payDate = v),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            maxLength: 1000,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: tr('모두에게 보일 안내'),
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr('취소')),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, (
          title: _title.text.trim(),
          payDate: _payDate,
          note: _note.text.trim(),
        )),
        child: Text(tr('저장')),
      ),
    ],
  );
}

/// 대장에 더할 사람 고르기(여럿).
class _PickPeopleDialog extends StatefulWidget {
  final List<({String id, String name, String username})> people;
  const _PickPeopleDialog({required this.people});

  @override
  State<_PickPeopleDialog> createState() => _PickPeopleDialogState();
}

class _PickPeopleDialogState extends State<_PickPeopleDialog> {
  final _picked = <String>{};

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('사람 더하기')),
    content: SizedBox(
      width: 380,
      height: 420,
      child: ListView(
        children: [
          for (final p in widget.people)
            CheckboxListTile(
              value: _picked.contains(p.id),
              title: Text(p.name),
              subtitle: Text(p.username),
              onChanged: (v) => setState(
                () => v == true ? _picked.add(p.id) : _picked.remove(p.id),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr('취소')),
      ),
      FilledButton(
        onPressed: _picked.isEmpty
            ? null
            : () => Navigator.pop(context, _picked.toList()),
        child: Text(tr('{n}명 더하기', {'n': _picked.length})),
      ),
    ],
  );
}

/// 급여대장 가져오기 미리 보기 — 고칠·더할 사람 수, 못 찾은 줄, 오류, 읽은 항목. 오류가 있으면 "닫기"만.
class _PayrollImportPreview extends StatelessWidget {
  final PayrollImportResult result;
  final String fileName;
  const _PayrollImportPreview({required this.result, required this.fileName});

  @override
  Widget build(BuildContext context) {
    final r = result;
    final theme = Theme.of(context);
    final hasErrors = r.errors.isNotEmpty;
    return AlertDialog(
      title: Text(tr('급여대장 가져오기')),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(fileName, style: TextStyle(color: theme.hintColor)),
              const SizedBox(height: 8),
              Text(
                tr('고칠 명세서 {u}명 · 새로 더할 사람 {a}명', {
                  'u': r.updated,
                  'a': r.added,
                }),
                key: const ValueKey('payroll-import-summary'),
              ),
              if (r.earningColumns.isNotEmpty)
                Text(
                  tr('지급 항목: {list}', {'list': r.earningColumns.join(', ')}),
                  style: const TextStyle(fontSize: 12),
                ),
              if (r.deductionColumns.isNotEmpty)
                Text(
                  tr('공제 항목: {list}', {'list': r.deductionColumns.join(', ')}),
                  style: const TextStyle(fontSize: 12),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  tr('파일에 값이 있는 항목만 바꾸고, 빈 칸과 파일에 없는 항목은 그대로 둡니다.'),
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
              ),
              if (r.unmatched.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  tr('찾지 못한 사람 {n}줄(건너뜀): {list}', {
                    'n': r.unmatched.length,
                    'list': [
                      for (final u in r.unmatched.take(20))
                        tr('{row}번째 줄 {label}', {
                          'row': u.row,
                          'label': u.label,
                        }),
                    ].join(', '),
                  }),
                  style: TextStyle(color: Colors.orange.shade800, fontSize: 13),
                ),
              ],
              if (hasErrors) ...[
                const SizedBox(height: 10),
                Text(
                  tr('오류가 있어 가져올 수 없습니다:'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                for (final e in r.errors.take(30))
                  Text(
                    e.row > 0
                        ? tr('{row}번째 줄: {message}', {
                            'row': e.row,
                            'message': trServer(e.message),
                          })
                        : trServer(e.message),
                    style: const TextStyle(fontSize: 12),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(hasErrors ? tr('닫기') : tr('취소')),
        ),
        if (!hasErrors)
          FilledButton(
            key: const ValueKey('payroll-import-apply'),
            onPressed: r.updated + r.added == 0
                ? null
                : () => Navigator.pop(context, true),
            child: Text(tr('가져오기')),
          ),
      ],
    );
  }
}

// ── 명세서 고치기 ──

/// 편집 중인 항목 한 줄.
class _ItemRow {
  final TextEditingController name;
  final TextEditingController amount;
  final TextEditingController basis;
  bool taxFree;
  _ItemRow(PayrollItem i)
    : name = TextEditingController(text: i.name),
      amount = TextEditingController(text: wonInputText(i.amount)),
      basis = TextEditingController(text: i.basis),
      taxFree = i.taxFree;
  _ItemRow.empty()
    : name = TextEditingController(),
      amount = TextEditingController(),
      basis = TextEditingController(),
      taxFree = false;

  int get value => parseWonInput(amount.text) ?? 0;

  PayrollItem toItem() => PayrollItem(
    name: name.text.trim(),
    amount: value,
    basis: basis.text.trim().isEmpty ? null : basis.text.trim(),
    taxFree: taxFree,
  );

  void dispose() {
    name.dispose();
    amount.dispose();
    basis.dispose();
  }
}

/// 명세서 고치기 — 지급·공제 항목(이름·금액·계산 방법·비과세), 근무 내역, 사번, 메모. 보낸 대장이면 정정 사유가 꼭 있어야 하고, 저장하면
/// 받는 사람에게 "정정" 알림이 간다.
class PayslipEditorDialog extends StatefulWidget {
  final GroupwareApi api;
  final Payslip slip;
  final bool published;
  const PayslipEditorDialog({
    super.key,
    required this.api,
    required this.slip,
    required this.published,
  });

  @override
  State<PayslipEditorDialog> createState() => _PayslipEditorDialogState();
}

class _PayslipEditorDialogState extends State<PayslipEditorDialog> {
  late final List<_ItemRow> _earnings = [
    for (final i in widget.slip.earnings) _ItemRow(i),
  ];
  late final List<_ItemRow> _deductions = [
    for (final i in widget.slip.deductions) _ItemRow(i),
  ];
  late final _employeeNo = TextEditingController(text: widget.slip.employeeNo);
  late final _memo = TextEditingController(text: widget.slip.memo);
  final _reason = TextEditingController();
  late final _workDays = TextEditingController(
    text: widget.slip.work?.workDays?.toString(),
  );
  late final _workHours = TextEditingController(
    text: _hours(widget.slip.work?.workMinutes),
  );
  late final _overtime = TextEditingController(
    text: _hours(widget.slip.work?.overtimeMinutes),
  );
  late final _night = TextEditingController(
    text: _hours(widget.slip.work?.nightMinutes),
  );
  late final _holiday = TextEditingController(
    text: _hours(widget.slip.work?.holidayMinutes),
  );
  bool _saving = false;
  String? _error;

  static String? _hours(int? minutes) {
    if (minutes == null) return null;
    final h = minutes / 60;
    return h == h.roundToDouble() ? '${h.round()}' : h.toStringAsFixed(2);
  }

  static int? _minutesOf(TextEditingController c) {
    final v = double.tryParse(c.text.trim());
    return v == null || v < 0 ? null : (v * 60).round();
  }

  @override
  void dispose() {
    for (final r in [..._earnings, ..._deductions]) {
      r.dispose();
    }
    for (final c in [
      _employeeNo,
      _memo,
      _reason,
      _workDays,
      _workHours,
      _overtime,
      _night,
      _holiday,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  int get _gross => _earnings.fold(0, (s, r) => s + r.value);
  int get _deductionTotal => _deductions.fold(0, (s, r) => s + r.value);

  Future<void> _save() async {
    final names = <String>{};
    for (final r in [..._earnings, ..._deductions]) {
      final n = r.name.text.trim();
      if (n.isEmpty) continue;
      if (parseWonInput(r.amount.text) == null &&
          r.amount.text.trim().isNotEmpty) {
        setState(() => _error = tr("'{name}'의 금액을 숫자로 넣으세요.", {'name': n}));
        return;
      }
    }
    for (final r in _earnings) {
      if (r.name.text.trim().isNotEmpty &&
          !names.add('e:${r.name.text.trim()}')) {
        setState(() => _error = tr('같은 이름의 지급 항목이 두 번 있습니다.'));
        return;
      }
    }
    for (final r in _deductions) {
      if (r.name.text.trim().isNotEmpty &&
          !names.add('d:${r.name.text.trim()}')) {
        setState(() => _error = tr('같은 이름의 공제 항목이 두 번 있습니다.'));
        return;
      }
    }
    if (widget.published && _reason.text.trim().isEmpty) {
      setState(() => _error = tr('이미 보낸 명세서입니다. 정정 사유를 쓰세요.'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.api.savePayslip(
        widget.slip.id,
        earnings: [
          for (final r in _earnings)
            if (r.name.text.trim().isNotEmpty) r.toItem(),
        ],
        deductions: [
          for (final r in _deductions)
            if (r.name.text.trim().isNotEmpty)
              r.toItem().copyWith(taxFree: false),
        ],
        work: PayrollWork(
          workDays: int.tryParse(_workDays.text.trim()),
          workMinutes: _minutesOf(_workHours),
          overtimeMinutes: _minutesOf(_overtime),
          nightMinutes: _minutesOf(_night),
          holidayMinutes: _minutesOf(_holiday),
        ),
        memo: _memo.text.trim().isEmpty ? null : _memo.text.trim(),
        employeeNo: _employeeNo.text.trim(),
        reason: widget.published ? _reason.text.trim() : null,
      );
      if (mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  Widget _itemsSection(
    String title,
    List<_ItemRow> rows, {
    required bool earnings,
  }) {
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              TextButton.icon(
                key: ValueKey(
                  earnings ? 'slip-add-earning' : 'slip-add-deduction',
                ),
                onPressed: () => setState(() => rows.add(_ItemRow.empty())),
                icon: const Icon(Icons.add, size: 16),
                label: Text(tr('항목 더하기')),
              ),
            ],
          ),
        ),
        for (final (i, r) in rows.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        key: ValueKey('slip-${earnings ? 'e' : 'd'}-name-$i'),
                        controller: r.name,
                        maxLength: 30,
                        decoration: InputDecoration(
                          labelText: tr('항목'),
                          isDense: true,
                          counterText: '',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      flex: 3,
                      child: TextField(
                        key: ValueKey('slip-${earnings ? 'e' : 'd'}-amount-$i'),
                        controller: r.amount,
                        keyboardType: const TextInputType.numberWithOptions(
                          signed: true,
                        ),
                        textAlign: TextAlign.right,
                        decoration: InputDecoration(
                          labelText: tr('금액(원)'),
                          isDense: true,
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    if (earnings)
                      Tooltip(
                        message: tr('비과세(4대보험·소득세 계산에서 뺌 — 예: 식대 월 20만 원까지)'),
                        child: Checkbox(
                          value: r.taxFree,
                          onChanged: (v) =>
                              setState(() => r.taxFree = v == true),
                        ),
                      ),
                    IconButton(
                      tooltip: tr('빼기'),
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(() {
                        rows.removeAt(i).dispose();
                      }),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: r.basis,
                  maxLength: 100,
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    hintText: tr('계산 방법(선택 — 예: 10시간 × 12,000원 × 1.5)'),
                    hintStyle: TextStyle(fontSize: 12, color: hint),
                    isDense: true,
                    counterText: '',
                    border: InputBorder.none,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget small(TextEditingController c, String label, {String? key}) =>
        SizedBox(
          width: 110,
          child: TextField(
            key: key == null ? null : ValueKey(key),
            controller: c,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: label,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        );
    return AlertDialog(
      title: Text(
        widget.published
            ? tr('{name}님 명세서 정정', {'name': widget.slip.userName})
            : tr('{name}님 명세서', {'name': widget.slip.userName}),
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.published)
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    tr(
                      '이미 보낸 명세서입니다. 저장하면 지금 내용이 정정 기록에 남고 받는 사람에게 "정정" 알림이 갑니다.',
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              TextField(
                controller: _employeeNo,
                maxLength: 30,
                decoration: InputDecoration(
                  labelText: tr('사번'),
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
              _itemsSection(tr('지급 항목'), _earnings, earnings: true),
              _itemsSection(tr('공제 항목'), _deductions, earnings: false),
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 6),
                child: Text(tr('근무 내역'), style: theme.textTheme.titleSmall),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  small(_workDays, tr('출근일수')),
                  small(_workHours, tr('근로(시간)')),
                  small(_overtime, tr('연장(시간)')),
                  small(_night, tr('야간(시간)')),
                  small(_holiday, tr('휴일(시간)')),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _memo,
                maxLength: 1000,
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: tr('받는 사람에게 보일 메모'),
                  border: const OutlineInputBorder(),
                ),
              ),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  tr('지급 {g} − 공제 {d} = 실수령 {n}', {
                    'g': signedWonText(_gross),
                    'd': signedWonText(_deductionTotal),
                    'n': signedWonText(_gross - _deductionTotal),
                  }),
                  key: const ValueKey('slip-editor-total'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (widget.published) ...[
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('slip-editor-reason'),
                  controller: _reason,
                  maxLength: 200,
                  decoration: InputDecoration(
                    labelText: tr('정정 사유(꼭)'),
                    border: const OutlineInputBorder(),
                  ),
                ),
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
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('slip-editor-save'),
          onPressed: _saving ? null : _save,
          child: Text(widget.published ? tr('정정해서 보내기') : tr('저장')),
        ),
      ],
    );
  }
}

// ── 급여 설정 ──

/// 급여 설정 창을 연다 — 처음 받기에 실패하면 알림만.
Future<void> showPayrollSettingsDialog(
  BuildContext context, {
  required GroupwareApi api,
}) async {
  PayrollSettings settings;
  try {
    settings = await api.payrollSettings();
  } catch (e) {
    if (context.mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _PayrollSettingsDialog(api: api, settings: settings),
  );
}

class _PayrollSettingsDialog extends StatefulWidget {
  final GroupwareApi api;
  final PayrollSettings settings;
  const _PayrollSettingsDialog({required this.api, required this.settings});

  @override
  State<_PayrollSettingsDialog> createState() => _PayrollSettingsDialogState();
}

class _PayrollSettingsDialogState extends State<_PayrollSettingsDialog> {
  late final _company = TextEditingController(
    text: widget.settings.companyName,
  );
  late final Set<String> _staff = {...widget.settings.staffIds};
  late final List<_ItemRow> _earnings = [
    for (final i in widget.settings.templateEarnings) _ItemRow(i),
  ];
  late final List<_ItemRow> _deductions = [
    for (final i in widget.settings.templateDeductions) _ItemRow(i),
  ];
  late final Map<String, TextEditingController> _rates = {
    for (final key in const [
      'pension',
      'health',
      'longTermCare',
      'employment',
      'localTax',
      'pensionMin',
      'pensionMax',
    ])
      key: TextEditingController(
        text: widget.settings.insurance[key]?.toString(),
      ),
  };
  late final Map<String, TextEditingController> _employeeNos = {
    for (final p in widget.settings.people)
      p.id: TextEditingController(text: widget.settings.employeeNos[p.id]),
  };
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _company.dispose();
    for (final r in [..._earnings, ..._deductions]) {
      r.dispose();
    }
    for (final c in [..._rates.values, ..._employeeNos.values]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.savePayrollSettings(
        staffIds: widget.settings.canEditStaff ? _staff.toList() : null,
        companyName: _company.text.trim(),
        templateEarnings: [
          for (final r in _earnings)
            if (r.name.text.trim().isNotEmpty)
              PayrollItem(
                name: r.name.text.trim(),
                amount: 0,
                taxFree: r.taxFree,
              ),
        ],
        templateDeductions: [
          for (final r in _deductions)
            if (r.name.text.trim().isNotEmpty)
              PayrollItem(name: r.name.text.trim(), amount: 0),
        ],
        insurance: {
          for (final e in _rates.entries)
            if (e.value.text.trim().isNotEmpty)
              e.key: num.tryParse(e.value.text.replaceAll(',', '').trim()),
        },
        employeeNos: {
          for (final e in _employeeNos.entries) e.key: e.value.text.trim(),
        },
      );
      if (mounted) {
        Navigator.pop(context);
        showAppToast(context, tr('급여 설정을 저장했습니다.'));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  Widget _names(String title, List<_ItemRow> rows, {required bool earnings}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(title)),
              IconButton(
                tooltip: tr('항목 더하기'),
                icon: const Icon(Icons.add, size: 18),
                onPressed: () => setState(() => rows.add(_ItemRow.empty())),
              ),
            ],
          ),
          for (final (i, r) in rows.indexed)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: r.name,
                    maxLength: 30,
                    decoration: const InputDecoration(
                      isDense: true,
                      counterText: '',
                    ),
                  ),
                ),
                if (earnings)
                  Tooltip(
                    message: tr('비과세'),
                    child: Checkbox(
                      value: r.taxFree,
                      onChanged: (v) => setState(() => r.taxFree = v == true),
                    ),
                  ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () => setState(() => rows.removeAt(i).dispose()),
                ),
              ],
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    Widget rate(String key, String label, {String suffix = '%'}) => SizedBox(
      width: 150,
      child: TextField(
        controller: _rates[key],
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          suffixText: suffix,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
    return AlertDialog(
      title: Text(tr('급여 설정')),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('payroll-company'),
                controller: _company,
                maxLength: 60,
                decoration: InputDecoration(
                  labelText: tr('명세서에 적을 회사 이름(비우면 팀 이름)'),
                  border: const OutlineInputBorder(),
                ),
              ),
              Text(tr('급여 담당자'), style: theme.textTheme.titleSmall),
              Text(
                widget.settings.canEditStaff
                    ? tr('그룹웨어 관리자 말고도 급여 대장을 다룰 사람입니다(모든 명세서를 봅니다).')
                    : tr('급여 담당자는 그룹웨어 관리자만 정할 수 있습니다.'),
                style: TextStyle(fontSize: 12, color: hint),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final p in widget.settings.people)
                    if (widget.settings.canEditStaff || _staff.contains(p.id))
                      FilterChip(
                        label: Text(p.name),
                        selected: _staff.contains(p.id),
                        onSelected: widget.settings.canEditStaff
                            ? (v) => setState(
                                () =>
                                    v ? _staff.add(p.id) : _staff.remove(p.id),
                              )
                            : null,
                      ),
                ],
              ),
              const Divider(height: 24),
              Text(tr('새 명세서의 항목 틀'), style: theme.textTheme.titleSmall),
              Text(
                tr('새 대장을 "항목 틀로" 만들 때의 항목입니다(체크는 비과세).'),
                style: TextStyle(fontSize: 12, color: hint),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _names(tr('지급'), _earnings, earnings: true)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _names(tr('공제'), _deductions, earnings: false),
                  ),
                ],
              ),
              const Divider(height: 24),
              Text(
                tr('4대보험 근로자 부담 요율(공제 계산 — 참고용)'),
                style: theme.textTheme.titleSmall,
              ),
              Text(
                tr(
                  '기본은 2026년 요율입니다(국민연금 4.75%, 건강보험 3.595%, 장기요양 = 건강보험료 × 13.14%, 고용보험 0.9%). 요율과 국민연금 기준소득월액 상·하한은 해마다 바뀌니 고시를 확인해 고치세요.',
                ),
                style: TextStyle(fontSize: 12, color: hint),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  rate('pension', tr('국민연금')),
                  rate('health', tr('건강보험')),
                  rate('longTermCare', tr('장기요양(건강보험료의)')),
                  rate('employment', tr('고용보험')),
                  rate('localTax', tr('지방소득세(소득세의)')),
                  rate('pensionMin', tr('국민연금 하한'), suffix: tr('원')),
                  rate('pensionMax', tr('국민연금 상한'), suffix: tr('원')),
                ],
              ),
              const Divider(height: 24),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(tr('사번'), style: theme.textTheme.titleSmall),
                subtitle: Text(
                  tr('명세서에 사람을 특정하는 값으로 적힙니다. 새로 만드는 명세서부터 들어갑니다.'),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
                children: [
                  for (final p in widget.settings.people)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          Expanded(child: Text('${p.name} (${p.username})')),
                          SizedBox(
                            width: 160,
                            child: TextField(
                              controller: _employeeNos[p.id],
                              maxLength: 30,
                              decoration: const InputDecoration(
                                isDense: true,
                                counterText: '',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
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
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('payroll-settings-save'),
          onPressed: _saving ? null : _save,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}
