import 'dart:async';

import 'package:flutter/material.dart';

import '../models/inquiry.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/app_toast.dart';
import '../widgets/attachment_widgets.dart';
import 'home_screen.dart' show wideBreakpoint;

/// "문의함" — 계정 메뉴에서 연다. "받은 문의"(내가 팀장인 팀에서 팀원들이 보낸 문의, 상태
/// 변경 가능)와 "보낸 문의"(내가 다른 팀장에게 보낸 문의, 처리 현황만 확인) 두 탭.
Future<void> showInquiryInboxScreen(BuildContext context, Session session) {
  final isWide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  if (isWide) {
    return showDialog<void>(
      context: context,
      // AppBar의 TabBar와 body의 TabBarView가 같은 탭 상태를 공유하려면 DefaultTabController가
      // 둘의 공통 조상이어야 한다 — 그래서 InquiryInboxScreen 안이 아니라 여기서 한 번만 감싼다.
      builder: (_) => DefaultTabController(
        length: 2,
        child: Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: SizedBox(
            width: 520,
            height: 640,
            child: InquiryInboxScreen(session: session),
          ),
        ),
      ),
    );
  }
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('문의함'),
            bottom: const TabBar(
              tabs: [
                Tab(text: '받은 문의'),
                Tab(text: '보낸 문의'),
              ],
            ),
          ),
          body: InquiryInboxScreen(session: session, embedTabBar: false),
        ),
      ),
    ),
  );
}

class InquiryInboxScreen extends StatelessWidget {
  final Session session;
  // 좁은 화면(push)은 AppBar.bottom에 TabBar를 이미 얹어서 열기 때문에, 이 위젯 안에서는
  // TabBar를 또 그리지 않는다 — 넓은 화면(Dialog)만 자체 헤더+TabBar를 그린다.
  final bool embedTabBar;
  const InquiryInboxScreen({
    super.key,
    required this.session,
    this.embedTabBar = true,
  });

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isWide && embedTabBar)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '문의함',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        if (isWide && embedTabBar)
          const TabBar(
            tabs: [
              Tab(text: '받은 문의'),
              Tab(text: '보낸 문의'),
            ],
          ),
        const Divider(height: 1),
        Expanded(
          child: TabBarView(
            children: [
              _ReceivedInquiriesTab(session: session),
              _SentInquiriesTab(session: session),
            ],
          ),
        ),
      ],
    );
  }
}

/// "전체/대기/처리중/완료" 필터 + 목록. 내가 받은(=내가 팀장인) 문의만 보이고, 각 항목을
/// 눌러 상세보기에서 상태를 바꿀 수 있다.
class _ReceivedInquiriesTab extends StatefulWidget {
  final Session session;
  const _ReceivedInquiriesTab({required this.session});

  @override
  State<_ReceivedInquiriesTab> createState() => _ReceivedInquiriesTabState();
}

class _ReceivedInquiriesTabState extends State<_ReceivedInquiriesTab> {
  List<Inquiry>? _items;
  String? _error;
  InquiryStatus? _filter;
  StreamSubscription<Inquiry>? _newSub;
  StreamSubscription<Inquiry>? _statusSub;

  @override
  void initState() {
    super.initState();
    _load();
    _newSub = widget.session.chatSocket.inquiryNew.listen((inquiry) {
      if (!mounted) return;
      setState(() {
        final items = _items;
        if (items == null || items.any((e) => e.id == inquiry.id)) return;
        _items = [inquiry, ...items];
      });
    });
    _statusSub = widget.session.chatSocket.inquiryStatusChanged.listen((
      inquiry,
    ) {
      if (!mounted) return;
      setState(() {
        final i = _items?.indexWhere((e) => e.id == inquiry.id) ?? -1;
        if (i != -1) _items![i].status = inquiry.status;
      });
    });
  }

  @override
  void dispose() {
    _newSub?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final items = await widget.session.api!.fetchReceivedInquiries();
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _changeStatus(Inquiry inquiry, InquiryStatus status) async {
    try {
      final updated = await widget.session.api!.updateInquiryStatus(
        inquiry.id,
        status,
      );
      if (mounted) {
        setState(() {
          final i = _items?.indexWhere((e) => e.id == inquiry.id) ?? -1;
          if (i != -1) _items![i].status = updated.status;
        });
      }
    } catch (e) {
      if (mounted) showAppToast(context, '상태를 바꾸지 못했습니다: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final all = _items;
    if (all == null) return const Center(child: CircularProgressIndicator());
    final items = _filter == null
        ? all
        : all.where((e) => e.status == _filter).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('전체'),
                selected: _filter == null,
                onSelected: (_) => setState(() => _filter = null),
              ),
              for (final status in InquiryStatus.values)
                ChoiceChip(
                  label: Text(inquiryStatusLabel(status)),
                  selected: _filter == status,
                  onSelected: (_) => setState(() => _filter = status),
                ),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('받은 문의가 없습니다.'))
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 24),
                  itemBuilder: (context, i) => _InquiryTile(
                    inquiry: items[i],
                    counterpartLabel: items[i].senderName,
                    onTap: () => showDialog(
                      context: context,
                      builder: (_) => _InquiryDetailDialog(
                        session: widget.session,
                        inquiry: items[i],
                        counterpartLabel: '보낸 사람: ${items[i].senderName}',
                        onChangeStatus: (status) =>
                            _changeStatus(items[i], status),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// 내가 보낸 문의 — 처리 현황만 볼 수 있고 상태를 바꿀 수는 없다.
class _SentInquiriesTab extends StatefulWidget {
  final Session session;
  const _SentInquiriesTab({required this.session});

  @override
  State<_SentInquiriesTab> createState() => _SentInquiriesTabState();
}

class _SentInquiriesTabState extends State<_SentInquiriesTab> {
  List<Inquiry>? _items;
  String? _error;
  StreamSubscription<Inquiry>? _statusSub;

  @override
  void initState() {
    super.initState();
    _load();
    _statusSub = widget.session.chatSocket.inquiryStatusChanged.listen((
      inquiry,
    ) {
      if (!mounted) return;
      setState(() {
        final i = _items?.indexWhere((e) => e.id == inquiry.id) ?? -1;
        if (i != -1) _items![i].status = inquiry.status;
      });
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final items = await widget.session.api!.fetchSentInquiries();
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final items = _items;
    if (items == null) return const Center(child: CircularProgressIndicator());
    if (items.isEmpty) return const Center(child: Text('보낸 문의가 없습니다.'));

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 24),
      itemBuilder: (context, i) => _InquiryTile(
        inquiry: items[i],
        counterpartLabel: items[i].recipientName,
        onTap: () => showDialog(
          context: context,
          builder: (_) => _InquiryDetailDialog(
            session: widget.session,
            inquiry: items[i],
            counterpartLabel: '받는 사람: ${items[i].recipientName}',
            onChangeStatus: null,
          ),
        ),
      ),
    );
  }
}

Color _statusColor(BuildContext context, InquiryStatus status) {
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    InquiryStatus.open => Colors.orange,
    InquiryStatus.inProgress => scheme.primary,
    InquiryStatus.resolved => Colors.green,
  };
}

class _InquiryTile extends StatelessWidget {
  final Inquiry inquiry;
  final String counterpartLabel;
  final VoidCallback onTap;
  const _InquiryTile({
    required this.inquiry,
    required this.counterpartLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(context, inquiry.status);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        inquiry.category,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        inquiry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '$counterpartLabel · ${formatRelativeTime(inquiry.createdAt)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              inquiryStatusLabel(inquiry.status),
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 문의 상세 — 전체 내용 + (onChangeStatus가 있으면, 즉 받은 문의라면) 상태 변경 버튼.
class _InquiryDetailDialog extends StatefulWidget {
  final Session session;
  final Inquiry inquiry;
  final String counterpartLabel;
  final Future<void> Function(InquiryStatus status)? onChangeStatus;
  const _InquiryDetailDialog({
    required this.session,
    required this.inquiry,
    required this.counterpartLabel,
    required this.onChangeStatus,
  });

  @override
  State<_InquiryDetailDialog> createState() => _InquiryDetailDialogState();
}

class _InquiryDetailDialogState extends State<_InquiryDetailDialog> {
  bool _updating = false;

  Future<void> _setStatus(InquiryStatus status) async {
    if (widget.onChangeStatus == null || _updating) return;
    setState(() => _updating = true);
    try {
      await widget.onChangeStatus!(status);
      if (mounted) setState(() => widget.inquiry.status = status);
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inquiry = widget.inquiry;
    return AlertDialog(
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(inquiry.category, style: const TextStyle(fontSize: 11)),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(inquiry.title, overflow: TextOverflow.ellipsis)),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.counterpartLabel} · ${formatDateTime(inquiry.createdAt)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 12),
            Text(inquiry.content),
            if (inquiry.hasAttachment) ...[
              const SizedBox(height: 12),
              if (inquiry.attachmentIsImage)
                DownloadableImage(
                  session: widget.session,
                  url: inquiry.fileUrl!,
                  fileName: inquiry.fileName ?? '첨부 이미지',
                  thumbnailUrl: inquiry.thumbnailUrl,
                )
              else
                DownloadableFile(
                  session: widget.session,
                  url: inquiry.fileUrl!,
                  fileName: inquiry.fileName ?? '첨부 파일',
                ),
            ],
            if (widget.onChangeStatus != null) ...[
              const SizedBox(height: 20),
              Text('처리 상태', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final status in InquiryStatus.values)
                    ChoiceChip(
                      label: Text(inquiryStatusLabel(status)),
                      selected: inquiry.status == status,
                      onSelected: _updating ? null : (_) => _setStatus(status),
                    ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    '처리 상태: ',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  Text(inquiryStatusLabel(inquiry.status)),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}
