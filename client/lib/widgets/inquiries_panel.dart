import 'dart:async';

import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/inquiry.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import 'app_toast.dart';
import 'attachment_widgets.dart';
import 'home_shell_scope.dart' show HomeShellScope, openRoomFromPanel;
import 'side_panels.dart' show openSidePanel;
import 'inquiry_compose.dart';
import 'search_result_parts.dart' show PanelTab;
import 'todos_panel.dart'
    show
        todoCardColor,
        todoCardHoverBorder,
        todoCardPressColor,
        todoListBackgroundColor;

/// 문의함의 두 목록.
enum InquiryBox { received, sent }

/// [openInquiriesPanel]이 새로 열 문의함 패널에 넘기는 "처음 보일 목록" — side_panels.dart의 builder가 한 번 가져간다.
InquiryBox? _pendingBox;

/// 문의함 패널을 [box] 목록으로 연다(문의 메시지의 "문의함 열기") — PC는 오른쪽 패널(이미 열려 있으면 그대로 두고 그 목록으로),
/// 모바일은 전체 화면.
void openInquiriesPanel(
  BuildContext context,
  Session session, {
  InquiryBox box = InquiryBox.received,
}) {
  final shell = HomeShellScope.maybeOf(context);
  if (shell != null && shell.openPanelKey == 'inquiries') {
    for (final panel in _InquiriesPanelState._mounted) {
      if (panel.mounted) panel._selectBox(box);
    }
    return;
  }
  _pendingBox = box;
  openSidePanel(context, session, 'inquiries');
}

/// 패널 builder가 처음 보일 목록을 가져간다(없으면 받은 문의).
InquiryBox takeInitialInquiryBox() {
  final box = _pendingBox ?? InquiryBox.received;
  _pendingBox = null;
  return box;
}

/// 문의함 패널(side_panels.dart의 'inquiries' — 메뉴 "툴"의 문의함, 문의 메시지의 "문의함 열기") — 할 일 패널과 같은 모양이다.
/// 위에서부터 머리(`문의함`, 오른쪽 끝 ✕), 가로 전체 `+ 팀장에게 문의하기`(지금 팀에 나 말고 직책이 "팀장"인 사람이 있을 때만 —
/// 팀장이 여럿이면 누구에게 보낼지 고른다. 그 사람과의 1:1 대화방에 문의를 만들고 메시지로도 보낸다), 탭 `받은 문의 N`
/// (내가 팀장으로 받은 것 — N은 아직 대기 중인 수) · `보낸 문의`, 처리 상태 칩(전체 · 대기 · 처리중 · 완료 — 개수와 함께), 그 아래
/// 옅은 회색 바탕에 `N개의 문의`와 카드 목록(최근 순)이다. 카드를 누르면 상세(받은 문의는 처리 상태를 바꾼다 — 보낸 사람에게도
/// 바로 보인다, `대화로 이동`으로 그 1:1 대화방을 연다). 새 문의·상태 변경은 소켓으로 바로 반영한다.
class InquiriesPanel extends StatefulWidget {
  final Session session;
  final VoidCallback? onClose;

  /// 처음 보일 목록 — 문의 메시지에서 열면 받은 사람은 받은 문의, 보낸 사람은 보낸 문의.
  final InquiryBox initialBox;

  const InquiriesPanel({
    super.key,
    required this.session,
    this.onClose,
    this.initialBox = InquiryBox.received,
  });

  @override
  State<InquiriesPanel> createState() => _InquiriesPanelState();
}

class _InquiriesPanelState extends State<InquiriesPanel> {
  /// 지금 떠 있는 문의함 패널 — 열려 있을 때 "문의함 열기"를 누르면 그 목록으로만 바꾼다([openInquiriesPanel]).
  static final _mounted = <_InquiriesPanelState>{};

  late InquiryBox _box = widget.initialBox;
  InquiryStatus? _filter;
  final _lists = <InquiryBox, List<Inquiry>?>{
    InquiryBox.received: null,
    InquiryBox.sent: null,
  };
  final _errors = <InquiryBox, String?>{};

  /// 지금 팀에서 문의를 보낼 수 있는 사람(직책이 "팀장"인 나 아닌 멤버) — 받기 전에는 null.
  List<AppUser>? _leaders;
  StreamSubscription<Inquiry>? _newSub;
  StreamSubscription<Inquiry>? _statusSub;

  @override
  void initState() {
    super.initState();
    _mounted.add(this);
    _load(InquiryBox.received);
    _load(InquiryBox.sent);
    _loadLeaders();
    final socket = widget.session.chatSocket;
    _newSub = socket.inquiryNew.listen((inquiry) {
      if (!mounted) return;
      final items = _lists[InquiryBox.received];
      if (items == null || items.any((e) => e.id == inquiry.id)) return;
      setState(() => _lists[InquiryBox.received] = [inquiry, ...items]);
    });
    _statusSub = socket.inquiryStatusChanged.listen((inquiry) {
      if (!mounted) return;
      setState(() {
        for (final items in _lists.values) {
          for (final e in items ?? const <Inquiry>[]) {
            if (e.id == inquiry.id) {
              e.status = inquiry.status;
              e.statusUpdatedAt = inquiry.statusUpdatedAt;
            }
          }
        }
      });
    });
  }

  @override
  void dispose() {
    _mounted.remove(this);
    _newSub?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }

  Future<void> _load(InquiryBox box) async {
    try {
      final api = widget.session.api!;
      final items = box == InquiryBox.received
          ? await api.fetchReceivedInquiries()
          : await api.fetchSentInquiries();
      if (!mounted) return;
      setState(() {
        _lists[box] = items;
        _errors[box] = null;
      });
    } catch (e) {
      if (mounted) setState(() => _errors[box] = '문의를 불러오지 못했습니다: $e');
    }
  }

  Future<void> _loadLeaders() async {
    if (widget.session.currentTeam == null) {
      setState(() => _leaders = const []);
      return;
    }
    try {
      final members = await widget.session.fetchTeamMembers();
      if (!mounted) return;
      setState(
        () => _leaders = [
          for (final m in members)
            if (m.id != widget.session.userId && m.position == '팀장') m,
        ],
      );
    } catch (_) {
      // 문의하기 단추만 안 보일 뿐 — 목록은 그대로 쓴다.
      if (mounted) setState(() => _leaders = const []);
    }
  }

  /// `+ 팀장에게 문의하기` — 팀장이 여럿이면 누구에게 보낼지 고르고, 그 사람과의 1:1 대화방(없으면 만든다)에 문의를 보낸다.
  /// 보냈으면 보낸 문의 목록 맨 위에 넣고 그 목록을 보인다.
  Future<void> _create() async {
    final leaders = _leaders ?? const <AppUser>[];
    if (leaders.isEmpty) return;
    final leader = leaders.length == 1
        ? leaders.single
        : await showDialog<AppUser>(
            context: context,
            builder: (dialogContext) => SimpleDialog(
              title: const Text('누구에게 문의할까요?'),
              children: [
                for (final l in leaders)
                  SimpleDialogOption(
                    key: ValueKey('inquiry-leader-${l.id}'),
                    onPressed: () => Navigator.of(dialogContext).pop(l),
                    child: Text('${l.name} · 팀장'),
                  ),
              ],
            ),
          );
    if (leader == null || !mounted) return;
    try {
      final room = await widget.session.startDm(leader.id);
      if (!mounted) return;
      final inquiry = await sendInquiryTo(context, widget.session, room);
      if (inquiry == null || !mounted) return;
      setState(() {
        final sent = _lists[InquiryBox.sent];
        if (sent != null && !sent.any((e) => e.id == inquiry.id)) {
          _lists[InquiryBox.sent] = [inquiry, ...sent];
        }
        _box = InquiryBox.sent;
        _filter = null;
      });
    } catch (e) {
      if (mounted) showAppToast(context, '대화방을 열지 못했습니다: $e');
    }
  }

  void _selectBox(InquiryBox box) {
    if (_box == box) return;
    setState(() {
      _box = box;
      _filter = null;
    });
  }

  Future<void> _changeStatus(Inquiry inquiry, InquiryStatus status) async {
    try {
      final updated = await widget.session.api!.updateInquiryStatus(
        inquiry.id,
        status,
      );
      if (!mounted) return;
      setState(() {
        inquiry.status = updated.status;
        inquiry.statusUpdatedAt = updated.statusUpdatedAt;
      });
    } catch (e) {
      if (mounted) showAppToast(context, '상태를 바꾸지 못했습니다: $e');
      rethrow;
    }
  }

  /// 그 문의가 오간 1:1 대화방을 연다(PC는 가운데 채팅, 모바일은 채팅 화면). 그 방에 더 이상 없으면 알린다.
  void _openRoom(Inquiry inquiry) {
    final room = widget.session.roomById(inquiry.roomId);
    if (room == null) {
      showAppToast(context, '이 대화방에 더 이상 참여하고 있지 않습니다.');
      return;
    }
    openRoomFromPanel(context, widget.session, room);
  }

  Future<void> _openDetail(Inquiry inquiry) async {
    final received = _box == InquiryBox.received;
    final openRoom = await showDialog<bool>(
      context: context,
      builder: (_) => InquiryDetailDialog(
        session: widget.session,
        inquiry: inquiry,
        counterpartLabel: received
            ? '보낸 사람: ${inquiry.senderName}'
            : '받는 사람: ${inquiry.recipientName}',
        onChangeStatus: received
            ? (status) => _changeStatus(inquiry, status)
            : null,
      ),
    );
    if (!mounted) return;
    setState(() {}); // 상세에서 바꾼 상태를 카드에도.
    if (openRoom == true) _openRoom(inquiry);
  }

  @override
  Widget build(BuildContext context) {
    final items = _lists[_box];
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context),
          const Divider(height: 1),
          if (_leaders?.isNotEmpty ?? false) _createButton(context),
          _boxTabs(context),
          if (items != null && items.isNotEmpty) _statusChips(items),
          const SizedBox(height: 8),
          Expanded(
            child: ColoredBox(
              color: todoListBackgroundColor(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _countLine(context),
                  Expanded(child: _content(context)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Text('문의함', style: Theme.of(context).textTheme.titleLarge),
          ),
          IconButton(
            key: const ValueKey('inquiry-panel-close'),
            icon: const Icon(Icons.close),
            tooltip: '닫기',
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  /// 가로 전체 `+ 팀장에게 문의하기` — 할 일 패널의 `+ 할 일 생성`과 같은 옅은 회색 둥근 단추.
  Widget _createButton(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: FilledButton.icon(
        key: const ValueKey('inquiry-create'),
        onPressed: _create,
        style: FilledButton.styleFrom(
          backgroundColor: scheme.surfaceContainerHighest,
          foregroundColor: scheme.onSurface,
          minimumSize: const Size.fromHeight(44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: theme.textTheme.labelLarge?.copyWith(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        icon: const Icon(Icons.add, size: 20),
        label: const Text(
          '팀장에게 문의하기',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// `받은 문의 N`(N은 아직 대기 중인 수 — 없으면 숫자 없이) · `보낸 문의` 탭.
  Widget _boxTabs(BuildContext context) {
    final waiting = (_lists[InquiryBox.received] ?? const <Inquiry>[])
        .where((e) => e.status == InquiryStatus.open)
        .length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          PanelTab(
            key: const ValueKey('inquiry-box-received'),
            label: waiting > 0 ? '받은 문의 $waiting' : '받은 문의',
            selected: _box == InquiryBox.received,
            onTap: () => _selectBox(InquiryBox.received),
          ),
          PanelTab(
            key: const ValueKey('inquiry-box-sent'),
            label: '보낸 문의',
            selected: _box == InquiryBox.sent,
            onTap: () => _selectBox(InquiryBox.sent),
          ),
        ],
      ),
    );
  }

  /// 처리 상태 칩 — 전체 · 대기 · 처리중 · 완료(각 개수).
  Widget _statusChips(List<Inquiry> items) {
    int countOf(InquiryStatus s) => items.where((e) => e.status == s).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          ChoiceChip(
            key: const ValueKey('inquiry-filter-all'),
            visualDensity: VisualDensity.compact,
            label: Text('전체 ${items.length}'),
            selected: _filter == null,
            onSelected: (_) => setState(() => _filter = null),
          ),
          for (final s in InquiryStatus.values)
            ChoiceChip(
              key: ValueKey('inquiry-filter-${inquiryStatusToWire(s)}'),
              visualDensity: VisualDensity.compact,
              label: Text('${inquiryStatusLabel(s)} ${countOf(s)}'),
              selected: _filter == s,
              onSelected: (_) => setState(() => _filter = s),
            ),
        ],
      ),
    );
  }

  List<Inquiry>? get _shown {
    final items = _lists[_box];
    final filter = _filter;
    if (items == null || filter == null) return items;
    return items.where((e) => e.status == filter).toList();
  }

  Widget _countLine(BuildContext context) {
    final theme = Theme.of(context);
    const bold = TextStyle(fontWeight: FontWeight.w700);
    final shown = _shown;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Text.rich(
        key: ValueKey(
          shown == null ? 'inquiry-count-pending' : 'inquiry-count',
        ),
        TextSpan(
          children: shown == null
              ? const [TextSpan(text: ' ', style: bold)]
              : [
                  TextSpan(text: '${shown.length}', style: bold),
                  const TextSpan(text: '개의 문의'),
                ],
        ),
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurface,
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final shown = _shown;
    if (shown == null) {
      final error = _errors[_box];
      if (error != null) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(error, textAlign: TextAlign.center),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => _load(_box),
                child: const Text('다시 시도'),
              ),
            ],
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    if (shown.isEmpty) return _empty(context);
    final received = _box == InquiryBox.received;
    return ListView.separated(
      key: const ValueKey('inquiry-list'),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      itemCount: shown.length,
      separatorBuilder: (context, i) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final inquiry = shown[i];
        return _InquiryCard(
          key: ValueKey('inquiry-${inquiry.id}'),
          session: widget.session,
          inquiry: inquiry,
          counterpart: received
              ? '보낸 사람 ${inquiry.senderName}'
              : '받는 사람 ${inquiry.recipientName}',
          onTap: () => _openDetail(inquiry),
        );
      },
    );
  }

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    final received = _box == InquiryBox.received;
    final filtered = _filter != null;
    final text = filtered
        ? '${inquiryStatusLabel(_filter!)} 상태인 문의가 없어요.'
        : received
        ? '받은 문의가 없어요.'
        : '보낸 문의가 없어요.';
    final hint = received
        ? '직책이 팀장이면 팀원이 보낸 문의가 여기에 모여요.'
        : (_leaders?.isNotEmpty ?? false)
        ? '"팀장에게 문의하기"로 업무·근태 등을 문의해 보세요.'
        : '팀장과의 1:1 대화방에서 문의할 수 있어요.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.contact_support_outlined,
              size: 40,
              color: theme.hintColor,
            ),
            const SizedBox(height: 12),
            Text(
              text,
              key: const ValueKey('inquiry-empty'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            if (!filtered) ...[
              const SizedBox(height: 4),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 처리 상태 색 — 대기(주황) · 처리중(주 색) · 완료(초록).
Color inquiryStatusColor(BuildContext context, InquiryStatus status) {
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    InquiryStatus.open => Colors.orange,
    InquiryStatus.inProgress => scheme.primary,
    InquiryStatus.resolved => Colors.green,
  };
}

/// 처리 상태 알약(대기/처리중/완료 — 상태 색).
class InquiryStatusPill extends StatelessWidget {
  final InquiryStatus status;
  const InquiryStatusPill(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final color = inquiryStatusColor(context, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        inquiryStatusLabel(status),
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 분류 칩(업무 · 근태/휴가 …) — 옅은 회색.
class _CategoryChip extends StatelessWidget {
  final String category;
  const _CategoryChip(this.category);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(category, style: const TextStyle(fontSize: 11)),
    );
  }
}

/// 문의 카드(할 일 카드와 같은 틀 — 흰 둥근 카드, 마우스를 올리면 테두리가 주 색) — 첫 줄 분류 칩 · 처리 상태 알약 · 오른쪽
/// 끝 보낸 때, 굵은 제목(두 줄까지), 내용 앞부분(두 줄까지), 작은 글씨로 상대(보낸/받는 사람) · 📎(첨부가 있으면).
class _InquiryCard extends StatefulWidget {
  final Session session;
  final Inquiry inquiry;
  final String counterpart;
  final VoidCallback onTap;
  const _InquiryCard({
    super.key,
    required this.session,
    required this.inquiry,
    required this.counterpart,
    required this.onTap,
  });

  @override
  State<_InquiryCard> createState() => _InquiryCardState();
}

class _InquiryCardState extends State<_InquiryCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hint = theme.hintColor;
    final inquiry = widget.inquiry;
    final small = TextStyle(fontSize: 12, color: hint);
    final session = widget.session;
    // 다른 팀의 문의면 어느 팀 것인지 적는다(문의함은 모든 팀의 것을 모아 보인다).
    final teamName =
        session.teams.length > 1 && inquiry.teamId != session.currentTeam?.id
        ? session.teams.where((t) => t.id == inquiry.teamId).firstOrNull?.name
        : null;
    return Material(
      color: todoCardColor(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: _hovered ? todoCardHoverBorder(context) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
        onHover: (v) {
          if (v != _hovered) setState(() => _hovered = v);
        },
        hoverColor: Colors.transparent,
        highlightColor: todoCardPressColor(context),
        splashColor: todoCardPressColor(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _CategoryChip(inquiry.category),
                  const SizedBox(width: 6),
                  InquiryStatusPill(
                    inquiry.status,
                    key: ValueKey('inquiry-status-${inquiry.id}'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      formatRelativeTime(inquiry.createdAt),
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: small,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                inquiry.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              if (inquiry.content.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  inquiry.content.trim(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.person_outline, size: 14, color: hint),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      widget.counterpart,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: small,
                    ),
                  ),
                  if (teamName != null) Text(' · $teamName', style: small),
                  if (inquiry.hasAttachment) ...[
                    Text(' · ', style: small),
                    Icon(Icons.attach_file, size: 13, color: hint),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 문의 상세 — 전체 내용과 첨부, 처리 상태([onChangeStatus]가 있으면 — 받은 문의 — 칩으로 바꾼다), 그리고 `대화로 이동`
/// (그 1:1 대화방을 연다 — 창을 닫으며 true를 돌려준다).
class InquiryDetailDialog extends StatefulWidget {
  final Session session;
  final Inquiry inquiry;
  final String counterpartLabel;
  final Future<void> Function(InquiryStatus status)? onChangeStatus;
  const InquiryDetailDialog({
    super.key,
    required this.session,
    required this.inquiry,
    required this.counterpartLabel,
    required this.onChangeStatus,
  });

  @override
  State<InquiryDetailDialog> createState() => _InquiryDetailDialogState();
}

class _InquiryDetailDialogState extends State<InquiryDetailDialog> {
  bool _updating = false;

  Future<void> _setStatus(InquiryStatus status) async {
    final change = widget.onChangeStatus;
    if (change == null || _updating) return;
    setState(() => _updating = true);
    try {
      await change(status);
    } catch (_) {
      // 실패는 패널이 알린다.
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inquiry = widget.inquiry;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Row(
        children: [
          _CategoryChip(inquiry.category),
          const SizedBox(width: 8),
          Expanded(child: Text(inquiry.title, overflow: TextOverflow.ellipsis)),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.counterpartLabel} · ${formatDateTime(inquiry.createdAt)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
              const SizedBox(height: 12),
              SelectableText(inquiry.content),
              if (inquiry.hasAttachment) ...[
                const SizedBox(height: 12),
                if (inquiry.attachmentIsImage)
                  DownloadableImage(
                    session: widget.session,
                    url: inquiry.fileUrl!,
                    fileName: inquiry.fileName ?? '첨부 이미지',
                    thumbnailUrl: inquiry.thumbnailUrl,
                  )
                else
                  DownloadableFile(
                    session: widget.session,
                    url: inquiry.fileUrl!,
                    fileName: inquiry.fileName ?? '첨부 파일',
                    // 다운로드 단추는 카드와 겹치지 않게 카드 바깥 오른쪽에(할 일 상세와 같다).
                    actionsBeside: true,
                  ),
              ],
              const SizedBox(height: 20),
              Text('처리 상태', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              if (widget.onChangeStatus != null)
                Wrap(
                  spacing: 8,
                  children: [
                    for (final status in InquiryStatus.values)
                      ChoiceChip(
                        key: ValueKey(
                          'inquiry-detail-status-${inquiryStatusToWire(status)}',
                        ),
                        label: Text(inquiryStatusLabel(status)),
                        selected: inquiry.status == status,
                        onSelected: _updating
                            ? null
                            : (_) => _setStatus(status),
                      ),
                  ],
                )
              else
                InquiryStatusPill(inquiry.status),
            ],
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          key: const ValueKey('inquiry-open-room'),
          onPressed: () => Navigator.of(context).pop(true),
          icon: const Icon(Icons.chat_bubble_outline, size: 18),
          label: const Text('대화로 이동'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}
