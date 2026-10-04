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
/// 초록 테두리), 이름("나"·"진행자" 표시), 손든 표시, 화면 공유 중 표시, 마이크·카메라 켜짐/꺼짐.
///
/// [onToggleMic]을 주면 마이크 표시가 단추가 된다 — 내 줄은 누구나(내 마이크), 다른 사람 줄은 내가 진행자일 때
/// ([canControlOthers])만 눌러서 그 사람의 마이크를 끄거나, 꺼져 있으면 켜 달라고 요청한다.
class CallParticipantsPanel extends StatelessWidget {
  final List<CallPerson> people;
  final VoidCallback onClose;
  final CallUrlResolver? resolveUrl;
  final bool canControlOthers;
  final void Function(CallPerson person)? onToggleMic;
  const CallParticipantsPanel({
    super.key,
    required this.people,
    required this.onClose,
    this.resolveUrl,
    this.canControlOthers = false,
    this.onToggleMic,
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
                    itemBuilder: (context, i) {
                      final person = sorted[i];
                      final toggle = onToggleMic;
                      final canToggle =
                          toggle != null && (person.isMe || canControlOthers);
                      return CallParticipantRow(
                        key: ValueKey('participant-${person.id}'),
                        person: person,
                        resolveUrl: resolveUrl,
                        onToggleMic: canToggle ? () => toggle(person) : null,
                      );
                    },
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

  /// 있으면 마이크 표시가 눌리는 단추가 된다(내 마이크, 또는 진행자가 다른 사람의 마이크).
  final VoidCallback? onToggleMic;
  const CallParticipantRow({
    super.key,
    required this.person,
    this.resolveUrl,
    this.onToggleMic,
  });

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
          if (person.isHost)
            Container(
              key: const ValueKey('host-badge'),
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '진행자',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.primary,
                ),
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
          _micIndicator(context, off),
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

  /// 마이크 켜짐/꺼짐 — 바꿀 수 있으면 눌리는 단추(툴팁으로 무엇이 바뀌는지 알린다).
  Widget _micIndicator(BuildContext context, Color off) {
    final icon = Icon(
      person.micOn ? Icons.mic : Icons.mic_off,
      size: 18,
      color: person.micOn ? null : off,
    );
    final toggle = onToggleMic;
    if (toggle == null) return icon;
    // 다른 사람의 마이크는 끄기만 바로 되고, 켜기는 그 사람에게 요청한다(본인이 수락해야 켜진다).
    final tooltip = person.isMe
        ? (person.micOn ? '내 마이크 끄기' : '내 마이크 켜기')
        : (person.micOn
              ? '${person.name}님의 마이크 끄기'
              : '${person.name}님에게 마이크 켜기 요청');
    return IconButton(
      key: ValueKey('participant-mic-${person.id}'),
      tooltip: tooltip,
      onPressed: toggle,
      icon: icon,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      padding: EdgeInsets.zero,
    );
  }
}
