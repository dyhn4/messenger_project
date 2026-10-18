import 'package:flutter/material.dart';

import '../../models/calendar.dart';
import '../../services/api_client.dart' show ApiException;
import '../../services/calendar_controller.dart';
import '../../widgets/app_toast.dart';
import 'calendar_common.dart';
import 'external_calendar_dialogs.dart';
import '../../l10n/tr.dart';

/// 캘린더 목록 — 데스크톱은 왼쪽 열, 모바일은 서랍. "나의 캘린더"(기본·팀·내가 만든/속한 shared)와
/// "구독 캘린더"(국가 공휴일·멤버 생일·구독한 캘린더) 두 묶음이고, 각 항목의 체크박스로 내 화면에서
/// 보이기/숨기기를 토글한다. ⋯ 메뉴의 색 변경은 여기서 처리하고, 설정·구독 취소·삭제와 두 "+"는
/// [CalendarManagementHooks]로 넘긴다. 그 아래 "외부 캘린더"(Google·Outlook 등의 ICS 구독 — 나에게만 보인다)와
/// "내 일정 내보내기"(ICS 구독 주소)는 external_calendar_dialogs.dart가 처리한다.
class CalendarListPanel extends StatelessWidget {
  final CalendarController controller;
  final CalendarManagementHooks hooks;

  const CalendarListPanel({
    super.key,
    required this.controller,
    required this.hooks,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final theme = Theme.of(context);
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _SectionHeader(
              title: tr('나의 캘린더'),
              showAdd: !controller.isGuest,
              addKey: const ValueKey('cal-add-mine'),
              addTooltip: tr('새 캘린더 만들기'),
              onAdd: () {
                final hook = hooks.onCreateCalendar;
                if (hook == null) {
                  CalendarManagementHooks.notConnected(
                    context,
                    tr('새 캘린더 만들기'),
                  );
                } else {
                  hook(context, controller);
                }
              },
            ),
            if (!controller.calendarsLoaded && controller.error != null)
              _LoadError(
                message: controller.error!,
                onRetry: controller.loadCalendars,
              )
            else if (!controller.calendarsLoaded)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              for (final c in controller.mine)
                _CalendarTile(
                  calendar: c,
                  controller: controller,
                  hooks: hooks,
                ),
            const SizedBox(height: 8),
            Divider(height: 1, color: theme.dividerColor),
            _SectionHeader(
              title: tr('구독 캘린더'),
              showAdd: !controller.isGuest,
              addKey: const ValueKey('cal-add-subscribed'),
              addTooltip: tr('구독할 캘린더 찾기'),
              onAdd: () {
                final hook = hooks.onSearchSubscribe;
                if (hook == null) {
                  CalendarManagementHooks.notConnected(context, tr('캘린더 구독'));
                } else {
                  hook(context, controller);
                }
              },
            ),
            for (final c in controller.subscribedGroup)
              _CalendarTile(calendar: c, controller: controller, hooks: hooks),
            const SizedBox(height: 8),
            Divider(height: 1, color: theme.dividerColor),
            // 외부 캘린더 구독은 나에게만 보이는 개인 설정이라 준회원도 쓸 수 있다.
            _SectionHeader(
              title: tr('외부 캘린더'),
              showAdd: controller.teamId != null,
              addKey: const ValueKey('cal-add-external'),
              addTooltip: tr('외부 캘린더 추가 (Google·Outlook 등)'),
              onAdd: () => showAddExternalCalendarDialog(context, controller),
            ),
            for (final c in controller.external)
              _CalendarTile(calendar: c, controller: controller, hooks: hooks),
            ListTile(
              key: const ValueKey('cal-export-feed'),
              dense: true,
              contentPadding: const EdgeInsets.only(left: 20, right: 16),
              leading: Icon(Icons.ios_share, size: 18, color: theme.hintColor),
              minLeadingWidth: 20,
              title: Text(tr('내 일정 내보내기 (ICS 주소)')),
              enabled: controller.teamId != null,
              onTap: () => showCalendarFeedDialog(context, controller),
            ),
          ],
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String addTooltip;
  final Key addKey;
  final VoidCallback onAdd;

  /// 준회원에게는 "+"를 감춘다(새 캘린더 만들기·구독은 정회원 이상).
  final bool showAdd;
  const _SectionHeader({
    required this.title,
    required this.addTooltip,
    required this.addKey,
    required this.onAdd,
    required this.showAdd,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.hintColor,
              ),
            ),
          ),
          if (showAdd)
            IconButton(
              key: addKey,
              tooltip: addTooltip,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add, size: 20),
              onPressed: onAdd,
            )
          else
            const SizedBox(height: 40),
        ],
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _LoadError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message, style: TextStyle(color: Theme.of(context).hintColor)),
          TextButton(onPressed: onRetry, child: Text(tr('다시 시도'))),
        ],
      ),
    );
  }
}

enum _CalAction { color, settings, leave, delete, refresh, unsubscribe }

class _CalendarTile extends StatelessWidget {
  final CalendarInfo calendar;
  final CalendarController controller;
  final CalendarManagementHooks hooks;
  const _CalendarTile({
    required this.calendar,
    required this.controller,
    required this.hooks,
  });

  Future<void> _toggle(BuildContext context, bool visible) async {
    try {
      await controller.setHidden(calendar, !visible);
    } catch (e) {
      if (context.mounted) {
        showAppToast(
          context,
          e is ApiException ? trServer(e.message) : tr('캘린더 표시를 바꾸지 못했습니다.'),
        );
      }
    }
  }

  Future<void> _changeColor(BuildContext context) async {
    final hex = await showCalendarColorPicker(context, current: calendar.color);
    if (hex == null || hex.toUpperCase() == calendar.color.toUpperCase()) {
      return;
    }
    try {
      await controller.setColor(calendar, hex);
    } catch (e) {
      if (context.mounted) {
        showAppToast(
          context,
          e is ApiException ? trServer(e.message) : tr('색을 바꾸지 못했습니다.'),
        );
      }
    }
  }

  void _onAction(BuildContext context, _CalAction action) {
    switch (action) {
      case _CalAction.color:
        _changeColor(context);
      case _CalAction.settings:
        final hook = hooks.onOpenSettings;
        hook == null
            ? CalendarManagementHooks.notConnected(context, tr('캘린더 설정'))
            : hook(context, controller, calendar);
      case _CalAction.leave:
        final hook = hooks.onLeave;
        hook == null
            ? CalendarManagementHooks.notConnected(
                context,
                calendar.isSubscriber ? tr('구독 취소') : tr('나에게만 삭제'),
              )
            : hook(context, controller, calendar);
      case _CalAction.delete:
        final hook = hooks.onDelete;
        hook == null
            ? CalendarManagementHooks.notConnected(context, tr('캘린더 삭제'))
            : hook(context, controller, calendar);
      case _CalAction.refresh:
        refreshExternalCalendarNow(context, controller, calendar);
      case _CalAction.unsubscribe:
        confirmRemoveExternalCalendar(context, controller, calendar);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = calendarColor(calendar.color);
    final hasLeave =
        !calendar.isBuiltin &&
        (calendar.isSubscriber ||
            (calendar.isSharedMember && !calendar.canDelete));
    // 관리자가 아닌 멤버·구독자도 설정 화면을 열어 읽기 전용으로 볼 수 있다(색 변경만 활성).
    // 팀 캘린더는 설정이 없어 색 변경만 있다.
    final external = calendar.isExternal;
    final hasSettings =
        !calendar.isBuiltin && !external && calendar.kind != 'team';
    final hasDelete = !calendar.isBuiltin && !external && calendar.canDelete;
    final status = external ? externalStatusLabel(calendar) : '';
    final hasMenu = !calendar.isBuiltin;
    return InkWell(
      onTap: () => _toggle(context, calendar.hidden),
      child: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Row(
          children: [
            Checkbox(
              key: ValueKey('cal-check-${calendar.id}'),
              value: !calendar.hidden,
              activeColor: color,
              side: BorderSide(color: color, width: 2),
              visualDensity: VisualDensity.compact,
              onChanged: (v) => _toggle(context, v ?? false),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    calendar.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: calendar.hidden ? theme.hintColor : null,
                    ),
                  ),
                  // 외부 캘린더: 어디서 받는지·언제 받았는지, 실패했으면 그 이유.
                  if (status.isNotEmpty)
                    Text(
                      status,
                      key: ValueKey('cal-status-${calendar.id}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: calendar.lastError != null
                            ? theme.colorScheme.error
                            : theme.hintColor,
                      ),
                    ),
                ],
              ),
            ),
            if (hasMenu)
              PopupMenuButton<_CalAction>(
                key: ValueKey('cal-menu-${calendar.id}'),
                tooltip: tr('더보기'),
                icon: const Icon(Icons.more_horiz, size: 20),
                padding: EdgeInsets.zero,
                onSelected: (a) => _onAction(context, a),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: _CalAction.color,
                    child: Text(tr('색 변경')),
                  ),
                  if (hasSettings)
                    PopupMenuItem(
                      value: _CalAction.settings,
                      child: Text(tr('캘린더 설정')),
                    ),
                  if (hasLeave)
                    PopupMenuItem(
                      value: _CalAction.leave,
                      child: Text(
                        calendar.isSubscriber ? tr('구독 취소') : tr('나에게만 삭제'),
                      ),
                    ),
                  if (hasDelete)
                    PopupMenuItem(
                      value: _CalAction.delete,
                      child: Text(tr('삭제')),
                    ),
                  if (external) ...[
                    PopupMenuItem(
                      value: _CalAction.refresh,
                      child: Text(tr('지금 새로고침')),
                    ),
                    PopupMenuItem(
                      value: _CalAction.unsubscribe,
                      child: Text(tr('구독 해지')),
                    ),
                  ],
                ],
              )
            else
              const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}
