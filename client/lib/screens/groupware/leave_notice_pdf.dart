import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/groupware.dart';
import '../../models/groupware_work.dart';
import '../../services/app_platform.dart';
import '../../services/download_storage.dart';
import '../../services/time_format.dart';
import '../../widgets/app_toast.dart';
import '../../l10n/tr.dart';

/// 연차 사용 촉진 서면 통지서(근로기준법 제61조) — 1차 "연차 사용 촉진 통지서"(남은 연차·사용 시기를 정해 낼 기한), 2차 "연차 사용 시기 지정
/// 통지서"(회사가 정한 날)를 A4 PDF로 인쇄하거나 저장한다(approval_print.dart와 같은 한글 글꼴·방식). 관리자는 관리 탭의 촉진 현황에서,
/// 받은 사람은 휴가 탭의 받은 통지에서 쓴다.
///
/// [notice]는 그 통지, [employeeName]은 받는 사람, [scopeLabel]은 회사(범위) 이름, [print]이면 인쇄(미리보기), 아니면 PDF로 저장.
Future<void> leaveNoticePdf(
  BuildContext context, {
  required LeavePromotion notice,
  required String employeeName,
  required String scopeLabel,
  GroupwareContext? ctx,
  bool print = false,
}) async {
  final name = _noticeFileName(notice, employeeName);
  if (print) {
    try {
      await Printing.layoutPdf(
        name: name,
        onLayout: (format) => buildLeaveNoticePdf(
          notice: notice,
          employeeName: employeeName,
          scopeLabel: scopeLabel,
          format: format,
        ),
      );
    } catch (e) {
      if (context.mounted) {
        showAppToast(context, tr('인쇄하지 못했습니다: {e}', {'e': e}));
      }
    }
    return;
  }
  try {
    final bytes = await buildLeaveNoticePdf(
      notice: notice,
      employeeName: employeeName,
      scopeLabel: scopeLabel,
    );
    final folder = await pdfDownloadFolder();
    if (folder.isEmpty && !kIsWeb) {
      // 받을 폴더를 모르면(환경 변수가 없는 기기 등) 공유·저장 창으로 넘긴다 — 저장을 막지 않는다.
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

/// 통지서 제목 — 1차는 "연차 사용 촉진 통지서", 2차는 "연차 사용 시기 지정 통지서".
String leaveNoticeTitle(LeavePromotion notice) =>
    notice.stage == 2 ? tr('연차 사용 시기 지정 통지서') : tr('연차 사용 촉진 통지서');

/// 통지서 PDF(A4) 바이트 — 화면 없이 만든다(시험에서 바로 부른다). 머리(제목·회사), 받는 사람·소속·연차 기간·남은 연차 표, 본문(1차는
/// 사용 시기를 정해 낼 기한과 낸 계획, 2차는 회사가 지정한 날짜), 근거 조문, 덧붙인 말, 보낸 사람·보낸 날짜·확인한 날짜, 맨 아래 안내.
/// [font]를 안 주면 앱에 든 한글 글꼴(approval_print.dart와 같은 파일).
Future<Uint8List> buildLeaveNoticePdf({
  required LeavePromotion notice,
  required String employeeName,
  required String scopeLabel,
  PdfPageFormat format = PdfPageFormat.a4,
  pw.Font? font,
}) async {
  final base = font ?? await koreanPdfFont();
  final theme = pw.ThemeData.withFont(base: base, bold: base);
  final grey = PdfColor.fromInt(0xFF757575);
  final line = PdfColor.fromInt(0xFFBDBDBD);
  final title = leaveNoticeTitle(notice);
  final second = notice.stage == 2;

  pw.Widget cell(String text, {bool head = false}) => pw.Container(
    padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    color: head ? PdfColor.fromInt(0xFFF0F0F0) : null,
    child: pw.Text(
      text,
      style: pw.TextStyle(fontSize: 10.5, color: head ? grey : null),
    ),
  );
  pw.Widget label(String text) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 14, bottom: 4),
    child: pw.Text(text, style: pw.TextStyle(fontSize: 10, color: grey)),
  );
  pw.Widget paragraph(String text) => pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 4),
    child: pw.Text(
      text,
      style: const pw.TextStyle(fontSize: 11, lineSpacing: 3),
    ),
  );
  pw.Widget dateList(List<String> dates) => pw.Wrap(
    spacing: 6,
    runSpacing: 4,
    children: [
      for (final d in dates)
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: line, width: 0.6),
          ),
          child: pw.Text(
            _dateText(d),
            style: const pw.TextStyle(fontSize: 10.5),
          ),
        ),
    ],
  );

  final remaining = halfDaysText(notice.remainingHalfDays);
  final pdf = pw.Document(title: title, author: notice.sentByName);
  pdf.addPage(
    pw.MultiPage(
      pageFormat: format,
      theme: theme,
      margin: const pw.EdgeInsets.fromLTRB(48, 48, 48, 40),
      build: (_) => [
        pw.Center(
          child: pw.Text(title, style: const pw.TextStyle(fontSize: 20)),
        ),
        pw.SizedBox(height: 4),
        pw.Center(
          child: pw.Text(
            scopeLabel,
            style: pw.TextStyle(fontSize: 10, color: grey),
          ),
        ),
        pw.SizedBox(height: 20),
        pw.Table(
          border: pw.TableBorder.all(color: line, width: 0.6),
          columnWidths: const {
            0: pw.FixedColumnWidth(96),
            1: pw.FlexColumnWidth(),
          },
          children: [
            pw.TableRow(
              children: [cell(tr('받는 사람'), head: true), cell(employeeName)],
            ),
            pw.TableRow(
              children: [cell(tr('소속'), head: true), cell(scopeLabel)],
            ),
            pw.TableRow(
              children: [
                cell(tr('연차 기간'), head: true),
                cell(
                  '${_dateText(notice.periodStart)} ~ ${_dateText(notice.expiry)}',
                ),
              ],
            ),
            pw.TableRow(
              children: [cell(tr('남은 연차'), head: true), cell(remaining)],
            ),
          ],
        ),
        pw.SizedBox(height: 18),
        if (!second) ...[
          paragraph(
            tr('귀하의 연차 유급휴가 중 사용하지 않은 {remaining}이 {expiry}에 사용 기간이 끝납니다.', {
              'remaining': remaining,
              'expiry': _dateText(notice.expiry),
            }),
          ),
          paragraph(
            tr('{deadline}까지 사용 시기를 정해 알려 주십시오.', {
              'deadline': _dateText(notice.deadline),
            }),
          ),
          if (notice.planDates.isNotEmpty) ...[
            label(
              notice.plannedAt == null
                  ? tr('제출한 사용 계획')
                  : tr('제출한 사용 계획 ({at} 제출)', {
                      'at': formatDateTime(notice.plannedAt!),
                    }),
            ),
            dateList(notice.planDates),
          ],
        ] else ...[
          paragraph(
            tr(
              '귀하가 정해진 기한까지 사용 시기를 알리지 않아, 사용하지 않은 연차 {remaining} 가운데 아래 날짜를 사용 시기로 지정합니다.',
              {'remaining': remaining},
            ),
          ),
          label(tr('지정한 날짜')),
          dateList(notice.designatedDates),
        ],
        pw.SizedBox(height: 16),
        paragraph(tr('근로기준법 제61조(연차 유급휴가의 사용 촉진)에 따라 통지합니다.')),
        if (notice.message != null && notice.message!.trim().isNotEmpty) ...[
          label(tr('덧붙인 말')),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: line, width: 0.6),
            ),
            child: pw.Text(
              notice.message!.trim(),
              style: const pw.TextStyle(fontSize: 10.5),
            ),
          ),
        ],
        pw.SizedBox(height: 24),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(
                tr('보낸 사람  {name}', {'name': notice.sentByName ?? scopeLabel}),
                style: const pw.TextStyle(fontSize: 10.5),
              ),
              pw.SizedBox(height: 3),
              pw.Text(
                tr('보낸 날짜  {at}', {
                  'at': notice.sentAt == null
                      ? '—'
                      : formatDateTime(notice.sentAt!),
                }),
                style: const pw.TextStyle(fontSize: 10.5),
              ),
              pw.SizedBox(height: 3),
              pw.Text(
                notice.readAt == null
                    ? tr('확인한 날짜  아직 확인하지 않음')
                    : tr('확인한 날짜  {at}', {
                        'at': formatDateTime(notice.readAt!),
                      }),
                style: const pw.TextStyle(fontSize: 10.5),
              ),
            ],
          ),
        ),
      ],
      footer: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Divider(color: line, thickness: 0.6),
          pw.Text(
            tr('이 통지에 따라 사용하지 않은 연차는 사용자의 보상 의무가 면제될 수 있습니다.'),
            style: pw.TextStyle(fontSize: 8.5, color: grey),
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

// ── 도움 ─────────────────────────────────────────────────────────────────

/// 한글 글꼴 — approval_print.dart와 같은 파일(옛한글까지 든 나눔바른고딕), 한 번만 읽어 둔다(급여명세서 PDF도 쓴다).
pw.Font? _font;
Future<pw.Font> koreanPdfFont() async => _font ??= pw.Font.ttf(
  await rootBundle.load('assets/fonts/NanumBarunGothic-YetHangul.ttf'),
);

/// 'YYYY-MM-DD' → "2027년 3월 2일"(모양이 다르면 그대로).
String _dateText(String key) {
  final d = DateTime.tryParse(key);
  if (d == null || key.length < 10) return key;
  return tr('{y}년 {m}월 {d}일', {'y': d.year, 'm': d.month, 'd': d.day});
}

/// 저장 파일 이름 — "연차 사용 촉진 통지서_김가_2026-10-17"(파일 이름에 못 쓰는 글자는 '_').
String _noticeFileName(LeavePromotion notice, String employeeName) {
  final sent = notice.sentAt == null
      ? notice.deadline
      : dateKeyOf(notice.sentAt!);
  return '${leaveNoticeTitle(notice)}_${employeeName}_$sent'.replaceAll(
    RegExp(r'[\\/:*?"<>|\n\r]'),
    '_',
  );
}

/// 받은 파일을 둘 폴더(급여명세서 PDF — payslip_view.dart도 쓴다) — 환경설정의 다운로드 폴더(AppSettings.downloadFolder와 같은 규칙: 휴대폰은 정해진 폴더, 데스크톱은 저장한 폴더
/// 아니면 사용자 폴더의 Downloads). 이 함수는 [Session] 없이 불리므로(서명이 정해져 있다) 설정 값을 직접 읽는다.
Future<String> pdfDownloadFolder() async {
  if (AppPlatform.isAndroid || AppPlatform.isIOS) return mobileDownloadFolder();
  if (kIsWeb) return '';
  try {
    final saved = (await SharedPreferences.getInstance()).getString(
      'settings_download_folder',
    );
    if (saved != null && saved.isNotEmpty) return saved;
  } catch (_) {
    // 설정을 못 읽으면 기본 폴더로.
  }
  final home =
      AppPlatform.environment['USERPROFILE'] ??
      AppPlatform.environment['HOME'] ??
      '';
  return home.isEmpty ? '' : '$home${AppPlatform.pathSeparator}Downloads';
}
