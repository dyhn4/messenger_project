import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../models/groupware.dart';
import '../../services/download_storage.dart';
import '../../services/session.dart';
import '../../services/time_format.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/attachment_widgets.dart' show fetchAttachmentBytes;
import '../../widgets/retrying_network_image.dart';
import '../../l10n/tr.dart';

/// 결재 문서의 결재란(칸마다 역할·서명/도장·이름·날짜)과 인쇄·PDF.

// ── 결재란(화면) ──────────────────────────────────────────────────────────

/// 칸 하나의 도장 글자 — 서명 그림이 없을 때 승인·반려·생략을 도장처럼 보인다.
String? stampTextOf(ApprovalStep s) => switch (s.status) {
  ApprovalStepStatus.approved =>
    s.role == LineRole.finalApprove
        ? tr('전결')
        : (s.role == LineRole.agree ? tr('합의') : tr('승인')),
  ApprovalStepStatus.rejected => tr('반려'),
  ApprovalStepStatus.skipped => tr('생략'),
  _ => null,
};

/// 결재란 — 결재선 칸들을 가로로(좁으면 줄바꿈). 위에 역할(합의는 같은 단계끼리 같은 번호), 가운데 서명·도장, 아래 이름·날짜·대결.
class ApprovalStampBox extends StatelessWidget {
  final ApprovalDocument doc;
  final String Function(String relative) resolveUrl;
  const ApprovalStampBox({
    super.key,
    required this.doc,
    required this.resolveUrl,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final border = BorderSide(color: theme.dividerColor);
    return Wrap(
      spacing: 0,
      runSpacing: 6,
      children: [
        for (final s in doc.steps)
          Container(
            key: ValueKey('approval-stamp-${s.order}'),
            width: 86,
            decoration: BoxDecoration(
              border: Border.fromBorderSide(border),
              color: s.status == ApprovalStepStatus.pending
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                  : null,
            ),
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Text(
                    '${s.role.label} ${s.stage + 1}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      color: s.role == LineRole.approve
                          ? hint
                          : theme.colorScheme.primary,
                    ),
                  ),
                ),
                SizedBox(
                  height: 48,
                  child: Center(
                    child: s.signatureUrl != null
                        ? RetryingNetworkImage(
                            imageUrl: resolveUrl(s.signatureUrl!),
                            height: 42,
                            fit: BoxFit.contain,
                          )
                        : stampTextOf(s) == null
                        ? Text(
                            s.status == ApprovalStepStatus.pending
                                ? tr('결재 차례')
                                : '',
                            style: TextStyle(fontSize: 11, color: hint),
                          )
                        : _Stamp(
                            text: stampTextOf(s)!,
                            faded: s.status == ApprovalStepStatus.skipped,
                          ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(2, 0, 2, 3),
                  child: Column(
                    children: [
                      Text(
                        s.approverName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      if (s.actedByName != null)
                        Text(
                          tr('대결 {s.actedByName}', {
                            's.actedByName': s.actedByName,
                          }),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      Text(
                        s.decidedAt == null
                            ? ' '
                            : '${s.decidedAt!.month}/${s.decidedAt!.day}',
                        style: TextStyle(fontSize: 10, color: hint),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Stamp extends StatelessWidget {
  final String text;
  final bool faded;
  const _Stamp({required this.text, this.faded = false});

  @override
  Widget build(BuildContext context) {
    final color = faded ? Theme.of(context).hintColor : Colors.red.shade700;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 2),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

// ── 내용 줄(PDF) ──────────────────────────────────────────────────────────

/// 문서 내용을 (이름, 값) 줄로 — 종류별 칸과 양식 칸. 여러 줄 글은 따로([longTexts]), 품목 표는 [items].
({
  List<(String, String)> rows,
  List<(String, String)> longTexts,
  List<Map<String, dynamic>> items,
  int? itemsTotal,
})
approvalContentOf(ApprovalDocument doc, GroupwareContext ctx) {
  final rows = <(String, String)>[];
  final longTexts = <(String, String)>[];
  var items = <Map<String, dynamic>>[];
  int? itemsTotal;
  final p = doc.payload;
  switch (doc.kind) {
    case ApprovalKind.leave:
      rows.add((
        tr('종류'),
        p['leaveLabel'] as String? ??
            ctx.leaveType(p['leaveType'] as String?)?.label ??
            tr('휴가'),
      ));
      rows.add((
        tr('기간'),
        p['startDate'] == p['endDate']
            ? '${p['startDate']}'
            : '${p['startDate']} ~ ${p['endDate']}',
      ));
      rows.add((tr('일수'), halfDaysText((p['halfDays'] as num?)?.toInt() ?? 0)));
    case ApprovalKind.expense:
      rows.add((tr('금액'), wonText((p['amount'] as num?)?.toInt() ?? 0)));
      rows.add((tr('분류'), '${p['category'] ?? ''}'));
      rows.add((tr('쓴 날'), '${p['spentOn'] ?? ''}'));
    case ApprovalKind.attendance:
      rows.add((tr('날짜'), '${p['workDate'] ?? ''}'));
      rows.add((tr('출근'), '${p['clockIn'] ?? ''}'));
      rows.add((
        tr('퇴근'),
        p['clockOut'] == null ? tr('(그대로)') : '${p['clockOut']}',
      ));
    default:
      final values = doc.formValues;
      for (final f in doc.formFields) {
        final v = values[f.key];
        if (f.type == FormFieldType.textarea) {
          if (v != null) longTexts.add((f.label, '$v'));
        } else if (f.type == FormFieldType.items && v is Map) {
          items = [
            for (final r in v['rows'] as List? ?? const [])
              (r as Map).cast<String, dynamic>(),
          ];
          itemsTotal = (v['total'] as num?)?.toInt();
        } else {
          rows.add((f.label, formValueText(f, v) ?? '—'));
        }
      }
  }
  if (doc.body != null) longTexts.add((tr('내용'), doc.body!));
  return (
    rows: rows,
    longTexts: longTexts,
    items: items,
    itemsTotal: itemsTotal,
  );
}

// ── PDF ──────────────────────────────────────────────────────────────────

pw.Font? _font;
Future<pw.Font> _koreanFont() async => _font ??= pw.Font.ttf(
  await rootBundle.load('assets/fonts/NanumBarunGothic-YetHangul.ttf'),
);

/// 결재 문서 PDF(A4) — 머리(문서 번호·종류·올린 사람·날짜·상태), 결재란, 내용, 결재 이력, 첨부 이름. [signatures]는 칸 id → 서명 그림.
Future<Uint8List> buildApprovalPdf(
  ApprovalDocument doc,
  GroupwareContext ctx, {
  Map<String, Uint8List> signatures = const {},
  PdfPageFormat format = PdfPageFormat.a4,
  pw.Font? font,
}) async {
  final base = font ?? await _koreanFont();
  final theme = pw.ThemeData.withFont(base: base, bold: base);
  final content = approvalContentOf(doc, ctx);
  final red = PdfColor.fromInt(0xFFC62828);
  final grey = PdfColor.fromInt(0xFF757575);
  final line = PdfColor.fromInt(0xFFBDBDBD);
  pw.Widget cell(String text, {bool head = false}) => pw.Container(
    padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    color: head ? PdfColor.fromInt(0xFFF0F0F0) : null,
    child: pw.Text(
      text,
      style: pw.TextStyle(fontSize: 10, color: head ? grey : null),
    ),
  );
  pw.Widget stamp(ApprovalStep s) {
    final sig = signatures[s.id];
    if (sig != null) {
      return pw.Image(pw.MemoryImage(sig), height: 36, fit: pw.BoxFit.contain);
    }
    final text = stampTextOf(s);
    if (text == null) return pw.SizedBox(height: 36);
    final c = s.status == ApprovalStepStatus.skipped ? grey : red;
    return pw.Container(
      width: 36,
      height: 36,
      alignment: pw.Alignment.center,
      decoration: pw.BoxDecoration(
        shape: pw.BoxShape.circle,
        border: pw.Border.all(color: c, width: 1.5),
      ),
      child: pw.Text(text, style: pw.TextStyle(color: c, fontSize: 9)),
    );
  }

  final pdf = pw.Document(title: doc.title, author: doc.authorName);
  pdf.addPage(
    pw.MultiPage(
      pageFormat: format,
      theme: theme,
      margin: const pw.EdgeInsets.all(36),
      build: (_) => [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    doc.kindLabel,
                    style: pw.TextStyle(fontSize: 11, color: grey),
                  ),
                  pw.SizedBox(height: 2),
                  pw.Text(doc.title, style: const pw.TextStyle(fontSize: 18)),
                  pw.SizedBox(height: 6),
                  pw.Text(
                    [
                      if (doc.docNumber != null)
                        tr('문서 번호 {doc.docNumber}', {
                          'doc.docNumber': doc.docNumber,
                        }),
                      tr('기안 {doc.authorName}', {
                        'doc.authorName': doc.authorName,
                      }),
                      if (doc.createdAt != null) formatDateTime(doc.createdAt!),
                      tr('상태 {doc.status.label}', {
                        'doc.status.label': doc.status.label,
                      }),
                    ].join('   '),
                    style: pw.TextStyle(fontSize: 9, color: grey),
                  ),
                ],
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 12),
        // 결재란
        pw.Wrap(
          children: [
            for (final s in doc.steps)
              pw.Container(
                width: 74,
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: line, width: 0.6),
                ),
                child: pw.Column(
                  children: [
                    pw.Container(
                      width: double.infinity,
                      color: PdfColor.fromInt(0xFFF0F0F0),
                      padding: const pw.EdgeInsets.symmetric(vertical: 2),
                      child: pw.Text(
                        '${s.role.label} ${s.stage + 1}',
                        textAlign: pw.TextAlign.center,
                        style: const pw.TextStyle(fontSize: 8),
                      ),
                    ),
                    pw.SizedBox(height: 44, child: pw.Center(child: stamp(s))),
                    pw.Text(
                      s.approverName,
                      style: const pw.TextStyle(fontSize: 9),
                    ),
                    if (s.actedByName != null)
                      pw.Text(
                        tr('대결 {s.actedByName}', {
                          's.actedByName': s.actedByName,
                        }),
                        style: pw.TextStyle(fontSize: 7, color: red),
                      ),
                    pw.Text(
                      s.decidedAt == null
                          ? ' '
                          : '${s.decidedAt!.year}.${s.decidedAt!.month}.${s.decidedAt!.day}',
                      style: pw.TextStyle(fontSize: 7, color: grey),
                    ),
                    pw.SizedBox(height: 3),
                  ],
                ),
              ),
          ],
        ),
        if (doc.cc.isNotEmpty) ...[
          pw.SizedBox(height: 6),
          pw.Text(
            tr('참조  {p0}', {'p0': doc.cc.map((c) => c.name).join(', ')}),
            style: pw.TextStyle(fontSize: 9, color: grey),
          ),
        ],
        pw.SizedBox(height: 14),
        if (content.rows.isNotEmpty)
          pw.Table(
            border: pw.TableBorder.all(color: line, width: 0.6),
            columnWidths: const {
              0: pw.FixedColumnWidth(90),
              1: pw.FlexColumnWidth(),
            },
            children: [
              for (final (label, value) in content.rows)
                pw.TableRow(children: [cell(label, head: true), cell(value)]),
            ],
          ),
        if (content.items.isNotEmpty) ...[
          pw.SizedBox(height: 10),
          pw.TableHelper.fromTextArray(
            headers: [tr('품명'), tr('수량'), tr('단가'), tr('금액')],
            data: [
              for (final r in content.items)
                [
                  '${r['name']}',
                  '${r['qty']}',
                  wonText((r['unitPrice'] as num).toInt()),
                  wonText((r['amount'] as num).toInt()),
                ],
            ],
            headerStyle: pw.TextStyle(fontSize: 9, color: grey),
            cellStyle: const pw.TextStyle(fontSize: 9),
            border: pw.TableBorder.all(color: line, width: 0.6),
            cellAlignments: {
              1: pw.Alignment.centerRight,
              2: pw.Alignment.centerRight,
              3: pw.Alignment.centerRight,
            },
          ),
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Padding(
              padding: const pw.EdgeInsets.only(top: 4),
              child: pw.Text(
                tr('합계 {p0}', {'p0': wonText(content.itemsTotal ?? 0)}),
                style: const pw.TextStyle(fontSize: 10),
              ),
            ),
          ),
        ],
        for (final (label, text) in content.longTexts) ...[
          pw.SizedBox(height: 10),
          pw.Text(label, style: pw.TextStyle(fontSize: 9, color: grey)),
          pw.SizedBox(height: 3),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: line, width: 0.6),
            ),
            child: pw.Text(text, style: const pw.TextStyle(fontSize: 10)),
          ),
        ],
        if (doc.attachments.isNotEmpty) ...[
          pw.SizedBox(height: 10),
          pw.Text(
            tr('첨부  {p0}', {
              'p0': doc.attachments
                  .map((a) => a.fileName ?? tr('첨부'))
                  .join(', '),
            }),
            style: pw.TextStyle(fontSize: 9, color: grey),
          ),
        ],
        pw.SizedBox(height: 14),
        pw.Text(tr('결재 이력'), style: pw.TextStyle(fontSize: 9, color: grey)),
        pw.SizedBox(height: 3),
        for (final s in doc.steps)
          if (s.decidedAt != null || s.status == ApprovalStepStatus.skipped)
            pw.Text(
              [
                '${s.approverName}(${s.role.label})',
                s.status.label,
                if (s.actedByName != null)
                  tr('대결 {s.actedByName}', {'s.actedByName': s.actedByName}),
                if (s.decidedAt != null) formatDateTime(s.decidedAt!),
                if (s.comment != null) '"${s.comment}"',
              ].join(' · '),
              style: const pw.TextStyle(fontSize: 9),
            ),
        if (doc.status == ApprovalStatus.canceled)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 6),
            child: pw.Text(
              tr('{p0}님이 취소: {p1}', {
                'p0': doc.canceledByName ?? tr('관리자'),
                'p1': doc.cancelReason ?? '',
              }),
              style: pw.TextStyle(fontSize: 9, color: red),
            ),
          ),
      ],
      footer: (context) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(
          '${context.pageNumber}/${context.pagesCount}',
          style: pw.TextStyle(fontSize: 8, color: grey),
        ),
      ),
    ),
  );
  return pdf.save();
}

/// 서명 그림들을 받아 둔다(못 받은 것은 도장 글자로 대신).
Future<Map<String, Uint8List>> _signatureBytes(
  ApprovalDocument doc,
  Session session,
) async {
  final out = <String, Uint8List>{};
  for (final s in doc.steps) {
    final url = s.signatureUrl;
    if (url == null) continue;
    try {
      out[s.id] = await fetchAttachmentBytes(
        url: session.resolveUrl(url),
        session: session,
      );
    } catch (_) {
      // 그림을 못 받으면 도장 글자로.
    }
  }
  return out;
}

String _pdfFileName(ApprovalDocument doc) =>
    '${doc.docNumber ?? tr('결재')}_${doc.title}'.replaceAll(
      RegExp(r'[\\/:*?"<>|\n\r]'),
      '_',
    );

/// 인쇄(미리보기 창 — 프린터 고르기·PDF로 저장).
Future<void> printApproval(
  BuildContext context,
  ApprovalDocument doc,
  GroupwareContext ctx,
  Session session,
) async {
  try {
    final signatures = await _signatureBytes(doc, session);
    await Printing.layoutPdf(
      name: _pdfFileName(doc),
      onLayout: (format) =>
          buildApprovalPdf(doc, ctx, signatures: signatures, format: format),
    );
  } catch (e) {
    if (context.mounted) showAppToast(context, tr('인쇄하지 못했습니다: {e}', {'e': e}));
  }
}

/// PDF를 다운로드 폴더에 저장한다.
Future<void> saveApprovalPdf(
  BuildContext context,
  ApprovalDocument doc,
  GroupwareContext ctx,
  Session session,
) async {
  try {
    final bytes = await buildApprovalPdf(
      doc,
      ctx,
      signatures: await _signatureBytes(doc, session),
    );
    final path = await writeDownloadFile(
      folder: session.settings.downloadFolder,
      fileName: '${_pdfFileName(doc)}.pdf',
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
