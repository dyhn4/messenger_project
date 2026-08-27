import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/session.dart';
import '../widgets/floating_dialog.dart';
import 'create_topic_screen.dart';

class TopicBrowseScreen extends StatefulWidget {
  final Session session;
  final bool asDialog;
  const TopicBrowseScreen({
    super.key,
    required this.session,
    this.asDialog = false,
  });

  @override
  State<TopicBrowseScreen> createState() => _TopicBrowseScreenState();
}

class _TopicBrowseScreenState extends State<TopicBrowseScreen> {
  List<TopicBrowseEntry>? _topics;
  String? _error;
  String? _joiningId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final topics = await widget.session.api!.browseTopics();
      if (!mounted) return;
      setState(() => _topics = topics);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _join(TopicBrowseEntry topic) async {
    setState(() => _joiningId = topic.id);
    try {
      await widget.session.joinRoom(topic.id);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('참여 실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _joiningId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = _error != null
        ? Center(child: Text(_error!))
        : _topics == null
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            shrinkWrap: widget.asDialog,
            children: [
              for (final topic in _topics!)
                ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.tag)),
                  title: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: Text(topic.name)),
                      if (!topic.isPublic) ...[
                        const SizedBox(width: 6),
                        Icon(
                          Icons.lock_outline,
                          size: 14,
                          color: Theme.of(context).hintColor,
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    topic.description ?? '멤버 ${topic.memberCount}명',
                  ),
                  trailing: topic.joined
                      ? const Text('참여중')
                      : FilledButton(
                          onPressed: _joiningId == topic.id
                              ? null
                              : () => _join(topic),
                          child: _joiningId == topic.id
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('참여'),
                        ),
                ),
            ],
          );

    if (widget.asDialog) {
      return FloatingDialog(title: '토픽방 찾기', child: body);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('토픽방 찾기')),
      floatingActionButton: FloatingActionButton(
        tooltip: '토픽방 만들기',
        onPressed: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => CreateTopicScreen(session: widget.session),
            ),
          );
          _load();
        },
        child: const Icon(Icons.add),
      ),
      body: body,
    );
  }
}
