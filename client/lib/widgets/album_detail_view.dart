import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/album.dart';
import '../services/album_controller.dart';
import '../services/album_download.dart';
import '../services/album_media.dart';
import '../services/session.dart';
import 'album_actions.dart';
import 'album_share_dialog.dart';
import 'album_viewer.dart';
import 'app_toast.dart';
import 'attachment_widgets.dart' show DropZoneOverlay;
import 'compact_menu.dart';
import 'panel_filters.dart' show formatPanelDate;

/// 앨범 상세 — 위에 뒤로가기·제목·⋯(수정/전체 다운로드/삭제), 설명, `+ 파일 추가`·`선택` 단추, 드래그 앤 드롭 영역(PC),
/// 올리는 중인 파일(진행률·재시도), 정사각 썸네일 격자, 선택 모드의 아래 막대(다운로드·공유·삭제).
class AlbumDetailView extends StatefulWidget {
  final Session session;
  final VoidCallback? onClose;
  const AlbumDetailView({super.key, required this.session, this.onClose});

  @override
  State<AlbumDetailView> createState() => _AlbumDetailViewState();
}

class _AlbumDetailViewState extends State<AlbumDetailView> {
  final _scroll = ScrollController();
  bool _dragHovering = false;
  int? _downloadDone;
  int _downloadTotal = 0;

  AlbumController get _albums => widget.session.albums;
  bool get _desktop => !(Platform.isAndroid || Platform.isIOS);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  // ── 올리기 ───────────────────────────────────────────────────────

  Future<void> _pickFiles() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      // 안드로이드는 갤러리(사진·영상)에서, PC는 이미지·영상 확장자로 거른 파일 선택 창.
      type: Platform.isAndroid ? FileType.media : FileType.custom,
      allowedExtensions: Platform.isAndroid ? null : albumPickerExtensions,
    );
    final files = [
      for (final f in result?.files ?? const <PlatformFile>[])
        if (f.path != null) File(f.path!),
    ];
    if (files.isNotEmpty && mounted) addFiles(files);
  }

  /// 파일을 올리기 시작한다 — 한 번에 100개까지, 넘으면 앞의 100개만 올리고 알린다(드롭도 같은 길).
  void addFiles(List<File> files) {
    final result = _albums.addFiles(files);
    if (!mounted) return;
    final notes = <String>[
      if (result.overLimit > 0)
        '한 번에 $albumUploadMaxCount개까지 올릴 수 있어 앞의 $albumUploadMaxCount개만 올립니다.',
      if (result.unsupported > 0) '이미지·영상이 아닌 ${result.unsupported}개는 제외했습니다.',
    ];
    if (notes.isNotEmpty) {
      showAppToast(
        context,
        notes.join(' '),
        duration: const Duration(seconds: 4),
      );
    }
  }

  // ── 단추 동작 ─────────────────────────────────────────────────────

  Future<void> _download(List<AlbumItem> items) async {
    if (_downloadDone != null || items.isEmpty) return;
    setState(() {
      _downloadDone = 0;
      _downloadTotal = items.length;
    });
    try {
      await downloadAlbumItems(
        context,
        widget.session,
        items,
        onProgress: (done, total) {
          if (mounted) {
            setState(() {
              _downloadDone = done;
              _downloadTotal = total;
            });
          }
        },
      );
    } catch (e) {
      if (mounted) showAppToast(context, '다운로드하지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _downloadDone = null);
    }
  }

  Future<void> _downloadAll() async {
    final all = await _albums.loadAllItems();
    if (!mounted) return;
    await _download(all);
  }

  Future<void> _share(Album album) async {
    final ids = [for (final i in _albums.selectedItems) i.id];
    if (ids.isEmpty) return;
    if (ids.length > albumShareMaxCount) {
      showAppToast(context, '한 번에 $albumShareMaxCount개까지 공유할 수 있습니다.');
      return;
    }
    final shared = await showAlbumShareDialog(
      context,
      session: widget.session,
      album: album,
      itemIds: ids,
    );
    if (shared) _albums.clearSelection();
  }

  Future<void> _deleteSelected(Album album) async {
    final selected = _albums.selectedItems;
    if (selected.isEmpty) return;
    final deletable = selected.where((i) => i.canDelete).length;
    if (deletable == 0) {
      showAppToast(
        context,
        '지울 권한이 있는 항목이 없습니다. (올린 사람이나 앨범을 만든 사람, 팀 관리자만 지울 수 있어요)',
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('항목 삭제'),
        content: Text(
          deletable == selected.length
              ? '선택한 ${selected.length}개를 앨범에서 삭제할까요?'
              : '선택한 ${selected.length}개 중 내가 지울 수 있는 $deletable개만 삭제됩니다. 계속할까요?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('삭제', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final overlay = Overlay.of(context);
    try {
      final result = await _albums.deleteItems([
        for (final i in selected) i.id,
      ]);
      _albums.clearSelection();
      showAppToastOnOverlay(
        overlay,
        result.skipped > 0
            ? '${result.deleted}개를 삭제했습니다. 권한이 없는 ${result.skipped}개는 남겼습니다.'
            : '${result.deleted}개를 삭제했습니다.',
      );
    } catch (e) {
      showAppToastOnOverlay(overlay, '삭제하지 못했습니다: $e');
    }
  }

  Future<void> _setCover() async {
    final selected = _albums.selectedItems;
    if (selected.length != 1) return;
    final overlay = Overlay.of(context);
    try {
      await _albums.updateAlbum(coverItemId: selected.first.id);
      await _albums.reloadAlbum();
      _albums.clearSelection();
      showAppToastOnOverlay(overlay, '대표 이미지로 정했습니다.');
    } catch (e) {
      showAppToastOnOverlay(overlay, '대표 이미지를 정하지 못했습니다: $e');
    }
  }

  // ── 화면 ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _albums,
      builder: (context, _) {
        final album = _albums.album;
        if (_albums.albumGone || album == null) return _gone(context);
        final body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context, album),
            Expanded(child: _content(context, album)),
            if (_albums.selecting) _selectionBar(context, album),
          ],
        );
        // 공유 메시지로만 보는 사람(보기 전용)은 올릴 수 없으니 끌어다 놓기도 받지 않는다.
        if (!_desktop || album.viewOnly) return body;
        return DropTarget(
          onDragEntered: (_) => setState(() => _dragHovering = true),
          onDragExited: (_) => setState(() => _dragHovering = false),
          onDragDone: (details) {
            setState(() => _dragHovering = false);
            addFiles([for (final f in details.files) File(f.path)]);
          },
          child: Stack(
            children: [
              Positioned.fill(child: body),
              if (_dragHovering)
                const Positioned.fill(
                  child: IgnorePointer(child: DropZoneOverlay()),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _gone(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: '목록으로',
                onPressed: _albums.closeAlbum,
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: '닫기',
                onPressed: widget.onClose,
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: Text(
              _albums.detailError ?? '삭제되었거나 볼 수 없는 앨범입니다.',
              key: const ValueKey('album-gone'),
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, Album album) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('album-back'),
            icon: const Icon(Icons.arrow_back),
            tooltip: '목록으로',
            onPressed: _albums.closeAlbum,
          ),
          Expanded(
            child: Text(
              album.title,
              key: const ValueKey('album-detail-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          PopupMenuButton<AlbumAction>(
            key: const ValueKey('album-more'),
            tooltip: '더보기',
            position: PopupMenuPosition.under,
            color: CompactMenu.color(context),
            shape: CompactMenu.shape,
            menuPadding: CompactMenu.menuPadding,
            constraints: const BoxConstraints(minWidth: 160, maxWidth: 240),
            onSelected: (a) {
              switch (a) {
                case AlbumAction.download:
                  _downloadAll();
                case AlbumAction.share:
                  shareAlbumToRoom(context, widget.session, album);
                case AlbumAction.edit:
                  editAlbumWithDialog(context, widget.session, album);
                case AlbumAction.delete:
                  confirmAndDeleteAlbum(context, widget.session, album);
              }
            },
            itemBuilder: (context) => albumActionMenuItems(context, album),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: '닫기',
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context, Album album) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final items = _albums.items;
    final uploads = _albums.currentUploads;
    final meta = [
      if (album.roomName != null) album.roomName!,
      if (album.creatorName != null) album.creatorName!,
      formatPanelDate(album.createdAt),
      '사진·영상 ${album.itemCount}개',
    ].join(' · ');
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 400) _albums.loadMoreItems();
        return false;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = (constraints.maxWidth / 116).floor().clamp(3, 8);
          return CustomScrollView(
            key: const ValueKey('album-detail-scroll'),
            controller: _scroll,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    if (album.description != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          album.description!,
                          key: const ValueKey('album-description'),
                          style: const TextStyle(fontSize: 13, height: 1.4),
                        ),
                      ),
                    Text(
                      meta,
                      key: const ValueKey('album-meta'),
                      style: TextStyle(fontSize: 12, color: hint),
                    ),
                    if (album.viewOnly) ...[
                      const SizedBox(height: 8),
                      Text(
                        '공유된 앨범입니다. 이 앨범의 대화방 멤버만 사진·영상을 올리거나 지울 수 있습니다.',
                        key: const ValueKey('album-view-only'),
                        style: TextStyle(fontSize: 12, color: hint),
                      ),
                    ],
                    const SizedBox(height: 12),
                    _actionRow(context, album),
                    if (_desktop && !_albums.selecting && !album.viewOnly) ...[
                      const SizedBox(height: 10),
                      _dropHint(context),
                    ],
                    if (_downloadDone != null) ...[
                      const SizedBox(height: 10),
                      _progressCard(
                        context,
                        key: const ValueKey('album-download-progress'),
                        label: '다운로드 중 $_downloadDone/$_downloadTotal',
                        value: _downloadTotal == 0
                            ? null
                            : _downloadDone! / _downloadTotal,
                      ),
                    ],
                    if (uploads.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      _uploadsCard(context, uploads),
                    ],
                    const SizedBox(height: 12),
                  ]),
                ),
              ),
              if (!_albums.itemsLoaded)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (items.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _albums.detailError ??
                            (album.viewOnly
                                ? '아직 사진·영상이 없습니다.'
                                : '아직 사진·영상이 없습니다.\n+ 파일 추가로 올려 보세요.'),
                        key: const ValueKey('album-items-empty'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: hint, height: 1.5),
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  sliver: SliverGrid(
                    key: const ValueKey('album-item-grid'),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: 4,
                      crossAxisSpacing: 4,
                    ),
                    delegate: SliverChildBuilderDelegate((context, i) {
                      final item = items[i];
                      return AlbumItemTile(
                        item: item,
                        resolveUrl: widget.session.resolveUrl,
                        selecting: _albums.selecting,
                        selected: _albums.isSelected(item.id),
                        onTap: () => _albums.selecting
                            ? _albums.toggleSelected(item.id)
                            : openAlbumItem(
                                context,
                                widget.session,
                                items,
                                item,
                              ),
                        onLongPress: () {
                          if (!_albums.selecting) _albums.startSelecting();
                          _albums.toggleSelected(item.id);
                        },
                      );
                    }, childCount: items.length),
                  ),
                ),
              if (_albums.itemsLoading &&
                  _albums.itemsLoaded &&
                  items.isNotEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _actionRow(BuildContext context, Album album) {
    if (_albums.selecting) {
      final count = _albums.selectedIds.length;
      final allSelected = count == _albums.items.length && count > 0;
      return Row(
        children: [
          Expanded(
            child: Text(
              '$count개 선택',
              key: const ValueKey('album-selected-count'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            key: const ValueKey('album-select-all'),
            onPressed: allSelected ? _albums.deselectAll : _albums.selectAll,
            child: Text(allSelected ? '선택 해제' : '전체 선택'),
          ),
          TextButton(
            key: const ValueKey('album-select-cancel'),
            onPressed: _albums.clearSelection,
            child: const Text('취소'),
          ),
        ],
      );
    }
    return Row(
      children: [
        if (album.viewOnly)
          const Spacer()
        else
          Expanded(
            child: FilledButton.icon(
              key: const ValueKey('album-add-files'),
              onPressed: _pickFiles,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('파일 추가'),
            ),
          ),
        const SizedBox(width: 8),
        OutlinedButton(
          key: const ValueKey('album-select'),
          onPressed: _albums.items.isEmpty ? null : _albums.startSelecting,
          child: const Text('선택'),
        ),
      ],
    );
  }

  /// PC의 드래그 앤 드롭 안내 칸(실제 드롭은 상세 화면 전체가 받는다).
  Widget _dropHint(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      key: const ValueKey('album-drop-zone'),
      onTap: _pickFiles,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.05),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.35),
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.upload_file_outlined,
              size: 18,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '사진·영상을 여기로 끌어다 놓으세요 (한 번에 최대 $albumUploadMaxCount개)',
                style: TextStyle(fontSize: 12, color: theme.hintColor),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _progressCard(
    BuildContext context, {
    Key? key,
    required String label,
    double? value,
  }) {
    final theme = Theme.of(context);
    return Container(
      key: key,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: value),
        ],
      ),
    );
  }

  Widget _uploadsCard(BuildContext context, List<AlbumUpload> uploads) {
    final theme = Theme.of(context);
    final failed = uploads
        .where((u) => u.status == AlbumUploadStatus.failed)
        .toList();
    final active = uploads.where((u) => u.isActive).toList();
    final done = uploads.length - active.length - failed.length;
    // 전체 진행률 — 끝난 파일은 1, 올라가는 중인 파일은 그 진행분.
    final sum = uploads.fold<double>(0, (acc, u) {
      if (u.status == AlbumUploadStatus.done) return acc + 1;
      if (u.status == AlbumUploadStatus.uploading) {
        return acc + (u.progress ?? 0);
      }
      return acc;
    });
    return Container(
      key: const ValueKey('album-uploads'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            active.isNotEmpty
                ? '업로드 중 ${done + failed.length}/${uploads.length}'
                : '업로드 ${failed.length}개 실패',
            key: const ValueKey('album-upload-label'),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          if (active.isNotEmpty) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: sum / uploads.length),
            const SizedBox(height: 4),
            for (final u in active.take(3))
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  u.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: theme.hintColor),
                ),
              ),
            if (active.length > 3)
              Text(
                '외 ${active.length - 3}개',
                style: TextStyle(fontSize: 11, color: theme.hintColor),
              ),
          ],
          for (final u in failed)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                key: ValueKey('album-upload-failed-${u.id}'),
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 16,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          u.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                        Text(
                          u.error ?? '업로드하지 못했습니다.',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    key: ValueKey('album-upload-retry-${u.id}'),
                    onPressed: () => _albums.retryUpload(u.id),
                    child: const Text('재시도'),
                  ),
                  TextButton(
                    key: ValueKey('album-upload-skip-${u.id}'),
                    onPressed: () => _albums.skipUpload(u.id),
                    child: const Text('건너뛰기'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _selectionBar(BuildContext context, Album album) {
    final theme = Theme.of(context);
    final selected = _albums.selectedItems;
    final empty = selected.isEmpty;
    final canDeleteAny = selected.any((i) => i.canDelete);
    final canCover =
        album.canEdit && selected.length == 1 && selected.first.isImage;
    Widget action({
      required Key key,
      required IconData icon,
      required String label,
      required VoidCallback? onPressed,
      Color? color,
    }) => Expanded(
      child: InkWell(
        key: key,
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Opacity(
            opacity: onPressed == null ? 0.4 : 1,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 22, color: color),
                const SizedBox(height: 2),
                Text(label, style: TextStyle(fontSize: 11, color: color)),
              ],
            ),
          ),
        ),
      ),
    );
    return Material(
      key: const ValueKey('album-selection-bar'),
      elevation: 8,
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            action(
              key: const ValueKey('album-action-download'),
              icon: Icons.file_download_outlined,
              label: '다운로드',
              onPressed: empty || _downloadDone != null
                  ? null
                  : () => _download(selected),
            ),
            if (album.canShare && !album.viewOnly)
              action(
                key: const ValueKey('album-action-share'),
                icon: Icons.share_outlined,
                label: '공유',
                onPressed: empty ? null : () => _share(album),
              ),
            if (canCover)
              action(
                key: const ValueKey('album-action-cover'),
                icon: Icons.image_outlined,
                label: '대표로',
                onPressed: _setCover,
              ),
            if (!album.viewOnly)
              action(
                key: const ValueKey('album-action-delete'),
                icon: Icons.delete_outline,
                label: '삭제',
                color: Colors.redAccent,
                onPressed: empty || !canDeleteAny
                    ? null
                    : () => _deleteSelected(album),
              ),
          ],
        ),
      ),
    );
  }
}

/// 격자의 정사각 썸네일 한 칸 — 영상은 재생 아이콘과 길이, GIF는 "GIF" 표시, 선택 모드에서는 체크 원.
class AlbumItemTile extends StatelessWidget {
  final AlbumItem item;
  final String Function(String url) resolveUrl;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const AlbumItemTile({
    super.key,
    required this.item,
    required this.resolveUrl,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 썸네일이 있으면 그것을, 없는 이미지는 원본을 그린다. 썸네일 없는 영상은 어두운 칸.
    final source = item.thumbnailUrl ?? (item.isImage ? item.fileUrl : null);
    return GestureDetector(
      key: ValueKey('album-item-${item.id}'),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: item.isVideo && source == null
                ? const Color(0xFF2B2B33)
                : theme.colorScheme.surfaceContainerHighest,
            child: source == null
                ? null
                : Image.network(
                    resolveUrl(source),
                    fit: BoxFit.cover,
                    cacheWidth: 300,
                    errorBuilder: (context, error, stack) => Icon(
                      Icons.broken_image_outlined,
                      color: theme.hintColor,
                    ),
                  ),
          ),
          if (item.isVideo) ...[
            Center(
              child: Container(
                width: 34,
                height: 34,
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              ),
            ),
            Positioned(
              right: 4,
              bottom: 4,
              child: _Badge(
                key: ValueKey('album-duration-${item.id}'),
                text: item.durationMs == null
                    ? '영상'
                    : formatAlbumDuration(item.durationMs),
              ),
            ),
          ],
          if (item.isGif)
            const Positioned(left: 4, bottom: 4, child: _Badge(text: 'GIF')),
          if (selected)
            Container(color: theme.colorScheme.primary.withValues(alpha: 0.25)),
          if (selecting)
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                key: ValueKey('album-check-${item.id}'),
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? theme.colorScheme.primary : Colors.black38,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: selected
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  const _Badge({super.key, required this.text});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      text,
      style: const TextStyle(color: Colors.white, fontSize: 10),
    ),
  );
}
