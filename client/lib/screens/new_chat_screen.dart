import 'dart:math';

import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../services/session.dart';
import '../widgets/avatar_utils.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/icon_edit_dialog.dart';
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
  late final _groupNameFocus = FocusNode()
    ..addListener(() => setState(() {}));
  bool _submitting = false;
  bool _submittingSecret = false;

  // 그룹 아이콘 — 이모지를 안 고르면(null) 그룹 이름 앞 2글자 이니셜이고, 이름까지 비어 있으면
  // 예전처럼 멤버 사진 두 개를 겹쳐 보여준다('members'). 배경색은 창을 열 때 무작위로 정해두고
  // 이니셜·이모지 모두에 쓴다.
  String? _iconEmoji;
  Color _iconColor = _groupColors[Random().nextInt(_groupColors.length)];

  /// 올린 사진(업로드 응답의 서명된 링크) — 있으면 이모지·이니셜보다 우선한다.
  String? _iconUrl;

  String get _iconType => _iconUrl != null
      ? 'photo'
      : _iconEmoji != null
      ? 'emoji'
      : _groupName.text.trim().isEmpty
      ? 'members'
      : 'initial';

  IconChoice get _iconChoice =>
      IconChoice(emoji: _iconEmoji, color: _iconColor, photoUrl: _iconUrl);

  Widget _groupIcon(IconChoice icon, double radius) => _GroupIcon(
    name: _groupName.text.trim(),
    emoji: icon.emoji,
    color: icon.color ?? _iconColor,
    photoUrl: icon.photoUrl,
    resolveUrl: widget.session.resolveUrl,
    radius: radius,
  );

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
    _groupNameFocus.dispose();
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
              iconEmoji: _iconEmoji,
              iconColor: _iconType == 'members' ? null : colorToHex(_iconColor),
              iconUrl: _iconUrl,
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

  /// "프로필 사진 편집"과 같은 편집 팝업(초기화/아이콘 선택하기/사진 올리기)을 띄운다 — 이
  /// 팝업을 열지 않고 그냥 만들면 이름 앞 2글자 이니셜(이름이 없으면 멤버 사진)이 된다.
  /// "아이콘 선택하기"는 그룹 고유의 이모지 목록(_GroupIconPickerDialog)을 연다.
  Future<void> _editGroupIcon() async {
    final result = await showIconEditDialog(
      context,
      title: '그룹 아이콘 편집',
      session: widget.session,
      initial: _iconChoice,
      preview: (icon, size) => _groupIcon(icon, size / 2),
      pickIcon: (current) async {
        final picked = await showDialog<(String?, Color)>(
          context: context,
          builder: (_) => _GroupIconPickerDialog(
            previewName: _groupName.text.trim(),
            initialEmoji: current.emoji,
            initialColor: current.color ?? _iconColor,
          ),
        );
        if (picked == null) return null;
        final (emoji, color) = picked;
        return IconChoice(emoji: emoji, color: color);
      },
    );
    if (result == null || !mounted) return;
    setState(() {
      _iconEmoji = result.emoji;
      _iconColor = result.color ?? _iconColor;
      _iconUrl = result.photoUrl;
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
                // 팀 설정의 "팀 아이콘"/"팀 이름"과 같은 배치 — 제목 한 줄 아래에 아이콘과
                // 이름 입력칸을 나란히 두고, 입력칸은 아이콘 높이의 가운데에 맞춘다.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          SizedBox(
                            width: 64,
                            child: Text(
                              '그룹 아이콘',
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: Text(
                              '그룹 이름',
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          // 아이콘의 사진기 배지를 누르면 편집 팝업이 뜬다(내 프로필 카드의
                          // 아바타 클릭-편집과 같은 방식).
                          SizedBox(
                            width: 64,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: CameraBadge(
                                onTap: _editGroupIcon,
                                child: _groupIcon(_iconChoice, 28),
                              ),
                            ),
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: TextField(
                              controller: _groupName,
                              focusNode: _groupNameFocus,
                              decoration: InputDecoration(
                                // 입력칸을 누르면(포커스) 안내 문구를 숨긴다.
                                hintText: _groupNameFocus.hasFocus
                                    ? null
                                    : '멤버 이름으로 표시',
                                border: const OutlineInputBorder(),
                                isDense: true,
                              ),
                              // 왼쪽 아이콘 미리보기의 이니셜을 입력하는 대로 갱신한다.
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                        ],
                      ),
                    ],
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

/// 그룹 아이콘 한 개 — [photoUrl]이 있으면 그 사진, [emoji]가 있으면 [color] 배경의 이모지,
/// 없으면 [name] 앞 2글자 이니셜, 이름까지 비어 있으면 멤버 사진 겹침('members')을 뜻하는
/// 회색 사람 아이콘.
class _GroupIcon extends StatelessWidget {
  final String name;
  final String? emoji;
  final Color color;
  final String? photoUrl;
  final String Function(String relative)? resolveUrl;
  final double radius;
  const _GroupIcon({
    required this.name,
    required this.emoji,
    required this.color,
    this.photoUrl,
    this.resolveUrl,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    if (photoUrl != null && resolveUrl != null) {
      return CircleAvatar(
        radius: radius,
        backgroundImage: NetworkImage(resolveUrl!(photoUrl!)),
      );
    }
    if (emoji != null) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: color,
        child: Text(emoji!, style: TextStyle(fontSize: radius)),
      );
    }
    if (name.isEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(
          Icons.groups_outlined,
          size: radius,
          color: Theme.of(context).hintColor,
        ),
      );
    }
    return InitialsAvatar(name: name, color: color, radius: radius);
  }
}

/// "그룹 아이콘 선택하기" 팝업 — my_profile_dialog.dart의 "캐릭터 선택하기"와 같은 모양이다.
/// 아이콘 첫 칸은 그룹 이름 앞 2글자 이니셜(팀 설정의 팀 아이콘과 같은 방식)이고, 배경색은
/// 이니셜·이모지 모두에 적용된다. "확인"을 누르면 (이모지(이니셜이면 null), 배경색)을 돌려준다.
class _GroupIconPickerDialog extends StatefulWidget {
  final String previewName;
  final String? initialEmoji;
  final Color initialColor;
  const _GroupIconPickerDialog({
    required this.previewName,
    required this.initialEmoji,
    required this.initialColor,
  });

  @override
  State<_GroupIconPickerDialog> createState() => _GroupIconPickerDialogState();
}

class _GroupIconPickerDialogState extends State<_GroupIconPickerDialog> {
  late String? _emoji = widget.initialEmoji;
  late Color _color = widget.initialColor;

  Widget _icon(String? emoji, double radius) => _GroupIcon(
    name: widget.previewName,
    emoji: emoji,
    color: _color,
    radius: radius,
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
                '그룹 아이콘 선택하기',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              _icon(_emoji, 44),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '아이콘',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final e in <String?>[null, ..._groupEmojis])
                    _EmojiChoice(
                      selected: e == _emoji,
                      onTap: () => setState(() => _emoji = e),
                      child: _icon(e, 16),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '배경색',
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
