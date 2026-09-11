import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../models/team.dart';
import '../services/session.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/team_avatar.dart';
import '../widgets/user_avatar.dart';
import 'member_profile_dialog.dart';
import 'my_profile_dialog.dart';

/// "조직도" — 관리자 이상만 볼 수 있는, 서버 전체 팀/회원 목록(팀 목록 화면의 AppBar에서 연다).
/// "팀" 탭(기본값)은 팀별로 묶어서 보여주고, 팀을 누르면 그 자리에 멤버가 펼쳐진다. "멤버"
/// 탭은 서버 전체 회원을 한 번에 검색할 수 있는 목록이다. 둘 다 회원을 누르면 기존 멤버
/// 패널과 같은 프로필 카드(사진+1:1/비밀 대화)가 뜬다.
Future<void> showOrgChartScreen(BuildContext context, Session session) {
  return showDialog<void>(
    context: context,
    builder: (_) => _OrgChartScreen(session: session),
  );
}

class _OrgChartScreen extends StatefulWidget {
  final Session session;
  const _OrgChartScreen({required this.session});

  @override
  State<_OrgChartScreen> createState() => _OrgChartScreenState();
}

class _OrgChartScreenState extends State<_OrgChartScreen>
    with SingleTickerProviderStateMixin {
  late final _tabController = TabController(length: 2, vsync: this);
  List<OrgChartTeam>? _teams;
  List<AppUser>? _users;
  String? _error;
  String _filter = '';

  /// "팀" 탭에서 지금 펼쳐진 항목의 id. 팀은 그 id 그대로, "미소속" 묶음은 이 특수값을 쓴다.
  String? _expandedId;
  static const _unassignedId = '__unassigned__';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.session.fetchOrgChartTeams(),
        widget.session.fetchAllUsers(),
      ]);
      if (!mounted) return;
      setState(() {
        _teams = results[0] as List<OrgChartTeam>;
        _users = (results[1] as List<AppUser>)
          ..sort((a, b) => a.name.compareTo(b.name));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  AppUser? _userById(String id) {
    final list = _users;
    if (list == null) return null;
    final match = list.where((u) => u.id == id);
    return match.isEmpty ? null : match.first;
  }

  Future<void> _openMember(AppUser user) async {
    if (user.id == widget.session.userId) {
      await showDialog(
        context: context,
        builder: (_) => MyProfileDialog(session: widget.session),
      );
      return;
    }
    // 평문 DM은 나와 상대가 "함께" 속한 팀이 있어야 만들 수 있고, 비밀 대화는 내가 속한
    // 팀만 있으면 된다 — 조직도는 currentTeam이 없을 수도 있어서(팀 목록 화면) 미리 둘 다
    // 계산해서 프로필 카드에 넘긴다.
    final teams = _teams ?? const <OrgChartTeam>[];
    final myId = widget.session.userId;
    final myTeams = myId == null
        ? const <OrgChartTeam>[]
        : teams.where((t) => t.memberIds.contains(myId)).toList();
    final shared = myTeams.where((t) => t.memberIds.contains(user.id));
    final room = await showDialog<Room>(
      context: context,
      builder: (_) => MemberProfileDialog(
        session: widget.session,
        user: user,
        fromOrgChart: true,
        orgChartDmTeamId: shared.isEmpty ? null : shared.first.id,
        orgChartSecretTeamId: myTeams.isEmpty ? null : myTeams.first.id,
      ),
    );
    if (room != null && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return FloatingDialog(
      title: '조직도',
      maxWidth: 480,
      maxHeight: 640,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TabBar(
            controller: _tabController,
            tabs: const [Tab(text: '팀'), Tab(text: '멤버')],
          ),
          const SizedBox(height: 12),
          TextField(
            decoration: const InputDecoration(
              hintText: '팀/멤버 검색',
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 18),
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _filter = v),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: _error != null
                ? Center(child: Text(_error!))
                : (_teams == null || _users == null)
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    controller: _tabController,
                    children: [_buildTeamsTab(context), _buildMembersTab(context)],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTeamsTab(BuildContext context) {
    final filter = _filter.trim().toLowerCase();
    final assignedIds = <String>{for (final t in _teams!) ...t.memberIds};
    final unassigned = _users!.where((u) => !assignedIds.contains(u.id)).toList();

    final teamRows = _teams!
        .where((t) => filter.isEmpty || t.name.toLowerCase().contains(filter))
        .toList();
    final showUnassigned =
        unassigned.isNotEmpty && (filter.isEmpty || '미소속'.contains(filter));

    if (teamRows.isEmpty && !showUnassigned) {
      return const Center(child: Text('검색 결과가 없습니다.'));
    }

    return MutedScrollbar(
      child: ListView(
        children: [
          for (final team in teamRows)
            _TeamGroup(
              title: team.name,
              avatar: TeamAvatar(team: team.asAvatarTeam, size: 36),
              memberCount: team.memberIds.length,
              expanded: _expandedId == team.id,
              onToggle: () => setState(
                () => _expandedId = _expandedId == team.id ? null : team.id,
              ),
              members: team.memberIds
                  .map(_userById)
                  .whereType<AppUser>()
                  .toList(),
              session: widget.session,
              onSelectMember: _openMember,
            ),
          if (showUnassigned)
            _TeamGroup(
              title: '미소속',
              avatar: CircleAvatar(
                radius: 18,
                backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.person_off_outlined,
                  size: 18,
                  color: Theme.of(context).hintColor,
                ),
              ),
              memberCount: unassigned.length,
              expanded: _expandedId == _unassignedId,
              onToggle: () => setState(
                () => _expandedId =
                    _expandedId == _unassignedId ? null : _unassignedId,
              ),
              members: unassigned,
              session: widget.session,
              onSelectMember: _openMember,
            ),
        ],
      ),
    );
  }

  Widget _buildMembersTab(BuildContext context) {
    final filter = _filter.trim().toLowerCase();
    final list = _users!
        .where((u) => filter.isEmpty || u.name.toLowerCase().contains(filter))
        .toList();
    if (list.isEmpty) {
      return const Center(child: Text('검색 결과가 없습니다.'));
    }
    return MutedScrollbar(
      child: ListView.separated(
        itemCount: list.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) => _OrgMemberRow(
          user: list[i],
          resolveUrl: widget.session.resolveUrl,
          online: widget.session.onlineUserIds.contains(list[i].id),
          onTap: () => _openMember(list[i]),
        ),
      ),
    );
  }
}

/// "팀" 탭 한 묶음: 팀 헤더(아바타+이름+인원수, 누르면 펼침) + 펼쳐지면 구분선 아래로 그
/// 팀 멤버 목록.
class _TeamGroup extends StatelessWidget {
  final String title;
  final Widget avatar;
  final int memberCount;
  final bool expanded;
  final VoidCallback onToggle;
  final List<AppUser> members;
  final Session session;
  final ValueChanged<AppUser> onSelectMember;

  const _TeamGroup({
    required this.title,
    required this.avatar,
    required this.memberCount,
    required this.expanded,
    required this.onToggle,
    required this.members,
    required this.session,
    required this.onSelectMember,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            child: Row(
              children: [
                avatar,
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Text(
                  '$memberCount명',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
                ),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  color: Theme.of(context).hintColor,
                ),
              ],
            ),
          ),
        ),
        if (expanded) ...[
          const Divider(height: 1),
          if (members.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '멤버가 없습니다.',
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
            )
          else
            for (final member in members)
              Padding(
                padding: const EdgeInsets.only(left: 20),
                child: _OrgMemberRow(
                  user: member,
                  resolveUrl: session.resolveUrl,
                  online: session.onlineUserIds.contains(member.id),
                  onTap: () => onSelectMember(member),
                ),
              ),
          const Divider(height: 1),
        ],
      ],
    );
  }
}

/// 멤버 한 줄: 아바타 + 이름(+부서·직책). 데스크톱 홈 화면 "멤버" 패널의 행과 같은 스타일.
class _OrgMemberRow extends StatelessWidget {
  final AppUser user;
  final String Function(String relative) resolveUrl;
  final bool online;
  final VoidCallback onTap;
  const _OrgMemberRow({
    required this.user,
    required this.resolveUrl,
    required this.online,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(
          children: [
            UserAvatar(
              user: user,
              resolveUrl: resolveUrl,
              radius: 18,
              online: online,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (user.orgLine != null)
                    Text(
                      user.orgLine!,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
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
