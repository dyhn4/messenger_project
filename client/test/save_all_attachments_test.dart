import 'dart:io';

import 'package:client/services/app_settings.dart';
import 'package:client/services/download_storage.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/attachment_widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory folder;

  setUp(() => folder = Directory.systemTemp.createTempSync('save_all_'));
  tearDown(() => folder.deleteSync(recursive: true));

  test('전체 다운로드는 설정된 폴더에 한 번에 저장하고, 같은 이름은 번호를 붙인다', () async {
    final settings = AppSettings()
      ..downloadWithoutAsking = true
      ..downloadFolder = folder.path
      ..openFolderAfterDownload = false;
    final session = Session(
      notifications: NotificationService(),
      settings: settings,
    );
    // 이미 같은 이름의 파일이 있다 — 덮어쓰면 안 된다.
    File(
      '${folder.path}${Platform.pathSeparator}a.png',
    ).writeAsStringSync('old');

    final result = await http.runWithClient(
      () => saveAllAttachments(
        session: session,
        items: [
          (url: 'https://test.local/uploads/1', fileName: 'a.png'),
          (url: 'https://test.local/uploads/2', fileName: 'a.png'),
          (url: 'https://test.local/uploads/3', fileName: 'b.pdf'),
        ],
      ),
      () => MockClient(
        (req) async => http.Response('body-${req.url.pathSegments.last}', 200),
      ),
    );

    expect(result!.count, 3);
    expect(result.folder, folder.path);
    String read(String name) =>
        File('${folder.path}${Platform.pathSeparator}$name').readAsStringSync();
    expect(read('a.png'), 'old');
    expect(read('a (1).png'), 'body-1');
    expect(read('a (2).png'), 'body-2');
    expect(read('b.pdf'), 'body-3');
  });

  test('같은 이름은 덮어쓰지 않고 번호를 붙이고, 열어 보기용은 똑같은 파일을 다시 쓴다', () async {
    final target = '${folder.path}${Platform.pathSeparator}TangoTalk';
    String at(String name) => '$target${Platform.pathSeparator}$name';

    // 폴더가 없으면 만든다.
    final first = await writeDownloadFile(
      folder: target,
      fileName: 'report.xlsx',
      bytes: [1],
    );
    expect(first, at('report.xlsx'));

    // 다운로드 — 내용이 같아도 원래 파일은 그대로 두고 번호를 붙인다.
    final second = await writeDownloadFile(
      folder: target,
      fileName: 'report.xlsx',
      bytes: [1],
    );
    expect(second, at('report (1).xlsx'));

    // 파일 열기 — 내용까지 같은 파일이 있으면 새로 만들지 않고 그 파일을 연다.
    final reopened = await writeDownloadFile(
      folder: target,
      fileName: 'report.xlsx',
      bytes: [1],
      reuseIdentical: true,
    );
    expect(reopened, first);

    // 파일 열기라도 내용이 다르면 덮어쓰지 않고 다음 번호.
    final changed = await writeDownloadFile(
      folder: target,
      fileName: 'report.xlsx',
      bytes: [2],
      reuseIdentical: true,
    );
    expect(changed, at('report (2).xlsx'));
    expect(File(first).readAsBytesSync(), [1]);
  });

  test('PC에서는 알림에 경로를 그대로 보여준다', () {
    expect(
      displayDownloadPath('C:/Users/me/Download/a.png'),
      'C:/Users/me/Download/a.png',
    );
  });
}
