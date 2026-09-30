import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/mention.dart';
import '../models/room.dart';
import '../services/mention_logic.dart';
import 'rich_text_format.dart';
import 'user_avatar.dart';

/// 입력칸 위에 떠서 "@이름"을 자동완성하는 멘션 패널 — 입력칸([child], 보통 TextField)을 감싼다.
///
///   - 글자 "@"를 치면(앞이 글 처음이거나 공백일 때) 방 멤버 중 이름·아이디에 그 뒤 글자가 들어 있는 사람을
///     입력칸 위에 보여 준다. 토픽·그룹이면 맨 위에 `@all`이 붙는다(1:1·나와의 대화는 없다).
///   - PC는 ↑/↓로 고르고 Enter/Tab으로 넣고 Esc로 닫는다. 모바일은 목록을 누른다.
///   - 고르면 입력칸 글자가 "@이름 "으로 바뀌고 [RichTextEditingController]가 그 구간을 멘션으로 잡는다.
///   - 비밀 대화는 멘션을 지원하지 않는다 — 이 위젯이 컨트롤러의 mentionsEnabled도 그에 맞춘다.
///
/// 입력칸에 "@" 단추가 있으면 [MentionAutocompleteState.insertTrigger]를 GlobalKey로 부른다. Enter로
/// 보내는 입력칸(채팅·댓글)은 Enter를 먼저 가로채므로, 패널이 열려 있는 동안([isOpen]) 보내기를 미뤄야 한다.
class MentionAutocomplete extends StatefulWidget {
  final RichTextEditingController controller;
  final FocusNode focusNode;
  final Room room;
  final String? myUserId;
  final String Function(String relative)? resolveUrl;
  final Widget child;

  const MentionAutocomplete({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.room,
    required this.myUserId,
    this.resolveUrl,
    required this.child,
  });

  @override
  State<MentionAutocomplete> createState() => MentionAutocompleteState();
}

class MentionAutocompleteState extends State<MentionAutocomplete> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _scroll = ScrollController();
  static const _rowHeight = 48.0;

  MentionQuery? _query;
  List<MentionCandidate> _candidates = const [];
  int _selected = 0;

  /// Esc로 닫은 "@"의 위치 — 같은 "@"를 계속 치는 동안은 다시 열지 않는다.
  int? _dismissedAt;
  double _width = 0;

  bool get isOpen => _query != null && _candidates.isNotEmpty;

  bool get _enabled => roomAllowsMention(widget.room);

  @override
  void initState() {
    super.initState();
    widget.controller.mentionsEnabled = _enabled;
    widget.controller.addListener(_refresh);
    widget.focusNode.addListener(_refresh);
  }

  @override
  void didUpdateWidget(covariant MentionAutocomplete oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_refresh);
      widget.controller.addListener(_refresh);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_refresh);
      widget.focusNode.addListener(_refresh);
    }
    widget.controller.mentionsEnabled = _enabled;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    widget.focusNode.removeListener(_refresh);
    _scroll.dispose();
    super.dispose();
  }

  void _close() {
    if (_query == null && _candidates.isEmpty) return;
    _query = null;
    _candidates = const [];
    _selected = 0;
    _syncPortal();
    if (mounted) setState(() {});
  }

  void _syncPortal() {
    final show = isOpen;
    if (show == _portal.isShowing) return;
    // 빌드 중에 불릴 수 있어서(컨트롤러 알림) 다음 프레임에 맞춘다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final want = isOpen;
      if (want == _portal.isShowing) return;
      want ? _portal.show() : _portal.hide();
    });
  }

  void _refresh() {
    if (!mounted) return;
    if (!_enabled || !widget.focusNode.hasFocus) {
      _close();
      return;
    }
    final v = widget.controller.value;
    final sel = v.selection;
    final q = sel.isValid && sel.isCollapsed
        ? activeMentionQuery(
            v.text,
            sel.baseOffset,
            existing: widget.controller.mentions,
          )
        : null;
    if (q == null) {
      _dismissedAt = null;
      _close();
      return;
    }
    if (_dismissedAt == q.start) {
      _close();
      return;
    }
    final next = mentionCandidates(
      members: widget.room.members,
      myUserId: widget.myUserId,
      allowAll: roomAllowsMentionAll(widget.room),
      query: q.query,
    );
    final queryChanged = _query != q;
    _query = q;
    _candidates = next;
    if (queryChanged || _selected >= next.length) _selected = 0;
    if (next.isEmpty) {
      _close();
      return;
    }
    _syncPortal();
    setState(() {});
    _ensureSelectedVisible();
  }

  void _ensureSelectedVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final top = _selected * _rowHeight;
      final bottom = top + _rowHeight;
      final pos = _scroll.position;
      if (top < pos.pixels) {
        _scroll.jumpTo(top);
      } else if (bottom > pos.pixels + pos.viewportDimension) {
        _scroll.jumpTo(bottom - pos.viewportDimension);
      }
    });
  }

  /// 입력칸 아래 "@" 단추 — 커서 자리에 "@"를 넣어 자동완성을 연다(앞 글자에 붙어 있으면 공백을 하나 끼운다).
  void insertTrigger() {
    if (!_enabled) return;
    final c = widget.controller;
    final t = c.text;
    final sel = c.selection;
    final start = sel.isValid ? sel.start : t.length;
    final end = sel.isValid ? sel.end : t.length;
    final before = start > 0 ? t.codeUnitAt(start - 1) : null;
    final needSpace =
        before != null &&
        before != 0x20 &&
        before != 0x0A &&
        before != 0x09 &&
        before != 0x3000;
    final insert = needSpace ? ' @' : '@';
    _dismissedAt = null;
    widget.focusNode.requestFocus();
    c.value = TextEditingValue(
      text: t.replaceRange(start, end, insert),
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
  }

  void _choose(MentionCandidate candidate) {
    final q = _query;
    if (q == null) return;
    final caret = widget.controller.selection.baseOffset;
    widget.controller.insertMention(
      start: q.start,
      end: caret < q.start ? q.start + 1 : caret,
      label: candidate.label,
      userId: candidate.userId,
    );
    _dismissedAt = null;
    _close();
    widget.focusNode.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!isOpen) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final isDown = event is KeyDownEvent;
    final isDownOrRepeat = isDown || event is KeyRepeatEvent;
    if (key == LogicalKeyboardKey.arrowDown && isDownOrRepeat) {
      setState(() => _selected = (_selected + 1) % _candidates.length);
      _ensureSelectedVisible();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp && isDownOrRepeat) {
      setState(
        () => _selected =
            (_selected - 1 + _candidates.length) % _candidates.length,
      );
      _ensureSelectedVisible();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.tab) {
      if (isDown) _choose(_candidates[_selected]);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (isDown) {
        _dismissedAt = _query?.start;
        _close();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (!_enabled) return widget.child;
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _buildPopup,
        child: LayoutBuilder(
          builder: (context, constraints) {
            _width = constraints.maxWidth;
            return Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: _onKey,
              child: widget.child,
            );
          },
        ),
      ),
    );
  }

  Widget _buildPopup(BuildContext context) {
    final theme = Theme.of(context);
    final list = _candidates;
    final maxHeight = _rowHeight * 5.5;
    final height = (list.length * _rowHeight).clamp(0.0, maxHeight);
    // 입력칸 위에 자리가 모자라면(창 위쪽에 붙은 큰 입력칸 등) 입력칸 안쪽 위에 겹쳐서 보인다.
    final box = this.context.findRenderObject();
    final spaceAbove = box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero).dy
        : double.infinity;
    final above = spaceAbove >= height + 8;
    return CompositedTransformFollower(
      link: _link,
      showWhenUnlinked: false,
      targetAnchor: Alignment.topLeft,
      followerAnchor: above ? Alignment.bottomLeft : Alignment.topLeft,
      offset: above ? const Offset(0, -4) : const Offset(0, 4),
      // 따라다니는 칸은 오버레이 크기만큼 채워지므로(RawAutocomplete와 같다) 패널을 그 안에서 붙일 모서리에 정렬한다.
      child: Align(
        alignment: above ? Alignment.bottomLeft : Alignment.topLeft,
        child: TextFieldTapRegion(
          child: SizedBox(
            width: _width,
            child: Material(
              key: const ValueKey('mention-popup'),
              elevation: 6,
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(10),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                height: height,
                child: ListView.builder(
                  controller: _scroll,
                  padding: EdgeInsets.zero,
                  itemExtent: _rowHeight,
                  itemCount: list.length,
                  itemBuilder: (context, i) => _MentionRow(
                    key: ValueKey('mention-option-$i'),
                    candidate: list[i],
                    selected: i == _selected,
                    resolveUrl: widget.resolveUrl,
                    onTap: () => _choose(list[i]),
                    onHover: () {
                      if (_selected != i) setState(() => _selected = i);
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MentionRow extends StatelessWidget {
  final MentionCandidate candidate;
  final bool selected;
  final String Function(String relative)? resolveUrl;
  final VoidCallback onTap;
  final VoidCallback onHover;
  const _MentionRow({
    super.key,
    required this.candidate,
    required this.selected,
    required this.resolveUrl,
    required this.onTap,
    required this.onHover,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final user = candidate.user;
    final title = candidate.isAll ? '@all' : user!.name;
    final sub = candidate.isAll
        ? '이 대화의 모든 멤버에게 알림'
        : [user!.username, if (user.orgLine != null) user.orgLine!].join(' · ');
    return Material(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.12)
          : Colors.transparent,
      child: InkWell(
        canRequestFocus: false,
        onTap: onTap,
        onHover: (hovering) {
          if (hovering) onHover();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              if (candidate.isAll)
                CircleAvatar(
                  radius: 14,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(
                    Icons.alternate_email,
                    size: 16,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                )
              else
                UserAvatar(user: user!, resolveUrl: resolveUrl, radius: 14),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 입력칸 아래 줄의 "@" 단추 — 커서 자리에 "@"를 넣어 멘션 자동완성을 연다.
class MentionButton extends StatelessWidget {
  final VoidCallback? onPressed;
  const MentionButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const ValueKey('mention-button'),
      // 투표 단추처럼 촘촘한 폭(40) — 입력칸 아래 단추 줄이 좁은 화면에서 넘치지 않게.
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.alternate_email),
      tooltip: '멘션',
      onPressed: onPressed,
    );
  }
}

/// 멘션이 들어간 글을 보낼 때 같이 보낼 목록 — 입력칸 컨트롤러와 방에서 바로 만든다.
List<Mention> mentionsToSend(
  RichTextEditingController controller,
  Room room,
  String? myUserId,
) => roomAllowsMention(room)
    ? controller.formattedMentions(
        allowAll: roomAllowsMentionAll(room),
        selfUserId: myUserId,
      )
    : const [];
