import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import '../../l10n/tr.dart';

// 웹 빌드용 — 화면 캡처는 Win32(GDI)로 화면을 찍는 Windows 전용 기능이다(capture_window.dart 참고).
// 공개 API 모양만 맞추고, 캡처를 시작하면 바로 실패 사유를 돌려준다.

const kCaptureWindowType = 'capture';

class CaptureOutcome {
  final String action;
  final File? file;
  final String? error;
  const CaptureOutcome(this.action, this.file, {this.error});
}

Future<CaptureOutcome?> startScreenCapture({
  required bool hideMessenger,
}) async => CaptureOutcome(
  'cancel',
  null,
  error: tr('화면 캡처는 PC(Windows) 앱에서만 쓸 수 있습니다.'),
);

Future<void> runCaptureWindow(
  WindowController controller,
  Map<String, dynamic> args,
) async {}
