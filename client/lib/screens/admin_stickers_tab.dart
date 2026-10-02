import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/stickers.dart';
import '../models/sticker_pack.dart';
import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/hover_toolbar.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/pagination.dart';
import '../widgets/sticker_view.dart';

/// 올릴 수 있는 그림 확장자(server/src/stickers.js의 STICKER_MIME과 같다).
const _imageExtensions = ['png', 'jpg', 'jpeg', 'gif', 'webp'];

/// "서버 관리 > 이모티콘" — 그림 이모티콘 세트, 그리고(세그먼트를 "캐릭터"로 바꾸면) 프로필
/// 사진으로 고르는 캐릭터 세트를 만들고 그림을 올린다(server/src/stickers.js). 둘은 서버의
/// 같은 테이블·API를 kind만 다르게 써서(server/src/db/schema.js 주석 참고) 화면도 이 한
/// 위젯을 공유하고, 세그먼트로 고른 kind만 목록·만들기 호출에 실어 보낸다.
///
/// 올린 이모티콘은 앱을 새로 배포하지 않아도 모든 사람의 이모티콘 선택창(또는 캐릭터는
/// 프로필 사진 편집 화면)에 바로 나온다.
///
/// 목록은 세트마다 대표 이미지(첫 그림) + 이름 카드이고, 대표 이미지를 누르면 그 세트의 모음으로
/// 바뀐다. 대표 이미지에 마우스를 올리면 "더보기"(그림 올리기 · 이름 바꾸기 · 세트 숨기기 ·
/// 세트 삭제). 이모티콘은 이미 보낸 메시지가, 캐릭터는 이미 그 그림을 프로필 사진으로 고른
/// 사람이 그 그림을 가리키고 있을 수 있어서 그림은 지우지 않고 숨기기만 하고, 세트 삭제도
/// 목록에서만 없앤다.
class AdminStickersTab extends StatefulWidget {
  final Session session;
  const AdminStickersTab({super.key, required this.session});

  @override
  State<AdminStickersTab> createState() => _AdminStickersTabState();
}

class _AdminStickersTabState extends State<AdminStickersTab> {
  /// 한 쪽에 보이는 세트 수(5칸 × 2줄쯤).
  static const _pageSize = 10;

  /// 'sticker'(채팅 이모티콘, 기본) | 'character'(프로필 사진 캐릭터).
  String _kind = 'sticker';
  bool get _isCharacter => _kind == 'character';

  List<ServerStickerPack>? _packs;
  String? _error;
  int _page = 0;

  /// 세트 모음을 보고 있는 세트 — null이면 세트 목록.
  String? _openPackId;

  /// 그림을 올리는 중인 세트 id.
  String? _uploadingPackId;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _switchKind(String kind) {
    if (kind == _kind) return;
    setState(() {
      _kind = kind;
      _packs = null;
      _openPackId = null;
      _page = 0;
    });
    _load();
  }

  Future<void> _load() async {
    try {
      final packs = await widget.session.api!.fetchStickerPacks(kind: _kind);
      if (mounted) {
        setState(() {
          _packs = [
            for (final p in packs)
              if (!p.deleted) p,
          ];
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// 바꾼 뒤 — 이 화면 목록과(이모티콘이면) 앱의 이모티콘 선택창을 같이 새로 받는다. 캐릭터는
  /// 상시 캐시해두는 선택창이 따로 없어서(프로필 사진 편집을 열 때마다 받는다) 이 화면만 새로
  /// 고치면 된다.
  Future<void> _changed() async {
    await _load();
    if (!_isCharacter) await widget.session.loadServerStickers(force: true);
  }

  Future<List<File>> _pickImages(String title) async {
    final picked = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: _imageExtensions,
      dialogTitle: title,
    );
    return [
      for (final f in picked?.files ?? const <PlatformFile>[])
        if (f.path != null) File(f.path!),
    ];
  }

  // ── 동작 ──

  /// 새 세트 — 이름과 그림을 한 창에서 같이 정한다.
  Future<void> _createPack() async {
    final result = await showDialog<(String, List<File>)>(
      context: context,
      builder: (_) =>
          _NewPackDialog(pickImages: _pickImages, isCharacter: _isCharacter),
    );
    if (result == null) return;
    final (name, files) = result;
    try {
      final pack = await widget.session.api!.createStickerPack(
        name,
        kind: _kind,
      );
      if (files.isNotEmpty) {
        setState(() => _uploadingPackId = pack.id);
        await widget.session.api!.uploadStickers(pack.id, files);
      }
      if (mounted) {
        showAppToast(
          context,
          files.isEmpty
              ? '"$name" 세트를 만들었습니다.'
              : '"$name" 세트를 만들고 ${files.length}개를 올렸습니다.',
        );
      }
      await _changed();
    } catch (e) {
      if (mounted) showAppToast(context, '세트를 만들지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _uploadingPackId = null);
    }
  }

  /// 그림 여러 장을 골라 세트 맨 뒤에 올린다 — 파일 이름 순서(1, 2, … 10)대로 붙는다.
  Future<void> _upload(ServerStickerPack pack) async {
    final files = await _pickImages('"${pack.name}"에 올릴 그림 선택');
    if (files.isEmpty) return;
    setState(() => _uploadingPackId = pack.id);
    try {
      await widget.session.api!.uploadStickers(pack.id, files);
      if (mounted) {
        showAppToast(context, '"${pack.name}"에 ${files.length}개를 올렸습니다.');
      }
      await _changed();
    } catch (e) {
      if (mounted) showAppToast(context, '올리지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _uploadingPackId = null);
    }
  }

  Future<void> _rename(ServerStickerPack pack) async {
    final controller = TextEditingController(text: pack.name);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('세트 이름 바꾸기'),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (v) => Navigator.of(c).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(controller.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == pack.name) return;
    try {
      await widget.session.api!.updateStickerPack(pack.id, name: name);
      await _changed();
    } catch (e) {
      if (mounted) showAppToast(context, '이름을 바꾸지 못했습니다: $e');
    }
  }

  Future<void> _togglePack(ServerStickerPack pack) async {
    try {
      await widget.session.api!.updateStickerPack(
        pack.id,
        hidden: !pack.hidden,
      );
      await _changed();
    } catch (e) {
      if (mounted) showAppToast(context, '바꾸지 못했습니다: $e');
    }
  }

  Future<void> _deletePack(ServerStickerPack pack) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('세트 삭제'),
        content: Text(
          _isCharacter
              ? '"${pack.name}" 세트를 삭제할까요?\n'
                    '"캐릭터 선택하기"와 이 목록에서 사라집니다. 이미 이 세트의 그림을 프로필 '
                    '사진으로 고른 사람은 그대로 유지됩니다.'
              : '"${pack.name}" 세트를 삭제할까요?\n'
                    '이모티콘 선택창과 이 목록에서 사라집니다. 이미 보낸 메시지의 이모티콘은 그대로 보입니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.session.api!.deleteStickerPack(pack.id);
      if (_openPackId == pack.id) setState(() => _openPackId = null);
      if (mounted) showAppToast(context, '"${pack.name}" 세트를 삭제했습니다.');
      await _changed();
    } catch (e) {
      if (mounted) showAppToast(context, '삭제하지 못했습니다: $e');
    }
  }

  Future<void> _toggleSticker(ServerSticker sticker) async {
    try {
      await widget.session.api!.setStickerHidden(
        sticker.packId,
        sticker.id,
        !sticker.hidden,
      );
      await _changed();
    } catch (e) {
      if (mounted) showAppToast(context, '바꾸지 못했습니다: $e');
    }
  }

  /// 세트의 "더보기" 메뉴 항목 — 목록의 카드와 이모티콘 모음 화면이 같이 쓴다.
  List<Widget> _packMenu(ServerStickerPack pack) => [
    hoverMenuItem(
      icon: Icons.upload_outlined,
      label: '그림 올리기',
      onPressed: () => _upload(pack),
    ),
    hoverMenuItem(
      icon: Icons.edit_outlined,
      label: '이름 바꾸기',
      onPressed: () => _rename(pack),
    ),
    hoverMenuItem(
      icon: pack.hidden
          ? Icons.visibility_outlined
          : Icons.visibility_off_outlined,
      label: pack.hidden ? '세트 다시 보이기' : '세트 숨기기',
      onPressed: () => _togglePack(pack),
    ),
    hoverMenuItem(
      icon: Icons.delete_outline,
      label: '세트 삭제',
      color: Colors.redAccent,
      onPressed: () => _deletePack(pack),
    ),
  ];

  /// 세트를 대표하는 그림 — 보이는 첫 그림, 다 숨겼으면 첫 그림.
  Sticker? _cover(ServerStickerPack pack) {
    final s =
        pack.stickers.where((s) => !s.hidden).firstOrNull ??
        pack.stickers.firstOrNull;
    return s == null ? null : _asSticker(s);
  }

  Sticker _asSticker(ServerSticker s) => Sticker(
    '$serverStickerPrefix${s.id}',
    '',
    s.fileName ?? '',
    imageUrl: widget.session.resolveUrl(s.displayUrl),
  );

  // ── 화면 ──

  @override
  Widget build(BuildContext context) {
    final packs = _packs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _kindSwitch(context),
        const SizedBox(height: 12),
        Expanded(
          child: _error != null
              ? Center(child: Text(_error!))
              : packs == null
              ? const Center(child: CircularProgressIndicator())
              : () {
                  final open = packs
                      .where((p) => p.id == _openPackId)
                      .firstOrNull;
                  return open != null
                      ? _buildPack(context, open)
                      : _buildList(context, packs);
                }(),
        ),
      ],
    );
  }

  /// 이모티콘(채팅용) / 캐릭터(프로필 사진용) 세그먼트 — 바꾸면 목록으로 돌아가 그 kind만 받는다.
  Widget _kindSwitch(BuildContext context) => SegmentedButton<String>(
    segments: const [
      ButtonSegment(
        value: 'sticker',
        label: Text('이모티콘'),
        icon: Icon(Icons.emoji_emotions_outlined, size: 16),
      ),
      ButtonSegment(
        value: 'character',
        label: Text('캐릭터'),
        icon: Icon(Icons.face_outlined, size: 16),
      ),
    ],
    selected: {_kind},
    showSelectedIcon: false,
    onSelectionChanged: (s) => _switchKind(s.first),
  );

  Widget _buildList(BuildContext context, List<ServerStickerPack> packs) {
    final theme = Theme.of(context);
    final totalPages = math.max(1, (packs.length / _pageSize).ceil());
    final page = _page.clamp(0, totalPages - 1);
    final items = packs.skip(page * _pageSize).take(_pageSize).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _isCharacter
                    ? '캐릭터 세트를 만들고 그림(PNG·JPG·GIF·WEBP, 한 장 5MB 이하)을 올리면 앱을 '
                          '새로 배포하지 않아도 모든 사람의 "캐릭터 선택하기"(프로필 사진 편집)에 '
                          '바로 나옵니다. 대표 이미지를 누르면 세트 모음을 봅니다.'
                    : '그림 이모티콘 세트를 만들고 그림(PNG·JPG·GIF·WEBP, 한 장 5MB 이하)을 올리면 앱을 '
                          '새로 배포하지 않아도 모든 사람의 이모티콘 선택창에 바로 나옵니다. 대표 이미지를 '
                          '누르면 이모티콘 모음을 봅니다.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: _uploadingPackId != null ? null : _createPack,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('새 세트'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: packs.isEmpty
              ? Center(
                  child: Text(
                    _isCharacter
                        ? '아직 캐릭터 세트가 없습니다. "새 세트"로 만들어 보세요.'
                        : '아직 이모티콘 세트가 없습니다. "새 세트"로 만들어 보세요.',
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    // 카드 폭이 170쯤 되게 열 수를 정한다(넓으면 5칸).
                    final columns = (constraints.maxWidth / 170).floor().clamp(
                      2,
                      5,
                    );
                    final cardWidth =
                        (constraints.maxWidth - 14 - 12 * (columns - 1)) /
                        columns;
                    return MutedScrollbar(
                      controller: _scroll,
                      child: GridView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.only(right: 14, bottom: 8),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 16,
                          // 정사각형 그림 + 아래 두 줄(이름·개수). Windows 디스플레이 배율
                          // (125% 등)에서 글자 두 줄의 실제 높이가 반올림 때문에 1px 정도
                          // 더 커져서 "BOTTOM OVERFLOWED BY 1.00 PIXELS"가 뜨는 경우가
                          // 있었다 — 여유를 좀 더 둔다.
                          mainAxisExtent: cardWidth + 56,
                        ),
                        itemCount: items.length,
                        itemBuilder: (context, i) {
                          final pack = items[i];
                          return _PackCard(
                            pack: pack,
                            cover: _cover(pack),
                            uploading: _uploadingPackId == pack.id,
                            menu: _packMenu(pack),
                            onOpen: () => setState(() => _openPackId = pack.id),
                          );
                        },
                      ),
                    );
                  },
                ),
        ),
        if (totalPages > 1) ...[
          const Divider(height: 1),
          Pagination(
            currentPage: page,
            totalPages: totalPages,
            onPageSelected: (p) => setState(() => _page = p),
          ),
        ],
      ],
    );
  }

  /// 한 세트의 이모티콘 모음 — 그림을 누르면 숨기기/다시 보이기.
  Widget _buildPack(BuildContext context, ServerStickerPack pack) {
    final theme = Theme.of(context);
    final uploading = _uploadingPackId == pack.id;
    final shown = pack.stickers.where((s) => !s.hidden).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: '세트 목록',
              onPressed: () => setState(() => _openPackId = null),
            ),
            const SizedBox(width: 4),
            // 이름·개수 칸이 남는 폭을 전부 차지해서 "더보기"가 오른쪽 끝에 붙는다(예전엔 이름의
            // Flexible과 Spacer가 남는 폭을 반씩 나눠 가져서 더보기가 줄 가운데쯤에 섰다).
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      pack.name,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _countLabel(pack, shown),
                    style: TextStyle(color: theme.hintColor, fontSize: 12),
                  ),
                ],
              ),
            ),
            // 그림 올리기는 "더보기" 안에 있다 — 올리는 동안만 옆에 도는 표시.
            if (uploading)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            MenuAnchor(
              style: hoverMenuStyle(context),
              menuChildren: _packMenu(pack),
              // 기본 IconButton은 누르는 칸(48)이 넓어서 아이콘이 오른쪽 끝에서 한참 안쪽에 보인다 —
              // 칸을 아이콘 크기로 줄여 오른쪽 끝(아래 스크롤바 줄)에 붙인다.
              builder: (context, controller, _) => IconButton(
                icon: const Icon(Icons.more_vert),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 36),
                style: const ButtonStyle(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                tooltip: '더보기',
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: Text(
            _isCharacter
                ? '그림을 누르면 숨기거나 다시 보이게 합니다(숨긴 그림은 "캐릭터 선택하기"에서만 '
                      '빠지고, 이미 프로필 사진으로 고른 사람에게는 그대로 보입니다).'
                : '그림을 누르면 숨기거나 다시 보이게 합니다(숨긴 그림은 선택창에서만 빠지고, 이미 보낸 '
                      '메시지에서는 그대로 보입니다).',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ),
        Expanded(
          child: pack.stickers.isEmpty
              ? Center(
                  child: Text(
                    '"그림 올리기"로 그림을 여러 장 한꺼번에 올릴 수 있습니다.',
                    style: TextStyle(color: theme.hintColor),
                  ),
                )
              : MutedScrollbar(
                  controller: _scroll,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(8, 0, 14, 8),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final s in pack.stickers) _stickerTile(context, s),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _stickerTile(BuildContext context, ServerSticker s) {
    final sticker = _asSticker(s);
    return Tooltip(
      message: '${s.fileName ?? ''}\n${s.hidden ? '눌러서 다시 보이기' : '눌러서 숨기기'}',
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _toggleSticker(s),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Opacity(
            opacity: s.hidden ? 0.3 : 1,
            child: StickerView(
              stickerId: sticker.id,
              sticker: sticker,
              emojiSize: 28,
              imageSize: 84,
            ),
          ),
        ),
      ),
    );
  }
}

String _countLabel(ServerStickerPack pack, int shown) {
  final total = pack.stickers.length;
  final hiddenCount = total - shown;
  return [
    '$total개',
    if (hiddenCount > 0 && !pack.hidden) '숨김 $hiddenCount',
    if (pack.hidden) '세트 숨김',
  ].join(' · ');
}

/// 목록의 세트 카드 — 대표 이미지(누르면 이모티콘 모음) + 이름 + 개수. 대표 이미지에 마우스를
/// 올리면 오른쪽 위에 "더보기".
class _PackCard extends StatefulWidget {
  final ServerStickerPack pack;
  final Sticker? cover;
  final bool uploading;
  final List<Widget> menu;
  final VoidCallback onOpen;

  const _PackCard({
    required this.pack,
    required this.cover,
    required this.uploading,
    required this.menu,
    required this.onOpen,
  });

  @override
  State<_PackCard> createState() => _PackCardState();
}

class _PackCardState extends State<_PackCard> {
  bool _hovering = false;

  /// 메뉴가 떠 있는 동안은 마우스가 카드 밖(메뉴 위)으로 나가도 "더보기"를 계속 보여준다.
  bool _menuOpen = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pack = widget.pack;
    final cover = widget.cover;
    final shown = pack.stickers.where((s) => !s.hidden).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovering = true),
            onExit: (_) => setState(() => _hovering = false),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Material(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: widget.onOpen,
                    child: Opacity(
                      opacity: pack.hidden ? 0.4 : 1,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: FittedBox(
                          child: cover == null
                              ? Icon(
                                  Icons.emoji_emotions_outlined,
                                  size: 48,
                                  color: theme.hintColor,
                                )
                              : StickerView(
                                  stickerId: cover.id,
                                  sticker: cover,
                                  emojiSize: 28,
                                  imageSize: 120,
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (widget.uploading)
                  const Center(child: CircularProgressIndicator()),
                if (_hovering || _menuOpen)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: HoverToolbar(
                      children: [
                        HoverToolbarButton(
                          icon: Icons.more_vert,
                          tooltip: '더보기',
                          onMenuOpenChanged: (v) =>
                              setState(() => _menuOpen = v),
                          menuChildren: widget.menu,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          pack.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          _countLabel(pack, shown),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: theme.hintColor),
        ),
      ],
    );
  }
}

/// "새 세트" — 세트 이름과 올릴 그림을 한 창에서 고른다(그림은 나중에 올려도 된다).
class _NewPackDialog extends StatefulWidget {
  final Future<List<File>> Function(String title) pickImages;
  final bool isCharacter;
  const _NewPackDialog({required this.pickImages, required this.isCharacter});

  @override
  State<_NewPackDialog> createState() => _NewPackDialogState();
}

class _NewPackDialogState extends State<_NewPackDialog> {
  final _name = TextEditingController();
  List<File> _files = const [];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final files = await widget.pickImages('새 세트에 올릴 그림 선택');
    if (files.isNotEmpty) setState(() => _files = files);
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop((name, _files));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.isCharacter ? '새 캐릭터 세트' : '새 이모티콘 세트'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '세트 이름',
                hintText: '예: 리마인',
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _pick,
                  icon: const Icon(Icons.upload_outlined, size: 18),
                  label: Text(_files.isEmpty ? '그림 올리기' : '다시 고르기'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _files.isEmpty
                        ? 'PNG·JPG·GIF·WEBP, 한 장 5MB 이하 · 여러 장 선택'
                        : '${_files.length}장 선택됨 — 파일 이름 순서대로 붙습니다',
                    style: TextStyle(fontSize: 12, color: theme.hintColor),
                  ),
                ),
              ],
            ),
            if (_files.isNotEmpty) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final f in _files)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.file(
                            f,
                            width: 48,
                            height: 48,
                            fit: BoxFit.cover,
                            cacheWidth: 96,
                            errorBuilder: (_, _, _) => const SizedBox(
                              width: 48,
                              height: 48,
                              child: Icon(Icons.broken_image_outlined),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _name.text.trim().isEmpty ? null : _submit,
          child: Text(_files.isEmpty ? '만들기' : '만들고 ${_files.length}장 올리기'),
        ),
      ],
    );
  }
}
