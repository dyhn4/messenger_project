import 'package:flutter/material.dart';

import '../models/team.dart';
import '../services/session.dart';
import '../widgets/account_menu_button.dart';
import '../widgets/my_avatar.dart';
import '../widgets/team_avatar.dart';
import 'home_screen.dart' show wideBreakpoint;
import 'org_chart_screen.dart';
import 'team_settings_dialog.dart';

/// 로그인 직후(또는 로그인 상태를 유지한 채 앱을 새로 켰을 때) 가장 먼저 뜨는 화면.
/// 내가 속한 팀들을 보여주고, "팀으로 가기"를 누르면 그 팀의 채팅 화면으로 들어간다
/// (Session.currentTeam이 정해지면 home_screen.dart가 채팅 화면으로 바꾼다).
class TeamSelectScreen extends StatefulWidget {
  final Session session;
  const TeamSelectScreen({super.key, required this.session});

  @override
  State<TeamSelectScreen> createState() => _TeamSelectScreenState();
}

class _TeamSelectScreenState extends State<TeamSelectScreen> {
  bool _creating = false;

  Future<void> _createTeam() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _CreateTeamDialog(),
    );
    if (name == null || name.isEmpty || !mounted) return;

    setState(() => _creating = true);
    try {
      // 팀을 만든 사람이 그 팀의 소유자가 된다(서버 teams.js) — 만들자마자 바로 들어간다.
      final team = await widget.session.createTeam(name: name);
      if (mounted) widget.session.enterTeam(team);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('팀 생성 실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text(
          'TangoTalk',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          // 삼선 메뉴 왼쪽에 로그인한 사용자 프로필(사진+이름)을 보여준다.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                MyAvatar(session: widget.session, radius: 14),
                const SizedBox(width: 8),
                Text(
                  widget.session.name ?? widget.session.username ?? '',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          // 서버 전체 팀/회원 구조를 보는 기능이라, 계정 등급이 관리자이거나 서버 운영자인
          // 사람에게만 보인다(server/src/teams.js의 GET /org-chart/teams와 같은 규칙).
          if (widget.session.canViewOrgChart)
            IconButton(
              tooltip: '조직도',
              icon: const Icon(Icons.account_tree_outlined),
              onPressed: () => showOrgChartScreen(context, widget.session),
            ),
          AccountMenuButton(session: widget.session),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) {
          final teams = widget.session.teams;
          // PC(넓은 화면)는 잔디식으로 화면 가운데에 떠 있는 카드처럼 보이도록 위아래도
          // 가운데 정렬하지만, 좁은 화면(안드로이드)에서는 목록이 위에서부터 시작해야
          // 자연스러워서 세로는 위쪽 정렬 + 좌우에 약간의 여백을 준다.
          final isWide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
          final list = SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              vertical: 32,
              horizontal: isWide ? 0 : 12,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 780),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 8),
                    child: Text(
                      '팀 리스트',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  ),
                  if (teams.isEmpty)
                    _EmptyTeams()
                  else
                    Card(
                      margin: EdgeInsets.zero,
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          for (var i = 0; i < teams.length; i++) ...[
                            if (i > 0) const Divider(height: 1),
                            _TeamRow(
                              session: widget.session,
                              team: teams[i],
                              onEnter: () => widget.session.enterTeam(teams[i]),
                            ),
                          ],
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  _CreateTeamButton(
                    busy: _creating,
                    onPressed: _creating ? null : _createTeam,
                  ),
                ],
              ),
            ),
          );
          // PC는 화면 가운데(위아래도)에 뜨는 카드처럼, 좁은 화면(안드로이드)은 목록이
          // 위에서부터 시작하도록 Center 대신 Align(topCenter)을 쓴다.
          return isWide
              ? Center(child: list)
              : Align(alignment: Alignment.topCenter, child: list);
        },
      ),
    );
  }
}

/// 팀 이름 입력창. TextEditingController를 이 State가 들고 dispose까지 책임진다.
///
/// 예전에는 _createTeam()에서 컨트롤러를 만들어 `await showDialog(...)` 직후에 dispose했는데,
/// showDialog의 Future는 Navigator.pop이 "호출된" 시점에 바로 완료되고 다이얼로그 라우트는
/// 그 뒤로도 닫히는 전환 애니메이션 동안 계속 리빌드된다 — 그 리빌드가 이미 dispose된
/// 컨트롤러에 리스너를 다시 달면서 "A TextEditingController was used after being disposed"가
/// 났고, 그 여파로 위젯 트리가 깨져 "_dependents.isEmpty" 단언 실패까지 이어졌다.
/// State가 소유하면 라우트가 실제로 사라질 때 dispose되므로 이 경합이 없다.
class _CreateTeamDialog extends StatefulWidget {
  const _CreateTeamDialog();

  @override
  State<_CreateTeamDialog> createState() => _CreateTeamDialogState();
}

class _CreateTeamDialogState extends State<_CreateTeamDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('팀 생성하기'),
      content: SizedBox(
        width: 320,
        child: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(
            labelText: '팀 이름',
            hintText: '예: 개발팀',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(onPressed: _submit, child: const Text('만들기')),
      ],
    );
  }
}

class _EmptyTeams extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
        child: Column(
          children: [
            Icon(
              Icons.groups_outlined,
              size: 40,
              color: Theme.of(context).hintColor,
            ),
            const SizedBox(height: 12),
            const Text('아직 속한 팀이 없습니다.'),
            const SizedBox(height: 6),
            Text(
              '팀을 직접 만들거나, 팀의 소유자·관리자가 초대해 주면 여기에 표시됩니다.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).hintColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 팀 카드 한 줄: 아이콘 + 이름(+내 등급/인원) + [설정] [팀으로 가기].
class _TeamRow extends StatelessWidget {
  final Session session;
  final Team team;
  final VoidCallback onEnter;
  const _TeamRow({
    required this.session,
    required this.team,
    required this.onEnter,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      if (team.isOwner) '소유자',
      if (team.memberCount != null) '${team.memberCount}명',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          TeamAvatar(team: team, size: 44),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  team.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ],
            ),
          ),
          // 팀 설정(이름·아이콘·멤버)은 그 팀의 소유자이거나 계정 등급이 관리자인 사람만.
          if (session.canManageTeam(team)) ...[
            OutlinedButton(
              onPressed: () => showTeamSettingsDialog(context, session, team),
              child: const Text('설정'),
            ),
            const SizedBox(width: 8),
          ],
          FilledButton(onPressed: onEnter, child: const Text('팀으로 가기')),
        ],
      ),
    );
  }
}

class _CreateTeamButton extends StatelessWidget {
  final bool busy;
  final VoidCallback? onPressed;
  const _CreateTeamButton({required this.busy, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 28),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(Icons.add, color: Theme.of(context).hintColor),
              const SizedBox(width: 8),
              Text(
                '팀 생성하기',
                style: TextStyle(
                  color: Theme.of(context).hintColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
