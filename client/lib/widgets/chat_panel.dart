import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../data/stickers.dart';
import '../models/app_user.dart';
import '../models/comment.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../services/session.dart';
import 'chat_input_bar.dart';
import 'date_divider.dart';
import 'date_picker_popup.dart';
import 'indexed_scrollbar.dart';
import 'message_bubble.dart';
import 'message_comments_card.dart';
import 'read_up_to_here_divider.dart';
import 'sticker_picker.dart';
import 'sticker_preview_card.dart';
import 'system_message_row.dart';

/// 방 하나의 메시지 목록 + 입력창. ChatScreen(모바일 전체화면)과
/// DesktopHomeScreen(우측 패널)이 이 위젯을 그대로 공유한다.
///
/// 이 방이 화면에 떠있는 동안은 Session에 "지금 보고 있는 방"으로 등록해서,
/// 그 방으로 온 메시지에는 알림이 뜨지 않도록 한다. 호출부에서 반드시
/// `key: ValueKey(room.id)`를 줘야 방이 바뀔 때 State가 새로 생성되어 이 등록이 정확히 갱신된다.
class ChatPanel extends StatefulWidget {
  final Session session;
  final Room room;

  /// 검색 결과에서 열었을 때, 그 메시지로 스크롤하고 잠깐 하이라이트한다.
  final String? highlightMessageId;

  /// 말풍선의 댓글 아이콘이나 댓글 미리보기 카드를 눌렀을 때(스레드 패널 열기).
  final void Function(Message message)? onOpenThread;

  const ChatPanel({
    super.key,
    required this.session,
    required this.room,
    this.highlightMessageId,
    this.onOpenThread,
  });

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final _listKey = GlobalKey();
  final _dividerKeys = <String, GlobalKey>{};
  final _itemScrollController = ItemScrollController();
  final _itemPositionsListener = ItemPositionsListener.create();
  DateTime? _floatingDate;
  Timer? _hideTimer;
  String? _highlightedMessageId;
  Timer? _highlightTimer;
  bool _showDatePicker = false;

  /// Session.setActiveRoom이 돌려준 토큰 — dispose에서 그대로 되돌려줘서, 그 사이 다른
  /// 화면이 활성 방을 새로 지정했으면 내가 지우지 않도록 한다(Session.clearActiveRoom 참고).
  int _activeRoomToken = 0;

  /// 이모티콘 패널/미리보기 상태 — 메시지 목록 위에 떠 있는 오버레이로 그리므로(카카오톡처럼
  /// 입력창을 밀어내지 않게) 입력창(ChatInputBar)이 아니라 여기서 들고 있는다.
  Sticker? _pendingSticker;
  bool _stickerPickerOpen = false;

  /// 내가 쓴 메시지/댓글은 스크롤이 맨 아래가 아니었더라도 항상 맨 아래로 따라가서 보여준다.
  /// 남이 쓴 건 내가 이미 맨 아래(index 0)를 보고 있을 때만 따라간다 — 검색으로 옛
  /// 메시지에 하이라이트해서 이동했거나 위로 스크롤해서 지난 대화를 읽는 중이면 읽던
  /// 위치를 뺏지 않는다. _maybeScrollToNewEntry/_isAtBottom 참고.
  String? _lastSeenEntryId;
  int _lastSeenEntryCount = 0;

  /// 이 방을 처음 여는 중이면(RoomChatController가 방금 생성돼 아직 히스토리를 못 받아온
  /// 상태) initState 시점엔 messages가 비어 있고, 잠시 뒤 REST 응답이 도착하면서
  /// notifyListeners()가 한 번 불린다 — 이때는 "새 메시지가 왔다"가 아니라 "이제 막
  /// 히스토리 로딩이 끝났다"일 뿐이라, _maybeScrollToNewEntry에서 알약을 띄우면 안 된다.
  /// 이미 로딩이 끝나 있던(캐시된) 컨트롤러는 initState에서 바로 true로 시작한다.
  bool _baselineEstablished = false;

  /// 맨 아래가 아닐 때 남이 보낸 새 메시지가 오면(위치를 뺏지 않으려고 자동 스크롤은 안
  /// 하는 대신) true로 켜서 "새로운 메시지가 있습니다" 알약을 띄운다. 알약을 누르면(맨
  /// 아래로 스크롤) 또는 직접 스크롤해서 맨 아래에 도달하면 꺼진다.
  ///
  /// setState가 아니라 ValueNotifier인 이유: 이 값들은 스크롤할 때마다 바뀌는데, setState로
  /// 처리하면 ChatPanel 전체(=ScrollablePositionedList 포함)가 다시 빌드된다. 그런데 이
  /// 값을 갱신하는 _onItemPositionsChanged는 리스트가 레이아웃을 끝내고 부르는 콜백이라,
  /// 거기서 리스트 자신을 다시 빌드하게 만들면 위젯 생명주기가 꼬여서
  /// '_dependents.isEmpty' assertion으로 죽는다. ValueListenableBuilder로 알약/버튼
  /// 위젯만 다시 그리면 리스트는 건드리지 않는다.
  final _newMessagesBelow = ValueNotifier<bool>(false);

  /// 맨 아래에서 한 화면 이상 위로 스크롤되어 있으면 켜서, 항상 떠 있지는 않는 "맨 아래로"
  /// 동그란 버튼을 보여준다. _onItemPositionsChanged에서 보이는 항목 인덱스로 판단한다.
  final _scrolledPastOnePage = ValueNotifier<bool>(false);

  /// 지금 맨 아래(가장 최신 메시지, itemIndex 0)가 화면에 보이는지. 검색 결과를 눌러 옛
  /// 메시지로 점프했거나 위로 스크롤해서 지난 대화를 읽는 중이면 false가 된다 — 이 경우
  /// 남이 보낸 새 메시지가 와도 읽던 위치를 그대로 유지해야 하므로 자동 스크롤을 건너뛴다.
  ///
  /// (드래그 여부로 판단하는 방식은 버렸다 — 마우스 휠 스크롤은 dragDetails가 안 잡혀서
  /// PC에서 위로 스크롤해도 "맨 아래를 계속 보는 중"으로 잘못 남아있는 문제가 있었다.)
  bool get _isAtBottom =>
      _itemPositionsListener.itemPositions.value.any((p) => p.index == 0);

  /// 스크롤 위치가 바뀔 때마다(레이아웃 후) 불린다. 여기서 판단하는 것들은 전부 "지금 어떤
  /// 항목이 화면에 보이는지"(itemPositions) 기준이다 — ScrollablePositionedList의
  /// ScrollMetrics.pixels/maxScrollExtent는 절대 위치가 아니라 "현재 앵커 항목 기준
  /// 상대값"이라, scrollTo/jumpTo로 앵커가 바뀔 때마다 0 근처로 리셋된다. 그걸 "맨 아래에
  /// 닿았다"로 잘못 읽는 바람에, 위로 스크롤해둔 상태에서 새 메시지가 오면
  /// _compensateForPrependedEntries의 jumpTo 직후 알약이 곧바로 다시 꺼지고 "맨 아래로"
  /// 버튼도 사라지는 문제가 있었다.
  void _onItemPositionsChanged() {
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty || !mounted) return;

    final atBottom = positions.any((p) => p.index == 0);
    // 화면에 한 번에 보이는 항목 수(positions.length)를 "한 화면"의 근사값으로 써서, 그보다
    // 더 위로 올라가 있을 때만 "맨 아래로" 버튼을 띄운다.
    var minIndex = positions.first.index;
    for (final p in positions) {
      if (p.index < minIndex) minIndex = p.index;
    }
    _scrolledPastOnePage.value = !atBottom && minIndex >= positions.length;
    // 알약이 떠 있는 채로 사용자가 직접 스크롤해서 맨 아래에 닿으면(알약/버튼을 안
    // 눌러도) 이미 다 본 셈이니 끈다.
    if (atBottom) _newMessagesBelow.value = false;
  }

  @override
  void initState() {
    super.initState();
    _activeRoomToken = widget.session.setActiveRoom(widget.room.id);
    // 캐시된 컨트롤러를 다시 열었을 때는 _load()가 재실행되지 않으므로, 방을
    // 다시 열 때마다 명시적으로 한 번 더 읽음 처리한다.
    final controller = widget.session.controllerFor(widget.room);
    controller.markReadNow();
    widget.session.clearUnreadCount(widget.room.id);
    _scrollToHighlight();
    if (!controller.loading) {
      _lastSeenEntryId = controller.messages.isNotEmpty
          ? controller.messages.last.id
          : null;
      _lastSeenEntryCount = controller.messages.length;
      _baselineEstablished = true;
    }
    controller.addListener(_maybeScrollToNewEntry);
    _itemPositionsListener.itemPositions.addListener(_onItemPositionsChanged);
    widget.session.openStickerPickerOwner.addListener(
      _onStickerPickerOwnerChanged,
    );
  }

  /// 다른 화면(댓글 패널 등)이 이모티콘 패널을 열면서 owner를 가져가면, 여기 열려있던
  /// 패널은 자동으로 닫는다 — 동시에 두 곳에서 열려있지 않게.
  void _onStickerPickerOwnerChanged() {
    if (_stickerPickerOpen &&
        widget.session.openStickerPickerOwner.value != this) {
      setState(() => _stickerPickerOpen = false);
    }
  }

  /// controller.messages의 마지막 항목(시간상 가장 나중 = reverse 리스트의 맨 아래)이 바뀔
  /// 때마다 불린다. 내가 쓴 메시지/댓글(m.senderId 또는 합성 항목의 asComment.senderId)이면
  /// 무조건 맨 아래로 따라가고, 남이 쓴 거면 내가 이미 맨 아래를 보고 있었을 때만 따라간다.
  /// 맨 아래가 아닌데 남이 새로 보냈으면, 스크롤 대신 "새로운 메시지가 있습니다" 알약만 켠다.
  void _maybeScrollToNewEntry() {
    final msgs = widget.session.controllerFor(widget.room).messages;
    if (msgs.isEmpty) return;
    final last = msgs.last;

    if (!_baselineEstablished) {
      // 방을 처음 열 때 히스토리 로딩이 막 끝나서 불린 것뿐이다 — "새 메시지"가 아니니
      // 기준점만 조용히 잡고 끝낸다(알약/스크롤 없음).
      _baselineEstablished = true;
      _lastSeenEntryId = last.id;
      _lastSeenEntryCount = msgs.length;
      return;
    }

    // loadOlderMessages()로 과거 메시지가 앞쪽(맨 아래 기준으로는 반대쪽)에 끼어드는
    // 경우도 있다 — 이땐 가장 최신 메시지(last)는 그대로지만 msgs.length는 늘어난다.
    // 매번 길이를 최신으로 맞춰둬야, 나중에 진짜 새 메시지가 왔을 때 added(그 사이 얼마나
    // 밀렸는지)가 정확하다 — 안 그러면 과거 메시지를 불러올 때마다 늘어난 개수가 다음 새
    // 메시지의 added에 잘못 누적돼서(_compensateForPrependedEntries가 엉뚱한 위치로 점프).
    final added = msgs.length - _lastSeenEntryCount;
    _lastSeenEntryCount = msgs.length;

    if (last.id == _lastSeenEntryId) return;
    _lastSeenEntryId = last.id;

    final senderId = last.type == MessageType.comment
        ? last.asComment!.senderId
        : last.senderId;
    if (senderId == widget.session.userId) {
      // 내가 보낸 건 위로 스크롤해둔 채였어도 항상 부드럽게 맨 아래로 내려간다.
      _scrollToBottom();
      return;
    }
    if (_isAtBottom) {
      // 이미 맨 아래였으면 애니메이션 없이(jumpTo) 그 자리에서 바로 반영한다. 이 메서드는
      // 화면을 다시 그리는 리스너보다 먼저 불리므로(_compensateForPrependedEntries 참고와
      // 동일한 이유) 다음 프레임으로 미루지 않고 지금 바로 처리해야, 댓글/메시지가 짧은
      // 간격으로 연달아 와도(애니메이션이 덜 끝난 채로 다음 게 오는 경쟁 상태 없이) 항상
      // 정확하게 "맨 아래"로 유지된다.
      _newMessagesBelow.value = false;
      if (_itemScrollController.isAttached) {
        _itemScrollController.jumpTo(index: 0);
      }
      return;
    }
    _newMessagesBelow.value = true;
    _compensateForPrependedEntries(added);
  }

  /// 맨 아래를 보고 있지 않을 때 새 메시지가 (reverse 리스트라) index 0 쪽에 끼어들면,
  /// 지금 화면에 보이는 메시지들의 itemIndex가 전부 [added]만큼 밀린다 — 그대로 두면 같은
  /// 인덱스 자리에 다른(더 최신) 메시지가 그려지면서 화면이 살짝 움직인 것처럼 보인다.
  /// 지금 보이는 위치를 애니메이션 없이(jumpTo) 그만큼 보정해서 실제로는 안 움직이게 한다.
  ///
  /// 이 메서드는 controller.notifyListeners()가 부르는 리스너라서, 화면을 다시 그리는
  /// ListenableBuilder의 리스너(같은 controller에 등록됨)보다 먼저 불린다 — 즉 지금 이
  /// 시점엔 아직 새 항목이 반영된 프레임이 그려지기 전이다. 그래서 여기서 다음 프레임으로
  /// 미루지 않고(addPostFrameCallback을 쓰면 "밀린 상태"가 한 프레임 그려졌다가 보정된
  /// 프레임으로 바뀌면서 화면이 순간적으로 출렁이는 게 보였다) 바로 잡아줘야, 새 항목
  /// 반영과 위치 보정이 같은 프레임에 한 번에 적용되어 깜빡임이 없다.
  void _compensateForPrependedEntries(int added) {
    if (added <= 0 || !_itemScrollController.isAttached) return;
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    final anchor = positions.reduce((a, b) => a.index < b.index ? a : b);
    _itemScrollController.jumpTo(
      index: anchor.index + added,
      alignment: anchor.itemLeadingEdge,
    );
  }

  void _scrollToBottom() {
    _newMessagesBelow.value = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemScrollController.isAttached) return;
      _itemScrollController.scrollTo(
        index: 0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  void _dismissNewMessagesPill() => _newMessagesBelow.value = false;

  @override
  void didUpdateWidget(covariant ChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 같은 방을 계속 보고 있는 채로(=State가 안 바뀜) 검색 결과를 새로 클릭한 경우.
    if (widget.highlightMessageId != null &&
        widget.highlightMessageId != oldWidget.highlightMessageId) {
      _scrollToHighlight();
    }
  }

  /// widget.highlightMessageId가 가리키는 메시지를 화면 가운데쯤으로 스크롤하고,
  /// 3초간 노란색으로 표시했다가 원래 색으로 되돌린다.
  Future<void> _scrollToHighlight() async {
    final targetId = widget.highlightMessageId;
    if (targetId == null) return;

    final controller = widget.session.controllerFor(widget.room);
    await controller.ensureMessageLoaded(targetId);
    if (!mounted) return;

    final msgs = controller.messages;
    final idx = msgs.indexWhere((m) => m.id == targetId);
    if (idx == -1) return; // 보존기간 파기 등으로 이미 지워졌으면 조용히 무시.
    final itemIndex = msgs.length - 1 - idx; // itemBuilder의 reverse 인덱싱과 맞춤.

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemScrollController.isAttached) return;
      _itemScrollController.scrollTo(
        index: itemIndex,
        alignment: 0.4,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    });

    setState(() => _highlightedMessageId = targetId);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _highlightedMessageId = null);
    });
  }

  /// 달력을 여는 동안은 _hideTimer를 꺼서, 달력을 보는 사이에 예전 스크롤 타이머가 만료돼
  /// 알약(과 그 위에 뜬 달력)이 통째로 사라지는 일이 없게 한다. 닫을 때는 타이머를 다시
  /// 걸어서(스크롤 없이 닫아도) 알약이 잠시 뒤 정상적으로 사라지게 한다.
  void _openDatePicker() {
    _hideTimer?.cancel();
    setState(() => _showDatePicker = true);
  }

  /// DateDivider의 꺽쇠를 눌렀을 때 — FloatingDatePill의 꺽쇠와 동일하게 동작하되, 알약이
  /// 아직 안 떠 있었을 수도 있으니(스크롤 없이 바로 눌렀을 때) 그 구분선의 날짜로 알약
  /// 자체를 세팅한 뒤 달력을 연다.
  void _openDatePickerFor(DateTime date) {
    _hideTimer?.cancel();
    setState(() {
      _floatingDate = date;
      _showDatePicker = true;
    });
  }

  void _closeDatePicker() {
    setState(() => _showDatePicker = false);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _floatingDate = null);
    });
  }

  void _toggleDatePicker() {
    if (_showDatePicker) {
      _closeDatePicker();
    } else {
      _openDatePicker();
    }
  }

  /// 날짜 알약의 달력(DatePickerPopup)에서 날짜를 고르면 호출된다. 그 날짜가 아직 로드된
  /// 범위 밖이면 controller.ensureDateLoaded가 과거 페이지를 이어서 불러오고, 그 날짜에
  /// 메시지가 아예 없으면 null을 돌려주므로 그때는 스크롤 없이 안내만 한다.
  Future<void> _jumpToDate(DateTime date) async {
    _closeDatePicker();
    final controller = widget.session.controllerFor(widget.room);
    final target = await controller.ensureDateLoaded(date);
    if (!mounted) return;
    if (target == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('해당 날짜에 메시지가 없습니다.')));
      return;
    }

    final msgs = controller.messages;
    final idx = msgs.indexWhere((m) => m.id == target.id);
    if (idx == -1) return;
    final itemIndex = msgs.length - 1 - idx;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemScrollController.isAttached) return;
      _itemScrollController.scrollTo(
        index: itemIndex,
        alignment: 0.05,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  void dispose() {
    // 위젯 재조정 순서상 dispose가 다음 화면의 initState보다 나중에 불릴 수 있어서,
    // 내가 지정했던 활성 방이 아직 그대로일 때만 지운다(토큰으로 판별 — 방 id 비교로는
    // "같은 방을 다시 여는" 경우를 구분하지 못한다. Session.clearActiveRoom 참고).
    widget.session.clearActiveRoom(_activeRoomToken);
    widget.session
        .controllerFor(widget.room)
        .removeListener(_maybeScrollToNewEntry);
    _itemPositionsListener.itemPositions.removeListener(
      _onItemPositionsChanged,
    );
    widget.session.openStickerPickerOwner.removeListener(
      _onStickerPickerOwnerChanged,
    );
    if (widget.session.openStickerPickerOwner.value == this) {
      widget.session.openStickerPickerOwner.value = null;
    }
    _hideTimer?.cancel();
    _highlightTimer?.cancel();
    _newMessagesBelow.dispose();
    _scrolledPastOnePage.dispose();
    super.dispose();
  }

  AppUser? _senderOf(String? senderId) {
    for (final m in widget.room.members) {
      if (m.id == senderId) return m;
    }
    return null;
  }

  Message? _findMessage(List<Message> msgs, String id) {
    for (final m in msgs) {
      if (m.id == id) return m;
    }
    return null;
  }

  String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  bool _sameMinute(DateTime a, DateTime b) =>
      a.year == b.year &&
      a.month == b.month &&
      a.day == b.day &&
      a.hour == b.hour &&
      a.minute == b.minute;

  void _toggleStickerPicker() {
    setState(() => _stickerPickerOpen = !_stickerPickerOpen);
    // 내가 열었으면 owner를 가져와서 다른 화면(댓글 패널 등)에 열려있던 패널을 닫히게 하고,
    // 내가 닫는 거면(그리고 owner가 나였다면) 놓아준다.
    if (_stickerPickerOpen) {
      widget.session.openStickerPickerOwner.value = this;
    } else if (widget.session.openStickerPickerOwner.value == this) {
      widget.session.openStickerPickerOwner.value = null;
    }
  }

  void _selectSticker(Sticker sticker) {
    setState(() {
      _pendingSticker = sticker;
      _stickerPickerOpen = false;
    });
    if (widget.session.openStickerPickerOwner.value == this) {
      widget.session.openStickerPickerOwner.value = null;
    }
  }

  void _removeSticker() => setState(() => _pendingSticker = null);

  /// 가장 오래된(맨 위) 메시지 근처까지 올라간 채로 스크롤이 멈추면 서버에서 그보다 더
  /// 오래된 메시지를 더 가져온다(RoomChatController.loadOlderMessages).
  ///
  /// 스크롤 도중(ScrollUpdateNotification)이 아니라 멈췄을 때(ScrollEndNotification)만
  /// 호출한다 — 스크롤바 썸을 드래그하는 도중에 목록이 길어지면 "마우스 이동량 → 스크롤
  /// 거리" 변환 비율이 드래그 중에 계속 바뀌어 스크롤바가 마우스를 안 따라가고 튄다.
  /// 판단 기준도 pixels가 아니라 보이는 항목 인덱스다(_onItemPositionsChanged 참고).
  void _maybeLoadOlderMessages() {
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    var maxIndex = positions.first.index;
    for (final p in positions) {
      if (p.index > maxIndex) maxIndex = p.index;
    }
    final itemCount = widget.session.controllerFor(widget.room).messages.length;
    // 가장 오래된 항목이 한 화면 안쪽까지 들어왔으면 미리 더 불러온다.
    if (maxIndex >= itemCount - 1 - positions.length) {
      widget.session.controllerFor(widget.room).loadOlderMessages();
    }
  }

  /// 날짜 구분선이 근처에 있을 때만 뜨던 예전 방식(구분선 GlobalKey 히트테스트)은 구분선에서
  /// 멀어지면(=같은 날짜 메시지를 계속 스크롤하는 중) 더 이상 아무 구분선도 안 걸려서 알약이
  /// 꺼져버리는 문제가 있었다. 지금은 뷰포트 맨 위에 있는 항목 자체의 날짜를 매번 직접
  /// 구하므로, 구분선과의 거리와 무관하게 스크롤하는 동안 항상 지금 보는 날짜가 뜬다.
  void _onScrollUpdate(
    ScrollUpdateNotification notification,
    List<Message> msgs,
  ) {
    if (msgs.isEmpty) return;
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;

    // reverse:true라 인덱스가 클수록(오래된 메시지일수록) 위쪽에 있다 — 뷰포트 맨 위(leading
    // edge가 0에 가장 가까움)에 있는 항목을 찾는다.
    var top = positions.first;
    for (final p in positions) {
      if (p.itemLeadingEdge < top.itemLeadingEdge) top = p;
    }
    if (top.index < 0 || top.index >= msgs.length) return;
    final m = msgs[msgs.length - 1 - top.index];
    final found = DateTime(
      m.createdAt.year,
      m.createdAt.month,
      m.createdAt.day,
    );

    setState(() => _floatingDate = found);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _floatingDate = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.session.controllerFor(widget.room);
    return Column(
      children: [
        Expanded(
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              if (controller.loading) {
                return const Center(child: CircularProgressIndicator());
              }
              final msgs = controller.messages;
              if (msgs.isEmpty) {
                return const Center(child: Text('아직 메시지가 없습니다.'));
              }

              final boundary = controller.readBoundary;
              final showReadDivider =
                  boundary > 0 &&
                  msgs.any(
                    (m) => m.createdAt.millisecondsSinceEpoch <= boundary,
                  ) &&
                  msgs.any(
                    (m) => m.createdAt.millisecondsSinceEpoch > boundary,
                  );

              return Stack(
                children: [
                  NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (notification is ScrollUpdateNotification) {
                        _onScrollUpdate(notification, msgs);
                      } else if (notification is ScrollEndNotification) {
                        _maybeLoadOlderMessages();
                      }
                      return false;
                    },
                    child: IndexedScrollbar(
                      positionsListener: _itemPositionsListener,
                      scrollController: _itemScrollController,
                      itemCount: msgs.length,
                      // 높이 캐시가 새 메시지로 인덱스가 밀려도 유지되도록 메시지 id를
                      // 키로 준다(itemBuilder와 동일한 reverse 인덱싱).
                      itemKeyAt: (i) => i >= 0 && i < msgs.length
                          ? msgs[msgs.length - 1 - i].id
                          : null,
                      child: ScrollablePositionedList.builder(
                        key: _listKey,
                        itemScrollController: _itemScrollController,
                        itemPositionsListener: _itemPositionsListener,
                        reverse: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        itemCount: msgs.length,
                        itemBuilder: (context, i) {
                          final m = msgs[msgs.length - 1 - i];
                          final isOldestLoaded = i == msgs.length - 1;
                          final prev = isOldestLoaded
                              ? null
                              : msgs[msgs.length - 2 - i];
                          final showDate =
                              isOldestLoaded ||
                              m.createdAt.year != prev!.createdAt.year ||
                              m.createdAt.month != prev.createdAt.month ||
                              m.createdAt.day != prev.createdAt.day;

                          // 같은 사람이 같은 분(分)에 연달아 보낸 메시지는, 그중 가장 나중(=시간상
                          // 마지막) 메시지에만 시간을 보여준다.
                          final next = i == 0 ? null : msgs[msgs.length - i];
                          final showTime =
                              next == null ||
                              next.senderId != m.senderId ||
                              !_sameMinute(next.createdAt, m.createdAt);

                          // 같은 사람이 연달아 보낸 메시지는 첫 메시지에만 프로필 사진/이름을 보여준다.
                          // 날짜가 바뀌었거나(showDate) 중간에 시스템 메시지(입장/퇴장 알림)나 댓글
                          // 카드가 끼면 그 다음 메시지부터 새로 보여준다.
                          final isFirstInGroup =
                              isOldestLoaded ||
                              showDate ||
                              prev.senderId != m.senderId ||
                              prev.type == MessageType.system ||
                              prev.type == MessageType.comment;

                          Widget row;
                          if (m.type == MessageType.system) {
                            row = SystemMessageRow(message: m);
                          } else if (m.type == MessageType.comment) {
                            final parent = _findMessage(
                              msgs,
                              m.asComment!.messageId,
                            );
                            // 바로 앞 항목이 "같은 원본 메시지"의 댓글이 아니면(=다른 채팅이 끼었거나,
                            // 다른 원본 메시지에 대한 댓글이거나, 여기가 맨 처음이면) 이 댓글이 새 런의
                            // 시작이라 카드를 새로 그린다. 아니면 이미 앞에서 그려진 카드에 흡수되므로
                            // 여기선 아무것도 안 그린다.
                            final isFirstCommentInRun =
                                prev == null ||
                                prev.type != MessageType.comment ||
                                prev.asComment!.messageId !=
                                    m.asComment!.messageId;
                            if (parent == null || !isFirstCommentInRun) {
                              row = const SizedBox.shrink();
                            } else {
                              // 같은 원본 메시지에 대한 댓글이 사이에 다른 채팅 없이 연달아 이어지는
                              // 만큼(런) 전부 모아서, 이 카드 하나 안에서 이어 붙여 보여준다. 런은
                              // 이 댓글부터 뒤로(시간순 정방향) 훑으며 조건이 깨지는 지점에서 끊는다.
                              final ascIdx = msgs.length - 1 - i;
                              final runComments = <Comment>[];
                              var j = ascIdx;
                              while (j < msgs.length &&
                                  msgs[j].type == MessageType.comment &&
                                  msgs[j].asComment!.messageId ==
                                      m.asComment!.messageId) {
                                runComments.add(msgs[j].asComment!);
                                j++;
                              }
                              row = Padding(
                                padding: const EdgeInsets.only(
                                  left: 8,
                                  right: 8,
                                ),
                                child: MessageCommentsCard(
                                  session: widget.session,
                                  parentMessage: parent,
                                  comments: runComments,
                                  room: widget.room,
                                  currentUserId: widget.session.userId,
                                  resolveUrl: widget.session.resolveUrl,
                                  onTap: () =>
                                      widget.onOpenThread?.call(parent),
                                  onEditComment: controller.editComment,
                                  onDeleteComment: controller.deleteComment,
                                ),
                              );
                            }
                          } else {
                            row = MessageBubble(
                              session: widget.session,
                              message: m,
                              resolveUrl: widget.session.resolveUrl,
                              unreadCount: widget.room.unreadCountFor(m),
                              isMine: m.senderId == widget.session.userId,
                              sender: _senderOf(m.senderId),
                              showTime: showTime,
                              showSenderInfo: isFirstInGroup,
                              highlighted: m.id == _highlightedMessageId,
                              onOpenThread: widget.onOpenThread,
                              onEdit: controller.editMessage,
                              onDelete: controller.deleteMessage,
                            );
                          }

                          Widget? divider;
                          if (showDate) {
                            final key = _dividerKeys.putIfAbsent(
                              _dateKey(m.createdAt),
                              () => GlobalKey(),
                            );
                            divider = DateDivider(
                              key: key,
                              date: m.createdAt,
                              onPickDate: () => _openDatePickerFor(m.createdAt),
                            );
                          }

                          final isFirstUnread =
                              showReadDivider &&
                              m.createdAt.millisecondsSinceEpoch > boundary &&
                              (isOldestLoaded ||
                                  prev!.createdAt.millisecondsSinceEpoch <=
                                      boundary);

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ?divider,
                              if (isFirstUnread) const ReadUpToHereDivider(),
                              row,
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                  if (_floatingDate != null)
                    Positioned(
                      top: 8,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: FloatingDatePill(
                          date: _floatingDate!,
                          onPickDate: _toggleDatePicker,
                        ),
                      ),
                    ),
                  if (_showDatePicker && _floatingDate != null)
                    Positioned(
                      top: 48,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: DatePickerPopup(
                          initialMonth: _floatingDate!,
                          selectedDate: _floatingDate,
                          onClose: _closeDatePicker,
                          onDateSelected: _jumpToDate,
                        ),
                      ),
                    ),
                  // 위로 스크롤해서 과거 메시지를 더 불러오는 동안(loadOlderMessages) 잠깐
                  // 보여주는 표시 — reverse:true라 "맨 위"는 화면 상단이다.
                  if (controller.loadingMore)
                    const Positioned(
                      top: 8,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                  // 이모티콘 패널/미리보기는 메시지 목록 영역(이 Stack)의 맨 아래에 떠 있는
                  // 오버레이로 그린다 — 입력창을 밀어내지 않고(레이아웃이 안 바뀌니 채팅 내용이
                  // 위아래로 출렁이지 않는다) 그 위에 겹쳐 보인다(카카오톡 방식). 이 Stack은
                  // Expanded 영역 전체를 실제로 차지하고 있어서(ScrollablePositionedList가
                  // 이미 그만큼 자리를 쓰고 있음) Positioned가 하단 근처 어디에 있든 진짜
                  // 레이아웃 범위 안이라 마우스 클릭도 정상적으로 먹는다(Stack 밖으로 "그림만"
                  // 넘치는 방식과 달리 히트테스트가 안 끊긴다).
                  if (_stickerPickerOpen)
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: StickerPicker(onSelected: _selectSticker),
                    )
                  else if (_pendingSticker != null)
                    // 입력창의 이모티콘 버튼(이미지 버튼 다음 두 번째 아이콘) 바로 위쯤에 오도록
                    // 왼쪽으로 붙인다 — 전체 폭을 채우던 것에서 바꿈.
                    Positioned(
                      left: 10,
                      bottom: 8,
                      child: StickerPreviewCard(
                        sticker: _pendingSticker!,
                        onRemove: _removeSticker,
                      ),
                    ),
                  // "맨 아래로" 버튼 + "새로운 메시지가 있습니다" 알약. 스크롤할 때마다
                  // 바뀌는 상태라 setState 대신 ValueNotifier로 이 부분만 다시 그린다
                  // (_newMessagesBelow의 주석 참고 — 리스트까지 다시 빌드하면 죽는다).
                  Positioned.fill(
                    child: ListenableBuilder(
                      listenable: Listenable.merge([
                        _scrolledPastOnePage,
                        _newMessagesBelow,
                      ]),
                      builder: (context, _) {
                        final showPill = _newMessagesBelow.value;
                        return Stack(
                          children: [
                            // 늘 떠 있진 않고, 맨 아래에서 한 화면 이상 스크롤이 올라가
                            // 있을 때만 보인다(_onItemPositionsChanged 참고).
                            if (_scrolledPastOnePage.value)
                              Positioned(
                                right: 12,
                                // 알약도 같이 떠 있으면 겹치지 않게 그 위로 띄운다.
                                bottom: showPill ? 60 : 12,
                                child: Material(
                                  elevation: 4,
                                  shape: const CircleBorder(),
                                  color: Theme.of(context).colorScheme.surface,
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    onTap: _scrollToBottom,
                                    child: const Padding(
                                      padding: EdgeInsets.all(10),
                                      child: Icon(Icons.keyboard_arrow_down),
                                    ),
                                  ),
                                ),
                              ),
                            // 맨 아래가 아닐 때 남이 보낸 새 메시지가 오면(자동으로
                            // 내려버리지 않는 대신) 이 알약을 띄운다. 누르면 맨 아래로
                            // 스크롤, x를 누르면 (안 읽었더라도) 그냥 닫는다.
                            if (showPill)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 8,
                                child: Center(
                                  child: Material(
                                    elevation: 4,
                                    borderRadius: BorderRadius.circular(20),
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primaryContainer,
                                    clipBehavior: Clip.antiAlias,
                                    child: InkWell(
                                      onTap: _scrollToBottom,
                                      child: Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          14,
                                          8,
                                          6,
                                          8,
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.arrow_downward,
                                              size: 16,
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onPrimaryContainer,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              '새로운 메시지가 있습니다',
                                              style: TextStyle(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onPrimaryContainer,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              onTap: _dismissNewMessagesPill,
                                              child: Padding(
                                                padding: const EdgeInsets.all(
                                                  6,
                                                ),
                                                child: Icon(
                                                  Icons.close,
                                                  size: 16,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onPrimaryContainer,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const Divider(height: 1),
        ChatInputBar(
          controller: controller,
          pendingSticker: _pendingSticker,
          stickerPickerOpen: _stickerPickerOpen,
          onToggleStickerPicker: _toggleStickerPicker,
          onStickerConsumed: _removeSticker,
        ),
      ],
    );
  }
}
