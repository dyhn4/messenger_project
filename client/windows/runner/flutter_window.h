#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // PC가 절전에 들어가거나 화면이 꺼질 때 Dart에 알리는 채널 — 환경설정의 "자동 잠금"
  // (lib/services/app_lock.dart)이 받아서 메신저를 잠근다.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      power_channel_;
  HPOWERNOTIFY display_notify_ = nullptr;

  // 비밀번호 칸에 포커스가 있는 동안 한글 입력기(IME)를 끄는 채널 — 일반 Windows 비밀번호 칸처럼
  // 한/영 상태와 상관없이 영문으로 입력되게 한다(lib/services/password_ime.dart).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> ime_channel_;

  void NotifyPower(const char* event);
  void SetLatinOnly(bool latin_only);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
