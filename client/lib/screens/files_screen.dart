import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/app_user.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../services/session.dart';
import '../widgets/attachment_widgets.dart';
import '../widgets/filter_dropdown.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/pagination.dart';

enum FileCategory { all, image, pdf, document, excel, powerpoint, archive, audio }

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
      final results = await widget.session.api!.fetchAttachments(
        teamId: widget.session.currentTeam!.id,
        roomId: _roomId,
        senderId: _senderId,
        category: _category.apiValue,
      );
      if (!mounted) return;
      setState(() {
        _results = results;
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
                child: Text(
                  m.senderName.isNotEmpty ? m.senderName[0] : '?',
                ),
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
                    style: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(color: Theme.of(context).hintColor),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                '대화방',
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
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
            DownloadableImage(
              session: widget.session,
              url: widget.session.resolveUrl(m.fileUrl ?? ''),
              fileName: m.fileName ?? 'image.png',
              thumbnailUrl: m.thumbnailUrl == null
                  ? null
                  : widget.session.resolveUrl(m.thumbnailUrl!),
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
class _FileResultRow extends StatelessWidget {
  final Session session;
  final Message message;
  final DateFormat timeFormat;
  final String roomName;
  final VoidCallback onTap;
  const _FileResultRow({
    required this.session,
    required this.message,
    required this.timeFormat,
    required this.roomName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isImage = message.type == MessageType.image;
    final placeholderColor = Theme.of(context).colorScheme.surfaceContainerHighest;
    final thumbnail = isImage
        ? Image.network(
            session.resolveUrl(message.thumbnailUrl ?? message.fileUrl ?? ''),
            width: 40,
            height: 40,
            fit: BoxFit.cover,
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

    return InkWell(
      onTap: onTap,
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
                ClipRRect(borderRadius: BorderRadius.circular(6), child: thumbnail),
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
