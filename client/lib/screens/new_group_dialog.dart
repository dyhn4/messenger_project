import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../services/api_client.dart' show ApiException;
import '../services/session.dart';
import '../widgets/avatar_utils.dart' show colorToHex;
import '../widgets/floating_dialog.dart';
import '../widgets/group_icon_picker.dart';
import '../widgets/icon_edit_dialog.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/user_avatar.dart';
import 'home_screen.dart' show wideBreakpoint;
import 'invite_members_screen.dart' show showPickMembers;
import '../l10n/tr.dart';

/// 새 그룹채팅 만들기 — 넓은 화면(PC)은 떠 있는 창, 좁은 화면(모바일)은 전체 화면으로 띄우고, 만들어진
/// 그룹채팅을 [onOpenRoom]으로 연다. 사이드바·모바일 목록이 같이 쓰는 진입점.
Future<Room?> showNewGroupDialog(
  BuildContext context,
  Session session, {
  required void Function(Room) onOpenRoom,
}) async {
  final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  final room = wide
      ? await showDialog<Room>(
          context: context,
          builder: (_) => NewGroupScreen(session: session, asDialog: true),
        )
      : await Navigator.of(context).push<Room>(
          MaterialPageRoute(builder: (_) => NewGroupScreen(session: session)),
        );
  if (room != null) onOpenRoom(room);
  return room;
}

/// "새 그룹채팅 만들기" — 새로운 토픽 생성하기와 같은 모양의 폼: 그룹 아이콘, 그룹 이름(선택), 설명
/// (선택), 멤버("멤버 선택" 창에서 고른다, 한 명 이상). "생성"하면 만든 방을 돌려주며 닫는다.
class NewGroupScreen extends StatefulWidget {
  final Session session;
  final bool asDialog;
  const NewGroupScreen({
    super.key,
    required this.session,
    this.asDialog = false,
  });

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _scroll = ScrollController();

  /// 고른 멤버(고른 순서) — "멤버 선택" 창에서 받아 온다.
  List<AppUser> _members = const [];

  /// 그룹 아이콘 — 이모지·사진을 안 고르면 이름 앞 2글자 이니셜, 이름까지 비면 멤버 사진 겹침. 배경색은
  /// 창을 열 때 무작위로 정해 두고 이니셜·이모지 모두에 쓴다.
  IconChoice _icon = IconChoice(color: randomGroupIconColor());

  bool _submitting = false;
  String? _membersError;
  String? _error;

  Session get _session => widget.session;
  Color get _iconColor => _icon.color ?? groupIconColors.first;
  String get _iconType => groupIconTypeOf(_icon, _name.text);

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _pickMembers() async {
    final picked = await showPickMembers(
      context,
      _session,
      initialSelected: [for (final u in _members) u.id],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _members = picked;
      if (picked.isNotEmpty) _membersError = null;
    });
  }

  void _removeMember(AppUser user) =>
      setState(() => _members = [..._members]..remove(user));

  /// "프로필 사진 편집"과 같은 편집 팝업 — 열지 않고 그냥 만들면 이름 앞 2글자 이니셜(이름이 없으면
  /// 멤버 사진)이 된다.
  Future<void> _editIcon() async {
    final result = await showGroupIconEditor(
      context,
      session: _session,
      initial: _icon,
      name: _name.text.trim(),
      members: _members,
    );
    if (result == null || !mounted) return;
    setState(
      () => _icon = IconChoice(
        emoji: result.emoji,
        color: result.color ?? _iconColor,
        photoUrl: result.photoUrl,
      ),
    );
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (_members.isEmpty) {
      setState(() => _membersError = tr('멤버를 한 명 이상 선택하세요.'));
      return;
    }
    final type = _iconType;
    setState(() {
      _submitting = true;
      _membersError = null;
      _error = null;
    });
    try {
      // 이름·설명은 Session이 앞뒤 공백을 떼고, 비어 있으면 보내지 않는다(이름 없으면 멤버 이름으로 보인다).
      final room = await _session.createGroup(
        name: _name.text,
        description: _description.text,
        memberIds: [for (final u in _members) u.id],
        iconType: type,
        iconEmoji: type == 'emoji' ? _icon.emoji : null,
        iconColor: type == 'emoji' || type == 'initial'
            ? colorToHex(_iconColor)
            : null,
        iconUrl: type == 'photo' ? _icon.photoUrl : null,
      );
      if (!mounted) return;
      Navigator.of(context).pop(room);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e is ApiException
            ? e.message
            : tr('그룹채팅을 만들지 못했습니다. 잠시 후 다시 시도하세요.');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 만드는 요청이 가는 동안은 Esc·뒤로 가기·바깥 누르기로 닫히지 않게 한다(취소 버튼도 잠겨 있다) —
    // 닫혀 버리면 방은 만들어지는데 열리지 않는다.
    return PopScope(canPop: !_submitting, child: _buildScreen(context));
  }

  Widget _buildScreen(BuildContext context) {
    final canCreate = _session.canCreateRooms;
    final form = _buildForm(context, canCreate);
    final actions = Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        const SizedBox(width: 8),
        FilledButton(
          key: const ValueKey('new-group-submit'),
          onPressed: _submitting || !canCreate ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(tr('생성')),
        ),
      ],
    );
    if (widget.asDialog) {
      return FloatingDialog(
        title: tr('새 그룹채팅 만들기'),
        maxWidth: 600,
        maxHeight: 820,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: MutedScrollbar(
                controller: _scroll,
                child: SingleChildScrollView(
                  controller: _scroll,
                  // 스크롤바(10px)가 입력칸을 덮지 않게 오른쪽을 비운다.
                  padding: const EdgeInsets.only(right: 16),
                  child: form,
                ),
              ),
            ),
            const SizedBox(height: 16),
            actions,
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr('새 그룹채팅 만들기'))),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: form,
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: actions,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForm(BuildContext context, bool canCreate) {
    final editable = canCreate && !_submitting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupFormLabel(tr('그룹 아이콘')),
        GroupIconField(
          editKey: const ValueKey('new-group-icon-edit'),
          preview: GroupIcon(
            type: _iconType,
            name: _name.text.trim(),
            emoji: _icon.emoji,
            color: _iconColor,
            photoUrl: _icon.photoUrl,
            members: _members,
            resolveUrl: _session.resolveUrl,
            radius: 32,
          ),
          hint: tr('그대로 두면 그룹 이름의 앞 두 글자로, 이름이 없으면 멤버 사진으로 보여요.'),
          onEdit: editable ? _editIcon : null,
        ),
        const SizedBox(height: 18),
        GroupFormLabel(tr('그룹 이름'), optional: true),
        TextField(
          key: const ValueKey('new-group-name'),
          controller: _name,
          enabled: canCreate,
          maxLength: groupNameMaxLength,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            hintText: tr('비워 두면 멤버 이름으로 표시돼요'),
            border: OutlineInputBorder(),
            isDense: true,
          ),
          // 아이콘 미리보기의 이니셜을 입력하는 대로 바꾼다.
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        GroupFormLabel(tr('설명'), optional: true),
        TextField(
          key: const ValueKey('new-group-description'),
          controller: _description,
          enabled: canCreate,
          maxLength: groupDescriptionMaxLength,
          minLines: 2,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: tr('어떤 이야기를 나누는 그룹인지 적어 주세요'),
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        _buildMembers(context, editable),
        if (!canCreate) ...[
          const SizedBox(height: 12),
          GroupFormNotice(
            key: ValueKey('new-group-guest-notice'),
            icon: Icons.lock_outline,
            text: tr('준회원은 그룹채팅을 만들 수 없습니다. 초대받은 방에서만 활동할 수 있습니다.'),
            error: true,
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          GroupFormNotice(
            key: const ValueKey('new-group-error'),
            icon: Icons.error_outline,
            text: _error!,
            error: true,
          ),
        ],
      ],
    );
  }

  /// "멤버" 칸 — 고른 멤버 칩(✕로 빼기)과 "멤버 선택" 버튼. 한 명도 없이 만들려고 하면 칸을 빨갛게
  /// 두르고 아래에 안내한다.
  Widget _buildMembers(BuildContext context, bool editable) {
    final theme = Theme.of(context);
    final error = _membersError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: GroupFormLabel(
                tr('멤버'),
                trailing: _members.isEmpty
                    ? null
                    : tr('{_members.length}명', {
                        '_members.length': _members.length,
                      }),
                padding: EdgeInsets.zero,
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              key: const ValueKey('new-group-pick-members'),
              onPressed: editable ? _pickMembers : null,
              icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
              label: Text(tr('멤버 선택')),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          key: const ValueKey('new-group-members'),
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            border: Border.all(
              color: error != null
                  ? theme.colorScheme.error
                  : theme.dividerColor,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: _members.isEmpty ? Alignment.center : Alignment.topLeft,
          child: _members.isEmpty
              ? Text(
                  tr('함께 대화할 멤버를 \'멤버 선택\'으로 골라 주세요.'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: theme.hintColor),
                )
              : Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final u in _members)
                      InputChip(
                        key: ValueKey('new-group-member-${u.id}'),
                        avatar: UserAvatar(
                          user: u,
                          resolveUrl: _session.resolveUrl,
                          radius: 12,
                        ),
                        label: Text(u.name),
                        onDeleted: editable ? () => _removeMember(u) : null,
                      ),
                  ],
                ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Text(
              error,
              style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }
}

/// 굵은 항목 이름 — [optional]이면 옆에 회색 "(선택)", [trailing]이 있으면 그 옆에 회색으로(인원 수 등).
/// 새로운 토픽 생성하기의 항목 이름과 같은 모양이고, 채팅 정보 변경도 같이 쓴다.
class GroupFormLabel extends StatelessWidget {
  final String text;
  final bool optional;
  final String? trailing;
  final EdgeInsetsGeometry padding;
  const GroupFormLabel(
    this.text, {
    super.key,
    this.optional = false,
    this.trailing,
    this.padding = const EdgeInsets.only(bottom: 8),
  });

  @override
  Widget build(BuildContext context) {
    final hint = TextStyle(fontSize: 12, color: Theme.of(context).hintColor);
    return Padding(
      padding: padding,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: text,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            if (optional) TextSpan(text: tr('  (선택)'), style: hint),
            if (trailing != null) TextSpan(text: '  $trailing', style: hint),
          ],
        ),
      ),
    );
  }
}

/// "그룹 아이콘" 칸 — 미리보기(사진기 배지를 누르면 편집) 옆에 안내와 [편집] 버튼. [onEdit]이 null이면
/// 미리보기와 안내만 보인다(읽기 전용·요청 중).
class GroupIconField extends StatelessWidget {
  final Widget preview;
  final String hint;
  final VoidCallback? onEdit;
  final Key? editKey;
  const GroupIconField({
    super.key,
    required this.preview,
    required this.hint,
    required this.onEdit,
    this.editKey,
  });

  @override
  Widget build(BuildContext context) {
    final onEdit = this.onEdit;
    return Row(
      children: [
        onEdit == null ? preview : CameraBadge(onTap: onEdit, child: preview),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                hint,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).hintColor,
                ),
              ),
              if (onEdit != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: editKey,
                  onPressed: onEdit,
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: Text(tr('편집')),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 폼 아래의 안내 상자 — [error]면 오류(빨강, 새로운 토픽 생성하기의 오류 상자와 같은 모양), 아니면
/// 옅은 강조색 바탕의 안내(토픽 정보 변경하기의 안내와 같은 모양).
class GroupFormNotice extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool error;
  const GroupFormNotice({
    super.key,
    required this.icon,
    required this.text,
    this.error = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: error
            ? scheme.errorContainer.withValues(alpha: 0.6)
            : scheme.primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: error ? 18 : 16,
            color: error ? scheme.error : scheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: error ? 13 : 12,
                color: error ? scheme.onErrorContainer : scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
