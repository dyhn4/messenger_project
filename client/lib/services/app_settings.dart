import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app_platform.dart';
import 'download_storage.dart';
import 'startup_registry.dart'
    if (dart.library.js_interop) 'startup_registry_stub.dart';

const _kDownloadWithoutAsking = 'settings_download_without_asking';
const _kDownloadFolder = 'settings_download_folder';
const _kOpenFolderAfterDownload = 'settings_open_folder_after_download';
const _kThemeMode = 'settings_theme_mode';
const _kMessagePreviewMode = 'settings_message_preview_mode';
const _kTeamSwitchStyle = 'settings_team_switch_style';
const _kAlwaysOnTop = 'settings_always_on_top';
const _kWindowOpacity = 'settings_window_opacity';
const _kSendWithShiftEnter = 'settings_send_with_shift_enter';
const _kAutoLockOnSleep = 'settings_auto_lock_on_sleep';
const _kAppLocked = 'settings_app_locked';
const _kFlashTaskbarWhenFocused = 'settings_flash_taskbar_when_focused';
const _kFlashWindowFrame = 'settings_flash_window_frame';
const _kStickerCategoryOrder = 'settings_sticker_category_order';
const _kTextScale = 'settings_text_scale';
const _kFontFamily = 'settings_font_family';

/// "글꼴"(화면 설정, Windows 전용) 값 — PC에 깔려 있는 시스템 글꼴 이름을 그대로 쓴다(새
/// 글꼴 파일을 번들하지 않음, 고를 수 있는 전체 목록은 services/system_fonts.dart가 그때그때
/// 그 PC에서 직접 받아온다). 안드로이드는 이 이름들이 없어서 설정 자체를 숨긴다
/// (settings_screen.dart). 빈 문자열이 "시스템 기본"이다. 채팅 내용과 방 목록에만 적용되고
/// (widgets/chat_font_scope.dart) 그 외 화면(설정·관리자 콘솔 등)은 항상 기본 모습이다.
String fontFamilyLabel(String family) => family.isEmpty ? '시스템 기본' : family;

/// 옛한글(고어) 자모 조합 글리프 — 기본 폰트(Roboto 등)에는 없어서 네모(tofu)로 보인다.
/// pubspec.yaml에 번들된 폰트(SIL OFL 1.1, assets/fonts/OFL.txt 참고) — 앱 전체 기본 테마
/// (main.dart)와, 채팅·방 목록에서 직접 고른 글꼴(widgets/chat_font_scope.dart) 양쪽 다
/// 이 글꼴을 폴백으로 얹어서 어느 글꼴을 쓰든 옛한글이 깨지지 않는다.
const oldHangulFontFamily = 'NanumBarunGothicYetHangul';

/// 모바일(안드로이드 스타일) 레이아웃으로 바뀌는 창 폭 기준(home_screen.dart의
/// wideBreakpoint=700)보다 확실히 더 좁게 줄일 수 있도록 하는 최소 창 크기 — 사용자가
/// 창을 직접 끌어서 줄이면 이 앱의 기존 반응형 레이아웃이 자동으로 모바일 화면으로
/// 바뀐다("미니보기"는 별도 기능이 아니라 이 최소 크기 제한을 완화하는 것으로 충분하다).
const minWindowSize = Size(350, 600);

/// "텍스트 크기"(화면 설정) 스텝퍼의 범위·간격 — 80%~150%를 10%씩. 1.0(100%)이 기본값이고
/// 가운데 알약을 누르면 바로 이 값으로 돌아간다(settings_screen.dart).
const minTextScale = 0.8;
const maxTextScale = 1.5;
const textScaleStep = 0.1;

/// 알림에 메시지 내용을 얼마나 보여줄지 — [all]은 지금까지의 기본 동작(비밀 대화 제외 전부
/// 원문 미리보기), [publicTopicOnly]는 공개 토픽방만 원문을 보여주고 그 외(그룹/DM/비공개
/// 토픽)는 아래 [none]과 동일하게 가린다, [none]은 항상 "새 메시지가 있습니다"만 보여준다.
/// 비밀 대화는 이 설정과 무관하게 항상 가려진다(session.dart의 기존 규칙).
enum MessagePreviewMode { all, publicTopicOnly, none }

/// 창 왼쪽 위에서 팀을 바꾸는 방식 — 드롭다운(지금 팀만 보이고 눌러서 고름) 또는
/// 탭(속한 팀을 전부 한 줄로 늘어놓고 눌러서 바로 전환).
enum TeamSwitchStyle { dropdown, tabs }

/// 삼선 메뉴 "설정"의 환경설정 상태: 시작 시 자동 실행(Windows 레지스트리로 실제 등록/해제)과
/// 파일 다운로드 관련 값. SharedPreferences에 저장하고, 자동 실행 여부는 레지스트리 값의
/// 실제 존재 여부로 판단한다(다른 방법으로 꺼졌어도 UI가 항상 실제 상태를 반영하도록).
class AppSettings extends ChangeNotifier {
  late SharedPreferences _prefs;

  bool launchAtStartup = false;
  bool downloadWithoutAsking = false;
  String downloadFolder = '';
  bool openFolderAfterDownload = true;

  /// 화면 테마 — 화이트(기본) 또는 다크. 예전의 "시스템 설정을 따름"은 화이트로 읽는다.
  ThemeMode themeMode = ThemeMode.light;
  MessagePreviewMode messagePreviewMode = MessagePreviewMode.all;
  TeamSwitchStyle teamSwitchStyle = TeamSwitchStyle.dropdown;
  bool alwaysOnTop = false;
  double windowOpacity = 1.0;

  /// 글자 크기 배율(1.0 = 100%, 기본) — 글꼴 설정과 같은 곳(채팅 내용의 메시지·댓글 본문, 방 이름)에만
  /// widgets/chat_font_scope.dart의 ChatFont가 MediaQuery.textScaler로 적용한다. 그 밖의 화면은 항상 기본 크기.
  double textScale = 1.0;

  /// 글꼴(화면 설정, Windows 전용) — 시스템 글꼴 이름, 빈 문자열이면 시스템 기본.
  String fontFamily = '';

  /// 메시지 전송 키 — false(기본)면 Enter로 전송·Shift+Enter로 줄바꿈, true면 그 반대.
  bool sendWithShiftEnter = false;

  /// 절전 모드(또는 화면 꺼짐)에 들어가면 메신저를 잠글지(PC 전용 — app_lock.dart).
  bool autoLockOnSleep = false;

  /// 지금 잠겨 있는지 — 비밀번호를 넣어 풀 때까지 유지된다. 앱을 껐다 켜도 잠긴 채로 떠야
  /// 하므로 저장해 둔다.
  bool appLocked = false;

  /// 창이 이미 포커스돼 있을 때(= 메신저를 보고 있는 중)도, 지금 보고 있는 방이 아닌 다른
  /// 방에 메시지가 오면 그 방을 열 때까지 작업표시줄을 깜빡일지 — false(기본)면 창을 보고
  /// 있으면 안 깜빡인다(notification_service.dart의 _flashWindowsTaskbar).
  bool flashTaskbarWhenFocused = false;

  /// 알림이 올 때 작업표시줄 버튼과 함께 창 테두리(제목 표시줄)도 깜빡일지 — true(기본)면 같이
  /// 깜빡이고, false면 작업표시줄 버튼만 깜빡인다(notification_service.dart의 _flash).
  bool flashWindowFrame = true;

  /// 채팅 입력창 이모티콘 목록의 세트 탭 순서(이름으로 기억 — widgets/category_tab_row.dart를
  /// 꾹 눌러서 끌면 바뀐다, sticker_picker.dart). 빈 목록이면 기본 순서(서버 세트 먼저, 그 뒤
  /// 기본 이모지 세트). 새로 생긴 세트(아직 이 목록에 없는 이름)는 끌어서 넣기 전까지 그
  /// 기본 순서 자리에 그대로 끼어 보인다.
  List<String> stickerCategoryOrder = const [];

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    downloadWithoutAsking = _prefs.getBool(_kDownloadWithoutAsking) ?? false;
    // 안드로이드는 폴더를 고르지 않고 늘 공용 Download/TangoTalk에 저장한다(download_storage.dart).
    downloadFolder = AppPlatform.isAndroid
        ? await androidDownloadFolder()
        : _prefs.getString(_kDownloadFolder) ?? _defaultDownloadFolder();
    openFolderAfterDownload = _prefs.getBool(_kOpenFolderAfterDownload) ?? true;
    themeMode = _themeModeFromName(_prefs.getString(_kThemeMode));
    messagePreviewMode = _messagePreviewModeFromName(
      _prefs.getString(_kMessagePreviewMode),
    );
    teamSwitchStyle = _prefs.getString(_kTeamSwitchStyle) == 'tabs'
        ? TeamSwitchStyle.tabs
        : TeamSwitchStyle.dropdown;
    alwaysOnTop = _prefs.getBool(_kAlwaysOnTop) ?? false;
    windowOpacity = _prefs.getDouble(_kWindowOpacity) ?? 1.0;
    sendWithShiftEnter = _prefs.getBool(_kSendWithShiftEnter) ?? false;
    autoLockOnSleep = _prefs.getBool(_kAutoLockOnSleep) ?? false;
    appLocked = _prefs.getBool(_kAppLocked) ?? false;
    flashTaskbarWhenFocused =
        _prefs.getBool(_kFlashTaskbarWhenFocused) ?? false;
    flashWindowFrame = _prefs.getBool(_kFlashWindowFrame) ?? true;
    stickerCategoryOrder =
        _prefs.getStringList(_kStickerCategoryOrder) ?? const [];
    textScale = (_prefs.getDouble(_kTextScale) ?? 1.0).clamp(
      minTextScale,
      maxTextScale,
    );
    fontFamily = _prefs.getString(_kFontFamily) ?? '';
    if (AppPlatform.isWindows) {
      launchAtStartup = readStartupPath() != null;
      // 창 자체의 실제 속성(항상 위로/불투명도)이라 위젯 재빌드만으론 반영이 안 되고, 매번
      // 앱을 켤 때마다 여기서 직접 적용해줘야 한다(테마 등 다른 값과 다른 점).
      await windowManager.setMinimumSize(minWindowSize);
      await windowManager.setAlwaysOnTop(alwaysOnTop);
      await windowManager.setOpacity(windowOpacity);
    }
    notifyListeners();
  }

  ThemeMode _themeModeFromName(String? name) =>
      name == 'dark' ? ThemeMode.dark : ThemeMode.light;

  MessagePreviewMode _messagePreviewModeFromName(String? name) =>
      switch (name) {
        'publicTopicOnly' => MessagePreviewMode.publicTopicOnly,
        'none' => MessagePreviewMode.none,
        _ => MessagePreviewMode.all,
      };

  String _defaultDownloadFolder() {
    final home =
        AppPlatform.environment['USERPROFILE'] ??
        AppPlatform.environment['HOME'] ??
        '';
    return home.isEmpty ? '' : '$home${AppPlatform.pathSeparator}Downloads';
  }

  Future<void> setLaunchAtStartup(bool value) async {
    if (AppPlatform.isWindows) {
      if (value) {
        writeStartupPath(AppPlatform.resolvedExecutable);
      } else {
        deleteStartupPath();
      }
    }
    launchAtStartup = value;
    notifyListeners();
  }

  /// 저장 위치를 묻지 않고 [downloadFolder]에 바로 저장하는지 — 안드로이드는 늘 바로 저장한다.
  bool get savesWithoutAsking =>
      downloadFolder.isNotEmpty &&
      (AppPlatform.isAndroid || downloadWithoutAsking);

  Future<void> setDownloadWithoutAsking(bool value) async {
    downloadWithoutAsking = value;
    await _prefs.setBool(_kDownloadWithoutAsking, value);
    notifyListeners();
  }

  Future<void> setDownloadFolder(String path) async {
    if (AppPlatform.isAndroid) return; // 안드로이드는 Download/TangoTalk 고정.
    downloadFolder = path;
    await _prefs.setString(_kDownloadFolder, path);
    notifyListeners();
  }

  Future<void> setOpenFolderAfterDownload(bool value) async {
    openFolderAfterDownload = value;
    await _prefs.setBool(_kOpenFolderAfterDownload, value);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode value) async {
    themeMode = value;
    await _prefs.setString(_kThemeMode, value.name);
    notifyListeners();
  }

  Future<void> setMessagePreviewMode(MessagePreviewMode value) async {
    messagePreviewMode = value;
    await _prefs.setString(_kMessagePreviewMode, value.name);
    notifyListeners();
  }

  Future<void> setTeamSwitchStyle(TeamSwitchStyle value) async {
    teamSwitchStyle = value;
    await _prefs.setString(_kTeamSwitchStyle, value.name);
    notifyListeners();
  }

  Future<void> setSendWithShiftEnter(bool value) async {
    sendWithShiftEnter = value;
    await _prefs.setBool(_kSendWithShiftEnter, value);
    notifyListeners();
  }

  Future<void> setAutoLockOnSleep(bool value) async {
    autoLockOnSleep = value;
    await _prefs.setBool(_kAutoLockOnSleep, value);
    notifyListeners();
  }

  Future<void> setFlashTaskbarWhenFocused(bool value) async {
    flashTaskbarWhenFocused = value;
    await _prefs.setBool(_kFlashTaskbarWhenFocused, value);
    notifyListeners();
  }

  Future<void> setFlashWindowFrame(bool value) async {
    flashWindowFrame = value;
    await _prefs.setBool(_kFlashWindowFrame, value);
    notifyListeners();
  }

  /// [minTextScale]~[maxTextScale] 밖의 값은 그 끝으로 붙인다(스텝퍼가 끝에서 더 못 가게
  /// 막아두지만, 혹시 몰라 여기서도 한 번 더 막는다).
  Future<void> setTextScale(double value) async {
    textScale = value.clamp(minTextScale, maxTextScale);
    await _prefs.setDouble(_kTextScale, textScale);
    notifyListeners();
  }

  /// [fontFamilyOptions]에 없는 값은 조용히 "시스템 기본"으로 저장한다.
  Future<void> setFontFamily(String value) async {
    fontFamily = value;
    await _prefs.setString(_kFontFamily, fontFamily);
    notifyListeners();
  }

  Future<void> setStickerCategoryOrder(List<String> order) async {
    stickerCategoryOrder = order;
    await _prefs.setStringList(_kStickerCategoryOrder, order);
    notifyListeners();
  }

  Future<void> setAppLocked(bool value) async {
    if (appLocked == value) return;
    appLocked = value;
    await _prefs.setBool(_kAppLocked, value);
    notifyListeners();
  }

  Future<void> setAlwaysOnTop(bool value) async {
    alwaysOnTop = value;
    if (AppPlatform.isWindows) await windowManager.setAlwaysOnTop(value);
    await _prefs.setBool(_kAlwaysOnTop, value);
    notifyListeners();
  }

  /// 슬라이더를 끄는 동안의 실시간 미리보기는 settings_screen.dart가
  /// windowManager.setOpacity를 직접 불러서 처리한다(저장 전이라 여기서 값을 확정 짓지
  /// 않기 위함) — 이 메서드는 "저장하기"를 눌렀을 때만 호출되어 실제로 값을 확정/저장한다.
  Future<void> setWindowOpacity(double value) async {
    windowOpacity = value;
    if (AppPlatform.isWindows) await windowManager.setOpacity(value);
    await _prefs.setDouble(_kWindowOpacity, value);
    notifyListeners();
  }

  /// 다운로드 완료 후 "폴더 열기"를 골랐을 때 호출(Windows 전용, 그 외 플랫폼은 아무 것도 안 함).
  Future<void> openDownloadFolder() async {
    if (!AppPlatform.isWindows || downloadFolder.isEmpty) return;
    // 이름만 주면 현재 폴더에 심어 둔 explorer.exe가 대신 실행될 수 있어 전체 경로로 부른다(download_storage.dart와 같은
    // 방식 — 검토 S32).
    final root = AppPlatform.environment['SystemRoot'] ?? r'C:\Windows';
    await Process.start('$root\\explorer.exe', [downloadFolder]);
  }
}
