import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';
import 'package:window_manager/window_manager.dart';

import '../../services/screen_capture.dart';

/// 창 생성 인자(JSON)의 "type" 값(main.dart가 이걸 보고 어느 서브 창 진입점을 탈지 정한다).
const kCaptureWindowType = 'capture';

/// 오버레이 → 메인: 캡처 결과를 알린다.
const _kResultMethod = 'capture_result';

/// 메인 → 오버레이: 이미 떠 있는(숨겨둔) 오버레이에게 새 캡처를 시작하라고 알린다.
const _kBeginMethod = 'capture_begin';

/// 캡처가 끝난 뒤 메인 창이 할 일. [action]은
/// - `cancel`: 아무것도 안 함
/// - `dialog`: "파일 업로드" 대화상자를 띄운다(Ctrl+드래그, 또는 편집 후 업로드 버튼)
/// - `send`: 지금 보고 있는 방에 바로 업로드해서 보낸다(Ctrl+Shift+드래그)
/// - `save`: 저장 위치를 물어 저장한다(편집 도구 모음의 저장 버튼)
class CaptureOutcome {
  final String action;
  final File? file;
  const CaptureOutcome(this.action, this.file);
}

/// 오버레이는 콘솔이 없는 별도 창이라 문제가 생겨도 알 방법이 없다 — 임시 폴더의 로그 파일에 남긴다.
void _log(String message) {
  try {
    File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}tangotalk_capture.log',
    ).writeAsStringSync(
      '${DateTime.now().toIso8601String()} $message\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}

/// 한 번 만든 오버레이 창(=별도 Flutter 엔진)은 닫지 않고 숨겨뒀다가 다시 쓴다 — 엔진을 새로
/// 띄우는 데 드는 시간이 "화면이 어두워지기까지" 걸리는 시간의 대부분이라, 두 번째 캡처부터는
/// 눈에 띄게 빨라진다. 창이 실제로 닫혔으면(Alt+F4 등) getAll()에 없으므로 새로 만든다.
String? _liveOverlayWindowId;

/// 메인 창 쪽 진입점 — 화면을 찍고, 전체 화면 오버레이 창을 띄우고, 사용자가 영역을 고를 때까지
/// 기다린다. [hideMessenger]가 true면 찍기 전에 메신저 창을 잠깐 숨겼다가(오버레이가 닫히면)
/// 다시 보여준다. 사용자가 취소했거나 오버레이가 결과 없이 닫히면 null.
///
/// 화면을 찍는 일과 오버레이 창을 띄우는 일은 동시에 진행한다 — 오버레이는 찍은 파일이 나타날
/// 때까지 기다렸다가 보여준다.
Future<CaptureOutcome?> startScreenCapture({
  required bool hideMessenger,
}) async {
  final t0 = DateTime.now();
  int ms() => DateTime.now().difference(t0).inMilliseconds;

  if (hideMessenger) await windowManager.hide();
  WindowController? me;
  StreamSubscription<void>? windowsSub;
  try {
    final rawPath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'capture_${DateTime.now().microsecondsSinceEpoch}.raw';
    final geo = virtualScreenGeometry(rawPath);
    me = await WindowController.fromCurrentEngine();
    final completer = Completer<CaptureOutcome?>();

    await me.setWindowMethodHandler((call) async {
      if (call.method == _kResultMethod && !completer.isCompleted) {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final path = args['path'] as String?;
        completer.complete(
          CaptureOutcome(
            args['action'] as String,
            path == null ? null : File(path),
          ),
        );
      }
      return null;
    });

    // 메신저 창이 화면에서 사라지고 그 뒤가 다시 그려질 짧은 시간만 두고 찍는다.
    unawaited(
      Future<void>.delayed(
        hideMessenger ? const Duration(milliseconds: 60) : Duration.zero,
      ).then((_) => captureVirtualScreenTo(rawPath)).catchError((Object e) {
        _log('화면 찍기 실패: $e');
        if (!completer.isCompleted) completer.complete(null);
      }),
    );

    final payload = <String, dynamic>{
      'mainWindowId': me.windowId,
      'rawPath': geo.rawPath,
      'x': geo.x,
      'y': geo.y,
      'width': geo.width,
      'height': geo.height,
      'primaryWidth': geo.primaryWidth,
    };

    var overlayId = await _beginOnExistingOverlay(payload);
    if (overlayId != null) {
      _log('오버레이 재사용 ${ms()}ms');
    } else {
      final overlay = await WindowController.create(
        WindowConfiguration(
          arguments: jsonEncode({'type': kCaptureWindowType, ...payload}),
        ),
      );
      overlayId = overlay.windowId;
      _liveOverlayWindowId = overlayId;
      _log('오버레이 새로 생성 ${ms()}ms');
    }

    // 오버레이가 결과를 알리지 못하고 닫혀버린 경우(Alt+F4 등)에도 기다림이 끝나도록.
    windowsSub = onWindowsChanged.listen((_) async {
      final all = await WindowController.getAll();
      if (!all.any((c) => c.windowId == overlayId)) {
        if (_liveOverlayWindowId == overlayId) _liveOverlayWindowId = null;
        if (!completer.isCompleted) completer.complete(null);
      }
    });

    return await completer.future.timeout(
      const Duration(minutes: 10),
      onTimeout: () => null,
    );
  } finally {
    await windowsSub?.cancel();
    try {
      await me?.setWindowMethodHandler(null);
    } catch (_) {}
    if (hideMessenger) {
      await windowManager.show();
      await windowManager.focus();
    }
  }
}

/// 숨겨둔 오버레이가 아직 살아있으면 거기에 새 캡처를 맡기고 그 창 id를 돌려준다. 없거나
/// 연락이 안 되면 null(=새로 만들어야 함).
Future<String?> _beginOnExistingOverlay(Map<String, dynamic> payload) async {
  final id = _liveOverlayWindowId;
  if (id == null) return null;
  try {
    final all = await WindowController.getAll();
    if (!all.any((c) => c.windowId == id)) {
      _liveOverlayWindowId = null;
      return null;
    }
    await WindowController.fromWindowId(
      id,
    ).invokeMethod(_kBeginMethod, payload).timeout(const Duration(seconds: 3));
    return id;
  } catch (e) {
    _log('오버레이 재사용 실패(새로 만듭니다): $e');
    _liveOverlayWindowId = null;
    return null;
  }
}

// ───────────────────────── 오버레이(서브 창) ─────────────────────────

/// 지금 화면에 띄울 캡처 한 건. [seq]가 바뀌면 오버레이 위젯을 새 상태로 다시 만든다.
class _CaptureSession {
  final int seq;
  final ui.Image image;
  final String mainWindowId;
  final double hintCenterX;
  const _CaptureSession({
    required this.seq,
    required this.image,
    required this.mainWindowId,
    required this.hintCenterX,
  });
}

final _session = ValueNotifier<_CaptureSession?>(null);
int _seq = 0;
int _overlayHwnd = 0;

/// 실제로 화면에 띄운 캡처 번호 — 숨겨둔 창은 그리기를 멈출 수 있어서 첫 프레임 콜백이 오지
/// 않을 수 있다. 그때를 대비해 아래에서 직접 띄우는데, 이미 떴는지 이 값으로 판단한다.
int _shownSeq = 0;

void _showOverlayWindow() {
  if (_overlayHwnd == 0) return;
  ShowWindow(_overlayHwnd, SW_SHOW);
  SetForegroundWindow(_overlayHwnd);
}

/// 오버레이 서브 창의 엔진에서 실행되는 진입점(main.dart가 type=capture일 때 부른다).
Future<void> runCaptureWindow(
  WindowController controller,
  Map<String, dynamic> args,
) async {
  await windowManager.ensureInitialized();
  final hwnd = await windowManager.getId();
  _overlayHwnd = hwnd;
  // 만들어질 때는 제목줄/테두리가 있는 일반 창이라, 테두리 없는 팝업으로 바꾼다.
  SetWindowLongPtr(hwnd, GWL_STYLE, WS_POPUP);
  SetWindowLongPtr(
    hwnd,
    GWL_EXSTYLE,
    GetWindowLongPtr(hwnd, GWL_EXSTYLE) | WS_EX_TOOLWINDOW,
  );

  // 캡처가 끝나면 이 창은 닫지 않고 숨겨둔다 — 메인 창이 다음 캡처를 이 채널로 맡긴다.
  await controller.setWindowMethodHandler((call) async {
    if (call.method == _kBeginMethod) {
      // 메인 창을 기다리게 하지 않도록 바로 돌려주고 준비는 뒤에서 한다.
      unawaited(
        _prepareSession(Map<String, dynamic>.from(call.arguments as Map)),
      );
    }
    return null;
  });

  runApp(const _CaptureRoot());
  await _prepareSession(args);
}

/// 찍은 화면 파일을 읽어 이미지로 만들고, 창을 모든 모니터 크기로 맞춘 뒤 화면에 띄운다.
Future<void> _prepareSession(Map<String, dynamic> args) async {
  final t0 = DateTime.now();
  final rawPath = args['rawPath'] as String;
  final x = args['x'] as int;
  final y = args['y'] as int;
  final w = args['width'] as int;
  final h = args['height'] as int;
  final mainId = args['mainWindowId'] as String;

  // 화면을 찍는 쪽(메인 창)이 아직 파일을 다 쓰지 못했을 수 있다 — 나타날 때까지 기다린다.
  final waitStart = DateTime.now();
  while (!File(rawPath).existsSync()) {
    if (DateTime.now().difference(waitStart) > const Duration(seconds: 10)) {
      _log('화면 파일을 기다리다 시간 초과');
      await _reportAndHide(mainId, 'cancel', null);
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }

  final ui.Image image;
  try {
    image = await _decodeBgra(await File(rawPath).readAsBytes(), w, h);
  } catch (e) {
    _log('화면 이미지 준비 실패: $e');
    await _reportAndHide(mainId, 'cancel', null);
    return;
  }
  try {
    File(rawPath).deleteSync();
  } catch (_) {}

  SetWindowPos(
    _overlayHwnd,
    HWND_TOPMOST,
    x,
    y,
    w,
    h,
    SWP_FRAMECHANGED | SWP_NOACTIVATE,
  );

  final previous = _session.value;
  final seq = ++_seq;
  _session.value = _CaptureSession(
    seq: seq,
    image: image,
    mainWindowId: mainId,
    hintCenterX: (args['primaryWidth'] as int) / 2 - x,
  );
  // 숨겨둔 창이 프레임을 그리지 않아 첫 프레임 콜백이 안 오는 경우를 대비한 안전장치.
  Future<void>.delayed(const Duration(milliseconds: 400), () {
    if (_shownSeq != seq) {
      _log('첫 프레임 콜백이 없어 직접 표시');
      _showOverlayWindow();
    }
  });
  // 이전 캡처 이미지는 새 화면이 확실히 그려진 뒤에 버린다(그리는 중에 버리면 안 된다).
  if (previous != null) {
    Future<void>.delayed(const Duration(seconds: 1), previous.image.dispose);
  }
  _log('이미지 준비 완료 ${DateTime.now().difference(t0).inMilliseconds}ms');
}

/// 창을 숨기고 메인 창에 결과를 알린다(캡처를 시작하지도 못한 경우 포함).
Future<void> _reportAndHide(String mainId, String action, String? path) async {
  if (_overlayHwnd != 0) ShowWindow(_overlayHwnd, SW_HIDE);
  try {
    await WindowController.fromWindowId(mainId)
        .invokeMethod(_kResultMethod, {'action': action, 'path': path})
        .timeout(const Duration(seconds: 5));
  } catch (e) {
    _log('메인 창에 결과 전달 실패: $e');
  }
}

Future<ui.Image> _decodeBgra(Uint8List bytes, int w, int h) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: w,
    height: h,
    pixelFormat: ui.PixelFormat.bgra8888,
  );
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  return frame.image;
}

// ───────────────────────── 편집(주석) 모델 ─────────────────────────

enum _Tool { select, shape, text, pen }

enum _ShapeKind { rect, oval, line }

double _distToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (len2 == 0) return (p - a).distance;
  final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

/// 선택 영역 위에 얹는 그림 하나(자유선/도형/글자). 좌표는 오버레이 창 안의 논리 좌표.
abstract class _Annot {
  Rect get bounds;
  void moveBy(Offset d);
  void paint(Canvas canvas);
  bool hit(Offset p);
}

class _PenAnnot extends _Annot {
  List<Offset> points;
  final Color color;
  final double width;
  _PenAnnot(this.points, this.color, this.width);

  @override
  Rect get bounds {
    var r = Rect.fromLTWH(points.first.dx, points.first.dy, 0, 0);
    for (final p in points) {
      r = r.expandToInclude(Rect.fromLTWH(p.dx, p.dy, 0, 0));
    }
    return r.inflate(width / 2);
  }

  @override
  void moveBy(Offset d) => points = [for (final p in points) p + d];

  @override
  void paint(Canvas canvas) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    if (points.length == 1) path.lineTo(points.first.dx + 0.1, points.first.dy);
    canvas.drawPath(path, paint);
  }

  @override
  bool hit(Offset p) {
    final tol = width / 2 + 6;
    if (points.length == 1) return (p - points.first).distance <= tol;
    for (var i = 0; i < points.length - 1; i++) {
      if (_distToSegment(p, points[i], points[i + 1]) <= tol) return true;
    }
    return false;
  }
}

class _ShapeAnnot extends _Annot {
  final _ShapeKind kind;
  Offset a;
  Offset b;
  final Color color;
  final double width;
  _ShapeAnnot(this.kind, this.a, this.b, this.color, this.width);

  @override
  Rect get bounds => Rect.fromPoints(a, b).inflate(width / 2);

  @override
  void moveBy(Offset d) {
    a += d;
    b += d;
  }

  @override
  void paint(Canvas canvas) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final rect = Rect.fromPoints(a, b);
    switch (kind) {
      case _ShapeKind.rect:
        canvas.drawRect(rect, paint);
      case _ShapeKind.oval:
        canvas.drawOval(rect, paint);
      case _ShapeKind.line:
        canvas.drawLine(a, b, paint);
    }
  }

  @override
  bool hit(Offset p) {
    final tol = width / 2 + 6;
    return switch (kind) {
      _ShapeKind.line => _distToSegment(p, a, b) <= tol,
      _ => bounds.inflate(6).contains(p),
    };
  }
}

class _TextAnnot extends _Annot {
  Offset pos;
  final String text;
  final Color color;
  final double size;
  _TextAnnot(this.pos, this.text, this.color, this.size);

  TextPainter get _painter => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(color: color, fontSize: size, height: 1.2),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  @override
  Rect get bounds => pos & _painter.size;

  @override
  void moveBy(Offset d) => pos += d;

  @override
  void paint(Canvas canvas) => _painter.paint(canvas, pos);

  @override
  bool hit(Offset p) => bounds.inflate(4).contains(p);
}

class _RepaintTick extends ChangeNotifier {
  void bump() => notifyListeners();
}

// ───────────────────────── 오버레이 화면 ─────────────────────────

/// 위젯 테스트에서 오버레이를 그대로 띄워 보기 위한 진입점.
@visibleForTesting
Widget debugCaptureOverlay(ui.Image image) {
  _session.value = _CaptureSession(
    seq: ++_seq,
    image: image,
    mainWindowId: 'test',
    hintCenterX: 200,
  );
  return const _CaptureRoot();
}

class _CaptureRoot extends StatelessWidget {
  const _CaptureRoot();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
      home: ValueListenableBuilder<_CaptureSession?>(
        valueListenable: _session,
        builder: (context, session, _) => session == null
            ? const SizedBox.shrink()
            : _CaptureOverlay(key: ValueKey(session.seq), session: session),
      ),
    );
  }
}

class _CaptureOverlay extends StatefulWidget {
  final _CaptureSession session;
  const _CaptureOverlay({super.key, required this.session});

  @override
  State<_CaptureOverlay> createState() => _CaptureOverlayState();
}

const _palette = <Color>[
  Color(0xFFE8442E),
  Color(0xFFFF9800),
  Color(0xFFFFEB3B),
  Color(0xFF4CAF50),
  Color(0xFF2196F3),
  Color(0xFF9C27B0),
  Color(0xFF000000),
  Color(0xFFFFFFFF),
];

class _CaptureOverlayState extends State<_CaptureOverlay> {
  /// 선택 영역 안(그림/도형/글자)만 다시 그리게 하는 신호 — 선택 영역 자체의 위치·크기가
  /// 바뀔 때는 위젯을 다시 배치해야 해서 setState를 쓴다.
  final _tick = _RepaintTick();
  final _rootFocus = FocusNode();
  final _textController = TextEditingController();
  final _textFocus = FocusNode();

  Size _size = Size.zero;
  Offset? _dragStart;
  Rect? _selection;

  /// 드래그가 끝나 선택이 확정되고 도구 모음이 떠 있는 상태(일반 드래그).
  bool _confirmed = false;
  bool _hintVisible = true;
  bool _finishing = false;

  _Tool? _tool;
  _ShapeKind _shapeKind = _ShapeKind.rect;
  Color _color = _palette.first;
  double _lineWidth = 4;
  double _textSize = 24;
  bool _paletteOpen = false;

  final _annots = <_Annot>[];
  _Annot? _draft;
  int? _selectedAnnot;
  Offset? _moveLast;
  Offset? _textAt;

  ui.Image get _image => widget.session.image;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _shownSeq = widget.session.seq;
      if (_overlayHwnd == 0) return;
      _showOverlayWindow();
      windowManager.focus();
      _log('오버레이 표시');
    });
  }

  @override
  void dispose() {
    _tick.dispose();
    _rootFocus.dispose();
    _textController.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  bool _insideSelection(Offset p) => _selection?.contains(p) ?? false;

  Offset _clampToSelection(Offset p) {
    final s = _selection!;
    return Offset(p.dx.clamp(s.left, s.right), p.dy.clamp(s.top, s.bottom));
  }

  void _onDown(PointerDownEvent e) {
    if (_finishing) return;
    if (e.buttons == kSecondaryMouseButton) {
      _finish('cancel');
      return;
    }
    if (_textAt != null) _commitText();
    final pos = e.localPosition;

    if (_confirmed && _insideSelection(pos)) {
      switch (_tool) {
        case _Tool.pen:
          _draft = _PenAnnot([pos], _color, _lineWidth);
          _selectedAnnot = null;
        case _Tool.shape:
          _draft = _ShapeAnnot(_shapeKind, pos, pos, _color, _lineWidth);
          _selectedAnnot = null;
        case _Tool.text:
          setState(() {
            _textAt = pos;
            _selectedAnnot = null;
            _textController.clear();
          });
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _textFocus.requestFocus(),
          );
        case _Tool.select:
          int? hit;
          for (var i = _annots.length - 1; i >= 0; i--) {
            if (_annots[i].hit(pos)) {
              hit = i;
              break;
            }
          }
          _selectedAnnot = hit;
          _moveLast = hit == null ? null : pos;
        case null:
          break;
      }
      _tick.bump();
      return;
    }

    // 처음 드래그하거나, 확정된 선택 밖에서 다시 드래그하면 영역을 새로 고른다.
    setState(() {
      _dragStart = pos;
      _selection = Rect.fromLTWH(pos.dx, pos.dy, 0, 0);
      _confirmed = false;
      _tool = null;
      _paletteOpen = false;
      _annots.clear();
      _draft = null;
      _selectedAnnot = null;
      _hintVisible = false;
    });
  }

  void _onMove(PointerMoveEvent e) {
    if (_finishing) return;
    final pos = e.localPosition;
    final draft = _draft;
    if (draft is _PenAnnot) {
      draft.points.add(_clampToSelection(pos));
      _tick.bump();
      return;
    }
    if (draft is _ShapeAnnot) {
      draft.b = _clampToSelection(pos);
      _tick.bump();
      return;
    }
    final last = _moveLast;
    final sel = _selectedAnnot;
    if (last != null && sel != null) {
      _annots[sel].moveBy(pos - last);
      _moveLast = pos;
      _tick.bump();
      return;
    }
    final start = _dragStart;
    if (start == null) return;
    setState(() => _selection = Rect.fromPoints(start, pos));
  }

  void _onUp(PointerUpEvent e) {
    if (_finishing) return;
    final draft = _draft;
    if (draft != null) {
      _draft = null;
      final tiny = draft is _ShapeAnnot && (draft.a - draft.b).distance < 3;
      if (!tiny) _annots.add(draft);
      _tick.bump();
      return;
    }
    if (_moveLast != null) {
      _moveLast = null;
      return;
    }
    if (_dragStart == null) return;
    _dragStart = null;
    final sel = _selection;
    if (sel == null || sel.width < 6 || sel.height < 6) {
      setState(() {
        _selection = null;
        _hintVisible = true;
      });
      return;
    }
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (ctrl && shift) {
      _finish('send');
    } else if (ctrl) {
      _finish('dialog');
    } else {
      setState(() => _confirmed = true);
    }
  }

  void _commitText() {
    final at = _textAt;
    if (at == null) return;
    final text = _textController.text.trim();
    setState(() {
      _textAt = null;
      if (text.isNotEmpty) {
        _annots.add(_TextAnnot(at, text, _color, _textSize));
      }
      _textController.clear();
    });
    _tick.bump();
    _rootFocus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      if (_textAt != null) {
        // 글자 입력 중이면 캡처 전체가 아니라 그 입력만 취소한다.
        setState(() {
          _textAt = null;
          _textController.clear();
        });
        _rootFocus.requestFocus();
      } else {
        _finish('cancel');
      }
      return KeyEventResult.handled;
    }
    if (_textAt != null) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.delete && _selectedAnnot != null) {
      _annots.removeAt(_selectedAnnot!);
      _selectedAnnot = null;
      _tick.bump();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyZ &&
        HardwareKeyboard.instance.isControlPressed &&
        _annots.isNotEmpty) {
      _annots.removeLast();
      _selectedAnnot = null;
      _tick.bump();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 선택 영역(+그려둔 주석)을 잘라 PNG 파일로 만든다.
  Future<File> _exportSelection() async {
    final sel = _selection!;
    final scale = _image.width / _size.width;
    final outW = (sel.width * scale).round().clamp(1, 100000);
    final outH = (sel.height * scale).round().clamp(1, 100000);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // 오버레이 창의 논리 좌표 그대로 그려도 되도록 좌표계를 옮기고 배율을 곱한다 —
    // 화면 이미지는 창 크기에 맞춰 그린 뒤 배율로 원래 픽셀 크기가 된다(1:1).
    canvas.scale(scale);
    canvas.translate(-sel.left, -sel.top);
    canvas.clipRect(sel);
    canvas.drawImageRect(
      _image,
      Rect.fromLTWH(0, 0, _image.width.toDouble(), _image.height.toDouble()),
      Offset.zero & _size,
      Paint()..filterQuality = FilterQuality.none,
    );
    for (final a in _annots) {
      a.paint(canvas);
    }
    final img = await recorder.endRecording().toImage(outW, outH);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}.${two(now.minute)}.${two(now.second)}';
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'TangoTalk_Screenshot_$stamp.png',
    );
    await file.writeAsBytes(data!.buffer.asUint8List(), flush: true);
    return file;
  }

  Future<void> _finish(String action) async {
    if (_finishing) return;
    if (_textAt != null) _commitText();
    _finishing = true;
    _log('finish($action) 시작');
    String? path;
    if (action != 'cancel') {
      try {
        path = (await _exportSelection()).path;
      } catch (e) {
        _log('내보내기 실패: $e');
        action = 'cancel';
      }
    }
    await _reportAndHide(widget.session.mainWindowId, action, path);
    // 창을 닫지 않고 비워둔다 — 다음 캡처 때 이 엔진을 그대로 다시 쓴다.
    _session.value = null;
  }

  @override
  Widget build(BuildContext context) {
    // TextField 같은 Material 위젯은 조상에 Material이 있어야 한다(없으면 글쓰기 도구에서 입력칸을
    // 만드는 순간 예외가 나고 화면이 깨진다) — 배경은 그대로 두는 투명 Material로 감싼다.
    return Material(
      type: MaterialType.transparency,
      child: Focus(
        focusNode: _rootFocus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: LayoutBuilder(
          builder: (context, constraints) {
            _size = constraints.biggest;
            final sel = _selection;
            final hasSelection = sel != null && sel.width > 0 && sel.height > 0;
            return Stack(
              children: [
                // 찍은 화면 + 전체를 덮는 어두운 막 — 한 번 그려두면 바뀌지 않는다.
                Positioned.fill(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _BackdropPainter(_image),
                      isComplex: true,
                      willChange: false,
                    ),
                  ),
                ),
                // 선택 영역만 원래 밝기로 보여주는 레이어 — 마우스를 움직일 때 다시 그리는 범위가
                // 화면 전체가 아니라 이 영역뿐이라, 모니터가 여러 대여도 빠르게 따라온다.
                if (hasSelection)
                  Positioned(
                    left: sel.left,
                    top: sel.top,
                    width: sel.width,
                    height: sel.height,
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: _SelectionPainter(this, sel, _tick),
                      ),
                    ),
                  ),
                if (hasSelection) _buildSizeLabel(sel),
                Positioned.fill(
                  child: MouseRegion(
                    cursor: _tool == _Tool.text
                        ? SystemMouseCursors.text
                        : (_tool == _Tool.select
                              ? SystemMouseCursors.basic
                              : SystemMouseCursors.precise),
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: _onDown,
                      onPointerMove: _onMove,
                      onPointerUp: _onUp,
                    ),
                  ),
                ),
                if (_hintVisible)
                  Positioned(
                    top: 24,
                    left: widget.session.hintCenterX - 210,
                    width: 420,
                    child: _HintBanner(
                      onClose: () => setState(() => _hintVisible = false),
                    ),
                  ),
                if (_textAt != null) _buildTextField(),
                if (_confirmed && sel != null) _buildToolbar(sel),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildSizeLabel(Rect sel) {
    final scale = _image.width / _size.width;
    final above = sel.top >= 26;
    return Positioned(
      left: sel.left,
      top: above ? sel.top - 24 : sel.top + 4,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xCC000000),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          '${(sel.width * scale).round()} × ${(sel.height * scale).round()}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }

  Widget _buildTextField() {
    final at = _textAt!;
    return Positioned(
      left: at.dx - 1,
      top: at.dy - 1,
      child: Container(
        width: 260,
        decoration: BoxDecoration(
          color: const Color(0x99FFFFFF),
          border: Border.all(color: const Color(0xFF42A5F5)),
        ),
        child: TextField(
          controller: _textController,
          focusNode: _textFocus,
          style: TextStyle(color: _color, fontSize: _textSize, height: 1.2),
          cursorColor: _color,
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.zero,
            border: InputBorder.none,
          ),
          onSubmitted: (_) => _commitText(),
        ),
      ),
    );
  }

  // ───────── 도구 모음 ─────────

  Widget _group(List<Widget> children) => Material(
    elevation: 6,
    borderRadius: BorderRadius.circular(8),
    color: Colors.white,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    ),
  );

  Widget _iconBtn(
    IconData icon,
    String tip,
    VoidCallback onTap, {
    bool active = false,
    Color? color,
  }) => IconButton(
    icon: Icon(icon, size: 20, color: color ?? Colors.black87),
    tooltip: tip,
    visualDensity: VisualDensity.compact,
    style: IconButton.styleFrom(
      backgroundColor: active ? const Color(0x22000000) : null,
    ),
    onPressed: onTap,
  );

  void _pickTool(_Tool t) {
    if (_textAt != null) _commitText();
    setState(() {
      _tool = _tool == t ? null : t;
      _paletteOpen = false;
      if (_tool != _Tool.select) _selectedAnnot = null;
    });
    _tick.bump();
  }

  Widget _buildToolbar(Rect sel) {
    const barWidth = 300.0;
    const barHeight = 44.0;
    const panelReserve = 140.0;
    var left = sel.right - barWidth;
    if (left + barWidth > _size.width - 8) left = _size.width - 8 - barWidth;
    if (left < 8) left = 8;
    var top = sel.bottom + 8;
    if (top + barHeight + panelReserve > _size.height - 8) {
      top = sel.top - barHeight - 8;
    }
    if (top < 8) top = sel.top + 8;

    return Positioned(
      left: left,
      top: top,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _group([
                _iconBtn(
                  Icons.open_with,
                  '선택 (그림을 골라 이동, Delete로 삭제)',
                  () => _pickTool(_Tool.select),
                  active: _tool == _Tool.select,
                ),
                _iconBtn(
                  Icons.crop_square,
                  '도형 삽입',
                  () => _pickTool(_Tool.shape),
                  active: _tool == _Tool.shape,
                ),
                _iconBtn(
                  Icons.title,
                  '글쓰기',
                  () => _pickTool(_Tool.text),
                  active: _tool == _Tool.text,
                ),
                _iconBtn(
                  Icons.edit_outlined,
                  '그리기',
                  () => _pickTool(_Tool.pen),
                  active: _tool == _Tool.pen,
                ),
              ]),
              const SizedBox(width: 8),
              _group([
                _iconBtn(
                  Icons.close,
                  '취소',
                  () => _finish('cancel'),
                  color: const Color(0xFFE53935),
                ),
                _iconBtn(
                  Icons.file_download_outlined,
                  '저장',
                  () => _finish('save'),
                ),
                _iconBtn(
                  Icons.check,
                  '파일 업로드',
                  () => _finish('dialog'),
                  color: const Color(0xFF1E88E5),
                ),
              ]),
            ],
          ),
          if (_tool != null && _tool != _Tool.select) ...[
            const SizedBox(height: 6),
            _buildOptionsPanel(),
          ],
        ],
      ),
    );
  }

  Widget _buildOptionsPanel() {
    Widget shapeBtn(_ShapeKind kind, Widget icon) => InkWell(
      onTap: () => setState(() => _shapeKind = kind),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _shapeKind == kind ? const Color(0x22000000) : null,
          borderRadius: BorderRadius.circular(6),
        ),
        child: icon,
      ),
    );

    Widget widthDot(double w) => InkWell(
      onTap: () => setState(() => _lineWidth = w),
      customBorder: const CircleBorder(),
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: _lineWidth == w
              ? Border.all(color: const Color(0xFF42A5F5), width: 1.5)
              : null,
        ),
        child: Container(
          width: w + 4,
          height: w + 4,
          decoration: const BoxDecoration(
            color: Colors.black54,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );

    Widget sizeBtn(double size, double glyph) => InkWell(
      onTap: () => setState(() => _textSize = size),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _textSize == size ? const Color(0x22000000) : null,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          'T',
          style: TextStyle(
            fontSize: glyph,
            fontFamily: 'serif',
            color: Colors.black87,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );

    final swatch = InkWell(
      onTap: () => setState(() => _paletteOpen = !_paletteOpen),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: _color,
          border: Border.all(color: Colors.black26),
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );

    final rows = <Widget>[];
    switch (_tool) {
      case _Tool.shape:
        rows.add(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              shapeBtn(
                _ShapeKind.rect,
                const Icon(Icons.crop_square, size: 20, color: Colors.black87),
              ),
              shapeBtn(
                _ShapeKind.oval,
                const Icon(
                  Icons.circle_outlined,
                  size: 20,
                  color: Colors.black87,
                ),
              ),
              shapeBtn(
                _ShapeKind.line,
                Transform.rotate(
                  angle: -math.pi / 4,
                  child: const Icon(
                    Icons.remove,
                    size: 22,
                    color: Colors.black87,
                  ),
                ),
              ),
            ],
          ),
        );
        rows.add(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              widthDot(2),
              widthDot(4),
              widthDot(8),
              const SizedBox(width: 8),
              swatch,
            ],
          ),
        );
      case _Tool.pen:
        rows.add(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              widthDot(2),
              widthDot(4),
              widthDot(8),
              const SizedBox(width: 8),
              swatch,
            ],
          ),
        );
      case _Tool.text:
        rows.add(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              sizeBtn(16, 13),
              sizeBtn(24, 17),
              sizeBtn(36, 22),
              const SizedBox(width: 8),
              swatch,
            ],
          ),
        );
      default:
        break;
    }
    if (_paletteOpen) {
      rows.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final c in _palette)
              InkWell(
                onTap: () => setState(() {
                  _color = c;
                  _paletteOpen = false;
                }),
                child: Container(
                  width: 22,
                  height: 22,
                  margin: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: c,
                    border: Border.all(
                      color: c == _color
                          ? const Color(0xFF42A5F5)
                          : Colors.black26,
                      width: c == _color ? 2 : 1,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const SizedBox(height: 4),
              rows[i],
            ],
          ],
        ),
      ),
    );
  }
}

class _HintBanner extends StatelessWidget {
  final VoidCallback onClose;
  const _HintBanner({required this.onClose});

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: Colors.white,
      fontSize: 14,
      height: 1.5,
      decoration: TextDecoration.none,
    );
    return Material(
      color: const Color(0xE6000000),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
        child: Row(
          children: [
            const Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Ctrl + 드래그 : 파일 업로드 창 열기', style: style),
                  Text('Ctrl + Shift + 드래그 : 바로 업로드하고 보내기', style: style),
                  Text('드래그 : 편집(그리기)·저장·업로드 선택', style: style),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white70, size: 18),
              onPressed: onClose,
              tooltip: '안내 닫기',
            ),
          ],
        ),
      ),
    );
  }
}

/// 찍은 화면 + 전체를 덮는 어두운 막. 캡처 한 건 동안 바뀌지 않으므로 한 번만 그려진다.
class _BackdropPainter extends CustomPainter {
  final ui.Image image;
  const _BackdropPainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0x99000000),
    );
  }

  @override
  bool shouldRepaint(_BackdropPainter old) => old.image != image;
}

/// 선택 영역 안쪽만 그린다 — 원래 밝기의 화면 + 주석 + 테두리. 이 레이어의 크기가 곧 다시
/// 그리는 범위라, 마우스를 움직일 때 드는 비용이 선택한 크기에만 비례한다.
class _SelectionPainter extends CustomPainter {
  final _CaptureOverlayState s;
  final Rect sel;
  _SelectionPainter(this.s, this.sel, Listenable repaint)
    : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final image = s._image;
    final scale = image.width / s._size.width;
    canvas.drawImageRect(
      image,
      Rect.fromLTRB(
        sel.left * scale,
        sel.top * scale,
        sel.right * scale,
        sel.bottom * scale,
      ),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(-sel.left, -sel.top);
    for (final a in s._annots) {
      a.paint(canvas);
    }
    s._draft?.paint(canvas);
    final picked = s._selectedAnnot;
    if (picked != null && picked < s._annots.length) {
      canvas.drawRect(
        s._annots[picked].bounds.inflate(4),
        Paint()
          ..color = const Color(0xFF42A5F5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
    canvas.restore();

    canvas.drawRect(
      Rect.fromLTWH(0.75, 0.75, size.width - 1.5, size.height - 1.5),
      Paint()
        ..color = const Color(0xFF42A5F5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_SelectionPainter old) => old.sel != sel;
}
