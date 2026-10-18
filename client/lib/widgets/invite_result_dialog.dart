import 'package:flutter/material.dart';

import '../models/room.dart';
import '../services/session.dart';
import 'floating_dialog.dart';
import 'room_avatar.dart';
import '../l10n/tr.dart';

/// "초대 완료" 창을 연다 — 멤버 초대하기(토픽·그룹채팅 한 곳)와 여러 토픽/그룹채팅에 초대가 같이 쓴다.
/// 어느 대화방에 누가 초대됐는지, 이미 참여 중이던 사람, 초대하지 못한 사람(사유)을 방별로 보여 준다.
/// "확인"(또는 ✕·Esc)으로 닫힌다.
Future<void> showInviteResultDialog(
  BuildContext context, {
  required Session session,
  required List<RoomInviteResult> results,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => InviteResultDialog(session: session, results: results),
  );
}

/// 한 줄에 이름을 몇 명까지 적는지 — 넘으면 "외 N명".
const inviteResultNamesMax = 3;

/// 이름 목록 문구 — 길면 앞의 몇 명만 적고 "외 N명".
String inviteNamesText(List<InvitePerson> people) {
  final shown = people.take(inviteResultNamesMax).map((p) => p.name).join(', ');
  final rest = people.length - inviteResultNamesMax;
  return rest > 0
      ? tr('{shown} 외 {rest}명', {'shown': shown, 'rest': rest})
      : shown;
}

/// "N개 대화방에 M명을 초대했습니다" 요약 — 새로 초대된 사람이 없으면 그렇게 알린다.
String inviteResultSummary(List<RoomInviteResult> results) {
  final invitedRooms = results.where((r) => r.hasInvited).length;
  final invitedPeople = {
    for (final r in results)
      if (r.error == null)
        for (final p in r.invited) p.userId,
  }.length;
  if (invitedRooms == 0) return tr('새로 초대된 멤버가 없습니다');
  return tr('{invitedRooms}개 대화방에 {invitedPeople}명을 초대했습니다', {
    'invitedRooms': invitedRooms,
    'invitedPeople': invitedPeople,
  });
}

class InviteResultDialog extends StatelessWidget {
  final Session session;
  final List<RoomInviteResult> results;
  const InviteResultDialog({
    super.key,
    required this.session,
    required this.results,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final skipped = results.where((r) => r.error != null).length;
    return FloatingDialog(
      title: tr('초대 완료'),
      maxWidth: 560,
      maxHeight: 680,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.check_circle,
                size: 22,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  inviteResultSummary(results),
                  key: const ValueKey('invite-result-summary'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (skipped > 0) ...[
            const SizedBox(height: 6),
            Text(
              tr('{skipped}개 대화방은 초대하지 못했습니다.', {'skipped': skipped}),
              key: const ValueKey('invite-result-skipped'),
              style: TextStyle(fontSize: 13, color: theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 14),
          Flexible(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: theme.dividerColor),
                borderRadius: BorderRadius.circular(8),
              ),
              clipBehavior: Clip.antiAlias,
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: results.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) =>
                    _ResultTile(session: session, result: results[i]),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton(
              key: const ValueKey('invite-result-confirm'),
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(),
              child: Text(tr('확인')),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  final Session session;
  final RoomInviteResult result;
  const _ResultTile({required this.session, required this.result});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final room = session.roomById(result.roomId);
    final type = result.roomType ?? room?.type;
    final name = (result.roomName ?? '').isNotEmpty
        ? result.roomName!
        : (room?.displayName(session.userId ?? '') ?? tr('(알 수 없음)'));
    final error = result.errorText;
    return Padding(
      key: ValueKey('invite-result-room-${result.roomId}'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InviteRoomLeading(session: session, room: room, type: type),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 300),
                      child: Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (type != null) InviteRoomTypeChip(type: type),
                  ],
                ),
                const SizedBox(height: 4),
                if (error != null)
                  Text(
                    error,
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.error,
                    ),
                  )
                else ...[
                  if (result.invited.isNotEmpty)
                    _line(
                      context,
                      label: tr('초대됨'),
                      text: inviteNamesText(result.invited),
                    ),
                  if (result.alreadyMembers.isNotEmpty)
                    _line(
                      context,
                      label: tr('이미 참여중'),
                      text: inviteNamesText(result.alreadyMembers),
                      muted: true,
                    ),
                  for (final p in result.failed)
                    _line(
                      context,
                      label: tr('실패'),
                      text: '${p.name} — ${p.reason ?? tr('초대하지 못했습니다.')}',
                      error: true,
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _line(
    BuildContext context, {
    required String label,
    required String text,
    bool muted = false,
    bool error = false,
  }) {
    final theme = Theme.of(context);
    final color = error
        ? theme.colorScheme.error
        : muted
        ? theme.hintColor
        : null;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label  ',
              style: TextStyle(fontWeight: FontWeight.w600, color: color),
            ),
            TextSpan(text: text),
          ],
        ),
        style: TextStyle(fontSize: 13, color: color),
      ),
    );
  }
}

/// 대화방 줄의 아바타 — 토픽은 # 아이콘, 그룹채팅은 그룹 아이콘/멤버 사진(방을 알 때). 선택 창·초대 완료 창이 같이 쓴다.
class InviteRoomLeading extends StatelessWidget {
  final Session session;
  final Room? room;
  final RoomType? type;
  final double size;
  const InviteRoomLeading({
    super.key,
    required this.session,
    required this.room,
    required this.type,
    this.size = 32,
  });

  @override
  Widget build(BuildContext context) {
    final room = this.room;
    if (type == RoomType.group && room != null) {
      return RoomAvatar(
        room: room,
        myUserId: session.userId ?? '',
        resolveUrl: session.resolveUrl,
        onlineUserIds: const {},
        size: size,
      );
    }
    return CircleAvatar(
      radius: size / 2,
      child: Icon(
        type == RoomType.group
            ? Icons.groups_outlined
            : (room?.isBoard ?? false)
            ? Icons.dashboard_outlined
            : Icons.tag,
        size: size * 0.55,
      ),
    );
  }
}

/// "토픽"/"그룹채팅" 작은 칩.
class InviteRoomTypeChip extends StatelessWidget {
  final RoomType type;
  const InviteRoomTypeChip({super.key, required this.type});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        type == RoomType.topic ? tr('토픽') : tr('그룹채팅'),
        style: TextStyle(
          fontSize: 11,
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}
