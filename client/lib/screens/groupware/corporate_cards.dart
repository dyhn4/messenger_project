import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../models/groupware_finance.dart';
import '../../services/download_storage.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../services/time_format.dart';
import '../../widgets/app_toast.dart';
import 'approval_forms.dart' show showExpenseRequestDialog, toastSubmitted;
import 'finance_widgets.dart';
import 'groupware_screen.dart';
import '../../l10n/tr.dart';

/// 법인카드 — 지출 탭의 "내 법인카드"(청구하지 않은 내 사용 건 — 골라서 한 번에 지출 결재로 청구, 영수증 붙이기·읽기, 영수증으로 사용 건
/// 찾기)와 사용 건 하나의 창(관리자도 같이 쓴다 — 사용자 지정·제외). 서버는 server/src/corporateCards.js, 지출 결재는 groupware.js의
/// cardTransactionIds(금액은 고른 사용 건의 합계와 같아야 한다).

/// 사용 건 한 줄의 날짜·시각 — "10/18 12:30".
String cardTxWhen(CardTransaction t) {
  final d = t.usedAt;
  return '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

/// 상태 칩.
class CardTxStatusChip extends StatelessWidget {
  final CardTxStatus status;
  const CardTxStatusChip(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (status) {
      CardTxStatus.open => Colors.orange.shade800,
      CardTxStatus.claiming => scheme.primary,
      CardTxStatus.settled => Colors.green.shade700,
      CardTxStatus.excluded => Theme.of(context).hintColor,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(status.label, style: TextStyle(fontSize: 11, color: color)),
    );
  }
}

/// 지출 탭의 "내 법인카드" — 청구하지 않은 내 사용 건(기간 없이), 골라서 "n건 청구", 영수증으로 찾기, 모든 내역.
class MyCardSection extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final GroupwareChanges changes;
  final Session session;
  const MyCardSection({
    super.key,
    required this.api,
    required this.ctx,
    required this.changes,
    required this.session,
  });

  @override
  State<MyCardSection> createState() => _MyCardSectionState();
}

class _MyCardSectionState extends State<MyCardSection> {
  CardTransactionPage? _page;
  final _selected = <String>{};
  String? _error;
  bool _busy = false;

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
      final page = await widget.api.cardTransactions(month: 'open', mine: true);
      if (!mounted) return;
      setState(() {
        _page = page;
        _selected.removeWhere(
          (id) => !page.items.any((t) => t.id == id && t.canClaim),
        );
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _open(CardTransaction t) async {
    final changed = await showCardTransactionDialog(
      context,
      api: widget.api,
      ctx: widget.ctx,
      session: widget.session,
      transaction: t,
    );
    if (changed) await _load();
  }

  Future<void> _claim() async {
    final items = [
      for (final t in _page?.items ?? const <CardTransaction>[])
        if (_selected.contains(t.id)) t,
    ];
    if (items.isEmpty) return;
    final missing = items.where((t) => t.receipts.isEmpty).length;
    if (missing > 0) {
      final go = await confirmAction(
        context,
        title: tr('영수증 없이 청구'),
        message: tr('고른 {n}건 중 {m}건에 영수증이 없습니다. 그대로 청구할까요?', {
          'n': items.length,
          'm': missing,
        }),
        okLabel: tr('청구하기'),
      );
      if (!go || !mounted) return;
    }
    final doc = await showExpenseRequestDialog(
      context,
      api: widget.api,
      ctx: widget.ctx,
      session: widget.session,
      cardTransactions: items,
    );
    if (!mounted || doc == null) return;
    toastSubmitted(context, doc);
    _selected.clear();
    widget.changes.bump();
  }

  /// 영수증 사진을 올려 읽고, 맞을 법한 내 사용 건에 붙인다.
  Future<void> _findByReceipt() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.image,
      withData: false,
    );
    final file = picked?.files.single;
    if (file == null || (file.path == null && file.bytes == null) || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      final up = await widget.session.api!.uploadFile(file.xFile);
      final scan = await widget.api.scanReceipt(
        fileUrl: up.url,
        fileName: up.fileName,
        mimeType: up.mimeType,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      final target = await showDialog<CardTransaction>(
        context: context,
        builder: (_) => _ReceiptMatchDialog(scan: scan),
      );
      if (target == null) return;
      setState(() => _busy = true);
      await widget.api.updateCardTransaction(
        target.id,
        receipts: [
          ...target.receipts,
          ReceiptFile(
            fileUrl: up.url,
            fileName: up.fileName,
            fileSize: up.size,
            mimeType: up.mimeType,
          ),
        ],
        category: target.category ?? scan.category,
      );
      await widget.api.scanReceipt(
        transactionId: target.id,
        receiptIndex: target.receipts.length,
      );
      if (mounted) {
        showAppToast(
          context,
          tr('{merchant} 사용 건에 영수증을 붙였습니다.', {'merchant': target.merchant}),
        );
      }
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    final hint = Theme.of(context).hintColor;
    final selectedTotal = (page?.items ?? const <CardTransaction>[])
        .where((t) => _selected.contains(t.id))
        .fold<int>(0, (s, t) => s + t.amount);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupwareSectionHeader(
          tr('내 법인카드 — 청구할 사용 건'),
          trailing: Wrap(
            spacing: 4,
            children: [
              if (widget.ctx.receiptOcr)
                IconButton(
                  key: const ValueKey('card-find-by-receipt'),
                  tooltip: tr('영수증으로 사용 건 찾기'),
                  onPressed: _busy ? null : _findByReceipt,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.document_scanner_outlined),
                ),
              IconButton(
                key: const ValueKey('card-history'),
                tooltip: tr('모든 사용 내역'),
                icon: const Icon(Icons.history),
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => CardHistoryScreen(
                      api: widget.api,
                      ctx: widget.ctx,
                      session: widget.session,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_error != null)
          GroupwareEmpty(_error!)
        else if (page == null)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (page.items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              tr('청구할 법인카드 사용 건이 없습니다. 관리자가 카드사 이용내역을 가져오면 여기에 보입니다.'),
              style: TextStyle(color: hint),
            ),
          )
        else ...[
          for (final t in page.items)
            CheckboxListTile(
              key: ValueKey('card-tx-${t.id}'),
              value: _selected.contains(t.id),
              onChanged: t.canClaim
                  ? (v) => setState(
                      () => v == true
                          ? _selected.add(t.id)
                          : _selected.remove(t.id),
                    )
                  : null,
              controlAffinity: ListTileControlAffinity.leading,
              title: Row(
                children: [
                  Expanded(
                    child: Text(t.merchant, overflow: TextOverflow.ellipsis),
                  ),
                  Text(
                    signedWonText(t.amount),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    [
                      cardTxWhen(t),
                      '${t.cardName} ${t.last4}',
                      ?t.memo,
                      if (t.unassigned) tr('여럿이 쓰는 카드'),
                    ].join(' · '),
                  ),
                  if (t.mismatchText != null)
                    Text(
                      t.mismatchText!,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.orange.shade800,
                      ),
                    ),
                ],
              ),
              secondary: IconButton(
                tooltip: t.receipts.isEmpty
                    ? tr('영수증 없음')
                    : tr('영수증 {n}장', {'n': t.receipts.length}),
                icon: Icon(
                  t.receipts.isEmpty
                      ? Icons.receipt_outlined
                      : Icons.receipt_long,
                  color: t.receipts.isEmpty ? hint : Colors.green.shade700,
                ),
                onPressed: () => _open(t),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _selected.isEmpty
                        ? tr('청구할 건을 고르세요 — 영수증 아이콘을 눌러 영수증·용도를 붙입니다.')
                        : tr('{n}건 · {won}', {
                            'n': _selected.length,
                            'won': signedWonText(selectedTotal),
                          }),
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                ),
                FilledButton.icon(
                  key: const ValueKey('card-claim'),
                  onPressed: _selected.isEmpty ? null : _claim,
                  icon: const Icon(Icons.request_quote_outlined, size: 18),
                  label: Text(tr('지출 결재로 청구')),
                ),
              ],
            ),
          ),
        ],
        const Divider(),
      ],
    );
  }
}

/// 영수증으로 찾은 사용 건 고르기 — 읽은 값과 맞는 정도(승인번호·금액·날짜·카드·가맹점) 순.
class _ReceiptMatchDialog extends StatelessWidget {
  final ReceiptScanResult scan;
  const _ReceiptMatchDialog({required this.scan});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    String reasonText(String r) => switch (r) {
      'approvalNo' => tr('승인번호'),
      'amount' => tr('금액'),
      'date' => tr('날짜'),
      'card' => tr('카드'),
      'merchant' => tr('가맹점'),
      _ => r,
    };
    return AlertDialog(
      title: Text(tr('영수증과 맞는 사용 건')),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              scan.empty
                  ? tr('영수증에서 읽은 것이 없습니다. 더 밝고 반듯하게 찍어 다시 해 보세요.')
                  : tr('읽은 값: {summary}', {'summary': scan.receipt.summary}),
              key: const ValueKey('receipt-match-summary'),
            ),
            const SizedBox(height: 8),
            if (!scan.empty && scan.matches.isEmpty)
              Text(
                tr('맞는 미정산 사용 건이 없습니다. 아직 이용내역이 들어오지 않았을 수 있습니다.'),
                style: TextStyle(color: hint),
              ),
            for (final m in scan.matches)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '${m.transaction.merchant} · ${signedWonText(m.transaction.amount)}',
                ),
                subtitle: Text(
                  '${cardTxWhen(m.transaction)} · ${tr('맞음: {list}', {'list': m.reasons.map(reasonText).join(', ')})}',
                ),
                trailing: FilledButton(
                  onPressed: () => Navigator.pop(context, m.transaction),
                  child: Text(tr('붙이기')),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('닫기')),
        ),
      ],
    );
  }
}

/// 사용 건 하나의 창 — 내용, 영수증(붙이기·읽기·열기), 용도·분류, "내가 씀", 관리자는 사용자 지정·제외·지우기. 바뀌었으면 true.
Future<bool> showCardTransactionDialog(
  BuildContext context, {
  required GroupwareApi api,
  required GroupwareContext ctx,
  required Session session,
  required CardTransaction transaction,
  List<({String id, String? name})> holders = const [],
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _CardTxDialog(
        api: api,
        ctx: ctx,
        session: session,
        tx: transaction,
        holders: holders,
      ),
    ) ==
    true;

class _CardTxDialog extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final Session session;
  final CardTransaction tx;
  final List<({String id, String? name})> holders;
  const _CardTxDialog({
    required this.api,
    required this.ctx,
    required this.session,
    required this.tx,
    required this.holders,
  });

  @override
  State<_CardTxDialog> createState() => _CardTxDialogState();
}

class _CardTxDialogState extends State<_CardTxDialog> {
  late CardTransaction _tx = widget.tx;
  late final _memo = TextEditingController(text: widget.tx.memo);
  late String? _category = widget.tx.category;
  bool _busy = false;
  bool _changed = false;
  String? _error;

  @override
  void dispose() {
    _memo.dispose();
    super.dispose();
  }

  Future<void> _do(Future<CardTransaction?> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final next = await action();
      if (!mounted) return;
      setState(() {
        if (next != null) _tx = next;
        _changed = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _attach() async {
    final picked = await FilePicker.pickFiles(allowMultiple: true);
    final files = [
      for (final f in picked?.files ?? const <PlatformFile>[])
        if (f.path != null || f.bytes != null) f.xFile,
    ].take(5 - _tx.receipts.length).toList();
    if (files.isEmpty) return;
    await _do(() async {
      final added = <ReceiptFile>[];
      for (final f in files) {
        final up = await widget.session.api!.uploadFile(f);
        added.add(
          ReceiptFile(
            fileUrl: up.url,
            fileName: up.fileName,
            fileSize: up.size,
            mimeType: up.mimeType,
          ),
        );
      }
      var next = await widget.api.updateCardTransaction(
        _tx.id,
        receipts: [..._tx.receipts, ...added],
      );
      // 영수증 읽기가 켜져 있으면 처음 붙인 사진을 바로 읽어 사용 건과 맞춰 본다.
      final firstImage = added.indexWhere(
        (r) => r.isImage || (r.mimeType ?? '').contains('pdf'),
      );
      if (widget.ctx.receiptOcr && firstImage >= 0) {
        try {
          final scan = await widget.api.scanReceipt(
            transactionId: _tx.id,
            receiptIndex: _tx.receipts.length + firstImage,
          );
          next = scan.transaction ?? next;
          if ((_category == null || _category!.isEmpty) &&
              scan.category != null) {
            _category = scan.category;
          }
        } catch (e) {
          if (mounted) {
            showAppToast(context, tr('영수증을 읽지 못했습니다: {e}', {'e': e}));
          }
        }
      }
      return next;
    });
  }

  Future<void> _scan(int index) => _do(() async {
    final scan = await widget.api.scanReceipt(
      transactionId: _tx.id,
      receiptIndex: index,
    );
    if ((_category == null || _category!.isEmpty) && scan.category != null) {
      _category = scan.category;
    }
    if (scan.empty && mounted) showAppToast(context, tr('영수증에서 읽은 것이 없습니다.'));
    return scan.transaction;
  });

  Future<void> _openReceipt(ReceiptFile r) async {
    final url = r.fileUrl;
    if (url == null) return;
    try {
      final path = await widget.session.downloadAuthedFile(
        url,
        fileName: r.fileName ?? tr('영수증'),
      );
      await openLocalFile(path);
    } catch (e) {
      if (mounted) showAppToast(context, tr('열지 못했습니다: {e}', {'e': e}));
    }
  }

  Future<void> _save() async {
    await _do(
      () => widget.api.updateCardTransaction(
        _tx.id,
        memo: _memo.text.trim(),
        category: _category ?? '',
      ),
    );
    if (mounted && _error == null) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final t = _tx;
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final isManager = widget.ctx.isManager;
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(label, style: TextStyle(color: hint)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
    final sourceLabel = switch (t.source) {
      'api' => tr('연동'),
      'manual' => tr('직접 넣음'),
      _ => tr('이용내역 가져오기'),
    };
    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(t.merchant)),
          CardTxStatusChip(t.status),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                signedWonText(t.amount),
                key: const ValueKey('card-tx-amount'),
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              row(tr('사용 일시'), formatDateTime(t.usedAt)),
              row(tr('카드'), '${t.cardName} (${t.issuer} ${t.last4})'),
              if (t.approvalNo != null) row(tr('승인번호'), t.approvalNo!),
              if (t.merchantBizNo != null) row(tr('사업자번호'), t.merchantBizNo!),
              row(tr('사용자'), t.userName ?? tr('정해지지 않음(여럿이 쓰는 카드)')),
              row(tr('들어온 곳'), sourceLabel),
              if (t.expense != null)
                row(
                  tr('지출 결재'),
                  [?t.expense!.docNumber, ?t.expense!.title].join(' '),
                ),
              if (t.status == CardTxStatus.excluded)
                row(
                  tr('제외'),
                  tr('{reason} ({by})', {
                    'reason': t.excludedReason ?? '',
                    'by': t.excludedByName ?? '',
                  }),
                ),
              if (t.receiptScan != null) ...[
                const SizedBox(height: 8),
                Text(
                  tr('읽은 영수증: {summary}', {'summary': t.receiptScan!.summary}),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              ],
              if (t.mismatchText != null)
                Text(
                  t.mismatchText!,
                  key: const ValueKey('card-tx-mismatch'),
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
                ),
              const SizedBox(height: 12),
              Text(tr('영수증'), style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final (i, r) in t.receipts.indexed)
                    InputChip(
                      label: Text(
                        r.fileName ?? tr('영수증'),
                        overflow: TextOverflow.ellipsis,
                      ),
                      avatar: const Icon(Icons.receipt_long, size: 16),
                      onPressed: () => _openReceipt(r),
                      onDeleted: t.canEdit && !_busy
                          ? () => _do(
                              () => widget.api.updateCardTransaction(
                                t.id,
                                receipts: [...t.receipts]..removeAt(i),
                              ),
                            )
                          : null,
                    ),
                  if (widget.ctx.receiptOcr)
                    for (final (i, r) in t.receipts.indexed)
                      if (r.isImage || (r.mimeType ?? '').contains('pdf'))
                        ActionChip(
                          avatar: const Icon(
                            Icons.document_scanner_outlined,
                            size: 16,
                          ),
                          label: Text(
                            t.receipts.length == 1
                                ? tr('영수증 읽기')
                                : tr('{n}번 읽기', {'n': i + 1}),
                          ),
                          onPressed: _busy ? null : () => _scan(i),
                        ),
                  if (t.canEdit && t.receipts.length < 5)
                    ActionChip(
                      key: const ValueKey('card-tx-attach'),
                      avatar: _busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.attach_file, size: 16),
                      label: Text(tr('영수증 붙이기')),
                      onPressed: _busy ? null : _attach,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('card-tx-memo'),
                controller: _memo,
                enabled: t.canEdit,
                maxLength: 300,
                decoration: InputDecoration(
                  labelText: tr('용도(예: 거래처 미팅 — 함께한 사람)'),
                  border: const OutlineInputBorder(),
                ),
              ),
              DropdownButtonFormField<String?>(
                initialValue: widget.ctx.expenseCategories.contains(_category)
                    ? _category
                    : null,
                decoration: InputDecoration(
                  labelText: tr('분류'),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem(value: null, child: Text(tr('(정하지 않음)'))),
                  for (final c in widget.ctx.expenseCategories)
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: t.canEdit
                    ? (v) => setState(() => _category = v)
                    : null,
              ),
              if (t.status == CardTxStatus.open) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (t.unassigned && !isManager)
                      OutlinedButton.icon(
                        key: const ValueKey('card-tx-mine'),
                        onPressed: _busy
                            ? null
                            : () => _do(
                                () => widget.api.updateCardTransaction(
                                  t.id,
                                  mine: true,
                                ),
                              ),
                        icon: const Icon(Icons.person_add_alt, size: 18),
                        label: Text(tr('내가 씀')),
                      ),
                    if (isManager && widget.holders.isNotEmpty)
                      DropdownButton<String?>(
                        key: const ValueKey('card-tx-assign'),
                        value: widget.holders.any((h) => h.id == t.userId)
                            ? t.userId
                            : null,
                        hint: Text(tr('사용자 정하기')),
                        items: [
                          DropdownMenuItem(
                            value: null,
                            child: Text(tr('(정하지 않음)')),
                          ),
                          for (final h in widget.holders)
                            DropdownMenuItem(
                              value: h.id,
                              child: Text(h.name ?? ''),
                            ),
                        ],
                        onChanged: _busy
                            ? null
                            : (v) => _do(
                                () => widget.api.updateCardTransaction(
                                  t.id,
                                  userId: v,
                                  setUser: true,
                                ),
                              ),
                      ),
                    if (isManager)
                      OutlinedButton.icon(
                        key: const ValueKey('card-tx-exclude'),
                        onPressed: _busy
                            ? null
                            : () async {
                                final reason = await askText(
                                  context,
                                  title: tr('사용 건 제외'),
                                  message: tr(
                                    '청구하지 않을 건으로 뺍니다(개인 사용·중복·카드사 오류 등). 감사 로그에 남습니다.',
                                  ),
                                  label: tr('사유'),
                                  okLabel: tr('제외'),
                                );
                                if (reason == null) return;
                                await _do(
                                  () => widget.api.excludeCardTransaction(
                                    t.id,
                                    reason,
                                  ),
                                );
                              },
                        icon: const Icon(Icons.block, size: 18),
                        label: Text(tr('제외')),
                      ),
                  ],
                ),
              ],
              if (isManager && t.status == CardTxStatus.excluded)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _do(
                            () => widget.api.restoreCardTransaction(t.id),
                          ),
                    icon: const Icon(Icons.undo, size: 18),
                    label: Text(tr('제외 풀기')),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (isManager &&
            (t.status == CardTxStatus.open ||
                t.status == CardTxStatus.excluded))
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    final ok = await confirmAction(
                      context,
                      title: tr('사용 건 지우기'),
                      message: tr('잘못 들어온 사용 건을 지웁니다. 이용내역을 다시 가져오면 다시 들어옵니다.'),
                      okLabel: tr('지우기'),
                      danger: true,
                    );
                    if (!ok) return;
                    try {
                      await widget.api.deleteCardTransaction(t.id);
                      if (context.mounted) Navigator.pop(context, true);
                    } catch (e) {
                      if (mounted) setState(() => _error = e.toString());
                    }
                  },
            child: Text(tr('지우기')),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context, _changed),
          child: Text(tr('닫기')),
        ),
        if (t.canEdit)
          FilledButton(
            key: const ValueKey('card-tx-save'),
            onPressed: _busy ? null : _save,
            child: Text(tr('저장')),
          ),
      ],
    );
  }
}

/// 내 사용 내역 전체(달마다) — 상태·결재 번호와 함께.
class CardHistoryScreen extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final Session session;
  const CardHistoryScreen({
    super.key,
    required this.api,
    required this.ctx,
    required this.session,
  });

  @override
  State<CardHistoryScreen> createState() => _CardHistoryScreenState();
}

class _CardHistoryScreenState extends State<CardHistoryScreen> {
  late String _month = widget.ctx.today.substring(0, 7);
  CardTransactionPage? _page;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _page = null);
    try {
      final page = await widget.api.cardTransactions(month: _month, mine: true);
      if (mounted) setState(() => _page = page);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    final hint = Theme.of(context).hintColor;
    return Scaffold(
      appBar: AppBar(title: Text(tr('내 법인카드 사용 내역'))),
      body: ListView(
        children: [
          Center(
            child: MonthStepper(
              month: _month,
              onChanged: (m) {
                _month = m;
                _load();
              },
            ),
          ),
          if (_error != null)
            GroupwareEmpty(_error!)
          else if (page == null)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                tr('합계 {all} · 미정산 {open} · 결재 중 {claiming} · 정산됨 {settled}', {
                  'all': signedWonText(page.total),
                  'open': signedWonText(page.openTotal),
                  'claiming': signedWonText(page.claimingTotal),
                  'settled': signedWonText(page.settledTotal),
                }),
                style: TextStyle(fontSize: 12, color: hint),
              ),
            ),
            if (page.items.isEmpty) GroupwareEmpty(tr('이 달의 사용 건이 없습니다.')),
            for (final t in page.items)
              ListTile(
                title: Text(t.merchant),
                subtitle: Text(
                  [
                    cardTxWhen(t),
                    '${t.cardName} ${t.last4}',
                    if (t.expense?.docNumber != null) t.expense!.docNumber!,
                  ].join(' · '),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(signedWonText(t.amount)),
                    const SizedBox(width: 8),
                    CardTxStatusChip(t.status),
                  ],
                ),
                onTap: () async {
                  final changed = await showCardTransactionDialog(
                    context,
                    api: widget.api,
                    ctx: widget.ctx,
                    session: widget.session,
                    transaction: t,
                  );
                  if (changed) await _load();
                },
              ),
          ],
        ],
      ),
    );
  }
}
