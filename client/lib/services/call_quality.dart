import 'dart:math' as math;

import 'package:livekit_client/livekit_client.dart';

/// 화상회의 영상 화질 단계 — 참가자가 늘어 서버(LiveKit SFU)의 부담이 커지면 보내는 쪽이 카메라·화면 공유의 최대
/// 해상도·비트레이트를 스스로 낮춘다. 단계는 서버가 정해 call:state의 `videoTier`로 보내고(server/src/callQuality.js —
/// 그 통화의 참가자 수와 서버 전체 통화 참가자 수 중 더 낮은 쪽), 클라이언트는 LiveKit 방에서 직접 센 참가자 수로도
/// 한 번 더 계산해 둘 중 낮은 쪽을 쓴다(서버 소식보다 먼저 반응하고, 예전 서버면 이것만 쓴다).
///
/// 카메라는 늘 1080p로 찍고 보내는 맨 위 층(simulcast 'f')만 줄인다 — 다시 찍지 않으니 영상이 끊기지 않는다.
enum CallVideoTier {
  /// 1080p 카메라 · 화면 공유 1080p 30fps.
  fhd,

  /// 720p 카메라 · 화면 공유 1080p 15fps.
  hd,

  /// 540p 카메라 · 화면 공유 1080p 15fps.
  sd,

  /// 360p 카메라 · 화면 공유 720p 15fps.
  ld,
}

/// 서버 값('fhd'|'hd'|'sd'|'ld') → 단계. 모르는 값·없음은 null(클라이언트 계산만 쓴다).
CallVideoTier? callVideoTierFromWire(Object? value) => switch (value) {
  'fhd' => CallVideoTier.fhd,
  'hd' => CallVideoTier.hd,
  'sd' => CallVideoTier.sd,
  'ld' => CallVideoTier.ld,
  _ => null,
};

/// 한 통화의 참가자 수 기준 — 서버(callQuality.js ROOM_TIER_LIMITS)와 같다: 4명까지 1080p, 8명까지 720p, 16명까지
/// 540p, 그 이상 360p.
CallVideoTier callVideoTierForParticipants(int count) {
  if (count <= 4) return CallVideoTier.fhd;
  if (count <= 8) return CallVideoTier.hd;
  if (count <= 16) return CallVideoTier.sd;
  return CallVideoTier.ld;
}

/// 둘 중 더 낮은 화질(서버 값이 없으면 [local] 그대로).
CallVideoTier lowerCallVideoTier(CallVideoTier local, CallVideoTier? server) =>
    server == null || server.index < local.index ? local : server;

/// 단계마다 보내는 영상의 최대치 — 카메라와 화면 공유.
class CallVideoSpec {
  final VideoParameters camera;
  final VideoParameters screen;
  const CallVideoSpec({required this.camera, required this.screen});
}

CallVideoSpec callVideoSpecFor(CallVideoTier tier) => switch (tier) {
  CallVideoTier.fhd => const CallVideoSpec(
    camera: VideoParametersPresets.h1080_169,
    screen: VideoParametersPresets.screenShareH1080FPS30,
  ),
  CallVideoTier.hd => const CallVideoSpec(
    camera: VideoParametersPresets.h720_169,
    screen: VideoParametersPresets.screenShareH1080FPS15,
  ),
  CallVideoTier.sd => const CallVideoSpec(
    camera: VideoParametersPresets.h540_169,
    screen: VideoParametersPresets.screenShareH1080FPS15,
  ),
  CallVideoTier.ld => const CallVideoSpec(
    camera: VideoParametersPresets.h360_169,
    screen: VideoParametersPresets.screenShareH720FPS15,
  ),
};

/// 찍는 높이 [captureHeight]에서 [target] 높이로 보내려면 얼마나 줄여야 하는지(1 미만으로는 키우지 않는다).
double callScaleDownBy(int captureHeight, VideoParameters target) {
  final targetHeight = target.dimensions.height;
  if (captureHeight <= 0 || targetHeight <= 0) return 1;
  return math.max(1, captureHeight / targetHeight);
}

/// 카메라 기본값 — 1080p로 찍고, simulcast 아래 두 층은 360p·720p(기본값 180p·360p는 1080p와 너무 벌어져 중간 크기
/// 타일이 흐리다). 작은 타일로 보는 사람은 SFU가 아래 층만 보낸다(adaptiveStream·dynacast).
const callCameraCaptureOptions = CameraCaptureOptions(
  params: VideoParametersPresets.h1080_169,
);

final callVideoPublishOptions = VideoPublishOptions(
  videoEncoding: VideoParametersPresets.h1080_169.encoding,
  screenShareEncoding: VideoParametersPresets.screenShareH1080FPS30.encoding,
  videoSimulcastLayers: const [
    VideoParametersPresets.h360_169,
    VideoParametersPresets.h720_169,
  ],
);
