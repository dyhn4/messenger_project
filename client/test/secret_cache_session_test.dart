import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/chat_socket.dart' show RoomRemovedEvent;
import 'package:client/services/device_identity.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/room_chat_controller.dart';
import 'package:client/services/secret_key_store.dart';
import 'package:client/services/secret_session_manager.dart';
import 'package:client/services/session.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 비밀 대화 평문 캐시(S34)를 방 화면(RoomChatController)·세션 경로로 본다 — 끊긴 동안 서버가 지운 메시지는
/// 다시 받은 히스토리로 평문과 화면에서 빠지고(방 화면이 없어도 세션의 뒷정리로), 목록에서 사라진 방은 서버에
/// 물어 없어졌을 때만 키·평문을 지우고, 예전 형식 평문은 히스토리를 훑어 옮기며, 서버가 정한 시각은 이 기기
/// 시계가 아니라 서버 시각으로 잰다. 타이머 없는 메시지의 평문은 남아 다시 열어도 보인다.

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}

  @override
  Future<void> showMessage({
    required String title,
    required String body,
    required String roomId,
    String? senderName,
    String? conversationTitle,
    String avatarType = 'initial',
    String? avatarEmoji,
    String? avatarColor,
    String? avatarUrl,
    bool isSecret = false,
    bool flashTaskbarUntilRoomOpened = false,
    bool flashWindowFrame = true,
  }) async {}
}

/// 소켓이 붙어 있는 것처럼 — 읽음 신호가 바로 서버에 닿는 경우(이 기기 기준 삭제 예정 시각을 어림한다).
class _ConnectedSession extends Session {
  _ConnectedSession()
    : super(notifications: _QuietNotifications(), settings: AppSettings());

  @override
  bool get secretReadSignalLive => true;
}

/// 메모리 저장소 — 저장된 평문 캐시 값을 테스트가 직접 들여다본다.
class _MemoryStorage extends Fake implements FlutterSecureStorage {
  final Map<String, String> data = {};

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data[key];

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data.remove(key);

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.of(data);

  Map<String, dynamic>? entry(String id, {String roomId = 'r1'}) {
    final raw = data['secretcache/$roomId/$id'];
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  /// 이 기기에 남은 방 [roomId]의 키·계정 표시·평문 키들.
  Iterable<String> keysOfRoom(String roomId) => data.keys.where(
    (k) =>
        k.startsWith('secret/$roomId/') || k.startsWith('secretcache/$roomId/'),
  );

  /// 이전 실행에서 저장해 둔 평문 하나(새 형식).
  void seedText(
    String roomId,
    String id,
    int createdAt, {
    String text = '평문',
    String? parentId,
  }) => data['secretcache/$roomId/$id'] = jsonEncode({
    't': text,
    'c': createdAt,
    'p': ?parentId,
  });

  /// 이전 실행에서 저장해 둔 그 방 키 상태(값은 이 테스트들에서 쓰지 않는다).
  void seedKeys(String roomId, {String? owner}) {
    data['secret/$roomId/epoch'] = '0';
    data['secret/$roomId/n'] = '3';
    data['secret/$roomId/chainKey'] = 'AQID';
    if (owner != null) data['secret/$roomId/owner'] = owner;
  }
}

typedef _Handler = FutureOr<http.Response> Function(http.Request request);

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json'},
);

class _Server {
  final _routes = <(String, RegExp, _Handler)>[];
  final requests = <Uri>[];

  void on(String method, String path, _Handler handler) {
    final pattern = path
        .split('/')
        .map((s) => s.startsWith(':') ? '[^/]+' : RegExp.escape(s))
        .join('/');
    _routes.insert(0, (method, RegExp('^$pattern\$'), handler));
  }

  late final client = MockClient((request) async {
    requests.add(request.url);
    for (final (method, re, handler) in _routes) {
      if (method == request.method && re.hasMatch(request.url.path)) {
        return handler(request);
      }
    }
    return _json(<Object>[]);
  });
}

/// 서버의 GET /rooms/:id/messages처럼 — before "미만" 중 최근 limit개(최대 200)를 오래된 순으로 준다.
/// 같은 밀리초 메시지는 id 순으로 놓는다.
_Handler _history(List<Map<String, dynamic>> all) => (request) {
  final q = request.url.queryParameters;
  final limit = math.min(int.tryParse(q['limit'] ?? '') ?? 50, 200);
  final before = int.tryParse(q['before'] ?? '');
  final eligible = [
    for (final m in all)
      if (before == null || (m['createdAt'] as int) < before) m,
  ]..sort((a, b) {
      final byTime = (b['createdAt'] as int).compareTo(a['createdAt'] as int);
      return byTime != 0 ? byTime : (b['id'] as String).compareTo(a['id'] as String);
    });
  return _json(eligible.take(limit).toList().reversed.toList());
};

const _roomNotFound = {'error': '방을 찾을 수 없습니다.'};
const _notMember = {'error': '이 방의 멤버가 아닙니다.'};

Map<String, dynamic> _user(String id, String name) => {
  'id': id,
  'username': id,
  'name': name,
  'role': 'member',
};

Room _secretRoom({String id = 'r1', int? selfDestructSeconds}) =>
    Room.fromJson({
      'id': id,
      'teamId': 't1',
      'type': 'dm',
      'name': null,
      'members': [_user('me', '나'), _user('u2', '김철수')],
      'createdAt': 1,
      'isSecret': true,
      'secretStatus': 'active',
      'secretSelfDestructSeconds': selfDestructSeconds,
    });

/// 서버가 내려주는 비밀 대화 메시지 — text는 암호문 봉투 모양(캐시가 없으면 복호화 실패로 보인다).
Map<String, dynamic> _message(
  String id,
  int createdAt, {
  String roomId = 'r1',
  String senderId = 'u2',
  bool deleted = false,
  int? readAt,
  int? expiresAt,
  List<Map<String, dynamic>> comments = const [],
}) => {
  'id': id,
  'roomId': roomId,
  'senderId': senderId,
  'senderName': senderId == 'me' ? '나' : '김철수',
  'type': 'text',
  'text': deleted ? null : '{"epoch":0,"n":0}',
  'createdAt': createdAt,
  'deleted': deleted,
  'readAt': readAt,
  'expiresAt': expiresAt,
  'attachments': const <Object>[],
  'comments': comments,
};

Map<String, dynamic> _comment(
  String id,
  String messageId,
  int createdAt, {
  bool deleted = false,
}) => {
  'id': id,
  'messageId': messageId,
  'roomId': 'r1',
  'senderId': 'u2',
  'senderName': '김철수',
  'type': 'text',
  'text': deleted ? null : '{"epoch":0,"n":1}',
  'createdAt': createdAt,
  'deleted': deleted,
};

DateTime _at(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

Session _session(
  _Server server,
  List<Room> rooms,
  SecretKeyStore store, {
  bool connected = false,
}) {
  final session = connected
      ? _ConnectedSession()
      : Session(notifications: _QuietNotifications(), settings: AppSettings());
  session.serverUrl = 'https://test.local';
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: server.client,
  );
  session.userId = 'me';
  session.name = '나';
  session.accountRole = AccountRole.member;
  final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  session.rooms.addAll(rooms);
  session.secretSessionManager = SecretSessionManager(
    session.api!,
    session.chatSocket,
    DeviceIdentity(),
    keyStore: store,
  );
  return session;
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue, reason: '기다리던 상태가 되지 않았습니다');
}

Message? _find(RoomChatController c, String id) =>
    c.messages.where((m) => m.id == id).firstOrNull;

Message? _commentEntry(RoomChatController c, String commentId) => c.messages
    .where((m) => m.type == MessageType.comment && m.asComment!.id == commentId)
    .firstOrNull;

void main() {
  late _MemoryStorage storage;
  late SecretKeyStore store;

  setUp(() {
    storage = _MemoryStorage();
    store = SecretKeyStore(storage: storage);
  });

  tearDown(() => store.dispose());

  test('재연결 동기화 — 끊긴 동안 서버가 자동 삭제한 메시지와 지운 댓글은 화면·평문에서 빠지고, 남은 메시지 평문은 그대로다', () async {
    await store.saveDecryptedText(
      SecretTextRef(roomId: 'r1', id: 'm1', createdAt: _at(1000)),
      '내가 보낸 메시지',
    );
    await store.saveDecryptedText(
      SecretTextRef(roomId: 'r1', id: 'm2', createdAt: _at(2000)),
      '상대 메시지',
    );
    await store.saveDecryptedText(
      SecretTextRef(roomId: 'r1', id: 'c1', parentId: 'm2', createdAt: _at(2500)),
      '댓글',
    );

    var round = 0;
    final server = _Server()
      ..on('GET', '/api/rooms/r1/messages', (_) {
        round++;
        return _json(
          round == 1
              ? [
                  _message('m1', 1000, senderId: 'me'),
                  _message('m2', 2000, comments: [_comment('c1', 'm2', 2500)]),
                ]
              // 끊긴 동안: 상대가 m1을 읽고 타이머가 지나 서버가 지웠고(message:expired를 못 받음),
              // 댓글 c1은 지워졌다(comment:deleted를 못 받음).
              : [
                  _message(
                    'm2',
                    2000,
                    comments: [_comment('c1', 'm2', 2500, deleted: true)],
                  ),
                ],
        );
      });
    final session = _session(server, [_secretRoom()], store);
    final controller = session.controllerFor(session.rooms.first);
    await _until(() => !controller.loading);
    expect(_find(controller, 'm1')?.text, '내가 보낸 메시지');
    expect(_find(controller, 'm2')?.text, '상대 메시지');
    expect(_commentEntry(controller, 'c1')?.asComment?.text, '댓글');

    await controller.refresh();
    expect(_find(controller, 'm1'), isNull);
    expect(storage.entry('m1'), isNull);
    expect(_commentEntry(controller, 'c1')?.asComment?.deleted, isTrue);
    expect(storage.entry('c1'), isNull);
    expect(_find(controller, 'm2')?.text, '상대 메시지');
    expect(storage.entry('m2'), isNotNull);

    // 타이머 없는 비밀 대화 — 앱을 다시 켜도(새 매니저·저장소, 새 방 화면) 남은 메시지는 캐시로 보인다
    // (한 방향 래칫이라 다시 복호화할 수는 없다).
    final restartedStore = SecretKeyStore(storage: storage);
    addTearDown(restartedStore.dispose);
    session.secretSessionManager = SecretSessionManager(
      session.api!,
      session.chatSocket,
      DeviceIdentity(),
      keyStore: restartedStore,
    );
    expect(await session.secretSessionManager!.purgeExpiredTexts(), isEmpty);
    final reopened = RoomChatController(session, session.rooms.first);
    addTearDown(reopened.dispose);
    await _until(() => !reopened.loading);
    expect(_find(reopened, 'm2')?.text, '상대 메시지');
    expect(_find(reopened, 'm2')?.decryptFailed, isFalse);
    expect(storage.entry('m2')!.containsKey('e'), isFalse);
  });

  test('앱을 다시 켠 뒤 뒷정리 — 방 화면을 열지 않아도, 끊긴 동안 서버가 지운 메시지·댓글의 평문을 최근 쪽 범위 안에서 지운다', () async {
    // 이전 실행에서 저장해 둔 평문 — 방 r1의 최근 50개 쪽은 꽉 차고 그 가장 오래된 메시지는 p13(13000)이다.
    storage
      ..seedText('r1', 'old', 5500, text: '최근 쪽보다 오래된 메시지')
      ..seedText('r1', 'mine', 30500, text: '내가 보낸 메시지 — 끊긴 동안 읽히고 만료됨')
      ..seedText('r1', 'unread', 31500, text: '상대가 지운 안 읽은 메시지')
      ..seedText('r1', 'soft', 32000, text: '상대가 지운 읽은 메시지')
      ..seedText('r1', 'kept', 33000, text: '그대로 남은 메시지')
      ..seedText('r1', 'cGone', 33500, text: '지워진 댓글', parentId: 'kept')
      ..seedText('r1', 'readLater', 34000, text: '끊긴 동안 상대가 읽은 내 메시지');
    final readAt = DateTime.now().millisecondsSinceEpoch;
    final expiresAt = readAt + const Duration(days: 1).inMilliseconds;
    final server = _Server()
      ..on(
        'GET',
        '/api/rooms/r1/messages',
        _history([
          for (var i = 0; i < 60; i++) _message('p$i', i * 1000),
          _message('soft', 32000, deleted: true),
          _message('kept', 33000),
          _message(
            'readLater',
            34000,
            senderId: 'me',
            readAt: readAt,
            expiresAt: expiresAt,
          ),
        ]),
      );
    // 새로 켠 앱 — 방 화면(컨트롤러)이 하나도 없다.
    final session = _session(server, [_secretRoom()], store);
    await session.syncSecretTextCaches();

    expect(storage.entry('mine'), isNull);
    expect(storage.entry('unread'), isNull);
    expect(storage.entry('soft'), isNull);
    expect(storage.entry('cGone'), isNull);
    expect(storage.entry('kept')?['t'], '그대로 남은 메시지');
    // 최근 쪽(꽉 참)보다 오래된 메시지는 그 쪽만으로는 모른다 — 남긴다.
    expect(storage.entry('old')?['t'], '최근 쪽보다 오래된 메시지');
    // 끊긴 동안 상대가 읽은 내 메시지 — 서버가 정한 삭제 예정 시각을 적는다(복호화 없이).
    expect(storage.entry('readLater')?['e'], expiresAt);
    expect(storage.entry('readLater')?['f'], isTrue);
    // 목록에 있는 이 계정 방이라는 표시.
    expect(storage.data['secret/r1/owner'], 'me');
  });

  test('목록에 없는 방 — 없어졌거나(404) 이 계정 방인데 멤버가 아니면(403) 키·평문을 지우고, 누구 방인지 모르는 403·다른 계정 방·물어보지 못한 방·아직 있는 방은 둔다', () async {
    // 메시지 id는 서버가 만든 UUID라 방이 달라도 겹치지 않는다.
    storage
      ..seedKeys('gone404')
      ..seedText('gone404', 'x1', 1)
      ..seedKeys('mine403', owner: 'me')
      ..seedText('mine403', 'x2', 1)
      ..seedKeys('unknown403')
      ..seedText('unknown403', 'x3', 1)
      ..seedKeys('other404', owner: 'someone-else')
      ..seedKeys('vanished403')
      ..seedKeys('offline')
      ..seedText('alive', 'a1', 1000, text: '다른 팀 소속이라 목록에 없는 방의 평문');
    final server = _Server()
      ..on('GET', '/api/rooms/gone404/messages', (_) => _json(_roomNotFound, 404))
      ..on('GET', '/api/rooms/mine403/messages', (_) => _json(_notMember, 403))
      ..on('GET', '/api/rooms/unknown403/messages', (_) => _json(_notMember, 403))
      ..on('GET', '/api/rooms/other404/messages', (_) => _json(_roomNotFound, 404))
      ..on('GET', '/api/rooms/vanished403/messages', (_) => _json(_notMember, 403))
      ..on('GET', '/api/rooms/offline/messages', (_) => _json({'error': '서버 오류'}, 500))
      ..on(
        'GET',
        '/api/rooms/alive/messages',
        _history([_message('a1', 1000, roomId: 'alive')]),
      );
    final session = _session(server, const [], store);
    // vanished403은 이번 실행에서 이 계정 목록에 있다가 재연결 때 사라진 방이다.
    await session.syncSecretTextCaches(vanishedRoomIds: ['vanished403']);

    expect(storage.keysOfRoom('gone404'), isEmpty);
    expect(storage.keysOfRoom('mine403'), isEmpty);
    expect(storage.keysOfRoom('vanished403'), isEmpty);
    expect(storage.keysOfRoom('unknown403'), isNotEmpty);
    expect(storage.data['secret/other404/owner'], 'someone-else');
    expect(storage.keysOfRoom('offline'), isNotEmpty);
    expect(storage.entry('a1', roomId: 'alive')?['t'], '다른 팀 소속이라 목록에 없는 방의 평문');
    // 히스토리를 받을 수 있으니 이 계정이 멤버인 방이다.
    expect(storage.data['secret/alive/owner'], 'me');
  });

  test('예전 형식 평문 — 히스토리를 처음부터 훑어(같은 밀리초의 쪽 경계 포함) 옮기고, 어느 방에도 없는 것은 다른 계정의 방일 수 있는 방이 남지 않았을 때만 지운다', () async {
    // 450개 — 최근 200개 쪽의 가장 오래된 메시지(p250)와 같은 밀리초에 p249·p251이 있다.
    int at(int i) => (i >= 249 && i <= 251) ? 2500 : i * 10;
    String id(int i) => 'p${i.toString().padLeft(3, '0')}';
    final all = [
      for (var i = 0; i < 450; i++)
        _message(
          id(i),
          at(i),
          comments: i == 100 ? [_comment('cm1', id(100), 1005)] : const [],
        ),
    ];
    storage
      ..seedKeys('r1')
      ..data['secretmsg/p249'] = '쪽 경계의 옛 메시지'
      ..data['secretmsg/p010'] = '맨 처음 쪽의 옛 메시지'
      ..data['secretmsg/p400'] = '최근 옛 메시지'
      ..data['secretmsg/cm1'] = '옛 댓글'
      ..data['secretmsg/gone1'] = '서버가 이미 지운 메시지'
      ..seedKeys('elsewhere'); // 누구 방인지 모르는 방 — 지금은 403.
    var elsewhere = _json(_notMember, 403);
    final server = _Server()
      ..on('GET', '/api/rooms/r1/messages', _history(all))
      ..on('GET', '/api/rooms/elsewhere/messages', (_) => elsewhere);
    final session = _session(server, [_secretRoom()], store);

    await session.syncSecretTextCaches();
    expect(storage.entry('p249'), {'t': '쪽 경계의 옛 메시지', 'c': 2500});
    expect(storage.entry('p010'), {'t': '맨 처음 쪽의 옛 메시지', 'c': 100});
    expect(storage.entry('p400'), {'t': '최근 옛 메시지', 'c': 4000});
    expect(storage.entry('cm1'), {'t': '옛 댓글', 'c': 1005, 'p': 'p100'});
    expect(
      storage.data.keys.where((k) => k.startsWith('secretmsg/')),
      ['secretmsg/gone1'],
      reason: '다른 계정의 방일 수 있는 방(elsewhere)이 남아 있어 지우지 않는다',
    );
    expect(storage.data['secretcache-legacy/me'], '1');

    // 다시 켜도 전체 히스토리를 다시 훑지 않는다(최근 쪽만).
    server.requests.clear();
    await session.syncSecretTextCaches();
    expect(
      server.requests
          .where((u) => u.path == '/api/rooms/r1/messages')
          .map((u) => u.queryParameters['limit']),
      ['50'],
    );
    expect(storage.data.containsKey('secretmsg/gone1'), isTrue);

    // 그 방이 없어진 게 확인되면 남은 예전 형식 평문(이미 지워진 메시지)도 지운다.
    elsewhere = _json(_roomNotFound, 404);
    await session.syncSecretTextCaches();
    expect(storage.keysOfRoom('elsewhere'), isEmpty);
    expect(
      storage.data.keys.where(
        (k) => k.startsWith('secretmsg/') || k.startsWith('secretcache-legacy/'),
      ),
      isEmpty,
    );
    expect(storage.entry('p249')?['t'], '쪽 경계의 옛 메시지');
  });

  test('타이머가 켜진 방 — 서버가 정한 시각은 이 기기 시계가 아니라 받은 서버 시각으로 재고, 소켓이 붙어 있을 때 읽은 메시지만 이 기기 기준으로 어림한다', () async {
    await store.saveDecryptedText(
      SecretTextRef(roomId: 'r1', id: 'm1', createdAt: _at(1000)),
      '방금 읽은 메시지',
    );
    await store.saveDecryptedText(
      SecretTextRef(roomId: 'r1', id: 'm2', createdAt: _at(2000)),
      '이미 만료된 메시지',
    );
    final now = DateTime.now();
    // 서버는 m2의 삭제 시각을 정해 두었는데(상대가 2분 30초 전에 읽음, 30초 타이머) 아직 훑지 않았다.
    final m2ExpiresAt = now
        .subtract(const Duration(minutes: 2))
        .millisecondsSinceEpoch;
    var round = 1;
    final server = _Server()
      ..on(
        'GET',
        '/api/rooms/r1/messages',
        (_) => _json([
          _message('m1', 1000),
          _message(
            'm2',
            2000,
            senderId: 'me',
            readAt: m2ExpiresAt - 30000,
            expiresAt: m2ExpiresAt,
          ),
          // 다시 받을 때는 방금 쓰인 메시지가 있다 — 서버의 지금을 알려 준다.
          if (round > 1)
            _message('m3', DateTime.now().millisecondsSinceEpoch),
        ]),
      );
    final room = _secretRoom(selfDestructSeconds: 30);
    final session = _session(server, [room], store, connected: true);
    final controller = session.controllerFor(room);
    await _until(() => !controller.loading);
    // 방을 열어(markReadNow) m1 읽음을 보냈다 — 서버 확정 알림 전에 이 기기 기준 30초 뒤가 적힌다.
    await _until(() => storage.entry('m1')?['e'] != null);
    final m1Expires = storage.entry('m1')!['e'] as int;
    expect(
      m1Expires,
      inInclusiveRange(
        now.add(const Duration(seconds: 29)).millisecondsSinceEpoch,
        DateTime.now().add(const Duration(seconds: 31)).millisecondsSinceEpoch,
      ),
    );
    expect(storage.entry('m1')!.containsKey('f'), isFalse);
    expect(storage.entry('m2')!['e'], m2ExpiresAt);
    expect(storage.entry('m2')!['f'], isTrue);

    // 받은 서버 시각 중 가장 늦은 것은 m2의 읽음 시각이다 — 이 기기 시계로는 m2의 시각(+유예)이 지났어도, 서버
    // 시각으로 확인되기 전에는 지우지 않는다(이 기기 시계가 빠를 수 있다).
    session.setActiveRoom('r1');
    await store.purgeExpiredTexts();
    expect(storage.entry('m2'), isNotNull);
    expect(_find(controller, 'm2')?.text, '이미 만료된 메시지');

    // 서버의 지금을 알게 되면 지우고, 열린 화면에서도 서버처럼 그 메시지를 뺀다.
    round = 2;
    await controller.refresh();
    await store.purgeExpiredTexts();
    expect(storage.entry('m2'), isNull);
    await _until(() => _find(controller, 'm2') == null);
    expect(_find(controller, 'm1')?.text, '방금 읽은 메시지');
    expect(storage.entry('m1'), isNotNull);
  });

  test('소켓이 끊겨 있으면 읽음 신호가 늦게 닿으므로 이 기기 기준 삭제 예정 시각을 어림하지 않는다', () async {
    await store.saveDecryptedText(
      SecretTextRef(roomId: 'r1', id: 'm1', createdAt: _at(1000)),
      '읽은 메시지',
    );
    final server = _Server()
      ..on('GET', '/api/rooms/r1/messages', (_) => _json([_message('m1', 1000)]));
    final room = _secretRoom(selfDestructSeconds: 30);
    final session = _session(server, [room], store);
    final controller = session.controllerFor(room);
    await _until(() => !controller.loading);
    controller.markReadNow();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(storage.entry('m1')!.containsKey('e'), isFalse);
  });

  test('서버가 나를 뺀 비밀 대화(room:removed)는 이 기기에 남은 키와 평문도 지운다', () async {
    storage
      ..seedKeys('r1', owner: 'me')
      ..seedText('r1', 'm1', 1000);
    final session = _session(_Server(), [_secretRoom()], store);
    session.handleRoomRemoved(
      const RoomRemovedEvent(roomId: 'r1', reason: 'team'),
    );
    await _until(() => storage.keysOfRoom('r1').isEmpty);
    expect(session.rooms, isEmpty);
  });
}
