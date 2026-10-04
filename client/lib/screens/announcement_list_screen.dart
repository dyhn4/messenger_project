import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show mergeSort;
import 'package:flutter/material.dart';

import '../models/announcement.dart';
import '../models/room.dart';
import '../services/chat_socket.dart' show AnnouncementRemovedEvent;
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/avatar_utils.dart';
import '../widgets/board_view.dart' show PinnedPostTag;
import '../widgets/filter_dropdown.dart' show iconForRoomType;
import '../widgets/home_shell_scope.dart';
import '../widgets/panel_filters.dart' show PanelSortButton;
import '../widgets/rich_text_format.dart' show FormattedText;
import '../widgets/room_options_menu.dart' show CloseWhenRoomRemoved;
import '../widgets/side_panels.dart' show openSidePanel;
import '../widgets/todo_widgets.dart' show todoPanelRoute;
import 'announcement_detail_screen.dart';
import 'announcement_editor_dialog.dart';
import 'home_screen.dart' show wideBreakpoint;

/// 공지 패널의 키(side_panels.dart의 [SidePanelSpec.key]).
const announcementPanelKey = 'announcements';

/// 토픽방 [room]의 "공지 패널"을 연다 — 토픽 머리 ⋯의 "공지"와 알림 센터(안 읽은 공지가 여럿인 방), 채팅방 공지바가 부른다.
/// PC(홈 셸 아래)는 오른쪽 패널(이미 그 방 것이 열려 있으면 닫고, 다른 방 것이면 그 방으로 바꾼다), 모바일은 전체 화면이다.
/// 홈 셸 밖의 넓은 화면(팀 리스트 화면의 알림 센터 대화상자 등 — 오른쪽 칸이 없다)은 같은 패널을 가운데 대화상자로 띄운다.
///
/// [initialAnnouncement]를 주면(공지바를 눌렀을 때) 목록과 함께 그 공지의 상세를 바로 띄운다 — PC는 패널 안 Navigator에
/// 상세를 얹어 ←로 목록에 돌아오고, 모바일은 전체 화면 목록 위에 상세 화면을 얹는다(←로 목록). PC에서 그 방의 공지 패널이
/// 이미 열려 있으면 닫지 않고 그 패널 안에 상세만 띄운다.
void openAnnouncementPanel(
  BuildContext context,
  Session session,
  Room room, {
  Announcement? initialAnnouncement,
}) {
  final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  final shell = HomeShellScope.maybeOf(context);
  // 이번에 열 패널이 가져갈 첫 상세 — 없는 요청이면 예전 것도 지운다(엉뚱한 때 열리지 않게).
  _pendingInitial = initialAnnouncement == null
      ? null
      : (roomId: room.id, announcement: initialAnnouncement);
  if (shell == null && wide) {
    _pendingInitial = null;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 440,
          height: 680,
          child: AnnouncementsPanel(
            session: session,
            room: room,
            inPlacePages: true,
            initialAnnouncement: initialAnnouncement,
            onClose: () => Navigator.of(dialogContext).pop(),
          ),
        ),
      ),
    );
    return;
  }
  if (shell != null && initialAnnouncement != null) {
    // 그 방의 공지 패널이 이미 오른쪽에 열려 있으면 토글로 닫지 않고 그 안에 상세만 띄운다.
    for (final panel in _AnnouncementsPanelState._mounted) {
      if (panel.mounted &&
          panel._room.id == room.id &&
          panel._hasInPlacePages &&
          panel.context.findAncestorWidgetOfExactType<HomeShellScope>() !=
              null) {
        _pendingInitial = null;
        panel._showDetail(initialAnnouncement);
        return;
      }
    }
  }
  openSidePanel(context, session, announcementPanelKey, room: room);
}

/// [openAnnouncementPanel]이 새로 열 패널에 넘기는 "처음 띄울 상세" — 패널은 side_panels.dart의 builder가 만드므로
/// 여기 잠깐 두고 [takeInitialAnnouncementFor]로 한 번 가져간다.
({String roomId, Announcement announcement})? _pendingInitial;

/// [roomId] 방의 공지 패널을 새로 만들 때 처음 띄울 상세(공지바로 열었을 때) — 한 번 가져가면 지워진다. side_panels.dart의
/// 공지 패널 builder가 부른다.
Announcement? takeInitialAnnouncementFor(String roomId) {
  final pending = _pendingInitial;
  if (pending == null || pending.roomId != roomId) return null;
  _pendingInitial = null;
  return pending.announcement;
}

/// 토픽방 "공지" 패널 — 카카오톡과 같은 개념. 누구나 볼 수 있고(방 멤버라면), 토픽을 만들 수 있는 사람만 새로 쓸 수 있다
/// (session.canCreateAnnouncementIn). pinned인 글(방마다 최대 1개)이 채팅방 상단 배너에 고정된다 — 새 글을 쓰면 자동으로 그
/// 글로 바뀌고, "공지 내리기"로 직접 내릴 수도 있다(announcement_detail_screen.dart).
///
/// 투표 패널(polls_screen.dart)과 같은 틀이다 — 위에서부터 머리(`공지` + 그 아래 작은 회색 방 이름, 오른쪽 ✕), 가로 전체 옅은
/// 회색 `+ 공지 쓰기`(쓸 수 있는 사람만), 작은 글씨 줄(왼쪽 `내린 공지 제외` 스위치 — 켜면 채팅방에 고정된 공지만, 오른쪽
/// `최신 순 / 과거 순` 정렬), 그 아래 옅은 회색 바탕에 `N개의 공지`(지금 보이는 개수)와 흰 둥근 카드 목록이다. 카드는 작성자
/// 아바타·고정/안 읽음 표시·본문 앞부분·`작성자 · 시각`·사진 썸네일·댓글 수와 오른쪽 위 ⋯(상세의 ⋯와 같은 메뉴·권한)를 보인다.
///
/// 카드를 누르면 상세가 열린다 — PC 오른쪽 칸(홈 셸 아래)에서는 할 일 패널처럼 패널 안에 Navigator를 따로 두고 상세를 패널 안
/// 화면(머리 `← 공지 … ✕` — ←는 목록으로, ✕는 패널 전체를 닫는다)으로 띄우고, 모바일은 전체 화면(`← 공지`)으로 띄운다.
/// 공지바로 열면([AnnouncementsPanel.initialAnnouncement]) 같은 방식으로 그 공지의 상세가 목록 위에 바로 뜬다.
///
/// 패널을 열 때 방에 안 읽은 공지가 있으면(알림 센터에서 왔거나 배너만 보고 안 열었을 때) 목록 위쪽의(=가장 최근의) 다른 사람이
/// 쓴 공지 그만큼에 "안 읽음" 표시를 붙여서 어느 게 새 공지인지 알 수 있게 하고, 방의 안 읽은 공지 표시는 지운다.
class AnnouncementsPanel extends StatefulWidget {
  final Session session;
  final Room room;
  final VoidCallback? onClose;

  /// "안 읽음" 표시를 붙일 공지 수 — 0이면 열 때의 방 상태(room.unreadAnnouncementCount)로 정한다.
  final int unreadCount;

  /// 상세를 패널 안 화면으로 띄울지 — 홈 셸 아래(PC 오른쪽 칸)면 늘 그렇고, 홈 셸 밖의 대화상자로 띄울 때 true를 준다.
  final bool inPlacePages;

  /// 열자마자 상세를 띄울 공지(공지바를 눌러 열었을 때) — 목록이 첫 화면이고 그 위에 상세가 얹혀서 ←로 목록에 돌아온다.
  /// 처음 만들 때 한 번만 본다. null이면 목록만.
  final Announcement? initialAnnouncement;

  const AnnouncementsPanel({
    super.key,
    required this.session,
    required this.room,
    this.onClose,
    this.unreadCount = 0,
    this.inPlacePages = false,
    this.initialAnnouncement,
  });

  @override
  State<AnnouncementsPanel> createState() => _AnnouncementsPanelState();
}

class _AnnouncementsPanelState extends State<AnnouncementsPanel>
    with CloseWhenRoomRemoved {
  /// 지금 떠 있는 공지 패널들 — 공지바를 눌렀을 때 그 방의 패널이 이미 열려 있으면 그 안에 상세만 띄우려고
  /// ([openAnnouncementPanel]).
  static final _mounted = <_AnnouncementsPanelState>{};

  List<Announcement>? _items;
  String? _error;
  StreamSubscription<Announcement>? _newSub;
  StreamSubscription<Announcement>? _updatedSub;
  StreamSubscription<AnnouncementRemovedEvent>? _deletedSub;
  StreamSubscription<AnnouncementRemovedEvent>? _unpinnedSub;

  /// PC 패널 안 Navigator — 목록이 첫 화면이고 상세가 그 위에 올라온다. 모바일(홈 셸 없음)에는 없다(currentState가 null).
  final _pages = GlobalKey<NavigatorState>();

  /// `내린 공지 제외` — 켜면 채팅방에 고정된(pinned) 공지만 보인다.
  bool _excludeUnpinned = false;

  /// 열 때 정한 "안 읽음" 표시 개수(방을 읽음 처리하기 전의 값).
  late final int _unreadTarget;

  /// "안 읽음" 표시가 붙은 공지 id — 처음 목록을 받았을 때 한 번만 정하고, 상세를 열어본 공지는 여기서 빼서 표시를 지운다
  /// (build에서 매번 다시 계산하면 열어본 것도 다시 붙는다).
  Set<String>? _unreadIds;

  /// 목록을 받기 전에 열어본 공지 id(공지바로 열어 상세가 바로 뜬 경우) — [_unreadIds]를 정할 때 뺀다.
  final _openedBeforeLoad = <String>{};

  /// 정렬 — true면 최신 순(기본), false면 과거 순. 받아 둔 목록을 작성 시각으로 그 자리에서 다시 줄 세운다.
  bool _newestFirst = true;

  Session get _session => widget.session;
  Room get _room => widget.room;
  bool get _canWrite => _session.canCreateAnnouncementIn(_room);

  @override
  Session get roomSession => _session;

  @override
  String get watchedRoomId => _room.id;

  /// 방이 사라지면(토픽 삭제·내보내짐·나가기) 패널을 닫는다(모바일은 이 화면을 닫는다).
  @override
  void onWatchedRoomRemoved() => widget.onClose?.call();

  @override
  void initState() {
    super.initState();
    _unreadTarget = widget.unreadCount > 0
        ? widget.unreadCount
        : (_room.hasUnreadAnnouncement
              ? math.max(1, _room.unreadAnnouncementCount)
              : 0);
    _mounted.add(this);
    _load();
    // 공지바로 열었으면 목록 위에 그 공지의 상세를 바로 띄운다(PC는 패널 안 Navigator가 생긴 다음 프레임에).
    final initial = widget.initialAnnouncement;
    if (initial != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _open(initial);
      });
    }
    // 패널을 실제로 열었다는 뜻 — 알림 센터의 "안 읽은 공지" 표시를 여기서 지운다(session.dart의 markAnnouncementsRead
    // 참고. 배너만 보고 안 열었으면 안읽음 그대로). 그리는 도중에 다른 위젯을 다시 그리게 하지 않도록 다음 프레임에.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _session.markAnnouncementsRead(_room);
    });
    // 열어둔 채로 누군가 공지를 쓰거나/고치거나/내리거나/지우면, 새로고침 없이 그 자리에서 바로 반영한다 — 채팅방 배너와
    // 같은 실시간성.
    final socket = _session.chatSocket;
    _newSub = socket.announcements.listen((a) {
      if (a.roomId != _room.id || !mounted) return;
      setState(() {
        final items = _items;
        if (items == null || items.any((e) => e.id == a.id)) return;
        // 새 공지가 고정되면 그전 공지는 내려간다(서버도 같다).
        if (a.pinned) {
          for (final e in items) {
            e.pinned = false;
          }
        }
        _items = [a, ...items];
      });
    });
    _updatedSub = socket.announcementUpdated.listen((a) {
      if (a.roomId != _room.id || !mounted) return;
      setState(() {
        final items = _items;
        if (items == null) return;
        final i = items.indexWhere((e) => e.id == a.id);
        if (i == -1) return;
        items[i].text = a.text;
        items[i].textFormat = a.textFormat;
        items[i].editedAt = a.editedAt;
      });
    });
    _deletedSub = socket.announcementDeleted.listen((e) {
      if (e.roomId != _room.id || !mounted) return;
      _remove(e.id);
    });
    _unpinnedSub = socket.announcementUnpinned.listen((e) {
      if (e.roomId != _room.id || !mounted) return;
      setState(() {
        final i = _items?.indexWhere((a) => a.id == e.id) ?? -1;
        if (i != -1) _items![i].pinned = false;
      });
    });
  }

  @override
  void dispose() {
    _mounted.remove(this);
    _newSub?.cancel();
    _updatedSub?.cancel();
    _deletedSub?.cancel();
    _unpinnedSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_error != null) setState(() => _error = null);
    try {
      final items = await _session.api!.fetchAnnouncements(_room.id);
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = '공지를 불러오지 못했습니다: $e');
    }
  }

  void _remove(String id) {
    if (!mounted) return;
    setState(() => _items = _items?.where((a) => a.id != id).toList());
  }

  /// `+ 공지 쓰기` — 게시글 작성창과 같은 틀의 공지 쓰기 창(announcement_editor_dialog.dart). PC는 가운데 대화상자(이 패널의
  /// context는 창 크기를 보므로), 모바일은 전체 화면. 등록 실패는 창 안에서 토스트로 알리고 쓰던 글을 남겨 둔다.
  Future<void> _write() async {
    await showAnnouncementEditor(
      context,
      session: _session,
      room: _room,
      onSubmit: (draft) async {
        final autoUnpinAfter = draft.autoUnpinAfter;
        final Announcement created;
        try {
          created = await _session.api!.createAnnouncement(
            _room.id,
            draft.text,
            textFormat: draft.format,
            autoUnpinAt: autoUnpinAfter == null
                ? null
                : DateTime.now().add(autoUnpinAfter),
          );
        } catch (e) {
          throw '공지를 등록하지 못했습니다: $e';
        }
        if (!mounted) return;
        // 소켓 echo(위 _newSub)와 중복되지 않도록 id로 한 번 더 확인한다.
        setState(() {
          final items = _items ?? [];
          if (items.any((e) => e.id == created.id)) return;
          if (created.pinned) {
            for (final e in items) {
              e.pinned = false;
            }
          }
          _items = [created, ...items];
        });
      },
    );
  }

  /// PC 패널 안 Navigator가 있는지(홈 셸 아래나 대화상자) — 없으면(모바일) 상세는 앱의 Navigator에 전체 화면으로 올린다.
  bool get _hasInPlacePages => _pages.currentState != null;

  /// 이미 열려 있는 이 패널에 [a]의 상세를 띄운다(공지바를 눌렀을 때) — 다른 상세가 떠 있으면 목록으로 돌아간 뒤 얹는다.
  void _showDetail(Announcement a) {
    _pages.currentState?.popUntil((route) => route.isFirst);
    _open(a);
  }

  /// 카드를 누르면 상세 — PC는 패널 안 화면, 모바일은 전체 화면. 열어본 공지는 "안 읽음" 표시를 지운다.
  Future<void> _open(Announcement a) async {
    setState(() {
      final ids = _unreadIds;
      if (ids != null) {
        ids.remove(a.id);
      } else {
        _openedBeforeLoad.add(a.id);
      }
    });
    final pages = _pages.currentState;
    void deleted() => _remove(a.id);
    if (pages != null) {
      await pages.push(
        todoPanelRoute<void>(
          (pageContext) => AnnouncementDetailScreen(
            session: _session,
            room: _room,
            announcement: a,
            onBack: () => Navigator.of(pageContext).maybePop(),
            onClose: widget.onClose,
            onDeleted: deleted,
          ),
        ),
      );
    } else {
      await pushAnnouncementDetailPage(
        Navigator.of(context),
        _session,
        _room,
        a,
        onDeleted: deleted,
      );
    }
    // 상세에서 고치거나 내리거나 댓글을 달았다면(같은 객체를 고친다) 카드도 새로 그린다. 공지바로 연 상세는 방 상단 공지
    // 객체(Room.latestAnnouncement — 공지바의 실시간 댓글 수가 그대로 이어지게)를 쓰므로 목록의 같은 공지에 옮겨 적는다.
    if (mounted) setState(() => _syncFrom(a));
  }

  /// 목록 밖의 [a](공지바의 공지 객체)에서 바뀐 것 — 댓글 수·고친 글·내림 — 을 목록의 같은 공지에 옮긴다.
  void _syncFrom(Announcement a) {
    final item = _items?.where((e) => e.id == a.id).firstOrNull;
    if (item == null || identical(item, a)) return;
    item.commentCount = math.max(item.commentCount, a.liveCommentCount);
    final edited = a.editedAt;
    final itemEdited = item.editedAt;
    if (edited != null && (itemEdited == null || edited.isAfter(itemEdited))) {
      item.text = a.text;
      item.textFormat = a.textFormat;
      item.editedAt = edited;
    }
    if (!a.pinned) item.pinned = false;
  }

  /// 카드 ⋯에서 고른 동작 — 상세의 ⋯와 같은 코드([runAnnouncementMoreAction]). 고쳤거나 내렸으면 카드를 다시 그리고,
  /// 지웠으면 카드를 뺀다.
  Future<void> _onCardMore(
    Announcement a,
    AnnouncementMoreAction action,
  ) async {
    final result = await runAnnouncementMoreAction(
      context,
      _session,
      _room,
      a,
      action,
    );
    if (!mounted) return;
    switch (result) {
      case AnnouncementActionResult.changed:
        setState(() {});
      case AnnouncementActionResult.deleted:
        _remove(a.id);
      case AnnouncementActionResult.none:
        break;
    }
  }

  void _setNewestFirst(bool v) {
    if (v == _newestFirst) return;
    setState(() => _newestFirst = v);
  }

  void _setExcludeUnpinned(bool v) {
    if (v == _excludeUnpinned) return;
    setState(() => _excludeUnpinned = v);
  }

  // ---- 그리기 ----

  /// 목록 아래쪽 옅은 회색 바탕 — 그 위에 [_cardColor] 카드가 떠 보인다(투표·할 일 패널과 같은 색).
  static Color _listBackground(BuildContext context) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.dark
        ? theme.colorScheme.surfaceContainerLow
        : theme.colorScheme.surfaceContainer;
  }

  /// 카드 바탕 — 밝은 테마는 패널 바탕(surface)과 같은 흰색.
  static Color _cardColor(BuildContext context) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.dark
        ? theme.colorScheme.surfaceContainerHigh
        : theme.colorScheme.surface;
  }

  @override
  Widget build(BuildContext context) {
    // 모바일(전체 화면 라우트) — 목록만 그리고, 상세는 앱의 Navigator에 전체 화면으로 올린다.
    if (!widget.inPlacePages && HomeShellScope.maybeOf(context) == null) {
      return _listPage(context);
    }
    // PC 오른쪽 칸 — 패널 안 Navigator의 첫 화면이 목록이다(할 일 패널과 같다). 밀려 들어오는 상세가 패널 밖으로 비치지
    // 않게 자른다. 시스템 뒤로 가기(안드로이드 태블릿)는 패널 안 화면부터 닫는다.
    return NavigatorPopHandler(
      onPopWithResult: (_) => _pages.currentState?.maybePop(),
      child: ClipRect(
        child: Navigator(
          key: _pages,
          onGenerateInitialRoutes: (navigator, initialRoute) => [
            // 패널이 다시 그려질 때마다 Navigator가 화면들을 다시 그리므로 목록은 늘 지금 상태로 그려진다. 패널을 열기만
            // 해서는 포커스를 가져오지 않는다 — 채팅 입력칸에 쓰던 글을 이어 쓸 수 있게.
            PageRouteBuilder<void>(
              requestFocus: false,
              pageBuilder: (context, _, _) => _listPage(context),
            ),
          ],
        ),
      ),
    );
  }

  /// 목록 화면 — 머리, 공지 쓰기, `내린 공지 제외` 줄, 그 아래 회색 바탕의 건수 줄과 카드 목록.
  Widget _listPage(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context),
          const Divider(height: 1),
          if (_canWrite) _writeButton(context),
          _optionBar(context),
          Expanded(
            child: ColoredBox(
              color: _listBackground(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _countLine(context),
                  Expanded(child: _body(context)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 머리 — `공지`와 그 아래 작은 회색 방 이름(토픽 아이콘 + 이름), 오른쪽 ✕. 높이는 다른 패널 머리(SidePanelHeader)와 같다.
  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final roomName = _room.displayName(_session.userId ?? '');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '공지',
                  maxLines: 1,
                  style: theme.textTheme.titleLarge?.copyWith(height: 1.15),
                ),
                const SizedBox(height: 1),
                Row(
                  children: [
                    Icon(iconForRoomType(_room.type), size: 13, color: hint),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(
                        roomName,
                        key: const ValueKey('announcement-panel-room'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.2,
                          color: hint,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('announcement-panel-close'),
            icon: const Icon(Icons.close),
            tooltip: '닫기',
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  /// 가로 전체 `+ 공지 쓰기` — 투표 패널의 `+ 투표 만들기`와 같은 옅은 회색 둥근 단추. 쓸 수 있는 사람에게만 보인다.
  Widget _writeButton(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: FilledButton.icon(
        key: const ValueKey('announcement-write'),
        onPressed: _write,
        style: FilledButton.styleFrom(
          backgroundColor: scheme.surfaceContainerHighest,
          foregroundColor: scheme.onSurface,
          minimumSize: const Size.fromHeight(44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: theme.textTheme.labelLarge?.copyWith(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        icon: const Icon(Icons.add, size: 20),
        label: const Text(
          '공지 쓰기',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// 작은 글씨 줄 — 왼쪽 `내린 공지 제외` 스위치(스위치 · 글자 — 글자를 눌러도 켜고 끈다, 투표 패널의 `마감된 투표 제외`와
  /// 같다), 오른쪽 `최신 순 / 과거 순` 정렬(투표·할 일 패널의 정렬과 같은 작은 회색 글자와 바로 뜨는 메뉴).
  Widget _optionBar(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(12, _canWrite ? 4 : 8, 12, 6),
      child: Row(
        children: [
          Expanded(child: _excludeSwitch(context, theme)),
          const SizedBox(width: 8),
          PanelSortButton(
            key: const ValueKey('announcement-sort'),
            newestFirst: _newestFirst,
            onChanged: _setNewestFirst,
          ),
        ],
      ),
    );
  }

  /// `내린 공지 제외` — 스위치와 글자.
  Widget _excludeSwitch(BuildContext context, ThemeData theme) {
    return Align(
      alignment: Alignment.centerLeft,
      // 글자와 스위치를 한 마디(켜짐/꺼짐)로 읽게 합친다.
      child: MergeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 작은 스위치 — 누르는 자리 여백을 빼야 모바일·PC에서 같은 크기로 줄어든다.
            SizedBox(
              height: 24,
              child: FittedBox(
                child: Switch(
                  key: const ValueKey('announcement-exclude-unpinned'),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  value: _excludeUnpinned,
                  onChanged: _setExcludeUnpinned,
                ),
              ),
            ),
            const SizedBox(width: 2),
            Flexible(
              child: InkWell(
                key: const ValueKey('announcement-exclude-unpinned-label'),
                onTap: () => _setExcludeUnpinned(!_excludeUnpinned),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 6,
                  ),
                  child: Text(
                    '내린 공지 제외',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 지금 보이는 공지 — `내린 공지 제외`면 고정된 것만, 정렬([_newestFirst])대로. 정렬은 받아 둔 목록을 작성 시각으로만
  /// 줄 세운다 — 고정된 공지를 따로 맨 위로 올리지 않는다(서버 목록도 작성 시각 순이고, 고정은 보통 가장 최근 공지다).
  /// 시각이 같으면 받은 순서(최신 순)를 지키고, 과거 순은 그것을 뒤집는다.
  List<Announcement> _visible(List<Announcement> items) {
    final shown = _excludeUnpinned
        ? items.where((a) => a.pinned).toList()
        : [...items];
    mergeSort<Announcement>(
      shown,
      compare: (a, b) => b.createdAt.compareTo(a.createdAt),
    );
    return _newestFirst ? shown : shown.reversed.toList();
  }

  /// `N개의 공지` — 지금 보이는 개수, 숫자는 굵게. 처음 받기 전에는 개수를 모르므로 같은 높이의 빈 줄만 둔다.
  Widget _countLine(BuildContext context) {
    final theme = Theme.of(context);
    const bold = TextStyle(fontWeight: FontWeight.w700);
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurface,
    );
    final items = _items;
    final Widget line;
    if (items != null) {
      line = Text.rich(
        key: const ValueKey('announcement-list-count'),
        TextSpan(
          children: [
            TextSpan(text: '${_visible(items).length}', style: bold),
            const TextSpan(text: '개의 공지'),
          ],
        ),
        style: style,
      );
    } else {
      line = ExcludeSemantics(
        child: Text.rich(
          const TextSpan(
            children: [
              TextSpan(text: ' ', style: bold),
              TextSpan(text: ' '),
            ],
          ),
          style: style,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: line,
    );
  }

  /// 빈 목록 — 투표 패널처럼 아이콘 · 문구 · 작은 안내.
  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _excludeUnpinned && (_items?.isNotEmpty ?? false);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.campaign_outlined, size: 40, color: theme.hintColor),
            const SizedBox(height: 12),
            Text(
              filtered ? '채팅방에 고정된 공지가 없습니다.' : '등록된 공지가 없습니다.',
              key: const ValueKey('announcement-empty'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 4),
            Text(
              filtered
                  ? '"내린 공지 제외"를 끄면 지난 공지도 보입니다.'
                  : (_canWrite ? '"공지 쓰기"로 첫 공지를 올려 보세요.' : '아직 올라온 공지가 없습니다.'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final error = _error;
    if (error != null && _items == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                error,
                key: const ValueKey('announcement-error'),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _load, child: const Text('다시 시도')),
          ],
        ),
      );
    }
    final items = _items;
    if (items == null) return const Center(child: CircularProgressIndicator());

    // 최신순 목록(받은 순서 — 화면의 정렬과 상관없이)에서 내가 안 쓴 공지 앞에서부터 안 읽은 개수만큼이 안 읽은 공지다
    // (안 읽은 건 항상 마지막으로 연 시각 이후 = 가장 최근 것들이기 때문). 목록을 받기 전에 이미 열어본 것(공지바로 열어
    // 상세가 바로 뜬 공지)은 읽은 것이다.
    final unreadIds = _unreadIds ??= () {
      final ids = <String>{};
      var counted = 0;
      for (final a in items) {
        if (counted >= _unreadTarget) break;
        if (a.authorId == _session.userId) continue;
        counted++;
        if (!_openedBeforeLoad.contains(a.id)) ids.add(a.id);
      }
      return ids;
    }();

    final visible = _visible(items);
    if (visible.isEmpty) return _empty(context);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        key: const ValueKey('announcement-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        itemCount: visible.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          final a = visible[i];
          return _AnnouncementCard(
            key: ValueKey('announcement-tile-${a.id}'),
            session: _session,
            room: _room,
            announcement: a,
            unread: unreadIds.contains(a.id),
            color: _cardColor(context),
            onTap: () => _open(a),
            onMore: (action) => _onCardMore(a, action),
          );
        },
      ),
    );
  }
}

/// 방 없이 열린 공지 패널(PC에서 토픽을 열지 않은 채 열렸을 때) — 머리와 안내만.
class AnnouncementsPanelNoRoom extends StatelessWidget {
  final VoidCallback? onClose;
  const AnnouncementsPanelNoRoom({super.key, this.onClose});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                Expanded(child: Text('공지', style: theme.textTheme.titleLarge)),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '닫기',
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Center(
              child: Text(
                '공지를 볼 토픽을 먼저 여세요.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 공지 카드 — 흰 둥근 카드(투표 패널의 카드와 같은 바탕·모서리)에 작성자 아바타, 위에 "안 읽음"·"고정" 표시, 굵은 본문 앞부분
/// (3줄 말줄임 — 사진만 있는 공지는 "[사진]"), `작성자 · 시각`, 오른쪽에 사진 공지의 작은 썸네일·댓글 수. 안 읽은 공지는
/// 테두리와 옅은 바탕색으로 한 번 더 드러낸다. 지금 채팅방에 고정된 공지에는 "고정" 표시, 내린 공지에는 없다.
///
/// 오른쪽 위 ⋯는 상세의 ⋯와 같은 메뉴·권한([AnnouncementMoreButton] — 할 수 있는 게 없으면 없다)이고, 눌러도 카드는
/// 열리지 않는다. 마우스를 올리면 바탕(흰색)은 그대로 두고 둥근 테두리를 옅은 강조색(1.5)으로 그린다 — 회색 덮개는 목록
/// 바탕의 회색과 헷갈리므로 쓰지 않는다(할 일 카드와 같은 규칙).
class _AnnouncementCard extends StatelessWidget {
  final Session session;
  final Room room;
  final Announcement announcement;
  final VoidCallback onTap;
  final ValueChanged<AnnouncementMoreAction> onMore;
  final bool unread;
  final Color color;
  const _AnnouncementCard({
    super.key,
    required this.session,
    required this.room,
    required this.announcement,
    required this.onTap,
    required this.onMore,
    required this.color,
    this.unread = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final hint = theme.hintColor;
    final author = room.members
        .where((m) => m.id == announcement.authorId)
        .firstOrNull;
    final hasText = announcement.text.trim().isNotEmpty;
    final radius = BorderRadius.circular(12);
    final canMore = announcementMoreActions(session, announcement).isNotEmpty;
    final hasSide =
        canMore || announcement.hasImage || announcement.commentCount > 0;
    return _HoverBuilder(
      builder: (context, hovered) => Material(
        color: unread
            ? Color.alphaBlend(primary.withValues(alpha: 0.06), color)
            : color,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          // 안 읽은 공지는 늘 강조색 테두리. 그 밖의 카드는 마우스를 올렸을 때만 옅은 강조색 테두리 — 바탕은 그대로 둔다
          // (덮개 색을 얹으면 밝은 테마에서 목록 바탕의 회색과 거의 같아져 구분이 안 된다. 할 일 카드와 같은 규칙).
          side: unread
              ? BorderSide(color: primary, width: 1.5)
              : hovered
              ? BorderSide(color: primary.withValues(alpha: 0.55), width: 1.5)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          // 올렸을 때는 덮개 없이 위 테두리만, 누를 때는 옅은 강조색.
          hoverColor: Colors.transparent,
          highlightColor: primary.withValues(alpha: 0.08),
          splashColor: primary.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AvatarView(
                  username: announcement.authorName,
                  avatarType: author?.avatarType ?? 'initial',
                  avatarEmoji: author?.avatarEmoji,
                  avatarColor: author?.avatarColor,
                  avatarUrl: author?.avatarUrl,
                  resolveUrl: session.resolveUrl,
                  radius: 17,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (unread || announcement.pinned)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (unread)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.redAccent,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Text(
                                    '안 읽음',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              if (announcement.pinned) const PinnedPostTag(),
                            ],
                          ),
                        ),
                      // 공지 쓰기 창에서 서식(굵게·제목·글자색 등)을 입혔으면 그대로, 아니면 평문 — 둘 다 3줄까지.
                      if (hasText && announcement.textFormat != null)
                        FormattedText(
                          announcement.text,
                          key: const ValueKey('announcement-tile-text'),
                          format: announcement.textFormat,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            height: 1.4,
                          ),
                        )
                      else
                        Text(
                          hasText
                              ? announcement.text
                              : announcement.previewText,
                          key: const ValueKey('announcement-tile-text'),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            height: 1.4,
                          ),
                        ),
                      const SizedBox(height: 4),
                      Text(
                        '${announcement.authorName} · '
                        '${formatPostDateTime(announcement.createdAt)}',
                        key: const ValueKey('announcement-tile-meta'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: hint),
                      ),
                    ],
                  ),
                ),
                // 오른쪽 — 맨 위 ⋯(할 수 있는 게 있을 때), 사진 공지의 작은 썸네일, 그 아래(또는 혼자) 댓글 수. 아래 줄
                // (작성자·시각)이 잘리지 않게 한 칸에 모았다.
                if (hasSide) ...[
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (canMore)
                        // 단추 칸 여백만큼 카드 모서리 쪽으로 당겨 ⋯가 오른쪽 위 끝에 붙어 보이게.
                        Transform.translate(
                          offset: const Offset(6, -6),
                          child: AnnouncementMoreButton(
                            buttonKey: const ValueKey('announcement-tile-more'),
                            session: session,
                            announcement: announcement,
                            onSelected: onMore,
                            iconSize: 18,
                            iconColor: hint,
                            buttonSize: 28,
                          ),
                        ),
                      if (canMore &&
                          (announcement.hasImage ||
                              announcement.commentCount > 0))
                        const SizedBox(height: 2),
                      if (announcement.hasImage)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: CachedNetworkImage(
                            key: const ValueKey('announcement-tile-thumb'),
                            imageUrl: session.resolveUrl(
                              announcement.imageThumbnailUrl ??
                                  announcement.imageUrl ??
                                  '',
                            ),
                            width: 44,
                            height: 44,
                            fit: BoxFit.cover,
                            placeholder: (_, _) => Container(
                              width: 44,
                              height: 44,
                              color: theme.colorScheme.surfaceContainerHighest,
                            ),
                            errorWidget: (_, _, _) => Container(
                              width: 44,
                              height: 44,
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: Icon(Icons.image_outlined, color: hint),
                            ),
                          ),
                        ),
                      if (announcement.hasImage &&
                          announcement.commentCount > 0)
                        const SizedBox(height: 6),
                      if (announcement.commentCount > 0)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.mode_comment_outlined,
                              size: 14,
                              color: hint,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              '${announcement.commentCount}',
                              style: TextStyle(fontSize: 12, color: hint),
                            ),
                          ],
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 마우스가 올라와 있는지([builder]의 `hovered`)를 알려 주는 작은 감싸개 — 공지 카드의 올렸을 때 테두리.
class _HoverBuilder extends StatefulWidget {
  final Widget Function(BuildContext context, bool hovered) builder;
  const _HoverBuilder({required this.builder});

  @override
  State<_HoverBuilder> createState() => _HoverBuilderState();
}

class _HoverBuilderState extends State<_HoverBuilder> {
  bool _hovered = false;

  void _set(bool v) {
    if (v != _hovered) setState(() => _hovered = v);
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => _set(true),
    onExit: (_) => _set(false),
    child: widget.builder(context, _hovered),
  );
}
