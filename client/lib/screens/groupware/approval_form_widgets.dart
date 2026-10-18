import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import 'approval_forms.dart';
import 'groupware_screen.dart'
    show GroupwareChanges, GroupwareSectionHeader, approvalKindIcon;
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

  /// 서버에 보낼 값.
  Map<String, dynamic> toJson() => {
    for (final f in form.fields)
      if (_values[f.key] != null)
        f.key: switch (f.type) {
          FormFieldType.money || FormFieldType.number =>
            _values[f.key].toString().replaceAll(',', '').trim(),
          FormFieldType.items => [
            for (final r in _values[f.key] as List)
              {
                'name': (r as Map)['name'],
                'qty': '${r['qty']}'.replaceAll(',', '').trim(),
                'unitPrice': '${r['unitPrice']}'.replaceAll(',', '').trim(),
              },
          ],
          _ => _values[f.key],
        },
  };
}

int _parseInt(Object? v) =>
    int.tryParse('${v ?? ''}'.replaceAll(',', '').trim()) ?? 0;

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
        FormFieldsEditor(values: _values),
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

/// 양식 칸들 — 칸마다 종류에 맞는 입력을 그리고 [values]에 적는다. 입력칸 컨트롤러는 이 위젯이 갖는다.
class FormFieldsEditor extends StatefulWidget {
  final FormValues values;
  const FormFieldsEditor({super.key, required this.values});

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

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final f in _v.form.fields)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _field(context, f),
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
          decoration: InputDecoration(labelText: _label(f), border: border),
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
          decoration: InputDecoration(labelText: _label(f), border: border),
          items: [
            for (final o in f.options)
              DropdownMenuItem(value: o, child: Text(o)),
          ],
          onChanged: (v) => _v.set(f.key, v),
        );
      case FormFieldType.items:
        return _ItemsEditor(field: f, values: _v, controllerOf: _c);
    }
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
                  formValueText(f, value) ?? '—',
                  key: ValueKey('form-value-${f.key}'),
                  style: value == null ? TextStyle(color: hint) : null,
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

// ── 관리: 결재 양식 ───────────────────────────────────────────────────────

/// 관리 탭의 "결재 양식" — 기본 양식 켜고 끄기, 양식 만들기·고치기·켜고 끄기·지우기.
class ApprovalFormsAdminSection extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareChanges changes;
  const ApprovalFormsAdminSection({
    super.key,
    required this.api,
    required this.changes,
  });

  @override
  State<ApprovalFormsAdminSection> createState() =>
      _ApprovalFormsAdminSectionState();
}

class _ApprovalFormsAdminSectionState extends State<ApprovalFormsAdminSection> {
  List<ApprovalForm>? _forms;
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
      final forms = await widget.api.forms();
      if (mounted) setState(() => (_forms = forms, _error = null));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([ApprovalForm? form]) async {
    final result = await showDialog<_FormDefinition>(
      context: context,
      builder: (_) => _FormDefinitionDialog(initial: form),
    );
    if (result == null) return;
    await _run(() async {
      if (form == null) {
        await widget.api.createForm(
          name: result.name,
          description: result.description,
          fields: result.fields,
          allowAttachments: result.allowAttachments,
        );
        if (mounted) {
          showAppToast(
            context,
            tr('"{result.name}" 양식을 만들었습니다.', {'result.name': result.name}),
          );
        }
      } else {
        await widget.api.updateForm(
          form.id,
          name: result.name,
          description: result.description ?? '',
          fields: result.fields,
          allowAttachments: result.allowAttachments,
        );
      }
    });
  }

  Future<void> _delete(ApprovalForm form) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('양식 지우기')),
        content: Text(
          tr('"{form.name}" 양식을 지울까요? 이 양식으로 이미 올린 결재는 그대로 남습니다.', {
            'form.name': form.name,
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('취소')),
          ),
          FilledButton(
            key: const ValueKey('gw-form-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('지우기')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => widget.api.deleteForm(form.id));
  }

  @override
  Widget build(BuildContext context) {
    final forms = _forms;
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupwareSectionHeader(
          tr('결재 양식'),
          trailing: TextButton.icon(
            key: const ValueKey('gw-form-create'),
            onPressed: _busy ? null : () => _edit(),
            icon: const Icon(Icons.add, size: 18),
            label: Text(tr('양식 만들기')),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            tr(
              '휴가·지출·근태 수정 말고 쓸 양식입니다. 끈 양식은 "새 결재"에 나오지 않고, 양식을 고치거나 지워도 이미 올린 결재는 그대로입니다.',
            ),
            style: TextStyle(fontSize: 12, color: hint),
          ),
        ),
        if (_error != null)
          Padding(padding: const EdgeInsets.all(16), child: Text(_error!))
        else if (forms == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          for (final f in forms)
            ListTile(
              key: ValueKey('gw-form-${f.id}'),
              dense: true,
              leading: Icon(
                approvalKindIcon(f.kind),
                color: f.enabled ? null : hint,
              ),
              title: Text(
                f.builtin
                    ? f.name
                    : tr('{f.name} (직접 만든 양식)', {'f.name': f.name}),
              ),
              subtitle: Text(
                tr('칸 {f.fields.length}개{p0}{p1}', {
                  'f.fields.length': f.fields.length,
                  'p0': f.allowAttachments ? tr(' · 첨부') : '',
                  'p1': f.enabled ? '' : tr(' · 꺼짐'),
                }),
                style: TextStyle(color: hint),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    key: ValueKey('gw-form-enabled-${f.id}'),
                    value: f.enabled,
                    onChanged: _busy
                        ? null
                        : (v) => _run(
                            () => widget.api.updateForm(f.id, enabled: v),
                          ),
                  ),
                  if (!f.builtin)
                    PopupMenuButton<String>(
                      key: ValueKey('gw-form-menu-${f.id}'),
                      enabled: !_busy,
                      onSelected: (v) => v == 'edit' ? _edit(f) : _delete(f),
                      itemBuilder: (_) => [
                        PopupMenuItem(value: 'edit', child: Text(tr('고치기'))),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(
                            tr('지우기'),
                            style: TextStyle(color: Colors.redAccent),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
      ],
    );
  }
}

typedef _FormDefinition = ({
  String name,
  String? description,
  List<FormFieldDef> fields,
  bool allowAttachments,
});

/// 양식 만들기·고치기 — 이름·설명·칸(이름·종류·필수·고를 거리)·첨부.
class _FormDefinitionDialog extends StatefulWidget {
  final ApprovalForm? initial;
  const _FormDefinitionDialog({this.initial});

  @override
  State<_FormDefinitionDialog> createState() => _FormDefinitionDialogState();
}

class _FieldDraft {
  final label = TextEditingController();
  final options = TextEditingController();
  FormFieldType type = FormFieldType.text;
  bool required = false;
  void dispose() {
    label.dispose();
    options.dispose();
  }
}

class _FormDefinitionDialogState extends State<_FormDefinitionDialog> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _description = TextEditingController(
    text: widget.initial?.description ?? '',
  );
  late bool _attachments = widget.initial?.allowAttachments ?? false;
  final _fields = <_FieldDraft>[];
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final f in widget.initial?.fields ?? const <FormFieldDef>[]) {
      _fields.add(
        _FieldDraft()
          ..label.text = f.label
          ..type = f.type
          ..required = f.required
          ..options.text = f.options.join(', '),
      );
    }
    if (_fields.isEmpty) _fields.add(_FieldDraft());
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    for (final f in _fields) {
      f.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return setState(() => _error = tr('양식 이름을 넣으세요.'));
    final fields = <FormFieldDef>[];
    for (final (i, d) in _fields.indexed) {
      final label = d.label.text.trim();
      if (label.isEmpty) {
        return setState(
          () => _error = tr('{p0}번째 칸의 이름을 넣으세요.', {'p0': i + 1}),
        );
      }
      final options = d.type == FormFieldType.select
          ? d.options.text
                .split(',')
                .map((o) => o.trim())
                .where((o) => o.isNotEmpty)
                .toList()
          : const <String>[];
      if (d.type == FormFieldType.select && options.length < 2) {
        return setState(
          () => _error = tr('"{label}"의 고를 거리를 쉼표로 나눠 둘 이상 넣으세요.', {
            'label': label,
          }),
        );
      }
      fields.add(
        FormFieldDef(
          key: '',
          label: label,
          type: d.type,
          required: d.required,
          options: options,
        ),
      );
    }
    final description = _description.text.trim();
    Navigator.of(context).pop((
      name: name,
      description: description.isEmpty ? null : description,
      fields: fields,
      allowAttachments: _attachments,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? tr('양식 만들기') : tr('양식 고치기')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('gw-form-name'),
                controller: _name,
                maxLength: 30,
                decoration: InputDecoration(
                  labelText: tr('양식 이름'),
                  hintText: tr('예: 교육 신청'),
                ),
              ),
              TextField(
                key: const ValueKey('gw-form-description'),
                controller: _description,
                maxLength: 200,
                decoration: InputDecoration(labelText: tr('설명(새 결재 고르기에 보임)')),
              ),
              CheckboxListTile(
                key: const ValueKey('gw-form-attachments'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _attachments,
                onChanged: (v) => setState(() => _attachments = v ?? false),
                title: Text(tr('파일 첨부 받기')),
              ),
              const Divider(),
              for (final (i, d) in _fields.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 4,
                        child: Column(
                          children: [
                            TextField(
                              key: ValueKey('gw-form-field-$i-label'),
                              controller: d.label,
                              decoration: InputDecoration(
                                labelText: tr('칸 {p0} 이름', {'p0': i + 1}),
                                isDense: true,
                              ),
                            ),
                            if (d.type == FormFieldType.select)
                              TextField(
                                key: ValueKey('gw-form-field-$i-options'),
                                controller: d.options,
                                decoration: InputDecoration(
                                  labelText: tr('고를 거리(쉼표로)'),
                                  isDense: true,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 3,
                        child: DropdownButtonFormField<FormFieldType>(
                          key: ValueKey('gw-form-field-$i-type'),
                          initialValue: d.type,
                          isDense: true,
                          decoration: InputDecoration(
                            labelText: tr('종류'),
                            isDense: true,
                          ),
                          items: [
                            for (final t in FormFieldType.values)
                              DropdownMenuItem(value: t, child: Text(t.label)),
                          ],
                          onChanged: (v) =>
                              setState(() => d.type = v ?? d.type),
                        ),
                      ),
                      Column(
                        children: [
                          Text(tr('필수'), style: TextStyle(fontSize: 11)),
                          Checkbox(
                            key: ValueKey('gw-form-field-$i-required'),
                            value: d.required,
                            onChanged: (v) =>
                                setState(() => d.required = v ?? false),
                          ),
                        ],
                      ),
                      IconButton(
                        tooltip: tr('칸 빼기'),
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: _fields.length == 1
                            ? null
                            : () =>
                                  setState(() => _fields.removeAt(i).dispose()),
                      ),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('gw-form-field-add'),
                  onPressed: _fields.length >= 20
                      ? null
                      : () => setState(() => _fields.add(_FieldDraft())),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(tr('칸 추가')),
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
          key: const ValueKey('gw-form-save'),
          onPressed: _submit,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}
