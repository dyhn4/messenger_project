import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'download_storage.dart' show webViewableMimeType;

// 웹 빌드에서 받은 첨부를 브라우저로 넘긴다 — 웹에는 다운로드 폴더나 "기본 앱으로 열기"가 없어서
// 내려받기는 브라우저 다운로드로, 열기는 새 탭으로 대신한다. 네이티브 빌드는 browser_files_stub.dart.
//
// 새 탭에 여는 blob: 주소는 앱과 같은 출처다 — 그 안에서 스크립트가 돌면 앱의 로그인 토큰을 읽을 수
// 있다. 그래서 스크립트를 품을 수 있는 형식(svg·html·xml …)은 탭으로 열지 않고, 내려받을 때도 그
// 형식을 붙이지 않는다([webViewableMimeType]).

/// [bytes]를 [fileName]으로 브라우저 다운로드한다(아이폰 Safari는 "다운로드" 확인 창이 뜬다).
void downloadBytes(Uint8List bytes, String fileName) {
  // 안전한 형식이 아니면 그냥 바이트로 붙인다 — 확인 창의 "보기"(아이폰 Safari) 등으로 브라우저가
  // 그 자리에서 열어도 svg·html로 해석되지 않게.
  final url = _objectUrl(
    bytes,
    webViewableMimeType(fileName) ?? 'application/octet-stream',
  );
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  _revokeLater(url);
}

/// [bytes]를 새 탭으로 연다 — 사진·PDF·동영상·소리·글 파일처럼 브라우저가 스크립트 없이 보여 주는
/// 형식만 열고, 그 밖의 형식(svg·html·xml·모르는 형식)은 내려받는다. 팝업이 막혀서 탭을 못 열어도
/// 내려받는다.
void openBytes(Uint8List bytes, String fileName) {
  final type = webViewableMimeType(fileName);
  if (type == null) {
    downloadBytes(bytes, fileName);
    return;
  }
  final url = _objectUrl(bytes, type);
  // 창 옵션에 'noopener'를 주면 탭이 열려도 늘 null이 돌아와 팝업이 막혔는지 알 수 없다 — 그래서
  // 옵션 없이 열고, 연 다음에 새 탭에서 이 창으로 거슬러 오는 길(opener)을 끊는다.
  final opened = web.window.open(url, '_blank');
  if (opened == null) {
    web.URL.revokeObjectURL(url);
    downloadBytes(bytes, fileName);
    return;
  }
  opened.opener = null;
  _revokeLater(url);
}

String _objectUrl(Uint8List bytes, String type) => web.URL.createObjectURL(
  web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: type)),
);

/// 새 탭이 다 읽어 가기 전에 주소를 지우면 빈 화면이 되니 넉넉히 기다렸다가 지운다.
void _revokeLater(String url) {
  Future<void>.delayed(
    const Duration(minutes: 1),
    () => web.URL.revokeObjectURL(url),
  );
}
