import 'package:flutter/material.dart';

import '../../models/groupware_finance.dart';
import '../../models/groupware_finance_tools.dart';
import '../../services/api_client.dart' show ApiException;
import '../../services/groupware_api.dart';
import '../../widgets/app_toast.dart';
import 'finance_widgets.dart';
import 'groupware_screen.dart';
import 'payslip_view.dart' show askPayrollPassword;
import '../../l10n/tr.dart';

/// 연말정산 공제 자료(소득·세액공제 신고서의 금액) — 근로자가 홈택스 간소화 자료의 항목별 합계를 넣고(내 급여 → 연말정산 공제 자료), 급여
/// 담당자가 보고 고치고 확인한다(연말정산 자료 → 사람마다 "공제 자료"). 계산은 서버(server/src/yearEndClaimRules.js)가 하고 여기서는 넣고
/// 보이기만 한다.

/// 공제 자료 칸 이름(묶음.칸).
String claimFieldLabel(String group, String field) => switch ('$group.$field') {
  'card.credit' => tr('신용카드'),
  'card.debitCash' => tr('체크카드·현금영수증'),
  'card.culture' => tr('도서·공연·박물관·영화 등'),
  'card.sports' => tr('체육시설(2025. 7. 이후)'),
  'card.market' => tr('전통시장'),
  'card.transit' => tr('대중교통'),
  'insurance.general' => tr('보장성보험료'),
  'insurance.disabled' => tr('장애인전용 보장성보험료'),
  'medical.general' => tr('그 밖의 가족 의료비'),
  'medical.special' => tr('본인·65세 이상·장애인·6세 이하·산정특례자 의료비'),
  'medical.premature' => tr('미숙아·선천성이상아 의료비'),
  'medical.infertility' => tr('난임 시술비'),
  'donation.political' => tr('정치자금 기부금'),
  'donation.hometown' => tr('고향사랑 기부금'),
  'donation.special' => tr('특례기부금'),
  'donation.general' => tr('일반기부금(종교 단체 외)'),
  'donation.religious' => tr('일반기부금(종교 단체)'),
  'pension.savings' => tr('연금저축'),
  'pension.retirement' => tr('퇴직연금(IRP 등)'),
  'housing.rentLoan' => tr('주택임차차입금 원리금 상환액'),
  'housing.subscription' => tr('주택청약종합저축 납입액'),
  'housing.mortgage' => tr('장기주택저당차입금 이자'),
  'births.first' => tr('첫째'),
  'births.second' => tr('둘째'),
  'births.third' => tr('셋째 이상'),
  'extraPersonal.elderly' => tr('70세 이상(경로우대)'),
  'extraPersonal.disabled' => tr('장애인'),
  _ => field,
};

/// 교육비 종류 이름.
String educationKindLabel(String kind) => switch (kind) {
  'self' => tr('본인(대학원 포함)'),
  'preschool' => tr('취학 전 아동(1명 300만 원까지)'),
  'school' => tr('초·중·고(1명 300만 원까지)'),
  'college' => tr('대학생(1명 900만 원까지)'),
  'disabled' => tr('장애인 특수교육비'),
  _ => kind,
};

/// 어림의 공제 이름(server claimAllowances의 deductions·credits 키).
String claimAllowanceLabel(String key, {required bool credit}) => credit
    ? switch (key) {
        'pensionAccount' => tr('연금계좌 세액공제'),
        'political' => tr('정치자금 기부금 세액공제'),
        'hometown' => tr('고향사랑 기부금 세액공제'),
        'marriage' => tr('결혼세액공제'),
        'births' => tr('출산·입양 세액공제'),
        'other' => tr('그 밖의 세액공제'),
        'insurance' => tr('보험료 세액공제'),
        'medical' => tr('의료비 세액공제'),
        'education' => tr('교육비 세액공제'),
        'donation' => tr('특례·일반기부금 세액공제'),
        'monthlyRent' => tr('월세 세액공제'),
        _ => key,
      }
    : switch (key) {
        'extraPersonal' => tr('추가공제(경로우대·장애인·부녀자·한부모)'),
        'card' => tr('신용카드 등 소득공제'),
        'subscription' => tr('주택청약종합저축 소득공제'),
        'other' => tr('그 밖의 소득공제(종합한도 안)'),
        'otherExempt' => tr('그 밖의 소득공제(종합한도 밖)'),
        'rentLoan' => tr('주택임차차입금 소득공제'),
        'mortgage' => tr('장기주택저당차입금 이자 소득공제'),
        _ => key,
      };

/// 연말정산 어림의 계산 줄(참고용) — 과세표준·산출세액·세액공제·결정세액과 공제 자료로 넣은 공제들.
class YearEndEstimateView extends StatelessWidget {
  final YearEndEstimate estimate;
  final PayrollYearTotals totals;
  const YearEndEstimateView({
    super.key,
    required this.estimate,
    required this.totals,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final e = estimate;
    Widget line(String label, int amount, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: bold ? FontWeight.w600 : null,
              ),
            ),
          ),
          Text(
            signedWonText(amount),
            style: TextStyle(
              fontSize: 13,
              fontWeight: bold ? FontWeight.w600 : null,
            ),
          ),
        ],
      ),
    );
    final deductions = e.claimDeductions.entries.where((x) => x.value != 0);
    final credits = e.claimCredits.entries.where((x) => x.value != 0);
    final excessLabel = tr('소득공제 종합한도(2,500만 원) 넘는 금액');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        line(tr('총급여'), totals.taxable),
        line(tr('근로소득금액'), e.earnedIncome),
        for (final d in deductions)
          line('  ${claimAllowanceLabel(d.key, credit: false)}', d.value),
        if (e.limitExcess > 0) line('  $excessLabel', -e.limitExcess),
        line(tr('과세표준'), e.taxBase),
        line(tr('산출세액'), e.computedTax),
        line(tr('근로소득세액공제'), e.earnedCredit),
        if (e.childCredit > 0) line(tr('자녀세액공제'), e.childCredit),
        for (final c in credits)
          line('  ${claimAllowanceLabel(c.key, credit: true)}', c.value),
        if (e.useStandard) line(tr('표준세액공제'), e.standardCredit),
        line(tr('결정세액'), e.decidedTax, bold: true),
        line(tr('기납부 소득세'), e.withheldIncomeTax),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            e.diffIncomeTax == 0
                ? tr('차이 없음')
                : e.diffIncomeTax > 0
                ? tr('추징 {won}(지방소득세 {local} 별도)', {
                    'won': signedWonText(e.diffIncomeTax),
                    'local': signedWonText(e.diffLocalTax),
                  })
                : tr('환급 {won}(지방소득세 {local} 별도)', {
                    'won': signedWonText(-e.diffIncomeTax),
                    'local': signedWonText(-e.diffLocalTax),
                  }),
            key: const ValueKey('year-end-settle'),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        if (e.useStandard)
          Text(
            tr('특별소득공제·특별세액공제·월세보다 표준세액공제(13만 원)가 유리해 표준세액공제로 셌습니다.'),
            style: TextStyle(fontSize: 12, color: hint),
          ),
        if (e.limitExcess > 0)
          Text(
            tr(
              '주택자금·주택청약·신용카드 등·그 밖의 소득공제(종합한도 안)를 합해 2,500만 원을 넘는 금액은 공제하지 않습니다.',
            ),
            style: TextStyle(fontSize: 12, color: hint),
          ),
        if (e.lawAssumed && e.lawYear != null)
          Text(
            tr('이 해의 세법이 아직 들어가 있지 않아 {y}년 귀속 세법으로 셌습니다.', {'y': e.lawYear}),
            key: const ValueKey('year-end-law-assumed'),
            style: TextStyle(fontSize: 12, color: hint),
          ),
      ],
    );
  }
}

/// 공제 자료 입력 화면 — [onSave]가 서버에 보낸다(null이면 지우기). [readOnly]면 보기만.
/// 담당자는 [onConfirm]으로 확인·확인 풀기(근로자가 더 못 고침)를 한다. 저장했으면 true로 닫힌다.
Future<bool?> openYearEndClaimForm(
  BuildContext context, {
  required String title,
  required int year,
  YearEndClaim? claim,
  YearEndClaimStatus status = const YearEndClaimStatus(),
  bool readOnly = false,
  required Future<void> Function(Map<String, dynamic>? claim) onSave,
  Future<void> Function(bool confirm, Map<String, dynamic>? claim)? onConfirm,
}) => Navigator.of(context).push<bool>(
  MaterialPageRoute(
    builder: (_) => YearEndClaimForm(
      title: title,
      year: year,
      claim: claim,
      status: status,
      readOnly: readOnly,
      onSave: onSave,
      onConfirm: onConfirm,
    ),
  ),
);

class YearEndClaimForm extends StatefulWidget {
  final String title;
  final int year;
  final YearEndClaim? claim;
  final YearEndClaimStatus status;
  final bool readOnly;
  final Future<void> Function(Map<String, dynamic>? claim) onSave;
  final Future<void> Function(bool confirm, Map<String, dynamic>? claim)?
  onConfirm;
  const YearEndClaimForm({
    super.key,
    required this.title,
    required this.year,
    this.claim,
    this.status = const YearEndClaimStatus(),
    this.readOnly = false,
    required this.onSave,
    this.onConfirm,
  });

  @override
  State<YearEndClaimForm> createState() => _YearEndClaimFormState();
}

class _YearEndClaimFormState extends State<YearEndClaimForm> {
  late final YearEndClaim _initial = widget.claim ?? const YearEndClaim();

  /// 'group.field' 또는 맨 위 칸(monthlyRent·cardPrevious·otherDeduction·otherDeductionExempt·otherCredit) → 입력칸.
  final Map<String, TextEditingController> _fields = {};
  late final _memo = TextEditingController(text: _initial.memo);

  /// 신용카드 등 기본한도를 늘리는 자녀등 수(2026년 귀속부터).
  late final _cardChildren = TextEditingController(
    text: _initial.top('cardChildren') == 0
        ? ''
        : '${_initial.top('cardChildren')}',
  );
  late bool _marriage = _initial.marriage;
  late bool _woman = _initial.woman;
  late bool _singleParent = _initial.singleParent;
  late int _mortgageLimit = _initial.mortgageLimit;
  late final List<(String, TextEditingController)> _education = [
    for (final e in _initial.education)
      (e.kind, TextEditingController(text: wonInputText(e.amount))),
  ];
  bool _busy = false;
  String? _error;

  static const _topFields = [
    'monthlyRent',
    'cardPrevious',
    'otherDeduction',
    'otherDeductionExempt',
    'otherCredit',
  ];

  @override
  void initState() {
    super.initState();
    for (final g in YearEndClaim.groups.entries) {
      for (final f in g.value) {
        final v = _initial.value(g.key, f);
        _fields['${g.key}.$f'] = TextEditingController(
          text: v == 0 ? '' : '$v',
        );
      }
    }
    for (final k in _topFields) {
      _fields[k] = TextEditingController(text: wonInputText(_initial.top(k)));
    }
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    for (final (_, c) in _education) {
      c.dispose();
    }
    _memo.dispose();
    _cardChildren.dispose();
    super.dispose();
  }

  /// 입력 → 서버에 보낼 모양. 숫자가 아닌 칸이 있으면 null과 함께 _error.
  Map<String, dynamic>? _build() {
    int? read(TextEditingController c) {
      final t = c.text.trim();
      if (t.isEmpty) return 0;
      final v = parseWonInput(t);
      return v == null || v < 0 ? null : v;
    }

    final out = <String, dynamic>{};
    for (final g in YearEndClaim.groups.entries) {
      final m = <String, dynamic>{};
      for (final f in g.value) {
        final v = read(_fields['${g.key}.$f']!);
        if (v == null) {
          setState(
            () => _error = tr('{label}: 0 이상의 숫자로 넣으세요.', {
              'label': claimFieldLabel(g.key, f),
            }),
          );
          return null;
        }
        m[f] = v;
      }
      out[g.key] = m;
    }
    (out['housing'] as Map)['mortgageLimit'] = _mortgageLimit;
    (out['extraPersonal'] as Map)['woman'] = _woman;
    (out['extraPersonal'] as Map)['singleParent'] = _singleParent;
    for (final k in _topFields) {
      final v = read(_fields[k]!);
      if (v == null) {
        setState(() => _error = tr('금액은 0 이상의 숫자로 넣으세요.'));
        return null;
      }
      out[k] = v;
    }
    final education = <Map<String, dynamic>>[];
    for (final (kind, c) in _education) {
      final v = read(c);
      if (v == null) {
        setState(() => _error = tr('교육비: 0 이상의 숫자로 넣으세요.'));
        return null;
      }
      if (v > 0) education.add({'kind': kind, 'amount': v});
    }
    out['education'] = education;
    final kids = _cardChildren.text.trim();
    final kidCount = kids.isEmpty ? 0 : int.tryParse(kids);
    if (kidCount == null || kidCount < 0 || kidCount > 20) {
      setState(() => _error = tr('사람 수는 0~20명으로 넣으세요.'));
      return null;
    }
    out['cardChildren'] = kidCount;
    out['marriage'] = _marriage;
    out['memo'] = _memo.text.trim();
    return out;
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _save() async {
    final body = _build();
    if (body == null) return;
    await _run(() => widget.onSave(body));
  }

  Future<void> _clear() async {
    final ok = await confirmAction(
      context,
      title: tr('공제 자료 지우기'),
      message: tr('{y}년 귀속 공제 자료를 모두 지울까요?', {'y': widget.year}),
      okLabel: tr('지우기'),
      danger: true,
    );
    if (ok) await _run(() => widget.onSave(null));
  }

  Future<void> _confirm(bool confirm) async {
    final body = confirm ? _build() : null;
    if (confirm && body == null) return;
    await _run(() => widget.onConfirm!(confirm, body));
  }

  Widget _money(String key, {String? label, String? helper}) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextField(
      key: ValueKey('claim-$key'),
      controller: _fields[key],
      enabled: !widget.readOnly,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        helperText: helper,
        suffixText: tr('원'),
        border: const OutlineInputBorder(),
      ),
    ),
  );

  Widget _group(String group, {Map<String, String> helpers = const {}}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final f in YearEndClaim.groups[group]!)
            YearEndClaim.countGroups.contains(group)
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      key: ValueKey('claim-$group.$f'),
                      controller: _fields['$group.$f'],
                      enabled: !widget.readOnly,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: claimFieldLabel(group, f),
                        suffixText: tr('명'),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  )
                : _money(
                    '$group.$f',
                    label: claimFieldLabel(group, f),
                    helper: helpers[f],
                  ),
        ],
      );

  Widget _section(String title, List<Widget> children, {String? note}) {
    final hint = Theme.of(context).hintColor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 6),
              child: Text(note, style: TextStyle(fontSize: 12, color: hint)),
            )
          else
            const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final status = widget.status;
    final ro = widget.readOnly;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (!ro && status.exists)
            IconButton(
              key: const ValueKey('claim-clear'),
              tooltip: tr('지우기'),
              icon: const Icon(Icons.delete_outline),
              onPressed: _busy ? null : _clear,
            ),
          if (widget.onConfirm != null)
            TextButton(
              key: const ValueKey('claim-confirm'),
              onPressed: _busy ? null : () => _confirm(!status.confirmed),
              child: Text(status.confirmed ? tr('확인 풀기') : tr('저장하고 확인')),
            ),
          if (!ro)
            TextButton(
              key: const ValueKey('claim-save'),
              onPressed: _busy ? null : _save,
              child: Text(tr('저장')),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 48),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              [
                tr(
                  '{y}년 귀속 — 홈택스 → 연말정산 간소화 자료의 항목별 합계(실손보험금 받은 의료비는 뺀 금액)를 넣으세요. 공제 대상인지(나이·소득·무주택 등)는 넣는 사람이 확인합니다. 계산은 참고용 어림입니다.',
                  {'y': widget.year},
                ),
                if (status.confirmed)
                  tr('담당자({by})가 확인한 자료입니다.', {
                    'by': status.confirmedByName ?? '',
                  }),
                if (ro && status.confirmed)
                  tr('고쳐야 하면 급여 담당자에게 확인을 풀어 달라고 하세요.'),
              ].join(' '),
              style: TextStyle(fontSize: 12, color: hint),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          _section(tr('인적공제 추가공제'), [
            _group('extraPersonal'),
            SwitchListTile(
              key: const ValueKey('claim-woman'),
              contentPadding: EdgeInsets.zero,
              title: Text(tr('부녀자(근로소득금액 3,000만 원 이하)')),
              value: _woman,
              onChanged: ro ? null : (v) => setState(() => _woman = v),
            ),
            SwitchListTile(
              key: const ValueKey('claim-single-parent'),
              contentPadding: EdgeInsets.zero,
              title: Text(tr('한부모')),
              value: _singleParent,
              onChanged: ro ? null : (v) => setState(() => _singleParent = v),
            ),
          ], note: tr('기본공제(150만 원 × 가족 수)는 급여 설정의 공제대상가족 수로 셉니다.')),
          _section(
            tr('신용카드 등 사용액'),
            [
              _group('card'),
              if (YearEndClaim.cardChildrenApplies(widget.year))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    key: const ValueKey('claim-cardChildren'),
                    controller: _cardChildren,
                    enabled: !widget.readOnly,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: tr('카드 공제 한도를 늘리는 자녀 수'),
                      helperText: tr(
                        '20세 이하 자녀·손자녀 등(장애인은 나이 상관없음) — 1명마다 50만 원(총급여 7,000만 원 넘으면 25만 원), 2명까지',
                      ),
                      helperMaxLines: 2,
                      suffixText: tr('명'),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
              if (YearEndClaim.spendingGrowthApplies(widget.year))
                _money(
                  'cardPrevious',
                  label: tr('{y}년 신용카드 등 사용액 합계', {'y': widget.year - 1}),
                  helper: tr(
                    '소비 증가분 공제 — 지난해의 105%를 넘게 쓴 금액의 10%(100만 원까지). 비우면 셈하지 않습니다.',
                  ),
                ),
            ],
            note: tr(
              '총급여 25%를 넘게 쓴 금액에서 공제합니다. 총급여 7,000만 원이 넘으면 도서·공연·체육시설 사용분은 신용카드 사용분으로 셉니다.',
            ),
          ),
          _section(tr('주택자금'), [
            _group(
              'housing',
              helpers: {
                'subscription': tr('총급여 7,000만 원 이하 무주택 세대주 — 연 300만 원까지'),
              },
            ),
            DropdownButtonFormField<int>(
              key: const ValueKey('claim-mortgage-limit'),
              initialValue: _mortgageLimit,
              decoration: InputDecoration(
                isDense: true,
                labelText: tr('장기주택저당차입금 이자 공제 한도'),
                border: const OutlineInputBorder(),
              ),
              items: [
                for (final l in YearEndClaim.mortgageLimits)
                  DropdownMenuItem(
                    value: l,
                    child: Text(switch (l) {
                      6000000 => tr('600만 원(10~15년)'),
                      8000000 => tr('800만 원(15년 이상, 그 밖의 방식)'),
                      18000000 => tr('1,800만 원(15년 이상, 고정금리 또는 비거치식)'),
                      _ => tr('2,000만 원(15년 이상, 고정금리이면서 비거치식)'),
                    }),
                  ),
              ],
              onChanged: ro
                  ? null
                  : (v) => setState(() => _mortgageLimit = v ?? 18000000),
            ),
          ]),
          _section(
            tr('연금계좌'),
            [_group('pension')],
            note: tr(
              '연금저축 600만 원, 퇴직연금과 합쳐 900만 원까지 — 총급여 5,500만 원 이하 15%, 넘으면 12%.',
            ),
          ),
          _section(tr('보험료'), [
            _group('insurance'),
          ], note: tr('국민연금·건강·고용보험료는 명세서에서 셉니다. 여기는 보장성보험료(각 100만 원까지)만.')),
          _section(tr('의료비'), [
            _group('medical'),
          ], note: tr('총급여 3%를 넘는 금액부터 공제합니다. 그 밖의 가족 의료비는 700만 원까지.')),
          _section(tr('교육비'), [
            for (var i = 0; i < _education.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: DropdownButtonFormField<String>(
                        key: ValueKey('claim-education-kind-$i'),
                        initialValue: _education[i].$1,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final k in YearEndClaim.educationKinds)
                            DropdownMenuItem(
                              value: k,
                              child: Text(
                                educationKindLabel(k),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: ro
                            ? null
                            : (v) => setState(
                                () => _education[i] = (
                                  v ?? 'self',
                                  _education[i].$2,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        key: ValueKey('claim-education-amount-$i'),
                        controller: _education[i].$2,
                        enabled: !ro,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          isDense: true,
                          suffixText: tr('원'),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    if (!ro)
                      IconButton(
                        tooltip: tr('빼기'),
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() {
                          _education.removeAt(i).$2.dispose();
                        }),
                      ),
                  ],
                ),
              ),
            if (!ro && _education.length < 20)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('claim-education-add'),
                  onPressed: () => setState(
                    () => _education.add(('school', TextEditingController())),
                  ),
                  icon: const Icon(Icons.add),
                  label: Text(tr('교육비 더하기(사람마다 한 줄)')),
                ),
              ),
          ]),
          _section(
            tr('기부금'),
            [_group('donation')],
            note: widget.year >= 2026
                ? tr(
                    '정치자금·고향사랑 기부금은 10만 원까지 100/110을 돌려받습니다(고향사랑은 20만 원까지 40%, 2,000만 원까지).',
                  )
                : tr(
                    '정치자금·고향사랑 기부금은 10만 원까지 100/110을 돌려받습니다(고향사랑은 2,000만 원까지).',
                  ),
          ),
          _section(tr('월세·결혼·출산'), [
            _money('monthlyRent', label: tr('월세 지급액(총급여 8,000만 원 이하 무주택 세대주)')),
            SwitchListTile(
              key: const ValueKey('claim-marriage'),
              contentPadding: EdgeInsets.zero,
              title: Text(tr('결혼세액공제(2024~2026년 혼인신고, 한 번)')),
              value: _marriage,
              onChanged: ro ? null : (v) => setState(() => _marriage = v),
            ),
            Text(
              tr('그해 태어나거나 입양한 자녀(순서)'),
              style: TextStyle(fontSize: 12, color: hint),
            ),
            const SizedBox(height: 4),
            _group('births'),
          ]),
          _section(
            tr('그 밖의 공제(직접)'),
            [
              _money(
                'otherDeduction',
                label: tr('그 밖의 소득공제(종합한도 안)'),
                helper: tr('우리사주 출연금·투자조합 출자 등'),
              ),
              _money(
                'otherDeductionExempt',
                label: tr('그 밖의 소득공제(종합한도 밖)'),
                helper: tr('벤처기업 직접 투자 등 소득공제 종합한도(2,500만 원)에 들지 않는 것'),
              ),
              _money('otherCredit', label: tr('그 밖의 세액공제')),
            ],
            note: tr(
              '우리사주·벤처투자·주택자금 이자 세액공제 등 여기서 계산하지 않는 공제는 세무 프로그램에서 센 금액을 넣으세요. 주택자금·주택청약·신용카드 등과 종합한도 안의 소득공제는 합쳐 2,500만 원까지입니다.',
            ),
          ),
          _section(tr('메모'), [
            TextField(
              key: const ValueKey('claim-memo'),
              controller: _memo,
              enabled: !ro,
              maxLength: 500,
              maxLines: 3,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ]),
        ],
      ),
    );
  }
}

// ── 받는 사람 — 내 연말정산 ──

Future<void> openMyYearEndScreen(
  BuildContext context, {
  required GroupwareApi api,
  required String today,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => MyYearEndScreen(api: api, today: today),
  ),
);

/// 내 연말정산 — 귀속 연도(◀ ▶)마다 내 공제 자료(내기·고치기)와, 그해 내 명세서로 계산한 어림.
class MyYearEndScreen extends StatefulWidget {
  final GroupwareApi api;
  final String today;
  const MyYearEndScreen({super.key, required this.api, required this.today});

  @override
  State<MyYearEndScreen> createState() => _MyYearEndScreenState();
}

class _MyYearEndScreenState extends State<MyYearEndScreen> {
  late int _year = int.parse(widget.today.substring(0, 4)) - 1;
  MyYearEnd? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _data = null;
      _error = null;
    });
    try {
      final d = await widget.api.myYearEnd(_year);
      if (mounted) setState(() => _data = d);
    } on ApiException catch (e) {
      // 비밀번호를 다시 확인해야 하는 범위 — 확인하면 다시 받는다.
      if (e.statusCode == 423 && mounted) {
        if (await askPayrollPassword(context, api: widget.api)) return _load();
        if (mounted) Navigator.pop(context);
        return;
      }
      if (mounted) setState(() => _error = e.toString());
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _edit(MyYearEnd d) async {
    final saved = await openYearEndClaimForm(
      context,
      title: tr('{y}년 귀속 공제 자료', {'y': d.year}),
      year: d.year,
      claim: d.detail.claim,
      status: d.detail.status,
      readOnly: !d.canEdit,
      onSave: (claim) => widget.api.submitMyYearEnd(d.year, claim),
    );
    if (saved == true && mounted) {
      showAppToast(context, tr('공제 자료를 냈습니다. 급여 담당자가 확인합니다.'));
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final d = _data;
    return Scaffold(
      appBar: AppBar(title: Text(tr('연말정산 공제 자료'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 48),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () {
                  setState(() => _year -= 1);
                  _load();
                },
              ),
              Text(
                tr('{y}년 귀속', {'y': _year}),
                key: const ValueKey('my-year-end-year'),
                style: theme.textTheme.titleMedium,
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () {
                  setState(() => _year += 1);
                  _load();
                },
              ),
            ],
          ),
          if (_error != null)
            GroupwareEmpty(_error!)
          else if (d == null)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            ListTile(
              key: const ValueKey('my-year-end-claim'),
              leading: Icon(
                d.detail.status.confirmed
                    ? Icons.verified_outlined
                    : d.detail.status.exists
                    ? Icons.assignment_turned_in_outlined
                    : Icons.assignment_outlined,
                color: d.detail.status.confirmed ? Colors.green.shade700 : null,
              ),
              title: Text(
                d.detail.status.confirmed
                    ? tr('담당자가 확인했습니다')
                    : d.detail.status.exists
                    ? tr('냈습니다 — 담당자 확인 전')
                    : tr('아직 내지 않았습니다'),
              ),
              subtitle: Text(
                d.canEdit
                    ? tr('홈택스 간소화 자료의 합계를 넣으세요. 확인 전까지 고칠 수 있습니다.')
                    : d.detail.status.confirmed
                    ? tr('고쳐야 하면 급여 담당자에게 말하세요.')
                    : tr('지난 2년과 올해의 자료만 낼 수 있습니다.'),
              ),
              trailing: FilledButton.tonal(
                key: const ValueKey('my-year-end-edit'),
                onPressed: () => _edit(d),
                child: Text(
                  !d.canEdit
                      ? tr('보기')
                      : d.detail.status.exists
                      ? tr('고치기')
                      : tr('넣기'),
                ),
              ),
            ),
            GroupwareSectionHeader(tr('연말정산 어림(참고용)')),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: d.totals.months == 0
                  ? Text(
                      tr('이 해에 받은 급여명세서가 없어 어림하지 못했습니다.'),
                      style: TextStyle(color: hint),
                    )
                  : YearEndEstimateView(estimate: d.estimate, totals: d.totals),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                tr(
                  '그해 받은 명세서(총급여·4대보험·기납부 소득세)와 급여 설정의 공제대상가족 수({n}명), 이 공제 자료로 계산한 참고용 금액입니다. 실제 정산 결과는 회사가 세무 프로그램으로 정산해 2월 급여에 넣습니다.',
                  {'n': d.profile.dependents},
                ),
                style: TextStyle(fontSize: 12, color: hint),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
