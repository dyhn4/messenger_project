import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;
import '../l10n/tr.dart';

/// 이 브라우저에서 이미지를 클립보드에 복사할 수 있는지 — Clipboard API는 HTTPS(보안 컨텍스트)에서만 있다.
bool get canCopyImageToClipboard =>
    web.window.navigator.has('clipboard') && web.window.has('ClipboardItem');

/// [bytes](원본 이미지 파일 내용)를 클립보드에 이미지로 올린다. 실패하면 예외.
///
/// 브라우저는 클릭 직후(사용자 동작 안)에만 클립보드 쓰기를 허락해서, 원본을 받기 **전에** 곧바로 write를 부르고
/// 내용은 나중에 채워지는 약속(Promise)으로 넘긴다(Safari는 이 방식만 받는다). 브라우저가 받는 이미지 형식은
/// PNG뿐이라 JPEG 등은 캔버스로 PNG로 바꿔서 넘긴다.
Future<void> copyImageToClipboard(Future<Uint8List> bytes) async {
  final png = bytes.then(_toPngBlob);
  final item = web.ClipboardItem(JSObject()..['image/png'] = png.toJS);
  try {
    await web.window.navigator.clipboard.write([item].toJS).toDart;
  } catch (_) {
    await png; // 원본을 못 받았거나 못 바꿨으면 그 오류를 그대로 알린다.
    rethrow;
  }
}

Future<web.Blob> _toPngBlob(Uint8List data) async {
  // createImageBitmap은 EXIF 방향도 반영한다 — 미리보기에 보이는 모양 그대로 복사된다.
  final bitmap = await web.window
      .createImageBitmap(web.Blob([data.toJS].toJS))
      .toDart;
  final canvas = web.HTMLCanvasElement()
    ..width = bitmap.width
    ..height = bitmap.height;
  (canvas.getContext('2d')! as web.CanvasRenderingContext2D).drawImage(
    bitmap,
    0,
    0,
  );
  bitmap.close();
  final done = Completer<web.Blob>();
  canvas.toBlob(
    (web.Blob? blob) {
      if (blob == null) {
        done.completeError(FormatException(tr('이미지를 PNG로 바꾸지 못했습니다.')));
      } else {
        done.complete(blob);
      }
    }.toJS,
    'image/png',
  );
  return done.future;
}
