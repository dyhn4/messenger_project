import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

class _ThumbnailRequest {
  final Uint8List bytes;
  final int maxDimension;
  final int quality;
  const _ThumbnailRequest(this.bytes, this.maxDimension, this.quality);
}

Uint8List _generateThumbnailSync(_ThumbnailRequest req) {
  final decoded = img.decodeImage(req.bytes);
  if (decoded == null) return req.bytes; // 디코딩 실패 — 호출자가 원본을 그대로 쓰게 둔다.

  // 카메라 사진의 EXIF 회전 정보를 반영해서, 원본은 세로인데 썸네일만 옆으로 누워 보이는
  // 일이 없게 한다.
  final oriented = img.bakeOrientation(decoded);

  final isWide = oriented.width >= oriented.height;
  final resized = isWide
      ? img.copyResize(
          oriented,
          width: req.maxDimension < oriented.width
              ? req.maxDimension
              : oriented.width,
        )
      : img.copyResize(
          oriented,
          height: req.maxDimension < oriented.height
              ? req.maxDimension
              : oriented.height,
        );

  return Uint8List.fromList(img.encodeJpg(resized, quality: req.quality));
}

/// 원본 이미지에서 채팅 버블 미리보기용 축소 JPEG 썸네일을 만든다. 무거운 디코드/리사이즈/
/// 재인코딩은 별도 isolate(compute)에서 돌려서 큰 사진을 골라도 UI가 멈추지 않는다. 실패하면
/// null — 호출자는 썸네일 없이 원본만 보내면 된다(버블 미리보기가 원본을 그대로 쓰게 됨).
Future<Uint8List?> generateThumbnail(
  Uint8List originalBytes, {
  // 채팅 버블 미리보기가 가로 650px까지 커져서(attachment_widgets.dart의
  // kChatImageMaxWidth) 예전 480px로는 뿌옇게 보인다. 고해상도 화면(devicePixelRatio 2)
  // 에서도 또렷하도록 1300px로 만든다 — 예전에 보낸 이미지의 썸네일은 그대로 480px이라
  // 살짝 부드럽게 보일 수 있다(다시 만들지는 않는다).
  int maxDimension = 1300,
  int quality = 72,
}) async {
  try {
    return await compute(
      _generateThumbnailSync,
      _ThumbnailRequest(originalBytes, maxDimension, quality),
    );
  } catch (_) {
    return null;
  }
}
