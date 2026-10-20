import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../models/groupware_finance.dart';
import '../../services/api_client.dart' show ApiException;
import '../../services/download_storage.dart';
import '../../services/groupware_api.dart';
import '../../services/time_format.dart';
import '../../widgets/app_toast.dart';
import 'groupware_screen.dart';
import 'leave_notice_pdf.dart' show koreanPdfFont, pdfDownloadFolder;
import '../../l10n/tr.dart';

/// 명세서를 열기 전 비밀번호 다시 확인(급여 설정에서 켠 범위) — 맞으면 10분 동안 이 기기에서 다시 묻지 않는다(GroupwareApi가 기억).
/// 맞으면 true, 취소하면 false. 틀리면 창에 서버 문구를 보이고 다시 묻는다.
Future<bool> askPayrollPassword(
  BuildContext context, {
  required GroupwareApi api,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _PayrollPasswordDialog(api: api),
    ) ==
    true;

class _PayrollPasswordDialog extends StatefulWidget {
  final GroupwareApi api;
  const _PayrollPasswordDialog({required this.api});

  @override
  State<_PayrollPasswordDialog> createState() => _PayrollPasswordDialogState();
}

class _PayrollPasswordDialogState extends State<_PayrollPasswordDialog> {
  final _controller = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_controller.text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.unlockPayroll(_controller.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('비밀번호 확인')),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('급여명세서를 보려면 로그인 비밀번호를 다시 넣으세요(10분 동안 다시 묻지 않습니다).')),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('payroll-password'),
            controller: _controller,
            autofocus: true,
            obscureText: true,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: tr('비밀번호'),
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: Text(tr('취소')),
      ),
      FilledButton(
        key: const ValueKey('payroll-password-ok'),
        onPressed: _busy ? null : _submit,
        child: Text(tr('확인')),
      ),
    ],
  );
}

/// 급여명세서 한 장 — 받는 사람(그룹웨어 → 급여 → 내 명세서)과 급여 담당자(대장의 미리 보기)가 같이 본다. 근로기준법 제48조 제2항의 임금명세서
/// 칸(성명·사번 등, 지급일, 총액, 항목별 금액, 계산 방법과 연장·야간·휴일 시간, 공제 항목별 금액과 총액)을 그대로 보이고, 인쇄·PDF로 저장한다.
Future<void> openPayslipScreen(
  BuildContext context, {
  required GroupwareApi api,
  required String payslipId,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => PayslipScreen(api: api, payslipId: payslipId),
  ),
);

class PayslipScreen extends StatefulWidget {
  final GroupwareApi api;
  final String payslipId;
  const PayslipScreen({super.key, required this.api, required this.payslipId});

  @override
  State<PayslipScreen> createState() => _PayslipScreenState();
}

class _PayslipScreenState extends State<PayslipScreen> {
  Payslip? _slip;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final slip = await widget.api.payslip(widget.payslipId);
      if (mounted) setState(() => _slip = slip);
    } on ApiException catch (e) {
      // 비밀번호를 다시 확인해야 한다(급여 설정 — 423) — 묻고 다시 연다. 취소하면 닫는다.
      if (e.statusCode == 423 && mounted) {
        if (await askPayrollPassword(context, api: widget.api)) {
          return _load();
        }
        if (mounted) Navigator.pop(context);
        return;
      }
      if (mounted) setState(() => _error = e.toString());
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final slip = _slip;
    return Scaffold(
      appBar: AppBar(
        title: Text(slip?.run?.title ?? tr('급여명세서')),
        actions: [
          if (slip != null) ...[
            IconButton(
              key: const ValueKey('payslip-print'),
              tooltip: tr('인쇄'),
              icon: const Icon(Icons.print_outlined),
              onPressed: () => payslipPdf(context, slip: slip, print: true),
            ),
            IconButton(
              key: const ValueKey('payslip-pdf'),
              tooltip: tr('PDF로 저장'),
              icon: const Icon(Icons.picture_as_pdf_outlined),
              onPressed: () => payslipPdf(context, slip: slip),
            ),
          ],
        ],
      ),
      body: slip == null
          ? Center(
              child: _error != null
                  ? GroupwareEmpty(_error!)
                  : const CircularProgressIndicator(),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: PayslipView(slip: slip),
                  ),
                ),
              ],
            ),
    );
  }
}

/// 명세서 본문(화면) — 머리(회사·대장·지급일), 받는 사람, 지급·공제 표, 합계, 근무 내역, 메모·안내, 정정 기록.
class PayslipView extends StatelessWidget {
  final Payslip slip;
  const PayslipView({super.key, required this.slip});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final run = slip.run;
    Widget section(String title) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 6),
      child: Text(title, style: theme.textTheme.titleSmall),
    );
    Widget itemRow(PayrollItem i) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(i.taxFree ? tr('{name} (비과세)', {'name': i.name}) : i.name),
                if (i.basis != null)
                  Text(i.basis!, style: TextStyle(fontSize: 12, color: hint)),
              ],
            ),
          ),
          Text(signedWonText(i.amount)),
        ],
      ),
    );
    Widget totalRow(String label, int amount, {bool strong = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: strong
                  ? const TextStyle(fontWeight: FontWeight.w700)
                  : null,
            ),
          ),
          Text(
            signedWonText(amount),
            style: strong
                ? TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    color: theme.colorScheme.primary,
                  )
                : const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
    final work = slip.work;
    final identity = [
      slip.userName,
      if (slip.employeeNo != null) tr('사번 {no}', {'no': slip.employeeNo}),
      ?slip.department,
      ?slip.position,
    ].join(' · ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (slip.companyName != null)
              Text(slip.companyName!, style: TextStyle(color: hint)),
            Text(
              run?.title ?? tr('급여명세서'),
              key: const ValueKey('payslip-title'),
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              [
                if (run != null) tr('지급일 {date}', {'date': run.payDate}),
                identity,
              ].join('  ·  '),
              style: TextStyle(color: hint),
            ),
            if (slip.revision > 1)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  tr('정정 {n}차 — {at}', {
                    'n': slip.revision - 1,
                    'at': slip.correctedAt == null
                        ? ''
                        : formatDateTime(slip.correctedAt!),
                  }),
                  key: const ValueKey('payslip-corrected'),
                  style: TextStyle(color: Colors.orange.shade800),
                ),
              ),
            if (slip.unreadable)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  tr('명세서 내용을 읽지 못했습니다. 급여 담당자에게 문의하세요.'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const Divider(height: 24),
            section(tr('지급 항목')),
            if (slip.earnings.isEmpty)
              Text(tr('(없음)'), style: TextStyle(color: hint))
            else
              for (final i in slip.earnings) itemRow(i),
            const Divider(),
            totalRow(tr('지급 총액'), slip.gross),
            section(tr('공제 항목')),
            if (slip.deductions.isEmpty)
              Text(tr('(없음)'), style: TextStyle(color: hint))
            else
              for (final i in slip.deductions) itemRow(i),
            const Divider(),
            totalRow(tr('공제 총액'), slip.deductionTotal),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(
                  alpha: 0.35,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: totalRow(tr('실수령액'), slip.net, strong: true),
            ),
            if (work != null && !work.isEmpty) ...[
              section(tr('근무 내역')),
              Wrap(
                spacing: 16,
                runSpacing: 4,
                children: [
                  for (final t in payrollWorkTexts(work))
                    Text(t, style: const TextStyle(fontSize: 13)),
                ],
              ),
            ],
            if (slip.memo != null) ...[section(tr('메모')), Text(slip.memo!)],
            if (run?.note != null) ...[section(tr('안내')), Text(run!.note!)],
            if (slip.corrections.isNotEmpty) ...[
              section(tr('정정 기록')),
              for (final c in slip.corrections.reversed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text(
                    tr('{at} {by} — {reason} (정정 전 실수령액 {net})', {
                      'at': c.correctedAt == null
                          ? ''
                          : formatDateTime(c.correctedAt!),
                      'by': c.correctedByName ?? '',
                      'reason': c.reason ?? '',
                      'net': signedWonText(c.net),
                    }),
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 근무 내역 글들 — "출근 21일", "근로 168시간", "연장 10시간 30분"…(값이 있는 것만).
List<String> payrollWorkTexts(PayrollWork work) => [
  if (work.workDays != null) tr('출근 {n}일', {'n': work.workDays}),
  if (work.workMinutes != null)
    tr('근로 {h}', {'h': payrollHoursText(work.workMinutes!)}),
  if (work.overtimeMinutes != null)
    tr('연장 {h}', {'h': payrollHoursText(work.overtimeMinutes!)}),
  if (work.nightMinutes != null)
    tr('야간 {h}', {'h': payrollHoursText(work.nightMinutes!)}),
  if (work.holidayMinutes != null)
    tr('휴일 {h}', {'h': payrollHoursText(work.holidayMinutes!)}),
];

/// 명세서 PDF — [print]이면 인쇄(미리 보기), 아니면 다운로드 폴더에 저장(폴더를 모르면 공유 창).
Future<void> payslipPdf(
  BuildContext context, {
  required Payslip slip,
  bool print = false,
}) async {
  final name = '${tr('급여명세서')}_${slip.run?.payMonth ?? ''}_${slip.userName}'
      .replaceAll(RegExp(r'[\\/:*?"<>|\n\r]'), '_');
  if (print) {
    try {
      await Printing.layoutPdf(
        name: name,
        onLayout: (format) => buildPayslipPdf(slip: slip, format: format),
      );
    } catch (e) {
      if (context.mounted) {
        showAppToast(context, tr('인쇄하지 못했습니다: {e}', {'e': e}));
      }
    }
    return;
  }
  try {
    final bytes = await buildPayslipPdf(slip: slip);
    final folder = await pdfDownloadFolder();
    if (folder.isEmpty && !kIsWeb) {
      await Printing.sharePdf(bytes: bytes, filename: '$name.pdf');
      return;
    }
    final path = await writeDownloadFile(
      folder: folder,
      fileName: '$name.pdf',
      bytes: bytes,
    );
    if (context.mounted) {
      showAppToast(context, tr('PDF를 저장했습니다: {path}', {'path': path}));
    }
  } catch (e) {
    if (context.mounted) {
      showAppToast(context, tr('PDF를 저장하지 못했습니다: {e}', {'e': e}));
    }
  }
}

/// 명세서 PDF(A4) 바이트 — 화면 없이 만든다(시험에서 바로 부른다). [font]를 안 주면 앱에 든 한글 글꼴.
Future<Uint8List> buildPayslipPdf({
  required Payslip slip,
  PdfPageFormat format = PdfPageFormat.a4,
  pw.Font? font,
}) async {
  final base = font ?? await koreanPdfFont();
  final theme = pw.ThemeData.withFont(base: base, bold: base);
  final grey = PdfColor.fromInt(0xFF757575);
  final line = PdfColor.fromInt(0xFFBDBDBD);
  final head = PdfColor.fromInt(0xFFF0F0F0);
  final run = slip.run;

  pw.Widget cell(
    String text, {
    bool isHead = false,
    bool right = false,
    double size = 10,
  }) => pw.Container(
    padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
    color: isHead ? head : null,
    alignment: right ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
    child: pw.Text(
      text,
      style: pw.TextStyle(fontSize: size, color: isHead ? grey : null),
    ),
  );
  pw.Widget itemsTable(String title, List<PayrollItem> items, int total) =>
      pw.Table(
        border: pw.TableBorder.all(color: line, width: 0.6),
        columnWidths: const {
          0: pw.FlexColumnWidth(2.2),
          1: pw.FlexColumnWidth(1.4),
          2: pw.FlexColumnWidth(3),
        },
        children: [
          pw.TableRow(
            children: [
              cell(title, isHead: true),
              cell(tr('금액'), isHead: true, right: true),
              cell(tr('계산 방법'), isHead: true),
            ],
          ),
          for (final i in items)
            pw.TableRow(
              children: [
                cell(i.taxFree ? tr('{name} (비과세)', {'name': i.name}) : i.name),
                cell(signedWonText(i.amount), right: true),
                cell(i.basis ?? '', size: 8.5),
              ],
            ),
          pw.TableRow(
            children: [
              cell(tr('합계'), isHead: true),
              cell(signedWonText(total), isHead: true, right: true),
              cell('', isHead: true),
            ],
          ),
        ],
      );

  final pdf = pw.Document(title: run?.title ?? tr('급여명세서'));
  pdf.addPage(
    pw.MultiPage(
      pageFormat: format,
      theme: theme,
      margin: const pw.EdgeInsets.fromLTRB(40, 40, 40, 36),
      build: (_) => [
        pw.Center(
          child: pw.Text(tr('급여명세서'), style: const pw.TextStyle(fontSize: 20)),
        ),
        pw.SizedBox(height: 4),
        pw.Center(
          child: pw.Text(
            [?slip.companyName, ?run?.title].join(' · '),
            style: pw.TextStyle(fontSize: 10, color: grey),
          ),
        ),
        pw.SizedBox(height: 16),
        pw.Table(
          border: pw.TableBorder.all(color: line, width: 0.6),
          columnWidths: const {
            0: pw.FixedColumnWidth(64),
            1: pw.FlexColumnWidth(),
            2: pw.FixedColumnWidth(64),
            3: pw.FlexColumnWidth(),
          },
          children: [
            pw.TableRow(
              children: [
                cell(tr('성명'), isHead: true),
                cell(slip.userName),
                cell(tr('사번'), isHead: true),
                cell(slip.employeeNo ?? ''),
              ],
            ),
            pw.TableRow(
              children: [
                cell(tr('부서'), isHead: true),
                cell(slip.department ?? ''),
                cell(tr('직책'), isHead: true),
                cell(slip.position ?? ''),
              ],
            ),
            pw.TableRow(
              children: [
                cell(tr('지급일'), isHead: true),
                cell(run?.payDate ?? ''),
                cell(tr('귀속 월'), isHead: true),
                cell(run?.payMonth ?? ''),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 12),
        itemsTable(tr('지급 항목'), slip.earnings, slip.gross),
        pw.SizedBox(height: 10),
        itemsTable(tr('공제 항목'), slip.deductions, slip.deductionTotal),
        pw.SizedBox(height: 10),
        pw.Table(
          border: pw.TableBorder.all(color: line, width: 0.6),
          children: [
            pw.TableRow(
              children: [
                cell(tr('지급 총액'), isHead: true),
                cell(tr('공제 총액'), isHead: true),
                cell(tr('실수령액'), isHead: true),
              ],
            ),
            pw.TableRow(
              children: [
                cell(signedWonText(slip.gross), right: true, size: 11),
                cell(signedWonText(slip.deductionTotal), right: true, size: 11),
                cell(signedWonText(slip.net), right: true, size: 13),
              ],
            ),
          ],
        ),
        if (slip.work != null && !slip.work!.isEmpty) ...[
          pw.SizedBox(height: 12),
          pw.Text(tr('근무 내역'), style: pw.TextStyle(fontSize: 10, color: grey)),
          pw.SizedBox(height: 3),
          pw.Text(
            payrollWorkTexts(slip.work!).join('   '),
            style: const pw.TextStyle(fontSize: 10),
          ),
        ],
        if (slip.memo != null) ...[
          pw.SizedBox(height: 12),
          pw.Text(tr('메모'), style: pw.TextStyle(fontSize: 10, color: grey)),
          pw.Text(slip.memo!, style: const pw.TextStyle(fontSize: 10)),
        ],
        if (run?.note != null) ...[
          pw.SizedBox(height: 12),
          pw.Text(tr('안내'), style: pw.TextStyle(fontSize: 10, color: grey)),
          pw.Text(run!.note!, style: const pw.TextStyle(fontSize: 10)),
        ],
        if (slip.revision > 1) ...[
          pw.SizedBox(height: 12),
          pw.Text(
            tr('정정 {n}차 — {at}', {
              'n': slip.revision - 1,
              'at': slip.correctedAt == null
                  ? ''
                  : formatDateTime(slip.correctedAt!),
            }),
            style: pw.TextStyle(fontSize: 9, color: grey),
          ),
          for (final c in slip.corrections.reversed)
            pw.Text(
              '· ${c.reason ?? ''} (${c.correctedByName ?? ''})',
              style: pw.TextStyle(fontSize: 8.5, color: grey),
            ),
        ],
      ],
      footer: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Divider(color: line, thickness: 0.6),
          pw.Text(
            tr('근로기준법 제48조 제2항에 따른 임금명세서입니다.'),
            style: pw.TextStyle(fontSize: 8, color: grey),
          ),
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text(
              '${context.pageNumber}/${context.pagesCount}',
              style: pw.TextStyle(fontSize: 8, color: grey),
            ),
          ),
        ],
      ),
    ),
  );
  return pdf.save();
}
