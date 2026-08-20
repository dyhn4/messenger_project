import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/session.dart';

class FindIdScreen extends StatefulWidget {
  final Session session;
  const FindIdScreen({super.key, required this.session});

  @override
  State<FindIdScreen> createState() => _FindIdScreenState();
}

class _FindIdScreenState extends State<FindIdScreen> {
  final _email = TextEditingController();
  bool _loading = false;
  String? _error;
  String? _foundUsername;

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
      _foundUsername = null;
    });
    try {
      final api = ApiClient(baseUrl: widget.session.serverUrl!);
      final username = await api.findId(_email.text.trim());
      if (!mounted) return;
      setState(() => _foundUsername = username);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('아이디 찾기')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('가입할 때 등록한 이메일을 입력하세요.'),
            const SizedBox(height: 16),
            TextField(
              controller: _email,
              decoration: const InputDecoration(labelText: '이메일', border: OutlineInputBorder()),
              keyboardType: TextInputType.emailAddress,
              onSubmitted: (_) => _submit(),
            ),
            if (_foundUsername != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('아이디: $_foundUsername', style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _loading ? null : _submit,
              child: _loading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('아이디 찾기'),
            ),
          ],
        ),
      ),
    );
  }
}
