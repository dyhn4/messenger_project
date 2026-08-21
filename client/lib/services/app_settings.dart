import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart';

const _kRunKeyPath = 'Software\\Microsoft\\Windows\\CurrentVersion\\Run';
const _kRunValueName = 'MessengerClient';

const _kDownloadWithoutAsking = 'settings_download_without_asking';
const _kDownloadFolder = 'settings_download_folder';
const _kOpenFolderAfterDownload = 'settings_open_folder_after_download';

/// 삼선 메뉴 "설정"의 환경설정 상태: 시작 시 자동 실행(Windows 레지스트리로 실제 등록/해제)과
/// 파일 다운로드 관련 값. SharedPreferences에 저장하고, 자동 실행 여부는 레지스트리 값의
/// 실제 존재 여부로 판단한다(다른 방법으로 꺼졌어도 UI가 항상 실제 상태를 반영하도록).
class AppSettings extends ChangeNotifier {
  late SharedPreferences _prefs;

  bool launchAtStartup = false;
  bool downloadWithoutAsking = false;
  String downloadFolder = '';
  bool openFolderAfterDownload = true;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    downloadWithoutAsking = _prefs.getBool(_kDownloadWithoutAsking) ?? false;
    downloadFolder = _prefs.getString(_kDownloadFolder) ?? _defaultDownloadFolder();
    openFolderAfterDownload = _prefs.getBool(_kOpenFolderAfterDownload) ?? true;
    if (Platform.isWindows) launchAtStartup = _readStartupPath() != null;
    notifyListeners();
  }

  String _defaultDownloadFolder() {
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';
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

  Future<void> setDownloadWithoutAsking(bool value) async {
    downloadWithoutAsking = value;
    await _prefs.setBool(_kDownloadWithoutAsking, value);
    notifyListeners();
  }

  Future<void> setDownloadFolder(String path) async {
    downloadFolder = path;
    await _prefs.setString(_kDownloadFolder, path);
    notifyListeners();
  }

  Future<void> setOpenFolderAfterDownload(bool value) async {
    openFolderAfterDownload = value;
    await _prefs.setBool(_kOpenFolderAfterDownload, value);
    notifyListeners();
  }

  // ---- Windows 레지스트리(HKCU\Software\Microsoft\Windows\CurrentVersion\Run) ----

  int? _openRunKey(int access) {
    final keyPtr = TEXT(_kRunKeyPath);
    final hKeyPtr = calloc<IntPtr>();
    try {
      final status = RegOpenKeyEx(HKEY_CURRENT_USER, keyPtr, 0, access, hKeyPtr);
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
        var status = RegQueryValueEx(hKey, valueNamePtr, nullptr, typePtr, nullptr, sizePtr);
        if (status != ERROR_SUCCESS || sizePtr.value == 0) return null;
        final buffer = calloc<Uint8>(sizePtr.value);
        try {
          status = RegQueryValueEx(hKey, valueNamePtr, nullptr, typePtr, buffer, sizePtr);
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
        RegSetValueEx(hKey, valueNamePtr, 0, REG_SZ, dataPtr.cast<Uint8>(), (quoted.length + 1) * 2);
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
