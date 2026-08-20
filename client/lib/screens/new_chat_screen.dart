import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../services/session.dart';
import '../widgets/floating_dialog.dart';
import 'chat_screen.dart';

class NewChatScreen extends StatefulWidget {
  final Session session;
  final bool asDialog;
  const NewChatScreen({super.key, required this.session, this.asDialog = false});

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  List<AppUser>? _users;
  String? _error;
  final _selected = <String>{};
  final _groupName = TextEditingController();
  bool _submitting = false;

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
          MaterialPageRoute(builder: (_) => ChatScreen(session: widget.session, room: room)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('생성 실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
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
                            leading: CircleAvatar(
                              child: Text(user.username.isNotEmpty ? user.username[0] : '?'),
                            ),
                            title: Text(user.username),
                            selected: _selected.contains(user.id),
                            selectedTileColor: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4),
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
                      child: Text('선택된 멤버 ${_selected.length}', style: Theme.of(context).textTheme.labelLarge),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final id in _selected)
                            Chip(
                              avatar: CircleAvatar(
                                child: Text(
                                  _users!.firstWhere((u) => u.id == id).username.isNotEmpty
                                      ? _users!.firstWhere((u) => u.id == id).username[0]
                                      : '?',
                                ),
                              ),
                              label: Text(_users!.firstWhere((u) => u.id == id).username),
                              onDeleted: () => setState(() => _selected.remove(id)),
                            ),
                        ],
                      ),
                    ),
                  ],
                  if (_selected.length > 1)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                            onPressed: _submitting ? null : () => Navigator.of(context).pop(),
                            child: const Text('취소'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: _selected.isEmpty || _submitting ? null : _submit,
                            child: _submitting
                                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Text('대화 시작하기'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );

    if (widget.asDialog) {
      return FloatingDialog(title: '새 대화', child: body);
    }
    return Scaffold(appBar: AppBar(title: const Text('새 대화')), body: body);
  }
}
