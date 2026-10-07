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

/// "상대 기기 키 다시 받기"(S5) — 고정해 둔 키로 확인이 안 돼 멈춘 방의 안내에 그 버튼이 보이고, 확인 창을 거쳐야만
/// 그 기기의 고정을 지우며(그 키로 맺은 다른 대화도 멈춤), 지운 뒤에는 "새로 시작해 보안 코드를 비교"하라는 안내로
/// 바뀌는지, 보안 코드 창의 "코드가 다릅니다"도 같은 길로 그 대화를 멈추는지 본다.

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

/// 밥의 기기 — 앨리스와의 비밀 대화방들.
///
/// SecretKeyStore의 저장소 줄은 앱 전체에 하나(static)라서 이 파일에는 testWidgets를 하나만 둔다
/// (secret_pinning_banner_test.dart 참고).
class _Env {
  _Env(this.session, this.store, this.identity);

  final Session session;
  final SecretKeyStore store;
  final DeviceIdentity identity;

  Room room(String id) => session.roomById(id)!;

  static Future<_Env> create(List<String> roomIds) async {
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
    return _Env(session, store, identity);
  }

  Future<SecretDevicePin> pin(String deviceId) async {
    final pin = SecretDevicePin.firstSeen(
      userId: 'u-alice',
      signingPublicKey: await publicKeyBase64(await Ed25519().newKeyPair()),
      at: DateTime(2026),
    );
    await store.pinDeviceIfAbsent(deviceId, pin);
    return pin;
  }

  Future<void> bind(String roomId, String deviceId) => store.saveRoomBinding(
    roomId,
    SecretRoomBinding(
      peerUserId: 'u-alice',
      peerDeviceId: deviceId,
      myDeviceId: identity.deviceId,
    ),
  );
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

final _resetButton = find.byKey(const ValueKey('secret-security-reset-key'));
final _confirmDialog = find.byKey(const ValueKey('secret-key-reset-confirm'));
final _confirmButton = find.byKey(
  const ValueKey('secret-key-reset-confirm-button'),
);

void main() {
  testWidgets(
    '고정한 키로 확인이 안 돼 멈춘 방은 "상대 기기 키 다시 받기"로 확인 창을 거쳐 그 키를 지우고(그 키로 맺은 대화도 멈춤), 보안 코드 창의 "코드가 다릅니다"도 같은 길로 대화를 멈춘다',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final env = await _Env.create(['r1', 'r2', 'r3']);
      // r1: 앨리스 기기(d-alice)와 맺은 대화. r2: 같은 기기로 온 새 초대가 고정한 키로 서명이 맞지 않아 멈춘 방(묶이지
      // 않음). r3: 앨리스의 다른 기기(d-alice-2)와 맺은 대화.
      final alicePin = await env.pin('d-alice');
      await env.pin('d-alice-2');
      await env.bind('r1', 'd-alice');
      await env.bind('r3', 'd-alice-2');
      await env.store.saveRoomSecurity(
        'r2',
        SecretRoomSecurity.none.blockedWith(
          SecretBlockReason.badSignature,
          DateTime(2026),
          deviceId: 'd-alice',
          pinSeenAt: alicePin.firstSeenAt,
        ),
      );

      // 멈춘 방 — 원인과 함께 "상대 기기 키 다시 받기"가 보인다. 확인 창에서 취소하면 아무것도 지우지 않는다.
      await _pumpRoom(tester, env, env.room('r2'));
      expect(
        find.byKey(const ValueKey('secret-security-blocked')),
        findsOneWidget,
      );
      expect(_resetButton, findsOneWidget);
      expect(find.textContaining('앱을 다시 설치'), findsOneWidget);
      await tester.tap(_resetButton);
      await tester.pumpAndSettle();
      expect(_confirmDialog, findsOneWidget);
      expect(find.textContaining('직접(만나서·전화로)'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(await env.store.readDevicePin('d-alice'), isNotNull);

      // 진행하면 그 기기의 고정을 지우고, 그 키로 맺은 r1도 멈춘다. 안내는 "새로 시작해 비교"로 바뀐다.
      await tester.tap(_resetButton);
      await tester.pumpAndSettle();
      await tester.tap(_confirmButton);
      await tester.pumpAndSettle();
      expect(await env.store.readDevicePin('d-alice'), isNull);
      expect(_resetButton, findsNothing);
      expect(
        find.byKey(const ValueKey('secret-security-key-reset-done')),
        findsOneWidget,
      );
      expect(find.textContaining('상대 기기 키를 지웠습니다'), findsOneWidget);
      expect(
        (await env.store.readRoomSecurity('r1')).blockedReason,
        SecretBlockReason.keyReset,
      );
      // 다른 기기(d-alice-2)의 고정과 그 대화는 그대로다.
      expect(await env.store.readDevicePin('d-alice-2'), isNotNull);
      expect((await env.store.readRoomSecurity('r3')).blocked, isFalse);

      await _pumpRoom(tester, env, env.room('r1'));
      expect(
        find.textContaining(SecretBlockReason.keyReset.description),
        findsOneWidget,
      );
      expect(_resetButton, findsNothing);

      // r3 — 보안 코드 창에서 "코드가 다릅니다"(취소하면 그대로, 진행하면 그 키를 지우고 대화를 멈춘다).
      await _pumpRoom(tester, env, env.room('r3'));
      expect(
        find.byKey(const ValueKey('secret-security-blocked')),
        findsNothing,
      );
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('room-menu-safety-number')));
      await tester.pumpAndSettle();
      final mismatch = find.byKey(
        const ValueKey('secret-safety-code-mismatch'),
      );
      expect(mismatch, findsOneWidget);
      expect(find.textContaining('"코드가 다릅니다"를 눌러 주세요'), findsOneWidget);
      await tester.tap(mismatch);
      await tester.pumpAndSettle();
      expect(find.text('보안 코드가 다릅니다'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(await env.store.readDevicePin('d-alice-2'), isNotNull);
      await tester.tap(mismatch);
      await tester.pumpAndSettle();
      await tester.tap(_confirmButton);
      await tester.pumpAndSettle();
      // 보안 코드 창은 닫히고, 방 안내가 멈춤을 알린다.
      expect(find.byKey(const ValueKey('secret-safety-number')), findsNothing);
      expect(await env.store.readDevicePin('d-alice-2'), isNull);
      expect(
        find.byKey(const ValueKey('secret-security-blocked')),
        findsOneWidget,
      );
      expect(
        find.textContaining(SecretBlockReason.keyReset.description),
        findsOneWidget,
      );
      await expectLater(
        env.session.secretSessionManager!.encryptForRoom('r3', '멈춘 대화'),
        throwsA(isA<SecretChatBlockedException>()),
      );
      expect(tester.takeException(), isNull);

      env.session.secretSessionManager = null;
      await tester.pumpWidget(const SizedBox());
      // 알림(토스트)이 사라질 때까지.
      await tester.pump(const Duration(seconds: 3));
    },
  );
}
