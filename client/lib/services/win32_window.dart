import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart'
    show
        FindWindow,
        GetForegroundWindow,
        SW_RESTORE,
        SetForegroundWindow,
        ShowWindow,
        TEXT;

// 알림(notification_service.dart)이 쓰는 메인 창 찾기·앞으로 가져오기·작업표시줄 깜빡임의 Win32 호출.
// 웹 빌드에는 dart:ffi가 없어서 win32_window_stub.dart가 대신 쓰인다.

/// 메인 창 핸들(못 찾으면 0). "프로젝트"/캡처 같은 보조 창도 창 클래스가 같아서, 제목("TangoTalk")까지
/// 맞춰 먼저 찾고 못 찾을 때만 클래스만으로 찾는다 — 안 그러면 보조 창이 먼저 잡혀서
/// 작업표시줄 깜빡임이 엉뚱한 창에 걸린다.
int findMainWindow() {
  final classNamePtr = TEXT('FLUTTER_RUNNER_WIN32_WINDOW');
  final titlePtr = TEXT('TangoTalk');
  try {
    final byTitle = FindWindow(classNamePtr, titlePtr);
    if (byTitle != 0) return byTitle;
    return FindWindow(classNamePtr, nullptr);
  } finally {
    calloc.free(classNamePtr);
    calloc.free(titlePtr);
  }
}

int foregroundWindow() => GetForegroundWindow();

void restoreAndFocusWindow(int hwnd) {
  ShowWindow(hwnd, SW_RESTORE);
  SetForegroundWindow(hwnd);
}

/// 작업표시줄 버튼(과 [frame]이면 창 테두리)을 깜빡이거나([stop]이면) 멈춘다. [forced]가 아니면
/// 창이 포커스를 받을 때까지, [forced]면 정해진 횟수만큼 깜빡인다.
void flashWindow(
  int hwnd, {
  required bool stop,
  required bool forced,
  required bool frame,
}) {
  final info = calloc<_FLASHWINFO>();
  final target = frame ? _flashwAll : _flashwTray;
  try {
    info.ref
      ..cbSize = sizeOf<_FLASHWINFO>()
      ..hwnd = hwnd
      ..dwFlags = stop
          ? _flashwStop
          : (forced ? target : (target | _flashwTimerNoFg))
      ..uCount = forced ? _flashwForcedCount : 0
      ..dwTimeout = 0;
    _flashWindowEx(info);
  } finally {
    calloc.free(info);
  }
}

// win32 5.x 패키지 바인딩에 FlashWindowEx가 아직 없어서, 여기서만 필요한
// 최소한의 FFI 선언을 직접 추가했다 (다른 Win32 호출은 전부 win32 패키지 것을 그대로 씀).
const _flashwStop = 0x00000000; // 깜빡임 중지(원래 상태로)
const _flashwAll = 0x00000003; // FLASHW_CAPTION | FLASHW_TRAY
const _flashwTray = 0x00000002; // FLASHW_TRAY — 작업표시줄 버튼만(창 테두리는 그대로)
const _flashwTimerNoFg = 0x0000000C; // 포커스를 받을 때까지 계속 깜빡임
// 창이 이미 포커스돼 있을 때(forced) 몇 번 깜빡이고 멈출지 — TIMERNOFG가 못 쓰이니 직접 횟수를 준다.
const _flashwForcedCount = 4;

final class _FLASHWINFO extends Struct {
  @Uint32()
  external int cbSize;
  @IntPtr()
  external int hwnd;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int uCount;
  @Uint32()
  external int dwTimeout;
}

typedef _FlashWindowExNative = Int32 Function(Pointer<_FLASHWINFO>);
typedef _FlashWindowExDart = int Function(Pointer<_FLASHWINFO>);

final _user32 = DynamicLibrary.open('user32.dll');
final _flashWindowEx = _user32
    .lookupFunction<_FlashWindowExNative, _FlashWindowExDart>('FlashWindowEx');
