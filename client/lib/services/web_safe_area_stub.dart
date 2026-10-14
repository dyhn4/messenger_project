// 네이티브 빌드용 — 안전 영역은 운영체제가 MediaQuery로 알려 준다. 웹 구현은 web_safe_area_web.dart.
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show EdgeInsets;

final ValueListenable<EdgeInsets> webSafeAreaInsets = ValueNotifier(
  EdgeInsets.zero,
);

void enableWebSafeArea() {}
