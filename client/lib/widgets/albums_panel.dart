import 'dart:io';

import 'package:flutter/material.dart';

import '../models/album.dart';
import '../models/room.dart';
import '../screens/album_create_dialog.dart';
import '../services/album_controller.dart';
import '../services/session.dart';
import 'album_actions.dart';
import 'album_detail_view.dart';
import 'compact_menu.dart';
import 'compact_menu_anchor.dart';
import 'filter_dropdown.dart';
import 'home_shell_scope.dart';
import 'panel_filters.dart';
import 'side_panel_header.dart';

/// 앨범 목록 정렬 — 기본은 잔디처럼 "업데이트 순"(사진·영상을 올리거나 고친 시각).
enum AlbumSort {
  updated('업데이트 순'),
  newest('최신순'),
  oldest('오래된순'),
  title('제목순'),
  mostItems('사진·영상 많은 순');

  final String label;
  const AlbumSort(this.label);

  List<Album> apply(List<Album> albums) {
    final sorted = List.of(albums);
    switch (this) {
      case AlbumSort.updated:
        sorted.sort((a, b) {
          final byUpdate = b.updatedAt.compareTo(a.updatedAt);
          return byUpdate != 0 ? byUpdate : b.createdAt.compareTo(a.createdAt);
        });
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

/// 공유된 앨범 메시지의 "앨범 보기" — PC는 오른쪽 앨범 패널에 그 앨범을 펼치고(패널이 닫혀 있으면 열면서), 모바일은 앨범
/// 화면을 전체 화면으로 얹는다. 앨범 방의 멤버가 아니어도 그 메시지를 볼 수 있으면 서버가 보기 전용으로 보여 준다.
void openSharedAlbum(BuildContext context, Session session, String albumId) {
  final albums = session.albums;
  final shell = HomeShellScope.maybeOf(context);
  if (shell != null) {
    if (shell.openPanelKey == 'albums') {
      albums.openAlbumById(albumId);
    } else {
      albums.openWhenPanelOpens(albumId);
      shell.togglePanel('albums');
    }
    return;
  }
  albums.openWhenPanelOpens(albumId);
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (routeContext) => Scaffold(
        body: SafeArea(
          child: AlbumsPanel(
            session: session,
            onClose: () => Navigator.of(routeContext).pop(),
          ),
        ),
      ),
    ),
  );
}

/// 앨범 목록 보기 방식 — 격자(카드)와 목록(한 줄씩).
enum AlbumListView { grid, list }

/// 앨범 패널 — 목록(`+ 앨범 생성`, 참여 대화방 필터, 격자/목록 전환, 정렬, 카드)과 앨범 상세([AlbumDetailView])를 오가는 한 칸.
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
  AlbumSort _sort = AlbumSort.updated;
  AlbumListView _view = AlbumListView.grid;
  final _scroll = ScrollController();

  AlbumController get _albums => widget.session.albums;

  @override
  void initState() {
    super.initState();
    // 패널을 새로 열면 늘 목록부터 — 앞서 열어 둔 앨범이 남아 있어도 닫는다(올리던 파일은 계속 올라간다). 단, 메시지의
    // "앨범 보기"로 열었으면 그 앨범을 바로 펼친다(openSharedAlbum).
    final pending = _albums.takePendingAlbum();
    _albums.closeAlbum(notify: false);
    // 화면을 그리는 도중에는 알리지 않도록 한 박자 뒤에 받기 시작한다.
    Future.microtask(() {
      if (!mounted) return;
      _albums.loadAlbums(roomId: _roomId);
      if (pending != null) _albums.openAlbumById(pending);
    });
  }

  Future<void> _onAction(Album album, AlbumAction action) async {
    final session = widget.session;
    switch (action) {
      case AlbumAction.download:
        await downloadWholeAlbum(context, session, album);
      case AlbumAction.share:
        await shareAlbumToRoom(context, session, album);
      case AlbumAction.edit:
        await editAlbumWithDialog(context, session, album);
      case AlbumAction.delete:
        await confirmAndDeleteAlbum(context, session, album);
    }
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
            label: const Text('앨범 생성'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: RoomFilterButton(
            session: widget.session,
            selectedRoomId: _roomId,
            expand: true,
            onSelected: _setRoom,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
          child: Row(
            children: [
              _ViewToggle(
                view: _view,
                onChanged: (v) => setState(() => _view = v),
              ),
              const Spacer(),
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
                ? '아직 앨범이 없습니다.\n앨범 생성으로 사진·영상을 주제별로 모아 보세요.'
                : '이 대화방에는 아직 앨범이 없습니다.\n앨범 생성으로 사진·영상을 주제별로 모아 보세요.',
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
      child: _view == AlbumListView.list
          ? ListView.builder(
              key: const ValueKey('album-list'),
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
              itemCount: albums.length,
              itemBuilder: (context, i) => AlbumListRow(
                album: albums[i],
                resolveUrl: widget.session.resolveUrl,
                onTap: () => _albums.openAlbum(albums[i]),
                onAction: (a) => _onAction(albums[i], a),
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final columns = (constraints.maxWidth / 170).floor().clamp(
                  2,
                  5,
                );
                return GridView.builder(
                  key: const ValueKey('album-grid'),
                  controller: _scroll,
                  padding: const EdgeInsets.all(16),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 12,
                    mainAxisExtent: 186,
                  ),
                  itemCount: albums.length,
                  itemBuilder: (context, i) => AlbumCard(
                    album: albums[i],
                    resolveUrl: widget.session.resolveUrl,
                    onTap: () => _albums.openAlbum(albums[i]),
                    onAction: (a) => _onAction(albums[i], a),
                  ),
                );
              },
            ),
    );
  }
}

/// 휴대폰(안드로이드·iOS)인지 — 마우스 올리기가 없어서 카드의 ⋯ 단추를 늘 보여 준다.
bool get _touchPlatform => Platform.isAndroid || Platform.isIOS;

/// 앨범 카드 — 대표 이미지(왼쪽 위에 사진·영상 개수), 아래에 제목과 방 이름·만든 날짜(yyyy/MM/dd). PC는 마우스를
/// 올리면 오른쪽 위에 ⋯ 단추가 뜨고(모바일은 늘 보인다), 누르면 전체 다운로드·앨범 공유·앨범 수정·앨범 삭제 중 내가
/// 할 수 있는 것만 나온다.
class AlbumCard extends StatefulWidget {
  final Album album;
  final String Function(String url) resolveUrl;
  final VoidCallback onTap;

  /// ⋯ 메뉴에서 고른 동작 — 없으면 ⋯ 단추가 없다.
  final ValueChanged<AlbumAction>? onAction;

  /// ⋯ 단추를 마우스를 올리지 않아도 늘 보일지 — 기본은 휴대폰에서만.
  final bool? alwaysShowMenu;

  const AlbumCard({
    super.key,
    required this.album,
    required this.resolveUrl,
    required this.onTap,
    this.onAction,
    this.alwaysShowMenu,
  });

  @override
  State<AlbumCard> createState() => _AlbumCardState();
}

class _AlbumCardState extends State<AlbumCard> {
  bool _hovering = false;
  bool _menuOpen = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final album = widget.album;
    final showMenu =
        widget.onAction != null &&
        (_hovering || _menuOpen || (widget.alwaysShowMenu ?? _touchPlatform));
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: InkWell(
        key: ValueKey('album-card-${album.id}'),
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: _AlbumCover(
                      album: album,
                      resolveUrl: widget.resolveUrl,
                      iconSize: 36,
                    ),
                  ),
                  Positioned(
                    left: 8,
                    top: 8,
                    child: _CountBadge(
                      key: ValueKey('album-count-${album.id}'),
                      count: album.itemCount,
                    ),
                  ),
                  if (showMenu)
                    Positioned(
                      right: 6,
                      top: 6,
                      child: _AlbumMoreButton(
                        album: album,
                        onOpened: () => setState(() => _menuOpen = true),
                        onClosed: () => setState(() => _menuOpen = false),
                        onSelected: (a) {
                          setState(() => _menuOpen = false);
                          widget.onAction?.call(a);
                        },
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 7),
            Text(
              album.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(height: 1),
            Text(
              '${album.roomName ?? ''} · ${formatPanelDate(album.createdAt)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: hint),
            ),
          ],
        ),
      ),
    );
  }
}

/// 목록 보기의 한 줄 — 작은 대표 이미지, 제목, `사진·영상 N개 · 방 이름 · 날짜`, 오른쪽 ⋯(PC는 마우스를 올렸을 때).
class AlbumListRow extends StatefulWidget {
  final Album album;
  final String Function(String url) resolveUrl;
  final VoidCallback onTap;
  final ValueChanged<AlbumAction>? onAction;
  final bool? alwaysShowMenu;

  const AlbumListRow({
    super.key,
    required this.album,
    required this.resolveUrl,
    required this.onTap,
    this.onAction,
    this.alwaysShowMenu,
  });

  @override
  State<AlbumListRow> createState() => _AlbumListRowState();
}

class _AlbumListRowState extends State<AlbumListRow> {
  bool _hovering = false;
  bool _menuOpen = false;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final album = widget.album;
    final showMenu =
        widget.onAction != null &&
        (_hovering || _menuOpen || (widget.alwaysShowMenu ?? _touchPlatform));
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: InkWell(
        key: ValueKey('album-row-${album.id}'),
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 52,
                  height: 52,
                  child: _AlbumCover(
                    album: album,
                    resolveUrl: widget.resolveUrl,
                    iconSize: 22,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      album.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '사진·영상 ${album.itemCount}개 · ${album.roomName ?? ''} · ${formatPanelDate(album.createdAt)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: hint),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 32,
                child: showMenu
                    ? _AlbumMoreButton(
                        album: album,
                        flat: true,
                        onOpened: () => setState(() => _menuOpen = true),
                        onClosed: () => setState(() => _menuOpen = false),
                        onSelected: (a) {
                          setState(() => _menuOpen = false);
                          widget.onAction?.call(a);
                        },
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 대표 이미지(없으면 앨범 아이콘) — 카드·목록 줄 공용.
class _AlbumCover extends StatelessWidget {
  final Album album;
  final String Function(String url) resolveUrl;
  final double iconSize;
  const _AlbumCover({
    required this.album,
    required this.resolveUrl,
    required this.iconSize,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final cover = album.coverUrl;
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: cover == null
          ? Icon(Icons.photo_library_outlined, size: iconSize, color: hint)
          : Image.network(
              resolveUrl(cover),
              fit: BoxFit.cover,
              cacheWidth: 400,
              errorBuilder: (context, error, stack) => Icon(
                Icons.broken_image_outlined,
                size: iconSize - 4,
                color: hint,
              ),
            ),
    );
  }
}

/// 대표 이미지 왼쪽 위의 개수 표시 — 사진 아이콘 + 사진·영상 개수.
class _CountBadge extends StatelessWidget {
  final int count;
  const _CountBadge({super.key, required this.count});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(6, 2, 7, 2),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.photo_outlined, size: 12, color: Colors.white),
        const SizedBox(width: 3),
        Text(
          '$count',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

/// 카드의 ⋯ 단추와 그 메뉴 — 할 수 있는 동작만([albumActionsFor]). [flat]이면 목록 줄처럼 바탕 없는 아이콘.
class _AlbumMoreButton extends StatelessWidget {
  final Album album;
  final bool flat;
  final VoidCallback onOpened;
  final VoidCallback onClosed;
  final ValueChanged<AlbumAction> onSelected;

  const _AlbumMoreButton({
    required this.album,
    this.flat = false,
    required this.onOpened,
    required this.onClosed,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final icon = Icon(
      Icons.more_horiz,
      size: 18,
      color: flat ? theme.hintColor : (dark ? Colors.white : Colors.black87),
    );
    return PopupMenuButton<AlbumAction>(
      key: ValueKey('album-card-more-${album.id}'),
      tooltip: '더보기',
      position: PopupMenuPosition.under,
      offset: const Offset(0, 4),
      color: CompactMenu.color(context),
      shape: CompactMenu.shape,
      menuPadding: CompactMenu.menuPadding,
      constraints: const BoxConstraints(minWidth: 160, maxWidth: 240),
      onOpened: onOpened,
      onCanceled: onClosed,
      onSelected: onSelected,
      itemBuilder: (context) => albumActionMenuItems(context, album),
      child: flat
          ? Padding(padding: const EdgeInsets.all(6), child: icon)
          : Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: dark ? const Color(0xE0303236) : Colors.white,
                borderRadius: BorderRadius.circular(6),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 4,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
              child: icon,
            ),
    );
  }
}

/// 격자/목록 보기 전환 — 아이콘 두 개, 지금 보기는 강조색.
class _ViewToggle extends StatelessWidget {
  final AlbumListView view;
  final ValueChanged<AlbumListView> onChanged;
  const _ViewToggle({required this.view, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget button(AlbumListView v, IconData icon, String tooltip) {
      final selected = v == view;
      return IconButton(
        key: ValueKey('album-view-${v.name}'),
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        isSelected: selected,
        iconSize: 20,
        color: selected ? theme.colorScheme.primary : theme.hintColor,
        onPressed: selected ? null : () => onChanged(v),
        icon: Icon(
          icon,
          color: selected ? theme.colorScheme.primary : theme.hintColor,
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        button(AlbumListView.grid, Icons.grid_view_rounded, '격자로 보기'),
        button(AlbumListView.list, Icons.view_list_rounded, '목록으로 보기'),
      ],
    );
  }
}

/// 목록 정렬 단추 — 누르면 메시지 예약 패널의 정렬 메뉴와 같은 드롭다운([CompactMenuAnchor])이 단추 오른쪽 끝에 맞춰
/// 바로 뜬다.
class _AlbumSortButton extends StatelessWidget {
  final AlbumSort sort;
  final ValueChanged<AlbumSort> onChanged;
  const _AlbumSortButton({required this.sort, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return CompactMenuAnchor<AlbumSort>(
      alignEnd: true,
      selected: sort,
      onSelected: onChanged,
      entries: [
        for (final s in AlbumSort.values)
          CompactMenuOption(
            key: ValueKey('album-sort-${s.name}'),
            value: s,
            label: s.label,
          ),
      ],
      builder: (context, open, toggle) => Semantics(
        expanded: open,
        child: Tooltip(
          message: '정렬',
          child: InkWell(
            key: const ValueKey('album-sort'),
            onTap: toggle,
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
          ),
        ),
      ),
    );
  }
}
