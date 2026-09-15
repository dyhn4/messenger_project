import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/room.dart';
import '../services/session.dart';
import 'date_range_calendar_panel.dart';

/// "대화 내보내기" — 방의 대화 내용을 엑셀(.xlsx)로 받는다. 기간을 안 고르면 전체 대화.
/// 비밀 대화는 서버가 평문을 몰라서 지원하지 않으므로, 호출부(room_options_menu.dart)가
/// 그 방에서는 애초에 메뉴 자체를 감춘다.
Future<void> showExportChatDialog(
  BuildContext context,
  Session session,
  Room room,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ExportChatDialog(session: session, room: room),
  );
}

class _ExportChatDialog extends StatefulWidget {
  final Session session;
  final Room room;
  const _ExportChatDialog({required this.session, required this.room});

  @override
  State<_ExportChatDialog> createState() => _ExportChatDialogState();
}

class _ExportChatDialogState extends State<_ExportChatDialog> {
  DateTime? _start;
  DateTime? _end;
  bool _exporting = false;
  String? _error;

  String _fmt(DateTime d) =>
      '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';

  String _buildFileName() {
    final roomName = widget.room.displayName(widget.session.userId ?? '');
    // 파일 시스템에 못 쓰는 문자만 걸러낸다(Windows 기준 \/:*?"<>|).
    final safeName = roomName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    String fmt(DateTime d) =>
        '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
    final rangePart = (_start == null || _end == null)
        ? '전체'
        : '${fmt(_start!)}-${fmt(_end!)}';
    return '${safeName}_대화내역_$rangePart.xlsx';
  }

  Future<void> _export() async {
    setState(() {
      _exporting = true;
      _error = null;
    });
    try {
      final path = await widget.session.exportRoomChat(
        widget.room.id,
        since: _start,
        // 종료일은 그날 끝까지 포함하도록 23:59:59로 맞춰서 보낸다.
        until: _end == null
            ? null
            : DateTime(_end!.year, _end!.month, _end!.day, 23, 59, 59),
        fileName: _buildFileName(),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      await launchUrl(Uri.file(path), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 시작일만 고르고 종료일을 아직 안 골랐으면(기간이 반쯤 정해진 상태) 그대로 내보내기를
    // 누르지 못하게 막는다 — 그 상태로 내보내면 "시작일부터 지금까지"로 조용히 넘어가서,
    // 종료일을 마저 고르려던 사용자 의도와 어긋난다.
    final picking = _start != null && _end == null;
    return AlertDialog(
      title: const Text('대화 내보내기'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DateRangeCalendarPanel(
              start: _start,
              end: _end,
              lastDate: DateTime.now(),
              onChanged: (start, end) => setState(() {
                _start = start;
                _end = end;
                _error = null;
              }),
            ),
            const SizedBox(height: 10),
            if (picking)
              Text(
                '종료일을 선택하세요.',
                style: TextStyle(color: Theme.of(context).hintColor),
              )
            else if (_start != null && _end != null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '선택한 기간: ${_fmt(_start!)} ~ ${_fmt(_end!)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: _exporting
                        ? null
                        : () => setState(() {
                            _start = null;
                            _end = null;
                          }),
                    child: const Text('전체 기간으로'),
                  ),
                ],
              )
            else
              Text(
                '기간을 안 고르면 전체 대화를 내보냅니다.',
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _exporting ? null : () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: (_exporting || picking) ? null : _export,
          child: _exporting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('내보내기'),
        ),
      ],
    );
  }
}
