import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../models/groupware_finance.dart';
import '../../models/groupware_finance_tools.dart';
import '../../services/download_storage.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../services/time_format.dart';
import '../../widgets/app_toast.dart';
import 'finance_widgets.dart';
import 'groupware_screen.dart';
import '../../l10n/tr.dart';

/// 지출 관리 도구(결재·근태 관리자 — 법인카드 관리의 도구 메뉴) — 회계 전표 내보내기, 현금영수증·전자세금계산서(홈택스 엑셀 가져오기·조회),
/// 카드사·홈택스 직접 연동(CODEF), 영수증 원본 보관 기간, 회계 계정 설정. 서버는 server/src/financeTools.js.

Future<void> _download(
  BuildContext context,
  Session session,
  String path,
  String fileName,
) async {
  try {
    final local = await session.downloadAuthedFile(
      path,
      fileName: fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_'),
    );
    await openLocalFile(local);
  } catch (e) {
    if (context.mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
  }
}

String _bytesText(int bytes) => bytes >= 1024 * 1024
    ? tr('{n}MB', {'n': (bytes / 1024 / 1024).toStringAsFixed(1)})
    : tr('{n}KB', {'n': (bytes / 1024).ceil()});

// ── 회계 전표 ──

/// 회계 전표 내보내기 — 달·포함할 것(법인카드·지출 결재·매입 증빙)을 골라 엑셀로(계정·모양은 회계 계정 설정).
Future<void> showVoucherExportDialog(
  BuildContext context, {
  required GroupwareApi api,
  required Session session,
  required String month,
}) => showDialog<void>(
  context: context,
  builder: (_) => _VoucherDialog(api: api, session: session, month: month),
);

class _VoucherDialog extends StatefulWidget {
  final GroupwareApi api;
  final Session session;
  final String month;
  const _VoucherDialog({
    required this.api,
    required this.session,
    required this.month,
  });

  @override
  State<_VoucherDialog> createState() => _VoucherDialogState();
}

class _VoucherDialogState extends State<_VoucherDialog> {
  late String _month = widget.month;
  final Set<String> _sources = {'cards', 'expenses'};
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    Widget source(String key, String label, String help) => CheckboxListTile(
      key: ValueKey('voucher-source-$key'),
      contentPadding: EdgeInsets.zero,
      value: _sources.contains(key),
      title: Text(label),
      subtitle: Text(help, style: TextStyle(fontSize: 12, color: hint)),
      onChanged: (v) =>
          setState(() => v == true ? _sources.add(key) : _sources.remove(key)),
    );
    return AlertDialog(
      title: Text(tr('회계 전표 내보내기')),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: MonthStepper(
                month: _month,
                onChanged: (m) => setState(() => _month = m),
              ),
            ),
            source(
              'cards',
              tr('법인카드 사용'),
              tr('차변 분류의 계정 / 대변 미지급금(카드사) — 제외한 건은 빼고, 승인 취소는 반대로'),
            ),
            source(
              'expenses',
              tr('지출 결재(직원이 먼저 쓴 돈)'),
              tr('승인된 것 — 차변 분류의 계정 / 대변 미지급금(쓴 사람)'),
            ),
            source(
              'taxdocs',
              tr('매입 증빙(현금영수증·세금계산서)'),
              tr('위와 겹칠 수 있으니 따로 처리하는 증빙만 넣으세요.'),
            ),
            const SizedBox(height: 8),
            Text(
              tr(
                '더존 등 회계 프로그램의 일반전표 엑셀 올리기에 맞춘 모양입니다. 계정과 모양(일반·더존)은 도구 메뉴의 "회계 계정 설정"에서 바꿉니다.',
              ),
              style: TextStyle(fontSize: 12, color: hint),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('닫기')),
        ),
        FilledButton.icon(
          key: const ValueKey('voucher-download'),
          onPressed: _busy || _sources.isEmpty
              ? null
              : () async {
                  setState(() => _busy = true);
                  await _download(
                    context,
                    widget.session,
                    widget.api.financeVouchersPath(_month, _sources),
                    '회계전표_$_month.xlsx',
                  );
                  if (mounted) setState(() => _busy = false);
                },
          icon: const Icon(Icons.download, size: 18),
          label: Text(tr('엑셀로 받기')),
        ),
      ],
    );
  }
}

// ── 회계 계정 설정 ──

const _namedLabels = {
  'fallback': '분류 없음·그 밖',
  'cardPayable': '법인카드 대변(카드 대금)',
  'expensePayable': '지출 결재·증빙 대변',
  'salary': '급여(차변)',
  'withholding': '급여 공제(예수금)',
  'payment': '급여 지급(대변)',
};

Future<void> showFinanceSettingsDialog(
  BuildContext context, {
  required GroupwareApi api,
}) async {
  FinanceSettings settings;
  try {
    settings = await api.financeSettings();
  } catch (e) {
    if (context.mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _AccountsDialog(api: api, settings: settings),
  );
}

class _AccountRow {
  final TextEditingController code;
  final TextEditingController name;
  _AccountRow(LedgerAccount a)
    : code = TextEditingController(text: a.code),
      name = TextEditingController(text: a.name);
  LedgerAccount? get value =>
      code.text.trim().isEmpty && name.text.trim().isEmpty
      ? null
      : LedgerAccount(code.text.trim(), name.text.trim());
  void dispose() {
    code.dispose();
    name.dispose();
  }
}

class _AccountsDialog extends StatefulWidget {
  final GroupwareApi api;
  final FinanceSettings settings;
  const _AccountsDialog({required this.api, required this.settings});

  @override
  State<_AccountsDialog> createState() => _AccountsDialogState();
}

class _AccountsDialogState extends State<_AccountsDialog> {
  late final Map<String, _AccountRow> _categories = {
    for (final c in widget.settings.categories)
      c: _AccountRow(
        widget.settings.accounts.categories[c] ??
            widget.settings.accounts.named['fallback'] ??
            const LedgerAccount('', ''),
      ),
  };
  late final Map<String, _AccountRow> _named = {
    for (final k in LedgerAccounts.namedKeys)
      k: _AccountRow(
        widget.settings.accounts.named[k] ?? const LedgerAccount('', ''),
      ),
  };
  late String _format = widget.settings.voucherFormat;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final r in [..._categories.values, ..._named.values]) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.saveFinanceSettings(
        voucherFormat: _format,
        accounts: LedgerAccounts(
          categories: {
            for (final e in _categories.entries)
              if (e.value.value != null) e.key: e.value.value!,
          },
          named: {
            for (final e in _named.entries)
              if (e.value.value != null) e.key: e.value.value!,
          },
        ),
      );
      if (mounted) {
        Navigator.pop(context);
        showAppToast(context, tr('회계 계정 설정을 저장했습니다.'));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  Widget _row(String label, _AccountRow row, String keyName) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        Expanded(flex: 3, child: Text(label)),
        SizedBox(
          width: 72,
          child: TextField(
            key: ValueKey('account-code-$keyName'),
            controller: row.code,
            maxLength: 10,
            decoration: InputDecoration(
              isDense: true,
              counterText: '',
              hintText: tr('코드'),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: TextField(
            controller: row.name,
            maxLength: 30,
            decoration: InputDecoration(
              isDense: true,
              counterText: '',
              hintText: tr('계정과목'),
            ),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(tr('회계 계정 설정')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tr(
                  '기본은 더존 기본 계정과목표에 흔한 번호입니다. 회사 계정과목표에 맞게 고치세요(부가세 매입세액은 나누지 않습니다).',
                ),
                style: TextStyle(fontSize: 12, color: theme.hintColor),
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'generic', label: Text(tr('일반 모양'))),
                  ButtonSegment(value: 'douzone', label: Text(tr('더존 모양'))),
                ],
                selected: {_format},
                onSelectionChanged: (v) => setState(() => _format = v.first),
              ),
              const SizedBox(height: 12),
              Text(tr('지출 분류 → 차변 계정'), style: theme.textTheme.titleSmall),
              for (final e in _categories.entries) _row(e.key, e.value, e.key),
              const Divider(height: 20),
              Text(tr('대변·급여 계정'), style: theme.textTheme.titleSmall),
              for (final e in _named.entries)
                _row(tr(_namedLabels[e.key] ?? e.key), e.value, e.key),
              if (_error != null)
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('accounts-save'),
          onPressed: _saving ? null : _save,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}

// ── 영수증 보관 ──

Future<void> showReceiptRetentionDialog(
  BuildContext context, {
  required GroupwareApi api,
}) => showDialog<void>(
  context: context,
  builder: (_) => _RetentionDialog(api: api),
);

class _RetentionDialog extends StatefulWidget {
  final GroupwareApi api;
  const _RetentionDialog({required this.api});

  @override
  State<_RetentionDialog> createState() => _RetentionDialogState();
}

class _RetentionDialogState extends State<_RetentionDialog> {
  ReceiptRetentionSummary? _summary;
  int _years = 5;
  String _filing = 'corporate';
  bool _purge = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await widget.api.receiptRetention();
      if (!mounted) return;
      setState(() {
        _summary = s;
        _years = s.retentionYears;
        _filing = s.filing;
        _purge = s.purge;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await widget.api.saveFinanceSettings(
        receiptRetentionYears: _years,
        receiptFiling: _filing,
        receiptPurge: _purge,
      );
      await _load();
      if (mounted) showAppToast(context, tr('보관 기간을 저장했습니다.'));
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _purgeNow() async {
    final s = _summary;
    if (s == null) return;
    final ok = await confirmAction(
      context,
      title: tr('보관 기한 지난 영수증 지우기'),
      message: tr(
        '보관 기한이 지난 영수증 원본 {n}개를 지웁니다. 되돌릴 수 없습니다(대화 등 다른 곳에서도 쓰는 파일은 둡니다). 결재 문서에는 "보관 기한이 지나 지움"으로 남습니다.',
        {'n': s.expired},
      ),
      okLabel: tr('지우기'),
      danger: true,
    );
    if (!ok) return;
    setState(() => _busy = true);
    try {
      final n = await widget.api.purgeExpiredReceipts();
      if (mounted) showAppToast(context, tr('{n}개를 지웠습니다.', {'n': n}));
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final s = _summary;
    return AlertDialog(
      title: Text(tr('영수증 원본 보관 기간')),
      content: SizedBox(
        width: 480,
        child: s == null
            ? (_error != null
                  ? Text(_error!)
                  : const Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr(
                        '장부·증빙은 법정신고기한이 지난 날부터 5년 보관합니다(국세기본법 제85조의3). 영수증의 보관 기한은 쓴 해의 다음 해 신고기한부터 셉니다.',
                      ),
                      style: TextStyle(fontSize: 12, color: hint),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        DropdownButton<int>(
                          key: const ValueKey('retention-years'),
                          value: _years,
                          items: [
                            for (final y in const [5, 7, 10, 0])
                              DropdownMenuItem(
                                value: y,
                                child: Text(
                                  y == 0 ? tr('기한 없이 둠') : tr('{y}년', {'y': y}),
                                ),
                              ),
                          ],
                          onChanged: (v) =>
                              setState(() => _years = v ?? _years),
                        ),
                        DropdownButton<String>(
                          value: _filing,
                          items: [
                            DropdownMenuItem(
                              value: 'corporate',
                              child: Text(tr('법인(다음 해 3월 31일)')),
                            ),
                            DropdownMenuItem(
                              value: 'individual',
                              child: Text(tr('개인사업자(다음 해 5월 31일)')),
                            ),
                          ],
                          onChanged: (v) =>
                              setState(() => _filing = v ?? _filing),
                        ),
                      ],
                    ),
                    SwitchListTile(
                      key: const ValueKey('retention-purge'),
                      contentPadding: EdgeInsets.zero,
                      value: _purge,
                      onChanged: _years == 0
                          ? null
                          : (v) => setState(() => _purge = v),
                      title: Text(tr('기한이 지나면 원본을 지우기')),
                      subtitle: Text(
                        tr('하루에 한 번 지웁니다. 끄면 기한만 보여 주고 지우지 않습니다.'),
                      ),
                    ),
                    const Divider(),
                    Text(
                      tr('영수증 {n}개 · {size} · 기한 지남 {e}개 · 지운 것 {p}개', {
                        'n': s.count,
                        'size': _bytesText(s.bytes),
                        'e': s.expired,
                        'p': s.purged,
                      }),
                      key: const ValueKey('retention-summary'),
                    ),
                    for (final y in s.years)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr('{y}년 사용분', {'y': y.year})),
                        subtitle: Text(
                          y.keepUntil == null
                              ? tr('기한 없음')
                              : tr('{date}까지 보관', {'date': y.keepUntil!}),
                        ),
                        trailing: Text(
                          [
                            tr('{n}개', {'n': y.count}),
                            _bytesText(y.bytes),
                            if (y.expired > 0)
                              tr('기한 지남 {n}', {'n': y.expired}),
                          ].join(' · '),
                          style: TextStyle(
                            fontSize: 12,
                            color: y.expired > 0
                                ? theme.colorScheme.error
                                : hint,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        if (s != null && s.expired > 0 && s.retentionYears > 0)
          TextButton(
            key: const ValueKey('retention-purge-now'),
            onPressed: _busy ? null : _purgeNow,
            child: Text(tr('지금 지우기')),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('닫기')),
        ),
        FilledButton(
          key: const ValueKey('retention-save'),
          onPressed: _busy || s == null ? null : _save,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}

// ── 카드사·홈택스 연동(CODEF) ──

Future<void> showCodefDialog(
  BuildContext context, {
  required GroupwareApi api,
  VoidCallback? onSynced,
}) async {
  FinanceSettings settings;
  try {
    settings = await api.financeSettings();
  } catch (e) {
    if (context.mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) =>
        _CodefDialog(api: api, settings: settings, onSynced: onSynced),
  );
}

class _CodefDialog extends StatefulWidget {
  final GroupwareApi api;
  final FinanceSettings settings;
  final VoidCallback? onSynced;
  const _CodefDialog({
    required this.api,
    required this.settings,
    this.onSynced,
  });

  @override
  State<_CodefDialog> createState() => _CodefDialogState();
}

class _CodefDialogState extends State<_CodefDialog> {
  late CodefStatus _status = widget.settings.codef;
  bool _busy = false;
  String? _message;

  Future<void> _act(Future<FinanceSettings?> Function() action) async {
    setState(() => _busy = true);
    try {
      final s = await action();
      if (s != null && mounted) setState(() => _status = s.codef);
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connectCard() async {
    final orgs = _status.organizations;
    final picked = await showDialog<({String org, String id, String pw})>(
      context: context,
      builder: (_) => _CodefLoginDialog(organizations: orgs),
    );
    if (picked == null) return;
    await _act(
      () => widget.api.codefConnect(
        target: 'card',
        organization: picked.org,
        loginId: picked.id,
        password: picked.pw,
      ),
    );
  }

  Future<void> _connectId(String target) async {
    final id = await askText(
      context,
      title: target == 'card' ? tr('카드사 connectedId') : tr('홈택스 connectedId'),
      message: tr('CODEF에서 계정을 등록하고 받은 connectedId를 넣으세요.'),
      label: 'connectedId',
      maxLength: 100,
    );
    if (id == null) return;
    await _act(() => widget.api.codefConnect(target: target, connectedId: id));
  }

  /// 연동 점검 — 계약한 상품 주소로 한 번 불러 응답 코드·칸 이름을 본다(넣지 않음).
  Future<void> _probe(String target) async {
    setState(() => _busy = true);
    CodefProbeResult? result;
    try {
      result = await widget.api.codefProbe(target: target);
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (result == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => CodefProbeView(
        result: result!,
        fieldOverrides: _status.fieldOverrides,
      ),
    );
  }

  Future<void> _sync() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final r = await widget.api.codefSync();
      final cards = (r['cards'] as Map?)?.cast<String, dynamic>();
      final hometax = (r['hometax'] as Map?)?.cast<String, dynamic>();
      final errors = [
        ...((cards?['errors'] as List?) ?? const []),
        ...((hometax?['errors'] as List?) ?? const []),
      ];
      setState(() {
        _message = [
          if (cards != null)
            tr('카드 사용 건 {n}건 새로(같은 건 {d}건)', {
              'n': cards['inserted'] ?? 0,
              'd': cards['duplicates'] ?? 0,
            }),
          if (hometax != null)
            tr('증빙 {n}건 새로', {'n': hometax['inserted'] ?? 0}),
          if (errors.isNotEmpty)
            tr('오류 {n}건: {first}', {
              'n': errors.length,
              'first': (errors.first as Map?)?['error'] ?? '',
            }),
        ].join(' · ');
        final settings = r['settings'];
        if (settings is Map) {
          _status = FinanceSettings.fromJson(
            settings.cast<String, dynamic>(),
          ).codef;
        }
      });
      widget.onSynced?.call();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final s = _status;
    return AlertDialog(
      title: Text(tr('카드사·홈택스 연동')),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tr(
                  'CODEF(코드에프) 중계로 법인카드 승인내역과 홈택스 현금영수증·전자세금계산서를 가져옵니다. CODEF와 계약한 뒤 서버 관리자가 server/.env에 키를 넣어야 켜집니다. 계약 전에는 카드사 엑셀 가져오기와 연동 키를 쓰세요.',
                ),
                style: TextStyle(fontSize: 12, color: hint),
              ),
              const SizedBox(height: 12),
              if (!s.enabled)
                ListTile(
                  key: const ValueKey('codef-disabled'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.power_off_outlined),
                  title: Text(tr('연동이 꺼져 있습니다')),
                  subtitle: Text(
                    tr(
                      'server/.env에 CODEF_CLIENT_ID·CODEF_CLIENT_SECRET(계정 연결은 CODEF_PUBLIC_KEY도)을 넣고 서버를 다시 시작하세요.',
                    ),
                  ),
                )
              else ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.credit_card,
                    color: s.cardConnected ? Colors.green.shade700 : hint,
                  ),
                  title: Text(
                    s.cardConnected ? tr('카드사 계정 연결됨') : tr('카드사 계정 없음'),
                  ),
                  subtitle: Text(
                    tr('카드사마다 기업 회원 아이디로 한 번씩 연결합니다(아이디·비밀번호는 이 서버에 남기지 않음).'),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (s.canConnect)
                      OutlinedButton(
                        key: const ValueKey('codef-connect-card'),
                        onPressed: _busy ? null : _connectCard,
                        child: Text(tr('카드사 계정 연결')),
                      ),
                    OutlinedButton(
                      onPressed: _busy ? null : () => _connectId('card'),
                      child: Text(tr('connectedId 넣기')),
                    ),
                    if (s.cardConnected)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _act(
                                () => widget.api.codefDisconnect('card'),
                              ),
                        child: Text(tr('끊기')),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.receipt_outlined,
                    color: s.hometaxConnected ? Colors.green.shade700 : hint,
                  ),
                  title: Text(
                    s.hometaxConnected ? tr('홈택스 연결됨') : tr('홈택스 없음'),
                  ),
                  subtitle: Text(
                    s.hometaxKinds.isEmpty
                        ? tr(
                            'server/.env에 홈택스 상품 주소(CODEF_CASH_RECEIPT_PATH·CODEF_TAX_INVOICE_PATH)가 없어 가져오지 않습니다.',
                          )
                        : tr('인증서 로그인이 흔해 CODEF에서 만든 connectedId를 넣습니다.'),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: _busy ? null : () => _connectId('hometax'),
                      child: Text(tr('홈택스 connectedId 넣기')),
                    ),
                    if (s.hometaxConnected)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _act(
                                () => widget.api.codefDisconnect('hometax'),
                              ),
                        child: Text(tr('끊기')),
                      ),
                  ],
                ),
                SwitchListTile(
                  key: const ValueKey('codef-auto'),
                  contentPadding: EdgeInsets.zero,
                  value: s.autoSync,
                  onChanged: !s.cardConnected || _busy
                      ? null
                      : (v) => _act(
                          () =>
                              widget.api.saveFinanceSettings(codefAutoSync: v),
                        ),
                  title: Text(tr('매일 자동으로 가져오기')),
                  subtitle: Text(tr('하루에 한 번 지난 3일치를 가져옵니다(같은 건은 건너뜀).')),
                ),
                if (s.lastSyncAt != null)
                  Text(
                    tr('마지막으로 가져온 때: {at}', {
                      'at': formatDateTime(s.lastSyncAt!),
                    }),
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                if (_message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_message!, key: const ValueKey('codef-result')),
                  ),
                const Divider(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        tr(
                          '연동 점검 — 계약한 상품 주소로 한 번 불러 응답 코드와 응답 칸 이름을 봅니다(아무것도 넣지 않음). 실제 계약 계정으로 처음 쓸 때 확인하세요.',
                        ),
                        style: TextStyle(fontSize: 12, color: hint),
                      ),
                    ),
                    PopupMenuButton<String>(
                      key: const ValueKey('codef-probe'),
                      enabled:
                          !_busy && (s.cardConnected || s.hometaxConnected),
                      tooltip: tr('연동 점검'),
                      icon: const Icon(Icons.fact_check_outlined),
                      onSelected: _probe,
                      itemBuilder: (_) => [
                        if (s.cardConnected)
                          PopupMenuItem(
                            value: 'card',
                            child: Text(tr('카드 승인내역')),
                          ),
                        if (s.hometaxConnected) ...[
                          PopupMenuItem(
                            value: 'cash_receipt',
                            child: Text(tr('홈택스 현금영수증')),
                          ),
                          PopupMenuItem(
                            value: 'tax_invoice',
                            child: Text(tr('홈택스 전자세금계산서')),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('닫기')),
        ),
        if (s.enabled)
          FilledButton.icon(
            key: const ValueKey('codef-sync'),
            onPressed: _busy || (!s.cardConnected && !s.hometaxConnected)
                ? null
                : _sync,
            icon: const Icon(Icons.sync, size: 18),
            label: Text(tr('지난 7일 가져오기')),
          ),
      ],
    );
  }
}

/// CODEF 응답 칸 이름(server taxDocRules.js CODEF_CARD_FIELDS·CODEF_TAX_DOC_FIELDS의 키).
String codefFieldLabel(String key) => switch (key) {
  'usedDate' => tr('사용 날짜'),
  'usedTime' => tr('사용 시각'),
  'amount' => tr('금액'),
  'cancel' => tr('취소 여부'),
  'cancelAmount' => tr('취소 금액'),
  'cardNo' => tr('카드 번호'),
  'merchant' => tr('가맹점'),
  'merchantBizNo' => tr('가맹점 사업자번호'),
  'approvalNo' => tr('승인번호'),
  'date' => tr('날짜'),
  'time' => tr('시각'),
  'supply' => tr('공급가액'),
  'tax' => tr('세액'),
  'total' => tr('합계'),
  'status' => tr('거래 구분'),
  'supplierName' => tr('공급자'),
  'supplierBizNo' => tr('공급자 사업자번호'),
  'buyerName' => tr('공급받는자'),
  'buyerBizNo' => tr('공급받는자 사업자번호'),
  'itemName' => tr('품목'),
  _ => key,
};

/// 연동 점검 결과 — 상품 주소·응답 코드·줄 수, 칸마다 읽은 이름(못 읽은 꼭 필요한 칸은 빨갛게), 응답에 있던 칸 이름들(값은 없음).
class CodefProbeView extends StatelessWidget {
  final CodefProbeResult result;
  final bool fieldOverrides;
  const CodefProbeView({
    super.key,
    required this.result,
    this.fieldOverrides = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final error = theme.colorScheme.error;
    final r = result;
    final mapKey = r.target == 'card' ? 'card' : 'taxDoc';
    final unmatched = [
      for (final e in r.fields.entries)
        if (e.value.matched.isEmpty && r.count > 0) e.key,
    ];
    return AlertDialog(
      title: Text(switch (r.target) {
        'card' => tr('연동 점검 — 카드 승인내역'),
        'cash_receipt' => tr('연동 점검 — 홈택스 현금영수증'),
        _ => tr('연동 점검 — 홈택스 전자세금계산서'),
      }),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText(
                [
                  tr('상품 주소 {path}', {'path': r.path ?? tr('(없음)')}),
                  if (r.organization != null)
                    tr('기관 코드 {org}', {'org': r.organization}),
                  tr('기간 {from} ~ {to}', {'from': r.from, 'to': r.to}),
                ].join('\n'),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              Text(
                r.ok
                    ? tr('응답 {code} · {n}줄 · 읽은 줄 {p} · 건너뛴 줄(승인 거절) {s}', {
                        'code': r.code ?? '',
                        'n': r.count,
                        'p': r.parsed,
                        's': r.skipped,
                      })
                    : tr('실패 {code} — {message}', {
                        'code': r.code ?? '',
                        'message': r.message ?? '',
                      }),
                key: const ValueKey('codef-probe-result'),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: r.ok ? null : error,
                ),
              ),
              if (!r.ok)
                Text(
                  tr(
                    '상품 주소가 계약한 상품과 다르면 server/.env의 CODEF_CARD_APPROVAL_PATH·CODEF_CASH_RECEIPT_PATH·CODEF_TAX_INVOICE_PATH를 고치고 서버를 다시 시작하세요.',
                  ),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              for (final e in r.errors)
                Text(
                  tr('못 읽은 줄 {n}개: {error}', {'n': e.count, 'error': e.error}),
                  style: TextStyle(fontSize: 12, color: error),
                ),
              if (r.ok && r.count == 0)
                Text(
                  tr('이 기간에 응답 줄이 없어 칸 이름을 볼 수 없습니다. 쓴 내역이 있는 기간으로 다시 해 보세요.'),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              if (r.ok && r.count > 0) ...[
                const Divider(height: 20),
                for (final e in r.fields.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 150,
                          child: Text(
                            codefFieldLabel(e.key) +
                                (e.value.required ? ' *' : ''),
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            e.value.matched.isEmpty
                                ? tr('못 찾음 (본 이름: {names})', {
                                    'names': e.value.names.join(', '),
                                  })
                                : [
                                    for (final m in e.value.matched.entries)
                                      tr('{name} ({n}줄)', {
                                        'name': m.key,
                                        'n': m.value,
                                      }),
                                    if (e.value.missing > 0)
                                      tr('빈 줄 {n}', {'n': e.value.missing}),
                                  ].join(' · '),
                            key: ValueKey('codef-probe-field-${e.key}'),
                            style: TextStyle(
                              fontSize: 13,
                              color: e.value.matched.isEmpty
                                  ? (e.value.required ? error : hint)
                                  : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  tr('응답에 있던 칸 이름(값은 보이지 않습니다)'),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
                SelectableText(
                  r.keys.join(', '),
                  key: const ValueKey('codef-probe-keys'),
                  style: const TextStyle(fontSize: 12),
                ),
                if (unmatched.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    tr(
                      '못 찾은 칸이 응답에 다른 이름으로 있으면 server/.env에 아래처럼 넣고 서버를 다시 시작하세요(* 칸을 못 읽으면 그 줄을 넣지 못합니다).',
                    ),
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                  SelectableText(
                    'CODEF_FIELD_MAP={"$mapKey":{${unmatched.map((k) => '"$k":"…"').join(',')}}}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
                if (fieldOverrides)
                  Text(
                    tr('server/.env의 CODEF_FIELD_MAP으로 더한 이름을 먼저 봅니다.'),
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
              ],
            ],
          ),
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

/// 카드사 기업 회원 로그인(CODEF로 보내 connectedId를 받는다).
class _CodefLoginDialog extends StatefulWidget {
  final Map<String, String> organizations;
  const _CodefLoginDialog({required this.organizations});

  @override
  State<_CodefLoginDialog> createState() => _CodefLoginDialogState();
}

class _CodefLoginDialogState extends State<_CodefLoginDialog> {
  late String? _org = widget.organizations.values.firstOrNull;
  final _id = TextEditingController();
  final _pw = TextEditingController();

  @override
  void dispose() {
    _id.dispose();
    _pw.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('카드사 계정 연결')),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _org,
            decoration: InputDecoration(
              labelText: tr('카드사'),
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final e in widget.organizations.entries)
                DropdownMenuItem(value: e.value, child: Text(e.key)),
            ],
            onChanged: (v) => setState(() => _org = v),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _id,
            decoration: InputDecoration(
              labelText: tr('기업 회원 아이디'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _pw,
            obscureText: true,
            decoration: InputDecoration(
              labelText: tr('비밀번호'),
              border: const OutlineInputBorder(),
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
      FilledButton(
        onPressed: () {
          if (_org == null || _id.text.trim().isEmpty || _pw.text.isEmpty) {
            return;
          }
          Navigator.pop(context, (
            org: _org!,
            id: _id.text.trim(),
            pw: _pw.text,
          ));
        },
        child: Text(tr('연결')),
      ),
    ],
  );
}

// ── 현금영수증·전자세금계산서 ──

Future<void> openTaxDocumentsScreen(
  BuildContext context, {
  required GroupwareApi api,
  required Session session,
  required GroupwareContext ctx,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => TaxDocumentsScreen(api: api, session: session, ctx: ctx),
  ),
);

/// 현금영수증·전자세금계산서 — 달마다 보고(종류 거르기·합계), 홈택스에서 받은 목록 엑셀을 올려 넣고, 분류(전표 계정)·메모를 붙인다.
class TaxDocumentsScreen extends StatefulWidget {
  final GroupwareApi api;
  final Session session;
  final GroupwareContext ctx;
  const TaxDocumentsScreen({
    super.key,
    required this.api,
    required this.session,
    required this.ctx,
  });

  @override
  State<TaxDocumentsScreen> createState() => _TaxDocumentsScreenState();
}

class _TaxDocumentsScreenState extends State<TaxDocumentsScreen> {
  late String _month = widget.ctx.today.substring(0, 7);
  String? _kind;
  TaxDocumentPage? _page;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await widget.api.taxDocuments(month: _month, kind: _kind);
      if (mounted) {
        setState(() {
          _page = p;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _import() async {
    final file = await pickSheetFile(title: tr('홈택스 목록 가져오기'));
    if (file == null || !mounted) return;
    final direction = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(tr('매입 목록인가요, 매출 목록인가요?')),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, 'purchase'),
            child: Text(tr('매입(우리가 받은 증빙)')),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, 'sale'),
            child: Text(tr('매출(우리가 발급한 증빙)')),
          ),
        ],
      ),
    );
    if (direction == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final preview = await widget.api.importTaxDocuments(
        file.bytes,
        direction: direction,
        dryRun: true,
        contentType: file.contentType,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      final ok = await confirmAction(
        context,
        title: tr('증빙 가져오기'),
        message: [
          tr('{file} — {kind}', {
            'file': file.name,
            'kind': preview.kind == 'tax_invoice' ? tr('전자세금계산서') : tr('현금영수증'),
          }),
          tr('읽은 {r}건 · 새로 {f}건 · 이미 있는 {d}건', {
            'r': preview.read,
            'f': preview.fresh,
            'd': preview.duplicates,
          }),
          if (preview.from != null)
            tr('{from} ~ {to} · 합계 {won}', {
              'from': preview.from!,
              'to': preview.to ?? '',
              'won': signedWonText(preview.total),
            }),
          if (preview.errors.isNotEmpty)
            tr('못 읽은 줄 {n}개 — {first}', {
              'n': preview.errors.length,
              'first':
                  '${preview.errors.first.line}: ${preview.errors.first.message}',
            }),
        ].join('\n'),
        okLabel: tr('가져오기'),
      );
      if (!ok || preview.fresh == 0) return;
      setState(() => _busy = true);
      final r = await widget.api.importTaxDocuments(
        file.bytes,
        kind: preview.kind,
        direction: direction,
        dryRun: false,
        contentType: file.contentType,
      );
      if (mounted) {
        showAppToast(context, tr('{n}건을 가져왔습니다.', {'n': r.inserted}));
      }
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(TaxDocument d) async {
    final result =
        await showDialog<({String action, String? category, String memo})>(
          context: context,
          builder: (_) => _TaxDocEditDialog(
            doc: d,
            categories: widget.ctx.expenseCategories,
          ),
        );
    if (result == null || !mounted) return;
    try {
      if (result.action == 'delete') {
        await widget.api.deleteTaxDocument(d.id);
      } else {
        await widget.api.updateTaxDocument(
          d.id,
          category: result.category ?? '',
          memo: result.memo,
        );
      }
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final page = _page;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('현금영수증·전자세금계산서')),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          IconButton(
            key: const ValueKey('taxdoc-import'),
            tooltip: tr('홈택스 엑셀 가져오기'),
            icon: const Icon(Icons.upload_file),
            onPressed: _busy ? null : _import,
          ),
          IconButton(
            tooltip: tr('엑셀로 내보내기'),
            icon: const Icon(Icons.download),
            onPressed: () => _download(
              context,
              widget.session,
              widget.api.taxDocumentsExportPath(_month),
              '증빙_$_month.xlsx',
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  MonthStepper(
                    month: _month,
                    onChanged: (m) {
                      setState(() => _month = m);
                      _load();
                    },
                  ),
                  for (final k in const [null, 'cash_receipt', 'tax_invoice'])
                    ChoiceChip(
                      label: Text(
                        k == null
                            ? tr('모두')
                            : k == 'cash_receipt'
                            ? tr('현금영수증')
                            : tr('전자세금계산서'),
                      ),
                      selected: _kind == k,
                      onSelected: (_) {
                        setState(() => _kind = k);
                        _load();
                      },
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                tr(
                  '홈택스 → 조회·발급 → 현금영수증·전자(세금)계산서 목록 조회에서 엑셀로 내려받아 그대로 올리세요. 같은 증빙은 한 번만 들어갑니다. 카드사·홈택스 연동(CODEF)을 켰다면 저절로 들어옵니다.',
                ),
                style: TextStyle(fontSize: 12, color: hint),
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
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  tr('{n}건 · 공급가액 {s} · 세액 {t} · 합계 {total}', {
                    'n': page.count,
                    's': signedWonText(page.supply),
                    't': signedWonText(page.tax),
                    'total': signedWonText(page.total),
                  }),
                  key: const ValueKey('taxdoc-totals'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (page.items.isEmpty)
                GroupwareEmpty(tr('이 달의 증빙이 없습니다.'))
              else
                for (final d in page.items)
                  ListTile(
                    key: ValueKey('taxdoc-${d.id}'),
                    leading: Icon(
                      d.invoice
                          ? Icons.request_page_outlined
                          : Icons.receipt_outlined,
                    ),
                    title: Text(d.supplierName ?? tr('(공급자 없음)')),
                    subtitle: Text(
                      [
                        d.issuedOn,
                        if (d.direction == 'sale') tr('매출'),
                        if (d.itemName != null) d.itemName!,
                        if (d.category != null) d.category!,
                        if (d.memo != null) d.memo!,
                      ].join(' · '),
                    ),
                    trailing: Text(
                      signedWonText(d.totalAmount),
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: d.totalAmount < 0
                            ? theme.colorScheme.error
                            : null,
                      ),
                    ),
                    onTap: () => _edit(d),
                  ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 증빙 하나 — 분류(전표 계정)·메모 고치기, 지우기. `(action: 'save' | 'delete', category, memo)`.
class _TaxDocEditDialog extends StatefulWidget {
  final TaxDocument doc;
  final List<String> categories;
  const _TaxDocEditDialog({required this.doc, required this.categories});

  @override
  State<_TaxDocEditDialog> createState() => _TaxDocEditDialogState();
}

class _TaxDocEditDialogState extends State<_TaxDocEditDialog> {
  late String? _category = widget.doc.category;
  late final _memo = TextEditingController(text: widget.doc.memo);

  @override
  void dispose() {
    _memo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.doc;
    return AlertDialog(
      title: Text(d.supplierName ?? tr('증빙')),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              [
                d.invoice ? tr('전자세금계산서') : tr('현금영수증'),
                d.issuedOn,
                if (d.approvalNo != null) tr('승인 {no}', {'no': d.approvalNo!}),
                if (d.supplierBizNo != null) d.supplierBizNo!,
              ].join(' · '),
            ),
            const SizedBox(height: 8),
            Text(
              tr('공급가액 {s} · 세액 {t} · 합계 {total}', {
                's': signedWonText(d.supplyAmount ?? 0),
                't': signedWonText(d.taxAmount ?? 0),
                'total': signedWonText(d.totalAmount),
              }),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: widget.categories.contains(_category)
                  ? _category
                  : null,
              decoration: InputDecoration(
                labelText: tr('분류(전표 계정)'),
                border: const OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(value: null, child: Text(tr('정하지 않음'))),
                for (final c in widget.categories)
                  DropdownMenuItem(value: c, child: Text(c)),
              ],
              onChanged: (v) => setState(() => _category = v),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _memo,
              maxLength: 300,
              decoration: InputDecoration(
                labelText: tr('메모'),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, (
            action: 'delete',
            category: null,
            memo: '',
          )),
          child: Text(tr('지우기')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('취소')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, (
            action: 'save',
            category: _category,
            memo: _memo.text.trim(),
          )),
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}
