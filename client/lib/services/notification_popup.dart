import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:win32/win32.dart';
import 'package:window_manager/window_manager.dart';

import 'main_window_methods.dart';
import 'notification_popup_style.dart';
import '../l10n/tr.dart';

/// PC(Windows) 새 메시지·프로젝트 알림 창 — Windows 기본 알림(토스트)은 OS가 그려서 높이가 100px쯤 되고 줄일 방법이
/// 없어서(앱이 줄 수 있는 건 제목·본문·그림뿐), 앱이 직접 그린 낮은 카드(기본 270×50)를 화면 오른쪽 아래에 띄운다.
/// 카드 가로·세로와 최대 개수는 사람마다 환경설정에서 고른다(NotificationPopupStyle — 알림마다 같이 보낸다).
///
/// 카드는 desktop_multi_window로 만든 서브 창(별도 Flutter 엔진) 하나에 아래에서 위로 쌓인다(최대 개수를 넘치면
/// 오래된 것부터 빠진다). 창은 처음 알림 때 한 번 만들고 닫지 않고 숨겨 두었다가 다시 쓴다(캡처 오버레이와 같은 방식 —
/// 엔진을 새로 띄우는 데 1초쯤 걸린다). 포커스를 빼앗지 않고(WS_EX_NOACTIVATE) 작업표시줄에도 안 나온다(WS_EX_TOOLWINDOW).
/// 같은 방의 알림은 카드 하나를 새 내용으로 바꾸고, [_visibleFor] 뒤에 저절로 사라진다(마우스를 올리고 있으면 기다린다).
/// 카드를 누르면 메인 창이 그 방(프로젝트)을 연다 — Windows 알림을 눌렀을 때와 같다.
///
/// Windows 알림과 달리 알림 센터에는 남지 않는다. 전체 화면·발표 중이면(SHQueryUserNotificationState) Windows 알림처럼
/// 띄우지 않는다. 창을 띄우지 못하면(엔진 생성 실패 등) [showNotificationPopup]이 false를 돌려주고, 부른 쪽이 Windows
/// 기본 알림으로 대신 띄운다(notification_service.dart).

/// 창 생성 인자(JSON)의 "type" 값 — main.dart가 이걸 보고 서브 창 진입점을 고른다.
const kNotificationPopupWindowType = 'notify';

/// 메인 → 알림 창: 카드 하나를 띄우거나(같은 key면 바꾸기) 지운다.
const _kShowMethod = 'notify_popup_show';
const _kCancelMethod = 'notify_popup_cancel';

/// 알림 창 → 메인: 준비됐다(메서드 핸들러를 걸었다) / 카드를 눌렀다.
const _kReadyMethod = 'notify_popup_ready';
const _kTapMethod = 'notify_popup_tap';

/// 화면 가장자리와의 간격, 카드 사이 구분선 두께(논리 픽셀 — 화면 배율을 곱해 창 크기를 잡는다).
const _edgeMargin = 12.0;
const _dividerHeight = 1.0;

/// 카드가 떠 있는 시간, 마우스를 뗀 뒤 다시 기다리는 시간.
const _visibleFor = Duration(seconds: 6);
const _afterHover = Duration(seconds: 3);

// ───────────────────────── 메인 창 쪽 ─────────────────────────

String? _popupWindowId;
Future<WindowController?>? _opening;
void Function(String payload)? _onTap;

/// 카드를 눌렀을 때 할 일(payload — 방 id 또는 `project:<id>`) — NotificationService.init이 건다.
void setNotificationPopupTapHandler(void Function(String payload) onTap) {
  _onTap = onTap;
}

/// 카드 하나를 띄운다 — [key]가 같으면(같은 방) 떠 있는 카드를 새 내용으로 바꾼다. [imagePath]는 왼쪽 동그란 그림
/// 파일(없으면 앱 아이콘), [style]은 테마·카드 크기·최대 개수. 띄웠거나 일부러 안 띄웠으면(전체 화면 중) true, 창을
/// 띄우지 못했으면 false. [force]면 전체 화면 중이어도 띄운다(환경설정의 미리 보기 — 소리도 [sound]로 끈다).
Future<bool> showNotificationPopup({
  required String key,
  required String title,
  required String body,
  required String payload,
  String? imagePath,
  NotificationPopupStyle style = const NotificationPopupStyle(),
  bool force = false,
  bool sound = true,
}) async {
  if (!force && !_acceptsNotifications()) return true;
  try {
    final popup = await _ensurePopup();
    if (popup == null) return false;
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    await popup
        .invokeMethod(_kShowMethod, {
          'key': key,
          'title': title,
          'body': body,
          'payload': payload,
          'imagePath': imagePath,
          'dark':
              style.themeMode == ThemeMode.dark ||
              (style.themeMode == ThemeMode.system &&
                  brightness == Brightness.dark),
          'width': style.width,
          'height': style.height,
          'maxCards': style.maxCards,
        })
        .timeout(const Duration(seconds: 3));
    if (sound) _playSound();
    return true;
  } catch (_) {
    // 그 사이 창이 닫혔거나 응답이 없다 — 다음 알림 때 새로 만든다.
    _popupWindowId = null;
    return false;
  }
}

/// [key] 카드를 지운다(그 방을 열었을 때 — Windows 알림을 지우는 것과 같은 때).
Future<void> cancelNotificationPopup(String key) async {
  final id = _popupWindowId;
  if (id == null) return;
  try {
    await WindowController.fromWindowId(id)
        .invokeMethod(_kCancelMethod, {'key': key})
        .timeout(const Duration(seconds: 3));
  } catch (_) {}
}

/// 알림 창 — 숨겨 둔 창이 살아 있으면 그것, 없으면 새로 만들어 준비될 때까지 기다린다. 못 만들면 null.
Future<WindowController?> _ensurePopup() async {
  final id = _popupWindowId;
  if (id != null) {
    final all = await WindowController.getAll();
    if (all.any((c) => c.windowId == id)) {
      return WindowController.fromWindowId(id);
    }
    _popupWindowId = null;
  }
  return _opening ??= _openPopup().whenComplete(() => _opening = null);
}

Future<WindowController?> _openPopup() async {
  final ready = Completer<void>();
  await registerMainWindowMethod(_kReadyMethod, (call) async {
    if (!ready.isCompleted) ready.complete();
    return null;
  });
  await registerMainWindowMethod(_kTapMethod, (call) async {
    final payload = (call.arguments as Map?)?['payload'] as String?;
    if (payload != null) _onTap?.call(payload);
    return null;
  });
  final me = await WindowController.fromCurrentEngine();
  final controller = await WindowController.create(
    WindowConfiguration(
      arguments: jsonEncode({
        'type': kNotificationPopupWindowType,
        'mainWindowId': me.windowId,
      }),
    ),
  );
  // 늦게라도 준비되면 다음 알림부터 쓴다 — 기다리다 말았다고 창을 하나 더 만들지 않게 먼저 기억해 둔다.
  _popupWindowId = controller.windowId;
  try {
    await ready.future.timeout(const Duration(seconds: 10));
  } on TimeoutException {
    return null;
  }
  return controller;
}

typedef _QueryNotificationStateNative = Int32 Function(Pointer<Int32>);
typedef _QueryNotificationStateDart = int Function(Pointer<Int32>);

/// 지금 알림을 띄워도 되는지 — 전체 화면 앱·게임, 발표 모드, 화면 잠금 중이면 Windows 알림처럼 띄우지 않는다.
/// 알 수 없으면 띄운다.
bool _acceptsNotifications() {
  final out = calloc<Int32>();
  try {
    final query = DynamicLibrary.open('shell32.dll')
        .lookupFunction<
          _QueryNotificationStateNative,
          _QueryNotificationStateDart
        >('SHQueryUserNotificationState');
    if (query(out) != S_OK) return true;
    // QUNS_ACCEPTS_NOTIFICATIONS = 5, QUNS_APP(스토어 앱이 앞에 떠 있음 — 알림은 받는다) = 7.
    return out.value == 5 || out.value == 7;
  } catch (_) {
    return true;
  } finally {
    calloc.free(out);
  }
}

/// Windows 기본 알림 소리(제어판 소리 설정의 "알림" — 사용자가 "없음"으로 바꿨으면 안 난다). 비동기 재생이라
/// 이름 문자열은 재생이 끝날 때까지 살아 있어야 해서 한 번 만들어 계속 쓴다.
final Pointer<Utf16> _soundAlias = 'Notification.Default'.toNativeUtf16();

void _playSound() {
  PlaySound(_soundAlias, 0, SND_ALIAS | SND_ASYNC | SND_NODEFAULT);
}

// ───────────────────────── 알림 창(서브 창) 쪽 ─────────────────────────

class _PopupItem {
  final String key;
  final String title;
  final String body;
  final String payload;
  final String? imagePath;
  Timer? timer;
  _PopupItem({
    required this.key,
    required this.title,
    required this.body,
    required this.payload,
    this.imagePath,
  });
}

/// 떠 있는 카드들(오래된 것 → 새것, 화면에는 새것이 맨 아래).
final _items = ValueNotifier<List<_PopupItem>>(const []);
final _dark = ValueNotifier<bool>(false);

/// 카드 크기(논리 픽셀)와 최대 개수 — 알림마다 메인 창이 보내 오는 사람별 설정(NotificationPopupStyle).
Size _cardSize = Size(
  NotificationPopupStyle.defaultWidth.toDouble(),
  NotificationPopupStyle.defaultHeight.toDouble(),
);
int _maxCards = NotificationPopupStyle.defaultMaxCards;
int _hwnd = 0;
String _mainWindowId = '';
bool _hovering = false;
bool _visible = false;

/// 숨겨 둔 창을 다시 띄울 때마다 올라간다 — 첫 프레임 콜백과 안전장치 타이머 중 먼저 온 쪽만 창을 띄운다.
int _showSeq = 0;

/// 알림 서브 창의 엔진에서 실행되는 진입점(main.dart가 type=notify일 때 부른다).
Future<void> runNotificationPopupWindow(
  WindowController controller,
  Map<String, dynamic> args,
) async {
  _mainWindowId = args['mainWindowId'] as String? ?? '';
  await windowManager.ensureInitialized();
  _hwnd = await windowManager.getId();
  // 만들어질 때는 제목줄·테두리가 있는 일반 창이라 테두리 없는 팝업으로 바꾸고, 눌러도 포커스를 가져가지 않고
  // 작업표시줄·Alt+Tab에도 나오지 않게 한다.
  SetWindowLongPtr(_hwnd, GWL_STYLE, WS_POPUP);
  SetWindowLongPtr(
    _hwnd,
    GWL_EXSTYLE,
    GetWindowLongPtr(_hwnd, GWL_EXSTYLE) | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
  );
  _roundCorners();

  await controller.setWindowMethodHandler((call) async {
    final args = Map<String, dynamic>.from(call.arguments as Map);
    switch (call.method) {
      case _kShowMethod:
        _add(args);
      case _kCancelMethod:
        _remove(args['key'] as String);
    }
    return null;
  });

  runApp(const _PopupApp());
  try {
    await WindowController.fromWindowId(
      _mainWindowId,
    ).invokeMethod(_kReadyMethod);
  } catch (_) {}
}

/// Windows 11이면 창 모서리를 둥글게(10은 무시된다).
void _roundCorners() {
  final pref = calloc<Int32>()..value = DWMWCP_ROUND;
  try {
    DwmSetWindowAttribute(
      _hwnd,
      DWMWA_WINDOW_CORNER_PREFERENCE,
      pref,
      sizeOf<Int32>(),
    );
  } catch (_) {
  } finally {
    calloc.free(pref);
  }
}

void _add(Map<String, dynamic> args) {
  _dark.value = args['dark'] == true;
  _cardSize = Size(
    NotificationPopupStyle.snapWidth(
      (args['width'] as num?)?.toInt() ?? NotificationPopupStyle.defaultWidth,
    ).toDouble(),
    NotificationPopupStyle.snapHeight(
      (args['height'] as num?)?.toInt() ?? NotificationPopupStyle.defaultHeight,
    ).toDouble(),
  );
  _maxCards = NotificationPopupStyle.snapMaxCards(
    (args['maxCards'] as num?)?.toInt() ??
        NotificationPopupStyle.defaultMaxCards,
  );
  final item = _PopupItem(
    key: args['key'] as String,
    title: args['title'] as String? ?? '',
    body: args['body'] as String? ?? '',
    payload: args['payload'] as String? ?? '',
    imagePath: args['imagePath'] as String?,
  );
  final list = [..._items.value];
  final same = list.indexWhere((e) => e.key == item.key);
  if (same >= 0) list.removeAt(same).timer?.cancel();
  list.add(item);
  while (list.length > _maxCards) {
    list.removeAt(0).timer?.cancel();
  }
  _items.value = list;
  if (!_hovering) _arm(item, _visibleFor);
  _layout();
}

/// [key] 카드를 뺀다 — [only]를 주면 그 카드일 때만(그 사이 같은 방의 새 카드로 바뀌었으면 두고).
void _remove(String key, [_PopupItem? only]) {
  final list = [..._items.value];
  final i = list.indexWhere((e) => e.key == key);
  if (i < 0 || (only != null && !identical(list[i], only))) return;
  list.removeAt(i).timer?.cancel();
  _items.value = list;
  _layout();
}

void _arm(_PopupItem item, Duration after) {
  item.timer?.cancel();
  item.timer = Timer(after, () => _remove(item.key, item));
}

/// 마우스를 올리고 있는 동안은 카드가 사라지지 않는다 — 떼면 [_afterHover] 뒤에 사라진다.
void _setHovering(bool hovering) {
  if (_hovering == hovering) return;
  _hovering = hovering;
  for (final item in _items.value) {
    if (hovering) {
      item.timer?.cancel();
    } else {
      _arm(item, _afterHover);
    }
  }
}

void _tap(_PopupItem item) {
  _remove(item.key, item);
  if (item.payload.isEmpty) return; // 환경설정의 미리 보기 카드 — 열 곳이 없다.
  unawaited(
    WindowController.fromWindowId(_mainWindowId)
        .invokeMethod(_kTapMethod, {'payload': item.payload})
        .catchError((_) => null),
  );
}

/// 카드 수에 맞춰 창 크기를 잡고 주 모니터 작업 영역(작업표시줄 제외)의 오른쪽 아래에 붙인다. 카드가 없으면 숨긴다.
void _layout() {
  final n = _items.value.length;
  if (n == 0) {
    _showSeq++;
    _hovering = false;
    if (_visible) {
      ShowWindow(_hwnd, SW_HIDE);
      _visible = false;
    }
    return;
  }
  final point = calloc<POINT>(); // (0, 0)은 늘 주 모니터 안이다.
  final info = calloc<MONITORINFO>()..ref.cbSize = sizeOf<MONITORINFO>();
  final dpiX = calloc<Uint32>();
  final dpiY = calloc<Uint32>();
  try {
    final monitor = MonitorFromPoint(point.ref, MONITOR_DEFAULTTOPRIMARY);
    GetMonitorInfo(monitor, info);
    final scale =
        GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, dpiX, dpiY) == S_OK
        ? dpiX.value / 96.0
        : GetDpiForSystem() / 96.0;
    final work = info.ref.rcWork;
    final w = (_cardSize.width * scale).round();
    final h = ((n * _cardSize.height + (n - 1) * _dividerHeight) * scale)
        .round();
    final x = work.right - w - (_edgeMargin * scale).round();
    final y = work.bottom - h - (_edgeMargin * scale).round();
    // SWP_FRAMECHANGED — 처음 한 번은 위에서 바꾼 테두리 없는 스타일을 실제로 적용시킨다(이후엔 아무 일 없다).
    SetWindowPos(
      _hwnd,
      HWND_TOPMOST,
      x,
      y,
      w,
      h,
      SWP_NOACTIVATE | SWP_FRAMECHANGED,
    );
  } finally {
    calloc.free(point);
    calloc.free(info);
    calloc.free(dpiX);
    calloc.free(dpiY);
  }
  if (_visible) return;
  // 숨겨 둔 창은 새 카드가 그려진 다음에 띄운다 — 숨긴 창은 프레임을 안 그릴 수 있어 안전장치 타이머도 둔다.
  final seq = ++_showSeq;
  WidgetsBinding.instance.addPostFrameCallback((_) => _show(seq));
  WidgetsBinding.instance.scheduleFrame();
  Future<void>.delayed(const Duration(milliseconds: 300), () => _show(seq));
}

void _show(int seq) {
  if (seq != _showSeq || _visible || _items.value.isEmpty) return;
  ShowWindow(_hwnd, SW_SHOWNOACTIVATE);
  SetWindowPos(
    _hwnd,
    HWND_TOPMOST,
    0,
    0,
    0,
    0,
    SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW,
  );
  _visible = true;
}

class _PopupApp extends StatelessWidget {
  const _PopupApp();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _dark,
      builder: (context, dark, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: dark ? Brightness.dark : Brightness.light,
          colorSchemeSeed: const Color(0xFF3A6EA5),
        ),
        home: MouseRegion(
          onEnter: (_) => _setHovering(true),
          onExit: (_) => _setHovering(false),
          child: ValueListenableBuilder<List<_PopupItem>>(
            valueListenable: _items,
            builder: (context, items, _) {
              final theme = Theme.of(context);
              final cards = <Widget>[];
              for (final (i, item) in items.indexed) {
                if (i > 0) {
                  cards.add(
                    Divider(
                      height: _dividerHeight,
                      thickness: _dividerHeight,
                      color: theme.dividerColor,
                    ),
                  );
                }
                cards.add(_PopupCard(key: ValueKey(item), item: item));
              }
              // 창 크기는 카드 수에 맞춰 메인 쪽(_layout)이 바꾼다 — 바뀌는 사이 한두 프레임은 크기가 안 맞을 수 있어
              // 넘치는 부분은 잘라서(아래쪽 = 새 카드 기준) 그린다.
              return ColoredBox(
                color: theme.colorScheme.surfaceContainerHigh,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.bottomCenter,
                    maxHeight: double.infinity,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: cards,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 카드 한 장(높이는 설정한 세로) — 왼쪽 동그란 그림, 제목 한 줄 + 본문 한 줄(높은 카드면 두 줄), 마우스를 올리면
/// 오른쪽에 닫기(X).
class _PopupCard extends StatefulWidget {
  final _PopupItem item;
  const _PopupCard({super.key, required this.item});

  @override
  State<_PopupCard> createState() => _PopupCardState();
}

class _PopupCardState extends State<_PopupCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    final path = item.imagePath;
    final icon = Image.asset('assets/icon.png', fit: BoxFit.cover);
    final height = _cardSize.height;
    // 카드를 높게 고른 사람에게는 그림을 키우고 본문을 두 줄까지 보여 준다.
    final tall = height >= 65;
    final avatar = tall ? 40.0 : 32.0;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        child: InkWell(
          onTap: () => _tap(item),
          child: SizedBox(
            height: height,
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 6),
              child: Row(
                children: [
                  ClipOval(
                    child: SizedBox(
                      width: avatar,
                      height: avatar,
                      child: path == null
                          ? icon
                          : Image.file(
                              File(path),
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => icon,
                            ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        if (item.body.isNotEmpty)
                          Text(
                            tall ? item.body : item.body.replaceAll('\n', ' '),
                            maxLines: tall ? 2 : 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 28,
                    child: _hover
                        ? IconButton(
                            padding: EdgeInsets.zero,
                            iconSize: 16,
                            visualDensity: VisualDensity.compact,
                            tooltip: tr('닫기'),
                            icon: Icon(
                              Icons.close,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            onPressed: () => _remove(item.key, item),
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
