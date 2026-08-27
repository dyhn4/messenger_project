import 'package:flutter/material.dart';

import '../models/room.dart';
import '../services/session.dart';
import 'floating_dialog.dart';

/// 1초~1주 범위를 슬라이더 대신 프리셋으로 고르게 한다 — 로그 스케일 범위라 슬라이더는
/// 끝쪽(1초~수십초)에서 손가락 정밀도가 안 나온다.
const _presets = <(String, int?)>[
  ('끄기', null),
  ('1초', 1),
  ('5초', 5),
  ('30초', 30),
  ('1분', 60),
  ('5분', 5 * 60),
  ('1시간', 60 * 60),
  ('1일', 24 * 60 * 60),
  ('1주', 7 * 24 * 60 * 60),
];

/// 비밀 대화 자동 삭제 타이머 설정 다이얼로그. RoomOptionsMenu의 "자동 삭제 타이머" 항목에서 연다.
class SelfDestructPickerDialog extends StatefulWidget {
  final Session session;
  final Room room;
  const SelfDestructPickerDialog({
    super.key,
    required this.session,
    required this.room,
  });

  @override
  State<SelfDestructPickerDialog> createState() =>
      _SelfDestructPickerDialogState();
}

class _SelfDestructPickerDialogState extends State<SelfDestructPickerDialog> {
  bool _saving = false;

  Future<void> _select(int? seconds) async {
    setState(() => _saving = true);
    try {
      await widget.session.setSecretChatTimer(widget.room, seconds);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('설정에 실패했습니다: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.room.secretSelfDestructSeconds;
    return FloatingDialog(
      title: '자동 삭제 타이머',
      maxHeight: 460,
      child: _saving
          ? const Center(child: CircularProgressIndicator())
          : RadioGroup<int?>(
              groupValue: current,
              onChanged: _select,
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final (label, seconds) in _presets)
                    RadioListTile<int?>(
                      contentPadding: EdgeInsets.zero,
                      value: seconds,
                      title: Text(label),
                    ),
                ],
              ),
            ),
    );
  }
}
