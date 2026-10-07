import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/message.dart' show serverHostedImagePath;
import '../models/room.dart';
import '../models/shared_link.dart';
import '../services/app_links.dart';
import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/hover_toolbar.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/pagination.dart';
import '../widgets/panel_filters.dart';

/// "메뉴 > 링크" — 대화에서 주고받은 링크를 한 곳에 모아 보는 패널(잔디의 "링크 모아보기"와 같은
/// 기능). 파일 패널과 같은 틀(헤더+검색칸+필터 줄(참여 대화방 / 모든 멤버 / 기간)+정렬+목록+페이지
/// 넘김, "파일 ⌄" 형식 단추만 없다)이고, 줄마다 대화방 이름·미리보기
/// 그림·제목(없으면 도메인)·주소를 보여준다(_LinkRow — 누르는 곳마다 하는 일이 다르다).
class LinksScreen extends StatefulWidget {
  final Session session;

  /// 패널을 열 당시 보고 있던 방 — 대화방 필터의 시작값(파일 패널과 같다).
  final String? initialRoomId;
  final VoidCallback? onClose;

  /// "대화방에서 보기" — 그 방을 열고 해당 메시지로 스크롤한다(PC는 옆 채팅 패널, 모바일은 새 화면).
  final void Function(Room room, String messageId) onOpenMessage;

  const LinksScreen({
    super.key,
    required this.session,
    required this.onOpenMessage,
    this.initialRoomId,
    this.onClose,
  });

  @override
  State<LinksScreen> createState() => _LinksScreenState();
}

class _LinksScreenState extends State<LinksScreen> {
  final _listScrollController = ScrollController();

  String? _roomId;
  String? _senderId; // null = 모든 멤버
  PanelPeriod _period = const PanelPeriod();
  bool _newestFirst = true;
  String _query = ''; // 링크 검색어
  bool _loading = true;
  String? _error;
  List<SharedLink>? _results;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _roomId = widget.initialRoomId;
    _load();
  }

  @override
  void dispose() {
    _listScrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await widget.session.api!.fetchLinks(
        teamId: widget.session.currentTeam!.id,
        roomId: _roomId,
        senderId: _senderId,
        query: _query,
        since: _period.since(),
        until: _period.until,
        newestFirst: _newestFirst,
      );
      if (!mounted) return;
      setState(() {
        _results = results;
        _page = 0;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Room? _roomOf(SharedLink link) {
    for (final r in widget.session.rooms) {
      if (r.id == link.roomId) return r;
    }
    return null;
  }

  /// 링크 열기 — 채팅 말풍선에서 링크를 눌렀을 때와 같다(앱 안 링크면 앱에서, 아니면 브라우저).
  void _openLink(SharedLink link) {
    if (AppLinks.open(link.url)) return;
    final uri = Uri.tryParse(link.url);
    if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _copyLink(SharedLink link) async {
    await Clipboard.setData(ClipboardData(text: link.url));
    if (mounted) showAppToast(context, '링크를 복사했습니다.');
  }

  /// 길게 누르면(모바일 — 마우스 호버가 없다) 호버 도구와 같은 두 가지를 아래에서 올려 보여준다.
  void _showActions(SharedLink link) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('대화방에서 보기'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _openInRoom(link);
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_copy),
              title: const Text('링크 복사'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _copyLink(link);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _openInRoom(SharedLink link) {
    final room = _roomOf(link);
    if (room == null) {
      showAppToast(context, '대화방을 찾을 수 없습니다.');
      return;
    }
    widget.onOpenMessage(room, link.messageId);
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '링크',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          PanelFilterBar(
            searchHint: '링크 검색',
            initialQuery: _query,
            onQueryChanged: (q) {
              _query = q;
              _load();
            },
            session: widget.session,
            roomId: _roomId,
            onRoomChanged: (id) {
              // 방이 바뀌면 이전 방 멤버 기준으로 골랐던 보낸 사람도 같이 비운다(파일 패널과 같다).
              setState(() {
                _roomId = id;
                _senderId = null;
              });
              _load();
            },
            members: memberChoicesFor(widget.session, _roomId),
            senderId: _senderId,
            onSenderChanged: (v) {
              setState(() => _senderId = v);
              _load();
            },
            period: _period,
            onPeriodChanged: (v) {
              setState(() => _period = v);
              _load();
            },
            newestFirst: _newestFirst,
            onSortChanged: (v) {
              setState(() => _newestFirst = v);
              _load();
            },
          ),
          const SizedBox(height: 4),
          Expanded(child: _buildResults(context)),
        ],
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(_error!));
    final results = _results ?? const <SharedLink>[];
    final countLine = PanelResultLine(
      summary: Text(
        '"${results.length}"개가 로딩되었습니다.',
        key: const ValueKey('panel-loaded-count'),
        style: Theme.of(context).textTheme.labelLarge,
      ),
      rangeText: _period.rangeText,
    );
    if (results.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          countLine,
          const Divider(height: 1),
          const Expanded(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('주고받은 링크가 없습니다.'),
              ),
            ),
          ),
        ],
      );
    }

    final totalPages = (results.length / paginationPageSize).ceil();
    final page = _page.clamp(0, totalPages - 1);
    final pageItems = results
        .skip(page * paginationPageSize)
        .take(paginationPageSize)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        countLine,
        const Divider(height: 1),
        Expanded(
          child: MutedScrollbar(
            controller: _listScrollController,
            child: ListView.separated(
              controller: _listScrollController,
              itemCount: pageItems.length,
              // 오른쪽 끝에 겹치는 스크롤바 아래로 선이 파고들지 않도록 그만큼 짧게 그린다.
              separatorBuilder: (_, _) => const Padding(
                padding: EdgeInsets.only(right: 12),
                child: Divider(height: 1),
              ),
              itemBuilder: (context, i) {
                final link = pageItems[i];
                return _LinkRow(
                  link: link,
                  roomName:
                      _roomOf(link)?.displayName(widget.session.userId ?? '') ??
                      '',
                  resolveUrl: widget.session.resolveUrl,
                  onOpenLink: () => _openLink(link),
                  onOpenInRoom: () => _openInRoom(link),
                  onCopy: () => _copyLink(link),
                  onLongPress: () => _showActions(link),
                );
              },
            ),
          ),
        ),
        const Divider(height: 1),
        Pagination(
          currentPage: page,
          totalPages: totalPages,
          onPageSelected: (p) => setState(() => _page = p),
        ),
      ],
    );
  }
}

/// 링크 한 줄(잔디의 링크 목록과 같은 모양) — 맨 위에 대화방 이름(초록), 그 아래 미리보기 그림 ·
/// 제목(없으면 도메인) · 파란 주소. 주소를 누를 때만 링크가 열리고, 그림이나 제목(또는 방 이름)을
/// 누르면 "대화방에서 보기"(그 메시지로 이동)다. 마우스를 올리면 오른쪽 위에 "대화방에서 보기" ·
/// "링크 복사"가 뜨고, 모바일은 길게 눌러 같은 두 가지를 고른다.
class _LinkRow extends StatefulWidget {
  final SharedLink link;
  final String roomName;

  /// 서버 상대 경로(미리보기 그림의 서명 링크)를 절대 주소로(Session.resolveUrl).
  final String Function(String relative) resolveUrl;
  final VoidCallback onOpenLink;
  final VoidCallback onOpenInRoom;
  final VoidCallback onCopy;
  final VoidCallback onLongPress;

  const _LinkRow({
    required this.link,
    required this.roomName,
    required this.resolveUrl,
    required this.onOpenLink,
    required this.onOpenInRoom,
    required this.onCopy,
    required this.onLongPress,
  });

  @override
  State<_LinkRow> createState() => _LinkRowState();
}

class _LinkRowState extends State<_LinkRow> {
  bool _hovering = false;

  /// 누를 수 있는 부분(그림·제목·방 이름·주소)에만 손가락 커서와 누르기를 붙인다.
  Widget _clickable(VoidCallback onTap, Widget child) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(onTap: onTap, child: child),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final roomColor = dark ? const Color(0xFF5FD08E) : const Color(0xFF1E9E57);
    final urlColor = dark ? const Color(0xFF8AB8FF) : const Color(0xFF2F6FDB);
    final link = widget.link;

    // 미리보기 그림이 없거나 아직(또는 못) 받으면 링크 아이콘 칸.
    final placeholder = Container(
      width: 48,
      height: 48,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(Icons.link, size: 22, color: theme.hintColor),
    );
    // 미리보기 그림은 서버가 받아 둔 파일(서명된 /files 경로)만 우리 서버에서 받는다 — 바깥 사이트 주소는 그리지 않는다
    // (보는 사람마다 그 사이트에 직접 접속하게 된다 — server/src/linkPreviewImage.js).
    final image = serverHostedImagePath(link.imageUrl);
    final thumbnail = ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: image == null
          ? placeholder
          : Image.network(
              widget.resolveUrl(image),
              key: const ValueKey('link-row-image'),
              width: 48,
              height: 48,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => placeholder,
            ),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Stack(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: widget.onLongPress,
            child: Container(
              color: _hovering
                  ? theme.colorScheme.onSurface.withValues(alpha: 0.04)
                  : null,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _clickable(
                    widget.onOpenInRoom,
                    Text(
                      widget.roomName.isEmpty ? '대화방' : widget.roomName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: roomColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      _clickable(widget.onOpenInRoom, thumbnail),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _clickable(
                              widget.onOpenInRoom,
                              Text(
                                link.displayTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                            const SizedBox(height: 4),
                            // 주소를 누를 때만 링크가 열린다.
                            _clickable(
                              widget.onOpenLink,
                              Row(
                                children: [
                                  Icon(
                                    Icons.open_in_new,
                                    size: 14,
                                    color: urlColor,
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      link.url,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: urlColor,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_hovering)
            Positioned(
              right: 12,
              top: 6,
              child: HoverToolbar(
                children: [
                  HoverToolbarButton(
                    icon: Icons.chat_outlined,
                    tooltip: '대화방에서 보기',
                    onPressed: widget.onOpenInRoom,
                  ),
                  HoverToolbarButton(
                    icon: Icons.content_copy,
                    tooltip: '링크 복사',
                    onPressed: widget.onCopy,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
