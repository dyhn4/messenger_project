import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:livekit_client/livekit_client.dart';

import '../models/call_recording.dart';
import 'api_client.dart';
import 'app_platform.dart';
import 'call_hands.dart';
import 'call_quality.dart';
import 'call_whiteboard.dart';
import '../l10n/tr.dart';

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
  if (!AppPlatform.isAndroid) return;
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'ongoing_call',
      channelName: tr('통화 중'),
      channelDescription: tr('화상회의가 진행되는 동안 표시됩니다.'),
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
    notificationTitle: tr('통화 중'),
    notificationText: roomName,
    // 기본값은 앱 아이콘(적응형)이라 알림 아이콘으로 쓰면 안 된다 — 흰 실루엣으로(AndroidManifest.xml).
    notificationIcon: const NotificationIcon(
      metaDataName: 'com.teamtalk.messenger.NOTIFICATION_ICON',
    ),
  );
}

Future<void> _stopCallForegroundService() async {
  if (!AppPlatform.isAndroid) return;
  await FlutterForegroundTask.stopService();
}

/// LiveKit 연결이 이 기기 밖의 이유로 끝났을 때 띄울 짧은 안내 — null이면 안내할 것이 없다(내가 나간 것).
///
/// 서버는 방에서 내보내졌거나 팀에서 빠졌거나 계정이 정지되는 등 통화에 있을 자격을 잃은 사람을 LiveKit에서 내보내고
/// ([DisconnectReason.participantRemoved] — server/src/callAccess.js), 토픽을 지우면 회의방째 닫는다([DisconnectReason.roomDeleted]).
/// 같은 계정으로 다른 기기에서 들어오면 LiveKit이 먼저 들어와 있던 연결을 끊는다([DisconnectReason.duplicateIdentity]).
/// 그 밖의 이유는 재연결까지 실패해 연결이 아주 끊긴 것이다. 어느 쪽이든 그 연결로는 통화를 이어 갈 수 없다.
String? callDisconnectNotice(DisconnectReason? reason) {
  switch (reason) {
    case DisconnectReason.clientInitiated:
      return null;
    case DisconnectReason.participantRemoved:
      return tr('화상회의에서 내보내졌습니다');
    case DisconnectReason.roomDeleted:
      return tr('화상회의가 종료되었습니다');
    case DisconnectReason.duplicateIdentity:
      return tr('다른 기기에서 화상회의에 참여해 이 기기의 통화를 끝냈습니다');
    default:
      return tr('화상회의 연결이 끊겼습니다');
  }
}

/// 같은 계정이 다른 기기에서 이 통화에 들어가 이 기기의 연결이 끊긴 것인지 — 그 사람은 다른 기기로 통화를 계속하고
/// 있으니 서버에 "나갔다"고 바로 알리지 않고 넘어갔다고 알린다(Session이 call:leave에 handoff를 붙인다 — 바로 나가면
/// 다른 기기의 참여가 닿기 전에 진행자가 넘어가고 통화 기록에 나감·참여가 남는다).
bool callDisconnectIsHandoff(DisconnectReason? reason) =>
    reason == DisconnectReason.duplicateIdentity;

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

  /// 통화가 이 기기 밖의 이유로 끝났을 때(서버가 내보냄·회의방이 닫힘·다른 기기에서 참여·연결이 아주 끊김) — 연결은 이미
  /// 정리한 뒤에 그 방 id와 [callDisconnectNotice] 안내, 다른 기기로 넘어간 것인지([callDisconnectIsHandoff])로 부른다.
  /// Session이 서버 통화 상태를 맞추고 안내를 띄운다.
  final void Function(String roomId, String notice, bool handoff)?
  onDisconnected;

  /// LiveKit 연결이 끊겼다가 다시 이어졌을 때(와이파이↔LTE 전환, 서버 재시작 뒤 신호 재연결 등) 그 방 id로 부른다.
  /// 신호가 메인 서버의 /livekit 프록시를 거쳐서, 서버가 재시작되면 채팅 소켓과 LiveKit 신호가 함께 끊긴다 — 채팅 소켓이
  /// 먼저 붙으면 그때는 아직 통화가 "연결됨"이 아니라 참여를 다시 알리지 못하므로, Session이 여기서 한 번 더 알린다.
  final void Function(String roomId)? onReconnected;

  CallController(this._api, {this.onDisconnected, this.onReconnected});

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

  /// 통화에 들어간다. 이미 다른 방에서 통화 중이면 먼저 끊고 새로 연결한다. [camera]가 false면 카메라를 끈 채(음성으로)
  /// 들어간다 — 마이크는 켜고, 카메라는 통화 화면에서 나중에 켤 수 있다.
  Future<void> join(
    String chatRoomId, {
    String? roomLabel,
    bool camera = true,
  }) async {
    if (_roomId == chatRoomId && (connected || _connecting)) return;
    await leave();

    _roomId = chatRoomId;
    _connecting = true;
    _error = null;
    notifyListeners();

    try {
      final credentials = await _api().fetchCallToken(chatRoomId);
      final room = Room(
        roomOptions: RoomOptions(
          // 화면에 작게 보이는 참가자는 낮은 해상도만 받아서 대역폭을 아낀다(SFU의 장점).
          adaptiveStream: true,
          dynacast: true,
          // 카메라는 1080p로 찍는다 — 실제로 보내는 최대 해상도는 화질 단계(videoTier)가 정한다(_applyVideoCaps).
          defaultCameraCaptureOptions: callCameraCaptureOptions,
          defaultVideoPublishOptions: callVideoPublishOptions,
          // 아이폰은 사용자가 iOS의 "방송 시작"을 누른 뒤에 LiveKit이 이 기본 옵션으로 화면 공유를 올린다(toggleScreenShare 참고) —
          // 방송 확장(client/ios/BroadcastExtension)이 찍은 화면을 받게 한다. 다른 플랫폼은 늘 옵션을 넘겨 이 값을 쓰지 않는다.
          defaultScreenShareCaptureOptions: ScreenShareCaptureOptions(
            useiOSBroadcastExtension: true,
            params: callVideoSpecFor(videoTier).screen,
          ),
        ),
      );
      // Room은 ChangeNotifier라 UI가 직접 구독한다 — 여기서도 연결 상태 변화를 그대로
      // 위로 흘려보내, 통화 화면이 CallController 하나만 구독하면 되게 한다.
      room.addListener(notifyListeners);
      // 손들기 신호(데이터 채널)와 참가자 입·퇴장은 연결 전에 구독해 둔다 — 놓치는 메시지가 없게.
      _roomListener = room.createListener()
        ..on<DataReceivedEvent>(_onData)
        ..on<ParticipantConnectedEvent>(_onParticipantConnected)
        ..on<ParticipantDisconnectedEvent>(_onParticipantDisconnected)
        // 서버가 내보냈거나 연결이 아주 끊기면 통화를 정리한다 — 안 그러면 빈 통화 화면이 남고 다음 전화도 울리지 않는다.
        ..on<RoomDisconnectedEvent>((e) => _onRoomDisconnected(room, e))
        // 끊겼다가 다시 이어지면 서버에 참여를 다시 알릴 기회를 준다(onReconnected).
        ..on<RoomReconnectedEvent>((_) => _onRoomReconnected(room))
        // 새로 올린 영상(카메라를 켜거나 화면 공유를 시작)에도 지금 화질 단계를 맞춘다. 아이폰 화면 공유는 누른 뒤가 아니라
        // iOS 방송이 시작·종료될 때(제어 센터에서 멈춤 포함) 올라가고 내려가서, 그때 화면의 공유 단추도 다시 그린다.
        ..on<LocalTrackPublishedEvent>((_) {
          unawaited(_applyVideoCaps());
          notifyListeners();
        })
        ..on<LocalTrackUnpublishedEvent>((_) => notifyListeners());
      await room.connect(credentials.url, credentials.token);
      _room = room;
      final me = room.localParticipant;
      if (me != null) {
        _whiteboard = CallWhiteboard(myId: me.identity, send: _sendWhiteboard);
      }
      _updateLocalTier();
      await me?.setMicrophoneEnabled(true);
      if (camera) await me?.setCameraEnabled(true);
      // 그사이 끊겼으면(서버가 바로 내보냄 등 — _onRoomDisconnected가 이미 정리했다) "통화 중" 알림을 다시 띄우지 않는다.
      if (!identical(_room, room)) return;
      // 연결에 성공한 뒤에 띄운다 — 실패한 통화에 알림만 남는 걸 막는다.
      _screenShareLabel = roomLabel ?? tr('화상회의');
      await _startCallForegroundService(_screenShareLabel);
    } catch (e) {
      _error = e.toString();
      _roomId = null;
      _room = null;
      _whiteboard?.dispose();
      _whiteboard = null;
      await _roomListener?.dispose();
      _roomListener = null;
      rethrow;
    } finally {
      _connecting = false;
      notifyListeners();
    }
  }

  /// LiveKit 연결이 끝났다. 연결 중(아직 [_room]이 아닌 Room)에 실패한 것은 join()의 catch가 정리하고, 내가 나간 것은
  /// leave()가 리스너를 먼저 치워서 여기로 오지 않는다(혹시 와도 clientInitiated라 안내가 없다).
  void _onRoomDisconnected(Room room, RoomDisconnectedEvent e) {
    if (!identical(_room, room)) return;
    final notice = callDisconnectNotice(e.reason);
    if (notice == null) return;
    final roomId = _roomId;
    unawaited(leave());
    if (roomId != null) {
      onDisconnected?.call(roomId, notice, callDisconnectIsHandoff(e.reason));
    }
  }

  /// LiveKit 연결이 다시 이어졌다 — 지금 통화 중인 Room일 때만 알린다(나간 뒤에 늦게 온 이벤트는 무시).
  void _onRoomReconnected(Room room) {
    if (!identical(_room, room)) return;
    final roomId = _roomId;
    if (roomId != null) onReconnected?.call(roomId);
  }

  Future<void> leave() async {
    final room = _room;
    _room = null;
    _roomId = null;
    _connecting = false;
    // 손은 통화를 나가면 저절로 내려간다 — 남은 사람들은 퇴장 이벤트로 이 사람의 손을 지운다.
    _hands.clear();
    _handResendTimer?.cancel();
    _snapshotTimer?.cancel();
    // 화이트보드는 통화 한 통 동안만 — 나가면 지운다(남은 사람들의 판은 그대로).
    _whiteboard?.dispose();
    _whiteboard = null;
    _hostId = null;
    _recording = null;
    _serverStateSeen = false;
    _micRequested = false;
    _serverTier = null;
    _localTier = CallVideoTier.fhd;
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
    // 스스로 켰으면 진행자의 켜기 요청에 답한 것과 같다.
    if (me.isMicrophoneEnabled()) _micRequested = false;
    notifyListeners();
  }

  /// 진행자의 마이크 요청(소켓 call:mic — 서버가 진행자인지 확인했다). 끄기는 바로 끄고 알린다. 켜기는 내 동의 없이
  /// 켜지 않고 "켜 달라는 요청"으로만 받는다 — 통화 화면이 [마이크 켜기]/[그대로 두기] 안내 띠를 띄운다.
  Future<void> applyHostMic(bool on) async {
    final me = _room?.localParticipant;
    if (me == null) return;
    if (on) {
      if (me.isMicrophoneEnabled() || _micRequested) return;
      _micRequested = true;
      notifyListeners();
      return;
    }
    // 꺼 달라고 했으면 켜 달라는 요청도 거둔다.
    _micRequested = false;
    if (!me.isMicrophoneEnabled()) {
      notifyListeners();
      return;
    }
    await me.setMicrophoneEnabled(false);
    _notices.add(tr('진행자가 마이크를 껐습니다'));
    notifyListeners();
  }

  /// 진행자가 마이크를 켜 달라고 요청했고 아직 답하지 않았는지.
  bool _micRequested = false;
  bool get micRequested => _micRequested;

  /// 요청에 답한다 — [accept]면 마이크를 켜고, 아니면 그대로 둔다(진행자에게 따로 알리지는 않는다 — 켜졌는지는 참가자
  /// 패널의 마이크 표시로 보인다).
  Future<void> answerMicRequest({required bool accept}) async {
    if (!_micRequested) return;
    _micRequested = false;
    notifyListeners();
    if (!accept) return;
    final me = _room?.localParticipant;
    if (me == null || me.isMicrophoneEnabled()) return;
    await me.setMicrophoneEnabled(true);
    notifyListeners();
  }

  // ───────────── 진행자 ─────────────

  /// 이 통화의 진행자 — 서버 call:state의 hostId(건 사람, 나가면 남은 사람 중 먼저 들어온 사람).
  String? _hostId;
  String? get hostId => _hostId;

  /// 내가 진행자인지 — 참가자 패널에서 다른 사람의 마이크를 켜고 끌 수 있다.
  bool get isHost {
    final me = _room?.localParticipant?.identity;
    return me != null && me == _hostId;
  }

  // ───────────── 화질 단계 ─────────────
  //
  // 참가자가 늘면(이 통화 또는 서버 전체) 보내는 영상의 최대 해상도·비트레이트를 낮춘다(call_quality.dart). 카메라는 늘
  // 1080p로 찍고, 보내는 층(simulcast 인코딩)만 줄였다 늘였다 한다 — 다시 찍지 않으니 끊김이 없다.

  CallVideoTier? _serverTier;
  CallVideoTier _localTier = CallVideoTier.fhd;

  /// 지금 보내는 영상의 화질 단계.
  CallVideoTier get videoTier => lowerCallVideoTier(_localTier, _serverTier);

  /// 서버가 알려준 이 통화의 상태(call:state) — 진행자·화질 단계·녹화. Session이 지금 통화 중인 방의 것만 넘긴다.
  void applyServerCallState({
    String? hostId,
    CallVideoTier? videoTier,
    CallRecordingLive? recording,
  }) {
    final before = this.videoTier;
    final hostChanged = hostId != _hostId;
    _hostId = hostId;
    _serverTier = videoTier;
    final recordingChanged = recording?.id != _recording?.id;
    if (recordingChanged) _announceRecording(_recording, recording);
    _recording = recording;
    _serverStateSeen = true;
    if (this.videoTier != before) unawaited(_applyVideoCaps());
    if (hostChanged || recordingChanged || this.videoTier != before) {
      notifyListeners();
    }
  }

  // ───────────── 녹화 ─────────────
  //
  // 녹화는 서버가 LiveKit Egress에 시킨다(server/src/callRecording.js) — Egress는 숨은 참가자라 참가자 목록에 안 보이므로, 녹화 중에는
  // 모두의 통화 화면에 "녹화 중"을 띄우고 시작·멈춤을 알린다.

  CallRecordingLive? _recording;

  /// 지금 녹화 중인 것(없으면 null).
  CallRecordingLive? get recording => _recording;

  /// 이 통화에서 서버 상태를 받은 적이 있는지 — 처음 받은 상태가 이미 녹화 중이면 "녹화 중인 회의"로 알린다(들어오자마자).
  bool _serverStateSeen = false;

  /// 내가 녹화를 멈출 수 있는지 — 진행자나 녹화를 시작한 사람(서버 callRecordingRules.js recordingStopDenial).
  bool get canStopRecording {
    final me = _room?.localParticipant?.identity;
    final r = _recording;
    return r != null && me != null && (me == r.byId || me == _hostId);
  }

  void _announceRecording(CallRecordingLive? before, CallRecordingLive? after) {
    if (after != null) {
      _notices.add(
        !_serverStateSeen
            ? tr('이 화상회의는 녹화되고 있습니다')
            : after.audioOnly
            ? tr('{name}님이 녹음을 시작했습니다', {'name': after.byName})
            : tr('{name}님이 녹화를 시작했습니다', {'name': after.byName}),
      );
    } else if (before != null) {
      _notices.add(before.audioOnly ? tr('녹음을 멈췄습니다') : tr('녹화를 멈췄습니다'));
    }
  }

  void _updateLocalTier() {
    final room = _room;
    if (room == null) return;
    final before = videoTier;
    _localTier = callVideoTierForParticipants(
      room.remoteParticipants.length + 1,
    );
    if (videoTier != before) unawaited(_applyVideoCaps());
  }

  /// 처음 올릴 때의 인코딩(층마다 줄임 비율·비트레이트·프레임) — 단계를 다시 올릴 때 이 값으로 되돌린다.
  final Expando<List<(double?, int?, int?)>> _originalEncodings = Expando();

  /// 내가 올린 영상마다, 지금 단계의 최대 높이를 넘는 층을 그 높이로 줄인다(넘지 않는 층은 원래대로).
  Future<void> _applyVideoCaps() async {
    final me = _room?.localParticipant;
    if (me == null) return;
    final spec = callVideoSpecFor(videoTier);
    for (final pub in me.videoTrackPublications) {
      final track = pub.track;
      final sender = track?.sender;
      if (track == null || sender == null) continue;
      final screen = pub.source == TrackSource.screenShareVideo;
      final target = screen ? spec.screen : spec.camera;
      try {
        final params = sender.parameters;
        final encodings = params.encodings;
        if (encodings == null || encodings.isEmpty) continue;
        final original = _originalEncodings[track] ??= [
          for (final e in encodings)
            (e.scaleResolutionDownBy, e.maxBitrate, e.maxFramerate),
        ];
        if (original.length != encodings.length) continue;
        final captureHeight = _captureHeight(track);
        var changed = false;
        for (var i = 0; i < encodings.length; i++) {
          final e = encodings[i];
          final (scale0, bitrate0, fps0) = original[i];
          final layerHeight = captureHeight / (scale0 ?? 1);
          var scale = scale0;
          var bitrate = bitrate0;
          var fps = fps0;
          if (layerHeight > target.dimensions.height + 1) {
            scale = callScaleDownBy(captureHeight, target);
            bitrate = _minOrNull(bitrate0, target.encoding?.maxBitrate);
            fps = _minOrNull(fps0, target.encoding?.maxFramerate);
          } else if (screen) {
            // 화면 공유는 해상도가 그대로여도 프레임(30 → 15)은 단계를 따른다.
            fps = _minOrNull(fps0, target.encoding?.maxFramerate);
          }
          if (e.scaleResolutionDownBy != scale ||
              e.maxBitrate != bitrate ||
              e.maxFramerate != fps) {
            e.scaleResolutionDownBy = scale;
            e.maxBitrate = bitrate;
            e.maxFramerate = fps;
            changed = true;
          }
        }
        if (changed) await sender.setParameters(params);
      } catch (_) {
        // 인코딩을 못 바꿔도 통화는 그대로 된다(원래 화질로 보낼 뿐).
      }
    }
  }

  /// 실제로 찍는 높이 — 알 수 없으면(일부 플랫폼) 요청한 높이.
  int _captureHeight(LocalTrack track) {
    try {
      final height = track.mediaStreamTrack.getSettings()['height'];
      if (height is num && height > 0) return height.toInt();
    } catch (_) {}
    final options = track.currentOptions;
    if (options is VideoCaptureOptions) return options.params.dimensions.height;
    return 1080;
  }

  static int? _minOrNull(int? a, int? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a < b ? a : b;
  }

  Future<void> toggleCamera() async {
    final me = _room?.localParticipant;
    if (me == null) return;
    await me.setCameraEnabled(!me.isCameraEnabled());
    // 다시 켜면 카메라를 새로 찍어 같은 자리에 넣는다 — 줄여 둔 층이 그대로인지 한 번 더 맞춘다.
    await _applyVideoCaps();
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
    if (enable && AppPlatform.isAndroid) {
      await _startCallForegroundService(
        _screenShareLabel,
        includeMediaProjection: true,
      );
    }
    // 아이폰 — 켜면 iOS의 "화면 방송" 창이 뜨고 여기서는 아무것도 올리지 않는다. 사용자가 [방송 시작]을 누르면 방송 확장이
    // 앱 그룹의 소켓으로 화면을 보내기 시작하고, LiveKit(BroadcastManager)이 그때 공유를 올린다(RoomOptions의 기본 옵션).
    // 끄면 공유를 내리고, 그러면 방송 확장도 연결이 끊겨 방송을 마친다.
    await me.setScreenShareEnabled(
      enable,
      // 지금 화질 단계의 화면 공유 해상도·프레임(fhd면 1080p 30fps)으로 찍는다.
      screenShareCaptureOptions: ScreenShareCaptureOptions(
        sourceId: sourceId,
        useiOSBroadcastExtension: AppPlatform.isIOS,
        params: callVideoSpecFor(videoTier).screen,
      ),
    );
    if (!enable && AppPlatform.isAndroid) {
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
    final sender = e.participant;
    if (sender == null) return;
    if (e.topic == whiteboardDataTopic) {
      final message = WhiteboardMessage.decode(e.data);
      if (message == null) return;
      if (message is WhiteboardOpened) {
        final name = sender.name.isEmpty ? sender.identity : sender.name;
        _notices.add(tr('{name}님이 화이트보드를 열었습니다', {'name': name}));
        return;
      }
      _whiteboard?.receive(sender.identity, message);
      return;
    }
    if (e.topic != callDataTopic) return;
    final raised = decodeHandMessage(e.data);
    if (raised == null) return;
    final fresh = _hands.apply(sender.identity, raised, DateTime.now());
    if (fresh) {
      _handRaisedNames.add(sender.name.isEmpty ? sender.identity : sender.name);
    }
    notifyListeners();
  }

  void _onParticipantConnected(ParticipantConnectedEvent e) {
    _updateLocalTier();
    final identity = e.participant.identity;
    // 이미 통화 중인 사람들에게 누가 들어왔는지 알린다(퇴장 알림과 짝). 내가 들어갈 때 이미 있던
    // 사람들은 이 이벤트로 오지 않으므로(연결 시점의 기존 참가자) 들어가자마자 알림이 쏟아지지 않는다.
    final name = e.participant.name.isEmpty ? identity : e.participant.name;
    _notices.add(tr('{name}님이 들어왔습니다', {'name': name}));
    _scheduleWhiteboardSnapshot(identity);
    if (!handRaised) return;
    // 막 들어온 사람의 데이터 채널이 아직 열리기 전일 수 있어 잠깐 뒤에 보낸다.
    _handResendTimer?.cancel();
    _handResendTimer = Timer(const Duration(seconds: 1), () {
      if (handRaised) _publishHand(true, to: [identity]);
    });
  }

  void _onParticipantDisconnected(ParticipantDisconnectedEvent e) {
    _hands.remove(e.participant.identity);
    _updateLocalTier();
    // 남은 사람들이 누가 나갔는지 알 수 있게 통화 화면에 알린다([나가기]뿐 아니라 앱이 꺼지거나 연결이
    // 끊겨 빠진 경우도 같은 이벤트라 "나갔습니다"로 묶는다). 내가 나갈 때는 leave()가 리스너를 먼저
    // 치우므로 여기로 오지 않는다.
    final p = e.participant;
    _notices.add(
      tr('{p0}님이 나갔습니다', {'p0': p.name.isEmpty ? p.identity : p.name}),
    );
    notifyListeners();
  }

  // ───────────── 화이트보드 ─────────────
  //
  // 판 내용은 참가자마다 따로 들고(call_whiteboard.dart), 획을 그릴 때마다 LiveKit 데이터 채널(reliable, topic 'wb')로
  // 주고받는다. 늦게 들어온 사람에게는 이미 있던 사람 중 한 명(identity가 가장 작은 사람)이 지금 판을 보내준다.

  CallWhiteboard? _whiteboard;

  /// 지금 통화의 화이트보드(통화 중이 아니면 null).
  CallWhiteboard? get whiteboard => _whiteboard;

  /// 통화에 나 말고 아무도 없는지 — 내가 나가면 화이트보드가 사라지므로 Session이 나가기 전에 저절로 저장한다.
  bool get aloneInCall => _room?.remoteParticipants.isEmpty ?? true;

  Timer? _snapshotTimer;

  Future<void> _sendWhiteboard(
    WhiteboardMessage message, {
    List<String>? to,
  }) async {
    try {
      await _room?.localParticipant?.publishData(
        message.encode(),
        reliable: true,
        topic: whiteboardDataTopic,
        destinationIdentities: to,
      );
    } catch (_) {
      // 한 번 못 가도 통화는 그대로 — 판이 조금 어긋날 뿐이다.
    }
  }

  void _scheduleWhiteboardSnapshot(String newcomer) {
    final room = _room;
    final board = _whiteboard;
    final me = room?.localParticipant;
    if (room == null || board == null || me == null || board.book.isEmpty) {
      return;
    }
    final existing = [
      me.identity,
      for (final p in room.remoteParticipants.values)
        if (p.identity != newcomer) p.identity,
    ];
    if (whiteboardSnapshotSender(existing) != me.identity) return;
    // 막 들어온 사람의 데이터 채널이 열릴 때까지 잠깐 기다린다(손들기와 같다).
    _snapshotTimer?.cancel();
    _snapshotTimer = Timer(const Duration(seconds: 1), () {
      unawaited(_whiteboard?.sendSnapshotTo(newcomer));
    });
  }

  /// 손들기 말고 통화 화면에 띄울 알림 — 진행자가 내 마이크를 바꿈, 누가 화이트보드를 엶.
  final StreamController<String> _notices =
      StreamController<String>.broadcast();
  Stream<String> get notices => _notices.stream;

  /// 포그라운드 서비스 알림에 쓸 방 이름 — join()에서 받아둔 값을 화면 공유 전환 때도 쓴다.
  String _screenShareLabel = tr('화상회의');

  @override
  void dispose() {
    unawaited(leave());
    unawaited(_handRaisedNames.close());
    unawaited(_notices.close());
    super.dispose();
  }
}
