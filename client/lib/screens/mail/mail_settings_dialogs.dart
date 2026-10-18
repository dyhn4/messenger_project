import 'package:flutter/material.dart';

import '../../l10n/tr.dart';
import '../../models/mail.dart';
import '../../services/api_client.dart' show ApiException;
import '../../services/mail_api.dart';
import '../../widgets/app_toast.dart';

/// 메일 계정의 설정 창들 — 서명(계정마다, 새 메일·답장에 저절로 붙일지)과 받는 규칙(보낸 사람·받는 사람·제목으로 골라 옮기기·읽음·중요·
/// 알리지 않기 — server webmailRules.js parseRule·planRules).

/// 서명 고치기 — 바꿨으면 바뀐 계정.
Future<MailAccount?> showMailSignatureDialog(
  BuildContext context, {
  required MailApi api,
  required MailAccount account,
}) => showDialog<MailAccount>(
  context: context,
  builder: (_) => _SignatureDialog(api: api, account: account),
);

class _SignatureDialog extends StatefulWidget {
  final MailApi api;
  final MailAccount account;
  const _SignatureDialog({required this.api, required this.account});

  @override
  State<_SignatureDialog> createState() => _SignatureDialogState();
}

class _SignatureDialogState extends State<_SignatureDialog> {
  late final _text = TextEditingController(text: widget.account.signature);
  late bool _onNew = widget.account.signatureOnNew;
  late bool _onReply = widget.account.signatureOnReply;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final next = await widget.api.updateAccount(
        widget.account.id,
        signature: _text.text,
        signatureOnNew: _onNew,
        signatureOnReply: _onReply,
      );
      if (mounted) Navigator.of(context).pop(next);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e is ApiException ? trServer(e.message) : tr('저장하지 못했습니다.');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(tr('서명 — {email}', {'email': widget.account.email})),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('mail-signature-text'),
              controller: _text,
              minLines: 4,
              maxLines: 10,
              maxLength: 2000,
              decoration: InputDecoration(
                hintText: tr('예: 홍길동 드림\n영업팀 · 010-0000-0000'),
                border: const OutlineInputBorder(),
              ),
            ),
            CheckboxListTile(
              key: const ValueKey('mail-signature-new'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: _onNew,
              title: Text(tr('새 메일에 넣기')),
              onChanged: (v) => setState(() => _onNew = v ?? _onNew),
            ),
            CheckboxListTile(
              key: const ValueKey('mail-signature-reply'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: _onReply,
              title: Text(tr('답장·전달에 넣기(인용 앞)')),
              onChanged: (v) => setState(() => _onReply = v ?? _onReply),
            ),
            if (_error != null)
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('mail-signature-save'),
          onPressed: _saving ? null : _save,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}

/// 받는 규칙 — 계정의 규칙 목록(차례대로 건다 — 끌어서 바꿈), 더하기·고치기·지우기·켜고 끄기, "지금 받은편지함에 적용".
/// [folders]는 옮길 폴더 후보.
Future<void> showMailRulesDialog(
  BuildContext context, {
  required MailApi api,
  required MailAccount account,
  required List<MailFolder> folders,
}) => showDialog<void>(
  context: context,
  builder: (_) => _RulesDialog(api: api, account: account, folders: folders),
);

String _fieldLabel(String field) => switch (field) {
  'from' => tr('보낸 사람'),
  'to' => tr('받는 사람(참조 포함)'),
  _ => tr('제목'),
};

String _opLabel(String op) => switch (op) {
  'not_contains' => tr('이(가) 들어 있지 않으면'),
  'is' => tr('이(가) 이것과 같으면'),
  _ => tr('에 들어 있으면'),
};

/// 규칙 한 줄 요약 — "보낸 사람에 'news' 들어 있으면 → 업무로 옮기기, 읽음".
String mailRuleSummary(MailRule r, List<MailFolder> folders) {
  final cond = r.conditions
      .map((c) => '${_fieldLabel(c.field)} "${c.value}" ${_opLabel(c.op)}')
      .join(r.match == 'any' ? tr(' 또는 ') : tr(' 그리고 '));
  final folderName =
      folders.where((f) => f.path == r.moveTo).firstOrNull?.name ?? r.moveTo;
  final acts = [
    if (r.moveTo != null) tr('{f}(으)로 옮기기', {'f': folderName}),
    if (r.markSeen) tr('읽음'),
    if (r.flag) tr('중요'),
    if (r.skipNotify) tr('알리지 않기'),
    if (r.stop) tr('뒤 규칙은 안 봄'),
  ].join(', ');
  return '$cond → $acts';
}

class _RulesDialog extends StatefulWidget {
  final MailApi api;
  final MailAccount account;
  final List<MailFolder> folders;
  const _RulesDialog({
    required this.api,
    required this.account,
    required this.folders,
  });

  @override
  State<_RulesDialog> createState() => _RulesDialogState();
}

class _RulesDialogState extends State<_RulesDialog> {
  List<MailRule>? _rules;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rules = await widget.api.rules(widget.account.id);
      if (mounted) setState(() => _rules = rules);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is ApiException ? trServer(e.message) : '$e');
      }
    }
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
    } catch (e) {
      if (mounted) {
        showAppToast(context, e is ApiException ? trServer(e.message) : '$e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([MailRule? rule]) async {
    final saved = await showDialog<MailRule>(
      context: context,
      builder: (_) => _RuleEditor(
        api: widget.api,
        account: widget.account,
        folders: widget.folders,
        rule: rule,
      ),
    );
    if (saved == null || !mounted) return;
    setState(() {
      final list = [...?_rules];
      final i = list.indexWhere((r) => r.id == saved.id);
      if (i >= 0) {
        list[i] = saved;
      } else {
        list.add(saved);
      }
      _rules = list;
    });
  }

  Future<void> _toggle(MailRule r, bool on) => _run(() async {
    final saved = await widget.api.saveRule(
      widget.account.id,
      MailRule(
        id: r.id,
        name: r.name,
        enabled: on,
        match: r.match,
        conditions: r.conditions,
        moveTo: r.moveTo,
        markSeen: r.markSeen,
        flag: r.flag,
        skipNotify: r.skipNotify,
        stop: r.stop,
      ),
    );
    if (mounted) {
      setState(
        () => _rules = [for (final x in _rules!) x.id == saved.id ? saved : x],
      );
    }
  });

  Future<void> _delete(MailRule r) => _run(() async {
    await widget.api.deleteRule(r.id);
    if (mounted) {
      setState(
        () => _rules = [
          for (final x in _rules!)
            if (x.id != r.id) x,
        ],
      );
    }
  });

  Future<void> _reorder(int from, int to) => _run(() async {
    final list = [..._rules!];
    final moved = list.removeAt(from);
    list.insert(to, moved);
    setState(() => _rules = list);
    final saved = await widget.api.reorderRules(widget.account.id, [
      for (final r in list) r.id,
    ]);
    if (mounted) setState(() => _rules = saved);
  });

  Future<void> _apply() => _run(() async {
    final r = await widget.api.applyRules(widget.account.id);
    if (mounted) {
      showAppToast(
        context,
        tr('받은편지함의 {matched}통에 규칙을 걸었습니다(옮긴 메일 {moved}통).', {
          'matched': r.matched,
          'moved': r.moved,
        }),
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rules = _rules;
    return AlertDialog(
      title: Text(tr('받는 규칙 — {email}', {'email': widget.account.email})),
      content: SizedBox(
        width: 560,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr(
                '새로 온 받은편지함 메일에 위에서부터 차례대로 겁니다(끌어서 차례를 바꿉니다). 다른 폴더로 옮긴 메일은 알리지 않습니다.',
              ),
              style: TextStyle(fontSize: 12, color: theme.hintColor),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: rules == null
                  ? Center(
                      child: _error != null
                          ? Text(_error!)
                          : const CircularProgressIndicator(),
                    )
                  : rules.isEmpty
                  ? Center(
                      child: Text(
                        tr('규칙이 없습니다. "규칙 더하기"로 만드세요.'),
                        style: TextStyle(color: theme.hintColor),
                      ),
                    )
                  : ReorderableListView(
                      buildDefaultDragHandles: true,
                      onReorderItem: _busy ? (_, _) {} : _reorder,
                      children: [
                        for (final r in rules)
                          ListTile(
                            key: ValueKey('mail-rule-${r.id}'),
                            dense: true,
                            leading: Switch(
                              value: r.enabled,
                              onChanged: _busy ? null : (v) => _toggle(r, v),
                            ),
                            title: Text(r.name),
                            subtitle: Text(
                              mailRuleSummary(r, widget.folders),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => _edit(r),
                            trailing: Padding(
                              padding: const EdgeInsets.only(right: 24),
                              child: IconButton(
                                tooltip: tr('지우기'),
                                icon: const Icon(Icons.delete_outline),
                                onPressed: _busy ? null : () => _delete(r),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('mail-rules-apply'),
          onPressed: _busy || (rules?.isEmpty ?? true) ? null : _apply,
          child: Text(tr('지금 받은편지함에 적용')),
        ),
        TextButton(
          key: const ValueKey('mail-rules-add'),
          onPressed: _busy || rules == null ? null : () => _edit(),
          child: Text(tr('규칙 더하기')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('닫기')),
        ),
      ],
    );
  }
}

class _RuleEditor extends StatefulWidget {
  final MailApi api;
  final MailAccount account;
  final List<MailFolder> folders;
  final MailRule? rule;
  const _RuleEditor({
    required this.api,
    required this.account,
    required this.folders,
    this.rule,
  });

  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<_RuleEditor> {
  late final _name = TextEditingController(text: widget.rule?.name ?? '');
  late String _match = widget.rule?.match ?? 'all';
  late final List<({String field, String op, TextEditingController value})>
  _conditions = [
    for (final c in widget.rule?.conditions ?? const [MailRuleCondition()])
      (field: c.field, op: c.op, value: TextEditingController(text: c.value)),
  ];
  late String? _moveTo = widget.rule?.moveTo;
  late bool _markSeen = widget.rule?.markSeen ?? false;
  late bool _flag = widget.rule?.flag ?? false;
  late bool _skipNotify = widget.rule?.skipNotify ?? false;
  late bool _stop = widget.rule?.stop ?? false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    for (final c in _conditions) {
      c.value.dispose();
    }
    super.dispose();
  }

  void _setCondition(int i, {String? field, String? op}) {
    final c = _conditions[i];
    setState(
      () => _conditions[i] = (
        field: field ?? c.field,
        op: op ?? c.op,
        value: c.value,
      ),
    );
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.api.saveRule(
        widget.account.id,
        MailRule(
          id: widget.rule?.id ?? '',
          name: _name.text.trim(),
          enabled: widget.rule?.enabled ?? true,
          match: _match,
          conditions: [
            for (final c in _conditions)
              MailRuleCondition(
                field: c.field,
                op: c.op,
                value: c.value.text.trim(),
              ),
          ],
          moveTo: _moveTo,
          markSeen: _markSeen,
          flag: _flag,
          skipNotify: _skipNotify,
          stop: _stop,
        ),
      );
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e is ApiException ? trServer(e.message) : tr('저장하지 못했습니다.');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final targets = [
      for (final f in widget.folders)
        if (!f.isInbox && !f.isDrafts && !f.isSent) f,
    ];
    return AlertDialog(
      title: Text(widget.rule == null ? tr('규칙 더하기') : tr('규칙 고치기')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('mail-rule-name'),
                controller: _name,
                maxLength: 50,
                decoration: InputDecoration(
                  labelText: tr('규칙 이름'),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(tr('조건')),
                  const Spacer(),
                  SegmentedButton<String>(
                    segments: [
                      ButtonSegment(value: 'all', label: Text(tr('모두 맞으면'))),
                      ButtonSegment(value: 'any', label: Text(tr('하나라도 맞으면'))),
                    ],
                    selected: {_match},
                    onSelectionChanged: (s) => setState(() => _match = s.first),
                  ),
                ],
              ),
              for (final (i, c) in _conditions.indexed)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      DropdownButton<String>(
                        key: ValueKey('mail-rule-field-$i'),
                        value: c.field,
                        items: [
                          for (final f in const ['from', 'to', 'subject'])
                            DropdownMenuItem(
                              value: f,
                              child: Text(_fieldLabel(f)),
                            ),
                        ],
                        onChanged: (v) => _setCondition(i, field: v),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: TextField(
                          key: ValueKey('mail-rule-value-$i'),
                          controller: c.value,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: c.field == 'subject'
                                ? tr('예: 주간 보고')
                                : tr('예: news@example.com 또는 example.com'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      DropdownButton<String>(
                        key: ValueKey('mail-rule-op-$i'),
                        value: c.op,
                        items: [
                          for (final o in const [
                            'contains',
                            'not_contains',
                            'is',
                          ])
                            DropdownMenuItem(
                              value: o,
                              child: Text(_opLabel(o)),
                            ),
                        ],
                        onChanged: (v) => _setCondition(i, op: v),
                      ),
                      if (_conditions.length > 1)
                        IconButton(
                          tooltip: tr('조건 빼기'),
                          icon: const Icon(
                            Icons.remove_circle_outline,
                            size: 18,
                          ),
                          onPressed: () => setState(
                            () => _conditions.removeAt(i).value.dispose(),
                          ),
                        ),
                    ],
                  ),
                ),
              if (_conditions.length < 5)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('mail-rule-add-condition'),
                    onPressed: () => setState(
                      () => _conditions.add((
                        field: 'subject',
                        op: 'contains',
                        value: TextEditingController(),
                      )),
                    ),
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(tr('조건 더하기')),
                  ),
                ),
              const Divider(),
              Text(tr('맞으면')),
              DropdownButtonFormField<String?>(
                key: const ValueKey('mail-rule-move'),
                initialValue: targets.any((f) => f.path == _moveTo)
                    ? _moveTo
                    : null,
                decoration: InputDecoration(
                  labelText: tr('옮길 폴더'),
                  isDense: true,
                ),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(tr('옮기지 않음')),
                  ),
                  for (final f in targets)
                    DropdownMenuItem<String?>(
                      value: f.path,
                      child: Text(f.name),
                    ),
                ],
                onChanged: (v) => setState(() => _moveTo = v),
              ),
              CheckboxListTile(
                key: const ValueKey('mail-rule-seen'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _markSeen,
                title: Text(tr('읽음으로')),
                onChanged: (v) => setState(() => _markSeen = v ?? false),
              ),
              CheckboxListTile(
                key: const ValueKey('mail-rule-flag'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _flag,
                title: Text(tr('중요 표시')),
                onChanged: (v) => setState(() => _flag = v ?? false),
              ),
              CheckboxListTile(
                key: const ValueKey('mail-rule-quiet'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _skipNotify,
                title: Text(tr('새 메일 알림을 보내지 않음')),
                onChanged: (v) => setState(() => _skipNotify = v ?? false),
              ),
              CheckboxListTile(
                key: const ValueKey('mail-rule-stop'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _stop,
                title: Text(tr('이 규칙이 맞으면 뒤 규칙은 보지 않음')),
                onChanged: (v) => setState(() => _stop = v ?? false),
              ),
              if (_error != null)
                Text(
                  _error!,
                  key: const ValueKey('mail-rule-error'),
                  style: TextStyle(color: theme.colorScheme.error),
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
          key: const ValueKey('mail-rule-save'),
          onPressed: _saving ? null : _save,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}
