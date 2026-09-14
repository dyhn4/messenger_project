import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/team.dart';
import '../services/session.dart';
import '../widgets/org_edit_dialog.dart';
import '../widgets/user_avatar.dart';

/// 다른 사용자의 프로필 플로팅 카드: 프로필 사진 + 이름 + 1:1 메시지 시작.
/// 아이디/이메일은 아이디·비밀번호 찾기에 쓰이는 개인정보라 다른 사람에게는 보여주지 않는다.
/// 멤버 패널 카드, 채팅방 메시지의 다른 사람 아바타/이름을 눌렀을 때 공용으로 쓴다.
class MemberProfileDialog extends StatefulWidget {
  final Session session;
  final AppUser user;

  /// 조직도에서 열었으면 true — DM/비밀 대화 둘 다 "방"이라 팀 하나를 걸어야 하는데
  /// (server rooms.js/secretChats.js), 조직도에는 지금 보고 있는 팀(currentTeam)이 없을 수도
  /// 있어서(팀 목록 화면에서 열 수 있으므로) 이 값들을 대신 쓴다. 채팅방 아바타 클릭 등
  /// 원래 방식대로 열 때는 false로 두고 지금 보고 있는 팀을 그대로 쓴다.
  final bool fromOrgChart;

  /// 평문 DM은 나와 상대가 "함께" 속한 팀이어야 한다(상대가 그 팀 멤버가 아니면 서버가
  /// 막는다) — 조직도 화면이 미리 계산해서 넘긴다. 후보가 여러 개면(같이 속한 팀이 두 개
  /// 이상) 어느 팀으로 시작할지 팝업으로 물어보고, 하나뿐이면 바로 그 팀으로, 없으면(빈
  /// 목록) 1:1 메시지 버튼을 감추고 이유를 보여준다.
  final List<OrgChartTeam> orgChartDmTeamCandidates;

  /// 비밀 대화는 내가 속한 팀이 하나만 있으면 된다 — 평문 DM과 달리 상대가 그 팀 소속일
  /// 필요는 없다(server/src/secretChats.js). 마찬가지로 후보가 여러 개면 팝업으로 물어본다.
  final List<OrgChartTeam> orgChartSecretTeamCandidates;

  const MemberProfileDialog({
    super.key,
    required this.session,
    required this.user,
    this.fromOrgChart = false,
    this.orgChartDmTeamCandidates = const [],
    this.orgChartSecretTeamCandidates = const [],
  });

  @override
  State<MemberProfileDialog> createState() => _MemberProfileDialogState();
}

class _MemberProfileDialogState extends State<MemberProfileDialog> {
  bool _starting = false;
  bool _startingSecret = false;

  /// 이 카드는 조직도뿐 아니라 채팅방 메시지의 아바타를 눌러서도 열리는데, 그쪽에서 넘어오는
  /// AppUser는 방 멤버 목록에서 온 것이라 팀 정보(등급/부서/직책)가 비어 있다. 어디서 열든
  /// 같은 내용이 보이도록 팀 멤버 목록에서 이 사람을 찾아 채워 넣는다.
  late AppUser _user = widget.user;

  /// "팀" 항목용 — null이면 아직 불러오는 중. 노출 범위(대상이 관리자면 나와 겹치는 팀만,
  /// 아니면 전체)는 서버(GET /users/:id/teams)가 정한다.
  List<Team>? _teams;

  @override
  void initState() {
    super.initState();
    if (widget.user.role == null) _loadTeamInfo();
    _loadTeams();
  }

  Future<void> _loadTeamInfo() async {
    try {
      final members = await widget.session.fetchTeamMembers();
      final match = members.where((u) => u.id == widget.user.id);
      if (match.isNotEmpty && mounted) setState(() => _user = match.first);
    } catch (_) {
      // 부가 정보라 실패하면 넘어온 값 그대로 보여준다.
    }
  }

  Future<void> _loadTeams() async {
    try {
      final teams = await widget.session.fetchUserTeams(widget.user.id);
      if (mounted) setState(() => _teams = teams);
    } catch (_) {
      if (mounted) setState(() => _teams = []);
    }
  }

  Future<void> _editOrg() async {
    final position = await showOrgEditDialog(context, widget.session, _user);
    final team = widget.session.currentTeam;
    if (position == null || team == null || !mounted) return;
    try {
      final members = await widget.session.updateTeamMember(
        team,
        _user.id,
        position: position,
      );
      final match = members.where((u) => u.id == _user.id);
      if (match.isNotEmpty && mounted) setState(() => _user = match.first);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('실패: $e')));
      }
    }
  }

  /// [candidates]가 여러 개면 어느 팀으로 시작할지 팝업으로 물어본다(하나뿐이면 바로 그
  /// 팀, 취소하면 null). 조직도가 아닌 곳(fromOrgChart=false)에서는 애초에 후보 목록이
  /// 비어 있으므로 항상 null(호출부가 지금 보고 있는 팀을 그대로 쓴다).
  Future<String?> _resolveTeamId(
    List<OrgChartTeam> candidates, {
    required String title,
  }) async {
    if (candidates.isEmpty) return null;
    if (candidates.length == 1) return candidates.first.id;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(title),
        children: [
          for (final team in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(team.id),
              child: Text(team.name),
            ),
        ],
      ),
    );
  }

  /// 이 팀들이면 상대와 공통 팀이 없어도 "팀원 추가"로 그 팀에 상대를 새로 넣고 그 팀에서
  /// 1:1 메시지를 시작할 수 있다 — 내가 소유자이거나 관리자인 내 팀들.
  List<Team> get _manageableTeamsForAdd =>
      widget.session.teams.where(widget.session.canManageTeam).toList();

  /// DM 시작에 쓸 팀 id를 정한다. fromOrgChart가 아니면 항상 null(호출부가 지금 보고 있는
  /// 팀을 그대로 씀). 조직도에서는: 공통 팀이 하나면 바로 그 팀, 여러 개면 고르는 팝업,
  /// 하나도 없으면(무소속이거나 나와 겹치는 팀이 없는 회원) 내가 관리할 수 있는 팀이 있는
  /// 경우에 한해 "팀원 추가" 버튼으로 그 팀에 상대를 새로 넣고 그 팀 id를 돌려준다.
  /// null을 돌려주면서 fromOrgChart가 true면 "팝업을 취소했다"는 뜻 — 호출부가 조용히 멈춘다.
  Future<String?> _resolveDmTeamId() async {
    if (!widget.fromOrgChart) return null;
    final candidates = widget.orgChartDmTeamCandidates;
    if (candidates.length == 1) return candidates.first.id;
    if (candidates.length > 1) {
      return showDialog<String>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('어느 팀으로 1:1 메시지를 시작할까요?'),
          children: [
            for (final team in candidates)
              SimpleDialogOption(
                onPressed: () => Navigator.of(dialogContext).pop(team.id),
                child: Text(team.name),
              ),
          ],
        ),
      );
    }

    final team = await showDialog<Team>(
      context: context,
      builder: (_) => _AddThenDmDialog(manageableTeams: _manageableTeamsForAdd),
    );
    if (team == null || !mounted) return null;
    try {
      await widget.session.addTeamMembers(team, [widget.user.id]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('팀원 추가 실패: $e')));
      }
      return null;
    }
    return team.id;
  }

  Future<void> _startDm() async {
    final teamId = await _resolveDmTeamId();
    // fromOrgChart인데(팝업이 실제로 떴는데) 취소를 누른 경우만 조용히 멈춘다 — 후보가
    // 애초에 비어 있는(fromOrgChart=false) 경우는 null이 정상이라 계속 진행해야 한다.
    if (widget.fromOrgChart && teamId == null) return;
    if (!mounted) return;
    setState(() => _starting = true);
    try {
      final room = teamId != null
          ? await widget.session.startDmInTeam(teamId, widget.user.id)
          : await widget.session.startDm(widget.user.id);
      if (!mounted) return;
      Navigator.of(context).pop(room);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('대화 시작 실패: $e')));
      setState(() => _starting = false);
    }
  }

  /// 비밀 대화는 일반 DM과 완전히 다른 방(별도 dmKey)으로 취급한다 — 텔레그램의 실제 동작처럼,
  /// 같은 상대와의 평범한 대화와 비밀 대화가 서로 다른 채팅방 목록 항목으로 공존한다.
  Future<void> _startSecretChat() async {
    final teamId = await _resolveTeamId(
      widget.orgChartSecretTeamCandidates,
      title: '어느 팀으로 비밀 대화를 시작할까요?',
    );
    if (widget.orgChartSecretTeamCandidates.length > 1 && teamId == null) {
      return;
    }
    if (!mounted) return;
    setState(() => _startingSecret = true);
    try {
      final room = teamId != null
          ? await widget.session.startSecretChatInTeam(teamId, widget.user.id)
          : await widget.session.startSecretChat(widget.user.id);
      if (!mounted) return;
      Navigator.of(context).pop(room);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('비밀 대화 시작 실패: $e')));
      setState(() => _startingSecret = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _user;
    // 준회원은 스스로 대화를 열 수 없다(초대받은 방에서만 활동) — 서버도 막지만 버튼부터 감춘다.
    final canStartChat = widget.session.canCreateRooms;
    // 조직도에서 열었을 때만 팀 조건이 걸린다 — DM은 나와 상대가 함께 속한 팀이 있어야 하고,
    // 비밀 대화는 내가 속한 팀이 하나만 있으면 된다(둘 다 방이라 NOT NULL인 team_id가 필요).
    // 공통 팀이 없어도(무소속이거나 나와 겹치는 팀이 없는 회원) 내가 팀원을 추가할 수 있는
    // 팀이 하나라도 있으면 "팀원 추가"로 시작할 수 있으니 버튼을 계속 보여준다.
    final canStartDm =
        canStartChat &&
        (!widget.fromOrgChart ||
            widget.orgChartDmTeamCandidates.isNotEmpty ||
            _manageableTeamsForAdd.isNotEmpty);
    final canStartSecret =
        canStartChat &&
        (!widget.fromOrgChart ||
            widget.orgChartSecretTeamCandidates.isNotEmpty);
    final role = user.role == null ? null : accountRoleFromWire(user.role);
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 90,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                ),
              ),
              alignment: Alignment.bottomCenter,
              child: Transform.translate(
                offset: const Offset(0, 30),
                child: UserAvatar(
                  user: user,
                  resolveUrl: widget.session.resolveUrl,
                  radius: 32,
                ),
              ),
            ),
            const SizedBox(height: 40),
            Text(
              user.name,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            if (role != null) ...[
              const SizedBox(height: 4),
              Text(
                user.isOwner ? '${role.label} · 이 팀의 소유자' : role.label,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).hintColor,
                ),
              ),
            ],
            const SizedBox(height: 12),
            _OrgSection(
              teamNames: _teams?.map((t) => t.name).toList(),
              position: user.position,
              // 직책은 인사 정보라 본인이 임의로 못 바꾸고 소유자·관리자만 수정한다.
              onEdit: widget.session.canManageCurrentTeam ? _editOrg : null,
            ),
            const SizedBox(height: 16),
            if (canStartChat) ...[
              if (canStartDm) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: FilledButton.icon(
                    onPressed: _starting ? null : _startDm,
                    icon: _starting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.chat_bubble_outline),
                    label: const Text('1:1 메시지'),
                  ),
                ),
                const SizedBox(height: 8),
              ] else if (widget.fromOrgChart)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Text(
                    '함께 속한 팀이 없어 1:1 메시지는 보낼 수 없습니다.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              if (canStartSecret)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: OutlinedButton.icon(
                    onPressed: _startingSecret ? null : _startSecretChat,
                    icon: _startingSecret
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.lock_outline, color: Colors.green),
                    label: const Text(
                      '비밀 대화 시작',
                      style: TextStyle(color: Colors.green),
                    ),
                  ),
                ),
            ] else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '준회원은 초대받은 방에서만 대화할 수 있습니다.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

/// 조직도에서 상대와 함께 속한 팀이 없을 때(무소속이거나 나와 겹치는 팀이 없는 회원) 뜬다 —
/// 처음엔 그 사실과 "팀원 추가" 버튼만 보여주고, 버튼을 누르면 내가 관리할 수 있는(소유자·
/// 관리자) 팀 목록으로 화면이 바뀐다. 고른 팀을 그대로 pop해서 돌려주고, 실제로 그 팀에
/// 상대를 추가하는 일은 호출부(_resolveDmTeamId)가 한다.
class _AddThenDmDialog extends StatefulWidget {
  final List<Team> manageableTeams;
  const _AddThenDmDialog({required this.manageableTeams});

  @override
  State<_AddThenDmDialog> createState() => _AddThenDmDialogState();
}

class _AddThenDmDialogState extends State<_AddThenDmDialog> {
  bool _pickingTeam = false;

  @override
  Widget build(BuildContext context) {
    if (_pickingTeam) {
      return SimpleDialog(
        title: const Text('어느 팀에 추가할까요?'),
        children: [
          for (final team in widget.manageableTeams)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(team),
              child: Text(team.name),
            ),
        ],
      );
    }
    return SimpleDialog(
      title: const Text('어느 팀으로 1:1 메시지를 시작할까요?'),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            '함께 속한 팀이 없습니다.',
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
        ),
        const Divider(height: 16),
        SimpleDialogOption(
          onPressed: () => setState(() => _pickingTeam = true),
          child: const Row(
            children: [
              Icon(Icons.person_add_alt_1, size: 18),
              SizedBox(width: 8),
              Text('팀원 추가'),
            ],
          ),
        ),
      ],
    );
  }
}

/// 프로필 카드의 "팀"/"직책" 칸. "팀"은 이 사람이 실제로 속한 팀 이름들(노출 범위는 서버가
/// 정한다 — GET /users/:id/teams), "직책"은 기존 부서/직책 필드의 직책 값이다. 소유자·관리자
/// 에게만 직책 수정용 연필 버튼이 보인다(팀 소속은 이 카드에서 바꿀 수 없다).
class _OrgSection extends StatelessWidget {
  final List<String>? teamNames; // null이면 아직 불러오는 중.
  final String? position;
  final VoidCallback? onEdit;
  const _OrgSection({
    required this.teamNames,
    required this.position,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final teamText = teamNames == null
        ? '불러오는 중…'
        : (teamNames!.isEmpty ? '없음' : teamNames!.join(', '));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.groups_outlined, size: 18, color: hint),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '팀',
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: hint),
                  ),
                  Text(
                    teamText,
                    style: teamNames == null || teamNames!.isEmpty
                        ? TextStyle(color: hint)
                        : const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '직책',
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: hint),
                  ),
                  Text(
                    position?.isNotEmpty == true ? position! : '아직 등록되지 않았습니다',
                    style: position?.isNotEmpty == true
                        ? const TextStyle(fontWeight: FontWeight.w500)
                        : TextStyle(color: hint),
                  ),
                ],
              ),
            ),
            if (onEdit != null)
              IconButton(
                tooltip: '직책 수정',
                icon: const Icon(Icons.edit_outlined, size: 18),
                onPressed: onEdit,
              ),
          ],
        ),
      ),
    );
  }
}
