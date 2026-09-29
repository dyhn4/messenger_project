import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart';
import 'package:window_manager/window_manager.dart';

import 'download_storage.dart';

const _kRunKeyPath = 'Software\\Microsoft\\Windows\\CurrentVersion\\Run';
const _kRunValueName = 'MessengerClient';

const _kDownloadWithoutAsking = 'settings_download_without_asking';
const _kDownloadFolder = 'settings_download_folder';
const _kOpenFolderAfterDownload = 'settings_open_folder_after_download';
const _kThemeMode = 'settings_theme_mode';
const _kMessagePreviewMode = 'settings_message_preview_mode';
const _kTeamSwitchStyle = 'settings_team_switch_style';
const _kAlwaysOnTop = 'settings_always_on_top';
const _kWindowOpacity = 'settings_window_opacity';

/// 모바일(안드로이드 스타일) 레이아웃으로 바뀌는 창 폭 기준(home_screen.dart의
/// wideBreakpoint=700)보다 확실히 더 좁게 줄일 수 있도록 하는 최소 창 크기 — 사용자가
/// 창을 직접 끌어서 줄이면 이 앱의 기존 반응형 레이아웃이 자동으로 모바일 화면으로
/// 바뀐다("미니보기"는 별도 기능이 아니라 이 최소 크기 제한을 완화하는 것으로 충분하다).
const minWindowSize = Size(350, 600);

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
  ThemeMode themeMode = ThemeMode.system;
  MessagePreviewMode messagePreviewMode = MessagePreviewMode.all;
  TeamSwitchStyle teamSwitchStyle = TeamSwitchStyle.dropdown;
  bool alwaysOnTop = false;
  double windowOpacity = 1.0;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    downloadWithoutAsking = _prefs.getBool(_kDownloadWithoutAsking) ?? false;
    // 안드로이드는 폴더를 고르지 않고 늘 공용 Download/TangoTalk에 저장한다(download_storage.dart).
    downloadFolder = Platform.isAndroid
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
    if (Platform.isWindows) {
      launchAtStartup = _readStartupPath() != null;
      // 창 자체의 실제 속성(항상 위로/불투명도)이라 위젯 재빌드만으론 반영이 안 되고, 매번
      // 앱을 켤 때마다 여기서 직접 적용해줘야 한다(테마 등 다른 값과 다른 점).
      await windowManager.setMinimumSize(minWindowSize);
      await windowManager.setAlwaysOnTop(alwaysOnTop);
      await windowManager.setOpacity(windowOpacity);
    }
    notifyListeners();
  }

  ThemeMode _themeModeFromName(String? name) => switch (name) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  MessagePreviewMode _messagePreviewModeFromName(String? name) =>
      switch (name) {
        'publicTopicOnly' => MessagePreviewMode.publicTopicOnly,
        'none' => MessagePreviewMode.none,
        _ => MessagePreviewMode.all,
      };

  String _defaultDownloadFolder() {
    final home =
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    return home.isEmpty ? '' : '$home${Platform.pathSeparator}Downloads';
  }

  Future<void> setLaunchAtStartup(bool value) async {
    if (Platform.isWindows) {
      if (value) {
        _writeStartupPath(Platform.resolvedExecutable);
      } else {
        _deleteStartupPath();
      }
    }
    launchAtStartup = value;
    notifyListeners();
  }

  /// 저장 위치를 묻지 않고 [downloadFolder]에 바로 저장하는지 — 안드로이드는 늘 바로 저장한다.
  bool get savesWithoutAsking =>
      downloadFolder.isNotEmpty &&
      (Platform.isAndroid || downloadWithoutAsking);

  Future<void> setDownloadWithoutAsking(bool value) async {
    downloadWithoutAsking = value;
    await _prefs.setBool(_kDownloadWithoutAsking, value);
    notifyListeners();
  }

  Future<void> setDownloadFolder(String path) async {
    if (Platform.isAndroid) return; // 안드로이드는 Download/TangoTalk 고정.
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

  Future<void> setAlwaysOnTop(bool value) async {
    alwaysOnTop = value;
    if (Platform.isWindows) await windowManager.setAlwaysOnTop(value);
    await _prefs.setBool(_kAlwaysOnTop, value);
    notifyListeners();
  }

  /// 슬라이더를 끄는 동안의 실시간 미리보기는 settings_screen.dart가
  /// windowManager.setOpacity를 직접 불러서 처리한다(저장 전이라 여기서 값을 확정 짓지
  /// 않기 위함) — 이 메서드는 "저장하기"를 눌렀을 때만 호출되어 실제로 값을 확정/저장한다.
  Future<void> setWindowOpacity(double value) async {
    windowOpacity = value;
    if (Platform.isWindows) await windowManager.setOpacity(value);
    await _prefs.setDouble(_kWindowOpacity, value);
    notifyListeners();
  }

  // ---- Windows 레지스트리(HKCU\Software\Microsoft\Windows\CurrentVersion\Run) ----

  int? _openRunKey(int access) {
    final keyPtr = TEXT(_kRunKeyPath);
    final hKeyPtr = calloc<IntPtr>();
    try {
      final status = RegOpenKeyEx(
        HKEY_CURRENT_USER,
        keyPtr,
        0,
        access,
        hKeyPtr,
      );
      if (status != ERROR_SUCCESS) return null;
      return hKeyPtr.value;
    } finally {
      calloc.free(keyPtr);
      calloc.free(hKeyPtr);
    }
  }

  String? _readStartupPath() {
    final hKey = _openRunKey(KEY_QUERY_VALUE);
    if (hKey == null) return null;
    try {
      final valueNamePtr = TEXT(_kRunValueName);
      final typePtr = calloc<Uint32>();
      final sizePtr = calloc<Uint32>();
      try {
        var status = RegQueryValueEx(
          hKey,
          valueNamePtr,
          nullptr,
          typePtr,
          nullptr,
          sizePtr,
        );
        if (status != ERROR_SUCCESS || sizePtr.value == 0) return null;
        final buffer = calloc<Uint8>(sizePtr.value);
        try {
          status = RegQueryValueEx(
            hKey,
            valueNamePtr,
            nullptr,
            typePtr,
            buffer,
            sizePtr,
          );
          if (status != ERROR_SUCCESS) return null;
          return buffer.cast<Utf16>().toDartString();
        } finally {
          calloc.free(buffer);
        }
      } finally {
        calloc.free(valueNamePtr);
        calloc.free(typePtr);
        calloc.free(sizePtr);
      }
    } finally {
      RegCloseKey(hKey);
    }
  }

  void _writeStartupPath(String exePath) {
    final hKey = _openRunKey(KEY_SET_VALUE);
    if (hKey == null) return;
    try {
      final valueNamePtr = TEXT(_kRunValueName);
      final quoted = '"$exePath"';
      final dataPtr = quoted.toNativeUtf16();
      try {
        RegSetValueEx(
          hKey,
          valueNamePtr,
          0,
          REG_SZ,
          dataPtr.cast<Uint8>(),
          (quoted.length + 1) * 2,
        );
      } finally {
        calloc.free(valueNamePtr);
        calloc.free(dataPtr);
      }
    } finally {
      RegCloseKey(hKey);
    }
  }

  void _deleteStartupPath() {
    final hKey = _openRunKey(KEY_SET_VALUE);
    if (hKey == null) return;
    try {
      final valueNamePtr = TEXT(_kRunValueName);
      try {
        RegDeleteValue(hKey, valueNamePtr);
      } finally {
        calloc.free(valueNamePtr);
      }
    } finally {
      RegCloseKey(hKey);
    }
  }

  /// 다운로드 완료 후 "폴더 열기"를 골랐을 때 호출(Windows 전용, 그 외 플랫폼은 아무 것도 안 함).
  Future<void> openDownloadFolder() async {
    if (!Platform.isWindows || downloadFolder.isEmpty) return;
    await Process.start('explorer.exe', [downloadFolder]);
  }
}
