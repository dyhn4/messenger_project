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
  /// 막는다) — 조직도 화면이 미리 계산해서 넘긴다. 그런 팀이 없으면 null(1:1 메시지 버튼을
  /// 감추고 이유를 보여준다).
  final String? orgChartDmTeamId;

  /// 비밀 대화는 내가 속한 팀이 하나만 있으면 된다 — 평문 DM과 달리 상대가 그 팀 소속일
  /// 필요는 없다(server/src/secretChats.js). 내가 속한 팀이 하나도 없으면 null.
  final String? orgChartSecretTeamId;

  const MemberProfileDialog({
    super.key,
    required this.session,
    required this.user,
    this.fromOrgChart = false,
    this.orgChartDmTeamId,
    this.orgChartSecretTeamId,
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
    final result = await showOrgEditDialog(context, _user);
    final team = widget.session.currentTeam;
    if (result == null || team == null || !mounted) return;
    try {
      final members = await widget.session.updateTeamMember(
        team,
        _user.id,
        department: result.department,
        position: result.position,
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

  Future<void> _startDm() async {
    setState(() => _starting = true);
    try {
      final room = widget.orgChartDmTeamId != null
          ? await widget.session.startDmInTeam(
              widget.orgChartDmTeamId!,
              widget.user.id,
            )
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
    setState(() => _startingSecret = true);
    try {
      final room = widget.orgChartSecretTeamId != null
          ? await widget.session.startSecretChatInTeam(
              widget.orgChartSecretTeamId!,
              widget.user.id,
            )
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
    final canStartDm =
        canStartChat && (!widget.fromOrgChart || widget.orgChartDmTeamId != null);
    final canStartSecret =
        canStartChat &&
        (!widget.fromOrgChart || widget.orgChartSecretTeamId != null);
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
                    position?.isNotEmpty == true
                        ? position!
                        : '아직 등록되지 않았습니다',
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
