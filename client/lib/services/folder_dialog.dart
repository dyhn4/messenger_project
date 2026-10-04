import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

/// 파일 고르기 대화상자의 결과 — 파일을 골랐으면 [files], 파일을 고르지 않고 [열기]를 눌렀으면 그때 열려 있던 폴더
/// [folder]. 둘 중 하나만 있다.
class FilesOrFolder {
  final List<String> files;
  final String? folder;
  const FilesOrFolder.files(this.files) : folder = null;
  const FilesOrFolder.folder(String this.folder) : files = const [];
}

/// 대화상자의 파일 이름 칸에 미리 넣어 두는 글자 — 파일을 고르지 않고 [열기]를 누르면 이 이름이 그대로 돌아오고, 그러면
/// 지금 열려 있는 폴더를 고른 것으로 본다(Windows 열기 대화상자는 폴더와 파일을 함께 고르는 모드가 없어 쓰는 방법).
const folderPickPlaceholder = '폴더 선택';

/// [path]가 "파일 없이 [열기]"의 결과(폴더 안의 [folderPickPlaceholder])인지 — 그렇다면 그 폴더 경로, 아니면 null.
@visibleForTesting
String? folderFromPlaceholderPath(String path) {
  final cut = path.lastIndexOf(Platform.pathSeparator);
  if (cut < 0) return null;
  final name = path.substring(cut + 1).trim();
  if (name != folderPickPlaceholder) return null;
  final dir = path.substring(0, cut);
  // 드라이브 맨 위(C:)면 C:\ 로.
  return dir.endsWith(':') ? '$dir${Platform.pathSeparator}' : dir;
}

/// Windows 열기 대화상자 — 파일을 여러 개 고르거나, 파일을 고르지 않고 [열기]를 눌러 지금 폴더를 고른다(Windows 전용).
/// 취소하면 null. 대화상자는 다른 isolate에서 띄운다 — 떠 있는 동안 앱 화면이 멈추지 않게(file_picker와 같은 방식).
Future<FilesOrFolder?> pickFilesOrFolder({String? title}) async {
  if (!Platform.isWindows) return null;
  final paths = await compute(_showDialog, title ?? '파일 또는 폴더 선택');
  if (paths == null || paths.isEmpty) return null;
  if (paths.length == 1) {
    final folder = folderFromPlaceholderPath(paths.single);
    if (folder != null) return FilesOrFolder.folder(folder);
    // 파일 이름 칸에 폴더 경로를 직접 적고 [열기]를 눌렀을 때.
    if (await Directory(paths.single).exists()) {
      return FilesOrFolder.folder(paths.single);
    }
  }
  final files = [
    for (final p in paths)
      if (await File(p).exists()) p,
  ];
  return files.isEmpty ? null : FilesOrFolder.files(files);
}

/// 대화상자를 띄우고 고른 경로들을 돌려준다(취소면 null) — compute로 다른 isolate에서 돈다.
List<String>? _showDialog(String title) {
  var hr = CoInitializeEx(
    nullptr,
    COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE,
  );
  if (FAILED(hr)) return null;
  try {
    final dialog = FileOpenDialog.createInstance();
    try {
      final options = calloc<Uint32>();
      try {
        hr = dialog.getOptions(options);
        if (FAILED(hr)) return null;
        // 이름 칸의 [folderPickPlaceholder]가 "없는 파일"이라 거절되지 않게 FILEMUSTEXIST는 빼고 NOVALIDATE를 켠다.
        final value =
            (options.value & ~FOS_FILEMUSTEXIST) |
            FOS_ALLOWMULTISELECT |
            FOS_FORCEFILESYSTEM |
            FOS_PATHMUSTEXIST |
            FOS_NOVALIDATE |
            FOS_NOCHANGEDIR;
        hr = dialog.setOptions(value);
        if (FAILED(hr)) return null;
      } finally {
        free(options);
      }
      final titlePtr = title.toNativeUtf16();
      final namePtr = folderPickPlaceholder.toNativeUtf16();
      try {
        dialog.setTitle(titlePtr);
        dialog.setFileName(namePtr);
      } finally {
        free(titlePtr);
        free(namePtr);
      }

      hr = dialog.show(GetForegroundWindow());
      if (FAILED(hr)) return null; // 취소

      final arrayPtr = calloc<Pointer<COMObject>>();
      try {
        hr = dialog.getResults(arrayPtr);
        if (FAILED(hr)) return null;
        final items = IShellItemArray(arrayPtr.cast());
        final paths = <String>[];
        final count = calloc<Uint32>();
        try {
          if (FAILED(items.getCount(count))) return null;
          for (var i = 0; i < count.value; i++) {
            final itemPtr = calloc<Pointer<COMObject>>();
            try {
              if (FAILED(items.getItemAt(i, itemPtr))) continue;
              final item = IShellItem(itemPtr.cast());
              final name = calloc<Pointer<Utf16>>();
              try {
                if (SUCCEEDED(item.getDisplayName(SIGDN_FILESYSPATH, name))) {
                  paths.add(name.value.toDartString());
                  CoTaskMemFree(name.value);
                }
              } finally {
                free(name);
                item.release();
              }
            } finally {
              free(itemPtr);
            }
          }
        } finally {
          free(count);
          items.release();
        }
        return paths;
      } finally {
        free(arrayPtr);
      }
    } finally {
      dialog.release();
    }
  } finally {
    CoUninitialize();
  }
}

/// [path] 폴더를 윈도우 탐색기로 연다. 열었으면 null, 못 열면 사용자에게 보일 까닭. PC(Windows)가 아니면 열 수 없다.
Future<String?> openFolderInExplorer(String path) async {
  if (!Platform.isWindows) return 'PC(Windows)에서 열 수 있는 경로입니다.';
  try {
    if (!await Directory(path).exists()) {
      return '이 PC에서 폴더를 찾을 수 없습니다: $path';
    }
    await Process.start('explorer.exe', [path]);
    return null;
  } catch (e) {
    return '폴더를 열지 못했습니다: $e';
  }
}
