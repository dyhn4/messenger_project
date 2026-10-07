import 'dart:io';

import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/download_storage.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// "인터넷에서 받은 파일" 표시(Mark of the Web — download_storage.dart의 markFromInternet)를 어디에 붙이는지.
// 남이 보낸 첨부에는 늘 붙이고(보려고 다시 받는 같은 파일에도), 서버가 내 요청으로 만들어 준 대화 내보내기
// 엑셀에는 붙이지 않는다 — 붙이면 내보내자마자 여는 엑셀이 제한된 보기로 열린다. 내보내기는 다운로드
// 폴더를 안 정했으면 임시 폴더 맨 위가 아니라 이 앱만의 임시 폴더(downloadTempFolder)에 둔다.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sep = Platform.pathSeparator;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('download_mark_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProvider,
          (call) async => '${root.path}${sep}temp',
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    root.deleteSync(recursive: true);
  });

  /// [path]의 Zone.Identifier 스트림 내용 — 없으면 null(Windows).
  String? zoneOf(String path) {
    try {
      return File('$path:Zone.Identifier').readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }

  group('대화 내보내기', () {
    late List<http.Request> requests;

    /// 내보내기 응답으로 [xlsx]를 돌려주는 서버에 붙은 세션.
    Session exportSession({required String downloadFolder, List<int>? xlsx}) {
      final session = Session(
        notifications: NotificationService(),
        settings: AppSettings()..downloadFolder = downloadFolder,
      );
      session.api = ApiClient(
        baseUrl: 'https://test.local',
        token: 't',
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response.bytes(xlsx ?? [1, 2, 3], 200);
        }),
      );
      return session;
    }

    setUp(() => requests = []);

    test('다운로드 폴더를 안 정했으면 이 앱만의 임시 폴더에 — 임시 폴더 맨 위가 아니다', () async {
      final session = exportSession(downloadFolder: '', xlsx: [7, 8, 9]);
      final path = await session.exportRoomChat(
        'r1',
        fileName: '공지방_대화내역_전체.xlsx',
      );

      expect(requests.single.url.path, '/api/rooms/r1/export');
      final folder = await downloadTempFolder();
      expect(folder, '${root.path}${sep}temp${sep}TangoTalk${sep}open');
      expect(path, '$folder$sep공지방_대화내역_전체.xlsx');
      expect(File(path).readAsBytesSync(), [7, 8, 9]);
      // 설치 프로그램이 풀리는 임시 폴더 맨 위에는 TangoTalk 폴더 말고 아무것도 생기지 않았다.
      expect(
        Directory('${root.path}${sep}temp').listSync().map((e) => e.path),
        ['${root.path}${sep}temp${sep}TangoTalk'],
      );
    });

    test('다운로드 폴더를 정했으면 거기에, 같은 이름이 있으면 번호를 붙인다', () async {
      final downloads = '${root.path}${sep}dl';
      final session = exportSession(downloadFolder: downloads);
      final first = await session.exportRoomChat('r1', fileName: '대화내역.xlsx');
      final second = await session.exportRoomChat('r1', fileName: '대화내역.xlsx');
      expect(first, '$downloads$sep대화내역.xlsx');
      expect(second, '$downloads$sep대화내역 (1).xlsx');
    });

    test('"인터넷에서 받은 파일" 표시를 붙이지 않는다 — 바로 여는 엑셀이 제한된 보기로 열리지 않게', () async {
      for (final downloadFolder in ['', '${root.path}${sep}dl']) {
        final session = exportSession(downloadFolder: downloadFolder);
        final path = await session.exportRoomChat('r1', fileName: '대화내역.xlsx');
        expect(File(path).readAsBytesSync(), [1, 2, 3]);
        expect(zoneOf(path), isNull, reason: path);
      }
    }, skip: !Platform.isWindows);
  });

  group('첨부 — writeDownloadFile', () {
    test('표시는 기본으로 붙이고, markAsDownloaded: false면 붙이지 않는다', () async {
      final attachment = await writeDownloadFile(
        folder: root.path,
        fileName: 'report.xlsx',
        bytes: [1],
      );
      expect(zoneOf(attachment), contains('ZoneId=3'));

      final own = await writeDownloadFile(
        folder: root.path,
        fileName: 'report.xlsx',
        bytes: [1],
        markAsDownloaded: false,
      );
      expect(own, '${root.path}${sep}report (1).xlsx');
      expect(File(own).readAsBytesSync(), [1]);
      expect(zoneOf(own), isNull);
    });

    test('보려고 다시 받는 같은 파일에 표시가 없으면(표시를 붙이기 전에 받아 둔 파일) 다시 붙인다', () async {
      final old = File('${root.path}${sep}macro.doc')..writeAsBytesSync([1, 2]);
      expect(zoneOf(old.path), isNull);

      final path = await writeDownloadFile(
        folder: root.path,
        fileName: 'macro.doc',
        bytes: [1, 2],
        reuseIdentical: true,
      );
      expect(path, old.path);
      expect(zoneOf(path), contains('ZoneId=3'));
      expect(File(path).readAsBytesSync(), [1, 2]);
      expect(root.listSync().map((e) => e.path), [old.path]);
    });
  }, skip: !Platform.isWindows);
}
