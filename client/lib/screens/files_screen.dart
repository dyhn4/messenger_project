import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/app_user.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../services/api_client.dart' show favoriteFileKey;
import '../services/session.dart';
import '../widgets/attachment_widgets.dart';
import '../widgets/file_actions.dart';
import '../widgets/hover_toolbar.dart';
import '../widgets/filter_dropdown.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/pagination.dart';
import 'image_viewer_screen.dart';

enum FileCategory {
  all,
  image,
  pdf,
  document,
  excel,
  powerpoint,
  archive,
  audio,
}

extension on FileCategory {
  String get label => switch (this) {
    FileCategory.all => '모든 파일',
    FileCategory.image => '이미지',
    FileCategory.pdf => 'PDF',
    FileCategory.document => '문서',
    FileCategory.excel => '엑셀',
    FileCategory.powerpoint => '파워포인트',
    FileCategory.archive => '압축 파일',
    FileCategory.audio => '오디오',
  };

  IconData get icon => switch (this) {
    FileCategory.all => Icons.insert_drive_file_outlined,
    FileCategory.image => Icons.image_outlined,
    FileCategory.pdf => Icons.picture_as_pdf_outlined,
    FileCategory.document => Icons.description_outlined,
    FileCategory.excel => Icons.grid_on_outlined,
    FileCategory.powerpoint => Icons.slideshow_outlined,
    FileCategory.archive => Icons.folder_zip_outlined,
    FileCategory.audio => Icons.audiotrack_outlined,
  };

  /// server/src/attachments.js의 CATEGORY_MATCHERS 키와 정확히 일치해야 한다.
  String? get apiValue => this == FileCategory.all ? null : name;
}

/// 채팅방에 첨부된 이미지/파일을 한 번에 볼 수 있는 패널. 검색 패널과 같은 틀(헤더+필터+
/// 목록+페이지네이션)을 재사용하지만, 검색어 입력 없이 필터만으로 바로 조회하고, 결과를
/// 클릭하면 검색처럼 실제 채팅창으로 이동하는 대신 이 패널 안에서 뒤로가기가 있는 자체
/// 미리보기("메시지" 화면)로 보여준다.
class FilesScreen extends StatefulWidget {
  final Session session;

  /// 패널을 열 당시 선택돼 있던 방 — 대화방 필터의 시작값으로만 쓰인다(그 뒤로 사용자가
  /// 사이드바에서 다른 방을 선택해도 이 필터는 그대로 유지된다, 검색/멤버 패널과 동일).
  final String? initialRoomId;
  final VoidCallback? onClose;
  const FilesScreen({
    super.key,
    required this.session,
    this.initialRoomId,
    this.onClose,
  });

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  final _timeFormat = DateFormat('yyyy/MM/dd a h:mm');
  final _listScrollController = ScrollController();
  List<Message>? _results;
  bool _loading = false;
  String? _error;
  int _page = 0; // 0-based.

  String? _roomId; // null = 참여 대화방(전체)
  String? _senderId; // null = 모든 멤버
  FileCategory _category = FileCategory.all;

  Message? _preview; // null이면 목록, 있으면 그 첨부의 자체 미리보기("메시지" 화면).

  /// 내가 즐겨찾기한 첨부([favoriteFileKey]) — 별 표시와 "즐겨찾기 먼저" 정렬에 쓴다.
  Set<String> _favorites = const {};

  bool _isFavorite(Message m) =>
      _favorites.contains(favoriteFileKey(m.id, m.fileName));

  /// 즐겨찾기한 것을 앞으로 보낸다. 그 안에서는 서버가 준 순서(최신순)를 그대로 둔다.
  List<Message> _sortFavoritesFirst(List<Message> items) {
    final favorite = <Message>[];
    final rest = <Message>[];
    for (final m in items) {
      (_isFavorite(m) ? favorite : rest).add(m);
    }
    return [...favorite, ...rest];
  }

  /// 별을 눌렀을 때 — 서버에 토글하고, 목록의 별 표시와 순서를 그 결과대로 다시 맞춘다.
  Future<void> _toggleFavorite(Message m) async {
    final actions = _actionsFor(m);
    final on = await actions.toggleFavorite(context);
    if (on == null || !mounted) return;
    final next = {..._favorites};
    final key = favoriteFileKey(m.id, m.fileName);
    on ? next.add(key) : next.remove(key);
    setState(() {
      _favorites = next;
      final results = _results;
      if (results != null) _results = _sortFavoritesFirst(results);
    });
  }

  FileActions _actionsFor(Message m) => FileActions(
    session: widget.session,
    message: m,
    url: widget.session.resolveUrl(m.fileUrl ?? ''),
    fileName: m.fileName ?? (m.type == MessageType.image ? 'image.png' : '파일'),
  );

  @override
  void initState() {
    super.initState();
    _roomId = widget.initialRoomId;
    _load();
  }

  @override
  void dispose() {
    _listScrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = widget.session.api!;
      final results = await api.fetchAttachments(
        teamId: widget.session.currentTeam!.id,
        roomId: _roomId,
        senderId: _senderId,
        category: _category.apiValue,
      );
      // 즐겨찾기한 것을 목록 맨 위로 올리려면 어떤 게 담겨 있는지 알아야 한다. 즐겨찾기를
      // 못 불러와도(예: 일시적 오류) 목록 자체는 보여준다.
      Set<String> favorites = const {};
      try {
        favorites = await api.fetchFavoriteFileKeys();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _favorites = favorites;
        _results = _sortFavoritesFirst(results);
        _page = 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 대화방 필터가 바뀌면 발신자 필터(이전 방 멤버 기준으로 골랐던 값)가 새 범위에 안
  /// 맞을 수 있어 같이 초기화한다.
  void _onRoomSelected(String? roomId) {
    setState(() {
      _roomId = roomId;
      _senderId = null;
    });
    _load();
  }

  Room? get _selectedRoom {
    final id = _roomId;
    if (id == null) return null;
    for (final r in widget.session.rooms) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// 발신자 필터 후보 — 방을 하나 골랐으면 그 방 멤버만, "전체"면 비밀 아닌 내 방들의
  /// 멤버를 모아 보여준다(검색 패널과 달리 조직 전체 사용자 목록은 쓰지 않는다).
  List<AppUser> get _senderChoices {
    final room = _selectedRoom;
    if (room != null) return room.members;
    final byId = <String, AppUser>{};
    for (final r in widget.session.rooms.where((r) => !r.isSecret)) {
      for (final m in r.members) {
        byId[m.id] = m;
      }
    }
    return byId.values.toList();
  }

  String _roomNameFor(Message m) {
    for (final r in widget.session.rooms) {
      if (r.id == m.roomId) return r.displayName(widget.session.userId ?? '');
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _preview == null
              ? _buildListHeader(context)
              : _buildPreviewHeader(context),
          const Divider(height: 1),
          Expanded(
            child: _preview != null
                ? _buildPreview(context, _preview!)
                : _buildListBody(context),
          ),
        ],
      ),
    );
  }

  Widget _buildListHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Text('파일', style: Theme.of(context).textTheme.titleLarge),
          ),
          IconButton(icon: const Icon(Icons.close), onPressed: widget.onClose),
        ],
      ),
    );
  }

  Widget _buildListBody(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: RoomFilterButton(
                  session: widget.session,
                  selectedRoomId: _roomId,
                  expand: true,
                  onSelected: _onRoomSelected,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SenderFilterButton(
                  users: _senderChoices,
                  selectedSenderId: _senderId,
                  onSelected: (v) {
                    setState(() => _senderId = v);
                    _load();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _CategoryFilterButton(
                  category: _category,
                  onSelected: (v) {
                    setState(() => _category = v);
                    _load();
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(child: _buildResults(context)),
      ],
    );
  }

  Widget _buildResults(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(_error!));
    final results = _results ?? const <Message>[];
    if (results.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('첨부된 파일이 없습니다.'),
        ),
      );
    }

    final totalPages = (results.length / paginationPageSize).ceil();
    final page = _page.clamp(0, totalPages - 1);
    final pageItems = results
        .skip(page * paginationPageSize)
        .take(paginationPageSize)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text(
            '"${results.length}"개가 로딩되었습니다.',
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: MutedScrollbar(
            controller: _listScrollController,
            child: ListView.separated(
              controller: _listScrollController,
              itemCount: pageItems.length,
              // 오른쪽 끝에 겹치는 스크롤바 아래로 선이 파고들지 않도록 그만큼 짧게 그린다.
              separatorBuilder: (_, _) => const Padding(
                padding: EdgeInsets.only(right: 12),
                child: Divider(height: 1),
              ),
              itemBuilder: (context, i) => _FileResultRow(
                session: widget.session,
                message: pageItems[i],
                timeFormat: _timeFormat,
                roomName: _roomNameFor(pageItems[i]),
                favorited: _isFavorite(pageItems[i]),
                actions: _actionsFor(pageItems[i]),
                onToggleFavorite: () => _toggleFavorite(pageItems[i]),
                onTap: () => setState(() => _preview = pageItems[i]),
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        Pagination(
          currentPage: page,
          totalPages: totalPages,
          onPageSelected: (p) => setState(() => _page = p),
        ),
      ],
    );
  }

  Widget _buildPreviewHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 8, 12),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() => _preview = null),
          ),
          Expanded(
            child: Text('메시지', style: Theme.of(context).textTheme.titleLarge),
          ),
          IconButton(icon: const Icon(Icons.close), onPressed: widget.onClose),
        ],
      ),
    );
  }

  /// "메시지" 화면에서 사진을 누르면 — 지금 목록(걸어 둔 방·보낸 사람·형식 필터 그대로)의 사진을
  /// 시간 순서대로 모아, 그 사진부터 앞뒤 메시지의 사진까지 이어서 넘겨 본다. 목록은 서버가
  /// 한꺼번에 준 것이라 채팅방에 아직 안 불러온 오래된 사진도 들어 있다.
  void _openViewer(Message m) {
    final results = _results ?? const <Message>[];
    final order = {for (final (i, r) in results.indexed) r: i};
    final photos = [
      for (final r in results)
        if (r.type == MessageType.image) r,
    ];
    // 목록은 최신순(+즐겨찾기 먼저)이라 시간 순서로 다시 줄 세운다 — 같은 시각(한 메시지의
    // 여러 장)은 목록 순서 그대로.
    photos.sort((a, b) {
      final byTime = a.createdAt.compareTo(b.createdAt);
      return byTime != 0 ? byTime : order[a]!.compareTo(order[b]!);
    });
    // 한 메시지의 여러 장이 목록에서 줄마다 따로 오므로(메시지 id가 같다) 파일 주소까지 붙여 구분한다.
    String idOf(Message x) => '${x.id}|${x.fileUrl}';
    var images = [
      for (final x in photos)
        ViewerImage(
          id: idOf(x),
          message: x,
          url: widget.session.resolveUrl(x.fileUrl ?? ''),
          fileName: x.fileName ?? 'image.png',
          fileSize: x.fileSize,
        ),
    ];
    var start = images.indexWhere((v) => v.id == idOf(m));
    if (start < 0) {
      images = [
        ViewerImage(
          id: idOf(m),
          message: m,
          url: widget.session.resolveUrl(m.fileUrl ?? ''),
          fileName: m.fileName ?? 'image.png',
          fileSize: m.fileSize,
        ),
      ];
      start = 0;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ImageViewerScreen(
          images: images,
          initialIndex: start,
          session: widget.session,
          message: m,
          // 댓글 패널은 그 사진의 방에서 연다(방을 모르면 댓글 버튼만 안 보인다).
          room: widget.session.rooms.where((r) => r.id == m.roomId).firstOrNull,
        ),
      ),
    );
  }

  Widget _buildPreview(BuildContext context, Message m) {
    final roomName = _roomNameFor(m);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 16,
                child: Text(m.senderName.isNotEmpty ? m.senderName[0] : '?'),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.senderName,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    _timeFormat.format(m.createdAt),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('대화방', style: TextStyle(color: Theme.of(context).hintColor)),
              const SizedBox(width: 4),
              Text(roomName),
            ],
          ),
          const SizedBox(height: 12),
          if (m.text != null && m.text!.isNotEmpty) ...[
            Text(m.text!),
            const SizedBox(height: 8),
          ],
          if (m.type == MessageType.image)
            // 마우스를 올리면 목록 줄과 같은 즐겨찾기 · 더보기가 뜨고, 누르면 지금 목록의 앞뒤
            // 사진까지 넘겨 보는 뷰어가 열린다.
            DownloadableImage(
              session: widget.session,
              url: widget.session.resolveUrl(m.fileUrl ?? ''),
              fileName: m.fileName ?? 'image.png',
              thumbnailUrl: m.thumbnailUrl == null
                  ? null
                  : widget.session.resolveUrl(m.thumbnailUrl!),
              actions: _actionsFor(m),
              favorited: _isFavorite(m),
              onToggleFavorite: () => _toggleFavorite(m),
              onOpen: () => _openViewer(m),
            )
          else
            DownloadableFile(
              session: widget.session,
              url: widget.session.resolveUrl(m.fileUrl ?? ''),
              fileName: m.fileName ?? '파일',
            ),
        ],
      ),
    );
  }
}

/// "모든 멤버" 필터 — 검색 패널과 달리 조직 전체가 아니라 현재 범위(선택된 방 또는 내
/// 방 전체)의 멤버로만 좁힌다.
class _SenderFilterButton extends StatelessWidget {
  final List<AppUser> users;
  final String? selectedSenderId;
  final ValueChanged<String?> onSelected;
  const _SenderFilterButton({
    required this.users,
    required this.selectedSenderId,
    required this.onSelected,
  });

  String get _label {
    final id = selectedSenderId;
    if (id == null) return '모든 멤버';
    for (final u in users) {
      if (u.id == id) return u.name;
    }
    return '모든 멤버';
  }

  @override
  Widget build(BuildContext context) {
    return FilterDropdownButton(
      label: _label,
      expand: true,
      panelBuilder: (close) => FilterPanelShell(
        width: 220,
        child: _SenderFilterPanel(
          users: users,
          selectedSenderId: selectedSenderId,
          onSelected: (id) {
            onSelected(id);
            close();
          },
        ),
      ),
    );
  }
}

class _SenderFilterPanel extends StatefulWidget {
  final List<AppUser> users;
  final String? selectedSenderId;
  final ValueChanged<String?> onSelected;
  const _SenderFilterPanel({
    required this.users,
    required this.selectedSenderId,
    required this.onSelected,
  });

  @override
  State<_SenderFilterPanel> createState() => _SenderFilterPanelState();
}

class _SenderFilterPanelState extends State<_SenderFilterPanel> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final list =
        widget.users
            .where(
              (u) =>
                  _filter.isEmpty ||
                  u.name.toLowerCase().contains(_filter.toLowerCase()),
            )
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        filterSearchBox((v) => setState(() => _filter = v)),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                dense: true,
                title: const Text('모든 멤버'),
                trailing: widget.selectedSenderId == null
                    ? const Icon(Icons.check, size: 18)
                    : null,
                onTap: () => widget.onSelected(null),
              ),
              const Divider(height: 1),
              for (final u in list)
                ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 12,
                    child: Text(u.name.isNotEmpty ? u.name[0] : '?'),
                  ),
                  title: Text(
                    u.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: widget.selectedSenderId == u.id
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  onTap: () => widget.onSelected(u.id),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "모든 파일" 필터 — 이미지/PDF/문서/엑셀/파워포인트/압축 파일/오디오 중 하나로 좁힌다.
class _CategoryFilterButton extends StatelessWidget {
  final FileCategory category;
  final ValueChanged<FileCategory> onSelected;
  const _CategoryFilterButton({
    required this.category,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return FilterDropdownButton(
      label: category.label,
      expand: true,
      panelBuilder: (close) => FilterPanelShell(
        width: 200,
        child: _CategoryFilterPanel(
          selected: category,
          onSelected: (c) {
            onSelected(c);
            close();
          },
        ),
      ),
    );
  }
}

class _CategoryFilterPanel extends StatefulWidget {
  final FileCategory selected;
  final ValueChanged<FileCategory> onSelected;
  const _CategoryFilterPanel({
    required this.selected,
    required this.onSelected,
  });

  @override
  State<_CategoryFilterPanel> createState() => _CategoryFilterPanelState();
}

class _CategoryFilterPanelState extends State<_CategoryFilterPanel> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final list = FileCategory.values.where(
      (c) =>
          _filter.isEmpty ||
          c.label.toLowerCase().contains(_filter.toLowerCase()),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        filterSearchBox((v) => setState(() => _filter = v)),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final c in list)
                ListTile(
                  dense: true,
                  leading: Icon(c.icon, size: 18),
                  title: Text(c.label),
                  trailing: widget.selected == c
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  onTap: () => widget.onSelected(c),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 파일 목록 한 줄: 대화방 이름(라벨) + (썸네일/아이콘 + 파일명 + 보낸사람 · 시간).
/// 검색 결과 행과 같은 스타일(카드 테두리 없이 ListView.separated의 Divider로만 구분).
/// 목록 한 줄 — 마우스를 올리면 오른쪽 위에 툴바(즐겨찾기 별 + 더보기)가 뜬다. 즐겨찾기한
/// 파일은 별이 노랗게 차고, 목록에서도 맨 위로 올라간다(_FilesScreenState._sortFavoritesFirst).
class _FileResultRow extends StatefulWidget {
  final Session session;
  final Message message;
  final DateFormat timeFormat;
  final String roomName;
  final bool favorited;
  final FileActions actions;
  final VoidCallback onToggleFavorite;
  final VoidCallback onTap;
  const _FileResultRow({
    required this.session,
    required this.message,
    required this.timeFormat,
    required this.roomName,
    required this.favorited,
    required this.actions,
    required this.onToggleFavorite,
    required this.onTap,
  });

  @override
  State<_FileResultRow> createState() => _FileResultRowState();
}

class _FileResultRowState extends State<_FileResultRow> {
  bool _hovering = false;

  /// 더보기 메뉴가 떠 있는 동안에는 툴바를 계속 보여준다 — 마우스를 메뉴로 옮기면 줄 밖으로
  /// 나간 것으로 잡혀서, 안 붙잡으면 툴바가 사라지며 메뉴까지 닫힌다.
  bool _menuOpen = false;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final message = widget.message;
    final isImage = message.type == MessageType.image;
    final placeholderColor = Theme.of(
      context,
    ).colorScheme.surfaceContainerHighest;
    final thumbnail = isImage
        ? Image.network(
            session.resolveUrl(message.thumbnailUrl ?? message.fileUrl ?? ''),
            width: 40,
            height: 40,
            // 채팅 썸네일과 같은 규칙 — 자르지 않고 통째로 보여준다.
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => Container(
              width: 40,
              height: 40,
              color: placeholderColor,
              child: const Icon(Icons.broken_image, size: 18),
            ),
          )
        : Container(
            width: 40,
            height: 40,
            color: placeholderColor,
            child: const Icon(Icons.insert_drive_file_outlined, size: 20),
          );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Stack(
        children: [
          _buildRow(context, thumbnail: thumbnail, isImage: isImage),
          // 즐겨찾기한 줄은 마우스를 올리지 않아도 별이 보여야 어떤 게 담긴 건지 알 수 있다.
          if (_hovering || _menuOpen || widget.favorited)
            Positioned(
              right: 16,
              top: 8,
              child: HoverToolbar(
                children: [
                  HoverToolbarButton(
                    icon: widget.favorited ? Icons.star : Icons.star_border,
                    color: widget.favorited ? Colors.amber : null,
                    tooltip: widget.favorited ? '즐겨찾기 빼기' : '즐겨찾기',
                    onPressed: widget.onToggleFavorite,
                  ),
                  if (_hovering || _menuOpen)
                    HoverToolbarButton(
                      icon: Icons.more_vert,
                      tooltip: '더보기',
                      onMenuOpenChanged: (v) => setState(() => _menuOpen = v),
                      menuChildren: fileActionMenuItems(
                        context,
                        widget.actions,
                        isImage: isImage,
                        favorited: widget.favorited,
                        onToggleFavorite: widget.onToggleFavorite,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRow(
    BuildContext context, {
    required Widget thumbnail,
    required bool isImage,
  }) {
    final message = widget.message;
    final timeFormat = widget.timeFormat;
    final roomName = widget.roomName;
    return InkWell(
      onTap: widget.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              roomName,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: thumbnail,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        message.fileName ?? (isImage ? '이미지' : '파일'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            message.senderName,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            timeFormat.format(message.createdAt),
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: Theme.of(context).hintColor),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
