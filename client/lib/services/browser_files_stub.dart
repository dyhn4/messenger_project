import 'dart:typed_data';

// 네이티브 빌드용 — 브라우저가 없으니 부르지 않는다(호출부가 kIsWeb일 때만 쓴다). 웹 구현은
// browser_files_web.dart.

void downloadBytes(Uint8List bytes, String fileName) =>
    throw UnsupportedError('웹에서만 쓸 수 있습니다.');

void openBytes(Uint8List bytes, String fileName) =>
    throw UnsupportedError('웹에서만 쓸 수 있습니다.');
