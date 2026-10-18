import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../widgets/avatar_utils.dart';
import 'call_logic.dart';
import 'call_snapshot.dart';
import '../../l10n/tr.dart';

/// 말하는 중 표시(테두리)와 줌 느낌의 어두운 타일 배경.
const callSpeakingColor = Color(0xFF2ECC71);
const callTileColor = Color(0xFF2B2B2E);
const callStageColor = Color(0xFF1C1C1E);
const callHandColor = Color(0xFFFFB300);

/// 사진 아바타의 서버 상대 경로를 절대 주소로 바꾸는 함수(Session.resolveUrl).
typedef CallUrlResolver = String Function(String relative);

/// 통화 화면의 영상 영역 — 갤러리 보기(균등 격자) 또는 스피커 보기(큰 메인 + 작은 썸네일 줄).
///
/// 스피커 보기의 메인은 다른 사람의 화면 공유가 있으면 그것, 없으면 지금 말하는 사람이다.
/// 말하는 사람이 바뀌어도 [SpeakerFocus]의 유지 시간(1.5초) 동안은 메인이 바뀌지 않는다.
class CallStage extends StatefulWidget {
  final List<CallTileData> tiles;

  /// 말하는 사람 id(목소리 큰 순).
  final List<String> speakingIds;
  final CallViewMode mode;
  final CallUrlResolver? resolveUrl;

  /// 시험에서 시계를 쥐고 흔들 수 있게 한다.
  final DateTime Function() now;

  const CallStage({
    super.key,
    required this.tiles,
    required this.speakingIds,
    required this.mode,
    this.resolveUrl,
    this.now = DateTime.now,
  });

  @override
  State<CallStage> createState() => _CallStageState();
}

class _CallStageState extends State<CallStage> {
  final SpeakerFocus _focus = SpeakerFocus();
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  CallTileData? _pickMain() {
    final tiles = widget.tiles;
    if (tiles.isEmpty) return null;
    for (final t in tiles) {
      if (t.isScreenShare && !t.person.isMe) return t;
    }
    final cameraTiles = tiles.where((t) => !t.isScreenShare).toList();
    if (cameraTiles.isEmpty) return tiles.first;
    final self = cameraTiles.where((t) => t.person.isMe);
    final mainId = _focus.update(
      now: widget.now(),
      available: [for (final t in cameraTiles) t.person.id],
      speakingIds: widget.speakingIds,
      selfId: self.isEmpty ? null : self.first.person.id,
    );
    final pending = _focus.pendingDelay;
    if (pending != null) {
      _timer?.cancel();
      _timer = Timer(pending + const Duration(milliseconds: 20), () {
        if (mounted) setState(() {});
      });
    }
    return cameraTiles.firstWhere(
      (t) => t.person.id == mainId,
      orElse: () => cameraTiles.first,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tiles = widget.tiles;
    if (tiles.isEmpty) return const SizedBox.shrink();
    if (widget.mode == CallViewMode.gallery) {
      return CallGallery(tiles: tiles, resolveUrl: widget.resolveUrl);
    }
    final main = _pickMain()!;
    return CallSpeakerLayout(
      main: main,
      others: [
        for (final t in tiles)
          if (t.key != main.key) t,
      ],
      resolveUrl: widget.resolveUrl,
    );
  }
}

/// 갤러리 보기 — 사람 수에 맞춰 열 수를 자동으로 잡는 균등 격자. 너무 많으면 스크롤.
class CallGallery extends StatelessWidget {
  final List<CallTileData> tiles;
  final CallUrlResolver? resolveUrl;
  const CallGallery({super.key, required this.tiles, this.resolveUrl});

  static const _pad = 8.0;
  static const _gap = 8.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final layout = galleryLayout(
          count: tiles.length,
          width: box.maxWidth - _pad * 2,
          height: box.maxHeight - _pad * 2,
          gap: _gap,
        );
        // 소수점 오차로 마지막 열이 다음 줄로 밀리지 않게 내림한다.
        final w = layout.tileWidth.floorToDouble();
        final h = layout.tileHeight.floorToDouble();
        final wrap = Wrap(
          alignment: WrapAlignment.center,
          runAlignment: WrapAlignment.center,
          spacing: _gap,
          runSpacing: _gap,
          children: [
            for (final t in tiles)
              SizedBox(
                key: ValueKey('gallery-${t.key}'),
                width: w,
                height: h,
                child: CallVideoTile(tile: t, resolveUrl: resolveUrl),
              ),
          ],
        );
        if (layout.scrolls) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(_pad),
            child: SizedBox(width: double.infinity, child: wrap),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(_pad),
          child: Center(child: wrap),
        );
      },
    );
  }
}

/// 스피커 보기 — 큰 메인 타일 하나 + 나머지는 작은 썸네일 줄(가로 화면은 오른쪽 세로 줄,
/// 세로 화면은 위쪽 가로 줄). 썸네일은 스크롤된다.
class CallSpeakerLayout extends StatelessWidget {
  final CallTileData main;
  final List<CallTileData> others;
  final CallUrlResolver? resolveUrl;
  const CallSpeakerLayout({
    super.key,
    required this.main,
    required this.others,
    this.resolveUrl,
  });

  static const _thumbW = 176.0;
  static const _thumbH = 99.0; // 16:9
  static const _gap = 8.0;

  Widget _mainTile() => CallVideoTile(
    key: ValueKey('main-${main.key}'),
    tile: main,
    resolveUrl: resolveUrl,
  );

  @override
  Widget build(BuildContext context) {
    if (others.isEmpty) {
      return Padding(padding: const EdgeInsets.all(8), child: _mainTile());
    }
    return LayoutBuilder(
      builder: (context, box) {
        final landscape = box.maxWidth >= box.maxHeight;
        final thumbs = ListView.separated(
          key: const ValueKey('speaker-thumbnails'),
          scrollDirection: landscape ? Axis.vertical : Axis.horizontal,
          itemCount: others.length,
          separatorBuilder: (_, _) => const SizedBox(width: _gap, height: _gap),
          itemBuilder: (context, i) => SizedBox(
            key: ValueKey('thumb-${others[i].key}'),
            width: _thumbW,
            height: _thumbH,
            child: CallVideoTile(
              tile: others[i],
              compact: true,
              resolveUrl: resolveUrl,
            ),
          ),
        );
        if (landscape) {
          return Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(child: _mainTile()),
                const SizedBox(width: _gap),
                SizedBox(width: _thumbW, child: thumbs),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              SizedBox(height: _thumbH, child: thumbs),
              const SizedBox(height: _gap),
              Expanded(child: _mainTile()),
            ],
          ),
        );
      },
    );
  }
}

/// 영상 타일 하나 — 어두운 배경, 이름 라벨(왼쪽 아래, 반투명 검정), 마이크 꺼짐 아이콘,
/// 말하는 중이면 초록 테두리, 손든 사람이면 오른쪽 위 손 배지. 영상이 없으면 아바타.
class CallVideoTile extends StatelessWidget {
  final CallTileData tile;
  final bool compact;
  final CallUrlResolver? resolveUrl;
  const CallVideoTile({
    super.key,
    required this.tile,
    this.compact = false,
    this.resolveUrl,
  });

  @override
  Widget build(BuildContext context) {
    final person = tile.person;
    final track = tile.track;
    final isShare = tile.isScreenShare;
    final speaking = person.speaking && person.micOn && !isShare;
    final label = isShare
        ? tr('{person.name}의 화면 공유', {'person.name': person.name})
        : person.isMe
        ? tr('{person.name} (나)', {'person.name': person.name})
        : person.name;

    Widget content;
    if (isShare && person.isMe) {
      // 내 화면을 내 화면에 비추면 거울 속 거울이 된다 — 안내만 띄운다.
      content = Center(
        child: Text(
          tr('내 화면을 공유하고 있습니다'),
          style: TextStyle(color: Colors.white70, fontSize: 14),
        ),
      );
    } else if (track != null) {
      content = lk.VideoTrackRenderer(
        track,
        // 화면 공유는 잘리면 안 되니 전체가 보이게(contain), 얼굴은 꽉 차게(cover).
        fit: isShare ? lk.VideoViewFit.contain : lk.VideoViewFit.cover,
      );
    } else {
      content = LayoutBuilder(
        builder: (context, box) {
          final radius = (box.biggest.shortestSide * 0.22).clamp(14.0, 56.0);
          return Center(
            child: CallAvatar(
              person: person,
              radius: radius,
              resolveUrl: resolveUrl,
            ),
          );
        },
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: callTileColor,
        borderRadius: BorderRadius.circular(8),
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: speaking
            ? Border.all(color: callSpeakingColor, width: 3)
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          content,
          Positioned(
            left: compact ? 4 : 8,
            bottom: compact ? 4 : 8,
            right: compact ? 4 : 8,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 6 : 8,
                  vertical: compact ? 1 : 3,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isShare)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(
                          Icons.screen_share,
                          size: 14,
                          color: Colors.white,
                        ),
                      )
                    else if (!person.micOn)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(
                          Icons.mic_off,
                          size: 14,
                          color: Color(0xFFFF6B6B),
                        ),
                      ),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: compact ? 11 : 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (person.handRaised && !isShare)
            Positioned(
              top: compact ? 4 : 8,
              left: compact ? 4 : 8,
              child: CallHandBadge(size: compact ? 20 : 28),
            ),
        ],
      ),
    );
  }
}

/// 손든 표시 — 노란 동그라미 안의 손.
class CallHandBadge extends StatelessWidget {
  final double size;
  const CallHandBadge({super.key, this.size = 28});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: callHandColor,
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.front_hand, size: size * 0.6, color: Colors.black87),
    );
  }
}

/// 참가자 아바타 — 방 멤버 정보가 있으면 그 아바타, 없으면 이름 첫 글자.
class CallAvatar extends StatelessWidget {
  final CallPerson person;
  final double radius;
  final CallUrlResolver? resolveUrl;
  const CallAvatar({
    super.key,
    required this.person,
    required this.radius,
    this.resolveUrl,
  });

  @override
  Widget build(BuildContext context) {
    final user = person.user;
    if (user != null) {
      return AvatarView(
        username: person.name,
        avatarType: user.avatarType,
        avatarEmoji: user.avatarEmoji,
        avatarColor: user.avatarColor,
        avatarUrl: user.avatarUrl,
        resolveUrl: resolveUrl,
        radius: radius,
      );
    }
    final initial = person.name.isEmpty ? '?' : person.name.characters.first;
    return CircleAvatar(
      radius: radius,
      backgroundColor: Colors
          .primaries[person.id.hashCode.abs() % Colors.primaries.length]
          .shade700,
      child: Text(
        initial,
        style: TextStyle(color: Colors.white, fontSize: radius * 0.9),
      ),
    );
  }
}

/// 컨트롤바 위에 잠깐 뜨는 안내(예: "○○님이 손을 들었습니다").
/// 진행자가 마이크를 켜 달라고 요청했을 때 영상 위쪽에 뜨는 안내 띠 — [마이크 켜기] / [그대로 두기]. 답할 때까지
/// 남아 있고, 스스로 마이크를 켜도 사라진다.
class CallMicRequestBanner extends StatelessWidget {
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  const CallMicRequestBanner({
    super.key,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('call-mic-request'),
      color: const Color(0xF0323232),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 6,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.mic, size: 18, color: callSpeakingColor),
                SizedBox(width: 8),
                Flexible(
                  child: Text(
                    tr('진행자가 마이크를 켜 달라고 요청했습니다'),
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  key: const ValueKey('call-mic-request-decline'),
                  onPressed: onDecline,
                  style: TextButton.styleFrom(foregroundColor: Colors.white70),
                  child: Text(tr('그대로 두기')),
                ),
                const SizedBox(width: 4),
                FilledButton.icon(
                  key: const ValueKey('call-mic-request-accept'),
                  onPressed: onAccept,
                  style: FilledButton.styleFrom(
                    backgroundColor: callSpeakingColor,
                    foregroundColor: Colors.black87,
                  ),
                  icon: const Icon(Icons.mic, size: 16),
                  label: Text(tr('마이크 켜기')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class CallToast extends StatelessWidget {
  final String message;

  /// 손들기 알림이면 노란 손, 그 밖의 알림(들어옴·나감·진행자가 마이크를 끔 등)은 정보 아이콘.
  final bool hand;
  const CallToast({super.key, required this.message, this.hand = true});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xE6323232),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          hand
              ? const Icon(Icons.front_hand, size: 16, color: callHandColor)
              : const Icon(Icons.info_outline, size: 16, color: Colors.white70),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
