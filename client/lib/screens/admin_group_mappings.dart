import 'package:flutter/material.dart';

import '../l10n/tr.dart';
import '../models/admin.dart';
import '../models/login_security.dart';
import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/integration_widgets.dart';

/// 관리자 콘솔 "로그인 보안" 탭의 디렉터리 그룹 규칙 목록 — "이 그룹이면 이 팀에 넣고 이 등급으로"(server/src/groupSync.js,
/// /admin/group-mappings). 켜기·빼기 스위치는 탭(서버 설정 PATCH)에 있고, 여기는 규칙 더하기·지우기만 — 바로 서버에 적고 다음
/// 로그인(LDAP은 10분마다 도는 확인 때도)부터 맞춘다.
///
/// 목록을 못 불러와도(예전 서버 등) 탭의 다른 칸은 그대로 쓰도록 이 칸 안에만 까닭을 보인다.
class AdminGroupMappingsSection extends StatefulWidget {
  final Session session;
  const AdminGroupMappingsSection({super.key, required this.session});

  @override
  State<AdminGroupMappingsSection> createState() =>
      _AdminGroupMappingsSectionState();
}

class _AdminGroupMappingsSectionState extends State<AdminGroupMappingsSection> {
  List<GroupMapping>? _mappings;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.session.api!.fetchGroupMappings();
      if (mounted) {
        setState(() {
          _mappings = list;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = tr('그룹 규칙을 불러오지 못했습니다: {e}', {'e': e}));
      }
    }
  }

  /// 규칙 더하기 — 팀 목록을 먼저 받아 창을 연다(팀 고르기). 창 안에서 서버에 적고 만든 규칙을 돌려받는다.
  Future<void> _add() async {
    setState(() => _busy = true);
    List<AdminTeam> teams;
    try {
      teams = await widget.session.api!.fetchAdminTeams();
    } catch (e) {
      if (mounted) {
        showAppToast(context, tr('팀 목록을 불러오지 못했습니다: {e}', {'e': e}));
      }
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    final created = await showDialog<GroupMapping>(
      context: context,
      builder: (_) =>
          _GroupMappingDialog(session: widget.session, teams: teams),
    );
    if (created == null || !mounted) return;
    setState(() => _mappings = [...?_mappings, created]);
    showAppToast(context, tr('그룹 규칙을 더했습니다. 다음 로그인부터 맞춥니다.'));
  }

  Future<void> _delete(GroupMapping m) async {
    final ok = await confirmIntegrationDelete(
      context,
      title: tr('그룹 규칙 지우기'),
      body: tr(
        '"{group}" 규칙을 지울까요? 이 규칙으로 이미 넣은 팀·등급은 그대로 남습니다("그룹에서 빠지면 빼기"를 켰으면 다음 확인 때 되돌립니다).',
        {'group': m.group},
      ),
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.session.api!.deleteGroupMapping(m.id);
      if (!mounted) return;
      setState(() => _mappings?.removeWhere((x) => x.id == m.id));
      showAppToast(context, tr('그룹 규칙을 지웠습니다.'));
    } catch (e) {
      if (mounted) showAppToast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 규칙이 하는 일 한 줄 — "출처 · 팀: … · 등급: …".
  String _describe(GroupMapping m) => [
    groupSourceLabel(m.source),
    if (m.teamId != null)
      tr('팀: {team}', {'team': m.teamName ?? tr('(지워진 팀)')}),
    if (m.accountRole != null)
      tr('등급: {role}', {'role': accountRoleLabel(m.accountRole!)}),
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = _mappings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(tr('그룹 규칙'), style: theme.textTheme.labelLarge),
            ),
            TextButton.icon(
              key: const ValueKey('group-mapping-add'),
              icon: const Icon(Icons.add, size: 18),
              label: Text(tr('규칙 추가')),
              onPressed: _busy || list == null ? null : _add,
            ),
          ],
        ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
          )
        else if (list == null)
          const Padding(
            padding: EdgeInsets.all(8),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (list.isEmpty)
          Text(
            tr('아직 규칙이 없습니다.'),
            style: TextStyle(fontSize: 12, color: theme.hintColor),
          )
        else
          for (final m in list)
            ListTile(
              key: ValueKey('group-mapping-${m.id}'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.group_outlined),
              title: Text(m.group),
              subtitle: Text(_describe(m)),
              trailing: IconButton(
                key: ValueKey('group-mapping-delete-${m.id}'),
                tooltip: tr('지우기'),
                icon: const Icon(Icons.delete_outline),
                onPressed: _busy ? null : () => _delete(m),
              ),
            ),
      ],
    );
  }
}

/// 규칙 더하기 창 — 출처·그룹 값·팀(선택)·등급(선택). 그룹 값은 꼭, 팀이나 등급 중 하나는 꼭. 서버가 거절하면 창 안에 까닭.
class _GroupMappingDialog extends StatefulWidget {
  final Session session;
  final List<AdminTeam> teams;
  const _GroupMappingDialog({required this.session, required this.teams});

  @override
  State<_GroupMappingDialog> createState() => _GroupMappingDialogState();
}

class _GroupMappingDialogState extends State<_GroupMappingDialog> {
  final _group = TextEditingController();
  String _source = 'any';
  String? _teamId;
  String? _role;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _group.dispose();
    super.dispose();
  }

  /// 출처마다 그룹 칸에 넣을 값의 예.
  String get _groupHint => switch (_source) {
    'ldap' => tr('CN=영업팀,OU=Groups,DC=company,DC=local 또는 영업팀'),
    'saml' => tr('그룹 속성 값'),
    'microsoft' => tr('그룹 개체 ID(GUID)'),
    _ => tr('그룹 이름·DN·개체 ID'),
  };

  Future<void> _submit() async {
    final group = _group.text.trim();
    if (group.isEmpty) {
      setState(() => _error = tr('그룹을 넣으세요.'));
      return;
    }
    if (_teamId == null && _role == null) {
      setState(() => _error = tr('넣을 팀이나 바꿀 등급 중 하나는 고르세요.'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final created = await widget.session.api!.createGroupMapping(
        source: _source,
        group: group,
        teamId: _teamId,
        accountRole: _role,
      );
      if (mounted) Navigator.of(context).pop(created);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return AlertDialog(
      title: Text(tr('그룹 규칙 추가')),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                key: const ValueKey('group-mapping-source'),
                initialValue: _source,
                decoration: InputDecoration(
                  labelText: tr('그룹을 알려 주는 곳'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final s in groupSources)
                    DropdownMenuItem(
                      value: s,
                      child: Text(groupSourceLabel(s)),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _source = v ?? _source),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('group-mapping-group'),
                controller: _group,
                decoration: InputDecoration(
                  labelText: tr('그룹'),
                  hintText: _groupHint,
                  helperText: _source == 'microsoft'
                      ? tr(
                          'Entra 관리 센터의 앱 등록 → 토큰 구성 → 그룹 클레임 추가로 ID 토큰에 그룹이 들어가게 해야 합니다.',
                        )
                      : null,
                  helperMaxLines: 3,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                key: const ValueKey('group-mapping-team'),
                initialValue: _teamId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: tr('넣을 팀(선택)'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(tr('팀은 그대로')),
                  ),
                  for (final t in widget.teams)
                    DropdownMenuItem<String?>(
                      value: t.id,
                      child: Text(t.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: _busy ? null : (v) => setState(() => _teamId = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                key: const ValueKey('group-mapping-role'),
                initialValue: _role,
                decoration: InputDecoration(
                  labelText: tr('계정 등급(선택)'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(tr('등급은 그대로')),
                  ),
                  for (final r in const ['guest', 'member', 'admin'])
                    DropdownMenuItem<String?>(
                      value: r,
                      child: Text(accountRoleLabel(r)),
                    ),
                ],
                onChanged: _busy ? null : (v) => setState(() => _role = v),
              ),
              const SizedBox(height: 8),
              Text(
                tr('여러 규칙이 맞으면 팀은 모두 넣고 등급은 가장 높은 것을 씁니다.'),
                style: TextStyle(fontSize: 12, color: hint),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    key: const ValueKey('group-mapping-error'),
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('group-mapping-save'),
          onPressed: _busy ? null : _submit,
          child: Text(tr('추가')),
        ),
      ],
    );
  }
}
