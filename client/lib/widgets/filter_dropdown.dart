import 'package:flutter/material.dart';

import '../models/room.dart';
import '../services/session.dart';

/// 검색/파일 패널 등에서 쓰는 필터 드롭다운 버튼 — 버튼을 누르면 앵커 방식으로 오버레이
/// 패널이 뜬다. Material `DropdownMenu`는 방 필터의 토픽/채팅 탭 같은 커스텀 내용을 못 넣어서
/// `CompositedTransformTarget/Follower` + `OverlayEntry`로 직접 앵커 드롭다운을 만든다.
class FilterDropdownButton extends StatefulWidget {
  final String label;
  final bool expand;
  final Widget Function(VoidCallback close) panelBuilder;
  const FilterDropdownButton({
    super.key,
    required this.label,
    this.expand = false,
    required this.panelBuilder,
  });

  @override
  State<FilterDropdownButton> createState() => _FilterDropdownButtonState();
}

class _FilterDropdownButtonState extends State<FilterDropdownButton> {
  final _link = LayerLink();
  OverlayEntry? _entry;

  void _open() {
    final overlay = Overlay.of(context);
    _entry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _close,
            ),
          ),
          CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            offset: const Offset(0, 44),
            child: widget.panelBuilder(_close),
          ),
        ],
      ),
    );
    overlay.insert(_entry!);
    setState(() {});
  }

  void _close() {
    _entry?.remove();
    _entry = null;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _entry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final button = OutlinedButton.icon(
      onPressed: _entry == null ? _open : _close,
      // 기본은 아이콘 앞 여백이 16px(OutlinedButton.icon의 M3 기본값, 세로 패딩은 0이라
      // 높이는 그대로 minimumSize가 정한다)이라 아이콘이 왼쪽 테두리에서 좀 떨어져
      // 보였다 — 줄여서 더 붙인다.
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsetsDirectional.fromSTEB(10, 0, 0, 0),
        // OutlinedButton 기본 alignment(가운데 정렬)를 그대로 두면, expand:true로
        // 버튼이 내용보다 넓어졌을 때 아이콘+글자가 통째로 가운데로 쏠린다 — 라벨
        // 길이가 버튼마다 달라서 그만큼 왼쪽 여백도 버튼마다 달라 보이는 원인이었다.
        // 항상 왼쪽에 붙도록 고정한다.
        alignment: Alignment.centerLeft,
      ),
      icon: Icon(_entry == null ? Icons.arrow_drop_down : Icons.arrow_drop_up),
      label: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    return CompositedTransformTarget(
      link: _link,
      child: widget.expand
          ? SizedBox(width: double.infinity, child: button)
          : button,
    );
  }
}

/// 필터 패널 공통 틀(그림자+둥근모서리+크기제한). 내용만 갈아끼운다.
class FilterPanelShell extends StatelessWidget {
  final double width;
  final Widget child;
  const FilterPanelShell({super.key, required this.width, required this.child});

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: width,
          maxWidth: width,
          maxHeight: 360,
        ),
        child: child,
      ),
    );
  }
}

Widget filterSearchBox(ValueChanged<String> onChanged) {
  return Padding(
    padding: const EdgeInsets.all(8),
    child: TextField(
      decoration: const InputDecoration(
        hintText: '검색어를 입력하세요.',
        isDense: true,
        prefixIcon: Icon(Icons.search, size: 18),
        border: OutlineInputBorder(),
      ),
      onChanged: onChanged,
    ),
  );
}

IconData iconForRoomType(RoomType type) => switch (type) {
  RoomType.topic => Icons.tag,
  RoomType.group => Icons.groups_outlined,
  RoomType.dm => Icons.person_outline,
};

/// "참여 대화방" 필터. 토픽/채팅(그룹+DM) 탭으로 나눠서 보여준다 — 검색 패널과 파일 패널이
/// 공유해서 쓴다(둘 다 "내가 속한 방 중 하나를 골라 범위를 좁힌다"는 의미가 동일하다).
class RoomFilterButton extends StatelessWidget {
  final Session session;
  final String? selectedRoomId;
  final bool expand;
  final ValueChanged<String?> onSelected;
  const RoomFilterButton({
    super.key,
    required this.session,
    required this.selectedRoomId,
    this.expand = false,
    required this.onSelected,
  });

  String get _label {
    final id = selectedRoomId;
    if (id == null) return '참여 대화방';
    for (final r in session.rooms) {
      if (r.id == id) return r.displayName(session.userId ?? '');
    }
    return '참여 대화방';
  }

  @override
  Widget build(BuildContext context) {
    return FilterDropdownButton(
      label: _label,
      expand: expand,
      panelBuilder: (close) => FilterPanelShell(
        width: 260,
        child: _RoomFilterPanel(
          session: session,
          selectedRoomId: selectedRoomId,
          onSelected: (id) {
            onSelected(id);
            close();
          },
        ),
      ),
    );
  }
}

class _RoomFilterPanel extends StatefulWidget {
  final Session session;
  final String? selectedRoomId;
  final ValueChanged<String?> onSelected;
  const _RoomFilterPanel({
    required this.session,
    required this.selectedRoomId,
    required this.onSelected,
  });

  @override
  State<_RoomFilterPanel> createState() => _RoomFilterPanelState();
}

class _RoomFilterPanelState extends State<_RoomFilterPanel> {
  /// 보고 있는 탭 — 토픽 / 그룹채팅 / 채팅(1:1). 방을 골라 둔 채로 열면 그 방의 탭부터 보인다.
  late RoomType _tab =
      widget.session.rooms
          .where((r) => r.id == widget.selectedRoomId)
          .firstOrNull
          ?.type ??
      RoomType.topic;
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final myId = widget.session.userId ?? '';
    final teamId = widget.session.currentTeam?.id;
    final rooms = widget.session.rooms
        // 비밀 대화는 검색/파일 목록 자체가 안 되므로(요구사항) 방 범위 선택지에도
        // 노출하지 않는다 — 서버 쪽도 별도로 막고 있다(server/src/db/queries/messages.js).
        .where((r) => !r.isSecret)
        // 검색·파일·링크는 지금 팀 안에서만 찾으므로 다른 팀 방은 골라도 결과가 없다 — 지금 팀 방만(팀마다
        // 하나씩 있는 나와의 대화도 하나만 보인다).
        .where((r) => teamId == null || r.teamId == teamId)
        .where((r) => r.type == _tab)
        .where(
          (r) =>
              _filter.isEmpty ||
              r.displayName(myId).toLowerCase().contains(_filter.toLowerCase()),
        )
        .toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            for (final (type, label) in const [
              (RoomType.topic, '토픽'),
              (RoomType.group, '그룹채팅'),
              (RoomType.dm, '채팅'),
            ])
              _tabButton(
                context,
                label,
                _tab == type,
                () => setState(() => _tab = type),
              ),
          ],
        ),
        const Divider(height: 1),
        filterSearchBox((v) => setState(() => _filter = v)),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                dense: true,
                title: const Text('전체'),
                trailing: widget.selectedRoomId == null
                    ? const Icon(Icons.check, size: 18)
                    : null,
                onTap: () => widget.onSelected(null),
              ),
              const Divider(height: 1),
              for (final r in rooms)
                ListTile(
                  dense: true,
                  leading: Icon(iconForRoomType(r.type), size: 18),
                  title: Text(
                    r.displayName(myId),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: widget.selectedRoomId == r.id
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  onTap: () => widget.onSelected(r.id),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tabButton(
    BuildContext context,
    String label,
    bool selected,
    VoidCallback onTap,
  ) {
    final color = selected
        ? Theme.of(context).colorScheme.primary
        : Colors.transparent;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: color, width: 2)),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
