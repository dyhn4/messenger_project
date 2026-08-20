import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../services/session.dart';

class InviteMembersScreen extends StatefulWidget {
  final Session session;
  final Room room;
  const InviteMembersScreen({super.key, required this.session, required this.room});

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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('초대 실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('멤버 초대')),
      body: _error != null
          ? Center(child: Text(_error!))
          : _users == null
              ? const Center(child: CircularProgressIndicator())
              : _users!.isEmpty
                  ? const Center(child: Text('초대할 수 있는 유저가 없습니다.'))
                  : Column(
                      children: [
                        Expanded(
                          child: ListView(
                            children: [
                              for (final user in _users!)
                                CheckboxListTile(
                                  title: Text(user.username),
                                  value: _selected.contains(user.id),
                                  onChanged: (checked) => setState(() {
                                    if (checked ?? false) {
                                      _selected.add(user.id);
                                    } else {
                                      _selected.remove(user.id);
                                    }
                                  }),
                                ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: FilledButton(
                            onPressed: _selected.isEmpty || _submitting ? null : _submit,
                            child: _submitting
                                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Text('초대하기'),
                          ),
                        ),
                      ],
                    ),
    );
  }
}
