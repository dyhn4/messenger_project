import '../../../services/session.dart';
import '../calendar_common.dart';
import 'calendar_create.dart';
import 'calendar_management_common.dart';
import 'calendar_settings.dart';
import 'calendar_subscribe.dart';

/// 캘린더 관리 화면 묶음(새 캘린더·설정·구독·나에게만 삭제·삭제)을 [CalendarManagementHooks]에 연결한다.
///
/// 훅은 (context, controller, calendar)만 받는데 멤버 고르기는 [Session]이 필요해서, 세션을 붙들고 있는
/// 훅 묶음을 만들어 CalendarScreen 기본값으로 쓴다.
CalendarManagementHooks buildCalendarManagementHooks(Session session) {
  return CalendarManagementHooks(
    onCreateCalendar: (context, controller) =>
        createCalendarFlow(context, session, controller),
    onSearchSubscribe: (context, controller) =>
        showCalendarSubscribe(context, controller),
    onOpenSettings: (context, controller, calendar) =>
        showCalendarSettings(context, session, controller, calendar),
    onLeave: (context, controller, calendar) async {
      await leaveCalendarFlow(context, controller, calendar);
    },
    onDelete: (context, controller, calendar) async {
      await deleteCalendarFlow(context, controller, calendar);
    },
  );
}
