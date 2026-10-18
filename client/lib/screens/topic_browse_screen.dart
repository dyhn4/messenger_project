import 'package:flutter/material.dart';

import '../models/room.dart';
import '../services/api_client.dart';
import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/private_topic_lock.dart';
import '../widgets/room_options_menu.dart' show TopicBadge, closeOwnRoute;
import 'chat_screen.dart';
import 'create_topic_screen.dart';
import 'home_screen.dart' show wideBreakpoint;
import 'topic_members_dialog.dart' show TopicSearchField;
import '../l10n/tr.dart';

/// 참여 가능한 토픽 보기 — 넓은 화면(PC)은 떠 있는 창, 좁은 화면(모바일)은 전체 화면.
/// 참여하거나 이미 참여 중인 토픽을 열면 이 창을 닫고 [onOpenRoom]으로 그 토픽을 연다.
Future<void> showTopicBrowse(
  BuildContext context,
  Session session, {
  required void Function(Room) onOpenRoom,
}) async {
  if (MediaQuery.sizeOf(context).width >= wideBreakpoint) {
    await showDialog<void>(
      context: context,
      builder: (_) => TopicBrowseScreen(
        session: session,
        asDialog: true,
        onOpenRoom: onOpenRoom,
      ),
    );
  } else {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            TopicBrowseScreen(session: session, onOpenRoom: onOpenRoom),
      ),
    );
  }
}

class TopicBrowseScreen extends StatefulWidget {
  final Session session;
  final bool asDialog;

  /// 참여한(또는 열기를 누른) 토픽을 여는 방법 — 안 주면 PC는 옆 패널, 모바일은 전체 화면으로 연다.
  final void Function(Room)? onOpenRoom;
  const TopicBrowseScreen({
    super.key,
    required this.session,
    this.asDialog = false,
    this.onOpenRoom,
  });

  @override
  State<TopicBrowseScreen> createState() => _TopicBrowseScreenState();
}

class _TopicBrowseScreenState extends State<TopicBrowseScreen>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 2, vsync: this);
  final _search = TextEditingController();

  /// 탭마다 목록 스크롤 — PC에서는 스크롤바가 기본 컨트롤러를 못 찾아서 각자 따로 둔다.
  final _joinableScroll = ScrollController();
  final _joinedScroll = ScrollController();
  List<TopicBrowseEntry>? _topics;
  String? _error;

  /// 지금 참여 요청 중인 토픽 — 그 행의 버튼에 진행 표시를 두고 다른 행은 잠시 막는다.
  String? _joiningId;

  Session get session => widget.session;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _search.dispose();
    _joinableScroll.dispose();
    _joinedScroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final team = session.currentTeam;
      if (team == null) throw ApiException(tr('팀을 먼저 선택하세요.'));
      final topics = await session.api!.browseTopics(team.id);
      if (!mounted) return;
      setState(() => _topics = topics);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  /// 공개 토픽 중 아직 참여하지 않은 것 / 참여 중인 것(비공개 포함) — 검색어로 거르고, 보관된
  /// 토픽은 뒤로, 그다음 이름순.
  List<TopicBrowseEntry> _entries({required bool joined}) {
    final q = _search.text.trim().toLowerCase();
    final list = [
      for (final t in _topics ?? const <TopicBrowseEntry>[])
        if ((joined ? t.joined : t.isPublic && !t.joined) &&
            (q.isEmpty ||
                t.name.toLowerCase().contains(q) ||
                (t.description?.toLowerCase().contains(q) ?? false)))
          t,
    ];
    list.sort((a, b) {
      if (a.archived != b.archived) return a.archived ? 1 : -1;
      return a.name.compareTo(b.name);
    });
    return list;
  }

  /// [onOpenRoom]이 없을 때(예전 진입점) — 이 화면을 닫은 뒤에도 쓸 수 있게 미리 잡아 둔다.
  void Function(Room) _opener() {
    final given = widget.onOpenRoom;
    if (given != null) return given;
    final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
    final navigator = Navigator.of(context);
    final session = this.session;
    return (room) {
      if (wide) {
        session.requestOpenRoom(room);
      } else {
        navigator.push(
          MaterialPageRoute(
            builder: (_) => ChatScreen(session: session, room: room),
          ),
        );
      }
    };
  }

  void _closeAndOpen(Room room) {
    final open = _opener();
    closeOwnRoute(context);
    open(room);
  }

  Future<void> _join(TopicBrowseEntry topic) async {
    if (_joiningId != null) return;
    setState(() => _joiningId = topic.id);
    try {
      final room = await session.joinRoom(topic.id);
      if (!mounted) return;
      _closeAndOpen(room);
    } catch (e) {
      if (!mounted) return;
      setState(() => _joiningId = null);
      showAppToast(context, tr('참여하지 못했습니다: {e}', {'e': e}));
    }
  }

  void _open(TopicBrowseEntry topic) {
    final room = session.roomById(topic.id);
    if (room == null) {
      showAppToast(context, tr('토픽을 열 수 없습니다. 잠시 후 다시 시도하세요.'));
      return;
    }
    _closeAndOpen(room);
  }

  /// 여기서 새 토픽을 만들면, 만든 토픽을 열기 전에 이 목록부터 닫는다.
  Future<void> _createTopic() async {
    final open = _opener();
    await showCreateTopicFlow(
      context,
      session,
      onOpenRoom: (room) {
        if (mounted) closeOwnRoute(context);
        open(room);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final joinable = _entries(joined: false);
    final joined = _entries(joined: true);
    final canCreate = session.canCreateTopic;

    final search = TopicSearchField(
      fieldKey: const ValueKey('topic-browse-search'),
      controller: _search,
      hintText: tr('토픽 이름이나 설명으로 검색'),
      onChanged: (_) => setState(() {}),
    );
    final tabBar = TabBar(
      controller: _tabs,
      tabs: [
        Tab(
          text: tr('참여 가능한 토픽 {joinable.length}', {
            'joinable.length': joinable.length,
          }),
        ),
        Tab(
          text: tr('참여 중인 토픽 {joined.length}', {
            'joined.length': joined.length,
          }),
        ),
      ],
    );
    final Widget content;
    if (_error != null) {
      content = _Message(
        icon: Icons.cloud_off_outlined,
        text: tr('토픽 목록을 불러오지 못했습니다.\n{_error}', {'_error': _error}),
        action: OutlinedButton.icon(
          onPressed: () {
            setState(() => _topics = null);
            _load();
          },
          icon: const Icon(Icons.refresh, size: 18),
          label: Text(tr('다시 시도')),
        ),
      );
    } else if (_topics == null) {
      content = const Center(child: CircularProgressIndicator());
    } else {
      content = TabBarView(
        controller: _tabs,
        children: [
          _buildList(context, joinable, joinedTab: false, canCreate: canCreate),
          _buildList(context, joined, joinedTab: true, canCreate: canCreate),
        ],
      );
    }

    if (widget.asDialog) {
      return FloatingDialog(
        title: tr('참여 가능한 토픽 보기'),
        maxWidth: 640,
        maxHeight: 680,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: search),
                if (canCreate) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _createTopic,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(tr('새로운 토픽 생성하기')),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            tabBar,
            Expanded(child: content),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr('참여 가능한 토픽 보기'))),
      // 새 토픽 만들기는 팀 설정(토픽 생성 권한)에 따라 막혀 있을 수 있다 — 찾아서 참여하기는
      // 그 설정과 무관하게 항상 쓸 수 있다.
      floatingActionButton: canCreate
          ? FloatingActionButton(
              tooltip: tr('새로운 토픽 생성하기'),
              onPressed: _createTopic,
              child: const Icon(Icons.add),
            )
          : null,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: search,
            ),
            tabBar,
            Expanded(child: content),
          ],
        ),
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    List<TopicBrowseEntry> entries, {
    required bool joinedTab,
    required bool canCreate,
  }) {
    if (entries.isEmpty) {
      if (_search.text.trim().isNotEmpty) {
        return _Message(
          icon: Icons.search_off,
          text: tr('\'{p0}\'에 맞는 토픽이 없습니다.', {'p0': _search.text.trim()}),
        );
      }
      if (joinedTab) {
        return _Message(icon: Icons.tag, text: tr('참여 중인 토픽이 없습니다.'));
      }
      return _Message(
        icon: Icons.travel_explore,
        text: tr('참여할 수 있는 공개 토픽이 없습니다.\n공개 토픽이 새로 생기면 여기에 보입니다.'),
        action: canCreate && widget.asDialog
            ? FilledButton.tonalIcon(
                onPressed: _createTopic,
                icon: const Icon(Icons.add, size: 18),
                label: Text(tr('새로운 토픽 생성하기')),
              )
            : null,
      );
    }
    // 준회원은 토픽을 찾아 직접 참여할 수 없다(서버도 막는다).
    final guest = !session.canCreateRooms;
    final scroll = joinedTab ? _joinedScroll : _joinableScroll;
    final list = ListView.separated(
      controller: scroll,
      // 모바일은 오른쪽 아래 + 버튼이 마지막 행을 가리지 않게 아래를 더 비운다.
      padding: EdgeInsets.fromLTRB(0, 8, 0, widget.asDialog ? 8 : 88),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 68),
      itemBuilder: (context, i) {
        final t = entries[i];
        return _TopicRow(
          key: ValueKey('topic-browse-${t.id}'),
          topic: t,
          busy: _joiningId == t.id,
          guest: guest,
          locked: _joiningId != null,
          onJoin: () => _join(t),
          onOpen: () => _open(t),
        );
      },
    );
    // PC 창에만 항상 보이는 스크롤바를 붙인다(모바일 전체 화면은 기본 스크롤).
    return widget.asDialog
        ? MutedScrollbar(controller: scroll, child: list)
        : list;
  }
}

class _TopicRow extends StatelessWidget {
  final TopicBrowseEntry topic;
  final bool busy;

  /// 준회원이라 참여할 수 없음(버튼을 끄고 이유를 툴팁으로).
  final bool guest;

  /// 다른 토픽에 참여하는 중이라 잠시 막아 둠.
  final bool locked;
  final VoidCallback onJoin;
  final VoidCallback onOpen;
  const _TopicRow({
    super.key,
    required this.topic,
    required this.busy,
    required this.guest,
    required this.locked,
    required this.onJoin,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final description = topic.description?.trim();
    final meta = topic.adminNames.isEmpty
        ? tr('멤버 {topic.memberCount}명', {
            'topic.memberCount': topic.memberCount,
          })
        : tr('멤버 {topic.memberCount}명 · 관리자 {p0}', {
            'topic.memberCount': topic.memberCount,
            'p0': topic.adminNames.join(', '),
          });
    final Widget button;
    if (topic.joined) {
      button = OutlinedButton(onPressed: onOpen, child: Text(tr('열기')));
    } else if (busy) {
      button = const FilledButton(
        onPressed: null,
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else {
      button = FilledButton(
        onPressed: guest || locked ? null : onJoin,
        child: Text(tr('참여하기')),
      );
    }
    return Padding(
      // 스크롤바(10px)가 버튼을 덮지 않게 오른쪽을 비운다.
      padding: const EdgeInsets.fromLTRB(12, 10, 18, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: topic.archived
                  ? scheme.surfaceContainerHighest
                  : scheme.primaryContainer.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              topic.isBoard ? Icons.dashboard_outlined : Icons.tag,
              size: 22,
              color: topic.archived
                  ? scheme.onSurfaceVariant
                  : scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 이름이 길면 배지가 다음 줄로 내려가고, 이름은 한 줄에서 말줄임한다.
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      topic.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (!topic.isPublic) const PrivateTopicLock(),
                    if (topic.isBoard) TopicBadge.board(),
                    if (topic.readOnly) TopicBadge.readOnly(),
                    if (topic.archived) TopicBadge.archived(),
                  ],
                ),
                if (description != null && description.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 3),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: !topic.joined && guest
                ? Tooltip(message: tr('준회원은 토픽에 직접 참여할 수 없습니다'), child: button)
                : button,
          ),
        ],
      ),
    );
  }
}

/// 빈 목록·오류 안내 — 가운데 아이콘과 문구, 필요하면 버튼.
class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;
  const _Message({required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: hint.withValues(alpha: 0.6)),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: hint, height: 1.5),
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
