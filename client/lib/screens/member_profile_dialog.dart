import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../services/session.dart';
import '../widgets/user_avatar.dart';

/// 다른 사용자의 프로필 플로팅 카드: 프로필 사진 + 이름 + 1:1 메시지 시작.
/// 아이디/이메일은 아이디·비밀번호 찾기에 쓰이는 개인정보라 다른 사람에게는 보여주지 않는다.
/// 멤버 패널 카드, 채팅방 메시지의 다른 사람 아바타/이름을 눌렀을 때 공용으로 쓴다.
class MemberProfileDialog extends StatefulWidget {
  final Session session;
  final AppUser user;
  const MemberProfileDialog({super.key, required this.session, required this.user});

  @override
  State<MemberProfileDialog> createState() => _MemberProfileDialogState();
}

class _MemberProfileDialogState extends State<MemberProfileDialog> {
  bool _starting = false;

  Future<void> _startDm() async {
    setState(() => _starting = true);
    try {
      final room = await widget.session.startDm(widget.user.id);
      if (!mounted) return;
      Navigator.of(context).pop(room);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('대화 시작 실패: $e')));
      setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 90,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              ),
              alignment: Alignment.bottomCenter,
              child: Transform.translate(
                offset: const Offset(0, 30),
                child: UserAvatar(user: user, resolveUrl: widget.session.resolveUrl, radius: 32),
              ),
            ),
            const SizedBox(height: 40),
            Text(
              user.name,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton.icon(
                onPressed: _starting ? null : _startDm,
                icon: _starting
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.chat_bubble_outline),
                label: const Text('1:1 메시지'),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
