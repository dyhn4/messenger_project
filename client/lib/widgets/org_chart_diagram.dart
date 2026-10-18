import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/tr.dart';
import '../models/org_tree.dart';
import 'avatar_utils.dart';

/// 조직도 그림(가로 트리) — 부서 상자를 왼쪽(맨 위 부서)에서 오른쪽(하위 부서)으로 선으로 잇는다.
///
/// - 자리: 맨 위 부서들은 왼쪽에 위에서 아래로 쌓고, 하위 부서는 오른쪽 한 칸에 놓는다. 위 부서 상자는 제 하위 부서들(첫째~막내)의
///   가운데 높이에 온다(가로로 누운 tidy tree). 자리는 여기서 직접 셈한다 — 끝 부서 높이 = 상자 높이, 위 부서 높이 = 하위 부서들 높이의 합.
/// - 선: 위 부서 오른쪽 가운데 → 가운데 세로줄 → 하위 부서 왼쪽 가운데(꺾은선 — [_ConnectorPainter]).
/// - 부서 없는 사람이 있으면 맨 아래에 "부서 없음" 상자를 하나 더 둔다(끌어 옮길 수 없다).
/// - 전체를 [InteractiveViewer]에 넣어 끌어서 움직이고 두 손가락(휠)으로 키우고 줄인다 — 좁은 휴대폰에서도 넘치지 않는다. 오른쪽 아래
///   단추로 확대·축소·화면에 맞춤.
/// - [OrgChartDiagram.onMoveDepartment]가 있으면 부서 상자를 길게 눌러 다른 부서 상자에 놓아 그 아래로 옮긴다(자기 자신·자기 하위
///   부서·이미 위 부서인 곳에는 놓을 수 없다). 끄는 동안 위쪽에 "맨 위로" 띠가 나온다. 옮기는 동안은 돌림표를 덮어 둔다 — 실패 알림은
///   부르는 쪽(토스트)이 한다.
class OrgChartDiagram extends StatefulWidget {
  final OrgTree tree;

  /// 부서 상자를 눌렀을 때(목록 보기에서 그 부서로 가기 등).
  final void Function(OrgDepartment department)? onTapDepartment;

  /// 부서장 얼굴 등 사람을 눌렀을 때(프로필 카드).
  final void Function(OrgMember member)? onTapMember;

  /// 고칠 수 있으면 부서 상자를 끌어다 다른 부서 상자(또는 빈 곳 — 맨 위로)에 놓아 옮긴다. [newParentId]가 null이면 맨 위로.
  final Future<void> Function(OrgDepartment department, String? newParentId)?
  onMoveDepartment;

  /// 사진 얼굴의 상대 경로(서버의 서명 링크)를 받을 주소로 — 세션의 resolveUrl. 없으면 사진은 이니셜로.
  final String Function(String relative)? resolveUrl;

  const OrgChartDiagram({
    super.key,
    required this.tree,
    this.onTapDepartment,
    this.onTapMember,
    this.onMoveDepartment,
    this.resolveUrl,
  });

  @override
  State<OrgChartDiagram> createState() => _OrgChartDiagramState();
}

// ── 크기(논리 픽셀) ───────────────────────────────────────────────────────
const double _cardW = 200;
const double _cardH = 76;

/// 위 부서와 하위 부서 사이(꺾은선이 지나는 길).
const double _hGap = 48;

/// 형제 부서 사이.
const double _vGap = 14;

/// 맨 위 부서 묶음 사이 — 형제보다 조금 더 띄워 덩어리가 나뉘어 보이게.
const double _rootGap = _vGap * 2;

/// 그림 가장자리 여백.
const double _pad = 24;

const double _minScale = 0.3;
const double _maxScale = 2.5;

/// 단추 한 번에 키우고 줄이는 배율.
const double _zoomStep = 1.25;

/// 부서 없음 상자에 보일 얼굴 수(넘치면 자른다).
const int _unassignedFaces = 5;

/// 셈해 둔 자리 — 부서 id → 상자 자리, 위→아래 부서 이음, 부서 없음 상자 자리, 그림 전체 크기.
class _ChartLayout {
  final Map<String, Rect> rects;
  final Map<String, int> depths;
  final List<(String parentId, String childId)> edges;
  final Rect? unassigned;
  final Size size;
  const _ChartLayout({
    required this.rects,
    required this.depths,
    required this.edges,
    required this.unassigned,
    required this.size,
  });

  /// [tree]의 부서 자리를 셈한다. 부모가 서로 물려(고리) 맨 위에서 닿지 않는 부서도 빠뜨리지 않게 맨 위 부서로 덧붙인다.
  factory _ChartLayout.of(OrgTree tree) {
    final rects = <String, Rect>{};
    final depths = <String, int>{};
    final edges = <(String, String)>[];
    final seen = <String>{};

    // [d]와 그 아래를 [top]부터 놓고 차지한 높이를 돌려준다.
    double place(OrgDepartment d, int depth, double top) {
      seen.add(d.id);
      depths[d.id] = depth;
      final x = _pad + depth * (_cardW + _hGap);
      final placed = <String>[];
      var cur = top;
      for (final c in tree.childrenOf(d.id)) {
        if (seen.contains(c.id)) continue;
        final h = place(c, depth + 1, cur);
        edges.add((d.id, c.id));
        placed.add(c.id);
        cur += h + _vGap;
      }
      if (placed.isEmpty) {
        rects[d.id] = Rect.fromLTWH(x, top, _cardW, _cardH);
        return _cardH;
      }
      // 첫째와 막내 하위 부서 상자의 가운데 — 위 부서는 그 사이 한가운데.
      final cy =
          (rects[placed.first]!.center.dy + rects[placed.last]!.center.dy) / 2;
      rects[d.id] = Rect.fromLTWH(x, cy - _cardH / 2, _cardW, _cardH);
      return cur - _vGap - top;
    }

    var cur = _pad;
    final roots = [
      ...tree.childrenOf(null),
      // 고리에 걸려 맨 위에서 닿지 않는 부서(서버가 막지만 혹시 몰라).
      ...tree.departments,
    ];
    for (final r in roots) {
      if (seen.contains(r.id)) continue;
      cur += place(r, 0, cur) + _rootGap;
    }
    Rect? unassigned;
    if (tree.membersOf(null).isNotEmpty) {
      unassigned = Rect.fromLTWH(_pad, cur, _cardW, _cardH);
      cur += _cardH + _rootGap;
    }
    var right = _pad + _cardW;
    for (final r in rects.values) {
      right = math.max(right, r.right);
    }
    return _ChartLayout(
      rects: rects,
      depths: depths,
      edges: edges,
      unassigned: unassigned,
      // 마지막에 더한 사이 간격을 빼고 아래 여백을 더한다.
      size: Size(right + _pad, cur - _rootGap + _pad),
    );
  }
}

class _OrgChartDiagramState extends State<OrgChartDiagram> {
  final _controller = TransformationController();

  /// 셈해 둔 자리와 그때의 조직도 — 같은 조직도면 다시 셈하지 않는다.
  _ChartLayout? _layout;
  OrgTree? _layoutTree;

  /// 보이는 칸 크기(맞춤·확대 기준점).
  Size? _viewport;

  /// 끌고 있는 부서(맨 위로 띠를 보일지).
  OrgDepartment? _dragging;

  /// 옮기는 중(돌림표).
  bool _busy = false;

  OrgTree get _tree => widget.tree;
  bool get _canMove => widget.onMoveDepartment != null;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  _ChartLayout get _chart {
    if (_layout == null || !identical(_layoutTree, _tree)) {
      _layout = _ChartLayout.of(_tree);
      _layoutTree = _tree;
    }
    return _layout!;
  }

  // ── 확대·축소·맞춤 ───────────────────────────────────────────────────────

  /// 보이는 칸 가운데를 기준으로 [factor]배(최소·최대 배율 안에서).
  void _zoom(double factor) {
    final vp = _viewport ?? Size.zero;
    final current = _controller.value.getMaxScaleOnAxis();
    final target = (current * factor).clamp(_minScale, _maxScale);
    final f = target / current;
    if ((f - 1).abs() < 1e-6) return;
    final c = vp.center(Offset.zero);
    // z축도 같이 — InteractiveViewer는 세 축을 함께 키우고 배율을 getMaxScaleOnAxis(세 축 중 가장 큰 값)로 읽는다.
    _controller.value = Matrix4.translationValues(c.dx, c.dy, 0)
      ..multiply(Matrix4.diagonal3Values(f, f, f))
      ..multiply(Matrix4.translationValues(-c.dx, -c.dy, 0))
      ..multiply(_controller.value);
  }

  /// 그림 전체가 보이게 줄이고(키우지는 않는다 — 1배까지) 가운데로. 최소 배율로도 넘치면 왼쪽 위에 붙인다.
  void _fit() {
    final vp = _viewport;
    if (vp == null || vp.isEmpty) return;
    final size = _chart.size;
    final s = math
        .min(vp.width / size.width, vp.height / size.height)
        .clamp(_minScale, 1.0);
    final dx = math.max(0.0, (vp.width - size.width * s) / 2);
    final dy = math.max(0.0, (vp.height - size.height * s) / 2);
    _controller.value = Matrix4.diagonal3Values(s, s, s)
      ..setTranslationRaw(dx, dy, 0);
  }

  // ── 옮기기 ──────────────────────────────────────────────────────────────

  /// [candidate]를 [target] 아래로 놓을 수 있는지 — 자기 자신, 자기 하위 부서(고리가 된다), 이미 위 부서인 곳은 안 된다.
  bool _canDropOn(OrgDepartment candidate, OrgDepartment target) =>
      candidate.id != target.id &&
      candidate.parentId != target.id &&
      !_tree.descendantsOf(candidate.id).contains(target.id);

  /// 지금 위 부서가 있는지(없는 부서를 가리키는 고아는 이미 맨 위에 그려진다).
  bool _hasParent(OrgDepartment d) => _tree.department(d.parentId) != null;

  Future<void> _move(OrgDepartment d, String? newParentId) async {
    final move = widget.onMoveDepartment;
    if (move == null || _busy) return;
    setState(() {
      _busy = true;
      _dragging = null;
    });
    try {
      await move(d, newParentId);
    } catch (e) {
      // 알림은 부르는 쪽이 한다 — 여기서는 그림이 깨지지 않게만.
      debugPrint('org chart move failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setDragging(OrgDepartment? d) {
    if (!mounted || identical(_dragging, d)) return;
    setState(() => _dragging = d);
  }

  // ── 그리기 ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_tree.departments.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            tr('아직 부서가 없습니다.'),
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.hintColor, fontSize: 13),
          ),
        ),
      );
    }
    final chart = _chart;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 높이·너비가 열려 있는 곳(Column 안 등)에 놓여도 그릴 수 있게 알맞은 크기로 막는다.
        final vp = Size(
          constraints.hasBoundedWidth
              ? constraints.maxWidth
              : math.min(chart.size.width, 800),
          constraints.hasBoundedHeight
              ? constraints.maxHeight
              : math.min(chart.size.height, 480),
        );
        _viewport = vp;
        final dragging = _dragging;
        return SizedBox(
          width: vp.width,
          height: vp.height,
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  transformationController: _controller,
                  constrained: false,
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  minScale: _minScale,
                  maxScale: _maxScale,
                  // 글씨를 아주 크게 키운 기기에서도 상자(높이 고정)가 넘치지 않게 조금만 따른다.
                  child: MediaQuery.withClampedTextScaling(
                    maxScaleFactor: 1.15,
                    child: _canvas(context, chart),
                  ),
                ),
              ),
              if (dragging != null && _hasParent(dragging))
                Positioned(
                  top: 8,
                  left: 16,
                  right: 16,
                  child: _rootDropStrip(context),
                ),
              Positioned(right: 12, bottom: 12, child: _zoomButtons(context)),
              if (_busy)
                Positioned.fill(
                  child: AbsorbPointer(
                    child: ColoredBox(
                      color: theme.colorScheme.surface.withValues(alpha: 0.4),
                      child: const Center(child: CircularProgressIndicator()),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 선과 상자를 셈한 자리에 놓은 그림 한 장.
  Widget _canvas(BuildContext context, _ChartLayout chart) {
    final cs = Theme.of(context).colorScheme;
    final segments = [
      for (final (p, c) in chart.edges)
        if (chart.rects[p] != null && chart.rects[c] != null)
          (chart.rects[p]!, chart.rects[c]!),
    ];
    final unassigned = chart.unassigned;
    return SizedBox(
      width: chart.size.width,
      height: chart.size.height,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _ConnectorPainter(
                segments: segments,
                color: cs.outline.withValues(alpha: 0.6),
              ),
            ),
          ),
          for (final d in _tree.departments)
            if (chart.rects[d.id] case final rect?)
              Positioned.fromRect(
                rect: rect,
                child: _departmentNode(context, d, chart.depths[d.id] ?? 0),
              ),
          if (unassigned != null)
            Positioned.fromRect(
              rect: unassigned,
              child: _unassignedCard(context),
            ),
        ],
      ),
    );
  }

  /// 부서 상자 — 옮길 수 있으면 길게 눌러 끄는 것([LongPressDraggable])과 놓을 곳([DragTarget])을 함께 씌운다.
  Widget _departmentNode(BuildContext context, OrgDepartment d, int depth) {
    if (!_canMove) {
      return _departmentCard(context, d, depth, key: _cardKey(d));
    }
    return LongPressDraggable<OrgDepartment>(
      data: d,
      maxSimultaneousDrags: _busy ? 0 : 1,
      onDragStarted: () => _setDragging(d),
      onDragEnd: (_) => _setDragging(null),
      onDraggableCanceled: (_, _) => _setDragging(null),
      // 끄는 동안 손가락을 따라오는 반투명 상자(확대 배율과 상관없이 원래 크기).
      feedback: Material(
        type: MaterialType.transparency,
        child: Opacity(
          opacity: 0.8,
          child: SizedBox(
            width: _cardW,
            height: _cardH,
            child: _departmentCard(context, d, depth, elevated: true),
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.35,
        child: _departmentCard(context, d, depth, key: _cardKey(d)),
      ),
      child: DragTarget<OrgDepartment>(
        onWillAcceptWithDetails: (details) => _canDropOn(details.data, d),
        onAcceptWithDetails: (details) => _move(details.data, d.id),
        builder: (context, candidates, rejected) => _departmentCard(
          context,
          d,
          depth,
          key: _cardKey(d),
          hovering: candidates.isNotEmpty,
        ),
      ),
    );
  }

  Key _cardKey(OrgDepartment d) => ValueKey('org-chart-dept-${d.id}');

  /// 깊이마다 왼쪽 띠 색을 바꿔 층이 눈에 들어오게(밝은·어두운 테마 모두 테마 색에서).
  Color _accent(ColorScheme cs, int depth) =>
      [cs.primary, cs.tertiary, cs.secondary][depth % 3];

  Widget _departmentCard(
    BuildContext context,
    OrgDepartment d,
    int depth, {
    Key? key,
    bool hovering = false,
    bool elevated = false,
  }) {
    final head = _tree.member(d.headId);
    final hint = Theme.of(context).hintColor;
    return _CardFrame(
      key: key,
      accent: _accent(Theme.of(context).colorScheme, depth),
      hovering: hovering,
      elevated: elevated,
      onTap: widget.onTapDepartment == null
          ? null
          : () => widget.onTapDepartment!(d),
      title: d.name,
      count: _tree.headcount(d.id),
      bottom: head == null
          ? Text(
              tr('부서장 없음'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: hint),
            )
          : _headRow(context, head),
    );
  }

  /// 부서장 줄 — 얼굴·이름·직책. 누르면 그 사람(프로필 카드).
  Widget _headRow(BuildContext context, OrgMember head) {
    final hint = Theme.of(context).hintColor;
    final position = head.position;
    final row = Row(
      children: [
        _avatar(head, 11),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            head.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
        ),
        if (position != null && position.isNotEmpty) ...[
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              position,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: hint),
            ),
          ),
        ],
      ],
    );
    final onTap = widget.onTapMember;
    if (onTap == null) return row;
    return InkWell(
      key: ValueKey('org-chart-head-${head.id}'),
      borderRadius: BorderRadius.circular(6),
      onTap: () => onTap(head),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: row,
      ),
    );
  }

  /// 부서 없음 상자 — 끌 수도, 놓을 수도 없다. 아래 줄은 그 사람들 얼굴 몇 개.
  Widget _unassignedCard(BuildContext context) {
    final people = _tree.membersOf(null);
    final onTap = widget.onTapMember;
    return _CardFrame(
      key: const ValueKey('org-chart-unassigned'),
      accent: Theme.of(context).hintColor,
      title: tr('부서 없음'),
      muted: true,
      count: people.length,
      bottom: Row(
        children: [
          for (final m in people.take(_unassignedFaces))
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: onTap == null
                  ? Tooltip(message: m.name, child: _avatar(m, 11))
                  : InkWell(
                      key: ValueKey('org-chart-unassigned-${m.id}'),
                      customBorder: const CircleBorder(),
                      onTap: () => onTap(m),
                      child: Tooltip(message: m.name, child: _avatar(m, 11)),
                    ),
            ),
        ],
      ),
    );
  }

  /// 사람 얼굴 — 공용 [AvatarView]. 사진 주소가 상대 경로(앱 서버의 서명 링크)면 [OrgChartDiagram.resolveUrl]로 서버 주소를 붙이고, 그것이
  /// 없으면 이니셜로 대신 그린다(깨진 그림·네트워크 오류 대신).
  Widget _avatar(OrgMember m, double radius) {
    final url = m.avatarUrl;
    final resolve = widget.resolveUrl;
    final absolute =
        url != null &&
        (url.startsWith('http://') ||
            url.startsWith('https://') ||
            url.startsWith('data:'));
    final photoOk = url != null && (absolute || resolve != null);
    return AvatarView(
      username: m.name,
      avatarType: m.avatarType == 'photo' && !photoOk
          ? 'initial'
          : m.avatarType,
      avatarEmoji: m.avatarEmoji,
      avatarColor: m.avatarColor,
      avatarUrl: url,
      resolveUrl: absolute ? null : resolve,
      radius: radius,
    );
  }

  /// 끄는 동안 위쪽에 나오는 "맨 위로" 띠 — 여기에 놓으면 위 부서 없이 맨 위 부서가 된다.
  Widget _rootDropStrip(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DragTarget<OrgDepartment>(
      onWillAcceptWithDetails: (details) => _hasParent(details.data),
      onAcceptWithDetails: (details) => _move(details.data, null),
      builder: (context, candidates, rejected) {
        final hovering = candidates.isNotEmpty;
        return AnimatedContainer(
          key: const ValueKey('org-chart-drop-root'),
          duration: const Duration(milliseconds: 120),
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: hovering
                ? cs.primaryContainer
                : cs.surfaceContainerHighest.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: hovering ? cs.primary : cs.outlineVariant,
              width: hovering ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.vertical_align_top,
                size: 18,
                color: hovering ? cs.onPrimaryContainer : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  tr('여기에 놓으면 맨 위 부서가 됩니다'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: hovering
                        ? cs.onPrimaryContainer
                        : cs.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 오른쪽 아래 확대·축소·맞춤 단추.
  Widget _zoomButtons(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget button(String key, IconData icon, String tooltip, VoidCallback on) =>
        IconButton(
          key: ValueKey(key),
          tooltip: tooltip,
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          icon: Icon(icon),
          onPressed: on,
        );
    return Material(
      color: cs.surfaceContainerHigh,
      elevation: 2,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          button('org-chart-zoom-in', Icons.add, tr('확대'), () {
            _zoom(_zoomStep);
          }),
          button('org-chart-zoom-out', Icons.remove, tr('축소'), () {
            _zoom(1 / _zoomStep);
          }),
          button(
            'org-chart-fit',
            Icons.fit_screen_outlined,
            tr('화면에 맞춤'),
            _fit,
          ),
        ],
      ),
    );
  }
}

/// 상자 모양(부서·부서 없음 공통) — 왼쪽 색 띠, 이름(굵게)과 사람 수 배지, 아래 한 줄.
class _CardFrame extends StatelessWidget {
  final Color accent;
  final String title;
  final int count;
  final Widget bottom;
  final VoidCallback? onTap;

  /// 다른 부서가 이 위에 떠 있다(놓을 수 있음).
  final bool hovering;

  /// 끄는 중 손가락을 따라오는 상자(그림자 더).
  final bool elevated;

  /// 부서 없음처럼 흐리게.
  final bool muted;

  const _CardFrame({
    super.key,
    required this.accent,
    required this.title,
    required this.count,
    required this.bottom,
    this.onTap,
    this.hovering = false,
    this.elevated = false,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final radius = BorderRadius.circular(10);
    final background = hovering
        ? Color.alphaBlend(
            cs.primary.withValues(alpha: 0.12),
            cs.surfaceContainerLow,
          )
        : muted
        ? cs.surfaceContainerLowest
        : cs.surfaceContainerLow;
    return Material(
      color: background,
      elevation: elevated ? 6 : (hovering ? 3 : 1),
      shadowColor: cs.shadow.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(
          color: hovering ? cs.primary : cs.outlineVariant,
          width: hovering ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 4, color: accent.withValues(alpha: 0.85)),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: muted ? theme.hintColor : null,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            tr('{n}명', {'n': count}),
                            style: TextStyle(
                              fontSize: 11,
                              color: muted ? theme.hintColor : accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SizedBox(height: 26, child: bottom),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 위 부서 오른쪽 가운데 → 가운데 세로줄 → 하위 부서 왼쪽 가운데로 꺾은선(모서리는 살짝 둥글게).
class _ConnectorPainter extends CustomPainter {
  /// (위 부서 상자, 하위 부서 상자).
  final List<(Rect, Rect)> segments;
  final Color color;
  const _ConnectorPainter({required this.segments, required this.color});

  static const double _corner = 8;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    final path = Path();
    for (final (parent, child) in segments) {
      final start = parent.centerRight;
      final end = child.centerLeft;
      final midX = (start.dx + end.dx) / 2;
      final dy = end.dy - start.dy;
      path.moveTo(start.dx, start.dy);
      if (dy.abs() < 0.5) {
        path.lineTo(end.dx, end.dy);
        continue;
      }
      final r = math.min(_corner, math.min(dy.abs() / 2, (midX - start.dx)));
      final sign = dy.sign;
      path
        ..lineTo(midX - r, start.dy)
        ..quadraticBezierTo(midX, start.dy, midX, start.dy + sign * r)
        ..lineTo(midX, end.dy - sign * r)
        ..quadraticBezierTo(midX, end.dy, midX + r, end.dy)
        ..lineTo(end.dx, end.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_ConnectorPainter old) =>
      old.color != color || !listEquals(old.segments, segments);
}
