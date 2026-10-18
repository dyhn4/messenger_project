import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../models/groupware.dart';
import '../../services/download_storage.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../services/time_format.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/attachment_widgets.dart' show fetchAttachmentBytes;
import '../../widgets/retrying_network_image.dart';
import '../../l10n/tr.dart';

/// 결재 문서의 결재란(칸마다 역할·서명/도장·이름·날짜)과 인쇄·PDF.

// ── 결재란(화면) ──────────────────────────────────────────────────────────

/// 칸 하나의 도장 글자 — 서명 그림이 없을 때 승인·반려·생략·반대(합의 반대 의견)를 도장처럼 보인다. 후결 칸은 확인했으면 "확인".
String? stampTextOf(ApprovalStep s) => switch (s.status) {
  ApprovalStepStatus.approved => switch (s.role) {
    LineRole.finalApprove => tr('전결'),
    LineRole.agree => tr('합의'),
    LineRole.post => tr('확인'),
    LineRole.approve => tr('승인'),
  },
  ApprovalStepStatus.rejected => tr('반려'),
  ApprovalStepStatus.skipped => tr('생략'),
  ApprovalStepStatus.disagreed => tr('반대'),
  _ => null,
};

/// 결재란에 놓을 칸 순서 — 결재선 순서 그대로, 다만 후결 칸은 맨 뒤(서버도 맨 뒤에만 두지만 예전 문서·순서가 섞여도).
List<ApprovalStep> stampOrderOf(ApprovalDocument doc) => [
  ...doc.steps.where((s) => s.role != LineRole.post),
  ...doc.steps.where((s) => s.role == LineRole.post),
];

/// 반대 의견 도장 색(주황 — 반려의 빨강과 구분).
const _disagreedColor = Color(0xFFE65100);

/// 전자서명 검증 결과 한 칸의 글(상세의 검증 창과 인쇄가 같이 쓴다).
String sealResultText(String result) => switch (result) {
  'valid' => tr('맞음'),
  'invalid' => tr('내용 또는 결정 기록이 바뀜'),
  'signatureChanged' => tr('서명 그림 파일이 바뀜'),
  'signatureMissing' => tr('서명 그림 파일이 없음'),
  'unsealed' => tr('서명 없음(이전 결재)'),
  _ => result,
};

/// 전자서명 검증 전체 결과 한 줄 — 바뀐 칸이 있으면 "바뀐 곳이 있습니다", 서명한 칸이 하나도 없으면 "검증할 전자서명이 없음",
/// 모두 맞으면 "위변조 없음".
String sealSummaryText(ApprovalVerification v) {
  if (v.tampered) return tr('바뀐 곳이 있습니다');
  if (v.steps.every((s) => s.result == 'unsealed')) {
    return tr('검증할 전자서명이 없습니다(이 기능 전에 결정한 결재).');
  }
  return tr('위변조 없음 — 모든 결재가 서명한 그대로입니다.');
}

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
        for (final s in stampOrderOf(doc))
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
                                ? (s.role == LineRole.post
                                      ? tr('확인 차례')
                                      : tr('결재 차례'))
                                : '',
                            style: TextStyle(fontSize: 11, color: hint),
                          )
                        : _Stamp(
                            text: stampTextOf(s)!,
                            faded: s.status == ApprovalStepStatus.skipped,
                            color: s.status == ApprovalStepStatus.disagreed
                                ? _disagreedColor
                                : null,
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

  /// 도장 색(없으면 빨강 — 반대 의견은 주황).
  final Color? color;
  const _Stamp({required this.text, this.faded = false, this.color});

  @override
  Widget build(BuildContext context) {
    final color = faded
        ? Theme.of(context).hintColor
        : this.color ?? Colors.red.shade700;
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

/// 표 칸 합계 줄의 칸 글들 — 숫자·금액 열은 합계, 그 밖의 첫 열에는 "합계"(모든 열이 숫자면 첫 칸 앞에 붙인다). 합계 낼 열이
/// 없으면 null. 화면(상세 — approval_form_widgets.dart FormTableValueView)과 인쇄가 같이 쓴다.
List<String>? formTableTotalsRow(FormFieldDef field, List totals) {
  final out = [
    for (final (j, c) in field.columns.indexed)
      (c.type == FormTableColumnType.number ||
                  c.type == FormTableColumnType.money) &&
              totals.elementAtOrNull(j) != null
          ? formTableCellText(c, totals[j])
          : '',
  ];
  if (out.every((t) => t.isEmpty)) return null;
  final labelAt = out.indexWhere((t) => t.isEmpty);
  if (labelAt >= 0) {
    out[labelAt] = tr('합계');
  } else {
    out[0] = tr('합계 {p0}', {'p0': out[0]});
  }
  return out;
}

/// 인쇄할 표 칸 하나 — 칸 이름, 열 머리, 줄마다 칸 글([formTableCellText]), 합계 줄([formTableTotalsRow] — 없으면 null), 숫자·금액
/// 열(오른쪽 맞춤할 열 번호).
typedef ApprovalPrintTable = ({
  String label,
  List<String> headers,
  List<List<String>> rows,
  List<String>? totals,
  Set<int> numericColumns,
});

/// 문서 내용을 (이름, 값) 줄로 — 종류별 칸과 양식 칸(사람 칸은 이름들). 여러 줄 글은 따로([longTexts]), 품목 표는 [items],
/// 표 칸은 [tables].
({
  List<(String, String)> rows,
  List<(String, String)> longTexts,
  List<Map<String, dynamic>> items,
  int? itemsTotal,
  List<ApprovalPrintTable> tables,
})
approvalContentOf(ApprovalDocument doc, GroupwareContext ctx) {
  final rows = <(String, String)>[];
  final longTexts = <(String, String)>[];
  var items = <Map<String, dynamic>>[];
  int? itemsTotal;
  final tables = <ApprovalPrintTable>[];
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
        } else if (f.type == FormFieldType.table && v is Map) {
          tables.add((
            label: f.label,
            headers: [for (final c in f.columns) c.label],
            rows: [
              for (final r in v['rows'] as List? ?? const [])
                if (r is List)
                  [
                    for (final (j, c) in f.columns.indexed)
                      formTableCellText(c, r.elementAtOrNull(j)),
                  ],
            ],
            totals: formTableTotalsRow(f, v['totals'] as List? ?? const []),
            numericColumns: {
              for (final (j, c) in f.columns.indexed)
                if (c.type == FormTableColumnType.number ||
                    c.type == FormTableColumnType.money)
                  j,
            },
          ));
        } else {
          // 한 줄 값(사람 칸은 이름들) — 비었으면 '—'.
          final text = formValueText(f, v);
          rows.add((f.label, text == null || text.isEmpty ? '—' : text));
        }
      }
  }
  if (doc.body != null) longTexts.add((tr('내용'), doc.body!));
  return (
    rows: rows,
    longTexts: longTexts,
    items: items,
    itemsTotal: itemsTotal,
    tables: tables,
  );
}

// ── PDF ──────────────────────────────────────────────────────────────────

pw.Font? _font;
Future<pw.Font> _koreanFont() async => _font ??= pw.Font.ttf(
  await rootBundle.load('assets/fonts/NanumBarunGothic-YetHangul.ttf'),
);

/// 결재 문서 PDF(A4) — 머리(문서 번호·종류·올린 사람·날짜·상태), 결재란, 내용, 결재 이력, 첨부 이름, 그리고 [verification]을 주면
/// 맨 끝에 "전자서명"(문서 지문·서버 키 지문·칸마다 검증 결과 — 인쇄한 종이를 나중에 맞춰 볼 수 있게). [signatures]는 칸 id →
/// 서명 그림.
Future<Uint8List> buildApprovalPdf(
  ApprovalDocument doc,
  GroupwareContext ctx, {
  Map<String, Uint8List> signatures = const {},
  ApprovalVerification? verification,
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
    final c = switch (s.status) {
      ApprovalStepStatus.skipped => grey,
      ApprovalStepStatus.disagreed => PdfColor.fromInt(
        _disagreedColor.toARGB32(),
      ),
      _ => red,
    };
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
            for (final s in stampOrderOf(doc))
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
        // 표 칸 — 칸 이름 아래 열 머리·줄, 맨 아래 합계 줄(숫자·금액 열은 오른쪽 맞춤).
        for (final t in content.tables) ...[
          pw.SizedBox(height: 10),
          pw.Text(t.label, style: pw.TextStyle(fontSize: 9, color: grey)),
          pw.SizedBox(height: 3),
          pw.TableHelper.fromTextArray(
            headers: t.headers,
            data: [...t.rows, ?t.totals],
            headerStyle: pw.TextStyle(fontSize: 9, color: grey),
            cellStyle: const pw.TextStyle(fontSize: 9),
            border: pw.TableBorder.all(color: line, width: 0.6),
            cellAlignments: {
              for (final j in t.numericColumns) j: pw.Alignment.centerRight,
            },
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
        // 전자서명 — 문서 지문(SHA-256)과 서버 서명 키 지문, 칸마다 검증 결과(인쇄할 때 서버에 물어본 것).
        if (verification != null) ...[
          pw.SizedBox(height: 14),
          pw.Text(tr('전자서명'), style: pw.TextStyle(fontSize: 9, color: grey)),
          pw.SizedBox(height: 3),
          pw.Text(
            sealSummaryText(verification),
            style: pw.TextStyle(
              fontSize: 9,
              color: verification.tampered ? red : null,
            ),
          ),
          pw.Text(
            tr('문서 지문 {digest}', {'digest': verification.digest}),
            style: const pw.TextStyle(fontSize: 7),
          ),
          pw.Text(
            tr('서버 키 지문 {fingerprint}', {
              'fingerprint': verification.fingerprint,
            }),
            style: const pw.TextStyle(fontSize: 7),
          ),
          for (final s in verification.steps)
            pw.Text(
              '${s.approverName} · ${s.status.label} · ${sealResultText(s.result)}',
              style: pw.TextStyle(
                fontSize: 8,
                color: s.result == 'valid' || s.result == 'unsealed'
                    ? null
                    : red,
              ),
            ),
        ],
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

/// 인쇄 전에 전자서명 검증을 받아 둔다 — [api]가 없거나 못 받으면 null(전자서명 칸 없이 인쇄한다 — 인쇄를 막지 않는다).
Future<ApprovalVerification?> _verificationOf(
  ApprovalDocument doc,
  GroupwareApi? api,
) async {
  if (api == null) return null;
  try {
    return await api.verifyDocument(doc.id);
  } catch (_) {
    return null;
  }
}

/// 인쇄(미리보기 창 — 프린터 고르기·PDF로 저장). [api]를 주면 전자서명 검증 결과를 맨 끝에 같이 찍는다.
Future<void> printApproval(
  BuildContext context,
  ApprovalDocument doc,
  GroupwareContext ctx,
  Session session, {
  GroupwareApi? api,
}) async {
  try {
    final signatures = await _signatureBytes(doc, session);
    final verification = await _verificationOf(doc, api);
    await Printing.layoutPdf(
      name: _pdfFileName(doc),
      onLayout: (format) => buildApprovalPdf(
        doc,
        ctx,
        signatures: signatures,
        verification: verification,
        format: format,
      ),
    );
  } catch (e) {
    if (context.mounted) showAppToast(context, tr('인쇄하지 못했습니다: {e}', {'e': e}));
  }
}

/// PDF를 다운로드 폴더에 저장한다. [api]를 주면 전자서명 검증 결과를 맨 끝에 같이 넣는다.
Future<void> saveApprovalPdf(
  BuildContext context,
  ApprovalDocument doc,
  GroupwareContext ctx,
  Session session, {
  GroupwareApi? api,
}) async {
  try {
    final bytes = await buildApprovalPdf(
      doc,
      ctx,
      signatures: await _signatureBytes(doc, session),
      verification: await _verificationOf(doc, api),
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
