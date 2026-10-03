import 'package:flutter/material.dart';

import '../models/room.dart';
import '../services/api_client.dart' show ApiException;
import '../services/session.dart';
import '../widgets/floating_dialog.dart';
import 'new_group_dialog.dart' show GroupFormLabel, GroupFormNotice;

/// 되돌릴 수 없다는 경고 — 전환 대화상자 맨 위에 늘 보인다.
const convertToTopicWarning =
    '토픽으로 전환하면 다시 그룹채팅으로 되돌릴 수 없습니다. 비공개 토픽으로 전환되며 전환한 사람이 토픽 관리자가 됩니다. '
    '대화 내용은 그대로 유지됩니다.';

/// "토픽으로 전환" 대화상자를 연다 — 그룹채팅 '채팅 정보 변경' 창의 단추가 부른다. 토픽 이름(필수)과 설명을 받아
/// 전환하고, 전환됐으면 true를 돌려준다(취소·닫기면 false).
Future<bool> showConvertToTopicDialog(
  BuildContext context,
  Session session,
  Room room,
) async {
  final converted = await showDialog<bool>(
    context: context,
    builder: (_) => ConvertToTopicDialog(session: session, room: room),
  );
  return converted == true;
}

class ConvertToTopicDialog extends StatefulWidget {
  final Session session;
  final Room room;
  const ConvertToTopicDialog({
    super.key,
    required this.session,
    required this.room,
  });

  @override
  State<ConvertToTopicDialog> createState() => _ConvertToTopicDialogState();
}

class _ConvertToTopicDialogState extends State<ConvertToTopicDialog> {
  // 그룹채팅에 이미 이름·설명이 있으면 그걸 시작값으로 — 그대로 전환해도 된다.
  late final _name = TextEditingController(text: widget.room.name ?? '');
  late final _description = TextEditingController(
    text: widget.room.description ?? '',
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  bool get _canSubmit => _name.text.trim().isNotEmpty && !_saving;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.session.convertGroupToTopic(
        widget.room,
        name: _name.text,
        description: _description.text,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is ApiException
            ? e.message
            : '토픽으로 전환하지 못했습니다. 잠시 후 다시 시도하세요.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: FloatingDialog(
        title: '토픽으로 전환',
        maxWidth: 480,
        maxHeight: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const GroupFormNotice(
                      key: ValueKey('convert-topic-warning'),
                      icon: Icons.warning_amber_outlined,
                      text: convertToTopicWarning,
                    ),
                    const SizedBox(height: 16),
                    const GroupFormLabel('토픽 이름'),
                    TextField(
                      key: const ValueKey('convert-topic-name'),
                      controller: _name,
                      autofocus: true,
                      enabled: !_saving,
                      maxLength: topicNameMaxLength,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText: '토픽 이름을 입력하세요',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 8),
                    const GroupFormLabel('설명', optional: true),
                    TextField(
                      key: const ValueKey('convert-topic-description'),
                      controller: _description,
                      enabled: !_saving,
                      maxLength: topicDescriptionMaxLength,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: '어떤 이야기를 나누는 토픽인지 적어 주세요',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      GroupFormNotice(
                        key: const ValueKey('convert-topic-error'),
                        icon: Icons.error_outline,
                        text: _error!,
                        error: true,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: const Text('취소'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('convert-topic-submit'),
                  onPressed: _canSubmit ? _submit : null,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('전환'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
