import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../services/api_client.dart' show ApiException;
import '../services/session.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/invite_result_dialog.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/private_topic_lock.dart';
import '../widgets/user_avatar.dart';
import 'invite_members_screen.dart' show showPickMembers;
import '../l10n/tr.dart';

/// "여러 토픽/그룹채팅에 초대" — 사이드바 토픽 '+' 메뉴(PC)가 연다. 잔디의 순서 그대로 세 단계다.
/// ① "멤버 초대하기" 창에서 멤버를 고르고 "다음", ② "토픽/그룹채팅 선택" 창에서 초대할 대화방을 고르고
/// "초대하기"(이전으로 돌아가도 고른 멤버는 유지), ③ "초대 완료" 창에서 방별 결과를 확인한다.
Future<void> showInviteToMultipleRooms(
  BuildContext context,
  Session session,
) async {
  var selected = <AppUser>[];
  while (true) {
    final users = await showPickMembers(
      context,
      session,
      title: tr('멤버 초대하기'),
      initialSelected: [for (final u in selected) u.id],
      confirmLabel: tr('다음'),
      requireSelection: true,
    );
    if (users == null || users.isEmpty || !context.mounted) return;
    selected = users;
    final step = await showDialog<InviteRoomsStep>(
      context: context,
      builder: (_) => InviteRoomsDialog(session: session, users: users),
    );
    if (step == null || !context.mounted) return;
    final results = step.results;
    if (results != null) {
      await showInviteResultDialog(context, session: session, results: results);
      return;
    }
    // 이전 — 고른 멤버를 그대로 둔 채 첫 단계로 돌아간다.
  }
}

/// "토픽/그룹채팅 선택" 창이 닫히며 돌려주는 값 — [results]가 있으면 초대를 마친 것, 없으면 "이전".
class InviteRoomsStep {
  final List<RoomInviteResult>? results;
  const InviteRoomsStep.back() : results = null;
  const InviteRoomsStep.done(List<RoomInviteResult> this.results);
}

/// "토픽/그룹채팅 선택" — 내가 참여 중인 토픽(보관된 토픽 포함)과 그룹채팅을 묶음별 체크박스로 고른다.
/// 고른 멤버가 이미 전원 참여 중인 방은 "이미 참여중"으로 비활성이고, 일부만 참여 중이면 "N명 참여중"이다.
class InviteRoomsDialog extends StatefulWidget {
  final Session session;

  /// 1단계에서 고른 멤버(고른 순서).
  final List<AppUser> users;
  const InviteRoomsDialog({
    super.key,
    required this.session,
    required this.users,
  });

  @override
  State<InviteRoomsDialog> createState() => _InviteRoomsDialogState();
}

class _InviteRoomsDialogState extends State<InviteRoomsDialog> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _picked = <String>{};
  bool _submitting = false;
  String? _error;

  Session get _session => widget.session;
  String get _myId => _session.userId ?? '';

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 초대할 수 있는 대화방 후보 — 지금 팀에서 내가 참여 중인 토픽(보관된 토픽 포함)과 그룹채팅.
  /// 1:1·나와의 대화·비밀 대화는 빠진다.
  List<Room> _candidates() {
    final teamId = _session.currentTeam?.id;
    return [
      for (final r in _session.rooms)
        if ((r.type == RoomType.topic || r.type == RoomType.group) &&
            !r.isSecret &&
            !r.isSelf &&
            (teamId == null || r.teamId == teamId) &&
            r.members.any((m) => m.id == _myId))
          r,
    ];
  }

  /// 고른 멤버 중 이 방에 이미 있는 사람 수.
  int _already(Room room) {
    final ids = {for (final m in room.members) m.id};
    return widget.users.where((u) => ids.contains(u.id)).length;
  }

  bool _full(Room room) => _already(room) >= widget.users.length;

  List<Room> _section(List<Room> all, RoomType type, String q) {
    final list = [
      for (final r in all)
        if (r.type == type &&
            (q.isEmpty || r.displayName(_myId).toLowerCase().contains(q)))
          r,
    ];
    if (type == RoomType.topic) {
      list.sort((a, b) {
        if (a.isArchived != b.isArchived) return a.isArchived ? 1 : -1;
        return a.displayName(_myId).compareTo(b.displayName(_myId));
      });
    } else {
      list.sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
    }
    return list;
  }

  void _toggle(Room room) => setState(() {
    if (!_picked.remove(room.id)) _picked.add(room.id);
  });

  void _toggleSection(List<Room> rooms) => setState(() {
    final ids = [
      for (final r in rooms)
        if (!_full(r)) r.id,
    ];
    if (ids.isNotEmpty && ids.every(_picked.contains)) {
      _picked.removeAll(ids);
    } else {
      _picked.addAll(ids);
    }
  });

  Future<void> _submit() async {
    if (_picked.isEmpty || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final results = await _session.inviteMembersBulk([
        for (final u in widget.users) u.id,
      ], _picked.toList());
      if (!mounted) return;
      Navigator.of(context).pop(InviteRoomsStep.done(results));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e is ApiException
            ? e.message
            : tr('초대하지 못했습니다. 잠시 후 다시 시도하세요.');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_submitting,
      child: FloatingDialog(
        title: tr('토픽/그룹채팅 선택'),
        maxWidth: 600,
        maxHeight: 740,
        child: ListenableBuilder(
          listenable: _session,
          builder: (context, _) => _buildBody(context),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);
    final q = _search.text.trim().toLowerCase();
    final all = _candidates();
    // 그사이 사라진(나간·삭제된) 방은 선택에서 뺀다.
    _picked.removeWhere((id) => !all.any((r) => r.id == id));
    final topics = _section(all, RoomType.topic, q);
    final groups = _section(all, RoomType.group, q);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildMembersSummary(context),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('invite-rooms-search'),
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            isDense: true,
            hintText: tr('토픽/그룹채팅 검색'),
            prefixIcon: Icon(Icons.search, size: 20),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: topics.isEmpty && groups.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        all.isEmpty
                            ? tr('초대할 수 있는 토픽이나 그룹채팅이 없습니다.')
                            : tr('검색 결과가 없습니다.'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.hintColor),
                      ),
                    ),
                  )
                : MutedScrollbar(
                    controller: _scroll,
                    child: ListView(
                      controller: _scroll,
                      children: [
                        if (topics.isNotEmpty)
                          ..._buildSection('topic', tr('토픽'), topics),
                        if (groups.isNotEmpty)
                          ..._buildSection('group', tr('그룹채팅'), groups),
                      ],
                    ),
                  ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(
            _error!,
            key: const ValueKey('invite-rooms-error'),
            style: TextStyle(fontSize: 13, color: theme.colorScheme.error),
          ),
        ],
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              key: const ValueKey('invite-rooms-back'),
              onPressed: _submitting
                  ? null
                  : () =>
                        Navigator.of(context).pop(const InviteRoomsStep.back()),
              child: Text(tr('이전')),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('invite-rooms-submit'),
              onPressed: _picked.isEmpty || _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      _picked.isEmpty
                          ? tr('초대하기')
                          : tr('초대하기 ({_picked.length})', {
                              '_picked.length': _picked.length,
                            }),
                    ),
            ),
          ],
        ),
      ],
    );
  }

  /// 위쪽 — 1단계에서 고른 멤버 요약(아바타 몇 개 + "N명" + 이름들).
  Widget _buildMembersSummary(BuildContext context) {
    final theme = Theme.of(context);
    final users = widget.users;
    const shown = 5;
    return Container(
      key: const ValueKey('invite-rooms-members'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 18.0 * (users.length < shown ? users.length : shown) + 10,
            height: 28,
            child: Stack(
              children: [
                for (var i = 0; i < users.length && i < shown; i++)
                  Positioned(
                    left: 18.0 * i,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: theme.colorScheme.surface,
                          width: 1.5,
                        ),
                      ),
                      child: UserAvatar(
                        user: users[i],
                        resolveUrl: _session.resolveUrl,
                        radius: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            tr('{users.length}명', {'users.length': users.length}),
            key: const ValueKey('invite-rooms-members-count'),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              users.map((u) => u.name).join(', '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: theme.hintColor),
            ),
          ),
        ],
      ),
    );
  }

  /// 묶음 하나 — 묶음 전체 선택 체크박스가 있는 제목 줄과 방 줄들.
  List<Widget> _buildSection(String id, String label, List<Room> rooms) {
    final selectable = [
      for (final r in rooms)
        if (!_full(r)) r,
    ];
    final picked = selectable.where((r) => _picked.contains(r.id)).length;
    final bool? value = picked == 0
        ? false
        : (picked == selectable.length ? true : null);
    final canPick = selectable.isNotEmpty && !_submitting;
    return [
      Material(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        child: InkWell(
          key: ValueKey('invite-rooms-section-$id'),
          onTap: canPick ? () => _toggleSection(rooms) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Row(
              children: [
                Checkbox(
                  tristate: true,
                  value: selectable.isEmpty ? false : value,
                  onChanged: canPick ? (_) => _toggleSection(rooms) : null,
                ),
                Text(
                  '$label ${rooms.length}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      for (final room in rooms) _buildRoomRow(room),
    ];
  }

  Widget _buildRoomRow(Room room) {
    final theme = Theme.of(context);
    final already = _already(room);
    final full = _full(room);
    final selected = _picked.contains(room.id);
    final enabled = !full && !_submitting;
    final status = full
        ? tr('이미 참여중')
        : already > 0
        ? tr('{already}명 참여중', {'already': already})
        : null;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: ValueKey('invite-room-${room.id}'),
        onTap: enabled ? () => _toggle(room) : null,
        child: Container(
          color: selected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
              : null,
          padding: const EdgeInsets.fromLTRB(6, 4, 12, 4),
          child: Opacity(
            opacity: full ? 0.55 : 1,
            child: Row(
              children: [
                Checkbox(
                  value: selected,
                  onChanged: enabled ? (_) => _toggle(room) : null,
                ),
                InviteRoomLeading(
                  session: _session,
                  room: room,
                  type: room.type,
                  size: 32,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          room.displayName(_myId),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (room.isPrivateTopic) ...[
                        const SizedBox(width: 4),
                        const PrivateTopicLock(),
                      ],
                      if (room.isArchived) ...[
                        const SizedBox(width: 6),
                        Container(
                          key: ValueKey('invite-room-archived-${room.id}'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: theme.dividerColor.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            tr('보관됨'),
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.hintColor,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr('{room.members.length}명', {
                        'room.members.length': room.members.length,
                      }),
                      style: TextStyle(fontSize: 12, color: theme.hintColor),
                    ),
                    if (status != null)
                      Text(
                        status,
                        key: ValueKey('invite-room-status-${room.id}'),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: full
                              ? theme.hintColor
                              : theme.colorScheme.primary,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
