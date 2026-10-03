import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:livekit_client/livekit_client.dart';

import 'api_client.dart';
import 'call_hands.dart';

/// 통화 중에만 도는 Android 포그라운드 서비스. 이게 없으면 통화 중에 홈으로 나가는 순간
/// OS가 카메라/마이크 접근을 끊어서(Android 14+) 상대방에게 내 영상·소리가 안 간다.
/// 서비스가 도는 동안 알림바에 "통화 중"이 상주하고, 통화를 끊으면 같이 사라진다.
///
/// 별도 백그라운드 작업(task handler)은 쓰지 않는다 — 우리에게 필요한 건 "앱이 백그라운드로
/// 가도 캡처 권한을 유지해주는 서비스"뿐이라 이벤트 액션을 nothing으로 둔다.
Future<void> _startCallForegroundService(
  String roomName, {
  bool includeMediaProjection = false,
}) async {
  if (!Platform.isAndroid) return;
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'ongoing_call',
      channelName: '통화 중',
      channelDescription: '화상회의가 진행되는 동안 표시됩니다.',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
  await FlutterForegroundTask.startService(
    serviceTypes: [
      ForegroundServiceTypes.camera,
      ForegroundServiceTypes.microphone,
      // 화면 공유(MediaProjection)는 Android 14+에서 이 타입의 서비스가 먼저 돌고 있어야만
      // 시작할 수 있다 — 공유를 켤 때만 포함해서 다시 띄운다.
      if (includeMediaProjection) ForegroundServiceTypes.mediaProjection,
    ],
    notificationTitle: '통화 중',
    notificationText: roomName,
    // 기본값은 앱 아이콘(적응형)이라 알림 아이콘으로 쓰면 안 된다 — 흰 실루엣으로(AndroidManifest.xml).
    notificationIcon: const NotificationIcon(
      metaDataName: 'com.teamtalk.messenger.NOTIFICATION_ICON',
    ),
  );
}

Future<void> _stopCallForegroundService() async {
  if (!Platform.isAndroid) return;
  await FlutterForegroundTask.stopService();
}

/// 화상회의 한 통(通)을 들고 있는 컨트롤러 — LiveKit 연결, 마이크/카메라 상태, 참가자 목록.
///
/// 시그널링(누가 통화를 걸었는지, 지금 누가 들어와 있는지)은 우리 소켓(chat_socket.dart의
/// call:state)이 담당하고, 여기서는 **미디어 연결만** 다룬다 — 미디어는 클라이언트와 LiveKit
/// 서버가 직접 주고받고 우리 Node 서버는 그 경로에 끼지 않는다(server/src/calls.js 참고).
///
/// Room 자체가 ChangeNotifier라 참가자/트랙 변화가 있을 때마다 다시 그려진다 — 이 클래스는
/// 그 위에 "연결 중/연결됨/실패" 같은 우리 화면이 필요로 하는 상태만 얹는다.
class CallController extends ChangeNotifier {
  /// ApiClient를 직접 들고 있지 않고 매번 가져오는 이유: 서버 주소를 바꾸거나 토큰이 갱신되면
  /// Session이 ApiClient를 새로 만드는데, 그때 여기 든 참조가 옛것으로 남으면 안 되기 때문.
  final ApiClient Function() _api;
  CallController(this._api);

  Room? _room;
  Room? get room => _room;

  /// 지금 통화 중인 대화방 id. null이면 통화 중이 아니다.
  String? _roomId;
  String? get roomId => _roomId;

  bool _connecting = false;
  bool get connecting => _connecting;

  String? _error;
  String? get error => _error;

  bool get connected => _room?.connectionState == ConnectionState.connected;

  /// 통화에 들어간다. 이미 다른 방에서 통화 중이면 먼저 끊고 새로 연결한다.
  Future<void> join(String chatRoomId, {String? roomLabel}) async {
    if (_roomId == chatRoomId && (connected || _connecting)) return;
    await leave();

    _roomId = chatRoomId;
    _connecting = true;
    _error = null;
    notifyListeners();

    try {
      final credentials = await _api().fetchCallToken(chatRoomId);
      final room = Room(
        roomOptions: const RoomOptions(
          // 화면에 작게 보이는 참가자는 낮은 해상도만 받아서 대역폭을 아낀다(SFU의 장점).
          adaptiveStream: true,
          dynacast: true,
        ),
      );
      // Room은 ChangeNotifier라 UI가 직접 구독한다 — 여기서도 연결 상태 변화를 그대로
      // 위로 흘려보내, 통화 화면이 CallController 하나만 구독하면 되게 한다.
      room.addListener(notifyListeners);
      // 손들기 신호(데이터 채널)와 참가자 입·퇴장은 연결 전에 구독해 둔다 — 놓치는 메시지가 없게.
      _roomListener = room.createListener()
        ..on<DataReceivedEvent>(_onData)
        ..on<ParticipantConnectedEvent>(_onParticipantConnected)
        ..on<ParticipantDisconnectedEvent>(_onParticipantDisconnected);
      await room.connect(credentials.url, credentials.token);
      await room.localParticipant?.setMicrophoneEnabled(true);
      await room.localParticipant?.setCameraEnabled(true);
      _room = room;
      // 연결에 성공한 뒤에 띄운다 — 실패한 통화에 알림만 남는 걸 막는다.
      _screenShareLabel = roomLabel ?? '화상회의';
      await _startCallForegroundService(_screenShareLabel);
    } catch (e) {
      _error = e.toString();
      _roomId = null;
      _room = null;
      await _roomListener?.dispose();
      _roomListener = null;
      rethrow;
    } finally {
      _connecting = false;
      notifyListeners();
    }
  }

  Future<void> leave() async {
    final room = _room;
    _room = null;
    _roomId = null;
    _connecting = false;
    // 손은 통화를 나가면 저절로 내려간다 — 남은 사람들은 퇴장 이벤트로 이 사람의 손을 지운다.
    _hands.clear();
    _handResendTimer?.cancel();
    final roomListener = _roomListener;
    _roomListener = null;
    notifyListeners();
    await roomListener?.dispose();
    await _stopCallForegroundService();
    if (room == null) return;
    room.removeListener(notifyListeners);
    await room.disconnect();
    await room.dispose();
  }

  bool get micEnabled =>
      _room?.localParticipant?.isMicrophoneEnabled() ?? false;
  bool get cameraEnabled => _room?.localParticipant?.isCameraEnabled() ?? false;

  Future<void> toggleMic() async {
    final me = _room?.localParticipant;
    if (me == null) return;
    await me.setMicrophoneEnabled(!me.isMicrophoneEnabled());
    notifyListeners();
  }

  Future<void> toggleCamera() async {
    final me = _room?.localParticipant;
    if (me == null) return;
    await me.setCameraEnabled(!me.isCameraEnabled());
    notifyListeners();
  }

  bool get screenShareEnabled =>
      _room?.localParticipant?.isScreenShareEnabled() ?? false;

  /// 화면 공유를 켜고 끈다. Windows는 어느 화면/창을 공유할지 미리 고른 [sourceId]가 필요하고
  /// (call_screen.dart의 선택 대화상자), Android는 OS가 자체 선택 화면을 띄우므로 필요 없다.
  ///
  /// Android는 화면 캡처(MediaProjection)를 시작하기 전에 mediaProjection 타입의 포그라운드
  /// 서비스가 이미 돌고 있어야 해서(Android 14+), 통화용 서비스를 그 타입까지 포함해 다시
  /// 띄운 뒤에 공유를 시작한다.
  Future<void> toggleScreenShare({String? sourceId}) async {
    final me = _room?.localParticipant;
    if (me == null) return;
    final enable = !me.isScreenShareEnabled();
    if (enable && Platform.isAndroid) {
      await _startCallForegroundService(
        _screenShareLabel,
        includeMediaProjection: true,
      );
    }
    await me.setScreenShareEnabled(
      enable,
      screenShareCaptureOptions: sourceId == null
          ? null
          : ScreenShareCaptureOptions(sourceId: sourceId),
    );
    if (!enable && Platform.isAndroid) {
      // 공유를 끄면 화면 캡처 권한이 더 필요 없으므로 원래(카메라/마이크) 서비스로 되돌린다.
      await _startCallForegroundService(_screenShareLabel);
    }
    notifyListeners();
  }

  // ───────────── 손들기 ─────────────
  //
  // 내 손 상태를 LiveKit 데이터 채널(reliable, topic 'call')로 방 전체에 `{type:'hand', raised}`로
  // 알린다. 서버(Node)는 이 경로에 끼지 않는다. 늦게 들어온 사람은 이미 든 손을 모르므로,
  // 새 참가자가 연결되면 내 손이 올라가 있을 때 그 사람에게만 한 번 다시 알린다.

  final HandRaiseBook _hands = HandRaiseBook();
  EventsListener<RoomEvent>? _roomListener;
  Timer? _handResendTimer;
  final StreamController<String> _handRaisedNames =
      StreamController<String>.broadcast();

  /// identity → 손든 시각(나 포함).
  Map<String, DateTime> get raisedHands => _hands.raised;

  bool get handRaised {
    final me = _room?.localParticipant?.identity;
    return me != null && _hands.isRaised(me);
  }

  /// 다른 사람이 새로 손을 들 때마다 그 사람의 이름이 흐른다 — 화면이 토스트로 알린다.
  Stream<String> get handRaisedNames => _handRaisedNames.stream;

  Future<void> toggleHand() async {
    final me = _room?.localParticipant;
    if (me == null) return;
    final raise = !_hands.isRaised(me.identity);
    _hands.apply(me.identity, raise, DateTime.now());
    notifyListeners();
    await _publishHand(raise);
  }

  Future<void> _publishHand(bool raised, {List<String>? to}) async {
    try {
      await _room?.localParticipant?.publishData(
        encodeHandMessage(raised),
        reliable: true,
        topic: callDataTopic,
        destinationIdentities: to,
      );
    } catch (_) {
      // 손들기 신호가 한 번 못 가도 통화 자체엔 영향이 없다 — 다음 토글/입장 때 다시 맞춰진다.
    }
  }

  void _onData(DataReceivedEvent e) {
    if (e.topic != callDataTopic) return;
    final sender = e.participant;
    if (sender == null) return;
    final raised = decodeHandMessage(e.data);
    if (raised == null) return;
    final fresh = _hands.apply(sender.identity, raised, DateTime.now());
    if (fresh) {
      _handRaisedNames.add(sender.name.isEmpty ? sender.identity : sender.name);
    }
    notifyListeners();
  }

  void _onParticipantConnected(ParticipantConnectedEvent e) {
    if (!handRaised) return;
    final identity = e.participant.identity;
    // 막 들어온 사람의 데이터 채널이 아직 열리기 전일 수 있어 잠깐 뒤에 보낸다.
    _handResendTimer?.cancel();
    _handResendTimer = Timer(const Duration(seconds: 1), () {
      if (handRaised) _publishHand(true, to: [identity]);
    });
  }

  void _onParticipantDisconnected(ParticipantDisconnectedEvent e) {
    _hands.remove(e.participant.identity);
    notifyListeners();
  }

  /// 포그라운드 서비스 알림에 쓸 방 이름 — join()에서 받아둔 값을 화면 공유 전환 때도 쓴다.
  String _screenShareLabel = '화상회의';

  @override
  void dispose() {
    unawaited(leave());
    unawaited(_handRaisedNames.close());
    super.dispose();
  }
}
