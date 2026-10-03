import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../services/api_client.dart' show ApiException;
import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/avatar_utils.dart' show colorToHex, parseHexColor;
import '../widgets/floating_dialog.dart';
import '../widgets/group_icon_picker.dart';
import '../widgets/icon_edit_dialog.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/room_options_menu.dart' show CloseWhenRoomRemoved;
import 'convert_to_topic_dialog.dart';
import 'home_screen.dart' show wideBreakpoint;
import 'new_group_dialog.dart'
    show GroupFormLabel, GroupFormNotice, GroupIconField;

/// 채팅 정보 변경(그룹채팅 아이콘·이름·설명) — 그룹채팅 ⋮ 메뉴의 "정보 변경"이 연다. 넓은 화면(PC)은
/// 떠 있는 창, 좁은 화면(모바일)은 전체 화면.
Future<void> showGroupSettingsDialog(
  BuildContext context,
  Session session,
  Room room,
) async {
  if (MediaQuery.sizeOf(context).width >= wideBreakpoint) {
    await showDialog<void>(
      context: context,
      builder: (_) =>
          GroupSettingsScreen(session: session, room: room, asDialog: true),
    );
  } else {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => GroupSettingsScreen(session: session, room: room),
      ),
    );
  }
}

/// 폼이 마지막으로 맞춘 방의 값 — 다른 멤버가 바꾸면 내가 손대지 않은 칸만 새 값으로 맞춘다.
/// [canEdit]·아이콘·멤버·별칭은 폼 칸이 아니지만, 바뀌면(준회원이 됨, 다른 멤버가 아이콘을 바꿈, 멤버가
/// 드나듦, 다른 기기에서 나에게만 이름을 바꿈) 이름 안내·미리보기·별칭 안내를 다시 그리려고 같이 본다.
typedef _GroupValues = ({
  String name,
  String description,
  String? iconType,
  String? iconEmoji,
  String? iconColor,
  String? iconUrl,
  bool canEdit,
  String members,
  String? alias,
});

/// "채팅 정보 변경" — 새 그룹채팅 만들기와 같은 칸(그룹 아이콘·그룹 채팅 이름·설명). 그 방 멤버인 정회원
/// 이상만 바꿀 수 있고(room.canEditGroupInfo, 서버가 다시 검사), 준회원에게는 읽기 전용으로 보인다.
/// "저장"은 바뀐 칸만 보내고 창을 닫는다. 방이 목록에서 사라지면(나가기·내보내짐) 스스로 닫힌다.
class GroupSettingsScreen extends StatefulWidget {
  final Session session;
  final Room room;
  final bool asDialog;
  const GroupSettingsScreen({
    super.key,
    required this.session,
    required this.room,
    this.asDialog = false,
  });

  @override
  State<GroupSettingsScreen> createState() => _GroupSettingsScreenState();
}

class _GroupSettingsScreenState extends State<GroupSettingsScreen>
    with CloseWhenRoomRemoved {
  @override
  Session get roomSession => widget.session;
  @override
  String get watchedRoomId => widget.room.id;

  late final _name = TextEditingController(text: _room.name ?? '');
  late final _description = TextEditingController(
    text: _room.description ?? '',
  );
  final _scroll = ScrollController();

  /// 창을 연 순간의 값으로 initState에서 바로 잡는다(토픽 정보 변경하기와 같은 이유 — 게으르게 잡으면
  /// 다른 멤버의 첫 변경을 놓친다).
  late _GroupValues _baseline;

  /// "그룹 아이콘 편집"에서 고른 아이콘 — null이면 손대지 않은 것(방의 지금 아이콘을 따른다).
  IconChoice? _editedIcon;

  /// 방에 배경색이 없을 때(멤버 사진) 이니셜·이모지로 바꾸면 쓸 색 — 창을 열 때 정해 둔다.
  final _fallbackColor = randomGroupIconColor();

  bool _saving = false;
  String? _error;

  Session get _session => widget.session;
  Room get _room => _session.roomById(widget.room.id) ?? widget.room;
  String get _myId => _session.userId ?? '';

  _GroupValues _valuesOf(Room room) => (
    name: room.name ?? '',
    description: room.description ?? '',
    iconType: room.iconType,
    iconEmoji: room.iconEmoji,
    iconColor: room.iconColor,
    iconUrl: room.iconUrl,
    canEdit: room.canEditGroupInfo(_session),
    // 멤버 목록은 방 정보가 올 때마다 새 리스트라 값(id·이름·아바타)으로 비교한다 — 사진 링크는
    // 올 때마다 새로 서명되므로 경로만.
    members: [
      for (final m in room.members)
        '${m.id}|${m.name}|${m.avatarType}|${m.avatarEmoji}|${m.avatarColor}|'
            '${Uri.tryParse(m.avatarUrl ?? '')?.path}',
    ].join('\n'),
    alias: room.customName,
  );

  @override
  void initState() {
    super.initState();
    _baseline = _valuesOf(_room);
    _session.addListener(_syncFromRoom);
  }

  @override
  void dispose() {
    _session.removeListener(_syncFromRoom);
    _name.dispose();
    _description.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 방 값이 바뀌었으면(다른 멤버의 변경·내 등급 변경) 손대지 않은 칸만 따라가게 하고 다시 그린다.
  /// 칸은 그 값이 실제로 바뀌었을 때만 덮는다 — 다른 값(사진 링크 재서명 등)만 바뀌었는데 덮으면, 이름
  /// 끝에 막 친 띄어쓰기가 지워지고 커서가 튄다.
  void _syncFromRoom() {
    if (!mounted) return;
    final now = _valuesOf(_room);
    if (now == _baseline) return;
    final before = _baseline;
    setState(() {
      if (now.name != before.name && _name.text.trim() == before.name) {
        _name.text = now.name;
      }
      if (now.description != before.description &&
          _description.text.trim() == before.description) {
        _description.text = now.description;
      }
      _baseline = now;
    });
  }

  bool get _canEdit => _room.canEditGroupInfo(_session);

  /// "토픽으로 전환" — 정회원 이상(토픽 생성이 허용된 사람)에게만 단추가 보인다. 전환되면 이 창은 그룹채팅용이라 닫는다
  /// (대화 화면은 그대로 열려 있고 방이 토픽으로 바뀐다).
  Future<void> _convertToTopic() async {
    final converted = await showConvertToTopicDialog(context, _session, _room);
    if (!converted || !mounted) return;
    showAppToast(context, '토픽으로 전환했습니다.');
    Navigator.of(context).pop();
  }

  /// 방의 지금 아이콘 모양 — 예전에 만든 그룹은 값이 없다(= 멤버 사진).
  String get _roomIconType => _room.iconType ?? 'members';

  IconChoice get _icon =>
      _editedIcon ??
      IconChoice(
        emoji: _room.iconEmoji,
        color: parseHexColor(_room.iconColor) ?? _fallbackColor,
        photoUrl: _room.iconUrl,
      );

  /// 저장했을 때의 아이콘 모양. 고른 아이콘이 있으면 새 그룹채팅 만들기와 같은 규칙(사진 > 이모지 >
  /// 이름이 있으면 이니셜, 없으면 멤버 사진)으로 정한다. 손대지 않았으면 지금 모양을 두되, 이니셜·멤버
  /// 사진은 이름이 생기거나 없어질 때만 따라 바꾼다 — 예전에 만든 "이름 있는 멤버 사진" 그룹이 설명만
  /// 고쳐도 이니셜로 바뀌지 않게.
  String get _iconType {
    final name = _name.text.trim();
    final edited = _editedIcon;
    if (edited != null) return groupIconTypeOf(edited, name);
    final current = _roomIconType;
    if (current != 'initial' && current != 'members') return current;
    final hadName = (_room.name ?? '').trim().isNotEmpty;
    if (name.isNotEmpty == hadName) return current;
    return name.isEmpty ? 'members' : 'initial';
  }

  bool get _nameChanged => _name.text.trim() != (_room.name ?? '');
  bool get _descriptionChanged =>
      _description.text.trim() != (_room.description ?? '');

  bool get _iconChanged {
    final type = _iconType;
    if (type != _roomIconType) return true;
    final icon = _editedIcon;
    if (icon == null) return false;
    final room = _room;
    final sameColor =
        colorToHex(icon.color ?? _fallbackColor).toUpperCase() ==
        (room.iconColor ?? '').toUpperCase();
    return switch (type) {
      'emoji' => icon.emoji != room.iconEmoji || !sameColor,
      'initial' => !sameColor,
      'photo' => !_samePhoto(icon.photoUrl, room.iconUrl),
      _ => false,
    };
  }

  /// 사진 링크는 방 정보를 받을 때마다 새로 서명되므로(쿼리만 달라진다) 경로로 비교한다.
  static bool _samePhoto(String? a, String? b) {
    if (a == null || b == null) return a == b;
    return Uri.tryParse(a)?.path == Uri.tryParse(b)?.path;
  }

  bool get _dirty => _nameChanged || _descriptionChanged || _iconChanged;

  Future<void> _editIcon() async {
    final result = await showGroupIconEditor(
      context,
      session: _session,
      initial: _icon,
      name: _name.text.trim(),
      members: _others,
    );
    if (result == null || !mounted) return;
    setState(
      () => _editedIcon = IconChoice(
        emoji: result.emoji,
        color: result.color ?? _icon.color ?? _fallbackColor,
        photoUrl: result.photoUrl,
      ),
    );
  }

  /// 멤버 사진 겹침에 쓸 멤버 — 나를 뺀 사람(나 혼자 남았으면 나).
  List<AppUser> get _others {
    final others = _room.members.where((m) => m.id != _myId).toList();
    return others.isEmpty ? _room.members : others;
  }

  Future<void> _save() async {
    if (_saving || !_dirty || !_canEdit) return;
    final room = _room;
    final nameChanged = _nameChanged;
    final descriptionChanged = _descriptionChanged;
    final iconChanged = _iconChanged;
    final type = _iconType;
    final icon = _icon;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // 바뀐 칸만 보낸다 — 서버가 바뀐 내용에 맞춰 안내 메시지를 남기므로. 이름·설명은 빈 문자열이면 지운다.
      await _session.updateGroupInfo(
        room,
        name: nameChanged ? _name.text.trim() : null,
        description: descriptionChanged ? _description.text.trim() : null,
        iconType: iconChanged ? type : null,
        iconEmoji: iconChanged && type == 'emoji' ? icon.emoji : null,
        iconColor: iconChanged && (type == 'emoji' || type == 'initial')
            ? colorToHex(icon.color ?? _fallbackColor)
            : null,
        iconUrl: iconChanged && type == 'photo' ? icon.photoUrl : null,
      );
      if (!mounted) return;
      showAppToast(context, '채팅 정보를 변경했습니다.');
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is ApiException
            ? e.message
            : '채팅 정보를 저장하지 못했습니다. 잠시 후 다시 시도하세요.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 저장 요청이 가는 동안은 닫히지 않게 한다(취소 버튼도 잠겨 있다).
    return PopScope(canPop: !_saving, child: _buildScreen(context));
  }

  Widget _buildScreen(BuildContext context) {
    final canEdit = _canEdit;
    final form = _buildForm(context, canEdit);
    final actions = Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(canEdit ? '취소' : '닫기'),
        ),
        const SizedBox(width: 8),
        FilledButton(
          key: const ValueKey('group-settings-save'),
          onPressed: _saving || !canEdit || !_dirty ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('저장'),
        ),
      ],
    );
    if (widget.asDialog) {
      return FloatingDialog(
        title: '채팅 정보 변경',
        maxWidth: 600,
        maxHeight: 720,
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
      appBar: AppBar(title: const Text('채팅 정보 변경')),
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

  Widget _buildForm(BuildContext context, bool canEdit) {
    final room = _room;
    final name = _name.text.trim();
    final defaultName = room.memberNames(_myId);
    final alias = room.customName?.trim();
    final icon = _icon;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!canEdit) ...[
          const GroupFormNotice(
            key: ValueKey('group-settings-guest-notice'),
            icon: Icons.lock_outline,
            text: groupInfoGuestNotice,
          ),
          const SizedBox(height: 16),
        ],
        const GroupFormLabel('그룹 아이콘'),
        GroupIconField(
          editKey: const ValueKey('group-settings-icon-edit'),
          preview: GroupIcon(
            type: _iconType,
            // 이름이 비었는데 이니셜이면(예전 값) 목록처럼 멤버 이름의 앞 두 글자를 보여준다.
            name: name.isEmpty ? defaultName : name,
            emoji: icon.emoji,
            color: icon.color ?? _fallbackColor,
            photoUrl: icon.photoUrl,
            members: _others,
            resolveUrl: _session.resolveUrl,
            radius: 32,
          ),
          hint: canEdit
              ? '이모지나 사진으로 바꾸거나, 초기화해서 이름 앞 두 글자(이름이 없으면 멤버 사진)로 되돌릴 수 있어요.'
              : '그룹 멤버 모두에게 이 아이콘으로 보여요.',
          onEdit: canEdit && !_saving ? _editIcon : null,
        ),
        const SizedBox(height: 18),
        const GroupFormLabel('그룹 채팅 이름', optional: true),
        TextField(
          key: const ValueKey('group-settings-name'),
          controller: _name,
          enabled: canEdit,
          maxLength: groupNameMaxLength,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            // 비워 두면 어떻게 보이는지 — 나를 뺀 멤버 이름(목록의 기본 이름).
            hintText: defaultName,
            helperText: '비워 두면 멤버 이름으로 표시돼요',
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          // 아이콘 미리보기의 이니셜·저장 버튼을 입력하는 대로 바꾼다.
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _save(),
        ),
        if (alias != null && alias.isNotEmpty) ...[
          const SizedBox(height: 8),
          GroupFormNotice(
            key: const ValueKey('group-settings-alias-note'),
            icon: Icons.info_outline,
            text: "내 목록에서는 '$alias'(으)로 보여요 — ⋮ › 나에게만 이름 변경에서 바꿀 수 있어요",
          ),
        ],
        const SizedBox(height: 12),
        const GroupFormLabel('설명', optional: true),
        TextField(
          key: const ValueKey('group-settings-description'),
          controller: _description,
          enabled: canEdit,
          maxLength: groupDescriptionMaxLength,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: '어떤 이야기를 나누는 그룹인지 적어 주세요',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (_) => setState(() {}),
        ),
        if (_room.canConvertToTopic(_session)) ...[
          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 16),
          const GroupFormLabel('토픽으로 전환'),
          Text(
            '더 많은 멤버와 이야기하고 싶다면 이 그룹채팅을 토픽으로 바꿀 수 있어요. 대화 내용은 그대로 유지돼요.',
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('group-settings-convert'),
              onPressed: _saving ? null : _convertToTopic,
              icon: const Icon(Icons.tag, size: 18),
              label: const Text('토픽으로 전환'),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          GroupFormNotice(
            key: const ValueKey('group-settings-error'),
            icon: Icons.error_outline,
            text: _error!,
            error: true,
          ),
        ],
      ],
    );
  }
}
