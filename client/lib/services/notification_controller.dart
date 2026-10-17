import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/app_notification.dart';
import '../models/groupware.dart' show ApprovalNotification;
import '../models/project.dart' show ProjectNotification;
import 'notification_api.dart';
import 'notification_view_prefs.dart';

/// 알림 센터의 탭 — `전체 | 멘션 | 메시지 | 보드·공지 | 프로젝트 | 결재`. 메시지 탭이 예전의 "안 읽은 대화"(안 읽은 메시지가 있는 방 목록)다.
/// 결재 탭은 전자결재의 결재 요청(내 차례)·승인·반려·회수·취소 알림이다(그룹웨어 결재 알림함).
enum NotificationTab { all, mention, unreadChats, board, project, approval }

extension NotificationTabLabel on NotificationTab {
  String get label => switch (this) {
    NotificationTab.all => '전체',
    NotificationTab.mention => '멘션',
    NotificationTab.unreadChats => '메시지',
    NotificationTab.board => '보드·공지',
    NotificationTab.project => '프로젝트',
    NotificationTab.approval => '결재',
  };
}

/// 멘션 탭의 드롭다운 필터 — `전체 멘션`(개인 멘션 + `@all`, 기본) / `@나를 멘션`(개인 멘션만) / `@all 멘션`.
/// 전체 탭은 이 필터와 상관없이 멘션 두 종류를 늘 모두 보여 준다.
enum MentionFilter { all, personal, everyone }

extension MentionFilterInfo on MentionFilter {
  /// 서버 `GET /api/notifications`의 kind(읽음 처리 `{kind}`도 같다).
  String get wire => switch (this) {
    MentionFilter.all => 'mention',
    MentionFilter.personal => 'mention_personal',
    MentionFilter.everyone => 'mention_all',
  };

  /// 드롭다운 메뉴 항목 글자.
  String get menuLabel => switch (this) {
    MentionFilter.all => '전체 멘션',
    MentionFilter.personal => '@나를 멘션',
    MentionFilter.everyone => '@all 멘션',
  };

  /// 탭 줄에 보이는 짧은 이름 — 고르지 않았으면(전체) 그냥 `멘션`.
  String get tabLabel => switch (this) {
    MentionFilter.all => '멘션',
    MentionFilter.personal => '@나',
    MentionFilter.everyone => '@all',
  };

  /// 이 종류의 알림인지([MentionFilter.all]은 멘션 두 종류 모두).
  bool accepts(AppNotification n) => switch (this) {
    MentionFilter.all => n.isMention,
    MentionFilter.personal => n.kind == NotificationKind.mention,
    MentionFilter.everyone => n.kind == NotificationKind.mentionAll,
  };
}

/// 서버에서 페이지 단위로 받는 알림 목록 하나(멘션·개인 멘션·@all·보드, 안 읽은 것만 여부별로 따로).
class _Feed {
  final String kind; // 'mention' | 'mention_personal' | 'mention_all' | 'board'
  final bool unreadOnly;
  _Feed(this.kind, this.unreadOnly);

  final List<AppNotification> items = [];
  bool loaded = false;
  bool loading = false;
  bool hasMore = false;
  String? error;

  /// 새로 받거나 비울 때마다 올라간다 — 그 전에 나간 요청의 늦은 응답을 버리려고.
  int epoch = 0;
}

/// 알림 센터의 상태: 탭별 서버 알림 목록(무한 스크롤), 프로젝트 알림함, 안 읽음 개수, 알림 설정, 그리고
/// 소켓 `notification:new` / `notification:sync` 반영. 안 읽은 대화와 안 읽은 공지는 방(Room)에서 나오므로
/// 여기서 들고 있지 않고 화면이 Session에서 읽는다.
///
/// Session이 하나만 들고 있고(`session.notificationCenter`) 로그아웃하면 [reset]이 비운다. 서버 호출은
/// [NotificationApi]로만 해서 테스트가 가짜를 끼운다.
class NotificationController extends ChangeNotifier {
  NotificationController({
    required this.apiProvider,
    Stream<NotificationNewEvent>? newEvents,
    Stream<NotificationCounts>? syncEvents,
    Stream<Map<String, dynamic>>? projectEvents,
    Stream<void>? approvalEvents,
    Stream<void>? reconnected,
    String? Function()? userId,
    this.onNew,
    this.onRead,
    this.onSync,
    this.onApprovalUnread,
  }) : _userId = userId ?? (() => null) {
    _newSub = newEvents?.listen(handleNew);
    _syncSub = syncEvents?.listen(handleSync);
    _projectSub = projectEvents?.listen((_) {
      if (_projectLoaded) unawaited(loadProject());
    });
    _approvalSub = approvalEvents?.listen((_) {
      if (_approvalLoaded) unawaited(loadApproval());
    });
    _reconnectSub = reconnected?.listen((_) => unawaited(_resync()));
  }

  final NotificationApi Function() apiProvider;

  /// "안 읽은 알림만 표시" 선택을 사용자별로 저장할 때 쓰는 현재 로그인 사용자 id.
  final String? Function() _userId;

  /// 방 목록의 "@" 표시처럼 알림과 함께 움직이는 곳(Session)이 듣는다.
  final void Function(AppNotification n)? onNew;
  final void Function(List<AppNotification> read)? onRead;
  final void Function(NotificationCounts counts)? onSync;

  /// 결재 알림함의 안 읽은 수를 새로 알았을 때(받거나 읽음 처리한 뒤) — Session.approvalUnread가 듣는다.
  final void Function(int unread)? onApprovalUnread;

  StreamSubscription<NotificationNewEvent>? _newSub;
  StreamSubscription<NotificationCounts>? _syncSub;
  StreamSubscription<Map<String, dynamic>>? _projectSub;
  StreamSubscription<void>? _approvalSub;
  StreamSubscription<void>? _reconnectSub;
  bool _disposed = false;

  /// 로그아웃·다른 계정 로그인 때 올라간다 — 이전 계정 요청의 늦은 응답을 버리려고.
  int _epoch = 0;

  // ---- 안 읽음 개수 ----

  NotificationCounts counts = const NotificationCounts();

  /// 서버가 센 안 읽은 멘션·보드 알림 합계(탭 배지와 종 모양 배지가 쓴다).
  int get totalUnread => counts.mention + counts.board;

  Future<void> refreshCounts() async {
    final epoch = _epoch;
    try {
      final c = await apiProvider().fetchUnreadCounts();
      if (epoch != _epoch) return;
      _setCounts(c);
    } catch (_) {
      // 배지 숫자일 뿐이라 실패해도 조용히 넘어간다.
    }
  }

  void _setCounts(NotificationCounts c) {
    if (c == counts) return;
    counts = c;
    _notify();
  }

  /// 소켓 `notification:sync` — 다른 기기에서 읽어서 개수가 바뀜. 목록의 읽음 표시도 맞춘다.
  void handleSync(NotificationCounts c) {
    final personalDropped = c.mentionPersonal < counts.mentionPersonal;
    final everyoneDropped = c.mentionAll < counts.mentionAll;
    final boardDropped = c.board < counts.board;
    counts = c;
    // 안 읽은 게 0이 됐으면 들고 있는 목록도 전부 읽은 것으로 — 개수만 줄고 목록은 그대로 안 읽음이면
    // 어긋나 보인다. 개인 멘션·@all은 종류별로 따로 본다.
    if (c.mentionPersonal == 0 && personalDropped) {
      _markLoadedRead((n) => n.kind == NotificationKind.mention);
    }
    if (c.mentionAll == 0 && everyoneDropped) {
      _markLoadedRead((n) => n.kind == NotificationKind.mentionAll);
    }
    if (c.board == 0 && boardDropped) _markLoadedRead((n) => n.isBoard);
    onSync?.call(c);
    _notify();
  }

  void _markLoadedRead(bool Function(AppNotification n) test) {
    final now = DateTime.now();
    for (final f in _feeds.values) {
      for (final n in f.items) {
        if (test(n)) n.readAt ??= now;
      }
    }
  }

  /// 멘션 탭 필터 [f]를 골랐을 때 탭 배지에 보일 안 읽은 멘션 수.
  int mentionUnread(MentionFilter f) => switch (f) {
    MentionFilter.all => counts.mention,
    MentionFilter.personal => counts.mentionPersonal,
    MentionFilter.everyone => counts.mentionAll,
  };

  /// 알림 [n] 하나만큼 안 읽음 개수를 늘리거나(+1) 줄인다(-1) — 소켓이 개수를 같이 안 줬을 때와 읽음 처리 때.
  void _shiftCounts(AppNotification n, int delta) {
    int shifted(int v) => v + delta < 0 ? 0 : v + delta;
    if (n.isMention) {
      final isAll = n.kind == NotificationKind.mentionAll;
      counts = NotificationCounts.of(
        mentionPersonal: isAll
            ? counts.mentionPersonal
            : shifted(counts.mentionPersonal),
        mentionAll: isAll ? shifted(counts.mentionAll) : counts.mentionAll,
        board: counts.board,
      );
    } else if (n.isBoard) {
      counts = NotificationCounts(
        mention: counts.mention,
        board: shifted(counts.board),
        mentionPersonal: counts.mentionPersonal,
        mentionAll: counts.mentionAll,
      );
    }
  }

  // ---- 서버 알림 목록(멘션·보드) ----

  final Map<String, _Feed> _feeds = {};

  /// 탭별 "안 읽은 알림만 표시" 선택(알림 설정 대화상자에서 켜고 끈다). 안 읽은 대화 탭은 늘 안 읽은
  /// 것만이라 쓰지 않는다. 이 기기에 사용자별로 저장해서(notification_view_prefs.dart) 다시 열어도 유지된다.
  final Map<NotificationTab, bool> _unreadOnly = {};

  bool unreadOnly(NotificationTab tab) => _unreadOnly[tab] ?? false;

  Future<void> setUnreadOnly(NotificationTab tab, bool value) async {
    if (unreadOnly(tab) == value) return;
    _unreadOnly[tab] = value;
    _notify();
    unawaited(_saveViewPrefs());
    await ensureLoaded(tab);
  }

  Future<void> _saveViewPrefs() => NotificationViewPrefs.save(_userId(), {
    for (final e in _unreadOnly.entries) e.key.name: e.value,
  });

  /// 멘션 탭의 드롭다운 필터(전체 멘션 / @나를 멘션 / @all 멘션). 이 기기에 사용자별로 저장해서 다시 열어도
  /// 유지된다. 종류마다 서버 목록([_feed])이 따로라 바꿔도 이미 받아 둔 목록은 그대로 두고, 새 종류의 첫 페이지만 받는다.
  MentionFilter _mentionFilter = MentionFilter.all;

  MentionFilter get mentionFilter => _mentionFilter;

  Future<void> setMentionFilter(MentionFilter filter) async {
    if (_mentionFilter == filter) return;
    _mentionFilter = filter;
    _notify();
    unawaited(NotificationViewPrefs.saveMentionFilter(_userId(), filter.name));
    await ensureLoaded(NotificationTab.mention);
  }

  /// 저장해 둔 선택을 불러온다 — 로그인 직후 한 번(Session._enterApp). 받아 둔 목록은 필터가 다르면 다른
  /// 목록([_feed])이라 건드릴 필요 없고, 화면은 [notifyListeners]로 새로 그려진다.
  Future<void> loadViewPrefs() async {
    final epoch = _epoch;
    final saved = await NotificationViewPrefs.load(_userId());
    final savedFilter = await NotificationViewPrefs.loadMentionFilter(
      _userId(),
    );
    if (epoch != _epoch || _disposed) return;
    for (final tab in NotificationTab.values) {
      if (tab == NotificationTab.unreadChats) continue;
      _unreadOnly[tab] = saved[tab.name] ?? false;
    }
    _mentionFilter = MentionFilter.values.firstWhere(
      (f) => f.name == savedFilter,
      orElse: () => MentionFilter.all,
    );
    _notify();
  }

  _Feed _feed(String kind, bool unreadOnly) =>
      _feeds.putIfAbsent('$kind|$unreadOnly', () => _Feed(kind, unreadOnly));

  /// 이 탭이 보여 줄 서버 목록들 — 멘션 탭은 고른 [mentionFilter] 종류 하나, 보드 탭은 보드, 전체 탭은
  /// 필터와 상관없이 멘션(두 종류 모두)+보드 둘.
  List<_Feed> _feedsFor(NotificationTab tab) {
    final uo = unreadOnly(tab);
    return switch (tab) {
      NotificationTab.mention => [_feed(_mentionFilter.wire, uo)],
      NotificationTab.board => [_feed('board', uo)],
      NotificationTab.all => [_feed('mention', uo), _feed('board', uo)],
      _ => const [],
    };
  }

  /// 서버 목록 [feedKind]에 알림 [n]이 속하는지.
  static bool _feedAccepts(String feedKind, AppNotification n) =>
      switch (feedKind) {
        'mention' => n.isMention,
        'mention_personal' => n.kind == NotificationKind.mention,
        'mention_all' => n.kind == NotificationKind.mentionAll,
        'board' => n.isBoard,
        _ => false,
      };

  /// 멘션·보드·전체 탭의 서버 알림(최신순). 전체 탭은 두 목록을 시간순으로 섞는다.
  List<AppNotification> itemsFor(NotificationTab tab) {
    final feeds = _feedsFor(tab);
    if (feeds.length == 1) return List.unmodifiable(feeds.first.items);
    final merged = [for (final f in feeds) ...f.items]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return merged;
  }

  /// 전체 탭에서 섞어 보여 줘도 되는 가장 오래된 시각 — 아직 더 받을 수 있는 목록(hasMore)들은 자기가
  /// 받은 가장 오래된 알림보다 더 오래된 것이 서버에 있으니, 그 시각보다 오래된 항목을 미리 끼워 넣으면
  /// 나중에 받는 더 새 알림이 그 아래로 끼어들어 순서가 뒤집힌다. null이면 전부 받았다는 뜻.
  DateTime? mergeCutoffFor(NotificationTab tab) {
    DateTime? cutoff;
    for (final f in _feedsFor(tab)) {
      if (!f.hasMore || f.items.isEmpty) continue;
      final oldest = f.items.last.createdAt;
      if (cutoff == null || oldest.isAfter(cutoff)) cutoff = oldest;
    }
    return cutoff;
  }

  bool isLoading(NotificationTab tab) {
    if (tab == NotificationTab.project) return _projectLoading;
    if (tab == NotificationTab.approval) return _approvalLoading;
    return _feedsFor(tab).any((f) => f.loading);
  }

  bool hasMore(NotificationTab tab) => _feedsFor(tab).any((f) => f.hasMore);

  bool isLoaded(NotificationTab tab) {
    if (tab == NotificationTab.project) return _projectLoaded;
    if (tab == NotificationTab.approval) return _approvalLoaded;
    final feeds = _feedsFor(tab);
    return feeds.isEmpty || feeds.every((f) => f.loaded);
  }

  String? errorFor(NotificationTab tab) {
    if (tab == NotificationTab.project) return _projectError;
    if (tab == NotificationTab.approval) return _approvalError;
    for (final f in _feedsFor(tab)) {
      if (f.error != null) return f.error;
    }
    return null;
  }

  /// 탭을 처음 열 때 첫 페이지를 받는다(이미 받았거나 받는 중이면 아무 것도 안 한다).
  Future<void> ensureLoaded(NotificationTab tab) async {
    if (tab == NotificationTab.project) {
      if (!_projectLoaded && !_projectLoading) await loadProject();
      return;
    }
    if (tab == NotificationTab.approval) {
      if (!_approvalLoaded && !_approvalLoading) await loadApproval();
      return;
    }
    await Future.wait([
      for (final f in _feedsFor(tab))
        if (!f.loaded && !f.loading) _loadFirst(f),
    ]);
  }

  /// 처음부터 다시 받는다(새로고침·재연결).
  Future<void> refresh(NotificationTab tab) async {
    if (tab == NotificationTab.project) {
      await loadProject();
      return;
    }
    if (tab == NotificationTab.approval) {
      await loadApproval();
      return;
    }
    await Future.wait([for (final f in _feedsFor(tab)) _loadFirst(f)]);
  }

  Future<void> _loadFirst(_Feed f) async {
    final token = ++f.epoch;
    final epoch = _epoch;
    f.loading = true;
    f.error = null;
    _notify();
    try {
      final page = await apiProvider().fetchNotifications(
        kind: f.kind,
        unreadOnly: f.unreadOnly,
      );
      if (token != f.epoch || epoch != _epoch) return;
      f.items
        ..clear()
        ..addAll(page.items);
      f.hasMore = page.hasMore;
      f.loaded = true;
    } catch (e) {
      if (token != f.epoch || epoch != _epoch) return;
      f.error = _message(e);
    } finally {
      if (token == f.epoch && epoch == _epoch) {
        f.loading = false;
        _notify();
      }
    }
  }

  /// 스크롤이 끝에 닿았을 때 — 받은 것 중 가장 오래된 시각(before 커서)보다 오래된 다음 페이지를 붙인다.
  Future<void> loadMore(NotificationTab tab) async {
    await Future.wait([
      for (final f in _feedsFor(tab))
        if (f.loaded && f.hasMore && !f.loading) _loadNext(f),
    ]);
  }

  Future<void> _loadNext(_Feed f) async {
    if (f.items.isEmpty) return;
    final token = f.epoch;
    final epoch = _epoch;
    f.loading = true;
    _notify();
    try {
      final page = await apiProvider().fetchNotifications(
        kind: f.kind,
        before: f.items.last.createdAt.millisecondsSinceEpoch,
        unreadOnly: f.unreadOnly,
      );
      if (token != f.epoch || epoch != _epoch) return;
      final known = {for (final n in f.items) n.id};
      f.items.addAll(page.items.where((n) => !known.contains(n.id)));
      f.hasMore = page.hasMore;
    } catch (e) {
      if (token != f.epoch || epoch != _epoch) return;
      f.error = _message(e);
    } finally {
      if (token == f.epoch && epoch == _epoch) {
        f.loading = false;
        _notify();
      }
    }
  }

  /// 소켓 `notification:new` — 받아 둔 목록 맨 앞에 끼우고 개수를 맞춘다.
  void handleNew(NotificationNewEvent event) {
    final n = event.notification;
    for (final f in _feeds.values) {
      if (!f.loaded || !_feedAccepts(f.kind, n)) continue;
      if (f.items.any((x) => x.id == n.id)) continue;
      f.items.insert(0, n);
    }
    final unread = event.unread;
    if (unread != null) {
      counts = unread;
    } else {
      _shiftCounts(n, 1);
    }
    onNew?.call(n);
    _notify();
  }

  // ---- 읽음 처리 ----

  /// 알림 하나를 읽음으로 — 목록·개수를 먼저 바꾸고(반응성) 서버에 알린다. 이미 읽었으면 아무 것도 안 한다.
  Future<void> markRead(AppNotification n) async {
    if (n.isRead) return;
    final now = DateTime.now();
    final touched = <AppNotification>[];
    for (final f in _feeds.values) {
      for (final x in f.items) {
        if (x.id == n.id && !x.isRead) {
          x.readAt = now;
          touched.add(x);
        }
      }
    }
    if (!touched.any((x) => identical(x, n))) n.readAt = now;
    _shiftCounts(n, -1);
    onRead?.call([n]);
    _notify();
    try {
      await apiProvider().markRead(ids: [n.id]);
    } catch (_) {
      await refreshCounts();
    }
  }

  /// [tab]의 서버 알림을 전부 읽음으로(전체 탭은 멘션·보드 둘 다, 멘션 탭은 고른 [mentionFilter] 종류만). 안 읽은
  /// 대화·공지 같은 방 쪽 일은 화면이 Session으로 따로 한다.
  Future<void> markAllRead(NotificationTab tab) async {
    final kinds = switch (tab) {
      NotificationTab.mention => [_mentionFilter.wire],
      NotificationTab.board => ['board'],
      NotificationTab.all => ['mention', 'board'],
      _ => const <String>[],
    };
    if (kinds.isEmpty) return;
    bool targeted(AppNotification n) => kinds.any((k) => _feedAccepts(k, n));
    final now = DateTime.now();
    final read = <AppNotification>[];
    for (final f in _feeds.values) {
      for (final n in f.items) {
        if (!n.isRead && targeted(n)) {
          n.readAt = now;
          read.add(n);
        }
      }
    }
    // 읽음 처리한 종류의 개수만 0으로.
    final personal = kinds.any(
      (k) => k == 'mention' || k == 'mention_personal',
    );
    final everyone = kinds.any((k) => k == 'mention' || k == 'mention_all');
    counts = NotificationCounts.of(
      mentionPersonal: personal ? 0 : counts.mentionPersonal,
      mentionAll: everyone ? 0 : counts.mentionAll,
      board: kinds.contains('board') ? 0 : counts.board,
    );
    onRead?.call(read);
    if (personal || everyone) onSync?.call(counts);
    _notify();
    final api = apiProvider();
    try {
      for (final k in kinds) {
        await api.markRead(kind: k);
      }
    } catch (_) {
      await refreshCounts();
    }
  }

  // ---- 프로젝트 알림함 ----

  List<ProjectNotification> project = const [];
  bool _projectLoaded = false;
  bool _projectLoading = false;
  String? _projectError;

  int get projectUnread => project.where((n) => !n.read).length;

  Future<void> loadProject() async {
    final epoch = _epoch;
    _projectLoading = true;
    _projectError = null;
    _notify();
    try {
      final r = await apiProvider().fetchProjectNotifications();
      if (epoch != _epoch) return;
      project = r.items;
      _projectLoaded = true;
    } catch (e) {
      if (epoch != _epoch) return;
      _projectError = _message(e);
    } finally {
      if (epoch == _epoch) {
        _projectLoading = false;
        _notify();
      }
    }
  }

  /// 프로젝트 알림 읽음 — [ids]가 없으면 전부. 남은 안 읽은 개수를 돌려준다(Session.projectUnread에 넣는 쪽이 쓴다).
  Future<int> markProjectRead({List<String>? ids}) async {
    final remaining = await apiProvider().markProjectRead(ids: ids);
    if (ids == null) {
      project = [for (final n in project) _asRead(n)];
    } else {
      project = [for (final n in project) ids.contains(n.id) ? _asRead(n) : n];
    }
    _notify();
    return remaining;
  }

  static ProjectNotification _asRead(ProjectNotification n) => n.read
      ? n
      : ProjectNotification(
          id: n.id,
          projectId: n.projectId,
          projectName: n.projectName,
          projectColor: n.projectColor,
          taskId: n.taskId,
          kind: n.kind,
          title: n.title,
          body: n.body,
          createdAt: n.createdAt,
          read: true,
        );

  // ---- 결재 알림함 ----

  List<ApprovalNotification> approval = const [];
  bool _approvalLoaded = false;
  bool _approvalLoading = false;
  String? _approvalError;

  /// 결재 알림함을 받는다 — 결재 탭을 처음 열 때와, 받아 둔 뒤 새 결재 알림·다른 기기 읽음이 오면([approvalEvents]). 받은 안 읽은
  /// 수를 [onApprovalUnread]로 넘긴다(Session.approvalUnread).
  Future<void> loadApproval() async {
    final epoch = _epoch;
    _approvalLoading = true;
    _approvalError = null;
    _notify();
    try {
      final r = await apiProvider().fetchApprovalNotifications();
      if (epoch != _epoch) return;
      approval = r.items;
      _approvalLoaded = true;
      onApprovalUnread?.call(r.unread);
    } catch (e) {
      if (epoch != _epoch) return;
      _approvalError = _message(e);
    } finally {
      if (epoch == _epoch) {
        _approvalLoading = false;
        _notify();
      }
    }
  }

  /// 결재 알림 읽음 — [ids]가 없으면 전부. 목록을 먼저 바꾸고(반응성) 남은 안 읽은 수를 [onApprovalUnread]로 넘긴다.
  Future<void> markApprovalRead({List<String>? ids}) async {
    final before = approval;
    approval = [
      for (final n in approval)
        if (ids == null || ids.contains(n.id)) n.asRead() else n,
    ];
    _notify();
    try {
      final remaining = await apiProvider().markApprovalRead(ids: ids);
      onApprovalUnread?.call(remaining);
    } catch (_) {
      // 서버가 거절했으면 읽음 표시를 되돌린다.
      approval = before;
      _notify();
      rethrow;
    }
  }

  // ---- 설정 ----

  NotificationSettings? settings;
  bool settingsLoading = false;
  String? settingsError;

  Future<void> loadSettings() async {
    final epoch = _epoch;
    settingsLoading = true;
    settingsError = null;
    _notify();
    try {
      final s = await apiProvider().fetchSettings();
      if (epoch != _epoch) return;
      settings = s;
    } catch (e) {
      if (epoch != _epoch) return;
      settingsError = _message(e);
    } finally {
      if (epoch == _epoch) {
        settingsLoading = false;
        _notify();
      }
    }
  }

  /// 설정을 바꾼다 — 화면은 바로 새 값을 보여 주고, 서버가 거절하면 되돌리고 예외를 다시 던진다.
  Future<void> updateSettings({
    bool? mentionAll,
    BoardNotifyLevel? boardLevel,
    bool? pushWhileOnline,
    bool? emailDigest,
  }) async {
    final before = settings ?? const NotificationSettings();
    settings = before.copyWith(
      mentionAll: mentionAll,
      boardLevel: boardLevel,
      pushWhileOnline: pushWhileOnline,
      emailDigest: emailDigest,
    );
    _notify();
    try {
      final saved = await apiProvider().updateSettings(
        mentionAll: mentionAll,
        boardLevel: boardLevel,
        pushWhileOnline: pushWhileOnline,
        emailDigest: emailDigest,
      );
      settings = saved;
      _notify();
    } catch (_) {
      settings = before;
      _notify();
      rethrow;
    }
  }

  // ---- 수명 ----

  /// 끊겼다 다시 연결됐을 때 — 그동안 놓친 알림을 받아 둔 목록을 새로 채운다.
  Future<void> _resync() async {
    await refreshCounts();
    final loaded = [
      for (final f in _feeds.values)
        if (f.loaded) f,
    ];
    await Future.wait([for (final f in loaded) _loadFirst(f)]);
    if (_projectLoaded) await loadProject();
    if (_approvalLoaded) await loadApproval();
  }

  /// 로그아웃 — 받아 둔 것을 전부 비운다(다음에 로그인하는 사람에게 남지 않게).
  void reset() {
    _epoch++;
    counts = const NotificationCounts();
    _feeds.clear();
    _unreadOnly.clear();
    _mentionFilter = MentionFilter.all;
    project = const [];
    _projectLoaded = false;
    _projectLoading = false;
    _projectError = null;
    approval = const [];
    _approvalLoaded = false;
    _approvalLoading = false;
    _approvalError = null;
    settings = null;
    settingsLoading = false;
    settingsError = null;
    _notify();
  }

  String _message(Object e) {
    final s = e.toString();
    return s.startsWith('Exception: ') ? s.substring(11) : s;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _newSub?.cancel();
    _syncSub?.cancel();
    _projectSub?.cancel();
    _approvalSub?.cancel();
    _reconnectSub?.cancel();
    super.dispose();
  }
}
