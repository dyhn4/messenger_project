import 'package:flutter/material.dart';

import '../models/album.dart';
import '../models/room.dart';
import '../screens/album_create_dialog.dart';
import '../services/album_controller.dart';
import '../services/session.dart';
import 'album_detail_view.dart';
import 'compact_menu.dart';
import 'filter_dropdown.dart';
import 'panel_filters.dart';
import 'side_panel_header.dart';

/// 앨범 목록 정렬.
enum AlbumSort {
  newest('최신순'),
  oldest('오래된순'),
  title('제목순'),
  mostItems('사진·영상 많은 순');

  final String label;
  const AlbumSort(this.label);

  List<Album> apply(List<Album> albums) {
    final sorted = List.of(albums);
    switch (this) {
      case AlbumSort.newest:
        sorted.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case AlbumSort.oldest:
        sorted.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      case AlbumSort.title:
        sorted.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
      case AlbumSort.mostItems:
        sorted.sort((a, b) => b.itemCount.compareTo(a.itemCount));
    }
    return sorted;
  }
}

/// 모바일에서 대화방의 "앨범 보기" — 그 방으로 걸러진 앨범 목록을 전체 화면으로 연다(PC는 오른쪽 패널로 열린다).
void openAlbumsForRoom(BuildContext context, Session session, Room room) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (routeContext) => Scaffold(
        body: SafeArea(
          child: AlbumsPanel(
            session: session,
            initialRoomId: room.id,
            onClose: () => Navigator.of(routeContext).pop(),
          ),
        ),
      ),
    ),
  );
}

/// 앨범 패널 — 목록(`+ 앨범 만들기`, 참여 대화방 필터, 정렬, 카드 격자)과 앨범 상세([AlbumDetailView])를 오가는 한 칸.
/// PC는 오른쪽 패널, 모바일은 전체 화면이다(side_panels.dart의 `albums`).
class AlbumsPanel extends StatefulWidget {
  final Session session;

  /// 처음에 거를 대화방 — 방 헤더의 "앨범 보기"나 지금 보고 있는 방. 없으면 내 모든 방의 앨범.
  final String? initialRoomId;
  final VoidCallback? onClose;

  const AlbumsPanel({
    super.key,
    required this.session,
    this.initialRoomId,
    this.onClose,
  });

  @override
  State<AlbumsPanel> createState() => _AlbumsPanelState();
}

class _AlbumsPanelState extends State<AlbumsPanel> {
  late String? _roomId = widget.initialRoomId;
  AlbumSort _sort = AlbumSort.newest;
  final _scroll = ScrollController();

  AlbumController get _albums => widget.session.albums;

  @override
  void initState() {
    super.initState();
    // 패널을 새로 열면 늘 목록부터 — 앞서 열어 둔 앨범이 남아 있어도 닫는다(올리던 파일은 계속 올라간다).
    _albums.closeAlbum(notify: false);
    // 화면을 그리는 도중에는 알리지 않도록 한 박자 뒤에 받기 시작한다.
    Future.microtask(() {
      if (mounted) _albums.loadAlbums(roomId: _roomId);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _setRoom(String? roomId) {
    setState(() => _roomId = roomId);
    _albums.loadAlbums(roomId: roomId);
  }

  Future<void> _create() async {
    final room = _roomId == null ? null : widget.session.roomById(_roomId!);
    final created = await showAlbumCreator(
      context,
      session: widget.session,
      room: room,
      lockRoom: room != null,
    );
    if (created != null && mounted) await _albums.openAlbum(created);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _albums,
      builder: (context, _) {
        final inDetail = _albums.album != null || _albums.albumGone;
        return PopScope(
          // 모바일에서 뒤로 가기는 앨범 안에서는 목록으로, 목록에서는 화면 닫기.
          canPop: !inDetail,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && inDetail) _albums.closeAlbum();
          },
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: inDetail
                ? AlbumDetailView(
                    session: widget.session,
                    onClose: widget.onClose,
                  )
                : _buildList(context),
          ),
        );
      },
    );
  }

  Widget _buildList(BuildContext context) {
    final theme = Theme.of(context);
    final albums = _sort.apply(_albums.albums);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SidePanelHeader(title: '앨범', onClose: widget.onClose),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: FilledButton.icon(
            key: const ValueKey('album-create-button'),
            onPressed: _create,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('앨범 만들기'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: RoomFilterButton(
                  session: widget.session,
                  selectedRoomId: _roomId,
                  expand: true,
                  onSelected: _setRoom,
                ),
              ),
              const SizedBox(width: 8),
              _AlbumSortButton(
                sort: _sort,
                onChanged: (s) => setState(() => _sort = s),
              ),
            ],
          ),
        ),
        PanelResultLine(
          summary: Text(
            _albums.listLoaded
                ? '${albums.length}개의 앨범${_albums.listHasMore ? ' 이상' : ''}'
                : '불러오는 중…',
            key: const ValueKey('album-count-line'),
            style: theme.textTheme.bodySmall,
          ),
        ),
        Expanded(child: _buildGrid(context, albums)),
      ],
    );
  }

  Widget _buildGrid(BuildContext context, List<Album> albums) {
    final theme = Theme.of(context);
    if (!_albums.listLoaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_albums.listError != null && albums.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _albums.listError!,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.error),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _albums.loadAlbums(roomId: _roomId),
                child: const Text('다시 시도'),
              ),
            ],
          ),
        ),
      );
    }
    if (albums.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _roomId == null
                ? '아직 앨범이 없습니다.\n앨범 만들기로 사진·영상을 주제별로 모아 보세요.'
                : '이 대화방에는 아직 앨범이 없습니다.\n앨범 만들기로 사진·영상을 주제별로 모아 보세요.',
            key: const ValueKey('album-empty'),
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.hintColor, height: 1.5),
          ),
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 300) _albums.loadMoreAlbums();
        return false;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = (constraints.maxWidth / 170).floor().clamp(2, 5);
          return GridView.builder(
            key: const ValueKey('album-grid'),
            controller: _scroll,
            padding: const EdgeInsets.all(16),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              mainAxisExtent: 196,
            ),
            itemCount: albums.length,
            itemBuilder: (context, i) => AlbumCard(
              album: albums[i],
              resolveUrl: widget.session.resolveUrl,
              onTap: () => _albums.openAlbum(albums[i]),
            ),
          );
        },
      ),
    );
  }
}

/// 앨범 카드 — 대표 이미지, 제목, `사진·영상 N개`, 방 이름, 만든 날짜(yyyy/MM/dd).
class AlbumCard extends StatelessWidget {
  final Album album;
  final String Function(String url) resolveUrl;
  final VoidCallback onTap;
  const AlbumCard({
    super.key,
    required this.album,
    required this.resolveUrl,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final cover = album.coverUrl;
    return InkWell(
      key: ValueKey('album-card-${album.id}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: double.infinity,
                child: ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: cover == null
                      ? Icon(
                          Icons.photo_library_outlined,
                          size: 36,
                          color: hint,
                        )
                      : Image.network(
                          resolveUrl(cover),
                          fit: BoxFit.cover,
                          cacheWidth: 400,
                          errorBuilder: (context, error, stack) => Icon(
                            Icons.broken_image_outlined,
                            size: 32,
                            color: hint,
                          ),
                        ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            album.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          Text(
            '사진·영상 ${album.itemCount}개',
            style: TextStyle(fontSize: 12, color: hint),
          ),
          Text(
            '${album.roomName ?? ''} · ${formatPanelDate(album.createdAt)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: hint),
          ),
        ],
      ),
    );
  }
}

/// 목록 정렬 단추 — 설정 메뉴와 같은 간결한 팝업([CompactMenu]).
class _AlbumSortButton extends StatelessWidget {
  final AlbumSort sort;
  final ValueChanged<AlbumSort> onChanged;
  const _AlbumSortButton({required this.sort, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return PopupMenuButton<AlbumSort>(
      key: const ValueKey('album-sort'),
      tooltip: '정렬',
      position: PopupMenuPosition.under,
      offset: const Offset(0, 4),
      color: CompactMenu.color(context),
      shape: CompactMenu.shape,
      menuPadding: CompactMenu.menuPadding,
      constraints: const BoxConstraints(minWidth: 150, maxWidth: 220),
      initialValue: sort,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final s in AlbumSort.values)
          PopupMenuItem<AlbumSort>(
            key: ValueKey('album-sort-${s.name}'),
            value: s,
            height: CompactMenu.itemHeight,
            padding: CompactMenu.itemPadding,
            child: Row(
              children: [
                Expanded(child: Text(s.label, style: CompactMenu.textStyle)),
                if (s == sort) const Icon(Icons.check, size: 16),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.swap_vert, size: 16, color: hint),
            const SizedBox(width: 2),
            Text(
              sort.label,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: hint),
            ),
          ],
        ),
      ),
    );
  }
}
