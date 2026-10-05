import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

// "Windows 시작 시 자동 실행"(app_settings.dart) — HKCU\Software\Microsoft\Windows\CurrentVersion\Run
// 레지스트리 값을 읽고 쓴다. 웹 빌드에는 dart:ffi가 없어서 startup_registry_stub.dart가 대신 쓰인다.

const _kRunKeyPath = 'Software\\Microsoft\\Windows\\CurrentVersion\\Run';
const _kRunValueName = 'MessengerClient';

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

String? readStartupPath() {
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

void writeStartupPath(String exePath) {
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

void deleteStartupPath() {
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
