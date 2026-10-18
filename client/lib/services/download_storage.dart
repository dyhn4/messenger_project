import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';

import 'app_platform.dart';
import 'browser_files.dart';
import '../l10n/tr.dart';

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

/// 아이폰의 다운로드 폴더 — 앱의 Documents 폴더. Info.plist의 UIFileSharingEnabled·LSSupportsOpeningDocumentsInPlace로
/// "파일" 앱의 "나의 iPhone > TangoTalk"에 그대로 보인다(아이폰은 다른 앱의 폴더에 쓸 수 없어서 폴더를 고르지 않는다).
Future<String> iosDownloadFolder() async =>
    (await getApplicationDocumentsDirectory()).path;

/// 휴대폰의 다운로드 폴더 — 안드로이드는 공용 Download/TangoTalk([androidDownloadFolder]), 아이폰은 앱의 Documents
/// ([iosDownloadFolder]).
Future<String> mobileDownloadFolder() =>
    AppPlatform.isIOS ? iosDownloadFolder() : androidDownloadFolder();

/// 알림 등에 보여줄 경로 — 안드로이드는 "/storage/emulated/0/"을 떼고 "Download/…"부터 보인다. 아이폰은 "파일" 앱에서
/// 찾는 이름으로 보인다.
String displayDownloadPath(String path) {
  if (AppPlatform.isIOS) return tr('파일 앱 > 나의 iPhone > TangoTalk');
  if (!AppPlatform.isAndroid) return path;
  final i = path.indexOf('/Download/');
  return i < 0 ? path : path.substring(i + 1);
}

/// [folder]에 [fileName]으로 [bytes]를 저장하고 실제로 저장된 경로를 돌려준다.
///
/// [fileName]은 첨부를 보낸 사람이 정한 이름이라 그대로 쓰지 않는다 — [savedFileName]으로 다듬은
/// 이름으로, [folder] 바로 아래에만 쓴다. 돌려주는 파일에는 "인터넷에서 받은 파일" 표시를 붙인다
/// ([markFromInternet], Windows). [markAsDownloaded]가 false면 붙이지 않는다 — 남이 보낸 첨부가
/// 아니라 서버가 내 요청으로 만들어 준 파일(대화 내보내기의 엑셀 — 글자 칸만 담는다)이라, 붙이면
/// 열 때마다 제한된 보기로 열려 "편집 사용"을 눌러야 하는 번거로움만 생긴다.
///
/// 같은 이름이 이미 있으면 **덮어쓰지 않고** "이름 (1).확장자", "이름 (2).확장자" … 로 비는 이름을
/// 찾는다. [reuseIdentical]이면(파일 열기·원본 보기처럼 "보려고" 받는 경우) 내용까지 똑같은 파일이
/// 이미 있을 때 새로 만들지 않고 그 파일을 돌려준다 — 같은 파일을 열 때마다 사본이 쌓이지 않게.
/// 그 파일에도 표시를 다시 붙인다(표시를 붙이지 않던 예전 버전이 받아 둔 파일일 수 있다).
/// 폴더가 없으면 만든다. 안드로이드는 10 이하에서만 저장 권한을 먼저 받고, 저장한 뒤 미디어
/// 스캔을 걸어 "파일"/"다운로드" 앱에 바로 보이게 한다 — 이 앱만의 폴더([downloadTempFolder])는
/// 권한 없이 쓸 수 있고 다른 앱에 보일 일도 없어서 둘 다 하지 않는다.
///
/// Windows는 이름 길이를 UTF-16 칸으로 세어 줄이는데([safeFileName]), 폴더가 이름을 UTF-8 바이트로
/// 세는 곳(리눅스 NAS의 공유 폴더 등)이라 이름이 너무 길다고 거절당하면 바이트로 줄인 이름으로 한 번
/// 더 써 본다.
Future<String> writeDownloadFile({
  required String folder,
  required String fileName,
  required List<int> bytes,
  bool reuseIdentical = false,
  bool markAsDownloaded = true,
}) async {
  final name = savedFileName(fileName);
  if (kIsWeb) return _webWrite(name, bytes, toOpen: reuseIdentical);
  // 쓸 수 없는 폴더(빈 폴더 등)면 폴더를 만들거나 권한을 묻기 전에 여기서 멈춘다.
  _pathInFolder(folder, name);
  final shared = AppPlatform.isAndroid && !_isAppPrivateFolder(folder);
  if (shared && !await _ensureAndroidWritePermission()) {
    throw FileSystemException(tr('저장 권한이 없어 다운로드할 수 없습니다.'));
  }
  await Directory(folder).create(recursive: true);

  Future<String> writeAs(String savedName) => _writeNumbered(
    folder,
    savedName,
    bytes,
    reuseIdentical: reuseIdentical,
    markAsDownloaded: markAsDownloaded,
    shared: shared,
  );
  try {
    return await writeAs(name);
  } on FileSystemException catch (e) {
    // 리눅스 NAS(ext4·btrfs를 Samba로 공유한 폴더)는 이름 한 칸을 UTF-8 255바이트까지만 받아서, UTF-16
    // 칸으로 세어 줄인 한글 이름은 85글자쯤부터 거절한다. 어느 폴더가 그런지는 써 보기 전에는 모르고
    // 처음부터 바이트로 세면 NTFS에서도 한글 이름이 3분의 1로 줄어서, 거절당했을 때만 바이트로 줄인
    // 이름(안드로이드와 같은 길이)으로 한 번 더 쓴다. 번호도 그 이름으로 처음부터 다시 찾는다 — 같은
    // 첨부를 또 받거나 보려고 다시 받으면 그 이름으로 저장해 둔 파일이 있다.
    if (!_isNameTooLong(e)) rethrow;
    final inBytes = _savedFileName(fileName, utf16: false);
    // 바이트로 세도 같은 이름(ASCII 이름 등)이면 또 거절당한다.
    if (inBytes == name) rethrow;
    return writeAs(inBytes);
  }
}

/// Windows가 이름이 너무 길다고 거절한 오류인지 — ERROR_FILENAME_EXCED_RANGE(206)는 SMB 서버(Samba
/// 등)가 이름이 너무 길다고 답할 때(NT_STATUS_NAME_TOO_LONG), ERROR_INVALID_NAME(123)은 파일 시스템이
/// 그 길이의 이름 칸을 받지 못한다고 답할 때(STATUS_OBJECT_NAME_INVALID) 난다. 이름을 UTF-16 칸으로
/// 세는 곳([_countsUtf16])에서만 본다 — 그 밖은 처음부터 바이트로 줄였다.
bool _isNameTooLong(FileSystemException e) =>
    _countsUtf16 && const {206, 123}.contains(e.osError?.errorCode);

/// [folder]에 다듬은 이름 [name]으로 [bytes]를 쓴다 — 같은 이름이 있으면 번호를 붙인다
/// ([writeDownloadFile]).
Future<String> _writeNumbered(
  String folder,
  String name,
  List<int> bytes, {
  required bool reuseIdentical,
  required bool markAsDownloaded,
  required bool shared,
}) async {
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  // 번호 붙인 이름은 이미 다듬은 이름에서 나왔으니 다시 다듬지 않는다 — 길이 제한에 걸려 다시
  // 줄이면 붙인 번호가 잘려 나가 모든 후보가 같은 이름이 된다.
  String candidate(int i) =>
      _pathInFolder(folder, i == 0 ? name : '$base ($i)$ext');

  FileSystemException? lastError;
  for (var i = 0; i < 50; i++) {
    final path = candidate(i);
    final existing = File(path);
    if (existing.existsSync()) {
      if (reuseIdentical && _sameContent(existing, bytes)) {
        if (markAsDownloaded) await markFromInternet(path);
        return path;
      }
      continue;
    }
    try {
      await File(path).writeAsBytes(bytes, flush: true);
      if (markAsDownloaded) await markFromInternet(path);
      if (shared) unawaited(_scan(path));
      return path;
    } on FileSystemException catch (e) {
      // 안드로이드는 다른 앱(또는 다시 설치하기 전의 이 앱)이 만든 같은 이름의 파일이 이 앱에는
      // 안 보이는 채로 있을 수 있다 — 그 이름으로는 쓰기가 실패하니 다음 번호로 넘어간다.
      if (!AppPlatform.isAndroid) rethrow;
      lastError = e;
    }
  }
  throw lastError ?? FileSystemException(tr('저장할 이름을 찾지 못했습니다.'), folder);
}

bool _sameContent(File file, List<int> bytes) {
  try {
    return file.lengthSync() == bytes.length &&
        listEquals(file.readAsBytesSync(), bytes);
  } catch (_) {
    return false; // 못 읽으면(남의 파일 등) 다른 파일로 본다.
  }
}

/// 받아 둔 파일을 기기의 기본 앱으로 연다 — 열었으면 null. 안드로이드는 file:// 주소를 다른 앱에
/// 넘기는 걸 OS가 막아서(7.0+) open_file이 FileProvider로 감싼 주소로 넘긴다. PC는 탐색기에서
/// 더블클릭한 것과 같다(ShellExecute).
///
/// 그래서 열기만 해도 실행되는 형식([isRiskyToOpen] — 프로그램·스크립트·바로 가기·설치 파일·
/// html·svg …)은 열지 않는다. 첨부는 보낸 사람이 이름(확장자)을 마음대로 정할 수 있어서, 누르기만
/// 해도 남이 보낸 프로그램이 돌거나 Windows 로그인 정보가 새어 나갈 수 있기 때문이다. 대신 PC는
/// 탐색기에서 그 파일을 골라 보여 주고, 사용자에게 보일 까닭을 돌려준다(호출부가 알림으로 띄운다).
/// 그 밖의 형식은 열되, 저장할 때 붙인 "인터넷에서 받은 파일" 표시([markFromInternet]) 때문에
/// 오피스 문서는 제한된 보기로 열린다.
Future<String?> openLocalFile(String path) async {
  if (kIsWeb) {
    _webOpen(path);
    return null;
  }
  final notice = riskyFileNotice(path);
  if (notice != null) {
    if (AppPlatform.isWindows) await _selectInExplorer(path);
    return notice;
  }
  final result = await OpenFile.open(path);
  switch (result.type) {
    case ResultType.done:
      return null;
    case ResultType.noAppToOpen:
      throw FileSystemException(tr('이 파일을 열 수 있는 앱이 없습니다.'));
    case ResultType.fileNotFound:
      throw FileSystemException(tr('파일을 찾을 수 없습니다.'));
    case ResultType.permissionDenied:
      throw FileSystemException(tr('파일을 열 권한이 없습니다.'));
    case ResultType.error:
      throw FileSystemException(tr('파일을 열지 못했습니다.'), result.message);
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

/// 안드로이드에서 [folder]가 이 앱만의 저장소(/data/… — [downloadTempFolder])인지. 공용 Download는
/// /storage/… 아래다.
bool _isAppPrivateFolder(String folder) => folder.startsWith('/data/');

/// Windows에서 [path]에 "인터넷에서 받은 파일" 표시(Mark of the Web — 브라우저가 받은 파일에 붙이는
/// NTFS의 Zone.Identifier 스트림)를 붙인다. [writeDownloadFile]이 돌려주는 파일(대화 내보내기처럼
/// 서버가 만들어 준 파일은 빼고 — `markAsDownloaded: false`)과, 저장 창으로 받은 파일
/// (attachment_widgets.dart의 saveAttachment)에 붙인다.
///
/// 확장자 목록([isRiskyToOpen])만으로는 다 막을 수 없어서다. 매크로 문서를 흔한 `.doc`·`.xls`로
/// 바꿔 보내면 목록을 지나 그대로 열리고, `.docx`도 안에 적힌 원격 서식·그림을 불러오면서 Windows
/// 로그인 정보(NTLM)를 넘길 수 있다. 이 표시가 있으면 오피스는 확장자와 상관없이 제한된 보기로 열어
/// 원격 내용을 불러오지 않고, 요즘 오피스는 매크로도 아예 막는다. 사용자가 탐색기에서 직접 여는 실행
/// 파일은 SmartScreen 검사를 받고, 최신 Windows는 탐색기 미리 보기 창에서도 이런 파일을 그리지 않는다.
///
/// 표시는 덧붙이는 보호일 뿐이라 못 붙여도(FAT32·exFAT 드라이브처럼 NTFS가 아닌 곳) 그냥 넘어간다.
/// 파일이 없으면(저장 창은 빈 파일을 쓰지 않는다) 표시만 남는 빈 파일이 생기지 않게 아무것도 하지 않는다.
Future<void> markFromInternet(String path) async {
  if (!AppPlatform.isWindows) return;
  try {
    if (!File(path).existsSync()) return;
    await File(
      '$path:Zone.Identifier',
    ).writeAsString('[ZoneTransfer]\r\nZoneId=3\r\n', flush: true);
  } catch (_) {
    // 위와 같이 — 파일은 이미 저장돼 있다.
  }
}

// ── 받은 파일 이름 ───────────────────────────────────────────────────────────────
// 첨부 이름은 보낸 사람이 마음대로 정한다(서버는 형식만 본다). `..\..\…\Startup\x.bat` 같은 이름을
// 그대로 폴더 경로에 붙이면 받은 사람이 누르기만 해도 다운로드 폴더 밖(시작 프로그램 폴더 등)에
// 파일이 생긴다. 그래서 받은 이름으로 이 기기에 파일을 만드는 곳(다운로드·열어 보기·비밀 대화의 임시
// 파일·전체/앨범/할 일 내려받기)은 모두 [writeDownloadFile]을 거치고, 저장 창은 [savedFileName]으로
// 이름을 채운다.

/// 다듬은 이름의 최대 길이 — 파일 시스템이 이름 한 칸을 세는 단위([_countsUtf16])로 잰다.
/// Windows(NTFS)는 UTF-16 255칸, 안드로이드(ext4·f2fs)는 UTF-8 255바이트까지라, 같은 이름이 있을 때
/// 붙이는 " (49)"와 탐색기가 속을 읽는 형식에 덧붙이는 `.txt`([savedFileName])가 들어갈 자리를
/// 남긴다. 장치 이름 앞에 붙이는 `_`는 이 길이 안에 든다([safeFileName]). Windows에서도 폴더가 바이트로
/// 세는 곳이라 거절당하면 바이트로 다시 줄인다([writeDownloadFile]).
const _maxFileNameLength = 200;

/// 이 기기의 파일 시스템이 이름 길이를 UTF-16 칸으로 세는지(Windows) — 아니면 UTF-8 바이트로 센다.
/// 어디서나 바이트로 세면 Windows에서 한글(3바이트) 이름이 NTFS가 허락하는 길이의 3분의 1도 안 되는
/// 66글자에서 잘린다. 웹은 브라우저가 어느 OS에 저장할지 몰라 더 짧게 잘리는 바이트로 센다. 테스트가
/// debugDefaultTargetPlatformOverride로 다른 플랫폼을 흉내 낼 수 있게 그 값이 있으면 먼저 따른다.
bool get _countsUtf16 {
  final override = debugDefaultTargetPlatformOverride;
  return override != null
      ? override == TargetPlatform.windows
      : AppPlatform.isWindows;
}

/// [s]의 길이 — [utf16]이면 UTF-16 칸(Dart 문자열의 길이 그대로), 아니면 UTF-8 바이트.
int _fileNameLength(String s, {required bool utf16}) =>
    utf16 ? s.length : utf8.encode(s).length;

/// 다듬고 남는 게 없을 때 쓰는 이름([safeFileName]).
const _fallbackFileName = '파일';

/// 줄일 때 살려 둘 확장자의 최대 길이(점 포함) — `.searchconnector-ms`처럼 긴 확장자도 살린다.
/// 이보다 길면 확장자가 아니라고 보고 이름 전체를 줄인다.
const _maxExtensionLength = 24;

/// 폴더 구분자 — 받은 이름은 어느 OS에서 왔는지 모르니 플랫폼과 상관없이 둘 다 자른다.
final _separators = RegExp(r'[\\/]');

/// 이름에서 지울 보이지 않는 글자 — 제어 문자(C0·DEL·C1)와 글자 방향을 바꾸는 문자. 방향 문자는
/// `photo\u202Egnp.exe`가 화면에 `photoexe.png`처럼 보이게 하는 데 쓰인다.
final _invisibleChars = RegExp(
  r'[\u0000-\u001F\u007F-\u009F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]',
);

/// Windows가 파일 이름에 못 쓰는 글자 — `_`로 바꾼다. `:`를 막으면 NTFS 대체 데이터 스트림
/// (`a.txt:x.exe`)도 만들 수 없다.
final _reservedChars = RegExp(r'[<>:"/\\|?*]');

/// Windows 장치 이름 — 첫 점 앞이 이 이름이면(`CON`·`NUL.txt`·`COM1.tar.gz`) 파일이 아니라 장치를
/// 가리킨다.
final _deviceName = RegExp(
  r'^(con|prn|aux|nul|conin\$|conout\$|clock\$|com[0-9¹²³]|lpt[0-9¹²³])$',
  caseSensitive: false,
);

/// 받은 파일 이름을 이 기기에 그대로 써도 되는 이름으로 다듬는다.
///
/// - 폴더가 섞인 이름(`..\..\Startup\x.bat`, `/etc/passwd`)은 마지막 칸만 남긴다.
/// - 보이지 않는 글자는 지우고, Windows가 못 쓰는 글자(`<>:"/\|?*`)는 `_`로 바꾼다.
/// - 끝의 점·공백을 떼고, 너무 길면 확장자를 살려서 줄인다.
/// - 장치 이름(`CON`·`NUL.txt` …)이면 앞에 `_`를 붙인다.
///
/// 남는 게 없으면(빈 이름, `.`, `..`) [fallback]. 다듬은 이름을 다시 넣어도 그대로 나온다.
String safeFileName(String name, {String fallback = _fallbackFileName}) =>
    _safeFileName(name, fallback: fallback, utf16: _countsUtf16);

/// [safeFileName] — 길이를 [utf16]이면 UTF-16 칸, 아니면 UTF-8 바이트로 잰다.
String _safeFileName(
  String name, {
  required String fallback,
  required bool utf16,
}) {
  final cleaned = _trimTrailingDotsAndSpaces(
    name
        .split(_separators)
        .last
        .replaceAll(_invisibleChars, '')
        .replaceAll(_reservedChars, '_')
        .trimLeft(),
  );
  final s = _fitFileName(cleaned, utf16: utf16);
  if (s.isEmpty) return fallback;
  // 장치 이름인지는 줄이고 끝의 공백을 뗀 다음에 본다(`CON` 뒤로 공백만 길게 이어진 이름은 줄이면 `CON`이
  // 된다). `_`를 붙여 길이를 넘으면 다시 맞춘다 — 안 그러면 다듬은 이름을 다시 넣었을 때 또 줄어든다
  // (앨범·할 일 내려받기는 다듬은 이름을 [writeDownloadFile]에 넘겨 한 번 더 다듬는다).
  return _deviceName.hasMatch(s.split('.').first.trimRight())
      ? _fitFileName('_$s', utf16: utf16)
      : s;
}

/// 길이 제한에 맞게 줄이고([_truncateFileName]) 끝의 점·공백을 뗀다.
String _fitFileName(String name, {required bool utf16}) =>
    _trimTrailingDotsAndSpaces(_truncateFileName(name, utf16: utf16));

/// 끝에 붙은 점·공백을 뗀다 — Windows가 조용히 떼어 내서(`x.bat.` → `x.bat`) 이름으로 본 확장자와
/// 실제 파일의 확장자가 어긋난다. 정규식(`[\s.]+$`)은 점이 길게 이어진 이름에서 한없이 느려져서
/// (받은 이름은 길이 제한 전이다) 뒤에서부터 직접 센다.
String _trimTrailingDotsAndSpaces(String s) {
  var end = s.length;
  while (end > 0) {
    final c = s[end - 1];
    if (c != '.' && c.trim().isNotEmpty) break;
    end--;
  }
  return s.substring(0, end);
}

/// [name]이 [_maxFileNameLength]보다 길면([utf16] — [_fileNameLength]) 확장자는 두고 앞 이름을
/// 줄인다 — 글자 단위(rune)로 세서 글자 중간(UTF-8의 여러 바이트, UTF-16의 서로게이트 쌍)에서 자르지
/// 않는다.
String _truncateFileName(String name, {required bool utf16}) {
  int length(String s) => _fileNameLength(s, utf16: utf16);
  if (length(name) <= _maxFileNameLength) return name;
  final dot = name.lastIndexOf('.');
  final ext = dot > 0 && name.length - dot <= _maxExtensionLength
      ? name.substring(dot)
      : '';
  var budget = _maxFileNameLength - length(ext);
  final stem = StringBuffer();
  for (final rune in name.substring(0, name.length - ext.length).runes) {
    final size = length(String.fromCharCode(rune));
    if (size > budget) break;
    budget -= size;
    stem.writeCharCode(rune);
  }
  return '$stem$ext';
}

/// 탐색기가 폴더를 보여 주기만 해도 속을 읽는 형식 — 바로 가기·셸 위치·테마 파일은 아이콘·그림
/// 자리에 원격 주소(`\\서버\공유\x.ico`)를 적을 수 있어서, 그 파일이 든 폴더를 탐색기로 보기만 해도
/// (열지 않아도) PC가 그 주소에 접속하며 Windows 로그인 정보(NTLM)를 넘긴다. 이런 버그가 해마다
/// 새로 나온다(.library-ms·.lnk·.theme …).
final _explorerParsedExtensions =
    ('lnk pif url website scf library-ms search-ms searchconnector-ms '
            'settingcontent-ms appcontent-ms theme themepack deskthemepack')
        .split(' ')
        .toSet();

/// 이름 그대로 탐색기가 읽는 폴더 설정 파일(아이콘 자리에 원격 주소를 적을 수 있다).
const _explorerParsedNames = {'desktop.ini', 'autorun.inf'};

/// 받은 첨부를 이 기기에 파일로 둘 때의 이름 — [safeFileName]으로 다듬고, 탐색기가 보기만 해도 속을
/// 읽는 형식([_explorerParsedExtensions])이면 끝에 `.txt`를 붙여 글 파일로 둔다(`x.url` →
/// `x.url.txt`). 막지 않으면 [openLocalFile]이 탐색기로 그 파일을 골라 보여 주는 것이나 "다운로드 후
/// 폴더 열기"가 오히려 로그인 정보가 새는 길이 된다. 메신저로 받은 바로 가기는 받은 PC에서 쓸 데가
/// 없고, 글 파일로 열면 안에 적힌 주소를 볼 수 있다.
///
/// [writeDownloadFile]이 쓰고, 저장 창에 미리 채우는 이름도 이것이다.
String savedFileName(String fileName) =>
    _savedFileName(fileName, utf16: _countsUtf16);

/// [savedFileName] — 길이를 [utf16]이면 UTF-16 칸, 아니면 UTF-8 바이트로 잰다.
String _savedFileName(String fileName, {required bool utf16}) {
  final name = _safeFileName(
    fileName,
    fallback: _fallbackFileName,
    utf16: utf16,
  );
  final lower = name.toLowerCase();
  final dot = lower.lastIndexOf('.');
  final parsed =
      _explorerParsedNames.contains(lower) ||
      (dot >= 0 &&
          _explorerParsedExtensions.contains(lower.substring(dot + 1)));
  return parsed ? '$name.txt' : name;
}

/// [folder]와 [name]을 이은 경로. 이름은 이미 다듬었지만 경로를 만드는 마지막 자리에서 한 번 더
/// 막는다 — 정리해 봐도(`.`·`..`를 풀어도) [folder] 바로 아래가 아니면 쓰지 않고 예외를 낸다.
String _pathInFolder(String folder, String name) {
  if (folder.trim().isEmpty) {
    // 빈 폴더에 이어 붙이면 드라이브 맨 위(\이름)가 된다.
    throw FileSystemException(tr('저장할 폴더가 정해지지 않았습니다.'));
  }
  final sep = AppPlatform.pathSeparator;
  final path = folder.endsWith(sep) ? '$folder$name' : '$folder$sep$name';
  if (!isDirectChildPath(folder, path)) {
    throw FileSystemException(tr('이 이름으로는 저장할 수 없습니다.'), name);
  }
  return path;
}

/// [path]가 [folder] 바로 아래의 항목인지 — 디스크는 보지 않고, 두 경로를 칸으로 나눠 `.`·`..`·
/// 겹친 구분자를 푼 다음 글자로 비교한다.
@visibleForTesting
bool isDirectChildPath(String folder, String path) {
  final dir = _pathSegments(folder);
  final child = _pathSegments(path);
  if (child.length != dir.length + 1) return false;
  // 점·공백뿐인 마지막 칸은 Windows가 끝의 점·공백을 떼어 내면서 폴더 자신(또는 위 폴더)을 가리키게
  // 될 수 있어 받지 않는다.
  if (_trimTrailingDotsAndSpaces(child.last).isEmpty) return false;
  for (var i = 0; i < dir.length; i++) {
    if (dir[i] != child[i]) return false;
  }
  return true;
}

/// 경로를 칸으로 나눈다 — 빈 칸과 `.`은 버리고 `..`은 앞 칸을 지운다. Windows는 `\`와 `/` 둘 다
/// 구분자다.
List<String> _pathSegments(String path) {
  final Pattern separator = AppPlatform.isWindows ? _separators : '/';
  final segments = <String>[];
  for (final s in path.split(separator)) {
    if (s.isEmpty || s == '.') continue;
    if (s == '..') {
      if (segments.isNotEmpty) segments.removeLast();
    } else {
      segments.add(s);
    }
  }
  return segments;
}

/// 받은 이름(또는 경로)의 확장자 — 소문자, 점 없이, 없으면 빈 문자열. [safeFileName]으로 다듬은 뒤에
/// 보므로 실제로 저장되는 이름과 같은 확장자다(끝의 점·공백, 방향 문자, `:` 뒤 스트림 이름 등).
String _extensionOf(String fileName) {
  final name = safeFileName(fileName, fallback: '');
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

// ── 바로 열면 위험한 형식 ─────────────────────────────────────────────────────────

/// 기본 앱으로 열기만 해도 위험한 확장자 — 넉넉하게 잡는다(잘못 걸려도 폴더에서 직접 열면 그만이다).
/// 날마다 주고받는 문서(doc·xls·ppt·docx·hwp·pdf …)는 넣지 않는다 — 그런 문서는 "인터넷에서 받은
/// 파일" 표시([markFromInternet])가 오피스의 보호 기능을 켜는 것에 맡긴다.
final _riskyExtensions = {
  for (final group in const [
    // 프로그램·설치 파일. 안드로이드 apk도 — 이 앱은 업데이트 설치 때문에 설치 권한이 있어서 누르면
    // 바로 설치 화면이 뜬다.
    'exe com scr pif cpl dll ocx sys drv cab msi msp mst msu msix msixbundle '
        'appx appxbundle appinstaller application appref-ms xbap gadget vsix '
        'vsto xll wll ppkg jar jnlp app apk apks apkm xapk ipa dmg pkg mpkg deb '
        'rpm appimage run',
    // 스크립트
    'bat cmd btm bas vb vbs vbe vbp js jse mjs wsf wsh ws wsc sct ps1 ps1xml '
        'ps2 ps2xml psc1 psc2 psm1 psd1 psdm1 cdxml msh msh1 msh2 mshxml '
        'msh1xml msh2xml py pyw pyc pyo pyz pyzw pl rb php ahk au3 sh bash zsh '
        'ksh csh command tool applescript scpt workflow action',
    // 바로 가기·셸 위치·시스템 설정 — 다른 프로그램이나 원격 위치로 넘어가거나 설정·인증서를 바꾼다.
    'lnk url website scf shb shs xnk desktop webloc inetloc fileloc asx '
        'library-ms search-ms searchconnector-ms settingcontent-ms '
        'appcontent-ms rdp ica wsb msc reg inf ins isp theme themepack '
        'deskthemepack cer crt der p7b p7c spc sst stl printerexport diagcab '
        'diagcfg diagpkg',
    // 브라우저·XML로 열리는 형식 — 안에서 스크립트가 돌거나, 원격 자원을 불러오면서 Windows 로그인
    // 정보(NTLM)가 새어 나간다.
    'html htm xhtml xht shtml shtm mht mhtml hta htc asp aspx svg svgz xml '
        'xsl xslt xaml',
    // 오피스 — 매크로를 담는 형식(매크로 문서·서식 파일·쇼·바이너리 통합 문서·퍼블리셔·백업)과
    // 추가 기능, 원격 데이터를 불러오는 엑셀 쿼리·연결(iqy·dqy·rqy·oqy·odc)과 DDE를 부르는 SYLK,
    // 파일을 품어 실행시키는 원노트, OLE 개체 공격에 쓰이는 RTF, 액세스 DB. 오피스의 매크로 차단과
    // 제한된 보기는 "인터넷에서 받은 파일" 표시([markFromInternet])가 있어야 걸리는데, 표시를 붙일 수
    // 없는 곳(FAT32·exFAT 드라이브)도 있고 옛 오피스는 표시가 있어도 버튼 두 번이면 매크로가 돈다 —
    // 그래서 이런 드문 형식은 바로 열지도 않는다.
    'docm dotm dot wbk xlsm xltm xlt xlsb xlam xla xlm pptm potm pot ppam ppa '
        'ppsm pps ppsx sldm pub rtf slk iqy dqy rqy oqy odc one onepkg '
        'ade adp mda mdb mde mdt mdw mdz accda accde accdr '
        'mad maf mag mam maq mar mas mat mau mav maw',
    // 재생 목록·미디어 플레이어 스킨 — 플레이어가 목록에 적힌 원격 주소(\\서버\…)를 불러오면서
    // 로그인 정보가 새고, 스킨은 스크립트를 품는다.
    'm3u m3u8 pls wpl wax wvx wmx wmz wms',
    // 개발 도구 프로젝트 — 비주얼 스튜디오는 프로젝트를 열기만 해도 그 안의 빌드 명령을 돌린다.
    'sln slnx csproj vbproj vcxproj vcproj fsproj proj props targets njsproj '
        'pyproj sqlproj wixproj shproj code-workspace',
    // 디스크 이미지 — 열면 드라이브로 붙고, 그 안의 파일에는 "인터넷에서 받은 파일" 표시가 이어지지
    // 않을 수 있다.
    'iso img vhd vhdx vmdk',
    // 도움말과 그 밖에 Outlook이 첨부로 막는 형식, 안의 링크로 프로그램을 띄울 수 있는 연락처 파일.
    'chm hlp bgi cnt fxp grp hpj its mcf ops osd pcd plg prf prg pst vsmacros '
        'vsw webpnp contact wab',
  ])
    ...group.split(' '),
};

/// 기본 앱으로 열기만 해도 위험한 형식인지 — 받은 이름(또는 경로)의 확장자로만 본다(대소문자와 끝의
/// 점·공백은 따지지 않는다). 이런 파일은 [openLocalFile]이 열지 않는다.
bool isRiskyToOpen(String fileName) {
  final ext = _extensionOf(fileName);
  // `이름.{CLSID}` — 확장자 자리에 COM 개체 번호를 쓰면 Windows가 그 개체(HTA 등)로 연다.
  return ext.startsWith('{') || _riskyExtensions.contains(ext);
}

final _riskyFileNotice = tr('실행될 수 있는 파일이라 바로 열지 않았습니다. 내용을 확인한 뒤 직접 여세요.');

/// [path]를 바로 열면 안 될 때([isRiskyToOpen]) 사용자에게 보일 안내 — 열어도 되면 null.
@visibleForTesting
String? riskyFileNotice(String path) {
  if (!isRiskyToOpen(path)) return null;
  // PC는 탐색기가 그 파일을 골라 보여 준다([openLocalFile]).
  if (AppPlatform.isWindows) return _riskyFileNotice;
  final shown = displayDownloadPath(path);
  // 안드로이드의 공용 Download 밖(비밀 대화 파일을 두는 이 앱만의 임시 폴더)은 "파일" 앱에서 보이지
  // 않는다 — 다운로드해서 보라고 한다.
  return shown == path
      ? tr('실행될 수 있는 파일이라 바로 열지 않았습니다. 다운로드해서 내용을 확인한 뒤 직접 여세요.')
      : '$_riskyFileNotice ($shown)';
}

/// 탐색기를 열어 [path] 파일을 골라 둔 채 보여 준다(Windows).
Future<void> _selectInExplorer(String path) async {
  // 이름만 주면 Windows가 현재 폴더부터 찾는다 — 같은 이름의 파일을 심어 두는 수법을 피해 전체
  // 경로로 부른다.
  final windows = AppPlatform.environment['SystemRoot'] ?? r'C:\Windows';
  try {
    await Process.start('$windows\\explorer.exe', explorerSelectArgs(path));
  } catch (_) {
    // 탐색기를 못 띄워도 파일은 저장돼 있고, 안내 문구는 호출부가 그대로 띄운다.
  }
}

/// 탐색기에서 [path]를 골라 보여 주는 인자. 파일 경로만 넘기면 탐색기가 그 파일을 **연다**(실행한다)
/// — 그래서 늘 `/select,`와 함께 넘긴다. 다만 쉼표는 탐색기가 인자를 나누는 기호이고 공백이 없는
/// 경로는 따옴표 없이 넘어가서, 쉼표가 든 경로는 골라 보이는 대신 그 폴더만 연다.
@visibleForTesting
List<String> explorerSelectArgs(String path) {
  final file = path.replaceAll('/', r'\');
  return file.contains(',') ? [File(file).parent.path] : ['/select,', file];
}

// ── 웹 ──────────────────────────────────────────────────────────────────────────
// 웹에는 다운로드 폴더도 "기본 앱으로 열기"도 없다. 그래서 받기([reuseIdentical] 없이)는 곧바로
// 브라우저 다운로드로, 보려고 받기([reuseIdentical])는 바이트를 잠깐 들고 있다가 이어지는
// [openLocalFile]이 새 탭으로 연다(새 탭에 띄워도 안전한 형식만 — [webViewableMimeType], 나머지는
// 내려받는다) — 호출부는 네이티브와 똑같이 "쓰고 → 연다"를 부르면 된다.
// [folder]는 웹에서 쓰지 않으니 호출부는 빈 문자열을 넘겨도 된다([downloadTempFolder] 참고).

/// 웹에서 새 탭으로 바로 보여 줘도 되는 형식이면 붙일 MIME 타입, 아니면 null(내려받는다 —
/// browser_files_web.dart).
///
/// 새 탭의 blob: 주소는 앱과 같은 출처라서 그 안에서 스크립트가 돌면 앱의 로그인 토큰을 읽을 수
/// 있다. 그래서 브라우저가 스크립트 없이 보여 주는 형식(사진·PDF·동영상·소리)과 글 파일만 연다 —
/// 글 파일은 내용과 상관없이 text/plain으로만 붙여서 안에 HTML이 있어도 글자로 보인다. svg·html·xml
/// 처럼 스크립트를 품을 수 있는 형식과 모르는 형식은 null.
String? webViewableMimeType(String fileName) =>
    switch (_extensionOf(fileName)) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'bmp' => 'image/bmp',
      'pdf' => 'application/pdf',
      'mp4' => 'video/mp4',
      'mov' => 'video/quicktime',
      'webm' => 'video/webm',
      'mp3' => 'audio/mpeg',
      'm4a' => 'audio/mp4',
      'wav' => 'audio/wav',
      'txt' || 'log' || 'csv' || 'json' => 'text/plain;charset=utf-8',
      _ => null,
    };

/// 보려고 받아 둔 첨부(가짜 경로 → 바이트). [openLocalFile]이 열면서 꺼내 간다.
final _webPendingOpens = <String, ({Uint8List bytes, String fileName})>{};
var _webOpenSeq = 0;

String _webWrite(String fileName, List<int> bytes, {required bool toOpen}) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  if (!toOpen) {
    downloadBytes(data, fileName);
    // 이미 내려받은 파일이라 뒤이어 여는(openLocalFile) 일은 없다 — 이름만 돌려준다.
    return fileName;
  }
  final path = 'web-open:${_webOpenSeq++}/$fileName';
  _webPendingOpens[path] = (bytes: data, fileName: fileName);
  return path;
}

void _webOpen(String path) {
  final pending = _webPendingOpens.remove(path);
  if (pending == null) return; // 이미 내려받은 파일 — 다시 열지 않는다.
  openBytes(pending.bytes, pending.fileName);
}

/// "보려고" 받는 파일을 둘 임시 폴더 — 다운로드 폴더를 안 정했을 때와, 평문을 다운로드 폴더에 남기지
/// 않는 비밀 대화 파일. 시스템 임시 폴더 아래 이 앱만 쓰는 폴더(`TangoTalk\open`)다. 임시 폴더 맨
/// 위(%TEMP%)는 설치 프로그램(이 앱의 업데이트 포함)이 파일을 풀어 놓고 실행하는 곳이라, 받은 파일
/// (이름도 내용도 보낸 사람이 정한다)을 거기 두면 그 프로그램 옆에 DLL을 심어 대신 돌게 하거나 그
/// 프로그램이 찾는 파일을 바꿔치기할 수 있다. 폴더는 [writeDownloadFile]이 만든다.
/// 웹은 폴더가 없어 빈 문자열이다([writeDownloadFile]이 웹에서는 폴더를 쓰지 않는다).
Future<String> downloadTempFolder() async {
  if (kIsWeb) return '';
  final sep = AppPlatform.pathSeparator;
  return '${(await getTemporaryDirectory()).path}${sep}TangoTalk${sep}open';
}
