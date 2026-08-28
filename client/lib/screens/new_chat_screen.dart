import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../services/session.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final users = await widget.session.api!.fetchUsers();
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
              if (_selected.length > 1)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: TextField(
                    controller: _groupName,
                    decoration: const InputDecoration(
                      labelText: '그룹 이름 (선택, 비워두면 멤버 이름으로 표시)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
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
