import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/mail.dart';
import '../../services/api_client.dart' show ApiException;
import '../../services/download_storage.dart' show openLocalFile;
import '../../services/mail_api.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import 'mail_account_dialog.dart';
import 'mail_compose.dart';
import 'mail_rich_view.dart';
import 'mail_settings_dialogs.dart';
import 'mail_share.dart';
import '../../l10n/tr.dart';

/// 메일 화면을 연다 — PC·모바일 모두 전체 화면.
Future<void> openMailScreen(BuildContext context, Session session) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => MailScreen(session: session)),
    );

/// 이 폭부터 폴더 · 목록 · 읽기 세 칸(좁으면 목록에서 눌러 읽기 화면으로 넘어간다).
const kMailWideBreakpoint = 900.0;

/// 한 사람이 연결할 수 있는 계정 수 — 서버 webmailRules.js ACCOUNTS_MAX.
const kMailAccountsMax = 5;

/// 메일 본문의 바깥 링크를 여는 곳 — 시험에서 바꿔 끼운다.
Future<bool> Function(Uri uri) mailOpenLink = (uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// 웹메일 — 연결한 메일 계정들(IMAP/SMTP·OAuth·회사 메일함)의 폴더·목록·읽기·쓰기(server/src/webmail.js). 계정이 여럿이면 폴더 칸
/// 위에서 바꾼다. 계정이 없으면 연결 안내. 새 메일이 오면(session.mailEvents — 소켓 mail:new·mail:changed) 목록을 다시 받는다.
class MailScreen extends StatefulWidget {
  final Session session;

  /// 시험에서 가짜 API를 끼울 때. 기본은 세션의 것.
  final MailApi? api;
  const MailScreen({super.key, required this.session, this.api});

  @override
  State<MailScreen> createState() => _MailScreenState();
}

class _MailScreenState extends State<MailScreen> {
  late final MailApi _api = widget.api ?? widget.session.mailApi;

  bool _loadingAccount = true;
  List<MailAccount> _accounts = const [];

  /// 계정이 하나뿐인 예전 서버(/mail/account — 계정 id가 없다).
  bool _legacy = false;
  String _accountId = '';
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

  MailAccount? get _account {
    for (final a in _accounts) {
      if (a.id == _accountId) return a;
    }
    return _accounts.firstOrNull;
  }

  @override
  void initState() {
    super.initState();
    _loadAccounts();
    _sub = widget.session.mailEvents.listen((_) => _loadAccounts(quiet: true));
  }

  @override
  void dispose() {
    _sub?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadAccounts({bool quiet = false}) async {
    try {
      final list = await _api.accountList();
      if (!mounted) return;
      final keep = list.accounts.any((a) => a.id == _accountId);
      setState(() {
        _accounts = list.accounts;
        _legacy = list.legacy;
        if (!keep) {
          _accountId = list.accounts.firstOrNull?.id ?? '';
          _folder = 'INBOX';
          _selectedUid = null;
        }
        _loadingAccount = false;
        if (!quiet) _error = null;
      });
      if (list.accounts.isNotEmpty) await _refresh();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingAccount = false;
          _error = e is ApiException ? trServer(e.message) : '$e';
        });
      }
    }
  }

  Future<void> _refresh() async {
    if (_account == null) return;
    await Future.wait([_loadFolders(), _loadMessages()]);
  }

  Future<void> _loadFolders() async {
    final account = _accountId;
    try {
      final folders = await _api.folders(account);
      if (!mounted || account != _accountId) return;
      setState(() => _folders = folders);
      unawaited(widget.session.refreshMailUnread());
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is ApiException ? trServer(e.message) : '$e');
      }
    }
  }

  Future<void> _loadMessages() async {
    final account = _accountId;
    setState(() => _loadingList = true);
    try {
      final page = await _api.messages(
        account,
        _folder,
        query: _query.isEmpty ? null : _query,
      );
      if (!mounted || account != _accountId) return;
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
          _error = e is ApiException ? trServer(e.message) : '$e';
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
        _accountId,
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
      if (mounted) {
        showAppToast(context, e is ApiException ? trServer(e.message) : '$e');
      }
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

  void _switchAccount(String id) {
    if (id == _accountId) return;
    setState(() {
      _accountId = id;
      _folder = 'INBOX';
      _folders = const [];
      _messages = const [];
      _selectedUid = null;
      _query = '';
      _search.clear();
      _error = null;
    });
    _refresh();
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
    if (inbox?.path == _folder && widget.session.mailUnread > 0) {
      widget.session.setMailUnread(widget.session.mailUnread - 1);
    }
  }

  MailReader _reader(
    int uid, {
    required VoidCallback onGone,
    bool wide = true,
  }) => MailReader(
    key: ValueKey('reader-$_accountId-$_folder-$uid'),
    session: widget.session,
    api: _api,
    account: _account!,
    accounts: _accounts,
    folder: _folder,
    uid: uid,
    folders: _folders,
    onChanged: _refresh,
    onReply: wide ? _compose : null,
    onAccountChanged: _replaceAccount,
    onGone: onGone,
  );

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
          body: _reader(
            m.uid,
            wide: false,
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
    final outcome = await showMailCompose(
      context,
      session: widget.session,
      api: _api,
      draft: MailDraft(
        to: draft.to,
        cc: draft.cc,
        bcc: draft.bcc,
        subject: draft.subject,
        text: draft.text,
        inReplyTo: draft.inReplyTo,
        references: draft.references,
        answered: draft.answered,
        saved: draft.saved,
        savedAttachments: draft.savedAttachments,
        accountId: draft.accountId ?? _accountId,
        signatureSlot: draft.signatureSlot,
      ),
      accounts: _accounts,
    );
    if (!mounted) return;
    if (outcome == MailComposeOutcome.sent) {
      showAppToast(context, tr('메일을 보냈습니다.'));
    }
    if (outcome != MailComposeOutcome.closed) {
      if (draft.saved != null) setState(() => _selectedUid = null);
      _refresh();
    }
  }

  void _replaceAccount(MailAccount next) {
    setState(() {
      _accounts = [for (final a in _accounts) a.id == next.id ? next : a];
    });
  }

  /// 계정 연결(새 계정 — [edit]면 지금 계정 바꾸기).
  Future<void> _connect({bool edit = false}) async {
    final current = edit ? _account : null;
    final account = await showMailAccountDialog(
      context,
      api: _api,
      current: current,
      legacy: _legacy,
    );
    if (account == null || !mounted) return;
    setState(() {
      final i = _accounts.indexWhere((a) => a.id == account.id);
      _accounts = i >= 0
          ? [for (final a in _accounts) a.id == account.id ? account : a]
          : [..._accounts, account];
      _accountId = account.id;
      _folder = 'INBOX';
      _selectedUid = null;
      _error = null;
    });
    showAppToast(
      context,
      tr('{account.email}을(를) 연결했습니다.', {'account.email': account.email}),
    );
    _refresh();
    widget.session.refreshMailUnread();
  }

  Future<void> _disconnect() async {
    final account = _account;
    if (account == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('메일 계정 연결을 끊을까요?')),
        content: Text(
          tr('{email} — 서버에 둔 연결 값과 비밀번호를 지웁니다. 메일 자체는 원래 메일 서버에 그대로 남습니다.', {
            'email': account.email,
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('취소')),
          ),
          FilledButton(
            key: const ValueKey('mail-disconnect-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('끊기')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _api.disconnect(account.id);
      if (!mounted) return;
      setState(() {
        _accounts = [
          for (final a in _accounts)
            if (a.id != account.id) a,
        ];
        _accountId = _accounts.firstOrNull?.id ?? '';
        _folders = const [];
        _messages = const [];
        _selectedUid = null;
        _folder = 'INBOX';
      });
      unawaited(widget.session.refreshMailUnread());
      _refresh();
    } catch (e) {
      if (mounted) {
        showAppToast(context, e is ApiException ? trServer(e.message) : '$e');
      }
    }
  }

  Future<void> _toggleNotify() async {
    final account = _account;
    if (account == null) return;
    try {
      final next = await _api.setNotify(account.id, !account.notify);
      if (!mounted) return;
      _replaceAccount(next);
      showAppToast(
        context,
        next.notify ? tr('새 메일 알림을 켰습니다.') : tr('새 메일 알림을 껐습니다.'),
      );
    } catch (e) {
      if (mounted) {
        showAppToast(context, e is ApiException ? trServer(e.message) : '$e');
      }
    }
  }

  Future<void> _signature() async {
    final account = _account;
    if (account == null) return;
    final next = await showMailSignatureDialog(
      context,
      api: _api,
      account: account,
    );
    if (next == null || !mounted) return;
    _replaceAccount(next);
    showAppToast(context, tr('서명을 저장했습니다.'));
  }

  Future<void> _rules() async {
    final account = _account;
    if (account == null) return;
    await showMailRulesDialog(
      context,
      api: _api,
      account: account,
      folders: _folders,
    );
    if (mounted) _refresh();
  }

  /// 지금 계정을 기본(맨 앞)으로.
  Future<void> _makeDefault() async {
    final account = _account;
    if (account == null) return;
    try {
      final next = await _api.reorder([
        account.id,
        for (final a in _accounts)
          if (a.id != account.id) a.id,
      ]);
      if (!mounted) return;
      setState(() => _accounts = next);
      showAppToast(
        context,
        tr('{email}을(를) 기본 계정으로 했습니다.', {'email': account.email}),
      );
    } catch (e) {
      if (mounted) {
        showAppToast(context, e is ApiException ? trServer(e.message) : '$e');
      }
    }
  }

  String get _folderName =>
      _folders.where((f) => f.path == _folder).firstOrNull?.name ??
      (_folder == 'INBOX' ? tr('받은편지함') : _folder);

  IconData _folderIcon(MailFolder f) => switch (f.specialUse) {
    r'\Inbox' => Icons.inbox_outlined,
    r'\Sent' => Icons.send_outlined,
    r'\Drafts' => Icons.drafts_outlined,
    r'\Junk' => Icons.report_gmailerrorred_outlined,
    r'\Trash' => Icons.delete_outline,
    r'\Archive' || r'\All' => Icons.archive_outlined,
    _ => Icons.folder_outlined,
  };

  IconData _accountIcon(MailAccount a) => a.isLocal
      ? Icons.domain
      : a.isOAuth
      ? Icons.verified_user_outlined
      : Icons.alternate_email;

  /// 폴더 칸 머리 — 지금 계정(여럿이면 눌러서 바꾸기·더하기).
  Widget _accountHeader() {
    final account = _account!;
    final theme = Theme.of(context);
    final canAdd = !_legacy && _accounts.length < kMailAccountsMax;
    final label = Row(
      children: [
        Icon(_accountIcon(account), size: 18, color: theme.hintColor),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                account.email,
                style: theme.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
              if (account.providerLabel.isNotEmpty)
                Text(
                  account.providerLabel,
                  style: TextStyle(fontSize: 11, color: theme.hintColor),
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        if (_accounts.length > 1 || canAdd)
          Icon(Icons.unfold_more, size: 18, color: theme.hintColor),
      ],
    );
    if (_accounts.length <= 1 && !canAdd) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: label,
      );
    }
    return PopupMenuButton<String>(
      key: const ValueKey('mail-account-switch'),
      tooltip: tr('계정 바꾸기'),
      onSelected: (v) => v == '+' ? _connect() : _switchAccount(v),
      itemBuilder: (_) => [
        for (final a in _accounts)
          CheckedPopupMenuItem(
            key: ValueKey('mail-account-${a.email}'),
            value: a.id,
            checked: a.id == account.id,
            child: Text(a.email, overflow: TextOverflow.ellipsis),
          ),
        if (canAdd) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            key: const ValueKey('mail-account-add'),
            value: '+',
            child: Text(tr('계정 더하기')),
          ),
        ],
      ],
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
        child: label,
      ),
    );
  }

  Widget _folderList({VoidCallback? afterTap}) => ListView(
    key: const ValueKey('mail-folders'),
    children: [
      _accountHeader(),
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
            _query.isNotEmpty
                ? tr('"{_query}"에 맞는 메일이 없습니다.', {'_query': _query})
                : tr('메일이 없습니다.'),
            style: TextStyle(color: theme.hintColor),
          ),
        ),
      );
    }
    final current = _folders.where((f) => f.path == _folder).firstOrNull;
    final toSide = (current?.isSent ?? false) || (current?.isDrafts ?? false);
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
                        child: Text(tr('더 보기')),
                      ),
              ),
            );
          }
          final m = _messages[i];
          final who = toSide
              ? (m.to.isEmpty
                    ? (m.draft ? tr('(받는 사람 없음)') : '')
                    : tr('받는 사람: {m.to.first.label}', {
                        'm.to.first.label': m.to.first.label,
                      }))
              : m.from.label;
          final bold = TextStyle(
            fontWeight: m.seen ? FontWeight.normal : FontWeight.w700,
          );
          return ListTile(
            key: ValueKey('mail-item-${m.uid}'),
            selected: wide && _selectedUid == m.uid,
            leading: Icon(
              m.draft
                  ? Icons.edit_note
                  : m.seen
                  ? Icons.drafts_outlined
                  : Icons.mail,
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
                if (m.draft)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(
                      tr('[임시]'),
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                if (m.answered)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(Icons.reply, size: 14, color: theme.hintColor),
                  ),
                Expanded(
                  child: Text(
                    m.subject.isEmpty ? tr('(제목 없음)') : m.subject,
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
        appBar: AppBar(title: Text(tr('메일'))),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final account = _account;
    if (account == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr('메일'))),
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
                      ? tr('이 서버 버전은 메일을 지원하지 않습니다. 서버를 업데이트하세요.')
                      : tr(
                          '쓰고 있는 메일 계정(회사 메일·네이버·Gmail 등)을 연결하면 여기서 메일을 받고 보낼 수 있습니다.',
                        ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const ValueKey('mail-connect'),
                  onPressed: _connect,
                  icon: const Icon(Icons.link),
                  label: Text(tr('메일 계정 연결')),
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
          hintText: tr('메일 찾기'),
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  tooltip: tr('찾기 지우기'),
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
    final canAdd = !_legacy && _accounts.length < kMailAccountsMax;
    final appBar = AppBar(
      title: Text(tr('메일 · {_folderName}', {'_folderName': _folderName})),
      actions: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: searchField,
        ),
        IconButton(
          key: const ValueKey('mail-refresh'),
          tooltip: tr('새로고침'),
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
              label: Text(tr('메일 쓰기')),
            ),
          ),
        PopupMenuButton<String>(
          key: const ValueKey('mail-menu'),
          tooltip: tr('계정'),
          onSelected: (v) => switch (v) {
            'edit' => _connect(edit: true),
            'signature' => _signature(),
            'rules' => _rules(),
            'notify' => _toggleNotify(),
            'default' => _makeDefault(),
            'add' => _connect(),
            'disconnect' => _disconnect(),
            _ => null,
          },
          itemBuilder: (_) => [
            if (!account.isLocal)
              PopupMenuItem(value: 'edit', child: Text(tr('계정 바꾸기'))),
            if (!_legacy) ...[
              PopupMenuItem(
                key: const ValueKey('mail-menu-signature'),
                value: 'signature',
                child: Text(tr('서명')),
              ),
              PopupMenuItem(
                key: const ValueKey('mail-menu-rules'),
                value: 'rules',
                child: Text(tr('받는 규칙')),
              ),
            ],
            PopupMenuItem(
              value: 'notify',
              child: Text(account.notify ? tr('새 메일 알림 끄기') : tr('새 메일 알림 켜기')),
            ),
            if (_accounts.length > 1 && _accounts.first.id != account.id)
              PopupMenuItem(
                key: const ValueKey('mail-menu-default'),
                value: 'default',
                child: Text(tr('기본 계정으로')),
              ),
            if (canAdd)
              PopupMenuItem(
                key: const ValueKey('mail-menu-add'),
                value: 'add',
                child: Text(tr('계정 더하기')),
              ),
            if (!account.isLocal)
              PopupMenuItem(value: 'disconnect', child: Text(tr('연결 끊기'))),
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
                if (account.lastError != null && !account.isLocal)
                  TextButton(
                    onPressed: () => _connect(edit: true),
                    child: Text(tr('계정 바꾸기')),
                  ),
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
          tooltip: tr('메일 쓰기'),
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
                SizedBox(width: 240, child: _folderList()),
                const VerticalDivider(width: 1),
                SizedBox(width: 380, child: _messageList(wide: true)),
                const VerticalDivider(width: 1),
                Expanded(
                  child: selected == null
                      ? Center(
                          child: Text(
                            tr('왼쪽에서 메일을 고르세요.'),
                            style: TextStyle(color: theme.hintColor),
                          ),
                        )
                      : _reader(
                          selected,
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

/// 메일 하나 읽기 — 머리(보낸 사람·받는 사람·참조·시각), 답장·전체 답장·전달·중요·안 읽음·옮기기·지우기·대화방으로·할 일로, 첨부,
/// 본문(HTML 메일은 걸러 낸 서식 그대로 — 바깥 그림은 "그림 보기"를 눌러야, "글자로 보기"로 바꿀 수 있음). 임시 저장본이면 "이어 쓰기".
class MailReader extends StatefulWidget {
  final Session session;
  final MailApi api;
  final MailAccount account;

  /// 쓰기 창의 보내는 계정 후보.
  final List<MailAccount> accounts;
  final String folder;
  final int uid;
  final List<MailFolder> folders;

  /// 읽음·중요가 바뀌었을 때(목록을 다시 받게).
  final VoidCallback onChanged;

  /// 옮기거나 지워서 이 폴더에서 없어졌을 때.
  final VoidCallback onGone;

  /// 답장·전달·이어 쓰기 — 없으면 이 위젯이 직접 쓰기 화면을 연다.
  final Future<void> Function(MailDraft draft)? onReply;

  /// 계정 설정이 바뀌었을 때(그림을 늘 볼 보낸 사람).
  final ValueChanged<MailAccount>? onAccountChanged;
  const MailReader({
    super.key,
    required this.session,
    required this.api,
    required this.account,
    this.accounts = const [],
    required this.folder,
    required this.uid,
    required this.folders,
    required this.onChanged,
    required this.onGone,
    this.onReply,
    this.onAccountChanged,
  });

  @override
  State<MailReader> createState() => _MailReaderState();
}

class _MailReaderState extends State<MailReader> {
  MailMessage? _message;
  String? _error;
  bool _flagged = false;
  bool _plain = false;
  bool _showImages = false;

  String get _accountId => widget.account.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final m = await widget.api.message(_accountId, widget.folder, widget.uid);
      if (!mounted) return;
      setState(() {
        _message = m;
        _flagged = m.flagged;
        _showImages = widget.account.trusts(m.from.address);
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is ApiException ? trServer(e.message) : '$e');
      }
    }
  }

  Future<void> _openDraft(MailDraft draft) async {
    if (widget.onReply != null) {
      await widget.onReply!(draft);
      return;
    }
    final outcome = await showMailCompose(
      context,
      session: widget.session,
      api: widget.api,
      draft: draft,
      accounts: widget.accounts,
    );
    if (!mounted) return;
    if (outcome == MailComposeOutcome.sent) {
      showAppToast(context, tr('메일을 보냈습니다.'));
    }
    if (outcome != MailComposeOutcome.closed) {
      if (draft.saved != null) {
        widget.onGone();
      } else {
        widget.onChanged();
      }
    }
  }

  Future<void> _reply(MailReplyKind kind) async {
    final m = _message;
    if (m == null) return;
    await _openDraft(
      draftFrom(
        m,
        kind,
        folder: widget.folder,
        myEmail: widget.account.email,
        accountId: _accountId,
      ),
    );
  }

  Future<void> _resume() async {
    final m = _message;
    if (m == null) return;
    await _openDraft(
      draftFromSaved(m, folder: widget.folder, accountId: _accountId),
    );
  }

  Future<void> _toggleFlag() async {
    final next = !_flagged;
    setState(() => _flagged = next);
    try {
      await widget.api.setFlags(_accountId, widget.folder, [
        widget.uid,
      ], flagged: next);
      widget.onChanged();
    } catch (e) {
      if (!mounted) return;
      setState(() => _flagged = !next);
      showAppToast(context, e is ApiException ? trServer(e.message) : '$e');
    }
  }

  Future<void> _markUnread() async {
    try {
      await widget.api.setFlags(_accountId, widget.folder, [
        widget.uid,
      ], seen: false);
      widget.onChanged();
      if (mounted) showAppToast(context, tr('안 읽음으로 바꿨습니다.'));
    } catch (e) {
      if (mounted) {
        showAppToast(context, e is ApiException ? trServer(e.message) : '$e');
      }
    }
  }

  Future<void> _move(String to) async {
    try {
      await widget.api.move(_accountId, widget.folder, [widget.uid], to);
      if (!mounted) return;
      showAppToast(context, tr('옮겼습니다.'));
      widget.onGone();
    } catch (e) {
      if (mounted) {
        showAppToast(context, e is ApiException ? trServer(e.message) : '$e');
      }
    }
  }

  Future<void> _delete() async {
    try {
      final result = await widget.api.delete(_accountId, widget.folder, [
        widget.uid,
      ]);
      if (!mounted) return;
      showAppToast(
        context,
        result == 'trash' ? tr('휴지통으로 옮겼습니다.') : tr('메일을 지웠습니다.'),
      );
      widget.onGone();
    } catch (e) {
      if (mounted) {
        showAppToast(context, e is ApiException ? trServer(e.message) : '$e');
      }
    }
  }

  Future<void> _download(MailAttachment a) async {
    try {
      final path = await widget.session.downloadAuthedFile(
        MailApi.attachmentPath(_accountId, widget.folder, widget.uid, a.index),
        fileName: a.fileName,
      );
      final notice = await openLocalFile(path);
      if (notice != null && mounted) showAppToast(context, notice);
    } catch (e) {
      if (mounted) showAppToast(context, tr('첨부를 열지 못했습니다: {e}', {'e': e}));
    }
  }

  /// 이 보낸 사람의 바깥 그림을 늘 보기.
  Future<void> _trustSender() async {
    final m = _message;
    if (m == null || m.from.address.isEmpty) return;
    setState(() => _showImages = true);
    try {
      final next = await widget.api.trustSender(_accountId, m.from.address);
      widget.onAccountChanged?.call(next);
      if (mounted) {
        showAppToast(
          context,
          tr('{from}이(가) 보낸 메일은 그림을 늘 보여 줍니다.', {'from': m.from.address}),
        );
      }
    } catch (e) {
      if (mounted) {
        showAppToast(context, e is ApiException ? trServer(e.message) : '$e');
      }
    }
  }

  /// 본문 링크 — mailto는 쓰기 창으로, 웹 주소는 실제 주소를 보이고 물은 뒤 브라우저로(글자와 다른 곳으로 보내는 피싱 막기).
  Future<void> _openLink(String href) async {
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    if (uri.scheme == 'mailto') {
      final address = uri.path;
      if (address.isEmpty) return;
      await _openDraft(
        MailDraft(
          to: [MailAddress(address: address)],
          subject: uri.queryParameters['subject'] ?? '',
          accountId: _accountId,
        ),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('이 주소를 열까요?')),
        content: SelectableText(href, key: const ValueKey('mail-link-url')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('취소')),
          ),
          FilledButton(
            key: const ValueKey('mail-link-open'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('열기')),
          ),
        ],
      ),
    );
    if (ok == true) await mailOpenLink(uri);
  }

  Future<void> _toRoom() async {
    final m = _message;
    if (m == null) return;
    final room = await showMailToRoom(
      context,
      session: widget.session,
      api: widget.api,
      account: _accountId,
      folder: widget.folder,
      message: m,
    );
    if (room != null && mounted) {
      showAppToast(context, tr('{room}에 보냈습니다.', {'room': room.name}));
    }
  }

  Future<void> _toTodo() async {
    final m = _message;
    if (m == null) return;
    final made = await createTodoFromMail(
      context,
      session: widget.session,
      api: widget.api,
      account: _accountId,
      folder: widget.folder,
      message: m,
    );
    if (made && mounted) showAppToast(context, tr('할 일을 만들었습니다.'));
  }

  Widget _imagesBanner(MailMessage m) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('mail-images-banner'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          Text(
            tr('바깥 그림 {n}개를 가렸습니다(열면 보낸 쪽이 읽었는지 알 수 있습니다).', {
              'n': m.remoteImages,
            }),
            style: const TextStyle(fontSize: 12),
          ),
          TextButton(
            key: const ValueKey('mail-show-images'),
            onPressed: () => setState(() => _showImages = true),
            child: Text(tr('그림 보기')),
          ),
          if (m.from.address.isNotEmpty)
            TextButton(
              key: const ValueKey('mail-trust-sender'),
              onPressed: _trustSender,
              child: Text(tr('이 보낸 사람은 늘 보기')),
            ),
        ],
      ),
    );
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
    final rich = m.rich;
    final showRich = rich != null && !_plain;
    return ListView(
      key: const ValueKey('mail-reader'),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SelectableText(
                m.subject.isEmpty ? tr('(제목 없음)') : m.subject,
                key: const ValueKey('mail-reader-subject'),
                style: theme.textTheme.titleLarge,
              ),
            ),
            IconButton(
              key: const ValueKey('mail-reader-flag'),
              tooltip: _flagged ? tr('중요 표시 끄기') : tr('중요 표시'),
              icon: Icon(
                _flagged ? Icons.star : Icons.star_border,
                color: _flagged ? Colors.amber : null,
              ),
              onPressed: _toggleFlag,
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (!m.draft || m.from.address.isNotEmpty)
          Text(
            tr('보낸 사람: {m.from.wire}', {'m.from.wire': m.from.wire}),
            key: const ValueKey('mail-reader-from'),
          ),
        if (m.to.isNotEmpty)
          Text(
            tr('받는 사람: {p0}', {'p0': people(m.to)}),
            style: TextStyle(color: theme.hintColor),
          ),
        if (m.cc.isNotEmpty)
          Text(
            tr('참조: {p0}', {'p0': people(m.cc)}),
            style: TextStyle(color: theme.hintColor),
          ),
        if (m.bcc.isNotEmpty)
          Text(
            tr('숨은 참조: {p0}', {'p0': people(m.bcc)}),
            style: TextStyle(color: theme.hintColor),
          ),
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
            if (m.draft)
              FilledButton.icon(
                key: const ValueKey('mail-resume-draft'),
                onPressed: _resume,
                icon: const Icon(Icons.edit, size: 18),
                label: Text(tr('이어 쓰기')),
              )
            else ...[
              OutlinedButton.icon(
                key: const ValueKey('mail-reply'),
                onPressed: () => _reply(MailReplyKind.reply),
                icon: const Icon(Icons.reply, size: 18),
                label: Text(tr('답장')),
              ),
              OutlinedButton.icon(
                key: const ValueKey('mail-reply-all'),
                onPressed: () => _reply(MailReplyKind.replyAll),
                icon: const Icon(Icons.reply_all, size: 18),
                label: Text(tr('전체 답장')),
              ),
              OutlinedButton.icon(
                key: const ValueKey('mail-forward'),
                onPressed: () => _reply(MailReplyKind.forward),
                icon: const Icon(Icons.forward, size: 18),
                label: Text(tr('전달')),
              ),
              IconButton(
                key: const ValueKey('mail-unread'),
                tooltip: tr('안 읽음으로'),
                icon: const Icon(Icons.mark_email_unread_outlined),
                onPressed: _markUnread,
              ),
            ],
            if (moveTargets.isNotEmpty)
              PopupMenuButton<String>(
                key: const ValueKey('mail-move'),
                tooltip: tr('옮기기'),
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
              tooltip: tr('지우기'),
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
            if (!m.draft)
              PopupMenuButton<String>(
                key: const ValueKey('mail-share'),
                tooltip: tr('보내기'),
                icon: const Icon(Icons.more_horiz),
                onSelected: (v) => v == 'room' ? _toRoom() : _toTodo(),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    key: const ValueKey('mail-to-room'),
                    value: 'room',
                    child: Text(tr('대화방으로 보내기')),
                  ),
                  PopupMenuItem(
                    key: const ValueKey('mail-to-todo'),
                    value: 'todo',
                    child: Text(tr('할 일로 만들기')),
                  ),
                ],
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
        if (rich != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const ValueKey('mail-view-toggle'),
              onPressed: () => setState(() => _plain = !_plain),
              icon: Icon(
                _plain ? Icons.article_outlined : Icons.notes,
                size: 16,
              ),
              label: Text(_plain ? tr('서식으로 보기') : tr('글자로 보기')),
            ),
          ),
        if (showRich && m.remoteImages > 0 && !_showImages) _imagesBanner(m),
        if (showRich)
          MailRichView(
            doc: rich,
            showRemoteImages: _showImages,
            cidPath: (index) => MailApi.inlinePath(
              _accountId,
              widget.folder,
              widget.uid,
              index,
            ),
            remotePath: MailApi.remoteImagePath,
            loadBytes: widget.api.bytes,
            onLink: _openLink,
          )
        else ...[
          if (m.wasHtml && rich == null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                tr('HTML 메일을 글자로 보여 줍니다(그림·서식은 빠짐).'),
                style: TextStyle(fontSize: 12, color: theme.hintColor),
              ),
            ),
          SelectableText(m.text, key: const ValueKey('mail-reader-body')),
        ],
        if (m.truncated || (showRich && m.richTruncated))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              showRich
                  ? tr('본문이 길어 앞부분만 서식으로 보여 줍니다. 전부 보려면 "글자로 보기"를 누르세요.')
                  : tr('본문이 길어 앞부분만 보여 줍니다.'),
              style: TextStyle(fontSize: 12, color: theme.hintColor),
            ),
          ),
      ],
    );
  }
}
