import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/mail.dart';
import '../../services/api_client.dart' show ApiException;
import '../../services/download_storage.dart' show openLocalFile;
import '../../services/mail_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import 'mail_account_dialog.dart';
import 'mail_compose.dart';

/// 메일 화면을 연다 — PC·모바일 모두 전체 화면.
Future<void> openMailScreen(BuildContext context, Session session) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => MailScreen(session: session)),
    );

/// 이 폭부터 폴더 · 목록 · 읽기 세 칸(좁으면 목록에서 눌러 읽기 화면으로 넘어간다).
const kMailWideBreakpoint = 900.0;

/// 웹메일 — 연결한 메일 계정(IMAP/SMTP)의 폴더·목록·읽기·쓰기(server/src/webmail.js). 계정이 없으면 연결 안내. 새 메일이 오면
/// (session.mailEvents — 소켓 mail:new) 목록을 다시 받는다.
class MailScreen extends StatefulWidget {
  final Session session;

  /// 시험에서 가짜 API를 끼울 때. 기본은 세션의 것.
  final MailApi? api;
  const MailScreen({super.key, required this.session, this.api});

  @override
  State<MailScreen> createState() => _MailScreenState();
}

class _MailScreenState extends State<MailScreen> {
  MailApi get _api => widget.api ?? widget.session.mailApi;

  bool _loadingAccount = true;
  MailAccount? _account;
  String? _error;
  List<MailFolder> _folders = const [];
  String _folder = 'INBOX';
  List<MailSummary> _messages = const [];
  int? _nextBefore;
  bool _loadingList = false;
  bool _loadingMore = false;
  String _query = '';
  final _search = TextEditingController();
  int? _selectedUid;
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _loadAccount();
    _sub = widget.session.mailEvents.listen((_) => _refresh());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadAccount() async {
    try {
      final account = await _api.account();
      if (!mounted) return;
      setState(() {
        _account = account;
        _loadingAccount = false;
        _error = null;
      });
      if (account != null) await _refresh();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingAccount = false;
          _error = e is ApiException ? e.message : '$e';
        });
      }
    }
  }

  Future<void> _refresh() async {
    if (_account == null) return;
    await Future.wait([_loadFolders(), _loadMessages()]);
  }

  Future<void> _loadFolders() async {
    try {
      final folders = await _api.folders();
      if (!mounted) return;
      setState(() => _folders = folders);
      final inbox = folders.where((f) => f.isInbox).firstOrNull;
      if (inbox?.unseen != null) widget.session.setMailUnread(inbox!.unseen!);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is ApiException ? e.message : '$e');
      }
    }
  }

  Future<void> _loadMessages() async {
    setState(() => _loadingList = true);
    try {
      final page = await _api.messages(
        _folder,
        query: _query.isEmpty ? null : _query,
      );
      if (!mounted) return;
      setState(() {
        _messages = page.messages;
        _nextBefore = page.nextBefore;
        _loadingList = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingList = false;
          _error = e is ApiException ? e.message : '$e';
        });
      }
    }
  }

  Future<void> _loadMore() async {
    final before = _nextBefore;
    if (before == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _api.messages(
        _folder,
        before: before,
        query: _query.isEmpty ? null : _query,
      );
      if (!mounted) return;
      setState(() {
        _messages = [..._messages, ...page.messages];
        _nextBefore = page.nextBefore;
      });
    } catch (e) {
      if (mounted) showAppToast(context, e is ApiException ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _openFolder(String path) {
    setState(() {
      _folder = path;
      _selectedUid = null;
      _messages = const [];
      _query = '';
      _search.clear();
    });
    _loadMessages();
  }

  void _runSearch(String q) {
    setState(() {
      _query = q.trim();
      _selectedUid = null;
    });
    _loadMessages();
  }

  /// 읽기로 연 메일을 목록에서 읽음으로(서버는 열 때 읽음으로 바꾼다).
  void _markSeenLocally(int uid) {
    final i = _messages.indexWhere((m) => m.uid == uid);
    if (i < 0 || _messages[i].seen) return;
    setState(() {
      _messages = [..._messages]..[i] = _messages[i].copyWith(seen: true);
      _folders = [
        for (final f in _folders)
          f.path == _folder && (f.unseen ?? 0) > 0
              ? MailFolder(
                  path: f.path,
                  name: f.name,
                  specialUse: f.specialUse,
                  unseen: f.unseen! - 1,
                  total: f.total,
                )
              : f,
      ];
    });
    final inbox = _folders.where((f) => f.isInbox).firstOrNull;
    if (inbox?.path == _folder && inbox?.unseen != null) {
      widget.session.setMailUnread(inbox!.unseen!);
    }
  }

  Future<void> _open(MailSummary m, {required bool wide}) async {
    _markSeenLocally(m.uid);
    if (wide) {
      setState(() => _selectedUid = m.uid);
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(_folderName)),
          body: MailReader(
            key: ValueKey('reader-${m.uid}'),
            session: widget.session,
            api: _api,
            account: _account!,
            folder: _folder,
            uid: m.uid,
            folders: _folders,
            onChanged: _refresh,
            onGone: () {
              Navigator.of(context).maybePop();
              _refresh();
            },
          ),
        ),
      ),
    );
  }

  Future<void> _compose([MailDraft draft = const MailDraft()]) async {
    final sent = await showMailCompose(
      context,
      session: widget.session,
      api: _api,
      draft: draft,
    );
    if (sent && mounted) {
      showAppToast(context, '메일을 보냈습니다.');
      _refresh();
    }
  }

  Future<void> _connect() async {
    final account = await showMailAccountDialog(
      context,
      api: _api,
      current: _account,
    );
    if (account == null || !mounted) return;
    setState(() {
      _account = account;
      _folder = 'INBOX';
      _selectedUid = null;
    });
    showAppToast(context, '${account.email}을(를) 연결했습니다.');
    _refresh();
    widget.session.refreshMailUnread();
  }

  Future<void> _disconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('메일 계정 연결을 끊을까요?'),
        content: const Text(
          '서버에 둔 연결 값과 비밀번호를 지웁니다. 메일 자체는 원래 메일 서버에 그대로 남습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('mail-disconnect-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('끊기'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _api.disconnect();
      if (!mounted) return;
      widget.session.setMailUnread(0);
      setState(() {
        _account = null;
        _folders = const [];
        _messages = const [];
        _selectedUid = null;
      });
    } catch (e) {
      if (mounted) showAppToast(context, e is ApiException ? e.message : '$e');
    }
  }

  Future<void> _toggleNotify() async {
    final account = _account;
    if (account == null) return;
    try {
      final next = await _api.setNotify(!account.notify);
      if (!mounted) return;
      setState(() => _account = next);
      showAppToast(context, next.notify ? '새 메일 알림을 켰습니다.' : '새 메일 알림을 껐습니다.');
    } catch (e) {
      if (mounted) showAppToast(context, e is ApiException ? e.message : '$e');
    }
  }

  String get _folderName =>
      _folders.where((f) => f.path == _folder).firstOrNull?.name ??
      (_folder == 'INBOX' ? '받은편지함' : _folder);

  IconData _folderIcon(MailFolder f) => switch (f.specialUse) {
    r'\Inbox' => Icons.inbox_outlined,
    r'\Sent' => Icons.send_outlined,
    r'\Drafts' => Icons.drafts_outlined,
    r'\Junk' => Icons.report_gmailerrorred_outlined,
    r'\Trash' => Icons.delete_outline,
    r'\Archive' || r'\All' => Icons.archive_outlined,
    _ => Icons.folder_outlined,
  };

  Widget _folderList({VoidCallback? afterTap}) {
    final account = _account!;
    return ListView(
      key: const ValueKey('mail-folders'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(
            account.email,
            style: Theme.of(context).textTheme.titleSmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        for (final f in _folders)
          ListTile(
            key: ValueKey('mail-folder-${f.path}'),
            dense: true,
            selected: f.path == _folder,
            leading: Icon(_folderIcon(f), size: 20),
            title: Text(f.name, overflow: TextOverflow.ellipsis),
            trailing: (f.unseen ?? 0) > 0
                ? Text(
                    '${f.unseen}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  )
                : null,
            onTap: () {
              _openFolder(f.path);
              afterTap?.call();
            },
          ),
      ],
    );
  }

  Widget _messageList({required bool wide}) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    if (_loadingList && _messages.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _query.isNotEmpty ? '"$_query"에 맞는 메일이 없습니다.' : '메일이 없습니다.',
            style: TextStyle(color: theme.hintColor),
          ),
        ),
      );
    }
    final sentFolder =
        _folders.where((f) => f.path == _folder).firstOrNull?.isSent ?? false;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        key: const ValueKey('mail-list'),
        itemCount: _messages.length + (_nextBefore != null ? 1 : 0),
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          if (i == _messages.length) {
            return Padding(
              padding: const EdgeInsets.all(12),
              child: Center(
                child: _loadingMore
                    ? const CircularProgressIndicator()
                    : TextButton(
                        key: const ValueKey('mail-more'),
                        onPressed: _loadMore,
                        child: const Text('더 보기'),
                      ),
              ),
            );
          }
          final m = _messages[i];
          final who = sentFolder
              ? (m.to.isEmpty ? '' : '받는 사람: ${m.to.first.label}')
              : m.from.label;
          final bold = TextStyle(
            fontWeight: m.seen ? FontWeight.normal : FontWeight.w700,
          );
          return ListTile(
            key: ValueKey('mail-item-${m.uid}'),
            selected: wide && _selectedUid == m.uid,
            leading: Icon(
              m.seen ? Icons.drafts_outlined : Icons.mail,
              color: m.seen ? theme.hintColor : theme.colorScheme.primary,
              size: 20,
            ),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    who,
                    style: bold,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  mailListTime(m.date, now),
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
              ],
            ),
            subtitle: Row(
              children: [
                if (m.answered)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(Icons.reply, size: 14, color: theme.hintColor),
                  ),
                Expanded(
                  child: Text(
                    m.subject,
                    style: bold.copyWith(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (m.hasAttachments)
                  Icon(Icons.attach_file, size: 14, color: theme.hintColor),
                if (m.flagged)
                  const Icon(Icons.star, size: 16, color: Colors.amber),
              ],
            ),
            onTap: () => _open(m, wide: wide),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loadingAccount) {
      return Scaffold(
        appBar: AppBar(title: const Text('메일')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final account = _account;
    if (account == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('메일')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.mail_outline, size: 56, color: theme.hintColor),
                const SizedBox(height: 12),
                Text(
                  _error != null && _error!.contains('Cannot')
                      ? '이 서버 버전은 메일을 지원하지 않습니다. 서버를 업데이트하세요.'
                      : '쓰고 있는 메일 계정(회사 메일·네이버·Gmail 등)을 연결하면 여기서 메일을 받고 보낼 수 있습니다.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const ValueKey('mail-connect'),
                  onPressed: _connect,
                  icon: const Icon(Icons.link),
                  label: const Text('메일 계정 연결'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final wide = MediaQuery.sizeOf(context).width >= kMailWideBreakpoint;
    final searchField = SizedBox(
      width: wide ? 280 : 180,
      child: TextField(
        key: const ValueKey('mail-search'),
        controller: _search,
        textInputAction: TextInputAction.search,
        onSubmitted: _runSearch,
        decoration: InputDecoration(
          isDense: true,
          hintText: '메일 찾기',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  tooltip: '찾기 지우기',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    _search.clear();
                    _runSearch('');
                  },
                ),
          border: const OutlineInputBorder(),
        ),
      ),
    );
    final appBar = AppBar(
      title: Text('메일 · $_folderName'),
      actions: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: searchField,
        ),
        IconButton(
          key: const ValueKey('mail-refresh'),
          tooltip: '새로고침',
          icon: const Icon(Icons.refresh),
          onPressed: _refresh,
        ),
        if (wide)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: FilledButton.icon(
              key: const ValueKey('mail-compose'),
              onPressed: () => _compose(),
              icon: const Icon(Icons.edit, size: 18),
              label: const Text('메일 쓰기'),
            ),
          ),
        PopupMenuButton<String>(
          key: const ValueKey('mail-menu'),
          tooltip: '계정',
          onSelected: (v) => switch (v) {
            'edit' => _connect(),
            'notify' => _toggleNotify(),
            'disconnect' => _disconnect(),
            _ => null,
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit', child: Text('계정 바꾸기')),
            PopupMenuItem(
              value: 'notify',
              child: Text(account.notify ? '새 메일 알림 끄기' : '새 메일 알림 켜기'),
            ),
            const PopupMenuItem(value: 'disconnect', child: Text('연결 끊기')),
          ],
        ),
      ],
    );
    final banner = account.lastError != null || _error != null
        ? Container(
            key: const ValueKey('mail-error-banner'),
            width: double.infinity,
            color: theme.colorScheme.errorContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _error ?? account.lastError!,
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
                if (account.lastError != null)
                  TextButton(onPressed: _connect, child: const Text('계정 바꾸기')),
              ],
            ),
          )
        : null;
    if (!wide) {
      return Scaffold(
        appBar: appBar,
        drawer: Drawer(
          child: SafeArea(
            child: Builder(
              builder: (drawerContext) => _folderList(
                afterTap: () => Navigator.of(drawerContext).pop(),
              ),
            ),
          ),
        ),
        floatingActionButton: FloatingActionButton(
          key: const ValueKey('mail-compose'),
          tooltip: '메일 쓰기',
          onPressed: () => _compose(),
          child: const Icon(Icons.edit),
        ),
        body: Column(
          children: [
            ?banner,
            Expanded(child: _messageList(wide: false)),
          ],
        ),
      );
    }
    final selected = _selectedUid;
    return Scaffold(
      appBar: appBar,
      body: Column(
        children: [
          ?banner,
          Expanded(
            child: Row(
              children: [
                SizedBox(width: 220, child: _folderList()),
                const VerticalDivider(width: 1),
                SizedBox(width: 380, child: _messageList(wide: true)),
                const VerticalDivider(width: 1),
                Expanded(
                  child: selected == null
                      ? Center(
                          child: Text(
                            '왼쪽에서 메일을 고르세요.',
                            style: TextStyle(color: theme.hintColor),
                          ),
                        )
                      : MailReader(
                          key: ValueKey('reader-$_folder-$selected'),
                          session: widget.session,
                          api: _api,
                          account: account,
                          folder: _folder,
                          uid: selected,
                          folders: _folders,
                          onChanged: _refresh,
                          onReply: _compose,
                          onGone: () {
                            setState(() => _selectedUid = null);
                            _refresh();
                          },
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 메일 하나 읽기 — 머리(보낸 사람·받는 사람·참조·시각), 답장·전체 답장·전달·중요·안 읽음·옮기기·지우기, 첨부, 본문(글자).
class MailReader extends StatefulWidget {
  final Session session;
  final MailApi api;
  final MailAccount account;
  final String folder;
  final int uid;
  final List<MailFolder> folders;

  /// 읽음·중요가 바뀌었을 때(목록을 다시 받게).
  final VoidCallback onChanged;

  /// 옮기거나 지워서 이 폴더에서 없어졌을 때.
  final VoidCallback onGone;

  /// 답장·전달 쓰기 — 없으면 이 위젯이 직접 쓰기 화면을 연다.
  final Future<void> Function(MailDraft draft)? onReply;
  const MailReader({
    super.key,
    required this.session,
    required this.api,
    required this.account,
    required this.folder,
    required this.uid,
    required this.folders,
    required this.onChanged,
    required this.onGone,
    this.onReply,
  });

  @override
  State<MailReader> createState() => _MailReaderState();
}

class _MailReaderState extends State<MailReader> {
  MailMessage? _message;
  String? _error;
  bool _flagged = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final m = await widget.api.message(widget.folder, widget.uid);
      if (!mounted) return;
      setState(() {
        _message = m;
        _flagged = m.flagged;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is ApiException ? e.message : '$e');
      }
    }
  }

  Future<void> _reply(MailReplyKind kind) async {
    final m = _message;
    if (m == null) return;
    final draft = draftFrom(
      m,
      kind,
      folder: widget.folder,
      myEmail: widget.account.email,
    );
    if (widget.onReply != null) {
      await widget.onReply!(draft);
      return;
    }
    final sent = await showMailCompose(
      context,
      session: widget.session,
      api: widget.api,
      draft: draft,
    );
    if (sent && mounted) {
      showAppToast(context, '메일을 보냈습니다.');
      widget.onChanged();
    }
  }

  Future<void> _toggleFlag() async {
    final next = !_flagged;
    setState(() => _flagged = next);
    try {
      await widget.api.setFlags(widget.folder, [widget.uid], flagged: next);
      widget.onChanged();
    } catch (e) {
      if (!mounted) return;
      setState(() => _flagged = !next);
      showAppToast(context, e is ApiException ? e.message : '$e');
    }
  }

  Future<void> _markUnread() async {
    try {
      await widget.api.setFlags(widget.folder, [widget.uid], seen: false);
      widget.onChanged();
      if (mounted) showAppToast(context, '안 읽음으로 바꿨습니다.');
    } catch (e) {
      if (mounted) showAppToast(context, e is ApiException ? e.message : '$e');
    }
  }

  Future<void> _move(String to) async {
    try {
      await widget.api.move(widget.folder, [widget.uid], to);
      if (!mounted) return;
      showAppToast(context, '옮겼습니다.');
      widget.onGone();
    } catch (e) {
      if (mounted) showAppToast(context, e is ApiException ? e.message : '$e');
    }
  }

  Future<void> _delete() async {
    try {
      final result = await widget.api.delete(widget.folder, [widget.uid]);
      if (!mounted) return;
      showAppToast(context, result == 'trash' ? '휴지통으로 옮겼습니다.' : '메일을 지웠습니다.');
      widget.onGone();
    } catch (e) {
      if (mounted) showAppToast(context, e is ApiException ? e.message : '$e');
    }
  }

  Future<void> _download(MailAttachment a) async {
    try {
      final path = await widget.session.downloadAuthedFile(
        MailApi.attachmentPath(widget.folder, widget.uid, a.index),
        fileName: a.fileName,
      );
      final notice = await openLocalFile(path);
      if (notice != null && mounted) showAppToast(context, notice);
    } catch (e) {
      if (mounted) showAppToast(context, '첨부를 열지 못했습니다: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = _message;
    if (m == null) {
      return Center(
        child: _error != null
            ? Padding(padding: const EdgeInsets.all(24), child: Text(_error!))
            : const CircularProgressIndicator(),
      );
    }
    String people(List<MailAddress> list) => list.map((a) => a.wire).join(', ');
    final moveTargets = [
      for (final f in widget.folders)
        if (f.path != widget.folder) f,
    ];
    return ListView(
      key: const ValueKey('mail-reader'),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SelectableText(
                m.subject,
                key: const ValueKey('mail-reader-subject'),
                style: theme.textTheme.titleLarge,
              ),
            ),
            IconButton(
              key: const ValueKey('mail-reader-flag'),
              tooltip: _flagged ? '중요 표시 끄기' : '중요 표시',
              icon: Icon(
                _flagged ? Icons.star : Icons.star_border,
                color: _flagged ? Colors.amber : null,
              ),
              onPressed: _toggleFlag,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('보낸 사람: ${m.from.wire}', key: const ValueKey('mail-reader-from')),
        if (m.to.isNotEmpty)
          Text(
            '받는 사람: ${people(m.to)}',
            style: TextStyle(color: theme.hintColor),
          ),
        if (m.cc.isNotEmpty)
          Text('참조: ${people(m.cc)}', style: TextStyle(color: theme.hintColor)),
        if (m.date != null)
          Text(
            mailQuoteTime(m.date),
            style: TextStyle(fontSize: 12, color: theme.hintColor),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('mail-reply'),
              onPressed: () => _reply(MailReplyKind.reply),
              icon: const Icon(Icons.reply, size: 18),
              label: const Text('답장'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('mail-reply-all'),
              onPressed: () => _reply(MailReplyKind.replyAll),
              icon: const Icon(Icons.reply_all, size: 18),
              label: const Text('전체 답장'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('mail-forward'),
              onPressed: () => _reply(MailReplyKind.forward),
              icon: const Icon(Icons.forward, size: 18),
              label: const Text('전달'),
            ),
            IconButton(
              key: const ValueKey('mail-unread'),
              tooltip: '안 읽음으로',
              icon: const Icon(Icons.mark_email_unread_outlined),
              onPressed: _markUnread,
            ),
            if (moveTargets.isNotEmpty)
              PopupMenuButton<String>(
                key: const ValueKey('mail-move'),
                tooltip: '옮기기',
                icon: const Icon(Icons.drive_file_move_outline),
                onSelected: _move,
                itemBuilder: (_) => [
                  for (final f in moveTargets)
                    PopupMenuItem(
                      key: ValueKey('mail-move-${f.path}'),
                      value: f.path,
                      child: Text(f.name),
                    ),
                ],
              ),
            IconButton(
              key: const ValueKey('mail-delete'),
              tooltip: '지우기',
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
          ],
        ),
        if (m.attachments.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final a in m.attachments)
                ActionChip(
                  key: ValueKey('mail-attachment-${a.index}'),
                  avatar: const Icon(Icons.download, size: 16),
                  label: Text('${a.fileName} (${mailSizeText(a.size)})'),
                  onPressed: () => _download(a),
                ),
            ],
          ),
        ],
        const Divider(height: 24),
        if (m.wasHtml)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'HTML 메일을 글자로 보여 줍니다(그림·서식은 빠짐).',
              style: TextStyle(fontSize: 12, color: theme.hintColor),
            ),
          ),
        SelectableText(m.text, key: const ValueKey('mail-reader-body')),
        if (m.truncated)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '본문이 길어 앞부분만 보여 줍니다.',
              style: TextStyle(fontSize: 12, color: theme.hintColor),
            ),
          ),
      ],
    );
  }
}
