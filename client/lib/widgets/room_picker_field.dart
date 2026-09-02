import 'package:flutter/material.dart';

import '../models/room.dart';
import '../services/session.dart';
import 'room_avatar.dart';

/// "메시지 공유"/"메시지 전달" 화면의 "대화방" 필드 — 누르면 바로 아래에 검색창 +
/// 토픽/그룹채팅/채팅 탭 + 목록이 든 드롭다운이 뜬다(전체화면 이동 없이). 방을 고르면
/// onChanged를 부르고 드롭다운을 닫는다.
class RoomPickerField extends StatefulWidget {
  final Session session;
  final Room? value;
  final ValueChanged<Room> onChanged;
  const RoomPickerField({
    super.key,
    required this.session,
    required this.value,
    required this.onChanged,
  });

  @override
  State<RoomPickerField> createState() => _RoomPickerFieldState();
}

class _RoomPickerFieldState extends State<RoomPickerField> {
  final _fieldKey = GlobalKey();
  final _layerLink = LayerLink();
  OverlayEntry? _entry;

  @override
  void dispose() {
    _removeOverlay();
    super.dispose();
  }

  void _toggle() {
    if (_entry == null) {
      _openOverlay();
    } else {
      _removeOverlay();
    }
  }

  void _removeOverlay() {
    _entry?.remove();
    _entry = null;
    if (mounted) setState(() {});
  }

  void _openOverlay() {
    final box = _fieldKey.currentContext!.findRenderObject() as RenderBox;
    final width = box.size.width;
    _entry = OverlayEntry(
      builder: (overlayContext) => Stack(
        children: [
          // 드롭다운 바깥을 누르면 닫히는 투명 배리어 — 목록 자체는 그 위에 그려서 안 막힌다.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _removeOverlay,
            ),
          ),
          CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            offset: Offset(0, box.size.height + 4),
            child: Align(
              alignment: Alignment.topLeft,
              child: _RoomPickerDropdown(
                width: width,
                session: widget.session,
                value: widget.value,
                onSelected: (room) {
                  widget.onChanged(room);
                  _removeOverlay();
                },
              ),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_entry!);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.value?.displayName(widget.session.userId ?? '');
    return CompositedTransformTarget(
      link: _layerLink,
      child: InkWell(
        key: _fieldKey,
        borderRadius: BorderRadius.circular(8),
        onTap: _toggle,
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
              Icon(
                _entry != null ? Icons.arrow_drop_up : Icons.arrow_drop_down,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 실제 드롭다운 패널 — 검색창 + 토픽/그룹채팅/채팅 탭 + 목록. 자기만의 검색어/탭 상태를
/// 갖는다(OverlayEntry는 부모 setState로 안 다시 그려지므로 독립 StatefulWidget이어야 함).
class _RoomPickerDropdown extends StatefulWidget {
  final double width;
  final Session session;
  final Room? value;
  final ValueChanged<Room> onSelected;
  const _RoomPickerDropdown({
    required this.width,
    required this.session,
    required this.value,
    required this.onSelected,
  });

  @override
  State<_RoomPickerDropdown> createState() => _RoomPickerDropdownState();
}

class _RoomPickerDropdownState extends State<_RoomPickerDropdown> {
  final _searchController = TextEditingController();
  String _filter = '';
  RoomType _tab = RoomType.topic;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final myUserId = widget.session.userId ?? '';
    final lowerFilter = _filter.trim().toLowerCase();
    final rooms =
        widget.session.rooms
            .where((r) => r.type == _tab && !r.isSecret)
            .where(
              (r) =>
                  lowerFilter.isEmpty ||
                  r.displayName(myUserId).toLowerCase().contains(lowerFilter),
            )
            .toList()
          ..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));

    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: widget.width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '검색어를 입력하세요.',
                  prefixIcon: Icon(Icons.search, size: 18),
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _filter = v),
              ),
            ),
            Row(
              children: [
                for (final t in RoomType.values)
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(() => _tab = t),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              width: 2,
                              color: _tab == t
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.transparent,
                            ),
                          ),
                        ),
                        child: Text(
                          switch (t) {
                            RoomType.topic => '토픽',
                            RoomType.group => '그룹채팅',
                            RoomType.dm => '채팅',
                          },
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontWeight: _tab == t
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: _tab == t
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const Divider(height: 1),
            SizedBox(
              height: 180,
              child: rooms.isEmpty
                  ? Center(
                      child: Text(
                        '대화방이 없습니다.',
                        style: TextStyle(color: Theme.of(context).hintColor),
                      ),
                    )
                  : ListView.builder(
                      itemCount: rooms.length,
                      itemBuilder: (context, i) {
                        final room = rooms[i];
                        final selected = widget.value?.id == room.id;
                        return ListTile(
                          dense: true,
                          leading: _tab == RoomType.topic
                              ? const CircleAvatar(child: Icon(Icons.tag))
                              : RoomAvatar(
                                  room: room,
                                  myUserId: myUserId,
                                  resolveUrl: widget.session.resolveUrl,
                                  onlineUserIds: widget.session.onlineUserIds,
                                  size: 28,
                                ),
                          title: Text(
                            room.displayName(myUserId),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: selected
                              ? Icon(
                                  Icons.check,
                                  color: Theme.of(context).colorScheme.primary,
                                )
                              : null,
                          onTap: () => widget.onSelected(room),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
