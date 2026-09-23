import 'package:flutter/material.dart';

import '../../models/app_user.dart';
import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import 'task_detail_panel.dart' show TaskPanelScope;
import '../../widgets/dashed_add_button.dart';
import '../../widgets/date_range_calendar_panel.dart';
import '../../widgets/floating_dialog.dart';
import '../../widgets/muted_scrollbar.dart';
import '../../widgets/user_avatar.dart';
import 'project_widgets.dart';

// intl의 DateFormat(locale: 'ko')는 initializeDateFormatting()을 먼저 부르지 않으면
// LocaleDataException을 던진다(이 앱은 그 초기화를 어디서도 안 한다 — time_format.dart와
// 같은 이유로 여기도 직접 문자열을 조립한다).
String _formatDue(DateTime dt) =>
    '${dt.year}.${dt.month.toString().padLeft(2, '0')}.${dt.day.toString().padLeft(2, '0')}';

String _formatCommentTime(DateTime dt) {
  final isPm = dt.hour >= 12;
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  return '${dt.month}월 ${dt.day}일 ${isPm ? '오후' : '오전'} $hour12:${dt.minute.toString().padLeft(2, '0')}';
}

/// "프로젝트 생성" — 이름, 대표 색상, 프로젝트 키, 설명, 공개 설정을 입력한다. 만든 사람이
/// 담당자(owner)가 되고, 구성원은 만든 뒤 프로젝트 화면에서 초대한다(공개 프로젝트는 팀의
/// 정회원 이상이 초대 없이 찾아서 참여할 수도 있다).
Future<Project?> showNewProjectDialog(
  BuildContext context,
  Session session,
  String teamId,
) {
  return showDialog<Project>(
    context: context,
    builder: (_) => _NewProjectDialog(session: session, teamId: teamId),
  );
}

/// 프로젝트 대표 색상 후보 — 첫 번째가 기본값.
const projectColorChoices = <String>[
  '#5B8DEF',
  '#10B981',
  '#F59E0B',
  '#EF4444',
  '#A78BFA',
  '#F472B6',
  '#64748B',
];

class _NewProjectDialog extends StatefulWidget {
  final Session session;
  final String teamId;
  const _NewProjectDialog({required this.session, required this.teamId});

  @override
  State<_NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends State<_NewProjectDialog> {
  final _name = TextEditingController();
  final _identifier = TextEditingController();
  final _description = TextEditingController();
  // 입력칸을 누르면(포커스) 안내 문구를 숨기려고 포커스 상태를 지켜본다.
  late final _nameFocus = FocusNode()..addListener(() => setState(() {}));
  late final _identifierFocus = FocusNode()..addListener(() => setState(() {}));
  late final _descriptionFocus = FocusNode()
    ..addListener(() => setState(() {}));

  /// 스크롤바가 붙을 목록 — 안 넘기면 Windows에서는 스크롤바가 목록을 못 찾아 경고가 난다.
  final _formScroll = ScrollController();
  String _color = projectColorChoices.first;
  bool _isPublic = true;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _identifier.dispose();
    _description.dispose();
    _nameFocus.dispose();
    _identifierFocus.dispose();
    _descriptionFocus.dispose();
    _formScroll.dispose();
    super.dispose();
  }

  /// 포커스가 없을 때만 보여줄 안내 문구(누르면 사라진다).
  String? _hintWhenIdle(FocusNode node, String text) =>
      node.hasFocus ? null : text;

  Future<void> _submit() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = '프로젝트 이름을 입력하세요.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final project = await widget.session.api!.createProject(
        teamId: widget.teamId,
        name: _name.text.trim(),
        identifier: _identifier.text.trim().toUpperCase(),
        description: _description.text.trim().isEmpty
            ? null
            : _description.text.trim(),
        color: _color,
        isPublic: _isPublic,
      );
      if (mounted) Navigator.of(context).pop(project);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return FloatingDialog(
      title: '프로젝트 생성',
      maxWidth: 520,
      maxHeight: 780,
      // 스크롤바를 창 오른쪽 끝에 붙이려고 오른쪽 여백을 0으로 받고, 안쪽 내용이 좌우 여백을
      // 직접 챙긴다(팀 설정과 같은 방식).
      padding: const EdgeInsets.fromLTRB(20, 20, 0, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: MutedScrollbar(
              controller: _formScroll,
              child: ListView(
                controller: _formScroll,
                // 내용만큼만 차지하게 한다 — 안 그러면 목록이 창 높이를 꽉 채워서 마지막
                // 항목과 아래 "프로젝트 생성" 버튼 사이가 휑하게 벌어진다(창이 모자라면
                // Flexible이 높이를 잘라주고 그때부터 스크롤된다).
                shrinkWrap: true,
                // 왼쪽(창 여백 20)과 같은 폭으로 오른쪽도 띄운다 — 스크롤바는 이 여백
                // 바깥의 창 오른쪽 끝에 그려진다.
                padding: const EdgeInsets.only(right: 20),
                children: [
                  _label('프로젝트 이름'),
                  TextField(
                    controller: _name,
                    focusNode: _nameFocus,
                    autofocus: true,
                    maxLength: 60,
                    decoration: InputDecoration(
                      hintText: _hintWhenIdle(_nameFocus, '프로젝트 이름을 입력하세요'),
                      counterText: '',
                      border: const OutlineInputBorder(),
                    ),
                    // 이름을 적으면 키를 아직 안 건드린 경우에 한해 영문 앞글자로 추천한다.
                    onChanged: (v) {
                      if (_identifier.text.isNotEmpty) return;
                      final guess = v
                          .toUpperCase()
                          .replaceAll(RegExp(r'[^A-Z0-9]'), '')
                          .replaceFirst(
                            RegExp(r'^[0-9]+'),
                            '',
                          ); // 키는 영문으로 시작해야 한다.
                      if (guess.length >= 2) {
                        _identifier.text = guess.substring(
                          0,
                          guess.length > 4 ? 4 : guess.length,
                        );
                      }
                    },
                  ),
                  const SizedBox(height: 20),
                  _label('대표 색상'),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final hex in projectColorChoices)
                        InkWell(
                          onTap: () => setState(() => _color = hex),
                          customBorder: const CircleBorder(),
                          child: Container(
                            width: 32,
                            height: 32,
                            padding: const EdgeInsets.all(2.5),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _color == hex
                                    ? Theme.of(context).colorScheme.onSurface
                                    : Colors.transparent,
                                width: 2,
                              ),
                            ),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: parseTypeColor(hex),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _label('프로젝트 키'),
                  TextField(
                    controller: _identifier,
                    focusNode: _identifierFocus,
                    maxLength: 10,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      hintText: _hintWhenIdle(
                        _identifierFocus,
                        '프로젝트 식별 키를 입력하세요. (예: HR, CX, DEV)',
                      ),
                      counterText: '',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 20),
                  _label('설명'),
                  TextField(
                    controller: _description,
                    focusNode: _descriptionFocus,
                    maxLines: 3,
                    minLines: 3,
                    decoration: InputDecoration(
                      hintText: _hintWhenIdle(
                        _descriptionFocus,
                        '프로젝트에 대한 설명을 추가하세요...',
                      ),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 20),
                  _label('공개 설정'),
                  // 고른 값 위에 메뉴가 겹쳐 뜨는 기본 드롭다운(DropdownButtonFormField) 대신,
                  // 메뉴가 입력칸 바로 아래로 펼쳐지는 DropdownMenu를 쓴다 — 펼쳤을 때 공개·
                  // 비공개 두 항목이 입력칸에 가리지 않고 다 보인다.
                  DropdownMenu<bool>(
                    initialSelection: _isPublic,
                    // 눌렀을 때 글자를 입력하는 칸이 아니라 목록만 펼치도록.
                    requestFocusOnTap: false,
                    expandedInsets: EdgeInsets.zero,
                    menuStyle: const MenuStyle(alignment: Alignment.bottomLeft),
                    inputDecorationTheme: const InputDecorationTheme(
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    dropdownMenuEntries: const [
                      DropdownMenuEntry(
                        value: true,
                        label: '공개',
                        leadingIcon: Icon(Icons.public, size: 18),
                      ),
                      DropdownMenuEntry(
                        value: false,
                        label: '비공개',
                        leadingIcon: Icon(Icons.lock_outline, size: 18),
                      ),
                    ],
                    onSelected: (v) => setState(() => _isPublic = v ?? true),
                  ),
                  const SizedBox(height: 8),
                  // 두 설명의 줄 수가 달라서 그냥 갈아끼우면 창 높이가 들썩인다 —
                  // IndexedStack은 자리를 항상 더 긴 쪽에 맞춰 잡아둔다.
                  IndexedStack(
                    index: _isPublic ? 0 : 1,
                    alignment: Alignment.centerLeft,
                    children: [
                      Text(
                        '정회원 이상 권한을 가진 모든 멤버가 별도 초대 없이 프로젝트를 확인하고 참여할 수 있습니다.',
                        style: TextStyle(color: hint, fontSize: 12),
                      ),
                      Text(
                        '초대한 구성원만 프로젝트를 확인할 수 있습니다.',
                        style: TextStyle(color: hint, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // 스크롤바가 없는 아래쪽 줄은 창의 원래 오른쪽 여백(20)을 직접 준다.
          Padding(
            padding: const EdgeInsets.only(right: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text(
                            '프로젝트 생성',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "새 업무" — [projectId]를 주면 그 프로젝트에 바로 만들고, 없으면 [projects]에서 고르게 한다.
Future<Task?> showNewTaskDialog(
  BuildContext context,
  Session session, {
  List<Project> projects = const [],
  String? projectId,
  List<AppUser> members = const [],
  String? projectName,
  String? initialTitle,
  String? initialDescription,
}) {
  return showDialog<Task>(
    context: context,
    builder: (_) => _NewTaskDialog(
      session: session,
      projects: projects,
      projectId: projectId,
      projectName: projectName,
      members: members,
      initialTitle: initialTitle,
      initialDescription: initialDescription,
    ),
  );
}

class _NewTaskDialog extends StatefulWidget {
  final Session session;
  final List<Project> projects;
  final String? projectId;

  /// 프로젝트를 고를 수 없을 때(프로젝트 안에서 연 경우) 보여줄 이름.
  final String? projectName;
  final List<AppUser> members;
  final String? initialTitle;
  final String? initialDescription;
  const _NewTaskDialog({
    required this.session,
    required this.projects,
    required this.projectId,
    this.projectName,
    required this.members,
    this.initialTitle,
    this.initialDescription,
  });

  @override
  State<_NewTaskDialog> createState() => _NewTaskDialogState();
}

class _NewTaskDialogState extends State<_NewTaskDialog> {
  late final _title = TextEditingController(text: widget.initialTitle);
  late final _description = TextEditingController(
    text: widget.initialDescription,
  );
  late String? _projectId = widget.projectId ?? widget.projects.firstOrNull?.id;
  late String? _projectName =
      widget.projectName ??
      widget.projects
          .where((p) => p.id == _projectId)
          .map((p) => p.name)
          .firstOrNull;
  late List<AppUser> _members = widget.members;
  String? _assigneeId;
  List<TaskStatusDef> _statuses = const [];
  String? _statusId;
  List<TaskFieldDef> _fields = const [];
  List<TaskPriorityDef> _priorities = const [];
  String? _priorityId;
  List<TaskTemplate> _templates = const [];
  String? _templateId;
  final _customValues = <String, dynamic>{};
  TaskPriority _priority = TaskPriority.normal;
  List<TaskType> _types = const [];
  String? _typeId;
  final _referenceIds = <String>{};

  /// "기간" 칸 바로 아래에 붙여 띄우는 달력 — 마감일까지 고르거나 바깥을 누르면 닫는다.
  final _periodOverlay = OverlayPortalController();
  final _periodLink = LayerLink();

  /// 스크롤바가 붙을 목록 — 안 넘기면 Windows에서는 스크롤바가 목록을 못 찾아 경고가 난다.
  final _formScroll = ScrollController();
  DateTime? _startDate;
  DateTime? _dueDate;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // "생성" 버튼은 제목이 있어야 눌리므로 글자가 바뀔 때마다 다시 그린다.
    _title.addListener(_onTitleChanged);
    if (_members.isEmpty || _projectName == null) _loadMembers();
    _loadTypes();
  }

  void _onTitleChanged() {
    if (mounted) setState(() {});
  }

  /// 유형은 프로젝트마다 따로 관리하므로, 프로젝트를 고르거나 바꿀 때 그 프로젝트 것으로 받아온다.
  Future<void> _loadTypes() async {
    final id = _projectId;
    if (id == null) return;
    try {
      final types = await widget.session.api!.fetchTaskTypes(id);
      if (mounted) {
        setState(() {
          _types = types;
          if (!types.any((t) => t.id == _typeId)) _typeId = null;
        });
      }
    } catch (_) {
      // 유형을 못 받아와도 업무는 유형 없이 만들 수 있다.
    }
    try {
      final statuses = await widget.session.api!.fetchTaskStatuses(id);
      final fields = await widget.session.api!.fetchTaskFields(id);
      final templates = await widget.session.api!.fetchTaskTemplates(id);
      final priorities = await widget.session.api!.fetchTaskPriorities(id);
      if (mounted) {
        setState(() {
          _priorities = priorities;
          // 템플릿이 정한 단계가 있으면 그 단계의 첫 우선순위를, 없으면 "보통"부터 고른다.
          _priorityId = _priorityIdFor(priorities, _priority);
          _templates = templates;
          _templateId = null;
          _statuses = statuses;
          if (!statuses.any((s) => s.id == _statusId)) {
            _statusId = statuses.firstOrNull?.id;
          }
          _fields = fields;
          _customValues.clear();
        });
      }
    } catch (_) {
      // 상태/필드를 못 받아와도 기본 상태(할 일)로 만들 수 있다.
    }
  }

  @override
  void dispose() {
    _title.removeListener(_onTitleChanged);
    _title.dispose();
    _description.dispose();
    _formScroll.dispose();
    super.dispose();
  }

  /// 단계(낮음/보통/높음)에 해당하는 첫 우선순위 id — 템플릿이나 기본값을 옮길 때 쓴다.
  String? _priorityIdFor(List<TaskPriorityDef> list, TaskPriority level) =>
      list.where((p) => p.level == level).map((p) => p.id).firstOrNull ??
      list.firstOrNull?.id;

  /// 템플릿을 고르면 제목·설명·우선순위·유형·담당자·마감일을 그 값으로 채운다(비어 있는 항목은 그대로 둔다).
  void _applyTemplate(TaskTemplate t) {
    setState(() {
      _templateId = t.id;
      if (t.title.isNotEmpty) _title.text = t.title;
      if (t.description != null) _description.text = t.description!;
      _priority = t.priority;
      _priorityId = _priorityIdFor(_priorities, t.priority);
      if (t.typeId != null && _types.any((x) => x.id == t.typeId)) {
        _typeId = t.typeId;
      }
      if (t.assigneeId != null && _members.any((m) => m.id == t.assigneeId)) {
        _assigneeId = t.assigneeId;
      }
      if (t.dueOffsetDays != null) {
        final now = DateTime.now();
        _dueDate = DateTime(now.year, now.month, now.day + t.dueOffsetDays!);
      }
    });
  }

  /// 담당자 후보는 그 프로젝트의 구성원 — 프로젝트를 바꾸면 다시 받아온다.
  Future<void> _loadMembers() async {
    final id = _projectId;
    if (id == null) return;
    try {
      final project = await widget.session.api!.fetchProject(id);
      if (mounted) {
        setState(() {
          _projectName ??= project.name;
          _members = project.members;
          if (!_members.any((m) => m.id == _assigneeId)) _assigneeId = null;
          _referenceIds.removeWhere((id) => !_members.any((m) => m.id == id));
        });
      }
    } catch (_) {
      // 담당자를 못 고르는 정도라 조용히 넘어간다(업무는 담당자 없이도 만들 수 있다).
    }
  }

  Future<void> _submit() async {
    final projectId = _projectId;
    if (projectId == null) {
      setState(() => _error = '프로젝트를 고르세요.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final task = await widget.session.api!.createTask(
        projectId: projectId,
        title: _title.text.trim(),
        description: _description.text.trim().isEmpty
            ? null
            : _description.text.trim(),
        assigneeId: _assigneeId,
        statusId: _statusId,
        customValues: _customValues.isEmpty ? null : _customValues,
        priority: _priority,
        priorityId: _priorityId,
        typeId: _typeId,
        referenceIds: _referenceIds.toList(),
        startDate: _startDate,
        dueDate: _dueDate,
      );
      if (mounted) Navigator.of(context).pop(task);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 프로젝트 드롭다운을 펼쳤을 때 이름 앞에 붙는 대표 색상 점(입력칸에는 이름만 보인다).
  Widget _projectColorDot(String color) => Padding(
    padding: const EdgeInsets.only(left: 4, right: 2),
    child: Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: parseTypeColor(color),
        shape: BoxShape.circle,
      ),
    ),
  );

  /// 섹션 제목("프로젝트", "업무") — 입력칸 바로 위에 붙는 작은 굵은 글씨.
  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
    ),
  );

  /// 항목들을 한 장의 테두리 안에 줄로 쌓는다(줄 사이엔 옅은 선).
  Widget _card(List<Widget> rows) => Container(
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const Divider(height: 1),
          rows[i],
        ],
      ],
    ),
  );

  /// 카드 한 줄 — 왼쪽에 항목 이름, 오른쪽에 내용(필요하면 맨 오른쪽에 작은 링크).
  Widget _row(String label, Widget child, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
    child: Row(
      children: [
        SizedBox(
          width: 60,
          child: Text(
            label,
            style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: child),
        ?trailing,
      ],
    ),
  );

  /// 상태·유형·우선순위처럼 하나만 고르는 항목 — 고른 칩만 색이 찬다.
  Widget _chip(
    String label, {
    required bool selected,
    required VoidCallback onTap,
    Color? color,
  }) {
    final theme = Theme.of(context);
    final tint = color ?? theme.colorScheme.primary;
    return ChoiceChip(
      label: Text(label, overflow: TextOverflow.ellipsis),
      selected: selected,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      labelStyle: TextStyle(
        fontSize: 12,
        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
      ),
      backgroundColor: theme.colorScheme.surface,
      selectedColor: tint.withValues(alpha: 0.16),
      side: BorderSide(
        color: selected ? tint.withValues(alpha: 0.5) : theme.dividerColor,
      ),
      onSelected: (_) => onTap(),
    );
  }

  Widget _chipRow(List<Widget> chips) =>
      Wrap(spacing: 6, runSpacing: 6, children: chips);

  /// 기간 — 칸 전체를 누르면(담당자 칸과 같은 방식) 달력 하나가 아래로 펼쳐지고, 거기서
  /// 시작일·마감일을 차례로 고른다(대화 내보내기와 같은 달력).
  Widget get _periodField {
    final hint = Theme.of(context).hintColor;
    Widget dateText(DateTime? value, String placeholder) => Text(
      value == null ? placeholder : _formatDue(value),
      style: TextStyle(fontSize: 13, color: value == null ? hint : null),
    );

    // 메뉴(MenuAnchor)·팝업메뉴 안에 달력을 넣으면 그 위젯들이 폭을 재는 방식(IntrinsicWidth)과
    // GridView가 맞지 않아 레이아웃이 깨진다 — 칸에 붙여 띄우는 건 OverlayPortal로 직접 한다.
    return OverlayPortal(
      controller: _periodOverlay,
      overlayChildBuilder: (context) => CompositedTransformFollower(
        link: _periodLink,
        targetAnchor: Alignment.bottomLeft,
        followerAnchor: Alignment.topLeft,
        offset: const Offset(0, 6),
        child: Align(
          alignment: Alignment.topLeft,
          child: TapRegion(
            // 달력 바깥을 누르면 닫는다.
            onTapOutside: (_) => _periodOverlay.hide(),
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(12),
              color: Theme.of(context).colorScheme.surface,
              child: Container(
                width: 300,
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _startDate == null || _dueDate != null
                          ? '시작일을 선택하세요'
                          : '마감일을 선택하세요',
                      style: TextStyle(color: hint, fontSize: 12),
                    ),
                    const SizedBox(height: 6),
                    DateRangeCalendarPanel(
                      start: _startDate,
                      end: _dueDate,
                      onChanged: (start, end) {
                        setState(() {
                          _startDate = start;
                          _dueDate = end;
                        });
                        // 마감일까지 고르면 더 볼 게 없으니 닫는다.
                        if (end != null) _periodOverlay.hide();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      child: CompositedTransformTarget(
        link: _periodLink,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: _periodOverlay.toggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(Icons.calendar_today_outlined, size: 14, color: hint),
                const SizedBox(width: 6),
                dateText(_startDate, '시작일'),
                Text('  —  ', style: TextStyle(color: hint)),
                dateText(_dueDate, '마감일'),
                const Spacer(),
                if (_startDate != null || _dueDate != null)
                  IconButton(
                    icon: const Icon(Icons.close, size: 14),
                    tooltip: '기간 지우기',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() {
                      _startDate = null;
                      _dueDate = null;
                    }),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget get _assigneeField {
    final me = _members.where((m) => m.id == _assigneeId).firstOrNull;
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          onPressed: () => setState(() => _assigneeId = null),
          child: const Text('미배정'),
        ),
        for (final user in _members)
          MenuItemButton(
            onPressed: () => setState(() => _assigneeId = user.id),
            child: Row(
              children: [
                UserAvatar(
                  user: user,
                  resolveUrl: widget.session.resolveUrl,
                  radius: 10,
                ),
                const SizedBox(width: 8),
                Text(user.name),
              ],
            ),
          ),
      ],
      builder: (context, controller, _) => InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: me == null
              ? Text(
                  '미배정',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).hintColor,
                  ),
                )
              : Row(
                  children: [
                    UserAvatar(
                      user: me,
                      resolveUrl: widget.session.resolveUrl,
                      radius: 10,
                    ),
                    const SizedBox(width: 8),
                    Text(me.name, style: const TextStyle(fontSize: 13)),
                  ],
                ),
        ),
      ),
    );
  }

  Widget get _referenceField {
    final selected = [
      for (final id in _referenceIds)
        if (_members.any((m) => m.id == id))
          _members.firstWhere((m) => m.id == id),
    ];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final user in selected)
          Chip(
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            labelStyle: const TextStyle(fontSize: 12),
            avatar: UserAvatar(
              user: user,
              resolveUrl: widget.session.resolveUrl,
              radius: 9,
            ),
            label: Text(user.name),
            onDeleted: () => setState(() => _referenceIds.remove(user.id)),
          ),
        DashedAddButton(label: '+ 추가', onTap: _pickReferences),
      ],
    );
  }

  Future<void> _pickReferences() async {
    final result = await showDialog<List<String>>(
      context: context,
      builder: (_) => _ReferencePickDialog(
        session: widget.session,
        members: _members,
        initial: _referenceIds.toList(),
      ),
    );
    if (result != null) {
      setState(() {
        _referenceIds
          ..clear()
          ..addAll(result);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final myId = widget.session.userId;
    // 구성원이 아니면 담당자로 넣어도 이름을 못 보여주므로 아예 권하지 않는다.
    final canAssignMe =
        myId != null &&
        _assigneeId != myId &&
        _members.any((m) => m.id == myId);
    final boxBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: theme.dividerColor),
    );

    return FloatingDialog(
      title: '새 업무',
      maxWidth: 560,
      maxHeight: 760,
      // 스크롤바를 창 오른쪽 끝에 붙이려고 오른쪽 여백을 0으로 받고, 안쪽 내용이 좌우 여백을
      // 직접 챙긴다(프로젝트 생성 창과 같은 방식).
      padding: const EdgeInsets.fromLTRB(20, 20, 0, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.only(right: 20),
            child: Divider(height: 1),
          ),
          const SizedBox(height: 16),
          Flexible(
            child: MutedScrollbar(
              controller: _formScroll,
              child: ListView(
                controller: _formScroll,
                // 내용만큼만 차지하게 해서 아래 버튼이 내용 바로 밑에 붙게 한다(창이 모자라면
                // Flexible이 잘라주고 그때부터 스크롤된다). 오른쪽은 왼쪽 여백과 같은 폭으로
                // 띄우고, 스크롤바는 그 바깥 창 끝에 그려진다.
                shrinkWrap: true,
                padding: const EdgeInsets.only(right: 20),
                children: [
                  _sectionLabel('프로젝트'),
                  if (widget.projects.isNotEmpty)
                    // 고른 값 위에 메뉴가 겹쳐 뜨는 기본 드롭다운 대신, 입력칸 바로 아래로
                    // 펼쳐지는 DropdownMenu를 쓴다(프로젝트 생성 창의 "공개 설정"과 같다).
                    DropdownMenu<String>(
                      initialSelection: _projectId,
                      requestFocusOnTap: false,
                      expandedInsets: EdgeInsets.zero,
                      menuStyle: const MenuStyle(
                        alignment: Alignment.bottomLeft,
                      ),
                      inputDecorationTheme: InputDecorationTheme(
                        isDense: true,
                        filled: true,
                        fillColor: theme.colorScheme.surfaceContainerLowest,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 14,
                        ),
                        border: boxBorder,
                        enabledBorder: boxBorder,
                      ),
                      dropdownMenuEntries: [
                        for (final project in widget.projects)
                          DropdownMenuEntry(
                            value: project.id,
                            label: project.name,
                            leadingIcon: _projectColorDot(project.color),
                          ),
                      ],
                      onSelected: (v) {
                        setState(() {
                          _projectId = v;
                          _projectName = widget.projects
                              .where((p) => p.id == v)
                              .map((p) => p.name)
                              .firstOrNull;
                        });
                        _loadMembers();
                        _loadTypes();
                      },
                    )
                  else
                    // 프로젝트 안에서 연 경우 — 바꿀 수 없으니 이름만 보여준다.
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerLowest,
                        border: Border.all(color: theme.dividerColor),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _projectName ?? '프로젝트',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (_templates.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _sectionLabel('템플릿에서 불러오기'),
                    DropdownButtonFormField<String>(
                      key: ValueKey('tpl-$_templateId-${_templates.length}'),
                      initialValue: _templateId,
                      isExpanded: true,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '템플릿에서 불러오기',
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 14,
                        ),
                        border: boxBorder,
                        enabledBorder: boxBorder,
                      ),
                      items: [
                        for (final t in _templates)
                          DropdownMenuItem(
                            value: t.id,
                            child: Text(
                              t.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) {
                        final t = _templates
                            .where((x) => x.id == v)
                            .firstOrNull;
                        if (t != null) _applyTemplate(t);
                      },
                    ),
                  ],
                  const SizedBox(height: 12),
                  _sectionLabel('업무'),
                  TextField(
                    controller: _title,
                    autofocus: true,
                    maxLength: 200,
                    decoration: InputDecoration(
                      hintText: '업무 입력',
                      counterText: '',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 14,
                      ),
                      border: boxBorder,
                      enabledBorder: boxBorder,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _card([
                    _row(
                      '담당자',
                      _assigneeField,
                      trailing: canAssignMe
                          ? TextButton(
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                textStyle: const TextStyle(fontSize: 12),
                              ),
                              onPressed: () =>
                                  setState(() => _assigneeId = myId),
                              child: const Text('나에게 할당'),
                            )
                          : null,
                    ),
                    _row('기간', _periodField),
                    if (_statuses.isNotEmpty)
                      _row(
                        '상태',
                        _chipRow([
                          for (final s in _statuses)
                            _chip(
                              s.name,
                              selected: _statusId == s.id,
                              color: parseTypeColor(s.color),
                              onTap: () => setState(() => _statusId = s.id),
                            ),
                        ]),
                      ),
                    if (_types.isNotEmpty)
                      _row(
                        '유형',
                        _chipRow([
                          for (final t in _types)
                            _chip(
                              t.name,
                              selected: _typeId == t.id,
                              color: parseTypeColor(t.color),
                              onTap: () => setState(
                                () => _typeId = _typeId == t.id ? null : t.id,
                              ),
                            ),
                        ]),
                      ),
                    if (_priorities.isNotEmpty)
                      _row(
                        '우선순위',
                        _chipRow([
                          for (final p in _priorities)
                            _chip(
                              p.name,
                              selected: _priorityId == p.id,
                              color: parseTypeColor(p.color),
                              onTap: () => setState(() {
                                _priorityId = p.id;
                                // 서버는 단계(낮음/보통/높음)도 같이 받으므로 어긋나지 않게 맞춘다.
                                _priority = p.level;
                              }),
                            ),
                        ]),
                      ),
                    _row('참조', _referenceField),
                  ]),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _description,
                    maxLines: 5,
                    minLines: 3,
                    decoration: InputDecoration(
                      hintText: '설명을 추가하세요...',
                      contentPadding: const EdgeInsets.all(12),
                      border: boxBorder,
                      enabledBorder: boxBorder,
                    ),
                  ),
                  if (_fields.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _CustomFieldsEditor(
                      fields: _fields,
                      values: _customValues,
                      commitOnChange: true,
                      onChanged: (id, v) => setState(() {
                        if (v == null) {
                          _customValues.remove(id);
                        } else {
                          _customValues[id] = v;
                        }
                      }),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // 스크롤바가 없는 아래쪽 줄은 창의 원래 오른쪽 여백(20)을 직접 준다.
          Padding(
            padding: const EdgeInsets.only(right: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: _submitting
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: const Text('취소'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _submitting || _title.text.trim().isEmpty
                          ? null
                          : _submit,
                      child: _submitting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('생성'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 업무 상세 — 상태/담당자/마감일을 그 자리에서 바꾸고, 댓글로 논의한다.
Future<void> showTaskDetailDialog(
  BuildContext context,
  Session session,
  String taskId,
) {
  // "프로젝트" 창 안이면 가운데 팝업 대신 오른쪽 패널로 연다(task_detail_panel.dart).
  // 밖에서 부른 경우에만 예전처럼 팝업으로 띄운다.
  final scope = TaskPanelScope.maybeOf(context);
  if (scope != null) {
    scope.openTask(taskId);
    return Future.value();
  }
  return showDialog<void>(
    context: context,
    builder: (_) => _TaskDetailDialog(session: session, taskId: taskId),
  );
}

class _TaskDetailDialog extends StatefulWidget {
  final Session session;
  final String taskId;
  const _TaskDetailDialog({required this.session, required this.taskId});

  @override
  State<_TaskDetailDialog> createState() => _TaskDetailDialogState();
}

class _TaskDetailDialogState extends State<_TaskDetailDialog> {
  final _comment = TextEditingController();
  Task? _task;
  List<AppUser> _members = const [];
  List<TaskType> _types = const [];
  List<TaskStatusDef> _statuses = const [];
  List<TaskFieldDef> _fields = const [];
  List<TaskPriorityDef> _priorities = const [];
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final task = await widget.session.api!.fetchTask(widget.taskId);
      final project = await widget.session.api!.fetchProject(task.projectId);
      final types = await widget.session.api!.fetchTaskTypes(task.projectId);
      final statuses = await widget.session.api!.fetchTaskStatuses(
        task.projectId,
      );
      final fields = await widget.session.api!.fetchTaskFields(task.projectId);
      final priorities = await widget.session.api!.fetchTaskPriorities(
        task.projectId,
      );
      if (mounted) {
        setState(() {
          _task = task;
          _members = project.members;
          _types = types;
          _statuses = statuses;
          _fields = fields;
          _priorities = priorities;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// 바꾼 항목 하나를 바로 저장한다(상태/담당자/마감일은 눌러서 즉시 반영되는 게 자연스럽다).
  Future<void> _patch({
    String? statusId,
    String? priorityId,
    Map<String, dynamic>? customValues,
    TaskPriority? priority,
    String? assigneeId,
    bool clearAssignee = false,
    String? typeId,
    bool clearType = false,
    List<String>? referenceIds,
    DateTime? startDate,
    bool clearStartDate = false,
    DateTime? dueDate,
    bool clearDueDate = false,
  }) async {
    setState(() => _saving = true);
    try {
      final updated = await widget.session.api!.updateTask(
        widget.taskId,
        statusId: statusId,
        priorityId: priorityId,
        customValues: customValues,
        priority: priority,
        assigneeId: assigneeId,
        clearAssignee: clearAssignee,
        typeId: typeId,
        clearType: clearType,
        referenceIds: referenceIds,
        startDate: startDate,
        clearStartDate: clearStartDate,
        dueDate: dueDate,
        clearDueDate: clearDueDate,
      );
      if (mounted) {
        setState(() {
          // 응답에는 댓글이 안 들어있어서, 지금 들고 있는 댓글은 그대로 유지한다.
          _task = updated;
        });
        await _load();
      }
    } catch (e) {
      if (mounted) showAppToast(context, '저장하지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 이 업무의 우선순위 id — 없는 예전 업무는 같은 단계의 첫 우선순위로 본다.
  String? _currentPriorityId(Task task) {
    if (task.priorityId != null &&
        _priorities.any((p) => p.id == task.priorityId)) {
      return task.priorityId;
    }
    return _priorities
        .where((p) => p.level == task.priority)
        .map((p) => p.id)
        .firstOrNull;
  }

  /// 이 업무가 [status] 상태인지 — 상태 id가 없는 예전 업무는 같은 분류의 첫 상태로 본다.
  bool _isCurrentStatus(Task task, TaskStatusDef status) {
    if (task.statusId != null && _statuses.any((s) => s.id == task.statusId)) {
      return task.statusId == status.id;
    }
    return _statuses.firstWhere((s) => s.category == task.status).id ==
        status.id;
  }

  Future<void> _addComment() async {
    final text = _comment.text.trim();
    if (text.isEmpty) return;
    _comment.clear();
    try {
      await widget.session.api!.addTaskComment(widget.taskId, text);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '댓글을 남기지 못했습니다: $e');
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('업무 삭제'),
        content: const Text('이 업무와 달린 댓글이 모두 삭제됩니다. 계속할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.session.api!.deleteTask(widget.taskId);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showAppToast(context, '삭제하지 못했습니다: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final task = _task;
    return FloatingDialog(
      title: task?.key ?? '업무',
      maxWidth: 560,
      maxHeight: 780,
      child: _error != null
          ? Center(child: Text(_error!))
          : task == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: MutedScrollbar(
                    child: ListView(
                      children: [
                        Text(
                          task.title,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        if (task.projectName != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            task.projectName!,
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(color: hint),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            for (final status in _statuses)
                              ChoiceChip(
                                label: Text(status.name),
                                avatar: Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    color: parseTypeColor(status.color),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                selected: _isCurrentStatus(task, status),
                                onSelected: _saving
                                    ? null
                                    : (_) => _patch(statusId: status.id),
                              ),
                            const SizedBox(width: 4),
                            DdayBadge(task: task),
                          ],
                        ),
                        const SizedBox(height: 16),
                        _AssigneeField(
                          session: widget.session,
                          members: _members,
                          value: task.assigneeId,
                          onChanged: (v) => v == null
                              ? _patch(clearAssignee: true)
                              : _patch(assigneeId: v),
                        ),
                        const SizedBox(height: 12),
                        _ReferenceField(
                          session: widget.session,
                          members: _members,
                          selectedIds: task.referenceIds,
                          onChanged: (ids) => _patch(referenceIds: ids),
                        ),
                        const SizedBox(height: 12),
                        _TypeField(
                          types: _types,
                          value: task.typeId,
                          onChanged: (v) => v == null
                              ? _patch(clearType: true)
                              : _patch(typeId: v),
                        ),
                        const SizedBox(height: 12),
                        _DueDateField(
                          label: '시작일',
                          value: task.startDate,
                          onChanged: (v) => v == null
                              ? _patch(clearStartDate: true)
                              : _patch(startDate: v),
                        ),
                        _DueDateField(
                          value: task.dueDate,
                          onChanged: (v) => v == null
                              ? _patch(clearDueDate: true)
                              : _patch(dueDate: v),
                        ),
                        if (_fields.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _CustomFieldsEditor(
                            fields: _fields,
                            values: task.customValues,
                            commitOnChange: false,
                            onChanged: (id, v) => _patch(customValues: {id: v}),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Text('우선순위', style: TextStyle(color: hint)),
                            const SizedBox(width: 12),
                            DropdownButton<String>(
                              value: _currentPriorityId(task),
                              underline: const SizedBox.shrink(),
                              items: [
                                for (final p in _priorities)
                                  DropdownMenuItem(
                                    value: p.id,
                                    child: Text(p.name),
                                  ),
                              ],
                              onChanged: _saving
                                  ? null
                                  : (v) => v == null
                                        ? null
                                        : _patch(priorityId: v),
                            ),
                          ],
                        ),
                        if (task.description != null &&
                            task.description!.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(task.description!),
                          ),
                        ],
                        const SizedBox(height: 20),
                        Text(
                          '댓글 ${task.comments.length}',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 8),
                        if (task.comments.isEmpty)
                          const EmptyHint('아직 댓글이 없습니다')
                        else
                          for (final comment in task.comments)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${comment.senderName} · ${_formatCommentTime(comment.createdAt)}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(color: hint),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(comment.text),
                                ],
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _comment,
                        decoration: const InputDecoration(
                          hintText: '댓글 남기기',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onSubmitted: (_) => _addComment(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      icon: const Icon(Icons.send, size: 18),
                      onPressed: _addComment,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _delete,
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: Colors.redAccent,
                    ),
                    label: const Text(
                      '업무 삭제',
                      style: TextStyle(color: Colors.redAccent),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// 담당자 고르기 — 프로젝트 구성원 중에서(또는 "담당자 없음").
class _AssigneeField extends StatelessWidget {
  final Session session;
  final List<AppUser> members;
  final String? value;
  final ValueChanged<String?> onChanged;
  const _AssigneeField({
    required this.session,
    required this.members,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // 목록에 없는 담당자(구성원에서 빠진 경우)면 드롭다운이 값을 못 찾으므로 null로 떨어뜨린다.
    final safeValue = members.any((m) => m.id == value) ? value : null;
    return DropdownButtonFormField<String?>(
      initialValue: safeValue,
      decoration: const InputDecoration(
        labelText: '담당자',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        const DropdownMenuItem(value: null, child: Text('담당자 없음')),
        for (final user in members)
          DropdownMenuItem(
            value: user.id,
            child: Row(
              children: [
                UserAvatar(
                  user: user,
                  resolveUrl: session.resolveUrl,
                  radius: 10,
                ),
                const SizedBox(width: 8),
                Text(user.name),
              ],
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

/// 업무 유형 고르기 — 그 프로젝트의 유형 목록에서(없음도 가능).
class _TypeField extends StatelessWidget {
  final List<TaskType> types;
  final String? value;
  final ValueChanged<String?> onChanged;
  const _TypeField({
    required this.types,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final safeValue = types.any((t) => t.id == value) ? value : null;
    return DropdownButtonFormField<String?>(
      key: ValueKey('type-$safeValue-${types.length}'),
      initialValue: safeValue,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: '유형',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        const DropdownMenuItem(value: null, child: Text('유형 없음')),
        for (final type in types)
          DropdownMenuItem(
            value: type.id,
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: parseTypeColor(type.color),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(type.name, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

/// 참조자 고르기 — 고른 사람은 칩으로 보이고, 누르면 구성원 체크 목록이 뜬다.
class _ReferenceField extends StatelessWidget {
  final Session session;
  final List<AppUser> members;
  final List<String> selectedIds;
  final ValueChanged<List<String>> onChanged;
  const _ReferenceField({
    required this.session,
    required this.members,
    required this.selectedIds,
    required this.onChanged,
  });

  Future<void> _pick(BuildContext context) async {
    final result = await showDialog<List<String>>(
      context: context,
      builder: (_) => _ReferencePickDialog(
        session: session,
        members: members,
        initial: selectedIds,
      ),
    );
    if (result != null) onChanged(result);
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final selected = [
      for (final id in selectedIds)
        if (members.any((m) => m.id == id))
          members.firstWhere((m) => m.id == id),
    ];
    return InkWell(
      onTap: () => _pick(context),
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: '참조자',
          border: OutlineInputBorder(),
          isDense: true,
        ),
        child: selected.isEmpty
            ? Text('참조자 없음 (눌러서 추가)', style: TextStyle(color: hint))
            : Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final user in selected)
                    Chip(
                      visualDensity: VisualDensity.compact,
                      avatar: UserAvatar(
                        user: user,
                        resolveUrl: session.resolveUrl,
                        radius: 9,
                      ),
                      label: Text(user.name),
                    ),
                ],
              ),
      ),
    );
  }
}

class _ReferencePickDialog extends StatefulWidget {
  final Session session;
  final List<AppUser> members;
  final List<String> initial;
  const _ReferencePickDialog({
    required this.session,
    required this.members,
    required this.initial,
  });

  @override
  State<_ReferencePickDialog> createState() => _ReferencePickDialogState();
}

class _ReferencePickDialogState extends State<_ReferencePickDialog> {
  late final _selected = widget.initial.toSet();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('참조자 선택'),
      content: SizedBox(
        width: 360,
        height: 360,
        child: MutedScrollbar(
          child: ListView(
            children: [
              for (final user in widget.members)
                CheckboxListTile(
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _selected.contains(user.id),
                  title: Row(
                    children: [
                      UserAvatar(
                        user: user,
                        resolveUrl: widget.session.resolveUrl,
                        radius: 12,
                      ),
                      const SizedBox(width: 8),
                      Flexible(child: Text(user.name)),
                    ],
                  ),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selected.add(user.id);
                    } else {
                      _selected.remove(user.id);
                    }
                  }),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selected.toList()),
          child: const Text('확인'),
        ),
      ],
    );
  }
}

/// 날짜 고르기(시작일/마감일) — 누르면 달력이 뜨고, X로 지울 수 있다.
class _DueDateField extends StatelessWidget {
  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  const _DueDateField({
    this.label = '마감일',
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Row(
      children: [
        Icon(Icons.event_outlined, size: 18, color: hint),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(color: hint)),
        const SizedBox(width: 12),
        TextButton(
          onPressed: () async {
            final now = DateTime.now();
            final picked = await showDatePicker(
              context: context,
              initialDate: value ?? now,
              firstDate: DateTime(now.year - 1),
              lastDate: DateTime(now.year + 5),
            );
            if (picked != null) onChanged(picked);
          },
          child: Text(value == null ? '설정 안 함' : _formatDue(value!)),
        ),
        if (value != null)
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: '$label 지우기',
            onPressed: () => onChanged(null),
          ),
      ],
    );
  }
}

/// 프로젝트의 사용자 정의 필드 입력칸들 — 새 업무에서는 바뀔 때마다([commitOnChange]),
/// 상세에서는 입력을 마쳤을 때(포커스를 잃거나 Enter) 값을 넘긴다. 지우면 null.
class _CustomFieldsEditor extends StatelessWidget {
  final List<TaskFieldDef> fields;
  final Map<String, dynamic> values;
  final bool commitOnChange;
  final void Function(String fieldId, dynamic value) onChanged;
  const _CustomFieldsEditor({
    required this.fields,
    required this.values,
    required this.commitOnChange,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('추가 정보', style: TextStyle(color: hint, fontSize: 12)),
        const SizedBox(height: 8),
        for (final f in fields)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: switch (f.kind) {
              'date' => _DueDateField(
                label: f.name,
                value: values[f.id] is num
                    ? DateTime.fromMillisecondsSinceEpoch(
                        (values[f.id] as num).toInt(),
                      )
                    : null,
                onChanged: (d) => onChanged(f.id, d?.millisecondsSinceEpoch),
              ),
              'progress' => _ProgressField(
                key: ValueKey('cf-${f.id}'),
                label: f.name,
                value: (values[f.id] as num?)?.toDouble() ?? 0,
                onChanged: (v) => onChanged(f.id, v),
              ),
              'multiSelect' => _MultiSelectField(
                field: f,
                selected:
                    (values[f.id] as List?)?.whereType<String>().toList() ??
                    const [],
                onChanged: (list) => onChanged(f.id, list),
              ),
              'select' => DropdownButtonFormField<String?>(
                key: ValueKey('cf-${f.id}-${values[f.id]}'),
                initialValue: f.options.contains(values[f.id])
                    ? values[f.id] as String
                    : null,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: f.name,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem(value: null, child: Text('선택 안 함')),
                  for (final o in f.options)
                    DropdownMenuItem(value: o, child: Text(o)),
                ],
                onChanged: (v) => onChanged(f.id, v),
              ),
              _ => _CustomTextInput(
                key: ValueKey('cf-${f.id}'),
                field: f,
                value: values[f.id],
                commitOnChange: commitOnChange,
                onChanged: (v) => onChanged(f.id, v),
              ),
            },
          ),
      ],
    );
  }
}

class _CustomTextInput extends StatefulWidget {
  final TaskFieldDef field;
  final dynamic value;
  final bool commitOnChange;
  final ValueChanged<dynamic> onChanged;
  const _CustomTextInput({
    super.key,
    required this.field,
    required this.value,
    required this.commitOnChange,
    required this.onChanged,
  });

  @override
  State<_CustomTextInput> createState() => _CustomTextInputState();
}

class _CustomTextInputState extends State<_CustomTextInput> {
  late final _controller = TextEditingController(
    text: widget.field.display(widget.value) ?? '',
  );
  final _focus = FocusNode();
  String _committed = '';

  bool get _isNumber => widget.field.kind == 'number';

  @override
  void initState() {
    super.initState();
    _committed = _controller.text;
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final text = _controller.text.trim();
    if (text == _committed) return;
    _committed = text;
    if (text.isEmpty) {
      widget.onChanged(null);
    } else if (_isNumber) {
      final n = num.tryParse(text);
      if (n != null) widget.onChanged(n);
    } else {
      widget.onChanged(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      keyboardType: _isNumber
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      decoration: InputDecoration(
        labelText: widget.field.name,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: widget.commitOnChange ? (_) => _commit() : null,
      onSubmitted: (_) => _commit(),
    );
  }
}

/// 진행률(0~100) 입력 — 끌어서 정하고 손을 뗄 때만 저장한다(업무 상세에서 매번 저장되지 않도록).
class _ProgressField extends StatefulWidget {
  final String label;
  final double value;
  final ValueChanged<num> onChanged;
  const _ProgressField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_ProgressField> createState() => _ProgressFieldState();
}

class _ProgressFieldState extends State<_ProgressField> {
  late double _value = widget.value;

  @override
  void didUpdateWidget(_ProgressField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _value = widget.value;
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: TextStyle(color: hint, fontSize: 12)),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: _value,
                max: 100,
                divisions: 20,
                label: '${_value.round()}%',
                onChanged: (v) => setState(() => _value = v),
                onChangeEnd: (v) => widget.onChanged(v.round()),
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                '${_value.round()}%',
                textAlign: TextAlign.right,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 다중 선택 — 고른 것만 색이 채워진 칩으로 보여주고, 누를 때마다 전체 목록을 넘긴다.
class _MultiSelectField extends StatelessWidget {
  final TaskFieldDef field;
  final List<String> selected;
  final void Function(List<String>) onChanged;
  const _MultiSelectField({
    required this.field,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(field.name, style: TextStyle(color: hint, fontSize: 12)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final option in field.options)
              FilterChip(
                label: Text(option),
                selected: selected.contains(option),
                onSelected: (on) => onChanged([
                  for (final o in field.options)
                    if (o == option ? on : selected.contains(o)) o,
                ]),
              ),
          ],
        ),
      ],
    );
  }
}
