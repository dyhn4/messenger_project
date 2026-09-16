import 'dart:async';

import 'package:flutter/material.dart';

import '../models/announcement.dart';
import '../models/room.dart';
import '../services/chat_socket.dart' show AnnouncementRemovedEvent;
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/app_toast.dart';
import 'announcement_detail_screen.dart';
import 'home_screen.dart' show wideBreakpoint;

/// 토픽방 "공지" — 카카오톡과 같은 개념. 누구나 볼 수 있고(방 멤버라면), 토픽을 만들 수
/// 있는 사람만 새로 쓸 수 있다(session.canCreateAnnouncementIn). pinned인 글(방마다 최대
/// 1개)이 채팅방 상단 배너에 고정된다 — 새 글을 쓰면 자동으로 그 글로 바뀌고, "공지 내리기"로
/// 직접 내릴 수도 있다(announcement_detail_screen.dart).
Future<void> showAnnouncementListScreen(
  BuildContext context,
  Session session,
  Room room,
) {
  final isWide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  if (isWide) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: SizedBox(
          width: 480,
          height: 640,
          child: AnnouncementListScreen(session: session, room: room),
        ),
      ),
    );
  }
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('공지')),
        body: AnnouncementListScreen(session: session, room: room),
      ),
    ),
  );
}

class AnnouncementListScreen extends StatefulWidget {
  final Session session;
  final Room room;
  const AnnouncementListScreen({
    super.key,
    required this.session,
    required this.room,
  });

  @override
  State<AnnouncementListScreen> createState() => _AnnouncementListScreenState();
}

class _AnnouncementListScreenState extends State<AnnouncementListScreen> {
  List<Announcement>? _items;
  String? _error;
  StreamSubscription<Announcement>? _newSub;
  StreamSubscription<Announcement>? _updatedSub;
  StreamSubscription<AnnouncementRemovedEvent>? _deletedSub;
  StreamSubscription<AnnouncementRemovedEvent>? _unpinnedSub;

  bool get _canWrite => widget.session.canCreateAnnouncementIn(widget.room);

  @override
  void initState() {
    super.initState();
    _load();
    // 이 목록을 실제로 열었다는 뜻 — 알림 센터의 "안 읽은 공지" 표시를 여기서 지운다
    // (session.dart의 markAnnouncementsRead 참고. 배너만 보고 안 열었으면 안읽음 그대로).
    widget.session.markAnnouncementsRead(widget.room);
    // 이 화면을 열어둔 채로 누군가 공지를 쓰거나/고치거나/내리거나/지우면, 새로고침 없이 그
    // 자리에서 바로 반영한다 — 채팅방 배너와 같은 실시간성.
    _newSub = widget.session.chatSocket.announcements.listen((a) {
      if (a.roomId != widget.room.id || !mounted) return;
      setState(() {
        final items = _items;
        if (items == null || items.any((e) => e.id == a.id)) return;
        _items = [a, ...items];
      });
    });
    _updatedSub = widget.session.chatSocket.announcementUpdated.listen((a) {
      if (a.roomId != widget.room.id || !mounted) return;
      setState(() {
        final items = _items;
        if (items == null) return;
        final i = items.indexWhere((e) => e.id == a.id);
        if (i == -1) return;
        items[i].text = a.text;
        items[i].editedAt = a.editedAt;
      });
    });
    _deletedSub = widget.session.chatSocket.announcementDeleted.listen((e) {
      if (e.roomId != widget.room.id || !mounted) return;
      setState(() {
        _items = _items?.where((a) => a.id != e.id).toList();
      });
    });
    _unpinnedSub = widget.session.chatSocket.announcementUnpinned.listen((e) {
      if (e.roomId != widget.room.id || !mounted) return;
      setState(() {
        final i = _items?.indexWhere((a) => a.id == e.id) ?? -1;
        if (i != -1) _items![i].pinned = false;
      });
    });
  }

  @override
  void dispose() {
    _newSub?.cancel();
    _updatedSub?.cancel();
    _deletedSub?.cancel();
    _unpinnedSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final items = await widget.session.api!.fetchAnnouncements(
        widget.room.id,
      );
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _write() async {
    final text = await _showWriteDialog(context);
    if (text == null || text.isEmpty || !mounted) return;
    try {
      final created = await widget.session.api!.createAnnouncement(
        widget.room.id,
        text,
      );
      if (!mounted) return;
      // 소켓 echo(위 _newSub)와 중복되지 않도록 id로 한 번 더 확인한다.
      setState(() {
        final items = _items ?? [];
        if (items.any((e) => e.id == created.id)) return;
        _items = [created, ...items];
      });
    } catch (e) {
      if (mounted) showAppToast(context, '공지를 등록하지 못했습니다: $e');
    }
  }

  Future<String?> _showWriteDialog(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('공지 작성'),
        content: SizedBox(
          width: 400,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 6,
            minLines: 3,
            maxLength: 2000,
            decoration: const InputDecoration(
              hintText: '공지 내용을 입력하세요',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('완료'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = _buildContent(context);
    // 좁은 화면은 showAnnouncementListScreen이 이미 Scaffold+AppBar를 씌워서 push하므로
    // 그대로 쓰고, 넓은 화면(Dialog)에서는 FloatingDialog와 같은 헤더+닫기 버튼을 직접 그린다.
    final isWide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
    if (!isWide) return content;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '공지',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(child: content),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final items = _items;
    if (items == null) return const Center(child: CircularProgressIndicator());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_canWrite)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _write,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('글쓰기'),
              ),
            ),
          ),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('등록된 공지가 없습니다.'))
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 24),
                  itemBuilder: (context, i) => _AnnouncementTile(
                    announcement: items[i],
                    onTap: () => showAnnouncementDetailScreen(
                      context,
                      widget.session,
                      widget.room,
                      items[i],
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _AnnouncementTile extends StatelessWidget {
  final Announcement announcement;
  final VoidCallback onTap;
  const _AnnouncementTile({required this.announcement, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (announcement.pinned)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.push_pin,
                    size: 14,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '채팅방에 고정됨',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          Text(announcement.text, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 6),
          Text(
            '${formatRelativeTime(announcement.createdAt)} · ${announcement.authorName} · 댓글 ${announcement.commentCount}개',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
          ),
        ],
      ),
    );
  }
}
