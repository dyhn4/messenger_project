import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/app_notification.dart';
import '../models/project.dart' show ProjectNotification;
import '../models/room.dart';
import '../screens/announcement_detail_screen.dart';
import '../screens/announcement_list_screen.dart';
import '../screens/chat_screen.dart';
import '../screens/home_screen.dart' show wideBreakpoint;
import '../screens/project/project_dialog.dart' show showProjectDialog;
import '../screens/project/project_notifications.dart'
    show ProjectNotificationTile;
import '../screens/project/project_window.dart' show openProjectWindow;
import '../services/app_links.dart';
import '../services/notification_controller.dart';
import '../services/notification_entries.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import 'app_toast.dart';
import 'compact_menu_anchor.dart';
import 'muted_scrollbar.dart';
import 'notification_settings_dialog.dart';
import 'room_avatar.dart';
import 'team_avatar.dart';
import 'unread_badge.dart';

/// 알림 센터에서 안 읽은 "공지"가 있는 방을 눌러 열었을 때, 공지 목록을 팝업으로 함께 띄운다
/// (안 읽은 공지에는 "안 읽음" 표시가 붙고, 하나를 눌러 상세를 본 뒤 뒤로 가면 이 목록으로 돌아온다).
/// 안 읽은 공지가 하나뿐이고 그게 지금 고정된 공지면 목록 대신 그 공지의 상세보기를 바로 연다.
/// 방만 열면 공지를 실제로 열어본 적이 없어서(session.markAnnouncementsRead는 공지 목록/상세를
/// 열 때만 호출된다) 알림 센터에 계속 "안 읽음"으로 남기 때문이다. [hadUnreadAnnouncement]는
/// 방을 열기 "전"의 값이어야 한다.
void showUnreadAnnouncementPopup(
  BuildContext context,
  Session session,
  Room room, {
  required bool hadUnreadAnnouncement,
}) {
  if (!hadUnreadAnnouncement || !context.mounted) return;
  // 목록을 여는 순간 읽음 처리되어 개수가 0이 되므로 그 전에 값을 잡아둔다.
  final unreadCount = math.max(1, room.unreadAnnouncementCount);
  // 안 읽은 공지가 하나뿐이고 그게 지금 고정된 공지면 목록을 거치지 않고 상세보기를 바로 연다.
  final latest = room.latestAnnouncement;
  if (unreadCount == 1 && latest != null && latest.authorId != session.userId) {
    showAnnouncementDetailScreen(context, session, room, latest);
    return;
  }
  showAnnouncementListScreen(context, session, room, unreadCount: unreadCount);
}

/// 상단 툴바의 종 모양 "알림 센터" 버튼 — 볼 알림이 하나라도 있으면(안 읽은 대화·멘션·보드·프로젝트 알림)
/// 오른쪽 위에 작은 빨간 점을 얹는다. desktop_home_screen.dart의 넓은 화면 툴바와
/// team_select_screen.dart의 "팀 리스트" 화면이 같이 쓴다.
class NotificationBellButton extends StatelessWidget {
  final Session session;
  final VoidCallback onPressed;
  const NotificationBellButton({
    super.key,
    required this.session,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // session이 바뀔 때마다(새 메시지로 unreadCount 증감 등) 이 아이콘만 다시 그린다 —
    // 호출부가 매번 setState 해주지 않아도 항상 최신 상태를 보여준다. 멘션·보드 안 읽음 개수는
    // 알림 센터 컨트롤러가 따로 들고 있어서 같이 듣는다.
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.notificationCenter]),
      builder: (context, _) => IconButton(
        icon: Badge(
          isLabelVisible:
              session.unreadRooms.isNotEmpty ||
              session.notificationCenter.totalUnread > 0 ||
              session.projectUnread > 0,
          // 방 목록의 안읽음 숫자 뱃지(UnreadBadge)와 같은 빨강으로 맞춘다.
          backgroundColor: Colors.redAccent,
          smallSize: 7,
          // 기본 위치(topEnd 모서리)에 딱 붙이면 종 모양 테두리와 겹쳐 보여서, 오른쪽
          // 위로 살짝 더 밀어낸다.
          offset: const Offset(4, -4),
          child: const Icon(Icons.notifications_outlined),
        ),
        tooltip: '알림 센터',
        onPressed: onPressed,
      ),
    );
  }
}

/// 알림 센터에서 방(과 메시지)을 열어 달라는 요청 — 호출한 화면이 그 방으로 간다. [messageId]가 있으면(멘션·보드
/// 알림) 그 메시지로 스크롤·강조하고, [announcementPopup]이면 안 읽은 공지 목록도 띄운다(안 읽은 대화·공지 줄).
typedef NotificationRoomOpener =
    void Function(Room room, {String? messageId, bool announcementPopup});

/// 프로젝트 알림을 눌렀을 때 그 프로젝트(업무)를 여는 기본 방법 — Windows는 독립된 프로젝트 창(업무 알림이면
/// 그 업무까지), 그 밖(안드로이드)은 프로젝트 대화상자. 종 모양 프로젝트 알림함(ProjectNotificationsBell)은
/// 프로젝트 창 안에서 열리므로 여기와 별개로 그 프로젝트 화면으로 이동한다.
void openProjectFromNotification(
  BuildContext context,
  Session session,
  ProjectNotification n,
) {
  final taskId = n.taskId;
  final link = taskId == null
      ? null
      : AppLinks.task(
          id: taskId,
          title: n.title.isNotEmpty ? n.title : (n.projectName ?? '업무'),
          project: n.projectName,
          color: n.projectColor,
        );
  if (Platform.isWindows) {
    unawaited(openProjectWindow(session, openLink: link));
    return;
  }
  if (link != null) AppLinks.requestOpen(link);
  unawaited(
    showProjectDialog(
      context,
      session,
    ).whenComplete(() => AppLinks.request.value = null),
  );
}

/// "알림 센터" 패널 — 검색/멤버 패널과 같은 틀(헤더+목록)에 탭 다섯 개를 얹었다:
/// `전체 | 멘션 | 메시지 | 보드·공지 | 프로젝트`. 여러 팀에 걸쳐(지금 보고 있는 팀 포함) 모아 보여 준다.
/// 탭마다 안 읽음 배지, 상단에 "안 읽은 것만" 필터와 "모두 읽음", 헤더 톱니에 알림 설정이 있다.
/// desktop_home_screen.dart는 이걸 우측 사이드 패널로, team_select_screen.dart·모바일은
/// [showNotificationsCenterDialog]로 띄운다 — 헤더/닫기 버튼을 이 위젯이 스스로 그리므로 둘 다 그대로 쓴다.
///
/// 기본으로 열리는 탭은 안 읽은 멘션이 있으면 `멘션`, 아니면 `전체`([initialTab]으로 정할 수도 있다).
class NotificationsPanel extends StatefulWidget {
  final Session session;
  final VoidCallback onClose;
  final NotificationRoomOpener onSelectRoom;

  /// 처음 열 탭 — 없으면 위 기본 규칙.
  final NotificationTab? initialTab;

  /// 프로젝트 알림을 눌렀을 때 — 없으면 [openProjectFromNotification].
  final void Function(ProjectNotification n)? onOpenProject;

  const NotificationsPanel({
    super.key,
    required this.session,
    required this.onClose,
    required this.onSelectRoom,
    this.initialTab,
    this.onOpenProject,
  });

  @override
  State<NotificationsPanel> createState() => _NotificationsPanelState();
}

class _NotificationsPanelState extends State<NotificationsPanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _scroll = ScrollController();
  late NotificationTab _lastTab;

  NotificationController get _center => widget.session.notificationCenter;
  NotificationTab get _tab => NotificationTab.values[_tabs.index];

  @override
  void initState() {
    super.initState();
    final initial =
        widget.initialTab ??
        (_center.mentionUnread(_center.mentionFilter) > 0
            ? NotificationTab.mention
            : NotificationTab.all);
    _lastTab = initial;
    // 탭을 바꿀 때 미끄러지는 효과는 두지 않는다 — 내용은 TabBarView가 아니라 고른 탭 하나만 그린다.
    _tabs = TabController(
      length: NotificationTab.values.length,
      vsync: this,
      initialIndex: initial.index,
      animationDuration: Duration.zero,
    )..addListener(_onTabChanged);
    _scroll.addListener(_onScroll);
    // 컨트롤러는 받기 시작할 때 바로 알리는데(로딩 표시), 그 알림이 이 패널을 만드는 빌드 중에 나가면 같은
    // 컨트롤러를 듣는 종 모양 버튼 등이 "빌드 중 setState" 오류를 낸다 — 첫 프레임이 끝난 뒤에 받기 시작한다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_center.refreshCounts());
      _load(_tab);
    });
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _load(NotificationTab tab) {
    if (tab == NotificationTab.project && !widget.session.canUseProjects) {
      return;
    }
    unawaited(_center.ensureLoaded(tab));
  }

  void _onTabChanged() {
    final tab = _tab;
    if (tab == _lastTab) return;
    _lastTab = tab;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load(tab);
    if (mounted) setState(() {});
  }

  /// 멘션 탭 꺾쇠를 눌러 메뉴가 열릴 때 — 다른 탭을 보고 있었으면 멘션 탭으로 옮겨 간다.
  void _onMentionMenuOpened() {
    if (_tab != NotificationTab.mention) {
      _tabs.index = NotificationTab.mention.index;
    }
  }

  /// 멘션 탭 필터(전체 멘션 / @나를 멘션 / @all 멘션)를 골랐다 — 새 종류의 목록을 맨 위부터 보여 준다.
  void _selectMentionFilter(MentionFilter filter) {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    unawaited(_center.setMentionFilter(filter));
  }

  /// 끝에 가까워지면 다음 페이지를 붙인다(멘션·보드·전체 탭의 무한 스크롤).
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final tab = _tab;
    if (_scroll.position.extentAfter < 240 &&
        _center.hasMore(tab) &&
        !_center.isLoading(tab)) {
      unawaited(_center.loadMore(tab));
    }
  }

  /// 받은 목록이 화면을 다 못 채웠는데 더 있으면 이어서 받는다(스크롤할 길이가 없으면 스크롤 이벤트가 없다).
  void _fillIfShort() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final tab = _tab;
      if (_scroll.position.maxScrollExtent <= 0 &&
          _center.hasMore(tab) &&
          !_center.isLoading(tab)) {
        unawaited(_center.loadMore(tab));
      }
    });
  }

  // ---- 눌렀을 때 ----

  void _openServer(AppNotification n) {
    unawaited(_center.markRead(n));
    final room = n.roomId == null ? null : widget.session.roomById(n.roomId!);
    if (room == null) {
      showAppToast(context, '더 이상 볼 수 없는 대화입니다.');
      return;
    }
    widget.onSelectRoom(room, messageId: n.messageId, announcementPopup: false);
  }

  Future<void> _openProject(ProjectNotification n) async {
    if (!n.read) {
      try {
        await _center.markProjectRead(ids: [n.id]);
        await widget.session.refreshProjectUnread();
      } catch (_) {
        // 읽음 표시가 실패해도 이동은 한다.
      }
    }
    if (!mounted) return;
    final open = widget.onOpenProject;
    if (open != null) {
      open(n);
    } else {
      openProjectFromNotification(context, widget.session, n);
    }
  }

  Future<void> _markAllRead() async {
    final session = widget.session;
    final tab = _tab;
    // 메시지 탭에 보이는 방만 읽음 처리한다 — 멘션만 안 읽은 방은 멘션 탭 몫이다(isUnreadChatRoom).
    final chatRooms = [
      for (final r in session.unreadRooms)
        if ((tab == NotificationTab.unreadChats &&
                (isUnreadChatRoom(r) || r.hasUnreadAnnouncement)) ||
            (tab == NotificationTab.all && isUnreadChatRoom(r)))
          r,
    ];
    if (chatRooms.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('모두 읽음'),
          content: Text('안 읽은 대화 ${chatRooms.length}개를 읽음으로 표시할까요?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('읽음으로 표시'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    try {
      // 서버 알림(멘션·보드)과 프로젝트 알림.
      await _center.markAllRead(tab);
      if (tab == NotificationTab.all || tab == NotificationTab.project) {
        if (session.canUseProjects) {
          await _center.markProjectRead();
          await session.refreshProjectUnread();
        }
      }
    } catch (e) {
      if (mounted) showAppToast(context, '읽음 처리하지 못했습니다: $e');
    }
    // 방 쪽 — 안 읽은 공지(보드·공지·전체 탭)와 안 읽은 대화.
    if (tab == NotificationTab.board || tab == NotificationTab.all) {
      for (final r in session.unreadRooms) {
        if (r.hasUnreadAnnouncement) session.markAnnouncementsRead(r);
      }
    }
    for (final r in chatRooms) {
      session.markRoomReadWithoutOpening(r);
    }
  }

  // ---- 그리기 ----

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    // ColoredBox가 아니라 Material — 줄(InkWell·ListTile)의 눌림 효과가 이 바탕 위에 그려져야 보인다.
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: ListenableBuilder(
        // 안읽음 수가 실시간으로 바뀔 때마다(새 메시지 수신, 다른 곳에서 읽음 처리 등) 목록을 다시
        // 그린다 — _MembersPanel의 onlineUserIds 갱신과 같은 이유.
        listenable: Listenable.merge([session, _center]),
        builder: (context, _) {
          final tab = _tab;
          final unreadRooms = session.unreadRooms;
          final entries = buildCenterEntries(
            tab: tab,
            center: _center,
            unreadRooms: unreadRooms,
          );
          int badge(NotificationTab t) => notificationTabBadge(
            t,
            center: _center,
            unreadRooms: unreadRooms,
            projectUnread: session.projectUnread,
          );
          _fillIfShort();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 4, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '알림 센터',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('notif-settings'),
                      icon: const Icon(Icons.settings_outlined),
                      tooltip: '알림 설정',
                      onPressed: () =>
                          showNotificationSettingsDialog(context, session),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: widget.onClose,
                    ),
                  ],
                ),
              ),
              // 제목 줄과 탭 사이의 구분선.
              const Divider(key: ValueKey('notif-title-divider'), height: 1),
              // 탭 다섯 개는 좁은 폭(360dp)에 다 안 들어가서 가로로 스크롤된다 — 고른 탭은 자동으로 보이는 쪽으로.
              TabBar(
                key: const ValueKey('notif-tabs'),
                controller: _tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                dividerHeight: 1,
                labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                tabs: [
                  for (final t in NotificationTab.values)
                    Tab(
                      key: ValueKey('notif-tab-${t.name}'),
                      height: 44,
                      child: t == NotificationTab.mention
                          // 멘션 탭만 이름 오른쪽에 꺾쇠(드롭다운)가 붙는다 — 탭 이름은 고른 종류를 짧게 반영한다.
                          ? _TabLabel(
                              label: _center.mentionFilter.tabLabel,
                              count: badge(t),
                              trailing: _MentionFilterButton(
                                filter: _center.mentionFilter,
                                onOpened: _onMentionMenuOpened,
                                onSelected: _selectMentionFilter,
                              ),
                            )
                          : _TabLabel(label: t.label, count: badge(t)),
                    ),
                ],
              ),
              _buildToolbar(context, tab, badge(tab)),
              const Divider(height: 1),
              Expanded(child: _buildBody(context, tab, entries)),
            ],
          );
        },
      ),
    );
  }

  /// 탭 아래 줄 — "모두 읽음". "안 읽은 알림만 표시"는 탭마다 알림 설정(톱니)에서 정한다.
  Widget _buildToolbar(BuildContext context, NotificationTab tab, int unread) {
    final hasUnread = tab == NotificationTab.unreadChats
        ? unread > 0
        : unread > 0 ||
              (tab == NotificationTab.project &&
                  _center.project.any((n) => !n.read));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(
        children: [
          const Spacer(),
          TextButton(
            key: const ValueKey('notif-read-all'),
            onPressed: hasUnread ? _markAllRead : null,
            child: const Text('모두 읽음'),
          ),
        ],
      ),
    );
  }

  String _emptyText(NotificationTab tab) {
    if (_center.unreadOnly(tab)) return '안 읽은 알림이 없습니다.';
    return switch (tab) {
      NotificationTab.all => '새 알림이 없습니다.',
      NotificationTab.mention => switch (_center.mentionFilter) {
        MentionFilter.all => '멘션 알림이 없습니다.',
        MentionFilter.personal => '나를 멘션한 알림이 없습니다.',
        MentionFilter.everyone => '@all 멘션 알림이 없습니다.',
      },
      NotificationTab.unreadChats => '안 읽은 메시지가 없습니다.',
      NotificationTab.board => '보드·공지 알림이 없습니다.',
      NotificationTab.project => '프로젝트 알림이 없습니다.',
    };
  }

  Widget _buildBody(
    BuildContext context,
    NotificationTab tab,
    List<CenterEntry> entries,
  ) {
    final hint = Theme.of(context).hintColor;
    final loading = _center.isLoading(tab);
    final error = _center.errorFor(tab);
    if (entries.isEmpty) {
      if (loading && !_center.isLoaded(tab)) {
        return const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      }
      if (error != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(error, textAlign: TextAlign.center),
                TextButton(
                  onPressed: () => _center.refresh(tab),
                  child: const Text('다시 시도'),
                ),
              ],
            ),
          ),
        );
      }
      return Center(
        child: Text(_emptyText(tab), style: TextStyle(color: hint)),
      );
    }
    final footer = loading && _center.isLoaded(tab);
    return MutedScrollbar(
      controller: _scroll,
      child: ListView.separated(
        key: ValueKey('notif-list-${tab.name}'),
        controller: _scroll,
        itemCount: entries.length + (footer ? 1 : 0),
        separatorBuilder: (_, _) => const Padding(
          padding: EdgeInsets.only(right: 12),
          child: Divider(height: 1),
        ),
        itemBuilder: (context, i) {
          if (i >= entries.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          return _entryRow(entries[i]);
        },
      ),
    );
  }

  Widget _entryRow(CenterEntry e) {
    final session = widget.session;
    return switch (e) {
      ServerEntry(:final notification) => _ServerNotificationRow(
        key: ValueKey('notif-${notification.id}'),
        session: session,
        notification: notification,
        onTap: () => _openServer(notification),
      ),
      RoomEntry(:final room) => _NotificationRow(
        session: session,
        room: room,
        onTap: () => widget.onSelectRoom(room, announcementPopup: true),
      ),
      AnnouncementEntry(:final room) => _AnnouncementRow(
        key: ValueKey('notif-announcement-${room.id}'),
        session: session,
        room: room,
        onTap: () => widget.onSelectRoom(room, announcementPopup: true),
      ),
      ProjectEntry(:final notification) => ProjectNotificationTile(
        key: ValueKey('notif-project-${notification.id}'),
        notification: notification,
        onTap: () => _openProject(notification),
      ),
    };
  }
}

/// 멘션 탭 이름 옆 꺾쇠(⌄) — 누르면 탭 바로 아래에 설정 메뉴와 같은 모양의 드롭다운이 열려 `전체 멘션` /
/// `@나를 멘션` / `@all 멘션` 중 하나를 고른다(고른 것에 체크). 탭 자체를 누르는 동작(탭 전환)과 겹치지 않게
/// 이 단추가 자기 영역의 탭을 따로 받는다.
class _MentionFilterButton extends StatelessWidget {
  final MentionFilter filter;
  final VoidCallback onOpened;
  final ValueChanged<MentionFilter> onSelected;
  const _MentionFilterButton({
    required this.filter,
    required this.onOpened,
    required this.onSelected,
  });

  /// 메뉴를 연다 — 다른 탭에 있었으면 먼저 멘션 탭으로 옮긴다([onOpened]). 탭 줄이 가로 스크롤이라 옮기면서 멘션 탭 쪽으로
  /// 굴러가는 중이면, 메뉴(MenuAnchor)는 위쪽 스크롤이 움직이면 닫히므로 다 굴러간 뒤에 연다.
  void _open(BuildContext context, VoidCallback toggle) {
    onOpened();
    final scrolling = Scrollable.maybeOf(context)?.position.isScrollingNotifier;
    if (scrolling == null || !scrolling.value) {
      toggle();
      return;
    }
    void whenStopped() {
      if (scrolling.value) return;
      scrolling.removeListener(whenStopped);
      // 같은 알림을 받는 메뉴 쪽 "스크롤되면 닫기"가 먼저 끝나도록 한 박자 뒤에.
      scheduleMicrotask(() {
        if (context.mounted) toggle();
      });
    }

    scrolling.addListener(whenStopped);
  }

  @override
  Widget build(BuildContext context) {
    return CompactMenuAnchor<MentionFilter>(
      // 항목이 짧아(`@all 멘션` 등) 설정 메뉴 폭(180~)이면 휑하다 — 글자에 맞게 좁힌다.
      itemMinWidth: 124,
      menuMinWidth: 124,
      maxWidth: 160,
      gap: 0,
      selected: filter,
      onSelected: onSelected,
      entries: [
        for (final f in MentionFilter.values)
          CompactMenuOption(
            key: ValueKey('notif-mention-filter-${f.name}'),
            value: f,
            label: f.menuLabel,
          ),
      ],
      // 탭 높이(44)만큼 세로로 길게 잡아 손가락으로도 누르기 쉽고, 메뉴가 탭 줄 바로 아래에서 열린다.
      builder: (context, open, toggle) => Semantics(
        expanded: open,
        child: Tooltip(
          message: '멘션 종류',
          child: InkWell(
            key: const ValueKey('notif-mention-filter'),
            onTap: () => open ? toggle() : _open(context, toggle),
            child: SizedBox(
              width: 26,
              height: 44,
              child: Center(
                child: Icon(
                  Icons.keyboard_arrow_down,
                  size: 18,
                  color: DefaultTextStyle.of(context).style.color,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 탭 이름 + (있으면) 오른쪽 위젯 + 안 읽음 숫자 배지(0이면 숫자 없음).
class _TabLabel extends StatelessWidget {
  final String label;
  final int count;
  final Widget? trailing;
  const _TabLabel({required this.label, required this.count, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        ?trailing,
        if (count > 0) ...[
          const SizedBox(width: 4),
          Container(
            key: ValueKey('notif-tab-badge-$label'),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            constraints: const BoxConstraints(minWidth: 16),
            decoration: BoxDecoration(
              color: Colors.redAccent,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              count > 99 ? '99+' : '$count',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                height: 1.3,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 줄 왼쪽의 팀 칸 — 여러 팀 알림이 한 목록에 섞이므로 어느 팀인지 한눈에 구분돼야 한다(팀 아바타 + 이름).
/// 방 아바타와 겹치지 않게 완전히 별도 칸으로 둔다.
class _TeamColumn extends StatelessWidget {
  final Session session;
  final String teamId;
  final String? fallbackName;
  const _TeamColumn({
    required this.session,
    required this.teamId,
    this.fallbackName,
  });

  static const width = 44.0;

  @override
  Widget build(BuildContext context) {
    final team = session.teams.where((t) => t.id == teamId).firstOrNull;
    final hint = Theme.of(context).hintColor;
    final nameStyle = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: hint, fontSize: 10);
    return SizedBox(
      width: width,
      child: team != null
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TeamAvatar(
                  team: team,
                  resolveUrl: session.resolveUrl,
                  size: 32,
                ),
                const SizedBox(height: 2),
                Text(
                  team.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: nameStyle,
                ),
              ],
            )
          : (fallbackName == null
                ? null
                : Text(
                    fallbackName!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: nameStyle,
                  )),
    );
  }
}

/// 안 읽은 표시(빨간 점) — 읽은 알림은 그 자리를 비워 둔다.
class _UnreadDot extends StatelessWidget {
  const _UnreadDot();

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: const BoxDecoration(
      color: Colors.redAccent,
      shape: BoxShape.circle,
    ),
  );
}

/// 멘션·보드 알림 한 줄: [팀 칸] [종류 아이콘] [방 이름 · 시각 / 보낸 사람·미리보기 · 안 읽음 점].
class _ServerNotificationRow extends StatelessWidget {
  final Session session;
  final AppNotification notification;
  final VoidCallback onTap;
  const _ServerNotificationRow({
    super.key,
    required this.session,
    required this.notification,
    required this.onTap,
  });

  IconData get _icon => switch (notification.kind) {
    NotificationKind.mention => Icons.alternate_email,
    // @all도 개인 멘션과 같은 @ 아이콘 — 알림 센터에서 "멘션"은 한 가지 아이콘으로 읽힌다.
    NotificationKind.mentionAll => Icons.alternate_email,
    NotificationKind.boardPost => Icons.dashboard_outlined,
    NotificationKind.boardEdit => Icons.edit_note,
    NotificationKind.boardComment => Icons.mode_comment_outlined,
    NotificationKind.other => Icons.notifications_none,
  };

  /// 두 번째 줄 — "보낸 사람: 미리보기"(멘션·새 글), "작성자 · 수정: 미리보기"(글 수정), "작성자 · 댓글: 미리보기"
  /// (serverNotificationSummary). 앞부분(이름·꼬리표)은 굵게.
  Widget _summaryText(BuildContext context, bool read) {
    final (:lead, :body) = serverNotificationSummary(notification);
    final theme = Theme.of(context);
    return Text.rich(
      TextSpan(
        children: [
          if (lead.isNotEmpty) ...[
            TextSpan(
              text: lead,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const TextSpan(text: ': '),
          ],
          TextSpan(text: body),
        ],
      ),
      key: const ValueKey('notif-server-summary'),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        color: read ? theme.hintColor : null,
        fontWeight: read ? FontWeight.normal : FontWeight.w500,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = notification;
    final read = n.isRead;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TeamColumn(
            session: session,
            teamId: n.teamId,
            fallbackName: n.teamName,
          ),
          const SizedBox(width: 10),
          CircleAvatar(
            radius: 16,
            backgroundColor: theme.colorScheme.primary.withValues(
              alpha: read ? 0.08 : 0.16,
            ),
            child: Icon(
              _icon,
              size: 17,
              color: read ? theme.hintColor : theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        n.roomName ?? '(볼 수 없는 대화)',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: read
                              ? theme.hintColor
                              : theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      formatRoomActivityTime(n.createdAt),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.hintColor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _summaryText(context, read)),
                    if (!read) ...[
                      const SizedBox(width: 8),
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: _UnreadDot(),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return InkWell(onTap: onTap, child: content);
  }
}

/// 안 읽은 공지 한 줄(보드·공지, 전체 탭) — 공지가 있는 방과 공지 내용.
class _AnnouncementRow extends StatelessWidget {
  final Session session;
  final Room room;
  final VoidCallback onTap;
  const _AnnouncementRow({
    super.key,
    required this.session,
    required this.room,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final announcement = room.latestAnnouncement;
    final time = announcement?.createdAt ?? room.lastActivityAt;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _TeamColumn(session: session, teamId: room.teamId),
            const SizedBox(width: 10),
            CircleAvatar(
              radius: 16,
              backgroundColor: theme.colorScheme.primary.withValues(
                alpha: 0.16,
              ),
              child: Icon(
                Icons.campaign_outlined,
                size: 17,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          room.displayName(session.userId ?? ''),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatRoomActivityTime(time),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          '공지 · ${announcement?.previewText ?? '새 공지가 있습니다'}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: _UnreadDot(),
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

/// 메시지 탭 줄의 미리보기 — 그룹채팅·토픽은 보낸 사람 이름을 굵게 앞에 붙인다([roomPreviewLine]과 같은 규칙).
Widget _previewText(BuildContext context, Room room) {
  final style = Theme.of(context).textTheme.bodySmall;
  final line = roomPreviewLine(room);
  final sender = room.lastMessageSenderName;
  final withSender =
      sender != null && sender.isNotEmpty && line.startsWith('$sender: ');
  if (!withSender) {
    return Text(
      line,
      key: const ValueKey('notif-row-preview'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }
  return Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: sender,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        TextSpan(text: line.substring(sender.length)),
      ],
    ),
    key: const ValueKey('notif-row-preview'),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: style,
  );
}

/// 알림 센터 "메시지" 탭(예전 "안 읽은 대화") 한 줄: [팀 아바타(+팀 이름)] [방 아바타] [방 이름 · 시각 / 미리보기 · 안읽음 수].
/// 팀 아바타는 방 아바타와 겹치지 않게 완전히 별도 칸으로 왼쪽에 둔다 — 여러 팀 알림이 한
/// 목록에 섞이므로 어느 팀인지 한눈에 구분돼야 한다(검색 결과 행과 같은 뼈대에 이 칸만 더함).
class _NotificationRow extends StatelessWidget {
  final Session session;
  final Room room;
  final VoidCallback onTap;
  const _NotificationRow({
    required this.session,
    required this.room,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final team = session.teams.where((t) => t.id == room.teamId).firstOrNull;
    const teamColumnWidth = 44.0;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: teamColumnWidth,
              child: team == null
                  ? null
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TeamAvatar(
                          team: team,
                          resolveUrl: session.resolveUrl,
                          size: 32,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          team.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Theme.of(context).hintColor,
                                fontSize: 10,
                              ),
                        ),
                      ],
                    ),
            ),
            const SizedBox(width: 10),
            RoomAvatar(
              room: room,
              myUserId: session.userId ?? '',
              resolveUrl: session.resolveUrl,
              onlineUserIds: session.onlineUserIds,
              size: 32,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          room.displayName(session.userId ?? ''),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatRoomActivityTime(room.lastActivityAt),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        // 안 읽은 공지가 있으면 그게 이 방이 여기 뜬 이유이므로 그 내용을
                        // 우선 보여준다 — 예전엔 이 자리에 항상 "마지막 채팅 내용"만 보여줘서
                        // 메시지는 다 읽었고 공지만 안 읽은 경우에도 엉뚱한 채팅 미리보기가
                        // 뜨는 문제가 있었다.
                        child: room.hasUnreadAnnouncement
                            ? Row(
                                children: [
                                  Icon(
                                    Icons.campaign_outlined,
                                    size: 14,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      room.latestAnnouncement?.previewText ??
                                          '새 공지가 있습니다',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            : _previewText(context, room),
                      ),
                      const SizedBox(width: 8),
                      // 안 읽은 멘션이 있으면 안읽음 숫자 옆에 "@"를 붙인다(방 목록과 같다).
                      if (room.unreadMentionCount > 0) ...[
                        const MentionMarker(),
                        const SizedBox(width: 4),
                      ],
                      // 안 읽은 공지도 개수대로 배지에 합산한다 — 전엔 room.unreadCount(메시지만)만
                      // 써서 공지만 안 읽었을 땐 0으로 떴고, 그 뒤엔 공지가 몇 개든 1로만 셌다.
                      UnreadBadge(
                        count:
                            room.unreadCount +
                            (room.hasUnreadAnnouncement
                                ? math.max(1, room.unreadAnnouncementCount)
                                : 0),
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

/// 알림 센터를 연다 — 넓은 화면은 가운데 뜨는 대화상자(team_select_screen.dart("팀 리스트" 화면)는
/// desktop_home_screen.dart처럼 옆으로 붙는 사이드 패널 자리가 없다), 좁은(모바일) 화면은 탭 다섯 개가
/// 잘리지 않게 전체 화면으로. 방을 고르면 그 방이 속한 팀으로 전환한 뒤(넓은 화면은
/// Session.requestOpenRoom으로 DesktopHomeScreen이 이어서 펼쳐 보여줌) 그 방을 연다.
/// 좁은 화면은 requestOpenRoom만으로는 안 열린다 — RoomListScreen(좁은 화면의 홈)은
/// message_bubble.dart의 프로필 대화상자 등과 마찬가지로 requestOpenRoom의 "대기 중인 방"을
/// 소비하지 않고 항상 직접 push된 ChatScreen으로만 열리므로, 여기서도 같은 패턴대로 직접
/// push한다(멘션·보드 알림이면 그 메시지로 스크롤·강조).
Future<void> showNotificationsCenterDialog(
  BuildContext context,
  Session session, {
  NotificationTab? initialTab,
}) {
  final narrow = MediaQuery.sizeOf(context).width < wideBreakpoint;

  void openRoom(Room room, {String? messageId, bool announcementPopup = true}) {
    final hadUnreadAnnouncement = room.hasUnreadAnnouncement;
    if (!narrow) {
      session.requestOpenRoom(room, messageId: messageId);
    } else {
      // 좁은 화면에서도 다른 팀의 방일 수 있으니 팀 전환만 requestOpenRoom에 맡기고
      // (내부적으로 currentTeam만 바꿔줌 — _pendingOpenRoom은 이 경로에서 안 쓰임),
      // 화면 전환 자체는 직접 push한다.
      session.requestOpenRoom(room);
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
    if (announcementPopup) {
      showUnreadAnnouncementPopup(
        context,
        session,
        room,
        hadUnreadAnnouncement: hadUnreadAnnouncement,
      );
    }
  }

  if (narrow) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (routeContext) => Scaffold(
          body: SafeArea(
            child: NotificationsPanel(
              session: session,
              initialTab: initialTab,
              onClose: () => Navigator.of(routeContext).pop(),
              onSelectRoom: (room, {messageId, announcementPopup = true}) {
                Navigator.of(routeContext).pop();
                openRoom(
                  room,
                  messageId: messageId,
                  announcementPopup: announcementPopup,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      // 폭을 고정하면(SizedBox) 좁은 폰 화면에서 Dialog의 기본 insetPadding(좌우 40씩)보다
      // 넓어져 넘친다 — FloatingDialog와 같은 방식으로 최댓값만 주고 좁은 화면에서는
      // 알아서 줄어들게 한다.
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 640),
        child: NotificationsPanel(
          session: session,
          initialTab: initialTab,
          onClose: () => Navigator.of(dialogContext).pop(),
          onSelectRoom: (room, {messageId, announcementPopup = true}) {
            Navigator.of(dialogContext).pop();
            openRoom(
              room,
              messageId: messageId,
              announcementPopup: announcementPopup,
            );
          },
        ),
      ),
    ),
  );
}
