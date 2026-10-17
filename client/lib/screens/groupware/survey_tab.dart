import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../models/groupware_forms.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/date_drop_calendar.dart';
import 'groupware_screen.dart' show GroupwareChanges, GroupwareSectionHeader;

/// 그룹웨어 "설문" 탭 — 여러 문항(하나 고르기·여러 개 고르기·글·별점) 설문을 만들어 범위 모두나 고른 사람에게 묻고, 응답하고, 결과를
/// 모아 본다(서버 groupwareSurveys.js). 응답할 설문이 위에 오고, 만든 사람은 결과·안 한 사람을 보고 마감·독촉·삭제한다.

String _md(DateTime d) => '${d.month}/${d.day}';
String _mdhm(DateTime d) =>
    '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class SurveyTab extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final GroupwareChanges changes;
  final Session session;
  const SurveyTab({
    super.key,
    required this.api,
    required this.ctx,
    required this.changes,
    required this.session,
  });

  @override
  State<SurveyTab> createState() => _SurveyTabState();
}

class _SurveyTabState extends State<SurveyTab> {
  List<SurveySummary>? _items;
  int _pending = 0;
  String? _error;

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
      final r = await widget.api.surveys();
      if (!mounted) return;
      setState(() {
        _items = r.items;
        _pending = r.pendingCount;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _create() async {
    final made = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => SurveyEditorScreen(api: widget.api)),
    );
    if (made == true) _load();
  }

  Future<void> _open(SurveySummary s) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SurveyScreen(api: widget.api, surveyId: s.id),
      ),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items == null) {
      return Center(
        child: _error != null
            ? Text(_error!)
            : const CircularProgressIndicator(),
      );
    }
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const ValueKey('survey-list'),
        children: [
          GroupwareSectionHeader(
            _pending > 0 ? '설문 · 응답할 설문 $_pending' : '설문',
            trailing: FilledButton.icon(
              key: const ValueKey('survey-new'),
              onPressed: _create,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('새 설문'),
            ),
          ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                '아직 설문이 없습니다.',
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.hintColor),
              ),
            ),
          for (final s in items)
            ListTile(
              key: ValueKey('survey-${s.id}'),
              onTap: () => _open(s),
              leading: Icon(
                s.pending
                    ? Icons.assignment_late_outlined
                    : s.closed
                    ? Icons.assignment_turned_in_outlined
                    : Icons.assignment_outlined,
                color: s.pending ? theme.colorScheme.primary : theme.hintColor,
              ),
              title: Text(
                s.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: s.pending ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              subtitle: Text(
                [
                  s.creatorName,
                  '응답 ${s.responseCount}/${s.targetCount}',
                  if (s.closesAt != null && !s.closed)
                    '${_mdhm(s.closesAt!)} 마감',
                  if (s.anonymous) '익명',
                ].join(' · '),
              ),
              trailing: _SurveyStateChip(s),
            ),
        ],
      ),
    );
  }
}

class _SurveyStateChip extends StatelessWidget {
  final SurveySummary s;
  const _SurveyStateChip(this.s);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (text, color) = s.closed
        ? ('마감', Colors.grey)
        : s.pending
        ? ('응답하기', scheme.primary)
        : s.responded
        ? ('응답함', Colors.green.shade700)
        : ('진행 중', scheme.secondary);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ── 만들기 ──────────────────────────────────────────────────────────────

/// 편집 중인 문항.
class _DraftQuestion {
  SurveyQuestionKind kind;
  final TextEditingController title;
  bool required = true;
  final List<TextEditingController> options;
  final Key key = UniqueKey();

  _DraftQuestion(this.kind)
    : title = TextEditingController(),
      options = [TextEditingController(), TextEditingController()];

  void dispose() {
    title.dispose();
    for (final o in options) {
      o.dispose();
    }
  }

  SurveyQuestion toQuestion() => SurveyQuestion(
    kind: kind,
    title: title.text.trim(),
    required: required,
    options: kind.hasOptions
        ? [
            for (final o in options)
              if (o.text.trim().isNotEmpty) SurveyOption(text: o.text.trim()),
          ]
        : const [],
  );
}

/// 새 설문 만들기 — 제목·설명, 문항들, 익명·결과 공개·대상·마감. 만들면 true로 닫힌다.
class SurveyEditorScreen extends StatefulWidget {
  final GroupwareApi api;
  const SurveyEditorScreen({super.key, required this.api});

  @override
  State<SurveyEditorScreen> createState() => _SurveyEditorScreenState();
}

class _SurveyEditorScreenState extends State<SurveyEditorScreen> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _questions = <_DraftQuestion>[
    _DraftQuestion(SurveyQuestionKind.single),
  ];
  bool _anonymous = false;
  SurveyResultVisibility _visibility = SurveyResultVisibility.creator;

  /// null이면 범위 모두.
  List<ApprovalCandidate>? _targets;
  DateTime? _closesAt;
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    for (final q in _questions) {
      q.dispose();
    }
    super.dispose();
  }

  Future<void> _pickTargets() async {
    final candidates = await widget.api.candidates().catchError(
      (Object _) => <ApprovalCandidate>[],
    );
    if (!mounted) return;
    final picked = await showDialog<List<ApprovalCandidate>>(
      context: context,
      builder: (_) => _PeoplePickerDialog(
        candidates: candidates,
        initial: {for (final t in _targets ?? const []) t.id},
      ),
    );
    if (picked == null) return;
    setState(() => _targets = picked.isEmpty ? null : picked);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.api.createSurvey(
        title: _title.text.trim(),
        description: _description.text,
        questions: [for (final q in _questions) q.toQuestion()],
        anonymous: _anonymous,
        resultVisibility: _visibility,
        targetIds: _targets?.map((t) => t.id).toList(),
        closesAt: _closesAt,
      );
      if (!mounted) return;
      showAppToast(context, '설문을 보냈습니다.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _questionCard(int index, _DraftQuestion q) {
    final theme = Theme.of(context);
    return Card(
      key: q.key,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  '${index + 1}.',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 8),
                DropdownButton<SurveyQuestionKind>(
                  key: ValueKey('survey-q$index-kind'),
                  value: q.kind,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final k in SurveyQuestionKind.values)
                      DropdownMenuItem(value: k, child: Text(k.label)),
                  ],
                  onChanged: (k) => setState(() => q.kind = k ?? q.kind),
                ),
                const Spacer(),
                const Text('필수', style: TextStyle(fontSize: 13)),
                Switch(
                  value: q.required,
                  onChanged: (v) => setState(() => q.required = v),
                ),
                IconButton(
                  tooltip: '문항 삭제',
                  onPressed: _questions.length <= 1
                      ? null
                      : () => setState(() {
                          _questions.removeAt(index);
                          q.dispose();
                        }),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            TextField(
              key: ValueKey('survey-q$index-title'),
              controller: q.title,
              maxLength: 200,
              decoration: const InputDecoration(
                hintText: '질문',
                isDense: true,
                counterText: '',
              ),
            ),
            if (q.kind.hasOptions) ...[
              const SizedBox(height: 6),
              for (var i = 0; i < q.options.length; i++)
                Row(
                  children: [
                    Icon(
                      q.kind == SurveyQuestionKind.single
                          ? Icons.radio_button_unchecked
                          : Icons.check_box_outline_blank,
                      size: 18,
                      color: theme.hintColor,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        key: ValueKey('survey-q$index-o$i'),
                        controller: q.options[i],
                        maxLength: 100,
                        decoration: InputDecoration(
                          hintText: '보기 ${i + 1}',
                          isDense: true,
                          counterText: '',
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '보기 삭제',
                      visualDensity: VisualDensity.compact,
                      onPressed: q.options.length <= 2
                          ? null
                          : () =>
                                setState(() => q.options.removeAt(i).dispose()),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: ValueKey('survey-q$index-add-option'),
                  onPressed: q.options.length >= 20
                      ? null
                      : () => setState(
                          () => q.options.add(TextEditingController()),
                        ),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('보기 추가'),
                ),
              ),
            ],
            if (q.kind == SurveyQuestionKind.rating)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '1~5점으로 답합니다.',
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Scaffold(
      appBar: AppBar(
        title: const Text('새 설문'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              key: const ValueKey('survey-send'),
              onPressed: _saving ? null : _save,
              child: const Text('보내기'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const ValueKey('survey-title'),
            controller: _title,
            maxLength: 100,
            decoration: const InputDecoration(
              labelText: '제목',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('survey-description'),
            controller: _description,
            maxLength: 2000,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: '설명(선택)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < _questions.length; i++)
            _questionCard(i, _questions[i]),
          OutlinedButton.icon(
            key: const ValueKey('survey-add-question'),
            onPressed: _questions.length >= 30
                ? null
                : () => setState(
                    () => _questions.add(
                      _DraftQuestion(SurveyQuestionKind.single),
                    ),
                  ),
            icon: const Icon(Icons.add),
            label: const Text('문항 추가'),
          ),
          const Divider(height: 32),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('받는 사람'),
            subtitle: Text(
              _targets == null ? '모두' : _targets!.map((t) => t.name).join(', '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: TextButton(
              key: const ValueKey('survey-targets'),
              onPressed: _pickTargets,
              child: const Text('고르기'),
            ),
          ),
          SwitchListTile(
            key: const ValueKey('survey-anonymous'),
            contentPadding: EdgeInsets.zero,
            title: const Text('익명'),
            subtitle: const Text('결과에 누가 답했는지 나오지 않습니다.'),
            value: _anonymous,
            onChanged: (v) => setState(() => _anonymous = v),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('결과 공개'),
            trailing: DropdownButton<SurveyResultVisibility>(
              key: const ValueKey('survey-visibility'),
              value: _visibility,
              items: [
                for (final v in SurveyResultVisibility.values)
                  DropdownMenuItem(value: v, child: Text(v.label)),
              ],
              onChanged: (v) => setState(() => _visibility = v ?? _visibility),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('마감'),
            trailing: DateDropButton(
              value: _closesAt,
              onPicked: (d) => setState(
                // 고른 날의 오후 6시에 마감한다.
                () => _closesAt = d == null
                    ? null
                    : DateTime(d.year, d.month, d.day, 18),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  _closesAt == null ? '없음' : '${_mdhm(_closesAt!)}까지',
                  style: TextStyle(color: _closesAt == null ? hint : null),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 받는 사람 고르기 — 이름으로 찾고 여럿 고른다. 아무도 안 고르면 "모두".
class _PeoplePickerDialog extends StatefulWidget {
  final List<ApprovalCandidate> candidates;
  final Set<String> initial;
  const _PeoplePickerDialog({required this.candidates, required this.initial});

  @override
  State<_PeoplePickerDialog> createState() => _PeoplePickerDialogState();
}

class _PeoplePickerDialogState extends State<_PeoplePickerDialog> {
  late final Set<String> _picked = {...widget.initial};
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final c in widget.candidates)
        if (_q.isEmpty || c.name.contains(_q) || c.username.contains(_q)) c,
    ];
    return AlertDialog(
      title: const Text('받는 사람'),
      content: SizedBox(
        width: 360,
        height: 420,
        child: Column(
          children: [
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '이름으로 찾기',
                isDense: true,
              ),
              onChanged: (v) => setState(() => _q = v.trim()),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final c in shown)
                    CheckboxListTile(
                      key: ValueKey('survey-target-${c.id}'),
                      dense: true,
                      value: _picked.contains(c.id),
                      title: Text(c.name),
                      onChanged: (on) => setState(
                        () => on == true
                            ? _picked.add(c.id)
                            : _picked.remove(c.id),
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
          onPressed: () => Navigator.of(context).pop(<ApprovalCandidate>[]),
          child: const Text('모두에게'),
        ),
        FilledButton(
          key: const ValueKey('survey-targets-done'),
          onPressed: () => Navigator.of(context).pop([
            for (final c in widget.candidates)
              if (_picked.contains(c.id)) c,
          ]),
          child: Text('${_picked.length}명 고르기'),
        ),
      ],
    );
  }
}

// ── 응답 ────────────────────────────────────────────────────────────────

/// 설문 하나 — 문항에 답하고(이미 냈으면 고치기), 결과를 볼 수 있으면 "결과 보기", 만든 사람은 ⋯에서 마감·독촉·삭제.
class SurveyScreen extends StatefulWidget {
  final GroupwareApi api;
  final String surveyId;
  const SurveyScreen({super.key, required this.api, required this.surveyId});

  @override
  State<SurveyScreen> createState() => _SurveyScreenState();
}

class _SurveyScreenState extends State<SurveyScreen> {
  SurveyDetail? _s;
  String? _error;
  final _answers = <String, dynamic>{};
  final _texts = <String, TextEditingController>{};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _texts.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await widget.api.survey(widget.surveyId);
      if (!mounted) return;
      setState(() {
        _s = s;
        _answers
          ..clear()
          ..addAll(s.myAnswers ?? const {});
        for (final q in s.questions) {
          if (q.kind == SurveyQuestionKind.text) {
            (_texts[q.id!] ??= TextEditingController()).text =
                (_answers[q.id] as String?) ?? '';
          }
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _submit() async {
    final s = _s!;
    for (final q in s.questions) {
      if (q.kind == SurveyQuestionKind.text) {
        final t = _texts[q.id]!.text.trim();
        t.isEmpty ? _answers.remove(q.id) : _answers[q.id!] = t;
      }
    }
    setState(() => _saving = true);
    try {
      final first = await widget.api.respondSurvey(s.summary.id, _answers);
      if (!mounted) return;
      showAppToast(context, first ? '응답을 보냈습니다.' : '응답을 고쳤습니다.');
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _manage(String action) async {
    final api = widget.api;
    final id = widget.surveyId;
    try {
      switch (action) {
        case 'close':
          await api.closeSurvey(id);
          if (mounted) showAppToast(context, '설문을 마감했습니다.');
          await _load();
        case 'remind':
          final n = await api.remindSurvey(id);
          if (mounted) showAppToast(context, '$n명에게 응답을 요청했습니다.');
        case 'delete':
          final ok = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text('설문 삭제'),
              content: const Text('설문과 모든 응답을 지울까요?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(c).pop(false),
                  child: const Text('취소'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(c).pop(true),
                  child: const Text('삭제'),
                ),
              ],
            ),
          );
          if (ok != true) return;
          await api.deleteSurvey(id);
          if (mounted) Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    }
  }

  Widget _question(int index, SurveyQuestion q, bool enabled) {
    final theme = Theme.of(context);
    final id = q.id!;
    final Widget input = switch (q.kind) {
      SurveyQuestionKind.single => RadioGroup<String>(
        groupValue: _answers[id] as String?,
        onChanged: (v) {
          if (enabled) setState(() => _answers[id] = v);
        },
        child: Column(
          children: [
            for (final o in q.options)
              RadioListTile<String>(
                key: ValueKey('answer-$id-${o.id}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: o.id!,
                enabled: enabled,
                title: Text(o.text),
              ),
          ],
        ),
      ),
      SurveyQuestionKind.multiple => Column(
        children: [
          for (final o in q.options)
            CheckboxListTile(
              key: ValueKey('answer-$id-${o.id}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: ((_answers[id] as List?) ?? const []).contains(o.id),
              title: Text(o.text),
              onChanged: !enabled
                  ? null
                  : (on) => setState(() {
                      final list = [...((_answers[id] as List?) ?? const [])];
                      on == true ? list.add(o.id) : list.remove(o.id);
                      _answers[id] = list;
                    }),
            ),
        ],
      ),
      SurveyQuestionKind.text => TextField(
        key: ValueKey('answer-$id'),
        controller: _texts[id],
        enabled: enabled,
        maxLength: 2000,
        minLines: 2,
        maxLines: 6,
        decoration: const InputDecoration(border: OutlineInputBorder()),
      ),
      SurveyQuestionKind.rating => Row(
        children: [
          for (var v = 1; v <= 5; v++)
            IconButton(
              key: ValueKey('answer-$id-$v'),
              tooltip: '$v점',
              onPressed: enabled
                  ? () => setState(() => _answers[id] = v)
                  : null,
              icon: Icon(
                ((_answers[id] as int?) ?? 0) >= v
                    ? Icons.star
                    : Icons.star_border,
                color: Colors.amber.shade700,
              ),
            ),
        ],
      ),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${index + 1}. ${q.title}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (q.required)
                  TextSpan(
                    text: ' *',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
              ],
            ),
          ),
          if (q.kind == SurveyQuestionKind.multiple)
            Text(
              '여러 개 고를 수 있습니다.',
              style: TextStyle(fontSize: 12, color: theme.hintColor),
            ),
          const SizedBox(height: 4),
          input,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    if (s == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('설문')),
        body: Center(
          child: _error != null
              ? Text(_error!)
              : const CircularProgressIndicator(),
        ),
      );
    }
    final hint = Theme.of(context).hintColor;
    final sum = s.summary;
    return Scaffold(
      appBar: AppBar(
        title: Text(sum.title, overflow: TextOverflow.ellipsis),
        actions: [
          if (s.canViewResults)
            TextButton(
              key: const ValueKey('survey-results'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      SurveyResultsScreen(api: widget.api, survey: s),
                ),
              ),
              child: const Text('결과 보기'),
            ),
          if (s.canManage)
            PopupMenuButton<String>(
              key: const ValueKey('survey-manage'),
              onSelected: _manage,
              itemBuilder: (_) => [
                if (!sum.closed) ...[
                  const PopupMenuItem(
                    value: 'remind',
                    child: Text('안 한 사람에게 요청'),
                  ),
                  const PopupMenuItem(value: 'close', child: Text('마감')),
                ],
                const PopupMenuItem(value: 'delete', child: Text('삭제')),
              ],
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            [
              sum.creatorName,
              _md(sum.createdAt),
              '응답 ${sum.responseCount}/${sum.targetCount}',
              if (sum.closed)
                '마감됨'
              else if (sum.closesAt != null)
                '${_mdhm(sum.closesAt!)} 마감',
              if (sum.anonymous) '익명',
            ].join(' · '),
            style: TextStyle(color: hint, fontSize: 13),
          ),
          if (sum.description != null) ...[
            const SizedBox(height: 10),
            Text(sum.description!),
          ],
          const Divider(height: 28),
          if (!s.canRespond && !sum.responded)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                sum.closed ? '마감된 설문입니다.' : '이 설문의 대상이 아닙니다.',
                style: TextStyle(color: hint),
              ),
            ),
          for (var i = 0; i < s.questions.length; i++)
            _question(i, s.questions[i], s.canRespond),
          if (s.canRespond)
            FilledButton(
              key: const ValueKey('survey-submit'),
              onPressed: _saving ? null : _submit,
              child: Text(sum.responded ? '응답 고치기' : '응답 보내기'),
            ),
        ],
      ),
    );
  }
}

// ── 결과 ────────────────────────────────────────────────────────────────

class SurveyResultsScreen extends StatefulWidget {
  final GroupwareApi api;
  final SurveyDetail survey;
  const SurveyResultsScreen({
    super.key,
    required this.api,
    required this.survey,
  });

  @override
  State<SurveyResultsScreen> createState() => _SurveyResultsScreenState();
}

class _SurveyResultsScreenState extends State<SurveyResultsScreen> {
  SurveyResults? _r;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.api
        .surveyResults(widget.survey.summary.id)
        .then((r) {
          if (mounted) setState(() => _r = r);
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = '$e');
        });
  }

  Widget _bar(String label, int count, int total, {Key? key}) {
    final ratio = total == 0 ? 0.0 : count / total;
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(value: ratio, minHeight: 8),
            ),
          ),
          SizedBox(
            width: 80,
            child: Text(
              '$count명 (${(ratio * 100).round()}%)',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    final hint = Theme.of(context).hintColor;
    return Scaffold(
      appBar: AppBar(title: Text('결과 — ${widget.survey.summary.title}')),
      body: r == null
          ? Center(
              child: _error != null
                  ? Text(_error!)
                  : const CircularProgressIndicator(),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  '응답 ${r.responseCount}명 / 대상 ${r.targetCount}명',
                  key: const ValueKey('survey-result-count'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                for (var i = 0; i < r.questions.length; i++) ...[
                  Text(
                    '${i + 1}. ${r.questions[i].title}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    '${r.questions[i].answered}명 응답',
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                  const SizedBox(height: 6),
                  ...switch (r.questions[i].kind) {
                    SurveyQuestionKind.single ||
                    SurveyQuestionKind.multiple => [
                      for (final o in r.questions[i].options)
                        _bar(
                          o.text,
                          o.count,
                          r.responseCount,
                          key: ValueKey('result-${o.id}'),
                        ),
                    ],
                    SurveyQuestionKind.rating => [
                      Text(
                        r.questions[i].average == null
                            ? '평균 —'
                            : '평균 ${r.questions[i].average!.toStringAsFixed(1)}점',
                        key: ValueKey('result-avg-${r.questions[i].id}'),
                      ),
                      for (var v = 5; v >= 1; v--)
                        if (r.questions[i].distribution.length == 5)
                          _bar(
                            '$v점',
                            r.questions[i].distribution[v - 1],
                            r.questions[i].answered,
                          ),
                    ],
                    SurveyQuestionKind.text => [
                      if (r.questions[i].texts.isEmpty)
                        Text('응답 없음', style: TextStyle(color: hint)),
                      for (final t in r.questions[i].texts)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Text(
                            t.name == null
                                ? '· ${t.text}'
                                : '· ${t.text} — ${t.name}',
                          ),
                        ),
                    ],
                  },
                  const Divider(height: 28),
                ],
                if (r.respondents != null) ...[
                  Text('응답한 사람', style: TextStyle(color: hint, fontSize: 12)),
                  Text(r.respondents!.map((p) => p.name).join(', ')),
                  const SizedBox(height: 12),
                ],
                if (r.nonRespondents != null) ...[
                  Text(
                    '아직 안 한 사람',
                    style: TextStyle(color: hint, fontSize: 12),
                  ),
                  Text(
                    r.nonRespondents!.isEmpty
                        ? '모두 응답했습니다.'
                        : r.nonRespondents!.map((p) => p.name).join(', '),
                    key: const ValueKey('survey-non-respondents'),
                  ),
                ],
              ],
            ),
    );
  }
}
