import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';

import 'app_platform.dart';

/// 안드로이드에서 다운로드한 파일이 모이는 폴더 — 휴대폰 공용 Download 아래의 이 이름.
const kAndroidDownloadSubfolder = 'TangoTalk';

/// MainActivity.kt와 짝을 이루는 채널(공용 Download 경로 · 저장 권한 · 미디어 스캔).
const _channel = MethodChannel('tangotalk/storage');

/// 안드로이드의 다운로드 폴더(공용 Download/TangoTalk) 전체 경로.
///
/// 안드로이드는 폴더를 고르게 하지 않는다 — 안드로이드 11부터 폴더 선택 창에서 Download 자체를
/// 고를 수 없고(OS 제한), Download 밖의 폴더는 저장 권한 없이 파일을 만들 수 없어서다.
/// 공용 Download 경로는 기기·사용자(업무 프로필 등)마다 달라서 OS에 물어본다.
Future<String> androidDownloadFolder() async {
  String? base;
  try {
    base = await _channel.invokeMethod<String>('downloadsDir');
  } catch (_) {
    // 채널이 없는 곳(백그라운드 알림 처리 등)에서는 가장 흔한 경로로 대신한다.
  }
  return '${base ?? '/storage/emulated/0/Download'}/$kAndroidDownloadSubfolder';
}

/// 알림 등에 보여줄 경로 — 안드로이드는 "/storage/emulated/0/"을 떼고 "Download/…"부터 보인다.
String displayDownloadPath(String path) {
  if (!AppPlatform.isAndroid) return path;
  final i = path.indexOf('/Download/');
  return i < 0 ? path : path.substring(i + 1);
}

/// [folder]에 [fileName]으로 [bytes]를 저장하고 실제로 저장된 경로를 돌려준다.
///
/// 같은 이름이 이미 있으면 **덮어쓰지 않고** "이름 (1).확장자", "이름 (2).확장자" … 로 비는 이름을
/// 찾는다. [reuseIdentical]이면(파일 열기·원본 보기처럼 "보려고" 받는 경우) 내용까지 똑같은 파일이
/// 이미 있을 때 새로 만들지 않고 그 파일을 돌려준다 — 같은 파일을 열 때마다 사본이 쌓이지 않게.
/// 폴더가 없으면 만든다. 안드로이드는 10 이하에서만 저장 권한을 먼저 받고, 저장한 뒤 미디어
/// 스캔을 걸어 "파일"/"다운로드" 앱에 바로 보이게 한다.
Future<String> writeDownloadFile({
  required String folder,
  required String fileName,
  required List<int> bytes,
  bool reuseIdentical = false,
}) async {
  if (AppPlatform.isAndroid && !await _ensureAndroidWritePermission()) {
    throw const FileSystemException('저장 권한이 없어 다운로드할 수 없습니다.');
  }
  await Directory(folder).create(recursive: true);

  final sep = AppPlatform.pathSeparator;
  final dot = fileName.lastIndexOf('.');
  final base = dot > 0 ? fileName.substring(0, dot) : fileName;
  final ext = dot > 0 ? fileName.substring(dot) : '';
  String candidate(int i) =>
      i == 0 ? '$folder$sep$fileName' : '$folder$sep$base ($i)$ext';

  FileSystemException? lastError;
  for (var i = 0; i < 50; i++) {
    final path = candidate(i);
    final existing = File(path);
    if (existing.existsSync()) {
      if (reuseIdentical && _sameContent(existing, bytes)) return path;
      continue;
    }
    try {
      await File(path).writeAsBytes(bytes, flush: true);
      if (AppPlatform.isAndroid) unawaited(_scan(path));
      return path;
    } on FileSystemException catch (e) {
      // 안드로이드는 다른 앱(또는 다시 설치하기 전의 이 앱)이 만든 같은 이름의 파일이 이 앱에는
      // 안 보이는 채로 있을 수 있다 — 그 이름으로는 쓰기가 실패하니 다음 번호로 넘어간다.
      if (!AppPlatform.isAndroid) rethrow;
      lastError = e;
    }
  }
  throw lastError ?? FileSystemException('저장할 이름을 찾지 못했습니다.', folder);
}

bool _sameContent(File file, List<int> bytes) {
  try {
    return file.lengthSync() == bytes.length &&
        listEquals(file.readAsBytesSync(), bytes);
  } catch (_) {
    return false; // 못 읽으면(남의 파일 등) 다른 파일로 본다.
  }
}

/// 받아 둔 파일을 기기의 기본 앱으로 연다. 안드로이드는 file:// 주소를 다른 앱에 넘기는 걸 OS가
/// 막아서(7.0+) open_file이 FileProvider로 감싼 주소로 넘긴다. PC는 탐색기에서 더블클릭한 것과
/// 같다(ShellExecute).
Future<void> openLocalFile(String path) async {
  final result = await OpenFile.open(path);
  switch (result.type) {
    case ResultType.done:
      return;
    case ResultType.noAppToOpen:
      throw const FileSystemException('이 파일을 열 수 있는 앱이 없습니다.');
    case ResultType.fileNotFound:
      throw const FileSystemException('파일을 찾을 수 없습니다.');
    case ResultType.permissionDenied:
      throw const FileSystemException('파일을 열 권한이 없습니다.');
    case ResultType.error:
      throw FileSystemException('파일을 열지 못했습니다.', result.message);
  }
}

/// 안드로이드 10 이하는 공용 Download에 쓰려면 저장 권한이 필요하다(11부터는 필요 없어서
/// 네이티브 쪽이 바로 true를 돌려준다).
Future<bool> _ensureAndroidWritePermission() async {
  try {
    return await _channel.invokeMethod<bool>('requestWritePermission') ?? false;
  } on MissingPluginException {
    return true; // 채널이 없으면 그냥 써 본다 — 안 되면 쓰기에서 오류가 난다.
  }
}

Future<void> _scan(String path) async {
  try {
    await _channel.invokeMethod<void>('scanFile', {'path': path});
  } catch (_) {
    // 스캔은 보이기 좋으라고 하는 것뿐 — 실패해도 파일은 이미 저장돼 있다.
  }
}
