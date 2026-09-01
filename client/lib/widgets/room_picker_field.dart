import 'package:flutter/material.dart';

import '../models/room.dart';
import '../screens/room_picker_screen.dart';
import '../services/session.dart';

/// "메시지 공유"/"메시지 전달" 화면의 "대화방" 필드 — 누르면 RoomPickerScreen(토픽/그룹채팅/
/// 채팅 탭)이 전체 화면으로 뜨고, 고른 방을 돌려받는다.
class RoomPickerField extends StatelessWidget {
  final Session session;
  final Room? value;
  final ValueChanged<Room> onChanged;
  const RoomPickerField({
    super.key,
    required this.session,
    required this.value,
    required this.onChanged,
  });

  Future<void> _pick(BuildContext context) async {
    final room = await Navigator.of(context).push<Room>(
      MaterialPageRoute(builder: (_) => RoomPickerScreen(session: session)),
    );
    if (room != null) onChanged(room);
  }

  @override
  Widget build(BuildContext context) {
    final label = value?.displayName(session.userId ?? '');
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _pick(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label ?? '대화방 선택',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: label == null
                    ? TextStyle(color: Theme.of(context).hintColor)
                    : null,
              ),
            ),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}
