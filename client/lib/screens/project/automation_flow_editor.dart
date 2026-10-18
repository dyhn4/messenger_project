import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/app_user.dart';
import '../../models/project.dart';
import '../../models/room.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/grab_cursors.dart';
import '../../widgets/user_avatar.dart';
import 'filter_controls.dart';
import '../../l10n/tr.dart';

/// 자동화 규칙 편집기(전체 화면). 저장하면 true.
Future<bool> showAutomationFlowEditor(
  BuildContext context, {
  required Session session,
  required String projectId,
  AutomationRule? rule,
}) async {
  final saved = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _AutomationFlowEditor(
        session: session,
        projectId: projectId,
        rule: rule,
      ),
    ),
  );
  return saved == true;
}

// ───────────────────────── 모양·색 ─────────────────────────

const _triggerColor = Color(0xFFF59E0B);
const _conditionColor = Color(0xFF8B5CF6);
const _actionColor = Color(0xFF10B981);
const _selectColor = Color(0xFF3B82F6);
const _edgeColor = Color(0xFFA3A9B5);
const _dangerColor = Color(0xFFEF4444);

/// 제목·메시지 변수(칩, 카드의 {업무 제목})의 글자색 — 어두운 테마에서는 밝은 쪽을 쓴다.
Color _tokenColor(bool dark) =>
    dark ? const Color(0xFF93C5FD) : const Color(0xFF2563EB);

/// 노드 카드 폭(캔버스 단위).
const _nodeW = 230.0;

/// 카드 양옆 여유 — 포트가 카드 테두리에 반쯤 걸쳐 있어서, 이만큼 넓혀 둬야 포트를 누를 수 있다.
const _gutter = 10.0;
const _headH = 40.0;
const _rowH = 28.0;
const _bodyPad = 8.0;
const _branchRowH = 24.0;
const _minScale = 0.5;
const _maxScale = 1.6;
const _gridStep = 20.0;

/// 팔레트에서 끌 때 포인터가 잡는 카드 속 자리 — 놓은 자리에 카드 왼쪽 위가 오게 하려고 고정한다.
const _dropAnchor = Offset(24, 20);

Color _kindColor(String kind) => switch (kind) {
  'trigger' => _triggerColor,
  'condition' => _conditionColor,
  _ => _actionColor,
};

String _kindLabel(String kind) => switch (kind) {
  'trigger' => tr('트리거'),
  'condition' => tr('조건'),
  _ => tr('액션'),
};

IconData _typeIcon(String type) => switch (type) {
  'field_changed' || 'set_field' => Icons.edit_outlined,
  'task_created' || 'create_task' => Icons.add,
  'task_deleted' => Icons.delete_outline,
  'task_archived' || 'archive_task' => Icons.inventory_2_outlined,
  'comment_added' => Icons.chat_bubble_outline,
  'checklist_completed' => Icons.checklist,
  'if' => Icons.filter_alt_outlined,
  'chat_message' => Icons.forum_outlined,
  _ => Icons.help_outline,
};

String _typeLabel(String kind, String type) => switch (kind) {
  'trigger' => automationTriggerLabels[type] ?? type,
  'condition' => tr('IF 조건'),
  _ => automationActionLabels[type] ?? type,
};

/// 옵션이 없는 노드의 몸통에 쓰는 설명.
final _typeHints = {
  'task_created': tr('새 업무가 생성되면 실행'),
  'task_deleted': tr('업무가 삭제되면 실행'),
  'task_archived': tr('업무가 보관되면 실행'),
  'comment_added': tr('댓글이 추가되면 실행'),
  'checklist_completed': tr('체크리스트를 모두 완료하면 실행'),
  'archive_task': tr('이 업무를 보관 처리'),
};

/// IF 조건·필드 변경 액션이 다루는 기본 필드.
const _basicFields = ['status', 'priority', 'assignee', 'type'];

String? _str(Object? v) => v is String ? v : null;
bool _blank(Object? v) => v == null || (v is String && v.trim().isEmpty);
bool _needsValue(String op) => op == 'eq' || op == 'neq';

/// 좁은 창 기준 — 이보다 좁으면 팔레트를 아이콘 줄로 줄이고 설정 칸은 고른 게 있을 때만 캔버스 위에 띄운다.
const _compactWidth = 760.0;
const _railW = 56.0;

/// 글자 수 제한 — 서버와 같게 String.length(UTF-16)로 센다.
const _maxNameLength = 40;
const _maxTitleLength = 200;
const _maxTextLength = 500;

/// 업무 생성 제목·채팅방 알림 메시지에 넣는 변수 — (칩 이름표 키, 변수, 화면 이름). 실행할 때 서버가
/// 규칙을 부른 업무의 값으로 바꾼다. 적힌 그대로 글자 수에 들어간다.
final _templateTokens = [
  ('title', '{{task.title}}', tr('업무 제목')),
  ('key', '{{task.key}}', tr('업무 번호')),
  ('assignee', '{{task.assignee}}', tr('담당자')),
];

final _templateTokenPattern = RegExp(
  _templateTokens.map((t) => RegExp.escape(t.$2)).join('|'),
);

/// 카드에 보여줄 제목·메시지 — 변수는 {업무 제목}처럼 읽을 수 있는 이름으로 바꾸고 색을 달리한다.
/// 모르는 {{...}}는 서버도 그대로 두므로 여기서도 적힌 그대로 보여준다.
List<InlineSpan> _templateSpans(String text, TextStyle tokenStyle) {
  final spans = <InlineSpan>[];
  var from = 0;
  for (final m in _templateTokenPattern.allMatches(text)) {
    if (m.start > from) {
      spans.add(TextSpan(text: text.substring(from, m.start)));
    }
    final label = _templateTokens.firstWhere((t) => t.$2 == m[0]).$3;
    spans.add(TextSpan(text: '{$label}', style: tokenStyle));
    from = m.end;
  }
  if (from < text.length) spans.add(TextSpan(text: text.substring(from)));
  return spans;
}

/// 필드 변경 트리거의 감지할 필드 체크 — '모든 필드'를 켜면 나머지를 끄고, 다른 필드를 켜면
/// '모든 필드'를 끈다. 체크한 순서가 아니라 목록([order]) 순서로 두어 카드·요약의 이름 순서가 늘 같다.
List<String> _toggledFields(
  List<String> current,
  String key,
  bool on,
  List<String> order,
) {
  final next = {...current};
  if (key == 'any') {
    next.clear();
  } else {
    next.remove('any');
  }
  if (on) {
    next.add(key);
  } else {
    next.remove(key);
  }
  return [
    for (final k in order)
      if (next.contains(k)) k,
    // 지워진 사용자 정의 필드처럼 목록에 없는 값은 뒤에 남겨 둔다(체크를 풀 때까지).
    for (final k in next)
      if (!order.contains(k)) k,
  ];
}

/// 날짜 필드 조건 값 'YYYY-MM-DD'(이 기기 시간대의 그 날) → DateTime. 형식이 틀리거나 없는 날이면 null.
DateTime? _parseDay(Object? v) {
  if (v is! String) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(v.trim());
  if (m == null) return null;
  final (y, mo, day) = (int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  final d = DateTime(y, mo, day);
  // 2026-02-30 같은 날은 DateTime이 다음 달로 넘겨 버려서 되돌려 맞춰 본다.
  return d.year == y && d.month == mo && d.day == day ? d : null;
}

String _dayValue(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

final _weekdayNames = [
  tr('일'),
  tr('월'),
  tr('화'),
  tr('수'),
  tr('목'),
  tr('금'),
  tr('토'),
];

/// 노드 카드에 보여줄 날 — "2026년 10월 1일 (목)".
String _dayLabel(DateTime d) => tr('{d.year}년 {d.month}월 {d.day}일 ({p0})', {
  'd.year': d.year,
  'd.month': d.month,
  'd.day': d.day,
  'p0': _weekdayNames[d.weekday % 7],
});

double? _numberOf(Object? v) {
  final n = v is num ? v.toDouble() : double.tryParse(_str(v)?.trim() ?? '');
  return n != null && n.isFinite ? n : null;
}

/// 노드 몸통의 요약 줄 수 — 카드 높이와 포트 자리를 레이아웃 없이 바로 계산하려고 고정해 둔다.
int _rowCount(AutomationNode n) => switch (n.type) {
  'create_task' => 3,
  'chat_message' => 2,
  _ => 1,
};

double _nodeHeight(AutomationNode n) =>
    _headH +
    1 +
    _bodyPad * 2 +
    _rowCount(n) * _rowH +
    (n.kind == 'condition' ? _branchRowH * 2 : 0);

List<String> _outPorts(AutomationNode n) => switch (n.kind) {
  'trigger' => const ['out'],
  'condition' => const ['yes', 'no'],
  _ => const [],
};

/// 카드 왼쪽 위 기준 포트 중심(캔버스 단위).
Offset _portOffset(AutomationNode n, String port) {
  final branchTop = _headH + 1 + _bodyPad + _rowCount(n) * _rowH;
  return switch (port) {
    'in' => Offset(0, _nodeHeight(n) / 2),
    'yes' => Offset(_nodeW, branchTop + _branchRowH / 2),
    'no' => Offset(_nodeW, branchTop + _branchRowH * 1.5),
    _ => Offset(_nodeW, _nodeHeight(n) / 2),
  };
}

/// 연결선 곡선의 두 조절점 — 포트에서 수평으로 나갔다가 수평으로 들어오게.
(Offset, Offset) _edgeControls(Offset a, Offset b, double scale) {
  final dx = math.max((b.dx - a.dx).abs() * 0.5, 50 * scale);
  return (a + Offset(dx, 0), b - Offset(dx, 0));
}

Offset _cubicAt(Offset a, Offset c1, Offset c2, Offset b, double t) {
  final u = 1 - t;
  return a * (u * u * u) +
      c1 * (3 * u * u * t) +
      c2 * (3 * u * t * t) +
      b * (t * t * t);
}

double _distToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (len2 == 0) return (p - a).distance;
  final t = (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / len2).clamp(
    0.0,
    1.0,
  );
  return (p - (a + ab * t)).distance;
}

// ───────────────────────── 팔레트 항목 ─────────────────────────

class _PaletteItem {
  final String kind;
  final String type;
  const _PaletteItem(this.kind, this.type);

  String get label => _typeLabel(kind, type);
}

const _triggerItems = [
  _PaletteItem('trigger', 'field_changed'),
  _PaletteItem('trigger', 'task_created'),
  _PaletteItem('trigger', 'task_deleted'),
  _PaletteItem('trigger', 'task_archived'),
  _PaletteItem('trigger', 'comment_added'),
  _PaletteItem('trigger', 'checklist_completed'),
];
const _conditionItems = [_PaletteItem('condition', 'if')];
const _actionItems = [
  _PaletteItem('action', 'set_field'),
  _PaletteItem('action', 'create_task'),
  _PaletteItem('action', 'archive_task'),
  _PaletteItem('action', 'chat_message'),
];

// ───────────────────────── 프로젝트 정보 ─────────────────────────

/// 설정 칸의 고르기 목록과 노드 요약이 쓰는 프로젝트 정보.
class _EditorData {
  final List<AppUser> members;
  final List<TaskStatusDef> statuses;
  final List<TaskPriorityDef> priorities;
  final List<TaskType> types;
  final List<TaskFieldDef> fields;
  final List<Room> rooms;
  final String myUserId;
  final String Function(String relative) resolveUrl;

  const _EditorData({
    required this.members,
    required this.statuses,
    required this.priorities,
    required this.types,
    required this.fields,
    required this.rooms,
    required this.myUserId,
    required this.resolveUrl,
  });

  /// 업무 생성 액션의 기본 상태 — 서버도 statusId가 없으면 첫 '할 일' 상태를 쓴다.
  TaskStatusDef? get defaultStatus =>
      statuses.where((s) => s.category == TaskStatus.todo).firstOrNull ??
      statuses.firstOrNull;

  AppUser? member(Object? id) => members.where((m) => m.id == id).firstOrNull;
  TaskStatusDef? status(Object? id) =>
      statuses.where((s) => s.id == id).firstOrNull;
  TaskPriorityDef? priority(Object? id) =>
      priorities.where((p) => p.id == id).firstOrNull;
  TaskType? type(Object? id) => types.where((t) => t.id == id).firstOrNull;
  Room? room(Object? id) => rooms.where((r) => r.id == id).firstOrNull;

  TaskFieldDef? customField(String field) => field.startsWith('field:')
      ? fields.where((f) => f.id == field.substring(6)).firstOrNull
      : null;

  String fieldLabel(String field) =>
      automationFieldLabels[field] ??
      customField(field)?.name ??
      (field.startsWith('field:') ? tr('(삭제된 필드)') : field);

  /// 사용자 정의 필드를 가리키는데 그 필드가 지워졌는지.
  bool fieldGone(String field) =>
      field.startsWith('field:') && customField(field) == null;

  /// [field]의 값 [value](비어 있지 않음)가 가리키는 대상이 이 프로젝트에 더 없으면 그 이름('상태' 등).
  /// 저장된 규칙은 상태·구성원 등이 지워져도 그대로 남아서, 서버가 저장을 거절하기 전에 여기서 찾는다.
  String? goneValue(String field, Object? value) => switch (field) {
    'status' => status(value) == null ? tr('상태') : null,
    'priority' => priority(value) == null ? tr('우선순위') : null,
    'type' => type(value) == null ? tr('유형') : null,
    'assignee' => member(value) == null ? tr('구성원') : null,
    _ => switch (customField(field)) {
      final f? when f.hasOptions =>
        f.options.contains(value?.toString().trim()) ? null : tr('선택지'),
      _ => null,
    },
  };
}

IconData _roomIcon(Room r) => switch (r.type) {
  RoomType.topic => Icons.tag,
  RoomType.group => Icons.group_outlined,
  RoomType.dm => Icons.person_outline,
};

// ───────────────────────── 편집기 ─────────────────────────

class _AutomationFlowEditor extends StatefulWidget {
  final Session session;
  final String projectId;
  final AutomationRule? rule;
  const _AutomationFlowEditor({
    required this.session,
    required this.projectId,
    this.rule,
  });

  @override
  State<_AutomationFlowEditor> createState() => _AutomationFlowEditorState();
}

typedef _EdgeLine = ({Offset from, Offset to, bool selected});

class _AutomationFlowEditorState extends State<_AutomationFlowEditor> {
  // 저장 전까지는 원래 규칙을 건드리지 않도록 복사본을 고친다.
  late final AutomationGraph _graph =
      widget.rule?.graph?.copy() ?? AutomationGraph();
  // 새 규칙은 제목 칸을 비워 두고 안내 문구(힌트)만 보인다 — 눌렀을 때 지울 글자가 없게.
  late final _name = TextEditingController(text: widget.rule?.name ?? '');

  /// 제목 칸 — 포커스가 오면 안내 문구를 감추고, 제목 없이 저장하면 여기로 커서를 옮긴다.
  late final _nameFocus = FocusNode(debugLabel: 'automation-rule-name')
    ..addListener(_onNameFocus);

  void _onNameFocus() {
    if (mounted) setState(() {});
  }

  late bool _enabled = widget.rule?.enabled ?? true;

  _EditorData? _data;
  String? _loadError;
  bool _dirty = false;
  bool _saving = false;

  String? _selectedId;
  AutomationEdge? _selectedEdge;

  /// 화면 좌표 = [_offset] + 캔버스 좌표 × [_scale].
  Offset _offset = Offset.zero;
  double _scale = 1;
  bool _panning = false;

  /// 끌어서 옮기는 중인 노드 — 시작 자리와 포인터 이동량으로 자리를 다시 계산한다.
  String? _movingId;
  Offset _moveStartGlobal = Offset.zero;
  Offset _moveStartPos = Offset.zero;

  /// 출력 포트에서 끌고 있는 새 연결(포인터는 캔버스 위젯 기준 화면 좌표).
  String? _linkFromId;
  String? _linkPort;
  Offset? _linkPointer;

  final _canvasKey = GlobalKey();
  final _keyFocus = FocusNode(debugLabel: 'automation-flow-editor');

  /// 설정 칸의 글 입력 컨트롤러 — 빌드마다 새로 만들면 커서·입력이 날아가서 노드별로 들고 있는다.
  final _texts = <String, TextEditingController>{};

  /// 변수 칩을 누른 뒤 포커스를 그 입력 칸으로 옮기려고 칸별로 들고 있는다 — 캔버스에 포커스가
  /// 남아 있으면 이어서 누른 Backspace/Delete가 글자 대신 노드를 지운다.
  final _textFocus = <String, FocusNode>{};

  FocusNode _focusFor(AutomationNode n, String slot) =>
      _textFocus.putIfAbsent('${n.id}:$slot', FocusNode.new);

  @override
  void initState() {
    super.initState();
    if (_graph.nodes.isNotEmpty) {
      // 저장된 흐름이 왼쪽 위부터 보이게.
      final minX = _graph.nodes.map((n) => n.x).reduce(math.min);
      final minY = _graph.nodes.map((n) => n.y).reduce(math.min);
      _offset = Offset(48 - minX, 48 - minY);
    }
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _nameFocus
      ..removeListener(_onNameFocus)
      ..dispose();
    _keyFocus.dispose();
    for (final c in _texts.values) {
      c.dispose();
    }
    for (final f in _textFocus.values) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final api = widget.session.api!;
      final id = widget.projectId;
      final project = await api.fetchProject(id);
      final statuses = await api.fetchTaskStatuses(id);
      final priorities = await api.fetchTaskPriorities(id);
      final types = await api.fetchTaskTypes(id);
      final fields = await api.fetchTaskFields(id);
      final me = widget.session.userId ?? '';
      // 채팅방 알림은 이 프로젝트 팀의 비밀 대화가 아닌 방에만 보낼 수 있다(서버도 다시 확인한다).
      // 보드 뷰 토픽은 게시글만 받아서 알림 메시지를 보낼 수 없으니 빼고, 읽기 전용·보관된 토픽은
      // 규칙을 저장하는 내가 그 토픽을 관리할 수 있을 때만 남긴다(서버가 저장·실행 때 같은 규칙으로 막는다).
      int order(Room r) => switch (r.type) {
        RoomType.topic => 0,
        RoomType.group => 1,
        RoomType.dm => 2,
      };
      final rooms =
          widget.session.rooms
              .where(
                (r) =>
                    r.teamId == project.teamId &&
                    !r.isSecret &&
                    !r.isBoard &&
                    r.canWrite(widget.session),
              )
              .toList()
            ..sort((a, b) {
              final c = order(a).compareTo(order(b));
              return c != 0
                  ? c
                  : a.displayName(me).compareTo(b.displayName(me));
            });
      if (!mounted) return;
      setState(
        () => _data = _EditorData(
          members: project.members,
          statuses: statuses,
          priorities: priorities,
          types: types,
          fields: fields,
          rooms: rooms,
          myUserId: me,
          resolveUrl: widget.session.resolveUrl,
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _loadError = e.toString());
    }
  }

  // ── 그래프 ──

  AutomationNode? _node(String id) =>
      _graph.nodes.where((n) => n.id == id).firstOrNull;

  AutomationNode? get _selectedNode =>
      _selectedId == null ? null : _node(_selectedId!);

  String _newId() {
    var i = _graph.nodes.length + 1;
    while (_graph.nodes.any((n) => n.id == 'n$i')) {
      i++;
    }
    return 'n$i';
  }

  Set<String> _reachableFrom(String start) {
    final seen = <String>{start};
    final stack = [start];
    while (stack.isNotEmpty) {
      final id = stack.removeLast();
      for (final e in _graph.edges) {
        if (e.from == id && seen.add(e.to)) stack.add(e.to);
      }
    }
    return seen;
  }

  bool _canConnect(AutomationNode from, AutomationNode to) {
    if (from.id == to.id || from.kind == 'action' || to.kind == 'trigger') {
      return false;
    }
    if (_graph.edges.any((e) => e.from == from.id && e.to == to.id)) {
      return false;
    }
    // to에서 from으로 가는 길이 이미 있으면 이 연결이 순환을 만든다.
    return !_reachableFrom(to.id).contains(from.id);
  }

  Map<String, dynamic> _defaultConfig(_PaletteItem item, _EditorData d) =>
      switch (item.type) {
        'field_changed' => {
          'fields': ['any'],
        },
        'if' => {'field': 'status', 'op': 'eq'},
        'set_field' => {'field': 'status', 'value': null},
        'create_task' => {
          'title': '',
          'statusId': d.defaultStatus?.id,
          'assignee': null,
        },
        'chat_message' => {'roomId': null, 'text': ''},
        _ => <String, dynamic>{},
      };

  void _edit(VoidCallback fn) {
    setState(() {
      fn();
      _dirty = true;
    });
  }

  void _select(String id) {
    if (_selectedId != id || _selectedEdge != null) {
      setState(() {
        _selectedId = id;
        _selectedEdge = null;
      });
    }
    _keyFocus.requestFocus();
  }

  void _deleteNode(String id) {
    setState(() {
      _graph.nodes.removeWhere((n) => n.id == id);
      _graph.edges.removeWhere((e) => e.from == id || e.to == id);
      if (_selectedId == id) _selectedId = null;
      if (_selectedEdge != null &&
          (_selectedEdge!.from == id || _selectedEdge!.to == id)) {
        _selectedEdge = null;
      }
      _dirty = true;
    });
    // 이번 프레임까지는 입력 칸이 컨트롤러를 붙들고 있어서, 화면에서 빠진 뒤에 정리한다.
    final stale = _texts.keys.where((k) => k.startsWith('$id:')).toList();
    final controllers = [for (final k in stale) _texts.remove(k)!];
    final staleFocus = _textFocus.keys
        .where((k) => k.startsWith('$id:'))
        .toList();
    final focusNodes = [for (final k in staleFocus) _textFocus.remove(k)!];
    if (controllers.isNotEmpty || focusNodes.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final c in controllers) {
          c.dispose();
        }
        for (final f in focusNodes) {
          f.dispose();
        }
      });
    }
  }

  void _deleteEdge(AutomationEdge edge) {
    setState(() {
      _graph.edges.remove(edge);
      if (_selectedEdge == edge) _selectedEdge = null;
      _dirty = true;
    });
  }

  TextEditingController _textFor(
    AutomationNode n,
    String slot,
    String initial,
  ) => _texts.putIfAbsent(
    '${n.id}:$slot',
    () => TextEditingController(text: initial),
  );

  /// IF 값이 지워질 때 값 입력 칸도 비운다 — 컨트롤러는 처음 만들 때만 값을 읽어서, 그대로 두면
  /// 필드·비교를 바꿨다 돌아왔을 때 설정에는 없는 옛 글자가 보인다. 이번 프레임까지는 입력 칸이
  /// 붙들고 있을 수 있어서 버리지 않고 비우기만 한다(clear는 onChanged를 부르지 않는다).
  void _clearValueTexts(AutomationNode n) {
    final prefix = '${n.id}:value:';
    for (final e in _texts.entries) {
      if (e.key.startsWith(prefix)) e.value.clear();
    }
  }

  /// 변수 칩을 누르면 [key] 칸(입력 칸 [slot])의 커서 자리에 [token]을 넣는다. 한 번도 누르지
  /// 않아 커서가 없으면 맨 뒤에 붙인다. 코드로 넣는 글자는 입력 칸의 글자 수 제한을 거치지
  /// 않아서, 넘치면 넣지 않고 알린다.
  void _insertToken(
    AutomationNode n,
    String slot,
    String key,
    String token,
    int maxLength,
  ) {
    final t = _textFor(n, slot, _str(n.config[key]) ?? '');
    final value = t.value;
    final sel = value.selection;
    final start = sel.isValid ? sel.start : value.text.length;
    final end = sel.isValid ? sel.end : value.text.length;
    final text = value.text.replaceRange(start, end, token);
    if (text.trim().length > maxLength) {
      showAppToast(
        context,
        tr('{maxLength}자를 넘어서 더 넣을 수 없습니다.', {'maxLength': maxLength}),
      );
      return;
    }
    t.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + token.length),
    );
    _edit(() => n.config[key] = text);
    // 이어서 치는 글자·지우기가 이 칸으로 가도록(캔버스의 노드 지우기 단축키가 아니라).
    _focusFor(n, slot).requestFocus();
  }

  // ── 좌표 ──

  RenderBox? get _canvasBox =>
      _canvasKey.currentContext?.findRenderObject() as RenderBox?;

  Offset _toLocal(Offset global) => _canvasBox?.globalToLocal(global) ?? global;

  Offset _toCanvas(Offset local) => (local - _offset) / _scale;

  Offset _portScreen(AutomationNode n, String port) =>
      _offset + (Offset(n.x, n.y) + _portOffset(n, port)) * _scale;

  /// [local] 아래의 노드(포트 여유 포함, 위에 그려진 것부터).
  AutomationNode? _nodeAt(Offset local, {String? except}) {
    for (final n in _graph.nodes.reversed) {
      if (n.id == except) continue;
      final rect = Rect.fromLTWH(
        _offset.dx + (n.x - _gutter) * _scale,
        _offset.dy + n.y * _scale,
        (_nodeW + _gutter * 2) * _scale,
        _nodeHeight(n) * _scale,
      );
      if (rect.contains(local)) return n;
    }
    return null;
  }

  AutomationEdge? _edgeAt(Offset p) {
    for (final e in _graph.edges.reversed) {
      final from = _node(e.from);
      final to = _node(e.to);
      if (from == null || to == null) continue;
      final a = _portScreen(from, e.port);
      final b = _portScreen(to, 'in');
      final (c1, c2) = _edgeControls(a, b, _scale);
      var prev = a;
      for (var i = 1; i <= 32; i++) {
        final q = _cubicAt(a, c1, c2, b, i / 32);
        if (_distToSegment(p, prev, q) <= 6) return e;
        prev = q;
      }
    }
    return null;
  }

  void _zoomAt(Offset focal, double factor) {
    final next = (_scale * factor).clamp(_minScale, _maxScale);
    if (next == _scale) return;
    setState(() {
      // 기준점 아래의 캔버스 자리가 그대로 머물게 이동량도 같이 고친다.
      _offset = focal - (focal - _offset) * (next / _scale);
      _scale = next;
    });
  }

  void _zoomStep(double factor) {
    final box = _canvasBox;
    _zoomAt(box == null ? Offset.zero : box.size.center(Offset.zero), factor);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      final s = e as PointerScrollEvent;
      final keys = HardwareKeyboard.instance;
      if (keys.isControlPressed) {
        // Ctrl+휠: 마우스 자리를 기준으로 확대·축소.
        if (s.scrollDelta.dy != 0) {
          _zoomAt(s.localPosition, s.scrollDelta.dy < 0 ? 1.1 : 1 / 1.1);
        }
      } else {
        // 그냥 휠은 캔버스를 위아래로(Shift면 좌우로) 옮긴다.
        final d = keys.isShiftPressed && s.scrollDelta.dx == 0
            ? Offset(s.scrollDelta.dy, 0)
            : s.scrollDelta;
        setState(() => _offset -= d);
      }
    });
  }

  // ── 팔레트에서 놓기 · 연결 ──

  void _drop(_PaletteItem item, Offset globalTopLeft) {
    final d = _data;
    if (d == null) return;
    if (item.kind == 'trigger' && _graph.trigger != null) {
      showAppToast(context, tr('트리거는 하나만 둘 수 있습니다.'));
      return;
    }
    final pos = _toCanvas(_toLocal(globalTopLeft));
    final node = AutomationNode(
      id: _newId(),
      kind: item.kind,
      type: item.type,
      config: _defaultConfig(item, d),
      x: pos.dx,
      y: pos.dy,
    );
    setState(() {
      _graph.nodes.add(node);
      // 놓자마자 오른쪽에서 바로 설정할 수 있게 고른다.
      _selectedId = node.id;
      _selectedEdge = null;
      _dirty = true;
    });
    _keyFocus.requestFocus();
  }

  void _finishLink() {
    final fromId = _linkFromId;
    final port = _linkPort;
    final pointer = _linkPointer;
    setState(() {
      _linkFromId = null;
      _linkPort = null;
      _linkPointer = null;
      if (fromId == null || port == null || pointer == null) return;
      final from = _node(fromId);
      final to = _nodeAt(pointer, except: fromId);
      if (from == null || to == null || !_canConnect(from, to)) return;
      _graph.edges.add(AutomationEdge(from: fromId, port: port, to: to.id));
      _dirty = true;
    });
  }

  void _tapCanvas(Offset local) {
    final edge = _edgeAt(local);
    setState(() {
      _selectedEdge = edge;
      _selectedId = null;
    });
    _keyFocus.requestFocus();
  }

  // ── 키보드 ──

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.delete &&
        key != LogicalKeyboardKey.backspace) {
      return KeyEventResult.ignored;
    }
    // 캔버스·노드를 눌러 편집기 자체에 포커스가 있을 때만 지운다 — 글 입력 칸(글자 지우기)이나
    // 열린 고르기 목록에서 올라온 키는 건드리지 않는다.
    if (!_keyFocus.hasPrimaryFocus) return KeyEventResult.ignored;
    final node = _selectedNode;
    if (node != null) {
      _deleteNode(node.id);
      return KeyEventResult.handled;
    }
    final edge = _selectedEdge;
    if (edge != null) {
      _deleteEdge(edge);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ── 저장 · 나가기 ──

  /// 자동화 제목의 문제 — 노드 검사보다 먼저 본다(저장하면 제목 칸으로 커서를 옮긴다).
  String? _titleProblem() {
    final name = _name.text.trim();
    if (name.isEmpty) return tr('자동화 제목을 입력하세요.');
    // 입력 칸의 글자 수 제한은 이모지를 한 글자로 세서, 서버처럼 UTF-16 길이로 다시 본다.
    if (name.length > _maxNameLength) {
      return tr('자동화 제목은 {_maxNameLength}자 이내로 입력하세요.', {
        '_maxNameLength': _maxNameLength,
      });
    }
    return null;
  }

  /// 서버에 보내기 전에 막을 수 있는 그래프 문제를 찾는다 — 문제가 있는 노드가 있으면 그 id도.
  ({String message, String? nodeId})? _validate() {
    final d = _data;
    if (d == null) {
      return (message: tr('프로젝트 정보를 불러오는 중입니다.'), nodeId: null);
    }
    final triggers = _graph.nodes.where((n) => n.kind == 'trigger').toList();
    if (triggers.isEmpty) {
      return (message: tr('트리거를 하나 놓아 주세요.'), nodeId: null);
    }
    if (triggers.length > 1) {
      return (message: tr('트리거는 하나만 둘 수 있습니다.'), nodeId: triggers.last.id);
    }
    final reach = _reachableFrom(triggers.single.id);
    if (!_graph.nodes.any((n) => n.kind == 'action' && reach.contains(n.id))) {
      return (
        message: tr('트리거에 연결된 액션이 하나 이상 필요합니다.'),
        nodeId: triggers.single.id,
      );
    }
    for (final n in _graph.nodes) {
      if (_nodeProblem(n, d) case final message?) {
        return (message: message, nodeId: n.id);
      }
    }
    return null;
  }

  /// 노드 한 개의 설정 문제 — 빠진 값, 지워진 상태·구성원·채팅방 등, 글자 수.
  String? _nodeProblem(AutomationNode n, _EditorData d) {
    final c = n.config;
    String gone(String what) => tr('삭제된 {what}입니다. 다시 선택하세요.', {'what': what});
    // 서버는 앞뒤 공백을 뺀 뒤 String.length로 센다.
    int length(Object? v) => _str(v)?.trim().length ?? 0;
    switch (n.type) {
      case 'field_changed':
        final watched = automationTriggerFields(c);
        if (watched.isEmpty) return tr('감지할 필드를 하나 이상 선택하세요.');
        if (watched.any(d.fieldGone)) return gone(tr('필드'));
      case 'if':
        final field = _str(c['field']) ?? 'status';
        if (d.fieldGone(field)) return gone(tr('필드'));
        if (!_needsValue(_str(c['op']) ?? 'eq')) return null;
        final value = c['value'];
        if (_blank(value)) return tr('IF 조건의 값을 선택하세요.');
        if (d.goneValue(field, value) case final what?) return gone(what);
        final custom = d.customField(field);
        switch (custom?.kind) {
          case 'date':
            if (_parseDay(value) == null) return tr('비교할 날짜를 다시 선택하세요.');
          case 'number':
            if (_numberOf(value) == null) {
              return tr('"{p0}" 값은 숫자로 입력하세요.', {'p0': custom!.name});
            }
          case 'progress':
            final v = _numberOf(value);
            if (v == null || v < 0 || v > 100) {
              return tr('"{p0}" 값은 0~100 사이의 숫자로 입력하세요.', {'p0': custom!.name});
            }
        }
        if (length(value) > _maxTextLength) {
          return tr('조건 값은 {_maxTextLength}자 이내로 입력하세요.', {
            '_maxTextLength': _maxTextLength,
          });
        }
      case 'set_field':
        final field = _str(c['field']);
        if (field == null) return tr('변경할 필드를 선택하세요.');
        final value = c['value'];
        if ((field == 'status' || field == 'priority') && value == null) {
          return tr('변경할 값을 선택하세요.');
        }
        if (value != null) {
          if (d.goneValue(field, value) case final what?) return gone(what);
        }
      case 'create_task':
        if (_blank(c['title'])) return tr('만들 업무의 제목을 입력하세요.');
        if (length(c['title']) > _maxTitleLength) {
          return tr('업무 제목은 {_maxTitleLength}자 이내로 입력하세요.', {
            '_maxTitleLength': _maxTitleLength,
          });
        }
        final statusId = c['statusId'];
        if (statusId != null && d.status(statusId) == null) {
          return gone(tr('상태'));
        }
        final assignee = c['assignee'];
        if (assignee != null &&
            assignee != 'current_assignee' &&
            d.member(assignee) == null) {
          return gone(tr('구성원'));
        }
      case 'chat_message':
        final roomId = c['roomId'];
        if (roomId == null) return tr('알림을 보낼 채팅방을 선택하세요.');
        // 고를 수 있는 방 = 이 팀의 비밀이 아닌, 내가 들어가 있는 방(서버도 같은 기준으로 받는다).
        if (d.room(roomId) == null) {
          return tr('삭제되었거나 참여 중이 아닌 채팅방입니다. 다시 선택하세요.');
        }
        if (_blank(c['text'])) return tr('보낼 메시지를 입력하세요.');
        if (length(c['text']) > _maxTextLength) {
          return tr('채팅방에 보낼 내용은 {_maxTextLength}자 이내로 입력하세요.', {
            '_maxTextLength': _maxTextLength,
          });
        }
    }
    return null;
  }

  Future<void> _save() async {
    if (_titleProblem() case final message?) {
      // 바로 고쳐 쓸 수 있게 제목 칸에 커서를 둔다.
      _nameFocus.requestFocus();
      showAppToast(context, message);
      return;
    }
    final problem = _validate();
    if (problem != null) {
      if (problem.nodeId != null) {
        setState(() {
          _selectedId = problem.nodeId;
          _selectedEdge = null;
        });
      }
      showAppToast(context, problem.message);
      return;
    }
    // 입력 칸은 그대로 두고 보내는 사본에서만 앞뒤 공백을 정리한다.
    final graph = _graph.copy();
    for (final n in graph.nodes) {
      for (final k in const ['title', 'text', 'value']) {
        final v = n.config[k];
        if (v is String) n.config[k] = v.trim();
      }
      // 예전 {field} 한 개짜리로 저장된 트리거도 지금 모양 {fields}로 바꿔 보낸다.
      if (n.type == 'field_changed') {
        final watched = automationTriggerFields(n.config);
        n.config.remove('field');
        n.config['fields'] = watched.contains('any')
            ? ['any']
            : watched.toSet().toList();
      }
    }
    setState(() => _saving = true);
    try {
      await widget.session.api!.saveAutomationGraph(
        widget.projectId,
        ruleId: widget.rule?.id,
        name: _name.text.trim(),
        enabled: _enabled,
        graph: graph,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showAppToast(context, tr('저장하지 못했습니다: {e}', {'e': e}));
    }
  }

  Future<void> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        content: Text(tr('저장하지 않은 변경 사항이 있습니다. 나갈까요?')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: Text(tr('취소')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: Text(tr('나가기')),
          ),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.of(context).pop(false);
  }

  // ── 화면 ──

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = _data;
    return PopScope<bool>(
      // 저장 중에 나가면 저장 결과(true)를 못 돌려줘서 규칙 목록이 새로 읽히지 않는다 — 끝날 때까지 막는다.
      canPop: !_dirty && !_saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_saving) _confirmLeave();
      },
      child: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: Focus(
          focusNode: _keyFocus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _topBar(theme),
              Expanded(
                child: d == null
                    ? _loadingOrError(theme)
                    : LayoutBuilder(
                        builder: (context, box) => box.maxWidth < _compactWidth
                            ? _compactBody(d, theme, box.maxWidth)
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const _Palette(),
                                  Expanded(child: _buildCanvas(d, theme)),
                                  _buildPanel(d, theme),
                                ],
                              ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 좁은 창 — 팔레트는 아이콘 줄, 설정 칸은 노드·연결을 골랐을 때만 캔버스 오른쪽 위에 덮어 띄운다.
  /// 세 칸을 나란히 두면 캔버스 자리가 없어진다.
  Widget _compactBody(_EditorData d, ThemeData theme, double width) {
    final picked = _selectedNode != null || _selectedEdge != null;
    // 왼쪽에 캔버스를 조금 남겨 빈 곳을 눌러 닫을 수 있게 한다.
    final panelW = math.min(300.0, math.max(0.0, width - _railW - 40));
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Palette(compact: true),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: _buildCanvas(d, theme)),
              if (picked)
                Positioned(
                  top: 0,
                  right: 0,
                  bottom: 0,
                  width: panelW,
                  child: Material(
                    elevation: 8,
                    child: _buildPanel(d, theme, overlay: true),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _topBar(ThemeData theme) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: tr('뒤로'),
            icon: const Icon(Icons.chevron_left),
            onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: TextField(
                  key: const ValueKey('rule-name'),
                  controller: _name,
                  focusNode: _nameFocus,
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(_maxNameLength),
                  ],
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                  // 누르면 안내 문구는 사라지고 커서만 깜빡이게 — 힌트는 포커스가 없을 때만.
                  decoration: InputDecoration.collapsed(
                    hintText: _nameFocus.hasFocus ? null : tr('자동화 제목을 입력하세요'),
                  ),
                  onChanged: (_) => setState(() => _dirty = true),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          _ActiveToggle(
            value: _enabled,
            onChanged: (v) => _edit(() => _enabled = v),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: _saving || _data == null ? null : _save,
            child: Text(tr('저장')),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _loadingOrError(ThemeData theme) {
    final error = _loadError;
    if (error == null) return const Center(child: CircularProgressIndicator());
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            tr('불러오지 못했습니다: {error}', {'error': error}),
            style: TextStyle(color: theme.hintColor),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () {
              setState(() => _loadError = null);
              _load();
            },
            child: Text(tr('다시 시도')),
          ),
        ],
      ),
    );
  }

  // ── 캔버스 ──

  Widget _buildCanvas(_EditorData d, ThemeData theme) {
    final dark = theme.brightness == Brightness.dark;
    final background = dark
        ? Color.alphaBlend(
            Colors.white.withValues(alpha: 0.03),
            theme.colorScheme.surface,
          )
        : const Color(0xFFF8FAFC);
    final dotColor = dark
        ? Colors.white.withValues(alpha: 0.12)
        : const Color(0xFFCBD5E1);

    final lines = <_EdgeLine>[
      for (final e in _graph.edges)
        if (_node(e.from) case final from?)
          if (_node(e.to) case final to?)
            (
              from: _portScreen(from, e.port),
              to: _portScreen(to, 'in'),
              selected: e == _selectedEdge,
            ),
    ];
    ({Offset from, Offset to})? link;
    AutomationNode? linkTarget;
    final linkFrom = _linkFromId == null ? null : _node(_linkFromId!);
    final pointer = _linkPointer;
    if (linkFrom != null && pointer != null) {
      link = (from: _portScreen(linkFrom, _linkPort!), to: pointer);
      final t = _nodeAt(pointer, except: linkFrom.id);
      if (t != null && _canConnect(linkFrom, t)) linkTarget = t;
    }

    return DragTarget<_PaletteItem>(
      key: const ValueKey('automation-canvas'),
      onAcceptWithDetails: (details) => _drop(details.data, details.offset),
      builder: (context, candidates, _) => Listener(
        onPointerSignal: _onPointerSignal,
        child: Stack(
          key: _canvasKey,
          children: [
            Positioned.fill(
              child: MouseRegion(
                cursor: _panning ? GrabCursors.closed : MouseCursor.defer,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // 누른 자리부터 따라가야 캔버스가 포인터에 붙어서 움직인다.
                  dragStartBehavior: DragStartBehavior.down,
                  onTapUp: (details) => _tapCanvas(details.localPosition),
                  onPanStart: (_) => setState(() => _panning = true),
                  onPanUpdate: (details) =>
                      setState(() => _offset += details.delta),
                  onPanEnd: (_) => setState(() => _panning = false),
                  onPanCancel: () => setState(() => _panning = false),
                  child: CustomPaint(
                    painter: _DotGridPainter(
                      offset: _offset,
                      scale: _scale,
                      background: background,
                      dot: dotColor,
                    ),
                    foregroundPainter: _EdgePainter(
                      edges: lines,
                      link: link,
                      scale: _scale,
                    ),
                  ),
                ),
              ),
            ),
            for (final n in _graph.nodes)
              _buildNode(n, d, highlighted: n == linkTarget),
            if (_graph.nodes.isEmpty)
              const Positioned(
                top: 20,
                left: 16,
                right: 16,
                child: IgnorePointer(child: Center(child: _EmptyHint())),
              ),
            Positioned(
              left: 16,
              bottom: 16,
              child: _ZoomControls(
                onZoomIn: () => _zoomStep(1.2),
                onZoomOut: () => _zoomStep(1 / 1.2),
              ),
            ),
            if (candidates.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: _selectColor.withValues(alpha: 0.5),
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildNode(
    AutomationNode n,
    _EditorData d, {
    required bool highlighted,
  }) {
    final h = _nodeHeight(n);
    final accent = _kindColor(n.kind);
    // 노드마다 배율을 걸어 화면 자리에 둔다 — 캔버스 전체를 변환하면 캔버스 밖(음수 좌표 등)에
    // 놓인 노드는 눌리지 않는다.
    return Positioned(
      left: _offset.dx + (n.x - _gutter) * _scale,
      top: _offset.dy + n.y * _scale,
      child: Transform.scale(
        scale: _scale,
        alignment: Alignment.topLeft,
        child: SizedBox(
          key: ValueKey('node-${n.id}'),
          width: _nodeW + _gutter * 2,
          height: h,
          child: Stack(
            children: [
              Positioned(
                left: _gutter,
                top: 0,
                width: _nodeW,
                height: h,
                child: MouseRegion(
                  cursor: _movingId == n.id
                      ? GrabCursors.closed
                      : GrabCursors.open,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    dragStartBehavior: DragStartBehavior.down,
                    onTapDown: (_) => _select(n.id),
                    onPanStart: (details) {
                      _select(n.id);
                      setState(() {
                        _movingId = n.id;
                        _moveStartGlobal = details.globalPosition;
                        _moveStartPos = Offset(n.x, n.y);
                      });
                    },
                    onPanUpdate: (details) {
                      final delta =
                          (details.globalPosition - _moveStartGlobal) / _scale;
                      _edit(() {
                        n.x = _moveStartPos.dx + delta.dx;
                        n.y = _moveStartPos.dy + delta.dy;
                      });
                    },
                    onPanEnd: (_) => setState(() => _movingId = null),
                    onPanCancel: () => setState(() => _movingId = null),
                    child: _NodeCard(
                      node: n,
                      accent: accent,
                      selected: n.id == _selectedId,
                      highlighted: highlighted,
                      rows: _summaryRows(n, d),
                    ),
                  ),
                ),
              ),
              if (n.kind != 'trigger')
                _port(n, 'in', highlighted ? _selectColor : accent),
              for (final p in _outPorts(n)) _port(n, p, accent),
            ],
          ),
        ),
      ),
    );
  }

  Widget _port(AutomationNode n, String port, Color color) {
    final c = _portOffset(n, port);
    final active = _linkFromId == n.id && _linkPort == port;
    final box = SizedBox(
      key: ValueKey('port-${n.id}-$port'),
      width: _gutter * 2,
      height: _gutter * 2,
      child: Center(
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: active ? color : Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
          ),
        ),
      ),
    );
    return Positioned(
      // 카드가 _gutter만큼 오른쪽에 있으므로 포트 중심은 _gutter + c.dx — 거기서 _gutter를 뺀 자리.
      left: c.dx,
      top: c.dy - _gutter,
      child: port == 'in'
          // 입력 포트는 놓는 자리일 뿐이라 눌러도 노드를 누른 것과 같게 한다.
          ? IgnorePointer(child: box)
          : MouseRegion(
              cursor: SystemMouseCursors.precise,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                dragStartBehavior: DragStartBehavior.down,
                onPanStart: (details) => setState(() {
                  _linkFromId = n.id;
                  _linkPort = port;
                  _linkPointer = _toLocal(details.globalPosition);
                }),
                onPanUpdate: (details) => setState(
                  () => _linkPointer = _toLocal(details.globalPosition),
                ),
                onPanEnd: (_) => _finishLink(),
                onPanCancel: () => setState(() {
                  _linkFromId = null;
                  _linkPort = null;
                  _linkPointer = null;
                }),
                child: box,
              ),
            ),
    );
  }

  // ── 노드 요약 ──

  Widget _row(String label, Widget value) {
    return SizedBox(
      height: _rowH,
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).hintColor,
              ),
            ),
          ),
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: value),
          ),
        ],
      ),
    );
  }

  Widget _valueChip(
    _EditorData d,
    String field,
    Object? value, {
    String? nullLabel,
  }) {
    if (_blank(value)) {
      return nullLabel != null
          ? _ValueChip(nullLabel)
          : _ValueChip(tr('값 선택'), placeholder: true);
    }
    // 지워진 상태·구성원·선택지 등은 기본값처럼 보이지 않게 따로 표시한다(저장 전 검사도 막는다).
    if (d.goneValue(field, value) case final what?) {
      return _ValueChip(tr('(삭제된 {what})', {'what': what}), placeholder: true);
    }
    switch (field) {
      case 'status':
        final s = d.status(value)!;
        return _ValueChip(s.name, leading: _Dot(parseTypeColor(s.color)));
      case 'priority':
        final p = d.priority(value)!;
        return _ValueChip(p.name, leading: _Dot(parseTypeColor(p.color)));
      case 'type':
        final t = d.type(value)!;
        return _ValueChip(t.name, leading: _Dot(parseTypeColor(t.color)));
      case 'assignee':
        final m = d.member(value)!;
        return _ValueChip(
          m.name,
          leading: UserAvatar(user: m, resolveUrl: d.resolveUrl, radius: 8),
        );
      default:
        switch (d.customField(field)?.kind) {
          case 'date':
            final day = _parseDay(value);
            return day == null
                ? _ValueChip(tr('(잘못된 날짜)'), placeholder: true)
                : _ValueChip(
                    _dayLabel(day),
                    leading: Icon(
                      Icons.calendar_today_outlined,
                      size: 12,
                      color: Theme.of(context).hintColor,
                    ),
                  );
          case 'progress' when _numberOf(value) != null:
            return _ValueChip('${value.toString().trim()}%');
        }
        return _ValueChip(value.toString());
    }
  }

  List<Widget> _summaryRows(AutomationNode n, _EditorData d) {
    final c = n.config;
    final hint = Theme.of(context).hintColor;
    switch (n.type) {
      case 'field_changed':
        final watched = automationTriggerFields(c);
        return [
          _row(
            tr('필드'),
            watched.isEmpty
                ? _ValueChip(tr('필드 선택'), placeholder: true)
                : _ValueChip(
                    watched.contains('any')
                        ? d.fieldLabel('any')
                        : watched.map(d.fieldLabel).join(', '),
                    placeholder: watched.any(d.fieldGone),
                  ),
          ),
        ];
      case 'if':
        final field = _str(c['field']) ?? 'status';
        final op = _str(c['op']) ?? 'eq';
        return [
          SizedBox(
            height: _rowH,
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    d.fieldLabel(field),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  automationOpLabels[op] ?? op,
                  style: TextStyle(fontSize: 12, color: hint),
                ),
                if (_needsValue(op)) ...[
                  const SizedBox(width: 6),
                  Flexible(flex: 2, child: _valueChip(d, field, c['value'])),
                ],
              ],
            ),
          ),
        ];
      case 'set_field':
        final field = _str(c['field']);
        return [
          field == null
              ? _row(tr('필드'), _ValueChip(tr('필드 선택'), placeholder: true))
              : _row(
                  d.fieldLabel(field),
                  _valueChip(
                    d,
                    field,
                    c['value'],
                    nullLabel: switch (field) {
                      'assignee' => tr('미배정'),
                      'type' => tr('없음'),
                      _ => null,
                    },
                  ),
                ),
        ];
      case 'create_task':
        final title = _str(c['title'])?.trim() ?? '';
        final statusId = c['statusId'];
        // statusId가 비어 있을 때만 기본 상태 — 지워진 상태를 기본 상태로 덮어 보이면 멀쩡해 보인다.
        final status = statusId == null ? d.defaultStatus : d.status(statusId);
        final assignee = _str(c['assignee']);
        return [
          _row(
            tr('제목'),
            title.isEmpty
                ? _ValueChip(tr('제목 입력'), placeholder: true)
                : _ValueChip(title, template: true),
          ),
          _row(
            tr('상태'),
            status == null
                ? _ValueChip(
                    statusId == null ? tr('상태 없음') : tr('(삭제된 상태)'),
                    placeholder: true,
                  )
                : _ValueChip(
                    status.name,
                    leading: _Dot(parseTypeColor(status.color)),
                  ),
          ),
          _row(
            tr('담당자'),
            assignee == 'current_assignee'
                ? _ValueChip(
                    tr('현재 담당자'),
                    leading: Icon(Icons.person_outline, size: 13, color: hint),
                  )
                : _valueChip(d, 'assignee', assignee, nullLabel: tr('없음')),
          ),
        ];
      case 'chat_message':
        final room = d.room(c['roomId']);
        final text = _str(c['text'])?.trim() ?? '';
        return [
          _row(
            tr('채팅방'),
            c['roomId'] == null
                ? _ValueChip(tr('채팅방 선택'), placeholder: true)
                : room == null
                ? _ValueChip(tr('(삭제된 채팅방)'), placeholder: true)
                : _ValueChip(
                    room.displayName(d.myUserId),
                    leading: Icon(_roomIcon(room), size: 13, color: hint),
                  ),
          ),
          _row(
            tr('메시지'),
            text.isEmpty
                ? _ValueChip(tr('메시지 입력'), placeholder: true)
                : _ValueChip(text.replaceAll('\n', ' '), template: true),
          ),
        ];
      default:
        return [
          SizedBox(
            height: _rowH,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _typeHints[n.type] ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: hint),
              ),
            ),
          ),
        ];
    }
  }

  // ── 노드 설정 칸 ──

  static const _dangerStyle = ButtonStyle(
    foregroundColor: WidgetStatePropertyAll(_dangerColor),
    side: WidgetStatePropertyAll(BorderSide(color: _dangerColor)),
    minimumSize: WidgetStatePropertyAll(Size.fromHeight(40)),
  );

  InputDecoration _inputDeco(String hint) => InputDecoration(
    hintText: hint,
    isDense: true,
    counterText: '',
    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    border: const OutlineInputBorder(),
  );

  Widget _section(String label, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }

  /// 제목·메시지 입력 칸 아래의 변수 칩 — 누르면 커서 자리에 {{task.title}} 등을 넣는다.
  /// TextFieldTapRegion 안에 둬야 데스크톱에서 칩을 눌러도 입력 칸 포커스(=커서 자리)가 안 풀린다.
  Widget _tokenChips(
    AutomationNode n,
    String slot,
    String key,
    int maxLength,
    Color hint,
  ) {
    return TextFieldTapRegion(
      child: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(tr('변수 넣기'), style: TextStyle(fontSize: 11, color: hint)),
            for (final (name, token, label) in _templateTokens)
              _TokenChip(
                key: ValueKey('token-$slot-$name'),
                label: label,
                onTap: () => _insertToken(n, slot, key, token, maxLength),
              ),
          ],
        ),
      ),
    );
  }

  List<_Opt<String?>> _valueOptions(_EditorData d, String field) =>
      switch (field) {
        'status' => [
          for (final s in d.statuses)
            _Opt(s.id, s.name, leading: _Dot(parseTypeColor(s.color))),
        ],
        'priority' => [
          for (final p in d.priorities)
            _Opt(p.id, p.name, leading: _Dot(parseTypeColor(p.color))),
        ],
        'type' => [
          for (final t in d.types)
            _Opt(t.id, t.name, leading: _Dot(parseTypeColor(t.color))),
        ],
        'assignee' => [
          for (final m in d.members)
            _Opt(
              m.id,
              m.name,
              leading: UserAvatar(user: m, resolveUrl: d.resolveUrl, radius: 9),
            ),
        ],
        _ => [
          for (final o in d.customField(field)?.options ?? const <String>[])
            _Opt(o, o),
        ],
      };

  Widget _conditionValue(AutomationNode n, _EditorData d, String field) {
    final c = n.config;
    final custom = d.customField(field);
    if (custom?.kind == 'date') {
      // 업무의 날짜 값은 시각(밀리초)이라 적은 글자와는 절대 같지 않다 — 달력에서 고른 날을
      // 'YYYY-MM-DD'로 두면 서버가 업무의 날짜도 같은 날로 바꿔 비교한다.
      return FilterDateField(
        key: const ValueKey('date-value'),
        value: _parseDay(c['value']),
        onChanged: (day) => _edit(() {
          if (day == null) {
            c.remove('value');
          } else {
            c['value'] = _dayValue(day);
          }
        }),
      );
    }
    final freeText =
        field.startsWith('field:') && !(custom?.hasOptions ?? false);
    if (freeText) {
      final numeric = custom?.kind == 'number' || custom?.kind == 'progress';
      // 글·숫자 필드는 비교할 값을 그대로 적는다(숫자 필드는 숫자만). 컨트롤러는 필드마다 따로 둔다.
      return TextField(
        key: const ValueKey('text-value'),
        controller: _textFor(n, 'value:$field', c['value']?.toString() ?? ''),
        maxLength: _maxTextLength,
        keyboardType: numeric
            ? const TextInputType.numberWithOptions(decimal: true, signed: true)
            : null,
        inputFormatters: numeric
            ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]'))]
            : null,
        decoration: _inputDeco(
          custom?.kind == 'progress'
              ? '0~100'
              : numeric
              ? tr('숫자 입력')
              : tr('값 입력'),
        ),
        onChanged: (v) => _edit(() => c['value'] = v),
      );
    }
    return _Pick<String?>(
      key: const ValueKey('pick-value'),
      value: _str(c['value']),
      options: _valueOptions(d, field),
      placeholder: tr('값 선택'),
      onChanged: (v) => _edit(() => c['value'] = v),
    );
  }

  Widget _nodeForm(AutomationNode n, _EditorData d, ThemeData theme) {
    final c = n.config;
    final hint = theme.hintColor;
    final fields = <Widget>[];
    switch (n.type) {
      case 'field_changed':
        final watched = automationTriggerFields(c);
        final order = [
          ...automationFieldLabels.keys,
          for (final f in d.fields) 'field:${f.id}',
        ];
        fields.add(
          _section(
            tr('감지할 필드'),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 지워진 사용자 정의 필드도 체크된 채로 보여 줘야 풀 수 있다.
                for (final k in [
                  ...order,
                  ...watched.where((k) => !order.contains(k)),
                ])
                  _FieldCheck(
                    key: ValueKey('check-field-$k'),
                    label: d.fieldLabel(k),
                    checked: watched.contains(k),
                    muted: d.fieldGone(k),
                    onChanged: (on) => _edit(() {
                      // 예전 {field} 한 개짜리 모양은 고치는 순간 {fields}로 바꾼다.
                      c.remove('field');
                      c['fields'] = _toggledFields(watched, k, on, order);
                    }),
                  ),
              ],
            ),
          ),
        );
        fields.add(
          Text(
            tr('여러 개를 고르면 그중 하나라도 바뀔 때 실행합니다.'),
            style: TextStyle(fontSize: 11, color: hint),
          ),
        );
      case 'if':
        final field = _str(c['field']) ?? 'status';
        final op = _str(c['op']) ?? 'eq';
        fields.add(
          _section(
            tr('필드'),
            _Pick<String>(
              key: const ValueKey('pick-field'),
              value: field,
              options: [
                for (final k in _basicFields)
                  _Opt(k, automationFieldLabels[k]!),
                for (final f in d.fields) _Opt('field:${f.id}', f.name),
              ],
              // 필드가 바뀌면 이전 값은 뜻이 없어진다.
              onChanged: (v) => _edit(() {
                c['field'] = v;
                c.remove('value');
                _clearValueTexts(n);
              }),
            ),
          ),
        );
        fields.add(
          _section(
            tr('비교'),
            _Pick<String>(
              key: const ValueKey('pick-op'),
              value: op,
              options: [
                for (final e in automationOpLabels.entries)
                  _Opt(e.key, e.value),
              ],
              onChanged: (v) => _edit(() {
                c['op'] = v;
                if (!_needsValue(v)) {
                  c.remove('value');
                  _clearValueTexts(n);
                }
              }),
            ),
          ),
        );
        if (_needsValue(op)) {
          fields.add(_section(tr('값'), _conditionValue(n, d, field)));
        }
      case 'set_field':
        final field = _str(c['field']);
        fields.add(
          _section(
            tr('필드'),
            _Pick<String?>(
              key: const ValueKey('pick-field'),
              value: field,
              placeholder: tr('필드 선택'),
              options: [
                for (final k in _basicFields)
                  _Opt(k, automationFieldLabels[k]!),
              ],
              onChanged: (v) => _edit(() {
                c['field'] = v;
                c['value'] = null;
              }),
            ),
          ),
        );
        if (field != null) {
          fields.add(
            _section(
              tr('값'),
              _Pick<String?>(
                key: const ValueKey('pick-value'),
                value: _str(c['value']),
                placeholder: tr('값 선택'),
                options: [
                  // 담당자·유형은 비우는 것도 값이다(상태·우선순위는 꼭 있어야 한다).
                  if (field == 'assignee') _Opt(null, tr('미배정')),
                  if (field == 'type') _Opt(null, tr('없음')),
                  ..._valueOptions(d, field),
                ],
                onChanged: (v) => _edit(() => c['value'] = v),
              ),
            ),
          );
        }
      case 'create_task':
        fields.add(
          _section(
            tr('제목'),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const ValueKey('text-title'),
                  controller: _textFor(n, 'title', _str(c['title']) ?? ''),
                  focusNode: _focusFor(n, 'title'),
                  maxLength: _maxTitleLength,
                  decoration: _inputDeco(tr('업무 제목')),
                  onChanged: (v) => _edit(() => c['title'] = v),
                ),
                _tokenChips(n, 'title', 'title', _maxTitleLength, hint),
              ],
            ),
          ),
        );
        fields.add(
          _section(
            tr('상태'),
            _Pick<String?>(
              key: const ValueKey('pick-status'),
              value: _str(c['statusId']) ?? d.defaultStatus?.id,
              placeholder: tr('상태 선택'),
              options: _valueOptions(d, 'status'),
              onChanged: (v) => _edit(() => c['statusId'] = v),
            ),
          ),
        );
        fields.add(
          _section(
            tr('담당자'),
            _Pick<String?>(
              key: const ValueKey('pick-assignee'),
              value: _str(c['assignee']),
              options: [
                _Opt(null, tr('없음')),
                _Opt(
                  'current_assignee',
                  tr('현재 담당자'),
                  leading: Icon(Icons.person_outline, size: 16, color: hint),
                ),
                ..._valueOptions(d, 'assignee'),
              ],
              onChanged: (v) => _edit(() => c['assignee'] = v),
            ),
          ),
        );
      case 'chat_message':
        fields.add(
          _section(
            tr('채팅방'),
            d.rooms.isEmpty && c['roomId'] == null
                ? Text(
                    tr('보낼 수 있는 채팅방이 없습니다.'),
                    style: TextStyle(fontSize: 12, color: hint),
                  )
                : _Pick<String?>(
                    key: const ValueKey('pick-room'),
                    value: _str(c['roomId']),
                    placeholder: tr('채팅방 선택'),
                    options: [
                      for (final r in d.rooms)
                        _Opt(
                          r.id,
                          r.displayName(d.myUserId),
                          leading: Icon(_roomIcon(r), size: 16, color: hint),
                        ),
                    ],
                    onChanged: (v) => _edit(() => c['roomId'] = v),
                  ),
          ),
        );
        fields.add(
          _section(
            tr('메시지'),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const ValueKey('text-text'),
                  controller: _textFor(n, 'text', _str(c['text']) ?? ''),
                  focusNode: _focusFor(n, 'text'),
                  minLines: 4,
                  maxLines: 8,
                  maxLength: _maxTextLength,
                  decoration: _inputDeco(tr('보낼 내용을 입력하세요')),
                  onChanged: (v) => _edit(() => c['text'] = v),
                ),
                _tokenChips(n, 'text', 'text', _maxTextLength, hint),
              ],
            ),
          ),
        );
        fields.add(
          Text(
            tr(
              '\'자동화\'가 보낸 메시지로 올라가 안읽음·알림이 갑니다. 메시지 앞에 [규칙 이름]과 업무 번호·제목이, 끝에 (실행한 사람: 이름)이 붙습니다. 이 규칙을 저장한 사람이 그 대화방·프로젝트 권한을 잃으면 규칙이 저절로 꺼집니다.',
            ),
            style: TextStyle(fontSize: 11, color: hint),
          ),
        );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _TypeIcon(
              icon: _typeIcon(n.type),
              color: _kindColor(n.kind),
              size: 28,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _typeLabel(n.kind, n.type),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              _kindLabel(n.kind),
              style: TextStyle(fontSize: 11, color: hint),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (fields.isEmpty)
          Text(tr('옵션이 없습니다.'), style: TextStyle(color: hint))
        else
          ...fields,
      ],
    );
  }

  Widget _edgeForm(AutomationEdge e, ThemeData theme) {
    String name(AutomationNode? n) =>
        n == null ? tr('(없는 노드)') : _typeLabel(n.kind, n.type);
    final branch = switch (e.port) {
      'yes' => ' (Yes)',
      'no' => ' (No)',
      _ => '',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          tr('연결'),
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          '${name(_node(e.from))}$branch → ${name(_node(e.to))}',
          style: const TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          style: _dangerStyle,
          onPressed: () => _deleteEdge(e),
          icon: const Icon(Icons.link_off, size: 18),
          label: Text(tr('연결 삭제')),
        ),
      ],
    );
  }

  /// 오른쪽 설정 칸. [overlay]면 좁은 창에서 캔버스 위에 떠 있는 칸이라 닫기 버튼을 단다.
  Widget _buildPanel(_EditorData d, ThemeData theme, {bool overlay = false}) {
    final node = _selectedNode;
    final edge = _selectedEdge;
    final title = Text(
      tr('노드 설정'),
      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
    );
    return Container(
      key: const ValueKey('automation-panel'),
      width: overlay ? null : 300,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(left: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (overlay)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 6, 2),
              child: Row(
                children: [
                  Expanded(child: title),
                  IconButton(
                    tooltip: tr('닫기'),
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() {
                      _selectedId = null;
                      _selectedEdge = null;
                    }),
                  ),
                ],
              ),
            )
          else
            Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 12), child: title),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: node != null
                  // 노드가 바뀌면 고르기 칸의 열림 상태 등도 새로 시작한다.
                  ? KeyedSubtree(
                      key: ValueKey('panel-${node.id}'),
                      child: _nodeForm(node, d, theme),
                    )
                  : edge != null
                  ? _edgeForm(edge, theme)
                  : Text(
                      tr('옵션이 없습니다.'),
                      style: TextStyle(color: theme.hintColor),
                    ),
            ),
          ),
          if (node != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: OutlinedButton.icon(
                style: _dangerStyle,
                onPressed: () => _deleteNode(node.id),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text(tr('노드 삭제')),
              ),
            ),
        ],
      ),
    );
  }
}

// ───────────────────────── 작은 위젯들 ─────────────────────────

/// 상단의 '활성'/'비활성' 알약 스위치.
class _ActiveToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ActiveToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = value
        ? _actionColor
        : (dark ? Colors.white24 : const Color(0xFFCBD5E1));
    final textColor = value || dark ? Colors.white : const Color(0xFF475569);
    final knob = Container(
      width: 20,
      height: 20,
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
    );
    final label = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7),
      child: Text(
        value ? tr('활성') : tr('비활성'),
        style: TextStyle(
          color: textColor,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    return Semantics(
      button: true,
      toggled: value,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => onChanged(!value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: value ? [label, knob] : [knob, label],
            ),
          ),
        ),
      ),
    );
  }
}

/// 옅은 색 네모 안의 종류 아이콘(팔레트·노드 머리·설정 칸).
class _TypeIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  const _TypeIcon({required this.icon, required this.color, this.size = 26});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Icon(icon, size: size * 0.6, color: color),
    );
  }
}

/// 필드 변경 트리거 설정 칸의 체크 한 줄. [muted]면 지워진 필드라 흐리게 보인다.
class _FieldCheck extends StatelessWidget {
  final String label;
  final bool checked;
  final bool muted;
  final ValueChanged<bool> onChanged;
  const _FieldCheck({
    super.key,
    required this.label,
    required this.checked,
    required this.onChanged,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!checked),
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: 32,
        child: Row(
          children: [
            Checkbox(
              value: checked,
              onChanged: (v) => onChanged(v ?? false),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: muted ? Theme.of(context).hintColor : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 제목·메시지에 변수를 넣는 작은 칩.
class _TokenChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _TokenChip({super.key, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = _tokenColor(Theme.of(context).brightness == Brightness.dark);
    return Material(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add, size: 12, color: color),
              const SizedBox(width: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  const _Dot(this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// 노드 요약 줄의 값 조각. [placeholder]면 아직 안 정한 값(테두리만). [template]이면 제목·메시지처럼
/// 변수({{task.title}} 등)가 들어갈 수 있는 글이라 변수를 {업무 제목}처럼 바꿔 색을 달리한다.
class _ValueChip extends StatelessWidget {
  final String text;
  final Widget? leading;
  final bool placeholder;
  final bool template;
  const _ValueChip(
    this.text, {
    this.leading,
    this.placeholder = false,
    this.template = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final style = TextStyle(
      fontSize: 12,
      color: placeholder ? theme.hintColor : null,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: placeholder
            ? null
            : (dark
                  ? Colors.white.withValues(alpha: 0.08)
                  : const Color(0xFFF1F5F9)),
        borderRadius: BorderRadius.circular(6),
        border: placeholder ? Border.all(color: theme.dividerColor) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 5)],
          Flexible(
            child: template
                ? Text.rich(
                    TextSpan(
                      children: _templateSpans(
                        text,
                        TextStyle(
                          color: _tokenColor(dark),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  )
                : Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
          ),
        ],
      ),
    );
  }
}

/// 캔버스 위의 노드 카드 — 왼쪽 색 띠, 머리(아이콘·이름·종류), 요약 줄, 조건이면 Yes/No 줄.
class _NodeCard extends StatelessWidget {
  final AutomationNode node;
  final Color accent;
  final bool selected;

  /// 새 연결을 놓을 수 있는 대상으로 떠 있는지.
  final bool highlighted;
  final List<Widget> rows;

  const _NodeCard({
    required this.node,
    required this.accent,
    required this.selected,
    required this.highlighted,
    required this.rows,
  });

  Widget _branch(String label, Color color) => SizedBox(
    height: _branchRowH,
    child: Align(
      alignment: Alignment.centerRight,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final line = dark ? theme.dividerColor : const Color(0xFFE2E8F0);
    final strong = selected || highlighted;
    final radius = BorderRadius.circular(12);
    return Container(
      decoration: BoxDecoration(
        color: dark ? theme.colorScheme.surfaceContainerHigh : Colors.white,
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: selected ? 0.12 : 0.05),
            blurRadius: selected ? 12 : 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      // 테두리는 위에 덧그려서, 선택해 굵어져도 안쪽 배치(=포트 자리)가 흔들리지 않게 한다.
      foregroundDecoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(
          color: strong ? _selectColor : line,
          width: strong ? 2 : 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 4, color: accent),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: _headH,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 10, right: 12),
                      child: Row(
                        children: [
                          _TypeIcon(
                            icon: _typeIcon(node.type),
                            color: accent,
                            size: 22,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _typeLabel(node.kind, node.type),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Text(
                            _kindLabel(node.kind),
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.hintColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Divider(height: 1, thickness: 1, color: line),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      10,
                      _bodyPad,
                      12,
                      _bodyPad,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ...rows,
                        if (node.kind == 'condition') ...[
                          _branch('Yes', _actionColor),
                          _branch('No', _dangerColor),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: dark ? theme.colorScheme.surfaceContainerHigh : Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: dark ? theme.dividerColor : const Color(0xFFE2E8F0),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.touch_app_outlined, size: 16, color: theme.hintColor),
          const SizedBox(width: 6),
          // 좁은 캔버스에서는 넘치지 않고 줄을 바꾼다.
          Flexible(
            child: Text(
              tr('왼쪽에서 트리거를 끌어다 놓아 시작하세요'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _ZoomControls extends StatelessWidget {
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  const _ZoomControls({required this.onZoomIn, required this.onZoomOut});

  Widget _button(IconData icon, String tooltip, VoidCallback onTap) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      child: SizedBox(width: 32, height: 32, child: Icon(icon, size: 18)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final line = dark ? theme.dividerColor : const Color(0xFFE2E8F0);
    return Material(
      color: dark ? theme.colorScheme.surfaceContainerHigh : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _button(Icons.add, tr('확대'), onZoomIn),
          SizedBox(width: 32, child: Divider(height: 1, color: line)),
          _button(Icons.remove, tr('축소'), onZoomOut),
        ],
      ),
    );
  }
}

// ───────────────────────── 팔레트 ─────────────────────────

class _Palette extends StatelessWidget {
  /// 좁은 창에서는 아이콘만 세로로 늘어놓은 줄(이름은 툴팁)로 줄여 캔버스 자리를 남긴다.
  final bool compact;
  const _Palette({this.compact = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: compact ? _railW : 200,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(right: BorderSide(color: theme.dividerColor)),
      ),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: compact
            ? [
                for (final (i, items) in const [
                  _triggerItems,
                  _conditionItems,
                  _actionItems,
                ].indexed) ...[
                  if (i > 0)
                    const Divider(height: 17, indent: 12, endIndent: 12),
                  for (final item in items) _PaletteTile(item, compact: true),
                ],
              ]
            : [
                _PaletteHeader(tr('트리거'), tr('(언제 실행할지)')),
                for (final item in _triggerItems) _PaletteTile(item),
                const SizedBox(height: 12),
                _PaletteHeader(tr('조건'), tr('(어떤 경우에만)')),
                for (final item in _conditionItems) _PaletteTile(item),
                const SizedBox(height: 12),
                _PaletteHeader(tr('액션'), tr('(무엇을 할지)')),
                for (final item in _actionItems) _PaletteTile(item),
              ],
      ),
    );
  }
}

class _PaletteHeader extends StatelessWidget {
  final String title;
  final String sub;
  const _PaletteHeader(this.title, this.sub);

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: Text.rich(
        TextSpan(
          text: title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: hint,
          ),
          children: [
            TextSpan(
              text: '  $sub',
              style: TextStyle(
                fontWeight: FontWeight.w400,
                color: hint.withValues(alpha: hint.a * 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PaletteTile extends StatefulWidget {
  final _PaletteItem item;

  /// 아이콘만(좁은 창의 팔레트 줄).
  final bool compact;
  const _PaletteTile(this.item, {this.compact = false});

  @override
  State<_PaletteTile> createState() => _PaletteTileState();
}

class _PaletteTileState extends State<_PaletteTile> {
  bool _hover = false;

  Widget _tile(BuildContext context, bool hover) {
    final item = widget.item;
    final icon = _TypeIcon(
      icon: _typeIcon(item.type),
      color: _kindColor(item.kind),
    );
    return Container(
      height: 40,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: EdgeInsets.symmetric(horizontal: widget.compact ? 0 : 8),
      alignment: widget.compact ? Alignment.center : null,
      decoration: BoxDecoration(
        color: hover
            ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05)
            : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: widget.compact
          ? icon
          : Row(
              children: [
                icon,
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Draggable<_PaletteItem>(
      key: ValueKey('palette-${item.kind}-${item.type}'),
      data: item,
      dragAnchorStrategy: (_, _, _) => _dropAnchor,
      feedback: _PaletteFeedback(item),
      childWhenDragging: Opacity(opacity: 0.4, child: _tile(context, false)),
      child: MouseRegion(
        cursor: GrabCursors.open,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: widget.compact
            ? Tooltip(
                message: '${_kindLabel(item.kind)} · ${item.label}',
                child: _tile(context, _hover),
              )
            : _tile(context, _hover),
      ),
    );
  }
}

/// 팔레트에서 끄는 동안 포인터를 따라다니는 카드.
class _PaletteFeedback extends StatelessWidget {
  final _PaletteItem item;
  const _PaletteFeedback(this.item);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final color = _kindColor(item.kind);
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 200,
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: dark ? theme.colorScheme.surfaceContainerHigh : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.6)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            _TypeIcon(icon: _typeIcon(item.type), color: color, size: 24),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              _kindLabel(item.kind),
              style: TextStyle(fontSize: 11, color: theme.hintColor),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── 고르기 칸 ─────────────────────────

class _Opt<T> {
  final T value;
  final String label;
  final Widget? leading;
  const _Opt(this.value, this.label, {this.leading});
}

/// 설정 칸의 한 개짜리 고르기 — 필터 칸과 같은 모양이고, 항목 앞에 색 점·사진을 붙일 수 있다.
/// [value]와 같은 항목이 없으면 [placeholder]를 보여준다(null도 항목의 값이 될 수 있다).
class _Pick<T> extends StatelessWidget {
  final T value;
  final List<_Opt<T>> options;
  final ValueChanged<T> onChanged;
  final String placeholder;

  const _Pick({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.placeholder = '선택하세요',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final hint = theme.hintColor;
    final current = options.where((o) => o.value == value).firstOrNull;
    return FilterPopup(
      matchWidth: true,
      anchorBuilder: (context, open, toggle) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: toggle,
          child: Container(
            height: 36,
            padding: const EdgeInsets.only(left: 10, right: 6),
            decoration: BoxDecoration(
              color: dark
                  ? theme.colorScheme.surfaceContainerHighest
                  : const Color(0xFFF1F3F6),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: open
                    ? filterAccent
                    : (dark ? theme.dividerColor : const Color(0xFFD6DAE1)),
              ),
            ),
            child: Row(
              children: [
                if (current?.leading case final leading?) ...[
                  leading,
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    current?.label ?? tr(placeholder),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: current == null ? hint : null,
                    ),
                  ),
                ),
                Icon(
                  open ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                  size: 18,
                  color: hint,
                ),
              ],
            ),
          ),
        ),
      ),
      popupBuilder: (context, close) => FilterPopupCard(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              if (options.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    tr('항목이 없습니다.'),
                    style: TextStyle(fontSize: 13, color: hint),
                  ),
                ),
              for (final o in options)
                InkWell(
                  onTap: () {
                    close();
                    if (o.value != value) onChanged(o.value);
                  },
                  child: Container(
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        if (o.leading case final leading?) ...[
                          leading,
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Text(
                            o.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: o.value == value ? filterAccent : null,
                              fontWeight: o.value == value
                                  ? FontWeight.w700
                                  : null,
                            ),
                          ),
                        ),
                        if (o.value == value)
                          const Icon(
                            Icons.check,
                            size: 16,
                            color: filterAccent,
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── 그리기 ─────────────────────────

/// 캔버스 바탕과 점 격자 — 이동·확대를 따라 움직인다.
class _DotGridPainter extends CustomPainter {
  final Offset offset;
  final double scale;
  final Color background;
  final Color dot;

  const _DotGridPainter({
    required this.offset,
    required this.scale,
    required this.background,
    required this.dot,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final step = _gridStep * scale;
    final points = <Offset>[];
    for (var x = offset.dx % step; x < size.width; x += step) {
      for (var y = offset.dy % step; y < size.height; y += step) {
        points.add(Offset(x, y));
      }
    }
    canvas.drawPoints(
      PointMode.points,
      points,
      Paint()
        ..color = dot
        ..strokeWidth = (2.4 * scale).clamp(1.6, 3.2)
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_DotGridPainter old) =>
      old.offset != offset ||
      old.scale != scale ||
      old.background != background ||
      old.dot != dot;
}

/// 노드 사이 연결선과, 포트에서 끌고 있는 새 연결선.
class _EdgePainter extends CustomPainter {
  final List<_EdgeLine> edges;
  final ({Offset from, Offset to})? link;
  final double scale;

  const _EdgePainter({
    required this.edges,
    required this.link,
    required this.scale,
  });

  Path _path(Offset a, Offset b) {
    final (c1, c2) = _edgeControls(a, b, scale);
    return Path()
      ..moveTo(a.dx, a.dy)
      ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, b.dx, b.dy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final width = (2 * scale).clamp(1.5, 3.0);
    for (final e in edges) {
      canvas.drawPath(
        _path(e.from, e.to),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = e.selected ? width + 1 : width
          ..color = e.selected ? _selectColor : _edgeColor,
      );
    }
    final l = link;
    if (l != null) {
      canvas.drawPath(
        _path(l.from, l.to),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = _selectColor.withValues(alpha: 0.8),
      );
      canvas.drawCircle(l.to, 4, Paint()..color = _selectColor);
    }
  }

  // 목록은 빌드마다 새로 만들어서 비교 대신 늘 다시 그린다(선 몇십 개라 가볍다).
  @override
  bool shouldRepaint(_EdgePainter old) => true;
}
