import 'package:flutter/material.dart';

import '../../models/calendar.dart';
import '../../services/calendar_move.dart';
import 'calendar_common.dart';

/// 일정 드래그 이동의 공통 조각 — 끌 수 있는 일정에 씌우는 [EventDragSource]와, 끄는 동안 포인터를 따라다니는
/// 작은 칩. 놓일 자리 계산(어느 날짜 칸/시간인지)과 고스트 그리기는 보기마다 달라서 월간·시간표가 각자 한다.

/// 이 반복 일정에 마우스를 올렸을 때 보이는 안내.
const kRecurringDragHint = '반복 일정은 상세에서 수정하세요';

/// 드래그 이벤트를 보기에 알리는 콜백 묶음. 시작·갱신에는 포인터의 전역 좌표가 담긴다.
class EventDragHandle {
  /// [downPosition]은 누른 자리(전역 좌표) — 여러 날 막대의 어느 날을 잡았는지, 블록의 어디를 잡았는지 알려 준다.
  final void Function(EventOccurrence event, Offset downPosition) onStart;
  final void Function(EventOccurrence event, Offset position) onUpdate;

  /// 놓았다(취소 포함). 마지막 [onUpdate]의 위치가 놓인 자리다.
  final void Function(EventOccurrence event) onEnd;

  const EventDragHandle({
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
  });
}

/// 터치 기기(안드로이드·iOS)는 스크롤과 겹치지 않게 길게 눌러야 끌린다 — 마우스는 눌러서 바로 끈다.
bool _isTouchPlatform(BuildContext context) {
  switch (Theme.of(context).platform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return true;
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
      return false;
  }
}

/// [event]를 끌 수 있게 [builder]가 만든 위젯을 감싼다.
///  - 끌 수 있는 일정([canDragEvent])이고 [handle]이 있으면 끌린다.
///  - 반복 일정은 끌리지 않고, 올리면 일반 커서와 "반복 일정은 상세에서 수정하세요" 툴팁이 나온다.
///  - 그 밖(권한 없음·공휴일·생일·제한된 일정)은 그대로 둔다.
/// [builder]는 마우스 커서를 받아 InkWell 등에 넘긴다(null이면 기본).
class EventDragSource extends StatefulWidget {
  final EventOccurrence event;
  final EventDragHandle? handle;
  final Widget Function(BuildContext context, MouseCursor? cursor) builder;

  const EventDragSource({
    super.key,
    required this.event,
    required this.handle,
    required this.builder,
  });

  @override
  State<EventDragSource> createState() => _EventDragSourceState();
}

class _EventDragSourceState extends State<EventDragSource> {
  Offset _down = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final handle = widget.handle;
    if (isDragBlockedByRecurrence(event) && handle != null) {
      return Tooltip(
        message: kRecurringDragHint,
        waitDuration: const Duration(milliseconds: 400),
        child: widget.builder(context, SystemMouseCursors.basic),
      );
    }
    if (handle == null || !canDragEvent(event)) {
      return widget.builder(context, null);
    }
    final child = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) => _down = e.position,
      child: widget.builder(context, SystemMouseCursors.grab),
    );
    void started() => handle.onStart(event, _down);
    void updated(DragUpdateDetails d) =>
        handle.onUpdate(event, d.globalPosition);
    void ended(DraggableDetails _) => handle.onEnd(event);
    final feedback = _DragChip(event: event);
    final faded = Opacity(opacity: 0.35, child: child);
    if (_isTouchPlatform(context)) {
      return LongPressDraggable<EventOccurrence>(
        data: event,
        maxSimultaneousDrags: 1,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: feedback,
        childWhenDragging: faded,
        onDragStarted: started,
        onDragUpdate: updated,
        onDragEnd: ended,
        child: child,
      );
    }
    return Draggable<EventOccurrence>(
      data: event,
      maxSimultaneousDrags: 1,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: feedback,
      childWhenDragging: faded,
      onDragStarted: started,
      onDragUpdate: updated,
      onDragEnd: ended,
      child: child,
    );
  }
}

/// 끄는 동안 포인터 옆에 따라다니는 칩(제목만). 놓일 자리는 보기 안의 반투명 고스트가 보여 준다.
class _DragChip extends StatelessWidget {
  final EventOccurrence event;
  const _DragChip({required this.event});

  @override
  Widget build(BuildContext context) {
    final color = calendarColor(event.color);
    return Transform.translate(
      offset: const Offset(10, 10),
      child: IgnorePointer(
        child: Material(
          color: color.withValues(alpha: 0.85),
          elevation: 4,
          borderRadius: BorderRadius.circular(6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                eventDisplayTitle(event),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  decoration: TextDecoration.none,
                  fontWeight: FontWeight.w600,
                  color: onCalendarColor(color),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 끄는 동안 놓일 자리 미리보기의 반투명 색(고스트·칸 하이라이트).
Color dragHighlightColor(BuildContext context) =>
    Theme.of(context).colorScheme.primary.withValues(alpha: 0.14);
