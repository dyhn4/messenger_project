import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// 프로필 사진·알림 아이콘 같은 작은 아바타용 썸네일의 한 변(px) — 가장 크게 그려지는 프로필
/// 편집 미리보기(지름 약 120)도 선명한 크기다.
const kAvatarThumbnailSize = 256;

/// [bytes](어떤 크기의 사진이든)의 가운데를 정사각형으로 오려 [size]px PNG 썸네일로 줄인다.
/// 휴대폰 사진 원본(수 MB·수천 픽셀)을 서버·알림에 그대로 보내지 않으려는 것이다. 읽을 수 없는
/// 형식이면 던진다.
Future<Uint8List> makeAvatarThumbnail(
  Uint8List bytes, {
  int size = kAvatarThumbnailSize,
}) async {
  // 디코딩 단계에서 미리 줄여서(한 변 기준 size*2) 큰 원본을 통째로 메모리에 펼치지 않는다.
  final codec = await ui.instantiateImageCodec(bytes, targetWidth: size * 2);
  final src = (await codec.getNextFrame()).image;
  final side = math.min(src.width, src.height).toDouble();
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    src,
    ui.Rect.fromLTWH(
      (src.width - side) / 2,
      (src.height - side) / 2,
      side,
      side,
    ),
    ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    ui.Paint()..filterQuality = FilterQuality.medium,
  );
  final image = await recorder.endRecording().toImage(size, size);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}
