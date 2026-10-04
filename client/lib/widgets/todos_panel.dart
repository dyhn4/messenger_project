import 'dart:async';

import 'package:flutter/material.dart';

import '../models/room.dart';
import '../models/todo.dart';
import '../screens/todo_detail_dialog.dart';
import '../screens/todo_editor_dialog.dart';
import '../services/session.dart';
import '../services/todo_api.dart';
import '../services/todo_controller.dart';
import 'app_toast.dart';
import 'compact_menu.dart';
import 'filter_dropdown.dart';
import 'home_shell_scope.dart';
import 'panel_filters.dart';
import 'todo_calendar_view.dart';
import 'todo_widgets.dart';

/// 할 일 목록·일정 화면 아래쪽의 옅은 회색 바탕 — 그 위에 [todoCardColor] 카드가 떠 보인다(잔디). 어두운 테마는 위쪽
/// (surface)보다 바탕을 한 단계, 카드를 두 단계 밝게 둬 층이 구분되게 한다.
Color todoListBackgroundColor(BuildContext context) {
  final theme = Theme.of(context);
  return theme.brightness == Brightness.dark
      ? theme.colorScheme.surfaceContainerLow
      : theme.colorScheme.surfaceContainer;
}

/// 할 일 카드(목록 카드·일정 화면의 대화방 묶음) 바탕 — 밝은 테마는 패널 바탕(surface)과 같은 흰색.
Color todoCardColor(BuildContext context) {
  final theme = Theme.of(context);
  return theme.brightness == Brightness.dark
      ? theme.colorScheme.surfaceContainerHigh
      : theme.colorScheme.surface;
}

/// 할 일 패널(side_panels.dart의 'todos') — 잔디의 할 일 목록 화면과 같다. 위에서부터 머리(`할 일` 바로 옆 작은 회색
/// `할 일 일정` 칩, 오른쪽 끝 ✕), 가로 전체 `+ 할 일 생성`, 필터 줄(참여한 대화방 · 보기 — 모든 할 일 / 나의 할 일 /
/// 부여한 할 일 · 부여한 할 일이면 담당 멤버), 정렬(생성 순 / 기한 순)과 `완료된 할 일 제외` 스위치, 그 아래 옅은 회색
/// 바탕에 `N개의 할 일`(서버가 센 전체 개수)과 카드 목록(무한 스크롤)이다. 카드는 보기만 하고, 누르면 상세가 열린다.
///
/// PC 오른쪽 칸(홈 셸 아래)에서는 패널 안에 Navigator를 따로 두고 목록을 첫 화면으로 삼아, 상세·생성·수정·할 일 일정을
/// 패널 안 화면(머리 `← 할 일 … ✕` — ←는 그 화면만, ✕는 패널 전체를 닫는다)으로 띄운다(잔디와 같다). 모바일(패널이
/// 전체 화면 라우트)은 앱의 Navigator에 전체 화면으로 띄운다(뒤로 가기도 예전과 같다). 팀을 바꾸면 띄워 둔 화면을 닫고
/// 새 팀의 목록으로 돌아간다.
///
/// 상태는 패널이 열릴 때 만드는 [TodoController]가 들고 있고(Session에는 두지 않는다), 서버의 todo:changed 알림이 오면
/// 조용히 다시 받는다. [controller]·[api]는 테스트가 바꿔 끼우는 값이다.
class TodosPanel extends StatefulWidget {
  final Session session;
  final VoidCallback? onClose;
  final TodoController? controller;
  final TodoApi? api;

  const TodosPanel({
    super.key,
    required this.session,
    this.onClose,
    this.controller,
    this.api,
  });

  @override
  State<TodosPanel> createState() => _TodosPanelState();
}

class _TodosPanelState extends State<TodosPanel> {
  late TodoController _controller;
  bool _ownsController = false;
  final _scroll = ScrollController();

  /// PC 패널 안 Navigator — 목록이 첫 화면이고, 상세·생성·수정·할 일 일정이 그 위에 올라온다. 모바일(홈 셸 없음)에는
  /// 없다(currentState가 null).
  final _pages = GlobalKey<NavigatorState>();

  /// 띄워 둔 할 일 일정 화면 — 두 번 띄우지 않고, 팀이 바뀌면 닫는다.
  Route<void>? _calendarRoute;

  /// PC 패널 안에서 쓰는 중인 할 일(생성·수정 화면) — 패널 안 Navigator 위에 내려 준다([TodoPanelDrafts]).
  final _drafts = TodoDraftRegistry();

  /// 홈 화면이 패널을 밖에서 닫거나 바꾸기 전에(같은 메뉴 타일·다른 패널·댓글·대화창 분할) 묻는 손잡이 — 쓰던 할 일이
  /// 있으면 그 화면의 "작성 취소" 확인을 띄운다.
  late final _leaveGuard = PanelLeaveGuard(
    needsConfirm: () => _drafts.top?.needsDiscardConfirm ?? false,
    confirm: () => _drafts.top?.confirmDiscard() ?? Future.value(true),
  );

  /// 손잡이를 맡긴 홈 화면(거둘 때 쓴다 — dispose에서는 위쪽을 찾을 수 없다).
  void Function(Object owner, PanelLeaveGuard? guard)? _setLeaveGuard;

  @override
  void initState() {
    super.initState();
    _attach();
    widget.session.addListener(_onSessionChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 홈 화면이 다시 그려지면 같은 손잡이(메서드)가 새 값으로 온다 — 다른 홈 화면일 때만 앞의 것에서 거둔다.
    final setGuard = HomeShellScope.maybeOf(context)?.setPanelLeaveGuard;
    if (setGuard != _setLeaveGuard) {
      _setLeaveGuard?.call(this, null);
      _setLeaveGuard = setGuard;
    }
    setGuard?.call(this, _leaveGuard);
  }

  void _attach() {
    final injected = widget.controller;
    if (injected != null) {
      _controller = injected;
      _ownsController = false;
    } else {
      final session = widget.session;
      _controller = TodoController(
        api: widget.api ?? session.todoApi,
        teamId: session.currentTeam!.id,
        changed: session.chatSocket.todoChanged,
        reconnected: session.chatSocket.reconnected,
      );
      _ownsController = true;
    }
    _controller.addListener(_onChanged);
    if (!_controller.loaded) _controller.load();
  }

  void _detach() {
    _controller.removeListener(_onChanged);
    if (_ownsController) _controller.dispose();
  }

  /// 보고 있는 팀이 바뀌면 띄워 둔 화면을 닫고 그 팀의 할 일로 새로 시작한다(내 컨트롤러일 때만).
  void _onSessionChanged() {
    if (!_ownsController) return;
    final teamId = widget.session.currentTeam?.id;
    if (teamId == null || teamId == _controller.teamId) return;
    _closePages();
    _detach();
    setState(_attach);
  }

  /// 목록 위에 띄운 화면을 닫는다 — PC는 패널 안 Navigator를 첫 화면(목록)까지(그 화면들이 창 전체에 띄운 메뉴 — 정렬·
  /// ••• · 진척률·알림 — 부터), 모바일은 할 일 일정 화면만(이전 팀의 컨트롤러를 들고 있다).
  void _closePages() {
    final pages = _pages.currentState;
    if (pages != null) {
      closeTodoPopups(Navigator.of(context, rootNavigator: true));
      pages.popUntil((route) => route.isFirst);
    }
    final calendar = _calendarRoute;
    _calendarRoute = null;
    if (calendar != null && calendar.isActive) {
      calendar.navigator?.removeRoute(calendar);
    }
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    // 첫 쪽이 화면을 다 못 채우면 스크롤이 안 생겨 다음 쪽을 못 받는다 — 그때는 직접 이어 받는다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (_scroll.position.maxScrollExtent <= 0 && _controller.hasMore) {
        _controller.loadMore();
      }
    });
  }

  @override
  void dispose() {
    _setLeaveGuard?.call(this, null);
    widget.session.removeListener(_onSessionChanged);
    _detach();
    _scroll.dispose();
    super.dispose();
  }

  // ---- 화면 띄우기 ----

  /// 패널 안 Navigator가 있으면(PC 홈 셸 아래) 상세·생성·일정을 패널 안 화면으로 띄운다.
  bool get _inPanel => _pages.currentState != null;

  /// 화면을 올릴 Navigator의 context — PC는 패널 안 Navigator, 모바일은 이 패널이 열린 앱의 Navigator.
  BuildContext get _pageHost => _pages.currentContext ?? context;

  TodoViewMode get _pageMode =>
      _inPanel ? TodoViewMode.panel : TodoViewMode.page;

  /// 패널 안 화면 머리의 ✕ — 패널 전체를 닫는다(모바일 전체 화면은 앱바의 ←로 닫는다).
  VoidCallback? get _closePanel => _inPanel ? widget.onClose : null;

  // ---- 동작 ----

  /// `+ 할 일 생성` — 대화방 칸은 지금 연 방(PC — 할 일을 만들 수 있는 방일 때), 아니면 잔디처럼 나와의 대화(모바일은
  /// 늘, PC는 방을 안 열었거나 보드 뷰·비밀·쓸 수 없는 방일 때). 그래서 담당자도 처음부터 나다. 고정하지 않으니 다른 방으로
  /// 바꿀 수 있다(아직 아무것도 안 넣었으면 묻지 않는다). 나와의 대화를 아직 못 받았으면 칸을 비워 둔다.
  Future<void> _create() async {
    final session = widget.session;
    bool usable(Room r) =>
        r.teamId == _controller.teamId && session.canCreateTodoIn(r);
    final shell = HomeShellScope.maybeOf(context);
    final currentId = shell?.panelRoom?.id ?? shell?.currentRoomId;
    final current = session.rooms
        .where((r) => r.id == currentId && usable(r))
        .firstOrNull;
    final self = session.selfRoom;
    final room = current ?? (self != null && usable(self) ? self : null);
    final saved = await showTodoEditor(
      _pageHost,
      session: session,
      room: room,
      api: widget.api,
      mode: _pageMode,
      onClosePanel: _closePanel,
    );
    if (saved == null || !mounted) return;
    showAppToast(context, '할 일을 만들었습니다.');
    _refresh();
  }

  Future<void> _open(Todo todo) async {
    final changed = await showTodoDetail(
      _pageHost,
      session: widget.session,
      todo: todo,
      api: widget.api,
      onOpenRoom: (room, {messageId}) => _openRoom(room, messageId),
      mode: _pageMode,
      onClosePanel: _closePanel,
    );
    if (changed && mounted) _refresh();
  }

  void _openRoom(Room room, String? messageId) =>
      openRoomFromPanel(context, widget.session, room, messageId: messageId);

  /// 내가 만들거나 상세에서 바꾼 뒤 — 목록과 (열어 둔) 일정을 로딩 표시 없이 다시 받는다.
  void _refresh() {
    _controller.load(silent: true);
    final month = _controller.calendarMonth;
    if (month != null) _controller.loadCalendar(month, silent: true);
  }

  /// `할 일 일정` — 오늘이 있는 달을 받으며 일정 화면을 띄우고(PC는 패널 안, 모바일은 전체 화면), 닫히면 달력 받기를
  /// 멈춘다(소켓 알림에 달력까지 다시 받지 않게).
  Future<void> _openCalendar() async {
    if (_calendarRoute != null) return;
    final c = _controller;
    final panel = _pages.currentState;
    final page = TodoCalendarPage(
      session: widget.session,
      controller: c,
      onOpen: _open,
      mode: _pageMode,
      onClosePanel: _closePanel,
    );
    final route = panel != null
        ? todoPanelRoute<void>((_) => page)
        : MaterialPageRoute<void>(builder: (_) => page);
    _calendarRoute = route;
    unawaited(c.loadCalendar(DateTime.now()));
    await (panel ?? Navigator.of(context)).push(route);
    if (identical(_calendarRoute, route)) _calendarRoute = null;
    // 팀이 바뀌어 닫힌 것이면 이전 팀의 컨트롤러는 이미 버렸다.
    if (identical(c, _controller)) c.closeCalendar();
  }

  // ---- 화면 ----

  @override
  Widget build(BuildContext context) {
    // 모바일(전체 화면 라우트) — 목록만 그리고, 상세 등은 앱의 Navigator에 전체 화면으로 올린다.
    if (HomeShellScope.maybeOf(context) == null) return _listPage(context);
    // PC 오른쪽 칸 — 패널 안 Navigator의 첫 화면이 목록이다. 밀려 들어오는 화면이 패널 밖으로 비치지 않게 자르고, 그
    // 안의 화면 크기(MediaQuery)는 패널 크기로 둔다(안의 화면이 창이 아니라 패널 폭에 맞춰 그려진다). 메뉴·펼침 목록·
    // 알림은 창 전체(루트)에 뜨되 자리는 패널 안이라, 바깥(채팅 쪽)을 눌러도 닫힌다. 시스템 뒤로 가기(안드로이드 태블릿)는
    // 패널 안 화면부터 닫는다. 패널 안에서 쓰는 중인 할 일은 [TodoPanelDrafts]로 모은다(밖에서 패널을 닫기 전에 묻는다).
    return NavigatorPopHandler(
      onPopWithResult: (_) => _pages.currentState?.maybePop(),
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: constraints.biggest),
            child: TodoPanelDrafts(
              drafts: _drafts,
              child: Navigator(
                key: _pages,
                onGenerateInitialRoutes: (navigator, initialRoute) => [
                  // 패널이 다시 그려질 때마다 Navigator가 화면들을 다시 그리게 하므로(changedExternalState) 목록은
                  // 늘 지금 상태로 그려진다. 패널을 열기만 해서는 포커스를 가져오지 않는다 — 채팅 입력칸에 쓰던
                  // 글을 이어 쓸 수 있게(위에 올라오는 상세·생성·일정은 누른 화면이라 포커스를 가져간다).
                  PageRouteBuilder<void>(
                    requestFocus: false,
                    pageBuilder: (context, _, _) => _listPage(context),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 목록 화면 — 머리, 할 일 생성, 필터 줄, 정렬·완료 제외 줄, 그 아래 회색 바탕의 건수 줄과 카드 목록.
  Widget _listPage(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context),
          const Divider(height: 1),
          _createButton(context),
          _filterBar(),
          _optionBar(context),
          Expanded(
            child: ColoredBox(
              color: todoListBackgroundColor(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _countLine(context),
                  Expanded(child: _content(context)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 머리 — `할 일`과 바로 옆 작은 회색 `할 일 일정` 칩(일정 화면을 연다), 오른쪽 끝 ✕(패널 닫기). 높이는 다른 패널
  /// 머리(SidePanelHeader)·패널 안 화면 머리([TodoPageHeader])와 같다.
  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Text('할 일', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(width: 10),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: _calendarChip(context),
            ),
          ),
          IconButton(
            key: const ValueKey('todo-panel-close'),
            icon: const Icon(Icons.close),
            tooltip: '닫기',
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  Widget _calendarChip(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    final radius = BorderRadius.circular(6);
    return Semantics(
      container: true,
      button: true,
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: radius,
        child: InkWell(
          key: const ValueKey('todo-calendar-toggle'),
          borderRadius: radius,
          onTap: _openCalendar,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(7, 5, 9, 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.calendar_month, size: 15, color: color),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    '할 일 일정',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: color),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 가로 전체 `+ 할 일 생성` — 옅은 회색 둥근 단추.
  Widget _createButton(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: FilledButton.icon(
        key: const ValueKey('todo-create'),
        onPressed: _create,
        style: FilledButton.styleFrom(
          backgroundColor: scheme.surfaceContainerHighest,
          foregroundColor: scheme.onSurface,
          minimumSize: const Size.fromHeight(44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          // 글꼴(대체 글꼴 포함)은 테마 것을 그대로 — 크기·굵기만 바꾼다.
          textStyle: theme.textTheme.labelLarge?.copyWith(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        icon: const Icon(Icons.add, size: 20),
        label: const Text(
          '할 일 생성',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// 대화방 필터에서 방을 고르지 않았을 때의 글자(잔디).
  static const _allRoomsLabel = '참여한 대화방';

  /// 필터 단추에서 글자 말고 차지하는 폭 — 앞 여백(10)·▾(18)·틈(8)에, 둥근 오른쪽 끝에 글자가 붙지 않게 둘 여유(12).
  static const _filterChrome = 48.0;

  /// 세 칸 줄에서 대화방 단추에 남길 최소 폭 — 이보다 좁아지면 세 칸을 글자 폭 비율로 나눈다.
  static const _roomMinWidth = 72.0;

  /// 필터 줄 — 참여한 대화방, 보기, 그리고 부여한 할 일이면 담당 멤버(잔디 "[부여한 할 일] – [모든 멤버]"). 펼침 패널은
  /// 폭을 아는 [FilterDropdownButton]이 창(PC는 패널) 안으로 당긴다 — 대화방·보기는 단추 왼쪽 끝, 줄 오른쪽 끝의 멤버는
  /// 단추 오른쪽 끝에 맞춘다. 세 칸이면 보기·멤버 단추를 글자가 다 들어가는 폭으로 두고 대화방 글자부터 줄인다(잔디도
  /// `참여한 대…`). 그래도 대화방 칸이 너무 좁아지면(좁은 폭·큰 글자) 셋을 글자 폭 비율로 나눈다.
  Widget _filterBar() {
    final c = _controller;
    final session = widget.session;
    // 펼침 목록의 첫 줄도 단추와 같은 `참여한 대화방`(잔디 — 참여한 대화방 / 특정 대화방).
    final room = RoomFilterButton(
      session: session,
      selectedRoomId: c.roomId,
      expand: true,
      allLabel: _allRoomsLabel,
      allOptionLabel: _allRoomsLabel,
      onSelected: c.setRoom,
    );
    const gap = SizedBox(width: 8);
    if (c.scope != TodoScope.assignedByMe) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Row(
          children: [
            Expanded(child: room),
            gap,
            Expanded(child: _scopeButton()),
          ],
        ),
      );
    }
    // 후보는 이 팀 방들의 멤버만 — 할 일 목록은 팀 안에서만 찾는다(다른 팀 사람을 고르면 늘 비어 있다).
    final users = memberChoicesFor(session, c.roomId, teamId: c.teamId);
    final member = MemberFilterButton(
      key: const ValueKey('todo-assignee-filter'),
      alignEnd: true,
      users: users,
      selectedSenderId: c.assigneeId,
      onSelected: c.setAssignee,
    );
    // 단추들이 보일 글자(RoomFilterButton·MemberFilterButton과 같은 규칙).
    final roomLabel =
        session.rooms
            .where((r) => r.id == c.roomId)
            .firstOrNull
            ?.displayName(session.userId ?? '') ??
        _allRoomsLabel;
    final memberLabel =
        users.where((u) => u.id == c.assigneeId).firstOrNull?.name ?? '모든 멤버';
    // 세 칸은 사이를 조금 좁혀 대화방 글자를 한 자라도 더 보인다.
    const narrowGap = SizedBox(width: 6);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final style = Theme.of(context).textTheme.labelLarge;
          final scaler = MediaQuery.textScalerOf(context);
          final direction = Directionality.of(context);
          double want(String label) {
            final painter = TextPainter(
              text: TextSpan(text: label, style: style),
              textDirection: direction,
              textScaler: scaler,
              maxLines: 1,
            )..layout();
            final width = painter.width;
            painter.dispose();
            return width + _filterChrome;
          }

          final scopeWidth = want(c.scope.label);
          final memberWidth = want(memberLabel);
          final roomWidth =
              constraints.maxWidth -
              2 * narrowGap.width! -
              scopeWidth -
              memberWidth;
          if (roomWidth >= _roomMinWidth) {
            return Row(
              children: [
                Expanded(child: room),
                narrowGap,
                SizedBox(width: scopeWidth, child: _scopeButton()),
                narrowGap,
                SizedBox(width: memberWidth, child: member),
              ],
            );
          }
          return Row(
            children: [
              Expanded(flex: want(roomLabel).round(), child: room),
              narrowGap,
              Expanded(flex: scopeWidth.round(), child: _scopeButton()),
              narrowGap,
              Expanded(flex: memberWidth.round(), child: member),
            ],
          );
        },
      ),
    );
  }

  /// 보기 드롭다운 펼침 패널 폭.
  static const _scopePanelWidth = 180.0;

  /// 보기 드롭다운(모든 할 일 / 나의 할 일 / 부여한 할 일 — 잔디 순서) — 다른 필터 단추와 같은 모양, 고른 것에 체크.
  Widget _scopeButton() {
    final scope = _controller.scope;
    return FilterDropdownButton(
      key: const ValueKey('todo-scope'),
      label: scope.label,
      expand: true,
      panelWidth: _scopePanelWidth,
      panelBuilder: (close) => FilterPanelShell(
        width: _scopePanelWidth,
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          children: [
            for (final s in TodoScope.menuOrder)
              ListTile(
                key: ValueKey('todo-scope-${s.wire}'),
                dense: true,
                title: Text(s.label),
                trailing: s == scope ? const Icon(Icons.check, size: 18) : null,
                onTap: () {
                  _controller.setScope(s);
                  close();
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 왼쪽 정렬, 오른쪽 `완료된 할 일 제외` 스위치(글자를 눌러도 켜고 끈다).
  Widget _optionBar(BuildContext context) {
    final c = _controller;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: Row(
        children: [
          _sortButton(context),
          const SizedBox(width: 8),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              // 글자와 스위치를 한 마디(켜짐/꺼짐)로 읽게 합친다.
              child: MergeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: InkWell(
                        onTap: () => c.setExcludeDone(!c.excludeDone),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 6,
                          ),
                          child: Text(
                            '완료된 할 일 제외',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    // 잔디처럼 작은 스위치 — 그대로는 줄보다 크다. 누르는 자리 여백을 빼야 모바일·PC에서 같은
                    // 크기로 줄어든다(모바일은 글자를 눌러도 된다).
                    SizedBox(
                      height: 24,
                      child: FittedBox(
                        child: Switch(
                          key: const ValueKey('todo-exclude-done'),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          value: c.excludeDone,
                          onChanged: c.setExcludeDone,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 정렬 메뉴가 떠 있는지(단추를 "펼침"으로 읽힌다).
  bool _sortMenuOpen = false;

  /// 정렬(생성 순 / 기한 순) 단추.
  Widget _sortButton(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return Semantics(
      expanded: _sortMenuOpen,
      child: Tooltip(
        message: '정렬',
        child: Builder(
          builder: (buttonContext) => InkWell(
            key: const ValueKey('todo-sort'),
            onTap: () => _openSortMenu(buttonContext),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.swap_vert, size: 16, color: hint),
                  const SizedBox(width: 2),
                  Text(
                    _controller.sort.label,
                    style: theme.textTheme.labelMedium?.copyWith(color: hint),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 정렬 메뉴 — 창 전체(루트 Navigator)에 띄워 바깥(PC는 채팅 쪽까지)을 누르면 닫히게 하고, 자리는 단추 바로 아래에서
  /// 단추 왼쪽 끝부터 오른쪽(패널 안)으로 편다([showTodoMenu] — 펴는 쪽을 창이 아니라 패널 기준으로 정한다).
  Future<void> _openSortMenu(BuildContext buttonContext) async {
    if (_sortMenuOpen) return;
    final current = _controller.sort;
    setState(() => _sortMenuOpen = true);
    final picked = await showTodoMenu<TodoSort>(
      buttonContext,
      initialValue: current,
      constraints: const BoxConstraints(minWidth: 140, maxWidth: 200),
      items: [
        for (final s in TodoSort.menuOrder)
          PopupMenuItem<TodoSort>(
            key: ValueKey('todo-sort-${s.wire}'),
            value: s,
            height: CompactMenu.itemHeight,
            padding: CompactMenu.itemPadding,
            child: Row(
              children: [
                Expanded(child: Text(s.label, style: CompactMenu.textStyle)),
                if (s == current) const Icon(Icons.check, size: 16),
              ],
            ),
          ),
      ],
    );
    if (!mounted) return;
    setState(() => _sortMenuOpen = false);
    if (picked != null) _controller.setSort(picked);
  }

  /// `N개의 할 일` — 지금 필터에 맞는 전체 개수(다음 쪽을 아직 안 받았어도 다 센다), 숫자는 굵게. 처음 받는 중·필터나
  /// 정렬을 바꿔 다시 받는 중·받지 못했을 때는 개수를 모르므로(0이 아니다) 같은 높이의 빈 줄만 둔다 — 받으면 그 자리에
  /// 개수가 나오고 목록은 밀리지 않는다. 조용히 다시 받는 동안(소켓 알림·내 변경 뒤)은 받아 둔 개수 그대로다.
  Widget _countLine(BuildContext context) {
    final theme = Theme.of(context);
    const bold = TextStyle(fontWeight: FontWeight.w700);
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurface,
    );
    final Widget line;
    if (_controller.loaded) {
      line = Text.rich(
        key: const ValueKey('panel-loaded-count'),
        TextSpan(
          children: [
            TextSpan(text: '${_controller.total}', style: bold),
            const TextSpan(text: '개의 할 일'),
          ],
        ),
        style: style,
      );
    } else {
      // 굵은 글자 칸까지 넣어 개수 줄과 같은 높이로.
      line = ExcludeSemantics(
        child: Text.rich(
          key: const ValueKey('panel-count-pending'),
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

  Widget _content(BuildContext context) {
    final c = _controller;
    if (!c.loaded) {
      if (c.error != null) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(c.error!, textAlign: TextAlign.center),
              ),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: c.load, child: const Text('다시 시도')),
            ],
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    final items = c.items;
    if (items.isEmpty) return _empty(context);
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 240) c.loadMore();
        return false;
      },
      child: ListView.separated(
        key: const ValueKey('todo-list'),
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        itemCount: items.length + (c.hasMore || c.loadingMore ? 1 : 0),
        separatorBuilder: (context, i) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          if (i >= items.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final todo = items[i];
          return TodoCard(
            key: ValueKey('todo-${todo.id}'),
            session: widget.session,
            controller: c,
            todo: todo,
            onTap: () => _open(todo),
          );
        },
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    final text = switch (_controller.scope) {
      TodoScope.mine => '나에게 지정된 할 일이 없어요.',
      TodoScope.assignedByMe => '다른 멤버에게 부여한 할 일이 없어요.',
      TodoScope.team => '참여한 대화방에 등록된 할 일이 없어요.',
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.checklist_rounded, size: 40, color: theme.hintColor),
            const SizedBox(height: 12),
            Text(
              text,
              key: const ValueKey('todo-empty'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 4),
            Text(
              '"할 일 생성"으로 대화방에 할 일을 만들어 보세요.',
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
}

/// 목록·일정의 할 일 카드(잔디) — 첫 줄 `진행률 : 75%`(숫자는 진척률 색)와 오른쪽 `생성일: 2026/10/03`, 굵은 제목(두 줄,
/// 즐겨찾기면 앞에 작은 노란 별), 설명 미리보기(두 줄, 있을 때만), 대화방·담당자 수·첨부 수 한 줄(작게), 구분선 아래
/// `일정: 2026/10/01 ~ 2026/10/07`(지난 기한이고 아직 안 끝났으면 빨강, 날짜가 없으면 `일정: 없음`). 카드에서는 진척률·
/// 즐겨찾기를 바꾸지 않는다 — 누르면 [onTap](상세).
///
/// 진척률은 목록이 보는 관점([TodoController.perspectiveProgress] — 나의 할 일은 내 것, 담당 멤버를 골랐으면 그 사람 것,
/// 그 밖은 전체)으로 보이고, 지난 기한의 "아직 안 끝남"도 그 값으로 따진다.
class TodoCard extends StatelessWidget {
  final Session session;
  final TodoController controller;
  final Todo todo;
  final VoidCallback? onTap;

  /// false면 대화방 이름을 빼고 그린다(일정 화면처럼 대화방별로 묶어 보일 때).
  final bool showRoom;

  /// false면 카드 바탕·모서리 없이 내용만 그린다(일정 화면의 대화방 묶음 카드 안에 줄줄이 넣을 때 — 바탕은 묶음이 칠한다).
  final bool framed;

  const TodoCard({
    super.key,
    required this.session,
    required this.controller,
    required this.todo,
    this.onTap,
    this.showRoom = true,
    this.framed = true,
  });

  @override
  Widget build(BuildContext context) {
    final content = InkWell(onTap: onTap, child: _content(context));
    if (!framed) return content;
    return Material(
      color: todoCardColor(context),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: content,
    );
  }

  Widget _content(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final progress = controller.perspectiveProgress(todo);
    final overdue = todo.isOverdueFor(progress);
    final description = todo.description?.trim() ?? '';
    final info = _infoLine(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '진행률 : ',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
              Text(
                controller.perspectiveText(todo),
                key: ValueKey('todo-card-progress-${todo.id}'),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: todoProgressColor(context, progress),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '생성일: ${formatTodoDate(todo.createdAt)}',
                  key: ValueKey('todo-created-${todo.id}'),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 즐겨찾기 표시(누르는 단추가 아니다 — 켜고 끄기는 상세의 별).
              if (todo.favorite)
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 4),
                  child: Icon(
                    Icons.star_rounded,
                    key: ValueKey('todo-fav-${todo.id}'),
                    size: 17,
                    color: Colors.amber,
                  ),
                ),
              Expanded(
                child: Text(
                  todo.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          if (description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              description,
              key: ValueKey('todo-desc-${todo.id}'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ],
          if (info != null) ...[const SizedBox(height: 8), info],
          const SizedBox(height: 12),
          Divider(height: 1, color: scheme.outlineVariant),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              '일정: ${todo.periodText ?? '없음'}',
              key: ValueKey('todo-period-${todo.id}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: overdue ? scheme.error : scheme.onSurfaceVariant,
                fontWeight: overdue ? FontWeight.w600 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 작은 회색 한 줄 — 대화방(종류 아이콘 + 이름, [showRoom]일 때) · 담당자 N명 · 📎 첨부 수. 보일 게 없으면 null.
  Widget? _infoLine(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final style = TextStyle(fontSize: 12, color: hint);
    final room = session.roomById(todo.roomId);
    final roomName =
        room?.displayName(session.userId ?? '') ?? todo.roomName ?? '';
    final parts = <Widget>[];
    void separator() => parts.add(Text(' · ', style: style));
    if (showRoom && roomName.isNotEmpty) {
      parts.addAll([
        Icon(
          iconForRoomType(room?.type ?? RoomType.topic),
          size: 13,
          color: hint,
        ),
        const SizedBox(width: 3),
        // 이름이 길면 이것부터 줄인다.
        Flexible(
          child: Text(
            roomName,
            key: ValueKey('todo-room-${todo.id}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ]);
    }
    if (todo.assignees.isNotEmpty) {
      if (parts.isNotEmpty) separator();
      parts.add(
        Text(
          '담당자 ${todo.assignees.length}명',
          key: ValueKey('todo-assignees-${todo.id}'),
          style: style,
        ),
      );
    }
    if (todo.attachments.isNotEmpty) {
      if (parts.isNotEmpty) separator();
      parts.addAll([
        Icon(Icons.attach_file, size: 13, color: hint),
        Text(
          '${todo.attachments.length}',
          key: ValueKey('todo-clips-${todo.id}'),
          style: style,
        ),
      ]);
    }
    if (parts.isEmpty) return null;
    return Row(children: parts);
  }
}
