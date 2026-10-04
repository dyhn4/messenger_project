import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/todo.dart';
import 'compact_menu.dart';

// 할 일 화면들(목록 카드·일정·상세·생성)이 같이 쓰는 작은 조각 — 진척률 색(todoProgressColor)·진척률 고르기 상자
// (TodoProgressSelect), 그리고 PC 할 일 패널 안에서 화면을 바꾸는 모양(TodoViewMode)·전환(todoPanelRoute)·머리
// (TodoPageHeader)·창 전체에 띄우는 메뉴의 이름표(todoPopupRouteName)·쓰는 중인 할 일 목록(TodoPanelDrafts).

/// 할 일 화면이 창 전체(루트 Navigator)에 띄우는 메뉴(••• · 진척률·알림 메뉴)의 라우트 이름. PC 할 일 패널 안 화면은
/// 패널의 중첩 Navigator에 있지만, 메뉴를 거기 띄우면 바깥을 누르는 막이 패널만 덮어 채팅 쪽을 눌러도 안 닫히고 그 누름이
/// 채팅에 간다 — 그래서 메뉴는 루트에 띄우고(자리는 패널 안), 패널 화면을 닫는 쪽(지워졌다는 알림·팀 전환)이 이 이름으로
/// 남은 메뉴를 찾아 닫는다.
const todoPopupRouteName = 'todo-popup';

/// [todoPopupRouteName]을 붙인 라우트 설정 — 할 일 메뉴의 `routeSettings`.
const todoPopupRouteSettings = RouteSettings(name: todoPopupRouteName);

/// [navigator] 맨 위에 떠 있는 할 일 메뉴([todoPopupRouteName])를 모두 닫는다(결과는 null — 고르지 않은 것과 같다).
void closeTodoPopups(NavigatorState navigator) =>
    navigator.popUntil((route) => route.settings.name != todoPopupRouteName);

/// 단추([buttonContext]) 바로 아래(+[gap])에 간결한 할 일 메뉴([CompactMenu] 모양)를 창 전체(루트 Navigator,
/// [todoPopupRouteName])에 띄운다 — 바깥 어디를 눌러도 닫히고 그 누름은 아래로 가지 않는다. 펴는 쪽은 가장 가까운 Overlay
/// (PC 할 일 패널 안 화면이면 패널) 안에 띄울 때와 같게 정한다: 그 Overlay의 오른쪽 끝에 더 가까운 단추면 단추 오른쪽 끝에
/// 맞춰 왼쪽으로, 아니면 왼쪽 끝에 맞춰 오른쪽으로. 루트 Navigator의 기본 자리 잡기는 창을 기준으로 정해서, 패널 왼쪽의
/// 단추도 "창 오른쪽 끝에 가깝다"고 보고 왼쪽으로(패널 밖까지) 펴 버린다. 다른 화면은 가장 가까운 Overlay가 곧 루트라
/// 기본과 같다. [height]는 메뉴 높이를 알 때(목록 높이를 정해 둔 긴 목록 — 시간 고르기) 준다: 단추 아래 자리가 모자라면
/// 단추를 덮지 않게 단추 바로 위로 편다(모르면 늘 아래 — 넘치면 창 안으로 밀려 올라온다). 고른 값, 닫기만 했으면 null.
Future<T?> showTodoMenu<T>(
  BuildContext buttonContext, {
  required List<PopupMenuEntry<T>> items,
  T? initialValue,
  BoxConstraints? constraints,
  double gap = 4,
  double? height,
}) {
  final button = buttonContext.findRenderObject() as RenderBox?;
  final bounds = Overlay.of(buttonContext).context.findRenderObject();
  final root =
      Navigator.of(
            buttonContext,
            rootNavigator: true,
          ).overlay?.context.findRenderObject()
          as RenderBox?;
  // 단추가 사라진 뒤에도(팀 전환 등) 메뉴가 다시 그려질 수 있어 마지막 자리를 들고 있는다.
  var last = RelativeRect.fill;
  RelativeRect position(BuildContext _, BoxConstraints _) {
    if (button == null || root == null || !button.attached || !root.attached) {
      return last;
    }
    final area = bounds is RenderBox && bounds.attached ? bounds : root;
    final leftInArea = button.localToGlobal(Offset.zero, ancestor: area).dx;
    final rightGap = area.size.width - leftInArea - button.size.width;
    final at = button.localToGlobal(
      Offset(0, button.size.height + gap),
      ancestor: root,
    );
    final width = root.size.width;
    // 메뉴 위 끝 — 보통은 단추 바로 아래. 높이를 알고 아래가 모자라면(창 가장자리 여백 8 포함) 단추 바로 위로.
    var top = at.dy;
    if (height != null && root.size.height - at.dy < height + 8) {
      final above =
          button.localToGlobal(Offset.zero, ancestor: root).dy - gap - height;
      if (above >= 8) top = above;
    }
    final bottom = root.size.height - top;
    // 메뉴 자리 잡기는 왼쪽 거리 > 오른쪽 거리면 오른쪽 끝([right])에 맞춰 왼쪽으로, 아니면 왼쪽 끝에 맞춰 오른쪽으로 편다.
    return last = leftInArea > rightGap
        ? RelativeRect.fromLTRB(
            width,
            top,
            width - at.dx - button.size.width,
            bottom,
          )
        : RelativeRect.fromLTRB(at.dx, top, width, bottom);
  }

  return showMenu<T>(
    context: buttonContext,
    useRootNavigator: true,
    routeSettings: todoPopupRouteSettings,
    positionBuilder: position,
    initialValue: initialValue,
    color: CompactMenu.color(buttonContext),
    shape: CompactMenu.shape,
    menuPadding: CompactMenu.menuPadding,
    constraints: constraints,
    items: items,
  );
}

/// 패널 안에서 쓰는 중인 할 일(생성·수정 화면) — 패널을 밖에서 닫거나 다른 패널로 바꾸기 전에 물어볼 수 있게 한다.
abstract interface class TodoDraft {
  /// 버리면 사라지는 내용이 있는지(저장하는 중이면 false — 묻지 않는다).
  bool get needsDiscardConfirm;

  /// "작성 취소" 확인 — 버려도 되면(바뀐 게 없거나 [닫기]) true.
  Future<bool> confirmDiscard();
}

/// 패널 안에서 쓰는 중인 할 일([TodoDraft]) 목록 — PC 할 일 패널이 들고 있다가 [TodoPanelDrafts]로 패널 안 화면들에 내려
/// 준다. 패널 안 생성·수정 화면이 열릴 때 들어오고 닫힐 때 빠지며, 패널은 홈 화면이 패널을 닫거나 바꾸기 전에 맨 위 것
/// ([top])에 묻는다.
class TodoDraftRegistry {
  final List<TodoDraft> _drafts = [];

  /// 가장 나중에 열린(맨 위) 쓰는 중인 할 일.
  TodoDraft? get top => _drafts.lastOrNull;

  void add(TodoDraft draft) {
    if (!_drafts.contains(draft)) _drafts.add(draft);
  }

  void remove(TodoDraft draft) => _drafts.remove(draft);
}

/// PC 할 일 패널이 중첩 Navigator 위에 두는 [TodoDraftRegistry] 손잡이.
class TodoPanelDrafts extends InheritedWidget {
  const TodoPanelDrafts({
    super.key,
    required this.drafts,
    required super.child,
  });

  final TodoDraftRegistry drafts;

  /// 가장 가까운 목록 — PC 할 일 패널 안 화면이 아니면(대화상자·모바일 전체 화면) null. 의존을 만들지 않는다.
  static TodoDraftRegistry? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TodoPanelDrafts>()?.drafts;

  @override
  bool updateShouldNotify(TodoPanelDrafts oldWidget) =>
      !identical(drafts, oldWidget.drafts);
}

/// 진척률 색(잔디) — 대기 주황, 진행(1~99) 잔디 초록(멘션 칩과 같은 초록), 완료 회색(hint). 어두운 테마에서는 같은 계열의
/// 밝은 색이라 어두운 바탕에서도 읽힌다.
Color todoProgressColor(BuildContext context, int progress) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;
  return switch (TodoStatus.of(progress)) {
    TodoStatus.todo => dark ? const Color(0xFFFFA94D) : const Color(0xFFF08C00),
    TodoStatus.doing =>
      dark ? const Color(0xFF4ADE9C) : const Color(0xFF02C472),
    TodoStatus.done => theme.hintColor,
  };
}

/// 할 일 상세·생성 화면을 그리는 모양 — 대화상자(넓은 창, 패널 밖에서 열 때) / 전체 화면(좁은 창) / 패널 안 화면(PC 오른쪽
/// 할 일 패널의 중첩 Navigator에 올리고 머리는 [TodoPageHeader] `← 할 일 … ✕`).
enum TodoViewMode { dialog, page, panel }

/// 패널 안 화면 전환([TodoViewMode.panel]) — 오른쪽에서 짧게(150ms) 밀려 들어오고, 닫으면 오른쪽으로 빠진다. 할 일 패널의
/// 중첩 Navigator에 올린다(상세·생성·수정·할 일 일정). 화면은 제 바탕을 칠해야 밀려 들어오는 동안 아래 화면이 비치지 않는다.
Route<T> todoPanelRoute<T>(WidgetBuilder builder, {RouteSettings? settings}) =>
    PageRouteBuilder<T>(
      settings: settings,
      transitionDuration: const Duration(milliseconds: 150),
      reverseTransitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (context, animation, secondaryAnimation) => builder(context),
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          SlideTransition(
            position: animation.drive(
              Tween(
                begin: const Offset(1, 0),
                end: Offset.zero,
              ).chain(CurveTween(curve: Curves.easeOutCubic)),
            ),
            child: child,
          ),
    );

/// [route]가 아직 떠 있으면 닫는다 — 맨 위면 pop(닫히는 모양 그대로), 아니면 그 자리에서 뺀다. 결과는 null이라 기다리던
/// 쪽은 "취소"로 읽는다. 패널 안 화면(중첩 Navigator)은 확인 창·고르기 창을 루트 Navigator에 띄우므로, 화면이 먼저 닫히면
/// (지워졌다는 알림·팀 전환) 그 창이 혼자 남는다 — 그때 치운다. 화면을 치우는 중(dispose)에는 부르지 말고 다음 프레임에.
void closeTodoRoute(Route<Object?> route) {
  final navigator = route.navigator;
  if (navigator == null || !route.isActive) return;
  if (route.isCurrent) {
    navigator.pop();
  } else {
    navigator.removeRoute(route);
  }
}

/// 패널 안 화면의 머리(잔디 `← 할 일 … ✕`) — ←([onBack])는 그 화면만 닫고, ✕([onClose])는 패널 전체를 닫는다. [actions]는
/// 제목과 ✕ 사이. 높이·글꼴은 패널 머리(SidePanelHeader)와 같고, 아래 구분선은 쓰는 쪽이 긋는다. [onBack]·[onClose]가
/// 없으면 그 단추는 빠진다. 단추 키는 `todo-page-back`·`todo-page-close`.
class TodoPageHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onBack;
  final VoidCallback? onClose;
  final List<Widget> actions;
  const TodoPageHeader({
    super.key,
    this.title = '할 일',
    this.onBack,
    this.onClose,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final back = onBack;
    final close = onClose;
    return Padding(
      // ←가 있으면 단추 안쪽 여백만큼 덜 띄워 화살표를 본문 왼쪽 끝에 맞춘다.
      padding: EdgeInsets.fromLTRB(back == null ? 16 : 8, 12, 8, 12),
      child: Row(
        children: [
          if (back != null) ...[
            IconButton(
              key: const ValueKey('todo-page-back'),
              icon: const Icon(Icons.arrow_back),
              tooltip: '뒤로',
              onPressed: back,
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          ...actions,
          if (close != null)
            IconButton(
              key: const ValueKey('todo-page-close'),
              icon: const Icon(Icons.close),
              tooltip: '닫기',
              onPressed: close,
            ),
        ],
      ),
    );
  }
}

/// 진척률 메뉴 항목 다섯 개(대기(0%) / 진행(25%) / 진행(50%) / 진행(75%) / 완료(100%)) — [current]에 체크. 키는
/// `todo-progress-option-<값>`.
List<PopupMenuEntry<int>> _progressMenuItems(int current) => [
  for (final p in todoProgressSteps)
    PopupMenuItem<int>(
      key: ValueKey('todo-progress-option-$p'),
      value: p,
      height: CompactMenu.itemHeight,
      padding: CompactMenu.itemPadding,
      child: Row(
        children: [
          Expanded(
            child: Text(todoProgressMenuLabel(p), style: CompactMenu.textStyle),
          ),
          if (p == current) const Icon(Icons.check, size: 16),
        ],
      ),
    ),
];

/// 진척률 고르기(잔디 상세의 담당자 줄) — [onSelected]가 있으면 테두리 있는 선택 상자 `대기(0%) ▾`(글자는 진척률 색)이고,
/// 누르면 간결한 메뉴(대기(0%) / 진행(25%) / 진행(50%) / 진행(75%) / 완료(100%), 지금 값에 체크)가 뜬다. 지금 값과 같은
/// 항목을 고르면 아무것도 하지 않는다. [onSelected]가 없으면 상자 없이 색 글자만 같은 자리에(다른 담당자 줄 — 위아래 줄의
/// 글자가 나란히 선다). 메뉴 항목 키는 `todo-progress-option-<값>`. 메뉴는 창 전체(루트 Navigator, [todoPopupRouteName])에
/// 띄운다 — PC 할 일 패널 안에서 열어도 바깥(채팅 쪽)을 누르면 닫힌다.
class TodoProgressSelect extends StatelessWidget {
  final int progress;
  final ValueChanged<int>? onSelected;
  const TodoProgressSelect({
    super.key,
    required this.progress,
    this.onSelected,
  });

  /// 상자의 최소 폭·높이.
  static const _minWidth = 116.0;
  static const _height = 34.0;

  /// 글자 앞 여백 — 상자 테두리(1) + 안쪽 여백(10). 글자만 보일 때도 같게 띄운다.
  static const _textInset = 11.0;

  /// 글자 뒤 ▾ 자리 — 글자와의 틈(6) + ▾(18) + 오른쪽 여백(7, 테두리 포함).
  static const _chevronGap = 6.0;
  static const _chevronSize = 18.0;
  static const _endInset = 7.0;

  /// 상자 폭 — 가장 긴 문구(`완료(100%)`)와 ▾가 들어가는 폭(최소 [_minWidth]). 지금 값이 무엇이든, 상자든 글자만이든
  /// 같은 폭이라 담당자 줄들이 나란하다(글꼴·글자 크기 배율이 달라도).
  double _boxWidth(BuildContext context, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(
        text: todoProgressMenuLabel(100),
        style: DefaultTextStyle.of(context).style.merge(style),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final longest = painter.width;
    painter.dispose();
    return math.max(
      _minWidth,
      _textInset + longest + _chevronGap + _chevronSize + _endInset,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: todoProgressColor(context, progress),
    );
    final label = Text(
      todoProgressMenuLabel(progress),
      maxLines: 1,
      softWrap: false,
      style: style,
    );
    final size = BoxConstraints(
      minWidth: _boxWidth(context, style),
      minHeight: _height,
    );
    final select = onSelected;
    if (select == null) {
      return ConstrainedBox(
        constraints: size,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: _textInset),
          child: Row(mainAxisSize: MainAxisSize.min, children: [label]),
        ),
      );
    }
    return _ProgressSelectButton(
      progress: progress,
      onSelected: select,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(6),
        ),
        child: ConstrainedBox(
          constraints: size,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(_textInset, 0, _endInset, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              // 상자가 글자보다 넓으면(짧은 문구·쓰는 쪽이 정한 폭) ▾는 오른쪽 끝에.
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                label,
                Padding(
                  padding: const EdgeInsets.only(left: _chevronGap),
                  child: Icon(
                    Icons.keyboard_arrow_down,
                    size: _chevronSize,
                    color: theme.hintColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// [TodoProgressSelect]의 고르기 상자 — 누르면 진척률 메뉴를 [showTodoMenu]로 띄운다(창 전체 위, 펴는 쪽은 가장 가까운
/// Overlay 기준). 메뉴가 떠 있는 동안은 "펼침"으로 읽힌다.
class _ProgressSelectButton extends StatefulWidget {
  final int progress;
  final ValueChanged<int> onSelected;
  final Widget child;
  const _ProgressSelectButton({
    required this.progress,
    required this.onSelected,
    required this.child,
  });

  @override
  State<_ProgressSelectButton> createState() => _ProgressSelectButtonState();
}

class _ProgressSelectButtonState extends State<_ProgressSelectButton> {
  bool _open = false;

  Future<void> _show() async {
    if (_open) return;
    final current = widget.progress;
    setState(() => _open = true);
    final picked = await showTodoMenu<int>(
      context,
      items: _progressMenuItems(current),
      initialValue: todoProgressSteps.contains(current) ? current : null,
      constraints: const BoxConstraints(minWidth: 140, maxWidth: 200),
    );
    if (!mounted) return;
    setState(() => _open = false);
    if (picked != null && picked != widget.progress) widget.onSelected(picked);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      expanded: _open,
      child: Tooltip(
        message: '진척률 변경',
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: _show,
          child: widget.child,
        ),
      ),
    );
  }
}
