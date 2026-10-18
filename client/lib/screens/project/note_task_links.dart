import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../models/project.dart';
import '../../services/app_links.dart';
import '../../widgets/rich_text_format.dart';
import 'note_markdown.dart' show notePlainLinkText;
import '../../l10n/tr.dart';

// 노트 편집기의 "/" 업무 링크.
//
// 줄 맨 앞이나 공백 뒤에서 "/"를 치면 그 글자 바로 아래에 이 노트가 속한 프로젝트의 업무 목록이
// 뜬다. 이어서 치는 글자로 번호·제목을 거르고(↑/↓ 이동, Enter·Tab 고르기, Esc 닫기, 마우스·터치로
// 누르기), 고르면 "/검색어"가 "MKT-1001 제목" 업무 링크(업무 번호 칩을 복사할 때와 같은 AppLinks.task
// 주소)로 바뀐다 — 보기 화면에서 누르면 그 업무가 열린다.
//
// 목록은 Overlay에 띄우고 포커스는 입력칸에 그대로 둔다(포커스가 옮겨 가면 한글 조합이 끊긴다).
// 조합 중에는 글을 고치지 않는다 — 조합 중에 누른 Enter·Tab은 조합이 끝난 뒤에 고른다.

bool _isSpace(int c) =>
    c == 0x20 ||
    c == 0x0A ||
    c == 0x09 ||
    c == 0x0D ||
    c == 0xA0 ||
    c == 0x3000;

bool _composing(TextEditingValue v) =>
    v.composing.isValid && !v.composing.isCollapsed;

/// [old]에서 [next]로 바뀐 것이 커서 자리에 "/" 한 글자를 친 것이고, 그 앞이 글 맨 앞·줄 맨 앞·공백이면
/// 그 "/"의 위치. 아니면 null — "a/b"처럼 낱말 안의 "/", 붙여넣기, 도구모음으로 넣은 글은 무시한다.
int? noteSlashTriggerAt(TextEditingValue old, TextEditingValue next) {
  final o = old.text, n = next.text;
  if (n.length != o.length + 1) return null;
  final sel = next.selection;
  if (!sel.isValid || !sel.isCollapsed) return null;
  final at = sel.baseOffset - 1;
  if (at < 0 || at >= n.length || n.codeUnitAt(at) != 0x2F) return null;
  if (n.substring(0, at) != o.substring(0, at) ||
      n.substring(at + 1) != o.substring(at)) {
    return null;
  }
  return at == 0 || _isSpace(n.codeUnitAt(at - 1)) ? at : null;
}

/// "/" 뒤에 친 [query]로 업무를 거르고 순서를 매긴다. 공백으로 나눈 낱말이 번호나 제목에 모두 들어
/// 있어야 걸리고, 번호가 딱 맞음 → 번호로 시작 → 제목으로 시작 → 제목에 포함 → 나머지 순, 같은
/// 무리 안에서는 최근에 만든 업무가 먼저. 검색어가 없으면 최근에 만든 순.
List<Task> noteTaskLinkMatches(List<Task> tasks, String query) {
  final q = query.trim().toLowerCase();
  final words = q.isEmpty ? const <String>[] : q.split(RegExp(r'\s+'));
  final ranked = <(int, Task)>[];
  for (final t in tasks) {
    final key = (t.key ?? '').toLowerCase();
    final title = t.title.toLowerCase();
    final all = '$key $title';
    if (!words.every(all.contains)) continue;
    final number = key.substring(key.lastIndexOf('-') + 1);
    final rank = q.isEmpty
        ? 0
        : key == q
        ? 0
        : key.startsWith(q) || number.startsWith(q)
        ? 1
        : title.startsWith(q)
        ? 2
        : title.contains(q)
        ? 3
        : 4;
    ranked.add((rank, t));
  }
  ranked.sort((a, b) {
    if (a.$1 != b.$1) return a.$1 - b.$1;
    final byDate = b.$2.createdAt.compareTo(a.$2.createdAt);
    return byDate != 0 ? byDate : (b.$2.key ?? '').compareTo(a.$2.key ?? '');
  });
  return [for (final (_, t) in ranked) t];
}

/// 업무 링크로 넣을 글 — "MKT-1001 제목". 제목의 "*"·"`"·대괄호 등이 저장 뒤 서식으로 읽히지 않게.
String noteTaskLinkLabel(Task t) =>
    notePlainLinkText(t.key == null ? t.title : '${t.key} ${t.title}');

/// 노트 본문 입력칸([child])을 감싸 "/" 업무 링크 목록을 붙인다.
class NoteTaskLinkMenu extends StatefulWidget {
  final RichTextEditingController controller;
  final FocusNode focusNode;

  /// 노트가 속한(새 노트면 들어갈) 프로젝트 — 없으면 "/"를 쳐도 목록이 뜨지 않는다.
  final String? projectId;
  final String? projectName;
  final String? projectColor;

  /// 프로젝트 업무 목록 — 편집기를 연 동안 프로젝트마다 한 번만 부른다.
  final Future<List<Task>> Function(String projectId) loadTasks;

  /// 읽기 전용 편집기면 false.
  final bool enabled;
  final Widget child;

  const NoteTaskLinkMenu({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.projectId,
    this.projectName,
    this.projectColor,
    required this.loadTasks,
    this.enabled = true,
    required this.child,
  });

  @override
  State<NoteTaskLinkMenu> createState() => _NoteTaskLinkMenuState();
}

class _NoteTaskLinkMenuState extends State<NoteTaskLinkMenu> {
  static const _rowHeight = 38.0;
  static const _maxRows = 50;

  final _portal = OverlayPortalController();
  final _anchorKey = GlobalKey();
  final _scroll = ScrollController();

  /// 바로 전 값 — "/"를 막 쳤는지 비교할 기준(initState에서 채운다; 늦게 채우면 첫 글자를 놓친다).
  late TextEditingValue _last;

  /// 열려 있으면 "/" 글자의 위치와 그 뒤에 친 검색어, 고른 줄.
  int? _slashAt;
  String _query = '';
  int _index = 0;

  /// 마지막으로 글을 친 뒤의 커서 — 글은 그대로인데 커서만 여기서 옮겨 가면(←/→·Home/End·클릭)
  /// 닫는다. 그러지 않으면 "/" 뒤에 원래 있던 글이 검색어가 되고, 고를 때 그 글이 지워진다.
  int? _typedCaret;

  /// "/" 글자 자리(감싼 입력칸 기준) — 그린 뒤에 재서 목록을 그 아래에 붙인다.
  Rect? _slashRect;
  bool _measureScheduled = false;

  /// 불러온 업무 목록(보관 제외)과 그게 어느 프로젝트 것인지.
  String? _tasksFor;
  List<Task>? _tasks;
  bool _loadFailed = false;

  /// 한글 조합 중에 Enter·Tab을 눌렀으면 조합이 끝난 뒤에 고른다.
  bool _pickPending = false;
  Timer? _pickTimer;

  /// 고른 업무를 넣는 중 — 그 사이의 글 변경을 "/" 입력으로 보지 않게.
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _last = widget.controller.value;
    widget.controller.addListener(_onChanged);
    widget.focusNode.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(NoteTaskLinkMenu old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
      _last = widget.controller.value;
    }
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_onFocus);
      widget.focusNode.addListener(_onFocus);
    }
    if (old.projectId != widget.projectId) {
      _tasksFor = null;
      _tasks = null;
      _loadFailed = false;
      if (_slashAt != null) _close();
    }
    if (!widget.enabled && _slashAt != null) _close();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    widget.focusNode.removeListener(_onFocus);
    _pickTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  // ── 열기 · 닫기 ──

  bool get _inFrame =>
      SchedulerBinding.instance.schedulerPhase ==
      SchedulerPhase.persistentCallbacks;

  /// Overlay를 상태에 맞춰 띄우거나 내린다 — 빌드 중에는 부르면 안 돼서 그때는 그린 뒤로 미룬다.
  void _syncPortal() {
    void apply() {
      if (!mounted) return;
      final want = _slashAt != null;
      if (want && !_portal.isShowing) _portal.show();
      if (!want && _portal.isShowing) _portal.hide();
    }

    if (_inFrame) {
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  void _open(int at) {
    _slashAt = at;
    _typedCaret = at + 1;
    _query = '';
    _index = 0;
    _slashRect = null;
    _pickPending = false;
    _ensureTasks();
    _syncPortal();
    if (!_inFrame) setState(() {});
    _measure();
  }

  void _close() {
    _pickTimer?.cancel();
    _pickPending = false;
    final wasOpen = _slashAt != null;
    _slashAt = null;
    _typedCaret = null;
    _slashRect = null;
    _query = '';
    _index = 0;
    _syncPortal();
    if (wasOpen && mounted && !_inFrame) setState(() {});
  }

  void _ensureTasks() {
    final id = widget.projectId;
    if (id == null || _tasksFor == id) return;
    _tasksFor = id;
    _tasks = null;
    _loadFailed = false;
    widget
        .loadTasks(id)
        .then(
          (list) {
            if (!mounted || _tasksFor != id) return;
            setState(
              () => _tasks = [
                for (final t in list)
                  if (!t.archived) t,
              ],
            );
          },
          onError: (Object _) {
            if (!mounted || _tasksFor != id) return;
            // 다음에 "/"를 치면 다시 불러 본다.
            setState(() {
              _tasksFor = null;
              _loadFailed = true;
            });
          },
        );
  }

  List<Task> _results() {
    final tasks = _tasks;
    if (tasks == null) return const [];
    final list = noteTaskLinkMatches(tasks, _query);
    return list.length > _maxRows ? list.sublist(0, _maxRows) : list;
  }

  // ── 입력 따라가기 ──

  /// 지금 값에서 "/" 뒤의 검색어 — 목록을 닫아야 하면 null(커서가 "/" 앞으로 갔거나 "/"가 지워짐,
  /// 줄이 바뀜, 공백으로 시작함, 너무 김, 글자를 드래그로 고름).
  String? _activeQuery(TextEditingValue v) {
    final at = _slashAt!;
    final t = v.text;
    final sel = v.selection;
    if (!sel.isValid || !sel.isCollapsed) return null;
    final caret = sel.baseOffset;
    if (at >= t.length || t.codeUnitAt(at) != 0x2F || caret <= at) return null;
    if (caret > t.length) return null;
    final q = t.substring(at + 1, caret);
    if (q.contains('\n') || q.length > 40) return null;
    if (q.isNotEmpty && _isSpace(q.codeUnitAt(0))) return null;
    return q;
  }

  void _onChanged() {
    final v = widget.controller.value;
    final old = _last;
    _last = v;
    if (_picking) return;
    if (_slashAt == null) {
      if (!widget.enabled || widget.projectId == null) return;
      if (v.text == old.text || !widget.focusNode.hasFocus) return;
      final at = noteSlashTriggerAt(old, v);
      if (at != null) _open(at);
      return;
    }
    final q = _activeQuery(v);
    if (q == null) {
      _close();
      return;
    }
    if (v.text != old.text) {
      _typedCaret = v.selection.baseOffset;
    } else if (v.selection.baseOffset != _typedCaret) {
      // 글은 그대로 두고 커서만 옮겼다(←/→·Home/End·클릭).
      _close();
      return;
    }
    if (q != _query) {
      setState(() {
        _query = q;
        _index = 0;
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _measure();
    }
    if (_pickPending && !_composing(v)) {
      _pickPending = false;
      _pickTimer?.cancel();
      // 입력기는 조합을 끝내는 값(확정·조합 끝)을 연달아 보내기도 해서, 그게 다 들어온 뒤(한 번
      // 그린 뒤)에 글을 바꾼다 — 먼저 바꾸면 뒤따라온 예전 값이 고른 링크를 덮어쓴다.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _slashAt == null) return;
        if (_composing(widget.controller.value)) return;
        final items = _results();
        if (items.isEmpty) return;
        _pick(items[_index.clamp(0, items.length - 1)]);
      });
      SchedulerBinding.instance.ensureVisualUpdate();
    }
  }

  void _onFocus() {
    if (!widget.focusNode.hasFocus) _close();
  }

  // ── 자리 재기 ──

  static RenderEditable? _findEditable(RenderObject o) {
    if (o is RenderEditable) return o;
    RenderEditable? found;
    o.visitChildren((child) => found ??= _findEditable(child));
    return found;
  }

  /// 그린 뒤에 "/" 글자 자리를 잰다(입력칸이 스크롤되거나 줄이 바뀌면 다시).
  void _measure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (!mounted || _slashAt == null) return;
      final r = _slashCaretRect();
      if (r != _slashRect) setState(() => _slashRect = r);
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  Rect? _slashCaretRect() {
    final at = _slashAt;
    final host = _anchorKey.currentContext?.findRenderObject();
    if (at == null || host is! RenderBox || !host.attached || !host.hasSize) {
      return null;
    }
    final editable = _findEditable(host);
    if (editable == null || !editable.attached || !editable.hasSize) {
      return null;
    }
    if (at > widget.controller.text.length) return null;
    final caret = editable.getLocalRectForCaret(TextPosition(offset: at));
    return MatrixUtils.transformRect(editable.getTransformTo(host), caret);
  }

  // ── 키보드 ──

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_slashAt == null || !widget.enabled) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final hw = HardwareKeyboard.instance;
    if (hw.isControlPressed || hw.isAltPressed || hw.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final composing = _composing(widget.controller.value);
    if (key == LogicalKeyboardKey.escape) {
      // 조합 중의 Esc는 입력기 몫.
      if (composing) return KeyEventResult.ignored;
      _close();
      return KeyEventResult.handled;
    }
    final items = _results();
    final down = key == LogicalKeyboardKey.arrowDown;
    if (down || key == LogicalKeyboardKey.arrowUp) {
      if (items.isEmpty) return KeyEventResult.ignored;
      setState(() {
        _index =
            (_index.clamp(0, items.length - 1) + (down ? 1 : -1)) %
            items.length;
      });
      _reveal();
      return KeyEventResult.handled;
    }
    final enter =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    final tab = key == LogicalKeyboardKey.tab && !hw.isShiftPressed;
    if (!enter && !tab) return KeyEventResult.ignored;
    if (items.isEmpty) {
      // 고를 게 없으면 목록만 닫고 키는 원래대로(Enter는 줄바꿈·목록 잇기).
      _close();
      return KeyEventResult.ignored;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (composing) {
      _pickPending = true;
      _pickTimer?.cancel();
      _pickTimer = Timer(
        const Duration(milliseconds: 600),
        () => _pickPending = false,
      );
      return KeyEventResult.handled;
    }
    _pick(items[_index.clamp(0, items.length - 1)]);
    return KeyEventResult.handled;
  }

  /// 키보드로 고른 줄이 목록 밖에 있으면 보이게 스크롤한다.
  void _reveal() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final top = _index * _rowHeight;
    final bottom = top + _rowHeight;
    if (top < pos.pixels) {
      _scroll.jumpTo(top);
    } else if (bottom > pos.pixels + pos.viewportDimension) {
      _scroll.jumpTo(bottom - pos.viewportDimension);
    }
  }

  // ── 고르기 ──

  /// "/" 글자에서 링크 글로 옮겨 줄 서식(코드는 빼고 — 링크 글은 코드로 넣지 않는다).
  static const _carriedFlags = [
    Fmt.bold,
    Fmt.italic,
    Fmt.underline,
    Fmt.strike,
    Fmt.quote,
    Fmt.h1,
    Fmt.h2,
    Fmt.h3,
  ];

  /// "/검색어"를 [task] 링크("MKT-1001 제목")로 바꾸고 뒤에 한 칸 띄운다.
  void _pick(Task task) {
    final at = _slashAt;
    if (at == null) return;
    final c = widget.controller;
    final v = c.value;
    if (at >= v.text.length || v.text.codeUnitAt(at) != 0x2F) {
      _close();
      return;
    }
    final caret = v.selection.isValid ? v.selection.baseOffset : v.text.length;
    final end = caret.clamp(at + 1, v.text.length);
    _close();
    final label = noteTaskLinkLabel(task);
    final href = AppLinks.task(
      id: task.id,
      key: task.key,
      title: task.title,
      project: widget.projectName ?? task.projectName,
      color: widget.projectColor,
      person: task.assigneeName,
    );
    _picking = true;
    try {
      // 링크 글은 "/" 글자의 서식을 이어받는다 — 제목·인용 줄 맨 앞에서 골라도 그 줄 서식이 남게
      // (applyLink는 커서 앞 글자, 곧 앞줄 줄바꿈의 서식을 줘서 줄 서식이 빠진다).
      c.selection = TextSelection(baseOffset: at, extentOffset: at + 1);
      final want = {for (final f in _carriedFlags) f: c.isActive(f)};
      final color = c.currentColor;
      c.value = TextEditingValue(
        text: v.text.replaceRange(at, end, ''),
        selection: TextSelection.collapsed(offset: at),
      );
      c.applyLink(href, label: label);
      final after = at + label.length;
      c.selection = TextSelection(baseOffset: at, extentOffset: after);
      for (final f in _carriedFlags) {
        if (c.isActive(f) != want[f]) c.toggle(f);
      }
      if (c.currentColor != color) c.applyColor(color);
      final t = c.text;
      if (after < t.length && t.codeUnitAt(after) == 0x20) {
        c.selection = TextSelection.collapsed(offset: after + 1);
      } else {
        c.value = TextEditingValue(
          text: t.replaceRange(after, after, ' '),
          selection: TextSelection.collapsed(offset: after + 1),
        );
      }
    } finally {
      _picking = false;
    }
    if (!widget.focusNode.hasFocus) widget.focusNode.requestFocus();
  }

  // ── 그리기 ──

  @override
  Widget build(BuildContext context) {
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _portal,
      overlayChildBuilder: (context, info) {
        final r = _slashRect;
        if (_slashAt == null || r == null) return const SizedBox.shrink();
        return CustomSingleChildLayout(
          delegate: _MenuLayout(
            anchor: MatrixUtils.transformRect(info.childPaintTransform, r),
            bottomInset: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: _menu(context),
        );
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: NotificationListener<ScrollNotification>(
          onNotification: (_) {
            if (_slashAt != null) _measure();
            return false;
          },
          child: KeyedSubtree(key: _anchorKey, child: widget.child),
        ),
      ),
    );
  }

  Widget _menu(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final items = _results();
    final keyColor = parseTypeColor(widget.projectColor);
    final desktop = switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };

    Widget message(String text, {bool busy = false}) => Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      child: Row(
        children: [
          if (busy) ...[
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
          ],
          Flexible(
            child: Text(text, style: TextStyle(fontSize: 13, color: hint)),
          ),
        ],
      ),
    );

    final Widget body;
    if (_tasks == null) {
      body = _loadFailed
          ? message(tr('업무를 불러오지 못했습니다.'))
          : message(tr('업무를 불러오는 중...'), busy: true);
    } else if (items.isEmpty) {
      body = message(tr('일치하는 업무가 없습니다.'));
    } else {
      final selected = _index.clamp(0, items.length - 1);
      body = ListView.builder(
        controller: _scroll,
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 4),
        itemExtent: _rowHeight,
        itemCount: items.length,
        itemBuilder: (context, i) {
          final t = items[i];
          final on = i == selected;
          // 마우스를 실제로 움직였을 때만 고른 줄을 옮긴다 — 목록이 가만히 있는 마우스 아래에 뜨거나
          // ↑/↓로 스크롤돼 그 아래로 지나가도(들어옴 이벤트만 온다) 키보드로 고른 줄이 바뀌지 않게.
          return MouseRegion(
            onHover: (e) {
              if (e.delta != Offset.zero && _index != i) {
                setState(() => _index = i);
              }
            },
            child: InkWell(
              canRequestFocus: false,
              hoverColor: Colors.transparent,
              onTap: () => _pick(t),
              child: Container(
                color: on
                    ? theme.colorScheme.primary.withValues(alpha: 0.09)
                    : null,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(
                      Icons.task_alt,
                      size: 16,
                      color: on ? theme.colorScheme.primary : hint,
                    ),
                    const SizedBox(width: 8),
                    if (t.key != null) ...[
                      Text(
                        t.key!,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: keyColor,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: on ? FontWeight.w600 : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    }

    // 목록을 눌러도 입력칸 밖을 누른 것으로 치지 않게(포커스·조합이 그대로 남도록).
    return TextFieldTapRegion(
      child: Material(
        color: theme.colorScheme.surface,
        elevation: 8,
        shadowColor: Colors.black38,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: theme.dividerColor),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
              child: Row(
                children: [
                  Text(
                    tr('업무 링크'),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: hint,
                    ),
                  ),
                  if (_query.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '"$_query"',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: hint),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Flexible(child: body),
            if (desktop && items.isNotEmpty) ...[
              Divider(height: 1, color: theme.dividerColor),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                child: Text(
                  tr('↑↓ 이동 · Enter 넣기 · Esc 닫기'),
                  style: TextStyle(fontSize: 11, color: hint),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 목록 자리 — "/" 글자 바로 아래(왼쪽 맞춤). 아래 공간(키보드가 올라와 있으면 그 위까지)이
/// 모자라면 글자 위로 띄우고, 양쪽 다 모자라면 넓은 쪽에 그 높이만큼 줄여 넣는다 — 목록이 치고
/// 있는 줄을 가리지 않게. 옆으로는 창 밖으로 나가지 않게 안쪽으로 민다.
class _MenuLayout extends SingleChildLayoutDelegate {
  final Rect anchor;
  final double bottomInset;
  const _MenuLayout({required this.anchor, required this.bottomInset});

  static const _gap = 4.0;
  static const _margin = 8.0;
  static const _maxHeight = 320.0;

  double _below(Size size) =>
      size.height - bottomInset - _margin - (anchor.bottom + _gap);
  double _above() => anchor.top - _gap - _margin;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = math.max(
      0.0,
      math.min(380.0, constraints.maxWidth - _margin * 2),
    );
    final room = math.max(_below(constraints.biggest), _above());
    return BoxConstraints(
      minWidth: width,
      maxWidth: width,
      maxHeight: math.max(0.0, math.min(_maxHeight, room)),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final below = _below(size), above = _above();
    final top = childSize.height <= below || below >= above
        ? anchor.bottom + _gap
        : anchor.top - _gap - childSize.height;
    final left = anchor.left
        .clamp(
          _margin,
          math.max(_margin, size.width - childSize.width - _margin),
        )
        .toDouble();
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_MenuLayout old) =>
      old.anchor != anchor || old.bottomInset != bottomInset;
}
