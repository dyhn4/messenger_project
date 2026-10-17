import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../services/download_storage.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../services/time_format.dart';
import '../../widgets/app_toast.dart';
import 'groupware_screen.dart';

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
      final docs = await widget.api.documents(box: _box);
      if (mounted && seq == _loadSeq) setState(() => _docs = docs);
    } catch (e) {
      if (mounted && seq == _loadSeq) setState(() => _error = e.toString());
    }
  }

  void _select(ApprovalBox box) {
    setState(() {
      _box = box;
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
                  _box == ApprovalBox.inbox ? '지금 결재할 문서가 없습니다.' : '문서가 없습니다.',
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
            'approve' => '승인',
            'reject' => '반려',
            _ => '결재 취소',
          },
          label: switch (action) {
            'approve' => '의견 (선택)',
            'reject' => '반려 사유',
            _ => '취소 사유',
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
          title: const Text('결재 회수'),
          content: const Text('올린 결재를 거둘까요? 결재자에게 더는 보이지 않습니다.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('회수'),
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
              ? '승인했습니다. 결재가 끝났습니다.'
              : '승인했습니다. 다음 결재자에게 넘어갔습니다.',
        'reject' => '반려했습니다.',
        'withdraw' => '회수했습니다.',
        _ => '취소했습니다.',
      });
      await widget.session.refreshGroupwarePending();
    } catch (e) {
      if (mounted) showAppToast(context, '실패: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openAttachment(ApprovalAttachment a) async {
    final url = a.fileUrl;
    if (url == null) return;
    try {
      final path = await widget.session.downloadAuthedFile(
        url,
        fileName: a.fileName ?? '첨부',
      );
      await openLocalFile(path);
    } catch (e) {
      if (mounted) showAppToast(context, '열지 못했습니다: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    return AlertDialog(
      title: Text(doc?.title ?? '결재 문서'),
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
          child: const Text('닫기'),
        ),
        if (doc != null && doc.canWithdraw)
          TextButton(
            key: const ValueKey('approval-withdraw'),
            onPressed: _busy ? null : () => _act('withdraw'),
            child: const Text('회수'),
          ),
        if (doc != null && doc.canCancel)
          TextButton(
            key: const ValueKey('approval-cancel'),
            onPressed: _busy ? null : () => _act('cancel'),
            child: const Text('결재 취소'),
          ),
        if (doc != null && doc.myTurn) ...[
          OutlinedButton(
            key: const ValueKey('approval-reject'),
            onPressed: _busy ? null : () => _act('reject'),
            child: const Text('반려'),
          ),
          FilledButton(
            key: const ValueKey('approval-approve'),
            onPressed: _busy ? null : () => _act('approve'),
            child: const Text('승인'),
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
                '${doc.kind.label} · ${doc.authorName}',
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
        const SizedBox(height: 12),
        if (doc.kind == ApprovalKind.leave) ...[
          row(
            '종류',
            widget.ctx.leaveType(p['leaveType'] as String?)?.label ?? '휴가',
          ),
          row(
            '기간',
            p['startDate'] == p['endDate']
                ? '${p['startDate']}'
                : '${p['startDate']} ~ ${p['endDate']}',
          ),
          row('일수', halfDaysText((p['halfDays'] as num?)?.toInt() ?? 0)),
        ],
        if (doc.kind == ApprovalKind.expense) ...[
          row('금액', wonText((p['amount'] as num?)?.toInt() ?? 0)),
          row('분류', '${p['category'] ?? ''}'),
          row('쓴 날', '${p['spentOn'] ?? ''}'),
        ],
        if (doc.kind == ApprovalKind.attendance) ...[
          row('날짜', '${p['workDate'] ?? ''}'),
          row('출근', '${p['clockIn'] ?? ''}'),
          row('퇴근', p['clockOut'] == null ? '(그대로)' : '${p['clockOut']}'),
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
                  label: Text(a.fileName ?? '첨부'),
                  onPressed: () => _openAttachment(a),
                ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        Text('결재선', style: theme.textTheme.titleSmall),
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
                ApprovalStepStatus.waiting =>
                  theme.colorScheme.surfaceContainerHighest,
              },
              child: Text(
                '${s.order + 1}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            title: Text('${s.approverName} · ${s.status.label}'),
            subtitle: s.comment == null && s.decidedAt == null
                ? null
                : Text(
                    [
                      if (s.decidedAt != null) formatDateTime(s.decidedAt!),
                      if (s.comment != null) '"${s.comment}"',
                    ].join(' · '),
                  ),
          ),
        if (doc.cc.isNotEmpty) row('참조', doc.cc.map((c) => c.name).join(', ')),
        if (doc.status == ApprovalStatus.canceled)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${doc.canceledByName ?? '관리자'}님이 취소했습니다: ${doc.cancelReason ?? ''}',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }
}

class _CommentDialog extends StatefulWidget {
  final String title;
  final String label;
  final bool required;
  const _CommentDialog({
    required this.title,
    required this.label,
    required this.required,
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
      setState(() => _error = '${widget.label}를 쓰세요.');
      return;
    }
    Navigator.of(context).pop(_text.text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 360,
      child: TextField(
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
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('취소'),
      ),
      FilledButton(
        key: const ValueKey('approval-comment-ok'),
        onPressed: _done,
        child: Text(widget.title),
      ),
    ],
  );
}
