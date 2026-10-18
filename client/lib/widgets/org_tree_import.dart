import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../l10n/tr.dart';
import '../models/org_tree.dart';

/// 조직도 엑셀 가져오기 도움 — 파일 고르기, 미리 보기 창, 바꾼 뒤 알림 글(서버 orgTree.js POST /org-tree/import).
///
/// 가져오는 파일은 "엑셀로 내보내기"로 받은 모양 그대로다 — "부서" 시트(부서 경로 "본부 > 팀"·부서장 아이디·순서)와 "구성원" 시트(아이디·
/// 이름·부서 경로·직책·상위자 아이디·겸직 부서 — 여럿은 ;). 빈칸은 그대로, "-"는 비우기. 사람은 아이디로 찾고 없는 부서는 만들며, 지우는
/// 것은 없다. 줄마다의 오류가 하나라도 있으면 서버가 아무것도 바꾸지 않는다.

/// .xlsx 하나를 골라 (이름, 바이트)로 — 취소하면 null. 웹은 경로 없이 바이트만 오고, 바이트가 비어 오면 경로에서 읽는다(xFile이
/// 둘 다 감싼다).
Future<({String name, List<int> bytes})?> pickOrgImportFile() async {
  final picked = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['xlsx'],
    withData: true,
    dialogTitle: tr('엑셀에서 가져오기'),
  );
  final file = picked?.files.single;
  if (file == null || (file.path == null && file.bytes == null)) return null;
  final bytes = file.bytes ?? await file.xFile.readAsBytes();
  return (name: file.name, bytes: bytes);
}

/// 줄마다의 오류 한 줄 — "구성원 3번째 줄: 없는 부서입니다"(시트·줄을 모르면 그 부분을 뺀다). 서버 글은 [trServer]로 옮긴다.
String orgImportErrorText(({String? sheet, int? row, String message}) e) {
  final message = trServer(e.message);
  if (e.row != null) {
    return tr('{sheet} {row}번째 줄: {message}', {
      'sheet': e.sheet ?? '',
      'row': e.row,
      'message': message,
    });
  }
  return e.sheet == null ? message : '${e.sheet}: $message';
}

/// 바꾼 뒤(또는 미리 보기의) 바뀌는 양 한 줄 — 알림에.
String orgImportSummaryText(OrgImportResult r) => tr(
  '만들 부서 {createDepartments}개 · 부서장 바꿈 {headChanges} · 순서 {orderChanges} · 사람 {memberChanges}명',
  {
    'createDepartments': r.createDepartments,
    'headChanges': r.headChanges,
    'orderChanges': r.orderChanges,
    'memberChanges': r.memberChanges,
  },
);

/// 건너뛴 사람(상위자가 서로 물려서 등) 한 줄 — "홍길동(까닭), …". 없으면 null.
String? orgImportSkippedText(OrgImportResult r) {
  if (r.skipped.isEmpty) return null;
  return tr('건너뛴 사람 {count}명: {list}', {
    'count': r.skipped.length,
    'list': [
      for (final s in r.skipped) '${s.name ?? '?'}(${trServer(s.error)})',
    ].join(', '),
  });
}

/// 가져오기 미리 보기 창 — 바뀌는 양(만들 부서·부서장·순서·사람)과 줄마다의 오류. 오류가 있으면 "닫기"만 있고, 없으면 "가져오기"
/// (key `org-import-apply`)를 누를 때 true. 바뀌는 것이 하나도 없으면 "가져오기"는 꺼져 있다.
class OrgImportPreviewDialog extends StatelessWidget {
  final OrgImportResult result;
  final String fileName;
  const OrgImportPreviewDialog({
    super.key,
    required this.result,
    required this.fileName,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final r = result;
    final hasErrors = r.errors.isNotEmpty;
    final total =
        r.createDepartments + r.headChanges + r.orderChanges + r.memberChanges;
    Widget count(String label) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(label),
    );
    return AlertDialog(
      title: Text(tr('엑셀에서 가져오기')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                tr(
                  "내보낸 파일을 고쳐서 가져오세요. 빈칸은 그대로, '-'는 비우기입니다. 사람은 아이디로 찾고, 없는 부서는 새로 만들며, 지우는 것은 없습니다.",
                ),
                style: TextStyle(fontSize: 12, color: hint),
              ),
              const SizedBox(height: 12),
              if (hasErrors) ...[
                Text(
                  tr('고칠 곳이 {count}군데 있어 가져올 수 없습니다.', {
                    'count': r.errors.length,
                  }),
                  key: const ValueKey('org-import-errors'),
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                for (final (i, e) in r.errors.indexed)
                  Padding(
                    key: ValueKey('org-import-error-$i'),
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      orgImportErrorText(e),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
              ] else if (total == 0)
                Text(tr('바뀌는 것이 없습니다.'))
              else ...[
                count(tr('만들 부서 {count}개', {'count': r.createDepartments})),
                count(tr('부서장 바꿈 {count}', {'count': r.headChanges})),
                count(tr('순서 {count}', {'count': r.orderChanges})),
                count(tr('사람 {count}명', {'count': r.memberChanges})),
              ],
            ],
          ),
        ),
      ),
      actions: hasErrors
          ? [
              TextButton(
                key: const ValueKey('org-import-close'),
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(tr('닫기')),
              ),
            ]
          : [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(tr('취소')),
              ),
              FilledButton(
                key: const ValueKey('org-import-apply'),
                onPressed: total == 0
                    ? null
                    : () => Navigator.of(context).pop(true),
                child: Text(tr('가져오기')),
              ),
            ],
    );
  }
}
