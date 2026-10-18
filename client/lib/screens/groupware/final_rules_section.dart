import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../../models/groupware.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import 'groupware_screen.dart' show GroupwareChanges, GroupwareSectionHeader;
import 'line_rule_text.dart';
import '../../l10n/tr.dart';

/// 전결 규정이 걸리는 문서 — 한 양식만 정했으면 그 양식 이름(이름을 모르면 "관리자가 만든 양식 1개"), 아니면 종류 이름("모든 결재"·"지출"…).
/// 결재선 규칙의 [lineRuleKindText]와 같은 글(종류 이름은 [lineRuleKindLabel]을 같이 쓴다).
String finalRuleKindText(ApprovalFinalRule rule, {String? templateName}) {
  if (rule.kind == 'form' && rule.templateId != null) {
    final name = templateName ?? rule.templateName;
    return name == null || name.isEmpty
        ? tr('관리자가 만든 양식 1개')
        : tr('"{name}" 양식', {'name': name});
  }
  return lineRuleKindLabel(rule.kind);
}

/// 전결 규정 한 줄 — "{종류} · {금액} 이상 → {직책} 이상 전결"(금액 기준이 없으면 "{종류} → {직책} 이상 전결").
/// 예: "지출 · 100만 원 이상 → 본부장 이상 전결", "모든 결재 → 팀장 이상 전결".
String finalRuleSentence(ApprovalFinalRule rule, {String? templateName}) {
  final head = [
    finalRuleKindText(rule, templateName: templateName),
    if (rule.minAmount != null)
      tr('{amount} 이상', {'amount': shortWonText(rule.minAmount!)}),
  ].join(' · ');
  return '$head → ${tr('{position} 이상 전결', {'position': rule.positionLabel})}';
}

/// 관리 탭의 "전결 규정" — 결재 종류(와 양식·금액)마다 어느 직책 이상이 전결할지(서버 approvalFinalRules.js). 결재를 올리면 서버가
/// 결재선에서 직책이 [ApprovalFinalRule.positionLabel] 이상인 **첫** 결재자를 전결권자로 정하고(그 사람이 승인하면 남은 결재는 생략),
/// 올리는 사람이 고른 전결은 규정대로 바뀐다. 결재선에 그런 사람이 없으면 전결 없이 끝까지. 여러 규정이 맞으면 결재선 규칙과 같은 순서
/// (한 양식 > 종류 > 모든 결재, 그다음 문서 금액 이하인 것 중 금액 기준이 가장 큰 것)로 하나를 쓴다.
///
/// 목록은 누구나 받을 수 있지만(GET) 만들기·고치기·지우기는 그룹웨어 관리자([GroupwareContext.isManager])만 — 서버도 403으로 막는다.
/// 관리 탭은 관리자만 보므로 관리자가 아니면 섹션을 아예 그리지 않는다.
class FinalRulesAdminSection extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final GroupwareChanges changes;

  /// 직책 목록(누구나 부를 수 있는 GET /api/position-options)을 받는 데 쓴다 — 없으면 직책을 못 골라 저장할 수 없다.
  final Session? session;
  const FinalRulesAdminSection({
    super.key,
    required this.api,
    required this.ctx,
    required this.changes,
    this.session,
  });

  @override
  State<FinalRulesAdminSection> createState() => _FinalRulesAdminSectionState();
}

class _FinalRulesAdminSectionState extends State<FinalRulesAdminSection> {
  List<ApprovalFinalRule>? _rules;

  /// 관리자가 만든 양식(종류 'form') — 규정을 한 양식에만 걸 때 고른다.
  List<ApprovalForm> _templates = const [];
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.changes.addListener(_load);
    if (widget.ctx.isManager) _load();
  }

  @override
  void dispose() {
    widget.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    if (!widget.ctx.isManager) return;
    try {
      // 양식 목록을 못 받아도 규정 목록은 보이게 — 양식 이름은 서버가 붙여 준 templateName으로.
      final results = await Future.wait<Object>([
        widget.api.finalRules(),
        widget.api.forms().catchError((_) => <ApprovalForm>[]),
      ]);
      if (!mounted) return;
      setState(() {
        _rules = results[0] as List<ApprovalFinalRule>;
        _templates = [
          for (final f in results[1] as List<ApprovalForm>)
            if (f.kind == ApprovalKind.form) f,
        ];
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  String? _templateNameOf(String? id) {
    for (final f in _templates) {
      if (f.id == id) return f.name;
    }
    return null;
  }

  String _sentence(ApprovalFinalRule rule) =>
      finalRuleSentence(rule, templateName: _templateNameOf(rule.templateId));

  Future<void> _edit([ApprovalFinalRule? rule]) async {
    // 직책 목록은 창을 열 때 받는다 — 관리자 콘솔에서 방금 바꿨어도 맞게. 못 받으면 빈 목록(창이 안내를 보인다).
    var positions = <String>[];
    try {
      final session = widget.session;
      if (session != null) {
        positions = [
          for (final o in await session.fetchPublicPositionOptions()) o.label,
        ];
      }
    } catch (_) {}
    if (!mounted) return;
    final result = await showDialog<ApprovalFinalRule>(
      context: context,
      builder: (_) => _FinalRuleDialog(
        initial: rule,
        templates: _templates,
        positions: positions,
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.saveFinalRule(result);
      if (mounted) {
        showAppToast(
          context,
          rule == null ? tr('전결 규정을 만들었습니다.') : tr('전결 규정을 고쳤습니다.'),
        );
      }
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(ApprovalFinalRule rule) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('전결 규정 지우기')),
        content: Text(
          tr('"{rule}" 규정을 지울까요? 이미 올린 결재의 전결은 그대로입니다.', {
            'rule': _sentence(rule),
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('취소')),
          ),
          FilledButton(
            key: const ValueKey('gw-final-rule-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('지우기')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.deleteFinalRule(rule.id);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.ctx.isManager) return const SizedBox.shrink();
    final hint = Theme.of(context).hintColor;
    final rules = _rules;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupwareSectionHeader(
          tr('전결 규정'),
          trailing: TextButton.icon(
            key: const ValueKey('gw-final-rule-add'),
            onPressed: _busy || rules == null ? null : () => _edit(),
            icon: const Icon(Icons.add, size: 18),
            label: Text(tr('규정 추가')),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            tr(
              '결재 종류와 금액마다 누가 전결할지 정합니다. 결재를 올리면 결재선에서 이 직책 이상인 첫 결재자가 저절로 전결이 되고(승인하면 남은 결재는 생략), 올리는 사람이 고른 전결은 규정대로 바뀝니다. 결재선에 해당하는 사람이 없으면 끝까지 결재합니다.',
            ),
            style: TextStyle(fontSize: 12, color: hint),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
          child: Text(
            tr(
              '예: 지출 → 팀장 전결 · 지출 100만 원 이상 → 본부장 전결 · 지출 1,000만 원 이상 → 대표 전결',
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
              tr('규정이 없습니다 — 올리는 사람이 고른 전결대로 결재합니다.'),
              style: TextStyle(color: hint),
            ),
          )
        else
          for (final r in rules)
            ListTile(
              key: ValueKey('gw-final-rule-${r.id}'),
              dense: true,
              leading: const Icon(Icons.gavel_outlined),
              title: Text(_sentence(r)),
              onTap: _busy ? null : () => _edit(r),
              trailing: PopupMenuButton<String>(
                key: ValueKey('gw-final-rule-menu-${r.id}'),
                enabled: !_busy,
                tooltip: tr('더 보기'),
                onSelected: (v) => v == 'delete' ? _delete(r) : _edit(r),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'edit', child: Text(tr('고치기'))),
                  PopupMenuItem(value: 'delete', child: Text(tr('지우기'))),
                ],
              ),
            ),
      ],
    );
  }
}

/// 전결 규정 만들기·고치기 — 종류(관리자가 만든 양식이면 한 양식만도), 금액 기준(선택), 전결할 직책(반드시).
/// 다 맞으면 [ApprovalFinalRule]을 돌려준다(고칠 때는 처음 규정의 id 그대로 — 저장은 부른 쪽이).
class _FinalRuleDialog extends StatefulWidget {
  final ApprovalFinalRule? initial;
  final List<ApprovalForm> templates;
  final List<String> positions;
  const _FinalRuleDialog({
    this.initial,
    required this.templates,
    required this.positions,
  });

  @override
  State<_FinalRuleDialog> createState() => _FinalRuleDialogState();
}

class _FinalRuleDialogState extends State<_FinalRuleDialog> {
  late String _kind = widget.initial?.kind ?? 'any';
  late String? _templateId = widget.initial?.templateId;
  late final _minAmount = TextEditingController(
    text: widget.initial?.minAmount?.toString() ?? '',
  );
  late String? _position = (widget.initial?.positionLabel ?? '').isEmpty
      ? null
      : widget.initial!.positionLabel;
  String? _error;

  /// 고를 직책 — 처음 규정의 직책이 목록에서 없어졌어도 보이게 붙인다(서버는 목록에 없는 직책을 받지 않으니 다시 골라야 저장된다).
  List<String> get _positionChoices => [
    ...widget.positions,
    if (_position != null && !widget.positions.contains(_position)) _position!,
  ];

  @override
  void dispose() {
    _minAmount.dispose();
    super.dispose();
  }

  void _done() {
    final amountText = _minAmount.text.trim();
    final minAmount = amountText.isEmpty ? null : int.tryParse(amountText);
    if (amountText.isNotEmpty && minAmount == null) {
      setState(() => _error = tr('금액은 원 단위 숫자로 넣으세요.'));
      return;
    }
    if (_position == null) {
      setState(() => _error = tr('전결할 직책을 고르세요.'));
      return;
    }
    Navigator.of(context).pop(
      ApprovalFinalRule(
        id: widget.initial?.id ?? '',
        kind: _kind,
        templateId: _kind == 'form' ? _templateId : null,
        minAmount: minAmount,
        positionLabel: _position!,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final amount = int.tryParse(_minAmount.text.trim());
    final positions = _positionChoices;
    return AlertDialog(
      title: Text(widget.initial == null ? tr('전결 규정 추가') : tr('전결 규정 고치기')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                key: const ValueKey('gw-final-rule-kind'),
                initialValue: _kind,
                decoration: InputDecoration(
                  labelText: tr('결재 종류'),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  // 서버 approvalFinalRules.js가 받는 종류 — 결재선 규칙과 같은 목록.
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
                  key: const ValueKey('gw-final-rule-form'),
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
                key: const ValueKey('gw-final-rule-amount'),
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
              if (positions.isEmpty)
                Text(
                  tr('직책 목록이 비어 있습니다 — 관리자 콘솔에서 직책을 먼저 만드세요.'),
                  key: const ValueKey('gw-final-rule-no-positions'),
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.error,
                  ),
                )
              else
                DropdownButtonFormField<String>(
                  key: const ValueKey('gw-final-rule-position'),
                  initialValue: _position,
                  decoration: InputDecoration(
                    labelText: tr('전결할 직책'),
                    border: const OutlineInputBorder(),
                    helperText: tr('결재선에서 이 직책 이상인 첫 결재자가 전결합니다.'),
                  ),
                  items: [
                    for (final p in positions)
                      DropdownMenuItem(value: p, child: Text(p)),
                  ],
                  onChanged: (v) => setState(() => _position = v),
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
          key: const ValueKey('gw-final-rule-save'),
          onPressed: _done,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}
