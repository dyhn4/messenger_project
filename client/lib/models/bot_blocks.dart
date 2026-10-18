/// 봇 메시지의 블록(대화형 봇 메시지) — 서버 botBlocks.js가 걸러 저장한 모양과 같다. 머리글·글·칸·문맥·구분선·그림과 단추·선택지.
/// 블록이 있으면 말풍선은 메시지 글(text — 블록을 못 그리는 곳에 보일 글) 대신 이것을 그린다(widgets/bot_blocks_view.dart).
/// 단추·선택지를 누르면 서버(POST /api/messages/:id/actions)가 그 연동의 응답 주소로 알린다. 링크 단추(url)는 그 주소를 연다.
library;

/// 블록 하나.
sealed class BotBlock {
  const BotBlock();

  /// 서버 모양 하나 → 블록. 모르는 종류는 null(앱이 아직 모르는 블록은 건너뛴다).
  static BotBlock? fromJson(Object? json) {
    if (json is! Map) return null;
    final m = json.cast<String, dynamic>();
    switch (m['type']) {
      case 'header':
        final t = m['text'] as String?;
        return t == null || t.isEmpty ? null : BotHeaderBlock(t);
      case 'section':
        return BotSectionBlock(
          text: m['text'] as String?,
          fields: (m['fields'] as List? ?? const [])
              .whereType<String>()
              .toList(),
          accessory: BotElement.fromJson(m['accessory']),
        );
      case 'context':
        final t = m['text'] as String?;
        return t == null || t.isEmpty ? null : BotContextBlock(t);
      case 'divider':
        return const BotDividerBlock();
      case 'image':
        final url = m['url'] as String?;
        return url == null
            ? null
            : BotImageBlock(
                url: url,
                alt: m['alt'] as String?,
                title: m['title'] as String?,
              );
      case 'actions':
        final elements = (m['elements'] as List? ?? const [])
            .map(BotElement.fromJson)
            .whereType<BotElement>()
            .toList();
        return elements.isEmpty
            ? null
            : BotActionsBlock(
                blockId: m['blockId'] as String?,
                elements: elements,
              );
    }
    return null;
  }

  /// 블록 목록 — 없거나 비면 null.
  static List<BotBlock>? listFromJson(Object? json) {
    if (json is! List) return null;
    final list = json.map(fromJson).whereType<BotBlock>().toList();
    return list.isEmpty ? null : list;
  }
}

class BotHeaderBlock extends BotBlock {
  final String text;
  const BotHeaderBlock(this.text);
}

/// 글 칸 — 글, 두 줄로 놓이는 칸들(fields), 오른쪽에 붙는 단추·선택지 하나(accessory).
class BotSectionBlock extends BotBlock {
  final String? text;
  final List<String> fields;
  final BotElement? accessory;
  const BotSectionBlock({this.text, this.fields = const [], this.accessory});
}

class BotContextBlock extends BotBlock {
  final String text;
  const BotContextBlock(this.text);
}

class BotDividerBlock extends BotBlock {
  const BotDividerBlock();
}

/// 그림 — 서버가 받아 둔 그림의 서명 링크.
class BotImageBlock extends BotBlock {
  final String url;
  final String? alt;
  final String? title;
  const BotImageBlock({required this.url, this.alt, this.title});
}

class BotActionsBlock extends BotBlock {
  final String? blockId;
  final List<BotElement> elements;
  const BotActionsBlock({this.blockId, required this.elements});
}

/// 단추·선택지.
sealed class BotElement {
  final String actionId;
  const BotElement(this.actionId);

  static BotElement? fromJson(Object? json) {
    if (json is! Map) return null;
    final m = json.cast<String, dynamic>();
    final id = m['actionId'] as String?;
    if (id == null) return null;
    switch (m['type']) {
      case 'button':
        final text = m['text'] as String?;
        if (text == null || text.isEmpty) return null;
        return BotButton(
          actionId: id,
          text: text,
          url: m['url'] as String?,
          style: switch (m['style']) {
            'primary' => BotButtonStyle.primary,
            'danger' => BotButtonStyle.danger,
            _ => BotButtonStyle.normal,
          },
        );
      case 'select':
        final options = [
          for (final o in m['options'] as List? ?? const [])
            if (o is Map && o['text'] is String && o['value'] is String)
              BotSelectOption(
                text: o['text'] as String,
                value: o['value'] as String,
              ),
        ];
        if (options.isEmpty) return null;
        return BotSelect(
          actionId: id,
          placeholder: m['placeholder'] as String?,
          options: options,
          initial: m['initial'] as String?,
        );
    }
    return null;
  }
}

enum BotButtonStyle { normal, primary, danger }

class BotButton extends BotElement {
  final String text;

  /// 링크 단추면 열 주소 — 누르면 서버에 알리지 않고 그 주소를 연다.
  final String? url;
  final BotButtonStyle style;
  const BotButton({
    required String actionId,
    required this.text,
    this.url,
    this.style = BotButtonStyle.normal,
  }) : super(actionId);

  bool get isLink => url != null;
}

class BotSelectOption {
  final String text;
  final String value;
  const BotSelectOption({required this.text, required this.value});
}

class BotSelect extends BotElement {
  final String? placeholder;
  final List<BotSelectOption> options;
  final String? initial;
  const BotSelect({
    required String actionId,
    this.placeholder,
    required this.options,
    this.initial,
  }) : super(actionId);
}

/// 단추·선택지를 누른 결과(서버 POST /messages/:id/actions) — 메시지를 바꿨거나·지웠거나·방에 새로 올렸거나(소켓으로 따로 온다),
/// 누른 사람에게만 보일 답([ephemeral]), 아무 일 없음.
class BotActionResult {
  final bool updated;
  final bool removed;
  final bool posted;
  final String? ephemeral;
  const BotActionResult({
    this.updated = false,
    this.removed = false,
    this.posted = false,
    this.ephemeral,
  });

  factory BotActionResult.fromJson(Map<String, dynamic> json) =>
      BotActionResult(
        updated: json['updated'] == true,
        removed: json['removed'] == true,
        posted: json['posted'] == true,
        ephemeral: json['ephemeral'] as String?,
      );
}
