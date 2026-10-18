import 'package:flutter/material.dart';

import '../models/integration.dart';
import '../models/room.dart';
import '../models/team.dart' show AccountRole;
import '../services/api_client.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/app_toast.dart';
import '../widgets/avatar_utils.dart';
import '../widgets/integration_widgets.dart';
import '../l10n/tr.dart';

/// "웹훅·앱" — 이 방(토픽·그룹)에 붙인 연동을 탭 셋으로 다룬다(server/src/integrations.js).
/// - 들어오는 웹훅: 바깥 서비스(서버 모니터링·CI/배포·설문 등)가 웹훅 주소로 JSON을 보내면 그 이름·아이콘의 봇 메시지로 올라온다. 주소에 든
///   토큰이 열쇠라 만들 때 한 번만 보인다. 단추 응답 주소를 정하면 그 웹훅이 올린 메시지의 단추·선택지 누름을 서명해 보낸다.
/// - 나가는 웹훅: 이 방에서 생기는 일(새 메시지·멘션·할 일 등)을 바깥 주소로 서명한 JSON POST로 알린다(실패하면 다시 보내고, 연달아
///   실패하면 서버가 끈다 — 여기서 다시 켠다). 서명 비밀은 만들 때 한 번만 보인다.
/// - 앱: 서버 운영자가 만든 연동 앱(봇 계정)을 이 방에 추가·뺀다. 추가한 앱은 이 방의 메시지를 읽고 쓰고, 방의 일을 받는다.
Future<void> showRoomWebhooksDialog(
  BuildContext context,
  Session session,
  Room room,
) => showDialog<void>(
  context: context,
  builder: (_) => RoomWebhooksDialog(session: session, room: room),
);

/// 이 방에서 웹훅을 다룰 수 있는지 — 서버 integrationRules.js canManageRoomWebhooks와 같은 규칙(메뉴를 보일지만 정한다).
bool canManageRoomWebhooks(Session session, Room room) {
  if (room.isSecret) return false;
  if (room.type == RoomType.topic) {
    return room.viewMode == TopicViewMode.chat && room.canManage(session);
  }
  if (room.type == RoomType.group) {
    return session.accountRole != AccountRole.guest;
  }
  return false;
}

/// 창 틀 — 제목·탭 줄·탭 본문(탭마다 저마다 목록을 받고 만들기 단추를 아래에 둔다). 높이는 화면에 맞춰(폰에서는 줄고 목록이 스크롤된다).
class RoomWebhooksDialog extends StatelessWidget {
  final Session session;
  final Room room;
  const RoomWebhooksDialog({
    super.key,
    required this.session,
    required this.room,
  });

  @override
  Widget build(BuildContext context) {
    final height = (MediaQuery.sizeOf(context).height * 0.6).clamp(
      260.0,
      520.0,
    );
    return DefaultTabController(
      length: 3,
      child: AlertDialog(
        title: Text(tr('웹훅·앱')),
        contentPadding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
        content: SizedBox(
          width: 520,
          height: height,
          child: Column(
            children: [
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  Tab(
                    key: const ValueKey('webhooks-tab-incoming'),
                    text: tr('들어오는 웹훅'),
                  ),
                  Tab(
                    key: const ValueKey('webhooks-tab-outgoing'),
                    text: tr('나가는 웹훅'),
                  ),
                  Tab(key: const ValueKey('webhooks-tab-apps'), text: tr('앱')),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _IncomingTab(session: session, room: room),
                    _OutgoingTab(session: session, room: room),
                    _AppsTab(session: session, room: room),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('닫기')),
          ),
        ],
      ),
    );
  }
}

// ── 탭 공통 ──────────────────────────────────────────────────────────────

/// 탭 하나 — 방과 세션만 받는다.
abstract class _RoomTab extends StatefulWidget {
  final Session session;
  final Room room;
  const _RoomTab({required this.session, required this.room});
}

/// 탭 상태 공통 — 목록 받기(실패하면 다시 시도)·실행 중 표시(_busy 동안 메뉴·단추를 막는다)·실패는 알림. 탭을 넘겨도 받은 목록을 들고
/// 있는다(돌아올 때마다 다시 받지 않게 — 바꾼 뒤에는 그 탭이 직접 다시 받는다).
abstract class _RoomTabState<W extends _RoomTab, R> extends State<W>
    with AutomaticKeepAliveClientMixin<W> {
  List<R>? items;
  String? error;
  bool busy = false;

  ApiClient get api => widget.session.api!;

  /// 이 탭의 목록 받기.
  Future<List<R>> fetch();

  /// 목록을 못 받았을 때의 글(오류 포함).
  String loadFailText(Object e);

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => error = null);
    try {
      final got = await fetch();
      if (mounted) setState(() => items = got);
    } catch (e) {
      if (mounted) setState(() => error = loadFailText(e));
    }
  }

  Future<void> run(Future<void> Function() action, String failText) async {
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showAppToast(context, '$failText: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// 탭 본문 — 회색 소개 글, 목록(비면 [emptyText]), [footer](목록 아래 안내), 맨 아래 [button].
  Widget buildBody({
    required String intro,
    required String emptyText,
    required List<Widget> Function(List<R> items) rows,
    required Widget button,
    List<Widget> footer = const [],
  }) {
    final list = items;
    final hint = Theme.of(context).hintColor;
    final Widget body;
    if (error != null) {
      body = Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(error!, textAlign: TextAlign.center),
              TextButton(onPressed: load, child: Text(tr('다시 시도'))),
            ],
          ),
        ),
      );
    } else if (list == null) {
      body = const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.only(top: 10),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(intro, style: TextStyle(fontSize: 12, color: hint)),
          ),
          if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text(emptyText, style: TextStyle(color: hint)),
              ),
            ),
          ...rows(list),
          ...footer,
        ],
      );
    }
    return Column(
      children: [
        Expanded(child: body),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Align(alignment: Alignment.centerRight, child: button),
        ),
      ],
    );
  }
}

/// 지우기 메뉴 칸(빨간 글).
PopupMenuItem<String> _deleteMenuItem([String? label]) => PopupMenuItem(
  value: 'delete',
  child: Text(label ?? tr('지우기'), style: TextStyle(color: Colors.redAccent)),
);

/// 서명 비밀을 보여 줄 때 붙이는 안내 — 받는 쪽이 할 일([body]: 보내는 모양·확인 방법·답하는 모양).
class _SignatureHelp extends StatelessWidget {
  final String body;
  const _SignatureHelp({required this.body});

  @override
  Widget build(BuildContext context) {
    final small = TextStyle(fontSize: 12, color: Theme.of(context).hintColor);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 14),
        Text(tr('받는 서버에서 할 일'), style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(body, style: small),
      ],
    );
  }
}

/// 서버 관리자가 아니면 바깥에서 닿는 주소만 — 서버가 막고 그 글을 돌려주지만 미리 알린다(주소 입력 창 아래).
String? _publicAddressNote(Session session) => session.isServerAdmin
    ? null
    : tr('사내 주소·다른 포트는 서버 관리자만 정할 수 있습니다. 바깥에서 닿는 주소(80·443 포트)를 넣으세요.');

/// 주소가 http(s)로 시작하는지 — 나머지(공인 주소인지 등)는 서버가 본다.
bool _looksLikeHttpUrl(String url) =>
    url.startsWith('https://') || url.startsWith('http://');

// ── 들어오는 웹훅 ──────────────────────────────────────────────────────────

class _IncomingTab extends _RoomTab {
  const _IncomingTab({required super.session, required super.room});

  @override
  State<_IncomingTab> createState() => _IncomingTabState();
}

class _IncomingTabState extends _RoomTabState<_IncomingTab, Integration> {
  @override
  Future<List<Integration>> fetch() => api.fetchRoomWebhooks(widget.room.id);

  @override
  String loadFailText(Object e) => tr('웹훅 목록을 불러오지 못했습니다: {e}', {'e': e});

  Future<void> _create() async {
    final input = await showBotNameDialog(
      context,
      title: tr('웹훅 만들기'),
      confirmLabel: tr('만들기'),
    );
    if (input == null || !mounted) return;
    await run(() async {
      final made = await api.createWebhook(
        widget.room.id,
        name: input.name,
        emoji: input.emoji,
      );
      await load();
      if (mounted) await _reveal(made, created: true);
    }, tr('웹훅을 만들지 못했습니다'));
  }

  Future<void> _reveal(WebhookSecret s, {required bool created}) =>
      showSecretRevealDialog(
        context,
        title: created ? tr('웹훅을 만들었습니다') : tr('새 웹훅 주소'),
        intro: tr('바깥 서비스의 웹훅(Webhook URL) 칸에 이 주소를 넣으세요.'),
        secret: s.url,
        children: [WebhookUsageHelp(secret: s)],
      );

  /// 단추 응답의 서명 비밀 — 응답 주소를 처음 정했을 때와 새로 만들었을 때 한 번만.
  Future<void> _revealSigning(String secret) => showSecretRevealDialog(
    context,
    title: tr('단추 응답 서명 비밀'),
    intro: tr('단추 응답을 받는 서버에 이 서명 비밀을 넣으세요. 요청이 이 서버에서 온 것인지 확인하는 데 씁니다.'),
    secret: secret,
    children: [
      _SignatureHelp(
        body: tr(
          '이 웹훅이 올린 메시지의 단추·선택지를 누르면 POST JSON {type: "block_actions", actionId, value, blockId, teamId, roomId, roomName, messageId, message, userId, username, userName, timestamp}을 보냅니다.\n· 확인: X-TangoTalk-Signature가 "v1=" + HMAC-SHA256(서명 비밀, "<X-TangoTalk-Timestamp>.<본문>")의 16진수와 같은지, 시각이 5분 안인지 보세요.\n· 답: 5초 안에 JSON — {"text": "…"}는 누른 사람에게만, "replace_original": true면 그 메시지를 바꾸고, "delete_original": true면 지우고, "response_type": "in_channel"이면 방에 새로 올립니다. 할 말이 없으면 빈 답(204).',
        ),
      ),
    ],
  );

  Future<void> _rename(Integration hook) async {
    final input = await showBotNameDialog(
      context,
      title: tr('이름·아이콘 바꾸기'),
      initialName: hook.name,
      initialEmoji: hook.emoji,
    );
    if (input == null || !mounted) return;
    await run(() async {
      await api.updateIntegration(hook.id, {
        'name': input.name,
        'emoji': input.emoji,
      });
      await load();
    }, tr('바꾸지 못했습니다'));
  }

  /// 단추 응답 주소 정하기(비우면 뺀다) — 처음 정하면 서버가 서명 비밀을 만들어 이번에만 돌려준다.
  Future<void> _editInteraction(Integration hook) async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => _UrlDialog(
        title: tr('단추 응답 주소'),
        intro: tr(
          '이 웹훅이 올린 메시지의 단추·선택지를 누르면 이 주소로 서명한 요청(POST)을 보냅니다. 비우고 저장하면 단추 누름을 받지 않습니다.',
        ),
        initial: hook.interactionUrl ?? '',
        note: _publicAddressNote(widget.session),
      ),
    );
    if (url == null || !mounted) return;
    await run(() async {
      final (_, secret) = await api.updateIntegrationWithSecret(hook.id, {
        'interactionUrl': url.isEmpty ? null : url,
      });
      await load();
      if (secret != null && mounted) await _revealSigning(secret);
    }, tr('바꾸지 못했습니다'));
  }

  Future<void> _regenerateSigning(Integration hook) async {
    final ok = await confirmIntegrationDelete(
      context,
      title: tr('새 서명 비밀'),
      body: tr(
        '"{name}"의 지금 서명 비밀은 바로 못 쓰게 됩니다. 단추 응답을 받는 서버에도 새 비밀을 넣어야 합니다.',
        {'name': hook.name},
      ),
    );
    if (!ok || !mounted) return;
    await run(() async {
      final secret = await api.regenerateSigningSecret(hook.id);
      if (mounted) await _revealSigning(secret);
    }, tr('새 서명 비밀을 만들지 못했습니다'));
  }

  Future<void> _regenerate(Integration hook) async {
    final ok = await confirmIntegrationDelete(
      context,
      title: tr('새 주소 만들기'),
      body: tr('"{hook.name}"의 지금 주소는 바로 못 쓰게 됩니다. 바깥 서비스에 새 주소를 다시 넣어야 합니다.', {
        'hook.name': hook.name,
      }),
    );
    if (!ok || !mounted) return;
    await run(() async {
      final s = await api.regenerateIntegration(hook) as WebhookSecret;
      await load();
      if (mounted) await _reveal(s, created: false);
    }, tr('새 주소를 만들지 못했습니다'));
  }

  Future<void> _delete(Integration hook) async {
    final ok = await confirmIntegrationDelete(
      context,
      title: tr('웹훅 지우기'),
      body: tr(
        '"{hook.name}" 웹훅을 지울까요? 이 주소로 오는 글은 더 올라오지 않습니다. 이미 올라온 메시지는 그대로 남습니다.',
        {'hook.name': hook.name},
      ),
    );
    if (!ok || !mounted) return;
    await run(() async {
      await api.deleteIntegration(hook.id);
      await load();
    }, tr('지우지 못했습니다'));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return buildBody(
      intro: tr(
        '서버 모니터링 알림, CI/배포 결과, 설문 응답 같은 바깥 소식을 이 방에 봇 메시지로 받습니다. Slack·Discord 웹훅 형식도 그대로 받습니다.',
      ),
      emptyText: tr('아직 웹훅이 없습니다.'),
      rows: (hooks) => [
        for (final h in hooks)
          ListTile(
            key: ValueKey('webhook-${h.id}'),
            leading: AutomationAvatar(radius: 16, emoji: h.emoji),
            title: Text(h.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                '${h.tokenPrefix ?? ''}… · ${integrationUsageText(h.lastUsedAt, h.useCount)}',
                if (h.interactionUrl != null)
                  tr('단추 응답: {url}', {'url': h.interactionUrl}),
              ].join('\n'),
              style: const TextStyle(fontSize: 12),
            ),
            trailing: PopupMenuButton<String>(
              key: ValueKey('webhook-menu-${h.id}'),
              enabled: !busy,
              onSelected: (v) => switch (v) {
                'rename' => _rename(h),
                'interaction' => _editInteraction(h),
                'signing' => _regenerateSigning(h),
                'regenerate' => _regenerate(h),
                _ => _delete(h),
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'rename', child: Text(tr('이름·아이콘 바꾸기'))),
                PopupMenuItem(
                  value: 'interaction',
                  child: Text(tr('단추 응답 주소')),
                ),
                if (h.hasSigningSecret)
                  PopupMenuItem(value: 'signing', child: Text(tr('새 서명 비밀'))),
                PopupMenuItem(value: 'regenerate', child: Text(tr('새 주소 만들기'))),
                _deleteMenuItem(),
              ],
            ),
          ),
      ],
      button: FilledButton.icon(
        key: const ValueKey('webhook-create'),
        onPressed: busy || items == null ? null : _create,
        icon: const Icon(Icons.add, size: 18),
        label: Text(tr('웹훅 만들기')),
      ),
    );
  }
}

/// 주소 하나 입력 — 저장하면 다듬은 주소(비우면 '' — 빼기), 취소하면 null. http(s)로 시작하는지만 본다.
class _UrlDialog extends StatefulWidget {
  final String title;
  final String intro;
  final String initial;
  final String? note;
  const _UrlDialog({
    required this.title,
    required this.intro,
    required this.initial,
    this.note,
  });

  @override
  State<_UrlDialog> createState() => _UrlDialogState();
}

class _UrlDialogState extends State<_UrlDialog> {
  late final _url = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _submit() {
    final url = _url.text.trim();
    if (url.isNotEmpty && !_looksLikeHttpUrl(url)) {
      setState(() => _error = tr('주소는 http:// 또는 https://로 시작해야 합니다.'));
      return;
    }
    Navigator.of(context).pop(url);
  }

  @override
  Widget build(BuildContext context) {
    final small = TextStyle(fontSize: 12, color: Theme.of(context).hintColor);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.intro, style: small),
              TextField(
                key: const ValueKey('webhook-interaction-url'),
                controller: _url,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: tr('주소'),
                  hintText: 'https://app.company.com/tangotalk/actions',
                ),
                onSubmitted: (_) => _submit(),
              ),
              if (widget.note != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(widget.note!, style: small),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('webhook-interaction-confirm'),
          onPressed: _submit,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}

// ── 나가는 웹훅 ────────────────────────────────────────────────────────────

class _OutgoingTab extends _RoomTab {
  const _OutgoingTab({required super.session, required super.room});

  @override
  State<_OutgoingTab> createState() => _OutgoingTabState();
}

class _OutgoingTabState extends _RoomTabState<_OutgoingTab, Integration> {
  @override
  Future<List<Integration>> fetch() =>
      api.fetchRoomOutgoingWebhooks(widget.room.id);

  @override
  String loadFailText(Object e) => tr('나가는 웹훅 목록을 불러오지 못했습니다: {e}', {'e': e});

  Future<void> _revealSecret(
    String secret, {
    required bool created,
  }) => showSecretRevealDialog(
    context,
    title: created ? tr('나가는 웹훅을 만들었습니다') : tr('새 서명 비밀'),
    intro: tr('받는 서버에 이 서명 비밀을 넣으세요. 요청이 이 서버에서 온 것인지 확인하는 데 씁니다.'),
    secret: secret,
    children: [
      _SignatureHelp(
        body: tr(
          '고른 일이 이 방에서 생기면 POST JSON {id, type, createdAt, teamId, roomId, data}를 보냅니다(헤더 X-TangoTalk-Event·X-TangoTalk-Delivery).\n· 확인: X-TangoTalk-Signature가 "v1=" + HMAC-SHA256(서명 비밀, "<X-TangoTalk-Timestamp>.<본문>")의 16진수와 같은지, 시각이 5분 안인지 보세요.\n· 답: 10초 안에 2xx로 답하세요. 실패하면 10초·1분·5분·30분·2시간·6시간 뒤 다시 보내고(X-TangoTalk-Delivery는 같은 값), 연달아 10건이 끝내 실패하면 이 웹훅을 끕니다.',
        ),
      ),
    ],
  );

  Future<void> _create() async {
    final input = await showDialog<_OutgoingInput>(
      context: context,
      builder: (_) =>
          _OutgoingEditDialog(note: _publicAddressNote(widget.session)),
    );
    if (input == null || !mounted) return;
    await run(() async {
      final (_, secret) = await api.createOutgoingWebhook(
        widget.room.id,
        name: input.name,
        url: input.url,
        events: input.events,
        emoji: input.emoji,
      );
      await load();
      if (mounted) await _revealSecret(secret, created: true);
    }, tr('나가는 웹훅을 만들지 못했습니다'));
  }

  Future<void> _edit(Integration hook) async {
    final input = await showDialog<_OutgoingInput>(
      context: context,
      builder: (_) => _OutgoingEditDialog(
        initial: hook,
        note: _publicAddressNote(widget.session),
      ),
    );
    if (input == null || !mounted) return;
    await run(() async {
      await api.updateIntegration(hook.id, {
        'name': input.name,
        'emoji': input.emoji,
        'url': input.url,
        'events': input.events,
      });
      await load();
    }, tr('바꾸지 못했습니다'));
  }

  /// 보내 보기 — ping을 바로 한 번 보내고 결과만 알린다(보내기 기록에도 남는다).
  Future<void> _test(Integration hook) => run(() async {
    final d = await api.testIntegration(hook.id);
    if (!mounted) return;
    showAppToast(
      context,
      d.delivered
          ? tr('보냈습니다 (HTTP {status})', {'status': d.lastStatus ?? 200})
          : tr('보내지 못했습니다: {error}', {'error': _deliveryProblem(d)}),
      duration: const Duration(seconds: 4),
    );
    await load();
  }, tr('보내 보지 못했습니다'));

  Future<void> _showDeliveries(Integration hook) => run(() async {
    final list = await api.fetchIntegrationDeliveries(hook.id);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _DeliveriesDialog(hook: hook, deliveries: list),
    );
  }, tr('보내기 기록을 불러오지 못했습니다'));

  Future<void> _regenerateSigning(Integration hook) async {
    final ok = await confirmIntegrationDelete(
      context,
      title: tr('새 서명 비밀'),
      body: tr('"{name}"의 지금 서명 비밀은 바로 못 쓰게 됩니다. 받는 서버에도 새 비밀을 넣어야 합니다.', {
        'name': hook.name,
      }),
    );
    if (!ok || !mounted) return;
    await run(() async {
      final secret = await api.regenerateSigningSecret(hook.id);
      if (mounted) await _revealSecret(secret, created: false);
    }, tr('새 서명 비밀을 만들지 못했습니다'));
  }

  /// 다시 켜기 — 서버가 연달아 실패한 수를 0으로 되돌린다.
  Future<void> _enable(Integration hook) => run(() async {
    await api.updateIntegration(hook.id, {'enabled': true});
    await load();
  }, tr('켜지 못했습니다'));

  Future<void> _delete(Integration hook) async {
    final ok = await confirmIntegrationDelete(
      context,
      title: tr('나가는 웹훅 지우기'),
      body: tr('"{name}" 나가는 웹훅을 지울까요? 이 방의 일을 더 보내지 않습니다.', {
        'name': hook.name,
      }),
    );
    if (!ok || !mounted) return;
    await run(() async {
      await api.deleteIntegration(hook.id);
      await load();
    }, tr('지우지 못했습니다'));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return buildBody(
      intro: tr(
        '이 방에서 생기는 일(새 메시지·멘션·할 일 등)을 바깥 서비스 주소로 서명한 JSON 요청(POST)으로 알립니다. 보내지 못하면 몇 번 다시 보내고, 계속 실패하면 꺼집니다.',
      ),
      emptyText: tr('아직 나가는 웹훅이 없습니다.'),
      rows: (hooks) => [
        for (final h in hooks)
          ListTile(
            key: ValueKey('outgoing-${h.id}'),
            leading: AutomationAvatar(radius: 16, emoji: h.emoji),
            title: Text(h.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  h.url ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                Text(
                  h.events.map(integrationEventLabel).join(' · '),
                  style: const TextStyle(fontSize: 12),
                ),
                if (!h.enabled)
                  Text(
                    tr('꺼짐 — 보내기가 계속 실패했습니다'),
                    key: ValueKey('outgoing-disabled-${h.id}'),
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.redAccent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            trailing: PopupMenuButton<String>(
              key: ValueKey('outgoing-menu-${h.id}'),
              enabled: !busy,
              onSelected: (v) => switch (v) {
                'edit' => _edit(h),
                'test' => _test(h),
                'deliveries' => _showDeliveries(h),
                'signing' => _regenerateSigning(h),
                'enable' => _enable(h),
                _ => _delete(h),
              },
              itemBuilder: (_) => [
                if (!h.enabled)
                  PopupMenuItem(value: 'enable', child: Text(tr('켜기'))),
                PopupMenuItem(value: 'edit', child: Text(tr('수정'))),
                PopupMenuItem(value: 'test', child: Text(tr('보내 보기'))),
                PopupMenuItem(value: 'deliveries', child: Text(tr('보내기 기록'))),
                PopupMenuItem(value: 'signing', child: Text(tr('새 서명 비밀'))),
                _deleteMenuItem(),
              ],
            ),
          ),
      ],
      button: FilledButton.icon(
        key: const ValueKey('outgoing-create'),
        onPressed: busy || items == null ? null : _create,
        icon: const Icon(Icons.add, size: 18),
        label: Text(tr('나가는 웹훅 만들기')),
      ),
    );
  }
}

/// 보내기 한 건의 문제 — 서버가 남긴 오류 글, 없으면 받은 HTTP 코드.
String _deliveryProblem(WebhookDelivery d) =>
    d.lastError ?? (d.lastStatus != null ? 'HTTP ${d.lastStatus}' : '');

typedef _OutgoingInput = ({
  String name,
  String? emoji,
  String url,
  List<String> events,
});

/// 나가는 웹훅 만들기·수정 — 이름·주소·받을 일·아이콘 한 창에. 만들 때 받을 일은 새 메시지·멘션을 미리 고른다.
class _OutgoingEditDialog extends StatefulWidget {
  final Integration? initial;
  final String? note;
  const _OutgoingEditDialog({this.initial, this.note});

  @override
  State<_OutgoingEditDialog> createState() => _OutgoingEditDialogState();
}

class _OutgoingEditDialogState extends State<_OutgoingEditDialog> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _url = TextEditingController(text: widget.initial?.url ?? '');
  late final _emoji = TextEditingController(text: widget.initial?.emoji ?? '');
  late final Set<String> _events = {
    ...?widget.initial?.events,
    if (widget.initial == null) ...['message.created', 'mention'],
  };
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _url, _emoji]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final url = _url.text.trim();
    final String? problem;
    if (name.isEmpty) {
      problem = tr('이름을 넣으세요.');
    } else if (!_looksLikeHttpUrl(url)) {
      problem = tr('주소는 http:// 또는 https://로 시작해야 합니다.');
    } else if (_events.isEmpty) {
      problem = tr('받을 일을 하나 이상 고르세요.');
    } else {
      problem = null;
    }
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final emoji = _emoji.text.trim();
    Navigator.of(context).pop((
      name: name,
      emoji: emoji.isEmpty ? null : emoji,
      url: url,
      // 서버 목록과 같은 순서로.
      events: [
        for (final e in integrationEvents)
          if (_events.contains(e)) e,
      ],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.initial != null;
    final small = TextStyle(fontSize: 12, color: Theme.of(context).hintColor);
    return AlertDialog(
      title: Text(editing ? tr('나가는 웹훅 수정') : tr('나가는 웹훅 만들기')),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('outgoing-name'),
                controller: _name,
                autofocus: !editing,
                maxLength: 40,
                decoration: InputDecoration(
                  labelText: tr('이름'),
                  hintText: tr('예: 업무 시스템 연동'),
                ),
              ),
              TextField(
                key: const ValueKey('outgoing-url'),
                controller: _url,
                decoration: InputDecoration(
                  labelText: tr('보낼 주소'),
                  hintText: 'https://app.company.com/tangotalk/events',
                ),
              ),
              if (widget.note != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(widget.note!, style: small),
                ),
              TextField(
                key: const ValueKey('outgoing-emoji'),
                controller: _emoji,
                decoration: InputDecoration(
                  labelText: tr('아이콘(이모지 하나)'),
                  hintText: tr('비우면 🤖'),
                ),
              ),
              const SizedBox(height: 12),
              Text(tr('받을 일'), style: TextStyle(fontWeight: FontWeight.w600)),
              for (final e in integrationEvents)
                CheckboxListTile(
                  key: ValueKey('outgoing-event-$e'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _events.contains(e),
                  title: Text(integrationEventLabel(e)),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _events.add(e);
                    } else {
                      _events.remove(e);
                    }
                  }),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('outgoing-confirm'),
          onPressed: _submit,
          child: Text(editing ? tr('저장') : tr('만들기')),
        ),
      ],
    );
  }
}

/// 보내기 기록(최근 30건, 새것부터) — 시각·일·결과(HTTP 코드·오류)·시도 수. 기다리는 것은 다음에 보낼 시각도.
class _DeliveriesDialog extends StatelessWidget {
  final Integration hook;
  final List<WebhookDelivery> deliveries;
  const _DeliveriesDialog({required this.hook, required this.deliveries});

  String _statusText(WebhookDelivery d) {
    if (d.delivered) {
      return tr('보냄 (HTTP {status})', {'status': d.lastStatus ?? 200});
    }
    if (d.failed) return tr('실패 — {error}', {'error': _deliveryProblem(d)});
    final next = d.nextAttemptAt;
    return next == null
        ? tr('보내는 중')
        : tr('다시 보낼 차례 {time}', {'time': formatPostDateTime(next)});
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return AlertDialog(
      title: Text(tr('"{name}" 보내기 기록', {'name': hook.name})),
      contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      content: SizedBox(
        width: 480,
        child: deliveries.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  tr('아직 보낸 것이 없습니다.'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: hint),
                ),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final d in deliveries)
                    ListTile(
                      key: ValueKey('delivery-${d.id}'),
                      dense: true,
                      leading: Icon(
                        d.delivered
                            ? Icons.check_circle_outline
                            : d.failed
                            ? Icons.error_outline
                            : Icons.schedule,
                        color: d.delivered
                            ? Colors.green
                            : d.failed
                            ? Colors.redAccent
                            : hint,
                      ),
                      title: Text(
                        [
                          if (d.createdAt != null)
                            formatPostDateTime(d.createdAt!),
                          integrationEventLabel(d.event),
                        ].join(' · '),
                      ),
                      subtitle: Text(
                        '${_statusText(d)} · ${tr('{n}번 시도', {'n': d.attempts})}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('닫기')),
        ),
      ],
    );
  }
}

// ── 앱 ─────────────────────────────────────────────────────────────────────

class _AppsTab extends _RoomTab {
  const _AppsTab({required super.session, required super.room});

  @override
  State<_AppsTab> createState() => _AppsTabState();
}

class _AppsTabState extends _RoomTabState<_AppsTab, TeamApp> {
  @override
  Future<List<TeamApp>> fetch() => api.fetchRoomApps(widget.room.id);

  @override
  String loadFailText(Object e) => tr('앱 목록을 불러오지 못했습니다: {e}', {'e': e});

  /// 앱 추가 — 팀의 앱 중 아직 이 방에 없고 켜진 것을 골라 추가한다(서버가 방에 "앱을 추가했습니다" 알림을 올린다).
  Future<void> _add() async {
    List<TeamApp>? teamApps;
    await run(
      () async => teamApps = await api.fetchTeamApps(widget.room.teamId),
      tr('앱 목록을 불러오지 못했습니다'),
    );
    final all = teamApps;
    if (all == null || !mounted) return;
    final installed = {for (final a in items ?? const <TeamApp>[]) a.id};
    final picked = await showDialog<TeamApp>(
      context: context,
      builder: (_) => _AppPickerDialog(
        teamHasApps: all.isNotEmpty,
        apps: [
          for (final a in all)
            if (a.enabled && !installed.contains(a.id)) a,
        ],
      ),
    );
    if (picked == null || !mounted) return;
    await run(() async {
      await api.addAppToRoom(widget.room.id, picked.id);
      await load();
    }, tr('앱을 추가하지 못했습니다'));
  }

  Future<void> _remove(TeamApp app) async {
    final ok = await confirmIntegrationDelete(
      context,
      title: tr('이 방에서 앱 빼기'),
      body: tr(
        '"{name}"을(를) 이 방에서 뺄까요? 이 앱은 더 이 방의 메시지를 읽거나 올리지 못하고, 방의 일도 받지 않습니다. 이미 올라온 메시지는 그대로 남습니다.',
        {'name': app.name},
      ),
    );
    if (!ok || !mounted) return;
    await run(() async {
      await api.removeAppFromRoom(widget.room.id, app.id);
      await load();
    }, tr('앱을 빼지 못했습니다'));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return buildBody(
      intro: tr(
        '연동 앱은 서버 운영자가 만든 봇 계정입니다. 이 방에 추가하면 그 앱이 이 방의 메시지를 읽고 쓰고, 방에서 생기는 일을 받습니다.',
      ),
      emptyText: tr('이 방에 추가한 앱이 없습니다.'),
      rows: (apps) => [
        for (final a in apps)
          ListTile(
            key: ValueKey('room-app-${a.id}'),
            leading: AutomationAvatar(radius: 16, emoji: a.emoji),
            title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                if (a.description != null && a.description!.isNotEmpty)
                  a.description!,
                if (a.addedByName != null && a.addedAt != null)
                  tr('{name}님이 추가 · {time}', {
                    'name': a.addedByName,
                    'time': formatPostDateTime(a.addedAt!),
                  }),
                if (!a.enabled) tr('꺼짐 — 서버 운영자가 껐습니다'),
              ].join('\n'),
              style: const TextStyle(fontSize: 12),
            ),
            trailing: IconButton(
              key: ValueKey('room-app-remove-${a.id}'),
              tooltip: tr('이 방에서 빼기'),
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: busy ? null : () => _remove(a),
            ),
          ),
      ],
      button: FilledButton.icon(
        key: const ValueKey('room-app-add'),
        onPressed: busy || items == null ? null : _add,
        icon: const Icon(Icons.add, size: 18),
        label: Text(tr('앱 추가')),
      ),
    );
  }
}

/// 추가할 앱 고르기 — 하나를 고르면 "이 방의 메시지를 읽고 쓸 수 있다"는 안내를 보고 추가한다. 고를 앱이 없으면 서버 운영자가 만든다는 안내.
class _AppPickerDialog extends StatefulWidget {
  final List<TeamApp> apps;

  /// 팀에 앱이 하나라도 있는지(모두 이미 추가했거나 꺼진 것과 아예 없는 것을 가른다).
  final bool teamHasApps;
  const _AppPickerDialog({required this.apps, required this.teamHasApps});

  @override
  State<_AppPickerDialog> createState() => _AppPickerDialogState();
}

class _AppPickerDialogState extends State<_AppPickerDialog> {
  TeamApp? _picked;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final scheme = Theme.of(context).colorScheme;
    final apps = widget.apps;
    return AlertDialog(
      title: Text(tr('앱 추가')),
      contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      content: SizedBox(
        width: 440,
        child: apps.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  key: const ValueKey('room-app-none'),
                  widget.teamHasApps
                      ? tr(
                          '더 추가할 수 있는 앱이 없습니다. 새 연동 앱은 서버 운영자가 관리자 콘솔 → 연동 앱에서 만듭니다.',
                        )
                      : tr(
                          '이 팀에는 연동 앱이 없습니다. 연동 앱은 서버 운영자가 관리자 콘솔 → 연동 앱에서 만듭니다.',
                        ),
                  style: TextStyle(color: hint),
                ),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final a in apps)
                    ListTile(
                      key: ValueKey('room-app-pick-${a.id}'),
                      selected: _picked?.id == a.id,
                      selectedTileColor: scheme.primary.withValues(alpha: 0.08),
                      leading: AutomationAvatar(radius: 16, emoji: a.emoji),
                      title: Text(
                        a.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: a.description == null || a.description!.isEmpty
                          ? null
                          : Text(
                              a.description!,
                              style: const TextStyle(fontSize: 12),
                            ),
                      trailing: _picked?.id == a.id
                          ? Icon(Icons.check, color: scheme.primary)
                          : null,
                      onTap: () => setState(() => _picked = a),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 16,
                          color: Colors.orange.shade700,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            tr(
                              '이 앱은 이 방의 메시지를 읽고 쓸 수 있습니다. 방에서 생기는 일(새 메시지·멘션 등)도 이 앱에 보내집니다.',
                            ),
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.orange.shade800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        if (apps.isNotEmpty)
          FilledButton(
            key: const ValueKey('room-app-add-confirm'),
            onPressed: _picked == null
                ? null
                : () => Navigator.of(context).pop(_picked),
            child: Text(tr('추가')),
          ),
      ],
    );
  }
}

/// 웹훅 주소를 보여 줄 때 붙이는 사용법 — 보내는 모양과 curl 예, 자체 서명 인증서 안내.
class WebhookUsageHelp extends StatelessWidget {
  final WebhookSecret secret;
  const WebhookUsageHelp({super.key, required this.secret});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final small = TextStyle(fontSize: 12, color: hint);
    final selfSigned = secret.webUrl == null;
    final curl = tr(
      'curl -X POST{p0} -H \'Content-Type: application/json\' -d \'{"text":"배포가 끝났습니다"}\' {secret.url}',
      {'p0': selfSigned ? ' -k' : '', 'secret.url': secret.url},
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 14),
        Text(tr('보내는 방법'), style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(
          tr(
            'POST로 JSON {"text": "보낼 글"}을 보내면 됩니다. Slack(text·attachments·blocks)·Discord(content·embeds) 형식과 그냥 글(text/plain)도 받습니다. 1분에 60건까지.',
          ),
          style: small,
        ),
        const SizedBox(height: 6),
        CopyableSecretField(value: curl, copiedText: tr('예시 명령을 복사했습니다.')),
        if (selfSigned) ...[
          const SizedBox(height: 8),
          Text(
            tr(
              '이 서버는 자체 서명 인증서를 써서 바깥 서비스가 주소를 믿지 않을 수 있습니다(인증서 확인 끄기 필요 — curl은 -k). 관리자 콘솔에서 웹 앱 주소(정식 인증서)를 설정하면 그 주소로 안내합니다.',
            ),
            style: small,
          ),
        ] else if (secret.directUrl.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(tr('사내에서 보낼 때는 이 주소도 됩니다(자체 서명 인증서):'), style: small),
          const SizedBox(height: 4),
          CopyableSecretField(value: secret.directUrl),
        ],
      ],
    );
  }
}
