import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../models/groupware_finance.dart';
import '../../l10n/tr.dart';

/// 급여명세서·법인카드 화면이 같이 쓰는 작은 도움들 — 표 파일 고르기, 가려지는 금액, 사유 묻기, 달 목록.

/// 엑셀(.xlsx)·CSV·카드사의 HTML 엑셀(.xls) 하나를 골라 (이름, 바이트, 형식)으로 — 취소하면 null.
Future<({String name, List<int> bytes, String contentType})?> pickSheetFile({
  String? title,
}) async {
  final picked = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['xlsx', 'csv', 'xls', 'htm', 'html', 'txt'],
    withData: true,
    dialogTitle: title ?? tr('파일 고르기'),
  );
  final file = picked?.files.single;
  if (file == null || (file.path == null && file.bytes == null)) return null;
  final bytes = file.bytes ?? await file.xFile.readAsBytes();
  final lower = file.name.toLowerCase();
  final type = lower.endsWith('.xlsx')
      ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
      : lower.endsWith('.csv') || lower.endsWith('.txt')
      ? 'text/csv'
      : 'application/octet-stream';
  return (name: file.name, bytes: bytes, contentType: type);
}

/// 금액 — [reveal]이 false면 "•••••원"으로 가린다(옆 사람이 화면을 볼 때).
class MaskedWon extends StatelessWidget {
  final int amount;
  final bool reveal;
  final TextStyle? style;
  const MaskedWon(this.amount, {super.key, required this.reveal, this.style});

  @override
  Widget build(BuildContext context) =>
      Text(reveal ? signedWonText(amount) : tr('•••••원'), style: style);
}

/// 한 줄 글을 묻는다(사유 등) — [required]면 비우고는 못 누른다. 취소하면 null.
Future<String?> askText(
  BuildContext context, {
  required String title,
  String? label,
  String? message,
  String? initial,
  String? okLabel,
  bool required = true,
  int maxLength = 200,
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message != null) ...[
                Text(message),
                const SizedBox(height: 12),
              ],
              TextField(
                key: const ValueKey('ask-text-field'),
                controller: controller,
                autofocus: true,
                maxLength: maxLength,
                decoration: InputDecoration(
                  labelText: label,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(tr('취소')),
          ),
          FilledButton(
            key: const ValueKey('ask-text-ok'),
            onPressed: required && controller.text.trim().isEmpty
                ? null
                : () => Navigator.pop(dialogContext, controller.text.trim()),
            child: Text(okLabel ?? tr('확인')),
          ),
        ],
      ),
    ),
  );
  controller.dispose();
  return result;
}

/// 예/아니오를 묻는다.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  String? okLabel,
  bool danger = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: SizedBox(width: 420, child: Text(message)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('confirm-action-ok'),
          style: danger
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(dialogContext).colorScheme.error,
                )
              : null,
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(okLabel ?? tr('확인')),
        ),
      ],
    ),
  );
  return ok == true;
}

/// 'YYYY-MM' 앞뒤로 [delta]달.
String shiftMonth(String month, int delta) {
  final y = int.parse(month.substring(0, 4));
  final m = int.parse(month.substring(5, 7));
  final d = DateTime(y, m + delta);
  return '${d.year}-${d.month.toString().padLeft(2, '0')}';
}

/// 'YYYY-MM' → "2026년 10월".
String monthLabel(String month) => month.length < 7
    ? month
    : tr('{y}년 {m}월', {
        'y': int.parse(month.substring(0, 4)),
        'm': int.parse(month.substring(5, 7)),
      });

/// 달 넘기기 줄(◀ 2026년 10월 ▶).
class MonthStepper extends StatelessWidget {
  final String month;
  final ValueChanged<String> onChanged;
  const MonthStepper({super.key, required this.month, required this.onChanged});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        key: const ValueKey('month-prev'),
        tooltip: tr('지난달'),
        icon: const Icon(Icons.chevron_left),
        onPressed: () => onChanged(shiftMonth(month, -1)),
      ),
      Text(monthLabel(month)),
      IconButton(
        key: const ValueKey('month-next'),
        tooltip: tr('다음 달'),
        icon: const Icon(Icons.chevron_right),
        onPressed: () => onChanged(shiftMonth(month, 1)),
      ),
    ],
  );
}

/// 금액 입력칸의 값(원) — 쉼표·공백은 빼고, 음수도 받는다. 비었거나 숫자가 아니면 null.
int? parseWonInput(String text) =>
    int.tryParse(text.replaceAll(RegExp(r'[,\s원]'), '').trim());

/// 금액 입력칸의 처음 글(0이면 비운다).
String wonInputText(int amount) => amount == 0 ? '' : '$amount';
