import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/session.dart';

/// 팀·그룹채팅 아이콘의 선택 상태 — 사진이 있으면 사진, 없으면 이모지, 둘 다 없으면 이름 앞
/// 2글자 이니셜. [color]는 이니셜·이모지의 배경색이다.
class IconChoice {
  final String? emoji;
  final Color? color;

  /// 서명된 /files/ 링크(업로드 응답의 signedUrl 또는 서버가 내려준 값).
  final String? photoUrl;
  const IconChoice({this.emoji, this.color, this.photoUrl});
}

/// 아이콘 오른쪽 아래에 사진기 배지를 얹어 "눌러서 바꿀 수 있다"는 걸 보여준다 — 내 프로필
/// 카드의 아바타(my_profile_dialog.dart)와 같은 모양이다.
class CameraBadge extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  const CameraBadge({super.key, required this.child, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            child,
            Positioned(
              right: -2,
              bottom: -2,
              child: CircleAvatar(
                radius: 11,
                backgroundColor: Theme.of(context).colorScheme.primary,
                child: const Icon(
                  Icons.camera_alt,
                  size: 13,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "프로필 사진 편집"(my_profile_dialog.dart의 AvatarEditDialog)과 같은 모양의 팀·그룹 아이콘
/// 편집 팝업 — 큰 미리보기 + 초기화/아이콘 선택하기/사진 올리기. "아이콘 선택하기"는 팀·그룹이
/// 각자 고유한 이모지 목록으로 여는 [pickIcon]을 부른다. 초기화는 이니셜로 되돌린다(배경색은
/// 유지). 여기서는 고르기만 하고, "확인"을 누르면 고른 값을, "취소"면 null을 돌려준다 — 실제
/// 저장은 호출한 화면이 한다(팀 설정의 "저장", 새 대화의 "대화 시작하기").
Future<IconChoice?> showIconEditDialog(
  BuildContext context, {
  required String title,
  required Session session,
  required IconChoice initial,
  required Widget Function(IconChoice choice, double size) preview,
  required Future<IconChoice?> Function(IconChoice current) pickIcon,
}) {
  return showDialog<IconChoice>(
    context: context,
    builder: (_) => _IconEditDialog(
      title: title,
      session: session,
      initial: initial,
      preview: preview,
      pickIcon: pickIcon,
    ),
  );
}

class _IconEditDialog extends StatefulWidget {
  final String title;
  final Session session;
  final IconChoice initial;
  final Widget Function(IconChoice choice, double size) preview;
  final Future<IconChoice?> Function(IconChoice current) pickIcon;
  const _IconEditDialog({
    required this.title,
    required this.session,
    required this.initial,
    required this.preview,
    required this.pickIcon,
  });

  @override
  State<_IconEditDialog> createState() => _IconEditDialogState();
}

class _IconEditDialogState extends State<_IconEditDialog> {
  late IconChoice _choice = widget.initial;
  bool _busy = false;

  void _reset() => setState(() => _choice = IconChoice(color: _choice.color));

  Future<void> _pickIcon() async {
    final picked = await widget.pickIcon(_choice);
    if (picked != null && mounted) setState(() => _choice = picked);
  }

  Future<void> _uploadPhoto() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (picked == null) return;
    setState(() => _busy = true);
    try {
      final uploaded = await widget.session.api!.uploadFile(File(picked.path));
      if (!mounted) return;
      setState(
        () => _choice = IconChoice(
          emoji: _choice.emoji,
          color: _choice.color,
          photoUrl: uploaded.signedUrl ?? uploaded.url,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('업로드 실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              AspectRatio(
                aspectRatio: 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: ColoredBox(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    child: Center(child: widget.preview(_choice, 160)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '사진은 정사각형 이미지를 권장합니다.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).hintColor,
                ),
              ),
              const SizedBox(height: 16),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: CircularProgressIndicator(),
                )
              else
                Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    TextButton(onPressed: _reset, child: const Text('초기화')),
                    TextButton(
                      onPressed: _pickIcon,
                      child: const Text('아이콘 선택하기'),
                    ),
                    TextButton(
                      onPressed: _uploadPhoto,
                      child: const Text('사진 올리기'),
                    ),
                  ],
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: const Text('취소'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).pop(_choice),
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
