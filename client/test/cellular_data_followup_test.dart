// 모바일 데이터 후속 — 데이터 사용 경고의 켜기/끄기·기준(환경설정), 휴대폰 데이터일 때 사진을 일반 화질로(photo_quality.dart),
// 큰 첨부를 메모리에 모으지 않고 받는 대로 디스크에(download_storage.dart writeDownloadStream·attachment_widgets.dart
// downloadAttachmentToFolder).
import 'dart:async';
import 'dart:io';

import 'package:client/services/app_settings.dart';
import 'package:client/services/download_progress.dart';
import 'package:client/services/download_storage.dart';
import 'package:client/services/memory_file.dart';
import 'package:client/services/network_type.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/photo_quality.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/attachment_widgets.dart';
import 'package:client/widgets/data_usage_warning.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

/// 무늬가 있는(잘 줄지 않는) 큰 사진.
Uint8List _noisyJpeg(int w, int h) {
  final image = img.Image(width: w, height: h);
  var seed = 7;
  for (final p in image) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    p
      ..r = seed & 0xff
      ..g = (seed >> 8) & 0xff
      ..b = (seed >> 16) & 0xff;
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 98));
}

void main() {
  tearDown(() => debugIsOnCellularOverride = null);

  group('환경설정', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('기본은 경고 켬·10MB·사진 일반 화질 켬, 저장하면 다시 읽어도 그대로, 없는 기준은 기본값', (
      tester,
    ) async {
      // init()이 창 속성을 적용하려고 부르는 채널 — 테스트엔 창이 없으니 그냥 받아 준다.
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (_) async => null,
      );
      final s = AppSettings();
      await s.init();
      expect(s.cellularDownloadWarning, isTrue);
      expect(s.cellularDownloadWarnMb, 10);
      expect(s.cellularDownloadWarnBytes, 10 * 1024 * 1024);
      expect(s.cellularPhotoNormalQuality, isTrue);
      await s.setCellularData(
        warning: false,
        warnMb: 50,
        photoNormalQuality: false,
      );
      final again = AppSettings();
      await again.init();
      expect(again.cellularDownloadWarning, isFalse);
      expect(again.cellularDownloadWarnMb, 50);
      expect(again.cellularPhotoNormalQuality, isFalse);
      await again.setCellularData(
        warning: true,
        warnMb: 7,
        photoNormalQuality: true,
      );
      expect(again.cellularDownloadWarnMb, kCellularWarnMbDefault);
    });
  });

  group('데이터 사용 경고 — 환경설정의 기준·끄기', () {
    Future<List<bool>> pump(
      WidgetTester tester,
      Session session,
      int size,
    ) async {
      final result = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result.add(
                await confirmCellularDownload(
                  context,
                  session: session,
                  items: [(url: 'u', size: size)],
                ),
              ),
              child: const Text('받기'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('받기'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('기준을 50MB로 올리면 20MB는 묻지 않고 60MB는 묻는다', (tester) async {
      debugIsOnCellularOverride = true;
      final session = Session(
        notifications: NotificationService(),
        settings: AppSettings()..cellularDownloadWarnMb = 50,
      );
      expect(await pump(tester, session, 20 * 1024 * 1024), [true]);
      await pump(tester, session, 60 * 1024 * 1024);
      expect(find.text('데이터 사용 경고'), findsOneWidget);
    });

    testWidgets('경고를 끄면 휴대폰 데이터로 큰 파일도 묻지 않는다', (tester) async {
      debugIsOnCellularOverride = true;
      final session = Session(
        notifications: NotificationService(),
        settings: AppSettings()..cellularDownloadWarning = false,
      );
      expect(await pump(tester, session, 500 * 1024 * 1024), [true]);
      expect(find.text('데이터 사용 경고'), findsNothing);
    });
  });

  group('사진 일반 화질', () {
    test('큰 사진은 긴 변 2048px JPEG로, 이름은 .jpg', () async {
      final big = _noisyJpeg(3000, 2000);
      final reduced = await normalQualityPhoto(big, 'IMG_0001.jpeg');
      expect(reduced, isNotNull);
      expect(reduced!.name, 'IMG_0001.jpg');
      expect(reduced.bytes.length, lessThan(big.length));
      final decoded = img.decodeImage(reduced.bytes)!;
      expect(decoded.width, kNormalPhotoMaxSide);
      expect(decoded.height, 1365);
    });

    test('세로 사진은 세로를 2048px로', () async {
      final reduced = await normalQualityPhoto(_noisyJpeg(1500, 2600), 'a.jpg');
      final decoded = img.decodeImage(reduced!.bytes)!;
      expect(decoded.height, kNormalPhotoMaxSide);
    });

    test('작은 사진·GIF·사진이 아닌 것은 그대로(null)', () async {
      expect(
        await normalQualityPhoto(_noisyJpeg(200, 100), 'small.jpg'),
        isNull,
      );
      final gif = Uint8List.fromList(
        img.encodeGif(img.Image(width: 3000, height: 3000)),
      );
      expect(await normalQualityPhoto(gif, 'anim.gif'), isNull);
      expect(
        await normalQualityPhoto(Uint8List(kNormalPhotoMinBytes + 10), 'x.jpg'),
        isNull,
      );
    });

    test('투명한 PNG는 PNG로 두고 크기만 줄인다', () async {
      final image = img.Image(width: 3000, height: 3000, numChannels: 4);
      var seed = 3;
      for (final p in image) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        p
          ..r = seed & 0xff
          ..g = (seed >> 8) & 0xff
          ..b = (seed >> 16) & 0xff
          ..a = (seed >> 24) & 0x7f;
      }
      final png = Uint8List.fromList(img.encodePng(image));
      final reduced = await normalQualityPhoto(png, 'shot.png');
      expect(reduced, isNotNull);
      expect(reduced!.name, 'shot.png');
      final decoded = img.decodeImage(reduced.bytes)!;
      expect(decoded.width, kNormalPhotoMaxSide);
      expect(decoded.hasAlpha, isTrue);
    });

    test('Wi-Fi이거나 환경설정을 끄면 원본 그대로, 휴대폰 데이터면 줄인 파일', () async {
      final big = _noisyJpeg(3000, 2000);
      final file = bytesAsFile(big, 'p.jpg');
      debugIsOnCellularOverride = false;
      expect(await photoForUpload(AppSettings(), file, big), isNull);
      debugIsOnCellularOverride = true;
      expect(
        await photoForUpload(
          AppSettings()..cellularPhotoNormalQuality = false,
          file,
          big,
        ),
        isNull,
      );
      final reduced = await photoForUpload(AppSettings(), file, big);
      expect(reduced, isNotNull);
      expect(reduced!.file.name, 'p.jpg');
      expect(await reduced.file.length(), reduced.bytes.length);
    });
  });

  group('받는 대로 디스크에', () {
    late Directory folder;
    setUp(() => folder = Directory.systemTemp.createTempSync('stream_dl_'));
    tearDown(() => folder.deleteSync(recursive: true));

    List<String> names() =>
        folder.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();

    test('임시 파일에 받은 뒤 이름을 붙이고, 같은 이름이 있으면 번호', () async {
      Future<void> write(IOSink sink) async {
        sink.add([1, 2, 3]);
        sink.add([4]);
      }

      final a = await writeDownloadStream(
        folder: folder.path,
        fileName: 'r.bin',
        write: write,
        markAsDownloaded: false,
      );
      final b = await writeDownloadStream(
        folder: folder.path,
        fileName: 'r.bin',
        write: write,
        markAsDownloaded: false,
      );
      expect(File(a).readAsBytesSync(), [1, 2, 3, 4]);
      expect(b.endsWith('r (1).bin'), isTrue);
      expect(names(), ['r (1).bin', 'r.bin']);
      // 보려고 받는 경우 — 같은 파일이 있으면 새로 만들지 않는다.
      final c = await writeDownloadStream(
        folder: folder.path,
        fileName: 'r.bin',
        write: write,
        reuseIdentical: true,
        markAsDownloaded: false,
      );
      expect(c, a);
      expect(names(), ['r (1).bin', 'r.bin']);
    });

    test('받다가 실패하면 임시 파일을 지우고 그 오류를 그대로', () async {
      await expectLater(
        writeDownloadStream(
          folder: folder.path,
          fileName: 'x.bin',
          write: (sink) async {
            sink.add(List.filled(1000, 1));
            throw const DownloadCancelled();
          },
          markAsDownloaded: false,
        ),
        throwsA(isA<DownloadCancelled>()),
      );
      expect(names(), isEmpty);
    });

    test('첨부를 조각조각 받아 폴더에 — 진행을 알리고, 실패(HTTP 500)면 아무것도 남기지 않는다', () async {
      final session = Session(
        notifications: NotificationService(),
        settings: AppSettings(),
      );
      final payload = List.generate(300 * 1024, (i) => i % 251);
      final server = MockClient.streaming((request, _) async {
        if (request.url.path.endsWith('/bad')) {
          return http.StreamedResponse(Stream.value([0]), 500);
        }
        Stream<List<int>> chunks() async* {
          for (var i = 0; i < payload.length; i += 64 * 1024) {
            yield payload.sublist(i, (i + 64 * 1024).clamp(0, payload.length));
          }
        }

        return http.StreamedResponse(
          chunks(),
          200,
          contentLength: payload.length,
        );
      });
      final task = DownloadTask('big.bin');
      final reported = <int>[];
      task.addListener(() => reported.add(task.receivedBytes));
      final path = await http.runWithClient(
        () => trackDownload(
          task: task,
          body: () => downloadAttachmentToFolder(
            session: session,
            url: 'https://s.test/files/good',
            folder: folder.path,
            fileName: 'big.bin',
          ),
        ),
        () => server,
      );
      expect(File(path).readAsBytesSync(), payload);
      expect(task.filesDone, 1);
      expect(reported, contains(payload.length));
      await expectLater(
        http.runWithClient(
          () => downloadAttachmentToFolder(
            session: session,
            url: 'https://s.test/files/bad',
            folder: folder.path,
            fileName: 'bad.bin',
          ),
          () => server,
        ),
        throwsA(isA<Exception>()),
      );
      expect(names(), ['big.bin']);
    });
  });
}
