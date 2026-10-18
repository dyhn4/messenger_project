import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../models/groupware_work.dart';
import '../../services/groupware_api.dart';
import '../../widgets/app_toast.dart';
import 'approval_forms.dart' show isHmText;
import 'groupware_screen.dart' show GroupwareChanges, GroupwareSectionHeader;
import 'leave_notice_pdf.dart';
import 'leave_tab.dart' show showLeaveDatesDialog;
import '../../l10n/tr.dart';

/// 관리 탭의 근태·휴가 관리 — 휴가 종류·지출 분류·출근 알림·주 52시간 지키기·연차 기준과 이월·가산율·출퇴근 위치(범위 설정), 유연근무와
/// 탄력·선택근무 정산 기간, 주 52시간(사람마다 상한), 연차 사용 촉진과 서면 통지서(서버 groupwareWork.js·workPolicy.js·workLocation.js).

// ── 휴가 종류·지출 분류·출근 알림 ─────────────────────────────────────────────

class GroupwareOptionsSection extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareChanges changes;
  final VoidCallback? onChanged;
  const GroupwareOptionsSection({
    super.key,
    required this.api,
    required this.changes,
    this.onChanged,
  });

  @override
  State<GroupwareOptionsSection> createState() =>
      _GroupwareOptionsSectionState();
}

/// 주 52시간 지키기 방식의 이름과 설명(서버 workPolicy.js OVERTIME_GUARDS) — 설정 화면과 주 52시간 현황 머리가 같이 쓴다.
String overtimeGuardLabel(String guard) => switch (guard) {
  'approval' => tr('결재를 받게'),
  'block' => tr('막기'),
  _ => tr('알리기만'),
};

String overtimeGuardHelp(String guard) => switch (guard) {
  'approval' => tr(
    '48시간(탄력근무는 그 사람 상한의 4시간 전)을 넘긴 주에는 그날 승인된 연장·휴일근무 결재가 있어야 출근을 누를 수 있고, 주 52시간을 넘기게 되는 연장근무 신청은 받지 않습니다.',
  ),
  'block' => tr(
    '주 52시간(탄력근무는 그 사람 상한)을 채운 주에는 출근을 누를 수 없고, 넘기게 되는 연장근무 신청도 받지 않습니다.',
  ),
  _ => tr('넘으면 출퇴근 화면과 이 관리 화면에 알리기만 합니다(출근·신청은 막지 않음).'),
};

/// 연차 이월 일수 고르기 값(0이면 하지 않음 — 서버 상한 25일).
const _carryDayChoices = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 20, 25];

class _GroupwareOptionsSectionState extends State<GroupwareOptionsSection> {
  GroupwareOptions? _options;
  bool _busy = false;

  /// 가산율(%) 입력 — 연장·야간·휴일(8시간까지)·휴일 8시간 넘는 부분, 그리고 5명 미만 사업장인지.
  final _payOvertime = TextEditingController();
  final _payNight = TextEditingController();
  final _payHoliday = TextEditingController();
  final _payHolidayOver = TextEditingController();
  bool _smallBusiness = false;

  /// 사무실 위치 입력 — 위도·경도·반경(m).
  final _officeLat = TextEditingController();
  final _officeLng = TextEditingController();
  final _officeRadius = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      _payOvertime,
      _payNight,
      _payHoliday,
      _payHolidayOver,
      _officeLat,
      _officeLng,
      _officeRadius,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final o = await widget.api.options();
      if (!mounted) return;
      setState(() {
        _options = o;
        _syncPayRates(o);
        _syncOffice(o);
      });
    } catch (e) {
      if (mounted) showAppToast(context, tr('설정을 불러오지 못했습니다: {e}', {'e': e}));
    }
  }

  /// 받은 설정의 가산율로 입력 칸을 채운다(불러올 때와 가산율을 저장했을 때만 — 다른 설정을 저장해도 입력 중인 값은 그대로).
  void _syncPayRates(GroupwareOptions o) {
    _payOvertime.text = '${o.payRates.overtime}';
    _payNight.text = '${o.payRates.night}';
    _payHoliday.text = '${o.payRates.holiday}';
    _payHolidayOver.text = '${o.payRates.holidayOver}';
    _smallBusiness = o.payRates.smallBusiness;
  }

  /// 받은 설정의 사무실 위치로 입력 칸을 채운다(없으면 비우고 반경은 기본 200m).
  void _syncOffice(GroupwareOptions o) {
    final office = o.officeLocation;
    _officeLat.text = office == null ? '' : '${office.lat}';
    _officeLng.text = office == null ? '' : '${office.lng}';
    _officeRadius.text = '${office?.radius ?? 200}';
  }

  /// 설정 저장 — 성공하면 받은 설정으로 바꾸고 [done]을 알린다, 서버가 거절하면 그 까닭을 알린다. [after]는 저장한 뒤 입력 칸 맞추기.
  Future<bool> _save(
    Future<GroupwareOptions> Function() action,
    String done, {
    void Function(GroupwareOptions o)? after,
  }) async {
    setState(() => _busy = true);
    try {
      final o = await action();
      if (!mounted) return true;
      setState(() {
        _options = o;
        after?.call(o);
      });
      showAppToast(context, done);
      widget.onChanged?.call();
      return true;
    } catch (e) {
      if (mounted) showAppToast(context, tr('저장하지 못했습니다: {e}', {'e': e}));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 연차 기준·회계연도 시작 달을 바꾸기 전에 묻는다 — 모두의 이번 연차 기간·남은 연차·촉진 일정이 다시 계산되므로.
  Future<bool> _confirmBasisChange(String description) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('연차 기준 바꾸기')),
        content: SizedBox(
          width: 420,
          child: Text(
            tr(
              '{description}\n\n바꾸면 모두의 이번 연차 기간·생긴 연차·남은 연차와 연차 사용 촉진 일정이 새 기준으로 다시 계산됩니다. 이미 보낸 촉진 통지와 승인된 휴가는 그대로 남습니다.',
              {'description': description},
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('취소')),
          ),
          FilledButton(
            key: const ValueKey('gw-leave-basis-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('바꾸기')),
          ),
        ],
      ),
    );
    return ok == true && mounted;
  }

  Future<void> _changeBasis(String basis) async {
    final o = _options!;
    if (basis == o.leaveBasis) return;
    final description = basis == 'fiscal'
        ? tr('연차 기준을 회계연도({m}월 1일 시작)로 바꿉니다.', {'m': o.fiscalStartMonth})
        : tr('연차 기준을 입사일로 바꿉니다.');
    if (!await _confirmBasisChange(description)) return;
    await _save(
      () => widget.api.updateOptions(
        leaveBasis: basis,
        fiscalStartMonth: basis == 'fiscal' ? o.fiscalStartMonth : null,
      ),
      tr('연차 기준을 바꿨습니다.'),
    );
  }

  Future<void> _changeFiscalMonth(int month) async {
    if (month == _options!.fiscalStartMonth) return;
    if (!await _confirmBasisChange(
      tr('회계연도 시작을 {m}월 1일로 바꿉니다.', {'m': month}),
    )) {
      return;
    }
    await _save(
      () => widget.api.updateOptions(fiscalStartMonth: month),
      tr('회계연도 시작 달을 바꿨습니다.'),
    );
  }

  /// 연차 이월 — 먼저 미리 보기(dryRun)로 넣을 사람·양과 건너뛸 사람을 보이고, 확인하면 미리 본 사람에게만 실제로 넣는다.
  Future<void> _runCarryOver() async {
    setState(() => _busy = true);
    CarryOverResult preview;
    try {
      preview = await widget.api.carryOverLeave(dryRun: true);
    } catch (e) {
      if (mounted) {
        showAppToast(context, tr('연차 이월을 미리 보지 못했습니다: {e}', {'e': e}));
        setState(() => _busy = false);
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _CarryOverPreviewDialog(preview: preview),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await widget.api.carryOverLeave(
        dryRun: false,
        userIds: [for (final a in preview.applied) a.userId],
      );
      if (!mounted) return;
      showAppToast(
        context,
        tr('{n}명의 연차를 이월했습니다.{skipped}', {
          'n': r.applied.length,
          'skipped': r.skipped.isEmpty
              ? ''
              : tr(' ({k}명 건너뜀)', {'k': r.skipped.length}),
        }),
      );
      widget.onChanged?.call();
    } catch (e) {
      if (mounted) showAppToast(context, tr('연차를 이월하지 못했습니다: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 가산율 저장 — 0~300 정수인지만 여기서 보고, 법정 최저(5명 이상: 연장·야간·휴일 50%, 휴일 8시간 넘는 부분 100%)는 서버가 거절한다.
  Future<void> _savePayRates() async {
    final values = [
      for (final c in [_payOvertime, _payNight, _payHoliday, _payHolidayOver])
        int.tryParse(c.text.trim()),
    ];
    if (values.any((v) => v == null || v < 0 || v > 300)) {
      showAppToast(context, tr('가산율은 0~300% 사이 정수로 넣으세요.'));
      return;
    }
    await _save(
      () => widget.api.updateOptions(
        payRates: PayRates(
          overtime: values[0]!,
          night: values[1]!,
          holiday: values[2]!,
          holidayOver: values[3]!,
          smallBusiness: _smallBusiness,
        ),
      ),
      tr('가산율을 저장했습니다.'),
      after: _syncPayRates,
    );
  }

  /// 사무실 위치 저장 — 위도 −90~90, 경도 −180~180, 반경 50~5000m.
  Future<void> _saveOffice() async {
    final lat = double.tryParse(_officeLat.text.trim());
    final lng = double.tryParse(_officeLng.text.trim());
    final radius = int.tryParse(_officeRadius.text.trim());
    if (lat == null || lng == null || lat.abs() > 90 || lng.abs() > 180) {
      showAppToast(context, tr('사무실 위도·경도를 숫자로 넣으세요(예: 37.5665, 126.9780).'));
      return;
    }
    if (radius == null || radius < 50 || radius > 5000) {
      showAppToast(context, tr('사무실 반경은 50~5000m로 정하세요.'));
      return;
    }
    await _save(
      () => widget.api.updateOptions(
        officeLocation: (lat: lat, lng: lng, radius: radius),
      ),
      tr('사무실 위치를 저장했습니다.'),
      after: _syncOffice,
    );
  }

  Future<void> _clearOffice() => _save(
    () => widget.api.updateOptions(clearOfficeLocation: true),
    tr('사무실 위치를 지웠습니다.'),
    after: _syncOffice,
  );

  Future<void> _editLeaveTypes() async {
    final result = await showDialog<List<LeaveTypeInfo>>(
      context: context,
      builder: (_) => _LeaveTypesDialog(types: _options!.leaveTypes),
    );
    if (result == null) return;
    await _save(
      () => widget.api.updateOptions(leaveTypes: result),
      tr('휴가 종류를 저장했습니다.'),
    );
  }

  Future<void> _editCategories() async {
    final result = await showDialog<List<String>>(
      context: context,
      builder: (_) =>
          _CategoriesDialog(categories: _options!.expenseCategories),
    );
    if (result == null) return;
    await _save(
      () => widget.api.updateOptions(expenseCategories: result),
      tr('지출 분류를 저장했습니다.'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final o = _options;
    final hint = Theme.of(context).hintColor;
    if (o == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupwareSectionHeader(tr('휴가 종류·지출 분류')),
        ListTile(
          key: const ValueKey('gw-leave-types'),
          dense: true,
          title: Text(tr('휴가 종류')),
          subtitle: Text(
            o.leaveTypes
                .where((t) => t.enabled)
                .map((t) => t.label)
                .join(' · '),
            style: TextStyle(color: hint),
          ),
          trailing: TextButton(
            onPressed: _busy ? null : _editLeaveTypes,
            child: Text(tr('바꾸기')),
          ),
        ),
        ListTile(
          key: const ValueKey('gw-expense-categories'),
          dense: true,
          title: Text(tr('지출 분류')),
          subtitle: Text(
            o.expenseCategories.join(' · '),
            style: TextStyle(color: hint),
          ),
          trailing: TextButton(
            onPressed: _busy ? null : _editCategories,
            child: Text(tr('바꾸기')),
          ),
        ),
        GroupwareSectionHeader(tr('출근·퇴근 알림')),
        SwitchListTile(
          key: const ValueKey('gw-clock-in-reminder'),
          dense: true,
          title: Text(tr('출근을 안 누르면 알림')),
          subtitle: Text(
            tr(
              '근무 시작 {o.reminderDelayMinutes}분 뒤 — 최근 30일 안에 출퇴근을 쓴 사람에게, 쉬는 날·휴가·출장 빼고',
              {'o.reminderDelayMinutes': o.reminderDelayMinutes},
            ),
            style: TextStyle(color: hint),
          ),
          value: o.clockInReminder,
          onChanged: _busy
              ? null
              : (v) => _save(
                  () => widget.api.updateOptions(clockInReminder: v),
                  v ? tr('출근 알림을 켰습니다.') : tr('출근 알림을 껐습니다.'),
                ),
        ),
        SwitchListTile(
          key: const ValueKey('gw-clock-out-reminder'),
          dense: true,
          title: Text(tr('퇴근을 안 누르면 알림')),
          subtitle: Text(tr('근무 끝 1시간 뒤'), style: TextStyle(color: hint)),
          value: o.clockOutReminder,
          onChanged: _busy
              ? null
              : (v) => _save(
                  () => widget.api.updateOptions(clockOutReminder: v),
                  v ? tr('퇴근 알림을 켰습니다.') : tr('퇴근 알림을 껐습니다.'),
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(tr('출근 알림 시각')),
              const SizedBox(width: 12),
              DropdownButton<int>(
                key: const ValueKey('gw-reminder-delay'),
                value:
                    const [
                      0,
                      5,
                      10,
                      15,
                      30,
                      60,
                    ].contains(o.reminderDelayMinutes)
                    ? o.reminderDelayMinutes
                    : 10,
                items: [
                  for (final m in const [0, 5, 10, 15, 30, 60])
                    DropdownMenuItem(
                      value: m,
                      child: Text(
                        m == 0 ? tr('근무 시작') : tr('근무 시작 {m}분 뒤', {'m': m}),
                      ),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (v) => _save(
                        () => widget.api.updateOptions(reminderDelayMinutes: v),
                        tr('출근 알림 시각을 바꿨습니다.'),
                      ),
              ),
            ],
          ),
        ),
        ..._overtimeGuardPart(o, hint),
        ..._leaveBasisPart(o, hint),
        ..._payRatesPart(o, hint),
        ..._locationPart(o, hint),
      ],
    );
  }

  /// 주 52시간 지키기 — 알리기만·결재를 받게·막기와 고른 방식의 설명.
  List<Widget> _overtimeGuardPart(GroupwareOptions o, Color hint) => [
    GroupwareSectionHeader(tr('주 52시간 지키기')),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SegmentedButton<String>(
          key: const ValueKey('gw-overtime-guard'),
          segments: [
            for (final g in const ['warn', 'approval', 'block'])
              ButtonSegment(value: g, label: Text(overtimeGuardLabel(g))),
          ],
          selected: {o.overtimeGuard},
          onSelectionChanged: _busy
              ? null
              : (s) => _save(
                  () => widget.api.updateOptions(overtimeGuard: s.first),
                  tr('주 52시간 지키기를 "{p0}"(으)로 바꿨습니다.', {
                    'p0': overtimeGuardLabel(s.first),
                  }),
                ),
        ),
      ),
    ),
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Text(
        overtimeGuardHelp(o.overtimeGuard),
        key: const ValueKey('gw-overtime-guard-help'),
        style: TextStyle(fontSize: 12, color: hint),
      ),
    ),
  ];

  /// 연차 기준(입사일·회계연도)·회계연도 시작 달, 연차 이월 일수와 "연차 이월" 단추.
  List<Widget> _leaveBasisPart(GroupwareOptions o, Color hint) {
    final warn = Theme.of(context).colorScheme.error;
    return [
      GroupwareSectionHeader(tr('연차 기준·이월')),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(tr('연차 기준')),
            SegmentedButton<String>(
              key: const ValueKey('gw-leave-basis'),
              segments: [
                ButtonSegment(value: 'hire', label: Text(tr('입사일'))),
                ButtonSegment(value: 'fiscal', label: Text(tr('회계연도'))),
              ],
              selected: {o.leaveBasis},
              onSelectionChanged: _busy ? null : (s) => _changeBasis(s.first),
            ),
            if (o.leaveBasis == 'fiscal')
              DropdownButton<int>(
                key: const ValueKey('gw-fiscal-month'),
                value: o.fiscalStartMonth.clamp(1, 12),
                items: [
                  for (var m = 1; m <= 12; m++)
                    DropdownMenuItem(
                      value: m,
                      child: Text(tr('{m}월 1일 시작', {'m': m})),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (v) => v == null ? null : _changeFiscalMonth(v),
              ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        child: Text(
          [
            tr('기준을 바꾸면 모두의 이번 연차 기간·남은 연차·촉진 일정이 새 기준으로 다시 계산됩니다.'),
            if (o.leaveBasis == 'fiscal')
              tr(
                '회계연도 기준은 퇴사할 때 입사일 기준으로 다시 셈해, 입사일 기준보다 적게 생겼으면 모자란 만큼 정산(수당)해야 합니다.',
              ),
          ].join(' '),
          key: const ValueKey('gw-leave-basis-note'),
          style: TextStyle(fontSize: 12, color: warn),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(tr('연차 이월')),
            DropdownButton<int>(
              key: const ValueKey('gw-carry-days'),
              value: o.carryOverMaxDays,
              items: [
                for (final d in {
                  ..._carryDayChoices,
                  o.carryOverMaxDays,
                }.toList()..sort())
                  DropdownMenuItem(
                    value: d,
                    child: Text(d == 0 ? tr('하지 않음') : tr('{d}일까지', {'d': d})),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (v) => v == null
                        ? null
                        : _save(
                            () => widget.api.updateOptions(carryOverMaxDays: v),
                            v == 0
                                ? tr('연차 이월을 껐습니다.')
                                : tr('연차 이월을 {v}일까지로 정했습니다.', {'v': v}),
                          ),
            ),
            FilledButton.tonal(
              key: const ValueKey('gw-carry-run'),
              onPressed: _busy || o.carryOverMaxDays <= 0
                  ? null
                  : _runCarryOver,
              child: Text(tr('연차 이월')),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        child: Text(
          tr(
            '지난 연차 기간 끝에 남은 연차를 정한 일수까지 이번 기간에 더합니다(사람마다 기간에 한 번 — 미리 보고 확인). 법정 의무는 아니고 회사가 정하는 것입니다.',
          ),
          style: TextStyle(fontSize: 12, color: hint),
        ),
      ),
    ];
  }

  /// 가산율(%) — 연장·야간·휴일(8시간까지)·휴일 8시간 넘는 부분, 5명 미만 사업장. 가산 수당(참고용) 계산에만 쓴다.
  List<Widget> _payRatesPart(GroupwareOptions o, Color hint) {
    Widget field(TextEditingController c, String label, String key) => SizedBox(
      width: 130,
      child: TextField(
        key: ValueKey(key),
        controller: c,
        enabled: !_smallBusiness,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: label,
          suffixText: '%',
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
    return [
      GroupwareSectionHeader(tr('가산율(가산 수당 참고용)')),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            field(_payOvertime, tr('연장'), 'gw-pay-overtime'),
            field(_payNight, tr('야간'), 'gw-pay-night'),
            field(_payHoliday, tr('휴일 8시간까지'), 'gw-pay-holiday'),
            field(_payHolidayOver, tr('휴일 8시간 넘게'), 'gw-pay-holiday-over'),
            FilledButton(
              key: const ValueKey('gw-pay-save'),
              onPressed: _busy ? null : _savePayRates,
              child: Text(tr('저장')),
            ),
          ],
        ),
      ),
      SwitchListTile(
        key: const ValueKey('gw-pay-small-business'),
        dense: true,
        title: Text(tr('상시 5명 미만 사업장')),
        subtitle: Text(
          tr('가산 수당을 셈하지 않습니다(근로기준법 제56조가 적용되지 않음). 저장을 눌러야 바뀝니다.'),
          style: TextStyle(color: hint),
        ),
        value: _smallBusiness,
        onChanged: _busy ? null : (v) => setState(() => _smallBusiness = v),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          tr(
            '법정 최저(상시 5명 이상): 연장 50% · 야간(22시~6시) 50% · 휴일 8시간까지 50% · 8시간 넘는 부분 100%. 이보다 낮게는 저장되지 않습니다. 통상시급은 아래 "구성원 연차"에서 사람마다 넣습니다.',
          ),
          style: TextStyle(fontSize: 12, color: hint),
        ),
      ),
    ];
  }

  /// 출퇴근 위치 — 사무실 위치(위도·경도·반경 — 사무실 출근 때 거리를 잰다)와 외근 위치 필수.
  List<Widget> _locationPart(GroupwareOptions o, Color hint) {
    Widget field(
      TextEditingController c,
      String label,
      String key, {
      double width = 150,
      String? suffix,
    }) => SizedBox(
      width: width,
      child: TextField(
        key: ValueKey(key),
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(
          decimal: true,
          signed: true,
        ),
        decoration: InputDecoration(
          labelText: label,
          suffixText: suffix,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
    final office = o.officeLocation;
    return [
      GroupwareSectionHeader(tr('출퇴근 위치')),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          office == null
              ? tr('사무실 위치를 정하지 않았습니다 — 사무실 출근의 거리를 재지 않습니다.')
              : tr(
                  '사무실 위도 {lat}, 경도 {lng} · 반경 {r}m — 사무실 출근인데 반경 밖이면 기록에 표시합니다.',
                  {'lat': office.lat, 'lng': office.lng, 'r': office.radius},
                ),
          key: const ValueKey('gw-office-status'),
          style: TextStyle(fontSize: 12, color: hint),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            field(_officeLat, tr('위도'), 'gw-office-lat'),
            field(_officeLng, tr('경도'), 'gw-office-lng'),
            field(
              _officeRadius,
              tr('반경'),
              'gw-office-radius',
              width: 110,
              suffix: 'm',
            ),
            FilledButton(
              key: const ValueKey('gw-office-save'),
              onPressed: _busy ? null : _saveOffice,
              child: Text(tr('저장')),
            ),
            if (office != null)
              TextButton(
                key: const ValueKey('gw-office-clear'),
                onPressed: _busy ? null : _clearOffice,
                child: Text(tr('지우기')),
              ),
          ],
        ),
      ),
      SwitchListTile(
        key: const ValueKey('gw-require-field-location'),
        dense: true,
        title: Text(tr('외근은 위치를 보내야 출근')),
        subtitle: Text(
          tr(
            '외근 출근 때 기기 위치(GPS)를 꼭 받습니다. 위치를 못 보내는 기기(PC 등)는 외근 출근을 할 수 없습니다.',
          ),
          style: TextStyle(color: hint),
        ),
        value: o.requireFieldLocation,
        onChanged: _busy
            ? null
            : (v) => _save(
                () => widget.api.updateOptions(requireFieldLocation: v),
                v ? tr('외근은 위치를 받습니다.') : tr('외근 위치를 받지 않습니다.'),
              ),
      ),
    ];
  }
}

/// 연차 이월 미리 보기 — 넣을 사람(양·지난 기간)과 건너뛸 사람(까닭). 넣을 사람이 없으면 확인 단추가 꺼진다.
class _CarryOverPreviewDialog extends StatelessWidget {
  final CarryOverResult preview;
  const _CarryOverPreviewDialog({required this.preview});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return AlertDialog(
      title: Text(tr('연차 이월 미리 보기')),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tr('지난 기간에 남은 연차를 {d}일까지 이번 기간에 더합니다.', {'d': preview.capDays}),
                style: TextStyle(fontSize: 12, color: hint),
              ),
              const SizedBox(height: 8),
              Text(
                tr('넣을 사람 {n}명', {'n': preview.applied.length}),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (preview.applied.isEmpty)
                Text(tr('없음'), style: TextStyle(color: hint)),
              for (final a in preview.applied)
                ListTile(
                  key: ValueKey('gw-carry-applied-${a.userId}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(a.name),
                  subtitle: a.from == null || a.to == null
                      ? null
                      : Text(
                          tr('{from}~{to} 기간에서', {'from': a.from, 'to': a.to}),
                        ),
                  trailing: Text('+${halfDaysText(a.halfDays)}'),
                ),
              if (preview.skipped.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  tr('건너뛸 사람 {n}명', {'n': preview.skipped.length}),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                for (final s in preview.skipped)
                  ListTile(
                    key: ValueKey('gw-carry-skipped-${s.userId}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(s.name),
                    subtitle: Text(trServer(s.reason)),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('gw-carry-confirm'),
          onPressed: preview.applied.isEmpty
              ? null
              : () => Navigator.of(context).pop(true),
          child: Text(tr('이월하기')),
        ),
      ],
    );
  }
}

class _LeaveTypesDialog extends StatefulWidget {
  final List<LeaveTypeInfo> types;
  const _LeaveTypesDialog({required this.types});

  @override
  State<_LeaveTypesDialog> createState() => _LeaveTypesDialogState();
}

class _LeaveTypeDraft {
  final String? key;
  final bool builtin;
  final bool half;
  final TextEditingController label;
  bool enabled;
  bool deducts;
  _LeaveTypeDraft({
    required this.key,
    required this.builtin,
    required this.half,
    required String label,
    required this.enabled,
    required this.deducts,
  }) : label = TextEditingController(text: label);
}

class _LeaveTypesDialogState extends State<_LeaveTypesDialog> {
  late final _drafts = [
    for (final t in widget.types)
      _LeaveTypeDraft(
        key: t.key,
        builtin: t.builtin,
        half: t.half,
        label: t.label,
        enabled: t.enabled,
        deducts: t.deducts,
      ),
  ];
  String? _error;

  @override
  void dispose() {
    for (final d in _drafts) {
      d.label.dispose();
    }
    super.dispose();
  }

  void _save() {
    final out = <LeaveTypeInfo>[];
    for (final d in _drafts) {
      final label = d.label.text.trim();
      if (label.isEmpty) {
        setState(() => _error = tr('휴가 종류 이름을 넣으세요.'));
        return;
      }
      out.add(
        LeaveTypeInfo(
          key: d.key ?? '',
          label: label,
          deducts: d.deducts,
          half: d.half,
          enabled: d.enabled,
          builtin: d.builtin,
        ),
      );
    }
    Navigator.of(context).pop(out);
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return AlertDialog(
      title: Text(tr('휴가 종류')),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tr(
                  '끈 종류는 새로 신청할 수 없고(연차는 끌 수 없음), 이미 올린 신청은 그때 이름 그대로 남습니다. 더한 종류는 하루 단위이고 연차에서 뺄지 고릅니다.',
                ),
                style: TextStyle(fontSize: 12, color: hint),
              ),
              const SizedBox(height: 8),
              for (final (i, d) in _drafts.indexed)
                Row(
                  key: ValueKey('gw-leave-type-$i'),
                  children: [
                    Expanded(
                      child: TextField(
                        key: ValueKey('gw-leave-type-$i-label'),
                        controller: d.label,
                        maxLength: 20,
                        decoration: InputDecoration(
                          isDense: true,
                          counterText: '',
                          helperText: d.builtin ? null : tr('더한 종류'),
                        ),
                      ),
                    ),
                    if (!d.builtin)
                      Column(
                        children: [
                          Text(tr('연차 차감'), style: TextStyle(fontSize: 11)),
                          Checkbox(
                            key: ValueKey('gw-leave-type-$i-deducts'),
                            value: d.deducts,
                            onChanged: (v) =>
                                setState(() => d.deducts = v ?? false),
                          ),
                        ],
                      ),
                    Switch(
                      key: ValueKey('gw-leave-type-$i-enabled'),
                      value: d.enabled,
                      onChanged: d.key == 'annual'
                          ? null
                          : (v) => setState(() => d.enabled = v),
                    ),
                  ],
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('gw-leave-type-add'),
                  onPressed: () => setState(
                    () => _drafts.add(
                      _LeaveTypeDraft(
                        key: null,
                        builtin: false,
                        half: false,
                        label: '',
                        enabled: true,
                        deducts: false,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(tr('종류 더하기')),
                ),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('gw-leave-types-save'),
          onPressed: _save,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}

class _CategoriesDialog extends StatefulWidget {
  final List<String> categories;
  const _CategoriesDialog({required this.categories});

  @override
  State<_CategoriesDialog> createState() => _CategoriesDialogState();
}

class _CategoriesDialogState extends State<_CategoriesDialog> {
  late final _list = [...widget.categories];
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _add() {
    final v = _input.text.trim();
    if (v.isEmpty || _list.contains(v)) return;
    setState(() {
      _list.add(v);
      _input.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('지출 분류')),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final c in _list)
                  InputChip(
                    key: ValueKey('gw-category-$c'),
                    label: Text(c),
                    onDeleted: _list.length <= 1
                        ? null
                        : () => setState(() => _list.remove(c)),
                  ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('gw-category-input'),
                    controller: _input,
                    maxLength: 20,
                    decoration: InputDecoration(
                      labelText: tr('분류 더하기'),
                      counterText: '',
                    ),
                    onSubmitted: (_) => _add(),
                  ),
                ),
                IconButton(
                  key: const ValueKey('gw-category-add'),
                  tooltip: tr('더하기'),
                  icon: const Icon(Icons.add),
                  onPressed: _add,
                ),
              ],
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
          key: const ValueKey('gw-categories-save'),
          onPressed: () => Navigator.of(context).pop(_list),
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}

// ── 유연근무 ─────────────────────────────────────────────────────────────

class WorkSchedulesSection extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  const WorkSchedulesSection({super.key, required this.api, required this.ctx});

  @override
  State<WorkSchedulesSection> createState() => _WorkSchedulesSectionState();
}

class _WorkSchedulesSectionState extends State<WorkSchedulesSection> {
  List<MemberSchedule>? _members;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final m = await widget.api.schedules();
      if (mounted) setState(() => _members = m);
    } catch (_) {}
  }

  Future<void> _edit(MemberSchedule m) async {
    final result = await showDialog<Object>(
      context: context,
      builder: (_) => _ScheduleDialog(member: m, ctx: widget.ctx),
    );
    if (result == null || !mounted) return;
    try {
      if (result == 'default') {
        await widget.api.clearSchedule(m.userId);
      } else {
        final r = result as _ScheduleResult;
        await widget.api.setSchedule(
          m.userId,
          mode: r.mode,
          start: r.start,
          end: r.end,
          coreStart: r.coreStart,
          coreEnd: r.coreEnd,
          periodType: r.periodType,
          periodStart: r.periodStart,
          periodMonths: r.periodMonths,
        );
      }
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    }
  }

  /// 목록 한 줄의 기간 — "탄력 2주 2026-10-12부터" / "선택근무 정산 3개월 2026-10-01부터".
  String _periodText(WorkSchedule s) {
    final label =
        s.periodLabel ?? workPeriodTypeLabels[s.periodType] ?? s.periodType!;
    final months = s.periodType == 'select' && s.periodMonths != null
        ? tr(' {n}개월', {'n': s.periodMonths})
        : '';
    return s.periodStart == null
        ? '$label$months'
        : tr('{label}{months} {start}부터', {
            'label': label,
            'months': months,
            'start': s.periodStart,
          });
  }

  @override
  Widget build(BuildContext context) {
    final members = _members;
    final hint = Theme.of(context).hintColor;
    if (members == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupwareSectionHeader(tr('유연근무')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            tr(
              '사람마다 근무 형태를 정합니다 — 시차출퇴근(자기 출근·퇴근 시각), 선택근무(핵심 시간대만 지각·조퇴), 자율 출퇴근(지각·조퇴를 세지 않음). 정하지 않으면 위 근무 시간입니다.',
            ),
            style: TextStyle(fontSize: 12, color: hint),
          ),
        ),
        for (final m in members)
          ListTile(
            key: ValueKey('gw-schedule-${m.userId}'),
            dense: true,
            title: Text(m.name),
            subtitle: Text(
              [
                m.schedule?.description ??
                    tr('기본 {p0}~{p1}', {
                      'p0': minutesText(widget.ctx.workStart),
                      'p1': minutesText(widget.ctx.workEnd),
                    }),
                if (m.schedule?.periodType != null) _periodText(m.schedule!),
              ].join(' · '),
              style: TextStyle(color: hint),
            ),
            trailing: const Icon(Icons.edit_outlined, size: 18),
            onTap: () => _edit(m),
          ),
      ],
    );
  }
}

class _ScheduleDialog extends StatefulWidget {
  final MemberSchedule member;
  final GroupwareContext ctx;
  const _ScheduleDialog({required this.member, required this.ctx});

  @override
  State<_ScheduleDialog> createState() => _ScheduleDialogState();
}

/// 근무 형태 창의 결과 — 형태·시각과 탄력·선택근무 정산 기간(없으면 null — 주 단위).
typedef _ScheduleResult = ({
  String mode,
  String? start,
  String? end,
  String? coreStart,
  String? coreEnd,
  String? periodType,
  String? periodStart,
  int? periodMonths,
});

class _ScheduleDialogState extends State<_ScheduleDialog> {
  late String _mode = widget.member.schedule?.mode ?? 'staggered';

  /// 탄력적 근로시간제·선택근무 정산 기간 — 종류(null이면 주 단위)·시작하는 날·선택근무 정산 개월(1 | 3).
  late String? _periodType = widget.member.schedule?.periodType;
  late String? _periodStart = widget.member.schedule?.periodStart;
  late int _periodMonths = widget.member.schedule?.periodMonths == 3 ? 3 : 1;
  late final _start = TextEditingController(
    text: minutesText(widget.member.schedule?.start ?? widget.ctx.workStart),
  );
  late final _end = TextEditingController(
    text: minutesText(widget.member.schedule?.end ?? widget.ctx.workEnd),
  );
  late final _coreStart = TextEditingController(
    text: minutesText(widget.member.schedule?.coreStart ?? 10 * 60),
  );
  late final _coreEnd = TextEditingController(
    text: minutesText(widget.member.schedule?.coreEnd ?? 15 * 60),
  );
  String? _error;

  @override
  void dispose() {
    for (final c in [_start, _end, _coreStart, _coreEnd]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (_mode == 'staggered' &&
        (!isHmText(_start.text) || !isHmText(_end.text))) {
      setState(() => _error = tr('출근·퇴근 시각을 HH:MM으로 넣으세요.'));
      return;
    }
    if (_mode == 'core' &&
        (!isHmText(_coreStart.text) || !isHmText(_coreEnd.text))) {
      setState(() => _error = tr('핵심 시간대를 HH:MM으로 넣으세요.'));
      return;
    }
    final periodType = _periodTypeFor(_mode);
    if (periodType != null && _periodStart == null) {
      setState(() => _error = tr('기간이 시작하는 날을 정하세요.'));
      return;
    }
    final _ScheduleResult result = (
      mode: _mode,
      start: _mode == 'staggered' ? _start.text.trim() : null,
      end: _mode == 'staggered' ? _end.text.trim() : null,
      coreStart: _mode == 'core' ? _coreStart.text.trim() : null,
      coreEnd: _mode == 'core' ? _coreEnd.text.trim() : null,
      periodType: periodType,
      periodStart: periodType == null ? null : _periodStart,
      periodMonths: periodType == 'select' ? _periodMonths : null,
    );
    Navigator.of(context).pop(result);
  }

  /// 이 근무 형태에서 쓸 수 있는 기간 종류 — 선택근무 정산은 선택근무·자율 출퇴근에만(서버 workRules.js parsePeriod).
  static List<String> _periodTypesFor(String mode) => [
    'flex2w',
    'flex3m',
    if (mode == 'core' || mode == 'free') 'select',
  ];

  /// 고른 기간 종류가 지금 형태에서 안 되면(시차출퇴근으로 바꿨는데 선택근무 정산) 주 단위로.
  String? _periodTypeFor(String mode) =>
      _periodTypesFor(mode).contains(_periodType) ? _periodType : null;

  Future<void> _pickPeriodStart() async {
    final today = DateTime.parse(widget.ctx.today);
    final picked = await showDatePicker(
      context: context,
      initialDate: _periodStart == null ? today : DateTime.parse(_periodStart!),
      firstDate: DateTime(today.year - 2),
      lastDate: DateTime(today.year + 2),
      helpText: tr('기간이 시작하는 날'),
    );
    if (picked != null && mounted) {
      setState(() => _periodStart = dateKeyOf(picked));
    }
  }

  /// 기간 종류 고르기·시작하는 날·선택근무 정산 개월과 설명.
  List<Widget> _periodPart(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final type = _periodTypeFor(_mode);
    return [
      const SizedBox(height: 16),
      Row(
        children: [
          Text(tr('근로시간 기간')),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButton<String?>(
              key: const ValueKey('gw-schedule-period-type'),
              isExpanded: true,
              value: type,
              items: [
                DropdownMenuItem<String?>(
                  value: null,
                  child: Text(tr('주 단위(주 52시간)')),
                ),
                for (final t in _periodTypesFor(_mode))
                  DropdownMenuItem<String?>(
                    value: t,
                    child: Text(workPeriodTypeLabels[t] ?? t),
                  ),
              ],
              onChanged: (v) => setState(() => _periodType = v),
            ),
          ),
        ],
      ),
      if (type != null) ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('gw-schedule-period-start'),
              onPressed: _pickPeriodStart,
              icon: const Icon(Icons.event, size: 18),
              label: Text(
                _periodStart == null
                    ? tr('시작하는 날 고르기')
                    : tr('{d}부터', {'d': _periodStart}),
              ),
            ),
            if (type == 'select')
              SegmentedButton<int>(
                key: const ValueKey('gw-schedule-period-months'),
                segments: [
                  ButtonSegment(value: 1, label: Text(tr('1개월'))),
                  ButtonSegment(value: 3, label: Text(tr('3개월'))),
                ],
                selected: {_periodMonths},
                onSelectionChanged: (s) =>
                    setState(() => _periodMonths = s.first),
              ),
          ],
        ),
      ],
      const SizedBox(height: 6),
      Text(switch (type) {
        'flex2w' => tr(
          '2주 평균 주 40시간 — 한 주는 연장 포함 60시간(48시간 + 연장 12시간)까지. 취업규칙(또는 서면 합의)이 필요합니다.',
        ),
        'flex3m' => tr(
          '3개월 평균 주 40시간 — 한 주는 연장 포함 64시간(52시간 + 연장 12시간)까지. 근로자대표와 서면 합의가 필요합니다.',
        ),
        'select' => tr(
          '정산 기간(1개월, 신상품·연구개발은 3개월) 평균 주 40시간 — 주마다 상한을 보지 않고 기간 전체로 봅니다. 근로자대표와 서면 합의가 필요합니다.',
        ),
        _ => tr('주마다 주 52시간(연장 12시간)으로 봅니다.'),
      }, style: TextStyle(fontSize: 12, color: hint)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    Widget times(
      TextEditingController a,
      TextEditingController b,
      String la,
      String lb,
      String key,
    ) => Row(
      children: [
        Expanded(
          child: TextField(
            key: ValueKey('$key-a'),
            controller: a,
            decoration: InputDecoration(labelText: la, isDense: true),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Text('~'),
        ),
        Expanded(
          child: TextField(
            key: ValueKey('$key-b'),
            controller: b,
            decoration: InputDecoration(labelText: lb, isDense: true),
          ),
        ),
      ],
    );
    return AlertDialog(
      title: Text(
        tr('{widget.member.name} 근무 형태', {
          'widget.member.name': widget.member.name,
        }),
      ),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<String>(
                key: const ValueKey('gw-schedule-mode'),
                segments: [
                  ButtonSegment(value: 'staggered', label: Text(tr('시차출퇴근'))),
                  ButtonSegment(value: 'core', label: Text(tr('선택근무'))),
                  ButtonSegment(value: 'free', label: Text(tr('자율'))),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
              const SizedBox(height: 12),
              if (_mode == 'staggered')
                times(
                  _start,
                  _end,
                  tr('출근 (HH:MM)'),
                  tr('퇴근 (HH:MM)'),
                  'gw-schedule-hours',
                ),
              if (_mode == 'core')
                times(
                  _coreStart,
                  _coreEnd,
                  tr('핵심 시작'),
                  tr('핵심 끝'),
                  'gw-schedule-core',
                ),
              if (_mode == 'free')
                Text(tr('지각·조퇴를 세지 않습니다. 근로시간(주 52시간)은 그대로 셉니다.')),
              ..._periodPart(context),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.member.schedule != null)
          TextButton(
            key: const ValueKey('gw-schedule-default'),
            onPressed: () => Navigator.of(context).pop('default'),
            child: Text(tr('기본으로')),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('gw-schedule-save'),
          onPressed: _save,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}

// ── 주 52시간 ─────────────────────────────────────────────────────────────

class WeeklyHoursSection extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  const WeeklyHoursSection({super.key, required this.api, required this.ctx});

  @override
  State<WeeklyHoursSection> createState() => _WeeklyHoursSectionState();
}

class _WeeklyHoursSectionState extends State<WeeklyHoursSection> {
  late String _day = widget.ctx.today;
  ({String weekStart, String weekEnd, List<WeeklyMember> members})? _week;

  /// 범위의 주 52시간 지키기 방식(설정에서 — 못 받으면 null, 머리 줄을 숨긴다).
  String? _guard;

  @override
  void initState() {
    super.initState();
    _load();
    _loadGuard();
  }

  Future<void> _load() async {
    try {
      final w = await widget.api.weekly(_day);
      if (mounted) setState(() => _week = w);
    } catch (_) {}
  }

  /// 주 52시간 지키기 방식은 범위 설정에서 받는다(주 현황 응답의 overtimeGuard는 GroupwareApi.weekly가 아직 넘기지 않는다).
  Future<void> _loadGuard() async {
    try {
      final o = await widget.api.options();
      if (mounted) setState(() => _guard = o.overtimeGuard);
    } catch (_) {}
  }

  /// 시간(분) → "52시간" / "45.5시간"(상한·기준 표시용).
  static String _hours(int minutes) => minutes % 60 == 0
      ? tr('{h}시간', {'h': minutes ~/ 60})
      : tr('{h}시간', {'h': (minutes / 60).toStringAsFixed(1)});

  /// 이 사람의 상태 글 — 상한이 있으면 "52시간 넘음"/"48시간 넘음"(상한 4시간 전부터, 서버와 같다), 선택근무(상한 없음)는 정산 기간 기준.
  static String? _statusText(WeeklyMember m) {
    final status = m.hours.status;
    if (status == 'ok') return null;
    final limit = m.weeklyLimitMinutes;
    if (limit == null) {
      return status == 'over' ? tr('정산 기간 한도 넘음') : tr('정산 기간 한도 가까움');
    }
    return tr('{h}시간 넘음', {
      'h': status == 'over' ? limit ~/ 60 : (limit - 4 * 60) ~/ 60,
    });
  }

  /// 그 주가 든 탄력·선택근무 기간 한 줄 — "탄력 2주 10/12~10/25: 실근로 70시간 / 기준 80시간 · 연장 0시간(한도 24시간)".
  static String _periodLine(WeeklyMember m) {
    final p = m.period!;
    final label = workPeriodTypeLabels[p.type] ?? p.type;
    return tr('{label} {from}~{to}: 실근로 {net} / 기준 {std} · 연장 {ot}(한도 {cap})', {
      'label': label,
      'from': shortDateText(p.start),
      'to': shortDateText(p.lastDay),
      'net': durationText(p.netMinutes),
      'std': _hours(p.standardMinutes),
      'ot': durationText(p.overtimeMinutes),
      'cap': _hours(p.overtimeCapMinutes),
    });
  }

  void _shift(int weeks) {
    final next = DateTime.parse(_day).add(Duration(days: 7 * weeks));
    final limit = DateTime.parse(widget.ctx.today).add(const Duration(days: 6));
    if (next.isAfter(limit)) return;
    _day = dateKeyOf(next);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final w = _week;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupwareSectionHeader(
          tr('주 52시간'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: tr('지난주'),
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _shift(-1),
              ),
              Text(
                w == null
                    ? ''
                    : '${shortDateText(w.weekStart)}~${shortDateText(w.weekEnd)}',
                key: const ValueKey('gw-weekly-range'),
              ),
              IconButton(
                tooltip: tr('다음 주'),
                icon: const Icon(Icons.chevron_right),
                onPressed: () => _shift(1),
              ),
            ],
          ),
        ),
        if (_guard != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              tr('주 52시간 지키기: {label} — {help}', {
                'label': overtimeGuardLabel(_guard!),
                'help': overtimeGuardHelp(_guard!),
              }),
              key: const ValueKey('gw-weekly-guard'),
              style: TextStyle(fontSize: 12, color: theme.hintColor),
            ),
          ),
        if (w != null)
          for (final m in w.members)
            ListTile(
              key: ValueKey('gw-weekly-${m.userId}'),
              dense: true,
              isThreeLine: m.period != null,
              title: Text(m.name),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    [
                      m.weeklyLimitMinutes == null
                          ? tr('실근로 {p0} · 선택근무 — 기간 기준', {
                              'p0': durationText(m.hours.netMinutes),
                            })
                          : tr('실근로 {p0} / {p1}', {
                              'p0': durationText(m.hours.netMinutes),
                              'p1': _hours(m.weeklyLimitMinutes!),
                            }),
                      if (m.hours.overtimeMinutes > 0)
                        tr('연장 {p0}', {
                          'p0': durationText(m.hours.overtimeMinutes),
                        }),
                      if (m.hours.holidayMinutes > 0)
                        tr('휴일 {p0}', {
                          'p0': durationText(m.hours.holidayMinutes),
                        }),
                      if (m.hours.nightMinutes > 0)
                        tr('야간 {p0}', {
                          'p0': durationText(m.hours.nightMinutes),
                        }),
                    ].join(' · '),
                  ),
                  if (m.period != null)
                    Text(
                      _periodLine(m),
                      key: ValueKey('gw-weekly-period-${m.userId}'),
                      style: TextStyle(
                        fontSize: 12,
                        color: switch (m.period!.status) {
                          'over' => theme.colorScheme.error,
                          'warn' => Colors.orange.shade800,
                          _ => theme.hintColor,
                        },
                      ),
                    ),
                ],
              ),
              trailing: _statusText(m) == null
                  ? null
                  : Text(
                      _statusText(m)!,
                      style: TextStyle(
                        color: m.hours.status == 'over'
                            ? theme.colorScheme.error
                            : Colors.orange.shade800,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
      ],
    );
  }
}

// ── 연차 사용 촉진 ───────────────────────────────────────────────────────

class LeavePromotionSection extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final GroupwareChanges changes;
  const LeavePromotionSection({
    super.key,
    required this.api,
    required this.ctx,
    required this.changes,
  });

  @override
  State<LeavePromotionSection> createState() => _LeavePromotionSectionState();
}

class _LeavePromotionSectionState extends State<LeavePromotionSection> {
  List<PromotionMember>? _members;
  final _selected = <String>{};
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
      final m = await widget.api.promotions();
      if (mounted) {
        setState(() {
          _members = m;
          _selected.removeWhere(
            (id) => !m.any(
              (x) => x.userId == id && x.stage == PromotionStage.first,
            ),
          );
        });
      }
    } catch (_) {}
  }

  Future<void> _sendFirst() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('1차 촉진 보내기')),
        content: Text(
          tr(
            '{_selected.length}명에게 남은 연차를 알리고 10일 안에 쓸 날을 내라고 요구합니다. 보낸 기록은 지워지지 않습니다.',
            {'_selected.length': _selected.length},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('취소')),
          ),
          FilledButton(
            key: const ValueKey('gw-promotion-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('보내기')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await widget.api.sendPromotion(_selected.toList());
      if (!mounted) return;
      showAppToast(
        context,
        tr('{r.sent}명에게 보냈습니다.{p0}', {
          'r.sent': r.sent,
          'p0': r.skipped.isEmpty
              ? ''
              : tr(' ({r.skipped.length}명 건너뜀: {r.skipped.first})', {
                  'r.skipped.length': r.skipped.length,
                  'r.skipped.first': r.skipped.first,
                }),
        }),
      );
      _selected.clear();
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendSecond(PromotionMember m) async {
    final dates = await showLeaveDatesDialog(
      context,
      title: tr('{m.name} — 회사가 정할 연차 날', {'m.name': m.name}),
      from: dateKeyOf(
        DateTime.parse(widget.ctx.today).add(const Duration(days: 1)),
      ),
      to: m.expiry,
      maxDays: m.remainingHalfDays ~/ 2,
    );
    if (dates == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.sendSecondPromotion(m.userId, dates);
      if (mounted) {
        showAppToast(
          context,
          tr('{m.name}님에게 2차 촉진(사용 시기 지정)을 보냈습니다.', {'m.name': m.name}),
        );
      }
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _noticeText(PromotionMember m) {
    final first = m.notices.where((n) => n.stage == 1).firstOrNull;
    final second = m.notices.where((n) => n.stage == 2).firstOrNull;
    return [
      tr('남은 {p0} · 만료 {m.expiry}', {
        'p0': halfDaysText(m.remainingHalfDays),
        'm.expiry': m.expiry,
      }),
      if (first == null && m.stage == PromotionStage.first)
        tr('1차 {m.firstStart}~{m.firstEnd}', {
          'm.firstStart': m.firstStart,
          'm.firstEnd': m.firstEnd,
        }),
      if (first == null && m.stage == PromotionStage.upcoming)
        tr('1차 {m.firstStart}부터', {'m.firstStart': m.firstStart}),
      if (first != null)
        tr('1차 보냄{p0}{p1}', {
          'p0': first.readAt != null ? tr('·확인함') : '',
          'p1': first.planDates.isNotEmpty
              ? tr('·계획 {first.planDates.length}일', {
                  'first.planDates.length': first.planDates.length,
                })
              : '',
        }),
      if (second != null)
        tr('2차 지정 {second.designatedDates.length}일', {
          'second.designatedDates.length': second.designatedDates.length,
        }),
      if (first != null && second == null && first.planDates.isEmpty)
        tr('2차 마감 {m.secondDeadline}', {'m.secondDeadline': m.secondDeadline}),
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final members = _members;
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    if (members == null) return const SizedBox.shrink();
    Color stageColor(PromotionStage s) => switch (s) {
      PromotionStage.first || PromotionStage.second => theme.colorScheme.error,
      PromotionStage.awaiting => Colors.orange.shade800,
      PromotionStage.missed => theme.colorScheme.error.withValues(alpha: 0.6),
      _ => hint,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupwareSectionHeader(
          tr('연차 사용 촉진'),
          trailing: FilledButton(
            key: const ValueKey('gw-promotion-send'),
            onPressed: _busy || _selected.isEmpty ? null : _sendFirst,
            child: Text(
              tr('1차 보내기 ({_selected.length})', {
                '_selected.length': _selected.length,
              }),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            tr(
              '근로기준법 제61조 — 연차 기간 만료 6개월 전(입사 첫해는 3개월 전)을 기준으로 10일 안에 1차(남은 연차를 알리고 쓸 날을 내라고 요구), 받은 사람이 10일 안에 내지 않으면 만료 2개월 전(첫해는 1개월 전)까지 2차(회사가 쓸 날을 정함)를 보냅니다. 보낸·확인한·낸 시각이 남습니다. 전자 통지를 서면으로 인정하는지는 노무 담당과 확인하세요.',
            ),
            style: TextStyle(fontSize: 12, color: hint),
          ),
        ),
        if (members.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              tr('입사일이 있는 구성원이 없습니다.'),
              style: TextStyle(color: hint),
            ),
          ),
        for (final m in members)
          ListTile(
            key: ValueKey('gw-promotion-${m.userId}'),
            dense: true,
            leading: m.stage == PromotionStage.first
                ? Checkbox(
                    key: ValueKey('gw-promotion-select-${m.userId}'),
                    value: _selected.contains(m.userId),
                    onChanged: (v) => setState(
                      () => v == true
                          ? _selected.add(m.userId)
                          : _selected.remove(m.userId),
                    ),
                  )
                : const SizedBox(width: 40),
            title: Row(
              children: [
                Flexible(child: Text(m.name, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 8),
                Text(
                  m.stage.label,
                  style: TextStyle(
                    fontSize: 12,
                    color: stageColor(m.stage),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            subtitle: Text(
              _noticeText(m),
              style: TextStyle(fontSize: 12, color: hint),
            ),
            trailing: m.notices.isEmpty && m.stage != PromotionStage.second
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final n in m.notices) _noticePdfButton(m, n),
                      if (m.stage == PromotionStage.second)
                        TextButton(
                          key: ValueKey('gw-promotion-second-${m.userId}'),
                          onPressed: _busy ? null : () => _sendSecond(m),
                          child: Text(tr('2차 통보')),
                        ),
                    ],
                  ),
          ),
      ],
    );
  }

  /// 보낸 통지 하나의 서면 통지서 — PDF로 저장하거나 인쇄(leave_notice_pdf.dart). 노무 분쟁 때 낼 서면으로 남겨 두려는 것.
  Widget _noticePdfButton(PromotionMember m, LeavePromotion n) =>
      PopupMenuButton<bool>(
        key: ValueKey('gw-notice-pdf-${n.id}'),
        tooltip: tr('{stage}차 통지서', {'stage': n.stage}),
        icon: Badge(
          label: Text('${n.stage}'),
          child: const Icon(Icons.picture_as_pdf_outlined, size: 20),
        ),
        onSelected: (toPrinter) => leaveNoticePdf(
          context,
          notice: n,
          employeeName: m.name,
          scopeLabel: widget.ctx.scopeLabel,
          ctx: widget.ctx,
          print: toPrinter,
        ),
        itemBuilder: (_) => [
          PopupMenuItem(
            key: ValueKey('gw-notice-pdf-save-${n.id}'),
            value: false,
            child: Text(tr('{stage}차 통지서 PDF로 저장', {'stage': n.stage})),
          ),
          PopupMenuItem(
            key: ValueKey('gw-notice-pdf-print-${n.id}'),
            value: true,
            child: Text(tr('{stage}차 통지서 인쇄', {'stage': n.stage})),
          ),
        ],
      );
}
