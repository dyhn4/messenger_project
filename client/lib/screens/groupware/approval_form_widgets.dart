import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import 'approval_forms.dart';
import 'approval_print.dart' show formTableTotalsRow;
import 'groupware_screen.dart' show approvalKindIcon;
import '../../l10n/tr.dart';

/// 양식으로 올리는 결재(서버 approvalForms.js) — 기본 양식(일반 기안서·출장 신청·구매 요청·연장근무 신청)과 관리자가 만든 양식을
/// 같은 칸 그리기로 받는다. 칸 종류: 한 줄 글·여러 줄 글·숫자·금액·날짜·기간·시간대·고르기·품목 표.

// ── 칸 값 모음 ─────────────────────────────────────────────────────────────

/// 신청 창에서 칸마다 넣은 값 — 글 칸은 글자 그대로, 날짜는 'YYYY-MM-DD', 기간·시간대는 {start, end}, 품목 표는 줄 목록.
class FormValues extends ChangeNotifier {
  final ApprovalForm form;
  final Map<String, dynamic> _values = {};
  final attachments =
      <({String url, String name, int size, String? mimeType})>[];
  bool uploading = false;
  FormValues(this.form);

  Object? operator [](String key) => _values[key];
  void set(String key, Object? value) {
    _values[key] = value;
    notifyListeners();
  }

  void touch() => notifyListeners();

  /// 다 안 찼으면 안내 글(올리지 않는다) — 서버가 같은 규칙으로 다시 본다.
  String? validate() {
    for (final f in form.fields) {
      if (!f.required) continue;
      final v = _values[f.key];
      final empty = switch (f.type) {
        FormFieldType.dateRange || FormFieldType.timeRange =>
          v is! Map || (v['start'] ?? '').toString().isEmpty,
        FormFieldType.items =>
          v is! List ||
              !v.any((r) => (r as Map)['name'].toString().trim().isNotEmpty),
        FormFieldType.person => v is! List || v.isEmpty,
        FormFieldType.table => _filledRows(v).isEmpty,
        _ => v == null || v.toString().trim().isEmpty,
      };
      if (empty) return tr('"{f.label}"을(를) 넣으세요.', {'f.label': f.label});
      if (f.type == FormFieldType.timeRange) {
        final m = v as Map;
        if (!isHmText('${m['start']}') || !isHmText('${m['end']}')) {
          return tr('"{f.label}"을(를) HH:MM으로 넣으세요.', {'f.label': f.label});
        }
      }
    }
    if (uploading) return tr('첨부를 올리는 중입니다. 잠시 뒤 다시 누르세요.');
    return null;
  }

  /// 문서 금액(원) — 결재선 규칙의 금액 기준을 고를 때 쓴다(서버 approvalLineRules.js documentAmountOf와 같은 규칙): 기안은 예산,
  /// 출장은 예상 경비, 구매는 품목 합계, 관리자가 만든 양식은 금액 칸·품목 칸 합계·표 칸 금액 열 합계의 합. 금액이 없는
  /// 양식(연장근무)이나 비었으면 null.
  int? get documentAmount {
    int? money(String key) =>
        int.tryParse('${_values[key] ?? ''}'.replaceAll(',', '').trim());
    int? items(String key) {
      final rows = _values[key];
      if (rows is! List) return null;
      final total = rows.fold<int>(
        0,
        (sum, r) =>
            sum + _parseInt((r as Map)['qty']) * _parseInt(r['unitPrice']),
      );
      return total > 0 ? total : null;
    }

    // 표 칸 — 빈칸 아닌 줄의 금액 열 합(서버처럼 값이 있는 줄이 하나라도 있으면 0원도 센다). 금액 열이 없으면 null.
    int? table(FormFieldDef f) {
      final rows = _filledRows(_values[f.key]);
      if (rows.isEmpty) return null;
      int? sum;
      for (final (j, c) in f.columns.indexed) {
        if (c.type != FormTableColumnType.money) continue;
        sum =
            (sum ?? 0) +
            rows.fold<int>(0, (s, r) => s + _parseInt(r.elementAtOrNull(j)));
      }
      return sum;
    }

    switch (form.kind) {
      case ApprovalKind.draft:
        return money('budget');
      case ApprovalKind.trip:
        return money('cost');
      case ApprovalKind.purchase:
        return items('items');
      case ApprovalKind.form:
        int? sum;
        for (final f in form.fields) {
          final v = switch (f.type) {
            FormFieldType.money => money(f.key),
            FormFieldType.items => items(f.key),
            FormFieldType.table => table(f),
            _ => null,
          };
          if (v != null) sum = (sum ?? 0) + v;
        }
        return sum;
      default:
        return null;
    }
  }

  /// 서버에 보낼 값(서버 approvalForms.js parseFieldValue가 받는 모양) — 숫자·금액은 쉼표를 빼고, 사람 칸은 id(여러 명이면 id
  /// 목록), 표 칸은 줄마다 열 순서의 글 목록(빈 줄도 그대로 — 서버가 건너뛰고, "몇 번째 줄" 안내가 화면 줄 번호와 맞는다).
  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{};
    for (final f in form.fields) {
      final v = _values[f.key];
      if (v == null) continue;
      final json = switch (f.type) {
        FormFieldType.money ||
        FormFieldType.number => v.toString().replaceAll(',', '').trim(),
        FormFieldType.items => [
          for (final r in v as List)
            {
              'name': (r as Map)['name'],
              'qty': '${r['qty']}'.replaceAll(',', '').trim(),
              'unitPrice': '${r['unitPrice']}'.replaceAll(',', '').trim(),
            },
        ],
        FormFieldType.person => () {
          final ids = [
            for (final p in v as List<({String id, String name})>) p.id,
          ];
          return f.multiple ? ids : ids.firstOrNull;
        }(),
        FormFieldType.table => [
          for (final row in v as List)
            [
              for (final (j, c) in f.columns.indexed)
                _tableCellJson(c, (row as List).elementAtOrNull(j)),
            ],
        ],
        _ => v,
      };
      if (json != null) out[f.key] = json;
    }
    return out;
  }
}

int _parseInt(Object? v) =>
    int.tryParse('${v ?? ''}'.replaceAll(',', '').trim()) ?? 0;

/// 표 칸 값(줄마다 글 목록) 중 빈칸 아닌 줄만 — 필수 검사·문서 금액에 쓴다(서버도 빈 줄은 건너뛴다).
List<List<Object?>> _filledRows(Object? rows) => [
  for (final r in rows is List ? rows : const [])
    if (r is List && r.any((c) => '${c ?? ''}'.trim().isNotEmpty)) r,
];

/// 표 한 칸을 보낼 글로 — 앞뒤 빈칸을 빼고, 숫자·금액 열은 쉼표도 뺀다.
String _tableCellJson(FormTableColumn column, Object? cell) {
  final text = '${cell ?? ''}'.trim();
  return switch (column.type) {
    FormTableColumnType.number ||
    FormTableColumnType.money => text.replaceAll(',', ''),
    _ => text,
  };
}

// ── 신청 창 ───────────────────────────────────────────────────────────────

/// 양식 결재 신청 — 제목, 양식 칸들, (받는 양식이면) 첨부, 결재선. 올렸으면 그 문서.
Future<ApprovalDocument?> showFormRequestDialog(
  BuildContext context, {
  required GroupwareApi api,
  required GroupwareContext ctx,
  required Session session,
  required ApprovalForm form,
}) => showDialog<ApprovalDocument>(
  context: context,
  builder: (_) =>
      FormRequestDialog(api: api, ctx: ctx, session: session, form: form),
);

/// 양식 결재 신청 창 — 제목 입력칸과 칸 값([FormValues])을 창이 닫히는 애니메이션이 끝날 때까지 갖고 있게 직접 만든다.
class FormRequestDialog extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final Session session;
  final ApprovalForm form;
  const FormRequestDialog({
    super.key,
    required this.api,
    required this.ctx,
    required this.session,
    required this.form,
  });

  @override
  State<FormRequestDialog> createState() => _FormRequestDialogState();
}

class _FormRequestDialogState extends State<FormRequestDialog> {
  late final _values = FormValues(widget.form);
  final _title = TextEditingController();

  /// 사람 칸에서 고를 후보(나 포함) — 처음 고를 때 한 번 불러 두고, 못 불렀으면 다음에 다시 부른다.
  Future<List<ApprovalCandidate>>? _people;
  Future<List<ApprovalCandidate>> _loadPeople() => _people ??= widget.api
      .candidates(includeSelf: true)
      .catchError((Object e, StackTrace st) {
        _people = null;
        Error.throwWithStackTrace(e, st);
      });

  /// 일반 기안서는 제목이 곧 안건이라 꼭 받는다.
  bool get _titleRequired => widget.form.kind == ApprovalKind.draft;

  @override
  void dispose() {
    _title.dispose();
    _values.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final form = widget.form;
    return ApprovalRequestDialog(
      title: form.name,
      api: widget.api,
      ctx: widget.ctx,
      showBody: false,
      // 결재선 규칙 — 양식 종류(관리자가 만든 양식이면 그 양식)와 금액(예산·경비·품목 합계)이 바뀌면 다시 추천받는다.
      lineKind: form.kind.wire,
      lineTemplateId: form.kind == ApprovalKind.form ? form.id : null,
      lineAmountOf: () => _values.documentAmount,
      lineAmountChanges: _values,
      fields: (setState) => [
        if (form.description != null) ...[
          Text(
            form.description!,
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 8),
        ],
        TextField(
          key: const ValueKey('form-title'),
          controller: _title,
          maxLength: 100,
          decoration: InputDecoration(
            labelText: _titleRequired ? tr('제목') : tr('제목(비우면 자동)'),
            border: const OutlineInputBorder(),
          ),
        ),
        FormFieldsEditor(values: _values, loadPeople: _loadPeople),
        if (form.allowAttachments)
          _FormAttachments(
            values: _values,
            session: widget.session,
            ctx: widget.ctx,
          ),
      ],
      validate: () {
        if (_titleRequired && _title.text.trim().isEmpty) {
          return tr('제목을 넣으세요.');
        }
        return _values.validate();
      },
      submit:
          ({
            required body,
            required approverIds,
            required ccIds,
            required roles,
          }) => widget.api.submitForm(
            form: form,
            values: _values.toJson(),
            title: _title.text.trim().isEmpty ? null : _title.text.trim(),
            attachments: [
              for (final r in _values.attachments)
                {
                  'fileUrl': r.url,
                  'fileName': r.name,
                  'fileSize': r.size,
                  'mimeType': r.mimeType,
                },
            ],
            approverIds: approverIds,
            ccIds: ccIds,
            roles: roles,
          ),
    );
  }
}

/// 양식 칸들 — 칸마다 종류에 맞는 입력을 그리고 [values]에 적는다. 입력칸 컨트롤러는 이 위젯이 갖는다. 칸 설명(help)은 칸
/// 아래에 보인다. [loadPeople]은 사람 칸에서 고를 후보(없으면 사람 고르기 단추가 꺼진다).
class FormFieldsEditor extends StatefulWidget {
  final FormValues values;
  final Future<List<ApprovalCandidate>> Function()? loadPeople;
  const FormFieldsEditor({super.key, required this.values, this.loadPeople});

  @override
  State<FormFieldsEditor> createState() => _FormFieldsEditorState();
}

class _FormFieldsEditorState extends State<FormFieldsEditor> {
  final _controllers = <String, TextEditingController>{};

  TextEditingController _c(String id, [String initial = '']) =>
      _controllers.putIfAbsent(id, () => TextEditingController(text: initial));

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  FormValues get _v => widget.values;

  String _label(FormFieldDef f) => f.required ? '${f.label} *' : f.label;

  /// 칸 설명(비었으면 null).
  String? _help(FormFieldDef f) {
    final help = f.help?.trim();
    return help == null || help.isEmpty ? null : help;
  }

  /// 입력칸 꾸밈을 쓰지 않는 칸(날짜·기간·시간대·품목·사람·표) — 칸 아래에 설명을 작은 글로 붙인다.
  Widget _withHelp(BuildContext context, FormFieldDef f, Widget child) {
    final help = _help(f);
    final decorated = switch (f.type) {
      FormFieldType.text ||
      FormFieldType.textarea ||
      FormFieldType.number ||
      FormFieldType.money ||
      FormFieldType.select => true,
      _ => false,
    };
    if (help == null || decorated) return child;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        child,
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 12),
          child: Text(
            help,
            key: ValueKey('form-field-${f.key}-help'),
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final f in _v.form.fields)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _withHelp(context, f, _field(context, f)),
          ),
      ],
    );
  }

  Widget _field(BuildContext context, FormFieldDef f) {
    final border = const OutlineInputBorder();
    switch (f.type) {
      case FormFieldType.text:
      case FormFieldType.textarea:
        return TextField(
          key: ValueKey('form-field-${f.key}'),
          controller: _c(f.key),
          minLines: f.type == FormFieldType.textarea ? 3 : 1,
          maxLines: f.type == FormFieldType.textarea ? 8 : 1,
          maxLength: f.type == FormFieldType.textarea ? 2000 : 200,
          decoration: InputDecoration(
            labelText: _label(f),
            border: border,
            helperText: _help(f),
            helperMaxLines: 3,
          ),
          onChanged: (v) => _v.set(f.key, v),
        );
      case FormFieldType.number:
      case FormFieldType.money:
        return TextField(
          key: ValueKey('form-field-${f.key}'),
          controller: _c(f.key),
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: _label(f),
            border: border,
            helperText: _help(f),
            helperMaxLines: 3,
            suffixText: f.type == FormFieldType.money ? tr('원') : null,
          ),
          onChanged: (v) => _v.set(f.key, v),
        );
      case FormFieldType.date:
        return Align(
          alignment: Alignment.centerLeft,
          child: ApprovalDateField(
            key: ValueKey('form-field-${f.key}'),
            label: _label(f),
            value: _v[f.key] as String?,
            onChanged: (v) => setState(() => _v.set(f.key, v)),
          ),
        );
      case FormFieldType.dateRange:
        final range = (_v[f.key] as Map?) ?? const {};
        void setRange(String part, String value) {
          final next = {...range, part: value};
          // 끝을 안 골랐거나 시작보다 이르면 시작과 같게.
          final start = next['start'] as String?;
          final end = next['end'] as String?;
          if (start != null && (end == null || end.compareTo(start) < 0)) {
            next['end'] = start;
          }
          setState(() => _v.set(f.key, next));
        }

        return Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(_label(f)),
            ApprovalDateField(
              key: ValueKey('form-field-${f.key}-start'),
              label: tr('시작'),
              value: range['start'] as String?,
              onChanged: (v) => setRange('start', v),
            ),
            ApprovalDateField(
              key: ValueKey('form-field-${f.key}-end'),
              label: tr('끝'),
              value: range['end'] as String?,
              onChanged: (v) => setRange('end', v),
            ),
          ],
        );
      case FormFieldType.timeRange:
        void setPart(String part, String value) {
          final range = {...?(_v[f.key] as Map?)};
          range[part] = value.trim();
          _v.set(f.key, range);
        }

        return Row(
          children: [
            Expanded(
              child: TextField(
                key: ValueKey('form-field-${f.key}-start'),
                controller: _c('${f.key}.start'),
                decoration: InputDecoration(
                  labelText: tr('{p0} 시작 (HH:MM)', {'p0': _label(f)}),
                  border: border,
                ),
                onChanged: (v) => setPart('start', v),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: Text('~'),
            ),
            Expanded(
              child: TextField(
                key: ValueKey('form-field-${f.key}-end'),
                controller: _c('${f.key}.end'),
                decoration: InputDecoration(
                  labelText: tr('끝 (HH:MM)'),
                  helperText: tr('시작보다 이르면 다음 날'),
                  border: border,
                ),
                onChanged: (v) => setPart('end', v),
              ),
            ),
          ],
        );
      case FormFieldType.select:
        return DropdownButtonFormField<String>(
          key: ValueKey('form-field-${f.key}'),
          initialValue: _v[f.key] as String?,
          decoration: InputDecoration(
            labelText: _label(f),
            border: border,
            helperText: _help(f),
            helperMaxLines: 3,
          ),
          items: [
            for (final o in f.options)
              DropdownMenuItem(value: o, child: Text(o)),
          ],
          onChanged: (v) => _v.set(f.key, v),
        );
      case FormFieldType.items:
        return _ItemsEditor(field: f, values: _v, controllerOf: _c);
      case FormFieldType.person:
        return _PersonFieldEditor(
          field: f,
          label: _label(f),
          values: _v,
          loadPeople: widget.loadPeople,
        );
      case FormFieldType.table:
        return _TableFieldEditor(
          field: f,
          label: _label(f),
          values: _v,
          controllerOf: _c,
        );
    }
  }
}

/// 사람 칸 — 고른 사람을 지울 수 있는 칩으로 보이고, "사람 고르기"로 후보 창을 연다. 한 사람 칸은 새로 고르면 바뀌고, 여러 명
/// 칸은 [kFormPeopleMax]명까지 더한다. 값은 [FormValues]에 ({id, name}) 목록으로 적는다(보낼 때 id만 — [FormValues.toJson]).
class _PersonFieldEditor extends StatefulWidget {
  final FormFieldDef field;
  final String label;
  final FormValues values;
  final Future<List<ApprovalCandidate>> Function()? loadPeople;
  const _PersonFieldEditor({
    required this.field,
    required this.label,
    required this.values,
    required this.loadPeople,
  });

  @override
  State<_PersonFieldEditor> createState() => _PersonFieldEditorState();
}

class _PersonFieldEditorState extends State<_PersonFieldEditor> {
  FormFieldDef get _f => widget.field;

  List<({String id, String name})> get _people => [
    ...?(widget.values[_f.key] as List<({String id, String name})>?),
  ];

  void _setPeople(List<({String id, String name})> people) {
    widget.values.set(_f.key, people);
    setState(() {});
  }

  Future<void> _pick() async {
    final load = widget.loadPeople;
    if (load == null) return;
    final picked = await showDialog<List<({String id, String name})>>(
      context: context,
      builder: (_) => _FormPeopleDialog(
        title: _f.label,
        multiple: _f.multiple,
        load: load,
        initial: _people,
      ),
    );
    if (picked == null || !mounted) return;
    _setPeople(picked);
  }

  @override
  Widget build(BuildContext context) {
    final people = _people;
    final full = _f.multiple && people.length >= kFormPeopleMax;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.label),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final p in people)
              InputChip(
                key: ValueKey('form-field-${_f.key}-person-${p.id}'),
                avatar: const Icon(Icons.person_outline, size: 16),
                label: Text(p.name, overflow: TextOverflow.ellipsis),
                onDeleted: () =>
                    _setPeople([...people.where((x) => x.id != p.id)]),
              ),
            TextButton.icon(
              key: ValueKey('form-field-${_f.key}-pick'),
              onPressed: widget.loadPeople == null || full ? null : _pick,
              icon: const Icon(Icons.person_add_alt, size: 18),
              label: Text(
                _f.multiple
                    ? tr('사람 고르기 ({n}/{max})', {
                        'n': people.length,
                        'max': kFormPeopleMax,
                      })
                    : tr('사람 고르기'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 사람 칸의 후보 창 — 이름·아이디로 찾는다. 한 사람 칸은 누르면 바로 그 사람으로 닫히고, 여러 명 칸은 체크해서 "확인"으로
/// 닫는다([kFormPeopleMax]명까지 — 이미 고른 사람은 체크된 채로 시작). 닫으면 고른 사람 목록(취소는 null).
class _FormPeopleDialog extends StatefulWidget {
  final String title;
  final bool multiple;
  final Future<List<ApprovalCandidate>> Function() load;
  final List<({String id, String name})> initial;
  const _FormPeopleDialog({
    required this.title,
    required this.multiple,
    required this.load,
    required this.initial,
  });

  @override
  State<_FormPeopleDialog> createState() => _FormPeopleDialogState();
}

class _FormPeopleDialogState extends State<_FormPeopleDialog> {
  late final Future<List<ApprovalCandidate>> _candidates = widget.load();
  late final _selected = [...widget.initial];
  String _query = '';

  void _toggle(ApprovalCandidate c) {
    setState(() {
      if (_selected.any((p) => p.id == c.id)) {
        _selected.removeWhere((p) => p.id == c.id);
      } else if (_selected.length < kFormPeopleMax) {
        _selected.add((id: c.id, name: c.name));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        height: 420,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('form-person-search'),
              autofocus: true,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: tr('이름·아이디로 찾기'),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            if (widget.multiple)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    tr('{n}/{max}명', {
                      'n': _selected.length,
                      'max': kFormPeopleMax,
                    }),
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: FutureBuilder<List<ApprovalCandidate>>(
                future: _candidates,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Center(
                      child: Text(
                        tr('사람 목록을 불러오지 못했습니다: {e}', {'e': snap.error}),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: hint),
                      ),
                    );
                  }
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final q = _query.trim().toLowerCase();
                  final shown = [
                    for (final c in snap.data!)
                      if (q.isEmpty ||
                          c.name.toLowerCase().contains(q) ||
                          c.username.toLowerCase().contains(q))
                        c,
                  ];
                  if (shown.isEmpty) {
                    return Center(
                      child: Text(
                        tr('고를 수 있는 사람이 없습니다.'),
                        style: TextStyle(color: hint),
                      ),
                    );
                  }
                  return ListView(
                    children: [
                      for (final c in shown)
                        if (widget.multiple)
                          CheckboxListTile(
                            key: ValueKey('form-person-${c.id}'),
                            value: _selected.any((p) => p.id == c.id),
                            title: Text(c.name),
                            subtitle: Text(c.username),
                            // 다 찼으면 이미 고른 사람만 뺄 수 있다.
                            enabled:
                                _selected.length < kFormPeopleMax ||
                                _selected.any((p) => p.id == c.id),
                            onChanged: (_) => _toggle(c),
                          )
                        else
                          ListTile(
                            key: ValueKey('form-person-${c.id}'),
                            title: Text(c.name),
                            subtitle: Text(c.username),
                            trailing: _selected.any((p) => p.id == c.id)
                                ? const Icon(Icons.check, size: 18)
                                : null,
                            onTap: () => Navigator.of(
                              context,
                            ).pop([(id: c.id, name: c.name)]),
                          ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('닫기')),
        ),
        if (widget.multiple)
          FilledButton(
            key: const ValueKey('form-person-done'),
            onPressed: () => Navigator.of(context).pop([..._selected]),
            child: Text(tr('확인')),
          ),
      ],
    );
  }
}

/// 표 칸 — 관리자가 정한 열([FormFieldDef.columns])마다 입력칸(글·숫자·금액은 글칸, 날짜는 날짜 단추)을 줄로 넣는다. 줄은
/// [kFormTableRowsMax]줄까지, 숫자·금액 열은 아래에 합계를 바로 보인다. 좁은 화면에서는 표가 옆으로 밀린다(넓으면 열을 늘려 채움).
/// 값은 [FormValues]에 줄마다 열 순서의 글 목록으로 적는다.
class _TableFieldEditor extends StatefulWidget {
  final FormFieldDef field;
  final String label;
  final FormValues values;
  final TextEditingController Function(String id, [String initial])
  controllerOf;
  const _TableFieldEditor({
    required this.field,
    required this.label,
    required this.values,
    required this.controllerOf,
  });

  @override
  State<_TableFieldEditor> createState() => _TableFieldEditorState();
}

class _TableFieldEditorState extends State<_TableFieldEditor> {
  /// 줄 id(지워도 입력칸 컨트롤러가 섞이지 않게) — 0부터 늘어난다. 처음엔 빈 줄 하나.
  final _rowIds = <int>[0];
  int _nextId = 1;
  late final _rows = <int, List<String>>{0: _emptyRow()};

  FormFieldDef get _f => widget.field;
  List<FormTableColumn> get _columns => _f.columns;

  List<String> _emptyRow() => List.filled(_columns.length, '');

  void _sync() {
    widget.values.set(_f.key, [
      for (final id in _rowIds) List<String>.of(_rows[id]!),
    ]);
    setState(() {});
  }

  /// 열 종류별 기본 너비 — 넓은 화면에서는 비율대로 늘린다.
  static double _baseWidth(FormTableColumnType type) => switch (type) {
    FormTableColumnType.text => 150,
    FormTableColumnType.number => 96,
    FormTableColumnType.money => 120,
    FormTableColumnType.date => 140,
  };

  static const _removeWidth = 40.0;

  /// 숫자·금액 열의 합계 글(그 밖의 열은 null) — 빈칸·숫자 아닌 칸은 0으로 센다(서버와 같게 소수 둘째 자리까지).
  String? _totalText(int j) {
    final c = _columns[j];
    if (c.type == FormTableColumnType.money) {
      return wonText(
        _rowIds.fold<int>(0, (s, id) => s + _parseInt(_rows[id]![j])),
      );
    }
    if (c.type == FormTableColumnType.number) {
      final sum = _rowIds.fold<double>(
        0,
        (s, id) =>
            s +
            (double.tryParse(_rows[id]![j].replaceAll(',', '').trim()) ?? 0),
      );
      return formTableCellText(c, (sum * 100).round() / 100);
    }
    return null;
  }

  Widget _cell(int index, int id, int j, double width) {
    final c = _columns[j];
    final cellKey = ValueKey('form-field-${_f.key}-$index-$j');
    final Widget input;
    if (c.type == FormTableColumnType.date) {
      final value = _rows[id]![j];
      input = Align(
        alignment: Alignment.centerLeft,
        child: ApprovalDateField(
          key: cellKey,
          label: c.label,
          value: value.isEmpty ? null : value,
          onChanged: (v) {
            _rows[id]![j] = v;
            _sync();
          },
        ),
      );
    } else {
      final numeric = c.type != FormTableColumnType.text;
      input = TextField(
        key: cellKey,
        controller: widget.controllerOf('${_f.key}.$id.$j'),
        keyboardType: numeric ? TextInputType.number : null,
        textAlign: numeric ? TextAlign.end : TextAlign.start,
        decoration: InputDecoration(
          isDense: true,
          border: const OutlineInputBorder(),
          suffixText: c.type == FormTableColumnType.money ? tr('원') : null,
        ),
        onChanged: (v) {
          _rows[id]![j] = v;
          _sync();
        },
      );
    }
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: SizedBox(width: width - 4, child: input),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final totals = [
      for (final (j, c) in _columns.indexed)
        if (_totalText(j) case final t?)
          tr('{label} 합계 {total}', {'label': c.label, 'total': t}),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.label),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (context, constraints) {
            final natural = _columns.fold<double>(
              0,
              (s, c) => s + _baseWidth(c.type),
            );
            final room = constraints.maxWidth.isFinite
                ? constraints.maxWidth - _removeWidth
                : natural;
            // 자리가 남으면 열을 비율대로 늘리고, 모자라면 기본 너비로 두고 옆으로 밀게 한다.
            final scale = natural > 0 && room > natural ? room / natural : 1.0;
            final widths = [
              for (final c in _columns) _baseWidth(c.type) * scale,
            ];
            return SingleChildScrollView(
              key: ValueKey('form-field-${_f.key}-scroll'),
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      for (final (j, c) in _columns.indexed)
                        SizedBox(
                          width: widths[j],
                          child: Text(
                            c.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: hint),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  for (final (i, id) in _rowIds.indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          for (final j in Iterable<int>.generate(
                            _columns.length,
                          ))
                            _cell(i, id, j, widths[j]),
                          SizedBox(
                            width: _removeWidth,
                            child: IconButton(
                              key: ValueKey('form-field-${_f.key}-$i-remove'),
                              tooltip: tr('이 줄 빼기'),
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: _rowIds.length == 1
                                  ? null
                                  : () {
                                      _rowIds.remove(id);
                                      _rows.remove(id);
                                      _sync();
                                    },
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            );
          },
        ),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            TextButton.icon(
              key: ValueKey('form-field-${_f.key}-add-row'),
              onPressed: _rowIds.length >= kFormTableRowsMax
                  ? null
                  : () {
                      final id = _nextId++;
                      _rowIds.add(id);
                      _rows[id] = _emptyRow();
                      _sync();
                    },
              icon: const Icon(Icons.add, size: 18),
              label: Text(tr('줄 추가')),
            ),
            if (totals.isNotEmpty)
              Text(
                totals.join(' · '),
                key: ValueKey('form-field-${_f.key}-totals'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
          ],
        ),
      ],
    );
  }
}

/// 품목 표 — 줄마다 품명·수량·단가, 금액과 합계는 바로 계산해 보여 준다.
class _ItemsEditor extends StatefulWidget {
  final FormFieldDef field;
  final FormValues values;
  final TextEditingController Function(String id, [String initial])
  controllerOf;
  const _ItemsEditor({
    required this.field,
    required this.values,
    required this.controllerOf,
  });

  @override
  State<_ItemsEditor> createState() => _ItemsEditorState();
}

class _ItemsEditorState extends State<_ItemsEditor> {
  /// 줄 id(지워도 입력칸이 섞이지 않게) — 0부터 늘어난다.
  final _rowIds = <int>[0];
  int _nextId = 1;
  final _rows = <int, Map<String, String>>{
    0: {'name': '', 'qty': '1', 'unitPrice': ''},
  };

  String get _key => widget.field.key;

  void _sync() {
    widget.values.set(_key, [for (final id in _rowIds) _rows[id]!]);
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.values.set(_key, [for (final id in _rowIds) _rows[id]!]);
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final total = _rowIds.fold<int>(
      0,
      (sum, id) =>
          sum +
          _parseInt(_rows[id]!['qty']) * _parseInt(_rows[id]!['unitPrice']),
    );
    InputDecoration dec(String label) => InputDecoration(
      labelText: label,
      isDense: true,
      border: const OutlineInputBorder(),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.field.required
              ? '${widget.field.label} *'
              : widget.field.label,
        ),
        const SizedBox(height: 6),
        for (final (i, id) in _rowIds.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: TextField(
                    key: ValueKey('form-item-$i-name'),
                    controller: widget.controllerOf('$_key.$id.name'),
                    decoration: dec(tr('품명')),
                    onChanged: (v) {
                      _rows[id]!['name'] = v;
                      _sync();
                    },
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  flex: 2,
                  child: TextField(
                    key: ValueKey('form-item-$i-qty'),
                    controller: widget.controllerOf('$_key.$id.qty', '1'),
                    keyboardType: TextInputType.number,
                    decoration: dec(tr('수량')),
                    onChanged: (v) {
                      _rows[id]!['qty'] = v;
                      _sync();
                    },
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  flex: 3,
                  child: TextField(
                    key: ValueKey('form-item-$i-price'),
                    controller: widget.controllerOf('$_key.$id.unitPrice'),
                    keyboardType: TextInputType.number,
                    decoration: dec(tr('단가(원)')),
                    onChanged: (v) {
                      _rows[id]!['unitPrice'] = v;
                      _sync();
                    },
                  ),
                ),
                IconButton(
                  tooltip: tr('이 줄 빼기'),
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: _rowIds.length == 1
                      ? null
                      : () {
                          _rowIds.remove(id);
                          _rows.remove(id);
                          _sync();
                        },
                ),
              ],
            ),
          ),
        Row(
          children: [
            TextButton.icon(
              key: const ValueKey('form-item-add'),
              onPressed: _rowIds.length >= 50
                  ? null
                  : () {
                      final id = _nextId++;
                      _rowIds.add(id);
                      _rows[id] = {'name': '', 'qty': '1', 'unitPrice': ''};
                      _sync();
                    },
              icon: const Icon(Icons.add, size: 18),
              label: Text(tr('품목 추가')),
            ),
            const Spacer(),
            Text(
              tr('합계 {p0}', {'p0': wonText(total)}),
              key: const ValueKey('form-items-total'),
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: total == 0 ? hint : null,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 첨부(받는 양식만) — 직접 올린 파일을 [GroupwareContext.attachmentsMax]개까지.
class _FormAttachments extends StatefulWidget {
  final FormValues values;
  final Session session;
  final GroupwareContext ctx;
  const _FormAttachments({
    required this.values,
    required this.session,
    required this.ctx,
  });

  @override
  State<_FormAttachments> createState() => _FormAttachmentsState();
}

class _FormAttachmentsState extends State<_FormAttachments> {
  Future<void> _pick() async {
    final v = widget.values;
    final picked = await FilePicker.pickFiles(allowMultiple: true);
    final files = [
      for (final f in picked?.files ?? const <PlatformFile>[])
        if (f.path != null || f.bytes != null) f.xFile,
    ].take(widget.ctx.attachmentsMax - v.attachments.length).toList();
    if (files.isEmpty) return;
    setState(() => v.uploading = true);
    try {
      for (final f in files) {
        final up = await widget.session.api!.uploadFile(f);
        v.attachments.add((
          url: up.url,
          name: up.fileName,
          size: up.size,
          mimeType: up.mimeType,
        ));
        if (mounted) setState(() {});
      }
    } catch (e) {
      if (mounted) showAppToast(context, tr('첨부 실패: {e}', {'e': e}));
    } finally {
      v.uploading = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.values;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final r in v.attachments)
          InputChip(
            label: Text(r.name, overflow: TextOverflow.ellipsis),
            onDeleted: () => setState(() => v.attachments.remove(r)),
          ),
        ActionChip(
          key: const ValueKey('form-attach'),
          avatar: v.uploading
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.attach_file, size: 16),
          label: Text(
            tr('첨부 ({v.attachments.length}/{widget.ctx.attachmentsMax})', {
              'v.attachments.length': v.attachments.length,
              'widget.ctx.attachmentsMax': widget.ctx.attachmentsMax,
            }),
          ),
          onPressed:
              v.uploading || v.attachments.length >= widget.ctx.attachmentsMax
              ? null
              : _pick,
        ),
      ],
    );
  }
}

// ── 문서 상세 ─────────────────────────────────────────────────────────────

/// 양식 문서의 칸과 값 — 올릴 때의 칸 정의(payload.fields)로 그린다(양식을 고쳐도 그대로).
class FormValuesView extends StatelessWidget {
  final ApprovalDocument doc;
  const FormValuesView({super.key, required this.doc});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final values = doc.formValues;
    final children = <Widget>[];
    for (final f in doc.formFields) {
      final value = values[f.key];
      if (f.type == FormFieldType.textarea && value != null) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Text(f.label, style: TextStyle(color: hint)),
          ),
        );
        children.add(
          Container(
            key: ValueKey('form-value-${f.key}'),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText('$value'),
          ),
        );
        continue;
      }
      if (f.type == FormFieldType.items && value is Map) {
        final rows = (value['rows'] as List? ?? const []).cast<Map>();
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Text(f.label, style: TextStyle(color: hint)),
          ),
        );
        children.add(
          Table(
            key: ValueKey('form-value-${f.key}'),
            columnWidths: const {
              0: FlexColumnWidth(4),
              1: FlexColumnWidth(1.4),
              2: FlexColumnWidth(2.4),
              3: FlexColumnWidth(2.6),
            },
            children: [
              TableRow(
                children: [
                  for (final h in [tr('품명'), tr('수량'), tr('단가'), tr('금액')])
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Text(
                        h,
                        style: TextStyle(fontSize: 12, color: hint),
                      ),
                    ),
                ],
              ),
              for (final r in rows)
                TableRow(
                  children: [
                    Text('${r['name']}'),
                    Text('${r['qty']}'),
                    Text(wonText((r['unitPrice'] as num).toInt())),
                    Text(wonText((r['amount'] as num).toInt())),
                  ],
                ),
            ],
          ),
        );
        children.add(
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              tr('합계 {p0}', {
                'p0': wonText((value['total'] as num?)?.toInt() ?? 0),
              }),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        );
        continue;
      }
      if (f.type == FormFieldType.table && value is Map) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Text(f.label, style: TextStyle(color: hint)),
          ),
        );
        children.add(
          FormTableValueView(
            key: ValueKey('form-value-${f.key}'),
            field: f,
            value: value,
          ),
        );
        continue;
      }
      // 한 줄 값(사람 칸은 이름들) — 비었으면 '—'.
      final text = formValueText(f, value);
      final empty = text == null || text.isEmpty;
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 96,
                child: Text(f.label, style: TextStyle(color: hint)),
              ),
              Expanded(
                child: Text(
                  empty ? '—' : text,
                  key: ValueKey('form-value-${f.key}'),
                  style: empty ? TextStyle(color: hint) : null,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

/// 문서에 적힌 표 칸 값({rows, totals}) — 열 이름 머리, 줄마다 칸 글([formTableCellText]), 숫자·금액 열이 있으면 맨 아래 합계 줄.
/// 열이 많으면 옆으로 밀린다.
class FormTableValueView extends StatelessWidget {
  final FormFieldDef field;
  final Map value;
  const FormTableValueView({
    super.key,
    required this.field,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final columns = field.columns;
    final rows = [
      for (final r in value['rows'] as List? ?? const [])
        if (r is List) r,
    ];
    final totals = value['totals'] as List? ?? const [];
    final totalsRow = formTableTotalsRow(field, totals);
    Widget cell(String text, {TextStyle? style, bool end = false}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Text(
        text,
        style: style,
        textAlign: end ? TextAlign.end : TextAlign.start,
      ),
    );
    bool numeric(FormTableColumn c) =>
        c.type == FormTableColumnType.number ||
        c.type == FormTableColumnType.money;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        border: TableBorder(
          horizontalInside: BorderSide(color: theme.dividerColor, width: 0.5),
        ),
        children: [
          TableRow(
            children: [
              for (final c in columns)
                cell(
                  c.label,
                  style: TextStyle(fontSize: 12, color: hint),
                  end: numeric(c),
                ),
            ],
          ),
          for (final r in rows)
            TableRow(
              children: [
                for (final (j, c) in columns.indexed)
                  cell(
                    formTableCellText(c, r.elementAtOrNull(j)),
                    end: numeric(c),
                  ),
              ],
            ),
          if (totalsRow != null)
            TableRow(
              children: [
                for (final (j, c) in columns.indexed)
                  cell(
                    totalsRow[j],
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    end: numeric(c),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

// ── 새 결재 고르기 ─────────────────────────────────────────────────────────

/// "새 결재" — 휴가·지출(전용 창)과 켜진 양식들 중에서 고르게 하고, 고른 신청 창을 연다. 올렸으면 그 문서.
Future<ApprovalDocument?> showNewApprovalChooser(
  BuildContext context, {
  required GroupwareApi api,
  required GroupwareContext ctx,
  required Session session,
}) async {
  List<ApprovalForm> forms;
  try {
    forms = (await api.forms()).where((f) => f.enabled).toList();
  } catch (e) {
    if (context.mounted) {
      showAppToast(context, tr('양식을 불러오지 못했습니다: {e}', {'e': e}));
    }
    return null;
  }
  if (!context.mounted) return null;
  final picked = await showDialog<Object>(
    context: context,
    builder: (dialogContext) {
      Widget option(
        Object value,
        IconData icon,
        String title,
        String? sub,
        Key key,
      ) => ListTile(
        key: key,
        leading: Icon(icon),
        title: Text(title),
        subtitle: sub == null
            ? null
            : Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis),
        onTap: () => Navigator.of(dialogContext).pop(value),
      );
      return AlertDialog(
        title: Text(tr('새 결재')),
        contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: [
              option(
                ApprovalKind.leave,
                approvalKindIcon(ApprovalKind.leave),
                tr('휴가 신청'),
                tr('연차·반차·경조사 등'),
                const ValueKey('new-approval-leave'),
              ),
              option(
                ApprovalKind.expense,
                approvalKindIcon(ApprovalKind.expense),
                tr('지출 결재'),
                tr('영수증을 붙여 비용 처리'),
                const ValueKey('new-approval-expense'),
              ),
              if (forms.isNotEmpty) const Divider(),
              for (final f in forms)
                option(
                  f,
                  approvalKindIcon(f.kind),
                  f.name,
                  f.description,
                  ValueKey('new-approval-${f.id}'),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text(
                  tr('근태 수정은 출퇴근 탭에서 그날을 골라 "수정 요청"으로 올립니다.'),
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(dialogContext).hintColor,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(tr('닫기')),
          ),
        ],
      );
    },
  );
  if (picked == null || !context.mounted) return null;
  if (picked == ApprovalKind.leave) {
    return showLeaveRequestDialog(context, api: api, ctx: ctx);
  }
  if (picked == ApprovalKind.expense) {
    return showExpenseRequestDialog(
      context,
      api: api,
      ctx: ctx,
      session: session,
    );
  }
  return showFormRequestDialog(
    context,
    api: api,
    ctx: ctx,
    session: session,
    form: picked as ApprovalForm,
  );
}
