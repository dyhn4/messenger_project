import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

// 웹 빌드에서 받은 첨부를 브라우저로 넘긴다 — 웹에는 다운로드 폴더나 "기본 앱으로 열기"가 없어서
// 내려받기는 브라우저 다운로드로, 열기는 새 탭으로 대신한다. 네이티브 빌드는 browser_files_stub.dart.

/// [bytes]를 [fileName]으로 브라우저 다운로드한다(아이폰 Safari는 "다운로드" 확인 창이 뜬다).
void downloadBytes(Uint8List bytes, String fileName) {
  final url = _objectUrl(bytes, fileName);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  _revokeLater(url);
}

/// [bytes]를 새 탭으로 연다 — 사진·PDF·동영상·글 파일은 브라우저가 바로 보여주고, 못 보여주는
/// 형식은 브라우저가 알아서 내려받는다. 팝업이 막혀서 탭을 못 열면 그냥 내려받는다.
void openBytes(Uint8List bytes, String fileName) {
  final url = _objectUrl(bytes, fileName);
  final opened = web.window.open(url, '_blank');
  if (opened == null) {
    web.URL.revokeObjectURL(url);
    downloadBytes(bytes, fileName);
    return;
  }
  _revokeLater(url);
}

String _objectUrl(Uint8List bytes, String fileName) {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: _mimeTypeOf(fileName)),
  );
  return web.URL.createObjectURL(blob);
}

/// 새 탭이 다 읽어 가기 전에 주소를 지우면 빈 화면이 되니 넉넉히 기다렸다가 지운다.
void _revokeLater(String url) {
  Future<void>.delayed(
    const Duration(minutes: 1),
    () => web.URL.revokeObjectURL(url),
  );
}

/// 새 탭이 형식을 알아보게 붙이는 MIME 타입 — 모르는 확장자는 브라우저가 내려받게 둔다.
String _mimeTypeOf(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final ext = dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    'svg' => 'image/svg+xml',
    'pdf' => 'application/pdf',
    'mp4' => 'video/mp4',
    'mov' => 'video/quicktime',
    'webm' => 'video/webm',
    'mp3' => 'audio/mpeg',
    'm4a' => 'audio/mp4',
    'wav' => 'audio/wav',
    'txt' || 'log' || 'csv' => 'text/plain;charset=utf-8',
    'json' => 'application/json',
    _ => 'application/octet-stream',
  };
}
