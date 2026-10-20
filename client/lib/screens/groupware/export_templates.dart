import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/groupware_finance_tools.dart';
import '../../services/groupware_api.dart';
import '../../widgets/app_toast.dart';
import 'finance_widgets.dart';
import '../../l10n/tr.dart';

/// 내보내기 양식(급여 이체 파일·4대보험 취득/상실 신고 파일 — server/src/exportTemplateRules.js) 고르기·만들기. 은행 기업뱅킹의 대량 이체
/// 양식과 4대사회보험 정보연계센터(EDI)의 일괄 신고 엑셀은 곳마다 열이 달라, 받은 양식의 열 순서대로 한 번 만들어 두고 내려받을 때 고른다.

/// 양식 칸 이름.
String exportFieldLabel(String field) => switch (field) {
  'bankCode' => tr('은행코드'),
  'bankName' => tr('은행명'),
  'account' => tr('계좌번호'),
  'holder' => tr('예금주'),
  'amount' => tr('이체금액'),
  'receiverText' => tr('받는 분 통장 표시'),
  'senderText' => tr('내 통장 표시'),
  'name' => tr('이름(성명)'),
  'employeeNo' => tr('사번'),
  'rrn' => tr('주민등록번호'),
  'eventDate' => tr('취득일·상실일'),
  'lastWorkDay' => tr('마지막 근무일'),
  'monthlyPay' => tr('월 소득액(보수월액)'),
  'weeklyHours' => tr('주 소정근로시간'),
  'jobName' => tr('직종'),
  'jobCode' => tr('직종 부호'),
  'pensionCode' => tr('국민연금 부호'),
  'healthCode' => tr('건강보험 부호'),
  'reasonCode' => tr('상실 사유 코드'),
  'reasonLabel' => tr('상실 사유'),
  'yearPay' => tr('해당 연도 보수총액'),
  'yearMonths' => tr('해당 연도 근무 개월 수'),
  'prevYearPay' => tr('전년도 보수총액'),
  'prevYearMonths' => tr('전년도 근무 개월 수'),
  'deadline' => tr('신고 기한'),
  'memo' => tr('메모'),
  'fixed' => tr('고정 값'),
  'blank' => tr('빈 칸'),
  _ => field,
};

String exportKindLabel(String kind) => switch (kind) {
  'transfer' => tr('급여 이체'),
  'acquire' => tr('자격 취득 신고'),
  _ => tr('자격 상실 신고'),
};

/// 양식의 이름 — 기본 양식은 서버 이름 대신 앱 글로.
String exportTemplateName(ExportTemplate t) =>
    t.builtin ? tr('기본(모든 칸)') : t.name;

/// 열 줄 요약("은행코드 · 계좌번호 · 이체금액 …").
String _columnsSummary(ExportTemplate t) {
  final names = [
    for (final c in t.columns)
      c.field == 'fixed'
          ? '"${c.value ?? ''}"'
          : (c.header.isNotEmpty ? c.header : exportFieldLabel(c.field)),
  ];
  final head = names.take(6).join(' · ');
  return names.length > 6 ? '$head …' : head;
}

/// 마지막에 고른 양식(종류마다 — 앱을 켜 둔 동안).
final Map<String, String> _lastPicked = {};

/// 양식을 고른다 — 고른 양식 | null(취소). 양식 만들기·고치기·지우기도 이 창에서 한다. [intro]는 창 위에 보일 글(사람 수·합계 등).
Future<ExportTemplate?> pickExportTemplate(
  BuildContext context, {
  required GroupwareApi api,
  required String kind,
  required String title,
  Widget? intro,
  String okLabel = '',
}) async {
  ExportTemplateSet set;
  try {
    set = await api.exportTemplates();
  } catch (e) {
    if (context.mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    return null;
  }
  if (!context.mounted) return null;
  return showDialog<ExportTemplate>(
    context: context,
    builder: (_) => _PickTemplateDialog(
      api: api,
      kind: kind,
      title: title,
      intro: intro,
      okLabel: okLabel,
      initial: set,
    ),
  );
}

class _PickTemplateDialog extends StatefulWidget {
  final GroupwareApi api;
  final String kind;
  final String title;
  final Widget? intro;
  final String okLabel;
  final ExportTemplateSet initial;
  const _PickTemplateDialog({
    required this.api,
    required this.kind,
    required this.title,
    required this.intro,
    required this.okLabel,
    required this.initial,
  });

  @override
  State<_PickTemplateDialog> createState() => _PickTemplateDialogState();
}

class _PickTemplateDialogState extends State<_PickTemplateDialog> {
  late ExportTemplateSet _set = widget.initial;
  late String? _picked = _initialPick();
  bool _busy = false;

  String? _initialPick() {
    final list = widget.initial.forKind(widget.kind);
    final last = _lastPicked[widget.kind];
    return list.any((t) => t.id == last) ? last : list.firstOrNull?.id;
  }

  Future<void> _save(List<ExportTemplate> templates) async {
    setState(() => _busy = true);
    try {
      final saved = await widget.api.saveExportTemplates(templates);
      if (mounted) setState(() => _set = saved);
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(ExportTemplate? template, {bool copy = false}) async {
    final base =
        template ??
        _set.forKind(widget.kind).where((t) => t.id == _picked).firstOrNull ??
        ExportTemplate(kind: widget.kind, name: '');
    final draft = template != null && !copy
        ? base
        : ExportTemplate(
            kind: widget.kind,
            name: '',
            header: base.header,
            dateFormat: base.dateFormat,
            rrnDash: base.rrnDash,
            fileType: base.fileType,
            columns: base.columns,
          );
    final result = await showDialog<ExportTemplate>(
      context: context,
      builder: (_) => ExportTemplateEditor(
        template: draft,
        fields: _set.fields[widget.kind] ?? const [],
      ),
    );
    if (result == null || !mounted) return;
    final others = _set.templates.where(
      (t) => draft.id == null || t.id != draft.id,
    );
    final before = _set.templates.map((t) => t.id).toSet();
    await _save([...others, result]);
    // 새로 만든 양식을 고른다.
    final added = _set
        .forKind(widget.kind)
        .where((t) => !t.builtin && !before.contains(t.id))
        .firstOrNull;
    if (mounted) {
      setState(() => _picked = added?.id ?? draft.id ?? _picked);
    }
  }

  Future<void> _delete(ExportTemplate t) async {
    final ok = await confirmAction(
      context,
      title: tr('양식 지우기'),
      message: tr('"{name}" 양식을 지울까요?', {'name': t.name}),
      okLabel: tr('지우기'),
      danger: true,
    );
    if (!ok) return;
    await _save(_set.templates.where((x) => x.id != t.id).toList());
    if (mounted && _picked == t.id) {
      setState(() => _picked = _set.forKind(widget.kind).firstOrNull?.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final list = _set.forKind(widget.kind);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ?widget.intro,
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Text(
                  widget.kind == 'transfer'
                      ? tr(
                          '은행 기업뱅킹의 대량 이체 양식에 맞춘 양식을 고르세요. 처음이면 "새 양식"으로 은행에서 받은 양식의 열 순서대로 만듭니다(머리 줄·날짜 모양·엑셀/CSV).',
                        )
                      : tr(
                          '4대사회보험 정보연계센터(EDI)의 일괄 신고 양식에 맞춘 양식을 고르세요. 처음이면 "새 양식"으로 받은 양식의 열 순서대로 만듭니다 — 부호처럼 늘 같은 칸은 "고정 값"으로.',
                        ),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              ),
              RadioGroup<String>(
                groupValue: _picked,
                onChanged: (v) => setState(() => _picked = v),
                child: Column(
                  children: [
                    for (final t in list)
                      RadioListTile<String>(
                        key: ValueKey('export-template-${t.id}'),
                        value: t.id ?? '',
                        contentPadding: EdgeInsets.zero,
                        title: Text(exportTemplateName(t)),
                        subtitle: Text(
                          [
                            t.fileType == 'csv' ? 'CSV' : tr('엑셀'),
                            if (!t.header) tr('머리 줄 없음'),
                            _columnsSummary(t),
                          ].join(' · '),
                          style: const TextStyle(fontSize: 12),
                        ),
                        secondary: t.builtin
                            ? null
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    key: ValueKey(
                                      'export-template-edit-${t.id}',
                                    ),
                                    tooltip: tr('고치기'),
                                    icon: const Icon(Icons.edit_outlined),
                                    onPressed: _busy ? null : () => _edit(t),
                                  ),
                                  IconButton(
                                    tooltip: tr('지우기'),
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: _busy ? null : () => _delete(t),
                                  ),
                                ],
                              ),
                      ),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('export-template-new'),
                  onPressed: _busy ? null : () => _edit(null, copy: true),
                  icon: const Icon(Icons.add),
                  label: Text(tr('새 양식(고른 양식에서 시작)')),
                ),
              ),
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
          key: const ValueKey('export-template-ok'),
          onPressed: _busy || _picked == null
              ? null
              : () {
                  final t = list.where((x) => x.id == _picked).firstOrNull;
                  if (t == null) return;
                  _lastPicked[widget.kind] = t.id!;
                  Navigator.pop(context, t);
                },
          child: Text(widget.okLabel.isEmpty ? tr('받기') : widget.okLabel),
        ),
      ],
    );
  }
}

/// 양식 만들기·고치기 — 이름, 머리 줄, 날짜 모양, 주민등록번호 '-', 엑셀/CSV, 열(칸·머리 글·고정 값 — 순서 바꾸기).
class ExportTemplateEditor extends StatefulWidget {
  final ExportTemplate template;
  final List<String> fields;
  const ExportTemplateEditor({
    super.key,
    required this.template,
    required this.fields,
  });

  @override
  State<ExportTemplateEditor> createState() => _ExportTemplateEditorState();
}

class _ColumnDraft {
  String field;
  final TextEditingController header;
  final TextEditingController value;
  _ColumnDraft(this.field, String header, String? value)
    : header = TextEditingController(text: header),
      value = TextEditingController(text: value ?? '');
  void dispose() {
    header.dispose();
    value.dispose();
  }
}

class _ExportTemplateEditorState extends State<ExportTemplateEditor> {
  late final _name = TextEditingController(text: widget.template.name);
  late bool _header = widget.template.header;
  late String _dateFormat = widget.template.dateFormat;
  late bool _rrnDash = widget.template.rrnDash;
  late String _fileType = widget.template.fileType;
  late final List<_ColumnDraft> _columns = [
    for (final c in widget.template.columns)
      _ColumnDraft(c.field, c.header, c.value),
  ];
  String? _error;

  bool get _insurance => widget.template.kind != 'transfer';

  @override
  void dispose() {
    _name.dispose();
    for (final c in _columns) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = tr('양식 이름을 넣으세요(예: "신한 기업뱅킹 대량이체").'));
      return;
    }
    if (_columns.isEmpty) {
      setState(() => _error = tr('열을 하나 이상 넣으세요.'));
      return;
    }
    Navigator.pop(
      context,
      widget.template.copyWith(
        name: name,
        header: _header,
        dateFormat: _dateFormat,
        rrnDash: _rrnDash,
        fileType: _fileType,
        columns: [
          for (final c in _columns)
            ExportColumn(
              c.field,
              header: c.header.text.trim(),
              value: c.field == 'fixed' ? c.value.text.trim() : null,
            ),
        ],
      ),
    );
  }

  void _move(int i, int delta) {
    final j = i + delta;
    if (j < 0 || j >= _columns.length) return;
    setState(() {
      final c = _columns.removeAt(i);
      _columns.insert(j, c);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fields = widget.fields.isEmpty
        ? {for (final c in _columns) c.field}.toList()
        : widget.fields;
    return AlertDialog(
      title: Text(
        widget.template.id == null
            ? tr('새 양식 — {kind}', {
                'kind': exportKindLabel(widget.template.kind),
              })
            : tr('양식 고치기 — {kind}', {
                'kind': exportKindLabel(widget.template.kind),
              }),
      ),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('export-template-name'),
                controller: _name,
                maxLength: 40,
                decoration: InputDecoration(
                  labelText: tr('양식 이름'),
                  border: const OutlineInputBorder(),
                ),
              ),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SegmentedButton<String>(
                    segments: [
                      ButtonSegment(value: 'xlsx', label: Text(tr('엑셀'))),
                      const ButtonSegment(value: 'csv', label: Text('CSV')),
                    ],
                    selected: {_fileType},
                    onSelectionChanged: (v) =>
                        setState(() => _fileType = v.first),
                  ),
                  DropdownButton<String>(
                    key: const ValueKey('export-template-date'),
                    value: _dateFormat,
                    items: [
                      DropdownMenuItem(
                        value: 'dash',
                        child: Text(tr('날짜 2026-03-02')),
                      ),
                      DropdownMenuItem(
                        value: 'compact',
                        child: Text(tr('날짜 20260302')),
                      ),
                      DropdownMenuItem(
                        value: 'dot',
                        child: Text(tr('날짜 2026.03.02')),
                      ),
                    ],
                    onChanged: (v) => setState(() => _dateFormat = v ?? 'dash'),
                  ),
                ],
              ),
              SwitchListTile(
                key: const ValueKey('export-template-header'),
                contentPadding: EdgeInsets.zero,
                title: Text(tr('첫 줄에 머리 글')),
                subtitle: Text(tr('끄면 첫 줄부터 자료입니다(머리 줄 없이 읽는 양식).')),
                value: _header,
                onChanged: (v) => setState(() => _header = v),
              ),
              if (_insurance)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('주민등록번호에 "-" 넣기')),
                  value: _rrnDash,
                  onChanged: (v) => setState(() => _rrnDash = v),
                ),
              const Divider(),
              Text(
                tr('열(왼쪽부터 차례로)'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < _columns.length; i++)
                Padding(
                  key: ObjectKey(_columns[i]),
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 28,
                        child: Text(
                          _columnLetter(i),
                          style: TextStyle(color: theme.hintColor),
                        ),
                      ),
                      Expanded(
                        flex: 4,
                        child: DropdownButtonFormField<String>(
                          key: ValueKey('export-column-field-$i'),
                          initialValue: _columns[i].field,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            for (final f in fields)
                              DropdownMenuItem(
                                value: f,
                                child: Text(
                                  exportFieldLabel(f),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (v) =>
                              setState(() => _columns[i].field = v ?? 'blank'),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        flex: 3,
                        child: TextField(
                          key: ValueKey('export-column-header-$i'),
                          controller: _columns[i].header,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: tr('머리 글'),
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                      if (_columns[i].field == 'fixed') ...[
                        const SizedBox(width: 6),
                        Expanded(
                          flex: 2,
                          child: TextField(
                            key: ValueKey('export-column-value-$i'),
                            controller: _columns[i].value,
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: tr('값'),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                      IconButton(
                        tooltip: tr('위로'),
                        icon: const Icon(Icons.arrow_upward, size: 18),
                        onPressed: i == 0 ? null : () => _move(i, -1),
                      ),
                      IconButton(
                        tooltip: tr('아래로'),
                        icon: const Icon(Icons.arrow_downward, size: 18),
                        onPressed: i == _columns.length - 1
                            ? null
                            : () => _move(i, 1),
                      ),
                      IconButton(
                        tooltip: tr('빼기'),
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () =>
                            setState(() => _columns.removeAt(i).dispose()),
                      ),
                    ],
                  ),
                ),
              if (_columns.length < 60)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('export-column-add'),
                    onPressed: () => setState(
                      () => _columns.add(_ColumnDraft('blank', '', null)),
                    ),
                    icon: const Icon(Icons.add),
                    label: Text(tr('열 더하기')),
                  ),
                ),
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
          key: const ValueKey('export-template-save'),
          onPressed: _submit,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}

/// 엑셀 열 이름(0 → A, 25 → Z, 26 → AA).
String _columnLetter(int i) {
  var n = i + 1;
  var s = '';
  while (n > 0) {
    final r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

/// 주민등록번호(외국인등록번호) 13자리 — 숫자만 | null.
String? normalizeRrnInput(String text) {
  final d = text.replaceAll(RegExp(r'[\s-]'), '');
  if (!RegExp(r'^\d{13}$').hasMatch(d)) return null;
  final m = int.parse(d.substring(2, 4));
  final day = int.parse(d.substring(4, 6));
  return m >= 1 && m <= 12 && day >= 1 && day <= 31 ? d : null;
}

/// 신고 파일에 넣을 주민등록번호를 사람마다 받는다 — `{ 신고 id: 번호 }` | null(취소). 이 기기·서버 어디에도 남기지 않고 파일에만 쓴다.
Future<Map<String, String>?> askRrns(
  BuildContext context,
  List<({String id, String name})> people,
) => showDialog<Map<String, String>>(
  context: context,
  builder: (_) => _RrnDialog(people: people),
);

class _RrnDialog extends StatefulWidget {
  final List<({String id, String name})> people;
  const _RrnDialog({required this.people});

  @override
  State<_RrnDialog> createState() => _RrnDialogState();
}

class _RrnDialogState extends State<_RrnDialog> {
  late final Map<String, TextEditingController> _c = {
    for (final p in widget.people) p.id: TextEditingController(),
  };
  String? _error;

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final out = <String, String>{};
    for (final p in widget.people) {
      final text = _c[p.id]!.text.trim();
      if (text.isEmpty) continue;
      final v = normalizeRrnInput(text);
      if (v == null) {
        setState(
          () => _error = tr('{name}: 주민등록번호(외국인등록번호) 13자리를 확인하세요.', {
            'name': p.name,
          }),
        );
        return;
      }
      out[p.id] = v;
    }
    Navigator.pop(context, out);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(tr('주민등록번호 넣기')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tr(
                  '고른 양식에 주민등록번호 칸이 있습니다. 넣은 번호는 이번 파일에만 쓰고 서버·이 기기에 남기지 않습니다(비우면 빈칸). 받은 파일은 신고 뒤 지우세요.',
                ),
                style: TextStyle(fontSize: 12, color: theme.hintColor),
              ),
              const SizedBox(height: 8),
              for (final p in widget.people)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    key: ValueKey('rrn-${p.id}'),
                    controller: _c[p.id],
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[\d-]')),
                      LengthLimitingTextInputFormatter(14),
                    ],
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: p.name,
                      hintText: '000000-0000000',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
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
          key: const ValueKey('rrn-ok'),
          onPressed: _submit,
          child: Text(tr('받기')),
        ),
      ],
    );
  }
}
