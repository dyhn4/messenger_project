import 'package:flutter/foundation.dart';

import 'web_keyboard_fix_stub.dart'
    if (dart.library.js_interop) 'web_keyboard_fix_web.dart'
    as impl;

/// 안드로이드 웹 앱에서 화상 키보드를 닫은 뒤 화면 아래에 키보드만큼 빈 공간이 남는 것을 되돌린다.
///
/// Flutter 웹 엔진은 입력 중(입력칸에 포커스)일 때 브라우저 크기가 바뀌면 화면 높이는 그대로 두고 키보드 높이만
/// viewInsets로 알린다. 그런데 프레임을 그릴 때마다(handleFrameworkResize) 입력 중이 아니면 화면 높이를 지금 보이는
/// 높이로 조용히 다시 잰다 — 키보드가 떠 있는 채로 포커스를 잠깐 놓았다 다시 잡으면(입력칸 바깥 단추를 터치하면
/// 손가락이 닿는 순간 포커스를 놓고, 단추가 다시 잡는다) 키보드를 뺀 높이가 화면 높이로 들어간다. 그 뒤 뒤로가기로
/// 키보드를 닫으면 다시 입력 중이라 그 줄어든 높이에 묶이고, viewInsets는 음수가 된다.
///
/// 자주 쓰는 입력창은 단추들을 TextFieldTapRegion으로 묶어 이 상황 자체를 피한다(chat_input_bar.dart 등). 이건 그
/// 밖의 경로(검사에 걸려 입력칸으로 되돌아가기, 항목 추가 뒤 새 칸으로 옮기기 등)까지 받치는 안전장치다 — 키보드를
/// 닫았는데 viewInsets가 음수면 입력칸 포커스를 놓고 엔진이 화면 높이를 다시 재게 한다. 웹이 아니거나 안드로이드가
/// 아니면 아무것도 하지 않는다.
void enableWebKeyboardFix() {
  if (kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    impl.enableWebKeyboardFix();
  }
}
