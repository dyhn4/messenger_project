import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/team.dart';
import '../models/team_invite_link.dart';
import '../services/api_client.dart' show PositionOption;
import '../services/invite_share.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/app_toast.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/muted_scrollbar.dart';

/// "팀 초대 링크" 관리 화면. 위의 InviteLinkScreen(설치→가입)과 달리, 이 링크로 가입하면
/// 가입과 동시에 지정한 팀에 자동 합류하고 계정 등급도 자동으로 부여된다.
///
/// session.canCreateTeamInviteLink(서버 설정 "팀 초대 링크 생성 권한")가 있을 때만 열린다 —
/// 서버도 매 요청마다 다시 확인한다(teamInvites.js).
///
/// [initialTeamId]를 주면(팀 설정 화면에서 열 때) "팀 초대 링크 만들기" 다이얼로그의 팀
/// 선택이 그 팀으로 미리 맞춰진다.
Future<void> showTeamInviteLinkScreen(
  BuildContext context,
  Session session, {
  String? initialTeamId,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) =>
        TeamInviteLinkScreen(session: session, initialTeamId: initialTeamId),
  );
}

class TeamInviteLinkScreen extends StatefulWidget {
  final Session session;
  final String? initialTeamId;
  const TeamInviteLinkScreen({
    super.key,
    required this.session,
    this.initialTeamId,
  });

  @override
  State<TeamInviteLinkScreen> createState() => _TeamInviteLinkScreenState();
}

class _TeamInviteLinkScreenState extends State<TeamInviteLinkScreen> {
  List<TeamInviteLink>? _links;
  String? _error;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final links = await widget.session.api!.fetchTeamInviteLinks();
      if (!mounted) return;
      setState(() => _links = links);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    showAppToast(context, message);
  }

  Future<void> _create() async {
    final teams = widget.session.teams;
    if (teams.isEmpty) {
      _toast('먼저 팀을 만들거나 팀에 들어가 있어야 합니다.');
      return;
    }
    final result = await showDialog<_CreateTeamInviteLinkResult>(
      context: context,
      builder: (_) => _CreateTeamInviteLinkDialog(
        session: widget.session,
        teams: teams,
        initialTeamId: widget.initialTeamId,
      ),
    );
    if (result == null) return;

    setState(() => _creating = true);
    try {
      final link = await widget.session.api!.createTeamInviteLink(
        teamId: result.teamId,
        assignedRole: result.assignedRole,
        assignedPosition: result.assignedPosition,
        label: result.label.isEmpty ? null : result.label,
        maxUses: result.maxUses,
      );
      if (mounted) setState(() => _links = [link, ...?_links]);
      if (mounted) await _copyAndNotify(link);
    } catch (e) {
      _toast('팀 초대 링크 생성 실패: $e');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _copyAndNotify(TeamInviteLink link) async {
    if (link.url == null) return;
    await Clipboard.setData(
      ClipboardData(text: inviteShareText(link.url!, link.externalUrl)),
    );
    if (!mounted) return;
    showAppToast(context, '링크를 복사했습니다. 원하는 곳에 붙여넣어 보내세요.');
  }

  Future<void> _revoke(TeamInviteLink link) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('팀 초대 링크 취소'),
        content: SizedBox(
          width: 320,
          child: Text(
            '${link.label ?? '이'} 링크를 취소할까요? 이미 보낸 링크로는 더 이상 가입할 수 없게 됩니다.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('링크 취소하기'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      final revoked = await widget.session.api!.revokeTeamInviteLink(link.id);
      if (!mounted) return;
      setState(() {
        final list = [...?_links];
        final i = list.indexWhere((l) => l.id == revoked.id);
        if (i >= 0) list[i] = revoked;
        _links = list;
      });
    } catch (e) {
      _toast('실패: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return FloatingDialog(
      title: '팀 초대 링크',
      maxWidth: 480,
      maxHeight: 640,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '링크로 가입하면 지정한 팀에 자동으로 합류하고, 지정한 등급이 바로 부여됩니다.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: _creating ? null : _create,
              icon: _creating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.group_add_outlined),
              label: const Text('팀 초대 링크 만들기'),
            ),
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          Flexible(child: _buildList(context)),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(child: Text(_error!)),
      );
    }
    final links = _links;
    if (links == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (links.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            '아직 만든 팀 초대 링크가 없습니다.',
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
        ),
      );
    }
    return MutedScrollbar(
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: links.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) => _TeamInviteLinkRow(
          link: links[i],
          onCopy: () => _copyAndNotify(links[i]),
          onRevoke: () => _revoke(links[i]),
        ),
      ),
    );
  }
}

class _TeamInviteLinkRow extends StatelessWidget {
  final TeamInviteLink link;
  final VoidCallback onCopy;
  final VoidCallback onRevoke;
  const _TeamInviteLinkRow({
    required this.link,
    required this.onCopy,
    required this.onRevoke,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final inactive = !link.valid;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        link.label?.isNotEmpty == true
            ? link.label!
            : '${link.teamName} · ${link.assignedRole.label}',
        style: TextStyle(color: inactive ? hint : null),
      ),
      subtitle: Text(
        '${link.teamName} · ${link.assignedRole.label}'
        '${link.assignedPosition != null ? ' · ${link.assignedPosition}' : ''}'
        ' · ${link.statusLabel} · '
        '${link.usageLabel} · ${formatDateTime(link.createdAt)} 생성',
        style: TextStyle(color: hint),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (link.valid)
            IconButton(
              tooltip: '링크 복사',
              icon: const Icon(Icons.copy_outlined, size: 20),
              onPressed: onCopy,
            ),
          if (link.valid)
            IconButton(
              tooltip: '링크 취소',
              icon: const Icon(Icons.link_off, size: 20),
              onPressed: onRevoke,
            ),
        ],
      ),
    );
  }
}

class _CreateTeamInviteLinkResult {
  final String teamId;
  final AccountRole assignedRole;
  final String? assignedPosition;
  final String label;
  final int maxUses;
  const _CreateTeamInviteLinkResult({
    required this.teamId,
    required this.assignedRole,
    this.assignedPosition,
    required this.label,
    required this.maxUses,
  });
}

/// 링크 하나로 가입할 수 있는 사람 수 고르기(서버 최대 100명, teamInvites.js).
const _maxUsesOptions = [1, 5, 10, 30, 100];

class _CreateTeamInviteLinkDialog extends StatefulWidget {
  final Session session;
  final List<Team> teams;
  final String? initialTeamId;
  const _CreateTeamInviteLinkDialog({
    required this.session,
    required this.teams,
    this.initialTeamId,
  });

  @override
  State<_CreateTeamInviteLinkDialog> createState() =>
      _CreateTeamInviteLinkDialogState();
}

class _CreateTeamInviteLinkDialogState
    extends State<_CreateTeamInviteLinkDialog> {
  final _label = TextEditingController();
  late String _teamId =
      widget.teams.where((t) => t.id == widget.initialTeamId).firstOrNull?.id ??
      widget.teams.first.id;
  AccountRole _assignedRole = AccountRole.member;
  int _maxUses = 1;

  /// 관리자 등급을 주는 링크는 고른 값과 상관없이 1명이다.
  int get _effectiveMaxUses =>
      _assignedRole == AccountRole.admin ? 1 : _maxUses;

  /// 직책 목록(서열순, position_options) — 로딩 전엔 null.
  List<PositionOption>? _positionOptions;
  String? _assignedPosition;

  @override
  void initState() {
    super.initState();
    widget.session.fetchPublicPositionOptions().then((list) {
      if (mounted) setState(() => _positionOptions = list);
    });
  }

  /// 내 직책과 같거나 그 아래만 남에게 부여할 수 있다 — 등급 제한(_canAssign)과 같은 이유의
  /// 권한 상승 방지(server/src/teamInvites.js가 같은 규칙으로 다시 확인한다). 목록은 서열순인데
  /// sortOrder가 **작을수록 서열이 낮다**(기본 목록이 사원(0)→대표(7) 순인 것과 같은 방향)
  /// — 그래서 "내 직책 이하"는 목록 맨 앞부터 내 위치(index)까지다. 내 직책이 목록에
  /// 없으면(직책 미등록 등) 아무것도 부여할 수 없다.
  List<PositionOption> get _availablePositions {
    final options = _positionOptions;
    if (options == null) return const [];
    final myIndex = options.indexWhere(
      (o) => o.label == widget.session.myPosition,
    );
    if (myIndex == -1) return const [];
    return options.sublist(0, myIndex + 1);
  }

  /// 서버 운영자는 관리자 콘솔에서 이미 자유롭게 등급을 바꿀 수 있는 사람이라 이 제한에서
  /// 빼고, 그 외에는 자기 등급보다 높은 등급을 남에게 부여하지 못한다(server/src/teamInvites.js
  /// 와 같은 규칙 — 여긴 버튼을 미리 흐리게 보여주는 UI 힌트일 뿐, 실제 차단은 서버가 한다).
  bool _canAssign(AccountRole role) =>
      widget.session.isServerAdmin ||
      role.rank <= widget.session.accountRole.rank;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('팀 초대 링크 만들기'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '발급하면 7일간 유효합니다.',
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 16),
            Text('팀', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              initialValue: _teamId,
              isExpanded: true,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: [
                for (final team in widget.teams)
                  DropdownMenuItem(value: team.id, child: Text(team.name)),
              ],
              onChanged: (v) => setState(() => _teamId = v ?? _teamId),
            ),
            const SizedBox(height: 16),
            Text('부여할 등급', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            SegmentedButton<AccountRole>(
              segments: [
                for (final role in AccountRole.values)
                  ButtonSegment(
                    value: role,
                    label: Text(role.label),
                    enabled: _canAssign(role),
                  ),
              ],
              selected: {_assignedRole},
              onSelectionChanged: (s) =>
                  setState(() => _assignedRole = s.first),
            ),
            const SizedBox(height: 16),
            Text('가입 인원', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            // 링크가 다른 데로 새도 정한 인원만 가입할 수 있다. 관리자 등급을 주는 링크는 늘 1명(서버도 같다).
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final n in _maxUsesOptions)
                  ChoiceChip(
                    label: Text('$n명'),
                    selected: _effectiveMaxUses == n,
                    onSelected: _assignedRole == AccountRole.admin && n != 1
                        ? null
                        : (_) => setState(() => _maxUses = n),
                  ),
              ],
            ),
            if (_assignedRole == AccountRole.admin)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '관리자 등급을 주는 링크는 1명만 가입할 수 있습니다.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ),
            if (_availablePositions.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                '부여할 직책 (선택)',
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('지정 안 함'),
                    selected: _assignedPosition == null,
                    onSelected: (_) => setState(() => _assignedPosition = null),
                  ),
                  for (final option in _availablePositions)
                    ChoiceChip(
                      label: Text(option.label),
                      selected: _assignedPosition == option.label,
                      onSelected: (_) =>
                          setState(() => _assignedPosition = option.label),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _label,
              maxLength: 30,
              decoration: const InputDecoration(
                labelText: '메모 (선택)',
                hintText: '예: 9월 신입',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _CreateTeamInviteLinkResult(
              teamId: _teamId,
              assignedRole: _assignedRole,
              assignedPosition: _assignedPosition,
              label: _label.text.trim(),
              maxUses: _effectiveMaxUses,
            ),
          ),
          child: const Text('만들기'),
        ),
      ],
    );
  }
}
