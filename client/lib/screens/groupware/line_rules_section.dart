import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../../models/groupware.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import 'groupware_screen.dart' show GroupwareChanges, GroupwareSectionHeader;
import 'line_rule_text.dart';
import '../../l10n/tr.dart';

/// 늘 붙일 결재자·늘 넣을 참조자는 각각 이만큼까지(서버 approvalLineRules.js EXTRA_MAX).
const _peopleMax = 5;

/// 상위자 수는 0~이만큼(서버 RULE_LEVELS_MAX).
const _levelsMax = 10;

/// 관리 탭의 "결재선 규칙" — 결재 종류(와 금액)마다 조직도 상위자 사슬을 어디까지 채울지, 늘 붙일 결재자·참조자(서버
/// approvalLineRules.js). 목록은 누구나 보지만 만들기·고치기·지우기는 그룹웨어 관리자([GroupwareContext.isManager])만. 규칙은
/// 신청 창이 결재선을 **미리 채울 때만** 쓰고(approval_forms.dart ApprovalLinePicker), 올리는 사람이 고칠 수 있다.
class LineRulesAdminSection extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final GroupwareChanges changes;

  /// 직책 목록(누구나 부를 수 있는 GET /api/position-options)을 받는 데 쓴다.
  final Session session;
  const LineRulesAdminSection({
    super.key,
    required this.api,
    required this.ctx,
    required this.changes,
    required this.session,
  });

  @override
  State<LineRulesAdminSection> createState() => _LineRulesAdminSectionState();
}

class _LineRulesAdminSectionState extends State<LineRulesAdminSection> {
  List<ApprovalLineRule>? _rules;
  List<ApprovalCandidate> _candidates = const [];

  /// 관리자가 만든 양식(종류 'form') — 규칙을 한 양식에만 걸 때 고른다.
  List<ApprovalForm> _templates = const [];
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
      // 사람·양식 목록을 못 받아도 규칙 목록은 보이게 — 이름 대신 "(알 수 없음)".
      final results = await Future.wait<Object>([
        widget.api.lineRules(),
        widget.api.candidates().catchError((_) => <ApprovalCandidate>[]),
        widget.api.forms().catchError((_) => <ApprovalForm>[]),
      ]);
      if (!mounted) return;
      setState(() {
        _rules = results[0] as List<ApprovalLineRule>;
        _candidates = results[1] as List<ApprovalCandidate>;
        _templates = [
          for (final f in results[2] as List<ApprovalForm>)
            if (f.kind == ApprovalKind.form) f,
        ];
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  String _nameOf(String id) {
    for (final c in _candidates) {
      if (c.id == id) return c.name;
    }
    return tr('(알 수 없음)');
  }

  String? _templateNameOf(String? id) {
    for (final f in _templates) {
      if (f.id == id) return f.name;
    }
    return null;
  }

  Future<void> _edit([ApprovalLineRule? rule]) async {
    // 직책 목록은 창을 열 때 받는다 — 관리자 콘솔에서 방금 바꿨어도 맞게. 못 받으면 "직책 기준"만 못 고른다.
    var positions = <String>[];
    try {
      positions = [
        for (final o in await widget.session.fetchPublicPositionOptions())
          o.label,
      ];
    } catch (_) {}
    if (!mounted) return;
    final result = await showDialog<ApprovalLineRule>(
      context: context,
      builder: (_) => _LineRuleDialog(
        initial: rule,
        candidates: _candidates,
        templates: _templates,
        positions: positions,
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.saveLineRule(result);
      if (mounted) {
        showAppToast(
          context,
          rule == null ? tr('결재선 규칙을 만들었습니다.') : tr('결재선 규칙을 고쳤습니다.'),
        );
      }
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(ApprovalLineRule rule) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('결재선 규칙 지우기')),
        content: Text(
          tr('"{rule}" 규칙을 지울까요? 이미 올린 결재의 결재선은 그대로입니다.', {
            'rule': _sentence(rule),
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('취소')),
          ),
          FilledButton(
            key: const ValueKey('line-rule-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('지우기')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.deleteLineRule(rule.id);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _sentence(ApprovalLineRule rule) => lineRuleSentence(
    rule,
    nameOf: _nameOf,
    templateName: _templateNameOf(rule.templateId),
  );

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final rules = _rules;
    final manager = widget.ctx.isManager;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupwareSectionHeader(
          tr('결재선 규칙'),
          trailing: manager
              ? TextButton.icon(
                  key: const ValueKey('line-rule-add'),
                  onPressed: _busy || rules == null ? null : () => _edit(),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(tr('규칙 추가')),
                )
              : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            tr(
              '규칙은 결재선을 미리 채울 때만 씁니다 — 올리는 사람이 고칠 수 있습니다. 규칙이 없으면 상위자를 5명까지 채웁니다.',
            ),
            style: TextStyle(fontSize: 12, color: hint),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
          child: Text(
            tr(
              '예: 휴가 → 상위자 1명까지(팀장) · 지출 100만 원 이상 → 직책 본부장 이상까지 + 결재 재무팀장. 한 문서에 여러 규칙이 맞으면 종류가 꼭 맞는 것, 그중 금액 기준이 큰 것을 씁니다.',
            ),
            style: TextStyle(fontSize: 12, color: hint),
          ),
        ),
        if (_error != null)
          Padding(padding: const EdgeInsets.all(16), child: Text(_error!))
        else if (rules == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (rules.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              tr('규칙이 없습니다 — 결재선은 조직도 상위자로 채웁니다.'),
              style: TextStyle(color: hint),
            ),
          )
        else
          for (final r in rules)
            ListTile(
              key: ValueKey('line-rule-${r.id}'),
              dense: true,
              leading: const Icon(Icons.account_tree_outlined),
              title: Text(_sentence(r)),
              onTap: manager && !_busy ? () => _edit(r) : null,
              trailing: manager
                  ? IconButton(
                      key: ValueKey('line-rule-delete-${r.id}'),
                      tooltip: tr('지우기'),
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: _busy ? null : () => _delete(r),
                    )
                  : null,
            ),
      ],
    );
  }
}

/// 규칙 만들기·고치기 — 종류(관리자가 만든 양식이면 한 양식만도), 금액 기준, 어디까지(상위자 수 | 직책), 늘 붙일 결재자·참조자.
/// 다 맞으면 [ApprovalLineRule]을 돌려준다(고칠 때는 처음 규칙의 id 그대로 — 저장은 부른 쪽이).
class _LineRuleDialog extends StatefulWidget {
  final ApprovalLineRule? initial;
  final List<ApprovalCandidate> candidates;
  final List<ApprovalForm> templates;
  final List<String> positions;
  const _LineRuleDialog({
    this.initial,
    required this.candidates,
    required this.templates,
    required this.positions,
  });

  @override
  State<_LineRuleDialog> createState() => _LineRuleDialogState();
}

class _LineRuleDialogState extends State<_LineRuleDialog> {
  late String _kind = widget.initial?.kind ?? 'any';
  late String? _templateId = widget.initial?.templateId;
  late final _minAmount = TextEditingController(
    text: widget.initial?.minAmount?.toString() ?? '',
  );
  late String _mode = widget.initial?.mode ?? 'levels';
  late final _levels = TextEditingController(
    text: '${widget.initial?.levels ?? 1}',
  );
  late String? _position = widget.initial?.positionLabel;
  late final List<String> _extra = List.of(
    widget.initial?.extraApproverIds ?? const [],
  );
  late final List<String> _cc = List.of(widget.initial?.ccIds ?? const []);
  String? _error;

  /// 고를 직책 — 처음 규칙의 직책이 목록에서 없어졌어도 보이게 붙인다.
  List<String> get _positionChoices => [
    ...widget.positions,
    if (_position != null && !widget.positions.contains(_position)) _position!,
  ];

  @override
  void dispose() {
    _minAmount.dispose();
    _levels.dispose();
    super.dispose();
  }

  String _nameOf(String id) {
    for (final c in widget.candidates) {
      if (c.id == id) return c.name;
    }
    return tr('(알 수 없음)');
  }

  Future<void> _pickPeople({required bool cc}) async {
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (_) => _PeoplePickerDialog(
        title: cc ? tr('늘 넣을 참조자') : tr('늘 붙일 결재자'),
        candidates: [
          // 같은 사람을 결재자와 참조자로 함께 넣을 수 없다(서버 parseLineRule).
          for (final c in widget.candidates)
            if (!(cc ? _extra : _cc).contains(c.id)) c,
        ],
        selected: cc ? _cc : _extra,
      ),
    );
    if (picked == null) return;
    setState(() {
      final target = cc ? _cc : _extra;
      target
        ..clear()
        ..addAll(picked);
    });
  }

  void _done() {
    final amountText = _minAmount.text.trim();
    final minAmount = amountText.isEmpty ? null : int.tryParse(amountText);
    if (amountText.isNotEmpty && minAmount == null) {
      setState(() => _error = tr('금액은 원 단위 숫자로 넣으세요.'));
      return;
    }
    int? levels;
    if (_mode == 'levels') {
      levels = int.tryParse(_levels.text.trim());
      if (levels == null || levels < 0 || levels > _levelsMax) {
        setState(
          () => _error = tr('상위자 수는 0~{max}명으로 정하세요.', {'max': _levelsMax}),
        );
        return;
      }
    } else if (_position == null) {
      setState(() => _error = tr('어느 직책까지 채울지 고르세요.'));
      return;
    }
    Navigator.of(context).pop(
      ApprovalLineRule(
        id: widget.initial?.id ?? '',
        kind: _kind,
        templateId: _kind == 'form' ? _templateId : null,
        minAmount: minAmount,
        mode: _mode,
        levels: levels,
        positionLabel: _mode == 'position' ? _position : null,
        extraApproverIds: List.of(_extra),
        ccIds: List.of(_cc),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final amount = int.tryParse(_minAmount.text.trim());
    final positions = _positionChoices;
    String peopleText(List<String> ids) =>
        ids.isEmpty ? tr('없음') : ids.map(_nameOf).join(', ');
    return AlertDialog(
      title: Text(widget.initial == null ? tr('결재선 규칙 추가') : tr('결재선 규칙 고치기')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                key: const ValueKey('line-rule-kind'),
                initialValue: _kind,
                decoration: InputDecoration(
                  labelText: tr('결재 종류'),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  for (final k in lineRuleKinds)
                    DropdownMenuItem(
                      value: k,
                      child: Text(lineRuleKindLabel(k)),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _kind = v ?? _kind;
                  if (_kind != 'form') _templateId = null;
                }),
              ),
              if (_kind == 'form') ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String?>(
                  key: const ValueKey('line-rule-template'),
                  initialValue: widget.templates.any((f) => f.id == _templateId)
                      ? _templateId
                      : null,
                  decoration: InputDecoration(
                    labelText: tr('양식'),
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem<String?>(
                      value: null,
                      child: Text(tr('모든 양식')),
                    ),
                    for (final f in widget.templates)
                      DropdownMenuItem<String?>(
                        value: f.id,
                        child: Text(f.name),
                      ),
                  ],
                  onChanged: (v) => setState(() => _templateId = v),
                ),
              ],
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('line-rule-min-amount'),
                controller: _minAmount,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: tr('이 금액 이상일 때만(원, 선택)'),
                  border: const OutlineInputBorder(),
                  suffixText: tr('원'),
                  helperText: amount == null
                      ? tr('비우면 금액과 상관없이 씁니다.')
                      // 짧게 적은 금액이 같으면(만·억으로 안 떨어지거나 영어) 한 번만 적는다.
                      : shortWonText(amount) == wonText(amount)
                      ? tr('{won} 이상인 문서에 씁니다.', {'won': wonText(amount)})
                      : tr('{won}({short}) 이상인 문서에 씁니다.', {
                          'won': wonText(amount),
                          'short': shortWonText(amount),
                        }),
                ),
              ),
              const SizedBox(height: 8),
              Text(tr('결재선을 어디까지 채울지'), style: theme.textTheme.bodySmall),
              RadioGroup<String>(
                groupValue: _mode,
                onChanged: (v) => setState(() => _mode = v ?? _mode),
                child: Column(
                  children: [
                    RadioListTile<String>(
                      key: const ValueKey('line-rule-mode-levels'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: 'levels',
                      title: Text(tr('상위자 몇 명까지')),
                    ),
                    RadioListTile<String>(
                      key: const ValueKey('line-rule-mode-position'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: 'position',
                      title: Text(tr('이 직책 이상인 상위자까지')),
                    ),
                  ],
                ),
              ),
              if (_mode == 'levels')
                TextField(
                  key: const ValueKey('line-rule-levels'),
                  controller: _levels,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: tr('상위자 수 (0~{max}명)', {'max': _levelsMax}),
                    border: const OutlineInputBorder(),
                    suffixText: tr('명'),
                    helperText: tr(
                      '1명이면 바로 위 상위자(예: 팀장)까지, 0명이면 상위자를 넣지 않습니다.',
                    ),
                  ),
                )
              else if (positions.isEmpty)
                Text(
                  tr('직책 목록이 비어 있습니다 — 관리자 콘솔에서 직책을 먼저 만드세요.'),
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.error,
                  ),
                )
              else
                DropdownButtonFormField<String>(
                  key: const ValueKey('line-rule-position'),
                  initialValue: _position,
                  decoration: InputDecoration(
                    labelText: tr('직책'),
                    border: const OutlineInputBorder(),
                    helperText: tr('이 직책 이상인 첫 상위자까지(그 사람 포함) 채웁니다.'),
                  ),
                  items: [
                    for (final p in positions)
                      DropdownMenuItem(value: p, child: Text(p)),
                  ],
                  onChanged: (v) => setState(() => _position = v),
                ),
              const SizedBox(height: 4),
              ListTile(
                key: const ValueKey('line-rule-extra'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.person_add_alt),
                title: Text(
                  tr('늘 붙일 결재자 ({n}/{max})', {
                    'n': _extra.length,
                    'max': _peopleMax,
                  }),
                ),
                subtitle: Text(
                  peopleText(_extra),
                  style: TextStyle(color: hint),
                ),
                onTap: () => _pickPeople(cc: false),
              ),
              ListTile(
                key: const ValueKey('line-rule-cc'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.visibility_outlined),
                title: Text(
                  tr('늘 넣을 참조자 ({n}/{max})', {
                    'n': _cc.length,
                    'max': _peopleMax,
                  }),
                ),
                subtitle: Text(peopleText(_cc), style: TextStyle(color: hint)),
                onTap: () => _pickPeople(cc: true),
              ),
              Text(
                tr(
                  '늘 붙일 결재자는 상위자 다음에 차례로 붙습니다(예: 재무팀장, 대표). 올리는 사람 자신과 이미 들어 있는 사람은 뺍니다.',
                ),
                style: TextStyle(fontSize: 12, color: hint),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
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
          key: const ValueKey('line-rule-save'),
          onPressed: _done,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}

/// 여러 사람 고르기(최대 [_peopleMax]명) — 이름·아이디로 찾고 체크해서 "확인". 고른 순서를 지킨다(늘 붙일 결재자의 결재 순서).
class _PeoplePickerDialog extends StatefulWidget {
  final String title;
  final List<ApprovalCandidate> candidates;
  final List<String> selected;
  const _PeoplePickerDialog({
    required this.title,
    required this.candidates,
    required this.selected,
  });

  @override
  State<_PeoplePickerDialog> createState() => _PeoplePickerDialogState();
}

class _PeoplePickerDialogState extends State<_PeoplePickerDialog> {
  late final List<String> _picked = List.of(widget.selected);
  String _query = '';

  void _toggle(String id) => setState(() {
    if (_picked.contains(id)) {
      _picked.remove(id);
    } else if (_picked.length < _peopleMax) {
      _picked.add(id);
    }
  });

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final hint = Theme.of(context).hintColor;
    final shown = [
      for (final c in widget.candidates)
        if (q.isEmpty ||
            c.name.toLowerCase().contains(q) ||
            c.username.toLowerCase().contains(q))
          c,
    ];
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        height: 420,
        child: Column(
          children: [
            TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: tr('이름·아이디로 찾기'),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                tr('{n}/{max}명 골랐습니다 — 고른 순서대로 붙습니다.', {
                  'n': _picked.length,
                  'max': _peopleMax,
                }),
                style: TextStyle(fontSize: 12, color: hint),
              ),
            ),
            Expanded(
              child: shown.isEmpty
                  ? Center(
                      child: Text(
                        tr('고를 수 있는 사람이 없습니다(정회원 이상만 결재선에 넣을 수 있습니다).'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: hint),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final c in shown)
                          CheckboxListTile(
                            key: ValueKey('line-rule-person-${c.id}'),
                            dense: true,
                            value: _picked.contains(c.id),
                            title: Text(c.name),
                            subtitle: Text(c.username),
                            onChanged:
                                _picked.contains(c.id) ||
                                    _picked.length < _peopleMax
                                ? (_) => _toggle(c.id)
                                : null,
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
        FilledButton(
          key: const ValueKey('line-rule-people-ok'),
          onPressed: () => Navigator.of(context).pop(List.of(_picked)),
          child: Text(tr('확인')),
        ),
      ],
    );
  }
}
