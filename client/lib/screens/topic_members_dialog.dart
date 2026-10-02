import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/pagination.dart';
import '../widgets/role_badge.dart';
import '../widgets/room_options_menu.dart' show CloseWhenRoomRemoved;
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';
import 'home_screen.dart' show wideBreakpoint;
import 'invite_members_screen.dart';
import 'member_profile_dialog.dart';
import 'my_profile_dialog.dart';

/// 토픽 "참여 멤버" — 채팅 헤더의 "멤버 N" 버튼이 연다. 넓은 화면(PC)은 떠 있는 창, 좁은
/// 화면(모바일)은 전체 화면.
Future<void> showTopicMembersDialog(
  BuildContext context,
  Session session,
  Room room,
) async {
  if (MediaQuery.sizeOf(context).width >= wideBreakpoint) {
    await showDialog<void>(
      context: context,
      builder: (_) =>
          TopicMembersScreen(session: session, room: room, asDialog: true),
    );
  } else {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TopicMembersScreen(session: session, room: room),
      ),
    );
  }
}

/// 참여 멤버 정렬 무리 — 본인 > 토픽 관리자 > 소유자(팀) > 관리자(계정) > 정회원 > 준회원.
int _memberRank(Room room, AppUser m, String? myId) {
  if (m.id == myId) return 0;
  if (room.isTopicAdmin(m.id)) return 1;
  if (m.isOwner) return 2;
  if (m.role == 'admin') return 3;
  if (m.role == 'guest') return 5;
  return 4;
}

/// 토픽 멤버를 참여 멤버 창의 순서(본인 > 토픽 관리자 > 소유자 > 관리자 > 정회원 > 준회원, 같은
/// 무리 안에서는 이름순)로 — 토픽 정보 변경하기의 멤버 목록도 같은 순서를 쓴다.
List<AppUser> sortTopicMembers(Room room, String? myId) {
  return room.members.toList()..sort((a, b) {
    final byRank = _memberRank(
      room,
      a,
      myId,
    ).compareTo(_memberRank(room, b, myId));
    return byRank != 0 ? byRank : a.name.compareTo(b.name);
  });
}

/// 이름·아이디·직책으로 거른다(대소문자 무시).
bool topicMemberMatches(AppUser m, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return m.name.toLowerCase().contains(q) ||
      m.username.toLowerCase().contains(q) ||
      (m.position?.toLowerCase().contains(q) ?? false);
}

/// 멤버 이름 옆 배지 — '토픽 관리자'(강조색), '소유자'(팀), '관리자'(계정), '준회원'. 정회원은 배지가
/// 없다. [withTopicAdmin]이 false면 토픽 관리자 배지를 뺀다(토픽 관리자 지정 목록처럼 체크로 이미
/// 보이는 곳).
List<Widget> topicMemberBadges(
  BuildContext context,
  Room room,
  AppUser m, {
  bool withTopicAdmin = true,
}) {
  final scheme = Theme.of(context).colorScheme;
  final owner = roleBadgeColors(context, 'owner');
  final admin = roleBadgeColors(context, 'admin');
  final guest = roleBadgeColors(context, 'guest');
  return [
    if (withTopicAdmin && room.isTopicAdmin(m.id))
      RoleBadge(
        label: '토픽 관리자',
        bg: scheme.primary.withValues(alpha: 0.16),
        fg: scheme.primary,
      ),
    if (m.isOwner) RoleBadge(label: '소유자', bg: owner.bg, fg: owner.fg),
    if (m.role == 'admin') RoleBadge(label: '관리자', bg: admin.bg, fg: admin.fg),
    if (m.role == 'guest') RoleBadge(label: '준회원', bg: guest.bg, fg: guest.fg),
  ];
}

/// 멤버 내보내기 확인 — 한 명이면 이름을, 여럿이면 인원수를 보여준다. 내보내기로 하면 true.
Future<bool> confirmKickTopicMembers(
  BuildContext context,
  List<AppUser> members,
) async {
  final who = members.length == 1
      ? "'${members.single.name}' 님을"
      : '선택한 멤버 ${members.length}명을';
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('멤버 내보내기'),
      content: SizedBox(
        width: 340,
        child: Text('$who 이 토픽에서 내보낼까요? 공개 토픽이면 다시 찾아서 참여할 수 있습니다.'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('취소'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(dialogContext).colorScheme.error,
            foregroundColor: Theme.of(dialogContext).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('내보내기'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// 멤버 목록 위의 회색 검색 칸(멤버 초대하기 창과 같은 모양) — 글자가 있으면 오른쪽 ✕로 지운다.
class TopicSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;
  final Key? fieldKey;
  const TopicSearchField({
    super.key,
    required this.controller,
    required this.hintText,
    required this.onChanged,
    this.fieldKey,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fill = theme.brightness == Brightness.dark
        ? theme.colorScheme.surfaceContainerHighest
        : const Color(0xFFF1F3F6);
    return Container(
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: TextField(
        key: fieldKey,
        controller: controller,
        onChanged: onChanged,
        style: const TextStyle(fontSize: 14),
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: hintText,
          prefixIcon: const Icon(Icons.search, size: 20),
          prefixIconConstraints: const BoxConstraints(minWidth: 36),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: '검색어 지우기',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
      ),
    );
  }
}

/// 참여 멤버 창 본문 — 검색, 멤버 목록(순서·배지), 행을 누르면 프로필, 토픽을 관리할 수 있으면
/// 내보낼 수 있는 행에 [내보내기].
class TopicMembersScreen extends StatefulWidget {
  final Session session;
  final Room room;
  final bool asDialog;

  /// PC 오른쪽 패널로 쓸 때(desktop_home_screen.dart) — 자체 헤더(제목+닫기)를 그리고, 라우트를
  /// 닫는 대신 [onClose]를 부른다. 토픽뿐 아니라 그룹채팅 멤버도 같은 패널로 본다(그룹은
  /// 관리자 배지·내보내기가 없다 — room.canManage가 토픽만 true).
  final bool asPanel;
  final VoidCallback? onClose;
  const TopicMembersScreen({
    super.key,
    required this.session,
    required this.room,
    this.asDialog = false,
    this.asPanel = false,
    this.onClose,
  });

  @override
  State<TopicMembersScreen> createState() => _TopicMembersScreenState();
}

class _TopicMembersScreenState extends State<TopicMembersScreen>
    with CloseWhenRoomRemoved {
  final _search = TextEditingController();
  final _scroll = ScrollController();

  /// 지금 내보내는 중인 멤버 — 그 행의 버튼 자리에 진행 표시를 둔다.
  final _kicking = <String>{};
  int _page = 0; // 패널 모드의 페이지(0-based).

  @override
  Session get roomSession => widget.session;
  @override
  String get watchedRoomId => widget.room.id;

  Session get session => widget.session;

  /// PC 창에만 항상 보이는 스크롤바를 붙인다(모바일 전체 화면은 기본 스크롤).
  Widget _withScrollbar(Widget list) => widget.asDialog || widget.asPanel
      ? MutedScrollbar(controller: _scroll, child: list)
      : list;

  @override
  void onWatchedRoomRemoved() {
    if (widget.asPanel) {
      widget.onClose?.call();
    } else {
      super.onWatchedRoomRemoved();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _openProfile(AppUser member) async {
    if (member.id == session.userId) {
      await showDialog<void>(
        context: context,
        builder: (_) => MyProfileDialog(session: session),
      );
      return;
    }
    // 프로필에서 "1:1 메시지"를 누르면 그 방이 돌아온다 — 이 창을 닫고 PC는 옆 패널을, 모바일은
    // 전체 화면으로 그 방을 연다(예전 멤버 목록과 같은 동작).
    final dm = await showDialog<Room>(
      context: context,
      builder: (_) => MemberProfileDialog(session: session, user: member),
    );
    if (dm == null || !mounted) return;
    if (widget.asPanel) {
      // 패널은 옆 패널일 뿐이라 라우트는 그대로 두고, 그 1:1 방으로 바꾸면서 패널을 닫는다.
      session.requestOpenRoom(dm);
      widget.onClose?.call();
      return;
    }
    final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
    final navigator = Navigator.of(context);
    navigator.pop();
    if (wide) {
      session.requestOpenRoom(dm);
    } else {
      navigator.push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(session: session, room: dm),
        ),
      );
    }
  }

  Future<void> _kick(Room room, AppUser member) async {
    if (!await confirmKickTopicMembers(context, [member]) || !mounted) return;
    setState(() => _kicking.add(member.id));
    try {
      await session.kickTopicMembers(room.id, [member.id]);
      if (mounted) showAppToast(context, "'${member.name}' 님을 내보냈습니다.");
    } catch (e) {
      if (mounted) showAppToast(context, '내보내지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _kicking.remove(member.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    // 내보내기·초대·다른 기기의 변경이 바로 보이도록 세션 변경마다 목록을 다시 그린다.
    final body = ListenableBuilder(
      listenable: session,
      builder: (context, _) =>
          _buildBody(context, session.roomById(widget.room.id) ?? widget.room),
    );
    if (widget.asPanel) {
      return ListenableBuilder(
        listenable: session,
        builder: (context, _) => _buildPanel(
          context,
          session.roomById(widget.room.id) ?? widget.room,
        ),
      );
    }
    if (widget.asDialog) {
      return FloatingDialog(
        title: '참여 멤버',
        maxWidth: 480,
        maxHeight: 640,
        child: body,
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('참여 멤버')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: body,
        ),
      ),
    );
  }

  /// PC 오른쪽 패널 — 상단바 팀 전체 "멤버" 패널(desktop_home_screen.dart의 _MembersPanel)과 같은
  /// 틀: 제목("멤버 총 N명")+닫기, 테두리 있는 검색칸, 구분선으로 나뉜 목록, 아래 페이지 번호.
  /// 이 방 전용으로 배지·내보내기(각 줄)가 더 있다(초대는 방 헤더의 초대 버튼에서).
  Widget _buildPanel(BuildContext context, Room room) {
    final theme = Theme.of(context);
    final all = sortTopicMembers(
      room,
      session.userId,
    ).where((m) => topicMemberMatches(m, _search.text)).toList();
    final totalPages = all.isEmpty
        ? 1
        : (all.length / paginationPageSize).ceil();
    final page = _page.clamp(0, totalPages - 1);
    final items = all
        .skip(page * paginationPageSize)
        .take(paginationPageSize)
        .toList();
    final canManage = room.canManage(session);
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '멤버 총 ${room.members.length}명',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '닫기',
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              key: const ValueKey('topic-members-search'),
              controller: _search,
              decoration: const InputDecoration(
                hintText: '멤버 검색',
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() => _page = 0),
            ),
          ),
          Expanded(
            child: all.isEmpty
                ? const Center(child: Text('검색 결과가 없습니다.'))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Divider(height: 1),
                      Expanded(
                        child: MutedScrollbar(
                          controller: _scroll,
                          child: ListView.separated(
                            controller: _scroll,
                            itemCount: items.length,
                            // 오른쪽 끝에 겹치는 스크롤바 아래로 선이 파고들지 않도록 그만큼 짧게 그린다.
                            separatorBuilder: (_, _) => const Padding(
                              padding: EdgeInsets.only(right: 12),
                              child: Divider(height: 1),
                            ),
                            itemBuilder: (context, i) {
                              final m = items[i];
                              final canKick =
                                  canManage && room.canKick(session, m.id);
                              return _MemberTile(
                                key: ValueKey('topic-member-${m.id}'),
                                session: session,
                                room: room,
                                member: m,
                                isMe: m.id == session.userId,
                                kicking: _kicking.contains(m.id),
                                onTap: () => _openProfile(m),
                                onKick: canKick ? () => _kick(room, m) : null,
                                panelStyle: true,
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
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, Room room) {
    final theme = Theme.of(context);
    final members = sortTopicMembers(
      room,
      session.userId,
    ).where((m) => topicMemberMatches(m, _search.text)).toList();
    final canManage = room.canManage(session);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TopicSearchField(
          fieldKey: const ValueKey('topic-members-search'),
          controller: _search,
          hintText: '이름이나 직책으로 검색',
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                '멤버 ${room.members.length}명',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: theme.hintColor,
                ),
              ),
            ),
            if (session.canInviteToRooms)
              TextButton.icon(
                onPressed: () => showInviteMembers(context, session, room),
                icon: const Icon(Icons.person_add_alt, size: 18),
                label: const Text('멤버 초대하기'),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: members.isEmpty
              ? Center(
                  child: Text(
                    '검색 결과가 없습니다.',
                    style: TextStyle(fontSize: 13, color: theme.hintColor),
                  ),
                )
              : _withScrollbar(
                  ListView.builder(
                    controller: _scroll,
                    itemCount: members.length,
                    itemBuilder: (context, i) {
                      final m = members[i];
                      final canKick = canManage && room.canKick(session, m.id);
                      return _MemberTile(
                        key: ValueKey('topic-member-${m.id}'),
                        session: session,
                        room: room,
                        member: m,
                        isMe: m.id == session.userId,
                        kicking: _kicking.contains(m.id),
                        onTap: () => _openProfile(m),
                        onKick: canKick ? () => _kick(room, m) : null,
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _MemberTile extends StatelessWidget {
  final Session session;
  final Room room;
  final AppUser member;
  final bool isMe;
  final bool kicking;
  final VoidCallback onTap;
  final VoidCallback? onKick;

  /// 오른쪽 패널의 줄 모양 — 팀 전체 멤버 패널의 줄(_MemberRow)처럼 아바타를 키우고 좌우 여백을 둔다.
  final bool panelStyle;

  const _MemberTile({
    super.key,
    required this.session,
    required this.room,
    required this.member,
    required this.isMe,
    required this.kicking,
    required this.onTap,
    required this.onKick,
    this.panelStyle = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final position = member.position?.trim();
    final badges = topicMemberBadges(context, room, member);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: panelStyle ? null : BorderRadius.circular(8),
        child: Padding(
          // 스크롤바(10px)가 [내보내기] 버튼을 덮지 않게 오른쪽을 조금 더 비운다.
          padding: panelStyle
              ? const EdgeInsets.fromLTRB(16, 10, 22, 10)
              : const EdgeInsets.fromLTRB(4, 8, 14, 8),
          child: Row(
            children: [
              UserAvatar(
                user: member,
                resolveUrl: session.resolveUrl,
                radius: panelStyle ? 20 : 18,
                online: session.onlineUserIds.contains(member.id),
              ),
              const SizedBox(width: 12),
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
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        ...badges,
                      ],
                    ),
                    if (position != null && position.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        position,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: theme.hintColor),
                      ),
                    ],
                  ],
                ),
              ),
              if (onKick != null) ...[
                const SizedBox(width: 8),
                if (kicking)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  TextButton(
                    onPressed: onKick,
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    child: const Text('내보내기'),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
