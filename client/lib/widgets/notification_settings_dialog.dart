import 'package:flutter/material.dart';

import '../models/app_notification.dart';
import '../services/notification_controller.dart';
import '../services/session.dart';
import 'app_toast.dart';
import 'muted_scrollbar.dart';

/// 알림 센터 톱니 — 내 알림 설정: 탭별 "안 읽은 알림만 표시"(이 기기에만 저장), `@all 알림 받기` 스위치와
/// 보드 알림 수준(전체 / 중요 알림 / 새 글 알림 — 서버에 저장). 고르는 즉시 저장하고(서버 값은 실패하면
/// 되돌리고 알린다) 닫기만 누르면 된다.
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
  /// 내용이 창에 다 안 들어갈 때 오른쪽 모서리에 그리는 스크롤바와 내용 스크롤이 같이 쓰는 컨트롤러.
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

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

  /// 탭별 "안 읽은 알림만 표시" — 켜면 그 탭 목록에서 읽은 알림이 빠진다(읽은 알림은 지워지지 않고, 끄면
  /// 다시 보인다). 안 읽은 대화 탭은 원래 안 읽은 것만 보여 주므로 고르는 대상이 아니다. 서버 설정과 달리
  /// 이 기기에만 저장돼서 서버 설정을 받아 오는 중이어도 바로 켜고 끌 수 있다.
  Widget _buildUnreadOnlySection(
    BuildContext context,
    NotificationController center,
    Color hint,
  ) {
    const tabs = [
      NotificationTab.all,
      NotificationTab.mention,
      NotificationTab.board,
      NotificationTab.project,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('안 읽은 알림만 표시', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(
          '켠 탭에서는 읽은 알림을 목록에서 숨깁니다. 이 기기에만 적용돼요.',
          style: TextStyle(fontSize: 12, color: hint),
        ),
        for (final tab in tabs)
          SwitchListTile(
            key: ValueKey('notif-setting-unread-only-${tab.name}'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(tab.label),
            value: center.unreadOnly(tab),
            onChanged: (v) => center.setUnreadOnly(tab, v),
          ),
      ],
    );
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
          // 스크롤바가 대화상자 오른쪽 모서리에 붙도록 오른쪽 안쪽 여백(기본 24)을 스크롤 영역 안으로 옮긴다.
          // 내용이 다 보이면 스크롤바는 그려지지 않는다(넘칠 때만 나타난다).
          contentPadding: const EdgeInsets.only(top: 20),
          content: SizedBox(
            width: 428,
            child: MutedScrollbar(
              controller: _scroll,
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildUnreadOnlySection(context, center, hint),
                    const Divider(height: 24),
                    body,
                  ],
                ),
              ),
            ),
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
