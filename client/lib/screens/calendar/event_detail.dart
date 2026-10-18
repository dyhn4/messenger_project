import 'package:flutter/material.dart';

import '../../models/calendar.dart';
import '../../services/api_client.dart' show ApiException;
import '../../services/calendar_controller.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../home_screen.dart' show wideBreakpoint;
import 'calendar_common.dart';
import 'event_editor.dart';
import 'event_resource_picker.dart' show eventResourcesOf, resourceKindIcon;
import 'recurrence_scope_dialog.dart';
import '../../l10n/tr.dart';

/// 일정을 눌렀을 때의 상세 보기 — 넓은 창(PC)은 대화상자, 좁은 창(모바일)은 아래에서 올라오는 시트.
/// 수정·삭제는 여기서 이어진다(반복 일정이면 적용 범위를 먼저 묻는다).
Future<void> showEventDetail(
  BuildContext context, {
  required Session session,
  required CalendarController controller,
  required EventOccurrence event,
}) {
  final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  // 수정·삭제 뒤 토스트와 편집기는 이 상세가 닫힌 다음에도 살아 있는 화면 context로 띄운다.
  final hostContext = context;
  Widget body(BuildContext sheetContext) => EventDetailBody(
    session: session,
    controller: controller,
    event: event,
    hostContext: hostContext,
    onClose: () => Navigator.of(sheetContext).pop(),
  );
  if (wide) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 640),
          child: body(dialogContext),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetContext) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85,
      ),
      child: body(sheetContext),
    ),
  );
}

class EventDetailBody extends StatelessWidget {
  final Session session;
  final CalendarController controller;
  final EventOccurrence event;
  final BuildContext hostContext;
  final VoidCallback onClose;

  const EventDetailBody({
    super.key,
    required this.session,
    required this.controller,
    required this.event,
    required this.hostContext,
    required this.onClose,
  });

  CalendarInfo? get _calendar => controller.calendarById(event.calendarId);

  Future<void> _edit() async {
    RecurrenceScope? scope;
    if (event.recurring) {
      scope = await showRecurrenceScopeDialog(
        hostContext,
        title: tr('반복 일정 수정'),
        confirmLabel: tr('수정'),
      );
      if (scope == null) return;
    }
    onClose();
    if (!hostContext.mounted) return;
    await showEventEditor(
      hostContext,
      session,
      controller,
      editing: event,
      scope: scope,
    );
  }

  Future<void> _delete(BuildContext context) async {
    RecurrenceScope? scope;
    if (event.recurring) {
      scope = await showRecurrenceScopeDialog(
        context,
        title: tr('반복 일정 삭제'),
        confirmLabel: tr('삭제'),
      );
      if (scope == null) return;
    } else {
      if (!context.mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(tr('일정을 삭제할까요?')),
          content: Text(
            tr('\'{p0}\' 일정이 삭제됩니다.', {'p0': eventDisplayTitle(event)}),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(tr('취소')),
            ),
            FilledButton(
              key: const ValueKey('event-delete-confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(tr('삭제')),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await controller.deleteEvent(
        event.eventId!,
        scope: scope,
        occurrenceStart: event.recurring ? event.start : null,
      );
      onClose();
      if (hostContext.mounted) showAppToast(hostContext, tr('일정을 삭제했습니다.'));
    } catch (e) {
      if (!context.mounted) return;
      showAppToast(
        context,
        e is ApiException ? trServer(e.message) : tr('일정을 삭제하지 못했습니다.'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = calendarColor(event.color);
    final calendarName =
        _calendar?.name ??
        (event.isHoliday
            ? tr('국가 공휴일')
            : event.isBirthday
            ? tr('멤버 생일')
            : event.isTrip
            ? tr('출장')
            : event.isExternal
            ? tr('외부 캘린더')
            : tr('캘린더'));
    final recurrence = event.recurrence;
    final canEdit = event.isUserEvent && event.canEdit && !event.restricted;
    final canDelete = event.isUserEvent && event.canDelete;
    // 붙은 회의실·자원 모두(예전 서버면 하나) — 종류 아이콘을 단 칩으로, 승인을 기다리는 것은 "승인 대기" 꼬리표와 함께.
    final resources = eventResourcesOf(event);

    Widget row(IconData icon, Widget child) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.hintColor),
          const SizedBox(width: 12),
          Expanded(child: child),
        ],
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
          child: Row(
            children: [
              const Spacer(),
              if (canEdit)
                IconButton(
                  key: const ValueKey('event-edit'),
                  tooltip: tr('수정하기'),
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: _edit,
                ),
              if (canDelete)
                IconButton(
                  key: const ValueKey('event-delete'),
                  tooltip: tr('삭제하기'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _delete(context),
                ),
              IconButton(
                tooltip: tr('닫기'),
                icon: const Icon(Icons.close),
                onPressed: onClose,
              ),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      margin: const EdgeInsets.only(top: 6, right: 10),
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        eventDisplayTitle(event),
                        key: const ValueKey('event-detail-title'),
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                row(
                  Icons.event_outlined,
                  Text(
                    key: const ValueKey('event-detail-calendar'),
                    calendarName,
                  ),
                ),
                row(
                  Icons.schedule,
                  Text(
                    formatEventPeriod(event),
                    key: const ValueKey('event-detail-period'),
                  ),
                ),
                if (recurrence != null)
                  row(
                    Icons.repeat,
                    Text(
                      recurrence.summary(startDay: event.firstDay),
                      key: const ValueKey('event-detail-recurrence'),
                    ),
                  ),
                if (event.restricted)
                  row(
                    Icons.lock_outline,
                    Text(
                      tr('비공개 일정입니다. 초대된 사람만 자세한 내용을 볼 수 있습니다.'),
                      style: TextStyle(color: theme.hintColor),
                    ),
                  ),
                if (!event.restricted) ...[
                  if (resources.isNotEmpty)
                    row(
                      Icons.meeting_room_outlined,
                      Wrap(
                        key: const ValueKey('event-detail-resource'),
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final r in resources) _ResourceChip(resource: r),
                        ],
                      ),
                    ),
                  // 장소가 붙은 자원 이름 중 하나와 같으면(회의실을 고르면 장소가 그 이름으로 채워진다) 한 번만 보인다.
                  if ((event.location ?? '').isNotEmpty &&
                      !resources.any((r) => r.name == event.location))
                    row(
                      Icons.place_outlined,
                      Text(
                        event.location!,
                        key: const ValueKey('event-detail-location'),
                      ),
                    ),
                  // 그룹웨어에서 승인된 출장 — 장소(위)가 출장지. 바꾸거나 취소하는 건 그룹웨어 결재에서.
                  if (event.isTrip)
                    row(
                      Icons.flight_takeoff,
                      Text(
                        tr('그룹웨어 → 결재에서 승인된 출장입니다. 바꾸거나 취소하려면 그곳에서 하세요.'),
                        key: const ValueKey('event-detail-trip'),
                        style: TextStyle(color: theme.hintColor),
                      ),
                    ),
                  // 그룹웨어에서 바로 잡은 회의실 예약 — 바꾸기·취소는 그룹웨어 "예약" 탭에서.
                  if (event.isBooking)
                    row(
                      Icons.info_outline,
                      Text(
                        tr('그룹웨어 → 예약에서 잡은 예약입니다. 바꾸거나 취소하려면 그곳에서 하세요.'),
                        key: const ValueKey('event-detail-booking'),
                        style: TextStyle(color: theme.hintColor),
                      ),
                    ),
                  if ((event.description ?? '').isNotEmpty)
                    row(Icons.notes, SelectableText(event.description!)),
                  if (event.attendees.isNotEmpty)
                    row(
                      Icons.people_outline,
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final a in event.attendees)
                            Chip(
                              label: Text(a.name),
                              visualDensity: VisualDensity.compact,
                            ),
                        ],
                      ),
                    ),
                  if (event.isUserEvent)
                    row(
                      event.isPrivate ? Icons.lock_outline : Icons.public,
                      Text(
                        event.isPrivate
                            ? tr('비공개 (초대된 사람만 자세히 볼 수 있음)')
                            : tr('공개'),
                        key: const ValueKey('event-detail-visibility'),
                      ),
                    ),
                  // 외부 캘린더(ICS 구독)에서 받아 온 일정 — 여기서는 고칠 수 없다.
                  if (event.isExternal)
                    row(
                      Icons.cloud_download_outlined,
                      Text(
                        tr(
                          '외부 캘린더에서 가져온 일정입니다. 고치려면 원래 캘린더(Google·Outlook 등)에서 고치세요.',
                        ),
                        key: const ValueKey('event-detail-external'),
                        style: TextStyle(color: theme.hintColor),
                      ),
                    ),
                  if ((event.creatorName ?? '').isNotEmpty && event.isUserEvent)
                    row(
                      Icons.person_outline,
                      Text(
                        tr('만든 사람: {event.creatorName}', {
                          'event.creatorName': event.creatorName,
                        }),
                        key: const ValueKey('event-detail-creator'),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 상세의 회의실·자원 칩 하나 — 종류 아이콘 + 이름, 관리자 승인을 기다리는 예약(`pending`)이면 이름 뒤에 "승인 대기" 꼬리표.
/// 좁은 창(360px)에서도 넘치지 않게 이름은 한 줄로 줄인다.
class _ResourceChip extends StatelessWidget {
  final EventResource resource;
  const _ResourceChip({required this.resource});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Chip(
      key: ValueKey('event-detail-resource-${resource.resourceId}'),
      visualDensity: VisualDensity.compact,
      avatar: Icon(resourceKindIcon(resource.kind), size: 18),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              resource.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (resource.pending) ...[
            const SizedBox(width: 6),
            Container(
              key: ValueKey(
                'event-detail-resource-pending-${resource.resourceId}',
              ),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                tr('승인 대기'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
