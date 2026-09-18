import 'package:flutter/material.dart';

/// 프로필 카드의 "팀"/"직책" 칸 — 다른 멤버의 프로필(member_profile_dialog.dart)과 내
/// 프로필(my_profile_dialog.dart) 둘 다 같은 모양을 쓴다. [onEdit]이 있으면 우측에 직책
/// 수정용 연필 버튼이 뜬다(팀 소속은 이 카드에서 바꿀 수 없다).
class OrgSection extends StatelessWidget {
  final List<String>? teamNames; // null이면 아직 불러오는 중.
  final String? position;
  final VoidCallback? onEdit;
  const OrgSection({
    super.key,
    required this.teamNames,
    required this.position,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final teamText = teamNames == null
        ? '불러오는 중…'
        : (teamNames!.isEmpty ? '없음' : teamNames!.join(', '));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.groups_outlined, size: 18, color: hint),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '팀',
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: hint),
                  ),
                  Text(
                    teamText,
                    style: teamNames == null || teamNames!.isEmpty
                        ? TextStyle(color: hint)
                        : const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '직책',
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: hint),
                  ),
                  Text(
                    position?.isNotEmpty == true ? position! : '아직 등록되지 않았습니다',
                    style: position?.isNotEmpty == true
                        ? const TextStyle(fontWeight: FontWeight.w500)
                        : TextStyle(color: hint),
                  ),
                ],
              ),
            ),
            if (onEdit != null)
              IconButton(
                tooltip: '직책 수정',
                icon: const Icon(Icons.edit_outlined, size: 18),
                onPressed: onEdit,
              ),
          ],
        ),
      ),
    );
  }
}
