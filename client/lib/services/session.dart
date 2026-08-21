import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_user.dart';
import '../models/message.dart';
import '../models/room.dart';
import 'api_client.dart';
import 'app_settings.dart';
import 'chat_socket.dart';
import 'notification_service.dart';
import 'room_chat_controller.dart';

enum AuthStage { loadingConfig, needsServer, needsLogin, ready }

/// 앱 전체 상태: 서버 주소 → 로그인 → 방 목록 순으로 진행됩니다. 인증/방 목록/라우팅만
/// 책임지고, 방 하나의 메시지/전송은 RoomChatController에 맡깁니다.
/// 이전 KiwoomApi 포팅 때와 같은 패턴으로, ChangeNotifier + ListenableBuilder만 씁니다.
class Session extends ChangeNotifier {
  Session({required this.notifications, required this.settings});

  static const _kServerUrl = 'server_base_url';
  static const _kToken = 'auth_token';
  static const _kUserId = 'auth_user_id';
  static const _kUsername = 'auth_username';
  static const _kRememberedUsername = 'remembered_username';

  late SharedPreferences _prefs;

  AuthStage stage = AuthStage.loadingConfig;
  String? serverUrl;
  String? token;
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
  final chatSocket = ChatSocket();
  final NotificationService notifications;
  final AppSettings settings;
  final List<Room> rooms = [];

  final _controllers = <String, RoomChatController>{};
  StreamSubscription? _messageSub;
  StreamSubscription? _roomSub;
  StreamSubscription? _readSub;

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
    token = _prefs.getString(_kToken);
    userId = _prefs.getString(_kUserId);
    username = _prefs.getString(_kUsername);
    rememberedUsername = _prefs.getString(_kRememberedUsername);

    if (serverUrl == null) {
      stage = AuthStage.needsServer;
    } else {
      api = ApiClient(baseUrl: serverUrl!, token: token);
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
    final testClient = ApiClient(baseUrl: normalized);
    final ok = await testClient.checkHealth();
    if (!ok) {
      error = '서버에 연결할 수 없습니다. 주소를 확인하세요 (예: http://192.168.0.62:3000)';
      notifyListeners();
      return false;
    }
    serverUrl = normalized;
    await _prefs.setString(_kServerUrl, normalized);
    api = ApiClient(baseUrl: normalized);
    error = null;
    stage = AuthStage.needsLogin;
    notifyListeners();
    return true;
  }

  Future<bool> login(String u, String p, {required bool keepSignedIn}) =>
      _auth(() => api!.login(u, p), keepSignedIn: keepSignedIn);

  Future<bool> register(String u, String p, String email, String name, {required bool keepSignedIn}) =>
      _auth(() => api!.register(u, p, email, name), keepSignedIn: keepSignedIn);

  Future<bool> _auth(Future<AuthResult> Function() call, {required bool keepSignedIn}) async {
    try {
      final result = await call();
      token = result.token;
      userId = result.userId;
      username = result.username;
      if (keepSignedIn) {
        await _prefs.setString(_kToken, token!);
        await _prefs.setString(_kUserId, userId!);
        await _prefs.setString(_kUsername, username!);
      } else {
        // 이전 세션에서 "로그인 상태 유지"로 저장해둔 게 있을 수 있으니 같이 지운다.
        await _prefs.remove(_kToken);
        await _prefs.remove(_kUserId);
        await _prefs.remove(_kUsername);
      }
      api = ApiClient(baseUrl: serverUrl!, token: token);
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

    chatSocket.connect(baseUrl: serverUrl!, token: token!);
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

  Future<void> leaveRoom(String roomId) async {
    await api!.leaveRoom(roomId);
    rooms.removeWhere((r) => r.id == roomId);
    _controllers.remove(roomId)?.dispose();
    if (_activeRoomId == roomId) _activeRoomId = null;
    notifyListeners();
  }

  Future<void> logout() async {
    await _prefs.remove(_kToken);
    await _prefs.remove(_kUserId);
    await _prefs.remove(_kUsername);
    await _messageSub?.cancel();
    await _roomSub?.cancel();
    await _readSub?.cancel();
    chatSocket.dispose();
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    token = null;
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
