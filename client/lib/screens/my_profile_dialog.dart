import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/team.dart';
import '../services/session.dart';
import '../widgets/email_address_field.dart';
import '../widgets/my_avatar.dart';
import '../widgets/org_section.dart';

/// 삼선(햄버거) 메뉴의 프로필 행을 누르면 뜨는 플로팅 카드: 아바타 + 이름 + 등급 + 팀/직책
/// (member_profile_dialog.dart의 다른 사람 프로필 카드와 같은 모양) + 개인정보 설정 + 로그아웃.
/// 아바타를 누르면 사진 편집 화면으로, 이름 옆 연필을 누르면 바로 수정할 수 있다. 아이디/
/// 이메일/비밀번호/회원 탈퇴는 "개인정보 설정"(비밀번호 확인 후 진입)으로 옮겼다.
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
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('실패: $e')));
      }
    }
  }

  /// 지금 보고 있는 팀 기준 내 직책 — account 단위면 전 팀에 같은 값, team 단위면 팀마다
  /// 다를 수 있어 지금 팀(currentTeam) 것을 찾는다(못 찾으면 첫 번째 팀 값으로 대체).
  /// member_profile_dialog.dart의 OrgSection과 같은 모양으로 보여주기 위해 하나로 좁힌다.
  String? _currentPosition() {
    if (session.orgScope == 'account') return session.myPosition;
    final currentId = session.currentTeam?.id;
    final matches = session.myTeamPositions.where((t) => t.teamId == currentId);
    if (matches.isNotEmpty) return matches.first.position;
    return session.myTeamPositions.isNotEmpty
        ? session.myTeamPositions.first.position
        : null;
  }

  /// "개인정보 설정" — 비밀번호를 한 번 더 확인해야 열 수 있다(아이디/이메일/비밀번호 변경/
  /// 회원 탈퇴처럼 민감한 작업을 모아둔 곳이라서). 확인된 비밀번호는 그 안의 이메일 변경에서
  /// 다시 물어보지 않고 그대로 재사용한다(비밀번호 변경/회원 탈퇴는 각각 별도로 다시 받는다 —
  /// 그 자체가 더 민감한 작업이라서).
  Future<void> _openPersonalInfo(BuildContext context) async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => _VerifyPasswordDialog(session: session),
    );
    if (password == null || !context.mounted) return;
    final withdrawn = await showDialog<bool>(
      context: context,
      builder: (_) =>
          PersonalInfoDialog(session: session, verifiedPassword: password),
    );
    if (withdrawn == true && context.mounted) {
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

  Future<void> _logout(BuildContext context) async {
    await session.logout();
    // 이 버튼이 push된 화면 위에 있을 수도 있으니, 로그인 화면이 보이도록
    // 루트까지 화면 스택을 걷어낸다.
    if (context.mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
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
          builder: (context, _) {
            final hint = Theme.of(context).hintColor;
            final role = session.accountRole;
            final roleText = session.currentTeam?.isOwner == true
                ? '${role.label} · 이 팀의 소유자'
                : role.label;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 아바타가 배너 아래쪽으로 튀어나오게(겹쳐 보이게) 하는 부분. Positioned+
                // Clip.none만으로는 부족하다 — Stack 자신의 size는 여전히 겹치지 않는 자식(배너
                // Container, 90) 기준으로 90만 되고, RenderBox.hitTest는 어떤 위젯이든 자기
                // size.contains(position)를 먼저 통과해야 자식을 검사하므로, Stack 자체가 90만큼만
                // "차지"하는 한 그 아래로 튀어나온 아바타는 Positioned를 써도 여전히 탭이 안 먹힌다
                // (신고된 "아래쪽 반원 클릭 안 됨" 버그 — 1차 수정에서 놓친 부분). SizedBox로
                // Stack 자체의 크기를 아바타 전체를 포함하는 높이로 명시해야 한다.
                SizedBox(
                  height: 124, // 배너 90 + 아바타가 튀어나온 만큼(56~120) + 여유
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          height: 90,
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(16),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 56,
                        child: Center(
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
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        session.name ?? '',
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 2),
                    InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () => _editName(context),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(Icons.edit_outlined, size: 16, color: hint),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  roleText,
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: hint),
                ),
                const SizedBox(height: 12),
                OrgSection(
                  teamNames: session.teams.map((t) => t.name).toList(),
                  position: _currentPosition(),
                  // 내 직책은 소유자·관리자도 스스로 바꾸지 않는다(자기 서열을 스스로 올리는
                  // 걸 막기 위함) — "회원"/"멤버" 탭에서 남이 바꿔줘야 한다.
                  onEdit: null,
                ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: () => _openPersonalInfo(context),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.manage_accounts_outlined,
                          size: 18,
                          color: hint,
                        ),
                        const SizedBox(width: 10),
                        const Expanded(child: Text('개인정보 설정')),
                        Icon(Icons.chevron_right, color: hint),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
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
              ],
            );
          },
        ),
      ),
    );
  }
}

/// "개인정보 설정" 진입 시 비밀번호를 한 번 확인하는 다이얼로그. 맞으면 그 비밀번호 문자열
/// 그대로 pop해서 돌려주고(PersonalInfoDialog의 이메일 변경이 다시 묻지 않고 재사용한다),
/// 취소하거나 실패한 채로 닫으면 null.
class _VerifyPasswordDialog extends StatefulWidget {
  final Session session;
  const _VerifyPasswordDialog({required this.session});

  @override
  State<_VerifyPasswordDialog> createState() => _VerifyPasswordDialogState();
}

class _VerifyPasswordDialogState extends State<_VerifyPasswordDialog> {
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
      await widget.session.verifyPassword(_password.text);
      if (mounted) Navigator.of(context).pop(_password.text);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('비밀번호 확인'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('개인정보 설정을 열려면 비밀번호를 다시 확인해야 합니다.'),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              autofocus: true,
              obscureText: true,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: '비밀번호',
                border: OutlineInputBorder(),
              ),
            ),
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
              : const Text('확인'),
        ),
      ],
    );
  }
}

/// "개인정보" 팝업 — 아이디(읽기전용) / 이메일 관리 / 비밀번호 변경 / 회원 탈퇴를 한 곳에
/// 모아, 각 항목을 눌러 그 자리에서 아래로 펼쳐 처리한다(따로 새 창을 띄우지 않는다).
/// 회원 탈퇴가 실제로 완료되면 true를 pop해서 돌려준다 — 호출부(my_profile_dialog의
/// _openPersonalInfo)가 이 카드도, 프로필 카드도 닫고 로그인 화면으로 돌려보낸다.
class PersonalInfoDialog extends StatefulWidget {
  final Session session;
  final String verifiedPassword;
  const PersonalInfoDialog({
    super.key,
    required this.session,
    required this.verifiedPassword,
  });

  @override
  State<PersonalInfoDialog> createState() => _PersonalInfoDialogState();
}

enum _InfoSection { none, email, password, withdraw }

class _PersonalInfoDialogState extends State<PersonalInfoDialog> {
  _InfoSection _expanded = _InfoSection.none;

  void _toggle(_InfoSection section) {
    setState(() => _expanded = _expanded == section ? _InfoSection.none : section);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 640),
        child: ListenableBuilder(
          listenable: widget.session,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '개인정보',
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _StaticInfoRow(
                        icon: Icons.badge_outlined,
                        label: '아이디',
                        value: widget.session.username ?? '',
                      ),
                      const Divider(height: 1),
                      _ExpandableEntry(
                        icon: Icons.mail_outline,
                        label: '이메일 관리',
                        collapsedValue: widget.session.email?.isNotEmpty == true
                            ? widget.session.email!
                            : '등록된 이메일이 없습니다',
                        expanded: _expanded == _InfoSection.email,
                        onToggle: () => _toggle(_InfoSection.email),
                        child: _EmailEditPanel(
                          session: widget.session,
                          verifiedPassword: widget.verifiedPassword,
                          onDone: () => _toggle(_InfoSection.email),
                        ),
                      ),
                      const Divider(height: 1),
                      _ExpandableEntry(
                        icon: Icons.lock_outline,
                        label: '비밀번호 변경',
                        collapsedValue: null,
                        expanded: _expanded == _InfoSection.password,
                        onToggle: () => _toggle(_InfoSection.password),
                        child: _PasswordChangePanel(
                          session: widget.session,
                          onDone: () => _toggle(_InfoSection.password),
                        ),
                      ),
                      const Divider(height: 1),
                      _ExpandableEntry(
                        icon: Icons.person_remove_outlined,
                        iconColor: Colors.redAccent,
                        label: '회원 탈퇴',
                        labelColor: Colors.redAccent,
                        collapsedValue: null,
                        expanded: _expanded == _InfoSection.withdraw,
                        onToggle: () => _toggle(_InfoSection.withdraw),
                        child: _WithdrawPanel(
                          session: widget.session,
                          onCancel: () => _toggle(_InfoSection.withdraw),
                          onWithdrawn: () => Navigator.of(context).pop(true),
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
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

/// 항목 하나(아이콘+라벨+오른쪽 화살표) — 누르면 [child]가 그 아래로 펼쳐지거나 접힌다.
class _ExpandableEntry extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String label;
  final Color? labelColor;
  final String? collapsedValue;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;
  const _ExpandableEntry({
    required this.icon,
    this.iconColor,
    required this.label,
    this.labelColor,
    required this.collapsedValue,
    required this.expanded,
    required this.onToggle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              children: [
                Icon(icon, size: 18, color: iconColor ?? hint),
                const SizedBox(width: 10),
                // 라벨 칸 폭을 _StaticInfoRow(아이디)와 똑같이 고정해서, 값이 라벨 길이와
                // 무관하게 항상 같은 자리(대략 가운데쯤)에서 시작하고 서로 왼쪽 정렬로
                // 맞춰지게 한다 — 값이 오른쪽 끝에 붙어 있으면 읽기 불편하다는 피드백 반영.
                SizedBox(
                  width: _infoLabelWidth,
                  child: Text(
                    label,
                    style: labelColor != null
                        ? TextStyle(color: labelColor)
                        : null,
                  ),
                ),
                Expanded(
                  child: collapsedValue != null
                      ? Text(
                          collapsedValue!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: hint),
                        )
                      : const SizedBox.shrink(),
                ),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(Icons.keyboard_arrow_down, color: hint),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          child: expanded
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  child: child,
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// 펼칠 내용이 없는 읽기전용 한 줄(아이디용) — 꺾쇠 없음.
/// 항목 행들의 "라벨" 칸 폭 — 라벨 길이가 제각각이어도(아이디/이메일 관리/비밀번호 변경)
/// 값이 항상 같은 자리에서 시작하도록 _StaticInfoRow와 _ExpandableEntry가 같이 쓴다.
const _infoLabelWidth = 100.0;

class _StaticInfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _StaticInfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: [
          Icon(icon, size: 18, color: hint),
          const SizedBox(width: 10),
          SizedBox(width: _infoLabelWidth, child: Text(label)),
          Expanded(child: Text(value, style: TextStyle(color: hint))),
        ],
      ),
    );
  }
}

/// "이메일 관리" 펼침 내용 — 현재 이메일 표시 + 새 이메일 입력. 개인정보 팝업에 들어올 때 이미
/// 비밀번호를 확인했으므로 다시 묻지 않고 [verifiedPassword]를 그대로 서버에 보낸다.
class _EmailEditPanel extends StatefulWidget {
  final Session session;
  final String verifiedPassword;
  final VoidCallback onDone;
  const _EmailEditPanel({
    required this.session,
    required this.verifiedPassword,
    required this.onDone,
  });

  @override
  State<_EmailEditPanel> createState() => _EmailEditPanelState();
}

class _EmailEditPanelState extends State<_EmailEditPanel> {
  String _email = '';
  bool _submitting = false;
  String? _error;

  Future<void> _submit() async {
    if (_email.trim().isEmpty) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.session.updateProfile(
        email: _email.trim(),
        currentPassword: widget.verifiedPassword,
      );
      if (mounted) widget.onDone();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '현재 이메일',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: hint),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            widget.session.email?.isNotEmpty == true
                ? widget.session.email!
                : '등록된 이메일이 없습니다',
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '새 이메일',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: hint),
        ),
        const SizedBox(height: 4),
        EmailAddressField(onChanged: (v) => _email = v),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: const TextStyle(color: Colors.redAccent)),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _submitting ? null : widget.onDone,
                child: const Text('취소'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _submitting ? null : _submit,
                child: _submitting
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
    );
  }
}

/// "비밀번호 변경" 펼침 내용 — 현재 비밀번호로 다시 본인 확인을 받는다(이 항목 자체가
/// 개인정보 팝업 진입 때보다 더 민감한 작업이라 별도로 한 번 더 받는다).
class _PasswordChangePanel extends StatefulWidget {
  final Session session;
  final VoidCallback onDone;
  const _PasswordChangePanel({required this.session, required this.onDone});

  @override
  State<_PasswordChangePanel> createState() => _PasswordChangePanelState();
}

class _PasswordChangePanelState extends State<_PasswordChangePanel> {
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
      if (mounted) widget.onDone();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
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
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _submitting ? null : widget.onDone,
                child: const Text('취소'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _submitting ? null : _submit,
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('변경하기'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// "회원 탈퇴" 펼침 내용 — 비밀번호를 한 번 더 입력하고, 유의사항을 읽었다는 체크박스에
/// 동의해야 "회원 탈퇴" 버튼이 눌린다. 실제로 탈퇴가 끝나면 [onWithdrawn]을 불러서
/// PersonalInfoDialog가 true를 pop하게 한다(호출부가 프로필 카드까지 닫고 로그인 화면으로
/// 돌려보낸다).
class _WithdrawPanel extends StatefulWidget {
  final Session session;
  final VoidCallback onCancel;
  final VoidCallback onWithdrawn;
  const _WithdrawPanel({
    required this.session,
    required this.onCancel,
    required this.onWithdrawn,
  });

  @override
  State<_WithdrawPanel> createState() => _WithdrawPanelState();
}

class _WithdrawPanelState extends State<_WithdrawPanel> {
  final _password = TextEditingController();
  bool _agreed = false;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_password.text.isEmpty || !_agreed) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.session.withdraw(_password.text);
      widget.onWithdrawn();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final canSubmit = _password.text.isNotEmpty && _agreed && !_submitting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _password,
          autofocus: true,
          obscureText: true,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: '비밀번호',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '탈퇴 시 유의사항',
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                '· 탈퇴 후에는 이 아이디로 다시 로그인할 수 없습니다.\n'
                '· 보낸 메시지·첨부파일 등 활동 기록은 삭제되지 않고, 작성자만 익명 처리됩니다.\n'
                '· 속한 팀·대화방에서 자동으로 나가며, 이 작업은 되돌릴 수 없습니다.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: hint),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        InkWell(
          onTap: () => setState(() => _agreed = !_agreed),
          child: Row(
            children: [
              Checkbox(
                value: _agreed,
                onChanged: (v) => setState(() => _agreed = v ?? false),
              ),
              const Expanded(
                child: Text('위 유의사항을 모두 확인하였으며 회원 탈퇴에 동의합니다.'),
              ),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 4),
          Text(_error!, style: const TextStyle(color: Colors.redAccent)),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _submitting ? null : widget.onCancel,
                child: const Text('취소'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: canSubmit ? _submit : null,
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
                    : const Text('회원 탈퇴'),
              ),
            ),
          ],
        ),
      ],
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
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('실패: $e')));
      }
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
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('실패: $e')));
      }
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
