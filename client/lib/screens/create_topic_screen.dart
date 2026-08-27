import 'package:flutter/material.dart';

import '../services/session.dart';
import '../widgets/floating_dialog.dart';

class CreateTopicScreen extends StatefulWidget {
  final Session session;
  final bool asDialog;
  const CreateTopicScreen({
    super.key,
    required this.session,
    this.asDialog = false,
  });

  @override
  State<CreateTopicScreen> createState() => _CreateTopicScreenState();
}

class _CreateTopicScreenState extends State<CreateTopicScreen> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  bool _loading = false;
  String? _error;
  bool _isPublic = true;

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
        isPublic: _isPublic,
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
          decoration: const InputDecoration(
            labelText: '토픽 이름',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _description,
          decoration: const InputDecoration(
            labelText: '설명 (선택)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        Text('공개 여부', style: Theme.of(context).textTheme.labelLarge),
        Text(
          '공개 토픽은 지금은 물론 나중에 가입하는 회원에게도 계속 보여요. 비공개는 초대한 사람만 볼 수 있어요.',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
        ),
        RadioGroup<bool>(
          groupValue: _isPublic,
          onChanged: (v) => setState(() => _isPublic = v ?? true),
          child: const Column(
            children: [
              RadioListTile<bool>(
                contentPadding: EdgeInsets.zero,
                value: true,
                title: Text('공개'),
              ),
              RadioListTile<bool>(
                contentPadding: EdgeInsets.zero,
                value: false,
                title: Text('비공개'),
              ),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('만들기'),
        ),
      ],
    );

    if (widget.asDialog) {
      return FloatingDialog(
        title: '새 토픽 생성',
        child: SingleChildScrollView(child: body),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('토픽방 만들기')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: body,
      ),
    );
  }
}
