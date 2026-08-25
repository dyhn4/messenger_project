import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/app_user.dart';
import '../models/message.dart';
import '../models/room.dart';
import 'api_client.dart';
import 'app_settings.dart';
import 'chat_socket.dart';
import 'notification_service.dart';
import 'pinned_tls.dart';
import 'room_chat_controller.dart';

enum AuthStage { loadingConfig, needsServer, needsLogin, ready }

/// 앱 전체 상태: 서버 주소 → 로그인 → 방 목록 순으로 진행됩니다. 인증/방 목록/라우팅만
/// 책임지고, 방 하나의 메시지/전송은 RoomChatController에 맡깁니다.
/// 이전 KiwoomApi 포팅 때와 같은 패턴으로, ChangeNotifier + ListenableBuilder만 씁니다.
class Session extends ChangeNotifier {
  Session({required this.notifications, required this.settings});

  static const _kServerUrl = 'server_base_url';
  static const _kToken = 'auth_token';
  static const _kRefreshToken = 'auth_refresh_token';
  static const _kUserId = 'auth_user_id';
  static const _kUsername = 'auth_username';
  static const _kRememberedUsername = 'remembered_username';

  late SharedPreferences _prefs;

  AuthStage stage = AuthStage.loadingConfig;
  String? serverUrl;
  String? token; // accessToken (짧게 삼)
  String? refreshToken; // accessToken 만료 시 재발급받는 데 쓰는 긴 토큰
  String? userId;
  String? username;
  String? error;
  String? rememberedUsername;

  String? name;
  String? email;
  String avatarType = 'initial'; // 'initial' | 'character' | 'photo'
  String? avatarEmoji;
  String? avatarColor;
  String? avatarUrl;

  ApiClient? api;
  String? updateAvailableVersion; // 서버가 더 최신 버전을 갖고 있으면 그 버전 문자열(예: "1.0.1").
  final chatSocket = ChatSocket();
  final NotificationService notifications;
  final AppSettings settings;
  final List<Room> rooms = [];

  final _controllers = <String, RoomChatController>{};
  StreamSubscription? _messageSub;
  StreamSubscription? _roomSub;
  StreamSubscription? _readSub;
  StreamSubscription? _presenceSub;
  StreamSubscription? _reconnectSub;
  StreamSubscription? _authErrorSub;

  /// 지금 소켓으로 연결되어 있는(온라인) 사용자 id 집합. 멤버 목록의 초록 점 표시에 쓴다.
  final Set<String> onlineUserIds = {};
  Future<String?>? _refreshInFlight;

  String? _activeRoomId;
  String? get activeRoomId => _activeRoomId;
  void setActiveRoom(String? roomId) => _activeRoomId = roomId;

  bool appInForeground = true;

  /// 창이 백그라운드였다가 다시 포그라운드로 돌아왔을 때, 이미 열려있던 방(activeRoomId)이
  /// 있다면 그 사이 온 메시지를 읽음 처리하고 안읽음 뱃지를 지운다. 방을 처음 열 때는
  /// ChatPanel.initState가 같은 일을 하지만, 방을 계속 열어둔 채로 창만 비활성화→활성화된
  /// 경우엔 ChatPanel이 다시 마운트되지 않아서 이 훅이 따로 필요하다.
  void setAppInForeground(bool value) {
    final wasBackground = !appInForeground;
    appInForeground = value;
    if (value && wasBackground && _activeRoomId != null) {
      _controllers[_activeRoomId]?.markReadNow();
      clearUnreadCount(_activeRoomId!);
    }
  }

  Room? _pendingOpenRoom;
  /// 알림을 눌러서 특정 방을 열어달라는 요청. 데스크톱 분할화면은 이걸 보고
  /// 전체화면 전환 없이 그 자리에서 우측 패널만 바꾼다.
  Room? consumePendingOpenRoom() {
    final room = _pendingOpenRoom;
    _pendingOpenRoom = null;
    return room;
  }

  void requestOpenRoom(Room room) {
    _pendingOpenRoom = room;
    notifyListeners();
  }

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    serverUrl = _prefs.getString(_kServerUrl);
    // 서버가 HTTP에서 HTTPS로 바뀌면서, 예전에 http://로 저장해둔 주소는 더 이상 연결되지
    // 않는다. 같은 호스트:포트를 https://로만 바꿔서 자동으로 맞춰준다.
    if (serverUrl != null && serverUrl!.startsWith('http://')) {
      serverUrl = 'https://${serverUrl!.substring('http://'.length)}';
      await _prefs.setString(_kServerUrl, serverUrl!);
    }
    token = _prefs.getString(_kToken);
    refreshToken = _prefs.getString(_kRefreshToken);
    userId = _prefs.getString(_kUserId);
    username = _prefs.getString(_kUsername);
    rememberedUsername = _prefs.getString(_kRememberedUsername);

    if (serverUrl == null) {
      stage = AuthStage.needsServer;
    } else {
      api = ApiClient(
        baseUrl: serverUrl!,
        token: token,
        onUnauthorized: _tryRefreshAndApply,
        httpClient: await PinnedTls.httpClient(),
      );
      unawaited(_checkForUpdate());
      if (token == null) {
        stage = AuthStage.needsLogin;
      } else {
        stage = AuthStage.ready;
        await _enterApp();
      }
    }
    notifyListeners();
  }

  Future<bool> setServerUrl(String url) async {
    final normalized = url.trim().replaceAll(RegExp(r'/+$'), '');
    final pinnedClient = await PinnedTls.httpClient();
    final testClient = ApiClient(baseUrl: normalized, httpClient: pinnedClient);
    final ok = await testClient.checkHealth();
    if (!ok) {
      error = '서버에 연결할 수 없습니다. 주소를 확인하세요 (예: https://192.168.0.62:3000)';
      notifyListeners();
      return false;
    }
    serverUrl = normalized;
    await _prefs.setString(_kServerUrl, normalized);
    api = ApiClient(baseUrl: normalized, onUnauthorized: _tryRefreshAndApply, httpClient: pinnedClient);
    unawaited(_checkForUpdate());
    error = null;
    stage = AuthStage.needsLogin;
    notifyListeners();
    return true;
  }

  /// 서버에 지금 이 앱보다 최신 버전이 배포돼 있으면 [updateAvailableVersion]을 채운다.
  /// 실패해도(오프라인, 아직 배포된 빌드 없음 등) 조용히 무시한다 — 부가 기능이라 앱 사용에
  /// 지장을 주면 안 된다.
  Future<void> _checkForUpdate() async {
    try {
      final latest = await api?.fetchLatestVersion();
      if (latest == null) return;
      final info = await PackageInfo.fromPlatform();
      if (_isNewerVersion(latest, info.version)) {
        updateAvailableVersion = latest;
        notifyListeners();
      }
    } catch (_) {
      // 버전 확인 실패는 무시 — 다음 실행/재연결 때 다시 시도됨.
    }
  }

  /// "1.2.10"처럼 점으로 구분된 버전 문자열을 부분별로 숫자 비교한다. 형식이 이상하면
  /// (파싱 실패) 안전하게 "업데이트 없음"으로 취급한다.
  bool _isNewerVersion(String remote, String local) {
    final r = remote.split('.').map(int.tryParse).toList();
    final l = local.split('.').map(int.tryParse).toList();
    if (r.any((n) => n == null) || l.any((n) => n == null)) return false;
    for (var i = 0; i < r.length; i++) {
      final rv = r[i]!;
      final lv = i < l.length ? l[i]! : 0;
      if (rv != lv) return rv > lv;
    }
    return false;
  }

  /// 업데이트 배너의 "다운로드"를 눌렀을 때 — 플랫폼에 맞는 다운로드 URL을 외부(브라우저)로 연다.
  Future<void> openUpdateDownload() async {
    final base = serverUrl;
    if (base == null) return;
    final platformPath = Platform.isAndroid ? 'android' : 'windows';
    await launchUrl(Uri.parse('$base/downloads/$platformPath'), mode: LaunchMode.externalApplication);
  }

  Future<bool> login(String u, String p, {required bool keepSignedIn}) =>
      _auth(() => api!.login(u, p), keepSignedIn: keepSignedIn);

  Future<bool> register(String u, String p, String email, String name, {required bool keepSignedIn}) =>
      _auth(() => api!.register(u, p, email, name), keepSignedIn: keepSignedIn);

  Future<bool> _auth(Future<AuthResult> Function() call, {required bool keepSignedIn}) async {
    try {
      final result = await call();
      token = result.accessToken;
      refreshToken = result.refreshToken;
      userId = result.userId;
      username = result.username;
      if (keepSignedIn) {
        await _prefs.setString(_kToken, token!);
        await _prefs.setString(_kRefreshToken, refreshToken!);
        await _prefs.setString(_kUserId, userId!);
        await _prefs.setString(_kUsername, username!);
      } else {
        // 이전 세션에서 "로그인 상태 유지"로 저장해둔 게 있을 수 있으니 같이 지운다.
        await _prefs.remove(_kToken);
        await _prefs.remove(_kRefreshToken);
        await _prefs.remove(_kUserId);
        await _prefs.remove(_kUsername);
      }
      api = ApiClient(
        baseUrl: serverUrl!,
        token: token,
        onUnauthorized: _tryRefreshAndApply,
        httpClient: await PinnedTls.httpClient(),
      );
      error = null;
      stage = AuthStage.ready;
      notifyListeners();
      await _enterApp();
      return true;
    } catch (e) {
      error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<void> setRememberedUsername(String? username) async {
    rememberedUsername = username;
    if (username == null) {
      await _prefs.remove(_kRememberedUsername);
    } else {
      await _prefs.setString(_kRememberedUsername, username);
    }
  }

  Future<void> _enterApp() async {
    try {
      final myRooms = await api!.fetchRooms();
      rooms
        ..clear()
        ..addAll(myRooms);
    } catch (e) {
      error = e.toString();
    }

    try {
      final me = await api!.fetchMe();
      name = me.name;
      email = me.email;
      avatarType = me.avatarType;
      avatarEmoji = me.avatarEmoji;
      avatarColor = me.avatarColor;
      avatarUrl = me.avatarUrl;
    } catch (_) {
      // 프로필/아바타는 부가 정보라 실패해도 조용히 무시한다.
    }

    // 위 fetchRooms/fetchMe 도중 401 → 리프레시 시도 → refreshToken마저 무효라 강제
    // 로그아웃(_forceLogout)됐을 수 있다(예: 이 토큰이 새 서버 버전 이전에 발급된 옛날
    // 형식이라 애초에 무효인 경우). 그러면 token이 null로 바뀌어 있으니 여기서 멈춘다.
    if (token == null) return;

    await chatSocket.connect(baseUrl: serverUrl!, token: token!);
    _messageSub?.cancel();
    _messageSub = chatSocket.messages.listen((m) {
      _controllers[m.roomId]?.feed(m);
      _handleIncomingMessage(m);
    });
    _roomSub?.cancel();
    _roomSub = chatSocket.roomEvents.listen(_upsertRoom);
    _readSub?.cancel();
    _readSub = chatSocket.readEvents.listen((e) {
      final match = rooms.where((r) => r.id == e.roomId);
      if (match.isEmpty) return;
      match.first.lastRead[e.userId] = e.lastReadAt;
      notifyListeners();
    });
    _presenceSub?.cancel();
    _presenceSub = chatSocket.presenceEvents.listen((e) {
      if (e.online) {
        onlineUserIds.add(e.userId);
      } else {
        onlineUserIds.remove(e.userId);
      }
      notifyListeners();
    });
    unawaited(_seedOnlineUsers());
    _reconnectSub?.cancel();
    _reconnectSub = chatSocket.reconnected.listen((_) => _resyncAfterReconnect());
    _authErrorSub?.cancel();
    _authErrorSub = chatSocket.authErrors.listen((_) async {
      // accessToken이 만료됐거나(오래 대기 상태였다가 복귀 등) 비밀번호 변경으로 폐기된
      // 상태로 소켓이 붙으려다 거부된 경우. 새 accessToken을 받아 다시 연결을 시도한다.
      final newToken = await _tryRefreshAccessToken();
      if (newToken != null) {
        await chatSocket.connect(baseUrl: serverUrl!, token: newToken);
      }
    });

    notifyListeners();
  }

  /// 소켓의 presence:update는 "바뀐 순간부터의" 변화만 알려주므로, 지금 이미 온라인인
  /// 사람들의 초기 스냅샷은 회원 목록 조회(각 사용자의 online 필드)로 따로 채워야 한다.
  Future<void> _seedOnlineUsers() async {
    try {
      final users = await api!.fetchUsers();
      onlineUserIds
        ..clear()
        ..addAll(users.where((u) => u.online).map((u) => u.id));
      notifyListeners();
    } catch (_) {
      // 부가 정보라 실패해도 조용히 무시 — 이후 presence:update로 점차 채워짐.
    }
  }

  /// 연결이 끊겼다가 재연결됐을 때 놓쳤을 수 있는 것들을 다시 받아온다:
  /// 방 목록(서버가 계산한 정확한 안읽음 수 포함)과, 지금까지 열어본 적 있어 캐시된 방들의 메시지.
  Future<void> _resyncAfterReconnect() async {
    try {
      final freshRooms = await api!.fetchRooms();
      for (final fresh in freshRooms) {
        final i = rooms.indexWhere((r) => r.id == fresh.id);
        if (i >= 0) {
          rooms[i] = fresh;
        } else {
          rooms.add(fresh);
        }
      }
      notifyListeners();
    } catch (_) {
      // 재연결 직후 방 목록 갱신 실패는 조용히 넘어간다 — 다음 재연결 때 다시 시도됨.
    }

    for (final controller in _controllers.values) {
      await controller.refresh();
    }
  }

  /// ApiClient가 401을 받았을 때 호출된다(ApiClient.onUnauthorized). 갱신에 성공하면 true를
  /// 돌려줘서 원래 요청을 재시도하게 한다.
  Future<bool> _tryRefreshAndApply() async => (await _tryRefreshAccessToken()) != null;

  /// refreshToken으로 새 accessToken을 받아온다. 여러 요청이 동시에 401을 맞아도 갱신
  /// 요청은 한 번만 나가도록 진행 중인 Future를 공유한다. refreshToken마저 무효면(비밀번호
  /// 변경, 다른 곳에서 로그아웃 등) 이 기기를 완전히 로그아웃시키고 null을 돌려준다.
  Future<String?> _tryRefreshAccessToken() {
    return _refreshInFlight ??= _doRefreshAccessToken().whenComplete(() => _refreshInFlight = null);
  }

  Future<String?> _doRefreshAccessToken() async {
    final rt = refreshToken;
    if (rt == null || api == null) {
      await _forceLogout();
      return null;
    }
    try {
      final newAccessToken = await api!.refreshAccessToken(rt);
      token = newAccessToken;
      api!.token = newAccessToken;
      if (_prefs.containsKey(_kToken)) {
        await _prefs.setString(_kToken, newAccessToken);
      }
      return newAccessToken;
    } catch (_) {
      await _forceLogout();
      return null;
    }
  }

  /// refreshToken까지 무효화된 경우(비밀번호 변경, 다른 기기에서 강제 로그아웃 등) 이
  /// 기기를 로그아웃 화면으로 되돌린다. 서버는 이미 이 세션을 폐기한 상태라 서버에 알릴
  /// 것은 없고, 로컬 상태만 정리한다.
  Future<void> _forceLogout() async {
    await logout();
    error = '세션이 만료되었습니다. 다시 로그인해주세요.';
    notifyListeners();
  }

  /// 새 메시지가 소켓으로 도착했을 때 알림 표시 여부와 방 목록의 안읽음 뱃지 증가를 함께 처리한다.
  /// 시스템 메시지/내가 보낸 메시지/지금 보고 있는 방이면 둘 다 건너뛴다.
  void _handleIncomingMessage(Message m) {
    if (m.type == MessageType.system) return;
    final isViewingNow = m.roomId == _activeRoomId && appInForeground;
    if (m.senderId == userId || isViewingNow) return;

    final match = rooms.where((r) => r.id == m.roomId);
    if (match.isNotEmpty) {
      match.first.unreadCount++;
      notifyListeners();
    }

    final room = match.isEmpty ? null : match.first;
    final roomTag = switch (room?.type) {
      null => null,
      RoomType.dm => '1:1',
      // 이름 없는 그룹채팅은 멤버 이름을 전부 나열하지 않고 "그룹채팅"이라고만 표시한다.
      RoomType.group => room!.name ?? '그룹채팅',
      RoomType.topic => room!.displayName(userId ?? ''),
    };
    final preview = switch (m.type) {
      MessageType.text => m.text ?? '',
      MessageType.image => '사진을 보냈습니다',
      MessageType.file => m.fileName ?? '파일을 보냈습니다',
      MessageType.system => '',
    };

    AppUser? sender;
    if (room != null) {
      for (final member in room.members) {
        if (member.id == m.senderId) {
          sender = member;
          break;
        }
      }
    }

    notifications.showMessage(
      title: roomTag != null ? '${m.senderName} [$roomTag]' : m.senderName,
      body: preview,
      roomId: m.roomId,
      avatarType: sender?.avatarType ?? 'initial',
      avatarEmoji: sender?.avatarEmoji,
      avatarColor: sender?.avatarColor,
      avatarUrl: sender?.avatarUrl != null ? resolveUrl(sender!.avatarUrl!) : null,
    );
  }

  void _upsertRoom(Room incoming) {
    final i = rooms.indexWhere((r) => r.id == incoming.id);
    if (i >= 0) {
      // 브로드캐스트/REST 응답에는 이 사람 기준 안읽음 수가 없거나 낡은 값일 수 있으니,
      // 실시간으로 로컬에서 추적 중이던 값을 유지한다.
      incoming.unreadCount = rooms[i].unreadCount;
      rooms[i] = incoming;
    } else {
      rooms.add(incoming);
    }
    notifyListeners();
  }

  /// 방을 열 때 안읽음 뱃지를 0으로 되돌린다.
  void clearUnreadCount(String roomId) {
    final match = rooms.where((r) => r.id == roomId);
    if (match.isEmpty || match.first.unreadCount == 0) return;
    match.first.unreadCount = 0;
    notifyListeners();
  }

  /// 방을 열 때 호출. 이미 열려있으면 캐시된 컨트롤러를 그대로 재사용한다.
  RoomChatController controllerFor(Room room) {
    return _controllers.putIfAbsent(room.id, () => RoomChatController(this, room));
  }

  Future<Room> createTopic({required String name, String? description, bool isPublic = true}) async {
    final room = await api!.createTopic(name: name, description: description, isPublic: isPublic);
    _upsertRoom(room);
    return room;
  }

  Future<Room> createGroup({String? name, required List<String> memberIds}) async {
    final room = await api!.createGroup(name: name, memberIds: memberIds);
    _upsertRoom(room);
    return room;
  }

  Future<Room> startDm(String targetUserId) async {
    final room = await api!.startDm(targetUserId);
    _upsertRoom(room);
    return room;
  }

  Future<Room> joinRoom(String roomId) async {
    final room = await api!.joinRoom(roomId);
    _upsertRoom(room);
    return room;
  }

  Future<void> inviteMembers(String roomId, List<String> userIds) async {
    final room = await api!.inviteMembers(roomId, userIds);
    _upsertRoom(room);
  }

  Future<void> updateAvatar({
    required String avatarType,
    String? avatarEmoji,
    String? avatarColor,
    String? avatarUrl,
  }) async {
    final me = await api!.updateMyAvatar(
      avatarType: avatarType,
      avatarEmoji: avatarEmoji,
      avatarColor: avatarColor,
      avatarUrl: avatarUrl,
    );
    this.avatarType = me.avatarType;
    this.avatarEmoji = me.avatarEmoji;
    this.avatarColor = me.avatarColor;
    this.avatarUrl = me.avatarUrl;
    notifyListeners();
  }

  Future<void> updateProfile({String? name, String? email}) async {
    final me = await api!.updateProfile(name: name, email: email);
    this.name = me.name;
    this.email = me.email;
    notifyListeners();
  }

  /// 회원 탈퇴. 서버가 세션/토큰을 이미 폐기해두므로, 성공하면 그냥 로그아웃과 같은
  /// 방식으로 로컬 상태를 정리한다. 비밀번호가 틀리면 여기서 던져서 다이얼로그가 잡는다.
  Future<void> withdraw(String password) async {
    await api!.withdraw(password);
    await logout();
  }

  /// 비밀번호 변경. 다른 기기는 서버가 강제로 끊지만, 이 기기는 응답으로 받은 새 토큰
  /// 쌍으로 로그아웃 없이 그대로 이어간다(소켓도 새 토큰으로 다시 연결).
  Future<void> changePassword({required String currentPassword, required String newPassword}) async {
    final result = await api!.changePassword(currentPassword: currentPassword, newPassword: newPassword);
    token = result.accessToken;
    refreshToken = result.refreshToken;
    api!.token = token;
    if (_prefs.containsKey(_kToken)) {
      await _prefs.setString(_kToken, token!);
      await _prefs.setString(_kRefreshToken, refreshToken!);
    }
    await chatSocket.connect(baseUrl: serverUrl!, token: token!);
  }

  Future<void> leaveRoom(String roomId) async {
    await api!.leaveRoom(roomId);
    rooms.removeWhere((r) => r.id == roomId);
    _controllers.remove(roomId)?.dispose();
    if (_activeRoomId == roomId) _activeRoomId = null;
    notifyListeners();
  }

  Future<void> logout() async {
    await _prefs.remove(_kToken);
    await _prefs.remove(_kRefreshToken);
    await _prefs.remove(_kUserId);
    await _prefs.remove(_kUsername);
    await _messageSub?.cancel();
    await _roomSub?.cancel();
    await _readSub?.cancel();
    await _presenceSub?.cancel();
    await _reconnectSub?.cancel();
    await _authErrorSub?.cancel();
    chatSocket.dispose();
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    onlineUserIds.clear();
    token = null;
    refreshToken = null;
    api?.token = null;
    userId = null;
    username = null;
    name = null;
    email = null;
    avatarType = 'initial';
    avatarEmoji = null;
    avatarColor = null;
    avatarUrl = null;
    rooms.clear();
    stage = AuthStage.needsLogin;
    notifyListeners();
  }

  String resolveUrl(String relative) => api?.resolve(relative) ?? relative;
}
