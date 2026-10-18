import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/network_type.dart';
import '../services/session.dart';
import 'attachment_widgets.dart' show formatFileSize;
import '../l10n/tr.dart';

/// 휴대폰 데이터로 받을 때 이 크기(합계) 이상이면 데이터 사용 경고를 띄운다.
const kCellularDownloadWarnBytes = 10 * 1024 * 1024;

/// 받을 첨부 하나 — [size]를 모르면(null) 받기 전에 서버에 크기만 물어본다(HEAD).
typedef DownloadSizeItem = ({String url, int? size});

/// 휴대폰 데이터(LTE·5G)로 큰 첨부를 받으려 할 때 카카오톡처럼 "데이터 사용 경고"를 띄워 확인을 받는다 —
/// 받아도 되면 true. Wi-Fi이거나 연결 종류를 알 수 없거나(PC 등 — [isOnCellularData]) 합계가
/// [kCellularDownloadWarnBytes]보다 작으면 묻지 않고 true.
///
/// 크기는 휴대폰 데이터일 때만 알아본다 — Wi-Fi에서는 서버에 따로 묻지 않는다. 크기를 끝내 모르는 파일은
/// 합계에서 뺀다(그런 링크는 받기도 실패한다).
Future<bool> confirmCellularDownload(
  BuildContext context, {
  required Session session,
  required List<DownloadSizeItem> items,
}) async {
  if (items.isEmpty || !await isOnCellularData()) return true;
  final sizes = await Future.wait([
    for (final item in items)
      item.size != null
          ? Future.value(item.size)
          : _remoteFileSize(session, item.url),
  ]);
  final total = sizes.fold<int>(0, (sum, s) => sum + (s ?? 0));
  if (total < kCellularDownloadWarnBytes) return true;
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (context) => AlertDialog(
      title: Text(tr('데이터 사용 경고')),
      content: Text(
        tr(
          'Wi-Fi에 연결되어 있지 않습니다.\n모바일 데이터(LTE/5G)로 {p0}{p1}를 다운로드하면 데이터 요금이 발생할 수 있습니다.\n\n다운로드할까요?',
          {
            'p0': formatFileSize(total),
            'p1': items.length > 1
                ? tr('(파일 {items.length}개)', {'items.length': items.length})
                : '',
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('confirm-cellular-download'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(tr('확인')),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// [url] 파일의 크기를 서버에 묻는다(HEAD의 Content-Length) — 모르면 null. 링크가 만료됐으면(401)
/// fetchAttachmentBytes처럼 새 링크를 받아 한 번 더 묻는다.
Future<int?> _remoteFileSize(Session session, String url) async {
  try {
    var res = await http.head(Uri.parse(url));
    final api = session.api;
    if (res.statusCode == 401 && api != null) {
      final fresh = await api.resignFileUrl(Uri.parse(url).path);
      res = await http.head(Uri.parse(session.resolveUrl(fresh)));
    }
    if (res.statusCode >= 400) return null;
    // http.Response.contentLength는 받은 본문 길이(HEAD면 0)라 헤더를 직접 읽는다.
    return int.tryParse(res.headers['content-length'] ?? '');
  } catch (_) {
    return null;
  }
}
