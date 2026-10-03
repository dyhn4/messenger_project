import 'dart:convert';

import 'package:client/models/announcement.dart';
import 'package:client/models/app_user.dart';
import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/models/text_format.dart';
import 'package:client/models/mention.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/announcement_banner.dart';
import 'package:client/widgets/message_bubble.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 메시지 수정 업그레이드(사진·파일 메시지의 설명글 수정 + 첨부 삭제)와 토픽 공지 업그레이드(메시지를 공지로
/// 등록, 배너의 X 숨기기·몸통 탭 상세보기, 사진 공지)를 위젯 수준에서 본다(상세·목록·글쓰기 창은 announcement_ui_test.dart). PC(호버 더보기)와 폭 360 모바일
/// (길게 누르기 시트) 둘 다.

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

final _me = AppUser(id: 'me', username: 'me', name: '나');
final _kim = AppUser(id: 'u2', username: 'kim', name: '김철수');

Map<String, dynamic> _announcementJson(
  String id, {
  String text = '이번 주 금요일 회식',
  String authorId = 'u2',
  String? messageId,
  String? imageUrl,
}) => {
  'id': id,
  'roomId': 'r1',
  'authorId': authorId,
  'authorName': authorId == 'me' ? '나' : '김철수',
  'text': text,
  'createdAt': DateTime(2026, 9, 30).millisecondsSinceEpoch,
  'pinned': true,
  'messageId': messageId,
  'imageUrl': imageUrl,
  'imageThumbnailUrl': imageUrl,
};

Room _room({
  String id = 'r1',
  RoomType type = RoomType.topic,
  bool secret = false,
  Announcement? announcement,
}) => Room(
  id: id,
  teamId: 't1',
  type: type,
  name: type == RoomType.dm ? null : '영업방',
  members: [_me, _kim],
  createdAt: DateTime(2026),
  lastRead: {},
  isSecret: secret,
  latestAnnouncement: announcement,
);

class _Server {
  final requests = <http.Request>[];
  late final client = MockClient((request) async {
    requests.add(request);
    if (request.method == 'POST' &&
        request.url.path == '/api/rooms/r1/announcements') {
      return _json(_announcementJson('a-new', messageId: 'm1'), 201);
    }
    if (request.method == 'DELETE') return _json({'ok': true});
    return _json(<Object>[]);
  });

  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
}

Session _session(_Server server, List<Room> rooms, {Team? team}) {
  final session = Session(
    notifications: _QuietNotifications(),
    settings: AppSettings(),
  );
  session.serverUrl = 'https://test.local';
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: server.client,
  );
  session.userId = 'me';
  session.name = '나';
  session.accountRole = AccountRole.member;
  final t = team ?? Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  session.teams.add(t);
  session.currentTeam = t;
  session.rooms.addAll(rooms);
  return session;
}

MessageAttachment _image(String id) => MessageAttachment(
  id: id,
  kind: 'image',
  fileUrl: '/uploads/$id.png',
  fileName: '$id.png',
  thumbnailUrl: '/uploads/${id}_t.png',
);

Message _imageMessage({
  String sender = 'me',
  String? caption = '회의 자료',
  List<MessageAttachment>? attachments,
  String id = 'm1',
}) {
  final items = attachments ?? [_image('a1'), _image('a2'), _image('a3')];
  return Message(
    id: id,
    roomId: 'r1',
    senderId: sender,
    senderName: sender == 'me' ? '나' : '김철수',
    type: MessageType.image,
    text: caption,
    fileUrl: items.first.fileUrl,
    fileName: items.first.fileName,
    thumbnailUrl: items.first.thumbnailUrl,
    attachments: items,
    createdAt: DateTime.now(),
  );
}

Message _textMessage({
  String sender = 'u2',
  String text = '내일 회의 10시',
  String id = 'm1',
}) => Message(
  id: id,
  roomId: 'r1',
  senderId: sender,
  senderName: sender == 'me' ? '나' : '김철수',
  type: MessageType.text,
  text: text,
  createdAt: DateTime.now(),
);

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 메뉴·대화상자가 닫히고 열리는 애니메이션까지 흘려보낸다(이미지 미리보기가 있어 pumpAndSettle은 못 쓴다).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// 길게 누르기 시트에서 항목을 누른다 — 항목이 많아 작은 화면에서는 스크롤해야 닿는다.
Future<void> _tapInSheet(WidgetTester tester, String label) async {
  final item = find.text(label);
  await tester.scrollUntilVisible(
    item,
    80,
    scrollable: find
        .descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.tap(item);
  await _settle(tester);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

typedef _MediaEdit =
    Future<void> Function(
      String,
      String, {
      List<TextFormatRun>? format,
      List<Mention>? mentions,
      List<String> removeAttachmentIds,
    });

Future<void> _pumpBubble(
  WidgetTester tester,
  Session session,
  Message message, {
  _MediaEdit? onEditMedia,
  Future<void> Function(String)? onDelete,
  Size size = const Size(700, 700),
}) async {
  _size(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: MessageBubble(
            session: session,
            message: message,
            resolveUrl: session.resolveUrl,
            isMine: message.senderId == 'me',
            sender: message.senderId == 'me' ? _me : _kim,
            onOpenThread: (_) {},
            onEdit: (id, text, {format, mentions}) async {},
            onEditMedia: onEditMedia,
            onDelete: onDelete ?? (_) async {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 한 테스트에서 마우스 포인터는 하나만 둔다(두 번 추가하면 마우스 추적기가 단언 실패한다).
TestGesture? _mouse;

/// 말풍선에 마우스를 올리고 툴바의 ⋯(더보기)를 연다.
Future<void> _openMoreMenu(WidgetTester tester, Finder over) async {
  if (_mouse == null) {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(() async {
      await gesture.removePointer();
      _mouse = null;
    });
    _mouse = gesture;
  }
  await _mouse!.moveTo(Offset.zero);
  await tester.pump(const Duration(milliseconds: 200));
  await _mouse!.moveTo(tester.getCenter(over.first));
  await _settle(tester);
  await tester.tap(find.byIcon(Icons.more_vert).last);
  await _settle(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('사진·파일 메시지 수정', () {
    testWidgets('PC: 수정 모드에서 첨부를 X로 표시하고 저장하면 지울 첨부 id와 설명글을 보낸다', (
      tester,
    ) async {
      final session = _session(_Server(), [_room()]);
      String? savedText;
      List<String>? savedRemove;
      await _pumpBubble(
        tester,
        session,
        _imageMessage(),
        onEditMedia:
            (
              id,
              text, {
              format,
              mentions,
              removeAttachmentIds = const [],
            }) async {
              savedText = text;
              savedRemove = removeAttachmentIds;
            },
      );
      await _openMoreMenu(tester, find.text('회의 자료'));
      await tester.tap(find.text('수정'));
      await _settle(tester);
      await _settle(tester);

      // 첨부 세 장이 각각 X 버튼과 함께 나온다.
      for (final id in ['a1', 'a2', 'a3']) {
        expect(find.byKey(ValueKey('remove-attachment-$id')), findsOneWidget);
      }
      expect(find.text('삭제 예정'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('remove-attachment-a2')));
      await tester.pump();
      expect(find.text('삭제 예정'), findsOneWidget);
      // 같은 버튼으로 되돌릴 수도 있다.
      await tester.tap(find.byKey(const ValueKey('remove-attachment-a2')));
      await tester.pump();
      expect(find.text('삭제 예정'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('remove-attachment-a2')));
      await tester.pump();

      await tester.enterText(find.byType(TextField), '회의 자료 (수정)');
      await tester.tap(find.text('저장'));
      await _settle(tester);
      expect(savedText, '회의 자료 (수정)');
      expect(savedRemove, ['a2']);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('설명글 없이 첨부만 남겨도 저장된다(빈 설명글을 보낸다)', (tester) async {
      final session = _session(_Server(), [_room()]);
      String? savedText;
      List<String>? savedRemove;
      await _pumpBubble(
        tester,
        session,
        _imageMessage(caption: null),
        onEditMedia:
            (
              id,
              text, {
              format,
              mentions,
              removeAttachmentIds = const [],
            }) async {
              savedText = text;
              savedRemove = removeAttachmentIds;
            },
      );
      await _openMoreMenu(tester, find.byType(MessageBubble));
      await tester.tap(find.text('수정'));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('remove-attachment-a1')));
      await tester.pump();
      await tester.tap(find.text('저장'));
      await _settle(tester);
      expect(savedText, '');
      expect(savedRemove, ['a1']);
      await _finish(tester);
    });

    testWidgets('첨부를 모두 지우고 설명글도 없으면 저장 대신 메시지 삭제를 권한다', (tester) async {
      final session = _session(_Server(), [_room()]);
      var edited = false;
      String? deleted;
      await _pumpBubble(
        tester,
        session,
        _imageMessage(caption: null, attachments: [_image('a1')]),
        onEditMedia:
            (
              id,
              text, {
              format,
              mentions,
              removeAttachmentIds = const [],
            }) async {
              edited = true;
            },
        onDelete: (id) async => deleted = id,
      );
      await _openMoreMenu(tester, find.byType(MessageBubble));
      await tester.tap(find.text('수정'));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('remove-attachment-a1')));
      await tester.pump();
      await tester.tap(find.text('저장'));
      await _settle(tester);

      expect(find.textContaining('메시지를 삭제할까요?'), findsOneWidget);
      expect(edited, isFalse);
      // "계속 수정"이면 수정 모드로 돌아간다.
      await tester.tap(find.text('계속 수정'));
      await _settle(tester);
      expect(find.text('저장'), findsOneWidget);
      expect(deleted, isNull);

      await tester.tap(find.text('저장'));
      await _settle(tester);
      await tester.tap(find.widgetWithText(TextButton, '삭제'));
      await _settle(tester);
      expect(deleted, 'm1');
      expect(edited, isFalse);
      await _finish(tester);
    });

    testWidgets('파일 메시지는 파일 이름 칩에 X가 붙는다', (tester) async {
      final session = _session(_Server(), [_room()]);
      List<String>? savedRemove;
      final file = MessageAttachment(
        id: 'f1',
        kind: 'file',
        fileUrl: '/uploads/f1.pdf',
        fileName: '견적서.pdf',
      );
      final message = Message(
        id: 'm1',
        roomId: 'r1',
        senderId: 'me',
        senderName: '나',
        type: MessageType.file,
        text: '견적서 보냅니다',
        fileUrl: file.fileUrl,
        fileName: file.fileName,
        attachments: [file],
        createdAt: DateTime.now(),
      );
      await _pumpBubble(
        tester,
        session,
        message,
        onEditMedia:
            (
              id,
              text, {
              format,
              mentions,
              removeAttachmentIds = const [],
            }) async {
              savedRemove = removeAttachmentIds;
            },
      );
      await _openMoreMenu(tester, find.text('견적서 보냅니다'));
      await tester.tap(find.text('수정'));
      await _settle(tester);
      expect(find.text('견적서.pdf'), findsWidgets);
      await tester.tap(find.text('저장'));
      await _settle(tester);
      expect(savedRemove, isEmpty);
      await _finish(tester);
    });

    testWidgets('비밀 대화의 사진 메시지와 남의 메시지에는 수정 항목이 없다', (tester) async {
      final secretRoom = _room(type: RoomType.dm, secret: true);
      final session = _session(_Server(), [secretRoom]);
      await _pumpBubble(
        tester,
        session,
        _imageMessage(),
        onEditMedia:
            (
              id,
              text, {
              format,
              mentions,
              removeAttachmentIds = const [],
            }) async {},
      );
      await _openMoreMenu(tester, find.text('회의 자료'));
      expect(find.text('복사'), findsOneWidget);
      expect(find.text('수정'), findsNothing);
      await _finish(tester);

      final session2 = _session(_Server(), [_room()]);
      await _pumpBubble(
        tester,
        session2,
        _imageMessage(sender: 'u2'),
        onEditMedia:
            (
              id,
              text, {
              format,
              mentions,
              removeAttachmentIds = const [],
            }) async {},
      );
      await _openMoreMenu(tester, find.text('회의 자료'));
      expect(find.text('복사'), findsOneWidget);
      expect(find.text('수정'), findsNothing);
      await _finish(tester);
    });

    testWidgets('모바일(폭 360): 길게 누르면 시트에 수정이 있고 수정 모드가 넘치지 않는다', (tester) async {
      final session = _session(_Server(), [_room()]);
      List<String>? savedRemove;
      await _pumpBubble(
        tester,
        session,
        _imageMessage(),
        size: const Size(360, 780),
        onEditMedia:
            (
              id,
              text, {
              format,
              mentions,
              removeAttachmentIds = const [],
            }) async {
              savedRemove = removeAttachmentIds;
            },
      );
      await tester.longPress(find.text('회의 자료'));
      await _settle(tester);
      expect(find.text('수정'), findsOneWidget);
      await _tapInSheet(tester, '수정');

      expect(
        find.byKey(const ValueKey('remove-attachment-a3')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('remove-attachment-a3')));
      await tester.pump();
      await tester.tap(find.text('저장'));
      await _settle(tester);
      expect(savedRemove, ['a3']);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('글 메시지 수정은 그대로(빈 글은 저장 안 됨)', (tester) async {
      final session = _session(_Server(), [_room()]);
      String? savedText;
      _size(tester, const Size(700, 700));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              session: session,
              message: _textMessage(sender: 'me'),
              resolveUrl: session.resolveUrl,
              isMine: true,
              sender: _me,
              onOpenThread: (_) {},
              onEdit: (id, text, {format, mentions}) async => savedText = text,
              onDelete: (_) async {},
            ),
          ),
        ),
      );
      await tester.pump();
      await _openMoreMenu(tester, find.text('내일 회의 10시'));
      await tester.tap(find.text('수정'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('remove-attachment-a1')), findsNothing);
      await tester.enterText(find.byType(TextField), '');
      await tester.tap(find.text('저장'));
      await _settle(tester);
      expect(savedText, isNull);
      await _finish(tester);
    });
  });

  group('메시지를 공지로 등록', () {
    testWidgets('PC: 토픽의 텍스트 메시지 더보기에 "공지 등록" — 누르면 바로 등록하고 토스트', (
      tester,
    ) async {
      final server = _Server();
      final session = _session(server, [_room()]);
      await _pumpBubble(tester, session, _textMessage());
      await _openMoreMenu(tester, find.text('내일 회의 10시'));
      expect(find.text('공지 등록'), findsOneWidget);
      await tester.tap(find.text('공지 등록'));
      await _settle(tester);

      final posts = server.called('POST', '/api/rooms/r1/announcements');
      expect(posts, hasLength(1));
      expect(jsonDecode(posts.single.body), {'messageId': 'm1'});
      expect(find.text('공지로 등록했습니다.'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('이미 고정 공지가 있으면 바꿀지 묻고, 취소하면 등록하지 않는다', (tester) async {
      final server = _Server();
      final room = _room(
        announcement: Announcement.fromJson(_announcementJson('old')),
      );
      final session = _session(server, [room]);
      await _pumpBubble(tester, session, _textMessage());
      await _openMoreMenu(tester, find.text('내일 회의 10시'));
      await tester.tap(find.text('공지 등록'));
      await _settle(tester);
      expect(find.textContaining('기존 공지를 이 메시지로 바꿀까요?'), findsOneWidget);

      await tester.tap(find.text('취소'));
      await _settle(tester);
      expect(server.called('POST', '/api/rooms/r1/announcements'), isEmpty);

      await _openMoreMenu(tester, find.text('내일 회의 10시'));
      await tester.tap(find.text('공지 등록'));
      await _settle(tester);
      await tester.tap(find.text('바꾸기'));
      await _settle(tester);
      expect(
        server.called('POST', '/api/rooms/r1/announcements'),
        hasLength(1),
      );
      await _finish(tester);
    });

    testWidgets('이미지 메시지도 공지로 등록할 수 있다', (tester) async {
      final server = _Server();
      final session = _session(server, [_room()]);
      await _pumpBubble(tester, session, _imageMessage(sender: 'u2'));
      await _openMoreMenu(tester, find.text('회의 자료'));
      await tester.tap(find.text('공지 등록'));
      await _settle(tester);
      expect(
        server.called('POST', '/api/rooms/r1/announcements'),
        hasLength(1),
      );
      await _finish(tester);
    });

    testWidgets('파일·이모티콘·삭제된 메시지, 그룹·1:1·비밀 대화에서는 항목이 없다', (tester) async {
      final file = MessageAttachment(
        id: 'f1',
        kind: 'file',
        fileUrl: '/uploads/f1.pdf',
        fileName: 'a.pdf',
      );
      final cases = <String, (Room, Message)>{
        '파일': (
          _room(),
          Message(
            id: 'm1',
            roomId: 'r1',
            senderId: 'u2',
            senderName: '김철수',
            type: MessageType.file,
            text: '파일 설명',
            fileUrl: file.fileUrl,
            attachments: [file],
            createdAt: DateTime.now(),
          ),
        ),
        '그룹': (_room(type: RoomType.group), _textMessage()),
        '1:1': (_room(type: RoomType.dm), _textMessage()),
        '비밀 대화': (_room(type: RoomType.dm, secret: true), _textMessage()),
      };
      for (final entry in cases.entries) {
        final session = _session(_Server(), [entry.value.$1]);
        await _pumpBubble(tester, session, entry.value.$2);
        await _openMoreMenu(tester, find.text(entry.value.$2.text!));
        expect(find.text('복사'), findsOneWidget, reason: entry.key);
        expect(find.text('공지 등록'), findsNothing, reason: entry.key);
        await _finish(tester);
      }
    });

    testWidgets('공지를 쓸 권한이 없으면(관리자만 토픽을 만들 수 있는 팀의 일반 멤버) 항목이 없다', (
      tester,
    ) async {
      final team = Team(
        id: 't1',
        name: '영업팀',
        createdAt: DateTime(2026),
        topicCreationPolicy: TopicCreationPolicy.admin,
      );
      final session = _session(_Server(), [_room()], team: team);
      await _pumpBubble(tester, session, _textMessage());
      await _openMoreMenu(tester, find.text('내일 회의 10시'));
      expect(find.text('복사'), findsOneWidget);
      expect(find.text('공지 등록'), findsNothing);
      await _finish(tester);
    });

    testWidgets('이 메시지가 이미 고정 공지면 항목을 숨기고 말풍선에 작은 공지 표시가 붙는다', (tester) async {
      final room = _room(
        announcement: Announcement.fromJson(
          _announcementJson('a1', messageId: 'm1'),
        ),
      );
      final session = _session(_Server(), [room]);
      await _pumpBubble(tester, session, _textMessage());
      expect(find.byKey(const ValueKey('announcement-marker')), findsOneWidget);
      await _openMoreMenu(tester, find.text('내일 회의 10시'));
      expect(find.text('공지 등록'), findsNothing);
      await _finish(tester);

      // 다른 메시지에는 표시가 없다.
      final other = _session(_Server(), [room]);
      await _pumpBubble(tester, other, _textMessage(id: 'm2'));
      expect(find.byKey(const ValueKey('announcement-marker')), findsNothing);
      await _finish(tester);
    });

    testWidgets('모바일(폭 360): 길게 누르면 시트에 공지 등록', (tester) async {
      final server = _Server();
      final session = _session(server, [_room()]);
      await _pumpBubble(
        tester,
        session,
        _textMessage(),
        size: const Size(360, 780),
      );
      // Windows에서는 본문이 드래그 선택용 SelectableText라 글자 위 길게 누르기를 가져간다 — 말풍선 여백을 누른다.
      await tester.longPressAt(
        tester.getTopLeft(find.text('내일 회의 10시')) - const Offset(6, 4),
      );
      await _settle(tester);
      expect(find.text('공지 등록'), findsOneWidget);
      // 시트 항목이 늘어(할 일로 등록 등) 작은 화면에서는 스크롤해야 보인다.
      await tester.ensureVisible(find.text('공지 등록'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('공지 등록'));
      await _settle(tester);
      expect(
        server.called('POST', '/api/rooms/r1/announcements'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });
  });

  group('공지 배너', () {
    Future<void> pumpBanner(
      WidgetTester tester,
      Session session,
      Room room, {
      Size size = const Size(700, 600),
    }) async {
      _size(tester, size);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                AnnouncementBanner(session: session, room: room),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    Text announcementText(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const ValueKey('announcement-text')));

    testWidgets('접기·펼치기·⋯ 메뉴는 없고 오른쪽 끝에 X(숨기기) 하나뿐이다 — 글 3줄과 작성자·시각 줄', (
      tester,
    ) async {
      final room = _room(
        announcement: Announcement.fromJson(
          _announcementJson(
            'a1',
            text: '회식은 금요일 저녁 7시에 합니다. 장소는 사무실 근처 식당이고 참석 여부를 알려 주세요.',
          ),
        ),
      );
      final session = _session(_Server(), [room]);
      await pumpBanner(tester, session, room, size: const Size(360, 600));
      expect(announcementText(tester).maxLines, 3);
      expect(
        find.byKey(const ValueKey('announcement-collapse-toggle')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('announcement-more')), findsNothing);
      expect(find.byIcon(Icons.more_vert), findsNothing);
      expect(find.byTooltip('접어두기'), findsNothing);
      expect(find.byTooltip('펼치기'), findsNothing);
      expect(find.byKey(const ValueKey('announcement-hide')), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
      // 시각은 "yyyy/MM/dd AM h:mm" — 9월 30일 0시 정각이라 AM 12:00.
      expect(find.text('김철수 · 2026/09/30 AM 12:00'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('X로 숨기기: 나에게만 배너를 치우고(저장), 새 공지가 오면 다시 보인다', (tester) async {
      final server = _Server();
      final room = _room(
        announcement: Announcement.fromJson(_announcementJson('a1')),
      );
      final session = _session(server, [room]);
      await pumpBanner(tester, session, room);
      expect(find.byKey(const ValueKey('announcement-text')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('announcement-hide')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('announcement-text')), findsNothing);
      // 서버에는 아무것도 보내지 않는다(나에게만).
      expect(server.requests, isEmpty);

      // 새 공지 — 다시 보인다.
      room.latestAnnouncement = Announcement.fromJson(
        _announcementJson('a2', text: '새 공지'),
      );
      await pumpBanner(tester, session, room);
      expect(find.text('새 공지'), findsOneWidget);
      await _finish(tester);

      // 앱을 다시 켜도(새 방 인스턴스) 숨긴 공지는 숨은 채다.
      final room2 = _room(
        announcement: Announcement.fromJson(_announcementJson('a1')),
      );
      await pumpBanner(tester, _session(_Server(), [room2]), room2);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('announcement-text')), findsNothing);
      await _finish(tester);
    });

    testWidgets('예전 접어두기 값이 같은 키에 남아 있어도 숨김만 읽는다', (tester) async {
      SharedPreferences.setMockInitialValues({
        'announcement_view:me:r1': jsonEncode({
          'hidden': 'a1',
          'collapsed': 'a1',
        }),
      });
      final room = _room(
        announcement: Announcement.fromJson(_announcementJson('a1')),
      );
      await pumpBanner(tester, _session(_Server(), [room]), room);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('announcement-text')), findsNothing);
      await _finish(tester);
    });

    testWidgets('배너 몸통을 누르면 그 공지의 상세보기가 바로 열린다(작성자 줄·본문·댓글 입력칸)', (
      tester,
    ) async {
      final server = _Server();
      final room = _room(
        announcement: Announcement.fromJson(_announcementJson('a1')),
      );
      final session = _session(server, [room]);
      await pumpBanner(tester, session, room, size: const Size(360, 700));
      await tester.tap(find.byKey(const ValueKey('announcement-text')));
      await _settle(tester);
      // 공지 목록이 아니라 상세보기다.
      expect(
        find.byKey(const ValueKey('announcement-detail-card')),
        findsOneWidget,
      );
      expect(find.text('댓글을 입력하세요....'), findsOneWidget);
      expect(find.text('등록된 공지가 없습니다.'), findsNothing);
      expect(
        server.called('GET', '/api/rooms/r1/announcements/a1/comments'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('X를 눌러도 상세가 열리지 않는다', (tester) async {
      final room = _room(
        announcement: Announcement.fromJson(_announcementJson('a1')),
      );
      final session = _session(_Server(), [room]);
      await pumpBanner(tester, session, room);
      await tester.tap(find.byKey(const ValueKey('announcement-hide')));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('announcement-detail-card')),
        findsNothing,
      );
      await _finish(tester);
    });

    testWidgets('사진 공지는 배너에 사진이 보이고, 사진을 눌러도 상세보기가 열린다', (tester) async {
      final room = _room(
        announcement: Announcement.fromJson(
          _announcementJson('a1', text: '', imageUrl: '/files/tok'),
        ),
      );
      final session = _session(_Server(), [room]);
      await pumpBanner(tester, session, room, size: const Size(360, 700));
      expect(find.byKey(const ValueKey('announcement-image')), findsOneWidget);
      // 글이 없으면 글 줄은 안 그린다.
      expect(find.byKey(const ValueKey('announcement-text')), findsNothing);

      // 사진 위젯은 터치를 무시하고(IgnorePointer) 아래 배너 몸통이 받는다.
      await tester.tap(
        find.byKey(const ValueKey('announcement-image')),
        warnIfMissed: false,
      );
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('announcement-detail-card')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });
  });

  group('모델', () {
    test('공지 JSON: 원본 메시지 id와 사진 필드를 읽고, 사진만 있는 공지의 미리보기는 [사진]', () {
      final a = Announcement.fromJson(
        _announcementJson(
          'a1',
          text: '',
          messageId: 'm9',
          imageUrl: '/files/x',
        ),
      );
      expect(a.messageId, 'm9');
      expect(a.hasImage, isTrue);
      expect(a.previewText, '[사진]');
      final plain = Announcement.fromJson(_announcementJson('a2'));
      expect(plain.messageId, isNull);
      expect(plain.hasImage, isFalse);
      expect(plain.previewText, '이번 주 금요일 회식');
    });

    test('RoomChatController.applyEdit: 첨부를 지운 수정이 첨부 목록·파일 칸·타입을 바꾼다', () {
      final room = _room();
      final session = _session(_Server(), [room]);
      final c = session.controllerFor(room);
      final m = _imageMessage();
      c.messages.add(m);
      final edited = Message.fromJson({
        'id': 'm1',
        'roomId': 'r1',
        'senderId': 'me',
        'senderName': '나',
        'type': 'image',
        'text': '회의 자료',
        'fileUrl': '/uploads/a2.png',
        'fileName': 'a2.png',
        'createdAt': 1,
        'editedAt': 2,
        'attachments': [
          {
            'id': 'a2',
            'kind': 'image',
            'fileUrl': '/uploads/a2.png',
            'fileName': 'a2.png',
          },
        ],
      });
      c.applyEdit(edited);
      expect(m.attachments.map((a) => a.id), ['a2']);
      expect(m.fileUrl, '/uploads/a2.png');
      expect(m.editedAt, isNotNull);

      // 첨부를 전부 지우고 설명글만 남기면 글 메시지가 된다.
      c.applyEdit(
        Message.fromJson({
          'id': 'm1',
          'roomId': 'r1',
          'senderId': 'me',
          'senderName': '나',
          'type': 'text',
          'text': '글만 남김',
          'createdAt': 1,
          'editedAt': 3,
          'attachments': <Object>[],
        }),
      );
      expect(m.type, MessageType.text);
      expect(m.attachments, isEmpty);
      expect(m.fileUrl, isNull);
      expect(m.text, '글만 남김');
    });
  });
}
