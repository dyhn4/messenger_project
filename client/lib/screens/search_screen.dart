import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../services/api_client.dart';
import '../services/session.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/pagination.dart';
import 'chat_screen.dart';

enum SearchPeriod { week, month, threeMonths, year, all, custom }

extension on SearchPeriod {
  String get label => switch (this) {
    SearchPeriod.week => '1주일',
    SearchPeriod.month => '1개월',
    SearchPeriod.threeMonths => '3개월',
    SearchPeriod.year => '1년 (기본)',
    SearchPeriod.all => '기간 설정 안 함',
    SearchPeriod.custom => '직접 설정',
  };
}

class SearchScreen extends StatefulWidget {
  final Session session;
  final bool asDialog;
  final bool asPanel;
  final VoidCallback? onClose;

  /// room과 함께, 검색 결과로 클릭한 메시지 id도 같이 넘겨서 그 말풍선으로 스크롤+하이라이트할 수 있게 한다.
  final void Function(Room room, String highlightMessageId)? onOpenRoom;
  const SearchScreen({
    super.key,
    required this.session,
    this.asDialog = false,
    this.asPanel = false,
    this.onClose,
    this.onOpenRoom,
  });

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _query = TextEditingController();
  final _timeFormat = DateFormat('yyyy/MM/dd a h:mm');
  final _listScrollController = ScrollController();
  List<SearchResult>? _results;
  bool _loading = false;
  String? _error;
  int _page = 0; // 0-based.

  List<AppUser>? _users;
  String? _roomId; // null = 참여한 대화방(전체)
  String? _senderId; // null = 모든 멤버
  SearchPeriod _period = SearchPeriod.year;
  DateTimeRange? _customRange;
  bool _newestFirst = true;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    try {
      final users = await widget.session.api!.fetchUsers();
      if (!mounted) return;
      setState(() => _users = users);
    } catch (_) {
      // 멤버 필터는 부가 기능이라 실패해도 조용히 무시한다.
    }
  }

  DateTime? get _since => switch (_period) {
    SearchPeriod.week => DateTime.now().subtract(const Duration(days: 7)),
    SearchPeriod.month => DateTime.now().subtract(const Duration(days: 30)),
    SearchPeriod.threeMonths => DateTime.now().subtract(
      const Duration(days: 90),
    ),
    SearchPeriod.year => DateTime.now().subtract(const Duration(days: 365)),
    SearchPeriod.all => null,
    SearchPeriod.custom => _customRange?.start,
  };

  DateTime? get _until =>
      _period == SearchPeriod.custom ? _customRange?.end : null;

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) {
      setState(() => _results = null);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await widget.session.api!.search(
        q,
        roomId: _roomId,
        senderId: _senderId,
        since: _since,
        until: _until,
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

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
      initialDateRange: _customRange,
    );
    if (range == null) return;
    setState(() {
      _period = SearchPeriod.custom;
      _customRange = range;
    });
    if (_query.text.trim().isNotEmpty) _search();
  }

  void _onPeriodSelected(SearchPeriod? period) {
    if (period == null) return;
    if (period == SearchPeriod.custom) {
      _pickCustomRange();
      return;
    }
    setState(() => _period = period);
    if (_query.text.trim().isNotEmpty) _search();
  }

  void _openResult(SearchResult result) {
    Room? room;
    for (final r in widget.session.rooms) {
      if (r.id == result.roomId) room = r;
    }
    if (room == null) return;
    if (widget.asPanel && widget.onOpenRoom != null) {
      widget.onOpenRoom!(room, result.id);
      return;
    }
    if (widget.asDialog) Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          session: widget.session,
          room: room!,
          highlightMessageId: result.id,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _query.dispose();
    _listScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 검색창/필터는 양옆에 여백을 두지만, 결과 목록은 여백 없이 패널 가장자리(스크롤바가
    // 붙는 오른쪽 끝, 왼쪽 구분선)까지 꽉 채운다 — _buildResults가 알아서 자기 안에서
    // 필요한 여백(예: "결과 N건" 줄)을 처리한다.
    final controls = Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _query,
            autofocus: true,
            decoration: InputDecoration(
              hintText: '메시지 검색',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.search),
                onPressed: _search,
              ),
            ),
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              // 참여한 대화방만 창 크기에 따라 늘었다 줄었다 한다. 모든 멤버/기간은
              // 항상 원래 크기 그대로 보이도록 고정 폭을 쓴다.
              Expanded(
                child: _RoomFilterButton(
                  session: widget.session,
                  selectedRoomId: _roomId,
                  expand: true,
                  onSelected: (value) {
                    setState(() => _roomId = value);
                    if (_query.text.trim().isNotEmpty) _search();
                  },
                ),
              ),
              const SizedBox(width: 8),
              _MemberFilterButton(
                users: _users,
                selectedSenderId: _senderId,
                onSelected: (value) {
                  setState(() => _senderId = value);
                  if (_query.text.trim().isNotEmpty) _search();
                },
              ),
              const SizedBox(width: 8),
              _PeriodFilterButton(
                period: _period,
                onSelected: _onPeriodSelected,
              ),
            ],
          ),
        ],
      ),
    );
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        controls,
        const SizedBox(height: 12),
        Expanded(child: _buildResults(context)),
      ],
    );

    if (widget.asPanel) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '검색',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: body),
          ],
        ),
      );
    }
    if (widget.asDialog) {
      return FloatingDialog(
        title: '검색',
        maxWidth: 640,
        maxHeight: 700,
        child: body,
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('검색')),
      body: body,
    );
  }

  Widget _buildResults(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(_error!));
    if (_results == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('내가 속한 모든 방을 대상으로 검색합니다.'),
        ),
      );
    }
    if (_results!.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('검색 결과가 없습니다.'),
        ),
      );
    }

    final sorted = [..._results!]
      ..sort(
        (a, b) => _newestFirst
            ? b.createdAt.compareTo(a.createdAt)
            : a.createdAt.compareTo(b.createdAt),
      );

    final totalPages = (sorted.length / paginationPageSize).ceil();
    final page = _page.clamp(0, totalPages - 1);
    final pageItems = sorted
        .skip(page * paginationPageSize)
        .take(paginationPageSize)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '결과 ${sorted.length}건',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              _SortButton(
                newestFirst: _newestFirst,
                onChanged: (v) => setState(() {
                  _newestFirst = v;
                  _page = 0;
                }),
              ),
            ],
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
              itemBuilder: (context, i) => _SearchResultRow(
                result: pageItems[i],
                query: _query.text.trim(),
                timeFormat: _timeFormat,
                onTap: () => _openResult(pageItems[i]),
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
}

/// "결과 N건" 옆 정렬 선택(최신 순/과거 순).
class _SortButton extends StatelessWidget {
  final bool newestFirst;
  final ValueChanged<bool> onChanged;
  const _SortButton({required this.newestFirst, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<bool>(
      initialValue: newestFirst,
      onSelected: onChanged,
      itemBuilder: (context) => [
        CheckedPopupMenuItem(
          value: true,
          checked: newestFirst,
          child: const Text('최신 순'),
        ),
        CheckedPopupMenuItem(
          value: false,
          checked: !newestFirst,
          child: const Text('과거 순'),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.swap_vert, size: 16, color: Theme.of(context).hintColor),
            const SizedBox(width: 2),
            Text(
              newestFirst ? '최신 순' : '과거 순',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).hintColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 검색 결과 한 건: 방 이름(라벨) + (아바타 + 보낸사람 · 시간) + 내용. 카드 테두리 없이
/// ListView.separated의 Divider로만 결과끼리 구분한다. 내용 중 검색어는 형광펜으로
/// 칠한 것처럼 하이라이트한다.
class _SearchResultRow extends StatelessWidget {
  final SearchResult result;
  final String query;
  final DateFormat timeFormat;
  final VoidCallback onTap;
  const _SearchResultRow({
    required this.result,
    required this.query,
    required this.timeFormat,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.roomName ?? '',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 14,
                  child: Text(
                    result.senderName.isNotEmpty ? result.senderName[0] : '?',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            result.senderName,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            timeFormat.format(result.createdAt),
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: Theme.of(context).hintColor),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      _highlighted(
                        context,
                        result.text ?? result.fileName ?? '(파일)',
                        query,
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

  Widget _highlighted(BuildContext context, String text, String query) {
    if (query.isEmpty) return Text(text);
    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (true) {
      final idx = lowerText.indexOf(lowerQuery, start);
      if (idx < 0) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (idx > start) spans.add(TextSpan(text: text.substring(start, idx)));
      spans.add(
        TextSpan(
          text: text.substring(idx, idx + query.length),
          style: const TextStyle(
            backgroundColor: Color(0xFFFFF59D),
            fontWeight: FontWeight.bold,
          ),
        ),
      );
      start = idx + query.length;
    }
    return RichText(
      text: TextSpan(
        style: DefaultTextStyle.of(context).style,
        children: spans,
      ),
    );
  }
}

IconData _iconForRoomType(RoomType type) => switch (type) {
  RoomType.topic => Icons.tag,
  RoomType.group => Icons.groups_outlined,
  RoomType.dm => Icons.person_outline,
};

/// 방/멤버/기간 필터 버튼 셋이 전부 이 위젯을 써서 겉모양(버튼+드롭다운 패널 틀)이 통일된다 —
/// 안에 들어가는 내용(패널)만 필터마다 다르다. Material `DropdownMenu`는 방 필터의 토픽/채팅
/// 탭 같은 커스텀 내용을 못 넣어서, 셋 다 `CompositedTransformTarget/Follower` + `OverlayEntry`로
/// 직접 앵커 드롭다운을 만든다.
class _FilterButton extends StatefulWidget {
  final String label;
  final bool expand;
  final Widget Function(VoidCallback close) panelBuilder;
  const _FilterButton({
    required this.label,
    this.expand = false,
    required this.panelBuilder,
  });

  @override
  State<_FilterButton> createState() => _FilterButtonState();
}

class _FilterButtonState extends State<_FilterButton> {
  final _link = LayerLink();
  OverlayEntry? _entry;

  void _open() {
    final overlay = Overlay.of(context);
    _entry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _close,
            ),
          ),
          CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            offset: const Offset(0, 44),
            child: widget.panelBuilder(_close),
          ),
        ],
      ),
    );
    overlay.insert(_entry!);
    setState(() {});
  }

  void _close() {
    _entry?.remove();
    _entry = null;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _entry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final button = OutlinedButton.icon(
      onPressed: _entry == null ? _open : _close,
      icon: Icon(_entry == null ? Icons.arrow_drop_down : Icons.arrow_drop_up),
      label: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    return CompositedTransformTarget(
      link: _link,
      child: widget.expand
          ? SizedBox(width: double.infinity, child: button)
          : button,
    );
  }
}

/// 필터 패널 공통 틀(그림자+둥근모서리+크기제한). 내용만 갈아끼운다.
class _FilterPanelShell extends StatelessWidget {
  final double width;
  final Widget child;
  const _FilterPanelShell({required this.width, required this.child});

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: width,
          maxWidth: width,
          maxHeight: 360,
        ),
        child: child,
      ),
    );
  }
}

Widget _filterSearchBox(ValueChanged<String> onChanged) {
  return Padding(
    padding: const EdgeInsets.all(8),
    child: TextField(
      decoration: const InputDecoration(
        hintText: '검색어를 입력하세요.',
        isDense: true,
        prefixIcon: Icon(Icons.search, size: 18),
        border: OutlineInputBorder(),
      ),
      onChanged: onChanged,
    ),
  );
}

/// "참여한 대화방" 필터. 토픽/채팅(그룹+DM) 탭으로 나눠서 보여준다.
class _RoomFilterButton extends StatelessWidget {
  final Session session;
  final String? selectedRoomId;
  final bool expand;
  final ValueChanged<String?> onSelected;
  const _RoomFilterButton({
    required this.session,
    required this.selectedRoomId,
    this.expand = false,
    required this.onSelected,
  });

  String get _label {
    final id = selectedRoomId;
    if (id == null) return '참여한 대화방';
    for (final r in session.rooms) {
      if (r.id == id) return r.displayName(session.userId ?? '');
    }
    return '참여한 대화방';
  }

  @override
  Widget build(BuildContext context) {
    return _FilterButton(
      label: _label,
      expand: expand,
      panelBuilder: (close) => _FilterPanelShell(
        width: 260,
        child: _RoomFilterPanel(
          session: session,
          selectedRoomId: selectedRoomId,
          onSelected: (id) {
            onSelected(id);
            close();
          },
        ),
      ),
    );
  }
}

class _RoomFilterPanel extends StatefulWidget {
  final Session session;
  final String? selectedRoomId;
  final ValueChanged<String?> onSelected;
  const _RoomFilterPanel({
    required this.session,
    required this.selectedRoomId,
    required this.onSelected,
  });

  @override
  State<_RoomFilterPanel> createState() => _RoomFilterPanelState();
}

class _RoomFilterPanelState extends State<_RoomFilterPanel> {
  bool _chatTab = false; // false=토픽, true=채팅(그룹+DM)
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final myId = widget.session.userId ?? '';
    final rooms = widget.session.rooms
        // 비밀 대화는 검색 자체가 안 되므로(요구사항) 방 범위 선택지에도 노출하지 않는다 —
        // 서버 쪽도 searchMessages에서 별도로 막고 있다(server/src/db/queries/messages.js).
        .where((r) => !r.isSecret)
        .where(
          (r) => _chatTab ? r.type != RoomType.topic : r.type == RoomType.topic,
        )
        .where(
          (r) =>
              _filter.isEmpty ||
              r.displayName(myId).toLowerCase().contains(_filter.toLowerCase()),
        )
        .toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            _tabButton(
              context,
              '토픽',
              !_chatTab,
              () => setState(() => _chatTab = false),
            ),
            _tabButton(
              context,
              '채팅',
              _chatTab,
              () => setState(() => _chatTab = true),
            ),
          ],
        ),
        const Divider(height: 1),
        _filterSearchBox((v) => setState(() => _filter = v)),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                dense: true,
                title: const Text('전체'),
                trailing: widget.selectedRoomId == null
                    ? const Icon(Icons.check, size: 18)
                    : null,
                onTap: () => widget.onSelected(null),
              ),
              const Divider(height: 1),
              for (final r in rooms)
                ListTile(
                  dense: true,
                  leading: Icon(_iconForRoomType(r.type), size: 18),
                  title: Text(
                    r.displayName(myId),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: widget.selectedRoomId == r.id
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  onTap: () => widget.onSelected(r.id),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tabButton(
    BuildContext context,
    String label,
    bool selected,
    VoidCallback onTap,
  ) {
    final color = selected
        ? Theme.of(context).colorScheme.primary
        : Colors.transparent;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: color, width: 2)),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "모든 멤버" 필터.
class _MemberFilterButton extends StatelessWidget {
  final List<AppUser>? users;
  final String? selectedSenderId;
  final ValueChanged<String?> onSelected;
  const _MemberFilterButton({
    required this.users,
    required this.selectedSenderId,
    required this.onSelected,
  });

  String get _label {
    final id = selectedSenderId;
    if (id == null) return '모든 멤버';
    for (final u in users ?? const <AppUser>[]) {
      if (u.id == id) return u.name;
    }
    return '모든 멤버';
  }

  @override
  Widget build(BuildContext context) {
    return _FilterButton(
      label: _label,
      panelBuilder: (close) => _FilterPanelShell(
        width: 220,
        child: _MemberFilterPanel(
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

class _MemberFilterPanel extends StatefulWidget {
  final List<AppUser>? users;
  final String? selectedSenderId;
  final ValueChanged<String?> onSelected;
  const _MemberFilterPanel({
    required this.users,
    required this.selectedSenderId,
    required this.onSelected,
  });

  @override
  State<_MemberFilterPanel> createState() => _MemberFilterPanelState();
}

class _MemberFilterPanelState extends State<_MemberFilterPanel> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final list = (widget.users ?? const <AppUser>[])
        .where(
          (u) =>
              _filter.isEmpty ||
              u.name.toLowerCase().contains(_filter.toLowerCase()),
        )
        .toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _filterSearchBox((v) => setState(() => _filter = v)),
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

/// 기간 필터. 검색창은 없이 프리셋 목록만 보여준다("직접 설정"은 상위에서 날짜 범위 선택기를 띄움).
class _PeriodFilterButton extends StatelessWidget {
  final SearchPeriod period;
  final ValueChanged<SearchPeriod?> onSelected;
  const _PeriodFilterButton({required this.period, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return _FilterButton(
      label: period.label,
      panelBuilder: (close) => _FilterPanelShell(
        width: 200,
        child: _PeriodFilterPanel(
          selected: period,
          onSelected: (p) {
            onSelected(p);
            close();
          },
        ),
      ),
    );
  }
}

class _PeriodFilterPanel extends StatelessWidget {
  final SearchPeriod selected;
  final ValueChanged<SearchPeriod> onSelected;
  const _PeriodFilterPanel({required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: true,
      children: [
        for (final p in SearchPeriod.values)
          ListTile(
            dense: true,
            title: Text(p.label),
            trailing: selected == p ? const Icon(Icons.check, size: 18) : null,
            onTap: () => onSelected(p),
          ),
      ],
    );
  }
}
