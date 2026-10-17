import 'dart:convert';
import 'dart:typed_data';

import 'package:client/models/drive.dart';
import 'package:client/screens/drive/drive_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 팀 공유 드라이브 화면(drive_screen.dart, 서버 drive.js).

const _json = {'content-type': 'application/json'};

void main() {
  final now = DateTime(2026, 10, 7).millisecondsSinceEpoch;
  late List<({String method, String path, Object? body})> calls;
  late Map<String, http.Response Function(http.Request r)> routes;

  http.Response ok(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: _json);

  Map<String, dynamic> file(
    String id,
    String name, {
    int version = 1,
    String? folderId,
  }) => {
    'id': id,
    'name': name,
    'folderId': folderId,
    'version': version,
    'size': 2048,
    'updatedByName': '김가',
    'updatedAt': now,
    'url': '/files/token-$id',
    'createdBy': 'me',
  };

  Session session() {
    calls = [];
    final s = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    s.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: MockClient((request) async {
        Object? body;
        if (request.headers['content-type']?.contains('json') ?? false) {
          body = request.body.isEmpty ? null : jsonDecode(request.body);
        }
        if (request.method != 'GET') {
          calls.add((
            method: request.method,
            path: request.url.path,
            body: body,
          ));
        }
        final handler = routes['${request.method} ${request.url.path}'];
        return handler == null ? ok(<Object>[]) : handler(request);
      }),
    );
    s.userId = 'me';
    return s;
  }

  Map<String, dynamic> listing({String? folderId}) => folderId == 'f1'
      ? {
          'folder': {'id': 'f1', 'name': '기획'},
          'path': [
            {'id': 'f1', 'name': '기획'},
          ],
          'folders': <Object>[],
          'files': [file('x1', '보고서.pdf', version: 3, folderId: 'f1')],
          'canWrite': true,
          'isManager': false,
          'usageBytes': 3 * 1024 * 1024,
        }
      : {
          'folder': null,
          'path': <Object>[],
          'folders': [
            {'id': 'f1', 'name': '기획', 'createdBy': 'me', 'updatedAt': now},
          ],
          'files': [file('x0', '회의록.txt')],
          'canWrite': true,
          'isManager': false,
          'usageBytes': 1024,
        };

  Future<void> pump(WidgetTester tester, Session s) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: DriveScreen(session: s, teamId: 't1', teamName: '영업팀'),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('모델 — 크기 글, 목록 읽기', () {
    expect(formatBytes(512), '512B');
    expect(formatBytes(2048), '2KB');
    expect(formatBytes(3 * 1024 * 1024), '3.0MB');
    final l = DriveListing.fromJson(listing(folderId: 'f1'));
    expect(l.path.single.name, '기획');
    expect(l.files.single.version, 3);
    expect(driveNameKey('Report.PDF'), driveNameKey('report.pdf'));
  });

  testWidgets('폴더를 오가고(빵부스러기) 새 폴더를 만든다', (tester) async {
    final s = session();
    routes = {
      'GET /api/drive': (r) =>
          ok(listing(folderId: r.url.queryParameters['folderId'])),
      'POST /api/drive/folders': (_) => ok({'id': 'f2', 'name': '디자인'}, 201),
    };
    await pump(tester, s);
    expect(find.text('드라이브 · 영업팀'), findsOneWidget);
    expect(find.text('회의록.txt'), findsOneWidget);
    expect(find.text('드라이브 사용량 1KB(판 기록 포함)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('drive-folder-f1')));
    await tester.pumpAndSettle();
    expect(find.text('보고서.pdf'), findsOneWidget);
    expect(find.textContaining('판 3'), findsOneWidget);
    expect(find.byKey(const ValueKey('drive-crumb-f1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('drive-new-folder')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('drive-name-input')),
      '디자인',
    );
    await tester.tap(find.byKey(const ValueKey('drive-name-ok')));
    await tester.pumpAndSettle();
    expect(calls.single.body, {
      'teamId': 't1',
      'name': '디자인',
      'parentId': 'f1',
    });

    await tester.tap(find.byKey(const ValueKey('drive-crumb-root')));
    await tester.pumpAndSettle();
    expect(find.text('회의록.txt'), findsOneWidget);
  });

  testWidgets('올리기 — 같은 이름이면 새 판으로 올릴지 묻는다', (tester) async {
    final s = session();
    routes = {
      'GET /api/drive': (r) => ok(listing()),
      'POST /api/upload': (_) => ok({
        'url': '/uploads/new.txt',
        'fileName': '회의록.TXT',
        'size': 5,
        'mimeType': 'text/plain',
      }),
      'POST /api/drive/files': (_) =>
          ok({'error': "'회의록.TXT'이(가) 이미 있습니다."}, 409),
      'POST /api/drive/files/x0/versions': (_) =>
          ok(file('x0', '회의록.txt', version: 2), 201),
    };
    await pump(tester, s);
    final state = tester.state<DriveScreenState>(find.byType(DriveScreen));
    final f = XFile.fromData(
      Uint8List.fromList(utf8.encode('hello')),
      name: '회의록.TXT',
    );
    // 업로드(멀티파트)는 실제 입출력이라 runAsync 안에서 끝까지 진행시킨다.
    await tester.runAsync(() async {
      final done = state.uploadFiles([f]);
      for (
        var i = 0;
        i < 50 &&
            find
                .byKey(const ValueKey('drive-upload-as-version'))
                .evaluate()
                .isEmpty;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
      expect(find.text('같은 이름의 파일'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('drive-upload-as-version')));
      await tester.pump();
      await done;
    });
    await tester.pumpAndSettle();
    final version = calls.singleWhere(
      (c) => c.path == '/api/drive/files/x0/versions',
    );
    expect((version.body as Map)['file'], '/uploads/new.txt');
  });

  testWidgets('파일 — 판 기록을 보고 지난 판으로 되돌리고, 휴지통으로', (tester) async {
    final s = session();
    routes = {
      'GET /api/drive': (r) =>
          ok(listing(folderId: r.url.queryParameters['folderId'])),
      'GET /api/drive/files/x0': (_) => ok({
        ...file('x0', '회의록.txt', version: 2),
        'path': <Object>[],
        'canRemove': true,
        'canWrite': true,
        'versions': [
          {
            'version': 2,
            'uploaderName': '이나',
            'note': '오타 고침',
            'createdAt': now,
            'size': 10,
            'url': '/files/v2',
          },
          {
            'version': 1,
            'uploaderName': '김가',
            'createdAt': now,
            'size': 5,
            'url': '/files/v1',
          },
        ],
      }),
      'POST /api/drive/files/x0/versions/1/restore': (_) =>
          ok(file('x0', '회의록.txt', version: 3)),
      'DELETE /api/drive/files/x0': (_) => ok({'ok': true}),
    };
    await pump(tester, s);
    await tester.tap(find.byKey(const ValueKey('drive-file-x0')));
    await tester.pumpAndSettle();
    expect(find.text('판 기록 2'), findsOneWidget);
    expect(find.text('오타 고침'), findsOneWidget);
    // 지금 판(2)에는 되돌리기가 없다.
    expect(find.byKey(const ValueKey('drive-version-restore-2')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('drive-version-restore-1')));
    await tester.pumpAndSettle();
    expect(
      calls.any((c) => c.path == '/api/drive/files/x0/versions/1/restore'),
      isTrue,
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.byKey(const ValueKey('drive-file-delete')));
    await tester.pumpAndSettle();
    expect(
      calls.any((c) => c.method == 'DELETE' && c.path == '/api/drive/files/x0'),
      isTrue,
    );
    expect(find.text('판 기록 2'), findsNothing, reason: '지우면 창이 닫힌다');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('휴지통 — 되살리기와 영구 삭제(한 번 더 묻는다)', (tester) async {
    final s = session();
    var trashed = true;
    routes = {
      'GET /api/drive': (r) => ok(listing()),
      'GET /api/drive/trash': (_) => ok({
        'folders': trashed
            ? [
                {'id': 'f9', 'name': '옛 자료', 'deletedAt': now, 'path': ''},
              ]
            : <Object>[],
        'files': [
          {
            ...file('x9', '초안.docx'),
            'url': null,
            'deletedAt': now,
            'path': '기획',
          },
        ],
      }),
      'POST /api/drive/trash/restore': (_) {
        trashed = false;
        return ok({'id': 'f9', 'name': '옛 자료'});
      },
      'DELETE /api/drive/trash/file/x9': (_) =>
          ok({'ok': true, 'folders': 0, 'files': 1}),
    };
    await pump(tester, s);
    await tester.tap(find.byKey(const ValueKey('drive-trash')));
    await tester.pumpAndSettle();
    expect(find.text('옛 자료'), findsOneWidget);
    expect(find.textContaining('기획 ·'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('drive-restore-f9')));
    await tester.pumpAndSettle();
    expect(calls.single.body, {'kind': 'folder', 'id': 'f9'});
    expect(find.text('옛 자료'), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.byKey(const ValueKey('drive-purge-x9')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('drive-purge-ok')));
    await tester.pumpAndSettle();
    expect(calls.last.method, 'DELETE');
    expect(calls.last.path, '/api/drive/trash/file/x9');
  });
}
