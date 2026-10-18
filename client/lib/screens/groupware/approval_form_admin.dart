import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../services/groupware_api.dart';
import '../../widgets/app_toast.dart';
import 'groupware_screen.dart'
    show GroupwareChanges, GroupwareSectionHeader, approvalKindIcon;
import '../../l10n/tr.dart';

/// 관리 탭의 "결재 양식"(서버 approvalForms.js) — 기본 양식 켜고 끄기, 양식 만들기·고치기·켜고 끄기·지우기, 양식마다의 기본
/// 결재선·참조자(서버 approvalFormDefaults.js). 신청 창과 칸 그리기는 approval_form_widgets.dart.

// ── 관리: 결재 양식 ───────────────────────────────────────────────────────

/// 기본 결재선·기본 참조자에 넣을 수 있는 사람 수(서버 approvalRules.js APPROVERS_MAX·CC_MAX).
const _kDefaultLineMax = 10;
const _kDefaultCcMax = 10;

/// 관리 탭의 "결재 양식" — 기본 양식 켜고 끄기, 양식 만들기·고치기·켜고 끄기·지우기, 양식마다(기본 양식도) 기본 결재선·참조자.
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

  /// 기본 결재선·참조자 창 — 창 안에서 저장하고(서버가 거르면 창에 오류), 저장했으면 알리고 목록을 다시 읽는다.
  Future<void> _editDefaults(ApprovalForm form) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _FormDefaultsDialog(api: widget.api, form: form),
    );
    if (saved != true || !mounted) return;
    showAppToast(context, tr('기본 결재선을 저장했습니다.'));
    await _load();
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

  /// 목록 부제에 붙일 기본 결재선·참조자 사람 수(정하지 않았으면 '').
  String _defaultsText(ApprovalForm f) =>
      (f.defaultLine.isEmpty
          ? ''
          : tr(' · 기본 결재선 {n}명', {'n': f.defaultLine.length})) +
      (f.defaultCcIds.isEmpty
          ? ''
          : tr(' · 기본 참조 {n}명', {'n': f.defaultCcIds.length}));

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
                    }) +
                    _defaultsText(f),
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
                  // 기본 양식은 "기본 결재선"만, 직접 만든 양식은 고치기·기본 결재선·지우기.
                  PopupMenuButton<String>(
                    key: ValueKey('gw-form-menu-${f.id}'),
                    enabled: !_busy,
                    onSelected: (v) => switch (v) {
                      'edit' => _edit(f),
                      'defaults' => _editDefaults(f),
                      _ => _delete(f),
                    },
                    itemBuilder: (_) => [
                      if (!f.builtin)
                        PopupMenuItem(value: 'edit', child: Text(tr('고치기'))),
                      PopupMenuItem(
                        key: ValueKey('gw-form-defaults-${f.id}'),
                        value: 'defaults',
                        child: Text(tr('기본 결재선')),
                      ),
                      if (!f.builtin)
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

/// 양식 만들기·고치기 — 이름·설명·첨부, 칸(이름·종류·필수·설명, 고르기의 고를 거리, 사람 칸의 여러 명, 표 칸의 열)을 끌어서 순서 바꾸기.
class _FormDefinitionDialog extends StatefulWidget {
  final ApprovalForm? initial;
  const _FormDefinitionDialog({this.initial});

  @override
  State<_FormDefinitionDialog> createState() => _FormDefinitionDialogState();
}

/// 편집 중인 칸 하나 — [key]는 이미 있던 칸의 서버 key(새 칸은 ''). 저장할 때 그대로 보내 순서를 바꿔도 같은 칸(값)으로 남게 한다.
/// 끌어 옮길 때 줄을 알아보는 열쇠는 이 객체 자체(ObjectKey)라 입력 상자(controller)가 섞이지 않는다.
class _FieldDraft {
  final String key;
  final label = TextEditingController();
  final options = TextEditingController();
  final help = TextEditingController();
  FormFieldType type = FormFieldType.text;
  bool required = false;

  /// 사람 칸 — 여러 명 고르기.
  bool multiple = false;

  /// 표 칸 — 열들(표로 바꾸면 빈 열 하나로 시작).
  final columns = <_ColumnDraft>[];
  _FieldDraft({this.key = ''});

  void dispose() {
    label.dispose();
    options.dispose();
    help.dispose();
    for (final c in columns) {
      c.dispose();
    }
  }
}

/// 편집 중인 표 칸의 열 하나(이름·종류).
class _ColumnDraft {
  final TextEditingController label;
  FormTableColumnType type;
  _ColumnDraft({String label = '', this.type = FormTableColumnType.text})
    : label = TextEditingController(text: label);
  void dispose() => label.dispose();
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
        _FieldDraft(key: f.key)
          ..label.text = f.label
          ..type = f.type
          ..required = f.required
          ..options.text = f.options.join(', ')
          ..help.text = f.help ?? ''
          ..multiple = f.multiple
          ..columns.addAll([
            for (final c in f.columns)
              _ColumnDraft(label: c.label, type: c.type),
          ]),
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

  /// 칸 종류 바꾸기 — 표로 바꿨는데 열이 없으면 빈 열 하나를 넣어 둔다.
  void _setType(_FieldDraft d, FormFieldType type) => setState(() {
    d.type = type;
    if (type == FormFieldType.table && d.columns.isEmpty) {
      d.columns.add(_ColumnDraft());
    }
  });

  /// 줄을 지운다 — 입력 상자가 이번 그리기에서 빠진 뒤에 controller를 버린다.
  void _disposeLater(void Function() dispose) =>
      WidgetsBinding.instance.addPostFrameCallback((_) => dispose());

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
      final columns = <FormTableColumn>[];
      if (d.type == FormFieldType.table) {
        if (d.columns.isEmpty) {
          return setState(
            () => _error = tr('"{label}" 표에 열을 하나 이상 넣으세요.', {'label': label}),
          );
        }
        for (final (j, c) in d.columns.indexed) {
          final columnLabel = c.label.text.trim();
          if (columnLabel.isEmpty) {
            return setState(
              () => _error = tr('"{label}" 표의 {n}번째 열 이름을 넣으세요.', {
                'label': label,
                'n': j + 1,
              }),
            );
          }
          if (columns.any((e) => e.label == columnLabel)) {
            return setState(
              () => _error = tr('"{label}" 표에 "{column}" 열이 두 번 있습니다.', {
                'label': label,
                'column': columnLabel,
              }),
            );
          }
          columns.add(FormTableColumn(label: columnLabel, type: c.type));
        }
      }
      final help = d.help.text.trim();
      fields.add(
        FormFieldDef(
          key: d.key,
          label: label,
          type: d.type,
          required: d.required,
          options: options,
          help: help.isEmpty ? null : help,
          multiple: d.type == FormFieldType.person && d.multiple,
          columns: columns,
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

  /// 표 칸의 열 편집 — 열마다 이름·종류·빼기, "열 추가"(최대 [kFormTableColumnsMax]개).
  Widget _columnsEditor(int i, _FieldDraft d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (j, c) in d.columns.indexed)
          Row(
            key: ObjectKey(c),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 4,
                child: TextField(
                  key: ValueKey('gw-form-field-$i-col-$j-label'),
                  controller: c.label,
                  maxLength: 20,
                  decoration: InputDecoration(
                    labelText: tr('열 {n} 이름', {'n': j + 1}),
                    isDense: true,
                    counterText: '',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<FormTableColumnType>(
                  key: ValueKey('gw-form-field-$i-col-$j-type'),
                  initialValue: c.type,
                  isDense: true,
                  decoration: InputDecoration(
                    labelText: tr('열 종류'),
                    isDense: true,
                  ),
                  items: [
                    for (final t in FormTableColumnType.values)
                      DropdownMenuItem(value: t, child: Text(t.label)),
                  ],
                  onChanged: (v) => setState(() => c.type = v ?? c.type),
                ),
              ),
              IconButton(
                key: ValueKey('gw-form-field-$i-col-$j-remove'),
                tooltip: tr('열 빼기'),
                icon: const Icon(Icons.close, size: 16),
                onPressed: d.columns.length == 1
                    ? null
                    : () => setState(() {
                        final removed = d.columns.removeAt(j);
                        _disposeLater(removed.dispose);
                      }),
              ),
            ],
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: ValueKey('gw-form-field-$i-col-add'),
            onPressed: d.columns.length >= kFormTableColumnsMax
                ? null
                : () => setState(() => d.columns.add(_ColumnDraft())),
            icon: const Icon(Icons.add, size: 16),
            label: Text(tr('열 추가')),
          ),
        ),
      ],
    );
  }

  /// 칸 한 줄 — 손잡이·이름(고를 거리·설명)·종류·필수·빼기, 아래에 사람 칸의 "여러 명 고르기"나 표 칸의 열 편집.
  Widget _fieldRow(BuildContext context, int i) {
    final d = _fields[i];
    final hint = Theme.of(context).hintColor;
    return Padding(
      key: ObjectKey(d),
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ReorderableDragStartListener(
                key: ValueKey('gw-form-field-$i-drag'),
                index: i,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 12, 4, 0),
                  child: Icon(Icons.drag_indicator, color: hint),
                ),
              ),
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
                    TextField(
                      key: ValueKey('gw-form-field-$i-help'),
                      controller: d.help,
                      maxLength: kFormFieldHelpMax,
                      decoration: InputDecoration(
                        labelText: tr('칸 설명(선택 — 입력칸 아래에 보임)'),
                        isDense: true,
                        counterText: '',
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
                  onChanged: (v) => _setType(d, v ?? d.type),
                ),
              ),
              Column(
                children: [
                  Text(tr('필수'), style: TextStyle(fontSize: 11)),
                  Checkbox(
                    key: ValueKey('gw-form-field-$i-required'),
                    value: d.required,
                    onChanged: (v) => setState(() => d.required = v ?? false),
                  ),
                ],
              ),
              IconButton(
                tooltip: tr('칸 빼기'),
                icon: const Icon(Icons.close, size: 18),
                onPressed: _fields.length == 1
                    ? null
                    : () => setState(() {
                        final removed = _fields.removeAt(i);
                        _disposeLater(removed.dispose);
                      }),
              ),
            ],
          ),
          if (d.type == FormFieldType.person)
            Padding(
              padding: const EdgeInsets.only(left: 28),
              child: CheckboxListTile(
                key: ValueKey('gw-form-field-$i-multiple'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: d.multiple,
                onChanged: (v) => setState(() => d.multiple = v ?? false),
                title: Text(tr('여러 명 고르기')),
              ),
            ),
          if (d.type == FormFieldType.table)
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 4),
              child: _columnsEditor(i, d),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? tr('양식 만들기') : tr('양식 고치기')),
      content: SizedBox(
        width: 560,
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
              // 바깥(SingleChildScrollView)이 스크롤하므로 목록 자체는 스크롤하지 않고 칸 수만큼 늘어난다.
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: _fields.length,
                onReorderItem: (from, to) =>
                    setState(() => _fields.insert(to, _fields.removeAt(from))),
                itemBuilder: _fieldRow,
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

// ── 관리: 양식마다의 기본 결재선·참조자 ─────────────────────────────────────

/// 편집 중인 기본 결재선 한 칸(사람·역할).
class _LineDraft {
  final String userId;
  LineRole role;
  _LineDraft(this.userId, this.role);
}

/// 양식 하나(기본 양식도)의 기본 결재선·참조자 — 결재자 순서·역할(결재→합의→전결)·빼기·더하기, 참조자 더하기·빼기. 저장은 창 안에서
/// PATCH /groupware/forms/:id(defaultLine·defaultCcIds — 빈 목록이면 지움)로 하고, 저장했으면 true로 닫는다. 후보에 없는 사람(나간 사람
/// 등)은 "(알 수 없음)"으로 보이고 뺄 수 있다.
class _FormDefaultsDialog extends StatefulWidget {
  final GroupwareApi api;
  final ApprovalForm form;
  const _FormDefaultsDialog({required this.api, required this.form});

  @override
  State<_FormDefaultsDialog> createState() => _FormDefaultsDialogState();
}

class _FormDefaultsDialogState extends State<_FormDefaultsDialog> {
  late final _line = [
    for (final e in widget.form.defaultLine) _LineDraft(e.userId, e.role),
  ];
  late final _cc = [...widget.form.defaultCcIds];
  List<ApprovalCandidate>? _candidates;
  String? _loadError;

  /// 저장 실패(서버 오류) — 빨간 글.
  String? _error;

  /// 전결을 옮겼을 때처럼 알려 줄 것 — 흐린 글.
  String? _notice;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadCandidates();
  }

  Future<void> _loadCandidates() async {
    try {
      final candidates = await widget.api.candidates(includeSelf: true);
      if (mounted) setState(() => _candidates = candidates);
    } catch (e) {
      if (mounted) setState(() => _loadError = e.toString());
    }
  }

  /// 후보에서 이름 찾기 — 없으면 "(알 수 없음)".
  String _nameOf(String id) {
    for (final c in _candidates ?? const <ApprovalCandidate>[]) {
      if (c.id == id) return c.name;
    }
    return tr('(알 수 없음)');
  }

  /// 역할 바꾸기(결재 → 합의 → 전결 → 결재). 전결은 한 명만 — 다른 사람이 전결이었으면 그 사람을 결재로 돌리고 알린다.
  void _cycleRole(int i) => setState(() {
    final next = _line[i].role.next;
    _notice = null;
    if (next == LineRole.finalApprove) {
      for (final (j, other) in _line.indexed) {
        if (j != i && other.role == LineRole.finalApprove) {
          other.role = LineRole.approve;
          _notice = tr('전결은 한 명만 정할 수 있어 {name}님을 결재로 바꿨습니다.', {
            'name': _nameOf(other.userId),
          });
        }
      }
    }
    _line[i].role = next;
  });

  void _move(int i, int delta) =>
      setState(() => _line.insert(i + delta, _line.removeAt(i)));

  /// 사람 고르기 창 — 이미 결재자나 참조자로 넣은 사람은 빼고 보인다(같은 사람을 둘 다로 넣을 수 없다).
  Future<String?> _pick() async {
    final taken = {for (final d in _line) d.userId, ..._cc};
    return showDialog<String>(
      context: context,
      builder: (_) => _CandidatePickerDialog(
        candidates: [
          for (final c in _candidates ?? const <ApprovalCandidate>[])
            if (!taken.contains(c.id)) c,
        ],
      ),
    );
  }

  Future<void> _addApprover() async {
    final id = await _pick();
    if (id == null || !mounted) return;
    setState(() => _line.add(_LineDraft(id, LineRole.approve)));
  }

  Future<void> _addCc() async {
    final id = await _pick();
    if (id == null || !mounted) return;
    setState(() => _cc.add(id));
  }

  Future<void> _save() async {
    setState(() => (_saving = true, _error = null));
    try {
      await widget.api.updateForm(
        widget.form.id,
        defaultLine: [for (final d in _line) (userId: d.userId, role: d.role)],
        defaultCcIds: [..._cc],
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => (_saving = false, _error = tr('실패: {e}', {'e': e})));
      }
    }
  }

  Widget _approverRow(int i, Color hint) {
    final d = _line[i];
    return Row(
      key: ObjectKey(d),
      children: [
        SizedBox(
          width: 24,
          child: Text('${i + 1}', style: TextStyle(color: hint)),
        ),
        Expanded(
          child: Text(
            _nameOf(d.userId),
            key: ValueKey('gw-form-defaults-name-$i'),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        ActionChip(
          key: ValueKey('gw-form-defaults-role-$i'),
          tooltip: tr('눌러서 역할 바꾸기(결재 → 합의 → 전결)'),
          visualDensity: VisualDensity.compact,
          label: Text(d.role.label),
          onPressed: _saving ? null : () => _cycleRole(i),
        ),
        IconButton(
          key: ValueKey('gw-form-defaults-up-$i'),
          tooltip: tr('위로'),
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.arrow_upward, size: 18),
          onPressed: i == 0 || _saving ? null : () => _move(i, -1),
        ),
        IconButton(
          key: ValueKey('gw-form-defaults-down-$i'),
          tooltip: tr('아래로'),
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.arrow_downward, size: 18),
          onPressed: i == _line.length - 1 || _saving
              ? null
              : () => _move(i, 1),
        ),
        IconButton(
          key: ValueKey('gw-form-defaults-remove-$i'),
          tooltip: tr('빼기'),
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close, size: 18),
          onPressed: _saving
              ? null
              : () => setState(() => (_line.removeAt(i), _notice = null)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final ready = _candidates != null;
    return AlertDialog(
      title: Text(tr('"{name}" 기본 결재선', {'name': widget.form.name})),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tr(
                  '이 양식으로 새 결재를 쓸 때 결재선을 이 사람들로 미리 채웁니다(결재선 규칙·조직도 상위자보다 먼저). 기본 참조자만 정하면 결재자는 규칙·상위자로 채우고 참조자에 더합니다. 올리는 사람이 고칠 수 있고, 올리는 사람 자신은 빠집니다.',
                ),
                style: TextStyle(fontSize: 12, color: hint),
              ),
              const SizedBox(height: 12),
              if (_loadError != null)
                Text(
                  tr('사람 목록을 못 읽었습니다: {e}', {'e': _loadError}),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                )
              else if (!ready)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
              Text(
                tr('결재자(순서대로)'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (_line.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    tr('정하지 않음 — 결재선 규칙·조직도 상위자로 채웁니다.'),
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                ),
              for (final i in Iterable<int>.generate(_line.length))
                _approverRow(i, hint),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('gw-form-defaults-add-approver'),
                  onPressed:
                      !ready || _saving || _line.length >= _kDefaultLineMax
                      ? null
                      : _addApprover,
                  icon: const Icon(Icons.person_add_alt, size: 18),
                  label: Text(tr('결재자 추가')),
                ),
              ),
              const Divider(),
              Text(tr('참조자'), style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final id in _cc)
                    InputChip(
                      key: ValueKey('gw-form-defaults-cc-$id'),
                      label: Text(_nameOf(id)),
                      onDeleted: _saving
                          ? null
                          : () => setState(() => _cc.remove(id)),
                    ),
                  ActionChip(
                    key: const ValueKey('gw-form-defaults-add-cc'),
                    avatar: const Icon(Icons.add, size: 16),
                    label: Text(tr('참조자 추가')),
                    onPressed: !ready || _saving || _cc.length >= _kDefaultCcMax
                        ? null
                        : _addCc,
                  ),
                ],
              ),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _notice!,
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        TextButton(
          key: const ValueKey('gw-form-defaults-clear'),
          onPressed: _saving || (_line.isEmpty && _cc.isEmpty)
              ? null
              : () => setState(() {
                  _line.clear();
                  _cc.clear();
                  _notice = null;
                }),
          child: Text(tr('비우기')),
        ),
        FilledButton(
          key: const ValueKey('gw-form-defaults-save'),
          onPressed: _saving ? null : _save,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}

/// 결재자·참조자 후보 고르기 — 이름·아이디로 찾고, 누르면 그 사람 id로 닫는다.
class _CandidatePickerDialog extends StatefulWidget {
  final List<ApprovalCandidate> candidates;
  const _CandidatePickerDialog({required this.candidates});

  @override
  State<_CandidatePickerDialog> createState() => _CandidatePickerDialogState();
}

class _CandidatePickerDialogState extends State<_CandidatePickerDialog> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.text.trim().toLowerCase();
    final shown = [
      for (final c in widget.candidates)
        if (q.isEmpty ||
            c.name.toLowerCase().contains(q) ||
            c.username.toLowerCase().contains(q))
          c,
    ];
    return AlertDialog(
      title: Text(tr('사람 고르기')),
      content: SizedBox(
        width: 360,
        height: 400,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('gw-form-defaults-search'),
              controller: _query,
              autofocus: true,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: tr('이름·아이디로 찾기'),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: shown.isEmpty
                  ? Center(
                      child: Text(
                        tr('고를 사람이 없습니다.'),
                        style: TextStyle(color: Theme.of(context).hintColor),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final c in shown)
                          ListTile(
                            key: ValueKey('gw-form-defaults-pick-${c.id}'),
                            dense: true,
                            title: Text(c.name),
                            subtitle: Text(c.username),
                            onTap: () => Navigator.of(context).pop(c.id),
                          ),
                      ],
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
      ],
    );
  }
}
