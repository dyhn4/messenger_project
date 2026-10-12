// 이미지를 시스템 클립보드에 복사한다(첨부 이미지 더보기의 "복사") — PC·모바일 앱은 clipboard_image_io.dart,
// 웹 앱은 브라우저 Clipboard API를 쓰는 clipboard_image_web.dart.
export 'clipboard_image_io.dart'
    if (dart.library.js_interop) 'clipboard_image_web.dart';
