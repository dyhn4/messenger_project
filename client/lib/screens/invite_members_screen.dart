import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../services/api_client.dart' show ApiException, PositionOption;
import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/invite_result_dialog.dart';
import '../widgets/room_options_menu.dart' show CloseWhenRoomRemoved;
import '../widgets/user_avatar.dart';
import 'home_screen.dart' show wideBreakpoint;
import '../l10n/tr.dart';

/// "멤버 초대하기"를 연다 — 넓은 화면(PC)은 떠 있는 창, 좁은 화면(모바일)은 전체 화면. 채팅 헤더의
/// 초대 버튼, 참여 멤버 창, 새 토픽을 만든 직후가 같이 쓴다.
Future<void> showInviteMembers(
  BuildContext context,
  Session session,
  Room room,
) async {
  if (MediaQuery.sizeOf(context).width >= wideBreakpoint) {
    await showDialog<void>(
      context: context,
      builder: (_) =>
          InviteMembersScreen(session: session, room: room, asDialog: true),
    );
  } else {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => InviteMembersScreen(session: session, room: room),
      ),
    );
  }
}

/// "멤버 선택"을 연다 — 새 그룹채팅 만들기처럼 멤버만 골라 받을 때(초대 요청은 하지 않는다). 멤버
/// 초대하기와 같은 모양으로, 넓은 화면(PC)은 떠 있는 창, 좁은 화면(모바일)은 전체 화면이다.
/// [initialSelected]를 미리 고른 채로 열고, "확인"이면 고른 멤버를 고른 순서대로, 취소하면 null을
/// 돌려준다. 나는 목록에 없다. [confirmLabel]·[requireSelection]은 "여러 토픽/그룹채팅에 초대"의 첫 단계처럼
/// 확인 단추를 "다음"으로 바꾸고 한 명 이상 골라야 누를 수 있게 할 때 쓴다.
Future<List<AppUser>?> showPickMembers(
  BuildContext context,
  Session session, {
  String title = '멤버 선택',
  List<String> initialSelected = const [],
  String confirmLabel = '확인',
  bool requireSelection = false,
}) {
  PickMembersScreen screen({required bool asDialog}) => PickMembersScreen(
    session: session,
    title: title,
    initialSelected: initialSelected,
    confirmLabel: confirmLabel,
    requireSelection: requireSelection,
    asDialog: asDialog,
  );
  if (MediaQuery.sizeOf(context).width >= wideBreakpoint) {
    return showDialog<List<AppUser>>(
      context: context,
      builder: (_) => screen(asDialog: true),
    );
  }
  return Navigator.of(context).push<List<AppUser>>(
    MaterialPageRoute(builder: (_) => screen(asDialog: false)),
  );
}

/// 토픽·그룹 "멤버 초대하기" — 잔디처럼 위에 검색 조건(멤버 검색·직책), 왼쪽에 팀 멤버, 오른쪽에
/// 선택된 멤버([MemberPicker]). 이미 방에 있는 사람은 목록에서 뺀다.
class InviteMembersScreen extends StatefulWidget {
  final Session session;
  final Room room;
  final bool asDialog;
  const InviteMembersScreen({
    super.key,
    required this.session,
    required this.room,
    this.asDialog = false,
  });

  @override
  State<InviteMembersScreen> createState() => _InviteMembersScreenState();
}

class _InviteMembersScreenState extends State<InviteMembersScreen>
    with CloseWhenRoomRemoved {
  // 초대하는 동안 토픽이 삭제되거나 내보내지면 이 창도 닫는다.
  @override
  Session get roomSession => widget.session;
  @override
  String get watchedRoomId => widget.room.id;

  /// 창을 연 순간의 방 멤버 — 목록에서 뺄 사람.
  late final _memberIds = {for (final m in widget.room.members) m.id};
  bool _submitting = false;

  Future<void> _submit(List<AppUser> selected) async {
    if (selected.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    try {
      await widget.session.inviteMembers(widget.room.id, [
        for (final u in selected) u.id,
      ]);
      if (!mounted) return;
      // 초대 완료 창이 떠 있는 동안 아래 창의 진행 표시는 멈춰 둔다.
      setState(() => _submitting = false);
      // 호출 전에 이미 방에 있던 사람은 목록에서 빠져 있으므로 고른 사람이 곧 새로 초대된 사람이다.
      await showInviteResultDialog(
        context,
        session: widget.session,
        results: [
          RoomInviteResult(
            roomId: widget.room.id,
            roomName: widget.room.displayName(widget.session.userId ?? ''),
            roomType: widget.room.type,
            invited: [
              for (final u in selected)
                InvitePerson(userId: u.id, name: u.name),
            ],
          ),
        ],
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showAppToast(context, tr('초대하지 못했습니다: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MemberPickerFrame(
      title: tr('멤버 초대하기'),
      asDialog: widget.asDialog,
      child: MemberPicker(
        session: widget.session,
        excludeIds: _memberIds,
        emptySelectedText: tr('초대할 멤버를 선택하세요.'),
        noMembersText: tr('초대할 수 있는 멤버가 없습니다.'),
        actionsBuilder: (context, selected, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: _submitting ? null : () => Navigator.of(context).pop(),
              child: Text(tr('닫기')),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: selected.isEmpty || _submitting
                  ? null
                  : () => _submit(selected),
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      selected.isEmpty
                          ? tr('초대하기')
                          : tr('초대하기 ({selected.length})', {
                              'selected.length': selected.length,
                            }),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "멤버 선택"([showPickMembers]) — 멤버 초대하기와 같은 모양으로 멤버만 골라 돌려준다. 고른 멤버를
/// 모두 빼고 "확인"해도 된다(빈 목록을 돌려준다 — 필요한지는 부른 창이 따진다).
class PickMembersScreen extends StatelessWidget {
  final Session session;
  final String title;
  final List<String> initialSelected;

  /// 확인 단추 문구(기본 "확인") — 여러 대화방에 초대하는 첫 단계는 "다음".
  final String confirmLabel;

  /// true면 한 명 이상 골라야 확인 단추가 켜진다.
  final bool requireSelection;
  final bool asDialog;
  const PickMembersScreen({
    super.key,
    required this.session,
    this.title = '멤버 선택',
    this.initialSelected = const [],
    this.confirmLabel = '확인',
    this.requireSelection = false,
    this.asDialog = false,
  });

  @override
  Widget build(BuildContext context) {
    return MemberPickerFrame(
      title: title,
      asDialog: asDialog,
      child: MemberPicker(
        session: session,
        excludeIds: {?session.userId},
        initialSelected: initialSelected,
        emptySelectedText: tr('함께할 멤버를 선택하세요.'),
        noMembersText: tr('선택할 수 있는 멤버가 없습니다.'),
        actionsBuilder: (context, selected, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(tr('취소')),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('pick-members-confirm'),
              onPressed: requireSelection && selected.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(selected),
              child: Text(
                selected.isEmpty
                    ? tr(confirmLabel)
                    : '${tr(confirmLabel)} (${selected.length})',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 멤버 고르기 창의 틀 — 넓은 화면은 떠 있는 창(멤버 초대하기 크기), 좁은 화면은 전체 화면.
/// 멤버 초대하기·멤버 선택·채팅 시작하기가 같이 쓴다.
class MemberPickerFrame extends StatelessWidget {
  final String title;
  final bool asDialog;
  final Widget child;
  const MemberPickerFrame({
    super.key,
    required this.title,
    required this.asDialog,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (asDialog) {
      return FloatingDialog(
        title: title,
        maxWidth: 940,
        maxHeight: 780,
        child: child,
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr(title))),
      body: SafeArea(
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    );
  }
}

/// 직책 드롭다운의 "전체"와 "직책 없음" — 실제 직책 이름과 겹치지 않는 값.
const _allPositions = '\u0000all';
const _noPosition = '\u0000none';

/// 두 칸 배치로 바꾸는 너비.
const _twoPaneMinWidth = 640.0;

/// 두 칸 배치에 필요한 높이 — 넓어도 이보다 낮으면(가로로 눕힌 휴대폰, 작은 PC 창) 목록 칸이 눌려
/// 넘치지 않게 스크롤되는 한 칸 배치로 그린다.
const _twoPaneMinHeight = 440.0;

/// 팀 멤버 고르기 몸통 — 위에 검색 조건(멤버 검색·직책)과 검색 조건 초기화, 왼쪽에 팀 멤버(체크박스),
/// 오른쪽에 선택된 멤버(✕로 빼기), 아래에 [footer]와 버튼 줄. 부서·직급은 이 앱에 없어서 뺐다. 넓은
/// 화면(PC)은 두 칸, 좁은 화면(모바일)은 한 칸 목록 + 아래 선택 칩으로 쌓는다. 멤버 초대하기·멤버
/// 선택·채팅 시작하기가 같이 쓰고, 고른 멤버로 무엇을 할지는 [actionsBuilder]의 버튼이 정한다.
class MemberPicker extends StatefulWidget {
  final Session session;

  /// 목록에서 뺄 사람(이미 방에 있는 멤버, 나 등).
  final Set<String> excludeIds;

  /// 미리 골라 둘 멤버(이 순서대로 "선택된 멤버"에 보인다) — 목록에 없는 사람은 빠진다.
  final List<String> initialSelected;

  /// 팀 멤버 목록 맨 위의 "모든 멤버 선택하기" 줄.
  final bool showSelectAll;

  /// 팀 멤버 목록 맨 위에 늘 고정해 둘 줄(채팅 시작하기의 "나와의 대화") — 검색 조건과 상관없이 보인다.
  final Widget? pinnedRow;

  /// false면 멤버를 고를 수 없다(준회원의 채팅 시작하기 — 목록은 보이지만 흐리게).
  final bool enabled;

  /// 오른쪽 "선택된 멤버"가 비었을 때의 안내.
  final String emptySelectedText;

  /// 고를 수 있는 팀 멤버가 한 명도 없을 때의 안내.
  final String noMembersText;

  /// 버튼 줄 옆(넓을 때) 또는 위(좁을 때)의 안내·오류 한 줄.
  final Widget? footer;

  /// 아래 버튼 줄 — 고른 멤버(고른 순서)와 폭이 넓은지를 받아 만든다. 넓을 때는 [footer] 옆에
  /// 놓이므로 Expanded 없이 제 크기만 차지해야 한다.
  final Widget Function(BuildContext context, List<AppUser> selected, bool wide)
  actionsBuilder;

  const MemberPicker({
    super.key,
    required this.session,
    this.excludeIds = const {},
    this.initialSelected = const [],
    this.showSelectAll = true,
    this.pinnedRow,
    this.enabled = true,
    required this.emptySelectedText,
    required this.noMembersText,
    this.footer,
    required this.actionsBuilder,
  });

  @override
  State<MemberPicker> createState() => _MemberPickerState();
}

class _MemberPickerState extends State<MemberPicker> {
  /// 고를 수 있는 팀 멤버(목록에서 뺄 사람 제외, 이름순).
  List<AppUser>? _users;
  List<PositionOption> _positionOptions = const [];
  String? _error;

  /// 고른 순서를 지켜서 오른쪽 "선택된 멤버"에 그 순서대로 보여준다.
  late final _selected = <String>{...widget.initialSelected};

  final _search = TextEditingController();
  String _position = _allPositions;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final users = await widget.session.fetchTeamMembers();
      users
        ..removeWhere((u) => widget.excludeIds.contains(u.id))
        ..sort((a, b) => a.name.compareTo(b.name));
      // 직책 목록은 드롭다운 순서를 맞추는 데만 쓴다 — 못 받아와도 멤버에게 붙은 직책으로 채운다.
      List<PositionOption> options = const [];
      try {
        options = await widget.session.fetchPublicPositionOptions();
      } catch (_) {}
      if (!mounted) return;
      final ids = {for (final u in users) u.id};
      setState(() {
        _users = users;
        _positionOptions = options;
        // 미리 고른 사람이 그사이 팀을 떠났으면 뺀다 — 버튼의 인원 수가 어긋나지 않게.
        _selected.removeWhere((id) => !ids.contains(id));
      });
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _error = e is ApiException
            ? e.message
            : tr('팀 멤버를 불러오지 못했습니다. 잠시 후 다시 시도하세요.'),
      );
    }
  }

  void _retry() {
    setState(() => _error = null);
    _load();
  }

  static String? _positionOf(AppUser u) {
    final p = u.position?.trim();
    return p == null || p.isEmpty ? null : p;
  }

  /// 드롭다운 항목 — 관리자가 정한 직책 순서, 그 목록에 없지만 멤버에게 붙어 있는 직책, 그리고
  /// 직책이 없는 멤버가 있으면 "직책 없음".
  List<(String, String)> get _positionItems {
    final users = _users ?? const <AppUser>[];
    final labels = <String>[
      for (final o in _positionOptions)
        if (o.label.trim().isNotEmpty) o.label.trim(),
    ];
    final extra =
        users
            .map(_positionOf)
            .whereType<String>()
            .toSet()
            .difference(labels.toSet())
            .toList()
          ..sort();
    return [
      (_allPositions, tr('전체')),
      for (final l in {...labels, ...extra}) (l, l),
      if (users.any((u) => _positionOf(u) == null)) (_noPosition, tr('직책 없음')),
    ];
  }

  bool get _hasConditions =>
      _search.text.trim().isNotEmpty || _position != _allPositions;

  List<AppUser> get _filtered {
    final q = _search.text.trim().toLowerCase();
    return [
      for (final u in _users ?? const <AppUser>[])
        if ((q.isEmpty ||
                u.name.toLowerCase().contains(q) ||
                u.username.toLowerCase().contains(q)) &&
            switch (_position) {
              _allPositions => true,
              _noPosition => _positionOf(u) == null,
              final p => _positionOf(u) == p,
            })
          u,
    ];
  }

  void _resetConditions() => setState(() {
    _search.clear();
    _position = _allPositions;
  });

  void _toggle(AppUser u) => setState(() {
    if (!_selected.remove(u.id)) _selected.add(u.id);
  });

  /// "모든 멤버 선택하기" — 지금 검색 조건에 걸린 멤버 전체를 고르거나(하나라도 빠졌으면) 뺀다.
  void _toggleAll(List<AppUser> visible) => setState(() {
    final ids = visible.map((u) => u.id);
    if (ids.every(_selected.contains)) {
      _selected.removeAll(ids);
    } else {
      _selected.addAll(ids);
    }
  });

  List<AppUser> get _selectedUsers {
    final byId = {for (final u in _users ?? const <AppUser>[]) u.id: u};
    return [
      for (final id in _selected)
        if (byId[id] != null) byId[id]!,
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (_users == null) return _buildPending(context);
    return LayoutBuilder(
      builder: (context, constraints) =>
          constraints.maxWidth >= _twoPaneMinWidth &&
              constraints.maxHeight >= _twoPaneMinHeight
          ? _buildWide(context)
          : _buildNarrow(context),
    );
  }

  /// 팀 멤버를 받는 중이거나 못 받았을 때. 맨 위 고정 줄(채팅 시작하기의 나와의 대화)은 멤버 목록과
  /// 상관없이 바로 열 수 있어야 해서 그대로 두고, 그 아래에 불러오는 중·실패 안내(다시 시도)를 둔다.
  Widget _buildPending(BuildContext context) {
    final error = _error;
    final status = error == null
        ? const Center(child: CircularProgressIndicator())
        : Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(error, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const ValueKey('member-picker-retry'),
                    onPressed: _retry,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(tr('다시 시도')),
                  ),
                ],
              ),
            ),
          );
    final pinned = widget.pinnedRow;
    if (pinned == null) return status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: pinned,
        ),
        Expanded(child: status),
      ],
    );
  }

  Widget _buildWide(BuildContext context) {
    final visible = _filtered;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildConditions(context, wide: true),
        const SizedBox(height: 12),
        Align(alignment: Alignment.centerRight, child: _resetButton()),
        const SizedBox(height: 12),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildMembersPane(context, visible)),
              const SizedBox(width: 16),
              Expanded(child: _buildSelectedPane(context)),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _buildBottom(context, wide: true),
      ],
    );
  }

  /// 한 칸 배치에서 목록이 한 줄이라도 보이려면 필요한 세로 자리 — 이보다 좁으면(휴대폰에서
  /// 검색하느라 키보드가 올라온 경우 등) 이 높이로 그리고 화면 전체를 스크롤한다. 예전엔 목록 칸이
  /// 0으로 눌려 사라지고 아래가 넘쳤다. 선택 칩·고정 줄·안내 줄이 보이면 그 몫이 더 든다. 터치
  /// 기기(48px 터치 영역)와 PC(촘촘한 밀도)는 줄 높이가 달라서 따로 둔다 — 작은 PC 창의
  /// 대화상자에서 괜히 스크롤이 생겨 버튼이 가려지지 않게.
  double _narrowMinHeight(BuildContext context, {required bool chips}) {
    final touch =
        Theme.of(context).materialTapTargetSize == MaterialTapTargetSize.padded;
    return (touch ? 330.0 : 290.0) +
        (chips ? (touch ? 140.0 : 120.0) : 0) +
        (widget.pinnedRow != null ? 56 : 0) +
        (widget.footer != null ? 44 : 0);
  }

  Widget _buildNarrow(BuildContext context) {
    final visible = _filtered;
    final selectedUsers = _selectedUsers;
    return LayoutBuilder(
      builder: (context, constraints) {
        final minHeight = _narrowMinHeight(
          context,
          chips: selectedUsers.isNotEmpty,
        );
        // 늘 같은 모양(스크롤 → 고정 높이 → 세로 줄)으로 그려서, 키보드가 오르내려도 검색 칸이
        // 새로 만들어지지 않는다(포커스가 풀리지 않게).
        return SingleChildScrollView(
          child: SizedBox(
            height: math.max(constraints.maxHeight, minHeight),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildConditions(context, wide: false),
                const SizedBox(height: 8),
                // 검색 조건 초기화는 "팀 멤버 N" 줄 오른쪽에 둬서 목록이 한 줄이라도 더 보이게 한다.
                Expanded(
                  child: _buildMembersPane(
                    context,
                    visible,
                    labelTrailing: _resetButton(),
                  ),
                ),
                if (selectedUsers.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _paneLabel(
                    context,
                    tr('선택된 멤버 {selectedUsers.length}', {
                      'selectedUsers.length': selectedUsers.length,
                    }),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 96),
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final u in selectedUsers)
                            InputChip(
                              avatar: UserAvatar(
                                user: u,
                                resolveUrl: widget.session.resolveUrl,
                                radius: 12,
                              ),
                              label: Text(u.name),
                              onDeleted: widget.enabled
                                  ? () => _toggle(u)
                                  : null,
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                // 넓은데 낮아서 한 칸으로 그릴 때(가로 휴대폰 등)는 버튼 줄은 넓은 모양 그대로 둔다.
                _buildBottom(
                  context,
                  wide: constraints.maxWidth >= _twoPaneMinWidth,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 아래 안내 줄과 버튼 줄 — 폭이 넓으면 안내를 버튼 왼쪽에, 좁으면 버튼 위에 둔다.
  Widget _buildBottom(BuildContext context, {required bool wide}) {
    final actions = widget.actionsBuilder(context, _selectedUsers, wide);
    final footer = widget.footer;
    if (footer == null) {
      return Align(alignment: AlignmentDirectional.centerEnd, child: actions);
    }
    if (wide) {
      return Row(
        children: [
          Expanded(child: footer),
          const SizedBox(width: 16),
          actions,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        footer,
        const SizedBox(height: 10),
        Align(alignment: AlignmentDirectional.centerEnd, child: actions),
      ],
    );
  }

  /// 상단 검색 조건 상자 — 멤버 검색 칸과 직책 드롭다운.
  Widget _buildConditions(BuildContext context, {required bool wide}) {
    // 검색 칸과 직책 드롭다운을 같은 회색 상자(_fieldBox)에 넣어 높이를 똑같이 맞춘다.
    final search = _labeled(
      context,
      tr('멤버 검색'),
      _fieldBox(
        context,
        TextField(
          key: const ValueKey('invite-search'),
          controller: _search,
          onChanged: (_) => setState(() {}),
          style: const TextStyle(fontSize: 14),
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            hintText: tr('검색어를 입력하세요.'),
            prefixIcon: Icon(Icons.search, size: 20),
            prefixIconConstraints: BoxConstraints(minWidth: 36),
            contentPadding: EdgeInsets.symmetric(vertical: 10),
          ),
        ),
        padding: const EdgeInsets.only(right: 12),
      ),
    );
    final items = _positionItems;
    // 목록을 다시 받아와서 고른 직책이 사라졌으면 "전체"로 보여준다.
    final value = items.any((e) => e.$1 == _position)
        ? _position
        : _allPositions;
    // 폼 필드가 아닌 DropdownButton을 쓴다 — "검색 조건 초기화"로 값을 바꾸면 바로 따라와야 해서.
    final position = _labeled(
      context,
      tr('직책'),
      _fieldBox(
        context,
        DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            key: const ValueKey('invite-position'),
            value: value,
            isExpanded: true,
            borderRadius: BorderRadius.circular(8),
            icon: const Icon(Icons.keyboard_arrow_down, size: 20),
            // 테마 글꼴(대체 글꼴 포함)을 이어받게 테마 스타일에서 만든다.
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            items: [
              for (final (v, label) in items)
                DropdownMenuItem(
                  value: v,
                  child: Text(label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(() => _position = v ?? _allPositions),
          ),
        ),
      ),
    );
    // 휴대폰에서도 두 칸을 한 줄에 둔다(검색 칸을 더 넓게) — 위아래로 쌓으면 키보드가 올라왔을 때
    // 검색 결과 목록이 보일 자리가 거의 남지 않았다.
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: wide ? 1 : 3, child: search),
          const SizedBox(width: 12),
          Expanded(flex: wide ? 1 : 2, child: position),
        ],
      ),
    );
  }

  Widget _resetButton() => OutlinedButton.icon(
    onPressed: _hasConditions ? _resetConditions : null,
    icon: const Icon(Icons.refresh, size: 18),
    label: Text(tr('검색 조건 초기화')),
  );

  /// 검색 칸·드롭다운이 함께 쓰는 회색 입력 상자(높이 44).
  Widget _fieldBox(
    BuildContext context,
    Widget child, {
    EdgeInsets padding = const EdgeInsets.only(left: 12, right: 8),
  }) => Container(
    height: 44,
    alignment: Alignment.center,
    padding: padding,
    decoration: BoxDecoration(
      color: _fillColor(context),
      borderRadius: BorderRadius.circular(8),
    ),
    child: child,
  );

  static Color _fillColor(BuildContext context) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.dark
        ? theme.colorScheme.surfaceContainerHighest
        : const Color(0xFFF1F3F6);
  }

  Widget _labeled(BuildContext context, String label, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      // 글자에 따라(띄어쓰기는 다른 글꼴로 그려진다) 줄 높이가 달라져서 두 칸의 입력 상자가
      // 어긋나지 않게 제목 줄 높이를 고정한다.
      SizedBox(
        height: 18,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
          ),
        ),
      ),
      const SizedBox(height: 6),
      child,
    ],
  );

  /// 칸 제목 — [trailing]이 있으면 같은 줄 오른쪽에 둔다(휴대폰의 검색 조건 초기화).
  Widget _paneLabel(BuildContext context, String text, {Widget? trailing}) {
    final label = Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).hintColor,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: trailing == null
          ? label
          : Row(
              children: [
                Expanded(child: label),
                const SizedBox(width: 8),
                trailing,
              ],
            ),
    );
  }

  /// 왼쪽 "팀 멤버" — 맨 위 고정 줄·"모든 멤버 선택하기", 그 아래 프로필 사진·이름·직책 목록.
  /// [labelTrailing]은 "팀 멤버 N" 줄 오른쪽에 붙일 것(휴대폰의 검색 조건 초기화).
  Widget _buildMembersPane(
    BuildContext context,
    List<AppUser> visible, {
    Widget? labelTrailing,
  }) {
    final theme = Theme.of(context);
    final canPick = widget.enabled && visible.isNotEmpty;
    final picked = visible.where((u) => _selected.contains(u.id)).length;
    final bool? allValue = picked == 0
        ? false
        : (picked == visible.length ? true : null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _paneLabel(
          context,
          tr('팀 멤버 {visible.length}', {'visible.length': visible.length}),
          trailing: labelTrailing,
        ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.pinnedRow case final pinned?) ...[
                  pinned,
                  const Divider(height: 1),
                ],
                if (widget.showSelectAll) ...[
                  Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      key: const ValueKey('invite-select-all'),
                      onTap: canPick ? () => _toggleAll(visible) : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        child: Row(
                          children: [
                            Checkbox(
                              tristate: true,
                              value: visible.isEmpty ? false : allValue,
                              onChanged: canPick
                                  ? (_) => _toggleAll(visible)
                                  : null,
                            ),
                            Text(
                              tr('모든 멤버 선택하기'),
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                ],
                Expanded(
                  child: visible.isEmpty
                      ? _EmptyText(
                          _users!.isEmpty
                              ? widget.noMembersText
                              : tr('조회 가능한 멤버가 없습니다.'),
                        )
                      : ListView.builder(
                          itemCount: visible.length,
                          itemBuilder: (context, i) {
                            final u = visible[i];
                            return _MemberRow(
                              key: ValueKey('invite-member-${u.id}'),
                              user: u,
                              position: _positionOf(u),
                              picking: true,
                              selected: _selected.contains(u.id),
                              resolveUrl: widget.session.resolveUrl,
                              onTap: widget.enabled ? () => _toggle(u) : null,
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 오른쪽 "선택된 멤버" — 고른 순서대로, ✕로 뺄 수 있다.
  Widget _buildSelectedPane(BuildContext context) {
    final selectedUsers = _selectedUsers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _paneLabel(
          context,
          tr('선택된 멤버 {selectedUsers.length}', {
            'selectedUsers.length': selectedUsers.length,
          }),
        ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: _fillColor(context),
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: selectedUsers.isEmpty
                ? _EmptyText(widget.emptySelectedText)
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    children: [
                      for (final u in selectedUsers)
                        _MemberRow(
                          key: ValueKey('invite-selected-${u.id}'),
                          user: u,
                          position: _positionOf(u),
                          resolveUrl: widget.session.resolveUrl,
                          onRemove: widget.enabled ? () => _toggle(u) : null,
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

/// 멤버 한 줄 — 왼쪽 목록([picking])에서는 체크박스로 고르고, 오른쪽 목록에서는 ✕로 뺀다.
/// 고르는 줄인데 [onTap]이 없으면 고를 수 없는 줄이라 흐리게 그린다.
class _MemberRow extends StatelessWidget {
  final AppUser user;
  final String? position;
  final String Function(String relative)? resolveUrl;
  final bool picking;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  const _MemberRow({
    super.key,
    required this.user,
    required this.position,
    required this.resolveUrl,
    this.picking = false,
    this.selected = false,
    this.onTap,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onTap = this.onTap;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: Container(
          color: picking && selected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
              : null,
          padding: EdgeInsets.fromLTRB(picking ? 6 : 12, 6, 6, 6),
          child: Opacity(
            opacity: picking && onTap == null ? 0.55 : 1,
            child: Row(
              children: [
                if (picking)
                  Checkbox(
                    value: selected,
                    onChanged: onTap == null ? null : (_) => onTap(),
                  ),
                UserAvatar(user: user, resolveUrl: resolveUrl, radius: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          user.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (position != null) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            position!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.hintColor,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (onRemove != null)
                  IconButton(
                    tooltip: tr('선택 해제'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: onRemove,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyText extends StatelessWidget {
  final String text;
  const _EmptyText(this.text);

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor),
      ),
    ),
  );
}
