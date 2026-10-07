import 'dart:convert';

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/device_identity.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/secret_key_store.dart';
import 'package:client/services/secret_peer_store.dart';
import 'package:client/services/secret_session_manager.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/room_options_menu.dart';
import 'package:client/widgets/secret_security_banner.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 비밀 대화방 맨 위 보안 안내(S5) — 보안 확인에 실패해 멈춘 방은 빨간 안내(원인·"비밀 대화 끝내기")와 함께 보내기가
/// 막히고, 상대 기기가 바뀐 방은 노란 안내, 예전 앱 상대는 회색 안내가 하나씩 보이며 닫으면 사라지는지 본다.

/// 신뢰 상태대로 보이고, "확인함"으로 표시하면 창과 메뉴에 그 표시가 붙는지 본다.

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
}

Map<String, dynamic> _user(String id, String name) => {
  'id': id,
  'username': id,
  'name': name,
  'role': 'member',
};

/// 밥의 기기 — 앨리스와의 비밀 대화방들이 있고, [bound]의 방은 앨리스 기기에 묶여 있다.
///
/// 저장소·암호 계산은 모두 테스트의 가짜 시간 안에서 마이크로태스크로 끝난다(메모리 저장소) — tester.runAsync는 쓰지
/// 않는다. 또 SecretKeyStore의 저장소 줄은 앱 전체에 하나(static)라서, 이 파일에는 testWidgets를 하나만 둔다 —
/// 테스트마다 가짜 시간 영역이 새로 생기는데, 앞 테스트 영역에서 만든 줄 끝에 이어 붙이면 그 콜백이 끝난 영역에서
/// 돌아 영영 실행되지 않는다(실제 앱은 영역이 하나라 상관없다).
class _Env {
  _Env(this.session, this.store);

  final Session session;
  final SecretKeyStore store;

  Room room(String id) => session.roomById(id)!;

  static Future<_Env> create(
    List<String> roomIds, {
    Set<String> bound = const {},
  }) async {
    final identity = DeviceIdentity(storage: _MemoryStorage());
    await identity.ensureLoaded();
    final store = SecretKeyStore(storage: _MemoryStorage());
    final session = Session(
      notifications: _QuietNotifications(),
      settings: AppSettings(),
    );
    session.serverUrl = 'https://test.local';
    session.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(jsonEncode({'error': '없음'})),
          404,
          headers: const {'content-type': 'application/json'},
        ),
      ),
    );
    session.userId = 'u-bob';
    session.name = '밥';
    session.accountRole = AccountRole.member;
    final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
    session.teams.add(team);
    session.currentTeam = team;
    for (final id in roomIds) {
      session.rooms.add(
        Room.fromJson({
          'id': id,
          'teamId': 't1',
          'type': 'dm',
          'name': null,
          'members': [_user('u-alice', '앨리스'), _user('u-bob', '밥')],
          'createdAt': 1,
          'isSecret': true,
          'secretStatus': 'active',
        }),
      );
    }
    session.secretSessionManager = SecretSessionManager(
      session.api!,
      session.chatSocket,
      identity,
      keyStore: store,
      userId: 'u-bob',
      roomLookup: session.roomById,
    );
    final peer = await Ed25519().newKeyPair();
    await store.saveDevicePin(
      'd-alice',
      SecretDevicePin(
        userId: 'u-alice',
        signingPublicKey: await publicKeyBase64(peer),
        firstSeenAt: DateTime(2026),
      ),
    );
    for (final id in bound) {
      await store.saveRoomBinding(
        id,
        SecretRoomBinding(
          peerUserId: 'u-alice',
          peerDeviceId: 'd-alice',
          myDeviceId: identity.deviceId,
        ),
      );
    }
    return _Env(session, store);
  }
}

/// 방 [room]의 대화 화면처럼 — 앱바에 더보기 메뉴, 본문 맨 위에 비밀 대화 안내.
Future<void> _pumpRoom(WidgetTester tester, _Env env, Room room) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('앨리스'),
          actions: [RoomOptionsMenu(session: env.session, room: room)],
        ),
        body: Column(
          children: [
            SecretSecurityBanner(session: env.session, room: room),
            const Expanded(child: Center(child: Text('채팅 본문'))),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _finish(WidgetTester tester, _Env env) async {
  env.session.secretSessionManager = null;
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets(
    '멈춘 방은 빨간 안내와 함께 보내기가 막히고, 상대 기기가 바뀐 방·예전 앱 상대는 안내가 하나씩 보이며 닫으면 사라진다',
    (tester) async {
      final env = await _Env.create(['r1', 'r2'], bound: {'r1', 'r2'});
      await env.store.saveRoomSecurity(
        'r1',
        SecretRoomSecurity.none.blockedWith(
          SecretBlockReason.badSignature,
          DateTime(2026),
        ),
      );
      await env.store.saveRoomSecurity(
        'r2',
        const SecretRoomSecurity(peerDeviceChanged: true, legacyPeer: true),
      );

      // 멈춘 방.
      await _pumpRoom(tester, env, env.room('r1'));
      expect(
        find.byKey(const ValueKey('secret-security-blocked')),
        findsOneWidget,
      );
      expect(
        find.textContaining('상대 기기의 보안 확인에 실패해 이 비밀 대화를 멈췄습니다'),
        findsOneWidget,
      );
      expect(find.textContaining('가로채려'), findsOneWidget);
      expect(
        find.textContaining(SecretBlockReason.badSignature.description),
        findsOneWidget,
      );
      expect(find.text('비밀 대화 끝내기'), findsOneWidget);
      Object? sendError;
      env.session.secretSessionManager!
          .encryptForRoom('r1', '보내면 안 된다')
          .then<void>((_) {}, onError: (Object e) => sendError = e);
      await tester.pumpAndSettle();
      expect(sendError, isA<SecretChatBlockedException>());

      // 상대 기기가 바뀌었고 상대가 예전 앱인 방 — 한 번에 하나씩, 기기 바뀜 안내가 먼저다.
      await _pumpRoom(tester, env, env.room('r2'));
      expect(
        find.byKey(const ValueKey('secret-security-blocked')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('secret-security-device-changed')),
        findsOneWidget,
      );
      expect(find.text('보안 코드 확인'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('secret-security-legacy')),
        findsNothing,
      );

      await tester.tap(find.byTooltip('닫기'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('secret-security-device-changed')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('secret-security-legacy')),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('닫기'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('secret-security-legacy')),
        findsNothing,
      );
      final stored = await env.store.readRoomSecurity('r2');
      expect(stored.legacyNoticeDismissed, isTrue);
      expect(stored.peerDeviceChanged, isFalse);
      expect(tester.takeException(), isNull);
      await _finish(tester, env);
    },
  );
}
