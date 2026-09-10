import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/invite_link.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/muted_scrollbar.dart';

/// "설치→가입" 초대 링크 관리 화면. 서버 운영자·계정 등급 관리자·팀 소유자에게만
/// 열려 있다(session.canCreateInviteLink — 서버도 매 요청마다 다시 확인한다).
///
/// 팀 합류는 이 화면이 하지 않는다 — 링크는 낯선 기기가 이 서버를 신뢰하고 설치 파일을
/// 받게만 해주고, 팀 합류는 항상 소유자·관리자가 팀 설정 → 팀원 추가에서 한다.
Future<void> showInviteLinkScreen(BuildContext context, Session session) {
  return showDialog<void>(
    context: context,
    builder: (_) => InviteLinkScreen(session: session),
  );
}

class InviteLinkScreen extends StatefulWidget {
  final Session session;
  const InviteLinkScreen({super.key, required this.session});

  @override
  State<InviteLinkScreen> createState() => _InviteLinkScreenState();
}

class _InviteLinkScreenState extends State<InviteLinkScreen> {
  List<InviteLink>? _links;
  String? _error;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final links = await widget.session.api!.fetchInviteLinks();
      if (!mounted) return;
      setState(() => _links = links);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _create() async {
    final label = await showDialog<String>(
      context: context,
      builder: (_) => const _CreateInviteLinkDialog(),
    );
    if (label == null) return;

    setState(() => _creating = true);
    try {
      final link = await widget.session.api!.createInviteLink(
        label: label.isEmpty ? null : label,
      );
      if (mounted) setState(() => _links = [link, ...?_links]);
      if (mounted) await _copyAndNotify(link);
    } catch (e) {
      _toast('초대 링크 생성 실패: $e');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _copyAndNotify(InviteLink link) async {
    if (link.url == null) return;
    await Clipboard.setData(ClipboardData(text: link.url!));
    _toast('링크를 복사했습니다. 원하는 곳에 붙여넣어 보내세요.');
  }

  Future<void> _revoke(InviteLink link) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('초대 링크 취소'),
        content: SizedBox(
          width: 320,
          child: Text(
            '${link.label ?? '이'} 링크를 취소할까요? 이미 보낸 링크로는 더 이상 설치·연결할 수 없게 됩니다.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('링크 취소하기'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      final revoked = await widget.session.api!.revokeInviteLink(link.id);
      if (!mounted) return;
      setState(() {
        final list = [...?_links];
        final i = list.indexWhere((l) => l.id == revoked.id);
        if (i >= 0) list[i] = revoked;
        _links = list;
      });
    } catch (e) {
      _toast('실패: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return FloatingDialog(
      title: '초대 링크',
      maxWidth: 480,
      maxHeight: 640,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '링크를 열면 설치 파일을 받고 이 서버에 연결할 수 있습니다. 팀 합류는 포함되지 않으니, '
            '가입한 뒤에는 팀 설정 → 팀원 추가에서 직접 넣어주세요.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: _creating ? null : _create,
              icon: _creating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_link),
              label: const Text('새 초대 링크 만들기'),
            ),
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          Flexible(child: _buildList(context)),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(child: Text(_error!)),
      );
    }
    final links = _links;
    if (links == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (links.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            '아직 만든 초대 링크가 없습니다.',
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
        ),
      );
    }
    return MutedScrollbar(
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: links.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) => _InviteLinkRow(
          link: links[i],
          onCopy: () => _copyAndNotify(links[i]),
          onRevoke: () => _revoke(links[i]),
        ),
      ),
    );
  }
}

class _InviteLinkRow extends StatelessWidget {
  final InviteLink link;
  final VoidCallback onCopy;
  final VoidCallback onRevoke;
  const _InviteLinkRow({
    required this.link,
    required this.onCopy,
    required this.onRevoke,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final inactive = !link.valid;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        link.label?.isNotEmpty == true ? link.label! : '초대 링크',
        style: TextStyle(color: inactive ? hint : null),
      ),
      subtitle: Text(
        '${link.statusLabel} · 사용 ${link.usedCount}회 · ${formatDateTime(link.createdAt)} 생성',
        style: TextStyle(color: hint),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (link.valid)
            IconButton(
              tooltip: '링크 복사',
              icon: const Icon(Icons.copy_outlined, size: 20),
              onPressed: onCopy,
            ),
          if (link.valid)
            IconButton(
              tooltip: '링크 취소',
              icon: const Icon(Icons.link_off, size: 20),
              onPressed: onRevoke,
            ),
        ],
      ),
    );
  }
}

/// 메모(선택)만 입력받는 작은 다이얼로그. 유효기간은 서버에서 항상 7일로 고정이라
/// 여기서 고를 게 없다.
class _CreateInviteLinkDialog extends StatefulWidget {
  const _CreateInviteLinkDialog();

  @override
  State<_CreateInviteLinkDialog> createState() =>
      _CreateInviteLinkDialogState();
}

class _CreateInviteLinkDialogState extends State<_CreateInviteLinkDialog> {
  final _label = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('초대 링크 만들기'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '발급하면 7일간 유효합니다.',
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _label,
              maxLength: 30,
              decoration: const InputDecoration(
                labelText: '메모 (선택)',
                hintText: '예: 9월 신입',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_label.text.trim()),
          child: const Text('만들기'),
        ),
      ],
    );
  }
}
