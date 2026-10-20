import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/room.dart';
import '../services/app_platform.dart';
import '../services/session.dart';
import 'room_avatar.dart';
import '../l10n/tr.dart';

/// "메시지 공유"/"메시지 전달" 화면의 "대화방" 필드 — 누르면 바로 아래에 검색창 +
/// 토픽/그룹채팅/채팅 탭 + 목록이 든 드롭다운이 뜬다(전체화면 이동 없이). 방을 고르면
/// onChanged를 부르고 드롭다운을 닫는다.
class RoomPickerField extends StatefulWidget {
  final Session session;
  final Room? value;
  final ValueChanged<Room> onChanged;

  /// 고를 수 있는 방만 남긴다(없으면 비밀 대화를 뺀 모든 방) — 공유·전달 화면이 보드 뷰 토픽과
  /// 내가 글을 쓸 수 없는 토픽을 빼는 데 쓴다.
  final bool Function(Room room)? filter;

  /// 비밀 대화도 목록에 넣는다(다른 앱에서 공유하기 — 보낼 때 이 기기에서 암호화한다). 기본은 뺀다.
  final bool includeSecret;

  /// 여러 방을 고르는 화면(공유하기)이 이미 고른 방 — 목록에 체크로 보인다. 칸에는 [value] 대신 [placeholder]가 보인다.
  final Set<String> selectedIds;
  final String? placeholder;
  const RoomPickerField({
    super.key,
    required this.session,
    required this.value,
    required this.onChanged,
    this.filter,
    this.includeSecret = false,
    this.selectedIds = const {},
    this.placeholder,
  });

  @override
  State<RoomPickerField> createState() => _RoomPickerFieldState();
}

class _RoomPickerFieldState extends State<RoomPickerField> {
  final _fieldKey = GlobalKey();
  final _layerLink = LayerLink();

  /// 목록을 닫으면 포커스를 이 칸으로 되돌린다 — 목록의 검색창은 창 밖(Overlay)에 있어서, 그냥 닫으면
  /// 포커스가 사라져 이 칸이 든 창의 단축키(Esc·Ctrl+Enter)가 먹지 않았다.
  final _focusNode = FocusNode(debugLabel: 'room-picker-field');
  OverlayEntry? _entry;

  @override
  void dispose() {
    // 떠 있던 드롭다운만 치운다 — 사라지는 중에 setState를 부르면(_removeOverlay) 디버그
    // 단언(defunct element)이 난다(공유·전달 창을 닫을 때마다).
    _entry?.remove();
    _entry = null;
    _focusNode.dispose();
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
    final wasOpen = _entry != null;
    _entry?.remove();
    _entry = null;
    if (!mounted) return;
    setState(() {});
    if (wasOpen) _focusNode.requestFocus();
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
                filter: widget.filter,
                includeSecret: widget.includeSecret,
                selectedIds: widget.selectedIds,
                onSelected: (room) {
                  widget.onChanged(room);
                  _removeOverlay();
                },
                onDismiss: _removeOverlay,
              ),
            ),
          ),
        ],
      ),
    );
    // 앱 맨 위(루트) Overlay에 — 바깥을 누르면 닫히는 막이 창 전체를 덮게(PC 할 일 패널 안 생성 화면에서 열어도 채팅 쪽을
    // 누르면 닫히고 그 누름은 아래로 가지 않는다). 목록은 칸 바로 아래·칸 폭이라 자리는 그대로다. 다른 화면은 가장 가까운
    // Overlay가 곧 루트라 예전과 같다.
    Overlay.of(context, rootOverlay: true).insert(_entry!);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.value?.displayName(widget.session.userId ?? '');
    return CompositedTransformTarget(
      link: _layerLink,
      child: InkWell(
        key: _fieldKey,
        focusNode: _focusNode,
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
                  label ?? widget.placeholder ?? tr('대화방 선택'),
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
  final bool Function(Room room)? filter;
  final bool includeSecret;
  final Set<String> selectedIds;
  final ValueChanged<Room> onSelected;
  final VoidCallback onDismiss;
  const _RoomPickerDropdown({
    required this.width,
    required this.session,
    required this.value,
    required this.filter,
    required this.includeSecret,
    required this.selectedIds,
    required this.onSelected,
    required this.onDismiss,
  });

  @override
  State<_RoomPickerDropdown> createState() => _RoomPickerDropdownState();
}

class _RoomPickerDropdownState extends State<_RoomPickerDropdown> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'room-picker-search');
  String _filter = '';

  /// 골라 둔 방이 있으면 그 방의 탭부터 보여준다(나와의 대화를 골라 뒀으면 채팅 탭).
  late RoomType _tab = widget.value?.type ?? RoomType.topic;

  @override
  void initState() {
    super.initState();
    // PC는 목록을 열자마자 검색어를 칠 수 있게(Esc로 닫기도) 검색창에 포커스를 옮긴다 — 이 목록은
    // 대화상자 밖(Overlay)에 떠서 autofocus만으로는 포커스가 오지 않는다. 휴대폰은 화상 키보드가
    // 목록을 가리지 않게 누를 때만.
    if (AppPlatform.isWindows || AppPlatform.isMacOS || AppPlatform.isLinux) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final myUserId = widget.session.userId ?? '';
    final teamId = widget.session.currentTeam?.id;
    final lowerFilter = _filter.trim().toLowerCase();
    final rooms =
        widget.session.rooms
            .where(
              (r) => r.type == _tab && (widget.includeSecret || !r.isSecret),
            )
            // session.rooms엔 다른 팀 방도 다 들어 있다 — 다른 목록 화면처럼 지금 팀 방만 보여 준다(팀마다
            // 하나씩 있는 나와의 대화가 여러 줄로 겹쳐 보이지 않게).
            .where((r) => teamId == null || r.teamId == teamId)
            .where((r) => widget.filter?.call(r) ?? true)
            .where(
              (r) =>
                  lowerFilter.isEmpty ||
                  r.displayName(myUserId).toLowerCase().contains(lowerFilter),
            )
            .toList()
          // 나와의 대화는 채팅 탭 맨 위에 둔다(사이드바처럼) — 나머지는 최근 활동 순.
          ..sort((a, b) {
            if (a.isSelf != b.isSelf) return a.isSelf ? -1 : 1;
            return b.lastActivityAt.compareTo(a.lastActivityAt);
          });

    // 목록이 떠 있는 동안 Esc는 목록만 닫는다 — 이 목록은 대화상자 밖(Overlay)에 떠 있어서, 그냥
    // 두면 아무도 Esc를 받지 않는다.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onDismiss,
      },
      child: _buildPanel(context, rooms, myUserId),
    );
  }

  Widget _buildPanel(BuildContext context, List<Room> rooms, String myUserId) {
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
                focusNode: _searchFocus,
                autofocus: true,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: tr('검색어를 입력하세요.'),
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
                            RoomType.topic => tr('토픽'),
                            RoomType.group => tr('그룹채팅'),
                            RoomType.dm => tr('채팅'),
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
                        tr('대화방이 없습니다.'),
                        style: TextStyle(color: Theme.of(context).hintColor),
                      ),
                    )
                  : ListView.builder(
                      itemCount: rooms.length,
                      itemBuilder: (context, i) {
                        final room = rooms[i];
                        final selected =
                            widget.value?.id == room.id ||
                            widget.selectedIds.contains(room.id);
                        return ListTile(
                          dense: true,
                          leading: _tab == RoomType.topic
                              ? CircleAvatar(
                                  child: Icon(
                                    room.isBoard
                                        ? Icons.dashboard_outlined
                                        : Icons.tag,
                                  ),
                                )
                              : RoomAvatar(
                                  room: room,
                                  myUserId: myUserId,
                                  resolveUrl: widget.session.resolveUrl,
                                  onlineUserIds: widget.session.onlineUserIds,
                                  size: 28,
                                ),
                          title: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  room.displayName(myUserId),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (room.isSecret) ...[
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.lock,
                                  size: 14,
                                  color: Colors.green.shade700,
                                  semanticLabel: tr('비밀 대화'),
                                ),
                              ],
                            ],
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
