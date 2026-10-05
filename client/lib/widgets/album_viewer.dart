import 'package:flutter/material.dart';

import '../models/album.dart';
import '../screens/image_viewer_screen.dart';
import '../services/album_download.dart' show albumItemFileName;
import '../services/download_storage.dart';
import '../services/session.dart';
import 'app_toast.dart';
import 'attachment_widgets.dart' show fetchAttachmentBytes;

/// 앨범 항목을 연다 — 이미지는 같은 앨범의 (불러온) 이미지들을 좌우로 넘겨 보는 뷰어로, 영상은 기존 파일 열기와 같이
/// 받아서 기본 동영상 앱으로 연다(인앱 재생 라이브러리가 없다).
Future<void> openAlbumItem(
  BuildContext context,
  Session session,
  List<AlbumItem> items,
  AlbumItem item,
) {
  if (item.isVideo) return openAlbumVideo(context, session, item);
  final images = [
    for (final i in items)
      if (i.isImage) i,
  ];
  final index = images.indexWhere((i) => i.id == item.id);
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ImageViewerScreen(
        images: [
          for (final (n, i) in images.indexed)
            ViewerImage(
              url: session.resolveUrl(i.fileUrl),
              fileName: albumItemFileName(i, n),
              fileSize: i.fileSize,
              id: i.id,
            ),
        ],
        initialIndex: index < 0 ? 0 : index,
      ),
    ),
  );
}

/// 영상 하나를 받아서 기본 앱으로 연다 — 다운로드 폴더를 정해 뒀으면 거기에(같은 파일은 다시 받지 않는다), 아니면 임시 폴더에.
Future<void> openAlbumVideo(
  BuildContext context,
  Session session,
  AlbumItem item,
) async {
  final overlay = Overlay.of(context);
  showAppToastOnOverlay(overlay, '영상을 여는 중입니다…');
  try {
    final bytes = await fetchAttachmentBytes(
      session: session,
      url: session.resolveUrl(item.fileUrl),
    );
    final folder = session.settings.downloadFolder;
    final path = await writeDownloadFile(
      folder: folder.isEmpty ? await downloadTempFolder() : folder,
      fileName: albumItemFileName(item, 0),
      bytes: bytes,
      reuseIdentical: true,
    );
    await openLocalFile(path);
  } catch (e) {
    showAppToastOnOverlay(overlay, '영상을 열지 못했습니다: $e');
  }
}
