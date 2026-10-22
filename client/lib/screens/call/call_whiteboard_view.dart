import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../models/saved_whiteboard.dart';
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

/// 저장해 둔 화이트보드 불러오기에 쓰는 것들(Session.savedCallWhiteboards·loadSavedCallWhiteboard·deleteSavedWhiteboard).
class WhiteboardLoader {
  final Future<List<SavedWhiteboard>> Function() list;
  final Future<void> Function(String id) load;
  final Future<void> Function(String id) delete;
  const WhiteboardLoader({
    required this.list,
    required this.load,
    required this.delete,
  });
}

/// 통화 중 화이트보드 — 위에 도구 줄(펜·지우개·색·굵기·되돌리기·이 쪽 지우기·쪽 넘기기·쪽 더하기/빼기·저장·불러오기·닫기),
/// 가운데에 16:9 흰 판. 마우스·손가락·펜으로 그린다(펜의 지우개 끝은 지우개). 판 내용은 통화 참가자 모두가 같이 보고 같이
/// 그리고, 어느 쪽을 볼지는 각자 고른다([CallWhiteboard]).
class CallWhiteboardView extends StatefulWidget {
  final CallWhiteboard board;
  final VoidCallback onClose;

  /// [저장] — 지금 판을 그림으로 대화방에 올리고 획을 서버에 둔다(Session.saveCallWhiteboard). null이면 단추가 없다.
  final Future<void> Function()? onSave;

  /// [불러오기] — 저장해 둔 판을 골라 모두의 판에 편다. null이면 단추가 없다.
  final WhiteboardLoader? loader;
  const CallWhiteboardView({
    super.key,
    required this.board,
    required this.onClose,
    this.onSave,
    this.loader,
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

  /// [불러오기] — 저장해 둔 판 목록에서 고르면(지금 판에 그림이 있으면 한 번 더 묻고) 모두의 판에 편다.
  Future<void> _openLoader() async {
    final loader = widget.loader!;
    final picked = await showDialog<SavedWhiteboard>(
      context: context,
      builder: (_) => _SavedWhiteboardsDialog(loader: loader),
    );
    if (picked == null || !mounted) return;
    if (!widget.board.book.isEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(tr('화이트보드 불러오기')),
          content: Text(
            tr('모든 참가자의 화이트보드를 지우고 "{title}"을(를) 펼칩니다. 지금 판을 남기려면 먼저 저장하세요.', {
              'title': picked.title,
            }),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(tr('취소')),
            ),
            TextButton(
              key: const ValueKey('whiteboard-load-confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(tr('불러오기')),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await loader.load(picked.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(tr('화이트보드를 불러오지 못했습니다: {e}', {'e': e}))),
        );
      }
    }
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('화이트보드 지우기')),
        content: Text(
          widget.board.book.pageIds.length > 1
              ? tr('모든 참가자의 화이트보드에서 이 쪽에 그린 내용을 모두 지웁니다.')
              : tr('모든 참가자의 화이트보드에서 그린 내용을 모두 지웁니다.'),
        ),
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
                widget.board.book.pageIds.length > 1
                    ? tr('이 쪽 모두 지우기')
                    : tr('모두 지우기'),
                false,
                widget.board.book.isPageEmpty(widget.board.currentPage)
                    ? null
                    : _confirmClear,
              ),
              const SizedBox(width: 8),
              ..._pageButtons(toolButton),
              if (widget.onSave != null)
                toolButton(
                  'whiteboard-save',
                  _saving ? Icons.hourglass_top : Icons.save_alt,
                  tr('대화방에 그림으로 저장'),
                  false,
                  widget.board.book.isEmpty || _saving ? null : _save,
                ),
              if (widget.loader != null)
                toolButton(
                  'whiteboard-load',
                  Icons.folder_open_outlined,
                  tr('저장해 둔 화이트보드 불러오기'),
                  false,
                  _openLoader,
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

extension on _CallWhiteboardViewState {
  /// 쪽 단추 — ‹ 2/3 › · 쪽 더하기 · 이 쪽 빼기(첫 쪽이 아닐 때).
  List<Widget> _pageButtons(
    Widget Function(String, IconData, String, bool, VoidCallback?) toolButton,
  ) {
    final board = widget.board;
    final ids = board.book.pageIds;
    final index = board.currentPageIndex;
    return [
      if (ids.length > 1) ...[
        toolButton(
          'whiteboard-page-prev',
          Icons.chevron_left,
          tr('앞 쪽'),
          false,
          index > 0 ? () => board.showPage(ids[index - 1]) : null,
        ),
        Text(
          '${index + 1}/${ids.length}',
          key: const ValueKey('whiteboard-page-label'),
          style: const TextStyle(color: Colors.white),
        ),
        toolButton(
          'whiteboard-page-next',
          Icons.chevron_right,
          tr('다음 쪽'),
          false,
          index < ids.length - 1 ? () => board.showPage(ids[index + 1]) : null,
        ),
      ],
      toolButton(
        'whiteboard-page-add',
        Icons.note_add_outlined,
        tr('쪽 더하기'),
        false,
        ids.length < whiteboardMaxPages ? board.addPage : null,
      ),
      if (board.canRemovePage)
        toolButton(
          'whiteboard-page-remove',
          Icons.remove_circle_outline,
          tr('이 쪽 빼기(모든 참가자의 판에서)'),
          false,
          board.removeCurrentPage,
        ),
    ];
  }
}

/// 저장해 둔 화이트보드 목록 — 고르면 그 판을 돌려준다. 처음 저장한 사람·토픽 관리자는 지울 수 있다(서버가 확인).
class _SavedWhiteboardsDialog extends StatefulWidget {
  final WhiteboardLoader loader;
  const _SavedWhiteboardsDialog({required this.loader});

  @override
  State<_SavedWhiteboardsDialog> createState() =>
      _SavedWhiteboardsDialogState();
}

class _SavedWhiteboardsDialogState extends State<_SavedWhiteboardsDialog> {
  List<SavedWhiteboard>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await widget.loader.list();
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _delete(SavedWhiteboard w) async {
    try {
      await widget.loader.delete(w.id);
      if (mounted) setState(() => _items?.remove(w));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    String two(int n) => n.toString().padLeft(2, '0');
    String when(DateTime d) =>
        '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
    return AlertDialog(
      title: Text(tr('저장해 둔 화이트보드')),
      content: SizedBox(
        width: 420,
        child: _error != null
            ? Text(_error!)
            : items == null
            ? const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              )
            : items.isEmpty
            ? Text(
                tr(
                  '이 대화방에 저장해 둔 화이트보드가 없습니다. 화이트보드의 [저장]으로 남겨 두면 다음 통화에서 이어 그릴 수 있습니다.',
                ),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final w in items)
                    ListTile(
                      key: ValueKey('saved-whiteboard-${w.id}'),
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.draw_outlined),
                      title: Text(w.title),
                      subtitle: Text(
                        tr('{n}쪽 · {name} · {when}', {
                          'n': w.pageCount,
                          'name': w.updatedByName,
                          'when': when(w.updatedAt),
                        }),
                      ),
                      onTap: () => Navigator.of(context).pop(w),
                      trailing: IconButton(
                        tooltip: tr('지우기'),
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _delete(w),
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('닫기')),
        ),
      ],
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
      paintWhiteboard(canvas, size, board.currentStrokes);

  @override
  bool shouldRepaint(WhiteboardPainter old) => old.board != board;
}
