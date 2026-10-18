import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../services/download_storage.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../services/time_format.dart';
import '../../widgets/app_toast.dart';
import 'approval_form_widgets.dart';
import 'approval_forms.dart'
    show settleDiffText, showExpenseRequestDialog, toastSubmitted;
import 'approval_print.dart';
import 'approval_settings.dart';
import 'groupware_screen.dart';
import '../../l10n/tr.dart';

/// 결재 탭 — 결재함(결재할 문서 · 내가 올린 문서 · 결재한 문서 · 참조 문서 · 관리자는 전체 문서). 줄을 누르면 문서 상세.
class ApprovalTab extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final GroupwareChanges changes;
  final Session session;
  const ApprovalTab({
    super.key,
    required this.api,
    required this.ctx,
    required this.changes,
    required this.session,
  });

  @override
  State<ApprovalTab> createState() => _ApprovalTabState();
}

class _ApprovalTabState extends State<ApprovalTab> {
  late ApprovalBox _box = widget.ctx.pendingForMe > 0
      ? ApprovalBox.inbox
      : ApprovalBox.mine;
  List<ApprovalDocument>? _docs;
  String? _error;
  int _loadSeq = 0;

  /// "정산 안 됨" 거르기 — 승인됐는데 살아 있는 정산이 없는 구매 요청·출장 신청만(서버 ?unsettled=1). "내가 올린 문서"(내 것)와
  /// 관리자의 "전체 문서"(모두의 것)에서만 고를 수 있고, 다른 함으로 옮기면 꺼진다.
  bool _unsettled = false;

  /// 지금 함에서 "정산 안 됨" 거르기를 고를 수 있는지.
  bool get _canFilterUnsettled =>
      _box == ApprovalBox.mine ||
      (_box == ApprovalBox.all && widget.ctx.isManager);

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
    final seq = ++_loadSeq;
    try {
      final docs = await widget.api.documents(
        box: _box,
        unsettled: _unsettled && _canFilterUnsettled,
      );
      if (mounted && seq == _loadSeq) setState(() => _docs = docs);
    } catch (e) {
      if (mounted && seq == _loadSeq) setState(() => _error = e.toString());
    }
  }

  /// "새 결재" — 휴가·지출과 켜진 양식 중에서 골라 올린다. 올렸으면 "내가 올린 문서"로 옮겨 보여 준다.
  Future<void> _newApproval() async {
    final doc = await showNewApprovalChooser(
      context,
      api: widget.api,
      ctx: widget.ctx,
      session: widget.session,
    );
    if (doc == null || !mounted) return;
    toastSubmitted(context, doc);
    widget.changes.bump();
    if (_box != ApprovalBox.mine) _select(ApprovalBox.mine);
  }

  void _select(ApprovalBox box) {
    setState(() {
      _box = box;
      if (!_canFilterUnsettled) _unsettled = false;
      _docs = null;
      _error = null;
    });
    _load();
  }

  void _toggleUnsettled(bool on) {
    setState(() {
      _unsettled = on;
      _docs = null;
      _error = null;
    });
    _load();
  }

  Future<void> _open(ApprovalDocument doc) async {
    final changed = await showApprovalDetail(
      context,
      api: widget.api,
      ctx: widget.ctx,
      session: widget.session,
      documentId: doc.id,
    );
    if (changed) widget.changes.bump();
  }

  @override
  Widget build(BuildContext context) {
    final boxes = [
      ApprovalBox.inbox,
      ApprovalBox.mine,
      ApprovalBox.done,
      ApprovalBox.cc,
      if (widget.ctx.isManager) ApprovalBox.all,
    ];
    final docs = _docs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(
            children: [
              FilledButton.icon(
                key: const ValueKey('approval-new'),
                onPressed: _newApproval,
                icon: const Icon(Icons.edit_document, size: 18),
                label: Text(tr('새 결재')),
              ),
              // 내 결재 설정 — 서명·도장, 대결(부재 중 대신 결재).
              PopupMenuButton<String>(
                key: const ValueKey('approval-settings'),
                tooltip: tr('결재 설정'),
                icon: const Icon(Icons.manage_accounts_outlined),
                onSelected: (v) => v == 'signature'
                    ? showSignatureDialog(
                        context,
                        api: widget.api,
                        session: widget.session,
                      )
                    : showDelegationsDialog(
                        context,
                        api: widget.api,
                        ctx: widget.ctx,
                        session: widget.session,
                        changes: widget.changes,
                      ),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'signature', child: Text(tr('내 서명·도장'))),
                  PopupMenuItem(
                    value: 'delegation',
                    child: Text(tr('대결(부재) 설정')),
                  ),
                ],
              ),
              const SizedBox(width: 4),
              for (final box in boxes)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    key: ValueKey('approval-box-${box.wire}'),
                    label: Text(
                      box == ApprovalBox.inbox && widget.ctx.pendingForMe > 0
                          ? '${box.label} ${widget.ctx.pendingForMe}'
                          : box.label,
                    ),
                    selected: _box == box,
                    onSelected: (_) => _select(box),
                  ),
                ),
              if (_canFilterUnsettled) ...[
                const SizedBox(width: 6),
                FilterChip(
                  key: const ValueKey('approval-filter-unsettled'),
                  avatar: _unsettled
                      ? null
                      : const Icon(Icons.receipt_long_outlined, size: 16),
                  label: Text(tr('정산 안 됨')),
                  tooltip: tr('승인됐지만 아직 정산하지 않은 구매·출장'),
                  selected: _unsettled,
                  onSelected: _toggleUnsettled,
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: _error != null
              ? GroupwareEmpty(_error!)
              : docs == null
              ? const Center(child: CircularProgressIndicator())
              : docs.isEmpty
              ? GroupwareEmpty(
                  _box == ApprovalBox.inbox
                      ? tr('지금 결재할 문서가 없습니다.')
                      : _unsettled && _canFilterUnsettled
                      ? tr('정산할 구매·출장 결재가 없습니다.')
                      : tr('문서가 없습니다.'),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    itemCount: docs.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) => ApprovalDocumentTile(
                      doc: docs[i],
                      ctx: widget.ctx,
                      onTap: () => _open(docs[i]),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// 문서 상세를 연다. 승인·반려·회수·취소를 했으면 true.
Future<bool> showApprovalDetail(
  BuildContext context, {
  required GroupwareApi api,
  required GroupwareContext ctx,
  required Session session,
  required String documentId,
}) async {
  final changed = await showDialog<bool>(
    context: context,
    builder: (_) => ApprovalDetailDialog(
      api: api,
      ctx: ctx,
      session: session,
      documentId: documentId,
    ),
  );
  return changed ?? false;
}

/// 결재 문서 상세 — 내용, 결재선(누가 언제 승인·반려했는지와 의견), 참조자, 그리고 내 차례면 승인·반려, 올린 사람은 회수, 관리자는
/// 승인된 문서 취소.
class ApprovalDetailDialog extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final Session session;
  final String documentId;
  const ApprovalDetailDialog({
    super.key,
    required this.api,
    required this.ctx,
    required this.session,
    required this.documentId,
  });

  @override
  State<ApprovalDetailDialog> createState() => _ApprovalDetailDialogState();
}

class _ApprovalDetailDialogState extends State<ApprovalDetailDialog> {
  ApprovalDocument? _doc;
  String? _error;
  bool _busy = false;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final doc = await widget.api.document(widget.documentId);
      if (mounted) setState(() => _doc = doc);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// [action]: approve | reject | withdraw | cancel. 반려·취소는 사유를, 승인은 의견(선택)을 받는다.
  Future<void> _act(String action) async {
    String? comment;
    if (action != 'withdraw') {
      final result = await showDialog<String>(
        context: context,
        builder: (_) => _CommentDialog(
          title: switch (action) {
            'approve' => _doc?.finalForMe == true ? tr('전결 승인') : tr('승인'),
            'reject' => tr('반려'),
            _ => tr('결재 취소'),
          },
          note: [
            if (action == 'approve' && _doc?.finalForMe == true)
              tr('전결 — 승인하면 남은 결재는 생략되고 바로 결재가 끝납니다.'),
            if (action != 'cancel' && _doc?.actingFor != null)
              tr('{p0}님 대신(대결) 결정합니다. 대결한 사람으로 함께 남습니다.', {
                'p0': _doc!.actingFor,
              }),
          ].join('\n'),
          label: switch (action) {
            'approve' => tr('의견 (선택)'),
            'reject' => tr('반려 사유'),
            _ => tr('취소 사유'),
          },
          required: action != 'approve',
        ),
      );
      if (result == null) return;
      comment = result.trim().isEmpty ? null : result.trim();
    } else {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(tr('결재 회수')),
          content: Text(tr('올린 결재를 거둘까요? 결재자에게 더는 보이지 않습니다.')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(tr('취소')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(tr('회수')),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy = true);
    try {
      final doc = await widget.api.decide(
        widget.documentId,
        action,
        comment: comment,
      );
      if (!mounted) return;
      setState(() {
        _doc = doc;
        _changed = true;
      });
      showAppToast(context, switch (action) {
        'approve' =>
          doc.status == ApprovalStatus.approved
              ? tr('승인했습니다. 결재가 끝났습니다.')
              : tr('승인했습니다. {p0}님 차례입니다.', {
                  'p0': doc.steps
                      .where((s) => s.status == ApprovalStepStatus.pending)
                      .map((s) => s.approverName)
                      .join(', '),
                }),
        'reject' => tr('반려했습니다.'),
        'withdraw' => tr('회수했습니다.'),
        _ => tr('취소했습니다.'),
      });
      await widget.session.refreshGroupwarePending();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// "정산하기" — 이 승인된 구매 요청·출장 신청을 정산하는 지출 결재 창을 연다(예산·내용을 미리 채움). 올렸으면 안내하고 상세를
  /// 다시 받아 정산 상태("정산 결재 중")를 보인다. 서버가 거절하면(이미 정산함 등) 지출 창 안에 그 문구가 뜬다.
  Future<void> _settle(ApprovalDocument doc) async {
    final created = await showExpenseRequestDialog(
      context,
      api: widget.api,
      ctx: widget.ctx,
      session: widget.session,
      settles: doc,
    );
    if (created == null || !mounted) return;
    toastSubmitted(context, created);
    setState(() => _changed = true);
    await _load();
  }

  /// 다른 결재(정산 지출 ↔ 원래 결재)의 상세를 위에 겹쳐 연다. 거기서 무언가 바꿨으면 이 문서도 다시 받는다(정산 상태가 바뀔 수 있다).
  Future<void> _openLinked(String id) async {
    final changed = await showApprovalDetail(
      context,
      api: widget.api,
      ctx: widget.ctx,
      session: widget.session,
      documentId: id,
    );
    if (!changed || !mounted) return;
    setState(() => _changed = true);
    await _load();
  }

  Future<void> _openAttachment(ApprovalAttachment a) async {
    final url = a.fileUrl;
    if (url == null) return;
    try {
      final path = await widget.session.downloadAuthedFile(
        url,
        fileName: a.fileName ?? tr('첨부'),
      );
      await openLocalFile(path);
    } catch (e) {
      if (mounted) showAppToast(context, tr('열지 못했습니다: {e}', {'e': e}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    return AlertDialog(
      title: Text(doc?.title ?? tr('결재 문서')),
      content: SizedBox(
        width: 480,
        child: doc == null
            ? (_error != null
                  ? Text(_error!)
                  : const SizedBox(
                      height: 80,
                      child: Center(child: CircularProgressIndicator()),
                    ))
            : SingleChildScrollView(child: _buildBody(context, doc)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_changed),
          child: Text(tr('닫기')),
        ),
        if (doc != null)
          PopupMenuButton<String>(
            key: const ValueKey('approval-print'),
            tooltip: tr('인쇄·PDF'),
            icon: const Icon(Icons.print_outlined),
            onSelected: (v) => v == 'print'
                ? printApproval(context, doc, widget.ctx, widget.session)
                : saveApprovalPdf(context, doc, widget.ctx, widget.session),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'print', child: Text(tr('인쇄'))),
              PopupMenuItem(value: 'pdf', child: Text(tr('PDF로 저장'))),
            ],
          ),
        // 승인된 내 구매 요청·출장 신청에 살아 있는 정산이 없으면(서버 canSettle) — 쓴 돈을 지출 결재로 정산한다.
        if (doc != null && doc.canSettle)
          OutlinedButton.icon(
            key: const ValueKey('approval-settle'),
            onPressed: _busy ? null : () => _settle(doc),
            icon: const Icon(Icons.receipt_long_outlined, size: 18),
            label: Text(tr('정산하기')),
          ),
        if (doc != null && doc.canWithdraw)
          TextButton(
            key: const ValueKey('approval-withdraw'),
            onPressed: _busy ? null : () => _act('withdraw'),
            child: Text(tr('회수')),
          ),
        if (doc != null && doc.canCancel)
          TextButton(
            key: const ValueKey('approval-cancel'),
            onPressed: _busy ? null : () => _act('cancel'),
            child: Text(tr('결재 취소')),
          ),
        if (doc != null && doc.myTurn) ...[
          OutlinedButton(
            key: const ValueKey('approval-reject'),
            onPressed: _busy ? null : () => _act('reject'),
            child: Text(tr('반려')),
          ),
          FilledButton(
            key: const ValueKey('approval-approve'),
            onPressed: _busy ? null : () => _act('approve'),
            child: Text(tr('승인')),
          ),
        ],
      ],
    );
  }

  Widget _buildBody(BuildContext context, ApprovalDocument doc) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(label, style: TextStyle(color: hint)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
    final p = doc.payload;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            ApprovalStatusChip(doc.status),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                [
                  doc.kindLabel,
                  doc.authorName,
                  if (doc.docNumber != null) doc.docNumber!,
                ].join(' · '),
                key: const ValueKey('approval-doc-header'),
                style: TextStyle(color: hint),
              ),
            ),
            if (doc.createdAt != null)
              Text(
                formatDateTime(doc.createdAt!),
                style: TextStyle(color: hint, fontSize: 12),
              ),
          ],
        ),
        if (doc.actingFor != null && doc.myTurn)
          Container(
            key: const ValueKey('approval-acting-for'),
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              tr('{doc.actingFor}님이 자리를 비워 대신(대결) 결재할 차례입니다.', {
                'doc.actingFor': doc.actingFor,
              }),
            ),
          ),
        const SizedBox(height: 12),
        ApprovalStampBox(doc: doc, resolveUrl: widget.session.resolveUrl),
        const SizedBox(height: 12),
        if (doc.kind == ApprovalKind.leave) ...[
          row(
            tr('종류'),
            p['leaveLabel'] as String? ??
                widget.ctx.leaveType(p['leaveType'] as String?)?.label ??
                tr('휴가'),
          ),
          row(
            tr('기간'),
            p['startDate'] == p['endDate']
                ? '${p['startDate']}'
                : '${p['startDate']} ~ ${p['endDate']}',
          ),
          row(tr('일수'), halfDaysText((p['halfDays'] as num?)?.toInt() ?? 0)),
        ],
        if (doc.kind == ApprovalKind.expense) ...[
          row(tr('금액'), wonText((p['amount'] as num?)?.toInt() ?? 0)),
          row(tr('분류'), '${p['category'] ?? ''}'),
          row(tr('쓴 날'), '${p['spentOn'] ?? ''}'),
          if (doc.settles case final settles?)
            ..._settlesRows(context, doc, settles, row),
        ],
        if (doc.kind.isForm) FormValuesView(doc: doc),
        if (kSettleKinds.contains(doc.kind)) ?_settlementRow(context, doc),
        if (doc.kind == ApprovalKind.attendance) ...[
          row(tr('날짜'), '${p['workDate'] ?? ''}'),
          row(tr('출근'), '${p['clockIn'] ?? ''}'),
          row(
            tr('퇴근'),
            p['clockOut'] == null ? tr('(그대로)') : '${p['clockOut']}',
          ),
        ],
        if (doc.body != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(doc.body!),
          ),
        ],
        if (doc.attachments.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final a in doc.attachments)
                ActionChip(
                  avatar: const Icon(Icons.attach_file, size: 16),
                  label: Text(a.fileName ?? tr('첨부')),
                  onPressed: () => _openAttachment(a),
                ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        Text(tr('결재선'), style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        for (final s in doc.steps)
          ListTile(
            key: ValueKey('approval-step-${s.order}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              radius: 13,
              backgroundColor: switch (s.status) {
                ApprovalStepStatus.approved => Colors.green.shade100,
                ApprovalStepStatus.rejected => theme.colorScheme.errorContainer,
                ApprovalStepStatus.pending =>
                  theme.colorScheme.primaryContainer,
                ApprovalStepStatus.waiting || ApprovalStepStatus.skipped =>
                  theme.colorScheme.surfaceContainerHighest,
              },
              child: Text(
                '${s.stage + 1}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            title: Text(
              '${s.approverName} · ${s.role.label} · ${s.status.label}',
            ),
            subtitle:
                s.comment == null &&
                    s.decidedAt == null &&
                    s.actedByName == null
                ? null
                : Text(
                    [
                      if (s.actedByName != null)
                        tr('대결 {s.actedByName}', {
                          's.actedByName': s.actedByName,
                        }),
                      if (s.decidedAt != null) formatDateTime(s.decidedAt!),
                      if (s.comment != null) '"${s.comment}"',
                    ].join(' · '),
                  ),
          ),
        if (doc.cc.isNotEmpty)
          row(tr('참조'), doc.cc.map((c) => c.name).join(', ')),
        if (doc.status == ApprovalStatus.canceled)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              tr('{p0}님이 취소했습니다: {p1}', {
                'p0': doc.canceledByName ?? tr('관리자'),
                'p1': doc.cancelReason ?? '',
              }),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }

  /// 구매 요청·출장 신청의 "정산" 줄 — 이 결재를 정산하는 지출 결재의 상태(서버 settlementOf: 승인된 것 → 결재 중 → 최근 것)와
  /// 그 번호·제목·금액·예산과의 차이. 누르면 그 지출 결재 상세를 연다. 정산이 아직 없으면 승인된 결재에만 "정산 안 함"을 보인다
  /// (진행 중·반려된 구매·출장은 정산할 일이 없다). 보일 게 없으면 null.
  Widget? _settlementRow(BuildContext context, ApprovalDocument doc) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final s = doc.settlement;
    if (s == null && doc.status != ApprovalStatus.approved) return null;
    final (String status, Color color) = switch (s?.status) {
      null => (tr('정산 안 함'), hint),
      ApprovalStatus.pending => (tr('정산 결재 중'), theme.colorScheme.primary),
      ApprovalStatus.approved => (tr('정산됨'), Colors.green.shade700),
      final other => (
        tr('정산 {status} — 다시 올릴 수 있습니다', {'status': other.label}),
        theme.colorScheme.error,
      ),
    };
    final budget = settleBudgetOf(doc);
    final amount = s?.amount;
    final detail = s == null
        ? ''
        : [
            ?s.docNumber,
            s.title,
            if (amount != null) wonText(amount),
            if (amount != null && budget != null)
              settleDiffText(amount - budget),
          ].join(' · ');
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(tr('정산'), style: TextStyle(color: hint)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status,
                  style: TextStyle(color: color, fontWeight: FontWeight.w600),
                ),
                if (detail.isNotEmpty)
                  Text(detail, style: TextStyle(fontSize: 12, color: hint)),
              ],
            ),
          ),
          if (s != null) Icon(Icons.chevron_right, size: 18, color: hint),
        ],
      ),
    );
    return Padding(
      key: const ValueKey('approval-settlement'),
      padding: const EdgeInsets.only(top: 4),
      child: s == null
          ? content
          : InkWell(
              onTap: () => _openLinked(s.id),
              borderRadius: BorderRadius.circular(6),
              child: content,
            ),
    );
  }

  /// 정산 지출 결재의 줄들 — "정산 대상"(올릴 때의 번호·제목, 누르면 그 결재 상세)과, 예산을 알면 "예산"·"차이"(+면 예산보다 많이 씀).
  List<Widget> _settlesRows(
    BuildContext context,
    ApprovalDocument doc,
    ApprovalSettles settles,
    Widget Function(String label, String value) row,
  ) {
    final hint = Theme.of(context).hintColor;
    final budget = settles.budget;
    final amount = (doc.payload['amount'] as num?)?.toInt();
    return [
      InkWell(
        key: const ValueKey('approval-settles'),
        onTap: settles.id.isEmpty ? null : () => _openLinked(settles.id),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              SizedBox(
                width: 72,
                child: Text(tr('정산 대상'), style: TextStyle(color: hint)),
              ),
              Expanded(
                child: Text(
                  [
                    settles.kind.label,
                    ?settles.docNumber,
                    settles.title,
                  ].join(' · '),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: hint),
            ],
          ),
        ),
      ),
      if (budget != null) ...[
        row(tr('예산'), wonText(budget)),
        if (amount != null)
          KeyedSubtree(
            key: const ValueKey('approval-settle-diff'),
            child: row(
              tr('차이'),
              '${_signedWon(amount - budget)} (${settleDiffText(amount - budget)})',
            ),
          ),
      ],
    ];
  }
}

/// 차이 금액 → "+12,000원" / "-3,000원" / "0원"(wonText는 음수를 못 받아 부호를 따로 붙인다).
String _signedWon(int diff) =>
    '${diff > 0
        ? '+'
        : diff < 0
        ? '-'
        : ''}${wonText(diff.abs())}';

class _CommentDialog extends StatefulWidget {
  final String title;
  final String label;
  final bool required;

  /// 입력칸 위의 안내(전결·대결) — 비면 없음.
  final String note;
  const _CommentDialog({
    required this.title,
    required this.label,
    required this.required,
    this.note = '',
  });

  @override
  State<_CommentDialog> createState() => _CommentDialogState();
}

class _CommentDialogState extends State<_CommentDialog> {
  final _text = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _done() {
    if (widget.required && _text.text.trim().isEmpty) {
      setState(
        () =>
            _error = tr('{widget.label}를 쓰세요.', {'widget.label': widget.label}),
      );
      return;
    }
    Navigator.of(context).pop(_text.text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                widget.note,
                key: const ValueKey('approval-comment-note'),
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          TextField(
            key: const ValueKey('approval-comment'),
            controller: _text,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            maxLength: 500,
            decoration: InputDecoration(
              labelText: widget.label,
              errorText: _error,
              border: const OutlineInputBorder(),
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
      FilledButton(
        key: const ValueKey('approval-comment-ok'),
        onPressed: _done,
        child: Text(widget.title),
      ),
    ],
  );
}
