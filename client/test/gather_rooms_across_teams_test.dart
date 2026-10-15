import 'dart:convert';

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/desktop_home_screen.dart';
import 'package:client/screens/room_list_screen.dart';
import 'package:client/screens/settings_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/team_name_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 환경설정 > 메신저 설정의 "여러 팀 방 모아보기" — 켠 종류(토픽·그룹채팅·1:1 채팅)는 내가 속한 다른 팀의 방도 지금 팀의
/// 방 목록(PC 사이드바·모바일 방 목록)에 함께 보이고, 다른 팀의 방에는 팀 이름이 붙으며, 누르면 그 팀으로 바뀌며 열린다.
class _Quiet extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

const _serverUrl = 'https://192.168.0.10:3000';

Map<String, dynamic> _user(String id, String name) => {
  'id': id,
  'username': 'user_$id',
  'name': name,
  'role': 'member',
};

Map<String, dynamic> _room(
  String id,
  String teamId,
  String type, {
  String? name,
  List<Map<String, dynamic>>? members,
  bool hidden = false,
}) => {
  'id': id,
  'teamId': teamId,
  'type': type,
  'name': name,
  'members': members ?? [_user('me', '김하나'), _user('u2', '이도현')],
  'createdAt': 1000,
  'hidden': hidden,
};

final _dev = Team(id: 't1', name: '개발팀', createdAt: DateTime(2026));
final _mkt = Team(id: 't2', name: '마케팅팀', createdAt: DateTime(2026));

Session _session() {
  final client = MockClient(
    (request) async => http.Response.bytes(
      utf8.encode(jsonEncode(<Object>[])),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    ),
  );
  final session = Session(notifications: _Quiet(), settings: AppSettings());
  session.serverUrl = _serverUrl;
  session.api = ApiClient(baseUrl: _serverUrl, token: 't', httpClient: client);
  session.userId = 'me';
  session.name = '김하나';
  session.teams.addAll([_dev, _mkt]);
  session.currentTeam = _dev;
  session.rooms.addAll([
    Room.fromJson(_room('dev-topic', 't1', 'topic', name: '개발 공지')),
    Room.fromJson(_room('mkt-topic', 't2', 'topic', name: '행사 준비')),
    Room.fromJson(
      _room('mkt-hidden', 't2', 'topic', name: '숨긴 토픽', hidden: true),
    ),
    Room.fromJson(_room('mkt-group', 't2', 'group', name: '마케팅 수다방')),
    Room.fromJson(
      _room(
        'mkt-dm',
        't2',
        'dm',
        members: [_user('me', '김하나'), _user('u3', '박서연')],
      ),
    ),
    // 내가 속하지 않은 팀의 방(목록에 섞여 들어와도 보이면 안 된다).
    Room.fromJson(_room('etc-topic', 't9', 'topic', name: '남의 팀 토픽')),
  ]);
  return session;
}

Future<void> _gather(
  Session s, {
  bool topics = false,
  bool groups = false,
  bool dms = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  // 저장소 없이 메모리 값만 바꾼다(_prefs는 init()에서 채워진다 — 여기선 화면 판단만 본다).
  s.settings
    ..gatherTopicsAcrossTeams = topics
    ..gatherGroupChatsAcrossTeams = groups
    ..gatherDmsAcrossTeams = dms;
}

/// AppSettings.init()이 창 속성을 적용하려고 부르는 채널 — 테스트엔 창이 없으니 그냥 받아 준다.
void _mockWindowManager(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (_) async => null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'TangoTalk',
      packageName: 'client',
      version: '1.1.3',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  group('Session.showsInRoomList', () {
    test('기본(모두 꺼짐)은 지금 팀의 방만 — 숨긴 방은 빼고', () {
      final s = _session();
      final shown = s.rooms.where(s.showsInRoomList).map((r) => r.id);
      expect(shown, ['dev-topic']);
      expect(s.otherTeamNameOf(s.rooms.first), isNull);
    });

    test('켠 종류만 내가 속한 다른 팀의 방도 보인다 — 숨긴 방·내가 없는 팀의 방은 여전히 안 보인다', () async {
      final s = _session();
      await _gather(s, topics: true, dms: true);
      final shown = s.rooms.where(s.showsInRoomList).map((r) => r.id).toSet();
      expect(shown, {'dev-topic', 'mkt-topic', 'mkt-dm'});
      final mktTopic = s.rooms.firstWhere((r) => r.id == 'mkt-topic');
      expect(s.otherTeamNameOf(mktTopic), '마케팅팀');
      await _gather(s, groups: true);
      expect(s.rooms.where(s.showsInRoomList).map((r) => r.id).toSet(), {
        'dev-topic',
        'mkt-group',
      });
    });

    test('다른 팀의 방을 열려고 하면 그 팀으로 바꾼다 — 지금 팀의 방이면 그대로', () {
      final s = _session();
      final devTopic = s.rooms.firstWhere((r) => r.id == 'dev-topic');
      final mktTopic = s.rooms.firstWhere((r) => r.id == 'mkt-topic');
      expect(s.enterTeamOf(devTopic), isFalse);
      expect(s.currentTeam?.id, 't1');
      expect(s.enterTeamOf(mktTopic), isTrue);
      expect(s.currentTeam?.id, 't2');
      // 이제는 개발팀 방이 "다른 팀" 방이다.
      expect(s.otherTeamNameOf(devTopic), '개발팀');
    });
  });

  testWidgets('환경설정 > 메신저 설정: 세 가지를 따로(여러 개) 골라 저장하면 저장되고, 다시 켜도 그대로다', (
    tester,
  ) async {
    _mockWindowManager(tester);
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = _session();
    await s.settings.init();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsScreen(session: s)),
      ),
    );
    await tester.pump();
    expect(find.text('여러 팀 방 모아보기'), findsOneWidget);
    for (final label in [
      '내가 속한 팀의 토픽방 모아보기',
      '내가 속한 팀의 그룹채팅방 모아보기',
      '내가 속한 팀의 채팅방 모아보기',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('내가 속한 팀의 토픽방 모아보기'));
    await tester.tap(find.text('내가 속한 팀의 채팅방 모아보기'));
    await tester.pump();
    // 저장하기 전에는 바뀌지 않는다.
    expect(s.settings.gatherTopicsAcrossTeams, isFalse);
    await tester.ensureVisible(find.text('저장하기'));
    await tester.tap(find.text('저장하기'));
    await tester.pumpAndSettle();
    expect(s.settings.gatherTopicsAcrossTeams, isTrue);
    expect(s.settings.gatherGroupChatsAcrossTeams, isFalse);
    expect(s.settings.gatherDmsAcrossTeams, isTrue);

    final reopened = AppSettings();
    await reopened.init();
    expect(reopened.gatherTopicsAcrossTeams, isTrue);
    expect(reopened.gatherGroupChatsAcrossTeams, isFalse);
    expect(reopened.gatherDmsAcrossTeams, isTrue);

    // 저장해도 창은 닫히지 않고 "저장했습니다." 알약만 뜬다.
    expect(find.text('저장했습니다.'), findsOneWidget);
    expect(find.text('저장하기'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3)); // 알약이 사라질 때까지
  });

  testWidgets('PC 사이드바: 켠 종류는 다른 팀 방도 팀 이름과 함께 보이고, 누르면 그 팀으로 바뀌며 열린다', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    _mockWindowManager(tester);
    final s = _session();
    await s.settings.init();
    await tester.pumpWidget(MaterialApp(home: DesktopHomeScreen(session: s)));
    await tester.pumpAndSettle();
    expect(find.text('행사 준비'), findsNothing);
    expect(find.byType(TeamNameBadge), findsNothing);

    // 설정을 바꾸면(저장하면) 목록이 바로 다시 그려진다.
    await s.settings.setGatherAcrossTeams(
      topics: true,
      groupChats: false,
      dms: false,
    );
    await tester.pumpAndSettle();
    expect(find.text('행사 준비'), findsOneWidget);
    expect(find.text('마케팅 수다방'), findsNothing, reason: '그룹채팅은 켜지 않았다');
    expect(find.text('숨긴 토픽'), findsNothing);
    expect(find.text('남의 팀 토픽'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(TeamNameBadge),
        matching: find.text('마케팅팀'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('행사 준비'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(s.currentTeam?.id, 't2');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('모바일·웹 방 목록: 켠 종류는 다른 팀 방도 팀 이름과 함께 보이고, 누르면 그 팀으로 바뀌며 열린다', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = _session();
    await _gather(s, dms: true);
    await tester.pumpWidget(MaterialApp(home: RoomListScreen(session: s)));
    await tester.pumpAndSettle();
    // 토픽은 켜지 않았다.
    expect(find.text('행사 준비'), findsNothing);
    await tester.tap(find.text('채팅'));
    await tester.pumpAndSettle();
    expect(find.text('박서연'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(TeamNameBadge),
        matching: find.text('마케팅팀'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('박서연'));
    await tester.pump();
    expect(s.currentTeam?.id, 't2');
    await tester.pumpWidget(const SizedBox());
  });
}
