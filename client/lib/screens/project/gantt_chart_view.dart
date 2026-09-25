import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/muted_scrollbar.dart';
import 'task_detail_panel.dart' show TaskPanelScope;
import 'task_views.dart';
import '../../widgets/grab_cursors.dart';

/// 간트차트 눈금 단위.
enum GanttScale { day, week, month, quarter }

/// 날짜 두 개 사이의 날 수(서머타임 등 시각 차이에 흔들리지 않게 UTC 자정끼리 잰다).
int _daysBetween(DateTime a, DateTime b) => DateTime.utc(
  b.year,
  b.month,
  b.day,
).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

/// 축척 하나 — 눈금 한 칸(unit)의 시작·다음 칸·이름과, 그 위 줄 묶음(group)의 이름을 정한다.
class _Scale {
  final GanttScale kind;
  const _Scale(this.kind);

  /// 100%일 때 한 칸 폭.
  double get baseUnitW => switch (kind) {
    GanttScale.day => 36,
    GanttScale.week => 72,
    GanttScale.month => 100,
    GanttScale.quarter => 150,
  };

  DateTime unitStart(DateTime d) => switch (kind) {
    GanttScale.day => DateTime(d.year, d.month, d.day),
    // 주는 일요일부터(달력과 같게).
    GanttScale.week => DateTime(d.year, d.month, d.day - d.weekday % 7),
    GanttScale.month => DateTime(d.year, d.month),
    GanttScale.quarter => DateTime(d.year, ((d.month - 1) ~/ 3) * 3 + 1),
  };

  DateTime nextUnit(DateTime s) => switch (kind) {
    GanttScale.day => DateTime(s.year, s.month, s.day + 1),
    GanttScale.week => DateTime(s.year, s.month, s.day + 7),
    GanttScale.month => DateTime(s.year, s.month + 1),
    GanttScale.quarter => DateTime(s.year, s.month + 3),
  };

  DateTime prevUnit(DateTime s) =>
      unitStart(DateTime(s.year, s.month, s.day - 1));

  String unitLabel(DateTime s) => switch (kind) {
    GanttScale.day => '${s.day}',
    GanttScale.week => '${s.month}/${s.day}',
    GanttScale.month => '${s.month}월',
    GanttScale.quarter => '${(s.month - 1) ~/ 3 + 1}분기',
  };

  /// 위 줄 묶음 이름 — 같은 이름이 이어지는 칸들을 한 칸으로 합쳐 그린다.
  String groupLabel(DateTime s) => switch (kind) {
    GanttScale.day || GanttScale.week => '${s.year}년 ${s.month}월',
    GanttScale.month => '${s.year} ${(s.month - 1) ~/ 3 + 1}분기',
    GanttScale.quarter => '${s.year}년',
  };
}

/// 가로 눈금 — 칸마다 시작 날짜와 폭. 날짜 ↔ 가로 위치 변환을 맡는다.
class _Timeline {
  final _Scale scale;
  final double unitW;
  final List<DateTime> units;

  /// 마지막 칸의 끝(다음 칸 시작).
  final DateTime end;

  _Timeline(this.scale, this.unitW, this.units, this.end);

  double get width => units.length * unitW;

  int _indexOf(DateTime d) {
    var lo = 0, hi = units.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (!units[mid].isAfter(d)) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  DateTime _unitEnd(int i) => i + 1 < units.length ? units[i + 1] : end;

  /// 그 날짜가 시작되는 가로 위치.
  double x(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    if (d.isBefore(units.first)) return 0;
    if (!d.isBefore(end)) return width;
    final i = _indexOf(d);
    final days = _daysBetween(units[i], _unitEnd(i));
    return (i + _daysBetween(units[i], d) / days) * unitW;
  }

  /// 그 날짜 근처에서 하루가 차지하는 폭(끌기를 날 수로 바꿀 때 쓴다).
  double pxPerDay(DateTime date) {
    final i = _indexOf(DateTime(date.year, date.month, date.day));
    return unitW / _daysBetween(units[i], _unitEnd(i));
  }

  static _Timeline build({
    required _Scale scale,
    required double unitW,
    required DateTime lo,
    required DateTime hi,
    required double minWidth,
  }) {
    var start = scale.unitStart(lo);
    for (var i = 0; i < 2; i++) {
      start = scale.prevUnit(start);
    }
    final units = <DateTime>[];
    var u = start;
    // 마지막 업무 뒤로 두 칸 더, 그리고 화면 폭만큼은 채운다.
    final stop = scale.nextUnit(
      scale.nextUnit(scale.nextUnit(scale.unitStart(hi))),
    );
    while (u.isBefore(stop) || units.length * unitW < minWidth) {
      units.add(u);
      u = scale.nextUnit(u);
    }
    return _Timeline(scale, unitW, units, u);
  }
}

/// 간트차트에서 사용자가 고른 설정 — 화면이 새로 만들어져도(업무 패널이 열리거나 창 폭이
/// 바뀌어 화면 구조가 달라질 때) 그대로 이어지도록 화면 밖에 기억해 둔다.
class _GanttPrefs {
  GanttScale scale = GanttScale.month;
  double zoom = 1.0;
  bool mineOnly = false;
  Set<String>? selected;
  final collapsed = <String>{};
  double? offset;
}

/// 묶음 하나(프로젝트 또는 상태) — id · 이름 · 색 · (프로젝트면) 키.
typedef _GroupDef = ({String id, String name, Color color, String key});

/// 업무 간트차트 — 업무를 묶음별 둥근 카드로 나눠 타임라인으로 본다.
/// - 사이드바 "간트차트": 프로젝트별로 묶는다([statuses]가 없을 때). 프로젝트 고르기 칸이 있다.
/// - 프로젝트의 "간트차트" 탭: [statuses]를 주면 상태별로 묶는다.
///
/// 막대 가운데를 끌면 일정을 통째로 옮기고, 양 끝을 끌면 시작일·마감일을 늘리거나 줄인다.
class GanttChartView extends StatefulWidget {
  final Session session;
  final List<Task> tasks;
  final ValueChanged<Task> onOpen;

  /// 일정을 고친 뒤 업무 목록을 다시 읽게 한다.
  final VoidCallback onChanged;

  /// 프로젝트별로 묶을 때 프로젝트 목록(이름·색·키)을 받아올 팀.
  final String? teamId;

  /// 주면 상태별로 묶는다(프로젝트 안의 간트차트).
  final List<TaskStatusDef>? statuses;

  /// 설정(축척·확대·필터·접힘·스크롤 위치)을 기억할 이름 — 화면마다 따로.
  final String prefsKey;

  /// 종료된 프로젝트처럼 고칠 수 없으면 막대를 끌 수 없다.
  final bool readOnly;

  const GanttChartView({
    super.key,
    required this.session,
    required this.tasks,
    required this.onOpen,
    required this.onChanged,
    required this.prefsKey,
    this.teamId,
    this.statuses,
    this.readOnly = false,
  });

  /// 기억해 둔 설정을 지운다 — 테스트끼리 값이 이어지지 않게.
  @visibleForTesting
  static void resetPrefs() => _GanttChartViewState._prefs.clear();

  @override
  State<GanttChartView> createState() => _GanttChartViewState();
}

class _GanttChartViewState extends State<GanttChartView> {
  static const _leftW = 240.0;
  static const _headRowH = 30.0;
  static const _groupH = 36.0;
  static const _rowH = 28.0;
  static const _zoomSteps = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
  static final _prefs = <String, _GanttPrefs>{};

  late final _GanttPrefs _p = _prefs.putIfAbsent(
    widget.prefsKey,
    _GanttPrefs.new,
  );

  bool get _byStatus => widget.statuses != null;

  List<Project> _projects = const [];

  /// 가로 스크롤 — 표 아래 스크롤 줄이 이 컨트롤러를 갖고, 머리글·모든 줄이 이 위치를 따른다.
  final _hScroll = ScrollController();
  final _vScroll = ScrollController();

  /// 끌어서 고쳐 저장 중인 일정 — 목록을 다시 받아올 때까지 새 자리에 그려 둔다.
  final _pending = <String, (DateTime, DateTime)>{};

  /// 지금 끌고 있는 막대.
  String? _dragId;

  /// 마우스를 누르고 있는 막대 — 누르는 순간(끌기 전)부터 쥔 손 커서로 바꾼다.
  String? _pressedId;
  String _dragMode = 'move'; // 'move' | 'start' | 'end'
  double _dragDx = 0;

  /// 처음 그릴 때 한 번 — 기억한 스크롤 위치(없으면 오늘)로 옮긴다.
  bool _placed = false;

  @override
  void initState() {
    super.initState();
    _hScroll.addListener(() {
      if (_hScroll.hasClients) _p.offset = _hScroll.offset;
    });
    if (!_byStatus) _loadProjects();
  }

  @override
  void didUpdateWidget(GanttChartView old) {
    super.didUpdateWidget(old);
    if (!identical(old.tasks, widget.tasks)) _pending.clear();
  }

  @override
  void dispose() {
    _hScroll.dispose();
    _vScroll.dispose();
    super.dispose();
  }

  Future<void> _loadProjects() async {
    final teamId = widget.teamId;
    if (teamId == null) return;
    try {
      final list = await widget.session.api!.fetchProjects(teamId);
      if (mounted) setState(() => _projects = list);
    } catch (_) {
      // 프로젝트 목록을 못 받아도 업무에 딸린 프로젝트 이름으로 그린다.
    }
  }

  // ── 데이터 ──

  (DateTime, DateTime)? _rangeOf(Task t) => _pending[t.id] ?? taskRange(t);

  /// 묶음들 — 프로젝트(프로젝트 목록 순서, 없으면 업무 순서) 또는 상태(정해 둔 순서).
  List<_GroupDef> _groupDefs() {
    final statuses = widget.statuses;
    if (statuses != null) {
      final sorted = [...statuses]
        ..sort((a, b) => a.position.compareTo(b.position));
      return [
        for (final s in sorted)
          (id: s.id, name: s.name, color: parseTypeColor(s.color), key: ''),
      ];
    }
    final seen = <String>{};
    final out = <_GroupDef>[];
    for (final p in _projects) {
      if (seen.add(p.id)) {
        out.add((
          id: p.id,
          name: p.name,
          color: parseTypeColor(p.color),
          key: p.identifier,
        ));
      }
    }
    for (final t in widget.tasks) {
      if (seen.add(t.projectId)) {
        out.add((
          id: t.projectId,
          name: t.projectName ?? '프로젝트',
          color: Colors.blueGrey,
          key: t.key?.split('-').first ?? '',
        ));
      }
    }
    return out;
  }

  /// 업무가 들어갈 묶음 id.
  String _groupOf(Task t) {
    final statuses = widget.statuses;
    if (statuses == null) return t.projectId;
    if (statuses.any((s) => s.id == t.statusId)) return t.statusId!;
    // 예전 업무는 statusId가 비어 있다 — 같은 분류의 첫 상태로 본다.
    final byCategory = [...statuses]
      ..sort((a, b) => a.position.compareTo(b.position));
    return (byCategory.where((s) => s.category == t.status).firstOrNull ??
                byCategory.firstOrNull)
            ?.id ??
        '';
  }

  // ── 스크롤 ──

  void _scrollTo(double x) {
    if (!_hScroll.hasClients) return;
    final pos = _hScroll.position;
    _hScroll.jumpTo(x.clamp(0.0, pos.maxScrollExtent));
  }

  void _scrollBy(double dx) {
    if (!_hScroll.hasClients) return;
    _scrollTo(_hScroll.offset + dx);
  }

  void _scrollToToday(_Timeline tl, double viewW) {
    _scrollTo(tl.x(DateTime.now()) - viewW / 3);
  }

  /// 축척·확대를 바꾸면 기억한 스크롤 위치는 맞지 않으니 오늘로 다시 맞춘다.
  void _rescale(VoidCallback change) => setState(() {
    change();
    _p.offset = null;
    _placed = false;
  });

  // ── 일정 저장 ──

  Future<void> _save(Task t, DateTime start, DateTime due) async {
    setState(() => _pending[t.id] = (start, due));
    try {
      await widget.session.api!.updateTask(
        t.id,
        startDate: start,
        dueDate: due,
      );
      widget.onChanged();
      // 업무 패널이 열려 있으면 바뀐 기간이 바로 보이게.
      if (mounted) TaskPanelScope.notifyChanged(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _pending.remove(t.id));
      showAppToast(context, '일정을 바꾸지 못했습니다: $e');
    }
  }

  /// 막대를 놓았을 때 바뀐 일정을 보여주고 저장할지 묻는다. 가운데를 끌었으면(옮기기)
  /// 시작일·마감일을 둘 다, 끝을 끌었으면(늘리기·줄이기) 바뀐 쪽만 보여준다.
  Future<bool> _confirmSchedule(
    Task t,
    (DateTime, DateTime) from,
    (DateTime, DateTime) to,
    String mode,
  ) async {
    String fmt(DateTime d) => '${d.year}년 ${d.month}월 ${d.day}일';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        Widget row(String label, DateTime before, DateTime after) => Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Row(
            children: [
              SizedBox(
                width: 76,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: theme.hintColor,
                  ),
                ),
              ),
              Text(
                fmt(before),
                style: TextStyle(
                  fontSize: 15,
                  color: theme.hintColor,
                  decoration: TextDecoration.lineThrough,
                  decorationColor: theme.hintColor,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                fmt(after),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        );
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: IntrinsicWidth(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '일정 변경',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          t.title,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (mode != 'end') row('시작일', from.$1, to.$1),
                        if (mode != 'start') row('마감일', from.$2, to.$2),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: theme.dividerColor),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 14, 24, 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: theme.dividerColor),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: const Text('취소'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          autofocus: true,
                          onPressed: () => Navigator.of(context).pop(true),
                          style: FilledButton.styleFrom(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: const Text('확인'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    return ok == true;
  }

  /// 끄는 동안의 미리보기 일정.
  (DateTime, DateTime) _dragPreview(Task t, _Timeline tl) {
    final (s, e) = _rangeOf(t)!;
    final days = (_dragDx / tl.pxPerDay(s)).round();
    DateTime add(DateTime d) => DateTime(d.year, d.month, d.day + days);
    return switch (_dragMode) {
      'start' => (add(s).isAfter(e) ? e : add(s), e),
      'end' => (s, add(e).isBefore(s) ? s : add(e)),
      _ => (add(s), add(e)),
    };
  }

  // ── 도구줄 ──

  Widget _segmented(ThemeData theme) {
    Widget item(String label, GanttScale v) {
      final on = _p.scale == v;
      return InkWell(
        onTap: () => _rescale(() => _p.scale = v),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: on ? theme.colorScheme.surface : null,
            borderRadius: BorderRadius.circular(6),
            boxShadow: on
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: on ? FontWeight.w600 : FontWeight.normal,
              color: on ? theme.colorScheme.primary : theme.hintColor,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          item('일', GanttScale.day),
          item('주', GanttScale.week),
          item('월', GanttScale.month),
          item('분기', GanttScale.quarter),
        ],
      ),
    );
  }

  Widget _zoomControls(ThemeData theme) {
    final i = _zoomSteps.indexOf(_p.zoom);
    Widget button(IconData icon, String tip, VoidCallback? onPressed) =>
        IconButton.outlined(
          icon: Icon(icon, size: 16),
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          style: IconButton.styleFrom(
            side: BorderSide(color: theme.dividerColor),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onPressed: onPressed,
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        button(
          Icons.remove,
          '축소',
          i > 0 ? () => _rescale(() => _p.zoom = _zoomSteps[i - 1]) : null,
        ),
        SizedBox(
          width: 52,
          child: Text(
            '${(_p.zoom * 100).round()}%',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        button(
          Icons.add,
          '확대',
          i < _zoomSteps.length - 1
              ? () => _rescale(() => _p.zoom = _zoomSteps[i + 1])
              : null,
        ),
      ],
    );
  }

  Widget _mineToggle(ThemeData theme) => InkWell(
    onTap: () => setState(() => _p.mineOnly = !_p.mineOnly),
    borderRadius: BorderRadius.circular(8),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _p.mineOnly ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 20,
            color: _p.mineOnly ? theme.colorScheme.primary : theme.hintColor,
          ),
          const SizedBox(width: 6),
          const Text('내 업무', style: TextStyle(fontSize: 13)),
        ],
      ),
    ),
  );

  // ── 표 ──

  /// 가로 눈금 머리글(위: 묶음, 아래: 칸). 오늘이 든 칸은 옅은 파랑.
  Widget _timelineHeader(ThemeData theme, _Timeline tl, Color line) {
    final scale = tl.scale;
    final today = DateTime.now();
    final groups = <(String, int)>[];
    for (final u in tl.units) {
      final label = scale.groupLabel(u);
      if (groups.isNotEmpty && groups.last.$1 == label) {
        groups[groups.length - 1] = (label, groups.last.$2 + 1);
      } else {
        groups.add((label, 1));
      }
    }
    final todayUnit = scale.unitStart(today);
    final primary = theme.colorScheme.primary;
    return SizedBox(
      width: tl.width,
      height: _headRowH * 2,
      child: Column(
        children: [
          Row(
            children: [
              for (final (label, n) in groups)
                Container(
                  width: n * tl.unitW,
                  height: _headRowH,
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.only(left: 8),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: line),
                      bottom: BorderSide(color: line),
                    ),
                  ),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    softWrap: false,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          Row(
            children: [
              for (final u in tl.units)
                Builder(
                  builder: (context) {
                    final isToday = u == todayUnit;
                    final weekend =
                        scale.kind == GanttScale.day &&
                        (u.weekday == DateTime.saturday ||
                            u.weekday == DateTime.sunday);
                    return Container(
                      width: tl.unitW,
                      height: _headRowH,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isToday ? primary.withValues(alpha: 0.08) : null,
                        border: Border(left: BorderSide(color: line)),
                      ),
                      child: Text(
                        scale.unitLabel(u),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.clip,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: isToday ? FontWeight.w700 : null,
                          color: isToday
                              ? primary
                              : weekend
                              ? (u.weekday == DateTime.sunday
                                    ? Colors.redAccent
                                    : Colors.blueAccent)
                              : theme.hintColor,
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 업무 막대 — 가운데(손 모양)를 끌면 통째로 옮기고, 양 끝(좌우 화살표)을 끌면 시작일·
  /// 마감일을 늘리거나 줄인다. 양 끝 손잡이는 막대 밖으로 조금 나와 있어서 짧은 막대도 잡힌다.
  List<Widget> _taskBar(Task t, _Timeline tl, Color color) {
    final dragging = _dragId == t.id;
    final (s, e) = dragging ? _dragPreview(t, tl) : _rangeOf(t)!;
    final left = tl.x(s);
    final width = math.max(
      6.0,
      tl.x(DateTime(e.year, e.month, e.day + 1)) - left,
    );
    const barH = 18.0;
    const top = (_rowH - barH) / 2;
    const handleW = 8.0;

    void start(String mode) => setState(() {
      _dragId = t.id;
      _dragMode = mode;
      _dragDx = 0;
    });
    void update(DragUpdateDetails d) => setState(() => _dragDx += d.delta.dx);
    Future<void> end() async {
      final (ns, ne) = _dragPreview(t, tl);
      final (os, oe) = _rangeOf(t)!;
      final mode = _dragMode;
      final changed = ns != os || ne != oe;
      // 묻는 동안에도 막대는 놓은 자리에 둔다(취소하면 되돌린다).
      setState(() {
        _dragId = null;
        if (changed) _pending[t.id] = (ns, ne);
      });
      if (!changed) return;
      final ok = await _confirmSchedule(t, (os, oe), (ns, ne), mode);
      if (!mounted) return;
      if (ok) {
        _save(t, ns, ne);
      } else {
        setState(() => _pending.remove(t.id));
      }
    }

    Widget handle(String mode) => MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => start(mode),
        onHorizontalDragUpdate: update,
        onHorizontalDragEnd: (_) => end(),
        onHorizontalDragCancel: () => setState(() => _dragId = null),
      ),
    );

    final body = Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: dragging ? 0.4 : 0.25),
        border: Border.all(color: color.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(4),
      ),
    );
    // 막대가 넉넉하면 손잡이를 양 끝에 반쯤 걸치고, 짧으면 막대 바깥에 붙인다(가운데를
    // 잡을 자리를 남기려고).
    final inset = width >= 20 ? handleW / 2 : 0.0;
    return [
      Positioned(
        left: left,
        top: top,
        width: width,
        height: barH,
        child: Tooltip(
          message: '${t.title}\n${formatYmd(s)} ~ ${formatYmd(e)}',
          waitDuration: const Duration(milliseconds: 400),
          child: widget.readOnly
              ? MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => widget.onOpen(t),
                    child: body,
                  ),
                )
              : MouseRegion(
                  cursor: dragging || _pressedId == t.id
                      ? GrabCursors.closed
                      : GrabCursors.open,
                  // 누르는 순간 쥔 손, 떼면 다시 펼친 손.
                  child: Listener(
                    onPointerDown: (_) => setState(() => _pressedId = t.id),
                    onPointerUp: (_) => setState(() => _pressedId = null),
                    onPointerCancel: (_) => setState(() => _pressedId = null),
                    child: GestureDetector(
                      onTap: () => widget.onOpen(t),
                      onHorizontalDragStart: (_) => start('move'),
                      onHorizontalDragUpdate: update,
                      onHorizontalDragEnd: (_) => end(),
                      onHorizontalDragCancel: () =>
                          setState(() => _dragId = null),
                      child: body,
                    ),
                  ),
                ),
        ),
      ),
      if (!widget.readOnly) ...[
        Positioned(
          left: left - handleW + inset,
          top: top,
          width: handleW,
          height: barH,
          child: handle('start'),
        ),
        Positioned(
          left: left + width - inset,
          top: top,
          width: handleW,
          height: barH,
          child: handle('end'),
        ),
      ],
    ];
  }

  /// 칸 경계 세로선.
  Widget _grid(_Timeline tl, Color line) =>
      CustomPaint(painter: _GridPainter(tl.units.length, tl.unitW, line));

  /// 묶음 하나 — 머리줄(접기·색·이름·개수 / 묶음 전체 기간 막대)과 업무 줄들.
  Widget _group(
    ThemeData theme,
    _Timeline tl,
    Color line,
    _GroupDef g,
    List<({Task task, bool indented})> rows,
  ) {
    final collapsed = _p.collapsed.contains(g.id);
    DateTime? lo, hi;
    for (final r in rows) {
      final range = _rangeOf(r.task);
      if (range == null) continue;
      if (lo == null || range.$1.isBefore(lo)) lo = range.$1;
      if (hi == null || range.$2.isAfter(hi)) hi = range.$2;
    }
    final today = DateTime.now();
    final todayX = tl.x(today) + tl.pxPerDay(today) / 2;

    final head = ColoredBox(
      color: theme.colorScheme.surfaceContainerLow,
      child: Row(
        children: [
          SizedBox(
            width: _leftW,
            height: _groupH,
            child: InkWell(
              onTap: () => setState(
                () => collapsed
                    ? _p.collapsed.remove(g.id)
                    : _p.collapsed.add(g.id),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Icon(
                    collapsed ? Icons.chevron_right : Icons.expand_more,
                    size: 18,
                    color: theme.hintColor,
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: g.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      g.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.only(left: 6, right: 12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${rows.length}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          VerticalDivider(width: 1, color: line),
          Expanded(
            child: SizedBox(
              height: _groupH,
              child: _Window(
                controller: _hScroll,
                child: SizedBox(
                  width: tl.width,
                  height: _groupH,
                  child: Stack(
                    children: [
                      Positioned.fill(child: _grid(tl, line)),
                      if (lo != null && hi != null)
                        Positioned(
                          left: tl.x(lo),
                          width: math.max(
                            6,
                            tl.x(DateTime(hi.year, hi.month, hi.day + 1)) -
                                tl.x(lo),
                          ),
                          top: (_groupH - 7) / 2,
                          height: 7,
                          child: Container(
                            decoration: BoxDecoration(
                              color: g.color,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    Widget taskRow(({Task task, bool indented}) r) {
      final t = r.task;
      final range = _rangeOf(t);
      return SizedBox(
        height: _rowH,
        child: Row(
          children: [
            SizedBox(
              width: _leftW,
              child: InkWell(
                onTap: () => widget.onOpen(t),
                child: Padding(
                  padding: EdgeInsets.only(
                    left: r.indented ? 52 : 36,
                    right: 12,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      r.indented ? '↳ ${t.title}' : t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        decoration: t.status == TaskStatus.done
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            VerticalDivider(width: 1, color: line),
            Expanded(
              child: _Window(
                controller: _hScroll,
                child: SizedBox(
                  width: tl.width,
                  height: _rowH,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(child: _grid(tl, line)),
                      if (range != null)
                        ..._taskBar(t, tl, taskDisplayColor(t)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          head,
          if (!collapsed && rows.isNotEmpty)
            Stack(
              children: [
                Column(
                  children: [
                    for (final r in rows) ...[
                      Divider(height: 1, color: line),
                      taskRow(r),
                    ],
                  ],
                ),
                // 오늘 세로선 — 업무 줄들 위로, 맨 위에 빨간 점.
                Positioned(
                  left: _leftW + 1,
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: _Window(
                      controller: _hScroll,
                      child: SizedBox(
                        width: tl.width,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned(
                              left: todayX - 1,
                              top: 0,
                              bottom: 0,
                              width: 2,
                              child: const ColoredBox(color: Colors.redAccent),
                            ),
                            Positioned(
                              left: todayX - 4.5,
                              top: -1,
                              width: 9,
                              height: 9,
                              child: const DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.redAccent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = theme.brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.12)
        : const Color(0xFFE5E7EB);
    final defs = _groupDefs();
    final selected = _byStatus
        ? {for (final g in defs) g.id}
        : (_p.selected ?? {for (final g in defs) g.id});

    // 보여줄 업무 — 고른 묶음 + (내 업무만이면) 내가 담당·참조인 것(서버가 준 myRole).
    final byGroup = <String, List<Task>>{};
    for (final t in widget.tasks) {
      final g = _groupOf(t);
      if (!selected.contains(g)) continue;
      if (_p.mineOnly && t.myRole == null) continue;
      (byGroup[g] ??= []).add(t);
    }
    final visible = [for (final list in byGroup.values) ...list];
    int compareByStart(Task a, Task b) {
      final ra = _rangeOf(a), rb = _rangeOf(b);
      if (ra == null && rb == null) return a.title.compareTo(b.title);
      if (ra == null) return 1;
      if (rb == null) return -1;
      return ra.$1.compareTo(rb.$1);
    }

    final toolbar = Row(
      children: [
        _segmented(theme),
        const SizedBox(width: 16),
        _TodayButton(
          onPressed: () => setState(() {
            _p.offset = null;
            _placed = false;
          }),
        ),
        const SizedBox(width: 16),
        _zoomControls(theme),
        const Spacer(),
        _mineToggle(theme),
        if (!_byStatus) ...[
          const SizedBox(width: 12),
          _ProjectPicker(
            projects: defs,
            selected: selected,
            onChanged: (next) => setState(() => _p.selected = next),
          ),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          toolbar,
          const SizedBox(height: 16),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final viewW = constraints.maxWidth - _leftW - 1 - 12;
                final now = DateTime.now();
                var lo = DateTime(now.year, now.month, now.day);
                var hi = lo;
                for (final t in visible) {
                  final r = _rangeOf(t);
                  if (r == null) continue;
                  if (r.$1.isBefore(lo)) lo = r.$1;
                  if (r.$2.isAfter(hi)) hi = r.$2;
                }
                final scale = _Scale(_p.scale);
                final tl = _Timeline.build(
                  scale: scale,
                  unitW: scale.baseUnitW * _p.zoom,
                  lo: lo,
                  hi: hi,
                  minWidth: viewW,
                );
                if (!_placed) {
                  _placed = true;
                  final remembered = _p.offset;
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => remembered != null
                        ? _scrollTo(remembered)
                        : _scrollToToday(tl, viewW),
                  );
                }
                final groups = [
                  for (final g in defs)
                    if (byGroup[g.id]?.isNotEmpty ?? false)
                      (
                        g,
                        arrangeWithSubtasks(
                          [...byGroup[g.id]!]..sort(compareByStart),
                        ),
                      ),
                ];

                final header = Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: line),
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(10),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Row(
                    children: [
                      Container(
                        width: _leftW,
                        height: _headRowH * 2,
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.only(left: 16),
                        child: Text(
                          _byStatus ? '상태 / 업무' : '프로젝트 / 업무',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.hintColor,
                          ),
                        ),
                      ),
                      VerticalDivider(width: 1, color: line),
                      Expanded(
                        child: SizedBox(
                          height: _headRowH * 2,
                          child: _Window(
                            controller: _hScroll,
                            child: _timelineHeader(theme, tl, line),
                          ),
                        ),
                      ),
                    ],
                  ),
                );

                // 타임라인 위에서 Shift+휠 또는 가로 휠로 좌우 이동.
                final body = Listener(
                  onPointerSignal: (event) {
                    if (event is! PointerScrollEvent) return;
                    final shift = HardwareKeyboard.instance.isShiftPressed;
                    final dx = event.scrollDelta.dx != 0
                        ? event.scrollDelta.dx
                        : (shift ? event.scrollDelta.dy : 0.0);
                    if (dx == 0) return;
                    GestureBinding.instance.pointerSignalResolver.register(
                      event,
                      (_) => _scrollBy(dx),
                    );
                  },
                  child: MutedScrollbar(
                    controller: _vScroll,
                    child: ListView(
                      controller: _vScroll,
                      padding: const EdgeInsets.only(top: 14, right: 12),
                      children: [
                        if (groups.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 40),
                            child: Center(
                              child: Text(
                                '표시할 업무가 없습니다.',
                                style: TextStyle(color: theme.hintColor),
                              ),
                            ),
                          ),
                        for (final (g, rows) in groups)
                          _group(theme, tl, line, g, rows),
                      ],
                    ),
                  ),
                );

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: header,
                    ),
                    Expanded(child: body),
                    // 가로 스크롤 줄 — 타임라인 구간 아래에만.
                    Padding(
                      padding: const EdgeInsets.only(
                        left: _leftW + 1,
                        right: 12,
                      ),
                      child: MutedScrollbar(
                        controller: _hScroll,
                        child: SingleChildScrollView(
                          controller: _hScroll,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(width: tl.width, height: 14),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// "N개 프로젝트 선택됨 ⌄" — 누르면 아래에 검색칸(프로젝트 이름/키)과 체크 목록이 뜬다.
/// 목록 안에 입력칸·스크롤 목록이 있어서 MenuAnchor 대신 오버레이로 띄운다(MenuAnchor는
/// 안쪽 크기를 미리 재려다 스크롤 목록에서 멈춘다).
class _ProjectPicker extends StatefulWidget {
  final List<_GroupDef> projects;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;
  const _ProjectPicker({
    required this.projects,
    required this.selected,
    required this.onChanged,
  });

  @override
  State<_ProjectPicker> createState() => _ProjectPickerState();
}

class _ProjectPickerState extends State<_ProjectPicker> {
  final _overlay = OverlayPortalController();
  final _link = LayerLink();
  final _tapGroup = Object();
  final _search = TextEditingController();
  final _listScroll = ScrollController();

  @override
  void dispose() {
    _search.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_overlay.isShowing) {
      _overlay.hide();
    } else {
      _search.clear();
      _overlay.show();
    }
    setState(() {});
  }

  void _close() {
    _overlay.hide();
    setState(() {});
  }

  Widget _panel(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final q = _search.text.trim().toLowerCase();
    final shown = [
      for (final p in widget.projects)
        if (q.isEmpty ||
            p.name.toLowerCase().contains(q) ||
            p.key.toLowerCase().contains(q))
          p,
    ];
    final allOn = widget.projects.every((p) => widget.selected.contains(p.id));
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(14),
      color: theme.colorScheme.surface,
      child: SizedBox(
        width: 290,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Container(
                  padding: const EdgeInsets.only(left: 10, right: 2),
                  decoration: BoxDecoration(
                    border: Border.all(color: primary.withValues(alpha: 0.6)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.search, size: 18, color: theme.hintColor),
                      const SizedBox(width: 6),
                      Expanded(
                        child: TextField(
                          controller: _search,
                          autofocus: true,
                          style: const TextStyle(fontSize: 13),
                          decoration: const InputDecoration(
                            hintText: '프로젝트 이름/프로젝트 키',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          onChanged: (_) =>
                              _overlay.isShowing ? setState(() {}) : null,
                        ),
                      ),
                      TextButton(
                        onPressed: () => widget.onChanged(
                          allOn
                              ? <String>{}
                              : {for (final p in widget.projects) p.id},
                        ),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          textStyle: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        child: Text(allOn ? '전체 해제' : '전체 선택'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: shown.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          '일치하는 프로젝트가 없습니다.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.hintColor,
                          ),
                        ),
                      )
                    : MutedScrollbar(
                        controller: _listScroll,
                        child: ListView(
                          controller: _listScroll,
                          shrinkWrap: true,
                          padding: const EdgeInsets.only(right: 12),
                          children: [
                            for (final p in shown)
                              _item(theme, p, widget.selected.contains(p.id)),
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

  Widget _item(ThemeData theme, _GroupDef p, bool on) {
    void flip() {
      final next = {...widget.selected};
      on ? next.remove(p.id) : next.add(p.id);
      widget.onChanged(next);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: on
            ? theme.colorScheme.primary.withValues(alpha: 0.06)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: flip,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              children: [
                Checkbox(
                  value: on,
                  onChanged: (_) => flip(),
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: p.color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = widget.projects
        .where((p) => widget.selected.contains(p.id))
        .length;
    final open = _overlay.isShowing;
    return OverlayPortal(
      controller: _overlay,
      overlayChildBuilder: (context) => CompositedTransformFollower(
        link: _link,
        targetAnchor: Alignment.bottomRight,
        followerAnchor: Alignment.topRight,
        offset: const Offset(0, 6),
        child: Align(
          alignment: Alignment.topRight,
          child: TapRegion(
            groupId: _tapGroup,
            onTapOutside: (_) => _close(),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): _close,
              },
              child: StatefulBuilder(builder: (context, _) => _panel(context)),
            ),
          ),
        ),
      ),
      child: CompositedTransformTarget(
        link: _link,
        child: TapRegion(
          groupId: _tapGroup,
          child: OutlinedButton(
            onPressed: _toggle,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              side: BorderSide(
                color: theme.colorScheme.primary.withValues(alpha: 0.5),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$count개 프로젝트 선택됨',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  open ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                  size: 18,
                  color: theme.hintColor,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TodayButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _TodayButton({required this.onPressed});

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      side: BorderSide(color: Theme.of(context).dividerColor),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    child: const Text('오늘'),
  );
}

/// 타임라인 조각 — 전체 타임라인을 가로 스크롤 위치만큼 왼쪽으로 밀어 그리고, 보이는 칸 밖은
/// 잘라낸다. 머리글·프로젝트 줄·업무 줄이 모두 같은 컨트롤러를 따라 함께 움직인다.
class _Window extends StatelessWidget {
  final ScrollController controller;
  final Widget child;
  const _Window({required this.controller, required this.child});

  @override
  Widget build(BuildContext context) => UnconstrainedBox(
    constrainedAxis: Axis.vertical,
    alignment: Alignment.centerLeft,
    clipBehavior: Clip.hardEdge,
    child: ListenableBuilder(
      listenable: controller,
      builder: (context, child) => Transform.translate(
        offset: Offset(controller.hasClients ? -controller.offset : 0, 0),
        child: child,
      ),
      child: child,
    ),
  );
}

class _GridPainter extends CustomPainter {
  final int count;
  final double unitW;
  final Color color;
  _GridPainter(this.count, this.unitW, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var i = 0; i <= count; i++) {
      final x = i * unitW + 0.5;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.count != count || old.unitW != unitW || old.color != color;
}
