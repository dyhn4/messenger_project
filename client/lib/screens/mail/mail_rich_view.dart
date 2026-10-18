import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../l10n/tr.dart';

/// HTML 메일을 서식 그대로 그린다 — 서버가 걸러 낸 문서(server/src/webmailHtml.js htmlToRich)만 그린다(HTML을 그대로 그리지 않으므로
/// 스크립트·양식·스타일시트가 끼어들 자리가 없다). 블록 `{ b, c, al, bg, … }`과 글 조각 `{ x, s, h }`·줄바꿈 `{ br }`.
///
/// 원래 모양(보낸 쪽의 색)을 지키려고 어두운 화면에서도 흰 종이 위에 그린다. 바깥 그림은 [showRemoteImages]일 때만 서버를 거쳐
/// 받고([remotePath]), 아니면 자리에 그림 표시와 대체 글만. 본문 그림(cid)은 늘 보인다([cidPath]). 링크를 누르면 [onLink].
class MailRichView extends StatefulWidget {
  final Map<String, dynamic> doc;
  final bool showRemoteImages;
  final String Function(int index) cidPath;
  final String Function(String url) remotePath;
  final Future<Uint8List> Function(String path) loadBytes;
  final void Function(String href) onLink;
  const MailRichView({
    super.key,
    required this.doc,
    required this.showRemoteImages,
    required this.cidPath,
    required this.remotePath,
    required this.loadBytes,
    required this.onLink,
  });

  @override
  State<MailRichView> createState() => _MailRichViewState();
}

/// 받은 그림 바이트 — 같은 그림을 다시 받지 않게(최근 60개).
final _imageCache = <String, Uint8List>{};
const _imageCacheMax = 60;

const _paper = Colors.white;
const _ink = Color(0xDD000000);
const _linkColor = Color(0xFF1A5DC9);

Color? _hex(Object? v) {
  if (v is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(v)) return null;
  return Color(int.parse('ff${v.substring(1)}', radix: 16));
}

TextAlign? _align(Object? v) => switch (v) {
  'center' => TextAlign.center,
  'right' => TextAlign.right,
  'justify' => TextAlign.justify,
  'left' => TextAlign.left,
  _ => null,
};

const _headingScale = {
  'h1': 1.8,
  'h2': 1.5,
  'h3': 1.3,
  'h4': 1.15,
  'h5': 1.05,
  'h6': 1.0,
};

class _MailRichViewState extends State<MailRichView> {
  /// 이번 그리기에 만든 링크 누르기 — 다시 그리거나 사라질 때 버린다.
  final _recognizers = <TapGestureRecognizer>[];

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  List<Map<String, dynamic>> _children(Map<String, dynamic> node) => [
    for (final c in node['c'] as List? ?? const [])
      if (c is Map) c.cast<String, dynamic>(),
  ];

  bool _isInline(Map<String, dynamic> n) => n['x'] is String || n['br'] == 1;

  TextStyle _styleOf(Object? s, TextStyle base) {
    if (s is! Map) return base;
    var style = base;
    if (s['b'] == 1) style = style.copyWith(fontWeight: FontWeight.w700);
    if (s['i'] == 1) style = style.copyWith(fontStyle: FontStyle.italic);
    final decorations = [
      if (s['u'] == 1) TextDecoration.underline,
      if (s['st'] == 1) TextDecoration.lineThrough,
    ];
    if (decorations.isNotEmpty) {
      style = style.copyWith(decoration: TextDecoration.combine(decorations));
    }
    if (s['m'] == 1) {
      style = style.copyWith(
        fontFamily: 'monospace',
        fontFamilyFallback: const ['Consolas', 'Courier New'],
      );
    }
    final c = _hex(s['c']);
    if (c != null) style = style.copyWith(color: c);
    final bg = _hex(s['bg']);
    if (bg != null) style = style.copyWith(backgroundColor: bg);
    final z = s['z'];
    if (z is num) {
      style = style.copyWith(fontSize: (base.fontSize ?? 14) * z.toDouble());
    }
    return style;
  }

  InlineSpan _span(Map<String, dynamic> run, TextStyle base) {
    if (run['br'] == 1) return const TextSpan(text: '\n');
    var style = _styleOf(run['s'], base);
    final href = run['h'];
    if (href is String) {
      style = style.copyWith(
        color: _hex((run['s'] as Map?)?['c']) ?? _linkColor,
        decoration: TextDecoration.underline,
      );
      final r = TapGestureRecognizer()..onTap = () => widget.onLink(href);
      _recognizers.add(r);
      return TextSpan(text: run['x'] as String, style: style, recognizer: r);
    }
    return TextSpan(text: run['x'] as String, style: style);
  }

  Widget _paragraph(
    List<Map<String, dynamic>> runs,
    TextStyle base,
    TextAlign align,
  ) => Text.rich(
    TextSpan(children: [for (final r in runs) _span(r, base)]),
    textAlign: align,
  );

  /// 블록의 자식들 — 이어진 글 조각은 한 문단으로, 블록은 그대로 쌓는다.
  List<Widget> _flow(
    Map<String, dynamic> node,
    TextStyle base,
    TextAlign align,
    int depth,
  ) {
    final out = <Widget>[];
    var group = <Map<String, dynamic>>[];
    void flush() {
      if (group.isNotEmpty) out.add(_paragraph(group, base, align));
      group = [];
    }

    for (final child in _children(node)) {
      if (_isInline(child)) {
        group.add(child);
      } else {
        flush();
        out.add(_block(child, base, align, depth + 1));
      }
    }
    flush();
    return out;
  }

  Widget _column(List<Widget> children, TextAlign align) => Column(
    crossAxisAlignment: switch (align) {
      TextAlign.center => CrossAxisAlignment.center,
      TextAlign.right => CrossAxisAlignment.end,
      _ => CrossAxisAlignment.start,
    },
    mainAxisSize: MainAxisSize.min,
    children: children,
  );

  Widget _block(
    Map<String, dynamic> node,
    TextStyle base,
    TextAlign inherited,
    int depth,
  ) {
    final kind = node['b'] as String? ?? 'div';
    final align = _align(node['al']) ?? inherited;
    final bg = _hex(node['bg']);
    Widget child;
    switch (kind) {
      case 'img':
        return _MailImage(
          key: ValueKey('mail-rich-img-${identityHashCode(node)}'),
          node: node,
          align: align,
          showRemote: widget.showRemoteImages,
          cidPath: widget.cidPath,
          remotePath: widget.remotePath,
          loadBytes: widget.loadBytes,
          onLink: widget.onLink,
        );
      case 'hr':
        return const Divider(height: 16, color: Color(0x33000000));
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final style = base.copyWith(
          fontSize: (base.fontSize ?? 14) * _headingScale[kind]!,
          fontWeight: FontWeight.w700,
        );
        child = Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: _column(_flow(node, style, align, depth), align),
        );
      case 'p':
        child = Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _column(_flow(node, base, align, depth), align),
        );
      case 'quote':
        child = Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.only(left: 10),
          decoration: const BoxDecoration(
            border: Border(
              left: BorderSide(color: Color(0x44000000), width: 3),
            ),
          ),
          child: _column(
            _flow(
              node,
              base.copyWith(color: const Color(0x99000000)),
              align,
              depth,
            ),
            align,
          ),
        );
      case 'pre':
        child = Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(8),
          color: const Color(0xFFF3F3F3),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: _column(
              _flow(
                node,
                base.copyWith(
                  fontFamily: 'monospace',
                  fontFamilyFallback: const ['Consolas', 'Courier New'],
                ),
                TextAlign.left,
                depth,
              ),
              TextAlign.left,
            ),
          ),
        );
      case 'ul' || 'ol':
        child = _list(node, base, align, depth, ordered: kind == 'ol');
      case 'li':
        child = _listItem(const Text('•'), node, base, align, depth);
      case 'table':
        child = _table(node, base, align, depth);
      default:
        child = _column(_flow(node, base, align, depth), align);
    }
    if (bg != null) {
      child = Container(
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: child,
      );
    }
    return child;
  }

  Widget _listItem(
    Widget marker,
    Map<String, dynamic> node,
    TextStyle base,
    TextAlign align,
    int depth,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 24,
          child: DefaultTextStyle(
            style: base,
            textAlign: TextAlign.right,
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: marker,
            ),
          ),
        ),
        Expanded(child: _column(_flow(node, base, align, depth), align)),
      ],
    ),
  );

  Widget _list(
    Map<String, dynamic> node,
    TextStyle base,
    TextAlign align,
    int depth, {
    required bool ordered,
  }) {
    var n = (node['n'] as num?)?.toInt() ?? 1;
    final items = <Widget>[];
    for (final child in _children(node)) {
      if (child['b'] == 'li') {
        items.add(
          _listItem(
            Text(ordered ? '${n++}.' : '•'),
            child,
            base,
            align,
            depth + 1,
          ),
        );
      } else if (!_isInline(child)) {
        items.add(_block(child, base, align, depth + 1));
      } else {
        items.add(_paragraph([child], base, align));
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: items,
      ),
    );
  }

  /// 칸이 여럿인 표 — 칸 너비(%·px)를 비율로 쓰고, 칸이 너무 좁아지면(칸마다 120px 아래) 세로로 쌓는다.
  Widget _table(
    Map<String, dynamic> node,
    TextStyle base,
    TextAlign align,
    int depth,
  ) {
    final rows = [
      for (final r in _children(node))
        if (r['b'] == 'tr') _children(r),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 600.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final cells in rows)
              if (cells.isNotEmpty && width / cells.length < 120) ...[
                for (final cell in cells) _cell(cell, base, align, depth),
              ] else
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final cell in cells)
                        Expanded(
                          flex: _flexOf(cell, cells),
                          child: _cell(cell, base, align, depth),
                        ),
                    ],
                  ),
                ),
          ],
        );
      },
    );
  }

  int _flexOf(Map<String, dynamic> cell, List<Map<String, dynamic>> cells) {
    final wp = (cell['wp'] as num?)?.toInt();
    if (wp != null && wp > 0) return wp;
    final wx = (cell['wx'] as num?)?.toInt();
    if (wx != null && wx > 0) return (wx / 10).ceil();
    final known = cells
        .map((c) => (c['wp'] as num?)?.toInt() ?? 0)
        .fold<int>(0, (a, b) => a + b);
    final unknown = cells
        .where((c) => c['wp'] == null && c['wx'] == null)
        .length;
    if (known > 0 && known < 100 && unknown > 0) {
      return ((100 - known) / unknown).ceil();
    }
    return 10;
  }

  Widget _cell(
    Map<String, dynamic> cell,
    TextStyle base,
    TextAlign inherited,
    int depth,
  ) {
    final align = _align(cell['al']) ?? inherited;
    final bg = _hex(cell['bg']);
    return Container(
      color: bg,
      padding: const EdgeInsets.all(4),
      child: _column(_flow(cell, base, align, depth), align),
    );
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final base =
        Theme.of(context).textTheme.bodyMedium?.copyWith(color: _ink) ??
        const TextStyle(color: _ink, fontSize: 14);
    final bg = _hex(widget.doc['bg']) ?? _paper;
    return Container(
      key: const ValueKey('mail-rich-view'),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0x22000000)),
      ),
      padding: const EdgeInsets.all(12),
      child: SelectionArea(
        child: DefaultTextStyle(
          style: base,
          child: _block(widget.doc, base, TextAlign.left, 0),
        ),
      ),
    );
  }
}

/// 문서의 그림 하나 — 본문 그림(cid)·데이터 그림은 바로, 바깥 그림은 [showRemote]일 때만 받는다(아니면 자리 표시).
class _MailImage extends StatefulWidget {
  final Map<String, dynamic> node;
  final TextAlign align;
  final bool showRemote;
  final String Function(int index) cidPath;
  final String Function(String url) remotePath;
  final Future<Uint8List> Function(String path) loadBytes;
  final void Function(String href) onLink;
  const _MailImage({
    super.key,
    required this.node,
    required this.align,
    required this.showRemote,
    required this.cidPath,
    required this.remotePath,
    required this.loadBytes,
    required this.onLink,
  });

  @override
  State<_MailImage> createState() => _MailImageState();
}

class _MailImageState extends State<_MailImage> {
  Uint8List? _bytes;
  bool _failed = false;
  String? _loadingPath;

  Map get _src =>
      widget.node['src'] is Map ? widget.node['src'] as Map : const {};

  /// 받을 경로 — 바깥 그림이고 아직 안 보이게 해 두었으면 null.
  String? get _path {
    final cid = _src['cid'];
    if (cid is num) return widget.cidPath(cid.toInt());
    final url = _src['url'];
    if (url is String && widget.showRemote) return widget.remotePath(url);
    return null;
  }

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant _MailImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showRemote != widget.showRemote) _start();
  }

  void _start() {
    final data = _src['data'];
    if (data is String) {
      try {
        _bytes = base64Decode(data);
      } catch (_) {
        _failed = true;
      }
      return;
    }
    final path = _path;
    if (path == null || path == _loadingPath) return;
    final cached = _imageCache[path];
    if (cached != null) {
      _bytes = cached;
      return;
    }
    _loadingPath = path;
    widget
        .loadBytes(path)
        .then(
          (bytes) {
            _imageCache[path] = bytes;
            while (_imageCache.length > _imageCacheMax) {
              _imageCache.remove(_imageCache.keys.first);
            }
            if (mounted) setState(() => _bytes = bytes);
          },
          onError: (_) {
            if (mounted) setState(() => _failed = true);
          },
        );
  }

  @override
  Widget build(BuildContext context) {
    final w = (widget.node['w'] as num?)?.toDouble();
    final h = (widget.node['ht'] as num?)?.toDouble();
    final alt = widget.node['alt'] as String? ?? '';
    final href = widget.node['h'] as String?;
    Widget image;
    final bytes = _bytes;
    if (bytes != null && !_failed) {
      image = Image.memory(
        bytes,
        width: w,
        height: w == null ? h : null,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _placeholder(alt, w, h, broken: true),
      );
    } else {
      image = _placeholder(alt, w, h, broken: _failed);
    }
    image = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: double.infinity),
      child: FittedBox(fit: BoxFit.scaleDown, child: image),
    );
    if (href != null) {
      image = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: () => widget.onLink(href), child: image),
      );
    }
    return Align(
      alignment: switch (widget.align) {
        TextAlign.center => Alignment.center,
        TextAlign.right => Alignment.centerRight,
        _ => Alignment.centerLeft,
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: image,
      ),
    );
  }

  Widget _placeholder(String alt, double? w, double? h, {bool broken = false}) {
    final remote = _src['url'] is String && !widget.showRemote;
    return Container(
      width: w?.clamp(48, 600),
      height: h?.clamp(24, 200),
      constraints: const BoxConstraints(minWidth: 48, minHeight: 24),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F1F1),
        border: Border.all(color: const Color(0x22000000)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            broken ? Icons.broken_image_outlined : Icons.image_outlined,
            size: 16,
            color: const Color(0x88000000),
          ),
          if (alt.isNotEmpty || remote) ...[
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                alt.isNotEmpty ? alt : tr('바깥 그림'),
                style: const TextStyle(fontSize: 12, color: Color(0x88000000)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
