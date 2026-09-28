import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/muted_scrollbar.dart';
import 'filter_controls.dart';

/// 템플릿 편집기에서 고를 수 있는 색.
const templateColorChoices = <String>[
  '#5B8DEF',
  '#3B82F6',
  '#10B981',
  '#22C55E',
  '#F59E0B',
  '#F97316',
  '#EF4444',
  '#EC4899',
  '#A78BFA',
  '#8B5CF6',
  '#64748B',
  '#94A3B8',
];

/// 왼쪽 메뉴 [+] > [템플릿] — 팀이 공유하는 프로젝트 템플릿 목록과 편집기.
///
/// [draft]를 주면(프로젝트의 ⋯ > "템플릿 저장", 프로젝트 생성 창의 "+ 새 템플릿") 목록 대신 그
/// 내용으로 채운 "새 템플릿 만들기" 편집기를 연다. [draftTick]이 바뀔 때마다 다시 연다.
class ProjectTemplatesView extends StatefulWidget {
  final Session session;
  final String teamId;
  final ProjectTemplate? draft;
  final int draftTick;

  /// "이 템플릿으로 만들기" — 그 템플릿을 골라 둔 프로젝트 생성 창을 연다.
  final ValueChanged<ProjectTemplate>? onUseTemplate;

  const ProjectTemplatesView({
    super.key,
    required this.session,
    required this.teamId,
    this.draft,
    this.draftTick = 0,
    this.onUseTemplate,
  });

  @override
  State<ProjectTemplatesView> createState() => _ProjectTemplatesViewState();
}

class _ProjectTemplatesViewState extends State<ProjectTemplatesView> {
  List<ProjectTemplate>? _templates;
  String? _error;

  /// 편집 중인 템플릿(null이면 목록). 새 템플릿이면 id가 null.
  ProjectTemplate? _editing;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _editing = widget.draft;
    _load();
  }

  @override
  void didUpdateWidget(ProjectTemplatesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.draftTick != widget.draftTick && widget.draft != null) {
      setState(() => _editing = widget.draft);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await widget.session.api!.fetchProjectTemplates(
        widget.teamId,
      );
      if (mounted) {
        setState(() {
          _templates = list;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _save(ProjectTemplate t) async {
    final api = widget.session.api!;
    try {
      final id = _editing?.id;
      if (id == null) {
        await api.createProjectTemplate(widget.teamId, t);
      } else {
        await api.updateProjectTemplate(id, t);
      }
      if (!mounted) return;
      showAppToast(context, '템플릿을 저장했습니다.');
      setState(() => _editing = null);
      _load();
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    }
  }

  Future<void> _delete(ProjectTemplate t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('템플릿 삭제'),
        content: Text(
          '"${t.name}" 템플릿을 삭제할까요?\n이 템플릿으로 이미 만든 프로젝트에는 영향이 없습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.session.api!.deleteProjectTemplate(t.id!);
      if (mounted) showAppToast(context, '템플릿을 삭제했습니다.');
      _load();
    } catch (e) {
      if (mounted) showAppToast(context, '템플릿을 삭제하지 못했습니다: $e');
    }
  }

  void _newTemplate() => setState(() => _editing = ProjectTemplate.blank());

  Widget _newButton() => FilledButton.icon(
    onPressed: _newTemplate,
    icon: const Icon(Icons.add, size: 18),
    label: const Text('새 템플릿 만들기'),
  );

  @override
  Widget build(BuildContext context) {
    final editing = _editing;
    if (editing != null) {
      return ProjectTemplateEditor(
        // 다른 템플릿을 열 때마다 편집 칸들을 새로 만든다.
        key: ObjectKey(editing),
        template: editing,
        onCancel: () => setState(() => _editing = null),
        onSave: _save,
      );
    }
    final hint = Theme.of(context).hintColor;
    final templates = _templates;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '프로젝트 템플릿',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '팀에서 공유하는 프로젝트 설정 템플릿을 관리합니다',
                      style: TextStyle(fontSize: 13, color: hint),
                    ),
                  ],
                ),
              ),
              _newButton(),
            ],
          ),
        ),
        const Divider(height: 1, indent: 16, endIndent: 16),
        Expanded(
          child: _error != null
              ? Center(child: Text(_error!))
              : templates == null
              ? const Center(child: CircularProgressIndicator())
              : templates.isEmpty
              ? _empty(context)
              : MutedScrollbar(
                  controller: _scroll,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.all(24),
                    child: Wrap(
                      spacing: 16,
                      runSpacing: 16,
                      children: [
                        for (final t in templates)
                          _TemplateCard(
                            template: t,
                            canCreateProject: widget.session.canCreateProject,
                            onUse: widget.onUseTemplate == null
                                ? null
                                : () => widget.onUseTemplate!(t),
                            onEdit: () => setState(() => _editing = t),
                            onDelete: () => _delete(t),
                          ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: theme.brightness == Brightness.dark
                  ? theme.colorScheme.surfaceContainerHighest
                  : const Color(0xFFEFF0F2),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.grid_view_outlined, size: 30),
          ),
          const SizedBox(height: 16),
          const Text(
            '템플릿이 없습니다',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            '자주 쓰는 프로젝트 설정을 템플릿으로 저장해 보세요',
            style: TextStyle(fontSize: 13, color: theme.hintColor),
          ),
          const SizedBox(height: 16),
          _newButton(),
        ],
      ),
    );
  }
}

/// 프로젝트의 지금 구성(상태·유형·우선순위·사용자 정의 필드)으로 채운 "새 템플릿" 초안 — 저장하면
/// 서버가 그 프로젝트를 새 템플릿에 연결한다([ProjectTemplate.sourceProjectId]). 설정 > 필드 / 상태의
/// "템플릿 저장"과 사이드바 프로젝트 ⋯ > "템플릿 저장"이 같이 쓴다.
Future<ProjectTemplate> projectTemplateDraftFor(
  Session session,
  Project project,
) async {
  final api = session.api!;
  final results = await Future.wait([
    api.fetchTaskStatuses(project.id),
    api.fetchTaskTypes(project.id),
    api.fetchTaskPriorities(project.id),
    api.fetchTaskFields(project.id),
  ]);
  return ProjectTemplate(
    // 템플릿 이름은 40자까지라(프로젝트 이름은 60자) 넘치면 잘라서 채운다.
    name: project.name.characters.take(40).toString(),
    description: project.description,
    statuses: [
      for (final s in results[0] as List<TaskStatusDef>)
        TemplateStatus(name: s.name, color: s.color, category: s.category),
    ],
    types: [
      for (final t in results[1] as List<TaskType>)
        TemplateType(name: t.name, color: t.color),
    ],
    priorities: [
      for (final p in results[2] as List<TaskPriorityDef>)
        TemplatePriority(name: p.name, color: p.color, level: p.level),
    ],
    fields: [
      for (final f in results[3] as List<TaskFieldDef>)
        TemplateField(name: f.name, kind: f.kind, options: f.options),
    ],
    sourceProjectId: project.id,
  );
}

/// 템플릿 편집기를 창으로 띄워 새 템플릿을 만든다 — 프로젝트 설정 창처럼 이미 창 안이라 왼쪽
/// 메뉴의 템플릿 화면으로 옮겨 갈 수 없는 곳에서 쓴다. 저장했으면 그 템플릿, 취소하면 null.
Future<ProjectTemplate?> showProjectTemplateEditorDialog(
  BuildContext context,
  Session session, {
  required String teamId,
  required ProjectTemplate draft,
}) {
  return showDialog<ProjectTemplate>(
    context: context,
    builder: (dialogContext) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: ProjectTemplateEditor(
            template: draft,
            onCancel: () => Navigator.of(dialogContext).pop(),
            onSave: (t) async {
              try {
                final saved = await session.api!.createProjectTemplate(
                  teamId,
                  t,
                );
                if (!dialogContext.mounted) return;
                showAppToast(dialogContext, '템플릿을 저장했습니다.');
                Navigator.of(dialogContext).pop(saved);
              } catch (e) {
                if (dialogContext.mounted) showAppToast(dialogContext, '$e');
              }
            },
          ),
        ),
      ),
    ),
  );
}

/// 템플릿 카드 — 이름과 오른쪽 위 [trailing](⋯ 메뉴 등), 설명, 구성 요약, 아래쪽 [footer].
/// 템플릿 목록과 프로젝트 설정의 "업무 템플릿" 칸이 같은 모양으로 쓴다. [detailed]면 이름 앞에
/// 템플릿 아이콘을, 요약 아래에 상태들을 색과 함께 더 보여준다(설정 칸은 폭이 넓어서).
class ProjectTemplateSummaryCard extends StatelessWidget {
  final ProjectTemplate template;
  final Widget? trailing;
  final Widget? footer;
  final bool detailed;
  final double? width;
  const ProjectTemplateSummaryCard({
    super.key,
    required this.template,
    this.trailing,
    this.footer,
    this.detailed = false,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final dark = theme.brightness == Brightness.dark;
    final t = template;
    const blue = Color(0xFF3B82F6);
    return Container(
      width: width,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: dark ? theme.dividerColor : const Color(0xFFE2E4E8),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (detailed) ...[
                // 새 프로젝트 창에서 고른 템플릿 표시와 같은 아이콘·색.
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: blue.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: const Icon(
                    Icons.grid_view_outlined,
                    size: 16,
                    color: blue,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  t.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              trailing ?? const SizedBox(height: 40),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if ((t.description ?? '').isNotEmpty) ...[
                  Text(
                    t.description!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                  const SizedBox(height: 6),
                ],
                Text(
                  '상태 ${t.statuses.length} · 유형 ${t.types.length} · '
                  '우선순위 ${t.priorities.length} · 필드 ${t.fields.length}',
                  style: TextStyle(fontSize: 12, color: hint),
                ),
                if (detailed && t.statuses.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final s in t.statuses)
                        _StatusChip(name: s.name, color: s.color),
                    ],
                  ),
                ],
                if (footer != null) ...[const SizedBox(height: 14), footer!],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 템플릿 카드의 상태 한 개 — 색 점 + 이름을 옅은 같은 색 알약에 담는다.
class _StatusChip extends StatelessWidget {
  final String name;
  final String color;
  const _StatusChip({required this.name, required this.color});

  @override
  Widget build(BuildContext context) {
    final c = parseTypeColor(color);
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 3, 9, 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            name,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// 템플릿 목록의 카드 한 장 — 이름, ⋯(수정·삭제), 구성 요약, "이 템플릿으로 만들기".
class _TemplateCard extends StatelessWidget {
  final ProjectTemplate template;
  final bool canCreateProject;
  final VoidCallback? onUse;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _TemplateCard({
    required this.template,
    required this.canCreateProject,
    required this.onUse,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = template;
    return ProjectTemplateSummaryCard(
      template: t,
      width: 370,
      trailing: !t.canEdit
          ? null
          : MenuAnchor(
              menuChildren: [
                MenuItemButton(
                  leadingIcon: const Icon(Icons.edit_outlined, size: 16),
                  onPressed: onEdit,
                  child: const Padding(
                    padding: EdgeInsets.only(right: 20),
                    child: Text('수정'),
                  ),
                ),
                MenuItemButton(
                  leadingIcon: const Icon(
                    Icons.delete_outline,
                    size: 16,
                    color: Colors.redAccent,
                  ),
                  onPressed: onDelete,
                  child: const Padding(
                    padding: EdgeInsets.only(right: 20),
                    child: Text(
                      '삭제',
                      style: TextStyle(color: Colors.redAccent),
                    ),
                  ),
                ),
              ],
              builder: (context, controller, _) => IconButton(
                tooltip: '템플릿 메뉴',
                icon: const Icon(Icons.more_horiz, size: 20),
                visualDensity: VisualDensity.compact,
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
              ),
            ),
      footer: OutlinedButton(
        onPressed: canCreateProject ? onUse : null,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(38),
          foregroundColor: theme.colorScheme.onSurface,
          side: BorderSide(
            color: theme.brightness == Brightness.dark
                ? theme.dividerColor
                : const Color(0xFFD9DCE1),
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: const Text('이 템플릿으로 만들기'),
      ),
    );
  }
}

// ───────────────────────── 편집기 ─────────────────────────

/// 편집 중인 한 줄(상태·유형·우선순위·선택지) — 이름 칸과 색·분류를 들고 있다.
class _Draft {
  final key = UniqueKey();
  final TextEditingController name;
  String color;
  TaskStatus category;
  TaskPriority level;
  _Draft(
    String name,
    this.color, {
    this.category = TaskStatus.doing,
    this.level = TaskPriority.normal,
  }) : name = TextEditingController(text: name);
}

/// 편집 중인 사용자 정의 필드.
class _FieldDraft {
  final key = UniqueKey();
  final TextEditingController name;
  final String kind;
  final List<_Draft> options;
  bool expanded = true;
  _FieldDraft(String name, this.kind, this.options)
    : name = TextEditingController(text: name);

  bool get hasOptions => kind == 'select' || kind == 'multiSelect';
}

/// "새 템플릿 만들기" / "템플릿 수정" — 이름·설명, 상태·작업 유형·우선순위 세 칸, 커스텀 필드.
/// 줄은 왼쪽 손잡이로 끌어 순서를 바꾸고, 색 점을 눌러 색을, 글자를 눌러 이름을 고친다.
class ProjectTemplateEditor extends StatefulWidget {
  final ProjectTemplate template;
  final VoidCallback onCancel;
  final Future<void> Function(ProjectTemplate template) onSave;

  const ProjectTemplateEditor({
    super.key,
    required this.template,
    required this.onCancel,
    required this.onSave,
  });

  @override
  State<ProjectTemplateEditor> createState() => _ProjectTemplateEditorState();
}

class _ProjectTemplateEditorState extends State<ProjectTemplateEditor> {
  late final _name = TextEditingController(text: widget.template.name)
    ..addListener(() => setState(() {}));
  late final _description = TextEditingController(
    text: widget.template.description ?? '',
  );
  late final List<_Draft> _statuses = [
    for (final s in widget.template.statuses)
      _Draft(s.name, s.color, category: s.category),
  ];
  late final List<_Draft> _types = [
    for (final t in widget.template.types) _Draft(t.name, t.color),
  ];
  late final List<_Draft> _priorities = [
    for (final p in widget.template.priorities)
      _Draft(p.name, p.color, level: p.level),
  ];
  late final List<_FieldDraft> _fields = [
    for (final f in widget.template.fields)
      _FieldDraft(f.name, f.kind, [
        for (final (i, o) in f.options.indexed)
          _Draft(o, templateColorChoices[i % templateColorChoices.length]),
      ]),
  ];
  final _scroll = ScrollController();
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    for (final d in [..._statuses, ..._types, ..._priorities]) {
      d.name.dispose();
    }
    for (final f in _fields) {
      f.name.dispose();
      for (final o in f.options) {
        o.name.dispose();
      }
    }
    _scroll.dispose();
    super.dispose();
  }

  /// 목록에서 안 겹치는 새 이름("새 상태", "새 상태 2", …).
  String _uniqueName(List<String> taken, String base) {
    if (!taken.contains(base)) return base;
    var i = 2;
    while (taken.contains('$base $i')) {
      i++;
    }
    return '$base $i';
  }

  void _add(List<_Draft> list, String base, {TaskStatus? category}) {
    setState(() {
      list.add(
        _Draft(
          _uniqueName([for (final d in list) d.name.text.trim()], base),
          templateColorChoices[list.length % templateColorChoices.length],
          category: category ?? TaskStatus.doing,
        ),
      );
    });
  }

  void _addField(String kind) {
    setState(() {
      _fields.add(
        _FieldDraft(
          _uniqueName([
            for (final f in _fields) f.name.text.trim(),
          ], fieldKindLabels[kind] ?? '새 필드'),
          kind,
          kind == 'select' || kind == 'multiSelect'
              ? [_Draft('옵션 1', templateColorChoices.first)]
              : [],
        ),
      );
    });
  }

  /// 완료 표시를 켜면 done, 끄면 맨 윗줄은 할 일·나머지는 진행 중으로 본다.
  void _toggleDone(int index) {
    final d = _statuses[index];
    setState(() {
      d.category = d.category == TaskStatus.done
          ? (index == 0 ? TaskStatus.todo : TaskStatus.doing)
          : TaskStatus.done;
    });
  }

  ProjectTemplate _build() => ProjectTemplate(
    id: widget.template.id,
    // 프로젝트를 템플릿으로 저장하는 중이면 그 프로젝트를 새 템플릿에 연결하도록 그대로 넘긴다.
    sourceProjectId: widget.template.sourceProjectId,
    name: _name.text.trim(),
    description: _description.text.trim().isEmpty
        ? null
        : _description.text.trim(),
    statuses: [
      for (final (i, s) in _statuses.indexed)
        TemplateStatus(
          name: s.name.text.trim(),
          color: s.color,
          // 완료가 아닌 첫 상태는 "할 일" 분류로 — 새 업무가 여기서 시작한다.
          category: s.category == TaskStatus.done
              ? TaskStatus.done
              : (i == _statuses.indexWhere((x) => x.category != TaskStatus.done)
                    ? TaskStatus.todo
                    : TaskStatus.doing),
        ),
    ],
    types: [
      for (final t in _types)
        TemplateType(name: t.name.text.trim(), color: t.color),
    ],
    priorities: [
      for (final p in _priorities)
        TemplatePriority(
          name: p.name.text.trim(),
          color: p.color,
          level: p.level,
        ),
    ],
    fields: [
      for (final f in _fields)
        TemplateField(
          name: f.name.text.trim(),
          kind: f.kind,
          options: f.hasOptions
              ? [
                  for (final o in f.options)
                    if (o.name.text.trim().isNotEmpty) o.name.text.trim(),
                ]
              : const [],
        ),
    ],
  );

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.onSave(_build());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
    ),
  );

  InputDecoration _inputDeco(String hint) => InputDecoration(
    hintText: hint,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    border: const OutlineInputBorder(),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final isNew = widget.template.id == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 24, 12),
          child: Row(
            children: [
              IconButton(
                tooltip: '뒤로',
                onPressed: widget.onCancel,
                icon: const Icon(Icons.chevron_left),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isNew ? '새 템플릿 만들기' : '템플릿 수정',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '프로젝트의 상태·유형·우선순위·커스텀 필드 구성을 저장해 재사용합니다',
                      style: TextStyle(fontSize: 12, color: hint),
                    ),
                  ],
                ),
              ),
              TextButton(onPressed: widget.onCancel, child: const Text('취소')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _saving || _name.text.trim().isEmpty ? null : _save,
                child: const Text('템플릿 저장'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: MutedScrollbar(
            controller: _scroll,
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _label('템플릿 이름'),
                  TextField(
                    controller: _name,
                    maxLength: 40,
                    decoration: _inputDeco(
                      '예: 소프트웨어 개발',
                    ).copyWith(counterText: ''),
                  ),
                  const SizedBox(height: 14),
                  _label('설명'),
                  TextField(
                    controller: _description,
                    minLines: 2,
                    maxLines: 3,
                    decoration: _inputDeco('템플릿에 대한 설명을 추가하세요...'),
                  ),
                  const SizedBox(height: 16),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final sections = [
                        _section(
                          title: '상태',
                          list: _statuses,
                          onAdd: () => _add(_statuses, '새 상태'),
                          withDone: true,
                          footnote: "'완료'로 표시한 상태의 업무는 진행률·통계에서 완료로 집계됩니다.",
                        ),
                        _section(
                          title: '작업 유형',
                          list: _types,
                          onAdd: () => _add(_types, '새 유형'),
                          footnote: '유형 색상은 캘린더·간트 차트에서 업무 색상으로 사용됩니다.',
                        ),
                        _section(
                          title: '우선순위',
                          list: _priorities,
                          onAdd: () => _add(_priorities, '새 우선순위'),
                        ),
                      ];
                      if (constraints.maxWidth < 760) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final s in sections) ...[
                              s,
                              const SizedBox(height: 12),
                            ],
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final (i, s) in sections.indexed) ...[
                            if (i > 0) const SizedBox(width: 12),
                            Expanded(child: s),
                          ],
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  _fieldsSection(),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  BoxDecoration _cardDeco(ThemeData theme) => BoxDecoration(
    color: theme.colorScheme.surface,
    borderRadius: BorderRadius.circular(10),
    border: Border.all(
      color: theme.brightness == Brightness.dark
          ? theme.dividerColor
          : const Color(0xFFE2E4E8),
    ),
  );

  Widget _addButton(String label, VoidCallback onTap) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        visualDensity: VisualDensity.compact,
      ),
      icon: const Icon(Icons.add, size: 14),
      label: Text(label),
    ),
  );

  /// 상태·작업 유형·우선순위 칸 하나.
  Widget _section({
    required String title,
    required List<_Draft> list,
    required VoidCallback onAdd,
    bool withDone = false,
    String? footnote,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: _cardDeco(theme),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          _addButton('추가', onAdd),
          _reorderable(list, withDone: withDone),
          if (footnote != null) ...[
            const SizedBox(height: 6),
            Text(
              footnote,
              style: TextStyle(fontSize: 11, color: theme.hintColor),
            ),
          ],
        ],
      ),
    );
  }

  /// 손잡이로 끌어 순서를 바꾸는 줄 목록.
  Widget _reorderable(
    List<_Draft> list, {
    bool withDone = false,
    bool withColor = true,
  }) {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: list.length,
      onReorderItem: (from, to) =>
          setState(() => list.insert(to, list.removeAt(from))),
      itemBuilder: (context, i) => Padding(
        key: list[i].key,
        padding: const EdgeInsets.only(bottom: 6),
        child: _row(list, i, withDone: withDone, withColor: withColor),
      ),
    );
  }

  Widget _row(
    List<_Draft> list,
    int i, {
    required bool withDone,
    required bool withColor,
  }) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final d = list[i];
    final done = d.category == TaskStatus.done;
    return Container(
      height: 40,
      padding: const EdgeInsets.only(left: 4, right: 2),
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark
            ? theme.colorScheme.surfaceContainerHighest
            : const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: i,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Icon(Icons.drag_indicator, size: 16, color: hint),
            ),
          ),
          const SizedBox(width: 6),
          if (withColor) ...[
            _ColorDot(
              color: d.color,
              onChanged: (c) => setState(() => d.color = c),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: TextField(
              controller: d.name,
              maxLength: withColor ? 20 : 30,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              decoration: const InputDecoration(
                isDense: true,
                counterText: '',
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          if (withDone)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => _toggleDone(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      done ? Icons.check_circle : Icons.radio_button_unchecked,
                      size: 16,
                      color: done ? filterAccent : hint,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '완료',
                      style: TextStyle(
                        fontSize: 11,
                        color: done ? filterAccent : hint,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          IconButton(
            tooltip: '삭제',
            onPressed: () => setState(() {
              list.removeAt(i).name.dispose();
            }),
            icon: Icon(Icons.close, size: 14, color: hint),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _fieldsSection() {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _cardDeco(theme),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '커스텀 필드',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            '각 필드는 하나의 타입을 가집니다. 단일/다중 선택 타입은 순서가 있는 옵션을 가질 수 있습니다.',
            style: TextStyle(fontSize: 11, color: hint),
          ),
          const SizedBox(height: 8),
          if (_fields.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: Text(
                  '사용자 정의 필드가 없습니다.',
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              ),
            ),
          for (final f in _fields) _fieldBox(f),
          FilterPopup(
            anchorBuilder: (context, open, toggle) =>
                _addButton('필드 추가', toggle),
            popupBuilder: (context, close) => FilterPopupCard(
              width: 180,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final e in fieldKindLabels.entries)
                    InkWell(
                      onTap: () {
                        close();
                        _addField(e.key);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        child: Text(
                          e.value,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fieldBox(_FieldDraft f) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return Container(
      key: f.key,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.brightness == Brightness.dark
              ? theme.dividerColor
              : const Color(0xFFE2E4E8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 10, right: 2),
            child: Row(
              children: [
                SizedBox(
                  width: 180,
                  child: TextField(
                    controller: f.name,
                    maxLength: 20,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      counterText: '',
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: filterAccent.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    fieldKindLabels[f.kind] ?? f.kind,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: filterAccent,
                    ),
                  ),
                ),
                const Spacer(),
                if (f.hasOptions)
                  IconButton(
                    tooltip: f.expanded ? '접기' : '펼치기',
                    onPressed: () => setState(() => f.expanded = !f.expanded),
                    icon: Icon(
                      f.expanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 18,
                      color: hint,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                IconButton(
                  tooltip: '필드 삭제',
                  onPressed: () => setState(() {
                    _fields.remove(f);
                    f.name.dispose();
                  }),
                  icon: Icon(Icons.close, size: 14, color: hint),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          if (f.hasOptions && f.expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _addButton('추가', () => _add(f.options, '옵션')),
                  _reorderable(f.options, withColor: false),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 색 점 — 누르면 아래에 색 고르기 판이 뜬다.
class _ColorDot extends StatelessWidget {
  final String color;
  final ValueChanged<String> onChanged;
  const _ColorDot({required this.color, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return FilterPopup(
      anchorBuilder: (context, open, toggle) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: toggle,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: parseTypeColor(color),
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
      popupBuilder: (context, close) => FilterPopupCard(
        width: 176,
        padding: const EdgeInsets.all(10),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in templateColorChoices)
              InkWell(
                customBorder: const CircleBorder(),
                onTap: () {
                  close();
                  onChanged(c);
                },
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: parseTypeColor(c),
                    shape: BoxShape.circle,
                    border: c.toUpperCase() == color.toUpperCase()
                        ? Border.all(
                            color: Theme.of(context).colorScheme.onSurface,
                            width: 2,
                          )
                        : null,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
