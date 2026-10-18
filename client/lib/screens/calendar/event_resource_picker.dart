import 'package:flutter/material.dart';

import '../../models/groupware_resources.dart';
import '../../services/api_client.dart' show ApiException;
import '../../services/groupware_api.dart';
import '../../l10n/tr.dart';

/// 일정 편집 창의 "회의실·자원" 고르기 — 그룹웨어 자원 목록을 그 일정 시간의 빈 여부와 함께 보여 준다(잡힌 자원은 누가 잡았는지와 함께
/// 막아 둠). [from]·[to]는 예약이 잡을 시간(ms — 종일이면 그날 자정부터), [eventId]는 고치는 일정(자기 예약은 빈 것으로 본다).
/// 고른 자원, 그만두면 null.
Future<GroupwareResource?> showEventResourcePicker(
  BuildContext context, {
  required GroupwareApi api,
  required int from,
  required int to,
  String? eventId,
  String? selectedId,
}) => showDialog<GroupwareResource>(
  context: context,
  builder: (_) => _ResourcePickerDialog(
    api: api,
    from: from,
    to: to,
    eventId: eventId,
    selectedId: selectedId,
  ),
);

class _ResourcePickerDialog extends StatefulWidget {
  final GroupwareApi api;
  final int from;
  final int to;
  final String? eventId;
  final String? selectedId;
  const _ResourcePickerDialog({
    required this.api,
    required this.from,
    required this.to,
    this.eventId,
    this.selectedId,
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
          () => _error = e is ApiException ? trServer(e.message) : tr('자원 목록을 받지 못했습니다.'),
        );
      }
    }
  }

  String _clock(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
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
                    ListTile(
                      key: ValueKey('event-resource-${r.id}'),
                      enabled: r.busy == null,
                      selected: r.id == widget.selectedId,
                      leading: Icon(switch (r.kind) {
                        'equipment' => Icons.devices_other_outlined,
                        'vehicle' => Icons.directions_car_outlined,
                        _ => Icons.meeting_room_outlined,
                      }),
                      title: Text(r.name),
                      subtitle: Text(
                        r.busy != null
                            ? tr('예약됨 {p0}~{p1} {p2}', {
                                'p0': _clock(r.busy!.start),
                                'p1': _clock(r.busy!.end),
                                'p2': r.busy!.userName,
                              })
                            : [
                                r.kindLabel,
                                if (r.detail.isNotEmpty) r.detail,
                                tr('비어 있음'),
                              ].join(' · '),
                      ),
                      onTap: r.busy == null
                          ? () => Navigator.of(context).pop(r)
                          : null,
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
