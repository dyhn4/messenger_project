import 'dart:async';

import 'package:flutter/material.dart';

import '../models/room.dart';
import '../models/todo.dart';
import '../screens/todo_detail_dialog.dart';
import '../screens/todo_editor_dialog.dart';
import '../services/session.dart';
import '../services/todo_api.dart';
import '../services/todo_controller.dart';
import '../services/todo_download.dart';
import '../services/todo_upload.dart';
import 'app_toast.dart';
import 'compact_menu_anchor.dart';
import 'filter_dropdown.dart';
import 'home_shell_scope.dart';
import 'panel_filters.dart';
import 'todo_calendar_view.dart';
import 'todo_menu.dart';
import 'todo_widgets.dart';
import '../l10n/tr.dart';

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
/// 부여한 할 일 · 부여한 할 일이면 담당 멤버), 왼쪽 `완료된 할 일 제외` 스위치와 오른쪽 정렬(생성 순 / 기한 순), 그 아래 옅은 회색
/// 바탕에 `N개의 할 일`(서버가 센 전체 개수)과 카드 목록(무한 스크롤)이다. 카드를 누르면 상세가 열리고, 카드 오른쪽 위
/// ⋯는 상세 •••와 같은 메뉴(즐겨찾기 · 할 일 수정 · 파일 다운로드 · 할 일 삭제 — 권한도 같다)다. 할 일 일정 화면의 카드도
/// 같다.
///
/// PC 오른쪽 칸(홈 셸 아래)에서는 패널 안에 Navigator를 따로 두고 목록을 첫 화면으로 삼아, 상세·생성·수정·할 일 일정을
/// 패널 안 화면(머리 `← 할 일 … ✕` — ←는 그 화면만, ✕는 패널 전체를 닫는다)으로 띄운다(잔디와 같다). 모바일(패널이
/// 전체 화면 라우트)은 앱의 Navigator에 전체 화면으로 띄운다(뒤로 가기도 예전과 같다). 팀을 바꾸면 띄워 둔 화면을 닫고
/// 새 팀의 목록으로 돌아간다.
///
/// 상태는 패널이 열릴 때 만드는 [TodoController]가 들고 있고(Session에는 두지 않는다), 서버의 todo:changed 알림이 오면
/// 조용히 다시 받는다. [controller]·[api]·[download]는 테스트가 바꿔 끼우는 값이다.
class TodosPanel extends StatefulWidget {
  final Session session;
  final VoidCallback? onClose;
  final TodoController? controller;
  final TodoApi? api;
  final TodoDownloader? download;

  const TodosPanel({
    super.key,
    required this.session,
    this.onClose,
    this.controller,
    this.api,
    this.download,
  });

  @override
  State<TodosPanel> createState() => _TodosPanelState();
}

/// 할 일 하나를 할 일 패널 안의 상세로 연다(채팅의 할 일 카드를 눌렀을 때) — PC(홈 셸 아래)는 오른쪽 할 일 패널을 열고(이미
/// 열려 있으면 그대로) 그 안에 상세를 띄운다. 모바일처럼 패널이 없으면 예전처럼 상세만 연다(좁으면 전체 화면).
Future<void> openTodoInPanel(
  BuildContext context,
  Session session,
  Todo todo, {
  TodoApi? api,
}) async {
  final shell = HomeShellScope.maybeOf(context);
  if (shell == null) {
    await showTodoDetail(context, session: session, todo: todo, api: api);
    return;
  }
  for (final panel in _TodosPanelState._mounted) {
    if (panel.mounted && panel._inPanel) {
      _pendingTodo = null;
      await panel._open(todo);
      return;
    }
  }
  // 패널을 새로 연다 — 패널이 만들어지며 [_pendingTodo]를 가져가 상세를 띄운다.
  _pendingTodo = todo;
  if (shell.openPanelKey != 'todos') shell.togglePanel('todos');
}

/// [openTodoInPanel]이 새로 열 할 일 패널에 넘기는 "처음 띄울 상세" — 패널은 side_panels.dart의 builder가 만들어서 여기 잠깐
/// 두고 패널이 처음 그려진 뒤 한 번 가져간다.
Todo? _pendingTodo;

class _TodosPanelState extends State<TodosPanel> {
  /// 지금 떠 있는 할 일 패널 — 할 일 카드를 눌렀을 때 이미 열린 패널 안에 상세만 띄우려고([openTodoInPanel]).
  static final _mounted = <_TodosPanelState>{};

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
    _mounted.add(this);
    _attach();
    widget.session.addListener(_onSessionChanged);
    // 할 일 카드를 눌러 열었으면 패널 안 Navigator가 그려진 뒤 그 할 일의 상세를 목록 위에 띄운다(←로 목록에 돌아온다).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final todo = _pendingTodo;
      _pendingTodo = null;
      if (todo != null && mounted) unawaited(_open(todo));
    });
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

  /// 목록 위에 띄운 화면을 닫는다 — 목록의 정렬 메뉴부터, PC는 패널 안 Navigator를 첫 화면(목록)까지(그 화면들이 창
  /// 전체에 띄운 메뉴 — ••• · 진척률·알림 — 부터), 모바일은 할 일 일정 화면만(이전 팀의 컨트롤러를 들고 있다).
  void _closePages() {
    _sortMenu.close();
    // 카드 ⋯에서 띄운 삭제 확인(창 전체에 뜬다) — 이전 팀의 할 일이라 지우지 않고(결과 null) 닫는다.
    final confirm = _confirmRoute;
    _confirmRoute = null;
    if (confirm != null) closeTodoRoute(confirm);
    final pages = _pages.currentState;
    // 카드 ⋯ 메뉴도 창 전체에 뜬다(모바일도) — 함께 닫는다.
    closeTodoPopups(Navigator.of(context, rootNavigator: true));
    if (pages != null) pages.popUntil((route) => route.isFirst);
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
    _mounted.remove(this);
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
    // 만들기는 투표 만들기처럼 PC는 가운데 대화상자, 모바일은 전체 화면으로 연다(상세·수정·일정은 패널 안 화면).
    final saved = await showTodoEditor(
      context,
      session: session,
      room: room,
      api: widget.api,
      mode: _inPanel ? TodoViewMode.dialog : TodoViewMode.page,
    );
    if (saved == null || !mounted) return;
    showAppToast(context, tr('할 일을 만들었습니다.'));
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

  // ---- 카드 ⋯ 메뉴 — 상세 •••와 같은 항목·동작 ----

  /// 첨부를 받는 중인 할 일(id) — 받는 동안 그 카드의 `파일 다운로드`는 꺼진다.
  final _downloading = <String>{};

  /// 카드 ⋯에서 띄운 삭제 확인 — 팀을 바꾸면 닫는다([_closePages]).
  Route<Object?>? _confirmRoute;

  /// 목록·일정 카드에 내려 주는 ⋯ 손잡이.
  late final _cardActions = TodoCardActions(
    onSelected: _onCardMenu,
    isDownloading: (todo) => _downloading.contains(todo.id),
  );

  void _onCardMenu(Todo todo, TodoMenuAction action) {
    switch (action) {
      case TodoMenuAction.favorite:
        unawaited(_toggleFavorite(todo));
      case TodoMenuAction.edit:
        unawaited(_edit(todo));
      case TodoMenuAction.download:
        unawaited(_download(todo));
      case TodoMenuAction.upload:
        unawaited(uploadTodoFiles(context, widget.session, todo));
      case TodoMenuAction.delete:
        unawaited(_delete(todo));
    }
  }

  /// 즐겨찾기 켜고 끄기 — 목록·일정에서 바로 바꿔 보이고(컨트롤러가 조용히 다시 받아 "즐겨찾기 먼저" 순서를 맞춘다),
  /// 실패하면 되돌리고 알린다.
  Future<void> _toggleFavorite(Todo todo) async {
    try {
      await _controller.toggleFavorite(todo);
    } catch (e) {
      if (mounted) showAppToast(context, tr('즐겨찾기를 바꾸지 못했습니다: {e}', {'e': e}));
    }
  }

  /// 할 일 수정 — 상세의 수정과 같은 모양으로 연다(PC는 패널 안 화면, 모바일은 전체 화면).
  Future<void> _edit(Todo todo) async {
    final updated = await showTodoEditor(
      _pageHost,
      session: widget.session,
      editing: todo,
      api: widget.api,
      mode: _pageMode,
      onClosePanel: _closePanel,
    );
    if (updated == null || !mounted) return;
    showAppToast(context, tr('할 일을 수정했습니다.'));
    _refresh();
  }

  /// 첨부 전부 받기 — 상세의 `파일 다운로드`와 같다(PC는 폴더를 골라 차례로, 안드로이드는 공용 Download 폴더). 받기
  /// 시작하면 알리고, 끝난 알림은 내려받기 쪽이 띄운다.
  Future<void> _download(Todo todo) async {
    if (todo.attachments.isEmpty || !_downloading.add(todo.id)) return;
    final TodoDownloader download = widget.download ?? downloadTodoAttachments;
    try {
      await download(
        context,
        widget.session,
        todo,
        onProgress: (done, total) {
          if (done == 0 && mounted) {
            showAppToast(
              context,
              tr('파일 {total}개를 다운로드하는 중입니다.', {'total': total}),
            );
          }
        },
      );
    } catch (e) {
      if (mounted) showAppToast(context, tr('다운로드하지 못했습니다: {e}', {'e': e}));
    } finally {
      _downloading.remove(todo.id);
    }
  }

  /// 할 일 삭제 — 상세와 같은 확인 뒤 지우고 목록·일정에서 뺀다.
  Future<void> _delete(Todo todo) async {
    final controller = _controller;
    final ok = await confirmTodoDelete(
      context,
      todo,
      onRoute: (route) => _confirmRoute = route,
    );
    _confirmRoute = null;
    // 그사이 팀을 바꿨으면(확인 창이 닫혔다) 지우지 않는다.
    if (!ok || !mounted || !identical(controller, _controller)) return;
    try {
      await controller.remove(todo);
      if (mounted) showAppToast(context, tr('할 일을 삭제했습니다.'));
    } catch (e) {
      if (mounted) showAppToast(context, tr('할 일을 삭제하지 못했습니다: {e}', {'e': e}));
    }
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
      actions: _cardActions,
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
          Text(tr('할 일'), style: Theme.of(context).textTheme.titleLarge),
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
            tooltip: tr('닫기'),
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
                    tr('할 일 일정'),
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
        label: Text(tr('할 일 생성'), maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  /// 대화방 필터에서 방을 고르지 않았을 때의 글자(잔디).
  static final _allRoomsLabel = tr('참여한 대화방');

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
        users.where((u) => u.id == c.assigneeId).firstOrNull?.name ??
        tr('모든 멤버');
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

  /// 왼쪽 `완료된 할 일 제외` 스위치(스위치 · 글자 — 글자를 눌러도 켜고 끈다), 오른쪽 끝 정렬.
  Widget _optionBar(BuildContext context) {
    final c = _controller;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              // 글자와 스위치를 한 마디(켜짐/꺼짐)로 읽게 합친다.
              child: MergeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
                    const SizedBox(width: 2),
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
                            tr('완료된 할 일 제외'),
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
            ),
          ),
          const SizedBox(width: 8),
          _sortButton(context),
        ],
      ),
    );
  }

  /// 정렬 메뉴 — 팀을 바꿔 목록을 새로 시작할 때 떠 있던 메뉴를 닫는다.
  final _sortMenu = MenuController();

  /// 정렬(생성 순 / 기한 순) 단추 — 메시지 예약 패널의 정렬과 같은 드롭다운([CompactMenuAnchor])이 단추 오른쪽 끝에 맞춰
  /// 바로 뜬다. 메뉴는 가장 가까운 Overlay(PC는 패널 안 Navigator — 자리가 패널 안)에 뜨고, 바깥 어디를(PC는 채팅 쪽까지)
  /// 눌러도 닫히며 그 누름은 아래로 가지 않는다.
  Widget _sortButton(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return CompactMenuAnchor<TodoSort>(
      controller: _sortMenu,
      alignEnd: true,
      consumeOutsideTap: true,
      selected: _controller.sort,
      onSelected: _controller.setSort,
      entries: [
        for (final s in TodoSort.menuOrder)
          CompactMenuOption(
            key: ValueKey('todo-sort-${s.wire}'),
            value: s,
            label: s.label,
          ),
      ],
      builder: (context, open, toggle) => Semantics(
        expanded: open,
        child: Tooltip(
          message: tr('정렬'),
          child: InkWell(
            key: const ValueKey('todo-sort'),
            onTap: toggle,
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
            TextSpan(text: tr('개의 할 일')),
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
              OutlinedButton(onPressed: c.load, child: Text(tr('다시 시도'))),
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
            actions: _cardActions,
          );
        },
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    final text = switch (_controller.scope) {
      TodoScope.mine => tr('나에게 지정된 할 일이 없어요.'),
      TodoScope.assignedByMe => tr('다른 멤버에게 부여한 할 일이 없어요.'),
      TodoScope.team => tr('참여한 대화방에 등록된 할 일이 없어요.'),
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
              tr('"할 일 생성"으로 대화방에 할 일을 만들어 보세요.'),
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

/// 테두리 없이 그리는 카드(일정 화면의 대화방 묶음 안 — 흰 묶음 바탕 위)에 마우스를 올렸을 때 얹는 옅은 주 색. 회색 목록
/// 바탕 위의 카드(테두리 카드)는 이 색 대신 [todoCardHoverBorder]로 구분한다 — 흰 카드에 옅은 주 색을 얹으면 밝은 테마의
/// 연보라 목록 바탕과 거의 같아져 구분이 안 됐다.
Color todoCardHoverColor(BuildContext context) =>
    Theme.of(context).colorScheme.primary.withValues(alpha: 0.06);

/// 카드에 마우스를 올렸을 때의 테두리(공지 카드와 같은 규칙) — 카드 바탕은 그대로 두고 둥근 테두리만 주 색으로 그린다.
BorderSide todoCardHoverBorder(BuildContext context) => BorderSide(
  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.55),
  width: 1.5,
);

/// 카드를 누르는 동안(물결·눌림) 얹는 색 — [todoCardHoverColor]보다 조금 짙다.
Color todoCardPressColor(BuildContext context) =>
    Theme.of(context).colorScheme.primary.withValues(alpha: 0.08);

/// 목록·일정의 할 일 카드(잔디) — 첫 줄 `진행률 : 75%`(숫자는 진척률 색)와 오른쪽 `생성일: 2026/10/03`, 굵은 제목(두 줄,
/// 즐겨찾기면 앞에 작은 노란 별), 설명 미리보기(두 줄, 있을 때만), 대화방·담당자 수·첨부 수 한 줄(작게), 구분선 아래
/// `일정: 2026/10/01 ~ 2026/10/07`(지난 기한이고 아직 안 끝났으면 빨강, 날짜가 없으면 `일정: 없음`). 누르면 [onTap](상세).
/// [actions]가 있으면 오른쪽 위에 ⋯([TodoCardMenuButton] — 상세 •••와 같은 메뉴: 즐겨찾기 · 할 일 수정 · 파일 다운로드 ·
/// 할 일 삭제)가 붙는다. 진척률은 카드에서 바꾸지 않는다(상세에서). 마우스를 올리면 카드 테두리가 주 색
/// ([todoCardHoverBorder])으로 바뀐다(테두리 없이 그릴 때는 옅은 주 색 [todoCardHoverColor]을 얹는다).
///
/// 진척률은 목록이 보는 관점([TodoController.perspectiveProgress] — 나의 할 일은 내 것, 담당 멤버를 골랐으면 그 사람 것,
/// 그 밖은 전체)으로 보이고, 지난 기한의 "아직 안 끝남"도 그 값으로 따진다.
class TodoCard extends StatelessWidget {
  final Session session;
  final TodoController controller;
  final Todo todo;
  final VoidCallback? onTap;

  /// ⋯ 메뉴의 손잡이 — 없으면 ⋯를 그리지 않는다.
  final TodoCardActions? actions;

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
    this.actions,
    this.showRoom = true,
    this.framed = true,
  });

  /// ⋯ 단추 자리 — 카드 위 끝에서, 오른쪽 끝에서(아이콘 오른쪽 끝이 내용 오른쪽 끝(16)에 오게).
  static const _menuTop = 12.0;
  static const _menuRight = 11.0;

  /// 첫 줄 오른쪽에 ⋯ 몫으로 비워 두는 폭(생성일이 ⋯ 밑으로 들어가지 않게).
  static const _menuReserve =
      TodoCardMenuButton.size + _menuRight - _contentRight + 4;

  /// 내용의 오른쪽 여백.
  static const _contentRight = 16.0;

  @override
  Widget build(BuildContext context) {
    final menu = actions;
    Widget body = _content(context, reserveMenu: menu != null);
    if (menu != null) {
      // ⋯는 카드(InkWell) 안에 둔다 — 그 위에 마우스를 올려도 카드가 올린 것으로 보이고, ⋯를 누르면 ⋯만 눌린다(카드의
      // 눌림·상세 열기는 없다).
      body = Stack(
        children: [
          body,
          Positioned(
            top: _menuTop,
            right: _menuRight,
            child: TodoCardMenuButton(todo: todo, actions: menu),
          ),
        ],
      );
    }
    InkWell ink({ValueChanged<bool>? onHover}) => InkWell(
      onTap: onTap,
      onHover: onHover,
      // 테두리 카드는 덧칠 없이 테두리로만 올린 것을 보인다.
      hoverColor: framed ? Colors.transparent : todoCardHoverColor(context),
      highlightColor: todoCardPressColor(context),
      splashColor: todoCardPressColor(context),
      child: body,
    );
    if (!framed) return ink();
    return _HoverFramedCard(
      key: ValueKey('todo-card-frame-${todo.id}'),
      color: todoCardColor(context),
      builder: (onHover) => ink(onHover: onHover),
    );
  }

  Widget _content(BuildContext context, {required bool reserveMenu}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final progress = controller.perspectiveProgress(todo);
    final overdue = todo.isOverdueFor(progress);
    final description = todo.description?.trim() ?? '';
    final info = _infoLine(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, _contentRight, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                tr('진행률 : '),
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
                  tr('생성일: {p0}', {'p0': formatTodoDate(todo.createdAt)}),
                  key: ValueKey('todo-created-${todo.id}'),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
              ),
              if (reserveMenu) const SizedBox(width: _menuReserve),
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
              tr('일정: {p0}', {'p0': todo.periodText ?? tr('없음')}),
              key: ValueKey('todo-period-${todo.id}'),
              // 시간까지 있으면 좁은 폭(휴대폰 360)에서는 종료 시각이 잘리지 않게 두 줄까지.
              maxLines: 2,
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
          tr('담당자 {todo.assignees.length}명', {
            'todo.assignees.length': todo.assignees.length,
          }),
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

/// 마우스를 올리면 둥근 테두리가 주 색([todoCardHoverBorder])으로 바뀌는 카드 틀 — 바탕색은 그대로다. [builder]는 안쪽
/// InkWell을 만들며 받은 onHover를 넘겨 올림 여부를 알린다.
class _HoverFramedCard extends StatefulWidget {
  final Color color;
  final Widget Function(ValueChanged<bool> onHover) builder;
  const _HoverFramedCard({
    super.key,
    required this.color,
    required this.builder,
  });

  @override
  State<_HoverFramedCard> createState() => _HoverFramedCardState();
}

class _HoverFramedCardState extends State<_HoverFramedCard> {
  bool _hovered = false;

  void _onHover(bool value) {
    if (value != _hovered) setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: widget.color,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: _hovered ? todoCardHoverBorder(context) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: widget.builder(_onHover),
    );
  }
}
