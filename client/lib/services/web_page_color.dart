import 'package:flutter/painting.dart' show Color;

import 'web_page_color_stub.dart'
    if (dart.library.js_interop) 'web_page_color_web.dart'
    as impl;

/// 웹 페이지 바탕색과 `<meta name="theme-color">`를 앱 화면 바탕색([color] — 테마의 surface)에 맞춘다.
///
/// 아이폰 홈 화면 웹 앱은 상태바(시계·배터리 줄) 뒤를 theme-color로 칠하는데, 그 색(예전엔 남색 고정)이 바로 아래
/// 앱 상단(밝은 앱 바)과 달라 iOS가 둘의 경계를 흐리게 섞어 그리면 그 부분이 뿌옇게 보였다. 같은 색이면 섞여도 티가
/// 나지 않는다. 다크 모드로 바꾸면 따라 바뀐다. 네이티브 빌드에서는 아무것도 하지 않는다.
void syncWebPageColor(Color color) => impl.syncWebPageColor(color);
