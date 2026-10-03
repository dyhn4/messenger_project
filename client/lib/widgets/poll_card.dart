import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';

import '../models/message.dart';
import '../models/poll.dart';
import '../models/room.dart';
import '../services/edit_policy.dart';
import '../services/session.dart';
import 'app_toast.dart';
import 'attachment_widgets.dart';

/// 투표 카드 — 채팅 말풍선 안, 보드 목록, "즐겨찾기한 투표" 목록에서 같이 쓴다. 제목·설명·배지·마감
/// 시각, 보기(라디오/체크박스 + 득표 막대·수·비율), 참여자 수, 투표하기/다시 투표하기 버튼, 더보기(⋯)
/// 메뉴(댓글·즐겨찾기·투표 마감·삭제)를 그린다.
///
/// 값은 [message]의 poll에서 그때그때 읽는다 — 채팅 화면은 컨트롤러가 같은 Message 인스턴스를
/// 그 자리에서 바꾸고 다시 그리기 때문이다. 이 카드가 직접 한 조작(투표·마감·즐겨찾기)은 응답으로
/// 받은 값을 [message]에도 넣어서, 컨트롤러에 없는 사본(즐겨찾기 목록)에서도 바로 바뀌어 보인다.
class PollCard extends StatefulWidget {
  final Session session;
  final Message message;

  /// 이 투표가 속한 방(권한 판단용) — 없으면 세션 목록에서 찾는다.
  final Room? room;

  /// "댓글" 진입 — 기존 메시지 댓글 진입 방식과 같다(없으면 메뉴에서 뺀다. 댓글 화면 안에서 쓸 때).
  final void Function(Message message)? onOpenThread;

  /// 삭제 확인 뒤 실제로 지우는 함수(보통 RoomChatController.deleteMessage) — 없으면 API로 직접 지운다.
  final Future<void> Function(String messageId)? onDelete;

  /// 이 카드가 값을 바꾼 뒤(투표·마감·즐겨찾기) / 삭제한 뒤 — 사본을 들고 있는 화면이 다시 그린다.
  final VoidCallback? onChanged;

  /// 카드 최대 폭. 넓은 화면에서 카드가 한없이 늘어나지 않게 한다(좁으면 주어진 폭을 다 쓴다).
  final double maxWidth;

  const PollCard({
    super.key,
    required this.session,
    required this.message,
    this.room,
    this.onOpenThread,
    this.onDelete,
    this.onChanged,
    this.maxWidth = 420,
  });

  @override
  State<PollCard> createState() => _PollCardState();
}

class _PollCardState extends State<PollCard> {
  /// 사용자가 보기를 눌러 직접 고른 선택 — 눌러 보기 전에는 서버의 내 선택(myOptionIds)을 그대로 쓴다.
  Set<String>? _picked;

  /// "다시 투표하기"를 눌러 선택을 바꾸는 중.
  bool _revoting = false;
  bool _busy = false;
  String? _error;
  Timer? _closeTimer;
  DateTime? _timerFor;

  Poll? get _poll => widget.message.poll;

  Room? get _room =>
      widget.room ?? widget.session.roomById(widget.message.roomId);

  @override
  void initState() {
    super.initState();
    _scheduleCloseTimer();
  }

  @override
  void didUpdateWidget(covariant PollCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.id != widget.message.id) {
      _picked = null;
      _revoting = false;
      _error = null;
    }
    _scheduleCloseTimer();
  }

  @override
  void dispose() {
    _closeTimer?.cancel();
    super.dispose();
  }

  /// 마감 시각이 지나면 서버가 따로 알리지 않으므로(규약) 그 시각에 맞춰 카드를 다시 그려 마감으로
  /// 바꾼다. 이미 마감됐거나 마감 시각이 안 바뀌었으면 건드리지 않는다.
  void _scheduleCloseTimer() {
    final poll = _poll;
    if (poll == null || poll.isClosed()) {
      _closeTimer?.cancel();
      _closeTimer = null;
      _timerFor = null;
      return;
    }
    if (_timerFor == poll.closesAt && _closeTimer != null) return;
    _closeTimer?.cancel();
    _timerFor = poll.closesAt;
    final wait = poll.closesAt.difference(DateTime.now());
    _closeTimer = Timer(wait + const Duration(milliseconds: 300), () {
      if (mounted) setState(() {});
    });
  }

  Set<String> _selection(Poll poll) => _picked ?? poll.myOptionIds.toSet();

  bool get _canManage {
    final poll = _poll;
    if (poll == null) return false;
    final mine =
        poll.creatorId != null && poll.creatorId == widget.session.userId;
    return mine ||
        (_room?.canManage(widget.session) ?? false) ||
        widget.session.canModerateContent;
  }

  void _toggle(Poll poll, PollOption option) {
    final next = {..._selection(poll)};
    if (poll.multiple) {
      if (!next.remove(option.id)) next.add(option.id);
    } else {
      next
        ..clear()
        ..add(option.id);
    }
    setState(() {
      _picked = next;
      _error = null;
    });
  }

  Future<void> _vote(Poll poll) async {
    if (_busy) return;
    // 등록된 순서대로 보내 서버 응답이 같은 순서가 되게 한다.
    final chosen = _selection(poll);
    final ids = [
      for (final o in poll.options)
        if (chosen.contains(o.id)) o.id,
    ];
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final updated = await widget.session.votePoll(poll, ids);
      widget.message.poll = updated;
      if (!mounted) return;
      setState(() {
        _picked = null;
        _revoting = false;
      });
      widget.onChanged?.call();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleFavorite(Poll poll) async {
    try {
      final now = await widget.session.setPollFavorite(
        widget.message,
        !poll.favorite,
      );
      widget.message.poll = _poll?.copyWith(favorite: now);
      if (!mounted) return;
      setState(() {});
      widget.onChanged?.call();
      showAppToast(context, now ? '즐겨찾기에 추가했습니다.' : '즐겨찾기에서 뺐습니다.');
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    }
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              action,
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _close(Poll poll) async {
    if (!await _confirm(
      '투표 마감',
      "'${poll.title}' 투표를 마감할까요? 마감하면 더 이상 투표할 수 없습니다.",
      '마감',
    )) {
      return;
    }
    try {
      final updated = await widget.session.closePoll(poll);
      widget.message.poll = updated;
      if (!mounted) return;
      setState(() => _revoting = false);
      widget.onChanged?.call();
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    }
  }

  Future<void> _delete(Poll poll) async {
    final mine =
        poll.creatorId != null && poll.creatorId == widget.session.userId;
    if (!await _confirm(
      '투표 삭제',
      mine
          ? "'${poll.title}' 투표를 삭제할까요?"
          : "관리자 권한으로 '${poll.title}' 투표를 삭제합니다. 계속할까요?",
      '삭제',
    )) {
      return;
    }
    try {
      final onDelete = widget.onDelete;
      if (onDelete != null) {
        await onDelete(widget.message.id);
      } else {
        await widget.session.api!.deleteMessage(widget.message.id);
        widget.message.deleted = true;
      }
      if (!mounted) return;
      setState(() {});
      widget.onChanged?.call();
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    }
  }

  void _showVoters(Poll poll, PollOption option) {
    final voters = option.voters ?? const <PollVoter>[];
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          '${option.text} · ${option.voteCount}표',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: SizedBox(
          width: 320,
          child: voters.isEmpty
              ? const Text('투표한 사람이 없습니다.')
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final v in voters)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.person_outline, size: 20),
                          title: Text(v.name.isEmpty ? '(알 수 없음)' : v.name),
                        ),
                    ],
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final poll = _poll;
    if (poll == null) {
      return Text(
        widget.message.text ?? '',
        style: const TextStyle(fontWeight: FontWeight.w600),
      );
    }
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final closed = poll.isClosed();
    final deleted = widget.message.deleted;
    final canVote = !closed && !deleted;
    final interactive = canVote && (!poll.hasVoted || _revoting);
    final selection = _selection(poll);
    final changed = !setEquals(selection, poll.myOptionIds.toSet());
    final canSubmit =
        interactive &&
        !_busy &&
        changed &&
        (selection.isNotEmpty || poll.hasVoted);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth < widget.maxWidth
                  ? constraints.maxWidth
                  : widget.maxWidth
            : widget.maxWidth;
        return SizedBox(
          width: width,
          child: Column(
            key: ValueKey('poll-card-${poll.id}'),
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(context, poll, closed),
              const SizedBox(height: 4),
              Text(
                poll.title,
                key: const ValueKey('poll-title'),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  height: 1.35,
                ),
              ),
              if (poll.description != null &&
                  poll.description!.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  poll.description!,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                ),
              ],
              // 보드 뷰 토픽의 투표에만 붙는 첨부(사진은 격자, 파일은 목록).
              ..._attachmentWidgets(),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (poll.anonymous)
                    _Badge(label: '익명 투표', icon: Icons.visibility_off_outlined),
                  if (poll.multiple)
                    _Badge(label: '복수 선택', icon: Icons.checklist),
                  if (closed)
                    _Badge(
                      label: '마감됨',
                      icon: Icons.lock_outline,
                      color: theme.colorScheme.error,
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                closed
                    ? '${formatPollTime(poll.closedAt ?? poll.closesAt)}에 마감됨'
                    : '~ ${formatPollTime(poll.closesAt)} 마감',
                key: const ValueKey('poll-deadline'),
                style: TextStyle(fontSize: 12, color: hint),
              ),
              const SizedBox(height: 8),
              for (final option in poll.options)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _OptionRow(
                    option: option,
                    ratio: poll.ratioOf(option),
                    multiple: poll.multiple,
                    interactive: interactive && !_busy,
                    selected: selection.contains(option.id),
                    mine: poll.myOptionIds.contains(option.id),
                    anonymous: poll.anonymous,
                    onTap: () => _toggle(poll, option),
                    onShowVoters: () => _showVoters(poll, option),
                  ),
                ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Icon(Icons.people_outline, size: 15, color: hint),
                  const SizedBox(width: 4),
                  Text(
                    '참여자 ${poll.voterCount}명',
                    key: const ValueKey('poll-voters'),
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                  if (_commentCount > 0 && widget.onOpenThread != null) ...[
                    const SizedBox(width: 10),
                    InkWell(
                      key: const ValueKey('poll-comments'),
                      onTap: () => widget.onOpenThread!(widget.message),
                      child: Text(
                        '댓글 $_commentCount',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _error!,
                    key: const ValueKey('poll-error'),
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              if (canVote) ...[
                const SizedBox(height: 8),
                _buildActions(context, poll, interactive, canSubmit, selection),
              ],
            ],
          ),
        );
      },
    );
  }

  List<Widget> _attachmentWidgets() {
    final message = widget.message;
    final images = [
      for (final a in message.liveAttachments)
        if (a.isImage) a,
    ];
    final files = [
      for (final a in message.liveAttachments)
        if (!a.isImage) a,
    ];
    return [
      if (images.isNotEmpty) ...[
        const SizedBox(height: 8),
        ChatImageAttachments(
          session: widget.session,
          attachments: images,
          message: message,
          room: _room,
        ),
      ],
      if (files.isNotEmpty) ...[
        const SizedBox(height: 8),
        ChatFileAttachments(
          session: widget.session,
          attachments: files,
          message: message,
        ),
      ],
    ];
  }

  int get _commentCount =>
      widget.message.comments.where((c) => !c.deleted).length;

  Widget _buildHeader(BuildContext context, Poll poll, bool closed) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return Row(
      children: [
        Icon(Icons.poll_outlined, size: 14, color: hint),
        const SizedBox(width: 4),
        Text('투표', style: theme.textTheme.labelSmall?.copyWith(color: hint)),
        if (poll.favorite) ...[
          const SizedBox(width: 6),
          const Icon(
            Icons.star,
            key: ValueKey('poll-favorite-star'),
            size: 14,
            color: Color(0xFFF5A623),
          ),
        ],
        const Spacer(),
        _buildMenu(context, poll, closed),
      ],
    );
  }

  Widget _buildMenu(BuildContext context, Poll poll, bool closed) {
    final canClose = !closed && _canManage && !widget.message.deleted;
    final canDelete =
        _canManage &&
        !widget.message.deleted &&
        isEditDeleteAllowed(widget.session);
    final items = <PopupMenuEntry<String>>[
      if (widget.onOpenThread != null)
        const PopupMenuItem(
          value: 'comment',
          child: _MenuRow(Icons.mode_comment_outlined, '댓글'),
        ),
      PopupMenuItem(
        value: 'favorite',
        child: _MenuRow(
          poll.favorite ? Icons.star : Icons.star_border,
          poll.favorite ? '즐겨찾기 해제' : '즐겨찾기',
        ),
      ),
      if (canClose)
        const PopupMenuItem(
          value: 'close',
          child: _MenuRow(Icons.lock_clock_outlined, '투표 마감'),
        ),
      if (canDelete) ...[
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'delete',
          child: _MenuRow(Icons.delete_outline, '삭제', color: Colors.redAccent),
        ),
      ],
    ];
    return SizedBox(
      height: 28,
      child: PopupMenuButton<String>(
        key: const ValueKey('poll-more'),
        tooltip: '더보기',
        padding: EdgeInsets.zero,
        iconSize: 20,
        icon: const Icon(Icons.more_horiz),
        onSelected: (value) {
          switch (value) {
            case 'comment':
              widget.onOpenThread?.call(widget.message);
            case 'favorite':
              _toggleFavorite(poll);
            case 'close':
              _close(poll);
            case 'delete':
              _delete(poll);
          }
        },
        itemBuilder: (_) => items,
      ),
    );
  }

  Widget _buildActions(
    BuildContext context,
    Poll poll,
    bool interactive,
    bool canSubmit,
    Set<String> selection,
  ) {
    if (!interactive) {
      // 이미 투표했다 — 결과를 보여 주고 "다시 투표하기"로 고를 수 있게 한다.
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          key: const ValueKey('poll-revote-button'),
          onPressed: _busy
              ? null
              : () => setState(() {
                  _revoting = true;
                  _picked = null;
                }),
          child: const Text('다시 투표하기'),
        ),
      );
    }
    final cancelling = selection.isEmpty && poll.hasVoted;
    return Row(
      children: [
        if (_revoting) ...[
          TextButton(
            key: const ValueKey('poll-revote-cancel'),
            onPressed: _busy
                ? null
                : () => setState(() {
                    _revoting = false;
                    _picked = null;
                    _error = null;
                  }),
            child: const Text('취소'),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: FilledButton(
            key: const ValueKey('poll-vote-button'),
            onPressed: canSubmit ? () => _vote(poll) : null,
            child: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(cancelling ? '투표 취소' : '투표하기'),
          ),
        ),
      ],
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  const _MenuRow(this.icon, this.label, {this.color});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: 10),
      Text(label, style: TextStyle(color: color)),
    ],
  );
}

/// 제목 아래의 작은 배지("익명 투표", "복수 선택", "마감됨").
class _Badge extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color? color;
  const _Badge({required this.label, required this.icon, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: c),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: c,
            ),
          ),
        ],
      ),
    );
  }
}

/// 보기 한 줄 — 왼쪽 라디오/체크박스(고를 수 있을 때) 또는 내가 고른 표시, 가운데 보기 글, 오른쪽
/// 득표 수·비율. 뒤에 깔린 막대가 비율만큼 채워진다. 기명 투표는 득표 수를 눌러 투표자를 본다.
class _OptionRow extends StatelessWidget {
  final PollOption option;
  final double ratio;
  final bool multiple;
  final bool interactive;
  final bool selected;
  final bool mine;
  final bool anonymous;
  final VoidCallback onTap;
  final VoidCallback onShowVoters;

  const _OptionRow({
    required this.option,
    required this.ratio,
    required this.multiple,
    required this.interactive,
    required this.selected,
    required this.mine,
    required this.anonymous,
    required this.onTap,
    required this.onShowVoters,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final highlight = interactive ? selected : mine;
    final barColor = scheme.primary.withValues(alpha: highlight ? 0.28 : 0.13);
    final percent = (ratio * 100).round();
    final canSeeVoters = !anonymous && option.voteCount > 0;

    final Widget leading;
    if (interactive) {
      leading = Icon(
        multiple
            ? (selected ? Icons.check_box : Icons.check_box_outline_blank)
            : (selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked),
        size: 20,
        color: selected ? scheme.primary : theme.hintColor,
      );
    } else if (mine) {
      leading = Icon(Icons.check_circle, size: 20, color: scheme.primary);
    } else {
      leading = const SizedBox(width: 20);
    }

    final count = Text(
      '${option.voteCount}표 · $percent%',
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: canSeeVoters ? scheme.primary : theme.hintColor,
        decoration: canSeeVoters ? TextDecoration.underline : null,
      ),
    );

    return Material(
      key: ValueKey('poll-option-${option.id}'),
      color: scheme.surface,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: interactive ? onTap : null,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: highlight ? scheme.primary : theme.dividerColor,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: ratio,
                    heightFactor: 1,
                    child: ColoredBox(
                      key: ValueKey('poll-bar-${option.id}'),
                      color: barColor,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    leading,
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        option.text,
                        style: const TextStyle(fontSize: 14, height: 1.3),
                      ),
                    ),
                    const SizedBox(width: 8),
                    canSeeVoters
                        ? InkWell(
                            key: ValueKey('poll-count-${option.id}'),
                            onTap: onShowVoters,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: count,
                            ),
                          )
                        : count,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
