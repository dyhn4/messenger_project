import 'dart:convert';
import 'dart:io';

import 'package:client/services/download_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// 첨부 이름은 보낸 사람이 마음대로 정한다 — 받은 이름이 이 기기의 경로가 될 때 폴더 밖에 쓰이거나
// 장치·스트림을 가리키지 않게 다듬는지(download_storage.dart의 safeFileName·savedFileName·
// writeDownloadFile), 이름을 바이트로 세는 폴더(NAS)가 긴 이름을 거절하면 바이트로 줄여 다시 쓰는지,
// 저장한 파일에 "인터넷에서 받은 파일" 표시가 붙는지, 보려고 받는 파일이 이 앱만의 임시 폴더에
// 쓰이는지(downloadTempFolder).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 이름 길이를 세는 단위가 플랫폼마다 달라서(Windows는 UTF-16 칸, 그 밖은 UTF-8 바이트) 두 가지를 다
  /// 본다 — download_storage.dart가 debugDefaultTargetPlatformOverride를 따른다.
  const lengthPlatforms = [TargetPlatform.windows, TargetPlatform.android];
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  /// 짝 없이 남은 서로게이트(쪼개진 이모지)가 있는지 — 짝이 맞으면 runes가 한 글자(0xFFFF 초과)로 묶는다.
  bool hasLoneSurrogate(String s) =>
      s.runes.any((c) => c >= 0xD800 && c <= 0xDFFF);

  group('safeFileName', () {
    test('폴더가 섞인 이름은 마지막 칸만 남긴다', () {
      expect(
        safeFileName(
          r'..\..\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\x.bat',
        ),
        'x.bat',
      );
      expect(safeFileName('../../etc/passwd'), 'passwd');
      expect(safeFileName(r'C:\Windows\System32\evil.dll'), 'evil.dll');
      expect(safeFileName(r'\\attacker\share\x.exe'), 'x.exe');
      expect(safeFileName(r'a/b\c.txt'), 'c.txt');
    });

    test('남는 게 없으면 대신할 이름', () {
      for (final name in [
        '',
        '   ',
        '.',
        '..',
        '...',
        ' . . ',
        'folder/',
        r'a\..',
        '\u202E',
      ]) {
        expect(safeFileName(name), '파일', reason: '"$name"');
      }
      expect(safeFileName('..', fallback: 'image.png'), 'image.png');
    });

    test('Windows가 못 쓰는 글자는 _로 — 대체 데이터 스트림(:)도 못 만든다', () {
      expect(safeFileName('report.txt:evil.exe'), 'report.txt_evil.exe');
      expect(safeFileName('x.exe::\$DATA'), 'x.exe__\$DATA');
      expect(safeFileName('a<b>c"d|e?f*g.txt'), 'a_b_c_d_e_f_g.txt');
    });

    test('제어 문자와 글자 방향을 바꾸는 문자는 지운다', () {
      expect(safeFileName('a\u0000b\nc\td\u007F\u0085.txt'), 'abcd.txt');
      // 화면에는 "photoexe.png"처럼 보이는 실행 파일.
      expect(safeFileName('photo\u202Egnp.exe'), 'photognp.exe');
      expect(safeFileName('\u2066x\u2069.pdf'), 'x.pdf');
    });

    test('앞뒤 공백과 끝의 점은 뗀다(Windows가 조용히 떼는 것과 같게)', () {
      expect(safeFileName('x.bat.'), 'x.bat');
      expect(safeFileName('x.bat . . '), 'x.bat');
      expect(safeFileName('  회의록.docx  '), '회의록.docx');
    });

    test('장치 이름은 확장자가 붙어도 앞에 _를 붙인다', () {
      expect(safeFileName('CON'), '_CON');
      expect(safeFileName('con.txt'), '_con.txt');
      expect(safeFileName('NUL.tar.gz'), '_NUL.tar.gz');
      expect(safeFileName('com1.log'), '_com1.log');
      expect(safeFileName('LPT9'), '_LPT9');
      expect(safeFileName('COM¹.txt'), '_COM¹.txt');
      expect(safeFileName('aux .txt'), '_aux .txt');
      expect(safeFileName('prn.'), '_prn');
      expect(safeFileName('conout\$'), '_conout\$');
      // 장치 이름이 아니다.
      expect(safeFileName('console.txt'), 'console.txt');
      expect(safeFileName('com10.txt'), 'com10.txt');
      expect(safeFileName('nul_report.pdf'), 'nul_report.pdf');
    });

    test('Windows — 너무 긴 이름은 UTF-16 200칸으로, 확장자를 살려서 줄인다', () {
      // NTFS는 이름 한 칸을 UTF-16 255칸까지 쓴다 — 바이트로 세면 한글이 66글자에서 잘린다.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final ascii = safeFileName('${'a' * 300}.pdf');
      expect(ascii, '${'a' * 196}.pdf');
      // 한글도 한 글자가 한 칸.
      expect(safeFileName('${'가' * 100}.docx'), '${'가' * 100}.docx');
      expect(safeFileName('${'가' * 300}.docx'), '${'가' * 195}.docx');
      // 이모지는 2칸(서로게이트 쌍) — 쌍이 쪼개지지 않게 남는 1칸은 비워 둔다.
      final emoji = safeFileName('${'😀' * 120}.jpeg');
      expect(emoji, '${'😀' * 97}.jpeg');
      expect(safeFileName('a${'😀' * 120}.png'), 'a${'😀' * 97}.png');
      expect(hasLoneSurrogate(emoji), isFalse);
      // 확장자처럼 보이지 않게 긴 꼬리는 이름 전체를 줄인다.
      expect(safeFileName('x.${'b' * 300}'), 'x.${'b' * 198}');
      expect(
        safeFileName('${'가' * 30}.${'나' * 300}'),
        '${'가' * 30}.${'나' * 169}',
      );
    });

    test('안드로이드 등 — 너무 긴 이름은 UTF-8 200바이트로 줄인다(글자 중간에서 자르지 않는다)', () {
      // ext4·f2fs는 이름 한 칸이 255바이트까지다.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final ascii = safeFileName('${'a' * 300}.pdf');
      expect(utf8.encode(ascii).length, 200);
      expect(ascii, endsWith('.pdf'));
      // 한글은 3바이트 — ".docx"(5바이트)를 빼고 195바이트 = 65글자.
      expect(safeFileName('${'가' * 100}.docx'), '${'가' * 65}.docx');
      // 이모지는 4바이트(서로게이트 쌍) — 쌍이 쪼개지지 않는다.
      final emoji = safeFileName('${'😀' * 60}.png');
      expect(emoji, '${'😀' * 49}.png');
      expect(hasLoneSurrogate(emoji), isFalse);
      // 확장자처럼 보이지 않게 긴 꼬리는 이름 전체를 줄인다.
      expect(safeFileName('x.${'b' * 300}'), 'x.${'b' * 198}');
      expect(
        utf8.encode(safeFileName('${'가' * 30}.${'나' * 100}')).length,
        lessThanOrEqualTo(200),
      );
    });

    test('장치 이름 앞의 _도 길이 안에 든다 — 붙여서 넘으면 다시 줄인다', () {
      for (final platform in lengthPlatforms) {
        debugDefaultTargetPlatformOverride = platform;
        final device = safeFileName('CON.${'a' * 300}.txt');
        expect(device, '_CON.${'a' * 191}.txt', reason: '$platform');
        // 줄이고 끝의 공백을 떼면 장치 이름이 되는 이름도 걸러 낸다.
        expect(safeFileName('con${' ' * 300}x'), '_con', reason: '$platform');
      }
    });

    test('점·공백이 아주 길게 이어진 이름도 금방 다듬는다', () {
      final watch = Stopwatch()..start();
      expect(safeFileName('${'.' * 200000}x'), '${'.' * 199}x');
      expect(safeFileName('a${'.' * 200000}'), 'a');
      expect(safeFileName('${' .' * 100000}x.txt'), endsWith('.txt'));
      expect(isRiskyToOpen('${'.' * 200000}x'), isFalse);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('평범한 이름은 그대로, 다듬은 이름은 다시 넣어도 그대로', () {
      for (final platform in lengthPlatforms) {
        debugDefaultTargetPlatformOverride = platform;
        for (final name in [
          'photo.png',
          '회의록 (최종).docx',
          '.bashrc',
          'archive.tar.gz',
          'a  b.txt',
          "it's #1 & 50%.xlsx",
        ]) {
          expect(safeFileName(name), name, reason: '$platform $name');
        }
        for (final name in [
          r'..\x.bat.',
          'CON.txt',
          'a:b',
          '${'가' * 100}.docx',
          '${'가' * 300}.docx',
          '${'😀' * 120}.jpeg',
          'a${'😀' * 120}.png',
          ' x ',
          'x.${'b' * 300}',
          '${'가' * 30}.${'나' * 300}',
          // 줄인 뒤 장치 이름이라 `_`를 붙이는 이름 — 붙여서 길이를 넘기면 다시 넣을 때 또 줄어든다.
          'CON.${'a' * 196}.txt',
          'CON.${'가' * 300}.txt',
          'con${' ' * 300}x',
        ]) {
          final once = safeFileName(name);
          expect(safeFileName(once), once, reason: '$platform $name');
        }
      }
    });
  });

  group('savedFileName — 탐색기가 보기만 해도 속을 읽는 형식은 글 파일로', () {
    test('바로 가기·셸 위치·테마 파일과 폴더 설정 파일에는 .txt를 붙인다', () {
      for (final name in [
        'x.url',
        'X.LNK',
        'x.website',
        'x.scf',
        'x.pif',
        'x.library-ms',
        'x.searchConnector-ms',
        'x.search-ms',
        'x.settingcontent-ms',
        'x.theme',
        'x.themepack',
        'x.deskthemepack',
        'desktop.ini',
        'Desktop.INI',
        'autorun.inf',
        '.lnk',
      ]) {
        expect(savedFileName(name), '$name.txt', reason: name);
      }
      // safeFileName으로 다듬은 다음에 본다 — 끝의 점·폴더·방향 문자로 숨겨도 걸린다.
      expect(savedFileName('x.url.'), 'x.url.txt');
      expect(savedFileName(r'..\..\x.lnk'), 'x.lnk.txt');
      expect(savedFileName('x\u202E.url'), 'x.url.txt');
    });

    test('그 밖의 이름은 safeFileName 그대로, 이미 붙였으면 다시 붙이지 않는다', () {
      for (final name in [
        'photo.png',
        'setup.exe',
        'x.inf',
        'my.desktop.ini',
        'url',
        'x.url.txt',
        'x.urlx',
      ]) {
        expect(savedFileName(name), safeFileName(name), reason: name);
      }
      expect(savedFileName('x.url:y'), 'x.url_y');
      expect(savedFileName(savedFileName('x.url')), 'x.url.txt');
    });
  });

  group('isDirectChildPath', () {
    final sep = Platform.pathSeparator;
    String p(List<String> parts) => parts.join(sep);

    test('정리한 경로가 폴더 바로 아래일 때만 true', () {
      final dl = p(['', 'home', 'dl']);
      expect(isDirectChildPath(dl, p([dl, 'x.txt'])), isTrue);
      expect(isDirectChildPath(dl, p([dl, '.', 'x.txt'])), isTrue);
      expect(isDirectChildPath('$dl$sep', '$dl$sep${sep}x.txt'), isTrue);
      expect(isDirectChildPath(dl, p([dl, '..', 'x.txt'])), isFalse);
      expect(isDirectChildPath(dl, p([dl, 'a', '..', '..', 'x.txt'])), isFalse);
      expect(isDirectChildPath(dl, p([dl, 'sub', 'x.txt'])), isFalse);
      expect(isDirectChildPath(dl, p([dl, '..'])), isFalse);
      expect(isDirectChildPath(dl, p([dl, '. .'])), isFalse);
      expect(isDirectChildPath(dl, p(['', 'home', 'other', 'x.txt'])), isFalse);
    });

    test('Windows는 / 와 \\ 둘 다 구분자로 본다', () {
      expect(isDirectChildPath(r'C:\dl', r'C:/dl/x.txt'), isTrue);
      expect(isDirectChildPath(r'C:\dl', r'C:\dl/../x.txt'), isFalse);
      expect(isDirectChildPath(r'C:\', r'C:\x.txt'), isTrue);
    }, skip: !Platform.isWindows);
  });

  group('writeDownloadFile — 받은 이름으로는 폴더 밖에 쓰지 않는다', () {
    late Directory root;
    late String folder;
    String inFolder(String name) => '$folder${Platform.pathSeparator}$name';

    setUp(() {
      root = Directory.systemTemp.createTempSync('safe_file_name_');
      folder = '${root.path}${Platform.pathSeparator}dl';
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('폴더를 거슬러 오르는 이름도 그 폴더 바로 아래에 쓴다', () async {
      expect(
        await writeDownloadFile(
          folder: folder,
          fileName: r'..\..\evil.bat',
          bytes: [1],
        ),
        inFolder('evil.bat'),
      );
      expect(
        await writeDownloadFile(
          folder: folder,
          fileName: '../evil.txt',
          bytes: [2],
        ),
        inFolder('evil.txt'),
      );
      // 한 단계 위(root)에는 다운로드 폴더 말고 아무것도 생기지 않았다.
      expect(root.listSync().map((e) => e.path).toList(), [folder]);
      expect(File(inFolder('evil.bat')).readAsBytesSync(), [1]);
    });

    test('장치 이름·긴 이름도 폴더 안의 파일로, 같은 이름은 번호를 붙인다', () async {
      expect(
        await writeDownloadFile(
          folder: folder,
          fileName: 'CON.txt',
          bytes: [1],
        ),
        inFolder('_CON.txt'),
      );
      final long = '${'가' * 300}.docx';
      // 이 기기의 파일 시스템이 세는 단위로 200 — Windows는 UTF-16 칸(".docx"를 빼고 195글자), 그 밖은
      // UTF-8 바이트(한글 3바이트라 65글자).
      final stem = '가' * (Platform.isWindows ? 195 : 65);
      final first = await writeDownloadFile(
        folder: folder,
        fileName: long,
        bytes: [1],
      );
      final second = await writeDownloadFile(
        folder: folder,
        fileName: long,
        bytes: [2],
      );
      expect(first, inFolder('$stem.docx'));
      // 줄인 이름에 번호를 붙여도 번호가 잘리지 않는다.
      expect(second, inFolder('$stem (1).docx'));
      expect(File(second).readAsBytesSync(), [2]);
    });

    test('남는 게 없는 이름은 대신할 이름으로, 폴더가 비면 아무 데도 쓰지 않는다', () async {
      expect(
        await writeDownloadFile(folder: folder, fileName: '..', bytes: [1]),
        inFolder('파일'),
      );
      // 빈 폴더에 이어 붙이면 드라이브 맨 위가 된다.
      await expectLater(
        writeDownloadFile(folder: '', fileName: 'x.txt', bytes: [1]),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('바로 가기는 글 파일로 쓰고, 같은 이름이면 번호는 .txt 앞에', () async {
      expect(
        await writeDownloadFile(folder: folder, fileName: 'x.url', bytes: [1]),
        inFolder('x.url.txt'),
      );
      expect(
        await writeDownloadFile(folder: folder, fileName: 'x.url', bytes: [2]),
        inFolder('x.url (1).txt'),
      );
      expect(File(inFolder('x.url')).existsSync(), isFalse);
    });
  });

  group('writeDownloadFile — 이름을 바이트로 세는 폴더(Windows에서 연 리눅스 NAS의 공유 폴더 등)', () {
    late Directory root;
    late String folder;
    String inFolder(String name) => '$folder${Platform.pathSeparator}$name';

    setUp(() {
      // 이름을 UTF-16 칸으로 세어 줄이는 Windows로 — 어느 OS에서 돌려도 같은 이름이 나온다.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      root = Directory.systemTemp.createTempSync('byte_limited_folder_');
      folder = '${root.path}${Platform.pathSeparator}nas';
    });
    tearDown(() => root.deleteSync(recursive: true));

    /// ext4·btrfs처럼 이름 한 칸이 UTF-8 255바이트를 넘으면 받지 않는다.
    bool overBytes(String name) => utf8.encode(name).length > 255;

    Future<String> write(
      _RejectingFolder nas,
      String fileName,
      List<int> bytes, {
      bool reuseIdentical = false,
    }) => IOOverrides.runWithIOOverrides(
      () => writeDownloadFile(
        folder: folder,
        fileName: fileName,
        bytes: bytes,
        reuseIdentical: reuseIdentical,
      ),
      nas,
    );

    // 한글 100글자 — UTF-16으로는 105칸이라 줄이지 않지만 UTF-8로는 305바이트다.
    final long = '${'가' * 100}.docx';
    // 바이트로 줄인 이름 — ".docx"(5바이트)를 빼고 195바이트 = 65글자(안드로이드와 같다).
    final inBytes = '${'가' * 65}.docx';

    for (final errorCode in [206, 123]) {
      test('이름이 너무 길다고 거절당하면(오류 $errorCode) 바이트로 줄인 이름으로 한 번 더 쓴다', () async {
        final nas = _RejectingFolder(overBytes, errorCode: errorCode);
        final path = await write(nas, long, [1]);
        expect(path, inFolder(inBytes));
        expect(File(path).readAsBytesSync(), [1]);
        expect(nas.rejected, [long]);
        // 같은 첨부를 또 받으면 줄인 이름에 번호를 붙인다.
        expect(await write(nas, long, [2]), inFolder('${'가' * 65} (1).docx'));
        expect(nas.rejected, [long, long]);
      });
    }

    test('보려고 다시 받으면 줄여서 저장해 둔 그 파일을 그대로 쓴다', () async {
      final nas = _RejectingFolder(overBytes);
      final first = await write(nas, long, [1, 2], reuseIdentical: true);
      expect(first, inFolder(inBytes));
      expect(await write(nas, long, [1, 2], reuseIdentical: true), first);
      expect(Directory(folder).listSync().map((e) => e.path), [first]);
    });

    test('번호를 붙여서 넘쳐도 바이트로 줄인 이름으로 쓴다', () async {
      final nas = _RejectingFolder(overBytes);
      // 254바이트 — 그대로는 들어가지만 " (1)"을 붙이면 넘는다.
      final name = '${'가' * 83}.docx';
      expect(await write(nas, name, [1]), inFolder(name));
      expect(await write(nas, name, [2]), inFolder(inBytes));
      expect(nas.rejected, ['${'가' * 83} (1).docx']);
    });

    test('바이트로 세도 같은 이름이거나 이름 길이와 상관없는 오류면 다시 쓰지 않는다', () async {
      // 무엇이든 거절하는 폴더 — ASCII 이름은 바이트로 세도 같은 이름이라 한 번만 써 본다.
      final all = _RejectingFolder((_) => true);
      await expectLater(
        write(all, 'report.docx', [1]),
        throwsA(isA<FileSystemException>()),
      );
      expect(all.rejected, ['report.docx']);
      // 바이트로 줄인 이름도 거절당하면 그 한 번으로 끝낸다.
      await expectLater(
        write(all, long, [1]),
        throwsA(isA<FileSystemException>()),
      );
      expect(all.rejected, ['report.docx', long, inBytes]);
      // 접근 거부(5) 같은 오류는 이름을 줄여도 소용없다.
      final denied = _RejectingFolder(overBytes, errorCode: 5);
      await expectLater(
        write(denied, long, [1]),
        throwsA(isA<FileSystemException>()),
      );
      expect(denied.rejected, [long]);
      expect(Directory(folder).listSync(), isEmpty);
    });
  });

  group('인터넷에서 받은 파일 표시(Windows)', () {
    late Directory root;
    String zoneOf(String path) =>
        File('$path:Zone.Identifier').readAsStringSync();

    setUp(() => root = Directory.systemTemp.createTempSync('motw_'));
    tearDown(() => root.deleteSync(recursive: true));

    test('새로 쓴 파일에는 ZoneId=3(인터넷)을 붙이고, 내용은 그대로', () async {
      final path = await writeDownloadFile(
        folder: root.path,
        fileName: 'macro.doc',
        bytes: [1, 2, 3],
      );
      expect(zoneOf(path), contains('ZoneId=3'));
      expect(File(path).readAsBytesSync(), [1, 2, 3]);
      // 같은 파일을 다시 열 때도 그 파일을 그대로 쓴다(표시는 스트림이라 내용 비교에 끼지 않는다).
      expect(
        await writeDownloadFile(
          folder: root.path,
          fileName: 'macro.doc',
          bytes: [1, 2, 3],
          reuseIdentical: true,
        ),
        path,
      );
    });

    test('저장 창으로 받은 파일에도 붙이고, 없는 파일은 만들지 않는다', () async {
      final saved = File('${root.path}${Platform.pathSeparator}a.xlsx')
        ..writeAsBytesSync([1]);
      await markFromInternet(saved.path);
      expect(zoneOf(saved.path), contains('ZoneId=3'));

      final missing = '${root.path}${Platform.pathSeparator}none.xlsx';
      await markFromInternet(missing);
      expect(File(missing).existsSync(), isFalse);
    });
  }, skip: !Platform.isWindows);

  group('downloadTempFolder — 보려고 받는 파일은 이 앱만의 임시 폴더에', () {
    late Directory temp;
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

    setUp(() {
      temp = Directory.systemTemp.createTempSync('download_temp_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, (call) async => temp.path);
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null);
      temp.deleteSync(recursive: true);
    });

    test('시스템 임시 폴더 맨 위가 아니라 TangoTalk\\open 아래', () async {
      final sep = Platform.pathSeparator;
      final folder = await downloadTempFolder();
      expect(folder, '${temp.path}${sep}TangoTalk${sep}open');

      // 업데이트 설치 파일 등이 풀리는 임시 폴더 맨 위에 DLL 같은 이름으로 받아도 그 옆에 놓이지 않는다.
      final path = await writeDownloadFile(
        folder: folder,
        fileName: r'..\version.dll',
        bytes: [1],
        reuseIdentical: true,
      );
      expect(path, '$folder${sep}version.dll');
      expect(temp.listSync().map((e) => e.path).toList(), [
        '${temp.path}${sep}TangoTalk',
      ]);
    });
  });
}

/// [rejects]가 true인 이름을 받지 않는 폴더 — 그 이름의 파일은 없는 것으로 보이고, 쓰려고 하면 Windows
/// 오류 [errorCode]로 실패한다(206 ERROR_FILENAME_EXCED_RANGE는 Samba가 이름이 너무 길다고 답할 때
/// Windows가 내는 오류). 그 밖의 이름은 진짜 파일 그대로다. IOOverrides라 그 안에서 만드는 `File`이
/// 모두 여기를 거친다.
final class _RejectingFolder extends IOOverrides {
  _RejectingFolder(this.rejects, {this.errorCode = 206});

  final bool Function(String name) rejects;
  final int errorCode;

  /// 쓰려다 거절당한 이름들(차례대로).
  final rejected = <String>[];

  @override
  File createFile(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    return rejects(name)
        ? _RejectedFile(path, name, this)
        : super.createFile(path);
  }
}

/// [_RejectingFolder]가 받지 않는 이름의 파일 — writeDownloadFile이 부르는 것만 흉내 낸다.
class _RejectedFile implements File {
  _RejectedFile(this.path, this._name, this._folder);

  @override
  final String path;
  final String _name;
  final _RejectingFolder _folder;

  @override
  bool existsSync() => false;

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    _folder.rejected.add(_name);
    throw FileSystemException(
      'Cannot open file',
      path,
      OSError('The filename or extension is too long.', _folder.errorCode),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
