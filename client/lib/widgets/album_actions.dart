import 'package:flutter/material.dart';

import '../models/album.dart';
import '../screens/album_create_dialog.dart';
import '../services/album_download.dart';
import '../services/session.dart';
import 'album_share_dialog.dart';
import 'app_toast.dart';
import 'compact_menu.dart';
import '../l10n/tr.dart';

/// 앨범 하나에 대한 ⋯ 메뉴 항목 — 목록 카드와 앨범 상세 머리글이 같은 순서·문구를 쓴다.
enum AlbumAction {
  download('전체 다운로드', Icons.file_download_outlined),
  share('앨범 공유', Icons.share_outlined),
  edit('앨범 수정', Icons.edit_outlined),
  delete('앨범 삭제', Icons.delete_outline);

  final String _labelKo;

  /// 화면에 보일 이름(지금 언어 — l10n/tr.dart).
  String get label => tr(_labelKo);
  final IconData icon;
  const AlbumAction(this._labelKo, this.icon);
}

/// 보는 사람이 할 수 있는 동작만 — 공유는 앨범 방의 멤버만(공유 메시지로만 보는 사람 제외), 수정·삭제는 서버가 준 권한대로.
List<AlbumAction> albumActionsFor(Album album) => [
  AlbumAction.download,
  if (album.canShare && !album.viewOnly) AlbumAction.share,
  if (album.canEdit && !album.viewOnly) AlbumAction.edit,
  if (album.canDelete && !album.viewOnly) AlbumAction.delete,
];

/// ⋯ 팝업의 항목들([CompactMenu] 모양) — 삭제 앞에는 구분선, 삭제는 빨간 글씨.
List<PopupMenuEntry<AlbumAction>> albumActionMenuItems(
  BuildContext context,
  Album album,
) => [
  for (final a in albumActionsFor(album)) ...[
    if (a == AlbumAction.delete) CompactMenu.divider,
    CompactMenu.item<AlbumAction>(
      context,
      value: a,
      icon: a.icon,
      label: a.label,
      color: a == AlbumAction.delete ? Colors.redAccent : null,
    ),
  ],
];

/// "앨범 수정" — 제목·설명 고치기 창. 고쳤으면 토스트로 알린다.
Future<void> editAlbumWithDialog(
  BuildContext context,
  Session session,
  Album album,
) async {
  final result = await showAlbumEditor(context, session: session, album: album);
  if (result != null && context.mounted) {
    showAppToast(context, tr('앨범을 수정했습니다.'));
  }
}

/// "앨범 삭제" — 확인을 받고 지운다. 열어 둔 앨범이었으면 목록으로 돌아간다(컨트롤러).
Future<void> confirmAndDeleteAlbum(
  BuildContext context,
  Session session,
  Album album,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(tr('앨범 삭제')),
      content: Text(
        tr(
          '\'{album.title}\' 앨범을 삭제할까요? 앨범의 사진·영상이 모두 사라집니다. 대화방에 공유한 메시지는 그대로 남습니다.',
          {'album.title': album.title},
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(tr('취소')),
        ),
        TextButton(
          key: const ValueKey('album-delete-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(tr('삭제'), style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final overlay = Overlay.of(context);
  try {
    await session.albums.deleteAlbum(albumId: album.id);
    showAppToastOnOverlay(overlay, tr('앨범을 삭제했습니다.'));
  } catch (e) {
    showAppToastOnOverlay(overlay, tr('앨범을 삭제하지 못했습니다: {e}', {'e': e}));
  }
}

/// 목록 카드의 "전체 다운로드" — 열지 않은 앨범의 항목을 끝까지 받아 [downloadAlbumItems]로 내려받는다.
Future<void> downloadWholeAlbum(
  BuildContext context,
  Session session,
  Album album,
) async {
  final overlay = Overlay.of(context);
  try {
    final items = await session.albums.fetchAllItemsOf(album.id);
    if (!context.mounted) return;
    if (items.isEmpty) {
      showAppToastOnOverlay(overlay, tr('내려받을 사진·영상이 없습니다.'));
      return;
    }
    await downloadAlbumItems(context, session, items);
  } catch (e) {
    showAppToastOnOverlay(overlay, tr('다운로드하지 못했습니다: {e}', {'e': e}));
  }
}

/// "앨범 공유" — 대화방·메시지를 받아 앨범 카드 메시지로 보낸다(album_share_dialog.dart).
Future<void> shareAlbumToRoom(
  BuildContext context,
  Session session,
  Album album,
) => showAlbumMessageShareDialog(context, session: session, album: album);
