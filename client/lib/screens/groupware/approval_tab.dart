import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../models/groupware.dart';
import '../../models/groupware_finance.dart';
import '../../services/download_storage.dart';
import '../../services/groupware_api.dart';
import '../../services/session.dart';
import '../../services/time_format.dart';
import '../../widgets/app_toast.dart';
import 'approval_form_widgets.dart';
import 'approval_forms.dart'
    show settleDiffText, showExpenseRequestDialog, toastSubmitted;
import 'approval_print.dart';
import 'approval_settings.dart';
import 'groupware_screen.dart';
import '../../l10n/tr.dart';

/// 결재 탭 — 결재함(결재할 문서 · 내가 올린 문서 · 결재한 문서 · 참조 문서 · 관리자는 전체 문서). 줄을 누르면 문서 상세.
class ApprovalTab extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final GroupwareChanges changes;
  final Session session;
  const ApprovalTab({
    super.key,
    required this.api,
    required this.ctx,
    required this.changes,
    required this.session,
  });

  @override
  State<ApprovalTab> createState() => _ApprovalTabState();
}

class _ApprovalTabState extends State<ApprovalTab> {
  late ApprovalBox _box = widget.ctx.pendingForMe > 0
      ? ApprovalBox.inbox
      : ApprovalBox.mine;
  List<ApprovalDocument>? _docs;
  String? _error;
  int _loadSeq = 0;

  /// "정산 안 됨" 거르기 — 승인됐는데 살아 있는 정산이 없는 구매 요청·출장 신청만(서버 ?unsettled=1). "내가 올린 문서"(내 것)와
  /// 관리자의 "전체 문서"(모두의 것)에서만 고를 수 있고, 다른 함으로 옮기면 꺼진다.
  bool _unsettled = false;

  /// 지금 함에서 "정산 안 됨" 거르기를 고를 수 있는지.
  bool get _canFilterUnsettled =>
      _box == ApprovalBox.mine ||
      (_box == ApprovalBox.all && widget.ctx.isManager);

  /// 서버가 한 번에 주는 문서 수(listApprovalDocuments limit) — 이만큼 왔으면 "더 보기"로 마지막 문서보다 먼저 올린 것을 더 받는다.
  static const _pageSize = 50;
  bool _hasMore = false;
  bool _loadingMore = false;

  /// 검색 — 제목·문서 번호·올린 사람(서버 ?q=, 100자까지)과 올린 날 기간(?from=&to=), 종류·상태. 보관함에서는 늘 보이고, 다른 함에서는
  /// 돋보기로 열어 같은 조건으로 거른다(닫으면 조건을 지운다). 입력칸 글은 엔터·검색 단추를 눌러야 [_q]로 들어간다.
  final _search = TextEditingController();
  bool _searchOpen = false;
  String _q = '';
  DateTime? _from;
  DateTime? _to;
  ApprovalKind? _kind;
  ApprovalStatus? _status;

  /// 검색 줄이 보이는지(보이면 그 조건으로 거른다).
  bool get _showSearch => _box == ApprovalBox.archive || _searchOpen;

  /// 검색 조건을 하나라도 걸었는지.
  bool get _hasConditions =>
      _q.isNotEmpty ||
      _from != null ||
      _to != null ||
      _kind != null ||
      _status != null;

  @override
  void initState() {
    super.initState();
    widget.changes.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.changes.removeListener(_load);
    _search.dispose();
    super.dispose();
  }

  /// 지금 함·거르기·검색 조건으로 목록을 받는다 — [before]를 주면 그보다 먼저 올린 것(다음 쪽).
  Future<List<ApprovalDocument>> _fetch({DateTime? before}) {
    final search = _showSearch;
    return widget.api.documents(
      box: _box,
      unsettled: _unsettled && _canFilterUnsettled,
      before: before,
      kind: search ? _kind : null,
      status: search ? _status : null,
      q: search && _q.isNotEmpty ? _q : null,
      from: search && _from != null ? dateKeyOf(_from!) : null,
      to: search && _to != null ? dateKeyOf(_to!) : null,
    );
  }

  Future<void> _load() async {
    final seq = ++_loadSeq;
    try {
      final docs = await _fetch();
      if (mounted && seq == _loadSeq) {
        setState(() {
          _docs = docs;
          _error = null;
          _hasMore = docs.length >= _pageSize;
        });
      }
    } catch (e) {
      if (mounted && seq == _loadSeq) setState(() => _error = e.toString());
    }
  }

  /// "더 보기" — 지금 목록의 마지막 문서보다 먼저 올린 것을 이어 붙인다(그 사이에 함·조건이 바뀌었으면 버린다).
  Future<void> _loadMore() async {
    final docs = _docs;
    final before = docs == null || docs.isEmpty ? null : docs.last.createdAt;
    if (before == null || _loadingMore) return;
    final seq = _loadSeq;
    setState(() => _loadingMore = true);
    try {
      final more = await _fetch(before: before);
      if (!mounted || seq != _loadSeq) return;
      final seen = {for (final d in docs!) d.id};
      setState(() {
        _docs = [...docs, ...more.where((d) => !seen.contains(d.id))];
        _hasMore = more.length >= _pageSize;
      });
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// 조건이 바뀌었다 — 처음부터 다시 받는다.
  void _reload() {
    setState(() {
      _docs = null;
      _error = null;
      _hasMore = false;
    });
    _load();
  }

  /// 입력칸 글로 찾는다(엔터·검색 단추).
  void _submitSearch() {
    final q = _search.text.trim();
    if (q == _q && _docs != null) return;
    _q = q;
    _reload();
  }

  /// 기간 끝 하나를 고른다 — 시작이 끝보다 늦어지면 다른 쪽을 지운다(서버는 거꾸로 된 기간을 거절한다).
  Future<void> _pickDate({required bool from}) async {
    final now = DateTime.now();
    final current = from ? _from : _to;
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? now,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 1, 12, 31),
      helpText: from ? tr('언제부터') : tr('언제까지'),
    );
    if (picked == null || !mounted) return;
    if (from) {
      _from = picked;
      if (_to != null && _to!.isBefore(picked)) _to = null;
    } else {
      _to = picked;
      if (_from != null && _from!.isAfter(picked)) _from = null;
    }
    _reload();
  }

  /// 검색 조건을 모두 지운다.
  void _clearSearch() {
    _search.clear();
    _q = '';
    _from = null;
    _to = null;
    _kind = null;
    _status = null;
  }

  /// 다른 함에서 돋보기 — 열면 검색 줄을 보이고, 닫으면 조건을 지우고 다시 받는다.
  void _toggleSearch() {
    final had = _hasConditions;
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) _clearSearch();
    });
    if (!_searchOpen && had) _reload();
  }

  /// "새 결재" — 휴가·지출과 켜진 양식 중에서 골라 올린다. 올렸으면 "내가 올린 문서"로 옮겨 보여 준다.
  Future<void> _newApproval() async {
    final doc = await showNewApprovalChooser(
      context,
      api: widget.api,
      ctx: widget.ctx,
      session: widget.session,
    );
    if (doc == null || !mounted) return;
    toastSubmitted(context, doc);
    widget.changes.bump();
    if (_box != ApprovalBox.mine) _select(ApprovalBox.mine);
  }

  /// 함을 옮긴다 — 걸어 둔 검색 조건은 그대로 따라간다(보관함에서 조건을 건 채 옮기면 검색 줄을 열어 둔다).
  void _select(ApprovalBox box) {
    if (_box == ApprovalBox.archive && _hasConditions) _searchOpen = true;
    _box = box;
    if (!_canFilterUnsettled) _unsettled = false;
    _reload();
  }

  void _toggleUnsettled(bool on) {
    _unsettled = on;
    _reload();
  }

  Future<void> _open(ApprovalDocument doc) async {
    final changed = await showApprovalDetail(
      context,
      api: widget.api,
      ctx: widget.ctx,
      session: widget.session,
      documentId: doc.id,
    );
    if (changed) widget.changes.bump();
  }

  @override
  Widget build(BuildContext context) {
    final boxes = [
      ApprovalBox.inbox,
      ApprovalBox.mine,
      ApprovalBox.done,
      ApprovalBox.cc,
      if (widget.ctx.isManager) ApprovalBox.all,
      ApprovalBox.archive,
    ];
    final docs = _docs;
    // 보관함이거나 검색 조건을 건 채 비었으면 "찾는 문서가 없다".
    final searchEmpty =
        _box == ApprovalBox.archive || (_showSearch && _hasConditions);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(
            children: [
              FilledButton.icon(
                key: const ValueKey('approval-new'),
                onPressed: _newApproval,
                icon: const Icon(Icons.edit_document, size: 18),
                label: Text(tr('새 결재')),
              ),
              // 내 결재 설정 — 서명·도장, 대결(부재 중 대신 결재).
              PopupMenuButton<String>(
                key: const ValueKey('approval-settings'),
                tooltip: tr('결재 설정'),
                icon: const Icon(Icons.manage_accounts_outlined),
                onSelected: (v) => v == 'signature'
                    ? showSignatureDialog(
                        context,
                        api: widget.api,
                        session: widget.session,
                      )
                    : showDelegationsDialog(
                        context,
                        api: widget.api,
                        ctx: widget.ctx,
                        session: widget.session,
                        changes: widget.changes,
                      ),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'signature', child: Text(tr('내 서명·도장'))),
                  PopupMenuItem(
                    value: 'delegation',
                    child: Text(tr('대결(부재) 설정')),
                  ),
                ],
              ),
              const SizedBox(width: 4),
              for (final box in boxes)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    key: ValueKey('approval-box-${box.wire}'),
                    label: Text(
                      box == ApprovalBox.inbox && widget.ctx.pendingForMe > 0
                          ? '${box.label} ${widget.ctx.pendingForMe}'
                          : box.label,
                    ),
                    selected: _box == box,
                    onSelected: (_) => _select(box),
                  ),
                ),
              if (_canFilterUnsettled) ...[
                const SizedBox(width: 6),
                FilterChip(
                  key: const ValueKey('approval-filter-unsettled'),
                  avatar: _unsettled
                      ? null
                      : const Icon(Icons.receipt_long_outlined, size: 16),
                  label: Text(tr('정산 안 됨')),
                  tooltip: tr('승인됐지만 아직 정산하지 않은 구매·출장'),
                  selected: _unsettled,
                  onSelected: _toggleUnsettled,
                ),
              ],
              // 보관함 밖에서도 같은 조건으로 찾을 수 있게(보관함은 검색 줄이 늘 보인다).
              if (_box != ApprovalBox.archive)
                IconButton(
                  key: const ValueKey('approval-search-toggle'),
                  tooltip: _searchOpen ? tr('검색 닫기') : tr('검색'),
                  isSelected: _searchOpen,
                  icon: const Icon(Icons.search),
                  selectedIcon: const Icon(Icons.search_off),
                  onPressed: _toggleSearch,
                ),
            ],
          ),
        ),
        if (_showSearch) _buildSearchBar(context),
        Expanded(
          child: _error != null
              ? GroupwareEmpty(_error!)
              : docs == null
              ? const Center(child: CircularProgressIndicator())
              : docs.isEmpty
              ? GroupwareEmpty(
                  searchEmpty
                      ? tr('찾는 결재 문서가 없습니다.')
                      : _box == ApprovalBox.inbox
                      ? tr('지금 결재할 문서가 없습니다.')
                      : _unsettled && _canFilterUnsettled
                      ? tr('정산할 구매·출장 결재가 없습니다.')
                      : tr('문서가 없습니다.'),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    itemCount: docs.length + (_hasMore ? 1 : 0),
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) => i == docs.length
                        ? Padding(
                            padding: const EdgeInsets.all(8),
                            child: Center(
                              child: _loadingMore
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : TextButton(
                                      key: const ValueKey('approval-more'),
                                      onPressed: _loadMore,
                                      child: Text(tr('더 보기')),
                                    ),
                            ),
                          )
                        : ApprovalDocumentTile(
                            doc: docs[i],
                            ctx: widget.ctx,
                            onTap: () => _open(docs[i]),
                          ),
                  ),
                ),
        ),
      ],
    );
  }

  /// 검색 줄 — 글(엔터·돋보기), 올린 날 기간(시작·끝 날짜 고르기), 종류·상태, 조건 지우기. 줄이 좁으면 다음 줄로 넘어간다.
  Widget _buildSearchBar(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    // 보관함은 끝난 문서만이라 "진행 중"은 고를 것이 없다.
    final statuses = [
      for (final s in ApprovalStatus.values)
        if (_box != ApprovalBox.archive || s != ApprovalStatus.pending) s,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 260,
            child: TextField(
              key: const ValueKey('approval-search'),
              controller: _search,
              maxLength: 100,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _submitSearch(),
              decoration: InputDecoration(
                isDense: true,
                counterText: '',
                hintText: tr('제목·문서 번호·올린 사람'),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  key: const ValueKey('approval-search-go'),
                  tooltip: tr('찾기'),
                  icon: const Icon(Icons.search, size: 20),
                  onPressed: _submitSearch,
                ),
              ),
            ),
          ),
          OutlinedButton.icon(
            key: const ValueKey('approval-search-from'),
            onPressed: () => _pickDate(from: true),
            icon: const Icon(Icons.event, size: 16),
            label: Text(_from == null ? tr('시작일') : dateKeyOf(_from!)),
          ),
          Text('~', style: TextStyle(color: hint)),
          OutlinedButton.icon(
            key: const ValueKey('approval-search-to'),
            onPressed: () => _pickDate(from: false),
            icon: const Icon(Icons.event, size: 16),
            label: Text(_to == null ? tr('종료일') : dateKeyOf(_to!)),
          ),
          // 종류·상태 — 'all'은 모두(PopupMenuButton은 null 값을 고른 것으로 보지 않아 따로 둔다).
          PopupMenuButton<String>(
            key: const ValueKey('approval-search-kind'),
            tooltip: tr('결재 종류'),
            onSelected: (v) {
              _kind = v == 'all' ? null : ApprovalKind.fromWire(v);
              _reload();
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'all', child: Text(tr('모든 종류'))),
              for (final k in ApprovalKind.values)
                PopupMenuItem(value: k.wire, child: Text(k.label)),
            ],
            child: Chip(
              avatar: const Icon(Icons.category_outlined, size: 16),
              label: Text(_kind?.label ?? tr('모든 종류')),
            ),
          ),
          PopupMenuButton<String>(
            key: const ValueKey('approval-search-status'),
            tooltip: tr('결재 상태'),
            onSelected: (v) {
              _status = v == 'all' ? null : ApprovalStatus.fromWire(v);
              _reload();
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'all', child: Text(tr('모든 상태'))),
              for (final s in statuses)
                PopupMenuItem(value: s.wire, child: Text(s.label)),
            ],
            child: Chip(
              avatar: const Icon(Icons.flag_outlined, size: 16),
              label: Text(_status?.label ?? tr('모든 상태')),
            ),
          ),
          if (_hasConditions || _search.text.isNotEmpty)
            TextButton(
              key: const ValueKey('approval-search-clear'),
              onPressed: () {
                _clearSearch();
                _reload();
              },
              child: Text(tr('조건 지우기')),
            ),
        ],
      ),
    );
  }
}

/// 문서 상세를 연다. 승인·반려·회수·취소를 했으면 true.
Future<bool> showApprovalDetail(
  BuildContext context, {
  required GroupwareApi api,
  required GroupwareContext ctx,
  required Session session,
  required String documentId,
}) async {
  final changed = await showDialog<bool>(
    context: context,
    builder: (_) => ApprovalDetailDialog(
      api: api,
      ctx: ctx,
      session: session,
      documentId: documentId,
    ),
  );
  return changed ?? false;
}

/// 결재 문서 상세 — 내용, 결재선(누가 언제 승인·반려했는지와 의견), 참조자, 그리고 내 차례면 승인·반려, 올린 사람은 회수, 관리자는
/// 승인된 문서 취소.
class ApprovalDetailDialog extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final Session session;
  final String documentId;
  const ApprovalDetailDialog({
    super.key,
    required this.api,
    required this.ctx,
    required this.session,
    required this.documentId,
  });

  @override
  State<ApprovalDetailDialog> createState() => _ApprovalDetailDialogState();
}

class _ApprovalDetailDialogState extends State<ApprovalDetailDialog> {
  ApprovalDocument? _doc;
  String? _error;
  bool _busy = false;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final doc = await widget.api.document(widget.documentId);
      if (mounted) setState(() => _doc = doc);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// [action]: approve | reject | disagree | withdraw | cancel. 반려·취소는 사유를, 합의의 "반대 의견으로 진행"은 반대 의견을(꼭),
  /// 승인은 의견(선택)을 받는다. 내 차례가 후결이면 승인은 "후결 확인"(이미 승인된 문서에 확인 기록과 의견을 남긴다).
  Future<void> _act(String action) async {
    String? comment;
    final post = _doc?.postForMe == true;
    if (action != 'withdraw') {
      final result = await showDialog<String>(
        context: context,
        builder: (_) => _CommentDialog(
          title: switch (action) {
            'approve' when post => tr('후결 확인'),
            'approve' => _doc?.finalForMe == true ? tr('전결 승인') : tr('승인'),
            'reject' => tr('반려'),
            'disagree' => tr('반대 의견으로 진행'),
            _ => tr('결재 취소'),
          },
          note: [
            if (action == 'approve' && post)
              tr('이미 승인된 결재입니다. 확인한 기록과 의견이 남습니다.'),
            if (action == 'approve' && !post && _doc?.finalForMe == true)
              tr('전결 — 승인하면 남은 결재는 생략되고 바로 결재가 끝납니다.'),
            if (action == 'disagree')
              tr('반대 의견을 남기고 결재를 다음으로 넘깁니다. 막으려면 반려하세요.'),
            if (action != 'cancel' && _doc?.actingFor != null)
              tr('{p0}님 대신(대결) 결정합니다. 대결한 사람으로 함께 남습니다.', {
                'p0': _doc!.actingFor,
              }),
          ].join('\n'),
          label: switch (action) {
            'approve' => tr('의견 (선택)'),
            'reject' => tr('반려 사유'),
            'disagree' => tr('반대 의견'),
            _ => tr('취소 사유'),
          },
          required: action != 'approve',
        ),
      );
      if (result == null) return;
      comment = result.trim().isEmpty ? null : result.trim();
    } else {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(tr('결재 회수')),
          content: Text(tr('올린 결재를 거둘까요? 결재자에게 더는 보이지 않습니다.')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(tr('취소')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(tr('회수')),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy = true);
    try {
      final doc = await widget.api.decide(
        widget.documentId,
        action,
        comment: comment,
      );
      if (!mounted) return;
      setState(() {
        _doc = doc;
        _changed = true;
      });
      // 지금 차례인 칸들의 이름(승인 뒤 다음 차례 — 승인된 문서면 남은 후결 칸).
      final pendingNames = doc.steps
          .where((s) => s.status == ApprovalStepStatus.pending)
          .map((s) => s.approverName)
          .join(', ');
      showAppToast(context, switch (action) {
        'approve' when post => tr('후결을 확인했습니다.'),
        'approve' =>
          doc.status == ApprovalStatus.approved
              ? (pendingNames.isEmpty
                    ? tr('승인했습니다. 결재가 끝났습니다.')
                    : tr('승인했습니다. 결재가 끝났고 {names}님이 후결로 확인합니다.', {
                        'names': pendingNames,
                      }))
              : tr('승인했습니다. {p0}님 차례입니다.', {'p0': pendingNames}),
        'reject' => tr('반려했습니다.'),
        'disagree' => tr('반대 의견을 남겼습니다. 결재는 계속 진행됩니다.'),
        'withdraw' => tr('회수했습니다.'),
        _ => tr('취소했습니다.'),
      });
      await widget.session.refreshGroupwarePending();
    } catch (e) {
      if (mounted) showAppToast(context, tr('실패: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// "정산하기" — 이 승인된 구매 요청·출장 신청을 정산하는 지출 결재 창을 연다(예산·내용을 미리 채움). 올렸으면 안내하고 상세를
  /// 다시 받아 정산 상태("정산 결재 중")를 보인다. 서버가 거절하면(이미 정산함 등) 지출 창 안에 그 문구가 뜬다.
  Future<void> _settle(ApprovalDocument doc) async {
    final created = await showExpenseRequestDialog(
      context,
      api: widget.api,
      ctx: widget.ctx,
      session: widget.session,
      settles: doc,
    );
    if (created == null || !mounted) return;
    toastSubmitted(context, created);
    setState(() => _changed = true);
    await _load();
  }

  /// 다른 결재(정산 지출 ↔ 원래 결재)의 상세를 위에 겹쳐 연다. 거기서 무언가 바꿨으면 이 문서도 다시 받는다(정산 상태가 바뀔 수 있다).
  Future<void> _openLinked(String id) async {
    final changed = await showApprovalDetail(
      context,
      api: widget.api,
      ctx: widget.ctx,
      session: widget.session,
      documentId: id,
    );
    if (!changed || !mounted) return;
    setState(() => _changed = true);
    await _load();
  }

  /// 지출 결재가 청구한 법인카드 사용 건들(없으면 빈 목록).
  List<Widget> _cardRows(
    BuildContext context,
    List<ClaimedCardTransaction> items,
  ) {
    if (items.isEmpty) return const [];
    final hint = Theme.of(context).hintColor;
    return [
      const SizedBox(height: 8),
      Text(
        tr('법인카드 사용 {n}건', {'n': items.length}),
        key: const ValueKey('approval-card-transactions'),
        style: Theme.of(context).textTheme.titleSmall,
      ),
      for (final t in items)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      t.memo == null ? t.merchant : '${t.merchant} — ${t.memo}',
                    ),
                  ),
                  Text(signedWonText(t.amount)),
                ],
              ),
              Text(
                [
                  if (t.usedAt != null) formatDateTime(t.usedAt!),
                  '${t.cardName} (${t.issuer} ${t.last4})',
                  if (t.approvalNo != null) tr('승인 {no}', {'no': t.approvalNo}),
                ].join(' · '),
                style: TextStyle(fontSize: 12, color: hint),
              ),
              if (t.receipts.isNotEmpty)
                Wrap(
                  spacing: 6,
                  children: [
                    for (final r in t.receipts)
                      ActionChip(
                        avatar: const Icon(Icons.receipt_long, size: 16),
                        label: Text(r.fileName ?? tr('영수증')),
                        onPressed: () => _openAttachment(
                          ApprovalAttachment(
                            fileUrl: r.fileUrl,
                            fileName: r.fileName,
                            mimeType: r.mimeType,
                          ),
                        ),
                      ),
                  ],
                )
              else
                Text(
                  tr('영수증 없음'),
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
                ),
            ],
          ),
        ),
    ];
  }

  Future<void> _openAttachment(ApprovalAttachment a) async {
    final url = a.fileUrl;
    if (url == null) return;
    try {
      final path = await widget.session.downloadAuthedFile(
        url,
        fileName: a.fileName ?? tr('첨부'),
      );
      await openLocalFile(path);
    } catch (e) {
      if (mounted) showAppToast(context, tr('열지 못했습니다: {e}', {'e': e}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    return AlertDialog(
      title: Text(doc?.title ?? tr('결재 문서')),
      content: SizedBox(
        width: 480,
        child: doc == null
            ? (_error != null
                  ? Text(_error!)
                  : const SizedBox(
                      height: 80,
                      child: Center(child: CircularProgressIndicator()),
                    ))
            : SingleChildScrollView(child: _buildBody(context, doc)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_changed),
          child: Text(tr('닫기')),
        ),
        if (doc != null)
          PopupMenuButton<String>(
            key: const ValueKey('approval-print'),
            tooltip: tr('인쇄·PDF'),
            icon: const Icon(Icons.print_outlined),
            // 인쇄·PDF에는 전자서명 검증 결과도 같이(못 받으면 빼고 인쇄한다).
            onSelected: (v) => v == 'print'
                ? printApproval(
                    context,
                    doc,
                    widget.ctx,
                    widget.session,
                    api: widget.api,
                  )
                : saveApprovalPdf(
                    context,
                    doc,
                    widget.ctx,
                    widget.session,
                    api: widget.api,
                  ),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'print', child: Text(tr('인쇄'))),
              PopupMenuItem(value: 'pdf', child: Text(tr('PDF로 저장'))),
            ],
          ),
        // 전자서명 검증 — 결정한 칸마다 서버가 남긴 서명이 지금 내용과 맞는지(위변조 확인).
        if (doc != null)
          IconButton(
            key: const ValueKey('approval-verify'),
            tooltip: tr('전자서명 검증'),
            icon: const Icon(Icons.verified_user_outlined),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) =>
                  ApprovalVerifyDialog(api: widget.api, documentId: doc.id),
            ),
          ),
        // 승인된 내 구매 요청·출장 신청에 살아 있는 정산이 없으면(서버 canSettle) — 쓴 돈을 지출 결재로 정산한다.
        if (doc != null && doc.canSettle)
          OutlinedButton.icon(
            key: const ValueKey('approval-settle'),
            onPressed: _busy ? null : () => _settle(doc),
            icon: const Icon(Icons.receipt_long_outlined, size: 18),
            label: Text(tr('정산하기')),
          ),
        if (doc != null && doc.canWithdraw)
          TextButton(
            key: const ValueKey('approval-withdraw'),
            onPressed: _busy ? null : () => _act('withdraw'),
            child: Text(tr('회수')),
          ),
        if (doc != null && doc.canCancel)
          TextButton(
            key: const ValueKey('approval-cancel'),
            onPressed: _busy ? null : () => _act('cancel'),
            child: Text(tr('결재 취소')),
          ),
        // 내 차례 — 합의 칸이면 "반대 의견으로 진행"(결재는 이어진다), 후결 칸이면 반려 없이 "후결 확인"만.
        if (doc != null && doc.myTurn) ...[
          if (doc.canDisagree)
            OutlinedButton(
              key: const ValueKey('approval-disagree'),
              onPressed: _busy ? null : () => _act('disagree'),
              child: Text(tr('반대 의견으로 진행')),
            ),
          if (!doc.postForMe)
            OutlinedButton(
              key: const ValueKey('approval-reject'),
              onPressed: _busy ? null : () => _act('reject'),
              child: Text(tr('반려')),
            ),
          FilledButton(
            key: const ValueKey('approval-approve'),
            onPressed: _busy ? null : () => _act('approve'),
            child: Text(doc.postForMe ? tr('후결 확인') : tr('승인')),
          ),
        ],
      ],
    );
  }

  Widget _buildBody(BuildContext context, ApprovalDocument doc) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(label, style: TextStyle(color: hint)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
    final p = doc.payload;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            ApprovalStatusChip(doc.status),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                [
                  doc.kindLabel,
                  doc.authorName,
                  if (doc.docNumber != null) doc.docNumber!,
                ].join(' · '),
                key: const ValueKey('approval-doc-header'),
                style: TextStyle(color: hint),
              ),
            ),
            if (doc.createdAt != null)
              Text(
                formatDateTime(doc.createdAt!),
                style: TextStyle(color: hint, fontSize: 12),
              ),
          ],
        ),
        if (doc.actingFor != null && doc.myTurn)
          Container(
            key: const ValueKey('approval-acting-for'),
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              tr('{doc.actingFor}님이 자리를 비워 대신(대결) 결재할 차례입니다.', {
                'doc.actingFor': doc.actingFor,
              }),
            ),
          ),
        const SizedBox(height: 12),
        ApprovalStampBox(doc: doc, resolveUrl: widget.session.resolveUrl),
        const SizedBox(height: 12),
        // 올릴 때 맞은 전결 규정 — 어느 직책 이상이 전결했는지, 결재선에 그런 사람이 없었으면 끝까지 결재한다는 것.
        if (doc.finalRule case final rule?)
          KeyedSubtree(
            key: const ValueKey('approval-final-rule'),
            child: row(
              tr('전결 규정'),
              rule.applied
                  ? '${tr('{position} 이상 전결', {'position': rule.positionLabel})}${rule.minAmount == null ? '' : tr(' ({won} 이상 문서)', {'won': wonText(rule.minAmount!)})}'
                  : tr('{position} 이상 전결 — 결재선에 해당하는 사람이 없어 끝까지 결재', {
                      'position': rule.positionLabel,
                    }),
            ),
          ),
        if (doc.kind == ApprovalKind.leave) ...[
          row(
            tr('종류'),
            p['leaveLabel'] as String? ??
                widget.ctx.leaveType(p['leaveType'] as String?)?.label ??
                tr('휴가'),
          ),
          row(
            tr('기간'),
            p['startDate'] == p['endDate']
                ? '${p['startDate']}'
                : '${p['startDate']} ~ ${p['endDate']}',
          ),
          row(tr('일수'), halfDaysText(p['halfDays'] as num? ?? 0)),
        ],
        if (doc.kind == ApprovalKind.expense) ...[
          row(tr('금액'), wonText((p['amount'] as num?)?.toInt() ?? 0)),
          row(tr('분류'), '${p['category'] ?? ''}'),
          row(tr('쓴 날'), '${p['spentOn'] ?? ''}'),
          if (doc.settles case final settles?)
            ..._settlesRows(context, doc, settles, row),
          // 법인카드 청구 — 그때의 사용 건과 사용 건마다 붙인 영수증.
          ..._cardRows(context, ClaimedCardTransaction.listOf(p)),
        ],
        if (doc.kind.isForm) FormValuesView(doc: doc),
        if (kSettleKinds.contains(doc.kind)) ?_settlementRow(context, doc),
        if (doc.kind == ApprovalKind.attendance) ...[
          row(tr('날짜'), '${p['workDate'] ?? ''}'),
          row(tr('출근'), '${p['clockIn'] ?? ''}'),
          row(
            tr('퇴근'),
            p['clockOut'] == null ? tr('(그대로)') : '${p['clockOut']}',
          ),
        ],
        if (doc.body != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(doc.body!),
          ),
        ],
        if (doc.attachments.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final a in doc.attachments)
                ActionChip(
                  avatar: const Icon(Icons.attach_file, size: 16),
                  label: Text(a.fileName ?? tr('첨부')),
                  onPressed: () => _openAttachment(a),
                ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        Text(tr('결재선'), style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        for (final s in doc.steps)
          ListTile(
            key: ValueKey('approval-step-${s.order}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              radius: 13,
              backgroundColor: switch (s.status) {
                ApprovalStepStatus.approved => Colors.green.shade100,
                ApprovalStepStatus.rejected => theme.colorScheme.errorContainer,
                // 합의 반대 — 결재는 이어졌지만 눈에 띄게(반려의 빨강과 다른 주황).
                ApprovalStepStatus.disagreed => Colors.orange.shade100,
                ApprovalStepStatus.pending =>
                  theme.colorScheme.primaryContainer,
                ApprovalStepStatus.waiting || ApprovalStepStatus.skipped =>
                  theme.colorScheme.surfaceContainerHighest,
              },
              child: Text(
                '${s.stage + 1}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            title: Text(
              '${s.approverName} · ${s.role.label} · ${s.status.label}',
              style: s.status == ApprovalStepStatus.disagreed
                  ? TextStyle(color: Colors.orange.shade900)
                  : null,
            ),
            // 결정할 때 서버가 전자서명한 칸(맞는지는 "전자서명 검증").
            trailing: s.sealed
                ? Tooltip(
                    message: tr('전자서명됨'),
                    child: Icon(
                      Icons.verified_outlined,
                      key: ValueKey('approval-step-sealed-${s.order}'),
                      size: 16,
                      color: hint,
                    ),
                  )
                : null,
            subtitle:
                s.comment == null &&
                    s.decidedAt == null &&
                    s.actedByName == null
                ? null
                : Text(
                    [
                      if (s.actedByName != null)
                        tr('대결 {s.actedByName}', {
                          's.actedByName': s.actedByName,
                        }),
                      if (s.decidedAt != null) formatDateTime(s.decidedAt!),
                      if (s.comment != null) '"${s.comment}"',
                    ].join(' · '),
                  ),
          ),
        if (doc.cc.isNotEmpty)
          row(tr('참조'), doc.cc.map((c) => c.name).join(', ')),
        if (doc.status == ApprovalStatus.canceled)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              tr('{p0}님이 취소했습니다: {p1}', {
                'p0': doc.canceledByName ?? tr('관리자'),
                'p1': doc.cancelReason ?? '',
              }),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }

  /// 구매 요청·출장 신청의 "정산" 줄 — 이 결재를 정산하는 지출 결재의 상태(서버 settlementOf: 승인된 것 → 결재 중 → 최근 것)와
  /// 그 번호·제목·금액·예산과의 차이. 누르면 그 지출 결재 상세를 연다. 정산이 아직 없으면 승인된 결재에만 "정산 안 함"을 보인다
  /// (진행 중·반려된 구매·출장은 정산할 일이 없다). 보일 게 없으면 null.
  Widget? _settlementRow(BuildContext context, ApprovalDocument doc) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final s = doc.settlement;
    if (s == null && doc.status != ApprovalStatus.approved) return null;
    final (String status, Color color) = switch (s?.status) {
      null => (tr('정산 안 함'), hint),
      ApprovalStatus.pending => (tr('정산 결재 중'), theme.colorScheme.primary),
      ApprovalStatus.approved => (tr('정산됨'), Colors.green.shade700),
      final other => (
        tr('정산 {status} — 다시 올릴 수 있습니다', {'status': other.label}),
        theme.colorScheme.error,
      ),
    };
    final budget = settleBudgetOf(doc);
    final amount = s?.amount;
    final detail = s == null
        ? ''
        : [
            ?s.docNumber,
            s.title,
            if (amount != null) wonText(amount),
            if (amount != null && budget != null)
              settleDiffText(amount - budget),
          ].join(' · ');
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(tr('정산'), style: TextStyle(color: hint)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status,
                  style: TextStyle(color: color, fontWeight: FontWeight.w600),
                ),
                if (detail.isNotEmpty)
                  Text(detail, style: TextStyle(fontSize: 12, color: hint)),
              ],
            ),
          ),
          if (s != null) Icon(Icons.chevron_right, size: 18, color: hint),
        ],
      ),
    );
    return Padding(
      key: const ValueKey('approval-settlement'),
      padding: const EdgeInsets.only(top: 4),
      child: s == null
          ? content
          : InkWell(
              onTap: () => _openLinked(s.id),
              borderRadius: BorderRadius.circular(6),
              child: content,
            ),
    );
  }

  /// 정산 지출 결재의 줄들 — "정산 대상"(올릴 때의 번호·제목, 누르면 그 결재 상세)과, 예산을 알면 "예산"·"차이"(+면 예산보다 많이 씀).
  List<Widget> _settlesRows(
    BuildContext context,
    ApprovalDocument doc,
    ApprovalSettles settles,
    Widget Function(String label, String value) row,
  ) {
    final hint = Theme.of(context).hintColor;
    final budget = settles.budget;
    final amount = (doc.payload['amount'] as num?)?.toInt();
    return [
      InkWell(
        key: const ValueKey('approval-settles'),
        onTap: settles.id.isEmpty ? null : () => _openLinked(settles.id),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              SizedBox(
                width: 72,
                child: Text(tr('정산 대상'), style: TextStyle(color: hint)),
              ),
              Expanded(
                child: Text(
                  [
                    settles.kind.label,
                    ?settles.docNumber,
                    settles.title,
                  ].join(' · '),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: hint),
            ],
          ),
        ),
      ),
      if (budget != null) ...[
        row(tr('예산'), wonText(budget)),
        if (amount != null)
          KeyedSubtree(
            key: const ValueKey('approval-settle-diff'),
            child: row(
              tr('차이'),
              '${_signedWon(amount - budget)} (${settleDiffText(amount - budget)})',
            ),
          ),
      ],
    ];
  }
}

/// 차이 금액 → "+12,000원" / "-3,000원" / "0원"(wonText는 음수를 못 받아 부호를 따로 붙인다).
String _signedWon(int diff) =>
    '${diff > 0
        ? '+'
        : diff < 0
        ? '-'
        : ''}${wonText(diff.abs())}';

/// 전자서명 검증 창 — 서버(GET /groupware/documents/:id/verify)에 물어 전체 결과(위변조 없음 · 바뀐 곳이 있음 · 검증할 서명 없음),
/// 칸마다 결과, 문서 지문(SHA-256 — 고를 수 있고 복사 단추)과 서버 키 지문을 보인다. 인쇄한 종이의 지문과 견줘 볼 수 있다.
class ApprovalVerifyDialog extends StatefulWidget {
  final GroupwareApi api;
  final String documentId;
  const ApprovalVerifyDialog({
    super.key,
    required this.api,
    required this.documentId,
  });

  @override
  State<ApprovalVerifyDialog> createState() => _ApprovalVerifyDialogState();
}

class _ApprovalVerifyDialogState extends State<ApprovalVerifyDialog> {
  ApprovalVerification? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await widget.api.verifyDocument(widget.documentId);
      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// 긴 지문 한 덩어리 — 이름, 고정폭 글(골라 복사할 수 있게)과 복사 단추.
  Widget _fingerprint(String label, String value, Key key) {
    final hint = Theme.of(context).hintColor;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(label, style: TextStyle(color: hint, fontSize: 12)),
          ),
          Expanded(
            child: SelectableText(
              value,
              key: key,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
          IconButton(
            tooltip: tr('복사'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy, size: 16),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (mounted) showAppToast(context, tr('복사했습니다.'));
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final v = _result;
    Widget body;
    if (v == null) {
      body = _error != null
          ? Text(_error!, style: TextStyle(color: theme.colorScheme.error))
          : const SizedBox(
              height: 80,
              child: Center(child: CircularProgressIndicator()),
            );
    } else {
      final none = v.steps.every((s) => s.result == 'unsealed');
      final (IconData icon, Color color) = v.tampered
          ? (Icons.gpp_bad_outlined, theme.colorScheme.error)
          : none
          ? (Icons.help_outline, hint)
          : (Icons.verified_user, Colors.green.shade700);
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  sealSummaryText(v),
                  key: const ValueKey('approval-verify-summary'),
                  style: TextStyle(color: color, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final s in v.steps)
            Padding(
              key: ValueKey('approval-verify-step-${s.order}'),
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text('${s.approverName} · ${s.status.label}'),
                  ),
                  Text(
                    sealResultText(s.result),
                    style: TextStyle(
                      fontSize: 12,
                      color: switch (s.result) {
                        'valid' => Colors.green.shade700,
                        'unsealed' => hint,
                        _ => theme.colorScheme.error,
                      },
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 20),
          _fingerprint(
            tr('문서 지문'),
            v.digest,
            const ValueKey('approval-verify-digest'),
          ),
          _fingerprint(
            tr('서버 키 지문'),
            v.fingerprint,
            const ValueKey('approval-verify-fingerprint'),
          ),
          const SizedBox(height: 6),
          Text(
            tr(
              '문서 지문은 문서 내용과 결재 기록으로 만든 값이고, 서버 키 지문은 서명한 서버의 열쇠입니다. 인쇄한 문서의 값과 견줘 볼 수 있습니다.',
            ),
            style: TextStyle(fontSize: 11, color: hint),
          ),
        ],
      );
    }
    return AlertDialog(
      title: Text(tr('전자서명 검증')),
      content: SizedBox(width: 440, child: SingleChildScrollView(child: body)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('닫기')),
        ),
      ],
    );
  }
}

class _CommentDialog extends StatefulWidget {
  final String title;
  final String label;
  final bool required;

  /// 입력칸 위의 안내(전결·대결) — 비면 없음.
  final String note;
  const _CommentDialog({
    required this.title,
    required this.label,
    required this.required,
    this.note = '',
  });

  @override
  State<_CommentDialog> createState() => _CommentDialogState();
}

class _CommentDialogState extends State<_CommentDialog> {
  final _text = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _done() {
    if (widget.required && _text.text.trim().isEmpty) {
      setState(
        () =>
            _error = tr('{widget.label}를 쓰세요.', {'widget.label': widget.label}),
      );
      return;
    }
    Navigator.of(context).pop(_text.text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                widget.note,
                key: const ValueKey('approval-comment-note'),
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          TextField(
            key: const ValueKey('approval-comment'),
            controller: _text,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            maxLength: 500,
            decoration: InputDecoration(
              labelText: widget.label,
              errorText: _error,
              border: const OutlineInputBorder(),
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
      FilledButton(
        key: const ValueKey('approval-comment-ok'),
        onPressed: _done,
        child: Text(widget.title),
      ),
    ],
  );
}
