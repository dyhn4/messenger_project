import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:livekit_client/livekit_client.dart';

import 'api_client.dart';

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
    notifyListeners();
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

  /// 포그라운드 서비스 알림에 쓸 방 이름 — join()에서 받아둔 값을 화면 공유 전환 때도 쓴다.
  String _screenShareLabel = '화상회의';

  @override
  void dispose() {
    unawaited(leave());
    super.dispose();
  }
}
