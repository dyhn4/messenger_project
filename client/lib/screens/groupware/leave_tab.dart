import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import 'approval_forms.dart';
import 'approval_tab.dart';
import 'groupware_screen.dart';

/// 휴가 탭 — 내 연차 현황(입사일 기준 법정 연차 — server annualLeave.js), 휴가 신청, 앞으로 30일의 팀 휴가, 내 휴가 결재.
class LeaveTab extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final GroupwareChanges changes;
  final Session session;
  const LeaveTab({
    super.key,
    required this.api,
    required this.ctx,
    required this.changes,
    required this.session,
  });

  @override
  State<LeaveTab> createState() => _LeaveTabState();
}

class _LeaveTabState extends State<LeaveTab> {
  LeaveBalance? _balance;
  List<TeamLeave> _teamLeaves = const [];
  List<ApprovalDocument> _mine = const [];
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
    final today = DateTime.parse(widget.ctx.today);
    try {
      final results = await Future.wait([
        widget.api.leaveBalance(),
        widget.api.teamLeaves(
          from: widget.ctx.today,
          to: dateKeyOf(today.add(const Duration(days: 30))),
        ),
        widget.api.documents(box: ApprovalBox.mine, kind: ApprovalKind.leave),
      ]);
      if (!mounted) return;
      setState(() {
        _balance = results[0] as LeaveBalance;
        _teamLeaves = results[1] as List<TeamLeave>;
        _mine = results[2] as List<ApprovalDocument>;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _request() async {
    final doc = await showLeaveRequestDialog(
      context,
      api: widget.api,
      ctx: widget.ctx,
      balance: _balance,
    );
    if (!mounted || doc == null) return;
    toastSubmitted(context, doc);
    widget.changes.bump();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return GroupwareEmpty(_error!);
    final balance = _balance;
    if (balance == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          _BalanceCard(balance: balance, onRequest: _request),
          GroupwareSectionHeader('앞으로 30일 팀 휴가'),
          if (_teamLeaves.isEmpty)
            const GroupwareEmpty('예정된 휴가가 없습니다.')
          else
            for (final l in _teamLeaves)
              ListTile(
                dense: true,
                leading: const Icon(Icons.beach_access_outlined, size: 20),
                title: Text(
                  '${l.name} · ${widget.ctx.leaveType(l.leaveType)?.label ?? '휴가'}',
                ),
                subtitle: Text(
                  l.startDate == l.endDate
                      ? shortDateText(l.startDate)
                      : '${shortDateText(l.startDate)} ~ ${shortDateText(l.endDate)}',
                ),
              ),
          GroupwareSectionHeader('내 휴가 결재'),
          if (_mine.isEmpty)
            const GroupwareEmpty('올린 휴가 결재가 없습니다.')
          else
            for (final d in _mine)
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
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  final LeaveBalance balance;
  final VoidCallback onRequest;
  const _BalanceCard({required this.balance, required this.onRequest});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    Widget stat(String label, String value, {Color? color}) => Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          Text(label, style: TextStyle(fontSize: 12, color: hint)),
        ],
      ),
    );
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('내 연차', style: theme.textTheme.titleMedium),
                ),
                FilledButton.icon(
                  key: const ValueKey('leave-request'),
                  onPressed: onRequest,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('휴가 신청'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (!balance.known)
              Text(
                '입사일이 등록되지 않아 연차를 계산할 수 없습니다. 결재·근태 관리자에게 입사일 등록을 요청하세요. (휴가 신청은 할 수 있습니다)',
                style: TextStyle(color: hint),
              )
            else ...[
              Row(
                children: [
                  stat('생긴 연차', halfDaysText(balance.grantedHalfDays!)),
                  stat('쓴 연차', halfDaysText(balance.usedHalfDays)),
                  stat('결재 중', halfDaysText(balance.pendingHalfDays)),
                  stat(
                    '남은 연차',
                    halfDaysText(balance.remainingHalfDays!),
                    color: theme.colorScheme.primary,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                [
                  '입사일 ${balance.hireDate}',
                  if (balance.periodStart != null)
                    '이번 연차 기간 ${balance.periodStart} ~ ${balance.periodEnd}',
                  balance.serviceYears == 0
                      ? '입사 첫해 — 한 달 채울 때마다 1일(최대 11일)'
                      : '근속 ${balance.serviceYears}년',
                  if (balance.adjustmentHalfDays != 0)
                    '관리자 조정 ${balance.adjustmentHalfDays > 0 ? '+' : '−'}${halfDaysText(balance.adjustmentHalfDays.abs())}',
                ].join(' · '),
                style: TextStyle(fontSize: 12, color: hint),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
