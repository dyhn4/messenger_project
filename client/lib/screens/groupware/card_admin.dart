import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../models/groupware.dart';
import '../../models/groupware_finance.dart';
import '../../services/download_storage.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../services/time_format.dart';
import '../../widgets/app_toast.dart';
import 'corporate_cards.dart';
import 'finance_tools.dart';
import 'finance_widgets.dart';
import 'groupware_screen.dart';
import '../../l10n/tr.dart';

/// 법인카드 관리(그룹웨어 관리자 — 지출 탭의 "법인카드 관리") — 카드 등록(이름·카드사·끝 4자리·사용자·월 한도), 카드사 이용내역(엑셀·CSV) 가져오기,
/// 사용 건 직접 넣기, 한 달 사용 건(상태별)·제외·사용자 지정, 미정산 알림, 엑셀 내보내기, 연동 키(바깥 서비스가 사용 건을 밀어 넣는 열쇠).
/// 서버는 server/src/corporateCards.js.
class CardAdminView extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final GroupwareChanges changes;
  final Session session;
  const CardAdminView({
    super.key,
    required this.api,
    required this.ctx,
    required this.changes,
    required this.session,
  });

  @override
  State<CardAdminView> createState() => _CardAdminViewState();
}

class _CardAdminViewState extends State<CardAdminView> {
  late String _month = widget.ctx.today.substring(0, 7);
  List<CorporateCard>? _cards;
  CardTransactionPage? _page;
  CardTxStatus? _status;
  String? _cardId;
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
      final results = await Future.wait([
        widget.api.corporateCards(month: _month),
        widget.api.cardTransactions(month: _month, cardId: _cardId),
      ]);
      if (!mounted) return;
      setState(() {
        _cards = results[0] as List<CorporateCard>;
        _page = results[1] as CardTransactionPage;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _run(Future<String?> Function() action) async {
    setState(() => _busy = true);
    try {
      final message = await action();
      if (mounted && message != null) showAppToast(context, message);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editCard([CorporateCard? card]) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _CardEditorDialog(api: widget.api, card: card),
    );
    if (changed == true) {
      widget.changes.bump();
    }
  }

  Future<void> _import() async {
    final cards = _cards ?? const <CorporateCard>[];
    if (cards.isEmpty) {
      showAppToast(context, tr('먼저 카드를 등록하세요.'));
      return;
    }
    final file = await pickSheetFile(title: tr('카드사 이용내역 가져오기'));
    if (file == null || !mounted) return;
    // 어느 카드의 내역인지 — 카드 번호 열로 찾기(여러 카드가 섞인 파일) 또는 카드 하나.
    final cardId = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(tr('어느 카드의 이용내역인가요?')),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, ''),
            child: Text(tr('파일의 카드 번호(끝 4자리)로 찾기')),
          ),
          for (final c in cards)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, c.id),
              child: Text(c.label),
            ),
        ],
      ),
    );
    if (cardId == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final preview = await widget.api.importCardStatement(
        file.bytes,
        cardId: cardId.isEmpty ? null : cardId,
        dryRun: true,
        contentType: file.contentType,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      final apply = await showDialog<bool>(
        context: context,
        builder: (_) =>
            _ImportPreviewDialog(result: preview, fileName: file.name),
      );
      if (apply != true) return;
      await _run(() async {
        final r = await widget.api.importCardStatement(
          file.bytes,
          cardId: cardId.isEmpty ? null : cardId,
          dryRun: false,
          contentType: file.contentType,
        );
        return tr('{n}건을 가져왔습니다(같은 건 {d}건 건너뜀, 승인 취소 짝 {p}).', {
          'n': r.inserted,
          'd': r.duplicates,
          'p': r.paired,
        });
      });
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showAppToast(context, tr('실패: {e}', {'e': e}));
      }
    }
  }

  Future<void> _addManual() async {
    final cards = _cards ?? const <CorporateCard>[];
    if (cards.isEmpty) {
      showAppToast(context, tr('먼저 카드를 등록하세요.'));
      return;
    }
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => _ManualTxDialog(
        api: widget.api,
        cards: cards,
        today: widget.ctx.today,
      ),
    );
    if (added == true) await _load();
  }

  Future<void> _remind() async {
    final ok = await confirmAction(
      context,
      title: tr('미정산 알림'),
      message: tr('{month}에 청구하지 않은 사용 건이 있는 사람에게 알림을 보냅니다(한 시간에 한 번).', {
        'month': monthLabel(_month),
      }),
      okLabel: tr('보내기'),
    );
    if (!ok) return;
    await _run(() async {
      final n = await widget.api.remindCardTransactions(month: _month);
      return tr('{n}명에게 알렸습니다.', {'n': n});
    });
  }

  Future<void> _export() => _run(() async {
    final path = await widget.session.downloadAuthedFile(
      widget.api.cardTransactionsExportPath(_month),
      fileName: '법인카드_$_month.xlsx',
    );
    await openLocalFile(path);
    return null;
  });

  Future<void> _feedKey() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _FeedKeyDialog(
        api: widget.api,
        endpoint:
            '${widget.session.api?.baseUrl ?? ''}/api/v1/corporate-cards/transactions',
      ),
    );
  }

  Future<void> _openTx(CardTransaction t) async {
    final card = (_cards ?? const <CorporateCard>[])
        .where((c) => c.id == t.cardId)
        .firstOrNull;
    final changed = await showCardTransactionDialog(
      context,
      api: widget.api,
      ctx: widget.ctx,
      session: widget.session,
      transaction: t,
      holders: card?.holders ?? const [],
    );
    if (changed) await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return GroupwareEmpty(_error!);
    final cards = _cards;
    final page = _page;
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    if (cards == null || page == null) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final items = _status == null
        ? page.items
        : page.items.where((t) => t.status == _status).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupwareSectionHeader(
          tr('법인카드'),
          trailing: Wrap(
            spacing: 4,
            children: [
              // 지출 관리 도구(finance_tools.dart) — 회계 전표·증빙 조회·카드사/홈택스 연동·영수증 보관·계정 설정.
              PopupMenuButton<String>(
                key: const ValueKey('finance-tools-menu'),
                tooltip: tr('지출 관리 도구'),
                icon: const Icon(Icons.account_balance_outlined),
                onSelected: (v) => switch (v) {
                  'vouchers' => showVoucherExportDialog(
                    context,
                    api: widget.api,
                    session: widget.session,
                    month: _month,
                  ),
                  'taxdocs' => openTaxDocumentsScreen(
                    context,
                    api: widget.api,
                    session: widget.session,
                    ctx: widget.ctx,
                  ),
                  'codef' => showCodefDialog(
                    context,
                    api: widget.api,
                    onSynced: () => widget.changes.bump(),
                  ),
                  'receipts' => showReceiptRetentionDialog(
                    context,
                    api: widget.api,
                  ),
                  'settings' => showFinanceSettingsDialog(
                    context,
                    api: widget.api,
                  ),
                  _ => null,
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'vouchers',
                    child: Text(tr('회계 전표 내보내기')),
                  ),
                  PopupMenuItem(
                    value: 'taxdocs',
                    child: Text(tr('현금영수증·전자세금계산서')),
                  ),
                  PopupMenuItem(value: 'codef', child: Text(tr('카드사·홈택스 연동'))),
                  PopupMenuItem(
                    value: 'receipts',
                    child: Text(tr('영수증 보관 기간')),
                  ),
                  PopupMenuItem(value: 'settings', child: Text(tr('회계 계정 설정'))),
                ],
              ),
              IconButton(
                key: const ValueKey('card-feed-key'),
                tooltip: tr('연동 키'),
                icon: const Icon(Icons.key_outlined),
                onPressed: _feedKey,
              ),
              FilledButton.icon(
                key: const ValueKey('card-add'),
                onPressed: () => _editCard(),
                icon: const Icon(Icons.add_card, size: 18),
                label: Text(tr('카드 등록')),
              ),
            ],
          ),
        ),
        if (cards.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              tr(
                '등록한 카드가 없습니다. 카드(끝 4자리)와 쓰는 사람을 등록한 뒤 카드사 홈페이지에서 받은 이용내역(엑셀·CSV)을 가져오세요.',
              ),
              style: TextStyle(color: hint),
            ),
          ),
        for (final c in cards)
          ListTile(
            key: ValueKey('card-${c.id}'),
            leading: Icon(
              Icons.credit_card,
              color: c.enabled ? theme.colorScheme.primary : hint,
            ),
            title: Text(
              c.enabled ? c.label : tr('{label} (꺼짐)', {'label': c.label}),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.holders.isEmpty
                      ? tr('사용자 없음')
                      : c.holders.map((h) => h.name ?? '').join(', '),
                ),
                if (c.monthlyLimit != null && c.used != null) ...[
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: (c.used! / c.monthlyLimit!).clamp(0, 1).toDouble(),
                    color: c.used! > c.monthlyLimit!
                        ? theme.colorScheme.error
                        : null,
                  ),
                ],
              ],
            ),
            trailing: Text(
              c.monthlyLimit == null
                  ? signedWonText(c.used ?? 0)
                  : '${signedWonText(c.used ?? 0)} / ${signedWonText(c.monthlyLimit!)}',
              style: TextStyle(
                fontSize: 12,
                color: c.monthlyLimit != null && (c.used ?? 0) > c.monthlyLimit!
                    ? theme.colorScheme.error
                    : hint,
              ),
            ),
            onTap: () => _editCard(c),
          ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              MonthStepper(
                month: _month,
                onChanged: (m) {
                  _month = m;
                  _load();
                },
              ),
              DropdownButton<String?>(
                value: _cardId,
                hint: Text(tr('모든 카드')),
                items: [
                  DropdownMenuItem(value: null, child: Text(tr('모든 카드'))),
                  for (final c in cards)
                    DropdownMenuItem(value: c.id, child: Text(c.label)),
                ],
                onChanged: (v) {
                  _cardId = v;
                  _load();
                },
              ),
              OutlinedButton.icon(
                key: const ValueKey('card-import'),
                onPressed: _busy ? null : _import,
                icon: const Icon(Icons.upload_file, size: 18),
                label: Text(tr('이용내역 가져오기')),
              ),
              TextButton.icon(
                onPressed: _busy ? null : _addManual,
                icon: const Icon(Icons.edit_note, size: 18),
                label: Text(tr('직접 넣기')),
              ),
              TextButton.icon(
                key: const ValueKey('card-remind'),
                onPressed: _busy || page.openCount == 0 ? null : _remind,
                icon: const Icon(Icons.notifications_active_outlined, size: 18),
                label: Text(tr('미정산 알림')),
              ),
              TextButton.icon(
                onPressed: _busy ? null : _export,
                icon: const Icon(Icons.download, size: 18),
                label: Text(tr('엑셀')),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              ChoiceChip(
                label: Text(tr('전체 {won}', {'won': signedWonText(page.total)})),
                selected: _status == null,
                onSelected: (_) => setState(() => _status = null),
              ),
              for (final (s, total) in [
                (CardTxStatus.open, page.openTotal),
                (CardTxStatus.claiming, page.claimingTotal),
                (CardTxStatus.settled, page.settledTotal),
                (CardTxStatus.excluded, page.excludedTotal),
              ])
                ChoiceChip(
                  key: ValueKey('card-filter-${s.name}'),
                  label: Text('${s.label} ${signedWonText(total)}'),
                  selected: _status == s,
                  onSelected: (_) => setState(() => _status = s),
                ),
            ],
          ),
        ),
        if (items.isEmpty) GroupwareEmpty(tr('사용 건이 없습니다.')),
        for (final t in items)
          ListTile(
            key: ValueKey('admin-card-tx-${t.id}'),
            title: Row(
              children: [
                Expanded(
                  child: Text(t.merchant, overflow: TextOverflow.ellipsis),
                ),
                Text(
                  signedWonText(t.amount),
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: t.amount < 0 ? theme.colorScheme.error : null,
                  ),
                ),
              ],
            ),
            subtitle: Text(
              [
                cardTxWhen(t),
                '${t.cardName} ${t.last4}',
                t.userName ?? tr('사용자 미정'),
                if (t.receipts.isNotEmpty)
                  tr('영수증 {n}', {'n': t.receipts.length}),
                if (t.mismatches.isNotEmpty) tr('영수증 불일치'),
                if (t.excludedReason != null) t.excludedReason!,
              ].join(' · '),
            ),
            trailing: CardTxStatusChip(t.status),
            onTap: () => _openTx(t),
          ),
      ],
    );
  }
}

/// 카드 등록·고치기 — 이름·카드사·끝 4자리·사용자(이 범위의 정회원 이상)·월 한도·메모·켜기, 지우기.
class _CardEditorDialog extends StatefulWidget {
  final GroupwareApi api;
  final CorporateCard? card;
  const _CardEditorDialog({required this.api, this.card});

  @override
  State<_CardEditorDialog> createState() => _CardEditorDialogState();
}

class _CardEditorDialogState extends State<_CardEditorDialog> {
  late final _name = TextEditingController(text: widget.card?.name);
  late final _last4 = TextEditingController(text: widget.card?.last4);
  late final _limit = TextEditingController(
    text: widget.card?.monthlyLimit?.toString(),
  );
  late final _memo = TextEditingController(text: widget.card?.memo);
  late final _codefOrg = TextEditingController(
    text: widget.card?.codefOrganization,
  );
  late String _issuer = widget.card?.issuer ?? cardIssuers.first;
  late final Set<String> _holders = {...?widget.card?.holderIds};
  late bool _enabled = widget.card?.enabled ?? true;
  List<ApprovalCandidate>? _people;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.api
        .candidates(includeSelf: true)
        .then((p) {
          if (mounted) setState(() => _people = p);
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = e.toString());
        });
  }

  @override
  void dispose() {
    _name.dispose();
    _last4.dispose();
    _limit.dispose();
    _memo.dispose();
    _codefOrg.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.saveCorporateCard(
        id: widget.card?.id,
        name: _name.text.trim(),
        issuer: _issuer,
        last4: _last4.text.trim(),
        holderIds: _holders.toList(),
        monthlyLimit: parseWonInput(_limit.text),
        memo: _memo.text.trim(),
        enabled: _enabled,
        codefOrganization: _codefOrg.text.trim(),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _delete() async {
    final ok = await confirmAction(
      context,
      title: tr('카드 지우기'),
      message: tr(
        '카드와 그 사용 건을 모두 지웁니다. 이미 올린 지출 결재에는 그때의 사용 건이 적혀 있어 그대로 보입니다.',
      ),
      okLabel: tr('지우기'),
      danger: true,
    );
    if (!ok) return;
    try {
      await widget.api.deleteCorporateCard(widget.card!.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = _people;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.card == null ? tr('카드 등록') : tr('카드 고치기')),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('card-name'),
                controller: _name,
                maxLength: 30,
                decoration: InputDecoration(
                  labelText: tr('카드 이름(예: 영업팀 법인카드)'),
                  border: const OutlineInputBorder(),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _issuer,
                      decoration: InputDecoration(
                        labelText: tr('카드사'),
                        border: const OutlineInputBorder(),
                      ),
                      items: [
                        for (final i in cardIssuers)
                          DropdownMenuItem(value: i, child: Text(i)),
                      ],
                      onChanged: (v) => setState(() => _issuer = v ?? _issuer),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 140,
                    child: TextField(
                      key: const ValueKey('card-last4'),
                      controller: _last4,
                      maxLength: 4,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: tr('끝 4자리'),
                        border: const OutlineInputBorder(),
                        counterText: '',
                      ),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Text(
                  tr(
                    '카드 번호는 끝 4자리만 둡니다(전체 번호·유효기간은 받지 않음). 이용내역의 카드 번호 열을 이 4자리로 찾습니다.',
                  ),
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
              ),
              TextField(
                controller: _limit,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: tr('월 한도(원, 선택)'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Text(tr('쓰는 사람'), style: theme.textTheme.titleSmall),
              Text(
                tr('한 명이면 사용 건이 저절로 그 사람 것이 되고, 여럿이면 쓴 사람이 "내가 씀"으로 가져갑니다.'),
                style: TextStyle(fontSize: 12, color: theme.hintColor),
              ),
              const SizedBox(height: 6),
              if (people == null)
                const LinearProgressIndicator()
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final p in people)
                      FilterChip(
                        label: Text(p.name),
                        selected: _holders.contains(p.id),
                        onSelected: (v) => setState(
                          () => v ? _holders.add(p.id) : _holders.remove(p.id),
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _memo,
                maxLength: 200,
                decoration: InputDecoration(
                  labelText: tr('메모'),
                  border: const OutlineInputBorder(),
                ),
              ),
              // 카드사·홈택스 연동(CODEF)에서 이 카드사를 부르는 코드 — 흔한 카드사는 비워 두면 된다.
              TextField(
                key: const ValueKey('card-codef-org'),
                controller: _codefOrg,
                maxLength: 4,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: tr('연동 기관 코드(선택)'),
                  helperText: widget.card?.codefOrg != null
                      ? tr('지금 쓰는 코드: {code}', {'code': widget.card!.codefOrg!})
                      : tr('카드사·홈택스 연동(CODEF)을 쓸 때만 — 비우면 카드사로 정합니다.'),
                  border: const OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              if (widget.card != null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('켜기')),
                  subtitle: Text(tr('끈 카드는 연동으로 사용 건을 받지 않습니다.')),
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                ),
              if (_error != null)
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.card != null)
          TextButton(
            onPressed: _saving ? null : _delete,
            child: Text(tr('지우기')),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('card-save'),
          onPressed: _saving ? null : _save,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}

/// 이용내역 가져오기 미리 보기 — 읽은 건·새 건·같은 건, 기간·합계, 못 읽은 줄.
class _ImportPreviewDialog extends StatelessWidget {
  final CardImportResult result;
  final String fileName;
  const _ImportPreviewDialog({required this.result, required this.fileName});

  @override
  Widget build(BuildContext context) {
    final r = result;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(tr('이용내역 가져오기')),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(fileName, style: TextStyle(color: theme.hintColor)),
              const SizedBox(height: 8),
              Text(
                tr('읽은 사용 건 {read}건 · 새로 들어갈 건 {fresh}건 · 이미 있는 건 {dup}건', {
                  'read': r.read,
                  'fresh': r.fresh,
                  'dup': r.duplicates,
                }),
                key: const ValueKey('card-import-summary'),
              ),
              if (r.from != null)
                Text(
                  tr('기간 {from} ~ {to} · 새 건 합계 {won}', {
                    'from': r.from,
                    'to': r.to ?? '',
                    'won': signedWonText(r.total),
                  }),
                  style: const TextStyle(fontSize: 13),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  tr(
                    '같은 파일을 다시 올려도 같은 건은 한 번만 들어갑니다. 승인 취소는 원래 건과 짝을 지어 함께 뺍니다.',
                  ),
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
              ),
              if (r.errors.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  tr('읽지 못한 줄 {n}개(건너뜀):', {'n': r.errors.length}),
                  style: TextStyle(color: Colors.orange.shade800),
                ),
                for (final e in r.errors.take(30))
                  Text(
                    tr('{line}번째 줄: {message}', {
                      'line': e.line,
                      'message': trServer(e.message),
                    }),
                    style: const TextStyle(fontSize: 12),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('card-import-apply'),
          onPressed: r.fresh == 0 ? null : () => Navigator.pop(context, true),
          child: Text(tr('{n}건 가져오기', {'n': r.fresh})),
        ),
      ],
    );
  }
}

/// 사용 건 직접 넣기 — 카드·날짜·시각·가맹점·금액(취소는 음수)·승인번호.
class _ManualTxDialog extends StatefulWidget {
  final GroupwareApi api;
  final List<CorporateCard> cards;
  final String today;
  const _ManualTxDialog({
    required this.api,
    required this.cards,
    required this.today,
  });

  @override
  State<_ManualTxDialog> createState() => _ManualTxDialogState();
}

class _ManualTxDialogState extends State<_ManualTxDialog> {
  late String _cardId = widget.cards.first.id;
  late final _date = TextEditingController(text: widget.today);
  final _time = TextEditingController();
  final _merchant = TextEditingController();
  final _amount = TextEditingController();
  final _approvalNo = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_date, _time, _merchant, _amount, _approvalNo]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final amount = parseWonInput(_amount.text);
    if (amount == null || amount == 0) {
      setState(() => _error = tr('금액을 원 단위로 넣으세요(취소는 음수).'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.addCardTransaction(
        cardId: _cardId,
        date: _date.text.trim(),
        time: _time.text.trim().isEmpty ? null : _time.text.trim(),
        merchant: _merchant.text.trim(),
        amount: amount,
        approvalNo: _approvalNo.text.trim().isEmpty
            ? null
            : _approvalNo.text.trim(),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    InputDecoration deco(String label) => InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      isDense: true,
    );
    return AlertDialog(
      title: Text(tr('사용 건 직접 넣기')),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _cardId,
              decoration: deco(tr('카드')),
              items: [
                for (final c in widget.cards)
                  DropdownMenuItem(value: c.id, child: Text(c.label)),
              ],
              onChanged: (v) => setState(() => _cardId = v ?? _cardId),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _date,
                    decoration: deco(tr('날짜(YYYY-MM-DD)')),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _time,
                    decoration: deco(tr('시각(HH:MM)')),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _merchant,
              maxLength: 100,
              decoration: deco(tr('가맹점')),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _amount,
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                    ),
                    decoration: deco(tr('금액(원)')),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _approvalNo,
                    decoration: deco(tr('승인번호(선택)')),
                  ),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('취소')),
        ),
        FilledButton(onPressed: _saving ? null : _save, child: Text(tr('넣기'))),
      ],
    );
  }
}

/// 연동 키 — 카드사 이용내역 연동 서비스·회계 프로그램·스크립트가 사용 건을 밀어 넣는 열쇠(범위마다 하나). 새로 만들면 예전 키는 바로 못 쓰고,
/// 키 값은 만들 때 한 번만 보인다.
class _FeedKeyDialog extends StatefulWidget {
  final GroupwareApi api;
  final String endpoint;
  const _FeedKeyDialog({required this.api, required this.endpoint});

  @override
  State<_FeedKeyDialog> createState() => _FeedKeyDialogState();
}

class _FeedKeyDialogState extends State<_FeedKeyDialog> {
  CardFeedKey? _key;
  String? _token;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.api
        .cardFeedKey()
        .then((k) {
          if (mounted) setState(() => _key = k);
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = e.toString());
        });
  }

  Future<void> _rotate() async {
    if (_key?.exists == true) {
      final ok = await confirmAction(
        context,
        title: tr('연동 키 새로 만들기'),
        message: tr('지금 키를 쓰는 연동은 바로 멈춥니다. 새 키로 바꿔 넣어야 합니다.'),
        okLabel: tr('새로 만들기'),
      );
      if (!ok) return;
    }
    setState(() => _busy = true);
    try {
      final k = await widget.api.rotateCardFeedKey();
      if (mounted) {
        setState(() {
          _key = k;
          _token = k.token;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    setState(() => _busy = true);
    try {
      await widget.api.deleteCardFeedKey();
      if (mounted) {
        setState(() {
          _key = const CardFeedKey(exists: false);
          _token = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = _key;
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    const sample =
        '{ "transactions": [ { "cardLast4": "5678", "usedAt": "2026-10-18T12:30:00+09:00", "merchant": "GS25", "amount": 5600, "approvalNo": "30012345" } ] }';
    return AlertDialog(
      title: Text(tr('법인카드 연동 키')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tr(
                  '카드사 이용내역 연동 서비스(스크래핑·오픈뱅킹 중계)나 회계 프로그램이 사용 건을 이 서버로 보내게 할 때 씁니다. 같은 건은 한 번만 들어가고, 쓰는 사람이 한 명인 카드는 그 사람 것으로 들어갑니다.',
                ),
                style: TextStyle(fontSize: 13, color: hint),
              ),
              const SizedBox(height: 12),
              if (k == null && _error == null) const LinearProgressIndicator(),
              if (k != null)
                Text(
                  k.exists
                      ? tr('지금 키: …{hint} · {by} {at}에 만듦 · 마지막 사용 {used}', {
                          'hint': k.hint ?? '',
                          'by': k.createdByName ?? '',
                          'at': k.createdAt == null
                              ? ''
                              : formatDateTime(k.createdAt!),
                          'used': k.lastUsedAt == null
                              ? tr('없음')
                              : formatDateTime(k.lastUsedAt!),
                        })
                      : tr('연동 키가 없습니다.'),
                  key: const ValueKey('card-feed-status'),
                ),
              if (_token != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          _token!,
                          key: const ValueKey('card-feed-token'),
                        ),
                      ),
                      IconButton(
                        tooltip: tr('복사'),
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: _token!));
                          if (context.mounted) {
                            showAppToast(context, tr('복사했습니다.'));
                          }
                        },
                      ),
                    ],
                  ),
                ),
                Text(
                  tr('이 키는 지금 한 번만 보입니다. 안전한 곳에 넣어 두세요.'),
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
                ),
              ],
              const SizedBox(height: 12),
              Text(tr('보내는 방법'), style: theme.textTheme.titleSmall),
              SelectableText(
                'POST ${widget.endpoint}\nAuthorization: Bearer ttc_…\nContent-Type: application/json\n\n$sample',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
              Text(
                tr(
                  '한 번에 300건까지, 키마다 1분에 30번. 취소는 금액을 음수로(또는 "canceled": true). 끝 4자리가 같은 카드가 여럿이면 "issuer"(카드사)나 "cardId"를 함께 보냅니다.',
                ),
                style: TextStyle(fontSize: 12, color: hint),
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
        if (k?.exists == true)
          TextButton(
            onPressed: _busy ? null : _delete,
            child: Text(tr('키 지우기')),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('닫기')),
        ),
        FilledButton(
          key: const ValueKey('card-feed-rotate'),
          onPressed: _busy ? null : _rotate,
          child: Text(k?.exists == true ? tr('새 키 만들기') : tr('키 만들기')),
        ),
      ],
    );
  }
}
