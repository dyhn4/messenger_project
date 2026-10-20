#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <optional>
#include <string>

#include "flutter_window.h"
#include "utils.h"
#include "app_links/app_links_plugin_c_api.h"

namespace {

// app_links 플러그인이 받는 WM_COPYDATA의 표시(app_links_plugin.h의 APPLINK_MSG_ID) — 공개 헤더에 없어 같은 값을 쓴다.
constexpr ULONG_PTR kAppLinkMessageId = WM_USER + 2;

// UTF-8 글을 주소의 쿼리 값으로 쓸 수 있게 %XX로 바꾼다(영문·숫자와 -_.~만 그대로).
std::string PercentEncode(const std::string& utf8) {
  static const char kHex[] = "0123456789ABCDEF";
  std::string out;
  for (unsigned char c : utf8) {
    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
        (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' ||
        c == '~') {
      out.push_back(static_cast<char>(c));
    } else {
      out.push_back('%');
      out.push_back(kHex[c >> 4]);
      out.push_back(kHex[c & 0xF]);
    }
  }
  return out;
}

// 탐색기 "보내기 → TangoTalk"(설치 프로그램이 SendTo 폴더에 만든 바로가기 — 인자 "--share" 뒤에 고른 파일 경로들)이면
// tangotalk://share?file=…&file=… 링크. 아니면 없음. 앱(share_intake.dart)이 같은 모양을 읽는다.
std::optional<std::string> ShareLinkFromCommandLine() {
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) return std::nullopt;
  std::optional<std::string> link;
  if (argc >= 3 && wcscmp(argv[1], L"--share") == 0) {
    std::string url = "tangotalk://share?";
    for (int i = 2; i < argc; ++i) {
      if (i > 2) url += "&";
      url += "file=" + PercentEncode(Utf8FromUtf16(argv[i]));
    }
    link = url;
  }
  ::LocalFree(argv);
  return link;
}

// 이미 떠 있는 이 앱의 창(트레이로 숨은 것 포함) — app_links의 SendAppLinkToInstance와 같은 방법으로 찾는다.
HWND FindRunningInstance() {
  struct State {
    HWND found;
    wchar_t exe[MAX_PATH];
  };
  State s = {};
  ::GetModuleFileNameW(nullptr, s.exe, MAX_PATH);
  ::EnumWindows(
      [](HWND hwnd, LPARAM lp) -> BOOL {
        auto* s = reinterpret_cast<State*>(lp);
        wchar_t cls[64] = {};
        ::GetClassNameW(hwnd, cls, 64);
        if (_wcsicmp(cls, L"FLUTTER_RUNNER_WIN32_WINDOW") != 0) return TRUE;
        DWORD pid = 0;
        ::GetWindowThreadProcessId(hwnd, &pid);
        HANDLE h = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
        if (!h) return TRUE;
        wchar_t exe[MAX_PATH] = {};
        DWORD len = MAX_PATH;
        ::QueryFullProcessImageNameW(h, 0, exe, &len);
        ::CloseHandle(h);
        if (_wcsicmp(exe, s->exe) == 0) {
          s->found = hwnd;
          return FALSE;
        }
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&s));
  return s.found;
}

// "보내기" 링크를 떠 있는 창에 넘기고 그 창을 앞으로 가져온다. 떠 있는 창이 없거나 넘기지 못했으면 false — 그러면 새로 띄우고
// 앱이 시작 인자로 읽는다.
bool ForwardShareToInstance(const std::string& link) {
  HWND hwnd = FindRunningInstance();
  if (!hwnd) return false;
  COPYDATASTRUCT cds = {};
  cds.dwData = kAppLinkMessageId;
  cds.cbData = static_cast<DWORD>(link.size() + 1);
  cds.lpData = const_cast<char*>(link.c_str());
  DWORD_PTR result = FALSE;
  LRESULT sent = ::SendMessageTimeout(hwnd, WM_COPYDATA, 0,
                                      reinterpret_cast<LPARAM>(&cds),
                                      SMTO_ABORTIFHUNG, 5000, &result);
  if (sent == 0 || result != TRUE) return false;
  WINDOWPLACEMENT place = {sizeof(WINDOWPLACEMENT)};
  ::GetWindowPlacement(hwnd, &place);
  ::ShowWindow(hwnd, place.showCmd == SW_SHOWMAXIMIZED ? SW_SHOWMAXIMIZED
                     : place.showCmd == SW_SHOWMINIMIZED ? SW_RESTORE
                                                         : SW_NORMAL);
  ::SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0,
                 SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE);
  ::SetForegroundWindow(hwnd);
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // 탐색기 "보내기 → TangoTalk" — 이미 떠 있는 창이 있으면 고른 파일들을 그 창에 넘기고 끝낸다(창을 두 개 띄우지 않게).
  // 없으면 아래에서 평소처럼 띄우고, 앱이 시작 인자(--share 뒤의 경로들)를 읽는다.
  if (auto share = ShareLinkFromCommandLine()) {
    if (ForwardShareToInstance(*share)) return EXIT_SUCCESS;
  } else if (SendAppLinkToInstance()) {
    // 초대 링크(tangotalk://pair)를 다시 눌렀을 때, 이미 떠 있는 창이 있으면 그 창으로
    // 링크를 넘기고(포그라운드로도 가져와줌) 이 새 프로세스는 바로 종료한다 — 창을
    // 두 개 띄우지 않기 위함. 없으면 false를 반환하고 아래에서 평소처럼 새로 띄운다.
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"TangoTalk", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
