import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../models/team.dart';
import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/room_options_menu.dart'
    show CloseWhenRoomRemoved, TopicBadge, closeOwnRoute;
import '../widgets/user_avatar.dart';
import 'create_topic_screen.dart' show TopicVisibilityTile;
import 'home_screen.dart' show wideBreakpoint;
import 'topic_members_dialog.dart';

/// 토픽 정보 변경하기의 탭 — 마지막 토픽 관리자가 나가려다 막히면 "토픽 멤버 관리"로 바로 연다.
enum TopicSettingsTab { settings, members }

/// "토픽 정보 변경하기"(토픽을 관리할 수 있는 사람만) — 넓은 화면(PC)은 떠 있는 창, 좁은
/// 화면(모바일)은 전체 화면. 탭 두 개: 토픽 설정(이름·설명·공개·조용히 나가기·자동 초대·읽기 전용,
/// 보관·삭제) / 토픽 멤버 관리(토픽 관리자 지정·멤버 내보내기).
Future<void> showTopicSettingsDialog(
  BuildContext context,
  Session session,
  Room room, {
  TopicSettingsTab initialTab = TopicSettingsTab.settings,
}) async {
  if (MediaQuery.sizeOf(context).width >= wideBreakpoint) {
    await showDialog<void>(
      context: context,
      builder: (_) => TopicSettingsScreen(
        session: session,
        room: room,
        asDialog: true,
        initialTab: initialTab,
      ),
    );
  } else {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TopicSettingsScreen(
          session: session,
          room: room,
          initialTab: initialTab,
        ),
      ),
    );
  }
}

/// 이 방이 속한 팀을 내가 관리할 수 있는지(팀 소유자 또는 계정 관리자) — room_permissions.dart와
/// 같은 규칙. 토픽 관리자에서 나를 빼도 관리 권한이 남는지 미리 알려 주는 데만 쓴다.
bool _isTeamManagerOf(Session session, Room room) {
  Team? team;
  for (final t in session.teams) {
    if (t.id == room.teamId) team = t;
  }
  if (team == null && session.currentTeam?.id == room.teamId) {
    team = session.currentTeam;
  }
  return team?.canManage(session.accountRole) ?? session.canManageCurrentTeam;
}

class TopicSettingsScreen extends StatefulWidget {
  final Session session;
  final Room room;
  final bool asDialog;
  final TopicSettingsTab initialTab;
  const TopicSettingsScreen({
    super.key,
    required this.session,
    required this.room,
    this.asDialog = false,
    this.initialTab = TopicSettingsTab.settings,
  });

  @override
  State<TopicSettingsScreen> createState() => _TopicSettingsScreenState();
}

class _TopicSettingsScreenState extends State<TopicSettingsScreen>
    with SingleTickerProviderStateMixin, CloseWhenRoomRemoved {
  late final _tabs = TabController(
    length: 2,
    vsync: this,
    initialIndex: widget.initialTab.index,
  );

  /// 토픽 관리자 저장으로 스스로 관리 권한을 내려놓는 중 — 그때는 "권한이 없어졌다" 안내 없이 닫는다.
  bool _leavingAdmin = false;
  bool _closing = false;

  @override
  Session get roomSession => widget.session;
  @override
  String get watchedRoomId => widget.room.id;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    _tabs.dispose();
    super.dispose();
  }

  /// 다른 사람이 나를 토픽 관리자에서 빼는 등 관리 권한이 없어지면 창을 닫는다(방이 사라지는
  /// 경우는 CloseWhenRoomRemoved가 닫는다).
  void _onSessionChanged() {
    if (_closing || !mounted) return;
    final room = widget.session.roomById(widget.room.id);
    if (room == null || room.canManage(widget.session)) return;
    _closing = true;
    if (!_leavingAdmin) {
      showAppToast(context, '토픽을 관리할 수 있는 권한이 없어져 창을 닫았습니다.');
    }
    closeOwnRoute(context);
  }

  void _onDeleted() {
    _closing = true;
    closeOwnRoute(context);
  }

  @override
  Widget build(BuildContext context) {
    final tabBar = TabBar(
      controller: _tabs,
      tabs: const [
        Tab(text: '토픽 설정'),
        Tab(text: '토픽 멤버 관리'),
      ],
    );
    final views = TabBarView(
      controller: _tabs,
      children: [
        _SettingsTab(
          session: widget.session,
          room: widget.room,
          scrollbar: widget.asDialog,
          onDeleted: _onDeleted,
        ),
        _MembersTab(
          session: widget.session,
          room: widget.room,
          scrollbar: widget.asDialog,
          onLeavingAdmin: (v) => _leavingAdmin = v,
        ),
      ],
    );
    if (widget.asDialog) {
      return FloatingDialog(
        title: '토픽 정보 변경하기',
        maxWidth: 600,
        maxHeight: 760,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            tabBar,
            const SizedBox(height: 12),
            Expanded(child: views),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('토픽 정보 변경하기'), bottom: tabBar),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: views,
        ),
      ),
    );
  }
}

// ───────────────────────── 토픽 설정 ─────────────────────────

class _SettingsTab extends StatefulWidget {
  final Session session;
  final Room room;

  /// PC 창이면 항상 보이는 스크롤바를 붙인다(모바일 전체 화면은 기본 스크롤만).
  final bool scrollbar;
  final VoidCallback onDeleted;
  const _SettingsTab({
    required this.session,
    required this.room,
    required this.scrollbar,
    required this.onDeleted,
  });

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

/// 폼이 마지막으로 맞춘 방의 값 — 다른 사람이 설정을 바꾸면, 내가 손대지 않은 칸만 새 값으로 맞춘다.
/// [archived]는 폼 칸이 아니지만, 다른 관리자가 보관/해제하면 아래 보관 칸이 바로 바뀌도록 같이 본다.
typedef _TopicValues = ({
  String name,
  String description,
  bool isPublic,
  bool readOnly,
  bool autoInvite,
  bool quietLeave,
  bool archived,
});

class _SettingsTabState extends State<_SettingsTab>
    with AutomaticKeepAliveClientMixin {
  late final _name = TextEditingController(text: _room.name ?? '');
  late final _description = TextEditingController(
    text: _room.description ?? '',
  );
  final _scroll = ScrollController();
  late bool _isPublic = _room.isPublic;
  late bool _readOnly = _room.readOnly;
  late bool _autoInvite = _room.autoInvite;
  late bool _quietLeave = _room.quietLeave;

  /// 창을 연 순간의 값으로 initState에서 바로 잡는다 — 게으른 초기화면 처음 쓰이는 때(첫 변경
  /// 알림)의 새 값으로 잡혀서, 다른 관리자의 첫 변경을 놓치고 다음 저장이 그 값을 되돌렸다.
  late _TopicValues _baseline;

  String? _nameError;
  bool _saving = false;
  bool _archiving = false;
  bool _deleting = false;

  @override
  bool get wantKeepAlive => true;

  Room get _room => widget.session.roomById(widget.room.id) ?? widget.room;

  static _TopicValues _valuesOf(Room room) => (
    name: room.name ?? '',
    description: room.description ?? '',
    isPublic: room.isPublic,
    readOnly: room.readOnly,
    autoInvite: room.autoInvite,
    quietLeave: room.quietLeave,
    archived: room.isArchived,
  );

  @override
  void initState() {
    super.initState();
    _baseline = _valuesOf(_room);
    widget.session.addListener(_syncFromRoom);
  }

  @override
  void dispose() {
    widget.session.removeListener(_syncFromRoom);
    _name.dispose();
    _description.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 방 값이 바뀌었으면(내 저장 또는 다른 관리자의 변경) 손대지 않은 칸만 따라가게 한다. 보관
  /// 여부만 바뀌어도 다시 그린다(보관 칸의 제목·버튼). 글 칸은 그 값이 실제로 바뀌었을 때만 덮는다 —
  /// 다른 값(읽기 전용 등)만 바뀌었는데 덮으면, 이름 끝에 막 친 띄어쓰기가 지워지고 커서가 튄다.
  void _syncFromRoom() {
    if (!mounted) return;
    final now = _valuesOf(_room);
    if (now == _baseline) return;
    final before = _baseline;
    setState(() {
      if (now.name != before.name && _name.text.trim() == before.name) {
        _name.text = now.name;
      }
      if (now.description != before.description &&
          _description.text.trim() == before.description) {
        _description.text = now.description;
      }
      if (_isPublic == before.isPublic) _isPublic = now.isPublic;
      if (_readOnly == before.readOnly) _readOnly = now.readOnly;
      if (_autoInvite == before.autoInvite) _autoInvite = now.autoInvite;
      if (_quietLeave == before.quietLeave) _quietLeave = now.quietLeave;
      _baseline = now;
    });
  }

  /// 비공개 토픽은 자동 초대를 쓸 수 없다(서버도 끈다).
  bool get _effectiveAutoInvite => _isPublic && _autoInvite;

  bool get _dirty {
    final room = _room;
    return _name.text.trim() != (room.name ?? '') ||
        _description.text.trim() != (room.description ?? '') ||
        _isPublic != room.isPublic ||
        _readOnly != room.readOnly ||
        _effectiveAutoInvite != room.autoInvite ||
        _quietLeave != room.quietLeave;
  }

  Future<void> _save() async {
    if (_saving || !_dirty) return;
    final room = _room;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = '토픽 이름을 입력하세요.');
      return;
    }
    final description = _description.text.trim();
    setState(() {
      _saving = true;
      _nameError = null;
    });
    try {
      // 바뀐 값만 보낸다 — 서버가 바뀐 항목마다 안내 메시지를 남기므로.
      await widget.session.updateTopic(
        room.id,
        name: name != (room.name ?? '') ? name : null,
        description: description != (room.description ?? '')
            ? description
            : null,
        isPublic: _isPublic != room.isPublic ? _isPublic : null,
        readOnly: _readOnly != room.readOnly ? _readOnly : null,
        autoInvite: _effectiveAutoInvite != room.autoInvite
            ? _effectiveAutoInvite
            : null,
        quietLeave: _quietLeave != room.quietLeave ? _quietLeave : null,
      );
      if (mounted) showAppToast(context, '토픽 정보를 저장했습니다.');
    } catch (e) {
      if (mounted) showAppToast(context, '저장하지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleArchived() async {
    final room = _room;
    final archiving = !room.isArchived;
    final name = room.name ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(archiving ? '토픽 보관' : '토픽 보관 해제'),
        content: SizedBox(
          width: 360,
          child: Text(
            archiving
                ? "'$name' 토픽을 보관할까요?\n\n보관한 토픽은 목록의 '보관된 토픽'으로 옮겨지고, "
                      '읽기 전용이 되어 토픽 관리자만 글을 쓸 수 있습니다. 메시지와 파일은 그대로 '
                      '남고, 언제든 보관을 해제할 수 있습니다.'
                : "'$name' 토픽의 보관을 해제할까요?\n\n토픽 목록으로 다시 돌아오고, 멤버가 다시 "
                      '글을 쓸 수 있습니다(읽기 전용 설정이 켜져 있으면 토픽 관리자만).',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(archiving ? '보관' : '보관 해제'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _archiving = true);
    try {
      await widget.session.setTopicArchived(room.id, archiving);
      if (mounted) {
        showAppToast(context, archiving ? '토픽을 보관했습니다.' : '토픽 보관을 해제했습니다.');
      }
    } catch (e) {
      if (mounted) showAppToast(context, '바꾸지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _archiving = false);
    }
  }

  Future<void> _delete() async {
    final room = _room;
    final name = room.name ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _DeleteTopicDialog(name: name),
    );
    if (ok != true || !mounted) return;
    setState(() => _deleting = true);
    try {
      await widget.session.deleteTopic(room.id);
      // 목록에서 이미 빠졌다 — 이 기기에는 room:removed 안내가 안 오므로 여기서 알린다. 창과
      // 대화 화면은 방이 사라진 것을 보고 각자 닫힌다(대화 패널·모바일 대화 화면).
      if (!mounted) return;
      showAppToast(context, "'$name' 토픽을 삭제했습니다.");
      widget.onDeleted();
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      showAppToast(context, '토픽을 삭제하지 못했습니다: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final room = _room;
    final hint = theme.hintColor;
    final small = TextStyle(fontSize: 12, color: hint);
    final publicChanged = _isPublic != room.isPublic;

    final form = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _FieldLabel('이름'),
        TextField(
          key: const ValueKey('topic-settings-name'),
          controller: _name,
          maxLength: topicNameMaxLength,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: '토픽 이름을 입력하세요',
            border: const OutlineInputBorder(),
            isDense: true,
            errorText: _nameError,
          ),
          onChanged: (_) => setState(() => _nameError = null),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 12),
        const _FieldLabel('토픽 설명', optional: true),
        TextField(
          key: const ValueKey('topic-settings-description'),
          controller: _description,
          maxLength: topicDescriptionMaxLength,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: '어떤 이야기를 나누는 토픽인지 적어 주세요',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        const _FieldLabel('보기 방식'),
        _ViewModeReadOnly(viewMode: room.viewMode),
        const SizedBox(height: 20),
        const _FieldLabel('공개 여부'),
        RadioGroup<bool>(
          groupValue: _isPublic,
          onChanged: (v) => setState(() => _isPublic = v ?? _isPublic),
          child: const Column(
            children: [
              TopicVisibilityTile(
                key: ValueKey('topic-settings-public'),
                isPublic: true,
              ),
              TopicVisibilityTile(
                key: ValueKey('topic-settings-private'),
                isPublic: false,
              ),
            ],
          ),
        ),
        if (publicChanged)
          _NoticeBox(
            key: const ValueKey('topic-settings-visibility-notice'),
            icon: Icons.info_outline,
            text: _isPublic
                ? '공개로 바꾸면 정회원 누구나 이 토픽을 찾아 참여할 수 있고, 참여하면 이전 메시지도 볼 수 있습니다.'
                : '비공개로 바꾸면 이후에는 초대된 멤버만 참여할 수 있습니다. 지금 멤버는 그대로 남습니다.',
          ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Divider(height: 1),
        ),
        SwitchListTile(
          key: const ValueKey('topic-settings-quiet-leave'),
          contentPadding: EdgeInsets.zero,
          value: _quietLeave,
          onChanged: (v) => setState(() => _quietLeave = v),
          title: const Text('조용히 나가기'),
          subtitle: Text('멤버가 나가거나 내보내져도 안내 메시지를 남기지 않습니다', style: small),
        ),
        SwitchListTile(
          key: const ValueKey('topic-settings-auto-invite'),
          contentPadding: EdgeInsets.zero,
          value: _effectiveAutoInvite,
          onChanged: _isPublic ? (v) => setState(() => _autoInvite = v) : null,
          title: const Text('정회원 자동 초대'),
          subtitle: Text(
            _isPublic
                ? '새로 팀에 들어오는 정회원을 이 토픽에 자동으로 초대합니다. '
                      '설정한 뒤 새로 팀에 들어오는 정회원부터 적용됩니다'
                : '비공개 토픽은 자동 초대를 쓸 수 없습니다',
            style: small,
          ),
        ),
        SwitchListTile(
          key: const ValueKey('topic-settings-read-only'),
          contentPadding: EdgeInsets.zero,
          value: _readOnly,
          onChanged: (v) => setState(() => _readOnly = v),
          title: const Text('읽기 전용 설정'),
          subtitle: Text('토픽 관리자만 글을 쓸 수 있고, 다른 멤버는 읽기만 합니다', style: small),
        ),
        // 보관·삭제는 [저장]과 따로, 누르는 즉시(확인을 거쳐) 실행된다.
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Divider(height: 1),
        ),
        _DangerCard(
          title: room.isArchived ? '토픽 보관 해제' : '토픽 보관',
          description: room.isArchived
              ? '보관된 토픽입니다. 보관을 해제하면 토픽 목록으로 돌아오고 멤버가 다시 글을 쓸 수 있습니다.'
              : "보관하면 목록의 '보관된 토픽'으로 옮겨지고 읽기 전용이 됩니다. 내용은 그대로 남고, "
                    '언제든 해제할 수 있습니다.',
          badge: room.isArchived ? const TopicBadge.archived() : null,
          action: OutlinedButton.icon(
            key: const ValueKey('topic-settings-archive'),
            onPressed: _archiving || _deleting ? null : _toggleArchived,
            icon: Icon(
              room.isArchived
                  ? Icons.unarchive_outlined
                  : Icons.inventory_2_outlined,
              size: 18,
            ),
            label: Text(room.isArchived ? '보관 해제' : '토픽 보관'),
          ),
        ),
        const SizedBox(height: 12),
        _DangerCard(
          danger: true,
          title: '토픽 삭제',
          description: '토픽을 삭제하면 모든 멤버의 목록에서 사라지고, 메시지와 파일은 복구되지 않습니다.',
          action: FilledButton.icon(
            key: const ValueKey('topic-settings-delete'),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            onPressed: _deleting || _archiving ? null : _delete,
            icon: _deleting
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.onError,
                    ),
                  )
                : const Icon(Icons.delete_outline, size: 18),
            label: const Text('토픽 삭제'),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );

    final dirty = _dirty;
    final scrollView = SingleChildScrollView(
      controller: _scroll,
      // 스크롤바(10px)가 입력칸·스위치를 덮지 않게 오른쪽을 비운다.
      padding: EdgeInsets.only(right: widget.scrollbar ? 16 : 0),
      child: form,
    );
    // [저장]은 내용이 길어도 늘 보이게 스크롤 밖 아래에 둔다(팀 설정 창과 같은 방식).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: widget.scrollbar
              ? MutedScrollbar(controller: _scroll, child: scrollView)
              : scrollView,
        ),
        const Divider(height: 1),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                dirty ? '저장하지 않은 변경 사항이 있습니다.' : '바꾼 내용이 있으면 저장할 수 있습니다.',
                style: TextStyle(
                  fontSize: 12,
                  color: dirty ? theme.colorScheme.primary : hint,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('topic-settings-save'),
              onPressed: _saving || !dirty ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('저장'),
            ),
          ],
        ),
      ],
    );
  }
}

/// 굵은 항목 이름 — [optional]이면 옆에 회색 "(선택)".
class _FieldLabel extends StatelessWidget {
  final String text;
  final bool optional;
  const _FieldLabel(this.text, {this.optional = false});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: text,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          if (optional)
            TextSpan(
              text: '  (선택)',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).hintColor,
              ),
            ),
        ],
      ),
    ),
  );
}

/// 보기 방식은 만든 뒤 바꿀 수 없어서 글로만 보여준다.
class _ViewModeReadOnly extends StatelessWidget {
  final TopicViewMode viewMode;
  const _ViewModeReadOnly({required this.viewMode});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('topic-settings-view-mode'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              viewMode == TopicViewMode.board
                  ? Icons.dashboard_outlined
                  : Icons.chat_bubble_outline,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: viewMode.label,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      TextSpan(
                        text: '  ${viewMode.description}',
                        style: TextStyle(fontSize: 12, color: theme.hintColor),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.lock_outline, size: 13, color: theme.hintColor),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '만든 뒤에는 바꿀 수 없습니다',
                        style: TextStyle(fontSize: 11, color: theme.hintColor),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 옅은 강조색 바탕의 안내 한 줄(공개 여부를 바꿀 때의 설명 등).
class _NoticeBox extends StatelessWidget {
  final IconData icon;
  final String text;
  const _NoticeBox({super.key, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: scheme.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}

/// 보관·삭제처럼 바로 실행되는(확인을 한 번 더 거치는) 동작 칸 — 설정 저장과 섞이지 않게 따로 둔다.
class _DangerCard extends StatelessWidget {
  final String title;
  final String description;
  final Widget action;
  final Widget? badge;
  final bool danger;
  const _DangerCard({
    required this.title,
    required this.description,
    required this.action,
    this.badge,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = theme.colorScheme.error;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(
          color: danger ? error.withValues(alpha: 0.6) : theme.dividerColor,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (danger) ...[
                Icon(Icons.warning_amber_rounded, size: 18, color: error),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: danger ? error : null,
                  ),
                ),
              ),
              if (badge != null) ...[const SizedBox(width: 8), badge!],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: TextStyle(fontSize: 12, color: theme.hintColor),
          ),
          const SizedBox(height: 12),
          action,
        ],
      ),
    );
  }
}

/// 토픽 삭제 확인 — 실수를 막으려고 토픽 이름을 그대로 입력해야 삭제 버튼이 켜진다.
class _DeleteTopicDialog extends StatefulWidget {
  final String name;
  const _DeleteTopicDialog({required this.name});

  @override
  State<_DeleteTopicDialog> createState() => _DeleteTopicDialogState();
}

class _DeleteTopicDialogState extends State<_DeleteTopicDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _matches => _controller.text.trim() == widget.name.trim();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('토픽 삭제'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("'${widget.name}' 토픽을 삭제할까요?"),
            const SizedBox(height: 8),
            Text(
              '삭제된 토픽의 메시지와 파일은 복구되지 않습니다.',
              style: TextStyle(
                color: theme.colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '계속하려면 토픽 이름을 그대로 입력하세요.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('topic-delete-confirm-name'),
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                isDense: true,
                hintText: widget.name,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (_matches) Navigator.of(context).pop(true);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('topic-delete-confirm'),
          onPressed: _matches ? () => Navigator.of(context).pop(true) : null,
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          child: const Text('삭제'),
        ),
      ],
    );
  }
}

// ───────────────────────── 토픽 멤버 관리 ─────────────────────────

enum _MemberMode { admins, kick }

class _MembersTab extends StatefulWidget {
  final Session session;
  final Room room;

  /// PC 창이면 목록에 항상 보이는 스크롤바를 붙인다.
  final bool scrollbar;

  /// 토픽 관리자 저장으로 내가 관리 권한을 내려놓을 때(저장 직전 true, 실패하면 false).
  final ValueChanged<bool> onLeavingAdmin;
  const _MembersTab({
    required this.session,
    required this.room,
    required this.scrollbar,
    required this.onLeavingAdmin,
  });

  @override
  State<_MembersTab> createState() => _MembersTabState();
}

class _MembersTabState extends State<_MembersTab>
    with AutomaticKeepAliveClientMixin {
  _MemberMode _mode = _MemberMode.admins;
  final _search = TextEditingController();
  final _scroll = ScrollController();

  /// 토픽 관리자로 체크한 멤버 — 손대기 전까지는 방의 토픽 관리자를 그대로 따라간다.
  Set<String> _admins = {};
  bool _adminsEdited = false;

  /// 내보낼 멤버로 체크한 멤버.
  final _kick = <String>{};
  bool _busy = false;

  @override
  bool get wantKeepAlive => true;

  Session get session => widget.session;
  Room get _room => session.roomById(widget.room.id) ?? widget.room;

  Widget _scrollable(Widget list) => widget.scrollbar
      ? MutedScrollbar(controller: _scroll, child: list)
      : list;

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 토픽 관리자로 지정할 수 있는 멤버(정회원 이상)가 지금 방에서 토픽 관리자인 것.
  Set<String> _currentAdmins(Room room, List<AppUser> eligible) => {
    for (final m in eligible)
      if (room.isTopicAdmin(m.id)) m.id,
  };

  Future<void> _saveAdmins(Room room, List<AppUser> eligible) async {
    final ids = [
      for (final m in eligible)
        if (_admins.contains(m.id)) m.id,
    ];
    if (ids.isEmpty || _busy) return;
    final me = session.userId;
    final leaving =
        me != null &&
        !ids.contains(me) &&
        !_isTeamManagerOf(session, room) &&
        room.isTopicAdmin(me);
    widget.onLeavingAdmin(leaving);
    setState(() => _busy = true);
    try {
      await session.setTopicAdmins(room.id, ids);
      _adminsEdited = false;
      if (mounted) showAppToast(context, '토픽 관리자를 저장했습니다.');
    } catch (e) {
      widget.onLeavingAdmin(false);
      if (mounted) showAppToast(context, '토픽 관리자를 저장하지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _kickSelected(Room room, List<AppUser> targets) async {
    if (targets.isEmpty || _busy) return;
    if (!await confirmKickTopicMembers(context, targets) || !mounted) return;
    setState(() => _busy = true);
    try {
      await session.kickTopicMembers(room.id, [for (final m in targets) m.id]);
      _kick.clear();
      if (mounted) {
        showAppToast(
          context,
          targets.length == 1
              ? "'${targets.single.name}' 님을 내보냈습니다."
              : '멤버 ${targets.length}명을 내보냈습니다.',
        );
      }
    } catch (e) {
      if (mounted) showAppToast(context, '내보내지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 목록이 한 줄이라도 보이려면 필요한 세로 자리 — 이보다 좁으면(휴대폰에서 검색하느라 키보드가
  /// 올라온 경우 등) 이 높이로 그리고 탭 전체를 스크롤한다. 예전엔 목록이 0으로 눌리고 넘쳤다.
  /// 터치 기기(48px 터치 영역)와 PC(촘촘한 밀도)는 줄 높이가 달라서 따로 둔다 — 작은 PC 창에서
  /// 괜히 스크롤이 생겨 [저장]이 가려지지 않게.
  static double _minBodyHeight(BuildContext context) =>
      Theme.of(context).materialTapTargetSize == MaterialTapTargetSize.padded
      ? 330
      : 270;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 늘 같은 모양(스크롤 → 고정 높이)으로 그려서, 키보드가 오르내려도 검색 칸의 포커스가 풀리지 않는다.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: SizedBox(
          height: math.max(constraints.maxHeight, _minBodyHeight(context)),
          child: ListenableBuilder(
            listenable: session,
            builder: (context, _) => _buildBody(context, _room),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, Room room) {
    final sorted = sortTopicMembers(room, session.userId);
    final eligible = sorted.where(canBeTopicAdmin).toList();
    final current = _currentAdmins(room, eligible);
    if (!_adminsEdited) _admins = current;
    final query = _search.text;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<_MemberMode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: _MemberMode.admins, label: Text('토픽 관리자 지정')),
            ButtonSegment(value: _MemberMode.kick, label: Text('멤버 내보내기')),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => setState(() => _mode = s.first),
        ),
        const SizedBox(height: 12),
        TopicSearchField(
          fieldKey: const ValueKey('topic-manage-search'),
          controller: _search,
          hintText: '이름이나 직책으로 검색',
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: _mode == _MemberMode.admins
              ? _buildAdmins(context, room, eligible, current, query)
              : _buildKick(context, room, sorted, query),
        ),
      ],
    );
  }

  Widget _buildAdmins(
    BuildContext context,
    Room room,
    List<AppUser> eligible,
    Set<String> current,
    String query,
  ) {
    final theme = Theme.of(context);
    final visible = eligible
        .where((m) => topicMemberMatches(m, query))
        .toList();
    final me = session.userId;
    final changed = !setEquals(_admins, current);
    final none = _admins.isEmpty;
    final leavingSelf =
        me != null &&
        room.isTopicAdmin(me) &&
        !_admins.contains(me) &&
        !_isTeamManagerOf(session, room);
    final status = none
        ? Text(
            '토픽 관리자를 한 명 이상 지정하세요.',
            style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
          )
        : leavingSelf
        ? Text(
            '나를 빼면 저장한 뒤 이 토픽을 관리할 수 없습니다.',
            style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
          )
        : Text(
            '토픽 관리자 ${_admins.length}명',
            style: TextStyle(fontSize: 13, color: theme.hintColor),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '토픽 관리자는 토픽 정보를 바꾸고 멤버를 내보낼 수 있습니다. 정회원 이상 멤버만 지정할 수 있습니다.',
          style: TextStyle(fontSize: 12, color: theme.hintColor),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _ListBox(
            child: visible.isEmpty
                ? _EmptyText(
                    eligible.isEmpty
                        ? '토픽 관리자로 지정할 수 있는 정회원 이상 멤버가 없습니다.'
                        : '검색 결과가 없습니다.',
                  )
                : _scrollable(
                    ListView.builder(
                      controller: _scroll,
                      itemCount: visible.length,
                      itemBuilder: (context, i) {
                        final m = visible[i];
                        return _CheckRow(
                          key: ValueKey('topic-admin-${m.id}'),
                          session: session,
                          room: room,
                          member: m,
                          isMe: m.id == me,
                          checked: _admins.contains(m.id),
                          withTopicAdminBadge: false,
                          onChanged: _busy
                              ? null
                              : (v) => setState(() {
                                  _adminsEdited = true;
                                  if (v) {
                                    _admins = {..._admins, m.id};
                                  } else {
                                    _admins = {..._admins}..remove(m.id);
                                  }
                                }),
                        );
                      },
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: status),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('topic-admins-save'),
              onPressed: _busy || !changed || none
                  ? null
                  : () => _saveAdmins(room, eligible),
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('저장'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildKick(
    BuildContext context,
    Room room,
    List<AppUser> sorted,
    String query,
  ) {
    final theme = Theme.of(context);
    final me = session.userId;
    // 본인은 목록에서 뺀다. 내보낼 수 없는 멤버(팀 관리자가 아닐 때 다른 토픽 관리자)는
    // 체크만 막고 배지로 이유를 보여준다.
    final others = sorted
        .where((m) => m.id != me && topicMemberMatches(m, query))
        .toList();
    final kickable = [
      for (final m in others)
        if (room.canKick(session, m.id)) m,
    ];
    // 검색으로 가려진 멤버도 고른 채로 남는다(멤버 초대하기와 같다) — 인원 수·내보내기는 고른
    // 멤버 전부다. "모든 멤버 선택"만 지금 보이는 멤버에 적용된다.
    final selected = [
      for (final m in sorted)
        if (_kick.contains(m.id) && room.canKick(session, m.id)) m,
    ];
    final allSelectedCount = kickable.where((m) => _kick.contains(m.id)).length;
    final bool? allValue = allSelectedCount == 0
        ? false
        : (allSelectedCount == kickable.length ? true : null);
    final adminsProtected =
        !_isTeamManagerOf(session, room) &&
        others.any((m) => room.isTopicAdmin(m.id));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          adminsProtected
              ? '내보낸 멤버는 이 토픽을 더 볼 수 없습니다. 토픽 관리자는 다른 토픽 관리자를 내보낼 수 없습니다.'
              : '내보낸 멤버는 이 토픽을 더 볼 수 없습니다. 공개 토픽이면 다시 찾아서 참여할 수 있습니다.',
          style: TextStyle(fontSize: 12, color: theme.hintColor),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _ListBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    key: const ValueKey('topic-kick-select-all'),
                    onTap: kickable.isEmpty || _busy
                        ? null
                        : () => setState(() {
                            final ids = kickable.map((m) => m.id);
                            if (allValue == true) {
                              _kick.removeAll(ids);
                            } else {
                              _kick.addAll(ids);
                            }
                          }),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      child: Row(
                        children: [
                          Checkbox(
                            tristate: true,
                            value: kickable.isEmpty ? false : allValue,
                            onChanged: kickable.isEmpty || _busy
                                ? null
                                : (_) => setState(() {
                                    final ids = kickable.map((m) => m.id);
                                    if (allValue == true) {
                                      _kick.removeAll(ids);
                                    } else {
                                      _kick.addAll(ids);
                                    }
                                  }),
                          ),
                          const Text(
                            '모든 멤버 선택',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: others.isEmpty
                      ? _EmptyText(
                          room.members.length <= 1
                              ? '나 말고 다른 멤버가 없습니다.'
                              : '검색 결과가 없습니다.',
                        )
                      : _scrollable(
                          ListView.builder(
                            controller: _scroll,
                            itemCount: others.length,
                            itemBuilder: (context, i) {
                              final m = others[i];
                              final allowed = room.canKick(session, m.id);
                              return _CheckRow(
                                key: ValueKey('topic-kick-${m.id}'),
                                session: session,
                                room: room,
                                member: m,
                                isMe: false,
                                checked: allowed && _kick.contains(m.id),
                                onChanged: !allowed || _busy
                                    ? null
                                    : (v) => setState(() {
                                        if (v) {
                                          _kick.add(m.id);
                                        } else {
                                          _kick.remove(m.id);
                                        }
                                      }),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                '선택한 멤버 ${selected.length}명',
                style: TextStyle(fontSize: 13, color: theme.hintColor),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('topic-kick-submit'),
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
                foregroundColor: theme.colorScheme.onError,
              ),
              onPressed: selected.isEmpty || _busy
                  ? null
                  : () => _kickSelected(room, selected),
              child: _busy
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.onError,
                      ),
                    )
                  : const Text('내보내기'),
            ),
          ],
        ),
      ],
    );
  }
}

/// 목록 테두리 상자.
class _ListBox extends StatelessWidget {
  final Widget child;
  const _ListBox({required this.child});

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(8),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

class _EmptyText extends StatelessWidget {
  final String text;
  const _EmptyText(this.text);

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor),
      ),
    ),
  );
}

/// 체크박스 + 사진 + 이름(배지) 한 줄 — [onChanged]가 null이면 고를 수 없는 멤버(흐리게).
class _CheckRow extends StatelessWidget {
  final Session session;
  final Room room;
  final AppUser member;
  final bool isMe;
  final bool checked;
  final bool withTopicAdminBadge;
  final ValueChanged<bool>? onChanged;
  const _CheckRow({
    super.key,
    required this.session,
    required this.room,
    required this.member,
    required this.isMe,
    required this.checked,
    required this.onChanged,
    this.withTopicAdminBadge = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onChanged != null;
    final position = member.position?.trim();
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: enabled ? () => onChanged!(!checked) : null,
        child: Container(
          color: checked
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
              : null,
          // 스크롤바(10px) 자리만큼 오른쪽을 비운다.
          padding: const EdgeInsets.fromLTRB(6, 4, 14, 4),
          child: Opacity(
            opacity: enabled || checked ? 1 : 0.55,
            child: Row(
              children: [
                Checkbox(
                  value: checked,
                  onChanged: enabled ? (v) => onChanged!(v ?? false) : null,
                ),
                UserAvatar(
                  user: member,
                  resolveUrl: session.resolveUrl,
                  radius: 16,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: member.name),
                            if (isMe)
                              TextSpan(
                                text: ' (나)',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.normal,
                                  color: theme.hintColor,
                                ),
                              ),
                            if (position != null && position.isNotEmpty)
                              TextSpan(
                                text: '  $position',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.normal,
                                  color: theme.hintColor,
                                ),
                              ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      ...topicMemberBadges(
                        context,
                        room,
                        member,
                        withTopicAdmin: withTopicAdminBadge,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
