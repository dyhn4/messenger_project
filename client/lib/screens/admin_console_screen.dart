import 'package:flutter/material.dart';

import '../models/admin.dart';
import '../services/api_client.dart' show PositionOption;
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/admin_org_edit_dialog.dart';
import '../widgets/avatar_utils.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/muted_scrollbar.dart';

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

  Future<void> _save({
    String? teamCreation,
    String? orgScope,
    String? teamInviteLinkCreation,
  }) async {
    setState(() => _saving = true);
    try {
      await widget.session.api!.updateServerSettings(
        teamCreation: teamCreation,
        orgScope: orgScope,
        teamInviteLinkCreation: teamInviteLinkCreation,
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
              '팀 초대 링크 생성 권한',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '"팀 초대 링크"로 가입하면 지정한 팀에 자동 합류하고 등급도 자동으로 부여됩니다. '
            '이 링크를 만들 수 있는 최소 등급입니다. 준회원은 어느 설정에서도 만들 수 없고, '
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
              selected: {stats.teamInviteLinkCreation},
              onSelectionChanged: _saving
                  ? null
                  : (s) => _save(teamInviteLinkCreation: s.first),
            ),
          ),
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '팀·직책 관리',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '팀 단위로 두면 한 사람이 팀마다 다른 직책을 가질 수 있고, 각 팀에서 팀 설정으로 정합니다. '
            '계정 단위로 두면 조직도가 하나로 통일되고, 여기 회원 탭에서 아래 직책 목록 중 하나를 골라 정합니다.',
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
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '직책 목록',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '팀·직책 관리가 "계정 단위"일 때, 회원 탭의 직책 수정에서 자유 입력 대신 이 목록 '
            '중 하나를 고르게 합니다.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 8),
          _PositionOptionsEditor(session: widget.session),
        ],
      ),
    );
  }
}

/// "직책 목록" 관리 — 칩(삭제 버튼 포함) + 추가 입력창. `_StatsTab`과 별도 위젯으로 뺀 이유는
/// 이 목록 자체의 로딩/에러 상태가 위 서버 설정(orgScope 등)과 독립적이기 때문이다.
class _PositionOptionsEditor extends StatefulWidget {
  final Session session;
  const _PositionOptionsEditor({required this.session});

  @override
  State<_PositionOptionsEditor> createState() => _PositionOptionsEditorState();
}

class _PositionOptionsEditorState extends State<_PositionOptionsEditor> {
  List<PositionOption>? _options;
  String? _error;
  bool _adding = false;
  final _newLabel = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _newLabel.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final options = await widget.session.fetchPositionOptions();
      if (mounted) setState(() => _options = options);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _add() async {
    final label = _newLabel.text.trim();
    if (label.isEmpty) return;
    setState(() => _adding = true);
    try {
      final created = await widget.session.createPositionOption(label);
      _newLabel.clear();
      if (mounted) setState(() => _options = [...?_options, created]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _delete(PositionOption option) async {
    try {
      await widget.session.deletePositionOption(option.id);
      if (mounted) {
        setState(
          () => _options = _options?.where((o) => o.id != option.id).toList(),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('실패: $e')));
      }
    }
  }

  /// [direction]은 'left' 또는 'right' — 그 이웃과 서열(sortOrder)을 맞바꾼다.
  Future<void> _move(PositionOption option, String direction) async {
    try {
      final updated = await widget.session.movePositionOption(
        option.id,
        direction,
      );
      if (mounted) setState(() => _options = updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('실패: $e')));
      }
    }
  }

  /// 별표를 누르면 기본값 지정/해제를 토글한다(이미 기본값이던 다른 직책은 자동으로 풀린다).
  Future<void> _toggleDefault(PositionOption option) async {
    try {
      final updated = await widget.session.toggleDefaultPositionOption(
        option.id,
      );
      if (mounted) setState(() => _options = updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('실패: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Text(_error!);
    final options = _options;
    if (options == null) {
      return const SizedBox(
        height: 24,
        width: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '화살표를 눌러 서열을 바꿀 수 있습니다(왼쪽이 위). 별표를 누르면 회원가입 시 자동으로'
          ' 부여할 기본값으로 지정됩니다(하나만 지정 가능).',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < options.length; i++)
              _PositionOptionPill(
                option: options[i],
                canMoveLeft: i > 0,
                canMoveRight: i < options.length - 1,
                onMoveLeft: () => _move(options[i], 'left'),
                onMoveRight: () => _move(options[i], 'right'),
                onToggleDefault: () => _toggleDefault(options[i]),
                onDelete: () => _delete(options[i]),
              ),
            if (options.isEmpty)
              Text(
                '등록된 직책이 없습니다.',
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _newLabel,
                maxLength: 30,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '예: 팀장',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
                onSubmitted: (_) => _adding ? null : _add(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _adding ? null : _add,
              child: _adding
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('추가'),
            ),
          ],
        ),
      ],
    );
  }
}

/// 직책 목록 한 항목: ◀ [이름] ▶ [★] [x]. 화살표를 누르면 그 방향의 이웃과 서열을 맞바꾸고
/// (맨 끝이면 그쪽 화살표가 비활성화된다), 별표를 누르면 회원가입 기본값으로 지정/해제한다
/// (기본값이면 테두리로도 표시).
class _PositionOptionPill extends StatelessWidget {
  final PositionOption option;
  final bool canMoveLeft;
  final bool canMoveRight;
  final VoidCallback onMoveLeft;
  final VoidCallback onMoveRight;
  final VoidCallback onToggleDefault;
  final VoidCallback onDelete;
  const _PositionOptionPill({
    required this.option,
    required this.canMoveLeft,
    required this.canMoveRight,
    required this.onMoveLeft,
    required this.onMoveRight,
    required this.onToggleDefault,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
        border: option.isDefault
            ? Border.all(color: primary, width: 1.5)
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '왼쪽으로',
            icon: const Icon(Icons.chevron_left, size: 18),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: canMoveLeft ? onMoveLeft : null,
          ),
          Text(option.label),
          IconButton(
            tooltip: '오른쪽으로',
            icon: const Icon(Icons.chevron_right, size: 18),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: canMoveRight ? onMoveRight : null,
          ),
          IconButton(
            tooltip: option.isDefault ? '기본값 해제' : '회원가입 기본값으로 지정',
            icon: Icon(
              option.isDefault ? Icons.star : Icons.star_border,
              size: 17,
              color: option.isDefault ? primary : hint,
            ),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: onToggleDefault,
          ),
          const SizedBox(width: 2),
          InkWell(
            onTap: onDelete,
            customBorder: const CircleBorder(),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(Icons.close, size: 14, color: hint),
            ),
          ),
          const SizedBox(width: 2),
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
    // '계정 단위'일 때는 직책을 자유 입력 대신 "직책 목록"(운영 현황에서 관리)에서
    // 칩으로 고르게 한다 — 그 외(팀 단위)에는 자유 입력 그대로 쓴다. 소속 팀은 목록에
    // 이미 칩으로 보이고 여기서 바꿀 수 있는 값도 아니라 이 다이얼로그에는 없다.
    final options = widget.session.orgScope == 'account'
        ? await widget.session.fetchPositionOptions()
        : const <PositionOption>[];
    if (!mounted) return;
    final result = await showAdminOrgEditDialog(
      context,
      userName: user.name,
      orgScope: widget.session.orgScope,
      position: user.position,
      options: options,
    );
    if (result == null || !mounted) return;
    await _run(() async {
      _replace(
        await widget.session.api!.updateUserOrg(
          user.id,
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
        _UsersTableHead(),
        const Divider(height: 1),
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
                if (user.deleted) {
                  return _DeletedUserRow(user: user);
                }
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        flex: 9,
                        child: Row(
                          children: [
                            CircleAvatar(
                              backgroundColor:
                                  parseHexColor(user.avatarColor) ??
                                  Theme.of(
                                    context,
                                  ).colorScheme.primaryContainer,
                              child: Text(
                                user.avatarEmoji ??
                                    (user.name.isEmpty
                                        ? '?'
                                        : user.name.substring(0, 1)),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          user.name,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      if (isMe)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            left: 6,
                                          ),
                                          child: Text(
                                            '(나)',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Theme.of(
                                                context,
                                              ).hintColor,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  Text(
                                    user.username,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: Theme.of(context).hintColor,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        flex: 5,
                        child: Transform.translate(
                          offset: const Offset(-50, 0),
                          child: Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: _statusBadges(context, user),
                          ),
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        flex: 9,
                        child: user.teams.isEmpty
                            ? Text(
                                '없음',
                                style: TextStyle(
                                  color: Theme.of(context).hintColor,
                                  fontStyle: FontStyle.italic,
                                ),
                              )
                            : Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: [
                                  for (final team in user.teams)
                                    _TeamChip(team: team),
                                ],
                              ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        flex: 5,
                        child: Text(
                          user.position?.isNotEmpty == true
                              ? user.position!
                              : '미등록',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Theme.of(context).hintColor,
                            fontStyle: user.position?.isNotEmpty == true
                                ? FontStyle.normal
                                : FontStyle.italic,
                          ),
                        ),
                      ),
                      Transform.translate(
                        offset: const Offset(-10, 0),
                        child: PopupMenuButton<void>(
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
                                  Text('직책 수정'),
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
                      ),
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

/// "회원" 탭 목록 위 칼럼 제목 — 실제 행(위의 itemBuilder)과 같은 비율(flex 10 / 12 / 7)로
/// 맞춰서, "회원"+"등급"은 붙여서 좁게, 그 다음 "팀"·"직책"은 넉넉한 간격으로 벌린다.
/// 맨 끝은 각 행의 PopupMenuButton 자리만큼 빈 칸을 둔다.
class _UsersTableHead extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).hintColor,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(flex: 9, child: Text('회원', style: style)),
          const SizedBox(width: 20),
          Expanded(
            flex: 5,
            // 아래 실제 행(등급 뱃지)과 같은 만큼(-50px) 왼쪽으로 옮겨서 계속 같은 위치에
            // 오도록 맞춘다.
            child: Transform.translate(
              offset: const Offset(-50, 0),
              child: Text('등급', style: style),
            ),
          ),
          const SizedBox(width: 20),
          Expanded(flex: 9, child: Text('팀', style: style)),
          const SizedBox(width: 20),
          Expanded(flex: 5, child: Text('직책', style: style)),
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

/// 탈퇴한 회원의 행 — 이름·"탈퇴" 표시만 흐리게 보여주고 등급/팀/직책/관리 메뉴는 의미가
/// 없어서(계정이 이미 익명화됨) 아예 뺀다.
class _DeletedUserRow extends StatelessWidget {
  final AdminUser user;
  const _DeletedUserRow({required this.user});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest,
            child: Icon(Icons.person_off_outlined, size: 18, color: hint),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              user.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: hint),
            ),
          ),
          const SizedBox(width: 10),
          Transform.translate(
            offset: const Offset(-10, 0),
            child: _Badge(
              label: '탈퇴',
              bg: Theme.of(context).colorScheme.surfaceContainerHighest,
              fg: hint,
            ),
          ),
        ],
      ),
    );
  }
}

/// 등급(관리자/정회원/준회원) + 정지됨/서버 운영자 뱃지들 — 색으로 한눈에 구분되게 한다.
List<Widget> _statusBadges(BuildContext context, AdminUser user) {
  final roleColors = _badgeColors(context, user.role);
  return [
    _Badge(
      label: accountRoleLabel(user.role),
      bg: roleColors.bg,
      fg: roleColors.fg,
    ),
    if (user.isServerAdmin)
      _Badge(
        label: '서버 운영자',
        bg: _badgeColors(context, 'op').bg,
        fg: _badgeColors(context, 'op').fg,
      ),
    if (user.suspended)
      _Badge(
        label: '정지됨',
        bg: _badgeColors(context, 'suspended').bg,
        fg: _badgeColors(context, 'suspended').fg,
      ),
  ];
}

/// 뱃지 배색 — 라이트/다크 테마 각각에 맞춘 옅은 배경 + 또렷한 글자색 쌍.
({Color bg, Color fg}) _badgeColors(BuildContext context, String kind) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  switch (kind) {
    case 'admin':
      return dark
          ? (bg: const Color(0xFF2C2650), fg: const Color(0xFFB3A4F5))
          : (bg: const Color(0xFFECE9FB), fg: const Color(0xFF6A4FD6));
    case 'member':
      return dark
          ? (bg: const Color(0xFF1C3934), fg: const Color(0xFF6BD6BD))
          : (bg: const Color(0xFFE3F6F2), fg: const Color(0xFF0F8A72));
    case 'op':
      return dark
          ? (bg: const Color(0xFF3A251F), fg: const Color(0xFFF0A284))
          : (bg: const Color(0xFFFDECE7), fg: const Color(0xFFC1502E));
    case 'suspended':
      return dark
          ? (bg: const Color(0xFF3A1E22), fg: const Color(0xFFF08A9A))
          : (bg: const Color(0xFFFCE8EA), fg: const Color(0xFFC13350));
    case 'guest':
    default:
      return dark
          ? (bg: const Color(0xFF262A3A), fg: const Color(0xFF9AA0B5))
          : (bg: const Color(0xFFEEF0F5), fg: const Color(0xFF6B7385));
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;
  const _Badge({required this.label, required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// 소속 팀 칩 — 팀마다(id 기준) 고정된 색을 골라서(`TeamAvatar`의 팔레트와 동일한 방식) 같은
/// 팀은 다른 화면에서도 항상 같은 색으로 보인다.
const _teamChipPalette = [
  Color(0xFF9575CD),
  Color(0xFF4C6EF5),
  Color(0xFF15AABF),
  Color(0xFF37B24D),
  Color(0xFFE64980),
  Color(0xFFFF6B35),
];

class _TeamChip extends StatelessWidget {
  final AdminUserTeam team;
  const _TeamChip({required this.team});

  @override
  Widget build(BuildContext context) {
    final color =
        _teamChipPalette[team.id.hashCode.abs() % _teamChipPalette.length];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        team.name,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
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
