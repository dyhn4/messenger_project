import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

/// 통화 중 화이트보드의 LiveKit 데이터 채널 topic(손들기의 'call'과 따로 — 서로의 메시지를 해석하지 않게).
const whiteboardDataTopic = 'wb';

/// 좌표를 보낼 때의 눈금 — 판 크기와 상관없이 0~[_grid] 정수로 보낸다(소수보다 짧다). 판은 16:9이고 x는 판 너비,
/// y는 판 높이에 대한 비율이라 화면 크기가 달라도 같은 자리에 그려진다.
const _grid = 10000;

/// 한 메시지에 싣는 점 수 상한 — LiveKit 데이터 메시지는 작게(수 KB) 보내는 게 안전해서, 늦게 들어온 사람에게 보내는
/// 긴 획은 나눠 보낸다.
const whiteboardPointsPerMessage = 400;

/// 화이트보드 판의 비율(가로:세로) — 모든 참가자가 같은 비율의 판에 그린다.
const whiteboardAspectRatio = 16 / 9;

/// 획 하나 — 펜으로 한 번 누르고 뗄 때까지. [points]는 판에 대한 비율(0~1), [width]는 판 너비에 대한 굵기 비율.
class WhiteboardStroke {
  final String id;
  final String authorId;
  final int color;
  final double width;
  final List<Offset> points;

  WhiteboardStroke({
    required this.id,
    required this.authorId,
    required this.color,
    required this.width,
    List<Offset>? points,
  }) : points = points ?? [];
}

/// 화이트보드 데이터 채널 메시지 — JSON `{t, ...}`:
/// - `begin {id, c, w, p}` 새 획(같은 id면 갈아끼운다 — 늦게 들어온 사람에게 다시 보낼 때),
/// - `add {id, p}` 그리는 중인 획에 점을 잇는다,
/// - `erase {ids}` 획을 지운다(지우개·되돌리기),
/// - `clear` 판 전체를 지운다,
/// - `open` 화이트보드를 열었다(다른 사람에게 알림만).
/// `p`는 [x0, y0, x1, y1, …] 정수(0~10000). 보낸 사람은 메시지가 아니라 LiveKit이 알려주는 identity로 정한다.
sealed class WhiteboardMessage {
  const WhiteboardMessage();

  Map<String, Object?> toJson();

  List<int> encode() => utf8.encode(jsonEncode(toJson()));

  /// 화이트보드 메시지가 아니거나 깨졌으면 null.
  static WhiteboardMessage? decode(List<int> data) {
    try {
      final json = jsonDecode(utf8.decode(data));
      if (json is! Map) return null;
      switch (json['t']) {
        case 'begin':
          return WhiteboardBegin(
            id: json['id'] as String,
            color: (json['c'] as num).toInt(),
            width: (json['w'] as num).toDouble(),
            points: _decodePoints(json['p']),
          );
        case 'add':
          return WhiteboardAdd(
            id: json['id'] as String,
            points: _decodePoints(json['p']),
          );
        case 'erase':
          return WhiteboardErase((json['ids'] as List).cast<String>());
        case 'clear':
          return const WhiteboardClear();
        case 'open':
          return const WhiteboardOpened();
      }
    } catch (_) {}
    return null;
  }
}

class WhiteboardBegin extends WhiteboardMessage {
  final String id;
  final int color;
  final double width;
  final List<Offset> points;
  const WhiteboardBegin({
    required this.id,
    required this.color,
    required this.width,
    this.points = const [],
  });

  @override
  Map<String, Object?> toJson() => {
    't': 'begin',
    'id': id,
    'c': color,
    'w': width,
    'p': _encodePoints(points),
  };
}

class WhiteboardAdd extends WhiteboardMessage {
  final String id;
  final List<Offset> points;
  const WhiteboardAdd({required this.id, required this.points});

  @override
  Map<String, Object?> toJson() => {
    't': 'add',
    'id': id,
    'p': _encodePoints(points),
  };
}

class WhiteboardErase extends WhiteboardMessage {
  final List<String> ids;
  const WhiteboardErase(this.ids);

  @override
  Map<String, Object?> toJson() => {'t': 'erase', 'ids': ids};
}

class WhiteboardClear extends WhiteboardMessage {
  const WhiteboardClear();

  @override
  Map<String, Object?> toJson() => {'t': 'clear'};
}

class WhiteboardOpened extends WhiteboardMessage {
  const WhiteboardOpened();

  @override
  Map<String, Object?> toJson() => {'t': 'open'};
}

List<int> _encodePoints(List<Offset> points) => [
  for (final p in points) ...[
    (p.dx.clamp(0.0, 1.0) * _grid).round(),
    (p.dy.clamp(0.0, 1.0) * _grid).round(),
  ],
];

List<Offset> _decodePoints(Object? raw) {
  final list = (raw as List?) ?? const [];
  return [
    for (var i = 0; i + 1 < list.length; i += 2)
      Offset(
        (list[i] as num).toDouble() / _grid,
        (list[i + 1] as num).toDouble() / _grid,
      ),
  ];
}

/// 화이트보드 내용(획 목록, 그린 순서) — 내가 그린 것과 데이터 채널로 받은 것을 같은 규칙으로 쌓는다.
class WhiteboardBook {
  final Map<String, WhiteboardStroke> _strokes = {};

  Iterable<WhiteboardStroke> get strokes => _strokes.values;
  bool get isEmpty => _strokes.isEmpty;
  WhiteboardStroke? operator [](String id) => _strokes[id];

  /// [authorId]가 보낸 메시지를 반영한다. 판이 바뀌었으면 true.
  bool apply(String authorId, WhiteboardMessage message) {
    switch (message) {
      case WhiteboardBegin():
        _strokes.remove(message.id);
        _strokes[message.id] = WhiteboardStroke(
          id: message.id,
          authorId: authorId,
          color: message.color,
          width: message.width,
          points: [...message.points],
        );
        return true;
      case WhiteboardAdd():
        final stroke = _strokes[message.id];
        if (stroke == null || message.points.isEmpty) return false;
        stroke.points.addAll(message.points);
        return true;
      case WhiteboardErase():
        var changed = false;
        for (final id in message.ids) {
          changed = _strokes.remove(id) != null || changed;
        }
        return changed;
      case WhiteboardClear():
        if (_strokes.isEmpty) return false;
        _strokes.clear();
        return true;
      case WhiteboardOpened():
        return false;
    }
  }

  /// [authorId]가 가장 나중에 그린 획(되돌리기 대상) — 없으면 null.
  WhiteboardStroke? lastStrokeBy(String authorId) {
    WhiteboardStroke? last;
    for (final s in _strokes.values) {
      if (s.authorId == authorId) last = s;
    }
    return last;
  }

  /// 판 위의 [point](비율) 둘레 [radius](판 너비 비율) 안을 지나는 획들 — 지우개.
  List<String> strokesNear(Offset point, double radius) {
    final hits = <String>[];
    for (final s in _strokes.values) {
      final reach = radius + s.width / 2;
      if (_touches(s.points, point, reach)) hits.add(s.id);
    }
    return hits;
  }

  /// 늦게 들어온 사람에게 지금 판을 그대로 보내는 메시지들 — 긴 획은 `begin` 뒤에 `add`로 나눈다.
  List<WhiteboardMessage> snapshotMessages() => [
    for (final s in _strokes.values) ..._strokeMessages(s),
  ];

  void clear() => _strokes.clear();
}

List<WhiteboardMessage> _strokeMessages(WhiteboardStroke s) {
  final chunks = <List<Offset>>[];
  for (var i = 0; i < s.points.length; i += whiteboardPointsPerMessage) {
    chunks.add(
      s.points.sublist(
        i,
        math.min(i + whiteboardPointsPerMessage, s.points.length),
      ),
    );
  }
  return [
    WhiteboardBegin(
      id: s.id,
      color: s.color,
      width: s.width,
      points: chunks.isEmpty ? const [] : chunks.first,
    ),
    for (final chunk in chunks.skip(1)) WhiteboardAdd(id: s.id, points: chunk),
  ];
}

/// 점 목록(선분들)이 [p]에서 [reach] 안을 지나는지. 판 비율(16:9)대로 y를 펴서 잰다.
bool _touches(List<Offset> points, Offset p, double reach) {
  Offset flat(Offset o) => Offset(o.dx, o.dy / whiteboardAspectRatio);
  final target = flat(p);
  if (points.length == 1) {
    return (flat(points.first) - target).distance <= reach;
  }
  for (var i = 0; i + 1 < points.length; i++) {
    if (_segmentDistance(flat(points[i]), flat(points[i + 1]), target) <=
        reach) {
      return true;
    }
  }
  return false;
}

double _segmentDistance(Offset a, Offset b, Offset p) {
  final ab = b - a;
  final lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
  if (lengthSquared == 0) return (p - a).distance;
  final t = (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / lengthSquared)
      .clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

/// 판을 [canvas]의 [size] 크기에 그린다 — 흰 바탕에 획들(통화 화면의 WhiteboardPainter와 저장할 때의 그림이 같은 그림이 되게).
void paintWhiteboard(
  ui.Canvas canvas,
  ui.Size size,
  Iterable<WhiteboardStroke> strokes,
) {
  canvas.drawRect(
    Offset.zero & size,
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  for (final stroke in strokes) {
    if (stroke.points.isEmpty) continue;
    final width = stroke.width * size.width;
    final paint = ui.Paint()
      ..color = ui.Color(stroke.color)
      ..strokeWidth = width
      ..strokeCap = ui.StrokeCap.round
      ..strokeJoin = ui.StrokeJoin.round
      ..style = ui.PaintingStyle.stroke
      ..isAntiAlias = true;
    Offset at(Offset p) => Offset(p.dx * size.width, p.dy * size.height);
    if (stroke.points.length == 1) {
      canvas.drawCircle(
        at(stroke.points.first),
        width / 2,
        paint..style = ui.PaintingStyle.fill,
      );
      continue;
    }
    final path = ui.Path()
      ..moveTo(at(stroke.points.first).dx, at(stroke.points.first).dy);
    for (final p in stroke.points.skip(1)) {
      final o = at(p);
      path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(path, paint);
  }
}

/// 저장할 때의 그림 너비(px) — 16:9라 1920×1080.
const whiteboardExportWidth = 1920;

/// 판을 PNG로 — 대화방에 사진으로 올린다(CallWhiteboard.renderPng).
Future<Uint8List> renderWhiteboardPng(
  Iterable<WhiteboardStroke> strokes, {
  int width = whiteboardExportWidth,
}) async {
  final height = (width / whiteboardAspectRatio).round();
  final recorder = ui.PictureRecorder();
  paintWhiteboard(
    ui.Canvas(recorder),
    ui.Size(width.toDouble(), height.toDouble()),
    strokes,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// 늦게 들어온 사람에게 판을 다시 보낼 사람 — 이미 있던 참가자 중 identity가 가장 작은 한 명(모두가 같은 답을 내서 한
/// 사람만 보낸다). 아무도 없으면 null.
String? whiteboardSnapshotSender(Iterable<String> existingIdentities) {
  String? min;
  for (final id in existingIdentities) {
    if (min == null || id.compareTo(min) < 0) min = id;
  }
  return min;
}

/// 통화 한 통의 화이트보드 — 판([book])과 그리는 중인 내 획, 데이터 채널로 보내기([send]). 점은 그릴 때마다 보내지
/// 않고 [flushInterval]마다 모아 보낸다(메시지 수를 줄인다). 판이 바뀌면 알린다(화이트보드 화면만 다시 그린다 —
/// 통화 화면 전체를 다시 그리지 않게 CallController와 따로 둔다).
class CallWhiteboard extends ChangeNotifier {
  CallWhiteboard({
    required this.myId,
    required this.send,
    this.flushInterval = const Duration(milliseconds: 40),
  });

  /// 내 identity(= 사용자 id) — 내가 그린 획의 작성자.
  final String myId;

  /// 메시지를 방 전체(또는 [to]에게만)에 보낸다.
  final Future<void> Function(WhiteboardMessage message, {List<String>? to})
  send;

  final Duration flushInterval;

  final WhiteboardBook book = WhiteboardBook();

  /// 판이 바뀐 횟수 — 그리는 쪽(CustomPainter)이 다시 그릴지 정한다.
  int revision = 0;

  /// 마지막으로 저장한(대화방에 올린) 때의 [revision] — 그 뒤로 바뀐 게 있는지([hasUnsavedChanges]).
  int _savedRevision = 0;

  /// 저장한 뒤로 판이 바뀌었고 비어 있지 않은지 — 마지막 사람이 통화를 나갈 때 저절로 저장할지(Session.leaveCall).
  bool get hasUnsavedChanges => !book.isEmpty && revision != _savedRevision;

  /// 지금 판을 PNG로 그리고 저장한 것으로 적는다.
  Future<Uint8List> renderPng() async {
    endStroke();
    final at = revision;
    final png = await renderWhiteboardPng(List.of(book.strokes));
    _savedRevision = at;
    return png;
  }

  String? _drawingId;
  final List<Offset> _pending = [];
  Timer? _flushTimer;
  int _seq = 0;

  void _changed() {
    revision++;
    notifyListeners();
  }

  /// 획을 시작한다(누른 자리 [point]).
  void beginStroke(Offset point, {required int color, required double width}) {
    endStroke();
    final id = '$myId-${DateTime.now().microsecondsSinceEpoch}-${_seq++}';
    _drawingId = id;
    final message = WhiteboardBegin(
      id: id,
      color: color,
      width: width,
      points: [point],
    );
    book.apply(myId, message);
    _changed();
    unawaited(send(message));
  }

  /// 그리는 중인 획에 점을 잇는다 — 판에는 바로, 데이터 채널에는 모아서.
  void extendStroke(Offset point) {
    final id = _drawingId;
    if (id == null) return;
    book.apply(myId, WhiteboardAdd(id: id, points: [point]));
    _pending.add(point);
    _changed();
    _flushTimer ??= Timer(flushInterval, _flush);
  }

  /// 획을 마친다(뗐을 때) — 남은 점을 바로 보낸다.
  void endStroke() {
    _flush();
    _drawingId = null;
  }

  void _flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    final id = _drawingId;
    if (id == null || _pending.isEmpty) return;
    final points = List<Offset>.of(_pending);
    _pending.clear();
    unawaited(send(WhiteboardAdd(id: id, points: points)));
  }

  /// 지우개 — [point] 둘레의 획을 지운다.
  void eraseAt(Offset point, {double radius = 0.012}) {
    final ids = book.strokesNear(point, radius);
    if (ids.isEmpty) return;
    final message = WhiteboardErase(ids);
    book.apply(myId, message);
    _changed();
    unawaited(send(message));
  }

  /// 내가 마지막으로 그린 획을 지운다.
  void undo() {
    endStroke();
    final last = book.lastStrokeBy(myId);
    if (last == null) return;
    final message = WhiteboardErase([last.id]);
    book.apply(myId, message);
    _changed();
    unawaited(send(message));
  }

  bool get canUndo => book.lastStrokeBy(myId) != null;

  /// 판 전체를 지운다(모두의 판에서).
  void clearAll() {
    endStroke();
    if (!book.apply(myId, const WhiteboardClear())) return;
    _changed();
    unawaited(send(const WhiteboardClear()));
  }

  /// 화이트보드를 열었다고 다른 사람들에게 알린다.
  void announceOpened() => unawaited(send(const WhiteboardOpened()));

  /// 다른 사람이 보낸 메시지 — 판이 바뀌었으면 다시 그린다.
  void receive(String authorId, WhiteboardMessage message) {
    if (book.apply(authorId, message)) _changed();
  }

  /// 막 들어온 [identity]에게 지금 판을 보낸다.
  Future<void> sendSnapshotTo(String identity) async {
    for (final message in book.snapshotMessages()) {
      await send(message, to: [identity]);
    }
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    super.dispose();
  }
}
