import 'package:flutter/material.dart';

import '../../models/calendar.dart';
import '../../models/groupware_resources.dart';
import '../../services/api_client.dart' show ApiException;
import '../../services/groupware_api.dart';
import '../../l10n/tr.dart';

/// 일정 하나에 붙일 수 있는 회의실·자원 수(서버 규약 — calendars.js·groupwareResources.js syncEventResources와 같다).
const kEventResourcesMax = 5;

/// 자원 종류 아이콘 — 회의실(기본)·장비·차량. 편집 창 칩·고르기 목록·상세가 같이 쓴다.
IconData resourceKindIcon(String kind) => switch (kind) {
  'equipment' => Icons.devices_other_outlined,
  'vehicle' => Icons.directions_car_outlined,
  _ => Icons.meeting_room_outlined,
};

/// 일정에 붙은 회의실·자원 모두 — 새 서버는 [EventOccurrence.resources], 예전 서버(또는 그 칸 없이 만든 일정)는
/// [EventOccurrence.resource] 하나를 목록으로 돌려준다. 붙은 게 없으면 빈 목록.
List<EventResource> eventResourcesOf(EventOccurrence e) =>
    e.resources.isNotEmpty ? e.resources : [?e.resource];

/// 일정 편집 창의 "회의실·자원" 고르기 — 그룹웨어 자원 목록을 그 일정 시간의 빈 여부와 함께 보여 준다(잡힌 자원은 누가 잡았는지와 함께,
/// 내가 예약할 수 없는 자원(`canBook` false)은 그렇다고 적어 막아 둠 — 관리자 승인이 필요한 자원은 "승인 필요"를 붙여 고를 수는 있게).
/// [from]·[to]는 예약이 잡을 시간(ms — 종일이면 그날 자정부터), [eventId]는 고치는 일정(자기 예약은 빈 것으로 본다).
/// [selectedIds]는 이미 붙인 자원 — 체크 표시와 함께 막아 둬 같은 자원을 두 번 붙이지 않게 한다.
/// 한 번에 하나를 고르고 창이 닫힌다(여러 개는 편집 창의 "추가"를 다시 눌러 붙인다). 고른 자원, 그만두면 null.
Future<GroupwareResource?> showEventResourcePicker(
  BuildContext context, {
  required GroupwareApi api,
  required int from,
  required int to,
  String? eventId,
  Set<String> selectedIds = const {},
}) => showDialog<GroupwareResource>(
  context: context,
  builder: (_) => _ResourcePickerDialog(
    api: api,
    from: from,
    to: to,
    eventId: eventId,
    selectedIds: selectedIds,
  ),
);

/// 일정 편집 창의 "회의실 추천" — 그 시간([start]~[end] ms)에 비어 있고 내가 잡을 수 있으며 [attendees]명(나 포함)이 들어가는 회의실을
/// 알맞은 크기부터(남는 자리가 적은 것부터 — 서버 resourcePolicy.js suggestResources) 보여 준다. 줄마다 수용 인원·남는 자리·
/// 승인 필요 여부. [eventId]는 고치는 일정(그 일정에 붙은 예약은 빈 것으로 본다), [selectedIds]는 이미 붙인 자원(체크 표시 — 막음).
/// 고른 회의실, 그만두면 null.
Future<GroupwareResource?> showEventResourceSuggest(
  BuildContext context, {
  required GroupwareApi api,
  required int start,
  required int end,
  required int attendees,
  String? eventId,
  Set<String> selectedIds = const {},
}) => showDialog<GroupwareResource>(
  context: context,
  builder: (_) => _ResourceSuggestDialog(
    api: api,
    start: start,
    end: end,
    attendees: attendees,
    eventId: eventId,
    selectedIds: selectedIds,
  ),
);

class _ResourcePickerDialog extends StatefulWidget {
  final GroupwareApi api;
  final int from;
  final int to;
  final String? eventId;
  final Set<String> selectedIds;
  const _ResourcePickerDialog({
    required this.api,
    required this.from,
    required this.to,
    this.eventId,
    this.selectedIds = const {},
  });

  @override
  State<_ResourcePickerDialog> createState() => _ResourcePickerDialogState();
}

class _ResourcePickerDialogState extends State<_ResourcePickerDialog> {
  List<GroupwareResource>? _resources;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.api.resources(
        from: widget.from,
        to: widget.to,
        eventId: widget.eventId,
      );
      if (mounted) {
        setState(
          () => _resources = [
            for (final r in list)
              if (r.enabled) r,
          ],
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ApiException
              ? trServer(e.message)
              : tr('자원 목록을 받지 못했습니다.'),
        );
      }
    }
  }

  String _clock(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  /// 줄 아래 글 — 잡힌 자원은 누가 언제 잡았는지, 못 잡는 자원은 그 까닭, 아니면 "종류 · 위치·인원 · 비어 있음 (· 승인 필요)".
  String _subtitle(GroupwareResource r) {
    if (r.busy case final busy?) {
      return tr('예약됨 {p0}~{p1} {p2}', {
        'p0': _clock(busy.start),
        'p1': _clock(busy.end),
        'p2': busy.userName,
      });
    }
    if (!r.canBook) {
      return [r.kindLabel, tr('예약할 수 있는 사람이 정해진 자원입니다.')].join(' · ');
    }
    return [
      r.kindLabel,
      if (r.detail.isNotEmpty) r.detail,
      tr('비어 있음'),
      if (r.needsApproval) tr('승인 필요'),
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final resources = _resources;
    final hint = Theme.of(context).hintColor;
    return AlertDialog(
      title: Text(tr('회의실·자원')),
      content: SizedBox(
        width: 400,
        child: resources == null
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: _error != null
                      ? Text(_error!)
                      : const CircularProgressIndicator(),
                ),
              )
            : resources.isEmpty
            ? Text(
                tr('예약할 수 있는 회의실·자원이 없습니다. 그룹웨어 관리자가 관리 탭에서 더할 수 있습니다.'),
                style: TextStyle(color: hint),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final r in resources)
                    _resourceTile(
                      context,
                      key: ValueKey('event-resource-${r.id}'),
                      resource: r,
                      subtitle: _subtitle(r),
                      selected: widget.selectedIds.contains(r.id),
                      enabled: r.busy == null && r.canBook,
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
      ],
    );
  }
}

/// 고르기·추천 창이 같이 쓰는 자원 한 줄 — 이미 붙인 것([selected])은 체크 표시와 함께, [enabled]가 false면 흐리게 막아 둔다.
/// 누르면 그 자원으로 창을 닫는다.
Widget _resourceTile(
  BuildContext context, {
  required Key key,
  required GroupwareResource resource,
  required String subtitle,
  required bool selected,
  required bool enabled,
}) => ListTile(
  key: key,
  enabled: enabled && !selected,
  selected: selected,
  leading: Icon(resourceKindIcon(resource.kind)),
  title: Text(resource.name, maxLines: 1, overflow: TextOverflow.ellipsis),
  subtitle: Text(subtitle),
  trailing: selected ? const Icon(Icons.check) : null,
  onTap: enabled && !selected
      ? () => Navigator.of(context).pop(resource)
      : null,
);

class _ResourceSuggestDialog extends StatefulWidget {
  final GroupwareApi api;
  final int start;
  final int end;
  final int attendees;
  final String? eventId;
  final Set<String> selectedIds;
  const _ResourceSuggestDialog({
    required this.api,
    required this.start,
    required this.end,
    required this.attendees,
    this.eventId,
    this.selectedIds = const {},
  });

  @override
  State<_ResourceSuggestDialog> createState() => _ResourceSuggestDialogState();
}

class _ResourceSuggestDialogState extends State<_ResourceSuggestDialog> {
  List<GroupwareResource>? _rooms;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.api.suggestResources(
        start: widget.start,
        end: widget.end,
        attendees: widget.attendees,
        kind: 'room',
        eventId: widget.eventId,
      );
      if (mounted) setState(() => _rooms = list);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ApiException
              ? trServer(e.message)
              : tr('추천할 회의실을 받지 못했습니다.'),
        );
      }
    }
  }

  /// "3층 · 12명 · 4자리 남음 · 승인 필요" — 위치·수용 인원, 남는 자리(모르면 뺌), 승인 필요 여부.
  String _subtitle(GroupwareResource r) => [
    if (r.detail.isNotEmpty) r.detail,
    if (r.spare != null) tr('{n}자리 남음', {'n': r.spare}),
    if (r.needsApproval) tr('승인 필요'),
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final rooms = _rooms;
    final hint = Theme.of(context).hintColor;
    return AlertDialog(
      title: Text(tr('회의실 추천')),
      content: SizedBox(
        width: 400,
        child: rooms == null
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: _error != null
                      ? Text(_error!)
                      : const CircularProgressIndicator(),
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('{n}명이 쓸 수 있고 이 시간에 비어 있는 회의실 — 알맞은 크기부터 보여 줍니다.', {
                      'n': widget.attendees,
                    }),
                    style: TextStyle(color: hint),
                  ),
                  const SizedBox(height: 8),
                  if (rooms.isEmpty)
                    Text(
                      tr('이 시간에 쓸 수 있는 회의실이 없습니다. 시간이나 참석자를 바꿔 보세요.'),
                      key: const ValueKey('event-resource-suggest-empty'),
                    )
                  else
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final r in rooms)
                            _resourceTile(
                              context,
                              key: ValueKey('event-resource-suggest-${r.id}'),
                              resource: r,
                              subtitle: _subtitle(r),
                              selected: widget.selectedIds.contains(r.id),
                              enabled: r.canBook,
                            ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
      ],
    );
  }
}
