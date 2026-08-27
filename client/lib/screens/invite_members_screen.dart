import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../services/session.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/user_avatar.dart';

class InviteMembersScreen extends StatefulWidget {
  final Session session;
  final Room room;
  final bool asDialog;
  const InviteMembersScreen({
    super.key,
    required this.session,
    required this.room,
    this.asDialog = false,
  });

  @override
  State<InviteMembersScreen> createState() => _InviteMembersScreenState();
}

class _InviteMembersScreenState extends State<InviteMembersScreen> {
  List<AppUser>? _users;
  String? _error;
  final _selected = <String>{};
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final users = await widget.session.api!.fetchUsers();
      final memberIds = widget.room.members.map((m) => m.id).toSet();
      users.removeWhere((u) => memberIds.contains(u.id));
      if (!mounted) return;
      setState(() => _users = users);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _submit() async {
    if (_selected.isEmpty) return;
    setState(() => _submitting = true);
    try {
      await widget.session.inviteMembers(widget.room.id, _selected.toList());
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('초대 실패: $e')));
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
        : _users!.isEmpty
        ? const Center(child: Text('초대할 수 있는 유저가 없습니다.'))
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Expanded(
                child: ListView(
                  shrinkWrap: widget.asDialog,
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
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _submitting
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: const Text('취소'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _selected.isEmpty || _submitting
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
                            : const Text('초대하기'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );

    if (widget.asDialog) {
      return FloatingDialog(title: '멤버 초대', child: body);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('멤버 초대')),
      body: body,
    );
  }
}
