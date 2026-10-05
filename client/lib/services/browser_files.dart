// 웹 빌드에서 첨부를 브라우저로 내려받거나 새 탭으로 연다(downloadBytes/openBytes). 네이티브에서는
// 부르지 않는다 — 호출부가 kIsWeb으로 가른다.
export 'browser_files_stub.dart'
    if (dart.library.js_interop) 'browser_files_web.dart';
