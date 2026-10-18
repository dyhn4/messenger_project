import 'dart:math';

import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../services/session.dart';
import 'avatar_utils.dart';
import 'icon_edit_dialog.dart';
import 'user_avatar.dart';
import '../l10n/tr.dart';

/// 그룹 아이콘 선택지 — team_settings_dialog.dart의 팀 이모지(🏢💼🚀💡🛠️📊🎨🧪📣🤝🌱⭐,
/// 업무 느낌)와 안 겹치게 사람/취향 느낌으로 골랐다. 팀은 사각(둥근모서리) 아이콘이라, 원형인
/// 그룹 아바타(room_avatar.dart)와도 모양으로 구분된다.
const groupIconEmojis = [
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

const groupIconColors = [
  Color(0xFF9575CD),
  Color(0xFF4C6EF5),
  Color(0xFF15AABF),
  Color(0xFF37B24D),
  Color(0xFFFAB005),
  Color(0xFFFF6B35),
  Color(0xFFE64980),
  Color(0xFF8D6E63),
];

/// 새 그룹 아이콘의 배경색 — 창을 열 때 무작위로 하나 정해 두고 이니셜·이모지 모두에 쓴다.
Color randomGroupIconColor([Random? random]) =>
    groupIconColors[(random ?? Random()).nextInt(groupIconColors.length)];

/// 고른 아이콘([choice])과 그룹 이름으로 정해지는 아이콘 모양(서버 rooms.icon_type) — 사진 > 이모지 >
/// 이름이 있으면 이름 앞 2글자 이니셜, 이름까지 비었으면 멤버 사진 겹침('members').
String groupIconTypeOf(IconChoice choice, String name) {
  if (choice.photoUrl != null) return 'photo';
  if (choice.emoji != null) return 'emoji';
  return name.trim().isEmpty ? 'members' : 'initial';
}

/// 그룹 아이콘 한 개 — [type]에 따라 사진, [color] 배경의 이모지, [name] 앞 2글자 이니셜, 또는
/// 멤버 사진 겹침('members' — [members]가 비었으면 회색 사람 아이콘)을 그린다. 새 그룹채팅 만들기와
/// 채팅 정보 변경의 미리보기용이고, 실제 목록·헤더의 그룹 아바타는 room_avatar.dart가 그린다.
class GroupIcon extends StatelessWidget {
  /// 'members' | 'initial' | 'emoji' | 'photo'([groupIconTypeOf] 참고).
  final String type;
  final String name;
  final String? emoji;
  final Color color;
  final String? photoUrl;

  /// 'members'일 때 겹쳐 보여줄 멤버(나 빼고, 앞의 두 명만 쓴다).
  final List<AppUser> members;
  final String Function(String relative)? resolveUrl;
  final double radius;
  const GroupIcon({
    super.key,
    required this.type,
    required this.name,
    this.emoji,
    required this.color,
    this.photoUrl,
    this.members = const [],
    this.resolveUrl,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    final url = photoUrl;
    if (type == 'photo' && url != null) {
      return CircleAvatar(
        radius: radius,
        backgroundImage: NetworkImage(resolveUrl?.call(url) ?? url),
      );
    }
    final emoji = this.emoji;
    if (type == 'emoji' && emoji != null) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: color,
        child: Text(emoji, style: TextStyle(fontSize: radius)),
      );
    }
    if (type == 'initial' && name.trim().isNotEmpty) {
      return InitialsAvatar(name: name, color: color, radius: radius);
    }
    if (members.isNotEmpty) {
      return _MembersIcon(
        members: members.take(2).toList(),
        resolveUrl: resolveUrl,
        radius: radius,
      );
    }
    final theme = Theme.of(context);
    return CircleAvatar(
      radius: radius,
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      child: Icon(Icons.groups_outlined, size: radius, color: theme.hintColor),
    );
  }
}

/// 멤버 사진 두 장을 살짝 겹친 모양(room_avatar.dart의 그룹 아바타)을 지름 크기의 정사각형 안에
/// 맞춰 그린다 — 다른 아이콘 모양과 자리 크기가 같아서 옆 칸이 흔들리지 않는다.
class _MembersIcon extends StatelessWidget {
  final List<AppUser> members;
  final String Function(String relative)? resolveUrl;
  final double radius;
  const _MembersIcon({
    required this.members,
    required this.resolveUrl,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    final size = radius * 2;
    if (members.length == 1) {
      return UserAvatar(
        user: members.single,
        resolveUrl: resolveUrl,
        radius: radius,
      );
    }
    final small = radius * 0.66;
    final ring = Theme.of(context).colorScheme.surface;
    Widget avatar(AppUser user) => CircleAvatar(
      radius: small,
      backgroundColor: ring,
      child: UserAvatar(
        user: user,
        resolveUrl: resolveUrl,
        radius: small - 1.5,
      ),
    );
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Positioned(left: 0, top: radius - small, child: avatar(members[0])),
          Positioned(right: 0, top: radius - small, child: avatar(members[1])),
        ],
      ),
    );
  }
}

/// "프로필 사진 편집"과 같은 그룹 아이콘 편집 팝업(초기화 / 아이콘 선택하기 / 사진 올리기)을 연다 —
/// 새 그룹채팅 만들기와 채팅 정보 변경이 같이 쓴다. 미리보기는 [name]으로 이니셜을, [members]로 멤버
/// 사진 겹침을 그린다. "아이콘 선택하기"는 그룹 고유의 이모지 목록([GroupIconPickerDialog])을 연다.
/// 고르기만 하고 "확인"이면 고른 값, "취소"면 null을 돌려준다 — 저장은 부른 창이 한다.
Future<IconChoice?> showGroupIconEditor(
  BuildContext context, {
  required Session session,
  required IconChoice initial,
  required String name,
  List<AppUser> members = const [],
}) {
  final fallbackColor = initial.color ?? groupIconColors.first;
  Widget icon(IconChoice choice, double radius) => GroupIcon(
    type: groupIconTypeOf(choice, name),
    name: name,
    emoji: choice.emoji,
    color: choice.color ?? fallbackColor,
    photoUrl: choice.photoUrl,
    members: members,
    resolveUrl: session.resolveUrl,
    radius: radius,
  );
  return showIconEditDialog(
    context,
    title: tr('그룹 아이콘 편집'),
    session: session,
    initial: initial,
    preview: (choice, size) => icon(choice, size / 2),
    pickIcon: (current) async {
      final picked = await showDialog<(String?, Color)>(
        context: context,
        builder: (_) => GroupIconPickerDialog(
          previewName: name,
          initialEmoji: current.emoji,
          initialColor: current.color ?? fallbackColor,
          members: members,
          resolveUrl: session.resolveUrl,
        ),
      );
      if (picked == null) return null;
      final (emoji, color) = picked;
      return IconChoice(emoji: emoji, color: color);
    },
  );
}

/// "그룹 아이콘 선택하기" 팝업 — my_profile_dialog.dart의 "캐릭터 선택하기"와 같은 모양이다.
/// 아이콘 첫 칸은 그룹 이름 앞 2글자 이니셜(이름이 없으면 멤버 사진 — 팀 설정의 팀 아이콘과 같은
/// 방식)이고, 배경색은 이니셜·이모지 모두에 적용된다. "확인"을 누르면 (이모지(이니셜이면 null),
/// 배경색)을 돌려준다.
class GroupIconPickerDialog extends StatefulWidget {
  final String previewName;
  final String? initialEmoji;
  final Color initialColor;
  final List<AppUser> members;
  final String Function(String relative)? resolveUrl;
  const GroupIconPickerDialog({
    super.key,
    required this.previewName,
    required this.initialEmoji,
    required this.initialColor,
    this.members = const [],
    this.resolveUrl,
  });

  @override
  State<GroupIconPickerDialog> createState() => _GroupIconPickerDialogState();
}

class _GroupIconPickerDialogState extends State<GroupIconPickerDialog> {
  late String? _emoji = widget.initialEmoji;
  late Color _color = widget.initialColor;

  Widget _icon(String? emoji, double radius) => GroupIcon(
    type: groupIconTypeOf(IconChoice(emoji: emoji), widget.previewName),
    name: widget.previewName,
    emoji: emoji,
    color: _color,
    members: widget.members,
    resolveUrl: widget.resolveUrl,
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
                tr('그룹 아이콘 선택하기'),
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
                  tr('아이콘'),
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final e in <String?>[null, ...groupIconEmojis])
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
                  tr('배경색'),
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final c in groupIconColors)
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
                      child: Text(tr('취소')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () =>
                          Navigator.of(context).pop((_emoji, _color)),
                      child: Text(tr('확인')),
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
