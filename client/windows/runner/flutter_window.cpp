#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "desktop_multi_window/desktop_multi_window_plugin.h"

namespace {

// GUID_CONSOLE_DISPLAY_STATE — 화면 켜짐/꺼짐/어두워짐. 헤더의 DEFINE_GUID는 선언만 있어서
// (initguid.h 순서에 따라 링크 오류가 난다) 값을 직접 둔다.
constexpr GUID kConsoleDisplayState = {
    0x6fe69556,
    0x704a,
    0x47a0,
    {0x8f, 0x24, 0xc2, 0x8d, 0x93, 0x6f, 0xda, 0x47}};

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  // "프로젝트" 창처럼 desktop_multi_window로 만드는 서브 창은 별도 엔진이라, 새로 만들어질
  // 때마다 이 콜백이 불려서 그 서브 창 엔진에도 똑같이 플러그인을 등록해줘야 한다(안 그러면
  // 서브 창에서 shared_preferences 등 플러그인 호출이 전부 MissingPluginException).
  DesktopMultiWindowSetWindowCreatedCallback([](void *controller) {
    auto *flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController *>(controller);
    auto *registry = flutter_view_controller->engine();
    RegisterPlugins(registry);
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // "자동 잠금" — 절전(PBT_APMSUSPEND)과 화면 꺼짐을 Dart에 알린다. 요즘 노트북의 "최신 대기
  // 모드(Modern Standby)"는 절전에 들어가도 PBT_APMSUSPEND를 보내지 않고 화면만 끄므로, 화면
  // 꺼짐 알림도 같이 받는다(창이 트레이로 숨어 있어도 최상위 창이라 둘 다 온다).
  power_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "tangotalk/power",
          &flutter::StandardMethodCodec::GetInstance());
  display_notify_ = RegisterPowerSettingNotification(
      GetHandle(), &kConsoleDisplayState, DEVICE_NOTIFY_WINDOW_HANDLE);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (display_notify_) {
    UnregisterPowerSettingNotification(display_notify_);
    display_notify_ = nullptr;
  }
  power_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_POWERBROADCAST:
      if (wparam == PBT_APMSUSPEND) {
        NotifyPower("suspend");
      } else if (wparam == PBT_POWERSETTINGCHANGE) {
        const auto* setting =
            reinterpret_cast<const POWERBROADCAST_SETTING*>(lparam);
        // 0 = 꺼짐, 1 = 켜짐, 2 = 어두워짐. 등록하자마자 지금 상태(켜짐)가 한 번 오므로 꺼짐만 본다.
        if (setting && IsEqualGUID(setting->PowerSetting, kConsoleDisplayState) &&
            setting->DataLength >= sizeof(DWORD) &&
            *reinterpret_cast<const DWORD*>(setting->Data) == 0) {
          NotifyPower("displayOff");
        }
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::NotifyPower(const char* event) {
  if (power_channel_) power_channel_->InvokeMethod(event, nullptr);
}
