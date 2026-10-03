import 'package:livekit_client/livekit_client.dart' as lk;

import '../../models/app_user.dart';
import 'call_logic.dart';

/// 화면의 타일 한 칸 = "참가자 + 그 참가자의 영상 트랙 하나". 화면 공유를 켜면 같은 사람이
/// 카메라 타일과 화면 공유 타일 두 개로 나타난다 — 둘 다 봐야 하는 화면이라 합치지 않는다.
/// [track]이 null이면 카메라를 껐거나(아바타 표시) 시험용 가짜 타일이다.
class CallTileData {
  final CallPerson person;
  final lk.VideoTrack? track;
  final bool isScreenShare;
  const CallTileData(this.person, {this.track, this.isScreenShare = false});

  /// 위젯 키 — 같은 사람의 카메라 타일과 공유 타일을 구분한다.
  String get key => isScreenShare ? '${person.id}#screen' : person.id;
}

/// LiveKit Room → 화면용 참가자 목록(나 먼저, 이어서 들어온 순서).
List<CallPerson> buildCallPeople(
  lk.Room room,
  Map<String, DateTime> hands,
  List<AppUser> members,
) {
  final participants = <lk.Participant>[
    ?room.localParticipant,
    ...room.remoteParticipants.values,
  ];
  final me = room.localParticipant;
  return [
    for (final p in participants)
      CallPerson(
        id: p.identity,
        name: p.name.isEmpty ? p.identity : p.name,
        isMe: identical(p, me),
        micOn: p.isMicrophoneEnabled(),
        camOn: p.isCameraEnabled(),
        sharing: p.isScreenShareEnabled(),
        speaking: p.isSpeaking,
        handRaisedAt: hands[p.identity],
        user: _memberById(members, p.identity),
      ),
  ];
}

AppUser? _memberById(List<AppUser> members, String id) {
  for (final m in members) {
    if (m.id == id) return m;
  }
  return null;
}

/// 사람마다 카메라 타일 하나(영상이 없어도 자리는 둔다) + 화면 공유가 있으면 공유 타일 하나.
List<CallTileData> buildCallTiles(lk.Room room, List<CallPerson> people) {
  final byId = {for (final p in people) p.id: p};
  final participants = <lk.Participant>[
    ?room.localParticipant,
    ...room.remoteParticipants.values,
  ];
  final tiles = <CallTileData>[];
  for (final p in participants) {
    final person = byId[p.identity];
    if (person == null) continue;
    lk.VideoTrack? camera;
    lk.VideoTrack? screen;
    for (final pub in p.videoTrackPublications) {
      if (!pub.subscribed || pub.muted) continue;
      final track = pub.track as lk.VideoTrack?;
      if (track == null) continue;
      if (pub.source == lk.TrackSource.screenShareVideo) {
        screen ??= track;
      } else {
        camera ??= track;
      }
    }
    tiles.add(CallTileData(person, track: camera));
    if (screen != null) {
      tiles.add(CallTileData(person, track: screen, isScreenShare: true));
    }
  }
  return tiles;
}

/// 말하는 중인 참가자 identity(목소리 큰 순).
List<String> activeSpeakerIds(lk.Room room) => [
  for (final p in room.activeSpeakers) p.identity,
];
