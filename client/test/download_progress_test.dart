// 다운로드 진행 표시 — 다운로드 단추로 받는 동안(trackDownload 안) fetchAttachmentBytes가 받은 양을 알리고, 화면 구석의
// 진행 카드(download_progress_card.dart)가 파일 이름·막대·받은 양을 보여 주다가 다 받으면 사라진다.
import 'dart:async';
import 'dart:io';

import 'package:client/models/message.dart' show MessageAttachment;
import 'package:client/services/app_settings.dart';
import 'package:client/services/download_progress.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/attachment_widgets.dart';
import 'package:client/widgets/download_progress_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 파일마다 [chunks]개 조각(조각당 1KB)으로 나눠 Content-Length와 함께 내려주는 가짜 서버.
MockClient _chunkedServer({int chunks = 4}) => MockClient.streaming(
  (request, _) async => http.StreamedResponse(
    Stream.fromIterable([
      for (var i = 0; i < chunks; i++) List.filled(1024, i),
    ]),
    200,
    contentLength: chunks * 1024,
  ),
);

/// 진행 상황이 바뀔 때마다 (이름, 몇 개 받음, 진행률)을 적어 둔다.
List<(String, int, double?)> _record() {
  final seen = <(String, int, double?)>[];
  void listener() {
    for (final t in DownloadProgress.instance.tasks) {
      seen.add((t.label, t.filesDone, t.fraction));
    }
  }

  DownloadProgress.instance.addListener(listener);
  addTearDown(() => DownloadProgress.instance.removeListener(listener));
  return seen;
}

void main() {
  test('다운로드 단추 밖(미리보기 등)에서 받으면 진행 카드에 아무것도 올라가지 않는다', () async {
    final seen = _record();
    final bytes = await http.runWithClient(
      () => fetchAttachmentBytes(url: 'https://test.local/files/a'),
      _chunkedServer,
    );
    expect(bytes.length, 4096);
    expect(seen, isEmpty);
  });

  test('파일 하나 — 받는 동안 0%에서 100%까지 알리고, 다 받으면 목록에서 빠진다', () async {
    final seen = _record();
    final bytes = await http.runWithClient(
      () => trackDownload(
        label: '보고서.pdf',
        body: () => fetchAttachmentBytes(url: 'https://test.local/files/a'),
      ),
      _chunkedServer,
    );
    expect(bytes.length, 4096);
    expect(seen, contains(('보고서.pdf', 0, 0.0)));
    expect(seen.map((s) => s.$3), contains(1.0));
    expect(DownloadProgress.instance.tasks, isEmpty);
  });

  test('전체 다운로드 — "파일 N개"로 하나로 묶여, 파일을 하나 받을 때마다 칸이 찬다', () async {
    final folder = Directory.systemTemp.createTempSync('download_progress_');
    addTearDown(() => folder.deleteSync(recursive: true));
    final settings = AppSettings()
      ..downloadWithoutAsking = true
      ..downloadFolder = folder.path
      ..openFolderAfterDownload = false;
    final session = Session(
      notifications: NotificationService(),
      settings: settings,
    );
    final seen = _record();
    final result = await http.runWithClient(
      () => saveAllAttachments(
        session: session,
        items: [
          (url: 'https://test.local/files/1', fileName: 'a.png'),
          (url: 'https://test.local/files/2', fileName: 'b.png'),
        ],
      ),
      _chunkedServer,
    );
    expect(result!.count, 2);
    expect(seen.map((s) => s.$1).toSet(), {'파일 2개'}, reason: '하나로 묶인다');
    expect(seen, contains(('파일 2개', 1, 0.5)), reason: '하나 받으면 절반');
    expect(seen.last.$3, 1.0);
    expect(DownloadProgress.instance.tasks, isEmpty);
  });

  testWidgets('진행 카드 — 받는 동안 이름·막대·받은 양이 보이고, 다 받으면 사라진다', (tester) async {
    final chunks = StreamController<List<int>>();
    final server = MockClient.streaming(
      (request, _) async =>
          http.StreamedResponse(chunks.stream, 200, contentLength: 2048),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Stack(children: [DownloadProgressCard()])),
      ),
    );

    late Future<void> done;
    await tester.runAsync(() async {
      done = http.runWithClient(
        () => trackDownload(
          label: '회의록.docx',
          body: () => fetchAttachmentBytes(url: 'https://test.local/files/a'),
        ),
        () => server,
      );
      chunks.add(List.filled(1024, 0));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();
    // 금방 끝나는 것은 띄우지 않으려고 조금 기다렸다가 보인다.
    expect(find.byKey(const ValueKey('download-progress')), findsNothing);
    // 진행 알림은 실제 시간 쪽(runAsync)에서 오므로 보이기까지의 타이머도 실제 시간으로 기다린다.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('download-progress')), findsOneWidget);
    expect(find.text('회의록.docx'), findsOneWidget);
    expect(find.text('다운로드 중 · 1.0KB / 2.0KB · 50%'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, 0.5);

    await tester.runAsync(() async {
      chunks.add(List.filled(1024, 1));
      await chunks.close();
      await done;
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('download-progress')), findsNothing);
  });

  test('X로 멈추면 받던 파일에서 그만두고(DownloadCancelled) 남은 파일은 받지 않는다', () async {
    final folder = Directory.systemTemp.createTempSync('download_cancel_');
    addTearDown(() => folder.deleteSync(recursive: true));
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings()
        ..downloadWithoutAsking = true
        ..downloadFolder = folder.path
        ..openFolderAfterDownload = false,
    );
    final task = DownloadTask('파일 2개', fileCount: 2, inline: true);
    var requests = 0;
    final server = MockClient.streaming((request, _) async {
      requests++;
      // 첫 조각을 받은 뒤 사용자가 X를 누른다.
      final chunks = StreamController<List<int>>();
      chunks.add(List.filled(1024, 0));
      Future<void>.delayed(const Duration(milliseconds: 10), () {
        task.cancel();
        chunks
          ..add(List.filled(1024, 1))
          ..close();
      });
      return http.StreamedResponse(chunks.stream, 200, contentLength: 2048);
    });
    await expectLater(
      http.runWithClient(
        () => saveAllAttachments(
          session: session,
          items: [
            (url: 'https://test.local/files/1', fileName: 'a.png'),
            (url: 'https://test.local/files/2', fileName: 'b.png'),
          ],
          task: task,
        ),
        () => server,
      ),
      throwsA(isA<DownloadCancelled>()),
    );
    expect(requests, 1, reason: '두 번째 파일은 받으러 가지 않는다');
    expect(folder.listSync(), isEmpty, reason: '다 받지 못한 파일은 저장하지 않는다');
    expect(task.finished, isTrue);
    expect(DownloadProgress.instance.tasks, isEmpty);
  });

  testWidgets('진행 카드의 X — 누르면 멈추고 카드가 사라진다', (tester) async {
    final chunks = StreamController<List<int>>();
    final server = MockClient.streaming(
      (request, _) async =>
          http.StreamedResponse(chunks.stream, 200, contentLength: 2048),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Stack(children: [DownloadProgressCard()])),
      ),
    );
    Object? error;
    late Future<void> done;
    await tester.runAsync(() async {
      done = http
          .runWithClient(
            () => trackDownload(
              label: '회의록.docx',
              body: () =>
                  fetchAttachmentBytes(url: 'https://test.local/files/a'),
            ),
            () => server,
          )
          .then<void>(
            (_) {},
            onError: (Object e) {
              error = e;
            },
          );
      chunks.add(List.filled(1024, 0));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('download-cancel')));
    await tester.runAsync(() async {
      chunks.add(List.filled(1024, 1));
      await done;
    });
    await tester.pump();
    expect(error, isA<DownloadCancelled>());
    expect(find.byKey(const ValueKey('download-progress')), findsNothing);
    // 멈춘 뒤라 받는 쪽이 이미 끊었다 — 닫기를 기다리지 않는다(가짜 시간에서는 끝나지 않는다).
    unawaited(chunks.close());
  });

  testWidgets('말풍선 "전체 다운로드" — 단추 왼쪽에 진행 표시와 X가 붙고, 구석 카드에는 뜨지 않는다', (
    tester,
  ) async {
    final folder = Directory.systemTemp.createTempSync('download_inline_');
    addTearDown(() => folder.deleteSync(recursive: true));
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings()
        ..downloadWithoutAsking = true
        ..downloadFolder = folder.path
        ..openFolderAfterDownload = false,
    );
    final chunks = StreamController<List<int>>();
    final server = MockClient.streaming(
      (request, _) async =>
          http.StreamedResponse(chunks.stream, 200, contentLength: 2048),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: ChatFileAttachments(
                  session: session,
                  attachments: [
                    for (final id in ['a', 'b'])
                      MessageAttachment(
                        id: id,
                        kind: 'file',
                        fileUrl: '/files/$id',
                        fileName: '$id.pdf',
                      ),
                  ],
                ),
              ),
              const DownloadProgressCard(),
            ],
          ),
        ),
      ),
    );
    final button = find.text('전체 다운로드 (2)');
    await http.runWithClient(() => tester.tap(button), () => server);
    await tester.runAsync(() async {
      chunks.add(List.filled(1024, 0));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();

    final pill = find.byKey(const ValueKey('download-pill'));
    expect(pill, findsOneWidget);
    expect(find.text('1/2개 · 25%'), findsOneWidget);
    expect(
      tester.getRect(pill).right,
      lessThanOrEqualTo(tester.getRect(button).left),
      reason: '단추 왼쪽',
    );
    expect(
      find.byKey(const ValueKey('download-progress')),
      findsNothing,
      reason: '말풍선에 보이는 것은 구석 카드에 또 띄우지 않는다',
    );

    // X로 멈춘다.
    await tester.tap(
      find.descendant(
        of: pill,
        matching: find.byKey(const ValueKey('download-cancel')),
      ),
    );
    await tester.runAsync(() async {
      chunks.add(List.filled(1024, 1));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(pill, findsNothing);
    expect(find.text('다운로드를 취소했습니다.'), findsOneWidget);
    expect(folder.listSync(), isEmpty);
    // 멈춘 뒤라 받는 쪽이 이미 끊었다 — 닫기를 기다리지 않는다(가짜 시간에서는 끝나지 않는다).
    unawaited(chunks.close());
    await tester.pump(const Duration(seconds: 5));
  });
}
