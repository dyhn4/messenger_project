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
    final result = await showDialog<(String, Duration?)>(
      context: context,
      builder: (_) => const _AnnouncementWriteDialog(),
    );
    if (result == null || !mounted) return;
    final (text, autoUnpinAfter) = result;
    if (text.isEmpty) return;
    try {
      final created = await widget.session.api!.createAnnouncement(
        widget.room.id,
        text,
        autoUnpinAt: autoUnpinAfter == null
            ? null
            : DateTime.now().add(autoUnpinAfter),
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

/// "공지 작성" 대화상자 — 내용 입력칸 아래에 "공지 자동 내리기" 빠른 선택 버튼들을 둔다.
/// 완료를 누르면 (텍스트, 자동 내리기까지 남은 기간) 튜플을 돌려준다(기간이 null이면 자동
/// 내리기 없음 — 기본값).
class _AnnouncementWriteDialog extends StatefulWidget {
  const _AnnouncementWriteDialog();

  @override
  State<_AnnouncementWriteDialog> createState() =>
      _AnnouncementWriteDialogState();
}

class _AnnouncementWriteDialogState extends State<_AnnouncementWriteDialog> {
  final _controller = TextEditingController();
  Duration? _autoUnpinAfter;
  // "지정"으로 고른 값인지 — 빠른 선택지와 우연히 같은 길이(예: 24시간=1일)를 골라도 칩 표시가
  // 헷갈리지 않도록 별도로 구분한다.
  bool _isCustom = false;

  static const _quickOptions = <(String, Duration?)>[
    ('없음', null),
    ('1시간', Duration(hours: 1)),
    ('4시간', Duration(hours: 4)),
    ('9시간', Duration(hours: 9)),
    ('1일', Duration(days: 1)),
    ('7일', Duration(days: 7)),
    ('30일', Duration(days: 30)),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _selectQuick(Duration? duration) {
    setState(() {
      _autoUnpinAfter = duration;
      _isCustom = false;
    });
  }

  Future<void> _pickCustom() async {
    final result = await showDialog<Duration>(
      context: context,
      builder: (_) => const _CustomAutoUnpinDialog(),
    );
    if (result == null || !mounted) return;
    setState(() {
      _autoUnpinAfter = result;
      _isCustom = true;
    });
  }

  String _customChipLabel() {
    final d = _autoUnpinAfter;
    if (!_isCustom || d == null) return '지정';
    final days = d.inDays;
    final hours = d.inHours % 24;
    if (days > 0 && hours > 0) return '지정 ($days일 $hours시간)';
    if (days > 0) return '지정 ($days일)';
    return '지정 ($hours시간)';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('공지 작성'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              maxLines: 6,
              minLines: 3,
              maxLength: 2000,
              decoration: const InputDecoration(
                hintText: '공지 내용을 입력하세요',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            Text('공지 자동 내리기', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (label, duration) in _quickOptions)
                  ChoiceChip(
                    label: Text(label),
                    selected: !_isCustom && _autoUnpinAfter == duration,
                    onSelected: (_) => _selectQuick(duration),
                  ),
                ChoiceChip(
                  label: Text(_customChipLabel()),
                  selected: _isCustom,
                  onSelected: (_) => _pickCustom(),
                ),
              ],
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
          onPressed: () {
            final text = _controller.text.trim();
            if (text.isEmpty) return;
            Navigator.of(context).pop((text, _autoUnpinAfter));
          },
          child: const Text('완료'),
        ),
      ],
    );
  }
}

/// "지정" 칩을 누르면 뜨는 일/시간 직접 입력 대화상자.
class _CustomAutoUnpinDialog extends StatefulWidget {
  const _CustomAutoUnpinDialog();

  @override
  State<_CustomAutoUnpinDialog> createState() =>
      _CustomAutoUnpinDialogState();
}

class _CustomAutoUnpinDialogState extends State<_CustomAutoUnpinDialog> {
  final _daysController = TextEditingController(text: '0');
  final _hoursController = TextEditingController(text: '0');

  @override
  void dispose() {
    _daysController.dispose();
    _hoursController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('공지 자동 내리기 — 직접 지정'),
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: TextField(
              controller: _daysController,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '일'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _hoursController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '시간'),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () {
            final days = int.tryParse(_daysController.text) ?? 0;
            final hours = int.tryParse(_hoursController.text) ?? 0;
            if (days <= 0 && hours <= 0) return;
            Navigator.of(context).pop(Duration(days: days, hours: hours));
          },
          child: const Text('완료'),
        ),
      ],
    );
  }
}
