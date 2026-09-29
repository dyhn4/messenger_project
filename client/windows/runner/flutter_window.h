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

  void NotifyPower(const char* event);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
