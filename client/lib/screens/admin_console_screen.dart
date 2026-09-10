import 'package:flutter/material.dart';

import '../models/admin.dart';
import '../models/app_user.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/avatar_utils.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/org_edit_dialog.dart';

/// 서버 운영자 전용 관리자 콘솔. 팀 설정(팀 안의 관리)과 달리 **서버 전체**를 다룬다 —
/// 운영 현황 / 회원 / 팀 / 감사 로그 네 탭.
///
/// 여기 있는 모든 동작은 서버 src/admin.js가 매 요청마다 isServerAdmin을 다시 확인하므로,
/// 이 화면이 열려 있다는 것만으로 권한이 생기지는 않는다.
Future<void> showAdminConsole(BuildContext context, Session session) {
  return showDialog<void>(
    context: context,
    builder: (_) => AdminConsoleScreen(session: session),
  );
}

class AdminConsoleScreen extends StatelessWidget {
  final Session session;
  const AdminConsoleScreen({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: FloatingDialog(
        title: '서버 관리',
        maxWidth: 820,
        maxHeight: 720,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(text: '운영 현황'),
                Tab(text: '회원'),
                Tab(text: '팀'),
                Tab(text: '감사 로그'),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: TabBarView(
                children: [
                  _StatsTab(session: session),
                  _UsersTab(session: session),
                  _TeamsTab(session: session),
                  _AuditTab(session: session),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────── 운영 현황 ─────────────────────────────

class _StatsTab extends StatefulWidget {
  final Session session;
  const _StatsTab({required this.session});

  @override
  State<_StatsTab> createState() => _StatsTabState();
}

class _StatsTabState extends State<_StatsTab> {
  ServerStats? _stats;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final stats = await widget.session.api!.fetchServerStats();
      if (mounted) setState(() => _stats = stats);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _save({String? teamCreation, String? orgScope}) async {
    setState(() => _saving = true);
    try {
      await widget.session.api!.updateServerSettings(
        teamCreation: teamCreation,
        orgScope: orgScope,
      );
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final stats = _stats;
    if (stats == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _StatCard(label: '회원', value: '${stats.users}명'),
              _StatCard(label: '팀', value: '${stats.teams}개'),
              _StatCard(label: '대화방', value: '${stats.rooms}개'),
              _StatCard(label: '전체 메시지', value: '${stats.messages}건'),
              _StatCard(label: '오늘 메시지·댓글', value: '${stats.messagesToday}건'),
              _StatCard(label: '첨부 용량', value: _formatBytes(stats.uploadBytes)),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            '서버 시작: ${formatDateTime(stats.serverStartedAt)}',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 24),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '팀 생성 권한',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '팀을 새로 만들 수 있는 최소 등급입니다. 준회원은 어느 설정에서도 팀을 만들 수 없고, '
            '서버 운영자는 설정과 무관하게 항상 만들 수 있습니다.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<String>(
              segments: [
                for (final level in teamCreationLevels)
                  ButtonSegment(
                    value: level,
                    label: Text(teamCreationLabel(level)),
                  ),
              ],
              selected: {stats.teamCreation},
              onSelectionChanged: _saving
                  ? null
                  : (s) => _save(teamCreation: s.first),
            ),
          ),
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '부서·직책 관리',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '팀 단위로 두면 한 사람이 팀마다 다른 직책을 가질 수 있고, 각 팀에서 팀 설정으로 정합니다. '
            '계정 단위로 두면 조직도가 하나로 통일되고, 여기 회원 탭에서 정합니다.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'team', label: Text('팀 단위')),
                ButtonSegment(value: 'account', label: Text('계정 단위')),
              ],
              selected: {stats.orgScope},
              onSelectionChanged: _saving
                  ? null
                  : (s) => _save(orgScope: s.first),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  const _StatCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 160,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).hintColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── 회원 ─────────────────────────────

class _UsersTab extends StatefulWidget {
  final Session session;
  const _UsersTab({required this.session});

  @override
  State<_UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<_UsersTab> {
  List<AdminUser>? _users;
  String? _error;
  String _filter = '';
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final users = await widget.session.api!.fetchAdminUsers();
      if (mounted) setState(() => _users = users);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _replace(AdminUser updated) {
    setState(() {
      final list = [...?_users];
      final i = list.indexWhere((u) => u.id == updated.id);
      if (i >= 0) list[i] = updated;
      _users = list;
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      _toast('실패: $e');
    }
  }

  Future<void> _toggleSuspend(AdminUser user) async {
    final suspend = !user.suspended;
    if (suspend) {
      final ok = await _confirm(
        title: '계정 정지',
        message:
            '${user.name} 님의 계정을 정지할까요?\n'
            '로그인과 실시간 연결이 즉시 끊기고, 다시 로그인할 수 없게 됩니다. 나중에 해제할 수 있습니다.',
        confirmLabel: '정지',
      );
      if (ok != true) return;
    }
    await _run(() async {
      _replace(await widget.session.api!.setUserSuspended(user.id, suspend));
      _toast(
        suspend ? '${user.name} 님을 정지했습니다.' : '${user.name} 님의 정지를 해제했습니다.',
      );
    });
  }

  Future<void> _logoutAll(AdminUser user) async {
    final ok = await _confirm(
      title: '강제 로그아웃',
      message: '${user.name} 님의 모든 기기에서 로그아웃시킬까요? 다시 로그인하면 정상적으로 사용할 수 있습니다.',
      confirmLabel: '로그아웃',
    );
    if (ok != true) return;
    await _run(() async {
      _replace(await widget.session.api!.logoutUserEverywhere(user.id));
      _toast('${user.name} 님을 모든 기기에서 로그아웃시켰습니다.');
    });
  }

  Future<void> _changeRole(AdminUser user, String role) async {
    await _run(() async {
      _replace(await widget.session.api!.setUserRole(user.id, role));
      _toast('${user.name} 님을 ${accountRoleLabel(role)}(으)로 바꿨습니다.');
    });
  }

  Future<void> _editOrg(AdminUser user) async {
    final result = await showOrgEditDialog(
      context,
      AppUser(
        id: user.id,
        username: user.username,
        name: user.name,
        department: user.department,
        position: user.position,
      ),
    );
    if (result == null || !mounted) return;
    await _run(() async {
      _replace(
        await widget.session.api!.updateUserOrg(
          user.id,
          department: result.department,
          position: result.position,
        ),
      );
    });
  }

  Future<void> _toggleServerAdmin(AdminUser user) async {
    final grant = !user.isServerAdmin;
    final ok = await _confirm(
      title: grant ? '서버 운영자로 지정' : '서버 운영자 해제',
      message: grant
          ? '${user.name} 님에게 서버 관리 권한을 줄까요? 회원·팀·감사 로그를 모두 볼 수 있게 됩니다.'
          : '${user.name} 님의 서버 관리 권한을 해제할까요?',
      confirmLabel: grant ? '지정' : '해제',
    );
    if (ok != true) return;
    await _run(() async {
      _replace(await widget.session.api!.setUserServerAdmin(user.id, grant));
    });
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SizedBox(width: 340, child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final users = _users;
    if (users == null) return const Center(child: CircularProgressIndicator());

    final list = users
        .where(
          (u) =>
              _filter.isEmpty ||
              u.name.toLowerCase().contains(_filter.toLowerCase()) ||
              u.username.toLowerCase().contains(_filter.toLowerCase()),
        )
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          decoration: InputDecoration(
            hintText: '이름·아이디 검색',
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 18),
            border: const OutlineInputBorder(),
            helperText: '총 ${users.length}명',
          ),
          onChanged: (v) => setState(() => _filter = v),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: MutedScrollbar(
            controller: _scrollController,
            child: ListView.separated(
              controller: _scrollController,
              itemCount: list.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final user = list[i];
                final isMe = user.id == widget.session.userId;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor:
                        parseHexColor(user.avatarColor) ??
                        Theme.of(context).colorScheme.primaryContainer,
                    child: Text(
                      user.avatarEmoji ??
                          (user.name.isEmpty ? '?' : user.name.substring(0, 1)),
                    ),
                  ),
                  title: Row(
                    children: [
                      Flexible(child: Text(user.name)),
                      if (isMe)
                        const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: Text('(나)', style: TextStyle(fontSize: 12)),
                        ),
                    ],
                  ),
                  subtitle: Text(
                    '${user.username} · ${user.statusLabel}'
                    '${user.orgLine == null ? '' : ' · ${user.orgLine}'}'
                    '${user.teams.isEmpty ? '' : ' · ${user.teams.map((t) => t.name).join(', ')}'}',
                  ),
                  trailing: user.deleted
                      ? null
                      : PopupMenuButton<void>(
                          tooltip: '회원 관리',
                          position: PopupMenuPosition.under,
                          itemBuilder: (context) => [
                            // 계정 등급은 서버 운영자만 정한다 — 여기가 유일한 변경 지점이다.
                            for (final role in const [
                              'admin',
                              'member',
                              'guest',
                            ])
                              PopupMenuItem<void>(
                                onTap: () => _changeRole(user, role),
                                child: Row(
                                  children: [
                                    Icon(
                                      user.role == role
                                          ? Icons.radio_button_checked
                                          : Icons.radio_button_unchecked,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(accountRoleLabel(role)),
                                  ],
                                ),
                              ),
                            const PopupMenuDivider(),
                            PopupMenuItem<void>(
                              onTap: () => _editOrg(user),
                              child: const Row(
                                children: [
                                  Icon(Icons.badge_outlined, size: 20),
                                  SizedBox(width: 8),
                                  Text('부서·직책 수정'),
                                ],
                              ),
                            ),
                            PopupMenuItem<void>(
                              onTap: () => _logoutAll(user),
                              child: const Row(
                                children: [
                                  Icon(Icons.logout, size: 20),
                                  SizedBox(width: 8),
                                  Text('모든 기기에서 로그아웃'),
                                ],
                              ),
                            ),
                            PopupMenuItem<void>(
                              onTap: () => _toggleServerAdmin(user),
                              child: Row(
                                children: [
                                  const Icon(Icons.shield_outlined, size: 20),
                                  const SizedBox(width: 8),
                                  Text(
                                    user.isServerAdmin
                                        ? '서버 운영자 해제'
                                        : '서버 운영자로 지정',
                                  ),
                                ],
                              ),
                            ),
                            if (!isMe) ...[
                              const PopupMenuDivider(),
                              PopupMenuItem<void>(
                                onTap: () => _toggleSuspend(user),
                                child: Row(
                                  children: [
                                    Icon(
                                      user.suspended
                                          ? Icons.lock_open_outlined
                                          : Icons.block,
                                      size: 20,
                                      color: user.suspended
                                          ? null
                                          : Colors.redAccent,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      user.suspended ? '정지 해제' : '계정 정지',
                                      style: TextStyle(
                                        color: user.suspended
                                            ? null
                                            : Colors.redAccent,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

// ───────────────────────────── 팀 ─────────────────────────────

class _TeamsTab extends StatefulWidget {
  final Session session;
  const _TeamsTab({required this.session});

  @override
  State<_TeamsTab> createState() => _TeamsTabState();
}

class _TeamsTabState extends State<_TeamsTab> {
  List<AdminTeam>? _teams;
  String? _error;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final teams = await widget.session.api!.fetchAdminTeams();
      if (mounted) setState(() => _teams = teams);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final teams = _teams;
    if (teams == null) return const Center(child: CircularProgressIndicator());
    if (teams.isEmpty) return const Center(child: Text('팀이 없습니다.'));

    return MutedScrollbar(
      controller: _scrollController,
      child: ListView.separated(
        controller: _scrollController,
        itemCount: teams.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final team = teams[i];
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color:
                    parseHexColor(team.iconColor) ??
                    Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Text(
                team.iconEmoji?.isNotEmpty == true
                    ? team.iconEmoji!
                    : (team.name.isEmpty ? '?' : team.name.substring(0, 1)),
              ),
            ),
            title: Text(team.name),
            subtitle: Text(
              '${team.memberCount}명'
              '${team.domain == null ? '' : ' · ${team.domain}'}'
              '${team.createdBy == null ? '' : ' · 만든 사람 ${team.createdBy}'}'
              ' · ${formatDateTime(team.createdAt)}',
            ),
          );
        },
      ),
    );
  }
}

// ───────────────────────────── 감사 로그 ─────────────────────────────

class _AuditTab extends StatefulWidget {
  final Session session;
  const _AuditTab({required this.session});

  @override
  State<_AuditTab> createState() => _AuditTabState();
}

class _AuditTabState extends State<_AuditTab> {
  static const _pageSize = 50;

  List<AuditLog>? _logs;
  int _total = 0;
  int _offset = 0;
  String? _action;
  String? _error;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final result = await widget.session.api!.fetchAuditLogs(
        action: _action,
        limit: _pageSize,
        offset: _offset,
      );
      if (mounted) {
        setState(() {
          _logs = result.logs;
          _total = result.total;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final logs = _logs;
    if (logs == null) return const Center(child: CircularProgressIndicator());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text('행위'),
            const SizedBox(width: 12),
            DropdownButton<String?>(
              value: _action,
              hint: const Text('전체'),
              onChanged: (v) {
                setState(() {
                  _action = v;
                  _offset = 0;
                  _logs = null;
                });
                _load();
              },
              items: [
                const DropdownMenuItem<String?>(child: Text('전체')),
                for (final a in auditActionFilters)
                  DropdownMenuItem<String?>(
                    value: a,
                    child: Text(auditActionLabel(a)),
                  ),
              ],
            ),
            const Spacer(),
            Text(
              '$_total건',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).hintColor,
              ),
            ),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: logs.isEmpty
              ? const Center(child: Text('기록이 없습니다.'))
              : MutedScrollbar(
                  controller: _scrollController,
                  child: ListView.separated(
                    controller: _scrollController,
                    itemCount: logs.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) => _AuditRow(log: logs[i]),
                  ),
                ),
        ),
        if (_total > _pageSize) ...[
          const Divider(height: 1),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: _offset == 0
                    ? null
                    : () {
                        setState(() {
                          _offset -= _pageSize;
                          _logs = null;
                        });
                        _load();
                      },
              ),
              Text(
                '${_offset ~/ _pageSize + 1} / ${(_total / _pageSize).ceil()}',
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: _offset + _pageSize >= _total
                    ? null
                    : () {
                        setState(() {
                          _offset += _pageSize;
                          _logs = null;
                        });
                        _load();
                      },
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _AuditRow extends StatelessWidget {
  final AuditLog log;
  const _AuditRow({required this.log});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  log.actionLabel,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  log.actorName,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                formatDateTime(log.createdAt),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: hint),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            [
              if (log.teamName != null) '[${log.teamName}]',
              if (log.targetLabel != null) '${log.targetLabel} →',
              log.detail ?? '',
            ].where((s) => s.isNotEmpty).join(' '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// "12.3MB"처럼 사람이 읽는 용량 표기.
String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)}${units[unit]}';
}
