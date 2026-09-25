import 'dart:io';
import 'dart:ui' as ui;

import 'package:custom_mouse_cursor/custom_mouse_cursor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 끌 수 있는 것 위의 "손"(펼친 손)과 끄는 동안의 "쥔 손" 커서.
///
/// Flutter의 SystemMouseCursors.grab/grabbing은 macOS·Linux에만 대응되는 커서가 있고
/// Windows에는 없어서(기본 화살표로 나온다), Windows에서는 손 모양을 픽셀 그림으로 그려
/// 직접 만든 커서를 쓴다. 앱(창)마다 시작할 때 [init]을 한 번 부른다 — 만들기 전이나 실패하면
/// 시스템 커서로 남는다.
abstract final class GrabCursors {
  static MouseCursor _open = SystemMouseCursors.grab;
  static MouseCursor _closed = SystemMouseCursors.grabbing;

  /// 끌 수 있음(펼친 손).
  static MouseCursor get open => _open;

  /// 끄는 중(쥔 손).
  static MouseCursor get closed => _closed;

  static Future<void> init() async {
    if (kIsWeb || !Platform.isWindows) return;
    try {
      _open = await _make(_openHand);
      _closed = await _make(_closedHand);
    } catch (e) {
      debugPrint('[cursor] 손 모양 커서를 만들지 못했습니다: $e');
    }
  }

  // 16×16 픽셀 그림 — '#' 검은 테두리, '.' 흰 속, ' ' 투명. macOS의 손 커서와 비슷한 모양.
  static const _openHand = [
    '       ##       ',
    '   ## #..###    ',
    '  #..##..#..#   ',
    '  #..##..#..# # ',
    '   #..#..#..##.#',
    '   #..#..#..#..#',
    ' ## #.......#..#',
    '#..##..........#',
    '#...#.........# ',
    ' #............# ',
    '  #...........# ',
    '  #..........#  ',
    '   #.........#  ',
    '    #.......#   ',
    '     #......#   ',
    '     #......#   ',
  ];

  static const _closedHand = [
    '                ',
    '                ',
    '                ',
    '    ## ## ##    ',
    '   #..#..#..##  ',
    '   #........#.# ',
    '    #.........# ',
    '   ##.........# ',
    '  #..#........# ',
    '  #...........# ',
    '   #.........#  ',
    '   #.........#  ',
    '    #.......#   ',
    '     #......#   ',
    '     #......#   ',
    '                ',
  ];

  /// 픽셀 그림을 2배(32×32)로 그려 커서로 만든다. 가운데가 기준점.
  static Future<MouseCursor> _make(List<String> art) async {
    const scale = 2.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final black = Paint()..color = const Color(0xFF000000);
    final white = Paint()..color = const Color(0xFFFFFFFF);
    for (var y = 0; y < art.length; y++) {
      for (var x = 0; x < art[y].length; x++) {
        final c = art[y][x];
        if (c == ' ') continue;
        canvas.drawRect(
          Rect.fromLTWH(x * scale, y * scale, scale, scale),
          c == '#' ? black : white,
        );
      }
    }
    final image = await recorder.endRecording().toImage(32, 32);
    // 180% 배율 기준 크기로 알려 준다 — 100% 화면에선 약 18px, 150%에선 약 27px로 보인다.
    return CustomMouseCursor.image(
      image,
      hotX: 16,
      hotY: 16,
      thisImagesDevicePixelRatio: 1.8,
    );
  }
}
