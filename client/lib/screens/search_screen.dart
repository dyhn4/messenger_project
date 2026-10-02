import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/app_user.dart';
import '../models/file_category.dart';
import '../models/poll.dart' show pollPreviewText;
import '../models/room.dart';
import '../services/api_client.dart';
import '../services/session.dart';
import '../widgets/filter_dropdown.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/pagination.dart';
import '../widgets/panel_filters.dart';
import 'chat_screen.dart';

/// 검색 패널의 종류 탭 — 전체 / 메시지 / 투표 / 파일(꺽쇠로 파일 형식).
enum SearchType { all, message, poll, file }

extension on SearchType {
  /// 서버 `type` 값 — 전체는 안 보낸다.
  String? get apiValue => this == SearchType.all ? null : name;
}

/// 한 번에 받아 오는 결과 수 — 넘치면 "결과 N건"의 N은 전체 건수이고 목록은 앞의 이만큼만 보인다.
const searchFetchLimit = 500;

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
  int _total = 0; // 한도에 잘리기 전의 전체 건수.
  bool _loading = false;
  String? _error;
  int _page = 0; // 0-based.

  List<AppUser>? _users;
  String? _roomId; // null = 참여한 대화방(전체)
  String? _senderId; // null = 모든 멤버
  PanelPeriod _period = const PanelPeriod();
  SearchType _type = SearchType.all;
  FileCategory _fileKind = FileCategory.all;
  bool _newestFirst = true;

  // 검색칸을 파일 패널("파일명 검색")과 같은 모양으로 — 입력을 멈추고 잠깐 뒤(또는 엔터)에
  // 찾는다(panel_filters.dart의 PanelFilterBar와 같은 디바운스).
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    try {
      final users = await widget.session.fetchTeamMembers();
      if (!mounted) return;
      setState(() => _users = users);
    } catch (_) {
      // 멤버 필터는 부가 기능이라 실패해도 조용히 무시한다.
    }
  }

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
      final page = await widget.session.api!.searchPage(
        q,
        // 검색은 지금 보고 있는 팀 안에서만 — 다른 팀 대화가 섞여 나오면 안 된다.
        teamId: widget.session.currentTeam!.id,
        roomId: _roomId,
        senderId: _senderId,
        since: _period.since(),
        until: _period.until,
        type: _type.apiValue,
        fileKind: _type == SearchType.file ? _fileKind.apiValue : null,
        newestFirst: _newestFirst,
        limit: searchFetchLimit,
      );
      if (!mounted) return;
      setState(() {
        _results = page.items;
        _total = page.total;
        _page = 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 조건(필터·탭·정렬)이 바뀌었을 때 — 이미 검색어가 있으면 그 조건으로 다시 찾는다.
  void _refresh() {
    if (_query.text.trim().isNotEmpty) _search();
  }

  /// 검색칸에 입력할 때마다 — 지우기(X) 단추 표시를 갱신하고, 잠깐(350ms) 멈추면 찾는다.
  void _onQueryChanged(String _) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _search);
  }

  /// 엔터를 누르거나 지우기(X)를 눌렀을 때 — 기다리지 않고 바로 찾는다.
  void _searchNow() {
    _debounce?.cancel();
    _search();
  }

  void _selectType(SearchType type) {
    if (_type == type) return;
    setState(() => _type = type);
    _refresh();
  }

  /// 꺽쇠 메뉴에서 파일 형식을 고르면 "파일" 탭으로 옮겨 그 형식으로 찾는다.
  void _selectFileKind(FileCategory kind) {
    setState(() {
      _type = SearchType.file;
      _fileKind = kind;
    });
    _refresh();
  }

  /// 결과 줄의 방 이름 — 목록에 있는 방이면 사이드바와 같은 이름(나에게만 바꾼 이름·나와의 대화 포함),
  /// 없으면(그 사이 나간 방 등) 서버가 준 이름. 서버는 모두가 보는 원래 이름을 준다.
  String _roomNameOf(SearchResult result) {
    final room = widget.session.roomById(result.roomId);
    if (room == null) return result.roomName ?? '';
    return room.displayName(widget.session.userId ?? '');
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
    _debounce?.cancel();
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
            key: const ValueKey('search-panel-field'),
            controller: _query,
            autofocus: true,
            decoration: InputDecoration(
              hintText: '메시지 검색',
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _query.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: '지우기',
                      onPressed: () {
                        _query.clear();
                        setState(() {});
                        _searchNow();
                      },
                    ),
              border: const OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.search,
            onChanged: _onQueryChanged,
            onSubmitted: (_) => _searchNow(),
          ),
          const SizedBox(height: 12),
          // 세 버튼 모두 Expanded로 감싸서 남는 폭을 동일한 비율로 나눠 갖는다.
          Row(
            children: [
              Expanded(
                child: RoomFilterButton(
                  session: widget.session,
                  selectedRoomId: _roomId,
                  expand: true,
                  onSelected: (value) {
                    setState(() => _roomId = value);
                    _refresh();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: MemberFilterButton(
                  users: _users,
                  selectedSenderId: _senderId,
                  onSelected: (value) {
                    setState(() => _senderId = value);
                    _refresh();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: PeriodFilterButton(
                  period: _period,
                  onChanged: (value) {
                    setState(() => _period = value);
                    _refresh();
                  },
                ),
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
        const SizedBox(height: 4),
        _buildTypeBar(context),
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

  /// 필터 줄 아래 — `전체 | 메시지 | 투표 | 파일 ⌄` 탭과 맨 오른쪽 정렬 단추. 검색 전에도 늘 보인다.
  Widget _buildTypeBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _SearchTab(
                    key: const ValueKey('search-tab-all'),
                    label: '전체',
                    selected: _type == SearchType.all,
                    onTap: () => _selectType(SearchType.all),
                  ),
                  _SearchTab(
                    key: const ValueKey('search-tab-message'),
                    label: '메시지',
                    selected: _type == SearchType.message,
                    onTap: () => _selectType(SearchType.message),
                  ),
                  _SearchTab(
                    key: const ValueKey('search-tab-poll'),
                    label: '투표',
                    selected: _type == SearchType.poll,
                    onTap: () => _selectType(SearchType.poll),
                  ),
                  _SearchTab(
                    key: const ValueKey('search-tab-file'),
                    label: _fileKind.buttonLabel,
                    selected: _type == SearchType.file,
                    onTap: () => _selectType(SearchType.file),
                    // 꺽쇠를 누르면 파일 형식 메뉴.
                    menuBuilder: (chevron) => FileCategoryMenu(
                      selected: _fileKind,
                      onSelected: _selectFileKind,
                      child: chevron,
                    ),
                  ),
                ],
              ),
            ),
          ),
          PanelSortButton(
            newestFirst: _newestFirst,
            onChanged: (v) {
              setState(() => _newestFirst = v);
              _refresh();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(_error!));
    final results = _results;
    if (results == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('내가 속한 모든 방을 대상으로 검색합니다.'),
        ),
      );
    }
    final theme = Theme.of(context);
    final summary = Text.rich(
      key: const ValueKey('search-result-count'),
      TextSpan(
        style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
        children: [
          const TextSpan(text: '결과 '),
          TextSpan(
            text: '$_total',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const TextSpan(text: '건'),
          // 한도를 넘으면 목록에는 앞의 일부만 있다는 걸 알린다.
          if (_total > results.length)
            TextSpan(
              text: ' (${results.length}건까지 표시)',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
    );
    final resultLine = PanelResultLine(
      summary: summary,
      rangeText: _period.rangeText,
    );

    if (results.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          resultLine,
          const Divider(height: 1),
          const Expanded(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('검색 결과가 없습니다.'),
              ),
            ),
          ),
        ],
      );
    }

    // 정렬은 서버가 한다(한도에 잘리는 쪽이 정렬 방향을 따라야 해서).
    final totalPages = (results.length / paginationPageSize).ceil();
    final page = _page.clamp(0, totalPages - 1);
    final pageItems = results
        .skip(page * paginationPageSize)
        .take(paginationPageSize)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        resultLine,
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
                roomName: _roomNameOf(pageItems[i]),
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

/// 종류 탭 하나 — 고른 탭은 굵은 글씨 + 밑줄. [menuBuilder]를 주면 글자 오른쪽에 꺽쇠가 붙고,
/// 꺽쇠를 누르면 그 메뉴가 열린다(글자를 누르면 탭만 고른다).
class _SearchTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget Function(Widget chevron)? menuBuilder;
  const _SearchTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.menuBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected ? theme.colorScheme.onSurface : theme.hintColor;
    final text = InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.only(
          left: 10,
          right: menuBuilder == null ? 10 : 0,
          top: 10,
          bottom: 10,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: color,
          ),
        ),
      ),
    );
    final builder = menuBuilder;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            width: 2,
            color: selected ? theme.colorScheme.onSurface : Colors.transparent,
          ),
        ),
      ),
      child: builder == null
          ? text
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                text,
                builder(
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 10, 8, 10),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      size: 18,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// 검색 결과 한 건: 방 이름(라벨) + (아바타 + 보낸사람 · 시간) + 내용. 카드 테두리 없이
/// ListView.separated의 Divider로만 결과끼리 구분한다. 내용 중 검색어는 형광펜으로
/// 칠한 것처럼 하이라이트한다.
class _SearchResultRow extends StatelessWidget {
  final SearchResult result;
  final String roomName;
  final String query;
  final DateFormat timeFormat;
  final VoidCallback onTap;
  const _SearchResultRow({
    required this.result,
    required this.roomName,
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
                      if (result.isPost)
                        ..._postLines(context)
                      else
                        _highlighted(
                          context,
                          result.isPoll
                              ? pollPreviewText(result.text)
                              : result.text ?? result.fileName ?? '(파일)',
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

  /// 보드 게시글 — "게시글" 표시와 굵은 제목 한 줄, 그 아래 본문 두 줄(검색어는 양쪽 다 칠한다 —
  /// 서버가 제목으로도 찾아준다).
  List<Widget> _postLines(BuildContext context) {
    final theme = Theme.of(context);
    final body = result.text?.trim() ?? '';
    return [
      Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '게시글',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _highlighted(
              context,
              result.title ?? '',
              query,
              maxLines: 1,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      if (body.isNotEmpty) ...[
        const SizedBox(height: 2),
        _highlighted(context, body, query, maxLines: 2),
      ],
    ];
  }

  Widget _highlighted(
    BuildContext context,
    String text,
    String query, {
    int? maxLines,
    TextStyle? style,
  }) {
    final overflow = maxLines == null ? null : TextOverflow.ellipsis;
    if (query.isEmpty) {
      return Text(text, maxLines: maxLines, overflow: overflow, style: style);
    }
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
      maxLines: maxLines,
      overflow: overflow ?? TextOverflow.clip,
      text: TextSpan(
        style: DefaultTextStyle.of(context).style.merge(style),
        children: spans,
      ),
    );
  }
}
