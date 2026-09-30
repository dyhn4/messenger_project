import 'dart:math';

import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/team.dart';
import '../services/api_client.dart' show PositionOption;
import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/avatar_utils.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/icon_edit_dialog.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/org_edit_dialog.dart';
import '../widgets/role_badge.dart';
import '../widgets/sort_menu_button.dart';
import '../widgets/team_avatar.dart';
import '../widgets/user_avatar.dart';
import 'team_invite_link_screen.dart';

/// 팀 설정(소유자·관리자만). "팀 정보"(이름·도메인·아이콘·초대 권한, 소유자에게는 소유권
/// 이양/팀 삭제까지)와 "멤버"(추가·등급 변경·부서/직책·빼기) 두 탭으로 나뉜다.
/// 여기서 보이는 버튼은 전부 서버(server/src/permissions.js)가 다시 검사한다.
Future<void> showTeamSettingsDialog(
  BuildContext context,
  Session session,
  Team team,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => TeamSettingsDialog(session: session, team: team),
  );
}

/// "팀 생성하기" — 팀 설정과 같은 화면(아이콘·이름·토픽 생성 권한·메시지 설정)에서 값을
/// 고른 뒤 "만들기"로 한 번에 만든다. 만든 팀을 돌려주고, 취소하면 null.
Future<Team?> showCreateTeamDialog(BuildContext context, Session session) {
  return showDialog<Team>(
    context: context,
    builder: (_) => TeamSettingsDialog(
      session: session,
      creating: true,
      // 아직 없는 팀의 자리표시자 — 배경색은 팔레트에서 무작위로 미리 골라 둔다.
      team: Team(
        id: '',
        name: '',
        iconColor: colorToHex(
          _teamColors[Random().nextInt(_teamColors.length)],
        ),
        createdAt: DateTime.now(),
      ),
    ),
  );
}

class TeamSettingsDialog extends StatefulWidget {
  final Session session;
  final Team team;

  /// true면 "팀 생성하기" — 멤버 탭·팀 초대 링크·팀 삭제처럼 이미 있는 팀에만 의미 있는 부분을
  /// 숨기고, "저장" 대신 "만들기"로 새 팀을 만든다.
  final bool creating;
  const TeamSettingsDialog({
    super.key,
    required this.session,
    required this.team,
    this.creating = false,
  });

  @override
  State<TeamSettingsDialog> createState() => _TeamSettingsDialogState();
}

class _TeamSettingsDialogState extends State<TeamSettingsDialog> {
  late final _nameController = TextEditingController(text: widget.team.name);
  late String _emoji = widget.team.iconEmoji ?? '';
  late Color? _color = parseHexColor(widget.team.iconColor);
  late String? _iconUrl = widget.team.iconUrl;
  late TopicCreationPolicy _topicCreationPolicy =
      widget.team.topicCreationPolicy;
  // _topicCreationPolicy가 designated일 때만 의미가 있다 — 아직 저장 전인 로컬 선택 상태.
  late List<String> _designatedTopicCreatorIds = List.of(
    widget.team.topicCreatorIds,
  );
  late bool _messageEditDeleteEnabled = widget.team.messageEditDeleteEnabled;
  late int _messageEditDeleteWindow =
      widget.team.messageEditDeleteWindowSeconds;
  bool _savingInfo = false;
  final _infoScrollController = ScrollController();

  List<AppUser>? _members;
  String? _membersError;

  MemberSortField _sortField = MemberSortField.name;
  bool _sortAscending = true;
  List<PositionOption>? _positionOptions;

  bool get _isOwner => widget.team.isOwner;

  @override
  void initState() {
    super.initState();
    if (widget.creating) return; // 아직 없는 팀이라 멤버·직책을 불러올 게 없다.
    _loadMembers();
    widget.session.fetchPublicPositionOptions().then((list) {
      if (mounted) setState(() => _positionOptions = list);
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _infoScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadMembers() async {
    try {
      final members = await widget.session.fetchMembersOfTeam(widget.team.id);
      if (!mounted) return;
      setState(() => _members = members);
    } catch (e) {
      if (!mounted) return;
      setState(() => _membersError = e.toString());
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  IconChoice get _iconChoice => IconChoice(
    emoji: _emoji.isEmpty ? null : _emoji,
    color: _color,
    photoUrl: _iconUrl,
  );

  /// 미리보기용 임시 팀 — 아직 저장하지 않은 아이콘을 그대로 그려보기 위한 것.
  Team _teamWith(IconChoice icon) => Team(
    id: widget.team.id,
    name: _nameController.text.trim().isEmpty
        ? widget.team.name
        : _nameController.text.trim(),
    iconEmoji: icon.emoji ?? '',
    iconColor: icon.color == null ? null : colorToHex(icon.color!),
    iconUrl: icon.photoUrl,
    createdAt: widget.team.createdAt,
  );

  Team get _preview => _teamWith(_iconChoice);

  /// 프로필 사진처럼 아이콘의 사진기 배지를 누르면 편집 팝업(초기화/아이콘 선택하기/사진
  /// 올리기)이 뜬다 — 여기서는 미리보기만 바뀌고, 아래 "저장"을 눌러야 서버에 반영된다.
  Future<void> _editIcon() async {
    final result = await showIconEditDialog(
      context,
      title: '팀 아이콘 편집',
      session: widget.session,
      initial: _iconChoice,
      preview: (icon, size) => TeamAvatar(
        team: _teamWith(icon),
        resolveUrl: widget.session.resolveUrl,
        size: size,
      ),
      pickIcon: (current) async {
        final picked = await showDialog<(String, Color?)>(
          context: context,
          builder: (_) => _TeamIconPickerDialog(
            team: _teamWith(current),
            resolveUrl: widget.session.resolveUrl,
            initialEmoji: current.emoji ?? '',
            initialColor: current.color,
          ),
        );
        if (picked == null) return null;
        final (emoji, color) = picked;
        return IconChoice(emoji: emoji.isEmpty ? null : emoji, color: color);
      },
    );
    if (result == null || !mounted) return;
    setState(() {
      _emoji = result.emoji ?? '';
      _color = result.color;
      _iconUrl = result.photoUrl;
    });
  }

  /// "팀 생성하기"의 "만들기" — 고른 값으로 팀을 만들고 그 팀을 돌려주며 닫는다.
  Future<void> _create() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    setState(() => _savingInfo = true);
    try {
      // 팀을 만든 사람이 그 팀의 소유자가 된다(서버 teams.js).
      final team = await widget.session.createTeam(
        name: name,
        iconEmoji: _emoji.isEmpty ? null : _emoji,
        iconColor: _color == null ? null : colorToHex(_color!),
        iconUrl: _iconUrl,
        topicCreationPolicy: _topicCreationPolicy,
        messageEditDeleteEnabled: _messageEditDeleteEnabled,
        messageEditDeleteWindowSeconds: _messageEditDeleteWindow,
      );
      if (mounted) Navigator.of(context).pop(team);
    } catch (e) {
      _toast('팀 생성 실패: $e');
      if (mounted) setState(() => _savingInfo = false);
    }
  }

  Future<void> _saveInfo() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    setState(() => _savingInfo = true);
    try {
      // 이모지·색은 "없음"도 고를 수 있어야 해서 빈 문자열로 보낸다(서버가 null로 지운다).
      await widget.session.updateTeam(
        widget.team,
        name: name,
        iconEmoji: _emoji,
        iconColor: _color == null ? '' : colorToHex(_color!),
        iconUrl: _iconUrl ?? '',
        topicCreationPolicy: _topicCreationPolicy,
        topicCreatorIds: _topicCreationPolicy == TopicCreationPolicy.designated
            ? _designatedTopicCreatorIds
            : null,
        messageEditDeleteEnabled: _messageEditDeleteEnabled,
        messageEditDeleteWindowSeconds: _messageEditDeleteWindow,
      );
      if (mounted) showAppToast(context, '팀 정보를 저장했습니다.');
    } catch (e) {
      _toast('저장 실패: $e');
    } finally {
      if (mounted) setState(() => _savingInfo = false);
    }
  }

  /// "토픽 생성 권한"을 '지정'으로 바꾸거나(처음 고를 때) 이미 지정된 목록을 다시 고칠 때
  /// (아래 "변경" 버튼) 공통으로 쓰는 멤버 선택 다이얼로그 — 정회원 이상만 후보로 보여준다.
  /// 취소하면 null.
  Future<List<String>?> _pickTopicCreators() async {
    final members = _members;
    if (members == null) {
      _toast('팀원 목록을 불러오는 중입니다. 잠시 후 다시 시도하세요.');
      return null;
    }
    final candidates = members
        .where((u) => accountRoleFromWire(u.role) != AccountRole.guest)
        .toList();
    return showDialog<List<String>>(
      context: context,
      builder: (_) => _DesignateTopicCreatorsDialog(
        session: widget.session,
        candidates: candidates,
        initialSelectedIds: _designatedTopicCreatorIds.toSet(),
      ),
    );
  }

  /// 토픽 생성 권한 SegmentedButton에서 '지정'을 고르면 바로 멤버 선택 다이얼로그가 뜬다 —
  /// 취소하면 정책 선택 자체를 되돌린다(아직 아무도 안 골랐는데 '지정'만 선택된 채로 남는
  /// 어중간한 상태를 안 만들기 위해서).
  Future<void> _onTopicCreationPolicyChanged(
    Set<TopicCreationPolicy> selection,
  ) async {
    final policy = selection.first;
    if (policy != TopicCreationPolicy.designated) {
      setState(() => _topicCreationPolicy = policy);
      return;
    }
    final ids = await _pickTopicCreators();
    if (ids == null || !mounted) return;
    setState(() {
      _topicCreationPolicy = TopicCreationPolicy.designated;
      _designatedTopicCreatorIds = ids;
    });
  }

  /// 이미 '지정'으로 정해진 상태에서 목록만 다시 고를 때("변경" 버튼).
  Future<void> _editDesignatedTopicCreators() async {
    final ids = await _pickTopicCreators();
    if (ids == null || !mounted) return;
    setState(() => _designatedTopicCreatorIds = ids);
  }

  /// "지정된 사람: 홍길동, 김철수" 표시용 — 서버는 id만 주므로 이미 불러온 팀원 목록과
  /// 대조해서 이름을 찾는다(아직 목록을 못 불러왔으면 id 그대로 보여준다).
  String _designatedTopicCreatorNames() {
    final members = {for (final u in _members ?? const <AppUser>[]) u.id: u};
    return _designatedTopicCreatorIds
        .map((id) => members[id]?.name ?? id)
        .join(', ');
  }

  Future<void> _addMembers() async {
    final added = await showDialog<List<AppUser>>(
      context: context,
      builder: (_) => _AddTeamMembersDialog(
        session: widget.session,
        team: widget.team,
        existingIds: (_members ?? const <AppUser>[]).map((u) => u.id).toSet(),
      ),
    );
    if (added != null && mounted) setState(() => _members = added);
  }

  Future<void> _editOrg(AppUser user) async {
    final position = await showOrgEditDialog(context, widget.session, user);
    if (position == null || !mounted) return;
    try {
      final members = await widget.session.updateTeamMember(
        widget.team,
        user.id,
        position: position,
      );
      if (mounted) setState(() => _members = members);
    } catch (e) {
      _toast('실패: $e');
    }
  }

  Future<void> _removeMember(AppUser user) async {
    final ok = await _confirm(
      title: '팀에서 빼기',
      message: '${user.name} 님을 ${widget.team.name} 팀에서 뺄까요?',
      confirmLabel: '빼기',
    );
    if (ok != true || !mounted) return;
    try {
      final members = await widget.session.removeTeamMember(
        widget.team,
        user.id,
      );
      if (mounted) setState(() => _members = members);
    } catch (e) {
      _toast('실패: $e');
    }
  }

  /// 직책 목록에서의 서열 — 목록은 이미 서열순(작을수록 낮음)으로 오므로 그 안에서의
  /// 위치(index)가 곧 서열이다. 목록에 없거나(미등록·자유 입력 시절의 값) 아직 안 불러왔으면
  /// 맨 뒤로 보낸다.
  int _positionRank(String? label) {
    if (label == null || label.isEmpty) return 1 << 30;
    final index = _positionOptions?.indexWhere((o) => o.label == label) ?? -1;
    return index == -1 ? 1 << 30 : index;
  }

  List<AppUser> get _sortedMembers {
    final members = List<AppUser>.of(_members ?? const []);
    final cmp = switch (_sortField) {
      MemberSortField.name => (AppUser a, AppUser b) => a.name.compareTo(
        b.name,
      ),
      MemberSortField.role => (AppUser a, AppUser b) => accountRoleFromWire(
        a.role,
      ).rank.compareTo(accountRoleFromWire(b.role).rank),
      MemberSortField.position => (AppUser a, AppUser b) => _positionRank(
        a.position,
      ).compareTo(_positionRank(b.position)),
      // 이 탭은 이미 한 팀 안이라 "팀" 정렬은 SortMenuButton.fields에 아예 안 넣는다 — 도달 안 함.
      MemberSortField.team => (AppUser a, AppUser b) => 0,
    };
    members.sort(_sortAscending ? cmp : (a, b) => cmp(b, a));
    return members;
  }

  Future<void> _transferOwnership(AppUser user) async {
    final ok = await _confirm(
      title: '소유권 넘기기',
      message:
          '${user.name} 님을 이 팀의 소유자로 만들까요?\n'
          '넘기고 나면 나는 관리자가 되고, 팀 삭제·소유권 이양은 더 이상 할 수 없습니다.',
      confirmLabel: '넘기기',
    );
    if (ok != true || !mounted) return;
    try {
      final members = await widget.session.transferTeamOwnership(
        widget.team,
        user.id,
      );
      if (mounted) setState(() => _members = members);
      _toast('${user.name} 님에게 소유권을 넘겼습니다.');
    } catch (e) {
      _toast('실패: $e');
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SizedBox(width: 320, child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteTeam() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _DeleteTeamDialog(team: widget.team),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.session.deleteTeam(widget.team);
      // 서버가 team:left(deleted)를 보내서 팀 목록/방을 정리하고 토스트도 띄운다.
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _toast('삭제 실패: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.creating) {
      // 새 팀에는 아직 멤버가 없으니 "멤버" 탭 없이 팀 정보만 보여준다.
      return FloatingDialog(
        title: '팀 생성하기',
        maxWidth: 520,
        maxHeight: 700,
        padding: const EdgeInsets.fromLTRB(20, 20, 0, 20),
        child: _buildInfoTab(context),
      );
    }
    return DefaultTabController(
      length: 2,
      child: FloatingDialog(
        title: '팀 설정',
        maxWidth: 520,
        maxHeight: 700,
        // 오른쪽 여백을 0으로 줘서 "팀 정보" 탭의 스크롤 영역이 실제 레이아웃 상으로 창
        // 끝까지 닿게 한다(settings_screen.dart와 같은 이유 — Positioned 오버플로 트릭은
        // 스크롤바 히트테스트가 안 먹혀서, 폭 자체를 넓히는 이 방식을 쓴다). 대신 오른쪽
        // 여백이 필요한 부분(탭바, 스크롤 내용, 팀원 탭, 저장 버튼)은 각자 직접 챙긴다.
        padding: const EdgeInsets.fromLTRB(20, 20, 0, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.only(right: 20),
              child: TabBar(
                tabs: [
                  Tab(text: '팀 정보'),
                  Tab(text: '멤버'),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TabBarView(
                children: [_buildInfoTab(context), _buildMembersTab(context)],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoTab(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: MutedScrollbar(
            controller: _infoScrollController,
            child: SingleChildScrollView(
              controller: _infoScrollController,
              // 스크롤바 두께(10) + 원래 창 오른쪽 여백(20)만큼을 내용 쪽에서 챙긴다.
              padding: const EdgeInsets.only(right: 34),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 팀 아이콘(왼쪽)과 팀 이름(오른쪽)을 한 줄에 두고, 이름 입력칸은 아이콘
                  // 높이의 가운데에 맞춘다.
                  const Row(
                    children: [
                      SizedBox(width: 72, child: _SectionLabel('팀 아이콘')),
                      SizedBox(width: 24),
                      Expanded(child: _SectionLabel('팀 이름')),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      CameraBadge(
                        onTap: _editIcon,
                        child: TeamAvatar(
                          team: _preview,
                          resolveUrl: widget.session.resolveUrl,
                          size: 72,
                        ),
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        child: TextField(
                          controller: _nameController,
                          autofocus: widget.creating,
                          maxLength: 30,
                          decoration: InputDecoration(
                            hintText: widget.creating ? '예: 개발팀' : null,
                            border: const OutlineInputBorder(),
                            isDense: true,
                            // 글자 수 표시가 입력칸 아래에 붙으면 가운데 정렬이 어긋나서 숨긴다
                            // (30자 제한은 그대로).
                            counterText: '',
                          ),
                          // 아이콘 미리보기의 이니셜 갱신
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                    ],
                  ),
                  // "팀을 관리할 수 있는 사람"이라도 "팀 초대 링크 생성 권한"(서버 설정)이
                  // 없으면 안 보인다 — 삼선 메뉴/더보기 탭에 있던 것과 같은 조건이다. 어느
                  // 팀으로 초대할지 이미 정해져 있는 이 화면에서 만드는 게 더 자연스러워서
                  // 여기로 옮겼다(원래 있던 "팀 도메인" 필드는 실제로 아무 기능이 없어서 뺐다).
                  if (widget.session.canCreateTeamInviteLink &&
                      !widget.creating) ...[
                    const _SectionDivider(),
                    const _SectionLabel('팀 초대 링크'),
                    const SizedBox(height: 4),
                    Text(
                      '이 링크로 가입하면 자동으로 이 팀에 합류하고 지정한 등급이 함께 부여됩니다.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: () => showTeamInviteLinkScreen(
                          context,
                          widget.session,
                          initialTeamId: widget.team.id,
                        ),
                        icon: const Icon(Icons.group_add_outlined, size: 18),
                        label: const Text('팀 초대 링크 생성'),
                      ),
                    ),
                  ],
                  const _SectionDivider(),
                  const _SectionLabel('토픽 생성 권한'),
                  const SizedBox(height: 4),
                  Text(
                    '새 토픽을 만들 수 있는 등급입니다. 그룹채팅은 이 설정과 무관하게 정회원 '
                    '이상이면 항상 만들 수 있고, 준회원은 어느 설정에서도 만들 수 없습니다.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<TopicCreationPolicy>(
                    segments: [
                      // '지정'은 멤버 중에서 고르는 거라, 아직 멤버가 없는 새 팀에서는 뺀다
                      // (만든 뒤 팀 설정에서 정한다).
                      for (final p in TopicCreationPolicy.values)
                        if (!widget.creating ||
                            p != TopicCreationPolicy.designated)
                          ButtonSegment(value: p, label: Text(p.label)),
                    ],
                    selected: {_topicCreationPolicy},
                    onSelectionChanged: _onTopicCreationPolicyChanged,
                  ),
                  if (_topicCreationPolicy ==
                      TopicCreationPolicy.designated) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _designatedTopicCreatorIds.isEmpty
                                ? '지정된 사람 없음'
                                : '지정된 사람: ${_designatedTopicCreatorNames()}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: Theme.of(context).hintColor),
                          ),
                        ),
                        TextButton(
                          onPressed: _editDesignatedTopicCreators,
                          child: const Text('변경'),
                        ),
                      ],
                    ),
                  ],
                  const _SectionDivider(),
                  const _SectionLabel('메시지 설정'),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _messageEditDeleteEnabled,
                    onChanged: (v) =>
                        setState(() => _messageEditDeleteEnabled = v),
                    title: const Text('메시지 수정/삭제'),
                    subtitle: Text(
                      _messageEditDeleteEnabled
                          ? '작성 후 정해진 시간 안에서만 메시지·댓글을 수정하거나 삭제할 수 있습니다.'
                          : '이 팀에서는 아무도(소유자·관리자 포함) 메시지·댓글을 수정하거나 삭제할 수 없습니다.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  ),
                  if (_messageEditDeleteEnabled) ...[
                    const SizedBox(height: 4),
                    const _SectionLabel('수정/삭제 가능 시간'),
                    const SizedBox(height: 4),
                    Text(
                      '작성 후 이 시간이 지나면 본인 메시지도, 관리자의 콘텐츠 관리도 수정·삭제할 수 없습니다.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final seconds in editDeleteWindowOptions)
                          ChoiceChip(
                            label: Text(formatEditDeleteWindow(seconds)),
                            selected: _messageEditDeleteWindow == seconds,
                            onSelected: (_) => setState(
                              () => _messageEditDeleteWindow = seconds,
                            ),
                          ),
                      ],
                    ),
                  ],
                  if (_isOwner) ...[
                    const _SectionDivider(),
                    _SectionLabel(
                      '팀 삭제',
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '이 팀의 모든 채팅방·메시지·댓글이 함께 사라지며 되돌릴 수 없습니다.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: _deleteTeam,
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('팀 삭제하기'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        // FloatingDialog의 오른쪽 여백을 0으로 받았으니(위 참고), 스크롤바가 필요 없는
        // 저장 버튼 줄은 여기서 직접 원래 여백(20)만큼 오른쪽을 띄워준다. 스크롤 밖에 있어서
        // 내용이 아무리 길어도 항상 보인다.
        Padding(
          padding: const EdgeInsets.only(right: 20),
          child: Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              // 만들 때는 팀 이름을 적어야 "만들기"가 켜진다.
              onPressed:
                  _savingInfo ||
                      (widget.creating && _nameController.text.trim().isEmpty)
                  ? null
                  : (widget.creating ? _create : _saveInfo),
              child: _savingInfo
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(widget.creating ? '만들기' : '저장'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMembersTab(BuildContext context) {
    if (_membersError != null) return Center(child: Text(_membersError!));
    if (_members == null) {
      return const Center(child: CircularProgressIndicator());
    }
    // "팀 정보" 탭과 달리 이 탭은 스크롤바를 오른쪽 끝에 붙일 필요가 없지만, FloatingDialog의
    // 오른쪽 여백이 0이므로(위 참고) 여기서도 원래 여백(20)만큼 직접 챙긴다.
    return Padding(
      padding: const EdgeInsets.only(right: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: _SectionLabel('멤버 ${_members!.length}')),
              TextButton.icon(
                onPressed: _addMembers,
                icon: const Icon(Icons.person_add_alt, size: 18),
                label: const Text('추가'),
              ),
            ],
          ),
          _MembersTableHead(
            sortField: _sortField,
            sortAscending: _sortAscending,
            onSortChanged: (field, ascending) => setState(() {
              _sortField = field;
              _sortAscending = ascending;
            }),
          ),
          const Divider(height: 1),
          Expanded(
            child: Builder(
              builder: (context) {
                final members = _sortedMembers;
                return ListView.separated(
                  itemCount: members.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final user = members[i];
                    return _MemberRow(
                      session: widget.session,
                      user: user,
                      isTeamOwner: widget.team.isOwner,
                      isMe: user.id == widget.session.userId,
                      onEditOrg: () => _editOrg(user),
                      onTransferOwnership: () => _transferOwnership(user),
                      onRemove: () => _removeMember(user),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// "멤버" 탭 목록 위 칼럼 제목 — 관리자 콘솔 "회원" 탭(admin_console_screen.dart)과 같은
/// 비율(이름 9 / 등급 5 / 직책 5)로 맞춘다. 맨 끝은 각 행의 PopupMenuButton 자리에 정렬
/// 버튼을 대신 놓는다.
class _MembersTableHead extends StatelessWidget {
  final MemberSortField sortField;
  final bool sortAscending;
  final void Function(MemberSortField field, bool ascending) onSortChanged;

  const _MembersTableHead({
    required this.sortField,
    required this.sortAscending,
    required this.onSortChanged,
  });

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).hintColor,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(flex: 9, child: Text('이름', style: style)),
          const SizedBox(width: 16),
          Expanded(flex: 5, child: Text('등급', style: style)),
          const SizedBox(width: 16),
          Expanded(flex: 5, child: Text('직책', style: style)),
          SortMenuButton<MemberSortField>(
            fields: const [
              MemberSortField.name,
              MemberSortField.role,
              MemberSortField.position,
            ],
            labelOf: (f) => f.label,
            selectedField: sortField,
            ascending: sortAscending,
            onChanged: onSortChanged,
          ),
        ],
      ),
    );
  }
}

/// 팀원 한 줄: 아바타·이름 / 등급(+소유자) 뱃지 / 직책 / 관리 메뉴 — 관리자 콘솔 "회원" 탭과
/// 같은 칼럼 구조. 등급은 **보여주기만** 한다 — 계정 등급이라 서버 운영자가 관리자 콘솔에서만
/// 바꾼다.
class _MemberRow extends StatelessWidget {
  final Session session;
  final AppUser user;
  final bool isTeamOwner; // 내가 이 팀의 소유자인지
  final bool isMe;
  final VoidCallback onEditOrg;
  final VoidCallback onTransferOwnership;
  final VoidCallback onRemove;

  const _MemberRow({
    required this.session,
    required this.user,
    required this.isTeamOwner,
    required this.isMe,
    required this.onEditOrg,
    required this.onTransferOwnership,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final role = accountRoleFromWire(user.role);
    // 소유자는 뺄 수 없고, 관리자는 그 팀의 소유자만 뺄 수 있다(서버 teams.js와 같은 규칙).
    final canRemove =
        !user.isOwner && !isMe && (role != AccountRole.admin || isTeamOwner);
    final roleColors = roleBadgeColors(context, role.wire);
    final ownerColors = roleBadgeColors(context, 'owner');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 9,
            child: Row(
              children: [
                UserAvatar(user: user, resolveUrl: session.resolveUrl),
                const SizedBox(width: 10),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          user.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (isMe)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text(
                            '(나)',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).hintColor,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 5,
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                RoleBadge(
                  label: role.label,
                  bg: roleColors.bg,
                  fg: roleColors.fg,
                ),
                if (user.isOwner)
                  RoleBadge(
                    label: '소유자',
                    bg: ownerColors.bg,
                    fg: ownerColors.fg,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 5,
            child: Text(
              user.position?.isNotEmpty == true ? user.position! : '미등록',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).hintColor,
                fontStyle: user.position?.isNotEmpty == true
                    ? FontStyle.normal
                    : FontStyle.italic,
              ),
            ),
          ),
          PopupMenuButton<_MemberAction>(
            tooltip: '팀원 관리',
            position: PopupMenuPosition.under,
            onSelected: (action) => switch (action) {
              _MemberAction.editOrg => onEditOrg(),
              _MemberAction.transferOwnership => onTransferOwnership(),
              _MemberAction.remove => onRemove(),
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _MemberAction.editOrg,
                child: Row(
                  children: [
                    Icon(Icons.badge_outlined, size: 20),
                    SizedBox(width: 8),
                    Text('직책 수정'),
                  ],
                ),
              ),
              // 소유권 이양은 그 팀의 소유자만, 자기 자신 말고 다른 사람에게.
              if (isTeamOwner && !isMe && !user.isOwner)
                const PopupMenuItem(
                  value: _MemberAction.transferOwnership,
                  child: Row(
                    children: [
                      Icon(Icons.workspace_premium_outlined, size: 20),
                      SizedBox(width: 8),
                      Text('소유권 넘기기'),
                    ],
                  ),
                ),
              if (canRemove) ...[
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: _MemberAction.remove,
                  child: Row(
                    children: [
                      Icon(
                        Icons.person_remove_alt_1_outlined,
                        size: 20,
                        color: Colors.redAccent,
                      ),
                      SizedBox(width: 8),
                      Text('팀에서 빼기', style: TextStyle(color: Colors.redAccent)),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

enum _MemberAction { editOrg, transferOwnership, remove }

/// 팀 삭제 확인 — 실수를 막기 위해 팀 이름을 그대로 타이핑해야 버튼이 켜진다(서버도 같은 값을
/// 다시 확인한다).
class _DeleteTeamDialog extends StatefulWidget {
  final Team team;
  const _DeleteTeamDialog({required this.team});

  @override
  State<_DeleteTeamDialog> createState() => _DeleteTeamDialogState();
}

class _DeleteTeamDialogState extends State<_DeleteTeamDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matches = _controller.text.trim() == widget.team.name;
    return AlertDialog(
      title: const Text('팀 삭제'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "'${widget.team.name}' 팀의 모든 채팅방·메시지·댓글이 영구히 삭제됩니다. 되돌릴 수 없습니다.",
            ),
            const SizedBox(height: 12),
            Text(
              '계속하려면 팀 이름을 그대로 입력하세요.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                isDense: true,
                hintText: widget.team.name,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: matches ? () => Navigator.of(context).pop(true) : null,
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          child: const Text('영구 삭제'),
        ),
      ],
    );
  }
}

/// 새 팀원 고르기 — 서버에 가입한 사람 중 아직 이 팀에 없는 사람만 보여준다.
class _AddTeamMembersDialog extends StatefulWidget {
  final Session session;
  final Team team;
  final Set<String> existingIds;
  const _AddTeamMembersDialog({
    required this.session,
    required this.team,
    required this.existingIds,
  });

  @override
  State<_AddTeamMembersDialog> createState() => _AddTeamMembersDialogState();
}

class _AddTeamMembersDialogState extends State<_AddTeamMembersDialog> {
  List<AppUser>? _candidates;
  String? _error;
  final _selected = <String>{};
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final users = await widget.session.fetchAllUsers();
      users.removeWhere((u) => widget.existingIds.contains(u.id));
      if (!mounted) return;
      setState(() => _candidates = users);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _submit() async {
    if (_selected.isEmpty) return;
    setState(() => _submitting = true);
    try {
      final members = await widget.session.addTeamMembers(
        widget.team,
        _selected.toList(),
      );
      if (mounted) Navigator.of(context).pop(members);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('추가 실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _error != null
        ? Center(child: Text(_error!))
        : _candidates == null
        ? const Center(child: CircularProgressIndicator())
        : _candidates!.isEmpty
        ? const Center(child: Text('추가할 수 있는 사람이 없습니다.'))
        : ListView(
            shrinkWrap: true,
            children: [
              // 체크박스 없이 눌러서 선택/해제하고, 선택된 항목은 배경색으로 표시한다(아래
              // "토픽 생성 권한 지정"과 같은 방식). 등급은 계정에 붙어 있는 값이라 여기서
              // 고르는 게 아니라 보여주기만 한다.
              for (final user in _candidates!)
                ListTile(
                  leading: UserAvatar(
                    user: user,
                    resolveUrl: widget.session.resolveUrl,
                  ),
                  title: Text(user.name),
                  subtitle: Text(
                    '${user.username} · ${accountRoleFromWire(user.role).label}',
                  ),
                  selected: _selected.contains(user.id),
                  selectedTileColor: Theme.of(
                    context,
                  ).colorScheme.primaryContainer.withValues(alpha: 0.4),
                  onTap: () => setState(() {
                    if (_selected.contains(user.id)) {
                      _selected.remove(user.id);
                    } else {
                      _selected.add(user.id);
                    }
                  }),
                ),
            ],
          );

    return FloatingDialog(
      title: '팀원 추가',
      maxWidth: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(child: list),
          const Divider(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _submitting
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: const Text('취소'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _selected.isEmpty || _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text('추가하기 (${_selected.length})'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "토픽 생성 권한"을 '지정'으로 정할 때 콕 집어 고르는 다이얼로그 — [candidates](정회원
/// 이상만 이미 걸러서 넘어온다) 중에서 여러 명을 골라 "확인"을 누르면 그 id 목록을 그대로
/// 반환한다. 여기서 서버에 저장하지는 않는다 — 팀 설정 화면이 "저장"을 눌러야 실제로 반영된다.
class _DesignateTopicCreatorsDialog extends StatefulWidget {
  final Session session;
  final List<AppUser> candidates;
  final Set<String> initialSelectedIds;
  const _DesignateTopicCreatorsDialog({
    required this.session,
    required this.candidates,
    required this.initialSelectedIds,
  });

  @override
  State<_DesignateTopicCreatorsDialog> createState() =>
      _DesignateTopicCreatorsDialogState();
}

class _DesignateTopicCreatorsDialogState
    extends State<_DesignateTopicCreatorsDialog> {
  late final _selected = Set<String>.of(widget.initialSelectedIds);

  @override
  Widget build(BuildContext context) {
    final list = widget.candidates.isEmpty
        ? const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(child: Text('지정할 수 있는 정회원 이상 팀원이 없습니다.')),
          )
        : ListView(
            shrinkWrap: true,
            children: [
              for (final user in widget.candidates)
                ListTile(
                  leading: UserAvatar(
                    user: user,
                    resolveUrl: widget.session.resolveUrl,
                  ),
                  title: Text(user.name),
                  subtitle: Text(
                    '${user.username} · ${accountRoleFromWire(user.role).label}',
                  ),
                  selected: _selected.contains(user.id),
                  selectedTileColor: Theme.of(
                    context,
                  ).colorScheme.primaryContainer.withValues(alpha: 0.4),
                  onTap: () => setState(() {
                    if (_selected.contains(user.id)) {
                      _selected.remove(user.id);
                    } else {
                      _selected.add(user.id);
                    }
                  }),
                ),
            ],
          );

    return FloatingDialog(
      title: '토픽 생성 권한 지정',
      maxWidth: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '정회원 이상 중에서 새 토픽을 만들 수 있는 사람을 고르세요.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 12),
          Flexible(child: list),
          const Divider(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('취소'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _selected.isEmpty
                      ? null
                      : () => Navigator.of(context).pop(_selected.toList()),
                  child: Text('확인 (${_selected.length})'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "팀 정보" 탭의 항목 사이 구분선.
class _SectionDivider extends StatelessWidget {
  const _SectionDivider();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 16),
    child: Divider(height: 1),
  );
}

/// "팀 아이콘 선택하기" 팝업 — 프로필의 "캐릭터 선택하기"(my_profile_dialog.dart)와 같은
/// 구성이다. 아이콘 첫 칸은 팀 이름 앞 2글자로 만든 이니셜이고, 배경색은 이니셜·이모지
/// 모두에 적용된다. "확인"을 누르면 (이모지(이니셜이면 ''), 배경색)을 돌려준다.
class _TeamIconPickerDialog extends StatefulWidget {
  final Team team;
  final String Function(String relative) resolveUrl;
  final String initialEmoji;
  final Color? initialColor;
  const _TeamIconPickerDialog({
    required this.team,
    required this.resolveUrl,
    required this.initialEmoji,
    required this.initialColor,
  });

  @override
  State<_TeamIconPickerDialog> createState() => _TeamIconPickerDialogState();
}

class _TeamIconPickerDialogState extends State<_TeamIconPickerDialog> {
  late String _emoji = widget.initialEmoji;
  late Color? _color = widget.initialColor;

  Team _withIcon(String emoji) => Team(
    id: widget.team.id,
    name: widget.team.name,
    iconEmoji: emoji,
    iconColor: _color == null ? null : colorToHex(_color!),
    createdAt: widget.team.createdAt,
  );

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '팀 아이콘 선택하기',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              TeamAvatar(
                team: _withIcon(_emoji),
                resolveUrl: widget.resolveUrl,
                size: 88,
              ),
              const SizedBox(height: 16),
              const _SectionLabel('아이콘'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in ['', ..._teamEmojis])
                    _EmojiChoice(
                      selected: e == _emoji,
                      onTap: () => setState(() => _emoji = e),
                      child: TeamAvatar(
                        team: _withIcon(e),
                        resolveUrl: widget.resolveUrl,
                        size: 32,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const _SectionLabel('배경색'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final c in _teamColors)
                    _ColorChoice(
                      color: c,
                      selected: _color?.toARGB32() == c.toARGB32(),
                      onTap: () => setState(() => _color = c),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('취소'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () =>
                          Navigator.of(context).pop((_emoji, _color)),
                      child: const Text('확인'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final Color? color;
  const _SectionLabel(this.text, {this.color});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
    ),
  );
}

class _EmojiChoice extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  final Widget child;
  const _EmojiChoice({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).dividerColor,
            width: selected ? 2 : 1,
          ),
        ),
        child: child,
      ),
    );
  }
}

class _ColorChoice extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  const _ColorChoice({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
            width: 3,
          ),
        ),
      ),
    );
  }
}

const _teamEmojis = [
  '🏢',
  '💼',
  '🚀',
  '💡',
  '🛠️',
  '📊',
  '🎨',
  '🧪',
  '📣',
  '🤝',
  '🌱',
  '⭐',
];

const _teamColors = [
  Color(0xFF9575CD),
  Color(0xFF4C6EF5),
  Color(0xFF15AABF),
  Color(0xFF37B24D),
  Color(0xFFFAB005),
  Color(0xFFFF6B35),
  Color(0xFFE64980),
  Color(0xFF8D6E63),
];
