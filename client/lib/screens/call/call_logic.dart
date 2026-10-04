import 'dart:math' as math;

import '../../models/app_user.dart';
import '../../models/message.dart';

// 화상회의 화면의 "판단" 부분 — 위젯도 LiveKit도 모르는 순수 함수/모델이다. 그래서 가짜 참가자를
// 넣어 보기 모드·정렬·메인 타일 선택·손들기 규칙을 그대로 시험할 수 있다(test/call_logic_test.dart).

/// 영상 배치 방식. 줌의 "갤러리 보기"/"스피커 보기"와 같다.
enum CallViewMode { gallery, speaker }

/// 오른쪽(좁은 화면에서는 아래 시트)에 띄우는 패널. 같은 자리를 번갈아 쓴다.
enum CallPanel { none, participants, chat }

/// 지금 적용할 보기 모드. 사용자가 직접 고른 게 있으면 그대로, 없으면 다른 사람의 화면 공유가
/// 있을 때 스피커 보기(공유 화면을 크게), 아니면 갤러리 보기.
CallViewMode effectiveViewMode(
  CallViewMode? chosen, {
  required bool hasRemoteScreenShare,
}) {
  if (chosen != null) return chosen;
  return hasRemoteScreenShare ? CallViewMode.speaker : CallViewMode.gallery;
}

/// 참가자 한 명을 화면이 그리는 데 필요한 값만 모은 것(LiveKit Participant에서 뽑아 온다).
class CallPerson {
  /// LiveKit identity = 우리 사용자 id.
  final String id;
  final String name;
  final bool isMe;
  final bool micOn;
  final bool camOn;
  final bool sharing;
  final bool speaking;

  /// 이 통화의 진행자인지(참가자 패널에 "진행자" 표시).
  final bool isHost;

  /// 손을 든 시각. null이면 손을 내린 상태.
  final DateTime? handRaisedAt;

  /// 이 방 멤버 정보(아바타용) — 못 찾으면 null이고 이름 첫 글자로 그린다.
  final AppUser? user;

  const CallPerson({
    required this.id,
    required this.name,
    this.isMe = false,
    this.micOn = true,
    this.camOn = true,
    this.sharing = false,
    this.speaking = false,
    this.isHost = false,
    this.handRaisedAt,
    this.user,
  });

  bool get handRaised => handRaisedAt != null;
}

/// 참가자 패널의 순서 — 손든 사람(든 순서) → 말하는 사람 → 나머지(들어온 순서 그대로).
List<CallPerson> sortForParticipantPanel(List<CallPerson> people) {
  final indexed = people.asMap().entries.toList();
  int group(CallPerson p) => p.handRaised ? 0 : (p.speaking ? 1 : 2);
  indexed.sort((a, b) {
    final ga = group(a.value);
    final gb = group(b.value);
    if (ga != gb) return ga.compareTo(gb);
    if (ga == 0) {
      final byTime = a.value.handRaisedAt!.compareTo(b.value.handRaisedAt!);
      if (byTime != 0) return byTime;
    }
    return a.key.compareTo(b.key); // 안정 정렬
  });
  return [for (final e in indexed) e.value];
}

/// 스피커 보기의 메인 타일에 놓을 참가자를 고른다. 말하는 사람이 바뀔 때마다 메인이 휙휙
/// 바뀌면 눈이 아프므로, 한 번 정해진 메인은 [hold] 동안은 유지한다.
class SpeakerFocus {
  final Duration hold;
  SpeakerFocus({this.hold = const Duration(milliseconds: 1500)});

  String? _mainId;
  DateTime? _since;
  Duration? _pending;

  String? get mainId => _mainId;

  /// 지금 바꾸고 싶은 후보가 있지만 유지 시간 때문에 미룬 경우, 얼마 뒤에 다시 계산해야 하는지.
  Duration? get pendingDelay => _pending;

  /// [available]은 타일이 있는 참가자 id(나 포함), [speakingIds]는 말하는 사람 id(목소리 큰 순).
  /// 내가 말하는 건 메인을 바꾸는 이유가 되지 않는다(내 목소리에 내 얼굴이 크게 뜨면 어색하다).
  String? update({
    required DateTime now,
    required List<String> available,
    required List<String> speakingIds,
    String? selfId,
  }) {
    _pending = null;
    if (available.isEmpty) {
      _mainId = null;
      _since = null;
      return null;
    }
    String? candidate;
    for (final id in speakingIds) {
      if (id != selfId && available.contains(id)) {
        candidate = id;
        break;
      }
    }

    final current = _mainId;
    if (current == null || !available.contains(current)) {
      _mainId =
          candidate ??
          available.firstWhere(
            (id) => id != selfId,
            orElse: () => available.first,
          );
      _since = now;
      return _mainId;
    }
    if (candidate != null && candidate != current) {
      final elapsed = now.difference(_since!);
      if (elapsed >= hold) {
        _mainId = candidate;
        _since = now;
      } else {
        _pending = hold - elapsed;
      }
    }
    return _mainId;
  }
}

/// 갤러리 보기의 격자 계산 결과.
class GalleryLayout {
  final int columns;
  final int rows;
  final double tileWidth;
  final double tileHeight;

  /// true면 타일이 영역에 다 안 들어가서(너무 작아짐) 세로로 스크롤한다.
  final bool scrolls;
  const GalleryLayout({
    required this.columns,
    required this.rows,
    required this.tileWidth,
    required this.tileHeight,
    required this.scrolls,
  });
}

/// [count]개 타일을 [width]x[height] 영역에 가능한 크게 배치하는 열 수를 고른다(줌처럼 사람 수에
/// 따라 자동). 타일 비율은 16:9·4:3·1:1 중 가장 큰 면적이 나오는 것. 한 변이 [minTileWidth]보다
/// 작아지면 스크롤 모드로 전환한다.
GalleryLayout galleryLayout({
  required int count,
  required double width,
  required double height,
  double gap = 8,
  double minTileWidth = 150,
}) {
  final n = math.max(1, count);
  GalleryLayout? best;
  double bestArea = -1;
  for (final aspect in const [16 / 9, 4 / 3, 1.0]) {
    for (var cols = 1; cols <= n; cols++) {
      final rows = (n / cols).ceil();
      final cellW = (width - gap * (cols - 1)) / cols;
      final cellH = (height - gap * (rows - 1)) / rows;
      if (cellW <= 0 || cellH <= 0) continue;
      final w = math.min(cellW, cellH * aspect);
      final area = w * (w / aspect);
      if (area > bestArea + 0.5) {
        bestArea = area;
        best = GalleryLayout(
          columns: cols,
          rows: rows,
          tileWidth: w,
          tileHeight: w / aspect,
          scrolls: false,
        );
      }
    }
  }
  if (best != null && best.tileWidth >= minTileWidth) return best;

  final cols = math.max(1, ((width + gap) / (minTileWidth + gap)).floor());
  final w = (width - gap * (cols - 1)) / cols;
  return GalleryLayout(
    columns: cols,
    rows: (n / cols).ceil(),
    tileWidth: w,
    tileHeight: w * 9 / 16,
    scrolls: true,
  );
}

// ───────────────────────── 통화 채팅 안읽음 ─────────────────────────

/// 채팅 패널을 닫아 둔 동안([since] 이후) 남이 보낸 메시지 수 — 컨트롤바 채팅 단추의 배지.
int countUnreadSince(
  Iterable<Message> messages,
  DateTime? since,
  String? myId,
) {
  if (since == null) return 0;
  var count = 0;
  for (final m in messages) {
    if (m.outOfWindow || m.deleted) continue;
    if (m.type == MessageType.system) continue;
    if (myId != null && m.senderId == myId) continue;
    if (m.createdAt.isAfter(since)) count++;
  }
  return count;
}

/// 메시지 목록에서 가장 늦은 시각(없으면 null).
DateTime? latestMessageTime(Iterable<Message> messages) {
  DateTime? latest;
  for (final m in messages) {
    if (m.outOfWindow) continue;
    if (latest == null || m.createdAt.isAfter(latest)) latest = m.createdAt;
  }
  return latest;
}
