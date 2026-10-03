import 'dart:convert';

import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/files_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/attachment_widgets.dart';
import 'package:client/widgets/deleted_file_card.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _json = {'content-type': 'application/json; charset=utf-8'};

Map<String, dynamic> _row(
  String id,
  String senderId,
  String sender,
  int minute,
) => {
  'id': id,
  'attachmentId': 'att-$id',
  'roomId': 'r1',
  'senderId': senderId,
  'senderName': sender,
  'type': 'image',
  'fileUrl': '/uploads/$id.png',
  'fileName': '$id.png',
  'attachments': [
    {
      'id': 'att-$id',
      'kind': 'image',
      'fileUrl': '/uploads/$id.png',
      'fileName': '$id.png',
    },
  ],
  'createdAt': DateTime(2026, 9, 23, 14, minute).millisecondsSinceEpoch,
};

MessageAttachment _image(String id, {bool deleted = false}) =>
    MessageAttachment(
      id: id,
      kind: 'image',
      fileUrl: deleted ? '' : '/uploads/$id.png',
      fileName: '$id.png',
      deleted: deleted,
    );

MessageAttachment _file(String id, {bool deleted = false}) => MessageAttachment(
  id: id,
  kind: 'file',
  fileUrl: deleted ? '' : '/uploads/$id.pdf',
  fileName: '$id.pdf',
  deleted: deleted,
);

void main() {
  late List<String> deletes;
  late bool deleted;
  TestGesture? mouse;
  setUp(() => mouse = null);

  /// 파일 패널: 내가 올린 m1, 남이 올린 m2. [deleted]가 켜지면 m1이 목록에서 빠진다.
  Session session({AccountRole role = AccountRole.member}) {
    deletes = [];
    deleted = false;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/attachments') {
        return http.Response(
          jsonEncode([
            if (!deleted) _row('m1', 'me', '나', 2),
            _row('m2', 'u-other', '이영희', 1),
          ]),
          200,
          headers: _json,
        );
      }
      if (request.method == 'DELETE' && path.startsWith('/api/messages/')) {
        deletes.add(path);
        deleted = true;
        return http.Response(jsonEncode({'id': 'm1'}), 200, headers: _json);
      }
      return http.Response('[]', 200, headers: _json);
    });
    final s = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    s.serverUrl = 'https://test.local';
    s.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: client,
    );
    s.userId = 'me';
    s.accountRole = role;
    s.currentTeam = Team(id: 't1', name: '팀', createdAt: DateTime(2026));
    return s;
  }

  Future<void> openPanel(
    WidgetTester tester,
    Session s, {
    double width = 1200,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FilesScreen(session: s)),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }

  /// 마우스를 [row] 줄 위에 올리고 더보기를 연다.
  Future<void> openMore(WidgetTester tester, String fileName) async {
    if (mouse == null) {
      mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse!.removePointer);
      await mouse!.addPointer(location: Offset.zero);
    }
    await mouse!.moveTo(tester.getCenter(find.text(fileName)));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pump();
  }

  group('모델', () {
    test('삭제된 첨부는 fileUrl 없이 deleted: true로 읽는다', () {
      final a = MessageAttachment.fromJson({
        'id': 'a1',
        'kind': 'image',
        'fileUrl': null,
        'fileName': 'x.png',
        'deleted': true,
      });
      expect(a.deleted, isTrue);
      expect(a.fileUrl, '');
      expect(a.fileName, 'x.png');
      expect(
        MessageAttachment.fromJson({
          'id': 'a2',
          'kind': 'file',
          'fileUrl': '/u/a',
        }).deleted,
        isFalse,
      );
    });

    test('liveAttachments는 지운 첨부를 뺀다', () {
      final m = Message(
        id: 'm',
        roomId: 'r',
        senderName: 's',
        type: MessageType.file,
        createdAt: DateTime(2026),
        attachments: [_file('a'), _file('b', deleted: true), _file('c')],
      );
      expect(m.liveAttachments.map((a) => a.id), ['a', 'c']);
    });
  });

  group('message:edited 반영', () {
    test('파일 삭제 알림이 오면 첨부가 삭제 표시로 바뀌고 설명글은 그대로다', () {
      final s = session();
      final room = Room(
        id: 'r1',
        teamId: 't1',
        type: RoomType.topic,
        name: '영업방',
        members: const [],
        createdAt: DateTime(2026),
        lastRead: {},
      );
      s.rooms.add(room);
      final c = s.controllerFor(room);
      final m = Message(
        id: 'm1',
        roomId: 'r1',
        senderId: 'me',
        senderName: '나',
        type: MessageType.image,
        text: '셋',
        fileUrl: '/uploads/a.png',
        fileName: 'a.png',
        attachments: [_image('a'), _image('b')],
        createdAt: DateTime(2026),
      );
      c.messages.add(m);
      c.applyEdit(
        Message.fromJson({
          'id': 'm1',
          'roomId': 'r1',
          'senderId': 'me',
          'senderName': '나',
          'type': 'image',
          'text': '셋',
          'fileUrl': '/uploads/b.png',
          'fileName': 'b.png',
          'createdAt': 1,
          'editedAt': null,
          'attachments': [
            {
              'id': 'a',
              'kind': 'image',
              'fileUrl': null,
              'fileName': 'a.png',
              'deleted': true,
            },
            {
              'id': 'b',
              'kind': 'image',
              'fileUrl': '/uploads/b.png',
              'fileName': 'b.png',
              'deleted': false,
            },
          ],
        }),
      );
      expect(m.attachments.map((a) => a.deleted), [true, false]);
      expect(m.liveAttachments.map((a) => a.id), ['b']);
      expect(m.fileUrl, '/uploads/b.png');
      expect(m.text, '셋');
      expect(m.editedAt, isNull);
    });
  });

  group('삭제된 첨부 자리표시', () {
    Future<void> pumpBubble(
      WidgetTester tester,
      Widget child, {
      double width = 900,
    }) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(alignment: Alignment.topLeft, child: child),
          ),
        ),
      );
      await tester.pump();
    }

    Session plain() {
      final s = Session(
        notifications: NotificationService(),
        settings: AppSettings(),
      );
      s.serverUrl = 'https://test.local';
      return s;
    }

    testWidgets('사진 한 장을 지우면 흐린 "삭제된 파일입니다" 카드', (tester) async {
      await pumpBubble(
        tester,
        ChatImageAttachments(
          session: plain(),
          attachments: [_image('a', deleted: true)],
        ),
      );
      expect(find.byType(DeletedFileCard), findsOneWidget);
      expect(find.text('삭제된 파일입니다'), findsOneWidget);
      expect(find.text('a.png'), findsOneWidget);
      expect(find.byType(ClipRRect), findsNothing);
      await close(tester);
    });

    testWidgets('사진 묶음에서 지운 칸만 카드가 되고 나머지는 그대로, 전체 다운로드는 남은 장수만', (
      tester,
    ) async {
      await pumpBubble(
        tester,
        ChatImageAttachments(
          session: plain(),
          attachments: [_image('a'), _image('b', deleted: true), _image('c')],
        ),
      );
      expect(find.byType(DeletedFileCard), findsOneWidget);
      expect(find.byType(ClipRRect), findsNWidgets(2));
      expect(find.text('전체 다운로드 (2)'), findsOneWidget);
      await close(tester);
    });

    testWidgets('사진을 모두 지우면 카드만 남고 전체 다운로드는 없다', (tester) async {
      await pumpBubble(
        tester,
        ChatImageAttachments(
          session: plain(),
          attachments: [_image('a', deleted: true), _image('b', deleted: true)],
        ),
      );
      expect(find.byType(DeletedFileCard), findsNWidgets(2));
      expect(find.textContaining('전체 다운로드'), findsNothing);
      await close(tester);
    });

    testWidgets('파일 목록에서 지운 파일은 카드, 남은 파일은 받을 수 있다', (tester) async {
      await pumpBubble(
        tester,
        ChatFileAttachments(
          session: plain(),
          attachments: [_file('a', deleted: true), _file('b'), _file('c')],
        ),
      );
      expect(find.byType(DeletedFileCard), findsOneWidget);
      expect(find.byType(DownloadableFile), findsNWidgets(2));
      expect(find.text('전체 다운로드 (2)'), findsOneWidget);
      await close(tester);
    });

    testWidgets('좁은 폭(360)에서도 넘치지 않는다', (tester) async {
      await pumpBubble(
        tester,
        ChatImageAttachments(
          session: plain(),
          attachments: [
            _image('a'),
            _image('b', deleted: true),
            _image('c'),
            _image('d', deleted: true),
          ],
        ),
        width: 360,
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(DeletedFileCard), findsNWidgets(2));
      await close(tester);
    });
  });

  group('파일 패널 삭제', () {
    testWidgets('일반 멤버는 내 파일에만 삭제가 나온다', (tester) async {
      await openPanel(tester, session());
      await openMore(tester, 'm1.png');
      expect(find.text('삭제'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.more_vert)); // 닫기
      await tester.pump();

      await openMore(tester, 'm2.png');
      expect(find.text('파일 전달'), findsOneWidget);
      expect(find.text('삭제'), findsNothing);
      await close(tester);
    });

    testWidgets('팀 관리자는 남의 파일에도 삭제가 나온다', (tester) async {
      await openPanel(tester, session(role: AccountRole.admin));
      await openMore(tester, 'm2.png');
      expect(find.text('삭제'), findsOneWidget);
      await close(tester);
    });

    testWidgets('삭제 → 확인 문구 → 서버 호출(첨부 id) → 목록에서 사라진다', (tester) async {
      await openPanel(tester, session());
      await openMore(tester, 'm1.png');
      await tester.tap(find.text('삭제'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('이 파일을 삭제할까요? 파일에 달린 댓글은 남아 있습니다.'), findsOneWidget);

      // 취소하면 아무 일도 없다.
      await tester.tap(find.text('취소'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(deletes, isEmpty);

      await openMore(tester, 'm1.png');
      await tester.tap(find.text('삭제'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('confirm-delete-file')));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(deletes, ['/api/messages/m1/attachments/att-m1']);
      expect(find.text('m1.png'), findsNothing);
      expect(find.text('m2.png'), findsOneWidget);
      await close(tester);
    });

    testWidgets('모바일 폭: 줄을 길게 누르면 시트에 삭제(내 파일만)', (tester) async {
      await openPanel(tester, session(), width: 360);
      await tester.longPress(find.text('m1.png'));
      await tester.pumpAndSettle();
      expect(find.text('파일 전달'), findsOneWidget);
      expect(find.text('삭제'), findsOneWidget);
      // 시트를 닫고 남의 파일을 길게 누르면 삭제가 없다.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('m2.png'));
      await tester.pumpAndSettle();
      expect(find.text('파일 전달'), findsOneWidget);
      expect(find.text('삭제'), findsNothing);
      expect(tester.takeException(), isNull);
      await close(tester);
    });
  });
}
