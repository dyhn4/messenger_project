import 'package:flutter/material.dart';

import 'call_logic.dart';
import 'call_stage.dart';

/// 오른쪽 패널(좁은 화면에서는 시트)의 머리줄 — 제목과 닫기 단추.
class CallPanelHeader extends StatelessWidget {
  final String title;
  final VoidCallback onClose;
  const CallPanelHeader({
    super.key,
    required this.title,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.only(left: 16, right: 4),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            tooltip: '닫기',
            icon: const Icon(Icons.close, size: 20),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// 참가자 패널 — `참가자 (N)` + 목록(손든 사람 → 말하는 사람 → 나머지). 각 줄에 아바타(말하는 중이면
/// 초록 테두리), 이름("나" 표시), 손든 표시, 화면 공유 중 표시, 마이크·카메라 켜짐/꺼짐.
class CallParticipantsPanel extends StatelessWidget {
  final List<CallPerson> people;
  final VoidCallback onClose;
  final CallUrlResolver? resolveUrl;
  const CallParticipantsPanel({
    super.key,
    required this.people,
    required this.onClose,
    this.resolveUrl,
  });

  @override
  Widget build(BuildContext context) {
    final sorted = sortForParticipantPanel(people);
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          CallPanelHeader(title: '참가자 (${people.length})', onClose: onClose),
          Expanded(
            child: sorted.isEmpty
                ? const Center(child: Text('참가자가 없습니다.'))
                : ListView.builder(
                    itemCount: sorted.length,
                    itemBuilder: (context, i) => CallParticipantRow(
                      key: ValueKey('participant-${sorted[i].id}'),
                      person: sorted[i],
                      resolveUrl: resolveUrl,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class CallParticipantRow extends StatelessWidget {
  final CallPerson person;
  final CallUrlResolver? resolveUrl;
  const CallParticipantRow({super.key, required this.person, this.resolveUrl});

  @override
  Widget build(BuildContext context) {
    final off = Theme.of(context).colorScheme.error;
    final speaking = person.speaking && person.micOn;
    return ListTile(
      dense: true,
      leading: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: speaking ? callSpeakingColor : Colors.transparent,
            width: 2,
          ),
        ),
        child: CallAvatar(person: person, radius: 15, resolveUrl: resolveUrl),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              person.isMe ? '${person.name} (나)' : person.name,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (speaking)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(
                Icons.graphic_eq,
                key: ValueKey('speaking-indicator'),
                size: 16,
                color: callSpeakingColor,
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (person.handRaised)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: CallHandBadge(size: 22),
            ),
          if (person.sharing)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Icon(
                Icons.screen_share,
                size: 18,
                color: callSpeakingColor,
              ),
            ),
          Icon(
            person.micOn ? Icons.mic : Icons.mic_off,
            size: 18,
            color: person.micOn ? null : off,
          ),
          const SizedBox(width: 8),
          Icon(
            person.camOn ? Icons.videocam : Icons.videocam_off,
            size: 18,
            color: person.camOn ? null : off,
          ),
        ],
      ),
    );
  }
}
