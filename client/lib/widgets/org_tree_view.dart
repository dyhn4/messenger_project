import 'dart:async';

import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/org_tree.dart';
import '../services/session.dart';
import 'app_toast.dart';
import 'muted_scrollbar.dart';
import 'user_avatar.dart';
import '../l10n/tr.dart';

/// 조직도 "부서" 탭 — 부서 트리(위 부서 › 아래 부서)와 부서마다의 사람들, 부서장·상위자(서버 orgTree.js). 누구나 보고(회사 하나면
/// 정회원 이상, 팀마다면 그 팀 멤버), 고칠 수 있는 사람(회사 하나면 서버 운영자·관리자, 팀마다면 팀 소유자도)에게는 부서 만들기·이름
/// 바꾸기·옮기기·부서장·지우기와 사람의 부서·상위자 지정 메뉴가 붙는다. 상위자는 결재선 추천(그룹웨어 결재)에 쓰인다.
///
/// [filter]가 있으면 트리 대신 이름이 맞는 부서·사람 목록을 보여 준다. 사람을 누르면 [onOpenMember].
class OrgTreeView extends StatefulWidget {
  final Session session;
  final String filter;
  final void Function(AppUser user, OrgTree tree) onOpenMember;
  const OrgTreeView({
    super.key,
    required this.session,
    this.filter = '',
    required this.onOpenMember,
  });

  @override
  State<OrgTreeView> createState() => OrgTreeViewState();
}

class OrgTreeViewState extends State<OrgTreeView> {
  final _scroll = ScrollController();
  OrgTree? _tree;
  String? _error;
  bool _busy = false;

  /// 팀 단위 조직도에서 보고 있는 팀.
  String? _teamId;

  /// 펼친 부서 — 처음에는 맨 위 부서들만.
  final _expanded = <String>{};
  bool _expandedInitialized = false;
  StreamSubscription<String?>? _changedSub;

  Session get _session => widget.session;
  bool get _byTeam => _session.orgScope != 'account';

  @override
  void initState() {
    super.initState();
    _teamId = _byTeam
        ? (_session.currentTeam?.id ??
              (_session.teams.isEmpty ? null : _session.teams.first.id))
        : null;
    _load();
    _changedSub = _session.chatSocket.orgTreeChanged.listen((key) {
      if (key == null || key == _tree?.scopeKey) _load();
    });
  }

  @override
  void dispose() {
    _changedSub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final tree = await _session.api!.fetchOrgTree(teamId: _teamId);
      if (!mounted) return;
      setState(() {
        _tree = tree;
        _error = null;
        if (!_expandedInitialized) {
          _expandedInitialized = true;
          _expanded.addAll(tree.childrenOf(null).map((d) => d.id));
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _run(Future<void> Function() action, String failText) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '$failText: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── 부서 고치기 ──

  Future<void> _addDepartment(String? parentId) async {
    final name = await _askName(
      parentId == null ? tr('부서 만들기') : tr('하위 부서 만들기'),
    );
    if (name == null) return;
    await _run(() async {
      final made = await _session.api!.createDepartment(
        teamId: _teamId,
        name: name,
        parentId: parentId,
      );
      if (parentId != null) _expanded.add(parentId);
      _expanded.add(made.id);
    }, tr('부서를 만들지 못했습니다'));
  }

  Future<void> _rename(OrgDepartment d) async {
    final name = await _askName(tr('부서 이름 바꾸기'), initial: d.name);
    if (name == null || name == d.name) return;
    await _run(
      () => _session.api!.updateDepartment(d.id, {'name': name}),
      tr('이름을 바꾸지 못했습니다'),
    );
  }

  Future<void> _reparent(OrgDepartment d) async {
    final tree = _tree!;
    final picked = await _pickDepartment(
      title: tr('"{d.name}"을(를) 옮길 위치', {'d.name': d.name}),
      exclude: {d.id, ...tree.descendantsOf(d.id)},
      noneLabel: tr('맨 위'),
    );
    if (picked == null) return;
    final parentId = picked.isEmpty ? null : picked;
    if (parentId == d.parentId) return;
    await _run(
      () => _session.api!.updateDepartment(d.id, {'parentId': parentId}),
      tr('옮기지 못했습니다'),
    );
  }

  Future<void> _setHead(OrgDepartment d) async {
    final picked = await _pickPerson(
      title: tr('"{d.name}" 부서장', {'d.name': d.name}),
      noneLabel: tr('부서장 없음'),
      current: d.headId,
    );
    if (picked == null) return;
    await _run(
      () => _session.api!.updateDepartment(d.id, {
        'headId': picked.isEmpty ? null : picked,
      }),
      tr('부서장을 정하지 못했습니다'),
    );
  }

  Future<void> _delete(OrgDepartment d) async {
    final tree = _tree!;
    final parent = tree.department(d.parentId);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('부서 지우기')),
        content: Text(
          parent == null
              ? tr('"{d.name}"을(를) 지울까요? 하위 부서는 맨 위로 올라가고, 구성원은 부서 없음이 됩니다.', {
                  'd.name': d.name,
                })
              : tr(
                  '"{d.name}"을(를) 지울까요? 하위 부서와 구성원은 "{parent.name}"(으)로 올라갑니다.',
                  {'d.name': d.name, 'parent.name': parent.name},
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('취소')),
          ),
          FilledButton(
            key: const ValueKey('org-delete-confirm'),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('지우기')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => _session.api!.deleteDepartment(d.id), tr('지우지 못했습니다'));
  }

  // ── 사람 고치기 ──

  Future<void> _moveMember(OrgMember m) async {
    final picked = await _pickDepartment(
      title: tr('{m.name}의 부서', {'m.name': m.name}),
      noneLabel: tr('부서 없음'),
      current: m.departmentId,
    );
    if (picked == null) return;
    final deptId = picked.isEmpty ? null : picked;
    if (deptId == m.departmentId) return;
    await _run(
      () => _session.api!.setMemberOrg(
        m.id,
        teamId: _teamId,
        patch: {'departmentId': deptId},
      ),
      tr('부서를 옮기지 못했습니다'),
    );
  }

  Future<void> _setManager(OrgMember m) async {
    final picked = await _pickPerson(
      title: tr('{m.name}의 상위자', {'m.name': m.name}),
      noneLabel: tr('따로 정하지 않음(부서장)'),
      exclude: {m.id},
      current: m.managerId,
    );
    if (picked == null) return;
    final managerId = picked.isEmpty ? null : picked;
    if (managerId == m.managerId) return;
    await _run(
      () => _session.api!.setMemberOrg(
        m.id,
        teamId: _teamId,
        patch: {'managerId': managerId},
      ),
      tr('상위자를 정하지 못했습니다'),
    );
  }

  // ── 입력 창 ──

  Future<String?> _askName(String title, {String initial = ''}) =>
      showDialog<String>(
        context: context,
        builder: (_) => _DepartmentNameDialog(title: title, initial: initial),
      );

  /// 부서 고르기 — 고른 부서 id, [noneLabel]을 고르면 빈 글자, 취소하면 null.
  Future<String?> _pickDepartment({
    required String title,
    required String noneLabel,
    Set<String> exclude = const {},
    String? current,
  }) {
    final tree = _tree!;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(title),
        children: [
          SimpleDialogOption(
            key: const ValueKey('org-pick-department-none'),
            onPressed: () => Navigator.of(dialogContext).pop(''),
            child: Text(
              noneLabel,
              style: TextStyle(color: Theme.of(dialogContext).hintColor),
            ),
          ),
          for (final (:department, :depth) in tree.flatten())
            if (!exclude.contains(department.id))
              SimpleDialogOption(
                key: ValueKey('org-pick-department-${department.id}'),
                onPressed: () => Navigator.of(dialogContext).pop(department.id),
                child: Padding(
                  padding: EdgeInsets.only(left: depth * 16.0),
                  child: Row(
                    children: [
                      Expanded(child: Text(department.name)),
                      if (department.id == current)
                        const Icon(Icons.check, size: 16),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }

  /// 사람 고르기 — 고른 사람 id, [noneLabel]을 고르면 빈 글자, 취소하면 null.
  Future<String?> _pickPerson({
    required String title,
    required String noneLabel,
    Set<String> exclude = const {},
    String? current,
  }) {
    final tree = _tree!;
    return showDialog<String>(
      context: context,
      builder: (_) => _PersonPicker(
        title: title,
        noneLabel: noneLabel,
        people: [
          for (final m in tree.members)
            if (!exclude.contains(m.id)) m,
        ],
        tree: tree,
        current: current,
        resolveUrl: _session.resolveUrl,
      ),
    );
  }

  // ── 그리기 ──

  @override
  Widget build(BuildContext context) {
    final tree = _tree;
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            TextButton(onPressed: _load, child: Text(tr('다시 시도'))),
          ],
        ),
      );
    }
    if (tree == null) return const Center(child: CircularProgressIndicator());
    final filter = widget.filter.trim().toLowerCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if ((_byTeam && _session.teams.length > 1) || tree.canEdit)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                if (_byTeam && _session.teams.length > 1)
                  Expanded(
                    child: DropdownButton<String>(
                      key: const ValueKey('org-tree-team'),
                      isExpanded: true,
                      isDense: true,
                      value: _teamId,
                      items: [
                        for (final t in _session.teams)
                          DropdownMenuItem(value: t.id, child: Text(t.name)),
                      ],
                      onChanged: (v) {
                        if (v == null || v == _teamId) return;
                        setState(() {
                          _teamId = v;
                          _tree = null;
                          _expanded.clear();
                          _expandedInitialized = false;
                        });
                        _load();
                      },
                    ),
                  )
                else
                  const Spacer(),
                if (tree.canEdit)
                  TextButton.icon(
                    key: const ValueKey('org-add-department'),
                    onPressed: _busy ? null : () => _addDepartment(null),
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(tr('부서 만들기')),
                  ),
              ],
            ),
          ),
        Expanded(
          child: MutedScrollbar(
            controller: _scroll,
            child: ListView(
              controller: _scroll,
              children: filter.isEmpty
                  ? _treeRows(context, tree)
                  : _searchRows(context, tree, filter),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _treeRows(BuildContext context, OrgTree tree) {
    final rows = <Widget>[];
    final hint = Theme.of(context).hintColor;
    if (tree.departments.isEmpty) {
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          child: Text(
            tree.canEdit
                ? tr(
                    '아직 부서가 없습니다. "부서 만들기"로 부서를 만들고 사람을 넣으면 상위자(부서장)가 정해지고, 결재를 올릴 때 결재선이 미리 채워집니다.',
                  )
                : tr('아직 부서가 없습니다.'),
            style: TextStyle(color: hint, fontSize: 13),
          ),
        ),
      );
    }
    void walk(String? parentId, int depth, Set<String> seen) {
      for (final d in tree.childrenOf(parentId)) {
        if (!seen.add(d.id)) continue;
        final open = _expanded.contains(d.id);
        rows.add(_departmentRow(context, tree, d, depth, open));
        if (!open) continue;
        for (final m in tree.membersOf(d.id)) {
          rows.add(
            _memberRow(context, tree, m, depth + 1, isHead: m.id == d.headId),
          );
        }
        walk(d.id, depth + 1, seen);
      }
    }

    walk(null, 0, <String>{});
    final unassigned = tree.membersOf(null);
    if (unassigned.isNotEmpty) {
      final open = _expanded.contains('');
      rows.add(
        InkWell(
          key: const ValueKey('org-unassigned'),
          onTap: () =>
              setState(() => open ? _expanded.remove('') : _expanded.add('')),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            child: Row(
              children: [
                Icon(
                  open ? Icons.expand_more : Icons.chevron_right,
                  size: 20,
                  color: hint,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    tr('부서 없음'),
                    style: TextStyle(color: hint, fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  tr('{unassigned.length}명', {
                    'unassigned.length': unassigned.length,
                  }),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              ],
            ),
          ),
        ),
      );
      if (open) {
        for (final m in unassigned) {
          rows.add(_memberRow(context, tree, m, 1));
        }
      }
    }
    return rows;
  }

  List<Widget> _searchRows(BuildContext context, OrgTree tree, String filter) {
    final depts = tree.departments
        .where((d) => d.name.toLowerCase().contains(filter))
        .toList();
    final people = tree.members
        .where((m) => m.name.toLowerCase().contains(filter))
        .toList();
    if (depts.isEmpty && people.isEmpty) {
      return [
        Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: Text(tr('검색 결과가 없습니다.'))),
        ),
      ];
    }
    return [
      for (final d in depts)
        ListTile(
          key: ValueKey('org-search-department-${d.id}'),
          dense: true,
          leading: const Icon(Icons.account_tree_outlined, size: 20),
          title: Text(d.name),
          subtitle: Text(
            tr('{p0} · {p1}명', {
              'p0': tree.pathOf(d.id),
              'p1': tree.headcount(d.id),
            }),
          ),
          onTap: () {
            // 트리로 돌아가 그 부서까지 펼친다.
            String? cur = d.id;
            final seen = <String>{};
            while (cur != null && seen.add(cur)) {
              _expanded.add(cur);
              cur = tree.department(cur)?.parentId;
            }
            setState(() {});
            showAppToast(
              context,
              tr('검색어를 지우면 "{d.name}"까지 펼쳐 보입니다.', {'d.name': d.name}),
            );
          },
        ),
      for (final m in people) _memberRow(context, tree, m, 0, showPath: true),
    ];
  }

  Widget _departmentRow(
    BuildContext context,
    OrgTree tree,
    OrgDepartment d,
    int depth,
    bool open,
  ) {
    final hint = Theme.of(context).hintColor;
    final head = tree.member(d.headId);
    return InkWell(
      key: ValueKey('org-department-${d.id}'),
      onTap: () =>
          setState(() => open ? _expanded.remove(d.id) : _expanded.add(d.id)),
      child: Padding(
        padding: EdgeInsets.only(
          left: 4 + depth * 18.0,
          right: 0,
          top: 8,
          bottom: 8,
        ),
        child: Row(
          children: [
            Icon(
              open ? Icons.expand_more : Icons.chevron_right,
              size: 20,
              color: hint,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    d.name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (head != null)
                    Text(
                      tr('부서장 {head.name}', {'head.name': head.name}),
                      style: TextStyle(fontSize: 12, color: hint),
                    ),
                ],
              ),
            ),
            Text(
              tr('{p0}명', {'p0': tree.headcount(d.id)}),
              style: TextStyle(fontSize: 12, color: hint),
            ),
            if (tree.canEdit)
              PopupMenuButton<String>(
                key: ValueKey('org-department-menu-${d.id}'),
                enabled: !_busy,
                tooltip: tr('부서 메뉴'),
                icon: const Icon(Icons.more_vert, size: 18),
                onSelected: (v) => switch (v) {
                  'child' => _addDepartment(d.id),
                  'rename' => _rename(d),
                  'head' => _setHead(d),
                  'up' => _run(
                    () => _session.api!.moveDepartment(d.id, up: true),
                    tr('옮기지 못했습니다'),
                  ),
                  'down' => _run(
                    () => _session.api!.moveDepartment(d.id, up: false),
                    tr('옮기지 못했습니다'),
                  ),
                  'move' => _reparent(d),
                  _ => _delete(d),
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'child', child: Text(tr('하위 부서 만들기'))),
                  PopupMenuItem(value: 'rename', child: Text(tr('이름 바꾸기'))),
                  PopupMenuItem(value: 'head', child: Text(tr('부서장 정하기'))),
                  PopupMenuItem(value: 'up', child: Text(tr('위로'))),
                  PopupMenuItem(value: 'down', child: Text(tr('아래로'))),
                  PopupMenuItem(
                    value: 'move',
                    child: Text(tr('다른 부서 아래로 옮기기')),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      tr('지우기'),
                      style: TextStyle(color: Colors.redAccent),
                    ),
                  ),
                ],
              )
            else
              const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  Widget _memberRow(
    BuildContext context,
    OrgTree tree,
    OrgMember m,
    int depth, {
    bool isHead = false,
    bool showPath = false,
  }) {
    final hint = Theme.of(context).hintColor;
    final manager = tree.member(m.effectiveManagerId);
    final dept = tree.department(m.departmentId);
    final sub = [
      if (showPath) dept == null ? tr('부서 없음') : tree.pathOf(dept.id),
      if (m.position != null && m.position!.isNotEmpty) m.position!,
      if (manager != null)
        tr('상위자 {manager.name}{p0}', {
          'manager.name': manager.name,
          'p0': m.managerId != null ? tr('(지정)') : '',
        }),
    ].join(' · ');
    return InkWell(
      key: ValueKey('org-member-${m.id}'),
      onTap: () =>
          widget.onOpenMember(m.toAppUser(department: dept?.name), tree),
      child: Padding(
        padding: EdgeInsets.only(left: 8 + depth * 18.0, top: 6, bottom: 6),
        child: Row(
          children: [
            UserAvatar(
              user: m.toAppUser(),
              resolveUrl: _session.resolveUrl,
              radius: 16,
              online: _session.onlineUserIds.contains(m.id),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(m.name, overflow: TextOverflow.ellipsis),
                      ),
                      if (isHead) ...[
                        const SizedBox(width: 6),
                        Container(
                          key: ValueKey('org-head-badge-${m.id}'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            tr('부서장'),
                            style: TextStyle(
                              fontSize: 10,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (sub.isNotEmpty)
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: hint),
                    ),
                ],
              ),
            ),
            if (tree.canEdit)
              PopupMenuButton<String>(
                key: ValueKey('org-member-menu-${m.id}'),
                enabled: !_busy,
                tooltip: tr('구성원 메뉴'),
                icon: const Icon(Icons.more_vert, size: 18),
                onSelected: (v) =>
                    v == 'department' ? _moveMember(m) : _setManager(m),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'department', child: Text(tr('부서 옮기기'))),
                  PopupMenuItem(value: 'manager', child: Text(tr('상위자 정하기'))),
                ],
              )
            else
              const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

/// 부서 이름 넣기 창 — 입력칸 컨트롤러를 창이 닫히는 애니메이션이 끝날 때까지 갖고 있게 창이 직접 만든다.
class _DepartmentNameDialog extends StatefulWidget {
  final String title;
  final String initial;
  const _DepartmentNameDialog({required this.title, required this.initial});

  @override
  State<_DepartmentNameDialog> createState() => _DepartmentNameDialogState();
}

class _DepartmentNameDialogState extends State<_DepartmentNameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _controller.text.trim();
    if (v.isNotEmpty) Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const ValueKey('org-department-name'),
        controller: _controller,
        autofocus: true,
        maxLength: 30,
        decoration: InputDecoration(
          labelText: tr('부서 이름'),
          hintText: tr('예: 영업1팀'),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('org-department-name-confirm'),
          onPressed: _submit,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}

/// 사람 고르기 창 — 이름 검색, 맨 위에 "없음" 칸.
class _PersonPicker extends StatefulWidget {
  final String title;
  final String noneLabel;
  final List<OrgMember> people;
  final OrgTree tree;
  final String? current;
  final String Function(String relative) resolveUrl;
  const _PersonPicker({
    required this.title,
    required this.noneLabel,
    required this.people,
    required this.tree,
    required this.current,
    required this.resolveUrl,
  });

  @override
  State<_PersonPicker> createState() => _PersonPickerState();
}

class _PersonPickerState extends State<_PersonPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final list = widget.people
        .where((m) => q.isEmpty || m.name.toLowerCase().contains(q))
        .toList();
    final hint = Theme.of(context).hintColor;
    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      content: SizedBox(
        width: 360,
        height: 420,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('org-person-search'),
              autofocus: true,
              decoration: InputDecoration(
                hintText: tr('이름 검색'),
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _q = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  ListTile(
                    key: const ValueKey('org-pick-person-none'),
                    dense: true,
                    title: Text(
                      widget.noneLabel,
                      style: TextStyle(color: hint),
                    ),
                    onTap: () => Navigator.of(context).pop(''),
                  ),
                  for (final m in list)
                    ListTile(
                      key: ValueKey('org-pick-person-${m.id}'),
                      dense: true,
                      leading: UserAvatar(
                        user: m.toAppUser(),
                        resolveUrl: widget.resolveUrl,
                        radius: 14,
                      ),
                      title: Text(m.name),
                      subtitle: Text(
                        [
                          widget.tree.department(m.departmentId)?.name ??
                              tr('부서 없음'),
                          if (m.position != null && m.position!.isNotEmpty)
                            m.position!,
                        ].join(' · '),
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: m.id == widget.current
                          ? const Icon(Icons.check, size: 16)
                          : null,
                      onTap: () => Navigator.of(context).pop(m.id),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
      ],
    );
  }
}
