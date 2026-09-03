import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:open_file/open_file.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/stickers.dart';
import '../models/app_user.dart';
import '../models/comment.dart';
import '../models/message.dart';
import '../models/room.dart';
import 'api_client.dart';
import 'app_settings.dart';
import 'chat_socket.dart';
import 'device_identity.dart';
import 'message_preview.dart';
import 'notification_service.dart';
import 'pinned_tls.dart';
import 'room_chat_controller.dart';
import 'secret_session_manager.dart';

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
  static const _secretPreviewPlaceholder = '새 메시지가 있습니다';

  // FCM 백그라운드 핸들러(main.dart)는 이 Session과 완전히 별개의 격리된 isolate에서
  // 돌아서 activeRoomId/appInForeground 필드에 전혀 접근할 수 없다 — 그래서 그 값이
  // 바뀔 때마다 SharedPreferences에도 같이 적어두고, 백그라운드 핸들러가 알림을 그리기
  // 직전에 그걸 읽어서 "지금 그 방을 보고 있는 중이면" 건너뛸 수 있게 한다. main.dart가
  // 같은 키로 읽어야 해서 public으로 둔다.
  static const kActiveRoomIdPrefsKey = 'active_room_id';
  static const kAppInForegroundPrefsKey = 'app_in_foreground';

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
  bool updateDownloading = false;
  // 0~1(다운로드 %). 서버가 Content-Length를 안 주면(드묾) null로 남아 있고, 호출부는
  // 이 경우 불확정(indeterminate) 진행 표시를 해야 한다.
  double? updateDownloadProgress;
  String? updateError; // installUpdate() 실패 시 사용자에게 보여줄 메시지.
  final chatSocket = ChatSocket();
  final NotificationService notifications;
  final AppSettings settings;
  final List<Room> rooms = [];

  /// 비밀 대화(E2EE)의 이 기기 신원 + 방별 핸드셰이크/암복호화 상태. 로그인마다(재로그인 포함)
  /// api 인스턴스가 바뀌므로 secretSessionManager는 _enterApp에서 매번 새로 만들지만,
  /// deviceIdentity(기기 UUID+키쌍)는 flutter_secure_storage에 영구 저장되므로 인스턴스만 재사용.
  DeviceIdentity? deviceIdentity;
  SecretSessionManager? secretSessionManager;

  /// 아직 응답하지 않은 비밀 대화 초대(secret:invite). UI가 이 목록을 보고 수락/거절 다이얼로그를 띄운다.
  final List<SecretInviteEvent> pendingSecretInvites = [];

  /// 화면 어디에 있든(방을 안 보고 있어도) 한 번 스치듯 보여주면 되는 안내 — 비밀 대화
  /// 거절/양쪽 나가기처럼 "방 자체가 사라지는" 이벤트를 토스트(SnackBar)로 알릴 때 쓴다.
  /// main.dart가 이 스트림을 구독해서 navigatorKey의 context로 SnackBar를 띄운다.
  final _toastController = StreamController<String>.broadcast();
  Stream<String> get toasts => _toastController.stream;
  void _showToast(String message) => _toastController.add(message);

  /// 지금 이모티콘 패널을 열어둔 화면(ChatPanel 또는 MessageThreadScreen의 State 객체, 식별용
  /// 토큰일 뿐 내용은 안 씀)을 담는다 — 채팅방과 댓글 패널이 동시에 떠 있을 때(데스크톱 분할
  /// 화면) 한쪽에서 이모티콘 버튼을 누르면 다른 쪽에 열려있던 패널이 자동으로 닫히게 하는 데
  /// 쓴다. Session 전체의 notifyListeners()에 얹으면 잦은 무관한 갱신에도 매번 걸리니, 이
  /// 용도로만 쓰는 별도의 가벼운 ValueNotifier로 둔다.
  final ValueNotifier<Object?> openStickerPickerOwner = ValueNotifier(null);

  final _controllers = <String, RoomChatController>{};
  StreamSubscription? _messageSub;
  StreamSubscription? _roomSub;
  StreamSubscription? _readSub;
  StreamSubscription? _favoriteSub;
  StreamSubscription? _mutedSub;
  StreamSubscription? _commentSub;
  StreamSubscription? _messageEditedSub;
  StreamSubscription? _messageDeletedSub;
  StreamSubscription? _commentEditedSub;
  StreamSubscription? _commentDeletedSub;
  StreamSubscription? _presenceSub;
  StreamSubscription? _reconnectSub;
  StreamSubscription? _authErrorSub;
  StreamSubscription? _secretInviteSub;
  StreamSubscription? _secretAcceptedSub;
  StreamSubscription? _secretRejectedSub;
  StreamSubscription? _secretLeftSub;
  StreamSubscription? _secretSettingsSub;
  StreamSubscription? _secretMessageReadSub;
  StreamSubscription? _messageExpiredSub;
  StreamSubscription? _secretRekeyProposeSub;
  StreamSubscription? _secretRekeyAckSub;
  StreamSubscription<String>? _fcmTokenRefreshSub;

  /// 지금 소켓으로 연결되어 있는(온라인) 사용자 id 집합. 멤버 목록의 초록 점 표시에 쓴다.
  final Set<String> onlineUserIds = {};
  Future<String?>? _refreshInFlight;

  String? _activeRoomId;
  String? get activeRoomId => _activeRoomId;

  /// 활성 방을 지정할 때마다 올라가는 일련번호. 화면이 닫힐 때 자기가 받았던 번호를
  /// [clearActiveRoom]에 되돌려주면, 그 사이 다른 화면이 활성 방을 새로 지정했는지 구분할 수 있다.
  int _activeRoomToken = 0;

  /// 활성 방을 지정하고, 화면이 닫힐 때 [clearActiveRoom]에 넘길 토큰을 돌려준다.
  int setActiveRoom(String roomId) {
    _activeRoomId = roomId;
    _persistForegroundState();
    // 방을 여는 순간, 그 방으로 이미 떠있던 알림(백그라운드 FCM 경로에서 놓친 것 포함)을
    // 바로 지운다 — 안 그러면 방을 봐도 알림이 남아있고 앱 아이콘의 안읽음 배지도 안 지워진다.
    notifications.cancelForRoom(roomId);
    return ++_activeRoomToken;
  }

  /// 채팅 화면이 닫힐 때 호출한다. 그 사이 다른 화면이 활성 방을 새로 지정했으면(토큰 불일치)
  /// 아무것도 하지 않는다.
  ///
  /// 방 id만 비교하면 안 되는 이유: 알림을 눌러서 "이미 열려 있던 그 방"을 다시 열면
  /// popUntil+push로 같은 방의 ChatPanel이 새로 만들어지는데, 새 initState가 먼저 돌고
  /// 옛 dispose가 나중에 돈다. 이때 id만 보면 (같은 방이라) 가드를 통과해서 활성 방을
  /// null로 지워버리고, 그러면 방을 보고 있는데도 읽음 처리와 알림 억제가 통째로 멈춘다.
  void clearActiveRoom(int token) {
    if (token != _activeRoomToken) return;
    _activeRoomId = null;
    _persistForegroundState();
  }

  /// 방이 사라져서(나가기/비밀대화 종료) 강제로 활성 방을 푸는 경우.
  void _forceClearActiveRoom() {
    _activeRoomId = null;
    _activeRoomToken++;
    _persistForegroundState();
  }

  /// 모바일(휴대폰 화면 폭)에서 댓글 스레드를 전체화면으로 열면(MessageThreadScreen이
  /// asPanel:false로 push됨) 그 밑에 있는 채팅 화면(ChatPanel)은 네비게이션 스택엔 남아있어
  /// activeRoomId는 그대로지만, 실제로는 화면에 안 보인다. 그래서 그 방으로 새 메시지가
  /// 와도 activeRoomId만 보고 "지금 보고 있다"고 판단하면 알림/안읽음 처리가 잘못
  /// 억제된다. 이 필드로 "지금 그 방의 댓글 스레드가 화면을 덮고 있는지"를 따로 추적해서
  /// _handleIncomingMessage가 구분할 수 있게 한다. 데스크톱은 댓글 패널이 채팅 목록
  /// 옆에 나란히 뜨는 패널이라(항상 같이 보임) 이 값을 안 쓴다.
  String? _mobileThreadOpenRoomId;
  String? get mobileThreadOpenRoomId => _mobileThreadOpenRoomId;
  void setMobileCommentThreadOpen(String? roomId) =>
      _mobileThreadOpenRoomId = roomId;

  bool appInForeground = true;

  /// 창이 백그라운드였다가 다시 포그라운드로 돌아왔을 때, 이미 열려있던 방(activeRoomId)이
  /// 있다면 그 사이 온 메시지를 읽음 처리하고 안읽음 뱃지를 지운다. 방을 처음 열 때는
  /// ChatPanel.initState가 같은 일을 하지만, 방을 계속 열어둔 채로 창만 비활성화→활성화된
  /// 경우엔 ChatPanel이 다시 마운트되지 않아서 이 훅이 따로 필요하다.
  void setAppInForeground(bool value) {
    final wasBackground = !appInForeground;
    appInForeground = value;
    _persistForegroundState();
    if (value && wasBackground && _activeRoomId != null) {
      _controllers[_activeRoomId]?.markReadNow();
      clearUnreadCount(_activeRoomId!);
      notifications.cancelForRoom(_activeRoomId!);
    }
  }

  /// FCM 백그라운드 핸들러가 읽을 수 있도록 activeRoomId/appInForeground를
  /// SharedPreferences에 그대로 미러링해둔다 — 위 두 setter의 클래스 주석 참고.
  void _persistForegroundState() {
    // init()이 아직 _prefs를 못 채운 아주 이른 시점(앱 시작 직후 lifecycle 콜백 등)에
    // 불릴 수 있어서, 그때는 조용히 건너뛴다 — init()이 끝나면 자연히 최신 상태로
    // 다시 반영된다(다음 setActiveRoom/setAppInForeground 호출 시).
    late SharedPreferences prefs;
    try {
      prefs = _prefs;
    } catch (_) {
      return;
    }
    final roomId = _activeRoomId;
    if (roomId == null) {
      prefs.remove(kActiveRoomIdPrefsKey);
    } else {
      prefs.setString(kActiveRoomIdPrefsKey, roomId);
    }
    prefs.setBool(kAppInForegroundPrefsKey, appInForeground);
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
    // 앱이 시작 상태 그대로(포그라운드) 죽 있으면 didChangeAppLifecycleState가 한 번도
    // 안 불려서 _persistForegroundState가 늦게까지 실행 안 될 수 있다 — 여기서 한 번
    // 명시적으로 찍어둬서 FCM 백그라운드 핸들러가 항상 최신 값을 읽을 수 있게 한다.
    _persistForegroundState();
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
    api = ApiClient(
      baseUrl: normalized,
      onUnauthorized: _tryRefreshAndApply,
      httpClient: pinnedClient,
    );
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

  /// 업데이트 대화상자의 "지금 설치"를 눌렀을 때 — 브라우저로 넘기지 않고 앱이 직접 설치
  /// 파일을 받아서(진행률을 [updateDownloadProgress]로 보고) 그 자리에서 실행/설치까지 한다.
  /// Windows는 받은 설치 프로그램(.exe)을 여는 것 자체가 설치 실행이고, Android는 apk를
  /// 여는 것으로 시스템 패키지 설치 화면(REQUEST_INSTALL_PACKAGES 권한 필요)이 뜬다.
  Future<void> installUpdate() async {
    if (api == null || updateDownloading) return;
    updateDownloading = true;
    updateDownloadProgress = null;
    updateError = null;
    notifyListeners();
    try {
      final platformPath = Platform.isAndroid ? 'android' : 'windows';
      final fileName = Platform.isAndroid ? 'update.apk' : 'update-setup.exe';
      final response = await api!.downloadUpdate(platformPath);
      if (response.statusCode != 200) {
        throw '다운로드에 실패했습니다 (${response.statusCode}).';
      }
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$fileName');
      final sink = file.openWrite();
      final total = response.contentLength;
      var received = 0;
      await response.stream.listen((chunk) {
        sink.add(chunk);
        received += chunk.length;
        if (total != null && total > 0) {
          updateDownloadProgress = received / total;
          notifyListeners();
        }
      }).asFuture<void>();
      await sink.close();
      await OpenFile.open(file.path);
    } catch (e) {
      updateError = '업데이트 설치 실패: $e';
    } finally {
      updateDownloading = false;
      notifyListeners();
    }
  }

  Future<bool> login(String u, String p, {required bool keepSignedIn}) =>
      _auth(() => api!.login(u, p), keepSignedIn: keepSignedIn);

  Future<bool> register(
    String u,
    String p,
    String email,
    String name, {
    required String securityQuestion,
    required String securityAnswer,
    required bool keepSignedIn,
  }) => _auth(
    () => api!.register(
      u,
      p,
      email,
      name,
      securityQuestion: securityQuestion,
      securityAnswer: securityAnswer,
    ),
    keepSignedIn: keepSignedIn,
  );

  Future<bool> _auth(
    Future<AuthResult> Function() call, {
    required bool keepSignedIn,
  }) async {
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
      for (final room in myRooms) {
        unawaited(ensurePendingSecretInvite(room.id));
      }
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

    deviceIdentity ??= DeviceIdentity();
    await deviceIdentity!.ensureLoaded();
    secretSessionManager = SecretSessionManager(
      api: api!,
      socket: chatSocket,
      identity: deviceIdentity!,
    );
    // FCM 토큰 등록(_registerFcmToken)은 서버의 devices 테이블에 이 기기 행이 먼저 있어야
    // UPDATE가 걸린다(server/src/db/queries/devices.js의 setDeviceFcmToken). 여기서
    // registerWithServer를 fire-and-forget으로 두면, 새로 설치한 기기처럼 아직 그 행이 없는
    // 상태에서 두 요청이 거의 동시에 나가 _registerFcmToken이 먼저 도착해버리는 경쟁 상태가
    // 생긴다 — 이때 서버는 404를 돌려주고, _registerFcmToken은 그 실패를 조용히 삼켜서 FCM
    // 토큰이 영영 등록되지 않는다(원인을 알기 어려운 형태로). 기기 등록만 먼저 기다린다.
    await deviceIdentity!.registerWithServer(api!);
    unawaited(_registerFcmToken());

    await chatSocket.connect(
      baseUrl: serverUrl!,
      token: token!,
      deviceId: deviceIdentity!.deviceId,
    );
    _messageSub?.cancel();
    _messageSub = chatSocket.messages.listen((m) async {
      await decryptInPlace(_findRoom(m.roomId), m);
      _controllers[m.roomId]?.feed(m);
      // 내가 보낸 메시지도 이 방 소켓으로 그대로 되돌아오므로(feed 참고), 보낸/받은 경우 모두
      // 여기서 한 번에 방을 "최근 활동"으로 끌어올릴 수 있다 — _handleIncomingMessage는 내가
      // 보낸 경우 알림/안읽음 처리를 건너뛰지만, 방 목록 정렬은 그것과 무관하게 항상 갱신한다.
      _bumpRoomActivity(m.roomId, m.createdAt);
      _updateRoomPreview(
        m.roomId,
        type: m.type,
        text: m.text,
        fileName: m.fileName,
      );
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
    _favoriteSub?.cancel();
    _favoriteSub = chatSocket.favoriteEvents.listen((e) {
      final match = rooms.where((r) => r.id == e.roomId);
      if (match.isEmpty) return;
      match.first.favorite = e.favorite;
      notifyListeners();
    });
    _mutedSub?.cancel();
    _mutedSub = chatSocket.mutedEvents.listen((e) {
      final match = rooms.where((r) => r.id == e.roomId);
      if (match.isEmpty) return;
      match.first.muted = e.muted;
      notifyListeners();
    });
    _commentSub?.cancel();
    _commentSub = chatSocket.commentEvents.listen((c) async {
      await decryptCommentInPlace(_findRoom(c.roomId), c);
      _controllers[c.roomId]?.addComment(c);
      _bumpRoomActivity(c.roomId, c.createdAt);
      _updateRoomPreview(
        c.roomId,
        type: c.type,
        text: c.text,
        fileName: c.fileName,
      );
      _handleIncomingComment(c);
    });
    _messageEditedSub?.cancel();
    _messageEditedSub = chatSocket.messageEdited.listen((m) async {
      // 같은 messageId라도 내용이 바뀐 것(수정)이라 forceDecrypt로 캐시를 무시하고 새로
      // 복호화한다 — 안 그러면 수정 전 평문이 영구 캐시에 박제되어 계속 그것만 보인다.
      await decryptInPlace(_findRoom(m.roomId), m, forceDecrypt: true);
      _controllers[m.roomId]?.applyEdit(m);
    });
    _messageDeletedSub?.cancel();
    _messageDeletedSub = chatSocket.messageDeleted.listen((e) {
      _controllers[e.roomId]?.applyDelete(e.id);
    });
    _commentEditedSub?.cancel();
    _commentEditedSub = chatSocket.commentEdited.listen((c) async {
      await decryptCommentInPlace(_findRoom(c.roomId), c, forceDecrypt: true);
      _controllers[c.roomId]?.applyCommentEdit(c);
    });
    _commentDeletedSub?.cancel();
    _commentDeletedSub = chatSocket.commentDeleted.listen((e) {
      _controllers[e.roomId]?.applyCommentDelete(e.id);
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
    _secretInviteSub?.cancel();
    _secretInviteSub = chatSocket.secretInvites.listen((e) {
      pendingSecretInvites.add(e);
      notifyListeners();
      // 포그라운드면 HomeScreen이 즉시 수락/거절 다이얼로그를 띄우므로(_maybeShowSecretInvite)
      // 알림까지 겹쳐 뜰 필요는 없다 — 백그라운드일 때만(메시지 알림과 같은 기준) 띄운다.
      if (appInForeground) return;
      final room = _findRoom(e.roomId);
      AppUser? initiator;
      if (room != null) {
        for (final member in room.members) {
          if (member.id == e.initiatorUserId) {
            initiator = member;
            break;
          }
        }
      }
      notifications.showMessage(
        title: initiator != null ? '${initiator.name} [비밀대화 요청]' : '비밀대화 요청',
        body: '비밀 대화(종단간 암호화)를 요청했습니다.',
        roomId: e.roomId,
        senderName: initiator?.name,
        conversationTitle: '비밀대화 요청',
        avatarType: initiator?.avatarType ?? 'initial',
        avatarEmoji: initiator?.avatarEmoji,
        avatarColor: initiator?.avatarColor,
        avatarUrl: initiator?.avatarUrl != null
            ? resolveUrl(initiator!.avatarUrl!)
            : null,
        isSecret: true,
      );
    });
    _secretAcceptedSub?.cancel();
    _secretAcceptedSub = chatSocket.secretAccepted.listen((e) async {
      await secretSessionManager?.handleAccepted(e);
      final room = _findRoom(e.roomId);
      if (room != null) {
        room.secretStatus = 'active';
        notifyListeners();
      }
    });
    _secretRejectedSub?.cancel();
    _secretRejectedSub = chatSocket.secretRejected.listen((e) async {
      // 거절한 사람(응답자) 본인은 방금 자기가 누른 결과라 알 필요가 없다 — 요청을 보내고
      // 기다리던 쪽(초대자)에게만 알려준다.
      final iAmInitiator = _findRoom(e.roomId)?.secretInitiatorUserId == userId;
      await secretSessionManager?.forgetRoom(e.roomId);
      rooms.removeWhere((r) => r.id == e.roomId);
      _controllers.remove(e.roomId)?.dispose();
      if (_activeRoomId == e.roomId) _forceClearActiveRoom();
      notifyListeners();
      if (iAmInitiator) _showToast('상대방이 요청을 거절했습니다.');
    });
    _secretLeftSub?.cancel();
    _secretLeftSub = chatSocket.secretLeft.listen((e) async {
      // 나 또는 상대방이 나가서 서버가 방을 완전히 지웠다는 신호 — 양쪽 다 여기서 정리한다.
      await secretSessionManager?.forgetRoom(e.roomId);
      rooms.removeWhere((r) => r.id == e.roomId);
      _controllers.remove(e.roomId)?.dispose();
      if (_activeRoomId == e.roomId) _forceClearActiveRoom();
      notifyListeners();
      _showToast('비밀 대화가 종료되었습니다.');
    });
    _secretSettingsSub?.cancel();
    _secretSettingsSub = chatSocket.secretSettings.listen((e) {
      final room = _findRoom(e.roomId);
      if (room != null) {
        room.secretSelfDestructSeconds = e.selfDestructSeconds;
        notifyListeners();
      }
    });
    _secretMessageReadSub?.cancel();
    _secretMessageReadSub = chatSocket.secretMessageRead.listen((e) {
      _controllers[e.roomId]?.applyMessageRead(
        e.messageId,
        DateTime.fromMillisecondsSinceEpoch(e.readAt),
        e.expiresAt != null
            ? DateTime.fromMillisecondsSinceEpoch(e.expiresAt!)
            : null,
      );
    });
    _messageExpiredSub?.cancel();
    _messageExpiredSub = chatSocket.messageExpired.listen((e) {
      _controllers[e.roomId]?.applyExpire(e.messageId);
    });
    _secretRekeyProposeSub?.cancel();
    _secretRekeyProposeSub = chatSocket.secretRekeyPropose.listen((e) {
      secretSessionManager?.handleRekeyPropose(e);
    });
    _secretRekeyAckSub?.cancel();
    _secretRekeyAckSub = chatSocket.secretRekeyAck.listen((e) {
      secretSessionManager?.handleRekeyAck(e);
    });
    _reconnectSub?.cancel();
    _reconnectSub = chatSocket.reconnected.listen(
      (_) => _resyncAfterReconnect(),
    );
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

  /// FCM은 안드로이드에서만 공식 지원한다(Windows는 firebase_messaging 플러그인 자체가
  /// 없음) — 그래서 PC 앱은 지금처럼 소켓이 연결돼 있는 동안만 로컬 알림을 띄우는 방식을
  /// 그대로 쓰고, 이 등록은 안드로이드에서만 시도한다. 실패해도(권한 거부, 오프라인 등)
  /// 앱 사용 자체는 계속돼야 하므로 전부 조용히 무시한다 — 소켓이 붙어있는 동안은 기존
  /// 방식으로도 알림이 정상적으로 오고, FCM은 "앱이 완전히 꺼졌을 때"를 위한 보강일 뿐이다.
  Future<void> _registerFcmToken() async {
    if (!Platform.isAndroid) return;
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      final token = await messaging.getToken();
      if (token != null)
        await api!.registerFcmToken(deviceIdentity!.deviceId, token);

      await _fcmTokenRefreshSub?.cancel();
      _fcmTokenRefreshSub = messaging.onTokenRefresh.listen((newToken) {
        api
            ?.registerFcmToken(deviceIdentity!.deviceId, newToken)
            .catchError((e) => debugPrint('[fcm] 토큰 갱신 등록 실패: $e'));
      });
    } catch (e) {
      // 다음 로그인/토큰 갱신 때 다시 시도된다 — 그래도 원인을 눈으로 확인할 수 있게 로그는 남긴다.
      debugPrint('[fcm] 토큰 등록 실패: $e');
    }
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
  Future<bool> _tryRefreshAndApply() async =>
      (await _tryRefreshAccessToken()) != null;

  /// refreshToken으로 새 accessToken을 받아온다. 여러 요청이 동시에 401을 맞아도 갱신
  /// 요청은 한 번만 나가도록 진행 중인 Future를 공유한다. refreshToken마저 무효면(비밀번호
  /// 변경, 다른 곳에서 로그아웃 등) 이 기기를 완전히 로그아웃시키고 null을 돌려준다.
  Future<String?> _tryRefreshAccessToken() {
    return _refreshInFlight ??= _doRefreshAccessToken().whenComplete(
      () => _refreshInFlight = null,
    );
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

  Room? _findRoom(String roomId) {
    final match = rooms.where((r) => r.id == roomId);
    return match.isEmpty ? null : match.first;
  }

  // ---- 비밀 대화(E2EE) ----

  /// 상대에게 비밀 대화를 건다 — 새 방이 생성되고 서버로는 임시 공개키/서명만 나간다.
  Future<Room> startSecretChat(String targetUserId) async {
    final room = await secretSessionManager!.startSecretChat(targetUserId);
    _upsertRoom(room);
    return room;
  }

  Future<void> acceptSecretInvite(SecretInviteEvent invite) async {
    pendingSecretInvites.remove(invite);
    final ok = await secretSessionManager!.acceptInvite(invite);
    if (!ok) {
      error = '상대 기기의 서명을 확인할 수 없어 비밀 대화를 시작할 수 없습니다.';
    }
    final room = _findRoom(invite.roomId);
    if (room != null && ok) room.secretStatus = 'active';
    notifyListeners();
  }

  Future<void> rejectSecretInvite(SecretInviteEvent invite) async {
    pendingSecretInvites.remove(invite);
    await secretSessionManager!.rejectInvite(invite.roomId);
    notifyListeners();
  }

  /// 응답이 필요한 비밀 대화 초대(내가 초대한 쪽이 아니고 아직 pending)인데 아직
  /// pendingSecretInvites에 없으면(=온라인이어서 받은 secret:invite 소켓 이벤트를 놓친
  /// 경우 — 앱이 꺼져있어서 FCM 알림만 받았을 때가 대표적) 서버에서 다시 가져와 채워
  /// 넣는다. HomeScreen._maybeShowSecretInvite가 이 목록을 보고 수락/거절 다이얼로그를
  /// 띄우므로, 이걸 부르는 것만으로 알림을 눌렀을 때 방이 아니라 그 다이얼로그가 뜨게 된다.
  /// 응답 대상이 아니거나 이미 처리됐으면(서버가 404) 조용히 아무 것도 안 한다.
  Future<void> ensurePendingSecretInvite(String roomId) async {
    final room = _findRoom(roomId);
    if (room == null || !room.isSecret || room.secretStatus != 'pending') {
      return;
    }
    if (room.secretInitiatorUserId == userId) return;
    if (pendingSecretInvites.any((e) => e.roomId == roomId)) return;
    try {
      final invite = await api!.fetchSecretInvite(roomId);
      if (pendingSecretInvites.any((e) => e.roomId == invite.roomId)) return;
      pendingSecretInvites.add(invite);
      notifyListeners();
    } catch (_) {
      // 이미 수락/거절됐거나(404) 네트워크 실패 — 다음 동기화 때 다시 시도된다.
    }
  }

  Future<void> setSecretChatTimer(Room room, int? seconds) async {
    await api!.setSecretChatTimer(room.id, seconds);
    room.secretSelfDestructSeconds = seconds;
    notifyListeners();
  }

  /// 비밀 대화면 평문을 암호문 봉투(JSON 문자열)로 바꾼다. 세션이 아직 성립되지 않았으면(핸드셰이크
  /// 진행 중) 예외를 던진다 — 호출자가 스낵바 등으로 보여줄 수 있게.
  Future<String?> encryptOutgoing(Room room, String? plainText) async {
    if (!room.isSecret) return plainText;
    final envelope = await secretSessionManager!.encryptForRoom(
      room.id,
      plainText ?? '',
    );
    if (envelope == null) {
      throw ApiException('비밀 대화가 아직 준비되지 않았습니다. 잠시 후 다시 시도해주세요.');
    }
    return envelope;
  }

  /// 비밀 대화의 이미지/파일 첨부 — 캡션+원본 파일정보+첨부 복호화 키를 하나의 암호문 봉투로
  /// 묶는다. 서버로는 이 봉투만 text에 담아 보내고, 실제 파일명/종류는 더미 값으로 가린다.
  Future<String> encryptAttachmentPayload(
    Room room, {
    String? caption,
    required String fileName,
    required int fileSize,
    String? mimeType,
    required String attachmentKey,
    required String attachmentNonce,
    String? thumbnailKey,
    String? thumbnailNonce,
  }) async {
    final payload = jsonEncode({
      'caption': caption,
      'fileName': fileName,
      'fileSize': fileSize,
      'mimeType': mimeType,
      'attachmentKey': attachmentKey,
      'attachmentNonce': attachmentNonce,
      'thumbnailKey': thumbnailKey,
      'thumbnailNonce': thumbnailNonce,
    });
    final envelope = await secretSessionManager!.encryptForRoom(
      room.id,
      payload,
    );
    if (envelope == null) {
      throw ApiException('비밀 대화가 아직 준비되지 않았습니다. 잠시 후 다시 시도해주세요.');
    }
    return envelope;
  }

  /// 수신한 메시지의 text가 비밀 대화 암호문 봉투면 그 자리에서 평문으로 바꾼다(실패하면
  /// decryptFailed만 세우고 text는 null). 이미지/파일 메시지는 캡션+원본 파일정보+첨부 복호화
  /// 키가 봉투 하나에 다 들어있어서, 풀어서 각 필드로 나눠 담는다(encryptAttachmentPayload와 대칭).
  ///
  /// 한 방향 래칫은 지나간 메시지의 키를 다시 계산할 수 없어서, 방을 다시 열거나(재연결/앱
  /// 재시작 포함) 서버 히스토리를 다시 받아올 때마다 매번 암호문을 새로 복호화하려고 하면
  /// 이미 지나간 옛 메시지는 전부 실패한다 — 그래서 처음 성공한 평문을 messageId로 이 기기에
  /// 영구 캐싱해두고, 두 번째부터는 그 캐시를 먼저 확인한다(secret_key_store.dart 참고).
  /// [forceDecrypt]는 message:edited처럼 같은 messageId인데 내용이 바뀐 경우에 쓴다 — 캐시를
  /// 읽지 않고 새 암호문을 새로 복호화한 뒤, 그 결과로 캐시를 덮어쓴다(안 그러면 수정 전
  /// 내용이 영구 캐시에 박제되어 계속 그것만 보인다).
  Future<void> decryptInPlace(
    Room? room,
    Message m, {
    bool forceDecrypt = false,
  }) async {
    if (room == null || !room.isSecret || m.text == null) return;
    // 시스템 메시지(자동 삭제 타이머 변경 안내 등)는 postSystemMessage가 암호화하지 않고
    // 평문 그대로 저장한다 — 그걸 암호문으로 착각해 복호화를 시도하면 실패해서
    // "복호화할 수 없습니다"로 잘못 보인다.
    if (m.type == MessageType.system) return;
    final cached = forceDecrypt
        ? null
        : await secretSessionManager?.readCachedDecryptedText(m.id);
    final plain =
        cached ?? await secretSessionManager?.decryptForRoom(room.id, m.text!);
    if (plain == null) {
      m.decryptFailed = true;
      m.text = null;
      return;
    }
    if (cached == null) {
      await secretSessionManager?.cacheDecryptedText(m.id, plain);
    }
    if (m.type == MessageType.image || m.type == MessageType.file) {
      try {
        final meta = jsonDecode(plain) as Map<String, dynamic>;
        m.text = meta['caption'] as String?;
        m.fileName = meta['fileName'] as String?;
        m.fileSize = (meta['fileSize'] as num?)?.toInt();
        m.mimeType = meta['mimeType'] as String?;
        m.attachmentKey = meta['attachmentKey'] as String?;
        m.attachmentNonce = meta['attachmentNonce'] as String?;
        m.thumbnailKey = meta['thumbnailKey'] as String?;
        m.thumbnailNonce = meta['thumbnailNonce'] as String?;
      } catch (_) {
        m.decryptFailed = true;
        m.text = null;
      }
    } else {
      m.text = plain;
    }
  }

  /// decryptInPlace와 동일한 규칙(+동일한 영구 캐시, forceDecrypt 의미도 동일)을 댓글에 적용한다.
  Future<void> decryptCommentInPlace(
    Room? room,
    Comment c, {
    bool forceDecrypt = false,
  }) async {
    if (room == null || !room.isSecret || c.text == null) return;
    final cached = forceDecrypt
        ? null
        : await secretSessionManager?.readCachedDecryptedText(c.id);
    final plain =
        cached ?? await secretSessionManager?.decryptForRoom(room.id, c.text!);
    if (plain == null) {
      c.decryptFailed = true;
      c.text = null;
      return;
    }
    if (cached == null) {
      await secretSessionManager?.cacheDecryptedText(c.id, plain);
    }
    if (c.type == MessageType.image || c.type == MessageType.file) {
      try {
        final meta = jsonDecode(plain) as Map<String, dynamic>;
        c.text = meta['caption'] as String?;
        c.fileName = meta['fileName'] as String?;
        c.fileSize = (meta['fileSize'] as num?)?.toInt();
        c.mimeType = meta['mimeType'] as String?;
        c.attachmentKey = meta['attachmentKey'] as String?;
        c.attachmentNonce = meta['attachmentNonce'] as String?;
        c.thumbnailKey = meta['thumbnailKey'] as String?;
        c.thumbnailNonce = meta['thumbnailNonce'] as String?;
      } catch (_) {
        c.decryptFailed = true;
        c.text = null;
      }
    } else {
      c.text = plain;
    }
  }

  /// 방을 열 때(REST로 받아온 히스토리) 메시지/댓글을 한꺼번에 복호화한다.
  Future<void> decryptHistory(Room room, List<Message> history) async {
    if (!room.isSecret) return;
    for (final m in history) {
      await decryptInPlace(room, m);
      for (final c in m.comments) {
        await decryptCommentInPlace(room, c);
      }
    }
  }

  /// 이 방에서 방금 활동(메시지/댓글을 보냈거나 받음)이 있었다는 뜻 — 방 목록에서 그 방을
  /// 속한 카테고리(토픽/그룹/DM) 안 맨 위로 끌어올리는 데 쓴다(desktop_home_screen.dart,
  /// room_list_screen.dart의 _favoriteFirst 정렬 참고). 재연결 중 순서가 안 맞는 이벤트가
  /// 뒤늦게 와도 시간을 거꾸로 되돌리지 않도록, 더 최근 시각일 때만 갱신한다.
  void _bumpRoomActivity(String roomId, DateTime at) {
    final match = rooms.where((r) => r.id == roomId);
    if (match.isEmpty) return;
    final room = match.first;
    if (at.isAfter(room.lastActivityAt)) {
      room.lastActivityAt = at;
      notifyListeners();
    }
  }

  /// 그룹채팅/채팅 목록 이름 아래 미리보기(room_list_screen.dart)를 새 메시지/댓글 내용으로
  /// 갱신한다. 시스템 메시지는 제외(로그인 시 서버가 내려준 마지막 실제 대화 미리보기를 계속
  /// 보여준다) — rooms.js의 toRoomDto가 로그인 시점 값을 계산하는 규칙과 맞춘다.
  void _updateRoomPreview(
    String roomId, {
    required MessageType type,
    String? text,
    String? fileName,
  }) {
    if (type == MessageType.system || type == MessageType.comment) return;
    final match = rooms.where((r) => r.id == roomId);
    if (match.isEmpty) return;
    final room = match.first;
    room.lastMessagePreview = room.isSecret
        ? _secretPreviewPlaceholder
        : formatMessagePreview(type: type, text: text, fileName: fileName);
    notifyListeners();
  }

  /// 새 메시지가 소켓으로 도착했을 때 알림 표시 여부와 방 목록의 안읽음 뱃지 증가를 함께 처리한다.
  /// 시스템 메시지/내가 보낸 메시지/지금 보고 있는 방이면 둘 다 건너뛴다.
  void _handleIncomingMessage(Message m) {
    if (m.type == MessageType.system) return;
    final isViewingNow =
        m.roomId == _activeRoomId &&
        appInForeground &&
        _mobileThreadOpenRoomId != m.roomId;
    if (m.senderId == userId || isViewingNow) return;

    final match = rooms.where((r) => r.id == m.roomId);
    if (match.isNotEmpty) {
      match.first.unreadCount++;
      notifyListeners();
    }

    final room = match.isEmpty ? null : match.first;
    // 알림 끄기는 안읽음 뱃지(이미 위에서 증가시켰다)는 그대로 두고, 알림(배너/토스트)만 막는다.
    if (room?.muted == true) return;
    final roomTag = switch (room?.type) {
      null => null,
      RoomType.dm => '1:1',
      // 이름 없는 그룹채팅은 멤버 이름을 전부 나열하지 않고 "그룹채팅"이라고만 표시한다.
      RoomType.group => room!.name ?? '그룹채팅',
      RoomType.topic => room!.displayName(userId ?? ''),
    };
    // 비밀 대화는 서버가 어차피 내용을 복호화할 수 없어서 서버발 미리보기 자체가 불가능하지만,
    // 클라이언트가 이미 복호화해둔 내용을 알림에 그대로 보여주는 것도 의도적으로 막는다 —
    // 화면 잠금 상태에서 알림만 봐도 대화 내용이 새어나가지 않게 하려는 목적.
    final preview = room?.isSecret == true
        ? _secretPreviewPlaceholder
        : switch (m.type) {
            MessageType.text => m.text ?? '',
            MessageType.image => '사진을 보냈습니다',
            MessageType.file => m.fileName ?? '파일을 보냈습니다',
            MessageType.sticker =>
              '${findStickerById(m.text ?? '')?.emoji ?? ''} 이모티콘을 보냈습니다',
            MessageType.system => '',
            MessageType.comment =>
              '', // 실시간 message:new로는 절대 안 옴(댓글은 클라이언트 전용 합성 타입).
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
      senderName: m.senderName,
      conversationTitle: roomTag,
      avatarType: sender?.avatarType ?? 'initial',
      avatarEmoji: sender?.avatarEmoji,
      avatarColor: sender?.avatarColor,
      avatarUrl: sender?.avatarUrl != null
          ? resolveUrl(sender!.avatarUrl!)
          : null,
      isSecret: room?.isSecret == true,
    );
  }

  /// 새 댓글이 소켓으로 도착했을 때 알림 표시 여부와 방 목록의 안읽음 뱃지 증가를 함께
  /// 처리한다(_handleIncomingMessage와 동일한 규칙 — 내가 단 댓글이거나 지금 보고 있는
  /// 방이면 둘 다 건너뛴다).
  void _handleIncomingComment(Comment c) {
    final isViewingNow = c.roomId == _activeRoomId && appInForeground;
    if (c.senderId == userId || isViewingNow) return;

    final match = rooms.where((r) => r.id == c.roomId);
    if (match.isNotEmpty) {
      match.first.unreadCount++;
      notifyListeners();
    }

    final room = match.isEmpty ? null : match.first;
    // 알림 끄기는 안읽음 뱃지(이미 위에서 증가시켰다)는 그대로 두고, 알림(배너/토스트)만 막는다.
    if (room?.muted == true) return;
    final roomTag = switch (room?.type) {
      null => null,
      RoomType.dm => '1:1',
      RoomType.group => room!.name ?? '그룹채팅',
      RoomType.topic => room!.displayName(userId ?? ''),
    };
    final preview = room?.isSecret == true
        ? _secretPreviewPlaceholder
        : switch (c.type) {
            MessageType.text => c.text ?? '',
            MessageType.image => '사진을 보냈습니다',
            MessageType.file => c.fileName ?? '파일을 보냈습니다',
            MessageType.sticker =>
              '${findStickerById(c.text ?? '')?.emoji ?? ''} 이모티콘을 보냈습니다',
            MessageType.system || MessageType.comment => '', // 댓글엔 나올 수 없는 타입.
          };

    AppUser? sender;
    if (room != null) {
      for (final member in room.members) {
        if (member.id == c.senderId) {
          sender = member;
          break;
        }
      }
    }

    final tag = roomTag != null ? '$roomTag·댓글' : '댓글';
    notifications.showMessage(
      title: '${c.senderName} [$tag]',
      body: preview,
      roomId: c.roomId,
      senderName: c.senderName,
      conversationTitle: tag,
      avatarType: sender?.avatarType ?? 'initial',
      avatarEmoji: sender?.avatarEmoji,
      avatarColor: sender?.avatarColor,
      avatarUrl: sender?.avatarUrl != null
          ? resolveUrl(sender!.avatarUrl!)
          : null,
      isSecret: room?.isSecret == true,
    );
  }

  void _upsertRoom(Room incoming) {
    final i = rooms.indexWhere((r) => r.id == incoming.id);
    if (i >= 0) {
      // 브로드캐스트/REST 응답에는 이 사람 기준 안읽음 수·즐겨찾기가 없거나 낡은 값일 수
      // 있으니(예: room:created는 requesterId 없이 만들어져 둘 다 비어있다), 로컬에서
      // 추적 중이던 값을 유지한다.
      incoming.unreadCount = rooms[i].unreadCount;
      incoming.favorite = rooms[i].favorite;
      incoming.muted = rooms[i].muted;
      incoming.lastActivityAt = rooms[i].lastActivityAt;
      incoming.lastMessagePreview = rooms[i].lastMessagePreview;
      rooms[i] = incoming;
    } else {
      rooms.add(incoming);
    }
    notifyListeners();
    unawaited(ensurePendingSecretInvite(incoming.id));
  }

  /// 즐겨찾기를 켜거나 끈다. 화면 반응성을 위해 먼저 로컬 값을 바꾸고, 서버 요청이 실패하면
  /// 되돌린다(room:favorite 브로드캐스트로 다른 기기도 같이 갱신됨).
  Future<void> toggleFavorite(Room room) async {
    final next = !room.favorite;
    room.favorite = next;
    notifyListeners();
    try {
      await api!.setFavorite(room.id, next);
    } catch (_) {
      room.favorite = !next;
      notifyListeners();
    }
  }

  /// 알림 끄기를 켜거나 끈다(toggleFavorite와 동일한 낙관적 갱신 패턴).
  Future<void> toggleMuted(Room room) async {
    final next = !room.muted;
    room.muted = next;
    notifyListeners();
    try {
      await api!.setMuted(room.id, next);
    } catch (_) {
      room.muted = !next;
      notifyListeners();
    }
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
    return _controllers.putIfAbsent(
      room.id,
      () => RoomChatController(this, room),
    );
  }

  Future<Room> createTopic({
    required String name,
    String? description,
    bool isPublic = true,
  }) async {
    final room = await api!.createTopic(
      name: name,
      description: description,
      isPublic: isPublic,
    );
    _upsertRoom(room);
    return room;
  }

  Future<Room> createGroup({
    String? name,
    required List<String> memberIds,
  }) async {
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

  Future<void> updateProfile({
    String? name,
    String? email,
    String? currentPassword,
  }) async {
    final me = await api!.updateProfile(
      name: name,
      email: email,
      currentPassword: currentPassword,
    );
    this.name = me.name;
    this.email = me.email;
    notifyListeners();
    if (email != null) _showToast('이메일이 변경되었습니다.');
  }

  /// 회원 탈퇴. 서버가 세션/토큰을 이미 폐기해두므로, 성공하면 그냥 로그아웃과 같은
  /// 방식으로 로컬 상태를 정리한다. 비밀번호가 틀리면 여기서 던져서 다이얼로그가 잡는다.
  Future<void> withdraw(String password) async {
    await api!.withdraw(password);
    await logout();
  }

  /// 비밀번호 변경. 다른 기기는 서버가 강제로 끊지만, 이 기기는 응답으로 받은 새 토큰
  /// 쌍으로 로그아웃 없이 그대로 이어간다(소켓도 새 토큰으로 다시 연결).
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final result = await api!.changePassword(
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
    token = result.accessToken;
    refreshToken = result.refreshToken;
    api!.token = token;
    if (_prefs.containsKey(_kToken)) {
      await _prefs.setString(_kToken, token!);
      await _prefs.setString(_kRefreshToken, refreshToken!);
    }
    await chatSocket.connect(
      baseUrl: serverUrl!,
      token: token!,
      deviceId: deviceIdentity?.deviceId,
    );
    _showToast('비밀번호가 변경되었습니다.');
  }

  Future<void> leaveRoom(String roomId, {bool alsoRemoveOther = false}) async {
    final room = _findRoom(roomId);
    await api!.leaveRoom(roomId, alsoRemoveOther: alsoRemoveOther);
    if (room?.isSecret == true) await secretSessionManager?.forgetRoom(roomId);
    rooms.removeWhere((r) => r.id == roomId);
    _controllers.remove(roomId)?.dispose();
    if (_activeRoomId == roomId) _forceClearActiveRoom();
    notifyListeners();
  }

  Future<void> logout() async {
    // 인증이 아직 유효한 동안(아래에서 token을 지우기 전) 이 기기의 FCM 토큰을 서버에서
    // 지워둔다 — 안 그러면 로그아웃한 뒤에도 이 기기로 그 계정 알림이 계속 온다.
    if (Platform.isAndroid && deviceIdentity != null && api != null) {
      try {
        await api!.registerFcmToken(deviceIdentity!.deviceId, null);
      } catch (_) {
        // 오프라인 등으로 실패해도 로그아웃 자체는 계속 진행한다.
      }
    }
    await _fcmTokenRefreshSub?.cancel();
    await _prefs.remove(_kToken);
    await _prefs.remove(_kRefreshToken);
    await _prefs.remove(_kUserId);
    await _prefs.remove(_kUsername);
    await _messageSub?.cancel();
    await _roomSub?.cancel();
    await _readSub?.cancel();
    await _favoriteSub?.cancel();
    await _mutedSub?.cancel();
    await _commentSub?.cancel();
    await _messageEditedSub?.cancel();
    await _messageDeletedSub?.cancel();
    await _commentEditedSub?.cancel();
    await _commentDeletedSub?.cancel();
    await _presenceSub?.cancel();
    await _reconnectSub?.cancel();
    await _authErrorSub?.cancel();
    await _secretInviteSub?.cancel();
    await _secretAcceptedSub?.cancel();
    await _secretRejectedSub?.cancel();
    await _secretLeftSub?.cancel();
    await _secretSettingsSub?.cancel();
    await _secretMessageReadSub?.cancel();
    await _messageExpiredSub?.cancel();
    await _secretRekeyProposeSub?.cancel();
    await _secretRekeyAckSub?.cancel();
    chatSocket.dispose();
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    onlineUserIds.clear();
    secretSessionManager = null;
    pendingSecretInvites.clear();
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
