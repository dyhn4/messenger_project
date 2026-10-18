import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/org_tree.dart';
import '../models/room.dart';
import '../models/team.dart';
import '../services/api_client.dart' show PositionOption;
import '../services/session.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/org_tree_view.dart';
import '../widgets/role_badge.dart';
import '../widgets/sort_menu_button.dart';
import '../widgets/team_avatar.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';
import 'home_screen.dart' show wideBreakpoint;
import 'member_profile_dialog.dart';
import 'my_profile_dialog.dart';
import '../l10n/tr.dart';

/// "조직도" — 첫 탭 "부서"는 부서 트리와 부서장·상위자(org_tree_view.dart — 회사 하나면 정회원 이상, 팀마다면 그 팀 멤버가 본다).
/// 계정 등급 관리자·서버 운영자에게는 서버 전체 팀/회원 목록 탭이 더 붙는다 — "팀" 탭은 팀별로 묶어서 보여주고 팀을 누르면 그
/// 자리에 멤버가 펼쳐지며, "멤버" 탭은 서버 전체 회원을 한 번에 검색할 수 있는 목록이다. 어느 탭이든 회원을 누르면 기존 멤버
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
  /// 서버 전체 팀/회원 탭(관리자 이상)까지 보이는지 — 아니면 "부서" 탭 하나.
  late final bool _admin = widget.session.canViewOrgChart;
  late final _tabController = TabController(
    length: _admin ? 3 : 1,
    vsync: this,
  );

  /// 두 탭 목록의 스크롤 — 스크롤바(MutedScrollbar)와 목록이 같은 컨트롤러를 써야 한다. 안 주면 스크롤바가 기본
  /// 컨트롤러를 찾는데, PC에서는 목록이 거기 붙지 않아 "스크롤 위치가 없다"는 오류가 나고, 휴대폰에서는 두 탭
  /// 목록이 한 컨트롤러에 같이 붙어 오류가 났다.
  final _teamsScroll = ScrollController();
  final _membersScroll = ScrollController();
  List<OrgChartTeam>? _teams;
  List<AppUser>? _users;
  String? _error;
  String _filter = '';

  /// "팀" 탭에서 지금 펼쳐진 항목의 id. 팀은 그 id 그대로, "미소속" 묶음은 이 특수값을 쓴다.
  String? _expandedId;
  static const _unassignedId = '__unassigned__';

  /// "멤버" 탭 정렬 — "팀" 탭(팀별로 묶인 목록)에는 적용하지 않는다.
  MemberSortField _sortField = MemberSortField.name;
  bool _sortAscending = true;
  List<PositionOption>? _positionOptions;

  @override
  void initState() {
    super.initState();
    // 서버 전체 팀·회원 목록은 관리자 이상만 받는다(GET /org-chart/teams — 그 밖에는 403).
    if (_admin) _load();
    widget.session.fetchPublicPositionOptions().then((list) {
      if (mounted) setState(() => _positionOptions = list);
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _teamsScroll.dispose();
    _membersScroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      // 회원 목록(GET /users)은 계정 등급 관리자·서버 운영자에게만 서버 전체를 준다(그 밖에는 팀을 같이 쓰는 사람만) —
      // 조직도도 같은 사람만 열 수 있어서(GET /org-chart/teams) 여기서는 "미소속" 회원까지 다 받는다.
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

  Future<void> _openMember(AppUser user, {OrgTree? tree}) async {
    if (user.id == widget.session.userId) {
      await showDialog(
        context: context,
        builder: (_) => MyProfileDialog(session: widget.session),
      );
      return;
    }
    // "부서" 탭을 관리자가 아닌 사람이 연 경우 — 서버 전체 팀 목록이 없으니, 팀 조직도면 그 팀(조직도 사람은 모두 그 팀 멤버)으로
    // 대화를 시작하고, 회사 조직도면 보통 프로필 카드처럼 지금 팀 기준으로 연다.
    if (_teams == null) {
      final teamId = tree?.scope == 'team' ? tree?.teamId : null;
      final team = teamId == null
          ? null
          : OrgChartTeam(
              id: teamId,
              name: tree!.teamName ?? '',
              memberIds: [for (final m in tree.members) m.id],
            );
      final room = await showDialog<Room>(
        context: context,
        builder: (_) => MemberProfileDialog(
          session: widget.session,
          user: user,
          fromOrgChart: team != null,
          orgChartDmTeamCandidates: team == null ? const [] : [team],
          orgChartSecretTeamCandidates: team == null ? const [] : [team],
        ),
      );
      if (room == null || !mounted) return;
      _openRoom(room);
      return;
    }
    // 평문 DM은 나와 상대가 "함께" 속한 팀이 있어야 만들 수 있고, 비밀 대화는 내가 속한
    // 팀만 있으면 된다 — 조직도는 currentTeam이 없을 수도 있어서(팀 목록 화면) 후보 목록을
    // 미리 계산해서 프로필 카드에 넘긴다(여러 개면 그 카드가 팝업으로 골라준다).
    final teams = _teams ?? const <OrgChartTeam>[];
    final myId = widget.session.userId;
    final myTeams = myId == null
        ? const <OrgChartTeam>[]
        : teams.where((t) => t.memberIds.contains(myId)).toList();
    final shared = myTeams.where((t) => t.memberIds.contains(user.id)).toList();
    final room = await showDialog<Room>(
      context: context,
      builder: (_) => MemberProfileDialog(
        session: widget.session,
        user: user,
        fromOrgChart: true,
        orgChartDmTeamCandidates: shared,
        orgChartSecretTeamCandidates: myTeams,
      ),
    );
    if (room == null || !mounted) return;
    _openRoom(room);
  }

  void _openRoom(Room room) {
    // session.startDmInTeam/startSecretChatInTeam이 이미 그 팀으로 전환하고(requestOpenRoom)
    // "펼쳐서 보여줄 방"까지 정해뒀지만, 그걸 실제로 화면에 띄우는 건 넓은 화면(DesktopHomeScreen)
    // 쪽 코드뿐이다 — 좁은 화면(RoomListScreen)은 방 목록만 보여줄 뿐 새로 생긴 방을 알아서
    // 열어주지 않는다(HomeScreen의 비밀 대화 수락 처리와 같은 이유·같은 처리 방식).
    final isWide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
    final navigator = Navigator.of(context);
    navigator.pop(); // 조직도 다이얼로그 닫기
    if (!isWide) {
      navigator.push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(session: widget.session, room: room),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FloatingDialog(
      title: tr('조직도'),
      maxWidth: 520,
      maxHeight: 680,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_admin) ...[
            TabBar(
              controller: _tabController,
              tabs: [
                Tab(text: tr('부서')),
                Tab(text: tr('팀')),
                Tab(text: tr('멤버')),
              ],
              onTap: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            key: const ValueKey('org-chart-search'),
            decoration: InputDecoration(
              hintText: _admin ? tr('부서/팀/멤버 검색') : tr('부서/이름 검색'),
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              border: const OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _filter = v),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: TabBarView(
              controller: _tabController,
              children: [
                OrgTreeView(
                  session: widget.session,
                  filter: _filter,
                  onOpenMember: (user, tree) => _openMember(user, tree: tree),
                ),
                if (_admin) ...[
                  _adminTab(() => _buildTeamsTab(context)),
                  _adminTab(() => _buildMembersTab(context)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 관리자 탭 — 서버 전체 팀·회원을 다 받기 전에는 불러오는 중.
  Widget _adminTab(Widget Function() build) {
    if (_error != null) return Center(child: Text(_error!));
    if (_teams == null || _users == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return build();
  }

  Widget _buildTeamsTab(BuildContext context) {
    final filter = _filter.trim().toLowerCase();
    final assignedIds = <String>{for (final t in _teams!) ...t.memberIds};
    final unassigned = _users!
        .where((u) => !assignedIds.contains(u.id))
        .toList();

    final teamRows = _teams!
        .where((t) => filter.isEmpty || t.name.toLowerCase().contains(filter))
        .toList();
    final showUnassigned =
        unassigned.isNotEmpty && (filter.isEmpty || '미소속'.contains(filter));

    if (teamRows.isEmpty && !showUnassigned) {
      return Center(child: Text(tr('검색 결과가 없습니다.')));
    }

    return MutedScrollbar(
      controller: _teamsScroll,
      child: ListView(
        controller: _teamsScroll,
        children: [
          for (final team in teamRows)
            _TeamGroup(
              title: team.name,
              avatar: TeamAvatar(
                team: team.asAvatarTeam,
                resolveUrl: widget.session.resolveUrl,
                size: 36,
              ),
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
              title: tr('미소속'),
              avatar: CircleAvatar(
                radius: 18,
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.person_off_outlined,
                  size: 18,
                  color: Theme.of(context).hintColor,
                ),
              ),
              memberCount: unassigned.length,
              expanded: _expandedId == _unassignedId,
              onToggle: () => setState(
                () => _expandedId = _expandedId == _unassignedId
                    ? null
                    : _unassignedId,
              ),
              members: unassigned,
              session: widget.session,
              onSelectMember: _openMember,
            ),
        ],
      ),
    );
  }

  /// 직책 목록에서의 서열 — 목록은 이미 서열순(작을수록 낮음)으로 오므로 그 안에서의
  /// 위치(index)가 곧 서열이다. 목록에 없거나(미등록·계정 단위가 아닌 서버) 아직 안
  /// 불러왔으면 맨 뒤로 보낸다.
  int _positionRank(String? label) {
    if (label == null || label.isEmpty) return 1 << 30;
    final index = _positionOptions?.indexWhere((o) => o.label == label) ?? -1;
    return index == -1 ? 1 << 30 : index;
  }

  List<AppUser> _sortedMembers(List<AppUser> list) {
    final members = List<AppUser>.of(list);
    final cmp = switch (_sortField) {
      MemberSortField.name => (AppUser a, AppUser b) => a.name.compareTo(
        b.name,
      ),
      MemberSortField.role => (AppUser a, AppUser b) => accountRoleFromWire(
        a.role,
      ).rank.compareTo(accountRoleFromWire(b.role).rank),
      MemberSortField.position => (AppUser a, AppUser b) => _positionRank(
        a.position,
      ).compareTo(_positionRank(b.position)),
      // "멤버" 탭에는 팀 칼럼이 없어서 SortMenuButton.fields에 아예 안 넣는다 — 도달 안 함.
      MemberSortField.team => (AppUser a, AppUser b) => 0,
    };
    members.sort(_sortAscending ? cmp : (a, b) => cmp(b, a));
    return members;
  }

  Widget _buildMembersTab(BuildContext context) {
    final filter = _filter.trim().toLowerCase();
    final filtered = _users!
        .where((u) => filter.isEmpty || u.name.toLowerCase().contains(filter))
        .toList();
    if (filtered.isEmpty) {
      return Center(child: Text(tr('검색 결과가 없습니다.')));
    }
    final list = _sortedMembers(filtered);
    // 한 사람이 여러 팀의 소유자일 수 있지만, 이 목록은 팀별로 나뉘지 않은 전체 멤버
    // 목록이라 "적어도 한 팀의 소유자인지"만 배지로 보여준다.
    final ownerIds = <String>{
      for (final t in _teams!)
        if (t.ownerId != null) t.ownerId!,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _OrgMembersTableHead(
          sortField: _sortField,
          sortAscending: _sortAscending,
          onSortChanged: (field, ascending) => setState(() {
            _sortField = field;
            _sortAscending = ascending;
          }),
        ),
        const Divider(height: 1),
        Expanded(
          child: MutedScrollbar(
            controller: _membersScroll,
            child: ListView.separated(
              controller: _membersScroll,
              itemCount: list.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => _OrgMemberTableRow(
                user: list[i],
                resolveUrl: widget.session.resolveUrl,
                online: widget.session.onlineUserIds.contains(list[i].id),
                isOwner: ownerIds.contains(list[i].id),
                onTap: () => _openMember(list[i]),
              ),
            ),
          ),
        ),
      ],
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
                  tr('{memberCount}명', {'memberCount': memberCount}),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).hintColor,
                  ),
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
                tr('멤버가 없습니다.'),
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
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).hintColor,
                      ),
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

/// "멤버" 탭 목록 위 칼럼 제목 — 관리자 콘솔 "회원" 탭/팀 설정 "멤버" 탭과 같은 비율
/// (이름 9 / 등급 5 / 직책 5)로 맞추고, 맨 오른쪽에 정렬 버튼을 둔다.
class _OrgMembersTableHead extends StatelessWidget {
  final MemberSortField sortField;
  final bool sortAscending;
  final void Function(MemberSortField field, bool ascending) onSortChanged;

  const _OrgMembersTableHead({
    required this.sortField,
    required this.sortAscending,
    required this.onSortChanged,
  });

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).hintColor,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Row(
        children: [
          Expanded(flex: 9, child: Text(tr('이름'), style: style)),
          const SizedBox(width: 16),
          Expanded(flex: 5, child: Text(tr('등급'), style: style)),
          const SizedBox(width: 16),
          Expanded(flex: 5, child: Text(tr('직책'), style: style)),
          SortMenuButton<MemberSortField>(
            fields: const [
              MemberSortField.name,
              MemberSortField.role,
              MemberSortField.position,
            ],
            labelOf: (f) => f.label,
            selectedField: sortField,
            ascending: sortAscending,
            onChanged: onSortChanged,
          ),
        ],
      ),
    );
  }
}

/// "멤버" 탭 한 줄: 아바타·이름 / 등급(+소유자) 뱃지 / 직책 — 관리자 콘솔 "회원" 탭·팀 설정
/// "멤버" 탭과 같은 칼럼 구조(_OrgMemberRow와 달리 "팀" 탭 안에 중첩되지 않는 이 탭 전용).
class _OrgMemberTableRow extends StatelessWidget {
  final AppUser user;
  final String Function(String relative) resolveUrl;
  final bool online;
  final bool isOwner;
  final VoidCallback onTap;
  const _OrgMemberTableRow({
    required this.user,
    required this.resolveUrl,
    required this.online,
    required this.isOwner,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final role = accountRoleFromWire(user.role);
    final roleColors = roleBadgeColors(context, role.wire);
    final ownerColors = roleBadgeColors(context, 'owner');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              flex: 9,
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
                    child: Text(
                      user.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 5,
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  RoleBadge(
                    label: role.label,
                    bg: roleColors.bg,
                    fg: roleColors.fg,
                  ),
                  if (isOwner)
                    RoleBadge(
                      label: tr('소유자'),
                      bg: ownerColors.bg,
                      fg: ownerColors.fg,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 5,
              child: Text(
                user.position?.isNotEmpty == true ? user.position! : tr('미등록'),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Theme.of(context).hintColor,
                  fontStyle: user.position?.isNotEmpty == true
                      ? FontStyle.normal
                      : FontStyle.italic,
                ),
              ),
            ),
            // 제목 줄 맨 오른쪽의 정렬 단추 자리 — 비워 두지 않으면 이 줄의 칼럼들이 그만큼 더 넓어져서
            // 제목(등급·직책)과 가로 위치가 어긋난다.
            const SizedBox(width: sortMenuButtonWidth),
          ],
        ),
      ),
    );
  }
}
