import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
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
import '../models/team.dart';
import '../widgets/avatar_utils.dart' show automationAvatarColor, colorToHex;
import 'api_client.dart';
import 'app_settings.dart';
import '../models/announcement.dart';
import 'call_controller.dart';
import 'chat_socket.dart';
import 'deep_link_service.dart';
import 'device_identity.dart';
import 'message_preview.dart';
import 'notification_service.dart';
import 'pinned_tls.dart';
import 'fcm_config_cache.dart';
import 'room_chat_controller.dart';
import 'secret_session_manager.dart';
import 'update_socket.dart';

enum AuthStage { loadingConfig, needsServer, needsLogin, ready }

/// 앱 전체 상태: 서버 주소 → 로그인 → 방 목록 순으로 진행됩니다. 인증/방 목록/라우팅만
/// 책임지고, 방 하나의 메시지/전송은 RoomChatController에 맡깁니다.
/// 이전 KiwoomApi 포팅 때와 같은 패턴으로, ChangeNotifier + ListenableBuilder만 씁니다.
class Session extends ChangeNotifier {
  Session({
    required this.notifications,
    required this.settings,
    this.suppressNotifications = false,
  });

  /// "프로젝트" 창처럼 같은 사람의 둘째 Session(별도 창의 별도 소켓 연결)이 떠 있을 때, 그
  /// 창도 메인 창과 똑같이 새 메시지/댓글/공지 소켓 이벤트를 받아버려서 알림이 두 번 뜨는 걸
  /// 막는다 — 로컬 알림만 끄고 나머지(방 목록 갱신 등)는 그대로 동작한다.
  final bool suppressNotifications;

  static const _kServerUrl = 'server_base_url';
  static const _kToken = 'auth_token';
  static const _kRefreshToken = 'auth_refresh_token';
  static const _kUserId = 'auth_user_id';
  static const _kUsername = 'auth_username';
  static const _kRememberedUsername = 'remembered_username';
  static const _kKeepSignedInPref = 'keep_signed_in_pref';
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

  /// 로그인 화면의 "로그인 상태 유지" 체크박스가 마지막으로 어느 값이었는지("아이디
  /// 기억하기"와 같은 방식으로 기기에 저장) — 로그인 자체의 keepSignedIn 인자(토큰을 저장할지
  /// 여부)와는 별개로, 체크박스 자체의 화면 표시값을 다음에 로그인 화면을 열 때도 그대로
  /// 보여주기 위한 값이다. 저장된 적이 없으면(첫 실행 등) 기본값 true.
  bool keepSignedInPref = true;

  String? name;
  String? email;
  String avatarType = 'initial'; // 'initial' | 'character' | 'photo'
  String? avatarEmoji;
  String? avatarColor;
  String? avatarUrl;

  /// 내 계정 등급(GET /users/me). 팀이 아니라 계정에 붙으므로 어느 팀에 있든 같은 값이다 —
  /// 화면은 이 값으로 버튼을 감추고, 실제 차단은 항상 서버가 다시 한다.
  AccountRole accountRole = AccountRole.guest;

  /// 서버 전체 운영자인지(GET /users/me). 삼선 메뉴에 "서버 관리"를 보여줄지 판단하는 데만
  /// 쓰고, 실제 접근 차단은 서버(admin.js)가 매 요청마다 다시 한다.
  bool isServerAdmin = false;

  /// "팀 초대 링크 생성" 메뉴를 보여줄지(GET /users/me) — 서버 설정(팀 초대 링크 생성 권한)에
  /// 달려 있어서 로컬 상태만으로 판단할 수 없다. 실제 생성은 서버(teamInvites.js)가 매
  /// 요청마다 다시 확인한다.
  bool canCreateTeamInviteLink = false;

  /// 서버 설정(프로젝트 생성 권한)이 정하는 "새 프로젝트를 만들 수 있는지" — /users/me가
  /// 서버에서 최종 판정해서 내려준다(projects.js가 실제 생성 때 다시 확인한다).
  bool canCreateProject = false;

  /// 내 프로필 카드의 "팀"/"직책" 표시용(GET /users/me) — 부서·직책 관리 범위가 '계정
  /// 단위'인지 '팀 단위'인지에 따라 [myPosition] 하나만 보거나 [myTeamPositions](팀마다
  /// 다른 값)를 본다. 팀 단위일 때 [myDepartment]/[myPosition]은 항상 null이다.
  String orgScope = 'team';
  String? myDepartment;
  String? myPosition;
  List<TeamPosition> myTeamPositions = [];

  ApiClient? api;
  String? updateAvailableVersion; // 서버가 더 최신 버전을 갖고 있으면 그 버전 문자열(예: "1.0.1").
  // 업데이트 안내 대화상자를 이미 한 번 띄웠는지 — 로그인 화면(LoginScreen)과 로그인 후
  // 화면(HomeScreen) 둘 다 이 값을 확인/갱신해서, 로그인 전에 이미 봤으면 로그인 직후 같은
  // 안내가 또 뜨지 않는다(둘 다 session.updateAvailableVersion이 채워지는 즉시 반응한다).
  bool updateBannerShown = false;
  bool updateDownloading = false;
  // 0~1(다운로드 %). 서버가 Content-Length를 안 주면(드묾) null로 남아 있고, 호출부는
  // 이 경우 불확정(indeterminate) 진행 표시를 해야 한다.
  double? updateDownloadProgress;
  String? updateError; // installUpdate() 실패 시 사용자에게 보여줄 메시지.
  final chatSocket = ChatSocket();

  /// 화상회의(LiveKit) — 서버에 LiveKit이 설정돼 있을 때만 true이고, false면 통화 버튼 자체를
  /// 감춘다(server/src/calls.js의 /calls/config). 지금 진행 중인 통화(callStates)는 방마다
  /// "통화 중" 표시와 수신 화면 판단에 쓴다.
  bool callsEnabled = false;
  final Map<String, CallState> callStates = {};

  /// 내가 아직 받지 않은(참가자 목록에 내가 없는) 통화가 걸려온 방. 수신 화면을 띄우는 신호.
  String? incomingCallRoomId;

  late final callController = CallController(() => api!);
  final _updateSocket = UpdateSocket();
  StreamSubscription<UpdateAvailableEvent>? _updateSub;

  /// 소켓 알림을 놓쳤을 때를 대비해 켜져 있는 동안 주기적으로 버전을 다시 확인하는 타이머.
  Timer? _updateRecheckTimer;
  final NotificationService notifications;
  final AppSettings settings;

  /// 내가 속한 모든 방 — 지금 보고 있는 팀뿐 아니라 **다른 팀 방까지 전부** 들고 있다.
  /// 다른 팀에서 온 메시지도 실시간으로 받아서 안읽음/알림에 반영해야 하기 때문이고
  /// (소켓도 팀과 무관하게 내 모든 방에 join한다, 서버 socket.js 참고), 화면에 보여줄 때만
  /// 각 목록 UI가 currentTeam 기준으로 걸러낸다.
  final List<Room> rooms = [];

  /// 내가 속한 팀 목록(각 팀에서의 내 등급 포함). 로그인/앱 시작 직후 팀 선택 화면이 이걸 그린다.
  final List<Team> teams = [];

  /// "알림 센터"(desktop_home_screen.dart)에 보여줄 대상 — 안 읽은 메시지가 있는 방 전부.
  /// 지금 보고 있는 팀도 포함한다(여러 팀에 걸친 안읽음을 한 번에 모아 보는 게 목적이라
  /// currentTeam으로 거르지 않는다). 뮤트/숨김 둘 다 "목록 화면에 안 보이게 해달라"는
  /// 뜻일 뿐 "안 읽었다는 사실 자체를 숨겨달라"는 뜻은 아니므로 거르지 않는다 — 숨긴
  /// DM이라도 상대가 새로 보내면 안읽음이 생기고, 그건 여기서 꼭 보여야 한다.
  List<Room> get unreadRooms =>
      rooms.where((r) => r.unreadCount > 0 || r.hasUnreadAnnouncement).toList();

  /// 지금 들어가 있는 팀. null이면 아직 팀을 안 골랐다는 뜻이라 팀 선택 화면이 뜬다
  /// (home_screen.dart) — 로그아웃 후 로그인하거나 앱을 새로 켰을 때가 그 경우다.
  Team? currentTeam;

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
  StreamSubscription? _renamedSub;
  StreamSubscription? _projectNotifSub;
  StreamSubscription? _projectNotifSyncSub;

  /// 프로젝트 알림함의 안 읽은 개수 — 툴바 "프로젝트" 버튼의 배지와 프로젝트 창 사이드바가 쓴다.
  int projectUnread = 0;
  StreamSubscription? _hiddenSub;
  StreamSubscription? _teamSub;
  StreamSubscription? _teamLeftSub;
  StreamSubscription? _commentSub;
  StreamSubscription? _messageEditedSub;
  StreamSubscription? _messageLinkPreviewSub;
  StreamSubscription? _messageDeletedSub;
  StreamSubscription? _commentEditedSub;
  StreamSubscription? _commentDeletedSub;
  StreamSubscription? _presenceSub;
  StreamSubscription<CallState>? _callStateSub;
  StreamSubscription<Announcement>? _announcementSub;
  StreamSubscription<Announcement>? _announcementUpdatedSub;
  StreamSubscription<AnnouncementRemovedEvent>? _announcementDeletedSub;
  StreamSubscription<AnnouncementRemovedEvent>? _announcementUnpinnedSub;
  StreamSubscription<AnnouncementReadEvent>? _announcementReadSub;
  StreamSubscription? _reconnectSub;
  StreamSubscription? _authErrorSub;
  StreamSubscription? _roleUpdatedSub;
  StreamSubscription? _orgUpdatedSub;
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

  PairRequest? _pendingPairRequest;

  /// 초대 링크(tangotalk://pair)로 앱이 열리며 받은 서버 주소/코드. ServerSetupScreen과
  /// 로그인 화면의 "서버 주소 변경" 다이얼로그가 이걸 보고 입력칸을 미리 채운다.
  PairRequest? consumePendingPairRequest() {
    final req = _pendingPairRequest;
    _pendingPairRequest = null;
    return req;
  }

  void setPendingPairRequest(PairRequest request) {
    _pendingPairRequest = request;
    // consumePendingPairRequest()는 서버 주소/코드 입력칸을 채우는 화면(ServerSetupScreen 등)
    // 딱 한 번만 소비하고 지워버린다 — 그런데 이 code가 "팀 초대 링크" 토큰이었을 수도 있고,
    // 그건 한참 뒤(회원가입 폼 제출 시점)에야 쓰인다. 그래서 따로, 더 오래 남겨둔다 — 서버가
    // 어차피 팀 초대 링크가 아니면 조용히 무시하므로 매번 값을 실어 보내도 안전하다.
    pendingTeamInviteToken = request.code;
    notifyListeners();
  }

  /// 딥링크로 받은 code — 회원가입 시 함께 보내서 "팀 초대 링크"였다면 팀 자동 합류+등급
  /// 부여를 받는다(server/src/auth.js가 유효하지 않으면 조용히 무시). LoginScreen의 회원가입
  /// 제출이 성공하면 지운다(consumePendingTeamInviteToken).
  String? pendingTeamInviteToken;

  String? consumePendingTeamInviteToken() {
    final token = pendingTeamInviteToken;
    pendingTeamInviteToken = null;
    return token;
  }

  void requestOpenRoom(Room room) {
    // 다른 팀의 방을 열어달라는 요청(예: 다른 팀에서 온 메시지 알림을 눌렀을 때)이면
    // 그 팀으로 먼저 전환한다 — 안 그러면 지금 팀 화면에 없는 방을 열려다 아무 일도 안 난다.
    if (room.teamId != currentTeam?.id) {
      final matches = teams.where((t) => t.id == room.teamId);
      if (matches.isNotEmpty) currentTeam = matches.first;
    }
    _pendingOpenRoom = room;
    notifyListeners();
  }

  Future<void> init() async {
    _listenForLiveUpdates();
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
    keepSignedInPref = _prefs.getBool(_kKeepSignedInPref) ?? true;

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
      unawaited(_updateSocket.connect(serverUrl!));
      if (token == null) {
        stage = AuthStage.needsLogin;
      } else {
        stage = AuthStage.ready;
        await _enterApp();
      }
    }
    notifyListeners();
  }

  /// "프로젝트" 창(project_window.dart)처럼, 메인 창이 이미 로그인해둔 상태를 그대로
  /// 이어받아 새 창의 Session을 세우고 싶을 때 쓴다. init()과 달리 SharedPreferences에서
  /// 토큰을 읽지 않는다 — "로그인 상태 유지"를 꺼둔 사용자는 토큰이 아예 저장되지 않으므로
  /// (_auth 참고), 서브 창이 그 값을 디스크에서 복원할 방법이 없다. 대신 메인 창의 살아있는
  /// Session이 들고 있는 값을 그대로 넘겨받는다(openProjectWindow가 창 생성 인자로 전달).
  Future<void> restoreFromCredentials({
    required String serverUrl,
    required String token,
    String? refreshToken,
    String? userId,
    String? username,
  }) async {
    _listenForLiveUpdates();
    _prefs = await SharedPreferences.getInstance();
    _persistForegroundState();
    this.serverUrl = serverUrl;
    this.token = token;
    this.refreshToken = refreshToken;
    this.userId = userId;
    this.username = username;
    keepSignedInPref = _prefs.getBool(_kKeepSignedInPref) ?? true;
    api = ApiClient(
      baseUrl: serverUrl,
      token: token,
      onUnauthorized: _tryRefreshAndApply,
      httpClient: await PinnedTls.httpClient(),
    );
    unawaited(_checkForUpdate());
    unawaited(_updateSocket.connect(serverUrl));
    stage = AuthStage.ready;
    await _enterApp();
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
    unawaited(_updateSocket.connect(serverUrl!));
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

  /// 앱을 쓰는 도중 서버가 새 버전을 배포하면(_updateSocket, server/src/version.js의
  /// /updates 네임스페이스) 재시작 없이 상단 알약을 띄운다. init()에서 딱 한 번만 구독한다.
  ///
  /// updateBannerShown을 여기서 미리 true로 찍어두는 이유: 이 필드는 원래 "시작 시 뜨는
  /// 자동 설치 모달을 이미 보여줬는지"를 기억하는 용도라(home_screen.dart/login_screen.dart의
  /// _maybeShowUpdateBanner 참고, updateAvailableVersion이 채워지고 이 값이 false일 때만
  /// 모달을 연다), 아무 처리도 안 하면 대화 중에도 모달이 불쑥 뜬다. 이 경로에서는 처음부터
  /// "이미 보여준 것"으로 표시해서 모달은 건너뛰고 UpdateBanner(알약)만 뜨게 한다.
  void _listenForLiveUpdates() {
    // init()과 restoreFromCredentials()가 둘 다 부르므로 중복 구독을 막는다.
    _updateSub?.cancel();
    _updateSub = _updateSocket.updates.listen((e) async {
      final info = await PackageInfo.fromPlatform();
      if (_isNewerVersion(e.version, info.version)) {
        updateAvailableVersion = e.version;
        updateBannerShown = true;
        notifyListeners();
      }
    });
    // 소켓 알림은 배포되는 그 순간 붙어 있는 앱에만 간다. 그때 PC가 절전이었거나 네트워크가
    // 끊겨 있었거나, 서버가 그 뒤 재시작됐거나, 앱을 켤 때 서버가 잠깐 꺼져 있어서 소켓이
    // 아예 못 붙은 경우엔 알약이 영영 안 뜬다 — 그래서 켜져 있는 동안 주기적으로도 확인한다
    // (서버도 이제 연결될 때마다 현재 버전을 알려주므로, 이건 그게 안 되는 예전 서버까지
    // 감싸는 보조 수단이다).
    _updateRecheckTimer?.cancel();
    _updateRecheckTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      if (updateAvailableVersion == null) unawaited(_checkForUpdate());
    });
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
      if (Platform.isWindows) {
        // OpenFile(Windows 구현)은 문서 파일 위주로 검증돼 있어서 설치 프로그램(.exe)에는
        // 조용히 실패하는 경우가 있었다 — 실패해도 예외를 던지지 않아 "설치하기"를 눌러도
        // 아무 반응 없이 대화상자만 닫히는 버그로 나타났다. 설치 파일 실행은 Process.start로
        // 직접 하는 게 훨씬 확실하다(탐색기에서 더블클릭하는 것과 동일 — UAC 상승도 그대로 뜬다).
        //
        // /SILENT(+/SUPPRESSMSGBOXES)로 띄운다 — "지금 설치"를 이미 눌러 동의한 상태라
        // 마법사 선택 화면이나 "실행 중인 앱을 종료할까요?" 확인창은 또 띄울 필요가 없지만,
        // 설치가 진행 중인지는 보여야 해서 /VERYSILENT(진행률 창까지 숨김)가 아니라 /SILENT
        // (진행률 창만 표시)를 쓴다. 일반
        // 더블클릭 설치(초대 링크 등)는 여전히 인자 없이 실행되어 기존 대화형 방식 그대로다
        // (messenger.iss의 InitializeSetup이 WizardSilent()로 이 경로만 확인창을 건너뛰고,
        // 설치 후 재실행도 이 모드에서만 자동으로 된다 — Check: IsSilentMode 항목 참고).
        await Process.start(file.path, [
          '/SILENT',
          '/SUPPRESSMSGBOXES',
          '/NORESTART',
        ], mode: ProcessStartMode.detached);
      } else {
        final result = await OpenFile.open(file.path);
        if (result.type != ResultType.done) {
          throw '설치 파일을 열 수 없습니다: ${result.message}';
        }
      }
    } catch (e) {
      updateError = '업데이트 설치 실패: $e';
    } finally {
      updateDownloading = false;
      notifyListeners();
    }
  }

  /// "대화 내보내기" — 방의 대화 내용을 엑셀(.xlsx)로 받아 기기에 저장한다. 다운로드 폴더를
  /// 설정해뒀으면 거기에, 아니면 임시 폴더에 저장한다(attachment_widgets.dart의 일반 파일
  /// 저장과 같은 규칙). 비밀 대화는 애초에 호출부(room_options_menu.dart)가 메뉴 자체를
  /// 감춰서 여기까지 안 오지만, 서버도 다시 막는다(rooms.js). 저장된 파일의 전체 경로를
  /// 돌려준다(호출부가 바로 열 때 씀).
  Future<String> exportRoomChat(
    String roomId, {
    DateTime? since,
    DateTime? until,
    required String fileName,
  }) async {
    if (api == null) throw const ApiException('연결되어 있지 않습니다.');
    final response = await api!.exportRoomChat(
      roomId,
      since: since,
      until: until,
    );
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      var message = '내보내기에 실패했습니다.';
      try {
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        message = decoded['error'] as String? ?? message;
      } catch (_) {
        // 서버가 JSON이 아닌 응답을 보냈으면(프록시 에러 페이지 등) 기본 문구를 그대로 쓴다.
      }
      throw ApiException(message);
    }
    final bytes = await response.stream.toBytes();
    final dirPath = settings.downloadFolder.isNotEmpty
        ? settings.downloadFolder
        : (await getTemporaryDirectory()).path;
    final file = File('$dirPath${Platform.pathSeparator}$fileName');
    await file.writeAsBytes(bytes);
    return file.path;
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
  }) async {
    // 실패하면(아이디 중복 등) 고쳐서 다시 시도할 수 있어야 하므로, 성공했을 때만 지운다 —
    // 여기서 바로 consumePendingTeamInviteToken()으로 지워버리면 재시도 때 팀 초대 맥락이
    // 사라진다.
    final teamInviteToken = pendingTeamInviteToken;
    final ok = await _auth(
      () => api!.register(
        u,
        p,
        email,
        name,
        securityQuestion: securityQuestion,
        securityAnswer: securityAnswer,
        teamInviteToken: teamInviteToken,
      ),
      keepSignedIn: keepSignedIn,
    );
    if (ok) pendingTeamInviteToken = null;
    return ok;
  }

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

  Future<void> setKeepSignedInPref(bool value) async {
    keepSignedInPref = value;
    await _prefs.setBool(_kKeepSignedInPref, value);
  }

  /// 내 팀 목록과, 그 팀들의 방을 전부 불러온다. 방을 팀별로 따로 요청하는 이유는 서버가
  /// 팀 범위를 강제하기 때문이고(GET /rooms?teamId=), 전부 모아두는 이유는 다른 팀에서 온
  /// 메시지도 안읽음/알림에 반영해야 하기 때문이다(rooms 필드 주석 참고).
  Future<void> _loadTeamsAndRooms() async {
    final myTeams = await api!.fetchTeams();
    teams
      ..clear()
      ..addAll(myTeams);

    final loaded = <Room>[];
    for (final team in myTeams) {
      loaded.addAll(await api!.fetchRooms(team.id));
    }
    rooms
      ..clear()
      ..addAll(loaded);
    for (final room in loaded) {
      unawaited(ensurePendingSecretInvite(room.id));
    }

    // 팀 목록이 바뀌어서(다른 기기에서 나가졌다거나) 지금 보던 팀이 없어졌으면 팀 선택으로.
    final current = currentTeam;
    if (current != null && !myTeams.any((t) => t.id == current.id)) {
      currentTeam = null;
    }
    notifyListeners();
  }

  /// 팀 선택 화면에서 "팀으로 가기"를 눌렀을 때. 방 목록은 이미 다 받아와 있으므로
  /// (그리고 소켓도 팀과 무관하게 전부 연결돼 있으므로) 보고 있는 팀만 바꾸면 된다.
  void enterTeam(Team team) {
    if (currentTeam?.id == team.id) return;
    currentTeam = team;
    // 팀을 바꾸면 이전 팀에서 열어둔 방/댓글 패널은 더 이상 의미가 없다.
    _forceClearActiveRoom();
    notifyListeners();
  }

  /// 지금 보고 있는 팀에서 내가 무엇을 할 수 있는지 — 화면이 버튼을 감출 때 쓴다.
  /// 계정 등급(accountRole)과 그 팀의 소유자 여부(Team.isOwner)를 합쳐서 판단하며,
  /// 실제 차단은 항상 서버가 다시 하므로(server/src/permissions.js) 여기 값은 UI 힌트일 뿐이다.
  bool get canManageCurrentTeam => currentTeam?.canManage(accountRole) ?? false;
  bool get canCreateRooms => accountRole.canCreateRooms;
  // 새 토픽 생성은 팀 설정(topicCreationPolicy)을 따로 보고, 이미 있는 방에 멤버를 추가로
  // 초대하는 건 팀 설정과 무관하게 항상 canCreateRooms와 같다(server/src/rooms.js 참고).
  bool get canCreateTopic =>
      currentTeam?.canCreateTopic(accountRole, userId) ?? false;
  bool get canInviteToRooms => canCreateRooms;
  bool get canModerateContent => canManageCurrentTeam;

  /// 팀 목록 화면처럼 특정 팀을 골라서 판단해야 할 때.
  bool canManageTeam(Team team) => team.canManage(accountRole);

  /// 이 방(토픽)에 공지를 쓸 수 있는지 — 그 방이 속한 팀의 토픽 생성 권한과 같다
  /// (room_options_menu.dart의 "공지" 메뉴). currentTeam이 아니라 room.teamId로 직접
  /// 찾는다 — 다른 팀 방 화면에 있을 수 있는 경로(알림 센터 등)에서도 정확해야 해서다.
  bool canCreateAnnouncementIn(Room room) {
    final team = teams.where((t) => t.id == room.teamId).firstOrNull;
    return team?.canCreateTopic(accountRole, userId) ?? false;
  }

  /// 이 공지의 수정/삭제/내리기/공유 메뉴(삼점 버튼)를 보여줄지 — 요청 사양 그대로 "작성 본인"만
  /// 이다(메시지/댓글처럼 관리자가 남의 글을 지울 수 있는 예외는 여기 없다 — server/src/
  /// announcements.js의 requireOwnAnnouncement와 동일 규칙).
  bool canManageAnnouncement(Announcement announcement) {
    return userId != null && announcement.authorId == userId;
  }

  /// "문의하기" 버튼(chat_input_bar.dart)을 보여줄지 — 평문 1:1 대화방이고, 상대가 그 방이
  /// 속한 팀에서 직책이 정확히 "팀장"일 때만이다(room.members[].position은 rooms.js의
  /// resolveMembers가 이미 그 팀의 orgScope 설정에 맞게 계산해서 보내주므로, 여기서는 값만
  /// 비교하면 된다). 등급(계정 role)과는 무관한 별개 축이다.
  bool canSendInquiryIn(Room room) {
    if (room.type != RoomType.dm || room.isSecret) return false;
    final other = room.members.where((m) => m.id != userId).firstOrNull;
    return other?.position == '팀장';
  }

  /// 초대 링크(설치→가입 링크)를 만들 수 있는지 — 서버 운영자, 계정 등급 관리자, 또는
  /// 어느 팀이든 소유자인 사람(server/src/permissions.js의 canCreateInviteLink와 동일 규칙).
  bool get canCreateInviteLink =>
      isServerAdmin ||
      accountRole == AccountRole.admin ||
      teams.any((t) => t.isOwner);

  /// 프로젝트 알림의 안 읽은 개수를 서버에서 다시 받아온다.
  Future<void> refreshProjectUnread() async {
    try {
      final (_, count) = await api!.fetchProjectNotifications();
      projectUnread = count;
      notifyListeners();
    } catch (_) {
      // 배지 숫자일 뿐이라 실패해도 조용히 넘어간다.
    }
  }

  /// 프로젝트는 정회원 이상만(server/src/projects.js의 게이트와 동일 규칙).
  bool get canUseProjects => isServerAdmin || accountRole != AccountRole.guest;

  /// "조직도" 버튼(팀 목록 화면)을 보여줄지 — 계정 등급이 관리자이거나 서버 운영자만
  /// (server/src/teams.js의 GET /org-chart/teams와 같은 규칙).
  bool get canViewOrgChart => isServerAdmin || accountRole == AccountRole.admin;

  /// 삼선 메뉴의 "메신저 설명서"(README 기반 운영 문서)를 보여줄지 — 관리자 이상(서버 운영자
  /// 또는 계정 등급 관리자). 서버(version.js의 POST /api/help/manual-link)도 같은 규칙으로
  /// 다시 확인한다.
  bool get canViewMessengerManual =>
      isServerAdmin || accountRole == AccountRole.admin;

  /// 팀 선택 화면으로 되돌아간다(전환 팝업의 "팀 목록").
  void leaveTeam() {
    if (currentTeam == null) return;
    currentTeam = null;
    _forceClearActiveRoom();
    notifyListeners();
  }

  /// 팀을 새로 만든다 — 만든 사람이 그 팀의 소유자가 된다(서버 teams.js).
  Future<Team> createTeam({
    required String name,
    String? iconEmoji,
    String? iconColor,
    String? iconUrl,
    TopicCreationPolicy? topicCreationPolicy,
    bool? messageEditDeleteEnabled,
    int? messageEditDeleteWindowSeconds,
  }) async {
    final team = await api!.createTeam(
      name: name,
      iconEmoji: iconEmoji,
      iconColor: iconColor,
      iconUrl: iconUrl,
      topicCreationPolicy: topicCreationPolicy?.wire,
      messageEditDeleteEnabled: messageEditDeleteEnabled,
      messageEditDeleteWindowSeconds: messageEditDeleteWindowSeconds,
    );
    teams.add(team);
    notifyListeners();
    return team;
  }

  /// 팀 이름/아이콘 변경(소유자·관리자만 — 서버가 다시 검사한다).
  /// [topicCreatorIds]는 topicCreationPolicy를 designated로 정할 때만 함께 보낸다.
  Future<void> updateTeam(
    Team team, {
    String? name,
    String? iconEmoji,
    String? iconColor,
    String? iconUrl,
    TopicCreationPolicy? topicCreationPolicy,
    List<String>? topicCreatorIds,
    bool? messageEditDeleteEnabled,
    int? messageEditDeleteWindowSeconds,
  }) async {
    final updated = await api!.updateTeam(
      team.id,
      name: name,
      iconEmoji: iconEmoji,
      iconColor: iconColor,
      iconUrl: iconUrl,
      topicCreationPolicy: topicCreationPolicy?.wire,
      topicCreatorIds: topicCreatorIds,
      messageEditDeleteEnabled: messageEditDeleteEnabled,
      messageEditDeleteWindowSeconds: messageEditDeleteWindowSeconds,
    );
    team.name = updated.name;
    team.iconEmoji = updated.iconEmoji;
    team.iconColor = updated.iconColor;
    team.iconUrl = updated.iconUrl;
    team.topicCreationPolicy = updated.topicCreationPolicy;
    team.topicCreatorIds = updated.topicCreatorIds;
    team.messageEditDeleteEnabled = updated.messageEditDeleteEnabled;
    team.messageEditDeleteWindowSeconds =
        updated.messageEditDeleteWindowSeconds;
    notifyListeners();
  }

  /// 팀 삭제(소유자만) — 그 팀의 방/메시지가 전부 사라진다. 서버가 team:left를 보내주므로
  /// 목록에서 빼는 일은 그 구독(_teamLeftSub)이 처리한다.
  Future<void> deleteTeam(Team team) async {
    await api!.deleteTeam(team.id, team.name);
  }

  /// 소유권 이양(소유자만) — 넘기고 나면 나는 더 이상 그 팀의 소유자가 아니다.
  Future<List<AppUser>> transferTeamOwnership(Team team, String userId) async {
    final members = await api!.transferTeamOwnership(team.id, userId);
    team.isOwner = false;
    notifyListeners();
    return members;
  }

  /// 팀원의 부서/직책 변경(그 팀을 관리할 수 있는 사람만). 등급은 여기서 못 바꾼다.
  Future<List<AppUser>> updateTeamMember(
    Team team,
    String userId, {
    String? department,
    String? position,
  }) async {
    final members = await api!.updateTeamMember(
      team.id,
      userId,
      department: department,
      position: position,
    );
    notifyListeners();
    return members;
  }

  /// 팀 설정 화면용 — 아직 팀에 들어가지 않은 상태(팀 선택 화면)에서도 써야 해서
  /// currentTeam이 아니라 팀을 명시적으로 받는다.
  Future<List<AppUser>> fetchMembersOfTeam(String teamId) =>
      api!.fetchTeamMembers(teamId);

  /// 팀에 넣을 수 있는 사람들 = 서버에 가입한 전체 계정. 회원가입만 하면 아직 어느 팀에도
  /// 속하지 않으므로, 소유자·관리자가 여기서 골라 팀에 가입시켜 준다.
  Future<List<AppUser>> fetchAllUsers() => api!.fetchUsers();

  /// 조직도(팀 탭)용 — 서버 전체 팀 + 각 팀의 멤버 id 목록.
  Future<List<OrgChartTeam>> fetchOrgChartTeams() => api!.fetchOrgChartTeams();

  /// 프로필 카드 "팀" 항목용 — 그 사람이 속한 팀 목록(노출 범위는 서버가 정한다).
  Future<List<Team>> fetchUserTeams(String userId) =>
      api!.fetchUserTeams(userId);

  /// 관리자 콘솔 "운영 현황"의 직책 목록 관리(서버 운영자 전용, 서버가 매번 다시 확인한다).
  Future<List<PositionOption>> fetchPositionOptions() =>
      api!.fetchPositionOptions();

  /// 팀·직책 관리 설정(orgScope)을 바꾼 직후 호출 — orgScope와 내 부서·직책 표시값은 로그인 때
  /// fetchMe로만 채워지므로, 다시 받아오지 않으면 재로그인 전까지 예전 설정으로 동작한다.
  Future<void> refreshOrgInfo() async {
    final me = await api!.fetchMe();
    orgScope = me.orgScope;
    myDepartment = me.department;
    myPosition = me.position;
    myTeamPositions = me.teamPositions;
    notifyListeners();
  }

  /// 직책 목록(서열순, 서버 운영자가 아니어도 누구나 호출 가능) — "팀 초대 링크 만들기"의
  /// "부여할 직책"이 쓴다.
  Future<List<PositionOption>> fetchPublicPositionOptions() =>
      api!.fetchPublicPositionOptions();
  Future<PositionOption> createPositionOption(String label) =>
      api!.createPositionOption(label);
  Future<void> deletePositionOption(String id) => api!.deletePositionOption(id);
  Future<List<PositionOption>> reorderPositionOptions(List<String> ids) =>
      api!.reorderPositionOptions(ids);
  Future<List<PositionOption>> toggleDefaultPositionOption(String id) =>
      api!.toggleDefaultPositionOption(id);

  /// 팀에 넣기 — 등급은 각자 계정에 이미 붙어 있는 것을 그대로 쓴다(여기서 정하지 않는다).
  Future<List<AppUser>> addTeamMembers(Team team, List<String> userIds) async {
    final members = await api!.addTeamMembers(team.id, userIds);
    team.memberCount = members.length;
    notifyListeners();
    return members;
  }

  Future<List<AppUser>> removeTeamMember(Team team, String userId) async {
    final members = await api!.removeTeamMember(team.id, userId);
    team.memberCount = members.length;
    notifyListeners();
    return members;
  }

  Future<void> _enterApp() async {
    try {
      // 팀 먼저 — 방은 팀 안에만 있으므로, 내가 속한 팀들을 받아온 뒤 그 팀들의 방을 전부
      // 불러온다(다른 팀 메시지도 실시간으로 받아야 해서 화면에 보이는 팀 것만 들고 있으면
      // 안 된다, rooms 필드 주석 참고). 어느 팀에 들어갈지는 사용자가 팀 선택 화면에서
      // 고르므로 여기서 currentTeam을 정하지는 않는다.
      await _loadTeamsAndRooms();
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
      accountRole = accountRoleFromWire(me.role);
      isServerAdmin = me.isServerAdmin;
      canCreateTeamInviteLink = me.canCreateTeamInviteLink;
      canCreateProject = me.canCreateProject;
      orgScope = me.orgScope;
      myDepartment = me.department;
      myPosition = me.position;
      myTeamPositions = me.teamPositions;
    } catch (_) {
      // 프로필/아바타는 부가 정보라 실패해도 조용히 무시한다.
    }
    if (canUseProjects) unawaited(refreshProjectUnread());

    // 위 fetchRooms/fetchMe 도중 401 → 리프레시 시도 → refreshToken마저 무효라 강제
    // 로그아웃(_forceLogout)됐을 수 있다(예: 이 토큰이 새 서버 버전 이전에 발급된 옛날
    // 형식이라 애초에 무효인 경우). 그러면 token이 null로 바뀌어 있으니 여기서 멈춘다.
    if (token == null) return;

    deviceIdentity ??= DeviceIdentity();
    await deviceIdentity!.ensureLoaded();
    secretSessionManager = SecretSessionManager(
      api!,
      chatSocket,
      deviceIdentity!,
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
    _messageSub = chatSocket.messages.listen(handleSocketMessage);
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
    _projectNotifSub?.cancel();
    _projectNotifSub = chatSocket.projectNotifications.listen((data) {
      projectUnread =
          (data['unreadCount'] as num?)?.toInt() ?? projectUnread + 1;
      if (!suppressNotifications) {
        notifications.showProjectNotification(
          title: data['title'] as String? ?? '프로젝트',
          body: data['body'] as String? ?? '',
          projectId: data['projectId'] as String? ?? '',
        );
      }
      notifyListeners();
    });
    _projectNotifSyncSub?.cancel();
    _projectNotifSyncSub = chatSocket.projectNotificationSync.listen((count) {
      projectUnread = count;
      notifyListeners();
    });
    _renamedSub?.cancel();
    _renamedSub = chatSocket.renamedEvents.listen((e) {
      final match = rooms.where((r) => r.id == e.roomId);
      if (match.isEmpty) return;
      match.first.customName = e.customName;
      notifyListeners();
    });
    _hiddenSub?.cancel();
    _hiddenSub = chatSocket.hiddenEvents.listen((e) {
      final match = rooms.where((r) => r.id == e.roomId);
      if (match.isEmpty) return;
      match.first.hidden = e.hidden;
      notifyListeners();
    });
    _teamSub?.cancel();
    _teamSub = chatSocket.teamEvents.listen((team) async {
      final i = teams.indexWhere((t) => t.id == team.id);
      if (i >= 0) {
        // 이름/아이콘 변경 — 지금 보고 있는 팀이면 상단 전환 버튼 표시도 같이 갱신된다.
        teams[i].name = team.name;
        teams[i].iconEmoji = team.iconEmoji;
        teams[i].iconColor = team.iconColor;
        teams[i].iconUrl = team.iconUrl;
        teams[i].topicCreationPolicy = team.topicCreationPolicy;
        teams[i].topicCreatorIds = team.topicCreatorIds;
        teams[i].messageEditDeleteEnabled = team.messageEditDeleteEnabled;
        teams[i].messageEditDeleteWindowSeconds =
            team.messageEditDeleteWindowSeconds;
        // 소유권이 바뀌면 화면의 버튼들도 바로 따라온다(등급은 계정 단위라 여기 없음).
        teams[i].isOwner = team.isOwner;
        teams[i].memberCount = team.memberCount;
        notifyListeners();
        return;
      }
      // 새로 들어간 팀 — 그 팀 방까지 받아와야 목록/알림이 정상 동작한다.
      teams.add(team);
      try {
        rooms.addAll(await api!.fetchRooms(team.id));
      } catch (_) {
        // 방 목록은 다음 재연결(_resyncAfterReconnect)에서 다시 맞춰진다.
      }
      notifyListeners();
    });
    _teamLeftSub?.cancel();
    _teamLeftSub = chatSocket.teamLeftEvents.listen((e) {
      teams.removeWhere((t) => t.id == e.teamId);
      // 그 팀 방들도 같이 정리한다(더 이상 볼 수 없다).
      for (final room in rooms.where((r) => r.teamId == e.teamId).toList()) {
        _controllers.remove(room.id)?.dispose();
      }
      rooms.removeWhere((r) => r.teamId == e.teamId);
      if (currentTeam?.id == e.teamId) {
        currentTeam = null; // 보고 있던 팀에서 빠졌으면 팀 선택 화면으로 돌아간다.
        _forceClearActiveRoom();
        final where = e.teamName == null ? '팀' : "'${e.teamName}' 팀";
        _showToast(e.deleted ? '$where이 삭제되었습니다.' : '$where에서 나가졌습니다.');
      }
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
    _messageLinkPreviewSub?.cancel();
    _messageLinkPreviewSub = chatSocket.messageLinkPreview.listen((m) {
      // 링크 미리보기는 비밀 대화(서버가 내용을 못 보는 방)에는 애초에 안 만들어지므로
      // 복호화가 필요 없다 — message:edited와 달리 바로 적용한다.
      _controllers[m.roomId]?.applyLinkPreview(m);
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
    _callStateSub?.cancel();
    _callStateSub = chatSocket.callStates.listen(_applyCallState);
    _announcementSub?.cancel();
    _announcementSub = chatSocket.announcements.listen(
      _handleIncomingAnnouncement,
    );
    _announcementUpdatedSub?.cancel();
    _announcementUpdatedSub = chatSocket.announcementUpdated.listen((a) {
      // 댓글 개수는 이 이벤트에 항상 0으로 온다(서버가 다시 세지 않음) — 배너에 반영된 글이면
      // text/editedAt만 갱신하고 나머지(pinned/commentCount)는 그대로 둔다.
      final match = rooms.where((r) => r.id == a.roomId);
      if (match.isEmpty) return;
      final current = match.first.latestAnnouncement;
      if (current == null || current.id != a.id) return;
      current.text = a.text;
      current.editedAt = a.editedAt;
      notifyListeners();
    });
    _announcementDeletedSub?.cancel();
    _announcementDeletedSub = chatSocket.announcementDeleted.listen((e) {
      final match = rooms.where((r) => r.id == e.roomId);
      if (match.isEmpty) return;
      if (match.first.latestAnnouncement?.id == e.id) {
        match.first.latestAnnouncement = null;
        match.first.hasUnreadAnnouncement = false;
        match.first.unreadAnnouncementCount = 0;
        notifyListeners();
      }
    });
    _announcementUnpinnedSub?.cancel();
    _announcementUnpinnedSub = chatSocket.announcementUnpinned.listen((e) {
      final match = rooms.where((r) => r.id == e.roomId);
      if (match.isEmpty) return;
      if (match.first.latestAnnouncement?.id == e.id) {
        match.first.latestAnnouncement = null;
        match.first.hasUnreadAnnouncement = false;
        match.first.unreadAnnouncementCount = 0;
        notifyListeners();
      }
    });
    _announcementReadSub?.cancel();
    _announcementReadSub = chatSocket.announcementRead.listen((e) {
      // user: 방에만 오므로 항상 "나"의 다른 기기에서 읽었다는 뜻이다(markAnnouncementsRead 참고).
      final match = rooms.where((r) => r.id == e.roomId);
      if (match.isEmpty) return;
      match.first.hasUnreadAnnouncement = false;
      match.first.unreadAnnouncementCount = 0;
      notifyListeners();
    });
    unawaited(_loadCallsConfig());
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
      if (suppressNotifications) return;
      final teamTag = _teamTagFor(room);
      final teamBadge = teamTag == null ? '' : ' [$teamTag]';
      notifications.showMessage(
        title: initiator != null
            ? '${initiator.name} [비밀대화 요청]$teamBadge'
            : '비밀대화 요청$teamBadge',
        body: '비밀 대화(종단간 암호화)를 요청했습니다.',
        roomId: e.roomId,
        senderName: initiator?.name,
        conversationTitle: teamTag == null ? '비밀대화 요청' : '비밀대화 요청 · $teamTag',
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
    _roleUpdatedSub?.cancel();
    _roleUpdatedSub = chatSocket.roleUpdated.listen((_) async {
      // 서버 운영자가 관리자 콘솔에서 내 등급/서버 운영자 여부를 바꿨다는 알림 — 로그아웃
      // 없이 바로 반영되도록 프로필을 다시 받아온다.
      try {
        final me = await api!.fetchMe();
        accountRole = accountRoleFromWire(me.role);
        isServerAdmin = me.isServerAdmin;
        canCreateTeamInviteLink = me.canCreateTeamInviteLink;
        canCreateProject = me.canCreateProject;
        notifyListeners();
      } catch (_) {
        // 실패해도 조용히 무시 — 다음 이벤트/재연결 때 다시 시도됨.
      }
    });
    _orgUpdatedSub?.cancel();
    _orgUpdatedSub = chatSocket.orgUpdated.listen((e) {
      // 관리자 콘솔/팀 설정에서 누군가의 부서·직책을 바꾸면 이 이벤트가 온다 — 그 사람이
      // 멤버로 들어있는 모든 방(토픽/그룹채팅/1:1)의 캐시를 직접 덮어써서, 다시 로그인하지
      // 않아도 채팅방 목록 배지·헤더에 바로 반영되게 한다.
      var changed = false;
      for (final room in rooms) {
        for (final member in room.members) {
          if (member.id != e.userId) continue;
          member.department = e.department;
          member.position = e.position;
          changed = true;
        }
      }
      if (changed) notifyListeners();
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
      if (!await _ensureFirebaseInitialized()) return;
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      final token = await messaging.getToken();
      if (token != null) {
        await api!.registerFcmToken(deviceIdentity!.deviceId, token);
      }

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

  /// FCM 초기화 값을 서버에서 받아와 캐싱하고(fcm_config_cache.dart), 이 프로세스에서 아직
  /// Firebase가 초기화되지 않았으면(캐시가 없어 main()이 건너뛴 경우 — 이 기기에서 처음
  /// 로그인하는 순간) 지금 바로 초기화한다. FirebaseMessaging.onBackgroundMessage 등록은
  /// 여기서 다시 하지 않는다 — 그건 main.dart의 최상위 함수라 여기서 부르면 순환 import가
  /// 생기고, 다음 앱 재시작부터는 이번에 캐싱된 값으로 main()이 정상적으로 등록한다(그 사이
  /// 짧은 틈은 소켓 연결이 대신 커버한다). 관리자가 아직 FCM을 설정하지 않았거나 서버에 못
  /// 닿으면 false.
  Future<bool> _ensureFirebaseInitialized() async {
    if (Firebase.apps.isNotEmpty) return true;
    final config = await api?.fetchFirebaseClientConfig();
    final options = FcmConfigCache.fromValues(
      apiKey: config?['apiKey'],
      appId: config?['appId'],
      projectId: config?['projectId'],
      senderId: config?['messagingSenderId'],
    );
    if (options == null) return false;
    await FcmConfigCache.save(
      _prefs,
      apiKey: config!['apiKey']!,
      appId: config['appId']!,
      projectId: config['projectId']!,
      senderId: config['messagingSenderId']!,
    );
    await Firebase.initializeApp(options: options);
    return true;
  }

  /// 이 서버에서 화상회의를 쓸 수 있는지 확인한다(LiveKit 미설치 서버면 false). 실패해도
  /// 조용히 무시 — 그 경우 통화 버튼이 안 보일 뿐 다른 기능은 그대로다.
  Future<void> _loadCallsConfig() async {
    try {
      final config = await api!.fetchCallsConfig();
      callsEnabled = config.enabled;
      notifyListeners();
    } catch (_) {
      // 다음 로그인 때 다시 확인한다.
    }
  }

  /// 서버가 보내주는 방별 통화 상태(call:state)를 반영하고, 그 결과로 "지금 나에게 걸려온
  /// 통화"가 있는지 판단한다 — 통화가 켜져 있는데 참가자 목록에 내가 없고 내가 건 것도
  /// 아니면 아직 안 받은 통화다. 내가 이미 다른 통화 중이면 벨을 울리지 않는다.
  void _applyCallState(CallState state) {
    if (state.active) {
      callStates[state.roomId] = state;
    } else {
      callStates.remove(state.roomId);
    }

    final iAmIn = state.participantIds.contains(userId);
    if (state.active &&
        !iAmIn &&
        state.startedBy != userId &&
        callController.roomId == null) {
      incomingCallRoomId = state.roomId;
    } else if (incomingCallRoomId == state.roomId && (!state.active || iAmIn)) {
      // 통화가 끝났거나(아무도 안 남음) 내가 다른 기기에서 받았으면 벨을 끈다.
      incomingCallRoomId = null;
    }
    if (!state.active || iAmIn) {
      // 앱이 꺼져 있는 동안 FCM으로 떠 있던 전체화면 통화 알림도 같이 내린다 — 안 그러면
      // 이미 끝난(또는 다른 기기에서 받은) 전화가 잠금화면에 계속 남는다.
      unawaited(notifications.cancelIncomingCall(state.roomId));
    }
    notifyListeners();
  }

  /// 통화를 걸거나(아무도 없으면) 진행 중인 통화에 합류한다. LiveKit 연결에 성공한 뒤에야
  /// 소켓으로 알려서, 연결 실패한 사람이 참가자 목록에 남지 않게 한다.
  Future<void> joinCall(String roomId) async {
    incomingCallRoomId = null;
    notifyListeners();
    final match = rooms.where((r) => r.id == roomId);
    await callController.join(
      roomId,
      roomLabel: match.isEmpty ? null : match.first.displayName(userId ?? ''),
    );
    chatSocket.joinCall(roomId);
    notifyListeners();
  }

  Future<void> leaveCall() async {
    final roomId = callController.roomId;
    await callController.leave();
    if (roomId != null) chatSocket.leaveCall(roomId);
    notifyListeners();
  }

  /// 수신 화면에서 "거절" — 이 기기에서만 벨을 끈다(다른 기기나 통화 자체는 그대로).
  void declineIncomingCall() {
    incomingCallRoomId = null;
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
      // 끊겨 있는 동안 팀에 들어가거나 빠졌을 수도 있으니 팀 목록부터 다시 받는다.
      final freshTeams = await api!.fetchTeams();
      teams
        ..clear()
        ..addAll(freshTeams);
      final current = currentTeam;
      if (current != null) {
        final match = freshTeams.where((t) => t.id == current.id);
        if (match.isEmpty) {
          currentTeam = null; // 그 사이 팀에서 빠졌으면 팀 선택 화면으로.
          _forceClearActiveRoom();
        } else {
          currentTeam = match.first;
        }
      }

      final freshRooms = <Room>[];
      for (final team in freshTeams) {
        freshRooms.addAll(await api!.fetchRooms(team.id));
      }
      final freshIds = freshRooms.map((r) => r.id).toSet();
      for (final fresh in freshRooms) {
        final i = rooms.indexWhere((r) => r.id == fresh.id);
        if (i >= 0) {
          rooms[i] = fresh;
        } else {
          rooms.add(fresh);
        }
      }
      // 더 이상 못 보는 방(팀에서 빠짐 등)은 정리한다.
      rooms.removeWhere((r) => !freshIds.contains(r.id));
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
    final room = await secretSessionManager!.startSecretChat(
      targetUserId,
      _requireTeamId,
    );
    _upsertRoom(room);
    return room;
  }

  /// 조직도에서 비밀 대화를 시작할 때 쓴다 — 아직 팀을 고르지 않은 상태(팀 목록 화면)에서도
  /// 호출할 수 있도록 [teamId](나와 상대가 함께 속한 팀일 필요는 없고, 내가 속한 팀이면 된다)를
  /// 명시적으로 받는다. 성공하면 그 팀으로 들어간다.
  Future<Room> startSecretChatInTeam(String teamId, String targetUserId) async {
    final room = await secretSessionManager!.startSecretChat(
      targetUserId,
      teamId,
    );
    _upsertRoom(room);
    requestOpenRoom(room);
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

  /// 환경설정의 "메시지 내용 미리보기"(AppSettings.messagePreviewMode)에 따라 알림에 실제
  /// 내용을 보여줄지 판단한다. 비밀 대화는 이 설정과 무관하게 항상 가려지므로(호출부에서
  /// room?.isSecret로 따로 체크) 여기서는 신경 쓰지 않는다.
  bool _shouldPreviewFor(Room? room) => switch (settings.messagePreviewMode) {
    MessagePreviewMode.all => true,
    MessagePreviewMode.publicTopicOnly =>
      room?.type == RoomType.topic && room?.isPublic == true,
    MessagePreviewMode.none => false,
  };

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

  /// 소켓의 message:new 하나를 처리한다 — 복호화 → 열린 방에 넣기 → 방 목록 정렬·미리보기 →
  /// 안읽음·알림. 테스트가 소켓 없이 같은 경로를 태울 수 있게 밖으로 열어 둔다.
  @visibleForTesting
  Future<void> handleSocketMessage(Message m) async {
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
  }

  /// 새 메시지가 소켓으로 도착했을 때 알림 표시 여부와 방 목록의 안읽음 뱃지 증가를 함께 처리한다.
  /// 시스템 메시지/내가 보낸 메시지/지금 보고 있는 방이면 둘 다 건너뛴다. 자동화 메시지(보낸
  /// 사람 없는 일반 글)는 누구의 메시지도 아니라서 모두에게 안읽음·알림이 간다.
  void _handleIncomingMessage(Message m) {
    if (m.type == MessageType.system) return;
    final isViewingNow =
        m.roomId == _activeRoomId &&
        appInForeground &&
        _mobileThreadOpenRoomId != m.roomId;
    final isMine = m.senderId != null && m.senderId == userId;
    if (isMine || isViewingNow) return;

    final match = rooms.where((r) => r.id == m.roomId);
    if (match.isNotEmpty) {
      match.first.unreadCount++;
      notifyListeners();
    }

    final room = match.isEmpty ? null : match.first;
    // 알림 끄기는 안읽음 뱃지(이미 위에서 증가시켰다)는 그대로 두고, 알림(배너/토스트)만 막는다.
    if (room?.muted == true) return;
    final teamTag = _teamTagFor(room);
    final roomTag = switch (room?.type) {
      null => null,
      RoomType.dm => '1:1',
      // 이름 없는 그룹채팅은 멤버 이름을 전부 나열하지 않고 "그룹채팅"이라고만 표시한다.
      RoomType.group => room!.name ?? '그룹채팅',
      RoomType.topic => room!.displayName(userId ?? ''),
    };
    // 비밀 대화는 서버가 어차피 내용을 복호화할 수 없어서 서버발 미리보기 자체가 불가능하지만,
    // 클라이언트가 이미 복호화해둔 내용을 알림에 그대로 보여주는 것도 의도적으로 막는다 —
    // 화면 잠금 상태에서 알림만 봐도 대화 내용이 새어나가지 않게 하려는 목적. 그 외엔 사용자가
    // 환경설정에서 고른 미리보기 범위(_shouldShowPreviewFor)를 따른다.
    final preview = room?.isSecret == true || !_shouldPreviewFor(room)
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
    if (room != null && m.senderId != null) {
      for (final member in room.members) {
        if (member.id == m.senderId) {
          sender = member;
          break;
        }
      }
    }
    // 자동화 메시지는 사람 아바타가 없어서, 채팅 말풍선의 번개 아바타와 비슷하게 그린다.
    final bot = m.isAutomation;

    if (suppressNotifications) return;
    notifications.showMessage(
      title: roomTag != null
          ? '${m.senderName} [$roomTag]${teamTag == null ? '' : ' [$teamTag]'}'
          : m.senderName,
      body: preview,
      roomId: m.roomId,
      senderName: m.senderName,
      conversationTitle: roomTag == null
          ? null
          : (teamTag == null ? roomTag : '$roomTag · $teamTag'),
      avatarType: bot ? 'character' : sender?.avatarType ?? 'initial',
      avatarEmoji: bot ? '⚡' : sender?.avatarEmoji,
      avatarColor: bot
          ? colorToHex(automationAvatarColor)
          : sender?.avatarColor,
      avatarUrl: sender?.avatarUrl != null
          ? resolveUrl(sender!.avatarUrl!)
          : null,
      isSecret: room?.isSecret == true,
    );
  }

  /// 알림 제목 끝에 붙일 팀 이름 — 여러 팀 방에서 알림이 섞여 오므로 어느 팀인지 구분해 준다.
  String? _teamTagFor(Room? room) {
    if (room == null) return null;
    return teams
        .where((t) => t.id == room.teamId)
        .map((t) => t.name)
        .firstOrNull;
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
    final preview = room?.isSecret == true || !_shouldPreviewFor(room)
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
    final teamTag = _teamTagFor(room);
    if (suppressNotifications) return;
    notifications.showMessage(
      title: '${c.senderName} [$tag]${teamTag == null ? '' : ' [$teamTag]'}',
      body: preview,
      roomId: c.roomId,
      senderName: c.senderName,
      conversationTitle: teamTag == null ? tag : '$tag · $teamTag',
      avatarType: sender?.avatarType ?? 'initial',
      avatarEmoji: sender?.avatarEmoji,
      avatarColor: sender?.avatarColor,
      avatarUrl: sender?.avatarUrl != null
          ? resolveUrl(sender!.avatarUrl!)
          : null,
      isSecret: room?.isSecret == true,
    );
  }

  /// 토픽방에 새 공지가 올라왔을 때(announcement:new) — 배너 갱신, 알림 센터의 "안 읽은 공지"
  /// 표시, 로컬 알림 표시까지 한 번에 처리한다(_handleIncomingMessage와 같은 구조). 내가 쓴
  /// 공지면 전부 건너뛴다.
  void _handleIncomingAnnouncement(Announcement a) {
    final match = rooms.where((r) => r.id == a.roomId);
    if (match.isEmpty) return;
    final room = match.first;
    room.latestAnnouncement = a;
    if (a.authorId != userId) {
      room.hasUnreadAnnouncement = true;
      room.unreadAnnouncementCount++;
    }
    notifyListeners();

    if (a.authorId == userId) return;
    // 그 방을 지금 보고 있으면 배너가 바로 바뀐 걸 이미 보고 있으므로(알림 끄기와 같은 이유로
    // 안읽음 표시는 그대로 두되) 알림 배너/토스트만 건너뛴다 — _handleIncomingMessage와 동일 규칙.
    final isViewingNow = room.id == _activeRoomId && appInForeground;
    if (isViewingNow || room.muted == true) return;

    AppUser? sender;
    for (final member in room.members) {
      if (member.id == a.authorId) {
        sender = member;
        break;
      }
    }
    final roomTag = room.displayName(userId ?? '');
    final tag = '$roomTag·공지';
    final teamTag = _teamTagFor(room);
    if (suppressNotifications) return;
    notifications.showMessage(
      title: '${a.authorName} [$tag]${teamTag == null ? '' : ' [$teamTag]'}',
      body: a.text,
      roomId: room.id,
      senderName: a.authorName,
      conversationTitle: teamTag == null ? tag : '$tag · $teamTag',
      avatarType: sender?.avatarType ?? 'initial',
      avatarEmoji: sender?.avatarEmoji,
      avatarColor: sender?.avatarColor,
      avatarUrl: sender?.avatarUrl != null
          ? resolveUrl(sender!.avatarUrl!)
          : null,
    );
  }

  /// 공지 목록/상세를 열었다는 뜻(announcement_list_screen.dart, announcement_detail_screen.dart) —
  /// 로컬로 즉시 안읽음 표시를 지우고(반응성), 서버에도 알려서 알림 센터와 다른 기기에도 반영한다.
  void markAnnouncementsRead(Room room) {
    if (!room.hasUnreadAnnouncement) return;
    room.hasUnreadAnnouncement = false;
    room.unreadAnnouncementCount = 0;
    notifyListeners();
    chatSocket.markAnnouncementRead(room.id);
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
      incoming.customName = rooms[i].customName;
      incoming.hidden = rooms[i].hidden;
      incoming.lastActivityAt = rooms[i].lastActivityAt;
      incoming.lastMessagePreview = rooms[i].lastMessagePreview;
      // latestAnnouncement는 toRoomDto가 requesterId 없이도 항상 채워주므로 여기 들어오는
      // 값이 더 최신이라 그대로 둔다. hasUnreadAnnouncement는 unreadCount 등과 똑같이
      // requesterId가 있을 때만 채워지므로(rooms.js) 이 경로(브로드캐스트)에선 낡을 수 있어
      // 보존한다. dismissedAnnouncementId는 서버 DTO에 아예 없는 순수 로컬 값이라 항상 보존.
      incoming.hasUnreadAnnouncement = rooms[i].hasUnreadAnnouncement;
      incoming.unreadAnnouncementCount = rooms[i].unreadAnnouncementCount;
      incoming.dismissedAnnouncementId = rooms[i].dismissedAnnouncementId;
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

  /// 그룹채팅방 이름을 나에게만 바꾼다(빈 문자열이면 원래 이름으로). toggleMuted와 같은
  /// 낙관적 갱신 패턴 — 실패하면 되돌리고 예외를 다시 던져 호출한 화면이 알리게 한다.
  Future<void> renameRoomForMe(Room room, String name) async {
    final trimmed = name.trim();
    final previous = room.customName;
    room.customName = trimmed.isEmpty ? null : trimmed;
    notifyListeners();
    try {
      await api!.setRoomNickname(room.id, trimmed);
    } catch (_) {
      room.customName = previous;
      notifyListeners();
      rethrow;
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

  /// 방은 전부 지금 보고 있는 팀 안에 만들어진다 — 팀을 안 고른 상태(팀 선택 화면)에서는
  /// 애초에 이 화면들에 들어갈 수 없으므로, 여기서는 currentTeam이 있다고 보고 진행한다.
  String get _requireTeamId {
    final team = currentTeam;
    if (team == null) throw StateError('팀을 먼저 선택해야 합니다.');
    return team.id;
  }

  Future<Room> createTopic({
    required String name,
    String? description,
    bool isPublic = true,
  }) async {
    final room = await api!.createTopic(
      teamId: _requireTeamId,
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
    String? iconType,
    String? iconEmoji,
    String? iconColor,
    String? iconUrl,
  }) async {
    final room = await api!.createGroup(
      teamId: _requireTeamId,
      name: name,
      memberIds: memberIds,
      iconType: iconType,
      iconEmoji: iconEmoji,
      iconColor: iconColor,
      iconUrl: iconUrl,
    );
    _upsertRoom(room);
    return room;
  }

  Future<Room> startDm(String targetUserId) async {
    final room = await api!.startDm(_requireTeamId, targetUserId);
    _upsertRoom(room);
    return room;
  }

  /// 조직도에서 1:1 대화를 시작할 때 쓴다 — 아직 팀을 고르지 않은 상태(팀 목록 화면)에서도
  /// 호출할 수 있도록 [teamId]를 명시적으로 받는다. 평문 DM은 팀 안에서만 만들어지므로(server
  /// rooms.js) 나와 상대가 함께 속한 팀이어야 하고(조직도 화면이 미리 계산해서 넘긴다).
  /// requestOpenRoom이 그 팀으로 전환하고 새 방을 바로 열어준다.
  Future<Room> startDmInTeam(String teamId, String targetUserId) async {
    final room = await api!.startDm(teamId, targetUserId);
    _upsertRoom(room);
    requestOpenRoom(room);
    return room;
  }

  /// 지금 팀의 멤버 목록(조직도/새 대화 상대 선택) — 서버 전체 사용자가 아니라 팀 단위다.
  Future<List<AppUser>> fetchTeamMembers() =>
      api!.fetchTeamMembers(_requireTeamId);

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

  /// 현재 비밀번호가 맞는지만 확인한다 — "이메일 변경" 1단계 다이얼로그가 쓴다. 틀리면
  /// 여기서 던져서 다이얼로그가 잡는다(다른 상태는 전혀 안 바뀐다).
  Future<void> verifyPassword(String password) => api!.verifyPassword(password);

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

  Future<void> leaveRoom(
    String roomId, {
    bool alsoRemoveOther = false,
    bool realLeave = false,
  }) async {
    final room = _findRoom(roomId);
    await api!.leaveRoom(
      roomId,
      alsoRemoveOther: alsoRemoveOther,
      realLeave: realLeave,
    );
    // 평문 DM은 서버가 멤버십을 그대로 두고 내 hidden 플래그만 켠다(room_options_menu.dart
    // 참고) — 상대가 새 메시지를 보내면 room:hidden 브로드캐스트로 자동으로 다시 꺼지므로,
    // 방 자체는 목록에서 지우지 않고 hidden만 올려둔다. 그룹/토픽/비밀 대화는 지금까지처럼
    // 진짜 멤버십이 없어지므로 목록에서 완전히 뺀다.
    final isPlainDm =
        room != null && room.type == RoomType.dm && !room.isSecret;
    if (isPlainDm) {
      room.hidden = true;
      if (realLeave) {
        // "진짜 나가기"는 서버가 dm_history_floors에 기록 시작선을 남겨서, 다음에 방을
        // 새로 불러올 때(GET /rooms/:id/messages) 그 이전 메시지를 걸러준다 — 그런데
        // RoomChatController를 그대로 두면 이미 메모리에 올라와 있는(그 이전 내용이 섞인)
        // 메시지 목록을 캐시로 그대로 보여줄 뿐 서버에 다시 요청하지 않는다. 컨트롤러를
        // 지워서, 방이 다시 보일 때(controllerFor) 새로 만들어져 서버에서 다시 불러오게
        // 한다 — 그래야 방금 그은 시작선이 실제로 적용된다. 그냥 "숨기기"는 시작선이 없어
        // 캐시를 지울 필요가 없다(계속 켜둬야 숨겨진 동안의 미리보기/안읽음이 정확하다).
        _controllers.remove(roomId)?.dispose();
      }
    } else {
      if (room?.isSecret == true) {
        await secretSessionManager?.forgetRoom(roomId);
      }
      rooms.removeWhere((r) => r.id == roomId);
      _controllers.remove(roomId)?.dispose();
    }
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
    await _renamedSub?.cancel();
    await _projectNotifSub?.cancel();
    await _projectNotifSyncSub?.cancel();
    projectUnread = 0;
    await _hiddenSub?.cancel();
    await _teamSub?.cancel();
    await _teamLeftSub?.cancel();
    await _commentSub?.cancel();
    await _messageEditedSub?.cancel();
    await _messageLinkPreviewSub?.cancel();
    await _messageDeletedSub?.cancel();
    await _commentEditedSub?.cancel();
    await _commentDeletedSub?.cancel();
    await _presenceSub?.cancel();
    await _reconnectSub?.cancel();
    await _authErrorSub?.cancel();
    await _roleUpdatedSub?.cancel();
    await _orgUpdatedSub?.cancel();
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
    accountRole = AccountRole.guest;
    isServerAdmin = false;
    canCreateTeamInviteLink = false;
    canCreateProject = false;
    orgScope = 'team';
    myDepartment = null;
    myPosition = null;
    myTeamPositions = [];
    rooms.clear();
    // 로그아웃하면 팀 선택도 초기화 — 다시 로그인하면 팀 선택 화면부터 시작한다.
    teams.clear();
    currentTeam = null;
    stage = AuthStage.needsLogin;
    notifyListeners();
  }

  String resolveUrl(String relative) => api?.resolve(relative) ?? relative;
}
