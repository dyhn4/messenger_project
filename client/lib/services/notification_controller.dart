import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/app_notification.dart';
import '../models/project.dart' show ProjectNotification;
import 'notification_api.dart';
import 'notification_view_prefs.dart';

/// 알림 센터의 탭 — `전체 | 멘션 | 메시지 | 보드·공지 | 프로젝트`. 메시지 탭이 예전의 "안 읽은 대화"(안 읽은 메시지가 있는 방 목록)다.
enum NotificationTab { all, mention, unreadChats, board, project }

extension NotificationTabLabel on NotificationTab {
  String get label => switch (this) {
    NotificationTab.all => '전체',
    NotificationTab.mention => '멘션',
    NotificationTab.unreadChats => '메시지',
    NotificationTab.board => '보드·공지',
    NotificationTab.project => '프로젝트',
  };
}

/// 서버에서 페이지 단위로 받는 알림 목록 하나(멘션 또는 보드, 안 읽은 것만 여부별로 따로).
class _Feed {
  final String kind; // 'mention' | 'board'
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
    Stream<void>? reconnected,
    String? Function()? userId,
    this.onNew,
    this.onRead,
    this.onSync,
  }) : _userId = userId ?? (() => null) {
    _newSub = newEvents?.listen(handleNew);
    _syncSub = syncEvents?.listen(handleSync);
    _projectSub = projectEvents?.listen((_) {
      if (_projectLoaded) unawaited(loadProject());
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

  StreamSubscription<NotificationNewEvent>? _newSub;
  StreamSubscription<NotificationCounts>? _syncSub;
  StreamSubscription<Map<String, dynamic>>? _projectSub;
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
    final mentionDropped = c.mention < counts.mention;
    final boardDropped = c.board < counts.board;
    counts = c;
    // 안 읽은 게 0이 됐으면 들고 있는 목록도 전부 읽은 것으로 — 개수만 줄고 목록은 그대로 안 읽음이면
    // 어긋나 보인다.
    if (c.mention == 0 && mentionDropped) _markLoadedRead('mention');
    if (c.board == 0 && boardDropped) _markLoadedRead('board');
    onSync?.call(c);
    _notify();
  }

  void _markLoadedRead(String kind) {
    final now = DateTime.now();
    for (final f in _feeds.values) {
      if (f.kind != kind) continue;
      for (final n in f.items) {
        n.readAt ??= now;
      }
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

  /// 저장해 둔 선택을 불러온다 — 로그인 직후 한 번(Session._enterApp). 받아 둔 목록은 필터가 다르면 다른
  /// 목록([_feed])이라 건드릴 필요 없고, 화면은 [notifyListeners]로 새로 그려진다.
  Future<void> loadViewPrefs() async {
    final epoch = _epoch;
    final saved = await NotificationViewPrefs.load(_userId());
    if (epoch != _epoch || _disposed) return;
    for (final tab in NotificationTab.values) {
      if (tab == NotificationTab.unreadChats) continue;
      _unreadOnly[tab] = saved[tab.name] ?? false;
    }
    _notify();
  }

  _Feed _feed(String kind, bool unreadOnly) =>
      _feeds.putIfAbsent('$kind|$unreadOnly', () => _Feed(kind, unreadOnly));

  /// 이 탭이 보여 줄 서버 목록들(전체 탭은 멘션+보드 둘).
  List<_Feed> _feedsFor(NotificationTab tab) {
    final uo = unreadOnly(tab);
    return switch (tab) {
      NotificationTab.mention => [_feed('mention', uo)],
      NotificationTab.board => [_feed('board', uo)],
      NotificationTab.all => [_feed('mention', uo), _feed('board', uo)],
      _ => const [],
    };
  }

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
    return _feedsFor(tab).any((f) => f.loading);
  }

  bool hasMore(NotificationTab tab) => _feedsFor(tab).any((f) => f.hasMore);

  bool isLoaded(NotificationTab tab) {
    if (tab == NotificationTab.project) return _projectLoaded;
    final feeds = _feedsFor(tab);
    return feeds.isEmpty || feeds.every((f) => f.loaded);
  }

  String? errorFor(NotificationTab tab) {
    if (tab == NotificationTab.project) return _projectError;
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
    final kind = n.isMention ? 'mention' : (n.isBoard ? 'board' : null);
    if (kind != null) {
      for (final f in _feeds.values) {
        if (f.kind != kind || !f.loaded) continue;
        if (f.items.any((x) => x.id == n.id)) continue;
        f.items.insert(0, n);
      }
    }
    final unread = event.unread;
    if (unread != null) {
      counts = unread;
    } else if (kind == 'mention') {
      counts = NotificationCounts(
        mention: counts.mention + 1,
        board: counts.board,
      );
    } else if (kind == 'board') {
      counts = NotificationCounts(
        mention: counts.mention,
        board: counts.board + 1,
      );
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
    _decrement(n);
    onRead?.call([n]);
    _notify();
    try {
      await apiProvider().markRead(ids: [n.id]);
    } catch (_) {
      await refreshCounts();
    }
  }

  void _decrement(AppNotification n) {
    if (n.isMention) {
      counts = NotificationCounts(
        mention: counts.mention > 0 ? counts.mention - 1 : 0,
        board: counts.board,
      );
    } else if (n.isBoard) {
      counts = NotificationCounts(
        mention: counts.mention,
        board: counts.board > 0 ? counts.board - 1 : 0,
      );
    }
  }

  /// [tab]의 서버 알림을 전부 읽음으로(전체 탭은 멘션·보드 둘 다). 안 읽은 대화·공지 같은 방 쪽 일은 화면이
  /// Session으로 따로 한다.
  Future<void> markAllRead(NotificationTab tab) async {
    final kinds = switch (tab) {
      NotificationTab.mention => ['mention'],
      NotificationTab.board => ['board'],
      NotificationTab.all => ['mention', 'board'],
      _ => const <String>[],
    };
    if (kinds.isEmpty) return;
    final now = DateTime.now();
    final read = <AppNotification>[];
    for (final f in _feeds.values) {
      if (!kinds.contains(f.kind)) continue;
      for (final n in f.items) {
        if (!n.isRead) {
          n.readAt = now;
          read.add(n);
        }
      }
    }
    counts = NotificationCounts(
      mention: kinds.contains('mention') ? 0 : counts.mention,
      board: kinds.contains('board') ? 0 : counts.board,
    );
    onRead?.call(read);
    if (kinds.contains('mention')) onSync?.call(counts);
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
  }) async {
    final before = settings ?? const NotificationSettings();
    settings = before.copyWith(mentionAll: mentionAll, boardLevel: boardLevel);
    _notify();
    try {
      final saved = await apiProvider().updateSettings(
        mentionAll: mentionAll,
        boardLevel: boardLevel,
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
  }

  /// 로그아웃 — 받아 둔 것을 전부 비운다(다음에 로그인하는 사람에게 남지 않게).
  void reset() {
    _epoch++;
    counts = const NotificationCounts();
    _feeds.clear();
    _unreadOnly.clear();
    project = const [];
    _projectLoaded = false;
    _projectLoading = false;
    _projectError = null;
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
    _reconnectSub?.cancel();
    super.dispose();
  }
}
