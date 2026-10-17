import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import '../models/album.dart';
import '../widgets/attachment_widgets.dart'
    show fetchAttachmentBytes, saveAttachment;
import '../widgets/app_toast.dart';
import '../widgets/data_usage_warning.dart';
import 'app_platform.dart';
import 'download_progress.dart';
import 'download_storage.dart';
import 'session.dart';

/// 앨범 항목 여러 개를 내려받은 결과.
class AlbumDownloadSummary {
  final int saved;
  final int failed;

  /// 저장한 폴더(안드로이드는 공용 Download 아래 폴더) — 없으면 null.
  final String? folder;
  const AlbumDownloadSummary({this.saved = 0, this.failed = 0, this.folder});
}

/// 저장할 파일 이름 — 올린 사람이 정한 이름을 [safeFileName]으로 다듬은 것. 이름이 없거나 다듬고 남는 게 없으면 종류에
/// 맞는 확장자로 임시 이름을 만든다.
String albumItemFileName(AlbumItem item, int index) {
  final name = safeFileName(item.fileName ?? '', fallback: '');
  if (name.isNotEmpty) return name;
  final mime = (item.mimeType ?? '').toLowerCase();
  final ext = mime.contains('/') && mime.split('/').last.isNotEmpty
      ? mime.split('/').last.replaceAll('jpeg', 'jpg')
      : (item.isVideo ? 'mp4' : 'jpg');
  return 'album_${index + 1}.$ext';
}

/// [items]를 [folder]에 차례로 저장한다 — 이름이 겹치면 "이름 (1).확장자"로 번호를 붙이고(덮어쓰지 않는다), 한 개가
/// 실패해도 나머지는 계속한다. [fetch]는 항목의 바이트를 받아 오는 함수(서명 링크가 만료됐으면 새로 받아 재시도하는 것까지
/// 맡는다 — 앱에서는 [fetchAttachmentBytes]).
Future<AlbumDownloadSummary> saveAlbumItemsToFolder({
  required List<AlbumItem> items,
  required String folder,
  required Future<List<int>> Function(AlbumItem item) fetch,
  void Function(int done, int total)? onProgress,
}) async {
  var saved = 0;
  var failed = 0;
  onProgress?.call(0, items.length);
  for (var i = 0; i < items.length; i++) {
    try {
      final bytes = await fetch(items[i]);
      await writeDownloadFile(
        folder: folder,
        fileName: albumItemFileName(items[i], i),
        bytes: bytes,
      );
      saved++;
    } on DownloadCancelled {
      break;
    } catch (_) {
      failed++;
    }
    onProgress?.call(i + 1, items.length);
  }
  return AlbumDownloadSummary(saved: saved, failed: failed, folder: folder);
}

bool get _isMobile => AppPlatform.isAndroid || AppPlatform.isIOS;

/// 앨범 항목들을 내려받는다 — Windows 등 PC는 폴더 선택 대화상자로 받은 폴더에 차례로 저장하고, 안드로이드는 파일 하나
/// 다운로드와 같은 방식(공용 Download/TangoTalk)으로 항목마다 저장한다. 끝나면 토스트로 알린다. 서명 링크(약 2시간)가
/// 만료됐으면 [fetchAttachmentBytes]가 새 링크를 받아 한 번 더 시도한다.
Future<void> downloadAlbumItems(
  BuildContext context,
  Session session,
  List<AlbumItem> items, {
  void Function(int done, int total)? onProgress,
}) async {
  if (items.isEmpty) return;
  final overlay = Overlay.of(context);
  final ok = await confirmCellularDownload(
    context,
    session: session,
    items: [
      for (final i in items)
        (url: session.resolveUrl(i.fileUrl), size: i.fileSize),
    ],
  );
  if (!ok || !context.mounted) return;

  // 진행 카드에 "파일 N개"로 보이고, 그 X로 멈추면 [task].cancelled.
  final task = DownloadTask('파일 ${items.length}개', fileCount: items.length);

  Future<List<int>> fetch(AlbumItem item) => fetchAttachmentBytes(
    session: session,
    url: session.resolveUrl(item.fileUrl),
  );

  AlbumDownloadSummary summary;
  // 웹은 폴더를 고를 수 없어 모바일처럼 하나씩 받는다(브라우저 다운로드).
  if (_isMobile || kIsWeb) {
    var saved = 0;
    var failed = 0;
    onProgress?.call(0, items.length);
    // 받는 동안 진행 카드에 "파일 N개"와 몇 번째·받은 양이 보인다(파일마다의 저장은 이 안에서 이어 센다).
    await trackDownload(
      task: task,
      body: () async {
        for (var i = 0; i < items.length; i++) {
          try {
            final path = await saveAttachment(
              session: session,
              url: session.resolveUrl(items[i].fileUrl),
              fileName: albumItemFileName(items[i], i),
            );
            path == null ? failed++ : saved++;
          } on DownloadCancelled {
            break;
          } catch (_) {
            failed++;
          }
          onProgress?.call(i + 1, items.length);
        }
      },
    );
    summary = AlbumDownloadSummary(
      saved: saved,
      failed: failed,
      folder: kIsWeb ? null : await mobileDownloadFolder(),
    );
  } else {
    final initial = session.settings.downloadFolder;
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: '저장할 폴더 선택',
      initialDirectory: initial.isEmpty ? null : initial,
    );
    if (folder == null) return;
    summary = await trackDownload(
      task: task,
      body: () => saveAlbumItemsToFolder(
        items: items,
        folder: folder,
        fetch: fetch,
        onProgress: onProgress,
      ),
    );
  }

  final where = summary.folder == null
      ? ''
      : ' (${displayDownloadPath(summary.folder!)})';
  final message = task.cancelled
      ? summary.saved == 0
            ? '다운로드를 취소했습니다.'
            : '다운로드를 취소했습니다. (${summary.saved}개는 받았습니다)$where'
      : summary.failed == 0
      ? '${summary.saved}개를 다운로드했습니다.$where'
      : summary.saved == 0
      ? '다운로드하지 못했습니다.'
      : '${summary.saved}개를 다운로드했습니다. ${summary.failed}개는 실패했습니다.$where';
  showAppToastOnOverlay(overlay, message, duration: const Duration(seconds: 4));
  // 폴더 선택 창에서 고른 곳(설정 폴더가 아닐 수 있다)을 연다.
  if (summary.saved > 0 && session.settings.openFolderAfterDownload) {
    await session.settings.openDownloadFolder(summary.folder);
  }
}
