import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../services/session.dart';
import '../widgets/avatar_utils.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';

/// 그룹 아이콘 선택지 — team_settings_dialog.dart의 팀 이모지(🏢💼🚀💡🛠️📊🎨🧪📣🤝🌱⭐,
/// 업무 느낌)와 안 겹치게 사람/취향 느낌으로 골랐다. 팀은 사각(둥근모서리) 아이콘이라, 원형인
/// 그룹 아바타(room_avatar.dart)와도 모양으로 구분된다.
const _groupEmojis = [
  '👥',
  '💬',
  '🎉',
  '🍀',
  '🎈',
  '🌟',
  '☕',
  '🎵',
  '🏖️',
  '🎮',
  '📷',
  '🐾',
];

const _groupColors = [
  Color(0xFF9575CD),
  Color(0xFF4C6EF5),
  Color(0xFF15AABF),
  Color(0xFF37B24D),
  Color(0xFFFAB005),
  Color(0xFFFF6B35),
  Color(0xFFE64980),
  Color(0xFF8D6E63),
];

class NewChatScreen extends StatefulWidget {
  final Session session;
  final bool asDialog;
  const NewChatScreen({
    super.key,
    required this.session,
    this.asDialog = false,
  });

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  List<AppUser>? _users;
  String? _error;
  final _selected = <String>{};
  final _groupName = TextEditingController();
  bool _submitting = false;
  bool _submittingSecret = false;

  // 그룹 아이콘 — 'members'(기본, 멤버 사진 두 개를 겹쳐 보여주는 기존 동작 그대로) |
  // 'initial'(그룹 이름 첫 글자) | 'emoji'(_iconEmoji/_iconColor).
  String _iconType = 'members';
  String? _iconEmoji;
  Color? _iconColor;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final users = await widget.session.fetchTeamMembers();
      users.removeWhere((u) => u.id == widget.session.userId);
      if (!mounted) return;
      setState(() => _users = users);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _groupName.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_selected.isEmpty) return;
    setState(() => _submitting = true);
    try {
      final groupName = _groupName.text.trim();
      final room = _selected.length == 1
          ? await widget.session.startDm(_selected.first)
          : await widget.session.createGroup(
              name: groupName.isEmpty ? null : groupName,
              memberIds: _selected.toList(),
              iconType: _iconType,
              iconEmoji: _iconType == 'emoji' ? _iconEmoji : null,
              iconColor: _iconType == 'emoji' && _iconColor != null
                  ? colorToHex(_iconColor!)
                  : null,
            );
      if (!mounted) return;
      if (widget.asDialog) {
        Navigator.of(context).pop(room);
      } else {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => ChatScreen(session: widget.session, room: room),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('생성 실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 프로필 카드의 "캐릭터 선택하기"(my_profile_dialog.dart)와 같은 모양의 팝업을 띄운다 —
  /// 이 팝업을 열지 않고 그냥 만들면 _iconType이 초기값 'members'(멤버 사진 겹침)로 남는다.
  Future<void> _pickGroupIcon() async {
    final result = await showDialog<(String, String, Color)>(
      context: context,
      builder: (_) => _GroupIconPickerDialog(
        previewName: _groupName.text.trim(),
        initialMode: _iconType == 'emoji' ? 'emoji' : 'initial',
        initialEmoji: _iconEmoji,
        initialColor: _iconColor,
      ),
    );
    if (result == null || !mounted) return;
    final (mode, emoji, color) = result;
    setState(() {
      _iconType = mode;
      _iconEmoji = mode == 'emoji' ? emoji : null;
      _iconColor = mode == 'emoji' ? color : null;
    });
  }

  /// 상대 1명만 선택했을 때만 가능(비밀 대화는 1:1 전용) — member_profile_dialog.dart의
  /// _startSecretChat과 동일하게 별도 dmKey의 방을 새로 만들거나 기존 진행중인 방으로 이동한다.
  Future<void> _submitSecret() async {
    if (_selected.length != 1) return;
    setState(() => _submittingSecret = true);
    try {
      final room = await widget.session.startSecretChat(_selected.first);
      if (!mounted) return;
      if (widget.asDialog) {
        Navigator.of(context).pop(room);
      } else {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => ChatScreen(session: widget.session, room: room),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('비밀 대화 시작 실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _submittingSecret = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = _error != null
        ? Center(child: Text(_error!))
        : _users == null
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    for (final user in _users!)
                      ListTile(
                        leading: UserAvatar(
                          user: user,
                          resolveUrl: widget.session.resolveUrl,
                        ),
                        title: Text(user.name),
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
                ),
              ),
              if (_selected.isNotEmpty) ...[
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    '선택된 멤버 ${_selected.length}',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final id in _selected)
                        Chip(
                          avatar: UserAvatar(
                            user: _users!.firstWhere((u) => u.id == id),
                            resolveUrl: widget.session.resolveUrl,
                          ),
                          label: Text(
                            _users!.firstWhere((u) => u.id == id).name,
                          ),
                          onDeleted: () => setState(() => _selected.remove(id)),
                        ),
                    ],
                  ),
                ),
              ],
              if (_selected.length > 1) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // 아이콘 미리보기를 누르면 바로 선택 팝업이 뜬다(내 프로필 카드의 아바타
                      // 클릭-편집과 같은 방식) — 예전엔 이름 칸 위아래로 "그룹 아이콘
                      // 선택하기" 버튼이 한 줄 통째로 차지해서 공간을 낭비했다.
                      GestureDetector(
                        onTap: _pickGroupIcon,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            if (_iconType == 'members')
                              CircleAvatar(
                                radius: 24,
                                backgroundColor: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                                child: Icon(
                                  Icons.groups_outlined,
                                  color: Theme.of(context).hintColor,
                                ),
                              )
                            else
                              AvatarView(
                                username: _groupName.text.trim().isEmpty
                                    ? '?'
                                    : _groupName.text.trim(),
                                avatarType: _iconType == 'emoji'
                                    ? 'character'
                                    : 'initial',
                                avatarEmoji: _iconEmoji,
                                avatarColor: _iconColor != null
                                    ? colorToHex(_iconColor!)
                                    : null,
                                radius: 24,
                              ),
                            Positioned(
                              right: -2,
                              bottom: -2,
                              child: CircleAvatar(
                                radius: 9,
                                backgroundColor: Theme.of(
                                  context,
                                ).colorScheme.primary,
                                child: const Icon(
                                  Icons.edit,
                                  size: 11,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _groupName,
                          decoration: const InputDecoration(
                            labelText: '그룹 이름 (선택, 비워두면 멤버 이름으로 표시)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_iconType != 'members')
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => setState(() {
                          _iconType = 'members';
                          _iconEmoji = null;
                          _iconColor = null;
                        }),
                        child: const Text('기본으로'),
                      ),
                    ),
                  ),
                const SizedBox(height: 4),
              ],
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                        ),
                        onPressed: _submitting || _submittingSecret
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: const Text('취소', maxLines: 1),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        // 활성화됐을 때만 초록으로 강조하고, 비활성화 상태의 배경/글자색은
                        // 직접 지정하지 않고 비워둬서 '대화 시작하기'(평범한 FilledButton)의
                        // 비활성화 스타일(테마 기본값)을 그대로 물려받게 한다.
                        style:
                            FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                            ).copyWith(
                              backgroundColor:
                                  WidgetStateProperty.resolveWith<Color?>(
                                    (states) =>
                                        states.contains(WidgetState.disabled)
                                        ? null
                                        : Colors.green,
                                  ),
                              foregroundColor:
                                  WidgetStateProperty.resolveWith<Color?>(
                                    (states) =>
                                        states.contains(WidgetState.disabled)
                                        ? null
                                        : Colors.white,
                                  ),
                            ),
                        onPressed:
                            _selected.length != 1 ||
                                _submitting ||
                                _submittingSecret
                            ? null
                            : _submitSecret,
                        icon: _submittingSecret
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.lock_outline, size: 18),
                        label: const Text(
                          '비밀 대화 시작',
                          maxLines: 1,
                          overflow: TextOverflow.visible,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        onPressed:
                            _selected.isEmpty ||
                                _submitting ||
                                _submittingSecret
                            ? null
                            : _submit,
                        child: _submitting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('대화 시작하기', maxLines: 1),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );

    if (widget.asDialog) {
      // 하단에 버튼 3개(취소/비밀 대화 시작/대화 시작하기)가 한 줄에 들어가려면 기본
      // 480px로는 좁아서 줄바꿈이 생긴다 — 여유 있게 넓힌다.
      return FloatingDialog(title: '새 대화', maxWidth: 480, child: body);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('새 대화')),
      body: body,
    );
  }
}

/// "그룹 아이콘 선택하기" 팝업 — my_profile_dialog.dart의 "캐릭터 선택하기"(CharacterPickerDialog)와
/// 같은 모양이다. 그룹 이름 첫 글자를 쓰는 "이니셜"과, 이모지+배경색을 고르는 "이미지" 중 하나를
/// 고른다. "취소"로 닫으면 null을 돌려주고(호출부가 아무것도 안 바꿈), "확인"을 눌러야 반영된다.
class _GroupIconPickerDialog extends StatefulWidget {
  final String previewName;
  final String initialMode; // 'initial' | 'emoji'
  final String? initialEmoji;
  final Color? initialColor;
  const _GroupIconPickerDialog({
    required this.previewName,
    required this.initialMode,
    this.initialEmoji,
    this.initialColor,
  });

  @override
  State<_GroupIconPickerDialog> createState() => _GroupIconPickerDialogState();
}

class _GroupIconPickerDialogState extends State<_GroupIconPickerDialog> {
  late String _mode = widget.initialMode;
  late String _emoji = widget.initialEmoji ?? _groupEmojis.first;
  late Color _color = widget.initialColor ?? _groupColors.first;

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
                '그룹 아이콘 선택하기',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              AvatarView(
                username: widget.previewName.isEmpty ? '?' : widget.previewName,
                avatarType: _mode == 'emoji' ? 'character' : 'initial',
                avatarEmoji: _mode == 'emoji' ? _emoji : null,
                avatarColor: _mode == 'emoji' ? colorToHex(_color) : null,
                radius: 44,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('이니셜'),
                    selected: _mode == 'initial',
                    onSelected: (_) => setState(() => _mode = 'initial'),
                  ),
                  ChoiceChip(
                    label: const Text('이미지'),
                    selected: _mode == 'emoji',
                    onSelected: (_) => setState(() => _mode = 'emoji'),
                  ),
                ],
              ),
              if (_mode == 'emoji') ...[
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '이미지',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final e in _groupEmojis)
                      _EmojiChoice(
                        selected: e == _emoji,
                        onTap: () => setState(() => _emoji = e),
                        child: Text(e, style: const TextStyle(fontSize: 20)),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '색상',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final c in _groupColors)
                      _ColorChoice(
                        color: c,
                        selected: c.toARGB32() == _color.toARGB32(),
                        onTap: () => setState(() => _color = c),
                      ),
                  ],
                ),
              ],
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
                          Navigator.of(context).pop((_mode, _emoji, _color)),
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

/// team_settings_dialog.dart의 같은 이름 위젯과 모양이 동일하다(선택 시 테두리 강조되는
/// 정사각 탭 영역) — 그쪽은 private이라 그대로 가져다 쓸 수 없어 똑같이 하나 더 둔다.
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
