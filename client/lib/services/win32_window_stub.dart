// 웹 빌드용 — 찾을 Win32 창이 없으니 늘 0(없음)이고 나머지는 아무것도 안 한다(win32_window.dart 참고).

int findMainWindow() => 0;

int foregroundWindow() => 0;

void restoreAndFocusWindow(int hwnd) {}

void flashWindow(
  int hwnd, {
  required bool stop,
  required bool forced,
  required bool frame,
}) {}
