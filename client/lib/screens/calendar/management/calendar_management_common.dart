import 'package:flutter/material.dart';

import '../../../models/calendar.dart';
import '../../../services/api_client.dart' show ApiException;
import '../../../services/calendar_controller.dart';
import '../../../widgets/app_toast.dart';
import '../../../widgets/floating_dialog.dart';
import '../../home_screen.dart' show wideBreakpoint;

/// 캘린더 관리 화면들이 같이 쓰는 조각 — 반응형 창 틀, 확인 대화상자, 결과 토스트, 나에게만 삭제·삭제 흐름.

/// 서버 에러(`{error}`)는 그대로, 그 밖의 예외는 [fallback] 문구로.
String calendarErrorText(Object e, String fallback) =>
    e is ApiException ? e.message : fallback;

/// 관리 대화상자를 넓은 화면(PC)에서는 가운데 뜨는 창으로, 좁은 화면(모바일)에서는 전체 화면으로 연다.
/// [child]는 스스로 스크롤되는 본문이고, 닫을 때 `Navigator.pop(값)`으로 결과를 돌려준다.
Future<T?> showCalendarSheet<T>(
  BuildContext context, {
  required String title,
  required Widget child,
  double maxWidth = 520,
}) {
  if (MediaQuery.sizeOf(context).width >= wideBreakpoint) {
    return showDialog<T>(
      context: context,
      builder: (_) =>
          FloatingDialog(title: title, maxWidth: maxWidth, child: child),
    );
  }
  return Navigator.of(context).push<T>(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: SafeArea(
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    ),
  );
}

/// 확인 대화상자 — [destructive]면 확인 버튼을 빨갛게. 확인하면 true.
Future<bool> confirmCalendarAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = true,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: SizedBox(width: 340, child: Text(message)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('cal-confirm-ok'),
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(dialogContext).colorScheme.error,
                  foregroundColor: Theme.of(dialogContext).colorScheme.onError,
                )
              : null,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok == true;
}

/// 미리 잡아 둔 [OverlayState]로 결과를 알리는 토스트 — 삭제·나가기 직후에는 부른 쪽 화면 조각(목록 항목,
/// 설정 창)이 사라져 context를 못 쓰기 때문이다.
class CalendarNotifier {
  final OverlayState? _overlay;
  CalendarNotifier._(this._overlay);

  factory CalendarNotifier.of(BuildContext context) =>
      CalendarNotifier._(Overlay.maybeOf(context, rootOverlay: true));

  void call(String message) {
    final overlay = _overlay;
    if (overlay != null && overlay.mounted) {
      showAppToastOnOverlay(overlay, message);
    }
  }
}

/// "나에게만 삭제"(공유 캘린더 멤버) / "구독 취소"(구독자) — 확인 후 내 목록에서만 뺀다. 지웠으면 true.
Future<bool> leaveCalendarFlow(
  BuildContext context,
  CalendarController controller,
  CalendarInfo calendar,
) async {
  final notify = CalendarNotifier.of(context);
  final subscriber = calendar.isSubscriber;
  final ok = await confirmCalendarAction(
    context,
    title: subscriber ? '구독 취소' : '나에게만 삭제',
    message: subscriber
        ? "'${calendar.name}' 캘린더 구독을 취소할까요?\n취소해도 언제든 다시 구독할 수 있어요."
        : "'${calendar.name}' 캘린더를 내 목록에서만 삭제할까요?\n다른 멤버에게는 그대로 남아 있고, 캘린더 관리자가 다시 추가하면 볼 수 있어요.",
    confirmLabel: subscriber ? '구독 취소' : '나에게만 삭제',
  );
  if (!ok) return false;
  try {
    await controller.leaveCalendar(calendar.id);
    notify(subscriber ? '구독을 취소했습니다.' : '캘린더를 내 목록에서 삭제했습니다.');
    return true;
  } catch (e) {
    notify(calendarErrorText(e, '처리하지 못했습니다. 잠시 후 다시 시도하세요.'));
    return false;
  }
}

/// 캘린더 삭제(소유자) — 모든 일정도 함께 지워진다는 경고를 보여 주고 확인받는다. 지웠으면 true.
Future<bool> deleteCalendarFlow(
  BuildContext context,
  CalendarController controller,
  CalendarInfo calendar,
) async {
  final notify = CalendarNotifier.of(context);
  final ok = await confirmCalendarAction(
    context,
    title: '캘린더 삭제',
    message:
        "'${calendar.name}' 캘린더를 삭제할까요?\n캘린더에 등록된 모든 일정도 함께 삭제되고, 멤버와 구독자에게서도 사라져요. 삭제한 캘린더는 되돌릴 수 없어요.",
    confirmLabel: '삭제',
  );
  if (!ok) return false;
  try {
    await controller.deleteCalendar(calendar.id);
    notify('캘린더를 삭제했습니다.');
    return true;
  } catch (e) {
    notify(calendarErrorText(e, '캘린더를 삭제하지 못했습니다. 잠시 후 다시 시도하세요.'));
    return false;
  }
}
