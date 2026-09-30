import 'package:flutter/material.dart';

import '../models/app_notification.dart';
import '../services/notification_controller.dart';
import '../services/session.dart';
import 'app_toast.dart';

/// 알림 센터 톱니 — 내 알림 설정: `@all 알림 받기` 스위치와 보드 알림 수준(전체 / 중요 알림 / 새 글 알림).
/// 고르는 즉시 서버에 저장하고(실패하면 되돌리고 알린다) 닫기만 누르면 된다.
Future<void> showNotificationSettingsDialog(
  BuildContext context,
  Session session,
) {
  return showDialog<void>(
    context: context,
    builder: (_) =>
        NotificationSettingsDialog(center: session.notificationCenter),
  );
}

class NotificationSettingsDialog extends StatefulWidget {
  final NotificationController center;
  const NotificationSettingsDialog({super.key, required this.center});

  @override
  State<NotificationSettingsDialog> createState() =>
      _NotificationSettingsDialogState();
}

class _NotificationSettingsDialogState
    extends State<NotificationSettingsDialog> {
  @override
  void initState() {
    super.initState();
    // 받기 시작할 때 컨트롤러가 바로 알리므로(로딩 표시) 빌드가 끝난 뒤에 시작한다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.center.settings == null) {
        widget.center.loadSettings();
      }
    });
  }

  Future<void> _save({bool? mentionAll, BoardNotifyLevel? boardLevel}) async {
    try {
      await widget.center.updateSettings(
        mentionAll: mentionAll,
        boardLevel: boardLevel,
      );
    } catch (e) {
      if (mounted) showAppToast(context, '알림 설정을 저장하지 못했습니다: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.center,
      builder: (context, _) {
        final center = widget.center;
        final settings = center.settings;
        final hint = Theme.of(context).hintColor;
        Widget body;
        if (settings == null) {
          body = center.settingsError != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(center.settingsError!),
                    TextButton(
                      onPressed: center.loadSettings,
                      child: const Text('다시 시도'),
                    ),
                  ],
                )
              : const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
        } else {
          body = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                key: const ValueKey('notif-setting-mention-all'),
                contentPadding: EdgeInsets.zero,
                title: const Text('@all 알림 받기'),
                subtitle: Text(
                  '끄면 @all 멘션의 푸시 알림을 받지 않습니다. 알림 센터에는 그대로 남습니다.',
                  style: TextStyle(fontSize: 12, color: hint),
                ),
                value: settings.mentionAll,
                onChanged: (v) => _save(mentionAll: v),
              ),
              const Divider(height: 24),
              Text('보드 알림', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              RadioGroup<BoardNotifyLevel>(
                groupValue: settings.boardLevel,
                onChanged: (v) {
                  if (v != null) _save(boardLevel: v);
                },
                child: Column(
                  children: [
                    for (final level in BoardNotifyLevel.values)
                      RadioListTile<BoardNotifyLevel>(
                        key: ValueKey('notif-setting-board-${level.wire}'),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: level,
                        title: Text(level.label),
                        subtitle: Text(
                          level.description,
                          style: TextStyle(fontSize: 12, color: hint),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        }
        return AlertDialog(
          title: const Text('알림 설정'),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(child: body),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('닫기'),
            ),
          ],
        );
      },
    );
  }
}
