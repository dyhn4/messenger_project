import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/session.dart';
import '../widgets/email_address_field.dart';
import '../widgets/my_avatar.dart';

/// 삼선(햄버거) 메뉴의 프로필 행을 누르면 뜨는 플로팅 카드: 아바타 + 아이디/이름/이메일 + 로그아웃.
/// 아바타를 누르면 사진 편집 화면으로, 이름/이메일을 누르면 바로 수정할 수 있다.
class MyProfileDialog extends StatelessWidget {
  final Session session;
  const MyProfileDialog({super.key, required this.session});

  Future<void> _editAvatar(BuildContext context) async {
    await showDialog(
      context: context,
      builder: (_) => AvatarEditDialog(session: session),
    );
  }

  Future<void> _editName(BuildContext context) async {
    final value = await _promptEdit(
      context,
      title: '이름 변경',
      initialValue: session.name ?? '',
    );
    if (value == null || value.isEmpty) return;
    try {
      await session.updateProfile(name: value);
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('실패: $e')));
    }
  }

  Future<void> _editEmail(BuildContext context) async {
    await showDialog(
      context: context,
      builder: (_) => _EditEmailDialog(session: session),
    );
  }

  Future<void> _changePassword(BuildContext context) async {
    await showDialog<bool>(
      context: context,
      builder: (_) => _ChangePasswordDialog(session: session),
    );
  }

  Future<void> _logout(BuildContext context) async {
    Navigator.of(context).pop();
    await session.logout();
    if (context.mounted)
      Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _withdraw(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _WithdrawConfirmDialog(session: session),
    );
    if (confirmed == true && context.mounted) {
      Navigator.of(context).pop(); // 프로필 카드 닫기
      if (context.mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('회원 탈퇴'),
            content: const Text('회원탈퇴가 완료되었습니다.'),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('확인'),
              ),
            ],
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: ListenableBuilder(
          listenable: session,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 90,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(16),
                  ),
                ),
                alignment: Alignment.bottomCenter,
                child: Transform.translate(
                  offset: const Offset(0, 30),
                  child: GestureDetector(
                    onTap: () => _editAvatar(context),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        MyAvatar(session: session, radius: 32),
                        Positioned(
                          right: -2,
                          bottom: -2,
                          child: CircleAvatar(
                            radius: 11,
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.primary,
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
                ),
              ),
              const SizedBox(height: 44),
              _ProfileInfoRow(
                icon: Icons.badge_outlined,
                label: '아이디',
                value: session.username ?? '',
              ),
              _ProfileInfoRow(
                icon: Icons.person_outline,
                label: '이름',
                value: session.name ?? '',
                onTap: () => _editName(context),
              ),
              _ProfileInfoRow(
                icon: Icons.mail_outline,
                label: '이메일',
                value: '',
                onTap: () => _editEmail(context),
              ),
              _ProfileInfoRow(
                icon: Icons.lock_outline,
                label: '비밀번호',
                value: '',
                onTap: () => _changePassword(context),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: TextButton.icon(
                    onPressed: () => _logout(context),
                    style: TextButton.styleFrom(
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      foregroundColor: Colors.redAccent,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: const Icon(Icons.logout, color: Colors.redAccent),
                    label: const Text(
                      '로그아웃',
                      style: TextStyle(
                        color: Colors.redAccent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: TextButton(
                  onPressed: () => _withdraw(context),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).hintColor,
                  ),
                  child: const Text(
                    '회원 탈퇴',
                    style: TextStyle(decoration: TextDecoration.underline),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "회원 탈퇴" 확인 다이얼로그. 로그아웃과 달리 되돌릴 수 없는 작업이라 비밀번호를 한 번 더
/// 받아서 본인 확인을 한다. 성공하면 true를 반환하고(호출부가 로그인 화면으로 돌려보낸다),
/// 취소하거나 실패한 채로 닫으면 null/false를 반환한다.
class _WithdrawConfirmDialog extends StatefulWidget {
  final Session session;
  const _WithdrawConfirmDialog({required this.session});

  @override
  State<_WithdrawConfirmDialog> createState() => _WithdrawConfirmDialogState();
}

class _WithdrawConfirmDialogState extends State<_WithdrawConfirmDialog> {
  final _password = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_password.text.isEmpty) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.session.withdraw(_password.text);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('회원 탈퇴'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '탈퇴하면 로그인할 수 없고, 프로필 정보는 익명화됩니다. 이 작업은 되돌릴 수 없습니다.\n'
            '계속하려면 비밀번호를 입력하세요.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            autofocus: true,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '비밀번호',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _submitting
              ? null
              : () => Navigator.of(context).pop(false),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('탈퇴하기'),
        ),
      ],
    );
  }
}

/// "비밀번호 변경" 다이얼로그. 현재 비밀번호로 본인 확인 후 새 비밀번호(+확인)를 받는다.
/// 성공하면 서버가 새 토큰을 내려줘서 이 기기는 로그아웃 없이 그대로 이어진다.
class _ChangePasswordDialog extends StatefulWidget {
  final Session session;
  const _ChangePasswordDialog({required this.session});

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _current = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirm = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _newPassword.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_current.text.isEmpty || _newPassword.text.isEmpty) return;
    if (_newPassword.text != _confirm.text) {
      setState(() => _error = '새 비밀번호가 서로 다릅니다.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.session.changePassword(
        currentPassword: _current.text,
        newPassword: _newPassword.text,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('비밀번호 변경'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _current,
            autofocus: true,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '현재 비밀번호',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _newPassword,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '새 비밀번호',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirm,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '새 비밀번호 확인',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('변경하기'),
        ),
      ],
    );
  }
}

/// "이메일 변경" 다이얼로그. 이메일은 아이디/비밀번호 찾기에 쓰이는 계정 복구 수단이라
/// 비밀번호 변경과 같은 정책으로, 현재 비밀번호를 확인한 뒤에만 새 이메일을 받는다. 새
/// 이메일 입력칸은 회원가입 폼과 같은 형식(로컬 파트 + '@' + 도메인)을 쓴다.
class _EditEmailDialog extends StatefulWidget {
  final Session session;
  const _EditEmailDialog({required this.session});

  @override
  State<_EditEmailDialog> createState() => _EditEmailDialogState();
}

class _EditEmailDialogState extends State<_EditEmailDialog> {
  final _password = TextEditingController();
  String _email = '';
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_password.text.isEmpty || _email.trim().isEmpty) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.session.updateProfile(
        email: _email.trim(),
        currentPassword: _password.text,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('이메일 변경'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _password,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '비밀번호 확인',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            EmailAddressField(onChanged: (v) => _email = v),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('변경하기'),
        ),
      ],
    );
  }
}

/// 프로필 카드의 정보 한 줄(아이디/이름/이메일). onTap이 있으면 눌러서 바로 수정할 수 있다.
class _ProfileInfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;
  const _ProfileInfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 18, color: Theme.of(context).hintColor),
            const SizedBox(width: 10),
            SizedBox(
              width: 52,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).hintColor,
                ),
              ),
            ),
            Expanded(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            if (onTap != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '수정',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 이름 수정용 간단한 한 줄 입력 다이얼로그.
Future<String?> _promptEdit(
  BuildContext context, {
  required String title,
  required String initialValue,
}) {
  final controller = TextEditingController(text: initialValue);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(controller: controller, autofocus: true),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: const Text('확인'),
        ),
      ],
    ),
  );
}

/// "프로필 사진 편집" 화면: 큰 미리보기 + 초기화/캐릭터 선택하기/사진 올리기.
class AvatarEditDialog extends StatefulWidget {
  final Session session;
  const AvatarEditDialog({super.key, required this.session});

  @override
  State<AvatarEditDialog> createState() => _AvatarEditDialogState();
}

class _AvatarEditDialogState extends State<AvatarEditDialog> {
  bool _busy = false;

  Future<void> _reset() async {
    setState(() => _busy = true);
    try {
      await widget.session.updateAvatar(avatarType: 'initial');
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('실패: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickCharacter() async {
    await showDialog(
      context: context,
      builder: (_) => CharacterPickerDialog(session: widget.session),
    );
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
      await widget.session.updateAvatar(
        avatarType: 'photo',
        avatarUrl: uploaded.url,
      );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('업로드 실패: $e')));
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
          child: ListenableBuilder(
            listenable: widget.session,
            builder: (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '프로필 사진 편집',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
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
                      child: Center(
                        child: MyAvatar(session: widget.session, radius: 80),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '프로필 사진은 640x640px 해상도를 권장합니다.',
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
                        onPressed: _pickCharacter,
                        child: const Text('캐릭터 선택하기'),
                      ),
                      TextButton(
                        onPressed: _uploadPhoto,
                        child: const Text('사진 올리기'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

const _characterEmojis = [
  '🧑‍🦰',
  '👮',
  '🧑‍🌾',
  '👩‍🦰',
  '🧑‍✈️',
  '👩‍💼',
  '🧑‍💼',
  '👩‍🦱',
  '🧔',
  '👩‍🎤',
  '🧑‍🎨',
  '🧑‍🔬',
];

const _characterColors = [
  Color(0xFF9AA6B2),
  Color(0xFF4C6EF5),
  Color(0xFF15AABF),
  Color(0xFFFAB005),
  Color(0xFFFF6B35),
  Color(0xFF37B24D),
  Color(0xFF0CA678),
  Color(0xFFE64980),
  Color(0xFF9775FA),
  Color(0xFF8D6E63),
];

/// "캐릭터 선택하기" 화면: 이모지 12개 중 하나 + 배경색 10개 중 하나를 골라 확인.
class CharacterPickerDialog extends StatefulWidget {
  final Session session;
  const CharacterPickerDialog({super.key, required this.session});

  @override
  State<CharacterPickerDialog> createState() => _CharacterPickerDialogState();
}

class _CharacterPickerDialogState extends State<CharacterPickerDialog> {
  late String _emoji = widget.session.avatarEmoji ?? _characterEmojis.first;
  late Color _color =
      parseHexColor(widget.session.avatarColor) ?? _characterColors.first;
  bool _saving = false;

  Future<void> _confirm() async {
    setState(() => _saving = true);
    try {
      await widget.session.updateAvatar(
        avatarType: 'character',
        avatarEmoji: _emoji,
        avatarColor: colorToHex(_color),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('실패: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

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
                '프로필 사진 편집',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                '캐릭터 선택하기',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).hintColor,
                ),
              ),
              const SizedBox(height: 16),
              CircleAvatar(
                radius: 44,
                backgroundColor: _color,
                child: Text(_emoji, style: const TextStyle(fontSize: 40)),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '캐릭터',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final e in _characterEmojis)
                    _PickCircle(
                      selected: e == _emoji,
                      onTap: () => setState(() => _emoji = e),
                      child: CircleAvatar(
                        radius: 22,
                        backgroundColor: _color,
                        child: Text(e, style: const TextStyle(fontSize: 20)),
                      ),
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
                  for (final c in _characterColors)
                    _PickCircle(
                      selected: c.toARGB32() == _color.toARGB32(),
                      onTap: () => setState(() => _color = c),
                      child: CircleAvatar(
                        radius: 14,
                        backgroundColor: c,
                        child: c.toARGB32() == _color.toARGB32()
                            ? const Icon(
                                Icons.check,
                                size: 16,
                                color: Colors.white,
                              )
                            : null,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: const Text('닫기'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _saving ? null : _confirm,
                      child: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('확인'),
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

class _PickCircle extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  final Widget child;
  const _PickCircle({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
            width: 2,
          ),
        ),
        child: child,
      ),
    );
  }
}
