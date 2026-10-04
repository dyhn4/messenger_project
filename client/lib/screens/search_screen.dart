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
import '../widgets/app_toast.dart';
import '../widgets/pagination.dart';
import '../widgets/panel_filters.dart';
import '../widgets/private_topic_lock.dart';
import '../widgets/room_avatar.dart';
import '../widgets/room_options_menu.dart' show TopicBadge;
import 'chat_screen.dart';

/// 검색 패널의 종류 탭 — 전체 / 메시지 / 투표 / 파일(꺽쇠로 파일 형식) / 대화방(내가 멤버인 방의 이름).
/// 전체 탭은 메시지·투표·파일에 더해 이름이 맞는 대화방 몇 개를 맨 위 묶음으로 보여 준다.
enum SearchType { all, message, poll, file, room }

extension on SearchType {
  /// 서버 `type` 값 — 전체는 안 보낸다. 대화방은 메시지 검색이 아니라 따로(/api/search/rooms) 찾는다.
  String? get apiValue =>
      this == SearchType.all || this == SearchType.room ? null : name;
}

/// 탭 줄에 검색 범위 단추(현재 팀 ⌄)까지 한 줄로 두려면 필요한 최소 폭 — 이보다 좁으면(휴대폰 등) 단추를
/// `결과 N건` 줄 오른쪽으로 옮긴다. 5개 탭(대화방 포함) + 범위 단추 + 정렬 단추가 가로 스크롤 없이 들어가는 폭.
const _scopeInlineMinWidth = 388.0;

/// 한 번에 받아 오는 결과 수 — 넘치면 "결과 N건"의 N은 전체 건수이고 목록은 앞의 이만큼만 보인다.
const searchFetchLimit = 500;

class SearchScreen extends StatefulWidget {
  final Session session;
  final bool asDialog;
  final bool asPanel;
  final VoidCallback? onClose;

  /// room과 함께, 검색 결과로 클릭한 메시지 id도 같이 넘겨서 그 말풍선으로 스크롤+하이라이트할 수 있게 한다
  /// (대화방 결과를 눌렀을 때는 메시지가 없어 null).
  final void Function(Room room, String? highlightMessageId)? onOpenRoom;
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
  List<RoomSearchResult>? _roomResults; // 대화방 탭의 결과(메시지 결과와 둘 중 하나만 있다).
  // 전체 탭 맨 위 "대화방" 묶음 — 이름이 맞는 방 몇 개와 전체 건수(더 보기 → 대화방 탭). 못 받아 오면 비운다.
  List<RoomSearchResult> _roomPreview = const [];
  int _roomPreviewTotal = 0;
  bool _resultAllTeams = false; // 이 결과를 "모든 팀"으로 찾았는지 — 맞으면 줄마다 팀 이름 칩.
  int _requestSeq = 0; // 늦게 도착한 옛 응답이 새 결과를 덮어쓰지 않게.
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

  // 검색 범위 — 패널을 열 때마다 "현재 팀"으로 시작한다(기기에 저장하지 않는다). 가입한 팀이 하나뿐이면 단추 자체가 없다.
  // [_scopeTeamId]는 범위 메뉴에서 이름으로 고른 특정 팀(null이면 _allTeams에 따라 현재 팀 / 모든 팀).
  bool _allTeams = false;
  String? _scopeTeamId;
  int _usersSeq = 0; // 팀을 바꿔 멤버 목록을 다시 받을 때, 늦게 온 옛 응답을 버리려고.

  // 검색칸을 파일 패널("파일명 검색")과 같은 모양으로 — 입력을 멈추고 잠깐 뒤(또는 엔터)에
  // 찾는다(panel_filters.dart의 PanelFilterBar와 같은 디바운스).
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  /// "모든 멤버" 필터의 후보 — [teamId]를 주면 그 팀(범위에서 고른 특정 팀), 아니면 지금 팀의 멤버.
  /// 고른 멤버가 새 후보에 없으면 필터를 풀고 다시 찾는다.
  Future<void> _loadUsers([String? teamId]) async {
    final seq = ++_usersSeq;
    try {
      final users = teamId == null
          ? await widget.session.fetchTeamMembers()
          : await widget.session.api!.fetchTeamMembers(teamId);
      if (!mounted || seq != _usersSeq) return;
      final sender = _senderId;
      final dropSender = sender != null && !users.any((u) => u.id == sender);
      setState(() {
        _users = users;
        if (dropSender) _senderId = null;
      });
      if (dropSender) _refresh();
    } catch (_) {
      // 멤버 필터는 부가 기능이라 실패해도 조용히 무시한다.
    }
  }

  /// 전체 탭 맨 위 "대화방" 묶음에 보일 방 수.
  static const _roomPreviewCount = 3;

  /// 전체 탭의 대화방 묶음 — 이름이 맞는 방 앞의 몇 개와 전체 건수. 부가 결과라 실패하면 null(메시지 결과만 보인다).
  Future<RoomSearchPage?> _fetchRoomPreview(
    String q, {
    required String teamId,
    required bool allTeams,
  }) async {
    try {
      return await widget.session.api!.searchRoomsPage(
        q,
        teamId: teamId,
        allTeams: allTeams,
        newestFirst: _newestFirst,
        limit: _roomPreviewCount,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    final seq = ++_requestSeq;
    if (q.isEmpty) {
      setState(() {
        _results = null;
        _roomResults = null;
        _roomPreview = const [];
        _roomPreviewTotal = 0;
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = widget.session.api!;
    // 기본은 지금 보고 있는 팀 안에서만 — 다른 팀 대화는 "모든 팀"을 골랐을 때만 섞인다. 범위에서 특정 팀을
    // 골랐으면 그 팀 안에서만(서버가 그 팀 멤버인지 확인한다).
    final teamId = _pickedTeamId ?? widget.session.currentTeam!.id;
    final allTeams = _allTeamsActive;
    try {
      if (_type == SearchType.room) {
        // 대화방 탭 — 내가 멤버인 방의 이름. 방/멤버/기간 필터는 의미가 없어 보내지 않는다.
        final page = await api.searchRoomsPage(
          q,
          teamId: teamId,
          allTeams: allTeams,
          newestFirst: _newestFirst,
          limit: searchFetchLimit,
        );
        if (!mounted || seq != _requestSeq) return;
        setState(() {
          _roomResults = page.items;
          _results = null;
          _roomPreview = const [];
          _roomPreviewTotal = 0;
          _resultAllTeams = allTeams;
          _total = page.total;
          _page = 0;
        });
        return;
      }
      // 전체 탭은 이름이 맞는 대화방도 맨 위에 몇 개 보여 준다 — 메시지 검색과 함께(동시에) 받는다. 방·멤버로
      // 좁혔으면 메시지만 찾는 뜻이라 대화방 묶음은 뺀다.
      final roomsFuture =
          _type == SearchType.all && _roomId == null && _senderId == null
          ? _fetchRoomPreview(q, teamId: teamId, allTeams: allTeams)
          : Future<RoomSearchPage?>.value(null);
      final page = await api.searchPage(
        q,
        teamId: teamId,
        allTeams: allTeams,
        roomId: _roomId,
        senderId: _senderId,
        since: _period.since(),
        until: _period.until,
        type: _type.apiValue,
        fileKind: _type == SearchType.file ? _fileKind.apiValue : null,
        newestFirst: _newestFirst,
        limit: searchFetchLimit,
      );
      final rooms = await roomsFuture;
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _results = page.items;
        _roomResults = null;
        _roomPreview = rooms?.items ?? const [];
        _roomPreviewTotal = rooms?.total ?? 0;
        _resultAllTeams = allTeams;
        _total = page.total;
        _page = 0;
      });
    } catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted && seq == _requestSeq) setState(() => _loading = false);
    }
  }

  /// 가입한 팀이 둘 이상일 때만 검색 범위 단추가 있다.
  bool get _hasScopeChoice => widget.session.teams.length > 1;

  /// 범위 메뉴에서 이름으로 고른 팀 — 단추가 없거나, 그 사이 그 팀을 나갔으면 null(현재 팀 / 모든 팀).
  String? get _pickedTeamId {
    final id = _scopeTeamId;
    if (id == null || !_hasScopeChoice) return null;
    return widget.session.teams.any((t) => t.id == id) ? id : null;
  }

  /// 지금 "모든 팀"으로 찾는 중인지(단추가 없으면 늘 현재 팀).
  bool get _allTeamsActive =>
      _allTeams && _hasScopeChoice && _pickedTeamId == null;

  void _selectScope(bool allTeams) {
    if (_allTeams == allTeams && _scopeTeamId == null) return;
    final hadTeam = _pickedTeamId;
    setState(() {
      _allTeams = allTeams;
      _scopeTeamId = null;
    });
    _onFilterTeamChanged(hadTeam);
    _refresh();
  }

  /// 범위 메뉴에서 특정 팀을 골랐을 때 — 그 팀 하나에서만 찾는다.
  void _selectTeam(String teamId) {
    if (_scopeTeamId == teamId) return;
    final hadTeam = _pickedTeamId;
    setState(() {
      _scopeTeamId = teamId;
      _allTeams = false;
    });
    _onFilterTeamChanged(hadTeam);
    _refresh();
  }

  /// 참여 대화방·멤버 필터의 후보는 고른 팀(없으면 지금 팀)의 것이다 — 그 팀이 바뀌면 다른 팀 방을 골라 둔
  /// 방 필터는 풀고, 멤버 후보를 다시 받는다. [before]는 바꾸기 전에 고른 팀.
  void _onFilterTeamChanged(String? before) {
    final after = _pickedTeamId;
    if (before == after) return;
    final teamId = after ?? widget.session.currentTeam?.id;
    final room = _roomId == null ? null : widget.session.roomById(_roomId!);
    if (room != null && room.teamId != teamId) {
      setState(() => _roomId = null);
    }
    _loadUsers(after);
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
    final room = widget.session.roomById(result.roomId);
    if (room == null) return;
    _openRoom(room, messageId: result.id);
  }

  /// 대화방 결과를 눌렀을 때 — 그 방으로(다른 팀이면 팀 전환 포함).
  void _openRoomResult(RoomSearchResult result) {
    final room = widget.session.roomById(result.roomId);
    if (room == null) {
      showAppToast(context, '대화방을 찾을 수 없습니다.');
      return;
    }
    _openRoom(room);
  }

  /// [room]을 연다. [messageId]가 있으면 그 말풍선으로 스크롤·강조. 다른 팀의 방이면(모든 팀 검색)
  /// 먼저 그 팀으로 전환한다 — Session.requestOpenRoom이 팀을 바꾸고 방(과 메시지)을 열어 준다.
  void _openRoom(Room room, {String? messageId}) {
    final session = widget.session;
    final otherTeam = room.teamId != session.currentTeam?.id;
    final onOpenRoom = widget.onOpenRoom;
    if (widget.asPanel && onOpenRoom != null) {
      if (otherTeam) {
        session.requestOpenRoom(room, messageId: messageId);
      } else {
        onOpenRoom(room, messageId);
      }
      return;
    }
    if (widget.asDialog) Navigator.of(context).pop();
    // 좁은 화면도 다른 팀의 방일 수 있어 팀 전환만 requestOpenRoom에 맡기고 화면은 직접 얹는다(즐겨찾기와 같다).
    if (otherTeam) session.requestOpenRoom(room);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          session: session,
          room: room,
          highlightMessageId: messageId,
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
              hintText: _type == SearchType.room ? '대화방 이름 검색' : '통합 검색',
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
          // 대화방 탭은 방 이름만 찾아서 참여 대화방·멤버·기간 필터가 뜻이 없다 — 줄째 숨긴다.
          if (_type != SearchType.room) ...[
            const SizedBox(height: 12),
            // 세 버튼 모두 Expanded로 감싸서 남는 폭을 동일한 비율로 나눠 갖는다.
            Row(
              children: [
                Expanded(
                  child: RoomFilterButton(
                    session: widget.session,
                    selectedRoomId: _roomId,
                    teamId: _pickedTeamId,
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
        ],
      ),
    );
    // 검색 범위 단추(현재 팀 ⌄)는 탭 줄의 정렬 단추 왼쪽에 둔다. 폭이 모자라면(휴대폰) `결과 N건` 줄 오른쪽으로.
    final body = LayoutBuilder(
      builder: (context, constraints) {
        final scope = _hasScopeChoice
            ? PanelScopeButton(
                allTeams: _allTeamsActive,
                onChanged: _selectScope,
                // 가입한 팀 전부(현재 팀 포함) — 이름으로 골라 그 팀 하나만 찾는다.
                teams: [
                  for (final t in widget.session.teams)
                    (id: t.id, name: t.name),
                ],
                teamId: _pickedTeamId,
                onTeamSelected: _selectTeam,
              )
            : null;
        final inline =
            scope != null && constraints.maxWidth - 32 >= _scopeInlineMinWidth;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            controls,
            const SizedBox(height: 4),
            _buildTypeBar(context, inline ? scope : null),
            // 결과 줄로 내려온 단추는 줄 오른쪽 끝에 붙인다(결과 줄의 오른쪽 칸이 글자 폭만큼만 잡혀 가운데쯤에 뜨지 않게).
            Expanded(
              child: _buildResults(
                context,
                inline || scope == null
                    ? null
                    : Align(alignment: Alignment.centerRight, child: scope),
              ),
            ),
          ],
        );
      },
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

  /// 필터 줄 아래 — `전체 | 메시지 | 투표 | 파일 ⌄ | 대화방` 탭과 맨 오른쪽 정렬 단추. 검색 전에도 늘 보인다.
  /// [scope]는 정렬 단추 왼쪽에 둘 검색 범위 단추(자리가 모자라거나 팀이 하나면 null).
  Widget _buildTypeBar(BuildContext context, Widget? scope) {
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
                  _SearchTab(
                    key: const ValueKey('search-tab-room'),
                    label: '대화방',
                    selected: _type == SearchType.room,
                    onTap: () => _selectType(SearchType.room),
                  ),
                ],
              ),
            ),
          ),
          ?scope,
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

  /// [scope]는 탭 줄에 자리가 없어 이쪽으로 내려온 검색 범위 단추 — 결과 N건 줄(검색 전·중에도 빈 줄로) 오른쪽에 둔다.
  Widget _buildResults(BuildContext context, Widget? scope) {
    final roomResults = _roomResults;
    final messageResults = _results;
    final isRooms = roomResults != null;
    if (_loading || _error != null || (messageResults == null && !isRooms)) {
      final Widget message = _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(switch (_type) {
                  SearchType.room => '내가 참여 중인 토픽·그룹채팅·채팅의 이름을 검색합니다.',
                  SearchType.all => '대화방 이름과 메시지·파일을 검색합니다.',
                  _ => '내가 속한 모든 방을 대상으로 검색합니다.',
                }, textAlign: TextAlign.center),
              ),
            );
      if (scope == null) return message;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelResultLine(summary: const SizedBox.shrink(), trailing: scope),
          const Divider(height: 1),
          Expanded(child: message),
        ],
      );
    }
    final count = isRooms ? roomResults.length : messageResults!.length;
    // 전체 탭 맨 위의 대화방 묶음 — 결과 N건에도 더한다(더 보기로 대화방 탭에서 다 볼 수 있어 "표시"에도 넣는다).
    final preview = isRooms ? const <RoomSearchResult>[] : _roomPreview;
    final roomTotal = preview.isEmpty ? 0 : _roomPreviewTotal;
    final total = _total + roomTotal;
    final shown = count + roomTotal;
    final theme = Theme.of(context);
    final summary = Text.rich(
      key: const ValueKey('search-result-count'),
      TextSpan(
        style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
        children: [
          const TextSpan(text: '결과 '),
          TextSpan(
            text: '$total',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const TextSpan(text: '건'),
          // 한도를 넘으면 목록에는 앞의 일부만 있다는 걸 알린다.
          if (total > shown)
            TextSpan(text: ' ($shown건까지 표시)', style: theme.textTheme.bodySmall),
        ],
      ),
    );
    final resultLine = PanelResultLine(
      summary: summary,
      // 대화방 탭은 기간을 안 쓴다.
      rangeText: isRooms ? null : _period.rangeText,
      trailing: scope,
    );

    if (count == 0 && preview.isEmpty) {
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
    final totalPages = count == 0 ? 1 : (count / paginationPageSize).ceil();
    final page = _page.clamp(0, totalPages - 1);
    final start = page * paginationPageSize;
    final pageCount = (count - start).clamp(0, paginationPageSize);
    final query = _query.text.trim();

    // 전체 탭 첫 쪽 맨 위 — "대화방" 머리줄 + 이름이 맞는 방 몇 개(+ 더 보기 → 대화방 탭), 그 아래 "메시지" 머리줄.
    final lead = <Widget>[];
    final headerIndexes = <int>{};
    if (page == 0 && preview.isNotEmpty) {
      headerIndexes.add(0);
      lead.add(
        _SectionHeader(
          key: const ValueKey('search-section-rooms'),
          label: '대화방',
          count: roomTotal,
          onMore: roomTotal > preview.length
              ? () => _selectType(SearchType.room)
              : null,
        ),
      );
      for (final r in preview) {
        lead.add(
          _RoomResultRow(
            key: ValueKey('search-room-preview-${r.roomId}'),
            result: r,
            room: widget.session.roomById(r.roomId),
            session: widget.session,
            query: query,
            showTeam: _resultAllTeams,
            onTap: () => _openRoomResult(r),
          ),
        );
      }
      if (count > 0) {
        headerIndexes.add(lead.length);
        lead.add(
          _SectionHeader(
            key: const ValueKey('search-section-messages'),
            label: '메시지',
            count: _total,
          ),
        );
      }
    }

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
              itemCount: lead.length + pageCount,
              // 오른쪽 끝에 겹치는 스크롤바 아래로 선이 파고들지 않도록 그만큼 짧게 그린다. 묶음 머리줄의 위아래는
              // 머리줄 바탕색이 나눠 주므로 선을 긋지 않는다.
              separatorBuilder: (_, i) =>
                  headerIndexes.contains(i) || headerIndexes.contains(i + 1)
                  ? const SizedBox.shrink()
                  : const Padding(
                      padding: EdgeInsets.only(right: 12),
                      child: Divider(height: 1),
                    ),
              itemBuilder: (context, index) {
                if (index < lead.length) return lead[index];
                final i = index - lead.length;
                if (isRooms) {
                  final item = roomResults[start + i];
                  return _RoomResultRow(
                    result: item,
                    room: widget.session.roomById(item.roomId),
                    session: widget.session,
                    query: query,
                    showTeam: _resultAllTeams,
                    onTap: () => _openRoomResult(item),
                  );
                }
                final item = messageResults![start + i];
                return _SearchResultRow(
                  result: item,
                  roomName: _roomNameOf(item),
                  query: query,
                  timeFormat: _timeFormat,
                  showTeam: _resultAllTeams,
                  onTap: () => _openResult(item),
                );
              },
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
          left: 6,
          right: menuBuilder == null ? 6 : 0,
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
  final bool showTeam; // 모든 팀 검색이면 방 이름 옆에 팀 이름 칩.
  final VoidCallback onTap;
  const _SearchResultRow({
    required this.result,
    required this.roomName,
    required this.query,
    required this.timeFormat,
    this.showTeam = false,
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
            Row(
              children: [
                Flexible(
                  child: Text(
                    roomName,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (showTeam &&
                    result.teamName != null &&
                    result.teamName!.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  _TeamChip(
                    key: const ValueKey('search-team-chip'),
                    name: result.teamName!,
                  ),
                ],
              ],
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
  }) =>
      _highlightedText(context, text, query, maxLines: maxLines, style: style);
}

/// [text] 안의 [query]를 형광펜으로 칠한 것처럼 보여준다(대소문자 무시).
Widget _highlightedText(
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

/// 모든 팀 검색에서 결과가 어느 팀 것인지 알려 주는 작은 칩.
class _TeamChip extends StatelessWidget {
  final String name;
  const _TeamChip({super.key, required this.name});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// 전체 탭 결과 목록의 묶음 머리줄 — `대화방 5 … 더 보기 ›` / `메시지 383`. 옅은 바탕으로 묶음을 나눈다.
class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;

  /// 주면 오른쪽에 "더 보기 ›"(그 종류의 탭으로).
  final VoidCallback? onMore;
  const _SectionHeader({
    super.key,
    required this.label,
    required this.count,
    this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final more = onMore;
    return ColoredBox(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, more == null ? 16 : 8, 0),
        child: SizedBox(
          height: 32,
          child: Row(
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
              const Spacer(),
              if (more != null)
                InkWell(
                  key: const ValueKey('search-section-more'),
                  onTap: more,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(6, 4, 2, 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '더 보기',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.hintColor,
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: theme.hintColor,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 대화방 탭(과 전체 탭 맨 위 "대화방" 묶음)의 결과 한 줄: 방 아바타 + 방 이름(검색어 하이라이트, 비공개 토픽은 자물쇠) +
/// 종류(토픽/그룹채팅/채팅)·보관됨·멤버 수·(모든 팀이면) 팀 이름 칩.
class _RoomResultRow extends StatelessWidget {
  final RoomSearchResult result;
  final Room? room; // 내 방 목록에서 찾은 방(아바타·비공개 표시용) — 없으면 글자 아바타.
  final Session session;
  final String query;
  final bool showTeam;
  final VoidCallback onTap;
  const _RoomResultRow({
    super.key,
    required this.result,
    required this.room,
    required this.session,
    required this.query,
    required this.showTeam,
    required this.onTap,
  });

  static String kindLabel(String type) => switch (type) {
    'topic' => '토픽',
    'group' => '그룹채팅',
    _ => '채팅',
  };

  Widget _avatar(BuildContext context) {
    const size = 32.0;
    final r = room;
    if (result.isSelf) return SelfRoomAvatar(session: session, size: size);
    if (result.type == 'topic') {
      final scheme = Theme.of(context).colorScheme;
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          r != null && r.isBoard ? Icons.dashboard_outlined : Icons.tag,
          size: 18,
          color: scheme.primary,
        ),
      );
    }
    if (r == null) {
      return CircleAvatar(
        radius: size / 2,
        child: Text(result.name.isNotEmpty ? result.name[0] : '?'),
      );
    }
    return RoomAvatar(
      room: r,
      myUserId: session.userId ?? '',
      resolveUrl: session.resolveUrl,
      onlineUserIds: session.onlineUserIds,
      size: size,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final small = theme.textTheme.bodySmall?.copyWith(color: hint);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            _avatar(context),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: _highlightedText(
                          context,
                          result.name,
                          query,
                          maxLines: 1,
                          style: TextStyle(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (room?.isPrivateTopic ?? false)
                        const PrivateTopicLock(size: 14),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(kindLabel(result.type), style: small),
                      if (result.archived)
                        const TopicBadge.archived(
                          key: ValueKey('search-room-archived'),
                        ),
                      if (!result.isSelf && result.memberCount > 0)
                        Text('· 멤버 ${result.memberCount}명', style: small),
                      if (showTeam && result.teamName.isNotEmpty)
                        _TeamChip(
                          key: const ValueKey('search-team-chip'),
                          name: result.teamName,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
