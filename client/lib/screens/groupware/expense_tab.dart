import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import 'approval_forms.dart';
import 'approval_tab.dart';
import 'card_admin.dart';
import 'corporate_cards.dart';
import 'groupware_screen.dart';
import '../../l10n/tr.dart';

/// 지출 탭 — 지출 결재 올리기(금액·분류·쓴 날·영수증)와 내가 올린 지출 결재, 내가 쓰는 법인카드의 청구할 사용 건(corporate_cards.dart),
/// 그룹웨어 관리자에게는 "법인카드 관리"(card_admin.dart — 카드·이용내역 가져오기·사용 건·연동 키).
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

  /// 관리자가 "법인카드 관리"를 보고 있는지.
  bool _cardAdmin = false;

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
    final ctx = widget.ctx;
    final showCardAdmin = ctx.isManager && ctx.cardsAvailable;
    return RefreshIndicator(
      onRefresh: () async {
        widget.changes.bump();
        await _load();
      },
      child: ListView(
        children: [
          if (showCardAdmin)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: SegmentedButton<bool>(
                key: const ValueKey('expense-mode'),
                segments: [
                  ButtonSegment(
                    value: false,
                    label: Text(tr('내 지출')),
                    icon: const Icon(Icons.receipt_outlined),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text(tr('법인카드 관리')),
                    icon: const Icon(Icons.credit_card),
                  ),
                ],
                selected: {_cardAdmin},
                onSelectionChanged: (v) => setState(() => _cardAdmin = v.first),
              ),
            ),
          if (showCardAdmin && _cardAdmin)
            CardAdminView(
              api: widget.api,
              ctx: ctx,
              changes: widget.changes,
              session: widget.session,
            )
          else ...[
            // 내가 쓰는 법인카드가 있으면 청구할 사용 건.
            if (ctx.cardsAvailable && ctx.cardsMine > 0)
              MyCardSection(
                api: widget.api,
                ctx: ctx,
                changes: widget.changes,
                session: widget.session,
              ),
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
        ],
      ),
    );
  }
}
