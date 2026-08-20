import 'package:flutter/material.dart';

import '../services/session.dart';
import '../widgets/floating_dialog.dart';

class CreateTopicScreen extends StatefulWidget {
  final Session session;
  final bool asDialog;
  const CreateTopicScreen({super.key, required this.session, this.asDialog = false});

  @override
  State<CreateTopicScreen> createState() => _CreateTopicScreenState();
}

class _CreateTopicScreenState extends State<CreateTopicScreen> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _submit() async {
    if (_name.text.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final room = await widget.session.createTopic(
        name: _name.text.trim(),
        description: _description.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(room);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: '토픽 이름', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _description,
          decoration: const InputDecoration(labelText: '설명 (선택)', border: OutlineInputBorder()),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('만들기'),
        ),
      ],
    );

    if (widget.asDialog) {
      return FloatingDialog(title: '새 토픽 생성', child: body);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('토픽방 만들기')),
      body: Padding(padding: const EdgeInsets.all(20), child: body),
    );
  }
}
