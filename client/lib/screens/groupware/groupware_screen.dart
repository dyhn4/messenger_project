import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../services/time_format.dart';
import 'approval_tab.dart';
import 'attendance_tab.dart';
import 'expense_tab.dart';
import 'groupware_admin_tab.dart';
import 'leave_tab.dart';

/// 그룹웨어 화면을 연다 — PC·모바일 모두 전체 화면.
Future<void> openGroupwareScreen(BuildContext context, Session session) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => GroupwareScreen(session: session)),
  );
}

/// 그룹웨어 — 전자결재(휴가·지출·근태 수정), 연차, 출퇴근(server/src/groupware.js). 탭: 결재 · 휴가 · 지출 · 출퇴근 · 관리(관리자만).
///
/// 범위(팀마다 / 회사 전체)는 서버 설정을 따르고(관리자 콘솔 "운영 현황"), 화면은 지금 보고 있는 팀을 함께 보낸다
/// (session.groupwareApi). 결재가 올라오거나 진행되면 소켓(groupware:changed)으로 알아서 다시 받는다.
class GroupwareScreen extends StatefulWidget {
  final Session session;

  /// 테스트에서 가짜 API를 끼울 때. 기본은 세션의 것(session.groupwareApi).
  final GroupwareApi? api;
  const GroupwareScreen({super.key, required this.session, this.api});

  @override
  State<GroupwareScreen> createState() => _GroupwareScreenState();
}

class _GroupwareScreenState extends State<GroupwareScreen> {
  GroupwareContext? _ctx;
  String? _error;

  /// 결재가 바뀌었다는 신호 — 탭들이 듣고 자기 목록을 다시 받는다.
  final _changes = GroupwareChanges();
  StreamSubscription<String>? _sub;

  GroupwareApi get _api => widget.api ?? widget.session.groupwareApi;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = widget.session.chatSocket.groupwareChanged.listen((_) {
      _changes.bump();
      unawaited(_reloadContext());
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _changes.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final ctx = await _api.context();
      if (mounted) setState(() => _ctx = ctx);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// 결재 수 같은 값만 다시 — 화면이 깜빡이지 않게 실패는 조용히 넘긴다.
  Future<void> _reloadContext() async {
    try {
      final ctx = await _api.context();
      if (mounted) setState(() => _ctx = ctx);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final ctx = _ctx;
    if (ctx == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('그룹웨어')),
        body: Center(
          child: _error != null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _error!.contains('Cannot') || _error!.contains('요청이 실패')
                        ? '이 서버 버전은 그룹웨어를 지원하지 않습니다. 서버를 업데이트하세요.'
                        : _error!,
                    textAlign: TextAlign.center,
                  ),
                )
              : const CircularProgressIndicator(),
        ),
      );
    }
    final tabs = <(String, Widget)>[
      (
        ctx.pendingForMe > 0 ? '결재 ${ctx.pendingForMe}' : '결재',
        ApprovalTab(
          api: _api,
          ctx: ctx,
          changes: _changes,
          session: widget.session,
        ),
      ),
      (
        '휴가',
        LeaveTab(
          api: _api,
          ctx: ctx,
          changes: _changes,
          session: widget.session,
        ),
      ),
      (
        '지출',
        ExpenseTab(
          api: _api,
          ctx: ctx,
          changes: _changes,
          session: widget.session,
        ),
      ),
      (
        '출퇴근',
        AttendanceTab(
          api: _api,
          ctx: ctx,
          changes: _changes,
          session: widget.session,
        ),
      ),
      if (ctx.isManager)
        (
          '관리',
          GroupwareAdminTab(
            api: _api,
            ctx: ctx,
            changes: _changes,
            session: widget.session,
            onContextChanged: _reloadContext,
          ),
        ),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text('그룹웨어 · ${ctx.scopeLabel}'),
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              for (final t in tabs)
                Tab(key: ValueKey('groupware-tab-${t.$1}'), text: t.$1),
            ],
          ),
        ),
        body: TabBarView(children: [for (final t in tabs) t.$2]),
      ),
    );
  }
}

/// 결재가 바뀌었다는 신호(탭끼리, 그리고 소켓에서). 값은 바뀔 때마다 하나씩 는다.
class GroupwareChanges extends ValueNotifier<int> {
  GroupwareChanges() : super(0);
  void bump() => value = value + 1;
}

/// 결재 상태 표시.
class ApprovalStatusChip extends StatelessWidget {
  final ApprovalStatus status;
  const ApprovalStatusChip(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (status) {
      ApprovalStatus.pending => scheme.primary,
      ApprovalStatus.approved => Colors.green.shade700,
      ApprovalStatus.rejected => scheme.error,
      ApprovalStatus.withdrawn ||
      ApprovalStatus.canceled => Theme.of(context).hintColor,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          fontSize: 12,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 결재 종류의 아이콘(목록·새 결재 고르기).
IconData approvalKindIcon(ApprovalKind kind) => switch (kind) {
  ApprovalKind.leave => Icons.beach_access_outlined,
  ApprovalKind.expense => Icons.receipt_long_outlined,
  ApprovalKind.attendance => Icons.schedule_outlined,
  ApprovalKind.draft => Icons.description_outlined,
  ApprovalKind.trip => Icons.flight_takeoff_outlined,
  ApprovalKind.purchase => Icons.shopping_cart_outlined,
  ApprovalKind.overtime => Icons.more_time_outlined,
  ApprovalKind.form => Icons.dynamic_form_outlined,
};

/// 결재 문서 목록 한 줄.
class ApprovalDocumentTile extends StatelessWidget {
  final ApprovalDocument doc;
  final GroupwareContext ctx;
  final VoidCallback onTap;
  const ApprovalDocumentTile({
    super.key,
    required this.doc,
    required this.ctx,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final current = doc.currentStep;
    final icon = approvalKindIcon(doc.kind);
    return ListTile(
      key: ValueKey('approval-doc-${doc.id}'),
      onTap: onTap,
      leading: Icon(icon),
      title: Text(doc.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          doc.authorName,
          doc.summary(ctx),
          if (doc.createdAt != null) formatDateTime(doc.createdAt!),
          if (current != null) '${current.approverName} 결재 차례',
        ].join(' · '),
        style: TextStyle(color: hint),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: doc.myTurn
          ? const Icon(Icons.edit_note, color: Colors.deepOrange)
          : ApprovalStatusChip(doc.status),
    );
  }
}

/// 비었을 때 가운데 안내.
class GroupwareEmpty extends StatelessWidget {
  final String text;
  const GroupwareEmpty(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(32),
    child: Center(
      child: Text(text, style: TextStyle(color: Theme.of(context).hintColor)),
    ),
  );
}

/// 탭 위쪽 제목 줄(제목 + 오른쪽 단추).
class GroupwareSectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const GroupwareSectionHeader(this.title, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
        ?trailing,
      ],
    ),
  );
}
