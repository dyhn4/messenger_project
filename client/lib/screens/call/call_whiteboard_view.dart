import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../services/call_whiteboard.dart';
import 'call_stage.dart' show callTileColor;
import '../../l10n/tr.dart';

/// 펜 색 — 흰 판 위에서 잘 보이는 것들.
const whiteboardColors = <int>[
  0xFF212121, // 검정
  0xFFE53935, // 빨강
  0xFF1E88E5, // 파랑
  0xFF43A047, // 초록
  0xFFFB8C00, // 주황
  0xFF8E24AA, // 보라
];

/// 펜 굵기 — 판 너비에 대한 비율(판이 1600px이면 약 3·6·13px). 비율이라 화면 크기가 달라도 같은 굵기로 보인다.
const whiteboardWidths = <double>[0.002, 0.004, 0.008];

enum _Tool { pen, eraser }

/// 통화 중 화이트보드 — 위에 도구 줄(펜·지우개·색·굵기·되돌리기·모두 지우기·닫기), 가운데에 16:9 흰 판. 마우스·손가락·
/// 펜으로 그린다(펜의 지우개 끝은 지우개). 판 내용은 통화 참가자 모두가 같이 보고 같이 그린다([CallWhiteboard]).
class CallWhiteboardView extends StatefulWidget {
  final CallWhiteboard board;
  final VoidCallback onClose;

  /// [저장] — 지금 판을 그림으로 대화방에 올린다(Session.saveCallWhiteboard). null이면 단추가 없다.
  final Future<void> Function()? onSave;
  const CallWhiteboardView({
    super.key,
    required this.board,
    required this.onClose,
    this.onSave,
  });

  @override
  State<CallWhiteboardView> createState() => _CallWhiteboardViewState();
}

class _CallWhiteboardViewState extends State<CallWhiteboardView> {
  _Tool _tool = _Tool.pen;
  int _color = whiteboardColors.first;
  double _width = whiteboardWidths[1];

  /// 지금 판을 누르고 있는 포인터와 그 포인터가 지우개인지.
  int? _pointer;
  bool _erasing = false;

  /// 지우개가 마지막으로 지난 자리 — 빠르게 끌면 이벤트 사이가 벌어지므로 그 사이도 훑는다.
  Offset? _lastErase;

  Offset _normalize(Offset local, Size size) => Offset(
    (local.dx / size.width).clamp(0.0, 1.0),
    (local.dy / size.height).clamp(0.0, 1.0),
  );

  void _down(PointerDownEvent e, Size size) {
    if (_pointer != null) return;
    // 마우스는 왼쪽 단추로만 그린다(오른쪽은 무시).
    if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryButton) {
      return;
    }
    _pointer = e.pointer;
    _erasing =
        _tool == _Tool.eraser || e.kind == PointerDeviceKind.invertedStylus;
    final point = _normalize(e.localPosition, size);
    if (_erasing) {
      _lastErase = point;
      widget.board.eraseAt(point);
    } else {
      widget.board.beginStroke(point, color: _color, width: _width);
    }
  }

  /// [from]에서 [to]까지 지우개 반지름보다 촘촘하게 훑는다.
  void _eraseAlong(Offset from, Offset to) {
    const step = 0.008;
    final flat = Offset(
      to.dx - from.dx,
      (to.dy - from.dy) / whiteboardAspectRatio,
    );
    final steps = (flat.distance / step).ceil().clamp(1, 200);
    for (var i = 1; i <= steps; i++) {
      widget.board.eraseAt(Offset.lerp(from, to, i / steps)!);
    }
  }

  void _move(PointerMoveEvent e, Size size) {
    if (e.pointer != _pointer) return;
    final point = _normalize(e.localPosition, size);
    if (_erasing) {
      _eraseAlong(_lastErase ?? point, point);
      _lastErase = point;
    } else {
      widget.board.extendStroke(point);
    }
  }

  void _up(PointerEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    _lastErase = null;
    if (!_erasing) widget.board.endStroke();
  }

  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.onSave!();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('화이트보드 지우기')),
        content: Text(tr('모든 참가자의 화이트보드에서 그린 내용을 모두 지웁니다.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('취소')),
          ),
          TextButton(
            key: const ValueKey('whiteboard-clear-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              tr('모두 지우기'),
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (ok == true) widget.board.clearAll();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _toolbar(context),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Center(
              child: AspectRatio(
                aspectRatio: whiteboardAspectRatio,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final size = box.biggest;
                      return Listener(
                        key: const ValueKey('whiteboard-canvas'),
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (e) => _down(e, size),
                        onPointerMove: (e) => _move(e, size),
                        onPointerUp: _up,
                        onPointerCancel: _up,
                        child: MouseRegion(
                          cursor: _tool == _Tool.eraser
                              ? SystemMouseCursors.cell
                              : SystemMouseCursors.precise,
                          child: CustomPaint(
                            size: size,
                            painter: WhiteboardPainter(widget.board),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _toolbar(BuildContext context) {
    Widget toolButton(
      String key,
      IconData icon,
      String tooltip,
      bool selected,
      VoidCallback? onPressed,
    ) => IconButton(
      key: ValueKey(key),
      tooltip: tooltip,
      onPressed: onPressed,
      isSelected: selected,
      color: Colors.white,
      disabledColor: Colors.white30,
      style: IconButton.styleFrom(
        backgroundColor: selected ? Colors.white24 : null,
      ),
      icon: Icon(icon, size: 20),
    );

    return Container(
      color: callTileColor,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ListenableBuilder(
          listenable: widget.board,
          builder: (context, _) => Row(
            children: [
              toolButton(
                'whiteboard-pen',
                Icons.edit,
                tr('펜'),
                _tool == _Tool.pen,
                () => setState(() => _tool = _Tool.pen),
              ),
              toolButton(
                'whiteboard-eraser',
                Icons.auto_fix_normal,
                tr('지우개(닿은 획을 지웁니다)'),
                _tool == _Tool.eraser,
                () => setState(() => _tool = _Tool.eraser),
              ),
              const SizedBox(width: 8),
              for (final (i, color) in whiteboardColors.indexed)
                _ColorDot(
                  key: ValueKey('whiteboard-color-$i'),
                  color: Color(color),
                  selected: _tool == _Tool.pen && _color == color,
                  onTap: () => setState(() {
                    _color = color;
                    _tool = _Tool.pen;
                  }),
                ),
              const SizedBox(width: 8),
              for (final (i, width) in whiteboardWidths.indexed)
                _WidthDot(
                  key: ValueKey('whiteboard-width-$i'),
                  diameter: 6.0 + i * 5,
                  selected: _width == width,
                  onTap: () => setState(() {
                    _width = width;
                    _tool = _Tool.pen;
                  }),
                ),
              const SizedBox(width: 8),
              toolButton(
                'whiteboard-undo',
                Icons.undo,
                tr('내가 마지막으로 그린 획 지우기'),
                false,
                widget.board.canUndo ? widget.board.undo : null,
              ),
              toolButton(
                'whiteboard-clear',
                Icons.delete_sweep_outlined,
                tr('모두 지우기'),
                false,
                widget.board.book.isEmpty ? null : _confirmClear,
              ),
              if (widget.onSave != null)
                toolButton(
                  'whiteboard-save',
                  _saving ? Icons.hourglass_top : Icons.save_alt,
                  tr('대화방에 그림으로 저장'),
                  false,
                  widget.board.book.isEmpty || _saving ? null : _save,
                ),
              const SizedBox(width: 8),
              toolButton(
                'whiteboard-close',
                Icons.close,
                tr('화이트보드 닫기(내용은 그대로 남습니다)'),
                false,
                widget.onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  const _ColorDot({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 18,
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? Colors.white : Colors.white24,
              width: selected ? 2.5 : 1,
            ),
          ),
        ),
      ),
    );
  }
}

class _WidthDot extends StatelessWidget {
  final double diameter;
  final bool selected;
  final VoidCallback onTap;
  const _WidthDot({
    super.key,
    required this.diameter,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 18,
      child: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? Colors.white24 : null,
        ),
        child: Container(
          width: diameter,
          height: diameter,
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

/// 흰 바탕에 획들을 그린다 — 판이 바뀔 때마다([CallWhiteboard]가 알릴 때) 다시 그린다.
class WhiteboardPainter extends CustomPainter {
  final CallWhiteboard board;
  WhiteboardPainter(this.board) : super(repaint: board);

  @override
  void paint(Canvas canvas, Size size) =>
      paintWhiteboard(canvas, size, board.book.strokes);

  @override
  bool shouldRepaint(WhiteboardPainter old) => old.board != board;
}
