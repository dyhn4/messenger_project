import 'dart:async';

import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/org_tree.dart';
import '../services/download_storage.dart';
import '../services/session.dart';
import 'app_toast.dart';
import 'muted_scrollbar.dart';
import 'org_chart_diagram.dart';
import 'org_tree_import.dart';
import 'user_avatar.dart';
import '../l10n/tr.dart';

/// 조직도 "부서" 탭 — 부서 트리(위 부서 › 아래 부서)와 부서마다의 사람들, 부서장·상위자(서버 orgTree.js). 누구나 보고(회사 하나면
/// 정회원 이상, 팀마다면 그 팀 멤버), 고칠 수 있는 사람(회사 하나면 서버 운영자·관리자, 팀마다면 팀 소유자도)에게는 부서 만들기·이름
/// 바꾸기·옮기기·부서장·지우기와 사람의 부서·상위자 지정 메뉴가 붙는다. 상위자는 결재선 추천(그룹웨어 결재)에 쓰인다.
///
/// 겸직: 한 사람이 주 부서 말고 다른 부서(5개까지)에도 속할 수 있다 — 그 부서의 사람들 밑에 "겸직" 표시와 그 부서에서의 직책(없으면
/// 주 직책)으로 보이고, 상위자·결재선은 주 부서를 따른다. 고칠 수 있는 사람은 사람 메뉴의 "겸직 추가", 겸직 줄 메뉴의 "겸직 빼기"로
/// 다룬다.
///
/// 고칠 수 있는 사람은 끌어다 놓아 옮긴다 — 부서 줄을 다른 부서 줄에 놓으면 그 아래 맨 끝으로, 끄는 동안 위에 뜨는 "맨 위로" 띠에
/// 놓으면 맨 위 부서로(자기와 자기 아래 부서에는 못 놓는다). 사람 줄을 부서 줄에 놓으면 그 사람의 주 부서가 바뀐다. PC는 바로 끌고,
/// 터치 기기는 길게 눌러 끈다(목록 스크롤과 겹치지 않게). 메뉴의 "위로/아래로/다른 부서 아래로 옮기기"도 그대로 있다(접근성).
/// 엑셀로 내보내기·가져오기(미리 보기 후 바꾸기)도 고칠 수 있는 사람에게만 있다. 맨 위 줄의 단추로 목록 ↔ 그림([OrgChartDiagram])을
/// 바꿔 본다(이 화면이 떠 있는 동안만 기억).
///
/// [filter]가 있으면 트리(또는 그림) 대신 이름이 맞는 부서·사람 목록을 보여 준다. 사람을 누르면 [onOpenMember].
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

  /// 그림으로 보는지(아니면 목록) — 이 화면이 떠 있는 동안만 기억한다.
  bool _diagram = false;

  /// 부서를 끄는 중인지 — 그동안 목록 위에 "맨 위로" 놓을 띠를 띄운다.
  bool _draggingDepartment = false;

  /// 엑셀 내보내기·가져오기 중(단추를 끈다).
  bool _excelBusy = false;

  /// 그림에서 눌러 목록으로 돌아온 부서 — 잠깐 색을 입히고 그 줄까지 스크롤한다.
  String? _focusId;
  final _focusKey = GlobalKey();
  Timer? _focusTimer;

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
    _focusTimer?.cancel();
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

  // ── 겸직 ──

  /// 한 사람이 겸할 수 있는 부서 수(서버 orgTreeRules.js CONCURRENT_MAX와 같게) — 넘으면 서버도 막지만 고르기 전에 알린다.
  static const _concurrentMax = 5;

  /// 겸직 넣기 — 부서를 고르고(주 부서·이미 겸한 부서는 빼고) 그 부서에서의 직책(비우면 주 직책)을 넣는다.
  Future<void> _addConcurrent(OrgMember m) async {
    final tree = _tree!;
    final current = tree.concurrentOf(m.id);
    if (current.length >= _concurrentMax) {
      showAppToast(
        context,
        tr('겸직은 {count}개 부서까지 넣을 수 있습니다.', {'count': _concurrentMax}),
      );
      return;
    }
    final picked = await _pickDepartment(
      title: tr('{m.name}의 겸직 부서', {'m.name': m.name}),
      exclude: {?m.departmentId, for (final c in current) c.departmentId},
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final position = await showDialog<String>(
      context: context,
      builder: (_) => _ConcurrentPositionDialog(
        departmentName: tree.department(picked)?.name ?? '',
      ),
    );
    if (position == null) return;
    await _run(() async {
      await _session.api!.addConcurrentDepartment(
        m.id,
        teamId: _teamId,
        departmentId: picked,
        position: position.isEmpty ? null : position,
      );
      _expanded.add(picked);
    }, tr('겸직을 넣지 못했습니다'));
  }

  Future<void> _removeConcurrent(OrgMember m, OrgDepartment d) => _run(
    () => _session.api!.removeConcurrentDepartment(m.id, d.id, teamId: _teamId),
    tr('겸직을 빼지 못했습니다'),
  );

  // ── 끌어다 놓기 ──

  /// [d]를 [parentId](null이면 맨 위) 아래에 놓을 수 있는지 — 자기 자신과 자기 아래 부서에는 못 놓는다(서버도 막는다).
  bool _canPlace(OrgDepartment d, String? parentId) {
    if (parentId == null) return true;
    return parentId != d.id && !_tree!.descendantsOf(d.id).contains(parentId);
  }

  /// 부서 [d]를 [parentId] 아래 맨 끝으로(목록 끌어다 놓기와 그림의 끌어다 놓기가 같이 쓴다). 서버의 index는 자기를 뺀 형제 사이의
  /// 자리라 맨 끝은 "자기를 뺀 형제 수"다.
  Future<void> _placeDepartment(OrgDepartment d, String? parentId) async {
    final tree = _tree;
    if (tree == null || _busy || !_canPlace(d, parentId)) return;
    final index = tree.childrenOf(parentId).where((c) => c.id != d.id).length;
    await _run(() async {
      await _session.api!.placeDepartment(
        d.id,
        parentId: parentId,
        index: index,
      );
      if (parentId != null) _expanded.add(parentId);
    }, tr('옮기지 못했습니다'));
  }

  /// 사람 [m]의 주 부서를 [departmentId]로(사람 줄을 부서 줄에 놓았을 때).
  Future<void> _dropMember(OrgMember m, String departmentId) async {
    if (_busy || m.departmentId == departmentId) return;
    await _run(() async {
      await _session.api!.setMemberOrg(
        m.id,
        teamId: _teamId,
        patch: {'departmentId': departmentId},
      );
      _expanded.add(departmentId);
    }, tr('부서를 옮기지 못했습니다'));
  }

  /// 부서 줄 [target]에 끌어 온 것을 놓을 수 있는지(null이면 "맨 위로" 띠 — 부서만).
  bool _canDrop(_OrgDrag data, OrgDepartment? target) => switch (data) {
    _DepartmentDrag(:final department) => _canPlace(department, target?.id),
    _MemberDrag(:final member) =>
      target != null && member.departmentId != target.id,
  };

  void _drop(_OrgDrag data, OrgDepartment? target) {
    if (!_canDrop(data, target)) return;
    switch (data) {
      case _DepartmentDrag(:final department):
        _placeDepartment(department, target?.id);
      case _MemberDrag(:final member):
        _dropMember(member, target!.id);
    }
  }

  /// 터치 기기(안드로이드·iOS)는 길게 눌러 끈다 — 바로 끌면 목록 스크롤을 빼앗는다.
  bool _isTouch(BuildContext context) => switch (Theme.of(context).platform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => true,
    _ => false,
  };

  /// 줄 하나를 끌 수 있게 감싼다 — 손가락·포인터 옆에 [label] 칩이 따라다니고, 원래 자리는 흐려진다.
  Widget _draggable({
    required Key key,
    required _OrgDrag data,
    required IconData icon,
    required String label,
    required Widget child,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final feedback = Material(
      elevation: 4,
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: scheme.primary),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
    final faded = Opacity(opacity: 0.4, child: child);
    final department = data is _DepartmentDrag;
    void started() {
      if (department) setState(() => _draggingDepartment = true);
    }

    void ended() {
      if (mounted && _draggingDepartment) {
        setState(() => _draggingDepartment = false);
      }
    }

    final max = _busy ? 0 : 1;
    if (_isTouch(context)) {
      return LongPressDraggable<_OrgDrag>(
        key: key,
        data: data,
        maxSimultaneousDrags: max,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: feedback,
        childWhenDragging: faded,
        onDragStarted: started,
        onDragEnd: (_) => ended(),
        child: child,
      );
    }
    return Draggable<_OrgDrag>(
      key: key,
      data: data,
      maxSimultaneousDrags: max,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: feedback,
      childWhenDragging: faded,
      onDragStarted: started,
      onDragEnd: (_) => ended(),
      child: child,
    );
  }

  /// 놓을 곳 — 놓을 수 있는 것이 위에 오면 색을 입힌다. [target]이 null이면 "맨 위로" 띠.
  Widget _dropTarget({
    required Key key,
    required OrgDepartment? target,
    required Widget child,
  }) {
    final primary = Theme.of(context).colorScheme.primary;
    return DragTarget<_OrgDrag>(
      key: key,
      onWillAcceptWithDetails: (d) => !_busy && _canDrop(d.data, target),
      onAcceptWithDetails: (d) => _drop(d.data, target),
      builder: (context, candidates, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: candidates.isEmpty
              ? Colors.transparent
              : primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: child,
      ),
    );
  }

  // ── 엑셀 ──

  /// 엑셀로 내보내기 — "조직도_{범위}_{날짜}.xlsx"로 받아 연다(파일 이름에 못 쓰는 글자는 _).
  Future<void> _export() async {
    final tree = _tree!;
    setState(() => _excelBusy = true);
    try {
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final scope = tree.scope == 'team'
          ? (tree.teamName ?? tr('팀'))
          : tr('회사 전체');
      final name = tr('조직도_{scope}_{date}.xlsx', {
        'scope': scope,
        'date': '${now.year}-${two(now.month)}-${two(now.day)}',
      }).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final path = await _session.downloadAuthedFile(
        _session.api!.orgTreeExportPath(teamId: _teamId),
        fileName: name,
      );
      final notice = await openLocalFile(path);
      if (notice != null && mounted) showAppToast(context, notice);
    } catch (e) {
      if (mounted) showAppToast(context, '${tr('내보내지 못했습니다')}: $e');
    } finally {
      if (mounted) setState(() => _excelBusy = false);
    }
  }

  /// 엑셀에서 가져오기 — 파일을 골라 먼저 미리 보기(dryRun)로 바뀌는 양·오류를 보이고, "가져오기"를 누르면 실제로 바꾼다.
  Future<void> _import() async {
    final ({String name, List<int> bytes})? file;
    try {
      file = await pickOrgImportFile();
    } catch (e) {
      if (mounted) showAppToast(context, '${tr('파일을 열지 못했습니다')}: $e');
      return;
    }
    if (file == null || !mounted) return;
    if (!file.name.toLowerCase().endsWith('.xlsx')) {
      showAppToast(context, tr('엑셀(.xlsx) 파일만 가져올 수 있습니다.'));
      return;
    }
    // 서버에 보내는 동안만 단추를 돌린다(미리 보기 창이 떠 있는 동안은 아니다).
    Future<OrgImportResult?> send({required bool dryRun}) async {
      setState(() => _excelBusy = true);
      try {
        return await _session.api!.importOrgTree(
          file!.bytes,
          teamId: _teamId,
          dryRun: dryRun,
        );
      } catch (e) {
        if (mounted) showAppToast(context, '${tr('가져오지 못했습니다')}: $e');
        return null;
      } finally {
        if (mounted) setState(() => _excelBusy = false);
      }
    }

    final preview = await send(dryRun: true);
    if (preview == null || !mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) =>
          OrgImportPreviewDialog(result: preview, fileName: file!.name),
    );
    if (ok != true || !mounted) return;
    final result = await send(dryRun: false);
    if (result == null || !mounted) return;
    if (result.errors.isNotEmpty) {
      // 미리 본 뒤 다른 사람이 바꿔 이제는 맞지 않는 줄 — 오류만 다시 보인다(바뀐 것은 없다).
      await showDialog<bool>(
        context: context,
        builder: (_) =>
            OrgImportPreviewDialog(result: result, fileName: file!.name),
      );
    } else {
      final skipped = orgImportSkippedText(result);
      showAppToast(
        context,
        [
          tr('가져왔습니다 — {summary}', {'summary': orgImportSummaryText(result)}),
          ?skipped,
        ].join('\n'),
        duration: Duration(milliseconds: skipped == null ? 2500 : 6000),
      );
    }
    await _load();
  }

  // ── 그림 ↔ 목록 ──

  /// 그림에서 누른 부서 — 목록으로 돌아가 그 부서까지 펼치고, 그 줄로 스크롤해 잠깐 색을 입힌다.
  void _revealDepartment(OrgDepartment d) {
    final tree = _tree;
    if (tree == null) return;
    String? cur = d.id;
    final seen = <String>{};
    while (cur != null && seen.add(cur)) {
      _expanded.add(cur);
      cur = tree.department(cur)?.parentId;
    }
    _focusTimer?.cancel();
    setState(() {
      _diagram = false;
      _focusId = d.id;
    });
    _focusTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _focusId = null);
    });
    // 목록은 보이는 줄만 만들어 그 줄이 아직 없을 수 있다 — 대충의 자리로 먼저 뛰고 다음 그림에서 정확히 맞춘다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_ensureFocusVisible()) return;
      if (_scroll.hasClients) {
        final rowIndex = tree.flatten().indexWhere(
          (e) => e.department.id == d.id,
        );
        final pos = _scroll.position;
        _scroll.jumpTo((rowIndex * 48.0).clamp(0, pos.maxScrollExtent));
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureFocusVisible();
      });
    });
  }

  bool _ensureFocusVisible() {
    final ctx = _focusKey.currentContext;
    if (ctx == null) return false;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.2,
      duration: const Duration(milliseconds: 250),
    );
    return true;
  }

  // ── 입력 창 ──

  Future<String?> _askName(String title, {String initial = ''}) =>
      showDialog<String>(
        context: context,
        builder: (_) => _DepartmentNameDialog(title: title, initial: initial),
      );

  /// 부서 고르기 — 고른 부서 id, [noneLabel]을 고르면 빈 글자, 취소하면 null. [noneLabel]이 null이면 "없음" 칸이 없다(겸직 부서).
  Future<String?> _pickDepartment({
    required String title,
    String? noneLabel,
    Set<String> exclude = const {},
    String? current,
  }) {
    final tree = _tree!;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(title),
        children: [
          if (noneLabel != null)
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
    // 검색 중에는 그림이어도 검색 결과 목록을 보인다.
    final diagram = _diagram && filter.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 맨 위 줄 — 팀 고르기(팀마다·팀이 여럿), 목록 ↔ 그림, 고칠 수 있으면 부서 만들기·엑셀.
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
              IconButton(
                key: const ValueKey('org-view-toggle'),
                tooltip: _diagram ? tr('목록으로 보기') : tr('그림으로 보기'),
                icon: Icon(
                  _diagram ? Icons.view_list_outlined : Icons.schema_outlined,
                  size: 20,
                ),
                onPressed: () => setState(() => _diagram = !_diagram),
              ),
              if (tree.canEdit) ...[
                TextButton.icon(
                  key: const ValueKey('org-add-department'),
                  onPressed: _busy ? null : () => _addDepartment(null),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(tr('부서 만들기')),
                ),
                PopupMenuButton<String>(
                  key: const ValueKey('org-excel-menu'),
                  enabled: !_busy && !_excelBusy,
                  tooltip: tr('엑셀'),
                  icon: _excelBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.table_view_outlined, size: 20),
                  onSelected: (v) => v == 'export' ? _export() : _import(),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      key: const ValueKey('org-export'),
                      value: 'export',
                      child: Text(tr('엑셀로 내보내기')),
                    ),
                    PopupMenuItem(
                      key: const ValueKey('org-import'),
                      value: 'import',
                      child: Text(tr('엑셀에서 가져오기')),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: diagram
              ? OrgChartDiagram(
                  tree: tree,
                  resolveUrl: _session.resolveUrl,
                  onTapDepartment: _revealDepartment,
                  onTapMember: (m) => widget.onOpenMember(
                    m.toAppUser(
                      department: tree.department(m.departmentId)?.name,
                    ),
                    tree,
                  ),
                  onMoveDepartment: tree.canEdit ? _placeDepartment : null,
                )
              : Stack(
                  children: [
                    Positioned.fill(
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
                    // 부서를 끄는 동안만 — 여기에 놓으면 맨 위 부서로(목록 위에 겹쳐 띄워 줄이 밀리지 않게).
                    if (_draggingDepartment && filter.isEmpty)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: _rootDropStrip(context),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  /// "맨 위로" 띠 — 부서를 놓으면 맨 위 부서들의 맨 끝으로.
  Widget _rootDropStrip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      elevation: 2,
      borderRadius: BorderRadius.circular(6),
      child: _dropTarget(
        key: const ValueKey('dept-drop-root'),
        target: null,
        child: Container(
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: scheme.primary.withValues(alpha: 0.5)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.vertical_align_top, size: 18, color: scheme.primary),
              const SizedBox(width: 6),
              Text(tr('맨 위로'), style: TextStyle(color: scheme.primary)),
            ],
          ),
        ),
      ),
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
        // 주 부서 사람들 다음에 겸직으로 속한 사람들(그 부서에서의 직책과 함께).
        for (final c in tree.concurrentMembersOf(d.id)) {
          rows.add(
            _memberRow(
              context,
              tree,
              c.member,
              depth + 1,
              isHead: c.member.id == d.headId,
              concurrentIn: d,
              concurrentPosition: c.position,
            ),
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
            setState(() => _diagram = false);
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
    Widget row = InkWell(
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
    // 고칠 수 있으면 끌 수 있고(부서), 부서·사람을 놓을 수 있다.
    if (tree.canEdit) {
      row = _dropTarget(
        key: ValueKey('dept-drop-${d.id}'),
        target: d,
        child: _draggable(
          key: ValueKey('dept-drag-${d.id}'),
          data: _DepartmentDrag(d),
          icon: Icons.account_tree_outlined,
          label: d.name,
          child: row,
        ),
      );
    }
    // 그림에서 눌러 온 부서 — 잠깐 색을 입히고, 스크롤로 찾을 수 있게 GlobalKey를 단다.
    if (d.id == _focusId) {
      row = Container(
        key: _focusKey,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
        ),
        child: row,
      );
    }
    return row;
  }

  /// 작은 표시(부서장·겸직).
  Widget _badge(BuildContext context, Key key, String text, Color color) =>
      Container(
        key: key,
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text, style: TextStyle(fontSize: 10, color: color)),
      );

  /// 사람 한 줄. [concurrentIn]이 있으면 그 부서에 겸직으로 보이는 줄 — "겸직" 표시, 그 부서에서의 직책([concurrentPosition], 없으면
  /// 주 직책)과 주 부서, 메뉴는 "겸직 빼기"만이고 끌 수 없다.
  Widget _memberRow(
    BuildContext context,
    OrgTree tree,
    OrgMember m,
    int depth, {
    bool isHead = false,
    bool showPath = false,
    OrgDepartment? concurrentIn,
    String? concurrentPosition,
  }) {
    final hint = Theme.of(context).hintColor;
    final scheme = Theme.of(context).colorScheme;
    final manager = tree.member(m.effectiveManagerId);
    final dept = tree.department(m.departmentId);
    final concurrent = concurrentIn != null;
    final position = concurrent && (concurrentPosition?.isNotEmpty ?? false)
        ? concurrentPosition
        : m.position;
    // 겸하는 부서 이름들(주 부서 줄·검색 줄에).
    final concurrentNames = concurrent
        ? const <String>[]
        : [
            for (final c in tree.concurrentOf(m.id))
              tree.department(c.departmentId)!.name,
          ];
    final sub = concurrent
        ? [
            if (position != null && position.isNotEmpty) position,
            tr('주 부서 {name}', {'name': dept?.name ?? tr('부서 없음')}),
          ].join(' · ')
        : [
            if (showPath) dept == null ? tr('부서 없음') : tree.pathOf(dept.id),
            if (position != null && position.isNotEmpty) position,
            if (manager != null)
              tr('상위자 {manager.name}{p0}', {
                'manager.name': manager.name,
                'p0': m.managerId != null ? tr('(지정)') : '',
              }),
            if (concurrentNames.isNotEmpty)
              tr('겸직: {names}', {'names': concurrentNames.join(', ')}),
          ].join(' · ');
    final Widget menu;
    if (!tree.canEdit) {
      menu = const SizedBox(width: 8);
    } else if (concurrent) {
      menu = PopupMenuButton<String>(
        key: ValueKey('org-concurrent-menu-${m.id}-${concurrentIn.id}'),
        enabled: !_busy,
        tooltip: tr('구성원 메뉴'),
        icon: const Icon(Icons.more_vert, size: 18),
        onSelected: (_) => _removeConcurrent(m, concurrentIn),
        itemBuilder: (_) => [
          PopupMenuItem(
            key: ValueKey('concurrent-remove-${m.id}-${concurrentIn.id}'),
            value: 'remove',
            child: Text(tr('겸직 빼기')),
          ),
        ],
      );
    } else {
      menu = PopupMenuButton<String>(
        key: ValueKey('org-member-menu-${m.id}'),
        enabled: !_busy,
        tooltip: tr('구성원 메뉴'),
        icon: const Icon(Icons.more_vert, size: 18),
        onSelected: (v) => switch (v) {
          'department' => _moveMember(m),
          'concurrent' => _addConcurrent(m),
          _ => _setManager(m),
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'department', child: Text(tr('부서 옮기기'))),
          PopupMenuItem(value: 'manager', child: Text(tr('상위자 정하기'))),
          PopupMenuItem(
            key: ValueKey('concurrent-add-${m.id}'),
            value: 'concurrent',
            child: Text(tr('겸직 추가')),
          ),
        ],
      );
    }
    final row = InkWell(
      key: concurrent
          ? ValueKey('org-concurrent-${m.id}-${concurrentIn.id}')
          : ValueKey('org-member-${m.id}'),
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
                        _badge(
                          context,
                          ValueKey(
                            concurrent
                                ? 'org-head-badge-${m.id}-${concurrentIn.id}'
                                : 'org-head-badge-${m.id}',
                          ),
                          tr('부서장'),
                          scheme.primary,
                        ),
                      ],
                      if (concurrent) ...[
                        const SizedBox(width: 6),
                        _badge(
                          context,
                          ValueKey(
                            'concurrent-chip-${m.id}-${concurrentIn.id}',
                          ),
                          tr('겸직'),
                          scheme.tertiary,
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
            menu,
          ],
        ),
      ),
    );
    // 고칠 수 있으면 주 부서 줄(트리 안)은 끌어다 다른 부서 줄에 놓아 주 부서를 바꾼다 — 겸직 줄·검색 줄은 끌지 않는다.
    if (!tree.canEdit || concurrent || showPath) return row;
    return _draggable(
      key: ValueKey('member-drag-${m.id}'),
      data: _MemberDrag(m),
      icon: Icons.person_outline,
      label: m.name,
      child: row,
    );
  }
}

/// 끌고 있는 것 — 부서 줄 또는 사람 줄(놓을 곳이 둘을 가려 받는다).
sealed class _OrgDrag {
  const _OrgDrag();
}

class _DepartmentDrag extends _OrgDrag {
  final OrgDepartment department;
  const _DepartmentDrag(this.department);
}

class _MemberDrag extends _OrgDrag {
  final OrgMember member;
  const _MemberDrag(this.member);
}

/// 겸직 부서에서의 직책 넣기 창 — 비우고 넣으면 주 직책을 쓴다(빈 글자를 돌려준다). 취소하면 null.
class _ConcurrentPositionDialog extends StatefulWidget {
  final String departmentName;
  const _ConcurrentPositionDialog({required this.departmentName});

  @override
  State<_ConcurrentPositionDialog> createState() =>
      _ConcurrentPositionDialogState();
}

class _ConcurrentPositionDialogState extends State<_ConcurrentPositionDialog> {
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
      title: Text(tr('"{name}" 겸직', {'name': widget.departmentName})),
      content: TextField(
        key: const ValueKey('concurrent-position'),
        controller: _controller,
        autofocus: true,
        maxLength: 40, // 서버 CONCURRENT_POSITION_MAX와 같게.
        decoration: InputDecoration(
          labelText: tr('이 부서에서의 직책(선택)'),
          hintText: tr('비우면 주 직책을 씁니다'),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('concurrent-confirm'),
          onPressed: _submit,
          child: Text(tr('겸직 추가')),
        ),
      ],
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
