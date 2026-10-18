import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import 'approval_forms.dart';
import 'approval_tab.dart';
import 'groupware_screen.dart';
import '../../l10n/tr.dart';

/// 지출 탭 — 지출 결재 올리기(금액·분류·쓴 날·영수증)와 내가 올린 지출 결재.
class ExpenseTab extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final GroupwareChanges changes;
  final Session session;
  const ExpenseTab({
    super.key,
    required this.api,
    required this.ctx,
    required this.changes,
    required this.session,
  });

  @override
  State<ExpenseTab> createState() => _ExpenseTabState();
}

class _ExpenseTabState extends State<ExpenseTab> {
  List<ApprovalDocument>? _mine;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.changes.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final docs = await widget.api.documents(
        box: ApprovalBox.mine,
        kind: ApprovalKind.expense,
      );
      if (mounted) setState(() => _mine = docs);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _request() async {
    final doc = await showExpenseRequestDialog(
      context,
      api: widget.api,
      ctx: widget.ctx,
      session: widget.session,
    );
    if (!mounted || doc == null) return;
    toastSubmitted(context, doc);
    widget.changes.bump();
  }

  @override
  Widget build(BuildContext context) {
    final mine = _mine;
    final approvedTotal = (mine ?? const <ApprovalDocument>[])
        .where((d) => d.status == ApprovalStatus.approved)
        .fold<int>(
          0,
          (sum, d) => sum + ((d.payload['amount'] as num?)?.toInt() ?? 0),
        );
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          GroupwareSectionHeader(
            tr('내 지출 결재'),
            trailing: FilledButton.icon(
              key: const ValueKey('expense-request'),
              onPressed: _request,
              icon: const Icon(Icons.add, size: 18),
              label: Text(tr('지출 결재 올리기')),
            ),
          ),
          if (approvedTotal > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                tr('승인된 지출 합계 {p0}', {'p0': wonText(approvedTotal)}),
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
            ),
          if (_error != null)
            GroupwareEmpty(_error!)
          else if (mine == null)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (mine.isEmpty)
            GroupwareEmpty(tr('올린 지출 결재가 없습니다.'))
          else
            for (final d in mine)
              ApprovalDocumentTile(
                doc: d,
                ctx: widget.ctx,
                onTap: () async {
                  final changed = await showApprovalDetail(
                    context,
                    api: widget.api,
                    ctx: widget.ctx,
                    session: widget.session,
                    documentId: d.id,
                  );
                  if (changed) widget.changes.bump();
                },
              ),
        ],
      ),
    );
  }
}
