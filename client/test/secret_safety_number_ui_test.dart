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

/// 비밀 대화 보안 코드 화면(S5) — 더보기의 "보안 코드 확인" 창이 60자리를 4묶음씩 3줄로 보여 주고, "확인함"으로
/// 표시하면 창과 메뉴에 그 표시가 붙는지, 상대 기기가 아직 묶이지 않은 방은 코드 대신 안내를 보이는지 본다.

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

final _digitGroup = find.byWidgetPredicate(
  (w) => w is Text && RegExp(r'^\d{5}$').hasMatch(w.data ?? ''),
);

void main() {
  testWidgets(
    '더보기 > 보안 코드 확인 — 60자리를 4묶음씩 3줄로 보여 주고, 확인함으로 표시하면 창과 메뉴에 "확인함"이 붙는다. 아직 묶이지 않은 방은 안내만',
    (tester) async {
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final env = await _Env.create(['r1', 'r2'], bound: {'r1'});

      // 상대 기기에 묶인 방 — 코드 12묶음과 "확인함으로 표시".
      await _pumpRoom(tester, env, env.room('r1'));
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('확인함'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('room-menu-safety-number')));
      await tester.pumpAndSettle();
      expect(find.text('앨리스 님과의 보안 코드'), findsOneWidget);
      expect(_digitGroup, findsNWidgets(12));
      final rows = tester
          .widgetList<Row>(
            find.descendant(
              of: find.byKey(const ValueKey('secret-safety-number')),
              matching: find.byType(Row),
            ),
          )
          .toList();
      expect(rows, hasLength(3));
      for (final row in rows) {
        expect(row.children, hasLength(4));
      }
      expect(find.textContaining('60자리'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('secret-safety-mark-verified')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('secret-safety-verified')),
        findsOneWidget,
      );
      expect(env.session.secretTrustOf('r1')!.verified, isTrue);

      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('확인함'), findsOneWidget);
      expect(find.byIcon(Icons.verified_user), findsOneWidget);
      // 메뉴를 닫는다.
      await tester.tapAt(const Offset(10, 600));
      await tester.pumpAndSettle();

      // 상대 기기가 아직 묶이지 않은 방(수락 전) — 코드 대신 안내.
      await _pumpRoom(tester, env, env.room('r2'));
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('확인함'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('room-menu-safety-number')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('secret-safety-unavailable')),
        findsOneWidget,
      );
      expect(_digitGroup, findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester, env);
    },
  );
}
